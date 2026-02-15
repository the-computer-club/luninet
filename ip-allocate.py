#!/usr/bin/env python3
"""IPv4 + IPv6 address allocator for WireGuard networks.

Network layout — IPv4
---------------------
- Root:        configurable CIDR            (default: 172.25.0.0/16)
- Tenant:      configurable prefix len      (default: /21)  carved from root
- Controllers: configurable prefix len      (default: /24)  carved from tenant
- Peers:       /32 host address inside each controller's subnet.
               Last octet = sum(ord(c)+10 for c in name) % 255, clamped 1-254.
               Collisions resolved by decrementing (wrapping 1-254).

Network layout — IPv6
---------------------
- Base:        ULA fd.../N                  (default: /40)  derived from instance_name
- Controllers: configurable prefix len      (default: /56)  carved from base
- Peers:       configurable prefix len      (default: /96)  carved from controller,
               suffix from SHA-256 of peer_name, reused identically across all controllers.

Usage
-----
  allocator.py [options] <instance_name> <json_file>

IPv4 options:
  --root CIDR           IPv4 root network            (default: 172.25.0.0/16)
  --tenant LEN          tenant prefix len            (default: 21)
  --controller LEN      controller prefix len        (default: 24)

IPv6 options:
  --6base LEN           ULA base prefix len          (default: 40)
  --6controller LEN     controller prefix len        (default: 56)
  --6peer LEN           peer subnet prefix len       (default: 96)

Examples
--------
  allocator.py luni network.json
  allocator.py --root 10.0.0.0/8 --tenant 16 --controller 24 luni network.json
  allocator.py --6base 48 --6controller 64 --6peer 96 luni network.json
  allocator.py --root 172.16.0.0/12 --tenant 20 --controller 24 \\
               --6base 48 --6controller 64 --6peer 112 acme network.json
"""
import argparse
import json
import hashlib
import ipaddress
import sys

IPV4_RESERVED = {0, 255}


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def hash_string(s: str) -> str:
    """SHA-256 hex digest of *s*."""
    return hashlib.sha256(s.encode()).hexdigest()


def hash_int(s: str) -> int:
    """SHA-256 of *s* as a 256-bit integer."""
    return int(hash_string(s), 16)


def top_bits(value: int, n: int, source_width: int = 256) -> int:
    """Return the top *n* bits of *value* (which is *source_width* bits wide)."""
    return value >> (source_width - n)


def is_controller(vals: dict) -> bool:
    return bool(vals.get("controller") or vals.get("isController"))


# ---------------------------------------------------------------------------
# IPv4 allocation
# ---------------------------------------------------------------------------

def ipv4_tenant_subnet(
    root: ipaddress.IPv4Network,
    tenant_prefix_len: int,
    instance_name: str,
) -> ipaddress.IPv4Network:
    """Return the tenant block for *instance_name* carved from *root*."""
    tenant_count = 2 ** (tenant_prefix_len - root.prefixlen)
    h = hash_int(instance_name)
    tenant_index = top_bits(h, 8) % tenant_count
    root_int = int(root.network_address)
    tenant_int = root_int + tenant_index * (2 ** (32 - tenant_prefix_len))
    return ipaddress.IPv4Network((tenant_int, tenant_prefix_len))


def ipv4_controller_subnet(
    tenant: ipaddress.IPv4Network,
    controller_prefix_len: int,
    controller_name: str,
    allocated_slots: dict[str, int],
) -> ipaddress.IPv4Network:
    """Return a controller subnet inside *tenant* for *controller_name*."""
    controllers_per_tenant = 2 ** (controller_prefix_len - tenant.prefixlen)
    h = hash_int(controller_name)
    candidate = top_bits(h, 8) % controllers_per_tenant

    used = set(allocated_slots.values())
    for _ in range(controllers_per_tenant):
        if candidate not in used:
            allocated_slots[controller_name] = candidate
            tenant_int = int(tenant.network_address)
            subnet_int = tenant_int + candidate * (2 ** (32 - controller_prefix_len))
            return ipaddress.IPv4Network((subnet_int, controller_prefix_len))
        candidate = (candidate + 1) % controllers_per_tenant

    print(
        f"ERROR: Cannot allocate a /{controller_prefix_len} for controller "
        f"'{controller_name}': all {controllers_per_tenant} slots in {tenant} are in use.",
        file=sys.stderr,
    )
    sys.exit(1)


