#!/usr/bin/env bash
# shellcheck shell=bash

openlist_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l|armv7|armhf) printf 'arm-7\n' ;;
    i386|i686) printf '386\n' ;;
    *) log_error "OpenList 暂不支持的 CPU 架构：$(uname -m)"; return 1 ;;
  esac
}

openlist_release_json() { github_api 'https://api.github.com/repos/OpenListTeam/OpenList/releases/latest'; }

openlist_binary_version() {
  local output version
  output=$("$1" version 2>/dev/null) || return 1
  # OpenList prints Go Version before its own Version field.
  version=$(awk '$1=="Version:" {sub(/^v/, "", $2); print $2; exit}' <<<"$output") || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

openlist_current_version() {
  [[ -x "$SBM_OPENLIST_BIN" ]] || return 0
  openlist_binary_version "$SBM_OPENLIST_BIN"
}

openlist_port() {
  if [[ -s "$SBM_OPENLIST_DATA/config.json" ]]; then
    jq -er '.scheme.http_port | select(type=="number" and floor==. and .>=1024 and .<=65535)' "$SBM_OPENLIST_DATA/config.json"
  else
    validate_port "$SBM_OPENLIST_PORT" && (( 10#$SBM_OPENLIST_PORT >= 1024 )) || return 1
    printf '%s\n' "$((10#$SBM_OPENLIST_PORT))"
  fi
}

openlist_require_runtime() {
  require_init_system
  case "$(init_system)" in systemd|openrc) ;; *) log_error 'OpenList 需要 systemd 或 OpenRC。'; return 1;; esac
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || { log_error 'OpenList 安装和网站配置不接受 --dry-run。'; return 1; }
  # These paths enter service definitions and the portable su command.
  local path
  for path in "$SBM_OPENLIST_BIN" "$SBM_OPENLIST_DATA" "$SBM_OPENLIST_LOG_DIR"; do
    [[ "$path" =~ ^/[A-Za-z0-9_./+-]+$ && "$path" != / && "$path" != *'/../'* ]] || return 1
  done
  [[ "$SBM_OPENLIST_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$SBM_OPENLIST_USER" != root ]] || return 1
  require_command curl; require_command tar; require_command timeout
  dependency_require_feature probe || return 1
  openlist_port >/dev/null || { log_error 'OpenList 本机端口必须为 1024–65535。'; return 1; }
}

openlist_download_latest() (
  set -Eeuo pipefail
  local arch json version name musl_name url digest target tmpdir archive member archive_bytes expanded_bytes candidate='' available_memory recovery_bytes=${1:-0}
  [[ "$recovery_bytes" =~ ^[0-9]+$ ]] || return 1
  arch=$(openlist_arch) || return 1
  json=$(openlist_release_json) || { log_error '无法获取 OpenList 官方 Release。'; return 1; }
  version=$(jq -er 'select(.draft==false and .prerelease==false)|.tag_name' <<<"$json") || return 1
  version=${version#v}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  name="openlist-linux-$arch.tar.gz"
  if [[ -f /etc/alpine-release ]]; then
    case "$arch" in
      amd64|arm64) musl_name="openlist-linux-musl-$arch.tar.gz";;
      arm-7) musl_name='openlist-linux-musleabihf-armv7l.tar.gz';;
      *) musl_name='';;
    esac
    if [[ -n "$musl_name" ]] && jq -e --arg name "$musl_name" 'any(.assets[]; .name==$name)' <<<"$json" >/dev/null; then name=$musl_name; fi
  fi
  url=$(jq -er --arg n "$name" 'first(.assets[]|select(.name==$n)).browser_download_url' <<<"$json") || return 1
  digest=$(jq -er --arg n "$name" 'first(.assets[]|select(.name==$n)).digest' <<<"$json") || return 1
  archive_bytes=$(jq -er --arg n "$name" 'first(.assets[]|select(.name==$n)).size | select(type=="number" and .>0)' <<<"$json") || return 1
  [[ "$url" == https://github.com/OpenListTeam/OpenList/releases/download/* && "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || {
    log_error 'OpenList Release 缺少有效的官方下载地址或 SHA-256 摘要。'; return 1;
  }
  target="$SBM_CORE_DIR/openlist/$version-${digest:7:16}/openlist"
  if [[ -x "$target" ]] && [[ $(openlist_binary_version "$target") == "$version" ]]; then
    printf '%s\n' "$target"
    return 0
  fi
  mkdir -p "$SBM_DOWNLOAD_TMP" || return 1
  core_check_free_space "$SBM_DOWNLOAD_TMP" "$((archive_bytes + 8388608))" || return 1
  if df -PT "$SBM_DOWNLOAD_TMP" | awk 'NR==2 {print $2}' | pipe_has -x tmpfs; then
    available_memory=$(awk '/^MemAvailable:/ {printf "%.0f", $2*1024}' /proc/meminfo)
    [[ "$available_memory" =~ ^[0-9]+$ ]] && (( available_memory > archive_bytes + 67108864 )) || {
      log_error '内存不足以安全暂存 OpenList 官方压缩包；请设置 SBM_DOWNLOAD_TMP 为容量充足的磁盘目录。'; return 1;
    }
  fi
  tmpdir=$(mktemp -d "$SBM_DOWNLOAD_TMP/sb-manager-openlist.XXXXXX") || return 1
  trap 'rm -rf -- "$tmpdir"; [[ -z "$candidate" ]] || rm -f -- "$candidate"' EXIT
  archive="$tmpdir/$name"
  download_file_with_retries "$url" "$archive" "OpenList $version" 5 || return 1
  verify_asset_digest "$archive" "$digest" || { log_error 'OpenList 下载摘要校验失败。'; return 1; }
  # Stream only the executable; never extract archive paths as root.
  member=$(tar -tzf "$archive" | awk '$0=="openlist" || $0=="./openlist" {print}') || return 1
  [[ "$member" == openlist || "$member" == ./openlist ]] || { log_error 'OpenList 压缩包结构无法识别。'; return 1; }
  expanded_bytes=$(tar -tvzf "$archive" | awk '$NF=="openlist" || $NF=="./openlist" {print $3}') || return 1
  [[ "$expanded_bytes" =~ ^[1-9][0-9]*$ ]] || { log_error '无法确认 OpenList 展开大小，未写入程序。'; return 1; }
  install -d -m 0755 "$SBM_CORE_DIR/openlist" "$(dirname "$target")" || return 1
  core_check_free_space "$(dirname "$target")" "$((expanded_bytes + recovery_bytes + 33554432))" || return 1
  candidate=$(mktemp "$(dirname "$target")/.openlist.XXXXXX") || return 1
  tar -xOzf "$archive" "$member" >"$candidate" || return 1
  chmod 0755 "$candidate" || return 1
  [[ $(openlist_binary_version "$candidate") == "$version" ]] || return 1
  mv -f "$candidate" "$target" || return 1
  candidate=''
  artifact_record openlist "$version" "$url" "$digest" "$target" || return 1
  printf '%s\n' "$target"
)

