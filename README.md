# luninet

**luninet** is a WireGuard VPN that underpins the computer-club's shared infrastructure. It provides a tunneling layer for gaming, file sharing, and self-hosted services across club members' machines.

All connected peers share the `172.29.80.0/24` subnet. This is a **split-tunnel** VPN — only traffic addressed to that subnet is encapsulated. Your normal internet traffic is unaffected.

---

## Documentation

| Page | Description |
|------|-------------|
| [Joining the Network](./docs/joining.md) | How to add yourself as a peer |
| [Linux Setup](./docs/linux.md) | `wg-quick` and manual setup for any Linux distro |
| [Windows Setup](./docs/Windows.md) | WireGuard, DNS proxy, and certificate setup on Windows |
| [NixOS Setup](./docs/nixos.md) | NixOS flake configurations (plain, flake-guard v1, flake-guard v2) |
| [Mikrotik Setup](./docs/mikrotik.md) | Configuring mikrotik to work with luninet |
| [DNS Configuration](./docs/dns.md) | Resolving `.luni` hostnames |
| [Named Keys](./docs/named-keys.md) | Showing peer names in `wg show` |
| [FAQ](./docs/faq.md) | Common questions |

---

## Network at a Glance

- **Subnet:** `172.29.80.0/24`
- **Routable range:** `172.29.80.1` – `172.29.80.254`
- **DNS server:** `172.29.80.2` / `172.29.80.6`
- **VPN type:** Split-tunnel (only VPN-addressed traffic is encapsulated)
- **Underlying protocol:** WireGuard

---

## Quick Start

If you just want to get connected as fast as possible on Linux:

1. [Add yourself as a peer](./joining.md)
2. Download the latest config: [`wg-asluni.conf`](https://github.com/the-computer-club/automous-zones/releases/download/latest/wg-asluni.conf)
3. Install WireGuard and bring up the interface:

```sh
sudo apt install wireguard  # or your distro's equivalent
sudo cp wg-asluni.conf /etc/wireguard/asluni.conf
# Prepend your private key — see Linux Setup for details
sudo wg-quick up asluni
```

For full setup instructions, see [Linux Setup](./linux.md).

---

See also: [RFC 0001 — luninet](https://github.com/the-computer-club/RFC/blob/main/0001-luninet.md)
