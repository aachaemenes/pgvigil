#!/usr/bin/env bash
# Proof of Darling slice 3 task D404 (C02a): the SQL Server index read widened - heaps, the per-index operational
# counters, the table shape, data spaces and partition functions, temporal tables, foreign-key columns, filter columns and
# columnstore segments (internal/mssql/indexes.go, migration 0169, GET /api/mssql/indexes). D405's rules (X7-X28) join
# this file when they are built. One SQL Server container per run, a repository database of its own, pgvigil built from
# this tree. Every value the read stores is compared with sa's own catalog read of the same thing on the same server,
# done right after the read with nothing run in between.
# Needs: docker, go, psql, curl, python3, and:
#   ADMIN_DSN     a superuser connection to a PostgreSQL sandbox in KEYWORD form (default 'host=127.0.0.1 port=5432
#                 user=postgres dbname=postgres'); the proof makes its own repository database and drops it.
#   MSSQL_IMAGE   the SQL Server image (default the D401 slice's pin, mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04;
#                 X6's segment half needs 2022 or later: sys.column_store_segments.min_deep_data)
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files or the environment.
# Each X row is graded on its own (a FAIL does not stop the rows after it); the last line counts them.
# DEPARTURES from the design's words (review N7): each part is its own sys.sp_executesql after the index read (the
# collector catches a part's error), not a TRY ... CATCH inside the index read's statement; the partition function is
# stored by name, not by id. The review's pass (in-process FALLBACK, 1ca3e07d) folded at the rows it names below.
#
# Expected (written before the first run):
#  A. the container: the monitor login (VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE, an msdb reader);
#     databases pgvr (every fixture below), pgvr_drop (a heap, a table with a foreign key; dropped before read 2),
#     pgvr_deny (a table with a foreign key; the monitor login's user there DENIED SELECT on sys.foreign_key_columns) and
#     pgvr_cs (COLLATE Latin1_General_CS_AS, not the server's: a filtered index and a partitioned heap);
#     instance ixr; read 1 of mssql_indexes stores pgvr's indexes (A2: as many as sa counts: index_id > 0 of user tables
#     and indexed views).
#  X1 HEAPS (BI 44-46's sources): pgvigil.mssql_heap holds one row per heap of a user table of pgvr (h_fwd, h_plain, ph,
#     tt_hist is not one: it has a clustered index) and nothing else, each equal to sa's read: rows, reserved KB, seeks /
#     scans / lookups / updates (sys.dm_db_index_usage_stats, index 0), forwarded_fetch_count and leaf_delete_count summed
#     over partitions (sys.dm_db_index_operational_stats), the table's create date to the second, the data space's name
#     and type, the partitioning column, the partition count, the compression (MIXED when the partitions differ) and
#     whether any partition is uncompressed; h_fwd's forwarded_fetch_count > 0 and leaf_delete_count > 0 (half its rows
#     widened to 3,000 bytes, then a scan, then a delete); ph on PARTITION_SCHEME ps_a, column [k], its partition 1 PAGE:
#     MIXED with a partition uncompressed (review N5).
#     Red on the base 7184f8ea: no table pgvigil.mssql_heap.
#  X1b OPERATIONAL COUNTERS on mssql_index (D436's breakdown, IC L2883-2896): row and page lock waits (count, ms), page
#     latch and page I/O latch waits (count, ms), forwarded_fetch_count, leaf_delete_count, summed over partitions, each
#     index of pgvr equal to sa's read (NULL where the DMV has no row); dbo.lk's primary key row_lock_wait_count >= 1 and
#     row_lock_wait_ms >= 2000 (one session held the row 4 s while another waited for it).
#     Red on the base: mssql_index has no column row_lock_wait_count.
#  X2 TABLE SHAPE (BI 24 / 26 / 27; IC's sparse and text / ntext / image tests): pgvigil.mssql_table_shape holds one row
#     per user table and indexed view of pgvr (v_iv yes, v_plain - a view with no index - no), each equal to sa's read:
#     object type, total columns, the sum of max_length with -1 as 0, columns of max_length -1, string-or-LOB columns by
#     BI's test (type named by user_type_id IN varchar / nvarchar / char, or max_length -1), any sparse column, any
#     text / ntext / image column, the clustered key's bytes and key-column count (NULL when there is none); wide:
#     sparse 1, text 1, LOB 1; ck4: 4 key columns, 20 bytes; v_iv: type V; and, worked out by hand from the DDL so a
#     wrong formula cannot pass on both sides (review B1): ck4 7 columns / 130 bytes / 2 strings (s, ch; nchar is not one
#     by BI L5708), v_iv 2 / 8 / 0, wide 37 / 156 / 1 (text is 16 bytes and not a string by BI's test).
#     Red on the base: no table pgvigil.mssql_table_shape.
#  X3 DATA SPACES AND OBJECT TYPE on mssql_index: every index of pgvr equal to sa's read in object type, data space name
#     and type_desc, the partition function's name, argument type, partition count and range ('RANGE RIGHT FOR VALUES
#     (100, 200)'), the partitioning column, any partition uncompressed; fixed: ix_pt_fg ROWS_FILEGROUP [PRIMARY];
#     ix_pt_eq on ps_b (pf_b, the same range as pf_a); cx_pt MIXED with any_uncompressed (partition 1 PAGE);
#     pd's clustered index argument type datetime2(3), RANGE LEFT, its boundary '2026-01-01 00:00:00.0000000' (the first
#     expected said '...00.000': run d404-g3 read the product's 'Jan  1 2026 12:00AM' - a sql_variant cast to nvarchar
#     takes style 0 - a product fault, fixed); pm's function on money with its boundary whole (1.2345, not 1.23);
#     cx_v_iv object type V; review B2: pdt's datetime boundary '2026-01-31 23:59:59.997' whole, pvs's varchar(10) quoted
#     ('m'), pdc's decimal(9,2) 10.50; review S9: xg's primary XML and spatial indexes in the equality (their data space by
#     LEFT JOIN, a NULL spelled '~'), their stored values printed - no fixed value was known before the run.
#     Red on the base: mssql_index has no column object_type.
#  X4 TEMPORAL on mssql_table_shape: temporal_type and history_table_id equal to sys.tables for every table of pgvr (NULL
#     for a view); tt 2 with tt_hist's object id, tt_hist 1, the rest 0.
#     Red on the base: no table pgvigil.mssql_table_shape.
#  X5 FOREIGN KEYS: pgvigil.mssql_fk_columns holds one row per ENABLED foreign key of pgvr, equal to sa's read: name,
#     parent and referenced table, the parent columns in constraint order, quoted; fk_fc_fp's columns [y],[x] (declared
#     FOREIGN KEY (y, x)); fk_fc_dis (NOCHECK) absent.
#     Red on the base: no table pgvigil.mssql_fk_columns.
#  X6 FILTER COLUMNS AND COLUMNSTORE SEGMENTS on mssql_index: filter_columns of each filtered index equal to sa's read of
#     sys.sql_expression_dependencies (class 7 -> 1), by name - the product reads them another way (the bracketed names
#     in filter_definition, sp_IndexCleanup's: the read login may not read the dependencies, Msg 229 in run d404-g1), so
#     the two are independent; ix_f's [b],[c] (WHERE b > 0 AND c IS NOT NULL);
#     cs_rebuild_columns of each columnstore index equal to sa's read of BI's L3011-3034 test (an empty list on 2022, where
#     a new segment keeps its deep data); NULL on every rowstore index.
#     Red on the base: mssql_index has no column filter_columns.
#  XD A DROPPED DATABASE: read 1 stores pgvr_drop's heap, shape and foreign-key rows; pgvr_drop dropped, read 2: none of
#     them is left (0092 deletes its indexes; the new import deletes the rest).
#     Red on the base: the new tables are absent.
#  XN A PART THAT FAILS: pgvr_deny's indexes stored as sa counts them (the index read stands), its foreign-key part not
#     read: pgvigil.mssql_index_parts says parts_read without 'fks' and a note naming the foreign keys and the server's
#     words (denied), no mssql_fk_columns row of pgvr_deny; pgvr's parts_read holds heaps, shape, fks, ixextra, segments;
#     the run's state partial, its note the foreign keys of 1 database(s) (review S2: a failed part makes the run partial).
#  XC A DATABASE IN ANOTHER COLLATION (review S8): pgvr_cs's parts all five read, Ix_Cf's filter columns [B],[C], its heap
#     Ch on Ps_Cs [K].
#     Red on the base: no table pgvigil.mssql_index_parts.
#  XA THE API: GET /api/mssql/indexes?instance=<ixr> answers a part 'heaps' with as many rows as mssql_heap holds for the
#     instance, and its 'indexes' rows carry object_type, data_space_name, data_space_type, partition_function,
#     table_created and the counters; its 'databases' rows carry parts_note.
#     Red on the base: no part 'heaps'.
#  XS THE PAGE (with PGVIGIL_SHOTS = a folder, and chromium and node here; the bundle built from this tree first): a headless
#     Chromium signed in as the proof's user opens #/mssqlindexes?i=<ixr>: the 'Heaps' block lists as many rows as
#     mssql_heap holds for the instance, the inventory shows 'indexed view' on cx_v_iv's row and 'ps_a ([k])' as a partition
#     scheme, the usage-window grid has its 'read notes' column with pgvr_deny's words; a full-page picture in the light
#     and the dark scheme into PGVIGIL_SHOTS. Without PGVIGIL_SHOTS: 'XS not run' (not counted).
#  NOT PROVEN here: the 20,000-row caps of the new parts (no such database in a container: the cap logic is the index
#  read's, read in the code); SQL Server before 2022 (cs_rebuild_columns NULL and the note: the box's 2019 image runs D405's
#  X15 trial); a memory-optimized table (left out as the index read leaves it out, its foreign keys too: review S4); a
#  non-empty cs_rebuild_columns (no pre-2022 segment here: D405's X15, review S7); a part cut by the run's deadline
#  (review S1: read in the code).
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvrx-sql-$SUF; LBL=pgvigil-proof=d404
PGDB=pgv_rx_$SUF; MON=pgv_rmon_$SUF; USR=proofdba$SUF
NF=0; NOK=0
fail() { echo "FAIL: $*" >&2; exit 1; }   # the setup only: an X row never stops the run
ok() { echo "ok   $*"; NOK=$((NOK + 1)); }
bad() { echo "FAIL $*"; NF=$((NF + 1)); }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; BG=()
SA_PW=$(pw); MON_PW=$(pw); UPW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  for p in "${BG[@]}"; do kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
for t in docker go psql curl python3; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

