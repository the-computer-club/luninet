# luninet

**luninet** is a WireGuard VPN that underpins the computer-club's shared infrastructure. It provides a tunneling layer for gaming, file sharing, and self-hosted services across club members' machines.

This repo is both a setup guide, and internal implementation of the network.
For network specifications, please defer to the [RFC](https://github.com/the-computer-club/RFC/blob/main/0001-luninet.md).

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

- **Subnet:** `172.29.81.0/24`
- **Routable range:** `172.29.64.0` – `172.29.127.255`
- **DNS server:** `172.29.83.1`
- **Underlying protocol:** WireGuard
- **MTU:** 1420 (Ipv4)
---

## Quick Start

If you just want to get connected as fast as possible on Linux:

1. [Add yourself as a peer](./docs/joining.md)
2. Download the latest config: [`wg-asluni.conf`](https://github.com/the-computer-club/luninet/releases/download/latest/luni-peer.conf)
3. Install WireGuard and bring up the interface:

```sh
sudo apt install wireguard  # or your distro's equivalent
sudo cp wg-asluni.conf /etc/wireguard/asluni.conf
# Prepend your private key — see Linux Setup for details
sudo wg-quick up asluni
```

For full setup instructions, see [Linux Setup](./docs/linux.md).

---

See also: [RFC 0001 — luninet](https://github.com/the-computer-club/RFC/blob/main/0001-luninet.md)
