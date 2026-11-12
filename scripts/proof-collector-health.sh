#!/usr/bin/env bash
# proof-collector-health.sh - task 201: the collector seen working (migration 0121, internal/collect/heartbeat.go, the
# Collector page). Needs: docker (a systemd container: --privileged, cgroup v2), psql, curl, python3, node, chromium,
# go and npm (unless PGVIGIL_BIN names a built binary with the web UI in it).
#
# The rig: a docker network with a repository (PostgreSQL 18), a target server (PostgreSQL 18: four databases, four
# logins: the instances t1-t4) and a Debian container running systemd, its hostname pgvigil-svc, where pgvigil runs as
# the shipped unit deploy/pgvigil.service (a drop-in only makes the alert spool writable). On this host: `pgvigil serve`
# (its collector watchdog on) and the checks. Every alert goes to a file channel (critical, sent once, cleared at once)
# whose directory both write.
#   A  the heartbeat: a 'systemd unit' collector on pgvigil-svc is up; each instance's runs counted (connections per
#      minute, runs, no failure); every collection's runs, rows and durations; the repository part answers
#   E  a login refused: t2's password changed at the source - t2's 'logins refused' counted; exactly ONE alert on the
#      channel that covers t2 ('authentication failing': the runs that failed at the connect build no 'collection
#      failing'), none on the channel scoped to t1, no 'collector or network'; the service restarted while t2 is still
#      refused: no alert key fired twice, nothing resolved; the password back and the service restarted again: t2's
#      'authentication failing' gone and resolved once, its 'collection failing' within t1's (the plain target's own:
#      some collections fail on every plain target)
#   H  the page: #/collector in both themes (shots), every link on it clicked with its landing (an instance link opens
#      its Collection dates with the collector's line, the line's link comes back), the tree's Collector node, the
#      chart's menu
#   D  failing together (t1-t3 run 'activity' every 10 s; every cut is refused logins - t1-t4 are four databases of
#      one server, so dropped packets for some of them cannot be made here; the cut's second is pinned; the files are
#      counted before and after the lift; each case's spool is kept under .vis/spool-evidence/<case>):
#      D1  t1-t3 cut at :20 for 6 min: the parent once on U (unscoped) and S (scoped to t1) within the cut + 3:05, t1-t3
#          nothing; after the lift the parent resolved once, t1-t3 nothing. D1b the same cut at :55 for 4 min.
#      D2  t1-t3 cut :10 to :50 of one minute: nothing sent, nothing resolved.
#      D3  t1, t2 cut (2 of 4): no parent; 'authentication failing' once each (S: t1 once) within the cut + 2:05; no
#          'collection failing'; resolved once each after.
#      D4  t1 refused first (its alert open on U, S and R - R repeats every 5 min), then t2, t3: during the hold R
#          repeats the parent and not t1, nothing resolves; after the lift t1 resolved once.
#      D5  t1-t3 cut, t1 t2 back, t3 kept: the parent resolves; t3's 'authentication failing' once, within 2 alert
#          passes of the parent leaving collector_parent; t1, t2 nothing.
#      DQ  a channel Q in quiet hours from the cut's minute - 1 to its minute + 3: the parent once on Q after the quiet
#          end, t1-t3 nothing.
#   F  many collectors: a second `pgvigil run` on this host collecting the same instances is not refused (the page: 2
#      up); each instance 'collected by more than one collector'
#   B  the service stopped: the page says stopped at once; after 5 minutes 'collector or network' (collector not seen),
#      and serve's watchdog sends it (the collector that would is the one stopped); started again: up, cleared
#   G  purge: 'purge not run in 2 days' on an instance seen 3 days ago; `pgvigil purge` records its run (an old
#      partition dropped and named); the finding gone
# PROOF_ONLY=E,D1,... runs the rig, A and the named cases only (A E H D1 D1b D2 D3 D4 D5 DQ F B G); unset = all.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .vis/spool-evidence .vis/collector-shots   # fetched back by the box job even when no case wrote to them
WORK=$(mktemp -d); FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
want() { [[ -z "${PROOF_ONLY:-}" || ",${PROOF_ONLY// /}," == *",$1,"* ]]; }
fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
RP=$(fp); TP=$(fp); SP=$(fp); CDP=$(fp)
NET=pgvch-$$; REPO=pgvch-repo-$$; TGT=pgvch-tgt-$$; SVC=pgvch-svc-$$; IMG=pgvigil-proof-systemd:1
SRV=""; CHR=""; SECOND=""
cleanup() {
  [[ -n "$CHR" ]] && kill -- -"$CHR" 2>/dev/null || true
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SECOND" ]] && kill "$SECOND" 2>/dev/null || true
  docker rm -f -v "$SVC" "$TGT" "$REPO" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  for c in "$SVC" "$TGT" "$REPO"; do docker inspect "$c" >/dev/null 2>&1 && echo "container $c LEFT"; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- the binary ----------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$PGVIGIL_BIN; else
  (cd web && npm ci --silent --no-audit --no-fund >/dev/null 2>&1 && npm run build >"$WORK/web.log" 2>&1) || { tail -20 "$WORK/web.log"; exit 1; }
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil
fi
cp "$BIN" "$WORK/pgvigil.bin"

# ---- the rig -------------------------------------------------------------------------------------------------------
docker network create "$NET" >/dev/null
docker run -d --name "$REPO" --network "$NET" --network-alias repo -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 >/dev/null
docker run -d --name "$TGT" --network "$NET" --network-alias target -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$TP:5432" postgres:18 >/dev/null
RDSN="host=127.0.0.1 port=$RP user=postgres password=$PW sslmode=disable"
TDSN="host=127.0.0.1 port=$TP user=postgres password=$PW sslmode=disable dbname=postgres"
for d in "$RDSN dbname=postgres" "$TDSN"; do for _ in $(seq 1 60); do psql "$d" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done; done; sleep 3
psql "$RDSN dbname=postgres" -XAtqc "create database pgvigil" >/dev/null
for n in 1 2 3 4; do psql "$TDSN" -Xq -v ON_ERROR_STOP=1 -c "create role l$n login password 'p$n' in role pg_monitor" -c "create database db$n owner l$n" >/dev/null; done
q() { psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  mkdir -p "$WORK/img"
  cat > "$WORK/img/Dockerfile" <<'EOF'
FROM debian:trixie-slim
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd systemd-sysv ca-certificates >/dev/null \
 && rm -rf /var/lib/apt/lists/* && useradd -r -s /usr/sbin/nologin pgvigil
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
EOF
  docker build -q -t "$IMG" "$WORK/img" >/dev/null || { echo "FAIL the systemd image did not build"; exit 1; }
fi
mkdir -p "$WORK/spool" "$WORK/spool2" "$WORK/spool3" "$WORK/spool4"; chmod 0711 "$WORK"; chmod 0777 "$WORK"/spool*   # the service's user walks through the folder (not reads it)
instances() { # $1 host, $2 port
  for n in 1 2 3 4; do printf '  - name: t%s\n    dsn: "host=%s port=%s user=l%s password=p%s dbname=db%s sslmode=disable"\n' "$n" "$1" "$2" "$n" "$n" "$n"
    if (( n < 4 )); then printf '    schedules: {activity: 10s}\n'; fi; done
}
# the service sees this folder as /work (systemd mounts a tmpfs over /tmp in the container)
alerts_of() { printf 'alerts:\n  - {name: spool, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, file: {dir: %s/spool}}\n  - {name: scoped, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, instances: [t1], file: {dir: %s/spool2}}\n  - {name: rep, kind: file, min_severity: critical, repeat: 5m, clear_after: 0, file: {dir: %s/spool3}}\n' "$1" "$1" "$1"
  [[ -n "${QUIET:-}" ]] && printf '  - {name: quiet, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, quiet_hours: "%s", timezone: UTC, file: {dir: %s/spool4}}\n' "$QUIET" "$1"; true; }
{ printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances target 5432; alerts_of /work; } > "$WORK/svc.yaml"
{ printf 'repository:\n  dsn: "%s dbname=pgvigil"\ninstances:\n' "$RDSN"; instances 127.0.0.1 "$TP"; alerts_of "$WORK"; } > "$WORK/host.yaml"
"$BIN" migrate -config "$WORK/host.yaml" >"$WORK/migrate.out" 2>&1 || { cat "$WORK/migrate.out"; exit 1; }

docker run -d --name "$SVC" --hostname pgvigil-svc --network "$NET" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock -v "$WORK:/work" "$IMG" >/dev/null
for _ in $(seq 1 30); do docker exec "$SVC" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
docker exec "$SVC" sh -c "install -m 0755 /work/pgvigil.bin /usr/local/bin/pgvigil && mkdir -p /etc/pgvigil /etc/systemd/system/pgvigil.service.d \
  && install -m 0640 -g pgvigil /work/svc.yaml /etc/pgvigil/pgvigil.yaml && touch /etc/pgvigil/pgvigil.env"
docker cp deploy/pgvigil.service "$SVC:/etc/systemd/system/pgvigil.service"
docker exec "$SVC" sh -c "printf '[Service]\nReadWritePaths=/work/spool /work/spool2 /work/spool3 /work/spool4\n' > /etc/systemd/system/pgvigil.service.d/proof.conf && systemctl daemon-reload && systemctl enable --now pgvigil.service" >/dev/null 2>&1
"$BIN" serve -config "$WORK/host.yaml" -listen "127.0.0.1:$SP" -no-login > "$WORK/serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$SP/api/collector" >/dev/null 2>&1 && break; sleep 1; done
api() { curl -fs "http://127.0.0.1:$SP/api/collector$1"; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); t=d[sys.argv[1]]; c=t['columns']; print(json.dumps([dict(zip(c,r)) for r in t['rows']]))" "$1"; }
# spool_n EVENT SETTING [INSTANCE]: the alert files (one JSON per alert: <time>-<event>-<channel>-<key>.json) of an event
# whose setting is SETTING (and instance INSTANCE). The service writes them 0640 as its own user: made readable first;
# a file still unreadable after 5 tries (one renamed in between) prints -1 and leaves $WORK/unreadable, which fails the
# proof at its end (a sum of counts could hide a -1), so 'nothing sent' is never read off files that could not be read.
spool_n() {
  local n=-1 try
  for try in 1 2 3 4 5; do
    docker exec "$SVC" chmod -R a+rX /work/spool /work/spool2 /work/spool3 /work/spool4 >/dev/null 2>&1
    n=$(python3 - "${SPOOL:-$WORK/spool}" "$@" <<'PY'
import glob, json, os, sys
d, ev, setting = sys.argv[1:4]; inst = sys.argv[4] if len(sys.argv) > 4 else None
skip = set(open(os.environ['SKIP']).read().split()) if os.environ.get('SKIP') else set()
n = bad = 0
for f in glob.glob(os.path.join(d, '*.json')):
    if f'-{ev}-' not in os.path.basename(f) or os.path.basename(f) in skip:
        continue
    try:
        a = json.load(open(f))
    except Exception:
        bad += 1
        continue
    flat = json.dumps(a)
    if f'"{setting}"' in flat and (inst is None or f'"{inst}"' in flat):
        n += 1
print(-1 if bad else n)
PY
)
    [[ "$n" != -1 ]] && break
    sleep 1
  done
  [[ "$n" == -1 ]] && echo "${SPOOL:-$WORK/spool} $*" >> "$WORK/unreadable"
  echo "$n"
}
waitfor() { # $1 seconds, $2 SQL that returns t when done
  local end=$((SECONDS + $1)); while (( SECONDS < end )); do [[ "$(q "$2")" == t ]] && return 0; sleep 5; done; return 1
}
# cnt DIR EVENT SETTINGS INSTANCES [NOTVALUES]: the alert files of an EVENT in DIR whose setting is one of SETTINGS and
# instance one of INSTANCES ('|'-separated; INSTANCES '' = any) and whose value is none of NOTVALUES; SKIP=<a list of
# file names> leaves those out (the files before a lift). An unreadable file prints -1 and fails the proof (spool_n).
cnt() {
  local n=-1 try
  for try in 1 2 3 4 5; do
    docker exec "$SVC" chmod -R a+rX /work/spool /work/spool2 /work/spool3 /work/spool4 >/dev/null 2>&1
    n=$(python3 - "$@" <<'PY'
import glob, json, os, sys
d, ev, sets, insts = sys.argv[1:5]
notv = set(sys.argv[5].split('|')) if len(sys.argv) > 5 and sys.argv[5] else set()
sets = set(sets.split('|')); insts = set(insts.split('|')) if insts else None
skip = set(open(os.environ['SKIP']).read().split()) if os.environ.get('SKIP') else set()
n = bad = 0
for f in glob.glob(os.path.join(d, '*.json')):
    b = os.path.basename(f)
    if f'-{ev}-' not in b or b in skip:
        continue
    try:
        a = json.load(open(f))
    except Exception:
        bad += 1
        continue
    if a.get('setting') in sets and (insts is None or a.get('instance') in insts) and a.get('value') not in notv:
        n += 1
print(-1 if bad else n)
PY
)
    [[ "$n" != -1 ]] && break
    sleep 1
  done
  [[ "$n" == -1 ]] && echo "cnt $*" >> "$WORK/unreadable"
  echo "$n"
}
# within SECONDS DIR EVENT SETTING INSTANCES [N]: the seconds until N (default 1) such files are there (-1: not in time).
# A recovery takes up to two alert passes after its finding left (alert_mark stamps missing_since on the first, the
# resolve needs a pass after it and an ok read since), so a resolve is waited for, never read after a fixed sleep.
within() { local t0=$SECONDS; while (( SECONDS - t0 < $1 )); do [[ "$(cnt "$2" "$3" "$4" "$5")" -ge "${6:-1}" ]] && { echo $((SECONDS - t0)); return 0; }; sleep 5; done; echo -1; }
# keymax DIR EVENT: the most files one alert key has for the EVENT in DIR (the key = the file name's last part)
keymax() {
  docker exec "$SVC" chmod -R a+rX /work/spool /work/spool2 /work/spool3 /work/spool4 >/dev/null 2>&1
  python3 -c "import collections, glob, os, sys; c = collections.Counter(os.path.basename(f).rsplit('-', 1)[1] for f in glob.glob(os.path.join(sys.argv[1], '*.json')) if '-' + sys.argv[2] + '-' in os.path.basename(f)); print(max(c.values(), default=0))" "$1" "$2"
}
echo "rig: repository :$RP, target :$TP (t1-t4), serve :$SP, the service in $SVC ($(docker exec "$SVC" systemctl is-active pgvigil.service))"

# ---- A the heartbeat -----------------------------------------------------------------------------------------------
if waitfor 200 "SELECT count(*) >= 2 FROM pgvigil.collector_beats b JOIN pgvigil.collector_heartbeat h USING (collector_id) WHERE h.host = 'pgvigil-svc'"; then
  read -r st ra hs <<<"$(api '' | jget collectors | python3 -c "import json,sys; r=json.load(sys.stdin)[0]; print(r['state'], r['runs_as'].replace(' ','_'), r['host'])")"
  loads=$(api '' | jget load | python3 -c "import json,sys; r=json.load(sys.stdin); print(len(r), all((x['conns_per_min'] or 0) > 0 and (x['attempts_per_min'] or 0) >= (x['conns_per_min'] or 0) for x in r), sum(x['failures_1h'] or 0 for x in r))")
  colls=$(api '' | jget collections | python3 -c "import json,sys; r=json.load(sys.stdin); print(len(r), sum(x['runs'] for x in r), sum(x['rows_written'] for x in r), sum(1 for x in r if x['p95_ms'] is not None))")
  repo=$(api '' | jget repository | python3 -c "import json,sys; r=json.load(sys.stdin)[0]; print(r['size_bytes'] > 0, r['rows_per_min'])")
  [[ "$st $ra $hs" == "up systemd_unit pgvigil-svc" && "${loads% *}" == "4 True" && "${repo%% *}" == True ]] \
    && ok "A heartbeat: $st, runs as $ra on $hs; load: $loads (instances, every one with connections opened <= attempted, failures in the hour); collections (count, runs, rows, with p95): $colls; repository (size read, rows/min): $repo" \
    || fail "A heartbeat: state '$st $ra $hs', load '$loads', collections '$colls', repository '$repo'"
else
  fail "A heartbeat: no two beats from pgvigil-svc in 200 s: $(docker exec "$SVC" journalctl -u pgvigil -n 15 --no-pager 2>&1 | tr '\n' ' ' | cut -c1-900)"
fi

# ---- E a login refused ---------------------------------------------------------------------------------------------
PER="authentication failing|collection failing|server unreachable"
# plain: the collections failing on the plain target t4 (never cut): host without system_stats, jobs without pg_cron ...
plain() { q "SELECT coalesce(string_agg(f.value, '|'), '') FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't4' AND f.setting = 'collection failing'"; }
T2="FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't2'"
if want E; then
rm -f "$WORK"/spool*/*
psql "$TDSN" -XAtqc "alter role l2 password 'changed'" >/dev/null
if waitfor 300 "SELECT EXISTS (SELECT 1 $T2 AND f.setting = 'authentication failing')"; then
  auth=$(api '' | jget load | python3 -c "import json,sys; print({x['instance']: x['auth_failures_24h'] for x in json.load(sys.stdin)})")
  sleep 70   # an alert pass after the findings
  PL=$(plain)
  e_auth=$(cnt "$WORK/spool" firing "authentication failing" t2); e_coll=$(cnt "$WORK/spool" firing "collection failing|server unreachable" t2 "$PL")
  e_s=$(cnt "$WORK/spool2" firing "$PER" t2); e_parent=$(cnt "$WORK/spool" firing "collector or network" "")
  [[ "$e_auth" == 1 && "$e_coll" == 0 && "$e_s" == 0 && "$e_parent" == 0 && "$(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)")" == f ]] \
    && ok "E login refused: logins refused per instance $auth; alerts: t2 'authentication failing' $e_auth on the channel that covers t2, its 'collection failing' / 'server unreachable' $e_coll (the runs failed at the connect), $e_s on the channel scoped to t1, 'collector or network' $e_parent" \
    || fail "E login refused: refused $auth; t2 auth $e_auth (want 1), collection / unreachable $e_coll (want 0), scoped $e_s (want 0), parent $e_parent (want 0), held $(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)"): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-600)"
else
  fail "E login refused: t2's 'authentication failing' did not come in 300 s: $(q "SELECT string_agg(setting || '=' || value, ', ') FROM pgvigil.collector_findings")"
fi
docker exec "$SVC" systemctl restart pgvigil.service   # still refused: the restart must send nothing again
sleep 150
dup=$(keymax "$WORK/spool" firing); res=$(cnt "$WORK/spool" resolved "$PER" t2); a1=$(cnt "$WORK/spool" firing "authentication failing" t2)
[[ "$dup" == 1 && "$res" == 0 && "$a1" == 1 ]] \
  && ok "E restart while refused: no alert key fired twice (the most files of one key: $dup), t2 resolved $res, its 'authentication failing' still once" \
  || fail "E restart while refused: one key fired $dup times (want 1), t2 resolved $res (want 0), auth $a1 (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-600)"
fi

if want H; then
# ---- H the page ----------------------------------------------------------------------------------------------------
setsid chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --hide-scrollbars \
  --window-size=1600,900 about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null && break; sleep 0.5; done
mkdir -p .vis/collector-shots
cat > "$WORK/page.mjs" <<'EOF'
const [cdp, base, out] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${cdp}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let n = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++n; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
let fails = 0; const line = (good, what) => { if (!good) fails++; console.log(`${good ? 'ok  ' : 'FAIL'} H ${what}`); };
const ready = async () => { for (let i = 0; i < 80; i++) { if (await ev(`(() => { const m = document.querySelector('main'); return !!m && !/Loading/.test(m.innerText) && !!m.querySelector('h2'); })()`)) return true; await sleep(250); } return false; };
const go = async h => { await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: base + h }); await sleep(500); return ready(); };
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 900, deviceScaleFactor: 1, mobile: false });
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: base }); await sleep(800);
  await ev(`localStorage.setItem('pgvigil.theme', '${theme}'); true`);
  const r = await go('#/collector');
  const panels = await ev(`[...document.querySelectorAll('main .panel h3.panel-head')].map(h => h.firstChild.textContent).join(' | ')`);
  const tiles = await ev(`document.querySelectorAll('main .tile').length`);
  const s = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(`${out}/${theme}-collector.png`, Buffer.from(s.result.data, 'base64'));
  line(r && panels === 'Service | Findings | Collections | Failing now | Load on the monitored servers | Repository' && tiles >= 15, `${theme}: ready ${r}; panels ${panels}; ${tiles} tiles; shot ${theme}-collector.png`);
}
// every link on the page, its landing
await go('#/collector');
const links = await ev(`[...new Set([...document.querySelectorAll('main a[href^="#/"]')].map(a => a.getAttribute('href')))]`);
let landed = 0;
for (const h of links) {
  await go(h);
  const at = await ev('location.hash'), title = await ev(`document.querySelector('main h2')?.textContent ?? ''`);
  const lineTxt = await ev(`document.querySelector('main .collector-line')?.textContent ?? ''`);
  const good = h.startsWith('#/collectiondates') ? at.startsWith('#/collectiondates') && /i=\d+/.test(at) && title === 'Collection dates' && lineTxt.startsWith('Collector:') : at.split('?')[0] === h.split('?')[0];
  if (good) landed++; else console.log(`FAIL H link ${h}: landed ${at} '${title}' line '${lineTxt}'`);
  if (good && lineTxt && landed === 1) {
    await ev(`document.querySelector('main .collector-line a').click(); true`); await sleep(300); await ready();
    const back = await ev('location.hash');
    line(back.startsWith('#/collector'), `the collector's line on ${h} ('${lineTxt.slice(0, 160)}'): its link lands on ${back}`);
  }
}
line(links.length > 0 && landed === links.length, `links: ${landed} of ${links.length} landed (${[...new Set(links.map(h => h.split('?')[0]))].join(', ')})`);
// the tree's node under Checks (a root folder's head is a .tree-node: its caret button opens it, its name is a link)
await go('#/summary');
const treeLink = `[...document.querySelectorAll('#tree a')].find(x => x.textContent.trim() === 'Collector')`;
let how = 'open already';
if (!(await ev(`!!${treeLink}`))) {
  how = await ev(`(() => { const n = [...document.querySelectorAll('#tree .tree-node')].find(x => x.querySelector('a, .folder-name')?.textContent.trim() === 'Checks'); if (!n) return 'no Checks node'; const c = n.querySelector('button.caret'); if (!c) return 'no caret'; c.click(); return 'caret ' + c.getAttribute('data-key'); })()`);
  await sleep(600);
}
const tree = await ev(`(() => { const a = ${treeLink}; if (!a) return ''; a.click(); return a.getAttribute('href'); })()`);
await sleep(300); await ready();
const treeAt = await ev('location.hash');
const treeGood = tree !== '' && treeAt.startsWith('#/collector');
line(treeGood, `the tree's Collector node (${tree}) lands on ${treeAt}` + (treeGood ? '' : `; ${how}; nodes: ${await ev(`[...document.querySelectorAll('#tree .tree-node')].map(x => x.textContent.trim().slice(0, 24)).join(' | ')`)}; links: ${await ev(`[...document.querySelectorAll('#tree a')].map(x => x.textContent.trim() + '=' + x.getAttribute('href')).slice(0, 40).join(', ')`)}; #tree ${await ev(`!!document.querySelector('#tree')`)}`));
// the chart's menu
await go('#/collector');
const menu = await ev(`(async () => { const b = [...document.querySelectorAll('main .chart h3 button')].find(x => x.textContent.trim() === '⋯'); if (!b) return 'no menu button'; b.click(); await new Promise(r => setTimeout(r, 300)); const m = document.querySelector('.menu'); const t = m ? [...m.querySelectorAll('button')].map(x => x.textContent).join('|') : 'no menu'; document.activeElement?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return t; })()`);
line(/Copy image/.test(menu) && /Export data/.test(menu), `the chart's menu: ${menu}`);
console.log(fails ? `FAIL H: ${fails}` : 'H: the page as expected');
ws.close(); process.exit(fails ? 1 : 0);
EOF
node "$WORK/page.mjs" "$CDP" "http://127.0.0.1:$SP/" "$PWD/.vis/collector-shots" || FAILS=$((FAILS + 1))
fi

