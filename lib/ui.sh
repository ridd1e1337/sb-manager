#!/usr/bin/env bash
# shellcheck shell=bash

ui_pause() {
  local reply
  [[ -t 0 ]] || return 206
  while true; do
    printf '\n按 Enter 返回主菜单；输入 r 留在当前菜单：'
    read -r reply || return 201
    case "$reply" in
      ''|0|q) return 206;;
      r|R) return 0;;
      *) log_error '请按 Enter 返回主菜单，或输入 r 留在当前菜单。';;
    esac
  done
}
ui_clear() { [[ -t 1 && -n ${TERM:-} && ${TERM:-} != dumb ]] && command_exists clear && clear || true; }

# Worker return codes: back, session exit, uninstalled, reload, cancel, redraw,
# and return to the main menu (200–206).
# A fresh Bash process preserves errexit; wrapping functions in `if` or `||`
# would disable it inside the backend and could let failed actions continue.
ui_worker_allowed() {
  case "$1" in
    ui_issue_certificate|ui_node_finish_menu|node_share|ui_add_node|ui_manage_nodes|ui_share_export_menu|ui_client_export_menu|ui_cert_menu|ui_tunnel_menu|ui_update_menu|ui_manager_auto_menu|ui_api_menu|ui_realm_menu|ui_doctor_menu|ui_uninstall_menu|ui_backup_menu|ui_nginx_stream_menu|ui_settings_menu|ui_tcp_tuning_menu|ui_template_menu|ui_firewall_menu|ui_notification_health_menu|ui_traffic_menu|ui_network_benchmark_menu|ui_traffic_group_menu|ui_shaping_menu|ui_tunnel_routes_menu|ui_substore_menu|ui_config_menu|ui_dns_menu|ui_bbr_menu|ui_hy2_buffer_menu|ui_outbound_menu|ui_substore_sources_menu|ui_subscription_menu|status_summary|show_logs) return 0;;
    *) return 1;;
  esac
}

ui_worker() {
  local fn=${1:-}
  [[ ${SBM_UI_WORKER:-0} == 1 ]] && ui_worker_allowed "$fn" || usage_die '无效的面板操作。'
  shift
  "$fn" "$@"
  [[ ${SBM_UNINSTALLED:-0} != 1 ]] || exit 202
}

ui_run() {
  local rc=0
  local -a flags=()
  [[ ${SBM_ASSUME_YES:-0} != 1 ]] || flags+=(--yes)
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || flags+=(--dry-run)
  [[ ${SBM_QUIET:-0} != 1 ]] || flags+=(--quiet)
  [[ -z ${NO_COLOR:-} ]] || flags+=(--no-color)
  SBM_UI_WORKER=1 SBM_LIB="$SBM_LIB" bash "$SBM_LIB/sb" "${flags[@]}" __ui-step "$@" || rc=$?
  SBM_UI_LAST_STATUS=$rc
}

ui_reload() {
  local -a flags=()
  [[ ${SBM_ASSUME_YES:-0} != 1 ]] || flags+=(--yes)
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || flags+=(--dry-run)
  [[ ${SBM_QUIET:-0} != 1 ]] || flags+=(--quiet)
  [[ -z ${NO_COLOR:-} ]] || flags+=(--no-color)
  unset SBM_VERSION
  exec bash "$SBM_LIB/sb" "${flags[@]}"
}

ui_end_session() {
  if [[ ${SBM_UI_WORKER:-0} == 1 ]]; then exit "$1"; fi
  SBM_UI_RESULT=$1
}

ui_menu_loop() {
  local pause_rc
  while true; do
    ui_run "$@"
    case "$SBM_UI_LAST_STATUS" in
      200) return 0;;
      201|202|203|206) ui_end_session "$SBM_UI_LAST_STATUS"; return 0;;
      204|205) continue;;
      0) ;;
      *) log_warn "操作未完成（退出码 $SBM_UI_LAST_STATUS），请检查上方提示后重试。";;
    esac
    pause_rc=0
    ui_pause || pause_rc=$?
    if [[ "$pause_rc" != 0 ]]; then ui_end_session "$pause_rc"; return 0; fi
  done
}

ui_open_submenu() {
  ui_menu_loop "$@"
  [[ ${SBM_UI_WORKER:-0} != 1 ]] || exit 205
}

ui_menu_choice() {
  local __ui_max=${3:-} __ui_value
  while true; do
    # Menu navigation never accepts an action merely because Enter was pressed.
    prompt_value "$1" "$2（Enter / 0 返回）" '0' || return 1
    __ui_value=${!1}
    if [[ ${SBM_UI_WORKER:-0} == 1 && "$__ui_value" == 0 ]]; then exit 200; fi
    if [[ -z "$__ui_max" ]] || { [[ "$__ui_value" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( __ui_value <= __ui_max )); }; then return 0; fi
    log_error "选择无效，请输入 0–$__ui_max。"
  done
}

ui_cancel() {
  [[ ${SBM_UI_WORKER:-0} != 1 ]] || exit 204
  return 1
}

ui_prompt_optional() {
  prompt_value "$1" "$2（输入 - 清空）" "${3:-}" || return 1
  [[ ${!1} != - ]] || printf -v "$1" '%s' ''
}

ui_page_back() {
  [[ ${SBM_UI_WORKER:-0} != 1 ]] || exit 200
  return 0
}

# All selectors write to the caller's variable; no eval or shell interpolation.
ui_select_json() {
  local __ui_var=$1 __ui_label=$2 __ui_items=$3 __ui_default=${4:-} __ui_new=${5:-0}
  local __ui_choice __ui_id __ui_index __ui_count
  __ui_count=$(jq 'length' <<<"$__ui_items") || return 1
  if (( __ui_count == 0 )); then
    [[ "$__ui_new" == 1 ]] || { log_warn "没有可选的${__ui_label}。"; return 1; }
    prompt_value "$__ui_var" "新建${__ui_label} ID（留空返回）" '' || return 1
    [[ -n ${!__ui_var} ]] || return 1
    return
  fi
  __ui_index=$(jq -r --arg id "$__ui_default" 'to_entries|map(select(.value.id==$id))|if length>0 then (.[0].key+1|tostring) else empty end' <<<"$__ui_items")
  while true; do
    jq -r 'to_entries[]|"\(.key+1). \(.value.label // .value.id)"' <<<"$__ui_items"
    [[ -z "$__ui_index" ]] || printf '当前/推荐选项：%s（需输入编号选择）\n' "$__ui_index"
    [[ "$__ui_new" != 1 ]] || printf 'n. 新建\n'
    printf 'm. 手动输入 ID\n0. 返回（直接按 Enter）\n'
    prompt_value __ui_choice "选择${__ui_label}" '0' || return 1
    case "$__ui_choice" in
      0) return 1;;
      n)
        [[ "$__ui_new" == 1 ]] || { log_error '选择无效'; continue; }
        prompt_value "$__ui_var" "新建${__ui_label} ID（留空返回）" '' || return 1
        [[ -n ${!__ui_var} ]] || return 1
        return;;
      m)
        prompt_value __ui_id "${__ui_label} ID（留空返回）" '' || return 1
        [[ -n "$__ui_id" ]] || return 1;;
      *)
        if [[ "$__ui_choice" =~ ^[1-9][0-9]{0,5}$ ]] && (( __ui_choice <= __ui_count )); then
          __ui_id=$(jq -r --argjson i "$((__ui_choice-1))" '.[$i].id' <<<"$__ui_items")
        else __ui_id=$__ui_choice; fi;;
    esac
    if jq -e --arg id "$__ui_id" 'any(.[];.id==$id)' <<<"$__ui_items" >/dev/null; then
      printf -v "$__ui_var" '%s' "$__ui_id"; return 0
    fi
    log_error '没有匹配的选项，请重新选择。'
  done
}

ui_select_group() {
  local items
  items=$(jq '[.traffic_groups[]?|{id,label:(.id+"（"+(.nodes|join(","))+"）")}]' "$SBM_STATE") || return 1
  ui_select_json "$1" '配额组' "$items" "${2:-}" "${3:-0}"
}

