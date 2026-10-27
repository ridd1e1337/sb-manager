#!/usr/bin/env bash
set -Eeuo pipefail
: "${SBM_TEST_SING_BOX:?Set SBM_TEST_SING_BOX to a real core}"
source "$(dirname "${BASH_SOURCE[0]}")/feature-fixture.sh"
umask 077
pids=()
client_pid=''
cleanup() {
  [[ -z "$client_pid" ]] || { kill "$client_pid" 2>/dev/null || true; wait "$client_pid" 2>/dev/null || true; }
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  rm -rf "$ROOT"
}
trap cleanup EXIT
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
wait_listener() {
  local pid=$1 port=$2 log=$3
  for _ in {1..50}; do
    kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; return 1; }
    host_port_in_use tcp "$port" && return 0
    sleep 0.1
  done
  cat "$log" >&2
  return 1
}

# Requiring a certificate must remain transactional.
cp "$SBM_STATE" "$ROOT/before.json"
expect_failure node_add anytls --id missing-cert --domain missing.example.test --port "$(free_port)" >"$ROOT/missing.log" 2>&1
grep -q '缺少证书' "$ROOT/missing.log"
cmp "$ROOT/before.json" "$SBM_STATE"

domain=anytls.example.test
mkdir -p "$SBM_CERTS/$domain"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=AnyTLS Test CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -keyout "$ROOT/ca.key" -out "$ROOT/ca.pem" >"$ROOT/openssl.log" 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$domain" \
  -keyout "$SBM_CERTS/$domain/key.pem" -out "$ROOT/server.csr" >>"$ROOT/openssl.log" 2>&1
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' "$domain" >"$ROOT/server.ext"
openssl x509 -req -in "$ROOT/server.csr" -CA "$ROOT/ca.pem" -CAkey "$ROOT/ca.key" -set_serial 1 -days 2 \
  -extfile "$ROOT/server.ext" -out "$SBM_CERTS/$domain/fullchain.pem" >>"$ROOT/openssl.log" 2>&1
port=$(free_port)
node_add anytls --id anytls-test --domain "$domain" --address 127.0.0.1 --port "$port" >/dev/null
node_client_outbound anytls-test >"$ROOT/outbound.json"
jq -e --arg domain "$domain" '.tls.enabled==true and .tls.insecure==false and .tls.server_name==$domain' "$ROOT/outbound.json" >/dev/null
node_share_uri anytls-test | grep -q '&insecure=0&allowInsecure=0#'

# Keep the test listener on loopback without changing the generated source.
jq '.inbounds[].listen="127.0.0.1"' "$SBM_CONFIG" >"$ROOT/server.json"
"$SBM_SING_BOX_BIN" run -c "$ROOT/server.json" >"$ROOT/server.log" 2>&1 &
pids+=("$!")
wait_listener "${pids[0]}" "$port" "$ROOT/server.log"
mkdir "$ROOT/www"
printf 'anytls-certificate-verified\n' >"$ROOT/www/index.html"
origin_port=$(free_port)
python3 -m http.server "$origin_port" --bind 127.0.0.1 --directory "$ROOT/www" >"$ROOT/origin.log" 2>&1 &
pids+=("$!")
wait_listener "${pids[1]}" "$origin_port" "$ROOT/origin.log"

for scenario in trusted untrusted wrong-name; do
  client_port=$(free_port)
  jq --arg ca "$ROOT/ca.pem" --arg scenario "$scenario" --argjson port "$client_port" '
    if $scenario=="untrusted" then . else .tls.certificate_path=$ca end
    | if $scenario=="wrong-name" then .tls.server_name="wrong.example.test" else . end
    | {log:{level:"info"},inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:$port}],outbounds:[.],route:{final:.tag}}
  ' "$ROOT/outbound.json" >"$ROOT/client.json"
  "$SBM_SING_BOX_BIN" check -c "$ROOT/client.json"
  "$SBM_SING_BOX_BIN" run -c "$ROOT/client.json" >"$ROOT/$scenario.log" 2>&1 &
  client_pid=$!
  wait_listener "$client_pid" "$client_port" "$ROOT/$scenario.log"
  if curl --fail --silent --show-error --max-time 8 --noproxy '' --proxy "socks5h://127.0.0.1:$client_port" \
    "http://127.0.0.1:$origin_port/" >"$ROOT/response" 2>"$ROOT/curl.log"; then
    [[ "$scenario" == trusted ]] || { printf 'Unexpected TLS success: %s\n' "$scenario" >&2; exit 1; }
    grep -qx 'anytls-certificate-verified' "$ROOT/response"
  else
    [[ "$scenario" != trusted ]] || { cat "$ROOT/curl.log" "$ROOT/$scenario.log" >&2; exit 1; }
    case "$scenario" in
      untrusted) grep -q 'certificate signed by unknown authority' "$ROOT/$scenario.log" ;;
      wrong-name) grep -q 'certificate is valid for .*not wrong.example.test' "$ROOT/$scenario.log" ;;
    esac
  fi
  kill "$client_pid"; wait "$client_pid" 2>/dev/null || true
  client_pid=''
  printf 'AnyTLS TLS %s: PASS\n' "$scenario"
done
printf 'ANYTLS TLS SMOKE PASSED\n'
