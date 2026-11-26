#!/usr/bin/env bash
# shellcheck shell=bash

# Inbounds without users: a port forward (sing-box "direct" with a fixed
# target) and the transparent-proxy listeners "redirect" / "tproxy". They
# only listen; routing packets to them (iptables / nftables) stays with the
# operator, the manager never touches the host firewall.
protocol_direct_render() {
  local node=$1
  jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --argjson n "$node" '
    {type:($n.mode // "direct"),tag:$tag,listen:($n.listen // "::"),listen_port:$n.port}
    + (if ($n.mode // "direct")=="redirect" or ($n.network // "")=="" then {} else {network:$n.network} end)
    + (if ($n.mode // "direct")=="direct" then {override_address:$n.target_address,override_port:$n.target_port} else {} end)'
}
