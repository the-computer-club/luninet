{ lib, ipv4, ipv6, config }:
let

  inherit (lib)
    attrNames concatMap concatStringsSep elem filter filterAttrs foldl' genAttrs
    genList hasInfix hasAttr head isString length mapAttrs mapAttrsToList sort
    unique;

  zones = config.zones;
  zoneNames = attrNames zones;

  v4Prefixes = z: if zones.${z}.ipv4 == null then [ ] else zones.${z}.ipv4.addresses;
  v6Prefixes = z: if zones.${z}.ipv6 == null then [ ] else zones.${z}.ipv6.addresses;

  v4Base = z: head (v4Prefixes z);
  v6Base = z: head (v6Prefixes z);

  inZone = z: a: lib.any (c: ipv4.contains c a) (v4Prefixes z);

  # ---- normalise machine interfaces ---------------------------------------
  # `eno1 = "10.0.0.5/24"` and `eno1 = { address = "10.0.0.5/24"; }` are the same
  # declaration; the string form is just the short spelling.
  mkIt = h: i: v:
    let c = if isString v then { address = v; } else v; in
    {
      host = h;
      interface = i;
      zone = c.zone or null;
      address = c.address or null;
      hostId = c.hostId or null;
      ipv6Address = c.ipv6Address or null;
      prefixLength = c.prefixLength or null;
      mac = c.mac or null;
      role = c.role or "host";
    };

  ifaces = concatMap
    (h: mapAttrsToList (i: v: mkIt h i v) config.machines.${h}.interfaces)
    (attrNames config.machines);

  # An address implies its zone when exactly one zone contains it.
  zoneOf = it:
    if it.zone != null then it.zone
    else if it.address != null then
      let
        matches = filter (z: inZone z it.address) zoneNames;
      in
      if length matches == 1 then head matches
      else if matches == [ ] then
        throw "fabric: ${it.host}.${it.interface} is ${it.address}, which is in no declared zone"
      else
        throw "fabric: ${it.host}.${it.interface} is ${it.address}, which is in ${concatStringsSep ", " matches} — name the zone"
    else throw "fabric: ${it.host}.${it.interface} needs a zone (or an address to infer one from)";

  addrIntOf = a: (ipv4.parseBlock a).address;
  prefixIn = a: if hasInfix "/" a then (ipv4.parseBlock a).prefixLength else null;

  offsetOf = it:
    if it.address != null then addrIntOf it.address - (ipv4.subnet (v4Base (zoneOf it))).networkInt
    else it.hostId;

  # ---- allocation ----------------------------------------------------------
  baseUsed = z:
    let
      si = ipv4.subnet (v4Base z);
      s = zones.${z}.ipv4;
      expand = r:
        let b = ipv4.subnet r; in
        genList (k: b.networkInt - si.networkInt + k) b.addressCount;
      pool = s.dhcp.pool;
      poolIds = if pool == null then [ ] else genList (k: pool.start + k) (pool.end - pool.start + 1);
      pinnedHere = filter (it: it.zone == z || (it.zone == null && it.address != null && inZone z it.address)) ifaces;
    in
    [ 0 (si.addressCount - 1) ]
    ++ concatMap expand s.reserved
    ++ poolIds
    ++ filter (x: x != null) (map offsetOf pinnedHere);

  unpinned = sort
    (a: b: "${a.host}/${a.interface}" < "${b.host}/${b.interface}")
    (filter (it: it.hostId == null && it.address == null) ifaces);

  # Host ids still free on a zone, from `autoStart` up to the last usable host.
  #
  # Two arithmetic traps live here, both of which used to abort evaluation with
  # a message naming neither the zone nor the interface:
  #
  #   * `autoStart` defaults to 100, but a /28 has 16 addresses. The old
  #     expression then asked `genList` for a list of length -86, which is an
  #     unrecoverable eval error -- not a `throw`, so `tryEval` cannot catch it.
  #     Clamping to zero keeps it a list; the zone simply has nothing to give.
  #   * the last usable host is `addressCount - 2`, so the count is
  #     `addressCount - 1 - autoStart`. The old `- 2` left the final address of
  #     every zone permanently unallocated.
  freeHostIds = z:
    let
      si = ipv4.subnet (v4Base z);
      count = si.addressCount - 1 - config.autoStart;
    in
    if count <= 0 then [ ] else genList (i: config.autoStart + i) count;

  alloc = foldl'
    (acc: it:
      let
        z = zoneOf it;
        si = ipv4.subnet (v4Base z);
        used = acc.used.${z};
        free = filter (i: !(elem i used)) (freeHostIds z);
        id =
          if free != [ ] then head free
          else
            throw ''
              fabric: no free address for ${it.host}.${it.interface} on zone `${z}`.
              The zone is ${v4Base z} (${toString si.addressCount} addresses) and allocation
              starts at autoStart = ${toString config.autoStart}, so every host id from there
              to ${toString (si.addressCount - 2)} is either taken, reserved, or in the DHCP
              pool. Pin an address, widen the zone, or lower `autoStart`.'';
      in
      {
        used = acc.used // { ${z} = used ++ [ id ]; };
        assigned = acc.assigned // { "${it.host}/${it.interface}" = id; };
      })
    { used = genAttrs (filter (z: zones.${z}.ipv4 != null) zoneNames) baseUsed; assigned = { }; }
    unpinned;

  hostIdOf = it:
    if it.hostId != null then it.hostId
    else if it.address != null then offsetOf it
    else alloc.assigned."${it.host}/${it.interface}";

  # ---- resolution of gateway / DNS references ------------------------------
  resolve = zone: ref:
    if ref == null then null
    else if hasAttr ref config.machines then
      let
        candidates = filter (it: it.host == ref && (it.zone == zone || (it.zone == null && it.address != null && inZone zone it.address))) ifaces;
      in
      if candidates == [ ] then throw "fabric: `${ref}` is not on zone `${zone}`" else addressOf (head candidates)
    else ref;

  resolvable = zone: ref:
    ref == null
    || !(hasAttr ref config.machines)
    || length (filter (it: it.host == ref && (it.zone == zone || (it.zone == null && it.address != null && inZone zone it.address))) ifaces) > 0;

  addressOf = it:
    let z = zoneOf it; in
    if it.address != null then ipv4.toAddress (addrIntOf it.address)
    else if zones.${z}.ipv4 == null then null
    else ipv4.addressAt (v4Base z) (hostIdOf it);

  # ---- derived addresses ---------------------------------------------------
  addresses = mapAttrs
    (h: _: mapAttrs
      (i: v:
        let
          it = mkIt h i v;
          z = zoneOf it;
          zi = zones.${z};
          si = if zi.ipv4 == null then null else ipv4.subnet (v4Base z);
          a = addressOf it;
          v6 = if zi.ipv6 == null then null else v6Base z;
          gw = if zi.ipv4 == null then null else resolve z zi.ipv4.defaultGateway;
          dnsList =
            if zi.ipv4 != null then map (resolve z) zi.ipv4.dns
            else if zi.ipv6 != null then map (resolve z) zi.ipv6.dns
            else [ ];
        in
        {
          zone = z;
          inherit (it) interface mac role;
          vlan = zi.vlan;
          vrf = zi.vrf;
          address = a;
          prefixLength =
            if it.prefixLength != null then it.prefixLength
            else if it.address != null && prefixIn it.address != null then prefixIn it.address
            else if si != null then si.prefixLength else null;
          netmask = if si == null then null else si.netmask;
          cidr = if si == null then null else (ipv4.subnet (v4Base z)).cidr;
          hostId = hostIdOf it;
          gateway = if gw == a then null else gw;
          dns = dnsList;
          ipv6 =
            if v6 == null then null
            else {
              address =
                if it.ipv6Address != null then ipv6.toAddress (ipv6.parseAddress it.ipv6Address)
                else ipv6.addressAt v6 (hostIdOf it);
              prefixLength = (ipv6.subnet v6).prefixLength;
              subnet = (ipv6.subnet v6).cidr;
            };
        })
      config.machines.${h}.interfaces)
    config.machines;

  all = concatMap (h: mapAttrsToList (i: a: { inherit h i a; }) addresses.${h}) (attrNames addresses);

  # ---- checks --------------------------------------------------------------
  v4Zones = filter (z: zones.${z}.ipv4 != null) zoneNames;

  outsideSpaces = filter
    (z: !(zones.${z}.external) && config.spaces != [ ]
      && !(lib.any (sp: lib.any (c: ipv4.contains sp c) (v4Prefixes z)) config.spaces))
    v4Zones;

  zonePairs = lib.concatMap
    (a: map (b: { left = a; right = b; }) v4Zones)
    v4Zones;

  overlappingZones = filter
    (p: p.left < p.right
      && zones.${p.left}.vrf == zones.${p.right}.vrf
      && lib.any (c1: lib.any (c2: ipv4.overlaps c1 c2) (v4Prefixes p.right)) (v4Prefixes p.left))
    zonePairs;

  badAddresses = filter
    (e:
      (
        let
          si = ipv4.subnet (v4Base e.a.zone);
          allowNet = zones.${e.a.zone}.ipv4.allowNetworkAddress or false;
          onNetwork = addrIntOf e.a.address == si.networkInt;
        in
        e.a.address == null
        ||
        !(ipv4.contains si.cidr e.a.address)
        || (onNetwork && !allowNet)
        || (addrIntOf e.a.address) == si.broadcastInt
        || (e.a.hostId < 1 && !(allowNet && onNetwork))
        || e.a.hostId > si.addressCount - 2
      ))
    (filter (e: zones.${e.a.zone}.ipv4 != null) all);

  # A zone that had to opt into network-address addressing. Not an error --
  # the assertions stay silent about it -- but published so a migration can be
  # tracked to completion and so it is obvious which segments still need the
  # one-line fix (move the device to host 1).
  networkAddressZones =
    map (e: "${e.h}.${e.i} (${e.a.address}, zone ${e.a.zone})")
      (filter
        (e:
          zones.${e.a.zone}.ipv4 != null
          && (zones.${e.a.zone}.ipv4.allowNetworkAddress or false)
          && e.a.address != null
          && (addrIntOf e.a.address) == (ipv4.subnet (v4Base e.a.zone)).networkInt)
        all);

  dupAddresses =
    let
      grouped = foldl'
        (acc: e: acc // {
          "${toString e.a.vrf}/${toString e.a.address}" =
            (acc."${toString e.a.vrf}/${toString e.a.address}" or [ ]) ++ [ "${e.h}.${e.i}" ];
        })
        { }
        (filter (e: e.a.address != null) all);
    in
    filterAttrs (_: v: length v > 1) grouped;

  badGateways = filter (z: !(resolvable z (zones.${z}.ipv4.defaultGateway or null))) v4Zones;
  badDns = concatMap
    (z:
      let zi = zones.${z}.ipv4; in
      map (d: { inherit z d; field = "dns"; }) (filter (d: !(resolvable z d)) (zi.dns or [ ]))
      # `dhcp.dns` is resolved by `mikrotikSections` exactly the way `dns` is, so
      # it needs the same check. Without this a zone whose lease resolvers name a
      # machine on another zone leaves `assertions` empty -- `checks.fabric` goes
      # green -- and the failure surfaces only when a router render is forced.
      ++ map (d: { inherit z d; field = "dhcp.dns"; }) (filter (d: !(resolvable z d)) (zi.dhcp.dns or [ ])))
    v4Zones;

  gatewayInPool = filter
    (z:
      let p = zones.${z}.ipv4.dhcp.pool; g = zones.${z}.ipv4.defaultGateway; in
      p != null && g != null && !(hasAttr g config.machines)
      && (
        let a = (ipv4.parseBlock g).address - (ipv4.subnet (v4Base z)).networkInt;
        in a >= p.start && a <= p.end
      ))
    v4Zones;

  # ---- reservations --------------------------------------------------------
  reservations = mapAttrs
    (n: r:
      let b = ipv4.subnet r.space; in
      r // { inherit n; inherit (b) cidr network broadcast; })
    config.reservations;

  reservationList = mapAttrsToList (_: r: r) reservations;

  reservationsOutside = filter
    (r: config.spaces != [ ] && !(lib.any (sp: ipv4.contains sp r.cidr) config.spaces))
    reservationList;

  reservationsOverZones = concatMap
    (r: map (z: { inherit (r) n cidr; zone = z; }) (filter (z: lib.any (c: ipv4.overlaps r.cidr c) (v4Prefixes z)) v4Zones))
    reservationList;

  reservationsOverEachOther =
    let
      pairs = lib.concatMap
        (a: map (b: { left = a; right = b; })
          (filter (b: b.n != a.n && ipv4.overlaps a.cidr b.cidr) reservationList))
        reservationList;
    in
    filter (p: p.left.n < p.right.n) pairs;

  assertions = map (m: { assertion = false; message = m; }) (
    (map (e: "fabric: ${e.h}.${e.i} = ${toString e.a.address} is not a usable address on zone `${e.a.zone}`") badAddresses)
    ++ (map (k: "fabric: ${k} is claimed by ${concatStringsSep ", " dupAddresses.${k}}") (attrNames dupAddresses))
    ++ (map (z: "fabric: zone `${z}` is outside every declared space") outsideSpaces)
    ++ (map (p: "fabric: zones `${p.left}` and `${p.right}` overlap in the same VRF") overlappingZones)
    ++ (map (z: "fabric: zone `${z}` has a gateway that is not an address on it") badGateways)
    ++ (map (e: "fabric: zone `${e.z}` has `${e.field}` = `${e.d}`, which is not an address on it") badDns)
    ++ (map (z: "fabric: zone `${z}` puts its gateway inside its DHCP pool") gatewayInPool)
    ++ (map (r: "fabric: reservation `${r.n}` (${r.cidr}) is outside every declared space") reservationsOutside)
    ++ (map (r: "fabric: reservation `${r.n}` (${r.cidr}) overlaps zone `${r.zone}`") reservationsOverZones)
    ++ (map (p: "fabric: reservations `${p.left.n}` and `${p.right.n}` overlap") reservationsOverEachOther)
  );

  # ---- renderers -----------------------------------------------------------
  nixosModuleFor = host:
    { ... }:
    let
      mine = filterAttrs (_: a: a.address != null || a.ipv6 != null) (addresses.${host} or { });
      routed = filterAttrs (_: a: a.gateway != null) mine;
      # Preference, explicitly: the management zone, then any internal zone,
      # then anything routed at all. Never "whichever name sorts first" — that
      # is how a WAN interface ends up as someone's default route.
      mgmt = filterAttrs (_: a: a.zone == "mgmt") routed;
      internal = filterAttrs (_: a: !(zones.${a.zone}.external or false)) routed;
      pick =
        if mgmt != { } then head (attrNames mgmt)
        else if internal != { } then head (attrNames internal)
        else if routed != { } then head (attrNames routed)
        else null;
    in
    {
      networking = {
        interfaces = mapAttrs
          (_: a:
            lib.optionalAttrs (a.address != null)
              {
                ipv4.addresses = [{ inherit (a) address prefixLength; }];
              }
            // lib.optionalAttrs (a.ipv6 != null) {
              ipv6.addresses = [{ inherit (a.ipv6) address prefixLength; }];
            })
          mine;
        nameservers = unique (concatMap (a: a.dns) (lib.attrValues mine));
      }
      // lib.optionalAttrs (pick != null) {
        defaultGateway = { address = mine.${pick}.gateway; interface = pick; };
      };
    };

  mikrotikSections = {
    "/ip address" = map
      (it:
        let a = it.a; in {
          address = "${a.address}/${toString a.prefixLength}";
          network = (ipv4.subnet a.cidr).network;
          interface = it.i;
          comment = "${it.h} ${a.zone}";
        })
      (filter (e: e.a.role == "router" && e.a.address != null) all);

    "/ip pool" = map
      (z:
        let zi = zones.${z}.ipv4; p = zi.dhcp.pool; in {
          name = if zi.dhcp.poolName != null then zi.dhcp.poolName else "dhcp-${z}";
          ranges = "${ipv4.addressAt (v4Base z) p.start}-${ipv4.addressAt (v4Base z) p.end}";
        })
      (filter (z: zones.${z}.ipv4.dhcp.pool != null) v4Zones);

    # `/ip dhcp-server` binds a pool to an interface; `/ip dhcp-server network`
    # then describes that segment. The interface is the one the router itself
    # holds on the zone, so the two cannot end up describing different segments.
    "/ip dhcp-server" = map
      (z:
        let
          zi = zones.${z}.ipv4;
          poolName = if zi.dhcp.poolName != null then zi.dhcp.poolName else "dhcp-${z}";
        in
        {
          name = if zi.dhcp.serverName != null then zi.dhcp.serverName else "dhcp-${z}";
          interface = head (map (e: e.i) (filter (e: e.a.zone == z && e.a.role == "router") all));
          address-pool = poolName;
        })
      # Only a zone with a router on it has anything for a dhcp-server entry to
      # bind to; a pool nobody serves is not an error, it is just not served.
      (filter
        (z: zones.${z}.ipv4.dhcp.pool != null
          && filter (e: e.a.zone == z && e.a.role == "router") all != [ ])
        v4Zones);

    "/ip dhcp-server network" = map
      (z:
        let
          zi = zones.${z}.ipv4;
          # What clients resolve with is a lease property, not the zone's own
          # resolver: a segment can be served by the router while its guests are
          # pointed at a public resolver.
          leaseDns = if zi.dhcp.dns != [ ] then zi.dhcp.dns else zi.dns;
        in
        # An attribute is only rendered when it has a value: `dns-server=` (from
          # an empty list) is rejected by RouterOS on import, and a null gateway
          # reaches the renderer's `scalar`, which throws with no zone named.
        { address = v4Base z; }
        // lib.optionalAttrs (zi.defaultGateway != null) {
          gateway = resolve z zi.defaultGateway;
        }
        // lib.optionalAttrs (leaseDns != [ ]) {
          dns-server = concatStringsSep "," (map (resolve z) leaseDns);
        })
      (filter (z: zones.${z}.ipv4.dhcp.pool != null) v4Zones);

    "/ip dhcp-server lease" = map
      (e: { address = e.a.address; mac-address = e.a.mac; comment = e.h; })
      # `staticLeases` used to be declared and never read, so turning it off
      # changed nothing. It gates the leases now.
      (filter
        (e: e.a.mac != null && e.a.role == "host"
          && (zones.${e.a.zone}.ipv4.dhcp.staticLeases or true))
        all);
  };

  dnsRecords = mapAttrs
    (h: _:
      let mine = lib.attrValues addresses.${h}; in
      {
        A = map (a: a.address) (filter (a: a.address != null) mine);
        AAAA = map (a: a.ipv6.address) (filter (a: a.ipv6 != null) mine);
        aliases = config.machines.${h}.aliases;
      })
    config.machines;

  hostsFile = concatStringsSep "\n" (
    concatMap
      (h:
        let
          names = concatStringsSep " " ([ h ] ++ config.machines.${h}.aliases);
          mine = lib.attrValues addresses.${h};
        in
        map (a: "${a.address} ${names}") (filter (a: a.address != null) mine)
        ++ map (a: "${a.ipv6.address} ${names}") (filter (a: a.ipv6 != null) mine))
      (attrNames config.machines));

  targetHostFor = host:
    let
      mine = filterAttrs (_: a: a.address != null && !(zones.${a.zone}.external or false)) (addresses.${host} or { });
      mgmt = filterAttrs (_: a: a.zone == "mgmt") mine;
      pick = if mgmt != { } then mgmt else mine;
    in
    if pick == { } then null else "root@${(head (lib.attrValues pick)).address}";
in
{
  inherit addresses assertions zones reservations;
  inherit networkAddressZones;
  inherit nixosModuleFor mikrotikSections dnsRecords hostsFile targetHostFor;
}
