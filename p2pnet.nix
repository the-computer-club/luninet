{ config, lib, pkgs, ... }:

let
  wgsd =
    pkgs.buildGoModule rec {
      pname = "wgsd";
      version = "0.3.5";

      src = pkgs.fetchFromGitHub {
        owner = "jwhited";
        repo = "wgsd";
        rev = "v${version}";
        sha256 = "sha256-mHB9QeRet/OlmdTKetu3O8jDAG2xWA2bS098jY9VpwU=";
      };

      vendorHash = "sha256-4K+k79igvlVTTMn1sIbcNTZLJiT7tXsH+epREyv5QiE=";

      meta = with lib; {
        description = "A CoreDNS plugin that provides WireGuard peer information via DNS-SD semantics, and a client for configuring WireGuard";
        homepage = "https://github.com/jwhited/wgsd";
        platforms = platforms.linux;
      };
    };


  luninet-addr = pkgs.writeShellScript "luni-addr" ''
    echo "$1" | base64 -d | base32 | tr '[:upper:]' '[:lower:]' | sed s/=/.luni.b32./ | sed s/=//g
  '';

  cfg = config.networking.luninetp2p;
in
{
  options.networking.luninetp2p = {
    enable = lib.mkEnableOption "enable coredns/wgsd-client & wireguard";

    zone = lib.mkOption {
      type = lib.types.str;
      default = "luninet.org";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "aslunip2p";
    };

    dnsSocket = lib.mkOption {
      type = lib.types.str;
      default = "198.12.96.43:5353";
    };
    
    package = lib.mkOption {
      type = lib.types.package;
      default = wgsd;
    };
  };
  
  config = lib.mkIf cfg.enable {
    systemd.services = {
      luninetp2p-discovery = {
        description = "Luninet discovery server service";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [ cfg.package ];

        serviceConfig = {
          Restart = "always";
          User = "root";
          Group = "root";
          
          Directory = cfg.homeDir;
          ExecStart = lib.concatStringsSep " " [
            "${cfg.package}/bin/wgsd-client -device=aslunip2p -dns=172.29.83.1:5353 -zone=unallocatedspace.luni"
          ];

          CapabilityBoundingSet = lib.mkForce "cap_net_bind_service cap_net_admin";
          AmbientCapabilities = lib.mkForce "cap_net_bind_service cap_net_admin";
        };
      };
    };
    
    wireguard.networks.lunip2p.peers.by-name = import ./p2p-peers.nix;
  };
}