if want E; then
psql "$TDSN" -XAtqc "alter role l2 password 'p2'" >/dev/null
docker exec "$SVC" systemctl restart pgvigil.service   # a changed password is fixed and the service restarted
# t2 back to t1's state: no 'authentication failing', and t2 fails no collection t1 does not (some collections fail on
# every plain target: host without system_stats, jobs without pg_cron, ...)
CF="SELECT f.value FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE f.setting = 'collection failing' AND i.name ="
if waitfor 300 "SELECT NOT EXISTS (SELECT 1 $T2 AND f.setting = 'authentication failing') AND NOT EXISTS ($CF 't2' EXCEPT $CF 't1')"; then
  e_w=$(within 240 "$WORK/spool" resolved "authentication failing" t2); e_res=$(cnt "$WORK/spool" resolved "authentication failing" t2)
  [[ "$e_res" == 1 ]] && ok "E restart: the password back and the service restarted - t2's 'authentication failing' gone and resolved once ($e_w s after it left the view), its 'collection failing' within t1's ($(q "SELECT count(*) FROM ($CF 't1') x") on t1: $(q "SELECT string_agg(value, ' ') FROM ($CF 't1') x"))" \
    || fail "E restart: t2's 'authentication failing' resolved $e_res times in 240 s (want 1)"
