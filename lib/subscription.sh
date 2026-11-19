#!/usr/bin/env bash
# shellcheck shell=bash

subscription_duration_seconds() {
  local value=$1 number unit
  [[ "$value" =~ ^([1-9][0-9]{0,4})([hd])$ ]] || die '有效期格式应为 24h 或 7d（最多五位数字）。'
  number=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
  [[ "$unit" == h ]] && printf '%s\n' "$((number * 3600))" || printf '%s\n' "$((number * 86400))"
}

# Build every client format. With NODE USER the bundle contains only that
# user and carries usage for the Subscription-Userinfo header.
subscription_build_bundle() (
  local output=$1 node_id=${2:-} user_id=${3:-} stage format line active=true userinfo=null usage='{}'
  mkdir -p "$(dirname "$output")" || return 1
  stage=$(mktemp -d "$(dirname "$output")/.bundle.XXXXXX") || return 1
  trap 'rm -rf -- "$stage"' EXIT
  if [[ -n "$user_id" ]]; then
    active=$(jq -r --arg n "$node_id" --arg u "$user_id" '[.nodes[]?|select(.id==$n and .enabled)|.users[]|select(.id==$u and .enabled)]|length>0' "$SBM_STATE") || return 1
    [[ ! -s "${SBM_USER_USAGE:-}" ]] || usage=$(jq -c --arg k "$node_id:$user_id" '.users[$k] // {}' "$SBM_USER_USAGE") || return 1
    userinfo=$(jq -c --arg n "$node_id" --arg u "$user_id" --argjson usage "$usage" '
      first(.nodes[]?|select(.id==$n)|.users[]|select(.id==$u)) as $user |
      {upload:($usage.upload_bytes // 0),download:($usage.download_bytes // 0),
       total:($user.limits.quota_bytes // 0),expire:($user.limits.expires_at // 0),
       suspended:($user.limits.suspended // null)}' "$SBM_STATE") || return 1
  fi
  if [[ "$active" != true ]]; then
    : >"$stage/links"; printf '[]\n' >"$stage/compatibility.json"
    for format in mixed tun xray mihomo; do printf 'null\n' >"$stage/$format.json"; done
  elif [[ -n "$user_id" ]]; then
    if line=$(node_substore_line "$node_id" "$user_id" 2>/dev/null); then printf '%s\n' "$line" >"$stage/links"; else : >"$stage/links"; fi
    export_vless_compatibility_json | jq --arg n "$node_id" --arg u "$user_id" 'map(select(.node_id==$n and .user_id==$u))' >"$stage/compatibility.json" || return 1
    for format in mixed tun; do
      export_client_config "$stage/$format.json" "$format" hijack '' "$node_id" "$user_id" >/dev/null 2>&1 || printf 'null\n' >"$stage/$format.json"
    done
    export_xray_client_config "$stage/xray.json" "$node_id" "$user_id" >/dev/null 2>&1 || printf 'null\n' >"$stage/xray.json"
    export_mihomo_client_config "$stage/mihomo.json" "$node_id" "$user_id" >/dev/null 2>&1 || printf 'null\n' >"$stage/mihomo.json"
  else
    export_substore_links "$stage/links" || return 1
    export_vless_compatibility_json >"$stage/compatibility.json" || return 1
    # Each profile has its own compatibility boundary. Failure of one client
    # format must not roll back a valid server node or corrupt other formats.
    for format in mixed tun; do
      if ! export_client_config "$stage/$format.json" "$format" >/dev/null; then
        printf 'null\n' >"$stage/$format.json" || return 1
      fi
    done
    if ! export_xray_client_config "$stage/xray.json" >/dev/null; then printf 'null\n' >"$stage/xray.json" || return 1; fi
    if ! export_mihomo_client_config "$stage/mihomo.json" >/dev/null; then printf 'null\n' >"$stage/mihomo.json" || return 1; fi
  fi
  jq -n --arg updated "$(now_iso)" --rawfile links "$stage/links" --argjson userinfo "$userinfo" --argjson active "$active" \
    --slurpfile mixed "$stage/mixed.json" --slurpfile tun "$stage/tun.json" \
    --slurpfile xray "$stage/xray.json" --slurpfile mihomo "$stage/mihomo.json" --slurpfile compatibility "$stage/compatibility.json" '
      {schema_version:1,updated_at:$updated,substore:$links,compatibility:$compatibility[0],
       profiles:{mixed:$mixed[0],tun:$tun[0],xray:$xray[0],mihomo:$mihomo[0]}} |
      (if $userinfo==null then . else .userinfo=$userinfo end) |
      .errors=(.profiles|to_entries|map(select(.value==null)|{key:.key,value:(if $active then "没有兼容节点，或此格式的客户端配置无法生成；请查看 compatibility。" else "该用户已停用、到期或流量用尽。" end)})|from_entries)
    ' >"$stage/bundle.json" || return 1
  chmod 0640 "$stage/bundle.json" && set_group_if_exists "$SBM_SERVICE_USER" "$stage/bundle.json" || return 1
  mv -f "$stage/bundle.json" "$output"
)

# Usage changes without a state change; refresh only user-scoped bundles.
subscription_refresh_user_bundles() {
  local meta node_id user_id now
  [[ -d "$SBM_SUBSCRIPTIONS" ]] || return 0
  now=$(date +%s)
  for meta in "$SBM_SUBSCRIPTIONS"/*.meta.json; do
    [[ -f "$meta" ]] || continue
    user_id=$(jq -r --argjson now "$now" 'select(.expires_at_epoch==null or .expires_at_epoch>$now) | .user_id // ""' "$meta") || continue
    [[ -n "$user_id" ]] || continue
    node_id=$(jq -r '.node_id' "$meta")
    state_user_exists "$node_id" "$user_id" || continue
    subscription_build_bundle "${meta%.meta.json}.user.json" "$node_id" "$user_id" || log_warn "用户订阅刷新失败：$node_id/$user_id"
  done
}

subscription_refresh_live() {
  local extra_mode=${1:-} meta mode now needed=false node_id user_id
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || return 0
  now=$(date +%s)
  for meta in "$SBM_SUBSCRIPTIONS"/*.meta.json; do
    [[ -f "$meta" ]] || continue
    mode=$(jq -er --argjson now "$now" 'select(.live==true and (.expires_at_epoch==null or .expires_at_epoch>$now)) | .mode' "$meta") || continue
    user_id=$(jq -r '.user_id // ""' "$meta")
    if [[ -n "$user_id" ]]; then
      node_id=$(jq -r '.node_id' "$meta")
      if state_user_exists "$node_id" "$user_id"; then
        subscription_build_bundle "${meta%.meta.json}.user.json" "$node_id" "$user_id" || return 1
      else rm -f "${meta%.meta.json}.user.json"; fi
      continue
    fi
    case "$mode" in mixed|tun|xray|mihomo) needed=true;; *) log_error '动态订阅模式无效。'; return 1;; esac
  done
  if [[ -n "$extra_mode" ]]; then
    case "$extra_mode" in mixed|tun|xray|mihomo) needed=true;; *) return 1;; esac
  fi
  [[ "$needed" == true ]] || return 0
  subscription_build_bundle "$SBM_SUBSCRIPTIONS/live.json"
}

subscription_write_service() {
  local python unit backend
  if ! command_exists python3 && ! command_exists python && declare -F dependency_require_feature >/dev/null 2>&1; then
    dependency_require_feature subscription || die '订阅服务需要 python3；请运行 sb deps install subscription。'
  fi
  python=$(command -v python3 || command -v python || true)
  [[ -n "$python" ]] || die '订阅服务需要 python3。'
  backend=$(effective_init_system)
  mkdir -p "$SBM_SUBSCRIPTIONS"
  chown root:"$SBM_SERVICE_USER" "$SBM_SUBSCRIPTIONS" 2>/dev/null || true
  chmod 0750 "$SBM_SUBSCRIPTIONS"
  case "$backend" in
    systemd)
      unit="$SBM_SYSTEMD_DIR/$SBM_SUBSCRIPTION_SERVICE"
      mkdir -p "$SBM_SYSTEMD_DIR"
      cat >"$unit" <<EOF_UNIT
[Unit]
Description=sb-manager loopback subscription service
After=network.target

[Service]
Type=simple
User=$SBM_SERVICE_USER
Group=$SBM_SERVICE_USER
ExecStart=$python $SBM_LIB/libexec/subscription_server.py --root $SBM_SUBSCRIPTIONS --listen 127.0.0.1 --port $SBM_SUBSCRIPTION_PORT
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadOnlyPaths=$SBM_SUBSCRIPTIONS $SBM_LIB
TasksMax=128
MemoryMax=128M
UMask=0027

[Install]
WantedBy=multi-user.target
EOF_UNIT
      chmod 0644 "$unit"
      ;;
    openrc)
      write_openrc_supervised_service "$SBM_OPENRC_DIR/$(service_native_name "$SBM_SUBSCRIPTION_SERVICE")" \
        'sb-manager subscription' 'sb-manager loopback subscription service' "$python" \
        "$SBM_LIB/libexec/subscription_server.py --root $SBM_SUBSCRIPTIONS --listen 127.0.0.1 --port $SBM_SUBSCRIPTION_PORT" \
        "$SBM_SERVICE_USER" "$SBM_LOG_DIR/subscription.log" "$SBM_LOG_DIR/subscription.err.log" 'after firewall'
      ;;
  esac
}

subscription_reconcile() {
  local start=${1:-1} backend
  if ! find "$SBM_SUBSCRIPTIONS" -maxdepth 1 -type f -name '*.meta.json' -print -quit 2>/dev/null | grep -q .; then
    if [[ "$SBM_SKIP_INIT" != 1 ]] && service_exists "$SBM_SUBSCRIPTION_SERVICE"; then
      backend=$(effective_init_system)
      service_disable "$SBM_SUBSCRIPTION_SERVICE" || true
      service_stop "$SBM_SUBSCRIPTION_SERVICE" || true
      case "$backend" in
        systemd) rm -f "$SBM_SYSTEMD_DIR/$SBM_SUBSCRIPTION_SERVICE" ;;
        openrc) rm -f "$SBM_OPENRC_DIR/$(service_native_name "$SBM_SUBSCRIPTION_SERVICE")" ;;
      esac
      service_reload_manager || true
    fi
    return 0
  fi
  subscription_write_service
  [[ "$SBM_SKIP_INIT" == 1 || "$start" != 1 ]] && return 0
  service_reload_manager
  service_enable "$SBM_SUBSCRIPTION_SERVICE"
  service_restart "$SBM_SUBSCRIPTION_SERVICE"
  service_wait_active "$SBM_SUBSCRIPTION_SERVICE" 20 || return 1
}

_subscription_create() {
  local duration=${1:-7d} mode=${2:-mixed} live=${3:-false} base=${4:-} node_id=${5:-} user_id=${6:-} seconds now expires token digest profile substore_profile meta bundle
  [[ "$mode" == mixed || "$mode" == tun || "$mode" == xray || "$mode" == mihomo ]] || usage_die '客户端模式必须是 mixed、tun、xray 或 mihomo。'
  [[ "$live" == true || "$live" == false ]] || return 1
  now=$(date +%s)
  if [[ "$duration" == never && "$live" == true ]]; then expires=null
  else seconds=$(subscription_duration_seconds "$duration") || return 1; expires=$((now + seconds)); fi
  token=$(random_password 36); digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}')
  mkdir -p "$SBM_SUBSCRIPTIONS"
  profile="$SBM_SUBSCRIPTIONS/$digest.profile.json"; substore_profile="$SBM_SUBSCRIPTIONS/$digest.substore.txt"; meta="$SBM_SUBSCRIPTIONS/$digest.meta.json"; bundle="$SBM_SUBSCRIPTIONS/$digest.bundle.json"
  if ! (
    if [[ -n "$user_id" ]]; then subscription_build_bundle "$SBM_SUBSCRIPTIONS/$digest.user.json" "$node_id" "$user_id" || exit 1
    elif [[ "$live" == true ]]; then subscription_refresh_live "$mode" || exit 1
    else
      subscription_build_bundle "$bundle" || exit 1
    fi
    jq -n --arg id "${digest:0:12}" --arg mode "$mode" --argjson live "$live" --argjson created "$now" --argjson expires "$expires" \
      --arg node "$node_id" --arg user "$user_id" \
      '{schema_version:1,id:$id,mode:$mode,live:$live,created_at_epoch:$created,expires_at_epoch:$expires}
       + (if $user=="" then {} else {node_id:$node,user_id:$user} end)' >"$meta.tmp" || exit 1
    chmod 0640 "$meta.tmp" && set_group_if_exists "$SBM_SERVICE_USER" "$meta.tmp" && mv -f "$meta.tmp" "$meta" || exit 1
    subscription_reconcile 1
  ); then
    rm -f "$profile" "$substore_profile" "$bundle" "$meta" "$meta.tmp" "$SBM_SUBSCRIPTIONS/$digest.user.json"
    subscription_reconcile 1 || true
    return 1
  fi
  printf '订阅 ID：%s\n有效期至 epoch：%s\n本机 URL：http://127.0.0.1:%s/sub/%s\nSub-Store URL：http://127.0.0.1:%s/sub/%s?format=substore\n' \
    "${digest:0:12}" "$expires" "$SBM_SUBSCRIPTION_PORT" "$token" "$SBM_SUBSCRIPTION_PORT" "$token"
  printf '格式参数：?format=xray / ?format=mihomo / ?format=sing-box / ?format=substore / ?format=compatibility\n'
  [[ "$live" != true ]] || printf '更新方式：动态（节点变更后自动更新，URL 不变）\n'
  [[ -z "$base" ]] || printf '远程 Sub-Store URL：%s/sub/%s?format=substore\n' "${base%/}" "$token"
  log_warn '订阅令牌只显示一次。不要直接向公网开放该端口；请使用 SSH 转发或受认证的 TLS 代理。'
}
subscription_create() {
  [[ ${SBM_DRY_RUN:-0} == 0 ]] || usage_die '订阅创建不接受 --dry-run。'
  with_lock _subscription_create "$@"
}

subscription_create_cli() {
  local duration=7d mode=mixed live=false base='' positional=0 node_id='' user_id=''
  while (($#)); do
    case "$1" in
      --live) live=true; shift;;
      --user)
        [[ $# -ge 2 && "$2" == *:* ]] || usage_die '--user 格式为 NODE_ID:USER_ID'
        node_id=${2%%:*}; user_id=${2#*:}; shift 2;;
      --base-url) [[ $# -ge 2 ]] || usage_die '--base-url 缺少地址'; base=$2; shift 2;;
      --*) usage_die '用法：sb subscription create [7d|never] [mixed|tun|xray|mihomo] [--live] [--user NODE_ID:USER_ID] [--base-url HTTPS_URL]';;
      *)
        case "$positional" in 0) duration=$1;; 1) mode=$1;; *) usage_die '订阅参数过多。';; esac
        positional=$((positional+1)); shift;;
    esac
  done
  if [[ -n "$base" ]]; then
    [[ "$base" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]{1,5})?(/[-a-zA-Z0-9._~/]*)?$ ]] || usage_die '公网入口须为已经配置好的 HTTPS 地址，不含令牌、查询参数或片段。'
  fi
  if [[ -n "$user_id" ]]; then
    state_user_exists "$node_id" "$user_id" || usage_die "用户不存在：$node_id/$user_id"
    live=true
  fi
  subscription_create "$duration" "$mode" "$live" "$base" "$node_id" "$user_id"
}

subscription_list() {
  local json=${1:-0} meta now id mode expires status
  now=$(date +%s)
  if [[ "$json" == 1 ]]; then
    for meta in "$SBM_SUBSCRIPTIONS"/*.meta.json; do
      [[ -f "$meta" ]] || continue
      id=$(jq -r '.id' "$meta"); mode=$(jq -r '.mode' "$meta"); expires=$(jq -r '.expires_at_epoch' "$meta")
      status=$(subscription_meta_status "$meta" "$now")
      jq --arg status "$status" '{id,mode,live:(.live // false),expires_at_epoch,status:$status} + (if .user_id then {user:(.node_id+":"+.user_id)} else {} end)' "$meta"
    done | jq -s .
    return
  fi
  printf '%-14s %-8s %-14s %s\n' ID MODE EXPIRES_EPOCH STATUS
  for meta in "$SBM_SUBSCRIPTIONS"/*.meta.json; do
    [[ -f "$meta" ]] || continue
    id=$(jq -r '.id' "$meta"); mode=$(jq -r '.mode' "$meta"); expires=$(jq -r '.expires_at_epoch' "$meta")
    status=$(subscription_meta_status "$meta" "$now")
    [[ "$expires" != null ]] || expires='never'
    printf '%-14s %-8s %-14s %s (%s)\n' "$id" "$mode" "$expires" "$status" "$(jq -r 'if .live then "live" else "snapshot" end' "$meta")"
  done
}

subscription_meta_status() {
  jq -r --argjson now "$2" '
    if .live==true and .expires_at_epoch==null then "active"
    elif (.expires_at_epoch|type)=="number" then
      if .expires_at_epoch>$now then "active" else "expired" end
    else "invalid" end' "$1"
}

_subscription_revoke() {
  local token=$1 digest meta match=''
  if [[ "$token" =~ ^[a-f0-9]{12}$ ]]; then
    for meta in "$SBM_SUBSCRIPTIONS"/*.meta.json; do
      [[ -f "$meta" ]] || continue
      if [[ $(jq -r '.id' "$meta") == "$token" ]]; then
        [[ -z "$match" ]] || usage_die '订阅 ID 不唯一，请使用完整令牌。'
        match=${meta##*/}; match=${match%.meta.json}
      fi
    done
    [[ -n "$match" ]] || usage_die '订阅 ID 不存在。'
    digest=$match
  else digest=$(printf '%s' "$token" | sha256sum | awk '{print $1}'); fi
  [[ -f "$SBM_SUBSCRIPTIONS/$digest.meta.json" ]] || die '订阅令牌不存在。'
  rm -f "$SBM_SUBSCRIPTIONS/$digest.meta.json" "$SBM_SUBSCRIPTIONS/$digest.profile.json" "$SBM_SUBSCRIPTIONS/$digest.substore.txt" "$SBM_SUBSCRIPTIONS/$digest.bundle.json" "$SBM_SUBSCRIPTIONS/$digest.user.json"
  log_ok "订阅已撤销：${digest:0:12}"
}
subscription_revoke() {
  [[ ${SBM_DRY_RUN:-0} == 0 ]] || usage_die '订阅撤销不接受 --dry-run。'
  with_lock _subscription_revoke "$@"
}

subscription_status() {
  subscription_list "${1:-0}"
  [[ ${1:-0} == 1 ]] && return 0
  if [[ "$SBM_SKIP_INIT" != 1 ]] && service_exists "$SBM_SUBSCRIPTION_SERVICE"; then service_status_text "$SBM_SUBSCRIPTION_SERVICE" || true; fi
}
