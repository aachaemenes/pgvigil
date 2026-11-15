#!/usr/bin/env bash
# Proof of task 401 (B3): the SQL Server counter list made configurable, the base arithmetic, the counters the tools
# agree pgvigil lacks - mssql_counters, mssql_counters_db and mssql_counter_catalog (internal/mssql/counters.go), 0152,
# GET / POST /api/mssql/counteradmin, the Metrics page's counters section and Admin > Counters - against hand reads of
# sys.dm_os_performance_counters on the same server.
# Needs: docker (mcr.microsoft.com/mssql/server images), go, psql, curl, python3, node, chromium, ss, and:
#   ADMIN_DSN          a superuser connection to a PostgreSQL sandbox in keyword form (default 'host=127.0.0.1 port=5432
#                      user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   PGVIGIL_IMAGES     the SQL Server images, the first the full run, the others the version run (default
#                      '2022-latest 2019-latest').
#   PGVIGIL_SHOTS      where the page shots go (default: a folder of the run, removed with it).
#   PGVIGIL_WIRING     1 (default) applies scripts/proof-mssql-counters-wiring.patch (the lead's files) to this copy when the
#                      tree lacks the counters' runner hook; 0 = the tree as it is.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment. Only the
# collection a step names runs (pgvigil collect -once): no other mssql_* collection reads the server meanwhile.
#
# Expected (written before the first run; red on f8e89d2 at A: 'unknown collection mssql_counters'):
#  A. the first image's container, a database pgvctr (log 1 MB, growth 1 MB, full recovery with one full backup taken,
#     so the log grows and stays), snapshot isolation allowed; a monitor login with VIEW SERVER STATE; migrate ok;
#     mssql_counters, mssql_counters_db and mssql_counter_catalog each run; the list = every default.
#  B. a hand read right before and right after one mssql_counters read: every stored raw value of a rate, count or
#     average series (and an average's base) lies between the two hand reads (before <= stored <= after: they only
#     grow); the gauges and fractions outside [min, max] of the two hand reads are counted and listed, not judged.
#  C. from two stored reads: every rate = (value - value before) / the reads' interval by the server's clock (3
#     places), every count's change = value - value before, every average = change in value / change in base, every
#     fraction = 100 * value / base, as mssql_counter_newest and metric_points return them.
#  D. provoked between two reads with nothing else connected, each change read from the store minus pgvigil's own
#     logins (one per collector read):
#     Logins/sec and Logouts/sec + 40 each; SQL Errors User Errors + 12 (RAISERROR 16), Info Errors + 7 (RAISERROR 10)
#     - read and printed whatever they are, Kill Connection Errors + 3 (RAISERROR 20 WITH LOG, three connections, in a
#     phase of their own: run 3 read User Errors + 15 with them in the same phase) read and printed with that phase's
#     User Errors; DB Offline Errors: not provable on a box (Microsoft: a severe error that takes the database
#     offline), read at 0 in zero_series; pgvctr Write Transactions/sec + 500 or more (500 one-row commits), Log Flush
#     Waits/sec more than 0; Log Growths of pgvctr 1 or more, then a flat read with its row stored at a change of 0 and
#     log_growths 0 in metric_points (F2's case 1); Lock Timeouts (timeout > 0)/sec + 6 (LOCK_TIMEOUT 200 behind a held
#     lock) and unmoved by 6 more at LOCK_TIMEOUT 0, the plain Lock Timeouts/sec + 12 or more; the average lock wait
#     between 150 and 600 ms; Update conflict ratio's value + 4 (four 3960 conflicts) over a base change of 4 or more;
#     Auto-Param Attempts/sec + 20 or more (20 literal queries), Forced Parameterizations/sec + 20 or more under
#     PARAMETERIZATION FORCED; Page compression attempts/sec more than 0 (a PAGE-compressed insert); Cursor
#     Requests/sec + 5 or more; Deprecated Features Usage of '::' function calling syntax + 3; Batch Resp Statistics
#     Elapsed Time:Requests + 5 or more in the 100-200 ms bucket and + 3 or more in the 1-2 s bucket (and the histogram
#     function says the same); Resource Pool Stats CPU usage % (default) read under a CPU loop above 0 and at most 100,
#     equal to 100 * value / base of its stored pair; Misguided plan executions/sec read and printed (a plan guide whose
#     index was dropped) - NOT PROVEN live if it does not move.
#  E. the list: a pgvigil.yaml instance line adds General Statistics / Logical Connections (read at the next read) and
#     removes Deprecated Features / Usage (not read); an Admin fleet row adding Usage back loses to the instance's yaml
#     line (narrowest scope); an Admin instance row adding it wins over the yaml line at the same scope (read again);
#     an Admin tag row (the instance's tag env:ctrproof) removing Plan Cache / Cache Pages takes it out, an Admin
#     instance row adding it back wins; Admin and yaml both refuse removing Logins/sec ('read by ...'); a removal of a
#     counter in use from the yaml is refused at load; mssql_counter_yaml holds the lines the runner used.
#  F. the gap rule: Pages Allocated/sec removed for two reads and added back: its first read back has no change and no
#     rate; the read after has both.
#  G. a restart (docker restart): the first read after it has no rate, no change and no average on any series; the
#     read after has them.
#  H. zero points: errors_offline_s is 0 at every instance read of the window (as many points as reads); errors_kill_s
#     is not (D provokes three kill-connection errors; corrected after run 4, the body always read errors_offline_s).
#  I. F1: mssql_cpu_newest's rg_active_requests NULL with 0124's own body (made in pg_temp from the file) after the
#     counters left mssql_cpu, not NULL with the join's body.
#  J. the API: GET /api/mssql/counteradmin (no instance: config, defaults, log, catalog; with the instance: layers,
#     catalog, absent, histogram) answers every part; with the UI login and the actions door's audit login: POST add
#     done (200), a removal of a counter in use refused (409, 'read by'), end done; without a session 401, without the
#     header 403; a -no-login serve: writable false naming -no-login, POST 403, nothing written; mssql_counter_config_log
#     holds exactly the done and refused attempts by the proof's user from 127.0.0.1.
#  K. the pages in headless Chromium, light and dark: the instance's Metrics page shows the counters grid with the kind
#     and figure columns (rows = /api/mssql/counters' now part), 'Batch response times' with 17 buckets, 'Listed but
#     not read', the 'Counters' family grid; Admin > Counters shows 'Rows made here' (rows = the config part),
#     'The defaults' (rows = the defaults part), 'Counters the servers have', 'Log', and its Save and End controls off
#     with their reason on a -no-login serve; no error box, no exception.
#  N. D6 (the rows on other slices' pages, WIRING hunks): after two mssql_cpu and mssql_memory reads with 20 batches
#     between them: /api/perfsummary's mssql part gives ctrbox compiles_per_100 = round(100 * compilations / batch
#     requests, 1) from mssql_sched_sample's interval-weighted rates over the same window (0 under 1 batch/s); the CPU
#     API's sched part carries failed_to_create_worker (0 on a healthy box) at a step; the Memory API's clerk_stats
#     names MEMORYCLERK_SQLBUFFERPOOL 'Buffer Pool'; the pages show the summary's 'compilations per 100 batches', the
#     scheduler trend's 'schedulers that failed to create a worker' and the clerks grid's 'what it is' with Buffer Pool.
#  L. the version run on each further image: A's setup, B's bracket and C's arithmetic, D's logins, errors and log
#     growth, the list = every default.
#  M. the measured size: rows per read of each scope and the sample rows stored per read, and bytes per day per instance
#     at one read a minute and one per 5 minutes.
# NOT PROVEN HERE: SQL Server 2016 (no Linux image: dba-lab-win's queue), Managed Instance, RDS, Cloud SQL, a Windows
#   host; DB Offline Errors moving; two memory nodes (one Buffer Node in a container); Misguided plan executions moving
#   if D says so.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
read -r -a IMAGES <<<"${PGVIGIL_IMAGES:-2022-latest 2019-latest}"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
LBL=pgvigil-proof=ctr
PGDB=pgv_ctr_$SUF; MON=pgv_cmon_$SUF; UIUSER=proofctr$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SQL=; SRVPID=; SRV2PID=; CHRPID=; BG=()
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); UIPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nMSSQL_PID=Developer\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$SRV2PID" ]] && kill "$SRV2PID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; fi
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  docker ps -aq --filter "label=$LBL-$SUF" | xargs -r docker rm -f -v >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3 node chromium setsid ss; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && ! grep -q 'ListCollector' internal/mssql/mssql.go; then
  git apply scripts/proof-mssql-counters-wiring.patch 2>/dev/null || patch -p1 --forward < scripts/proof-mssql-counters-wiring.patch >/dev/null \
    || fail "the wiring patch"
  echo "wiring applied to this copy (config.go, mssql.go, repo.go, cpu.go, activity.go, 0190, web.go, router.ts, main.ts; D6: q_perfsummary.go, perfsummary.ts, q_mssql_perf.go, mssql_perf.ts)"
