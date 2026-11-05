#!/usr/bin/env bash
# shellcheck shell=bash

SBM_VPS_INIT_DIR="${SBM_VPS_INIT_DIR:-$SBM_VAR/vps-init}"
SBM_VPS_FAIL2BAN_CONFIG="${SBM_VPS_FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/99-sb-manager-vps.local}"

vps_ssh_ports() {
  local port
  {
    printf '22\n'
    firewall_detect_ssh_ports
    # An override must never hide the port of the current SSH connection.
    [[ -z ${SSH_CONNECTION:-} ]] || awk '{print $4}' <<<"$SSH_CONNECTION"
  } | while IFS= read -r port; do
    validate_port "$port" && printf '%s\n' "$port"
  done | sort -nu
}

vps_ufw_active() {
  command_exists ufw && LC_ALL=C ufw status 2>/dev/null | grep -Fx 'Status: active' >/dev/null
}

vps_init_supported() {
  case "$1:$2" in debian:systemd|alpine:openrc) return 0;; *) return 1;; esac
}

vps_system_support() {
  local distro backend
  distro=$(dependency_distro)
  backend=$(init_system 2>/dev/null || true)
  printf '当前环境：%s / %s；包管理器分支：%s；服务管理：%s\n\n' \
    "$(uname -s)" "$(uname -m)" "$distro" "${backend:-未检测到}"
  cat <<'EOF_SYSTEMS'
sing-box 安装与节点管理：
  Debian / Ubuntu       apt      systemd
  Alpine                apk      OpenRC
  Fedora / Rocky / Alma  dnf/yum  systemd
  Arch                  pacman   systemd
  openSUSE              zypper   systemd

新 VPS 一键初始化（Caddy + UFW + Fail2ban）：
  Debian / Ubuntu + systemd、Alpine + OpenRC。
  需要已配置的软件源提供三个组件；Alpine 需要 community 源。
  其他发行版可使用节点管理，但此初始化入口暂不执行。

Nginx / Caddy 网站共用 443：需要兼容的网站配置和 systemd/OpenRC 服务。
Nginx stream 模块仅在 Debian/Ubuntu、Alpine 自动补装；其他系统需先安装匹配模块。
BBR、流量计数等功能还取决于内核支持和主机权限；普通容器不等同于完整 VPS。
EOF_SYSTEMS
  if vps_init_supported "$distro" "$backend"; then
    printf '\n当前环境符合新 VPS 初始化的系统范围；执行时仍会检查端口、组件和防火墙。\n'
  else
    printf '\n当前环境不在新 VPS 初始化范围内；查看此说明不会安装软件或修改系统。\n'
  fi
}

vps_init_plan() {
  printf '新 VPS 初始化：安装并启用 Caddy、UFW、Fail2ban。\n'
  printf '  入站放行：22/TCP、80/TCP、443/TCP、443/UDP。\n'
  printf '  保留 SSH：%s/TCP（包含当前 SSH 连接端口）。\n' "$(vps_ssh_ports | paste -sd, -)"
  printf '  新启用 UFW：默认拒绝入站、允许出站；保留已有规则。\n'
  printf '  SSH 防护：复用已有 sshd jail；没有时配置 10 分钟失败 5 次封禁 1 小时。\n'
  printf '  保留现有 Caddy 网站和 SSH 登录配置；不自动放行其他节点端口。\n'
  printf '  支持 Debian/Ubuntu + systemd、Alpine + OpenRC。\n'
}

vps_init_status() {
  local json=${1:-0} caddy=false ufw=false fail2ban=false data
  service_active caddy.service && caddy=true
  vps_ufw_active && ufw=true
  if command_exists fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then fail2ban=true; fi
  data=$(jq -n --argjson caddy "$caddy" --argjson ufw "$ufw" --argjson fail2ban "$fail2ban" \
    --argjson caddy_installed "$(command_exists caddy && echo true || echo false)" \
    --argjson ufw_installed "$(command_exists ufw && echo true || echo false)" \
    --argjson f2b_installed "$(command_exists fail2ban-client && echo true || echo false)" \
    --argjson ports "$(vps_ssh_ports | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)')" \
    '{caddy:{installed:$caddy_installed,active:$caddy},ufw:{installed:$ufw_installed,active:$ufw},
      fail2ban:{installed:$f2b_installed,sshd_active:$fail2ban},ssh_ports:$ports}') || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$data"; return 0; fi
  jq -r '"Caddy：\(if .caddy.active then "运行中" elif .caddy.installed then "已安装，未运行" else "未安装" end)",
    "UFW：\(if .ufw.active then "已启用" elif .ufw.installed then "未启用" else "未安装" end)",
    "Fail2ban SSH：\(if .fail2ban.sshd_active then "防护已启用" elif .fail2ban.installed then "未启用" else "未安装" end)",
    "SSH 端口：\(.ssh_ports|map(tostring)|join(","))"' <<<"$data"
}

