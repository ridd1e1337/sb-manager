#!/usr/bin/env bash
# shellcheck shell=bash

# Plain VMess (protocol "vmess"; the Cloudflare WebSocket template is
# "vmess-ws-cf"). TLS is optional; transports come from the sing-box extension.
protocol_vmess_std_render() {
  local node=$1 credentials=$2 domain cert_dir base
  domain=$(jq -r '.domain // ""' <<<"$node"); cert_dir="$SBM_CERTS/$domain"
  base=$(jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --argjson users "$(jq '[.[] | {name,uuid,alterId:0}]' <<<"$credentials")" \
    '{type:"vmess",tag:$tag,listen:$listen,listen_port:$port,users:$users}') || return 1
  if [[ $(jq -r '.security // "none"' <<<"$node") == tls ]]; then
    jq --arg domain "$domain" --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
      '. + {tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}}' <<<"$base"
  else printf '%s\n' "$base"; fi
}

protocol_vmess_std_client_outbound() {
  local node=$1 secret=$2
  jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg uuid "$(jq -r '.uuid' <<<"$secret")" \
    --arg security "$(jq -r '.security // "none"' <<<"$node")" --arg domain "$(jq -r '.domain // ""' <<<"$node")" \
    '{type:"vmess",tag:$tag,server:$server,server_port:$port,uuid:$uuid,security:"auto",alter_id:0}
     + (if $security=="tls" then {tls:{enabled:true,server_name:$domain}} else {} end)'
}

# v2rayN-style link built from the effective client outbound.
protocol_vmess_std_share() {
  local node=$1 secret=$2 outbound network payload
  [[ -n $(jq -r '.server_address // ""' <<<"$node") ]] || return 1
  outbound=$(protocol_vmess_std_client_outbound "$node" "$secret") || return 1
  outbound=$(singbox_apply_override "$outbound" "$(singbox_node_override "$node" outbound)") || return 1
  network=$(jq -r '.transport.type // "tcp"' <<<"$outbound")
  case "$network" in tcp|ws|grpc|httpupgrade) ;; *) log_warn "分享链接无法表达 $network 传输，请使用 sing-box 客户端配置。"; return 1;; esac
  payload=$(jq -c --arg name "$(jq -r '.name' <<<"$node")" --arg network "$network" '
    {v:"2",ps:$name,add:.server,port:(.server_port|tostring),id:.uuid,aid:"0",scy:(.security // "auto"),net:$network,type:"none",
     host:((.transport.headers.Host // .transport.host // "")|if type=="array" then .[0] else . end),
     path:(if $network=="grpc" then (.transport.service_name // "") elif $network=="tcp" then "" else (.transport.path // "/") end),
     tls:(if .tls.enabled==true then "tls" else "" end),sni:(.tls.server_name // ""),
     alpn:((.tls.alpn // [])|join(",")),fp:(.tls.utls.fingerprint // "")}' <<<"$outbound") || return 1
  printf 'vmess://%s\n' "$(printf '%s' "$payload" | base64_nowrap)"
}
