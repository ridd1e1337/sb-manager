#!/usr/bin/env bash
# shellcheck shell=bash

source "$SBM_LIB/lib/cloudflare_dns.sh"

SBM_ACME_HOME="${SBM_ACME_HOME:-$SBM_VAR/acme/home}"
SBM_ACME_CONFIG="${SBM_ACME_CONFIG:-$SBM_VAR/acme/config}"
SBM_ACME_CERT_HOME="${SBM_ACME_CERT_HOME:-$SBM_VAR/acme/internal-certs}"
SBM_ACME_BIN="${SBM_ACME_BIN:-$SBM_ACME_HOME/acme.sh}"
SBM_CF_DNS_ENV="${SBM_CF_DNS_ENV:-$SBM_SECRETS/dns-cloudflare.env}"
SBM_ACME_LEGACY_HOME="${SBM_ACME_LEGACY_HOME:-${HOME:-/root}/.acme.sh}"
SBM_ACME_VERSION="${SBM_ACME_VERSION:-3.1.4}"
SBM_ACME_COMMIT="${SBM_ACME_COMMIT:-3661fd86b6304115e42f43910e6dd452ab9866d6}"
SBM_ACME_SHA256="${SBM_ACME_SHA256:-9af3ad3d775a5782246df4cdd4b4e7b9b3179deb63c509b10e3ba0433093a884}"
SBM_ACME_ISSUE_TIMEOUT="${SBM_ACME_ISSUE_TIMEOUT:-600}"
SBM_ACME_INSTALL_TIMEOUT="${SBM_ACME_INSTALL_TIMEOUT:-120}"
SBM_ACME_CRON_TIMEOUT="${SBM_ACME_CRON_TIMEOUT:-900}"

acme_migrate_legacy_home() {
  local legacy=$SBM_ACME_LEGACY_HOME dir base tmp
  [[ "$legacy" != "$SBM_ACME_HOME" && -d "$legacy" ]] || return 0
  [[ -f "$legacy/account.conf" ]] || return 0
  mkdir -p "$SBM_ACME_HOME" "$SBM_ACME_CONFIG" "$SBM_ACME_CERT_HOME"
  if [[ -d "$legacy/ca" && ! -e "$SBM_ACME_CONFIG/ca" ]]; then
    cp -a "$legacy/ca" "$SBM_ACME_CONFIG/ca"
  fi
  if [[ -f "$legacy/account.conf" ]] && ! grep -q '^ACCOUNT_EMAIL=' "$SBM_ACME_CONFIG/account.conf" 2>/dev/null; then
    tmp=$(mktemp "$SBM_ACME_CONFIG/.account.XXXXXX")
    {
      cat "$SBM_ACME_CONFIG/account.conf" 2>/dev/null || true
      sed -n '/^ACCOUNT_EMAIL=/p' "$legacy/account.conf"
    } | awk '!seen[$0]++' >"$tmp"
    chmod 0600 "$tmp"; mv -f "$tmp" "$SBM_ACME_CONFIG/account.conf"
  fi
  shopt -s nullglob
  for dir in "$legacy"/*; do
    [[ -d "$dir" ]] || continue
    base=${dir##*/}
    case "$base" in ca|deploy|dnsapi|notify|.??*) continue;; esac
    [[ -e "$SBM_ACME_CERT_HOME/$base" ]] || cp -a "$dir" "$SBM_ACME_CERT_HOME/$base"
  done
  shopt -u nullglob
}

