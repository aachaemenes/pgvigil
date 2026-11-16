#!/usr/bin/env bash
# Proof of task 404 (B8): restarts, failovers, crash restarts and build changes as events, findings and chart marks
# (0155 and scripts/proof-restart-marker-wiring.patch) - a SQL Server container restarted and recreated on a newer CU on
# the same volume, a PostgreSQL container restarted, crashed (a backend killed) and recreated on a newer minor on the
# same volume; each change read against the server's own start time and version; the instance pages' charts in a
# headless Chromium. Run it on a scratch copy of the tree: it applies the wiring patch and builds the web there.
# Needs: docker, go, psql, curl, python3, node, npm, chromium, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_MSSQL_OLD / PGVIGIL_MSSQL_NEW  two SQL Server 2022 image tags (default: the two newest '2022-CU<n>-ubuntu-22.04'
#                   tags of mcr.microsoft.com's tag list, read at the run).
#   PGVIGIL_PG_OLD / PGVIGIL_PG_NEW  two PostgreSQL 16 minor image tags (default 16.4 and 16.6).
#   PGVIGIL_WIRING  1 (default) applies scripts/proof-restart-marker-wiring.patch when the join file lacks
#                   restart_findings; 0 = the tree as it is.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# Expected (written before the first run; red on f8e89d2 at A: no 0155, no pgvigil.instance_events):
#  A. migrate; the SQL Server container on OLD (its own volume, a fixed host name): two mssql_instance reads write no
#     event; instance.go's two wiring reads stored (404 review B, 3 and 8): physical_machine is the container's host
#     name (ComputerNamePhysicalNetBIOS, read on Linux as the host name: not yet seen on a run) and server_utc within
#     5 s of the read;
#     event (a first read is an INSERT; the start's jitter between reads is far under 120 s); the stored start within
#     2 s of sys.dm_os_sys_info's sqlserver_start_time (the container's clock is UTC: the local start is the UTC one).
#  B. docker restart, once the running start is over 150 s old (0155 needs a move over 120 s: 404 review B, 1; each
#     start is waited for as the monitoring login, which an upgrading server refuses: review B, 2): the next read
#     writes ONE event, 'restart', at the new start (within 2 s of the DMV's);
#     pgvigil.findings holds 'instance restarted' once, at severity info; /api/frame/events over the run holds 1 restart mark (the
#     container's first start was never an event and is no longer the newest), its words 'SQL Server restarted: ...'.
#  C. over 150 s after B's start, the container removed and run on NEW on the same volume (msdb's upgrade: up to 600 s;
#     the up-check waits for the monitoring login, past the script upgrade): ONE more 'restart' and ONE
#     'build' event at the new start, the build's words naming OLD's and NEW's SERVERPROPERTY('ProductVersion');
#     frame marks: restart 2, build 1; findings: 'instance restarted' 2, 'build changed' 1.
#  D. built rows on a second instance (an INSERT, then UPDATEs of its mssql_instance row, the reads a minute apart;
#     the lead's 11-14 22:5x, F17 (a) and F16's clock rule (a); red on 168ca53 at D's first physical_machine update, the
#     column being 0155's - T4's own red was shown in a sandbox run of 0155 over stand-in tables): the INSERT = no event; the start
#     60 s later = none; T4 the start 5 minutes later and T4b 5 minutes earlier on the same machine (a clock step: the
#     new start before the read before) = none; a new start 30 s after the read before = 'restart' at that start; FCI
#     the same virtual machine_name, physical_machine NODE1 then NODE2 with a new start = 'failover'; another
#     machine_name up 3 days = 'failover' at its read (not 3 days back) and a 'instance failed over' finding; the
#     product_version changed with the start unchanged = 'build' at that read's time. D2 built rows on a PostgreSQL
#     instance (T1 / T2): over onto a standby up 3 days, back, over again onto it = three 'failover' events at their
#     reads and three findings (red on 168ca53: two events, at the starts, no finding). Finding 7 (the lead's 11-14
#     23:1x, (a): a new start after the read before = restart, else failover, whatever the address; red on 81f943d,
#     where the address decided): T9 a new address with a start 30 s after the read before = 'restart' (81f943d:
#     'failover'); T10 one address (a VIP) and T11 none (a Unix socket), the standby up 3 days and started after the
#     old primary = 'failover' (81f943d: 'restart').
#  E. the PostgreSQL container on PG_OLD with its volume: two reads of instance, versions and dbstats write no event;
#     docker restart: ONE 'restart' at pg_postmaster_start_time() exactly; 40 commits, two dbstats reads, a backend killed
#     with SIGKILL (the postmaster runs crash recovery and stays up), the next dbstats read: ONE 'crash restart', the
#     postmaster start unchanged, stats_reset before and after printed and NULL after (graded: PostgreSQL 15 and later drop
#     every statistics entry at a crash); recreated on PG_NEW on the same volume and on a second network of the run (so
#     its address differs for certain: both printed; finding 7's red row, a 'failover' on 81f943d): ONE more 'restart'
#     and version_history's 'patch' row as one 'build' in instance_event_list; findings: 'instance restarted' 2, 'crash
#     restart' 1, 'build changed' 1; frame marks: restart 2, crash restart 1, build 1.
#  F. the charts in a headless Chromium (the web built from this copy with the patch): the SQL Server instance's CPU and
#     Memory pages and the PostgreSQL instance's Performance page over the run's window, in the light and the dark theme,
#     each with a chart at least; every chart whose span holds an event of /api/frame/events (restart, failover, crash
#     restart, build) carries its mark held to frame-check.mjs case S (404 review B, 4): at its instant, named
#     '<chart.ts's word: Restart / Failover / Crash restart / Build change> at ...: <the event's words>', placed at the
#     moment's share of the chart's span (within 2 %), out of the tab order (tabindex -1), its words in the list under
#     the chart; no page draws a mark that is not its instance's (0 foreign); at least one chart holding an event per
#     instance and theme; each kind's first mark on each page opens its rows' tab ('#/' + the event's tab: the
#     PostgreSQL build '#/versions'), its instance, from five minutes before it; axe-core 4.14.0 (WCAG 2.1 A and AA)
#     finds 0 violation nodes on those pages in both themes.
# NOT PROVEN HERE: a daylight-saving change on a Windows host (the containers run in UTC: F5's ticks-based start is
#   proven equal to the DMV's at A and C, the hour shift itself is not); a real availability group or cluster failover
#   (D's built rows only); a crash restart on PostgreSQL 14 or older (missed by design: stats_reset moves there too).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
PG_OLD=${PGVIGIL_PG_OLD:-16.4}; PG_NEW=${PGVIGIL_PG_NEW:-16.6}
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
LBL=pgvigil-proof=rst
PGDB=pgv_rst_$SUF; MON=pgv_rmon_$SUF; MS=pgv-rstms-$SUF; PG=pgv-rstpg-$SUF; MSVOL=pgv-rstms-$SUF; PGVOL=pgv-rstpg-$SUF; HOSTN=pgvrst$SUF
PGN1=pgv-rstpg1-$SUF; PGN2=pgv-rstpg2-$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=
SA_PW=$(pw); MON_PW=$(pw); PG_PW=$(pw | tr -d '!')
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
printf 'POSTGRES_PASSWORD=%s\n' "$PG_PW" > "$TMPD/pg.env"
printf 'MON_PW=%s\n' "$MON_PW" > "$TMPD/mon.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  # chromium is its own process group (setsid): the group killed and waited for before its profile is removed
  if [[ -n "$CHRPID" ]]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker volume rm -f "$MSVOL" "$PGVOL" >/dev/null 2>&1 || true
  echo "CLEANUP: left on this box, as pulled: the images mcr.microsoft.com/mssql/server:${MS_OLD:-?} and :${MS_NEW:-?}, postgres:${PG_OLD:-?} and :${PG_NEW:-?}" >&2
  docker network rm "$PGN1" "$PGN2" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3 node npm chromium; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && ! grep -q 'restart_findings' internal/repo/sql/0190_join_release2.sql; then
  git apply scripts/proof-restart-marker-wiring.patch 2>/dev/null || patch -p1 --forward < scripts/proof-restart-marker-wiring.patch >/dev/null \
    || fail "404's wiring patch"
  echo "404's wiring applied to this copy"
