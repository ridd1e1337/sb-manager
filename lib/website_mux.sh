#!/usr/bin/env bash
# shellcheck shell=bash

SBM_WEBSITE_MUX_DIR="${SBM_WEBSITE_MUX_DIR:-$SBM_VAR/website-mux}"
SBM_WEBSITE_L4_COMMIT="${SBM_WEBSITE_L4_COMMIT:-96e1a6bf063c206c3bd09ca6dc4a0484a158d83f}"
SBM_WEBSITE_XCADDY_VERSION="${SBM_WEBSITE_XCADDY_VERSION:-v0.4.7}"
SBM_WEBSITE_GO_VERSION="${SBM_WEBSITE_GO_VERSION:-1.26.10}"

website_mux_managed() {
  jq -e '.nginx_stream.website.managed == true' "${1:-$SBM_STATE}" >/dev/null
}

website_mux_require_python() {
  command_exists python3 && return 0
  dependency_require_feature subscription || return 1
  command_exists python3 || { log_error '网站配置编辑需要 python3。'; return 1; }
}

website_mux_helper() {
  python3 "$SBM_LIB/libexec/website_mux.py" "$1" "$2" "$SBM_WEBSITE_MUX_DIR" "$3"
}

website_mux_choose_port() {
  local state=$1 skip=${2:-0} p
  for ((p=18000; p<20000; p++)); do
    [[ "$p" != "$skip" ]] || continue
    mux_reserved_port "$state" "$p" && continue
    node_port_in_state tcp "$p" "$state" && continue
    host_port_in_use tcp "$p" && continue
    printf '%s\n' "$p"; return 0
  done
  log_error '没有可用的网站本机后端端口。'; return 1
}

website_mux_sync_routes() {
  local candidate=$1 node id sni port tmp routes='[]' old
  website_mux_managed "$candidate" || return 0
  while IFS= read -r node; do
    nginx_stream_supported_node "$node" || continue
    id=$(jq -r '.id' <<<"$node"); sni=$(nginx_stream_node_sni "$node") || return 1
    validate_domain "$sni" || { log_error "无效 SNI：$id"; return 1; }
    old=$(nginx_stream_route_for_node "$candidate" "$id") || return 1
    [[ -n "$old" ]] || old='{}'
    port=$(jq -r '.backend_port // empty' <<<"$old") || return 1
    if [[ -z "$port" ]]; then
      port=$(nginx_stream_choose_backend_port "$candidate") || return 1
      tmp=$(state_candidate) || return 1
      jq --arg id "$id" --arg sni "${sni,,}" --argjson port "$port" '.nginx_stream.routes += [{node_id:$id,sni:$sni,backend_port:$port}]' "$candidate" >"$tmp" || return 1
      mv -f "$tmp" "$candidate" || return 1
    fi
    routes=$(jq --arg id "$id" --arg sni "${sni,,}" --argjson port "$port" '. + [{node_id:$id,sni:$sni,backend_port:$port}]' <<<"$routes") || return 1
  done < <(jq -c '.nodes[] | select(.enabled)' "$candidate")
  tmp=$(state_candidate) || return 1
  jq --argjson routes "$routes" '.nginx_stream.routes=$routes | .nginx_stream.enabled=true' "$candidate" >"$tmp" || return 1
  mv -f "$tmp" "$candidate"
}

