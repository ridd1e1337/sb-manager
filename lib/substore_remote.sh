#!/usr/bin/env bash
# shellcheck shell=bash

# Push this server's nodes into an existing central Sub-Store instead of
# running one Sub-Store per VPS. The nodes become a "local" subscription
# (source) there; it is created once (optionally tagged, e.g. 主节点库) and
# afterwards only its content is updated, so the display name, tags and
# processing configured on the central side are kept. The backend URL holds
# Sub-Store's secret path, so it lives in a 0600 secret, never in state or argv.

SBM_SUBSTORE_REMOTE_SECRET="${SBM_SUBSTORE_REMOTE_SECRET:-$SBM_SECRETS/substore-remote.json}"
SBM_SUBSTORE_REMOTE_HASH="${SBM_SUBSTORE_REMOTE_HASH:-$SBM_VAR/substore-remote.hash}"

substore_remote_default_name() {
  local name
  name=$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._\n-' '-' | cut -c1-48) || true
  validate_node_id "$name" && printf '%s\n' "$name" || printf 'sb-manager\n'
}
substore_remote_configured() { [[ -s "$SBM_SUBSTORE_REMOTE_SECRET" ]]; }

# substore_remote_api METHOD PATH [BODY_FILE] → response body
substore_remote_api() {
  local method=$1 path=$2 body=${3:-} base
  base=$(jq -r '.url' "$SBM_SUBSTORE_REMOTE_SECRET") || return 1
  local -a args=(--fail --silent --show-error --connect-timeout 10 --max-time 30 -X "$method" -H 'Accept: application/json')
  [[ -z "$body" ]] || args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  # The URL (with the secret path) goes through a curl config on stdin.
  jq -rn --arg url "${base%/}$path" '"url = " + ($url|tojson)' | curl "${args[@]}" --config -
}

_substore_remote_links() {
  local out=$1
  export_substore_links "$out" >/dev/null 2>&1 || return 1
  [[ -s "$out" ]] || { log_error '本机没有可推送的节点链接（没有启用的节点？）。'; return 1; }
}

# Cheap fingerprint of everything a share link depends on (node definitions,
# public-entry settings and credential files). Exporting the links costs a few
# jq calls per user, so the export only runs when this changes.
substore_remote_fingerprint() {
  {
    jq -c 'del(.created_at, .updated_at, .health, .notifications, .api, .realm, .routing, .node_templates, .manager_version, .certificates)' "$SBM_STATE"
    find "$SBM_SECRETS/users" "$SBM_SECRETS/nodes" -type f -printf '%P %T@ %s\n' 2>/dev/null | LC_ALL=C sort
  } | sha256sum | awk '{print $1}'
}

# Push the current links; skipped when nothing changed since the last
# successful push unless FORCE=1.
substore_remote_push() {
  local force=${1:-0} cfg name display tags links fp body response
  substore_remote_configured || { log_error '尚未连接中心 Sub-Store；先运行 sb substore remote set URL。'; return 1; }
  cfg=$(jq -c '{name, display:(.display // .name), tags:(.tags // [])}' "$SBM_SUBSTORE_REMOTE_SECRET") || return 1
  name=$(jq -r '.name' <<<"$cfg"); display=$(jq -r '.display' <<<"$cfg"); tags=$(jq -c '.tags' <<<"$cfg")
  fp=$(substore_remote_fingerprint) || return 1
  if [[ "$force" != 1 && -r "$SBM_SUBSTORE_REMOTE_HASH" && "$(<"$SBM_SUBSTORE_REMOTE_HASH")" == "$fp $name" ]]; then return 0; fi
  links=$(mktemp "$SBM_RUN/substore-push.XXXXXX") || return 1
  body="$links.json"
  _substore_remote_links "$links" || { rm -f "$links"; return 1; }
  local count; count=$(grep -c '' "$links")
  local rc=0
  response=$(substore_remote_api GET "/api/sub/$(jq -rn --arg n "$name" '$n|@uri')" 2>/dev/null) || rc=$?
  # curl 22 = HTTP error (the source does not exist yet); anything else is a
  # connection problem.
  if ((rc != 0 && rc != 22)); then rm -f "$links"; log_error "无法连接中心 Sub-Store（curl 错误 $rc）。"; return 1; fi
  if ((rc == 0)) && jq -e '.status=="success"' <<<"$response" >/dev/null 2>&1; then
    # Existing source: replace only its content.
    jq -n --rawfile content "$links" '{content:$content}' >"$body"
    response=$(substore_remote_api PATCH "/api/sub/$(jq -rn --arg n "$name" '$n|@uri')" "$body") || { rm -f "$links" "$body"; log_error '更新中心 Sub-Store 来源失败。'; return 1; }
  else
    jq -n --arg name "$name" --arg display "$display" --argjson tags "$tags" --rawfile content "$links" \
      '{name:$name, displayName:$display, source:"local", content:$content, tag:$tags}' >"$body"
    response=$(substore_remote_api POST "/api/subs" "$body") || { rm -f "$links" "$body"; log_error '在中心 Sub-Store 创建来源失败。'; return 1; }
  fi
  rm -f "$links" "$body"
  jq -e '.status=="success"' <<<"$response" >/dev/null 2>&1 || { log_error "中心 Sub-Store 拒绝写入：$(jq -r '.error.message // .message // "未知错误"' <<<"$response" 2>/dev/null)"; return 1; }
  (umask 077; printf '%s %s\n' "$fp" "$name" >"$SBM_SUBSTORE_REMOTE_HASH")
  log_ok "已推送 $count 个节点到中心 Sub-Store 来源：$display"
}

