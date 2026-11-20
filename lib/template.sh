#!/usr/bin/env bash
# shellcheck shell=bash

node_clone_defaults() {
  local node=$1
  jq '{name,protocol,domain:(.domain // ""),server_address:(.server_address // ""),client_address:(.client_address // ""),
      port,listen,network:(.network // ""),method:(.method // ""),multiplex:(.multiplex // true),ws_path:(.ws_path // ""),
      obfs:(.obfs.type // ""),obfs_min_packet_size:(.obfs.min_packet_size // 512),obfs_max_packet_size:(.obfs.max_packet_size // 1200),disable_chrome_parrot:(.disable_chrome_parrot // false),bbr_profile:(.bbr_profile // ""),brutal_debug:(.brutal_debug // false),obfs_host:(.obfs_host // ""),masquerade:(.masquerade // ""),security:(.security // ""),flow:(.flow // ""),
      handshake_server:(.handshake_server // ""),handshake_port:(.handshake_port // 443),congestion_control:(.congestion_control // .quic_congestion_control // "cubic"),
      strict_mode:(.strict_mode // true),wildcard_sni:(.wildcard_sni // "off"),obfs_mode:(.obfs_mode // "none"),snell_version:(.snell_version // 5),snell_mode:(.snell_mode // "default"),
      metadata:(.metadata // {remark:"",region:"",purpose:"",line:"",tags:[]}),
      singbox:(.singbox // {inbound:{},outbound:{}})}' <<<"$node"
}


node_add_from_defaults() {
  local defaults=$1 id=$2 protocol value address domain port node_name disabled=0 inbound_json outbound_json
  shift 2
  protocol=$(jq -r '.protocol' <<<"$defaults")
  inbound_json=$(jq -c '.singbox.inbound // {}' <<<"$defaults")
  outbound_json=$(jq -c '.singbox.outbound // {}' <<<"$defaults")
  node_name=$(jq -r '.name // ""' <<<"$defaults"); node_name=${node_name:-$id}
  address=$(jq -r '(.server_address // .client_address // "")' <<<"$defaults"); domain=$(jq -r '.domain // ""' <<<"$defaults"); port=$(jq -r '.port' <<<"$defaults")
  local remark region purpose line tags
  remark=$(jq -r '.metadata.remark // ""' <<<"$defaults"); region=$(jq -r '.metadata.region // ""' <<<"$defaults"); purpose=$(jq -r '.metadata.purpose // ""' <<<"$defaults"); line=$(jq -r '.metadata.line // ""' <<<"$defaults"); tags=$(jq -r '.metadata.tags|join(",")' <<<"$defaults")
  local -a args=("$protocol" --id "$id" --name "$node_name" --port "$port" --sing-box-inbound-json "$inbound_json" --sing-box-outbound-json "$outbound_json")
  [[ -n "$address" ]] && args+=(--address "$address")
  [[ -n "$domain" ]] && args+=(--domain "$domain")
  case "$protocol" in
    socks|http|mixed) args+=(--listen "$(jq -r '.listen' <<<"$defaults")");;
    vmess-ws-cf) [[ -n $(jq -r '.ws_path // ""' <<<"$defaults") ]] && args+=(--path "$(jq -r '.ws_path' <<<"$defaults")");;
    shadowsocks) args+=(--method "$(jq -r '.method' <<<"$defaults")" --network "$(jq -r '.network' <<<"$defaults")"); [[ $(jq -r '.multiplex' <<<"$defaults") == true ]] || args+=(--no-mux);;
    hysteria2) [[ -n $(jq -r '.obfs // ""' <<<"$defaults") ]] && args+=(--obfs "$(jq -r '.obfs' <<<"$defaults")"); [[ $(jq -r '.obfs' <<<"$defaults") == gecko ]] && args+=(--obfs-min-packet-size "$(jq -r '.obfs_min_packet_size' <<<"$defaults")" --obfs-max-packet-size "$(jq -r '.obfs_max_packet_size' <<<"$defaults")"); [[ $(jq -r '.disable_chrome_parrot' <<<"$defaults") == true ]] && args+=(--disable-chrome-parrot); [[ -n $(jq -r '.bbr_profile' <<<"$defaults") ]] && args+=(--bbr-profile "$(jq -r '.bbr_profile' <<<"$defaults")"); [[ $(jq -r '.brutal_debug' <<<"$defaults") == true ]] && args+=(--brutal-debug); [[ -n $(jq -r '.masquerade // ""' <<<"$defaults") ]] && args+=(--masquerade "$(jq -r '.masquerade' <<<"$defaults")");;
    vless) args+=(--security "$(jq -r '.security' <<<"$defaults")" --handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")");;
    naive) args+=(--network "$(jq -r '.network' <<<"$defaults")");;
    shadowtls) args+=(--handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")" --strict-mode "$(jq -r '.strict_mode' <<<"$defaults")" --wildcard-sni "$(jq -r '.wildcard_sni' <<<"$defaults")");;
    snell) args+=(--snell-version "$(jq -r '.snell_version' <<<"$defaults")" --snell-mode "$(jq -r '.snell_mode' <<<"$defaults")"); [[ $(jq -r '.snell_version' <<<"$defaults") != 5 ]] || args+=(--obfs "$(jq -r '.obfs_mode' <<<"$defaults")" --obfs-host "$(jq -r '.obfs_host' <<<"$defaults")");;
    tuic) args+=(--congestion-control "$(jq -r '.congestion_control' <<<"$defaults")");;
  esac
  while (($#)); do
    case "$1" in
      --name|--port|--address|--domain|--remark|--region|--purpose|--line|--tags|--sing-box-inbound-json|--inbound-json|--sing-box-outbound-json|--outbound-json)
        value=${2:?缺少参数值}
        case "$1" in
          --name) node_name=$value;; --port) port=$value;; --address) address=$value;; --domain) domain=$value;;
          --remark) remark=$value;; --region) region=$value;; --purpose) purpose=$value;; --line) line=$value;; --tags) tags=$value;;
          --sing-box-inbound-json|--inbound-json) inbound_json=$(node_json_argument "$value"); node_validate_json_object 'sing-box inbound JSON' "$inbound_json";;
          --sing-box-outbound-json|--outbound-json) outbound_json=$(node_json_argument "$value"); node_validate_json_object 'sing-box outbound JSON' "$outbound_json";;
        esac
        shift 2;;
      --disabled) disabled=1; shift;; *) die "模板创建不支持参数：$1";;
    esac
  done
  # Rebuild common overrides after parsing so no user value is silently lost.
  args=("$protocol" --id "$id" --name "$node_name" --port "$port" --sing-box-inbound-json "$inbound_json" --sing-box-outbound-json "$outbound_json")
  [[ -n "$address" ]] && args+=(--address "$address"); [[ -n "$domain" ]] && args+=(--domain "$domain")
  case "$protocol" in
    socks|http|mixed) args+=(--listen "$(jq -r '.listen' <<<"$defaults")");;
    vmess-ws-cf) args+=(--path "$(jq -r '.ws_path' <<<"$defaults")");; shadowsocks) args+=(--method "$(jq -r '.method' <<<"$defaults")" --network "$(jq -r '.network' <<<"$defaults")"); [[ $(jq -r '.multiplex' <<<"$defaults") == true ]] || args+=(--no-mux);;
    hysteria2) [[ -n $(jq -r '.obfs' <<<"$defaults") ]] && args+=(--obfs "$(jq -r '.obfs' <<<"$defaults")"); [[ $(jq -r '.obfs' <<<"$defaults") == gecko ]] && args+=(--obfs-min-packet-size "$(jq -r '.obfs_min_packet_size' <<<"$defaults")" --obfs-max-packet-size "$(jq -r '.obfs_max_packet_size' <<<"$defaults")"); [[ $(jq -r '.disable_chrome_parrot' <<<"$defaults") == true ]] && args+=(--disable-chrome-parrot); [[ -n $(jq -r '.bbr_profile' <<<"$defaults") ]] && args+=(--bbr-profile "$(jq -r '.bbr_profile' <<<"$defaults")"); [[ $(jq -r '.brutal_debug' <<<"$defaults") == true ]] && args+=(--brutal-debug); [[ -n $(jq -r '.masquerade' <<<"$defaults") ]] && args+=(--masquerade "$(jq -r '.masquerade' <<<"$defaults")");;
    vless) args+=(--security "$(jq -r '.security' <<<"$defaults")"); [[ -n $(jq -r '.flow // ""' <<<"$defaults") ]] && args+=(--flow "$(jq -r '.flow' <<<"$defaults")"); [[ $(jq -r '.security' <<<"$defaults") != reality ]] || args+=(--handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")");;
    naive) args+=(--network "$(jq -r '.network' <<<"$defaults")" --congestion-control "$(jq -r '.congestion_control' <<<"$defaults")");; shadowtls) args+=(--handshake-server "$(jq -r '.handshake_server' <<<"$defaults")" --handshake-port "$(jq -r '.handshake_port' <<<"$defaults")" --strict-mode "$(jq -r '.strict_mode' <<<"$defaults")" --wildcard-sni "$(jq -r '.wildcard_sni' <<<"$defaults")");; snell) args+=(--snell-version "$(jq -r '.snell_version' <<<"$defaults")" --snell-mode "$(jq -r '.snell_mode' <<<"$defaults")"); [[ $(jq -r '.snell_version' <<<"$defaults") != 5 ]] || args+=(--obfs "$(jq -r '.obfs_mode' <<<"$defaults")" --obfs-host "$(jq -r '.obfs_host' <<<"$defaults")");; tuic) args+=(--congestion-control "$(jq -r '.congestion_control' <<<"$defaults")");;
  esac
  args+=(--remark "$remark" --region "$region" --purpose "$purpose" --line "$line" --tags "$tags")
  (( disabled == 0 )) || args+=(--disabled)
  node_add "${args[@]}"
}

node_clone() {
  local src=${1:?用法：sb node clone SRC_ID NEW_ID [--port N] [--name NAME] [--domain DOMAIN]} id=${2:?缺少新节点 ID} node port
  shift 2
  node=$(state_get_node "$src"); [[ -n "$node" ]] || die "节点不存在：$src"
  port=$(node_choose_port "$(node_transport_kinds "$node" | head -1)") || return 1
  node_add_from_defaults "$(node_clone_defaults "$node")" "$id" --port "$port" --name "$(jq -r '.name' <<<"$node") copy" "$@"
}
