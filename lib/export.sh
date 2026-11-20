#!/usr/bin/env bash
# shellcheck shell=bash

node_share_uri() {
  local id=$1 user_id=${2:-} node user secret node_secret='{}' protocol
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  if declare -F nginx_stream_public_node >/dev/null 2>&1; then node=$(nginx_stream_public_node "$node"); fi
  [[ -n "$user_id" ]] || user_id=$(jq -r 'first(.users[] | select(.enabled==true) | .id) // empty' <<<"$node")
  [[ -n "$user_id" ]] || die "节点没有启用用户：$id"
  user=$(state_get_user "$id" "$user_id"); secret=$(jq -s '.[0]+.[1]' <(printf '%s\n' "$user") <(state_get_user_secret "$id" "$user_id"))
  [[ ! -r $(state_secret_path "$id") ]] || node_secret=$(state_get_secret "$id")
  protocol=$(jq -r '.protocol' <<<"$node")
  case "$protocol" in
    vmess-ws-cf) protocol_vmess_share "$node" "$secret" "$node_secret" ;;
    shadowsocks) protocol_ss_share "$node" "$secret" "$node_secret" ;;
    anytls) protocol_anytls_share "$node" "$secret" "$node_secret" ;;
    hysteria2) protocol_hy2_share "$node" "$secret" "$node_secret" ;;
    trojan) protocol_trojan_share "$node" "$secret" ;;
    tuic) protocol_tuic_share "$node" "$secret" ;;
    vless) protocol_vless_share "$node" "$secret" "$node_secret" ;;
    socks|http|mixed) protocol_proxy_share "$node" "$secret" ;;
    naive) protocol_naive_share "$node" "$secret" ;;
    shadowtls) protocol_shadowtls_share "$node" "$secret" "$node_secret" ;;
    snell) protocol_snell_share "$node" "$secret" "$node_secret" ;;
  esac
}

node_client_outbound() {
  local id=$1 user_id=${2:-} node user secret node_secret='{}' protocol outbound tag override
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  if declare -F nginx_stream_public_node >/dev/null 2>&1; then node=$(nginx_stream_public_node "$node"); fi
  [[ -n "$user_id" ]] || user_id=$(jq -r 'first(.users[] | select(.enabled==true) | .id) // empty' <<<"$node")
  [[ -n "$user_id" ]] || die "节点没有启用用户：$id"
  user=$(state_get_user "$id" "$user_id"); secret=$(jq -s '.[0]+.[1]' <(printf '%s\n' "$user") <(state_get_user_secret "$id" "$user_id"))
  [[ ! -r $(state_secret_path "$id") ]] || node_secret=$(state_get_secret "$id")
  protocol=$(jq -r '.protocol' <<<"$node")
  tag="proxy-${id}-${user_id}"
  case "$protocol" in
    vmess-ws-cf) outbound=$(protocol_vmess_client_outbound "$node" "$secret" "$node_secret") ;;
    shadowsocks) outbound=$(protocol_ss_client_outbound "$node" "$secret" "$node_secret") ;;
    anytls) outbound=$(protocol_anytls_client_outbound "$node" "$secret" "$node_secret") ;;
    hysteria2) outbound=$(protocol_hy2_client_outbound "$node" "$secret" "$node_secret") ;;
    trojan) outbound=$(protocol_trojan_client_outbound "$node" "$secret") ;;
    tuic) outbound=$(protocol_tuic_client_outbound "$node" "$secret") ;;
    vless) outbound=$(protocol_vless_client_outbound "$node" "$secret" "$node_secret") || return 1 ;;
    socks|http|mixed) outbound=$(protocol_proxy_client_outbound "$node" "$secret") ;;
    naive) outbound=$(protocol_naive_client_outbound "$node" "$secret") ;;
    shadowtls) outbound=$(protocol_shadowtls_client_outbound "$node" "$secret" "$node_secret" "$tag") || return 1 ;;
    snell) outbound=$(protocol_snell_client_outbound "$node" "$secret" "$node_secret") ;;
    *) die "不支持导出的协议：$protocol" ;;
  esac
  [[ -n "$outbound" ]] || return 1
  outbound=$(jq --arg tag "$tag" 'if type=="array" then . else .tag=$tag end' <<<"$outbound")
  override=$(singbox_node_override "$node" outbound)
  singbox_apply_override "$outbound" "$override"
}

