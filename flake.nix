{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  outputs = {nixpkgs, ...}:
  let
    toNonFlakeParts = data: (nixpkgs.lib.mapAttrsToList toPeers data);

    toPeers = n: v: {
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

    wireguard.networks.luni.peers.by-name = luninet-full;
  in
  {
    inherit wireguard;

    lib = { inherit toPeers toNonFlakeParts; };
    flakeModules.asluni = { inherit wireguard; };
    nixosModules.asluni = { inherit wireguard; };

    packages = nixpkgs.lib.genAttrs ["x86_64-linux"] (system:
    let
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
    in
    rec {
      ipv6-allocate = pkgs.writeShellScriptBin "ipv6-allocate"
        ''
        ${pkgs.python3}/bin/python ${./ipv6-allocate.py} $@
        '';

      update-inventory = pkgs.writeShellScriptBin "update-inventory"
        ''
        ${pkgs.lib.getExe ipv6-allocate} luni ${
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
