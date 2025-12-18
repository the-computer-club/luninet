#!/usr/bin/env python3
"""IPv6 address allocator for WireGuard networks.

Network layout:
- Base network: /40 ULA prefix (fd00::/8 + 32 bits from hash)
- Controllers: Each gets a /56 subnet from the base /40 (256 controllers max)
- Peers: Each gets a /96 subnet from their controller's /56
"""
import json
import hashlib
import ipaddress
import sys
from pathlib import Path

# Constants for argument count validation
MIN_ARGS_BASE = 3
MIN_ARGS_CONTROLLER = 4
MIN_ARGS_PEER = 4


def hash_string(s: str) -> str:
    """Generate SHA256 hash of string."""
    return hashlib.sha256(s.encode()).hexdigest()


def generate_ula_prefix(instance_name: str) -> ipaddress.IPv6Network:
    """Generate a /40 ULA prefix from instance name.

    Format: fd{32-bit hash}/40
    This gives us fd00:0000:0000::/40 through fdff:ffff:ff00::/40
    """
    h = hash_string(instance_name)

    # For /40, we need 32 bits after 'fd' (8 hex chars)
    # But only the first 32 bits count for the network prefix
    # The last 8 bits of the 40-bit prefix must be 0
    prefix_bits = int(h[:8], 16)

    # Mask to ensure we only use the first 32 bits for /40
    # This gives us addresses like fd28:387a::/40
    prefix_bits = prefix_bits & 0xFFFFFF00  # Clear last 8 bits

    # Format as IPv6 address
    prefix = f"fd{prefix_bits:08x}"
    prefix_formatted = f"{prefix[:4]}:{prefix[4:8]}::/40"

    return ipaddress.IPv6Network(prefix_formatted)


def generate_controller_subnet(
    base_network: ipaddress.IPv6Network,
    controller_name: str,
) -> ipaddress.IPv6Network:
    """Generate a /56 subnet for a controller from the base /40 network.

    We have 16 bits (40 to 56) to allocate controller subnets.
    This allows for 65,536 possible controller subnets.
    """
    h = hash_string(controller_name)
    # Take 16 bits from hash for the controller subnet ID
    controller_id = int(h[:4], 16)

    # Create the controller subnet by adding the controller ID to the base network
    # The controller subnet is at base_prefix:controller_id::/56
    base_int = int(base_network.network_address)
    controller_subnet_int = base_int | (controller_id << (128 - 56))
    return ipaddress.IPv6Network((controller_subnet_int, 56))


def generate_peer_suffix(peer_name: str) -> str:
    """Generate a unique 64-bit host suffix for a peer.

    This suffix will be used in all controller subnets to create unique addresses.
    Format: :xxxx:xxxx:xxxx:xxxx (64 bits)
    """
    h = hash_string(peer_name)
    # Take 64 bits (16 hex chars) from hash for the host suffix
    suffix_bits = h[:16]

    # Format as IPv6 suffix without leading colon
    return f"{suffix_bits[0:4]}:{suffix_bits[4:8]}:{suffix_bits[8:12]}:{suffix_bits[12:16]}"


def main() -> None:
    if len(sys.argv) < 1:
        print(
            "Usage: ipv6_allocator.py <instance_name> <jsonFile>",
            """{ "hostname": { "publicKey": "...",  } }"""

        )
        sys.exit(1)

    instance_name = sys.argv[1]

    # Generate base /40 network
    base_network = generate_ula_prefix(instance_name)

    payload = sys.argv[2]

    with open(payload) as fd:
      data = json.load(fd)

    inventory = dict();

    prefixes = dict();
    suffixes = dict();

    for hostname, vals in data.items():
      if "controller" in vals and vals["controller"]:
        subnet = generate_controller_subnet(base_network, hostname)
        prefix_str = str(subnet).split("/")[0].rstrip(":")
        while prefix_str.endswith(":"):
            prefix_str = prefix_str.rstrip(":")
        prefixes[hostname] = prefix_str
      else:
        suffixes[hostname] = generate_peer_suffix(hostname)

    view = {};
    for controller, prefix in prefixes.items():
      for hostname, suffix in suffixes.items():
        if not hostname in view:
            view[hostname] = { "ipv6": [] }

        view[hostname]["ipv6"].append(f"{prefix}:{suffix}::/96")


      # controller_view[controller] = peers

    controllers = dict()
    for k, x in prefixes.items():
      controllers[k] = { "ipv6": [ f"{x}::/56" ] }



    print(json.dumps(
      view | controllers
    ))


if __name__ == "__main__":
    main()
