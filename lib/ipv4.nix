# ipv4.nix — an IPv4 subnet calculator written in pure Nix.
#
# No dependencies: no nixpkgs, no `lib`, no import-from-derivation. Everything
# is evaluation-time integer arithmetic, so it works from a flake, an overlay,
# a NixOS module, or plain `nix eval`.
#
#     let ipv4 = import ./ipv4.nix; in ipv4.subnet "192.168.1.130/26"
#
#     => { addressCount = 64; broadcast = "192.168.1.191";
#          cidr = "192.168.1.128/26"; firstHost = "192.168.1.129"; ... }
#
# Anything called a "block" below accepts three spellings:
#
#     "192.168.1.0/24"              CIDR
#     "192.168.1.0/255.255.254.0"   address plus netmask
#     "192.168.1.7"                 bare address, treated as /32
#
# Octets with leading zeros ("192.168.01.1") are rejected on purpose: some
# stacks read them as octal and others as decimal, so they are never safe.
#
# Run the test suite with:  nix eval -f ./ipv4.nix selfTest   ([ ] means pass)

let
  inherit (builtins)
    attrNames bitAnd bitOr concatStringsSep deepSeq elemAt filter foldl' genList
    head isInt isList isString length match stringLength substring tryEval
    typeOf;

  ## ------------------------------------------------------------------
  ## internals
  ## ------------------------------------------------------------------

  maxAddress = 4294967295; # 2^32 - 1

  # Ceiling on the list-producing helpers, so that a slip like
  # `subdivide "10.0.0.0/8" 32` fails with a message rather than eating all
  # the memory on the machine during evaluation.
  listLimit = 65536;

  upTo = n: genList (i: i) n; # [ 0 1 ... n-1 ]

  pow2 = e: foldl' (acc: _: acc * 2) 1 (upTo e);

  slice = from: count: xs: genList (i: elemAt xs (from + i)) count;

  show = v: if isString v then "\"" + v + "\"" else "<" + typeOf v + ">";

  digitOf = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
  };

  # Only ever fed regex-validated digit strings, which is also why it may
  # differ from `lib.toInt`: leading zeros stay decimal here.
  toInt = s:
    foldl' (acc: i: acc * 10 + digitOf.${substring i 1 s}) 0
      (upTo (stringLength s));

  # POSIX extended regex, fully anchored by builtins.match. The octet
  # alternation validates the 0..255 range and bans leading zeros in one go.
  octetPat = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])";
  addressPat = "${octetPat}\\.${octetPat}\\.${octetPat}\\.${octetPat}";
  prefixPat = "(3[0-2]|[12][0-9]|[0-9])";
  cidrPat = "${addressPat}/${prefixPat}";
  maskedPat = "${addressPat}/${addressPat}";

  fromOctets = o:
    elemAt o 0 * 16777216 + elemAt o 1 * 65536 + elemAt o 2 * 256 + elemAt o 3;

  toOctets = n: [
    (bitAnd (n / 16777216) 255)
    (bitAnd (n / 65536) 255)
    (bitAnd (n / 256) 255)
    (bitAnd n 255)
  ];

  classOfOctet = o:
    if o < 128 then "A"
    else if o < 192 then "B"
    else if o < 224 then "C"
    else if o < 240 then "D"
    else "E";

  # Most specific first: 255.255.255.255/32 sits inside 240.0.0.0/4.
  specialBlocks = [
    { cidr = "0.0.0.0/8"; scope = "this-network"; } # RFC 1122
    { cidr = "10.0.0.0/8"; scope = "private"; } # RFC 1918
    { cidr = "100.64.0.0/10"; scope = "shared"; } # RFC 6598 (CGNAT)
    { cidr = "127.0.0.0/8"; scope = "loopback"; } # RFC 1122
    { cidr = "169.254.0.0/16"; scope = "link-local"; } # RFC 3927
    { cidr = "172.16.0.0/12"; scope = "private"; } # RFC 1918
    { cidr = "192.0.0.0/24"; scope = "ietf-protocol"; } # RFC 6890
    { cidr = "192.0.2.0/24"; scope = "documentation"; } # RFC 5737
    { cidr = "192.88.99.0/24"; scope = "6to4-relay"; } # RFC 7526
    { cidr = "192.168.0.0/16"; scope = "private"; } # RFC 1918
    { cidr = "198.18.0.0/15"; scope = "benchmarking"; } # RFC 2544
    { cidr = "198.51.100.0/24"; scope = "documentation"; } # RFC 5737
    { cidr = "203.0.113.0/24"; scope = "documentation"; } # RFC 5737
    { cidr = "224.0.0.0/4"; scope = "multicast"; } # RFC 5771
    { cidr = "255.255.255.255/32"; scope = "broadcast"; } # RFC 8190
    { cidr = "240.0.0.0/4"; scope = "reserved"; } # RFC 1112
  ];

  ## ------------------------------------------------------------------
  ## addresses
  ## ------------------------------------------------------------------

  # parseAddress :: String -> Int
  parseAddress = s:
    let m = if isString s then match addressPat s else null;
    in if m == null
    then throw "ipv4.parseAddress: ${show s} is not a dotted-quad IPv4 address"
    else fromOctets (map toInt m);

  # toAddress :: Int -> String
  toAddress = n:
    if !isInt n then
      throw "ipv4.toAddress: expected an integer, got ${show n}"
    else if n < 0 || n > maxAddress then
      throw "ipv4.toAddress: ${toString n} is outside 0..${toString maxAddress}"
    else concatStringsSep "." (map toString (toOctets n));

  isValidAddress = s: isString s && match addressPat s != null;

  ## ------------------------------------------------------------------
  ## netmasks
  ## ------------------------------------------------------------------

  # netmaskOf :: Int -> Int          netmaskOf 26 == 4294967232
  netmaskOf = prefix:
    if !isInt prefix || prefix < 0 || prefix > 32 then
      throw "ipv4: prefix length must be an integer in 0..32, got ${show prefix}"
    else maxAddress - pow2 (32 - prefix) + 1;

  # prefixOfNetmask :: (String | Int) -> Int
  # Non-contiguous masks such as 255.0.255.0 are rejected.
  prefixOfNetmask = mask:
    let
      value = if isString mask then parseAddress mask else mask;
      hits = filter (p: netmaskOf p == value) (upTo 33);
    in
    if hits == [ ] then
      throw "ipv4.prefixOfNetmask: ${show mask} is not a contiguous netmask"
    else head hits;

  ## ------------------------------------------------------------------
  ## blocks
  ## ------------------------------------------------------------------

  # parseBlock :: String -> { address :: Int; prefixLength :: Int; }
  # The address is kept as written; it is not snapped to the network.
  parseBlock = s:
    if !isString s then
      throw "ipv4: expected a block as a string, got ${show s}"
    else
      let
        c = match cidrPat s;
        m = match maskedPat s;
        a = match addressPat s;
      in
      if c != null then {
        address = fromOctets (map toInt (slice 0 4 c));
        prefixLength = toInt (elemAt c 4);
      }
      else if m != null then {
        address = fromOctets (map toInt (slice 0 4 m));
        prefixLength = prefixOfNetmask (fromOctets (map toInt (slice 4 4 m)));
      }
      else if a != null then {
        address = fromOctets (map toInt a);
        prefixLength = 32;
      }
      else throw "ipv4: cannot parse ${show s} as an IPv4 address or block";

  # bounds :: String -> { lo, hi, address, prefixLength :: Int; }
  # The cheap primitive the comparison helpers are built from.
  bounds = s:
    let
      p = parseBlock s;
      mask = netmaskOf p.prefixLength;
      lo = bitAnd p.address mask;
    in
    {
      inherit lo;
      hi = bitOr lo (maxAddress - mask);
      inherit (p) address prefixLength;
    };

  isValidBlock = s:
    isString s && (tryEval (deepSeq (parseBlock s) true)).success;

  ## ------------------------------------------------------------------
  ## the calculator
  ## ------------------------------------------------------------------

  # classOf :: (String | Int) -> "A" | "B" | "C" | "D" | "E"
  classOf = v:
    classOfOctet (bitAnd ((if isInt v then v else (bounds v).lo) / 16777216) 255);

  # scopeOf :: String -> String
  # The block has to sit entirely inside a reserved range to be labelled by it.
  scopeOf = s:
    let
      b = bounds s;
      hits = filter
        (r: let rb = bounds r.cidr; in b.lo >= rb.lo && b.hi <= rb.hi)
        specialBlocks;
    in
    if hits == [ ] then "public" else (head hits).scope;

  # subnet :: String -> AttrSet
  # The whole report for one block. String fields for display, matching
  # `*Int` fields for arithmetic.
  subnet = s:
    let
      b = bounds s;
      prefix = b.prefixLength;
      mask = netmaskOf prefix;
      hostMask = maxAddress - mask;
      total = pow2 (32 - prefix);
      # /31 (RFC 3021 point-to-point) and /32 have no network/broadcast pair
      # to set aside, so every address in them is usable.
      tiny = prefix >= 31;
      first = if tiny then b.lo else b.lo + 1;
      last = if tiny then b.hi else b.hi - 1;
    in
    {
      cidr = "${toAddress b.lo}/${toString prefix}"; # canonical, network-aligned
      address = toAddress b.address; # as supplied
      addressInt = b.address;
      prefixLength = prefix;
      netmask = toAddress mask;
      netmaskInt = mask;
      wildcard = toAddress hostMask;
      wildcardInt = hostMask;
      network = toAddress b.lo;
      networkInt = b.lo;
      broadcast = toAddress b.hi;
      broadcastInt = b.hi;
      firstHost = toAddress first;
      firstHostInt = first;
      lastHost = toAddress last;
      lastHostInt = last;
      addressCount = total; # every address in the block
      hostCount = if tiny then total else total - 2; # usable ones
      class = classOfOctet (bitAnd (b.lo / 16777216) 255);
      scope = scopeOf s;
      aligned = b.address == b.lo; # was the input already the network address?
    };

  ## ------------------------------------------------------------------
  ## relations
  ## ------------------------------------------------------------------

  # contains :: String -> String -> Bool
  # Curries nicely:  filter (ipv4.contains "10.0.0.0/8") addresses
  contains = block: other:
    let a = bounds block; b = bounds other;
    in b.lo >= a.lo && b.hi <= a.hi;

  # overlaps :: String -> String -> Bool
  overlaps = x: y:
    let a = bounds x; b = bounds y;
    in a.lo <= b.hi && b.lo <= a.hi;

  # supernet :: [ String ] -> String
  # The smallest single block covering every input block.
  supernet = blocks:
    if !isList blocks || blocks == [ ] then
      throw "ipv4.supernet: expected a non-empty list of blocks"
    else
      let
        bs = map bounds blocks;
        lo = foldl' (acc: b: if b.lo < acc then b.lo else acc) (head bs).lo bs;
        hi = foldl' (acc: b: if b.hi > acc then b.hi else acc) (head bs).hi bs;
        fits = filter
          (p: bitAnd lo (netmaskOf p) == bitAnd hi (netmaskOf p))
          (upTo 33);
        prefix = elemAt fits (length fits - 1); # /0 always fits, so never empty
      in
      "${toAddress (bitAnd lo (netmaskOf prefix))}/${toString prefix}";

  ## ------------------------------------------------------------------
  ## splitting and enumerating
  ## ------------------------------------------------------------------

  # subdivide :: String -> Int -> [ String ]
  # subdivide "192.168.0.0/22" 24
  #   => [ "192.168.0.0/24" "192.168.1.0/24" "192.168.2.0/24" "192.168.3.0/24" ]
  subdivide = block: newPrefix:
    let
      b = bounds block;
      size = pow2 (32 - newPrefix);
      count = pow2 (newPrefix - b.prefixLength);
    in
    if !isInt newPrefix || newPrefix < 0 || newPrefix > 32 then
      throw "ipv4.subdivide: prefix length must be an integer in 0..32, got ${show newPrefix}"
    else if newPrefix < b.prefixLength then
      throw "ipv4.subdivide: /${toString newPrefix} is larger than the /${toString b.prefixLength} being split"
    else if count > listLimit then
      throw "ipv4.subdivide: ${toString count} blocks exceeds the ${toString listLimit} element guard; use subnetAt to pick individual blocks"
    else genList (i: "${toAddress (b.lo + i * size)}/${toString newPrefix}") count;

  # subnetAt :: String -> Int -> Int -> String
  # The nth subdivision without building the list.
  subnetAt = block: newPrefix: index:
    let
      b = bounds block;
      size = pow2 (32 - newPrefix);
      count = pow2 (newPrefix - b.prefixLength);
    in
    if !isInt newPrefix || newPrefix < 0 || newPrefix > 32 then
      throw "ipv4.subnetAt: prefix length must be an integer in 0..32, got ${show newPrefix}"
    else if newPrefix < b.prefixLength then
      throw "ipv4.subnetAt: /${toString newPrefix} is larger than the /${toString b.prefixLength} being split"
    else if !isInt index || index < 0 || index >= count then
      throw "ipv4.subnetAt: index ${show index} is outside 0..${toString (count - 1)}"
    else "${toAddress (b.lo + index * size)}/${toString newPrefix}";

  # addresses :: String -> [ String ]    every address in the block
  # Unlike hosts, this includes the network and broadcast addresses.
  addresses = block:
    let
      b = bounds block;
      count = pow2 (32 - b.prefixLength);
    in
    if count > listLimit then
      throw "ipv4.addresses: ${toString count} addresses exceeds the ${toString listLimit} element guard; use addressAt to pick individual addresses"
    else genList (i: toAddress (b.lo + i)) count;

  # addressAt :: String -> Int -> String
  # The nth address in a block, counting the network address as 0. Use hostAt
  # instead to count from the first usable host.
  addressAt = block: index:
    let
      b = bounds block;
      count = pow2 (32 - b.prefixLength);
    in
    if !isInt index || index < 0 || index >= count then
      throw "ipv4.addressAt: index ${show index} is outside 0..${toString (count - 1)} for ${toAddress b.lo}/${toString b.prefixLength}"
    else toAddress (b.lo + index);

  # hosts :: String -> [ String ]      every usable address in the block
  hosts = block:
    let s = subnet block;
    in
    if s.hostCount > listLimit then
      throw "ipv4.hosts: ${toString s.hostCount} addresses exceeds the ${toString listLimit} element guard; use hostAt to pick individual addresses"
    else genList (i: toAddress (s.firstHostInt + i)) s.hostCount;

  # hostAt :: String -> Int -> String
  hostAt = block: index:
    let s = subnet block;
    in
    if !isInt index || index < 0 || index >= s.hostCount then
      throw "ipv4.hostAt: index ${show index} is outside 0..${toString (s.hostCount - 1)} for ${s.cidr}"
    else toAddress (s.firstHostInt + index);

  ## ------------------------------------------------------------------
  ## tests
  ## ------------------------------------------------------------------

  tests = {
    roundTrip = {
      expr = toAddress (parseAddress "192.168.1.130");
      expected = "192.168.1.130";
    };
    parseLow = { expr = parseAddress "0.0.0.1"; expected = 1; };
    parseHigh = { expr = parseAddress "255.255.255.255"; expected = maxAddress; };
    rejectsLeadingZero = { expr = isValidAddress "192.168.01.1"; expected = false; };
    rejectsBigOctet = { expr = isValidAddress "192.168.1.256"; expected = false; };
    rejectsShort = { expr = isValidAddress "192.168.1"; expected = false; };

    netmask26 = { expr = toAddress (netmaskOf 26); expected = "255.255.255.192"; };
    netmask0 = { expr = toAddress (netmaskOf 0); expected = "0.0.0.0"; };
    netmask32 = { expr = toAddress (netmaskOf 32); expected = "255.255.255.255"; };
    prefixFromMask = { expr = prefixOfNetmask "255.255.255.192"; expected = 26; };

    report = {
      expr =
        let s = subnet "192.168.1.130/26"; in
        [ s.cidr s.netmask s.wildcard s.network s.broadcast s.firstHost s.lastHost s.hostCount s.addressCount s.aligned ];
      expected =
        [ "192.168.1.128/26" "255.255.255.192" "0.0.0.63" "192.168.1.128" "192.168.1.191" "192.168.1.129" "192.168.1.190" 62 64 false ];
    };
    pointToPoint = {
      expr = let s = subnet "10.0.0.0/31"; in [ s.firstHost s.lastHost s.hostCount ];
      expected = [ "10.0.0.0" "10.0.0.1" 2 ];
    };
    singleHost = {
      expr = let s = subnet "10.1.2.3"; in [ s.cidr s.firstHost s.hostCount s.aligned ];
      expected = [ "10.1.2.3/32" "10.1.2.3" 1 true ];
    };
    everything = {
      expr = let s = subnet "0.0.0.0/0"; in [ s.broadcast s.addressCount s.hostCount ];
      expected = [ "255.255.255.255" 4294967296 4294967294 ];
    };
    netmaskForm = {
      expr = (subnet "192.168.1.0/255.255.254.0").cidr;
      expected = "192.168.0.0/23";
    };

    containment = {
      expr = [
        (contains "10.0.0.0/8" "10.1.2.3")
        (contains "10.0.0.0/8" "11.0.0.1")
        (contains "10.0.0.0/8" "10.1.0.0/16")
        (contains "10.1.0.0/16" "10.0.0.0/8")
      ];
      expected = [ true false true false ];
    };
    overlapping = {
      expr = [
        (overlaps "10.0.0.0/24" "10.0.0.128/25")
        (overlaps "10.0.0.0/25" "10.0.0.128/25")
      ];
      expected = [ true false ];
    };
    smallestCover = {
      expr = supernet [ "192.168.7.0/24" "192.168.4.0/24" ];
      expected = "192.168.4.0/22";
    };

    split = {
      expr = subdivide "192.168.0.0/22" 24;
      expected = [ "192.168.0.0/24" "192.168.1.0/24" "192.168.2.0/24" "192.168.3.0/24" ];
    };
    nthSplit = { expr = subnetAt "10.0.0.0/8" 16 200; expected = "10.200.0.0/16"; };
    firstUsable = { expr = hostAt "192.168.1.0/24" 0; expected = "192.168.1.1"; };
    nthAddress = {
      expr = [ (addressAt "192.168.1.0/24" 0) (addressAt "192.168.1.0/24" 255) (addressAt "10.0.0.7/32" 0) ];
      expected = [ "192.168.1.0" "192.168.1.255" "10.0.0.7" ];
    };
    addressListIncludesEdges = {
      expr = addresses "192.168.1.8/30";
      expected = [ "192.168.1.8" "192.168.1.9" "192.168.1.10" "192.168.1.11" ];
    };
    hostList = { expr = hosts "192.168.1.8/29"; expected = [ "192.168.1.9" "192.168.1.10" "192.168.1.11" "192.168.1.12" "192.168.1.13" "192.168.1.14" ]; };

    scopes = {
      expr = map scopeOf [ "10.1.1.1" "172.16.0.1" "172.32.0.1" "127.0.0.1" "169.254.1.1" "8.8.8.8" "224.0.0.1" "100.64.0.1" "255.255.255.255" "192.168.0.0/16" ];
      expected = [ "private" "private" "public" "loopback" "link-local" "public" "multicast" "shared" "broadcast" "private" ];
    };
    classes = {
      expr = map classOf [ "10.0.0.1" "172.16.0.1" "192.168.0.1" "224.0.0.1" "250.0.0.1" ];
      expected = [ "A" "B" "C" "D" "E" ];
    };

    badPrefix = { expr = isValidBlock "192.168.1.0/33"; expected = false; };
    badNetmask = { expr = isValidBlock "10.0.0.0/255.0.255.0"; expected = false; };
    goodBlock = { expr = isValidBlock "10.0.0.0/8"; expected = true; };
  };

  # An empty list means every test passed.
  selfTest =
    let failed = filter (n: tests.${n}.expr != tests.${n}.expected) (attrNames tests);
    in map (n: { name = n; inherit (tests.${n}) expected; actual = tests.${n}.expr; }) failed;

in
{
  # addresses
  inherit parseAddress toAddress isValidAddress;

  # netmasks
  inherit netmaskOf prefixOfNetmask;

  # blocks
  inherit parseBlock bounds isValidBlock subnet;

  # classification
  inherit classOf scopeOf specialBlocks;

  # relations
  inherit contains overlaps supernet;

  # splitting and enumerating
  inherit subdivide subnetAt hosts hostAt addresses addressAt;

  # tests
  inherit tests selfTest;
}
