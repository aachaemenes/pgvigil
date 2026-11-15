#!/usr/bin/env bash
# Proof of task 413 (B22): sessions and connections. One SQL Server container per run (MSSQL_IMAGE; the box job runs
# it once per version: 2017, 2019, 2022, 2025), a repository database of its own, pgvigil built from this tree.
# Needs: docker, go, psql, curl, python3, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it; every
#                   other connection string is ADMIN_DSN with user / password / dbname appended (never a fixed port)
#   MSSQL_IMAGE     the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_PARTS   the parts to run (default every part this file has)
#   PGVIGIL_SQL_MEM_MB  SQL Server's own memory cap in the 6 GB container (MSSQL_MEMORY_LIMIT_MB; default 4096; 0 = none):
#                   2017 and 2019 size themselves on the host's memory, not the container's (box diag 413-d2017c:
#                   physical_memory_kb 105517056 in a 6 GB container)
#   PGVIGIL_WIRING  1 (default) applies scripts/proof-mssql-sessions-wiring.patch (activity.go's grouping sets, web.go,
#                   mssql_perf.ts, 0190: the lead's files) to this copy when the tree lacks them.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch.
#
# Expected (written before the first run). THE RULE (the lead 09:4x): user / system = sys.dm_exec_sessions.is_user_process
# (1 user, 0 system) over ALL sessions, everywhere on the Connections page; the activity total moves from 'session_id > 50'
# (PerformanceMonitor's) to all sessions too (docs and a release-note line name the departure).
#  A. the container: a monitor login (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE); three logins
#     l1-l3; database pgvss with dbo.t (100,000 rows) and dbo.hold (one row).
#  P1 sessions by status x user / system: the held set below plus l1-l3 idle sessions (sleeping) and a dormant-free box:
#     the stored per-minute counts (mssql_sessions) of user and system running / sleeping / dormant / preconnect (a
#     session's own statuses; 'background' is a request's) equal a hand read of sys.dm_exec_sessions GROUP BY is_user_process, status taken
#     before and after the collector's read in the same minute (both equal, or retried, at most 5 cycles); pgvigil's own
#     reading session is left out of both (its program name) and the hand read says how many it left out.
#  P1b the activity total under the rule (the WIRING patch): the 5-minute total's sessions = every session the hand read
#     sees (system sessions under 51 included), its background = the system sessions; the program / host / database
#     groups unchanged ('user sessions with a program name', A2) and their sum named so on the page.
#  A3 the groups (5 minutes, activity.go's GROUPING SETS): by login, by status x user / system, by interface (net_transport
#     + protocol_type of the physical connection: parent_connection_id IS NULL inside the LEFT JOIN's ON), by client
#     address, by isolation level: each dimension's rows sum to the total session count with system sessions present
#     (a system session has no connection: it falls in the NULL bucket, kept and named 'no connection'); a session over
#     MARS counted once; the 'other' row by GROUPING() (P6).
#  P2 requests by status: a held set - a request blocked on dbo.hold (suspended, LCK_M_*), a WAITFOR DELAY (suspended,
#     WAITFOR), a CPU loop (running or runnable), a sleeping session with an open transaction - read by mssql_sessions:
#     the stored counts of running + runnable, suspended, sleeping and background equal a hand read of
#     sys.dm_exec_requests taken before and after the collector's read in the same minute (both hand reads equal, or
#     the cycle is retried, at most 5 cycles).
#  P4 waiting tasks: the blocked request counted in waiting tasks with its wait; the WAITFOR (a benign wait of
#     waits.go benignWaits) not counted; the longest wait at least the blocked request's hand-read wait_duration_ms.
#  P5 top-N over a range [refined before the first run: one request cannot top every list, so two known requests]: R1
#     (l3) a 150 s loop scanning dbo.t (CPU, logical reads, duration) and R2 (l2) a sort of 3,000,000+ rows with
#     MAX_GRANT_PERCENT that spills to tempdb (a 50 MB+ grant) [mechanism refined from box diag 413-p5diag before P5's
#     first graded run: MIN_GRANT_PERCENT on 'TOP (1) ... ORDER BY' made a TopN sort, tempdb 0; R2 now a full sort in a
#     100 s loop started after R1 and ended before it], both captured by mssql_requests over their minutes; the sessions
#     earlier parts hold are ended before P5 starts: GET
#     /api/mssql/sessions over the range lists R1 at rank 1 of CPU, logical reads and duration and R2 at rank 1 of tempdb
#     and grant (their sessions and logins),
#     the statement under the query_text policy (full: the text; none: no text, the policy's words); the reply says the
#     snapshot keeps user requests and sessions with an open transaction only.
#  P6 'other': 55 logins each holding one session: the login dimension holds 50 named rows and one 'other' row whose
#     sessions are the other 5 (+ any login past them), 'other' made by GROUPING() (a login named 'other' stays a named
#     row of its own).
#  P7 the page: proof-a11y 0 nodes and proof-wording OK on the Connections page with the wiring (the walks job); the
#     active-transactions chart off with its reason ('needs the Databases counters collector, mssql_counters_db') while
#     401 is not joined; every new control works or is off with its reason.
#  A6 the read's time: 5,000 sessions held open (from the box's own client pool), the groups read and the per-minute
#     read each timed 3 times: printed as MEASURE lines with the rows and bytes each read stores; a read over 5 s FAILs
#     the row (the collector budget's share).
#  Red on f8e89d2 (before 413): collect refuses mssql_sessions (unknown collection); no route /api/mssql/sessions;
#  no 'login' group in the activity read's rows.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
PARTS=${PGVIGIL_PARTS:-P1 P2 P4 P5 P6 A6}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvss-sql-$SUF; LBL=pgvigil-proof=413
PGDB=pgv_ss_$SUF; MON=pgv_smon_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
part() { [[ " $PARTS " == *" $1 "* ]]; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; BG=()
SA_PW=$(pw); MON_PW=$(pw); LP_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\nLP_PW=%s\n' "$SA_PW" "$SA_PW" "$LP_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && grep -q 'func (s \*Server) MSSQLSessions' internal/web/*.go && ! grep -q 'mssql/sessions"' internal/web/web.go; then
  git apply scripts/proof-mssql-sessions-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-mssql-sessions-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (activity.go, web.go, mssql_perf.ts, 0190, docs)"
fi

echo "== A. the container ($IMG_SQL) =="
MEMCAP=(); [[ "${PGVIGIL_SQL_MEM_MB:-4096}" != 0 ]] && MEMCAP=(-e "MSSQL_MEMORY_LIMIT_MB=${PGVIGIL_SQL_MEM_MB:-4096}")
docker run -d --name "$SQL" --label "$LBL" --memory 6g "${MEMCAP[@]}" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
SQLCMD=
for _ in $(seq 1 60); do
  for c in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do docker exec "$SQL" test -x "$c" 2>/dev/null && SQLCMD=$c && break 2; done
  sleep 1
done
[[ -n "$SQLCMD" ]] || fail "A: no sqlcmd in the image"
TRUST=; [[ "$SQLCMD" == *tools18* ]] && TRUST=-C
sq() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" "${4:-180}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
for _ in $(seq 1 150); do [[ "$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true)" == 1 ]] && break; sleep 2; done
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
VER=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")
[[ -n "$VER" ]] || fail "A: the SQL Server container did not come up"
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON]; GRANT CONNECT ANY DATABASE TO [$MON];"
sqok "A: pgvss" "CREATE DATABASE pgvss; ALTER DATABASE pgvss SET RECOVERY SIMPLE;"
sqok "A: dbo.t and dbo.hold" "CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, c int NOT NULL, pad char(400) NOT NULL DEFAULT 'p');
  INSERT dbo.t (id, c) SELECT TOP (100000) n, n % 997 FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
  CREATE TABLE dbo.hold (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT dbo.hold VALUES (1, 0);" pgvss 300
# l1-l3 and lp01-lp55 (P6) and a login named 'other' (P6: a name, not the rest); each a user in pgvss with dbo's rows
LOGINS="l1 l2 l3 other $(printf 'lp%02d ' $(seq 1 55))"
TSQL=""; for l in $LOGINS; do TSQL+="CREATE LOGIN [$l] WITH PASSWORD = '$LP_PW', CHECK_POLICY = OFF, DEFAULT_DATABASE = pgvss; "; done
sqok "A: the logins" "$TSQL"
TSQL=""; for l in $LOGINS; do TSQL+="CREATE USER [$l] FOR LOGIN [$l]; GRANT SELECT, UPDATE ON SCHEMA::dbo TO [$l]; "; done
sqok "A: their users" "$TSQL" pgvss

go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_S_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
{ printf 'repository:\n  dsn: "%s"\ninstances:\n' "$PGDSN"
  printf '  - name: ss\n    engine: sqlserver\n    dsn: env:PGV_S_MON\n    query_text: full\n'
  printf '  - name: ssnone\n    engine: sqlserver\n    dsn: env:PGV_S_MON\n    query_text: none\n'
} > "$TMPD/m.yaml"
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
# memstat <label>: the container's memory against its limit, its cgroup memory events and SQL Server's own view of memory
memstat() { echo "     MEM $1: $(docker stats --no-stream --format '{{.MemUsage}}' "$SQL" 2>/dev/null); $(docker exec "$SQL" sh -c 'cat /sys/fs/cgroup/memory.events 2>/dev/null | tr "\n" " "' 2>/dev/null); $(sq "SELECT CONCAT('physical_kb ', i.physical_memory_kb, ' committed_kb ', i.committed_kb, ' target_kb ', i.committed_target_kb) FROM sys.dm_os_sys_info i" master 30 2>/dev/null)"; }
col() { local i=$1; shift; for c in "$@"; do timeout 300 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance "$i" -once "$c" >"$TMPD/col-$i-$c.out" 2>&1 || { cat "$TMPD/col-$i-$c.out" >&2; memstat "at the failed collect" >&2; fail "collect $i $c"; }; done; }
col ss mssql_instance; col ssnone mssql_instance
ISS=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'ss'"); INONE=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'ssnone'")
echo "ok   A: SQL Server $VER, pgvss, $(echo $LOGINS | wc -w) logins, instances ss $ISS / ssnone $INONE, SQL memory cap ${PGVIGIL_SQL_MEM_MB:-4096} MB"
memstat "after A"

