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
#   PGVIGIL_PARTS  the parts to run (default MABCDEF)
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
#     C1 a wait LCK_M_X of 2,500 to 6,000 ms stored, category 'Locking'; C2 no WAITFOR wait stored; C3 (sa reads the files in /var/opt/mssql/log/, the Linux image's log folder) the stored waits equal
#     sa's count of wait_info events over 1,000 ms in the waits session's file (the same events, after the read's
#     filter); C4 sort_warning counted at least once; C5 missing_join_predicate and plan_affecting_convert each counted at
#     least once, or written down as the server's answer if it raised none; C6 page_split's difference between the two
#     reads at least 1,000; C7 the 6 s procedure stored with 5,500 to 8,000 ms, the 50 ms one not, sp_pgvproof not;
#     C8 every capture's state 'running'.
#  D. the settings: wait_ms 5000 at the instance; a new lock wait of about 3 s is then not stored (the read's filter);
#     the script the GET part writes carries 'waits over 5000 ms' and '[duration]>=(5000)'; wait_ms 50 refused, a
#     proc_exclude entry without a dot refused, each with its log row.
#  E. the drop script drops the four sessions and leaves a session of another name (other_waits) running.
#  F. the trend: login trend_a runs 3 batches of WAITFOR 1.2 s and trend_b 2, under pgvigil's slow session (the
#     four-session script); mssql_xe_slow_trend by login counts 3 and 2 completions for them.
set -u
PARTS=${PGVIGIL_PARTS:-MABCDEF}
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
MADE_DB=
cleanup() {
  rc=$?
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
go build -o "$TMPD/pgvigil" ./cmd/pgvigil || die "go build"
BIN=$TMPD/pgvigil
pw() { printf 'Px9%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); LPW=$(pw)
export SQLCMDPASSWORD="$SAPW"
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nMSSQL_MEMORY_LIMIT_MB=2048\n' "$SAPW" > "$TMPD/sa.env"
docker run -d --name "$SQL" --memory 3g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG" >/dev/null || die "docker run"
PORT=$(docker port "$SQL" 1433 | head -1 | sed 's/.*://')
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
docker exec "$SQL" test -x "$SQLCMD" || SQLCMD=/opt/mssql-tools/bin/sqlcmd
sq() { docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -b -I -W -h -1 -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
# the newest event a capture's stored cursor has read (the hand reads count no event past it)
lastread() { q "select to_char(last_event_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS') from pgvigil.mssql_cursor where instance_id = $(iid) and source = '$1'"; }
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
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: xc\n    engine: sqlserver\n    dsn: env:XC_DSN\n' > "$CFG"
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
  want "A2: no event left out on this version" "$(grep -c 'left out' "$TMPD/cap.out")" "0"
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
  between "C1: a lock wait of about 3 s" "$(q "select max(duration_ms) from pgvigil.mssql_xe_waits where instance_id = $I and wait_type = 'LCK_M_X'")" 2500 6000
  want "C1: its category" "$(q "select category from pgvigil.mssql_xe_waits where instance_id = $I and wait_type = 'LCK_M_X' limit 1")" "Locking"
  want "C2: no WAITFOR stored" "$(q "select count(*) from pgvigil.mssql_xe_waits where instance_id = $I and wait_type = 'WAITFOR'")" "0"
  LW=$(lastread pgvigil_cap_waits)
  HAND=$(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log/pgvigil_cap_waits*.xel', NULL, NULL, NULL) f CROSS APPLY (SELECT CAST(f.event_data AS xml) x) e WHERE f.object_name IN (N'wait_info', N'wait_info_external') AND e.x.value('(event/data[@name=\"duration\"]/value)[1]', 'bigint') >= 1000 AND f.timestamp_utc <= '$LW'")
  want "C3: the stored waits equal sa's read of the file" "$(q "select count(*) from pgvigil.mssql_xe_waits where instance_id = $I")" "$HAND"
  N=$(q "select coalesce(sum(events), 0) from pgvigil.mssql_xe_warning_hours where instance_id = $I and event_name = 'sort_warning'")
  [ "$N" -ge 1 ] && pass "C4: sort_warning counted ($N)" || bad "C4: sort_warning counted $N"
  for e in missing_join_predicate plan_affecting_convert; do
    N=$(q "select coalesce(sum(events), 0) from pgvigil.mssql_xe_warning_hours where instance_id = $I and event_name = '$e'")
    HN=$(sq "SELECT COUNT(*) FROM sys.fn_xe_file_target_read_file(N'/var/opt/mssql/log/pgvigil_cap_warnings*.xel', NULL, NULL, NULL) WHERE object_name = N'$e' AND timestamp_utc <= '$(lastread pgvigil_cap_warnings)'")
    want "C5: $e stored as sa's read of the file has it" "$N" "$HN"
    [ "$HN" -ge 1 ] || echo "  (the server raised no $e for the proof's statement: written down)"
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

if [ "$FAILS" = 0 ]; then echo "PROOF OK: proof-mssql-xe-captures ($PARTS)"; exit 0; fi
echo "PROOF FAILED: $FAILS check(s)"; exit 1