echo "== A. the container ($IMG_SQL) =="
docker run -d --name "$SQL" --label "$LBL" --memory 4g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null || fail "A: docker run"
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
sqok "A: the monitor login" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON]; GRANT VIEW ANY DEFINITION TO [$MON]; GRANT CONNECT ANY DATABASE TO [$MON];"
sqok "A: the monitor's msdb user" "CREATE USER [$MON] FOR LOGIN [$MON]; ALTER ROLE db_datareader ADD MEMBER [$MON];" msdb
sqok "A: the databases" "CREATE DATABASE pgvr; ALTER DATABASE pgvr SET RECOVERY SIMPLE; CREATE DATABASE pgvr_drop; ALTER DATABASE pgvr_drop SET RECOVERY SIMPLE;
  CREATE DATABASE pgvr_deny; ALTER DATABASE pgvr_deny SET RECOVERY SIMPLE;
  CREATE DATABASE pgvr_cs COLLATE Latin1_General_CS_AS; ALTER DATABASE pgvr_cs SET RECOVERY SIMPLE;"
NUMS="(SELECT TOP (@n) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS n FROM sys.all_objects x CROSS JOIN sys.all_objects y) z"
# X1: two heaps and a partitioned heap; h_fwd's rows widened (forwarded records), scanned (forwarded fetches), some deleted
sqok "A: the partition functions and schemes" "CREATE PARTITION FUNCTION pf_a (int) AS RANGE RIGHT FOR VALUES (100, 200);
  CREATE PARTITION SCHEME ps_a AS PARTITION pf_a ALL TO ([PRIMARY]);
  CREATE PARTITION FUNCTION pf_b (int) AS RANGE RIGHT FOR VALUES (100, 200);
  CREATE PARTITION SCHEME ps_b AS PARTITION pf_b ALL TO ([PRIMARY]);
  CREATE PARTITION FUNCTION pf_c (int) AS RANGE RIGHT FOR VALUES (150);
  CREATE PARTITION SCHEME ps_c AS PARTITION pf_c ALL TO ([PRIMARY]);
  CREATE PARTITION FUNCTION pf_d (datetime2(3)) AS RANGE LEFT FOR VALUES ('2026-01-01');
  CREATE PARTITION SCHEME ps_d AS PARTITION pf_d ALL TO ([PRIMARY]);
  CREATE PARTITION FUNCTION pf_m (money) AS RANGE RIGHT FOR VALUES (1.2345);
  CREATE PARTITION SCHEME ps_m AS PARTITION pf_m ALL TO ([PRIMARY]);
  CREATE PARTITION FUNCTION pf_t (datetime) AS RANGE LEFT FOR VALUES ('2026-01-31T23:59:59.997');
  CREATE PARTITION SCHEME ps_t AS PARTITION pf_t ALL TO ([PRIMARY]);
  CREATE PARTITION FUNCTION pf_s (varchar(10)) AS RANGE LEFT FOR VALUES ('m');
  CREATE PARTITION SCHEME ps_s AS PARTITION pf_s ALL TO ([PRIMARY]);
  CREATE PARTITION FUNCTION pf_n (decimal(9,2)) AS RANGE RIGHT FOR VALUES (10.50);
  CREATE PARTITION SCHEME ps_n AS PARTITION pf_n ALL TO ([PRIMARY]);" pgvr
sqok "A: the heaps" "DECLARE @n int = 2000;
  CREATE TABLE dbo.h_fwd (id int NOT NULL, v varchar(4000) NULL);
  INSERT dbo.h_fwd (id, v) SELECT n, 'x' FROM $NUMS;
  UPDATE dbo.h_fwd SET v = REPLICATE('y', 3000) WHERE id % 2 = 0;
  SELECT @n = COUNT(*) FROM dbo.h_fwd WHERE v LIKE 'y%';
  DELETE dbo.h_fwd WHERE id % 7 = 0;
  SET @n = 3000;
  CREATE TABLE dbo.h_plain (id int NOT NULL, pad char(200) NOT NULL DEFAULT 'p');
  INSERT dbo.h_plain (id) SELECT n FROM $NUMS;
  CREATE INDEX ix_h_plain ON dbo.h_plain (id) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
  SELECT @n = COUNT(*) FROM dbo.h_plain;
  CREATE TABLE dbo.ph (k int NOT NULL, v int NOT NULL) ON ps_a (k);
  SET @n = 300; INSERT dbo.ph (k, v) SELECT n, n FROM $NUMS;
  ALTER TABLE dbo.ph REBUILD PARTITION = 1 WITH (DATA_COMPRESSION = PAGE);" pgvr 300
