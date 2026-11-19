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
  if [[ "$version" == latest ]]; then
    github_api 'https://api.github.com/repos/XTLS/Xray-core/releases/latest'
  else
    github_api "https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${version#v}"
  fi
}

xray_current_version() {
  local output
  [[ -x "$SBM_XRAY_BIN" ]] || return 0
  output=$("$SBM_XRAY_BIN" version 2>/dev/null) || return 1
  if [[ "$output" =~ Xray[[:space:]]+([0-9]{4}\.[0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$output" =~ ([0-9]{4}\.[0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

xray_asset_name() {
  local version=${1#v} arch=$2
  case "$arch" in
    64) printf 'Xray-linux-64.zip\n' ;;
    32) printf 'Xray-linux-32.zip\n' ;;
    arm64-v8a) printf 'Xray-linux-arm64-v8a.zip\n' ;;
    arm32-v7a) printf 'Xray-linux-arm32-v7a.zip\n' ;;
    *) return 1 ;;
  esac
}

xray_download_version() {
  local requested=${1:-latest} arch json version asset_name asset_url digest checksum_url expected tmpdir archive found target
  arch=$(xray_arch)
  json=$(xray_release_json "$requested") || die '无法获取 Xray-core 官方 Release 信息。'
  version=$(jq -r '.tag_name // empty' <<<"$json" | sed 's/^v//')
  [[ "$version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || die "Xray Release 版本无效：$version"
  asset_name=$(xray_asset_name "$version" "$arch") || die "Xray Release 不支持架构：$arch"
  asset_url=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | .browser_download_url) // empty' <<<"$json")
  digest=$(jq -r --arg n "$asset_name" 'first(.assets[] | select(.name==$n) | (.digest // "")) // empty' <<<"$json")
  [[ -n "$asset_url" ]] || die "Xray Release 中未找到：$asset_name"
  target="$SBM_CORE_DIR/xray/$version/xray"
  if [[ -x "$target" ]]; then
    "$target" version 2>/dev/null | grep -Fq "$version" || die "已缓存的 Xray $version 无法通过版本校验。"
    artifact_record xray "$version" "$asset_url" "${digest:-previously-verified}" "$target"
    printf '%s\n' "$target"
    return 0
  fi
  mkdir -p "$SBM_CORE_DIR/xray" "$SBM_CACHE"
  core_check_free_space "$SBM_CACHE" 120000000 || return 1
  core_check_free_space "$SBM_CORE_DIR" 120000000 || return 1
  tmpdir=$(mktemp -d "$SBM_CACHE/xray.XXXXXX")
  archive="$tmpdir/$asset_name"
  download_file_with_retries "$asset_url" "$archive" "Xray $version" 5
  if [[ -n "$digest" && "$digest" == sha256:* ]]; then
    verify_asset_digest "$archive" "$digest" || { rm -rf "$tmpdir"; die 'Xray 下载文件摘要校验失败。'; }
  else
    checksum_url=$(jq -r 'first(.assets[] | select(.name|test("sha256sum|checksum";"i")) | .browser_download_url) // empty' <<<"$json")
    [[ -n "$checksum_url" ]] || { rm -rf "$tmpdir"; die 'Xray Release 未提供可用 SHA-256 摘要，已拒绝安装。'; }
    download_file_with_retries "$checksum_url" "$tmpdir/checksums.txt" 'Xray checksum' 5
    expected=$(awk -v n="$asset_name" '
      /^SHA2-256=/ {sub(/^SHA2-256=/, ""); gsub(/[[:space:]]/, ""); print; exit}
      $NF==n {print $1; exit}
    ' "$tmpdir/checksums.txt")
    [[ -n "$expected" && "$expected" == "$(sha256sum "$archive" | awk '{print $1}')" ]] || { rm -rf "$tmpdir"; die 'Xray 下载文件摘要校验失败。'; }
    digest="sha256:$expected"
  fi
  mkdir -p "$SBM_CORE_DIR/xray/$version"
  unzip -q "$archive" -d "$tmpdir/unpacked" || { rm -rf "$tmpdir"; die 'Xray 下载文件无法解压。'; }
  found=$(find "$tmpdir/unpacked" -type f -name xray -perm -u+x -print -quit)
  [[ -n "$found" ]] || { rm -rf "$tmpdir"; die 'Xray 压缩包中未找到可执行程序。'; }
  install -m 0755 "$found" "$target" || { rm -rf "$tmpdir"; die "无法写入 Xray 核心：$target"; }
  ensure_program_permissions
  "$target" version >/dev/null 2>&1 || { rm -rf "$tmpdir" "$(dirname "$target")"; die '下载的 Xray 核心无法执行。'; }
  artifact_record xray "$version" "$asset_url" "$digest" "$target"
  rm -rf "$tmpdir"
  printf '%s\n' "$target"
}

xray_supported_protocol() {
  case "$1" in vmess-ws-cf|shadowsocks|trojan|vless|socks|http|mixed) return 0;; *) return 1;; esac
}

xray_unsupported_nodes() {
  jq -r '.nodes[] | select(.enabled==true)
    | select(if .protocol == "shadowsocks" then (((.method // "") | startswith("2022-")) or (([.users[] | select(.enabled==true)] | length) > 1))
             else (.protocol | IN("vmess-ws-cf","trojan","vless","socks","http","mixed") | not)
             end)
    | "\(.name)（\(.protocol)\(if .method? then "," + .method else "" end)）"' "$1"
}

xray_users_json() {
  local credentials=$1
  jq '[.[] | if (.uuid // "") != "" then {id:.uuid,email:.name,level:0} elif (.password // "") != "" then {password:.password,email:.name,level:0} else {email:.name,level:0} end]' <<<"$credentials"
}

xray_node_override() {
  local node=$1 direction=$2
  jq -c --arg direction "$direction" 'if ((.xray // {})[$direction] // {}) | type == "object" then ((.xray // {})[$direction] // {}) else {} end' <<<"$node"
}

xray_apply_override() {
  local rendered=$1 override=$2
  jq --argjson override "$override" '
    def protected: del(.protocol,.tag,.listen,.port,.settings.clients,.settings.accounts,.settings.password);
    if ($override|type) != "object" or ($override|length)==0 then .
    else . * ($override | protected)
    end
  ' <<<"$rendered"
}

xray_inbound_for_node() {
  local node=$1 credentials=$2 node_secret=$3 protocol id listen port domain cert key rendered override
  protocol=$(jq -r '.protocol' <<<"$node"); id=$(jq -r '.id' <<<"$node")
  listen=$(jq -r '.listen // "::"' <<<"$node"); port=$(jq -r '.port' <<<"$node")
  case "$protocol" in
    vmess-ws-cf)
      rendered=$(jq -n --arg tag "in-$id" --arg listen "$listen" --argjson port "$port" --arg path "$(jq -r '.ws_path' <<<"$node")" \
        --argjson users "$(xray_users_json "$credentials")" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"vmess",settings:{clients:$users},streamSettings:{network:"ws",wsSettings:{path:$path}}}');;
    shadowsocks)
      rendered=$(jq -n --arg tag "in-$id" --arg listen "$listen" --argjson port "$port" --arg method "$(jq -r '.method' <<<"$node")" \
        --arg password "$(jq -r '.[0].password // ""' <<<"$credentials")" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"shadowsocks",settings:{method:$method,password:$password,network:"tcp,udp"}}');;
    trojan)
      domain=$(jq -r '.domain' <<<"$node"); cert="$SBM_CERTS/$domain/fullchain.pem"; key="$SBM_CERTS/$domain/key.pem"
      rendered=$(jq -n --arg tag "in-$id" --arg listen "$listen" --argjson port "$port" --argjson clients "$(xray_users_json "$credentials")" \
        --arg cert "$cert" --arg key "$key" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"trojan",settings:{clients:$clients},streamSettings:{network:"tcp",security:"tls",tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}}');;
    vless)
      domain=$(jq -r '.domain' <<<"$node")
      if [[ $(jq -r '.security' <<<"$node") == reality ]]; then
        rendered=$(jq -n --arg tag "in-$id" --arg listen "$listen" --argjson port "$port" --argjson clients "$(xray_users_json "$credentials")" \
          --arg dest "$(jq -r '.handshake_server' <<<"$node"):$(jq -r '.handshake_port' <<<"$node")" \
          --arg server_name "$domain" --arg private "$(jq -r '.reality_private_key' <<<"$node_secret")" --arg short_id "$(jq -r '.reality_short_id' <<<"$node_secret")" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:$clients,decryption:"none"},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:$dest,xver:0,serverNames:[$server_name],privateKey:$private,shortIds:[$short_id]}}}')
      else
        cert="$SBM_CERTS/$domain/fullchain.pem"; key="$SBM_CERTS/$domain/key.pem"
        rendered=$(jq -n --arg tag "in-$id" --arg listen "$listen" --argjson port "$port" --argjson clients "$(xray_users_json "$credentials")" \
          --arg cert "$cert" --arg key "$key" \
          '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:$clients,decryption:"none"},streamSettings:{network:"tcp",security:"tls",tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}}')
      fi ;;
    socks|mixed)
      rendered=$(jq -n --arg tag "in-$id" --arg listen "$listen" --argjson port "$port" --argjson accounts "$(jq '[.[]|{user:(.username // .name),pass:.password}]' <<<"$credentials")" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"socks",settings:{auth:"password",accounts:$accounts,udp:true}}');;
    http)
      rendered=$(jq -n --arg tag "in-$id" --arg listen "$listen" --argjson port "$port" --argjson accounts "$(jq '[.[]|{user:(.username // .name),pass:.password}]' <<<"$credentials")" \
        '{tag:$tag,listen:$listen,port:$port,protocol:"http",settings:{accounts:$accounts}}');;
    *) return 1 ;;
  esac
  override=$(xray_node_override "$node" inbound)
  xray_apply_override "$rendered" "$override"
}