acme_run_timed() {
  local label=$1 seconds=$2 allowed=$3 rc=0 code
  shift 3
  [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || { log_error "$label 超时设置无效：$seconds"; return 1; }
  if timeout --kill-after=15s "${seconds}s" "$SBM_ACME_BIN" "$@"; then
    return 0
  else
    rc=$?
  fi
  for code in $allowed; do
    [[ "$rc" == "$code" ]] && return 0
  done
  if [[ "$rc" == 124 || "$rc" == 137 ]]; then
    log_error "$label 超过 ${seconds} 秒，已终止并回滚；请检查 DNS API、域名 NS 和网络。"
  else
    log_error "$label 失败（退出码 $rc）。"
  fi
  return "$rc"
}

acme_install() {
  local email=${1:-} force=${2:-0} url tmpdir source actual
  if [[ -x "$SBM_ACME_BIN" && "$force" != 1 ]]; then
    acme_migrate_legacy_home
    return 0
  fi
  [[ -n "$email" ]] || email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  [[ -n "$email" ]] || die "首次安装 acme.sh 需要邮箱地址。"
  url="https://github.com/acmesh-official/acme.sh/archive/${SBM_ACME_COMMIT}.tar.gz"
  tmpdir=$(mktemp -d "$SBM_CACHE/acme.XXXXXX")
  download_file_with_retries "$url" "$tmpdir/acme.tar.gz" "acme.sh $SBM_ACME_VERSION" 5
  actual=$(sha256sum "$tmpdir/acme.tar.gz" | awk '{print $1}')
  [[ "$actual" == "$SBM_ACME_SHA256" ]] || { rm -rf "$tmpdir"; die "acme.sh 下载摘要不匹配，已拒绝执行。"; }
  mkdir -p "$tmpdir/src"; tar -xzf "$tmpdir/acme.tar.gz" -C "$tmpdir/src" --strip-components=1
  source="$tmpdir/src/acme.sh"; [[ -x "$source" ]] || chmod +x "$source"
  mkdir -p "$SBM_ACME_HOME" "$SBM_ACME_CONFIG" "$SBM_ACME_CERT_HOME"
  (
    cd "$tmpdir/src"
    ./acme.sh --install --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" \
      --cert-home "$SBM_ACME_CERT_HOME" --accountemail "$email" --nocron --noprofile
  )
  rm -rf "$tmpdir"
  [[ -x "$SBM_ACME_BIN" ]] || die "acme.sh 安装失败。"
  "$SBM_ACME_BIN" --version 2>&1 | pipe_has -F "$SBM_ACME_VERSION" || die "acme.sh 安装版本与固定版本 $SBM_ACME_VERSION 不一致。"
  acme_migrate_legacy_home
  artifact_record acme.sh "$SBM_ACME_VERSION" "$url" "sha256:$SBM_ACME_SHA256" "$SBM_ACME_BIN"
  log_ok "acme.sh $SBM_ACME_VERSION 已通过固定摘要安装。"
}

SBM_DNS_ENV="${SBM_DNS_ENV:-$SBM_SECRETS/dns-provider.env}"

# DNS-01 providers: name → acme.sh dnsapi id, display name and the credential
# variables that dnsapi script reads.  Cloudflare keeps its own env file
# because the DNS-record automation (cloudflare_dns.sh) shares it.
cert_provider_id() {
  case "$1" in
    cloudflare|cf|dns_cf) printf 'dns_cf\n';;
    aliyun|ali|dns_ali) printf 'dns_ali\n';;
    dnspod|dp|dns_dp) printf 'dns_dp\n';;
    namesilo|dns_namesilo) printf 'dns_namesilo\n';;
    *) return 1;;
  esac
}
cert_provider_label() {
  case "$1" in
    dns_cf) printf 'Cloudflare\n';; dns_ali) printf '阿里云\n';;
    dns_dp) printf '腾讯云 DNSPod\n';; dns_namesilo) printf 'NameSilo\n';; *) printf '%s\n' "$1";;
  esac
}
cert_provider_vars() {
  case "$1" in
    dns_cf) printf 'CF_Token\n';; dns_ali) printf 'Ali_Key Ali_Secret\n';;
    dns_dp) printf 'DP_Id DP_Key\n';; dns_namesilo) printf 'Namesilo_Key\n';;
  esac
}
cert_current_provider() { jq -r '.settings.acme_dns_provider // "dns_cf"' "$SBM_STATE"; }