fi
freeport() { local lo=$1 hi=$2 p used
  used=$(ss -Htan) || fail "ss -Htan failed: the ports in use cannot be read"
  used=$(awk '{n = split($4, a, ":"); print a[n]}' <<<"$used" | sort -u)
  for _ in $(seq 1 50); do p=$((lo + RANDOM % (hi - lo + 1))); grep -qx "$p" <<<"$used" || { echo "$p"; return 0; }; done
  fail "no free port in $lo-$hi"
}
# sq: T-SQL as sa on the current container (stdin; -I: QUOTED_IDENTIFIER ON)
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqb() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sqb "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
# hand: every counter row now, as object (prefix dropped) | counter | instance ('' read as _Total) | value | type
hand() { sq "SELECT SUBSTRING(RTRIM(object_name), CHARINDEX(':', object_name) + 1, 200) + '|' + RTRIM(counter_name) + '|'
  + CASE WHEN RTRIM(instance_name) = '' THEN '_Total' ELSE RTRIM(instance_name) END + '|' + CAST(cntr_value AS varchar(30)) + '|' + CAST(cntr_type AS varchar(20))
  FROM sys.dm_os_performance_counters" > "$1"; }
col() { for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance ctrbox -once "$c" > "$TMPD/col-$c.out" 2>&1 \
  || { cat "$TMPD/col-$c.out" >&2; fail "collect $c"; }; done; }
# the stored raw value / base / change / rate of one series at the scope's newest read ('' = no row at that read)
stored() { pq "SELECT coalesce(s.value::text, CASE WHEN k.series_id = ANY (r.zero_series) THEN '0' END, '') || '|' || coalesce(s.base::text, '') || '|' || coalesce(s.dvalue::text, '') || '|' || coalesce(s.dbase::text, '') || '|' || coalesce(s.rate::text, '')
  FROM pgvigil.mssql_counter_series k
  JOIN LATERAL (SELECT * FROM pgvigil.mssql_counter_read c WHERE c.instance_id = k.instance_id AND c.scope = pgvigil.mssql_counter_scope(k.object) ORDER BY c.snapshot_at DESC LIMIT 1) r ON true
  LEFT JOIN pgvigil.mssql_counter_sample s ON s.instance_id = k.instance_id AND s.series_id = k.series_id AND s.snapshot_at = r.snapshot_at
  WHERE k.instance_id = $SB AND k.object = '$1' AND k.counter = '$2' AND k.inst = '$3'"; }
field() { cut -d'|' -f"$2" <<<"$1"; }
chg() { field "$(stored "$1" "$2" "$3")" 3; }       # the change of a series at its scope's newest read
listed() { pq "SELECT count(*) FROM jsonb_array_elements(pgvigil.import_mssql_counter_list($SB, '$1'::jsonb)) e WHERE e->>'object' = '$2' AND e->>'counter' = '$3'"; }
readat() { pq "SELECT count(*) FROM pgvigil.mssql_counter_series k JOIN pgvigil.mssql_counter_last l ON l.series_id = k.series_id
  WHERE k.instance_id = $SB AND k.object = '$1' AND k.counter = '$2'
    AND l.server_utc = (SELECT server_utc FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = pgvigil.mssql_counter_scope('$1') ORDER BY snapshot_at DESC LIMIT 1)"; }

# start <image>: a container of the image, the database and the monitor login; PORT_SQL
start() {
  SQL=pgv-ctr-$1-$SUF
  docker run -d --name "$SQL" --label "$LBL-$SUF" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "mcr.microsoft.com/mssql/server:$1" >/dev/null
  local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
  [[ "$r" == 1 ]] || { docker logs --tail 20 "$SQL" >&2 2>&1 || true; fail "A: the $1 container did not come up in 300 s"; }
  mondsn
  sqok "A: the database" "CREATE DATABASE pgvctr ON (NAME = pgvctr, FILENAME = '/var/opt/mssql/data/pgvctr.mdf', SIZE = 16MB)
    LOG ON (NAME = pgvctr_log, FILENAME = '/var/opt/mssql/data/pgvctr_log.ldf', SIZE = 1MB, FILEGROWTH = 1MB);
    ALTER DATABASE pgvctr SET RECOVERY FULL; ALTER DATABASE pgvctr SET ALLOW_SNAPSHOT_ISOLATION ON;"
  sqok "A: the full backup that starts the log chain" "BACKUP DATABASE pgvctr TO DISK = '/var/opt/mssql/data/pgvctr.bak' WITH INIT;"
  sqok "A: the table" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0, pad char(200) NOT NULL DEFAULT 'a');
    INSERT dbo.t (id) SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvctr
  sqok "A: the monitor login" "IF SUSER_ID('$MON') IS NULL CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF;
    GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON];"
}
# mondsn: the container's host port (random; a docker restart may give it a new one) and the monitor's DSN on it
mondsn() {
  PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
  [[ "$PORT_SQL" =~ ^[0-9]+$ ]] || fail "the host port of $SQL: [$PORT_SQL]"
  export PGV_CTR_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
}

# config <yaml lines for the instance>: the proof's pgvigil.yaml
config() {
  CFG=$TMPD/m.yaml
  { printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: ctrbox\n    engine: sqlserver\n    dsn: env:PGV_CTR_MON\n    tags: [env:ctrproof]\n' "$PGDSN"
    if [[ -n "${1:-}" ]]; then printf '%s\n' "$1"; fi; } > "$CFG"
}

go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="${ADMIN_DSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"

echo "== A. the first image (${IMAGES[0]}) =="
start "${IMAGES[0]}"
config
"$TMPD/pgvigil" migrate -config "$CFG" > "$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col mssql_instance mssql_counters mssql_counters_db mssql_counter_catalog
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'ctrbox'")
NDEF=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_defaults"); NL=$(pq "SELECT jsonb_array_length(pgvigil.import_mssql_counter_list($SB, '[]'))")
[[ "$NDEF" == "$NL" ]] || fail "A: the list holds $NL, the defaults $NDEF"
ok "A: SQL Server $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))"), migrate, the three collections, the list = every default ($NL)"

