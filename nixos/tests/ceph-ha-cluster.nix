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
    # Clients
    alice = {
      ip = "192.168.1.100";
    };
    bob = {
      ip = "192.168.1.101";
    };
  };
  commonConfig = {
    virtualisation = {
      memorySize = 1024;
      vlans = [ 1 ];
    };

    environment.systemPackages = with pkgs; [
      bash
      sudo
      ceph
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

  monConfig = c: generateHost c {
    networking.firewall = {
      allowedTCPPorts = [ 6789 3300 ];
      allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    };
    services.ceph = {
      mon = {
        enable = true;
        daemons = [ c.name ];
      };
      mgr = {
        enable = true;
        daemons = [ c.name ];
      };
    };
  };

  osdConfig = c: generateHost c {
    services.ceph.osd = {
      enable = true;
      daemons = [ c.name ];
    };
    environment.systemPackages = with pkgs; [
      cryptsetup # needed for --dmcrypt. Perhaps ceph should depend on it directly.
    ];
    networking.firewall.allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    virtualisation.emptyDiskImages = [ 20480 ];
  };

  mdsConfig = c: generateHost c {
    services.ceph.mds = {
      enable = true;
      daemons = [ c.name ];
    };
    networking.firewall.allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    virtualisation.memorySize = lib.mkForce 1024;
  };

in {
  nodes = {
    monA = monConfig cfg.monA;
    monB = monConfig cfg.monB;
    monC = monConfig cfg.monC;
    osd0 = osdConfig cfg.osd0;
    osd1 = osdConfig cfg.osd1;
    osd2 = osdConfig cfg.osd2;
    mds0 = mdsConfig cfg.mds0;
    mds1 = mdsConfig cfg.mds1;
    alice = generateHost cfg.alice { };
    bob = generateHost cfg.bob { };
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

    # We're using monA as the admin node
    admin = monA
    admin.wait_until_succeeds("ceph -s | grep 'quorum ${cfg.monA.name}'")
    admin.wait_until_succeeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'")

    # Send the OSD Bootstrap keyring to the OSD machines
    monA.succeed("cp -r /var/lib/ceph/bootstrap-osd /tmp/shared")
    # /etc/ceph/ceph.client.bootstrap-osd.keyring


    def add_osd(osd, name):
        osd.succeed(
            "cp -r /tmp/shared/bootstrap-osd /var/lib/ceph/",
            "ceph-volume lvm create --no-systemd --bluestore --data /dev/vdb --dmcrypt",
            f"systemctl start ceph-osd-{name}",
        )


    # Bootstrap OSDs
    add_osd(osd0, "${cfg.osd0.name}")
    add_osd(osd1, "${cfg.osd1.name}")
    add_osd(osd2, "${cfg.osd2.name}")

    admin.wait_until_succeeds("ceph osd stat | grep -e '3 osds: 3 up[^,]*, 3 in'")
    admin.wait_until_succeeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'")
    admin.wait_until_succeeds("ceph -s | grep 'HEALTH_OK'")


    def add_mds(mds, name):
        global admin
        admin.succeed(
            f"ceph auth get-or-create mds.{name} mon 'allow rwx' osd 'allow *' mds 'allow *' mgr 'allow profile mds' -o /tmp/shared/ceph-{name}-keyring",
        )
        mds.succeed(
            f"mkdir -p /var/lib/ceph/mds/ceph-{name}",
            f"cp /tmp/shared/ceph-{name}-keyring /var/lib/ceph/mds/ceph-{name}/keyring",
            f"systemctl start ceph-mds-{name}",
        )
        mds.wait_for_unit(f"ceph-mds-{name}")
        admin.wait_until_succeeds("ceph -s | grep 'mds: '")
        admin.wait_until_succeeds("ceph -s | grep HEALTH_OK")


    # Bootstrap an MDS
    add_mds(mds0, "${cfg.mds0.name}")

    # Create a ceph filesystem
    # Based on https://docs.ceph.com/en/latest/cephfs/createfs/
    admin.succeed(
        "ceph osd pool create cephfs_metadata",
        "ceph osd pool create cephfs_data",
        "ceph fs new cephfs cephfs_metadata cephfs_data",
        # rwp needed for setfattr per https://www.spinics.net/lists/ceph-users/msg44594.html
        "ceph fs authorize cephfs client.alice / rwp >/tmp/shared/ceph.client.alice.keyring",
        "ceph fs authorize cephfs client.bob / rw >/tmp/shared/ceph.client.bob.keyring",
    )

    # Add a standby MDS
    add_mds(mds1, "${cfg.mds1.name}")
    admin.wait_until_succeeds("ceph -s | grep 'mds: .*up:active.* up:standby'")

    # Based on https://docs.ceph.com/en/latest/rados/operations/add-or-rm-mons/
    def add_mon_mgr(mon, name):
        admin.succeed(
            "ceph auth get mon. -o /tmp/shared/mon.keyring",
            "ceph mon getmap -o /tmp/shared/monmap",
            f"ceph auth get-or-create mgr.{name} mon 'allow profile mgr' osd 'allow *' mds 'allow *' > /tmp/shared/ceph-mgr.{name}.keyring",
        )
        mon.succeed(
            f"mkdir /var/lib/ceph/mon/ceph-{name}",
            f"ceph-mon -i {name} --mkfs --monmap /tmp/shared/monmap --keyring /tmp/shared/mon.keyring",
            f"systemctl start ceph-mon-{name}",
            f"mkdir /var/lib/ceph/mgr/ceph-{name}",
            f"cp /tmp/shared/ceph-mgr.{name}.keyring /var/lib/ceph/mgr/ceph-{name}/keyring",
            f"systemctl start ceph-mgr-{name}",
        )
        mon.wait_for_unit(f"ceph-mon-{name}")
        mon.wait_for_unit(f"ceph-mgr-{name}")


    # Add 2 more Mon/mgrs so we can tolerate a failure while maintaining quorum
    add_mon_mgr(monB, "${cfg.monB.name}")
    add_mon_mgr(monC, "${cfg.monC.name}")

    admin.wait_until_succeeds("ceph -s | grep 'mon: 3 daemons'")
    admin.wait_until_succeeds("ceph -s | grep 'mgr: .(active, since .*), standbys: ., .'")

    # Let's not lose the admin key for now. I'm not sure how to recover it if lost.
    admin.succeed("cp /etc/ceph/ceph.client.admin.keyring /tmp/shared/")
    monB.succeed(
        "cp /tmp/shared/ceph.client.admin.keyring /etc/ceph/",
        "sync",
    )

    # Simulate everything has had enough time to settle since cluster bootstrapping.
    for machine in machines:
        if machine.is_up():
            machine.execute("sync")


    # Mount the filesystem with the kernel driver
    alice.succeed(
        "cp /tmp/shared/ceph.client.alice.keyring /etc/ceph/",
        "mkdir -p /mnt/ceph",
        "mount -t ceph :/ /mnt/ceph -o name=alice",
        "ls -l /mnt/ceph",
        "cp -a ${pkgs.ceph.out} /mnt/ceph/some_data",
        "df -h /mnt/ceph",
    )

    # Mount the filesystem with ceph-fuse
    bob.succeed(
        "cp /tmp/shared/ceph.client.bob.keyring /etc/ceph/",
        "mkdir -p /mnt/ceph",
        "ceph-fuse --id bob /mnt/ceph",
        "ls -l /mnt/ceph",
        "cp -a ${pkgs.ceph.out} /mnt/ceph/more_data",
        "df -h /mnt/ceph",
    )

    # Test erasure coding
    # https://docs.ceph.com/en/latest/rados/operations/erasure-code/
    admin.succeed(
        "ceph osd pool create cephfs_ec erasure",
        "ceph osd pool set cephfs_ec allow_ec_overwrites true",
        "ceph fs add_data_pool cephfs cephfs_ec",
    )
    alice.succeed(
        "mkdir /mnt/ceph/ec",
        "setfattr -n ceph.dir.layout.pool -v cephfs_ec /mnt/ceph/ec",
        "cp -a ${pkgs.ceph.out} /mnt/ceph/ec/some_data",
    )
    print(admin.succeed("ceph fs ls"))
    print(admin.succeed("ceph df"))

    # Crash some redundant nodes
    monA.crash()
    osd0.crash()
    mds0.crash()

    admin = monB
    admin.wait_until_fails("ceph -s | grep HEALTH_OK")
    print(admin.succeed("ceph -s"))
    admin.wait_until_succeeds("ceph -s | grep 'osd: 3 osds: 2 up'")
    admin.succeed("ceph -s | grep 'mon: 3 daemons'")
    admin.succeed("ceph -s | grep 'quorum ${cfg.monB.name},${cfg.monC.name} .*, out of quorum: ${cfg.monA.name}'")
    print(admin.succeed("ceph osd stat"))
    print(admin.succeed("ceph pg stat"))
    # admin.wait_until_succeeds("ceph osd stat | grep -e '3 osds: 2 up[^,]*, 3 in'")
    print(admin.succeed("ceph -s | grep 'mgr: .*(active,'"))
    admin.wait_until_succeeds("ceph -s | grep 'mds: cephfs:1.*=${cfg.mds1.name}=up'")

    # Client should still have the filesystem mounted and usable
    print(alice.succeed("df -h /mnt/ceph"))
    print(alice.succeed("ls -l /mnt/ceph"))
    alice.succeed(
        "echo hello > /mnt/ceph/world",
        # Make sure we didn't lose anything from earlier
        "diff --recursive ${pkgs.ceph.out} /mnt/ceph/some_data",
        "diff --recursive ${pkgs.ceph.out} /mnt/ceph/more_data",
        "diff --recursive ${pkgs.ceph.out} /mnt/ceph/ec/some_data",
    )
  '';


  name = "ceph-ha-cluster";
  meta = with pkgs.stdenv.lib.maintainers; {
    maintainers = [ aij ];
  };
})
