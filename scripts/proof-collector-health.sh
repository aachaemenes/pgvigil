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
#   E  a login refused: t2's password changed at the source - t2's 'logins refused' counted, 'authentication failing'
#      and 'collection failing' on t2, both alerted (one instance: nothing held), no 'collector or network'; the service
#      restarted while t2 is still refused: its streak counts on from the stored one (no new alert, no recovery); the
#      password back and the service restarted again: t2's findings gone, its streaks reset
#   H  the page: #/collector in both themes (shots), every link on it clicked with its landing (an instance link opens
#      its Collection dates with the collector's line, the line's link comes back), the tree's Collector node, the
#      chart's menu
#   D  failing together: the logins of t1-t3 refused - 'collector or network' (instances failing together:
#      pgvigil-svc) alerted ONCE on the unscoped channel and ONCE on a channel scoped to t1; t1-t3 held (their own
#      alerts not sent), t4 (still read) not held; the logins back - the parent clears, and no held 'collection failing'
#      goes out after it (a streak whose last run fell in a failing-together minute waits for its next run)
#   F  many collectors: a second `pgvigil run` on this host collecting the same instances is not refused (the page: 2
#      up); each instance 'collected by more than one collector'
#   B  the service stopped: the page says stopped at once; after 5 minutes 'collector or network' (collector not seen),
#      and serve's watchdog sends it (the collector that would is the one stopped); started again: up, cleared
#   G  purge: 'purge not run in 2 days' on an instance seen 3 days ago; `pgvigil purge` records its run (an old
#      partition dropped and named); the finding gone
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
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
mkdir -p "$WORK/spool" "$WORK/spool2"; chmod 0777 "$WORK/spool" "$WORK/spool2"
instances() { # $1 host, $2 port
  for n in 1 2 3 4; do printf '  - name: t%s\n    dsn: "host=%s port=%s user=l%s password=p%s dbname=db%s sslmode=disable"\n' "$n" "$1" "$2" "$n" "$n" "$n"; done
}
# the service sees this folder as /work (systemd mounts a tmpfs over /tmp in the container)
alerts_of() { printf 'alerts:\n  - {name: spool, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, file: {dir: %s/spool}}\n  - {name: scoped, kind: file, min_severity: critical, repeat: disabled, clear_after: 0, instances: [t1], file: {dir: %s/spool2}}\n' "$1" "$1"; }
{ printf 'repository:\n  dsn: "host=repo port=5432 user=postgres password=%s dbname=pgvigil sslmode=disable"\ninstances:\n' "$PW"; instances target 5432; alerts_of /work; } > "$WORK/svc.yaml"
{ printf 'repository:\n  dsn: "%s dbname=pgvigil"\ninstances:\n' "$RDSN"; instances 127.0.0.1 "$TP"; alerts_of "$WORK"; } > "$WORK/host.yaml"
"$BIN" migrate -config "$WORK/host.yaml" >"$WORK/migrate.out" 2>&1 || { cat "$WORK/migrate.out"; exit 1; }

docker run -d --name "$SVC" --hostname pgvigil-svc --network "$NET" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock -v "$WORK:/work" "$IMG" >/dev/null
for _ in $(seq 1 30); do docker exec "$SVC" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
docker exec "$SVC" sh -c "install -m 0755 /work/pgvigil.bin /usr/local/bin/pgvigil && mkdir -p /etc/pgvigil /etc/systemd/system/pgvigil.service.d \
  && install -m 0640 -g pgvigil /work/svc.yaml /etc/pgvigil/pgvigil.yaml && touch /etc/pgvigil/pgvigil.env"