# hold <login> <seconds> <T-SQL>: one session of <login> in pgvss (host name pgvss-<login>) that runs the batch at once, then
# stays connected (sleeping) for <seconds>. sqlcmd reads its stdin with no -i: given '-i /dev/stdin' it reads the input to its
# end before running a batch, so a held pipe never ran (box diag 413-p5diag T1: the session sleeping, no request at 5 s).
cat > "$TMPD/hold.sh" <<'HOLD'
{ printf 'SET NOCOUNT ON;\nGO\n%s\nGO\n' "$4"; sleep "$3"; } | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$LP_PW exec '"$5"' -S localhost -U "$0" '"$6"' -d pgvss -b -h -1 -H "pgvss-$0" -l 60' "$7"
HOLD
hold() { setsid bash "$TMPD/hold.sh" "$SQL" "$TMPD/sa.env" "$2" "$3" "$SQLCMD" "$TRUST" "$1" >"$TMPD/hold-$1-$RANDOM.out" 2>&1 & BG+=($!); }
# unhold: every held session ends (its process group, then a KILL of each pgvss-* session left), so a part starts clean
unhold() { for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done; BG=()
  sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'KILL ' + CAST(session_id AS nvarchar(10)) + N'; ' FROM sys.dm_exec_sessions WHERE host_name LIKE 'pgvss-%' AND session_id <> @@SPID; EXEC (@s);" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do [[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE host_name LIKE 'pgvss-%'" 2>/dev/null)" == 0 ]] && return 0; sleep 1; done
  fail "unhold: pgvss-* sessions still open after 30 s"; }