ui_select_members() {
  local __ui_var=$1 __ui_default=${2:-} __ui_data __ui_choice __ui_token __ui_id __ui_valid __ui_joined
  local -a __ui_tokens __ui_selected
  local -A __ui_seen
  __ui_data=$(jq '[.nodes[]?|{id,label:(.id+"（"+.name+"）")}]' "$SBM_STATE") || return 1
  [[ $(jq 'length' <<<"$__ui_data") != 0 ]] || { log_warn '当前没有节点。'; return 1; }
  while true; do
    jq -r 'to_entries[]|"\(.key+1). \(.value.label)"' <<<"$__ui_data"
    [[ -z "$__ui_default" ]] || printf 'k. 保留当前成员（%s）\n' "$__ui_default"
    printf '0. 返回（直接按 Enter）\n'
    prompt_value __ui_choice '选择成员（编号或 ID，以逗号分隔）' '0' || return 1
    [[ "$__ui_choice" != 0 ]] || return 1
    if [[ "$__ui_choice" == k && -n "$__ui_default" ]]; then __ui_choice=$__ui_default; fi
    IFS=, read -r -a __ui_tokens <<<"$__ui_choice"
    __ui_selected=(); __ui_seen=(); __ui_valid=1
    for __ui_token in "${__ui_tokens[@]}"; do
      __ui_token=${__ui_token//[[:space:]]/}
      __ui_id=$__ui_token
      if [[ "$__ui_token" =~ ^[1-9][0-9]{0,5}$ ]] && (( __ui_token <= $(jq 'length' <<<"$__ui_data") )); then
        __ui_id=$(jq -r --argjson i "$((__ui_token-1))" '.[$i].id' <<<"$__ui_data")
      fi
      if [[ -z "$__ui_id" ]] || ! jq -e --arg id "$__ui_id" 'any(.[];.id==$id)' <<<"$__ui_data" >/dev/null; then __ui_valid=0; break; fi
      if [[ -z ${__ui_seen[$__ui_id]+x} ]]; then __ui_selected+=("$__ui_id"); __ui_seen[$__ui_id]=1; fi
    done
    if [[ "$__ui_valid" == 1 && ${#__ui_selected[@]} -gt 0 ]]; then
      __ui_joined=$(IFS=,; printf '%s' "${__ui_selected[*]}")
      printf -v "$__ui_var" '%s' "$__ui_joined"; return 0
    fi
    log_error '成员选择无效，请重新输入。'
  done
}

ui_interfaces_json() {
  local path name state
  for path in "${SBM_UI_NET_DIR:-/sys/class/net}"/*; do
    [[ -e "$path" ]] || continue
    name=${path##*/}; [[ "$name" != lo ]] || continue
    state=$(cat "$path/operstate" 2>/dev/null || printf 'unknown')
    jq -cn --arg id "$name" --arg display "$name ($state)" '{id:$id,label:$display}'
  done | jq -s .
}

ui_select_interface() {
  local items preferred=${2:-}
  items=$(ui_interfaces_json) || return 1
  if [[ -z "$preferred" ]] && command_exists ip; then
    preferred=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}') || true
  fi
  ui_select_json "$1" '出口网卡' "$items" "$preferred"
}

ui_select_benchmark() {
  local __ui_data=$2 __ui_reference=${3:-} __ui_rows
  if [[ -n "$__ui_reference" ]]; then
    __ui_data=$(jq --arg id "$__ui_reference" '
      (.[]|select(.id==$id)) as $base |
      map(select(.id!=$id and ([.target,.port,.seconds,.streams,.direction]==[$base.target,$base.port,$base.seconds,$base.streams,$base.direction])))' <<<"$__ui_data") || return 1
  fi
  __ui_rows=$(jq '[.[]|{id,label:(.id+" "+.target+":"+(.port|tostring)+" "+.direction+" "+(.streams|tostring)+"连接 "+(.seconds|tostring)+"s "+((.bits_per_second/1000000*100|round)/100|tostring)+" Mbps")}]' <<<"$__ui_data") || return 1
  ui_select_json "$1" '测速记录' "$__ui_rows"
}

ui_proxy_address_default() {
  local address
  case "$1" in
    127.0.0.1|::1) printf '%s\n' "$1";;
    0.0.0.0|::)
      address=$(ui_client_address_default '') || return 1
      case "$address" in 127.*|::1|localhost|0.0.0.0|::) address='';; esac
      printf '%s\n' "$address";;
    *) return 1;;
  esac
}
ui_header() {
  local service_state enabled mux_state traffic_count notify_state health_state
  ui_clear
  enabled=$(state_enabled_count)
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then
    service_state='不接管服务'
  elif ! state_runtime_required; then
    service_state='待机'
  elif service_active "$SBM_SERVICE"; then
    service_state='运行中'
  else
    service_state='未运行'
  fi
  printf '%s╭──────────────────── sb-manager ────────────────────╮%s\n' "$C_CYAN" "$C_RESET"
  printf '  版本 %-18s sing-box %-16s\n' "$SBM_VERSION" "$(core_current_version || echo '-')"
  printf '  服务管理 %-16s\n' "$(init_system_label)"
  printf '  服务 %-18s Tunnel %-18s\n' "$service_state" "$(jq -r '.tunnel.mode' "$SBM_STATE")"
  mux_state=$(jq -r 'if .nginx_stream.enabled then ((.nginx_stream.port|tostring) + "/TCP") else "off" end' "$SBM_STATE")
  printf '  TCP/SNI 复用 %-36s\n' "$mux_state"
  traffic_count=$(jq '[.nodes[]? | select(.traffic.enabled==true)] | length' "$SBM_STATE")
  printf '  流量控制 %-36s\n' "${traffic_count} 个节点"
  notify_state=$(jq -r 'if .notifications.enabled then .notifications.provider else "off" end' "$SBM_STATE")
  health_state=$(jq -r 'if .health.enabled then "on" else "off" end' "$SBM_STATE")
  printf '  通知 %-18s 健康检查 %-16s\n' "$notify_state" "$health_state"
  printf '%s╰─────────────────────────────────────────────────────╯%s\n\n' "$C_CYAN" "$C_RESET"
}

ui_select_node() {
  local __var=$1 allow_all=${2:-0} selected_id choice node i
  local -a ids=()
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    selected_id=$(jq -r '.id' <<<"$node")
    ids+=("$selected_id")
    printf '%d. %s | %s | %s | ID: %s\n' "${#ids[@]}" "$(jq -r '.name' <<<"$node")" \
      "$(node_protocol_label "$(jq -r '.protocol' <<<"$node")")" \
      "$(jq -r '(if .enabled then "启用" else "停用" end)+" / "+(.port|tostring)' <<<"$node")" "$selected_id"
  done < <(state_list_nodes)
  ((${#ids[@]} > 0)) || { log_warn '当前没有节点。'; return 1; }
  [[ "$allow_all" == 1 ]] && printf 'a. 全部节点\n'
  printf 'm. 输入 ID\n0. 返回（直接按 Enter）\n'
  # Returning from a node page redraws this list. An empty selection must not
  # reopen the first node or repeat its share/export action.
  prompt_value choice '选节点（编号或 ID）' '0' || return 1
  case "$choice" in
    0) return 1;;
    a|A)
      [[ "$allow_all" == 1 ]] || { log_error '选择无效'; return 1; }
      selected_id=all
      ;;
    m|M)
      prompt_value selected_id '输入节点 ID（留空返回）' '' || return 1
      [[ -n "$selected_id" ]] || return 1
      ;;
    * )
      if [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#ids[@]} )); then
        selected_id=${ids[$((choice - 1))]}
      else
        selected_id=$choice
      fi
      ;;
  esac
  [[ "$selected_id" == all ]] || state_node_exists "$selected_id" || { log_error "节点不存在：$selected_id"; return 1; }
  printf -v "$__var" '%s' "$selected_id"
}

ui_client_address_default() {
  local domain=${1:-} ipv4 fallback
  [[ -n "$domain" ]] && { printf '%s\n' "$domain"; return 0; }
  fallback=$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")
  [[ -n "$fallback" ]] && { printf '%s\n' "$fallback"; return 0; }
  ipv4=$(jq -r '.settings.public_ipv4 // ""' "$SBM_STATE")
  [[ -n "$ipv4" ]] || ipv4=$(detect_public_ipv4 2>/dev/null || true)
  printf '%s\n' "$ipv4"
}

ui_certificate_usable() {
  local domain=$1
  validate_domain "$domain" || return 1
  [[ -s "$SBM_CERTS/$domain/fullchain.pem" && -s "$SBM_CERTS/$domain/key.pem" ]] || return 1
  openssl x509 -in "$SBM_CERTS/$domain/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 \
    && openssl x509 -in "$SBM_CERTS/$domain/fullchain.pem" -noout -checkhost "$domain" >/dev/null 2>&1
}

ui_require_certificate() {
  ui_certificate_usable "$1" || { log_error "证书 $1 不完整、已过期或域名不匹配。"; return 1; }
}

ui_issue_certificate() {
  local domain=$1 reset_credentials=${2:-0}
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '证书申请不支持 --dry-run；请退出预览模式后再操作。'
  validate_domain "$domain" || die "无效域名：$domain"
  if ui_certificate_usable "$domain"; then log_info "复用现有证书：$domain"; return; fi
  printf '\n正在为 %s 准备证书。域名需由 Cloudflare 托管 DNS。\n' "$domain"
  printf '用于连接节点的 DNS 记录应指向本机公网 IP，并关闭橙云代理。\n'
  if [[ "$reset_credentials" == 1 || ! -s "$SBM_CF_DNS_ENV" || -z $(jq -r '.settings.acme_email // ""' "$SBM_STATE") ]]; then
    printf '首次需要 Cloudflare API Token（区域读取、DNS 编辑权限）和邮箱；保存后后续复用。\n'
    cert_setup_cloudflare
  fi
  cert_issue "$domain"
  ui_require_certificate "$domain"
}

ui_select_certificate_domain() {
  local __var=$1 choice selected_domain days i cert_domain reset_credentials=0
  local -a domains=()
  while IFS= read -r cert_domain; do
    [[ -n "$cert_domain" ]] || continue
    domains+=("$cert_domain")
  done < <(jq -r '[.certificates[]?.domain] | unique[]' "$SBM_STATE")

  while true; do
    if ((${#domains[@]} == 0)); then
      printf '没有证书：输入域名即可申请。\n'
      prompt_value selected_domain '域名（留空返回）' '' || return 1
    else
      printf '选择证书，或输入 n 使用新域名：\n'
      for ((i=0; i<${#domains[@]}; i++)); do
        selected_domain=${domains[$i]}
        if ui_certificate_usable "$selected_domain"; then
          days=$(x509_days_remaining "$SBM_CERTS/$selected_domain/fullchain.pem" 2>/dev/null || printf '?')
          printf '%d. %s（剩余 %s 天）\n' "$((i + 1))" "$selected_domain" "$days"
        else printf '%d. %s（需要签发/续签）\n' "$((i + 1))" "$selected_domain"; fi
      done
      printf 'n. 使用其他域名（自动复用或申请）\n0. 返回（直接按 Enter）\n'
      prompt_value choice '证书域名' '0' || return 1
      case "$choice" in
        n|N|m|M) prompt_value selected_domain '新域名（留空返回）' '' || return 1;;
        0) return 1;;
        *)
          if [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#domains[@]} )); then
            selected_domain=${domains[$((choice - 1))]}
          else selected_domain=$choice; fi;;
      esac
    fi
    [[ -n "$selected_domain" && "$selected_domain" != 0 ]] || return 1
    if validate_domain "$selected_domain"; then break; fi
    log_error '请输入有效域名，不要带 https://、端口或路径。'
  done
  selected_domain=${selected_domain%.}
  while ! ui_certificate_usable "$selected_domain"; do
    # Certificate mutations run in a fresh worker: the selector's caller may
    # be using ||, which would otherwise suppress errexit in the ACME steps.
    ui_run ui_issue_certificate "$selected_domain" "$reset_credentials"
    case "$SBM_UI_LAST_STATUS" in
      0) break;;
      201|202|203|206) ui_end_session "$SBM_UI_LAST_STATUS"; return 1;;
      204) return 1;;
      *)
        log_error '证书申请未完成，尚未创建节点。'
        printf '1. 使用现有凭据重试\n2. 更新 Cloudflare DNS 凭据后重试\n0. 返回\n'
        ui_menu_choice choice '下一步' 2 || return 1
        case "$choice" in 1) reset_credentials=0;; 2) reset_credentials=1;; *) return 1;; esac;;
    esac
  done
  ui_require_certificate "$selected_domain" || return 1
  printf -v "$__var" '%s' "$selected_domain"
}

