#!/usr/bin/env bash
# shellcheck shell=bash

# Resolve server and client from one native Xray profile. Public exports must
# never copy a server TLS key, REALITY private key, or cloud storage credential.
vless_network_normalize() {
  case "${1,,}" in
    ''|tcp|raw) printf 'raw\n';;
    ws|websocket) printf 'ws\n';;
    xhttp|splithttp) printf 'xhttp\n';;
    kcp|mkcp) printf 'kcp\n';;
    grpc|httpupgrade|hysteria|xdrive) printf '%s\n' "${1,,}";;
    masque) log_error 'MASQUE 传输不支持 VLESS，请使用对应核心原生协议。'; return 1;;
    http|h2|h3|quic) log_error '当前 Xray 已移除此旧传输，请使用 XHTTP。'; return 1;;
    *) log_error '无法识别的 VLESS 传输，请使用当前 Xray 支持的 network。'; return 1;;
  esac
}

vless_node_network() {
  local network
  network=$(jq -r '.xray.inbound.streamSettings.method // .xray.inbound.streamSettings.network // "raw"' <<<"$1") || return 1
  vless_network_normalize "$network"
}

vless_node_listener_kinds() {
  local network
  network=$(vless_node_network "$1") || return 1
  case "$network" in
    kcp|hysteria) printf 'udp\n';;
    xdrive) return 0;;
    xhttp)
      if jq -e '.xray.inbound.streamSettings.tlsSettings.alpn==["h3"] and (.xray.inbound.streamSettings.security // .security)=="tls"' <<<"$1" >/dev/null; then printf 'udp\n'
      else printf 'tcp\n'; fi;;
    *) printf 'tcp\n';;
  esac
}