# heldreq <login>: the session id of <login>'s running request (host pgvss-<login>), waited up to 30 s; else every pgvss-*
# session's request line and the hold outputs are printed and the run fails
heldreq() { local v=; for _ in $(seq 1 60); do v=$(sq "SELECT TOP (1) r.session_id FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.host_name = 'pgvss-$1'" 2>/dev/null || true); [[ -n "$v" ]] && { echo "$v"; return 0; }; sleep 0.5; done
  sq "SELECT CONCAT(s.session_id, '|', s.login_name, '|', s.host_name, '|', s.status, '|', ISNULL(r.command, '-'), '|', ISNULL(r.status, '-'), '|', ISNULL(r.wait_type, '-'))
    FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id WHERE s.host_name LIKE 'pgvss-%' OR s.login_name = '$1'" >&2 || true
  for f in "$TMPD"/hold-"$1"-*.out; do [[ -e "$f" ]] && echo "  --- $(basename "$f"): $(head -c 300 "$f" | tr '\n' ' ')" >&2; done
  return 1; }
# the hand reads: every session but the hand read's own (@@SPID) and pgvigil's (its program name)
HAND_S="SELECT CONCAT(CASE WHEN is_user_process = 1 THEN 'user_' ELSE 'system_' END,
  CASE WHEN status IN ('running', 'sleeping', 'dormant', 'preconnect') THEN status ELSE 'other' END, '=', COUNT(*))
  FROM sys.dm_exec_sessions WHERE session_id <> @@SPID AND ISNULL(program_name, '') NOT LIKE 'pgvigil%'
  GROUP BY is_user_process, CASE WHEN status IN ('running', 'sleeping', 'dormant', 'preconnect') THEN status ELSE 'other' END ORDER BY 1"
