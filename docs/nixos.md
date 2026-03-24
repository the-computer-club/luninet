 # NixOS Setup

Three configuration styles are supported depending on what you're using. Pick the one that matches your setup.

- [Plain Flake](#plain-flake) — no extra dependencies, just nixpkgs and automous-zones
- [Flake-guard v1](#flake-guard-v1) — reduces boilerplate around private key management
- [Flake-guard v2](#flake-guard-v2) — current generation, declarative mesh config with autoConfig

---

## Plain Flake

The minimal setup. Requires only `nixpkgs` and the `automous-zones` flake input.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    automous-zones.url = "github:the-computer-club/automous-zones";
  };

  outputs = inputs @ { self, nixpkgs, automous-zones, ... }: {
    nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        {
          networking.wireguard.interfaces.asluni =
            let
              peers  = inputs.automous-zones.flakeModules.asluni.wireguard.networks.asluni.peers.by-name;
              aslib  = inputs.automous-zones.lib;
              self'  = peers.${config.networking.hostName};
            in {
              privateKeyFile        = "/var/lib/wireguard/key";
              generatePrivateKeyFile = true;
              peers = aslib.toNonFlakeParts peers;
              ips   = self'.ipv4 ++ self'.ipv6;
            };
        }
        ./configuration.nix
        ./hardware-configuration.nix
      ];
    };
  };
}
```

> Your hostname must match the key you registered in `peers.nix`.

---

## Flake-guard v1

Flake-guard v1 reduces boilerplate around private key handling and firewall rules.

```nix
{ self, config, lib, pkgs, inputs, ... }:
let
  net = config.networking.wireguard.networks;
in {
  imports = [
    self.nixosModules.flake-guard-host
    {
      # flake-guard v1 still uses networking.wireguard.networks
      networking.wireguard.networks =
        inputs.asluni.nixosModules.asluni.wireguard.networks;
    }
  ];

  sops.secrets.asluni.mode = "0400";

  networking.firewall.interfaces = {
    # Allow WireGuard handshakes on your uplink interface
    eno1.allowedUDPPorts = [
      net.asluni.self.listenPort
    ];
    # Allow services over the VPN interface
    asluni.allowedTCPPorts = [ 22 80 443 ];
  };

  networking.wireguard.networks = {
    asluni.autoConfig = {
      interface = true;
      peers     = true;
    };
  };
}
```

---

## Flake-guard v2

Flake-guard v2 is the current generation. See the full [quickstart docs](https://github.com/the-computer-club/lynx/blob/flake-guard-v2/flake-modules/flake-guard/docs/quickstart.md) for details.

```nix
{ self, config, lib, pkgs, inputs, ... }:
let
  net = config.networking.wireguard.networks;
in {
  imports = [
    inputs.lynx.nixosModules.flake-guard-host
    inputs.asluni.nixosModules.asluni
  ];

  sops.secrets.asluni.mode = "0400";

  # Defaults applied to all networks unless overridden
  wireguard.defaults.autoConfig = {
    openFirewall = lib.mkDefault true;

    "networking.wireguard" = {
      interface.enable = lib.mkDefault true;
      peers.mesh.enable = lib.mkDefault true;
    };

    "networking.hosts" = {
      FQDNs.enable = lib.mkDefault true;
      names.enable = lib.mkDefault true;
    };
  };

  wireguard.networks.asluni = {
    secretsLookup = "sopsValue";

    autoConfig."networking.wireguard" = {
      interface.enable  = true;
      peers.mesh.enable = true;
    };
  };
}
```

---

## Private Key Management

If you are not using flake-guard and need to manage the private key yourself, generate it and store it outside the Nix store:

```sh
sudo mkdir -p /var/lib/wireguard
wg genkey | sudo tee /var/lib/wireguard/key
sudo chmod 600 /var/lib/wireguard/key
```

Then reference it in your config:

```nix
networking.wireguard.interfaces.asluni.privateKeyFile = "/var/lib/wireguard/key";
```

The `generatePrivateKeyFile = true` option will do this automatically but will generate a new key on first activation — make sure the resulting public key matches what you submitted in `peers.nix`.

