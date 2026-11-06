#!/usr/bin/env bash
# shellcheck shell=bash

SBM_CADDY_STORE="${SBM_CADDY_STORE:-$SBM_PREFIX/lib/sb-manager-web/managed}"

caddy_managed() {
  jq -e '.caddy.managed == true' "$SBM_STATE" >/dev/null
}

caddy_apt_managed() {
  jq -e '.caddy == null and .caddy_apt.enabled == true' "$SBM_STATE" >/dev/null
}

caddy_apt_run() {
  local action=$1 config
  config=$(jq -er '.caddy_apt.config' "$SBM_STATE") || return 1
  python3 "$SBM_LIB/libexec/caddy_apt.py" "$action" "$config" "$SBM_CACHE" "$SBM_VAR/updates/caddy-apt.log"
}

_caddy_apt_enroll() {
  local candidate config=/etc/caddy/Caddyfile
  caddy_managed && { log_error '请先解除 L4 分流并恢复标准 Caddy 软件包；此命令仅登记现有官方包。'; return 1; }
  website_mux_managed && { log_error '请先解除网站 443 分流。'; return 1; }
  python3 "$SBM_LIB/libexec/caddy_apt.py" verify "$config" "$SBM_CACHE" "$SBM_VAR/updates/caddy-apt.log" || return 1
  candidate=$(state_candidate) || return 1
  jq --arg config "$config" '.caddy_apt={enabled:true,config:$config}' "$SBM_STATE" >"$candidate" || return 1
  apply_candidate_state "$candidate" caddy-apt-enroll || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
  log_ok '官方 APT Caddy 已接入 sb update 和现有每日任务。'
}

caddy_version() {
  local version
  version=$("$1" version 2>/dev/null | awk 'NR==1 {print $1}') || return 1
  [[ "$version" =~ ^v2\.[0-9]+\.[0-9]+$ ]] || { log_error 'Caddy 程序缺少可识别的正式版本信息。'; return 1; }
  printf '%s\n' "${version#v}"
}

