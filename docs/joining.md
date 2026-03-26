# Joining the Network

To join the mesh you need to register your WireGuard public key and a chosen IP address in the shared peer list. This is done via a pull request.

---

## Prerequisites

- [WireGuard installed](https://www.wireguard.com/install/) on your machine
- A GitHub account
- `nix` (optional, needed for the inventory update step)

---

## Steps

### 1. Fork the repository

Fork [`the-computer-club/automous-zones`](https://github.com/the-computer-club/automous-zones) on GitHub and clone your fork locally.

### 2. Generate a WireGuard keypair

```sh
wg genkey | tee private-key | wg pubkey > public-key
```

> **Keep `private-key` secret.** Never commit it. Store it somewhere safe on your machine (e.g. `/etc/wireguard/asluni.key` with permissions `600`).

### 3. Add yourself to the peer list

Open `peers.nix` and add an entry for your machine:

```nix
# peers.nix
{
  your-hostname = {
    publicKey = "your-public-key-here";  # contents of public-key file
    # Optional: define a stable endpoint if your machine has a public IP
    # selfEndpoint = "your.ip.or.hostname:51820";
  };
}
```

Replace `your-hostname` with something that identifies your machine. It will be used as your DNS hostname on the `.luni` domain.

### 4. Update the inventory

Normally, `inventory.json` is generated using the nix command:

```sh
nix run .#update-inventory | jq > inventory.json
```

If you don't have nix installed, you can generate `inventory.json` directly using the Python script:

```sh
python3 ip-allocate.py \
    --tenant 23 \
    --controller 24 \
    --root 172.29.80.0/23 \
    --6peer 64 \
    --6base 9 \
    --6controller 48 \
    --6instance-bits 1 \
    luni peers.nix > inventory.json
```

This requires Python 3 to be installed on your system.


### 5. Commit and open a pull request

```sh
git add peers.nix inventory.json
git commit -m "add: your-hostname"
git push origin main
```

Then open a pull request against the upstream repository. Once it's merged, existing peers will receive your key on their next config update.

---

## After Your PR Is Merged

Your key won't be usable by others until they update their local configuration. If you can't reach a specific peer, ask them to pull the latest peer list.

If you can't reach **anyone**, double-check:

- Your private key is correctly configured (see [Linux Setup](./linux.md) or [NixOS Setup](./nixos.md))
- The WireGuard interface is up (`sudo wg show`)
- Your IP address doesn't conflict with another peer in `inventory.json`