node_substore_line() {
  local id=$1 user_id=${2:-} node user secret node_secret='{}' protocol
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  if declare -F nginx_stream_public_node >/dev/null 2>&1; then node=$(nginx_stream_public_node "$node"); fi
  [[ -n "$user_id" ]] || user_id=$(jq -r 'first(.users[] | select(.enabled==true) | .id) // empty' <<<"$node")
  [[ -n "$user_id" ]] || die "节点没有启用用户：$id"
  protocol=$(jq -r '.protocol' <<<"$node")
  if [[ "$protocol" != snell ]]; then
    node_share_uri "$id" "$user_id"
    return
  fi
  user=$(state_get_user "$id" "$user_id")
  secret=$(jq -s '.[0]+.[1]' <(printf '%s\n' "$user") <(state_get_user_secret "$id" "$user_id"))
  [[ ! -r $(state_secret_path "$id") ]] || node_secret=$(state_get_secret "$id")
  protocol_snell_surge_share "$node" "$secret" "$node_secret"
}

export_substore_links() {
  local output=${1:-$SBM_EXPORTS/substore.txt} node id user_id line tmp
  mkdir -p "$(dirname "$output")"
  tmp=$(mktemp "$(dirname "$output")/.substore.XXXXXX")
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    while IFS= read -r user_id; do
      if line=$(node_substore_line "$id" "$user_id"); then printf '%s\n' "$line" >>"$tmp" || return 1
      else log_warn "Sub-Store 链接已排除无法用分享链接表达的节点：$id/$user_id；请使用 sing-box 客户端配置。"; fi
    done < <(jq -r '.users[] | select(.enabled==true) | .id' <<<"$node")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  chmod 0600 "$tmp"
  mv "$tmp" "$output"
}

