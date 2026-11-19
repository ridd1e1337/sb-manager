#!/usr/bin/env bash
# shellcheck shell=bash

# Xray outbounds, balancers and routing for the VLESS runtime.
#
# State keeps only routing structure (.xray_routing). Outbound objects can
# carry passwords and WireGuard private keys, so they live in a 0600 secrets
# file. Rendering combines both and the whole Xray config is checked with
# `xray run -test` before installation.

SBM_XRAY_OUTBOUNDS_SECRET="${SBM_XRAY_OUTBOUNDS_SECRET:-$SBM_SECRETS/xray-outbounds.json}"
XRAY_RESERVED_TAGS='["direct","block","api"]'

xray_outbounds_read() {
  if [[ -s "$SBM_XRAY_OUTBOUNDS_SECRET" ]]; then jq -c '.' "$SBM_XRAY_OUTBOUNDS_SECRET"
  else printf '{}\n'; fi
}

xray_outbounds_write() {
  local json=$1 tmp
  mkdir -p "$SBM_SECRETS" || return 1
  tmp=$(mktemp "$SBM_SECRETS/.xray-outbounds.XXXXXX") || return 1
  jq -e 'type=="object"' <<<"$json" >/dev/null 2>&1 && jq . <<<"$json" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && must_mv -f "$tmp" "$SBM_XRAY_OUTBOUNDS_SECRET" || { rm -f "$tmp"; return 1; }
}

xray_routing_validate_tag() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,47}$ ]] || { log_error '标签只能包含小写字母、数字、点、下划线和连字符。'; return 1; }
  jq -e --arg tag "$1" --argjson reserved "$XRAY_RESERVED_TAGS" '$reserved|index($tag)==null' <<<'null' >/dev/null \
    || { log_error "保留标签不可使用：$1"; return 1; }
}