xray_render_config() {
  local state=$1 output=$2 node id credentials secret inbounds='[]' unsupported
  unsupported=$(xray_unsupported_nodes "$state")
  if [[ -n "$unsupported" ]]; then
    log_error "Xray 不支持当前启用节点：$(paste -sd '、' <<<"$unsupported")"
    log_error '请停用这些节点，或继续使用 sing-box 运行它们。'
    return 1
  fi
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    id=$(jq -r '.id' <<<"$node")
    credentials=$(node_enabled_credentials "$node")
    secret='{}'; [[ ! -r "$(state_secret_path "$id")" ]] || secret=$(state_get_secret "$id")
    inbounds=$(jq -c --argjson inbound "$(xray_inbound_for_node "$node" "$credentials" "$secret")" '. + [$inbound]' <<<"$inbounds")
  done < <(jq -c '.nodes[] | select(.enabled==true)' "$state")
  jq -n --argjson inbounds "$inbounds" '{log:{loglevel:"warning",access:"",error:""},inbounds:$inbounds,outbounds:[{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}],routing:{domainStrategy:"AsIs",rules:[]}}' >"$output"
  chmod 0640 "$output"
  set_group_if_exists "$SBM_SERVICE_USER" "$output"
}

xray_validate_config() {
  local binary=$1 config=$2
  "$binary" run -test -config "$config" >"$SBM_RUN/xray-config-check.log" 2>&1 || {
    log_error "Xray 配置检查失败；日志：$SBM_RUN/xray-config-check.log"; return 1;
  }
}