# sb cert setup PROVIDER --email EMAIL [--stdin] [VAR=VALUE ...]
# Credentials are read as VAR=VALUE lines from standard input with --stdin, so
# they never appear in the process list or shell history.
_cert_setup() {
  local provider email='' from_stdin=0 line key value var tmp candidate target
  local -A creds=()
  provider=$(cert_provider_id "${1:-}") || usage_die '用法：sb cert setup <cloudflare|aliyun|dnspod|namesilo> --email EMAIL [--stdin] [变量=值 …]'
  shift
  while (($#)); do
    case "$1" in
      --email) email=${2:?缺少邮箱}; shift 2;;
      --stdin) from_stdin=1; shift;;
      *=*) creds[${1%%=*}]=${1#*=}; shift;;
      *) usage_die "未知参数：$1";;
    esac
  done
  if [[ "$from_stdin" == 1 ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *=* ]] || continue
      key=${line%%=*}; value=${line#*=}; creds[$key]=$value
    done
  fi
  [[ -n "$email" ]] || email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die '请用 --email 提供有效的 ACME 账户邮箱。'
  for var in $(cert_provider_vars "$provider"); do
    value=${creds[$var]:-}
    [[ -n "$value" ]] || die "缺少 $(cert_provider_label "$provider") 的凭据：$var"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$var 含有换行符。"
  done
  acme_install "$email"
  if [[ "$provider" == dns_cf ]]; then target=$SBM_CF_DNS_ENV; else target=$SBM_DNS_ENV; fi
  tmp=$(mktemp "$SBM_SECRETS/.dns-provider.XXXXXX")
  {
    for var in $(cert_provider_vars "$provider"); do printf '%s=%q\n' "$var" "${creds[$var]}"; done
    [[ "$provider" != dns_cf || -z "${creds[CF_Zone_ID]:-}" ]] || printf 'CF_Zone_ID=%q\n' "${creds[CF_Zone_ID]}"
  } >"$tmp"
  chmod 0600 "$tmp"; mv "$tmp" "$target"
  [[ "$provider" != dns_cf ]] || rm -f "$SBM_DNS_ENV"  # credentials of a provider no longer in use
  candidate=$(state_candidate)
  jq --arg e "$email" --arg p "$provider" '.settings.acme_email=$e | .settings.acme_dns_provider=$p' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" acme-settings; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "$(cert_provider_label "$provider") DNS-01 凭据已保存（不会回显）。"
  [[ "$provider" == dns_cf ]] || log_info '提示：这个服务商只用于证书验证；节点域名的 A/AAAA 记录需要你自己指向本机。'
}
cert_setup() { with_state_transaction cert-provider _cert_setup "$@"; }

# Load the credentials of the configured provider into the environment.
cert_load_dns_env() {
  local provider
  provider=$(cert_current_provider)
  if [[ "$provider" == dns_cf ]]; then cert_load_cloudflare_env; return $?; fi
  [[ -s "$SBM_DNS_ENV" ]] || die "尚未配置 $(cert_provider_label "$provider") 的 DNS 凭据。运行：sb cert setup"
  unset Ali_Key Ali_Secret DP_Id DP_Key Namesilo_Key
  set -a
  # shellcheck disable=SC1090
  source "$SBM_DNS_ENV"
  set +a
}

cert_status_json() {
  local provider configured=false
  provider=$(cert_current_provider)
  if [[ "$provider" == dns_cf ]]; then [[ ! -s "$SBM_CF_DNS_ENV" ]] || configured=true
  else [[ ! -s "$SBM_DNS_ENV" ]] || configured=true; fi
  jq -n --arg provider "$provider" --arg name "$(cert_provider_label "$provider")" --argjson configured "$configured" \
    --arg email "$(jq -r '.settings.acme_email // ""' "$SBM_STATE")" \
    '{provider:$provider,"label":$name,configured:$configured,email:$email,auto_dns:($provider=="dns_cf"),
      providers:[{id:"cloudflare","label":"Cloudflare",vars:[{name:"CF_Token","label":"API Token"}]},
                 {id:"aliyun","label":"阿里云",vars:[{name:"Ali_Key","label":"AccessKey ID"},{name:"Ali_Secret","label":"AccessKey Secret"}]},
                 {id:"dnspod","label":"腾讯云 DNSPod",vars:[{name:"DP_Id","label":"Token ID"},{name:"DP_Key","label":"Token"}]},
                 {id:"namesilo","label":"NameSilo",vars:[{name:"Namesilo_Key","label":"API Key"}]}]}'
}

_cert_setup_cloudflare() {
  local token=${1:-} zone_id=${2:-} email=${3:-} candidate tmp
  [[ -n "$token" ]] || prompt_secret token 'Cloudflare API Token'
  [[ -n "$zone_id" ]] || { [[ -t 0 ]] && prompt_value zone_id 'Cloudflare Zone ID（可留空，自动查询）' ''; }
  [[ -n "$email" ]] || { [[ -t 0 ]] && prompt_value email 'ACME 账户邮箱' "$(jq -r '.settings.acme_email // ""' "$SBM_STATE")"; }
  [[ -n "$token" ]] || die "API Token 不能为空。"
  [[ -n "$email" ]] || die "邮箱不能为空。"
  acme_install "$email"
  tmp=$(mktemp "$SBM_SECRETS/.dns-cloudflare.XXXXXX")
  {
    printf 'CF_Token=%q\n' "$token"
    [[ -n "$zone_id" ]] && printf 'CF_Zone_ID=%q\n' "$zone_id"
  } >"$tmp"
  chmod 0600 "$tmp"; mv "$tmp" "$SBM_CF_DNS_ENV"
  candidate=$(state_candidate)
  jq --arg e "$email" '.settings.acme_email=$e | .settings.acme_dns_provider="dns_cf"' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" acme-settings; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  log_ok "Cloudflare DNS-01 凭据已保存（不会在面板中回显）。"
}
cert_setup_cloudflare() { with_state_transaction cert-provider _cert_setup_cloudflare "$@"; }