def ipv4_peer_suffix(peer_name: str) -> int:
    """Return the preferred last-octet value for *peer_name* (1-254)."""
    raw = sum(ord(c) + 10 for c in peer_name) % 255
    return raw if raw != 0 else 1


def ipv4_allocate_peer(
    controller_subnet: ipaddress.IPv4Network,
    preferred: int,
    occupied: set[int],
) -> int:
    """Find a free last-octet in *controller_subnet*, decrementing on conflict."""
    candidate = preferred
    for _ in range(254):
        if candidate not in IPV4_RESERVED and candidate not in occupied:
            return candidate
        candidate -= 1
        if candidate < 1:
            candidate = 254

    print(
        f"ERROR: Cannot allocate a /32 inside {controller_subnet}: "
        "all host addresses are occupied.",
        file=sys.stderr,
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# IPv6 allocation
# ---------------------------------------------------------------------------

def ipv6_ula_base(instance_name: str, base_prefix_len: int) -> ipaddress.IPv6Network:
    """Return the ULA base network for *instance_name* at *base_prefix_len*.

    Always uses the fd::/8 ULA range.  The (base_prefix_len - 8) bits after
    'fd' are filled from the top bits of the SHA-256 hash of instance_name.
    """
    h = hash_int(instance_name)
    # How many bits come from the hash (everything after the 'fd' byte).
    net_bits = base_prefix_len - 8
    # Pull exactly that many bits from the top of the 256-bit hash.
    hash_segment = top_bits(h, net_bits)
    # Build the 128-bit address: 'fd' at bits 127-120, hash below that.
    fd_int = 0xfd << 120
    hash_int_ = hash_segment << (128 - base_prefix_len)
    return ipaddress.IPv6Network((fd_int | hash_int_, base_prefix_len))


def ipv6_controller_subnet(
    base: ipaddress.IPv6Network,
    controller_prefix_len: int,
    controller_name: str,
) -> ipaddress.IPv6Network:
    """Return a controller subnet of *controller_prefix_len* inside *base*."""
    h = hash_int(controller_name)
    id_bits = controller_prefix_len - base.prefixlen
    # Take the top id_bits from the hash as the controller ID.
    controller_id = top_bits(h, id_bits)
    base_int = int(base.network_address)
    subnet_int = base_int | (controller_id << (128 - controller_prefix_len))
    return ipaddress.IPv6Network((subnet_int, controller_prefix_len))


def ipv6_peer_id(peer_name: str) -> int:
    """Return a 64-bit peer identifier derived from *peer_name*.

    The same value is used across all controllers so the peer always appears
    at a consistent offset within each controller's subnet.
    """
    return top_bits(hash_int(peer_name), 64)


def ipv6_peer_subnet(
    controller_subnet: ipaddress.IPv6Network,
    peer_prefix_len: int,
    peer_id: int,
) -> ipaddress.IPv6Network:
    """Return the peer's /peer_prefix_len subnet within *controller_subnet*.

    The top (peer_prefix_len - controller_prefix_len) bits of *peer_id* are
    placed immediately after the controller prefix, giving every peer a
    consistent suffix across all controllers.
    """
    ctrl_len = controller_subnet.prefixlen
    peer_id_bits = peer_prefix_len - ctrl_len
    # Trim peer_id to only the bits we actually need.
    peer_id_trimmed = peer_id >> (64 - peer_id_bits)
    # Place those bits immediately after the controller prefix.
    ctrl_int = int(controller_subnet.network_address)
    peer_int = ctrl_int | (peer_id_trimmed << (128 - peer_prefix_len))
    return ipaddress.IPv6Network((peer_int, peer_prefix_len))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="IPv4 + IPv6 WireGuard address allocator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  allocator.py luni network.json\n"
            "  allocator.py --root 10.0.0.0/8 --tenant 16 --controller 24 luni network.json\n"
            "  allocator.py --6base 48 --6controller 64 --6peer 96 luni network.json\n"
            "  allocator.py --root 172.16.0.0/12 --tenant 20 --controller 24 \\\n"
            "               --6base 48 --6controller 64 --6peer 112 acme network.json"
        ),
    )
    v4 = p.add_argument_group("IPv4")
    v4.add_argument(
        "--root",
        default="172.25.0.0/16",
        metavar="CIDR",
        help="IPv4 root network (default: 172.25.0.0/16)",
    )
    v4.add_argument(
        "--tenant",
        type=int,
        default=21,
        metavar="LEN",
        help="tenant prefix length carved from root (default: 21)",
    )
    v4.add_argument(
        "--controller",
        type=int,
        default=24,
        metavar="LEN",
        help="controller prefix length carved from tenant (default: 24)",
    )
    v6 = p.add_argument_group("IPv6")
    v6.add_argument(
        "--6base",
        dest="v6base",
        type=int,
        default=40,
        metavar="LEN",
        help="ULA base prefix length (default: 40)",
    )
    v6.add_argument(
        "--6controller",
        dest="v6controller",
        type=int,
        default=56,
        metavar="LEN",
        help="controller subnet prefix length (default: 56)",
    )
    v6.add_argument(
        "--6peer",
        dest="v6peer",
        type=int,
        default=96,
        metavar="LEN",
        help="peer subnet prefix length (default: 96)",
    )
    p.add_argument("instance_name", help="name of this WireGuard instance / tenant")
    p.add_argument("json_file", help="path to the network inventory JSON file")
    return p.parse_args()


