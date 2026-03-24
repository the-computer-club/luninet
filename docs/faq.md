# FAQ

---

**What can I access on the network?**

Any peer that has a `selfEndpoint` defined in `peers.nix` is reachable at any time. Peers without a `selfEndpoint` are only reachable when they've initiated a connection themselves (WireGuard establishes a path dynamically). All addresses in `172.29.80.1`–`172.29.80.254` are routed over the VPN.

---

**Can other peers connect to me without my knowledge?**

Not by default. WireGuard only establishes a session when you initiate outbound traffic.

The one exception: if you or a peer you're connecting to has `selfEndpoint` defined, a bidirectional path can be established during that session. If this is a concern, configure your firewall to drop unsolicited inbound UDP on WireGuard's listen port. This is the default policy on most systems.

---

**Do I need this running all the time?**

No. Bring the interface up when you need it, down when you don't:

```sh
sudo wg-quick up asluni
sudo wg-quick down asluni
```

---

**Does this hide my internet traffic like a commercial VPN?**

No. This is a split-tunnel VPN. Only packets addressed to `172.29.80.0/24` are encapsulated and routed through the VPN. All other traffic (web browsing, etc.) goes through your normal connection unchanged.

---

**Why can't I ping anyone after joining?**

The most likely cause is that other peers haven't updated their config to include your public key yet. Your key only takes effect on a peer's machine after they pull the latest `peers.nix`. Some peers may update infrequently.

Also check:

- Your WireGuard interface is up (`sudo wg show`)
- Your private key corresponds to the public key in `peers.nix`
- Your assigned IP address is correctly set on the interface (`ip addr show asluni`)

---

**A peer I could reach before is now unreachable.**

They may have updated their keys or IP address. Pull the latest config and update your peer list.

---

**How do I update the peer list without restarting?**

With `wg-quick`:

```sh
sudo wg-quick down asluni && sudo wg-quick up asluni
```

Or, to update peers in-place without dropping the interface (more advanced):

```sh
# Sync new peer config into the running interface
sudo wg syncconf asluni <(wg-quick strip asluni)
```

---

**What's the difference between `selfEndpoint` and not having one?**

A peer with `selfEndpoint` has a stable public address (IP or hostname + port). Others can initiate connections to them directly at any time.

A peer without `selfEndpoint` can still participate — but someone else needs to initiate the session first. Once one side sends traffic, WireGuard learns the roaming endpoint and communication becomes bidirectional.

---

**Where do I get help?**

Open an issue on the [automous-zones repository](https://github.com/the-computer-club/automous-zones) or ask in the club's usual channels.