xray_write_service() {
  local backend=$1
  case "$backend" in
    systemd)
      cat >"$SBM_SYSTEMD_DIR/$SBM_XRAY_SERVICE" <<EOF_UNIT
[Unit]
Description=sb-manager managed Xray-core service
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
ReadWritePaths=$SBM_VAR $SBM_LOG_DIR

[Install]
WantedBy=multi-user.target
EOF_UNIT
      chmod 0644 "$SBM_SYSTEMD_DIR/$SBM_XRAY_SERVICE" ;;
    openrc)
      write_openrc_supervised_service "$SBM_OPENRC_DIR/$(service_native_name "$SBM_XRAY_SERVICE")" 'sb-manager xray' 'sb-manager managed Xray-core service' "$SBM_XRAY_BIN" "run -config $SBM_XRAY_CONFIG" "$SBM_SERVICE_USER" "$SBM_XRAY_LOG" "$SBM_XRAY_ERROR_LOG" 'after firewall'
      ;;
    *) die 'Xray 需要 systemd 或 OpenRC。' ;;
  esac
}

xray_render_validate() {
  mkdir -p "$SBM_GENERATED_DIR"
  xray_render_config "$SBM_STATE" "$SBM_XRAY_CONFIG" || return 1
  xray_validate_config "$SBM_XRAY_BIN" "$SBM_XRAY_CONFIG"
}

xray_install() {
  require_root
  with_lock _xray_install
}