openlist_account() {
  local entry
  if ! group_exists "$SBM_OPENLIST_USER"; then
    if command_exists groupadd; then groupadd --system "$SBM_OPENLIST_USER" || return 1
    else addgroup -S "$SBM_OPENLIST_USER" || return 1; fi
  fi
  entry=$(account_entry "$SBM_OPENLIST_USER" || true)
  if [[ -z "$entry" ]]; then
    if command_exists useradd; then
      useradd --system --gid "$SBM_OPENLIST_USER" --home-dir "$SBM_OPENLIST_DATA" --shell /sbin/nologin "$SBM_OPENLIST_USER" || return 1
    else
      adduser -S -D -H -h "$SBM_OPENLIST_DATA" -s /sbin/nologin -G "$SBM_OPENLIST_USER" "$SBM_OPENLIST_USER" || return 1
    fi
  elif [[ $(cut -d: -f6 <<<"$entry") != "$SBM_OPENLIST_DATA" || $(id -gn "$SBM_OPENLIST_USER") != "$SBM_OPENLIST_USER" ]]; then
    log_error '同名 OpenList 用户不属于本项目，拒绝复用。'; return 1
  fi
  install -d -m 0750 -o "$SBM_OPENLIST_USER" -g "$SBM_OPENLIST_USER" "$SBM_OPENLIST_DATA" "$SBM_OPENLIST_LOG_DIR"
}

