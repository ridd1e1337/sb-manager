#!/usr/bin/env bash
# shellcheck shell=bash

status_service_state() {
  local unit=$1
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then printf 'test\n'
  elif ! service_exists "$unit"; then printf 'not_installed\n'
  elif service_active "$unit"; then printf 'running\n'
  else printf 'stopped\n'; fi
}

status_certificates_json() {
  local cert domain path days valid
  {
    while IFS= read -r cert; do
      [[ -n "$cert" ]] || continue
      domain=$(jq -r '.domain' <<<"$cert")
      path=$(jq -r '.certificate_path // empty' <<<"$cert")
      [[ -s "$path" ]] || path="$SBM_CERTS/$domain/fullchain.pem"
      days=null; valid=false
      if [[ -s "$path" ]] && days=$(x509_days_remaining "$path" 2>/dev/null); then
        (( days >= 0 )) && valid=true
      else
        days=null
      fi
      jq -cn --arg domain "$domain" --arg path "$path" --argjson days "$days" --argjson valid "$valid" \
        '{domain:$domain,path:$path,valid:$valid,days_remaining:$days}'
    done < <(jq -c '.certificates[]?' "$SBM_STATE")
  } | jq -s .
}

# Listening sockets of sing-box, sampled once per status call. Alpine's
# gcompat launcher reports the process as ld-musl/ld-linux.
singbox_listeners_json() {
  if [[ "$SBM_SKIP_INIT" == 1 ]] || ! command_exists ss; then printf 'null\n'; return 0; fi
  ss -H -lntup 2>/dev/null | awk '/sing-box|ld-(musl|linux)/ { n=split($5,a,":"); print $1 "\t" a[n] }' |
    jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {p:.[0], port:(.[1]|tonumber? // 0)})'
}

# One jq pass over all nodes (per-node jq calls dominated status latency).
status_nodes_json() {
  local traffic_data listeners
  traffic_data=$(traffic_status_json_unlocked all)
  listeners=$(singbox_listeners_json) || listeners=null
  jq -c --argjson traffic "$traffic_data" --argjson listeners "$listeners" "$SBM_JQ_NODE_KINDS"'
    (.nginx_stream.enabled // false) as $mux | (.nginx_stream.routes // []) as $routes |
    [ .nodes[]? | . as $n | ([$routes[] | select(.node_id==$n.id)] | first) as $r |
      (if $mux and $r != null then {listen:"127.0.0.1", port:$r.backend_port} else {listen:$n.listen, port:$n.port} end) as $rt |
      ([$traffic[]? | select(.id==$n.id)] | first // {}) as $t |
      {id:$n.id, name:$n.name, protocol:$n.protocol, engine:"sing-box", enabled:$n.enabled,
       listening:(if ($n.enabled|not) then false elif $listeners==null then null
                  else all($n|kinds[]; . as $k | any($listeners[]; .p==$k and .port==$rt.port)) end),
       listen:$rt.listen, port:$rt.port,
       endpoint:($n.domain // $n.server_address // $n.client_address // ""),
       metadata:$n.metadata,
       traffic:($t + {percent_used:(if ($t.quota_bytes // null)==null then null else (($t.billable_bytes*10000/$t.quota_bytes|floor)/100) end)})} ]
  ' "$SBM_STATE"
}

status_collect_json_unlocked() {
  local sb_ver cf_ver openlist_ver nodes certs issues enabled_count service_state openlist_state tunnel_mode nginx_enabled nginx_state tunnel_state
  local ufw_state fail2ban_state traffic_count traffic_state pending=''
  host_probe_init
  traffic_usage_init_unlocked
  nodes=$(status_nodes_json)
  certs=$(status_certificates_json)
  issues=$(health_collect_json)
  sb_ver=$(core_current_version || true); cf_ver=$(cloudflared_current_version || true)
  openlist_ver=$(openlist_current_version || true)
  enabled_count=$(state_enabled_count)
  if [[ "$SBM_SKIP_INIT" == 1 ]]; then service_state=test
  elif ! state_runtime_required; then service_state=standby
  else service_state=$(status_service_state "$SBM_SERVICE"); fi
  # One read of the scalar settings used below.
  read -r tunnel_mode nginx_enabled traffic_count < <(jq -r '[.tunnel.mode, (.nginx_stream.enabled // false), ([.nodes[]? | select(.traffic.enabled==true)] | length)] | @tsv' "$SBM_STATE")
  if [[ "$tunnel_mode" == none ]]; then tunnel_state=off; else tunnel_state=$(status_service_state "$SBM_TUNNEL_SERVICE"); fi
  openlist_state=$(status_service_state "$SBM_OPENLIST_SERVICE")
  if [[ "$nginx_enabled" == true ]]; then nginx_state=$(status_service_state "$(mux_service)"); else nginx_state=off; fi
  if (( traffic_count == 0 )); then traffic_state=off
  elif traffic_runtime_complete; then traffic_state=running
  else traffic_state=degraded; fi
  ufw_state=$(host_ufw_state); fail2ban_state=$(host_f2b_state)
  if [[ -s "$SBM_VAR/updates/sing-box.json" ]]; then pending=$(jq -r '.latest // ""' "$SBM_VAR/updates/sing-box.json" 2>/dev/null || true); fi
  jq -n --arg now "$(now_iso)" --arg version "$SBM_VERSION" --arg init "$(init_system_label)" \
    --arg sb_ver "$sb_ver" --arg service_state "$service_state" --arg cf_ver "$cf_ver" \
    --arg openlist_ver "$openlist_ver" --arg openlist_state "$openlist_state" \
    --arg tunnel_mode "$tunnel_mode" --arg tunnel_state "$tunnel_state" --arg nginx_state "$nginx_state" \
    --arg mux_backend "$(mux_backend)" \
    --argjson nginx_port "$(jq -r '.nginx_stream.port // 443' "$SBM_STATE")" --arg traffic_state "$traffic_state" \
    --argjson traffic_count "$traffic_count" --arg ufw_state "$ufw_state" --arg fail2ban_state "$fail2ban_state" \
    --arg pending "$pending" --argjson enabled_count "$enabled_count" --argjson nodes "$nodes" --argjson certs "$certs" \
    --argjson issues "$issues" --argjson notify "$(notification_status_json)" --argjson health "$(jq -c '.health' "$SBM_STATE")" --argjson resources "$(health_resource_metrics_json)" \
    --argjson substore "$(jq -c '.substore // {enabled:false}' "$SBM_STATE")" --argjson shaping "$(jq -c '.shaping // {enabled:false}' "$SBM_STATE")" \
    --argjson groups "$(jq '(.traffic_groups // [])|length' "$SBM_STATE")" '
    {manager:{version:$version,checked_at:$now,init_system:$init},
     summary:{nodes:($nodes|length),enabled_nodes:$enabled_count,certificates:($certs|length),issues:($issues|length),
       errors:([$issues[]|select(.severity=="error")]|length),warnings:([$issues[]|select(.severity=="warning")]|length)},
     components:{
       sing_box:{version:(if $sb_ver=="" then null else $sb_ver end),state:$service_state,pending_version:(if $pending=="" then null else $pending end)},
       openlist:{version:(if $openlist_ver=="" then null else $openlist_ver end),state:$openlist_state},
       cloudflared:{version:(if $cf_ver=="" then null else $cf_ver end),mode:$tunnel_mode,state:$tunnel_state},
       nginx_stream:{state:$nginx_state,port:$nginx_port,backend:$mux_backend},traffic:{state:$traffic_state,configured_nodes:$traffic_count,shared_groups:$groups,shaping:$shaping},substore:$substore,
       ufw:{state:$ufw_state},fail2ban:{state:$fail2ban_state},notifications:$notify,health:($health + {resources_current:$resources})},
     nodes:$nodes,certificates:$certs,issues:$issues}
  '
}

status_json() { with_lock status_collect_json_unlocked; }

status_exit_code() {
  local data=$1
  [[ $(jq -r '.summary.errors // 0' <<<"$data") == 0 ]]
}

status_show() {
  local data id protocol state port usage tags name
  data=$(status_json)
  # Header and rows in one jq pass each; the panel calls this on every refresh.
  jq -r --arg bold "$C_BOLD" --arg reset "$C_RESET" '
    "\($bold)SB Manager \(.manager.version)\($reset)",
    "服务管理      : \(.manager.init_system)",
    "sing-box     : \(.components.sing_box.version // "未安装") (\(.components.sing_box.state))",
    "OpenList     : \(.components.openlist.version // "未安装") (\(.components.openlist.state))",
    "cloudflared  : \(.components.cloudflared.version // "未安装") (Tunnel: \(.components.cloudflared.mode)/\(.components.cloudflared.state))",
    "TCP/SNI 复用 : \(.components.nginx_stream.state) (\(.components.nginx_stream.port)/TCP, \(.components.nginx_stream.backend))",
    "安全组件      : UFW \(.components.ufw.state)，Fail2ban \(.components.fail2ban.state)",
    "通知/健康检查 : \(if .components.notifications.enabled then .components.notifications.provider else "off" end)/\(if .components.health.enabled then "on" else "off" end)",
    "节点/证书/异常: \(.summary.nodes)（启用 \(.summary.enabled_nodes)）/\(.summary.certificates)/\(.summary.issues)", ""' <<<"$data"
  printf '%-17s %-15s %-7s %-9s %-10s %-12s %s\n' 'ID' '协议' '状态' '端口' '流量' '地区/标签' '名称'
  while IFS=$'\t' read -r id protocol state port usage tags name; do
    printf '%-17s %-15s %-7s %-9s %-10s %-12s %s\n' "$id" "$(node_protocol_label "$protocol")" "$state" "$port" "$usage" "$tags" "$name"
  done < <(jq -r '.nodes[] | [.id, .protocol,
      (if .engine=="disabled" then "暂停" elif .enabled then (if .listening==false then "异常" else "启用" end) else "停用" end),
      (.port|tostring),
      (if .traffic.percent_used==null then "-" else (.traffic.percent_used|tostring)+"%" end),
      (([.metadata.region] + (.metadata.tags // []) | map(select(. != null and length>0)) | join(",")) | if .=="" then "-" else . end),
      .name] | @tsv' <<<"$data")
  jq -r 'if (.issues|length)>0 then "\n待处理异常：", (.issues[] | "- [\(.severity)] \(.message)") else empty end' <<<"$data"
  status_exit_code "$data"
}

status_summary() { status_show; }