caddy_latest_version() {
  local metadata version
  metadata=$(curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 45 \
    https://api.github.com/repos/caddyserver/caddy/releases/latest) || return 1
  version=$(jq -er 'select(.draft==false and .prerelease==false)|.tag_name' <<<"$metadata") || return 1
  [[ "$version" =~ ^v2\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "${version#v}"
}

caddy_verify_modules() {
  local reference=$1 candidate=$2 expected actual module
  expected=$("$reference" list-modules 2>/dev/null | awk '$1 ~ /^[a-z0-9_]+[.]/ {print $1}') || return 1
  actual=$("$candidate" list-modules 2>/dev/null | awk '$1 ~ /^[a-z0-9_]+[.]/ {print $1}') || return 1
  grep -Fx caddy.listeners.layer4 <<<"$actual" >/dev/null || { log_error '候选 Caddy 缺少 L4 模块。'; return 1; }
  while IFS= read -r module; do
    [[ -z "$module" ]] || grep -Fx "$module" <<<"$actual" >/dev/null || {
      log_error "候选 Caddy 缺少现有模块：$module"; return 1;
    }
  done <<<"$expected"
}

caddy_store_binary() {
  local binary=$1 version digest directory target
  version=$(caddy_version "$binary") || return 1
  digest=$(sha256sum "$binary" | awk '{print $1}') || return 1
  directory="$SBM_CADDY_STORE/$version-${digest:0:16}"
  target="$directory/caddy"
  # install -d can leave intermediate directories subject to the caller's
  # restrictive umask. The service account must traverse this program tree.
  install -d -m 0755 "$SBM_PREFIX/lib/sb-manager-web" "$SBM_CADDY_STORE" "$directory" || return 1
  if [[ -e "$target" ]]; then
    [[ ! -L "$target" && "$(sha256sum "$target" | awk '{print $1}')" == "$digest" ]] || {
      log_error '已有 Caddy 版本目录摘要不匹配，请先检查文件。'; return 1;
    }
  else
    install -m 0755 "$binary" "$directory/.caddy-new" || return 1
    [[ "$(sha256sum "$directory/.caddy-new" | awk '{print $1}')" == "$digest" ]] || return 1
    mv -f "$directory/.caddy-new" "$target" || return 1
  fi
  if [[ $(init_system 2>/dev/null || true) == openrc ]]; then
    dependency_require_feature low-port || return 1
    setcap cap_net_bind_service=+ep "$target" || return 1
  fi
  printf '%s\n' "$target"
}

caddy_download_candidate() (
  local reference=$1 expected=${2:-} arch work output package version size
  local -a query=()
  website_mux_require_python || return 1
  arch=$(sb_arch) || return 1
  query=(--data-urlencode os=linux --data-urlencode "arch=$arch")
  if [[ "$arch" == armv7 ]]; then query=(--data-urlencode os=linux --data-urlencode arch=arm --data-urlencode arm=7); fi
  output=$("$reference" list-modules --packages --versions) || return 1
  # The publisher's custom-build service resolves current plugin versions.
  # Preserve every module identity and validate the actual website before use.
  while IFS= read -r package; do
    [[ "$package" =~ ^[A-Za-z0-9_./~-]+$ ]] || { log_error '现有 Caddy 模块来源无法安全识别。'; return 1; }
    query+=(--data-urlencode "p=$package")
  done < <({ awk 'NF==3 && $3 ~ /\// && $3!="github.com/caddyserver/caddy/v2" {print $3}' <<<"$output"; printf '%s\n' github.com/mholt/caddy-l4; } | sort -u)
  mkdir -p "$SBM_CACHE" || return 1
  work=$(mktemp -d "$SBM_CACHE/caddy-download.XXXXXX") || return 1
  trap 'rm -rf -- "$work"' EXIT
  log_info '从 Caddy 官方 HTTPS 构建接口下载带现有模块的候选程序；不在 VPS 编译。'
  if ! curl -fSL --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 600 --max-filesize 134217728 --retry 2 \
    --get "${query[@]}" https://caddyserver.com/api/download -o "$work/caddy"; then
    log_error '官方 Caddy 构建暂不可用，保留现有程序；可稍后重试。'; return 1
  fi
  size=$(stat -c %s "$work/caddy") || return 1
  (( size > 1024 && size <= 134217728 )) || { log_error 'Caddy 下载大小异常，未执行候选程序。'; return 1; }
  python3 "$SBM_LIB/libexec/caddy_package.py" elf "$work/caddy" "$arch" || return 1
  chmod 0755 "$work/caddy" || return 1
  version=$(caddy_version "$work/caddy") || return 1
  [[ -z "$expected" || "$version" == "$expected" ]] || { log_error "官方构建返回 $version，尚未提供预期的 $expected；保留现有程序。"; return 1; }
  version_ge "$version" "$(caddy_version "$reference")" || { log_error '候选 Caddy 版本较旧，拒绝自动降级。'; return 1; }
  caddy_verify_modules "$reference" "$work/caddy" || return 1
  caddy_store_binary "$work/caddy"
)

caddy_context() {
  if caddy_managed; then
    jq -c '.caddy' "$SBM_STATE"
  elif website_mux_managed && [[ $(jq -r '.nginx_stream.website.server' "$SBM_STATE") == caddy ]]; then
    jq -c '.nginx_stream.website | {binary:.binary,config:.config,init:.init,managed:false}' "$SBM_STATE"
  else
    log_error '请先通过 sb mux setup 接入现有 Caddy 网站。'; return 1
  fi
}

caddy_validate_candidate() {
  local binary=$1 config=$2 log="$SBM_RUN/caddy-candidate.log"
  "$binary" validate --adapter caddyfile --config "$config" >"$log" 2>&1 || {
    log_error "候选 Caddy 无法加载网站配置，未切换；日志：$log"; return 1;
  }
}

caddy_service_can_execute() {
  local binary=$1 backend=$2 user
  [[ "$backend" == systemd ]] || return 0
  user=$(systemctl show caddy.service -p User --value) || return 1
  user=${user:-root}
  if command_exists runuser; then
    runuser -u "$user" -- "$binary" version >"$SBM_RUN/caddy-exec.log" 2>&1
  elif command_exists su; then
    # The caller has already restricted binary paths to safe absolute names.
    su -s /bin/sh -c "$binary version" "$user" >"$SBM_RUN/caddy-exec.log" 2>&1
  else
    log_error '缺少 runuser/su，无法确认 Caddy 服务用户能够执行候选程序。'; return 1
  fi
}

caddy_package_restore() {
  local snapshot=$1
  [[ -f "$snapshot/caddy-package/package.json" ]] || return 0
  python3 "$SBM_LIB/libexec/caddy_package.py" rollback "$snapshot/caddy-package"
}

caddy_restart_restored() {
  [[ -f "$1/caddy-package/package.json" ]] || return 0
  service_reload_manager && service_restart caddy.service && service_wait_active caddy.service 20 2
}

caddy_runtime_reconcile() {
  # Detaching the website restores its original OpenRC script. The separately
  # managed Caddy lifecycle still owns binary selection after that restoration.
  caddy_managed || return 0
  [[ $(jq -r '.caddy.init' "$SBM_STATE") == openrc ]] || return 0
  local file binary temporary
  file=$(jq -r '.caddy.service_file' "$SBM_STATE"); binary=$(jq -r '.caddy.binary' "$SBM_STATE")
  grep -Fx "command=\"$binary\"" "$file" >/dev/null && return 0
  [[ $(grep -c '^command=' "$file") == 1 ]] || return 1
  temporary=$(mktemp "$SBM_RUN/caddy-openrc.XXXXXX") || return 1
  awk -v binary="$binary" '/^command=/ {print "command=\"" binary "\""; next} {print}' "$file" >"$temporary" || return 1
  safe_install_file "$temporary" "$file" 0755 || { rm -f "$temporary"; return 1; }
  rm -f "$temporary"
}

caddy_verify_running() {
  local binary=$1 expected=$2 backend pid actual
  backend=$(init_system) || return 1
  service_wait_active caddy.service 20 2 || return 1
  if [[ "$backend" == systemd ]]; then
    pid=$(systemctl show caddy.service -p MainPID --value) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    actual=$(sha256sum "/proc/$pid/exe" | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]] || { log_error '运行中的 Caddy 与候选程序摘要不一致。'; return 1; }
  fi
  [[ "$(sha256sum "$binary" | awk '{print $1}')" == "$expected" ]]
}

_caddy_switch() {
  local target=$1 mode=$2 context old managed config backend canonical method service_file version digest previous candidate plan pid running
  context=$(caddy_context) || return 1
  old=$(jq -r '.target // .binary' <<<"$context")
  managed=$(jq -r '.managed' <<<"$context")
  config=$(jq -r '.config' <<<"$context"); backend=$(jq -r '.init' <<<"$context")
  [[ "$backend" == "$(init_system)" ]] || { log_error 'Caddy 服务管理器与记录不一致。'; return 1; }
  service_active caddy.service || { log_error '请先恢复 Caddy 服务运行，再维护程序。'; return 1; }
  if [[ "$backend" == systemd ]]; then
    pid=$(systemctl show caddy.service -p MainPID --value) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    python3 "$SBM_LIB/libexec/caddy_package.py" command "$pid" "$config" || return 1
    [[ "$(sha256sum "/proc/$pid/exe" | awk '{print $1}')" == "$(sha256sum "$old" | awk '{print $1}')" ]] || {
      log_error '运行中的 Caddy 与记录的程序不一致，请先核对服务。'; return 1;
    }
  fi
  if [[ "$managed" == true ]]; then
    [[ "$(sha256sum "$old" | awk '{print $1}')" == "$(jq -r '.sha256' <<<"$context")" ]] || {
      log_error '现有 Caddy 程序被外部替换，请先核对版本；请使用 sb caddy update 管理升级。'; return 1;
    }
  fi
  [[ "$target" =~ ^/[A-Za-z0-9_./+-]+$ && "$config" =~ ^/[A-Za-z0-9_./+-]+$ ]] || return 1
  if [[ "$mode" == rollback ]]; then
    "$target" list-modules | grep -Fx caddy.listeners.layer4 >/dev/null || return 1
  else caddy_verify_modules "$old" "$target" || return 1; fi
  caddy_service_can_execute "$target" "$backend" || {
    log_error "Caddy 服务用户无法执行候选程序，未切换；日志：$SBM_RUN/caddy-exec.log"; return 1;
  }
  caddy_validate_candidate "$target" "$config" || return 1
  version=$(caddy_version "$target") || return 1
  digest=$(sha256sum "$target" | awk '{print $1}') || return 1
  if [[ "$managed" == true ]]; then
    canonical=$(jq -r '.binary' <<<"$context"); method=$(jq -r '.method' <<<"$context")
    service_file=$(jq -r '.service_file' <<<"$context")
    previous=$(jq -c '{target,version,sha256}' <<<"$context")
  else
    method=standalone; canonical="$SBM_BIN_DIR/caddy-managed"
    if [[ $(dependency_distro) == debian ]] && command_exists dpkg-divert && command_exists update-alternatives \
      && [[ $(dpkg-query -W '-f=${Status}' caddy 2>/dev/null || true) == 'install ok installed' ]]; then
      method=debian-alternatives; canonical=/usr/bin/caddy
    fi
    if [[ "$backend" == systemd ]]; then service_file="$SBM_SYSTEMD_DIR/caddy.service.d/90-sb-manager-caddy.conf"
    else service_file="$SBM_OPENRC_DIR/caddy"; fi
    previous=null
  fi
  plan=$(mktemp "$SBM_RUN/caddy-plan.XXXXXX") || return 1
  jq -n --arg method "$method" --arg target "$target" --arg binary "$canonical" --arg old "$old" \
    --arg digest "$digest" --arg config "$config" --arg init "$backend" --arg service "$service_file" \
    --arg website "$SBM_WEBSITE_MUX_DIR" --argjson managed "$managed" \
    '{method:$method,target:$target,binary:$binary,old_target:$old,sha256:$digest,config:$config,init:$init,
      service_file:$service,website_directory:$website,previously_managed:$managed}' >"$plan" || return 1
  if ! python3 "$SBM_LIB/libexec/caddy_package.py" install "$plan" "${SBM_OPERATION_SNAPSHOT:?}/caddy-package"; then
    rm -f "$plan"; return 1
  fi
  rm -f "$plan"
  candidate=$(state_candidate) || return 1
  jq --arg binary "$canonical" --arg target "$target" --arg config "$config" --arg init "$backend" \
    --arg method "$method" --arg service "$service_file" --arg version "$version" --arg digest "$digest" \
    --argjson previous "$previous" '
    .caddy={managed:true,binary:$binary,target:$target,config:$config,init:$init,method:$method,
      service_file:$service,version:$version,sha256:$digest,previous:$previous}
    | if .nginx_stream.website.server=="caddy" and .nginx_stream.website.managed then
        .nginx_stream.website.binary=$binary else . end' "$SBM_STATE" >"$candidate" || return 1
  apply_candidate_state "$candidate" "caddy-$mode" || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
  service_reload_manager || return 1
  running=''
  if [[ "$backend" == systemd ]]; then
    pid=$(systemctl show caddy.service -p MainPID --value) || return 1
    running=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  fi
  [[ "$running" == "$target" ]] || service_restart caddy.service || return 1
  caddy_verify_running "$canonical" "$digest" || return 1
  log_ok "Caddy $version 已切换并确认运行；维护方式：$method。"
}

_caddy_manage() {
  local context reference target
  if caddy_managed; then log_info 'Caddy 已接入程序维护，可运行 sb caddy update 升级。'; return 0; fi
  context=$(caddy_context) || return 1
  reference=$(jq -r '.binary' <<<"$context")
  target=$(caddy_store_binary "$reference") || return 1
  _caddy_switch "$target" manage
}

caddy_manage() {
  [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die 'Caddy 接入不接受 --dry-run。'
  website_mux_require_python || return 1
  with_state_transaction caddy-manage _caddy_manage
}

_caddy_update() {
  local context latest current target digest
  if caddy_apt_managed; then caddy_apt_run update; return "$?"; fi
  caddy_managed || { log_error '请先运行 sb caddy manage。'; return 1; }
  context=$(caddy_context) || return 1
  [[ "$(sha256sum "$(jq -r '.target' <<<"$context")" | awk '{print $1}')" == "$(jq -r '.sha256' <<<"$context")" ]] || {
    log_error '受管 Caddy 程序摘要已改变，请先核对手工修改。'; return 1;
  }
  latest=$(caddy_latest_version) || { log_error '无法取得官方 Caddy 版本，保留当前服务。'; return 1; }
  current=$(jq -r '.version' <<<"$context")
  if [[ "$current" != "$latest" ]] && version_ge "$current" "$latest"; then
    log_error "当前 Caddy $current 高于官方最新正式版 $latest，保留当前程序，不自动降级。"; return 1
  fi
  # Plugins and build dependencies can change without a Caddy core release.
  # An explicit update must refresh the publisher's build in that case too.
  if [[ "$current" == "$latest" ]]; then
    log_info "Caddy 主版本已是 $current，继续检查官方插件构建。"
  fi
  target=$(caddy_download_candidate "$(jq -r '.target' <<<"$context")" "$latest") || return 1
  digest=$(sha256sum "$target" | awk '{print $1}') || return 1
  if [[ "$digest" == "$(jq -r '.sha256' <<<"$context")" ]]; then
    caddy_verify_running "$target" "$digest" || return 1
    log_ok '官方构建与当前运行程序一致，无需切换或重启。'; return 0
  fi
  # Download failures and unchanged builds must not enter a rollback that
  # would restart otherwise healthy services during the daily update.
  _state_transaction_run caddy-update _caddy_switch "$target" update
}

_caddy_rollback() {
  local target digest
  caddy_managed || { log_error 'Caddy 尚未接入程序维护。'; return 1; }
  target=$(jq -r '.caddy.previous.target // empty' "$SBM_STATE")
  digest=$(jq -r '.caddy.previous.sha256 // empty' "$SBM_STATE")
  [[ -n "$target" && -x "$target" && "$(sha256sum "$target" | awk '{print $1}')" == "$digest" ]] || {
    log_error '没有可用且摘要匹配的上一版 Caddy。'; return 1;
  }
  _caddy_switch "$target" rollback
}

caddy_status() {
  if caddy_apt_managed; then caddy_apt_run check; return "$?"; fi
  local context binary version pid running='未运行或不可读取' official='未通过 Debian 软件包接入'
  context=$(caddy_context) || return 1
  binary=$(jq -r '.binary' <<<"$context")
  version=$(caddy_version "$binary") || return 1
  if [[ -x /usr/bin/caddy.default ]]; then official=$(caddy_version /usr/bin/caddy.default || printf '未知')
  elif [[ -x /usr/bin/caddy ]]; then official=$(caddy_version /usr/bin/caddy || printf '未知'); fi
  if [[ $(init_system 2>/dev/null || true) == systemd ]]; then
    pid=$(systemctl show caddy.service -p MainPID --value 2>/dev/null || true)
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then running=$(caddy_version "/proc/$pid/exe" 2>/dev/null || printf '未知'); fi
  elif service_active caddy.service; then running='OpenRC 服务运行中'; fi
  printf 'Caddy 命令入口：%s\n定制程序版本：%s\n实际服务版本：%s\n官方包程序版本：%s\n' "$binary" "$version" "$running" "$official"
  printf '程序维护：%s\n' "$(jq -r 'if .managed then .method else "尚未接入；运行 sb caddy manage" end' <<<"$context")"
  printf '可回滚版本：%s\n' "$(jq -r '.previous.version // "无"' <<<"$context")"
  printf '官方源继续管理官方包；受管程序随 sb update 和每日更新维护。\n'
}

caddy_cli() {
  local action=${1:-status}
  (($# == 0)) || shift
  case "$action" in
    status) (($# == 0)) || usage_die '用法：sb caddy status'; caddy_status;;
    apt)
      (($# == 0)) || usage_die '用法：sb caddy apt'
      [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die 'APT 接入不接受 --dry-run。'
      with_state_transaction caddy-apt-enroll _caddy_apt_enroll;;
    manage) (($# == 0)) || usage_die '用法：sb caddy manage'; caddy_manage;;
    update)
      if [[ ${1:-} == --check ]]; then
        (($# == 1)) || usage_die '用法：sb caddy update [--check]'
        if caddy_apt_managed; then caddy_apt_run check; return "$?"; fi
        caddy_status
        local latest
        latest=$(caddy_latest_version) || return 1
        printf '官方最新正式版本：%s\n' "$latest"
        printf '此查询仅比较 Caddy 主版本；运行 sb update 获取当前官方插件构建。\n'
      else
        (($# == 0)) || usage_die '用法：sb caddy update [--check]'
        [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die '请使用 sb caddy update --check 查看更新。'
        with_lock _caddy_update
      fi;;
    rollback)
      (($# == 0)) || usage_die '用法：sb caddy rollback'
      [[ ${SBM_DRY_RUN:-0} != 1 ]] || usage_die 'Caddy 回滚不接受 --dry-run。'
      with_state_transaction caddy-rollback _caddy_rollback;;
    *) usage_die '用法：sb caddy status|apt|manage|update [--check]|rollback';;
  esac
}
