#!/usr/bin/env bash
# shellcheck shell=bash

# Outbound subscriptions (3x-ui "outbound subs"): import a remote list of share
# links as sing-box outbounds tagged PREFIX-1…N, optionally grouped by an
# urltest/selector group of the same name. URLs may embed tokens, so they live in a 0600 secret.
# Refresh replaces the whole set in one transaction; if a rule still points at
# a tag that disappeared, validation fails and the old set is kept.

SBM_SINGBOX_OUTSUBS="${SBM_SINGBOX_OUTSUBS:-$SBM_SECRETS/singbox-outsubs.json}"
SBM_SINGBOX_OUTSUB_MAX="${SBM_SINGBOX_OUTSUB_MAX:-200}"

singbox_outsub_urls() { [[ -s "$SBM_SINGBOX_OUTSUBS" ]] && jq -c . "$SBM_SINGBOX_OUTSUBS" || printf '{}\n'; }

# Fetch and convert; prints [{tag,name,outbound}] for valid links only.
singbox_outsub_fetch() (
  local url=$1 prefix=$2 dir body links
  dir=$(mktemp -d "$SBM_RUN/outsub.XXXXXX") || return 1
  trap 'rm -rf -- "$dir"' EXIT
  curl --fail --silent --show-error --location --proto '=https,http' --max-redirs 3 --connect-timeout 15 --max-time 60 \
    --max-filesize 10485760 -A 'sb-manager' "$url" -o "$dir/body" || { log_error '订阅下载失败。'; return 1; }
  body=$(tr -d '\r' <"$dir/body")
  if ! grep -q '://' <<<"$body"; then body=$(tr -d '\n ' <<<"$body" | base64 -d 2>/dev/null | tr -d '\r') || { log_error '订阅内容既不是链接列表也不是 base64。'; return 1; }; fi
  links=$(grep -E '^[a-z0-9]+://' <<<"$body" | head -n "$SBM_SINGBOX_OUTSUB_MAX")
  [[ -n "$links" ]] || { log_error '订阅中没有可识别的分享链接。'; return 1; }
  # jq -R runs the converter once per line in a single process; duplicates are dropped.
  printf '%s\n' "$links" | jq -R -c --arg tag x -f "$SBM_LIB/libexec/share_to_singbox.jq" |
    jq -s -c --arg prefix "$prefix" '
      ([.[] | select(.error == null)] | unique_by(.outbound | del(.tag))) as $ok |
      {skipped:([.[] | select(.error != null) | .error] | group_by(.) | map({reason:.[0], count:length})),
       items:[$ok | to_entries[] | {tag:"\($prefix)-\(.key + 1)", name:.value.name, outbound:(.value.outbound | del(.tag))}]}'
)

