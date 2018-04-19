{ lib, config, pkgs, ... }:

with lib;

let

  cfg = config.services.xmr-stak;

  pkg = pkgs.xmr-stak.override {
    inherit (cfg) openclSupport cudaSupport;
  };

  xmrConfArg = optionalString (cfg.configText != "") ("-c " +
    pkgs.writeText "xmr-stak-config.txt" cfg.configText);
  xmrPoolArg = optionalString (cfg.poolConfigText != "") ("--poolconf " +
    pkgs.writeText "xmr-stak-pools.txt" cfg.poolConfigText);

in

{
  options = {
    services.xmr-stak = {
      enable = mkEnableOption "xmr-stak miner";
      openclSupport = mkEnableOption "support for OpenCL (AMD/ATI graphics cards)";
      cudaSupport = mkEnableOption "support for CUDA (NVidia graphics cards)";

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "--noCPU" "--currency monero" ];
        description = "List of parameters to pass to xmr-stak.";
      };

      configText = mkOption {
        type = types.lines;
        default = "";
        example = ''
          "daemon_mode" : true,
          "h_print_time" : 600,
          "verbose_level" : 4,
          "httpd_port" : 0,
        '';
        description = ''
          Verbatim xmr-stak config.txt. If empty, the <literal>-c</literal>
          parameter will not be added to the xmr-stak command.
        '';
      };

      poolConfigText = mkOption {
        type = types.lines;
        default = "";
        example = ''
          "currency" : "monero",
          "pool_list" :
            [ { "pool_address" : "pool.supportxmr.com:5555",
                "wallet_address" : "<long-hash>",
                "pool_password" : "minername",
                "pool_weight" : 1,
              },
            ],
        '';
        description = ''
          Verbatim xmr-stak pool.txt. If empty, the <literal>--poolconf</literal>
          parameter will not be added to the xmr-stak command.
        '';
      };

      niceness = mkOption {
        type = types.int;
        default = 0;
        example = 10;
        description = "Niceness adjustment";
      };
      extraServiceConfig = mkOption {
        type = types.attrs;
        default = {};
        example = {
          LimitMEMLOCK = "256M";
        };
        description = "Extra options for the systemd service config.";
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.xmr-stak = {
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = mkIf cfg.cudaSupport {
        LD_LIBRARY_PATH = "${pkgs.linuxPackages_latest.nvidia_x11}/lib";
      };
      script = ''
        exec nice -n ${toString cfg.niceness} ${pkg}/bin/xmr-stak ${xmrConfArg} ${xmrPoolArg} ${concatStringsSep " " cfg.extraArgs}
      '';
      serviceConfig = let rootRequired = cfg.openclSupport || cfg.cudaSupport; in {
        # xmr-stak generates cpu and/or gpu configuration files
        WorkingDirectory = "/tmp";
        PrivateTmp = true;
        DynamicUser = !rootRequired;
        LimitMEMLOCK = "128M";
      } // cfg.extraServiceConfig;
    };
  };
}