HAND_R="SELECT CONCAT('req_', CASE WHEN s.is_user_process = 1 THEN 'user_' ELSE 'system_' END,
  CASE WHEN r.status IN ('running', 'runnable', 'suspended', 'sleeping', 'background') THEN r.status ELSE 'other' END, '=', COUNT(*))
  FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
 WHERE r.session_id <> @@SPID AND ISNULL(s.program_name, '') NOT LIKE 'pgvigil%'
 GROUP BY s.is_user_process, CASE WHEN r.status IN ('running', 'runnable', 'suspended', 'sleeping', 'background') THEN r.status ELSE 'other' END ORDER BY 1"
BENIGN=$(sed -n '/^var benignWaits = func/,/^}()/p' internal/mssql/waits.go | sed -n '/`/,/`/p' | tr -d '`' | tr -s ' \n' ' ')
HAND_W="SELECT CONCAT(w.wait_type, '=', COUNT(*), '=', MAX(w.wait_duration_ms)) FROM sys.dm_os_waiting_tasks w
  JOIN sys.dm_exec_sessions s ON s.session_id = w.session_id
 WHERE s.is_user_process = 1 AND w.session_id <> @@SPID AND ISNULL(s.program_name, '') NOT LIKE 'pgvigil%' GROUP BY w.wait_type"

if part P1 || part P2 || part P4; then
echo "== P1 / P2 / P4. the per-minute counts =="
pq "SELECT 1 FROM pgvigil.mssql_session_count LIMIT 0" >/dev/null 2>&1 || fail "P1: no table pgvigil.mssql_session_count (red on f8e89d2)"
# the held set: l1 idle in a transaction that holds dbo.hold (sleeping, open tran); l2 blocked on it (suspended, LCK_M_*);
# l3 a CPU loop (running / runnable); 'other' a WAITFOR (suspended, a benign wait); three idle sessions of l1
hold l1 600 "BEGIN TRAN; UPDATE dbo.hold SET v = v + 1 WHERE id = 1;"
sleep 2
hold l2 600 "SELECT v FROM dbo.hold WITH (UPDLOCK) WHERE id = 1;"
hold l3 600 "DECLARE @t datetime2 = SYSDATETIME(), @i bigint = 0; WHILE DATEDIFF(second, @t, SYSDATETIME()) < 400 SET @i += 1;"
hold other 600 "WAITFOR DELAY '00:08:00';"
for _ in 1 2 3; do hold l1 600 "SELECT 1;"; done
for _ in $(seq 1 30); do [[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE wait_type LIKE 'LCK_M_%'")" -ge 1 ]] && break; sleep 1; done
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE wait_type LIKE 'LCK_M_%'")" -ge 1 ]] || fail "P2: the blocked request never waited"
P1OK=0
for cycle in 1 2 3 4 5; do
  h1="$(sq "$HAND_S"; sq "$HAND_R")"; w1=$(sq "$HAND_W")
  col ss mssql_sessions
  h2="$(sq "$HAND_S"; sq "$HAND_R")"; w2=$(sq "$HAND_W")
  if [[ "$h1" != "$h2" ]]; then echo "     cycle $cycle: the hand reads differ around the collector's read: retried"; continue; fi
  pq "SELECT row_to_json(c) FROM pgvigil.mssql_session_count c WHERE instance_id = $ISS ORDER BY snapshot_at DESC LIMIT 1" > "$TMPD/count.json"
  if HAND="$h1" W="$w1" BENIGN="$BENIGN" python3 - "$TMPD/count.json" <<'PY'
