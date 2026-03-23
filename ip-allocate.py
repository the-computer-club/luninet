#!/usr/bin/env python3

#!/usr/bin/env python3
"""IPv4 + IPv6 address allocator for WireGuard networks.
 
Network layout — IPv4
---------------------
- Root:        configurable CIDR            (default: 172.25.0.0/16)
- Tenant:      configurable prefix len      (default: /21)  carved from root
- Controllers: configurable prefix len      (default: /24)  carved from tenant, sequential
- Controller host address: always .1 within its subnet
- Peers:       /32 host addresses inside each controller's subnet, sequential from .2
 
  If a controller has an explicit ipv4 field in the JSON, that subnet is used
  directly instead of being allocated sequentially from the tenant block.
 
Network layout — IPv6
---------------------
- Base:        ULA fd.../N                  (default: /48)  derived from instance_name
- Controllers: configurable prefix len      (default: /64)  carved from base
- Peers:       configurable prefix len      (default: /96)  carved from controller,
               suffix from SHA-256 of peer_name, reused identically across all controllers.
 
  If a controller has an explicit ipv6 field in the JSON, that subnet is used
  directly instead of being derived from the base.
 
Usage
-----
  allocator.py [options] <instance_name> <json_file>
 
IPv4 options:
  --root CIDR           IPv4 root network            (default: 172.25.0.0/16)
  --tenant LEN          tenant prefix len            (default: 21)
  --controller LEN      controller prefix len        (default: 24)
 
IPv6 options:
  --6base LEN           ULA base prefix len          (default: 48)
  --6controller LEN     controller prefix len        (default: 64)
  --6peer LEN           peer subnet prefix len       (default: 96)
  --6instance-bits BITS bits of instance hash in ULA prefix (default: --6base - 8)
 
Examples
--------
  allocator.py luni network.json
  allocator.py --root 10.0.0.0/8 --tenant 16 --controller 24 luni network.json
  allocator.py --6base 48 --6controller 64 --6peer 96 luni network.json
"""
import argparse
import ipaddress
import json
import hashlib
import sys
 
 
# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
 
def hash_int(s: str) -> int:
    return int(hashlib.sha256(s.encode()).hexdigest(), 16)
 
 
def top_bits(value: int, n: int, source_width: int = 256) -> int:
    return value >> (source_width - n)
 
 
def is_controller(vals: dict) -> bool:
    return bool(vals.get("controller") or vals.get("isController"))
 
 
# ---------------------------------------------------------------------------
# IPv4
# ---------------------------------------------------------------------------
 
def ipv4_tenant_subnet(
    root: ipaddress.IPv4Network,
    tenant_prefix_len: int,
    instance_name: str,
) -> ipaddress.IPv4Network:
    """Pick a tenant block from *root* based on a hash of *instance_name*."""
    tenant_count = 2 ** (tenant_prefix_len - root.prefixlen)
    tenant_index = top_bits(hash_int(instance_name), 8) % tenant_count
    tenant_int = int(root.network_address) + tenant_index * (2 ** (32 - tenant_prefix_len))
    return ipaddress.IPv4Network((tenant_int, tenant_prefix_len))
 
 
def ipv4_subnets(
    tenant: ipaddress.IPv4Network,
    controller_prefix_len: int,
) -> list[ipaddress.IPv4Network]:
    """Return all controller-sized subnets within *tenant*, in order."""
    return list(tenant.subnets(new_prefix=controller_prefix_len))
 
 
# ---------------------------------------------------------------------------
# IPv6
# ---------------------------------------------------------------------------
 
def ipv6_ula_base(
    instance_name: str,
    base_prefix_len: int,
    instance_hash_bits: int,
) -> ipaddress.IPv6Network:
    h = hash_int(instance_name)
    hash_segment = top_bits(h, instance_hash_bits)
    fd_int = 0xfd << 120
    hash_placed = hash_segment << (128 - 8 - instance_hash_bits)
    return ipaddress.IPv6Network((fd_int | hash_placed, base_prefix_len))
 
 
def ipv6_controller_subnet(
    base: ipaddress.IPv6Network,
    controller_prefix_len: int,
    controller_name: str,
) -> ipaddress.IPv6Network:
    h = hash_int(controller_name)
    id_bits = controller_prefix_len - base.prefixlen
    controller_id = top_bits(h, id_bits)
    subnet_int = int(base.network_address) | (controller_id << (128 - controller_prefix_len))
    return ipaddress.IPv6Network((subnet_int, controller_prefix_len))
 
 
