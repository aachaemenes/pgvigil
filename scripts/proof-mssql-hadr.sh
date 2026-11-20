#!/usr/bin/env bash
# Proof of SQL Server HA/DR, Agent jobs and backups (task 98; migration 0066, internal/mssql/{ag,mirroring,logshipping,
# replication,jobs,backups}.go, the /api/mssql/availability, /api/mssql/jobs and /api/mssql/backups pages).
#
# Needs: docker with TWO SQL Server containers that share one availability group (PGVIGIL_MSSQL_CONTAINER, default
# mssql-sandbox, the primary, on PGVIGIL_MSSQL_ADDR, default localhost:1433; PGVIGIL_MSSQL_CONTAINER2, default
# mssql-sandbox2, a secondary, on PGVIGIL_MSSQL_ADDR2, default 127.0.0.1:1434; the group PGVIGIL_MSSQL_AG, default
# ag_sandbox, with automatic seeding), SQL Server Agent running on the first, the sa password of both in
# MSSQL_SA_PASSWORD, psql, curl, python3, a go toolchain at the repository root, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
# Needs too: more than 50 rows of SQL Server Agent job history in msdb before the run (a server in use has them, a
# new container has none). Part D expects the second jobs read to return fewer rows than the first, and the read
# starts 50 rows behind its cursor: with less history than that both reads return the same rows.
#
# What it makes, and drops at the end on every exit path (a flag per object; nothing it did not make is touched):
# its own repository database; on each node a monitoring login (VIEW SERVER STATE, VIEW ANY DEFINITION, a user in
# msdb with db_datareader) and on the first a login without msdb; its own database pgvhadr_<n> on the first node,
# which it ADDS TO THE GROUP and removes again (the group's replicas and its other databases are never touched);
# a stand-in database pgvhadrdist_<n> with empty tables in the documented shape of a distribution database; two
# Agent jobs; its own backup files under /backups and its databases' rows of msdb's backup history. It changes no
# server setting.
#
# The wiring (web.go's routes, RunOnce's thresholds call and cursor branch, repo.go's MSSQLCursor,
# config.go's mssql_thresholds): where the tree does not have it yet, the proof builds a scratch copy with exactly
# those lines and uses that binary, and says so.
#
# Expected (written before the first run):
#  A. the group read from BOTH sides as the least-privilege login. From the primary: every replica of the group (as
#     many as sa counts), the local one PRIMARY and connected, the other SECONDARY, CONNECTED and HEALTHY; as many
#     database replica rows as sa counts in sys.dm_hadr_database_replica_states; the secondary's rows carry an
#     estimated data loss (0 or more) and the last hardened time within 10 minutes of sa's own read. From the
#     secondary: the same replicas, its own SECONDARY, the other one's role NULL (a secondary cannot see it), the
#     group's primary named as the first node; only its own database replicas; no estimated data loss (it cannot
#     know). cluster_type stored as the server gives it (a clusterless group is read like any other), is_distributed
#     false. No row of the instance is partial.
#  B. backups. The proof's database, in the group, gets a full backup on the primary and a log backup ON THE
#     SECONDARY. mssql_backup_state of the primary holds the full with sa's finish time (UTC, within 2 s), sa's
#     backup_size, device disk and the file name (NOT the copy-only stream to a virtual device that automatic seeding
#     records in msdb a moment later); the judged row of the PRIMARY shows the log backup with the
#     secondary's instance name as where it ran (merged by group), replicas 2 of 2. With the defaults the database is
#     'a new database' and not judged; with the thresholds new_database_hours 0 and log_backup_minutes 0.01 from the
#     configuration, the finding 'no recent log backup' (warning) names it, its age taken at the read. A log backup
#     to NUL is stored apart (nul_at, type log), does not replace the real one, and raises 'a backup went to NUL'.
#     backup_exclude ['pgvhadr%'] from the configuration takes the database out: not judged 'excluded by the pattern',
#     no finding. An unknown threshold name in the configuration fails the run with the list of known names.
#  C. the queue. Data movement of the proof's database is suspended on the secondary: the primary's next read stores
#     is_suspended for that database replica and raises 'a database is suspended' (critical). After 150 MB of log on
#     the primary the next read stores an estimated data loss of 2 s or more for it (the primary's last commit less
#     the secondary's: it grew), and NO send queue: the DMV reports log_send_queue_size NULL for a suspended replica
#     (read on SQL Server 2022; so the growth while suspended shows as data loss, not as a queue). Reads taken back to
#     back across the RESUME then catch the catch-up: the largest send or redo queue among them is above 0 and is in
#     mssql_ag_sample; if the catch-up finishes between two reads the proof prints 'queue NOT PROVEN' for that line
#     and goes on. Within 90 s the database is SYNCHRONIZED again with both queues under 1,000 KB and no finding (it
#     drained). If the database cannot be added to the group, C prints 'queue growth NOT PROVEN' and the rest goes
#     on. The queue FINDINGS (over the threshold for 5 minutes) are proven over stubbed samples in F.
#  D. jobs. A job the proof creates that fails at its second step: stored with owner sa, enabled, its schedule's
#     name, the next run at 23:59 server time in UTC, last outcome failed; its three history rows (step 1 succeeded,
#     step 2 failed, the outcome row failed) are in mssql_job_runs; 'a job failed' (warning) names step 2 and carries
#     the step's own message text and the next run. The cursor equals the newest sysjobhistory row read and has its
#     mark; a second run reads only what was written since plus the 50 rows behind the cursor it re-checks (at most
#     sa's count of rows past the first cursor + 50) and the job still has exactly three rows. A job that waits is seen running (running_since within 60 s of sa's start time). A login
#     without a user in msdb (msdb's guest lets it in, so HAS_DBACCESS says yes): mssql_jobs is 'skipped' with 'no
#     access to msdb.dbo.sysjobs' and the missing right, nothing stored; mssql_backups and mssql_logshipping either
#     run (msdb grants some tables to public) or are skipped the same way, never an error.
#  E. mirroring, log shipping, replication on this sandbox: each collection runs as the monitoring login, reads 0
#     rows and stores nothing; the proof prints NOT PROVEN for each. Their statements are compiled by the server
#     (SET NOEXEC ON) and RUN as the monitoring login by TestHADRStatementsLive (with the backup sink and time-zone
#     tests: a seeding stream, a NUL backup and their look-alikes told apart; time_zone -32 = UTC + 8 h); the replication statements are also
#     run against the stand-in database and return its rows (one publication, one subscription with 7 undelivered
#     commands, three agents; on a tree whose replication read takes a merge agent as its subscription
#     (replMergeSubscriptions, task 385's merge rows): two subscriptions and two agents).
#  F. stubbed rows through the import functions on a stub instance: a mirrored database DISCONNECTED -> critical; a
#     log shipping secondary 3 hours behind a 45-minute threshold -> warning; a failed distribution agent and 250,000
#     undistributed commands -> two warnings; six minutes of samples with a redo queue over its threshold -> 'the
#     redo queue is over its threshold' (and no send-queue finding); a group whose primary changes between two reads
#     -> one row in mssql_ag_failovers and 'the primary of a group changed' (critical); a distributed group stored
#     as such; a database of a group with one of two replicas monitored and no backup -> info 'backups not judged',
#     never critical; a backup kept when a later read no longer lists it, also
#     when the database's creation time comes back an hour off; a backup older than its database's creation not
#     counted for it ('no full backup ever', its text saying 'created or restored <time>; no full backup since'); a failover still seen across a read that names no primary; two
#     secondaries carrying one database name kept as two rows; a replication read of which one part failed replaces
#     the parts that were read; a job history row read twice an hour apart stored once, the cursor with its mark;
#     an older read imported late changes no current state; import_mssql_ag refuses a PostgreSQL instance.
#  G. the API: /api/mssql/availability (replicas 2, the proof's failover-free window, findings), /api/mssql/jobs (the
#     failed run with step 2 and its message) and /api/mssql/backups (the proof's database row) answer 200 with
#     those rows; ?part=reads answers alone; an unknown part is 400.
#  NOT PROVEN HERE: a distributed or contained group, a listener, a Windows cluster's members (none on this
#  sandbox); a real mirrored database, log shipping pair or distributor; the sign of backupset.time_zone on a server
#  whose clock is not UTC on REAL rows (the containers run in UTC; the expression is proven over literal rows); SQL Server 2016-2019, RDS, Managed Instance.
set -euo pipefail
#
# PART S - the availability group gaps (task 382 and the tools audit's B1; migration 0143): `scripts/proof-mssql-hadr.sh
# gaps` runs it ALONE, on a lab of its own (scripts/dag/trial.sh, KEEP=1: ag1 on d1a + d1b, ag2 on d2a + d2b, both
# clusterless, the distributed group dag1 over them; image PGVIGIL_MSSQL_IMAGE, default the CU27 pin
# mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04), removed on every exit path (trial.sh down, read back).
# Needs docker, openssl, psql, python3, a go toolchain and PGVIGIL_REPO_DSN (keyword form); nothing of parts A-G.
# The collector reads each node at its address on the lab's network as a monitoring login of the run (one SID on the
# four nodes; VIEW SERVER STATE, VIEW ANY DEFINITION, a user in msdb with db_datareader).
# Expected (written before the first run):
#  S1. the lab forms ('DAG FORMED'); the login is on the four nodes, no sysadmin.
#  S2. at rest, one read per node, none partial or skipped. On d1a: ag1's two replicas with join_state as sa reads
#      sys.dm_hadr_availability_replica_cluster_states (JOINED_STANDALONE_INSTANCE), failure_condition_level and
#      health_check_timeout as sa reads sys.availability_groups, the endpoint Hadr_endpoint STARTED on 5022, the
#      AlwaysOn_health session exists / running / autostart as sa reads; quorum as sa reads sys.dm_hadr_cluster (the
#      question the design pass left open: what a clusterless Linux node answers), stored and shown, never judged
#      (cluster_type NONE); ag1 / d1b / dagdb joined, its failover readiness as sa reads (judged only for AUTOMATIC:
#      ag1 is MANUAL, so never); a seeding row of dagdb (COMPLETED) where sa's sys.dm_hadr_automatic_seeding lists
#      one; a second read gives the replica and database counter rates as numbers (0 or more). TestHADRS3StatementsLive
#      passes on d1a and d1b. Findings at rest: none of the new checks, except 'the AlwaysOn_health session is not
#      running' on exactly the nodes where sa reads it not running or not starting with the server (said either way);
#      the session is first started on d1b with STARTUP_STATE ON, so at least one node reads 1|1|1 and raises nothing.
#  S3. a lagging secondary: a row written on d1a and read until d1a's estimate for d1b is 0 s (the secondary holds the
#      newest commit: the estimate is the primary's last commit less the secondary's, so on an idle database it would
#      jump at once to the age of the last commit - seen on run 1: 54 s at the first read), then dagdb's data movement
#      suspended on d1b and a row written on d1a every few seconds; ag_data_loss set for d1a's instance at 0.25 / 0.75
#      minutes (15 / 45 s; rows of pg_thresholds inserted directly, not through the Thresholds page): each read's stored
#      estimate equals sa's own (the primary's last commit less d1b's, sys.dm_hadr_database_replica_states on d1a)
#      within 5 s; 'a secondary would lose data in a failover' on ag1 / d1b / dagdb as a warning only once two reads in
#      a row are 15 s or more, critical only once two are 45 s or more - ONE finding of that check for the secondary at
#      each read (beside 'a database is suspended', 0066's). 0118's 'AG secondary behind' is not read
#      (the release migration drops it). After RESUME, within 90 s, no data-loss finding.
#  S4. a secondary's endpoint stopped (ALTER ENDPOINT Hadr_endpoint STATE = STOPPED on d1b): d1b's read raises 'the
#      availability group endpoint is not started' (critical) and d1a's raises 'a replica is not connected' for ag1 / d1b
#      (critical) within 60 s; after STATE = STARTED both are gone within 90 s.
#  S5. a database not joined: d1b's seeding mode set to MANUAL, then pgvgj made on d1a and added to ag1, so d1b never
#      receives it (the common case: a database added on the primary and never joined on a secondary): sa on d1a reads
#      is_database_joined 0 for d1b, and d1a raises 'a database is not joined' (warning) for ag1 / d1b / pgvgj and NOT
#      'a database is not synchronizing' for it; removed from ag1, dropped, d1b's seeding mode AUTOMATIC again: gone.
#      (Rewritten after runs gaps4 / gaps5: after SET HADR OFF on a SYNCHRONIZED secondary, SQL Server's d1a still read
#      the database joined there 30 s on; gaps3's pass came from a SET HADR OFF that landed while seeding still ran.)
#  S6. a replica not joined: d2b added to ag1 on d1a (ASYNCHRONOUS_COMMIT, MANUAL, SEEDING_MODE MANUAL) and never joined
#      there: d1a raises 'a replica is not joined' (warning) for ag1 / d2b, and neither 'a replica is not connected' nor
#      'a replica is not healthy' for it; the replica removed: gone.
#  S7. read-only routing: d1a's routing list set to ('d1b') while d1b has no READ_ONLY_ROUTING_URL: 'read-only routing
#      names a replica that takes no reads' (warning) for ag1 / d1a -> d1b; d1b's URL set: gone; the list reset to NONE.
#      If SQL Server refuses a list naming a replica with no URL (it does: Msg 19404 on CU27, run gaps2), the row says so
#      and the finding is made with d1b's URL set and ALLOW_CONNECTIONS = NO instead, cleared by ALLOW_CONNECTIONS = ALL.
#  S8. a failed seeding: pgvgf exists on d1b already, then made on d1a and added to ag1 (automatic seeding): sa reads a
#      FAILED seeding on d1a and pgvigil raises 'automatic seeding failed' (warning) for ag1 / pgvgf -> d1b; removed
#      from the group: the warning gone within 90 s (a FAILED seeding is judged only while its database is in the group).
#      If SQL Server reports no FAILED row, the row says 'seeding failure NOT PROVEN' with what sa read, and so does the
#      final line.
#  S9. dagdb on d1b as sa reads its state in sys.databases (the second question of the design pass) and no log shipping
#      finding on d1b. A group's secondary database reads ONLINE, so the reader never reads it and this row cannot fail
#      on log shipping's group exclusion: that exclusion is NOT PROVEN here (it is proven over stub rows, part T); a
#      restore row of d1b, if one is ever stored, must be marked as in a group.
#  U (task 383, before S10): the HA/DR folder's AG page over d1a and d1b (TestHADRFleetProof, the handler as served).
#  U1. at rest, after a fresh read of both: each node's FLEET counts (local and remote, by state) equal sa's own counts
#      of sys.dm_hadr_database_replica_states on that node (joined to sys.availability_groups and
#      sys.availability_replicas as the collector reads it; state upper, '_' as ' '), and its stored rows' counts.
#  U2. dagdb suspended on d1b, both read: sa on d1b reads its local dagdb row 'NOT SYNCHRONIZING' (the DMV's text, with a
#      space), the stored text is the same, d1b's Not Synchronizing is 1 or more and equals the stored count; d1a's
#      Remote Not Synchronizing is 1 or more and equals its stored count. Resumed after.
#  U3. ag1 failed over by hand (FORCE_FAILOVER_ALLOW_DATA_LOSS on d1b - a group with CLUSTER_TYPE NONE takes no other
#      failover, so 'Manual' cannot occur here - and ROLE = SECONDARY on d1a), both read again until both rows are there
#      (60 s): Role Changes hold 'Became Primary' for d1b and 'No Longer Primary' for d1a on ag1. mssql_xe is read on
#      both (AlwaysOn_health, S2 started it on d1b): Failover Type 'Forced' where its DDL row is stored, else the final
#      line says 'U3 Failover Type NOT PROVEN'. U3 leaves the lab changed (ag1's primary d1b, dag1's listener URL still
#      d1a's): S10 removes it whole.
#  S10. the lab removed: 0 containers, 0 networks, 0 volumes; the repository database dropped.
#  NOT PROVEN HERE: quorum, a cluster member down and failover readiness on a Windows cluster (WSFC; task 387; a
#  clusterless group cannot be AUTOMATIC, so 'a database is not ready for automatic failover' is proven over stub rows
#  only, part T); log shipping's group exclusion on a real RESTORING group database (S9); dbachecks HADR #1-#20,
#  #22-#25, #27 (the cluster's own nodes, resources, networks and listener names: Windows only).
# PART T - 0143's rules over stub payloads: `scripts/proof-mssql-hadr.sh stubs` runs it ALONE on a fresh repository
# migrated by this tree (PGVIGIL_REPO_DSN, a superuser keyword DSN; psql and a go toolchain; nothing of SQL Server).
# It feeds the import functions the payloads a collector would send for what no lab here reaches - a Windows
# cluster's quorum and members, a failover cluster instance, PENDING / UNSYNCHRONIZED mirroring, Amazon RDS, a mirror
# re-created (its role sequence back to 1), a mirror read by a login that is not sysadmin, a log shipping copy past the
# 14-day window, a tier set alone, a group database left RESTORING, a seeding seen from either side - and the findings
# must equal the list in it line for line (written before the run), with three state lines. Its repository is dropped
# on every exit path. Expected: 'T: the findings equal the expected list ...' and 'PROOF OK (part T)'.
if [ "${1:-}" = stubs ]; then
  set -euo pipefail
  : "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of the PostgreSQL sandbox}"
  T_DB=pgvigil_s3stub_$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'); T_WORK=$(mktemp -d)
  t_cleanup() { rc=$?; psql "$PGVIGIL_REPO_DSN dbname=postgres" -XAtqc "drop database if exists $T_DB with (force)" >/dev/null 2>&1 || { echo "CLEANUP: $T_DB not dropped" >&2; [ $rc = 0 ] && rc=1; }; rm -rf "$T_WORK"; exit $rc; }
  trap t_cleanup EXIT
  CGO_ENABLED=0 go build -o "$T_WORK/pgvigil" ./cmd/pgvigil || { echo "FAIL: T: the build" >&2; exit 1; }
  psql "$PGVIGIL_REPO_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $T_DB"
  printf 'repository:\n  dsn: "%s dbname=%s"\ninstances: []\n' "$PGVIGIL_REPO_DSN" "$T_DB" > "$T_WORK/c.yaml"
  "$T_WORK/pgvigil" migrate -config "$T_WORK/c.yaml" > "$T_WORK/m.out" 2>&1 || { cat "$T_WORK/m.out"; echo "FAIL: T: the migrate" >&2; exit 1; }
  psql "$PGVIGIL_REPO_DSN dbname=$T_DB" -X -v ON_ERROR_STOP=1 -f - > "$T_WORK/t.out" 2>&1 <<'TSQL' || { cat "$T_WORK/t.out"; echo "FAIL: T: the stub rows (above)" >&2; exit 1; }
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION pg_temp.ts(p text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE m text[]; v text := p;
BEGIN
  FOR m IN SELECT regexp_matches(p, '@-([0-9]+)@', 'g') LOOP
    v := replace(v, '@-' || m[1] || '@', to_char((now() - make_interval(secs => m[1]::int)) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  END LOOP;
  RETURN v::jsonb;
END $$;
SELECT pgvigil.ensure_instance('s3ag', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') AS ag \gset
SELECT pgvigil.ensure_instance('s3mir', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') AS mir \gset
SELECT pgvigil.ensure_instance('s3rds', 'rdssqlserver', '15.0', 150000, false, '{}', 'sqlserver') AS rds \gset
SELECT pgvigil.ensure_instance('s3ls', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') AS ls \gset
SELECT pgvigil.ensure_instance('s3fci', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') AS fci \gset

-- availability groups: two reads 80 s apart
\set agrows '[{"kind":"replica","group_id":"G1","group_name":"ag1","cluster_type":"WSFC","is_distributed":0,"primary_replica":"d1a","group_health":"HEALTHY","replica_id":"R1","replica_server":"d1a","availability_mode":"SYNCHRONOUS_COMMIT","failover_mode":"AUTOMATIC","secondary_connections":"ALL","primary_connections":"READ_WRITE","read_only_routing_url":"TCP://d1a:1433","join_state":"JOINED_STANDALONE_INSTANCE","is_local":1,"role":"PRIMARY","connected_state":"CONNECTED","synchronization_health":"HEALTHY","failure_condition_level":3,"health_check_timeout_ms":30000},{"kind":"replica","group_id":"G1","group_name":"ag1","cluster_type":"WSFC","is_distributed":0,"primary_replica":"d1a","group_health":"HEALTHY","replica_id":"R2","replica_server":"d1b","availability_mode":"SYNCHRONOUS_COMMIT","failover_mode":"AUTOMATIC","secondary_connections":"NO","join_state":"JOINED_STANDALONE_INSTANCE","is_local":0,"role":"SECONDARY","connected_state":"CONNECTED","synchronization_health":"HEALTHY"},{"kind":"database","group_id":"G1","group_name":"ag1","replica_server":"d1a","database_name":"dbh","is_local":1,"is_primary_replica":1,"synchronization_state":"SYNCHRONIZED","last_commit_utc":"@-10@"},{"kind":"database","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbh","is_local":0,"is_primary_replica":0,"synchronization_state":"SYNCHRONIZED","last_hardened_utc":"@-130@"},{"kind":"database","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbc","is_local":0,"is_primary_replica":0,"synchronization_state":"SYNCHRONIZED","est_data_loss_s":400},{"kind":"db_cluster","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbj","is_failover_ready":0,"is_database_joined":0},{"kind":"db_cluster","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbr","is_failover_ready":0,"is_database_joined":1},{"kind":"db_cluster","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbh","is_failover_ready":1,"is_database_joined":1},{"kind":"routing","group_id":"G1","replica_server":"d1a","routing_priority":1,"read_only_replica":"d1b"},{"kind":"seeding","group_id":"G1","group_name":"ag1","database_name":"dbs","remote_replica":"d1b","is_source":1,"seeding_state":"FAILED","failure_state":"FAILED_AT_DESTINATION","error_code":0,"number_of_attempts":1,"start_utc":"@-600@","completion_utc":"@-590@"},{"kind":"endpoint","endpoint_name":"Hadr_endpoint","endpoint_state":"STOPPED","endpoint_role":"ALL","endpoint_port":5022},{"kind":"health_session","session_exists":1,"session_running":0,"session_autostart":1},{"kind":"cluster_member","cluster_name":"wsfc1","quorum_type":"NODE_MAJORITY","quorum_state":"FORCED_QUORUM","member_name":"node1","member_type":"CLUSTER_NODE","member_state":"UP","quorum_votes":1},{"kind":"cluster_member","cluster_name":"wsfc1","quorum_type":"NODE_MAJORITY","quorum_state":"FORCED_QUORUM","member_name":"node2","member_type":"CLUSTER_NODE","member_state":"DOWN","quorum_votes":1},{"kind":"replica_counters","counter_instance":"d1b","flow_control_ms_total":CTR1,"flow_controls_total":5,"resent_messages_total":0,"flow_control_type":272696576,"flow_controls_type":272696576,"third_type":272696576},{"kind":"db_counters","counter_instance":"dbc","db_flow_control_delay_total":0,"db_flow_controls_total":0,"redo_blocked_total":CTR2,"flow_control_type":272696576,"flow_controls_type":272696576,"third_type":272696576},{"kind":"database","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbr","is_local":0,"is_primary_replica":0,"synchronization_state":"SYNCHRONIZED"},{"kind":"db_cluster","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbz","is_failover_ready":0,"is_database_joined":1},{"kind":"database","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbz","is_local":0,"is_primary_replica":0,"synchronization_state":"SYNCHRONIZING"},{"kind":"db_cluster","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbs","is_failover_ready":0,"is_database_joined":0},{"kind":"seeding","group_id":"G1","group_name":"ag1","database_name":"dbx","remote_replica":"d1b","is_source":1,"seeding_state":"FAILED","failure_state":"FAILED_AT_DESTINATION","error_code":0,"number_of_attempts":1,"start_utc":"@-600@","completion_utc":"@-590@"},{"kind":"seeding","group_id":"G1","group_name":"ag1","database_name":"dbk","remote_replica":"d1b","is_source":1,"seeding_state":"FAILED","failure_state":"FAILED_AT_DESTINATION","error_code":0,"number_of_attempts":1,"start_utc":"@-600@","completion_utc":"@-590@"},{"kind":"db_cluster","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbk","is_failover_ready":1,"is_database_joined":1},{"kind":"database","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbk","is_local":0,"is_primary_replica":0,"synchronization_state":"SYNCHRONIZED"}]'
SELECT pgvigil.import_mssql_ag(:ag, now() - interval '100 seconds', pg_temp.ts(replace(replace(:'agrows', 'CTR1', '1000'), 'CTR2', '10')));
SELECT pgvigil.import_mssql_ag(:ag, now() - interval '20 seconds', pg_temp.ts(replace(replace(:'agrows', 'CTR1', '9000'), 'CTR2', '50')));

-- mirroring: two reads 260 s apart (the 5-minute rule) on s3mir; one read on the RDS instance
\set mirrows '[{"kind":"mirror","database_name":"m1","role":"PRINCIPAL","state":"SYNCHRONIZED","state_code":4,"role_sequence":1,"partner_instance":"p2","witness":"TCP://w:5025","witness_state":"DISCONNECTED","log_send_queue_kb":204800,"log_bytes_sent_total":SENT,"log_bytes_sent_type":272696576,"txn_delay_ms_total":DELAY,"txn_delay_type":272696576,"mirrored_write_txns_total":TXNS,"mirrored_write_txns_type":272696576},{"kind":"mirror","database_name":"m2","role":"ROLE2","state":"SYNCHRONIZED","state_code":4,"role_sequence":SEQ,"partner_instance":"p2","witness":"TCP://w:5025","witness_state":"CONNECTED"},{"kind":"mirror","database_name":"m3","role":"PRINCIPAL","state":"UNSYNCHRONIZED","state_code":5,"role_sequence":1},{"kind":"mirror","database_name":"m4","role":"PRINCIPAL","state":"SYNCHRONIZING","state_code":2,"role_sequence":1},{"kind":"mirror","database_name":"m5","role":"PRINCIPAL","state":"DISCONNECTED","state_code":1,"role_sequence":1},{"kind":"endpoint","endpoint_name":"pgv_mirroring","endpoint_state":"STOPPED","endpoint_role":"PARTNER","endpoint_port":5023},{"kind":"mirror","database_name":"m6","role":"PRINCIPAL","state":"SYNCHRONIZED","state_code":4,"role_sequence":SEQ6},{"kind":"mirror","database_name":"m7","role":"MIRROR","values_hidden":1,"redo_queue_kb":0,"database_state":"RESTORING"}]'
SELECT pgvigil.import_mssql_mirroring(:mir, now() - interval '280 seconds',
  replace(replace(replace(replace(replace(replace(:'mirrows', 'SENT', '1000000'), 'DELAY', '100'), 'TXNS', '50'), 'ROLE2', 'PRINCIPAL'), 'SEQ6', '5'), 'SEQ', '1')::jsonb);
SELECT pgvigil.import_mssql_mirroring(:mir, now() - interval '20 seconds',
  replace(replace(replace(replace(replace(replace(:'mirrows', 'SENT', '267240000'), 'DELAY', '1100'), 'TXNS', '550'), 'ROLE2', 'MIRROR'), 'SEQ6', '1'), 'SEQ', '2')::jsonb);
SELECT pgvigil.import_mssql_mirroring(:rds, now() - interval '20 seconds',
  '[{"kind":"mirror","database_name":"m1","role":"PRINCIPAL","state":"DISCONNECTED","state_code":1}]'::jsonb);

-- log shipping from restore history
SELECT pgvigil.import_mssql_logshipping(:ls, now() - interval '20 seconds', pg_temp.ts('[
 {"kind":"secondary","database_name":"LS7","secondary_server":"s3ls","primary_server":"p","primary_database":"ls7","threshold_minutes":45,"last_restored_utc":"@-90000@"},
 {"kind":"secondary","database_name":"ls12","secondary_server":"s3ls","primary_server":"p","primary_database":"ls12","threshold_minutes":45,"last_restored_utc":"@-600@"},
 {"kind":"restore","database_name":"ls1","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":0,"last_log_restore_utc":"@-180000@","last_log_backup_start_utc":"@-180600@","source_server":"p","source_database":"ls1","last_file":"f1"},
 {"kind":"restore","database_name":"ls2","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":0,"last_log_restore_utc":"@-90000@","last_log_backup_start_utc":"@-91800@","source_server":"p","source_database":"ls2","last_file":"f2"},
 {"kind":"restore","database_name":"ls3","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":1,"in_availability_group":0},
 {"kind":"restore","database_name":"ls4","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":0,"last_restore_utc":"@-259200@","last_restore_type":"D"},
 {"kind":"pair","database_name":"ls5","source_server":"p","source_database":"ls5","last_log_restore_utc":"@-7200@","log_restores":40,"last_with_recovery":0},
 {"kind":"pair","database_name":"ls13","source_server":"p","source_database":"ls13","last_log_restore_utc":"@-7200@","log_restores":1,"last_with_recovery":0},
 {"kind":"pair","database_name":"ls14","source_server":"p","source_database":"ls14","last_log_restore_utc":"@-7200@","log_restores":5,"last_with_recovery":1},
 {"kind":"restore","database_name":"ls15","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","in_availability_group":0,"last_log_restore_utc":"@-180000@","last_log_backup_start_utc":"@-180600@","source_server":"p","source_database":"ls15"},
 {"kind":"restore","database_name":"ls6","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-3600@","is_mirrored":0,"in_availability_group":0,"last_log_restore_utc":"@-3000@","last_log_backup_start_utc":"@-3600@","source_server":"p","source_database":"ls6"},
 {"kind":"restore","database_name":"ls7","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":0,"last_log_restore_utc":"@-90000@","last_log_backup_start_utc":"@-90060@","source_server":"p","source_database":"ls7"},
 {"kind":"restore","database_name":"ls8","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":1,"last_log_restore_utc":"@-180000@","last_log_backup_start_utc":"@-180600@","source_server":"p","source_database":"ls8"},
 {"kind":"restore","database_name":"ls9","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":1},
 {"kind":"restore","database_name":"ls10","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-2592000@","is_mirrored":0,"in_availability_group":0,"last_restore_utc":"@-1728000@","last_restore_type":"L"},
 {"kind":"restore","database_name":"ls11","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":0,"last_restore_utc":"@-259200@","last_restore_type":"D"},
 {"kind":"restore","database_name":"ls12","database_state":"RESTORING","is_in_standby":0,"recovery_model":"FULL","created_utc":"@-864000@","is_mirrored":0,"in_availability_group":0,"last_log_restore_utc":"@-600@","last_log_backup_start_utc":"@-90600@","source_server":"p","source_database":"ls12"}]'));

-- the failover cluster instance: two reads, the owner moves from n1 to n2, n1 then down
SELECT pgvigil.import_mssql_fci(:fci, now() - interval '80 seconds',
  '[{"kind":"node","node_name":"n1","node_status":0,"node_state":"up","is_current_owner":1,"physical_node":"n1","virtual_name":"vsql"},{"kind":"node","node_name":"n2","node_status":0,"node_state":"up","is_current_owner":0,"physical_node":"n1","virtual_name":"vsql"}]'::jsonb);
SELECT pgvigil.import_mssql_fci(:fci, now() - interval '20 seconds',
  '[{"kind":"node","node_name":"n1","node_status":1,"node_state":"down","is_current_owner":0,"physical_node":"n2","virtual_name":"vsql"},{"kind":"node","node_name":"n2","node_status":0,"node_state":"up","is_current_owner":1,"physical_node":"n2","virtual_name":"vsql"}]'::jsonb);


-- s3ag also reads a mirrored database on its one endpoint (the group's arm says the endpoint once)
SELECT pgvigil.import_mssql_mirroring(:ag, now() - interval '20 seconds',
  '[{"kind":"mirror","database_name":"m9","role":"PRINCIPAL","state":"SYNCHRONIZED","state_code":4,"role_sequence":1},{"kind":"endpoint","endpoint_name":"Hadr_endpoint","endpoint_state":"STOPPED","endpoint_role":"ALL","endpoint_port":5022}]'::jsonb);
-- s3ag2: a secondary's own read (d1b local); ag_data_loss with the critical tier alone; a seeding in progress from the destination's side
SELECT pgvigil.ensure_instance('s3ag2', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver') AS ag2 \gset
INSERT INTO pgvigil.pg_thresholds (key, level, instance_id, warn, crit, created_by, created_at) VALUES ('ag_data_loss', 'instance', :ag2, NULL, 5, 'proof', now());
\set ag2rows '[{"kind":"replica","group_id":"G1","group_name":"ag1","cluster_type":"NONE","is_distributed":0,"primary_replica":"d1a","group_health":"HEALTHY","replica_id":"R1","replica_server":"d1a","availability_mode":"SYNCHRONOUS_COMMIT","failover_mode":"MANUAL","secondary_connections":"ALL","join_state":"JOINED_STANDALONE_INSTANCE","is_local":0,"role":"PRIMARY","connected_state":"CONNECTED","synchronization_health":"HEALTHY"},{"kind":"replica","group_id":"G1","group_name":"ag1","cluster_type":"NONE","is_distributed":0,"primary_replica":"d1a","group_health":"HEALTHY","replica_id":"R2","replica_server":"d1b","availability_mode":"SYNCHRONOUS_COMMIT","failover_mode":"MANUAL","secondary_connections":"ALL","join_state":"JOINED_STANDALONE_INSTANCE","is_local":1,"role":"SECONDARY","connected_state":"CONNECTED","synchronization_health":"HEALTHY"},{"kind":"database","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbl","is_local":1,"is_primary_replica":0,"synchronization_state":"SYNCHRONIZED","est_data_loss_s":400},{"kind":"db_cluster","group_id":"G1","group_name":"ag1","replica_server":"d1b","database_name":"dbq","is_failover_ready":0,"is_database_joined":0},{"kind":"seeding","group_id":"G1","group_name":"ag1","database_name":"dbq","remote_replica":"d1a","is_source":0,"seeding_state":"SEEDING","number_of_attempts":1,"start_utc":"@-60@"}]'
SELECT pgvigil.import_mssql_ag(:ag2, now() - interval '100 seconds', pg_temp.ts(:'ag2rows'));
SELECT pgvigil.import_mssql_ag(:ag2, now() - interval '20 seconds', pg_temp.ts(:'ag2rows'));
-- s3ls: restoring_days with the critical tier alone for ls11 (database level)
INSERT INTO pgvigil.pg_thresholds (key, level, instance_id, datname, warn, crit, created_by, created_at) VALUES ('restoring_days', 'database', :ls, 'ls11', NULL, 1, 'proof', now());

\echo == findings
SELECT i.name, f.severity, f.check_name, f.object
  FROM pgvigil.mssql_hadr_findings f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.name LIKE 's3%' ORDER BY 1, 3, 4;
\echo == samples and state
SELECT 'ag replica rate' AS what, replica_server, flow_control_ms_per_s FROM pgvigil.mssql_ag_replica_sample WHERE instance_id = :ag ORDER BY snapshot_at DESC LIMIT 1;
SELECT 'mirror rates' AS what, database_name, send_rate_kb_s, txn_delay_ms FROM pgvigil.mssql_mirroring_state WHERE instance_id = :mir AND database_name = 'm1';
SELECT 'mirror role changes' AS what, database_name, old_role, new_role, old_sequence, new_sequence FROM pgvigil.mssql_mirroring_role_changes WHERE instance_id = :mir ORDER BY 2;
SELECT 'hidden mirror' AS what, database_name, role, state, values_hidden FROM pgvigil.mssql_mirroring_state WHERE instance_id = :mir AND database_name = 'm7';
-- the check: the findings equal this list line for line (written before the run), and three state lines
CREATE TEMP TABLE t_expected (name text, severity text, check_name text, object text);
INSERT INTO t_expected VALUES
 ('s3ag', 'warning', 'a cluster member is down', 'node2'),
 ('s3ag', 'warning', 'a database is not joined', 'ag1 / d1b / dbj'),
 ('s3ag', 'warning', 'a database is not joined', 'ag1 / d1b / dbs'),
 ('s3ag', 'critical', 'a database is not ready for automatic failover', 'ag1 / d1b / dbr'),
 ('s3ag', 'critical', 'a secondary would lose data in a failover', 'ag1 / d1b / dbc'),
 ('s3ag', 'warning', 'a secondary would lose data in a failover', 'ag1 / d1b / dbh'),
 ('s3ag', 'warning', 'a synchronous replica is not synchronized', 'ag1 / d1b / dbz'),
 ('s3ag', 'warning', 'automatic seeding failed', 'ag1 / dbs -> d1b'),
 ('s3ag', 'warning', 'read-only routing names a replica that takes no reads', 'ag1 / d1a -> d1b'),
 ('s3ag', 'warning', 'the AlwaysOn_health session is not running', 'AlwaysOn_health'),
 ('s3ag', 'critical', 'the availability group endpoint is not started', 'Hadr_endpoint'),
 ('s3ag', 'critical', 'the cluster has no normal quorum', 'wsfc1'),
 ('s3ag2', 'critical', 'a secondary would lose data in a failover', 'ag1 / d1b / dbl'),
 ('s3fci', 'warning', 'a cluster node is not up', 'n1'),
 ('s3fci', 'warning', 'no spare cluster node', 'vsql'),
 ('s3fci', 'critical', 'the failover cluster instance moved to another node', 'n2'),
 ('s3ls', 'warning', 'a database has been restoring for days', 'ls4'),
 ('s3ls', 'critical', 'a database has been restoring for days', 'ls10'),
 ('s3ls', 'critical', 'a database has been restoring for days', 'ls11'),
 ('s3ls', 'warning', 'a log shipping copy is missing', 'ls5 (from p.ls5)'),
 ('s3ls', 'critical', 'log restores are behind', 'ls1 (from p.ls1)'),
 ('s3ls', 'warning', 'log restores are behind', 'ls2 (from p.ls2)'),
 ('s3ls', 'warning', 'log restores are behind', 'ls12 (from p.ls12)'),
 ('s3ls', 'warning', 'log shipping is behind its threshold', 'secondary / LS7 on s3ls'),
 ('s3mir', 'critical', 'mirroring is disconnected or suspended', 'm5'),
 ('s3mir', 'critical', 'mirroring is not synchronized', 'm3'),
 ('s3mir', 'warning', 'mirroring is synchronizing', 'm4'),
 ('s3mir', 'critical', 'the mirroring endpoint is not started', 'pgv_mirroring'),
 ('s3mir', 'warning', 'the mirroring send queue is over its threshold', 'm1'),
 ('s3mir', 'warning', 'the mirroring witness is disconnected', 'm1'),
 ('s3mir', 'critical', 'the principal of a mirrored database changed', 'm2');
DO $chk$
DECLARE v_missing text; v_extra text; v_state text;
BEGIN
  SELECT string_agg(format('%s|%s|%s|%s', name, severity, check_name, object), E'\n') INTO v_missing FROM (
    SELECT name, severity, check_name, object FROM t_expected
    EXCEPT ALL SELECT i.name, f.severity, f.check_name, f.object FROM pgvigil.mssql_hadr_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name LIKE 's3%') m;
  SELECT string_agg(format('%s|%s|%s|%s', name, severity, check_name, object), E'\n') INTO v_extra FROM (
    SELECT i.name, f.severity, f.check_name, f.object FROM pgvigil.mssql_hadr_findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name LIKE 's3%'
    EXCEPT ALL SELECT name, severity, check_name, object FROM t_expected) x;
  IF v_missing IS NOT NULL OR v_extra IS NOT NULL THEN
    RAISE EXCEPTION E'T: the findings differ from the expected list\nmissing:\n%\nnot expected:\n%', coalesce(v_missing, '-'), coalesce(v_extra, '-');
  END IF;
  SELECT string_agg(database_name, ',' ORDER BY database_name) INTO v_state FROM pgvigil.mssql_mirroring_role_changes
   WHERE instance_id = (SELECT instance_id FROM pgvigil.instances WHERE name = 's3mir');
  IF v_state IS DISTINCT FROM 'm2' THEN RAISE EXCEPTION 'T: mirroring role changes stored for % (expected m2 only: m6''s sequence went 5 -> 1, a re-created session)', v_state; END IF;
  SELECT role || '|' || coalesce(state, '') || '|' || values_hidden INTO v_state FROM pgvigil.mssql_mirroring_state
   WHERE instance_id = (SELECT instance_id FROM pgvigil.instances WHERE name = 's3mir') AND database_name = 'm7';
  IF v_state IS DISTINCT FROM 'MIRROR||true' THEN RAISE EXCEPTION 'T: the hidden mirror m7 stored %', v_state; END IF;
  SELECT txn_delay_ms::text INTO v_state FROM pgvigil.mssql_mirroring_state
   WHERE instance_id = (SELECT instance_id FROM pgvigil.instances WHERE name = 's3mir') AND database_name = 'm1';
  IF v_state IS DISTINCT FROM '2.000' THEN RAISE EXCEPTION 'T: m1''s transaction delay per write %, expected 2.000 (1000 ms over 500 writes)', v_state; END IF;
  SELECT primary_connections INTO v_state FROM pgvigil.mssql_ag_state
   WHERE instance_id = (SELECT instance_id FROM pgvigil.instances WHERE name = 's3ag') AND replica_server = 'd1a';
  IF v_state IS DISTINCT FROM 'READ_WRITE' THEN RAISE EXCEPTION 'T: d1a''s primary_connections stored %, expected READ_WRITE', v_state; END IF;
END $chk$;
\echo T: the findings equal the expected list; role changes m2 only; m7 hidden MIRROR; m1 delay 2.000; primary_connections READ_WRITE
TSQL
  cat "$T_WORK/t.out"
  echo "PROOF OK (part T)"
  exit 0
fi
if [ "${1:-}" = gaps ]; then
  : "${PGVIGIL_REPO_DSN:?a superuser connection to a PostgreSQL sandbox, in keyword form}"
  for t in docker openssl psql python3 go; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
  export PGVIGIL_MSSQL_IMAGE=${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04}
  S_ADMIN=$PGVIGIL_REPO_DSN; S_SUF=$RANDOM
  S_TAG="pgvgaps$(openssl rand -hex 4)"; S_NODES=(d1a d1b d2a d2b)
  S_SA="S$(openssl rand -hex 14)!a"; S_MP="Pv9$(openssl rand -hex 16)"; S_LM="pgvgaps_mon_$S_SUF"; S_SID="0x9B$(openssl rand -hex 15 | tr a-f A-F)"
  S_REPO=pgvigil_gapsproof_$S_SUF
  S_WORK=$(mktemp -d); S_CFG=$S_WORK/pgvigil.yaml; S_OUT=$S_WORK/out
  S_LAB=; S_MADE_REPO=; S_SQLCMD=()
  declare -A S_N S_I
  for n in "${S_NODES[@]}"; do S_N[$n]="gapsproof-$n-$S_SUF"; done
  sfail() { echo "FAIL: $*" >&2; exit 1; }
  s_cleanup() {
    rc=$?
    set +e
    if [ -n "$S_LAB" ]; then bash scripts/dag/trial.sh down "$S_TAG" || { echo "CLEANUP: the lab $S_TAG is not removed in full" >&2; [ $rc = 0 ] && rc=1; }; fi
    if [ -n "$S_MADE_REPO" ]; then psql "$S_ADMIN" -XAtq -c "drop database if exists $S_REPO with (force)" >/dev/null 2>&1 || { echo "CLEANUP: database $S_REPO not dropped" >&2; [ $rc = 0 ] && rc=1; }; fi
    rm -rf "$S_WORK"
    exit $rc
  }
  trap s_cleanup EXIT
  sct() { echo "$S_TAG-$1"; }
  SQ() { SQLCMDPASSWORD="$S_SA" MP="$S_MP" docker exec -e SQLCMDPASSWORD -e MP "$(sct "$1")" "${S_SQLCMD[@]}" -S localhost -U sa -b -h -1 -W -s '|' -Q "SET NOCOUNT ON; $2"; }
  SX() { local out; if ! out=$(SQ "$1" "$3" 2>&1); then printf '%s\n' "$out" | sed "s/$S_SA/<sa>/g; s/$S_MP/<password>/g" >&2; sfail "$2 (on $1) was refused"; fi; }
  sq() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
  saddr() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(sct "$1")"; }
  sdsnvar() { echo "MSSQL_GAPS_${1^^}_DSN"; }
  sread() { "$BIN" collect -config "$S_CFG" -once "$2" -instance "${S_N[$1]}" >"$S_OUT" 2>&1 || { cat "$S_OUT"; sfail "the $2 read of $1 failed"; }
    if grep -q "partial\|skipped" "$S_OUT"; then cat "$S_OUT"; sfail "the $2 read of $1 is partial or skipped"; fi; }
  sag() { local n; for n in "$@"; do sread "$n" mssql_ag; done; }
  # sf <node> <check> <object>: the severities of that finding on the node (comma list), or nothing
  sf() { sq "select coalesce(string_agg(severity, ',' order by severity), '') from pgvigil.mssql_hadr_findings where instance_id = ${S_I[$1]} and check_name = '$2' and object = '$3'"; }
  # swait <seconds> <nodes> -- <command>: read the nodes every 5 s until the command holds
  swait() { local limit=$1; shift; local nodes=() t0=$SECONDS; while [ "$1" != -- ]; do nodes+=("$1"); shift; done; shift
    while :; do sag "${nodes[@]}"; if "$@"; then echo "    after $((SECONDS - t0)) s"; return 0; fi; [ $((SECONDS - t0)) -ge "$limit" ] && return 1; sleep 5; done; }
  setthr_ag() { sq "update pgvigil.pg_thresholds set ended_at = now(), ended_by = 'proof' where ended_at is null and key = 'ag_data_loss' and level = 'instance' and instance_id = ${S_I[d1a]};
     insert into pgvigil.pg_thresholds (key, level, instance_id, warn, crit, created_by, created_at) values ('ag_data_loss', 'instance', ${S_I[d1a]}, $1, $2, 'proof', now())" >/dev/null; }
  BIN=${PGVIGIL_BIN:-}
  if [ -z "$BIN" ]; then CGO_ENABLED=0 go build -o "$S_WORK/pgvigil" ./cmd/pgvigil || sfail "the build"; BIN=$S_WORK/pgvigil; fi

  echo "--- S1. the lab ($PGVIGIL_MSSQL_IMAGE) and the monitoring login"
  S_LAB=1
  KEEP=1 PGVIGIL_DAG_TAG="$S_TAG" PGVIGIL_DAG_SA="$S_SA" bash scripts/dag/trial.sh > "$S_OUT" 2>&1 || { cat "$S_OUT"; sfail "S1: the lab did not form"; }
  grep -qx 'DAG FORMED' "$S_OUT" || { cat "$S_OUT"; sfail "S1: no 'DAG FORMED' line"; }
  if docker exec "$(sct d1a)" test -x /opt/mssql-tools18/bin/sqlcmd; then S_SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -C); else S_SQLCMD=(/opt/mssql-tools/bin/sqlcmd); fi
  for n in "${S_NODES[@]}"; do
    SX "$n" "S1: the monitoring login" "CREATE LOGIN [$S_LM] WITH PASSWORD = '\$(MP)', SID = $S_SID, CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$S_LM]; GRANT VIEW ANY DEFINITION TO [$S_LM]; USE msdb; CREATE USER [$S_LM] FOR LOGIN [$S_LM]; ALTER ROLE db_datareader ADD MEMBER [$S_LM];"
    [ "$(SQ "$n" "SELECT CAST(IS_SRVROLEMEMBER('sysadmin', '$S_LM') AS varchar(2))")" = 0 ] || sfail "S1: the login is a sysadmin on $n"
    ip=$(saddr "$n"); [ -n "$ip" ] || sfail "S1: $n has no address"
    export "$(sdsnvar "$n")=sqlserver://$S_LM:$S_MP@$ip:1433?database=master&encrypt=true&TrustServerCertificate=true&dial+timeout=5"
  done
  psql "$S_ADMIN" -XAtq -v ON_ERROR_STOP=1 -c "create database $S_REPO"; S_MADE_REPO=1
  export PGVIGIL_REPO_DSN="$S_ADMIN dbname=$S_REPO"
  { echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
    for n in "${S_NODES[@]}"; do echo "  - name: ${S_N[$n]}"; echo "    engine: sqlserver"; echo "    dsn: env:$(sdsnvar "$n")"; done; } > "$S_CFG"
  "$BIN" migrate -config "$S_CFG" >/dev/null
  echo "ok S1: DAG FORMED; the login on four nodes, no sysadmin"

  echo "--- S2. at rest"
  SX d1b "S2: AlwaysOn_health started" "ALTER EVENT SESSION AlwaysOn_health ON SERVER WITH (STARTUP_STATE = ON); IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'AlwaysOn_health') ALTER EVENT SESSION AlwaysOn_health ON SERVER STATE = START;"
  sag "${S_NODES[@]}"
  for n in "${S_NODES[@]}"; do S_I[$n]=$(sq "select instance_id from pgvigil.instances where name = '${S_N[$n]}'"); done
  sleep 20; sag "${S_NODES[@]}"
  SAJ=$(SQ d1a "SELECT STRING_AGG(r.replica_server_name + '=' + c.join_state_desc, ' ') WITHIN GROUP (ORDER BY r.replica_server_name) FROM sys.dm_hadr_availability_replica_cluster_states c JOIN sys.availability_replicas r ON r.replica_id = c.replica_id JOIN sys.availability_groups g ON g.group_id = r.group_id WHERE g.name = 'ag1'")
  PGJ=$(sq "select string_agg(replica_server || '=' || coalesce(join_state, '-'), ' ' order by replica_server) from pgvigil.mssql_ag_state where instance_id = ${S_I[d1a]} and group_name = 'ag1'")
  [ "$SAJ" = "$PGJ" ] || sfail "S2: join states: sa '$SAJ', stored '$PGJ'"
  SAG=$(SQ d1a "SELECT CONCAT(failure_condition_level, '|', health_check_timeout) FROM sys.availability_groups WHERE name = 'ag1'")
  PGG=$(sq "select distinct failure_condition_level || '|' || health_check_timeout_ms from pgvigil.mssql_ag_state where instance_id = ${S_I[d1a]} and group_name = 'ag1'")
  [ "$SAG" = "$PGG" ] || sfail "S2: failure condition / health check: sa '$SAG', stored '$PGG'"
  PGE=$(sq "select distinct (endpoint->>'endpoint_name') || '|' || (endpoint->>'endpoint_state') || '|' || (endpoint->>'endpoint_port') from pgvigil.mssql_ag_state where instance_id = ${S_I[d1a]} and is_local")
  [ "$PGE" = "Hadr_endpoint|STARTED|5022" ] || sfail "S2: the endpoint stored as '$PGE'"
  for n in "${S_NODES[@]}"; do
    SAH=$(SQ "$n" "SELECT CONCAT(CASE WHEN es.name IS NULL THEN 0 ELSE 1 END, '|', CASE WHEN xs.name IS NULL THEN 0 ELSE 1 END, '|', CAST(ISNULL(es.startup_state, 0) AS int)) FROM (SELECT 1 AS one) x LEFT JOIN sys.server_event_sessions es ON es.name = 'AlwaysOn_health' LEFT JOIN sys.dm_xe_sessions xs ON xs.name = 'AlwaysOn_health'")
    PGH=$(sq "select distinct case when (health_session->>'exists')::boolean then 1 else 0 end || '|' || case when (health_session->>'running')::boolean then 1 else 0 end || '|' || case when coalesce((health_session->>'autostart')::boolean, false) then 1 else 0 end from pgvigil.mssql_ag_state where instance_id = ${S_I[$n]}")
    [ "$SAH" = "$PGH" ] || sfail "S2: AlwaysOn_health on $n: sa '$SAH', stored '$PGH'"
    want=; [ "$SAH" = "1|1|1" ] || want=warning
    [ "$(sf "$n" 'the AlwaysOn_health session is not running' AlwaysOn_health)" = "$want" ] || sfail "S2: the AlwaysOn_health finding on $n is '$(sf "$n" 'the AlwaysOn_health session is not running' AlwaysOn_health)' with sa's '$SAH'"
    echo "    AlwaysOn_health on $n (exists|running|autostart): $SAH -> finding '${want:-none}'"
    if [ "$SAH" = "1|1|1" ]; then HOK=1; fi
  done
  [ -n "${HOK:-}" ] || sfail "S2: no node reads AlwaysOn_health 1|1|1 after d1b's start: the 'not raised' case is not read"
  SAQ=$(SQ d1a "SELECT CONCAT(ISNULL(cluster_name, ''), '|', quorum_type_desc, '|', quorum_state_desc) FROM sys.dm_hadr_cluster" 2>&1 || true)
  PGQ=$(sq "select distinct coalesce(e->>'cluster_name', '') || '|' || (e->>'quorum_type') || '|' || (e->>'quorum_state') from pgvigil.mssql_ag_state a cross join lateral jsonb_array_elements(case when jsonb_typeof(a.cluster) = 'array' then a.cluster else '[]'::jsonb end) e where a.instance_id = ${S_I[d1a]}")
  echo "    quorum on a clusterless Linux node: sa '$SAQ', stored '$PGQ' (cluster type $(sq "select distinct cluster_type from pgvigil.mssql_ag_state where instance_id = ${S_I[d1a]} and group_name = 'ag1'"))"
  [ "$SAQ" = "$PGQ" ] || sfail "S2: quorum: sa '$SAQ', stored '$PGQ'"
  SAR=$(SQ d1a "SELECT CONCAT(c.is_database_joined, '|', c.is_failover_ready) FROM sys.dm_hadr_database_replica_cluster_states c JOIN sys.availability_replicas r ON r.replica_id = c.replica_id WHERE r.replica_server_name = 'd1b' AND c.database_name = 'dagdb'")
  PGR=$(sq "select case when is_database_joined then 1 else 0 end || '|' || case when is_failover_ready then 1 else 0 end from pgvigil.mssql_ag_database_cluster where instance_id = ${S_I[d1a]} and group_name = 'ag1' and replica_server = 'd1b' and database_name = 'dagdb'")
  [ "$SAR" = "$PGR" ] && [ "${PGR%%|*}" = 1 ] || sfail "S2: ag1 / d1b / dagdb joined|ready: sa '$SAR', stored '$PGR'"
  SAS=$(SQ d1a "SELECT COUNT(*) FROM sys.dm_hadr_automatic_seeding")
  PGS=$(sq "select coalesce(string_agg(database_name || '->' || remote_replica || '=' || seeding_state, ' ' order by 1), 'none') from pgvigil.mssql_ag_seeding where instance_id = ${S_I[d1a]}")
  echo "    seeding on d1a: sa counts $SAS row(s); stored: $PGS"
  [ "$SAS" = 0 ] || [ "$PGS" != none ] || sfail "S2: sa lists seeding rows on d1a, none stored"
  RR=$(sq "select count(*) from pgvigil.mssql_ag_replica_sample where instance_id = ${S_I[d1a]} and flow_control_ms_per_s is not null and resent_messages_per_s is not null")
  RD=$(sq "select count(*) from pgvigil.mssql_ag_dbcounter_sample where instance_id = ${S_I[d1b]} and database_name = 'dagdb' and redo_blocked_per_s is not null")
  [ "$RR" -ge 1 ] && [ "$RD" -ge 1 ] || sfail "S2: the counter rates: replica rows with rates $RR on d1a, database rows $RD on d1b"
  NEW="'a secondary would lose data in a failover','a replica is not joined','a database is not joined','a database is not ready for automatic failover','the cluster has no normal quorum','a cluster member is down','the availability group endpoint is not started','automatic seeding failed','read-only routing names a replica that takes no reads'"
  AT_REST=$(sq "select coalesce(string_agg(i.name || ':' || f.check_name, '; '), 'none') from pgvigil.mssql_hadr_findings f join pgvigil.instances i using (instance_id) where f.check_name in ($NEW)")
  [ "$AT_REST" = none ] || sfail "S2: new findings at rest: $AT_REST"
  for n in d1a d1b; do v=$(sdsnvar "$n")
    PGVIGIL_MSSQL_TEST_DSN="${!v}" go test -count=1 -run 'TestHADRS3StatementsLive' ./internal/mssql/ > "$S_OUT" 2>&1 || { sed "s/$S_MP/<password>/g" "$S_OUT"; sfail "S2: TestHADRS3StatementsLive on $n"; }
  done
  echo "ok S2: join states, group settings, endpoint, AlwaysOn_health, quorum, joined / ready, seeding, counter rates as sa reads; no new finding at rest; the statements live on d1a and d1b"

  echo "--- S3. a lagging secondary: one data-loss finding, two tiers"
  setthr_ag 0.25 0.75
  srow() { SQ d1a "USE dagdb; IF OBJECT_ID('dbo.gaps_rows') IS NULL CREATE TABLE dbo.gaps_rows (id int IDENTITY PRIMARY KEY, at datetime2 DEFAULT SYSUTCDATETIME()); INSERT dbo.gaps_rows DEFAULT VALUES;" >/dev/null; }
  srow
  zero() { [ "$(sq "select coalesce(est_data_loss_s::text, '-') from pgvigil.mssql_ag_database_state where instance_id = ${S_I[d1a]} and group_name = 'ag1' and replica_server = 'd1b' and database_name = 'dagdb'")" = 0 ]; }
  swait 60 d1a -- zero || sfail "S3: the estimate for d1b does not come to 0 s after a replicated write"
  SX d1b "S3: suspend" "ALTER DATABASE dagdb SET HADR SUSPEND;"
  t0=$SECONDS; W1=; C1=; BAD=; DIFF=; RUNW=0; RUNC=0; WRUN=; CRUN=
  while [ $((SECONDS - t0)) -lt 150 ]; do
    srow
    sag d1a
    sev=$(sf d1a 'a secondary would lose data in a failover' 'ag1 / d1b / dagdb')
    est=$(sq "select coalesce(est_data_loss_s::text, '-') from pgvigil.mssql_ag_database_state where instance_id = ${S_I[d1a]} and group_name = 'ag1' and replica_server = 'd1b' and database_name = 'dagdb'")
    sae=$(SQ d1a "SELECT DATEDIFF(second, s.last_commit_time, p.last_commit_time) FROM sys.dm_hadr_database_replica_states p JOIN sys.dm_hadr_database_replica_states s ON s.group_database_id = p.group_database_id AND s.replica_id <> p.replica_id JOIN sys.availability_replicas r ON r.replica_id = s.replica_id WHERE p.is_primary_replica = 1 AND p.is_local = 1 AND r.replica_server_name = 'd1b' AND DB_NAME(p.database_id) = 'dagdb'") || sae=ERR
    python3 -c "import sys; sys.exit(0 if abs(int('$est') - int('$sae')) <= 5 else 1)" 2>/dev/null || DIFF="$DIFF stored $est / sa $sae at $((SECONDS - t0)) s;"
    if [ "$est" != - ] && [ "$est" -ge 15 ]; then RUNW=$((RUNW + 1)); else RUNW=0; fi
    if [ "$est" != - ] && [ "$est" -ge 45 ]; then RUNC=$((RUNC + 1)); else RUNC=0; fi
    echo "    read at $((SECONDS - t0)) s: stored $est s, sa $sae s, finding '${sev:-none}'"
    [ -n "$sev" ] && [ -z "$WRUN" ] && WRUN=$RUNW
    [ "$sev" = critical ] && [ -z "$CRUN" ] && CRUN=$RUNC
    n=$(sq "select count(*) from pgvigil.mssql_hadr_findings where instance_id = ${S_I[d1a]} and check_name = 'a secondary would lose data in a failover' and object = 'ag1 / d1b / dagdb'")
    [ "$n" -le 1 ] || BAD="$n findings at $((SECONDS - t0)) s"
    [ "$sev" = warning ] && [ -z "$W1" ] && W1=$((SECONDS - t0))
    if [ "$sev" = critical ]; then C1=$((SECONDS - t0)); break; fi
    sleep 4
  done
  LOSS=$(sq "select est_data_loss_s || ' s (' || coalesce(data_loss_basis, '-') || ')' from pgvigil.mssql_ag_database_state where instance_id = ${S_I[d1a]} and group_name = 'ag1' and replica_server = 'd1b' and database_name = 'dagdb'")
  [ -z "$BAD" ] || sfail "S3: more than one data-loss finding: $BAD"
  [ -n "$W1" ] && [ -n "$C1" ] || sfail "S3: the tiers: warning at '${W1:-never}' s, critical at '${C1:-never}' s (last estimate $LOSS)"
  [ -z "$DIFF" ] || sfail "S3: the stored estimate differs from sa's by more than 5 s:$DIFF"
  [ "${WRUN:-0}" -ge 2 ] && [ "${CRUN:-0}" -ge 2 ] || sfail "S3: a tier came before two reads in a row reached it (reads at or over 15 s when the first finding came: ${WRUN:-?}; at or over 45 s when critical came: ${CRUN:-?})"
  [ "$(sf d1a 'a database is suspended' 'ag1 / d1b / dagdb')" = critical ] || sfail "S3: 0066's suspended finding is missing"
  SX d1b "S3: resume" "ALTER DATABASE dagdb SET HADR RESUME;"
  cleared() { [ -z "$(sf d1a 'a secondary would lose data in a failover' 'ag1 / d1b / dagdb')" ]; }
  swait 90 d1a -- cleared || sfail "S3: the data-loss finding stays 90 s after RESUME"
  echo "ok S3: one finding, the estimate as sa's within 5 s at each read: warning after $W1 s (the 2nd read in a row at 15 s or more), critical after $C1 s (the 2nd at 45 s or more; estimate $LOSS); cleared after RESUME"

  echo "--- S4. a secondary's endpoint stopped"
  SX d1b "S4: stop the endpoint" "ALTER ENDPOINT Hadr_endpoint STATE = STOPPED;"
  s4set() { [ "$(sf d1b 'the availability group endpoint is not started' Hadr_endpoint)" = critical ] && [ "$(sf d1a 'a replica is not connected' 'ag1 / d1b')" = critical ]; }
  swait 60 d1a d1b -- s4set || { SX d1b "S4: restart the endpoint" "ALTER ENDPOINT Hadr_endpoint STATE = STARTED;"; sfail "S4: endpoint '$(sf d1b 'the availability group endpoint is not started' Hadr_endpoint)', not connected '$(sf d1a 'a replica is not connected' 'ag1 / d1b')'"; }
  SX d1b "S4: restart the endpoint" "ALTER ENDPOINT Hadr_endpoint STATE = STARTED;"
  s4clear() { [ -z "$(sf d1b 'the availability group endpoint is not started' Hadr_endpoint)" ] && [ -z "$(sf d1a 'a replica is not connected' 'ag1 / d1b')" ]; }
  swait 90 d1a d1b -- s4clear || sfail "S4: the findings stay 90 s after STARTED"
  echo "ok S4: endpoint stopped -> both critical findings; started -> both gone"

  echo "--- S5. a database not joined"
  SX d1a "S5: d1b seeds by hand" "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1b' WITH (SEEDING_MODE = MANUAL);"
  SX d1a "S5: pgvgj added" "CREATE DATABASE pgvgj; ALTER DATABASE pgvgj SET RECOVERY FULL; BACKUP DATABASE pgvgj TO DISK = 'NUL'; ALTER AVAILABILITY GROUP ag1 ADD DATABASE pgvgj;"
  sajoined() { SQ d1a "SELECT ISNULL(CAST(MAX(CAST(c.is_database_joined AS int)) AS varchar(5)), 'none') FROM sys.dm_hadr_database_replica_cluster_states c JOIN sys.availability_replicas r ON r.replica_id = c.replica_id WHERE r.replica_server_name = 'd1b' AND c.database_name = 'pgvgj'"; }
  for _ in $(seq 1 15); do [ "$(sajoined)" = 0 ] && break; sleep 2; done
  [ "$(sajoined)" = 0 ] || sfail "S5: sa on d1a reads pgvgj on d1b as joined '$(sajoined)' 30 s after the add (SQL Server's, not pgvigil's)"
  [ "$(SQ d1b "SELECT COUNT(*) FROM sys.databases WHERE name = 'pgvgj'")" = 0 ] || sfail "S5: pgvgj reached d1b with its seeding mode MANUAL"
  s5set() { [ "$(sf d1a 'a database is not joined' 'ag1 / d1b / pgvgj')" = warning ]; }
  swait 60 d1a -- s5set || sfail "S5: sa reads it not joined, pgvigil raises no 'a database is not joined' (stored: $(sq "select coalesce(string_agg(replica_server || '/' || database_name || ' joined=' || coalesce(is_database_joined::text, '-'), '; '), 'none') from pgvigil.mssql_ag_database_cluster where instance_id = ${S_I[d1a]} and database_name = 'pgvgj'"))"
  [ -z "$(sf d1a 'a database is not synchronizing' 'ag1 / d1b / pgvgj')" ] || sfail "S5: a second finding (not synchronizing) for the unjoined database"
  SX d1a "S5: remove" "ALTER AVAILABILITY GROUP ag1 REMOVE DATABASE pgvgj; ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1b' WITH (SEEDING_MODE = AUTOMATIC);"
  SX d1b "S5: drop the copy" "IF DB_ID('pgvgj') IS NOT NULL DROP DATABASE pgvgj;"
  SX d1a "S5: drop" "ALTER DATABASE pgvgj SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE pgvgj;"
  s5clear() { [ -z "$(sf d1a 'a database is not joined' 'ag1 / d1b / pgvgj')" ]; }
  swait 60 d1a -- s5clear || sfail "S5: the finding stays after the removal"
  echo "ok S5: one warning 'a database is not joined', no second finding; gone after the removal"

  echo "--- S6. a replica not joined"
  SX d1a "S6: add d2b to ag1" "ALTER AVAILABILITY GROUP ag1 ADD REPLICA ON N'd2b' WITH (ENDPOINT_URL = 'TCP://d2b:5022', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = MANUAL);"
  s6set() { [ "$(sf d1a 'a replica is not joined' 'ag1 / d2b')" = warning ]; }
  swait 60 d1a -- s6set || { SQ d1a "ALTER AVAILABILITY GROUP ag1 REMOVE REPLICA ON N'd2b';" >/dev/null 2>&1; sfail "S6: no 'a replica is not joined' (stored join state $(sq "select coalesce(join_state, '-') from pgvigil.mssql_ag_state where instance_id = ${S_I[d1a]} and group_name = 'ag1' and replica_server = 'd2b'"))"; }
  OTHER=$(sq "select coalesce(string_agg(check_name, '; '), 'none') from pgvigil.mssql_hadr_findings where instance_id = ${S_I[d1a]} and object = 'ag1 / d2b' and check_name <> 'a replica is not joined'")
  SX d1a "S6: remove d2b" "ALTER AVAILABILITY GROUP ag1 REMOVE REPLICA ON N'd2b';"
  [ "$OTHER" = none ] || sfail "S6: other findings for the unjoined replica: $OTHER"
  s6clear() { [ -z "$(sf d1a 'a replica is not joined' 'ag1 / d2b')" ]; }
  swait 60 d1a -- s6clear || sfail "S6: the finding stays after the removal"
  echo "ok S6: one warning 'a replica is not joined', no other finding for it; gone after the removal"

  echo "--- S7. read-only routing"
  RMODE=url
  if ! SQ d1a "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1a' WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = ('d1b')));" > "$S_OUT" 2>&1; then
    echo "    SQL Server refused a list naming d1b without a URL: $(tr '\n' ' ' < "$S_OUT" | sed "s/$S_SA/<sa>/g" | cut -c1-200)"
    RMODE=allow
    SX d1a "S7: d1b's URL" "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1b' WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = 'TCP://d1b:1433'));"
    SX d1a "S7: d1b takes no reads" "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1b' WITH (SECONDARY_ROLE (ALLOW_CONNECTIONS = NO));"
    SX d1a "S7: the list" "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1a' WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = ('d1b')));"
  fi
  s7set() { [ "$(sf d1a 'read-only routing names a replica that takes no reads' 'ag1 / d1a -> d1b')" = warning ]; }
  swait 60 d1a -- s7set || sfail "S7: no routing finding ($RMODE; stored list $(sq "select coalesce(routing_list::text, '-') from pgvigil.mssql_ag_state where instance_id = ${S_I[d1a]} and group_name = 'ag1' and replica_server = 'd1a'"))"
  if [ "$RMODE" = url ]; then SX d1a "S7: d1b's URL" "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1b' WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = 'TCP://d1b:1433'));"
  else SX d1a "S7: d1b takes reads again" "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1b' WITH (SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL));"; fi
  s7clear() { [ -z "$(sf d1a 'read-only routing names a replica that takes no reads' 'ag1 / d1a -> d1b')" ]; }
  swait 60 d1a -- s7clear || sfail "S7: the routing finding stays after the fix"
  # READ_ONLY_ROUTING_URL takes no NONE (Msg 153): d1b keeps its URL until the lab is removed
  SX d1a "S7: reset" "ALTER AVAILABILITY GROUP ag1 MODIFY REPLICA ON N'd1a' WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = NONE));"
  echo "ok S7: the routing finding ($RMODE), gone after the fix; the list reset"

  echo "--- S8. a failed automatic seeding"
  SX d1b "S8: pgvgf on d1b first" "CREATE DATABASE pgvgf;"
  SX d1a "S8: pgvgf on d1a, added" "CREATE DATABASE pgvgf; ALTER DATABASE pgvgf SET RECOVERY FULL; BACKUP DATABASE pgvgf TO DISK = 'NUL'; ALTER AVAILABILITY GROUP ag1 ADD DATABASE pgvgf;"
  failed() { [ "$(SQ d1a "SELECT COUNT(*) FROM sys.dm_hadr_automatic_seeding s JOIN sys.availability_databases_cluster c ON c.group_database_id = s.ag_db_id WHERE c.database_name = 'pgvgf' AND s.current_state = 'FAILED'")" -ge 1 ]; }
  for _ in $(seq 1 30); do failed && break; sleep 2; done
  if failed; then
    s8set() { [ "$(sf d1a 'automatic seeding failed' 'ag1 / pgvgf -> d1b')" = warning ]; }
    swait 60 d1a -- s8set || sfail "S8: sa reads a FAILED seeding, no finding (stored: $(sq "select coalesce(string_agg(database_name || '->' || remote_replica || '=' || coalesce(seeding_state, '-') || '/' || coalesce(failure_state, '-'), '; '), 'none') from pgvigil.mssql_ag_seeding where instance_id = ${S_I[d1a]} and database_name = 'pgvgf'"))"
    echo "ok S8: a FAILED seeding ($(SQ d1a "SELECT TOP (1) failure_state_desc FROM sys.dm_hadr_automatic_seeding s JOIN sys.availability_databases_cluster c ON c.group_database_id = s.ag_db_id WHERE c.database_name = 'pgvgf' AND s.current_state = 'FAILED'")) -> 'automatic seeding failed'"
  else
    S8NP=" (S8 seeding failure NOT PROVEN)"
    echo "    seeding failure NOT PROVEN: sa reads for pgvgf: $(SQ d1a "SELECT STRING_AGG(CONCAT(s.current_state, '/', s.failure_state_desc), ' ') FROM sys.dm_hadr_automatic_seeding s JOIN sys.availability_databases_cluster c ON c.group_database_id = s.ag_db_id WHERE c.database_name = 'pgvgf'")"
  fi
  SX d1a "S8: remove" "ALTER AVAILABILITY GROUP ag1 REMOVE DATABASE pgvgf; ALTER DATABASE pgvgf SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE pgvgf;"
  s8clear() { [ -z "$(sf d1a 'automatic seeding failed' 'ag1 / pgvgf -> d1b')" ]; }
  swait 90 d1a -- s8clear || sfail "S8: 'automatic seeding failed' stays 90 s after pgvgf left the group"
  [ -n "${S8NP:-}" ] || echo "ok S8: removed from the group -> the warning gone"
  SX d1b "S8: drop" "IF DB_ID('pgvgf') IS NOT NULL BEGIN ALTER DATABASE pgvgf SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE pgvgf; END"

  echo "--- S9. log shipping leaves a group's secondary out"
  STATE=$(SQ d1b "SELECT CONCAT(state_desc, '|', is_in_standby, '|', CASE WHEN replica_id IS NULL THEN 0 ELSE 1 END) FROM sys.databases WHERE name = 'dagdb'")
  sread d1b mssql_logshipping
  ROWS=$(sq "select coalesce(string_agg(database_name || ' ag=' || in_availability_group, ' '), 'none') from pgvigil.mssql_logrestore_state where instance_id = ${S_I[d1b]}")
  LSF=$(sq "select count(*) from pgvigil.mssql_hadr_findings where instance_id = ${S_I[d1b]} and check_name in ('log restores are behind', 'a database has been restoring for days', 'a log shipping copy is missing')")
  echo "    dagdb on d1b (state|standby|in a group): $STATE; restore rows stored: $ROWS; log shipping findings: $LSF"
  [ "$LSF" = 0 ] || sfail "S9: log shipping findings on the group's secondary"
  [ "$ROWS" = none ] || [ "$(sq "select count(*) from pgvigil.mssql_logrestore_state where instance_id = ${S_I[d1b]} and not coalesce(in_availability_group, false)")" = 0 ] || sfail "S9: a restore row of d1b not marked as in a group: $ROWS"
  if [ "$ROWS" = none ]; then
    echo "ok S9: no log shipping finding on d1b; the group exclusion NOT PROVEN here: dagdb reads ${STATE%%|*} on the secondary, so the reader never reads it (proven over stub rows, part T)"
  else
    echo "ok S9: d1b's restore rows are all marked as in a group and none is judged"
  fi

  echo "--- U. the HA/DR folder's AG page (task 383) over d1a and d1b"
  ufleet() { PGVIGIL_HADR_FLEET_DSN="$PGVIGIL_REPO_DSN" PGVIGIL_HADR_FLEET_INSTANCES="${S_I[d1a]},${S_I[d1b]}" go test -count=1 -v -run 'TestHADRFleetProof' ./internal/web/ > "$S_OUT" 2>&1 || { cat "$S_OUT"; sfail "U: TestHADRFleetProof failed"; }; }
  ucount() { grep "^FLEET ${S_I[$1]} " "$S_OUT" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
  ustored() { sq "select count(*) from pgvigil.mssql_ag_database_state where instance_id = ${S_I[$1]} and coalesce(is_local, false) = $2 and upper(replace(synchronization_state, '_', ' ')) = '$3'"; }
  ucheck() { local n k st loc
    for n in d1a d1b; do
      for st in 'NOT SYNCHRONIZING' SYNCHRONIZING SYNCHRONIZED REVERTING INITIALIZING; do
        k=$(echo "$st" | tr 'A-Z ' 'a-z_')
        [ "$(ucount "$n" "$k")" = "$(ustored "$n" true "$st")" ] || sfail "U: $n $k: page $(ucount "$n" "$k"), stored $(ustored "$n" true "$st")"
        [ "$(ucount "$n" "remote_$k")" = "$(ustored "$n" false "$st")" ] || sfail "U: $n remote_$k: page $(ucount "$n" "remote_$k"), stored $(ustored "$n" false "$st")"
      done
    done; }
  # sa's own count of the DMV rows the collector reads (agDatabaseSQL's joins), by local / remote and state
  usa() { SQ "$1" "SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
                   JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
                   WHERE drs.is_local = $2 AND UPPER(REPLACE(drs.synchronization_state_desc, '_', ' ')) = '$3'"; }
  usacheck() { local n k st
    for n in d1a d1b; do
      for st in 'NOT SYNCHRONIZING' SYNCHRONIZING SYNCHRONIZED REVERTING INITIALIZING; do
        k=$(echo "$st" | tr 'A-Z ' 'a-z_')
        [ "$(ucount "$n" "$k")" = "$(usa "$n" 1 "$st")" ] || sfail "U1: $n $k: page $(ucount "$n" "$k"), sa's DMV $(usa "$n" 1 "$st")"
        [ "$(ucount "$n" "remote_$k")" = "$(usa "$n" 0 "$st")" ] || sfail "U1: $n remote_$k: page $(ucount "$n" "remote_$k"), sa's DMV $(usa "$n" 0 "$st")"
      done
    done; }
  for n in d1a d1b; do sread "$n" mssql_instance; done   # each server's own name, as a deployment reads it on every instance
  sag d1a d1b; ufleet; ucheck; usacheck
  echo "ok U1: the page's counts on d1a and d1b equal sa's DMV counts and their stored rows by state ($(grep '^FLEET' "$S_OUT" | sed "s/^FLEET ${S_I[d1a]}/d1a/; s/^FLEET ${S_I[d1b]}/d1b/" | tr '\n' ';'))"
  SX d1b "U2: suspend" "ALTER DATABASE dagdb SET HADR SUSPEND"
  sleep 3; sag d1b d1a; ufleet; ucheck
  SAT=$(SQ d1b "SELECT synchronization_state_desc FROM sys.dm_hadr_database_replica_states WHERE is_local = 1 AND database_id = DB_ID('dagdb')") || sfail "U2: sa's read of dagdb's state on d1b failed"
  PGT=$(sq "select synchronization_state from pgvigil.mssql_ag_database_state where instance_id = ${S_I[d1b]} and database_name = 'dagdb' and is_local and group_name = 'ag1'")
  [ "$SAT" = "NOT SYNCHRONIZING" ] && [ "$PGT" = "$SAT" ] || sfail "U2: dagdb on d1b: sa '$SAT', stored '$PGT' (want the DMV's 'NOT SYNCHRONIZING')"
  [ "$(ucount d1b not_synchronizing)" -ge 1 ] || sfail "U2: d1b's Not Synchronizing is $(ucount d1b not_synchronizing)"
  [ "$(ucount d1a remote_not_synchronizing)" -ge 1 ] || sfail "U2: d1a's Remote Not Synchronizing is $(ucount d1a remote_not_synchronizing)"
  echo "ok U2: sa and the store read '$SAT' (with a space); d1b Not Synchronizing $(ucount d1b not_synchronizing), d1a Remote Not Synchronizing $(ucount d1a remote_not_synchronizing) - each equal to the stored rows"
  SX d1b "U2: resume" "ALTER DATABASE dagdb SET HADR RESUME"
  sleep 5
  SX d1b "U3: failover" "ALTER AVAILABILITY GROUP ag1 FORCE_FAILOVER_ALLOW_DATA_LOSS"
  SX d1a "U3: demote" "ALTER AVAILABILITY GROUP ag1 SET (ROLE = SECONDARY)"
  # AlwaysOn_health through the collector (a read that fails is said, not fatal: the Failover Type is then not proven)
  xeread() { "$BIN" collect -config "$S_CFG" -once mssql_xe -instance "${S_N[$1]}" > "$S_WORK/xe.out" 2>&1 \
    || echo "    the mssql_xe read of $1 failed: $(tail -1 "$S_WORK/xe.out")"; }
  u3ok() { xeread d1b; xeread d1a; ufleet; RC=$(grep '^RC ' "$S_OUT" | grep '|ag1|' || true)
    printf '%s\n' "$RC" | grep -q "^RC ${S_I[d1b]}|ag1|Became Primary|" && printf '%s\n' "$RC" | grep -q "^RC ${S_I[d1a]}|ag1|No Longer Primary|"; }
  swait 60 d1b d1a -- u3ok || { printf '%s\n' "$RC" | sed 's/^/    /'; sfail "U3: Role Changes do not hold 'Became Primary' for d1b and 'No Longer Primary' for d1a on ag1 within 60 s"; }
  printf '%s\n' "$RC" | sed "s/^RC ${S_I[d1a]}/    d1a/; s/^RC ${S_I[d1b]}/    d1b/"
  if printf '%s\n' "$RC" | grep -q '|Forced|'; then echo "ok U3: the failover in Role Changes on both sides, Failover Type Forced"
  else U3NP=" - U3 Failover Type NOT PROVEN (no AlwaysOn_health DDL row stored)"
    echo "ok U3: the failover in Role Changes on both sides; its Failover Type NOT PROVEN here (no AlwaysOn_health DDL row stored by the mssql_xe read)"; fi

  echo "--- S10. the lab removed"
  bash scripts/dag/trial.sh down "$S_TAG" | tee "$S_OUT" || sfail "S10: the lab is not removed in full"
  S_LAB=
  psql "$S_ADMIN" -XAtq -c "drop database if exists $S_REPO with (force)" >/dev/null; S_MADE_REPO=
  echo "ok S10: the lab and the repository removed"
  echo "PROOF OK (part S, part U)${S8NP:-}${U3NP:-}"
  exit 0
fi
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${MSSQL_SA_PASSWORD:?the sa password of the SQL Server sandbox}"
CT1=${PGVIGIL_MSSQL_CONTAINER:-mssql-sandbox}; ADDR1=${PGVIGIL_MSSQL_ADDR:-localhost:1433}
CT2=${PGVIGIL_MSSQL_CONTAINER2:-mssql-sandbox2}; ADDR2=${PGVIGIL_MSSQL_ADDR2:-127.0.0.1:1434}
AG=${PGVIGIL_MSSQL_AG:-ag_sandbox}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_hadrproof_$SUF
LM=pgvh_mon_$SUF; LB=pgvh_bare_$SUF
PDB=pgvhadr_$SUF; DDB=pgvhadrdist_$SUF
J1="pgvhadr fails $SUF"; J2="pgvhadr waits $SUF"
BKF=/backups/${PDB}_full.bak; BKL=/backups/${PDB}_log.trn
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PM=$(pw); PB=$(pw)
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; LOG=$WORK/serve.log; SCRATCH=$WORK/scratch; mkdir -p "$SCRATCH"
fail() { echo "FAIL: $*" >&2; exit 1; }
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
sqn() { local ct=$1 db=$2; shift 2; docker exec -e SQLCMDPASSWORD "$ct" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -s '|' -d "$db" -Q "SET NOCOUNT ON; $1"; }
sq() { sqn "$CT1" "${2:-master}" "$1"; }
# sqin <container>: one statement on stdin (a statement that carries a password is never an argument: an argument is
# in the process list of this machine and of the container while the call runs)
sqin() { docker exec -i -e SQLCMDPASSWORD "$1" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -d master -i /dev/stdin; }
sq2() { sqn "$CT2" "${2:-master}" "$1"; }
MADE_REPO=; MADE_LM1=; MADE_LM2=; MADE_LB=; MADE_UM1=; MADE_UM2=; MADE_PDB=; MADE_DDB=; IN_AG=; SUSPENDED=; MADE_PDB2=; MADE_J1=; MADE_J2=; MADE_BK=; SRVPID=; LOOP=
cleanup() {
  rc=$?
  set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  [ -n "$LOOP" ] && { kill "$LOOP" 2>/dev/null; wait "$LOOP" 2>/dev/null; }   # its reads hold the monitoring login
  # the waiting job: stopped only where it still runs (sp_stop_job raises on a job that does not), then deleted
  [ -n "$MADE_J2" ] && { sq "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'$J2' AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL) EXEC msdb.dbo.sp_stop_job @job_name = N'$J2';" >/dev/null 2>&1; sq "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'$J2') EXEC msdb.dbo.sp_delete_job @job_name = N'$J2', @delete_unused_schedule = 1;" >/dev/null 2>&1; [ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name = N'$J2'" 2>/dev/null)" = 0 ] || echo "CLEANUP: job $J2 not deleted" >&2; }
  [ -n "$MADE_J1" ] && { sq "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'$J1') EXEC msdb.dbo.sp_delete_job @job_name = N'$J1', @delete_unused_schedule = 1;" >/dev/null 2>&1 || echo "CLEANUP: job $J1 not deleted" >&2; }
  [ -n "$SUSPENDED" ] && { sq2 "IF EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID('$PDB') AND is_local = 1 AND is_suspended = 1) ALTER DATABASE [$PDB] SET HADR RESUME;" >/dev/null 2>&1 || echo "CLEANUP: $PDB was NOT resumed on $CT2" >&2; }
  if [ -n "$IN_AG" ]; then
    sq "IF EXISTS (SELECT 1 FROM sys.availability_databases_cluster c JOIN sys.availability_groups g ON g.group_id = c.group_id WHERE g.name = N'$AG' AND c.database_name = N'$PDB') ALTER AVAILABILITY GROUP [$AG] REMOVE DATABASE [$PDB];" >/dev/null 2>&1 \
      || echo "CLEANUP: $PDB was NOT removed from the group $AG" >&2
  fi
  if [ -n "$MADE_PDB2" ]; then
    # the secondary's copy is this run's own: seeded from the proof's database, left RESTORING by the removal
    for _ in $(seq 1 30); do sq2 "IF DB_ID('$PDB') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID('$PDB')) DROP DATABASE [$PDB];" >/dev/null 2>&1; [ "$(sq2 "SELECT ISNULL(DB_ID('$PDB'), 0)" 2>/dev/null)" = 0 ] && break; sleep 2; done
    [ "$(sq2 "SELECT ISNULL(DB_ID('$PDB'), 0)" 2>/dev/null)" = 0 ] || echo "CLEANUP: database $PDB not dropped on $CT2" >&2
    sq2 "EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'$PDB';" >/dev/null 2>&1
  fi
  if [ -n "$MADE_PDB" ]; then
    sq "IF DB_ID('$PDB') IS NOT NULL BEGIN ALTER DATABASE [$PDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$PDB]; END" >/dev/null 2>&1 || echo "CLEANUP: database $PDB not dropped on $CT1" >&2
    sq "EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'$PDB';" >/dev/null 2>&1
  fi
  [ -n "$MADE_DDB" ] && { sq "IF DB_ID('$DDB') IS NOT NULL BEGIN ALTER DATABASE [$DDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DDB]; END" >/dev/null 2>&1 || echo "CLEANUP: database $DDB not dropped" >&2; }
  [ -n "$MADE_BK" ] && docker exec "$CT1" rm -f "$BKF" "$BKL" 2>/dev/null
  [ -n "$MADE_UM1" ] && { sq "IF USER_ID('$LM') IS NOT NULL DROP USER [$LM];" msdb >/dev/null 2>&1 || echo "CLEANUP: msdb user $LM not dropped on $CT1" >&2; }
  [ -n "$MADE_UM2" ] && { sq2 "IF USER_ID('$LM') IS NOT NULL DROP USER [$LM];" msdb >/dev/null 2>&1 || echo "CLEANUP: msdb user $LM not dropped on $CT2" >&2; }
  [ -n "$MADE_LM1" ] && { sq "IF SUSER_ID('$LM') IS NOT NULL DROP LOGIN [$LM];" >/dev/null 2>&1 || echo "CLEANUP: login $LM not dropped on $CT1" >&2; }
  [ -n "$MADE_LM2" ] && { sq2 "IF SUSER_ID('$LM') IS NOT NULL DROP LOGIN [$LM];" >/dev/null 2>&1 || echo "CLEANUP: login $LM not dropped on $CT2" >&2; }
  [ -n "$MADE_LB" ] && { sq "IF SUSER_ID('$LB') IS NOT NULL DROP LOGIN [$LB];" >/dev/null 2>&1 || echo "CLEANUP: login $LB not dropped" >&2; }
  [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

# ---- the binary: the given one where the tree is wired, else a scratch build with the wiring's lines
command -v go >/dev/null 2>&1 && [ -f go.mod ] || fail "run from the repository root with a go toolchain"
if grep -q 'StoreHADRThresholds' internal/mssql/mssql.go && grep -q 'CursorCollector' internal/mssql/mssql.go \
   && grep -q '/api/mssql/availability' internal/web/web.go && grep -q 'mssql_thresholds' internal/config/config.go; then
  WIRED="wired in this tree"
else
  tar --exclude=./web/node_modules --exclude=./bin --exclude=./.git -cf - . | tar -C "$SCRATCH" -xf -
  python3 - "$SCRATCH" <<'PY' || fail "the wiring's anchor lines are gone from the shared files"
import sys, io
root = sys.argv[1]
def edit(path, old, new, count=1):
    p = root + "/" + path
    s = io.open(p, encoding="utf-8").read()
    if s.count(old) != count:
        sys.exit("%s: anchor found %d times, want %d: %r" % (path, s.count(old), count, old[:70]))
    io.open(p, "w", encoding="utf-8").write(s.replace(old, new))
edit("internal/web/web.go", '\tapi.HandleFunc("GET /api/plan", s.Plan)\n',
     '\tapi.HandleFunc("GET /api/plan", s.Plan)\n\tapi.HandleFunc("GET /api/mssql/availability", s.MSSQLAvailability)\n'
     '\tapi.HandleFunc("GET /api/mssql/jobs", s.MSSQLJobs)\n\tapi.HandleFunc("GET /api/mssql/backups", s.MSSQLBackups)\n')
edit("internal/config/config.go", '\tPgBouncerDSNRaw string `yaml:"pgbouncer"`\n',
     '\tPgBouncerDSNRaw string `yaml:"pgbouncer"`\n'
     '\t// MSSQLThresholds sets the HA/DR, jobs and backups thresholds of a sqlserver instance (docs/sqlserver-hadr.md).\n'
     '\tMSSQLThresholds map[string]any `yaml:"mssql_thresholds"`\n')
edit("internal/mssql/mssql.go", '\trows, err := c.Run(sctx, conn, info)\n',
     '\ttctx, tcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)\n'
     '\terr = StoreHADRThresholds(tctx, r, instanceID, name, start, in.MSSQLThresholds)\n'
     '\ttcancel()\n'
     '\tif err != nil {\n'
     '\t\tlogRun(instanceID, "error", err.Error())\n'
     '\t\treturn collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}\n'
     '\t}\n'
     '\tvar rows []collect.Row\n'
     '\tif cc, ok := c.(CursorCollector); ok {\n'
     '\t\trows, err = cc.RunFrom(sctx, conn, info, func(_ context.Context, source string) (int64, bool, error) {\n'
     '\t\t\tcctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)\n'
     '\t\t\tdefer ccancel()\n'
     '\t\t\treturn r.MSSQLCursor(cctx, instanceID, source)\n'
     '\t\t})\n'
     '\t} else {\n'
     '\t\trows, err = c.Run(sctx, conn, info)\n'
     '\t}\n')
p = root + "/internal/repo/repo.go"
s = io.open(p, encoding="utf-8").read()
s += '''
// MSSQLCursor returns how far a cursor source of a SQL Server instance was read (false: never).
func (r *Repo) MSSQLCursor(ctx context.Context, instanceID int, source string) (int64, bool, error) {
	var n *int64
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.mssql_hadr_cursor($1, $2)`, instanceID, source).Scan(&n); err != nil {
		return 0, false, fmt.Errorf("mssql_hadr_cursor: %w", err)
	}
	if n == nil {
		return 0, false, nil
	}
	return *n, true, nil
}
'''
io.open(p, "w", encoding="utf-8").write(s)
PY
  (cd "$SCRATCH" && CGO_ENABLED=0 go build -o "$SCRATCH/pgvigil-wired" ./cmd/pgvigil) || fail "the scratch build with the wiring"
  BIN=$SCRATCH/pgvigil-wired
  WIRED="wired in a scratch build (the release wiring applies the same lines)"
fi
echo "binary: $WIRED"

# ---- logins, the proof's databases
for n in 1 2; do
  if [ $n = 1 ]; then s=sq; else s=sq2; fi
  if [ $n = 1 ]; then ct=$CT1; else ct=$CT2; fi
  sqin "$ct" <<<"CREATE LOGIN [$LM] WITH PASSWORD = '$PM', CHECK_POLICY = OFF;"; eval "MADE_LM$n=1"
  $s "GRANT VIEW SERVER STATE TO [$LM]; GRANT VIEW ANY DEFINITION TO [$LM];"
  $s "CREATE USER [$LM] FOR LOGIN [$LM];" msdb; eval "MADE_UM$n=1"
  $s "ALTER ROLE db_datareader ADD MEMBER [$LM];" msdb
done
sqin "$CT1" <<<"CREATE LOGIN [$LB] WITH PASSWORD = '$PB', CHECK_POLICY = OFF;"; MADE_LB=1
sq "GRANT VIEW SERVER STATE TO [$LB]; GRANT VIEW ANY DEFINITION TO [$LB];"
[ "$(sq "SELECT ISNULL(DB_ID('$PDB'), 0) + ISNULL(DB_ID('$DDB'), 0)")" = 0 ] && [ "$(sq2 "SELECT ISNULL(DB_ID('$PDB'), 0)")" = 0 ] || fail "a database named $PDB or $DDB exists already (a suffix collision): run again"
sq "CREATE DATABASE [$PDB];"; MADE_PDB=1
sq "ALTER DATABASE [$PDB] SET RECOVERY FULL; CREATE TABLE [$PDB].dbo.filler (id int IDENTITY PRIMARY KEY, pad char(8000) NOT NULL DEFAULT 'x');"
# a stand-in distribution database: empty tables in the documented shape (learn.microsoft.com, the system tables'
# pages), a few rows; the monitoring login reads it as it would a distribution database
sq "CREATE DATABASE [$DDB];"; MADE_DDB=1
sq "CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];
CREATE TABLE dbo.MSpublications (publisher_id smallint, publisher_db sysname, publication sysname, publication_id int, publication_type int);
CREATE TABLE dbo.MSarticles (publisher_id smallint, publisher_db sysname, publication_id int, article sysname, article_id int);
CREATE TABLE dbo.MSdistribution_agents (id int, name nvarchar(100), publisher_database_id int, publisher_id smallint, publisher_db sysname, publication sysname, subscriber_id smallint, subscriber_db sysname, subscription_type int);
CREATE TABLE dbo.MSdistribution_history (agent_id int, runstatus int, start_time datetime, time datetime, duration int, comments nvarchar(4000), xact_seqno varbinary(16), current_delivery_rate float, current_delivery_latency int, delivered_transactions int, delivered_commands int, average_commands int, delivery_rate float, delivery_latency int, total_delivered_commands bigint, error_id int, updateable_row bit, timestamp timestamp);
CREATE TABLE dbo.MSlogreader_agents (id int, name nvarchar(100), publisher_id smallint, publisher_db sysname, publication sysname);
CREATE TABLE dbo.MSlogreader_history (agent_id int, runstatus int, start_time datetime, time datetime, duration int, comments nvarchar(4000), xact_seqno varbinary(16), delivery_time int, delivered_transactions int, delivered_commands int, average_commands int, delivery_rate float, delivery_latency int, error_id int, timestamp timestamp, updateable_row bit);
CREATE TABLE dbo.MSsnapshot_agents (id int, name nvarchar(100), publisher_id smallint, publisher_db sysname, publication sysname, publication_type int);
CREATE TABLE dbo.MSsnapshot_history (agent_id int, runstatus int, start_time datetime, time datetime, duration int, comments nvarchar(1000), delivered_transactions int, delivered_commands int, delivery_rate float, error_id int, timestamp timestamp);
CREATE TABLE dbo.MSmerge_agents (id int, name nvarchar(100), publisher_id smallint, publisher_db sysname, publication sysname, subscriber_id smallint, subscriber_db sysname, subscriber_name sysname NULL);
CREATE TABLE dbo.MSmerge_sessions (session_id int, agent_id int, start_time datetime, end_time datetime, duration int, delivery_rate float NULL, runstatus int, timestamp timestamp);
CREATE TABLE dbo.MSmerge_subscriptions (publisher_id smallint, publisher_db sysname, publication_id int, subscriber_id smallint, subscriber_db sysname, subscription_type int, sync_type tinyint, status tinyint, subscription_time datetime);
CREATE TABLE dbo.MSsubscriptions (publisher_database_id int, article_id int, agent_id int, status tinyint);
CREATE TABLE dbo.MSrepl_errors (id int, time datetime, error_code sysname NULL, error_text ntext NULL);
CREATE TABLE dbo.MSrepl_transactions (publisher_database_id int, xact_seqno varbinary(16), entry_time datetime);
CREATE TABLE dbo.MSrepl_commands (publisher_database_id int, xact_seqno varbinary(16), article_id int);
CREATE TABLE dbo.MSmerge_history (session_id int, agent_id int, comments nvarchar(1000), error_id int, timestamp timestamp, updatable_row bit);
CREATE TABLE dbo.stub_status (article_id int, agent_id int, UndelivCmdsInDistDB int, DelivCmdsInDistDB int);
EXEC('CREATE VIEW dbo.MSdistribution_status AS SELECT article_id, agent_id, UndelivCmdsInDistDB, DelivCmdsInDistDB FROM dbo.stub_status');
INSERT dbo.MSpublications VALUES (0, N'sales', N'pub_orders', 1, 0);
INSERT dbo.MSarticles VALUES (0, N'sales', 1, N'orders', 1), (0, N'sales', 1, N'lines', 2);
INSERT dbo.MSdistribution_agents VALUES (1, N'dist-agent-1', 1, 0, N'sales', N'pub_orders', 0, N'sales_copy', 0), (2, N'virtual-agent', 1, 0, N'sales', N'pub_orders', -1, N'virtual', 0);
INSERT dbo.MSdistribution_history (agent_id, runstatus, start_time, time, comments, delivery_rate, delivery_latency) VALUES (1, 3, DATEADD(minute, -9, GETDATE()), DATEADD(minute, -8, GETDATE()), N'older row', 10, 900), (1, 6, DATEADD(minute, -9, GETDATE()), DATEADD(minute, -1, GETDATE()), N'the subscriber refused the connection', 2, 4000);
INSERT dbo.stub_status VALUES (1, 1, 3, 10), (2, 1, 4, 20), (1, 2, 99, 0);
INSERT dbo.MSlogreader_agents VALUES (1, N'logreader-1', 0, N'sales', N'ALL');
INSERT dbo.MSlogreader_history (agent_id, runstatus, start_time, time, comments, delivery_latency) VALUES (1, 4, GETDATE(), GETDATE(), N'No replicated transactions are available.', 120);
INSERT dbo.MSsnapshot_agents VALUES (1, N'snapshot-1', 0, N'sales', N'pub_orders', 0);
INSERT dbo.MSsnapshot_history (agent_id, runstatus, start_time, time, comments) VALUES (1, 2, GETDATE(), GETDATE(), N'A snapshot of 2 article(s) was generated.');
INSERT dbo.MSmerge_agents VALUES (1, N'merge-1', 0, N'crm', N'pub_crm', 0, N'crm_copy', NULL);
INSERT dbo.MSmerge_subscriptions VALUES (0, N'crm', 2, 0, N'crm_copy', 0, 1, 0, GETDATE());
INSERT dbo.MSmerge_sessions (session_id, agent_id, start_time, end_time, duration, runstatus) VALUES (1, 1, DATEADD(hour, -1, GETDATE()), DATEADD(minute, -59, GETDATE()), 60, 2), (2, 1, DATEADD(minute, -5, GETDATE()), NULL, 0, 5);
INSERT dbo.MSmerge_history (session_id, agent_id, comments) VALUES (2, 1, N'The merge process is retrying.');" "$DDB"

export MSSQL_N1_DSN="sqlserver://$LM:$PM@$ADDR1?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_N2_DSN="sqlserver://$LM:$PM@$ADDR2?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_NB_DSN="sqlserver://$LB:$PB@$ADDR1?database=master&encrypt=true&TrustServerCertificate=true"
N1=proof-hadr-a-$SUF; N2=proof-hadr-b-$SUF; NB=proof-hadr-bare-$SUF
# config <thresholds block for the first instance>: writes $CFG
config() {
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $N1
    engine: sqlserver
    dsn: env:MSSQL_N1_DSN
$1
  - name: $N2
    engine: sqlserver
    dsn: env:MSSQL_N2_DSN
  - name: $NB
    engine: sqlserver
    dsn: env:MSSQL_NB_DSN
EOF
}
config ""
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" | tee "$OUT"; }
SN1=$(sq "SELECT @@SERVERNAME"); SN2=$(sq2 "SELECT @@SERVERNAME")

echo "--- A. the group from the primary and from the secondary, as the least-privilege login"
[ "$(sq "SELECT COUNT(*) FROM sys.availability_groups WHERE name = N'$AG'")" = 1 ] || fail "A: the group $AG does not exist on $CT1"
[ "$(sq "SELECT primary_replica FROM sys.dm_hadr_availability_group_states s JOIN sys.availability_groups g ON g.group_id = s.group_id WHERE g.name = N'$AG'")" = "$SN1" ] || fail "A: $CT1 is not the primary of $AG"
NREP=$(sq "SELECT COUNT(*) FROM sys.availability_replicas r JOIN sys.availability_groups g ON g.group_id = r.group_id WHERE g.name = N'$AG'")
NDRS1=$(sq "SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states"); NDRS2=$(sq2 "SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states")
CTYPE=$(sq "SELECT cluster_type_desc FROM sys.availability_groups WHERE name = N'$AG'")
echo "  sa reads: $NREP replicas, primary $SN1, cluster type $CTYPE; database replica rows: $NDRS1 on $CT1, $NDRS2 on $CT2"
collect mssql_ag "$N1"; if grep -q "partial\|skipped" "$OUT"; then fail "A: the primary's read is partial or skipped"; fi
collect mssql_ag "$N2"; if grep -q "partial\|skipped" "$OUT"; then fail "A: the secondary's read is partial or skipped"; fi
I1=$(q "select instance_id from pgvigil.instances where name='$N1'"); I2=$(q "select instance_id from pgvigil.instances where name='$N2'")
agq="group_name = '$AG'"
[ "$(q "select count(*) from pgvigil.mssql_ag_state where instance_id=$I1 and $agq")" = "$NREP" ] || fail "A: the primary's replica rows"
[ "$(q "select role || '|' || connected_state || '|' || is_local from pgvigil.mssql_ag_state where instance_id=$I1 and $agq and replica_server='$SN1'")" = "PRIMARY|CONNECTED|true" ] || fail "A: the primary's own row"
[ "$(q "select role || '|' || connected_state || '|' || synchronization_health || '|' || is_local from pgvigil.mssql_ag_state where instance_id=$I1 and $agq and replica_server='$SN2'")" = "SECONDARY|CONNECTED|HEALTHY|false" ] \
  || fail "A: the secondary as the primary sees it: $(q "select role, connected_state, synchronization_health, is_local from pgvigil.mssql_ag_state where instance_id=$I1 and replica_server='$SN2'")"
[ "$(q "select count(*) from pgvigil.mssql_ag_database_state where instance_id=$I1")" = "$NDRS1" ] || fail "A: the primary's database replica rows (want $NDRS1)"
[ "$(q "select bool_and(est_data_loss_s >= 0) and bool_and(last_hardened_at > now() - interval '1 day') from pgvigil.mssql_ag_database_state where instance_id=$I1 and $agq and not is_primary_replica")" = t ] || fail "A: the estimates of the secondary's rows on the primary"
IFS='|' read -r HDB HARD <<<"$(sq "SELECT TOP (1) c.database_name, CONVERT(varchar(19), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), drs.last_hardened_time), 126) FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_groups g ON g.group_id = drs.group_id JOIN sys.availability_databases_cluster c ON c.group_database_id = drs.group_database_id WHERE g.name = N'$AG' AND drs.is_local = 0 AND drs.last_hardened_time IS NOT NULL ORDER BY c.database_name")"
if [ -n "${HARD:-}" ]; then
  [ "$(q "select abs(extract(epoch from last_hardened_at - '${HARD}Z'::timestamptz)) < 600 from pgvigil.mssql_ag_database_state where instance_id=$I1 and $agq and database_name='$HDB' and not is_local")" = t ] || fail "A: last_hardened_at of $HDB is not sa's value in UTC"
else
  echo "  NOT PROVEN: the last hardened time against sa's own read (the group has no database replica with one)"
fi
[ "$(q "select count(*) from pgvigil.mssql_ag_state where instance_id=$I2 and $agq")" = "$NREP" ] || fail "A: the secondary's replica rows"
[ "$(q "select role || '|' || is_local || '|' || primary_replica from pgvigil.mssql_ag_state where instance_id=$I2 and $agq and replica_server='$SN2'")" = "SECONDARY|true|$SN1" ] || fail "A: the secondary's own row"
[ "$(q "select (role is null) || '|' || (connected_state is null) || '|' || is_local from pgvigil.mssql_ag_state where instance_id=$I2 and $agq and replica_server='$SN1'")" = "true|true|false" ] || fail "A: the primary as the secondary sees it (its state is not visible from a secondary)"
[ "$(q "select count(*) || '|' || bool_and(is_local) || '|' || bool_and(not is_primary_replica) || '|' || bool_and(est_data_loss_s is null) from pgvigil.mssql_ag_database_state where instance_id=$I2")" = "$NDRS2|true|true|true" ] || fail "A: the secondary's database replica rows"
[ "$(q "select distinct cluster_type || '|' || is_distributed from pgvigil.mssql_ag_state where instance_id=$I1 and $agq")" = "$CTYPE|false" ] || fail "A: cluster_type / is_distributed"
[ "$(q "select count(*) from pgvigil.collection_dates where instance_id in ($I1, $I2) and collection='mssql_ag' and status='ok'")" = 2 ] || fail "A: collection_dates"
echo "A: OK"

echo "--- B. backups (the proof's database joins the group first)"
sq "BACKUP DATABASE [$PDB] TO DISK = N'$BKF' WITH INIT, COMPRESSION;" >/dev/null; MADE_BK=1
IN_AG=1   # set before the statement: a failure half-way still gets the cleanup's guarded removal
if sq "ALTER AVAILABILITY GROUP [$AG] ADD DATABASE [$PDB];" >"$OUT" 2>&1; then
  MADE_PDB2=1
  for _ in $(seq 1 45); do
    SYN=$(sq "SELECT ISNULL((SELECT TOP (1) drs.synchronization_state_desc FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_databases_cluster c ON c.group_database_id = drs.group_database_id WHERE c.database_name = N'$PDB' AND drs.is_local = 0), 'none')")
    [ "$SYN" = SYNCHRONIZED ] && break; sleep 2
  done
  if [ "$SYN" = SYNCHRONIZED ]; then JOINED=1; else JOINED=; echo "  the proof's database did not synchronize on $CT2 within 90 s (state $SYN)"; fi
else
  JOINED=; IN_AG=; echo "  ADD DATABASE was refused: $(tr '\n' ' ' <"$OUT")"
fi
if [ -n "$JOINED" ]; then
  sq2 "BACKUP LOG [$PDB] TO DISK = N'$BKL' WITH INIT;" >/dev/null
  LOGWHERE=$N2
else
  sq "BACKUP LOG [$PDB] TO DISK = N'$BKL' WITH INIT;" >/dev/null
  LOGWHERE=$N1
  echo "  B: the merge of a group's backups over its replicas is NOT PROVEN live (the database is not in the group); F proves it over stubbed rows"
fi
IFS='|' read -r FFIN FSIZE <<<"$(sq "SELECT TOP (1) CONVERT(varchar(19), DATEADD(minute, -15 * time_zone, backup_finish_date), 126), CAST(backup_size AS bigint) FROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id WHERE bs.database_name = N'$PDB' AND bs.type = 'D' AND mf.physical_device_name = N'$BKF'")"
if [ -n "$JOINED" ]; then
  NSEED=$(sq "SELECT COUNT(*) FROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = bs.media_set_id WHERE bs.database_name = N'$PDB' AND bs.type = 'D' AND mf.device_type = 7")
  echo "  msdb holds $NSEED full 'backup' row(s) of $PDB to a virtual device: the automatic seeding stream"
  [ "$NSEED" -ge 1 ] || fail "B: no seeding row in msdb (the proof's premise)"
fi
collect mssql_ag "$N1" >/dev/null; collect mssql_ag "$N2" >/dev/null
collect mssql_backups "$N1"; if grep -q "partial\|skipped" "$OUT"; then fail "B: the read is partial or skipped"; fi
collect mssql_backups "$N2" >/dev/null
NDB=$(sq "SELECT COUNT(*) FROM sys.databases")
[ "$(q "select count(*) from pgvigil.mssql_backup_state where instance_id=$I1 and is_present")" = "$NDB" ] || fail "B: one row per database (want $NDB)"
[ "$(q "select (abs(extract(epoch from full_at - '${FFIN}Z'::timestamptz)) <= 2) || '|' || full_bytes || '|' || full_device || '|' || full_device_name || '|' || recovery_model from pgvigil.mssql_backup_state where instance_id=$I1 and database_name='$PDB'")" \
  = "true|$FSIZE|disk|$BKF|FULL" ] || fail "B: the full backup row: $(q "select full_at, full_bytes, full_device, full_device_name from pgvigil.mssql_backup_state where instance_id=$I1 and database_name='$PDB'") (sa: $FFIN $FSIZE)"
J=$(q "select not_judged || '|' || full_status || '|' || log_status || '|' || coalesce(log_from, '') || '|' || coalesce(replicas_monitored::text, '') || '/' || coalesce(replicas_total::text, '') from pgvigil.mssql_backup_judged where instance_id=$I1 and database_name='$PDB'")
echo "  judged with the defaults: $J"
if [ -n "$JOINED" ]; then WANTREP="$NREP/$NREP"; else WANTREP="/"; fi
[ "$J" = "a new database|not judged|not judged|$LOGWHERE|$WANTREP" ] || fail "B: the judged row with the defaults"
[ "$(q "select count(*) from pgvigil.mssql_jobs_findings where instance_id=$I1 and object='$PDB'")" = 0 ] || fail "B: a finding on a database that is not judged"
sleep 2
config "    mssql_thresholds:
      new_database_hours: 0
      log_backup_minutes: 0.01"
collect mssql_backups "$N1" >/dev/null
F=$(q "select severity || '|' || check_name from pgvigil.mssql_jobs_findings where instance_id=$I1 and object='$PDB'")
echo "  with the proof's thresholds: $F"
[ "$F" = "warning|no recent log backup" ] || fail "B: the log backup finding under the low threshold"
[ "$(q "select (detail like '%on $LOGWHERE%' or '$JOINED' = '') and detail like '%threshold is 0.01 minutes%' from pgvigil.mssql_jobs_findings where instance_id=$I1 and object='$PDB'")" = t ] || fail "B: the finding's text: $(q "select detail from pgvigil.mssql_jobs_findings where instance_id=$I1 and object='$PDB'")"
sq "BACKUP LOG [$PDB] TO DISK = N'NUL';" >/dev/null
collect mssql_backups "$N1" >/dev/null
[ "$(q "select (nul_at > now() - interval '5 minutes') || '|' || nul_type || '|' || coalesce(log_device_name, '') from pgvigil.mssql_backup_state where instance_id=$I1 and database_name='$PDB'")" = "true|log|$( [ -n "$JOINED" ] && echo "" || echo "$BKL")" ] \
  || fail "B: the NUL backup row: $(q "select nul_at, nul_type, log_at, log_device_name from pgvigil.mssql_backup_state where instance_id=$I1 and database_name='$PDB'")"
[ "$(q "select string_agg(check_name, ',' order by check_name) from pgvigil.mssql_jobs_findings where instance_id=$I1 and object='$PDB'")" = "a backup went to NUL,no recent log backup" ] \
  || fail "B: the findings after the NUL backup: $(q "select string_agg(check_name, ',') from pgvigil.mssql_jobs_findings where instance_id=$I1 and object='$PDB'")"
config "    mssql_thresholds:
      new_database_hours: 0
      log_backup_minutes: 0.01
      backup_exclude: ['pgvhadr%']"
collect mssql_backups "$N1" >/dev/null
[ "$(q "select not_judged from pgvigil.mssql_backup_judged where instance_id=$I1 and database_name='$PDB'")" = "excluded by the pattern pgvhadr%" ] || fail "B: backup_exclude"
[ "$(q "select count(*) from pgvigil.mssql_jobs_findings where instance_id=$I1 and object='$PDB'")" = 0 ] || fail "B: a finding on an excluded database"
config "    mssql_thresholds:
      log_backup_minute: 5"
if "$BIN" collect -config "$CFG" -once mssql_backups -instance "$N1" >"$OUT" 2>&1; then fail "B: an unknown threshold name was accepted"; fi
grep -q "log_backup_minute.*is not known" "$OUT" && grep -q "full_backup_hours" "$OUT" || { cat "$OUT"; fail "B: the refusal of an unknown threshold"; }
config "    mssql_thresholds:
      new_database_hours: 0"
echo "B: OK"

echo "--- C. a suspended database: the exposure grows, the queue drains"
if [ -n "$JOINED" ]; then
  SUSPENDED=1
  sq2 "ALTER DATABASE [$PDB] SET HADR SUSPEND;" >/dev/null
  sleep 2
  collect mssql_ag "$N1" >/dev/null
  [ "$(q "select is_suspended from pgvigil.mssql_ag_database_state where instance_id=$I1 and database_name='$PDB' and replica_server='$SN2'")" = t ] || fail "C: the suspended database replica is not stored as suspended"
  [ "$(q "select severity from pgvigil.mssql_hadr_findings where instance_id=$I1 and check_name='a database is suspended' and object='$AG / $SN2 / $PDB'")" = critical ] \
    || fail "C: no 'a database is suspended' finding: $(q "select check_name, object from pgvigil.mssql_hadr_findings where instance_id=$I1")"
  sq "INSERT dbo.filler (pad) SELECT TOP (18750) 'y' FROM sys.all_columns a CROSS JOIN sys.all_columns b;" "$PDB" >/dev/null
  sleep 3
  collect mssql_ag "$N1" >/dev/null
  R=$(q "select coalesce(log_send_queue_kb::text, 'null') || '|' || est_data_loss_s || '|' || synchronization_state from pgvigil.mssql_ag_database_state where instance_id=$I1 and database_name='$PDB' and replica_server='$SN2'")
  echo "  suspended, after 150 MB of log on the primary: send queue | estimated data loss s | state = $R"
  IFS='|' read -r SQ LOSS _ <<<"$R"
  [ "$LOSS" -ge 2 ] || fail "C: the estimated data loss did not grow while suspended"
  [ "$SQ" = null ] || echo "  (this server reports a send queue for a suspended replica: $SQ KB)"
  # reads back to back across the RESUME: the catch-up is short
  ( for _ in $(seq 1 25); do "$BIN" collect -config "$CFG" -once mssql_ag -instance "$N1" >/dev/null 2>&1 || true; done ) & LOOP=$!
  sleep 0.3
  sq2 "ALTER DATABASE [$PDB] SET HADR RESUME;" >/dev/null; SUSPENDED=
  wait $LOOP; LOOP=
  QMAX=$(q "select coalesce(max(greatest(coalesce(log_send_queue_kb, 0), coalesce(redo_queue_kb, 0))), 0) || '|' || coalesce(max(log_send_queue_kb), 0) || '|' || coalesce(max(redo_queue_kb), 0) || '|' || count(distinct snapshot_at) from pgvigil.mssql_ag_sample where instance_id=$I1 and database_name='$PDB' and replica_server='$SN2'")
  IFS='|' read -r QANY QSEND QREDO NREADS <<<"$QMAX"
  if [ "$QANY" -gt 0 ]; then echo "  across the RESUME ($NREADS reads kept): the largest send queue $QSEND KB, the largest redo queue $QREDO KB"; QSEEN="the catch-up's queue seen: send $QSEND KB, redo $QREDO KB"
  else echo "  queue NOT PROVEN: the catch-up finished between two reads ($NREADS reads kept, no queue above 0)"; QSEEN="the catch-up's queue NOT PROVEN"; fi
  for _ in $(seq 1 45); do
    collect mssql_ag "$N1" >/dev/null
    Q2=$(q "select greatest(coalesce(log_send_queue_kb, 0), coalesce(redo_queue_kb, 0)) from pgvigil.mssql_ag_database_state where instance_id=$I1 and database_name='$PDB' and replica_server='$SN2'")
    S2=$(q "select is_suspended || '|' || synchronization_state from pgvigil.mssql_ag_database_state where instance_id=$I1 and database_name='$PDB' and replica_server='$SN2'")
    [ "$Q2" -lt 1000 ] && [ "$S2" = "false|SYNCHRONIZED" ] && break; sleep 2
  done
  echo "  after RESUME: $Q2 KB, $S2"
  [ "$Q2" -lt 1000 ] && [ "$S2" = "false|SYNCHRONIZED" ] || fail "C: the queue did not drain"
  [ "$(q "select count(*) from pgvigil.mssql_hadr_findings where instance_id=$I1 and object like '%$PDB'")" = 0 ] || fail "C: a finding stays after the drain"
  echo "C: OK (suspended and found, the data loss grew, drained after RESUME; $QSEEN)"
  sq "ALTER AVAILABILITY GROUP [$AG] REMOVE DATABASE [$PDB];" >/dev/null; IN_AG=
else
  echo "C: queue growth NOT PROVEN (the proof's database could not be added to $AG; no other database is touched)"
fi

echo "--- D. Agent jobs"
sq "EXEC msdb.dbo.sp_add_job @job_name = N'$J1', @enabled = 1, @owner_login_name = N'sa';" >/dev/null; MADE_J1=1
sq "EXEC msdb.dbo.sp_add_jobstep @job_name = N'$J1', @step_id = 1, @step_name = N'one', @subsystem = N'TSQL', @command = N'SELECT 1;', @on_success_action = 3;
EXEC msdb.dbo.sp_add_jobstep @job_name = N'$J1', @step_id = 2, @step_name = N'two fails', @subsystem = N'TSQL', @command = N'RAISERROR(''pgvigil proof $SUF: step two fails'', 16, 1);';
EXEC msdb.dbo.sp_add_jobschedule @job_name = N'$J1', @name = N'pgvhadr nightly $SUF', @freq_type = 4, @freq_interval = 1, @active_start_time = 235900;
EXEC msdb.dbo.sp_add_jobserver @job_name = N'$J1';" >/dev/null
sq "EXEC msdb.dbo.sp_add_job @job_name = N'$J2', @enabled = 1, @owner_login_name = N'sa';" >/dev/null; MADE_J2=1
sq "EXEC msdb.dbo.sp_add_jobstep @job_name = N'$J2', @step_id = 1, @step_name = N'wait', @subsystem = N'TSQL', @command = N'WAITFOR DELAY ''00:03:00'';';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'$J2';" >/dev/null
sq "EXEC msdb.dbo.sp_start_job @job_name = N'$J1'; EXEC msdb.dbo.sp_start_job @job_name = N'$J2';" >/dev/null
for _ in $(seq 1 30); do
  [ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$J1' AND h.step_id = 0")" = 1 ] && break; sleep 1
done
[ "$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = N'$J1'")" = 3 ] || fail "D: the job did not write its three history rows (is SQL Server Agent running?)"
# the next 23:59 server time after now (a part D that runs after 23:59 meets tomorrow's: the 2017 cell of task 166's
# versions run failed so, its job row right), in UTC
NEXT=$(sq "DECLARE @next datetime = DATEADD(minute, 23 * 60 + 59, CAST(CAST(GETDATE() AS date) AS datetime)); IF GETDATE() >= @next SET @next = DATEADD(day, 1, @next); SELECT CONVERT(varchar(16), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), @next), 126)")
RSTART=
for _ in $(seq 1 30); do
  RSTART=$(sq "SELECT ISNULL(CONVERT(varchar(19), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), MAX(a.start_execution_date)), 126), '') FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'$J2' AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.stop_execution_date IS NULL")
  [ -n "$RSTART" ] && break; sleep 1
done
[ -n "$RSTART" ] || fail "D: the waiting job did not start within 30 s"
collect mssql_jobs "$N1"; if grep -q "partial\|skipped" "$OUT"; then fail "D: the read is partial or skipped"; fi
ROWS1=$(sed -n "s/^$N1 mssql_jobs: \([0-9]*\) row.*/\1/p" "$OUT")
jq1="instance_id=$I1 and name='$J1'"
R=$(q "select owner || '|' || enabled || '|' || schedule_names || '|' || to_char(next_run_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI') || '|' || last_outcome || '|' || jsonb_array_length(steps) || '|' || (running_since is null) from pgvigil.mssql_jobs where $jq1")
echo "  the failing job: $R"
[ "$R" = "sa|true|pgvhadr nightly $SUF|$NEXT|0|2|true" ] || fail "D: the job row (want sa|true|pgvhadr nightly $SUF|$NEXT|0|2|true)"
JID=$(q "select job_id from pgvigil.mssql_jobs where $jq1")
[ "$(q "select string_agg(step_id || ':' || run_status, ',' order by history_id) from pgvigil.mssql_job_runs where instance_id=$I1 and job_id='$JID'")" = "1:1,2:0,0:0" ] \
  || fail "D: the job's history rows: $(q "select string_agg(step_id || ':' || run_status, ',' order by history_id) from pgvigil.mssql_job_runs where instance_id=$I1 and job_id='$JID'")"
D=$(q "select severity || '|' || detail from pgvigil.mssql_jobs_findings where instance_id=$I1 and check_name='a job failed' and object='$J1'")
echo "  finding: $D"
[[ $D == "warning|"*"at step 2 (two fails)"*"pgvigil proof $SUF: step two fails"*"Next run ${NEXT/T/ } UTC."* ]] || fail "D: the finding's text"
R=$(q "select (abs(extract(epoch from running_since - '${RSTART}Z'::timestamptz)) < 60) from pgvigil.mssql_jobs where instance_id=$I1 and name='$J2'")
[ "$R" = t ] || fail "D: the waiting job is not seen running (sa: started $RSTART)"
CUR1=$(q "select last_history_id from pgvigil.mssql_jobs_cursor where instance_id=$I1 and mark is not null")
MAXRUN=$(q "select max(history_id) from pgvigil.mssql_job_runs where instance_id=$I1")
[ -n "$CUR1" ] && [ "$CUR1" = "$MAXRUN" ] || fail "D: the cursor ($CUR1) is not the newest row read ($MAXRUN)"
NJ=$(q "select count(*) from pgvigil.mssql_jobs where instance_id=$I1"); NS=$(q "select coalesce(sum(jsonb_array_length(steps)), 0) from pgvigil.mssql_jobs where instance_id=$I1")
collect mssql_jobs "$N1"
ROWS2=$(sed -n "s/^$N1 mssql_jobs: \([0-9]*\) row.*/\1/p" "$OUT")
NEW=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobhistory WHERE instance_id > $CUR1 AND run_status <> 4")
NJ2=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobs"); NS2=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobsteps")
# (the read also returns one row per schedule a job has: counted here, or each one would pass for a history row)
NC2=$(sq "SELECT COUNT(*) FROM msdb.dbo.sysjobschedules x JOIN msdb.dbo.sysschedules s ON s.schedule_id = x.schedule_id")
READ2=$((ROWS2 - NJ2 - NS2 - NC2 - 2))
echo "  first run $ROWS1 rows; second run $ROWS2 rows = $NJ2 jobs + $NS2 steps + $NC2 schedule(s) + 2 + $READ2 history row(s); sa counts $NEW past the first cursor (a read starts 50 rows behind it)"
[ "$READ2" -ge 0 ] && [ "$READ2" -le $((NEW + 50)) ] && [ "$ROWS2" -lt "$ROWS1" ] || fail "D: the second run read history again (stored before: $NJ jobs, $NS steps)"
[ "$(q "select count(*) from pgvigil.mssql_job_runs where instance_id=$I1 and job_id='$JID'")" = 3 ] || fail "D: the job's history rows after the second run"
sq "EXEC msdb.dbo.sp_stop_job @job_name = N'$J2';" >/dev/null
# msdb lets every login in through its guest user; what a login without a user of its own may read there is asked
# per table: sysjobs is never readable that way; backupset is granted to public, so mssql_backups may run in full
collect mssql_jobs "$NB" >/dev/null
grep -q "skipped: the login has no access to msdb" "$OUT" && grep -q "db_datareader" "$OUT" || { cat "$OUT"; fail "D: mssql_jobs as the login without a user in msdb"; }
IB=$(q "select instance_id from pgvigil.instances where name='$NB'")
[ "$(q "select status || '|' || (note like '%sysjobs%db_datareader%') from pgvigil.collection_dates where instance_id=$IB and collection='mssql_jobs'")" = "skipped|true" ] || fail "D: collection_dates of the login without a user in msdb"
[ "$(q "select count(*) from pgvigil.mssql_jobs where instance_id=$IB")" = 0 ] || fail "D: jobs stored for the login without a user in msdb"
for c in mssql_backups mssql_logshipping; do
  collect $c "$NB" >/dev/null
  if grep -q "skipped: the login has no access to msdb" "$OUT"; then echo "  $c as the login without a user in msdb: skipped with the missing right"
  elif grep -q "partial\|error" "$OUT"; then cat "$OUT"; fail "D: $c as the login without a user in msdb neither ran nor was skipped with the reason"
  else echo "  $c as the login without a user in msdb: ran (msdb grants that table to public)"; fi
done
echo "D: OK"

echo "--- E. mirroring, log shipping, replication: nothing on this sandbox"
for c in mssql_mirroring mssql_logshipping mssql_replication; do
  collect $c "$N1"
  grep -q "^$N1 $c: 0 row(s)" "$OUT" || fail "E: $c did not read 0 rows"
done
[ "$(q "select (select count(*) from pgvigil.mssql_mirroring_state) + (select count(*) from pgvigil.mssql_logshipping_state) + (select count(*) from pgvigil.mssql_replication_state)")" = 0 ] || fail "E: something was stored"
echo "NOT PROVEN: no mirrored database on this sandbox (mssql_mirroring ran, found none, stored nothing)"
echo "NOT PROVEN: no log shipping on this sandbox (mssql_logshipping ran, found none, stored nothing)"
echo "NOT PROVEN: no distributor on this sandbox (mssql_replication ran, found none, stored nothing)"
PGVIGIL_MSSQL_TEST_DSN="$MSSQL_N1_DSN" PGVIGIL_MSSQL_TEST_DISTRIBUTION="$DDB" go test ./internal/mssql -run 'TestHADRStatementsLive|TestAgentDateTimeLive|TestBackupSinkLive|TestBackupUTCLive' -count=1 -v >"$OUT" 2>&1 || { cat "$OUT"; fail "E: the live statement tests on the primary"; }
grep -E "replication (publications|subscriptions|agents): [0-9]+ row" "$OUT" | sed 's/^ *[a-z_.0-9]*: /  stand-in distribution database: /' || true
# merge-1: an agent row, or (a tree with task 385's merge rows) a subscription row and no agent row
if grep -q 'func replMergeSubscriptions' internal/mssql/replication.go; then RSUB=2; RAG=2; else RSUB=1; RAG=3; fi
grep -q "replication publications: 1 row" "$OUT" && grep -q "replication subscriptions: $RSUB row" "$OUT" && grep -q "replication agents: $RAG row" "$OUT" || { cat "$OUT"; fail "E: the replication statements over the stand-in database (want $RSUB subscriptions, $RAG agents)"; }
PGVIGIL_MSSQL_TEST_DSN="$MSSQL_N2_DSN" go test ./internal/mssql -run 'TestHADRStatementsLive' -count=1 >"$OUT" 2>&1 || { cat "$OUT"; fail "E: the live statement test on the secondary"; }
# the same statements through the collector's row shaping into the import, against the stand-in, read by hand
SUBS=$(sqn "$CT1" "$DDB" "SELECT CAST(SUM(UndelivCmdsInDistDB) AS varchar(12)) FROM dbo.MSdistribution_status WHERE agent_id = 1")
[ "$SUBS" = 7 ] || fail "E: the stand-in's undelivered commands"
echo "E: OK (every statement compiled and run by the server as the monitoring login on both nodes; the replication statements over a stand-in of the documented shape)"

echo "--- F. stubbed rows through the import functions"
ST=$(q "select pgvigil.ensure_instance('proof-hadr-stub-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
PGI=$(q "select pgvigil.ensure_instance('proof-hadr-pg-$SUF', 'onprem', 'x', 170000, false, '{}', 'postgres')")
imp() { q "select pgvigil.import_$1($2, $3, \$j\$$4\$j\$::jsonb)" >/dev/null; }
if q "select pgvigil.import_mssql_ag($PGI, now(), '[]'::jsonb)" >"$OUT" 2>&1; then fail "F: import_mssql_ag accepted a PostgreSQL instance"; fi
grep -q "is not a SQL Server instance" "$OUT" || fail "F: the refusal's text"
imp mssql_mirroring "$ST" "now()" '[{"kind":"mirror","database_name":"sales","role":"PRINCIPAL","state":"DISCONNECTED","safety_level":"FULL","partner":"TCP://b:5022","partner_instance":"b","witness":"w","witness_state":"CONNECTED","log_send_queue_kb":4096,"redo_queue_kb":0},
 {"kind":"mirror","database_name":"crm","role":"PRINCIPAL","state":"SYNCHRONIZED","safety_level":"FULL","partner_instance":"b"}]'
imp mssql_logshipping "$ST" "now()" "[{\"kind\":\"secondary\",\"database_name\":\"sales_ls\",\"secondary_server\":\"c\",\"primary_server\":\"a\",\"primary_database\":\"sales\",\"threshold_minutes\":45,\"alert_enabled\":1,\"last_copied_utc\":\"$(date -u -d '-170 min' +%FT%TZ)\",\"last_restored_utc\":\"$(date -u -d '-180 min' +%FT%TZ)\",\"last_restored_file\":\"sales_1.trn\"},
 {\"kind\":\"secondary\",\"database_name\":\"sales_ls\",\"secondary_server\":\"d\",\"primary_server\":\"a\",\"primary_database\":\"sales\",\"threshold_minutes\":45,\"alert_enabled\":1,\"last_copied_utc\":\"$(date -u -d '-5 min' +%FT%TZ)\",\"last_restored_utc\":\"$(date -u -d '-4 min' +%FT%TZ)\"},
 {\"kind\":\"primary\",\"database_name\":\"sales\",\"primary_server\":\"a\",\"threshold_minutes\":60,\"alert_enabled\":1,\"last_backup_utc\":\"$(date -u -d '-10 min' +%FT%TZ)\"}]"
imp mssql_replication "$ST" "now()" "[{\"kind\":\"publication\",\"distribution_db\":\"distribution\",\"publisher\":\"a\",\"publisher_db\":\"sales\",\"publication\":\"pub\",\"publication_type\":\"transactional\",\"articles\":2},
 {\"kind\":\"subscription\",\"distribution_db\":\"distribution\",\"publisher\":\"a\",\"publisher_db\":\"sales\",\"publication\":\"pub\",\"subscriber\":\"s\",\"subscriber_db\":\"copy\",\"subscription_type\":\"push\",\"agent_type\":\"distribution\",\"agent_name\":\"d1\",\"runstatus\":6,\"status_text\":\"login failed\",\"last_run_utc\":\"$(date -u +%FT%TZ)\",\"delivery_rate\":50,\"undistributed\":250000,\"est_catchup_s\":5000},
 {\"kind\":\"agent\",\"distribution_db\":\"distribution\",\"agent_type\":\"logreader\",\"agent_name\":\"lr1\",\"publisher\":\"a\",\"publisher_db\":\"sales\",\"runstatus\":4,\"status_text\":\"idle\"}]"
G=11111111-2222-3333-4444-555555555555; DG=99999999-2222-3333-4444-555555555555
agp() { # agp <minutes ago> <primary> <redo kb> <send kb>
  imp mssql_ag "$ST" "now() - interval '$1 minutes'" "[{\"kind\":\"replica\",\"group_id\":\"$G\",\"group_name\":\"ag1\",\"cluster_type\":\"WSFC\",\"is_distributed\":0,\"is_contained\":0,\"primary_replica\":\"$2\",\"replica_server\":\"a\",\"availability_mode\":\"SYNCHRONOUS_COMMIT\",\"is_local\":1,\"role\":\"PRIMARY\",\"connected_state\":\"CONNECTED\",\"synchronization_health\":\"HEALTHY\"},
 {\"kind\":\"replica\",\"group_id\":\"$G\",\"group_name\":\"ag1\",\"cluster_type\":\"WSFC\",\"is_distributed\":0,\"primary_replica\":\"$2\",\"replica_server\":\"b\",\"availability_mode\":\"ASYNCHRONOUS_COMMIT\",\"is_local\":0,\"role\":\"SECONDARY\",\"connected_state\":\"CONNECTED\",\"synchronization_health\":\"HEALTHY\"},
 {\"kind\":\"replica\",\"group_id\":\"$DG\",\"group_name\":\"dag\",\"is_distributed\":1,\"primary_replica\":\"ag1\",\"replica_server\":\"ag1\",\"is_local\":1,\"role\":\"PRIMARY\",\"connected_state\":\"CONNECTED\",\"synchronization_health\":\"HEALTHY\"},
 {\"kind\":\"replica\",\"group_id\":\"$DG\",\"group_name\":\"dag\",\"is_distributed\":1,\"primary_replica\":\"ag1\",\"replica_server\":\"ag2\",\"is_local\":0,\"role\":\"SECONDARY\",\"connected_state\":\"CONNECTED\",\"synchronization_health\":\"HEALTHY\"},
 {\"kind\":\"database\",\"group_id\":\"$G\",\"group_name\":\"ag1\",\"replica_server\":\"b\",\"database_name\":\"sales\",\"is_local\":0,\"is_primary_replica\":0,\"synchronization_state\":\"SYNCHRONIZING\",\"synchronization_health\":\"HEALTHY\",\"is_suspended\":0,\"log_send_queue_kb\":$4,\"redo_queue_kb\":$3,\"redo_rate_kb_s\":1000,\"est_recovery_s\":$(( $3 / 1000 ))},
 {\"kind\":\"listener\",\"group_id\":\"$G\",\"dns_name\":\"ag1-l\",\"port\":1433}]"
}
for m in 6 5 4 3 2 1; do agp $m a 600000 50; done
[ "$(q "select count(*) from pgvigil.mssql_ag_failovers where instance_id=$ST")" = 0 ] || fail "F: a failover without a change of primary"
F=$(q "select string_agg(check_name, ',' order by check_name) from pgvigil.mssql_hadr_findings where instance_id=$ST and object like 'ag1%'")
[ "$F" = "the redo queue is over its threshold" ] || fail "F: the availability findings of the stub: $F"
[ "$(q "select is_distributed || '|' || count(*) from pgvigil.mssql_ag_state where instance_id=$ST and group_name='dag' group by is_distributed")" = "true|2" ] || fail "F: the distributed group"
[ "$(q "select listeners->0->>'dns_name' from pgvigil.mssql_ag_state where instance_id=$ST and group_name='ag1' limit 1")" = ag1-l ] || fail "F: the listener"
agp 0.5 "" 100 50   # a read in the middle of a failover: the group names no primary
[ "$(q "select count(*) from pgvigil.mssql_ag_failovers where instance_id=$ST")|$(q "select distinct primary_replica from pgvigil.mssql_ag_state where instance_id=$ST and group_name='ag1'")" = "0|a" ] || fail "F: a read without a primary lost the last one known"
agp 0 b 100 50
[ "$(q "select old_primary || '>' || new_primary from pgvigil.mssql_ag_failovers where instance_id=$ST")" = "a>b" ] || fail "F: the failover event"
agp 3.5 a 100 50   # an older read imported late: a sample, never the current state, never a second failover
[ "$(q "select count(*) from pgvigil.mssql_ag_failovers where instance_id=$ST")|$(q "select distinct primary_replica from pgvigil.mssql_ag_state where instance_id=$ST and group_name='ag1'")" = "1|b" ] || fail "F: an older read changed the current state"
F=$(q "select string_agg(severity || ':' || check_name, ',' order by check_name) from pgvigil.mssql_hadr_findings where instance_id=$ST")
echo "  the stub's HA/DR findings: $F"
[ "$F" = "warning:a replication agent failed,warning:log shipping is behind its threshold,critical:mirroring is disconnected or suspended,critical:the primary of a group changed,warning:undistributed commands over the threshold" ] || fail "F: the stub's HA/DR findings"
[ "$(q "select string_agg(secondary_server, ',' order by secondary_server) from pgvigil.mssql_logshipping_state where instance_id=$ST and role='secondary' and database_name='sales_ls'")" = "c,d" ] || fail "F: two secondaries carrying one database name are not two rows"
[ "$(q "select object from pgvigil.mssql_hadr_findings where instance_id=$ST and check_name='log shipping is behind its threshold'")" = "secondary / sales_ls on c" ] || fail "F: the log shipping finding names the wrong secondary"
# a replication read of which one part failed: the parts that were read replace their rows, the failed part keeps its own
imp mssql_replication "$ST" "now()" "[{\"kind\":\"collector_error\",\"source\":\"distribution.dbo.MSpublications\",\"message\":\"lock request time out\"},
 {\"kind\":\"subscription\",\"distribution_db\":\"distribution\",\"publisher\":\"a\",\"publisher_db\":\"sales\",\"publication\":\"pub\",\"subscriber\":\"s\",\"subscriber_db\":\"copy\",\"subscription_type\":\"push\",\"agent_type\":\"distribution\",\"agent_name\":\"d1\",\"runstatus\":6,\"status_text\":\"login failed again\",\"last_run_utc\":\"$(date -u +%FT%TZ)\",\"delivery_rate\":50,\"undistributed\":260000,\"est_catchup_s\":5200},
 {\"kind\":\"agent\",\"distribution_db\":\"distribution\",\"agent_type\":\"logreader\",\"agent_name\":\"lr1\",\"publisher\":\"a\",\"publisher_db\":\"sales\",\"runstatus\":4,\"status_text\":\"idle\"}]"
[ "$(q "select string_agg(kind || ':' || coalesce(status_text, publication), ',' order by kind) from pgvigil.mssql_replication_state where instance_id=$ST")" = "agent:idle,publication:pub,subscription:login failed again" ] \
  || fail "F: a partly failed replication read: $(q "select string_agg(kind || ':' || coalesce(status_text, publication), ',' order by kind) from pgvigil.mssql_replication_state where instance_id=$ST")"
# a job history row read twice across a change of the server's offset (its instant moves an hour) is stored once
JR='{"kind":"run","history_id":77,"job_id":"J-1","job_name":"j","step_id":0,"run_date":20261101,"run_time":13000,"run_status":1,"duration_s":5,"message":"The job succeeded."'
imp mssql_jobs "$ST" "now() - interval '2 minutes'" "[$JR,\"run_utc\":\"$(date -u -d '-3 hours' +%FT%TZ)\"}]"
imp mssql_jobs "$ST" "now() - interval '1 minute'" "[$JR,\"run_utc\":\"$(date -u -d '-2 hours' +%FT%TZ)\"},{\"kind\":\"cursor\",\"last_history_id\":77,\"mark\":4242}]"
[ "$(q "select count(*) from pgvigil.mssql_job_runs where instance_id=$ST")|$(q "select pgvigil.mssql_hadr_cursor($ST, 'jobs') || '/' || pgvigil.mssql_hadr_cursor($ST, 'jobs_mark')")" = "1|77/4242" ] || fail "F: a history row read twice, or the cursor with its mark"
OLD=$(date -u -d '-40 days' +%FT%TZ); OLD1=$(date -u -d '-40 days +1 hour' +%FT%TZ); OLDF=$(date -u -d '-3 days' +%FT%TZ); BORN=$(date -u -d '-30 hours' +%FT%TZ); OLDB=$(date -u -d '-20 days' +%FT%TZ)
imp mssql_backups "$ST" "now() - interval '1 minute'" "[{\"kind\":\"database\",\"database_name\":\"sales\",\"state\":\"ONLINE\",\"recovery_model\":\"FULL\",\"created_utc\":\"$OLD\",\"is_snapshot\":0,\"is_read_only\":0,\"is_standby\":0,\"ag_group_id\":\"$G\",\"ag_name\":\"ag1\"},
 {\"kind\":\"database\",\"database_name\":\"solo\",\"state\":\"ONLINE\",\"recovery_model\":\"SIMPLE\",\"created_utc\":\"$OLD\",\"is_snapshot\":0,\"is_read_only\":0,\"is_standby\":0},
 {\"kind\":\"database\",\"database_name\":\"kept\",\"state\":\"ONLINE\",\"recovery_model\":\"SIMPLE\",\"created_utc\":\"$OLD\",\"is_snapshot\":0,\"is_read_only\":0,\"is_standby\":0},
 {\"kind\":\"database\",\"database_name\":\"tempdb\",\"state\":\"ONLINE\",\"recovery_model\":\"SIMPLE\",\"created_utc\":\"$OLD\"},
 {\"kind\":\"database\",\"database_name\":\"off\",\"state\":\"OFFLINE\",\"recovery_model\":\"FULL\",\"created_utc\":\"$OLD\"},
 {\"kind\":\"database\",\"database_name\":\"snap\",\"state\":\"ONLINE\",\"recovery_model\":\"FULL\",\"created_utc\":\"$OLD\",\"is_snapshot\":1},
 {\"kind\":\"database\",\"database_name\":\"reborn\",\"state\":\"ONLINE\",\"recovery_model\":\"SIMPLE\",\"created_utc\":\"$BORN\",\"is_snapshot\":0,\"is_read_only\":0,\"is_standby\":0},
 {\"kind\":\"backup\",\"database_name\":\"reborn\",\"backup_type\":\"full\",\"sink\":\"backup\",\"finish_utc\":\"$OLDB\",\"size_bytes\":5,\"device\":\"disk\"},
 {\"kind\":\"backup\",\"database_name\":\"kept\",\"backup_type\":\"full\",\"sink\":\"backup\",\"finish_utc\":\"$OLDF\",\"size_bytes\":1000,\"device\":\"disk\"},
 {\"kind\":\"history\",\"backup_sets\":1,\"oldest_utc\":\"$OLDF\"}]"
F=$(q "select string_agg(object || '=' || severity || ':' || check_name, ', ' order by object) from pgvigil.mssql_jobs_findings where instance_id=$ST")
echo "  the stub's backup findings: $F"
[ "$F" = "reborn=critical:no full backup ever, sales=info:backups not judged: a replica of the group is not monitored, solo=critical:no full backup ever" ] || fail "F: the stub's backup findings"
D=$(q "select detail from pgvigil.mssql_jobs_findings where instance_id=$ST and object='reborn'")
echo "  the re-created database's finding: $D"
[[ $D == "database reborn (simple): created or restored ${BORN:0:10} ${BORN:11:5} UTC; no full backup since"*"is not counted." ]] || fail "F: the finding does not say when the database was created or restored"
[ "$(q "select string_agg(database_name || ':' || not_judged, ', ' order by database_name) from pgvigil.mssql_backup_judged where instance_id=$ST and not_judged is not null")" \
  = "off:the database is offline, snap:a database snapshot, tempdb:tempdb is never backed up" ] || fail "F: what is not judged"
# msdb's history trimmed: the next read lists no backup of 'kept'; the repository keeps the one it saw - also when
# the database's creation time comes back an hour off (the server's offset changed between the two reads)
imp mssql_backups "$ST" "now()" "[{\"kind\":\"database\",\"database_name\":\"kept\",\"state\":\"ONLINE\",\"recovery_model\":\"SIMPLE\",\"created_utc\":\"$OLD1\",\"is_snapshot\":0,\"is_read_only\":0,\"is_standby\":0},{\"kind\":\"history\",\"backup_sets\":0}]"
[ "$(q "select (full_at = '$OLDF'::timestamptz) || '|' || full_bytes from pgvigil.mssql_backup_state where instance_id=$ST and database_name='kept'")" = "true|1000" ] || fail "F: a backup once seen was lost when msdb no longer listed it"
[ "$(q "select count(*) from pgvigil.mssql_backup_state where instance_id=$ST and not is_present")" = 6 ] || fail "F: the databases the server no longer lists are not marked"
echo "F: OK"

echo "--- G. the API"
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
api() { local code; code=$(curl -s -o "$LOG.body" -w '%{http_code}' "$U/api/$1"); [ "$code" = 200 ] || fail "/api/$1 answered $code: $(cat "$LOG.body")"; cat "$LOG.body"; }
FROM=$(date -u -d '-6 hours' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
PYROWS='import json, sys
d = json.load(sys.stdin)
def rows(k):
    t = d.get(k) or {"columns": [], "rows": []}
    return [dict(zip(t["columns"], r)) for r in t["rows"]]'
api "mssql/availability?instance=$I1&from=$FROM&to=$TO" | python3 -c "$PYROWS
reps = [r for r in rows('replicas') if r['group_name'] == '$AG']
assert len(reps) == $NREP and reps[0]['role'] == 'PRIMARY' and reps[0]['replica_server'] == '$SN1', reps
assert len(rows('databases')) >= 1 and len(rows('series')) >= 1 and rows('failovers') == [], (len(rows('series')), rows('failovers'))
assert rows('limits')[0]['redo_queue_kb'] in (512000, '512000'), rows('limits')
assert {r['collection'] for r in rows('reads')} == {'mssql_ag', 'mssql_mirroring', 'mssql_logshipping', 'mssql_replication'}, rows('reads')
assert rows('mirroring') == [] and rows('logshipping') == [] and rows('replication') == []" || fail "G: /api/mssql/availability"
api "mssql/availability?instance=$ST&from=$FROM&to=$TO" | python3 -c "$PYROWS
assert len(rows('failovers')) == 1 and len(rows('mirroring')) == 2 and len(rows('logshipping')) == 3 and len(rows('replication')) == 3, d
assert len(rows('findings')) == 5, rows('findings')" || fail "G: /api/mssql/availability of the stub"
api "mssql/availability?instance=$I1&part=reads" | python3 -c "$PYROWS
assert list(d.keys()) == ['reads'], d.keys()" || fail "G: ?part=reads"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$U/api/mssql/availability?instance=$I1&part=nope")" = 400 ] || fail "G: an unknown part"
api "mssql/jobs?instance=$I1&from=$FROM&to=$TO" | python3 -c "$PYROWS
f = [r for r in rows('failed') if r['job'] == '$J1']
assert len(f) == 1 and f[0]['step_id'] == 2 and 'pgvigil proof $SUF: step two fails' in f[0]['message'], f
j = [r for r in rows('jobs') if r['name'] == '$J1']
assert len(j) == 1 and j[0]['last_outcome_text'] == 'failed' and len(j[0]['steps']) == 2, j
assert [r for r in rows('running') if r['name'] == '$J2'], rows('running')
assert [r for r in rows('findings') if r['object'] == '$J1'], rows('findings')
assert rows('read')[0]['history_cursor'] is not None, rows('read')" || fail "G: /api/mssql/jobs"
api "mssql/backups?instance=$I1" | python3 -c "$PYROWS
b = [r for r in rows('databases') if r['database_name'] == '$PDB']
assert len(b) == 1 and b[0]['full_status'] == 'ok' and b[0]['full_device'] == 'disk' and b[0]['nul_type'] == 'log', b
assert float(rows('limits')[0]['new_database_hours']) == 0 and float(rows('limits')[0]['log_backup_minutes']) == 60, rows('limits')" || fail "G: /api/mssql/backups"
kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=
echo "G: OK"

echo "NOT PROVEN: a distributed or contained group, a listener, a Windows cluster (none here); a real mirrored database, log shipping pair or distributor; backupset.time_zone on real rows off UTC; SQL Server 2016-2019, RDS, Managed Instance"
echo "proof-mssql-hadr: PASS (A, B, ${JOINED:+C, }D, E, F, G; $WIRED)"
