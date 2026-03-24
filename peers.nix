{

  # cardinal = {
  #   isController = true;
  #   publicKey = "GfzR2IYKx6IBXwGVNSTVnCRcQSr/Wm5dlPwXHO2xykI=";
  #   selfEndpoint = "72.11.152.185:31690";
  # };

  gateway = {
    isController = true;
    publicKey = "GfzR2IYKx6IBXwGVNSTVnCRcQSr/Wm5dlPwXHO2xykI=";
    # selfEndpoint = "198.12.96.43:24122";
    ipv4 = ["172.29.80.0/24"];
    ipv6 = ["fd49:093b:2b68::/48"];

    # TODO: Add IPv4 port mapping.
    # portmap = [
    #   { # create a port
    #     # on 0.0.0.0:${dst-port} -> ${to-address}:${to-port}
    #     dst-port = 25543;
    #     to-port = 25543;
    #     to-address = "10.0.0.1"; # or peers.${hostname}.ipv4
    #   }
    # ];
  };

  simcra.publicKey = "pq529jYwkJZZzdWB2fJ08A+41prV5gVsg3iE/kVN0GQ=";
  tangobee.publicKey = "5kGzZgx1QMLvdm7OsZoMzG7NC/4Pf3/S2MKFAvcR5wU=";
  fluorine.publicKey = "fCw+r4TKsxh36CdDSc6BTf0an9F2O8KQ189dYukpFHs=";
  hypothalamus.publicKey = "9yzjykzsSnDxXA15sRf+PW/V3HFMxA3ZWTwngOWlUHk=";
  mesalon.publicKey = "NBXhSrqgTN2LDfJ6MhqVwWFfxyBaqBjR5fYfLjb+gg8=";
  mesalon-vps.publicKey = "/6egVjOjIIgxEzBAW+SWjSTmauxA5spi8cVAaQUX5GY=";
  ov13.publicKey = "S6yiCMatKlVX0WxyaWXTizasZPfQQ9oGM2pv82CtrgM=";
  frogson.publicKey = "5j44nM6qmbJ2S8B24aA/H6UEPVXJFfxf8sTacMktMis=";
  comet.publicKey = "w90lfP16gY5debtjkfKVyKdL8mtlEXUmciNRTyTi7jw=";
  hexi.publicKey = "UHmZ/pzB5cUFGEm9708pdG42vYVO+IkqtzeNaBAseWg=";
}
