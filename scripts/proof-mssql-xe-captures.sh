#!/usr/bin/env bash
# Proof of the optional Extended Events captures (task 411, B18: migration 0162_mssql_xe_captures.sql,
# internal/mssql/xe_captures.go, internal/web/q_mssql_xe_captures.go, web/src/mssql_xe.ts) on a real SQL Server: the
# printed script made and run by sa as the server's DBA, each event provoked, read by `collect -once` as the service
# does, and graded against sa's own read of the same sessions.
#
# Needs: docker, go, psql, and
#   ADMIN_DSN    a superuser connection to a PostgreSQL in KEYWORD form (default 'host=127.0.0.1 port=5432 user=postgres
#                dbname=postgres'), no password in it (PGPASSWORD or ~/.pgpass); the proof's repository database is made
#                there and dropped.
#   MSSQL_IMAGE  the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_PARTS  the parts to run (default MABCDEFGS; they run in the file's order: M A B C D G E F S); S needs node,
#                npm, chromium, curl and python3
#   PGVIGIL_VERSION_PASS 1 = the script-and-read pass on another version (MSSQL_IMAGE 2017 / 2019, PGVIGIL_PARTS=MABC):
#                  every check as on 2022 except A2, which prints the events the script left out instead of wanting none
#   PGVIGIL_WIRING 1 (default) applies scripts/proof-mssql-xe-captures-wiring.patch (the CLI's -captures, the routes, the
#                  tabs, the findings arm) to this copy first
# The proof makes, and removes on every exit path, its repository database and one SQL Server container of its own.
#
# Expected (written before the first run):
#  M. migrate exits 0; import_mssql_xe_captures, import_mssql_xe_capture_config, mssql_xe_slow_trend and
#     mssql_xe_captures_findings exist.
# Changed after the first green run (sqltb-s2-411-green1; the product's answers held, the proof's own slips fixed):
# sp_pgvproof is made through stdin (CREATE PROCEDURE must open its batch: it was never made, so C7's 'not sp_pgvproof'
# proved nothing); the hand reads run with QUOTED_IDENTIFIER on (sqlcmd -I: XML methods need it) and count only the
# events up to the stored cursor's last event (sa's own reads raise plan_affecting_convert after pgvigil's read); C8's
# order is the captures' sort order.
#  A. `pgvigil mssql-xe -print -captures all -install-id cap` writes a script that sa runs: the four sessions
#     pgvigil_cap_waits, _warnings, _warncounts, _modules are created and running; no 'left out' line on 2022 (every
#     event exists there); a second run of the script says 'exists, left as it is' four times.
#  B. provoked in the proof's database: a lock wait of about 3 s (a holder updates a row and waits 3 s, a second session
#     updates the same row); a WAITFOR DELAY of 2 s; a sort that spills (MAX_GRANT_PERCENT = 0 on 200,000 rows); a join
#     with no predicate; a plan-affecting implicit conversion (varchar column, nvarchar value); 20,000 inserts of random
#     GUID keys (page splits: about 18 rows a page); a procedure of 6 s; a procedure of 50 ms; master.dbo.sp_pgvproof of 6 s (the default
#     procedure exclusion 'master.sp[_]%').
#  C. `collect -once mssql_xe_captures` twice (the counter needs two reads), then:
#     C1 a wait LCK_M_X of 2,500 to 6,000 ms stored (2,000 since the V result below; and equal to sa's read of the
#     file), category 'Locking'; C2 no WAITFOR wait stored; C3 (sa reads the files in /var/opt/mssql/log/, the Linux image's log folder) the stored waits equal
#     sa's count of wait_info events over 1,000 ms in the waits session's file (the same events, after the read's
#     filter); C4 sort_warning counted at least once; C5 missing_join_predicate and plan_affecting_convert each counted at
#     least once, or written down as the server's answer if it raised none; C6 page_split's difference between the two
#     reads at least 1,000; C7 the 6 s procedure stored with 5,500 to 8,000 ms, the 50 ms one not, sp_pgvproof not;
#     C8 every capture's state 'running'.
#  D. the settings: wait_ms 5000 at the instance; a new lock wait of about 3 s is then not stored (the read's filter);
#     wait_ms 50 refused, a proc_exclude entry without a dot refused, each with its log row. (The GET's script with
#     these settings is S2's: D runs no web server.)
#  E. the drop script drops the four sessions and leaves a session of another name (other_waits) running.
#  F. the trend: login trend_a runs 3 batches of WAITFOR 1.2 s and trend_b 2, under pgvigil's slow session (the
#     four-session script); mssql_xe_slow_trend by login counts 3 and 2 completions for them.
# Parts G and S, written after green2 (sqltb-s2-411-green2: MABCDEF OK) and before their first run - the rest of the
# design's provocations and the API with the page. G runs before E (E drops the sessions); the container runs SQL
# Server Agent (MSSQL_AGENT_ENABLED) for G5. The hand reads now compare each event's own XML timestamp with the
# cursor's at microseconds (timestamp_utc carries more digits than the XML the reader stores); C5 now needs at least 1
# of each (green2 raised both: a 0 = 0 would pass on nothing).
# Changed after green3 (sqltb-s2-411-green3; the product's answers held): G1's two hash statements carry
# USE HINT('DISALLOW_BATCH_MODE') - on 2022 at compatibility 160 they ran in batch mode over rowstore, whose spills
# raise no hash_warning (the file and the store both held 0) [inferred: the hint's run says]; S registers xc_lost with
# one collect (an instance's row is made when a collect first connects, not by migrate or serve).
# Changed after green4 (sqltb-s2-411-green4; every other check passed): hash_warning was still 0 in the file and the
# store. The old join carried only its int key (COUNT(*)), so its build rows were about 12 bytes and may never have
# spilled; and Hash Warning is documented for recursion (a partition that still does not fit) and bailout (the deepest
# level reached, data skew), so a spill that fits after one partitioning may raise none. G1 now runs three statements,
# each tagged and each with FORCE ORDER where it joins: G1a the hash aggregate as before; G1b a hash join whose build
# carries pad (char(200), about 42 MB against the minimum grant); G1c a hash join of dbo.hw (10,000 rows of char(2000),
# every key 0) with itself and a residual that is never true - no partitioning can split one key and both sides are the
# same size (role reversal gains nothing), so it must recurse to the deepest level and bail out. Printed as 'G1 info'
# (evidence for the grade, never graded): the event's description and data columns from sys.dm_xe_objects /
# dm_xe_object_columns, each statement's total_spills from sys.dm_exec_query_stats, and the file's hash_warning rows by
# type and level. Expected: G1c raises hash_warning (recursion, then bailout) and G1-G3 passes with at least 1.
# Result green5 (sqltb-s2-411-green5: PROOF OK MABCDEFGS, go test ok): G1-G3 passed with 16, every one 'Recursion level
# 1', and they came from G1b (6,144 spills); G1c spilled 0 (total_spills 0, 3 s), not the bailout expected [unverified
# why]. G1c stays as run until the review's fold.
#  V (written before its first run): PGVIGIL_VERSION_PASS=1, PGVIGIL_PARTS=MABC on SQL Server 2017 and 2019 (the CU
#     images): M, A1, A3, B and C pass as on 2022; A2 printed - expected 'none' on both [inferred: all 16 events are in
#     the 2016 event catalogue]; a listed event is the server's answer, and the C check that needs it says so.
# Result V: v2019 (15.0.4510.2) PROOF OK MABC, A2 none; v2017 (14.0.3570.2) A2 none, one FAIL - C1 stored 2,499 ms
# against 2,500 to 6,000. Root cause: the waiter starts 0.5 s after the holder's 3 s hold, so the wait the proof makes
# is about 2,500 ms - C1's floor sat on the value itself (every run before read 2,505 to 2,772). Changed: C1's window
# is 2,000 to 6,000 (3 s less the head start, less up to 0.5 s of start skew), and C1 now also wants the stored wait
# EQUAL to sa's read of the LCK_M_X duration in the file (the exact check the window never was). Rerun: v2017b 3,063,
# v2019b 2,506, 2022 (parts MABC) 2,499 - the old floor would have failed 2022 too - each equal to sa's read; PROOF OK.
#  G. auto create statistics off in xcdb, then: G1 a hash aggregate, a wide-build hash join and a one-key hash join (all
#     MAX_GRANT_PERCENT = 0, row mode) - hash_warning stored as sa's read of the file has it, at least 1; G2 a predicate on a column with no statistics
#     (dbo.g.pad) - missing_column_statistics the same, at least 1; G3 a filtered index (vc_f, WHERE id > 100) and a
#     parameterised query through sp_executesql that cannot use it - unmatched_filtered_indexes the same, at least 1;
#     G4 sp_cache_miss's difference between B's two reads at least 20 (B ran 20 statements of distinct text);
#     G5 a SQL Agent job (step: EXEC dbo.p_slow in xcdb) succeeds, and its module_end is not in the modules file (the
#     session's own filter: 'SQLAgent - TSQL JobStep%'): the file and the store hold B's one p_slow run, the job's
#     history 1 success; G6 every one of the 11 warning events: stored = sa's read of the file up to the cursor
#     (an event the server never raised says 0 = 0 and is listed); G7 app_exclude at the instance with 'SQLCMD' added,
#     p_slow run again from sqlcmd: the file holds 2 p_slow runs, the store still 1 (the read applies the list);
#     G8 imported rows, each named so (database 'imported'; a container does not raise them on demand):
#     long_io_detected, additional_memory_grant, execution_warning, optimizer_timeout, exchange_spill one each in
#     warning_hours, and a wait_info_external of 7,000 ms stored with its category.
#  S. two serves of the proof's repository on loopback, one with the UI login (a user made by `pgvigil user add`), one
#     -no-login; a second instance xc_lost in the config, never collected, given two state rows of 0065's import per
#     capture (deadlocks, blocked: the ring took 50 events more than the read found).
#     S1 signed in: GET 200, writable true; S2 part=script with install_id cap, text none: 'pgvigil_cap_waits',
#     '[opcode]=(1) AND [duration]>=(5000)' (D's 5000 at the instance), no 'sqlserver.sql_text'; S3 part=waits_by_type
#     has LCK_M_X; S4 POST module_ms 7000 at the instance: 200, the setting 7000; its end: 200, the setting 5000 again;
#     S5 the POST with no session 401, with a session and no X-Pgvigil header 403; S6 -no-login: GET writable false
#     with its reason, a POST 403; S7 part=lost on xc_lost: 'blocked=50 deadlocks=50'; S8 by=nobody 400, plan_hash=0x12
#     400; S9 the page in headless Chromium, both themes, axe-core 4.14.0 (WCAG 2.1 A / AA): the four new tabs on xc
#     render with no error box and 0 axe nodes, the XE captures tab's controls under -no-login all off with a visible
#     reason (off > 0, offBad 0, no live Save), signed in live Save buttons; xc_lost's Deadlocks and Blocked reports
#     tabs show the 'events lost' line.
set -u
PARTS=${PGVIGIL_PARTS:-MABCDEFGS}
has() { case "$PARTS" in *"$1"*) return 0 ;; esac; return 1; }
SUF=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
REPO_DB=pgvigil_xc_$SUF; SQL=pgv-xc-$SUF; TMPD=$(mktemp -d)
FAILS=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL (setup) $*"; exit 1; }
want() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1: got [$2], want [$3]"; fi; }
between() { awk -v v="$2" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v != "" && v >= lo && v <= hi) }' && pass "$1 ($2)" || bad "$1: got [$2], want $3 to $4"; }
MADE_DB=; SRV=; SRV2=; CHR=
cleanup() {
  rc=$?
  for p in $SRV $SRV2 $CHR; do kill "$p" 2>/dev/null; done
  docker rm -f "$SQL" >/dev/null 2>&1
  if [ -n "$MADE_DB" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped"; fi
  rm -rf "$TMPD"
  exit $rc
}
trap cleanup EXIT

if [ "${PGVIGIL_WIRING:-1}" = 1 ] && ! grep -q 'mssql/xecaptures' internal/web/web.go; then
  git apply scripts/proof-mssql-xe-captures-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-mssql-xe-captures-wiring.patch >/dev/null || die "the wiring patch"
fi
grep -q 'mssql/xecaptures' internal/web/web.go || die "the wiring is not in (the CLI's -captures and the routes)"
if has S; then
  for t in chromium node npm curl python3; do command -v $t >/dev/null || die "S: $t is not on this machine"; done
  # the bundle with the new tabs, before the build: the web UI is embedded in the binary
  (cd web && npm ci --no-audit --no-fund >/dev/null 2>&1 && npx esbuild src/main.ts --bundle --minify --format=esm --target=es2020 --outfile=../internal/web/dist/app.js >/dev/null 2>&1) || die "S: the web bundle"
fi
go build -o "$TMPD/pgvigil" ./cmd/pgvigil || die "go build"
BIN=$TMPD/pgvigil
pw() { printf 'Px9%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); LPW=$(pw)
export SQLCMDPASSWORD="$SAPW"
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nMSSQL_MEMORY_LIMIT_MB=2048\nMSSQL_AGENT_ENABLED=true\n' "$SAPW" > "$TMPD/sa.env"
docker run -d --name "$SQL" --memory 3g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG" >/dev/null || die "docker run"
PORT=$(docker port "$SQL" 1433 | head -1 | sed 's/.*://')
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
docker exec "$SQL" test -x "$SQLCMD" || SQLCMD=/opt/mssql-tools/bin/sqlcmd
sq() { docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -b -I -W -h -1 -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# the newest event a capture's stored cursor has read (the hand reads count no event past it)
# sa's count of one warning event in the warnings file, up to the stored cursor's last event
handwarn() { sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log/pgvigil_cap_warnings*.xel', NULL, NULL, NULL) f CROSS APPLY (SELECT CAST(f.event_data AS xml) x) e WHERE f.object_name = N'$1' AND e.x.value('(event/@timestamp)[1]', 'datetime2(7)') <= '$(lastread pgvigil_cap_warnings)'"; }
storedwarn() { q "select coalesce(sum(events), 0) from pgvigil.mssql_xe_warning_hours where instance_id = $(iid) and event_name = '$1' and database_name <> 'imported'"; }
lastread() { q "select to_char(last_event_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US') from pgvigil.mssql_cursor where instance_id = $(iid) and source = '$1'"; }
sqs() { docker exec -i -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -W -h -1 -d "${1:-master}" -i /dev/stdin; }
sqbg() { docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -d xcdb -Q "$1" > /dev/null 2>&1 & }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || die "SQL Server did not answer"
echo "server: $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40))")"
printf "CREATE LOGIN xc_mon WITH PASSWORD = '%s', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO xc_mon; GRANT VIEW ANY DEFINITION TO xc_mon;
CREATE LOGIN trend_a WITH PASSWORD = '%s', CHECK_POLICY = OFF; CREATE LOGIN trend_b WITH PASSWORD = '%s', CHECK_POLICY = OFF;" "$LPW" "$LPW" "$LPW" | sqs >/dev/null || die "the logins"
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" || die "the repository database"; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export XC_DSN="sqlserver://xc_mon:$LPW@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
CFG=$TMPD/pgvigil.yaml
# xc_lost is never collected: part S gives it state rows of its own (the loss line)
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: xc\n    engine: sqlserver\n    dsn: env:XC_DSN\n  - name: xc_lost\n    engine: sqlserver\n    dsn: env:XC_DSN\n' > "$CFG"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance xc > "$TMPD/c.out" 2>&1 || bad "collect -once $1: $(tail -3 "$TMPD/c.out")"; }
"$BIN" migrate -config "$CFG" > "$TMPD/m.out" 2>&1 || die "migrate: $(tail -3 "$TMPD/m.out")"
IID=""; iid() { [ -n "$IID" ] || IID=$(q "select instance_id from pgvigil.instances where name = 'xc'"); echo "$IID"; }

if has M; then
  echo "--- M. the migration"
  pass "M1: migrate exit 0"
  want "M2: the objects exist" "$(q "select count(*) from pg_proc where proname in ('import_mssql_xe_captures', 'import_mssql_xe_capture_config', 'mssql_xe_slow_trend')")|$(q "select count(*) from pg_views where viewname = 'mssql_xe_captures_findings'")" "3|1"
fi

if has A; then
  echo "--- A. the script, run by sa"
  "$BIN" mssql-xe -print -captures all -install-id cap > "$TMPD/cap.sql" || die "A: mssql-xe -print -captures all"
  sqs < "$TMPD/cap.sql" > "$TMPD/cap.out" 2>&1
  want "A1: the four sessions created and running" "$(sq "SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name IN (N'pgvigil_cap_waits', N'pgvigil_cap_warnings', N'pgvigil_cap_warncounts', N'pgvigil_cap_modules')")" "4"
  if [ "${PGVIGIL_VERSION_PASS:-0}" = 1 ]; then
    LO=$(grep 'left out' "$TMPD/cap.out" | sed 's/.*: //' | sort -u | tr '\n' ' ')
    echo "  A2 (printed, a version pass): left out: ${LO:-none}"
  else
    want "A2: no event left out on this version" "$(grep -c 'left out' "$TMPD/cap.out")" "0"
  fi
  sqs < "$TMPD/cap.sql" > "$TMPD/cap2.out" 2>&1
  want "A3: a second run leaves them as they are" "$(grep -c 'exists, left as it is' "$TMPD/cap2.out")" "4"
  [ "$(grep -c 'created:' "$TMPD/cap.out")" = 4 ] || echo "  the script's output: $(grep -v '^$' "$TMPD/cap.out" | head -12 | tr '\n' ' ')"
fi

if has B; then
  echo "--- B. the events provoked"
  sq "CREATE DATABASE xcdb;" >/dev/null || die "B: xcdb"
  sqs xcdb >/dev/null <<'EOF'
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, v int NOT NULL, pad char(200) NOT NULL DEFAULT 'x');
INSERT dbo.t (id, v) SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), ABS(CHECKSUM(NEWID())) FROM sys.all_objects a CROSS JOIN sys.all_objects b;
CREATE TABLE dbo.vc (id int IDENTITY PRIMARY KEY, code varchar(20) NOT NULL);
INSERT dbo.vc (code) SELECT TOP (50000) CONVERT(varchar(20), ABS(CHECKSUM(NEWID()))) FROM sys.all_objects a CROSS JOIN sys.all_objects b;
CREATE INDEX vc_code ON dbo.vc (code);
CREATE TABLE dbo.g (id uniqueidentifier NOT NULL PRIMARY KEY CLUSTERED, pad char(400) NOT NULL DEFAULT 'x');
GO
CREATE PROCEDURE dbo.p_slow AS WAITFOR DELAY '00:00:06';
GO
CREATE PROCEDURE dbo.p_fast AS WAITFOR DELAY '00:00:00.050';
GO
EOF
  printf "CREATE PROCEDURE dbo.sp_pgvproof AS WAITFOR DELAY '00:00:06';\n" | sqs >/dev/null
  [ "$(sq "SELECT COUNT(*) FROM sys.procedures WHERE name = N'sp_pgvproof'")" = 1 ] || bad "B: master.dbo.sp_pgvproof not made"
  # the lock wait: a holder keeps the row 3 s, a second session waits for it
  sqbg "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:03'; ROLLBACK;"
  sleep 0.5
  sq "UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 1);" xcdb >/dev/null
  sq "WAITFOR DELAY '00:00:02';" xcdb >/dev/null
  sq "SELECT TOP (10) * FROM (SELECT v, pad FROM dbo.t ORDER BY v, pad OFFSET 0 ROWS) x OPTION (MAX_GRANT_PERCENT = 0);" xcdb >/dev/null
  sq "SELECT COUNT(*) FROM dbo.t a, dbo.vc b WHERE a.id < 10 AND b.id < 10;" xcdb >/dev/null
  sq "DECLARE @c nvarchar(20) = N'12345'; SELECT COUNT(*) FROM dbo.vc WHERE code = @c;" xcdb >/dev/null
  sq "EXEC dbo.p_slow; EXEC dbo.p_fast;" xcdb >/dev/null
  sq "EXEC dbo.sp_pgvproof;" >/dev/null
  collect mssql_xe_captures
  sq "DECLARE @i int = 0; WHILE @i < 20000 BEGIN INSERT dbo.g (id) VALUES (NEWID()); SET @i += 1; END;" xcdb >/dev/null
  for i in $(seq 1 20); do sq "SELECT $i + COUNT(*) FROM dbo.vc WHERE id = $i;" xcdb >/dev/null; done
  sleep 6
  collect mssql_xe_captures
  pass "B: provoked (the checks are C's)"
fi

if has C; then
  echo "--- C. what was stored"
  I=$(iid)
  LW=$(lastread pgvigil_cap_waits)
  LCK=$(q "select max(duration_ms) from pgvigil.mssql_xe_waits where instance_id = $I and wait_type = 'LCK_M_X'")
  between "C1: a lock wait of about 3 s less the waiter's 0.5 s head start" "$LCK" 2000 6000
  want "C1: it equals sa's read of the file" "$LCK" "$(sq "SELECT MAX(e.x.value('(event/data[@name=\"duration\"]/value)[1]', 'bigint')) FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log/pgvigil_cap_waits*.xel', NULL, NULL, NULL) f CROSS APPLY (SELECT CAST(f.event_data AS xml) x) e WHERE f.object_name = N'wait_info' AND e.x.value('(event/data[@name=\"wait_type\"]/text)[1]', 'nvarchar(60)') = N'LCK_M_X' AND e.x.value('(event/@timestamp)[1]', 'datetime2(7)') <= '$LW'")"
  want "C1: its category" "$(q "select category from pgvigil.mssql_xe_waits where instance_id = $I and wait_type = 'LCK_M_X' limit 1")" "Locking"
  want "C2: no WAITFOR stored" "$(q "select count(*) from pgvigil.mssql_xe_waits where instance_id = $I and wait_type = 'WAITFOR'")" "0"
  HAND=$(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log/pgvigil_cap_waits*.xel', NULL, NULL, NULL) f CROSS APPLY (SELECT CAST(f.event_data AS xml) x) e WHERE f.object_name IN (N'wait_info', N'wait_info_external') AND e.x.value('(event/data[@name=\"duration\"]/value)[1]', 'bigint') >= 1000 AND e.x.value('(event/@timestamp)[1]', 'datetime2(7)') <= '$LW'")
  want "C3: the stored waits equal sa's read of the file" "$(q "select count(*) from pgvigil.mssql_xe_waits where instance_id = $I")" "$HAND"
  N=$(q "select coalesce(sum(events), 0) from pgvigil.mssql_xe_warning_hours where instance_id = $I and event_name = 'sort_warning'")
  [ "$N" -ge 1 ] && pass "C4: sort_warning counted ($N)" || bad "C4: sort_warning counted $N"
  for e in missing_join_predicate plan_affecting_convert; do
    N=$(q "select coalesce(sum(events), 0) from pgvigil.mssql_xe_warning_hours where instance_id = $I and event_name = '$e'")
    HN=$(handwarn "$e")
    [ "$N" = "$HN" ] && [ "$HN" -ge 1 ] 2>/dev/null && pass "C5: $e stored as sa's read of the file has it ($N)" || bad "C5: $e stored [$N], sa's read [$HN], want equal and at least 1"
  done
  D=$(q "select coalesce(sum(delta), 0) from pgvigil.mssql_xe_warning_counts where instance_id = $I and event_name = 'page_split'")
  [ "$D" -ge 1000 ] && pass "C6: page_split between the two reads ($D)" || bad "C6: page_split between the two reads: $D"
  between "C7: the 6 s procedure" "$(q "select max(duration_ms) from pgvigil.mssql_xe_modules where instance_id = $I and object_name = 'p_slow'")" 5500 8000
  want "C7: not the 50 ms one, not sp_pgvproof" "$(q "select count(*) from pgvigil.mssql_xe_modules where instance_id = $I and object_name in ('p_fast', 'sp_pgvproof')")" "0"
  want "C8: every capture running" "$(q "select string_agg(capture || '=' || state, ' ' order by capture) from pgvigil.mssql_xe_capture_state where instance_id = $I")" \
    "modules=running waits=running warncounts=running warnings=running"
fi

if has D; then
  echo "--- D. the settings"
  I=$(iid)
  cfg() { q "select pgvigil.import_mssql_xe_capture_config(now(), '$1'::jsonb)->>'outcome'"; }
  want "D1: wait_ms 5000 at the instance" "$(cfg '{"ui_user": "proof", "op": "add", "scope": "instance", "instance_name": "xc", "key": "wait_ms", "value": "5000"}')" "done"
  BEFORE=$(q "select count(*) from pgvigil.mssql_xe_waits where instance_id = $I")
  sqbg "BEGIN TRAN; UPDATE dbo.t SET v = v + 1 WHERE id = 2; WAITFOR DELAY '00:00:03'; ROLLBACK;"
  sleep 0.5
  sq "UPDATE dbo.t SET v = v + 1 WHERE id = (SELECT 2);" xcdb >/dev/null
  sleep 6
  collect mssql_xe_captures
  want "D2: the new 3 s wait not stored (the read's filter)" "$(q "select count(*) from pgvigil.mssql_xe_waits where instance_id = $I")" "$BEFORE"
  want "D3: the refusals, each logged" "$(cfg '{"ui_user": "proof", "op": "add", "scope": "fleet", "key": "wait_ms", "value": "50"}') $(cfg '{"ui_user": "proof", "op": "add", "scope": "fleet", "key": "proc_exclude", "value": "[\"nodot\"]"}')|$(q "select count(*) from pgvigil.mssql_xe_capture_config_log where outcome = 'refused'")" "refused refused|2"
  want "D4: the settings in force" "$(q "select pgvigil.mssql_xe_capture_settings_json($I)->>'wait_ms'")" "5000"
fi

if has G; then
  echo "--- G. the rest of the design's provocations"
  I=$(iid)
  sq "ALTER DATABASE xcdb SET AUTO_CREATE_STATISTICS OFF;" >/dev/null || bad "G: auto create statistics off"
  # G1 hash spills; G2 a column with no statistics; G3 a filtered index a parameterised query cannot use
  sq "/* G1a */ SELECT COUNT(*) FROM (SELECT v % 150000 AS g, COUNT(*) AS n FROM dbo.t GROUP BY v % 150000) x OPTION (HASH GROUP, MAX_GRANT_PERCENT = 0, USE HINT('DISALLOW_BATCH_MODE'));" xcdb >/dev/null
  sq "/* G1b */ SELECT MAX(a.pad) FROM dbo.t a JOIN dbo.t b ON a.v = b.v OPTION (HASH JOIN, FORCE ORDER, MAX_GRANT_PERCENT = 0, USE HINT('DISALLOW_BATCH_MODE'));" xcdb >/dev/null
  sq "CREATE TABLE dbo.hw (id int NOT NULL, k int NOT NULL, pad char(2000) NOT NULL DEFAULT 'x'); INSERT dbo.hw (id, k) SELECT TOP (10000) id, 0 FROM dbo.t;" xcdb >/dev/null || bad "G1: dbo.hw"
  T0=$SECONDS
  sq "/* G1c */ SELECT COUNT(*) FROM dbo.hw a JOIN dbo.hw b ON a.k = b.k AND b.id < a.id - 1000000 OPTION (HASH JOIN, FORCE ORDER, MAX_GRANT_PERCENT = 0, USE HINT('DISALLOW_BATCH_MODE'));" xcdb >/dev/null
  echo "G1 info: G1c ran $((SECONDS - T0)) s"
  sq "SELECT COUNT(*) FROM dbo.g WHERE pad = 'y';" xcdb >/dev/null
  sq "CREATE INDEX vc_f ON dbo.vc (code) WHERE id > 100;" xcdb >/dev/null || bad "G3: the filtered index"
  sq "EXEC sp_executesql N'SELECT code FROM dbo.vc WHERE id > @p AND code = ''1''', N'@p int', @p = 200;" xcdb >/dev/null
  # G5 the Agent job: Agent starts a little after the engine
  for _ in $(seq 1 60); do [ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%'")" -gt 0 ] 2>/dev/null && break; sleep 1; done
  sqs >/dev/null 2>&1 <<'SQL'
EXEC msdb.dbo.sp_add_job @job_name = N'pgv_proof_job';
EXEC msdb.dbo.sp_add_jobstep @job_name = N'pgv_proof_job', @step_name = N's1', @subsystem = N'TSQL', @database_name = N'xcdb', @command = N'EXEC dbo.p_slow;';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'pgv_proof_job';
EXEC msdb.dbo.sp_start_job @job_name = N'pgv_proof_job';
SQL
  JOBOK=0
  for _ in $(seq 1 40); do
    JOBOK=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'pgv_proof_job' AND h.step_id = 0 AND h.run_status = 1")
    [ "$JOBOK" = 1 ] && break; sleep 1
  done
  sleep 6
  collect mssql_xe_captures
  # evidence for G1, never graded: the event as the server documents it, each hash statement's spills, the file's rows
  echo "G1 info: hash_warning is: $(sq "SELECT LEFT(description, 300) FROM sys.dm_xe_objects WHERE name = N'hash_warning' AND object_type = N'event'")"
  echo "G1 info: its data columns: $(sq "SELECT STRING_AGG(name, N',') FROM sys.dm_xe_object_columns WHERE object_name = N'hash_warning' AND column_type = N'data'")"
  echo "G1 info: spills by statement: $(sq "SELECT SUBSTRING(t.text, CHARINDEX(N'/* G1', t.text), 9) + N'=' + CAST(SUM(qs.total_spills) AS nvarchar(20)) FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t WHERE t.text LIKE N'%/* G1_ */%' AND t.text NOT LIKE N'%dm_exec_query_stats%' GROUP BY SUBSTRING(t.text, CHARINDEX(N'/* G1', t.text), 9)" | tr '\n' ' ')"
  echo "G1 info: hash_warning rows in the file by type and level: $(sq "SELECT ISNULL(e.x.value('(event/data[@name=\"hash_warning_type\"]/text)[1]', 'nvarchar(40)'), N'?') + N' level ' + ISNULL(e.x.value('(event/data[@name=\"recursion_level\"]/value)[1]', 'nvarchar(10)'), N'?') FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log/pgvigil_cap_warnings*.xel', NULL, NULL, NULL) f CROSS APPLY (SELECT CAST(f.event_data AS xml) x) e WHERE f.object_name = N'hash_warning'" | sort | uniq -c | tr '\n' ' ')"
  for e in hash_warning missing_column_statistics unmatched_filtered_indexes; do
    N=$(storedwarn $e); HN=$(handwarn $e)
    [ "$N" = "$HN" ] && [ "$HN" -ge 1 ] 2>/dev/null && pass "G1-G3: $e stored as sa's read has it ($N)" || bad "G1-G3: $e stored [$N], sa's read [$HN], want equal and at least 1"
  done
  CM=$(q "select coalesce(sum(delta), 0) from pgvigil.mssql_xe_warning_counts where instance_id = $I and event_name = 'sp_cache_miss'")
  [ "$CM" -ge 20 ] 2>/dev/null && pass "G4: sp_cache_miss between the reads ($CM)" || bad "G4: sp_cache_miss between the reads: $CM"
  handmod() { sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log/pgvigil_cap_modules*.xel', NULL, NULL, NULL) f CROSS APPLY (SELECT CAST(f.event_data AS xml) x) e WHERE f.object_name = N'module_end' AND e.x.value('(event/data[@name=\"object_name\"]/value)[1]', 'nvarchar(256)') = N'p_slow'"; }
  storedmod() { q "select count(*) from pgvigil.mssql_xe_modules where instance_id = $I and object_name = 'p_slow'"; }
  want "G5: the job succeeded | p_slow runs in the file | stored" "$JOBOK|$(handmod)|$(storedmod)" "1|1|1"
  # G6 every warning event: the store against sa's read of the file
  NONE=""
  for e in sort_warning hash_warning exchange_spill missing_join_predicate plan_affecting_convert missing_column_statistics \
           unmatched_filtered_indexes optimizer_timeout additional_memory_grant execution_warning long_io_detected; do
    N=$(storedwarn $e); HN=$(handwarn $e)
    [ "$N" = "$HN" ] || bad "G6: $e stored [$N], sa's read of the file [$HN]"
    [ "$HN" = 0 ] && NONE="$NONE $e"
  done
  pass "G6: every warning event stored as the file has it (not raised here:${NONE:- none})"
  # G7 the read applies the app list: SQLCMD added at the instance, p_slow from sqlcmd again
  APPS=$(q "select (pgvigil.mssql_xe_capture_settings_json($I)->'app_exclude') || '[\"SQLCMD\"]'::jsonb")
  want "G7: SQLCMD added to app_exclude at the instance" "$(q "select pgvigil.import_mssql_xe_capture_config(now(), jsonb_build_object('ui_user', 'proof', 'op', 'add', 'scope', 'instance', 'instance_name', 'xc', 'key', 'app_exclude', 'value', '$APPS'))->>'outcome'")" "done"
  sq "EXEC dbo.p_slow;" xcdb >/dev/null
  sleep 6
  collect mssql_xe_captures
  want "G7: p_slow runs in the file | stored" "$(handmod)|$(storedmod)" "2|1"
  # G8 imported rows: events a container does not raise on demand
  T=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  PAY="["
  for e in long_io_detected additional_memory_grant execution_warning optimizer_timeout exchange_spill; do
    PAY="$PAY{\"kind\": \"xwarn\", \"event_at\": \"$T\", \"event_name\": \"$e\", \"session_name\": \"imported\", \"database_name\": \"imported\", \"program_name\": \"imported\", \"detail\": \"imported by the proof\"},"
  done
  PAY="$PAY{\"kind\": \"xwait\", \"event_at\": \"$T\", \"event_key\": \"imported-1\", \"event_name\": \"wait_info_external\", \"session_name\": \"imported\", \"wait_type\": \"PREEMPTIVE_OS_WRITEFILE\", \"category\": \"Preemptive\", \"duration_ms\": 7000, \"database_name\": \"imported\", \"program_name\": \"imported\"}]"
  q "select pgvigil.import_mssql_xe_captures($I, now(), \$p\$$PAY\$p\$::jsonb)" >/dev/null || bad "G8: the import"
  want "G8: the imported warnings, one each" "$(q "select string_agg(event_name || '=' || events, ' ' order by event_name) from pgvigil.mssql_xe_warning_hours where instance_id = $I and database_name = 'imported'")" \
    "additional_memory_grant=1 exchange_spill=1 execution_warning=1 long_io_detected=1 optimizer_timeout=1"
  want "G8: the imported external wait" "$(q "select event_name || '/' || category || '/' || duration_ms from pgvigil.mssql_xe_waits where instance_id = $I and event_key = 'imported-1'")" "wait_info_external/Preemptive/7000"
fi

if has E; then
  echo "--- E. the drop script"
  sq "CREATE EVENT SESSION other_waits ON SERVER ADD EVENT sqlos.wait_info ADD TARGET package0.ring_buffer; ALTER EVENT SESSION other_waits ON SERVER STATE = START;" >/dev/null || bad "E: other_waits"
  "$BIN" mssql-xe -print -drop -captures all -install-id cap > "$TMPD/drop.sql" || die "E: the drop script"
  sqs < "$TMPD/drop.sql" > /dev/null 2>&1
  want "E1: the four dropped, other_waits running" "$(sq "SELECT COUNT(*) FROM sys.server_event_sessions WHERE name LIKE N'pgvigil[_]cap[_]%'")|$(sq "SELECT COUNT(*) FROM sys.dm_xe_sessions WHERE name = N'other_waits'")" "0|1"
  want "E2: the drop script says the files stay" "$(grep -c 'The event files they wrote stay' "$TMPD/drop.sql")" "1"
fi

if has F; then
  echo "--- F. the slow capture's trend"
  "$BIN" mssql-xe -print -install-id cap > "$TMPD/four.sql" || die "F: mssql-xe -print"
  sqs < "$TMPD/four.sql" > /dev/null 2>&1
  for login in trend_a trend_a trend_a trend_b trend_b; do
    (export SQLCMDPASSWORD="$LPW"; docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U $login -C -Q "WAITFOR DELAY '00:00:01.200';" > /dev/null 2>&1)
  done
  sleep 6
  collect mssql_xe
  I=$(iid)
  want "F1: the trend by login" "$(q "select string_agg(grp || '=' || events, ' ' order by grp) from pgvigil.mssql_xe_slow_trend($I, now() - interval '1 hour', now(), 'hour', 'login') where grp like 'trend_%'")" "trend_a=3 trend_b=2"
fi

if has S; then
  echo "--- S. the API's doors and parts, the page in both themes"
  XC=$(iid)
  UIUSER=xcproof; UIPW=$(pw)
  PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" $UIUSER >/dev/null 2>&1 || die "S: user add"
  freeport() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
  P1=$(freeport); P2=$(freeport); U="http://127.0.0.1:$P1"; U2="http://127.0.0.1:$P2"
  "$BIN" serve -config "$CFG" -listen "127.0.0.1:$P1" > "$TMPD/serve.log" 2>&1 & SRV=$!
  "$BIN" serve -config "$CFG" -listen "127.0.0.1:$P2" -no-login > "$TMPD/serve2.log" 2>&1 & SRV2=$!
  for url in "$U" "$U2"; do for _ in $(seq 1 60); do curl -sf -o /dev/null "$url/" && break; sleep 0.5; done; done
  # an instance's row is made when a collect first connects (EnsureInstanceEngine): one read registers xc_lost
  "$BIN" collect -config "$CFG" -once mssql_xe_captures -instance xc_lost > "$TMPD/c.out" 2>&1 || bad "S: collect -once on xc_lost: $(tail -3 "$TMPD/c.out")"
  LOST=$(q "select instance_id from pgvigil.instances where name = 'xc_lost'")
  [ -n "$LOST" ] || die "S: the instance xc_lost has no row"
  # two reads of each ring: the second found 30 new events where the ring took 80 more: 50 lost (0065's arithmetic)
  for c in deadlocks blocked; do
    q "select pgvigil.import_mssql_xe($LOST, now() - interval '3 minutes', '[{\"kind\":\"state\",\"capture\":\"$c\",\"state\":\"running\",\"source\":\"product\",\"session_name\":\"pgvigil_cap_$c\",\"target\":\"ring_buffer\",\"total_processed\":100,\"new_events\":100,\"dropped_events\":0}]'::jsonb)" >/dev/null || bad "S: the state import 1 ($c)"
    q "select pgvigil.import_mssql_xe($LOST, now() - interval '1 minute', '[{\"kind\":\"state\",\"capture\":\"$c\",\"state\":\"running\",\"source\":\"product\",\"session_name\":\"pgvigil_cap_$c\",\"target\":\"ring_buffer\",\"total_processed\":180,\"new_events\":30,\"dropped_events\":0}]'::jsonb)" >/dev/null || bad "S: the state import 2 ($c)"
  done
  JAR=$TMPD/jar; code() { curl -s -o "$TMPD/body" -w '%{http_code}' "$@"; }
  # the UI password goes in a file curl reads, never on the command line
  umask 077; printf '{"username": "%s", "password": "%s"}' "$UIUSER" "$UIPW" > "$TMPD/login.json"; umask 022
  curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d @"$TMPD/login.json" "$U/api/login" > /dev/null
  COOKIE=$(awk '$6 == "pgvigil_session" {print $7}' "$JAR")
  [ -n "$COOKIE" ] || die "S: no session cookie"
  body() { python3 -c "import json,sys
d = json.load(open(sys.argv[1]))
$1" "$TMPD/body"; }
  tbl='def rows(t): return [dict(zip(t["columns"], r)) for r in (t or {}).get("rows") or []] if t else []'
  post() { code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$1/api/mssql/xecaptures/config"; }
  G="$U/api/mssql/xecaptures?instance=$XC"
  want "S1: signed in, GET 200 and writable" "$(code -b "$JAR" "$G&part=state")|$(body 'print(d.get("writable"))')" "200|True"
  want "S2: the script with the settings in force, text none" "$(code -b "$JAR" "$G&part=script&install_id=cap&text=none")|$(body 'sc = d.get("script") or ""; print("pgvigil_cap_waits" in sc, "[opcode]=(1) AND [duration]>=(5000)" in sc, "sqlserver.sql_text" in sc)')" "200|True True False"
  want "S3: the waits by type have LCK_M_X" "$(code -b "$JAR" "$G&part=waits_by_type")|$(body "$tbl
print(any(r.get('wait_type') == 'LCK_M_X' for r in rows(d.get('waits_by_type'))))")" "200|True"
  want "S4: module_ms 7000 at the instance through the door" "$(post "$U" "{\"op\":\"add\",\"scope\":\"instance\",\"instance_id\":$XC,\"key\":\"module_ms\",\"value\":\"7000\"}")|$(body 'print(d.get("outcome"))')|$(q "select pgvigil.mssql_xe_capture_settings_json($XC)->>'module_ms'")" "200|done|7000"
  CID=$(body 'print(d.get("config_id"))')
  want "S4: its end" "$(post "$U" "{\"op\":\"end\",\"config_id\":$CID}")|$(q "select pgvigil.mssql_xe_capture_settings_json($XC)->>'module_ms'")" "200|5000"
  want "S5: no session 401, no header 403" "$(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d '{}' "$U/api/mssql/xecaptures/config") $(code -b "$JAR" -H 'Content-Type: application/json' -d '{}' "$U/api/mssql/xecaptures/config")" "401 403"
  want "S6: -no-login: read-only with its reason, a write 403" "$(code "$U2/api/mssql/xecaptures?instance=$XC&part=state")|$(body 'print(d.get("writable"), "no-login" in (d.get("reason") or ""))')|$(post "$U2" "{\"op\":\"add\",\"scope\":\"fleet\",\"key\":\"module_ms\",\"value\":\"7000\"}")" "200|False True|403"
  want "S7: the loss on xc_lost" "$(code -b "$JAR" "$U/api/mssql/xecaptures?instance=$LOST&part=lost")|$(body "$tbl
print(' '.join('%s=%s' % (r['capture'], r['lost_events']) for r in rows(d.get('lost'))))")" "200|blocked=50 deadlocks=50"
  want "S8: a bad by, a bad plan hash" "$(code -b "$JAR" "$G&part=trend&by=nobody") $(code -b "$JAR" "$G&part=plan_text&plan_hash=0x12")" "400 400"
  # S9 the page in a headless Chromium, both themes, with axe-core 4.14.0 (WCAG 2.1 A / AA) and the off-control rule
  (cd "$TMPD" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || die "S: npm install axe-core"
  CDP=$(freeport)
  chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu about:blank > "$TMPD/chrome.log" 2>&1 & CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  cat > "$TMPD/xc-page.mjs" <<'JS'
const [port, base, axePath, xc, lost, cookie] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const head = (sel, start) => `[...document.querySelectorAll('main ${sel}')].some(h => h.textContent.startsWith(${JSON.stringify(start)}))`;
const tabs = [
  { inst: xc, tab: 'mssql_xewaits', ready: head('h2', 'Waits over the threshold') },
  { inst: xc, tab: 'mssql_xewarnings', ready: head('h2', 'Query warnings') },
  { inst: xc, tab: 'mssql_xemodules', ready: head('h2', 'Procedure runs') },
  { inst: xc, tab: 'mssql_xecaptures', ready: head('h3', 'Settings') },
  { inst: xc, tab: 'mssql_slow', ready: head('h3', 'The slow workload over time') + ` && !!document.querySelector('main svg, main table')` },
  { inst: lost, tab: 'mssql_deadlocks', ready: head('h2', 'Deadlocks') },
  { inst: lost, tab: 'mssql_blocked', ready: head('h2', 'Blocked reports') },
];
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
if (cookie) await cmd('Network.setCookie', { name: 'pgvigil_session', value: cookie, url: base });
const out = [];
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: base }); await sleep(800);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const t of tabs) {
    await cmd('Page.navigate', { url: base + '#/' + t.tab + '?i=' + t.inst });
    let rendered = false;
    for (let i = 0; i < 80 && !rendered; i++) { await sleep(250); rendered = await ev(t.ready); }
    await sleep(600);
    const page = await ev(`(() => {
      const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
      const ctl = [...document.querySelectorAll('main button, main input, main select, main textarea')].filter(e => (e.disabled || e.getAttribute('aria-disabled') === 'true') && vis(e));
      const said = x => { const t = x.textContent.trim(); return t.length > 0 && !/:\\s*\\.?$/.test(t); };
      const bad = ctl.filter(e => !(e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).some(i => { const x = document.getElementById(i); return vis(x) && said(x); }));
      const live = [...document.querySelectorAll('main button')].filter(b => b.textContent === 'Save' && !b.disabled && b.getAttribute('aria-disabled') !== 'true').length;
      const lostLine = [...document.querySelectorAll('main p')].some(p => /events lost/.test(p.textContent) && /50 event/.test(p.textContent));
      return { off: ctl.length, offBad: bad.length, live, lostLine, error: !!document.querySelector('main .error') };
    })()`);
    await ev(axeSrc + '; "axe loaded"');
    const res = await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, nodes: v.nodes.length, first: v.nodes[0]?.html.slice(0, 120) }))))`, true);
    const v = JSON.parse(res);
    out.push({ theme, tab: t.tab, rendered, ...page, nodes: v.reduce((a, x) => a + x.nodes, 0), violations: v });
  }
}
console.log(JSON.stringify(out));
ws.close();
JS
  page() { node "$TMPD/xc-page.mjs" "$CDP" "$1/" "$TMPD/node_modules/axe-core/axe.min.js" "$XC" "$LOST" "${2:-}" 2> "$TMPD/node.err" || echo "[]"; }
  # one word per tab and theme: ok, or what is wrong
  grade() { python3 -c 'import json,sys
r = json.loads(sys.argv[1]); mode = sys.argv[2]; out = []
for x in r:
    w = []
    if not x["rendered"]: w.append("not rendered")
    if x["error"]: w.append("error box")
    if x["nodes"]: w.append("axe %d" % x["nodes"])
    if x["offBad"]: w.append("offBad %d" % x["offBad"])
    if x["tab"] == "mssql_xecaptures":
        if mode == "nologin" and not (x["off"] > 0 and x["live"] == 0): w.append("off %d live %d" % (x["off"], x["live"]))
        if mode == "login" and x["live"] == 0: w.append("no live Save")
    if x["tab"] in ("mssql_deadlocks", "mssql_blocked") and not x["lostLine"]: w.append("no lost line")
    out.append("%s/%s=%s" % (x["theme"], x["tab"], ",".join(w) or "ok"))
print(" ".join(out) if r else "no page result")' "$1" "$2"; }
  allok="light/mssql_xewaits=ok light/mssql_xewarnings=ok light/mssql_xemodules=ok light/mssql_xecaptures=ok light/mssql_slow=ok light/mssql_deadlocks=ok light/mssql_blocked=ok dark/mssql_xewaits=ok dark/mssql_xewarnings=ok dark/mssql_xemodules=ok dark/mssql_xecaptures=ok dark/mssql_slow=ok dark/mssql_deadlocks=ok dark/mssql_blocked=ok"
  NOLOGIN=$(page "$U2"); LOGIN=$(page "$U" "$COOKIE")
  want "S9: -no-login - every tab renders, the captures tab's controls off with their reason, the lost lines, 0 axe nodes" "$(grade "$NOLOGIN" nologin)" "$allok"
  want "S9: signed in - the same, the Save buttons live" "$(grade "$LOGIN" login)" "$allok"
  for R in "$NOLOGIN" "$LOGIN"; do echo "$R" | python3 -c 'import json,sys; [print("  axe %s %s: %s" % (x["theme"], x["tab"], v)) for x in json.load(sys.stdin) for v in x["violations"]]' 2>/dev/null; done
  [ -s "$TMPD/node.err" ] && echo "  node: $(tail -3 "$TMPD/node.err")"
fi

if [ "$FAILS" = 0 ]; then echo "PROOF OK: proof-mssql-xe-captures ($PARTS)"; exit 0; fi
echo "PROOF FAILED: $FAILS check(s)"; exit 1
