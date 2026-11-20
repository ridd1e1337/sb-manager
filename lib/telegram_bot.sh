#!/usr/bin/env bash
# shellcheck shell=bash

# Telegram command bot. It reuses the Telegram notification credentials,
# accepts messages only from the configured chat and an explicit admin user
# allowlist, and maps a fixed command set onto `sb` subcommands with
# validated arguments. No message text ever reaches a shell.

SBM_TELEGRAM_BOT_SERVICE="${SBM_TELEGRAM_BOT_SERVICE:-sb-telegram-bot.service}"
SBM_TELEGRAM_OFFSET="${SBM_TELEGRAM_OFFSET:-$SBM_VAR/telegram-bot.offset}"

telegram_bot_validate_state() {
  jq -e '(.notifications.bot // {enabled:false}) as $b |
    ($b.enabled|type=="boolean")
    and (($b.admins // [])|type=="array" and all(.[]; type=="number" and floor==. and .>0))
    and (($b.enabled|not) or ((.notifications.provider // "")=="telegram" and ($b.admins|length)>0))' "$1" >/dev/null || {
    log_error 'Telegram 机器人需要 Telegram 通知渠道和至少一个管理员用户 ID。'; return 1;
  }
}

telegram_bot_secret() {
  [[ -s "$SBM_NOTIFICATION_SECRET" ]] || { log_error 'Telegram 通知凭据缺失。'; return 1; }
  jq -ce 'select(.provider=="telegram" and (.bot_token|length)>0 and (.chat_id|tostring|length)>0)' "$SBM_NOTIFICATION_SECRET" \
    || { log_error '请先运行 sb notify configure telegram。'; return 1; }
}

# The bot token is passed through a curl config on stdin, never argv.
telegram_api() {
  local token=$1 method=$2
  shift 2
  printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$method" |
    curl --fail --silent --connect-timeout 10 --max-time 70 --config - "$@"
}

telegram_bot_reply() {
  local token=$1 chat=$2 text=$3
  (( ${#text} <= 3800 )) || text="${text:0:3800}
…（输出已截断）"
  telegram_api "$token" sendMessage --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" >/dev/null || true
}

telegram_bot_help() {
  cat <<'EOF'
sb-manager 机器人命令：
/status 服务器与服务状态
/nodes 节点列表
/users [节点] 用户状态与到期时间
/enable 节点 用户 · /disable 节点 用户
/renew 节点 用户 天数
/sub 节点 用户 [mixed|tun] 生成该用户动态订阅
EOF
}

# Map a command line to an argv for sb; prints NUL-separated argv.
telegram_bot_argv() {
  local text=$1 cmd arg id='^[a-z0-9][a-z0-9._-]{0,47}$'
  local -a w=()
  read -r -a w <<<"${text//$'\r'/}"
  ((${#w[@]} > 0)) || return 1
  cmd=${w[0]%%@*}
  for arg in "${w[@]:1}"; do [[ "$arg" =~ ^[A-Za-z0-9._:-]{1,64}$ ]] || return 1; done
  case "$cmd:${#w[@]}" in
    /status:1) printf '%s\0' status;;
    /nodes:1) printf '%s\0' node list;;
    /users:1) printf '%s\0' user stats;;
    /users:2) [[ ${w[1]} =~ $id ]] || return 1; printf '%s\0' user stats "${w[1]}";;
    /enable:3|/disable:3)
      [[ ${w[1]} =~ $id && ${w[2]} =~ $id ]] || return 1
      printf '%s\0' user "${cmd#/}" "${w[1]}" "${w[2]}";;
    /renew:4)
      [[ ${w[1]} =~ $id && ${w[2]} =~ $id && ${w[3]} =~ ^[1-9][0-9]{0,3}$ ]] || return 1
      printf '%s\0' user limit "${w[1]}" "${w[2]}" --days "${w[3]}";;
    /sub:3|/sub:4)
      [[ ${w[1]} =~ $id && ${w[2]} =~ $id ]] || return 1
      local mode=${w[3]:-mixed}
      case "$mode" in mixed|tun) ;; *) return 1;; esac
      printf '%s\0' subscription create never "$mode" --live --user "${w[1]}:${w[2]}";;
    *) return 1;;
  esac
}

