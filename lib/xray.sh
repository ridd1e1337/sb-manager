#!/usr/bin/env bash
# shellcheck shell=bash

xray_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '64\n' ;;
    aarch64|arm64) printf 'arm64-v8a\n' ;;
    armv7l|armv7|armhf) printf 'arm32-v7a\n' ;;
    i386|i486|i586|i686) printf '32\n' ;;
    *) die "Xray 暂不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

xray_release_json() {
  local version=${1:-latest}
  if [[ "$version" == latest ]]; then github_api 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'
  else github_api "https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${version#v}"; fi
}

xray_current_version() {
  local output
  [[ -x "$SBM_XRAY_BIN" ]] || return 0
  output=$("$SBM_XRAY_BIN" version 2>/dev/null) || return 1
  [[ "$output" =~ Xray[[:space:]]+([0-9]{2,4}\.[0-9]+\.[0-9]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

xray_asset_name() {
  case "$2" in
    64|32|arm64-v8a|arm32-v7a) printf 'Xray-linux-%s.zip\n' "$2" ;;
    *) return 1 ;;
  esac
}

xray_download_version() (
  local requested=${1:-latest} arch json version name url digest expected work target size
  dependency_require_feature xray >&2 || return 1
  arch=$(xray_arch) || return 1
  json=$(xray_release_json "$requested") || { log_error '无法获取 Xray 官方 Release。'; return 1; }
  version=$(jq -r '.tag_name // empty | ltrimstr("v")' <<<"$json") || return 1
  [[ "$version" =~ ^[0-9]{2,4}\.[0-9]+\.[0-9]+$ ]] || { log_error "无效 Xray 版本：$version"; return 1; }
  name=$(xray_asset_name "$version" "$arch") || return 1
  url=$(jq -r --arg n "$name" 'first(.assets[] | select(.name==$n) | .browser_download_url) // empty' <<<"$json") || return 1
  digest=$(jq -r --arg n "$name" 'first(.assets[] | select(.name==$n) | .digest) // empty' <<<"$json") || return 1
  [[ "$url" == "https://github.com/XTLS/Xray-core/releases/download/"* ]] || { log_error '缺少官方 Xray 下载地址。'; return 1; }
  target="$SBM_CORE_DIR/xray/$version/xray"
  if [[ -x "$target" ]]; then
    "$target" version >/dev/null 2>&1 || return 1
    printf '%s\n' "$target"
    return 0
  fi
  mkdir -p "$SBM_CACHE" "$SBM_CORE_DIR/xray" || return 1
  size=$(jq -r --arg n "$name" 'first(.assets[] | select(.name==$n) | .size) // 0' <<<"$json") || return 1
  [[ "$size" =~ ^[1-9][0-9]*$ ]] || return 1
  core_check_free_space "$SBM_CACHE" "$((size + 40000000))" || return 1
  core_check_free_space "$SBM_CORE_DIR" 40000000 || return 1
  work=$(mktemp -d "$SBM_CACHE/xray.XXXXXX") || return 1
  trap 'rm -rf -- "$work"; rm -f -- "$target.new"' EXIT
  download_file_with_retries "$url" "$work/core.zip" "Xray $version" 5 || return 1
  if [[ "$digest" != sha256:* ]]; then
    url=$(jq -r --arg n "$name.dgst" 'first(.assets[] | select(.name==$n) | .browser_download_url) // empty' <<<"$json") || return 1
    [[ "$url" == "https://github.com/XTLS/Xray-core/releases/download/"* ]] || { log_error 'Xray Release 缺少 SHA-256 摘要。'; return 1; }
    download_file_with_retries "$url" "$work/digest" 'Xray 摘要' 5 || return 1
    expected=$(awk -F= '/^SHA2?-256=/{gsub(/[[:space:]]/, "", $2); print tolower($2); exit}' "$work/digest") || return 1
    [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || { log_error 'Xray SHA-256 摘要无效。'; return 1; }
    digest="sha256:$expected"
  fi
  verify_asset_digest "$work/core.zip" "$digest" || { log_error 'Xray 下载摘要不匹配。'; return 1; }
  # Routing is generated locally; the large geoip/geosite databases are unused.
  install -d -m 0755 "$SBM_CORE_DIR/xray/$version" || return 1
  unzip -p "$work/core.zip" xray >"$target.new" || return 1
  chmod 0755 "$target.new" || return 1
  "$target.new" version >/dev/null 2>&1 || { log_error 'Xray 无法在当前架构运行。'; return 1; }
  mv -f "$target.new" "$target" || return 1
  ensure_program_permissions || return 1
  artifact_record xray "$version" "https://github.com/XTLS/Xray-core/releases/download/v$version/$name" "$digest" "$target" >&2 || return 1
  printf '%s\n' "$target"
)

xray_prune_versions() {
  local active directory
  [[ -d "$SBM_CORE_DIR/xray" ]] || return 0
  # A failed recovery may still need the previous executable until repaired.
  [[ -z $(find "$SBM_BACKUPS" -name .recovery-pending -print -quit 2>/dev/null) ]] || return 0
  active=$(readlink -f "$SBM_XRAY_BIN" 2>/dev/null || true)
  [[ "$active" == "$SBM_CORE_DIR/xray/"* ]] || return 0
  for directory in "$SBM_CORE_DIR/xray"/*; do
    [[ -d "$directory" && ! -L "$directory" ]] || continue
    [[ "$active" == "$directory/xray" ]] || rm -rf -- "$directory" || return 1
  done
}

xray_node_override() {
  jq -c --arg direction "$2" '(.xray // {})[$direction] // {}' <<<"$1"
}

xray_apply_override() {
  local rendered=$1 override=$2
  jq -e 'type=="object" and (.settings==null or (.settings|type)=="object") and (.streamSettings==null or (.streamSettings|type)=="object")' <<<"$override" >/dev/null || {
    log_error 'Xray 扩展及 settings/streamSettings 必须是 JSON 对象。'; return 1;
  }
  jq --argjson override "$override" '
    . as $base | . * ($override
      | if .settings==null then del(.settings) else . end
      | if .streamSettings==null then del(.streamSettings) else . end
      | del(.protocol,.tag,.listen,.port,.settings.clients,.settings.accounts,.settings.password))
    | .protocol=$base.protocol | .tag=$base.tag | .listen=$base.listen | .port=$base.port
    | .settings=((.settings // {}) + {clients:$base.settings.clients})
  ' <<<"$rendered"
}

xray_inbound_for_node() {
  local node=$1 credentials=$2 secret=$3 id domain rendered users security flow target
  [[ $(jq -r '.protocol' <<<"$node") == vless ]] || { log_error 'Xray 运行时仅接管 VLESS。'; return 1; }
  id=$(jq -r '.id' <<<"$node"); domain=$(jq -r '.domain' <<<"$node")
  flow=$(jq -r '.flow // ""' <<<"$node"); security=$(jq -r '.security' <<<"$node")
  # email is the per-user Stats API key; keep it unique across nodes.
  users=$(jq --arg flow "$flow" --arg node "$id" '[.[] | {id:.uuid,email:($node+":"+.id),level:0} + (if $flow=="" then {} else {flow:$flow} end)]' <<<"$credentials") || return 1
  rendered=$(jq -n --arg tag "in-$id" --arg listen "$(jq -r '.listen // "::"' <<<"$node")" \
    --argjson port "$(jq -r '.port' <<<"$node")" --argjson clients "$users" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:$clients,decryption:"none"},streamSettings:{network:"raw"}}') || return 1
  if [[ "$security" == reality ]]; then
    target=$(format_hostport "$(jq -r '.handshake_server' <<<"$node")" "$(jq -r '.handshake_port' <<<"$node")") || return 1
    rendered=$(jq --arg target "$target" --arg server_name "$domain" \
      --arg private "$(jq -r '.reality_private_key' <<<"$secret")" --arg short_id "$(jq -r '.reality_short_id' <<<"$secret")" \
      '.streamSettings += {security:"reality",realitySettings:{show:false,target:$target,xver:0,serverNames:[$server_name],privateKey:$private,shortIds:[$short_id]}}' <<<"$rendered") || return 1
  elif [[ "$security" == tls ]]; then
    rendered=$(jq --arg cert "$SBM_CERTS/$domain/fullchain.pem" --arg key "$SBM_CERTS/$domain/key.pem" \
      '.streamSettings += {security:"tls",tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}' <<<"$rendered") || return 1
  fi
  rendered=$(xray_apply_override "$rendered" "$(xray_node_override "$node" inbound)") || return 1
  local stream
  stream=$(vless_stream_normalize "$(jq -c '.streamSettings' <<<"$rendered")") || return 1
  # Fallbacks need an explicit HTTP/1.1 ALPN; add h2 only for h2 fallbacks.
  jq --argjson stream "$stream" '.streamSettings=$stream
    | if ((.settings.fallbacks // [])|length)>0 and .streamSettings.security=="tls" and .streamSettings.tlsSettings.alpn==null then
        .streamSettings.tlsSettings.alpn=(if any(.settings.fallbacks[]; .alpn=="h2") then ["h2","http/1.1"] else ["http/1.1"] end)
      else . end' <<<"$rendered"
}

xray_render_config() {
  local state=$1 output=$2 node id credentials secret inbound inbounds='[]'
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if declare -F nginx_stream_effective_node >/dev/null 2>&1; then node=$(nginx_stream_effective_node "$state" "$node") || return 1; fi
    id=$(jq -r '.id' <<<"$node") || return 1
    credentials=$(node_enabled_credentials "$node") || return 1
    secret='{}'; [[ ! -r "$(state_secret_path "$id")" ]] || secret=$(state_get_secret "$id") || return 1
    inbound=$(xray_inbound_for_node "$node" "$credentials" "$secret") || return 1
    inbounds=$(jq -c --argjson inbound "$inbound" '. + [$inbound]' <<<"$inbounds") || return 1
  done < <(state_xray_nodes "$state")
  local routing='{"outbounds":[{"tag":"direct","protocol":"freedom"}]}'
  if declare -F xray_routing_render >/dev/null 2>&1; then routing=$(xray_routing_render "$state") || return 1; fi
  # Loopback-only Stats API for per-user traffic and online-IP limits.
  jq -n --argjson inbounds "$inbounds" --argjson routing "$routing" --arg api "127.0.0.1:$(jq -r '.settings.xray_api_port // 10085' "$state")" '{
    log:{loglevel:"warning"},
    api:{tag:"api",listen:$api,services:["StatsService"]},
    stats:{},
    policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true,statsUserOnline:true}},
      system:{statsInboundUplink:true,statsInboundDownlink:true,statsOutboundUplink:true,statsOutboundDownlink:true}},
    inbounds:$inbounds} + $routing' >"$output" || return 1
  chmod 0640 "$output" && set_group_if_exists "$SBM_SERVICE_USER" "$output"
}

# Current Xray infers the config format from the file extension and rejects
# extensionless candidates even with -format json. BusyBox mktemp lacks
# --suffix, so test a config.json copy inside a private temporary directory.
xray_test_config() (
  local bin=$1 config=$2 log=$3 dir
  mkdir -p "$SBM_RUN" || return 1
  dir=$(mktemp -d "$SBM_RUN/xray-test.XXXXXX") || return 1
  trap 'rm -rf -- "$dir"' EXIT
  chmod 0700 "$dir" && cp "$config" "$dir/config.json" || return 1
  "$bin" run -test -config "$dir/config.json" >"$log" 2>&1
)

xray_validate_config() {
  xray_test_config "$1" "$2" "$SBM_RUN/xray-config-check.log" || {
    log_error "Xray 配置检查失败；日志：$SBM_RUN/xray-config-check.log"; return 1;
  }
}

xray_write_service() {
  local backend=$1 unit
  unit=$(service_file_path "$SBM_XRAY_SERVICE") || return 1
  case "$backend" in
    systemd)
      mkdir -p "$SBM_SYSTEMD_DIR" || return 1
      cat >"$unit.new" <<EOF_UNIT || return 1
[Unit]
Description=sb-manager VLESS Xray-core service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
ExecStart=$SBM_XRAY_BIN run -config $SBM_XRAY_CONFIG
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=$SBM_ETC $SBM_LIB
[Install]
WantedBy=multi-user.target
EOF_UNIT
      chmod 0644 "$unit.new" && mv -f "$unit.new" "$unit" || return 1 ;;
    openrc)
      dependency_require_feature low-port || return 1
      setcap cap_net_bind_service=+ep "$(readlink -f "$SBM_XRAY_BIN")" || {
        log_error '无法授予 Xray 低端口能力，未切换为 root 服务。'; return 1;
      }
      write_openrc_supervised_service "$unit" 'sb-manager xray' 'sb-manager VLESS Xray-core service' "$SBM_XRAY_BIN" "run -config $SBM_XRAY_CONFIG" "$SBM_SERVICE_USER" "$SBM_XRAY_LOG" "$SBM_XRAY_ERROR_LOG" 'after firewall' || return 1 ;;
    *) log_error 'Xray 需要 systemd 或 OpenRC。'; return 1 ;;
  esac
}

xray_service_reconcile() {
  local restart=${1:-1}
  [[ "$SBM_SKIP_INIT" != 1 ]] || return 0
  if ! xray_runtime_required; then
    if service_exists "$SBM_XRAY_SERVICE"; then
      service_disable "$SBM_XRAY_SERVICE" && service_stop "$SBM_XRAY_SERVICE" || return 1
      service_reset_failed "$SBM_XRAY_SERVICE"
    fi
    return 0
  fi
  [[ -x "$SBM_XRAY_BIN" && -s "$SBM_XRAY_CONFIG" ]] || { log_error 'Xray 程序或 VLESS 配置缺失。'; return 1; }
  if [[ "$restart" == 0 ]] && service_active "$SBM_XRAY_SERVICE"; then return 0; fi
  # Restarting drops in-memory counters; fold them into the ledger first.
  if declare -F user_usage_collect_unlocked >/dev/null 2>&1; then user_usage_collect_unlocked || true; fi
  xray_write_service "$(init_system)" && service_reload_manager && service_enable "$SBM_XRAY_SERVICE" || return 1
  service_restart "$SBM_XRAY_SERVICE" && service_wait_active "$SBM_XRAY_SERVICE" 20 2 || {
    service_failure_report "$SBM_XRAY_SERVICE"; return 1;
  }
}

xray_render_validate() (
  local output=${1:-$SBM_XRAY_CONFIG} config
  mkdir -p "$(dirname "$output")" || return 1
  config=$(mktemp "$(dirname "$output")/.xray-config.XXXXXX") || return 1
  trap 'rm -f -- "$config"' EXIT
  xray_render_config "$SBM_STATE" "$config" && xray_validate_config "$SBM_XRAY_BIN" "$config" || return 1
  mv -f "$config" "$output"
)

_xray_install() {
  local target old active=0 config backup rc=0
  old=$(readlink -f "$SBM_XRAY_BIN" 2>/dev/null || true)
  service_active "$SBM_XRAY_SERVICE" && active=1
  [[ -L "$SBM_XRAY_BIN" || ! -e "$SBM_XRAY_BIN" ]] || { log_error '已有非托管 Xray 程序，拒绝覆盖。'; return 1; }
  if (( active )) && ! xray_runtime_required; then
    log_error '旧 Xray 服务尚未按 VLESS 分工接入，请先执行 sb xray enable。'; return 1
  fi
  target=$(xray_download_version latest) || return 1
  if [[ "$old" == "$target" ]]; then
    xray_prune_versions || return 1
    log_ok "Xray 已是最新版：$(xray_current_version)"
    return 0
  fi
  config=$(mktemp "$SBM_RUN/xray-candidate.XXXXXX") || return 1
  if xray_runtime_required; then
    xray_render_config "$SBM_STATE" "$config" && xray_validate_config "$target" "$config" || { rm -f "$config"; return 1; }
  fi
  backup=$(snapshot_create xray-install) || { rm -f "$config"; return 1; }
  touch "$backup/force-xray-restart" || { rm -f "$config"; rm -rf -- "$backup"; return 1; }
  mkdir -p "$SBM_BIN_DIR" || { rm -f "$config"; rm -rf -- "$backup"; return 1; }
  if ln -sfn "$target" "$SBM_XRAY_BIN.new" && mv -Tf "$SBM_XRAY_BIN.new" "$SBM_XRAY_BIN"; then
    if xray_runtime_required; then
      safe_install_file "$config" "$SBM_XRAY_CONFIG" 0640 && set_group_if_exists "$SBM_SERVICE_USER" "$SBM_XRAY_CONFIG" || rc=1
      (( rc != 0 )) || xray_service_reconcile 1 || rc=1
    fi
  else rc=1; fi
  rm -f "$config"
  if (( rc != 0 )); then
    if [[ -n "$old" && -x "$old" ]]; then ln -sfn "$old" "$SBM_XRAY_BIN.new" && mv -Tf "$SBM_XRAY_BIN.new" "$SBM_XRAY_BIN" || return 1
    else rm -f "$SBM_XRAY_BIN"; fi
    if snapshot_restore "$backup"; then rm -rf -- "$backup"
    else touch "$backup/.recovery-pending"; log_error "Xray 恢复未完成，临时恢复记录最多保留 23 小时：$backup"; fi
    return 1
  fi
  rm -rf -- "$backup"
  xray_prune_versions || return 1
  log_ok "Xray 已安装：$(xray_current_version)；仅负责 VLESS。"
}

xray_install() { require_root; with_lock _xray_install; }
xray_update() { xray_install; }

_xray_set_policy() {
  local policy=$1 candidate
  case "$policy" in manual|notify|patch|stable) ;; *) usage_die 'Xray 更新策略必须是 manual、notify、patch 或 stable。';; esac
  candidate=$(state_candidate) || return 1
  jq --arg policy "$policy" '.settings.xray_update_policy=$policy' "$SBM_STATE" >"$candidate" || return 1
  apply_candidate_state "$candidate" xray-policy || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
  log_ok "Xray 自动更新策略：$policy"
}
xray_set_policy() { with_state_transaction xray-policy _xray_set_policy "$@"; }

_xray_set_engine() {
  local engine=$1 candidate
  candidate=$(state_candidate) || return 1
  jq --arg engine "$engine" '.settings.vless_engine=$engine' "$SBM_STATE" >"$candidate" || return 1
  apply_candidate_state "$candidate" "vless-$engine" || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
  if [[ "$engine" == xray ]]; then log_ok 'VLESS 已交给 Xray；其他协议由 sing-box 运行。'
  else log_ok 'VLESS 已暂停；其他协议继续由 sing-box 运行。'; fi
}
_xray_set_api_port() {
  local port=$1 candidate
  validate_port "$port" || { log_error "无效端口：$port"; return 1; }
  candidate=$(state_candidate) || return 1
  jq --argjson port "$((10#$port))" '.settings.xray_api_port=$port' "$SBM_STATE" >"$candidate" || { rm -f "$candidate"; return 1; }
  if ! apply_candidate_state "$candidate" xray-api-port; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "Xray 统计 API 仅监听 127.0.0.1:$port"
}
xray_set_api_port() { require_root; with_state_transaction xray-api-port _xray_set_api_port "$1"; }

xray_enable() { require_root; with_state_transaction xray-enable _xray_set_engine xray; }
xray_disable() { require_root; with_state_transaction xray-disable _xray_set_engine disabled; }

xray_status() {
  printf 'VLESS 引擎：%s\n' "$(jq -r '.settings.vless_engine // "sing-box"' "$SBM_STATE")"
  if [[ ! -x "$SBM_XRAY_BIN" ]]; then printf 'Xray：未安装\n'; return 0; fi
  printf 'Xray：%s\n服务：%s\n配置：%s\n' "$(xray_current_version || printf '未知版本')" "$(status_service_state "$SBM_XRAY_SERVICE")" "$SBM_XRAY_CONFIG"
}

xray_auto_update() {
  [[ -x "$SBM_XRAY_BIN" ]] || return 0
  local policy current latest
  policy=$(jq -r '.settings.xray_update_policy // "notify"' "$SBM_STATE") || return 1
  [[ "$policy" != manual ]] || return 0
  current=$(xray_current_version) || return 1
  latest=$(xray_release_json latest | jq -r '.tag_name // empty | ltrimstr("v")') || return 1
  [[ -n "$latest" && "$current" != "$latest" ]] || return 0
  case "$policy" in
    notify) log_warn "发现 Xray 更新：$current → $latest；运行 sb xray update。" ;;
    patch|stable) _xray_install ;;
  esac
}