import json, os, sys
row = json.loads(open(sys.argv[1]).read())
hand = dict(l.split('=') for l in os.environ['HAND'].split() if '=' in l)
bad = []
for k in ['user_running', 'user_sleeping', 'user_dormant', 'user_preconnect', 'user_other', 'system_running', 'system_sleeping',
          'system_dormant', 'system_preconnect', 'system_other', 'req_user_suspended', 'req_user_sleeping', 'req_user_background',
          'req_system_suspended', 'req_system_sleeping', 'req_system_background']:
    if int(hand.get(k, 0)) != int(row[k] or 0): bad.append(f"{k} stored {row[k]} hand {hand.get(k, 0)}")
# running and runnable trade places as the CPU loop is scheduled: compared as one
for who in ['user', 'system']:
    h = int(hand.get(f'req_{who}_running', 0)) + int(hand.get(f'req_{who}_runnable', 0))
    st = int(row[f'req_{who}_running'] or 0) + int(row[f'req_{who}_runnable'] or 0)
    # the collector's own request runs while it reads and is left out (own); the hand read's own is @@SPID
    if h != st: bad.append(f"req_{who}_running+runnable stored {st} hand {h}")
benign = set(os.environ['BENIGN'].split())
waits = [l.split('=') for l in os.environ['W'].split() if l.count('=') == 2]
tasks = sum(int(n) for w, n, _ in waits if w not in benign)
longest = max([int(m) for w, _, m in waits if w not in benign] or [0])
if int(row['waiting_tasks'] or 0) != tasks: bad.append(f"waiting_tasks stored {row['waiting_tasks']} hand {tasks} ({waits})")
if longest and int(row['waiting_longest_ms'] or 0) < longest // 2: bad.append(f"waiting_longest_ms stored {row['waiting_longest_ms']} hand {longest}")
if not any(w.startswith('LCK_M_') for w, _, _ in waits): bad.append(f"no lock wait in the hand read {waits}")
if not any(w == 'WAITFOR' for w, _, _ in waits): bad.append(f"no WAITFOR in the hand read {waits}")
if int(row['own_sessions'] or 0) < 1: bad.append(f"own_sessions {row['own_sessions']}")
print('     stored:', {k: row[k] for k in row if k not in ('instance_id',)})
if bad: print('DIFF', '; '.join(bad)); sys.exit(1)
PY
  then P1OK=1; break; else echo "     cycle $cycle: a difference (above)"; fi
done
[[ $P1OK == 1 ]] || fail "P1 / P2 / P4: the stored counts never met the hand reads in 5 cycles"
echo "ok   P1: sessions by user / system x status equal the hand read; P2: requests by user / system x status (running + runnable as one); P4: the waiting tasks of user sessions with the benign WAITFOR left out, the lock wait counted"
fi

