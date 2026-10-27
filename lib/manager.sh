#!/usr/bin/env bash
# shellcheck shell=bash

manager_update_lock() {
  require_command flock
  ensure_runtime_dirs
  exec 7>"$SBM_RUN/manager-update.lock"
  flock -n 7
}

manager_update() (
  if [[ ${1:-} != --check && ${SBM_DRY_RUN:-0} != 1 ]]; then
    require_root
    manager_update_lock || { log_error '已有脚本更新正在运行，请稍后重试。'; exit 1; }
  fi
  _manager_update 0 "$@"
)

manager_auto_enabled() {
  jq -e '.settings.manager_auto_update == true' "$SBM_STATE" >/dev/null 2>&1
}

manager_auto_time() {
  local slot
  slot=$(jq -er '.settings.manager_update_minute | select(type=="number" and floor==. and .>=0 and .<180)' "$SBM_STATE") || return 1
  printf '%02d:%02d\n' "$((3 + slot / 60))" "$((slot % 60))"
}

manager_auto_reconcile() {
  local start=${1:-1} backend time unit timer job job_mode=0644
  [[ ${NO_START:-0} != 1 ]] || start=0
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  backend=$(init_system) || return 1
  unit="$SBM_SYSTEMD_DIR/sb-manager-update.service"
  timer="$SBM_SYSTEMD_DIR/sb-manager-update.timer"
  job="$SBM_PERIODIC_DIR/15min/sb-manager-update"
  if ! manager_auto_enabled; then
    if [[ "$backend" == systemd && -f "$timer" ]]; then
      # Disabling future activations must not kill an installer in progress.
      systemctl disable --now sb-manager-update.timer || return 1
    fi
    rm -f "$unit" "$timer" "$job" || return 1
    [[ "$backend" != systemd ]] || service_reload_manager || return 1
    return 0
  fi
  time=$(manager_auto_time) || return 1
  case "$backend" in
    systemd)
      mkdir -p "$SBM_SYSTEMD_DIR" || return 1
      cat >"$unit" <<EOF_UNIT || return 1
[Unit]
Description=Update sb-manager scripts automatically
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
UMask=0077
ExecStart="$SBM_BIN_DIR/sb" update auto run --scheduled
TimeoutStartSec=infinity
EOF_UNIT
      cat >"$timer" <<EOF_TIMER || return 1
[Unit]
Description=Daily sb-manager script update

[Timer]
OnCalendar=*-*-* $time:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF_TIMER
      chmod 0644 "$unit" "$timer" || return 1
      rm -f "$job" || return 1
      service_reload_manager || return 1
      [[ "$start" != 1 ]] || systemctl enable --now sb-manager-update.timer || return 1
      ;;
    openrc)
      mkdir -p "$(dirname "$job")" || return 1
      if [[ "$start" == 1 || -x "$job" ]]; then job_mode=0755; fi
      cat >"$job" <<EOF_JOB || return 1
#!/usr/bin/env bash
exec $(printf '%q' "$SBM_BIN_DIR/sb") update auto run --scheduled
EOF_JOB
      chmod "$job_mode" "$job" || return 1
      rm -f "$unit" "$timer" || return 1
      if [[ "$start" == 1 ]]; then
        dependency_require_feature scheduler || return 1
        service_enable crond || return 1
        service_active crond || service_start crond || return 1
      fi
      ;;
    *) log_error '脚本自动更新需要 systemd 或 OpenRC。'; return 1;;
  esac
}

_manager_auto_set() {
  local enabled=$1 before candidate
  before=$(mktemp "$SBM_RUN/manager-policy-before.XXXXXX") || return 1
  candidate=$(state_candidate) || { rm -f "$before"; return 1; }
  cp "$SBM_STATE" "$before" || { rm -f "$before" "$candidate"; return 1; }
  if ! jq --argjson enabled "$enabled" '.settings.manager_auto_update=$enabled' "$SBM_STATE" >"$candidate" \
    || ! state_validate "$candidate" || ! state_update_timestamp "$candidate" \
    || ! safe_install_file "$candidate" "$SBM_STATE" 0600; then
    rm -f "$before" "$candidate"; return 1
  fi
  if ! manager_auto_reconcile; then
    safe_install_file "$before" "$SBM_STATE" 0600 || log_error '无法恢复自动更新设置。'
    manager_auto_reconcile || log_error '无法恢复自动更新调度器，请检查服务状态。'
    rm -f "$before" "$candidate"; return 1
  fi
  rm -f "$before" "$candidate"
  if [[ "$enabled" == true ]]; then
    log_ok "脚本自动更新已开启，每天约 $(manager_auto_time)（服务器本地时间）。"
  else log_ok '已停止后续脚本自动更新；正在进行的升级会完成。'; fi
}

