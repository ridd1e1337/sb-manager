#!/usr/bin/env bash
# shellcheck shell=bash

# Hysteria (v1). Bandwidth is the server's view: the client mirrors it.
protocol_hysteria_render() {
  local node=$1 credentials=$2 node_secret=${3:-'{}'} domain cert_dir
  domain=$(jq -r '.domain' <<<"$node"); cert_dir="$SBM_CERTS/$domain"
  jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --argjson users "$(jq '[.[] | {name,auth_str:.password}]' <<<"$credentials")" \
    --argjson up "$(jq -r '.up_mbps // 100' <<<"$node")" --argjson down "$(jq -r '.down_mbps // 100' <<<"$node")" \
    --arg obfs "$(jq -r '.obfs_password // ""' <<<"$node_secret")" \
    --arg domain "$domain" --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
    '{type:"hysteria",tag:$tag,listen:$listen,listen_port:$port,up_mbps:$up,down_mbps:$down,users:$users,
      tls:{enabled:true,server_name:$domain,alpn:["h3"],certificate_path:$cert,key_path:$key}}
     + (if $obfs=="" then {} else {obfs:$obfs} end)'
}

protocol_hysteria_client_outbound() {
  local node=$1 secret=$2 node_secret=${3:-'{}'}
  jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg auth "$(jq -r '.password' <<<"$secret")" \
    --argjson up "$(jq -r '.up_mbps // 100' <<<"$node")" --argjson down "$(jq -r '.down_mbps // 100' <<<"$node")" \
    --arg obfs "$(jq -r '.obfs_password // ""' <<<"$node_secret")" --arg domain "$(jq -r '.domain' <<<"$node")" \
    '{type:"hysteria",tag:$tag,server:$server,server_port:$port,up_mbps:$down,down_mbps:$up,auth_str:$auth,
      tls:{enabled:true,server_name:$domain,alpn:["h3"]}}
     + (if $obfs=="" then {} else {obfs:$obfs} end)'
}

protocol_hysteria_share() {
  local node=$1 secret=$2 node_secret=${3:-'{}'} outbound
  [[ -n $(jq -r '.server_address // ""' <<<"$node") ]] || return 1
  outbound=$(protocol_hysteria_client_outbound "$node" "$secret" "$node_secret") || return 1
  outbound=$(singbox_apply_override "$outbound" "$(singbox_node_override "$node" outbound)") || return 1
  printf 'hysteria://%s?%s#%s\n' "$(format_hostport "$(jq -r '.server' <<<"$outbound")" "$(jq -r '.server_port' <<<"$outbound")")" \
    "$(jq -r 'def enc: @uri;
      "protocol=udp&auth="+(.auth_str|enc)+"&peer="+((.tls.server_name // "")|enc)+"&insecure=0"
      +"&upmbps="+(.up_mbps|tostring)+"&downmbps="+(.down_mbps|tostring)
      +(if (.tls.alpn // [])|length>0 then "&alpn="+(.tls.alpn|join(",")|enc) else "" end)
      +(if (.obfs // "")!="" then "&obfs=xplus&obfsParam="+(.obfs|enc) else "" end)' <<<"$outbound")" \
    "$(urlencode "$(jq -r '.name' <<<"$node")")"
}