def ipv6_peer_subnet(
    controller_subnet: ipaddress.IPv6Network,
    peer_prefix_len: int,
    peer_name: str,
) -> ipaddress.IPv6Network:
    peer_id_bits = peer_prefix_len - controller_subnet.prefixlen
    peer_id = top_bits(hash_int(peer_name), 64) >> (64 - peer_id_bits)
    peer_int = int(controller_subnet.network_address) | (peer_id << (128 - peer_prefix_len))
    return ipaddress.IPv6Network((peer_int, peer_prefix_len))
 
 
# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
 
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="IPv4 + IPv6 WireGuard address allocator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    v4 = p.add_argument_group("IPv4")
    v4.add_argument("--root", default="172.25.0.0/16", metavar="CIDR",
                    help="IPv4 root network (default: 172.25.0.0/16)")
    v4.add_argument("--tenant", type=int, default=21, metavar="LEN",
                    help="tenant prefix length (default: 21)")
    v4.add_argument("--controller", type=int, default=24, metavar="LEN",
                    help="controller prefix length (default: 24)")
    v6 = p.add_argument_group("IPv6")
    v6.add_argument("--6base", dest="v6base", type=int, default=48, metavar="LEN",
                    help="ULA base prefix length (default: 48)")
    v6.add_argument("--6controller", dest="v6controller", type=int, default=64, metavar="LEN",
                    help="controller subnet prefix length (default: 64)")
    v6.add_argument("--6peer", dest="v6peer", type=int, default=96, metavar="LEN",
                    help="peer subnet prefix length (default: 96)")
    v6.add_argument("--6instance-bits", dest="v6instance_bits", type=int, default=None,
                    metavar="BITS",
                    help="bits of instance hash in ULA prefix (default: --6base - 8)")
    p.add_argument("instance_name")
    p.add_argument("json_file")
    return p.parse_args()
 
 