manager_auto_status() {
  local enabled time scheduler=inactive backend record='null'
  enabled=$(jq '.settings.manager_auto_update' "$SBM_STATE") || return 1
  time=$(manager_auto_time) || return 1
  backend=$(init_system 2>/dev/null || true)
  case "$backend" in
    systemd) if systemctl is-active --quiet sb-manager-update.timer; then scheduler=active; fi;;
    openrc) if [[ -x "$SBM_PERIODIC_DIR/15min/sb-manager-update" ]] && service_active crond; then scheduler=active; fi;;
  esac
  [[ ! -f "$SBM_VAR/updates/manager.json" ]] || record=$(jq . "$SBM_VAR/updates/manager.json") || return 1
  if [[ ${1:-0} == 1 ]]; then
    jq -n --argjson enabled "$enabled" --arg time "$time" --arg scheduler "$scheduler" --argjson last "$record" \
      '{enabled:$enabled,local_time:$time,scheduler:$scheduler,last_attempt:$last}'
    return
  fi
  printf '脚本自动更新：%s\n每日时间：%s（服务器本地时间；OpenRC 最多延后 15 分钟）\n调度器：%s\n' \
    "$([[ "$enabled" == true ]] && printf '开启' || printf '关闭')" "$time" "$scheduler"
  if [[ "$record" != null ]]; then
    jq -r '"最近尝试：\(.started_at)；结果：\(.result)；退出码：\(.exit_code // "-")"' <<<"$record"
  fi
  printf '最近日志：%s/updates/manager.log\n' "$SBM_VAR"
}

manager_auto_record() {
  local day=$1 started=$2 result=$3 rc=$4 tmp
  tmp=$(mktemp "$SBM_VAR/updates/.manager.XXXXXX") || return 1
  if ! jq -n --arg day "$day" --arg started "$started" --arg finished "$(now_iso)" \
    --arg result "$result" --argjson rc "$rc" --arg version "$(cat "$SBM_LIB/VERSION")" \
    '{day:$day,started_at:$started,finished_at:(if $result=="started" then null else $finished end),result:$result,exit_code:$rc,installed_version:$version}' >"$tmp"; then
    rm -f "$tmp"; return 1
  fi
  chmod 0600 "$tmp" && mv -f "$tmp" "$SBM_VAR/updates/manager.json" || { rm -f "$tmp"; return 1; }
}

