# automous-zones
A wireguard mesh network that underpins computer-club infrastructure. Its used as tunneling layer that lets us play games, share files, host services, etc.


To Join add yourself to the peer list inside `flake.nix`

- 1) Fork this repository,
- 2) Generate a wireguard key, 
- 3) Fill in the following information
``` nix
  # peers.nix
  {
    your-hostname.publicKey = "..."; # wg genkey | tee private-key | wg pubkey
    ...
  };
```
- 4) `nix run .#update-inventory | jq > inventory.json` 
- 5) `git commit -m "add: your-hostname"` Setup a pull request on this repository.

And you're done.

See [0001-luninet.md](./0001-luninet.md)


## FAQ
What do you have access to:
  - whatever peers have known endpoints is what you can reach at any given time.
  - some peers have `selfEndpoint` which lets you connect to them anytime.
  - All the IP addresses under 172.16.2.1 - 172.16.2.254 are routed under the VPN, which is everything you potentially have access to.
  
Can people connect to me without me knowing:
  - No one can connect to you.
  
    Except, on the occasion that you try connecting to a peer with `selfEndpoint` defined, or yourself have defined `selfEndpoint`. Then in fact, they can connect back to you while a pathway is established.
  
    If this is of concern to you, 
    make sure to include firewall rules at the endpoint which is hosting the private key to drop incoming connections. (This is the default policy on most OS's)

Can I turn off wireguard?:
  - You absolutely do not need this VPN running all the time.

Does this mask my traffic like NordVPN?:
  - No, we do not forward public WAN traffic. The setup is a split VPN

What is a split VPN?:
  - A split VPN is a configuration where sometimes traffic is encapsulated. 
  In the case of this network, only 172.16.2.0/24 is encapsulated, so only packets
  addressed to them will be sent through the VPN.
  
Why can I not ping anyone?:
  - If you were just recently added to the peer list, everyone who you wish to connect to must first update their peer list with your newly added keys. Some peers may never include your keys on the interface. If you lost access to a particular peer, try updating this configuration. They may updated their configuration.

## Support options
----

### wg-quick

wg-quick configuration [wg-asluni.conf](https://github.com/the-computer-club/automous-zones/releases/download/latest/wg-asluni.conf)

#### To automatically update
```sh
#!/usr/bin/env sh
curl https://github.com/the-computer-club/automous-zones/releases/download/latest/wg-asluni.conf > /tmp/latest-asluni.conf
cat /var/secrets/asluni.tmpl /tmp/latest-asluni.conf > /var/lib/wireguard/asluni.conf
rm /tmp/latest-asluni.conf
```


#### build from source
```sh
nix eval github:the-computer-club/automous-zones#nixosModules.asluni.wireguard.networks.asluni.peers.by-name --apply "x: {Peer = builtins.attrValues ((builtins.mapAttrs(name: peer: { AllowedIPs = peer.ipv4; PublicKey = peer.publicKey; } // (if peer ? selfEndpoint then { Endpoint = peer.selfEndpoint; } else {}) )) x);}" --json | remarshal --if json --of toml | sed 's/"//g' | sed 's/\[\[/\[/g' | sed 's/\]\]/\]/g' | sed "s/\[1/1/" | sed "s/2\]/2/g"
```


## Nixos Flake
If you're using NixOS flakes, then the minimal configuration is.
```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    automous-zones.url = "github:the-computer-club/automous-zones";
  };
  outputs = inputs @ {
    self,
    nixpkgs,
    automous-zones,
    ...
  }: {
    nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      specialArgs = {inherit inputs;};
      modules = [
        {
          networking.wireguard.interfaces.asluni = let
            # asluni can be anything.
            peers = inputs.automous-zones.flakeModules.asluni.wireguard.networks.asluni.peers.by-name;
            aslib = inputs.automous-zones.lib;
            self' = peers.${config.networking.hostName}
          in {
            privateKeyFile = "/var/lib/wireguard/key";
            generatePrivateKeyFile = true;
            peers = aslib.toNonFlakeParts peers; # this is where the magic happens
            ips = self'.ipv4 ++ self'.ipv6;
          };
        }
        ./configuration.nix
        ./hardware-configuration.nix
      ];
    };
  };
}
```


### Using Flake-guard v1

https://github.com/the-computer-club/lynx/tree/main/flake-modules/flake-guard

This just reduces the need for setting up the private keying information yourself.

```nix
{ self, config, lib, pkgs, ... }:
let
  net = config.networking.wireguard.networks;
in
{
  imports = [ 
     self.nixosModules.flake-guard-host
     # at one point or another we depreciated `networking.wireguard.networks`
     # but is maintained on v1
     { networking.wireguard.networks = inputs.asluni.nixosModules.asluni.wireguard.networks;  }
  ];
  
  sops.secrets.asluni.mode = "0400";
  
  networking.firewall.interfaces = {
    eno1.allowedUDPPorts = [
      net.asluni.self.listenPort
    ];
    
    asluni.allowedTCPPorts = [ 22 80 443 ];
  };

  networking.wireguard.networks = {
    asluni.autoConfig = {
      interface = true;
      peers = true;
    };
  };
}
```

### Using Flake-guard v2
[see documentation for flake-guard v2](https://github.com/the-computer-club/lynx/blob/flake-guard-v2/flake-modules/flake-guard/docs/quickstart.md)

likewise

``` nix

{ self, config, lib, pkgs, ... }:
let
  net = config.networking.wireguard.networks;
in
{
  imports = [ 
     inputs.lynx.nixosModules.flake-guard-host
     inputs.asluni.nixosModules.asluni
  ];
  
  sops.secrets.asluni.mode = "0400";
  
  wireguard.defaults.autoConfig = {
    openFirewall = mkDefault true;

    "networking.wireguard" = {
      interface.enable = mkDefault true;
      peers.mesh.enable = mkDefault true;
    };

    "networking.hosts" = {
      FQDNs.enable = mkDefault true;
      names.enable = mkDefault true;
    };
  };
  
  wireguard.networks.asluni = {
    secretsLookup = "sopsValue";

    autoConfig."networking.wireguard" = {
      interface.enable = true;
      peers.mesh.enable = true;
    };
  };
}
```

## DNS Support

### resolv.conf

``` sh
echo "nameserver 172.16.2.2" | resolvconf -a asluni -m 0 -x
```

### systemd-resolved

```sh
sudo systemd-resolve -i asluni --set-dns=172.16.2.6:5333 --set-dns=172.16.2.6:5334
resolvectl domain asluni luni. _wireguard._udp.luni.b32.
```

### dnscrypt

```nix
services.dnscrypt-proxy2.settings.forwarding = pkgs.writeText "forwarding_rules.txt" ''
  luni 172.16.2.2:5334
  luni.b32 172.16.2.2:5333
'';
```


### Wireguard named keys.

![screenshot](imgs/image.png?height=100)


### Nix

try it out before you buy it.
```sh
WG_NAME="https://github.com/the-computer-club/automous-zones/releases/download/latest/name.json" sudo -E nix run github:the-computer-club/lynx/flake-guard-v2#wireguard-tools -- show
```

### NixOS
---
If you include `inputs.flake-guard-v2.url = github:the-computer-club/lynx/flake-guard-v2` 
as an input to your flake, it provides `packages.x86_64-linux.wireguard-tools`


```nix
{ config, lib, pkgs, ... }:
let
  peerNames =
    lib.foldl' lib.recursiveUpdate { }
      (lib.mapAttrsToList
        (network-name: network:
          lib.mapAttrs' (k: v: lib.nameValuePair v.publicKey { name = k; })
            network.peers.by-name
        )
        config.wireguard.build.networks
      );
in
{
  options.wireguard.named.enable =
    lib.mkEnableOption "enable names on 'wg show <interface|all>'";

  config = lib.mkIf config.wireguard.named.enable {
    environment.sessionVariables.WG_NAME = lib.mkDefault
      "path:///etc/wireguard/name.json";

    environment.etc."wireguard/name.json".source =
      builtins.toFile "name.json"
        (builtins.toJSON peerNames);

     environment.systemPackages = [
         inputs.flake-guard-v2.packages.${pkgs.system}.wireguard-tools;
     ];
  };
}
```

Now run.
```sh
sudo wg show
```
should show names as seen above in the screenshot

### Linux
---
Download `pkgs/wg-name/wg-name` from flake-guard-v2

Create this file
```sh
#!/usr/bin/env sh
# wireguard-entry-point.sh
excludeWord=( interfaces -h --help )
if [[ "\$1" == "show" ]]; then
  if [[ " ${excludeWord[*]} " =~ " $2 " ]] || [[ "$3" != "" ]]; then
    /bin/wg-original ${@:1}
    exit 0
  fi
  PROGRAM="wg-original" /bin/wg-name ${@:2}
else /bin/wg-original ${@:1}
fi
```

And then do the following installation
```sh
mv /bin/wg /bin/wg-original
mv wg-name /bin/wg-name
mv wireguard-entry-point.sh /bin/wg

chmod +x /bin/wg /bin/wg-name
chown root:root /bin/wg /bin/wg-name

echo "WG_NAME=https://github.com/the-computer-club/automous-zones/releases/download/latest/name.json" >> ~/.profile
```

Now run.
```sh
sudo wg show
```
should show names as seen above in the screenshot


