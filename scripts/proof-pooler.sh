#!/usr/bin/env bash
# Proof of the pooler traced (task 128: internal/collect/pgbouncer.go's SHOW CLIENTS and SHOW SERVERS, migration
# 0081_pooler_clients.sql, internal/web/q_pooler.go, web/src/pooler.ts and running.ts) against a real PgBouncer.
#
# Needs: psql, curl, python3, docker with the PgBouncer image, chromium and node, and:
#   PGVIGIL_REPO_DSN   a superuser connection to the PostgreSQL sandbox in KEYWORD form (host=... user=...), no dbname
#   PGVIGIL_BIN        the binary (default bin/pgvigil), built from a tree with the route GET /api/pooler/conns (the
#                      lead's wiring in web.go) and a current bundle
#   PGB_IMAGE          the PgBouncer image (default edoburu/pgbouncer:v1.26.1-p0), run on the host network with the
#                      proof's own pgbouncer.ini and killed by its own name at the end
#   PGB_UPSTREAM       host:port the PgBouncer reaches the sandbox at (default 127.0.0.1:5432: the sandbox of
#                      PGVIGIL_REPO_DSN must listen there, or the pooler cannot connect and A fails)
# The proof makes, and drops on every exit path: its own repository database, one monitored database (one table), a
# pg_monitor login and an application role (random suffix and passwords); its own PgBouncer container, pgvigil serve,
# Chromium and psql clients, stopped by their names and pids. It changes no server setting.
#
# Expected (written before the first run):
#  A. PgBouncer 1.26.1 in transaction mode, pool_size 3, in front of the monitored database. A holder (application
#     pgvpool_h_<n>) opens a transaction through the pooler, updates row 1 and stays idle in it: it keeps one server.
#     [review fold] One more client (application pgvpool_i_<n>) connects through the pooler, runs SELECT 1 and stays
#     connected outside a transaction: idle, counted and not stored.
#     Then 19 clients (application pgvpool_w_<n>) each update row 1 through the pooler: two get the other two servers
#     and wait on the holder's lock (one on its transactionid, one on the tuple behind the first), 17 wait in the
#     pooler. After 6 s, collect -once pgbouncer and collect -once activity. In the repository:
#     - the read's conns row: clients_read 21, clients_kept 20 (the idle one counted, not kept), servers_read 3;
#     - 17 client rows 'waiting' (each wait_us > 0, application pgvpool_w_<n>) and 3 'active';
#     - 3 server rows whose remote_pids are exactly the pids pg_stat_activity holds for the application role in the
#       monitored database (a hand read at the same moment);
#     - the pool row of SHOW POOLS: cl_waiting 17, sv_active 3, pool_size 3;
#     - pooler_conns: the holder's server has role 'head', backend_state 'idle in transaction', paired_application
#       pgvpool_h_<n>; the other two servers role 'blocked', backend_wait_type Lock, head_pid = the holder's pid (from
#       pg_stat_activity by its application); head_via_pooler true and head_client_application pgvpool_h_<n> on both;
#       [review fold] backend_match 'matched' on all three; the clients' connect_time within 5 minutes of now (the
#       pooler's local time placed by its own clock);
#       the 3 active clients carry a backend_pid, the 17 waiting none. [first run, 2026-11-10: the holder's
#       backend_wait_type read 'Client' where this line expected none: PostgreSQL shows an idle-in-transaction session
#       waiting on Client: ClientRead. Expected now: the head's wait type 'Client'.]
#  B. the API (pgvigil serve -no-login): /api/pooler/conns for the instance: read clients_read 21 and an activity_at
#     within two minutes of read_at; clients 20 rows, 17 waiting; servers 3; trace one row for the database and role:
#     clients_waiting 17, servers 3, servers_active 3, servers_blocked 2, servers_heading 1, head_pids [holder] (the
#     heads its BLOCKED servers wait behind), heading_pids [holder] (its own server that heads), servers_elsewhere 0;
#     heads one row: head_pid holder, servers_behind 2, clients_waiting 17, head_state 'idle in transaction',
#     head_via_pooler true. part=nonsense answers 400; at = a day before every read gives an empty read part.
#  C. the pages in a headless Chromium: the Pooler tab shows the trace line with '17 client(s) waiting' and 'behind
#     head pid <holder>', the Clients grid with 17 cells 'waiting', the Servers grid with 3 rows each linking a pid to
#     Running queries, the holder's among them. Running queries shows the status line 'Pooler: 17 client(s) waiting in
#     PgBouncer' naming head pid <holder>, the chain tree's head row of pid <holder> with 'pooler: pgvpool_h_<n>' in its
#     pooler column, and 3 'pooler:' cells in the Sessions grid.
#  D. the import's edges: the same read imported again leaves 1 conns row and 23 client and server rows (replaced, not
#     doubled); a later payload without conns rows (an older collector, a console refusing SHOW CLIENTS) stores none,
#     and pooler_read_at for that later time still gives the proof's read (within two minutes) and pooler_conns its rows.
#  NOT PROVEN HERE: a pooler with thousands of clients (the cap of 1000 and its order are unit-tested in
#  pgbouncer_test.go, TestPgBouncerConnCap), a pooler routing to another host (the login and database match is read,
#  not run), a pooler in another time zone (TestPgBouncerConnTimes), PgBouncer before 1.21 (no 'idle' client state: every client is kept up to the cap), session mode, a server pool
#  through TLS, the page's look (looked at by hand against pgbouncer-pages.md's console reads), PostgreSQL 13 (0081 is
#  migrated there by hand: the CI matrix's lowest version).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
PGB_IMAGE=${PGB_IMAGE:-edoburu/pgbouncer:v1.26.1-p0}
PGB_UPSTREAM=${PGB_UPSTREAM:-127.0.0.1:5432}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_poolproof_$SUF; MDB=pgvpool_db_$SUF
MON=pgvpool_mon_$SUF; MONPW=p$RANDOM$RANDOM; APP=pgvpool_app_$SUF; APPPW=p$RANDOM$RANDOM
STATSU=pgvpool_stats_$SUF; STATSPW=p$RANDOM$RANDOM
HAPP=pgvpool_h_$SUF; WAPP=pgvpool_w_$SUF; IAPP=pgvpool_i_$SUF
PGBNAME=pgvigil-proof-pool-$SUF; PGBPORT=$((30000 + RANDOM % 20000))
while ss -ltnH "sport = :$PGBPORT" | grep -q .; do PGBPORT=$((30000 + RANDOM % 20000)); done
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
SRVPID=; CHRPID=; HOLD_OPEN=; IDLE_OPEN=; CLIENTS=()
cleanup() {
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  [ -n "$CHRPID" ] && kill "$CHRPID" 2>/dev/null || true
  [ -n "$HOLD_OPEN" ] && exec 8>&- 2>/dev/null || true
  [ -n "$IDLE_OPEN" ] && exec 9>&- 2>/dev/null || true
  for p in "${CLIENTS[@]}"; do kill "$p" 2>/dev/null || true; done
  docker kill "$PGBNAME" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $MDB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" -c "drop role if exists $APP" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in docker psql curl python3 chromium node; do command -v $t >/dev/null || fail "$t is not on this machine"; done

psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" -c "create database $MDB" \
  -c "create role $MON login password '$MONPW' in role pg_monitor" -c "create role $APP login password '$APPPW'" >/dev/null
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "create table public.pgv_pool_t (id int primary key, v int)" \
  -c "insert into public.pgv_pool_t values (1, 0)" -c "grant select, update on public.pgv_pool_t to $APP" \
  -c "grant connect on database $MDB to $APP" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export SBX_DSN="$ADMIN_DSN dbname=$MDB user=$MON password=$MONPW"
export PGB_DSN="host=127.0.0.1 port=$PGBPORT dbname=pgbouncer user=$STATSU password=$STATSPW sslmode=disable"
POOLED="host=127.0.0.1 port=$PGBPORT dbname=$MDB user=$APP password=$APPPW sslmode=disable"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
adm() { psql "$ADMIN_DSN dbname=$MDB" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-pool-$SUF
    dsn: env:SBX_DSN
    pgbouncer: env:PGB_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -instance "proof-pool-$SUF" -once "$1" >/dev/null 2>&1 || fail "collect -once $1 failed"; }

echo "--- A. a real PgBouncer: 20 clients on a pool of 3, one holder in a lock"
cat > "$WORK/pgbouncer.ini" <<EOF
[databases]
$MDB = host=${PGB_UPSTREAM%:*} port=${PGB_UPSTREAM##*:} dbname=$MDB pool_size=3
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $PGBPORT
auth_type = plain
auth_file = /etc/pgbouncer-proof/userlist.txt
pool_mode = transaction
default_pool_size = 3
max_client_conn = 100
stats_users = $STATSU
EOF
printf '"%s" "%s"\n"%s" "%s"\n' "$APP" "$APPPW" "$STATSU" "$STATSPW" > "$WORK/userlist.txt"
chmod 644 "$WORK/pgbouncer.ini" "$WORK/userlist.txt"; chmod 755 "$WORK"
docker run -d --rm --name "$PGBNAME" --network host -v "$WORK:/etc/pgbouncer-proof:ro" --entrypoint pgbouncer "$PGB_IMAGE" /etc/pgbouncer-proof/pgbouncer.ini >/dev/null
for _ in $(seq 1 50); do psql "$PGB_DSN" -XAtq -c "show version" >/dev/null 2>&1 && break; sleep 0.2; done
psql "$PGB_DSN" -XAtq -c "show version" >/dev/null 2>&1 || fail "A: the pooler did not start: $(docker logs "$PGBNAME" 2>&1 | tail -5)"
mkfifo "$WORK/hold"
PGAPPNAME=$HAPP psql "$POOLED" -XAtq < "$WORK/hold" > "$WORK/hold.out" 2>&1 & CLIENTS+=($!)
exec 8>"$WORK/hold"; HOLD_OPEN=1
printf 'BEGIN;\nUPDATE public.pgv_pool_t SET v = v + 1 WHERE id = 1;\n' >&8
HP=
for _ in $(seq 1 50); do
  HP=$(adm "select pid from pg_stat_activity where application_name = '$HAPP' and state = 'idle in transaction'")
  [ -n "$HP" ] && break; sleep 0.2
done
[ -n "$HP" ] || fail "A: the holder is not idle in transaction: $(cat "$WORK/hold.out")"
mkfifo "$WORK/idle"
PGAPPNAME=$IAPP psql "$POOLED" -XAtq < "$WORK/idle" > "$WORK/idle.out" 2>&1 & CLIENTS+=($!)
exec 9>"$WORK/idle"; IDLE_OPEN=1
printf 'SELECT 1;\n' >&9
for _ in $(seq 1 50); do grep -q '^1$' "$WORK/idle.out" && break; sleep 0.1; done
grep -q '^1$' "$WORK/idle.out" || fail "A: the idle client's SELECT 1 did not run through the pooler: $(cat "$WORK/idle.out")"
for _ in $(seq 1 19); do
  PGAPPNAME=$WAPP psql "$POOLED" -XAtq -c "UPDATE public.pgv_pool_t SET v = v + 1 WHERE id = 1" >/dev/null 2>&1 & CLIENTS+=($!)
done
sleep 6
collect pgbouncer
collect activity
SVPIDS=$(adm "select string_agg(pid::text, ',' order by pid) from pg_stat_activity where datname = '$MDB' and usename = '$APP'")
I=$(q "select instance_id from pgvigil.instances where name = 'proof-pool-$SUF'")
R=$(q "select clients_read || '|' || clients_kept || '|' || servers_read from pgvigil.pooler_conn_sample where instance_id = $I and kind = 'conns'")
echo "conns: $R (holder pid $HP; backends $SVPIDS)"; [ "$R" = "21|20|3" ] || fail "A: the conns row"
R=$(q "select count(*) filter (where state = 'waiting' and wait_us > 0 and application_name = '$WAPP') || '|' || count(*) filter (where state = 'active')
         from pgvigil.pooler_conn_sample where instance_id = $I and kind = 'client'")
echo "clients waiting|active: $R"; [ "$R" = "17|3" ] || fail "A: the client rows"
R=$(q "select string_agg(remote_pid::text, ',' order by remote_pid) from pgvigil.pooler_conn_sample where instance_id = $I and kind = 'server'")
echo "servers' remote_pids: $R"; [ "$R" = "$SVPIDS" ] || fail "A: the servers' remote_pids are not the role's backends ($SVPIDS)"
R=$(q "select cl_waiting || '|' || sv_active || '|' || pool_size from pgvigil.pooler_sample where instance_id = $I and kind = 'pool' and database = '$MDB'")
echo "pool: $R"; [ "$R" = "17|3|3" ] || fail "A: the pool row"
R=$(q "select string_agg(role || '|' || coalesce(backend_state, '-') || '|' || coalesce(backend_wait_type, '-') || '|' || coalesce(head_pid::text, '-') || '|'
                         || coalesce(paired_application, '-') || '|' || head_via_pooler || '|' || coalesce(head_client_application, '-'), ',' order by role, backend_pid)
         from pgvigil.pooler_conns($I, now()) where kind = 'server'")
echo "servers traced: $R"
[ "$R" = "blocked|active|Lock|$HP|$WAPP|true|$HAPP,blocked|active|Lock|$HP|$WAPP|true|$HAPP,head|idle in transaction|Client|$HP|$HAPP|true|$HAPP" ] || fail "A: the servers traced"
R=$(q "select count(*) filter (where state = 'active' and backend_pid is not null) || '|' || count(*) filter (where state = 'waiting' and backend_pid is null)
         from pgvigil.pooler_conns($I, now()) where kind = 'client'")
echo "clients with|without a backend: $R"; [ "$R" = "3|17" ] || fail "A: the clients' backends"
R=$(q "select count(*) filter (where backend_match = 'matched') from pgvigil.pooler_conns($I, now()) where kind = 'server'")
echo "servers matched by pid, login and database: $R"; [ "$R" = 3 ] || fail "A: the backend match"
R=$(q "select count(*) filter (where connect_time between now() - interval '5 minutes' and now() + interval '1 minute') || '|' || count(*)
         from pgvigil.pooler_conn_sample where instance_id = $I and kind = 'client'")
echo "clients' connect_time near now: $R"; [ "$R" = "20|20" ] || fail "A: the pooler's times are not placed at now"
echo "A: OK"

echo "--- B. the API"
PORT=$((20000 + RANDOM % 20000)); while ss -ltnH "sport = :$PORT" | grep -q .; do PORT=$((20000 + RANDOM % 20000)); done
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/serve.yaml"
"$BIN" serve -config "$WORK/serve.yaml" -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "B: serve exited: $(cat "$WORK/serve.out")"
U="http://127.0.0.1:$PORT/api/pooler/conns"
curl -fs "$U?instance=$I" > "$WORK/conns.json" || fail "B: /api/pooler/conns (is the route wired in web.go?)"
python3 - "$WORK/conns.json" "$HP" "$MDB" "$APP" <<'PY' || fail "B: the parts"
import json, sys, datetime as dt
d = json.load(open(sys.argv[1])); hp = int(sys.argv[2]); db, usr = sys.argv[3], sys.argv[4]
rows = lambda p: [dict(zip(d[p]["columns"], r)) for r in d[p]["rows"]]
assert sorted(d) == ["clients", "heads", "read", "servers", "trace"], sorted(d)
r = rows("read")[0]
assert r["clients_read"] == 21 and r["activity_at"] is not None, r
assert abs((dt.datetime.fromisoformat(r["activity_at"]) - dt.datetime.fromisoformat(r["read_at"])).total_seconds()) <= 120, r
c = rows("clients"); assert len(c) == 20 and sum(x["state"] == "waiting" for x in c) == 17, c
assert len(rows("servers")) == 3, rows("servers")
t = rows("trace"); assert len(t) == 1, t
t = t[0]
want = dict(database=db, user=usr, clients_waiting=17, servers=3, servers_active=3, servers_blocked=2, servers_heading=1, head_pids=[hp], heading_pids=[hp], servers_elsewhere=0)
assert all(t[k] == v for k, v in want.items()), (t, want)
h = rows("heads"); assert len(h) == 1, h
h = h[0]
assert h["head_pid"] == hp and h["servers_behind"] == 2 and h["clients_waiting"] == 17 and h["head_state"] == "idle in transaction" and h["head_via_pooler"] is True, h
print(f"  trace: {t['clients_waiting']} waiting, {t['servers_blocked']} of {t['servers']} servers blocked behind head {hp}")
PY
code=$(curl -s -o /dev/null -w '%{http_code}' "$U?instance=$I&part=nonsense"); [ "$code" = 400 ] || fail "B: an unknown part answered $code"
DAY=$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)
[ "$(curl -fs "$U?instance=$I&at=$DAY&part=read" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["read"]["rows"]))')" = 0 ] || fail "B: a time before every read gives a read"
echo "B: OK"

echo "--- C. the pages in a headless Chromium"
CDP=$((PORT + 1)); while ss -ltnH "sport = :$CDP" | grep -q .; do CDP=$((CDP + 1)); done
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.out" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 || fail "C: chromium did not start: $(cat "$WORK/chrome.out")"
cat > "$WORK/look.mjs" <<'JS'
const [port, U, iid, hp, happ] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (e) => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (e, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await ev(e)) return true; await sleep(200); } return false; };
const fails = [];
const check = (ok, what) => { if (!ok) fails.push(what); };
const tableAfter = h => `[...document.querySelectorAll('h3')].find(x => x.textContent.startsWith(${JSON.stringify(h)}))`;
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: `${U}#/pooler?i=${iid}&w=1h` });
check(await until(`!!${tableAfter('Servers (SHOW SERVERS)')}`), 'no Servers (SHOW SERVERS) section on the Pooler tab');
const p = await ev(`(() => {
  const next = h => { let n = h?.nextElementSibling; while (n && !n.querySelector?.('table') && n.tagName !== 'TABLE') n = n.nextElementSibling; return n?.tagName === 'TABLE' ? n : n?.querySelector('table'); };
  const cl = next(${tableAfter('Clients (SHOW CLIENTS)')}), sv = next(${tableAfter('Servers (SHOW SERVERS)')});
  const trace = document.querySelector('ul.pooler-trace')?.textContent ?? '';
  return { trace, waiting: [...(cl?.querySelectorAll('tbody td') ?? [])].filter(td => td.textContent === 'waiting').length,
    servers: [...(sv?.querySelectorAll('tbody tr') ?? [])].map(r => r.querySelector('td a')?.textContent ?? '') };
})()`);
check(p.trace.includes('17 client(s) waiting') && p.trace.includes(`behind head pid ${hp}`), `the trace line: ${p.trace}`);
check(p.waiting === 17, `17 waiting cells in Clients, got ${p.waiting}`);
check(p.servers.length === 3 && p.servers.every(s => /^pid \d+$/.test(s)) && p.servers.includes(`pid ${hp}`), `3 server rows linking a pid, the holder's among them: ${JSON.stringify(p.servers)}`);
console.log(`  Pooler: ${p.trace.trim()}; ${p.waiting} waiting; servers ${JSON.stringify(p.servers)}`);
await cmd('Page.navigate', { url: `${U}#/activity?i=${iid}&w=1h` });
check(await until(`!!document.querySelector('.pooler-status') && !!document.querySelector('.chain-tree')`), 'no pooler status line or chain tree on Running queries');
const r = await ev(`(() => {
  const status = document.querySelector('.pooler-status')?.textContent ?? '';
  const tree = document.querySelector('.chain-tree');
  const hd = [...tree.querySelectorAll('thead th')].map(th => th.textContent);
  const pc = hd.indexOf('pooler');
  const head = [...tree.querySelectorAll('tbody tr')].map(r => [...r.children].map(c => c.textContent)).find(c => c[0].trim() === ${JSON.stringify(hp)});
  const all = [...document.querySelectorAll('table')].filter(t => !tree.contains(t));   // [first run: the tree class is on the grid's wrapper, its table counted 3 more]
  const cells = all.flatMap(t => [...t.querySelectorAll('tbody td')]).filter(td => td.textContent.startsWith('pooler:')).length;
  return { status, headPooler: head && pc >= 0 ? head[pc] : null, cells };
})()`);
check(r.status.includes('Pooler: 17 client(s) waiting in PgBouncer') && r.status.includes(`head pid ${hp}`), `the status line: ${r.status}`);
check(r.headPooler === `pooler: ${happ}`, `the head row's pooler cell: ${r.headPooler}`);
check(r.cells === 3, `3 pooler: cells in Sessions, got ${r.cells}`);
console.log(`  Running: ${r.status.trim()}; head ${hp} ${r.headPooler}; ${r.cells} pooler cells`);
ws.close();
if (fails.length) { console.log('FAIL ' + fails.join('; ')); process.exit(1); }
JS
node "$WORK/look.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$I" "$HP" "$HAPP" || fail "C: the pages"
echo "C: OK"