ui_port_default() {
  local kind=$1; shift
  local port
  for port in "$@"; do
    if ! node_port_in_state "$kind" "$port" && ! host_port_in_use "$kind" "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  node_choose_port "$kind"
}

ui_prompt_port() {
  local __var=$1 kind=$2 label=$3 suggested
  shift 3
  suggested=$(ui_port_default "$kind" "$@")
  prompt_value "$__var" "$label（推荐 $suggested）" "$suggested"
}

ui_prompt_server_address() {
  local __address_var=$1 __address_default=${2:-} __address_value
  if ! { validate_ipv4 "$__address_default" || validate_ipv6 "$__address_default" || validate_domain "$__address_default"; }; then
    __address_default=''
  fi
  while true; do
    prompt_value __address_value '客户端连接地址（域名或公网 IP）' "$__address_default" || return 1
    [[ -n "$__address_value" ]] || { ui_cancel; return 1; }
    if validate_ipv4 "$__address_value" || validate_ipv6 "$__address_value" || validate_domain "$__address_value"; then
      printf -v "$__address_var" '%s' "$__address_value"; return 0
    fi
    log_error '请输入域名或 IP，不要带协议、端口或路径。'
  done
}

ui_node_finish_menu() {
  local id=$1 choice node user_id output max_choice=5
  node=$(state_get_node "$id")
  [[ -n "$node" ]] || { ui_page_back; return; }
  printf '\n%s（%s）\n' "$(jq -r '.name' <<<"$node")" "$id"
  printf '1. 再次显示链接和二维码\n2. 显示可复制的完整 sing-box JSON\n3. 生成动态订阅地址（所有启用节点）\n4. 管理这个节点\n5. 查看防火墙与协议端口\n'
  if [[ $(jq -r '.protocol' <<<"$node") == vmess-ws-cf ]]; then printf '6. 为这个节点配置 Cloudflare Tunnel\n'; max_choice=6; fi
  printf '0. 返回主菜单\n'
  ui_menu_choice choice '下一步' "$max_choice"
  case "$choice" in
    1) node_share "$id" 1;;
    2)
      user_id=$(jq -r 'first(.users[]|select(.enabled)|.id) // empty' <<<"$node")
      [[ -n "$user_id" ]] || die '该节点没有启用用户。'
      output="$SBM_EXPORTS/nodes/$id/$user_id/client.json"
      export_node_client_config "$id" "$user_id" "$output" >/dev/null
      printf '\n在 sing-box 客户端导入以下完整 JSON；其中含节点凭据，请妥善保存：\n'
      cat "$output"
      ;;
    3) ui_open_submenu ui_subscription_menu;;
    4) ui_open_submenu ui_manage_nodes "$id";;
    5) ui_open_submenu ui_firewall_menu;;
    6)
      if [[ $(jq -r '.protocol' <<<"$node") == vmess-ws-cf ]]; then ui_open_submenu ui_tunnel_menu "$id"
      else log_error '当前节点不使用 Cloudflare Tunnel。'; fi;;
  esac
}

ui_add_node_and_deliver() {
  local type=$1 id node kind
  shift
  id="${type}-$(random_hex 4)"
  node_add "$type" --id "$id" "$@"
  node=$(state_get_node "$id")
  printf '\n节点已创建：%s（%s）\n' "$(jq -r '.name' <<<"$node")" "$id"
  if [[ $(jq -r '.protocol' <<<"$node") == vmess-ws-cf ]]; then
    printf '下一步请在 Cloudflare Tunnel 菜单关联这个节点，再获取公网分享链接。\n'
  else
    if [[ $(jq -r '.listen' <<<"$node") == 127.0.0.1 || $(jq -r '.listen' <<<"$node") == ::1 ]]; then
      printf '该入口只监听本机；远程使用需要 SSH/VPN 等受保护通道。\n'
    else
      while IFS= read -r kind; do
        printf '公网连接需要放行 %s/%s（云安全组和主机防火墙）。\n' "$(jq -r '.port' <<<"$node")" "${kind^^}"
      done < <(node_transport_kinds "$node")
    fi
    printf '客户端可从剪贴板导入下面的分享链接，或扫描二维码。\n'
    ui_run node_share "$id" 1
    if [[ "$SBM_UI_LAST_STATUS" != 0 ]]; then
      log_warn "节点 $id 已保留；导出未完成，可在下面重试或管理节点，无需重复创建。"
    fi
  fi
  ui_menu_loop ui_node_finish_menu "$id"
  ui_page_back
}