if part P1 || part P6; then
echo "== P1b / A3 / P6. the 5-minute groups (activity's one read) =="
# P6: 55 logins with one idle session each, and 'other' with three (it ranks among the 50 largest by its count)
for l in $(printf 'lp%02d ' $(seq 1 55)); do hold "$l" 600 "SELECT 1;"; done
for _ in 1 2 3; do hold other 600 "SELECT 1;"; done
for _ in $(seq 1 60); do [[ "$(sq "SELECT COUNT(DISTINCT login_name) FROM sys.dm_exec_sessions WHERE login_name LIKE 'lp%'")" == 55 ]] && break; sleep 1; done
A3OK=0
for cycle in 1 2 3 4 5; do
  HAND_L="SELECT CONCAT(login_name, '=', COUNT(*)) FROM sys.dm_exec_sessions WHERE session_id <> @@SPID AND login_name <> '$MON' GROUP BY login_name"
  HAND_T="SELECT CONCAT(COUNT(*), '=', SUM(1 - CAST(is_user_process AS int))) FROM sys.dm_exec_sessions WHERE session_id <> @@SPID AND login_name <> '$MON'"
  l1h=$(sq "$HAND_L" | sort); t1=$(sq "$HAND_T")
  col ss mssql_activity
  l2h=$(sq "$HAND_L" | sort); t2=$(sq "$HAND_T")
  if [[ "$l1h" != "$l2h" || "$t1" != "$t2" ]]; then echo "     cycle $cycle: the hand reads differ around the read: retried"; continue; fi
  AT=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_session_summary WHERE instance_id = $ISS")
  pq "SELECT json_build_object('total', (SELECT row_to_json(x) FROM pgvigil.mssql_session_summary x WHERE instance_id = $ISS AND snapshot_at = '$AT'),
        'by', (SELECT json_agg(b) FROM pgvigil.mssql_session_by b WHERE instance_id = $ISS AND snapshot_at = '$AT'))" > "$TMPD/groups.json"
  if HL="$l1h" HT="$t1" MON="$MON" python3 - "$TMPD/groups.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1])); tot = d['total']; by = d['by'] or []
bad = []
hand_total, hand_system = (int(x) for x in os.environ['HT'].split('='))
# the hand read's sessions per login (the monitor login left out: its read session exists only during the stored read)
hl = {l: int(n) for l, n in (x.rsplit('=', 1) for x in os.environ['HL'].split('\n') if '=' in x)}
lgn = [b for b in by if b['dimension'] == 'login']
named_names = {b['name'] for b in lgn if not b['is_other']}
# each named login (not the monitor) holds the hand read's sessions of that login
for b in lgn:
    if not b['is_other'] and b['name'] != os.environ['MON'] and b['sessions'] != hl.get(b['name'], 0):
        bad.append(f"login {b['name']}: stored {b['sessions']} hand {hl.get(b['name'], 0)}")
# the monitor's sessions at the read: its named row, or - when its one session ranks past the 50 largest (55 one-session
# logins tie with it) - 'other' less the hand read's sessions of every unnamed login (first 2022 run: the monitor in 'other')
mon = [b for b in lgn if not b['is_other'] and b['name'] == os.environ['MON']]
oth = [b for b in lgn if b['is_other']]
mon_n = mon[0]['sessions'] if mon else (oth[0]['sessions'] if oth else 0) - sum(n for l, n in hl.items() if l not in named_names)
# P1b: the total is every session: the hand read's and the monitor login's own read session (pgvigil's own are IN this read)
if mon_n < 1: bad.append(f"the monitor's own read session is not in the stored read ({mon_n}, {'named' if mon else 'in other'})")
if tot['sessions'] - mon_n != hand_total: bad.append(f"total {tot['sessions']} - the monitor's {mon_n} != hand {hand_total}")
if tot['background'] != hand_system: bad.append(f"background {tot['background']} != the hand read's system sessions {hand_system}")
# A3: every dimension sums to the total (system sessions present, their NULL bucket kept)
for dim in ['login', 'status', 'interface', 'address', 'isolation']:
    rows = [b for b in by if b['dimension'] == dim]
    if sum(b['sessions'] for b in rows) != tot['sessions']: bad.append(f"{dim}: rows sum {sum(b['sessions'] for b in rows)} != total {tot['sessions']}")
    if sum(b['user_sessions'] + b['system_sessions'] for b in rows) != tot['sessions']: bad.append(f"{dim}: user + system != total")