vless_stream_normalize() {
  local stream=$1 network
  network=$(jq -r '.method // .network // "raw"' <<<"$stream") || return 1
  network=$(vless_network_normalize "$network") || return 1
  jq --arg network "$network" '
    .network=$network | del(.method)
    | if .rawSettings==null and .tcpSettings!=null then .rawSettings=.tcpSettings else . end | del(.tcpSettings)
    | if .xhttpSettings==null and .splithttpSettings!=null then .xhttpSettings=.splithttpSettings else . end | del(.splithttpSettings)
    | .security=(if (.security // "")=="" then "none" else .security end)
  ' <<<"$stream"
}

vless_b64url_decode() {
  local value=$1
  [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  while (( ${#value} % 4 )); do value+='='; done
  printf '%s' "$value" | tr '_-' '/+' | base64 -d
}

vless_x25519_public() {
  local private=$1
  [[ "$private" =~ ^[A-Za-z0-9_-]{43}$ ]] || { log_error 'X25519 私钥格式无效。'; return 1; }
  # PKCS#8 X25519 prefix + 32-byte private key; the key never enters argv.
  {
    printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
    vless_b64url_decode "$private" || return 1
  } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64url_nowrap
}

vless_pq_public() {
  local algorithm=$1 seed=$2 output value
  [[ -x "$SBM_XRAY_BIN" ]] || { log_error '此后量子参数需要已安装的官方 Xray 生成配对公钥。'; return 1; }
  # Upstream's key utilities only accept -i. Capture their output, including
  # the echoed private seed, and return only the public component.
  case "$algorithm" in
    mlkem768)
      [[ "$seed" =~ ^[A-Za-z0-9_-]{86}$ ]] || return 1
      output=$("$SBM_XRAY_BIN" mlkem768 -i "$seed" 2>/dev/null) || return 1
      value=$(awk -F': *' '$1=="Client" {print $2; exit}' <<<"$output") || return 1
      [[ "$value" =~ ^[A-Za-z0-9_-]{1579}$ ]] || return 1;;
    mldsa65)
      [[ "$seed" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
      output=$("$SBM_XRAY_BIN" mldsa65 -i "$seed" 2>/dev/null) || return 1
      value=$(awk -F': *' '$1=="Verify" {print $2; exit}' <<<"$output") || return 1
      [[ "$value" =~ ^[A-Za-z0-9_-]{2603}$ ]] || return 1;;
    *) return 1;;
  esac
  printf '%s\n' "$value"
}

vless_encryption_public() {
  local decryption=$1 mode=${2:-0rtt} part public result count=0
  local -a parts=()
  [[ "$decryption" != none ]] || { printf 'none\n'; return 0; }
  IFS=. read -r -a parts <<<"$decryption"
  (( ${#parts[@]} >= 4 )) && [[ ${parts[0]} == mlkem768x25519plus ]] || { log_error '不支持的 VLESS decryption 格式。'; return 1; }
  case "${parts[1]}" in native|xorpub|random) ;; *) return 1;; esac
  [[ "${parts[2]}" =~ ^[0-9]+(-[0-9]+)?s?$ ]] || return 1
  case "$mode" in 0rtt|1rtt) ;; *) return 1;; esac
  result="${parts[0]}.${parts[1]}.$mode"
  for part in "${parts[@]:3}"; do
    if (( ${#part} < 20 )); then result+=".$part"; continue; fi
    case ${#part} in
      43) public=$(vless_x25519_public "$part") || return 1;;
      86) public=$(vless_pq_public mlkem768 "$part") || return 1;;
      *) log_error 'VLESS decryption 私钥长度无效。'; return 1;;
    esac
    result+=".$public"; count=$((count + 1))
  done
  (( count > 0 )) || { log_error 'VLESS decryption 缺少认证密钥。'; return 1; }
  printf '%s\n' "$result"
}

vless_encryption_pair_check() {
  local decryption=$1 encryption=$2 expected
  if [[ "$decryption" == none || "$encryption" == none ]]; then
    [[ "$decryption" == none && "$encryption" == none ]] || { log_error 'VLESS encryption 与 decryption 必须同时启用或同时为 none。'; return 1; }
    return 0
  fi
  expected=$(vless_encryption_public "$decryption" "$(cut -d. -f3 <<<"$encryption")") || return 1
  jq -ne --arg expected "$expected" --arg actual "$encryption" '
    def keys: split(".") | .[3:] | map(select(length>=20));
    ($expected|split(".")|.[0:3])==($actual|split(".")|.[0:3]) and ($expected|keys)==($actual|keys)
  ' >/dev/null || { log_error 'VLESS encryption 公钥与服务端 decryption 不匹配。'; return 1; }
}

xray_vless_keys() {
  local kind=${1:-x25519} output index
  local -a values=()
  [[ -x "$SBM_XRAY_BIN" ]] || { log_error '请先运行 sb xray install。'; return 1; }
  case "$kind" in x25519) index=0;; mlkem768|ml-kem-768) index=2;; *) usage_die '密钥类型只能是 x25519 或 mlkem768。';; esac
  output=$("$SBM_XRAY_BIN" vlessenc 2>/dev/null) || return 1
  mapfile -t values < <(awk -F'"' '/^"decryption":|^"encryption":/ {print $4}' <<<"$output")
  (( ${#values[@]} == 4 )) || { log_error '无法解析当前 Xray 的 VLESS Encryption 密钥输出。'; return 1; }
  [[ ${values[index]} == mlkem768x25519plus.* && ${values[index+1]} == mlkem768x25519plus.* ]] || return 1
  jq -n --arg decryption "${values[index]}" --arg encryption "${values[index+1]}" '{decryption:$decryption,encryption:$encryption}'
}

vless_outbound_override_normalize() {
  jq -e '
    select(type=="object")
    | if .settings==null then .settings={} else . end
    | if (.settings|type)!="object" then error("VLESS 客户端 settings 必须是对象") else . end
    | if .settings.vnext!=null then
        if (.settings.vnext|type)!="array" or (.settings.vnext|length)!=1 or
          ((.settings.vnext[0].users // [{}])|type)!="array" or ((.settings.vnext[0].users // [{}])|length)!=1
        then error("VLESS 客户端扩展只接受一个 endpoint 和一个 user") else . end
      else . end
    | if .settings.address!=null or .settings.id!=null or .settings.encryption!=null or .settings.flow!=null or .settings.reverse!=null then
        .settings as $s | .settings={vnext:[{address:$s.address,port:$s.port,users:[($s|del(.address,.port,.vnext))]}]}
      else . end
    | if .streamSettings==null then .streamSettings={} else . end
    | if (.streamSettings|type)!="object" then error("VLESS 客户端 streamSettings 必须是对象") else . end
    | del(.protocol,.tag,.settings.address,.settings.port,.settings.id)
  ' <<<"$1"
}

vless_profile_pair_check() {
  local inbound=$1 outbound=$2 public=$3 verify=$4
  jq -e --argjson server "$inbound" --arg public "$public" --arg verify "$verify" '
    def fail($s): error($s);
    def req($condition;$s): if $condition then . else fail($s) end;
    def path($v): ($v // "/" | split("?")[0] | if .=="" then "/" else . end | sub("/+$"; ""));
    def host($s): $s.host // ([$s.headers // {}|to_entries[]|select(.key|ascii_downcase=="host")|.value][0]) // "";
    . as $client | $server.streamSettings as $ss | .streamSettings as $cs |
    .settings.vnext[0].users[0] as $user |
    (($server.settings.clients[0].flow // "") | if .=="" then ($server.settings.flow // "") else . end) as $server_flow |
    req($cs.network==$ss.network;"VLESS 服务端和客户端 network 不一致") |
    req($cs.security==$ss.security;"VLESS 服务端和客户端 security 不一致") |
    req(($user.flow // "" | sub("-udp443$"; ""))==$server_flow;"VLESS 客户端 flow 与服务端不一致") |
    req(($user.flow // "" | IN("","xtls-rprx-vision","xtls-rprx-vision-udp443"));"不支持的 VLESS 客户端 flow") |
    req(($cs|has("address")|not) and ($cs|has("port")|not);"请用节点地址与端口设置 VLESS 连接目标") |
    req(($client|has("packetEncoding")|not);"packetEncoding 不是 Xray 原生字段，请使用管理器客户端编码选项") |
    req((($ss.finalmask // {})|length)==0 or (($cs.finalmask // {})|length)>0;"finalmask 需要显式配置对应的客户端 finalmask") |
    req($server_flow!="xtls-rprx-vision" or $user.encryption!="none" or
      ($ss.network=="raw" and ($ss.security|IN("tls","reality")));"Vision 需要 RAW+TLS/Reality，或配对启用 VLESS Encryption") |
    if $ss.security=="reality" then
      req(($ss.network|IN("raw","xhttp","grpc"));"Reality 仅支持 RAW、XHTTP、gRPC") |
      req(($cs.realitySettings.privateKey==null and $cs.realitySettings.mldsa65Seed==null and
           $cs.realitySettings.target==null and $cs.realitySettings.dest==null and $cs.realitySettings.serverNames==null and $cs.realitySettings.shortIds==null);
          "客户端 Reality 不能包含服务端私钥、目标或列表字段") |
      req(($cs.realitySettings.password // $cs.realitySettings.publicKey // "")==$public;"Reality 客户端公钥与服务端私钥不匹配") |
      req(any($ss.realitySettings.serverNames[]?; ascii_downcase==($cs.realitySettings.serverName // ""|ascii_downcase));"Reality 客户端 SNI 不在服务端 serverNames 中") |
      req(any($ss.realitySettings.shortIds[]?; ascii_downcase==($cs.realitySettings.shortId // ""|ascii_downcase));"Reality 客户端 shortId 不在服务端 shortIds 中") |
      req($verify=="" or ($cs.realitySettings.mldsa65Verify // "")==$verify;"Reality 后量子验证公钥不匹配")
    elif $ss.security=="tls" then
      req(($cs.tlsSettings.echServerKeys==null);"客户端不能包含 TLS ECH 服务端密钥") |
      req(($ss.tlsSettings.echServerKeys // "")=="" or ($cs.tlsSettings.echConfigList // "")!="";"ECH 已启用，请配置配套客户端 echConfigList") |
      req(($ss.tlsSettings.alpn // []|length)==0 or ($cs.tlsSettings.alpn // []|length)==0 or
          any($cs.tlsSettings.alpn[]; . as $p | any($ss.tlsSettings.alpn[]; .==$p));"服务端和客户端 TLS ALPN 没有共同协议") |
      req($server_flow!="xtls-rprx-vision" or $user.encryption!="none" or ($ss.tlsSettings.maxVersion // "1.3")=="1.3";"Vision 不能使用低于 TLS 1.3 的外层连接")
    elif $ss.security=="none" then . else fail("不支持的 VLESS security") end |
    if $ss.network=="ws" then
      req(path($ss.wsSettings.path)==path($cs.wsSettings.path);"WebSocket 路径不一致") |
      req(host($ss.wsSettings)=="" or host($ss.wsSettings)==host($cs.wsSettings);"WebSocket Host 不一致")
    elif $ss.network=="httpupgrade" then
      req(path($ss.httpupgradeSettings.path)==path($cs.httpupgradeSettings.path);"HTTPUpgrade 路径不一致") |
      req(host($ss.httpupgradeSettings)=="" or host($ss.httpupgradeSettings)==host($cs.httpupgradeSettings);"HTTPUpgrade Host 不一致")
    elif $ss.network=="grpc" then
      req(($ss.grpcSettings.serviceName // "")==($cs.grpcSettings.serviceName // "");"gRPC serviceName 不一致") |
      req(($ss.grpcSettings.multiMode // false)==($cs.grpcSettings.multiMode // false);"gRPC multiMode 不一致")
    elif $ss.network=="xhttp" then
      req(path($ss.xhttpSettings.path)==path($cs.xhttpSettings.path);"XHTTP 路径不一致") |
      req(host($ss.xhttpSettings)=="" or host($ss.xhttpSettings)==host($cs.xhttpSettings);"XHTTP Host 不一致") |
      req(($ss.xhttpSettings.mode // "auto"|IN("","auto")) or ($ss.xhttpSettings.mode // "auto")==($cs.xhttpSettings.mode // "auto");"XHTTP mode 不兼容") |
      req(($ss.tlsSettings.alpn==["h3"])==($cs.tlsSettings.alpn==["h3"]);"XHTTP H3 的 TCP/UDP 选择不一致")
    elif $ss.network=="kcp" then
      req(($ss.kcpSettings.seed // "")==($cs.kcpSettings.seed // "");"mKCP seed 不一致") |
      req(($ss.kcpSettings.header.type // "none")==($cs.kcpSettings.header.type // "none");"mKCP header 不一致")
    elif $ss.network=="hysteria" then
      req($ss.security=="tls";"Hysteria 传输需要 TLS") |
      req(($ss.hysteriaSettings.auth // "")!="" and $ss.hysteriaSettings.auth==$cs.hysteriaSettings.auth;"Hysteria 传输需要配对 auth")
    elif $ss.network=="xdrive" then
      req($server_flow=="" and $user.encryption!="none";"XDrive 需要 VLESS Encryption 且 flow 为空") |
      req(($cs.xdriveSettings // {}|length)>0;"XDrive 客户端需要显式提供 xdriveSettings，避免自动公开服务端云凭据") |
      req($user.reverse!=null or ($client.mux.enabled==true and ($client.mux.concurrency // 0)>=0 and ($client.mux.xudpConcurrency // 0)>=0 and ($client.mux.xudpProxyUDP443 // "")!="skip");"XDrive 客户端需要启用 Mux")
    elif $ss.network=="raw" then
      req(($ss.rawSettings.header.type // "none")==($cs.rawSettings.header.type // "none");"RAW header 类型不一致")
    else fail("不支持的 VLESS network") end |
    if ($ss.network|IN("ws","httpupgrade")) and $ss.security=="tls" then
      req(($ss.tlsSettings.alpn // ["http/1.1"] | index("http/1.1"))!=null and
          ($cs.tlsSettings.alpn // ["http/1.1"] | index("http/1.1"))!=null;"WebSocket/HTTPUpgrade 需要 http/1.1 ALPN")
    elif $ss.network=="grpc" and $ss.security=="tls" then
      req(($ss.tlsSettings.alpn // ["h2"] | index("h2"))!=null and
          ($cs.tlsSettings.alpn // ["h2"] | index("h2"))!=null;"gRPC 需要 h2 ALPN")
    else . end
  ' <<<"$outbound" >/dev/null
}

vless_xray_client_outbound() {
  local node=$1 credential=$2 secret=$3 inbound stream override settings user_extra encryption decryption public='' verify='' network security flow client
  inbound=$(xray_inbound_for_node "$node" "$(jq -cn --argjson user "$credential" '[$user]')" "$secret") || return 1
  stream=$(vless_stream_normalize "$(jq -c '.streamSettings' <<<"$inbound")") || return 1
  inbound=$(jq --argjson stream "$stream" '.streamSettings=$stream' <<<"$inbound") || return 1
  network=$(jq -r '.network' <<<"$stream"); security=$(jq -r '.security' <<<"$stream")
  override=$(vless_outbound_override_normalize "$(jq -c '.xray.outbound // {}' <<<"$node")") || return 1
  user_extra=$(jq -c '.settings.vnext[0].users[0] // {}' <<<"$override") || return 1
  decryption=$(jq -r '.settings.decryption // "none"' <<<"$inbound") || return 1
  encryption=$(jq -r '.encryption // empty' <<<"$user_extra") || return 1
  [[ -n "$encryption" ]] || encryption=$(vless_encryption_public "$decryption") || return 1
  vless_encryption_pair_check "$decryption" "$encryption" || return 1
  flow=$(jq -r '(.settings.clients[0].flow // "") as $user | if $user=="" then (.settings.flow // "") else $user end' <<<"$inbound") || return 1
  if [[ "$security" == reality ]]; then
    public=$(vless_x25519_public "$(jq -r '.realitySettings.privateKey // ""' <<<"$stream")") || return 1
    if [[ $(jq -r '.realitySettings.mldsa65Seed // ""' <<<"$stream") != "" ]]; then
      verify=$(vless_pq_public mldsa65 "$(jq -r '.realitySettings.mldsa65Seed' <<<"$stream")") || return 1
    fi
  fi
  client=$(jq -n --argjson node "$node" --argjson user "$credential" --argjson ss "$stream" --arg flow "$flow" --arg encryption "$encryption" --arg public "$public" --arg verify "$verify" '
    ($ss | del(.sockopt,.tlsSettings,.realitySettings,.finalmask,.address,.port,.xdriveSettings)
      | if .rawSettings!=null then .rawSettings |= del(.acceptProxyProtocol,.header.response) else . end
      | if .wsSettings!=null then .wsSettings |= del(.acceptProxyProtocol) else . end
      | if .httpupgradeSettings!=null then .httpupgradeSettings |= del(.acceptProxyProtocol) else . end
      | if .hysteriaSettings!=null then .hysteriaSettings |= del(.masquerade) else . end) as $stream |
    {tag:("proxy-"+$node.id),protocol:"vless",settings:{vnext:[{address:$node.server_address,port:$node.port,users:[{id:$user.uuid,encryption:$encryption,flow:$flow}]}]},streamSettings:$stream}
    | if $ss.security=="tls" then
        .streamSettings.tlsSettings={serverName:($ss.tlsSettings.serverName // $node.domain),fingerprint:"chrome"}
        | if $ss.tlsSettings.alpn!=null then .streamSettings.tlsSettings.alpn=$ss.tlsSettings.alpn else . end
        | if ($ss.network|IN("ws","httpupgrade")) then .streamSettings.tlsSettings.alpn=["http/1.1"]
          elif $ss.network=="grpc" then .streamSettings.tlsSettings.alpn=["h2"] else . end
      elif $ss.security=="reality" then
        .streamSettings.realitySettings={serverName:($ss.realitySettings.serverNames[0] // $node.domain),fingerprint:"chrome",password:$public,shortId:($ss.realitySettings.shortIds[0] // ""),spiderX:"/"}
        | if $verify!="" then .streamSettings.realitySettings.mldsa65Verify=$verify else . end
      else . end
  ') || return 1
  settings=$(jq -c '.settings' <<<"$client") || return 1
  client=$(jq --argjson override "$override" --argjson settings "$settings" --argjson extras "$user_extra" '
    . as $base | . * ($override|del(.settings,.protocol,.tag))
    | .settings=$settings
    | .settings.vnext[0].users[0] += ($extras | del(.id,.email,.level))
    | .settings.vnext[0].users[0].id=$base.settings.vnext[0].users[0].id
    | .tag=$base.tag | .protocol="vless"
  ' <<<"$client") || return 1
  stream=$(vless_stream_normalize "$(jq -c '.streamSettings' <<<"$client")") || return 1
  # Accept the legacy publicKey alias, then emit upstream's current name.
  stream=$(jq 'if .security=="reality" then
      if (.realitySettings.publicKey // "")!="" and (.realitySettings.password // "")=="" then .realitySettings.password=.realitySettings.publicKey else . end
      | del(.realitySettings.publicKey)
    elif .security=="tls" then
      if (.tlsSettings.allowInsecure // false)==true then error("Xray 已移除 allowInsecure；自签证书请使用 pinnedPeerCertSha256") else .tlsSettings |= del(.allowInsecure) end
    else . end' <<<"$stream") || return 1
  client=$(jq --argjson stream "$stream" '.streamSettings=$stream' <<<"$client") || return 1
  vless_profile_pair_check "$inbound" "$client" "$public" "$verify" || return 1
  # Upstream supports reverse only in the current simplified VLESS shape.
  jq 'if .settings.vnext[0].users[0].reverse!=null then
      .settings.vnext[0] as $endpoint | .settings=($endpoint.users[0]+{address:$endpoint.address,port:$endpoint.port})
    else . end' <<<"$client"
}

vless_profile_validate() (
  local node=$1 secret=$2 state=${3:-$SBM_STATE} credential outbound tmp log id
  [[ $(jq -r '.protocol' <<<"$node") == vless ]] || return 0
  id=$(jq -r '.id' <<<"$node") || return 1
  credential=$(node_enabled_credentials "$node" | jq -c '.[0] // empty') || return 1
  if [[ -z "$credential" ]]; then
    id=$(jq -r '.users[0].id // empty' <<<"$node") || return 1
    [[ -n "$id" ]] || { log_error 'VLESS 节点缺少用户。'; return 1; }
    credential=$(state_get_user_secret "$(jq -r '.id' <<<"$node")" "$id") || return 1
  fi
  outbound=$(vless_xray_client_outbound "$node" "$credential" "$secret") || return 1
  if [[ -x "$SBM_XRAY_BIN" && $(jq -r '.settings.vless_engine // "xray"' "$state") == xray ]]; then
    tmp=$(mktemp "$SBM_RUN/vless-client.XXXXXX") || return 1
    log=$(mktemp "$SBM_RUN/vless-client-check.XXXXXX.log") || { rm -f "$tmp"; return 1; }
    trap 'rm -f -- "$tmp" "$log"' EXIT
    jq -n --argjson outbound "$outbound" '{log:{loglevel:"none"},outbounds:[$outbound]}' >"$tmp" || return 1
    xray_test_config "$SBM_XRAY_BIN" "$tmp" "$log" || {
      log_error "VLESS 客户端参数不被当前 Xray 接受：$(grep -m1 -E 'Failed|failed|error' "$log" | cut -c1-300)"; return 1;
    }
  fi
)