ui_add_node() {
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '添加节点不支持 --dry-run；请退出预览模式后再操作。'
  local choice domain address port name id obfs method security security_choice snell_obfs_choice snell_obfs_host snell_version_choice snell_mode_choice
  local hy2_obfs_choice hy2_min_packet_size hy2_max_packet_size hy2_disable_chrome hy2_bbr_profile hy2_brutal_debug hy2_realm_choice hy2_realm_id hy2_realm_ip hy2_realm_mapping
  local handshake_server handshake_port congestion_control network strict_mode wildcard_sni
  printf '%s\n' \
    '1. VMess + WebSocket + Cloudflare Tunnel' \
    '2. Shadowsocks 2022' \
    '3. AnyTLS' \
    '4. Hysteria2' \
    '5. Trojan TLS' \
    '6. TUIC（QUIC）' \
    '7. VLESS（TLS/Reality）' \
    '8. NaiveProxy（HTTPS/QUIC）' \
    '9. ShadowTLS v3' \
    '10. Snell v5/v6（需要 sing-box 1.14+）' \
    '11. SOCKS5 / HTTP / mixed 认证代理' \
    '0. 返回'
  ui_menu_choice choice '选择协议' 11
  case "$choice" in
    1)
      prompt_value name '节点名称' 'VMess WS Cloudflare'; prompt_value domain '固定 Tunnel 域名（Quick Tunnel 可留空）' ''; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"
      local args=(vmess --name "$name")
      [[ -n "$domain" ]] && args+=(--domain "$domain")
      [[ -n "$address" ]] && args+=(--address "$address")
      ui_add_node_and_deliver "${args[@]}"
      ;;
    2)
      prompt_value name '节点名称' 'Shadowsocks 2022'; prompt_value address '客户端连接地址（域名或 IP）' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 8388 8389 8390 8443
      printf '1. 2022-blake3-aes-128-gcm\n2. 2022-blake3-aes-256-gcm（推荐）\n3. 2022-blake3-chacha20-poly1305\n'; ui_menu_choice method '选择方法' 3
      case "$method" in 1) method=2022-blake3-aes-128-gcm;; 2) method=2022-blake3-aes-256-gcm;; 3) method=2022-blake3-chacha20-poly1305;; *) log_error '选择无效'; return;; esac
      ui_add_node_and_deliver ss --name "$name" --address "$address" --port "$port" --method "$method"
      ;;
    3)
      prompt_value name '节点名称' 'AnyTLS'; ui_select_certificate_domain domain || { ui_cancel; return; }; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      ui_add_node_and_deliver anytls --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    4)
      prompt_value name '节点名称' 'Hysteria2'; ui_select_certificate_domain domain || { ui_cancel; return; }; prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port udp 'UDP 端口' 443 8443 9443 10443
      printf '1. 不启用混淆\n2. Salamander\n3. Gecko（1.14+，可调包长）\n'; ui_menu_choice hy2_obfs_choice '选择 Hysteria2 混淆' 3
      local -a hy2_args=(hy2 --name "$name" --domain "$domain" --address "$address" --port "$port")
      case "$hy2_obfs_choice" in
        1) ;;
        2) hy2_args+=(--obfs salamander) ;;
        3)
          prompt_value hy2_min_packet_size 'Gecko 最小包长' '512'; prompt_value hy2_max_packet_size 'Gecko 最大包长' '1200'
          hy2_args+=(--obfs gecko --obfs-min-packet-size "$hy2_min_packet_size" --obfs-max-packet-size "$hy2_max_packet_size") ;;
        *) log_error '选择无效'; return ;;
      esac
      prompt_value hy2_disable_chrome '关闭 Chrome QUIC 指纹伪装？(y/N)' 'N'
      [[ "$hy2_disable_chrome" =~ ^[Yy]$ ]] && hy2_args+=(--disable-chrome-parrot)
      printf '1. standard\n2. conservative\n3. aggressive\n4. 不显式设置\n'; ui_menu_choice hy2_bbr_profile 'BBR profile' 4
      case "$hy2_bbr_profile" in
        1) hy2_args+=(--bbr-profile standard) ;;
        2) hy2_args+=(--bbr-profile conservative) ;;
        3) hy2_args+=(--bbr-profile aggressive) ;;
        4) ;;
        *) log_error '选择无效'; return ;;
      esac
      prompt_value hy2_brutal_debug '启用 Hysteria Brutal 调试日志？(y/N)' 'N'
      [[ "$hy2_brutal_debug" =~ ^[Yy]$ ]] && hy2_args+=(--brutal-debug)
      if [[ $(jq -r '.realm.enabled // false' "$SBM_STATE") == true ]]; then
        prompt_value hy2_realm_choice '启用 Hysteria Realm NAT 穿透？(y/N)' 'N'
        if [[ "$hy2_realm_choice" =~ ^[Yy]$ ]]; then
          prompt_value hy2_realm_id 'Realm slot ID' ''
          prompt_value hy2_realm_ip 'Realm IP 版本（0/4/6）' '0'
          prompt_value hy2_realm_mapping '启用 UPnP/NAT-PMP 端口映射？(y/N)' 'N'
          hy2_args+=(--realm-id "$hy2_realm_id" --realm-ip-version "$hy2_realm_ip")
          [[ "$hy2_realm_mapping" =~ ^[Yy]$ ]] && hy2_args+=(--realm-port-mapping)
        fi
      fi
      ui_add_node_and_deliver "${hy2_args[@]}"
      ;;
    5)
      prompt_value name '节点名称' 'Trojan'; ui_select_certificate_domain domain || { ui_cancel; return; }
      prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      ui_add_node_and_deliver trojan --name "$name" --domain "$domain" --address "$address" --port "$port"
      ;;
    6)
      prompt_value name '节点名称' 'TUIC'; ui_select_certificate_domain domain || { ui_cancel; return; }
      prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port udp 'UDP 端口' 443 8443 9443 10443
      printf '1. cubic\n2. new_reno\n3. bbr\n'; ui_menu_choice congestion_control '拥塞控制' 3
      case "$congestion_control" in 1) congestion_control=cubic;; 2) congestion_control=new_reno;; 3) congestion_control=bbr;; *) log_error '选择无效'; return;; esac
      ui_add_node_and_deliver tuic --name "$name" --domain "$domain" --address "$address" --port "$port" --congestion-control "$congestion_control"
      ;;
    7)
      prompt_value name '节点名称' 'VLESS'
      printf '1. TLS（需要本地证书）\n2. Reality（使用 Reality 密钥对）\n'; ui_menu_choice security_choice '选择安全层' 2
      case "$security_choice" in
        1)
          security=tls; ui_select_certificate_domain domain || { ui_cancel; return; }
          prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
          ui_add_node_and_deliver vless --name "$name" --domain "$domain" --address "$address" --port "$port" --security "$security"
          ;;
        2)
          security=reality; prompt_value domain 'Reality SNI' 'www.apple.com'; prompt_value address '客户端连接地址' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
          prompt_value handshake_server 'Reality 握手域名' 'www.apple.com'; prompt_value handshake_port 'Reality 握手端口' '443'
          ui_add_node_and_deliver vless --name "$name" --domain "$domain" --address "$address" --port "$port" --security "$security" --handshake-server "$handshake_server" --handshake-port "$handshake_port"
          ;;
        *) log_error '选择无效';;
      esac
      ;;
    8)
      prompt_value name '节点名称' 'NaiveProxy'; ui_select_certificate_domain domain || { ui_cancel; return; }
      prompt_value address '客户端连接地址' "$(ui_client_address_default "$domain")"
      printf '1. HTTPS/TCP\n2. QUIC/UDP\n'; ui_menu_choice security_choice '选择传输' 2
      case "$security_choice" in 1) network=tcp;; 2) network=udp;; *) log_error '选择无效'; return;; esac
      ui_prompt_port port "$network" '端口' 443 8443 9443 10443
      ui_add_node_and_deliver naive --name "$name" --domain "$domain" --address "$address" --port "$port" --network "$network"
      ;;
    9)
      prompt_value name '节点名称' 'ShadowTLS'; prompt_value handshake_server '握手目标域名' ''; prompt_value handshake_port '握手目标端口' '443'
      printf '节点包含 Shadowsocks 2022 加密内层；客户端须导入完整 sing-box 配置，或支持 shadow-tls 插件的分享链接。\n'
      prompt_value address '客户端连接地址' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 443 8443 9443 10443
      prompt_value strict_mode '严格模式（true/false）' 'true'; prompt_value wildcard_sni '通配 SNI（off/authed/all）' 'off'
      ui_add_node_and_deliver shadowtls --name "$name" --address "$address" --port "$port" --handshake-server "$handshake_server" --handshake-port "$handshake_port" --strict-mode "$strict_mode" --wildcard-sni "$wildcard_sni"
      ;;
    10)
      prompt_value name '节点名称' 'Snell'; prompt_value address '客户端连接地址（域名或 IP）' "$(ui_client_address_default '')"; ui_prompt_port port tcp 'TCP 端口' 6160 443 8443 9443 10443
      printf '1. Snell v5（推荐，兼容 Surge/mihomo/sing-box，可选 HTTP obfs）\n2. Snell v6（traffic shaping，Surge Beta/sing-box；mihomo 不支持）\n'; ui_menu_choice snell_version_choice '选择 Snell 版本' 2
      case "$snell_version_choice" in
        1)
          printf '1. 不启用 HTTP 混淆\n2. HTTP 混淆\n'; ui_menu_choice snell_obfs_choice '选择混淆' 2
          case "$snell_obfs_choice" in
            1) obfs=none; ui_add_node_and_deliver snell --name "$name" --address "$address" --port "$port" --snell-version 5 --obfs none ;;
            2) prompt_value snell_obfs_host 'HTTP 混淆 Host' 'bing.com'; ui_add_node_and_deliver snell --name "$name" --address "$address" --port "$port" --snell-version 5 --obfs http --obfs-host "$snell_obfs_host" ;;
            *) log_error '选择无效';;
          esac
          ;;
        2)
          printf '1. default\n2. unshaped\n3. unsafe-raw\n'; ui_menu_choice snell_mode_choice 'Snell v6 traffic shaping mode' 3
          case "$snell_mode_choice" in 1) snell_mode_choice=default;; 2) snell_mode_choice=unshaped;; 3) snell_mode_choice=unsafe-raw;; *) log_error '选择无效'; return;; esac
          ui_add_node_and_deliver snell --name "$name" --address "$address" --port "$port" --snell-version 6 --snell-mode "$snell_mode_choice"
          ;;
        *) log_error '选择无效';;
      esac
      ;;
    11)
      local proxy_type proxy_listen
      prompt_value proxy_type '代理类型（socks/http/mixed）' 'mixed'
      prompt_value proxy_listen '监听地址（127.0.0.1/::1/0.0.0.0/::）' '127.0.0.1'
      prompt_value address '客户端连接地址' "$(ui_proxy_address_default "$proxy_listen")"
      ui_prompt_port port tcp '监听端口' 1080 1081 8080 8081
      prompt_value name '节点名称' '认证代理'
      ui_add_node_and_deliver "$proxy_type" --listen "$proxy_listen" --address "$address" --port "$port" --name "$name"
      ;;
    0) return;; *) log_error '选择无效';;
  esac
}

ui_manage_nodes() {
  local id=${1:-} action value remark region purpose line tags node max_action=11
  if [[ -z "$id" ]]; then
    ui_select_node id || { ui_page_back; return; }
    if [[ ${SBM_UI_WORKER:-0} == 1 ]]; then ui_open_submenu ui_manage_nodes "$id"; return; fi
  fi
  state_node_exists "$id" || { ui_page_back; return; }
  node=$(state_get_node "$id")
  node_show "$id"
  printf '\n1. 分享链接\n2. 启用\n3. 停用\n4. 改端口\n5. 改地址\n6. 改名称\n7. 备注/标签\n8. 换密码\n9. 删除\n10. 设置到期\n11. 清除到期\n'
  if [[ $(jq -r '.protocol' <<<"$node") == snell ]]; then printf '12. 恢复升级前凭据\n'; max_action=12; fi
  printf '0. 返回\n'
  ui_menu_choice action '选择操作' "$max_action"
  case "$action" in
    1) node_share "$id" 1;; 2) node_enable "$id";; 3) node_disable "$id";;
    4) prompt_value value '新端口' "$(jq -r '.port' <<<"$node")"; node_set "$id" --port "$value";;
    5) prompt_value value '新地址' "$(jq -r '.client_address // .server_address // ""' <<<"$node")"; node_set "$id" --address "$value";;
    6) prompt_value value '新名称' "$(jq -r '.name' <<<"$node")"; node_set "$id" --name "$value";;
    7)
      remark=$(jq -r '.metadata.remark' <<<"$(state_get_node "$id")"); region=$(jq -r '.metadata.region' <<<"$(state_get_node "$id")")
      purpose=$(jq -r '.metadata.purpose' <<<"$(state_get_node "$id")"); line=$(jq -r '.metadata.line' <<<"$(state_get_node "$id")")
      tags=$(jq -r '.metadata.tags|join(",")' <<<"$(state_get_node "$id")")
      ui_prompt_optional remark '备注' "$remark"; ui_prompt_optional region '地区' "$region"; ui_prompt_optional purpose '用途' "$purpose"
      ui_prompt_optional line '线路/运营商' "$line"; ui_prompt_optional tags '标签（逗号分隔）' "$tags"
      node_set "$id" --remark "$remark" --region "$region" --purpose "$purpose" --line "$line" --tags "$tags"
      ;;
    8) confirm '轮换后旧链接会立即失效，继续？' N && node_rotate "$id";;
    9) confirm "确认删除 $id？" N && node_delete "$id";;
    10) prompt_value value '续期天数（从当前到期日或今天起算）' '30'; node_expiry_cli "$id" --days "$value";;
    11) node_expiry_cli "$id" --clear;;
    12) node_recover_legacy_credentials "$id";;
  esac
}