node_share() {
  local id=$1 qr=${2:-0} user_id=${3:-} uri out_dir outbound node user secret node_secret protocol native substore_line profile_ready=0 surge_ready=0
  node=$(state_get_node "$id"); [[ -n "$node" ]] || die "节点不存在：$id"
  if declare -F nginx_stream_public_node >/dev/null 2>&1; then node=$(nginx_stream_public_node "$node"); fi
  [[ -n "$user_id" ]] || user_id=$(jq -r 'first(.users[] | select(.enabled==true) | .id) // empty' <<<"$node")
  [[ -n "$user_id" ]] || die "节点没有启用用户：$id"
  state_user_exists "$id" "$user_id" || die "用户不存在：$id/$user_id"
  protocol=$(jq -r '.protocol' <<<"$node")
  user=$(state_get_user "$id" "$user_id")
  secret=$(jq -s '.[0]+.[1]' <(printf '%s\n' "$user") <(state_get_user_secret "$id" "$user_id"))
  node_secret='{}'; [[ ! -r $(state_secret_path "$id") ]] || node_secret=$(state_get_secret "$id")
  out_dir="$SBM_EXPORTS/nodes/$id/$user_id"; mkdir -p "$out_dir"; chmod 0700 "$out_dir" 2>/dev/null || true
  rm -f "$out_dir/surge.conf" "$out_dir/mihomo.json" "$out_dir/mihomo.yaml"
  if [[ "$protocol" == snell ]]; then
    if native=$(protocol_snell_surge_share "$node" "$secret" "$node_secret"); then
      printf '%s\n' "$native" >"$out_dir/surge.conf"; chmod 0600 "$out_dir/surge.conf"
      surge_ready=1
      # Print the usable native entry before ancillary exports or diagnostics.
      printf '\n%sSurge 原生配置（复制到配置文件的 [Proxy] 段）%s\n\n%s\n\n' "$C_BOLD" "$C_RESET" "$native"
      printf '节点/用户：%s/%s；已保存：%s\n' "$id" "$user_id" "$out_dir/surge.conf"
      if [[ $(jq -r '.snell_version // 5' <<<"$node") == 6 ]]; then
        printf 'Snell v6 需要支持 v6 的 Surge 版本。\n'
      else
        printf '服务端 Snell v5 使用 Surge 兼容的 version=4。\n'
      fi
    else
      printf '\n该 Snell 节点未生成 Surge 配置（多用户模式不受支持）；请使用下方 sing-box 配置。\n'
    fi
    if native=$(protocol_snell_mihomo_share "$node" "$secret" "$node_secret"); then
      printf '{"proxies":[%s]}\n' "$native" | jq . >"$out_dir/mihomo.json"; chmod 0600 "$out_dir/mihomo.json"
      cp "$out_dir/mihomo.json" "$out_dir/mihomo.yaml"; chmod 0600 "$out_dir/mihomo.yaml"
    fi
  fi
  # The link (and QR) comes first; every client format is then exported
  # independently, so one that cannot express the node never hides the rest.
  rm -f "$out_dir/share.txt" "$out_dir/substore.txt" "$out_dir/outbound.json" "$out_dir/client.json"
  [[ "$protocol" == snell ]] || rm -f "$out_dir/mihomo.json" "$out_dir/mihomo.yaml"
  # The client formats are independent read-only exports: build them in
  # parallel, then report in a fixed order.
  local -a jobs=()
  { if outbound=$(node_client_outbound "$id" "$user_id" 2>/dev/null); then
      printf '%s\n' "$outbound" | jq . >"$out_dir/outbound.json"; chmod 0600 "$out_dir/outbound.json"
      export_node_client_config "$id" "$user_id" "$out_dir/client.json" >/dev/null 2>&1 || rm -f "$out_dir/client.json"
    fi; } & jobs+=($!)
  if [[ ! -r "$out_dir/mihomo.yaml" ]]; then
    { export_mihomo_client_config "$out_dir/mihomo.json" "$id" "$user_id" >/dev/null 2>&1 \
        && cp "$out_dir/mihomo.json" "$out_dir/mihomo.yaml" && chmod 0600 "$out_dir/mihomo.yaml" || rm -f "$out_dir/mihomo.json"; } & jobs+=($!)
  fi
  if (( surge_ready == 0 )); then printf '\n%s节点/用户：%s/%s%s\n' "$C_BOLD" "$id" "$user_id" "$C_RESET"; fi
  if uri=$(node_share_uri "$id" "$user_id" 2>/dev/null) && [[ -n "$uri" ]]; then
    printf '%s\n' "$uri" >"$out_dir/share.txt"; chmod 0600 "$out_dir/share.txt"
    cp "$out_dir/share.txt" "$out_dir/substore.txt"; chmod 0600 "$out_dir/substore.txt"
    if [[ "$protocol" != snell ]]; then
      printf '\n分享链接：\n%s\n\n' "$uri"
      if [[ "$qr" == 1 ]]; then
        if command_exists qrencode; then qrencode -t ANSIUTF8 "$uri"; else log_info '未安装二维码工具；可直接复制上面的分享链接导入客户端。'; fi
      fi
    fi
  elif (( surge_ready == 0 )); then
    log_info '该节点没有通用分享链接格式，请使用下方客户端配置文件。'
  fi
  wait "${jobs[@]}" 2>/dev/null || true
  if [[ -r "$out_dir/client.json" ]]; then printf 'sing-box 客户端配置：%s\n' "$out_dir/client.json"
  elif [[ -r "$out_dir/outbound.json" ]]; then printf 'sing-box 节点 JSON：%s\n' "$out_dir/outbound.json"; fi
  [[ ! -r "$out_dir/mihomo.yaml" ]] || printf 'mihomo 客户端配置（Clash Verge/FlClash）：%s\n' "$out_dir/mihomo.yaml"
  if [[ "$protocol" == shadowtls ]]; then
    printf 'ShadowTLS 文件包含 Shadowsocks 内层与 ShadowTLS 外层两个 outbound，须一起导入；分享链接需要客户端支持 shadow-tls 插件。\n'
  fi
  [[ -r "$out_dir/share.txt" || -r "$out_dir/outbound.json" || -r "$out_dir/mihomo.yaml" || "$surge_ready" == 1 ]] \
    || { log_error "节点 $id 没有可用的客户端导出。"; return 1; }
}

