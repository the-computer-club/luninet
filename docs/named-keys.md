# Named Keys

By default, `wg show` identifies peers by their public key — a 44-character base64 string. The `wg-name` tool replaces those with human-readable hostnames from the peer list.

![Screenshot of wg show with named peers](imgs/image.png)

---

## NixOS

If you include `flake-guard-v2` as a flake input, it provides a patched `wireguard-tools` package with naming support built in.

```nix
# In your flake inputs
inputs.flake-guard-v2.url = "github:the-computer-club/lynx/flake-guard-v2";
```

Then enable named keys in your NixOS config:

```nix
{ config, lib, pkgs, inputs, ... }:
let
  peerNames =
    lib.foldl' lib.recursiveUpdate { }
      (lib.mapAttrsToList
        (network-name: network:
          lib.mapAttrs'
            (k: v: lib.nameValuePair v.publicKey { name = k; })
            network.peers.by-name
        )
        config.wireguard.build.networks
      );
in {
  options.wireguard.named.enable =
    lib.mkEnableOption "enable names on 'wg show <interface|all>'";

  config = lib.mkIf config.wireguard.named.enable {
    environment.sessionVariables.WG_NAME =
      lib.mkDefault "path:///etc/wireguard/name.json";

    environment.etc."wireguard/name.json".source =
      builtins.toFile "name.json" (builtins.toJSON peerNames);

    environment.systemPackages = [
      inputs.flake-guard-v2.packages.${pkgs.system}.wireguard-tools
    ];
  };
}
```

Then enable it:

```nix
wireguard.named.enable = true;
```

Run `sudo wg show` and peers will be identified by hostname.

---

## Try It Without Installing

```sh
WG_NAME="https://github.com/the-computer-club/automous-zones/releases/download/latest/name.json" \
  sudo -E nix run github:the-computer-club/lynx/flake-guard-v2#wireguard-tools -- show
```

---

## Linux (non-NixOS)

### 1. Download wg-name

Download `wg-name` from the flake-guard-v2 release artifacts, or build it with:

```sh
nix build github:the-computer-club/lynx/flake-guard-v2#wg-name
```

### 2. Install alongside the existing wg binary

```sh
# Back up the original wg binary
sudo mv /usr/bin/wg /usr/bin/wg-original

# Install wg-name
sudo install -m 755 wg-name /usr/bin/wg-name
```

### 3. Create a wrapper script

Save the following as `/usr/bin/wg` and make it executable:

```sh
#!/usr/bin/env sh
# /usr/bin/wg — wrapper that adds peer name resolution to wg show

excludeWords="interfaces -h --help"

if [ "$1" = "show" ]; then
  for word in $excludeWords; do
    if [ "$2" = "$word" ] || [ -n "$3" ]; then
      exec /usr/bin/wg-original "$@"
    fi
  done
  PROGRAM="wg-original" exec /usr/bin/wg-name "${@:2}"
else
  exec /usr/bin/wg-original "$@"
fi
```

```sh
sudo chmod +x /usr/bin/wg
sudo chown root:root /usr/bin/wg /usr/bin/wg-name
```

### 4. Set the name source

Add to your `~/.profile` or `~/.bashrc`:

```sh
export WG_NAME="https://github.com/the-computer-club/automous-zones/releases/download/latest/name.json"
```

Or use the local file (faster, works offline):

```sh
export WG_NAME="path:///etc/wireguard/name.json"
```

### 5. Verify

```sh
sudo wg show
# Peers should now display hostnames instead of raw public keys
```

