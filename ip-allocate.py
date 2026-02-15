#!/usr/bin/env python3

#!/usr/bin/env python3
"""IPv4 + IPv6 address allocator for WireGuard networks.

Network layout — IPv4
---------------------
- Root:        172.25.0.0/16  (fixed)
- Tenant:      /21 carved from the /16  — 32 possible tenants
               Chosen by hashing instance_name.
- Controllers: /24 carved from the tenant /21 — 8 possible per tenant
               Chosen by hashing controller_name; linear-probe on collision.
- Peers:       /32 host address inside each controller's /24.
               Last octet = sum(ord(c)+10 for c in name) % 255, clamped to
               [1, 254].  Collisions resolved by decrementing (wrapping 1–254).

Network layout — IPv6
---------------------
- Base:        /40 ULA prefix  fd{32-bit hash}::/40  derived from instance_name
- Controllers: /56 subnet from the base /40 (up to 65,536 controllers)
               Chosen by hashing controller_name (no collision handling needed
               — the 16-bit space makes collisions astronomically unlikely).
- Peers:       /96 subnet from each controller's /56
               64-bit suffix derived from SHA-256 of peer_name, reused across
               all controllers.

Input JSON
----------
{
  "hostname": {
    "publicKey":    "...",
    "isController": true,       // or "controller": true
    "selfEndpoint": "ip:port",  // optional, controllers only
    "ipv4": [...],              // ignored — always recomputed
    "ipv6": [...]               // ignored — always recomputed
  }
}

Output JSON
-----------
{
  "instanceName": "...",
  "ipv4": { "root": "172.25.0.0/16", "tenant": "172.25.X.0/21" },
  "ipv6": { "ula": "fdXX:XXXX::/40" },
  "network": {
    "hostname": {
      ...,               // passthrough fields (publicKey, selfEndpoint, …)
      "ipv4": [...],     // /24 for controllers, /32 per controller for peers
      "ipv6": [...]      // /56 for controllers, /96 per controller for peers
    }
  }
}
"""
import json
import hashlib
import ipaddress
import sys


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

IPV4_ROOT = ipaddress.IPv4Network("172.25.0.0/16")
TENANT_PREFIX_LEN = 21
TENANT_COUNT = 2 ** (TENANT_PREFIX_LEN - IPV4_ROOT.prefixlen)          # 32
CONTROLLER_PREFIX_LEN = 24
CONTROLLERS_PER_TENANT = 2 ** (CONTROLLER_PREFIX_LEN - TENANT_PREFIX_LEN)  # 8
IPV4_RESERVED = {0, 255}


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def hash_string(s: str) -> str:
    """SHA-256 hex digest of *s*."""
    return hashlib.sha256(s.encode()).hexdigest()


def is_controller(vals: dict) -> bool:
    return bool(vals.get("controller") or vals.get("isController"))


# ---------------------------------------------------------------------------
# IPv4 allocation
# ---------------------------------------------------------------------------

def ipv4_tenant_subnet(instance_name: str) -> ipaddress.IPv4Network:
    """Return the /21 tenant block for *instance_name*."""
    h = hash_string(instance_name)
    tenant_index = int(h[:2], 16) % TENANT_COUNT
    root_int = int(IPV4_ROOT.network_address)
    tenant_int = root_int + tenant_index * (2 ** (32 - TENANT_PREFIX_LEN))
    return ipaddress.IPv4Network((tenant_int, TENANT_PREFIX_LEN))


def ipv4_controller_subnet(
    tenant_network: ipaddress.IPv4Network,
    controller_name: str,
    allocated_slots: dict[str, int],
) -> ipaddress.IPv4Network:
    """
        Return a /24 inside *tenant_network* for *controller_name*.
        8 /24's inside of the /21
    """

    h = hash_string(controller_name)
    
    candidate = int(h[:2], 16) % CONTROLLERS_PER_TENANT

    used = set(allocated_slots.values())
    for _ in range(CONTROLLERS_PER_TENANT):
        if candidate not in used:
            allocated_slots[controller_name] = candidate
            tenant_int = int(tenant_network.network_address)
            subnet_int = tenant_int + candidate * (2 ** (32 - CONTROLLER_PREFIX_LEN))
            return ipaddress.IPv4Network((subnet_int, CONTROLLER_PREFIX_LEN))
        candidate = (candidate + 1) % CONTROLLERS_PER_TENANT

    print(
        f"ERROR: Cannot allocate a /24 for controller '{controller_name}': "
        f"all {CONTROLLERS_PER_TENANT} slots in {tenant_network} are in use.",
        file=sys.stderr,
    )
    sys.exit(1)