website_mux_compile_caddy() {
  local binary=$1 version output target go_bin arch metadata digest work plugin plugins module_ids module_id built_modules
  local -a build_args=()
  if "$binary" list-modules 2>/dev/null | grep -Fx caddy.listeners.layer4 >/dev/null; then printf '%s\n' "$binary"; return 0; fi
  output=$("$binary" list-modules --packages --versions) || return 1
  plugins=$(awk 'NF==3 && $3 ~ /\// && $3!="github.com/caddyserver/caddy/v2" {print $3 "@" $2}' <<<"$output" | sort -u) || return 1
  module_ids=$(awk 'NF==3 && $3 ~ /\// {print $1}' <<<"$output") || return 1
  while IFS= read -r plugin; do
    [[ -n "$plugin" ]] || continue
    [[ "$plugin" =~ ^[A-Za-z0-9_./-]+@v[0-9]+\.[0-9]+\.[0-9]+[-.+A-Za-z0-9]*$ ]] || { log_error '现有 Caddy 模块没有可复现的版本，无法自动重建。'; return 1; }
    build_args+=(--with "$plugin")
  done <<<"$plugins"
  version=$("$binary" version | awk '{print $1}') || return 1
  [[ "$version" =~ ^v2\.[0-9]+\.[0-9]+$ ]] || { log_error '无法识别 Caddy 2 正式版本，拒绝替换。'; return 1; }
  version_ge "${version#v}" 2.11.7 || version=v2.11.8
  digest=$(printf '%s' "$plugins" | sha256sum | cut -c1-12) || return 1
  target="$SBM_PREFIX/lib/sb-manager-web/caddy-$version-${SBM_WEBSITE_L4_COMMIT:0:12}-$digest"
  if [[ -x "$target" ]] && "$target" list-modules 2>/dev/null | grep -Fx caddy.listeners.layer4 >/dev/null; then printf '%s\n' "$target"; return; fi
  core_check_free_space "$SBM_CACHE" 1800000000 || return 1
  work=$(mktemp -d "$SBM_CACHE/caddy-build.XXXXXX") || return 1
  chmod 0700 "$work"
  go_bin=$(command -v go || true)
  if [[ -z "$go_bin" ]] || ! version_ge "$("$go_bin" version | sed -n 's/.*go\([0-9][0-9.]*\).*/\1/p')" 1.21.0; then
    arch=$(sb_arch) || return 1
    [[ "$arch" != armv7 ]] || arch=armv6l
    metadata=$(curl -fsSL --connect-timeout 10 --max-time 60 'https://go.dev/dl/?mode=json&include=all') || return 1
    digest=$(jq -er --arg version "go$SBM_WEBSITE_GO_VERSION" --arg arch "$arch" '.[] | select(.version==$version) | .files[] | select(.os=="linux" and .arch==$arch and .kind=="archive") | .sha256' <<<"$metadata") || return 1
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
    download_file_with_retries "https://go.dev/dl/go${SBM_WEBSITE_GO_VERSION}.linux-${arch}.tar.gz" "$work/go.tar.gz" Go 3 || return 1
    verify_asset_digest "$work/go.tar.gz" "sha256:$digest" || { log_error 'Go 下载摘要不匹配。'; return 1; }
    tar -xzf "$work/go.tar.gz" -C "$work" || return 1
    go_bin="$work/go/bin/go"
  fi
  log_info "编译 Caddy $version + L4，可能需要数分钟；日志：$work/build.log"
  if ! (cd "$work" && GOTOOLCHAIN=auto GOSUMDB=sum.golang.org GOPROXY=https://proxy.golang.org \
    GOPRIVATE='' GONOSUMDB='' GOMODCACHE="$work/go-mod" GOCACHE="$work/go-cache" GOPATH="$work/go-path" \
    CGO_ENABLED=0 GOMAXPROCS=1 GOMEMLIMIT=256MiB GOFLAGS=-p=1 \
    "$go_bin" run "github.com/caddyserver/xcaddy/cmd/xcaddy@$SBM_WEBSITE_XCADDY_VERSION" build "$version" \
    --with "github.com/mholt/caddy-l4@$SBM_WEBSITE_L4_COMMIT" "${build_args[@]}" --output "$work/caddy" >"$work/build.log" 2>&1); then
    log_error "Caddy 编译失败，原网站未切换；请查看 $work/build.log。"; return 1
  fi
  "$work/caddy" list-modules | grep -Fx caddy.listeners.layer4 >/dev/null || return 1
  [[ $("$work/caddy" version | awk '{print $1}') == "$version" ]] || { log_error '编译后的 Caddy 版本与目标不一致。'; return 1; }
  built_modules=$("$work/caddy" list-modules --packages --versions) || return 1
  while IFS= read -r module_id; do
    [[ -n "$module_id" ]] || continue
    awk '{print $1}' <<<"$built_modules" | grep -Fx "$module_id" >/dev/null || { log_error "重建的 Caddy 缺少原有模块：$module_id"; return 1; }
  done <<<"$module_ids"
  install -d -m 0755 "$SBM_PREFIX/lib/sb-manager-web" || return 1
  install -m 0755 "$work/caddy" "$target" || return 1
  mkdir -p "$SBM_WEBSITE_MUX_DIR" || return 1
  install -m 0600 "$work/build.log" "$SBM_WEBSITE_MUX_DIR/build.log" || return 1
  rm -rf -- "$work" || return 1
  printf '%s\n' "$target"
}

