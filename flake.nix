{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  outputs = {nixpkgs, ...}:
  let
    toNonFlakeParts = data: (nixpkgs.lib.mapAttrsToList toPeers data);

    toPeers = v: {
      publicKey = v.publicKey;
      allowedIPs = (v.ipv4 or []) ++ (v.ipv6 or []);
      endpoint = v.selfEndpoint or null;
      persistentKeepalive = v.persistentKeepalive or null;
    };

    luninet = import ./peers.nix;

    luninet-full =
      nixpkgs.lib.recursiveUpdate
        luninet
        (builtins.fromJSON (builtins.readFile ./inventory.json)).network;

    luninetModule.wireguard.networks.luni.peers.by-name = luninet-full;
  in
  {
    lib = {
      toPeer = toPeers;
      inherit toPeers toNonFlakeParts;
    };

    flakeModules.asluni = luninetModule;
    nixosModules.asluni = luninetModule;

    packages = nixpkgs.lib.genAttrs ["x86_64-linux"] (system:
    let
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      peerToml = name: controllersOnly:
        let
          header = ''
            [Interface]
            Name = luni
            DNS = 172.25.112.1
            PrivateKey = 0000000000000000000000000
          '';

          body = (lib.pipe luninet-full [
            (lib.mapAttrsToList (k: p: p // {hostname=k;}))
            (x:
              let
                isController = p: p ? isController && p.isController;
              in
              if controllersOnly then
                lib.filter(isController) x
              else x
            )
            (map (p: lib.trim ''
              [Peer]
              # Name = ${p.hostname}
              PublicKey = ${p.publicKey or ""}
              AllowedIPs = ${lib.concatStringsSep ", " ((p.ipv4 or [])  ++ (p.ipv6 or []))}
              ${if p?endpoint then "Endpoint = ${p.endpoint or ""}" else ""}
              ${if p?persistentKeepalive then "PersistentKeepalive = ${p.persistentKeepalive or ""}" else ""} 
              '')
            )
            (lib.concatStringsSep "\n")
          ]);
        in
          (pkgs.writeText "luni-${name}.conf"
            ''
            ${header}
            ${body}
            ''
          );

      mapMikrotik =
        lib.mapAttrsToList (name: value: {
          "public-key" = value.publicKey;
          "allowed-address" = lib.concatStringsSep "," ((value.ipv4 or []) ++ (value.ipv6 or []));
          "comment" = name;
        }) luninet-full;

    peerNames = lib.foldl' lib.recursiveUpdate { }
      (lib.mapAttrsToList
        (network-name: network:
          lib.mapAttrs' (k: v: lib.nameValuePair (lib.trim v.publicKey) { name = k; })
            network.peers.by-name
        )
        { luni.peers.by-name = luninet-full; }
      );
      
    in
      rec {
        names-json = pkgs.writeText "luninet-names.json" (builtins.toJSON peerNames);
        quick-peer-toml = peerToml "peer" true;
        quick-controller-toml = peerToml "controller" false;
        
        mikrotik-controller-json = pkgs.writeText "controllercfg.json" (builtins.toJSON mapMikrotik) ;
        mikrotik-peer-json = pkgs.writeText "peercfg.json" (builtins.toJSON mapMikrotik);
        
        mikrotik-convert = pkgs.writeShellScriptBin "mikrotik-convert"
          ''
          PATH=${pkgs.jq}/bin ${./mikrotik/convert.sh} $@
          '';        

        buildArtifacts = pkgs.stdenvNoCC.mkDerivation {
          name = "build-artifacts";

          dontUnpack = true;

          buildPhase = ''
            mkdir $out
            cp ${names-json} $out/names.json
            cp ${quick-peer-toml} $out/peer-luni.conf
            cp ${quick-controller-toml} $out/controller-luni.conf
            cp ${mikrotik-controller-json} $out/mikrotik-controllers.json
            cp ${mikrotik-peer-json} $out/mikrotik-peer.json
          '';
        };

        json = pkgs.writeText "current-inventory.json"
          (builtins.toJSON luninet);
        
        ip-allocate = pkgs.writeShellScriptBin "ip-allocate"
          ''
          ${pkgs.python3}/bin/python ${./ip-allocate.py} $@
          '';
        
        update-inventory = pkgs.writeShellScriptBin "update-inventory"
          ''
          ${pkgs.lib.getExe ip-allocate} \
              --tenant 23 \
              --controller 24 \
              --root 172.29.80.0/23 \
              --6peer 64 \
              --6base 9 \
              --6controller 48 \
              --6instance-bits 1 luni ${
                pkgs.writeText "current-inventory.json"
                  (builtins.toJSON luninet)
              }

              '';
    });
  };
}
