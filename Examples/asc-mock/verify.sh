#!/bin/bash
# Live-verifies the full asc-dsym flow (JWT → HTTP → response parse → zip
# download → extract) against a local mock of the App Store Connect API.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d /tmp/coroner-ascmock.XXXXXX)
trap 'rm -rf "$WORK"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null || true' EXIT

# a real P-256 key in openssl's two-block SEC1 PEM (what openssl ecparam emits)
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/key.pem" 2>/dev/null

# a fake dSYM zip to download
mkdir -p "$WORK/FakeApp.dSYM/Contents/Resources/DWARF"
echo fake > "$WORK/FakeApp.dSYM/Contents/Resources/DWARF/FakeApp"
(cd "$WORK" && zip -qr dsym.zip FakeApp.dSYM)

PORT=$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
/usr/bin/python3 "$ROOT/Examples/asc-mock/server.py" "$PORT" "$WORK/dsym.zip" &
SRV=$!

CORONER_ASC_KEY_ID=TESTKEY CORONER_ASC_ISSUER_ID=TESTISSUER \
CORONER_ASC_KEY_PATH="$WORK/key.pem" CORONER_ASC_API_BASE="http://127.0.0.1:$PORT" \
"$ROOT/.build/release/coroner" asc-dsym --app 123 --build 241 --out "$WORK/out"

[ -f "$WORK/out/bundle-0/FakeApp.dSYM/Contents/Resources/DWARF/FakeApp" ] \
  && echo "ASC-MOCK PASS — JWT, HTTP chain, zip download and extraction all verified"