ui_share_export_menu() {
  local id
  ui_select_node id 1 || { ui_page_back; return; }
  if [[ "$id" == all ]]; then
    node_share_all
    export_all_outbounds
  else
    node_share "$id" 1
  fi
}

ui_client_export_menu() {
  local mode_choice mode output dns_mode dns_address
  printf '1. 导出 mixed 客户端配置\n2. 导出 TUN 客户端配置\n0. 返回\n'
  ui_menu_choice mode_choice '选择客户端配置模式' 2
  case "$mode_choice" in
    1) mode=mixed; output="$SBM_EXPORTS/client-mixed.json";;
    2) mode=tun; output="$SBM_EXPORTS/client-tun.json";;
    0) return;;
    *) log_error '选择无效'; return;;
  esac
  prompt_value output '输出文件' "$output"
  dns_mode=hijack; dns_address=''
  if [[ "$mode" == tun ]] && version_ge "$(core_current_version)" 1.14.0-rc.1; then
    printf '1. hijack（设置系统 DNS 并劫持 53 端口）\n2. native（仅设置系统 DNS）\n3. disabled（不改系统 DNS）\n'
    ui_menu_choice dns_mode 'TUN DNS 模式' 3
    case "$dns_mode" in 1) dns_mode=hijack;; 2) dns_mode=native;; 3) dns_mode=disabled;; *) log_error '选择无效'; return;; esac
    if [[ "$dns_mode" != disabled ]]; then prompt_value dns_address 'DNS 地址（留空使用自动地址）' ''; fi
  fi
  export_client_config "$output" "$mode" "$dns_mode" "$dns_address"
}

ui_cert_menu() {
  local c token zone email domain
  printf '1. 查看证书\n2. 配置 Cloudflare DNS API\n3. 签发/续发域名证书\n4. 立即执行全部续签检查\n5. 查看证书详情\n0. 返回\n'
  ui_menu_choice c '选择操作' 5
  case "$c" in
    1) cert_list;;
    2) cert_setup_cloudflare;;
    3) prompt_value domain '域名' ''; ui_issue_certificate "$domain";;
    4) cert_renew;;
    5) prompt_value domain '域名' ''; cert_inspect "$domain";;
  esac
}

ui_tunnel_menu() {
  local c id=${1:-} domain address
  printf '1. 查看 Tunnel 状态\n2. 安装/更新 cloudflared\n3. 配置固定 Tunnel\n4. 启动 Quick Tunnel\n5. 刷新 Quick Tunnel 域名\n6. 更换固定 Tunnel Token\n7. 停止 Tunnel\n8. 多域名/路径路由管理\n0. 返回\n'
  ui_menu_choice c '选择操作' 8
  case "$c" in
    1) tunnel_status;;
    2) cloudflared_install;;
    3) [[ -n "$id" ]] || ui_select_node id || { ui_cancel; return; }; prompt_value domain 'Tunnel 公网域名' ''; prompt_value address '客户端 add 地址' "$domain"; tunnel_setup_fixed "$id" "$domain" '' "$address";;
    4) [[ -n "$id" ]] || ui_select_node id || { ui_cancel; return; }; tunnel_setup_quick "$id";;
    5) tunnel_refresh_quick;; 6) tunnel_set_token;; 7) confirm '停止 Tunnel？' N && tunnel_stop;;
    8) ui_open_submenu ui_tunnel_routes_menu;;
  esac
}

ui_update_menu() {
  local c p v path
  printf '1. 检查 sing-box 更新\n2. 更新 sing-box 最新版\n3. 指定 sing-box 版本\n4. 回滚 sing-box\n5. 设置 sing-box 核心自动更新策略\n6. 安装/更新 cloudflared\n7. 更新 acme.sh\n8. 导出 sing-box 1.14 JSON Schema\n9. 查看核心 build tags 与能力\n10. 检查脚本更新\n11. 更新脚本本身（保留当前核心和节点）\n12. 脚本每日自动更新（默认开启）\n0. 返回\n'
  ui_menu_choice c '选择操作' 12
  case "$c" in
    1) core_check_update || true;; 2) core_update latest;; 3) prompt_value v '版本号，如 1.14.0-rc.1' ''; core_update "$v";; 4) core_rollback;;
    5) printf 'manual / notify / patch / stable\n'; prompt_value p '策略' "$(jq -r '.settings.core_update_policy' "$SBM_STATE")"; core_set_policy "$p";; 6) cloudflared_update;; 7) acme_update;;
    8) prompt_value path 'Schema 输出文件' "$SBM_EXPORTS/sing-box-schema.json"; core_schema "$path";;
    9) core_capabilities;;
    10) manager_update --check;;
    11) manager_update; if [[ ${SBM_UI_WORKER:-0} == 1 ]]; then exit 203; else exec "$SBM_BIN_DIR/sb"; fi;;
    12) ui_open_submenu ui_manager_auto_menu;;
  esac
}

ui_manager_auto_menu() {
  local choice
  manager_auto_status
  printf '\n1. 开启每日脚本自动更新\n2. 关闭每日脚本自动更新\n3. 立即执行一次自动更新检查\n4. 查看最近自动更新日志\n0. 返回\n'
  ui_menu_choice choice '选择操作' 4
  case "$choice" in
    1) manager_update_cli auto enable;;
    2) manager_update_cli auto disable;;
    3)
      if ! manager_auto_enabled; then log_warn '请先开启自动更新，或使用上级菜单的“更新脚本本身”。'; return; fi
      manager_auto_run
      if [[ ${SBM_UI_WORKER:-0} == 1 ]]; then exit 203; else exec "$SBM_BIN_DIR/sb"; fi;;
    4)
      if [[ -f "$SBM_VAR/updates/manager.log" ]]; then tail -n 80 "$SBM_VAR/updates/manager.log"
      else log_info '尚无自动更新日志。'; fi;;
  esac
}

ui_api_menu() {
  local c port dashboard path command
  api_status
  printf '\n1. 启用 API\n2. 启用 API + Dashboard\n3. 停用 API/Dashboard\n4. 显示 API 令牌\n5. 查看 API 服务状态\n6. 查看 API outbounds\n7. 导出 sing-box JSON Schema\n0. 返回\n'
  ui_menu_choice c '选择操作' 7
  case "$c" in
    1|2)
      port=$(jq -r '.api.port // 9090' "$SBM_STATE")
      prompt_value port 'API loopback 端口' "$port"
      if [[ "$c" == 2 ]]; then api_enable "$port" true; else api_enable "$port" false; fi
      ;;
    3) confirm '确认停用 API/Dashboard？' N && api_disable;;
    4) api_show_token;;
    5) api_cli status;;
    6) api_cli outbounds;;
    7) path="$SBM_EXPORTS/sing-box-schema.json"; prompt_value path 'Schema 输出文件' "$path"; core_schema "$path";;
  esac
}

ui_realm_menu() {
  local c port url listen domain max token
  realm_status
  printf '\n1. 启用/配置 Hysteria Realm\n2. 停用 Hysteria Realm\n3. 显示 Realm token\n4. 查看 Realm 配置 JSON\n0. 返回\n'
  ui_menu_choice c '选择操作' 4
  case "$c" in
    1)
      port=$(jq -r '.realm.port // 9443' "$SBM_STATE"); url=$(jq -r '.realm.public_url // ""' "$SBM_STATE"); listen=$(jq -r '.realm.listen // "::"' "$SBM_STATE"); domain=$(jq -r '.realm.tls_domain // ""' "$SBM_STATE"); max=$(jq -r '.realm.max_realms // 0' "$SBM_STATE")
      prompt_value port 'Realm 监听端口' "$port"; prompt_value url 'Realm 公网 URL（http/https）' "$url"; prompt_value listen '监听地址' "$listen"; prompt_value domain 'TLS 域名（留空为明文 HTTP）' "$domain"; prompt_value max '每个用户最大 Realm 数（0 不限）' "$max"
      realm_enable "$port" "$url" "$listen" "$domain" "$max"
      ;;
    2) confirm '确认停用 Hysteria Realm？' N && realm_disable;;
    3) realm_show_token;;
    4) realm_status 1;;
  esac
}

ui_doctor_menu() {
  local c host count family
  printf '1. 运行完整诊断\n2. 自动修复权限、配置与服务\n3. 低风险自动修复（不改防火墙/SSH/内核）\n4. 协调/重启 sing-box 服务\n5. 查看 sing-box 最近日志\n6. 网络延迟、丢包与抖动检测\n7. 吞吐测速与前后对比\n0. 返回\n'
  ui_menu_choice c '选择操作' 7
  case "$c" in
    1) doctor_run || true;;
    2) doctor_run 1 || true;;
    3) doctor_run 0 0 1 || true;;
    4) singbox_service_reconcile && status_summary || true;;
    5) show_logs singbox 100;;
    6)
      prompt_value host '目标主机名或 IP' ''
      prompt_value count '探测次数（1–30）' '10'
      prompt_value family 'IP 协议（auto/4/6）' 'auto'
      network_ping "$host" "$count" "$family" || true
      ;;
    7) ui_open_submenu ui_network_benchmark_menu;;
  esac
}

ui_uninstall_menu() {
  local c phrase
  printf '%s\n' \
    '1. 卸载程序（保留节点、配置、证书、密钥和备份）' \
    '2. 完全卸载（删除程序及全部数据）' \
    '0. 返回'
  ui_menu_choice c '选择操作' 2
  case "$c" in
    1)
      uninstall_manager 0 0
      ;;
    2)
      printf '%s警告：此操作会删除所有节点、证书、Token、核心和备份，无法撤销。%s\n' "$C_RED" "$C_RESET"
      prompt_value phrase '请输入 DELETE 确认彻底卸载' ''
      [[ "$phrase" == DELETE ]] || { log_warn '确认文字不匹配，已取消。'; return; }
      uninstall_manager 1 1
      ;;
    0) return 0 ;;
    *) log_error '选择无效' ;;
  esac
}

