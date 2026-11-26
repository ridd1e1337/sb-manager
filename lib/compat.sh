#!/usr/bin/env bash
# shellcheck shell=bash

# Which client formats can express a node. Every export refuses a node it
# cannot describe completely, so trying each one is the authoritative answer.
node_compat_link() { node_substore_line "$1"; }

node_compat() {
  local id=$1 json=${2:-0} rows='[]' name label fn out err rc reason ok
  [[ -n "$(state_get_node "$id" 2>/dev/null)" ]] || die "节点不存在：$id"
  err=$(mktemp "$SBM_RUN/compat.XXXXXX") || return 1
  while IFS='|' read -r name label fn; do
    [[ -n "$name" ]] || continue
    rc=0; out=$( ( "$fn" "$id" ) 2>"$err" ) || rc=$?
    reason=$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^\[[A-Z]*\] *//' "$err" | awk 'NF' | tail -n 1)
    if (( rc == 0 )) && [[ -n "$out" ]]; then ok=true; reason=''; else ok=false; [[ -n "$reason" ]] || reason='这个协议没有对应的客户端配置'; fi
    rows=$(jq -c --arg c "$name" --arg l "$label" --argjson ok "$ok" --arg r "$reason" '. + [{client:$c,label:$l,ok:$ok,reason:$r}]' <<<"$rows")
  done <<'EOF_CLIENTS'
link|分享链接 / Sub-Store|node_compat_link
singbox|sing-box|node_client_outbound
mihomo|mihomo|node_mihomo_client_outbound
EOF_CLIENTS
  rm -f "$err"
  if [[ "$json" == 1 ]]; then jq . <<<"$rows"; return 0; fi
  printf '客户端兼容性（节点 %s）：\n' "$id"
  jq -r '.[] | "  " + (if .ok then "[可用]   " else "[不可用] " end) + .label + (if .ok then "" else "：" + .reason end)' <<<"$rows"
}

# --dry-run node add: validate the candidate without installing anything and
# say which clients could use the node.
node_add_cert() {
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then
    [[ -s "$SBM_CERTS/$1/fullchain.pem" ]] || NODE_ADD_CERT_MISSING=$1
    return 0
  fi
  _cert_prepare_node_domain "$1"
}

node_add_preview() {
  local candidate=$1 id=$2 tmp
  if [[ -n "${NODE_ADD_CERT_MISSING:-}" ]]; then
    state_validate "$candidate" || return 1
    log_warn "域名 ${NODE_ADD_CERT_MISSING} 还没有证书：添加时会自动申请；本次预检没有做内核校验。"
  else
    tmp=$(mktemp "$SBM_RUN/node-add-check.XXXXXX") || return 1
    if ! ( config_render_validated "$candidate" "$tmp" "$SBM_RUN/node-add-check.log" ); then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
    log_ok '预检通过：内核接受生成的配置（没有保存任何改动）。'
  fi
  ( SBM_STATE=$candidate; node_compat "$id" "${SBM_OUTPUT_JSON:-0}" )
}
