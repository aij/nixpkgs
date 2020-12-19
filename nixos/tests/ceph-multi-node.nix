import ./make-test-python.nix ({pkgs, lib, ...}:

let
  cfg = {
    clusterId = "066ae264-2a5d-4729-8001-6ad265f50b03";
    monA = {
      name = "a";
      ip = "192.168.1.1";
    };
    osd0 = {
      name = "0";
      ip = "192.168.1.2";
    };
    osd1 = {
      name = "1";
      ip = "192.168.1.3";
    };
    osd2 = {
      name = "2";
      ip = "192.168.1.4";
    };
    client = {
      ip = "192.168.1.5";
    };
  };
  generateCephConfig = { daemonConfig }: {
    enable = true;
    global = {
      fsid = cfg.clusterId;
      monHost = cfg.monA.ip;
      monInitialMembers = cfg.monA.name;
    };
  } // daemonConfig;

  generateHost = { pkgs, cephConfig, networkConfig, ... }: {
    virtualisation = {
      memorySize = 1024;
      emptyDiskImages = [ 20480 ];
      vlans = [ 1 ];
    };

    networking = networkConfig;

    environment.systemPackages = with pkgs; [
      bash
      sudo
      ceph
      kmod busybox
    ];

    boot.kernelModules = [ "ceph" ];

    services.ceph = cephConfig;
  };

  staticIp = address: {
    dhcpcd.enable = false;
    interfaces.eth1.ipv4.addresses = pkgs.lib.mkOverride 0 [
      { inherit address; prefixLength = 24; }
    ];
  };
  networkMonA = staticIp cfg.monA.ip // {
    firewall = {
      allowedTCPPorts = [ 6789 3300 ];
      allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    };
  };
  cephConfigMonA = generateCephConfig { daemonConfig = {
    mon = {
      enable = true;
      daemons = [ cfg.monA.name ];
    };
    mgr = {
      enable = true;
      daemons = [ cfg.monA.name ];
    };
    mds = {
      enable = true;
      daemons = [ cfg.monA.name ];
    };
  }; };

  networkOsd = osd: staticIp osd.ip // {
    firewall = {
      allowedTCPPortRanges = [ { from = 6800; to = 7300; } ];
    };
  };

  cephConfigOsd = osd: generateCephConfig { daemonConfig = {
    osd = {
      enable = true;
      daemons = [ osd.name ];
    };
  }; };

  cephConfigClient = generateCephConfig { daemonConfig = {}; };

  # Following deployment is based on the manual deployment described here:
  # https://docs.ceph.com/docs/master/install/manual-deployment/
  # For other ways to deploy a ceph cluster, look at the documentation at
  # https://docs.ceph.com/docs/master/
  testscript = { ... }: ''
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
    monA.wait_for_unit("ceph-mgr-a")
    monA.wait_until_succeeds("ceph -s | grep 'quorum ${cfg.monA.name}'")
    monA.wait_until_succeeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'")

    # Send the OSD Bootstrap keyring to the OSD machines
    monA.succeed("cp -r /var/lib/ceph/bootstrap-osd /tmp/shared")
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

    monA.succeed(
        "ceph osd pool create multi-node-test 32 32",
        "ceph osd pool ls | grep 'multi-node-test'",
        "ceph osd pool rename multi-node-test multi-node-other-test",
        "ceph osd pool ls | grep 'multi-node-other-test'",
    )
    monA.wait_until_succeeds("ceph -s | grep '2 pools, 33 pgs'")
    monA.succeed("ceph osd pool set multi-node-other-test size 2")
    monA.wait_until_succeeds("ceph -s | grep 'HEALTH_OK'")
    monA.wait_until_succeeds("ceph -s | grep '33 active+clean'")
    monA.fail(
        "ceph osd pool ls | grep 'multi-node-test'",
        "ceph osd pool delete multi-node-other-test multi-node-other-test --yes-i-really-really-mean-it",
    )

    # Bootstram an MDS
    monA.succeed(
        "sudo -u ceph mkdir -p /var/lib/ceph/mds/ceph-${cfg.monA.name}",
        "sudo -u ceph ceph-authtool --create-keyring /var/lib/ceph/mds/ceph-${cfg.monA.name}/keyring --gen-key -n mds.${cfg.monA.name}",
        # Per https://docs.ceph.com/en/latest/install/manual-deployment/ FIXME
        # "ceph auth add mds.${cfg.monA.name} osd 'allow rwx' mds 'allow' mon 'allow profile mds' -i /var/lib/ceph/mds/ceph-${cfg.monA.name}/keyring",
        # Per https://docs.ceph.com/en/latest/rados/configuration/auth-config-ref/
        "ceph auth get-or-create mds.${cfg.monA.name} mon 'allow rwx' osd 'allow *' mds 'allow *' mgr 'allow profile mds' -o /var/lib/ceph/mds/ceph-${cfg.monA.name}/keyring",
        "systemctl start ceph-mds-${cfg.monA.name}",
    )
    monA.wait_for_unit("ceph-mds-a")
    monA.wait_until_succeeds("ceph -s | grep 'HEALTH_OK'")

    # Create a ceph filesystem
    # Based on https://docs.ceph.com/en/latest/cephfs/createfs/
    monA.succeed(
        "ceph osd pool create cephfs_data",
        "ceph osd pool create cephfs_metadata",
        "ceph fs new cephfs cephfs_metadata cephfs_data",
        "ceph fs authorize cephfs client.foo / rw >/tmp/shared/ceph.client.foo.keyring",
    )
    # Mount the filesystem
    client.succeed(
        "cp /tmp/shared/ceph.client.foo.keyring /etc/ceph/ceph.client.foo.keyring",
        "mkdir -p /mnt/ceph",
        "mount -t ceph :/ /mnt/ceph -o name=foo",
        "ls -l /mnt/ceph",
        "cp -a ${pkgs.ceph.out} /mnt/ceph/some_data",
        "df -h /mnt/ceph",
    )

    # Shut down ceph on all cluster machines in a very unpolite way
    monA.crash()
    osd0.crash()
    osd1.crash()
    osd2.crash()

    # Start it up
    osd0.start()
    osd1.start()
    osd2.start()
    monA.start()

    # Ensure the cluster comes back up again
    monA.succeed("ceph -s | grep 'mon: 1 daemons'")
    monA.wait_until_succeeds("ceph -s | grep 'quorum ${cfg.monA.name}'")
    monA.wait_until_succeeds("ceph osd stat | grep -e '3 osds: 3 up[^,]*, 3 in'")
    monA.wait_until_succeeds("ceph -s | grep 'mgr: ${cfg.monA.name}(active,'")
    monA.wait_until_succeeds("ceph -s | grep 'mds: cephfs:1/1 {0=${cfg.monA.name}=up'")
    monA.succeed("ceph -s")
    # I'm getting HEALTH_WARN due to "1 MDSs report slow metadata IOs", which
    # presumably will be dependent on the underlying hardware running the test
    # so we will consider that to be OK for the test.
    monA.wait_until_succeeds("ceph -s | grep -e HEALTH_OK -e HEALTH_WARN")

    # Client should still have the filesystem mounted and usable
    print(client.succeed("df -h /mnt/ceph"))
    print(client.succeed("ls -l /mnt/ceph"))
    client.succeed(
        # "echo hello > /mnt/ceph/world",
        # Make sure we didn't lose anything from earlier
        "diff -R ${pkgs.ceph.out} /mnt/ceph/some_data",
    )
  '';
in {
  name = "basic-multi-node-ceph-cluster";
  meta = with pkgs.stdenv.lib.maintainers; {
    maintainers = [ lejonet ];
  };

  nodes = {
    monA = generateHost { pkgs = pkgs; cephConfig = cephConfigMonA; networkConfig = networkMonA; };
    osd0 = generateHost { pkgs = pkgs; cephConfig = cephConfigOsd cfg.osd0; networkConfig = networkOsd cfg.osd0; };
    osd1 = generateHost { pkgs = pkgs; cephConfig = cephConfigOsd cfg.osd1; networkConfig = networkOsd cfg.osd1; };
    osd2 = generateHost { pkgs = pkgs; cephConfig = cephConfigOsd cfg.osd2; networkConfig = networkOsd cfg.osd2; };
    client = generateHost { pkgs = pkgs; cephConfig = cephConfigClient; networkConfig = staticIp cfg.client.ip; };
  };

  testScript = testscript;
})
