#!/usr/bin/env bash
# shellcheck shell=bash

SBM_MAINTENANCE_DIR="${SBM_MAINTENANCE_DIR:-$SBM_VAR/maintenance}"
SBM_JOURNAL_CONFIG="${SBM_JOURNAL_CONFIG:-$(dirname "$SBM_SYSTEMD_DIR")/journald@sb-manager.conf}"

maintenance_namespace_supported() {
  local version
  command_exists systemctl || return 1
  version=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}') || return 1
  [[ "$version" =~ ^[0-9]+$ ]] && (( version >= 245 ))
}

maintenance_journal_units() {
  maintenance_namespace_supported || return 0
  local unit file temporary
  if [[ -e "$SBM_JOURNAL_CONFIG" ]] && { [[ -L "$SBM_JOURNAL_CONFIG" ]] || ! grep -q '^# Managed by sb-manager;' "$SBM_JOURNAL_CONFIG"; }; then
    log_error '专属 journal 配置已由其他工具管理，拒绝覆盖。'; return 1
  fi
  mkdir -p "$(dirname "$SBM_JOURNAL_CONFIG")" || return 1
  temporary=$(mktemp "${SBM_JOURNAL_CONFIG}.XXXXXX") || return 1
  cat >"$temporary" <<'EOF_JOURNAL'
# Managed by sb-manager; applies only to its own journal namespace.
[Journal]
Storage=persistent
SystemMaxUse=16M
RuntimeMaxUse=8M
SystemMaxFileSize=2M
RuntimeMaxFileSize=1M
MaxFileSec=15min
MaxRetentionSec=23h
ForwardToSyslog=no
EOF_JOURNAL
  if [[ ! -f "$SBM_JOURNAL_CONFIG" ]] || ! cmp -s "$temporary" "$SBM_JOURNAL_CONFIG"; then
    chmod 0644 "$temporary" && mv -f "$temporary" "$SBM_JOURNAL_CONFIG" || return 1
    systemctl try-restart systemd-journald@sb-manager.service >/dev/null 2>&1 || true
  else rm -f "$temporary"; fi
  for unit in "$SBM_SERVICE" "$SBM_TUNNEL_SERVICE" "$SBM_NGINX_STREAM_SERVICE" \
    "$SBM_SUBSCRIPTION_SERVICE" "${SBM_SUBSTORE_SERVICE:-sb-substore.service}" "$SBM_TRAFFIC_SERVICE" \
    "$SBM_HEALTH_SERVICE" sb-core-update.service sb-manager-update.service sb-acme-renew.service \
    sb-quick-tunnel-refresh.service sb-traffic-sync.service sb-maintenance.service; do
    file="$SBM_SYSTEMD_DIR/$unit"
    [[ -f "$file" && ! -L "$file" ]] || continue
    if ! grep -q '^LogNamespace=' "$file"; then
      printf '\n[Service]\nLogNamespace=sb-manager\n' >>"$file" || return 1
    fi
  done
}

maintenance_journal_args() {
  if [[ -f "$SBM_JOURNAL_CONFIG" ]] && maintenance_namespace_supported; then
    printf '%s\n' '--namespace=+sb-manager'
  fi
}

maintenance_truncate_log() {
  # Log directories can be writable by the low-privilege service account.
  # O_NOFOLLOW prevents a symlink swap from redirecting root's truncation.
  dd if=/dev/null of="$1" bs=1 count=0 conv=nocreat oflag=nofollow,nonblock status=none
}

maintenance_safe_cache_root() {
  local path
  path=$(readlink -m "$SBM_CACHE") || return 1
  case "$path" in /|/etc|/usr|/usr/local|/var|/var/lib|/var/log|/run|/tmp|/root|"$SBM_ETC"|"$SBM_VAR"|"$SBM_SECRETS"|"$SBM_CERTS") return 1;; esac
  [[ -d "$SBM_CACHE" && ! -L "$SBM_CACHE" ]]
}