website_mux_build_caddy() {
  local binary=$1
  if "$binary" list-modules 2>/dev/null | grep -Fx caddy.listeners.layer4 >/dev/null; then
    printf '%s\n' "$binary"; return 0
  fi
  if [[ ${SBM_CADDY_BUILD_LOCAL:-0} == 1 ]]; then website_mux_compile_caddy "$binary"
  else caddy_download_candidate "$binary"; fi
}

_website_mux_setup() {
  local server=${1:-auto} config=${2:-} binary=${3:-} candidate frontend=0 owner init override='' original_binary website_port relay_port module='' active_command
  if jq -e '.caddy_apt != null' "$SBM_STATE" >/dev/null; then
    log_error '已选择官方 APT Caddy；标准包不提供 L4，请保持节点使用独立端口。'; return 1
  fi
  website_mux_require_python || return 1
  [[ ${SBM_SKIP_INIT:-0} != 1 ]] || { log_error '网站自动接入需要真实 systemd/OpenRC。'; return 1; }
  if website_mux_managed; then
    if [[ ( "$server" != auto && "$server" != "$(jq -r '.nginx_stream.website.server' "$SBM_STATE")" ) \
       || ( -n "$config" && "$config" != "$(jq -r '.nginx_stream.website.config' "$SBM_STATE")" ) \
       || ( -n "$binary" && "$binary" != "$(jq -r '.nginx_stream.website.binary' "$SBM_STATE")" ) ]]; then
      log_error '网站接入设置已固定，请先 sb mux detach 再切换程序或路径。'; return 1
    fi
    log_info '网站入口已接入，正在同步全部启用的 TCP/TLS 节点。'
    candidate=$(state_candidate) || return 1
    cp "$SBM_STATE" "$candidate" || return 1
    apply_candidate_state "$candidate" website-sync || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    return 0
  fi
  dependency_require_feature probe || return 1
  owner=$(ss -H -ltnp 'sport = :443' 2>/dev/null) || return 1
  if [[ "$server" == auto ]]; then
    if [[ "$owner" == *'"caddy"'* && "$owner" != *'"nginx"'* ]]; then server=caddy
    elif [[ "$owner" == *'"nginx"'* && "$owner" != *'"caddy"'* ]]; then server=nginx
    else log_error '443/TCP 不由单一 Nginx/Caddy 监听，无法自动接入。'; return 1; fi
  fi
  case "$server" in nginx|caddy) ;; *) usage_die '网站程序只能是 auto、nginx 或 caddy。';; esac
  [[ "$owner" == *\""$server"\"* ]] && service_active "$server.service" || { log_error "$server 未通过系统服务监听 443。"; return 1; }
  init=$(init_system) || return 1
  if [[ "$init" == systemd ]]; then
    frontend=$(systemctl show "$server.service" -p MainPID --value) || return 1
    original_binary=$(readlink -f "/proc/$frontend/exe") || return 1
  else
    original_binary=$(sed -n 's/^command=//p' "$SBM_OPENRC_DIR/$server") || return 1
    original_binary=${original_binary//\"/}; original_binary=${original_binary//\'/}
    [[ -x "$original_binary" ]] || original_binary=$(command -v "$server") || return 1
  fi
  if [[ -z "$binary" ]]; then
    binary=$original_binary
  elif [[ $(readlink -f "$binary") != "$(readlink -f "$original_binary")" ]]; then
    log_error '--binary 必须是当前网站服务实际使用的程序。'; return 1
  fi
  [[ -x "$binary" && "$binary" =~ ^/[A-Za-z0-9_./+-]+$ ]] || { log_error '网站二进制路径无效。'; return 1; }
  original_binary=$binary
  if [[ -z "$config" ]]; then
    if [[ "$server" == nginx ]]; then config=$("$binary" -V 2>&1 | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p')
    else config=/etc/caddy/Caddyfile; fi
  fi
  [[ -f "$config" && "$config" =~ ^/[A-Za-z0-9_./+-]+$ ]] || { log_error '请使用 --config 指定实际网站配置文件。'; return 1; }
  if [[ "$init" == systemd ]]; then
    active_command=$(tr '\0' '\n' <"/proc/$frontend/cmdline") || return 1
    if [[ "$server" == caddy ]]; then
      grep -Fxq -- "$config" <<<"$active_command" || { log_error '运行中的 Caddy 使用其他配置；请指定实际 --config。'; return 1; }
      if grep -Eq '^--(resume|watch|envfile|pingback|pidfile)' <<<"$active_command"; then
        log_error 'Caddy 使用自定义启动参数，无法自动替换服务命令。'; return 1
      fi
    elif [[ "$active_command" == *' -c '* && "$active_command" != *" -c $config"* ]]; then
      log_error 'Nginx 使用自定义配置，请指定实际 --config。'; return 1
    fi
  fi
  website_port=$(website_mux_choose_port "$SBM_STATE") || return 1
  relay_port=$(website_mux_choose_port "$SBM_STATE" "$website_port") || return 1
  if [[ "$server" == caddy ]]; then
    binary=$(website_mux_build_caddy "$binary") || return 1
    if [[ "$binary" != "$original_binary" ]]; then
      if [[ "$init" == systemd ]]; then override="$SBM_SYSTEMD_DIR/caddy.service.d/70-sb-manager-l4.conf"
      else
        grep -Eq '(^|[[:space:]])command=' "$SBM_OPENRC_DIR/caddy" || { log_error '非标准 Caddy OpenRC 服务，无法自动配置启动命令。'; return 1; }
        override="$SBM_OPENRC_DIR/caddy"
      fi
    fi
  else
    if "$binary" -V 2>&1 | grep -q -- '--with-stream=dynamic'; then
      if ! module=$(nginx_stream_module_path); then
        case "$(dependency_distro)" in
          debian) dependency_install_packages libnginx-mod-stream || return 1;;
          alpine) dependency_install_packages nginx-mod-stream || return 1;;
          *) log_error '请先安装与现有 Nginx 匹配的 stream 模块。'; return 1;;
        esac
        module=$(nginx_stream_module_path) || return 1
      fi
    fi
  fi
  candidate=$(state_candidate) || return 1
  jq --arg server "$server" --arg binary "$binary" --arg original "$original_binary" --arg config "$config" \
    --arg init "$init" --arg override "$override" --arg module "$module" --argjson website_port "$website_port" --argjson relay_port "$relay_port" '
    .nginx_stream.enabled=true | .nginx_stream.port=443
    | .nginx_stream.backend=(if $server=="nginx" then "nginx-site" else "caddy" end)
    | .nginx_stream.website={managed:true,server:$server,binary:$binary,original_binary:$original,config:$config,
        init:$init,service_override:$override,stream_module:$module,website_port:$website_port,relay_port:$relay_port}
  ' "$SBM_STATE" >"$candidate" || return 1
  apply_candidate_state "$candidate" website-setup || return 1
  rm -f "$candidate"
  log_ok '网站与全部启用的 TCP/TLS 节点已共用 443；后续节点增删、域名修改和启停将自动同步。'
}

