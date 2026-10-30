#!/usr/bin/env bash
# shellcheck shell=bash

# Keep the existing nginx_stream state key and topology helpers so saved
# routes, exports, backups and per-node accounting work with either backend.
mux_backend() {
  jq -r '.nginx_stream.backend // (if .nginx_stream.enabled==true or ((.nginx_stream.routes // [])|length)>0 then "nginx" else "sing-box" end)' "${1:-$SBM_STATE}"
}

mux_backend_label() {
  case "$(mux_backend "${1:-$SBM_STATE}")" in
    sing-box) printf 'sing-box 内置';;
    nginx) printf 'Nginx Stream';;
    *) return 1;;
  esac
}

mux_uses_nginx() {
  nginx_stream_state_enabled "${1:-$SBM_STATE}" && [[ $(mux_backend "${1:-$SBM_STATE}") == nginx ]]
}

mux_service() {
  if [[ $(mux_backend "${1:-$SBM_STATE}") == sing-box ]]; then printf '%s\n' "$SBM_SERVICE"
  else printf '%s\n' "$SBM_NGINX_STREAM_SERVICE"; fi
}

mux_reserved_port() {
  local state=$1 port=$2
  [[ "$port" != "$SBM_SUBSCRIPTION_PORT" ]] || return 0
  jq -e --argjson port "$port" '
    (.api.enabled==true and .api.port==$port)
    or (.realm.enabled==true and .realm.port==$port)
    or (.substore.enabled==true and .substore.port==$port)
  ' "$state" >/dev/null
}

