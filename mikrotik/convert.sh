#!/usr/bin/env sh
# convert inventory.json to a mikrotik peer list.
jq '[
  .network | to_entries[] |
  {
    "public-key": .value.publicKey,
    "allowed-address": (
      (.value.ipv4 + (.value.ipv6 // [])) | join(",")
    ),
    "comment": .key
  }
]' "${1:--}"
