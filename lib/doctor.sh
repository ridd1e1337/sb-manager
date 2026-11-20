#!/usr/bin/env bash
# shellcheck shell=bash

check_line() {
  local level=$1
  shift
  case "$level" in
    PASS) printf '%s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*" ;;
    WARN) printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" ;;
    FAIL) printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" ;;
  esac
}

# Kept as a compatibility shim for callers that source doctor.sh directly;
# the full implementation is provided by lib/status.sh when the CLI starts.
status_summary() {
  if declare -F status_show >/dev/null 2>&1; then
    status_show
    return $?
  fi
  local sb_ver cf_ver nodes enabled certs mode backend service_state mux_state mux_port traffic_count
  sb_ver=$(core_current_version || true); cf_ver=$(cloudflared_current_version || true)
  nodes=$(jq '.nodes|length' "$SBM_STATE"); enabled=$(state_enabled_count); certs=$(jq '.certificates|length' "$SBM_STATE")
  mode=$(jq -r '.tunnel.mode' "$SBM_STATE"); mux_state=$(jq -r '.nginx_stream.enabled // false' "$SBM_STATE"); mux_port=$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")
  traffic_count=$(jq '[.nodes[]? | select(.traffic.enabled==true)] | length' "$SBM_STATE"); backend=$(init_system_label)
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then service_state='不接管服务'
  elif ! state_runtime_required; then service_state='待机（无启用节点）'
  elif service_active "$SBM_SERVICE"; then service_state='运行中'; else service_state='未运行'; fi
  printf '%sSB Manager %s%s\n' "$C_BOLD" "$SBM_VERSION" "$C_RESET"
  printf '服务管理      : %s\n' "$backend"
  printf 'sing-box     : %s (%s)\n' "${sb_ver:-未安装}" "$service_state"
  printf 'cloudflared  : %s (Tunnel: %s)\n' "${cf_ver:-未安装}" "$mode"
  printf '节点          : %s 个，启用 %s 个\n' "$nodes" "$enabled"
  printf '证书          : %s 个\n' "$certs"
  printf 'TCP/SNI 复用 : %s (%s/TCP, %s)\n' "$([[ "$mux_state" == true ]] && echo '启用' || echo '停用')" "$mux_port" "$(mux_backend_label)"
  printf '流量控制      : %s 个节点\n' "$traffic_count"
}

show_logs() {
  local target=${1:-all} lines=${2:-100}
  [[ "$SBM_SKIP_INIT" != 1 ]] || { log_warn '未接管服务管理器，无法读取服务日志。'; return $?; }
  case "$target" in
    singbox|core) service_logs "$SBM_SERVICE" "$lines" 0 ;;
    tunnel|cloudflared) service_logs "$SBM_TUNNEL_SERVICE" "$lines" 0 ;;
    mux) service_logs "$(mux_service)" "$lines" 0 ;;
    nginx|nginx-stream) service_logs "$SBM_NGINX_STREAM_SERVICE" "$lines" 0 ;;
    all)
      printf '%s\n' '---- sing-box ----'
      service_logs "$SBM_SERVICE" "$lines" 0 || true
      printf '%s\n' '---- cloudflared ----'
      service_logs "$SBM_TUNNEL_SERVICE" "$lines" 0 || true
      if mux_uses_nginx; then
        printf '%s\n' '---- nginx stream ----'
        service_logs "$SBM_NGINX_STREAM_SERVICE" "$lines" 0 || true
      fi
      ;;
    follow)
      if [[ $(init_system) == systemd ]]; then
        local -a journal_args=()
        mapfile -t journal_args < <(maintenance_journal_args)
        journalctl "${journal_args[@]}" -u "$SBM_SERVICE" -u "$SBM_TUNNEL_SERVICE" -u "$SBM_NGINX_STREAM_SERVICE" --since '-24 hours' -f
      else service_logs "$SBM_SERVICE" "$lines" 1; fi
      ;;
    *) die '日志目标应为 all、singbox、tunnel、mux、nginx 或 follow。' ;;
  esac
}
