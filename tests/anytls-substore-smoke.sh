#!/usr/bin/env bash
set -Eeuo pipefail
# The caller supplies a verified official Sub-Store bundle; never use host data.
BUNDLE=${SBM_TEST_SUBSTORE_BUNDLE:?Set SBM_TEST_SUBSTORE_BUNDLE to a verified sub-store.bundle.js}
PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(mktemp -d)
pid=''
cleanup() {
  [[ -z "$pid" ]] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  rm -rf "$ROOT"
}
trap cleanup EXIT
source "$PROJECT/lib/common.sh"
source "$PROJECT/protocols/anytls.sh"
mkdir -p "$ROOT/data"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
SUB_STORE_BACKEND_API_HOST=127.0.0.1 SUB_STORE_BACKEND_API_PORT="$port" SUB_STORE_DATA_BASE_PATH="$ROOT/data" \
  node "$BUNDLE" >"$ROOT/backend.log" 2>&1 &
pid=$!
base="http://127.0.0.1:$port"
for _ in {1..50}; do
  kill -0 "$pid" 2>/dev/null || { cat "$ROOT/backend.log" >&2; exit 1; }
  curl --max-time 2 --noproxy '*' -fsS "$base/api/subs" >/dev/null 2>&1 && break
  sleep 0.1
done
for address in 192.0.2.1 2001:db8::1; do
  node=$(jq -n --arg address "$address" '{id:"anytls",name:"AnyTLS test",server_address:$address,domain:"edge.example.test",port:443}')
  # Match random_password's URL-safe alphabet, including on older Sub-Store.
  secret='{"password":"test-password_1234567890"}'
  uri=$(protocol_anytls_share "$node" "$secret")
  jq -n --arg content "$uri" '{name:"anytls",source:"local",content:$content}' >"$ROOT/sub.json"
  curl --max-time 10 --noproxy '*' -fsS -X POST -H 'Content-Type: application/json' \
    --data-binary "@$ROOT/sub.json" "$base/api/subs" | jq -e '.status=="success"' >/dev/null
  curl --max-time 10 --noproxy '*' -fsS "$base/download/anytls?target=JSON&noCache=true" \
    | jq -e 'length==1 and .[0].type=="anytls" and .[0]["skip-cert-verify"]==false and .[0].sni=="edge.example.test"' >/dev/null
  # Reproduce an aggregation override, then verify that DEFAULT preserves
  # the source's explicit certificate verification policy.
  jq -n '{name:"anytls-group",subscriptions:["anytls"],process:[{type:"Quick Setting Operator",args:{scert:"ENABLED"}}]}' >"$ROOT/collection.json"
  curl --max-time 10 --noproxy '*' -fsS -X POST -H 'Content-Type: application/json' \
    --data-binary "@$ROOT/collection.json" "$base/api/collections" | jq -e '.status=="success"' >/dev/null
  curl --max-time 10 --noproxy '*' -fsS "$base/download/collection/anytls-group?target=JSON&noCache=true" \
    | jq -e 'length==1 and .[0]["skip-cert-verify"]==true' >/dev/null
  jq '.process[0].args.scert="DEFAULT"' "$ROOT/collection.json" >"$ROOT/default.json"
  curl --max-time 10 --noproxy '*' -fsS -X PATCH -H 'Content-Type: application/json' \
    --data-binary "@$ROOT/default.json" "$base/api/collection/anytls-group" | jq -e '.status=="success"' >/dev/null
  curl --max-time 10 --noproxy '*' -fsS "$base/download/collection/anytls-group?target=JSON&noCache=true" \
    | jq -e 'length==1 and .[0]["skip-cert-verify"]==false' >/dev/null
  curl --max-time 10 --noproxy '*' -fsS "$base/download/collection/anytls-group?target=V2Ray&noCache=true" | base64 -d >"$ROOT/links"
  # v2rayN 7.18 resolves these aliases before consulting DefAllowInsecure.
  # A missing flag would inherit a potentially insecure client default.
  python3 - "$ROOT/links" "$address" <<'PY'
import sys
from urllib.parse import parse_qs, unquote, urlsplit

links = open(sys.argv[1]).read().splitlines()
assert len(links) == 1
uri = urlsplit(links[0])
query = parse_qs(uri.query)
flags = [query.get(key, [""])[0] for key in ("insecure", "allowInsecure", "allow_insecure")]
assert "1" not in flags and "0" in flags, "Explicit TLS verification lost in Sub-Store conversion"
assert uri.scheme == "anytls" and uri.hostname == sys.argv[2] and uri.port == 443
assert unquote(uri.username) == "test-password_1234567890"
assert query["sni"] == ["edge.example.test"]
PY
  # DEFAULT must also retain a source's explicit opt-out for other use cases.
  jq '.content |= gsub("insecure=0";"insecure=1") | .content |= gsub("allowInsecure=0";"allowInsecure=1")' "$ROOT/sub.json" >"$ROOT/insecure.json"
  curl --max-time 10 --noproxy '*' -fsS -X PATCH -H 'Content-Type: application/json' \
    --data-binary "@$ROOT/insecure.json" "$base/api/sub/anytls" | jq -e '.status=="success"' >/dev/null
  curl --max-time 10 --noproxy '*' -fsS "$base/download/collection/anytls-group?target=JSON&noCache=true" \
    | jq -e 'length==1 and .[0]["skip-cert-verify"]==true' >/dev/null
  curl --max-time 10 --noproxy '*' -fsS -X DELETE "$base/api/sub/anytls" >/dev/null
  curl --max-time 10 --noproxy '*' -fsS -X DELETE "$base/api/collection/anytls-group" >/dev/null
done
printf 'ANYTLS SUBSTORE V2RAY ROUND-TRIP PASSED\n'