fi
if [[ -z "${PGVIGIL_MSSQL_OLD:-}" || -z "${PGVIGIL_MSSQL_NEW:-}" ]]; then
  curl -fsS -m 60 https://mcr.microsoft.com/v2/mssql/server/tags/list > "$TMPD/tags.json" || fail "mcr's tag list"
  read -r MS_OLD MS_NEW <<<"$(python3 - "$TMPD/tags.json" <<'PY'
import json, re, sys
t = sorted((int(m.group(1)), x) for x in json.load(open(sys.argv[1]))['tags'] if (m := re.fullmatch(r'2022-CU(\d+)-ubuntu-22\.04', x)))
print(t[-2][1], t[-1][1])
PY
)"
fi
MS_OLD=${PGVIGIL_MSSQL_OLD:-$MS_OLD}; MS_NEW=${PGVIGIL_MSSQL_NEW:-$MS_NEW}
echo "SQL Server images $MS_OLD -> $MS_NEW; PostgreSQL $PG_OLD -> $PG_NEW"

sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout 120 docker exec -i --env-file "$TMPD/sa.env" "$MS" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -s "|" -l 30 -d master -i /dev/stdin'; }
ps_() { docker exec -i -e PGPASSWORD="$PG_PW" "$PG" psql -h localhost -U postgres -d postgres -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
col() { local i=$1; shift; for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance "$i" -once "$c" > "$TMPD/col-$c.out" 2>&1 \
  || { cat "$TMPD/col-$c.out" >&2; fail "collect $i $c"; }; done; }
# the containers' host ports move at a restart: each start reads its port again and writes the instance's DSN
# sqm: a batch as the monitoring login (an upgrading server, in script upgrade mode, refuses every login but an
# administrator's even while msdb reads ONLINE: 404 review B, 2)
sqm() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout 60 docker exec -i --env-file "$TMPD/mon.env" "$MS" bash -c 'SQLCMDPASSWORD=$MON_PW '"$SQLCMD"' -S localhost -U '"$MON"' -C -I -W -h -1 -l 15 -d master -i /dev/stdin'; }
ms_up() { local r=; for _ in $(seq 1 "${1:-150}"); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true)
    [[ "$r" == 1 ]] && r=$(sqm "SELECT 1" 2>/dev/null | tr -d '[:space:]' || true); [[ "$r" == 1 ]] && break; sleep 4; done
  [[ "$r" == 1 ]] || { docker logs --tail 20 "$MS" >&2 2>&1 || true; fail "SQL Server did not come up (msdb online and the monitoring login answering)"; }
  local p; p=$(docker port "$MS" 1433/tcp | head -1 | sed 's/.*://'); [[ "$p" =~ ^[0-9]+$ ]] || fail "the SQL Server port [$p]"
  export PGV_RST_MS="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$p?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"; }