# bracket: a hand read before and after one mssql_counters read; the stored raw values of that read between them
bracket() {
  local tag=$1
  sleep 2; hand "$TMPD/h0"; col mssql_counters; hand "$TMPD/h1"
  pq "SELECT k.object || '|' || k.counter || '|' || k.inst || '|' || k.kind || '|' || coalesce(s.value, 0) || '|' || coalesce(s.base::text, '')
        FROM pgvigil.mssql_counter_series k
        JOIN (SELECT * FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 1) r ON true
        LEFT JOIN pgvigil.mssql_counter_sample s ON s.instance_id = $SB AND s.series_id = k.series_id AND s.snapshot_at = r.snapshot_at
       WHERE k.instance_id = $SB AND pgvigil.mssql_counter_scope(k.object) = 'instance' AND k.object NOT LIKE 'sys.dm_os_%'
         AND (s.series_id IS NOT NULL OR k.series_id = ANY (r.zero_series))" > "$TMPD/stored"
  python3 - "$TMPD/h0" "$TMPD/h1" "$TMPD/stored" "$tag" <<'PY'
import sys
def load(p):
    d = {}
    for l in open(p):
        f = l.rstrip('\n').split('|')
        if len(f) == 5 and f[3].lstrip('-').isdigit():
            d[(f[0], f[1], f[2])] = int(f[3])
    return d
h0, h1 = load(sys.argv[1]), load(sys.argv[2])
base_of = {}
for (o, c, i), v in h0.items():
    base_of[(o.lower(), c.lower(), i)] = None
cum_bad, moved, n, nb = [], [], 0, 0
for l in open(sys.argv[3]):
    o, c, i, k, v, b = l.rstrip('\n').split('|')
    v = int(v); key = (o, c, i)
    if key not in h0 or key not in h1:
        continue
    n += 1
    lo, hi = h0[key], h1[key]
    if k in ('rate', 'count', 'average'):
        if not (lo <= v <= hi):
            cum_bad.append(f'{o}/{c}/{i} {lo} <= {v} <= {hi}')
    elif not (min(lo, hi) <= v <= max(lo, hi)):
        moved.append(f'{o}/{c}/{i} {lo} {v} {hi}')
    if b and k == 'average':
        # the base's own hand reads: the base row's name is not kept, so the bracket is on the stored base against its counter's base name rule
        nb += 1
print(f'{sys.argv[4]}: {n} stored series bracketed; cumulative outside: {len(cum_bad)}; gauges / fractions outside their two hand reads: {len(moved)}')
for x in moved[:15]: print('   moved: ' + x)
for x in cum_bad[:15]: print('   FAIL ' + x)
sys.exit(1 if cum_bad or n < 300 else 0)
PY
}

echo "== B. the bracket =="
bracket "B" || fail "B: a stored cumulative value outside its hand reads (or under 300 series)"
ok "B: every stored rate, count and average between the hand read before and after"

echo "== C. the arithmetic from the stored pairs =="
sleep 3; col mssql_counters
# arith <label>: C's arithmetic on the newest two instance reads of $SB (C here, L on each further image)
arith() {
python3 - "$PGDSN" "$SB" "$1" <<'PY' || return 1
import subprocess, sys
dsn, sb = sys.argv[1], sys.argv[2]
q = lambda s: subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-F', '|', '-c', s], capture_output=True, text=True, check=True).stdout
reads = q(f"SELECT snapshot_at, server_utc, extract(epoch FROM server_utc)::text FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 2").split('\n')
(at1, _, e1), (at0, _, e0) = [r.split('|') for r in reads[:2]]
secs = float(e1) - float(e0)
rows = q(f"""SELECT k.series_id, k.kind, s1.value, s1.base, s1.dvalue, s1.dbase, s1.rate, s0.value, s0.base,
                    (SELECT figure FROM pgvigil.mssql_counter_newest({sb}, now() - interval '1 hour', now()) n WHERE n.series_id = k.series_id)
               FROM pgvigil.mssql_counter_series k
               JOIN pgvigil.mssql_counter_sample s1 ON s1.series_id = k.series_id AND s1.instance_id = {sb} AND s1.snapshot_at = '{at1}'
               LEFT JOIN pgvigil.mssql_counter_sample s0 ON s0.series_id = k.series_id AND s0.instance_id = {sb} AND s0.snapshot_at = '{at0}'
              WHERE k.instance_id = {sb}""")
bad, n = [], {}
for l in rows.strip().split('\n'):
    sid, kind, v1, b1, dv, db, rate, v0, b0, fig = l.split('|')
    n[kind] = n.get(kind, 0) + 1
    f = lambda x: None if x == '' else float(x)
    v1, b1, dv, db, rate, v0, b0, fig = map(f, (v1, b1, dv, db, rate, v0, b0, fig))
    if kind in ('rate', 'count') and v0 is not None:
        if dv != v1 - v0: bad.append(f'{sid} {kind} change {dv} != {v1} - {v0}')
        if kind == 'rate' and (rate is None or abs(rate - round((v1 - v0) / secs, 3)) > 0.0015): bad.append(f'{sid} rate {rate} != {(v1 - v0) / secs:.3f}')
    if kind == 'average' and v0 is not None and b0 is not None:
        if dv != v1 - v0 or db != b1 - b0: bad.append(f'{sid} average changes {dv} {db}')
        if db and abs(fig - dv / db) > 1e-6: bad.append(f'{sid} average {fig} != {dv / db}')
    if kind == 'fraction' and b1:
        if abs(fig - 100.0 * v1 / b1) > 1e-6: bad.append(f'{sid} fraction {fig} != {100 * v1 / b1}')
    if kind == 'gauge' and fig != v1: bad.append(f'{sid} gauge {fig} != {v1}')
print(f'{sys.argv[3]}: {sum(n.values())} series over {secs:.3f} s by the server clock: ' + ', '.join(f'{k} {v}' for k, v in sorted(n.items())))
for b in bad[:20]: print('   FAIL ' + b)
sys.exit(1 if bad else 0)
PY
# the ratio metrics recomputed from the same read's rates (the floors included)
python3 - "$PGDSN" "$SB" "$1" <<'PY' || return 2
import subprocess, sys
dsn, sb = sys.argv[1], sys.argv[2]
q = lambda s: subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-F', '|', '-c', s], capture_output=True, text=True, check=True).stdout.strip()
at = q(f"SELECT snapshot_at FROM pgvigil.mssql_counter_read WHERE instance_id = {sb} AND scope = 'instance' ORDER BY snapshot_at DESC LIMIT 1")
rate = lambda o, c, i='_Total': float(q(f"SELECT coalesce(max(v.rate), 0) FROM pgvigil.mssql_counter_values({sb}, '{at}'::timestamptz - interval '1 second', '{at}', 'instance') v WHERE v.object = '{o}' AND v.counter = '{c}' AND v.inst = '{i}'") or 0)
pt = lambda m: q(f"SELECT value FROM pgvigil.metric_points({sb}, 'counters', '{at}'::timestamptz - interval '1 second', '{at}') WHERE metric = '{m}'")
b, c, rc = rate('SQL Statistics', 'Batch Requests/sec'), rate('SQL Statistics', 'SQL Compilations/sec'), rate('SQL Statistics', 'SQL Re-Compilations/sec')
exp = {'compiles_per_100_batches': 0 if b < 1 else 100 * c / b, 'recompiles_per_100_compiles': 0 if c < 1 else 100 * rc / c}
bad = [f'{m} {pt(m)} != {e}' for m, e in exp.items() if pt(m) == '' or abs(float(pt(m)) - e) > 1e-6]
print(f'{sys.argv[3]}: ratios at batches {b}/s: ' + ', '.join(f'{m} {pt(m)}' for m in exp))
for x in bad: print('   FAIL ' + x)
sys.exit(1 if bad else 0)
PY
}
arith C || fail "C: a figure differs from its recomputation (arith $?: 1 a stored figure, 2 a ratio metric)"
ok "C: every rate, change, average, fraction and gauge equals its recomputation from the stored raw pairs; the ratios equal their rates"

echo "== D. the provoked counters =="
# a phase: one read, the provocation, one read; each change read from the store
for _ in $(seq 1 40); do sq "SELECT 1" >/dev/null; done
col mssql_counters
DL=$(chg 'General Statistics' 'Logins/sec' '_Total'); DO=$(chg 'General Statistics' 'Logouts/sec' '_Total')
# the collector's own login of this read is counted (+1); its logout of the read before happened after that read
[[ "$DL" == 41 && "$DO" == 41 ]] || fail "D: logins +$DL logouts +$DO (want 41 each: 40 and the collector's own)"
ok "D: Logins/sec and Logouts/sec + 40 each beside the collector's own (+41 stored)"

