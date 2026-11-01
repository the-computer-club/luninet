# ipv6.nix — an IPv6 subnet calculator written in pure Nix.
#
# Standalone companion to ipv4.nix: no dependencies, no nixpkgs, no `lib`, no
# import-from-derivation. Neither file imports the other.
#
#     let ipv6 = import ./ipv6.nix; in ipv6.subnet "2001:db8:abcd:12::1/64"
#
#     => { cidr = "2001:db8:abcd:12::/64"; network = "2001:db8:abcd:12::";
#          lastAddress = "2001:db8:abcd:12:ffff:ffff:ffff:ffff";
#          addressCount = "18446744073709551616"; scope = "documentation"; ... }
#
# A 128-bit address does not fit in Nix's 64-bit integers, so an address is
# carried around as a list of eight 16-bit words, most significant first:
#
#     parseAddress "2001:db8::1"
#       => [ 8193 3512 0 0 0 0 0 1 ]
#
# All arithmetic below is word-wise, and address counts are produced as
# decimal strings by a small bignum, so nothing ever overflows.
#
# Anything called a "block" accepts either spelling:
#
#     "2001:db8::/32"    CIDR
#     "2001:db8::1"      bare address, treated as /128
#
# Addresses are parsed per RFC 4291 (`::` compression and a trailing dotted
# quad are both understood) and printed per RFC 5952 (lowercase, shortest
# groups, longest zero run compressed, leftmost on a tie). Scoped forms
# ("fe80::1%eth0") and bracketed forms ("[::1]") are rejected; strip the zone
# or the brackets before calling in.
#
# Run the test suite with:  nix eval -f ./ipv6.nix selfTest   ([ ] means pass)