pg_up() { local r=; for _ in $(seq 1 90); do r=$(ps_ "select 1" 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
  [[ "$r" == 1 ]] || { docker logs --tail 20 "$PG" >&2 2>&1 || true; fail "PostgreSQL did not come up"; }
  local p; p=$(docker port "$PG" 5432/tcp | head -1 | sed 's/.*://'); [[ "$p" =~ ^[0-9]+$ ]] || fail "the PostgreSQL port [$p]"
  export PGV_RST_PG="host=127.0.0.1 port=$p user=postgres password=$PG_PW dbname=postgres sslmode=disable"; }
ms_run() { docker run -d --name "$MS" --label "$LBL-$SUF" --hostname "$HOSTN" --memory 4g --env-file "$TMPD/sa.env" -v "$MSVOL:/var/opt/mssql" \
  -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$1" >/dev/null; }
# pg_run <tag> <network>: the run's own networks, so a recreate on the second one has another address for certain
pg_run() { docker run -d --name "$PG" --label "$LBL-$SUF" --network "$2" --env-file "$TMPD/pg.env" -v "$PGVOL:/var/lib/postgresql/data" \
  -p 127.0.0.1::5432 "postgres:$1" >/dev/null; }
# events of an instance: kind=count in kind order; the newest event of a kind
evs() { pq "SELECT coalesce(string_agg(kind || '=' || n, ' ' ORDER BY kind), 'none') FROM (SELECT kind, count(*) n FROM pgvigil.instance_event_list WHERE instance_id = $1 GROUP BY kind) x"; }
# times are compared as epoch seconds (psql prints in its session's zone, the DMV in the container's)
newest() { pq "SELECT extract(epoch FROM at) FROM pgvigil.instance_events WHERE instance_id = $1 AND kind = '$2' ORDER BY at DESC LIMIT 1"; }
dmvstart() { sq "SELECT CAST(DATEDIFF_BIG(MILLISECOND, '19700101', sqlserver_start_time) / 1000.0 AS decimal(20, 3)) FROM sys.dm_os_sys_info"; }
# ms_aged: wait until the running SQL Server started over 150 s ago, so its next start moves by over 0155's 120 s (404
# review B, 1: B and C came 20-100 s after the start before); the container's clock is this host's
ms_aged() { local st; st=$(dmvstart | tr -d '[:space:]'); [[ "$st" =~ ^[0-9]+ ]] || fail "the server's start [$st]"
  while (( $(date +%s) - ${st%.*} < 150 )); do sleep 5; done; }
fnd() { pq "SELECT coalesce(string_agg(setting || '=' || n, ' ' ORDER BY setting), 'none') FROM (SELECT setting, count(*) n FROM pgvigil.findings WHERE instance_id = $1 AND source = 'pgvigil' AND setting IN ('instance restarted', 'instance failed over', 'crash restart', 'build changed') GROUP BY setting) x"; }
# within <seconds> <a> <b>: two epoch times at most that far apart
within() { python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[2]) - float(sys.argv[3])) <= float(sys.argv[1]) else 1)" "$@" 2>/dev/null; }
# frame marks of an instance over the run: kind=count
marks() { curl -fs -m 20 "$U/api/frame/events?instance=$1&from=$(urlq "$RUN_FROM")&to=$(urlq "$(date -u -d '+1 min' +%Y-%m-%dT%H:%M:%SZ)")" > "$TMPD/frame.json" || fail "GET /api/frame/events"
  python3 - "$TMPD/frame.json" "${2:-}" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))['events']; rows = [dict(zip(t['columns'], r)) for r in t['rows']]
k = {}
for r in rows:
    if r['kind'] in ('restart', 'failover', 'crash restart', 'build'): k[r['kind']] = k.get(r['kind'], 0) + 1
if sys.argv[2]: print(' | '.join(r['label'] for r in rows if r['kind'] == sys.argv[2]))
else: print(' '.join(f'{x}={k[x]}' for x in sorted(k)) or 'none')
PY
}
RUN_FROM=$(date -u -d '-5 min' +%Y-%m-%dT%H:%M:%SZ)

