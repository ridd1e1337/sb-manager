#!/usr/bin/env bash
# shellcheck shell=bash

# sing-box outbounds, groups and routing. State keeps only the structure (.routing); outbound objects may
# carry passwords and WireGuard keys, so they live in a 0600 secrets file.
#
# Rule syntax: domain:/full:/keyword:/regexp:/geosite:
# and CIDR or geoip:. geosite:/geoip: become sing-box remote rule-sets that
# sing-box downloads and caches itself (no large files kept by the manager).

SBM_SINGBOX_OUTBOUNDS_SECRET="${SBM_SINGBOX_OUTBOUNDS_SECRET:-$SBM_SECRETS/singbox-outbounds.json}"
SBM_GEOSITE_URL="${SBM_GEOSITE_URL:-https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-%s.srs}"
SBM_GEOIP_URL="${SBM_GEOIP_URL:-https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-%s.srs}"
SINGBOX_RESERVED_TAGS='["direct","block","dns-local"]'

singbox_outbounds_read() { if [[ -s "$SBM_SINGBOX_OUTBOUNDS_SECRET" ]]; then jq -c . "$SBM_SINGBOX_OUTBOUNDS_SECRET"; else printf '{}\n'; fi; }

singbox_outbounds_write() {
  local json=$1 tmp
  mkdir -p "$SBM_SECRETS" || return 1
  tmp=$(mktemp "$SBM_SECRETS/.singbox-outbounds.XXXXXX") || return 1
  jq -e 'type=="object"' <<<"$json" >/dev/null 2>&1 && jq . <<<"$json" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f "$tmp" "$SBM_SINGBOX_OUTBOUNDS_SECRET" || { rm -f "$tmp"; return 1; }
}

singbox_routing_validate_tag() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,47}$ ]] || { log_error '标签只能包含小写字母、数字、点、下划线和连字符。'; return 1; }
  jq -e --arg tag "$1" --argjson reserved "$SINGBOX_RESERVED_TAGS" '$reserved|index($tag)==null' <<<'null' >/dev/null \
    || { log_error "保留标签不可使用：$1"; return 1; }
}