let
  inherit (builtins)
    attrNames bitAnd bitOr concatStringsSep deepSeq elemAt filter foldl' genList
    head isInt isList isString length match stringLength substring tryEval
    typeOf;

  ## ------------------------------------------------------------------
  ## internals: lists, numbers, strings
  ## ------------------------------------------------------------------

  wordMax = 65535; # 2^16 - 1, one group
  groups = 8; # words per address
  addressBits = 128;

  # Ceiling on the list-producing helpers, so that a slip like
  # `subdivide "2001:db8::/32" 64` fails with a message rather than trying to
  # build four billion strings.
  listLimit = 65536;

  upTo = n: genList (i: i) n; # [ 0 1 ... n-1 ]

  pow2 = e: foldl' (acc: _: acc * 2) 1 (upTo e);

  slice = from: count: xs: genList (i: elemAt xs (from + i)) count;

  reverseList = xs: let n = length xs; in genList (i: elemAt xs (n - 1 - i)) n;

  show = v: if isString v then "\"" + v + "\"" else "<" + typeOf v + ">";

  charAt = i: s: substring i 1 s;

  # Indices at which `needle` occurs in `s`; "::" in ":::" reports two, which
  # is what makes the degenerate spellings fall out as errors for free.
  occurrencesOf = needle: s:
    let
      n = stringLength s;
      m = stringLength needle;
    in
    filter (i: substring i m s == needle) (upTo (if n >= m then n - m + 1 else 0));

  # splitOn ":" "a::b" => [ "a" "" "b" ]; empty fields are kept so that they
  # can be rejected later.
  splitOn = sep: s:
    let
      step = st: i:
        let c = charAt i s; in
        if c == sep
        then { parts = st.parts ++ [ st.cur ]; cur = ""; }
        else { inherit (st) parts; cur = st.cur + c; };
      r = foldl' step { parts = [ ]; cur = ""; } (upTo (stringLength s));
    in
    r.parts ++ [ r.cur ];

  decDigitOf = {
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

  hexDigitOf = {
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
    "a" = 10;
    "b" = 11;
    "c" = 12;
    "d" = 13;
    "e" = 14;
    "f" = 15;
    "A" = 10;
    "B" = 11;
    "C" = 12;
    "D" = 13;
    "E" = 14;
    "F" = 15;
  };

  hexChars = "0123456789abcdef";

  # Both are only ever fed regex-validated strings.
  toInt = s:
    foldl' (acc: i: acc * 10 + decDigitOf.${charAt i s}) 0 (upTo (stringLength s));

  fromHex = s:
    foldl' (acc: i: acc * 16 + hexDigitOf.${charAt i s}) 0 (upTo (stringLength s));

  toHex = n:
    let go = acc: v: if v == 0 then acc else go (charAt (bitAnd v 15) hexChars + acc) (v / 16);
    in if n == 0 then "0" else go "" n;

  toHex4 = n:
    concatStringsSep "" (map (sh: charAt (bitAnd (n / sh) 15) hexChars) [ 4096 256 16 1 ]);

  ## ------------------------------------------------------------------
  ## internals: 128-bit words
  ## ------------------------------------------------------------------

  checkWords = ws:
    if !isList ws || length ws != groups then
      throw "ipv6: expected a list of ${toString groups} 16-bit words, got ${show ws}"
    else if filter (w: !isInt w || w < 0 || w > wordMax) ws != [ ] then
      throw "ipv6: every word must be an integer in 0..${toString wordMax}"
    else ws;

  andWords = a: b: genList (i: bitAnd (elemAt a i) (elemAt b i)) groups;
  orWords = a: b: genList (i: bitOr (elemAt a i) (elemAt b i)) groups;
  notWords = a: genList (i: wordMax - elemAt a i) groups;

  # -1, 0 or 1, comparing most significant word first.
  compareWords = a: b:
    let diffs = filter (i: elemAt a i != elemAt b i) (upTo groups); in
    if diffs == [ ] then 0
    else if elemAt a (head diffs) < elemAt b (head diffs) then -1
    else 1;

  # words + value * 2^shift, wrapping at 2^128. `value` is an ordinary Nix
  # integer; splitting it into 16-bit chunks before scaling keeps every
  # intermediate well under the 64-bit ceiling.
  addShifted = ws: value: shift:
    let
      wordOffset = shift / 16;
      scale = pow2 (shift - 16 * wordOffset);
      chunk = i: if i < 0 || i > 3 then 0 else bitAnd (value / pow2 (16 * i)) wordMax;
      part = i: chunk i * scale; # < 2^31
      le = reverseList ws; # least significant word first
      step = st: j:
        let
          addend = bitAnd (part (j - wordOffset)) wordMax + (part (j - wordOffset - 1)) / 65536;
          t = elemAt le j + addend + st.carry;
        in
        { carry = t / 65536; out = st.out ++ [ (bitAnd t wordMax) ]; };
    in
    reverseList (foldl' step { carry = 0; out = [ ]; } (upTo groups)).out;

  # maskOf 64 => [ 65535 65535 65535 65535 0 0 0 0 ]
  maskOf = prefix:
    if !isInt prefix || prefix < 0 || prefix > addressBits then
      throw "ipv6: prefix length must be an integer in 0..${toString addressBits}, got ${show prefix}"
    else
      genList
        (i:
          let
            b = prefix - 16 * i;
            bits = if b < 0 then 0 else if b > 16 then 16 else b;
          in
          wordMax - pow2 (16 - bits) + 1)
        groups;

  ## ------------------------------------------------------------------
  ## internals: decimal bignum, for counts that outgrow a Nix integer
  ## ------------------------------------------------------------------

  # Digits are held little-endian, one per list element.
  decDouble = ds:
    let
      step = st: d:
        let t = 2 * d + st.carry; in
        {
          carry = if t > 9 then 1 else 0;
          out = st.out ++ [ (if t > 9 then t - 10 else t) ];
        };
      r = foldl' step { carry = 0; out = [ ]; } ds;
    in
    r.out ++ (if r.carry > 0 then [ r.carry ] else [ ]);

  # countOf 128 => "340282366920938463463374607431768211456"
  countOf = e:
    concatStringsSep "" (map toString (reverseList (foldl' (acc: _: decDouble acc) [ 1 ] (upTo e))));

  ## ------------------------------------------------------------------
  ## addresses
  ## ------------------------------------------------------------------

  hexGroupPat = "[0-9a-fA-F]{1,4}";
  # Same strict octet as ipv4.nix: in range, and no ambiguous leading zeros.
  octetPat = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])";
  dottedPat = "${octetPat}\\.${octetPat}\\.${octetPat}\\.${octetPat}";
  prefixPat = "(12[0-8]|1[01][0-9]|[1-9][0-9]|[0-9])";

  wordOfGroup = g:
    if match hexGroupPat g == null
    then throw "ipv6: ${show g} is not a group of 1 to 4 hex digits"
    else fromHex g;

  # A run of colon-separated fields. `allowDotted` marks the run that ends the
  # address, the only place a trailing IPv4 literal is permitted.
  wordsOfFields = allowDotted: fields:
    let
      n = length fields;
      dotted = if n == 0 || !allowDotted then null else match dottedPat (elemAt fields (n - 1));
      octet = i: toInt (elemAt dotted i);
    in
    if dotted == null
    then map wordOfGroup fields
    else
      map wordOfGroup (slice 0 (n - 1) fields)
      ++ [ (octet 0 * 256 + octet 1) (octet 2 * 256 + octet 3) ];

  # parseAddress :: String -> [ Int ]   (eight 16-bit words)
  parseAddress = s:
    if !isString s then
      throw "ipv6: expected an address as a string, got ${show s}"
    else
      let
        marks = occurrencesOf "::" s;
        atEnd = stringLength s;
      in
      if length marks > 1 then
        throw "ipv6: ${show s} uses :: more than once"
      else if marks == [ ] then
        let ws = wordsOfFields true (splitOn ":" s); in
        if length ws != groups
        then throw "ipv6: ${show s} has ${toString (length ws)} groups, expected ${toString groups}"
        else ws
      else
        let
          at = head marks;
          left = substring 0 at s;
          right = substring (at + 2) atEnd s;
          leftFields = if left == "" then [ ] else splitOn ":" left;
          rightFields = if right == "" then [ ] else splitOn ":" right;
          # The :: run always stands for at least one group, so anything left
          # of it can never be the low 32 bits: "1.2.3.4::" is not an address.
          lw = wordsOfFields false leftFields;
          rw = wordsOfFields true rightFields;
          zeros = groups - length lw - length rw;
        in
        if zeros < 1
        then throw "ipv6: ${show s} leaves no room for the :: run"
        else lw ++ genList (_: 0) zeros ++ rw;

  # The longest run of zero words in the first `n`, leftmost on a tie, per
  # RFC 5952. `>` rather than `>=` is what keeps the leftmost run winning.
  longestZeroRun = n: ws:
    let
      step = st: i:
        let
          len = if elemAt ws i == 0 then st.len + 1 else 0;
          start = if elemAt ws i == 0 && st.len == 0 then i else st.start;
        in
        {
          inherit len start;
          bestLen = if len > st.bestLen then len else st.bestLen;
          bestStart = if len > st.bestLen then start else st.bestStart;
        };
    in
    foldl' step { len = 0; start = 0; bestLen = 0; bestStart = 0; } (upTo n);

  # Compress the first `n` words of an address into text.
  compressRun = n: ws:
    let
      run = longestZeroRun n ws;
      hex = map toHex (slice 0 n ws);
      join = concatStringsSep ":";
    in
    if run.bestLen < 2 then join hex
    else
      join (slice 0 run.bestStart hex)
      + "::"
      + join (slice (run.bestStart + run.bestLen) (n - run.bestStart - run.bestLen) hex);

  # toAddress :: [ Int ] -> String    canonical RFC 5952 form
  toAddress = ws: compressRun groups (checkWords ws);

  # toFullAddress :: [ Int ] -> String    all eight groups, four digits each
  toFullAddress = ws: concatStringsSep ":" (map toHex4 (checkWords ws));

  # toDottedQuad :: [ Int ] -> String     the low 32 bits as an IPv4 literal
  toDottedQuad = ws:
    let
      v = checkWords ws;
      pair = i: [ (elemAt v i / 256) (bitAnd (elemAt v i) 255) ];
    in
    concatStringsSep "." (map toString (pair 6 ++ pair 7));

  # toMixedAddress :: [ Int ] -> String
  # The `::ffff:192.0.2.1` spelling of RFC 5952 section 5: the leading six
  # groups are compressed on their own and the last two are written as a
  # dotted quad. Identical to toAddress for everything else.
  toMixedAddress = ws:
    let
      v = checkWords ws;
      lead = compressRun 6 v;
      n = stringLength lead;
      # "::ffff" takes a colon before the quad, a bare "::" does not.
      sep = if n >= 2 && substring (n - 2) 2 lead == "::" then "" else ":";
    in
    if hasEmbeddedIPv4 v then lead + sep + toDottedQuad v else toAddress v;

  # ::ffff:0:0/96 (IPv4-mapped, RFC 4291) and 64:ff9b::/96 (NAT64, RFC 6052).
  # The deprecated IPv4-compatible ::/96 range is deliberately left out.
  hasEmbeddedIPv4 = v:
    let top = slice 0 6 v; in
    top == [ 0 0 0 0 0 65535 ] || top == [ 100 65435 0 0 0 0 ];

  isValidAddress = s: isString s && (tryEval (deepSeq (parseAddress s) true)).success;

  # embeddedIPv4 :: String -> String | null
  embeddedIPv4 = s:
    let v = parseAddress s; in
    if hasEmbeddedIPv4 v then toDottedQuad v else null;

  ## ------------------------------------------------------------------
  ## netmasks
  ## ------------------------------------------------------------------

  # prefixOfNetmask :: (String | [ Int ]) -> Int
  # Non-contiguous masks are rejected.
  prefixOfNetmask = mask:
    let
      value = if isString mask then parseAddress mask else checkWords mask;
      hits = filter (p: maskOf p == value) (upTo (addressBits + 1));
    in
    if hits == [ ] then
      throw "ipv6.prefixOfNetmask: ${show mask} is not a contiguous netmask"
    else head hits;

  ## ------------------------------------------------------------------
  ## blocks
  ## ------------------------------------------------------------------

  # parseBlock :: String -> { words :: [ Int ]; prefixLength :: Int; }
  # The address is kept as written; it is not snapped to the network.
  parseBlock = s:
    if !isString s then
      throw "ipv6: expected a block as a string, got ${show s}"
    else
      let cuts = occurrencesOf "/" s; in
      if length cuts > 1 then
        throw "ipv6: ${show s} contains more than one /"
      else if cuts == [ ] then
        { words = parseAddress s; prefixLength = addressBits; }
      else
        let
          at = head cuts;
          tail' = substring (at + 1) (stringLength s) s;
        in
        if match prefixPat tail' == null
        then throw "ipv6: ${show tail'} is not a prefix length in 0..${toString addressBits}"
        else { words = parseAddress (substring 0 at s); prefixLength = toInt tail'; };

  # bounds :: String -> { lo, hi, words :: [ Int ]; prefixLength :: Int; }
  # The cheap primitive the comparison helpers are built from.
  bounds = s:
    let
      b = parseBlock s;
      mask = maskOf b.prefixLength;
      lo = andWords b.words mask;
    in
    { inherit lo; hi = orWords lo (notWords mask); inherit (b) words prefixLength; };

  isValidBlock = s: isString s && (tryEval (deepSeq (parseBlock s) true)).success;

  # canonical :: String -> String     re-spell an address or block per RFC 5952
  canonical = s:
    if !isString s then throw "ipv6.canonical: expected a string, got ${show s}"
    else
      let b = parseBlock s; in
      if occurrencesOf "/" s == [ ]
      then toAddress b.words
      else "${toAddress b.words}/${toString b.prefixLength}";

  # expand :: String -> String        the same, fully written out
  expand = s:
    if !isString s then throw "ipv6.expand: expected a string, got ${show s}"
    else
      let b = parseBlock s; in
      if occurrencesOf "/" s == [ ]
      then toFullAddress b.words
      else "${toFullAddress b.words}/${toString b.prefixLength}";

  ## ------------------------------------------------------------------
  ## classification
  ## ------------------------------------------------------------------

  # Most specific first: several of these nest inside one another.
  specialBlocks = [
    { cidr = "::/128"; scope = "unspecified"; } # RFC 4291
    { cidr = "::1/128"; scope = "loopback"; } # RFC 4291
    { cidr = "::ffff:0:0/96"; scope = "ipv4-mapped"; } # RFC 4291
    { cidr = "64:ff9b::/96"; scope = "ipv4-translation"; } # RFC 6052
    { cidr = "64:ff9b:1::/48"; scope = "ipv4-translation"; } # RFC 8215
    { cidr = "100::/64"; scope = "discard"; } # RFC 6666
    { cidr = "2001::/32"; scope = "teredo"; } # RFC 4380
    { cidr = "2001:20::/28"; scope = "orchidv2"; } # RFC 7343
    { cidr = "2001::/23"; scope = "ietf-protocol"; } # RFC 2928
    { cidr = "2001:db8::/32"; scope = "documentation"; } # RFC 3849
    { cidr = "2002::/16"; scope = "6to4"; } # RFC 3056
    { cidr = "3fff::/20"; scope = "documentation"; } # RFC 9637
    { cidr = "2000::/3"; scope = "global-unicast"; } # RFC 3587
    { cidr = "fc00::/7"; scope = "unique-local"; } # RFC 4193
    { cidr = "fe80::/10"; scope = "link-local"; } # RFC 4291
    { cidr = "ff00::/8"; scope = "multicast"; } # RFC 4291
  ];

  # scopeOf :: String -> String
  # The block has to sit entirely inside a reserved range to be labelled by
  # it; anything left over is still unassigned.
  scopeOf = s:
    let
      b = bounds s;
      hits = filter
        (r:
          let rb = bounds r.cidr; in
          compareWords b.lo rb.lo >= 0 && compareWords b.hi rb.hi <= 0)
        specialBlocks;
    in
    if hits == [ ] then "reserved" else (head hits).scope;

  ## ------------------------------------------------------------------
  ## the calculator
  ## ------------------------------------------------------------------

  # subnet :: String -> AttrSet
  # The whole report for one block. IPv6 has no broadcast address and no
  # network address reserved out of the host range, so every address in the
  # block is usable and only the count is reported.
  subnet = s:
    let
      b = bounds s;
      prefix = b.prefixLength;
      mask = maskOf prefix;
    in
    {
      cidr = "${toAddress b.lo}/${toString prefix}"; # canonical, network-aligned
      address = toAddress b.words; # as supplied, re-spelled
      full = toFullAddress b.words;
      words = b.words;
      prefixLength = prefix;
      netmask = toAddress mask;
      netmaskWords = mask;
      hostmask = toAddress (notWords mask);
      network = toAddress b.lo;
      networkWords = b.lo;
      firstAddress = toAddress b.lo; # alias for network
      lastAddress = toAddress b.hi;
      lastAddressWords = b.hi;
      addressCount = countOf (addressBits - prefix); # decimal string: 2^(128-n)
      addressCountExponent = addressBits - prefix;
      scope = scopeOf s;
      embeddedIPv4 = if hasEmbeddedIPv4 b.words then toDottedQuad b.words else null;
      aligned = b.words == b.lo; # was the input already the network address?
    };

  ## ------------------------------------------------------------------
  ## relations
  ## ------------------------------------------------------------------

  # compareAddresses :: String -> String -> Int    -1, 0 or 1
  # Sort with:  builtins.sort (a: b: ipv6.compareAddresses a b < 0) list
  compareAddresses = x: y: compareWords (parseAddress x) (parseAddress y);

  # contains :: String -> String -> Bool
  # Curries nicely:  filter (ipv6.contains "fe80::/10") addresses
  contains = block: other:
    let a = bounds block; b = bounds other; in
    compareWords b.lo a.lo >= 0 && compareWords b.hi a.hi <= 0;

  # overlaps :: String -> String -> Bool
  overlaps = x: y:
    let a = bounds x; b = bounds y; in
    compareWords a.lo b.hi <= 0 && compareWords b.lo a.hi <= 0;

  # supernet :: [ String ] -> String
  # The smallest single block covering every input block.
  supernet = blocks:
    if !isList blocks || blocks == [ ] then
      throw "ipv6.supernet: expected a non-empty list of blocks"
    else
      let
        bs = map bounds blocks;
        lo = foldl' (acc: b: if compareWords b.lo acc < 0 then b.lo else acc) (head bs).lo bs;
        hi = foldl' (acc: b: if compareWords b.hi acc > 0 then b.hi else acc) (head bs).hi bs;
        fits = filter
          (p: andWords lo (maskOf p) == andWords hi (maskOf p))
          (upTo (addressBits + 1));
        prefix = elemAt fits (length fits - 1); # /0 always fits, so never empty
      in
      "${toAddress (andWords lo (maskOf prefix))}/${toString prefix}";

  ## ------------------------------------------------------------------
  ## splitting and enumerating
  ## ------------------------------------------------------------------

  # subdivide :: String -> Int -> [ String ]
  # subdivide "2001:db8::/32" 34
  #   => [ "2001:db8::/34" "2001:db8:4000::/34"
  #        "2001:db8:8000::/34" "2001:db8:c000::/34" ]
  subdivide = block: newPrefix:
    let
      b = bounds block;
      exponent = newPrefix - b.prefixLength;
    in
    if !isInt newPrefix || newPrefix < 0 || newPrefix > addressBits then
      throw "ipv6.subdivide: prefix length must be an integer in 0..${toString addressBits}, got ${show newPrefix}"
    else if exponent < 0 then
      throw "ipv6.subdivide: /${toString newPrefix} is larger than the /${toString b.prefixLength} being split"
    else if pow2 (if exponent > 17 then 17 else exponent) > listLimit then
    throw "ipv6.subdivide: 2^${toString exponent} blocks exceeds the ${toString listLimit} element guard; use subnetAt to pick individual blocks"
    else
    genList
      (i: "${toAddress (addShifted b.lo i (addressBits - newPrefix))}/${toString newPrefix}")
      (pow2 exponent);

  # subnetAt :: String -> Int -> Int -> String
  # The nth subdivision without building the list, so indexes far beyond any
  # list you would want to hold are fine.
  subnetAt = block: newPrefix: index:
    let
      b = bounds block;
      exponent = newPrefix - b.prefixLength;
      # 2^exponent outgrows a Nix integer past 62 bits, and no index that a
      # Nix integer can hold reaches that far anyway.
      inRange = exponent > 62 || index < pow2 (if exponent > 62 then 0 else exponent);
    in
    if !isInt newPrefix || newPrefix < 0 || newPrefix > addressBits then
      throw "ipv6.subnetAt: prefix length must be an integer in 0..${toString addressBits}, got ${show newPrefix}"
    else if exponent < 0 then
      throw "ipv6.subnetAt: /${toString newPrefix} is larger than the /${toString b.prefixLength} being split"
    else if !isInt index || index < 0 || !inRange then
      throw "ipv6.subnetAt: index ${show index} is outside 0..2^${toString exponent} - 1"
    else "${toAddress (addShifted b.lo index (addressBits - newPrefix))}/${toString newPrefix}";

  # addresses :: String -> [ String ]    every address in a small block
  addresses = block:
    let
      b = bounds block;
      exponent = addressBits - b.prefixLength;
    in
    if pow2 (if exponent > 17 then 17 else exponent) > listLimit then
    throw "ipv6.addresses: 2^${toString exponent} addresses exceeds the ${toString listLimit} element guard; use addressAt to pick individual addresses"
    else genList (i: toAddress (addShifted b.lo i 0)) (pow2 exponent);

  # addressAt :: String -> Int -> String
  addressAt = block: index:
    let
      b = bounds block;
      exponent = addressBits - b.prefixLength;
      inRange = exponent > 62 || index < pow2 (if exponent > 62 then 0 else exponent);
    in
    if !isInt index || index < 0 || !inRange then
      throw "ipv6.addressAt: index ${show index} is outside 0..2^${toString exponent} - 1"
    else toAddress (addShifted b.lo index 0);

  ## ------------------------------------------------------------------
  ## tests
  ## ------------------------------------------------------------------

  tests = {
    parseWords = {
      expr = parseAddress "2001:db8::1";
      expected = [ 8193 3512 0 0 0 0 0 1 ];
    };
    parseFull = {
      expr = parseAddress "1:2:3:4:5:6:7:8";
      expected = [ 1 2 3 4 5 6 7 8 ];
    };
    parseUpperAndPadded = {
      expr = parseAddress "2001:0DB8:0000:0000:0000:0000:0000:0001";
      expected = parseAddress "2001:db8::1";
    };
    parseDotted = {
      expr = toFullAddress (parseAddress "::ffff:192.0.2.1");
      expected = "0000:0000:0000:0000:0000:ffff:c000:0201";
    };
    parseLeadingRun = { expr = parseAddress "::"; expected = [ 0 0 0 0 0 0 0 0 ]; };

    compressLoopback = { expr = canonical "0:0:0:0:0:0:0:1"; expected = "::1"; };
    compressTrailing = { expr = canonical "1:0:2:0:0:0:0:0"; expected = "1:0:2::"; };
    compressLeftmostOnTie = {
      expr = canonical "0:0:1:0:0:1:0:0";
      expected = "::1:0:0:1:0:0";
    };
    compressSkipsSingle = {
      expr = canonical "1:0:2:3:4:5:6:7";
      expected = "1:0:2:3:4:5:6:7";
    };
    compressMapped = { expr = canonical "::ffff:192.0.2.1"; expected = "::ffff:c000:201"; };
    mixedForm = {
      expr = toMixedAddress (parseAddress "::ffff:c000:201");
      expected = "::ffff:192.0.2.1";
    };
    expandBlock = {
      expr = expand "2001:db8::1/64";
      expected = "2001:0db8:0000:0000:0000:0000:0000:0001/64";
    };
    canonicalBlock = { expr = canonical "2001:0DB8:0::/32"; expected = "2001:db8::/32"; };

    netmask64 = { expr = toAddress (maskOf 64); expected = "ffff:ffff:ffff:ffff::"; };
    netmask0 = { expr = toAddress (maskOf 0); expected = "::"; };
    netmask128 = {
      expr = toAddress (maskOf 128);
      expected = "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff";
    };
    netmask49 = { expr = toAddress (maskOf 49); expected = "ffff:ffff:ffff:8000::"; };
    prefixFromNetmask = { expr = prefixOfNetmask "ffff:ffff:ffff:ffff::"; expected = 64; };

    report = {
      expr =
        let s = subnet "2001:db8:abcd:12::1/64"; in
        [ s.cidr s.network s.lastAddress s.addressCount s.scope s.aligned s.hostmask ];
      expected = [
        "2001:db8:abcd:12::/64"
        "2001:db8:abcd:12::"
        "2001:db8:abcd:12:ffff:ffff:ffff:ffff"
        "18446744073709551616"
        "documentation"
        false
        "::ffff:ffff:ffff:ffff"
      ];
    };
    wholeSpace = {
      expr = let s = subnet "::/0"; in [ s.lastAddress s.addressCount ];
      expected = [
        "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
        "340282366920938463463374607431768211456"
      ];
    };
    singleAddress = {
      expr = let s = subnet "2001:db8::1"; in [ s.cidr s.lastAddress s.addressCount s.aligned ];
      expected = [ "2001:db8::1/128" "2001:db8::1" "1" true ];
    };
    pointToPoint = {
      expr = let s = subnet "2001:db8::/127"; in [ s.lastAddress s.addressCount ];
      expected = [ "2001:db8::1" "2" ];
    };
    oddPrefix = {
      expr = (subnet "2001:db8:1234:5678::/49").cidr;
      expected = "2001:db8:1234::/49";
    };
    mappedReport = {
      expr = (subnet "::ffff:192.0.2.1").embeddedIPv4;
      expected = "192.0.2.1";
    };

    containment = {
      expr = [
        (contains "2001:db8::/32" "2001:db8:dead:beef::1")
        (contains "2001:db8::/32" "2001:db9::1")
        (contains "2001:db8::/32" "2001:db8:8000::/33")
        (contains "2001:db8:8000::/33" "2001:db8::/32")
        (contains "fe80::/10" "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
        (contains "fe80::/10" "fec0::1")
      ];
      expected = [ true false true false true false ];
    };
    overlapping = {
      expr = [
        (overlaps "2001:db8::/32" "2001:db8:8000::/33")
        (overlaps "2001:db8::/33" "2001:db8:8000::/33")
      ];
      expected = [ true false ];
    };
    ordering = {
      expr = [
        (compareAddresses "::1" "::2")
        (compareAddresses "::2" "::1")
        (compareAddresses "2001:db8::1" "2001:0db8::1")
        (compareAddresses "ff00::" "2001:db8::")
      ];
      expected = [ (-1) 1 0 1 ];
    };
    smallestCover = {
      expr = supernet [ "2001:db8:3::/48" "2001:db8::/48" ];
      expected = "2001:db8::/46";
    };

    split = {
      expr = subdivide "2001:db8::/32" 34;
      expected = [
        "2001:db8::/34"
        "2001:db8:4000::/34"
        "2001:db8:8000::/34"
        "2001:db8:c000::/34"
      ];
    };
    splitOddBoundary = {
      expr = subdivide "2001:db8::/126" 128;
      expected = [ "2001:db8::/128" "2001:db8::1/128" "2001:db8::2/128" "2001:db8::3/128" ];
    };
    nthSplit = {
      expr = subnetAt "2001:db8::/32" 64 305419896;
      expected = "2001:db8:1234:5678::/64";
    };
    hugeIndex = {
      expr = subnetAt "::/0" 128 1152921504606846976; # 2^60
      expected = "::1000:0:0:0/128";
    };
    nthAddress = {
      expr = addressAt "2001:db8::/64" 4294967296; # 2^32
      expected = "2001:db8::1:0:0";
    };
    addressList = {
      expr = addresses "2001:db8::4/126";
      expected = [ "2001:db8::4" "2001:db8::5" "2001:db8::6" "2001:db8::7" ];
    };
    carryAcrossWords = {
      expr = [
        (addressAt "2001:db8::/32" 281474976710655) # 2^48 - 1
        (addressAt "2001:db8::/32" 281474976710656) # 2^48, carries three words
      ];
      expected = [ "2001:db8::ffff:ffff:ffff" "2001:db8:0:0:1::" ];
    };
    shiftPastSixtyFour = {
      expr = subnetAt "::/0" 64 9223372036854775807; # (2^63 - 1) << 64
      expected = "7fff:ffff:ffff:ffff::/64";
    };

    scopes = {
      expr = map scopeOf [
        "::"
        "::1"
        "2001:db8::1"
        "2001:db8::/32"
        "fe80::1"
        "fd00::1"
        "ff02::1"
        "2606:4700::1111"
        "2001::1"
        "::ffff:10.0.0.1"
        "64:ff9b::1.2.3.4"
        "3fff::1"
        "4000::1"
      ];
      expected = [
        "unspecified"
        "loopback"
        "documentation"
        "documentation"
        "link-local"
        "unique-local"
        "multicast"
        "global-unicast"
        "teredo"
        "ipv4-mapped"
        "ipv4-translation"
        "documentation"
        "reserved"
      ];
    };

    rejectsDoubleRun = { expr = isValidAddress "1::2::3"; expected = false; };
    rejectsTripleColon = { expr = isValidAddress ":::"; expected = false; };
    rejectsTooManyGroups = { expr = isValidAddress "1:2:3:4:5:6:7:8:9"; expected = false; };
    rejectsLongGroup = { expr = isValidAddress "::12345"; expected = false; };
    rejectsLeadingDotted = { expr = isValidAddress "1.2.3.4::"; expected = false; };
    rejectsTrailingColon = { expr = isValidAddress "1::2:"; expected = false; };
    rejectsZoneId = { expr = isValidAddress "fe80::1%eth0"; expected = false; };
    rejectsBrackets = { expr = isValidAddress "[::1]"; expected = false; };
    rejectsEmptyRun = { expr = isValidAddress "1:2:3:4:5:6:7:8::9"; expected = false; };
    rejectsBadPrefix = { expr = isValidBlock "2001:db8::/129"; expected = false; };
    acceptsPaddedGroup = { expr = isValidAddress "0001::0001"; expected = true; };
    acceptsBlock = { expr = isValidBlock "2001:db8::/32"; expected = true; };
  };

  # An empty list means every test passed.
  selfTest =
    let failed = filter (n: tests.${n}.expr != tests.${n}.expected) (attrNames tests); in
    map (n: { name = n; inherit (tests.${n}) expected; actual = tests.${n}.expr; }) failed;

in
{
  # addresses
  inherit parseAddress toAddress toFullAddress toMixedAddress toDottedQuad;
  inherit canonical expand isValidAddress embeddedIPv4;

  # netmasks
  inherit maskOf prefixOfNetmask;

  # blocks
  inherit parseBlock bounds isValidBlock subnet;

  # classification
  inherit scopeOf specialBlocks;

  # relations
  inherit compareAddresses contains overlaps supernet;

  # splitting and enumerating
  inherit subdivide subnetAt addresses addressAt;

  # word-level helpers, for building on top
  inherit andWords orWords notWords compareWords addShifted;

  # tests
  inherit tests selfTest;
}