telegram_bot_handle() {
  local token=$1 chat=$2 text=$3 output rc=0
  local -a argv=()
  case "${text%%[ @]*}" in /start|/help) telegram_bot_reply "$token" "$chat" "$(telegram_bot_help)"; return;; esac
  mapfile -d '' -t argv < <(telegram_bot_argv "$text") || true
  if ((${#argv[@]} == 0)); then telegram_bot_reply "$token" "$chat" "无法识别或参数无效。发送 /help 查看命令。"; return; fi
  output=$(NO_COLOR=1 SBM_ASSUME_YES=1 timeout 120 "$SBM_BIN_DIR/sb" "${argv[@]}" </dev/null 2>&1) || rc=$?
  output=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$output")
  telegram_bot_reply "$token" "$chat" "$( ((rc == 0)) && printf '✅' || printf '❌（%s）' "$rc") ${output:-完成}"
}

telegram_bot_run() {
  local secret token chat admins offset=0 response update
  require_root
  secret=$(telegram_bot_secret) || return 1
  token=$(jq -r '.bot_token' <<<"$secret"); chat=$(jq -r '.chat_id|tostring' <<<"$secret")
  admins=$(jq -c '.notifications.bot.admins // []' "$SBM_STATE")
  [[ "$admins" != '[]' ]] || { log_error '未设置机器人管理员。'; return 1; }
  [[ ! -s "$SBM_TELEGRAM_OFFSET" ]] || offset=$(tr -cd '0-9' <"$SBM_TELEGRAM_OFFSET")
  log_info 'Telegram 机器人已启动。'
  while true; do
    response=$(telegram_api "$token" getUpdates --get --data-urlencode "offset=${offset:-0}" \
      --data-urlencode timeout=50 --data-urlencode 'allowed_updates=["message"]') || { sleep 5; continue; }
    jq -e '.ok==true' <<<"$response" >/dev/null 2>&1 || { sleep 5; continue; }
    while IFS= read -r update; do
      [[ -n "$update" ]] || continue
      offset=$(( $(jq -r '.update_id' <<<"$update") + 1 ))
      printf '%s\n' "$offset" >"$SBM_TELEGRAM_OFFSET.tmp" && mv -f "$SBM_TELEGRAM_OFFSET.tmp" "$SBM_TELEGRAM_OFFSET"
      # Only the configured chat, only allowlisted senders, only text.
      jq -e --arg chat "$chat" --argjson admins "$admins" '
        (.message.chat.id|tostring)==$chat and ((.message.from.id // 0) as $f | $admins|index($f))!=null
        and (.message.text|type=="string") and (.message.text|startswith("/"))' <<<"$update" >/dev/null || continue
      telegram_bot_handle "$token" "$chat" "$(jq -r '.message.text' <<<"$update")"
    done < <(jq -c '.result[]?' <<<"$response")
  done
}

telegram_bot_write_service() {
  local unit
  case "$(effective_init_system)" in
    systemd)
      unit="$SBM_SYSTEMD_DIR/$SBM_TELEGRAM_BOT_SERVICE"
      mkdir -p "$SBM_SYSTEMD_DIR"
      cat >"$unit" <<EOF_UNIT
[Unit]
Description=sb-manager Telegram command bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SBM_BIN_DIR/sb notify bot run
Restart=always
RestartSec=10s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF_UNIT
      chmod 0644 "$unit";;
    openrc)
      write_openrc_supervised_service "$SBM_OPENRC_DIR/$(service_native_name "$SBM_TELEGRAM_BOT_SERVICE")" \
        'sb-manager telegram bot' 'sb-manager Telegram command bot' "$SBM_BIN_DIR/sb" 'notify bot run' root \
        "$SBM_LOG_DIR/telegram-bot.log" "$SBM_LOG_DIR/telegram-bot.err.log" net;;
    *) log_error '机器人服务需要 systemd 或 OpenRC。'; return 1;;
  esac
}

telegram_bot_reconcile() {
  [[ "$SBM_SKIP_INIT" != 1 ]] || return 0
  if [[ $(jq -r '.notifications.bot.enabled // false' "$SBM_STATE") == true ]]; then
    telegram_bot_write_service && service_reload_manager && service_enable "$SBM_TELEGRAM_BOT_SERVICE" \
      && service_restart "$SBM_TELEGRAM_BOT_SERVICE" && service_wait_active "$SBM_TELEGRAM_BOT_SERVICE" 20 || return 1
  elif service_exists "$SBM_TELEGRAM_BOT_SERVICE"; then
    service_disable "$SBM_TELEGRAM_BOT_SERVICE" || true
    service_stop "$SBM_TELEGRAM_BOT_SERVICE" || true
  fi
}

_telegram_bot_set() {
  local enabled=$1 admins=${2:-} candidate admins_json='[]'
  if [[ "$enabled" == true ]]; then
    telegram_bot_secret >/dev/null || return 1
    [[ "$admins" =~ ^[1-9][0-9]{0,15}(,[1-9][0-9]{0,15})*$ ]] || { log_error '--admin 须为 Telegram 数字用户 ID，多个用逗号分隔。'; return 1; }
    admins_json=$(jq -cn --arg a "$admins" '$a|split(",")|map(tonumber)|unique')
  fi
  candidate=$(state_candidate) || return 1
  jq --argjson enabled "$enabled" --argjson admins "$admins_json" \
    '.notifications.bot={enabled:$enabled,admins:(if $enabled then $admins else (.notifications.bot.admins // []) end)}' "$SBM_STATE" >"$candidate" || { rm -f "$candidate"; return 1; }
  if ! apply_candidate_state "$candidate" telegram-bot; then rm -f "$candidate"; return 1; fi
  rm -f "$candidate"
  telegram_bot_reconcile || return 1
  if [[ "$enabled" == true ]]; then log_ok "Telegram 机器人已启用，管理员：$admins"; else log_ok 'Telegram 机器人已停用。'; fi
}

telegram_bot_cli() {
  local action=${1:-status}
  case "$action" in
    enable)
      [[ "${2:-}" == --admin && -n "${3:-}" ]] || usage_die '用法：sb notify bot enable --admin USER_ID[,USER_ID]'
      require_root; with_state_transaction telegram-bot _telegram_bot_set true "$3";;
    disable) require_root; with_state_transaction telegram-bot _telegram_bot_set false;;
    run) telegram_bot_run;;
    status) jq '.notifications.bot // {enabled:false,admins:[]}' "$SBM_STATE";;
    *) usage_die '用法：sb notify bot enable --admin ID[,ID]|disable|status|run';;
  esac
}