echo "== build: pgvigil and the web from this copy =="
(cd web && npm ci --no-audit --no-fund > "$TMPD/web.log" 2>&1 && npm run build >> "$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "the web build"; }
go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFG=$TMPD/r.yaml
printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: rstms\n    engine: sqlserver\n    dsn: env:PGV_RST_MS\n  - name: rstpg\n    dsn: env:PGV_RST_PG\n' "$PGDSN" > "$CFG"

echo "== A. SQL Server on $MS_OLD: the first reads =="
docker volume create "$MSVOL" >/dev/null; ms_run "$MS_OLD"
r=; for _ in $(seq 1 150); do r=$(sq "SELECT 1" 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done; [[ "$r" == 1 ]] || fail "A: SQL Server did not answer"
sq "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];" >/dev/null
ms_up
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
"$TMPD/pgvigil" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login > "$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 60); do grep -q "url=http://127.0.0.1:$PORT/" "$TMPD/serve.log" 2>/dev/null && break; sleep 0.5; done
U=http://127.0.0.1:$PORT
col rstms mssql_instance mssql_cpu mssql_memory; sleep 20; col rstms mssql_instance mssql_cpu mssql_memory
MSI=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'rstms'")
S0=$(pq "SELECT extract(epoch FROM started_at) FROM pgvigil.mssql_instance WHERE instance_id = $MSI"); D0=$(dmvstart)
V0=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))")
echo "   stored start $S0, the DMV's $D0, version $V0, events: $(evs "$MSI")"
[[ "$(evs "$MSI")" == none ]] || fail "A: an event from the first reads"
within 2 "$S0" "$D0" || fail "A: the stored start $S0 against the DMV's $D0"
PM=$(pq "SELECT coalesce(physical_machine, 'NULL') || '|' || coalesce((abs(extract(epoch FROM server_utc - snapshot_at)) < 5)::text, 'NULL') FROM pgvigil.mssql_instance WHERE instance_id = $MSI")
echo "   physical_machine|server_utc within 5 s of the read: $PM"
[[ "${PM^^}" == "${HOSTN^^}|TRUE" ]] || fail "A: instance.go's wiring reads [$PM] (want the host name $HOSTN and server_utc at the read)"
ok "A: two first reads write no event; the start from the ticks equals the DMV's; the physical node and the server's clock stored"

echo "== B. SQL Server restarted =="
ms_aged; docker restart "$MS" >/dev/null; ms_up; col rstms mssql_instance
S1=$(newest "$MSI" restart); D1=$(dmvstart)
E1=$(evs "$MSI"); F1=$(fnd "$MSI"); K1=$(marks "$MSI"); L1=$(marks "$MSI" restart)
echo "   events $E1; the restart at $S1, the DMV's $D1; findings $F1; marks $K1: $L1"
[[ "$E1" == "restart=1" && "$F1" == "instance restarted=1" && "$K1" == "restart=1" && "${L1,,}" == "sql server restarted: ${HOSTN,,} started "* ]] || fail "B: [$E1|$F1|$K1|$L1]"
within 2 "$S1" "$D1" || fail "B: the restart's time $S1 against the DMV's $D1"
[[ $(pq "SELECT string_agg(DISTINCT severity, ',') FROM pgvigil.findings WHERE instance_id = $MSI AND setting = 'instance restarted'") == info ]] || fail "B: the finding's severity (want info)"
ok "B: one restart at the server's new start, its finding, one mark"

echo "== C. SQL Server recreated on $MS_NEW on the same volume =="
ms_aged; docker stop -t 60 "$MS" >/dev/null; docker rm "$MS" >/dev/null; ms_run "$MS_NEW"; ms_up 150; col rstms mssql_instance
V2=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))"); D2=$(dmvstart)
E2=$(evs "$MSI"); F2=$(fnd "$MSI"); K2=$(marks "$MSI"); B2=$(marks "$MSI" build); S2=$(newest "$MSI" restart); SB2=$(newest "$MSI" build)
echo "   $V0 -> $V2; events $E2; the restart at $S2, the build at $SB2, the DMV's start $D2; findings $F2; marks $K2: $B2"
[[ "$V0" != "$V2" ]] || fail "C: the two images run one version ($V0)"
[[ "$E2" == "build=1 restart=2" && "$F2" == "build changed=1 instance restarted=2" && "$K2" == "build=1 restart=2" && "$B2" == "build changed from $V0"*" to $V2"* ]] || fail "C: [$E2|$F2|$K2|$B2]"
within 2 "$S2" "$D2" && within 2 "$SB2" "$D2" || fail "C: the events' times $S2 / $SB2 against the DMV's $D2"
col rstms mssql_cpu mssql_memory; sleep 20; col rstms mssql_cpu mssql_memory
ok "C: a restart and a build change at the new start, the build's words naming both versions"