website_mux_setup() {
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '网站接入不支持 --dry-run。'
  with_state_transaction website-setup _website_mux_setup "$@" || return 1
  if [[ $(jq -r '.nginx_stream.website.server' "$SBM_STATE") == caddy ]] && ! caddy_managed; then
    caddy_manage || { log_warn '网站共用 443 已保留；Caddy 程序维护接入未完成，可运行 sb caddy manage 重试。'; return 1; }
  fi
}

website_mux_prepare() {
  local candidate=$1 snapshot=$2
  if website_mux_managed "$candidate"; then
    website_mux_require_python || return 1
    mkdir -p "$SBM_WEBSITE_MUX_DIR" || return 1
    chmod 0700 "$SBM_WEBSITE_MUX_DIR"
    website_mux_helper prepare "$candidate" "$snapshot" || return 1
  elif website_mux_managed "$SBM_STATE"; then
    website_mux_helper detach "$candidate" "$snapshot" || return 1
  fi
}

website_mux_reload() {
  local server=$1 restart=${2:-false}
  if [[ "$server" == caddy ]]; then caddy_runtime_reconcile || return 1; fi
  service_reload_manager || return 1
  if [[ "$restart" == true ]]; then service_restart "$server.service" || return 1
  elif [[ $(init_system) == systemd ]]; then systemctl reload "$server.service" || return 1
  else rc-service "$server" reload || return 1; fi
  service_wait_active "$server.service" 20 2
}