node_share_all() (
  local node id user_id uri native protocol file="$SBM_EXPORTS/links.txt" substore_file="$SBM_EXPORTS/substore.txt" tmp='' surge_tmp='' display_tmp=''
  local surge_file="$SBM_EXPORTS/snell-surge.conf" unsupported=''
  trap 'rm -f -- "$tmp" "$surge_tmp" "$display_tmp"' EXIT
  mkdir -p "$SBM_EXPORTS" || return 1
  tmp=$(mktemp "$SBM_EXPORTS/.links.XXXXXX") || return 1
  surge_tmp=$(mktemp "$SBM_EXPORTS/.snell-surge.XXXXXX") || return 1
  display_tmp=$(mktemp "$SBM_EXPORTS/.share-display.XXXXXX") || return 1
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    protocol=$(jq -r '.protocol' <<<"$node")
    while IFS= read -r user_id; do
      if uri=$(node_share_uri "$id" "$user_id"); then
        printf '%s\n' "$uri" >>"$tmp" || return 1
        if [[ "$protocol" != snell ]]; then printf '%s\n' "$uri" >>"$display_tmp" || return 1; fi
      else log_warn "链接文件已排除无法完整表达的节点：$id/$user_id。"; fi
      if [[ "$protocol" == snell ]]; then
        if native=$(node_substore_line "$id" "$user_id" 2>/dev/null); then
          printf '%s\n' "$native" >>"$surge_tmp" || return 1
        else unsupported+=" $id/$user_id"; fi
      fi
    done < <(jq -r '.users[] | select(.enabled==true) | .id' <<<"$node")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  chmod 0600 "$tmp" "$surge_tmp" "$display_tmp" || return 1
  mv "$tmp" "$file" && mv "$surge_tmp" "$surge_file" || return 1
  if [[ -s "$surge_file" ]]; then
    printf 'Surge 原生 Snell 配置（复制到 [Proxy] 段；v6 需客户端支持）：\n\n'
    cat "$surge_file"
    printf '\n已保存：%s\n\n' "$surge_file"
  fi
  if [[ -s "$display_tmp" ]]; then printf '节点分享链接：\n'; cat "$display_tmp"; fi
  if [[ -n "$unsupported" ]]; then printf '\n以下 Snell 节点未生成 Surge 配置（多用户模式不受支持），请检查节点并使用 sing-box 导出：%s\n' "$unsupported"; fi
  export_substore_links "$substore_file" || return 1
  printf '\n通用链接文件：%s\nSub-Store 兼容订阅文件：%s\n' "$file" "$substore_file"
)

export_all_outbounds() {
  local arr='[]' node id user_id ob out="$SBM_EXPORTS/outbounds.json"
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node")
    while IFS= read -r user_id; do
      if ! ob=$(node_client_outbound "$id" "$user_id"); then
        log_warn "sing-box outbound 已排除不兼容节点：$id/$user_id。"
        continue
      fi
      arr=$(jq -c --argjson x "$ob" '. + ($x | if type=="array" then . else [.] end)' <<<"$arr")
    done < <(jq -r '.users[] | select(.enabled==true) | .id' <<<"$node")
  done < <(jq -c '.nodes[]? | select(.enabled==true)' "$SBM_STATE")
  [[ "$arr" != '[]' ]] || { log_error '没有可导出的 sing-box 节点。'; return 1; }
  printf '%s\n' "$arr" | jq . >"$out"; chmod 0600 "$out"
  log_ok "已导出客户端 outbound 数组：$out"
}

