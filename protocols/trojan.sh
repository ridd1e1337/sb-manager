#!/usr/bin/env bash
# shellcheck shell=bash

protocol_trojan_render() {
  local node=$1 credentials=$2 domain cert_dir
  domain=$(jq -r '.domain' <<<"$node"); cert_dir="$SBM_CERTS/$domain"
  jq -n \
    --arg tag "in-$(jq -r '.id' <<<"$node")" \
    --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" \
    --argjson users "$(jq '[.[] | {name,password}]' <<<"$credentials")" \
    --arg domain "$domain" --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
    '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:$users,
      tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}}'
}

# The link describes the effective client outbound, so a transport, ALPN or
# fingerprint set through the extension is reflected instead of a stale TCP link.
protocol_trojan_share() {
  local node=$1 secret=$2 outbound network
  [[ -n $(jq -r '.server_address // ""' <<<"$node") ]] || return 1
  outbound=$(protocol_trojan_client_outbound "$node" "$secret") || return 1
  outbound=$(singbox_apply_override "$outbound" "$(singbox_node_override "$node" outbound)") || return 1
  network=$(jq -r '.transport.type // "tcp"' <<<"$outbound")
  case "$network" in tcp|ws|grpc|httpupgrade) ;; *) log_warn "分享链接无法表达 $network 传输，请使用 sing-box 客户端配置。"; return 1;; esac
  printf 'trojan://%s@%s?%s#%s\n' "$(urlencode "$(jq -r '.password' <<<"$outbound")")" \
    "$(format_hostport "$(jq -r '.server' <<<"$outbound")" "$(jq -r '.server_port' <<<"$outbound")")" \
    "$(jq -r --arg network "$network" '
      def enc: @uri;
      "security=tls&sni="+((.tls.server_name // "")|enc)+"&type="+$network
      + ((.tls.utls.fingerprint // "") as $fp | if $fp!="" then "&fp="+($fp|enc) else "" end)
      + (if (.tls.alpn // [])|length>0 then "&alpn="+(.tls.alpn|join(",")|enc) else "" end)
      + (if $network=="ws" or $network=="httpupgrade" then
          "&path="+((.transport.path // "/")|enc)
          + (((.transport.headers.Host // .transport.host // "")|if type=="array" then .[0] else . end) as $h | if $h!="" then "&host="+($h|enc) else "" end)
        elif $network=="grpc" then "&serviceName="+((.transport.service_name // "")|enc) else "" end)' <<<"$outbound")" \
    "$(urlencode "$(jq -r '.name' <<<"$node")")"
}

protocol_trojan_client_outbound() {
  local node=$1 secret=$2
  jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg password "$(jq -r '.password' <<<"$secret")" \
    --arg domain "$(jq -r '.domain' <<<"$node")" \
    '{type:"trojan",tag:$tag,server:$server,server_port:$port,password:$password,tls:{enabled:true,server_name:$domain}}'
}