itf_null = [b for b in by if b['dimension'] == 'interface' and b['name'] is None and not b['is_other']]
if not itf_null or itf_null[0]['system_sessions'] < 1: bad.append(f"interface: no NULL bucket holding the system sessions {itf_null}")
# P6: 50 named logins and one 'other' row; the login named 'other' a named row; the rest = the hand read's past the 50 largest
lg = [b for b in by if b['dimension'] == 'login']
named, other = [b for b in lg if not b['is_other']], [b for b in lg if b['is_other']]
if len(named) != 50 or len(other) != 1: bad.append(f"login: {len(named)} named rows and {len(other)} other rows")
if not any(b['name'] == 'other' and not b['is_other'] for b in named): bad.append("the login named 'other' is not a named row")
hand = sorted(((-int(n), l) for l, n in (x.rsplit('=', 1) for x in os.environ['HL'].split('\n') if '=' in x)))
if other and other[0]['sessions'] < 5: bad.append(f"other holds {other[0]['sessions']} sessions, want 5+")
print(f"     P1b total {tot['sessions']} (the monitor's {mon_n}), background {tot['background']}; logins named {len(named)} + other {other[0]['sessions'] if other else None}; the hand read's distinct logins {len(hand)}")
if bad: print('DIFF', '; '.join(bad)); sys.exit(1)
PY
  then A3OK=1; break; else echo "     cycle $cycle: a difference (above)"; fi
done
[[ $A3OK == 1 ]] || fail "P1b / A3 / P6: the stored groups never met the hand reads in 5 cycles"
echo "ok   P1b: the total counts every session, background = the system sessions; A3: each dimension sums to the total, the NULL interface bucket holds the system sessions; P6: 50 named logins + 'other', a login named 'other' stays a name"
fi

if part P5; then
echo "== P5. the top requests over a range =="
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "P5: user add"
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.out" >&2; fail "P5: serve exited"; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "P5: the API login"
# the parts before leave sessions held (P1's 400 s loop, its 8-minute WAITFOR): they would compete for rank 1, so they end first
unhold
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# R1 (l3): 150 s scanning dbo.t at MAXDOP 1 (a core's CPU, about 500,000 reads a second: p5diag T3).
# R2 (l2), started after R1 and ended 50 s before it, so R1 keeps rank 1 of CPU and duration: a loop of 100 s over a FULL
# sort of 3,000,000 rows (about 1.3 GB) under MAX_GRANT_PERCENT = 20 (a grant of about 150 MB, under the sort, so it spills).
# Not 'TOP (1) ... ORDER BY': that is a TopN sort that keeps one row and never spills (p5diag T4a: 74 MB grant, tempdb 0).
hold l3 300 "DECLARE @t datetime2 = SYSDATETIME(), @n bigint; WHILE DATEDIFF(second, @t, SYSDATETIME()) < 150 SELECT @n = COUNT_BIG(*) FROM dbo.t WHERE c % 7 = 3 OPTION (MAXDOP 1);"
R1S=$(heldreq l3) || fail "P5: R1 (l3) never ran its request (above)"
hold l2 300 "DECLARE @t datetime2 = SYSDATETIME(), @n bigint; WHILE DATEDIFF(second, @t, SYSDATETIME()) < 100 SELECT @n = MAX(z.rn) FROM (SELECT ROW_NUMBER() OVER (ORDER BY a.pad, b.id DESC, a.c) AS rn FROM dbo.t a CROSS JOIN (SELECT TOP (30) id FROM dbo.t) b) z OPTION (MAXDOP 1, MAX_GRANT_PERCENT = 20);"
R2S=$(heldreq l2) || fail "P5: R2 (l2) never ran its request (above)"
echo "     R1 session $R1S, R2 session $R2S"
# mssql_requests every 20 s while they run (their figures grow; the top takes each request's largest)
for _ in $(seq 1 7); do col ss mssql_requests; col ssnone mssql_requests; sleep 20; done
T1=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
for i in "$ISS" "$INONE"; do
  code=$(curl -s -o "$TMPD/top-$i.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/sessions?instance=$i&from=$T0&to=$T1&n=5")
  [[ "$code" == 200 ]] || { head -c 300 "$TMPD/top-$i.json" >&2; fail "P5: GET /api/mssql/sessions instance $i: HTTP $code (red on f8e89d2: no route)"; }
done
R1S="$R1S" R2S="$R2S" python3 - "$TMPD/top-$ISS.json" "$TMPD/top-$INONE.json" <<'PY' || fail "P5: see above"
import json, os, sys
bad = []
def top(f):
    d = json.load(open(f)); t = d['top']
    return [dict(zip(t['columns'], r)) for r in (t['rows'] or [])], [dict(zip(d['policy']['columns'], r)) for r in d['policy']['rows']][0]