manager_auto_run() (
  require_root
  require_command jq
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '自动更新执行不支持 --dry-run；可使用 sb update --check。'
  local scheduled=${1:-0} day started slot hour minute last='' rc=0
  manager_auto_enabled || { [[ "$scheduled" == 1 ]] || log_info '自动更新已关闭；立即手动更新可运行 sb update。'; exit 0; }
  manager_update_lock || { log_info '已有脚本更新正在运行，本次跳过。'; exit 0; }
  manager_auto_enabled || exit 0
  day=$(date +%F)
  if [[ "$scheduled" == 1 ]]; then
    slot=$(jq -er '.settings.manager_update_minute | select(type=="number" and floor==. and .>=0 and .<180)' "$SBM_STATE") || exit 1
    hour=$(date +%H); minute=$(date +%M)
    (( 10#$hour * 60 + 10#$minute >= 180 + slot )) || exit 0
    [[ ! -f "$SBM_VAR/updates/manager.json" ]] || last=$(jq -r '.day // ""' "$SBM_VAR/updates/manager.json") || exit 1
    [[ "$last" != "$day" ]] || exit 0
  fi
  mkdir -p "$SBM_VAR/updates" || exit 1
  chmod 0700 "$SBM_VAR/updates" || exit 1
  started=$(now_iso)
  # Persist the attempt before downloading: a failure or interruption is not
  # retried every 15 minutes. An operator can explicitly run it again.
  manager_auto_record "$day" "$started" started null || exit 1
  if [[ -f "$SBM_VAR/updates/manager.log" ]]; then
    mv -f "$SBM_VAR/updates/manager.log" "$SBM_VAR/updates/manager.previous.log" || exit 1
  fi
  umask 077
  printf '%s 自动检查管理器脚本更新\n' "$started" >"$SBM_VAR/updates/manager.log" || exit 1
  log_info "正在检查脚本更新，详情：$SBM_VAR/updates/manager.log"
  if _manager_update 1 >>"$SBM_VAR/updates/manager.log" 2>&1; then
    manager_auto_record "$day" "$started" success 0 || exit 1
    log_ok "脚本更新检查完成，当前版本：$(cat "$SBM_LIB/VERSION")。"
  else
    rc=$?
    manager_auto_record "$day" "$started" failed "$rc" || exit 1
    log_error "脚本自动更新失败，详情：$SBM_VAR/updates/manager.log"
  fi
  exit "$rc"
)

manager_update_cli() {
  if [[ ${1:-} != auto ]]; then manager_update "$@"; return; fi
  shift
  local action=${1:-status} json=${SBM_OUTPUT_JSON:-0} scheduled=0
  (($# == 0)) || shift
  case "$action" in
    run)
      if [[ ${1:-} == --scheduled ]]; then scheduled=1; shift; fi
      (($# == 0)) || usage_die '用法：sb update auto run'
      manager_auto_run "$scheduled";;
    status|enable|disable)
      require_root
      if [[ "$action" == status && ${1:-} == --json ]]; then json=1; shift; fi
      (($# == 0)) || usage_die '用法：sb update auto status [--json] | enable | disable'
      if [[ "$action" != status && ${SBM_DRY_RUN:-0} == 1 ]]; then usage_die '自动更新开关不支持 --dry-run。'; fi
      state_init 0
      case "$action" in
        status) manager_auto_status "$json";;
        enable) with_lock _manager_auto_set true;;
        disable) with_lock _manager_auto_set false;;
      esac;;
    *) usage_die '用法：sb update auto enable|disable|status|run';;
  esac
}

_manager_update() (
  set -Eeuo pipefail
  local automatic=$1 check_only=0 repository current='' latest response stage
  shift
  case "${1:-}" in
    --check) check_only=1; shift ;;
    '') ;;
    *) usage_die '用法：sb update [--check]' ;;
  esac
  (($# == 0)) || usage_die '用法：sb update [--check]'
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || check_only=1
  if (( ! check_only )); then
    require_root
  fi
  require_command curl
  require_command jq
  repository=${SBM_INSTALL_REPOSITORY:-}
  if [[ -z "$repository" && -r "$SBM_LIB/INSTALL_REPOSITORY" ]]; then
    repository=$(cat "$SBM_LIB/INSTALL_REPOSITORY")
    case "$repository" in
      R1ddle1337/sb-manager|wugan666/sb-manager) repository=ridd1e1337/sb-manager ;;
    esac
  fi
  repository=${repository:-ridd1e1337/sb-manager}
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die '无效的 GitHub 仓库名。'
  [[ ! -r "$SBM_LIB/INSTALL_COMMIT" ]] || current=$(cat "$SBM_LIB/INSTALL_COMMIT")
  printf '当前脚本：%s（commit：%s）\n' "$SBM_VERSION" "${current:-未记录}"
  response=$(curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: sb-manager' "https://api.github.com/repos/$repository/commits/main") \
    || die '检查脚本更新失败，请检查 GitHub 网络连接后重试。'
  latest=$(jq -er '.sha | select(type=="string" and test("^[0-9a-fA-F]{40}$"))' <<<"$response") \
    || die 'GitHub 未返回有效的脚本 commit。'
  if [[ "$current" == "$latest" ]]; then
    printf '脚本已经是最新版本。\n'
    exit 0
  fi
  printf '可更新至 commit：%s\n' "$latest"
  (( ! check_only )) || { printf '执行 sb update 更新脚本；当前核心和节点将保留。\n'; exit 0; }
  [[ -x "$SBM_SING_BOX_BIN" ]] || die '未找到已安装核心；请重新运行安装器。'
  if [[ "$automatic" == 1 ]] && ! manager_auto_enabled; then
    log_info '自动更新已关闭，本次不安装。'; exit 0
  fi
  stage=$(mktemp -d) || exit 1
  trap 'rm -rf -- "$stage"' EXIT
  # Run a private copy: setup replaces the installed scripts during upgrade.
  cp "$SBM_LIB/install.sh" "$stage/install.sh" || exit 1
  printf '正在更新脚本，保留当前核心、节点、密钥和证书；服务可能短暂重启。\n'
  SBM_INSTALL_REPOSITORY="$repository" SBM_INSTALL_REF="$latest" \
    bash "$stage/install.sh" --no-menu --keep-core 7>&- || exit "$?"
  printf '脚本更新完成：%s。\n' "$(cat "$SBM_LIB/VERSION")"
)