export_node_client_config() {
  local id=$1 user_id=${2:-} output=${3:-}
  [[ -n "$user_id" ]] || user_id=$(jq -r --arg id "$id" 'first(.nodes[]|select(.id==$id)|.users[]|select(.enabled)|.id) // empty' "$SBM_STATE")
  [[ -n "$user_id" ]] || die '该节点没有启用用户，无法生成客户端配置。'
  [[ -n "$output" ]] || output="$SBM_EXPORTS/nodes/$id/$user_id/client.json"
  export_client_config "$output" mixed hijack '' "$id" "$user_id"
}

export_client_config() {
  local output=${1:-$SBM_EXPORTS/client-config.json} mode=${2:-mixed} tun_dns_mode=${3:-hijack} tun_dns_address=${4:-} selected_node=${5:-} selected_user=${6:-}
  local node user_id ob outbounds='[]' final inbounds route dns strategy core_version tmp
  [[ "$mode" == mixed || "$mode" == tun ]] || die '客户端模式必须是 mixed 或 tun。'
  case "$tun_dns_mode" in disabled|native|hijack) ;; *) die 'TUN DNS 模式必须是 disabled、native 或 hijack。';; esac
  if [[ -n "$tun_dns_address" ]]; then
    validate_address "$tun_dns_address" || die "无效 TUN DNS 地址：$tun_dns_address"
  fi
  if [[ -n "$selected_node" ]]; then
    state_node_exists "$selected_node" || die "节点不存在：$selected_node"
    [[ -z "$selected_user" ]] || state_user_exists "$selected_node" "$selected_user" || die "用户不存在：$selected_node/$selected_user"
  elif [[ -n "$selected_user" ]]; then
    die '导出指定用户时必须选择节点。'
  fi
  mkdir -p "$(dirname "$output")"
  while IFS= read -r node; do
    while IFS= read -r user_id; do
      if ! ob=$(node_client_outbound "$(jq -r '.id' <<<"$node")" "$user_id"); then
        [[ -z "$selected_node" ]] || return 1
        log_warn "sing-box 配置已排除不兼容节点：$(jq -r '.id' <<<"$node")/$user_id。"
        continue
      fi
      outbounds=$(jq -c --argjson x "$ob" '. + ($x | if type=="array" then . else [.] end)' <<<"$outbounds")
    done < <(jq -r --arg user "$selected_user" '.users[] | select(if $user=="" then .enabled==true else .id==$user end) | .id' <<<"$node")
  done < <(jq -c --arg id "$selected_node" '.nodes[]? | select(if $id=="" then .enabled==true else .id==$id end)' "$SBM_STATE")
  [[ "$outbounds" != '[]' ]] || { log_error '没有可导出的 sing-box 节点。'; return 1; }
  final=$(jq -r 'first(.[]?.tag) // "direct"' <<<"$outbounds")
  strategy=$(jq -r '.settings.outbound_ip_strategy // "prefer_ipv4"' "$SBM_STATE")
  dns=$(jq -n --arg strategy "$strategy" '{servers:[{type:"local",tag:"dns-local"}],final:"dns-local",strategy:$strategy}')
  if [[ "$mode" == tun ]]; then
    inbounds=$(jq -n '[{type:"tun",tag:"tun-in",address:["172.19.0.1/30","fdfe:dcba:9876::1/126"],mtu:1500,auto_route:true,strict_route:true,stack:"system"}]')
    core_version=$(core_current_version || true)
    if version_ge "$core_version" 1.14.0-rc.1; then
      inbounds=$(jq --arg mode "$tun_dns_mode" --arg address "$tun_dns_address" '.[0].dns_mode=$mode | if $address=="" then . else .[0].dns_address=[$address] end' <<<"$inbounds")
    elif [[ "$tun_dns_mode" != hijack || -n "$tun_dns_address" ]]; then
      die '自定义 TUN DNS 模式/地址需要 sing-box 1.14.0-rc.1 或更高版本核心。'
    fi
    route=$(jq -n --arg final "$final" '{auto_detect_interface:true,default_domain_resolver:"dns-local",rules:[{action:"sniff"},{protocol:"dns",action:"hijack-dns"},{ip_is_private:true,action:"route",outbound:"direct"}],final:$final}')
  else
    inbounds=$(jq -n '[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}]')
    route=$(jq -n --arg final "$final" '{default_domain_resolver:"dns-local",final:$final}')
  fi
  tmp=$(mktemp "$(dirname "$output")/.client-config.XXXXXX") || return 1
  if ! jq -n --argjson dns "$dns" --argjson inbounds "$inbounds" --argjson route "$route" --argjson outbounds "$outbounds" '{
    "$schema":"https://sing-box.sagernet.org/schema.json",
    log:{level:"info",timestamp:true},
    dns:$dns,
    inbounds:$inbounds,
    outbounds:($outbounds + [{type:"direct",tag:"direct"}]),
    route:$route
  }' >"$tmp"; then rm -f "$tmp"; return 1; fi
  if ! core_validate_config "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 0600 "$tmp" && mv -f "$tmp" "$output" || { rm -f "$tmp"; return 1; }
  log_ok "已导出 $mode 模式 sing-box 客户端配置：$output"
}


