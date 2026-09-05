#!/bin/bash
# End-to-end self check: real crash → real .ips → dSYM symbolication → git suspect.
# Usage: run.sh <repo-root>   (from `make selfcheck`)
set -u
ROOT="$1"
WORK=$(mktemp -d /tmp/coroner-selfcheck.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

echo "== 1/5 mini git repo with the crashing source"
git init -q repo && cd repo
cp "$ROOT/Examples/selfcheck/main.swift" .
git add . && git -c user.email=self@check -c user.name=selfcheck commit -qm "import crashing code"
git tag build/1

echo "== 2/5 build with debug info + dSYM"
# two-step compile keeps the .o around so dsymutil can emit full line tables
swiftc -g -c main.swift -o main.o
swiftc main.o -o selfcheck
mkdir -p dsyms && dsymutil selfcheck -o dsyms/selfcheck.dSYM

echo "== 3/5 crash it — the OS crash reporter writes the .ips"
BEFORE=$(ls ~/Library/Logs/DiagnosticReports/selfcheck-*.ips 2>/dev/null | wc -l | tr -d ' ')
./selfcheck 2>/dev/null; RC=$?
IPS=""
for i in $(seq 1 40); do
  IPS=$(ls -t ~/Library/Logs/DiagnosticReports/selfcheck-*.ips 2>/dev/null | head -1)
  NOW=$(ls ~/Library/Logs/DiagnosticReports/selfcheck-*.ips 2>/dev/null | wc -l | tr -d ' ')
  [ -n "$IPS" ] && [ "$NOW" -gt "$BEFORE" ] && break
  sleep 0.5
done
[ -z "$IPS" ] && { echo "FAIL: no .ips appeared in ~/Library/Logs/DiagnosticReports"; exit 1; }
echo "   crash exit=$RC, report: $(basename "$IPS")"

echo "== 4/5 ingest + symbolicate"
BIN="$ROOT/.build/release/coroner"
"$BIN" --store "$WORK/.coroner" --dsym "$WORK/repo/dsyms" ingest "$IPS" | sed 's/^/   /'
ID=$("$BIN" --store "$WORK/.coroner" top 1 | tail -1 | cut -d' ' -f1)
"$BIN" --store "$WORK/.coroner" show "$ID" | sed -n '1,8p;/top frames/,+3p' | sed 's/^/   /'

echo "== 5/5 suspect via git"
"$BIN" --store "$WORK/.coroner" suspect "$ID" --repo "$WORK/repo" | sed 's/^/   /'

SIG=$("$BIN" --store "$WORK/.coroner" show "$ID" | grep -c 'boom()')
SUS=$("$BIN" --store "$WORK/.coroner" suspect "$ID" --repo "$WORK/repo" | grep -c 'import crashing code')
if [ "$SIG" -ge 1 ] && [ "$SUS" -ge 1 ]; then
  echo "SELF-CHECK PASS — real .ips symbolicated to boom() and git suspect found the commit"
elif [ "$SIG" -ge 1 ]; then
  echo "SELF-CHECK PARTIAL — symbolication ok, suspect missing (check source anchors)"
else
  echo "SELF-CHECK FAIL — no symbolication; is atos/dsymutil ok?"
fi
