#!/usr/bin/env bash
# shellcheck shell=bash

# Credentials travel over curl's config stdin, never in argv or API logs.
cloudflare_dns_api() {
  local method=$1 endpoint=$2 payload=${3:-} response status
  [[ ${CF_Token:-} =~ ^[A-Za-z0-9_-]+$ ]] || { log_error 'Cloudflare API Token 为空或格式无效，请重新配置 DNS 凭据。'; return 1; }
  local -a args=(--disable --silent --show-error --connect-timeout 10 --max-time 45
    --proto '=https' --request "$method" --config - --write-out $'\n%{http_code}')
  [[ -z "$payload" ]] || args+=(--data-raw "$payload")
  response=$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$CF_Token" |
    curl "${args[@]}" "https://api.cloudflare.com/client/v4/$endpoint") || {
      log_error 'Cloudflare DNS 请求未完成；请检查网络，写入请求不会自动重试。'; return 1;
    }
  status=${response##*$'\n'}; response=${response%$'\n'*}
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]] || ! jq -e '.success == true' <<<"$response" >/dev/null 2>&1; then
    # Do not echo arbitrary response bodies: authentication failures may
    # contain request details. Cloudflare's numeric codes suffice here.
    log_error "Cloudflare DNS API 失败（HTTP $status，错误码 $(jq -r '[.errors[]?.code | numbers | tostring] | join(",")' <<<"$response" 2>/dev/null || true)）；请检查 Token 的区域读取、DNS 编辑权限及区域范围。"
    return 1
  fi
  printf '%s\n' "$response"
}

