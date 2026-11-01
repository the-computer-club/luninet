# fabric-test.nix — pure evaluation tests: no clan, no NixOS, no VM.
#
# `checks.fabric-lib` runs this list through `nix flake check` (see flake.nix):
#
#     nix build .#checks.x86_64-linux.fabric-lib
#
# Each case is
# a small address space and the values the derivation must produce from it, so
# a change to the allocator or the resolvers shows up as a named failure rather
# than as a wrong address on a machine.
{ lib, eval }:
let
  inherit (builtins) tryEval toJSON;

  lan = {
    ipv4 = {
      addresses = [ "10.0.0.0/24" ];
      defaultGateway = "10.0.0.1";
      dns = [ "10.0.0.1" ];
      dhcp.pool = { start = 100; end = 200; };
    };
  };

  base = {
    spaces = [ "10.0.0.0/8" ];
    zones.lan = lan;
  };

  net = extra: eval { modules = [ base extra ]; };
  iface = n: h: i: n.addresses.${h}.${i};
  messages = n: map (a: a.message) n.assertions;
  mentions = needle: n: lib.any (s: lib.hasInfix needle s) (messages n);

  # One unpinned machine on `lan`: the allocator must skip the DHCP pool
  # (100-200), so the first automatic address is .201, then .202.
  autoA = net { machines.a.interfaces.eno1 = { zone = "lan"; }; };
  autoB = net { machines = { a.interfaces.eno1 = { zone = "lan"; }; b.interfaces.eno1 = { zone = "lan"; }; }; };

  dual = net {
    spaces = [ "10.0.0.0/8" "fd00:aa::/48" ];
    zones.dual = {
      ipv4 = { addresses = [ "10.0.0.0/24" ]; defaultGateway = "10.0.0.1"; };
      ipv6 = { addresses = [ "fd00:aa:0:1::/64" ]; };
    };
    machines.a.interfaces.eno1 = { zone = "dual"; hostId = 54; };
  };

  referenced = net {
    machines.r.interfaces.eno1 = { zone = "lan"; hostId = 1; role = "router"; };
    machines.m.interfaces.eno1 = "10.0.0.5/24";
  };
  # …with the zone pointing its gateway at `r` instead of a literal.
  byRef = net {
    zones.lan.ipv4.defaultGateway = lib.mkForce "r";
    machines.r.interfaces.eno1 = { zone = "lan"; hostId = 1; role = "router"; };
    machines.m.interfaces.eno1 = "10.0.0.5/24";
  };

  duplicate = net {
    machines.a.interfaces.eno1 = "10.0.0.5/24";
    machines.b.interfaces.eno1 = "10.0.0.5/24";
  };

  reservation = net {
    reservations.wg.space = "10.0.0.0/24";
  };

  inNoZone = net { machines.g.interfaces.eno1 = "192.0.2.9/24"; };

  externalZone = net {
    zones.wan = { external = true; ipv4 = { addresses = [ "198.51.100.0/24" ]; }; };
    machines.w.interfaces.eno1 = "198.51.100.7/24";
  };

  strayZone = net {
    zones.other = { ipv4 = { addresses = [ "192.168.5.0/24" ]; }; };
    machines.o.interfaces.eno1 = "192.168.5.7/24";
  };

  # Same address, two zones: one that refuses network-address addressing (the
  # default) and one that carries an existing segment as-is.
  netAddrDefault = net { machines.a.interfaces.eno1 = "10.0.0.0/24"; };
  netAddrAllowed = net {
    zones.lan.ipv4.allowNetworkAddress = true;
    machines.a.interfaces.eno1 = "10.0.0.0/24";
  };

  # A segment served by a router, whose guests get a public resolver while the
  # zone's own machines resolve with the router.
  dhcpLeaseDns = net {
    zones.lan.ipv4.dhcp.dns = [ "198.51.100.53" ];
    machines.r.interfaces.eno1 = { zone = "lan"; hostId = 1; role = "router"; };
  };
  dhcpZoneDns = net {
    machines.r.interfaces.eno1 = { zone = "lan"; hostId = 1; role = "router"; };
  };

  # A /28 cannot start allocating at `autoStart` = 100.
  smallZone = net {
    zones.tiny.ipv4.addresses = [ "10.1.1.16/28" ];
    machines.a.interfaces.eno1 = { zone = "tiny"; };
  };

  # Allocation that begins at the last usable host of a /24.
  lateStart = net {
    autoStart = 253;
    machines = {
      a.interfaces.eno1 = { zone = "lan"; };
      b.interfaces.eno1 = { zone = "lan"; };
    };
  };

  # `dhcp.dns` naming a machine that is on a different zone.
  offZoneLeaseDns = net {
    zones.other.ipv4.addresses = [ "10.9.0.0/24" ];
    zones.lan.ipv4.dhcp.dns = [ "m" ];
    machines.r.interfaces.eno1 = { zone = "lan"; hostId = 1; role = "router"; };
    machines.m.interfaces.eno1 = { zone = "other"; hostId = 5; };
  };

  # A served zone with neither a gateway nor resolvers to hand out.
  bareServed = net {
    zones.bare.ipv4 = {
      addresses = [ "10.7.0.0/24" ];
      dhcp.pool = { start = 20; end = 30; };
    };
    machines.r.interfaces.eno1 = { zone = "bare"; hostId = 1; role = "router"; };
  };

  # A host with a MAC, on a zone that does and does not want static leases.
  leaseOff = net {
    zones.lan.ipv4.dhcp.staticLeases = false;
    machines.h.interfaces.eno1 = { zone = "lan"; hostId = 5; mac = "aa:bb:cc:dd:ee:ff"; };
  };
  leaseOn = net {
    machines.h.interfaces.eno1 = { zone = "lan"; hostId = 5; mac = "aa:bb:cc:dd:ee:ff"; };
  };

  cases = {
    "short form: address implies the zone, and the zone supplies the rest" = {
      actual = [
        (iface (net { machines.a.interfaces.eno1 = "10.0.0.5/24"; }) "a" "eno1").zone
        (iface (net { machines.a.interfaces.eno1 = "10.0.0.5/24"; }) "a" "eno1").address
        (iface (net { machines.a.interfaces.eno1 = "10.0.0.5/24"; }) "a" "eno1").prefixLength
        (iface (net { machines.a.interfaces.eno1 = "10.0.0.5/24"; }) "a" "eno1").gateway
        (iface (net { machines.a.interfaces.eno1 = "10.0.0.5/24"; }) "a" "eno1").dns
      ];
      expected = [ "lan" "10.0.0.5" 24 "10.0.0.1" [ "10.0.0.1" ] ];
    };

    "netmask is derived from the prefix" = {
      actual = (iface (net { machines.a.interfaces.eno1 = "10.0.0.5/24"; }) "a" "eno1").netmask;
      expected = "255.255.255.0";
    };

    "a prefix in the machine's own address wins over the zone's" = {
      actual = (iface (net { machines.a.interfaces.eno1 = "10.0.0.5/32"; }) "a" "eno1").prefixLength;
      expected = 32;
    };

    "hostId addresses both families" = {
      actual = [
        (iface dual "a" "eno1").address
        (iface dual "a" "eno1").ipv6.address
        (iface dual "a" "eno1").ipv6.prefixLength
      ];
      expected = [ "10.0.0.54" "fd00:aa:0:1::36" 64 ];
    };

    "auto allocation starts above the DHCP pool" = {
      actual = map (h: (iface autoA h "eno1").address) [ "a" ];
      expected = [ "10.0.0.201" ];
    };

    "auto allocation is stable and never reuses an id" = {
      actual = map (h: (iface autoB h "eno1").address) [ "a" "b" ];
      expected = [ "10.0.0.201" "10.0.0.202" ];
    };

    "a gateway given as a machine name resolves on that zone" = {
      actual = (iface byRef "m" "eno1").gateway;
      expected = "10.0.0.1";
    };

    "the host that is the gateway has no default route through itself" = {
      actual = (iface byRef "r" "eno1").gateway;
      expected = null;
    };

    "literal gateway still works" = {
      actual = (iface referenced "m" "eno1").gateway;
      expected = "10.0.0.1";
    };

    "two machines on one address is reported" = {
      actual = mentions "claimed by" duplicate;
      expected = true;
    };

    "a reservation over a zone is reported" = {
      actual = mentions "overlaps zone" reservation;
      expected = true;
    };

    "an address outside every zone is an evaluation error" = {
      # The derived record is lazy per field; the zone is forced as soon as
      # anything that needs it is read, and `assertions` is the first thing a
      # check reads.
      actual = (tryEval (lib.length inNoZone.assertions)).success;
      expected = false;
    };

    "an external zone may sit outside `spaces`" = {
      actual = messages externalZone;
      expected = [ ];
    };

    "an internal zone outside `spaces` is reported" = {
      actual = mentions "outside every declared space" strayZone;
      expected = true;
    };

    # The fleet addresses its per-vlan /28 segments on the *network* address
    # (`10.1.1.96/28`). That is not a usable unicast address, so the fabric
    # refuses it -- unless the zone says, explicitly, that it is carrying an
    # existing segment as-is. Both halves are tested: the default must still
    # reject, and the opt-in must be recorded rather than silently honoured.
    "the network address is refused on a zone that did not opt in" = {
      actual = mentions "is not a usable address" netAddrDefault;
      expected = true;
    };

    "a zone that opts in may carry the network address, and it is published" = {
      actual = [
        (messages netAddrAllowed)
        (iface netAddrAllowed "a" "eno1").address
        netAddrAllowed.networkAddressZones
      ];
      expected = [ [ ] "10.0.0.0" [ "a.eno1 (10.0.0.0, zone lan)" ] ];
    };

    # What DHCP hands out is a lease property, not the zone's own resolver: the
    # router-served segment tells its machines to use the router while pointing
    # guests at a public resolver.
    "a lease's resolvers are its own, not the zone's" = {
      actual = (lib.head dhcpLeaseDns.mikrotikSections."/ip dhcp-server network").dns-server;
      expected = "198.51.100.53";
    };

    "with no lease resolvers, the lease falls back to the zone's" = {
      actual = (lib.head dhcpZoneDns.mikrotikSections."/ip dhcp-server network").dns-server;
      expected = "10.0.0.1";
    };

    "the dhcp-server binds the pool to the router's own interface on the zone" = {
      actual = lib.head dhcpZoneDns.mikrotikSections."/ip dhcp-server";
      expected = { name = "dhcp-lan"; interface = "eno1"; address-pool = "dhcp-lan"; };
    };

    # The four below are the defects the review found. Each one fails on the
    # commit before the fix and passes after it.

    # A /28 with `autoStart` = 100 used to ask for a negative-length list, which
    # aborts evaluation and cannot be caught. It is a throw now, so a caller can
    # see it -- and the message names the zone and the interface.
    "a zone too small for autoStart fails catchably instead of aborting" = {
      actual = (tryEval smallZone.addresses.a.eno1.address).success;
      expected = false;
    };

    # The last usable host of a zone is `addressCount - 2`; the old count stopped
    # one short, so .254 was never handed out and the 155th machine crashed.
    "allocation reaches the last usable host" = {
      actual = map (h: (iface lateStart h "eno1").address) [ "a" "b" ];
      expected = [ "10.0.0.253" "10.0.0.254" ];
    };

    # `dhcp.dns` is resolved exactly like `dns`, so it is asserted like `dns`.
    # Before this it left `assertions` empty and only the router render failed.
    "a lease resolver on another zone is asserted" = {
      actual = mentions "dhcp.dns" offZoneLeaseDns;
      expected = true;
    };

    # `dns-server=` is rejected by RouterOS and a null gateway makes the renderer
    # throw, so neither attribute is emitted without a value.
    "a served zone with no resolvers and no gateway renders only the network" = {
      actual = lib.head bareServed.mikrotikSections."/ip dhcp-server network";
      expected = { address = "10.7.0.0/24"; };
    };

    # `staticLeases` was declared and never read.
    "staticLeases = false emits no static lease" = {
      actual = [
        (lib.length leaseOff.mikrotikSections."/ip dhcp-server lease")
        (lib.length leaseOn.mikrotikSections."/ip dhcp-server lease")
      ];
      expected = [ 0 1 ];
    };
  };

  failed = lib.filter (n: cases.${n}.actual != cases.${n}.expected) (lib.attrNames cases);
  selfTest = map
    (n: "${n}: expected ${toJSON cases.${n}.expected}, got ${toJSON cases.${n}.actual}")
    failed;
in
{
  inherit cases selfTest;
}
