{ config, lib, pkgs, ... }:

{
  registry = {
    isController = true;
    publicKey = "KdO2Js/JUOq1Yv6fzN64P3LLrfkKMqUNxeE5R1JJTHU=";
    selfEndpoint = "198.12.96.43:32289";
    ipv4 = ["172.29.84.1/32"];
  };
}