# X1b: a row lock waited for 3 s on dbo.lk's primary key
sqok "A: dbo.lk" "CREATE TABLE dbo.lk (id int NOT NULL CONSTRAINT pk_lk PRIMARY KEY CLUSTERED, v int NOT NULL); INSERT dbo.lk (id, v) VALUES (1, 1), (2, 2), (3, 3);" pgvr
sq "BEGIN TRAN; UPDATE dbo.lk SET v = v + 1 WHERE id = 1; WAITFOR DELAY '00:00:04'; COMMIT;" pgvr 60 >/dev/null 2>&1 & BG+=($!)
sleep 1
sqok "A: the waiter on dbo.lk" "UPDATE dbo.lk SET v = v + 1 WHERE id = 1;" pgvr 60
wait "${BG[-1]}" 2>/dev/null || true
# X2: a wide table (sparse, LOB, text), a four-column clustered key of 20 bytes, an indexed view and a plain view
WIDE=$(for i in $(seq -w 1 33); do printf 'c%s int NULL, ' "$i"; done)
sqok "A: the shapes" "CREATE TABLE dbo.wide (id int NOT NULL CONSTRAINT pk_wide PRIMARY KEY CLUSTERED, $WIDE sp1 int SPARSE NULL, lob nvarchar(max) NULL, txt text NULL);
  CREATE TABLE dbo.ck4 (a int NOT NULL, b int NOT NULL, c int NOT NULL, d bigint NOT NULL, s nvarchar(40) NULL, ch char(10) NULL, nc nchar(10) NULL);
  CREATE UNIQUE CLUSTERED INDEX cx_ck4 ON dbo.ck4 (a, b, c, d) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
  CREATE TABLE dbo.t_base (id int NOT NULL CONSTRAINT pk_t_base PRIMARY KEY CLUSTERED, a int NOT NULL, b int NOT NULL, c varchar(10) NULL);
  INSERT dbo.t_base (id, a, b, c) VALUES (1, 1, 1, 'a'), (2, 2, 0, NULL), (3, 3, 3, 'c');
  CREATE INDEX ix_f ON dbo.t_base (a) WHERE b > 0 AND c IS NOT NULL WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);" pgvr
sqok "A: the views" "SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE VIEW dbo.v_iv WITH SCHEMABINDING AS SELECT id, a FROM dbo.t_base;
GO
CREATE UNIQUE CLUSTERED INDEX cx_v_iv ON dbo.v_iv (id) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
GO
CREATE VIEW dbo.v_plain AS SELECT id FROM dbo.t_base;" pgvr
# X3: a partitioned table with an aligned index, one on an equivalent function, one on a filegroup, one on another
# function, one on another column; partition 1 of the clustered index PAGE (MIXED); a table on a datetime2(3) function
sqok "A: the partitioned tables" "CREATE TABLE dbo.pt (k int NOT NULL, j int NOT NULL, v int NOT NULL);
  CREATE CLUSTERED INDEX cx_pt ON dbo.pt (k) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_a (k);
  CREATE INDEX ix_pt_al ON dbo.pt (j) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_a (k);
  CREATE INDEX ix_pt_eq ON dbo.pt (j, v) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_b (k);
  CREATE INDEX ix_pt_fg ON dbo.pt (v) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON [PRIMARY];
  CREATE INDEX ix_pt_oth ON dbo.pt (v, j) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_c (k);
  CREATE INDEX ix_pt_col ON dbo.pt (k, j) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_a (j);
  DECLARE @n int = 300; INSERT dbo.pt (k, j, v) SELECT n, n % 250, n FROM $NUMS;
  ALTER INDEX cx_pt ON dbo.pt REBUILD PARTITION = 1 WITH (DATA_COMPRESSION = PAGE);
  CREATE TABLE dbo.pd (d datetime2(3) NOT NULL, v int NOT NULL);
  CREATE CLUSTERED INDEX cx_pd ON dbo.pd (d) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_d (d);
  CREATE TABLE dbo.pm (m money NOT NULL, v int NOT NULL);
  CREATE CLUSTERED INDEX cx_pm ON dbo.pm (m) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_m (m);
  CREATE TABLE dbo.pdt (t datetime NOT NULL); CREATE CLUSTERED INDEX cx_pdt ON dbo.pdt (t) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_t (t);
  CREATE TABLE dbo.pvs (s varchar(10) NOT NULL); CREATE CLUSTERED INDEX cx_pvs ON dbo.pvs (s) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_s (s);
  CREATE TABLE dbo.pdc (n decimal(9,2) NOT NULL); CREATE CLUSTERED INDEX cx_pdc ON dbo.pdc (n) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE) ON ps_n (n);
  CREATE TABLE dbo.xg (id int NOT NULL CONSTRAINT pk_xg PRIMARY KEY CLUSTERED, doc xml NULL, geo geography NULL);
  INSERT dbo.xg (id, doc, geo) VALUES (1, N'<a>1</a>', geography::Point(47.6, -122.3, 4326));
  CREATE PRIMARY XML INDEX px_xg ON dbo.xg (doc);
  CREATE SPATIAL INDEX sx_xg ON dbo.xg (geo);" pgvr
# X4: a system-versioned table and its history table with a nonclustered index of its own
sqok "A: the temporal table" "CREATE TABLE dbo.tt (id int NOT NULL CONSTRAINT pk_tt PRIMARY KEY CLUSTERED, v int NOT NULL,
    vf datetime2 GENERATED ALWAYS AS ROW START NOT NULL, vt datetime2 GENERATED ALWAYS AS ROW END NOT NULL, PERIOD FOR SYSTEM_TIME (vf, vt))
  WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.tt_hist));
  CREATE INDEX ix_tt_hist_v ON dbo.tt_hist (v) WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
  INSERT dbo.tt (id, v) VALUES (1, 1); UPDATE dbo.tt SET v = 2 WHERE id = 1;" pgvr
# X5: a two-column foreign key declared (y, x), and a disabled one
sqok "A: the foreign keys" "CREATE TABLE dbo.fp (a int NOT NULL, b int NOT NULL, CONSTRAINT pk_fp PRIMARY KEY (a, b));
  CREATE TABLE dbo.fs (id int NOT NULL CONSTRAINT pk_fs PRIMARY KEY);
  CREATE TABLE dbo.fc (id int NOT NULL CONSTRAINT pk_fc PRIMARY KEY, x int NOT NULL, y int NOT NULL, z int NULL,
    CONSTRAINT fk_fc_fp FOREIGN KEY (y, x) REFERENCES dbo.fp (a, b), CONSTRAINT fk_fc_dis FOREIGN KEY (z) REFERENCES dbo.fs (id));
  ALTER TABLE dbo.fc NOCHECK CONSTRAINT fk_fc_dis;" pgvr
# X6: a clustered columnstore table of string, uniqueidentifier and int columns, its rows compressed at the build
sqok "A: the columnstore table" "CREATE TABLE dbo.cs_t (id int NOT NULL, s nvarchar(40) NOT NULL, u uniqueidentifier NOT NULL);
  DECLARE @n int = 5000; INSERT dbo.cs_t (id, s, u) SELECT n, N'v-' + CAST(n AS nvarchar(10)), NEWID() FROM $NUMS;
  CREATE CLUSTERED COLUMNSTORE INDEX cci_cs_t ON dbo.cs_t;" pgvr 300
# XD / XN
sqok "A: pgvr_drop" "CREATE TABLE dbo.hd (id int NOT NULL); INSERT dbo.hd VALUES (1);
  CREATE TABLE dbo.dp (id int NOT NULL CONSTRAINT pk_dp PRIMARY KEY); CREATE TABLE dbo.dc (id int NOT NULL CONSTRAINT pk_dc PRIMARY KEY, pid int NOT NULL CONSTRAINT fk_dc_dp REFERENCES dbo.dp (id));" pgvr_drop
sqok "A: pgvr_deny" "CREATE TABLE dbo.np (id int NOT NULL CONSTRAINT pk_np PRIMARY KEY); CREATE TABLE dbo.nc (id int NOT NULL CONSTRAINT pk_nc PRIMARY KEY, pid int NOT NULL CONSTRAINT fk_nc_np REFERENCES dbo.np (id));
  CREATE TABLE dbo.nh (id int NOT NULL);
  CREATE USER [$MON] FOR LOGIN [$MON]; DENY SELECT ON sys.foreign_key_columns TO [$MON];" pgvr_deny
sqok "A: pgvr_cs (case-sensitive, not the server's collation)" "CREATE PARTITION FUNCTION Pf_Cs (int) AS RANGE RIGHT FOR VALUES (10);
  CREATE PARTITION SCHEME Ps_Cs AS PARTITION Pf_Cs ALL TO ([PRIMARY]);
  CREATE TABLE dbo.Cf (Id int NOT NULL CONSTRAINT Pk_Cf PRIMARY KEY, B int NOT NULL, C varchar(10) NULL);
  CREATE INDEX Ix_Cf ON dbo.Cf (Id) WHERE B > 0 AND C IS NOT NULL WITH (ONLINE = OFF, FILLFACTOR = 100, SORT_IN_TEMPDB = OFF, DATA_COMPRESSION = NONE);
  CREATE TABLE dbo.Ch (K int NOT NULL) ON Ps_Cs (K); INSERT dbo.Ch (K) VALUES (1), (20);" pgvr_cs
