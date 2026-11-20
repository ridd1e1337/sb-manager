#!/usr/bin/env bash
# shellcheck shell=bash

node_transport_kinds() {
  local node=$1 protocol network
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf|anytls|trojan|shadowtls|snell|http|socks|mixed) printf 'tcp\n' ;;
    vless) printf 'tcp\n' ;;
    hysteria2|tuic) printf 'udp\n' ;;
    naive) jq -r '.network // "tcp"' <<<"$node" ;;
    shadowsocks)
      network=$(jq -r '.network // "tcp"' <<<"$node")
      case "$network" in tcp) printf 'tcp\n';; udp) printf 'udp\n';; *) printf 'tcp\nudp\n';; esac
      ;;
    *) return 1 ;;
  esac
}

# Return the user-supplied sing-box extension for a node.  The extension is
# intentionally kept as JSON so new sing-box fields can be used before the
# manager has a dedicated flag for them.
singbox_node_override() {
  local node=$1 direction=$2
  jq -c --arg direction "$direction" '
    if ((.singbox // {}) | type) == "object"
       and ((.singbox[$direction] // {}) | type) == "object"
    then (.singbox[$direction] // {})
    else {}
    end
  ' <<<"$node"
}

# Apply an extension to a generated sing-box object.  ShadowTLS and other
# compound protocols render an array; by default the extension targets the
# primary object.  An optional `by_tag` map targets individual array members,
# which makes nested protocols fully extensible as well.
singbox_apply_override() {
  local rendered=$1 override=$2
  jq --argjson override "$override" '
    def safe_extension:
      del(.type, .tag, .listen, .listen_port, .server, .server_port,
          .users, .password, .uuid, .psk);
    if ($override | type) != "object" or ($override | length) == 0 then .
    elif type == "array" then
      . as $items
      | ($override.by_tag // {}) as $by_tag
      | ($override | del(.by_tag) | safe_extension) as $default
      | [ range(0; ($items | length)) as $i
          | $items[$i] as $item
          | if (($by_tag | type) == "object" and (($by_tag[$item.tag // ""] // null) | type == "object"))
            then $item * ($by_tag[$item.tag] | safe_extension)
            elif $i == 0 then $item * $default
            else $item
            end
        ]
    else . * ($override | del(.by_tag) | safe_extension)
    end
  ' <<<"$rendered"
}

validate_state_semantics() {
  local state=$1 ids count node id protocol port domain cert_dir kind key user_ids user_id enabled_users realm_url realm_domain realm_port realm_id
  state_validate "$state" || return 1
  if declare -F traffic_validate_state >/dev/null 2>&1; then
    traffic_validate_state "$state" || return 1
  fi
  if declare -F nginx_stream_validate_state >/dev/null 2>&1; then
    nginx_stream_validate_state "$state" || die 'TCP/SNI 复用状态无效。'
  fi
  ids=$(jq -r '.nodes[].id' "$state" | sort)
  count=$(printf '%s\n' "$ids" | sed '/^$/d' | uniq -d | wc -l)
  (( count == 0 )) || die "状态中存在重复节点 ID。"
  if [[ $(jq -r '.api.enabled // false' "$state") == true ]]; then
    version_ge "$(core_current_version)" 1.14.0-rc.1 || die 'sing-box API/Dashboard 需要 1.14+ 核心。'
    [[ -r "$(state_secret_path api)" ]] || die 'API secret 文件缺失。'
  fi
  if [[ $(jq -r '.realm.enabled // false' "$state") == true ]]; then
    version_ge "$(core_current_version)" 1.14.0-rc.1 || die 'Hysteria Realm 需要 sing-box 1.14.0-rc.1 或更高版本核心。'
    [[ -r "$SBM_REALM_SECRET" ]] || die 'Hysteria Realm secret 文件缺失。'
    realm_url=$(jq -r '.realm.public_url // ""' "$state")
    [[ "$realm_url" =~ ^https?://[^/[:space:]]+$ ]] || die "无效 Realm 公网 URL：$realm_url"
    realm_domain=$(jq -r '.realm.tls_domain // ""' "$state")
    if [[ -n "$realm_domain" ]]; then
      [[ -s "$SBM_CERTS/$realm_domain/fullchain.pem" && -s "$SBM_CERTS/$realm_domain/key.pem" ]] || die "Realm 缺少证书：$SBM_CERTS/$realm_domain/{fullchain.pem,key.pem}"
    fi
  fi

  # Per-node checks in one jq pass (per-node jq calls dominated latency).
  # Work items: E msg | A node addr | C node domain | U node user | S node | V gate msg
  local tag a b core_version=''
  while IFS=$'\t' read -r tag a b; do
    case "$tag" in
      E) die "$a";;
      A) validate_address "$b" || die "节点 $a 的客户端服务器地址无效或为空。";;
      C) validate_domain "$b" || die "节点 $a 的 TLS 域名无效：$b"
         [[ -s "$SBM_CERTS/$b/fullchain.pem" && -s "$SBM_CERTS/$b/key.pem" ]] || die "节点 $a 缺少证书：$SBM_CERTS/$b/{fullchain.pem,key.pem}";;
      U) [[ -r "$(state_user_secret_path "$a" "$b")" ]] || die "节点 $a 的用户 $b 缺少密钥文件。";;
      S) [[ -r "$(state_secret_path "$a")" ]] || die "节点 $a 缺少协议级密钥文件。";;
      V) [[ -n "$core_version" ]] || core_version=$(core_current_version || true)
         version_ge "$core_version" "$a" || die "$b";;
    esac
  done < <(jq -r '
    def kinds:
      if .protocol|IN("hysteria2","tuic") then ["udp"]
      elif .protocol=="naive" then [.network // "tcp"]
      elif .protocol=="shadowsocks" then ((.network // "tcp") | if .=="tcp" then ["tcp"] elif .=="udp" then ["udp"] else ["tcp","udp"] end)
      else ["tcp"] end;
    def tab: map(tostring) | join("\t");
    (.nginx_stream.enabled // false) as $mux | (.nginx_stream.routes // []) as $routes | . as $root |
    ( [ (if $mux then {key:"tcp:\(.nginx_stream.port)", owner:"TCP/SNI 复用入口", port:.nginx_stream.port, kind:"tcp"} else empty end),
        (.nodes[]? | select(.enabled==true) | . as $n | ([$routes[] | select(.node_id==$n.id)] | first) as $r |
          (if $mux and $r != null then $r.backend_port else $n.port end) as $port |
          kinds[] | {key:"\(.):\($port)", owner:$n.id, port:$port, kind:.}) ]
      | (group_by(.key)[] | select(length>1) | ["E","端口冲突：\(.[1].owner) 与 \(.[0].owner) 同时占用 \(.[1].port)/\(.[1].kind|ascii_upcase)。"] | tab),
        (if ($root.realm.enabled // false) then (map(select(.key=="tcp:\($root.realm.port)")) | first) as $c
           | if $c then ["E","Realm 端口冲突：\($c.owner) 已占用 \($root.realm.port)/TCP。"] | tab else empty end else empty end) ),
    ( [.nodes[]? | select(.enabled==true and .protocol=="hysteria2" and (.realm_enabled // false))] | group_by(.realm_id // "")[] | select(length>1)
      | ["E","Realm ID 重复：\(.[0].realm_id)（节点 \(.[0].id) 与 \(.[1].id)）"] | tab ),
    ( .nodes[]? | . as $n |
      (if (.id|test("^[a-z0-9][a-z0-9._-]{0,47}$")|not) then ["E","节点 ID 不规范：\(.id)"]|tab else empty end),
      (if (.port|type)!="number" or .port<1 or .port>65535 then ["E","节点 \(.id) 的端口无效：\(.port)"]|tab else empty end),
      (if (.protocol|IN("vmess-ws-cf","shadowsocks","anytls","hysteria2","trojan","tuic","vless","naive","shadowtls","snell","socks","http","mixed")|not)
        then ["E","节点 \(.id) 使用未知协议：\(.protocol)"]|tab else empty end),
      ([.users[]?.id] | if length != (unique|length) then ["E","节点 \($n.id) 存在重复用户 ID。"]|tab else empty end),
      ( select(.enabled==true) |
        (if .protocol!="vmess-ws-cf" then ["A",.id,(.server_address // "")]|tab else empty end),
        (if .protocol=="snell" then ["V","1.14.0-rc.1","Snell 需要 sing-box 1.14.0-rc.1 或更高版本核心。"]|tab else empty end),
        (if .protocol=="snell" and ((.snell_version // 5)==6) then ["V","1.14.0-rc.2","Snell v6 需要 sing-box 1.14.0-rc.2 或更高版本核心。"]|tab else empty end),
        (if .protocol=="hysteria2" and ((.obfs.type // "")=="gecko" or (.disable_chrome_parrot // false) or ((.bbr_profile // "")!="") or (.brutal_debug // false))
          then ["V","1.14.0-rc.1","当前 Hysteria2 配置包含 1.14+ 功能，需要 sing-box 1.14.0-rc.1 或更高版本核心。"]|tab else empty end),
        (if .protocol=="hysteria2" and (.realm_enabled // false) then
           (if ($root.realm.enabled // false)|not then ["E","节点 \(.id) 启用了 Hysteria Realm，但全局 Realm 服务未启用。"]|tab else empty end),
           (if ((.realm_id // "")|test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")|not) then ["E","节点 \(.id) 的 Realm ID 无效：\(.realm_id // "")"]|tab else empty end)
         else empty end),
        (if ([.users[]? | select(.enabled==true)]|length)==0 and (all(.users[]?; .limits.suspended!=null or .enabled)|not)
          then ["E","启用节点 \(.id) 至少需要一个启用用户。"]|tab else empty end),
        (if (.protocol|IN("anytls","hysteria2","trojan","tuic","naive")) or (.protocol=="vless" and .security=="tls")
          then ["C",.id,(.domain // "")]|tab else empty end),
        (.users[]? | select(.enabled==true) | ["U",$n.id,.id]|tab),
        (if (.protocol|IN("hysteria2","snell","shadowtls")) or (.protocol=="vless" and .security=="reality") then ["S",.id]|tab else empty end),
        (if (.protocol|IN("snell","shadowtls")) and ((.credential_revision // 0)!=1)
          then ["E","节点 \(.id) 的安全凭据尚未迁移，请通过 sb 命令初始化状态。"]|tab else empty end) ) )
  ' "$state")
}

node_enabled_credentials() {
  local node=$1 node_id user user_id secret credentials='[]'
  node_id=$(jq -r '.id' <<<"$node")
  while IFS= read -r user; do
    user_id=$(jq -r '.id' <<<"$user")
    secret=$(state_get_user_secret "$node_id" "$user_id")
    credentials=$(jq -c --argjson user "$user" --argjson secret "$secret" '. + [$user + $secret]' <<<"$credentials")
  done < <(jq -c '.users[] | select(.enabled==true)' <<<"$node")
  printf '%s\n' "$credentials"
}

render_inbound_for_node() {
  local node=$1 credentials=$2 node_secret=${3:-'{}'} protocol rendered override
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) rendered=$(protocol_vmess_render "$node" "$credentials" "$node_secret") ;;
    shadowsocks) rendered=$(protocol_ss_render "$node" "$credentials" "$node_secret") ;;
    anytls) rendered=$(protocol_anytls_render "$node" "$credentials" "$node_secret") ;;
    hysteria2) rendered=$(protocol_hy2_render "$node" "$credentials" "$node_secret") ;;
    trojan) rendered=$(protocol_trojan_render "$node" "$credentials") ;;
    tuic) rendered=$(protocol_tuic_render "$node" "$credentials") ;;
    vless) rendered=$(protocol_vless_render "$node" "$credentials" "$node_secret") ;;
    socks|http|mixed) rendered=$(protocol_proxy_render "$node" "$credentials") ;;
    naive) rendered=$(protocol_naive_render "$node" "$credentials") ;;
    shadowtls) rendered=$(protocol_shadowtls_render "$node" "$credentials" "$node_secret") ;;
    snell) rendered=$(protocol_snell_render "$node" "$credentials" "$node_secret") ;;
    *) die "未知协议：$protocol" ;;
  esac
  override=$(singbox_node_override "$node" inbound)
  singbox_apply_override "$rendered" "$override"
}

# Content-addressed cache of rendered inbounds in a root-only runtime dir;
# any input change yields a new key, and entries are pruned after a day.
render_cache_dir() {
  local dir="$SBM_RUN/render-cache"
  [[ -d "$dir" ]] || { mkdir -p "$dir" && chmod 0700 "$dir"; } 2>/dev/null || return 1
  [[ -w "$dir" ]] || return 1
  printf '%s\n' "$dir"
}
render_cache_prune() {
  [[ -d "$SBM_RUN/render-cache" ]] || return 0
  find "$SBM_RUN/render-cache" -type f -mmin +1440 -delete 2>/dev/null || true
}

render_config_from_state() {
  local mux_config
  local state=$1 output=$2 node node_id credentials node_secret inbound inbounds='[]' log_level api_enabled api_secret api_port dashboard strategy dns_optimistic dns_optimistic_timeout dns_timeout dns_advanced core_version realm_enabled realm_listen realm_port realm_url realm_token realm_user realm_max realm_domain
  validate_state_semantics "$state" || return 1
  mux_config=$(mux_builtin_config "$state") || return 1
  # Rendered inbounds are cached by content (see render_cache_key), so only
  # changed nodes are rendered again; inbounds are joined in one jq call.
  local users nsec key file cache_dir realm_part u
  local -a rendered=() files=()
  cache_dir=$(render_cache_dir) || cache_dir=''
  while IFS=$'\t' read -r node_id node users; do
    [[ -n "$node_id" ]] || continue
    nsec=$(state_secret_path "$node_id"); file=''
    if [[ -n "$cache_dir" ]]; then
      files=(); for u in $users; do files+=("$(state_user_secret_path "$node_id" "$u")"); done
      # Hysteria2 Realm blocks embed the global Realm URL and token.
      realm_part=''
      if [[ $(jq -r '.realm_enabled // false' <<<"$node") == true ]]; then
        realm_part="$(jq -c '.realm // {}' "$state")$(cat -- "$SBM_REALM_SECRET" 2>/dev/null)"
      fi
      key=$({ printf '%s\0' render "$SBM_VERSION" "$SBM_CERTS" "$node" "$realm_part"; cat -- "${files[@]}" 2>/dev/null; [[ ! -r "$nsec" ]] || cat -- "$nsec"; } | sha256sum | awk '{print $1}')
      file="$cache_dir/$key.inbound.json"
    fi
    if [[ -n "$file" && -s "$file" ]]; then
      inbound=$(<"$file")
    else
      credentials=$(node_enabled_credentials "$node")
      node_secret='{}'
      [[ ! -r "$nsec" ]] || node_secret=$(state_get_secret "$node_id")
      inbound=$(render_inbound_for_node "$node" "$credentials" "$node_secret") || return 1
      [[ -z "$file" ]] || { (umask 077; printf '%s\n' "$inbound" >"$file.$$" && mv -f "$file.$$" "$file") 2>/dev/null || rm -f "$file.$$"; }
    fi
    rendered+=("$inbound")
  done < <(jq -r '(.nginx_stream.enabled // false) as $mux | (.nginx_stream.routes // []) as $routes |
    .nodes[]? | select(.enabled==true and any(.users[]?; .enabled==true)) | . as $n |
    ([$routes[] | select(.node_id==$n.id)] | first) as $r |
    (if $mux and $r != null then .listen="127.0.0.1" | .port=$r.backend_port else . end) |
    [.id, tojson, ([.users[] | select(.enabled==true) | .id] | join(" "))] | join("\t")' "$state")
  if (( ${#rendered[@]} )); then
    inbounds=$(printf '%s\n' "${rendered[@]}" | jq -cs 'map(if type=="array" then .[] else . end)') || return 1
  fi
  log_level=$(jq -r '.settings.log_level // "info"' "$state")
  api_enabled=$(jq -r '.api.enabled // false' "$state")
  api_secret=''; api_port=$(jq -r '.api.port // 9090' "$state"); dashboard=$(jq -r '.api.dashboard // false' "$state")
  strategy=$(jq -r '.settings.outbound_ip_strategy // "prefer_ipv4"' "$state")
  realm_enabled=$(jq -r '.realm.enabled // false' "$state")
  realm_listen=$(jq -r '.realm.listen // "::"' "$state")
  realm_port=$(jq -r '.realm.port // 9443' "$state")
  realm_url=$(jq -r '.realm.public_url // ""' "$state")
  realm_user=$(jq -r '.realm.user_name // "default"' "$state")
  realm_max=$(jq -r '.realm.max_realms // 0' "$state")
  realm_domain=$(jq -r '.realm.tls_domain // ""' "$state")
  realm_token=''
  [[ "$realm_enabled" != true ]] || realm_token=$(jq -r '.token' "$SBM_REALM_SECRET")
  dns_optimistic=$(jq -r '.settings.dns_optimistic // false' "$state")
  dns_optimistic_timeout=$(jq -r '.settings.dns_optimistic_timeout // "3d"' "$state")
  dns_timeout=$(jq -r '.settings.dns_timeout // "10s"' "$state")
  dns_advanced=false
  if [[ "$dns_optimistic" == true || "$dns_timeout" != 10s ]]; then
    core_version=$(core_current_version || true)
    version_ge "$core_version" 1.14.0-rc.1 || die 'optimistic DNS 和 DNS 超时设置需要 sing-box 1.14.0-rc.1 或更高版本核心。'
    dns_advanced=true
  fi
  [[ "$api_enabled" != true ]] || api_secret=$(state_get_secret api | jq -r '.secret')
  jq -n --argjson metered_proxies "$(jq '[.nodes[]|select(.enabled and .traffic.enabled and (.protocol|IN("socks","mixed")))|"in-"+.id]' "$state")" --arg level "$log_level" --arg strategy "$strategy" --argjson inbounds "$inbounds" --argjson api_enabled "$api_enabled" \
    --argjson mux "$mux_config" \
    --arg secret "$api_secret" --argjson api_port "$api_port" --argjson dashboard "$dashboard" --arg dashboard_path "$SBM_VAR/dashboard" \
    --argjson dns_advanced "$dns_advanced" --argjson dns_optimistic "$dns_optimistic" --arg dns_optimistic_timeout "$dns_optimistic_timeout" --arg dns_timeout "$dns_timeout" \
    --argjson realm_enabled "$realm_enabled" --arg realm_listen "$realm_listen" --argjson realm_port "$realm_port" --arg realm_url "$realm_url" --arg realm_token "$realm_token" --arg realm_user "$realm_user" --argjson realm_max "$realm_max" --arg realm_domain "$realm_domain" --arg cert_dir "$SBM_CERTS" '{
    "$schema":"https://sing-box.sagernet.org/schema.json",
    log:{level:$level,timestamp:true},
    inbounds:$inbounds,
    dns:{servers:[{type:"local",tag:"dns-local"}],final:"dns-local",strategy:$strategy},
    outbounds:[{type:"direct",tag:"direct"}],
    route:{default_domain_resolver:"dns-local",final:"direct"}
  }
  | if ($metered_proxies|length)>0 then .route.rules=[{inbound:$metered_proxies,network:"udp",action:"reject"}] else . end
  | if ($mux.inbounds|length)>0 then
      .inbounds += $mux.inbounds
      | .route.rules=($mux.rules + (.route.rules // []))
    else . end
  | if $dns_advanced then
      .dns.timeout=$dns_timeout
      | .dns.optimistic=(if $dns_optimistic then {enabled:true,timeout:$dns_optimistic_timeout} else false end)
    else . end
  | if $realm_enabled then
      .services=[{type:"hysteria-realm",tag:"realm-local",listen:$realm_listen,listen_port:$realm_port,users:[{name:$realm_user,token:$realm_token,max_realms:$realm_max}]}]
      | if $realm_domain=="" then . else .services[0].tls={enabled:true,server_name:$realm_domain,certificate_path:($cert_dir + "/" + $realm_domain + "/fullchain.pem"),key_path:($cert_dir + "/" + $realm_domain + "/key.pem")} end
    else . end
  | if $api_enabled then
      .http_clients=[{tag:"http-direct",detour:"direct"}]
      | .route.default_http_client="http-direct"
      | .services=((.services // []) + [{
          type:"api",tag:"api-local",listen:"127.0.0.1",listen_port:$api_port,secret:$secret,
          access_control_allow_origin:[("http://127.0.0.1:" + ($api_port|tostring))],
          dashboard:(if $dashboard then {enabled:true,path:$dashboard_path,http_client:"http-direct",update_interval:"1d"} else false end)
        }])
    else . end
  ' >"$output"
  jq -e . "$output" >/dev/null
}

core_validate_config_with() {
  local binary=$1 config=$2 log_file=${3:-$SBM_RUN/check.log}
  [[ -x "$binary" ]] || die "sing-box 核心不存在：$binary"
  if ! "$binary" check -c "$config" >"$log_file" 2>&1; then
    log_error "sing-box 配置检查失败："
    sed -n '1,80p' "$log_file" >&2 || true
    return 1
  fi
}

core_validate_config() { core_validate_config_with "$SBM_SING_BOX_BIN" "$1"; }

runtime_render_candidates() {
  local state=$1 singbox_config=$2
  render_config_from_state "$state" "$singbox_config" && core_validate_config "$singbox_config"
}

apply_candidate_state() (
  local candidate=$1 reason=${2:-change} tmp_config
  website_mux_sync_routes "$candidate" || return 1
  tmp_config=$(mktemp "$SBM_RUN/config.candidate.XXXXXX") || return 1
  trap 'rm -f -- "$tmp_config"' EXIT
  runtime_render_candidates "$candidate" "$tmp_config" || return 1
  state_install_candidate "$candidate" "$tmp_config" "$reason" || return 1
  log_ok '配置已应用。'
)

render_current_config() (
  local tmp backup retain=0 restored=1
  tmp=$(mktemp "$SBM_RUN/config.current.XXXXXX") || return 1
  backup=$(mktemp -d "$SBM_BACKUPS/config-current.XXXXXX") || { rm -f "$tmp"; return 1; }
  trap 'rm -f -- "$tmp"; (( retain )) || rm -rf -- "$backup"' EXIT
  printf '%s\n' "$$" >"$backup/.operation-pid" || return 1
  runtime_render_candidates "$SBM_STATE" "$tmp" || return 1
  [[ ! -f "$SBM_CONFIG" ]] || cp -a "$SBM_CONFIG" "$backup/singbox" || return 1
  if ! { safe_install_file "$tmp" "$SBM_CONFIG" 0640 && set_group_if_exists "$SBM_SERVICE_USER" "$SBM_CONFIG"; }; then
    if [[ -f "$backup/singbox" ]]; then cp -a "$backup/singbox" "$SBM_CONFIG" || restored=0
    else rm -f "$SBM_CONFIG" || restored=0; fi
    if (( ! restored )); then
      retain=1; touch "$backup/.recovery-pending"
      log_error "配置恢复未完成，临时记录最多保留 23 小时：$backup"
    fi
    return 1
  fi
)
