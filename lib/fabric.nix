# fabric.nix — an address space as code: spaces, zones, machines, reservations.
#
# The problem it solves: one address fact (a machine's address, its gateway, its
# prefix) currently gets written once per consumer -- the NixOS module, the
# router configuration, the initrd, DNS -- and nothing checks that the copies
# agree. Here it is declared once and every consumer derives from that:
#
#     zones.<name>            an L2 segment and what everything on it shares
#                             (prefixes, gateway, resolvers, DHCP pool, VLAN, VRF)
#     machines.<m>.<iface>    who is on it: an address, a hostId, or nothing
#     reservations.<name>     a block a service owns (wireguard's tunnel network)
#     spaces                  what the organisation owns; zones must sit inside it
#
# Everything concrete -- address, prefix length, netmask, gateway, DNS, IPv6,
# DHCP leases, router sections, DNS records, deploy target -- is derived.
#
#     let fabric = cclib.fabric;
#         net = fabric.eval { modules = [ ./fabric/data.nix ]; };
#     in net.nixosModuleFor "speedway"    # networking.interfaces / defaultRoute / resolvers
#        net.mikrotikSections             # /ip address, /ip pool, /ip dhcp-server ...
#        net.dnsRecords                   # A/AAAA per host, aliases
#        net.targetHostFor "speedway"     # root@<management address>
#        net.assertions                   # [] or the reasons it cannot be true
#
# Design notes, alternatives and the upstream `clan.inventory.ip` question:
# infra/RFC 2026-0001.
{ lib, ipv4, ipv6 }:
let
  schema = import ./fabric/schema.nix { inherit lib; };
  derive = import ./fabric/derive.nix;

  eval = { modules }:
    let
      ev = lib.evalModules {
        # A class of its own, like `mikrotik` and `nixos`: a module can
        # contribute zones or reservations without being a NixOS machine.
        class = "fabric";
        modules = [ schema ] ++ modules;
      };
    in
    derive { inherit lib ipv4 ipv6; config = ev.config; } // { inherit (ev) config; };
in
{
  inherit schema eval;
  inherit (import ./fabric-test.nix { inherit lib eval; }) selfTest;
}