DENYREAD=$(printf 'SET NOCOUNT ON;\nGO\nSELECT COUNT(*) FROM sys.foreign_key_columns\n' | docker exec -i -e "P=$MON_PW" "$SQL" bash -c "SQLCMDPASSWORD=\$P $SQLCMD -S localhost -U $MON $TRUST -b -W -h -1 -d pgvr_deny -i /dev/stdin" 2>&1 | tr '\n' ' ')
echo "read: the monitor login's own read of sys.foreign_key_columns in pgvr_deny: ${DENYREAD:0:200}"

go build -o "$TMPD/pgvigil" ./cmd/pgvigil || fail "A: go build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null || fail "A: the repository database"
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
export PGV_R_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true&connection+timeout=20"
printf 'repository:\n  dsn: "%s"\ninstances:\n  - name: ixr\n    engine: sqlserver\n    dsn: env:PGV_R_MON\n' "$PGDSN" > "$TMPD/m.yaml"
"$TMPD/pgvigil" migrate -config "$TMPD/m.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "A: migrate"; }
col() { timeout 300 "$TMPD/pgvigil" collect -config "$TMPD/m.yaml" -instance ixr -once "$1" >"$TMPD/col-$1.out" 2>&1 || { cat "$TMPD/col-$1.out" >&2; fail "collect $1"; }; }
col mssql_instance
I=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'ixr'")
col mssql_indexes
echo "ok   A: SQL Server $VER, pgvr / pgvr_drop / pgvr_deny, instance ixr $I, read 1 of mssql_indexes"

# the base set every listing shares: user tables and indexed views, not memory-optimized
BASE="o.is_ms_shipped = 0 AND o.type IN ('U', 'V') AND NOT EXISTS (SELECT 1 FROM sys.tables mt WHERE mt.object_id = o.object_id AND mt.is_memory_optimized = 1)"
a2s=$(sq "SELECT COUNT(*) FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id WHERE i.index_id > 0 AND $BASE" pgvr)
a2p=$(pq "SELECT count(*) FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr'")
[[ -n "$a2s" && "$a2s" == "$a2p" ]] || fail "A2: the base read stored $a2p indexes of pgvr, sa counts $a2s"
echo "ok   A2: the index read stored $a2p indexes of pgvr (sa counts $a2s)"

# has <table> [column]: the table (and the column) exist in the repository
has() { if [[ -n "${2:-}" ]]; then [[ "$(pq "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'pgvigil' AND table_name = '$1' AND column_name = '$2'")" == 1 ]]
        else [[ "$(pq "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'pgvigil' AND table_name = '$1'")" == 1 ]]; fi; }
# same <row> <what> <sa file> <repository file>: the two listings sorted and compared line by line
same() { sort "$3" > "$3.s"; sort "$4" > "$4.s"
  if [[ ! -s "$3.s" ]]; then bad "$1: sa's read of $2 is empty (the fixture)"; return 1; fi
  if diff "$3.s" "$4.s" > "$TMPD/$1.diff"; then return 0; fi
  bad "$1: $2 differ from sa's read ($(grep -c '^<' "$TMPD/$1.diff") sa line(s) not matched, $(grep -c '^>' "$TMPD/$1.diff") stored line(s) not matched):"
  head -n 12 "$TMPD/$1.diff" | cut -c1-300 | sed 's/^/       /'; return 1; }
# a catalog name beside the database's own strings in one CONCAT_WS: the database's collation (else Msg 451, run d404-g1)
DD="COLLATE DATABASE_DEFAULT"
# the stored text of a value: NULL as '~', booleans as 1 / 0
N="coalesce(%s::text, '~')"
nv() { printf "$N" "$1"; }

echo "== X1. heaps =="
if ! has mssql_heap; then bad "X1: no table pgvigil.mssql_heap"; else
  sq "SELECT CONCAT_WS('|', s.name $DD, o.name $DD, ps.rc, ps.kb, ISNULL(us.user_seeks, 0), ISNULL(us.user_scans, 0), ISNULL(us.user_lookups, 0), ISNULL(us.user_updates, 0),
      ISNULL(CAST(os.ff AS varchar(20)), '~'), ISNULL(CAST(os.ld AS varchar(20)), '~'), CONVERT(varchar(19), o.create_date, 126), ds.name $DD, ds.type_desc $DD,
      ISNULL(pc.name $DD, '~'), pt.n, pt.comp $DD, pt.unc)
    FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
    JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
    CROSS APPLY (SELECT SUM(p.row_count) AS rc, SUM(p.reserved_page_count) * 8 AS kb FROM sys.dm_db_partition_stats p WHERE p.object_id = i.object_id AND p.index_id = 0) ps
    LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = 0
    OUTER APPLY (SELECT SUM(x.forwarded_fetch_count) AS ff, SUM(x.leaf_delete_count) AS ld FROM sys.dm_db_index_operational_stats(DB_ID(), i.object_id, 0, NULL) x) os
    OUTER APPLY (SELECT QUOTENAME(c.name) AS name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                  WHERE ic.object_id = i.object_id AND ic.index_id = 0 AND ic.partition_ordinal = 1) pc
    CROSS APPLY (SELECT COUNT(*) AS n, CASE WHEN MIN(p.data_compression_desc) = MAX(p.data_compression_desc) THEN MIN(p.data_compression_desc) ELSE N'MIXED' END AS comp,
                        MAX(CASE WHEN p.data_compression = 0 THEN 1 ELSE 0 END) AS unc FROM sys.partitions p WHERE p.object_id = i.object_id AND p.index_id = 0) pt
   WHERE i.index_id = 0 AND o.type = 'U' AND $BASE" pgvr > "$TMPD/x1.sa"
  pq "SELECT concat_ws('|', schema_name, table_name, $(nv row_count), $(nv size_kb), user_seeks, user_scans, user_lookups, user_updates, $(nv forwarded_fetch_count),
      $(nv leaf_delete_count), coalesce(to_char(table_created AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS'), '~'), $(nv data_space_name), $(nv data_space_type),
      $(nv partition_column), $(nv partitions), $(nv compression), $(nv 'any_uncompressed::int'))
    FROM pgvigil.mssql_heap WHERE instance_id = $I AND database_name = 'pgvr'" > "$TMPD/x1.pg" 2>"$TMPD/x1.err" || bad "X1: the stored read: $(head -c 300 "$TMPD/x1.err")"
  if same X1 "the heaps" "$TMPD/x1.sa" "$TMPD/x1.pg"; then
    f=$(pq "SELECT concat_ws('|', forwarded_fetch_count > 0, leaf_delete_count > 0) FROM pgvigil.mssql_heap WHERE instance_id = $I AND database_name = 'pgvr' AND table_name = 'h_fwd'")
    p=$(pq "SELECT concat_ws('|', data_space_name, data_space_type, partition_column, partitions, compression, any_uncompressed::int) FROM pgvigil.mssql_heap WHERE instance_id = $I AND database_name = 'pgvr' AND table_name = 'ph'")
    if [[ "$f" == "t|t" && "$p" == "ps_a|PARTITION_SCHEME|[k]|3|MIXED|1" ]]; then ok "X1: $(wc -l < "$TMPD/x1.pg") heaps equal to sa's read; h_fwd forwarded fetches and deletes > 0; ph on ps_a [k], 3 partitions, MIXED"
    else bad "X1: h_fwd forwarded > 0 | deletes > 0 = '$f' (wanted t|t); ph = '$p' (wanted ps_a|PARTITION_SCHEME|[k]|3|MIXED|1)"; fi
  fi
fi

echo "== X1b. operational counters per index =="
OPC="row_lock_wait_count row_lock_wait_ms page_lock_wait_count page_lock_wait_ms page_latch_wait_count page_latch_wait_ms page_io_latch_wait_count page_io_latch_wait_ms forwarded_fetch_count leaf_delete_count"
if ! has mssql_index row_lock_wait_count; then bad "X1b: mssql_index has no column row_lock_wait_count"; else
  sq "SELECT CONCAT_WS('|', s.name, o.name, i.name, ISNULL(CAST(x.rlc AS varchar(20)), '~'), ISNULL(CAST(x.rlm AS varchar(20)), '~'), ISNULL(CAST(x.plc AS varchar(20)), '~'),
      ISNULL(CAST(x.plm AS varchar(20)), '~'), ISNULL(CAST(x.pac AS varchar(20)), '~'), ISNULL(CAST(x.pam AS varchar(20)), '~'), ISNULL(CAST(x.pic AS varchar(20)), '~'),
      ISNULL(CAST(x.pim AS varchar(20)), '~'), ISNULL(CAST(x.ff AS varchar(20)), '~'), ISNULL(CAST(x.ld AS varchar(20)), '~'))
    FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
    OUTER APPLY (SELECT SUM(z.row_lock_wait_count) AS rlc, SUM(z.row_lock_wait_in_ms) AS rlm, SUM(z.page_lock_wait_count) AS plc, SUM(z.page_lock_wait_in_ms) AS plm,
                        SUM(z.page_latch_wait_count) AS pac, SUM(z.page_latch_wait_in_ms) AS pam, SUM(z.page_io_latch_wait_count) AS pic, SUM(z.page_io_latch_wait_in_ms) AS pim,
                        SUM(z.forwarded_fetch_count) AS ff, SUM(z.leaf_delete_count) AS ld
                   FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) z WHERE z.object_id = i.object_id AND z.index_id = i.index_id) x
   WHERE i.index_id > 0 AND $BASE" pgvr > "$TMPD/x1b.sa"
  cols=; for c in $OPC; do cols="$cols, $(nv "$c")"; done
  pq "SELECT concat_ws('|', schema_name, table_name, index_name$cols) FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr'" > "$TMPD/x1b.pg" 2>"$TMPD/x1b.err" \
    || bad "X1b: the stored read: $(head -c 300 "$TMPD/x1b.err")"
  if same X1b "the operational counters" "$TMPD/x1b.sa" "$TMPD/x1b.pg"; then
    l=$(pq "SELECT concat_ws('|', row_lock_wait_count >= 1, row_lock_wait_ms >= 2000) FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr' AND index_name = 'pk_lk'")
    if [[ "$l" == "t|t" ]]; then ok "X1b: $(wc -l < "$TMPD/x1b.pg") indexes' counters equal to sa's read; pk_lk's row lock wait counted (>= 1, >= 2000 ms)"
    else bad "X1b: pk_lk row_lock_wait_count >= 1 | ms >= 2000 = '$l' (wanted t|t)"; fi
  fi