openlist_write_service() {
  local backend=$1 unit
  unit=$(service_file_path "$SBM_OPENLIST_SERVICE") || return 1
  mkdir -p "$(dirname "$unit")" || return 1
  case "$backend" in
    systemd)
      cat >"$unit" <<EOF_UNIT || return 1
[Unit]
Description=sb-manager managed OpenList service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=$SBM_OPENLIST_USER
Group=$SBM_OPENLIST_USER
WorkingDirectory=$SBM_OPENLIST_DATA
ExecStart=$SBM_OPENLIST_BIN server --data $SBM_OPENLIST_DATA
Environment=GOMEMLIMIT=128MiB
EnvironmentFile=-/etc/default/sb-openlist
Restart=on-failure
RestartSec=3s
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$SBM_OPENLIST_DATA
CapabilityBoundingSet=
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF_UNIT
      chmod 0644 "$unit" ;;
    openrc)
      local SBM_LOG_DIR=$SBM_OPENLIST_LOG_DIR
      write_openrc_supervised_service "$unit" 'sb-manager openlist' 'sb-manager managed OpenList service' "$SBM_OPENLIST_BIN" "server --data $SBM_OPENLIST_DATA" "$SBM_OPENLIST_USER" "$SBM_OPENLIST_LOG" "$SBM_OPENLIST_ERROR_LOG" 'after firewall' '' "$SBM_OPENLIST_DATA" || return 1
      printf '\nexport GOMEMLIMIT="${GOMEMLIMIT:-128MiB}"\n' >>"$unit" || return 1
      ;;
  esac
}

openlist_ready() {
  local port=$1 attempt response
  for ((attempt=0; attempt<20; attempt++)); do
    if service_active "$SBM_OPENLIST_SERVICE"; then
      response=$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$port/ping" 2>/dev/null || true)
      [[ "$response" == pong ]] && return 0
    fi
    sleep 0.5
  done
  log_error 'OpenList 本机 HTTP 服务未就绪，请查看 sb-openlist 服务日志。'
  return 1
}

openlist_install_restore() {
  local backup=$1 unit=$2 active=$3 enabled=$4 file
  service_stop "$SBM_OPENLIST_SERVICE"
  service_active "$SBM_OPENLIST_SERVICE" && { log_error 'OpenList 未能停止，保留现场与恢复备份。'; return 1; }
  for file in config.json data.db data.db-wal data.db-shm; do
    rm -f -- "$SBM_OPENLIST_DATA/$file" || return 1
    [[ ! -f "$backup/$file" ]] || cp -p "$backup/$file" "$SBM_OPENLIST_DATA/$file" || return 1
  done
  if [[ -f "$backup/binary-link" ]]; then cp -P "$backup/binary-link" "$SBM_OPENLIST_BIN.restore" && mv -fT "$SBM_OPENLIST_BIN.restore" "$SBM_OPENLIST_BIN" || return 1
  elif [[ -L "$backup/binary-link" ]]; then cp -P "$backup/binary-link" "$SBM_OPENLIST_BIN.restore" && mv -fT "$SBM_OPENLIST_BIN.restore" "$SBM_OPENLIST_BIN" || return 1
  else rm -f "$SBM_OPENLIST_BIN"; fi
  if [[ -f "$backup/unit" ]]; then cp -p "$backup/unit" "$unit" || return 1
  else rm -f "$unit" || return 1; fi
  service_reload_manager || return 1
  if [[ "$enabled" == true ]]; then service_enable "$SBM_OPENLIST_SERVICE" || return 1
  else service_disable "$SBM_OPENLIST_SERVICE"; fi
  if [[ "$active" == true ]]; then service_start "$SBM_OPENLIST_SERVICE" && openlist_ready "$(openlist_port)" || return 1; fi
}

openlist_install_finish() {
  local rc=$1 backup=$2 unit=$3 active=$4 enabled=$5 recovery_ready=$6
  if (( rc != 0 )) && [[ "$recovery_ready" == true ]]; then
    if ! openlist_install_restore "$backup" "$unit" "$active" "$enabled"; then
      touch "$backup/.recovery-pending"
      log_error "OpenList 自动恢复未完成：$backup；恢复资料最多保留 23 小时，请及时处理。"
      return 0
    fi
  fi
  rm -rf -- "$backup" || return 1
  openlist_prune
}