singbox_routing_validate_state() {
  local state=$1 outbounds
  outbounds=$(singbox_outbounds_read) || return 1
  jq -e --argjson outbounds "$outbounds" --argjson reserved "$SINGBOX_RESERVED_TAGS" '
    (.routing // {}) as $r |
    ($r.outbounds // []) as $o | ($r.groups // []) as $g | ($r.rules // []) as $rules |
    ([$o[].tag] + $reserved) as $out_tags | [$g[].tag] as $grp |
    def target_ok: . as $t | ($t.outbound!=null and ((($out_tags + $grp)|index($t.outbound))!=null));
    ($o|type=="array") and ($g|type=="array") and ($rules|type=="array")
    and (([$o[].tag] + $grp)|length)==(([$o[].tag] + $grp)|unique|length)
    and all($o[]; . as $x | ($x.tag|type=="string") and ($outbounds[$x.tag]!=null)
      and (($x.via // null)==null or ($x.via!=$x.tag and ([$o[].tag]|index($x.via))!=null)))
    and all($g[]; (.tag|type=="string") and (.outbounds|type=="array" and length>0)
      and all(.outbounds[]; . as $s | ([$o[].tag]+["direct"])|index($s)!=null)
      and (.type|IN("urltest","selector")))
    and all($rules[]; type=="object" and target_ok
      and ([.node,.user,.domain,.ip,.network,.port]|map(select(.!=null))|length)>0)
    and (($r.default // null)==null or ($r.default|target_ok))
    and (($r.domain_strategy // "AsIs")|IN("AsIs","IPIfNonMatch"))
    and (($r.dns // null)==null or ($r.dns.servers|type=="array" and length>0 and length<=8))
  ' "$state" >/dev/null || { log_error 'sing-box 出站/路由状态无效：请检查出站、分组、规则与默认出口引用。'; return 1; }
}

# Render {outbounds, endpoints, rules, rule_set, final, dns_servers}. Rules
# keep their order; geosite/geoip become remote rule-sets.
singbox_routing_render() {
  local state=$1 outbounds
  outbounds=$(singbox_outbounds_read) || return 1
  jq -c --argjson secret "$outbounds" --arg geosite "$SBM_GEOSITE_URL" --arg geoip "$SBM_GEOIP_URL" '
    (.routing // {}) as $r |
    . as $root |
    def via($o): if ($o.via // null)==null then . else .detour=$o.via end;
    def items($v): ($v // "") | split(",") | map(select(length>0));
    def pick($xs; $p): [$xs[] | select(startswith($p)) | ltrimstr($p)];
    def user_name($u): ($u|split(":")) as $p | (first($root.nodes[]? | select(.id==$p[0]) | .users[] | select(.id==$p[1]) | .name) // $p[1]);
    def nonempty_obj: with_entries(select(.value != null and .value != [] and .value != false));
    ([($r.outbounds // [])[] | . as $o | ($secret[$o.tag] + {tag:$o.tag}) | via($o)]) as $custom |
    ([($r.rules // [])[] | items(.domain) as $d | items(.ip) as $i | (.port // "" | split(",") | map(select(length>0))) as $p |
      ({inbound:(if .node then ["in-"+.node] elif .user then ["in-"+(.user|split(":")[0])] else null end),
        auth_user:(if .user then [user_name(.user)] else null end),
        domain_suffix:pick($d; "domain:"), domain:pick($d; "full:"), domain_keyword:pick($d; "keyword:"), domain_regex:pick($d; "regexp:"),
        ip_cidr:[$i[] | select(startswith("geoip:")|not)],
        ip_is_private:(any($i[]; .=="geoip:private")),
        rule_set:([pick($d; "geosite:")[] | "geosite-"+.] + [pick($i; "geoip:")[] | select(.!="private") | "geoip-"+.]),
        network:(if .network then (.network|split(",")) else null end),
        port:[$p[] | select(test("-")|not) | tonumber],
        port_range:[$p[] | select(test("-")) | sub("-";":")]} | nonempty_obj)]) as $match |
    ([($r.rules // [])[] | .outbound]) as $targets |
    ([range(0; $match|length) as $i | $match[$i] + (if $targets[$i]=="block" then {action:"reject"} else {action:"route", outbound:$targets[$i]} end)]) as $rules |
    ([($r.rules // [])[] | ((.domain // "") | split(",")[] | select(startswith("geosite:")) | ltrimstr("geosite:") as $n | {tag:("geosite-"+$n), url:($geosite|sub("%s";$n))}),
                            ((.ip // "") | split(",")[] | select(startswith("geoip:") and .!="geoip:private") | ltrimstr("geoip:") as $n | {tag:("geoip-"+$n), url:($geoip|sub("%s";$n))})]
      | unique_by(.tag) | map({type:"remote", tag, format:"binary", url, update_interval:"1d"})) as $rule_set |
    {
      outbounds: ([$custom[] | select(.type!="wireguard")]
        + [($r.groups // [])[] | if .type=="urltest" then {type:"urltest", tag, outbounds, url:"https://www.gstatic.com/generate_204", interval:"3m", tolerance:50}
                                  else {type:"selector", tag, outbounds, default:.outbounds[0]} end]),
      endpoints: [$custom[] | select(.type=="wireguard")],
      rules: ((if ($r.domain_strategy // "AsIs")=="IPIfNonMatch" and any($rules[]; .ip_cidr or .ip_is_private or ((.rule_set // [])|any(startswith("geoip-"))))
               then [{action:"resolve"}] else [] end) + $rules
             + (if (($r.default // {}).outbound // "")=="block" then [{action:"reject"}] else [] end)),
      rule_set: $rule_set,
      final: ((($r.default // {}).outbound // "direct") | if .=="block" then "direct" else . end),
      dns_servers: ($r.dns.servers // null)
    }' "$state"
}

_singbox_routing_commit() {
  local state_program=$1 outbounds=$2 candidate
  shift 2
  candidate=$(state_candidate) || return 1
  jq "$@" ".routing=(.routing // {outbounds:[],groups:[],rules:[]}) | $state_program" "$SBM_STATE" >"$candidate" || { rm -f "$candidate"; return 1; }
  if [[ -n "$outbounds" ]]; then singbox_outbounds_write "$outbounds" || { rm -f "$candidate"; return 1; }; fi
  if ! apply_candidate_state "$candidate" routing; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}

_singbox_outbound_add() {
  local tag=$1 json=$2 via=${3:-} outbounds type
  singbox_routing_validate_tag "$tag" || return 1
  jq -e --arg tag "$tag" '[(.routing.outbounds // [])[].tag, (.routing.groups // [])[].tag]|index($tag)==null' "$SBM_STATE" >/dev/null || { log_error "出站已存在：$tag"; return 1; }
  json=$(node_json_argument "$json") || return 1
  jq -e 'type=="object" and (.type|type=="string")' <<<"$json" >/dev/null || { log_error '出站必须是含 type 的 sing-box outbound 对象。'; return 1; }
  type=$(jq -r '.type' <<<"$json")
  json=$(jq -c 'del(.tag)' <<<"$json") || return 1
  outbounds=$(singbox_outbounds_read | jq -c --arg tag "$tag" --argjson ob "$json" '.[$tag]=$ob') || return 1
  _singbox_routing_commit '.routing.outbounds += [{tag:$tag,type:$type,via:(if $via=="" then null else $via end)}]' "$outbounds" \
    --arg tag "$tag" --arg type "$type" --arg via "$via" || return 1
  log_ok "已添加出站：$tag（$type）"
}

_singbox_outbound_remove() {
  local tag=$1 outbounds
  jq -e --arg tag "$tag" 'any((.routing.outbounds // [])[]; .tag==$tag)' "$SBM_STATE" >/dev/null || { log_error "出站不存在：$tag"; return 1; }
  jq -e --arg tag "$tag" '(.routing // {}) as $r |
    any(($r.outbounds // [])[]; .via==$tag) or any(($r.groups // [])[]; (.outbounds|index($tag))!=null)
    or any(($r.rules // [])[]; .outbound==$tag) or ($r.default.outbound // "")==$tag' "$SBM_STATE" >/dev/null \
    && { log_error "出站 $tag 仍被链式、分组、规则或默认出口引用。"; return 1; }
  outbounds=$(singbox_outbounds_read | jq -c --arg tag "$tag" 'del(.[$tag])') || return 1
  _singbox_routing_commit '.routing.outbounds |= map(select(.tag!=$tag))' "$outbounds" --arg tag "$tag" || return 1
  log_ok "已删除出站：$tag"
}

# WARP as a sing-box WireGuard endpoint. Registration talks to Cloudflare's
# public client API only after confirmation; manual import is available.
singbox_warp_register() {
  local keys private public install response
  require_command curl
  keys=$(sing-box generate wg-keypair 2>/dev/null) || { log_error '无法用 sing-box 生成 WireGuard 密钥。'; return 1; }
  private=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$keys")
  public=$(awk -F': *' 'tolower($1) ~ /public/ {print $2; exit}' <<<"$keys")
  [[ -n "$private" && -n "$public" ]] || { log_error '无法解析 WireGuard 密钥输出。'; return 1; }
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
     client_id:($c.client_id // "")}' <<<"$response" | {
    local info client reserved=''
    info=$(cat) && [[ -n "$info" ]] || return 1
    client=$(jq -r '.client_id' <<<"$info")
    if [[ -n "$client" ]]; then
      reserved=$(printf '%s' "$client" | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' \n' ',' | sed 's/^,//; s/,$//')
      [[ "$reserved" =~ ^[0-9]{1,3},[0-9]{1,3},[0-9]{1,3}$ ]] || { log_error 'WARP client_id 无法解析为 reserved。'; return 1; }
    fi
    jq -c --arg reserved "$reserved" 'del(.client_id) + {reserved:$reserved}' <<<"$info"
  } || { log_error 'WARP 注册返回格式无法识别。'; return 1; }
}

singbox_warp_cli() {
  local tag=warp via='' private='' v4='' v6='' peer='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=' endpoint='engage.cloudflareclient.com:2408' reserved='' register=0 info json host port
  while (($#)); do
    case "$1" in
      --tag) tag=${2:?}; shift 2;; --register) register=1; shift;;
      --private-key) private=${2:?}; shift 2;; --address-v4) v4=${2:?}; shift 2;; --address-v6) v6=${2:?}; shift 2;;
      --peer-public-key) peer=${2:?}; shift 2;; --endpoint) endpoint=${2:?}; shift 2;;
      --reserved) reserved=${2:?}; shift 2;; --via) via=${2:?}; shift 2;;
      *) usage_die '用法：sb warp [--tag TAG] --register | --private-key KEY --address-v4 IP [--address-v6 IP] [--reserved a,b,c] [--peer-public-key KEY] [--endpoint HOST:PORT]';;
    esac
  done
  require_root
  if [[ "$register" == 1 ]]; then
    confirm '将向 Cloudflare WARP 注册一个新的免费设备并获取 WireGuard 配置，继续？' N || return 0
    info=$(singbox_warp_register) || return 1
    private=$(jq -r '.private' <<<"$info"); v4=$(jq -r '.v4' <<<"$info"); v6=$(jq -r '.v6' <<<"$info")
    peer=$(jq -r '.peer' <<<"$info"); endpoint=$(jq -r '.endpoint' <<<"$info"); reserved=$(jq -r '.reserved' <<<"$info")
  fi
  [[ -n "$private" && -n "$v4" ]] || usage_die '需要 --register，或提供 --private-key 与 --address-v4。'
  [[ -z "$reserved" || "$reserved" =~ ^[0-9]{1,3},[0-9]{1,3},[0-9]{1,3}$ ]] || usage_die 'reserved 格式为三个 0-255 数字，如 1,2,3。'
  host=${endpoint%:*}; port=${endpoint##*:}
  json=$(jq -cn --arg private "$private" --arg v4 "$v4" --arg v6 "$v6" --arg peer "$peer" --arg host "$host" --argjson port "$port" --arg reserved "$reserved" '
    {type:"wireguard", system:false, mtu:1280, private_key:$private,
     address:([$v4,$v6]|map(select(.!=""))|map(if test(":") then .+"/128" else .+"/32" end)),
     peers:[{address:$host, port:$port, public_key:$peer, allowed_ips:["0.0.0.0/0","::/0"]}
       + (if $reserved=="" then {} else {reserved:($reserved|split(",")|map(tonumber))} end)]}') || return 1
  with_state_transaction warp _singbox_outbound_add "$tag" "$json" "$via"
}

_singbox_group_set() {
  local tag=$1 members=$2 type=${3:-urltest}
  singbox_routing_validate_tag "$tag" || return 1
  [[ "$type" =~ ^(urltest|selector)$ ]] || { log_error '类型只能是 urltest（自动选最快）或 selector（手动/固定第一个）。'; return 1; }
  jq -e --arg tag "$tag" 'any((.routing.outbounds // [])[]; .tag==$tag)|not' "$SBM_STATE" >/dev/null || { log_error "标签与出站重名：$tag"; return 1; }
  _singbox_routing_commit '.routing.groups=((.routing.groups // [])|map(select(.tag!=$tag))) + [{tag:$tag,outbounds:($m|split(",")),type:$type}]' '' \
    --arg tag "$tag" --arg m "$members" --arg type "$type" || return 1
  log_ok "已设置出站分组：$tag（$type）"
}

_singbox_group_remove() {
  local tag=$1
  jq -e --arg tag "$tag" '(.routing // {}) as $r | any(($r.rules // [])[]; .outbound==$tag) or ($r.default.outbound // "")==$tag' "$SBM_STATE" >/dev/null \
    && { log_error "分组 $tag 仍被规则或默认出口引用。"; return 1; }
  _singbox_routing_commit '.routing.groups |= map(select(.tag!=$tag))' '' --arg tag "$tag" || return 1
  log_ok "已删除出站分组：$tag"
}

_singbox_route_add() {
  local target='' rule='{}' value
  while (($#)); do
    case "$1" in
      --node) state_node_exists "${2:?}" || { log_error "节点不存在：$2"; return 1; }; rule=$(jq -c --arg v "$2" '.node=$v' <<<"$rule"); shift 2;;
      --user)
        value=${2:?}; [[ "$value" == *:* ]] && state_user_exists "${value%%:*}" "${value#*:}" || { log_error '--user 格式为 NODE_ID:USER_ID，且用户须存在。'; return 1; }
        rule=$(jq -c --arg v "$value" '.user=$v' <<<"$rule"); shift 2;;
      --domain)
        value=${2:?}; [[ "$value" =~ ^((domain|full|keyword|regexp|geosite):[^,]+)(,(domain|full|keyword|regexp|geosite):[^,]+)*$ ]] \
          || { log_error '域名规则使用 domain:/full:/keyword:/regexp:/geosite: 前缀，多个用逗号分隔。'; return 1; }
        local item; for item in ${value//,/ }; do
          [[ "$item" != geosite:* || "$item" =~ ^geosite:[a-z0-9!@_-]+$ ]] || { log_error "geosite 名称只能包含小写字母、数字和 -_!@：$item"; return 1; }
        done
        rule=$(jq -c --arg v "$value" '.domain=$v' <<<"$rule"); shift 2;;
      --ip)
        value=${2:?}; [[ "$value" =~ ^((geoip:[a-z0-9!_-]+|[0-9a-fA-F:./]+)(,|$))+$ ]] || { log_error 'IP 规则须为 CIDR 或 geoip:CODE（如 geoip:cn、geoip:private），多个用逗号分隔。'; return 1; }
        rule=$(jq -c --arg v "$value" '.ip=$v' <<<"$rule"); shift 2;;
      --network) [[ "${2:?}" =~ ^(tcp|udp|tcp,udp)$ ]] || { log_error 'network 只能是 tcp、udp 或 tcp,udp。'; return 1; }; rule=$(jq -c --arg v "$2" '.network=$v' <<<"$rule"); shift 2;;
      --port) [[ "${2:?}" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] || { log_error '端口规则格式如 443 或 1000-2000,8443。'; return 1; }; rule=$(jq -c --arg v "$2" '.port=$v' <<<"$rule"); shift 2;;
      --to) target=${2:?}; target=${target#group:}; target=${target#balancer:}; shift 2;;
      *) log_error "未知路由参数：$1"; return 1;;
    esac
  done
  [[ -n "$target" ]] || { log_error '请用 --to OUTBOUND|GROUP|block 指定出口。'; return 1; }
  [[ "$rule" != '{}' ]] || { log_error '至少需要一个匹配条件。'; return 1; }
  _singbox_routing_commit '.routing.rules += [$rule + {outbound:$t}]' '' --argjson rule "$rule" --arg t "$target" || return 1
  log_ok '已添加路由规则。'
}

_singbox_route_remove() {
  local index=$1
  [[ "$index" =~ ^[1-9][0-9]*$ ]] || { log_error '请输入规则序号。'; return 1; }
  jq -e --argjson i "$index" '(.routing.rules // [])|length>=$i' "$SBM_STATE" >/dev/null || { log_error "规则不存在：$index"; return 1; }
  _singbox_routing_commit '.routing.rules |= del(.[$i-1])' '' --argjson i "$index" || return 1
  log_ok "已删除规则 $index"
}

_singbox_route_default() {
  local t=${1#group:}; t=${t#balancer:}
  if [[ "$t" == direct ]]; then _singbox_routing_commit '.routing.default=null' '' || return 1
  else _singbox_routing_commit '.routing.default={outbound:$t}' '' --arg t "$t" || return 1; fi
  log_ok "默认出口：$t"
}

singbox_routing_show() {
  local json=${1:-0}
  if [[ "$json" == 1 ]]; then jq '.routing // {outbounds:[],groups:[],rules:[],default:null}' "$SBM_STATE"; return $?; fi
  jq -r '(.routing // {}) as $r |
    "出站：", (($r.outbounds // [])[] | "  \(.tag)  \(.type)" + (if .via then "  经由 \(.via)" else "" end)),
    "分组：", (($r.groups // [])[] | "  \(.tag)  \(.type)  [\(.outbounds|join(","))]"),
    "规则：", (($r.rules // []) | to_entries[] | "  \(.key+1). " + ([.value | to_entries[] | select(.value!=null and .key!="outbound") | "\(.key)=\(.value)"]|join(" ")) + " -> " + .value.outbound),
    "默认出口：" + ($r.default.outbound // "direct"),
    "域名策略：" + ($r.domain_strategy // "AsIs"),
    "DNS：" + (if $r.dns then ($r.dns.servers|join(",")) else "系统" end)' "$SBM_STATE"
}

singbox_route_strategy() {
  local value=${1:?用法：sb route strategy AsIs|IPIfNonMatch}
  [[ "$value" =~ ^(AsIs|IPIfNonMatch)$ ]] || die '域名策略只能是 AsIs 或 IPIfNonMatch（未命中域名规则时解析后再按 IP 规则匹配）。'
  require_root
  with_state_transaction route _singbox_routing_commit '.routing.domain_strategy=$v' '' --arg v "$value" || return 1
  log_ok "路由域名策略：$value"
}

# Custom DNS servers: 1.1.1.1 (UDP), tcp://, tls://, https://host/path,
# quic://, h3://. The first server becomes the final DNS.
singbox_dns_cli() {
  local action=${1:-show} servers server
  case "$action" in
    show) jq -r '"DNS：" + (if .routing.dns then (.routing.dns.servers|join(",")) else "系统（local）" end)' "$SBM_STATE";;
    set)
      servers=${2:?用法：sb dns set SERVER[,SERVER]}
      for server in ${servers//,/ }; do
        [[ "$server" =~ ^((tcp|tls|https|quic|h3)://[^[:space:]]+|[0-9a-fA-F.:]+)$ ]] || die "无效 DNS 服务器：$server（示例：1.1.1.1、https://1.1.1.1/dns-query、tls://dns.google）"
      done
      require_root
      with_state_transaction dns _singbox_routing_commit '.routing.dns={servers:($s|split(","))}' '' --arg s "$servers" || return 1
      log_ok "DNS：$servers";;
    clear) require_root; with_state_transaction dns _singbox_routing_commit 'del(.routing.dns)' '' || return 1; log_ok '已恢复系统 DNS。';;
    *) usage_die '用法：sb dns show|set SERVERS|clear';;
  esac
}

singbox_routing_cli() {
  local area=${1:-show} action=${2:-}
  case "$area" in
    show|routing) singbox_routing_show "$([[ ${2:-} == --json ]] && echo 1 || echo 0)";;
    outbound)
      case "$action" in
        add)
          local tag=${3:-} json='' via=''
          shift 3 || usage_die '用法：sb outbound add TAG --json JSON|@FILE [--via TAG]'
          while (($#)); do case "$1" in --json) json=${2:?}; shift 2;; --via) via=${2:?}; shift 2;; *) usage_die "未知参数：$1";; esac; done
          [[ -n "$tag" && -n "$json" ]] || usage_die '用法：sb outbound add TAG --json JSON|@FILE [--via TAG]'
          require_root; with_state_transaction outbound _singbox_outbound_add "$tag" "$json" "$via";;
        remove) [[ -n "${3:-}" ]] || usage_die '用法：sb outbound remove TAG'; require_root; with_state_transaction outbound _singbox_outbound_remove "$3";;
        test) require_root; singbox_outbound_test "${3:-}";;
        sub) shift 2; singbox_outsub_cli "$@";;
        *) usage_die '用法：sb outbound add|remove|test|sub ...';;
      esac;;
    group|balancer)
      case "$action" in
        set)
          local tag=${3:-} members='' type=urltest
          shift 3 || usage_die '用法：sb balancer set TAG --outbounds a,b [--type urltest|selector]'
          while (($#)); do case "$1" in --outbounds|--selectors) members=${2:?}; shift 2;; --type|--strategy) type=${2:?}; [[ "$type" != leastPing ]] || type=urltest; shift 2;; *) usage_die "未知参数：$1";; esac; done
          [[ -n "$tag" && -n "$members" ]] || usage_die '缺少 TAG 或 --outbounds。'
          require_root; with_state_transaction group _singbox_group_set "$tag" "$members" "$type";;
        remove) [[ -n "${3:-}" ]] || usage_die '用法：sb balancer remove TAG'; require_root; with_state_transaction group _singbox_group_remove "$3";;
        *) usage_die '用法：sb balancer set|remove ...';;
      esac;;
    route)
      case "$action" in
        add) shift 2; require_root; with_state_transaction route _singbox_route_add "$@";;
        remove) [[ -n "${3:-}" ]] || usage_die '用法：sb route remove INDEX'; require_root; with_state_transaction route _singbox_route_remove "$3";;
        default) [[ -n "${3:-}" ]] || usage_die '用法：sb route default direct|OUTBOUND|GROUP'; require_root; with_state_transaction route _singbox_route_default "$3";;
        test) shift 2; require_root; singbox_route_test "$@";;
        strategy) singbox_route_strategy "${3:-}";;
        ''|show) singbox_routing_show 0;;
        *) usage_die '用法：sb route add|remove|default|test|strategy ...';;
      esac;;
    *) usage_die '用法：sb routing|outbound|balancer|route ...';;
  esac
}

# Throwaway sing-box for probes: loopback mixed inbound, the live routing,
# rule-sets from the shared cache, and its own temporary directory.
_singbox_probe_config() {
  local routing=$1 port=$2 outbounds=$3
  jq -n --argjson r "$routing" --argjson port "$port" --argjson outbounds "$outbounds" --arg cache "$SBM_VAR/sing-box/cache.db" '{
    log:{level:"debug",timestamp:false},
    inbounds:[{type:"mixed",tag:"probe-in",listen:"127.0.0.1",listen_port:$port}],
    outbounds:$outbounds,
    route:{rules:$r.rules, final:$r.final}}
    + (if ($r.rule_set|length)>0 then {route:{rules:$r.rules, final:$r.final, rule_set:$r.rule_set, default_http_client:"probe-http"},
        http_clients:[{tag:"probe-http"}], experimental:{cache_file:{enabled:true,path:$cache}}} else {} end)'
}

_singbox_wait_port() { local port=$1; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do ss -H -ltn 2>/dev/null | grep -q ":$port " && return 0; sleep 0.2; done; return 1; }

# Which exit would the live rules pick for DOMAIN|IP[:PORT]? Every outbound is
# replaced by a SOCKS stub pointing at a closed loopback port, so nothing
# leaves the host; the debug log records the matched rule. Rules scoped to a
# node or user cannot match this probe.
singbox_route_test() (
  local target=${1:?用法：sb route test DOMAIN|IP[:PORT]} host port routing dir pid='' lport stubs line chosen group
  host=${target%:*}; port=${target##*:}; [[ "$port" != "$target" && "$port" =~ ^[0-9]+$ ]] || { host=$target; port=443; }
  host=${host#[}; host=${host%]}
  validate_domain "$host" || validate_ipv4 "$host" || validate_ipv6 "$host" || die "无效目标：$host"
  routing=$(singbox_routing_render "$SBM_STATE") || return 1
  dir=$(mktemp -d "$SBM_RUN/route-test.XXXXXX") || return 1
  trap '[[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; rm -rf -- "$dir"' EXIT
  lport=$(node_choose_port tcp) || return 1
  stubs=$(jq -c '[{type:"direct",tag:"direct"}] + [(.outbounds[] | select(.type!="urltest" and .type!="selector")), .endpoints[] | {type:"socks",tag,server:"127.0.0.1",server_port:9}]
    + [.outbounds[] | select(.type=="urltest" or .type=="selector") | {type:"selector",tag,outbounds,default:.outbounds[0]}]' <<<"$routing") || return 1
  # The direct exit is probed with a stub too, so the test never connects out.
  stubs=$(jq -c 'map(if .tag=="direct" then {type:"socks",tag:"direct",server:"127.0.0.1",server_port:9} else . end)' <<<"$stubs")
  _singbox_probe_config "$routing" "$lport" "$stubs" >"$dir/config.json" || return 1
  sing-box run -c "$dir/config.json" >"$dir/log" 2>&1 & pid=$!
  _singbox_wait_port "$lport" || { log_error "测试实例未能启动：$(grep -m1 -iE 'fatal|error' "$dir/log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-200)"; return 1; }
  curl -s -o /dev/null --max-time 4 -x "socks5h://127.0.0.1:$lport" "http://$(format_hostport "$host" "$port")/" || true
  sleep 0.3
  line=$(sed 's/\x1b\[[0-9;]*m//g' "$dir/log" | grep -E 'router: match\[' | grep -v '=> resolve' | head -1 || true)
  if [[ "$line" == *'=> reject'* ]]; then chosen=block
  elif [[ "$line" =~ route\(([^\)]+)\) ]]; then chosen=${BASH_REMATCH[1]}
  else chosen=$(jq -r '.final' <<<"$routing"); line=''; fi
  group=$(jq -r --arg t "$chosen" '.outbounds[] | select((.type=="urltest" or .type=="selector") and .tag==$t) | "\(.type)：\(.outbounds|join(","))"' <<<"$routing")
  # Generated index → the number shown by `sb routing` (a leading resolve
  # rule is added for IPIfNonMatch).
  local index=''
  if [[ "$line" =~ match\[([0-9]+)\] ]]; then
    index=$(( BASH_REMATCH[1] + 1 - $(jq '[.rules[0] | select(.action=="resolve")] | length' <<<"$routing") ))
  fi
  printf '%s:%s → %s%s%s\n' "$host" "$port" "$chosen" "${group:+（分组 $group，实际成员由分组选择）}" \
    "$([[ -n "$index" ]] && echo "（命中规则 $index）" || echo '（未命中规则，走默认出口）')"
)

# Connectivity test for each outbound (3x-ui "test outbound"); the full
# outbound list is kept so chained (--via) outbounds work.
singbox_outbound_test() (
  local only=${1:-} routing tags tag dir port pid='' result url="${SBM_SINGBOX_TEST_URL:-https://www.gstatic.com/generate_204}" failed=0 obs
  routing=$(singbox_routing_render "$SBM_STATE") || return 1
  tags=$(jq -r '"direct", (.outbounds[].tag), (.endpoints[].tag)' <<<"$routing")
  if [[ -n "$only" ]]; then grep -qxF "$only" <<<"$tags" || die "出站不存在：$only"; tags=$only; fi
  obs=$(jq -c '[{type:"direct",tag:"direct"}] + .outbounds' <<<"$routing")
  dir=$(mktemp -d "$SBM_RUN/outbound-test.XXXXXX") || return 1
  trap '[[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; rm -rf -- "$dir"' EXIT
  printf '%-20s %-10s %s\n' 出站 结果 耗时
  while IFS= read -r tag; do
    port=$(node_choose_port tcp) || return 1
    jq -n --argjson obs "$obs" --argjson eps "$(jq -c '.endpoints' <<<"$routing")" --arg tag "$tag" --argjson port "$port" '{log:{level:"warn"},
      inbounds:[{type:"mixed",tag:"test-in",listen:"127.0.0.1",listen_port:$port}], outbounds:$obs, route:{final:$tag}}
      + (if ($eps|length)>0 then {endpoints:$eps} else {} end)' >"$dir/config.json" || return 1
    sing-box run -c "$dir/config.json" >"$dir/log" 2>&1 & pid=$!
    if ! _singbox_wait_port "$port"; then
      printf '%-20s %-10s %s\n' "$tag" 不通 "$(grep -m1 -iE 'fatal|error' "$dir/log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-60)"; failed=1
    elif result=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 -x "socks5h://127.0.0.1:$port" "$url") \
      && [[ "${result%% *}" =~ ^(204|200)$ ]]; then
      printf '%-20s %-10s %s ms\n' "$tag" 通 "$(awk -v t="${result#* }" 'BEGIN{printf "%.0f", t*1000}')"
    else
      printf '%-20s %-10s %s\n' "$tag" 不通 "$([[ "${result%% *}" == 000 ]] && echo '连接失败或超时' || echo "HTTP ${result%% *}")"; failed=1
    fi
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=''
  done <<<"$tags"
  return "$failed"
)