echo "== D. built rows: the tolerance and the kinds =="
SY=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('rstsyn', 'sqlserver', '{}', now(), now(), true, 'sqlserver') RETURNING instance_id" | head -1)
# the reads a minute apart from R0, 30 minutes back: rk <k> is read k's time; the start a day before R0
R0=$(pq "SELECT date_trunc('second', now()) - interval '30 minutes'"); S0=$(pq "SELECT '$R0'::timestamptz - interval '1 day'")
rk() { echo "'$R0'::timestamptz + interval '$1 minutes'"; }
pq "INSERT INTO pgvigil.mssql_instance (instance_id, snapshot_at, machine_name, product_version, started_at) VALUES ($SY, $(rk 0), 'hosta', '16.0.1000.1', '$S0')" >/dev/null
DK=$(evs "$SY")
up() { pq "UPDATE pgvigil.mssql_instance SET snapshot_at = $(rk "$1"), $2 WHERE instance_id = $SY" >/dev/null; evs "$SY"; }
D1_=$(up 1 "started_at = '$S0'::timestamptz + interval '60 seconds'")
D4_=$(up 2 "started_at = '$S0'::timestamptz + interval '5 minutes'")
D4b=$(up 3 "started_at = '$S0'::timestamptz - interval '5 minutes'")
D2_=$(up 4 "started_at = $(rk 3) + interval '30 seconds'")
up 5 "physical_machine = 'NODE1'" >/dev/null
DF_=$(up 6 "physical_machine = 'NODE2', started_at = $(rk 5) + interval '20 seconds'")
DA_=$(up 7 "machine_name = 'hostb', physical_machine = NULL, started_at = $(rk 7) - interval '3 days'")
DAT=$(pq "SELECT round(extract(epoch FROM at - ($(rk 7))))::int || '|' || (SELECT count(*) FROM pgvigil.restart_findings f WHERE f.instance_id = $SY AND f.setting = 'instance failed over' AND f.at = e.at)
  FROM pgvigil.instance_events e WHERE e.instance_id = $SY AND e.kind = 'failover' ORDER BY e.seen_at DESC LIMIT 1")
D5_=$(up 8 "product_version = '16.0.1001.2'")
echo "   insert: $DK; +60 s: $D1_; T4 +5 min: $D4_; T4b -5 min: $D4b; a start after the read: $D2_; FCI: $DF_; another host up 3 days: $DA_ (at - its read, findings: $DAT); a build: $D5_"
[[ "$DK|$D1_|$D4_|$D4b|$D2_|$DF_|$DA_|$D5_" == "none|none|none|none|restart=1|failover=1 restart=1|failover=2 restart=1|build=1 failover=2 restart=1" ]] || fail "D: the kinds"
[[ "$DAT" == "0|1" ]] || fail "D: the failover onto a node up 3 days [$DAT] (want at its read: 0, one finding)"
[[ $(pq "SELECT abs(extract(epoch FROM at - ($(rk 8)))) < 1 FROM pgvigil.instance_events WHERE instance_id = $SY AND kind = 'build'") == t ]] || fail "D: the build without a moved start is not at its read"
ok "D: no event within 120 s, for a first read or for a clock step on one machine; a start after the read before = restart; another node (an FCI's physical name) or another host = failover, at its read when the node was up; a build at its read"
# D2 (T1 / T2): a PostgreSQL instance's failovers onto a standby up 3 days, at their reads
SP=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('rstpgsyn', 'postgres', '{}', now(), now(), true, 'postgres') RETURNING instance_id" | head -1)
pq "INSERT INTO pgvigil.instance_state (instance_id, snapshot_at, postmaster_start, server_addr) VALUES ($SP, $(rk 0), $(rk 0) - interval '10 days', '10.0.0.1')" >/dev/null
pst() { pq "UPDATE pgvigil.instance_state SET snapshot_at = $(rk "$1"), postmaster_start = $(rk "$1") - interval '$2', server_addr = '$3' WHERE instance_id = $SP" >/dev/null; }
pst 1 '3 days' 10.0.0.2; P1_=$(pq "SELECT count(*) || '|' || count(*) FILTER (WHERE at = ($(rk 1))) FROM pgvigil.instance_events WHERE instance_id = $SP")
pq "UPDATE pgvigil.instance_state SET snapshot_at = $(rk 2), postmaster_start = $(rk 2) - interval '5 days', server_addr = '10.0.0.1' WHERE instance_id = $SP" >/dev/null
pq "UPDATE pgvigil.instance_state SET snapshot_at = $(rk 3), postmaster_start = $(rk 1) - interval '3 days', server_addr = '10.0.0.2' WHERE instance_id = $SP" >/dev/null
P3_=$(pq "SELECT (SELECT count(*) FROM pgvigil.instance_events WHERE instance_id = $SP AND kind = 'failover') || '|' || (SELECT count(*) FROM pgvigil.restart_findings WHERE instance_id = $SP)")
echo "   PostgreSQL: over onto a standby up 3 days: events|at its read $P1_; over, back, over: failovers|findings $P3_"
[[ "$P1_" == "1|1" && "$P3_" == "3|3" ]] || fail "D2: [$P1_] [$P3_] (want 1|1, then 3|3)"
pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $SP" >/dev/null
# finding 7: pgcase <name> <the first address> <the second read's start> <the second address> (SQL literals): its events
pgcase() { local i; i=$(pq "INSERT INTO pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         VALUES ('$1', 'postgres', '{}', now(), now(), true, 'postgres') RETURNING instance_id" | head -1)
  pq "INSERT INTO pgvigil.instance_state (instance_id, snapshot_at, postmaster_start, server_addr) VALUES ($i, $(rk 0), $(rk 0) - interval '10 days', $2)" >/dev/null
  pq "UPDATE pgvigil.instance_state SET snapshot_at = $(rk 1), postmaster_start = $3, server_addr = $4 WHERE instance_id = $i" >/dev/null
  evs "$i"; pq "UPDATE pgvigil.instances SET is_active = false WHERE instance_id = $i" >/dev/null; }
P9_=$(pgcase rstpg9 "'172.18.0.2'" "$(rk 0) + interval '30 seconds'" "'172.18.0.3'")
P10=$(pgcase rstpg10 "'10.0.0.100'" "$(rk 1) - interval '3 days'" "'10.0.0.100'")
P11=$(pgcase rstpg11 NULL "$(rk 1) - interval '3 days'" NULL)
echo "   finding 7: T9 a new address, a start after the read before: $P9_; T10 one address (a VIP), a standby up 3 days: $P10; T11 a socket (no address): $P11"
[[ "$P9_|$P10|$P11" == "restart=1|failover=1|failover=1" ]] || fail "D2: finding 7 [$P9_|$P10|$P11] (want restart=1|failover=1|failover=1)"
ok "D2: a PostgreSQL failover onto a standby up 3 days is dated at its read with its finding; over, back and over again: three events, three findings; a start after the read before is a restart and one before it a failover, whatever the address"

echo "== E. PostgreSQL on $PG_OLD: restarted, crashed, recreated on $PG_NEW =="
docker network create --label "$LBL-$SUF" "$PGN1" >/dev/null; docker network create --label "$LBL-$SUF" "$PGN2" >/dev/null
docker volume create "$PGVOL" >/dev/null; pg_run "$PG_OLD" "$PGN1"; pg_up
col rstpg instance versions dbstats; sleep 5; col rstpg instance versions dbstats
PGI=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'rstpg'")
[[ "$(evs "$PGI")" == none ]] || fail "E: an event from the first reads: $(evs "$PGI")"
docker restart "$PG" >/dev/null; pg_up; col rstpg instance dbstats
PS1=$(ps_ "select extract(epoch from pg_postmaster_start_time())"); R1=$(newest "$PGI" restart)
echo "   restarted: events $(evs "$PGI"), the restart at $R1, pg_postmaster_start_time() $PS1"
[[ "$(evs "$PGI")" == "restart=1" ]] && within 0.001 "$R1" "$PS1" || fail "E: the restart [$(evs "$PGI")|$R1|$PS1]"
for _ in $(seq 1 40); do ps_ "select 1" >/dev/null; done
col rstpg dbstats; sleep 3; col rstpg dbstats
SR0=$(ps_ "select coalesce(stats_reset::text, 'NULL') from pg_stat_database where datname = 'postgres'")
docker exec -d -e PGPASSWORD="$PG_PW" "$PG" psql -h localhost -U postgres -d postgres -c "select pg_sleep(120)"
BP=; for _ in $(seq 1 20); do BP=$(ps_ "select pid from pg_stat_activity where query = 'select pg_sleep(120)' limit 1"); [[ -n "$BP" ]] && break; sleep 0.5; done
[[ "$BP" =~ ^[0-9]+$ ]] || fail "E: the backend to kill"
docker exec "$PG" bash -c "kill -9 $BP"; sleep 5; pg_up
PS2=$(ps_ "select extract(epoch from pg_postmaster_start_time())"); SR1=$(ps_ "select coalesce(stats_reset::text, 'NULL') from pg_stat_database where datname = 'postgres'")
col rstpg dbstats
echo "   crashed: the postmaster start $PS1 -> $PS2, stats_reset $SR0 -> $SR1, events $(evs "$PGI")"
[[ "$PS1" == "$PS2" && "$(evs "$PGI")" == "crash restart=1 restart=1" ]] || fail "E: the crash restart [$PS2|$SR1|$(evs "$PGI")]"
[[ "$SR1" == NULL ]] || fail "E: stats_reset after the crash [$SR1] (want NULL: PostgreSQL 15 and later drop every statistics entry)"
AD0=$(pq "SELECT coalesce(server_addr, 'NULL') FROM pgvigil.instance_state WHERE instance_id = $PGI")
docker stop -t 30 "$PG" >/dev/null; docker rm "$PG" >/dev/null; pg_run "$PG_NEW" "$PGN2"; pg_up; col rstpg instance versions dbstats; sleep 5; col rstpg instance dbstats
AD1=$(pq "SELECT coalesce(server_addr, 'NULL') FROM pgvigil.instance_state WHERE instance_id = $PGI")
E3=$(evs "$PGI"); F3=$(fnd "$PGI"); K3=$(marks "$PGI")
VH=$(pq "SELECT change || ' ' || old_value || ' -> ' || new_value FROM pgvigil.version_history WHERE instance_id = $PGI")
echo "   recreated: the address $AD0 -> $AD1; version_history [$VH]; events $E3; findings $F3; marks $K3"
[[ "$AD0" != "$AD1" && "$AD1" != NULL ]] || fail "E: the recreated container kept its address [$AD0 -> $AD1]: finding 7's red row is not exercised"
[[ "$VH" == "patch $PG_OLD"*" -> $PG_NEW"* && "$E3" == "build=1 crash restart=1 restart=2" && "$F3" == "build changed=1 crash restart=1 instance restarted=2" \
   && "$K3" == "build=1 crash restart=1 restart=2" ]] || fail "E: [$VH|$E3|$F3|$K3]"
ok "E: a restart at the postmaster's start, a crash restart with the postmaster kept, a recreate on another address a restart, a minor version move as a build"

echo "== F. the charts in a headless Chromium, both themes =="
(cd "$TMPD" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "F: npm install axe-core"
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
setsid chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1100 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "F: chromium's CDP port never answered"
WTO=$(date -u -d '+1 min' +%Y-%m-%dT%H:%M:%SZ)
cat > "$TMPD/f.mjs" <<'JS'
// prints one JSON line per page and theme, then one per mark clicked; the shell grades them. Each mark is held to
// frame-check.mjs case S (404 review B, 4)
const [port, U, axePath, W, pagesJson] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const pages = JSON.parse(pagesJson);
const words = { restart: 'Restart', failover: 'Failover', 'crash restart': 'Crash restart', build: 'Build change' };
const frame = async i => { const d = await (await fetch(`${U}api/frame/events?instance=${i}&${W}`)).json(); const t = d.events ?? { columns: [], rows: [] };
  return t.rows.map(r => Object.fromEntries(t.columns.map((k, n) => [k, r[n]]))).map(e => ({ ...e, at: new Date(Date.parse(e.at)).toISOString() })); };
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
// settled(hash): the document is the target route's - its hash, loaded - and its main has an h2 and no Loading line
const settled = async hash => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { if (location.hash !== ${JSON.stringify(hash)} || document.readyState !== 'complete') return false; const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && !!m.querySelector('h2'); })()`); if (ok) { await sleep(3000); return true; } await sleep(200); } return false; };
// open(hash): through about:blank, so no main of the page before survives (404green1d: a same-document hash change and
// a reload let the reads see the previous route's charts and marks, and a click land on the previous instance)
const blank = async () => { await cmd('Page.navigate', { url: 'about:blank' }); for (let i = 0; i < 50; i++) { if ((await ev('location.href')) === 'about:blank') return; await sleep(100); } throw new Error('about:blank never loaded'); };
const open = async hash => { await blank(); await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(hash); };
await open('#/instances');
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const p of pages) {
    if (!(await open(p.hash))) { console.log(JSON.stringify({ theme, hash: p.hash, instance: p.instance, error: 'did not render' })); continue; }
    const all = await frame(p.instance), mine = all.filter(e => words[e.kind]);
    const res = JSON.parse(await ev(`JSON.stringify((() => { const mine = ${JSON.stringify(mine)}, words = ${JSON.stringify(words)};
      const charts = [...document.querySelectorAll('main .chart')].filter(c => c.querySelector('.u-over'));
      return { charts: charts.length, drawn: [...document.querySelectorAll('main a.chart-mark')].map(a => a.dataset.at),
        rows: charts.map(c => { const s0 = Date.parse(c.dataset.first), s1 = Date.parse(c.dataset.last), o = c.querySelector('.u-over').getBoundingClientRect();
          const l = c.querySelector('details.chart-marks'), listed = l ? [...l.querySelectorAll('a')].map(a => a.textContent) : [];
          return { title: c.querySelector('h3')?.textContent ?? '', checks: mine.filter(e => s0 <= Date.parse(e.at) && Date.parse(e.at) <= s1).map(e => {
            const m = c.querySelector('a.chart-mark[data-kind="' + e.kind + '"][data-at="' + e.at + '"]'), r = m ? m.getBoundingClientRect() : null;
            const share = r ? ((r.left + r.width / 2) - o.left) / o.width : -1, want = (Date.parse(e.at) - s0) / (s1 - s0), label = m ? (m.getAttribute('aria-label') || '') : '';
            return { kind: e.kind, at: e.at, mark: !!m, named: label.startsWith(words[e.kind] + ' at ') && label.includes(e.label), placed: Math.abs(share - want) <= 0.02,
                     untabbed: !!m && m.getAttribute('tabindex') === '-1', listed: listed.some(t => t.includes(e.label)) }; }) }; }) }; })())`));
    const own = all.map(e => e.at);
    await ev(axeSrc + '; "ok"');
    const ax = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] } }).then(r => JSON.stringify(r.violations.map(v => v.id + ' ' + v.nodes.length)))`, true));
    console.log(JSON.stringify({ theme, hash: p.hash, instance: p.instance, charts: res.charts, rows: res.rows, foreign: res.drawn.filter(x => !own.includes(x)).length, axe: ax }));
  }
}
// each kind's first mark on each page opens its rows' tab, its instance, from five minutes before it
for (const p of pages) {
  const all = (await frame(p.instance)).filter(e => words[e.kind]);
  for (const kind of [...new Set(all.map(e => e.kind))]) {
    const e = all.find(x => x.kind === kind);
    if (!(await open(p.hash))) { console.log(JSON.stringify({ click: true, hash: p.hash, kind, error: 'did not render' })); continue; }
    const hit = await ev(`(() => { const a = document.querySelector('main a.chart-mark[data-kind=' + ${JSON.stringify(JSON.stringify(kind))} + '][data-at="${e.at}"]'); if (!a) return false; a.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })); return true; })()`);
    await sleep(800);
    const h = await ev('location.hash'), q = new URLSearchParams(h.split('?')[1] || '');
    console.log(JSON.stringify({ click: true, hash: p.hash, instance: p.instance, kind, tab: e.tab, hit, opened: h.split('?')[0], i: q.get('i'),
      from_ok: Date.parse(q.get('from') || '') === Date.parse(e.at) - 300e3 }));
  }
}
ws.close();
JS
W="from=$(urlq "$RUN_FROM")&to=$(urlq "$WTO")"
PAGES="[{\"instance\":$MSI,\"hash\":\"#/mssqlcpu?i=$MSI&$W\"},{\"instance\":$MSI,\"hash\":\"#/mssqlmemory?i=$MSI&$W\"},{\"instance\":$PGI,\"hash\":\"#/performance?i=$PGI&$W\"}]"
# DIAG F (the j16 LAST run's diagnostic of j16d3's red, where the PostgreSQL page drew 0 charts): what that page reads
# over the walk's window, printed whatever F's result - the row count of each part of GET /api/performance, and
# pgvigil.dbstats_rate's rows (the 'db' part's source) - so a page with no chart names its empty read
if curl -fs -m 60 "$U/api/performance?instance=$PGI&$W" > "$TMPD/perf.json"; then
  python3 - "$TMPD/perf.json" <<'PYD' || echo "DIAG F: the reply of GET /api/performance did not parse"