_openlist_install() (
  set -Eeuo pipefail
  local target port unit backup active=false enabled=false file config fresh=false recovery_ready=false recovery_bytes=0 file_bytes
  openlist_require_runtime || return 1
  port=$(openlist_port) || return 1
  unit=$(service_file_path "$SBM_OPENLIST_SERVICE") || return 1
  config="$SBM_OPENLIST_DATA/config.json"
  # Do not replace a manual OpenList installation or an externally managed DB.
  if [[ -e "$SBM_OPENLIST_BIN" || -L "$SBM_OPENLIST_BIN" ]]; then
    [[ -L "$SBM_OPENLIST_BIN" && $(readlink -f "$SBM_OPENLIST_BIN") == "$SBM_CORE_DIR/openlist/"* ]] || {
      log_error '现有 OpenList 程序不是本项目管理，拒绝覆盖。'; return 1;
    }
  fi
  if [[ -e "$unit" ]] && ! grep -Fq 'sb-manager managed OpenList service' "$unit"; then
    log_error '同名 OpenList 服务由其他工具管理，拒绝覆盖。'; return 1
  fi
  if [[ -f "$config" ]]; then
    jq -e --arg db "$SBM_OPENLIST_DATA/data.db" '(.database.type // "sqlite3")=="sqlite3" and ((.database.db_file // $db)==$db)' "$config" >/dev/null || {
      log_error 'OpenList 使用外部数据库或自定义路径，请先自行迁移；本命令只管理本机 SQLite。'; return 1;
    }
  elif [[ -e "$SBM_OPENLIST_DATA/data.db" ]]; then
    log_error '现有 OpenList 数据库缺少配置，拒绝自动初始化。'; return 1
  fi
  service_active "$SBM_OPENLIST_SERVICE" && active=true
  service_enabled "$SBM_OPENLIST_SERVICE" && enabled=true
  if node_port_in_state tcp "$port"; then
    log_error "OpenList 端口 $port 已分配给节点。"; return 1
  fi
  if [[ "$active" == false ]] && host_port_in_use tcp "$port"; then
    log_error "OpenList 端口 $port 已被占用。"; return 1
  fi
  mkdir -p "$SBM_BACKUPS/openlist" || return 1
  for file in config.json data.db data.db-wal data.db-shm; do
    [[ -f "$SBM_OPENLIST_DATA/$file" ]] || continue
    file_bytes=$(stat -c %s "$SBM_OPENLIST_DATA/$file") || return 1
    recovery_bytes=$((recovery_bytes + file_bytes))
  done
  core_check_free_space "$SBM_BACKUPS/openlist" "$((recovery_bytes + 33554432))" || return 1
  target=$(openlist_download_latest "$recovery_bytes") || return 1
  openlist_account || return 1
  mkdir -p "$SBM_BACKUPS/openlist" || return 1
  backup=$(mktemp -d "$SBM_BACKUPS/openlist/install-$(now_stamp).XXXXXX") || return 1
  trap 'rc=$?; openlist_install_finish "$rc" "$backup" "$unit" "$active" "$enabled" "$recovery_ready" || log_warn "OpenList 临时恢复资料清理未完成：$backup"' EXIT
  chmod 0700 "$backup" || return 1
  [[ ! -e "$SBM_OPENLIST_BIN" && ! -L "$SBM_OPENLIST_BIN" ]] || cp -P "$SBM_OPENLIST_BIN" "$backup/binary-link" || return 1
  [[ ! -f "$unit" ]] || cp -p "$unit" "$backup/unit" || return 1
  service_stop "$SBM_OPENLIST_SERVICE"
  service_active "$SBM_OPENLIST_SERVICE" && { log_error 'OpenList 未停止，取消更新。'; return 1; }
  for file in config.json data.db data.db-wal data.db-shm; do
    if [[ -L "$SBM_OPENLIST_DATA/$file" ]]; then
      log_error 'OpenList 数据文件不能是符号链接。'
      [[ "$active" != true ]] || service_start "$SBM_OPENLIST_SERVICE"
      return 1
    fi
    if [[ -f "$SBM_OPENLIST_DATA/$file" ]] && ! cp -p "$SBM_OPENLIST_DATA/$file" "$backup/$file"; then
      [[ "$active" != true ]] || service_start "$SBM_OPENLIST_SERVICE"
      return 1
    fi
  done
  recovery_ready=true
  [[ -s "$SBM_OPENLIST_DATA/data.db" ]] || fresh=true
  if [[ ! -f "$config" ]]; then printf '{}\n' >"$config" || return 1; fi
  jq --argjson port "$port" --arg db "$SBM_OPENLIST_DATA/data.db" '
    .scheme.address="127.0.0.1" | .scheme.http_port=$port | .scheme.https_port=-1
    | .scheme.force_https=false | .scheme.unix_file=""
    | .database.type="sqlite3" | .database.db_file=$db
    | .log.enable=false
    | .ftp.enable=false | .sftp.enable=false | .s3.enable=false | .mcp.enable=false
    | .site_url=""
  ' "$config" >"$backup/config-candidate.json" || return 1
  safe_install_file "$backup/config-candidate.json" "$config" 0600 || return 1
  chown "$SBM_OPENLIST_USER:$SBM_OPENLIST_USER" "$config" || return 1
  if [[ "$fresh" == true ]]; then
    # Latest OpenList requires explicit admin initialization. The secret is
    # inherited through the environment of this one process, never argv/unit.
    local admin="$SBM_SECRETS/openlist-admin.txt"
    (umask 077; : >"$admin") || return 1
    chmod 0600 "$admin" || return 1
    (
      export OPENLIST_ADMIN_PASSWORD
      OPENLIST_ADMIN_PASSWORD=$(random_password 32) || exit 1
      if command_exists runuser; then
        timeout 90 runuser -u "$SBM_OPENLIST_USER" -- "$target" --data "$SBM_OPENLIST_DATA" admin
      else
        timeout 90 su -p -s /bin/sh -c "exec '$target' --data '$SBM_OPENLIST_DATA' admin" "$SBM_OPENLIST_USER"
      fi
    ) >"$admin" 2>&1 || { log_error "OpenList 管理员初始化失败，详情：$admin"; return 1; }
    grep -Fq "Admin user's username:" "$admin" || { log_error "OpenList 管理员未建立，详情：$admin"; return 1; }
  fi
  ln -sfn "$target" "$SBM_OPENLIST_BIN.new" && mv -fT "$SBM_OPENLIST_BIN.new" "$SBM_OPENLIST_BIN" || return 1
  openlist_write_service "$(init_system)" || return 1
  service_reload_manager && service_enable "$SBM_OPENLIST_SERVICE" && service_start "$SBM_OPENLIST_SERVICE" || return 1
  openlist_ready "$port" || return 1
  log_ok "OpenList $(openlist_current_version) 已运行：127.0.0.1:$port"
  [[ "$fresh" != true ]] || log_info "初始管理员信息：$SBM_SECRETS/openlist-admin.txt；请登录后修改密码。"
)