ui_backup_menu() {
  local c path
  printf '1. 创建备份\n2. 从备份恢复\n0. 返回\n'; ui_menu_choice c '选择操作' 2
  case "$c" in 1) backup_create;; 2) prompt_value path '备份文件路径' ''; confirm '恢复会覆盖当前配置，继续？' N && backup_restore "$path" 1;; esac
}

ui_mux_auto_menu() {
  local ids port backend items count
  items=$(jq '[.nodes[]? | select(.enabled==true) | select(
    (.protocol|IN("anytls","trojan","shadowtls"))
    or (.protocol=="vless" and (.security|IN("tls","reality")))
    or (.protocol=="naive" and (.network // "tcp")=="tcp")
  ) | {id,name,protocol,domain}]' "$SBM_STATE") || return 1
  count=$(jq 'length' <<<"$items")
  if (( count == 0 )); then
    log_warn '没有可加入 TCP/443 复用的启用节点。支持 AnyTLS、Trojan、VLESS TLS/Reality、Naive TCP 和 ShadowTLS。'
    return
  fi
  printf '可复用节点（已有路由会跳过）：\n'
  jq -r '.[] | "- \(.id) | \(.protocol) | \(.domain // "-")"' <<<"$items"
  prompt_value ids '节点 ID（逗号分隔，all=全部）' 'all'
  port=$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")
  prompt_value port '公网端口' "$port"
  backend=$(mux_backend)
  printf '方式：%s；不会修改现有网站。\n' "$(mux_backend_label)"
  mux_auto_configure "$ids" "$port" "$backend"
}

ui_nginx_stream_menu() {
  local c id sni backend port node engine_choice
  nginx_stream_status
  printf '不同节点需使用不同 SNI；证书验证保持开启，UDP 节点仍使用独立监听。\n'
  printf '\n1. 一键配置多个节点并启用 TCP/443 复用\n2. 添加单条 SNI 路由\n3. 删除 SNI 路由\n4. 启用 TCP 端口复用\n5. 停用复用，恢复独立端口\n6. 查看路由\n7. 切换复用方式\n0. 返回\n'
  ui_menu_choice c '选择操作' 7
  case "$c" in
    1) ui_mux_auto_menu;;
    2)
      ui_select_node id || { ui_cancel; return; }
      node=$(state_get_node "$id")
      sni=$(nginx_stream_node_sni "$node" 2>/dev/null || true)
      prompt_value sni 'SNI 域名（必须与客户端 server_name 一致）' "$sni"
      prompt_value backend '后端端口（留空自动分配）' ''
      nginx_stream_route_add "$id" "$sni" "$backend"
      ;;
    3)
      prompt_value id '节点 ID' ''
      nginx_stream_route_remove "$id"
      ;;
    4)
      port=$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")
      prompt_value port '公网端口' "$port"
      nginx_stream_enable "$port"
      ;;
    5) nginx_stream_disable;;
    6) nginx_stream_route_list;;
    7)
      printf '1. sing-box 内置（推荐小内存服务器，无新增进程或软件包）\n2. Nginx Stream（按需安装并启动独立服务）\n0. 返回\n'
      ui_menu_choice engine_choice '选择复用方式' 2
      case "$engine_choice" in 1) mux_set_backend sing-box;; 2) mux_set_backend nginx;; esac;;
  esac
}

ui_settings_menu() {
  local c v
  printf '1. 设置默认服务器地址\n2. 修改日志级别\n3. TCP/443 多协议复用（内置 / Nginx）\n4. 出站 IP 优先级\n5. 配置校验与差异预览\n6. sing-box 1.14 DNS 优化\n7. 一键开启/恢复 BBR\n8. Hysteria2 UDP 缓冲区优化\n9. 按带宽/延迟优化 TCP\n0. 返回\n'; ui_menu_choice c '选择操作' 9
  case "$c" in
    1) prompt_value v '域名或 IP' "$(jq -r '.settings.default_server_address // ""' "$SBM_STATE")"; settings_set_default_address "$v";;
    2) prompt_value v '日志级别 (trace/debug/info/warn/error/fatal/panic)' "$(jq -r '.settings.log_level' "$SBM_STATE")"; settings_set_log_level "$v";;
    3) ui_open_submenu ui_nginx_stream_menu;;
    4) ui_open_submenu ui_outbound_menu;;
    5) ui_open_submenu ui_config_menu;;
    6) ui_open_submenu ui_dns_menu;;
    7) ui_open_submenu ui_bbr_menu;;
    8) ui_open_submenu ui_hy2_buffer_menu;;
    9) ui_open_submenu ui_tcp_tuning_menu;;
  esac
}

ui_outbound_menu() {
  local c
  printf '1. IPv4 优先\n2. IPv6 优先\n3. 仅 IPv4\n0. 返回\n'
  ui_menu_choice c '选择出站 IP 策略' 3
  case "$c" in 1) settings_set_outbound_ip_strategy prefer_ipv4;; 2) settings_set_outbound_ip_strategy prefer_ipv6;; 3) settings_set_outbound_ip_strategy ipv4_only;; esac
}

ui_config_menu() {
  local c
  printf '1. 校验当前配置\n2. 查看已安装配置与当前状态差异\n3. 查看 state.json（敏感字段已遮蔽）\n0. 返回\n'
  ui_menu_choice c '选择操作' 3
  case "$c" in 1) config_validate;; 2) config_diff;; 3) config_redact <"$SBM_STATE";; esac
}

ui_dns_menu() {
  local c value
  printf '1. 查看 DNS 1.14 设置\n2. 开启 optimistic DNS\n3. 关闭 optimistic DNS\n4. 设置 optimistic 缓存窗口\n5. 设置 DNS 查询超时\n0. 返回\n'
  ui_menu_choice c '选择操作' 5
  case "$c" in
    1) settings_show_addresses 1 | jq '{dns_optimistic,dns_optimistic_timeout,dns_timeout}';;
    2) settings_set_dns optimistic true;; 3) settings_set_dns optimistic false;;
    4) prompt_value value '缓存窗口（如 3d）' "$(jq -r '.settings.dns_optimistic_timeout // "3d"' "$SBM_STATE")"; settings_set_dns optimistic-timeout "$value";;
    5) prompt_value value 'DNS 超时（如 10s）' "$(jq -r '.settings.dns_timeout // "10s"' "$SBM_STATE")"; settings_set_dns timeout "$value";;
  esac
}

ui_bbr_menu() {
  local c
  bbr_status
  printf '1. 开启 BBR（fq + tcp_congestion_control=bbr）\n2. 恢复开启前设置\n0. 返回\n'
  ui_menu_choice c '选择 BBR 操作' 2
  case "$c" in 1) bbr_enable;; 2) confirm '确认恢复 BBR 启用前的 sysctl？' N && bbr_disable;; esac
}

ui_hy2_buffer_menu() {
  local c
  hy2_udp_buffer_status
  printf '1. 开启官方建议值（rmem_max/wmem_max = 16 MiB）\n2. 恢复开启前设置\n0. 返回\n'
  ui_menu_choice c '选择 Hysteria2 UDP 缓冲区操作' 2
  case "$c" in 1) hy2_udp_buffer_enable;; 2) confirm '确认恢复 Hysteria2 UDP 缓冲区启用前的 sysctl？' N && hy2_udp_buffer_disable;; esac
}

ui_tcp_tuning_menu() {
  local c bandwidth rtt plan
  tcp_tuning_status || return
  printf '\n1. 预览 TCP 调优参数\n2. 预览并应用 TCP 调优\n3. 恢复首次启用前的设置\n0. 返回\n'
  ui_menu_choice c '选择操作' 3
  case "$c" in
    1|2)
      prompt_value bandwidth '线路带宽（Mbps，整数）' '500'
      prompt_value rtt '典型客户端 RTT（ms，整数）' '100'
      plan=$(tcp_tuning_plan "$bandwidth" "$rtt") || return
      tcp_tuning_show_plan "$plan"
      if [[ "$c" == 2 ]] && confirm '应用以上 TCP 参数？' N; then tcp_tuning_enable "$bandwidth" "$rtt"; fi
      ;;
    3) confirm '恢复首次 TCP 调优前的 sysctl？' N && tcp_tuning_disable;;
  esac
}

ui_template_menu() {
  local c name id tag region
  node_template_list
  printf '\n1. 从节点保存模板\n2. 使用模板创建节点\n3. 删除模板\n4. 按标签启用节点\n5. 按标签停用节点\n0. 返回\n'
  ui_menu_choice c '选择操作' 5
  case "$c" in
    1) prompt_value name '模板名称' ''; ui_select_node id || { ui_cancel; return; }; node_template_save "$name" "$id" ;;
    2) prompt_value name '模板名称' ''; prompt_value id '新节点 ID' ''; node_template_add "$name" "$id" ;;
    3) prompt_value name '模板名称' ''; confirm "确认删除模板 $name？" N && node_template_delete "$name" ;;
    4) prompt_value tag '标签' ''; node_batch_enable "$tag" '' ;;
    5) prompt_value tag '标签' ''; node_batch_disable "$tag" '' ;;
  esac
}

