#!/usr/bin/env bash
# shellcheck shell=bash

SBM_REALITY_SITE_DIR="${SBM_REALITY_SITE_DIR:-$SBM_VAR/reality-site}"

reality_site_validate_state() {
  local state=$1
  jq -e --arg journal "$SBM_REALITY_SITE_DIR/current" '
    if .reality_site==null then true else
      .reality_site as $r |
      ($r.enabled==true and ($r.server|IN("nginx","caddy")) and
       ($r.domain|type=="string" and length>0) and $r.journal==$journal and
       ($r.backend_port|type=="number" and floor==. and .>=1024 and .<=65535) and
       .settings.vless_engine=="xray" and (.nginx_stream.enabled!=true) and
       ([.nodes[] | select(.id==$r.node_id and .enabled==true and .protocol=="vless" and
         .security=="reality" and .flow=="xtls-rprx-vision" and .port==443 and
         .domain==$r.domain and .handshake_server=="127.0.0.1" and .handshake_port==$r.backend_port and
         ((.xray.inbound // {})|length)==0 and ((.xray.outbound // {})|length)==0 and
         ((.singbox.inbound // {})|length)==0 and ((.singbox.outbound // {})|length)==0)]|length)==1 and
       all(.nodes[]; .port!=$r.backend_port)) end
  ' "$state" >/dev/null || {
    log_error 'Reality 网站入口必须由启用的 Xray Vision 节点维持；请先 sb reality detach 再停用、删除或修改其入口。'; return 1;
  }
}

reality_site_space() {
  local server=$1 security=$2 required=50331648 available
  [[ -x "$SBM_OPENLIST_BIN" ]] || required=$((required + 188743680))
  [[ -x "$SBM_XRAY_BIN" ]] || required=$((required + 41943040))
  if ! command_exists "$server"; then
    if [[ "$server" == caddy ]]; then required=$((required + 62914560)); else required=$((required + 10485760)); fi
  fi
  command_exists python3 || required=$((required + 41943040))
  if [[ "$security" == true ]] && ! command_exists ufw; then required=$((required + 20971520)); fi
  available=$(df -Pk "$SBM_CORE_DIR" | awk 'NR==2 {printf "%.0f", $4*1024}') || return 1
  [[ "$available" =~ ^[0-9]+$ ]] || return 1
  if (( available < required )); then
    log_error "安装预计至少需要 $((required / 1048576)) MiB 可用空间，程序所在分区只有 $((available / 1048576)) MiB。请释放空间或扩容；不会自动使用 /boot 或修改分区。"
    return 1
  fi
}

reality_site_choose_node() {
  local requested=$1 node ids
  if [[ -n "$requested" ]]; then
    validate_node_id "$requested" || return 1
    node=$(state_get_node "$requested") || return 1
    [[ -n "$node" && $(jq -r '.protocol' <<<"$node") == vless ]] || { log_error '--node 必须指定已有 VLESS 节点。'; return 1; }
    printf '%s\n' "$requested"; return 0
  fi
  ids=$(jq -r '.nodes[]|select(.enabled and .protocol=="vless" and .port==443)|.id' "$SBM_STATE") || return 1
  if [[ "$ids" == *$'\n'* ]]; then log_error '多个 VLESS 节点占用 443，请明确指定 --node。'; return 1; fi
  if [[ -n "$ids" ]]; then printf '%s\n' "$ids"
  else state_unique_id vless-reality; fi
}

reality_site_port_owner() {
  local id=$1 server=$2 row node
  node=$(state_get_node "$id") || return 1
  while IFS= read -r row; do
    [[ -z "$row" || "$row" == *"\"$server\""* ]] || {
      log_error "TCP/80 由其他程序使用；请选择现有网站程序，不会替换它。"; return 1;
    }
  done < <(ss -H -ltnp | awk '$4 ~ /:80$/')
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    if [[ "$row" == *"\"$server\""* ]]; then continue; fi
    if [[ -n "$node" ]] && jq -e '.enabled and .protocol=="vless" and .port==443' <<<"$node" >/dev/null; then
      if [[ "$row" == *'"xray"'* ]] && service_active "$SBM_XRAY_SERVICE"; then continue; fi
      if [[ "$row" == *sing-box* || "$row" == *ld-musl* || "$row" == *ld-linux* ]] && service_active "$SBM_SERVICE"; then continue; fi
    fi
    log_error 'TCP/443 已由其他服务或节点使用，未迁移入口。'; return 1
  done < <(ss -H -ltnp | awk '$4 ~ /:443$/')
}

reality_site_install_web() {
  local server=$1 distro backend unit="$1.service"
  distro=$(dependency_distro); backend=$(init_system)
  local -a packages=()
  case "$distro:$backend" in debian:systemd|alpine:openrc) ;; *) log_error '一键建站支持 Debian/Ubuntu systemd 与 Alpine OpenRC。'; return 1;; esac
  command_exists "$server" || packages+=("$server")
  if [[ "$backend" == openrc ]] && ! service_exists "$unit"; then packages+=("$server-openrc"); fi
  dependency_install_packages "${packages[@]}" || return 1
  if [[ "$server" == caddy && ! -e /etc/caddy/Caddyfile ]]; then
    mkdir -p /etc/caddy || return 1
    printf ':80 {\n  respond "No website configured." 200\n}\n' >/etc/caddy/Caddyfile || return 1
    chmod 0644 /etc/caddy/Caddyfile || return 1
  fi
  service_enable "$unit" && service_start "$unit" && service_wait_active "$unit" 20 2
}

reality_site_prepare_dns() {
  local domain=$1 zone
  cert_load_cloudflare_env || return 1
  zone=$(cloudflare_dns_zone "$domain") || return 1
  cloudflare_dns_prepare "$domain" "$zone"
}

reality_site_backend_port() {
  local port attempt
  for ((attempt=0; attempt<100; attempt++)); do
    port=$((20000 + RANDOM % 40000))
    host_port_in_use tcp "$port" && continue
    node_port_in_state tcp "$port" && continue
    mux_reserved_port "$SBM_STATE" "$port" && continue
    printf '%s\n' "$port"; return 0
  done
  log_error '没有可用的网站本机后端端口。'; return 1
}

reality_site_backend_ready() {
  local domain=$1 port=$2 response attempt
  for ((attempt=0; attempt<30; attempt++)); do
    response=$(curl --noproxy '*' --resolve "$domain:$port:127.0.0.1" --tlsv1.3 --tls-max 1.3 \
      -fsS --connect-timeout 1 --max-time 2 "https://$domain:$port/ping" 2>/dev/null || true)
    [[ "$response" == pong ]] && return 0
    sleep 1
  done
  log_error 'OpenList 本机 TLS 1.3 网站尚未就绪；请核对域名解析、证书和 HTTP80 可达性。'; return 1
}

reality_site_security() {
  local backup=$1 distro port_list unit
  local -a packages=()
  distro=$(dependency_distro)
  port_list=$(vps_ssh_ports) || return 1
  vps_service_snapshot "$backup" || return 1
  if command_exists fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
    touch "$backup/fail2ban-sshd-was-active" || return 1
  fi
  touch "$backup/fail2ban-service-touched" || return 1
  command_exists ufw || packages+=(ufw)
  command_exists fail2ban-client || packages+=(fail2ban)
  if [[ "$distro" == alpine ]]; then
    for unit in ufw fail2ban; do service_exists "$unit.service" || packages+=("$unit-openrc"); done
  elif [[ "$distro" == debian ]]; then packages+=(python3-systemd); fi
  dependency_install_packages "${packages[@]}" || return 1
  vps_init_ufw "$backup" "$port_list" && vps_init_fail2ban "$backup" "$port_list"
}

reality_site_candidate() {
  local id=$1 domain=$2 server=$3 binary=$4 config=$5 backend_port=$6 candidate=$7 node secret existing
  existing=$(state_get_node "$id") || return 1
  if [[ -n "$existing" ]]; then
    if ! jq -e 'all([.xray.inbound,.xray.outbound,.singbox.inbound,.singbox.outbound][]; (. // {}|length)==0)' <<<"$existing" >/dev/null; then
      log_error '所选节点含自定义入站或出站参数，请使用普通 VLESS 节点或新建入口。'; return 1
    fi
    node=$existing
  else
    node=$(jq -n --arg id "$id" --arg name "$domain" --arg at "$(now_iso)" '
      {id:$id,name:$name,protocol:"vless",created_at:$at,users:[{id:"default",name:$name,enabled:true,created_at:$at}],
       singbox:{inbound:{},outbound:{}},xray:{inbound:{},outbound:{}}}') || return 1
    secret=$(jq -n --arg uuid "$(random_uuid)" '{uuid:$uuid}') || return 1
    state_write_user_secret "$id" default "$secret" || return 1
  fi
  if [[ ! -s "$(state_secret_path "$id")" ]] || ! jq -e '.reality_private_key and .reality_public_key and .reality_short_id' "$(state_secret_path "$id")" >/dev/null; then
    secret=$(protocol_vless_generate_reality_secret xray) || return 1
    state_write_secret "$id" "$secret" || return 1
  fi
  node=$(jq --arg domain "$domain" --argjson port "$backend_port" '
    .enabled=true | .listen="::" | .port=443 | .security="reality" | .flow="xtls-rprx-vision"
    | .domain=$domain | .server_address=(if (.server_address // "")=="" then $domain else .server_address end)
    | .server_address_source="manual" | .handshake_server="127.0.0.1" | .handshake_port=$port
  ' <<<"$node") || return 1
  jq --argjson node "$node" --arg domain "$domain" --arg server "$server" --arg binary "$binary" --arg config "$config" \
    --argjson port "$backend_port" --argjson openlist_port "$(openlist_port)" --arg journal "$SBM_REALITY_SITE_DIR/current" '
    .settings.vless_engine="xray" | .settings.log_level="warn" | .nodes=(.nodes|map(select(.id!=$node.id)))+[$node]
    | .reality_site={enabled:true,node_id:$node.id,domain:$domain,server:$server,binary:$binary,config:$config,backend_port:$port,journal:$journal}
    | .openlist.sites=((.openlist.sites // []|map(select(.domain!=$domain)))+[{domain:$domain,server:$server,binary:$binary,config:$config,port:$openlist_port}])
  ' "$SBM_STATE" >"$candidate" || return 1
  state_normalize_v2_file "$candidate"
}

_reality_site_setup() (
  set -Eeuo pipefail
  local domain=$1 server=$2 requested=$3 security=$4 id binary config port candidate snapshot work
  local complete=false standard_changed=false reality_changed=false runtime_changed=false web_ready=false security_started=false recovered=true
  local -a context=()
  require_init_system
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || { log_error 'Reality 一键建站不接受 --dry-run。'; return 1; }
  if jq -e '.reality_site.enabled==true' "$SBM_STATE" >/dev/null; then
    log_error '已有 Reality 网站入口；请先查看 sb reality status 或使用 sb reality detach。'; return 1
  fi
  if nginx_stream_state_enabled "$SBM_STATE"; then log_error '请先解除已有 TCP/SNI 分流，再接入 Reality 网站。'; return 1; fi
  [[ ! -e "$SBM_REALITY_SITE_DIR/current" ]] || { log_error '存在未完成的 Reality 网站恢复记录，请先处理该记录。'; return 1; }
  dependency_require_feature probe || return 1
  id=$(reality_site_choose_node "$requested") || return 1
  reality_site_port_owner "$id" "$server" || return 1
  reality_site_space "$server" "$security" || return 1
  snapshot=$(snapshot_create reality-setup) || return 1
  work=$(mktemp -d "$SBM_RUN/reality-setup.XXXXXX") || return 1
  chmod 0700 "$work" || return 1
  printf '%s\n' "$$" >"$work/.operation-pid" || return 1
  export SBM_OPERATION_SNAPSHOT="$snapshot"
  # Recovery data exists only for this operation; the active website journal
  # below is needed to reverse the currently installed listener transformation.
  trap 'rc=$?; trap - EXIT; if [[ "$complete" != true ]]; then
    if [[ "$runtime_changed" == true ]]; then service_stop "$SBM_XRAY_SERVICE"; fi
    if [[ "$reality_changed" == true && -s "$SBM_REALITY_SITE_DIR/current/files.json" ]]; then python3 "$SBM_LIB/libexec/reality_site.py" rollback "$SBM_REALITY_SITE_DIR/current" || recovered=false; fi
    if [[ "$standard_changed" == true && -s "$work/site/files.json" ]]; then python3 "$SBM_LIB/libexec/openlist_proxy.py" rollback "$work/site" || recovered=false; fi
    if [[ "$web_ready" == true ]]; then openlist_web_reload "$server" || recovered=false; fi
    if [[ "$security_started" == true ]]; then vps_init_rollback "$work/security" || recovered=false; fi
    if [[ -s "$snapshot/cloudflare-dns.json" ]]; then cloudflare_dns_rollback "$snapshot" || recovered=false; fi
    snapshot_restore "$snapshot" || recovered=false
    if [[ "$recovered" == true ]]; then rm -rf -- "$SBM_REALITY_SITE_DIR/current"; else touch "$work/.recovery-pending" "$snapshot/.recovery-pending"; log_error "自动恢复未完成，临时记录最多保留 23 小时：$work；$snapshot"; fi
  fi
  if [[ "$complete" == true || "$recovered" == true ]]; then rm -rf -- "$work" "$snapshot"; fi
  exit "$rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  if [[ "$server" == nginx ]]; then
    _cert_prepare_node_domain "$domain" || return 1
  elif [[ -s "$SBM_CF_DNS_ENV" ]]; then
    reality_site_prepare_dns "$domain" || return 1
  elif ! host_resolves "$domain"; then
    log_error 'Caddy 需要域名已解析至本机，或先配置 Cloudflare DNS 凭据。'; return 1
  fi
  [[ -x "$SBM_XRAY_BIN" ]] || _xray_install || return 1
  if [[ ! -x "$SBM_OPENLIST_BIN" ]]; then _openlist_install || return 1
  else
    [[ -L "$SBM_OPENLIST_BIN" && $(readlink -f "$SBM_OPENLIST_BIN") == "$SBM_CORE_DIR/openlist/"* ]] || {
      log_error '现有 OpenList 不是本项目管理，拒绝自动发布网站。'; return 1;
    }
    jq -e '.scheme.address=="127.0.0.1" and .scheme.https_port==-1' "$SBM_OPENLIST_DATA/config.json" >/dev/null || {
      log_error 'OpenList 本机监听配置已改变，请先通过 sb openlist update 对齐。'; return 1;
    }
    service_start "$SBM_OPENLIST_SERVICE" && openlist_ready "$(openlist_port)" || return 1
  fi
  # OpenList keeps its initialized local DB if a later website step fails.
  # Preserve its matching administrator secret across the state rollback.
  if [[ -s "$SBM_SECRETS/openlist-admin.txt" && ! -e "$snapshot/secrets/openlist-admin.txt" ]]; then
    mkdir -p "$snapshot/secrets" || return 1
    cp -p "$SBM_SECRETS/openlist-admin.txt" "$snapshot/secrets/openlist-admin.txt" || return 1
  fi
  reality_site_install_web "$server" || return 1
  web_ready=true
  mapfile -t context < <(openlist_proxy_context "$server" true)
  (( ${#context[@]} == 2 )) || return 1
  binary=${context[0]}; config=${context[1]}
  website_mux_require_python || return 1
  if ! jq -e --arg domain "$domain" --arg server "$server" '.openlist.sites[]?|select(.domain==$domain and .server==$server)' "$SBM_STATE" >/dev/null; then
    standard_changed=true
    python3 "$SBM_LIB/libexec/openlist_proxy.py" prepare "$server" "$binary" "$config" "$domain" "$(openlist_port)" "$SBM_CERTS/$domain/fullchain.pem" "$SBM_CERTS/$domain/key.pem" "$work/site" || return 1
  fi
  port=$(reality_site_backend_port) || return 1
  mkdir -p "$SBM_REALITY_SITE_DIR" || return 1
  chmod 0700 "$SBM_REALITY_SITE_DIR" || return 1
  reality_changed=true
  python3 "$SBM_LIB/libexec/reality_site.py" prepare "$server" "$binary" "$config" "$port" "$SBM_REALITY_SITE_DIR/current" || return 1
  if [[ "$security" == true ]]; then
    mkdir -p "$work/security" || return 1
    security_started=true
    reality_site_security "$work/security" || return 1
  fi
  openlist_web_reload "$server" && reality_site_backend_ready "$domain" "$port" || return 1
  candidate="$work/state.json"
  reality_site_candidate "$id" "$domain" "$server" "$binary" "$config" "$port" "$candidate" || return 1
  runtime_changed=true
  apply_candidate_state "$candidate" reality-site || return 1
  openlist_site_ready "$domain" || return 1
  subscription_refresh_live || return 1
  complete=true
  rm -f "$SBM_REALITY_SITE_DIR/current"/*.log
  log_ok "OpenList 与 VLESS Vision Reality 已共用 443：https://$domain"
  log_info "节点：$id；网站程序：$server；更新客户端订阅以使用新的 SNI。"
  log_info "初始管理员信息：$SBM_SECRETS/openlist-admin.txt；节点分享：sb share $id"
)

reality_site_setup() {
  require_root
  local domain=${1:?缺少域名} server=${2:-nginx} id=${3:-} security=${4:-false}
  domain=${domain,,}; domain=${domain%.}
  validate_domain "$domain" || usage_die '无效的网站域名。'
  case "$server" in nginx|caddy) ;; *) usage_die '网站程序只能是 nginx 或 caddy。';; esac
  with_lock _reality_site_setup "$domain" "$server" "$id" "$security"
}

_reality_site_detach() (
  set -Eeuo pipefail
  local snapshot candidate info server domain complete=false work recovered=true
  info=$(jq -c '.reality_site // empty' "$SBM_STATE") || return 1
  [[ -n "$info" ]] || { log_info '未接入 Reality 网站。'; return 0; }
  server=$(jq -r '.server' <<<"$info"); domain=$(jq -r '.domain' <<<"$info")
  snapshot=$(snapshot_create reality-detach) || return 1
  work=$(mktemp -d "$SBM_RUN/reality-detach.XXXXXX") || return 1
  printf '%s\n' "$$" >"$work/.operation-pid" || return 1
  export SBM_OPERATION_SNAPSHOT="$snapshot"
  trap 'rc=$?; trap - EXIT; if [[ "$complete" != true ]]; then
    if [[ -s "$work/active/files.json" ]]; then python3 "$SBM_LIB/libexec/reality_site.py" rollback "$work/active" || recovered=false; fi
    openlist_web_reload "$server" || recovered=false
    snapshot_restore "$snapshot" || recovered=false
    if [[ "$recovered" != true ]]; then touch "$work/.recovery-pending" "$snapshot/.recovery-pending"; log_error "Reality 移除恢复未完成，临时记录最多保留 23 小时：$work；$snapshot"; fi
  fi
  if [[ "$complete" == true || "$recovered" == true ]]; then rm -rf -- "$work" "$snapshot"; fi
  exit "$rc"' EXIT
  candidate="$work/state.json"
  jq '.reality_site.node_id as $id | (.nodes[]|select(.id==$id)).enabled=false | del(.reality_site)' "$SBM_STATE" >"$candidate" || return 1
  apply_candidate_state "$candidate" reality-detach || return 1
  python3 "$SBM_LIB/libexec/reality_site.py" detach "$SBM_REALITY_SITE_DIR/current" "$work/active" || return 1
  openlist_web_reload "$server" && openlist_site_ready "$domain" || return 1
  subscription_refresh_live || return 1
  complete=true
  rm -rf -- "$SBM_REALITY_SITE_DIR/current"
  log_ok '网站已恢复直接使用 443；原 Reality 节点已停用，凭据保留。'
)

reality_site_detach() {
  require_root
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die 'Reality 移除不接受 --dry-run。'
  with_lock _reality_site_detach
}

reality_site_status() {
  jq -r 'if .reality_site==null then "Reality 网站：未接入" else .reality_site |
    "网站：https://\(.domain)","节点：\(.node_id) / Xray VLESS Vision Reality", "TCP入口：443 → 网站 127.0.0.1:\(.backend_port)","网站程序：\(.server)" end' "$SBM_STATE"
}

reality_site_cli() {
  local action=${1:-status} domain server=nginx id='' security=false
  (($# == 0)) || shift
  case "$action" in
    status) (($# == 0)) || usage_die '用法：sb reality status'; reality_site_status;;
    detach) (($# == 0)) || usage_die '用法：sb reality detach'; reality_site_detach;;
    setup)
      (($# >= 1)) || usage_die '用法：sb reality setup DOMAIN [nginx|caddy] [--node ID] [--init-vps]'
      domain=$1; shift
      if [[ ${1:-} == nginx || ${1:-} == caddy ]]; then server=$1; shift; fi
      while (($#)); do
        case "$1" in
          --node) id=${2:?缺少节点ID}; shift 2;;
          --init-vps) security=true; shift;;
          *) usage_die "未知 Reality 参数：$1";;
        esac
      done
      reality_site_setup "$domain" "$server" "$id" "$security";;
    *) usage_die '用法：sb reality status|setup DOMAIN [nginx|caddy] [--node ID] [--init-vps]|detach';;
  esac
}
