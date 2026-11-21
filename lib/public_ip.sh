#!/usr/bin/env bash
# shellcheck shell=bash

# A cloud server can get a new public IP while its DNS names stay the same.
# This updates what depends on the address: the recorded public IP, client
# addresses that were the old IP, and this server's own Cloudflare records.

SBM_PUBLIC_IP_PENDING="${SBM_PUBLIC_IP_PENDING:-$SBM_VAR/public-ip.pending}"

public_ip_managed_domains() {
  jq -r '[.certificates[]?.domain, .openlist.sites[]?.domain, .reality_site.domain?, .reality_site.domains[]?]
    | map(select(type=="string" and length>0)) | unique[]' "$SBM_STATE"
}

# Automatic checks act only when two independent services report the same IPv4.
public_ip_detect_confirmed() {
  local a b
  a=$(curl -4 --fail --silent --connect-timeout 3 --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '\r[:space:]') || return 1
  b=$(curl -4 --fail --silent --connect-timeout 3 --max-time 6 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r[:space:]') || return 1
  validate_ipv4 "$a" && [[ "$a" == "$b" ]] || return 1
  printf '%s\n' "$a"
}

# Repoint the managed domains; returns 1 when any record could not be updated.
public_ip_update_dns() {
  local old4=$1 old6=$2 new4=$3 new6=$4 domain zone failed=0
  [[ -s "$SBM_CF_DNS_ENV" ]] || return 0
  cert_load_cloudflare_env || return 1
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    # Borrowed REALITY names and other zones are not ours: skip them quietly.
    zone=$(cloudflare_dns_zone "$domain" 2>/dev/null) || continue
    cloudflare_dns_repoint "$domain" "$zone" "$old4" "$old6" "$new4" "$new6" || failed=1
  done < <(public_ip_managed_domains)
  return "$failed"
}

_public_ip_refresh() {
  local mode=${1:-manual} old4 old6 new4='' new6='' p4='' p6='' candidate changed=0
  old4=$(jq -r '.settings.public_ipv4 // ""' "$SBM_STATE"); old6=$(jq -r '.settings.public_ipv6 // ""' "$SBM_STATE")
  if [[ "$mode" == auto ]]; then new4=$(public_ip_detect_confirmed || true)
  else new4=$(detect_public_ipv4 || true); new6=$(detect_public_ipv6 || true); fi
  if [[ -z "$new4" && -z "$new6" ]]; then
    [[ "$mode" == auto ]] && return 0
    log_error '无法探测公网 IP；请检查网络后重试。'; return 1
  fi
  [[ -n "$new4" ]] || new4=$old4
  [[ -n "$new6" ]] || new6=$old6
  [[ "$new4" == "$old4" && "$new6" == "$old6" ]] || changed=1
  # DNS left over from an earlier, partly failed update still knows the address it had.
  if [[ -s "$SBM_PUBLIC_IP_PENDING" ]]; then IFS=' ' read -r p4 p6 <"$SBM_PUBLIC_IP_PENDING" || true; [[ "$p4" != - ]] || p4=''; [[ "$p6" != - ]] || p6=''; fi
  if [[ "$mode" == auto && "$changed" == 0 && ! -s "$SBM_PUBLIC_IP_PENDING" ]]; then return 0; fi
  if (( changed )); then log_info "公网 IP 已变化：${old4:--} → ${new4:--}$([[ "$new6" == "$old6" ]] || printf '；IPv6 %s → %s' "${old6:--}" "${new6:--}")"; fi
  if public_ip_update_dns "${p4:-$old4}" "${p6:-$old6}" "$new4" "$new6"; then rm -f -- "$SBM_PUBLIC_IP_PENDING"
  else
    [[ -s "$SBM_PUBLIC_IP_PENDING" ]] || (umask 077; printf '%s %s\n' "${old4:--}" "${old6:--}" >"$SBM_PUBLIC_IP_PENDING")
    log_warn "部分 DNS 记录未能更新，稍后自动重试（或运行 sb settings refresh-ip）。"
  fi
  if (( changed )); then
    candidate=$(state_candidate)
    jq --arg old4 "$old4" --arg old6 "$old6" --arg new4 "$new4" --arg new6 "$new6" --arg now "$(now_iso)" '
      def swap: if $old4!="" and .==$old4 then $new4 elif $old6!="" and .==$old6 and $new6!="" then $new6 else . end;
      .settings.public_ipv4=$new4 | .settings.public_ipv6=$new6 | .settings.public_ip_detected_at=$now
      | .settings.default_server_address |= ((. // "") | swap)
      | (if (.settings.default_server_address // "")=="" then .settings.default_server_address=(if $new4!="" then $new4 else $new6 end) | .settings.default_server_address_source="auto" else . end)
      | .nodes |= map((if has("server_address") then .server_address |= ((. // "") | swap) else . end)
                      | (if has("client_address") then .client_address |= ((. // "") | swap) else . end))
    ' "$SBM_STATE" >"$candidate" || { rm -f "$candidate"; return 1; }
    if ! apply_candidate_state "$candidate" public-ip; then rm -f "$candidate"; return 1; fi
    rm -f "$candidate"
    log_ok "已按新 IP 更新：公网地址、使用旧 IP 的节点连接地址和分享链接。客户端刷新订阅即可；手动导入的链接需重新导入。"
  elif [[ "$mode" != auto ]]; then
    log_ok "公网 IP 未变化（IPv4=${new4:--} IPv6=${new6:--}）；DNS 记录已核对。"
  fi
}
public_ip_refresh() { require_root; with_state_transaction public-ip _public_ip_refresh manual; }

# Periodic check from the maintenance timer; silent unless something changed.
public_ip_auto_check() {
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || return 0
  jq -e '(.nodes|length)>0 and (.settings.public_ipv4 // "")!=""' "$SBM_STATE" >/dev/null 2>&1 || return 0
  local current
  current=$(public_ip_detect_confirmed) || return 0
  if [[ "$current" == "$(jq -r '.settings.public_ipv4' "$SBM_STATE")" && ! -s "$SBM_PUBLIC_IP_PENDING" ]]; then return 0; fi
  with_state_transaction public-ip _public_ip_refresh auto || log_warn '公网 IP 变化后的自动更新未完成；可运行 sb settings refresh-ip。'
}