cert_load_cloudflare_env() {
  [[ -s "$SBM_CF_DNS_ENV" ]] || die "尚未配置 Cloudflare DNS API Token。运行：sb cert setup-cloudflare"
  unset CF_Token CF_Zone_ID CF_Account_ID CF_Key CF_Email
  set -a
  # shellcheck disable=SC1090
  source "$SBM_CF_DNS_ENV"
  set +a
}

cert_usable() {
  local domain=$1 cert_pub key_pub
  validate_domain "$domain" || return 1
  [[ -s "$SBM_CERTS/$domain/fullchain.pem" && -s "$SBM_CERTS/$domain/key.pem" ]] || return 1
  openssl x509 -in "$SBM_CERTS/$domain/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || return 1
  openssl x509 -in "$SBM_CERTS/$domain/fullchain.pem" -noout -checkhost "$domain" >/dev/null 2>&1 || return 1
  cert_pub=$(openssl x509 -in "$SBM_CERTS/$domain/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum) || return 1
  key_pub=$(openssl pkey -in "$SBM_CERTS/$domain/key.pem" -pubout -outform DER | sha256sum) || return 1
  [[ "$cert_pub" == "$key_pub" ]]
}

# Reuse from the node-add transaction without taking the manager lock again.
_cert_prepare_node_domain() {
  local domain=$1 zone email
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die 'DNS 和证书申请不支持 --dry-run。'
  validate_domain "$domain" || { log_error "无效域名：$domain"; return 1; }
  if cert_usable "$domain"; then log_info "复用现有证书：$domain"; return 0; fi
  cert_load_dns_env || return 1
  email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE") || return 1
  [[ -n "$email" ]] || { log_error '请先用 sb cert setup 配置 DNS 服务商和 ACME 邮箱。'; return 1; }
  acme_install "$email" || return 1
  if [[ $(cert_current_provider) == dns_cf ]]; then
    zone=$(cloudflare_dns_zone "$domain") || return 1
    cloudflare_dns_prepare "$domain" "$zone" || return 1
  else
    zone=''
    log_info "$(cert_provider_label "$(cert_current_provider)") 只用于证书验证；请确认 $domain 的 A/AAAA 记录已指向本机。"
  fi
  _cert_issue "$domain" "$email" "$zone" || return 1
  cert_usable "$domain"
}
cert_prepare_node_domain() { with_state_transaction cert-node-domain _cert_prepare_node_domain "$@"; }

cert_hook() {
  local domain=$1 dir cert_pub key_pub
  dir="$SBM_CERTS/$domain"
  [[ -s "$dir/fullchain.pem" && -s "$dir/key.pem" ]] || return 1
  openssl x509 -in "$dir/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || { log_error "$domain 证书无效或已经过期。"; return 1; }
  openssl verify -purpose sslserver -CAfile "$dir/fullchain.pem" "$dir/fullchain.pem" >/dev/null 2>&1 || {
    log_error "$domain 证书链校验失败。"
    return 1
  }
  if openssl x509 -help 2>&1 | pipe_has -- '-checkhost'; then
    openssl x509 -in "$dir/fullchain.pem" -noout -checkhost "$domain" >/dev/null 2>&1 || { log_error "$domain 不在证书 SAN/CN 中。"; return 1; }
  fi
  cert_pub=$(openssl x509 -in "$dir/fullchain.pem" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$dir/key.pem" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || { log_error "$domain 证书与私钥不匹配。"; return 1; }
  chmod 0644 "$dir/fullchain.pem"
  chmod 0640 "$dir/key.pem"
  set_group_if_exists "$SBM_SERVICE_USER" "$dir"; set_group_if_exists "$SBM_SERVICE_USER" "$dir/key.pem"
  chmod 0750 "$dir"
  if [[ "$SBM_SKIP_INIT" != "1" ]] && service_active "$SBM_SERVICE"; then
    service_restart "$SBM_SERVICE" >/dev/null 2>&1 || return 1
    service_wait_active "$SBM_SERVICE" 20 || return 1
  fi
  if declare -F openlist_cert_reload >/dev/null 2>&1; then openlist_cert_reload "$domain" || return 1; fi
}

_cert_record_state() {
  local domain=$1 candidate tmp
  candidate=$(state_candidate)
  jq --arg d "$domain" --arg now "$(now_iso)" --arg cert "$SBM_CERTS/$domain/fullchain.pem" --arg key "$SBM_CERTS/$domain/key.pem" '
    (.settings.acme_dns_provider // "dns_cf") as $prov |
    .certificates |= (map(select(.domain!=$d)) + [{domain:$d,provider:("acme.sh/" + $prov),key_type:"ec-256",certificate_path:$cert,key_path:$key,updated_at:$now}])
  ' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "cert-$domain"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
}

_cert_issue() {
  local domain=$1 email=${2:-} zone=${3:-} dir reloadcmd provider timeout
  local -a dns_args
  validate_domain "$domain" || die "无效域名：$domain"
  [[ -n "$email" ]] || email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  acme_install "$email" || return 1
  cert_load_dns_env || return 1
  provider=$(cert_current_provider); dns_args=(--dns "$provider"); timeout=$SBM_ACME_ISSUE_TIMEOUT
  [[ "$provider" != dns_cf || -z "$zone" ]] || export CF_Zone_ID="$zone"
  # NameSilo publishes record changes in batches of up to 15 minutes.
  if [[ "$provider" == dns_namesilo ]]; then dns_args+=(--dnssleep 900); (( timeout >= 1500 )) || timeout=1500; fi
  acme_migrate_legacy_home || return 1
  dir="$SBM_CERTS/$domain"; mkdir -p "$dir"; chmod 0750 "$dir"
  log_info "使用 $(cert_provider_label "$provider") DNS-01 为 $domain 签发 ECDSA 证书…"
  acme_run_timed "为 $domain 签发证书" "$timeout" '0 2' \
    --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
    --accountemail "$email" --issue "${dns_args[@]}" -d "$domain" --server letsencrypt --keylength ec-256 || return $?
  reloadcmd="SBM_SKIP_STATE_INIT=1 $(printf '%q' "$SBM_BIN_DIR/sb") cert hook $(printf '%q' "$domain")"
  acme_run_timed "为 $domain 部署证书" "$SBM_ACME_INSTALL_TIMEOUT" '0' \
    --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
    --install-cert -d "$domain" --ecc \
    --fullchain-file "$dir/fullchain.pem" --key-file "$dir/key.pem" --reloadcmd "$reloadcmd" || return $?
  cert_hook "$domain" || return $?
  _cert_record_state "$domain" || return $?
  log_ok "证书已部署：$dir"
}
cert_issue() { with_state_transaction cert-issue _cert_issue "$@"; }

_cert_renew() {
  local quiet=${1:-0}
  [[ -x "$SBM_ACME_BIN" ]] || { [[ "$quiet" == 1 ]] || log_warn "acme.sh 尚未安装。"; return 0; }
  cert_load_dns_env
  if [[ "$quiet" == 1 ]]; then
    acme_run_timed 'ACME 定时续签' "$SBM_ACME_CRON_TIMEOUT" '0' \
      --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
      --cron >/dev/null || return $?
  else
    acme_run_timed 'ACME 定时续签' "$SBM_ACME_CRON_TIMEOUT" '0' \
      --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" \
      --cron || return $?
  fi
  local d
  while IFS= read -r d; do cert_hook "$d" || return 1; done < <(jq -r '.certificates[].domain' "$SBM_STATE")
}
cert_renew() {
  local rc=0
  with_state_transaction cert-renew _cert_renew "$@" || rc=$?
  if (( rc != 0 )) && declare -F notification_send >/dev/null 2>&1; then
    notification_send certificate_renewal_failed "sb-manager 证书续期失败：$(hostname 2>/dev/null || printf unknown)，请运行 sb cert renew 和 sb logs 检查。" || true
  fi
  return "$rc"
}

# Refusals happen before the transaction, so nothing is rolled back for them.
_cert_delete_check() {
  local domain=$1 users
  validate_domain "$domain" || { log_error "无效域名：$domain"; return 1; }
  [[ -d "$SBM_CERTS/$domain" ]] || jq -e --arg d "$domain" 'any(.certificates[]?; .domain==$d)' "$SBM_STATE" >/dev/null || { log_error "没有这个域名的证书：$domain"; return 1; }
  users=$(jq -r --arg d "$domain" '[(.nodes[]? | select(.domain==$d and (.security // "")!="reality") | "节点 " + .id),
      (.openlist.sites[]? | select(.domain==$d) | "OpenList 网站"), (if any(.reality_site.domains[]?; .==$d) or .reality_site.domain?==$d then "Reality 共用 443 的网站" else empty end)] | join("、")' "$SBM_STATE")
  [[ -z "$users" ]] || { log_error "证书仍在使用（$users）；请先删除或改用其他域名，再删除证书。"; return 1; }
}

_cert_delete() {
  local domain=$1 candidate
  candidate=$(state_candidate)
  jq --arg d "$domain" '.certificates |= map(select(.domain!=$d))' "$SBM_STATE" >"$candidate"
  if ! apply_candidate_state "$candidate" "cert-delete-$domain"; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  # Stop renewing it, then remove the files.
  if [[ -x "$SBM_ACME_BIN" ]]; then
    "$SBM_ACME_BIN" --home "$SBM_ACME_HOME" --config-home "$SBM_ACME_CONFIG" --cert-home "$SBM_ACME_CERT_HOME" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
  fi
  rm -rf -- "$SBM_ACME_CERT_HOME/${domain}_ecc" "$SBM_CERTS/$domain"
  log_ok "已删除证书并停止续签：$domain（Cloudflare 上的 DNS 记录未改动）"
}
cert_delete() { require_root; _cert_delete_check "$1" || return 1; with_state_transaction cert-delete _cert_delete "$@"; }

acme_update() {
  [[ -x "$SBM_ACME_BIN" ]] || die "acme.sh 尚未安装。"
  local email
  email=$(jq -r '.settings.acme_email // ""' "$SBM_STATE")
  with_lock acme_install "$email" 1
  log_ok "acme.sh 已更新到项目审核版本 $SBM_ACME_VERSION。"
}

cert_list() {
  local cert domain path end epoch now days subject
  printf '%-30s %-12s %-24s %s\n' '域名' '剩余天数' '到期时间' '状态'
  while IFS= read -r cert; do
    domain=$(jq -r '.domain' <<<"$cert"); path=$(jq -r '.certificate_path' <<<"$cert")
    if [[ ! -s "$path" ]]; then printf '%-30s %-12s %-24s %s\n' "$domain" '-' '-' '文件缺失'; continue; fi
    end=$(openssl x509 -in "$path" -noout -enddate 2>/dev/null | cut -d= -f2-)
    days=$(x509_days_remaining "$path" 2>/dev/null || echo -1)
    subject='正常'; (( days < 20 )) && subject='即将过期'; (( days < 7 )) && subject='危险'
    printf '%-30s %-12s %-24s %s\n' "$domain" "$days" "$end" "$subject"
  done < <(jq -c '.certificates[]?' "$SBM_STATE")
}

cert_list_json() {
  local cert domain path end days status
  {
    while IFS= read -r cert; do
      domain=$(jq -r '.domain' <<<"$cert"); path=$(jq -r '.certificate_path' <<<"$cert"); end=''; days=null; status='missing'
      if [[ -s "$path" ]]; then
        end=$(openssl x509 -in "$path" -noout -enddate 2>/dev/null | cut -d= -f2- || true)
        days=$(x509_days_remaining "$path" 2>/dev/null || printf 'null')
        if [[ "$days" != null ]]; then
          if (( days < 0 )); then status=expired; elif (( days < 7 )); then status=critical; elif (( days < 20 )); then status=expiring; else status=valid; fi
        else status=invalid; fi
      fi
      jq -cn --arg domain "$domain" --arg path "$path" --arg end "$end" --argjson days "$days" --arg status "$status" \
        '{domain:$domain,path:$path,expires_at:(if $end=="" then null else $end end),days_remaining:$days,status:$status}'
    done < <(jq -c '.certificates[]?' "$SBM_STATE")
  } | jq -s .
}

cert_inspect() {
  local domain=$1 path
  path="$SBM_CERTS/$domain/fullchain.pem"
  [[ -s "$path" ]] || die "证书不存在：$domain"
  openssl x509 -in "$path" -noout -subject -issuer -serial -dates -ext subjectAltName
}