import json, sys
d = json.load(open(sys.argv[1]))
print('DIAG F: GET /api/performance (the PostgreSQL instance, the walk\'s window): ' + ', '.join(
    f"{k} {len(v['rows'])} rows" if isinstance(v, dict) and isinstance(v.get('rows'), list) else f"{k} {type(v).__name__}" for k, v in d.items()))
PYD
else echo "DIAG F: GET /api/performance?instance=$PGI did not answer"; fi
echo "DIAG F: pgvigil.dbstats_rate($PGI) from $RUN_FROM to $WTO: $(pq "SELECT count(*) || ' rows, ' || count(DISTINCT datname) || ' databases, ' || count(*) FILTER (WHERE reset) || ' reset, ' || coalesce(min(snapshot_at)::text, '-') || ' .. ' || coalesce(max(snapshot_at)::text, '-') FROM pgvigil.dbstats_rate($PGI, '$RUN_FROM', '$WTO')" 2>&1 | tr '\n' ' ' | cut -c1-300)"
node "$TMPD/f.mjs" "$CDP" "$U/" "$TMPD/node_modules/axe-core/axe.min.js" "$W" "$PAGES" > "$TMPD/f.out" || { cat "$TMPD/f.out" >&2; fail "F: the Chromium walk stopped"; }
python3 - "$TMPD/f.out" "$MSI" "$PGI" <<'PY' || fail "F: see above"
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in lines if not r.get('click')]; clicks = [r for r in lines if r.get('click')]
bad, per = [], {}
for r in rows:
    held = [c for c in r.get('rows', []) if c['checks']]
    wrong = [f"{c['title']}: {x['kind']} {x['at']} " + ','.join(k for k in ('mark', 'named', 'placed', 'untabbed', 'listed') if not x[k])
             for c in held for x in c['checks'] if not all(x[k] for k in ('mark', 'named', 'placed', 'untabbed', 'listed'))]
    print(f"   {r['theme']:5} {r['hash'].split('&')[0]}: {r.get('charts')} charts, {len(held)} holding an event, {r.get('foreign')} foreign marks; axe {r.get('axe')}"
          + (f"; wrong {wrong}" if wrong else '') + (f"; {r['error']}" if r.get('error') else ''))
    if r.get('error') or not r.get('charts') or wrong or r.get('foreign') or r.get('axe'): bad.append(r['hash'])
    per[(r['instance'], r['theme'])] = per.get((r['instance'], r['theme']), 0) + len(held)