fi

echo "== X2. table shape =="
SHAPE_SA="FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id LEFT JOIN sys.tables tb ON tb.object_id = o.object_id
    CROSS APPLY (SELECT COUNT(*) AS n, SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END) AS nonlob, SUM(CASE WHEN c.max_length = -1 THEN 1 ELSE 0 END) AS lob,
                        SUM(CASE WHEN t.name IN ('varchar', 'nvarchar', 'char') OR c.max_length = -1 THEN 1 ELSE 0 END) AS str, MAX(CAST(c.is_sparse AS int)) AS sp,
                        MAX(CASE WHEN c.system_type_id IN (34, 35, 99) THEN 1 ELSE 0 END) AS ti
                   FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE c.object_id = o.object_id) c
    OUTER APPLY (SELECT SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END) AS kb, COUNT(*) AS kc
                   FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                  WHERE ic.object_id = o.object_id AND ic.index_id = 1 AND ic.key_ordinal > 0 HAVING COUNT(*) > 0) k
   WHERE $BASE AND (o.type = 'U' OR EXISTS (SELECT 1 FROM sys.indexes iv WHERE iv.object_id = o.object_id AND iv.index_id = 1))"
if ! has mssql_table_shape; then bad "X2: no table pgvigil.mssql_table_shape"; else
  sq "SELECT CONCAT_WS('|', s.name $DD, o.name $DD, RTRIM(o.type) $DD, c.n, c.nonlob, c.lob, c.str, c.sp, c.ti, ISNULL(CAST(k.kb AS varchar(20)), '~'), ISNULL(CAST(k.kc AS varchar(20)), '~')) $SHAPE_SA" pgvr > "$TMPD/x2.sa"
  pq "SELECT concat_ws('|', schema_name, table_name, object_type, $(nv total_columns), $(nv nonlob_bytes), $(nv lob_columns), $(nv string_columns), $(nv 'has_sparse::int'),
      $(nv 'has_text_image::int'), $(nv cx_key_bytes), $(nv cx_key_columns)) FROM pgvigil.mssql_table_shape WHERE instance_id = $I AND database_name = 'pgvr'" > "$TMPD/x2.pg" 2>"$TMPD/x2.err" \
    || bad "X2: the stored read: $(head -c 300 "$TMPD/x2.err")"
  if same X2 "the table shapes" "$TMPD/x2.sa" "$TMPD/x2.pg"; then
    w=$(pq "SELECT string_agg(concat_ws(':', table_name, object_type, total_columns, nonlob_bytes, string_columns, has_sparse::int, has_text_image::int, lob_columns, cx_key_columns, cx_key_bytes), ' ' ORDER BY table_name)
              FROM pgvigil.mssql_table_shape WHERE instance_id = $I AND database_name = 'pgvr' AND table_name IN ('wide', 'ck4', 'v_iv', 'v_plain')")
    # by hand from the DDL (review B1): ck4 7 columns, 4+4+4+8+80+10+20 = 130 bytes, s and ch strings (nchar not, BI L5708);
    # v_iv 2 / 8 / 0; wide 37 columns, 4 + 33 x 4 + 4 + 0 (max) + 16 (text) = 156 bytes, lob alone a string (text is not, by BI's test)
    if [[ "$w" == "ck4:U:7:130:2:0:0:0:4:20 v_iv:V:2:8:0:0:0:0:1:4 wide:U:37:156:1:1:1:1:1:4" ]]; then ok "X2: $(wc -l < "$TMPD/x2.pg") tables and indexed views equal to sa's read; $w; v_plain not stored"
    else bad "X2: the fixed rows read '$w' (wanted 'ck4:U:7:130:2:0:0:0:4:20 v_iv:V:2:8:0:0:0:0:1:4 wide:U:37:156:1:1:1:1:1:4')"; fi
  fi
fi

echo "== X3. data spaces and object type =="
if ! has mssql_index object_type; then bad "X3: mssql_index has no column object_type"; else
  sq "SELECT CONCAT_WS('|', s.name $DD, o.name $DD, i.name $DD, RTRIM(o.type) $DD, ISNULL(ds.name $DD, '~'), ISNULL(ds.type_desc $DD, '~'), ISNULL(pf.name $DD, '~'), ISNULL(pf.t $DD, '~'),
      ISNULL(CAST(pf.fanout AS varchar(10)), '~'), ISNULL(pf.r $DD, '~'), ISNULL(pc.name $DD, '~'), ISNULL(CAST(pt.unc AS varchar(1)), '~'))
    FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
    LEFT JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
    OUTER APPLY (SELECT f.name, f.fanout,
                        TYPE_NAME(pp.user_type_id) + CASE WHEN TYPE_NAME(pp.system_type_id) IN ('datetime2', 'time', 'datetimeoffset') THEN '(' + CAST(pp.scale AS varchar(3)) + ')'
                          WHEN TYPE_NAME(pp.system_type_id) IN ('varchar', 'char', 'varbinary', 'binary') THEN '(' + CAST(pp.max_length AS varchar(10)) + ')'
                          WHEN TYPE_NAME(pp.system_type_id) IN ('decimal', 'numeric') THEN '(' + CAST(pp.precision AS varchar(3)) + ',' + CAST(pp.scale AS varchar(3)) + ')' ELSE '' END AS t,
                        'RANGE ' + CASE WHEN f.boundary_value_on_right = 1 THEN 'RIGHT' ELSE 'LEFT' END + ' FOR VALUES ('
                          + (SELECT STRING_AGG(CAST(CASE SQL_VARIANT_PROPERTY(v.value, 'BaseType') WHEN 'datetime2' THEN CONVERT(nvarchar(40), CAST(v.value AS datetime2(7)), 121)
                                                         WHEN 'datetime' THEN CONVERT(nvarchar(40), CAST(v.value AS datetime), 121)
                                                         WHEN 'varchar' THEN '''' + CAST(v.value AS nvarchar(4000)) + ''''
                                                         WHEN 'money' THEN CONVERT(nvarchar(40), CAST(v.value AS money), 2) ELSE CAST(v.value AS nvarchar(4000)) END AS nvarchar(max)), N', ')
                                      WITHIN GROUP (ORDER BY v.boundary_id) FROM sys.partition_range_values v WHERE v.function_id = f.function_id) + ')' AS r
                   FROM sys.partition_schemes sch JOIN sys.partition_functions f ON f.function_id = sch.function_id
                   JOIN sys.partition_parameters pp ON pp.function_id = f.function_id AND pp.parameter_id = 1 WHERE sch.data_space_id = i.data_space_id) pf
    OUTER APPLY (SELECT QUOTENAME(c.name) AS name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                  WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.partition_ordinal = 1) pc
    CROSS APPLY (SELECT MAX(CASE WHEN p.data_compression = 0 THEN 1 ELSE 0 END) AS unc FROM sys.partitions p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) pt
   WHERE i.index_id > 0 AND $BASE" pgvr > "$TMPD/x3.sa"
  pq "SELECT concat_ws('|', schema_name, table_name, index_name, $(nv object_type), $(nv data_space_name), $(nv data_space_type), $(nv partition_function), $(nv pf_type),
      $(nv pf_partitions), $(nv pf_range), $(nv partition_column), $(nv 'any_uncompressed::int')) FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr'" \
    > "$TMPD/x3.pg" 2>"$TMPD/x3.err" || bad "X3: the stored read: $(head -c 300 "$TMPD/x3.err")"
  if same X3 "the data spaces" "$TMPD/x3.sa" "$TMPD/x3.pg"; then
    w=$(pq "SELECT string_agg(concat_ws(':', index_name, object_type, data_space_name, data_space_type, partition_function, pf_type, pf_range, compression, any_uncompressed::int), ' ' ORDER BY index_name)
              FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr' AND index_name IN ('ix_pt_fg', 'ix_pt_eq', 'cx_pt', 'cx_pd', 'cx_pm', 'cx_pdt', 'cx_pvs', 'cx_pdc', 'cx_v_iv')")
    want="cx_pd:U:ps_d:PARTITION_SCHEME:pf_d:datetime2(3):RANGE LEFT FOR VALUES (2026-01-01 00:00:00.0000000):NONE:1 cx_pdc:U:ps_n:PARTITION_SCHEME:pf_n:decimal(9,2):RANGE RIGHT FOR VALUES (10.50):NONE:1 cx_pdt:U:ps_t:PARTITION_SCHEME:pf_t:datetime:RANGE LEFT FOR VALUES (2026-01-31 23:59:59.997):NONE:1 cx_pm:U:ps_m:PARTITION_SCHEME:pf_m:money:RANGE RIGHT FOR VALUES (1.2345):NONE:1 cx_pt:U:ps_a:PARTITION_SCHEME:pf_a:int:RANGE RIGHT FOR VALUES (100, 200):MIXED:1 cx_pvs:U:ps_s:PARTITION_SCHEME:pf_s:varchar(10):RANGE LEFT FOR VALUES ('m'):NONE:1 cx_v_iv:V:PRIMARY:ROWS_FILEGROUP:NONE:1 ix_pt_eq:U:ps_b:PARTITION_SCHEME:pf_b:int:RANGE RIGHT FOR VALUES (100, 200):NONE:1 ix_pt_fg:U:PRIMARY:ROWS_FILEGROUP:NONE:1"
    xs=$(pq "SELECT string_agg(concat_ws(':', index_name, index_type, coalesce(data_space_name, '~'), coalesce(data_space_type, '~'), coalesce(any_uncompressed::int::text, '~')), ' ' ORDER BY index_name)
              FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr' AND index_name IN ('px_xg', 'sx_xg')")
    echo "read: the XML and spatial indexes as stored (equal to sa's read above; no fixed value was known before the run): $xs"
    if [[ "$w" == "$want" ]]; then ok "X3: $(wc -l < "$TMPD/x3.pg") indexes' data spaces equal to sa's read (XML and spatial included); the fixed rows as wanted"
    else bad "X3: the fixed rows read '$w'"; echo "       wanted '$want'"; fi
  fi
fi

echo "== X4. temporal tables =="
if ! has mssql_table_shape temporal_type; then bad "X4: no table pgvigil.mssql_table_shape (temporal_type)"; else
  sq "SELECT CONCAT_WS('|', s.name, o.name, ISNULL(CAST(tb.temporal_type AS varchar(3)), '~'), ISNULL(CAST(tb.history_table_id AS varchar(20)), '~')) $SHAPE_SA" pgvr > "$TMPD/x4.sa"
  pq "SELECT concat_ws('|', schema_name, table_name, $(nv temporal_type), $(nv history_table_id)) FROM pgvigil.mssql_table_shape WHERE instance_id = $I AND database_name = 'pgvr'" \
    > "$TMPD/x4.pg" 2>"$TMPD/x4.err" || bad "X4: the stored read: $(head -c 300 "$TMPD/x4.err")"
  if same X4 "the temporal types" "$TMPD/x4.sa" "$TMPD/x4.pg"; then
    h=$(sq "SELECT OBJECT_ID('dbo.tt_hist')" pgvr)
    w=$(pq "SELECT string_agg(concat_ws(':', table_name, temporal_type, coalesce(history_table_id::text, '-')), ' ' ORDER BY table_name) FROM pgvigil.mssql_table_shape
              WHERE instance_id = $I AND database_name = 'pgvr' AND table_name IN ('tt', 'tt_hist', 'h_fwd')")
    if [[ "$w" == "h_fwd:0:- tt:2:$h tt_hist:1:-" ]]; then ok "X4: $(wc -l < "$TMPD/x4.pg") rows' temporal types equal to sys.tables; $w"
    else bad "X4: the fixed rows read '$w' (wanted 'h_fwd:0:- tt:2:$h tt_hist:1:-')"; fi
  fi
fi

echo "== X5. foreign keys =="
FK_SA="SELECT CONCAT_WS('|', fk.name, OBJECT_SCHEMA_NAME(fk.parent_object_id), OBJECT_NAME(fk.parent_object_id), OBJECT_SCHEMA_NAME(fk.referenced_object_id), OBJECT_NAME(fk.referenced_object_id),
      (SELECT STRING_AGG(QUOTENAME(c.name), ',') WITHIN GROUP (ORDER BY k.constraint_column_id) FROM sys.foreign_key_columns k
         JOIN sys.columns c ON c.object_id = k.parent_object_id AND c.column_id = k.parent_column_id WHERE k.constraint_object_id = fk.object_id))
    FROM sys.foreign_keys fk WHERE fk.is_disabled = 0 AND fk.is_ms_shipped = 0"
if ! has mssql_fk_columns; then bad "X5: no table pgvigil.mssql_fk_columns"; else
  sq "$FK_SA" pgvr > "$TMPD/x5.sa"
  pq "SELECT concat_ws('|', fk_name, parent_schema, parent_table, ref_schema, ref_table, array_to_string(columns, ',')) FROM pgvigil.mssql_fk_columns WHERE instance_id = $I AND database_name = 'pgvr'" \
    > "$TMPD/x5.pg" 2>"$TMPD/x5.err" || bad "X5: the stored read: $(head -c 300 "$TMPD/x5.err")"
  if same X5 "the foreign keys" "$TMPD/x5.sa" "$TMPD/x5.pg"; then
    w=$(pq "SELECT coalesce(string_agg(concat_ws(':', fk_name, array_to_string(columns, ',')), ' ' ORDER BY fk_name), '') FROM pgvigil.mssql_fk_columns
              WHERE instance_id = $I AND database_name = 'pgvr' AND fk_name IN ('fk_fc_fp', 'fk_fc_dis')")
    if [[ "$w" == "fk_fc_fp:[y],[x]" ]]; then ok "X5: $(wc -l < "$TMPD/x5.pg") enabled foreign keys equal to sa's read; fk_fc_fp [y],[x]; fk_fc_dis not stored"
    else bad "X5: the fixed rows read '$w' (wanted 'fk_fc_fp:[y],[x]')"; fi
  fi
fi

echo "== X6. filter columns and columnstore segments =="
if ! has mssql_index filter_columns; then bad "X6: mssql_index has no column filter_columns"; else
  sq "SELECT CONCAT_WS('|', s.name, o.name, i.name, ISNULL((SELECT STRING_AGG(QUOTENAME(c.name), ',') WITHIN GROUP (ORDER BY c.name)
         FROM sys.sql_expression_dependencies d JOIN sys.columns c ON c.object_id = d.referenced_id AND c.column_id = d.referenced_minor_id
        WHERE d.referencing_class = 7 AND d.referenced_class = 1 AND d.referenced_id = i.object_id AND d.referencing_minor_id = i.index_id), '~'))
    FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
   WHERE i.index_id > 0 AND i.has_filter = 1 AND $BASE" pgvr > "$TMPD/x6a.sa"
  pq "SELECT concat_ws('|', schema_name, table_name, index_name, coalesce(array_to_string(filter_columns, ','), '~')) FROM pgvigil.mssql_index
       WHERE instance_id = $I AND database_name = 'pgvr' AND has_filter" > "$TMPD/x6a.pg" 2>"$TMPD/x6a.err" || bad "X6: the stored read: $(head -c 300 "$TMPD/x6a.err")"
  sq "SELECT CONCAT_WS('|', s.name, o.name, i.name, ISNULL((SELECT STRING_AGG(QUOTENAME(q.name), ',') WITHIN GROUP (ORDER BY q.name) FROM (
           SELECT DISTINCT c.name FROM sys.column_store_segments seg JOIN sys.partitions p ON seg.partition_id = p.partition_id
             JOIN sys.index_columns ic ON ic.object_id = p.object_id AND ic.index_id = p.index_id AND ic.index_column_id = seg.column_id
             JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
             JOIN sys.types t ON c.system_type_id = t.system_type_id AND t.user_type_id = t.system_type_id
            WHERE p.object_id = i.object_id AND p.index_id = i.index_id AND seg.row_count > 0 AND seg.min_deep_data IS NULL AND seg.max_deep_data IS NULL
              AND ((t.name IN (N'char', N'varchar', N'nchar', N'nvarchar', N'binary', N'varbinary') AND c.max_length <> -1) OR t.name = N'uniqueidentifier'
                   OR (t.name = N'datetimeoffset' AND c.scale > 2))) q), ''))
    FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = o.schema_id
   WHERE i.type IN (5, 6) AND $BASE" pgvr > "$TMPD/x6b.sa"
  pq "SELECT concat_ws('|', schema_name, table_name, index_name, coalesce(array_to_string(cs_rebuild_columns, ','), '~')) FROM pgvigil.mssql_index
       WHERE instance_id = $I AND database_name = 'pgvr' AND index_type LIKE '%COLUMNSTORE'" > "$TMPD/x6b.pg" 2>>"$TMPD/x6a.err" || bad "X6: the stored segments: $(head -c 300 "$TMPD/x6a.err")"
  if same X6 "the filter columns" "$TMPD/x6a.sa" "$TMPD/x6a.pg" && same X6 "the columnstore columns needing a rebuild" "$TMPD/x6b.sa" "$TMPD/x6b.pg"; then
    f=$(pq "SELECT array_to_string(filter_columns, ',') FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr' AND index_name = 'ix_f'")
    c=$(pq "SELECT coalesce(array_to_string(cs_rebuild_columns, ','), 'NULL') FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr' AND index_name = 'cci_cs_t'")
    r=$(pq "SELECT count(*) FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr' AND index_type NOT LIKE '%COLUMNSTORE' AND cs_rebuild_columns IS NOT NULL")
    if [[ "$f" == "[b],[c]" && "$c" == "" && "$r" == 0 ]]; then ok "X6: $(wc -l < "$TMPD/x6a.pg") filtered and $(wc -l < "$TMPD/x6b.pg") columnstore indexes equal to sa's read; ix_f [b],[c]; cci_cs_t none to rebuild (read); rowstore NULL"
    else bad "X6: ix_f '$f' (wanted [b],[c]); cci_cs_t '$c' (wanted empty, read); rowstore indexes with a value: $r (wanted 0)"; fi
  fi