_xray_install() {
  local target old active=0
  target=$(xray_download_version latest)
  old=$(readlink -f "$SBM_XRAY_BIN" 2>/dev/null || true)
  service_active "$SBM_XRAY_SERVICE" && active=1 || true
  mkdir -p "$SBM_BIN_DIR"
  ln -sfn "$target" "$SBM_XRAY_BIN.new"
  mv -Tf "$SBM_XRAY_BIN.new" "$SBM_XRAY_BIN"
  if (( active )); then
    xray_render_validate || { [[ -z "$old" ]] || ln -sfn "$old" "$SBM_XRAY_BIN"; return 1; }
    if ! service_restart "$SBM_XRAY_SERVICE" || ! service_wait_active "$SBM_XRAY_SERVICE" 20 2; then
      [[ -z "$old" ]] || ln -sfn "$old" "$SBM_XRAY_BIN"
      service_restart "$SBM_XRAY_SERVICE" || true
      return 1
    fi
  fi
  [[ "$old" == "$target" ]] && log_ok "Xray 已是最新版：$(xray_current_version)" || log_ok "Xray 已安装：$(xray_current_version)"
}

xray_update() { require_root; with_lock _xray_install; }

_xray_set_policy() {
  local policy=$1 candidate
  case "$policy" in manual|notify|patch|stable) ;; *) die 'Xray 更新策略必须是 manual、notify、patch 或 stable。';; esac
  candidate=$(state_candidate)
  jq --arg policy "$policy" '.settings.xray_update_policy=$policy' "$SBM_STATE" >"$candidate"
  apply_candidate_state "$candidate" xray-policy || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
  log_ok "Xray 自动更新策略：$policy"
}
xray_set_policy() { with_state_transaction xray-policy _xray_set_policy "$@"; }

xray_enable() {
  require_root
  with_lock _xray_enable
}

_xray_enable() {
  [[ -x "$SBM_XRAY_BIN" ]] || _xray_install || return 1
  xray_render_validate || return 1
  local backend; backend=$(init_system)
  xray_write_service "$backend"
  service_reload_manager
  if service_active "$SBM_SERVICE"; then
    service_stop "$SBM_SERVICE"
    log_info '已停止 sing-box，释放节点端口给 Xray。'
  fi
  service_disable "$SBM_SERVICE"
  service_enable "$SBM_XRAY_SERVICE"
  service_start "$SBM_XRAY_SERVICE"
  service_wait_active "$SBM_XRAY_SERVICE" 20 2 || { service_failure_report "$SBM_XRAY_SERVICE"; return 1; }
  log_ok "Xray 已启用：$(xray_current_version)"
}

xray_disable() {
  require_root
  with_lock _xray_disable
}

_xray_disable() {
  if service_exists "$SBM_XRAY_SERVICE"; then
    service_disable "$SBM_XRAY_SERVICE"; service_stop "$SBM_XRAY_SERVICE"
  fi
  if state_runtime_required && [[ -x "$SBM_SING_BOX_BIN" ]]; then
    render_current_config
    singbox_service_reconcile
  fi
  log_ok 'Xray 已停用；sing-box 已按当前状态恢复（如有启用节点）。'
}

xray_status() {
  if [[ ! -x "$SBM_XRAY_BIN" ]]; then
    printf 'Xray：未安装\n路径：%s\n' "$SBM_XRAY_BIN"; return 0
  fi
  printf 'Xray：%s\n路径：%s\n服务：%s\n配置：%s\n' "$(xray_current_version || printf '未知版本')" "$SBM_XRAY_BIN" "$(status_service_state "$SBM_XRAY_SERVICE")" "$SBM_XRAY_CONFIG"
}

xray_auto_update() {
  [[ -x "$SBM_XRAY_BIN" ]] || return 0
  local policy current latest
  policy=$(jq -r '.settings.xray_update_policy // "notify"' "$SBM_STATE")
  [[ "$policy" != manual ]] || return 0
  current=$(xray_current_version || true); latest=$(xray_release_json latest | jq -r '.tag_name // empty' | sed 's/^v//')
  [[ -n "$current" && -n "$latest" && "$current" != "$latest" ]] || return 0
  case "$policy" in
    notify) log_warn "发现 Xray 更新：$current → $latest；运行 sb xray update。" ;;
    patch|stable) _xray_install ;;
  esac
}
