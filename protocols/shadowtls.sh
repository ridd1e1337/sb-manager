#!/usr/bin/env bash
# shellcheck shell=bash

protocol_shadowtls_validate_keys() {
  local credentials=$1 node_secret=$2
  jq -e '(.shadowsocks_server_password // "") | test("^[A-Za-z0-9+/]{22}==$")' <<<"$node_secret" >/dev/null \
    && jq -e '(if type=="array" then . else [.] end) | length>0 and all(.[]; (.password|type=="string" and length>0) and ((.shadowsocks_password // "") | test("^[A-Za-z0-9+/]{22}==$")))' <<<"$credentials" >/dev/null \
    || { log_error 'ShadowTLS 缺少有效的外层密码或 Shadowsocks 2022 内层密钥；请使用管理器迁移或恢复完整备份。'; return 1; }
}

protocol_shadowtls_render() {
  local node=$1 credentials=$2 node_secret=$3
  protocol_shadowtls_validate_keys "$credentials" "$node_secret" || return 1
  jq -n --arg tag "in-$(jq -r '.id' <<<"$node")" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --argjson users "$credentials" \
    --arg key "$(jq -r '.shadowsocks_server_password' <<<"$node_secret")" \
    --arg server "$(jq -r '.handshake_server' <<<"$node")" --argjson server_port "$(jq -r '.handshake_port' <<<"$node")" \
    --argjson strict "$(jq 'if .strict_mode==null then true else .strict_mode end' <<<"$node")" --arg wildcard "$(jq -r '.wildcard_sni // "off"' <<<"$node")" \
    '[{type:"shadowtls",tag:$tag,listen:$listen,listen_port:$port,version:3,users:[$users[]|{name,password}],
       handshake:{server:$server,server_port:$server_port},strict_mode:$strict,wildcard_sni:$wildcard,detour:($tag+":ss")},
      {type:"shadowsocks",tag:($tag+":ss"),listen:"127.0.0.1",listen_port:0,network:"tcp",method:"2022-blake3-aes-128-gcm",password:$key,
       users:[$users[]|{name,password:.shadowsocks_password}]}]'
}

protocol_shadowtls_share() {
  local node=$1 secret=$2 node_secret=$3 address port password name hp sni userinfo plugin
  protocol_shadowtls_validate_keys "$secret" "$node_secret" || return 1
  address=$(jq -r '.server_address' <<<"$node"); port=$(jq -r '.port' <<<"$node"); password=$(jq -r '.password' <<<"$secret")
  name=$(jq -r '.name' <<<"$node"); sni=$(jq -r '.handshake_server' <<<"$node"); hp=$(format_hostport "$address" "$port")
  userinfo=$(printf '2022-blake3-aes-128-gcm:%s:%s' "$(jq -r '.shadowsocks_server_password' <<<"$node_secret")" "$(jq -r '.shadowsocks_password' <<<"$secret")" | base64url_nowrap)
  plugin="shadow-tls;host=$sni;password=$password;version=3"
  printf 'ss://%s@%s/?plugin=%s#%s\n' "$userinfo" "$hp" "$(urlencode "$plugin")" "$(urlencode "$name")"
}

protocol_shadowtls_client_outbound() {
  local node=$1 secret=$2 node_secret=$3 tag=$4
  protocol_shadowtls_validate_keys "$secret" "$node_secret" || return 1
  jq -n --arg tag "$tag" --arg server "$(jq -r '.server_address' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --arg password "$(jq -r '.password' <<<"$secret")" \
    --arg key "$(jq -r '.shadowsocks_server_password' <<<"$node_secret"):$(jq -r '.shadowsocks_password' <<<"$secret")" \
    --arg sni "$(jq -r '.handshake_server' <<<"$node")" \
    '[{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,method:"2022-blake3-aes-128-gcm",password:$key,network:"tcp",detour:($tag+":tls")},
      {type:"shadowtls",tag:($tag+":tls"),server:$server,server_port:$port,version:3,password:$password,
       tls:{enabled:true,server_name:$sni,insecure:false,utls:{enabled:true,fingerprint:"chrome"}}}]'
}