else fail "E restart: t2 still $(q "SELECT string_agg(f.setting || ' ' || f.value, ', ') $T2") 300 s after the restart"; fi
mkdir -p .vis/spool-evidence/E && cp -r "$WORK"/spool* .vis/spool-evidence/E/ 2>/dev/null || true
fi

# ---- D failing together -------------------------------------------------------------------------------------------
# logins HOW NAME...: the logins of the instances (t1 -> l1) turned login | nologin at the source (a refused login)
logins() { local how=$1 a=() n; shift; for n in "$@"; do a+=(-c "alter role l${n#t} $how"); done; psql "$TDSN" -Xq "${a[@]}" >/dev/null; }
# pin_at S: wait for the second S of a wall-clock minute (the cut's second)
pin_at() { local i; for i in $(seq 1 700); do [[ "$((10#$(date -u +%S)))" == "$1" ]] && return 0; sleep 0.1; done; return 0; }
# snap CASE: the spools' file names now (the files before the lift); keep CASE: the spools copied for the evidence
snap() { (cd "$WORK" && ls spool spool2 spool3 spool4 2>/dev/null | grep '\.json$') > "$WORK/$1.lst" || true; }
keep() { mkdir -p ".vis/spool-evidence/$1"; cp -r "$WORK"/spool* ".vis/spool-evidence/$1/" 2>/dev/null || true; }
NOPARENT="SELECT NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent) AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances) AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_findings WHERE setting IN ('authentication failing', 'server unreachable'))"
# d_clean: every login back, no parent, nothing held, no refusal standing, a pass after it; the spools emptied
d_clean() { logins login t1 t2 t3 t4; waitfor 600 "$NOPARENT" || fail "D: not clean 600 s after the logins came back"; sleep 70; rm -f "$WORK"/spool*/*; }
# per DIR EVENT INSTANCES: the instances' own alerts ($PER), the collections failing on the plain target left out
per() { cnt "$1" "$2" "$PER" "$3" "$(plain)"; }
PAR="collector or network"
# d_cut CASE SECOND MINUTES: t1-t3 cut at the SECOND of a minute for MINUTES (D1, D1b)
d_cut() {
  local c=$1 t0 tp left up sp pr pr2 ur sr af ar s1 L
  d_clean; pin_at "$2"; logins nologin t1 t2 t3; t0=$SECONDS
  tp=$(within 185 "$WORK/spool" firing "$PAR" "")
  left=$(( $3 * 60 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi
  snap "$c"; L=$WORK/$c.lst
  up=$(cnt "$WORK/spool" firing "$PAR" ""); sp=$(cnt "$WORK/spool2" firing "$PAR" "")
  pr=$(per "$WORK/spool" firing "t1|t2|t3"); pr2=$(per "$WORK/spool2" firing t1)
  logins login t1 t2 t3
  waitfor 480 "$NOPARENT" || fail "$c: the parent still standing 480 s after the lift"
  SKIP=$L within 240 "$WORK/spool" resolved "$PAR" "" >/dev/null; SKIP=$L within 60 "$WORK/spool2" resolved "$PAR" "" >/dev/null
  sleep 60   # one more pass: nothing of t1-t3 may follow the parent's recovery
  ur=$(SKIP=$L cnt "$WORK/spool" resolved "$PAR" ""); sr=$(SKIP=$L cnt "$WORK/spool2" resolved "$PAR" "")
  af=$(SKIP=$L per "$WORK/spool" firing "t1|t2|t3"); ar=$(per "$WORK/spool" resolved "t1|t2|t3"); s1=$(per "$WORK/spool2" resolved t1)
  keep "$c"
  if [[ "$tp" -ge 0 && "$up" == 1 && "$sp" == 1 && "$pr" == 0 && "$pr2" == 0 && "$ur" == 1 && "$sr" == 1 && "$af" == 0 && "$ar" == 0 && "$s1" == 0 ]]; then
    ok "$c: t1-t3 cut at :$2 for $3 min - 'collector or network' sent $tp s after the cut, once on U and once on S; t1-t3's own alerts 0 (S: t1 0); after the lift the parent resolved once on each, t1-t3 sent 0 and resolved 0"
  else
    fail "$c: parent $tp s after the cut (want 0-185), U $up / S $sp (want 1 / 1), t1-t3 before the lift $pr / S $pr2 (want 0 / 0); after it: parent resolved U $ur / S $sr (want 1 / 1), t1-t3 sent $af resolved $ar, S t1 resolved $s1 (want 0 0 0): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-700)"
  fi
}
if want D1; then d_cut D1 20 6; fi
if want D1b; then d_cut D1b 55 4; fi
if want D2; then
  d_clean; pin_at 10; logins nologin t1 t2 t3; sleep 40; logins login t1 t2 t3; sleep 200
  d2a=$(per "$WORK/spool" firing "t1|t2|t3"); d2b=$(per "$WORK/spool" resolved "t1|t2|t3"); d2c=$(cnt "$WORK/spool" firing "$PAR" ""); d2d=$(per "$WORK/spool2" firing t1)
  keep D2
  [[ "$d2a$d2b$d2c$d2d" == 0000 ]] && ok "D2: t1-t3 cut :10 to :50 of one minute - nothing sent, nothing resolved (U: own $d2a, resolved $d2b, parent $d2c; S: $d2d)" \
    || fail "D2: U own $d2a, resolved $d2b, parent $d2c; S $d2d (want 0 0 0 0): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
fi
if want D3; then
  d_clean; pin_at 20; logins nologin t1 t2; t0=$SECONDS; tw=-1
  while (( SECONDS - t0 < 125 )); do [[ "$(cnt "$WORK/spool" firing "authentication failing" "t1|t2")" == 2 ]] && { tw=$((SECONDS - t0)); break; }; sleep 5; done
  left=$(( 240 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi   # the cut stands 4 min: nothing more goes out
  d3a=$(cnt "$WORK/spool" firing "authentication failing" "t1|t2"); d3c=$(cnt "$WORK/spool" firing "collection failing|server unreachable" "t1|t2" "$(plain)")
  d3p=$(cnt "$WORK/spool" firing "$PAR" ""); d3h=$(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)"); d3s=$(cnt "$WORK/spool2" firing "authentication failing" t1)
  logins login t1 t2; waitfor 300 "$NOPARENT" || true
  within 240 "$WORK/spool" resolved "authentication failing" "t1|t2" 2 >/dev/null; within 60 "$WORK/spool2" resolved "authentication failing" t1 >/dev/null
  d3r=$(cnt "$WORK/spool" resolved "authentication failing" "t1|t2"); d3sr=$(cnt "$WORK/spool2" resolved "authentication failing" t1)
  keep D3
  [[ "$tw" -ge 0 && "$d3a" == 2 && "$d3c" == 0 && "$d3p" == 0 && "$d3h" == f && "$d3s" == 1 && "$d3r" == 2 && "$d3sr" == 1 ]] \
    && ok "D3: t1, t2 cut (2 of 4) - no parent, nothing held; 'authentication failing' once each within $tw s of the cut (S: t1 once), no 'collection failing' / 'server unreachable'; resolved once each after (S: t1 once)" \
    || fail "D3: both auth after $tw s (want 0-125), U auth $d3a (want 2), collection / unreachable $d3c (want 0), parent $d3p (want 0), held $d3h (want f), S auth $d3s (want 1); resolved U $d3r (want 2), S $d3sr (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-500)"
fi
if want D4; then
  d_clean; logins nologin t1; t0=$SECONDS; tw=-1
  while (( SECONDS - t0 < 150 )); do [[ "$(cnt "$WORK/spool3" firing "authentication failing" t1)" == 1 ]] && { tw=$((SECONDS - t0)); break; }; sleep 5; done
  pin_at 20; logins nologin t2 t3; t0=$SECONDS
  tp=$(within 185 "$WORK/spool" firing "$PAR" "")
  left=$(( 540 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi   # 9 min: R's 5-minute repeat of the parent falls inside the hold
  d4rp=$(cnt "$WORK/spool3" repeat "$PAR" ""); d4rt=$(cnt "$WORK/spool3" repeat "authentication failing" t1)
  d4h=$(cnt "$WORK/spool" resolved "authentication failing" t1)$(cnt "$WORK/spool2" resolved "authentication failing" t1)
  d4o=$(per "$WORK/spool" firing "t2|t3"); d4d=$(q "SELECT detail FROM pgvigil.collector_findings WHERE setting = '$PAR'" | grep -o 'it covers.*' | cut -c1-160 || true)
  snap D4; L=$WORK/D4.lst
  logins login t1 t2 t3; waitfor 480 "$NOPARENT" || fail "D4: the parent still standing 480 s after the lift"
  SKIP=$L within 240 "$WORK/spool" resolved "authentication failing" t1 >/dev/null; SKIP=$L within 60 "$WORK/spool2" resolved "authentication failing" t1 >/dev/null; sleep 60
  d4a=$(SKIP=$L cnt "$WORK/spool" resolved "authentication failing" t1)$(SKIP=$L cnt "$WORK/spool2" resolved "authentication failing" t1)
  d4o2=$(per "$WORK/spool" firing "t2|t3"); d4rt2=$(cnt "$WORK/spool3" repeat "authentication failing" t1)
  keep D4
  [[ "$tw" -ge 0 && "$tp" -ge 0 && "$d4rp" -ge 1 && "$d4rt" == 0 && "$d4h" == 00 && "$d4o" == 0 && "$d4d" == *"t1 authentication failing"* && "$d4a" == 11 && "$d4o2" == 0 && "$d4rt2" == 0 ]] \
    && ok "D4: t1 refused first (its alert out in $tw s on U, S and R), then t2, t3 - the parent $tp s after; during the hold R repeated the parent $d4rp time(s) and t1 0 times, t1 resolved 0, t2 t3 sent 0; the parent's text '$d4d'; after the lift t1 resolved once on U and on S" \
    || fail "D4: t1 out after $tw s, parent after $tp s; R repeats parent $d4rp (want >= 1) / t1 $d4rt (want 0); t1 resolved during the hold U+S '$d4h' (want 00); t2 t3 sent $d4o (want 0); covers '$d4d'; after: t1 resolved U+S '$d4a' (want 11), t2 t3 $d4o2, R t1 repeats $d4rt2: $(ls "$WORK/spool" "$WORK/spool3" | tr '\n' ' ' | cut -c1-700)"
fi
if want D5; then
  d_clean; pin_at 20; logins nologin t1 t2 t3; t0=$SECONDS
  tp=$(within 185 "$WORK/spool" firing "$PAR" "")
  left=$(( 240 - (SECONDS - t0) )); if (( left > 0 )); then sleep "$left"; fi
  logins login t1 t2
  t3w=-1; if waitfor 480 "SELECT NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent)"; then t3w=$(within 150 "$WORK/spool" firing "authentication failing" t3); fi
  within 240 "$WORK/spool" resolved "$PAR" "" >/dev/null; within 60 "$WORK/spool2" resolved "$PAR" "" >/dev/null
  d5p=$(cnt "$WORK/spool" resolved "$PAR" ""); d5o=$(per "$WORK/spool" firing "t1|t2")$(per "$WORK/spool" resolved "t1|t2")
  d5t=$(cnt "$WORK/spool" firing "authentication failing" t3)$(cnt "$WORK/spool" resolved "authentication failing" t3)
  d5s=$(cnt "$WORK/spool2" firing "$PAR" "")$(cnt "$WORK/spool2" resolved "$PAR" "")$(per "$WORK/spool2" firing t1)
  logins login t3; waitfor 300 "$NOPARENT" || true; within 240 "$WORK/spool" resolved "authentication failing" t3 >/dev/null
  d5t2=$(cnt "$WORK/spool" resolved "authentication failing" t3)
  keep D5
  [[ "$tp" -ge 0 && "$d5p" == 1 && "$d5o" == 00 && "$t3w" -ge 0 && "$d5t" == 10 && "$d5s" == 110 && "$d5t2" == 1 ]] \
    && ok "D5: t1-t3 cut, t1 t2 back after 4 min, t3 kept - the parent ($tp s) resolved once; t3's 'authentication failing' once, $t3w s after the parent left collector_parent; t1 t2 sent / resolved $d5o; S parent / resolved / t1 $d5s; t3 resolved once when back" \
    || fail "D5: parent after $tp s, resolved $d5p (want 1); t1 t2 sent+resolved '$d5o' (want 00); t3 $t3w s after the parent left (want 0-150), t3 sent+resolved '$d5t' (want 10); S '$d5s' (want 110); t3 resolved when back $d5t2 (want 1): $(ls "$WORK/spool" | tr '\n' ' ' | cut -c1-600)"
fi
if want DQ; then
  d_clean
  C=$(( $(date -u +%s) / 60 + 2 ))   # the cut's minute: two on (the service restarts with the quiet channel first)
  QUIET="$(date -u -d @$(( (C - 1) * 60 )) +%H:%M)-$(date -u -d @$(( (C + 3) * 60 )) +%H:%M)"; QEND=$(date -u -d @$(( (C + 3) * 60 )) +%Y%m%dT%H%M%S)
  { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances target 5432; alerts_of /work; } > "$WORK/svc.yaml"
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
  left=$(( C * 60 + 20 - $(date -u +%s) )); if (( left > 0 )); then sleep "$left"; fi
  logins nologin t1 t2 t3; sleep 300
  dq1=$(cnt "$WORK/spool4" firing "$PAR" ""); dqo=$(per "$WORK/spool4" firing "t1|t2|t3")
  # the parent's own first file (a new channel also sends the standing findings of the plain target)
  dqt=$(python3 -c "import glob, json, os, sys; print(min((os.path.basename(f)[:15] for f in glob.glob(sys.argv[1] + '/*-firing-*.json') if json.load(open(f)).get('setting') == 'collector or network'), default=''))" "$WORK/spool4" 2>/dev/null || true)
  logins login t1 t2 t3; waitfor 480 "$NOPARENT" || true
  unset QUIET
  { printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances target 5432; alerts_of /work; } > "$WORK/svc.yaml"
  docker exec "$SVC" sh -c "install -m 0640 -g pgvigil /work/svc.yaml /etc/pgvigil/pgvigil.yaml && systemctl restart pgvigil.service"
  keep DQ
  [[ "$dq1" == 1 && "$dqo" == 0 && -n "$dqt" ]] && ! [[ "$dqt" < "$QEND" ]] \
    && ok "DQ: quiet hours $QUIET UTC over the cut - the parent once on the quiet channel, its first file at $dqt (the quiet end $QEND), t1-t3 0" \
    || fail "DQ: quiet $QUIET: the parent $dq1 (want 1), first file '$dqt' (want at or after $QEND), t1-t3 $dqo (want 0): $(ls "$WORK/spool4" | tr '\n' ' ' | cut -c1-500)"
fi
logins login t1 t2 t3 t4

# ---- F many collectors
if want F; then
on one repository ---------------------------------------------------------------------------
timeout 240 "$BIN" run -config "$WORK/host.yaml" > "$WORK/second.log" 2>&1 &
SECOND=$!
if waitfor 200 "SELECT count(DISTINCT f.instance_id) = 4 FROM pgvigil.collector_findings f WHERE f.setting = 'collected by more than one collector'"; then
  up=$(api '' | jget collectors | python3 -c "import json,sys; print(sum(1 for r in json.load(sys.stdin) if r['state'] == 'up'))")
  [[ "$up" == 2 ]] && kill -0 $SECOND 2>/dev/null \
    && ok "F many: a second collector on $(hostname) runs beside pgvigil-svc (not refused; the page: $up up); 'collected by more than one collector' on t1-t4: $(q "SELECT detail FROM pgvigil.collector_findings WHERE setting = 'collected by more than one collector' LIMIT 1" | cut -c1-200)" \
    || fail "F many: up $up (want 2), the second alive $(kill -0 $SECOND 2>/dev/null && echo yes || echo no): $(tail -3 "$WORK/second.log" | tr '\n' ' ' | cut -c1-400)"
else fail "F many: no 'collected by more than one collector' on the 4 instances in 200 s: $(tail -3 "$WORK/second.log" | tr '\n' ' ' | cut -c1-400)"; fi
kill -TERM $SECOND 2>/dev/null || true; wait $SECOND 2>/dev/null || true; SECOND=""
waitfor 60 "SELECT (SELECT count(*) FROM pgvigil.collector_live) = 1" || fail "F many: the second collector still live 60 s after it was stopped"
sleep 130   # pgvigil-svc beats past the second collector's stop: the second's instances are read by another host since

fi

# ---- B the service stopped
if want B; then
-----------------------------------------------------------------------------------------
waitfor 150 "SELECT count(*) = 1 FROM pgvigil.collector_live" || true
rm -f "$WORK"/spool/* "$WORK"/spool2/*
docker exec "$SVC" systemctl stop pgvigil.service
sleep 5
st=$(api '' | jget collectors | python3 -c "import json,sys; r=max((x for x in json.load(sys.stdin) if x['host'] == 'pgvigil-svc'), key=lambda x: x['started_at']); print(r['state'])")
[[ "$st" == stopped ]] && ok "B stopped: the page says '$st' at once (a clean stop)" || fail "B stopped: the page says '$st'"
if waitfor 600 "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_parent WHERE why = 'collector not seen' AND host = 'pgvigil-svc')"; then
  sleep 130   # serve's watchdog: its next minute
  sent=$(spool_n firing "collector or network"); sent2=$(SPOOL=$WORK/spool2 spool_n firing "collector or network")
  heldb=$(q "SELECT string_agg(i.name, ' ' ORDER BY i.name) FROM pgvigil.collector_held_instances h JOIN pgvigil.instances i USING (instance_id)")
  [[ "$sent" == 1 && "$sent2" == 1 && "$heldb" == "t1 t2 t3 t4" ]] && grep -qE 'collector_down(=|":)true' "$WORK/serve.log" \
    && ok "B not seen: 'collector or network' (collector not seen: pgvigil-svc) after $(q "SELECT floor(extract(epoch FROM now() - max(beat_at)) / 60) FROM pgvigil.collector_heartbeat WHERE host = 'pgvigil-svc'") min, sent once on each channel by serve's watchdog; held: $heldb" \
    || fail "B not seen: alerts $sent / scoped $sent2 (want 1 / 1), held '$heldb' (want t1 t2 t3 t4); serve log: $(grep -i watchdog "$WORK/serve.log" | tail -3 | tr '\n' ' ' | cut -c1-400)"
else fail "B not seen: no 'collector not seen' 8 min after the stop"; fi
docker exec "$SVC" systemctl start pgvigil.service
waitfor 200 "SELECT (SELECT count(*) FROM pgvigil.collector_live) = 1 AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent)" \
  && ok "B started: up again, the parent cleared" || fail "B started: not up with the parent cleared in 200 s"

fi

# ---- G purge
if want G; then
-------------------------------------------------------------------------------------------------------
q "UPDATE pgvigil.instances SET first_seen = now() - interval '3 days' WHERE name = 't1'" >/dev/null
before=$(q "SELECT value FROM pgvigil.collector_findings WHERE setting = 'purge not run in 2 days'")
old=$(date -u -d '-4 months' +%Y%m)
q "CREATE TABLE IF NOT EXISTS pgvigil.wait_sample_$old PARTITION OF pgvigil.wait_sample FOR VALUES FROM ('$(date -u -d "-4 months" +%Y-%m-01)') TO ('$(date -u -d "-3 months" +%Y-%m-01)')" >/dev/null 2>&1 \
  || q "SELECT pgvigil.ensure_month_partition('wait_sample', '$(date -u -d '-4 months' +%Y-%m-15)'::timestamptz)" >/dev/null 2>&1 || true
"$BIN" purge -config "$WORK/host.yaml" > "$WORK/purge.out" 2>&1 || true
row=$(q "SELECT days || ' days, ' || cardinality(partitions_dropped) || ' partition(s): ' || array_to_string(partitions_dropped, ' ') || ', rows ' || rows_deleted FROM pgvigil.purge_runs ORDER BY run_id DESC LIMIT 1")
after=$(q "SELECT count(*) FROM pgvigil.collector_findings WHERE setting = 'purge not run in 2 days'")
page=$(api '' | jget repository | python3 -c "import json,sys; r=json.load(sys.stdin)[0]; print(r['purge_at'] is not None, r['purge_dropped'])")
[[ "$before" == never && -n "$row" && "$row" == *"wait_sample_$old"* && "$after" == 0 && "${page%% *}" == True ]] \
  && ok "G purge: the finding said '$before'; the run: $row; the page: $page; the finding gone" \
  || fail "G purge: finding before '$before', run '$row', after $after, page '$page': $(tail -2 "$WORK/purge.out" | tr '\n' ' ')"

fi

echo "the service's journal (last lines): $(docker exec "$SVC" journalctl -u pgvigil -n 4 --no-pager 2>&1 | tr '\n' ' ' | cut -c1-600)"
[[ -s "$WORK/unreadable" ]] && fail "alert files unreadable after 5 tries (a count read as -1): $(tr '\n' ';' < "$WORK/unreadable")"
if (( FAILS )); then echo "FAIL: $FAILS case(s)"; exit 1; fi
echo "proof-collector-health: OK (the heartbeat of a systemd unit, its load and a refused login, the page, failing together and a stopped collector each one alert with only their unread instances held, many collectors on one repository, the purge recorded)"