website_mux_reconcile() {
  local manifest="$SBM_WEBSITE_MUX_DIR/manifest.json" server restart changed tmp
  [[ -s "$manifest" ]] || return 0
  server=$(jq -r '.server // empty' "$manifest") || return 1
  [[ -n "$server" ]] || return 0
  changed=$(jq -r '.changed // false' "$manifest") || return 1
  if [[ "$changed" == true ]]; then
    restart=$(jq -r '.restart // false' "$manifest") || return 1
    website_mux_reload "$server" "$restart" || return 1
  fi
  tmp=$(mktemp "$SBM_WEBSITE_MUX_DIR/.manifest.XXXXXX") || return 1
  jq 'if .detached then {} else .changed=false | .restart=false end' "$manifest" >"$tmp" || return 1
  chmod 0600 "$tmp" && mv -f "$tmp" "$manifest"
}

website_mux_rollback() {
  local snapshot=$1 info="$1/website-files/frontend.json" server
  [[ -s "$snapshot/website-files/files.json" ]] || return 0
  server=$(jq -r '.server' "$info") || return 1
  website_mux_helper rollback "$SBM_STATE" "$snapshot" || return 1
  website_mux_reload "$server" true
}

_website_mux_detach() {
  local candidate prior
  website_mux_managed || { log_error '尚未启用网站自动接入。'; return 1; }
  prior=$(jq -ec '.prior_mux' "$SBM_WEBSITE_MUX_DIR/manifest.json") || return 1
  candidate=$(state_candidate) || return 1
  jq --argjson prior "$prior" '.nginx_stream.website as $web | .nginx_stream=$prior
    | .nginx_stream.website=($web + {managed:false})' "$SBM_STATE" >"$candidate" || return 1
  apply_candidate_state "$candidate" website-detach || return 1
  rm -f "$candidate"
  log_ok '已恢复网站接入前的配置和复用方式；未参与原分流的节点使用独立端口。'
}

website_mux_detach() {
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '网站恢复不支持 --dry-run。'
  with_state_transaction website-detach _website_mux_detach
}
