# luninet's address space, as data for the `fabric` module class.
#
# Vendored from `ComputerClub/ccpkgs` (`lib/fabric*`), because this repository
# cannot take ccpkgs as a flake input -- see `lib/README.md`.
#
# What this replaces: `ip-allocate.py`, which derived addresses in JSON iteration
# order. That is why a reordered `peers.nix` silently renumbered every peer, and
# why nothing checked a claimed address against anything else. Here the
# *inventory stays the oracle*: every host id and every IPv6 address is pinned
# from `inventory.json`, so what the fabric derives is exactly what the network
# runs today. The library is what turns those pins into an address space that can
# be checked -- overlap, duplicates, gateways, reservations inside their space.
#
# The drift, recorded rather than "fixed", because encoding RFC 0001 would
# renumber every peer:
#
#   * RFC 0001 §1.2 gives each member a /21 of `172.29.64.0/18`; the network
#     actually in service is one controller subnet, `172.29.80.0/24`, with peers
#     as /32s inside it. The /21s are modelled below as *reservations* (blocks we
#     do not administer yet), and the lunarix /21 has a zone carved out of it.
#   * RFC 0001 puts router links in `172.29.65.0/24` (§1.2) and in
#     `172.29.255.0/24` (§1.3). Neither is reserved here: the first is inside the
#     management /21, so reserving it would overlap, and the second contradicts
#     the first. That needs fixing in the RFC, not in the data.
#
# Peers are `machines`, not reservations: a reservation is a block a service owns
# and the library refuses one that overlaps a zone, while these peers are hosts
# on the controller's zone at fixed ids. Being machines is also what makes their
# addresses checkable against each other.
{ lib, ... }:
let
  ipv4 = import ../lib/ipv4.nix;

  inv = builtins.fromJSON (builtins.readFile ../inventory.json);
  net = inv.network;

  isController = v: v.isController or false;
  controllers = lib.filterAttrs (_: isController) net;
  peers = lib.filterAttrs (_: v: !(isController v)) net;

  # "172.29.80.2/32" -> address "172.29.80.2", length 32.
  cidrOf = c:
    let parts = lib.splitString "/" c;
    in {
      address = lib.head parts;
      length = lib.toInt (lib.last parts);
    };

  # The host's offset inside its controller's subnet: .1 is the controller,
  # peers start at .2. Pinned from the inventory, never recomputed -- this is the
  # whole point of the replacement.
  hostIdOf = c: lib.toInt (lib.last (lib.splitString "." (cidrOf c).address));

  # The subnet a controller's zone *is*: 172.29.80.1/24 -> 172.29.80.0/24.
  zoneCidrOf = c: (ipv4.subnet "${(cidrOf c).address}/${toString (cidrOf c).length}").cidr;

  controllerNames = lib.attrNames controllers;

  zoneName = ctrl: "ctrl-${ctrl}";

  # One zone per controller: that is what the network actually has -- each
  # controller's tunnel subnet is a segment of its own.
  zones = lib.mapAttrs' (name: v: lib.nameValuePair (zoneName name) {
    description = "Tunnel subnet of controller ${name} (${v.selfEndpoint or "no endpoint"})";
    ipv4 = {
      addresses = [ (zoneCidrOf (lib.head v.ipv4)) ];
      # The controller is at .1 on its own zone; naming the machine rather than
      # writing 172.29.80.1 is what survives moving it.
      defaultGateway = name;
    };
    ipv6.addresses = [ (lib.head v.ipv6) ];
  }) controllers;

  # Each peer has one address per controller, in the same order as `ipv4`/`ipv6`
  # in the inventory (today: one controller, one address).
  interfacesFor = v:
    lib.listToAttrs (lib.imap0
      (i: cidr:
        let ctrl = lib.elemAt controllerNames i;
        in lib.nameValuePair "wg-${ctrl}" {
          zone = zoneName ctrl;
          hostId = hostIdOf cidr;
          prefixLength = (cidrOf cidr).length;
          # Bare address: `ipv6.parseAddress` splits on `:` and a `/64` suffix
          # lands in the last group. The prefix itself is the zone's -- the
          # inventory's /64s are peer subnets, which the fabric does not model.
          ipv6Address = lib.head (lib.splitString "/" (lib.elemAt v.ipv6 i));
        })
      v.ipv4);

  machines = lib.mapAttrs (_: v: { interfaces = interfacesFor v; }) net;

  # RFC 0001 §1.2, minus `172.29.80.0/21`: that block holds the controllers'
  # zones, and a reservation may not overlap one. A block a member owns is
  # reserved here until we know what is inside it -- we do not administer it.
  memberBlocks = {
    management = "172.29.64.0/21";
    reserved = "172.29.72.0/21";
    jeffrey = "172.29.88.0/21";
    unassigned-1 = "172.29.96.0/21";
    unassigned-2 = "172.29.104.0/21";
    unassigned-3 = "172.29.112.0/21";
    unassigned-4 = "172.29.120.0/21";
  };
in
{
  name = "luninet";
  domain = "luninet.org";

  spaces = [
    "172.29.64.0/18"
    "fd49:093b:2b68::/48"
  ];

  inherit zones machines;

  reservations = lib.mapAttrs
    (n: space: {
      inherit space;
      description = "RFC 0001 §1.2 member block: ${n}";
    })
    memberBlocks;
}