#!/usr/bin/env bash
# shellcheck shell=bash

# VLESS served by sing-box: TCP with TLS or Reality and optional Vision flow.
# Transports and other native fields go through the per-node
# --sing-box-inbound-json / --sing-box-outbound-json extensions.

protocol_vless_generate_reality_secret() {
  local output private public
  output=$("$SBM_SING_BOX_BIN" generate reality-keypair 2>/dev/null) || { log_error 'Reality 密钥生成失败。'; return 1; }
  private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$output")
  public=$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$output")
  [[ "$private" =~ ^[A-Za-z0-9_-]{43}$ && "$public" =~ ^[A-Za-z0-9_-]{43}$ ]] || { log_error '无法解析 Reality 密钥。'; return 1; }
  jq -n --arg private "$private" --arg public "$public" --arg short_id "$(random_hex 4)" \
    '{reality_private_key:$private,reality_public_key:$public,reality_short_id:$short_id}'
}

protocol_vless_render() {
  local node=$1 credentials=$2 node_secret=$3 security domain flow base cert_dir
  security=$(jq -r '.security' <<<"$node"); domain=$(jq -r '.domain' <<<"$node"); flow=$(jq -r '.flow // ""' <<<"$node")
  base=$(jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg flow "$flow" \
    --argjson users "$(jq --arg flow "$flow" '[.[] | {name,uuid,flow:$flow}]' <<<"$credentials")" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:$users}')
  if [[ "$security" == reality ]]; then
    jq --arg domain "$domain" --arg server "$(jq -r '.handshake_server' <<<"$node")" \
      --argjson port "$(jq -r '.handshake_port' <<<"$node")" --arg private "$(jq -r '.reality_private_key' <<<"$node_secret")" \
      --arg short_id "$(jq -r '.reality_short_id' <<<"$node_secret")" \
      '. + {tls:{enabled:true,server_name:$domain,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$private,short_id:[$short_id],max_time_difference:"1m"}}}' <<<"$base"
  else
    cert_dir="$SBM_CERTS/$domain"
    jq --arg domain "$domain" --arg cert "$cert_dir/fullchain.pem" --arg key "$cert_dir/key.pem" \
      '. + {tls:{enabled:true,server_name:$domain,certificate_path:$cert,key_path:$key}}' <<<"$base"
  fi
}

# Share links describe the effective client outbound, so a transport added
# through --sing-box-outbound-json is reflected instead of a stale TCP link.
protocol_vless_share() {
  local node=$1 secret=$2 node_secret=$3 outbound address port uuid flow security domain network uri query
  outbound=$(protocol_vless_client_outbound "$node" "$secret" "$node_secret") || return 1
  outbound=$(singbox_apply_override "$outbound" "$(singbox_node_override "$node" outbound)") || return 1
  address=$(jq -r '.server' <<<"$outbound"); port=$(jq -r '.server_port' <<<"$outbound")
  uuid=$(jq -r '.uuid' <<<"$outbound"); flow=$(jq -r '.flow // ""' <<<"$outbound")
  domain=$(jq -r '.tls.server_name // ""' <<<"$outbound")
  security=$(jq -r 'if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end' <<<"$outbound")
  network=$(jq -r '.transport.type // "tcp"' <<<"$outbound")
  case "$network" in tcp|ws|grpc|httpupgrade) ;; *) log_warn "分享链接无法表达 $network 传输，请使用 sing-box 客户端配置。"; return 1;; esac
  query="encryption=none&security=${security}&type=${network}"
  [[ -z "$domain" ]] || query+="&sni=$(urlencode "$domain")"
  [[ -z "$flow" ]] || query+="&flow=$(urlencode "$flow")"
  query+=$(jq -r '
    def enc: @uri;
    (.tls.utls.fingerprint // "") as $fp |
    (if $fp!="" then "&fp="+($fp|enc) elif .tls.reality.enabled==true then "&fp=chrome" else "" end)
    + (if .tls.reality.enabled==true then "&pbk="+(.tls.reality.public_key|enc)+"&sid="+((.tls.reality.short_id // "")|enc) else "" end)
    + (if (.tls.alpn // [])|length>0 then "&alpn="+(.tls.alpn|join(",")|enc) else "" end)
    + (if .transport.type=="ws" or .transport.type=="httpupgrade" then
        "&path="+((.transport.path // "/")|enc)
        + (((.transport.headers.Host // .transport.host // "")|if type=="array" then .[0] else . end) as $h | if $h!="" then "&host="+($h|enc) else "" end)
      elif .transport.type=="grpc" then "&serviceName="+((.transport.service_name // "")|enc) else "" end)
  ' <<<"$outbound") || return 1
  uri="vless://${uuid}@$(format_hostport "$address" "$port")?${query}"
  printf '%s#%s\n' "$uri" "$(urlencode "$(jq -r '.name' <<<"$node")")"
}

protocol_vless_client_outbound() {
  local node=$1 secret=$2 node_secret=$3 security domain flow base
  security=$(jq -r '.security' <<<"$node"); domain=$(jq -r '.domain' <<<"$node"); flow=$(jq -r '.flow // ""' <<<"$node")
  base=$(jq -n --arg tag "proxy-$(jq -r '.id' <<<"$node")" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg uuid "$(jq -r '.uuid' <<<"$secret")" --arg flow "$flow" \
    '{type:"vless",tag:$tag,server:$server,server_port:$port,uuid:$uuid,flow:$flow,network:"tcp"}')
  if [[ "$security" == reality ]]; then
    jq --arg domain "$domain" --arg public "$(jq -r '.reality_public_key' <<<"$node_secret")" \
      --arg short_id "$(jq -r '.reality_short_id' <<<"$node_secret")" \
      '. + {tls:{enabled:true,server_name:$domain,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$public,short_id:$short_id}}}' <<<"$base"
  else
    jq --arg domain "$domain" '. + {tls:{enabled:true,server_name:$domain}}' <<<"$base"
  fi
}