openlist_install() { require_root; with_lock _openlist_install; }
openlist_update() {
  [[ -x "$SBM_OPENLIST_BIN" ]] || { log_error '请先安装 OpenList。'; return 1; }
  openlist_install
}

openlist_prune() {
  local current path
  # Unfinished recovery temporarily pins its binaries. Successful operation
  # snapshots are disposable; explicit backup archives are outside this tree.
  for path in "$SBM_BACKUPS/openlist"/*/.recovery-pending; do
    [[ ! -f "$path" ]] || return 0
  done
  for path in "$SBM_BACKUPS/openlist"/install-* "$SBM_BACKUPS/openlist"/site-* "$SBM_BACKUPS/openlist"/detach-*; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    rm -rf -- "$path" || return 1
  done
  [[ -L "$SBM_OPENLIST_BIN" ]] || return 0
  current=$(readlink -f "$SBM_OPENLIST_BIN") || return 1
  [[ "$current" == "$SBM_CORE_DIR/openlist/"* ]] || return 0
  for path in "$SBM_CORE_DIR/openlist"/*; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    [[ "${path##*/}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{16}$ ]] || continue
    [[ "$path/openlist" == "$current" ]] || rm -rf -- "$path" || return 1
  done
}

openlist_web_reload() {
  local server=$1
  if [[ $(init_system) == systemd ]]; then systemctl reload "$server.service" || return 1
  else rc-service "$server" reload || return 1; fi
  service_wait_active "$server.service" 20 2
}