_maintenance_run() {
  local path name temporary epochs now epoch inode saved_inode modified born directory
  now=$(date +%s)
  mkdir -p "$SBM_MAINTENANCE_DIR" || return 1
  chmod 0700 "$SBM_MAINTENANCE_DIR" || return 1
  epochs="$SBM_MAINTENANCE_DIR/log-epochs.json"
  [[ -f "$epochs" ]] || printf '{}\n' >"$epochs"
  chmod 0600 "$epochs"
  # Only known disposable download/build directories are eligible. Never
  # traverse state, exports, subscriptions, credentials or recovery journals.
  if maintenance_safe_cache_root; then
    while IFS= read -r -d '' path; do
      name=${path##*/}
      case "$name" in caddy-build.*|caddy-download.*|sing-box.*|acme.*|cloudflared.*) rm -rf -- "$path" || return 1;; esac
    done < <(find "$SBM_CACHE" -mindepth 1 -maxdepth 1 -mmin +1380 -print0)
  fi
  if [[ -d "$SBM_LOG_DIR" && ! -L "$SBM_LOG_DIR" && "$SBM_LOG_DIR" != / && "$SBM_LOG_DIR" != /var/log ]]; then
    while IFS= read -r -d '' path; do
      [[ ! -L "$path" ]] || continue
      inode=$(stat -c '%d:%i' "$path") || return 1
      modified=$(stat -c %Y "$path") || return 1
      saved_inode=$(jq -r --arg path "$path" '.[$path].inode // ""' "$epochs") || return 1
      epoch=$(jq -r --arg path "$path" '.[$path].epoch // 0' "$epochs") || return 1
      if [[ "$inode" != "$saved_inode" ]]; then
        born=$(stat -c %W "$path" 2>/dev/null || printf 0)
        if [[ "$born" =~ ^[1-9][0-9]*$ ]]; then epoch=$born; else epoch=$modified; fi
      fi
      if (( now - epoch >= 84600 )) || (( $(stat -c %s "$path") > 5242880 )); then
        maintenance_truncate_log "$path" || return 1
        epoch=$now
      fi
      temporary=$(mktemp "$SBM_MAINTENANCE_DIR/.epochs.XXXXXX") || return 1
      jq --arg path "$path" --arg inode "$inode" --argjson epoch "$epoch" \
        '.[$path]={inode:$inode,epoch:$epoch}' "$epochs" >"$temporary" || return 1
      chmod 0600 "$temporary" && mv -f "$temporary" "$epochs" || return 1
    done < <(find "$SBM_LOG_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name '*.err' \) -print0)
    find "$SBM_LOG_DIR" -maxdepth 1 -type f \( -name '*.gz' -o -name '*.log.[0-9]*' -o -name '*.err.[0-9]*' \) -mmin +1380 -delete || return 1
  fi
  for directory in "$SBM_RUN" "$SBM_VAR/updates" "$SBM_WEBSITE_MUX_DIR"; do
    [[ -d "$directory" && ! -L "$directory" && "$directory" != / ]] || continue
    find "$directory" -maxdepth 1 -type f -name '*.log' -mmin +1380 -delete || return 1
    while IFS= read -r -d '' path; do
      (( $(stat -c %s "$path") <= 5242880 )) || maintenance_truncate_log "$path" || return 1
    done < <(find "$directory" -maxdepth 1 -type f -name '*.log' -print0)
  done
  if [[ -f "$SBM_JOURNAL_CONFIG" ]] && maintenance_namespace_supported \
    && systemctl is-active --quiet systemd-journald@sb-manager.service; then
    journalctl --namespace=sb-manager --rotate --vacuum-time=23h --vacuum-size=16M >/dev/null 2>&1 || return 1
  fi
  # Versioned Caddy programs are not temporary cache: retain the running and
  # rollback binaries even when older than a day; reclaim only other versions.
  if [[ -d "$SBM_CADDY_STORE" && -s "$SBM_STATE" ]]; then
    while IFS= read -r -d '' path; do
      name=${path##*/}
      [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{16}$ ]] || continue
      if ! jq -e --arg target "$path/caddy" '.caddy.target==$target or .caddy.previous.target==$target
        or .nginx_stream.website.binary==$target or .nginx_stream.website.original_binary==$target' "$SBM_STATE" >/dev/null; then
        rm -rf -- "$path" || return 1
      fi
    done < <(find "$SBM_CADDY_STORE" -mindepth 1 -maxdepth 1 -type d -mmin +1380 -print0)
  fi
  now_iso >"$SBM_MAINTENANCE_DIR/last-run"
}

maintenance_run() (
  require_root
  ensure_runtime_dirs
  # Match update/setup -> manager lock order. Do not prune an installer or
  # an in-flight state transaction, even when a download is unusually slow.
  exec 7>"$SBM_RUN/manager-update.lock"
  flock -n 7 || { log_info '脚本更新正在运行，本轮清理跳过。'; return 0; }
  exec 8>"$SBM_RUN/setup.lock"
  flock -n 8 || { log_info '安装正在运行，本轮清理跳过。'; return 0; }
  with_lock _maintenance_run
)

maintenance_reconcile() {
  local start=${1:-1} unit timer job
  case "$(init_system)" in
    systemd)
      unit="$SBM_SYSTEMD_DIR/sb-maintenance.service"; timer="$SBM_SYSTEMD_DIR/sb-maintenance.timer"
      cat >"$unit" <<EOF_SERVICE
[Unit]
Description=Bound sb-manager temporary cache and logs
[Service]
Type=oneshot
UMask=0077
ExecStart=$SBM_BIN_DIR/sb maintenance run
TimeoutStartSec=5min
EOF_SERVICE
      cat >"$timer" <<'EOF_TIMER'
[Unit]
Description=Maintain sb-manager cache and one-day log retention
[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true
[Install]
WantedBy=timers.target
EOF_TIMER
      chmod 0644 "$unit" "$timer"
      service_reload_manager || return 1
      [[ "$start" != 1 ]] || systemctl enable --now sb-maintenance.timer
      ;;
    openrc)
      job="$SBM_PERIODIC_DIR/15min/sb-maintenance"
      mkdir -p "$(dirname "$job")" || return 1
      printf '#!/bin/sh\nexec "%s" maintenance run >/dev/null 2>&1\n' "$SBM_BIN_DIR/sb" >"$job"
      chmod 0755 "$job"
      [[ "$start" != 1 ]] || dependency_require_feature scheduler
      ;;
  esac
}