vps_service_snapshot() {
  local backup=$1 unit active enabled
  for unit in caddy fail2ban ufw syslog; do
    active=false; enabled=false
    service_active "$unit.service" && active=true
    service_enabled "$unit.service" && enabled=true
    jq -n --argjson active "$active" --argjson enabled "$enabled" \
      '{active:$active,enabled:$enabled}' >"$backup/$unit-service.json" || return 1
  done
}

vps_init_rollback() {
  local backup=$1 unit active enabled rc=0
  log_error "初始化未完成，正在恢复本次配置；备份：$backup"
  if [[ -f "$backup/ufw-touched" ]]; then
    if LC_ALL=C ufw --force disable >"$backup/ufw-rollback.log" 2>&1; then
      cp -a "$backup/ufw/." /etc/ufw/ || rc=1
      cp -a "$backup/default-ufw" /etc/default/ufw || rc=1
      if [[ -f "$backup/ufw-was-active" ]]; then
        LC_ALL=C ufw --force enable >>"$backup/ufw-rollback.log" 2>&1 || rc=1
      fi
    else rc=1; fi
  fi
  if [[ -f "$backup/fail2ban-touched" ]]; then
    if [[ -f "$backup/previous-jail" ]]; then cp -a "$backup/previous-jail" "$SBM_VPS_FAIL2BAN_CONFIG" || rc=1
    else rm -f -- "$SBM_VPS_FAIL2BAN_CONFIG" || rc=1; fi
  fi
  if [[ -f "$backup/caddy-config-created" ]]; then rm -f /etc/caddy/Caddyfile || rc=1; fi
  for unit in fail2ban caddy syslog ufw; do
    [[ -f "$backup/$unit-service-touched" ]] || continue
    active=$(jq -r '.active' "$backup/$unit-service.json") || { rc=1; continue; }
    enabled=$(jq -r '.enabled' "$backup/$unit-service.json") || { rc=1; continue; }
    if [[ "$enabled" == true ]]; then service_enable "$unit.service" || rc=1
    else service_disable "$unit.service" || rc=1; fi
    # UFW's live rules are restored above, independently of its oneshot unit.
    [[ "$unit" != ufw ]] || continue
    if [[ "$active" == true ]]; then
      if [[ "$unit" == fail2ban && ( -f "$backup/fail2ban-touched" || -f "$backup/ufw-touched" ) ]]; then service_restart "$unit.service" || rc=1
      else service_active "$unit.service" || service_start "$unit.service" || rc=1; fi
    else service_stop "$unit.service" || rc=1; fi
  done
  (( rc == 0 )) || log_error "部分恢复未完成，请查看 $backup；已安装的软件包会保留。"
  return "$rc"
}

vps_init_caddy() {
  local backup=$1 tmp
  if service_active caddy.service; then
    service_enable caddy.service || return 1
    log_info '复用现有 Caddy 服务和网站配置。'
    return 0
  fi
  if [[ ! -e /etc/caddy/Caddyfile && ! -L /etc/caddy/Caddyfile ]]; then
    mkdir -p /etc/caddy || return 1
    tmp=$(mktemp /etc/caddy/.vps-caddy.XXXXXX) || return 1
    printf ':80 {\n\trespond "No website configured." 200\n}\n' >"$tmp" || return 1
    chmod 0644 "$tmp" || return 1
    touch "$backup/caddy-config-created" || return 1
    mv -f "$tmp" /etc/caddy/Caddyfile || return 1
  fi
  if ! caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >"$backup/caddy-check.log" 2>&1; then
    log_error "Caddy 配置无效；请查看 $backup/caddy-check.log。"; return 1
  fi
  service_enable caddy.service && service_start caddy.service || return 1
  service_wait_active caddy.service 20 2
}

vps_init_ssh_log() {
  local backup=$1 unit logger_active=0 i
  [[ $(init_system) == openrc ]] || return 0
  for unit in syslog rsyslog syslog-ng; do
    service_active "$unit.service" && logger_active=1
  done
  if (( logger_active == 0 )); then
    touch "$backup/syslog-service-touched" || return 1
    if ! service_exists syslog.service; then dependency_install_packages busybox-syslog || return 1; fi
    service_enable syslog.service && service_start syslog.service || return 1
  fi
  for ((i=0; i<10; i++)); do
    [[ -f /var/log/auth.log || -f /var/log/secure || -f /var/log/messages ]] && return 0
    sleep 0.5
  done
  log_error '未找到可供 Fail2ban 读取的 SSH 日志，请先配置系统日志服务。'; return 1
}