xray_routing_validate_state() {
  local state=$1 outbounds
  outbounds=$(xray_outbounds_read) || return 1
  jq -e --argjson outbounds "$outbounds" --argjson reserved "$XRAY_RESERVED_TAGS" '
    (.xray_routing // {}) as $r |
    ($r.outbounds // []) as $o | ($r.balancers // []) as $b | ($r.rules // []) as $rules |
    ([$o[].tag] + $reserved) as $out_tags | [$b[].tag] as $bal_tags |
    def target_ok: . as $t | ($t.outbound!=null and ($out_tags|index($t.outbound))!=null and $t.balancer==null)
                or ($t.balancer!=null and ($bal_tags|index($t.balancer))!=null and $t.outbound==null);
    ($o|type=="array") and ($b|type=="array") and ($rules|type=="array")
    and ([$o[].tag]|length)==([$o[].tag]|unique|length)
    and ($bal_tags|length)==($bal_tags|unique|length)
    and all($o[]; . as $x | ($x.tag|type=="string") and ($outbounds[$x.tag]!=null)
      and (($x.via // null)==null or ($x.via!=$x.tag and ([$o[].tag]|index($x.via))!=null)))
    and all($b[]; (.tag|type=="string") and (.selectors|type=="array" and length>0)
      and all(.selectors[]; . as $s | ([$o[].tag]+["direct"])|index($s)!=null)
      and (.strategy|IN("random","roundRobin","leastPing","leastLoad"))
      and (. as $x | $x.fallback==null or ($out_tags|index($x.fallback))!=null))
    and all($rules[]; type=="object" and target_ok
      and ([.node,.user,.domain,.ip,.network,.port]|map(select(.!=null))|length)>0)
    and (($r.default // null)==null or ($r.default|target_ok))
  ' "$state" >/dev/null || { log_error 'Xray 出站/路由状态无效：请检查出站、负载均衡、规则与默认出口引用。'; return 1; }
}

# Translate structured rules into native Xray routing rules.
xray_routing_render() {
  local state=$1 outbounds
  outbounds=$(xray_outbounds_read) || return 1
  jq -c --argjson secret "$outbounds" '
    (.xray_routing // {}) as $r |
    def target: if .balancer!=null then {balancerTag:.balancer} else {outboundTag:.outbound} end;
    def via($o): if ($o.via // null)==null then . else
      if (.protocol|IN("freedom","blackhole","dns")) then .
      else .streamSettings=((.streamSettings // {}) | .sockopt=((.sockopt // {}) + {dialerProxy:$o.via})) end end;
    ([($r.outbounds // [])[] | . as $o | ($secret[$o.tag] + {tag:$o.tag}) | via($o)]) as $custom |
    ($r.balancers // []) as $balancers |
    {
      outbounds: ([{tag:"direct",protocol:"freedom"}] + $custom + [{tag:"block",protocol:"blackhole"}]),
      routing: ({domainStrategy:"AsIs",
        rules: (
          [($r.rules // [])[] |
            ({type:"field"}
              + (if .node!=null then {inboundTag:["in-"+.node]} else {} end)
              + (if .user!=null then {user:[.user]} else {} end)
              + (if .domain!=null then {domain:(.domain|split(","))} else {} end)
              + (if .ip!=null then {ip:(.ip|split(","))} else {} end)
              + (if .network!=null then {network:.network} else {} end)
              + (if .port!=null then {port:.port} else {} end)
              + target)] +
          (if ($r.default // null)==null then [] else [{type:"field",network:"tcp,udp"} + ($r.default|target)] end))}
        + (if ($balancers|length)==0 then {} else {balancers:[$balancers[] |
            {tag,selector:.selectors,strategy:{type:.strategy}} + (if .fallback==null then {} else {fallbackTag:.fallback} end)]} end)),
      observatory_tags: ([$balancers[] | select(.strategy|IN("leastPing","leastLoad")) | .selectors[]] | unique)
    }
    | if (.observatory_tags|length)>0 then
        .burstObservatory={subjectSelector:.observatory_tags,
          pingConfig:{destination:"https://www.gstatic.com/generate_204",interval:"1m",sampling:3,timeout:"5s"}}
      else . end
    | del(.observatory_tags)
  ' "$state"
}

_xray_routing_commit() {
  local state_program=$1 outbounds=$2 candidate
  shift 2
  candidate=$(state_candidate) || return 1
  jq "$@" ".xray_routing=(.xray_routing // {outbounds:[],balancers:[],rules:[]}) | $state_program" "$SBM_STATE" >"$candidate" || { rm -f "$candidate"; return 1; }
  if [[ -n "$outbounds" ]]; then xray_outbounds_write "$outbounds" || { rm -f "$candidate"; return 1; }; fi
  if ! apply_candidate_state "$candidate" xray-routing; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}

_xray_outbound_add() {
  local tag=$1 json=$2 via=${3:-} outbounds protocol
  xray_routing_validate_tag "$tag" || return 1
  jq -e --arg tag "$tag" '[(.xray_routing.outbounds // [])[].tag]|index($tag)==null' "$SBM_STATE" >/dev/null || { log_error "出站已存在：$tag"; return 1; }
  json=$(node_json_argument "$json") || return 1
  jq -e 'type=="object" and (.protocol|type=="string")' <<<"$json" >/dev/null || { log_error '出站必须是含 protocol 的 Xray outbound 对象。'; return 1; }
  protocol=$(jq -r '.protocol' <<<"$json")
  json=$(jq -c 'del(.tag)' <<<"$json") || return 1
  outbounds=$(xray_outbounds_read | jq -c --arg tag "$tag" --argjson ob "$json" '.[$tag]=$ob') || return 1
  _xray_routing_commit '.xray_routing.outbounds += [{tag:$tag,protocol:$protocol,via:(if $via=="" then null else $via end)}]' "$outbounds" \
    --arg tag "$tag" --arg protocol "$protocol" --arg via "$via" || return 1
  log_ok "已添加 Xray 出站：$tag（$protocol）"
}

_xray_outbound_remove() {
  local tag=$1 outbounds
  jq -e --arg tag "$tag" 'any((.xray_routing.outbounds // [])[]; .tag==$tag)' "$SBM_STATE" >/dev/null || { log_error "出站不存在：$tag"; return 1; }
  jq -e --arg tag "$tag" '(.xray_routing // {}) as $r |
    any(($r.outbounds // [])[]; .via==$tag) or any(($r.balancers // [])[]; (.selectors|index($tag))!=null or .fallback==$tag)
    or any(($r.rules // [])[]; .outbound==$tag) or ($r.default.outbound // "")==$tag' "$SBM_STATE" >/dev/null \
    && { log_error "出站 $tag 仍被链式、负载均衡、规则或默认出口引用。"; return 1; }
  outbounds=$(xray_outbounds_read | jq -c --arg tag "$tag" 'del(.[$tag])') || return 1
  _xray_routing_commit '.xray_routing.outbounds |= map(select(.tag!=$tag))' "$outbounds" --arg tag "$tag" || return 1
  log_ok "已删除 Xray 出站：$tag"
}

# WARP through Xray's native WireGuard outbound. Registration talks to
# Cloudflare's public client API only after confirmation; manual import is
# available for existing wgcf/WARP credentials.
xray_warp_outbound_json() {
  local private=$1 v4=$2 v6=$3 peer=$4 endpoint=$5 reserved=$6
  jq -cn --arg private "$private" --arg v4 "$v4" --arg v6 "$v6" --arg peer "$peer" --arg endpoint "$endpoint" --arg reserved "$reserved" '
    {protocol:"wireguard",settings:({
      secretKey:$private,
      address:([$v4,$v6]|map(select(.!=""))|map(if test(":") then .+"/128" else .+"/32" end)),
      peers:[{publicKey:$peer,endpoint:$endpoint,allowedIPs:["0.0.0.0/0","::/0"]}],
      mtu:1280,
      noKernelTun:true,
      domainStrategy:"ForceIP"}
     + (if $reserved=="" then {} else {reserved:($reserved|split(",")|map(tonumber))} end))}'
}

xray_warp_register() {
  local keys private public install response
  [[ -x "$SBM_XRAY_BIN" ]] || { log_error '请先安装 Xray。'; return 1; }
  require_command curl
  keys=$("$SBM_XRAY_BIN" wg 2>/dev/null) || { log_error '无法用 Xray 生成 WireGuard 密钥。'; return 1; }
  private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$keys")
  public=$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$keys")
  [[ -n "$private" && -n "$public" ]] || { log_error '无法解析 Xray WireGuard 密钥输出。'; return 1; }
  install=$(random_hex 11)
  response=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 20 \
    -H 'Content-Type: application/json' -H 'CF-Client-Version: a-6.30-3596' \
    --data "$(jq -cn --arg key "$public" --arg install "$install" --arg tos "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
      '{key:$key,install_id:$install,fcm_token:"",tos:$tos,type:"Android",locale:"en_US"}')" \
    https://api.cloudflareclient.com/v0a2158/reg) || { log_error 'WARP 注册失败。'; return 1; }
  jq -ce --arg private "$private" '
    .config as $c | select($c.peers[0].public_key!=null and $c.interface.addresses.v4!=null) |
    {private:$private,v4:$c.interface.addresses.v4,v6:($c.interface.addresses.v6 // ""),
     peer:$c.peers[0].public_key,endpoint:($c.peers[0].endpoint.host // "engage.cloudflareclient.com:2408"),
     reserved:(($c.client_id // "")|if .=="" then "" else (@base64d|explode|map(tostring)|join(",")) end)}
  ' <<<"$response" || { log_error 'WARP 注册返回格式无法识别。'; return 1; }
}

xray_warp_cli() {
  local tag=warp via='' private='' v4='' v6='' peer='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' endpoint='engage.cloudflareclient.com:2408' reserved='' register=0 info json
  while (($#)); do
    case "$1" in
      --tag) tag=${2:?}; shift 2;;
      --register) register=1; shift;;
      --private-key) private=${2:?}; shift 2;;
      --address-v4) v4=${2:?}; shift 2;;
      --address-v6) v6=${2:?}; shift 2;;
      --peer-public-key) peer=${2:?}; shift 2;;
      --endpoint) endpoint=${2:?}; shift 2;;
      --reserved) reserved=${2:?}; shift 2;;
      --via) via=${2:?}; shift 2;;
      *) usage_die '用法：sb xray warp [--tag TAG] --register | --private-key KEY --address-v4 IP [--address-v6 IP] [--reserved a,b,c] [--peer-public-key KEY] [--endpoint HOST:PORT]';;
    esac
  done
  require_root
  if [[ "$register" == 1 ]]; then
    confirm '将向 Cloudflare WARP 注册一个新的免费设备并获取 WireGuard 配置，继续？' N || return 0
    info=$(xray_warp_register) || return 1
    private=$(jq -r '.private' <<<"$info"); v4=$(jq -r '.v4' <<<"$info"); v6=$(jq -r '.v6' <<<"$info")
    peer=$(jq -r '.peer' <<<"$info"); endpoint=$(jq -r '.endpoint' <<<"$info"); reserved=$(jq -r '.reserved' <<<"$info")
  fi
  [[ -n "$private" && -n "$v4" ]] || usage_die '需要 --register，或提供 --private-key 与 --address-v4。'
  [[ -z "$reserved" || "$reserved" =~ ^[0-9]{1,3},[0-9]{1,3},[0-9]{1,3}$ ]] || usage_die 'reserved 格式为三个 0-255 数字，如 1,2,3。'
  json=$(xray_warp_outbound_json "$private" "$v4" "$v6" "$peer" "$endpoint" "$reserved") || return 1
  with_state_transaction xray-warp _xray_outbound_add "$tag" "$json" "$via"
}

_xray_balancer_set() {
  local tag=$1 selectors=$2 strategy=${3:-random} fallback=${4:-}
  xray_routing_validate_tag "$tag" || return 1
  case "$strategy" in random|roundRobin|leastPing|leastLoad) ;; *) log_error '策略只能是 random、roundRobin、leastPing、leastLoad。'; return 1;; esac
  _xray_routing_commit '.xray_routing.balancers=((.xray_routing.balancers // [])|map(select(.tag!=$tag))) + [{tag:$tag,selectors:($selectors|split(",")),strategy:$strategy,fallback:(if $fallback=="" then null else $fallback end)}]' '' \
    --arg tag "$tag" --arg selectors "$selectors" --arg strategy "$strategy" --arg fallback "$fallback" || return 1
  log_ok "已设置负载均衡：$tag（$strategy）"
}

_xray_balancer_remove() {
  local tag=$1
  jq -e --arg tag "$tag" '(.xray_routing // {}) as $r | any(($r.rules // [])[]; .balancer==$tag) or ($r.default.balancer // "")==$tag' "$SBM_STATE" >/dev/null \
    && { log_error "负载均衡 $tag 仍被规则或默认出口引用。"; return 1; }
  _xray_routing_commit '.xray_routing.balancers |= map(select(.tag!=$tag))' '' --arg tag "$tag" || return 1
  log_ok "已删除负载均衡：$tag"
}

xray_route_target_json() {
  case "$1" in
    balancer:*) jq -cn --arg tag "${1#balancer:}" '{balancer:$tag,outbound:null}';;
    *) jq -cn --arg tag "$1" '{outbound:$tag,balancer:null}';;
  esac
}

_xray_route_add() {
  local target='' rule='{}' value
  while (($#)); do
    case "$1" in
      --node) state_node_exists "${2:?}" || { log_error "节点不存在：$2"; return 1; }; rule=$(jq -c --arg v "$2" '.node=$v' <<<"$rule"); shift 2;;
      --user)
        value=${2:?}; [[ "$value" == *:* ]] && state_user_exists "${value%%:*}" "${value#*:}" || { log_error '--user 格式为 NODE_ID:USER_ID，且用户须存在。'; return 1; }
        rule=$(jq -c --arg v "$value" '.user=$v' <<<"$rule"); shift 2;;
      --domain)
        value=${2:?}; [[ "$value" =~ ^((domain|full|keyword|regexp):[^,]+)(,(domain|full|keyword|regexp):[^,]+)*$ ]] \
          || { log_error '域名规则使用 domain:/full:/keyword:/regexp: 前缀（未安装 geosite 数据库）。'; return 1; }
        rule=$(jq -c --arg v "$value" '.domain=$v' <<<"$rule"); shift 2;;
      --ip)
        value=${2:?}; [[ "$value" =~ ^[0-9a-fA-F:./,]+$ ]] || { log_error 'IP 规则须为 CIDR，多个用逗号分隔（未安装 geoip 数据库）。'; return 1; }
        rule=$(jq -c --arg v "$value" '.ip=$v' <<<"$rule"); shift 2;;
      --network) [[ "${2:?}" =~ ^(tcp|udp|tcp,udp)$ ]] || { log_error 'network 只能是 tcp、udp 或 tcp,udp。'; return 1; }; rule=$(jq -c --arg v "$2" '.network=$v' <<<"$rule"); shift 2;;
      --port) [[ "${2:?}" =~ ^[0-9,-]+$ ]] || { log_error '端口规则格式如 443 或 1000-2000,8443。'; return 1; }; rule=$(jq -c --arg v "$2" '.port=$v' <<<"$rule"); shift 2;;
      --to) target=$(xray_route_target_json "${2:?}") || return 1; shift 2;;
      *) log_error "未知路由参数：$1"; return 1;;
    esac
  done
  [[ -n "$target" ]] || { log_error '请用 --to OUTBOUND 或 --to balancer:TAG 指定出口。'; return 1; }
  [[ "$rule" != '{}' ]] || { log_error '至少需要一个匹配条件。'; return 1; }
  _xray_routing_commit '.xray_routing.rules += [$rule + $target]' '' --argjson rule "$rule" --argjson target "$target" || return 1
  log_ok '已添加 Xray 路由规则。'
}

_xray_route_remove() {
  local index=$1
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || { log_error '请输入规则序号。'; return 1; }
  jq -e --argjson i "$index" '(.xray_routing.rules // [])|length>=$i' "$SBM_STATE" >/dev/null || { log_error "规则不存在：$index"; return 1; }
  _xray_routing_commit '.xray_routing.rules |= del(.[$i-1])' '' --argjson i "$index" || return 1
  log_ok "已删除规则 $index"
}

_xray_route_default() {
  local target
  if [[ "$1" == direct ]]; then
    _xray_routing_commit '.xray_routing.default=null' '' || return 1
  else
    target=$(xray_route_target_json "$1") || return 1
    _xray_routing_commit '.xray_routing.default=$target' '' --argjson target "$target" || return 1
  fi
  log_ok "默认出口：$1"
}

xray_routing_show() {
  local json=${1:-0}
  if [[ "$json" == 1 ]]; then jq '.xray_routing // {outbounds:[],balancers:[],rules:[],default:null}' "$SBM_STATE"; return; fi
  jq -r '(.xray_routing // {}) as $r |
    "出站：", (($r.outbounds // [])[] | "  \(.tag)  \(.protocol)" + (if .via then "  经由 \(.via)" else "" end)),
    "负载均衡：", (($r.balancers // [])[] | "  \(.tag)  \(.strategy)  [\(.selectors|join(","))]" + (if .fallback then "  回退 \(.fallback)" else "" end)),
    "规则：", (($r.rules // []) | to_entries[] | "  \(.key+1). " + ([.value | to_entries[] | select(.value!=null and (.key|IN("outbound","balancer")|not)) | "\(.key)=\(.value)"]|join(" ")) + " -> " + (if .value.balancer then "balancer:"+.value.balancer else .value.outbound end)),
    "默认出口：" + (if $r.default==null then "direct" elif $r.default.balancer then "balancer:"+$r.default.balancer else $r.default.outbound end)' "$SBM_STATE"
}

xray_routing_cli() {
  local area=${1:-show} action=${2:-}
  case "$area" in
    show) xray_routing_show "$([[ ${2:-} == --json ]] && echo 1 || echo 0)";;
    outbound)
      case "$action" in
        add)
          local tag=${3:-} json='' via=''
          shift 3 || usage_die '用法：sb xray outbound add TAG --json JSON|@FILE [--via TAG]'
          while (($#)); do case "$1" in --json) json=${2:?}; shift 2;; --via) via=${2:?}; shift 2;; *) usage_die "未知参数：$1";; esac; done
          [[ -n "$tag" && -n "$json" ]] || usage_die '用法：sb xray outbound add TAG --json JSON|@FILE [--via TAG]'
          require_root; with_state_transaction xray-outbound _xray_outbound_add "$tag" "$json" "$via";;
        remove) [[ -n "${3:-}" ]] || usage_die '用法：sb xray outbound remove TAG'; require_root; with_state_transaction xray-outbound _xray_outbound_remove "$3";;
        *) usage_die '用法：sb xray outbound add|remove ...';;
      esac;;
    balancer)
      case "$action" in
        set)
          local tag=${3:-} selectors='' strategy=random fallback=''
          shift 3 || usage_die '用法：sb xray balancer set TAG --selectors a,b [--strategy random|roundRobin|leastPing|leastLoad] [--fallback TAG]'
          while (($#)); do case "$1" in --selectors) selectors=${2:?}; shift 2;; --strategy) strategy=${2:?}; shift 2;; --fallback) fallback=${2:?}; shift 2;; *) usage_die "未知参数：$1";; esac; done
          [[ -n "$tag" && -n "$selectors" ]] || usage_die '缺少 TAG 或 --selectors。'
          require_root; with_state_transaction xray-balancer _xray_balancer_set "$tag" "$selectors" "$strategy" "$fallback";;
        remove) [[ -n "${3:-}" ]] || usage_die '用法：sb xray balancer remove TAG'; require_root; with_state_transaction xray-balancer _xray_balancer_remove "$3";;
        *) usage_die '用法：sb xray balancer set|remove ...';;
      esac;;
    route)
      case "$action" in
        add) shift 2; require_root; with_state_transaction xray-route _xray_route_add "$@";;
        remove) [[ -n "${3:-}" ]] || usage_die '用法：sb xray route remove INDEX'; require_root; with_state_transaction xray-route _xray_route_remove "$3";;
        default) [[ -n "${3:-}" ]] || usage_die '用法：sb xray route default direct|OUTBOUND|balancer:TAG'; require_root; with_state_transaction xray-route _xray_route_default "$3";;
        *) usage_die '用法：sb xray route add|remove|default ...';;
      esac;;
    *) usage_die '用法：sb xray routing|outbound|balancer|route ...';;
  esac
}