ui_firewall_menu() {
  local c
  printf '1. 查看防火墙组件状态\n2. 查看所有协议端口\n3. 备份并清理 iptables 入站全局禁止\n4. 按所有启用协议端口执行 UFW allow\n5. 安装并启用 Fail2ban（自动探测 SSH，3分钟/5次/永久封禁）\n6. 安装并启用 UFW（安全向导：实际 SSH、22/80/443 及协议端口）\n7. 仅预览 UFW 变更\n0. 返回\n'
  ui_menu_choice c '选择操作' 7
  case "$c" in
    1) firewall_status ;;
    2) firewall_list_protocol_ports ;;
    3) confirm '将备份并移除 INPUT 链全局 DROP/REJECT，必要时调整默认策略，继续？' N && firewall_clear_iptables_input_deny 1 ;;
    4)
      firewall_list_protocol_ports
      command_exists ufw || { log_error '未安装 UFW；请使用发行版包管理器安装（Alpine：apk add ufw）。'; return; }
      confirm '将为所有启用协议端口执行 UFW allow，继续？' N && firewall_ufw_allow_protocol_ports 1
      ;;
    5) firewall_setup_fail2ban ;;
    6) firewall_setup_ufw ;;
    7) firewall_setup_ufw 0 1 ;;
  esac
}

ui_notification_health_menu() {
  local c provider token destination thresholds warn_days
  notification_status
  health_status
  printf '\n1. 配置 Telegram 通知\n2. 配置企业微信机器人\n3. 配置通用 Webhook\n4. 发送测试通知\n5. 停用通知\n6. 立即检查流量阈值\n7. 启用定时健康检查\n8. 停用定时健康检查\n9. 立即运行健康检查\n10. 配置资源/安全告警阈值\n0. 返回\n'
  ui_menu_choice c '选择操作' 10
  case "$c" in
    1)
      provider=telegram; prompt_secret token 'Telegram Bot Token'; prompt_value destination 'Telegram Chat ID' ''
      prompt_value thresholds '流量阈值（逗号分隔）' '80,90,100'; notification_configure "$provider" "$token" "$destination" "$thresholds"
      ;;
    2|3)
      [[ "$c" == 2 ]] && provider=wecom || provider=webhook
      prompt_secret token 'Webhook URL'; prompt_value thresholds '流量阈值（逗号分隔）' '80,90,100'
      notification_configure "$provider" "$token" '' "$thresholds"
      ;;
    4) notification_test ;;
    5) notification_disable ;;
    6) with_lock notification_traffic_check_unlocked ;;
    7) warn_days=$(jq -r '.health.certificate_warn_days' "$SBM_STATE"); prompt_value warn_days '证书提前预警天数' "$warn_days"; health_enable "$warn_days" ;;
    8) health_disable ;;
    9) health_check || true ;;
    10)
      local disk_free memory_max load_max
      disk_free=$(jq -r '.health.resources.disk_min_free_percent' "$SBM_STATE"); memory_max=$(jq -r '.health.resources.memory_max_percent' "$SBM_STATE"); load_max=$(jq -r '.health.resources.cpu_load_per_core_max' "$SBM_STATE")
      prompt_value disk_free '磁盘剩余最小百分比' "$disk_free"; prompt_value memory_max '内存最大百分比' "$memory_max"; prompt_value load_max '每核负载最大值' "$load_max"
      health_configure_resources --disk-free "$disk_free" --memory-max "$memory_max" --load-per-core "$load_max"
      ;;
  esac
}

ui_traffic_menu() {
  local c id quota reset_day upload_rate download_rate mode mode_choice
  traffic_status all
  printf '\n1. 配置/启用节点流量控制\n2. 停用节点流量控制\n3. 立即重置节点统计\n4. 移除配置与累计用量\n5. 重新加载运行规则\n6. 多节点共享配额\n7. tc 下行平滑限速\n0. 返回\n'
  ui_menu_choice c '选择操作' 7
  case "$c" in
    1)
      ui_select_node id || { ui_cancel; return; }
      quota=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|if .traffic.quota_bytes==null then "unlimited" else (.traffic.quota_bytes|tostring)+"B" end' "$SBM_STATE")
      reset_day=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.traffic.reset_day' "$SBM_STATE")
      upload_rate=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|if .traffic.upload_rate_bps==null then "unlimited" else (.traffic.upload_rate_bps|tostring)+"bps" end' "$SBM_STATE")
      download_rate=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|if .traffic.download_rate_bps==null then "unlimited" else (.traffic.download_rate_bps|tostring)+"bps" end' "$SBM_STATE")
      mode=$(jq -r --arg id "$id" '.nodes[]|select(.id==$id)|.traffic.quota_mode' "$SBM_STATE")
      prompt_value quota '月配额（如 100G；unlimited 不限）' "$quota"
      printf '1. 上行+下行计入配额\n2. 仅下行计入配额\n'
      printf '当前统计方式：%s\n' "$mode"
      ui_menu_choice mode_choice '配额统计方式' 2
      case "$mode_choice" in 1) mode=total;; 2) mode=download;; *) log_error '选择无效'; return;; esac
      prompt_value reset_day '每月重置日（1-28，UTC）' "$reset_day"
      prompt_value upload_rate '上行限速（如 20M；unlimited 不限）' "$upload_rate"
      prompt_value download_rate '下行限速（如 100M；unlimited 不限）' "$download_rate"
      traffic_set "$id" --quota "$quota" --quota-mode "$mode" --reset-day "$reset_day" --upload-rate "$upload_rate" --download-rate "$download_rate"
      ;;
    2) ui_select_node id || { ui_cancel; return; }; traffic_disable "$id" ;;
    3) ui_select_node id 1 || { ui_cancel; return; }; confirm "确认清零 $id 的本周期流量统计？" N && traffic_reset "$id" ;;
    4) ui_select_node id || { ui_cancel; return; }; confirm "确认移除 $id 的流量控制配置和累计用量？" N && traffic_remove "$id" ;;
    5) traffic_reconcile ;;
    6) ui_open_submenu ui_traffic_group_menu;;
    7) ui_open_submenu ui_shaping_menu;;
  esac
}

ui_network_benchmark_menu() {
  local c host port seconds streams direction before after data
  printf '1. iperf3 吞吐测速\n2. 查看测速记录\n3. 比较两次测速\n4. 安装测速依赖\n0. 返回\n'
  ui_menu_choice c '选择操作' 4
  case "$c" in
    1)
      command_exists "$SBM_NETWORK_IPERF_CMD" || { log_warn '尚未安装 iperf3，请先选择“安装测速依赖”。'; return; }
      prompt_value host '目标 iperf3 服务器' ''; prompt_value port '端口' '5201'
      prompt_value seconds '测试秒数（1–30）' '10'; prompt_value streams '并发连接（1–16）' '1'
      ui_select_json direction '测速方向' '[{"id":"down","label":"下载（服务器 → 本机）"},{"id":"up","label":"上传（本机 → 服务器）"}]' down || { ui_cancel; return; }
      network_speed "$host" "$port" "$seconds" "$streams" "$direction" 0;;
    2)
      data=$(network_history)
      jq -r 'if length==0 then "暂无测速记录。" else .[]|"\(.id)  \(.target):\(.port)  \(.direction)  \(.streams)连接  \(.seconds)s  \((.bits_per_second/1000000*100|round)/100) Mbps" end' <<<"$data";;
    3)
      data=$(network_history)
      ui_select_benchmark before "$data" || { ui_cancel; return; }
      printf '第二次仅列出测试条件相同的记录。\n'
      ui_select_benchmark after "$data" "$before" || { ui_cancel; return; }
      network_compare "$before" "$after";;
    4) dependency_require_feature benchmark;;
  esac
}

ui_traffic_group_menu() {
  local c id members quota day mode group data
  printf '1. 查看共享配额\n2. 创建/修改共享配额\n3. 移除配额组\n4. 重置组用量\n0. 返回\n'
  ui_menu_choice c '选择操作' 4
  case "$c" in
    1)
      data=$(traffic_group_cli status)
      jq -r 'if length==0 then "暂无共享配额组。" else .[]|"配额组：\(.id)；成员：\(.nodes|join(","))；用量：\(.used_bytes) / \(.quota_bytes) B；每月 \(.reset_day) 日重置；\(if .exhausted then "配额已用尽" else "配额可用" end)" end' <<<"$data";;
    2)
      ui_select_group id '' 1 || { ui_cancel; return; }
      group=$(jq -c --arg id "$id" 'first(.traffic_groups[]?|select(.id==$id)) // {}' "$SBM_STATE")
      members=$(jq -r '(.nodes // [])|join(",")' <<<"$group")
      quota=$(jq -r 'if .quota_bytes==null then "500G" else (.quota_bytes|tostring)+"B" end' <<<"$group")
      day=$(jq -r '.reset_day // 1' <<<"$group"); mode=$(jq -r '.quota_mode // "total"' <<<"$group")
      ui_select_members members "$members" || { ui_cancel; return; }
      prompt_value quota '共享月配额（如 500G）' "$quota"; prompt_value day '每月重置日（1–28）' "$day"
      ui_select_json mode '统计模式' '[{"id":"total","label":"双向合计"},{"id":"download","label":"仅下行"}]' "$mode" || { ui_cancel; return; }
      traffic_group_cli set "$id" --nodes "$members" --quota "$quota" --reset-day "$day" --quota-mode "$mode";;
    3) ui_select_group id || { ui_cancel; return; }; confirm "确认移除配额组 $id？" N && traffic_group_cli remove "$id";;
    4) ui_select_group id || { ui_cancel; return; }; confirm "确认清零配额组 $id 的累计用量？" N && traffic_group_cli reset "$id";;
  esac
}

