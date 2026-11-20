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
SystemMaxUse=4M
RuntimeMaxUse=2M
SystemMaxFileSize=1M
RuntimeMaxFileSize=512K
MaxFileSec=15min
MaxRetentionSec=23h
ForwardToSyslog=no
EOF_JOURNAL
  if [[ ! -f "$SBM_JOURNAL_CONFIG" ]] || ! cmp -s "$temporary" "$SBM_JOURNAL_CONFIG"; then
    chmod 0644 "$temporary" && mv -f "$temporary" "$SBM_JOURNAL_CONFIG" || return 1
    systemctl try-restart systemd-journald@sb-manager.service >/dev/null 2>&1 || true
  else rm -f "$temporary"; fi
  for unit in "$SBM_SERVICE" "$SBM_OPENLIST_SERVICE" "$SBM_TUNNEL_SERVICE" "$SBM_NGINX_STREAM_SERVICE" \
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

maintenance_operation_active() {
  local pid
  pid=$(cat "$1/.operation-pid" 2>/dev/null || true)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
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
      case "$name" in caddy-build.*|caddy-download.*|sing-box.*|xray.*|openlist.*|acme.*|cloudflared.*|backup.*|restore.*) rm -rf -- "$path" || return 1;; esac
    done < <(find "$SBM_CACHE" -mindepth 1 -maxdepth 1 -mmin +1380 -print0)
  fi
  if [[ -d "$SBM_DOWNLOAD_TMP" && ! -L "$SBM_DOWNLOAD_TMP" ]]; then
    while IFS= read -r -d '' path; do
      rm -rf -- "$path" || return 1
    done < <(find "$SBM_DOWNLOAD_TMP" -mindepth 1 -maxdepth 1 -type d \( -name 'sb-manager-openlist.*' -o -name 'sb-manager-sing-box.*' \) -mmin +1380 -print0)
  fi
  # Only operation-created recovery directories have this marker. User-made
  # .tar.gz/.age backups are never selected by automatic maintenance.
  if [[ -d "$SBM_BACKUPS" && ! -L "$SBM_BACKUPS" ]]; then
    while IFS= read -r -d '' path; do
      maintenance_operation_active "$(dirname "$path")" && continue
      rm -rf -- "$(dirname "$path")" || return 1
    done < <(find "$SBM_BACKUPS" -mindepth 2 -maxdepth 4 -type f -name .recovery-pending -mmin +1380 -print0)
    while IFS= read -r -d '' path; do
      [[ ! -f "$path/.recovery-pending" ]] || continue
      maintenance_operation_active "$path" && continue
      rm -rf -- "$path" || return 1
    done < <(find "$SBM_BACKUPS" -mindepth 1 -maxdepth 1 -type d -name 'config-current.*' -mmin +1380 -print0)
    if [[ ${SBM_PROGRAM_BACKUP_RETENTION:-0} == 0 ]]; then
      for path in "$SBM_BACKUPS"/program-*; do
        [[ -d "$path" && ! -L "$path" && ! -f "$path/.recovery-pending" ]] || continue
        maintenance_operation_active "$path" && continue
        rm -rf -- "$path" || return 1
      done
    fi
  fi
  if [[ -d "$SBM_RUN" && ! -L "$SBM_RUN" ]]; then
    for path in "$SBM_RUN"/reality-setup.* "$SBM_RUN"/reality-detach.*; do
      [[ -d "$path" && ! -L "$path" && -f "$path/.recovery-pending" ]] || continue
      maintenance_operation_active "$path" && continue
      modified=$(stat -c %Y "$path/.recovery-pending") || return 1
      (( now - modified >= 82800 )) || continue
      rm -rf -- "$path" || return 1
    done
  fi
  if [[ -d "${SBM_VPS_INIT_DIR:-$SBM_VAR/vps-init}" && ! -L "${SBM_VPS_INIT_DIR:-$SBM_VAR/vps-init}" ]]; then
    for path in "${SBM_VPS_INIT_DIR:-$SBM_VAR/vps-init}"/*; do
      [[ -d "$path" && ! -L "$path" && "${path##*/}" =~ ^[0-9]{8}T[0-9]{6}Z\.[A-Za-z0-9]+$ ]] || continue
      maintenance_operation_active "$path" && continue
      if [[ -f "$path/.recovery-pending" ]]; then
        modified=$(stat -c %Y "$path/.recovery-pending") || return 1
        (( now - modified >= 82800 )) || continue
      fi
      rm -rf -- "$path" || return 1
    done
  fi
  for directory in "$SBM_LOG_DIR" "$SBM_OPENLIST_LOG_DIR"; do
    [[ -d "$directory" && ! -L "$directory" && "$directory" != / && "$directory" != /var/log ]] || continue
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
      if (( now - epoch >= 84600 )) || (( $(stat -c %s "$path") > 1048576 )); then
        maintenance_truncate_log "$path" || return 1
        epoch=$now
      fi
      temporary=$(mktemp "$SBM_MAINTENANCE_DIR/.epochs.XXXXXX") || return 1
      jq --arg path "$path" --arg inode "$inode" --argjson epoch "$epoch" \
        '.[$path]={inode:$inode,epoch:$epoch}' "$epochs" >"$temporary" || return 1
      chmod 0600 "$temporary" && mv -f "$temporary" "$epochs" || return 1
    done < <(find "$directory" -maxdepth 1 -type f \( -name '*.log' -o -name '*.err' \) -print0)
    find "$directory" -maxdepth 1 -type f \( -name '*.gz' -o -name '*.log.[0-9]*' -o -name '*.err.[0-9]*' \) -mmin +1380 -delete || return 1
  done
  for directory in "$SBM_RUN" "$SBM_VAR/updates" "$SBM_WEBSITE_MUX_DIR"; do
    [[ -d "$directory" && ! -L "$directory" && "$directory" != / ]] || continue
    find "$directory" -maxdepth 1 -type f -name '*.log' -mmin +1380 -delete || return 1
    while IFS= read -r -d '' path; do
      (( $(stat -c %s "$path") <= 1048576 )) || maintenance_truncate_log "$path" || return 1
    done < <(find "$directory" -maxdepth 1 -type f -name '*.log' -print0)
  done
  if [[ -d "$SBM_BACKUPS/openlist" && ! -L "$SBM_BACKUPS/openlist" ]]; then
    find "$SBM_BACKUPS/openlist" -mindepth 2 -maxdepth 2 -type f -name '*.log' -mmin +1380 -delete || return 1
    if declare -F openlist_prune >/dev/null 2>&1; then openlist_prune || return 1; fi
  fi
  if [[ -f "$SBM_JOURNAL_CONFIG" ]] && maintenance_namespace_supported \
    && systemctl is-active --quiet systemd-journald@sb-manager.service; then
    journalctl --namespace=sb-manager --rotate --vacuum-time=23h --vacuum-size=4M >/dev/null 2>&1 || return 1
  fi
  # Active website baselines may still refer to a binary after a frontend
  # transition. The Caddy helper keeps those references, without old releases.
  if declare -F caddy_prune_versions >/dev/null 2>&1; then caddy_prune_versions || return 1; fi
  if declare -F snapshot_prune >/dev/null 2>&1; then snapshot_prune || return 1; fi
  if declare -F core_prune_cached_versions >/dev/null 2>&1; then core_prune_cached_versions || return 1; fi
  if declare -F cloudflared_prune_cached_versions >/dev/null 2>&1; then cloudflared_prune_cached_versions || return 1; fi
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
  if declare -F vless_cache_prune >/dev/null 2>&1; then vless_cache_prune; fi
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
  printf '项目文件日志：最长约 24 小时，单文件达到 1 MiB 后清理（每 15 分钟维护）。\n'
  if maintenance_namespace_supported; then
    printf 'systemd 项目日志：独立 sb-manager 空间，23 小时、总量 4 MiB。\n'
  else
    printf 'OpenRC 使用项目文件日志；systemd 245 之前的系统日志沿用宿主机策略。\n'
  fi
  printf '自动操作成功即删除临时恢复资料；恢复未完成的资料最多保留 23 小时。\n'
  printf '默认仅保留当前核心；证书、凭据、节点数据、活动网站配置与手动备份保留。\n'
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