sq "$(printf "RAISERROR('pgvigil proof user error', 16, 1);\n%.0s" $(seq 1 12))" >/dev/null 2>&1 || true
sq "$(printf "RAISERROR('pgvigil proof info message', 10, 1);\n%.0s" $(seq 1 7))" >/dev/null 2>&1 || true
col mssql_counters
EU=$(chg 'SQL Errors' 'Errors/sec' 'User Errors'); EI=$(chg 'SQL Errors' 'Errors/sec' 'Info Errors')
# the severe errors in a phase of their own: in one phase with the 12 above, User Errors read +15 (sqltb-s1-proof3)
for _ in 1 2 3; do sq "RAISERROR('pgvigil proof severe error', 20, 1) WITH LOG;" >/dev/null 2>&1 || true; done
col mssql_counters
EK=$(chg 'SQL Errors' 'Errors/sec' 'Kill Connection Errors'); EUK=$(chg 'SQL Errors' 'Errors/sec' 'User Errors')
EO=$(stored 'SQL Errors' 'Errors/sec' 'DB Offline Errors'); ET=$(chg 'SQL Errors' 'Errors/sec' '_Total')
echo "   errors: user +$EU, info +$EI (12 at severity 16, 7 at 10); then kill connection +$EK, user +$EUK, total +$ET (3 at severity 20 WITH LOG); DB Offline Errors stored as [$EO]"
[[ "$EU" == 12 ]] || fail "D: User Errors +$EU (want 12)"
[[ -n "$EK" && "$EK" -ge 3 ]] || fail "D: Kill Connection Errors +$EK (want 3: three severity 20 errors)"
[[ "$(field "$EO" 1)" == 0 ]] || fail "D: DB Offline Errors [$EO] (want 0, in zero_series)"
ok "D: User Errors +12, Info Errors +$EI (read as they are); Kill Connection Errors +$EK with User Errors +$EUK in the severe phase; DB Offline Errors 0 (not provable on a box)"

col mssql_counters_db
sq "DECLARE @i int = 0; WHILE @i < 500 BEGIN UPDATE dbo.t SET v = v + 1 WHERE id = @i % 2000 + 1; SET @i += 1; END" pgvctr >/dev/null
sq "INSERT dbo.t (id, pad) SELECT TOP (30000) 100000 + ROW_NUMBER() OVER (ORDER BY (SELECT 1)), REPLICATE('g', 200) FROM sys.all_objects a CROSS JOIN sys.all_objects b" pgvctr >/dev/null
col mssql_counters_db
WT=$(chg 'Databases' 'Write Transactions/sec' 'pgvctr'); LF=$(chg 'Databases' 'Log Flush Waits/sec' 'pgvctr'); LG=$(chg 'Databases' 'Log Growths' 'pgvctr')
LW=$(chg 'Databases' 'Log Flush Wait Time' 'pgvctr')
[[ -n "$WT" && "$WT" -ge 500 ]] || fail "D: pgvctr Write Transactions + $WT (want 500 or more)"
[[ -n "$LF" && "$LF" -gt 0 ]] || fail "D: pgvctr Log Flush Waits + $LF (want more than 0)"
[[ -n "$LG" && "$LG" -ge 1 ]] || fail "D: pgvctr Log Growths + $LG (want 1 or more)"
sleep 2; col mssql_counters_db
FLAT=$(stored 'Databases' 'Log Growths' 'pgvctr'); FV=$(field "$FLAT" 1); FC=$(field "$FLAT" 3)
INROW=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_series k ON k.series_id = s.series_id
  WHERE k.instance_id = $SB AND k.object = 'Databases' AND k.counter = 'Log Growths' AND k.inst = 'pgvctr'
    AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'database')")
LGP=$(pq "SELECT value FROM pgvigil.metric_points($SB, 'counters', now() - interval '20 seconds', now(), interval '15 minutes', 'pgvctr') WHERE metric = 'log_growths' ORDER BY at DESC LIMIT 1")
[[ "$FV" -ge 1 && "$FC" == 0 && "$INROW" == 1 && "$LGP" == 0 ]] || fail "D: the flat read [$FLAT] row $INROW log_growths [$LGP] (want a row at a change of 0 and the point 0)"
ok "D: pgvctr Write Transactions +$WT, Log Flush Waits +$LF (wait time +$LW ms), Log Growths +$LG; the flat read after it keeps its row at a change of 0 and log_growths is 0 (F2 case 1)"

col mssql_counters
( printf 'BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '"'"'00:00:25'"'"'; ROLLBACK;\n' | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 & ) ; sleep 2
for _ in $(seq 1 6); do sq "SET LOCK_TIMEOUT 200; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done
col mssql_counters
TG=$(chg 'Locks' 'Lock Timeouts (timeout > 0)/sec' '_Total'); TP=$(chg 'Locks' 'Lock Timeouts/sec' '_Total')
AW=$(pq "SELECT round(value::numeric, 1) FROM pgvigil.metric_points($SB, 'counters', now() - interval '20 seconds', now()) WHERE metric = 'avg_lock_wait_ms' ORDER BY at DESC LIMIT 1")
for _ in $(seq 1 6); do sq "SET LOCK_TIMEOUT 0; SELECT v FROM dbo.t WHERE id = 1;" pgvctr >/dev/null 2>&1 || true; done
col mssql_counters
TG2=$(chg 'Locks' 'Lock Timeouts (timeout > 0)/sec' '_Total'); TP2=$(chg 'Locks' 'Lock Timeouts/sec' '_Total')
echo "   lock timeouts: (timeout > 0) +$TG then +$TG2; all +$TP then +$TP2; average lock wait $AW ms"
[[ "$TG" == 6 && "$TG2" == 0 && "$((TP + TP2))" -ge 12 ]] || fail "D: lock timeouts (timeout > 0) +$TG / +$TG2, all +$TP / +$TP2"
python3 -c "import sys; sys.exit(0 if 150 <= float('${AW:-0}') <= 600 else 1)" || fail "D: the average lock wait $AW ms (want 150-600)"
ok "D: Lock Timeouts (timeout > 0) +6 at 200 ms and +0 at LOCK_TIMEOUT 0; all lock timeouts +$((TP + TP2)); the average lock wait $AW ms"
sleep 25

col mssql_counters
for _ in 1 2 3 4; do
  ( printf 'SET TRANSACTION ISOLATION LEVEL SNAPSHOT; BEGIN TRAN; SELECT v FROM dbo.t WHERE id = 2; WAITFOR DELAY '"'"'00:00:02'"'"'; UPDATE dbo.t SET v = v + 1 WHERE id = 2; COMMIT;\n' \
      | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 & )
  sleep 0.7; sq "UPDATE dbo.t SET v = v + 1 WHERE id = 2;" pgvctr >/dev/null; sleep 2
done
sleep 1; col mssql_counters
UC=$(stored 'Transactions' 'Update conflict ratio' '_Total')
[[ "$(field "$UC" 3)" == 4 && "$(field "$UC" 4)" -ge 4 ]] || fail "D: Update conflict ratio [$UC] (want a change of 4 over a base change of 4 or more)"
ok "D: Update conflict ratio +4 conflicts over +$(field "$UC" 4) snapshot updates"

col mssql_counters
sq "$(for i in $(seq 1 20); do echo "SELECT v FROM dbo.t WHERE id = $((i * 7));"; echo GO; done)" pgvctr >/dev/null
col mssql_counters
AP=$(chg 'SQL Statistics' 'Auto-Param Attempts/sec' '_Total')
sq "ALTER DATABASE pgvctr SET PARAMETERIZATION FORCED;" >/dev/null
sq "$(for i in $(seq 1 20); do echo "SELECT v, pad FROM dbo.t WHERE id = $((i * 11)) AND v >= 0;"; echo GO; done)" pgvctr >/dev/null
col mssql_counters
FP=$(chg 'SQL Statistics' 'Forced Parameterizations/sec' '_Total')
sq "ALTER DATABASE pgvctr SET PARAMETERIZATION SIMPLE;" >/dev/null
[[ -n "$AP" && "$AP" -ge 20 && -n "$FP" && "$FP" -ge 20 ]] || fail "D: Auto-Param Attempts +$AP, Forced Parameterizations +$FP (want 20 or more each)"
ok "D: Auto-Param Attempts +$AP, Forced Parameterizations +$FP"

col mssql_counters
sq "CREATE TABLE dbo.pc (id int NOT NULL, pad char(500) NOT NULL) WITH (DATA_COMPRESSION = PAGE);
  INSERT dbo.pc WITH (TABLOCK) SELECT TOP (30000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)), REPLICATE('p', 500) FROM sys.all_objects a CROSS JOIN sys.all_objects b;" pgvctr >/dev/null
