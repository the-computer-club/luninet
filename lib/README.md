# Vendored: `lib/fabric`, `lib/ipv4`, `lib/ipv6`

Copied from `ComputerClub/ccpkgs` at `feat/mikrotik-routers`
(`lib/fabric.nix`, `lib/fabric/{schema,derive}.nix`, `lib/fabric-test.nix`,
`lib/ipv4.nix`, `lib/ipv6.nix`).

**Why vendored, not an input.** luninet is meant to be usable on its own — a
clone from GitHub with no access to the `codex` forge should build it. `lib/fabric`
lives only in ccpkgs, and taking ccpkgs as a flake input would drag the whole
package set (and clan-core, and their pins) into a repo whose only job is to
publish a peer list.

**What it costs.** These files are copies, so they do not follow ccpkgs. When the
library changes there, re-copy from the commit that carries it and re-run the
checks:

```sh
nix build .#checks.x86_64-linux.fabric .#checks.x86_64-linux.fabric-parity
```

`fabric` is the library's own assertions (duplicate addresses, gateways that are
not on their zone, reservations outside their space or overlapping a zone);
`fabric-parity` is the claim this repository actually depends on — every address
in `inventory.json` is the address the fabric derives from the same inventory.

**Do not edit these files to fit luninet.** If something here needs to change,
change it in ccpkgs and re-vendor; a local edit is a fork nobody will notice
until the next copy overwrites it.

`fabric/data.nix` is *not* vendored — it is luninet's address space, and it is
the only file in this tree that describes this network.