openlist_keep_recovery() {
  local directory=$1
  touch "$directory/.recovery-pending" || return 1
  log_warn "未完成操作的恢复资料：$directory；最多保留 23 小时。"
}

openlist_record_site() (
  local domain=$1 server=$2 binary=$3 config=$4 port=$5 candidate
  candidate=$(state_candidate) || return 1
  trap 'rm -f -- "$candidate"' EXIT
  jq --arg domain "$domain" --arg server "$server" --arg binary "$binary" --arg config "$config" --argjson port "$port" '
    .openlist.sites=((.openlist.sites // [] | map(select(.domain!=$domain))) +
      [{domain:$domain,server:$server,binary:$binary,config:$config,port:$port}])
  ' "$SBM_STATE" >"$candidate" || return 1
  state_validate "$candidate" || return 1
  state_update_timestamp "$candidate" || return 1
  safe_install_file "$candidate" "$SBM_STATE" 0600
)

openlist_cert_reload() {
  local domain=$1 site binary config
  [[ -s "$SBM_STATE" ]] || return 0
  site=$(jq -c --arg domain "$domain" 'first(.openlist.sites[]? | select(.domain==$domain and .server=="nginx")) // empty' "$SBM_STATE") || return 1
  [[ -n "$site" ]] || return 0
  service_active nginx.service || return 0
  binary=$(jq -r '.binary' <<<"$site") || return 1
  config=$(jq -r '.config' <<<"$site") || return 1
  "$binary" -t -c "$config" >"$SBM_RUN/openlist-cert-reload.log" 2>&1 || return 1
  openlist_web_reload nginx
}

openlist_proxy_context() {
  local server=$1 allow_proxy443=${2:-false} binary config pid args owners row port flags prefix
  require_command "$server"
  service_active "$server.service" || { log_error "请先安装并启动 $server 网站服务。"; return 1; }
  binary=$(command -v "$server") || return 1
  if [[ "$server" == caddy ]]; then config=/etc/caddy/Caddyfile
  else config=$("$binary" -V 2>&1 | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p'); fi
  # Nginx can keep its old workers after a failed asynchronous reload.
  # Reject port owners up front and verify the new HTTPS vhost after reload.
  owners=$(ss -H -ltnp) || return 1
  pid=''
  for port in 80 443; do
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      if [[ "$row" != *"\"$server\""* ]]; then
        if [[ "$port" == 443 && "$allow_proxy443" == true ]]; then continue; fi
        log_error "TCP/$port 已被其他程序占用，未修改网站。"; return 1
      fi
      pid=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' <<<"$row") || return 1
    done < <(awk -v port="$port" '$4 ~ (":" port "$")' <<<"$owners")
  done
  if [[ $(init_system) == systemd ]]; then
    pid=$(systemctl show "$server.service" -p MainPID --value) || return 1
  fi
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { log_error '无法确认网站服务的实际进程。'; return 1; }
  binary=$(readlink -f "/proc/$pid/exe") || return 1
  args=$(tr '\0' '\n' <"/proc/$pid/cmdline") || return 1
  if [[ "$server" == caddy ]]; then
    grep -Fxq "$config" <<<"$args" || { log_error 'Caddy 使用自定义配置，无法自动添加网站。'; return 1; }
    if grep -Eq '^--(resume|watch|envfile)(=|$)' <<<"$args"; then
      log_error 'Caddy 使用自定义启动参数，无法自动添加网站。'; return 1
    fi
    flags=$(awk '$0=="--adapter" {getline; print} /^--adapter=/ {sub(/^--adapter=/, ""); print}' <<<"$args") || return 1
    [[ -z "$flags" || "$flags" == caddyfile ]] || { log_error '只支持 Caddyfile 网站配置。'; return 1; }
  else
    # OpenRC may expose a worker PID with no master arguments. Require the
    # master cmdline as well; a custom -c/-p is never silently ignored.
    if [[ "$args" == *'nginx: worker process'* ]]; then
      pid=$(awk '$1=="PPid:" {print $2}' "/proc/$pid/status") || return 1
      args=$(tr '\0' '\n' <"/proc/$pid/cmdline") || return 1
    fi
    config=$("$binary" -V 2>&1 | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p') || return 1
    flags=$(tr '\n' ' ' <<<"$args" | awk '{for(i=1;i<=NF;i++) if($i=="-c") print $(i+1); else if($i ~ /^-c.+/) print substr($i,3)}') || return 1
    [[ -z "$flags" || "$flags" == "$config" ]] || { log_error 'Nginx 使用自定义配置，无法自动添加网站。'; return 1; }
    flags=$(tr '\n' ' ' <<<"$args" | awk '{for(i=1;i<=NF;i++) if($i=="-p") print $(i+1); else if($i ~ /^-p.+/) print substr($i,3)}') || return 1
    prefix=$("$binary" -V 2>&1 | sed -n 's/.*--prefix=\([^ ]*\).*/\1/p') || return 1
    [[ -z "$flags" || "${flags%/}" == "${prefix%/}" ]] || { log_error 'Nginx 使用自定义前缀，无法自动添加网站。'; return 1; }
  fi
  [[ -x "$binary" && -s "$config" ]] || return 1
  printf '%s\n%s\n' "$binary" "$config"
}

openlist_site_ready() {
  local domain=$1 attempt response
  for ((attempt=0; attempt<20; attempt++)); do
    response=$(curl --noproxy '*' --resolve "$domain:443:127.0.0.1" -fsS --connect-timeout 1 --max-time 2 "https://$domain/ping" 2>/dev/null || true)
    [[ "$response" == pong ]] && return 0
    sleep 1
  done
  log_error '新 OpenList HTTPS 入口未就绪，请确认域名解析、证书和网站监听设置。'
  return 1
}

_openlist_setup() {
  local domain=$1 server=$2 backup port binary config
  local -a context=()
  openlist_require_runtime || return 1
  # Existing mux transactions own the website configuration. Avoid creating
  # entries that their later rollback would silently remove.
  if website_mux_managed; then log_error '请先解除已有网站分流，再添加 OpenList 网站。'; return 1; fi
  mapfile -t context < <(openlist_proxy_context "$server")
  (( ${#context[@]} == 2 )) || return 1
  binary=${context[0]}; config=${context[1]}
  website_mux_require_python || return 1
  if [[ "$server" == nginx ]] && ! cert_usable "$domain"; then
    [[ -s "$SBM_CF_DNS_ENV" ]] || { log_error 'Nginx 网站需要证书，请先配置 sb cert setup-cloudflare。'; return 1; }
    _state_transaction_run openlist-certificate _cert_prepare_node_domain "$domain" || return 1
  fi
  if [[ ! -x "$SBM_OPENLIST_BIN" ]]; then
    _openlist_install || return 1
  else
    [[ -L "$SBM_OPENLIST_BIN" && $(readlink -f "$SBM_OPENLIST_BIN") == "$SBM_CORE_DIR/openlist/"* ]] || {
      log_error '现有 OpenList 不属于本项目管理，拒绝接入。'; return 1;
    }
    jq -e '.scheme.address=="127.0.0.1" and .scheme.https_port==-1' "$SBM_OPENLIST_DATA/config.json" >/dev/null || {
      log_error 'OpenList 监听设置已改变，请先运行 sb openlist update 恢复本机监听。'; return 1;
    }
    service_start "$SBM_OPENLIST_SERVICE" && openlist_ready "$(openlist_port)" || return 1
  fi
  port=$(openlist_port) || return 1
  mkdir -p "$SBM_BACKUPS/openlist" || return 1
  backup=$(mktemp -d "$SBM_BACKUPS/openlist/site-$(now_stamp).XXXXXX") || return 1
  chmod 0700 "$backup" || return 1
  if ! python3 "$SBM_LIB/libexec/openlist_proxy.py" prepare "$server" "$binary" "$config" "$domain" "$port" "$SBM_CERTS/$domain/fullchain.pem" "$SBM_CERTS/$domain/key.pem" "$backup"; then
    openlist_keep_recovery "$backup"
    log_error 'OpenList 网站配置未完成。'; return 1
  fi
  if ! openlist_web_reload "$server" || ! openlist_site_ready "$domain" || ! openlist_record_site "$domain" "$server" "$binary" "$config" "$port"; then
    if python3 "$SBM_LIB/libexec/openlist_proxy.py" rollback "$backup" && openlist_web_reload "$server"; then
      rm -rf -- "$backup" || return 1
    else
      openlist_keep_recovery "$backup"
      log_error '网站恢复未完成。'
    fi
    return 1
  fi
  rm -rf -- "$backup" || return 1
  log_ok "OpenList 网站已配置：https://$domain"
}

openlist_setup() {
  require_root
  local domain=${1,,} server=${2:-caddy}
  domain=${domain%.}
  validate_domain "$domain" || usage_die "无效域名：$domain"
  case "$server" in caddy|nginx) ;; *) usage_die '网站程序只能是 caddy 或 nginx。';; esac
  with_lock _openlist_setup "$domain" "$server"
}

openlist_forget_site() (
  local domain=$1 candidate
  candidate=$(state_candidate) || return 1
  trap 'rm -f -- "$candidate"' EXIT
  jq --arg domain "$domain" '.openlist.sites |= map(select(.domain!=$domain))' "$SBM_STATE" >"$candidate" || return 1
  state_validate "$candidate" && state_update_timestamp "$candidate" || return 1
  safe_install_file "$candidate" "$SBM_STATE" 0600
)

_openlist_detach() {
  local domain=$1 site server binary config port backup active=false
  if jq -e --arg domain "$domain" '.reality_site.enabled==true and .reality_site.domain==$domain' "$SBM_STATE" >/dev/null; then
    log_error '此网站仍由 Reality 入口使用；请先运行 sb reality detach，再移除 OpenList 网站。'
    return 1
  fi
  site=$(jq -c --arg domain "$domain" 'first(.openlist.sites[]? | select(.domain==$domain)) // empty' "$SBM_STATE") || return 1
  [[ -n "$site" ]] || { log_error '此域名未登记为 OpenList 网站。'; return 1; }
  website_mux_managed && { log_error '请先解除网站分流，再移除 OpenList 网站。'; return 1; }
  server=$(jq -r '.server' <<<"$site"); binary=$(jq -r '.binary' <<<"$site")
  config=$(jq -r '.config' <<<"$site"); port=$(jq -r '.port' <<<"$site")
  website_mux_require_python || return 1
  service_active "$server.service" && active=true
  mkdir -p "$SBM_BACKUPS/openlist" || return 1
  backup=$(mktemp -d "$SBM_BACKUPS/openlist/detach-$(now_stamp).XXXXXX") || return 1
  chmod 0700 "$backup" || return 1
  python3 "$SBM_LIB/libexec/openlist_proxy.py" detach "$server" "$binary" "$config" "$domain" "$port" "$SBM_CERTS/$domain/fullchain.pem" "$SBM_CERTS/$domain/key.pem" "$backup" || { openlist_keep_recovery "$backup"; return 1; }
  if { [[ "$active" != true ]] || openlist_web_reload "$server"; } && openlist_forget_site "$domain"; then
    rm -rf -- "$backup" || return 1
    log_ok "已移除 OpenList 网站入口：$domain；数据已保留。"
  else
    python3 "$SBM_LIB/libexec/openlist_proxy.py" rollback "$backup" || { openlist_keep_recovery "$backup"; return 1; }
    [[ "$active" != true ]] || openlist_web_reload "$server" || { openlist_keep_recovery "$backup"; return 1; }
    rm -rf -- "$backup" || return 1
    return 1
  fi
}

openlist_detach() {
  require_root
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '移除网站不接受 --dry-run。'
  local domain=${1,,}
  domain=${domain%.}
  validate_domain "$domain" || usage_die '无效网站域名。'
  with_lock _openlist_detach "$domain"
}

openlist_detach_all() {
  local domain
  [[ -s "$SBM_STATE" ]] || return 0
  while IFS= read -r domain; do
    openlist_detach "$domain" || return 1
  done < <(jq -r '.openlist.sites[]?.domain' "$SBM_STATE")
}

openlist_status() {
  if [[ ! -x "$SBM_OPENLIST_BIN" ]]; then printf 'OpenList：未安装\n'; return 0; fi
  printf 'OpenList：%s\n服务：%s\n本机地址：127.0.0.1:%s\n数据目录：%s\n' "$(openlist_current_version || printf '未知版本')" "$(status_service_state "$SBM_OPENLIST_SERVICE")" "$(openlist_port || printf '未知')" "$SBM_OPENLIST_DATA"
  [[ ! -s "$SBM_STATE" ]] || jq -r '.openlist.sites[]? | "网站：https://\(.domain) / \(.server)"' "$SBM_STATE"
}
