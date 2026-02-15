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
        (builtins.fromJSON (builtins.readFile ./inventory.json));

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
    in
    rec {
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

      peerToml = pkgs.writeText "wgluni-peers.conf"
        (lib.pipe luninet-full [
          (map (p:
          ''
          [Peer]
          PublicKey = ${p.publicKey or ""}
          AllowedIPs = ${lib.concatStringsSep ", " ((p.ipv4 or [])  ++ (p.ipv6 or []))}
          Endpoint = ${p.endpoint or ""}
          PersistentKeepalive = ${p.persistentKeepalive or ""}
          ''))

          (lib.concatStringsSep "\n")
        ]);
      });
    };
}
