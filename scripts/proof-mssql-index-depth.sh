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