docker cp deploy/pgvigil.service "$SVC:/etc/systemd/system/pgvigil.service"
docker exec "$SVC" sh -c "printf '[Service]\nReadWritePaths=/work/spool /work/spool2\n' > /etc/systemd/system/pgvigil.service.d/proof.conf && systemctl daemon-reload && systemctl enable --now pgvigil.service" >/dev/null 2>&1
"$BIN" serve -config "$WORK/host.yaml" -listen "127.0.0.1:$SP" -no-login > "$WORK/serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$SP/api/collector" >/dev/null 2>&1 && break; sleep 1; done
api() { curl -fs "http://127.0.0.1:$SP/api/collector$1"; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); t=d[sys.argv[1]]; c=t['columns']; print(json.dumps([dict(zip(c,r)) for r in t['rows']]))" "$1"; }
# spool_n EVENT SETTING [INSTANCE]: the alert files (one JSON per alert: <time>-<event>-<channel>-<key>.json) of an event
# whose setting is SETTING (and instance INSTANCE)
spool_n() {
  python3 - "${SPOOL:-$WORK/spool}" "$@" <<'PY'
import glob, json, os, sys
d, ev, setting = sys.argv[1:4]; inst = sys.argv[4] if len(sys.argv) > 4 else None
n = 0
for f in glob.glob(os.path.join(d, '*.json')):
    if f'-{ev}-' not in os.path.basename(f):
        continue
    try:
        a = json.load(open(f))
    except Exception:
        continue
    flat = json.dumps(a)
    if f'"{setting}"' in flat and (inst is None or f'"{inst}"' in flat):
        n += 1
print(n)
PY
}
waitfor() { # $1 seconds, $2 SQL that returns t when done
  local end=$((SECONDS + $1)); while (( SECONDS < end )); do [[ "$(q "$2")" == t ]] && return 0; sleep 5; done; return 1
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
psql "$TDSN" -XAtqc "alter role l2 password 'changed'" >/dev/null
T2="FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't2'"
base_fail=$(q "SELECT count(*) FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't2' AND s.fail_streak > 0")
if waitfor 300 "SELECT EXISTS (SELECT 1 $T2 AND f.setting = 'authentication failing') AND (SELECT count(*) FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't2' AND s.fail_streak >= 3) > $base_fail"; then
  auth=$(api '' | jget load | python3 -c "import json,sys; print({x['instance']: x['auth_failures_24h'] for x in json.load(sys.stdin)})")
  sleep 70   # an alert pass after the findings
  e_auth=$(spool_n firing "authentication failing" t2); e_coll=$(spool_n firing "collection failing" t2); e_parent=$(spool_n firing "collector or network")
  [[ "$e_auth" -ge 1 && "$e_coll" -ge 1 && "$e_parent" == 0 && "$(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)")" == f ]] \
    && ok "E login refused: logins refused per instance $auth; alerts: 'authentication failing' $e_auth, t2 'collection failing' lines $e_coll, 'collector or network' $e_parent (one instance: nothing held)" \
    || fail "E login refused: refused $auth; alerts auth $e_auth, collection $e_coll, parent $e_parent, held $(q "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)")"
else
  fail "E login refused: t2's findings did not come in 300 s: $(q "SELECT string_agg(setting || '=' || value, ', ') FROM pgvigil.collector_findings")"
fi
S2="SELECT coalesce(max(s.fail_streak), 0) FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't2'"
k0=$(q "$S2"); f0=$(spool_n firing "collection failing" t2); r0=$(spool_n resolved "collection failing" t2)
docker exec "$SVC" systemctl restart pgvigil.service   # still refused: the restart must not reset the count
sleep 150
k1=$(q "$S2"); f1=$(spool_n firing "collection failing" t2); r1=$(spool_n resolved "collection failing" t2)
[[ "$k1" -gt "$k0" && "$f1" == "$f0" && "$r1" == "$r0" ]] \
  && ok "E restart while refused: t2's streak $k0 -> $k1 across the restart (carried on), no new 'collection failing' alert ($f1), no recovery ($r1)" \
  || fail "E restart while refused: streak $k0 -> $k1 (want more), firing $f0 -> $f1, resolved $r0 -> $r1 (want unchanged)"

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
// the tree's node under Checks
await go('#/summary');
const tree = await ev(`(() => { const a = [...document.querySelectorAll('#tree a')].find(x => x.textContent.trim() === 'Collector'); if (!a) return ''; a.click(); return a.getAttribute('href'); })()`);
await sleep(300); await ready();
line(tree !== '' && (await ev('location.hash')).startsWith('#/collector'), `the tree's Collector node (${tree}) lands on ${await ev('location.hash')}`);
// the chart's menu
await go('#/collector');
const menu = await ev(`(async () => { const b = [...document.querySelectorAll('main .chart h3 button')].find(x => x.textContent.trim() === '⋯'); if (!b) return 'no menu button'; b.click(); await new Promise(r => setTimeout(r, 300)); const m = document.querySelector('.menu'); const t = m ? [...m.querySelectorAll('button')].map(x => x.textContent).join('|') : 'no menu'; document.activeElement?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return t; })()`);
line(/Copy image/.test(menu) && /Export data/.test(menu), `the chart's menu: ${menu}`);
console.log(fails ? `FAIL H: ${fails}` : 'H: the page as expected');
ws.close(); process.exit(fails ? 1 : 0);
EOF
node "$WORK/page.mjs" "$CDP" "http://127.0.0.1:$SP/" "$PWD/.vis/collector-shots" || FAILS=$((FAILS + 1))
psql "$TDSN" -XAtqc "alter role l2 password 'p2'" >/dev/null
docker exec "$SVC" systemctl restart pgvigil.service   # a changed password is fixed and the service restarted
if waitfor 300 "SELECT NOT EXISTS (SELECT 1 $T2 AND f.setting IN ('authentication failing', 'collection failing')) AND (SELECT count(*) FROM pgvigil.collector_streaks s JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 't2' AND s.fail_streak > 0) <= $base_fail"; then
  ok "E restart: the password back and the service restarted - t2's 'collection failing' and 'authentication failing' gone, its streaks reset"
else fail "E restart: t2 still $(q "SELECT string_agg(f.setting || ' ' || f.value, ', ') $T2") 300 s after the restart"; fi
sleep 90   # the passes that send t2's recoveries, before D counts

# ---- D failing together -------------------------------------------------------------------------------------------
rm -f "$WORK"/spool/* "$WORK"/spool2/*
psql "$TDSN" -Xq -c "alter role l1 nologin" -c "alter role l2 nologin" -c "alter role l3 nologin" >/dev/null
if waitfor 240 "SELECT EXISTS (SELECT 1 FROM pgvigil.collector_parent WHERE why = 'instances failing together' AND host = 'pgvigil-svc')"; then
  sleep 240   # three more runs: t1-t3's own findings stand, held
  heldn=$(q "SELECT string_agg(i.name, ' ' ORDER BY i.name) FROM pgvigil.collector_held_instances h JOIN pgvigil.instances i USING (instance_id)")
  standing=$(q "SELECT count(*) FROM pgvigil.collector_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name IN ('t1','t2','t3')")
  parent=$(spool_n firing "collector or network"); parent2=$(SPOOL=$WORK/spool2 spool_n firing "collector or network")
  per=0; for n in t1 t2 t3; do per=$((per + $(spool_n firing "collection failing" $n) + $(spool_n firing "authentication failing" $n))); done
  [[ "$parent" == 1 && "$parent2" == 1 && "$per" == 0 && "$heldn" == "t1 t2 t3" && "$standing" -ge 3 ]] \
    && ok "D together: 'collector or network' (instances failing together: pgvigil-svc) sent once on the unscoped channel and once on the channel scoped to t1; held: $heldn (t4, still read, not held); $standing finding(s) of t1-t3 standing, 0 of them sent" \
    || fail "D together: parent sent $parent / scoped $parent2 (want 1 / 1), t1-t3 sent $per (want 0), held '$heldn' (want t1 t2 t3), standing $standing: $(ls "$WORK/spool" | head -20 | tr '\n' ' ')"
else
  fail "D together: no 'instances failing together' in 240 s: $(q "SELECT string_agg(minute || ':' || failures || '/' || runs, ' ') FROM (SELECT minute, sum(failures) failures, sum(runs) runs FROM pgvigil.collector_load GROUP BY minute ORDER BY minute DESC LIMIT 3) x")"
fi
psql "$TDSN" -Xq -c "alter role l1 login" -c "alter role l2 login" -c "alter role l3 login" >/dev/null
if waitfor 300 "SELECT NOT EXISTS (SELECT 1 FROM pgvigil.collector_parent) AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_held_instances)"; then
  sleep 200   # the passes after the hold lifts: a held 'collection failing' of a slower collection must not go out
  after=0; for n in t1 t2 t3; do after=$((after + $(spool_n firing "collection failing" $n) + $(spool_n firing "authentication failing" $n))); done
  [[ "$after" == 0 ]] && ok "D lifted: the logins back - the parent cleared, nothing held, no 'collection failing' or 'authentication failing' of t1-t3 sent in the 200 s after" \
    || fail "D lifted: $after alert(s) of t1-t3 sent after the hold lifted: $(ls "$WORK/spool" | grep -v 'collector' | head | tr '\n' ' ')"
else fail "D lifted: still a parent or a held instance 300 s after the logins came back"; fi

# ---- F many collectors on one repository ---------------------------------------------------------------------------
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

# ---- B the service stopped -----------------------------------------------------------------------------------------
waitfor 150 "SELECT count(*) = 1 FROM pgvigil.collector_live" || true
rm -f "$WORK"/spool/* "$WORK"/spool2/*
docker exec "$SVC" systemctl stop pgvigil.service
sleep 5
st=$(api '' | jget collectors | python3 -c "import json,sys; r=[x for x in json.load(sys.stdin) if x['host'] == 'pgvigil-svc'][0]; print(r['state'])")
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

# ---- G purge -------------------------------------------------------------------------------------------------------
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

echo "the service's journal (last lines): $(docker exec "$SVC" journalctl -u pgvigil -n 4 --no-pager 2>&1 | tr '\n' ' ' | cut -c1-600)"
if (( FAILS )); then echo "FAIL: $FAILS case(s)"; exit 1; fi
echo "proof-collector-health: OK (the heartbeat of a systemd unit, its load and a refused login, the page, failing together and a stopped collector each one alert with only their unread instances held, many collectors on one repository, the purge recorded)"
