#!/usr/bin/env bash
# Proof of pgvigil on macOS (GitHub's macos-15 = Apple silicon and macos-15-intel = x86_64 runners, or a Mac by hand):
# the binary built from this tree, PostgreSQL 18 from Homebrew as both the repository and one monitored instance,
# install, the collections, serve, every page's API read, the UI in the machine's Google Chrome, the collector under
# launchd for one round, uninstall. macOS's own bash 3.2 and BSD tools; no Docker, no cloud, no secret: every password
# is made here for this run. Run from the tree's root: scripts/proof-macos.sh [<shots folder>]
#
# Needs: go (the tree's go.mod), Homebrew, python3, curl, node 22+ (the UI walk; none = that row is NOT PROVEN), sudo
# without a password (install, launchd, uninstall: a GitHub runner has it). Leaves nothing: the PostgreSQL data folder,
# the LaunchDaemon and the installed files are removed on every exit.
#
# Expected (written before the first run, 2026-11-15):
#   M1 build    CGO_ENABLED=0 go build -trimpath: a Mach-O binary of this machine's CPU; 'pgvigil version' says darwin
#   M2 store    postgresql@18 from Homebrew (its version read back), a cluster made here (scram-sha-256, a generated
#               superuser password, pg_stat_statements preloaded) on 127.0.0.1 at a free port
#   M3 install  'sudo pgvigil install' as cmd/pgvigil/service_other.go does it: /usr/local/bin/pgvigil (this build's
#               sha256) and /usr/local/etc/pgvigil/pgvigil.yaml (0640), the line 'no service manager is wired on this
#               system', exit 0; then the installed binary: migrate (twice: nothing to apply the second time), a UI user
#   M4 collect  the cluster as one instance through a pg_monitor login (a generated password): 'collect' once, then
#               'run' for 4 minutes; every collection's last status ok or skipped (each skip with its note printed),
#               NO error, at least 20 ok
#   M5 serve    'serve' on loopback, the UI login 200; every GET route of internal/web without a path parameter, with
#               ?instance=<the instance>: no 5xx and none unanswered, every body that says application/json parses (any
#               other answer listed: a 4xx of a route needing another parameter, a SQL Server download's XML);
#               'report' writes its zip with mode 0600
#   M6 UI       the machine's Google Chrome headless: every root tab and every tab of the instance (the page's own tab
#               list), each rendered, no error on it, each of its /api reads 2xx; the Summary shot in both themes
#   M7 launchd  a LaunchDaemon of this run's own (not a product file: README's 'run pgvigil run under launchd') runs
#               'pgvigil run' as this user: launchctl says running, a collection round lands newer than before it,
#               booted out and gone
#   M8 remove   'sudo pgvigil uninstall -purge': the binary and the config folder gone; the cluster stopped and removed
# NOT PROVEN here: SQL Server targets from a Mac (no Docker on the runners, no lab); a long run (minutes, not days); a
# launchd service shipped by pgvigil (none: README, the binary and the config template only); Gatekeeper and
# notarization of a downloaded release asset (the binary is built here, never quarantined); the release's own
# cross-compiled darwin assets (a native CGO_ENABLED=0 build of the same tree); macOS 14 and 26; 'serve -open' on a
# desktop; Kerberos; 'uninstall -all' (documented for Linux and Windows only).
set -euo pipefail
cd "$(dirname "$0")/.."
SHOTS=${1:-}
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
[ "$(uname -s)" = Darwin ] || fail "not macOS ($(uname -s))"
for t in go brew python3 curl shasum; do command -v "$t" >/dev/null || fail "needs $t"; done
W=$(mktemp -d "${TMPDIR:-/tmp}/pgvmac.XXXXXX"); PLIST=/Library/LaunchDaemons/com.pgvigil.proof.plist
SRV=; RUNP=; PGD=; CHR=; INSTALLED=
cleanup() {
  [ -n "$CHR" ] && kill "$CHR" 2>/dev/null || true
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true
  [ -n "$RUNP" ] && kill "$RUNP" 2>/dev/null || true
  if [ -e "$PLIST" ]; then sudo launchctl bootout system/com.pgvigil.proof 2>/dev/null || true; sudo rm -f "$PLIST"; fi
  [ -n "$INSTALLED" ] && [ -e /usr/local/bin/pgvigil ] && { sudo /usr/local/bin/pgvigil uninstall -purge >/dev/null 2>&1 || true; }
  [ -n "$PGD" ] && { "$PGBIN/pg_ctl" -D "$PGD" -m immediate stop >/dev/null 2>&1 || true; }
  rm -rf "$W"
}
trap cleanup EXIT
gen() { python3 -c 'import secrets; print("Pv9" + secrets.token_hex(12))'; }
mask() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$1" || true; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