for i in (int(sys.argv[2]), int(sys.argv[3])):
    for t in ('light', 'dark'):
        if per.get((i, t), 0) < 1: bad.append(f'instance {i} {t}: no chart holds an event')
for c in clicks:
    ok = not c.get('error') and c.get('hit') and c.get('opened') == '#/' + str(c.get('tab')) and c.get('i') == str(c.get('instance')) and c.get('from_ok')
    print(f"   click {c['hash'].split('?')[0]} {c['kind']}: opened {c.get('opened')} (its tab {c.get('tab')}), i {c.get('i')}, from five minutes before {c.get('from_ok')}" + ('' if ok else ' - WRONG'))
    if not ok: bad.append(f"click {c['kind']}")
if not any(c['instance'] == int(sys.argv[3]) and c['kind'] == 'build' and c.get('opened') == '#/versions' for c in clicks): bad.append('the PostgreSQL build mark did not open #/versions')
sys.exit(1 if bad or len(rows) != 6 else 0)
PY
ok "F: every mark of a chart holding an event at its instant, named, placed, out of the tab order and listed; no foreign mark; each kind's mark opens its tab; axe 0 on those pages, both themes"

echo "NOT PROVEN HERE: a daylight-saving change on a Windows host; a real availability group or cluster failover; a crash restart on PostgreSQL 14 or older"
echo "PROOF OK: restart marker (A B C D E F)"