_singbox_outsub_apply() {
  local name=$1 url=$2 prefix=$3 balancer=$4 result items outbounds tags count
  result=$(singbox_outsub_fetch "$url" "$prefix") || return 1
  items=$(jq -c '.items' <<<"$result"); count=$(jq 'length' <<<"$items")
  (( count > 0 )) || { log_error '订阅中没有可转换的节点。'; jq -r '.skipped[] | "  跳过 \(.count) 条：\(.reason)"' <<<"$result" >&2; return 1; }
  tags=$(jq -c '[.[].tag]' <<<"$items")
  # Replace this subscription's previous outbounds (secret objects + state refs).
  outbounds=$(singbox_outbounds_read | jq -c --arg prefix "$prefix" --argjson items "$items" '
    with_entries(select(.key | startswith($prefix + "-") | not)) + ($items | map({key:.tag, value:.outbound}) | from_entries)') || return 1
  _singbox_routing_commit '
    .routing.outbounds = ([.routing.outbounds[] | select(.tag | startswith($prefix + "-") | not)]
      + ($items | map({tag, type:.outbound.type, via:null, subscription:$name})))
    | .routing.subscriptions = ([(.routing.subscriptions // [])[] | select(.name != $name)]
      + [{name:$name, prefix:$prefix, balancer:$balancer, count:($tags|length), updated_at:$now}])
    | if $balancer == "none" then .routing.groups = ((.routing.groups // []) | map(select(.tag != $name)))
      else .routing.groups = ([(.routing.groups // [])[] | select(.tag != $name)]
        + [{tag:$name, outbounds:$tags, type:$balancer}]) end' "$outbounds" \
    --arg name "$name" --arg prefix "$prefix" --arg balancer "$balancer" --argjson items "$items" --argjson tags "$tags" --arg now "$(now_iso)" \
    || { log_error "若有路由规则直接指向 $prefix-N，节点数变化后会失效；建议让规则指向分组 $name。原节点保持不变。"; return 1; }
  (umask 077; jq -c --arg n "$name" --arg u "$url" '.[$n]=$u' <<<"$(singbox_outsub_urls)" >"$SBM_SINGBOX_OUTSUBS.tmp" && mv -f "$SBM_SINGBOX_OUTSUBS.tmp" "$SBM_SINGBOX_OUTSUBS") || return 1
  log_ok "出站订阅 $name：导入 $count 个节点（标签 $prefix-1…$prefix-$count$([[ "$balancer" == none ]] || echo "，分组 $name")）"
  jq -r '.skipped[] | "  跳过 \(.count) 条：\(.reason)"' <<<"$result"
}

_singbox_outsub_remove() {
  local name=$1 prefix outbounds
  prefix=$(jq -r --arg n "$name" '(.routing.subscriptions // [])[] | select(.name==$n) | .prefix' "$SBM_STATE")
  [[ -n "$prefix" ]] || { log_error "出站订阅不存在：$name"; return 1; }
  outbounds=$(singbox_outbounds_read | jq -c --arg prefix "$prefix" 'with_entries(select(.key | startswith($prefix + "-") | not))') || return 1
  _singbox_routing_commit '
    .routing.outbounds |= map(select(.tag | startswith($prefix + "-") | not))
    | .routing.groups = ((.routing.groups // []) | map(select(.tag != $name)))
    | .routing.subscriptions |= map(select(.name != $name))' "$outbounds" --arg name "$name" --arg prefix "$prefix" || return 1
  (umask 077; jq -c --arg n "$name" 'del(.[$n])' <<<"$(singbox_outsub_urls)" >"$SBM_SINGBOX_OUTSUBS.tmp" && mv -f "$SBM_SINGBOX_OUTSUBS.tmp" "$SBM_SINGBOX_OUTSUBS") || return 1
  log_ok "已删除出站订阅：$name"
}

# Refresh all (or one) subscriptions; used by the CLI and the daily task.
singbox_outsub_refresh() {
  local only=${1:-} row name prefix balancer url rc=0
  while IFS=$'\t' read -r name prefix balancer; do
    [[ -n "$name" ]] || continue
    url=$(jq -r --arg n "$name" '.[$n] // empty' <<<"$(singbox_outsub_urls)")
    [[ -n "$url" ]] || { log_error "出站订阅 $name 缺少地址。"; rc=1; continue; }
    with_state_transaction outsub _singbox_outsub_apply "$name" "$url" "$prefix" "$balancer" || rc=1
  done < <(jq -r --arg only "$only" '(.routing.subscriptions // [])[] | select($only=="" or .name==$only) | [.name,.prefix,.balancer] | @tsv' "$SBM_STATE")
  return "$rc"
}

singbox_outsub_cli() {
  local action=${1:-list} name url prefix balancer=urltest
  case "$action" in
    list) jq -r '(.routing.subscriptions // []) | if length==0 then "（无出站订阅）" else .[] | "\(.name)  \(.count) 个节点  前缀 \(.prefix)  分组 \(.balancer)  更新于 \(.updated_at)" end' "$SBM_STATE";;
    add)
      name=${2:-}; url=${3:-}
      [[ -n "$name" && -n "$url" ]] || usage_die '用法：sb outbound sub add NAME URL [--prefix P] [--type urltest|selector|none]'
      shift 3; prefix=$name
      while (($#)); do case "$1" in --prefix) prefix=${2:?}; shift 2;; --type|--balancer) balancer=${2:?}; [[ "$balancer" != leastPing ]] || balancer=urltest; shift 2;; *) usage_die "未知参数：$1";; esac; done
      singbox_routing_validate_tag "$name" && singbox_routing_validate_tag "$prefix-1" || return 1
      [[ "$balancer" =~ ^(urltest|selector|none)$ ]] || die '分组类型只能是 urltest、selector 或 none。'
      [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || die '订阅地址须为 http(s) URL。'
      jq -e --arg n "$name" '(.routing.subscriptions // [])|any(.name==$n)|not' "$SBM_STATE" >/dev/null || die "出站订阅已存在：$name"
      jq -e --arg p "$prefix" '(.routing.outbounds // [])|any(.tag|startswith($p + "-"))|not' "$SBM_STATE" >/dev/null || die "前缀 $prefix 与现有出站冲突。"
      require_root; with_state_transaction outsub _singbox_outsub_apply "$name" "$url" "$prefix" "$balancer";;
    refresh) require_root; singbox_outsub_refresh "${2:-}";;
    remove) [[ -n "${2:-}" ]] || usage_die '用法：sb outbound sub remove NAME'; require_root; with_state_transaction outsub _singbox_outsub_remove "$2";;
    *) usage_die '用法：sb outbound sub list|add NAME URL [--prefix P] [--type urltest|selector|none]|refresh [NAME]|remove NAME';;
  esac
}
