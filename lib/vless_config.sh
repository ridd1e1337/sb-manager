#!/usr/bin/env bash
# shellcheck shell=bash

# Structured fields are a view over the native Xray objects. Keeping one
# source of truth lets server generation and every export resolve the same
# final stream settings, including JSON imported from other managers.
vless_config_apply() {
  local node=$1 key value network settings_key security client_security old_network old_security flow json
  shift
  local -A options=()
  [[ $(jq -r '.protocol' <<<"$node") == vless ]] || { log_error '这些参数仅用于 VLESS。'; return 1; }
  while (($#)); do
    (($# >= 2)) || { log_error "缺少参数值：$1"; return 1; }
    key=$1; value=$2; shift 2
    case "$key" in
      --xray-inbound-json|--xray-outbound-json|--transport-json|--tls-json|--sockopt-json)
        value=$(node_json_argument "$value") || return 1
        node_validate_json_object "$key" "$value" || return 1;;
      --transport|--security|--flow|--path|--host|--service-name|--xhttp-mode|--tls-server-name|--fingerprint|--alpn|--allow-insecure|--pinned-cert-sha256|--verify-name|--packet-encoding|--vless-encryption|--vless-decryption|--handshake-server|--handshake-port|--domain|--address|--name|--port|--listen|--frontend-address|--frontend-port|--frontend-sni|--fallbacks|--fallback-dest|--sniffing|--sniff-dest|--tcp-fast-open|--accept-proxy-protocol) ;;
      *) log_error "未知 VLESS 参数：$key"; return 1;;
    esac
    options[$key]=$value
  done
  old_network=$(vless_node_network "$node") || return 1
  old_security=$(jq -r '.xray.inbound.streamSettings.security // .security // "none"' <<<"$node") || return 1
  for key in --xray-inbound-json --xray-outbound-json; do
    if [[ -v options[$key] ]]; then
      value=${key#--xray-}; value=${value%-json}
      node=$(jq --arg direction "$value" --argjson object "${options[$key]}" '.xray[$direction]=$object' <<<"$node") || return 1
    fi
  done
  network=$(vless_network_normalize "${options[--transport]:-$(vless_node_network "$node")}") || return 1
  security=${options[--security]:-$(jq -r '.xray.inbound.streamSettings.security // .security // "none"' <<<"$node")}
  case "$security" in none|tls|reality) ;; *) log_error 'VLESS 安全层只能是 none、tls 或 reality。'; return 1;; esac
  if [[ -v options[--frontend-address] ]]; then
    value=${options[--frontend-address]}
    if [[ -z "$value" ]]; then node=$(jq 'del(.xray.frontend)' <<<"$node") || return 1
    else
      validate_address "$value" || return 1
      node=$(jq --arg address "$value" '.xray.frontend=(.xray.frontend // {})+{address:$address,security:"tls"} | .xray.frontend.port //= 443' <<<"$node") || return 1
    fi
  fi
  if [[ -v options[--frontend-port] ]]; then
    value=${options[--frontend-port]}; validate_port "$value" || return 1
    node=$(jq --argjson port "$((10#$value))" '.xray.frontend.port=$port | .xray.frontend.security="tls"' <<<"$node") || return 1
  fi
  if [[ -v options[--frontend-sni] ]]; then
    node=$(jq --arg sni "${options[--frontend-sni]}" '.xray.frontend.server_name=$sni' <<<"$node") || return 1
  fi
  client_security=$security
  if jq -e '.xray.frontend != null' <<<"$node" >/dev/null; then client_security=tls; fi
  case "$network" in
    raw) settings_key=rawSettings;; ws) settings_key=wsSettings;; grpc) settings_key=grpcSettings;;
    httpupgrade) settings_key=httpupgradeSettings;; xhttp) settings_key=xhttpSettings;;
    kcp) settings_key=kcpSettings;; hysteria) settings_key=hysteriaSettings;; xdrive) settings_key=xdriveSettings;;
    *) log_error "当前 VLESS 不支持此传输：$network"; return 1;;
  esac
  if [[ -v options[--transport] ]]; then
    node=$(jq --arg network "$network" --arg keep "$settings_key" '
      def clean: with_entries(select((.key|IN("rawSettings","tcpSettings","wsSettings","grpcSettings","httpupgradeSettings","xhttpSettings","splithttpSettings","kcpSettings","hysteriaSettings","xdriveSettings"))|not));
      .xray.inbound.streamSettings=(.xray.inbound.streamSettings // {}) |
      .xray.outbound.streamSettings=(.xray.outbound.streamSettings // {}) |
      .xray.inbound.streamSettings |= ((.[$keep] // null) as $saved | clean | .network=$network | if $saved==null then . else .[$keep]=$saved end) |
      .xray.outbound.streamSettings |= ((.[$keep] // null) as $saved | clean | .network=$network | if $saved==null then . else .[$keep]=$saved end)
    ' <<<"$node") || return 1
  fi
  if [[ -v options[--security] ]]; then
    node=$(jq --arg security "$security" --arg client_security "$client_security" '
      .security=$security |
      .xray.inbound.streamSettings.security=$security |
      .xray.outbound.streamSettings.security=$client_security |
      if $security!="tls" then del(.xray.inbound.streamSettings.tlsSettings) else . end |
      if $security!="reality" then del(.xray.inbound.streamSettings.realitySettings) else . end |
      if $client_security!="tls" then del(.xray.outbound.streamSettings.tlsSettings) else . end |
      if $client_security!="reality" then del(.xray.outbound.streamSettings.realitySettings) else . end
    ' <<<"$node") || return 1
  else node=$(jq --arg security "$security" '.security=$security' <<<"$node") || return 1; fi
  if [[ -v options[--transport-json] ]]; then
    node=$(jq --arg key "$settings_key" --argjson settings "${options[--transport-json]}" '.xray.inbound.streamSettings[$key]=$settings' <<<"$node") || return 1
  fi
  for key in --path --host --service-name --xhttp-mode; do
    [[ -v options[$key] ]] || continue
    value=${options[$key]}
    case "$key:$network" in
      --path:ws|--path:httpupgrade|--path:xhttp)
        [[ -n "$value" ]] || value=/
        [[ "$value" == /* ]] || value="/$value"
        node=$(jq --arg key "$settings_key" --arg value "$value" '.xray.inbound.streamSettings[$key].path=$value | .xray.outbound.streamSettings[$key].path=$value' <<<"$node") || return 1;;
      --host:ws)
        node=$(jq --arg value "$value" 'if $value=="" then del(.xray.inbound.streamSettings.wsSettings.host,.xray.inbound.streamSettings.wsSettings.headers.Host,.xray.outbound.streamSettings.wsSettings.host,.xray.outbound.streamSettings.wsSettings.headers.Host) else .xray.inbound.streamSettings.wsSettings.host=$value | .xray.outbound.streamSettings.wsSettings.host=$value end' <<<"$node") || return 1;;
      --host:httpupgrade|--host:xhttp)
        node=$(jq --arg key "$settings_key" --arg value "$value" '.xray.inbound.streamSettings[$key].host=$value | .xray.outbound.streamSettings[$key].host=$value' <<<"$node") || return 1;;
      --service-name:grpc)
        node=$(jq --arg value "$value" '.xray.inbound.streamSettings.grpcSettings.serviceName=$value | .xray.outbound.streamSettings.grpcSettings.serviceName=$value' <<<"$node") || return 1;;
      --xhttp-mode:xhttp)
        case "$value" in auto|packet-up|stream-up|stream-one) ;; *) log_error '无效 XHTTP mode。'; return 1;; esac
        node=$(jq --arg value "$value" '.xray.inbound.streamSettings.xhttpSettings.mode=$value | .xray.outbound.streamSettings.xhttpSettings.mode=$value' <<<"$node") || return 1;;
      --host:raw|--path:raw)
        node=$(jq --arg key "${key#--}" --arg value "$value" '
          .xray.inbound.streamSettings.rawSettings.header.type="http" |
          .xray.outbound.streamSettings.rawSettings.header.type="http" |
          if $key=="host" then
            .xray.inbound.streamSettings.rawSettings.header.request.headers.Host=[$value] |
            .xray.outbound.streamSettings.rawSettings.header.request.headers.Host=[$value]
          else
            .xray.inbound.streamSettings.rawSettings.header.request.path=[$value] |
            .xray.outbound.streamSettings.rawSettings.header.request.path=[$value]
          end' <<<"$node") || return 1;;
      *) [[ -z "$value" ]] || { log_error "$key 不适用于 $network。"; return 1; };;
    esac
  done
  if [[ -v options[--tls-json] ]]; then
    [[ "$security" != none ]] || { log_error 'none 安全层不能设置 TLS 参数。'; return 1; }
    node=$(jq --arg key "${security}Settings" --argjson object "${options[--tls-json]}" '.xray.inbound.streamSettings[$key]=$object' <<<"$node") || return 1
  fi
  for key in --tls-server-name --fingerprint --alpn --allow-insecure --pinned-cert-sha256 --verify-name; do
    [[ -v options[$key] ]] || continue
    value=${options[$key]}
    if [[ "$client_security" == none ]]; then
      [[ -z "$value" || "$value" == false ]] || { log_error "$key 需要 TLS 或 Reality。"; return 1; }
      continue
    fi
    case "$key" in
      --tls-server-name|--fingerprint)
        if [[ "$key" == --tls-server-name ]]; then json=serverName; else json=fingerprint; fi
        node=$(jq --arg key "${client_security}Settings" --arg field "$json" --arg value "$value" 'if $value=="" then del(.xray.outbound.streamSettings[$key][$field]) else .xray.outbound.streamSettings[$key][$field]=$value end' <<<"$node") || return 1;;
      --alpn)
        [[ "$client_security" == tls ]] || { [[ -z "$value" ]] && continue; log_error 'Reality ALPN 由握手目标提供，不能当作 TLS ALPN 设置。'; return 1; }
        node=$(jq --arg value "$value" --arg security "$security" '($value|split(",")|map(gsub("^ +| +$"; ""))|map(select(length>0))) as $alpn | if ($alpn|length)==0 then del(.xray.inbound.streamSettings.tlsSettings.alpn,.xray.outbound.streamSettings.tlsSettings.alpn) else .xray.outbound.streamSettings.tlsSettings.alpn=$alpn | if $security=="tls" then .xray.inbound.streamSettings.tlsSettings.alpn=$alpn else . end end' <<<"$node") || return 1;;
      --allow-insecure)
        # Upstream removed allowInsecure; self-signed servers are pinned instead.
        [[ "$value" == false || -z "$value" ]] || { log_error 'Xray 已移除 allowInsecure；自签证书请使用 --pinned-cert-sha256。'; return 1; }
        node=$(jq 'del(.xray.outbound.streamSettings.tlsSettings.allowInsecure)' <<<"$node") || return 1;;
      --pinned-cert-sha256|--verify-name)
        [[ "$client_security" == tls ]] || { [[ -z "$value" ]] && continue; log_error "$key 仅用于 TLS。"; return 1; }
        if [[ "$key" == --pinned-cert-sha256 ]]; then
          json=pinnedPeerCertSha256
          value=${value//:/}; value=${value,,}; value=${value// /}
          [[ -z "$value" || "$value" =~ ^[0-9a-f]{64}(,[0-9a-f]{64})*$ ]] || { log_error '证书指纹须为 SHA-256 十六进制，多个用逗号分隔。'; return 1; }
        else
          json=verifyPeerCertByName
          [[ -z "$value" || "$value" =~ ^[A-Za-z0-9.*-]+(,[A-Za-z0-9.*-]+)*$ ]] || { log_error '证书校验名称格式无效。'; return 1; }
        fi
        node=$(jq --arg field "$json" --arg value "$value" 'if $value=="" then del(.xray.outbound.streamSettings.tlsSettings[$field]) else .xray.outbound.streamSettings.tlsSettings[$field]=$value end' <<<"$node") || return 1;;
    esac
  done
  for key in --vless-encryption --vless-decryption; do
    [[ -v options[$key] ]] || continue
    value=${options[$key]}; value=${value:-none}
    if [[ "$key" == --vless-encryption ]]; then
      node=$(jq --arg value "$value" '.xray.outbound.settings.vnext[0].users[0].encryption=$value' <<<"$node") || return 1
    else node=$(jq --arg value "$value" '.xray.inbound.settings.decryption=$value' <<<"$node") || return 1; fi
  done
  if [[ -v options[--packet-encoding] ]]; then
    case "${options[--packet-encoding]}" in xudp|packetaddr|none) ;; *) log_error 'packet-encoding 只能是 xudp、packetaddr 或 none。'; return 1;; esac
    node=$(jq --arg value "${options[--packet-encoding]}" '.xray.packet_encoding=$value' <<<"$node") || return 1
  fi
  for key in --domain --address --name --handshake-server --handshake-port --port --listen; do
    [[ -v options[$key] ]] || continue
    value=${options[$key]}
    case "$key" in
      --port|--handshake-port)
        validate_port "$value" || { log_error "无效端口：$value"; return 1; }
        node=$(jq --arg key "${key#--}" --argjson value "$((10#$value))" '.[($key|gsub("-";"_"))]=$value' <<<"$node") || return 1;;
      --address)
        validate_address "$value" || return 1
        node=$(jq --arg value "$value" '.server_address=$value | .server_address_source="manual"' <<<"$node") || return 1;;
      --listen)
        validate_ipv4 "$value" || validate_ipv6 "$value" || { log_error 'VLESS 监听地址必须是 IP。'; return 1; }
        node=$(jq --arg value "$value" '.listen=$value' <<<"$node") || return 1;;
      *) node=$(jq --arg key "${key#--}" --arg value "$value" '.[($key|gsub("-";"_"))]=$value' <<<"$node") || return 1;;
    esac
  done
  if [[ -v options[--sockopt-json] ]]; then
    node=$(jq --argjson value "${options[--sockopt-json]}" 'if $value=={} then del(.xray.inbound.streamSettings.sockopt) else .xray.inbound.streamSettings.sockopt=$value end' <<<"$node") || return 1
  fi
  for key in --tcp-fast-open --accept-proxy-protocol; do
    [[ -v options[$key] ]] || continue
    value=${options[$key]}
    [[ "$value" == true || "$value" == false ]] || { log_error "$key 只能是 true 或 false。"; return 1; }
    if [[ "$key" == --tcp-fast-open ]]; then json=tcpFastOpen; else json=acceptProxyProtocol; fi
    node=$(jq --arg field "$json" --argjson value "$value" '
      if $value then .xray.inbound.streamSettings.sockopt[$field]=true
      else del(.xray.inbound.streamSettings.sockopt[$field]) end
      | if (.xray.inbound.streamSettings.sockopt // null)=={} then del(.xray.inbound.streamSettings.sockopt) else . end' <<<"$node") || return 1
  done
  if [[ -v options[--sniffing] ]]; then
    case "${options[--sniffing]}" in
      off) node=$(jq 'del(.xray.inbound.sniffing)' <<<"$node") || return 1;;
      on|route-only)
        node=$(jq --argjson route "$([[ ${options[--sniffing]} == route-only ]] && echo true || echo false)" '
          .xray.inbound.sniffing=((.xray.inbound.sniffing // {}) + {enabled:true,routeOnly:$route})
          | .xray.inbound.sniffing.destOverride //= ["http","tls","quic"]' <<<"$node") || return 1;;
      *) log_error 'sniffing 只能是 on、route-only 或 off。'; return 1;;
    esac
  fi
  if [[ -v options[--sniff-dest] ]]; then
    value=${options[--sniff-dest]// /}
    [[ "$value" =~ ^(http|tls|quic|fakedns)(,(http|tls|quic|fakedns))*$ ]] || { log_error 'sniff-dest 只能组合 http、tls、quic、fakedns。'; return 1; }
    node=$(jq --arg value "$value" '.xray.inbound.sniffing=((.xray.inbound.sniffing // {enabled:true}) + {destOverride:($value|split(",")|unique)})' <<<"$node") || return 1
  fi
  if [[ -v options[--fallback-dest] ]]; then
    value=${options[--fallback-dest]}
    if [[ -z "$value" || "$value" == none ]]; then options[--fallbacks]='[]'
    else options[--fallbacks]=$(jq -cn --arg dest "$value" '[{dest:(if $dest|test("^[0-9]+$") then ($dest|tonumber) else $dest end)}]') || return 1; fi
  fi
  if [[ -v options[--fallbacks] ]]; then
    value=${options[--fallbacks]}
    [[ "$value" != none ]] || value='[]'
    value=$(node_json_argument "$value") || return 1
    vless_fallbacks_validate "$value" || return 1
    node=$(jq --argjson value "$value" 'if ($value|length)==0 then del(.xray.inbound.settings.fallbacks) else .xray.inbound.settings.fallbacks=$value end' <<<"$node") || return 1
  fi
  # Explicit empty flow is meaningful. Re-select the safe default when the
  # operator changes transport/security but did not prescribe a flow.
  flow=$(jq -r '.flow // ""' <<<"$node") || return 1
  if [[ -v options[--flow] ]]; then flow=${options[--flow]}
  elif [[ "$network" != "$old_network" || "$security" != "$old_security" ]]; then flow=auto; fi
  if [[ "$flow" == auto ]]; then
    if [[ "$network" == raw && "$security" != none ]]; then flow=xtls-rprx-vision; else flow=''; fi
  fi
  case "$flow" in ''|xtls-rprx-vision) ;; *) log_error 'flow 只能为空或 xtls-rprx-vision。'; return 1;; esac
  node=$(jq --arg flow "$flow" '.flow=(if $flow=="" then null else $flow end)' <<<"$node") || return 1
  vless_server_options_check "$node" || return 1
  printf '%s\n' "$node"
}

vless_fallbacks_validate() {
  jq -e '
    type=="array" and length<=32 and all(.[];
      type=="object" and (keys - ["name","alpn","path","dest","xver"] | length)==0
      and (.dest|type=="number" and floor==. and .>=1 and .<=65535 or (type=="string" and length>0 and length<=256))
      and ((.name // "")|type=="string") and ((.alpn // "")|IN("","h2","http/1.1"))
      and ((.path // "")|type=="string" and (.=="" or startswith("/")))
      and ((.xver // 0)|IN(0,1,2)))
  ' <<<"$1" >/dev/null || { log_error '回落须为数组，每项只含 name/alpn/path/dest/xver，dest 必填，path 以 / 开头，xver 为 0-2。'; return 1; }
}

# Server-only options are checked against the effective inbound because
# imported native JSON can enable them without the structured flags.
vless_server_options_check() {
  local node=$1 network security
  network=$(vless_node_network "$node") || return 1
  security=$(jq -r '.xray.inbound.streamSettings.security // .security // "none"' <<<"$node") || return 1
  if jq -e '(.xray.inbound.settings.fallbacks // [])|length>0' <<<"$node" >/dev/null; then
    [[ "$network" == raw && "$security" == tls ]] || { log_error 'Xray 回落仅支持 RAW + TLS；Reality 请使用目标网站。'; return 1; }
    vless_fallbacks_validate "$(jq -c '.xray.inbound.settings.fallbacks' <<<"$node")" || return 1
  fi
  jq -e '(.xray.inbound.sniffing // {}) | type=="object" and ((.destOverride // [])|all(.[]; IN("http","tls","quic","fakedns")))' <<<"$node" >/dev/null || {
    log_error 'sniffing.destOverride 只能包含 http、tls、quic、fakedns。'; return 1;
  }
}

_node_vless_configure() {
  local id=$1 node previous candidate secret domain security kind port old_kind old_port
  shift
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || { log_error 'VLESS 参数变更不接受 --dry-run。'; return 1; }
  previous=$(state_get_node "$id") || return 1
  [[ -n "$previous" && $(jq -r '.protocol' <<<"$previous") == vless ]] || { log_error '请选择 VLESS 节点。'; return 1; }
  node=$(vless_config_apply "$previous" "$@") || return 1
  domain=$(jq -r '.domain // ""' <<<"$node"); security=$(jq -r '.security' <<<"$node")
  if [[ "$security" != none ]]; then validate_domain "$domain" || { log_error 'TLS/Reality 需要有效域名。'; return 1; }; fi
  if [[ $(jq -r '.settings.vless_engine // "sing-box"' "$SBM_STATE") != xray ]]; then
    log_error '请先运行 sb xray enable，把 VLESS 接入 Xray 后再设置 Xray 参数。'; return 1
  fi
  [[ -x "$SBM_XRAY_BIN" ]] || _xray_install || return 1
  if [[ "$security" == reality ]]; then
    secret='{}'; [[ ! -r "$(state_secret_path "$id")" ]] || secret=$(state_get_secret "$id") || return 1
    if [[ $(jq -r '.reality_private_key // ""' <<<"$secret") == '' ]] && ! jq -e '.xray.inbound.streamSettings.realitySettings.privateKey' <<<"$node" >/dev/null; then
      secret=$(protocol_vless_generate_reality_secret xray) || return 1
      state_write_secret "$id" "$secret" || return 1
    fi
  fi
  if [[ "$security" == tls && $(jq -r '.enabled' <<<"$node") == true ]] && ! jq -e '(.xray.inbound.streamSettings.tlsSettings.certificates // [])|length>0' <<<"$node" >/dev/null; then
    _cert_prepare_node_domain "$domain" || return 1
  fi
  old_kind=$(node_transport_kinds "$previous"); kind=$(node_transport_kinds "$node")
  old_port=$(jq -r '.port' <<<"$previous"); port=$(jq -r '.port' <<<"$node")
  if [[ $(jq -r '.enabled' <<<"$node") == true && ( "$kind" != "$old_kind" || "$port" != "$old_port" ) ]]; then
    while IFS= read -r kind; do
      [[ -n "$kind" ]] || continue
      host_port_in_use "$kind" "$port" && { log_error '新监听端口已被使用。'; return 1; }
    done < <(node_transport_kinds "$node")
  fi
  candidate=$(state_candidate) || return 1
  jq --arg id "$id" --argjson node "$node" '(.nodes[]|select(.id==$id))=$node' "$SBM_STATE" >"$candidate" || { rm -f "$candidate"; return 1; }
  state_normalize_v2_file "$candidate" || { rm -f "$candidate"; return 1; }
  apply_candidate_state "$candidate" vless-configure || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
  log_ok "VLESS 参数已更新：$id"
}

node_vless_configure() {
  require_root
  with_state_transaction vless-configure _node_vless_configure "$@"
}
