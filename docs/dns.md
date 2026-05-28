# DNS Configuration

The network provides DNS resolution for `.luni` hostnames, allowing you to reach peers by name (e.g. `some-peer.luni`) rather than raw IP address.

DNS servers are available at:
- `172.29.83.1` (port `5353`, port `53` )

---

## resolv.conf

The simplest option. Works on any Linux system.

```sh
echo "nameserver 172.29.83.1" | sudo resolvconf -a asluni -m 0 -x
```

If `resolvconf` is not available, you can edit `/etc/resolv.conf` directly, though this may be overwritten by your network manager.

---

## systemd-resolved

Configures DNS only for the `asluni` interface, so `.luni` queries go to the VPN DNS without affecting the rest of your system.

```sh
sudo systemd-resolve -i asluni \
  --set-dns=172.29.83.1:53 \
sudo resolvectl domain asluni luni. _wireguard._udp.luni.b32.
```

To make this persistent, create a drop-in for the interface. Add the following to `/etc/systemd/resolved.conf.d/asluni.conf`:

```ini
[Resolve]
DNS=172.29.83.1:53 
Domains=luni. _wireguard._udp.luni.b32.
```

Then restart resolved:

```sh
sudo systemctl restart systemd-resolved
```

Verify with:

```sh
resolvectl status asluni
```

---

## NetworkManager

If you use NetworkManager, you can configure DNS per-connection:

```sh
# Find the connection name for your WireGuard interface
nmcli connection show

# Set DNS for the asluni connection
nmcli connection modify asluni ipv4.dns "172.29.83.1"
nmcli connection modify asluni ipv4.dns-search "luni"
nmcli connection up asluni
```

---

## dnscrypt-proxy

```nix
# NixOS — services.dnscrypt-proxy2
services.dnscrypt-proxy2.settings.forwarding_rules =
  pkgs.writeText "forwarding_rules.txt" ''
    luni      172.29.83.1:53
    luni.b32  172.29.83.1:53
  '';
```

On non-NixOS systems, add the equivalent to your `dnscrypt-proxy.toml`:

```toml
[forwarding_rules]
forwarding_rules = '/etc/dnscrypt-proxy/forwarding_rules.txt'
```

```
# /etc/dnscrypt-proxy/forwarding_rules.txt
luni      172.29.83.1:53
luni.b32  172.29.83.1:53
```

---

## Testing

```sh
# Check that .luni resolution works
dig some-peer.luni @172.29.80.2 -p 5334

# Or with host
host some-peer.luni 172.29.80.2

# Check what resolver is being used
resolvectl query some-peer.luni
```



# Mullvad VPN

If you're using mullvad-vpn, just be aware that they drop all traffic bounded for port `53` that is destined outside of their network.
You may use the alternative port number `5353` to bypass such restrictions