vps_init_fail2ban() {
  local backup=$1 ports=$2 stage candidate client_ip='' i
  if [[ -f "$backup/fail2ban-sshd-was-active" ]] && fail2ban-client status sshd >/dev/null 2>&1; then
    service_enable "$SBM_FAIL2BAN_SERVICE" || return 1
    # UFW activation may rebuild filter chains. Reinstall Fail2ban actions
    # after that, retaining the operator's jail configuration and ban DB.
    service_restart "$SBM_FAIL2BAN_SERVICE" || return 1
    for ((i=0; i<20; i++)); do
      if fail2ban-client status sshd >/dev/null 2>&1; then
        log_info '复用已有 Fail2ban SSH 防护规则。'
        return 0
      fi
      sleep 0.5
    done
    log_error '已有 Fail2ban SSH jail 重启后未就绪。'; return 1
  fi
  vps_init_ssh_log "$backup" || return 1
  [[ "$SBM_VPS_FAIL2BAN_CONFIG" == /etc/fail2ban/jail.d/99-sb-manager-vps.local ]] || {
    log_error 'VPS 初始化需要使用标准 Fail2ban jail.d 路径。'; return 1;
  }
  stage="$backup/fail2ban-candidate"
  mkdir -p "$stage" || return 1
  cp -a /etc/fail2ban/. "$stage/" || return 1
  mkdir -p "$stage/jail.d" || return 1
  candidate="$stage/jail.d/99-sb-manager-vps.local"
  [[ -z ${SSH_CONNECTION:-} ]] || client_ip=$(awk '{print $1}' <<<"$SSH_CONNECTION")
  if ! validate_ipv4 "$client_ip" && ! validate_ipv6 "$client_ip"; then client_ip=''; fi
  {
    printf '[sshd]\nenabled = true\nfilter = sshd\nport = %s\n' "$(paste -sd, - <<<"$ports")"
    firewall_fail2ban_log_config "$(init_system)"
    printf 'findtime = 600\nmaxretry = 5\nbantime = 3600\nbanaction = iptables-multiport\naction = %%(action_)s\n'
    printf 'ignoreip = 127.0.0.1/8 ::1 %s\n' "$client_ip"
  } >"$candidate" || return 1
  if ! fail2ban-client -c "$stage" -t >"$backup/fail2ban-check.log" 2>&1; then
    log_error "Fail2ban 候选配置无效；请查看 $backup/fail2ban-check.log。"; return 1
  fi
  [[ ! -e "$SBM_VPS_FAIL2BAN_CONFIG" ]] || cp -a "$SBM_VPS_FAIL2BAN_CONFIG" "$backup/previous-jail" || return 1
  touch "$backup/fail2ban-touched" || return 1
  mkdir -p /etc/fail2ban/jail.d || return 1
  safe_install_file "$candidate" "$SBM_VPS_FAIL2BAN_CONFIG" 0644 || return 1
  service_enable "$SBM_FAIL2BAN_SERVICE" || return 1
  if service_active "$SBM_FAIL2BAN_SERVICE"; then service_restart "$SBM_FAIL2BAN_SERVICE" || return 1
  else service_start "$SBM_FAIL2BAN_SERVICE" || return 1; fi
  for ((i=0; i<20; i++)); do
    fail2ban-client status sshd >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  log_error 'Fail2ban SSH jail 未能启动。'; return 1
}

vps_init_ufw() {
  local backup=$1 ports=$2 port
  LC_ALL=C ufw status >"$backup/ufw-before.status" 2>&1 || { log_error '无法访问 UFW/内核防火墙，初始化已停止。'; return 1; }
  vps_ufw_active && touch "$backup/ufw-was-active"
  cp -a /etc/ufw "$backup/ufw" || return 1
  cp -a /etc/default/ufw "$backup/default-ufw" || return 1
  touch "$backup/ufw-touched" "$backup/ufw-service-touched" || return 1
  # Put SSH ahead of any existing blanket deny before enabling or reloading.
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    LC_ALL=C ufw insert 1 allow "$port/tcp" >/dev/null || return 1
  done <<<"$ports"
  for port in 80/tcp 443/tcp 443/udp; do
    LC_ALL=C ufw insert 1 allow "$port" >/dev/null || return 1
  done
  if [[ ! -f "$backup/ufw-was-active" ]]; then
    LC_ALL=C ufw default deny incoming >/dev/null || return 1
    LC_ALL=C ufw default allow outgoing >/dev/null || return 1
  fi
  LC_ALL=C ufw --force enable >"$backup/ufw-enable.log" 2>&1 || { log_error "UFW 启用失败：$backup/ufw-enable.log"; return 1; }
  service_enable ufw.service || return 1
  vps_ufw_active || return 1
  LC_ALL=C ufw status verbose
}

