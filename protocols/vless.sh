#!/usr/bin/env bash
# shellcheck shell=bash

protocol_vless_generate_reality_secret() {
  local output private public engine
  engine=${1:-$(jq -r '.settings.vless_engine // "sing-box"' "$SBM_STATE")} || return 1
  if [[ "$engine" == xray ]]; then
    [[ -x "$SBM_XRAY_BIN" ]] || { log_error '请先安装 Xray 再生成 Reality 密钥。'; return 1; }
    output=$("$SBM_XRAY_BIN" x25519 2>/dev/null) || { log_error 'Xray Reality 密钥生成失败。'; return 1; }
  else
    output=$("$SBM_SING_BOX_BIN" generate reality-keypair 2>/dev/null) || { log_error 'Reality 密钥生成失败。'; return 1; }
  fi
  private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$output")
  public=$(awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' <<<"$output")
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

# All client formats consume the same effective native Xray outbound. This
# prevents a transport/security override from leaving a stale TCP share link.
protocol_vless_export_result() {
  local mode=$1 node=$2 secret=$3 node_secret=$4 outbound name packet
  outbound=$(vless_xray_client_outbound "$node" "$secret" "$node_secret") || return 1
  name=$(jq -r '.name' <<<"$node") || return 1
  packet=$(jq -r '.xray.packet_encoding // ""' <<<"$node") || return 1
  jq -c --arg mode "$mode" --arg name "$name" --arg packet_encoding "$packet" \
    -f "$SBM_LIB/libexec/vless_export.jq" <<<"$outbound"
}

protocol_vless_export_value() {
  local mode=$1 node=$2 secret=$3 node_secret=$4 result
  result=$(protocol_vless_export_result "$mode" "$node" "$secret" "$node_secret") || return 1
  if ! jq -e '.ok==true' <<<"$result" >/dev/null; then
    log_warn "$(jq -r '.reason' <<<"$result")"
    return 1
  fi
  if [[ "$mode" == uri ]]; then jq -r '.value' <<<"$result"
  else jq -c '.value' <<<"$result"; fi
}

protocol_vless_share() {
  protocol_vless_export_value uri "$1" "$2" "$3"
}

protocol_vless_client_outbound() {
  protocol_vless_export_value singbox "$1" "$2" "$3"
}

protocol_vless_mihomo_outbound() {
  protocol_vless_export_value mihomo "$1" "$2" "$3"
}
