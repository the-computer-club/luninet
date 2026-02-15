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
    in
      rec {
        wg-quick-controller = peerToml "controller" false;
        wg-quick = peerToml "peer" true;
        default = wg-quick;
        
        ip-allocate = pkgs.writeShellScriptBin "ip-allocate"
          ''
          ${pkgs.python3}/bin/python ${./ip-allocate.py} $@
          '';

        update-inventory = pkgs.writeShellScriptBin "update-inventory"
          ''
          ${pkgs.lib.getExe ip-allocate} luni ${
            pkgs.writeText "current-inventory.json"
              (builtins.toJSON luninet)
          }
          '';
    });
  };
}
