#!/usr/bin/env bash
# shellcheck shell=bash

# Per-user limits. Expiry applies to every multi-user protocol. Quota and
# online-IP limits need per-user counters, which only the Xray VLESS runtime
# provides through its loopback Stats API.
#
# A suspended user keeps its credentials. `.enabled` is set to false so every
# renderer and exporter already excludes it, and `.limits.resume_enabled`
# remembers the operator's intent for automatic recovery.

user_limits_default_api_port() { jq -r '.settings.xray_api_port // 10085' "${1:-$SBM_STATE}"; }

user_limits_key() { printf '%s:%s\n' "$1" "$2"; }

user_limits_validate_state() {
  jq -e '
    def int_or_null($min;$max): .==null or (type=="number" and floor==. and .>=$min and .<=$max);
    ((.settings.xray_api_port // 10085)|type=="number" and floor==. and .>=1 and .<=65535)
    and ((.settings.xray_api_port // 10085) as $api | all(.nodes[]?; .port!=$api))
    and all(.nodes[]?; . as $node | all(.users[]?; (.limits // null) as $l |
      $l==null or ($l|type=="object"
        and (.quota_bytes|int_or_null(1;9000000000000000))
        and (.reset_day|int_or_null(1;28))
        and (.expires_at|int_or_null(1;253402300799))
        and (.ip_limit|int_or_null(1;1024))
        and ((.suspended // null)|IN(null,"quota","expired","ip"))
        and ((.suspended_until // null)|int_or_null(1;253402300799))
        and ((.resume_enabled // false)|type=="boolean")
        and (((.quota_bytes==null and .ip_limit==null)) or $node.protocol=="vless"))))
  ' "$1" >/dev/null || { log_error '用户限额状态无效：流量配额与在线 IP 限制仅支持 VLESS（Xray），且节点端口不能与 Xray 统计 API 端口相同（sb xray api-port）。'; return 1; }
}

user_usage_validate() {
  jq -e '
    type=="object" and .schema_version==1 and (.users|type=="object")
    and all(.users[]; type=="object"
      and all((.upload_bytes,.download_bytes,.total_upload_bytes,.total_download_bytes)|(.//0); type=="number" and floor==. and .>=0)
      and ((.cycle_id // 0)|type=="number"))
  ' "$1" >/dev/null 2>&1
}

user_usage_init_unlocked() {
  local tmp
  mkdir -p "$(dirname "$SBM_USER_USAGE")" || return 1
  if [[ -e "$SBM_USER_USAGE" ]]; then
    user_usage_validate "$SBM_USER_USAGE" || { log_error "用户流量账本损坏：$SBM_USER_USAGE"; return 1; }
    return 0
  fi
  tmp=$(mktemp "$(dirname "$SBM_USER_USAGE")/.user-usage.XXXXXX") || return 1
  jq -n --arg now "$(now_iso)" '{schema_version:1,updated_at:$now,users:{}}' >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f "$tmp" "$SBM_USER_USAGE"
}

# Replace the ledger atomically with the result of a jq program.
user_usage_update_unlocked() {
  local program=$1 tmp
  shift
  user_usage_init_unlocked || return 1
  tmp=$(mktemp "$(dirname "$SBM_USER_USAGE")/.user-usage.XXXXXX") || return 1
  jq --arg now "$(now_iso)" "$@" "$program | .updated_at=\$now" "$SBM_USER_USAGE" >"$tmp" \
    && user_usage_validate "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$SBM_USER_USAGE" || { rm -f "$tmp"; return 1; }
}

user_limits_xray_ready() {
  [[ "$SBM_SKIP_INIT" != 1 && -x "$SBM_XRAY_BIN" ]] || return 1
  [[ $(jq -r '.settings.vless_engine // "sing-box"' "$SBM_STATE") == xray ]] || return 1
  service_active "$SBM_XRAY_SERVICE" 2>/dev/null
}

user_limits_xray_api() {
  "$SBM_XRAY_BIN" api "$1" -s "127.0.0.1:$(user_limits_default_api_port)" -t 5 "${@:2}" 2>/dev/null
}

# Read and reset Xray's per-user counters, then add the deltas to the ledger.
# Called before Xray restarts so counters are not lost with the process.
user_usage_collect_unlocked() {
  local output stats
  user_limits_xray_ready || return 0
  # Verified against Xray 26.11: {"stat":[{"name":"user>>>E>>>traffic>>>uplink","value":N}]};
  # zero counters omit "value". Inbound/outbound counters use the same shape.
  output=$(user_limits_xray_api statsquery -pattern '' -reset) || { log_warn '无法读取 Xray 流量统计。'; return 0; }
  stats=$(jq -c '
    def bucket($kind):
      [(.stat // [])[] | (.name|split(">>>")) as $p
        | select(($p|length)==4 and $p[0]==$kind and $p[2]=="traffic")
        | {key:$p[1],dir:$p[3],value:((.value // 0)|tonumber)}]
      | group_by(.key) | map({key:.[0].key,value:{
          up:([.[]|select(.dir=="uplink").value]|add // 0),
          down:([.[]|select(.dir=="downlink").value]|add // 0)}}) | from_entries;
    {users:bucket("user"),inbounds:bucket("inbound"),outbounds:bucket("outbound")}
  ' <<<"$output" 2>/dev/null) || { log_warn 'Xray 流量统计格式无法识别。'; return 0; }
  jq -e 'any(.[][]; .up>0 or .down>0)' <<<"$stats" >/dev/null || return 0
  user_usage_update_unlocked '
    reduce ($stats.users|to_entries[]) as $e (.;
      .users[$e.key] = ((.users[$e.key] // {}) as $u | $u + {
        upload_bytes:(($u.upload_bytes // 0)+$e.value.up),
        download_bytes:(($u.download_bytes // 0)+$e.value.down),
        total_upload_bytes:(($u.total_upload_bytes // 0)+$e.value.up),
        total_download_bytes:(($u.total_download_bytes // 0)+$e.value.down)}))
    | reduce ("inbounds","outbounds") as $kind (.;
        reduce ($stats[$kind]|to_entries[]) as $e (.;
          .[$kind][$e.key] = ((.[$kind][$e.key] // {}) as $t | {
            upload_bytes:(($t.upload_bytes // 0)+$e.value.up),
            download_bytes:(($t.download_bytes // 0)+$e.value.down)})))
  ' --argjson stats "$stats"
}

# Online IPs come from Xray's statsUserOnline policy (activity in the last 20s).
user_limits_online_ips() {
  local email=$1 output
  output=$(user_limits_xray_api statsonlineiplist -email "$email") || { printf '[]\n'; return 0; }
  jq -c '(.ips // .ipList // .ip_list // {}) | if type=="object" then keys elif type=="array" then map(if type=="object" then (.ip // .key // empty) else . end) else [] end' <<<"$output" 2>/dev/null || printf '[]\n'
}

user_limits_online_map() {
  local key ips map='{}'
  user_limits_xray_ready || { printf '{}\n'; return 0; }
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    ips=$(user_limits_online_ips "$key")
    map=$(jq -c --arg key "$key" --argjson ips "$ips" '.[$key]=($ips|length)' <<<"$map") || return 1
  done < <(jq -r '.nodes[]? | select(.protocol=="vless") | .id as $n | .users[] | select(.limits.ip_limit!=null and .enabled==true) | "\($n):\(.id)"' "$SBM_STATE")
  printf '%s\n' "$map"
}

# Start a new cycle for users whose monthly reset day has passed.
user_usage_rollover_unlocked() {
  local cycles='{}' row key day
  while IFS=$'\t' read -r key day; do
    [[ -n "$key" ]] || continue
    cycles=$(jq -c --arg key "$key" --argjson cycle "$(traffic_cycle_id "$day")" '.[$key]=$cycle' <<<"$cycles") || return 1
  done < <(jq -r '.nodes[]? | .id as $n | .users[] | select(.limits.reset_day!=null) | ["\($n):\(.id)",.limits.reset_day] | @tsv' "$SBM_STATE")
  [[ "$cycles" != '{}' ]] || return 0
  row=$(jq -c --argjson cycles "$cycles" '[.users as $u | $cycles|to_entries[] | select(($u[.key].cycle_id // 0)!=.value)] | length' "$SBM_USER_USAGE" 2>/dev/null || echo 1)
  [[ "$row" != 0 ]] || return 0
  user_usage_update_unlocked '
    reduce ($cycles|to_entries[]) as $e (.;
      if (.users[$e.key].cycle_id // 0)==$e.value then .
      else .users[$e.key]=((.users[$e.key] // {}) + {cycle_id:$e.value,upload_bytes:0,download_bytes:0}) end)
  ' --argjson cycles "$cycles"
}

# Pure state transition shared by the periodic tick and limit edits.
USER_LIMITS_EVAL_JQ='
  def eval($now;$usage;$online):
    .nodes |= map(.id as $nid | .users |= map(
      (.limits // null) as $l |
      if $l==null then . else
        ($nid+":"+.id) as $key |
        ((($usage[$key].upload_bytes) // 0) + (($usage[$key].download_bytes) // 0)) as $used |
        (($online[$key]) // 0) as $ips |
        if ($l.suspended // null)==null then
          (if $l.expires_at!=null and $l.expires_at<=$now then "expired"
           elif $l.quota_bytes!=null and $used>=$l.quota_bytes then "quota"
           elif $l.ip_limit!=null and $ips>$l.ip_limit then "ip" else null end) as $reason |
          if $reason==null or (.enabled|not) then . else
            .limits.suspended=$reason | .limits.resume_enabled=.enabled | .enabled=false
            | .limits.suspended_until=(if $reason=="ip" then $now+600 else null end) end
        else
          (if $l.suspended=="expired" then ($l.expires_at==null or $l.expires_at>$now)
           elif $l.suspended=="quota" then ($l.quota_bytes==null or $used<$l.quota_bytes)
           else ($l.ip_limit==null or ($l.suspended_until // 0)<=$now) end) as $ok |
          if $ok then .enabled=($l.resume_enabled // true) | .limits.suspended=null | .limits.suspended_until=null | .limits.resume_enabled=false
          else . end
        end
      end));
  eval($now;$usage;$online) | eval($now;$usage;$online)'

user_limits_eval_file() {
  local input=$1 output=$2 online=${3:-'{}'} usage='{}'
  [[ ! -s "$SBM_USER_USAGE" ]] || usage=$(jq -c '.users' "$SBM_USER_USAGE") || return 1
  jq --argjson now "$(date +%s)" --argjson usage "$usage" --argjson online "$online" "$USER_LIMITS_EVAL_JQ" "$input" >"$output"
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
    if .value==null then "用户 \(.key) 已自动恢复。"
    else "用户 \(.key) 已暂停：" + ({quota:"流量配额用尽",expired:"已到期",ip:"在线 IP 超出限制，10 分钟后自动重试"}[.value]) end')
}

user_limits_tick_unlocked() {
  local online candidate
  if ! jq -e 'any(.nodes[]?.users[]?; .limits!=null)' "$SBM_STATE" >/dev/null; then
    user_usage_collect_unlocked || true
    if declare -F subscription_refresh_user_bundles >/dev/null 2>&1; then subscription_refresh_user_bundles || true; fi
    return 0
  fi
  user_usage_init_unlocked || return 1
  user_usage_collect_unlocked || true
  user_usage_rollover_unlocked || return 1
  online=$(user_limits_online_map) || online='{}'
  candidate=$(state_candidate) || return 1
  user_limits_eval_file "$SBM_STATE" "$candidate" "$online" || { rm -f "$candidate"; return 1; }
  if jq -e --slurpfile current "$SBM_STATE" '. == $current[0]' "$candidate" >/dev/null; then
    rm -f "$candidate"
    if declare -F subscription_refresh_user_bundles >/dev/null 2>&1; then subscription_refresh_user_bundles || true; fi
    return 0
  fi
  local before
  before=$(mktemp "$SBM_RUN/user-limits-before.XXXXXX") || { rm -f "$candidate"; return 1; }
  cp "$SBM_STATE" "$before" || { rm -f "$candidate" "$before"; return 1; }
  _state_transaction_run user-limits _user_limits_apply "$candidate" || { rm -f "$before"; return 1; }
  user_limits_notify_changes "$before" "$SBM_STATE" || true
  rm -f "$before"
}
user_limits_tick() { require_root; with_lock user_limits_tick_unlocked; }

_user_limit_set() {
  local node_id=$1 user_id=$2 node protocol candidate value now at
  shift 2
  node=$(state_get_node "$node_id"); [[ -n "$node" ]] || die "节点不存在：$node_id"
  state_user_exists "$node_id" "$user_id" || die "用户不存在：$node_id/$user_id"
  protocol=$(jq -r '.protocol' <<<"$node")
  local -A set=()
  now=$(date +%s)
  while (($#)); do
    case "$1" in
      --quota)
        value=${2:?缺少配额}; set[quota_bytes]=$(traffic_nullable_size "$value") || die "无效配额：$value（示例：50G、unlimited）"; shift 2;;
      --reset-day)
        value=${2:?缺少重置日}
        if [[ "$value" == none ]]; then set[reset_day]=null
        else [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value >= 1 && 10#$value <= 28 )) || die '每月重置日必须是 1-28 或 none。'; set[reset_day]=$((10#$value)); fi
        shift 2;;
      --days)
        value=${2:?缺少天数}; [[ "$value" =~ ^[1-9][0-9]{0,3}$ ]] && (( value <= 3650 )) || die '天数必须为 1-3650。'
        at=$(jq -r --arg n "$node_id" --arg u "$user_id" --argjson now "$now" '.nodes[]|select(.id==$n)|.users[]|select(.id==$u)|[.limits.expires_at // 0,$now]|max' "$SBM_STATE")
        set[expires_at]=$((at + value * 86400)); shift 2;;
      --expire-at)
        value=${2:?缺少时间}; [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die '时间须为 UTC，如 2027-01-01T00:00:00Z。'
        at=$(jq -ner --arg at "$value" '$at|fromdateiso8601') || die '到期时间无效。'
        (( at > now )) || die '到期时间必须晚于当前时间。'
        set[expires_at]=$at; shift 2;;
      --no-expiry) set[expires_at]=null; shift;;
      --ip-limit)
        value=${2:?缺少 IP 数}
        if [[ "$value" == unlimited || "$value" == none ]]; then set[ip_limit]=null
        else [[ "$value" =~ ^[1-9][0-9]{0,3}$ ]] && (( value <= 1024 )) || die 'IP 数必须为 1-1024 或 unlimited。'; set[ip_limit]=$value; fi
        shift 2;;
      --clear) set[clear]=1; shift;;
      *) die "未知用户限额参数：$1";;
    esac
  done
  if [[ "$protocol" != vless ]] && { [[ ${set[quota_bytes]:-null} != null ]] || [[ ${set[ip_limit]:-null} != null ]]; }; then
    die '流量配额与在线 IP 限制需要 Xray 统计，仅支持 VLESS；其他协议可使用到期时间或节点级流量控制（sb traffic set）。'
  fi
  if [[ "$protocol" == vless && $(jq -r '.settings.vless_engine // "sing-box"' "$SBM_STATE") != xray ]] \
    && { [[ ${set[quota_bytes]:-null} != null ]] || [[ ${set[ip_limit]:-null} != null ]]; }; then
    die '请先运行 sb xray enable，用户流量统计由 Xray 提供。'
  fi
  if [[ ${set[ip_limit]:-null} != null ]] && jq -e '
      ((.listen // "::")|IN("127.0.0.1","::1","localhost"))
      and ((.xray.inbound.streamSettings.sockopt.acceptProxyProtocol // false)|not)
      and ((.xray.inbound.streamSettings.sockopt.trustedXForwardedFor // [])|length==0)' <<<"$node" >/dev/null; then
    # Xray never records loopback sources as online IPs.
    log_warn '该节点只监听本机，经反向代理接入时 Xray 看不到客户端 IP，在线 IP 限制不会生效；请让代理发送 PROXY protocol 并执行 --accept-proxy-protocol true，或配置 sockopt.trustedXForwardedFor。'
  fi
  local patch='{}' key
  for key in quota_bytes reset_day expires_at ip_limit; do
    [[ -v set[$key] ]] || continue
    patch=$(jq -c --arg key "$key" --argjson value "${set[$key]}" '.[$key]=$value' <<<"$patch") || return 1
  done
  [[ ! -v set[clear] ]] || patch='{"quota_bytes":null,"reset_day":null,"expires_at":null,"ip_limit":null}'
  [[ $(jq -r '.settings.vless_engine // ""' "$SBM_STATE") != xray ]] || user_usage_collect_unlocked || true
  candidate=$(state_candidate) || return 1
  jq --arg n "$node_id" --arg u "$user_id" --argjson patch "$patch" '
    (.nodes[]|select(.id==$n)|.users[]|select(.id==$u)) |=
      (.limits=({quota_bytes:null,reset_day:null,expires_at:null,ip_limit:null,suspended:null,suspended_until:null,resume_enabled:false} + (.limits // {}) + $patch)
       | if .limits.quota_bytes==null and .limits.expires_at==null and .limits.ip_limit==null then
           (if .limits.suspended!=null then .enabled=(.limits.resume_enabled // true) else . end) | del(.limits)
         else . end)
  ' "$SBM_STATE" >"$candidate.raw" || { rm -f "$candidate" "$candidate.raw"; return 1; }
  if [[ -v set[reset_day] && ${set[reset_day]} != null ]]; then
    user_usage_update_unlocked '.users[$key]=((.users[$key] // {}) + {cycle_id:$cycle})' \
      --arg key "$(user_limits_key "$node_id" "$user_id")" --argjson cycle "$(traffic_cycle_id "${set[reset_day]}")" || return 1
  fi
  user_limits_eval_file "$candidate.raw" "$candidate" || { rm -f "$candidate" "$candidate.raw"; return 1; }
  rm -f "$candidate.raw"
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then config_preview_candidate "$candidate"; rm -f "$candidate"; return 0; fi
  if ! apply_candidate_state "$candidate" "user-limit-$node_id-$user_id"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "已更新用户限额：$node_id/$user_id"
}

user_limit_cli() {
  local node_id=${1:-} user_id=${2:-}
  [[ -n "$node_id" && -n "$user_id" ]] || usage_die '用法：sb user limit NODE_ID USER_ID [--quota SIZE|unlimited] [--reset-day 1-28|none] [--days N|--expire-at UTC|--no-expiry] [--ip-limit N|unlimited] [--clear]'
  if (($# == 2)); then user_stats_json "$node_id" | jq --arg u "$user_id" '.[] | select(.user==$u)'; return; fi
  require_root
  if [[ ${SBM_DRY_RUN:-0} == 1 ]]; then with_lock _user_limit_set "$@"
  else with_state_transaction user-limit _user_limit_set "$@"; fi
}

_user_usage_reset() {
  local key
  key=$(user_limits_key "$1" "$2")
  state_user_exists "$1" "$2" || die "用户不存在：$1/$2"
  user_usage_collect_unlocked || true
  user_usage_update_unlocked '.users[$key]=((.users[$key] // {}) + {upload_bytes:0,download_bytes:0})' --arg key "$key" || return 1
  user_limits_tick_unlocked || return 1
  log_ok "已清零本周期用户流量：$1/$2"
}
user_usage_reset() { require_root; with_lock _user_usage_reset "$@"; }

user_stats_json() {
  local filter=${1:-} usage='{}' online='{}'
  [[ ! -s "$SBM_USER_USAGE" ]] || usage=$(jq -c '.users' "$SBM_USER_USAGE")
  if [[ $EUID -eq 0 ]] && user_limits_xray_ready; then
    local key
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      online=$(jq -c --arg key "$key" --argjson ips "$(user_limits_online_ips "$key")" '.[$key]=$ips' <<<"$online")
    done < <(jq -r --arg f "$filter" '.nodes[]? | select(.protocol=="vless" and ($f=="" or .id==$f)) | .id as $n | .users[] | select(.enabled) | "\($n):\(.id)"' "$SBM_STATE")
  fi
  jq --arg f "$filter" --argjson usage "$usage" --argjson online "$online" '[
    .nodes[]? | select($f=="" or .id==$f) | .id as $n | .protocol as $p | .users[] |
    ("\($n):\(.id)") as $key | ($usage[$key] // {}) as $u |
    {node:$n,user:.id,name,protocol:$p,enabled,
     upload_bytes:($u.upload_bytes // 0),download_bytes:($u.download_bytes // 0),
     total_upload_bytes:($u.total_upload_bytes // 0),total_download_bytes:($u.total_download_bytes // 0),
     online_ips:($online[$key] // null),limits:(.limits // null),
     stats:(if $p=="vless" then "xray" else "unavailable" end)}]' "$SBM_STATE"
}

user_stats() {
  local filter=${1:-} json=${2:-0} rows
  [[ -z "$filter" ]] || state_node_exists "$filter" || die "节点不存在：$filter"
  if [[ $EUID -eq 0 ]]; then with_lock user_usage_collect_unlocked || true; fi
  rows=$(user_stats_json "$filter") || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$rows"; return; fi
  printf '%-14s %-12s %-6s %-11s %-11s %-12s %-8s %s\n' 节点 用户 状态 本期上行 本期下行 配额 在线IP 到期
  jq -r '.[] | [.node,.user,
      (if .limits.suspended!=null then "暂停:"+.limits.suspended elif .enabled then "启用" else "停用" end),
      (.upload_bytes|tostring),(.download_bytes|tostring),
      (if .limits.quota_bytes==null then "-" else (.limits.quota_bytes|tostring) end),
      (if .online_ips==null then "-" else (.online_ips|length|tostring) + (if .limits.ip_limit==null then "" else "/"+(.limits.ip_limit|tostring) end) end),
      (if .limits.expires_at==null then "-" else (.limits.expires_at|todateiso8601) end),
      .stats] | @tsv' <<<"$rows" |
    while IFS=$'\t' read -r node user status up down quota ips expiry stats; do
      if [[ "$stats" != xray ]]; then up=-; down=-; else up=$(traffic_format_bytes "$up"); down=$(traffic_format_bytes "$down"); fi
      [[ "$quota" == - ]] || quota=$(traffic_format_bytes "$quota")
      printf '%-14s %-12s %-6s %-11s %-11s %-12s %-8s %s\n' "$node" "$user" "$status" "$up" "$down" "$quota" "$ips" "$expiry"
    done
}

xray_traffic_json() {
  [[ -s "$SBM_USER_USAGE" ]] || { printf '{"inbounds":{},"outbounds":{}}\n'; return 0; }
  jq '{updated_at,inbounds:(.inbounds // {}),outbounds:(.outbounds // {})}' "$SBM_USER_USAGE"
}

xray_traffic() {
  local json=${1:-0} rows
  if [[ $EUID -eq 0 ]]; then with_lock user_usage_collect_unlocked || true; fi
  rows=$(xray_traffic_json) || return 1
  if [[ "$json" == 1 ]]; then printf '%s\n' "$rows"; return; fi
  printf '%-10s %-28s %-12s %s\n' 类型 标签 上行 下行
  jq -r '(.inbounds|to_entries[]|["入站",.key,.value.upload_bytes,.value.download_bytes]),
         (.outbounds|to_entries[]|["出站",.key,.value.upload_bytes,.value.download_bytes]) | @tsv' <<<"$rows" |
    while IFS=$'\t' read -r kind tag up down; do
      printf '%-10s %-28s %-12s %s\n' "$kind" "$tag" "$(traffic_format_bytes "$up")" "$(traffic_format_bytes "$down")"
    done
}

_xray_traffic_reset() {
  user_usage_collect_unlocked || true
  user_usage_update_unlocked '.inbounds={} | .outbounds={}' || return 1
  log_ok '已清零 Xray 入站/出站累计流量。'
}
xray_traffic_reset() { require_root; with_lock _xray_traffic_reset; }