maintenance_status() {
  local scheduled='未启用'
  if [[ $(init_system 2>/dev/null || true) == systemd ]]; then
    service_active sb-maintenance.timer && scheduled='已启用'
  elif [[ -x "$SBM_PERIODIC_DIR/15min/sb-maintenance" ]] && service_active crond; then scheduled='已启用'; fi
  printf '定期维护：%s\n' "$scheduled"
  printf '临时下载/编译缓存：最长约 24 小时；成功下载/编译会立即清理。\n'
  printf '项目文件日志：最长约 24 小时，单文件上限 5 MiB（每 15 分钟维护）。\n'
  if maintenance_namespace_supported; then
    printf 'systemd 项目日志：独立 sb-manager 空间，23 小时、总量 16 MiB。\n'
  else
    printf 'OpenRC 使用项目文件日志；systemd 245 之前的系统日志沿用宿主机策略。\n'
  fi
  printf '保留：当前/回滚程序、证书、凭据、流量计数、规则与网站恢复记录。\n'
  [[ ! -f "$SBM_MAINTENANCE_DIR/last-run" ]] || printf '上次完成：%s\n' "$(cat "$SBM_MAINTENANCE_DIR/last-run")"
}

maintenance_cli() {
  local action=${1:-status}
  (($# <= 1)) || usage_die '用法：sb maintenance status|run'
  case "$action" in
    status) maintenance_status;;
    run) [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '清理不接受 --dry-run。'; maintenance_run;;
    *) usage_die '用法：sb maintenance status|run';;
  esac
}