# Called after every successful state transaction. Unchanged nodes cost one
# fingerprint; otherwise the push runs detached (it waits for the manager
# lock) so the operation never waits for the export or the network. The
# result is recorded in substore-remote.log and shown by `remote status`.
substore_remote_auto_push() {
  substore_remote_configured || return 0
  [[ "${SBM_SUBSTORE_REMOTE_PUSHING:-0}" == 0 ]] || return 0
  if [[ -r "$SBM_SUBSTORE_REMOTE_HASH" ]] \
     && [[ "$(<"$SBM_SUBSTORE_REMOTE_HASH")" == "$(substore_remote_fingerprint) $(jq -r '.name' "$SBM_SUBSTORE_REMOTE_SECRET")" ]]; then return 0; fi
  mkdir -p "$SBM_LOG_DIR" 2>/dev/null || true
  SBM_SUBSTORE_REMOTE_PUSHING=1 nohup "$SBM_LIB/sb" substore remote push --auto \
    </dev/null >"$SBM_LOG_DIR/substore-remote.log" 2>&1 9>&- &
  disown 2>/dev/null || true
}

_substore_remote_set() {
  local url=$1 name=$2 display=$3 tags=$4 response tmp
  [[ "$url" =~ ^https://[^/[:space:]]+/[^[:space:]]+$ || "$url" =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?/[^[:space:]]+$ ]] \
    || die '中心 Sub-Store 后端地址须为 https://域名/后端路径（同机可用 http://127.0.0.1:端口/后端路径）。'
  validate_node_id "$name" || die '来源名称只能包含小写字母、数字、点、下划线和连字符。'
  tmp=$(mktemp "$SBM_SECRETS/.substore-remote.XXXXXX") || return 1
  jq -n --arg url "$url" --arg name "$name" --arg display "$display" --argjson tags "$tags" \
    '{url:$url, name:$name, display:$display, tags:$tags}' >"$tmp" && chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  # Verify the address before saving it.
  if ! response=$(SBM_SUBSTORE_REMOTE_SECRET=$tmp substore_remote_api GET /api/subs 2>&1) \
     || ! jq -e '.status=="success" and (.data|type=="array")' <<<"$response" >/dev/null 2>&1; then
    rm -f "$tmp"; die '无法访问中心 Sub-Store 后端（检查地址与后端路径）。'
  fi
  mv -f "$tmp" "$SBM_SUBSTORE_REMOTE_SECRET" || { rm -f "$tmp"; return 1; }
  rm -f "$SBM_SUBSTORE_REMOTE_HASH"
  log_ok "已连接中心 Sub-Store（现有 $(jq '.data|length' <<<"$response") 个来源）。"
  substore_remote_push 1
}

substore_remote_cli() {
  local action=${1:-status}; shift || true
  case "$action" in
    set)
      local url=${1:-} name display='' tags='[]' t
      [[ -n "$url" ]] || usage_die '用法：sb substore remote set -|URL [--name 来源名] [--display 显示名] [--tag 主节点库]（- 从标准输入读取地址，避免出现在进程列表）'
      shift
      if [[ "$url" == - ]]; then IFS= read -r url || usage_die '标准输入没有地址。'; fi
      name=$(substore_remote_default_name)
      while (($#)); do
        case "$1" in
          --name) name=${2:?}; shift 2;;
          --display) display=${2:?}; shift 2;;
          --tag) t=${2:?}; tags=$(jq -c --arg t "$t" '. + [$t] | unique' <<<"$tags"); shift 2;;
          *) usage_die "未知参数：$1";;
        esac
      done
      require_root; with_lock _substore_remote_set "$url" "$name" "${display:-$name}" "$tags";;
    push)
      require_root
      if [[ ${1:-} == --auto ]]; then with_lock substore_remote_push 0; else with_lock substore_remote_push 1; fi;;
    status)
      if substore_remote_configured; then
        jq -r '"中心 Sub-Store：已连接（地址含后端路径，已隐藏）","来源名：\(.name)（显示名 \(.display // .name)）","新建时的标签：\(if (.tags|length)>0 then (.tags|join(",")) else "无" end)"' "$SBM_SUBSTORE_REMOTE_SECRET"
        if [[ -r "$SBM_SUBSTORE_REMOTE_HASH" ]]; then printf '上次推送：%s\n' "$(date -r "$SBM_SUBSTORE_REMOTE_HASH" '+%F %T' 2>/dev/null)"; fi
        if [[ -s "$SBM_LOG_DIR/substore-remote.log" ]] && grep -q 'FAIL' "$SBM_LOG_DIR/substore-remote.log"; then
          printf '最近一次自动推送失败：%s\n' "$(grep -m1 'FAIL' "$SBM_LOG_DIR/substore-remote.log" | sed 's/^\[FAIL\] //')"
        fi
        printf '节点变化后自动推送。\n'
      else printf '中心 Sub-Store：未连接。连接后本机节点会作为一个来源自动同步到那里。\n'; fi;;
    disable) require_root; rm -f "$SBM_SUBSTORE_REMOTE_SECRET" "$SBM_SUBSTORE_REMOTE_HASH" "$SBM_LOG_DIR/substore-remote.log"; log_ok '已断开中心 Sub-Store（中心那边已有的来源保留，可在网页里删除）。';;
    *) usage_die '用法：sb substore remote set URL [--name N] [--display D] [--tag T]|push|status|disable';;
  esac
}