def ipv4_peer_suffix(peer_name: str) -> int:
    """Return the preferred last-octet value for *peer_name* (1–254)."""
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

def ipv6_ula_prefix(instance_name: str) -> ipaddress.IPv6Network:
    """Return the /40 ULA base for *instance_name*.  Format: fd{32-bit hash}::/40"""
    h = hash_string(instance_name)
    prefix_bits = int(h[:8], 16) & 0xFFFFFF00  # clear last 8 bits for /40
    prefix = f"fd{prefix_bits:08x}"
    return ipaddress.IPv6Network(f"{prefix[:4]}:{prefix[4:8]}::/40")


def ipv6_controller_subnet(
    base_network: ipaddress.IPv6Network,
    controller_name: str,
) -> ipaddress.IPv6Network:
    """Return a /56 inside *base_network* for *controller_name*."""
    h = hash_string(controller_name)
    controller_id = int(h[:4], 16)  # 16 bits → up to 65,536 controllers
    base_int = int(base_network.network_address)
    subnet_int = base_int | (controller_id << (128 - 56))
    return ipaddress.IPv6Network((subnet_int, 56))


def ipv6_peer_suffix(peer_name: str) -> str:
    """Return a 64-bit host suffix for *peer_name*.  Format: xxxx:xxxx:xxxx:xxxx"""
    h = hash_string(peer_name)
    b = h[:16]
    return f"{b[0:4]}:{b[4:8]}:{b[8:12]}:{b[12:16]}"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    if len(sys.argv) < 3:
        print(
            "Usage: allocator.py <instance_name> <json_file>\n"
            'JSON: { "hostname": { "publicKey": "...", "isController": true|false } }',
            file=sys.stderr,
        )
        sys.exit(1)

    instance_name = sys.argv[1]
    payload_path  = sys.argv[2]

    with open(payload_path) as fd:
        data = json.load(fd)

    # -- IPv4 tenant block ---------------------------------------------------
    ipv4_tenant = ipv4_tenant_subnet(instance_name)
    ipv4_slots: dict[str, int] = {}

    # -- IPv6 ULA base -------------------------------------------------------
    ipv6_base = ipv6_ula_prefix(instance_name)

    # -----------------------------------------------------------------------
    # Phase 1 – classify nodes, allocate controller subnets
    # -----------------------------------------------------------------------
    controllers: dict[str, dict] = {}
    peers:       dict[str, dict] = {}

    for hostname, vals in data.items():
        if is_controller(vals):
            v4_subnet = ipv4_controller_subnet(ipv4_tenant, hostname, ipv4_slots)
            v6_subnet = ipv6_controller_subnet(ipv6_base, hostname)
            v6_prefix = str(v6_subnet).split("/")[0].rstrip(":")

            controllers[hostname] = {
                "v4_subnet":  v4_subnet,
                "v6_subnet":  v6_subnet,
                "v6_prefix":  v6_prefix,
                "ipv4":       [str(v4_subnet)],
                "ipv6":       [f"{v6_prefix}::/56"],
                "_v4_occupied": set(),
            }
        else:
            peers[hostname] = {
                "v4_preferred": ipv4_peer_suffix(hostname),
                "v6_suffix":    ipv6_peer_suffix(hostname),
                "ipv4":         [],
                "ipv6":         [],
            }

    # -----------------------------------------------------------------------
    # Phase 2 – assign each peer an address inside every controller's block
    # -----------------------------------------------------------------------
    for peer_name, peer in peers.items():
        for ctrl_name, ctrl in controllers.items():
            # IPv4 /32
            last_octet = ipv4_allocate_peer(
                ctrl["v4_subnet"], peer["v4_preferred"], ctrl["_v4_occupied"]
            )
            ctrl["_v4_occupied"].add(last_octet)
            host_int  = int(ctrl["v4_subnet"].network_address) | last_octet
            peer["ipv4"].append(f"{ipaddress.IPv4Address(host_int)}/32")

            # IPv6 /96
            prefix = ctrl["v6_prefix"]
            suffix = peer["v6_suffix"]
            peer["ipv6"].append(f"{prefix}:{suffix}::/96")

    # -----------------------------------------------------------------------
    # Phase 3 – emit JSON, stripping input ipv4/ipv6 fields
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
        "instanceName": instance_name,
        "ipv4": {
            "root":   str(IPV4_ROOT),
            "tenant": str(ipv4_tenant),
        },
        "ipv6": {
            "ula": str(ipv6_base),
        },
        "network": network_out,
    }, indent=2))


if __name__ == "__main__":
    main()
