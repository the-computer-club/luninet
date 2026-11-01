# schema.nix — the option surface of the `fabric` module class.
#
# Three declarations and one space, which is what `clan.inventory.ip` was
# reaching for (see infra/RFC 2026-0001):
#
# Three kinds of declaration, one space:
#
#   zones          what a network is: its prefixes, gateway, DNS, DHCP. Written once.
#   machines       who is on it: per interface, a zone (or an address that implies
#                  one), an id, or nothing at all.
#   reservations   what a service owns: a block no zone or machine may use
#                  (a wireguard tunnel network, a vlan pool).
#
# Everything an interface needs — address, prefix, netmask, gateway, DNS, IPv6 —
# is derived from those three. Nothing is written twice.
{ lib }:
let
  inherit (lib) types mkOption;
in
{
  options = {
    name = mkOption { type = types.str; default = "ip"; };
    domain = mkOption { type = types.nullOr types.str; default = null; };

    spaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "10.0.0.0/8" "172.29.64.0/18" "fd12:7001::/48" ];
      description = ''
        Everything this fabric may address out of, IPv4 and IPv6. A zone must
        be inside one of these, unless it is marked `external` (a WAN block, a
        customer network — real addresses you do not own but do have to record).
      '';
    };

    autoStart = mkOption {
      type = types.ints.positive;
      default = 100;
      description = "First host id handed out to interfaces that neither pin an address nor an id.";
    };

    zones = mkOption {
      default = { };
      description = ''
        A zone is an L2 segment plus the configuration everything on it shares:
        the prefix(es), the gateway, the resolvers, the DHCP pool. Machines join
        a zone; they never repeat what the zone says.
      '';
      type = types.attrsOf (types.submodule {
        options = {
          description = mkOption { type = types.str; default = ""; };
          vlan = mkOption { type = types.nullOr (types.ints.between 1 4094); default = null; };
          vrf = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Routing domain. Two zones in different VRFs may hold the same prefix.";
          };
          external = mkOption {
            type = types.bool;
            default = false;
            description = "Not carved out of `spaces` (a WAN block). Still checked for overlap with everything else.";
          };

          ipv4 = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                addresses = mkOption {
                  type = types.nonEmptyListOf types.str;
                  example = [ "10.0.0.0/24" ];
                  description = "Prefixes on this zone. Usually one; more than one means multiple subnets on the same L2.";
                };
                defaultGateway = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "10.0.0.1";
                  description = ''
                    Either a literal address, or the name of a machine in this
                    inventory (`"homelab-router"`), which is resolved to that
                    machine's address on *this* zone. The second form is the one
                    that survives moving a router.
                  '';
                };
                dns = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Resolvers, same two spellings as `defaultGateway`.";
                };
                dhcp = {
                  pool = mkOption {
                    type = types.nullOr (types.submodule {
                      options = {
                        start = mkOption { type = types.ints.between 1 254; };
                        end = mkOption { type = types.ints.between 1 254; };
                      };
                    });
                    default = null;
                  };
                  staticLeases = mkOption { type = types.bool; default = true; };

                  # What DHCP *hands out* is not what the zone's own machines
                  # resolve with. The router-served segment is the normal case:
                  # its machines are told to use the router, while the leases
                  # it serves point guests at a public resolver -- so that they
                  # never depend on an internal name server the router does not
                  # run. Empty means "hand out the zone's own `dns`".
                  dns = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [ "1.1.1.1" "8.8.8.8" ];
                    description = ''
                      Resolvers to hand to DHCP clients. Same two spellings as
                      `ipv4.dns`. Empty falls back to the zone's `dns`, which is
                      what a segment that *is* served by its own resolver wants.
                    '';
                  };

                  # RouterOS names its menus' objects, and the names are not
                  # derivable from an address: a device that has been running
                  # has whatever the person who set it up chose. These carry
                  # that through a migration; leave them null and the renderer
                  # invents a stable name from the zone.
                  serverName = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "dhcp1";
                    description = "Name of the RouterOS `/ip dhcp-server` entry for this zone.";
                  };
                  poolName = mkOption {
                    type = types.nullOr types.str;
                    default = null;
                    example = "dhcp_pool0";
                    description = "Name of the `/ip pool` entry for this zone. Defaults to `dhcp-<zone>`.";
                  };
                };
                reserved = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Blocks inside this zone the allocator must not touch.";
                };
                allowNetworkAddress = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Allow an interface on this zone to take the segment's
                    *network* address (offset 0).

                    Off by default, because an address whose host bits are all
                    zero is not a usable unicast address: Linux accepts it, but
                    stacks that enforce the network address reject it and no
                    tool will agree about what it means. It exists for one
                    thing -- representing a segment that is already addressed
                    that way, so a migration can carry the existing addresses
                    and *then* move them, rather than changing addresses and
                    representation in the same step. A zone that sets it is
                    recorded as a finding, never as a model to copy.
                  '';
                };
              };
            });
            default = null;
          };

          ipv6 = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                addresses = mkOption { type = types.nonEmptyListOf types.str; };
                defaultGateway = mkOption { type = types.nullOr types.str; default = null; };
                dns = mkOption { type = types.listOf types.str; default = [ ]; };
                slaac = mkOption { type = types.bool; default = false; };
              };
            });
            default = null;
          };
        };
      });
    };

    machines = mkOption {
      default = { };
      description = ''
        Machines and their interfaces. An interface entry is either a string
        address (`"10.0.0.5/24"`, from which the zone is inferred) or an attrset
        when you need to say more.
      '';
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          description = mkOption { type = types.str; default = ""; };
          aliases = mkOption { type = types.listOf types.str; default = [ ]; };

          interfaces = mkOption {
            default = { };
            type = types.attrsOf (types.either types.str (types.submodule {
              options = {
                zone = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Zone this interface is on. Optional when `address` implies exactly one.";
                };
                address = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  example = "10.0.0.54/24";
                  description = "IPv4 address, optionally with the prefix. Wins over `hostId`.";
                };
                hostId = mkOption {
                  type = types.nullOr types.ints.unsigned;
                  default = null;
                  example = 54;
                  description = ''
                    Host part, reused for IPv4 and IPv6: with a zone that has
                    both, one number is the whole dual-stack configuration.
                  '';
                };
                ipv6Address = mkOption { type = types.nullOr types.str; default = null; };
                prefixLength = mkOption { type = types.nullOr (types.ints.between 1 32); default = null; };
                mac = mkOption { type = types.nullOr types.str; default = null; };
                role = mkOption {
                  type = types.enum [ "host" "router" "reserved" ];
                  default = "host";
                };
              };
            }));
          };
        };
      }));
    };

    # A service says "this block is mine" and the fabric guarantees nobody else
    # gets an address out of it. Subdivision inside the block stays the
    # service's business (ccpkgs/wireguard already does controller/peer slots).
    reservations = mkOption {
      default = { };
      description = "Blocks claimed by a service instance.";
      type = types.attrsOf (types.submodule {
        options = {
          space = mkOption {
            type = types.str;
            example = "10.50.0.0/24";
            description = "The block. One prefix; subdivide it yourself.";
          };
          instance = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "homelab-wg";
            description = "Which inventory instance owns it, for error messages and docs.";
          };
          description = mkOption { type = types.str; default = ""; };
        };
      });
    };
  };
}
