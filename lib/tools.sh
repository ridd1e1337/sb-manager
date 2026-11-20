#!/usr/bin/env bash
# shellcheck shell=bash

# Key/cert generators and checks, backed
# by the installed sing-box so formats always match the running core.

tools_singbox() {
  command_exists sing-box || [[ -x "$SBM_SING_BOX_BIN" ]] || die 'sing-box 尚未安装，请先运行 sb core update。'
  "${SBM_SING_BOX_BIN:-sing-box}" "$@"
}

# Judge a REALITY target for sing-box: TLS 1.3 with SNI and a certificate that
# covers the name. (sing-box REALITY uses X25519, so no post-quantum check.)
tools_reality_check() {
  local domain=${1:?用法：sb tools reality-check DOMAIN} out start ms ok=1 names name covered=0
  validate_domain "$domain" || die "无效域名：$domain"
  start=${EPOCHREALTIME/./}
  out=$(timeout 15 openssl s_client -connect "$domain:443" -servername "$domain" -tls1_3 </dev/null 2>&1) || true
  ms=$(( (${EPOCHREALTIME/./} - start) / 1000 ))
  printf 'REALITY 目标检查：%s（耗时 %s ms）\n' "$domain" "$ms"
  if grep -q 'BEGIN CERTIFICATE\|Server certificate' <<<"$out"; then printf '  [通过] 带 SNI 握手成功\n'; else printf '  [失败] 带 SNI 握手失败\n'; ok=0; fi
  if grep -qE 'Protocol *: *TLSv1\.3|New, TLSv1\.3' <<<"$out"; then printf '  [通过] TLS 1.3\n'; else printf '  [失败] 不支持 TLS 1.3\n'; ok=0; fi
  names=$(openssl x509 -noout -ext subjectAltName 2>/dev/null <<<"$out" | tr ',' '\n' | sed -n 's/.*DNS://p')
  for name in $names; do [[ "$name" == "$domain" || ( "$name" == '*.'* && "${domain#*.}" == "${name#\*.}" ) ]] && covered=1; done
  if (( covered )); then printf '  [通过] 证书覆盖该域名\n'; else printf '  [警告] 证书域名列表未包含 %s\n' "$domain"; fi
  if (( ok )); then log_ok "$domain 适合作为 REALITY 目标。"; else log_error "$domain 不适合作为 REALITY 目标。"; return 1; fi
}

# SHA-256 of a certificate: a PEM file or HOST[:PORT].
tools_cert_hash() {
  local target=${1:?用法：sb tools cert-hash FILE|HOST[:PORT]} host port
  if [[ -r "$target" ]]; then
    openssl x509 -in "$target" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'; return
  fi
  host=${target%:*}; port=${target##*:}; [[ "$port" != "$target" ]] || port=443
  validate_port "$port" || die "无效端口：$port"
  timeout 15 openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
}

tools_cli() {
  local action=${1:-help}; shift || true
  case "$action" in
    uuid|rand) tools_singbox generate "$action" "$@";;
    reality-keypair|wg-keypair|tls-keypair|vapid-keypair) tools_singbox generate "$action" "$@";;
    ech) tools_singbox generate ech-keypair "${1:?用法：sb tools ech DOMAIN}";;
    reality-check) tools_reality_check "$@";;
    cert-hash) tools_cert_hash "$@";;
    *) usage_die '用法：sb tools uuid|reality-keypair|wg-keypair|tls-keypair DOMAIN|ech DOMAIN|reality-check DOMAIN|cert-hash FILE|HOST[:PORT]';;
  esac
}