def validate(
    root: ipaddress.IPv4Network,
    tenant_len: int,
    controller_len: int,
    v6base_len: int,
    v6ctrl_len: int,
    v6peer_len: int,
    v6instance_bits: int,
) -> None:
    errors = []
    if tenant_len < root.prefixlen:
        errors.append(f"--tenant {tenant_len} must be >= root prefix /{root.prefixlen}")
    if controller_len < tenant_len:
        errors.append(f"--controller {controller_len} must be > --tenant {tenant_len}")
    if controller_len > 30:
        errors.append(f"--controller {controller_len} must be <= 30")
    if not (8 < v6base_len < 128):
        errors.append(f"--6base {v6base_len} must be between 9 and 127")
    if v6ctrl_len <= v6base_len:
        errors.append(f"--6controller {v6ctrl_len} must be > --6base {v6base_len}")
    if v6peer_len <= v6ctrl_len:
        errors.append(f"--6peer {v6peer_len} must be > --6controller {v6ctrl_len}")
    if v6peer_len > 128:
        errors.append(f"--6peer {v6peer_len} must be <= 128")
    if (v6peer_len - v6ctrl_len) > 64:
        errors.append(
            f"--6peer {v6peer_len} - --6controller {v6ctrl_len} exceeds 64-bit peer suffix; "
            f"max --6peer is {v6ctrl_len + 64}"
        )
    if not (1 <= v6instance_bits <= v6base_len - 8):
        errors.append(
            f"--6instance-bits {v6instance_bits} must be between 1 and {v6base_len - 8}"
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
 
    v6instance_bits = args.v6instance_bits if args.v6instance_bits is not None else args.v6base - 8
    validate(root, args.tenant, args.controller, args.v6base, args.v6controller, args.v6peer, v6instance_bits)
 
    with open(args.json_file) as f:
        data = json.load(f)
 
    ctrl_len = args.controller
    v6ctrl_len = args.v6controller
    v6peer_len = args.v6peer
 
    # IPv4 tenant block and available controller subnets
    ipv4_tenant = ipv4_tenant_subnet(root, args.tenant, args.instance_name)
    available_subnets = ipv4_subnets(ipv4_tenant, ctrl_len)
    subnet_iter = iter(available_subnets)
 
    # IPv6 ULA base
    ipv6_base = ipv6_ula_base(args.instance_name, args.v6base, v6instance_bits)
 
    STRIP = {"ipv4", "ipv6"}
 
    # -----------------------------------------------------------------------
    # Phase 1 — controllers
    # -----------------------------------------------------------------------
    controllers: dict[str, dict] = {}
 
    for hostname, vals in data.items():
        if not is_controller(vals):
            continue
 
        # IPv4: use pinned subnet if provided, otherwise take the next sequential one
        pinned_v4 = vals.get("ipv4")
        if pinned_v4:
            raw = pinned_v4 if isinstance(pinned_v4, str) else pinned_v4[0]
            v4_subnet = ipaddress.IPv4Network(raw, strict=False)
        else:
            try:
                v4_subnet = next(subnet_iter)
            except StopIteration:
                print(
                    f"ERROR: ran out of /{ctrl_len} subnets in {ipv4_tenant} "
                    f"while allocating controller '{hostname}'",
                    file=sys.stderr,
                )
                sys.exit(1)
 
        # IPv6: use pinned subnet if provided, otherwise derive from base
        pinned_v6 = vals.get("ipv6")
        if pinned_v6:
            raw6 = pinned_v6 if isinstance(pinned_v6, str) else pinned_v6[0]
            v6_subnet = ipaddress.IPv6Network(raw6, strict=False)
        else:
            v6_subnet = ipv6_controller_subnet(ipv6_base, v6ctrl_len, hostname)
 
        # Controller always takes the first host address (.1)
        ctrl_host_v4 = str(ipaddress.IPv4Address(int(v4_subnet.network_address) + 1))
 
        controllers[hostname] = {
            "v4_subnet":    v4_subnet,
            "v6_subnet":    v6_subnet,
            "ipv4":         [f"{ctrl_host_v4}/{ctrl_len}"],
            "ipv6":         [str(v6_subnet)],
            "_next_peer":   2,   # peers start at .2
        }
 
    # -----------------------------------------------------------------------
    # Phase 2 — peers
    # -----------------------------------------------------------------------
    peers: dict[str, dict] = {}
 
    for hostname, vals in data.items():
        if is_controller(vals):
            continue
 
        ipv4_addrs = []
        ipv6_addrs = []
 
        for ctrl in controllers.values():
            # IPv4 /32 — sequential from .2
            offset = ctrl["_next_peer"]
            host_int = int(ctrl["v4_subnet"].network_address) + offset
            ipv4_addrs.append(f"{ipaddress.IPv4Address(host_int)}/32")
            ctrl["_next_peer"] += 1
 
            # IPv6 peer subnet
            ipv6_addrs.append(str(ipv6_peer_subnet(ctrl["v6_subnet"], v6peer_len, hostname)))
 
        peers[hostname] = {"ipv4": ipv4_addrs, "ipv6": ipv6_addrs}
 
    # -----------------------------------------------------------------------
    # Phase 3 — emit JSON
    # -----------------------------------------------------------------------
    network_out: dict = {}
 
    for name, ctrl in controllers.items():
        entry = {k: v for k, v in data[name].items() if k not in STRIP}
        entry["ipv4"] = ctrl["ipv4"]
        entry["ipv6"] = ctrl["ipv6"]
        network_out[name] = entry
 
    for name, peer in peers.items():
        entry = {k: v for k, v in data[name].items() if k not in STRIP}
        entry["ipv4"] = peer["ipv4"]
        entry["ipv6"] = peer["ipv6"]
        network_out[name] = entry
 
    tenant_count = 2 ** (args.tenant - root.prefixlen)
    controllers_per_tenant = 2 ** (ctrl_len - args.tenant)
 
    print(json.dumps({
        "instanceName": args.instance_name,
        "ipv4": {
            "root":                 str(root),
            "tenant":               str(ipv4_tenant),
            "tenantCount":          tenant_count,
            "controllersPerTenant": controllers_per_tenant,
        },
        "ipv6": {
            "base":                str(ipv6_base),
            "instanceHashBits":    v6instance_bits,
            "controllerPrefixLen": v6ctrl_len,
            "peerPrefixLen":       v6peer_len,
        },
        "network": network_out,
    }, indent=2))
 
 
if __name__ == "__main__":
    main()