ui_shaping_menu() {
  local c interface capacity
  printf '1. 查看 tc 整形设置\n2. 预览并启用下行平滑限速\n3. 停用并恢复网卡队列\n4. 安装 tc 依赖\n0. 返回\n'
  ui_menu_choice c '选择操作' 4
  case "$c" in
    1) jq -r '(.shaping // {enabled:false,interface:"",capacity_bps:1000000000})|"tc 下行整形：\(if .enabled then "启用" else "停用" end)；网卡：\(.interface)；容量：\(.capacity_bps) bit/s"' "$SBM_STATE";;
    2)
      interface=$(jq -r '.shaping.interface // ""' "$SBM_STATE")
      capacity=$(jq -r '(.shaping.capacity_bps // 1000000000|tostring)+"bps"' "$SBM_STATE")
      ui_select_interface interface "$interface" || { ui_cancel; return; }
      prompt_value capacity '网卡带宽容量（如 1G）' "$capacity"
      shaping_cli plan "$interface" --capacity "$capacity" || return
      confirm '将管理该网卡的出口队列，应用以上整形？' N && shaping_cli enable "$interface" --capacity "$capacity";;
    3) shaping_cli disable;;
    4) dependency_require_feature shaping;;
  esac
}

ui_tunnel_routes_menu() {
  local c id credentials host url path items route
  printf '1. 查看路由\n2. 导入命名 Tunnel 凭据\n3. 添加/修改路由\n4. 删除路由\n0. 返回\n'
  ui_menu_choice c '选择操作' 4
  case "$c" in
    1) jq -r '(.tunnel.routes // [])|if length==0 then "暂无路由。" else .[]|"\(.id)  \(.hostname)\(.path) → \(.service)" end' "$SBM_STATE";;
    2)
      prompt_value id 'Tunnel UUID' "$(jq -r '.tunnel.tunnel_id // ""' "$SBM_STATE")"
      prompt_value credentials '凭据 JSON 文件路径' ''; tunnel_routes_cli managed "$id" "$credentials";;
    3|4)
      [[ $(jq -r '.tunnel.mode' "$SBM_STATE") == managed ]] || { log_warn '请先导入命名 Tunnel 凭据。'; return; }
      items=$(jq '[.tunnel.routes[]?|{id,label:(.id+"  "+.hostname+.path+" → "+.service)}]' "$SBM_STATE")
      ui_select_json id '路由' "$items" '' "$([[ "$c" == 3 ]] && echo 1 || echo 0)" || { ui_cancel; return; }
      if [[ "$c" == 4 ]]; then confirm "确认删除路由 $id？" N && tunnel_routes_cli route remove "$id"; return; fi
      route=$(jq -c --arg id "$id" 'first(.tunnel.routes[]?|select(.id==$id)) // {}' "$SBM_STATE")
      host=$(jq -r '.hostname // ""' <<<"$route"); url=$(jq -r '.service // ""' <<<"$route"); path=$(jq -r '.path // ""' <<<"$route")
      prompt_value host '公网域名' "$host"
      prompt_value url '本机 HTTP(S) 地址（如 http://127.0.0.1:3001）' "$url"
      ui_prompt_optional path '路径正则（空值匹配整个域名）' "$path"
      tunnel_routes_cli route add "$id" "$host" "$url" "$path";;
  esac
}

ui_substore_menu() {
  local c port version frontend file name current current_frontend
  printf '1. 查看状态\n2. 安装/升级 Sub-Store\n3. 启用\n4. 停用\n5. 查看本机访问地址\n6. 接入本机节点（自动更新）\n7. 备份 Sub-Store\n8. 恢复 Sub-Store\n9. 其他服务器来源与自动合并\n10. 本机动态订阅地址管理\n0. 返回\n'
  ui_menu_choice c '选择操作' 10
  case "$c" in
    1) jq -r '(.substore // {enabled:false,port:3001,version:"",frontend_version:""})|"Sub-Store：\(if .version=="" then "未安装" elif .enabled then "已启用" else "已停用" end)；本机端口：\(.port)","后端版本：\(.version)；前端版本：\(.frontend_version)"' "$SBM_STATE";;
    2)
      port=$(jq -r '.substore.port // 3001' "$SBM_STATE")
      current=$(jq -r '.substore.version // "未安装"' "$SBM_STATE"); current_frontend=$(jq -r '.substore.frontend_version // "未安装"' "$SBM_STATE")
      prompt_value port '本机端口' "$port"
      prompt_value version "后端版本（当前 $current）" 'latest'; prompt_value frontend "前端版本（当前 $current_frontend）" 'latest'
      substore_cli install --port "$port" --version "$version" --frontend-version "$frontend";;
    3) substore_cli enable;; 4) substore_cli disable;; 5) substore_cli access;;
    6) prompt_value name 'Sub-Store 来源名称' 'sb-manager'; substore_cli sync "$name";;
    7) prompt_value file '备份文件路径' "$SBM_BACKUPS/substore-$(now_stamp).tar.gz"; substore_cli backup "$file";;
    8) prompt_value file '备份文件路径' ''; confirm '恢复会覆盖 Sub-Store 当前数据，继续？' N && substore_cli restore "$file";;
    9) ui_open_submenu ui_substore_sources_menu;;
    10) ui_open_submenu ui_subscription_menu;;
  esac
}

ui_substore_sources_menu() {
  local c name url collection items
  printf '1. 查看来源与组合\n2. 添加/更新服务器来源（自动加入组合）\n3. 测试来源拉取\n4. 移除来源\n0. 返回\n'
  ui_menu_choice c '选择操作' 4
  case "$c" in
    1) substore_cli source list;;
    2|3|4)
      items=$(substore_source_list 1 | jq '[.[]|{id:.name,label:(.name+"（"+.source+"）")}]')
      ui_select_json name '订阅来源' "$items" '' "$([[ "$c" == 2 ]] && echo 1 || echo 0)" || { ui_cancel; return; }
      case "$c" in
        2)
          printf '填写对方服务器生成的动态订阅 URL；首次接入后无需重复导入节点。\n'
          prompt_secret url '订阅 URL（输入隐藏）'
          prompt_value collection '组合名称' 'sb-manager-all'
          substore_cli source add "$name" "$url" "$collection";;
        3) substore_cli source check "$name";;
        4) confirm "确认从 Sub-Store 移除来源 $name？" N && substore_cli source remove "$name";;
      esac;;
  esac
}

ui_subscription_menu() {
  local c base duration id items
  printf '1. 生成动态订阅地址（节点变更后自动更新）\n2. 查看有效期与状态\n3. 撤销订阅地址\n0. 返回\n'
  ui_menu_choice c '选择操作' 3
  case "$c" in
    1)
      base=$(jq -r --arg service "http://127.0.0.1:$SBM_SUBSCRIPTION_PORT" 'first(.tunnel.routes[]?|select(.service==$service and .path=="")|"https://"+.hostname) // ""' "$SBM_STATE")
      printf '公网入口需已通过 HTTPS/Tunnel 转发到本机订阅服务；SSH 转发可留空。\n'
      ui_prompt_optional base '已有 HTTPS 订阅入口（如 https://sub.example.com）' "$base"
      prompt_value duration '有效期（如 30d；never 持续有效，直至撤销）' 'never'
      local -a args=("$duration" mixed --live)
      [[ -z "$base" ]] || args+=(--base-url "$base")
      subscription_create_cli "${args[@]}";;
    2) subscription_list;;
    3)
      items=$(subscription_list 1 | jq '[.[]|{id,label:(.id+"（"+.status+", "+(if .live then "动态" else "快照" end)+"）")}]')
      ui_select_json id '订阅地址' "$items" || { ui_cancel; return; }
      confirm "确认撤销订阅 $id？使用此地址的客户端将无法再拉取。" N && subscription_revoke "$id";;
  esac
}

ui_main() {
  [[ -t 0 ]] || { sb_help; return; }
  local choice page
  local -a page_args=()
  SBM_UI_RESULT=0
  while true; do
    ui_header
    printf 'Enter 返回；输入 r 留在当前页。\n'
    printf '填写时 Enter 保留当前值；q 取消；主菜单 0 / q 退出。\n'
    if [[ $(jq '.nodes|length' "$SBM_STATE") == 0 ]]; then
      printf '还没有节点：输入 2 开始创建。\n'
    fi
    printf '1. 状态\n2. 添加节点\n3. 节点管理\n4. 分享/导出\n5. 客户端配置\n6. 证书\n7. Tunnel\n8. 更新\n9. API\n10. Realm\n11. 日志\n12. 诊断\n13. 备份\n14. 设置\n15. 防火墙\n16. 流量\n17. 通知\n18. 模板/批量\n19. 卸载\n20. Sub-Store\n0. 退出\n\n'
    # Stay at the root on empty input without reopening a page or redrawing
    # the entire menu for every buffered Enter key.
    while true; do
      prompt_value choice '选功能（Enter 留在主菜单）' '' || return 0
      [[ -z "$choice" ]] || break
    done
    page=''
    page_args=()
    SBM_UI_RESULT=0
    case "$choice" in
      1) page=status_summary;;
      2) page=ui_add_node;; 3) page=ui_manage_nodes;; 4) page=ui_share_export_menu;;
      5) page=ui_client_export_menu;; 6) page=ui_cert_menu;; 7) page=ui_tunnel_menu;;
      8) page=ui_update_menu;; 9) page=ui_api_menu;; 10) page=ui_realm_menu;;
      11) page=show_logs; page_args=(all 100);; 12) page=ui_doctor_menu;; 13) page=ui_backup_menu;;
      14) page=ui_settings_menu;; 15) page=ui_firewall_menu;; 16) page=ui_traffic_menu;;
      17) page=ui_notification_health_menu;; 18) page=ui_template_menu;;
      19) page=ui_uninstall_menu;; 20) page=ui_substore_menu;;
      0|q) return 0;; *) log_error '选择无效'; continue;;
    esac
    ui_menu_loop "$page" "${page_args[@]}"
    case "$SBM_UI_RESULT" in
      201|202) return 0;;
      203) ui_reload;;
    esac
  done
}
