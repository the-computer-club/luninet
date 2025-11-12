
{
  outputs = _:
  let
    mapAttrsToList = f: attrs: map (name: f name attrs.${name}) (builtins.attrNames attrs);
    toNonFlakeParts = data: (mapAttrsToList toPeers data);
    toPeers = n: v: {
      publicKey = v.publicKey;
      allowedIPs = v.ipv4;
      endpoint = v.selfEndpoint or null;
      persistentKeepalive = v.persistentKeepalive or null;
    };

    peers = wireguard.networks.asluni.peers.by-name;

    peerARecord = p: {
      A =
          if p ? ipv4
          then map (x: builtins.head (builtins.split "/" x)) p.ipv4
          else [];
      AAAA =
        if
          p ? ipv6
        then
          map (x: builtins.head (builtins.split "/" x)) p.ipv6
        else
          [];
     };

    zones =
       let
         NS = ["ns2.unallocatedspace.luni."];
         SOA = {
           nameServer = "unallocatedspace.luni.";
           adminEmail = "contact@unallocatedspace.luni";
           serial = 2025072000; # 2025-07-20-00
         };
         artixRec = (peerARecord peers.artix);
       in
      {
        "unallocatedspace.luni" = artixRec // {
          inherit NS SOA;
          subdomains = {
            codex = artixRec;
            buildbot = artixRec;
            sesh = artixRec;
            tape = artixRec;
            turn = artixRec;
            media = artixRec;
            jitsi = artixRec;
            pgadmin = artixRec;
            admin = artixRec;
            mumble = artixRec;
            observe = artixRec;
            flagship = peerARecord peers.flagship;
          };
        };
      };

    wireguard.networks.asluni = {
      listenPort = 63723;
      peers.by-name = {
        cardinal = {
          publicKey = "2Q5yU5ueoDcEc+Segj/FJZ61IIiLWUVHtzf4uV31NjI=";
          ipv4 = [ "172.16.2.1/32" ];
          selfEndpoint = "unallocatedspace.dev:63723";
        };

        artix = {
          publicKey = "3CThsm++hbh48Oe7BX6PNQhUyWoCMsaq3gd0KvCoITM=";
          ipv4 = [ "172.16.2.2/32" ];
          selfEndpoint = "23.94.99.203:63723";
        };

        cypress = {
          publicKey = "nvuYPHJ2BUjXGyUMwr03XZYTMZGSQDyv3vDfZpGzfwo=";
          ipv4 = [ "172.16.2.3/32" ];
          persistentKeepalive = 10;
        };

        hydrogen = {
          publicKey = "qXsTs+IsmHeq9+rulmG6M7XhVgu/3N/wEgEaHPuHciU=";
          ipv4 = [ "172.16.2.4/32" ];
        };

        quantum = {
          publicKey = "FuOo9TwnE8P/zDBorjGNtsyPImHsHPxA21ePNrElsD0=";
          ipv4 = [ "172.16.2.5/32" ];
        };

        flagship = {
          publicKey = "qHQIOwGK7+6hXuBr6g1U00IzOM1p7Wc/ov/svPom0A8=";
          ipv4 = [ "172.16.2.6/32" ];
        };

        argon = {
          publicKey = "YO5w0tMvPt2lDdg9eD25wZsz9rWMTGbA/KuPYB6F1jQ=";
          ipv4 = [ "172.16.2.7/32" ];
        };

        pager1 = {
          publicKey = "NEN3VPGm58JLQkjUwq8MOhC/d7ZEZXcIjBl84ENGBzg=";
          ipv4 = [ "172.16.2.8/32" ];
        };

        simcra = {
          publicKey = "pq529jYwkJZZzdWB2fJ08A+41prV5gVsg3iE/kVN0GQ=";
          ipv4 = [ "172.16.2.9/32" ];
        };

        "0xc000000f" = {
          publicKey = "58qZ8KjLz80JPfSgsWU7iPpS6bjy94NONVoufLGxeX4=";
          ipv4 = [ "172.16.2.10/32" ];
        };

        tangobee = {
          publicKey = "5kGzZgx1QMLvdm7OsZoMzG7NC/4Pf3/S2MKFAvcR5wU=";
          ipv4 = [ "172.16.2.11/32" ];
        };

        voidhawk = {
          publicKey = "okKNJFTh42ZDFD5zcm2+bBJ6S2ht2QrQYb1Ktm+qdkY=";
          ipv4 = [ "172.16.2.12/32" ];
        };

        patch = {
          publicKey = "/tOmWpj1LZih8AqtS0P8PoBtI55+CY97TEUXx4iMxQo=";
          ipv4 = [ "172.16.2.13/32" ];
        };

        fluorine = {
          publicKey = "fCw+r4TKsxh36CdDSc6BTf0an9F2O8KQ189dYukpFHs=";
          ipv4 = [ "172.16.2.14/32" ];
          persistentKeepalive = 10;
        };

        "vxgw1.unallocatedspace.dev" = {
          publicKey = "YH/HBw/jOrG3EnXBu4asoCKGu7nnp1GvsjsFE/96q1E=";
          ipv4 = [ "172.16.2.15/32" "172.16.2.18/32" "172.16.2.19/32" ];
          persistentKeepalive = 10;
        };

        cypress-initrd = {
          publicKey = "rqHU9kjEuO6MBtXCON+qPjPwGBd1YF09oirl15M9xzM=";
          ipv4 = [ "172.16.2.16/32" ];
        };

        artix-initrd = {
          publicKey = "z74Ko8MZmZ40CKYfP3jekIydmtdNITRMQ55hrYp9TVQ=";
          ipv4 = [ "172.16.2.17/32" ];
        };

        lunarix-rpi = {
          publicKey = "tAow4qU5RDY0lxOmvBru/qB1cudT09pPFl+9zwkdF0Q=";
          ipv4 = [ "172.16.2.20/32" ];
          persistentKeepalive = 10;
        };

        porsche = {
          publicKey = "xqavFCvLVGYDyG/2ytgg7H5EV2wYXXEsvMWsOw2DyXM=";
          ipv4 = [ "172.16.2.21/32" ];
        };

        helium = {
          publicKey = "1OisEbl0ZTfqbUxrzMfKtoMD7Kz9VFahr0d+kpe9QB0=";
          ipv4 = [ "172.16.2.22/32" ];
        };

        hypothalamus = {
          publicKey = "9yzjykzsSnDxXA15sRf+PW/V3HFMxA3ZWTwngOWlUHk=";
          ipv4 = [ "172.16.2.23/32" ];
        };

        mesalon = {
          publicKey = "NBXhSrqgTN2LDfJ6MhqVwWFfxyBaqBjR5fYfLjb+gg8=";
          ipv4 = [ "172.16.2.24/32" ];
        };

        mesalon-vps = {
          publicKey = "/6egVjOjIIgxEzBAW+SWjSTmauxA5spi8cVAaQUX5GY=";
          ipv4 = [ "172.16.2.25/32" ];
        };

        wasp = {
          publicKey = "Y6di4cRd1Tq5Ii6C0ADrJPfMb0omVZ8hIJcuXQHEzBE=";
          ipv4 = [ "172.16.2.26/32" ];
        };

        ov13 = {
          publicKey = "S6yiCMatKlVX0WxyaWXTizasZPfQQ9oGM2pv82CtrgM=";
          ipv4 = [ "172.16.2.27/32" ];
        };

        sky = {
          publicKey = "EF4+fPzrAMqasS8Z7auajOuHmcvqcHVGQNPwhPo0/U8=";
          ipv4 = [ "172.16.2.42/32" ];
        };

        watermelon = {
          publicKey = "RksMNP9ojih2Jt8JqC1yWNImQnv0eJJ802fNS4T9pCI=";
          ipv4 = [ "172.16.2.55/32" ];
        };
        
        frogson = {
          publicKey = "5j44nM6qmbJ2S8B24aA/H6UEPVXJFfxf8sTacMktMis=";
          ipv4 = [ "172.16.2.69/32" ];
        };

        "jita.etherealryft.net" = {
          publicKey = "Ngp854R/d126OVrO7nRv0yj8rdHRjGURa5LbD/UT8Xk=";
          ipv4 = [ "172.16.2.71/32" ];
          selfEndpoint = "72.55.233.131:56854";
        };

        comet = {
          publicKey = "w90lfP16gY5debtjkfKVyKdL8mtlEXUmciNRTyTi7jw=";
          ipv4 = [ "172.16.2.96/32" ];
        };

        hexi = {
          publicKey = "UHmZ/pzB5cUFGEm9708pdG42vYVO+IkqtzeNaBAseWg=";
          ipv4 = ["172.16.2.99/32"];
        };

        Scott = {
          publicKey = "5W6KorrxAf3MWErAYlgSXcGUNEJfBwPTBlyEfRRfeXU=";
          ipv4 = [ "172.16.2.128/32" ];
        };

        merosity = {
          publicKey = "UHmZ/pzB5cUFGEm9708pdG42vYVO+IkqtzeNaBAseWg=";
          ipv4 = ["172.16.2.254/32"];
        };
      };
    };
  in
  {
    inherit zones;
    lib = { inherit toPeers toNonFlakeParts; };
    flakeModules.asluni = { inherit wireguard; };
    nixosModules.asluni = { inherit wireguard; };
  };
}