cloudflare_dns_zone() {
  local domain=$1 name=$1 response zone zone_name
  if [[ -n ${CF_Zone_ID:-} ]]; then
    [[ "$CF_Zone_ID" =~ ^[a-fA-F0-9]{32}$ ]] || { log_error 'Cloudflare Zone ID 格式无效。'; return 1; }
    response=$(cloudflare_dns_api GET "zones/$CF_Zone_ID") || return 1
    zone_name=$(jq -r '.result.name // "" | ascii_downcase' <<<"$response") || return 1
    [[ "$domain" == "$zone_name" || "$domain" == *."$zone_name" ]] || {
      log_error "域名 $domain 不属于配置的 Cloudflare Zone；请更正 Zone ID 或留空自动查询。"; return 1;
    }
    zone=$(jq -r '.result | select(.status=="active") | .id // empty' <<<"$response") || return 1
  else
    # Query exact suffixes, longest first, to handle delegated child zones.
    while [[ "$name" == *.* ]]; do
      response=$(cloudflare_dns_api GET "zones?name=$name&status=active&per_page=50") || return 1
      zone=$(jq -r --arg name "$name" '[.result[] | select(.name==$name and .status=="active")] | if length==1 then .[0].id else empty end' <<<"$response") || return 1
      [[ -z "$zone" ]] || break
      name=${name#*.}
    done
  fi
  [[ ${zone:-} =~ ^[a-fA-F0-9]{32}$ ]] || {
    log_error "未找到 $domain 的有效 Cloudflare 区域；请检查 NS 托管状态和 Token 的区域权限。"; return 1;
  }
  printf '%s\n' "$zone"
}

cloudflare_dns_records() {
  local zone=$1 domain=$2 response
  response=$(cloudflare_dns_api GET "zones/$zone/dns_records?name=$domain&per_page=100") || return 1
  jq -e '(.result | type=="array") and ((.result_info.total_pages // 1) <= 1)' <<<"$response" >/dev/null || {
    log_error "域名 $domain 的 DNS 响应不完整，请在 Cloudflare 控制台处理记录。"; return 1;
  }
  jq -c '.result' <<<"$response" | cloudflare_dns_normalize_records
}

cloudflare_dns_normalize_records() {
  # Cloudflare canonicalizes IPv6. Expand compression and trim leading zeros
  # on both detected and returned addresses without requiring Python/iproute2.
  jq -c '
    def ipv6:
      ascii_downcase | split("::") as $parts
      | ($parts[0] | split(":") | map(select(length>0))) as $left
      | if ($parts|length)==2 then
          ($parts[1] | split(":") | map(select(length>0))) as $right
          | $left + [range(0; 8-($left|length)-($right|length)) | "0"] + $right
        else $left end
      | map(sub("^0+"; "") | if .=="" then "0" else . end) | join(":");
    map(if .type=="AAAA" and (.content|length)>0 then .content |= ipv6 else . end)
  '
}

cloudflare_dns_records_match() {
  local records=$1 ipv4=$2 ipv6=$3 domain=$4
  if ! jq -e --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" '
    all(.[]; if .type=="CNAME" or .type=="NS" then false
      elif .type=="A" then .content==$ipv4 and .proxied==false
      elif .type=="AAAA" then .content==$ipv6 and .proxied==false
      else true end)
  ' <<<"$records" >/dev/null; then
    log_error "$domain 已有指向其他地址、开启橙云或 CNAME/NS 的记录；请使用新的节点子域名，或先在 Cloudflare 修正记录。"
    return 1
  fi
}

# Called under the manager transaction lock. Never repoint an existing name.
# The journal is persisted before POST, so a lost response is recoverable too.
cloudflare_dns_prepare() {
  local domain=$1 zone=$2 ipv4 ipv6 records record type content payload marker journal tmp
  journal="${SBM_OPERATION_SNAPSHOT:?DNS 操作需要状态事务}/cloudflare-dns.json"
  log_info "探测本机公网地址，为 $domain 准备 DNS…"
  ipv4=$(detect_public_ipv4 || true); ipv6=$(detect_public_ipv6 || true)
  [[ -n "$ipv4" || -n "$ipv6" ]] || {
    log_error '无法探测公网 IP；请设置 SBM_PUBLIC_IPV4 / SBM_PUBLIC_IPV6 后重试。'; return 1;
  }
  ipv6=$(jq -n --arg ip "$ipv6" '[{type:"AAAA",content:$ip}]' | cloudflare_dns_normalize_records | jq -r '.[0].content') || return 1
  records=$(cloudflare_dns_records "$zone" "$domain") || return 1
  # An existing AAAA must also match, even when only an A will be created.
  # Unknown/disabled IPv6 detection cannot prove an existing AAAA is safe.
  cloudflare_dns_records_match "$records" "$ipv4" "$ipv6" "$domain" || return 1
  for type in A AAAA; do
    if [[ "$type" == A ]]; then content=$ipv4; else content=$ipv6; fi
    [[ -n "$content" ]] || continue
    if jq -e --arg type "$type" 'any(.[]; .type==$type)' <<<"$records" >/dev/null; then
      log_info "复用 DNS：$domain $type $content（DNS only）"
      continue
    fi
    marker="sb-manager:$(random_hex 16)" || return 1
    payload=$(jq -cn --arg type "$type" --arg domain "$domain" --arg content "$content" --arg marker "$marker" \
      '{type:$type,name:$domain,content:$content,ttl:1,proxied:false,comment:$marker}') || return 1
    record=$(jq -cn --arg zone "$zone" --argjson payload "$payload" '{zone:$zone,record:$payload}') || return 1
    tmp=$(mktemp "${journal}.XXXXXX") || return 1
    if [[ -s "$journal" ]]; then
      jq --argjson record "$record" '. + [$record]' "$journal" >"$tmp" || return 1
    else
      jq -n --argjson record "$record" '[$record]' >"$tmp" || return 1
    fi
    chmod 0600 "$tmp" && mv -f "$tmp" "$journal" || return 1
    cloudflare_dns_api POST "zones/$zone/dns_records" "$payload" >/dev/null || return 1
    log_info "已添加 DNS：$domain $type $content（DNS only）"
  done
  records=$(cloudflare_dns_records "$zone" "$domain") || return 1
  cloudflare_dns_records_match "$records" "$ipv4" "$ipv6" "$domain"
}

# Only delete records bearing this transaction's random marker and unchanged
# connection fields. Pre-existing records and concurrently edited ones survive.
cloudflare_dns_rollback() (
  local snapshot=$1 journal entries entry zone domain records ids id rc=0 count matched
  journal="$snapshot/cloudflare-dns.json"
  [[ -s "$journal" ]] || return 0
  cert_load_cloudflare_env || return 1
  entries=$(jq -c 'reverse[]' "$journal") || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    zone=$(jq -r '.zone' <<<"$entry") || return 1
    domain=$(jq -r '.record.name' <<<"$entry") || return 1
    [[ "$zone" =~ ^[a-fA-F0-9]{32}$ ]] && validate_domain "$domain" || return 1
    records=$(cloudflare_dns_records "$zone" "$domain") || { rc=1; continue; }
    count=$(jq --argjson entry "$entry" '[.[] | select(.comment==$entry.record.comment)] | length' <<<"$records") || return 1
    ids=$(jq -r --argjson entry "$entry" '.[] | select(.comment==$entry.record.comment and .type==$entry.record.type and .name==$entry.record.name and (.content|ascii_downcase)==($entry.record.content|ascii_downcase) and .proxied==false) | .id' <<<"$records") || return 1
    matched=0
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      [[ "$id" =~ ^[a-fA-F0-9]{32}$ ]] || { rc=1; continue; }
      matched=$((matched + 1))
      if cloudflare_dns_api DELETE "zones/$zone/dns_records/$id" >/dev/null; then
        log_info "已清理本次新建的 DNS：$domain"
      else rc=1; fi
    done <<<"$ids"
    if (( count != matched )); then
      log_warn "$domain 的 DNS 已被其他操作修改，保留记录，请在 Cloudflare 控制台核对。"
      rc=1
    fi
  done <<<"$entries"
  if (( rc != 0 )); then log_error "DNS 清理未完成，请按 $journal 在 Cloudflare 控制台核对本次记录。"; fi
  return "$rc"
)