mux_frontend_available() {
  local state=${1:-$SBM_STATE} port=${2:-443} owner=''
  # Adding routes to an already-active frontend does not require another bind.
  if [[ $(jq -r '.nginx_stream.enabled // false' "$state") == true && $(jq -r '.nginx_stream.port' "$state") == "$port" ]]; then
    return 0
  fi
  host_port_in_use tcp "$port" || return 0
  if command_exists ss; then
    owner=$(ss -H -ltnp 2>/dev/null | awk -v p=":$port" '$0 ~ p {print $0; exit}' | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' || true)
  fi
  if [[ "$owner" == *sing-box* || "$owner" == *ld-musl* || "$owner" == *ld-linux* ]]; then
    # The candidate transaction will move selected manager nodes behind the
    # frontend before restarting sing-box. Other direct nodes are rejected by
    # state validation, so an existing manager listener is safe to transition.
    return 0
  fi
  if [[ -n "$owner" ]]; then
    log_error "TCP/SNI 复用未启用：${port}/TCP 已被 $owner 占用。不会修改现有网站或服务。"
  else
    log_error "TCP/SNI 复用未启用：${port}/TCP 已被其他服务占用。不会修改现有网站或服务。"
  fi
  log_info '请让现有 Caddy/Nginx 的 L4/SNI 配置转发到节点后端，或选择其他公网端口。'
  return 1
}

_mux_auto_configure() {
  local ids=$1 public_port=${2:-443} backend=${3:-} candidate id node sni route backend_port tmp
  local -a node_ids=()
  [[ "$ids" == all ]] && ids=$(jq -r '[.nodes[]? | select(.enabled==true) | select(
    (.protocol|IN("anytls","trojan","shadowtls"))
    or (.protocol=="vless" and (.security|IN("tls","reality")))
    or (.protocol=="naive" and (.network // "tcp")=="tcp")
  ) | .id] | join(",")' "$SBM_STATE")
  IFS=, read -r -a node_ids <<<"$ids"
  ((${#node_ids[@]} > 0)) || { log_error '没有可加入 TCP/SNI 复用的启用节点。'; return 1; }
  mux_frontend_available "$SBM_STATE" "$public_port" || return 1
  candidate=$(state_candidate) || return 1
  cp "$SBM_STATE" "$candidate" || { rm -f "$candidate"; return 1; }
  for id in "${node_ids[@]}"; do
    id=${id//[[:space:]]/}
    [[ -n "$id" ]] || continue
    node=$(jq -c --arg id "$id" '.nodes[]? | select(.id==$id)' "$candidate")
    [[ -n "$node" ]] || { rm -f "$candidate"; log_error "节点不存在：$id"; return 1; }
    [[ $(jq -r '.enabled' <<<"$node") == true ]] || { rm -f "$candidate"; log_error "节点未启用：$id"; return 1; }
    nginx_stream_supported_node "$node" || { rm -f "$candidate"; log_error "节点不支持 TCP/SNI 复用：$id"; return 1; }
    route=$(jq -c --arg id "$id" '.nginx_stream.routes[]? | select(.node_id==$id)' "$candidate")
    [[ -z "$route" ]] || continue
    sni=$(nginx_stream_node_sni "$node")
    validate_domain "$sni" || { rm -f "$candidate"; log_error "节点 $id 的 SNI 无效：$sni"; return 1; }
    if jq -e --arg sni "${sni,,}" '.nginx_stream.routes[]? | select((.sni|ascii_downcase)==$sni)' "$candidate" >/dev/null; then
      rm -f "$candidate"; log_error "SNI 已被其他节点使用：$sni"; return 1
    fi
    backend_port=$(nginx_stream_choose_backend_port "$candidate") || { rm -f "$candidate"; return 1; }
    tmp=$(mktemp "$SBM_RUN/mux-auto.XXXXXX") || { rm -f "$candidate"; return 1; }
    jq --arg id "$id" --arg sni "${sni,,}" --argjson p "$backend_port" \
      '.nginx_stream.routes += [{node_id:$id,sni:$sni,backend_port:$p}]' "$candidate" >"$tmp" || { rm -f "$tmp" "$candidate"; return 1; }
    chmod 0600 "$tmp" && mv -f "$tmp" "$candidate" || { rm -f "$tmp" "$candidate"; return 1; }
  done
  if ! jq --argjson port "$public_port" --arg backend "$backend" '
    .nginx_stream.enabled=true | .nginx_stream.port=$port
    | if $backend=="" then . else .nginx_stream.backend=$backend end
  ' "$candidate" >"$candidate.tmp"; then
    rm -f "$candidate" "$candidate.tmp"; return 1
  fi
  mv -f "$candidate.tmp" "$candidate" || { rm -f "$candidate" "$candidate.tmp"; return 1; }
  if ! apply_candidate_state "$candidate" mux-auto; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已配置并启用 TCP/SNI 复用：$(jq '.nginx_stream.routes|length' "$SBM_STATE") 条路由，共用 ${public_port}/TCP。"
}

mux_auto_configure() { with_state_transaction mux-auto _mux_auto_configure "$@"; }

mux_builtin_config() {
  local state=$1
  if ! nginx_stream_state_enabled "$state" || [[ $(mux_backend "$state") != sing-box ]]; then
    printf '{"inbounds":[],"rules":[]}\n'
    return 0
  fi
  # Only the frontend is sniffed. Backend inbounds re-enter routing after
  # authentication and must never match these forwarding rules a second time.
  # The final reject is mandatory: the public direct inbound is not an open
  # forward proxy, and no domain is ever used as a network destination.
  jq '{
    inbounds:[{
      type:"direct",tag:"sbm-mux-tcp",listen:.nginx_stream.listen,
      listen_port:.nginx_stream.port,network:"tcp",
      override_address:"127.0.0.1",override_port:1
    }],
    rules:([
      {inbound:["sbm-mux-tcp"],action:"sniff",sniffer:["tls"],timeout:"300ms"}
    ] + [.nginx_stream.routes[] | {
      inbound:["sbm-mux-tcp"],protocol:["tls"],domain:[(.sni|ascii_downcase)],
      action:"route",outbound:"direct",override_address:"127.0.0.1",
      override_port:.backend_port
    }] + [{inbound:["sbm-mux-tcp"],action:"reject"}])
  }' "$state"
}

_mux_set_backend() {
  local backend=$1 candidate
  case "$backend" in sing-box|nginx) ;; *) usage_die '复用方式只能是 sing-box 或 nginx。';; esac
  candidate=$(state_candidate) || return 1
  if ! jq --arg backend "$backend" '.nginx_stream.backend=$backend' "$SBM_STATE" >"$candidate" \
    || ! apply_candidate_state "$candidate" mux-backend; then
    rm -f "$candidate"; return 1
  fi
  rm -f "$candidate"
  log_ok "TCP/SNI 复用方式已设置为 $(mux_backend_label)。"
}

mux_set_backend() { with_state_transaction mux-backend _mux_set_backend "$@"; }

mux_cli() {
  local alias=$1 action=${2:-status} port='' backend='' json=${SBM_OUTPUT_JSON:-0}
  shift
  (($# == 0)) || shift
  case "$action" in
    status)
      if [[ ${1:-} == --json ]]; then json=1; shift; fi
      (($# == 0)) || usage_die '用法：sb mux status [--json]'
      nginx_stream_status "$json";;
    enable)
      [[ "$alias" != nginx-stream ]] || backend=nginx
      if [[ $# -gt 0 && "$1" != --backend ]]; then port=$1; shift; fi
      if [[ ${1:-} == --backend ]]; then backend=${2:?缺少复用方式}; shift 2; fi
      (($# == 0)) || usage_die '用法：sb mux enable [PORT] [--backend sing-box|nginx]'
      nginx_stream_enable "$port" "$backend";;
    disable)
      (($# == 0)) || usage_die '用法：sb mux disable'
      nginx_stream_disable;;
    backend)
      (($# == 1)) || usage_die '用法：sb mux backend sing-box|nginx'
      mux_set_backend "$1";;
    auto)
      local ids=all auto_port=443 auto_backend=''
      if [[ -n ${1:-} && ${1:-} != --port && ${1:-} != --backend ]]; then ids=$1; shift; fi
      while (($#)); do
        case "$1" in
          --port) auto_port=${2:?缺少端口}; shift 2;;
          --backend) auto_backend=${2:?缺少复用方式}; shift 2;;
          *) usage_die '用法：sb mux auto [all|NODE1,NODE2,...] [--port 443] [--backend sing-box|nginx]';;
        esac
      done
      mux_auto_configure "$ids" "$auto_port" "$auto_backend";;
    route)
      action=${1:-list}
      (($# == 0)) || shift
      case "$action" in
        list) (($# == 0)) || usage_die '用法：sb mux route list'; nginx_stream_route_list;;
        add)
          (( $# == 2 || $# == 3 )) || usage_die '用法：sb mux route add NODE_ID SNI [BACKEND_PORT]'
          nginx_stream_route_add "$@";;
        remove|del)
          (($# == 1)) || usage_die '用法：sb mux route remove NODE_ID'
          nginx_stream_route_remove "$1";;
        *) usage_die '用法：sb mux route list|add NODE_ID SNI [BACKEND_PORT]|remove NODE_ID';;
      esac;;
    *) usage_die '用法：sb mux status|enable [PORT] [--backend sing-box|nginx]|disable|backend sing-box|nginx|auto [NODE_IDS]|route ...';;
  esac
}
