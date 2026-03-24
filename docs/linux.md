# Linux Setup

This page covers WireGuard setup on standard Linux distributions using `wg-quick`, `systemd-networkd`, or manual `ip`/`wg` commands. For NixOS, see [NixOS Setup](./nixos.md).

---

## Requirements

WireGuard is included in the Linux kernel since 5.6. Most modern distributions provide it out of the box.

```sh
# Debian / Ubuntu
sudo apt install wireguard wireguard-tools

# Fedora / RHEL
sudo dnf install wireguard-tools

# Arch Linux
sudo pacman -S wireguard-tools

# Alpine
sudo apk add wireguard-tools
```

---

## Option 1: wg-quick (Recommended)

`wg-quick` is the simplest way to get connected. It manages interface creation, routing, and teardown for you.

### Download the peer config

Download the latest generated config file (contains all current peers):

```sh
curl -L https://github.com/the-computer-club/automous-zones/releases/download/latest/wg-asluni.conf \
  -o /tmp/wg-asluni.conf
```

### Create your private key file

```sh
sudo mkdir -p /etc/wireguard
wg genkey | sudo tee /etc/wireguard/asluni.key
sudo chmod 600 /etc/wireguard/asluni.key
```

### Assemble the full config

The downloaded config contains only peer entries. You need to prepend an `[Interface]` section with your private key and assigned IP address.

Create `/etc/wireguard/asluni.conf`:

```ini
[Interface]
PrivateKey = <contents of /etc/wireguard/asluni.key>
Address = 172.16.2.X/24   # your assigned IP from peers.nix
ListenPort = 51820         # optional, needed if you have a selfEndpoint

# --- Peer list follows (append contents of wg-asluni.conf below) ---
```

Then append the downloaded peer list:

```sh
cat /tmp/wg-asluni.conf | sudo tee -a /etc/wireguard/asluni.conf
```

Or use this one-liner to do it every time you update:

```sh
#!/usr/bin/env sh
# save as /usr/local/bin/update-asluni and chmod +x
curl -fsSL https://github.com/the-computer-club/automous-zones/releases/download/latest/wg-asluni.conf \
  > /tmp/latest-asluni.conf
cat /var/secrets/asluni.tmpl /tmp/latest-asluni.conf \
  > /etc/wireguard/asluni.conf
rm /tmp/latest-asluni.conf
```

Where `/var/secrets/asluni.tmpl` holds just your `[Interface]` block.

### Bring the interface up

```sh
sudo wg-quick up asluni

# Verify
sudo wg show
```

### Bring it down

```sh
sudo wg-quick down asluni
```

You do not need to run this VPN all the time. Bring it up only when you need it.

### Start on boot (optional)

```sh
sudo systemctl enable --now wg-quick@asluni
```

---

## Option 2: systemd-networkd

If you manage networking with `systemd-networkd`, you can use `.netdev` and `.network` unit files instead of `wg-quick`.

### /etc/systemd/network/asluni.netdev

```ini
[NetDev]
Name = asluni
Kind = wireguard
Description = automous-zones mesh VPN

[WireGuard]
PrivateKeyFile = /etc/wireguard/asluni.key
ListenPort = 51820

# Repeat [WireGuardPeer] sections for each peer
[WireGuardPeer]
PublicKey = <peer public key>
AllowedIPs = 172.16.2.X/32
Endpoint = <peer endpoint if known>   # optional
PersistentKeepalive = 25              # optional, helps with NAT
```

### /etc/systemd/network/asluni.network

```ini
[Match]
Name = asluni

[Network]
Address = 172.16.2.X/24
```

### Apply

```sh
sudo systemctl restart systemd-networkd
networkctl status asluni
```

---

## Option 3: Manual Setup (ip + wg)

For scripting or environments without `wg-quick`:

```sh
# Create the interface
sudo ip link add dev asluni type wireguard

# Set your private key
sudo wg set asluni private-key /etc/wireguard/asluni.key

# Assign your IP
sudo ip address add 172.16.2.X/24 dev asluni

# Add peers
sudo wg set asluni peer <PUBLIC_KEY> \
  allowed-ips 172.16.2.Y/32 \
  endpoint <IP:PORT>           # optional

# Bring the interface up
sudo ip link set up dev asluni
```

To tear down:

```sh
sudo ip link delete dev asluni
```

---

## Building the Peer Config from Source

If you'd rather build the config directly from the Nix flake instead of using the prebuilt release:

```sh
nix eval github:the-computer-club/automous-zones#nixosModules.asluni.wireguard.networks.asluni.peers.by-name \
  --apply "x: {Peer = builtins.attrValues ((builtins.mapAttrs(name: peer: { AllowedIPs = peer.ipv4; PublicKey = peer.publicKey; } // (if peer ? selfEndpoint then { Endpoint = peer.selfEndpoint; } else {}) )) x);}" \
  --json \
  | remarshal --if json --of toml \
  | sed 's/"//g' \
  | sed 's/\[\[/\[/g' \
  | sed 's/\]\]/\]/g' \
  | sed "s/\[1/1/" \
  | sed "s/2\]/2/g"
```

---

## Verifying Connectivity

```sh
# Check interface status and peer handshakes
sudo wg show

# Check your assigned address
ip addr show asluni

# Ping another peer
ping 172.16.2.1

# Check routing
ip route show dev asluni
```

A peer will only show a recent handshake if there has been traffic between you recently. If a handshake is missing, it means no connection attempt has been made yet — not necessarily that the peer is down.

---

## Firewall Considerations

If you run a firewall (e.g. `nftables`, `iptables`, `ufw`), you may need to allow WireGuard's UDP port:

```sh
# ufw
sudo ufw allow 51820/udp

# nftables — add to your input chain
sudo nft add rule inet filter input udp dport 51820 accept

# iptables
sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
```

This is only necessary if you have defined a `selfEndpoint` (i.e. you want peers to initiate connections to you). If you only ever connect outward, no inbound rule is needed.

---

## Troubleshooting

**`RTNETLINK answers: Operation not supported`**
Your kernel may not have WireGuard support. Check: `modinfo wireguard`. On older kernels you may need to install the `wireguard-dkms` package.

**No handshake with a peer**
- Confirm they have your public key (your PR was merged and they've updated)
- Check that the peer has a `selfEndpoint` — without it, one side needs to initiate
- Check that any firewall on their end allows UDP on their listen port

**`wg show` lists peers but no transfer**
Verify the `AllowedIPs` on your end match the peer's assigned address in `inventory.json`.