echo "== M1. build ($(uname -m), macOS $(sw_vers -productVersion))"
CGO_ENABLED=0 go build -trimpath -o "$W/pgvigil" ./cmd/pgvigil || fail "M1: go build"
ARCH=$(uname -m); FILE=$(file -b "$W/pgvigil")
case $ARCH:$FILE in arm64:*"Mach-O 64-bit executable arm64"* | x86_64:*"Mach-O 64-bit executable x86_64"*) ;; *) fail "M1: $ARCH, but the binary is: $FILE" ;; esac
VER=$("$W/pgvigil" version 2>&1 | head -1)
case $VER in *darwin/*) ;; *) fail "M1: pgvigil version says '$VER'" ;; esac
SHA=$(shasum -a 256 "$W/pgvigil" | cut -c1-64)
ok "M1: $FILE; $VER; sha256 $SHA"

echo "== M2. PostgreSQL 18 from Homebrew"
brew list postgresql@18 >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 brew install postgresql@18 >"$W/brew.log" 2>&1 || { tail -20 "$W/brew.log"; fail "M2: brew install postgresql@18"; }
PGBIN="$(brew --prefix postgresql@18)/bin"; export PATH="$PGBIN:$PATH"
PGV=$("$PGBIN/postgres" --version)
SUPW=$(gen); mask "$SUPW"; printf '%s\n' "$SUPW" > "$W/supw"; chmod 600 "$W/supw"
PGD=$W/pgdata; PGPORT_=$(freeport)
"$PGBIN/initdb" -D "$PGD" -U postgres -A scram-sha-256 --pwfile="$W/supw" >"$W/initdb.log" 2>&1 || { tail -20 "$W/initdb.log"; fail "M2: initdb"; }
"$PGBIN/pg_ctl" -D "$PGD" -l "$W/pg.log" -w -o "-p $PGPORT_ -k $W -c listen_addresses=127.0.0.1 -c shared_preload_libraries=pg_stat_statements" start >/dev/null || { tail -20 "$W/pg.log"; fail "M2: pg_ctl start"; }
export PGPASSWORD="$SUPW"
ADMIN="host=127.0.0.1 port=$PGPORT_ user=postgres dbname=postgres"
psql "$ADMIN" -XAtqc "CREATE EXTENSION pg_stat_statements" >/dev/null
ok "M2: $PGV on 127.0.0.1:$PGPORT_ ($(psql "$ADMIN" -XAtc 'show server_version'))"

echo "== M3. install, migrate, a UI user"
sudo "$W/pgvigil" install >"$W/install.out" 2>&1 || { cat "$W/install.out"; fail "M3: sudo pgvigil install"; }
INSTALLED=1
grep -q 'no service manager is wired on this system' "$W/install.out" || { cat "$W/install.out"; fail "M3: install did not say 'no service manager is wired on this system'"; }
[ "$(shasum -a 256 /usr/local/bin/pgvigil | cut -c1-64)" = "$SHA" ] || fail "M3: /usr/local/bin/pgvigil is not this build"
MODE=$(sudo stat -f '%Lp' /usr/local/etc/pgvigil/pgvigil.yaml 2>/dev/null || echo none)
[ "$MODE" = 640 ] || fail "M3: /usr/local/etc/pgvigil/pgvigil.yaml mode $MODE (want 640)"
BIN=/usr/local/bin/pgvigil
psql "$ADMIN" -XAtqc "CREATE DATABASE pgvigil" >/dev/null
MONPW=$(gen); mask "$MONPW"
psql "$ADMIN" -XAtq -c "CREATE ROLE pgvmon LOGIN PASSWORD '$MONPW' IN ROLE pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$PGPORT_ user=postgres password=$SUPW dbname=pgvigil sslmode=disable"
export PGVIGIL_MAC_DSN="host=127.0.0.1 port=$PGPORT_ user=pgvmon password=$MONPW dbname=postgres sslmode=disable"
CFG=$W/pgvigil.yaml
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: mac-pg\n    dsn: env:PGVIGIL_MAC_DSN\n    tags: [macos]\n' > "$CFG"; chmod 600 "$CFG"
"$BIN" migrate -config "$CFG" >"$W/migrate1.out" 2>&1 || { tail -20 "$W/migrate1.out"; fail "M3: migrate"; }
"$BIN" migrate -config "$CFG" >"$W/migrate2.out" 2>&1 || { tail -20 "$W/migrate2.out"; fail "M3: the second migrate"; }
UIPW=$(gen); mask "$UIPW"
PGVIGIL_PASSWORD="$UIPW" "$BIN" user add -config "$CFG" proofmac >/dev/null 2>&1 || fail "M3: user add"
q() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
ok "M3: installed (/usr/local/bin/pgvigil = this build, the template 0640, 'no service manager is wired'); migrated twice; UI user proofmac"

echo "== M4. the collections"
"$BIN" collect -config "$CFG" >"$W/collect.out" 2>&1 || { tail -30 "$W/collect.out"; fail "M4: collect"; }
IID=$(q "SELECT instance_id FROM pgvigil.instances WHERE name = 'mac-pg'")
[ -n "$IID" ] || fail "M4: no instance row for mac-pg"
"$BIN" run -config "$CFG" >"$W/run.out" 2>&1 & RUNP=$!
sleep 240
kill "$RUNP" 2>/dev/null || true; wait "$RUNP" 2>/dev/null || true; RUNP=
q "SELECT collection || '|' || status || '|' || coalesce(note, '') FROM pgvigil.collection_dates WHERE instance_id = $IID ORDER BY collection" > "$W/status.txt"
NOK=$(grep -c '|ok|' "$W/status.txt" || true); NSK=$(grep -c '|skipped|' "$W/status.txt" || true)
grep '|skipped|' "$W/status.txt" | sed 's/^/  skipped: /' || true
if grep -vE '\|(ok|skipped)\|' "$W/status.txt" | grep -q .; then grep -vE '\|(ok|skipped)\|' "$W/status.txt" | sed 's/^/  NOT ok: /'; fail "M4: a collection ended other than ok or skipped (above)"; fi
[ "$NOK" -ge 20 ] || fail "M4: only $NOK collections ok"
ok "M4: $NOK collections ok, $NSK skipped (each above with its note), none in error ($(wc -l < "$W/status.txt" | tr -d ' ') read)"

echo "== M5. serve, every page's API read, the report"
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >"$W/serve.log" 2>&1 & SRV=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" && break; sleep 0.1; done
printf '{"username":"proofmac","password":"%s"}' "$UIPW" > "$W/login.json"
[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$W/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$W/login.json" "$U/api/login")" = 200 ] || fail "M5: the UI login"
rm -f "$W/login.json"
grep -hoE 'HandleFunc\("GET /api/[^"{ ]+"' internal/web/*.go | sed -E 's/.*"GET (\/api\/[^"]+)"/\1/' | sort -u > "$W/routes.txt"
[ "$(wc -l < "$W/routes.txt")" -ge 30 ] || fail "M5: only $(wc -l < "$W/routes.txt") GET routes read from internal/web"
: > "$W/api.txt"
while read -r r; do
  cw=$(curl -s -o "$W/body" -w '%{http_code} %{content_type}' -b "$W/cj" -H 'X-Pgvigil: 1' --max-time 60 "$U$r?instance=$IID") || cw="000 none"
  c=${cw%% *}; ct=${cw#* }; ct=${ct%%;*}; [ -n "$ct" ] || ct=none
  if [ "$ct" = application/json ]; then j=$(python3 -c 'import json, sys; json.load(open(sys.argv[1])); print("json")' "$W/body" 2>/dev/null || echo "BAD-json"); else j=$ct; fi
  echo "$c $j $r" >> "$W/api.txt"
done < "$W/routes.txt"
awk '{print $1}' "$W/api.txt" | sort | uniq -c | sed 's/^/  status /'
if grep -E '^(5[0-9][0-9]|000) ' "$W/api.txt"; then fail "M5: a route answered 5xx or nothing (above)"; fi
if grep -E ' BAD-json ' "$W/api.txt"; then fail "M5: a body that says application/json does not parse (above)"; fi
grep -vE '^200 json ' "$W/api.txt" | sed 's/^/  not 200 json: /' || true
(cd "$W" && "$BIN" report -config "$CFG" -out "$W/report.zip" >/dev/null 2>&1) || fail "M5: report"
RMODE=$(stat -f '%Lp' "$W/report.zip"); [ "$RMODE" = 600 ] || fail "M5: the report zip's mode $RMODE (want 600)"
ok "M5: serve on $PORT, the login 200; $(wc -l < "$W/routes.txt" | tr -d ' ') GET routes read: $(grep -c '^200 ' "$W/api.txt") 200, none 5xx, every JSON body parsed (the others listed above); the report zip 0600"

echo "== M6. the UI in the machine's Google Chrome"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then echo "NOT PROVEN: M6: no Google Chrome on this machine"
elif ! command -v node >/dev/null || [ "$(node -e 'console.log(typeof WebSocket)')" != function ]; then echo "NOT PROVEN: M6: no node with WebSocket (22+)"
else
  CDPP=$(freeport)
  "$CHROME" --headless=new --remote-debugging-port="$CDPP" --user-data-dir="$W/chrome" --no-first-run --disable-gpu --window-size=1500,1000 about:blank >"$W/chrome.log" 2>&1 & CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDPP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  mkdir -p "${SHOTS:-$W/shots}"
  cat > "$W/walk.mjs" <<'JS'
const [port, U, iid, shots] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); const api = [];
ws.addEventListener('message', m => { const d = JSON.parse(m.data);
  if (d.method === 'Network.responseReceived' && d.params.response.url.includes('/api/')) api.push([d.params.response.status, d.params.response.url]);
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 80; i++) { if (await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^Loading/.test(e.textContent)) && m.children.length > 0; })()`)) { await sleep(500); return true; } await sleep(150); } return false; };
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
console.log(`login ${await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: 'proofmac', password: ${JSON.stringify(process.env.W_UIPW)} }) }).then(r => r.status)`, true)}`);
const tabsOf = async (hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200); await cmd('Page.navigate', { url: U + hash }); await settled();
  return await ev(`(() => { const t = document.querySelector('#tabs'); return !t ? [] : t.dataset.all ? JSON.parse(t.dataset.all) : [...t.querySelectorAll('a')].map(a => a.getAttribute('href')); })()`); };
const pages = [...new Set([...(await tabsOf('#/summary')), ...(await tabsOf(`#/summary?i=${iid}`)).map(t => t.replace(/i=\d+/, `i=${iid}`))])];
let bad = 0;
for (const p of pages) {
  api.length = 0;
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150);
  await cmd('Page.navigate', { url: U + p }); const r = await settled();
  const errs = await ev(`document.querySelectorAll('main .error:not([role=status])').length`);
  const off = api.filter(([s]) => s < 200 || s > 299);
  if (!r || errs > 0 || off.length) { bad++; console.log(`page ${p} rendered=${r} errors=${errs} api-off=${JSON.stringify(off.slice(0, 3))}`); }
}
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150); await cmd('Page.navigate', { url: U + `#/summary?i=${iid}` }); await settled();
  const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/macos-summary-${theme}.png`, Buffer.from(d.result.data, 'base64'));
}
console.log(`pages ${pages.length} bad ${bad}`);
ws.close(); process.exit(0);
JS
  OUT=$(W_UIPW="$UIPW" node "$W/walk.mjs" "$CDPP" "$U/" "$IID" "${SHOTS:-$W/shots}") || fail "M6: the walk stopped: $OUT"
  echo "$OUT"
  echo "$OUT" | grep -q '^login 200$' || fail "M6: the page's login"
  NP=$(echo "$OUT" | sed -n 's/^pages \([0-9]*\) bad \([0-9]*\)$/\1 \2/p')
  [ -n "$NP" ] && [ "${NP#* }" = 0 ] && [ "${NP% *}" -ge 10 ] || fail "M6: pages / bad = '$NP' (want 10 or more pages, 0 bad)"
  kill "$CHR" 2>/dev/null || true; CHR=
  ok "M6: Google Chrome $("$CHROME" --version 2>/dev/null | sed 's/Google Chrome //'): ${NP% *} pages (every root tab and the instance's), each rendered, no error, every /api read 2xx; the Summary in both themes shot"
fi
kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; SRV=

echo "== M7. the collector under launchd (one round)"
B4=$(q "SELECT coalesce(max(snapshot_at), '-infinity')::text FROM pgvigil.collection_dates WHERE instance_id = $IID")
cat > "$W/plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.pgvigil.proof</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>run</string><string>-config</string><string>$W/launchd.yaml</string></array>
  <key>UserName</key><string>$(id -un)</string>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$W/launchd.log</string>
</dict></plist>
EOF
# launchd passes no environment of this shell: the daemon's config names the two connections itself (a file of this
# run's, 0600, its generated passwords only)
printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: mac-pg\n    dsn: "%s"\n    tags: [macos]\n' "$PGVIGIL_REPO_DSN" "$PGVIGIL_MAC_DSN" > "$W/launchd.yaml"; chmod 600 "$W/launchd.yaml"
plutil -lint "$W/plist" >/dev/null || fail "M7: the plist does not lint"
sudo cp "$W/plist" "$PLIST"; sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
sudo launchctl bootstrap system "$PLIST" || fail "M7: launchctl bootstrap"
STATE=; NEWER=
for _ in $(seq 1 36); do
  sleep 5
  STATE=$(sudo launchctl print system/com.pgvigil.proof 2>/dev/null | sed -n 's/^[[:space:]]*state = //p' | head -1)
  NEWER=$(q "SELECT count(*) FROM pgvigil.collection_dates WHERE instance_id = $IID AND snapshot_at > '$B4'::timestamptz")
  [ "$STATE" = running ] && [ "${NEWER:-0}" -ge 1 ] && break
done
[ "$STATE" = running ] || { tail -20 "$W/launchd.log" 2>/dev/null; fail "M7: launchd state '$STATE' (want running)"; }
[ "${NEWER:-0}" -ge 1 ] || { tail -20 "$W/launchd.log" 2>/dev/null; fail "M7: no collection newer than $B4 under launchd"; }
sudo launchctl bootout system/com.pgvigil.proof || fail "M7: launchctl bootout"
sudo rm -f "$PLIST"; sleep 2
! sudo launchctl print system/com.pgvigil.proof >/dev/null 2>&1 || fail "M7: the daemon is still loaded after the bootout"
ok "M7: launchd ran 'pgvigil run' as $(id -un) (state running; $NEWER collection(s) newer than before it); booted out, the plist removed"

echo "== M8. uninstall"
sudo "$BIN" uninstall -purge >"$W/uninstall.out" 2>&1 || { cat "$W/uninstall.out"; fail "M8: sudo pgvigil uninstall -purge"; }
[ ! -e /usr/local/bin/pgvigil ] || fail "M8: /usr/local/bin/pgvigil is still there"
[ ! -e /usr/local/etc/pgvigil ] || fail "M8: /usr/local/etc/pgvigil is still there ($(ls -A /usr/local/etc/pgvigil | tr '\n' ' '))"
INSTALLED=
"$PGBIN/pg_ctl" -D "$PGD" -m fast stop >/dev/null || fail "M8: pg_ctl stop"; PGD=
ok "M8: uninstall -purge removed the binary and the config folder; the cluster stopped (its folder goes with this run's)"
echo "NOT PROVEN (no lab, or nothing to run here): SQL Server targets from a Mac; a long run; a launchd service shipped by pgvigil (none); Gatekeeper and notarization of a downloaded release asset; the release's cross-compiled darwin assets themselves; macOS 14 and 26; serve -open on a desktop; Kerberos; uninstall -all on macOS (documented for Linux and Windows only)"
echo "proof-macos: OK ($ARCH)"