fi

echo "== XD. a dropped database / XN. a part that fails =="
xd1=; if has mssql_heap && has mssql_table_shape && has mssql_fk_columns; then
  xd1=$(pq "SELECT concat_ws('|', (SELECT count(*) FROM pgvigil.mssql_heap WHERE instance_id = $I AND database_name = 'pgvr_drop'),
                (SELECT count(*) FROM pgvigil.mssql_table_shape WHERE instance_id = $I AND database_name = 'pgvr_drop'),
                (SELECT count(*) FROM pgvigil.mssql_fk_columns WHERE instance_id = $I AND database_name = 'pgvr_drop'))"); fi
# XN is read at read 1 (pgvr_deny stays through read 2 too)
if ! has mssql_index_parts; then bad "XN: no table pgvigil.mssql_index_parts"; else
  ns=$(sq "SELECT COUNT(*) FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id WHERE i.index_id > 0 AND $BASE" pgvr_deny)
  np=$(pq "SELECT count(*) FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr_deny'")
  nr=$(pq "SELECT concat_ws('|', 'fks' = ANY (parts_read), 'heaps' = ANY (parts_read), 'shape' = ANY (parts_read), note ILIKE '%foreign key%' AND note ILIKE '%denied%')
             FROM pgvigil.mssql_index_parts WHERE instance_id = $I AND database_name = 'pgvr_deny'")
  nn=$(pq "SELECT note FROM pgvigil.mssql_index_parts WHERE instance_id = $I AND database_name = 'pgvr_deny'")
  nf=$(pq "SELECT count(*) FROM pgvigil.mssql_fk_columns WHERE instance_id = $I AND database_name = 'pgvr_deny'" 2>/dev/null || echo '?')
  pr=$(pq "SELECT array_to_string(ARRAY(SELECT unnest(parts_read) ORDER BY 1), ',') FROM pgvigil.mssql_index_parts WHERE instance_id = $I AND database_name = 'pgvr'")
  st=$(pq "SELECT concat_ws('|', status, note LIKE '%the foreign keys of 1 database(s) were not read (pgvr_deny)%') FROM pgvigil.collection_dates
             WHERE instance_id = $I AND collection = 'mssql_indexes' ORDER BY snapshot_at DESC LIMIT 1")
  if [[ "$np" == "$ns" && "$np" -gt 0 && "$nr" == "f|t|t|t" && "$nf" == 0 && "$pr" == "fks,heaps,ixextra,segments,shape" && "$st" == "partial|t" ]]; then
    ok "XN: pgvr_deny's $np indexes stored, its foreign keys not read ('${nn:0:160}'), no fk row; pgvr's parts $pr; the run partial"
  else bad "XN: pgvr_deny indexes $np (sa $ns); fks|heaps|shape|note = '$nr' (wanted f|t|t|t); fk rows $nf (wanted 0); pgvr's parts '$pr' (wanted fks,heaps,ixextra,segments,shape); run state|note '$st' (wanted partial|t); note '${nn:0:200}'"; fi
  cs=$(pq "SELECT concat_ws('|', (SELECT array_to_string(ARRAY(SELECT unnest(parts_read) ORDER BY 1), ',') FROM pgvigil.mssql_index_parts WHERE instance_id = $I AND database_name = 'pgvr_cs'),
                (SELECT array_to_string(filter_columns, ',') FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr_cs' AND index_name = 'Ix_Cf'),
                (SELECT concat_ws(' ', data_space_name, partition_column) FROM pgvigil.mssql_heap WHERE instance_id = $I AND database_name = 'pgvr_cs' AND table_name = 'Ch'))")
  if [[ "$cs" == "fks,heaps,ixextra,segments,shape|[B],[C]|Ps_Cs [K]" ]]; then ok "XC: pgvr_cs (Latin1_General_CS_AS): every part read, Ix_Cf [B],[C], Ch on Ps_Cs [K]"
  else bad "XC: pgvr_cs parts|Ix_Cf filter|Ch = '$cs' (wanted 'fks,heaps,ixextra,segments,shape|[B],[C]|Ps_Cs [K]')"; fi
fi
sqok "XD: drop pgvr_drop" "ALTER DATABASE pgvr_drop SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE pgvr_drop;"
col mssql_indexes
if [[ -z "$xd1" ]]; then bad "XD: the new tables are absent"; else
  xd2=$(pq "SELECT concat_ws('|', (SELECT count(*) FROM pgvigil.mssql_heap WHERE instance_id = $I AND database_name = 'pgvr_drop'),
                (SELECT count(*) FROM pgvigil.mssql_table_shape WHERE instance_id = $I AND database_name = 'pgvr_drop'),
                (SELECT count(*) FROM pgvigil.mssql_fk_columns WHERE instance_id = $I AND database_name = 'pgvr_drop'),
                (SELECT count(*) FROM pgvigil.mssql_index_parts WHERE instance_id = $I AND database_name = 'pgvr_drop'),
                (SELECT count(*) FROM pgvigil.mssql_index WHERE instance_id = $I AND database_name = 'pgvr_drop'))")
  if [[ "$xd1" == "1|3|1" && "$xd2" == "0|0|0|0|0" ]]; then ok "XD: pgvr_drop's heap, 3 shapes and foreign key stored at read 1; none left after its drop and read 2"
  else bad "XD: heaps|shapes|fks at read 1 '$xd1' (wanted 1|3|1); heaps|shapes|fks|parts|indexes after the drop '$xd2' (wanted 0|0|0|0|0)"; fi
fi

echo "== XA. the API =="
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$TMPD/m.yaml" "$USR" >/dev/null 2>&1 || fail "XA: user add"
WPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$WPORT"
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
"$TMPD/pgvigil" serve -config "$TMPD/m.yaml" -listen "127.0.0.1:$WPORT" >"$TMPD/serve.out" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.out" >&2; fail "XA: serve exited"; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "XA: the API login"
code=$(curl -s -o "$TMPD/ix.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' "$U/api/mssql/indexes?instance=$I")
xa=$(python3 - "$TMPD/ix.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# each part is a table {columns: [...], rows: [[...], ...]} (web/src/api.ts rowsOf)
cols = lambda t: (t or {}).get('columns') or []
heaps = d.get('heaps')
want = ['object_type', 'data_space_name', 'data_space_type', 'partition_function', 'table_created', 'row_lock_wait_count', 'forwarded_fetch_count']
miss = [k for k in want if k not in cols(d.get('indexes'))]
print('%s|%s|%s' % ('none' if heaps is None else len(heaps.get('rows') or []), ','.join(miss) or '-', 'yes' if 'parts_note' in cols(d.get('databases')) else 'no'))
PY
)
hc=$(pq "SELECT count(*) FROM pgvigil.mssql_heap WHERE instance_id = $I" 2>/dev/null || echo none)
if [[ "$code" == 200 && "$xa" == "$hc|-|yes" ]]; then ok "XA: GET /api/mssql/indexes answers $hc heaps, the indexes' new columns and the databases' parts_note"
else bad "XA: code $code; heaps|missing index keys|parts_note = '$xa' (wanted '$hc|-|yes')"; fi

echo "== XS. the page =="
if [[ -z "${PGVIGIL_SHOTS:-}" ]] || ! command -v chromium >/dev/null || ! command -v node >/dev/null; then echo "XS not run (PGVIGIL_SHOTS unset, or no chromium / node here)"
else
  mkdir -p "$PGVIGIL_SHOTS"; CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  chromium --headless=new --no-sandbox --disable-gpu --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chr" about:blank >"$TMPD/chr.out" 2>&1 & BG+=($!)
  for _ in $(seq 1 100); do curl -s "http://127.0.0.1:$CDP/json" >/dev/null 2>&1 && break; sleep 0.1; done
  cat > "$TMPD/shot.mjs" <<'JS'
const [cdp, url, jar, out] = process.argv.slice(2);
const fs = await import('node:fs');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${cdp}/json`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map();
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => (await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true })).result?.result?.value;
await send('Network.enable'); await send('Page.enable');
// the session cookie curl received at the API login (Netscape format; '#HttpOnly_' marks an HttpOnly one)
for (const line of fs.readFileSync(jar, 'utf8').split('\n')) {
  const f = line.replace(/^#HttpOnly_/, '').split('\t');
  if (f.length < 7 || line.startsWith('# ')) continue;
  await send('Network.setCookie', { name: f[5], value: f[6], domain: f[0], path: f[2], httpOnly: line.startsWith('#HttpOnly_') });
}
const res = {};
for (const scheme of ['light', 'dark']) {
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await send('Page.navigate', { url });
  let got = null;
  for (let i = 0; i < 200 && !got; i++) { await sleep(100); got = await ev(`[...document.querySelectorAll('h3')].some(h => h.textContent.startsWith('Heaps')) || null`); }
  await sleep(500);
  res[scheme] = await ev(`(() => {
    const h = [...document.querySelectorAll('h3')].find(x => x.textContent.startsWith('Heaps'));
    let rows = -1, n = h;
    for (let k = 0; k < 4 && n && rows < 0; k++) { n = n.nextElementSibling; const t = n && (n.matches('table') ? n : n.querySelector('table')); if (t) rows = t.querySelectorAll('tbody tr').length; }
    const cells = [...document.querySelectorAll('td')].map(td => td.textContent.trim());
    const heads = [...document.querySelectorAll('th')].map(th => th.textContent.trim());
    return { heaps: h ? rows : null, view: cells.includes('indexed view'), scheme: cells.includes('ps_a ([k])'), partsHead: heads.includes('read notes'),
             denyWords: cells.some(c => c.includes('foreign keys: not read')), title: h ? h.textContent : '' };
  })()`);
  const height = await ev('document.documentElement.scrollHeight');
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: Math.min(height || 900, 12000), deviceScaleFactor: 1, mobile: false });
  await sleep(300);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${out}/d404-mssqlindexes-${scheme}.png`, Buffer.from(shot.result.data, 'base64'));
}
console.log(JSON.stringify(res));
process.exit(0);
JS
  xs=$(timeout 120 node "$TMPD/shot.mjs" "$CDP" "$U/#/mssqlindexes?i=$I" "$TMPD/cj" "$PGVIGIL_SHOTS" 2>&1 | tail -1)
  want="{\"heaps\":$hc,\"view\":true,\"scheme\":true,\"partsHead\":true,\"denyWords\":true,\"title\":\"Heaps ($hc)\"}"
  if [[ "$xs" == "{\"light\":$want,\"dark\":$want}" ]]; then ok "XS: the page in both schemes: Heaps ($hc rows), 'indexed view', 'ps_a ([k])', 'read notes' with pgvr_deny's words; pictures in $PGVIGIL_SHOTS"
  else bad "XS: the page read '${xs:0:600}'"; echo "       wanted {light, dark} each $want"; fi
fi

echo "PROOF-D404: $NOK ok, $NF FAIL (SQL Server $VER)"
[[ $NF == 0 ]]