rows, pol = top(sys.argv[1])
want = {'cpu_ms': os.environ['R1S'], 'logical_reads': os.environ['R1S'], 'elapsed_ms': os.environ['R1S'],
        'tempdb_alloc_kb': os.environ['R2S'], 'granted_memory_kb': os.environ['R2S']}
for m, sess in want.items():
    r1 = [r for r in rows if r['measure'] == m and r['rank'] == 1]
    if not r1 or str(r1[0]['session_id']) != sess: bad.append(f"{m}: rank 1 is {r1[0] if r1 else None}, want session {sess}"); continue
    print(f"     {m}: rank 1 session {sess} ({r1[0]['login_name']}) value {r1[0]['value']}")
g = [r for r in rows if r['measure'] == 'granted_memory_kb' and r['rank'] == 1]
if g and g[0]['value'] < 51200: bad.append(f"R2's grant {g[0]['value']} KB, want 50 MB+")
t = [r for r in rows if r['measure'] == 'tempdb_alloc_kb' and r['rank'] == 1]
if not t or t[0]['value'] <= 0: bad.append(f"R2 allocated no tempdb: {t}")
if pol['query_text'] != 'full' or not any(r['statement'] for r in rows if r['measure'] == 'cpu_ms' and r['rank'] == 1): bad.append(f"ss (full): no statement on R1's row ({pol})")
rows2, pol2 = top(sys.argv[2])
if pol2['query_text'] != 'none' or any(r['statement'] for r in rows2): bad.append(f"ssnone (none): a statement returned ({pol2})")
if bad: print('DIFF', '; '.join(bad)); sys.exit(1)
PY
memstat "after P5"
echo "ok   P5: R1 at rank 1 of CPU, logical reads and duration, R2 at rank 1 of tempdb and grant (50 MB+); the statement under 'full', none under 'none'"
fi

if part A6; then
echo "== A6. the reads' time at about 5,000 sessions =="
export PGV_HOLD_DSN="sqlserver://l1:$(urlq "$LP_PW")@127.0.0.1:$PORT_SQL?database=pgvss&encrypt=true&TrustServerCertificate=true&connection+timeout=60"
go run ./scripts/proof-sessions-hold 5000 900 >"$TMPD/hold5k.out" 2>"$TMPD/hold5k.err" & BG+=($!)
for _ in $(seq 1 300); do grep -q '^held' "$TMPD/hold5k.out" 2>/dev/null && break; sleep 1; done
grep -q '^held' "$TMPD/hold5k.out" || { cat "$TMPD/hold5k.err" >&2; fail "A6: the 5,000 sessions never opened"; }
N=$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions")
memstat "A6, $N sessions held"
echo "     $(cat "$TMPD/hold5k.out"); the server lists $N sessions"
A6FAIL=0
for c in mssql_sessions mssql_activity; do
  for k in 1 2 3; do
    t0=$(date +%s%N); col ss "$c"; t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
    echo "MEASURE A6: $c at $N sessions, run $k: ${ms} ms (the whole collect -once: connect, read, import)"
    (( ms <= 5000 )) || A6FAIL=1
  done
done
echo "MEASURE A6: rows per read: mssql_session_count 1; mssql_session_by $(pq "SELECT count(*) FROM pgvigil.mssql_session_by WHERE instance_id = $ISS AND snapshot_at = (SELECT max(snapshot_at) FROM pgvigil.mssql_session_by WHERE instance_id = $ISS)") at the newest read"
echo "MEASURE A6: bytes per row: mssql_session_count $(pq "SELECT round(avg(pg_column_size(c.*))) FROM pgvigil.mssql_session_count c"), mssql_session_by $(pq "SELECT round(avg(pg_column_size(b.*))) FROM pgvigil.mssql_session_by b")"
[[ $A6FAIL == 0 ]] || fail "A6: a read took over 5 s at $N sessions (the MEASURE lines above)"
echo "ok   A6: both reads under 5 s at $N sessions"
fi

echo "PASS: proof-mssql-sessions ($PARTS) on SQL Server $VER"
