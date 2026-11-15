#!/usr/bin/env bash
# Proof of task 414 (B23): indexes and statistics on demand. One SQL Server container per run (MSSQL_IMAGE; the box job
# runs it once per version: 2017, 2019, 2022, 2025), a repository database of its own, pgvigil built from this tree.
# Needs: docker, go, psql, curl, python3, and:
#   ADMIN_DSN       a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                   user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   MSSQL_IMAGE     the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_PARTS   the parts to run (default every part this file has: ABCDEFGHI)
#   PGVIGIL_WIRING  1 (default) applies scripts/proof-mssql-index-depth-wiring.patch (config, serve, the door set,
#                   web.go: the lead's files) to this copy when the tree has the handlers and web.go lacks their routes.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
#
# Expected (written before the first run):
#  A. the container: the monitor login (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE, an msdb reader);
#     a statistics-only login (a user in pgvix with SELECT on schema dbo, nothing else); database pgvix with dbo.t (a
#     clustered key, ix_a, ix_b, 20,000 rows), dbo.frag (a NEWID() clustered key, random inserts), dbo.heap (a heap of
#     20,000+ pages), dbo.parent / dbo.child (a foreign key), dbo.t_cl, dbo.types (datetime2, varbinary keys), dbo.cs (a
#     nonclustered columnstore), dbo.x (an XML index), dbo.g (a spatial index), dbo.f1-f3; instances of one server:
#     ixon (histogram + stats_dsn + index_fragmentation, query_text full), ixdef (nothing set), ixnorm (histogram, query_text
#     normalized), ixread (histogram, no stats_dsn: the read login), ixsa (histogram, stats_dsn = sa).
#  B. index usage kept per read (SQLWATCH PBI#12, F5, F10, F17):
#     B1 read 1 of mssql_indexes: one usage row per index of pgvix, each a baseline (deltas NULL), index_name kept;
#     B2 a known workload (n seeks on ix_a, m scans of t's clustered index, k lookups, u updates), read 2: the rows of the
#        indexes it touched carry deltas equal to the hand reads of sys.dm_db_index_usage_stats before and after; ix_b
#        (untouched) has no row at read 2;
#     B3 pgvix taken OFFLINE and ONLINE, a workload, read 3: the rows carry reset = true and the whole count as the delta;
#     B4 an AUTO_CLOSE database (pgvac): reads 1 and 2 import without an error, its usage_since NULL, a moved index kept;
#     B5 a read across a month boundary (import_mssql_indexes called with next month's time on a copy of read 2's
#        payload): the next month's partition made, its rows stored, the inventory imported;
#     B6 the measure: bytes per usage row (pg_column_size, mean) and the import time of a 20,000-index batch with the
#        history and through import_mssql_indexes_0092 alone, printed; the history under 3 times the old import's time.
#     Red on f8e89d2: no table pgvigil.mssql_index_usage_read.
#  C. missing-index requests kept per read (SQLWATCH PBI#13, F11):
#     C1 a query asking for an index on dbo.t (c = @v) run 5 times between reads 1 and 2: two rows of one identity, seeks
#        rising by 5 (delta 5); GET /api/mssql/indexes/depth's impact series for it holds those two points;
#     C2 the pair equality (c) / no inequality and no equality / inequality (c): two identities;
#     C3 the top 10 by benefit and the scatter's rows come in the same reply (part 'missing_top').
#     Red on f8e89d2: no table pgvigil.mssql_missing_index_read.
#  D. disabled indexes (dbachecks Database#16, F9; Learn: Disable Indexes and Constraints):
#     D1 ix_b disabled: the finding 'disabled indexes' (info) names it, the inventory row is_disabled;
#     D2 t_cl's clustered index disabled: 'a disabled index that blocks its table' (warning) with ALTER INDEX ALL ON
#        [dbo].[t_cl] REBUILD; parent's primary key disabled: the same warning, naming the foreign keys to check again
#        (ALTER TABLE ... WITH CHECK CHECK CONSTRAINT);
#     D3 all rebuilt (and the foreign key checked again), read again: no disabled finding.
#  E. untrusted keys and constraints (dbachecks Database#41, #42, F14):
#     E1 child's foreign key and a check constraint NOCHECK, then CHECK without WITH CHECK, collect mssql_constraints: both
#        named (the finding 'untrusted foreign keys and check constraints', info, and the grid);
#     E2 a NOT FOR REPLICATION foreign key left untrusted and a disabled check constraint: neither named, the disabled one
#        counted apart;
#     E3 WITH CHECK CHECK CONSTRAINT on both: cleared on the next read.
#     Red on f8e89d2: collect refuses mssql_constraints (unknown collection).
#  F. a histogram on demand (SQLWATCH COL#22, F2, F3, F8, F12, F13, F15):
#     F1 ixon (the statistics-only login), ix_a's statistic: the steps equal DBCC SHOW_STATISTICS ... WITH HISTOGRAM step
#        by step (RANGE_HI_KEY, EQ_ROWS, RANGE_ROWS, DISTINCT_RANGE_ROWS); the reply's Cache-Control no-store; its
#        custom_report_log row (op histogram, done, the user, the statistic, the step count) written, holding no key value;
#        serve's log line names the statistic and the step count and no key value;
#     F2 the datetime2 and the varbinary statistic: each key shown as the hand read's CONVERT (style 126 / 1);
#     F3 ixdef: off, 'shows the column's real values; an admin turns it on'; ixnorm: off naming the policy; nothing sent
#        (no login of the statistics login counted);
#     F4 ixread (the read login, no SELECT): the server's own words or the 'no step was readable' words (measured, printed);
#        ixsa: refused (sysadmin);
#     F5 the columnstore, XML and spatial indexes' rows: off with the reason (no histogram), nothing sent;
#     F6 a GET: 405; a POST without X-Pgvigil: 403; a serve with -no-login: off, 'needs a signed-in user', nothing sent;
#     F7 nothing written to the repository but the audit rows (row counts of every pgvigil table before and after).
#     Red on f8e89d2: no route (POST /api/mssql/stats/histogram is not JSON with steps).
#  G. fragmentation as a job (SQLWATCH REP#1, F1, F4, F6, F7, O2):
#     G1 the cost reply for pgvix: the heap size equals the hand read of sys.dm_db_partition_stats (index_id 0), with the
#        words 'reads every index and heap of the database; a heap's data pages are read in full even in LIMITED';
#     G2 ixon LIMITED: the POST answers an id at once; the poll ends 'done'; dbo.frag's avg_fragmentation_in_percent equals
#        a hand read in LIMITED within 0.5 and is marked (> 30 %, > 1000 pages); the heap's page_count equals its data
#        pages; SAMPLED: the same check in SAMPLED;
#     G3 ixdef: off ('an admin turns it on'), no row;
#     G4 a read held up by three tables locked in turn (each under 30 s, the read over 75 s in all): the POST answered at
#        once, the job ends 'done' past 75 s (not tied to the request);
#     G5 a second start while one runs: refused 'one at a time'; Cancel: the row 'cancelled' and the job's session gone from
#        sys.dm_exec_requests within 5 s;
#     G6 a table under a held Sch-M lock: the read ends near 30 s with the lock-timeout words, the rows read before it kept,
#        the note naming where it stopped;
#     G7 serve killed during a held read, serve again: the row reads 'stopped' (no beat for 60 s) and a new start is taken;
#        the killed serve's session gone from the server;
#     G8 no collection names it (pgvigil collect refuses 'mssql_fragmentation').
#     NOT PROVEN: a secondary replica (no availability group in a container); the unit test covers the refusal.
#     Red on f8e89d2: no route.
#  H. purge and rights: H1 purge(30) through the wiring's line: an aged usage partition dropped, an aged missing row and
#     fragmentation read deleted, the rest kept; H2 pgvigil_reader may not EXECUTE mssql_index_depth_purge (NOT PROVEN
#     without the role).
#  I. the page: mssql_indexes.ts built; GET /api/mssql/indexes/depth's parts (usage, usage_series, missing_series,
#     missing_top, untrusted, constraint_dbs, switches, fragmentation) present for ixon; switches off for ixdef with the
#     words. (a11y and wording: the walks job, scripts/proof-a11y.sh and proof-wording.sh with the wiring applied.)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
PARTS=${PGVIGIL_PARTS:-ABCDEFGHI}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvix-sql-$SUF; LBL=pgvigil-proof=414
PGDB=pgv_ix_$SUF; MON=pgv_xmon_$SUF; STL=pgv_xstat_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
part() { [[ "$PARTS" == *"$1"* ]]; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; SRV2PID=; BG=()
SA_PW=$(pw); MON_PW=$(pw); STL_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$SRV2PID" ]] && kill "$SRV2PID" 2>/dev/null || true
  for p in "${BG[@]}"; do kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
if [[ "${PGVIGIL_WIRING:-1}" == 1 ]] && grep -q 'func (s \*Server) MSSQLIndexDepth' internal/web/*.go && ! grep -q 'mssql/indexes/depth' internal/web/web.go; then
  git apply scripts/proof-mssql-index-depth-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-mssql-index-depth-wiring.patch >/dev/null || fail "the wiring patch"
  echo "wiring applied to this copy (config.go, serve.go, web.go, report.go, 0110, 0190)"
fi
# the tree's own keys: a tree without 414 (the red base) gets a config without them, so each part is red on its own
NEWKEYS=0; grep -q 'yaml:"index_fragmentation"' internal/config/config.go && NEWKEYS=1

echo "== A. the container ($IMG_SQL) =="
docker run -d --name "$SQL" --label "$LBL" --memory 6g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
SQLCMD=
for _ in $(seq 1 60); do
  for c in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do docker exec "$SQL" test -x "$c" 2>/dev/null && SQLCMD=$c && break 2; done
  sleep 1
done
[[ -n "$SQLCMD" ]] || fail "A: no sqlcmd in the image"
TRUST=; [[ "$SQLCMD" == *tools18* ]] && TRUST=-C
# sq: T-SQL as sa (stdin; -I: QUOTED_IDENTIFIER ON); sqok: loud
sq() { printf 'SET NOCOUNT ON;\nGO\n%s\n' "$1" | timeout "${3:-180}" docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa '"$TRUST"' -b -I -W -h -1 -s "|" -l 60 -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" "${4:-180}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
up() { local r=; for _ in $(seq 1 150); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" master 15 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done
  docker logs --tail 40 "$SQL" >&2 2>&1 || true; fail "A: the SQL Server container did not come up in 300 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
VER=$(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON]; GRANT CONNECT ANY DATABASE TO [$MON];
  CREATE LOGIN [$STL] WITH PASSWORD = '$STL_PW', CHECK_POLICY = OFF;"
sqok "A: the monitor's msdb user" "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb
sqok "A: the databases" "CREATE DATABASE pgvix; ALTER DATABASE pgvix SET RECOVERY SIMPLE; CREATE DATABASE pgvac; ALTER DATABASE pgvac SET RECOVERY SIMPLE; ALTER DATABASE pgvac SET AUTO_CLOSE ON;"
sqok "A: the statistics login's user (SELECT on dbo, nothing else)" "CREATE USER [$STL] FOR LOGIN [$STL]; GRANT SELECT ON SCHEMA::dbo TO [$STL];" pgvix
sqok "A: dbo.t" "CREATE TABLE dbo.t (id int NOT NULL CONSTRAINT pk_t PRIMARY KEY CLUSTERED, a int NOT NULL, b int NOT NULL, c int NOT NULL, pad char(400) NOT NULL DEFAULT 'p');
  INSERT dbo.t (id, a, b, c) SELECT TOP (20000) n, n % 500, n % 300, n FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
  CREATE INDEX ix_a ON dbo.t (a) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
  CREATE INDEX ix_b ON dbo.t (b) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);" pgvix
sqok "A: dbo.frag (random keys)" "CREATE TABLE dbo.frag (id uniqueidentifier NOT NULL CONSTRAINT pk_frag PRIMARY KEY CLUSTERED, pad char(400) NOT NULL DEFAULT 'f');
  DECLARE @i int = 0; WHILE @i < 30 BEGIN INSERT dbo.frag (id) SELECT TOP (1000) NEWID() FROM sys.all_objects; SET @i += 1; END" pgvix 300
sqok "A: dbo.heap (20,000 pages)" "CREATE TABLE dbo.heap (id int NOT NULL, pad char(3000) NOT NULL DEFAULT 'h');
  INSERT dbo.heap (id) SELECT TOP (40000) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) FROM sys.all_objects x CROSS JOIN sys.all_objects y;" pgvix 300
sqok "A: keys and constraints" "CREATE TABLE dbo.parent (id int NOT NULL CONSTRAINT pk_parent PRIMARY KEY NONCLUSTERED, v int NOT NULL);
  INSERT dbo.parent (id, v) VALUES (1, 1), (2, 2);
  CREATE TABLE dbo.child (id int NOT NULL CONSTRAINT pk_child PRIMARY KEY, pid int NOT NULL CONSTRAINT fk_child_parent REFERENCES dbo.parent (id), CONSTRAINT ck_child CHECK (pid > 0));
  INSERT dbo.child (id, pid) VALUES (1, 1), (2, 2);
  CREATE TABLE dbo.child2 (id int NOT NULL CONSTRAINT pk_child2 PRIMARY KEY, pid int NOT NULL, CONSTRAINT ck_dis CHECK (id > 0));
  ALTER TABLE dbo.child2 ADD CONSTRAINT fk_child2_nfr FOREIGN KEY (pid) REFERENCES dbo.parent (id) NOT FOR REPLICATION;
  INSERT dbo.child2 (id, pid) VALUES (1, 1);
  CREATE TABLE dbo.t_cl (id int NOT NULL, v int NOT NULL); CREATE CLUSTERED INDEX cx_t_cl ON dbo.t_cl (id) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
  CREATE INDEX ix_t_cl_v ON dbo.t_cl (v) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
  INSERT dbo.t_cl (id, v) VALUES (1, 1), (2, 2);" pgvix
sqok "A: the key types (datetime2, varbinary, nvarchar) and the index types with no histogram" "CREATE TABLE dbo.types (id int NOT NULL PRIMARY KEY, d datetime2(7) NOT NULL, bin varbinary(16) NOT NULL, nm nvarchar(40) NOT NULL);
  INSERT dbo.types (id, d, bin, nm) SELECT TOP (3000) n, DATEADD(minute, n * 7, CAST('2026-01-01T00:00:00' AS datetime2(7))), CAST(n * 7919 AS varbinary(16)), N'pgvkey-' + CAST(n * 3 AS nvarchar(10))
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z;
  CREATE STATISTICS st_d ON dbo.types (d) WITH FULLSCAN; CREATE STATISTICS st_bin ON dbo.types (bin) WITH FULLSCAN; CREATE STATISTICS st_nm ON dbo.types (nm) WITH FULLSCAN;
  CREATE TABLE dbo.cs (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT dbo.cs (id, v) SELECT id, a FROM dbo.t;
  CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_cs ON dbo.cs (v);
  CREATE TABLE dbo.x (id int NOT NULL PRIMARY KEY, doc xml NULL); INSERT dbo.x (id, doc) VALUES (1, N'<a>1</a>'), (2, N'<a>2</a>');
  CREATE PRIMARY XML INDEX px_x ON dbo.x (doc);
  CREATE TABLE dbo.g (id int NOT NULL PRIMARY KEY, geo geography NULL); INSERT dbo.g (id, geo) VALUES (1, geography::Point(47.6, -122.3, 4326));
  CREATE SPATIAL INDEX sx_g ON dbo.g (geo);
  UPDATE STATISTICS dbo.t ix_a WITH FULLSCAN;" pgvix
sqok "A: f1-f3 (made last: the read reaches them last)" "CREATE TABLE dbo.f1 (id int NOT NULL); CREATE TABLE dbo.f2 (id int NOT NULL); CREATE TABLE dbo.f3 (id int NOT NULL);
  INSERT dbo.f1 VALUES (1); INSERT dbo.f2 VALUES (1); INSERT dbo.f3 VALUES (1);" pgvix
sqok "A: pgvac's table" "CREATE TABLE dbo.a (id int NOT NULL PRIMARY KEY, v int NOT NULL); INSERT dbo.a VALUES (1, 1), (2, 2);" pgvac
# the missing-index requests of C (equality c; inequality c), asked once before the first read
sqok "A: the missing-index requests" "SELECT id FROM dbo.t WHERE c = 17; SELECT id FROM dbo.t WHERE c > 19990;" pgvix

go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_X_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
export PGV_X_STAT="sqlserver://$STL:$(urlq "$STL_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
export PGV_X_SA="sqlserver://sa:$(urlq "$SA_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
inst() { # inst <name> <query_text> [yaml lines...]
  printf '  - name: %s\n    engine: sqlserver\n    dsn: env:PGV_X_MON\n    query_text: %s\n' "$1" "$2"; shift 2
  if [[ $NEWKEYS == 1 ]]; then for l in "$@"; do printf '    %s\n' "$l"; done; fi; }
{ printf 'repository:\n  dsn: "%s"\ninstances:\n' "$PGDSN"
  inst ixon full "histogram: true" "stats_dsn: env:PGV_X_STAT" "index_fragmentation: true"
  inst ixdef full
  inst ixnorm normalized "histogram: true"
  inst ixread full "histogram: true"
  inst ixsa full "histogram: true" "stats_dsn: env:PGV_X_SA"
  inst ixmon full
  inst ixbig full
  inst ixbig2 full
} > "$TMPD/m.yaml"
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col() { local i=$1; shift; for c in "$@"; do timeout 300 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance "$i" -once "$c" >"$TMPD/col-$i-$c.out" 2>&1 || { cat "$TMPD/col-$i-$c.out" >&2; fail "collect $i $c"; }; done; }
for i in ixon ixdef ixnorm ixread ixsa ixmon ixbig ixbig2; do col "$i" mssql_instance; done
iid() { pq "SELECT instance_id FROM pgvigil.instances WHERE name = '$1'"; }
ION=$(iid ixon); IDEF=$(iid ixdef); INORM=$(iid ixnorm); IREAD=$(iid ixread); ISA=$(iid ixsa); IMON=$(iid ixmon); IBIG=$(iid ixbig); IBIG2=$(iid ixbig2)
echo "ok   A: SQL Server $VER, pgvix and pgvac, instances ixon $ION / ixdef $IDEF / ixnorm $INORM / ixread $IREAD / ixsa $ISA"

PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "A: user add"
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
serve_start() { "$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve-$1.out" 2>&1 & SRVPID=$!
  for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
  kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve-$1.out" >&2; fail "$1: serve exited"; }
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "$1: the API login"; }
serve_start a
# api <path?query> <out>: GET, the body in <out>, the code printed; post <path> <json> <out> [headers-out]: POST with X-Pgvigil
api() { curl -s -o "$2" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/$1"; }
post() { curl -s -o "$3" -D "${4:-/dev/null}" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$2" "$U/api/$1"; }
# jq-like: jget <file> <python expression over d>
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
T0=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
WIN() { echo "from=$T0&to=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"; }
# usage <index name>: sys.dm_db_index_usage_stats of pgvix.dbo.t's index, as seeks|scans|lookups|updates
usage() { sq "SELECT CONCAT(ISNULL(us.user_seeks, 0), '|', ISNULL(us.user_scans, 0), '|', ISNULL(us.user_lookups, 0), '|', ISNULL(us.user_updates, 0))
  FROM sys.indexes i LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
 WHERE i.object_id = OBJECT_ID('dbo.t') AND i.name = '$1'" pgvix; }
# missing <equality|inequality>: the request on dbo.t (c) as seeks|scans
missing() { sq "SELECT CONCAT(s.user_seeks, '|', s.user_scans) FROM sys.dm_db_missing_index_details d JOIN sys.dm_db_missing_index_groups g ON g.index_handle = d.index_handle
  JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle = g.index_group_handle
 WHERE d.database_id = DB_ID('pgvix') AND d.object_id = OBJECT_ID('pgvix.dbo.t') AND d.${1}_columns = '[c]'"; }

if part B || part C; then
echo "== B. index usage kept per read / C. missing-index requests kept per read =="
pq "SELECT 1 FROM pgvigil.mssql_index_usage_read LIMIT 0" >/dev/null 2>&1 || fail "B: no table pgvigil.mssql_index_usage_read (red on f8e89d2)"
pq "SELECT 1 FROM pgvigil.mssql_missing_index_read LIMIT 0" >/dev/null 2>&1 || fail "C: no table pgvigil.mssql_missing_index_read (red on f8e89d2)"
col ixon mssql_indexes
R1=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_index WHERE instance_id = $ION AND database_name = 'pgvix'")
for ix in pk_t ix_a ix_b; do eval "H1_$ix=\$(usage $ix)"; done
MI1=$(missing equality); MN1=$(missing inequality)
# B1: one baseline row per index of pgvix at read 1, index_name kept
b1=$(pq "SELECT count(*) FILTER (WHERE u.prev_at IS NULL AND u.seeks_delta IS NULL AND u.index_name IS NOT NULL), count(*), (SELECT count(*) FROM pgvigil.mssql_index x WHERE x.instance_id = $ION AND x.database_name = 'pgvix')
  FROM pgvigil.mssql_index_usage_read u WHERE u.instance_id = $ION AND u.database_name = 'pgvix' AND u.snapshot_at = '$R1'")
IFS='|' read -r b1base b1all b1ix <<<"$b1"
[[ "$b1base" == "$b1all" && "$b1all" == "$b1ix" && "$b1ix" -gt 5 ]] || fail "B1: baselines $b1base of $b1all rows for $b1ix indexes"
echo "ok   B1: read 1 keeps $b1all baseline rows (deltas NULL, index_name kept), one per index of pgvix"
# B2: the workload, pgvac held open (AUTO_CLOSE) through read 2
sq "WAITFOR DELAY '00:01:30'" pgvac 200 >/dev/null 2>&1 & BG+=($!)
sleep 2
sqok "B2: the workload" "SELECT a FROM dbo.t WITH (INDEX(ix_a)) WHERE a = 1;
SELECT a FROM dbo.t WITH (INDEX(ix_a)) WHERE a = 2;
SELECT a FROM dbo.t WITH (INDEX(ix_a)) WHERE a = 3;
SELECT pad FROM dbo.t WITH (INDEX(ix_a)) WHERE a = 4;
SELECT COUNT(*) FROM dbo.t WITH (INDEX(pk_t));
SELECT COUNT(*) FROM dbo.t WITH (INDEX(pk_t));
SELECT COUNT(*) FROM dbo.t WITH (INDEX(pk_t));
UPDATE dbo.t SET a = a WHERE id = 1;
UPDATE dbo.t SET a = a WHERE id = 2;
SELECT id FROM dbo.t WHERE c = 17; SELECT id FROM dbo.t WHERE c = 18; SELECT id FROM dbo.t WHERE c = 19; SELECT id FROM dbo.t WHERE c = 20; SELECT id FROM dbo.t WHERE c = 21;
GO
SELECT COUNT(*) FROM pgvac.dbo.a WITH (INDEX(1));" pgvix
sleep 1
col ixon mssql_indexes
R2=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_index WHERE instance_id = $ION AND database_name = 'pgvix'")
for ix in pk_t ix_a ix_b; do eval "H2_$ix=\$(usage $ix)"; done
MI2=$(missing equality); MN2=$(missing inequality)
for ix in pk_t ix_a; do
  eval "h1=\$H1_$ix; h2=\$H2_$ix"
  want=$(python3 -c 'import sys; a=[int(x) for x in sys.argv[1].split("|")]; b=[int(x) for x in sys.argv[2].split("|")]; print("|".join(str(y-x) for x,y in zip(a,b)))' "$h1" "$h2")
  got=$(pq "SELECT concat_ws('|', u.seeks_delta, u.scans_delta, u.lookups_delta, u.updates_delta) FROM pgvigil.mssql_index_usage_read u
    WHERE u.instance_id = $ION AND u.database_name = 'pgvix' AND u.index_name = '$ix' AND u.snapshot_at = '$R2' AND u.prev_at = '$R1' AND NOT u.reset")
  [[ "$got" == "$want" ]] || fail "B2: $ix's deltas at read 2 '$got', the hand reads give '$want' ($h1 -> $h2)"
  echo "ok   B2: $ix's deltas at read 2 = $got (seeks|scans|lookups|updates), the hand reads' $h1 -> $h2"
done
[[ "$H1_ix_b" == "$H2_ix_b" ]] || fail "B2: ix_b moved by hand ($H1_ix_b -> $H2_ix_b)"
nb=$(pq "SELECT count(*) FROM pgvigil.mssql_index_usage_read u WHERE u.instance_id = $ION AND u.database_name = 'pgvix' AND u.index_name = 'ix_b' AND u.snapshot_at = '$R2'")
[[ "$nb" == 0 ]] || fail "B2: ix_b did not move and has $nb row(s) at read 2"
echo "ok   B2: ix_b (unmoved, $H2_ix_b) keeps no row at read 2"
# B4: pgvac (AUTO_CLOSE): both reads imported, its window not known, a moved index kept
b4=$(pq "SELECT coalesce(b.usage_since::text, 'NULL'), b.auto_close, b.read_at = '$R2', (SELECT count(*) FROM pgvigil.mssql_index_usage_read u WHERE u.instance_id = $ION AND u.database_name = 'pgvac' AND u.snapshot_at = '$R2')
  FROM pgvigil.mssql_index_db b WHERE b.instance_id = $ION AND b.database_name = 'pgvac'")
IFS='|' read -r b4since b4auto b4read b4rows <<<"$b4"
[[ "$b4since" == NULL && "$b4auto" == t && "$b4read" == t ]] || fail "B4: pgvac usage_since $b4since, auto_close $b4auto, read at read 2 $b4read"
echo "ok   B4: pgvac (AUTO_CLOSE) read twice without an error, usage_since NULL, $b4rows row(s) at read 2 (its scan of dbo.a, held open)"
[[ "$b4rows" -ge 1 ]] || fail "B4: pgvac's scanned index kept no row at read 2"
if part C; then
  # C1: the equality request: two rows of one identity, the delta the hand reads'
  wantmi=$(( ${MI2%%|*} - ${MI1%%|*} ))
  c1=$(pq "SELECT count(*), max(seeks_delta) FILTER (WHERE snapshot_at = '$R2'), count(DISTINCT ident) FROM pgvigil.mssql_missing_index_read
    WHERE instance_id = $ION AND table_ref LIKE '%[t]' AND equality_columns = '[c]' AND inequality_columns IS NULL")
  IFS='|' read -r c1n c1d c1id <<<"$c1"
  [[ "$c1n" == 2 && "$c1id" == 1 && "$c1d" == "$wantmi" ]] || fail "C1: rows $c1n, identities $c1id, delta $c1d (the hand reads: $MI1 -> $MI2)"
  echo "ok   C1: the equality request: 2 rows of one identity, seeks delta $c1d = the hand reads' ($MI1 -> $MI2)"
  # C2: equality (c) and inequality (c): two identities
  c2=$(pq "SELECT count(DISTINCT ident) FROM pgvigil.mssql_missing_index_read WHERE instance_id = $ION AND table_ref LIKE '%[t]'
    AND ((equality_columns = '[c]' AND inequality_columns IS NULL) OR (equality_columns IS NULL AND inequality_columns = '[c]'))")
  [[ "$c2" == 2 ]] || fail "C2: the equality / inequality pair has $c2 identit(y/ies)"
  echo "ok   C2: equality [c] / inequality [c] are two identities"
  [[ "$(api "mssql/indexes/depth?instance=$ION&$(WIN)" "$TMPD/c3.json")" == 200 ]] || fail "C3: depth $(cat "$TMPD/c3.json")"
  python3 - "$TMPD/c3.json" "$c1d" "$(pq "SELECT count(*) FROM pgvigil.mssql_missing_index WHERE instance_id = $ION")" <<'PY' || fail "C3: see above"
import json, sys
d = json.load(open(sys.argv[1])); want = int(sys.argv[2]); nmiss = int(sys.argv[3])
rows = lambda t: [dict(zip(t["columns"], r)) for r in (t or {}).get("rows") or []]
s = [r for r in rows(d["missing_series"]) if r["equality_columns"] == "[c]" and r["inequality_columns"] is None and str(r["table_ref"]).endswith("[t]")]
top = rows(d["missing_top"])
ok = len(s) == 2 and s[1]["seeks_delta"] == want and s[0]["seeks_delta"] is None and len(top) == nmiss and nmiss >= 2
print(("ok   " if ok else "BAD  ") + f"C3: the series of the equality request: {[(x['at'], x['seeks_delta']) for x in s]}; missing_top {len(top)} row(s) of {nmiss}")
sys.exit(0 if ok else 1)
PY
fi
# B3: pgvix offline and online, a workload, read 3: the whole count, reset
sqok "B3: offline / online" "ALTER DATABASE pgvix SET OFFLINE WITH ROLLBACK IMMEDIATE; ALTER DATABASE pgvix SET ONLINE;"
sqok "B3: the workload" "SELECT COUNT(*) FROM dbo.t WITH (INDEX(pk_t)); SELECT COUNT(*) FROM dbo.t WITH (INDEX(pk_t));" pgvix
H3=$(usage pk_t)
col ixon mssql_indexes
R3=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_index WHERE instance_id = $ION AND database_name = 'pgvix'")
b3=$(pq "SELECT concat_ws('|', u.seeks_delta, u.scans_delta, u.lookups_delta, u.updates_delta), u.reset FROM pgvigil.mssql_index_usage_read u
  WHERE u.instance_id = $ION AND u.database_name = 'pgvix' AND u.index_name = 'pk_t' AND u.snapshot_at = '$R3'")
[[ "$b3" == "$H3|t" ]] || fail "B3: pk_t at read 3 '$b3', the hand read $H3 with reset"
echo "ok   B3: after OFFLINE / ONLINE pk_t's row carries reset and the whole count ($H3)"
fi

if part B; then
# B5: a read across a month boundary (ixmon: its own instance, so the later parts' reads are not 'older')
col ixmon mssql_indexes
NEXT=$(pq "SELECT to_char(date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month' + interval '5 seconds', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
PART=$(pq "SELECT 'mssql_index_usage_read_' || to_char(date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month', 'YYYYMM')")
# payload <instance id> <database> <time> <seeks added>: a batch built from the stored rows, as the collector sends one
payload_sql() { echo "SELECT jsonb_build_array(jsonb_build_object('kind', 'state', 'server_utc', '$3', 'server_start', b.server_start, 'online_index_builds', false),
    jsonb_build_object('kind', 'db', 'database_id', b.database_id, 'database_name', b.database_name, 'database_state', 'ONLINE', 'created_at', b.created_at,
                       'last_restore', b.last_restore, 'restore_read', b.restore_read, 'auto_close', b.auto_close, 'readable_secondary', false, 'read', true, 'indexes', b.indexes))
  || (SELECT jsonb_agg(jsonb_build_object('kind', 'index', 'database_name', x.database_name, 'database_id', x.database_id, 'object_id', x.object_id, 'index_id', x.index_id,
        'schema_name', x.schema_name, 'table_name', x.table_name, 'index_name', x.index_name, 'index_type', x.index_type, 'key_columns', to_jsonb(x.key_columns),
        'include_columns', to_jsonb(x.include_columns), 'row_count', x.row_count, 'size_kb', x.size_kb, 'user_seeks', x.user_seeks + $4, 'user_scans', x.user_scans,
        'user_lookups', x.user_lookups, 'user_updates', x.user_updates))
      FROM pgvigil.mssql_index x WHERE x.instance_id = $1 AND x.database_name = '$2')
  FROM pgvigil.mssql_index_db b WHERE b.instance_id = $1 AND b.database_name = '$2'"; }
pq "SELECT pgvigil.import_mssql_indexes($IMON, '$NEXT', ($(payload_sql "$IMON" pgvix "$NEXT" 1)))" >/dev/null || fail "B5: the import across the month"
b5=$(pq "SELECT to_regclass('pgvigil.$PART') IS NOT NULL, (SELECT count(*) FROM pgvigil.$PART WHERE instance_id = $IMON AND seeks_delta = 1),
  (SELECT count(*) FROM pgvigil.mssql_index WHERE instance_id = $IMON AND database_name = 'pgvix' AND snapshot_at = '$NEXT')")
IFS='|' read -r b5p b5rows b5ix <<<"$b5"
[[ "$b5p" == t && "$b5rows" -gt 5 && "$b5rows" == "$b5ix" ]] || fail "B5: partition $b5p, rows $b5rows, inventory rows $b5ix"
echo "ok   B5: a read at $NEXT made $PART, its $b5rows rows (delta 1 each) and the inventory imported"
# B6: the measure: a 20,000-index batch through the wrapper (ixbig) and through 0092's import alone (ixbig2)
pq "INSERT INTO pgvigil.mssql_index_db (instance_id, database_name, database_id, snapshot_at) VALUES ($IBIG, 'bigdb', 99, now() - interval '1 day'), ($IBIG2, 'bigdb', 99, now() - interval '1 day')" >/dev/null
big_sql() { echo "SELECT jsonb_build_array(jsonb_build_object('kind', 'state', 'server_utc', '$2', 'server_start', '2026-01-01T00:00:00Z'),
    jsonb_build_object('kind', 'db', 'database_id', 99, 'database_name', 'bigdb', 'database_state', 'ONLINE', 'created_at', '2025-01-01T00:00:00Z', 'restore_read', true, 'read', true, 'indexes', 20000))
  || (SELECT jsonb_agg(jsonb_build_object('kind', 'index', 'database_name', 'bigdb', 'database_id', 99, 'object_id', 1000 + n / 4, 'index_id', 1 + n % 4, 'schema_name', 'dbo',
        'table_name', 'tab' || (n / 4), 'index_name', 'ix' || n, 'index_type', 'NONCLUSTERED', 'key_columns', jsonb_build_array('[k' || n || ']'), 'include_columns', '[]'::jsonb,
        'row_count', 1000, 'size_kb', 64, 'user_seeks', n + $3, 'user_scans', 1, 'user_lookups', 0, 'user_updates', 5)) FROM generate_series(1, 20000) n)"; }
tm() { local s e; s=$(date +%s%N); pq "$1" >/dev/null || fail "B6: $2"; e=$(date +%s%N); echo $(( (e - s) / 1000000 )); }
T1=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); T2=$(date -u -d '-1 hours' +%Y-%m-%dT%H:%M:%SZ)
pq "SELECT pgvigil.import_mssql_indexes($IBIG, '$T1', ($(big_sql "$IBIG" "$T1" 0)))" >/dev/null || fail "B6: the first big batch"
pq "SELECT pgvigil.import_mssql_indexes_0092($IBIG2, '$T1', ($(big_sql "$IBIG2" "$T1" 0)))" >/dev/null || fail "B6: the first big batch (0092)"
MSW=$(tm "SELECT pgvigil.import_mssql_indexes($IBIG, '$T2', ($(big_sql "$IBIG" "$T2" 1)))" "the wrapper")
MSO=$(tm "SELECT pgvigil.import_mssql_indexes_0092($IBIG2, '$T2', ($(big_sql "$IBIG2" "$T2" 1)))" "0092's import")
BPR=$(pq "SELECT round(avg(pg_column_size(u.*))) FROM pgvigil.mssql_index_usage_read u WHERE u.instance_id = $IBIG AND u.snapshot_at = '$T2'")
NB=$(pq "SELECT count(*) FROM pgvigil.mssql_index_usage_read u WHERE u.instance_id = $IBIG AND u.snapshot_at = '$T2'")
echo "MEASURE B6: a 20,000-index batch: the wrapper $MSW ms ($NB history rows), 0092's import alone $MSO ms; $BPR bytes per usage row (pg_column_size, mean)"
[[ "$NB" == 20000 && $MSW -lt $(( 3 * MSO + 500 )) ]] || fail "B6: $NB history rows, the wrapper $MSW ms against $MSO ms"
echo "ok   B6: the history costs under 3 times the old import's time"
fi

finding() { # finding <check_name> <database>: the instance ixon's finding's detail, or nothing
  pq "SELECT f.severity || ': ' || f.detail FROM pgvigil.mssql_indexes_findings f WHERE f.instance_id = $ION AND f.check_name = '$1' AND f.object = '$2'"; }
if part D; then
echo "== D. disabled indexes =="
sqok "D1: ix_b disabled" "ALTER INDEX ix_b ON dbo.t DISABLE;" pgvix
col ixon mssql_indexes
d1=$(finding 'disabled indexes' pgvix)
[[ "$d1" == info:* && "$d1" == *'[dbo].[t].[ix_b]'* ]] || fail "D1: the finding: '$d1'"
[[ "$(pq "SELECT is_disabled FROM pgvigil.mssql_index WHERE instance_id = $ION AND database_name = 'pgvix' AND index_name = 'ix_b'")" == t ]] || fail "D1: ix_b's row is not disabled"
echo "ok   D1: 'disabled indexes' (info) names [dbo].[t].[ix_b]; its inventory row is_disabled"
sqok "D2: t_cl's clustered index and parent's primary key disabled" "ALTER INDEX cx_t_cl ON dbo.t_cl DISABLE; ALTER INDEX pk_parent ON dbo.parent DISABLE;" pgvix
FKREF=$(sq "SELECT CONCAT(fk.is_disabled, '|', CASE WHEN fk.key_index_id IS NULL THEN 'none' ELSE 'kept' END) FROM sys.foreign_keys fk WHERE fk.name = 'fk_child_parent'" pgvix)
col ixon mssql_indexes
if [[ "$NEWKEYS" == 1 ]]; then col ixon mssql_constraints; fi
d2=$(finding 'a disabled index that blocks its table' pgvix)
echo "     D2: fk_child_parent after the disable (is_disabled|key index): $FKREF"
for want in 'warning:' 'ALTER INDEX ALL ON [dbo].[t_cl] REBUILD' 'ALTER INDEX [pk_parent] ON [dbo].[parent] REBUILD' 'ALTER TABLE [dbo].[child] WITH CHECK CHECK CONSTRAINT [fk_child_parent];' 'Disable Indexes and Constraints'; do
  [[ "$d2" == *"$want"* ]] || fail "D2: the warning lacks '$want': '$d2'"
done
d2i=$(finding 'disabled indexes' pgvix)
[[ "$d2i" != *'ix_t_cl_v'* ]] || fail "D2: the nonclustered index the clustered one took with it is listed apart: '$d2i'"
echo "ok   D2: 'a disabled index that blocks its table' (warning) with ALTER INDEX ALL ON [dbo].[t_cl] REBUILD, pk_parent's REBUILD and the foreign key's WITH CHECK CHECK"
sqok "D3: rebuilt" "ALTER INDEX ALL ON dbo.t_cl REBUILD; ALTER INDEX pk_parent ON dbo.parent REBUILD; ALTER TABLE dbo.child WITH CHECK CHECK CONSTRAINT fk_child_parent; ALTER INDEX ix_b ON dbo.t REBUILD;" pgvix
col ixon mssql_indexes
[[ -z "$(finding 'disabled indexes' pgvix)$(finding 'a disabled index that blocks its table' pgvix)" ]] || fail "D3: a disabled finding stays"
echo "ok   D3: rebuilt, read again: no disabled finding"
fi

if part E; then
echo "== E. untrusted keys and constraints =="
sqok "E1: NOCHECK, then CHECK without WITH CHECK" "ALTER TABLE dbo.child NOCHECK CONSTRAINT fk_child_parent; ALTER TABLE dbo.child CHECK CONSTRAINT fk_child_parent;
  ALTER TABLE dbo.child NOCHECK CONSTRAINT ck_child; ALTER TABLE dbo.child CHECK CONSTRAINT ck_child;
  ALTER TABLE dbo.child2 NOCHECK CONSTRAINT fk_child2_nfr; ALTER TABLE dbo.child2 CHECK CONSTRAINT fk_child2_nfr;
  ALTER TABLE dbo.child2 NOCHECK CONSTRAINT ck_dis;" pgvix
HAND=$(sq "SELECT STRING_AGG(CONCAT(name, ':', is_not_trusted, is_disabled, is_not_for_replication), ',') FROM (SELECT name, is_not_trusted, is_disabled, is_not_for_replication FROM sys.foreign_keys
  UNION ALL SELECT name, is_not_trusted, is_disabled, is_not_for_replication FROM sys.check_constraints) z" pgvix)
echo "     E1: the hand read (name:trusted,disabled,NFR): $HAND"
col ixon mssql_constraints
e1=$(pq "SELECT string_agg(kind || ':' || constraint_name, ',' ORDER BY constraint_name) FROM pgvigil.mssql_untrusted_constraint WHERE instance_id = $ION AND database_name = 'pgvix'")
[[ "$e1" == 'check:ck_child,foreign key:fk_child_parent' ]] || fail "E1/E2: the rows '$e1'"
f1=$(finding 'untrusted foreign keys and check constraints' pgvix)
[[ "$f1" == info:* && "$f1" == *'[dbo].[child].[ck_child]'* && "$f1" == *'[dbo].[child].[fk_child_parent]'* ]] || fail "E1: the finding '$f1'"
[[ "$(pq "SELECT concat_ws('|', untrusted_fk, untrusted_check, disabled_check) FROM pgvigil.mssql_constraint_db WHERE instance_id = $ION AND database_name = 'pgvix'")" == '1|1|1' ]] || fail "E2: the counts"
echo "ok   E1: ck_child and fk_child_parent named (the finding, the grid); E2: fk_child2_nfr (NOT FOR REPLICATION) and ck_dis (disabled) not named, ck_dis counted (1|1|1)"
sqok "E3: WITH CHECK CHECK" "ALTER TABLE dbo.child WITH CHECK CHECK CONSTRAINT fk_child_parent; ALTER TABLE dbo.child WITH CHECK CHECK CONSTRAINT ck_child;" pgvix
col ixon mssql_constraints
[[ -z "$(pq "SELECT 1 FROM pgvigil.mssql_untrusted_constraint WHERE instance_id = $ION AND database_name = 'pgvix'")$(finding 'untrusted foreign keys and check constraints' pgvix)" ]] || fail "E3: not cleared"
echo "ok   E3: WITH CHECK CHECK CONSTRAINT: cleared on the next read"
fi

hist() { post mssql/stats/histogram "{\"instance_id\":$1,\"database\":\"pgvix\",\"schema\":\"dbo\",\"table\":\"$2\",\"stats\":\"$3\"}" "$4" "${5:-/dev/null}"; }
# dbcc <table> <statistic>: DBCC SHOW_STATISTICS ... WITH HISTOGRAM, key|range_rows|eq_rows|distinct_range_rows per line
dbcc() { sq "DBCC SHOW_STATISTICS ('dbo.$1', '$2') WITH HISTOGRAM, NO_INFOMSGS;" pgvix; }
counts() { pq "SELECT string_agg(t || '=' || n, ',' ORDER BY t) FROM (SELECT table_name AS t, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM pgvigil.%I', table_name), false, true, '')))[1]::text AS n
  FROM information_schema.tables WHERE table_schema = 'pgvigil' AND table_type = 'BASE TABLE') z"; }
logins() { sq "SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Logins/sec' AND object_name LIKE '%General Statistics%'"; }
if part F; then
echo "== F. a histogram on demand =="
C0=$(counts)
code=$(hist "$ION" t ix_a "$TMPD/f1.json" "$TMPD/f1.h")
[[ "$code" == 200 ]] || fail "F1: POST stats/histogram $code $(cat "$TMPD/f1.json") (red on f8e89d2: no route)"
grep -qi '^Cache-Control: no-store' "$TMPD/f1.h" || fail "F1: the reply is not no-store"
dbcc t ix_a > "$TMPD/f1.dbcc"
for st in "t ix_a f1" "types st_d f2d" "types st_bin f2b" "types st_nm f2n"; do
  set -- $st
  [[ -s "$TMPD/$3.json" ]] || hist "$ION" "$1" "$2" "$TMPD/$3.json" >/dev/null
  [[ -s "$TMPD/$3.dbcc" ]] || dbcc "$1" "$2" > "$TMPD/$3.dbcc"
  python3 - "$TMPD/$3.json" "$TMPD/$3.dbcc" "$2" <<'PY' || fail "F1/F2: $2: see above"
import json, sys
d = json.load(open(sys.argv[1])); name = sys.argv[3]
hand = [l.split("|") for l in open(sys.argv[2]).read().splitlines() if l.strip()]
steps = d.get("steps") or []
def norm(k): return None if k is None else str(k).replace("T", " ")
bad = []
if d.get("state") != "ok": bad.append(f"state {d.get('state')}: {d.get('words')}")
if len(steps) != len(hand): bad.append(f"{len(steps)} steps, DBCC {len(hand)}")
for s, h in zip(steps, hand):
    hk = None if h[0] == "NULL" else h[0]
    if norm(s["range_high_key"]) != hk or abs(float(s["range_rows"]) - float(h[1])) > 1e-6 or abs(float(s["equal_rows"]) - float(h[2])) > 1e-6 \
       or int(s["distinct_range_rows"]) != int(float(h[3])):
        bad.append(f"step {s['step']}: {s['range_high_key']} {s['range_rows']} {s['equal_rows']} {s['distinct_range_rows']} vs {h[:4]}"); break
print(("ok   " if not bad else "BAD  ") + f"F1/F2: {name}: {len(steps)} steps equal DBCC SHOW_STATISTICS WITH HISTOGRAM step by step" + (f" ({bad})" if bad else "")
      + (f"; key type {steps[0]['key_type']}, first key {steps[0]['range_high_key']}" if steps else ""))
sys.exit(1 if bad else 0)
PY
done
f1log=$(pq "SELECT concat_ws('|', op, outcome, ui_user, door, rows, detail) FROM pgvigil.custom_report_log WHERE op = 'histogram' AND detail LIKE '%[st_nm]%' ORDER BY log_id DESC LIMIT 1")
[[ "$f1log" == "histogram|done|$USR|file|"* && "$f1log" == *'[dbo].[types].[st_nm] in pgvix'* ]] || fail "F1: the audit row '$f1log'"
pq "SELECT payload::text || coalesce(detail, '') FROM pgvigil.custom_report_log WHERE op = 'histogram'" | grep -q 'pgvkey-' && fail "F1: an audit row holds a key value"
grep -q 'histogram read' "$TMPD/serve-a.out" || fail "F1: no log line"
grep -q 'pgvkey-' "$TMPD/serve-a.out" && fail "F1: serve's log holds a key value"
echo "ok   F1: no-store; the audit rows (op histogram, done, $USR, door file, the step count) and serve's log line hold no key value"
L1=$(logins)
hist "$IDEF" t ix_a "$TMPD/f3a.json" >/dev/null; hist "$INORM" t ix_a "$TMPD/f3b.json" >/dev/null
L2=$(logins)
[[ "$(jget "$TMPD/f3a.json" 'd["state"]+"|"+d["words"]')" == "off|"*"an admin turns it on"* ]] || fail "F3: ixdef $(cat "$TMPD/f3a.json")"
[[ "$(jget "$TMPD/f3b.json" 'd["state"]+"|"+d["words"]')" == "off|"*'"normalized"'* ]] || fail "F3: ixnorm $(cat "$TMPD/f3b.json")"
[[ $(( L2 - L1 )) == 1 ]] || fail "F3: the server's logins moved by $(( L2 - L1 )) (1 = the count's own read)"
echo "ok   F3: ixdef off ('an admin turns it on'), ixnorm off (the policy), nothing sent (the logins moved by the count's own read only)"
hist "$IREAD" t ix_a "$TMPD/f4a.json" >/dev/null
echo "MEASURE F4: the read login without SELECT: $(jget "$TMPD/f4a.json" 'd["state"]+": "+str(d.get("words"))+" ("+str(len(d.get("steps") or []))+" steps)"')"
[[ "$(jget "$TMPD/f4a.json" 'd["state"] in ("none","error") and not d.get("steps") and bool(d.get("words"))')" == True ]] || fail "F4: ixread $(cat "$TMPD/f4a.json")"
hist "$ISA" t ix_a "$TMPD/f4b.json" >/dev/null
[[ "$(jget "$TMPD/f4b.json" 'd["state"]+"|"+d["words"]')" == "off|"*"sysadmin"* ]] || fail "F4: ixsa $(cat "$TMPD/f4b.json")"
echo "ok   F4: ixread answers its words with no step; ixsa (sa) refused (sysadmin)"
sq "SELECT CONCAT(OBJECT_NAME(s.object_id), '.', s.name, ' stats_id ', s.stats_id) FROM sys.stats s WHERE s.object_id IN (OBJECT_ID('dbo.cs'), OBJECT_ID('dbo.x'), OBJECT_ID('dbo.g'))" pgvix | sed 's/^/     F5 sys.stats: /'
for st in "cs ncci_cs columnstore" "x px_x XML" "g sx_g spatial"; do
  set -- $st
  hist "$ION" "$1" "$2" "$TMPD/f5$1.json" >/dev/null
  echo "     F5 $2: $(cat "$TMPD/f5$1.json" | head -c 300)"
  [[ "$(jget "$TMPD/f5$1.json" '(d["state"] in ("none","error")) and not d.get("steps")')" == True && "$(jget "$TMPD/f5$1.json" 'str(d.get("words"))')" == *"$3"* || "$(jget "$TMPD/f5$1.json" 'str(d.get("words"))')" == *"no statistic"* ]] || fail "F5: $2 $(cat "$TMPD/f5$1.json")"
done
echo "ok   F5: the columnstore, XML and spatial indexes: no histogram, with the reason"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/stats/histogram")" == 405 ]] || fail "F6: a GET is not 405"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMPD/cj" -H 'Content-Type: application/json' --data "{\"instance_id\":$ION,\"database\":\"pgvix\",\"schema\":\"dbo\",\"table\":\"t\",\"stats\":\"ix_a\"}" "$U/api/mssql/stats/histogram")" == 403 ]] || fail "F6: without X-Pgvigil not 403"
W2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$W2" -no-login >"$TMPD/serve-nologin.out" 2>&1 & SRV2PID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$W2/api/session" 2>/dev/null && break; sleep 0.1; done
curl -s -o "$TMPD/f6.json" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "{\"instance_id\":$ION,\"database\":\"pgvix\",\"schema\":\"dbo\",\"table\":\"t\",\"stats\":\"ix_a\"}" "http://127.0.0.1:$W2/api/mssql/stats/histogram"
kill "$SRV2PID" 2>/dev/null; wait "$SRV2PID" 2>/dev/null || true; SRV2PID=
[[ "$(jget "$TMPD/f6.json" 'd["state"]+"|"+d["words"]')" == "off|"*"needs a signed-in user"* ]] || fail "F6: -no-login $(cat "$TMPD/f6.json")"
echo "ok   F6: GET 405, no X-Pgvigil 403, -no-login off ('needs a signed-in user')"
C1=$(counts)
python3 - "$C0" "$C1" <<'PY' || fail "F7: see above"
import sys
a = dict(x.split("=") for x in sys.argv[1].split(",")); b = dict(x.split("=") for x in sys.argv[2].split(","))
moved = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
ok = moved == ["custom_report_log"]
print(("ok   " if ok else "BAD  ") + f"F7: the tables that changed during F: {moved}")
sys.exit(0 if ok else 1)
PY
fi

frag() { post mssql/indexes/fragmentation "{\"instance_id\":$1,\"database\":\"pgvix\",\"mode\":\"$2\"}" "$3"; }
# poll <read id> <seconds>: until the read is no longer running; its state printed
poll() { local s=; for _ in $(seq 1 "$2"); do api "mssql/indexes/fragmentation?instance=$ION&id=$1" "$TMPD/poll.json" >/dev/null
    s=$(jget "$TMPD/poll.json" 'dict(zip(d["read"]["columns"], d["read"]["rows"][0]))["state"]'); [[ "$s" != running ]] && break; sleep 1; done; echo "$s"; }
readcol() { jget "$TMPD/poll.json" "dict(zip(d['read']['columns'], d['read']['rows'][0]))['$1']"; }
hold() { # hold <table> <seconds> [sch-m]: a session holding the table, in the background
  local stmt="BEGIN TRAN; SELECT TOP (1) id FROM dbo.$1 WITH (TABLOCKX, HOLDLOCK); WAITFOR DELAY '00:00:$(printf %02d "$2")'; COMMIT;"
  [[ "${3:-}" == schm ]] && stmt="BEGIN TRAN; ALTER TABLE dbo.$1 ADD zz int NULL; WAITFOR DELAY '00:00:$(printf %02d "$2")'; ROLLBACK;"
  [[ "$2" -ge 60 ]] && stmt="${stmt/00:00:$(printf %02d "$2")/00:01:$(printf %02d $(( $2 - 60 )))}"
  sq "$stmt" pgvix 200 >/dev/null 2>&1 & BG+=($!); }
jobreqs() { sq "SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.program_name = 'pgvigil-fragmentation'"; }
jobsess() { sq "SELECT COUNT(*) FROM sys.dm_exec_sessions s WHERE s.program_name = 'pgvigil-fragmentation'"; }
if part G; then
echo "== G. fragmentation as a job =="
code=$(post mssql/indexes/fragmentation/cost "{\"instance_id\":$ION,\"database\":\"pgvix\"}" "$TMPD/g1.json")
[[ "$code" == 200 ]] || fail "G1: cost $code $(cat "$TMPD/g1.json") (red on f8e89d2: no route)"
HP=$(sq "SELECT SUM(p.used_page_count) FROM sys.dm_db_partition_stats p JOIN sys.objects o ON o.object_id = p.object_id WHERE p.index_id = 0 AND o.is_ms_shipped = 0" pgvix)
[[ "$(jget "$TMPD/g1.json" 'str(d["heap_pages"])')" == "$HP" && "$(jget "$TMPD/g1.json" 'd["cost_words"]')" == *"a heap's data pages are read in full even in LIMITED"* ]] || fail "G1: $(cat "$TMPD/g1.json") vs heap pages $HP"
echo "ok   G1: the heap size $HP pages = the hand read of sys.dm_db_partition_stats, with the cost words"
for mode in LIMITED SAMPLED; do
  t0=$(date +%s%N); frag "$ION" "$mode" "$TMPD/g2.json" >/dev/null; t1=$(date +%s%N)
  RID=$(jget "$TMPD/g2.json" 'd.get("read_id")'); [[ "$(jget "$TMPD/g2.json" 'd["state"]')" == running && $(( (t1 - t0) / 1000000 )) -lt 5000 ]] || fail "G2: $mode start $(cat "$TMPD/g2.json")"
  st=$(poll "$RID" 180); [[ "$st" == done ]] || fail "G2: $mode ended $st: $(readcol note)"
  HF=$(sq "SELECT CONCAT(CAST(avg_fragmentation_in_percent AS decimal(9,2)), '|', page_count) FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.frag'), 1, NULL, '$mode') WHERE index_level = 0 AND alloc_unit_type_desc = 'IN_ROW_DATA'" pgvix)
  HH=$(sq "SELECT page_count FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.heap'), 0, NULL, '$mode') WHERE alloc_unit_type_desc = 'IN_ROW_DATA'" pgvix)
  python3 - "$TMPD/poll.json" "$HF" "$HH" "$mode" <<'PY' || fail "G2: see above"
import json, sys
d = json.load(open(sys.argv[1])); hf, hp = sys.argv[2].split("|"); hh = int(sys.argv[3]); mode = sys.argv[4]
rows = [dict(zip(d["rows"]["columns"], r)) for r in d["rows"]["rows"] or []]
fr = [r for r in rows if r["table_name"] == "frag" and r["alloc_unit"] == "IN_ROW_DATA"]
hr = [r for r in rows if r["table_name"] == "heap" and r["alloc_unit"] == "IN_ROW_DATA"]
want_mark = float(hf) > 30 and int(hp) > 1000
ok = len(fr) == 1 and abs(float(fr[0]["fragment_pct"]) - float(hf)) <= 0.5 and fr[0]["marked"] == want_mark and len(hr) == 1 and int(hr[0]["page_count"]) == hh
print(("ok   " if ok else "BAD  ") + f"G2: {mode}: dbo.frag {fr[0]['fragment_pct'] if fr else None} % (the hand read {hf} %, {hp} pages), marked {fr[0]['marked'] if fr else None}; the heap {hr[0]['page_count'] if hr else None} pages (the hand read {hh})")
sys.exit(0 if ok else 1)
PY
done
frag "$IDEF" LIMITED "$TMPD/g3.json" >/dev/null
[[ "$(jget "$TMPD/g3.json" 'd["state"]+"|"+d["words"]')" == "off|"*"an admin turns it on"* && "$(pq "SELECT count(*) FROM pgvigil.mssql_fragmentation_read WHERE instance_id = $IDEF")" == 0 ]] || fail "G3: ixdef $(cat "$TMPD/g3.json")"
echo "ok   G3: ixdef off ('an admin turns it on'), no row"
# G4: three tables held in turn, each under 30 s: the read over 75 s, the POST answered at once
hold f1 28; hold f2 56; hold f3 84; sleep 1
t0=$(date +%s%N); frag "$ION" LIMITED "$TMPD/g4.json" >/dev/null; t1=$(date +%s%N); RID=$(jget "$TMPD/g4.json" 'd.get("read_id")')
[[ "$(jget "$TMPD/g4.json" 'd["state"]')" == running && $(( (t1 - t0) / 1000000 )) -lt 5000 ]] || fail "G4: start $(cat "$TMPD/g4.json")"
st=$(poll "$RID" 150); secs=$(readcol secs)
[[ "$st" == done && "$secs" -gt 75 ]] || fail "G4: ended $st after $secs s: $(readcol note)"
echo "ok   G4: the POST answered in $(( (t1 - t0) / 1000000 )) ms; the job ran $secs s (past serve's 75 s write timeout) and ended done"
wait 2>/dev/null || true; BG=()
# G5: one at a time; Cancel ends the job's own request on the server
hold f1 40; sleep 1
frag "$ION" LIMITED "$TMPD/g5a.json" >/dev/null; RID=$(jget "$TMPD/g5a.json" 'd.get("read_id")')
frag "$ION" SAMPLED "$TMPD/g5b.json" >/dev/null
[[ "$(jget "$TMPD/g5b.json" 'd["state"]+"|"+d["words"]')" == "refused|"*"one at a time"* ]] || fail "G5: the second start $(cat "$TMPD/g5b.json")"
sleep 3; [[ "$(jobreqs)" -ge 1 ]] || fail "G5: the job's request is not on the server before the Cancel"
post mssql/indexes/fragmentation/cancel "{\"instance_id\":$ION,\"read_id\":$RID}" "$TMPD/g5c.json" >/dev/null
gone=; for _ in $(seq 1 10); do [[ "$(jobreqs)" == 0 ]] && gone=1 && break; sleep 0.5; done
[[ -n "$gone" ]] || fail "G5: the job's request is still on the server 5 s after the Cancel"
st=$(poll "$RID" 20); [[ "$st" == cancelled ]] || fail "G5: the row is $st"
echo "ok   G5: a second start refused ('one at a time'); Cancel: the request gone from sys.dm_exec_requests within 5 s, the row cancelled"
wait 2>/dev/null || true; BG=()
# G6: a held Sch-M lock: the read ends near 30 s, the rows before kept, where it stopped named
hold f1 45 schm; sleep 2
frag "$ION" LIMITED "$TMPD/g6.json" >/dev/null; RID=$(jget "$TMPD/g6.json" 'd.get("read_id")')
st=$(poll "$RID" 60); secs=$(readcol secs); note=$(readcol note); kept=$(readcol rows_kept)
[[ "$st" == failed && "$secs" -ge 28 && "$secs" -le 42 && "$note" == *"index maintenance"* && "$note" == *"after "* && "$kept" -ge 1 ]] || fail "G6: $st after $secs s, $kept kept: $note"
echo "ok   G6: the Sch-M lock ended the read after $secs s; $kept row(s) kept; the note: $note"
wait 2>/dev/null || true; BG=()
# G7: serve killed during a held read; serve again: the row stopped after 60 s without a beat, a new start taken
hold f1 50; sleep 1
frag "$ION" LIMITED "$TMPD/g7.json" >/dev/null; RID=$(jget "$TMPD/g7.json" 'd.get("read_id")')
sleep 3; kill -9 "$SRVPID"; wait "$SRVPID" 2>/dev/null || true; SRVPID=
serve_start g7
gone=; for _ in $(seq 1 60); do [[ "$(jobsess)" == 0 ]] && gone=$_ && break; sleep 1; done
[[ -n "$gone" ]] || fail "G7: the killed serve's session is still on the server after 60 s"
st0=$(poll "$RID" 1)
sleep 62; st=$(poll "$RID" 1)
[[ "$st0" == running && "$st" == stopped ]] || fail "G7: the row read $st0 at once and $st after 62 s"
wait 2>/dev/null || true; BG=()
frag "$ION" LIMITED "$TMPD/g7b.json" >/dev/null; R2ID=$(jget "$TMPD/g7b.json" 'd.get("read_id")')
[[ "$(jget "$TMPD/g7b.json" 'd["state"]')" == running && "$(pq "SELECT state FROM pgvigil.mssql_fragmentation_read WHERE read_id = $RID")" == stopped ]] || fail "G7: the new start $(cat "$TMPD/g7b.json")"
poll "$R2ID" 120 >/dev/null
echo "ok   G7: the killed serve's session gone in about $gone s; the row read running, then stopped after 60 s without a beat; a new start taken and the row marked stopped"
"$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance ixon -once mssql_fragmentation >"$TMPD/g8.out" 2>&1 && fail "G8: a collection named mssql_fragmentation ran"
grep -q 'unknown collection' "$TMPD/g8.out" || fail "G8: $(cat "$TMPD/g8.out")"
echo "ok   G8: no collection names it"
echo "NOT PROVEN: G, a secondary replica refused (no availability group in a container); the code path is OnDemandDatabase's refuseSecondary"
fi

if part H; then
echo "== H. purge and rights =="
OLDP=$(pq "SELECT now() - interval '75 days'")
pq "SELECT pgvigil.ensure_month_partition('mssql_index_usage_read', '$OLDP')" >/dev/null
OLDPART=$(pq "SELECT 'mssql_index_usage_read_' || to_char(date_trunc('month', '$OLDP'::timestamptz AT TIME ZONE 'UTC'), 'YYYYMM')")
pq "INSERT INTO pgvigil.mssql_index_usage_read (instance_id, database_name, object_id, index_id, snapshot_at, user_seeks, user_scans, user_lookups, user_updates)
      VALUES ($ION, 'pgvix', 1, 1, '$OLDP', 0, 0, 0, 0);
    INSERT INTO pgvigil.mssql_missing_index_read (instance_id, ident, snapshot_at) VALUES ($ION, 'aged', now() - interval '40 days');
    INSERT INTO pgvigil.mssql_fragmentation_read (instance_id, instance, database_name, mode, ui_user, started_at, beat_at, ended_at, state)
      VALUES ($ION, 'ixon', 'pgvix', 'LIMITED', 'aged', now() - interval '40 days', now() - interval '40 days', now() - interval '40 days', 'done')" >/dev/null
KEEP=$(pq "SELECT (SELECT count(*) FROM pgvigil.mssql_missing_index_read WHERE ident <> 'aged') || '|' || (SELECT count(*) FROM pgvigil.mssql_fragmentation_read WHERE ui_user <> 'aged')")
pq "SELECT pgvigil.purge(30)" >/dev/null || fail "H1: purge(30)"
h1=$(pq "SELECT to_regclass('pgvigil.$OLDPART') IS NULL, (SELECT count(*) FROM pgvigil.mssql_missing_index_read WHERE ident = 'aged'), (SELECT count(*) FROM pgvigil.mssql_fragmentation_read WHERE ui_user = 'aged'),
  (SELECT count(*) FROM pgvigil.mssql_missing_index_read WHERE ident <> 'aged') || '|' || (SELECT count(*) FROM pgvigil.mssql_fragmentation_read WHERE ui_user <> 'aged')")
[[ "$h1" == "t|0|0|$KEEP" ]] || fail "H1: after purge(30) '$h1' (kept before $KEEP)"
echo "ok   H1: purge(30): $OLDPART dropped, the aged missing-index row and fragmentation read deleted, the rest kept ($KEEP)"
if [[ "$(pq "SELECT count(*) FROM pg_roles WHERE rolname = 'pgvigil_reader'")" == 1 ]]; then
  [[ "$(pq "SELECT has_function_privilege('pgvigil_reader', 'pgvigil.mssql_index_depth_purge(int)', 'EXECUTE')")" == f ]] || fail "H2: pgvigil_reader may EXECUTE mssql_index_depth_purge"
  echo "ok   H2: pgvigil_reader may not EXECUTE mssql_index_depth_purge"
else
  echo "NOT PROVEN: H2 (the cluster has no pgvigil_reader role)"
fi
fi

if part I; then
echo "== I. the page's reads =="
[[ "$(api "mssql/indexes/depth?instance=$ION&$(WIN)" "$TMPD/i1.json")" == 200 ]] || fail "I: depth $(cat "$TMPD/i1.json") (red on f8e89d2: no route)"
[[ "$(api "mssql/indexes/depth?instance=$IDEF&$(WIN)" "$TMPD/i2.json")" == 200 ]] || fail "I: depth ixdef"
python3 - "$TMPD/i1.json" "$TMPD/i2.json" <<'PY' || fail "I: see above"
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
want = {"state", "usage_series", "missing_series", "missing_top", "untrusted", "constraint_dbs", "fragmentation", "switches"}
sw = lambda d: dict(zip(d["switches"]["columns"], d["switches"]["rows"][0]))
ok = want <= set(a) and sw(a)["histogram_off"] == "" and sw(a)["fragmentation_off"] == "" and sw(a)["histogram_login"] == "statistics" \
     and "an admin turns it on" in sw(b)["histogram_off"] and "an admin turns it on" in sw(b)["fragmentation_off"]
print(("ok   " if ok else "BAD  ") + f"I: the parts {sorted(set(a) & want)}; ixon's switches {sw(a)['histogram_off']!r} {sw(a)['fragmentation_off']!r} ({sw(a)['histogram_login']}); ixdef's off with the words")
sys.exit(0 if ok else 1)
PY
fi
echo "PASS: proof-mssql-index-depth ($PARTS) on SQL Server $VER"
