# MikroTik Setup

MikroTik routers can participate in the asluni mesh by periodically fetching the peer list from the network's HTTP endpoint and automatically syncing their WireGuard peer configuration. This means you don't need to manually update peers when someone joins or leaves — the router handles it on a schedule.

---

## Contents

1. [Prerequisites](#prerequisites)
2. [Generate the Peer JSON](#generate-the-peer-json)
3. [Host the Peer Endpoint](#host-the-peer-endpoint)
4. [Configure the Sync Script](#configure-the-sync-script)
5. [Schedule Automatic Sync](#schedule-automatic-sync)
6. [Verify](#verify)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- A MikroTik router running RouterOS 7.x (WireGuard support and JSON deserialization require 7.x)
- A WireGuard interface already created on the router (referred to as `wg0` below)
- The router must be able to reach the URL hosting `peers.json` over HTTPS
- Your router's public key must be [registered in peers.nix](./joining.md)

---

## Generate the Peer JSON

The `convert.sh` script transforms `inventory.json` (the canonical peer list) into a flat JSON array suitable for the router to consume.

```sh
./mikrotik/convert.sh inventory.json
```

Output format:

```json
[
  {
    "pubkey": "base64pubkey==",
    "allowed-ips": "172.29.80.2/32",
    "endpoint": "1.2.3.4:51820"
  },
  {
    "pubkey": "anotherkey==",
    "allowed-ips": "172.29.80.3/32"
  }
]
```

Peers without a `selfEndpoint` will have no `endpoint` field. The sync script handles both cases.

---

## Configuration for a Controller

Paste the following into a RouterOS terminal. Update `interface` for your setup before running.

```rsc
/system/script add \
    name="luninet-sync" \
    policy=read,write,test \
    source="
:local url \"https://github.com/the-computer-club/luninet/releases/download/latest/luni-controllers.json\"
:local interface \"wg0\"
:local ownKey [/interface/wireguard get \$interface public-key]

:local result [/tool/fetch url=\$url as-value output=user]
:local body (\$result->\"data\")
:local peers [:deserialize value=\$body from=json]

# Build a set of desired public keys
:local desiredKeys [:toarray \"\"]
:foreach peer in=\$peers do={
    :local pubkey (\$peer->\"public-key\")
    :if (\$pubkey != \$ownKey) do={
        :set (\$desiredKeys->\$pubkey) true
    }
}

# Remove peers no longer in the list
:foreach p in=[/interface/wireguard/peers find interface=\$interface] do={
    :local existingKey [/interface/wireguard/peers get \$p public-key]
    :if ([:typeof (\$desiredKeys->\$existingKey)] = \"nothing\") do={
        /interface/wireguard/peers remove \$p
        :log info \"WG sync: removed peer \$existingKey\"
    }
}

# Add or update peers
:foreach peer in=\$peers do={
    :local pubkey (\$peer->\"public-key\")
    :if (\$pubkey = \$ownKey) do={
        :log info \"WG sync: skipping own key\"
    } else={
        :local peerName (\$peer->\"name\")
        :local allowedips (\$peer->\"allowed-address\")
        :local endpointAddr (\$peer->\"endpoint-address\")
        :local endpointPort (\$peer->\"endpoint-port\")
        :local existing [/interface/wireguard/peers find public-key=\$pubkey interface=\$interface]

        :if ([:len \$existing] = 0) do={
            :if (\$endpointAddr != \"\") do={
                /interface/wireguard/peers add \
                    interface=\$interface \
                    public-key=\$pubkey \
                    allowed-address=\$allowedips \
                    endpoint-address=\$endpointAddr \
                    endpoint-port=\$endpointPort \
                    name=\$peerName
            } else={
                /interface/wireguard/peers add \
                    interface=\$interface \
                    public-key=\$pubkey \
                    allowed-address=\$allowedips \
                    name=\$peerName
            }
            :log info \"WG sync: added peer \$peerName\"
        } else={
            :if (\$endpointAddr != \"\") do={
                /interface/wireguard/peers set \$existing \
                    allowed-address=\$allowedips \
                    endpoint-address=\$endpointAddr \
                    endpoint-port=\$endpointPort \
                    name=\$peerName
            } else={
                /interface/wireguard/peers set \$existing \
                    allowed-address=\$allowedips \
                    name=\$peerName
            }
            :log info \"WG sync: updated peer \$peerName\"
        }
    }
}
"
```

### What the script does

The script runs in three passes:

1. **Fetch** — downloads `peers.json` from the configured URL and deserializes it
2. **Prune** — walks existing peers on the interface and removes any whose public key is no longer in the fetched list
3. **Sync** — for each peer in the fetched list, adds it if it doesn't exist or updates its address/endpoint if it does

Peers without an `endpoint` field (i.e. no `selfEndpoint` in `peers.nix`) are added as roaming peers — WireGuard will learn their address dynamically when they initiate traffic.

---

## Schedule Automatic Sync

Once you've confirmed the script works (see [Verify](#verify) below), add a scheduler to run it every 5 minutes and on every startup:

```rsc
/system/scheduler add \
    name="wg-peer-sync" \
    interval=5m \
    start-time=startup \
    on-event="/system/script run wg-peer-sync" \
    policy=read,write,test
```

---

## Verify

### Run the script manually

```rsc
/system/script run wg-peer-sync
```

### Check the log

```rsc
/log print where message~"WG sync"
```

You should see `added peer` or `removed peer` lines for any changes made. If the peer list was already up to date, no log lines will appear — that's normal.

### Check the peer table

```rsc
/interface/wireguard/peers print where interface=wg0
```

Peers should now match the current contents of `peers.json`.

### Test connectivity

```rsc
/tool/ping 172.29.80.1
```

If you get replies, the tunnel and peer configuration are working correctly.

---

## Troubleshooting

**`/tool/fetch` fails with a TLS error**

RouterOS needs to trust the CA that issued the certificate on your HTTPS endpoint. If you're using Let's Encrypt, import the ISRG Root X1 certificate into `/certificate`. If you're hosting on GitHub or another large provider this should work out of the box.

**Script runs but no peers are added**

  * [ ] Check that the JSON at your endpoint is valid and matches the expected format. You can test the fetch in isolation:

```rsc
:put [/tool/fetch url="https://your-endpoint.example.com/peers.json" as-value output=user]
```

Also verify that `$interface` matches the exact name of your WireGuard interface (`/interface/wireguard print`).

**Peers are repeatedly added and removed on each run**

The public keys in `peers.json` may not match what RouterOS has stored — possibly a trailing newline or encoding difference introduced by `convert.sh` or your hosting setup. Check the raw file with `curl -s <url> | cat -A` and confirm there are no unexpected characters.

**The scheduler isn't running**

Check that the scheduler exists and has the correct policy:

```rsc
/system/scheduler print
```

RouterOS requires the `test` policy for `/tool/fetch` to make outbound HTTP requests.