echo "--- D. the import's edges"
AT=$(q "select snapshot_at from pgvigil.pooler_conn_sample where instance_id = $I and kind = 'conns'")
q "select pgvigil.import_pgbouncer($I, '$AT', (select jsonb_agg(x) from (
     select jsonb_build_object('kind', 'state', 'status', 'ok') x
     union all select jsonb_build_object('kind', kind, 'database', database, 'user', usr, 'state', state, 'application_name', application_name,
       'wait_us', wait_us, 'ptr', ptr, 'link', link, 'remote_pid', remote_pid, 'clients_read', clients_read, 'clients_kept', clients_kept,
       'servers_read', servers_read) from pgvigil.pooler_conn_sample where instance_id = $I and snapshot_at = '$AT') y))" >/dev/null
R=$(q "select count(*) filter (where kind = 'conns') || '|' || count(*) filter (where kind <> 'conns') from pgvigil.pooler_conn_sample where instance_id = $I")
echo "after a re-import of the read: $R"; [ "$R" = "1|23" ] || fail "D: a re-import doubled the rows"
q "select pgvigil.import_pgbouncer($I, '$AT'::timestamptz + interval '60 seconds', '[{\"kind\":\"state\",\"status\":\"ok\"},{\"kind\":\"pool\",\"database\":\"$MDB\",\"user\":\"$APP\",\"cl_waiting\":0}]')" >/dev/null
R=$(q "select count(*) from pgvigil.pooler_conn_sample where instance_id = $I and snapshot_at > '$AT'")
L=$(q "select (pgvigil.pooler_read_at($I, '$AT'::timestamptz + interval '60 seconds') = '$AT') || '|' || (select count(*) from pgvigil.pooler_conns($I, '$AT'::timestamptz + interval '60 seconds'))")
echo "a read without conns: $R row(s) stored; the read shown for its time is the proof's, with its rows: $L"
[ "$R" = 0 ] && [ "$L" = "true|23" ] || fail "D: a payload without conns"
echo "D: OK"
echo "PASS proof-pooler"