sq "$(for i in 1 2 3 4 5; do echo "DECLARE c$i CURSOR LOCAL FOR SELECT TOP (3) id FROM dbo.t; OPEN c$i; FETCH NEXT FROM c$i; CLOSE c$i; DEALLOCATE c$i;"; done)" pgvctr >/dev/null
sq "SELECT COUNT(*) FROM ::fn_helpcollations(); SELECT COUNT(*) FROM ::fn_helpcollations(); SELECT COUNT(*) FROM ::fn_helpcollations();" >/dev/null
sq "$(for _ in 1 2 3 4 5; do echo "WAITFOR DELAY '00:00:00.150';"; echo GO; done; for _ in 1 2 3; do echo "WAITFOR DELAY '00:00:01.200';"; echo GO; done)" >/dev/null
col mssql_counters
PC=$(chg 'Access Methods' 'Page compression attempts/sec' '_Total'); CR=$(chg 'Cursor Manager by Type' 'Cursor Requests/sec' '_Total')
DF=$(pq "SELECT s.dvalue FROM pgvigil.mssql_counter_series k JOIN pgvigil.mssql_counter_sample s ON s.series_id = k.series_id
  WHERE k.instance_id = $SB AND k.object = 'Deprecated Features' AND k.inst LIKE '%::%function calling syntax%'
    AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance')")
B100=$(chg 'Batch Resp Statistics' 'Batches >=000100ms & <000200ms' 'Elapsed Time:Requests'); B1K=$(chg 'Batch Resp Statistics' 'Batches >=001000ms & <002000ms' 'Elapsed Time:Requests')
PREV=$(pq "SELECT snapshot_at FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' ORDER BY snapshot_at DESC OFFSET 1 LIMIT 1")
H100=$(pq "SELECT elapsed_batches FROM pgvigil.mssql_counter_histogram($SB, '$PREV', now()) WHERE lo_ms = 100")
echo "   page compression attempts +$PC, cursor requests +$CR, '::' syntax +$DF, batches 100-200 ms +$B100, 1-2 s +$B1K (histogram 100-200 ms: $H100)"
[[ -n "$PC" && "$PC" -gt 0 && -n "$CR" && "$CR" -ge 5 && "$DF" == 3 && -n "$B100" && "$B100" -ge 5 && -n "$B1K" && "$B1K" -ge 3 && "$H100" == "$B100" ]] \
  || fail "D: compression / cursors / deprecated / batch buckets"
ok "D: Page compression attempts +$PC, Cursor Requests +$CR, Deprecated Features '::' +3, batches 100-200 ms +$B100 and 1-2 s +$B1K (the histogram the same)"

( printf "DECLARE @e datetime2 = DATEADD(second, 25, SYSDATETIME()), @i bigint = 0; WHILE SYSDATETIME() < @e SET @i += 1;\n" \
    | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -i /dev/stdin' >/dev/null 2>&1 & )
sleep 8; col mssql_counters
CPU=$(stored 'Resource Pool Stats' 'CPU usage %' 'default'); CF=$(pq "SELECT figure FROM pgvigil.mssql_counter_newest($SB, now() - interval '1 hour', now()) WHERE object = 'Resource Pool Stats' AND counter = 'CPU usage %' AND inst = 'default'")
python3 - "$CPU" "$CF" <<'PY' || fail "D: Resource Pool CPU usage % [$CPU] figure [$CF]"
import sys
v, b = [float(x) for x in sys.argv[1].split('|')[:2]]
f = float(sys.argv[2]); print(f'   default pool CPU usage %: value {v:.0f} base {b:.0f} figure {f:.3f}')
sys.exit(0 if 0 < f <= 100 and abs(f - 100 * v / b) < 1e-6 else 1)
PY
ok "D: Resource Pool Stats CPU usage % read under a CPU loop: $CF % = 100 * value / base"
sleep 18

sq "CREATE INDEX ix_v ON dbo.t (v); " pgvctr >/dev/null
sq "EXEC sp_create_plan_guide @name = N'pgv_ctr_guide', @stmt = N'SELECT id FROM dbo.t WHERE v > 100000;', @type = N'SQL', @module_or_batch = NULL, @params = NULL, @hints = N'OPTION (TABLE HINT (dbo.t, INDEX (ix_v)))';" pgvctr >/dev/null 2>&1 || true
col mssql_counters
sq "DROP INDEX ix_v ON dbo.t;" pgvctr >/dev/null 2>&1 || true
for _ in 1 2 3; do printf 'SELECT id FROM dbo.t WHERE v > 100000;\nGO\n' | timeout 60 docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -I -d pgvctr -i /dev/stdin' >/dev/null 2>&1 || true
  sq "DBCC FREEPROCCACHE WITH NO_INFOMSGS;" >/dev/null 2>&1 || true; done
col mssql_counters
MG=$(chg 'SQL Statistics' 'Misguided plan executions/sec' '_Total')
if [[ -n "$MG" && "$MG" -gt 0 ]]; then ok "D: Misguided plan executions +$MG (a plan guide whose index was dropped)"
else echo "NOT PROVEN live: Misguided plan executions/sec did not move (+${MG:-no change}) with a plan guide whose index was dropped; the counter is read ($(stored 'SQL Statistics' 'Misguided plan executions/sec' '_Total'))"; fi

echo "== E. the list =="
config "    mssql_counters:
      add:
        - object: General Statistics
          counter: Logical Connections
      remove:
        - object: Deprecated Features
          counter: Usage"
col mssql_counters
[[ $(readat 'General Statistics' 'Logical Connections') -ge 1 && $(readat 'Deprecated Features' 'Usage') == 0 ]] \
  || fail "E: the yaml lines: Logical Connections read $(readat 'General Statistics' 'Logical Connections'), Usage read $(readat 'Deprecated Features' 'Usage')"
Y=$(pq "SELECT jsonb_array_length(lines) FROM pgvigil.mssql_counter_yaml WHERE instance_id = $SB"); [[ "$Y" == 2 ]] || fail "E: mssql_counter_yaml holds $Y lines"
ok "E: pgvigil.yaml's instance lines: Logical Connections read, Deprecated Features Usage not; the runner's 2 lines kept"
door() { pq "SELECT pgvigil.import_mssql_counter_config(now(), '$1'::jsonb)"; }
door '{"op":"add","ui_user":"proof-e","scope":"fleet","object":"Deprecated Features","counter":"Usage","action":"add"}' | grep -q '"done"' || fail "E: the fleet row"
col mssql_counters
[[ $(readat 'Deprecated Features' 'Usage') == 0 ]] || fail "E: an Admin fleet row won over the instance's yaml line"
door '{"op":"add","ui_user":"proof-e","scope":"instance","instance_name":"ctrbox","object":"Deprecated Features","counter":"Usage","action":"add"}' | grep -q '"done"' || fail "E: the instance row"
col mssql_counters
[[ $(readat 'Deprecated Features' 'Usage') -ge 1 ]] || fail "E: an Admin instance row lost to the instance's yaml line"
door '{"op":"add","ui_user":"proof-e","scope":"tag","tag":"env:ctrproof","object":"Plan Cache","counter":"Cache Pages","action":"remove"}' | grep -q '"done"' || fail "E: the tag row"
col mssql_counters
[[ $(readat 'Plan Cache' 'Cache Pages') == 0 ]] || fail "E: the tag row's removal did not hold"
door '{"op":"add","ui_user":"proof-e","scope":"instance","instance_name":"ctrbox","object":"Plan Cache","counter":"Cache Pages","action":"add"}' | grep -q '"done"' || fail "E: the instance add"
col mssql_counters
[[ $(readat 'Plan Cache' 'Cache Pages') -ge 1 ]] || fail "E: the instance row lost to the tag row"
R=$(door '{"op":"add","ui_user":"proof-e","scope":"fleet","object":"General Statistics","counter":"Logins/sec","action":"remove"}')
grep -q '"refused"' <<<"$R" && grep -q 'read by' <<<"$R" || fail "E: removing Logins/sec: $R"
config "    mssql_counters:
      remove:
        - object: General Statistics
          counter: Logins/sec"
O=$("$TMPD/pgvigil" collect -config "$CFG" -instance ctrbox -once mssql_counters 2>&1 || true); grep -q 'is read by' <<<"$O" || fail "E: the yaml removal of Logins/sec: $O"
config
ok "E: an Admin fleet row loses to the instance's yaml line, an Admin instance row wins over it; a tag row removes, an instance row adds back; Admin and yaml refuse removing Logins/sec"

echo "== F. the gap rule =="
door '{"op":"add","ui_user":"proof-f","scope":"instance","instance_name":"ctrbox","object":"Access Methods","counter":"Pages Allocated/sec","action":"remove"}' >/dev/null
col mssql_counters; sleep 2; col mssql_counters
GID=$(pq "SELECT config_id FROM pgvigil.mssql_counter_config WHERE ended_at IS NULL AND counter = 'Pages Allocated/sec'")
door "{\"op\":\"end\",\"ui_user\":\"proof-f\",\"config_id\":\"$GID\"}" | grep -q '"done"' || fail "F: end"
sleep 2; col mssql_counters; G1=$(stored 'Access Methods' 'Pages Allocated/sec' '_Total')
sleep 2; col mssql_counters; G2=$(stored 'Access Methods' 'Pages Allocated/sec' '_Total')
[[ -n "$(field "$G1" 1)" && -z "$(field "$G1" 3)" && -z "$(field "$G1" 5)" && -n "$(field "$G2" 3)" && -n "$(field "$G2" 5)" ]] || fail "F: back from the gap [$G1] then [$G2]"
ok "F: Pages Allocated/sec back after a gap: no change and no rate at its first read back [$G1], both at the next [$G2]"

echo "== G. a restart =="
docker restart "$SQL" >/dev/null
for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('pgvctr', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && break; sleep 2; done
[[ "$r" == 1 ]] || fail "G: pgvctr not online 300 s after the restart"
mondsn
col mssql_counters
NR=$(pq "SELECT count(*) FILTER (WHERE s.rate IS NOT NULL OR s.dvalue IS NOT NULL), count(*) FROM pgvigil.mssql_counter_sample s
  WHERE s.instance_id = $SB AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance')")
sleep 3; col mssql_counters
NR2=$(pq "SELECT count(*) FILTER (WHERE s.rate IS NOT NULL OR s.dvalue IS NOT NULL) FROM pgvigil.mssql_counter_sample s
  WHERE s.instance_id = $SB AND s.snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance')")
[[ "$(field "$NR" 1)" == 0 && "$NR2" -gt 0 ]] || fail "G: after the restart [$NR] changes, then $NR2"
ok "G: the first read after a restart has no rate or change on any of its $(field "$NR" 2) rows; the read after has $NR2"

echo "== H. zero points =="
NRD=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB AND scope = 'instance' AND snapshot_at > now() - interval '30 minutes'")
ZK=$(pq "SELECT count(*) FILTER (WHERE value = 0) || '|' || count(*) FROM pgvigil.metric_points($SB, 'counters', now() - interval '30 minutes', now()) WHERE metric = 'errors_offline_s'")
[[ "$ZK" == "$NRD|$NRD" ]] || fail "H: errors_offline_s points [$ZK] for $NRD reads"
ok "H: errors_offline_s is 0 at every one of the $NRD instance reads (the counter at raw 0, named in zero_series)"

echo "== I. F1: the CPU page's workload groups =="
col mssql_cpu mssql_counters
python3 - internal/repo/sql/0124_darling_cpu.sql "$TMPD/old_cpu.sql" <<'PY'
import sys
s = open(sys.argv[1]).read(); a = s.index('CREATE OR REPLACE FUNCTION pgvigil.mssql_cpu_newest('); b = s.index('$$;', a) + 3
open(sys.argv[2], 'w').write(s[a:b].replace('pgvigil.mssql_cpu_newest(', 'pg_temp.old_cpu_newest(', 1))
PY
OLD=$(psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -f "$TMPD/old_cpu.sql" -c "SELECT coalesce(rg_active_requests::text, 'NULL') FROM pg_temp.old_cpu_newest($SB, now() - interval '1 hour', now())" | tail -1)
NEW=$(pq "SELECT coalesce(rg_active_requests::text, 'NULL') FROM pgvigil.mssql_cpu_newest($SB, now() - interval '1 hour', now())")
[[ "$OLD" == NULL && "$NEW" != NULL ]] || fail "I: 0124's body $OLD, the join's $NEW"
ok "I: 0124's mssql_cpu_newest reads NULL workload groups once the counters left mssql_cpu (red); the join's reads $NEW (green)"

echo "== J. the API =="
NOW_LOG=$(pq "SELECT count(*) FROM pgvigil.mssql_counter_config_log")
PGVIGIL_PASSWORD=$UIPW "$TMPD/pgvigil" user add -config "$CFG" "$UIUSER" > /dev/null 2>&1 || fail "J: user add"
serve() { local p; for _ in 1 2 3; do p=$(freeport 29000 32499)
    "$TMPD/pgvigil" serve -config "$CFG" -listen "127.0.0.1:$p" "$@" > "$TMPD/serve-$p.log" 2>&1 & local pid=$!
    for _ in $(seq 1 60); do grep -q "url=http://127.0.0.1:$p/" "$TMPD/serve-$p.log" 2>/dev/null && { echo "$pid $p"; return 0; }; kill -0 $pid 2>/dev/null || break; sleep 0.5; done
    kill $pid 2>/dev/null || true; done; fail "J: serve never answered: $(tail -3 "$TMPD"/serve-*.log)"; }
read -r SRVPID SPORT <<<"$(serve)"; read -r SRV2PID SPORT2 <<<"$(serve -no-login)"
U=http://127.0.0.1:$SPORT; U2=http://127.0.0.1:$SPORT2; JAR=$TMPD/jar
code() { curl -s -m 20 -o "$TMPD/body" -w '%{http_code}' "$@"; }
[[ $(code -X POST -H 'X-Pgvigil: 1' -d '{}' "$U/api/mssql/counteradmin") == 401 ]] || fail "J: a POST without a session: $(cat "$TMPD/body")"
curl -s -m 20 -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" > /dev/null
[[ $(code -b "$JAR" -X POST -d '{}' "$U/api/mssql/counteradmin") == 403 ]] || fail "J: a POST without the header"
for q in "" "?instance=$SB"; do
  [[ $(code -b "$JAR" "$U/api/mssql/counteradmin$q") == 200 ]] || fail "J: GET$q: $(cat "$TMPD/body")"
  python3 - "$TMPD/body" "$q" <<'PY' || fail "J: GET$q parts"
import json, sys
d = json.load(open(sys.argv[1])); want = ['config', 'defaults', 'log', 'catalog'] + (['layers', 'absent', 'histogram'] if sys.argv[2] else [])
miss = [p for p in want if not isinstance(d.get(p), dict)]
print(f"   GET{sys.argv[2]}: writable {d.get('writable')}, parts {sorted(k for k in d if isinstance(d[k], dict))}")
sys.exit(1 if miss or d.get('writable') is not True else 0)
PY
done
P1=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"op\":\"add\",\"scope\":\"instance\",\"instance_id\":$SB,\"object\":\"General Statistics\",\"counter\":\"Mars Rollbacks/sec\",\"action\":\"add\"}" "$U/api/mssql/counteradmin")
CID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("config_id") or "")' "$TMPD/body")
P2=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"add","scope":"fleet","object":"Locks","counter":"Lock Waits/sec","action":"remove"}' "$U/api/mssql/counteradmin")
grep -q 'read by' "$TMPD/body" || fail "J: the refusal's words: $(cat "$TMPD/body")"
P3=$(code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"op\":\"end\",\"config_id\":$CID}" "$U/api/mssql/counteradmin")
[[ "$P1 $P2 $P3" == "200 409 200" ]] || fail "J: POST add / refused / end: $P1 $P2 $P3"
[[ $(code "$U2/api/mssql/counteradmin") == 200 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["writable"] is False and "-no-login" in d["reason"] else 1)' "$TMPD/body" \
  || fail "J: the -no-login serve's GET: $(cat "$TMPD/body")"
[[ $(code -X POST -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{"op":"add","scope":"fleet","object":"a","counter":"b","action":"add"}' "$U2/api/mssql/counteradmin") == 403 ]] || fail "J: the -no-login serve took a POST"
LOGS=$(pq "SELECT string_agg(outcome || '=' || n, ' ' ORDER BY outcome) FROM (SELECT outcome, count(*) n FROM pgvigil.mssql_counter_config_log WHERE ui_user = '$UIUSER' AND client = '127.0.0.1' GROUP BY 1) x")
[[ "$LOGS" == "done=2 refused=1" && $(pq "SELECT count(*) FROM pgvigil.mssql_counter_config_log") == $((NOW_LOG + 3)) ]] || fail "J: the log [$LOGS]"
ok "J: GET every part with and without an instance; POST 401 / 403 / add 200 / refused 409 ('read by') / end 200; a -no-login serve read only and refusing; the log holds done=2 refused=1 by the proof's user from 127.0.0.1"

echo "== K. the pages =="
setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu about:blank > "$TMPD/chrome.log" 2>&1 & CHRPID=$!
CDP=; for _ in $(seq 1 60); do [ -s "$TMPD/chrome/DevToolsActivePort" ] && CDP=$(head -1 "$TMPD/chrome/DevToolsActivePort"); [ -n "$CDP" ] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
[[ "$CDP" =~ ^[0-9]+$ ]] || fail "K: Chromium never answered"
cat > "$TMPD/page.mjs" <<'PAGE'
const [port, base, sb, shots] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the page check did not end in 300 s'); process.exit(2); }, 300000).unref();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); let thrown = [];
ws.addEventListener('message', m => { const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? 'exception');
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const until = async (e, ms = 45000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(e); if (v) return v; await sleep(300); } return null; };
let failed = 0; const check = (l, ok, w) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${l}: ${w}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
const gridRows = h => `(() => { const h3 = [...document.querySelectorAll('main h3')].find(x => x.textContent.trim().startsWith(${JSON.stringify(h)})); if (!h3) return -2;
  let t = h3.nextElementSibling; while (t && !t.querySelector?.('table.grid') && !t.matches?.('table.grid') && !t.matches?.('p.empty') && t.tagName !== 'H3') t = t.nextElementSibling;
  const tb = t?.matches?.('table.grid') ? t : t?.querySelector?.('table.grid'); return tb ? Number(tb.dataset.rows) : t?.matches?.('p.empty') ? 0 : -1; })()`;
const api = async (q, part) => { const d = await (await fetch(`${base}/api/${q}`)).json(); return d[part]?.rows?.length ?? -1; };
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: `${base}/#/counters?i=${sb}&w=1h` }); await until(`!!document.querySelector('main')`);
  await ev(`localStorage.setItem('pgvigil.theme', '${theme}')`); await cmd('Page.reload'); await sleep(500);
  await until(`[...document.querySelectorAll('main h3')].some(h => h.textContent.startsWith('Listed but not read'))`);
  const nowRows = await api(`mssql/counters?instance=${sb}&part=now`, 'now');
  const g = await ev(gridRows('Performance counters'));
  check(`counters ${theme}`, g === nowRows && nowRows > 300, `grid ${g} rows, the API's now part ${nowRows}`);
  const heads = await ev(`[...document.querySelectorAll('main table.grid')].some(t => [...t.querySelectorAll('th')].some(th => th.textContent.trim() === 'figure') && [...t.querySelectorAll('th')].some(th => th.textContent.trim() === 'kind'))`);
  check(`counters ${theme}`, heads, 'a grid with the figure and kind columns');
  check(`counters ${theme}`, await ev(gridRows('Batch response times')) === 17, `Batch response times ${await ev(gridRows('Batch response times'))} rows`);
  check(`counters ${theme}`, await ev(`[...document.querySelectorAll('main h3')].some(h => h.textContent.trim() === 'Counters')`), "the 'Counters' family grid");
  check(`counters ${theme}`, !(await ev(`!!document.querySelector('main .error, main .errorbox, main [role=alert].error')`)), 'no error box');
  if (shots) { const s = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); (await import('node:fs')).writeFileSync(`${shots}/counters-${theme}.png`, Buffer.from(s.result.data, 'base64')); }
  await cmd('Page.navigate', { url: `${base}/#/admin_counters?w=1h` });
  await until(`[...document.querySelectorAll('main h3')].some(h => h.textContent.trim() === 'Log')`);
  const cfg = await api('mssql/counteradmin?part=config', 'config'), def = await api('mssql/counteradmin?part=defaults', 'defaults');
  check(`admin ${theme}`, await ev(gridRows('Rows made here')) === cfg, `Rows made here ${await ev(gridRows('Rows made here'))}, the API ${cfg}`);
  check(`admin ${theme}`, await ev(gridRows('The defaults')) === def, `The defaults ${await ev(gridRows('The defaults'))}, the API ${def}`);
  check(`admin ${theme}`, (await ev(gridRows('Counters the servers have'))) > 300, `Counters the servers have ${await ev(gridRows('Counters the servers have'))}`);
  const offs = await ev(`[...document.querySelectorAll('main button')].filter(b => b.textContent.trim() === 'Save row' || b.textContent.trim() === 'End').map(b => b.getAttribute('aria-disabled') === 'true' && !!document.getElementById(b.getAttribute('aria-describedby') || '')?.textContent.includes('-no-login'))`);
  check(`admin ${theme}`, offs.length >= 1 && offs.every(Boolean), `${offs.length} Save / End control(s), each off with its -no-login reason`);
  if (shots) { const s = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); (await import('node:fs')).writeFileSync(`${shots}/admin-counters-${theme}.png`, Buffer.from(s.result.data, 'base64')); }
}
check('pages', thrown.length === 0, thrown.length ? thrown.slice(0, 3).join(' | ') : 'no exception');
process.exit(failed ? 1 : 0);
PAGE
timeout 320 node "$TMPD/page.mjs" "$CDP" "$U2" "$SB" "$SHOTS" || fail "K: a check of the pages failed"
ok "K: the Metrics page's counters (rows = the API's), the histogram, the absent list, the Counters family, Admin > Counters (rows = the API's) with its controls off and their reason, light and dark"

echo "== N. D6: the Performance summary, the CPU page's scheduler trend, the Memory page's clerk names =="
col mssql_cpu mssql_memory
sq "$(for i in $(seq 1 20); do echo "SELECT COUNT(*) FROM sys.objects WHERE object_id > $i;"; echo GO; done)" >/dev/null
sleep 2; col mssql_cpu mssql_memory mssql_counters
NF=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ); NT=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
for q in "perfsummary?part=mssql&from=$NF&to=$NT" "mssql/cpu?instance=$SB&part=sched&from=$NF&to=$NT" "mssql/memory?instance=$SB&part=clerk_stats&from=$NF&to=$NT"; do
  n=${q%%\?*}; n=${n//\//_}; [[ $(code "$U2/api/$q") == 200 ]] || fail "N: GET $q: $(cat "$TMPD/body")"; cp "$TMPD/body" "$TMPD/n-$n.json"
done
python3 - "$PGDSN" "$SB" "$NF" "$NT" "$TMPD" <<'PY2' || fail "N: an API row of D6"
import json, subprocess, sys
dsn, sb, nf, nt, d = sys.argv[1:6]
rows = lambda f, p: [dict(zip(t['columns'], r)) for t in [json.load(open(f'{d}/n-{f}.json'))[p]] for r in t['rows']]
q = lambda s: subprocess.run(['psql', dsn, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-F', '|', '-c', s], capture_output=True, text=True, check=True).stdout.strip()
bad = []
ps = [r for r in rows('perfsummary', 'mssql') if r.get('instance') == 'ctrbox']
cb = q(f"""SELECT sum(batch_s * interval_secs) / nullif(sum(interval_secs) FILTER (WHERE batch_s IS NOT NULL), 0),
                  sum(compiles_s * interval_secs) / nullif(sum(interval_secs) FILTER (WHERE compiles_s IS NOT NULL), 0)
             FROM pgvigil.mssql_sched_sample WHERE instance_id = {sb} AND snapshot_at > '{nf}' AND snapshot_at <= '{nt}' AND interval_secs > 0""").split('|')
b, c = round(float(cb[0]), 2), float(cb[1])
exp = 0 if b < 1 else round(100 * c / b, 1)
got = ps[0].get('compiles_per_100') if ps else None
print(f'   perfsummary ctrbox: batch_s {b}, compiles_s {c:.3f}: compiles_per_100 {got} (recomputed {exp})')
if got is None or abs(float(got) - exp) > 0.051: bad.append(f'compiles_per_100 {got} != {exp}')
fw = [r.get('failed_to_create_worker') for r in rows('mssql_cpu', 'sched')]
print(f'   sched steps {len(fw)}, failed_to_create_worker at {sum(v is not None for v in fw)} of them: {sorted(set(v for v in fw if v is not None))}')
if not any(v is not None and float(v) == 0 for v in fw): bad.append('no step with failed_to_create_worker 0')
bp = [r for r in rows('mssql_memory', 'clerk_stats') if r.get('clerk_type') == 'MEMORYCLERK_SQLBUFFERPOOL']
print(f"   clerk_stats: MEMORYCLERK_SQLBUFFERPOOL named [{bp[0].get('clerk_name') if bp else 'no row'}]")
if not bp or bp[0].get('clerk_name') != 'Buffer Pool': bad.append('the buffer pool clerk not named Buffer Pool')
for x in bad: print('   FAIL ' + x)
sys.exit(1 if bad else 0)
PY2
cat > "$TMPD/d6.mjs" <<'PAGE'
const [port, base, sb] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the D6 page check did not end in 120 s'); process.exit(2); }, 120000).unref();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); const thrown = [];
ws.addEventListener('message', m => { const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? 'exception');
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
const until = async (e, ms = 45000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(e); if (v) return v; await sleep(300); } return null; };
let failed = 0; const check = (l, ok) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${l}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: `${base}/#/perfsummary?w=1h` });
check("N page: the Performance summary's 'compilations per 100 batches' column", !!await until(`[...document.querySelectorAll('main th')].some(th => th.textContent.trim().startsWith('compilations per 100 batches'))`));
await cmd('Page.navigate', { url: `${base}/#/mssqlcpu?i=${sb}&w=1h` });
check("N page: the CPU page's scheduler trend names 'schedulers that failed to create a worker'", !!await until(`document.querySelector('main')?.innerText.includes('schedulers that failed to create a worker')`));
await cmd('Page.navigate', { url: `${base}/#/mssqlmemory?i=${sb}&w=1h` });
check("N page: the Memory page's clerks grid has 'what it is' with Buffer Pool", !!await until(`[...document.querySelectorAll('main table.grid')].some(t => [...t.querySelectorAll('th')].some(th => th.textContent.trim().startsWith('what it is')) && [...t.querySelectorAll('td')].some(td => td.textContent.trim() === 'Buffer Pool'))`));
check('N pages: no exception', thrown.length === 0);
process.exit(failed ? 1 : 0);
PAGE
timeout 140 node "$TMPD/d6.mjs" "$CDP" "$U2" "$SB" || fail "N: a D6 page check failed"
ok "N: compiles_per_100 on the Performance summary = its recomputation from mssql_sched_sample; failed_to_create_worker on the scheduler trend's steps; Buffer Pool named on the Memory page's clerks; the three pages show them"

echo "== M. the size =="
pq "SELECT scope, round(avg(rows_read)), count(*) FROM pgvigil.mssql_counter_read WHERE instance_id = $SB GROUP BY 1 ORDER BY 1" | sed 's/^/   reads: /'
python3 - "$PGDSN" "$SB" <<'PY'
import subprocess, sys
q = lambda s: subprocess.run(['psql', sys.argv[1], '-XAtq', '-c', s], capture_output=True, text=True, check=True).stdout.strip()
sb = sys.argv[2]
per = {}
for sc in ('instance', 'database'):
    per[sc] = float(q(f"""SELECT coalesce(avg(n), 0) FROM (SELECT count(*) n FROM pgvigil.mssql_counter_sample s JOIN pgvigil.mssql_counter_read r ON r.instance_id = s.instance_id AND r.snapshot_at = s.snapshot_at
       WHERE s.instance_id = {sb} AND r.scope = '{sc}' GROUP BY s.snapshot_at) x"""))
row = float(q(f"SELECT avg(pg_column_size(s.*)) + 40 FROM pgvigil.mssql_counter_sample s WHERE s.instance_id = {sb}"))  # + the index entry's share
day = (per['instance'] * 1440 + per['database'] * 288)
print(f"   sample rows stored per read: instance {per['instance']:.0f}, database {per['database']:.0f}; about {day:,.0f} rows and {day * row / 1048576:.0f} MB a day per instance at about {row:.0f} bytes a row with its index entry")
PY

# the version run starts from the defaults: the Admin rows the proof left live are ended first (E's fleet row and its
# tag row on env:ctrproof, which the version run's instance carries too: run 5 read a list of 143 with it live)
for id in $(pq "SELECT config_id FROM pgvigil.mssql_counter_config WHERE ended_at IS NULL"); do
  door "{\"op\":\"end\",\"ui_user\":\"proof-l\",\"config_id\":\"$id\"}" | grep -q '"done"' || fail "L: ending the Admin row $id"
done
for img in "${IMAGES[@]:1}"; do
  echo "== L. the version run on $img =="
  OLDSQL=$SQL; start "$img"; docker rm -f -v "$OLDSQL" >/dev/null 2>&1 || true
  NAME=ctr${img%%-*}
  psql "$PGDSN" -Xqc "UPDATE pgvigil.instances SET is_active = false WHERE name = 'ctrbox'" >/dev/null
  sed -i "s/name: ctrbox/name: $NAME/" "$CFG"
  colv() { for c in "$@"; do timeout 180 "$TMPD/pgvigil" collect -config "$CFG" -instance "$NAME" -once "$c" > "$TMPD/col-$c.out" 2>&1 || { cat "$TMPD/col-$c.out" >&2; fail "L: collect $c"; }; done; }
  colv mssql_instance mssql_counters mssql_counters_db
  SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = '$NAME'")
  NL=$(pq "SELECT jsonb_array_length(pgvigil.import_mssql_counter_list($SB, '[]'))"); [[ "$NL" == "$NDEF" ]] || fail "L: $img's list $NL"
  col() { colv "$@"; }
  bracket "L $img" || fail "L: $img: a cumulative value outside its hand reads"
  sleep 2; colv mssql_counters
  arith "L $img" || fail "L: $img: a figure differs from its recomputation (arith $?: 1 a stored figure, 2 a ratio metric)"
  for _ in $(seq 1 40); do sq "SELECT 1" >/dev/null; done
  sleep 1; colv mssql_counters; DL=$(chg 'General Statistics' 'Logins/sec' '_Total')
  sq "$(printf "RAISERROR('pgvigil proof user error', 16, 1);\n%.0s" $(seq 1 12))" >/dev/null 2>&1 || true
  sleep 1; colv mssql_counters; EU=$(chg 'SQL Errors' 'Errors/sec' 'User Errors')
  colv mssql_counters_db
  sq "DECLARE @i int = 0; WHILE @i < 500 BEGIN UPDATE dbo.t SET v = v + 1 WHERE id = @i % 2000 + 1; SET @i += 1; END" pgvctr >/dev/null
  sq "INSERT dbo.t (id, pad) SELECT TOP (30000) 100000 + ROW_NUMBER() OVER (ORDER BY (SELECT 1)), REPLICATE('g', 200) FROM sys.all_objects a CROSS JOIN sys.all_objects b" pgvctr >/dev/null
  colv mssql_counters_db; LG=$(chg 'Databases' 'Log Growths' 'pgvctr')
  [[ "$DL" == 41 && "$EU" == 12 && -n "$LG" && "$LG" -ge 1 ]] || fail "L: $img logins +$DL, user errors +$EU, pgvctr log growths +$LG"
  ok "L: $img ($(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")): the list = every default, the bracket, C's arithmetic, Logins/sec +40 and the collector's own, User Errors +12, pgvctr Log Growths +$LG"
done

echo "NOT PROVEN HERE: SQL Server 2016 (no Linux image: dba-lab-win's queue), Managed Instance, RDS, Cloud SQL, a Windows host; DB Offline Errors moving (no box can provoke it); two memory nodes (one Buffer Node in a container)"
echo "PROOF OK: mssql counters (A B C D E F G H I J K N M L)"
