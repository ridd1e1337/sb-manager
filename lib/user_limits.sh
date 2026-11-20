#!/usr/bin/env bash
# shellcheck shell=bash

# Per-user expiry for every multi-user protocol. Official sing-box builds do
# not expose per-user traffic counters, so traffic quotas and online-IP limits
# are an xray-manager feature; sb-manager offers node-level quotas instead
# (sb traffic set).
#
# A suspended user keeps its credentials. `.enabled` is set to false so every
# renderer and exporter already excludes it, and `.limits.resume_enabled`
# remembers the operator's intent for automatic recovery.

user_limits_key() { printf '%s:%s\n' "$1" "$2"; }

user_limits_validate_state() {
  jq -e '
    def int_or_null($min;$max): .==null or (type=="number" and floor==. and .>=$min and .<=$max);
    all(.nodes[]?; all(.users[]?; (.limits // null) as $l |
      $l==null or ($l|type=="object"
        and ((.quota_bytes // null)==null) and ((.ip_limit // null)==null) and ((.reset_day // null)==null)
        and (.expires_at|int_or_null(1;253402300799))
        and ((.suspended // null)|IN(null,"expired"))
        and ((.resume_enabled // false)|type=="boolean"))))
  ' "$1" >/dev/null || { log_error '用户限额状态无效：sb-manager 仅支持用户到期时间。'; return 1; }
}

# Pure state transition shared by the periodic tick and limit edits.
USER_LIMITS_EVAL_JQ='
  def eval($now):
    .nodes |= map(.users |= map(
      (.limits // null) as $l |
      if $l==null then .
      elif ($l.suspended // null)==null then
        if $l.expires_at!=null and $l.expires_at<=$now and .enabled then
          .limits.suspended="expired" | .limits.resume_enabled=.enabled | .enabled=false
        else . end
      elif $l.expires_at==null or $l.expires_at>$now then
        .enabled=($l.resume_enabled // true) | .limits.suspended=null | .limits.resume_enabled=false
      else . end));
  eval($now)'

user_limits_eval_file() {
  jq --argjson now "$(date +%s)" "$USER_LIMITS_EVAL_JQ" "$1" >"$2"
}

_user_limits_apply() {
  local candidate=$1
  if ! apply_candidate_state "$candidate" user-limits; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}

user_limits_notify_changes() {
  local before=$1 after=$2 row
  [[ $(jq -r '.notifications.enabled // false' "$after") == true ]] || return 0
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    notification_send user_limit "$row" || true
  done < <(jq -rn --slurpfile a "$before" --slurpfile b "$after" '
    def users($s): [$s[0].nodes[]? | .id as $n | .users[] | {key:"\($n)/\(.id)",value:(.limits.suspended // null)}] | from_entries;
    users($a) as $old | users($b) as $new |
    $new | to_entries[] | select(.value!=$old[.key]) |
    if .value==null then "用户 \(.key) 已续期并自动恢复。" else "用户 \(.key) 已到期，已暂停。" end')
}

user_limits_tick_unlocked() {
  local candidate before
  if ! jq -e 'any(.nodes[]?.users[]?; .limits!=null)' "$SBM_STATE" >/dev/null; then
    if declare -F subscription_refresh_user_bundles >/dev/null 2>&1; then subscription_refresh_user_bundles || true; fi
    return 0
  fi
  candidate=$(state_candidate) || return 1
  user_limits_eval_file "$SBM_STATE" "$candidate" || { rm -f "$candidate"; return 1; }
  if jq -e --slurpfile current "$SBM_STATE" '. == $current[0]' "$candidate" >/dev/null; then
    rm -f "$candidate"
    if declare -F subscription_refresh_user_bundles >/dev/null 2>&1; then subscription_refresh_user_bundles || true; fi
    return 0
  fi
  before=$(mktemp "$SBM_RUN/user-limits-before.XXXXXX") || { rm -f "$candidate"; return 1; }
  cp "$SBM_STATE" "$before" || { rm -f "$candidate" "$before"; return 1; }
  _state_transaction_run user-limits _user_limits_apply "$candidate" || { rm -f "$before"; return 1; }
  user_limits_notify_changes "$before" "$SBM_STATE" || true
  rm -f "$before"
}
user_limits_tick() { require_root; with_lock user_limits_tick_unlocked; }

_user_limit_set() {
  local node_id=$1 user_id=$2 candidate value now at expires='keep'
  shift 2
  state_node_exists "$node_id" || die "节点不存在：$node_id"
  state_user_exists "$node_id" "$user_id" || die "用户不存在：$node_id/$user_id"
  now=$(date +%s)
  while (($#)); do
    case "$1" in
      --days)
        value=${2:?缺少天数}; [[ "$value" =~ ^[1-9][0-9]{0,3}$ ]] && (( value <= 3650 )) || die '天数必须为 1-3650。'
        at=$(jq -r --arg n "$node_id" --arg u "$user_id" --argjson now "$now" '.nodes[]|select(.id==$n)|.users[]|select(.id==$u)|[.limits.expires_at // 0,$now]|max' "$SBM_STATE")
        expires=$((at + value * 86400)); shift 2;;
      --expire-at)
        value=${2:?缺少时间}; [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die '时间须为 UTC，如 2027-01-01T00:00:00Z。'
        at=$(jq -ner --arg at "$value" '$at|fromdateiso8601') || die '到期时间无效。'
        (( at > now )) || die '到期时间必须晚于当前时间。'
        expires=$at; shift 2;;
      --no-expiry|--clear) expires=null; shift;;
      --quota|--reset-day|--ip-limit)
        die "$1 需要用户级流量统计，sing-box 官方版本不提供；请使用节点级流量控制（sb traffic set）或 xray-manager。";;
      *) die "未知用户限额参数：$1";;
    esac
  done
  [[ "$expires" != keep ]] || die '请指定 --days、--expire-at 或 --no-expiry。'
  candidate=$(state_candidate) || return 1
  jq --arg n "$node_id" --arg u "$user_id" --argjson at "$expires" '
    (.nodes[]|select(.id==$n)|.users[]|select(.id==$u)) |=
      (.limits=({expires_at:null,suspended:null,resume_enabled:false} + (.limits // {}) + {expires_at:$at})
       | if .limits.expires_at==null then
           (if .limits.suspended!=null then .enabled=(.limits.resume_enabled // true) else . end) | del(.limits)
         else . end)
  ' "$SBM_STATE" >"$candidate.raw" || { rm -f "$candidate" "$candidate.raw"; return 1; }
  user_limits_eval_file "$candidate.raw" "$candidate" || { rm -f "$candidate" "$candidate.raw"; return 1; }
  rm -f "$candidate.raw"
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then config_preview_candidate "$candidate"; rm -f "$candidate"; return 0; fi
  if ! apply_candidate_state "$candidate" "user-limit-$node_id-$user_id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已更新用户到期时间：$node_id/$user_id"
}

user_limit_cli() {
  local node_id=${1:-} user_id=${2:-}
  [[ -n "$node_id" && -n "$user_id" ]] || usage_die '用法：sb user limit NODE_ID USER_ID [--days N|--expire-at UTC|--no-expiry]'
  if (($# == 2)); then user_stats_json "$node_id" | jq --arg u "$user_id" '.[] | select(.user==$u)'; return; fi
  require_root
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then with_lock _user_limit_set "$@"
  else with_state_transaction user-limit _user_limit_set "$@"; fi
}

user_stats_json() {
  jq --arg f "${1:-}" '[
    .nodes[]? | select($f=="" or .id==$f) | .id as $n | .protocol as $p | .users[] |
    {node:$n,user:.id,name,protocol:$p,enabled,limits:(.limits // null)}]' "$SBM_STATE"
}

user_stats() {
  local filter=${1:-} json=${2:-0} rows
  [[ -z "$filter" ]] || state_node_exists "$filter" || die "节点不存在：$filter"
  rows=$(user_stats_json "$filter") || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$rows"; return; fi
  printf '%-14s %-12s %-12s %s\n' 节点 用户 状态 到期
  jq -r '.[] | [.node,.user,
      (if .limits.suspended!=null then "已到期暂停" elif .enabled then "启用" else "停用" end),
      (if .limits.expires_at==null then "-" else (.limits.expires_at|todateiso8601) end)] | @tsv' <<<"$rows" |
    while IFS=$'\t' read -r node user status expiry; do
      printf '%-14s %-12s %-12s %s\n' "$node" "$user" "$status" "$expiry"
    done
  printf '\n用户级流量配额与在线 IP 需要 Xray 统计，请使用 xray-manager；节点级配额见 sb traffic status。\n'
}
