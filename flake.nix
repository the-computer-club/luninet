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

    
    aslunip2p-peerlist.wireguard.networks.aslunip2p.peers.by-name = import ./p2p-peers.nix;
    
    peerRecord = p:
      let parse = p: field:
        if p ? "${field}"
        then map (x: (builtins.head (builtins.split "/" x))) p.${field}
        else [];
      in {
        A = parse p "ipv4";
        AAAA = parse p "ipv6";
      };

    subdomains = peer: nixpkgs.lib.foldl' (s: x: { ${x} = peerRecord peer; } // s) {};
    # ---- the peers, as a consumer needs them ---------------------------------
    # One entry per luninet peer, with the *one* IPv4 and the *one* IPv6 address
    # it owns, so a controller does not have to know how luninet's inventory
    # happens to spell them (a list per family, one entry per controller).
    #
    # This is the shape `@ccpkgs/mikrotik/luninet-peers` takes: `allowedIPs` is
    # what the controller routes to that peer -- its /32 and its /64 -- and
    # `endpoint` is only set for peers that can be dialled.
    luninetPeers =
      let
        lib' = nixpkgs.lib;
        isController = v: v.isController or false;
        entry = name: v: {
          inherit name;
          publicKey = v.publicKey or null;
          ipv4 = lib'.head (v.ipv4 or [ ]);
          ipv6 = lib'.head (v.ipv6 or [ ]);
          selfEndpoint = v.selfEndpoint or null;
          allowedIPs = (v.ipv4 or [ ]) ++ (v.ipv6 or [ ]);
        };
        peers = lib'.filterAttrs (_: v: !(isController v) && v ? publicKey) luninet-full;
      in
      lib'.mapAttrs' (name: v: lib'.nameValuePair name (entry name v)) peers;

    # ---- the address space, as data -----------------------------------------
    # `lib/fabric` (vendored from ComputerClub/ccpkgs; see lib/README.md) checks
    # the inventory's pins against each other -- duplicates, gateways, blocks
    # that overlap. The inventory stays the oracle: every host id and every IPv6
    # address below comes from it, so nothing renumbers.
    fabricLib = import ./lib/fabric.nix {
      lib = nixpkgs.lib;
      ipv4 = import ./lib/ipv4.nix;
      ipv6 = import ./lib/ipv6.nix;
    };

    fabricNet = fabricLib.eval { modules = [ ./fabric/data.nix ]; };

    fabricMismatches =
      let
        lib' = nixpkgs.lib;
        controllers = lib'.attrNames (lib'.filterAttrs (_: v: v.isController or false) luninet-full);
        expected = lib'.concatMap
          (host: lib'.imap0
            (i: cidr: { inherit host; iface = "wg-${lib'.elemAt controllers i}"; want = cidr; })
            luninet-full.${host}.ipv4)
          (lib'.attrNames (lib'.filterAttrs (_: v: v ? ipv4) luninet-full));
        actual = e:
          let a = fabricNet.addresses.${e.host}.${e.iface} or null;
          in if a == null then null else "${a.address}/${toString a.prefixLength}";
      in
      map (e: "${e.host}.${e.iface}: the inventory says ${e.want}, the fabric says ${toString (actual e)}")
        (builtins.filter (e: actual e != e.want) expected);
  in
  {
    # The address space as an output: this is what a consumer (lunix) reads
    # instead of running the allocator. `fabricNet.assertions` must be empty.
    inherit fabricNet luninetPeers;
    fabric = fabricNet;

    checks.x86_64-linux =
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        verdict = name: problems:
          if problems == [ ]
          then pkgs.runCommand name { } "touch $out"
          else pkgs.runCommand name { } ''
            echo ${nixpkgs.lib.escapeShellArg (nixpkgs.lib.concatStringsSep "\n" problems)}
            exit 1
          '';
      in
      {
        fabric = verdict "fabric" (map (a: a.message) fabricNet.assertions);
        fabric-parity = verdict "fabric-parity" fabricMismatches;
      };

    lib = {
      toPeer = toPeers;
      inherit toPeers toNonFlakeParts peerRecord subdomains;
    };

    flakeModules.asluni = luninetModule;
    nixosModules.asluni = luninetModule;
    nixosModules.aslunip2p-peerlist = aslunip2p-peerlist;
    nixosModules.aslunip2p-client = {
      imports = [
        ./p2pnet.nix
        aslunip2p-peerlist
      ];
    };
    
    zones = {  
      "unallocatedspace.luni" = {
        NS = ["unallocatedspace.luni."];
        SOA = {
          nameServer = "unallocatedspace.luni.";
          adminEmail = "contact@unallocatedspace.luni";
          serial = 2026102802; # 2026-10-28-02 (searx)
        };
        
        A = ["172.29.83.1"];

        # inherit NS SOA;
        subdomains =
          (nixpkgs.lib.mapAttrs
            (k: p: (peerRecord p))
            luninet-full)
          //
          (subdomains { ipv4 = ["172.29.83.1"]; } [
            "airsonic"
            "buildbot"
            "codex"
            "tape"
            "ca"
            "lowendtalk"
            "doh"
            "cache"
            "pgadmin"
            "observe"
            # The MCP gateway on wasp (Infra/lunix, machines/wasp/mcp-gateway.nix):
            # one endpoint in front of the fleet's MCP servers, key-gated at nginx.
            "mcp"
            # SearXNG on wasp (Infra/lunix, machines/wasp/searx.nix): the club's
            # meta search front-end, served by the same nginx and behind the mesh
            # allow-list. The record is what lets its certificate be ordered.
            "searx"
          ]);
      };
    };

    packages = nixpkgs.lib.genAttrs ["x86_64-linux"] (system:
    let
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      peerToml = filename: controllersOnly:
        let
          header = ''
            [Interface]
            Name = luni
            DNS = 172.29.83.1
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
          (pkgs.writeText "luni-${filename}.conf"
            ''
            ${header}
            ${body}
            ''
          );

      mapMikrotik = controllersOnly:
        let
          isController = p: p ? isController && p.isController;
          peers = lib.mapAttrsToList (k: v: v // { hostname = k; }) luninet-full;
          filtered = if controllersOnly then lib.filter isController peers else peers;
        in
          map (p:
            let
              parts = if p?selfEndpoint then lib.splitString ":" p.selfEndpoint else [];
              host = if parts != [] then builtins.head parts else "";
              port = if parts != [] then builtins.elemAt parts 1 else 0;
              
            in
          {
            "public-key" = p.publicKey or "";
            "allowed-address" = lib.concatStringsSep "," ((p.ipv4 or []) ++ (p.ipv6 or []));
            "name" = p.hostname;
            "persistent-keepalive" = p.persistentKeepalive or 0;
            "endpoint-address" = host;
            "endpoint-port" = port;
          }) filtered;

     peerNames = controllersOnly:
       let
         isController = p: p ? isController && p.isController;
         peers = if controllersOnly then lib.filterAttrs (_: isController) luninet-full else luninet-full;
       in
         lib.foldl' lib.recursiveUpdate { }
           (lib.mapAttrsToList
             (network-name: network:
               lib.mapAttrs' (k: v: lib.nameValuePair (lib.trim v.publicKey) { name = k; })
                 network.peers.by-name
             ) 
             { luni.peers.by-name = peers; }
           );
    in
      rec {
        peer-names-json = pkgs.writeText "luninet-names.json" (builtins.toJSON (peerNames true));
        controller-names-json = pkgs.writeText "luninet-names.json" (builtins.toJSON (peerNames false));
        quick-peer-toml = peerToml "peer" true;
        quick-controller-toml = peerToml "controller" false;
        
        mikrotik-controller-json = pkgs.writeText "controller.json" (builtins.toJSON (mapMikrotik false));
        mikrotik-peer-json = pkgs.writeText "peercfg.json" (builtins.toJSON (mapMikrotik true));
        
        buildArtifacts = pkgs.stdenvNoCC.mkDerivation {
          name = "build-artifacts";

          dontUnpack = true;

          buildPhase = ''
            mkdir $out
            cp ${peer-names-json} $out/peer-names.json
            cp ${controller-names-json} $out/controller-names.json
            cp ${quick-peer-toml} $out/luni-peer.conf
            cp ${quick-controller-toml} $out/luni-controller.conf
            cp ${mikrotik-peer-json} $out/luni-peers.json
            cp ${mikrotik-controller-json} $out/luni-controllers.json
          '';
        };

        mikrotik-convert = pkgs.writeShellScriptBin "mikrotik-convert"
          ''
          PATH=${pkgs.jq}/bin ${./mikrotik/convert.sh} $@
          '';        
        
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
