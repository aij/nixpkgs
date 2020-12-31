import ./make-test-python.nix ({pkgs, lib, ...}:

let
  cfg = {
    clusterId = "066ae264-2a5d-4729-8001-6ad265f50b03";
    monA = {
      name = "a";
      ip = "192.168.1.1";
    };
    monB = {
      name = "b";
      ip = "192.168.1.2";
    };
    monC = {
      name = "c";
      ip = "192.168.1.3";
    };
    osd0 = {
      name = "0";
      ip = "192.168.1.10";
    };
    osd1 = {
      name = "1";
      ip = "192.168.1.11";
    };
    osd2 = {
      name = "2";
      ip = "192.168.1.12";
    };
    mds0 = {
      name = "mds0";
      ip = "192.168.1.4";
    };
    mds1 = {
      name = "mds1";
      ip = "192.168.1.5";
    };
    client = {
      ip = "192.168.1.100";
    };
  };
  commonConfig = {
    virtualisation = {
      memorySize = 1024;
      emptyDiskImages = [ 20480 ];
      vlans = [ 1 ];
    };

    environment.systemPackages = with pkgs; [
      bash
      sudo
      ceph
      kmod busybox
    ];

    services.ceph = {
      enable = true;
      global = {
        fsid = cfg.clusterId;
        monHost = "${cfg.monA.ip} ${cfg.monB.ip} ${cfg.monC.ip}";
        monInitialMembers = cfg.monA.name;
        # Ideally, this should include all expected mons, but we can't have
        # others configured when bootstrapping.
        #monInitialMembers = "${cfg.monA.name} ${cfg.monB.name} ${cfg.monC.name}";
        publicNetwork = "192.168.1.0/24";
      };
    };
  };

  generateHost = {ip, ...}: config: {
    imports = [ commonConfig config ];
    networking = {
      dhcpcd.enable = false;
      interfaces.eth1.ipv4.addresses = pkgs.lib.mkOverride 0 [
      { address = ip; prefixLength = 24; }
    ];
  };
  };

  monConfig = {name, ...}: {
    networking.firewall = {
        allowedTCPPorts = [ 6789 3300 ];
        allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    };
    services.ceph = {
      mon = {
        enable = true;
        daemons = [ name ];
      };
      mgr = {
        enable = true;
        daemons = [ name ];
      };
    }; };

  osdConfig = {name, ...}: {
    networking.firewall = {
        allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    };

    services.ceph = {
      osd = {
        enable = true;
        daemons = [ name ];
      };
    };
  };

  mdsConfig= {name, ...}: {
    services.ceph.mds = {
        enable = true;
        daemons = [ name ];
      };

    networking.firewall = {
        allowedTCPPorts = [ 6789 3300 ];
        allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    };
  };

in {
  nodes = {
    monA = generateHost cfg.monA (monConfig cfg.monA);
    monB = generateHost cfg.monB (monConfig cfg.monB);
    monC = generateHost cfg.monC (monConfig cfg.monC);
    osd0 = generateHost cfg.osd0 (osdConfig cfg.osd0);
    osd1 = generateHost cfg.osd1 (osdConfig cfg.osd1);
    osd2 = generateHost cfg.osd2 (osdConfig cfg.osd2);
    mds0 = generateHost cfg.mds0 (mdsConfig cfg.mds0);
    client = generateHost cfg.client { };
  };

  # Following deployment is based on the manual deployment described here:
  # https://docs.ceph.com/docs/master/install/manual-deployment/
  # For other ways to deploy a ceph cluster, look at the documentation at
  # https://docs.ceph.com/docs/master/
  testScript = { ... }: ''
    start_all()

    monA.wait_for_unit("network.target")
    osd0.wait_for_unit("network.target")
    osd1.wait_for_unit("network.target")
    osd2.wait_for_unit("network.target")

    # Bootstrap ceph-mon daemon
    monA.succeed(
        "sudo -u ceph ceph-authtool --create-keyring /tmp/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'",
        "sudo -u ceph ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'",
        "sudo -u ceph ceph-authtool /tmp/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring",
        "sudo -u ceph mkdir /var/lib/ceph/bootstrap-osd",
        "sudo -u ceph ceph-authtool --create-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring --gen-key -n client.bootstrap-osd --cap mon 'profile bootstrap-osd' --cap mgr 'allow r'",
        "sudo -u ceph ceph-authtool /tmp/ceph.mon.keyring --import-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring",
        "monmaptool --create --add ${cfg.monA.name} ${cfg.monA.ip} --fsid ${cfg.clusterId} /tmp/monmap",
        "sudo -u ceph ceph-mon --mkfs -i ${cfg.monA.name} --monmap /tmp/monmap --keyring /tmp/ceph.mon.keyring",
        "sudo -u ceph mkdir -p /var/lib/ceph/mgr/ceph-${cfg.monA.name}/",
        "sudo -u ceph touch /var/lib/ceph/mon/ceph-${cfg.monA.name}/done",
        "systemctl start ceph-mon-${cfg.monA.name}",
    )
    monA.wait_for_unit("ceph-mon-${cfg.monA.name}")
    monA.succeed("ceph mon enable-msgr2")

    # Can't check ceph status until a mon is up
    monA.succeed("ceph -s | grep 'mon: 1 daemons'")

    # Start the ceph-mgr daemon, it has no deps and hardly any setup
    monA.succeed(
        "ceph auth get-or-create mgr.${cfg.monA.name} mon 'allow profile mgr' osd 'allow *' mds 'allow *' > /var/lib/ceph/mgr/ceph-${cfg.monA.name}/keyring",
        "systemctl start ceph-mgr-${cfg.monA.name}",
    )
    monA.wait_for_unit("ceph-mgr-${cfg.monA.name}")
    monA.wait_until_succeeds("ceph -s | grep 'quorum ${cfg.monA.name}'")
    monA.wait_until_succeeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'")

    # Send the OSD Bootstrap keyring to the OSD machines
    monA.succeed("cp -r /var/lib/ceph/bootstrap-osd /tmp/shared")
    # /etc/ceph/ceph.client.bootstrap-osd.keyring
    osd0.succeed("cp -r /tmp/shared/bootstrap-osd /var/lib/ceph/")
    osd1.succeed("cp -r /tmp/shared/bootstrap-osd /var/lib/ceph/")
    osd2.succeed("cp -r /tmp/shared/bootstrap-osd /var/lib/ceph/")

    # Bootstrap OSDs
    osd0.succeed(
        "ceph-volume lvm create --no-systemd --data /dev/vdb",
        "systemctl start ceph-osd-${cfg.osd0.name}",
    )
    osd1.succeed(
        "ceph-volume lvm create --no-systemd --data /dev/vdb",
        "systemctl start ceph-osd-${cfg.osd1.name}",
    )
    osd2.succeed(
        "ceph-volume lvm create --no-systemd --data /dev/vdb",
        "systemctl start ceph-osd-${cfg.osd2.name}",
    )

    monA.wait_until_succeeds("ceph osd stat | grep -e '3 osds: 3 up[^,]*, 3 in'")
    monA.wait_until_succeeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'")
    monA.wait_until_succeeds("ceph -s | grep 'HEALTH_OK'")


    # Bootstram an MDS
    monA.succeed(
        "ceph auth get-or-create mds.${cfg.mds0.name} mon 'allow rwx' osd 'allow *' mds 'allow *' mgr 'allow profile mds' -o /tmp/shared/ceph-${cfg.mds0.name}-keyring",
    )
    mds0.succeed(
        "mkdir -p /var/lib/ceph/mds/ceph-${cfg.mds0.name}",
        "cp /tmp/shared/ceph-${cfg.mds0.name}-keyring /var/lib/ceph/mds/ceph-${cfg.mds0.name}/keyring",
        # "chown",
        "systemctl start ceph-mds-${cfg.mds0.name}",
    )
    mds0.wait_for_unit("ceph-mds-${cfg.mds0.name}")
    # print(monA.succeed("ceph -s"))
    monA.wait_until_succeeds("ceph -s | grep 'mds: '")
    # print(monA.succeed("ceph -s"))
    monA.wait_until_succeeds("ceph -s | grep HEALTH_OK")

    # Create a ceph filesystem
    # Based on https://docs.ceph.com/en/latest/cephfs/createfs/
    monA.succeed(
        "ceph osd pool create cephfs_data",
        "ceph osd pool create cephfs_metadata",
        "ceph fs new cephfs cephfs_metadata cephfs_data",
        "ceph fs authorize cephfs client.foo / rw >/tmp/shared/ceph.client.foo.keyring",
    )
    # print(monA.succeed("ceph -s"))

    # Mount the filesystem
    client.succeed(
        "cp /tmp/shared/ceph.client.foo.keyring /etc/ceph/ceph.client.foo.keyring",
        "mkdir -p /mnt/ceph",
        "mount -t ceph :/ /mnt/ceph -o name=foo",
        "ls -l /mnt/ceph",
        "cp -a ${pkgs.ceph.out} /mnt/ceph/some_data",
        "df -h /mnt/ceph",
    )

    # Add 2 more Mon/mgrs so we can tolerate a failure while maintaining quorum
    # Based on https://docs.ceph.com/en/latest/rados/operations/add-or-rm-mons/
    monA.succeed(
        "ceph auth get mon. -o /tmp/shared/mon.keyring",
        "ceph mon getmap -o /tmp/shared/monmap",
        "ceph auth get-or-create mgr.${cfg.monB.name} mon 'allow profile mgr' osd 'allow *' mds 'allow *' > /tmp/shared/ceph-${cfg.monB.name}.keyring",
        "ceph auth get-or-create mgr.${cfg.monC.name} mon 'allow profile mgr' osd 'allow *' mds 'allow *' > /tmp/shared/ceph-${cfg.monC.name}.keyring",
    )
    monB.succeed(
        "mkdir /var/lib/ceph/mon/ceph-${cfg.monB.name}",
        "ceph-mon -i ${cfg.monB.name} --mkfs --monmap /tmp/shared/monmap --keyring /tmp/shared/mon.keyring",
        "systemctl start ceph-mon-${cfg.monB.name}",
        "mkdir /var/lib/ceph/mgr/ceph-${cfg.monB.name}",
        "cp /tmp/shared/ceph-${cfg.monB.name}.keyring /var/lib/ceph/mgr/ceph-${cfg.monB.name}/keyring",
        "systemctl start ceph-mgr-${cfg.monB.name}",
    )
    monB.wait_for_unit("ceph-mon-${cfg.monB.name}")
    monB.wait_for_unit("ceph-mgr-${cfg.monB.name}")
    monC.succeed(
        "mkdir /var/lib/ceph/mon/ceph-${cfg.monC.name}",
        "ceph-mon -i ${cfg.monC.name} --mkfs --monmap /tmp/shared/monmap --keyring /tmp/shared/mon.keyring",
        "systemctl start ceph-mon-${cfg.monC.name}",
        "mkdir /var/lib/ceph/mgr/ceph-${cfg.monC.name}",
        "cp /tmp/shared/ceph-${cfg.monC.name}.keyring /var/lib/ceph/mgr/ceph-${cfg.monC.name}/keyring",
        "systemctl start ceph-mgr-${cfg.monC.name}",
    )
    monC.wait_for_unit("ceph-mon-${cfg.monC.name}")
    monC.wait_for_unit("ceph-mgr-${cfg.monC.name}")
    # print(monA.succeed("ceph -s"))
    monA.wait_until_succeeds("ceph -s | grep 'mon: 3 daemons'")
    print(monA.succeed("ceph -s"))
    monA.wait_until_succeeds("ceph -s | grep 'mgr: .(active, since .*), standbys: ., .'")

    # Let's not lose the admin key for now. I'm not sure how to recover it if lost.
    monA.succeed("cp /etc/ceph/ceph.client.admin.keyring /tmp/shared/")
    monB.succeed("cp /tmp/shared/ceph.client.admin.keyring /etc/ceph/")

    # Shut down ceph on all cluster machines in a very unpolite way
    # mds0.crash()
    monA.crash()
    osd0.crash()
    # osd1.crash()
    # osd2.crash()
    # client.crash()
    #
    # # Start it up
    # osd0.start()
    # osd1.start()
    # osd2.start()
    # monA.start()
    # mds0.start()
    # client.start()

    # Ensure the cluster comes back up again
    # time.sleep(30)
    print(monB.succeed("ceph -s"))
    monB.wait_until_fails("ceph -s | grep HEALTH_OK")
    print(monB.succeed("ceph -s"))
    monB.wait_until_succeeds("ceph -s | grep 'osd: 3 osds: 2 up'")
    monB.succeed("ceph -s | grep 'mon: 3 daemons'")
    monB.succeed("ceph -s | grep 'quorum ${cfg.monB.name},${cfg.monC.name} .*, out of quorum: ${cfg.monA.name}'")
    print(monB.succeed("ceph osd stat"))
    # monB.wait_until_succeeds("ceph osd stat | grep -e '3 osds: 2 up[^,]*, 3 in'")
    print(monB.succeed("ceph -s"))
    print(monB.succeed("ceph -s | grep 'mgr: .*(active,'"))
    print(monB.succeed("ceph -s"))
    monB.wait_until_succeeds("ceph -s | grep 'mds: cephfs:1.*=${cfg.mds0.name}=up'")
    print(monB.succeed("ceph -s"))

    monB.wait_until_succeeds("ceph -s | grep HEALTH_WARN")

    # TODO: The client should be able to recover if it stays up accross a ceph cluster restart?
    # Re-Mount the filesystem
    # client.succeed(
    #     "mount -t ceph :/ /mnt/ceph -o name=foo",
    # )

    # Client should still have the filesystem mounted and usable
    print(client.succeed("df -h /mnt/ceph"))
    print(client.succeed("ls -l /mnt/ceph"))
    client.succeed(
        "echo hello > /mnt/ceph/world",
        # Make sure we didn't lose anything from earlier
        "diff --recursive ${pkgs.ceph.out} /mnt/ceph/some_data",
    )
  '';


  name = "ceph-ha-cluster";
  meta = with pkgs.stdenv.lib.maintainers; {
    maintainers = [ aij ];
  };
})