_vps_init() (
  local distro backend ports listeners line backup complete=0 rc unit
  require_init_system || return 1
  backend=$(init_system) || return 1
  distro=$(dependency_distro) || return 1
  vps_init_supported "$distro" "$backend" || { log_error '新 VPS 初始化目前支持 Debian/Ubuntu systemd 与 Alpine OpenRC；sb vps systems 可查看各功能的系统范围。'; return 1; }
  if service_active firewalld.service; then log_error 'firewalld 正在运行，不能同时启用 UFW。'; return 1; fi
  dependency_require_feature probe || return 1
  ports=$(vps_ssh_ports) || return 1
  [[ -n "$ports" ]] || return 1
  listeners=$(ss -H -ltnp '( sport = :80 or sport = :443 )') || return 1
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == *'"caddy"'* ]] || { log_error '80/443 已被其他程序占用；这是新 VPS 初始化入口，请先处理端口冲突。'; return 1; }
  done <<<"$listeners"
  mkdir -p "$SBM_VPS_INIT_DIR" || return 1
  chmod 0700 "$SBM_VPS_INIT_DIR" || return 1
  backup=$(mktemp -d "$SBM_VPS_INIT_DIR/$(now_stamp).XXXXXX") || return 1
  chmod 0700 "$backup"
  vps_service_snapshot "$backup" || return 1
  if command_exists fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
    touch "$backup/fail2ban-sshd-was-active" || return 1
  fi
  trap 'rc=$?; trap - EXIT; if [[ "$complete" != 1 ]]; then vps_init_rollback "$backup" || true; fi; exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  # Include services before package installation: Debian packages may start
  # their services in postinst even when later configuration fails.
  touch "$backup/caddy-service-touched" "$backup/fail2ban-service-touched" || return 1
  local -a packages=()
  command_exists caddy || packages+=(caddy)
  command_exists ufw || packages+=(ufw)
  command_exists fail2ban-client || packages+=(fail2ban)
  if [[ "$distro" == debian ]]; then
    if ! /usr/bin/python3 -c 'import systemd.journal' >/dev/null 2>&1; then packages+=(python3-systemd); fi
  else
    for unit in caddy ufw fail2ban; do service_exists "$unit.service" || packages+=("$unit-openrc"); done
  fi
  dependency_install_packages "${packages[@]}" || return 1
  service_reload_manager || return 1
  for unit in caddy ufw fail2ban; do service_exists "$unit.service" || { log_error "安装后缺少 $unit 服务定义。"; return 1; }; done
  command_exists caddy && command_exists ufw && command_exists fail2ban-client || { log_error '组件安装不完整。'; return 1; }
  vps_init_caddy "$backup" || return 1
  vps_init_ufw "$backup" "$ports" || return 1
  vps_init_fail2ban "$backup" "$ports" || return 1
  local report
  report=$(mktemp "$SBM_VPS_INIT_DIR/.last.XXXXXX") || return 1
  jq -n --arg at "$(now_iso)" --arg version "$SBM_VERSION" --arg backup "$backup" \
    --argjson ports "$(jq -Rsc 'split("\n")|map(select(length>0)|tonumber)' <<<"$ports")" \
    '{completed_at:$at,manager_version:$version,backup:$backup,ssh_ports:$ports,components:["caddy","ufw","fail2ban"]}' >"$report" || return 1
  chmod 0600 "$report" && mv -f "$report" "$SBM_VPS_INIT_DIR/last.json" || return 1
  complete=1
  log_ok '新 VPS 初始化完成：Caddy、UFW、Fail2ban 已就绪。'
  log_info "配置备份：$backup；已有规则保留，其他节点端口不会自动放行。"
)

vps_init() {
  require_root
  vps_init_plan
  [[ ${1:-${SBM_DRY_RUN:-0}} != 1 ]] || return 0
  with_lock _vps_init
}

vps_cli() {
  local action=${1:-status} dry_run=${SBM_DRY_RUN:-0} json=${SBM_OUTPUT_JSON:-0}
  (($# == 0)) || shift
  while (($#)); do
    case "$1" in --dry-run) dry_run=1;; --json) json=1;; --yes|-y) ;; *) usage_die '用法：sb vps init [--dry-run] | status [--json] | systems';; esac
    shift
  done
  if [[ "$action" == systems ]]; then
    [[ "$json" == 0 ]] || usage_die '系统支持说明不接受 --json。'
    vps_system_support
    return
  fi
  require_root; require_command jq
  case "$action" in
    init) [[ "$json" == 0 ]] || usage_die '初始化不接受 --json。'; vps_init "$dry_run";;
    status) vps_init_status "$json";;
    *) usage_die '用法：sb vps init [--dry-run] | status [--json] | systems';;
  esac
}