def validate(
    root: ipaddress.IPv4Network,
    tenant_len: int,
    controller_len: int,
    v6base_len: int,
    v6ctrl_len: int,
    v6peer_len: int,
) -> None:
    errors = []
    # IPv4
    if tenant_len <= root.prefixlen:
        errors.append(
            f"--tenant {tenant_len} must be greater than root prefix /{root.prefixlen}"
        )
    if controller_len <= tenant_len:
        errors.append(
            f"--controller {controller_len} must be greater than --tenant {tenant_len}"
        )
    if controller_len > 31:
        errors.append(
            f"--controller {controller_len} must be <= 31 to leave room for host addresses"
        )
    # IPv6
    if not (8 < v6base_len < 128):
        errors.append(f"--6base {v6base_len} must be between 9 and 127")
    if v6ctrl_len <= v6base_len:
        errors.append(
            f"--6controller {v6ctrl_len} must be greater than --6base {v6base_len}"
        )
    if v6peer_len <= v6ctrl_len:
        errors.append(
            f"--6peer {v6peer_len} must be greater than --6controller {v6ctrl_len}"
        )
    if v6peer_len > 128:
        errors.append(f"--6peer {v6peer_len} must be <= 128")
    peer_id_bits = v6peer_len - v6ctrl_len
    if peer_id_bits > 64:
        errors.append(
            f"--6peer {v6peer_len} - --6controller {v6ctrl_len} = {peer_id_bits} bits, "
            f"but the peer suffix is only 64 bits wide; maximum --6peer is {v6ctrl_len + 64}"
        )
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()

    try:
        root = ipaddress.IPv4Network(args.root, strict=True)
    except ValueError as e:
        print(f"ERROR: invalid --root '{args.root}': {e}", file=sys.stderr)
        sys.exit(1)

    validate(root, args.tenant, args.controller, args.v6base, args.v6controller, args.v6peer)

    with open(args.json_file) as fd:
        data = json.load(fd)

    tenant_prefix_len      = args.tenant
    controller_prefix_len  = args.controller
    tenant_count           = 2 ** (tenant_prefix_len - root.prefixlen)
    controllers_per_tenant = 2 ** (controller_prefix_len - tenant_prefix_len)

    v6base_len = args.v6base
    v6ctrl_len = args.v6controller
    v6peer_len = args.v6peer

    # -- IPv4 tenant block ---------------------------------------------------
    ipv4_tenant = ipv4_tenant_subnet(root, tenant_prefix_len, args.instance_name)
    ipv4_slots: dict[str, int] = {}

    # -- IPv6 ULA base -------------------------------------------------------
    ipv6_base = ipv6_ula_base(args.instance_name, v6base_len)

    # -----------------------------------------------------------------------
    # Phase 1 - classify nodes, allocate controller subnets
    # -----------------------------------------------------------------------
    controllers: dict[str, dict] = {}
    peers:       dict[str, dict] = {}

    for hostname, vals in data.items():
        if is_controller(vals):
            v4_subnet = ipv4_controller_subnet(
                ipv4_tenant, controller_prefix_len, hostname, ipv4_slots
            )
            v6_subnet = ipv6_controller_subnet(ipv6_base, v6ctrl_len, hostname)

            controllers[hostname] = {
                "v4_subnet":    v4_subnet,
                "v6_subnet":    v6_subnet,
                "ipv4":         [str(v4_subnet)],
                "ipv6":         [str(v6_subnet)],
                "_v4_occupied": set(),
            }
        else:
            peers[hostname] = {
                "v4_preferred": ipv4_peer_suffix(hostname),
                "v6_peer_id":   ipv6_peer_id(hostname),
                "ipv4":         [],
                "ipv6":         [],
            }

    # -----------------------------------------------------------------------
    # Phase 2 - assign each peer an address in every controller's block
    # -----------------------------------------------------------------------
    for peer_name, peer in peers.items():
        for ctrl_name, ctrl in controllers.items():
            # IPv4 /32
            last_octet = ipv4_allocate_peer(
                ctrl["v4_subnet"], peer["v4_preferred"], ctrl["_v4_occupied"]
            )
            ctrl["_v4_occupied"].add(last_octet)
            host_int = int(ctrl["v4_subnet"].network_address) | last_octet
            peer["ipv4"].append(f"{ipaddress.IPv4Address(host_int)}/32")

            # IPv6 peer subnet
            peer_net = ipv6_peer_subnet(ctrl["v6_subnet"], v6peer_len, peer["v6_peer_id"])
            peer["ipv6"].append(str(peer_net))

    # -----------------------------------------------------------------------
    # Phase 3 - emit JSON, stripping any input ipv4/ipv6 fields
    # -----------------------------------------------------------------------
    STRIP = {"ipv4", "ipv6"}
    network_out: dict = {}

    for ctrl_name, ctrl in controllers.items():
        entry = {k: v for k, v in data[ctrl_name].items() if k not in STRIP}
        entry["ipv4"] = ctrl["ipv4"]
        entry["ipv6"] = ctrl["ipv6"]
        network_out[ctrl_name] = entry

    for peer_name, peer in peers.items():
        entry = {k: v for k, v in data[peer_name].items() if k not in STRIP}
        entry["ipv4"] = peer["ipv4"]
        entry["ipv6"] = peer["ipv6"]
        network_out[peer_name] = entry

    print(json.dumps({
        "instanceName": args.instance_name,
        "ipv4": {
            "root":                 str(root),
            "tenant":               str(ipv4_tenant),
            "tenantCount":          tenant_count,
            "controllersPerTenant": controllers_per_tenant,
        },
        "ipv6": {
            "base":               str(ipv6_base),
            "controllerPrefixLen": v6ctrl_len,
            "peerPrefixLen":       v6peer_len,
        },
        "network": network_out,
    }, indent=2))


if __name__ == "__main__":
    main()

