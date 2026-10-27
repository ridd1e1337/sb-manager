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
    *) usage_die '用法：sb mux status|enable [PORT] [--backend sing-box|nginx]|disable|backend sing-box|nginx|route ...';;
  esac
}
