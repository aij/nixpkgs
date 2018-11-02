{ lib, config, pkgs, ... }:

with lib;

let

  cfg = config.services.xmrig-proxy;

  pkg = pkgs.xmrig-proxy;

  confArg = optionalString (cfg.configText != "") ("-c " +
    pkgs.writeText "xmrig-proxy-config.json" cfg.configText);

in

{
  options = {
    services.xmrig-proxy = {
      enable = mkEnableOption "xmrig proxy";

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "-S --api-port 8888 --api-worker-id xmrigproxy -b 0.0.0.0:3333 -o cryptonightv7.usa.nicehash.com:3363 -u 37xxrZgNu8ytQfEFo6jVC9nJ4tAEb73URJ.proxy -p x --variant 1 -o xmr-usa.dwarfpool.com:8005 -u 42yuVh16tr3ExsVGHzXcdv7P7nrQynyYAF6Jf9hmTkemTictk7FQcFXB2ANWqgxh8uEc2DmPFAtgrdGooERzCvtjE3mkrYp -p monero@mrph.org --variant 1" ];
        description = "List of parameters to pass to xmrig-proxy.";
      };

      configText = mkOption {
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
          Verbatim xmrig-proxy config.json. If empty, the <literal>-c</literal>
          parameter will not be added to the xmr-stak command.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # TODO: assert config or extraArgs
    systemd.services.xmrig-proxy = {
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "network-online.target" ];
      after = [ "network-online.target" ];
      script = ''
        exec ${pkg}/bin/xmrig-proxy ${confArg} ${concatStringsSep " " cfg.extraArgs}
      '';
      serviceConfig = {
        DynamicUser = true;
      };
    };
  };
}