# mihomo export for every protocol: convert the effective sing-box client
# outbound (shared converter with xray-manager).
node_mihomo_client_outbound() {
  local id=$1 user_id=${2:-} node outbound result
  node=$(state_get_node "$id") || return 1
  [[ -n "$node" ]] || return 1
  [[ -n "$user_id" ]] || user_id=$(jq -r 'first(.users[]|select(.enabled)|.id) // empty' <<<"$node")
  [[ -n "$user_id" ]] || return 1
  outbound=$(node_client_outbound "$id" "$user_id") || return 1
  if [[ $(jq -r 'type' <<<"$outbound") == array ]]; then log_warn "mihomo 导出暂不转换复合协议节点：$id。"; return 1; fi
  if ! result=$(jq -c --arg name "$(jq -r '.name' <<<"$node") [$id/$user_id]" -f "$SBM_LIB/libexec/singbox_to_mihomo.jq" <<<"$outbound" 2>&1); then
    log_warn "$(sed -n 's/.*"sb_reason":"\([^"]*\)".*/\1/p' <<<"$result" | head -1)"; return 1
  fi
  printf '%s\n' "$result"
}

export_mihomo_client_config() (
  local output=${1:-$SBM_EXPORTS/mihomo-client.json} selected_node=${2:-} selected_user=${3:-}
  local node id user_id proxy proxies='[]' tmp
  mkdir -p "$(dirname "$output")" || return 1
  while IFS= read -r node; do
    id=$(jq -r '.id' <<<"$node") || return 1
    while IFS= read -r user_id; do
      if proxy=$(node_mihomo_client_outbound "$id" "$user_id"); then
        proxies=$(jq --argjson proxy "$proxy" '. + [$proxy]' <<<"$proxies") || return 1
      elif [[ -n "$selected_node" ]]; then return 1
      else log_warn "mihomo 配置已排除无法转换的节点：$id/$user_id。"; fi
    done < <(jq -r --arg user "$selected_user" '.users[]|select(if $user=="" then .enabled else .id==$user end)|.id' <<<"$node")
  done < <(jq -c --arg id "$selected_node" '.nodes[]?|select(if $id=="" then .enabled else .id==$id end)' "$SBM_STATE")
  [[ "$proxies" != '[]' ]] || { log_error '没有可导出的 mihomo 节点。'; return 1; }
  tmp=$(mktemp "$(dirname "$output")/.mihomo-client.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  jq -n --argjson proxies "$proxies" '{"mixed-port":2080,"allow-lan":false,mode:"rule","log-level":"warning",
    proxies:$proxies,"proxy-groups":[{name:"代理选择",type:"select",proxies:($proxies|map(.name))}],rules:["MATCH,代理选择"]}' >"$tmp" || return 1
  chmod 0600 "$tmp" && mv -f "$tmp" "$output" || return 1
  log_ok "已导出 mihomo 客户端配置：$output；JSON 可直接作为 YAML 导入。"
)
