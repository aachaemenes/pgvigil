#!/usr/bin/env bash
# Proof of pgvigil's monitoring of SQL Server REPLICATION (task 385; migration 0142, internal/mssql/replication.go)
# on a REAL lab: three SQL Server 2022 containers on one Docker network - a publisher, a REMOTE distributor and a
# subscriber, each container's hostname its @@SERVERNAME (replication connects by that name) - with a transactional
# and a snapshot publication pushed to the subscriber. pgvigil's own collector reads the distributor and the
# publisher into a throwaway repository; what it stores and finds is graded against what sa reads on the nodes.
#
#   scripts/proof-mssql-replication.sh             the proof (below)
#   scripts/proof-mssql-replication.sh lab up      the lab alone, left up (its tag printed); for a trial by hand
#   scripts/proof-mssql-replication.sh lab down <tag>
#                                                  every container and network labelled pgvrepl=<tag>, read back
#
# Needs: docker, openssl, psql, python3, git, curl, node and npm (part N builds the page), a go toolchain at the
# repository root, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
#   PGVIGIL_MSSQL_IMAGE optional; default mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04 (16.0.4315.2, the
#                      only version this proof ran on). SQL Server on Linux runs snapshot and transactional replication;
#                      merge and peer-to-peer are not supported there.
# The nodes publish no port: the collector reaches each at its address on the lab's network, as a monitoring login
# of the proof's own (VIEW SERVER STATE, VIEW ANY DEFINITION, a user in msdb and in distribution with db_datareader;
# never sysadmin, never sa in pgvigil's configuration).
# Passwords: none is printed and none is on a command line: they reach docker and sqlcmd through the environment, by
# name, and a statement that carries one is sent on stdin. The sa password stays in the containers' configuration
# (docker inspect) for the life of the lab, as any MSSQL_SA_PASSWORD does.
#
# What it makes, and removes at the end on every exit path: the lab (its containers and network, read back: 0
# containers, 0 networks, 0 volumes), its own repository database, a temporary folder with the build. What stays: the
# repository's migration creates the cluster-wide NOLOGIN roles pgvigil_* on the PostgreSQL server where they do not
# exist yet, as every pgvigil proof does.
#
# Expected (written before the first run, 2026-11-14; the lab's behaviour read first by a probe on the same image: an
# idle agent rewrites its history row every 60 s, a distribution agent blocked at the subscriber does not, a stopped
# job's agent writes 'The process was successfully stopped.' (runstatus 2), the publisher's 'Repl. Pending Xacts'
# counts the transactions its stopped log reader has not read):
#  A. the lab forms ('LAB UP'): three nodes, each @@SERVERNAME its hostname; the publisher's distributor is the other
#     node (sys.servers' distributor entry names it); 100 rows of the transactional and 50 of the snapshot
#     publication reach the subscriber. The monitoring login exists on the distributor and the publisher and is no
#     sysadmin (IS_SRVROLEMEMBER 0).
#  B. a healthy read, as the monitoring login. On the distributor, mssql_replication 'ok' (not partial): 2 publications
#     (pgvr_tran transactional, pgvr_snap snapshot, 1 article each); 2 subscriptions to <sub>.pgvr_sub, push, active,
#     every row naming the publisher and the subscriber by the containers' names (any case: a remote distributor's
#     tables carry ids of its own server map, MSreplservers, not of its sys.servers - read on the probe);
#     each with sa's agent name; the transactional one's job running and continuous, the snapshot one's job stopped
#     and not continuous; agents: the log reader (running, continuous) and two snapshot agents (not continuous); the
#     undistributed commands per subscription equal sa's MSdistribution_status sum; no failing time, no error, no
#     oldest waiting command; the judged latency 0. On the publisher: no distribution database, one published_db row
#     pgvr_pub with the distributor sa's sys.servers names (another server), pending_xacts equal to sa's counter.
#     Neither instance has a replication finding. One sample per series (5 on the distributor: 2 subscriptions, the
#     log reader, 2 snapshot agents; 1 on the publisher) and one hour row each.
#  C. the trend: 20,000 rows written at the publisher, then a read of both: the publisher's transactions per second
#     above 0 (its counter moved since B), the distributor's undistributed back to 0 within 60 s (read again until).
#     The hour rows count each series' reads.
#  D. the subscriber's table locked (one session holds TABLOCKX for 220 s) and 100 rows written at the publisher.
#     The distributor's instance thresholds set through import_pg_threshold at the INSTANCE level (SQL Server): latency
#     1 / 3 minutes, silent 2 minutes ('done'). At about 150 s: stored undistributed = sa's 100, the oldest waiting
#     command's entry time within 30 s after the write (sa's clock), the judged latency 120 s or more; findings
#     'replication latency over the threshold' (warning) and 'a replication agent writes nothing' (warning) on the
#     transactional subscription and its agent. At about 210 s: the latency finding critical. After the lock ends:
#     within 120 s undistributed 0, latency 0, neither finding.
#  E. the transactional distribution agent's job stopped (sp_stop_job) and 50 rows written: the first read stores
#     job_state 'stopped' and raises nothing; the second raises 'a replication agent is stopped' (warning), its text
#     naming 50 commands waiting. The job started again: within 90 s running, 0 waiting, no finding.
#  F. the log reader's job stopped and 5 transactions written at the publisher. The publisher's instance threshold
#     silent 1 minute. The publisher's first read stores pending_xacts = sa's counter (5 or more) and raises nothing;
#     70 s later 'replicated transactions wait in the log of a published database' (warning), naming the distributor
#     as another server. The distributor at two reads: 'a replication agent is stopped' on the log reader. The job
#     started again: within 120 s the publisher's pending_xacts 0 and neither finding.
#  G. a row deleted at the subscriber, then updated at the publisher: the distribution agent fails on it. The
#     distributor's instance threshold retrying 1 minute. A read while it fails: 'a replication agent failed'
#     (warning) with error 20598 (sa finds it in MSrepl_errors; the history's error id names SQL Server's generic
#     14151 row, whose text carries the cause) and the text 'The row was not found at the Subscriber';
#     failing_since = sa's first retry or failure row after the agent's last idle or succeeded one (within 2 s).
#     Once that is a minute old: 'a replication agent keeps failing or retrying' and no longer 'failed' - also
#     while a job retry's 'in progress' rows deliver nothing (read on the probe: 'Error executing a batch of
#     commands. Retrying individual commands.', runstatus 3). The row put back at the subscriber: within 150 s no
#     failing time and neither finding.
#  H. the snapshot folder made unwritable and pgvr_snap's snapshot started: a read stores the snapshot agent failed
#     (runstatus 6) with an error text and raises 'a replication agent failed' on it. The folder back, the snapshot
#     run again: succeeded, no finding.
#  I. the trend function: mssql_repl_series over the proof's window from the reads ('reads'): the largest latency
#     120 s or more, the most undistributed 100 or more, one bucket with a failing series and one with a stopped one;
#     over three days from the hours ('hours'): the same largest latency and undistributed. Every hour row's reads =
#     its series' samples in that hour.
#  J. pgvigil.findings (the release join's union) carries the replication findings with source 'mssql_hadr'.
#  K. the read-only statements again: TestHADRStatementsLive as the monitoring login against the real distribution
#     database (its rows returned), go test ./internal/mssql/.
#  L. stubbed rows through the import on a stub instance: a pull subscription's agent ('not here') never 'stopped'; a
#     failed jobs read (collector_error <db>.msdb) leaves job_state NULL and fires nothing; a failed publisher read
#     keeps the last published_db rows; a re-run of one read adds nothing to the hours; an older read imported late
#     changes nothing. import_pg_threshold: repl_latency at a PostgreSQL instance refused 'no SQL Server instance';
#     uptime at a SQL Server instance accepted (as before); amcheck_age at a SQL Server instance refused 'no
#     PostgreSQL instance' (as before).
#  N. the page's wiring (the lead's files, web/src/mssql_hadr.ts and internal/web/q_mssql_hadr.go, task 383): the
#     patch this file carries (wiring_patch) applies to a scratch copy of the tree, its web bundle builds (tsc,
#     esbuild) and its binary serves /api/mssql/availability for the distributor: part replseries answers 2 or more
#     buckets over the proof's window with the largest latency 120 s or more and 100 or more commands waiting; part
#     replication carries the new columns (the transactional subscription running, continuous, latency 0, active);
#     part repllimits the three keys at their defaults (10, 15, 5 minutes); the bundle holds the latency chart.
#  M. everything removed: the lab read back as 0 containers, 0 networks, 0 volumes; the repository database dropped.
#  NOT PROVEN HERE: merge replication (SQL Server on Linux has none; on Windows it waits on the owner's answer to Q10),
#  peer-to-peer, a pull subscription's agent on a live subscriber, an Azure SQL Managed Instance distributor, SQL
#  Server 2016-2019 and 2025, a distributor in an availability group.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*" >&2; exit 1; }
IMG="${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04}"
tag_ok() { [[ "$1" =~ ^[a-z][a-z0-9]{2,39}$ ]]; }

# lab_down <tag>: every container and network labelled pgvrepl=<tag>, and the volumes those containers mounted; read back
lab_down() {
  local tag=$1 vols=() left_c left_n left_v=0
  for c in $(docker ps -a -q --filter "label=pgvrepl=$tag"); do
    while read -r v; do [[ -n "$v" ]] && vols+=("$v"); done < <(docker inspect -f '{{range .Mounts}}{{if .Name}}{{println .Name}}{{end}}{{end}}' "$c" 2>/dev/null || true)
    docker rm -f -v "$c" >/dev/null 2>&1 || true
  done
  for c in $(docker network ls -q --filter "label=pgvrepl=$tag"); do docker network rm "$c" >/dev/null 2>&1 || true; done
  for v in ${vols[@]+"${vols[@]}"}; do if docker volume inspect "$v" >/dev/null 2>&1; then left_v=$((left_v + 1)); fi; done
  left_c=$(docker ps -a -q --filter "label=pgvrepl=$tag" | wc -l); left_n=$(docker network ls -q --filter "label=pgvrepl=$tag" | wc -l)
  echo "cleanup of $tag: containers left $left_c, networks left $left_n, volumes left $left_v"
  [[ $left_c == 0 && $left_n == 0 && $left_v == 0 ]]
}

# ---- the lab: three nodes, named by the run's hex so two runs never share a name
HX=${PGVIGIL_REPL_HEX:-$(openssl rand -hex 3)}
TAG="pgvrepl$HX"; NET="$TAG-net"
PUB="rpub$HX"; DIST="rdist$HX"; SUB="rsub$HX"     # container name = hostname = @@SERVERNAME (15 characters at most)
NODES=("$PUB" "$DIST" "$SUB")
SA="${PGVIGIL_REPL_SA:-S$(openssl rand -hex 14)!a}"; DP="D$(openssl rand -hex 14)!a"; PM="M$(openssl rand -hex 14)!a"
export SA DP PM
SQLCMD=()
mask() { sed "s/$SA/<sa>/g; s/$DP/<distributor_admin>/g; s/$PM/<monitor>/g"; }
# Q <node> <sql>: one batch on a node as sa, its rows bare and '|'-separated
Q() { SQLCMDPASSWORD="$SA" docker exec -e SQLCMDPASSWORD "$1" "${SQLCMD[@]}" -S localhost -U sa -b -I -h -1 -W -s '|' -Q "SET NOCOUNT ON; $2"; }
# QIN <node>: the batch on stdin, as sa; it may name the passwords as the sqlcmd variables $(SA), $(DP) and $(PM)
QIN() { SQLCMDPASSWORD="$SA" docker exec -i -e SQLCMDPASSWORD -e SA -e DP -e PM "$1" "${SQLCMD[@]}" -S localhost -U sa -b -I -h -1 -W -s '|' -i /dev/stdin; }
# step <name> <node>: a batch on stdin whose refusal ends the run with the server's own message (masked)
step() { local name=$1 node=$2 out
  if ! out=$(QIN "$node" 2>&1); then printf '%s\n' "$out" | mask; fail "the lab's step '$name' on $node failed"; fi
  [[ -n "$out" ]] && printf '%s\n' "$out" | mask
  return 0; }
# until_is <tries> <seconds> <node> <want> <sql>: the batch's one value read until it is <want>; the last read in $GOT
until_is() { local tries=$1 pause=$2 node=$3 want=$4 sql=$5
  for _ in $(seq 1 "$tries"); do
    GOT=$(Q "$node" "$sql" 2>/dev/null) || GOT=unread
    [[ "$GOT" == "$want" ]] && return 0
    sleep "$pause"
  done
  return 1; }

lab_up() {
  if [[ -n "$(docker ps -a -q --filter "label=pgvrepl=$TAG")$(docker network ls -q --filter "label=pgvrepl=$TAG")" ]] || docker network inspect "$NET" >/dev/null 2>&1; then
    fail "the tag $TAG is taken (a container or a network of it exists); nothing was touched"
  fi
  echo "== lab $TAG: three $IMG containers on $NET (publisher $PUB, distributor $DIST, subscriber $SUB)"
  docker network create --label "pgvrepl=$TAG" "$NET" >/dev/null; LAB=1
  for n in "${NODES[@]}"; do
    MSSQL_SA_PASSWORD="$SA" docker run -d --name "$n" --hostname "$n" --network "$NET" --label "pgvrepl=$TAG" \
      -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD -e MSSQL_AGENT_ENABLED=true \
      -e MSSQL_MEMORY_LIMIT_MB="${PGVIGIL_REPL_MEMORY_MB:-2048}" "$IMG" >/dev/null 2>&1 \
      || fail "docker run of $n refused"
  done
  for n in "${NODES[@]}"; do
    local up=0
    for _ in $(seq 1 120); do
      [[ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null || true)" == true ]] || { docker logs --tail 20 "$n" 2>&1 | mask; fail "$n stopped at its start"; }
      if [[ ${#SQLCMD[@]} == 0 ]]; then
        if docker exec "$n" test -x /opt/mssql-tools18/bin/sqlcmd; then SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -C)
        elif docker exec "$n" test -x /opt/mssql-tools/bin/sqlcmd; then SQLCMD=(/opt/mssql-tools/bin/sqlcmd)
        else fail "the image $IMG has no sqlcmd under /opt/mssql-tools18/bin or /opt/mssql-tools/bin"; fi
      fi
      if Q "$n" "SELECT 1" >/dev/null 2>&1; then up=1; break; fi
      sleep 3
    done
    [[ $up == 1 ]] || { docker logs --tail 20 "$n" 2>&1 | mask; fail "$n did not answer in 360 s"; }
    local sn; sn=$(Q "$n" "SELECT @@SERVERNAME")
    [[ "$sn" == "$n" ]] || fail "$n: @@SERVERNAME is '$sn', not the hostname (replication connects by that name)"
    echo "  $n up: @@SERVERNAME $sn, $(Q "$n" "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))")"
  done
  # SQL Server Agent runs every replication agent: wait until it is up on the distributor
  until_is 40 3 "$DIST" 1 "SELECT COUNT(*) FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%' AND status_desc = N'Running'" \
    || fail "SQL Server Agent is not running on $DIST ($GOT)"

  echo "== the distributor $DIST"
  docker exec -u 0 "$DIST" bash -c 'mkdir -p /var/opt/mssql/ReplData && chown mssql /var/opt/mssql/ReplData' || fail "the snapshot folder on $DIST"
  step distributor "$DIST" <<SQL
EXEC sp_adddistributor @distributor = @@SERVERNAME, @password = N'\$(DP)';
EXEC sp_adddistributiondb @database = N'distribution', @security_mode = 1;
EXEC sp_adddistpublisher @publisher = N'$PUB', @distribution_db = N'distribution', @security_mode = 0, @login = N'sa', @password = N'\$(SA)',
     @working_directory = N'/var/opt/mssql/ReplData', @trusted = N'false', @thirdparty_flag = 0, @publisher_type = N'MSSQLSERVER';
SQL
  echo "== the subscriber $SUB"
  step subscriber "$SUB" <<SQL
CREATE DATABASE pgvr_sub;
SQL
  echo "== the publisher $PUB (its distributor is $DIST)"
  step publisher "$PUB" <<SQL
EXEC sp_adddistributor @distributor = N'$DIST', @password = N'\$(DP)';
CREATE DATABASE pgvr_pub;
GO
USE pgvr_pub;
CREATE TABLE dbo.t_tran (id int NOT NULL PRIMARY KEY, v nvarchar(200) NOT NULL);
CREATE TABLE dbo.t_snap (id int NOT NULL PRIMARY KEY, v nvarchar(200) NOT NULL);
INSERT dbo.t_tran (id, v) SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY (SELECT 0)), N'seed' FROM sys.all_objects;
INSERT dbo.t_snap (id, v) SELECT TOP (50) ROW_NUMBER() OVER (ORDER BY (SELECT 0)), N'seed' FROM sys.all_objects;
EXEC sp_replicationdboption @dbname = N'pgvr_pub', @optname = N'publish', @value = N'true';
GO
USE pgvr_pub;
EXEC sp_addlogreader_agent @job_login = NULL, @job_password = NULL,
     @publisher_security_mode = 0, @publisher_login = N'sa', @publisher_password = N'\$(SA)';
EXEC sp_addpublication @publication = N'pgvr_tran', @status = N'active', @allow_push = N'true', @repl_freq = N'continuous',
     @independent_agent = N'true', @immediate_sync = N'true', @sync_method = N'concurrent';
EXEC sp_addpublication_snapshot @publication = N'pgvr_tran', @frequency_type = 1, @job_login = NULL, @job_password = NULL,
     @publisher_security_mode = 0, @publisher_login = N'sa', @publisher_password = N'\$(SA)';
EXEC sp_addarticle @publication = N'pgvr_tran', @article = N't_tran', @source_owner = N'dbo', @source_object = N't_tran',
     @type = N'logbased', @destination_owner = N'dbo', @destination_table = N't_tran';
EXEC sp_addsubscription @publication = N'pgvr_tran', @subscriber = N'$SUB', @destination_db = N'pgvr_sub', @subscription_type = N'Push',
     @sync_type = N'automatic', @article = N'all', @update_mode = N'read only', @subscriber_type = 0;
EXEC sp_addpushsubscription_agent @publication = N'pgvr_tran', @subscriber = N'$SUB', @subscriber_db = N'pgvr_sub',
     @subscriber_security_mode = 0, @subscriber_login = N'sa', @subscriber_password = N'\$(SA)', @job_login = NULL, @job_password = NULL,
     @frequency_type = 64, @frequency_interval = 0, @frequency_relative_interval = 0, @frequency_recurrence_factor = 0,
     @frequency_subday = 0, @frequency_subday_interval = 0, @active_start_time_of_day = 0, @active_end_time_of_day = 235959,
     @active_start_date = 0, @active_end_date = 0, @dts_package_location = N'Distributor';
EXEC sp_addpublication @publication = N'pgvr_snap', @status = N'active', @allow_push = N'true', @repl_freq = N'snapshot',
     @independent_agent = N'true', @immediate_sync = N'false';
EXEC sp_addpublication_snapshot @publication = N'pgvr_snap', @frequency_type = 1, @job_login = NULL, @job_password = NULL,
     @publisher_security_mode = 0, @publisher_login = N'sa', @publisher_password = N'\$(SA)';
EXEC sp_addarticle @publication = N'pgvr_snap', @article = N't_snap', @source_owner = N'dbo', @source_object = N't_snap',
     @destination_owner = N'dbo', @destination_table = N't_snap';
EXEC sp_addsubscription @publication = N'pgvr_snap', @subscriber = N'$SUB', @destination_db = N'pgvr_sub', @subscription_type = N'Push',
     @sync_type = N'automatic', @article = N'all', @update_mode = N'read only', @subscriber_type = 0;
EXEC sp_addpushsubscription_agent @publication = N'pgvr_snap', @subscriber = N'$SUB', @subscriber_db = N'pgvr_sub',
     @subscriber_security_mode = 0, @subscriber_login = N'sa', @subscriber_password = N'\$(SA)', @job_login = NULL, @job_password = NULL,
     @frequency_type = 1, @frequency_interval = 0, @frequency_relative_interval = 0, @frequency_recurrence_factor = 0,
     @frequency_subday = 0, @frequency_subday_interval = 0, @active_start_time_of_day = 0, @active_end_time_of_day = 235959,
     @active_start_date = 0, @active_end_date = 0, @dts_package_location = N'Distributor';
EXEC sp_startpublication_snapshot @publication = N'pgvr_tran';
EXEC sp_startpublication_snapshot @publication = N'pgvr_snap';
SQL
  # the transactional subscription is initialised by its continuous distribution agent; the snapshot one by a run of
  # its agent after the snapshot
  until_is 60 5 "$SUB" 100 "SELECT CASE WHEN OBJECT_ID(N'pgvr_sub.dbo.t_tran') IS NULL THEN -1 ELSE (SELECT COUNT(*) FROM pgvr_sub.dbo.t_tran) END" \
    || fail "the transactional subscription did not reach 100 rows in 300 s (last read $GOT)"
  echo "  pgvr_tran: 100 rows at $SUB"
  until_is 40 3 "$DIST" 2 "SELECT TOP (1) h.runstatus FROM distribution.dbo.MSsnapshot_agents a JOIN distribution.dbo.MSsnapshot_history h ON h.agent_id = a.id WHERE a.publication = N'pgvr_snap' ORDER BY h.time DESC, h.timestamp DESC" \
    || fail "the snapshot of pgvr_snap did not succeed in 120 s (last runstatus $GOT)"
  local sj; sj=$(Q "$DIST" "SELECT a.name FROM distribution.dbo.MSdistribution_agents a WHERE a.publication = N'pgvr_snap' AND a.subscriber_db = N'pgvr_sub'")
  Q "$DIST" "EXEC msdb.dbo.sp_start_job @job_name = N'$sj'" >/dev/null || fail "start of the snapshot subscription's agent $sj"
  until_is 40 3 "$SUB" 50 "SELECT CASE WHEN OBJECT_ID(N'pgvr_sub.dbo.t_snap') IS NULL THEN -1 ELSE (SELECT COUNT(*) FROM pgvr_sub.dbo.t_snap) END" \
    || fail "the snapshot subscription did not reach 50 rows in 120 s (last read $GOT)"
  echo "  pgvr_snap: 50 rows at $SUB"
  echo "LAB UP $TAG"
}

LAB=
if [[ "${1:-}" == lab ]]; then
  for t in docker openssl; do command -v $t >/dev/null || fail "$t is not on this machine"; done
  case "${2:-}" in
    up)
      trap 'rc=$?; if [[ $rc != 0 && -n "$LAB" ]]; then lab_down "$TAG" || true; fi; exit $rc' EXIT
      lab_up
      echo "left up: ${NODES[*]} on $NET (remove with: scripts/proof-mssql-replication.sh lab down $TAG)"
      exit 0 ;;
    down)
      tag_ok "${3:-}" || fail "lab down needs the lab's tag"
      lab_down "$3"; exit $? ;;
    *) fail "lab up | lab down <tag>" ;;
  esac
fi
[[ $# == 0 ]] || fail "unknown argument '$1' (none, or: lab up | lab down <tag>)"
for t in docker openssl psql python3 go git curl node npm; do command -v $t >/dev/null || fail "$t is not on this machine"; done
: "${PGVIGIL_REPO_DSN:?a superuser connection to a PostgreSQL sandbox, in keyword form}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_replproof_$SUF
LM=pgvr_mon_$SUF
NDIST=proof-repl-dist-$SUF; NPUB=proof-repl-pub-$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out
MADE_REPO=; BLOCKER=; SRVPID=
cleanup() {
  rc=$?
  trap - ERR; set +e
  [ -n "$SRVPID" ] && { kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null; }
  [ -n "$BLOCKER" ] && { kill "$BLOCKER" 2>/dev/null; wait "$BLOCKER" 2>/dev/null; }
  if [ -n "$LAB" ]; then lab_down "$TAG" || { echo "CLEANUP: the lab $TAG is not removed in full" >&2; [ $rc = 0 ] && rc=1; }; fi
  [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK"
  [ $rc = 0 ] && echo "M: OK (the lab and the repository removed)"
  exit $rc
}
trap cleanup EXIT
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR
# wiring_patch: the page's lines for the lead's files (task 383's), as the lead applies them at the join
wiring_patch() { cat <<'PATCH'
diff -ru a/docs/sqlserver-hadr.md b/docs/sqlserver-hadr.md
--- a/docs/sqlserver-hadr.md	2026-11-14 09:32:01.484310526 -0800
+++ b/docs/sqlserver-hadr.md	2026-11-14 09:32:37.582895779 -0800
@@ -70,7 +70,7 @@
 
 - **Mirroring**: role, state, safety level, partner, witness and its state, the send and redo queues.
 - **Log shipping**: per primary database the last log backup, per secondary the last copy and restore, each against the threshold its own configuration in msdb names. A monitor server lists every secondary; two secondaries that carry the same database name are two rows.
-- **Replication**, as the distributor knows it: publications, subscriptions with the distribution agent's last status, the commands not yet delivered (the distribution database's view `MSdistribution_status`) and the time to deliver them at the agent's last rate, and the log reader, snapshot and merge agents with their last status. **No tracer token is ever written and no replication procedure is called.** A publisher whose distributor is another server is read there: add the distributor as an instance. A distribution database the login cannot enter is named in the collection's note with the missing right (a distribution database on a secondary replica that takes no connections reads the same way: read it on the primary). When one of the three reads of a distribution database fails, the rows of the reads that worked are replaced and the failed read's rows stay as last read.
+- **Replication**, as the distributor knows it: publications, subscriptions with the distribution agent's last status, the commands not yet delivered (the distribution database's view `MSdistribution_status`) and the time to deliver them at the agent's last rate, and the log reader, snapshot and merge agents with their last status. **No tracer token is ever written and no replication procedure is called.** A publisher whose distributor is another server is read there: add the distributor as an instance. A distribution database the login cannot enter is named in the collection's note with the missing right (a distribution database on a secondary replica that takes no connections reads the same way: read it on the primary). When one of the three reads of a distribution database fails, the rows of the reads that worked are replaced and the failed read's rows stay as last read. The publisher side, each agent's job, failing time and error text, the latency trend and the replication thresholds: [SQL Server replication](sqlserver-replication.md).
 
 ## Agent jobs
 
diff -ru a/internal/web/q_mssql_hadr.go b/internal/web/q_mssql_hadr.go
--- a/internal/web/q_mssql_hadr.go	2026-11-14 09:32:01.481723795 -0800
+++ b/internal/web/q_mssql_hadr.go	2026-11-14 09:32:37.582711904 -0800
@@ -140,14 +140,30 @@
        snapshot_at
   FROM pgvigil.mssql_logshipping_state WHERE instance_id = $1 ORDER BY role, database_name`
 
+// the judged latency of a subscription is the age of the oldest command waiting for it (0 when none waits; 0142)
 const sqlMSSQLReplication = `
 SELECT kind, distribution_db, publisher, publisher_db, publication, publication_type, articles, subscriber, subscriber_db,
-       subscription_type, agent_type, agent_name, runstatus,
+       subscription_type, subscription_status, agent_type, agent_name, runstatus,
        CASE runstatus WHEN 1 THEN 'started' WHEN 2 THEN 'succeeded' WHEN 3 THEN 'in progress' WHEN 4 THEN 'idle'
                       WHEN 5 THEN 'retrying' WHEN 6 THEN 'failed' END AS status,
-       status_text, last_run_at, latency_ms, delivery_rate, undistributed, est_catchup_s, snapshot_at
+       status_text, last_run_at, latency_ms, delivery_rate, undistributed, est_catchup_s, snapshot_at,
+       job_state, continuous, failing_since, error_code, error_text, oldest_pending_at,
+       CASE WHEN kind = 'subscription' THEN CASE WHEN coalesce(undistributed, 0) = 0 THEN 0
+            ELSE greatest(0, extract(epoch FROM snapshot_at - oldest_pending_at)) END END AS latency_s,
+       database_name, distributor, distributor_local, log_reuse_wait, pending_xacts
   FROM pgvigil.mssql_replication_state WHERE instance_id = $1
- ORDER BY CASE kind WHEN 'publication' THEN 0 WHEN 'subscription' THEN 1 ELSE 2 END, publisher, publisher_db, publication, subscriber, agent_name`
+ ORDER BY CASE kind WHEN 'publication' THEN 0 WHEN 'subscription' THEN 1 WHEN 'agent' THEN 2 ELSE 3 END, publisher, publisher_db, publication,
+          subscriber, agent_name, database_name`
+
+// the replication trend (pgvigil.mssql_repl_series: the reads up to two days, the hours past that) and the
+// replication thresholds in force (pg_threshold: the instance's own, its tag's, the root's, the default)
+const sqlMSSQLReplSeries = `SELECT * FROM pgvigil.mssql_repl_series($1, $2, $3, $4)`
+
+const sqlMSSQLReplLimits = `
+SELECT k.key, k.label, k.unit, t.warn, t.crit, t.level, t.tag
+  FROM pgvigil.pg_threshold_keys k CROSS JOIN LATERAL pgvigil.pg_threshold($1, k.key) t
+ WHERE k.key IN ('repl_latency', 'repl_agent_retrying', 'repl_agent_silent')
+ ORDER BY k.key`
 
 const sqlMSSQLHADRFindings = `
 SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_hadr_findings
@@ -187,6 +203,8 @@
 		{"mirroring", sqlMSSQLMirroring, []any{id}},
 		{"logshipping", sqlMSSQLLogShipping, []any{id}},
 		{"replication", sqlMSSQLReplication, []any{id}},
+		{"replseries", sqlMSSQLReplSeries, []any{id, from, to, step}},
+		{"repllimits", sqlMSSQLReplLimits, []any{id}},
 		{"findings", sqlMSSQLHADRFindings, []any{id}},
 		{"limits", sqlMSSQLHADRLimits, []any{id}},
 		{"reads", sqlMSSQLHADRReads, []any{id}},
diff -ru a/web/src/mssql_hadr.ts b/web/src/mssql_hadr.ts
--- a/web/src/mssql_hadr.ts	2026-11-14 09:32:01.478859373 -0800
+++ b/web/src/mssql_hadr.ts	2026-11-14 09:32:37.582862336 -0800
@@ -9,7 +9,7 @@
 import { Ctx, href, rangeLabel, window_ } from './router';
 import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';
 
-type Parts = 'replicas' | 'databases' | 'distributed' | 'series' | 'failovers' | 'mirroring' | 'logshipping' | 'replication' | 'findings' | 'limits' | 'reads';
+type Parts = 'replicas' | 'databases' | 'distributed' | 'series' | 'failovers' | 'mirroring' | 'logshipping' | 'replication' | 'replseries' | 'repllimits' | 'findings' | 'limits' | 'reads';
 
 export const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
 
@@ -129,19 +129,46 @@
   { key: 'publisher' }, { key: 'publisher_db', label: 'database' }, { key: 'publication' },
   { key: 'publication_type', label: 'type' }, { key: 'articles', num: true }, { key: 'distribution_db', label: 'distribution database' },
 ];
+// an agent's job: running, stopped, disabled, 'not here' (a pull subscription's agent runs at the subscriber); a job
+// meant to run all the time (-Continuous) that is not running is marked
+const jobCell = (v: unknown, r: Row) => v == null ? 'not read' : `${String(v)}${r.continuous === true ? ' (continuous)' : ''}`;
+const jobCls = (v: unknown, r: Row) => r.continuous === true && v != null && v !== 'running' && v !== 'not here' ? 'warn' : '';
+const errCell = (v: unknown, r: Row) => v == null && r.error_text == null ? '' : `${v != null ? `${String(v)}: ` : ''}${String(r.error_text ?? '')}`;
 const subCols: Col[] = [
   { key: 'publication' }, { key: 'publisher_db', label: 'from' },
   { key: 'subscriber', fmt: (v, r) => `${String(v ?? '')}.${String(r.subscriber_db ?? '')}` },
-  { key: 'subscription_type', label: 'type' }, { key: 'status', cls: (_, r) => statusCls(r.runstatus) },
+  { key: 'subscription_type', label: 'type' }, { key: 'subscription_status', label: 'subscription' },
+  { key: 'status', cls: (_, r) => statusCls(r.runstatus) },
+  { key: 'job_state', label: 'job', fmt: jobCell, cls: jobCls },
   { key: 'undistributed', label: 'undistributed commands', num: true },
+  { key: 'latency_s', label: 'latency (oldest waiting)', num: true, fmt: fmtSecs },
   { key: 'est_catchup_s', label: 'est. to deliver', num: true, fmt: fmtSecs },
-  { key: 'latency_ms', label: 'latency (ms)', num: true }, { key: 'last_run_at', label: 'last report', fmt: fmtTime },
-  { key: 'status_text', label: 'message', wide: true },
+  { key: 'latency_ms', label: 'agent latency (ms)', num: true },
+  { key: 'failing_since', label: 'failing since', fmt: fmtTime, cls: v => v == null ? '' : 'crit' },
+  { key: 'last_run_at', label: 'last report', fmt: fmtTime },
+  { key: 'status_text', label: 'message', wide: true }, { key: 'error_code', label: 'error', fmt: errCell, wide: true },
 ];
 const agentCols: Col[] = [
   { key: 'agent_type', label: 'agent' }, { key: 'agent_name', label: 'name' }, { key: 'publisher_db', label: 'database' },
   { key: 'publication' }, { key: 'status', cls: (_, r) => statusCls(r.runstatus) },
+  { key: 'job_state', label: 'job', fmt: jobCell, cls: jobCls },
+  { key: 'failing_since', label: 'failing since', fmt: fmtTime, cls: v => v == null ? '' : 'crit' },
   { key: 'last_run_at', label: 'last report', fmt: fmtTime }, { key: 'status_text', label: 'message', wide: true },
+  { key: 'error_code', label: 'error', fmt: errCell, wide: true },
+];
+// the publisher side: each published database of this server, the distributor it names and what waits in its log
+const pubDbCols: Col[] = [
+  { key: 'database_name', label: 'database' }, { key: 'publication_type', label: 'publishes' },
+  { key: 'distributor', fmt: (v, r) => v == null ? 'none named' : `${String(v)}${r.distributor_local === true ? ' (this server)' : ' (another server)'}` },
+  { key: 'pending_xacts', label: 'transactions waiting for the log reader', num: true, cls: v => Number(v ?? 0) > 0 ? 'warn' : '' },
+  { key: 'log_reuse_wait', label: 'log reuse wait', fmt: words },
+  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
+];
+const replSeriesCols: Col[] = [
+  { key: 'snapshot_at', label: 'time', fmt: fmtTime }, { key: 'latency_s', label: 'latency, worst', num: true, fmt: fmtSecs },
+  { key: 'undistributed', label: 'commands waiting', num: true }, { key: 'delivery_rate', label: 'delivered / s', num: true, fmt: fmtNum },
+  { key: 'pending_xacts', label: 'transactions pending at the publisher', num: true }, { key: 'trans_per_s', label: 'read out / s', num: true, fmt: fmtNum },
+  { key: 'failing', label: 'failing agents', num: true }, { key: 'stopped', label: 'stopped agents', num: true }, { key: 'source', label: 'from' },
 ];
 
 // groupKind: what a group is, in words (the catalog's own flags)
@@ -306,10 +333,24 @@
     if (mirroring.length) sec.append(el('h3', {}, 'Database mirroring'), grid(mirroring, mirrorCols));
     if (shipping.length) sec.append(el('h3', {}, 'Log shipping'), grid(shipping, shipCols));
     if (repl.length) {
-      sec.append(el('h3', {}, 'Replication (as this distributor knows it)'),
-        el('h4', {}, 'Publications'), grid(repl.filter(r => r.kind === 'publication'), pubCols, 'No publication.'),
+      sec.append(el('h3', {}, 'Replication'));
+      const published = repl.filter(r => r.kind === 'published_db');
+      if (published.length) sec.append(el('h4', {}, 'Published databases (this server as publisher)'), grid(published, pubDbCols));
+      if (repl.some(r => r.kind !== 'published_db')) sec.append(
+        el('h4', {}, 'Publications (as this distributor knows them)'), grid(repl.filter(r => r.kind === 'publication'), pubCols, 'No publication.'),
         el('h4', {}, 'Subscriptions'), grid(repl.filter(r => r.kind === 'subscription'), subCols, 'No subscription.'),
         el('h4', {}, 'Log reader, snapshot and merge agents'), grid(repl.filter(r => r.kind === 'agent'), agentCols, 'No agent.'));
+      // the trend: the worst subscription's latency, and what waits at the distributor and in the published logs
+      const rs = rowsOf(d.replseries);
+      sec.append(lineChart('Replication latency: the oldest command waiting (the worst subscription)', rs,
+        [{ key: 'latency_s', label: 'latency' }], v => fmtSecs(v)));
+      sec.append(lineChart('Commands waiting at the distributor and transactions waiting in published logs', rs, [
+        { key: 'undistributed', label: 'commands waiting' }, { key: 'pending_xacts', label: 'transactions pending at the publisher' },
+      ]));
+      sec.append(el('details', {}, el('summary', {}, 'The charts\' numbers as a table'), grid(rs, replSeriesCols, 'No read in this window.')));
+      const lims = rowsOf(d.repllimits);
+      if (lims.length) sec.append(el('p', { class: 'meta' }, 'Thresholds in force: ' + lims.map(l =>
+        `${String(l.label)}: ${l.warn != null ? `warning ${String(l.warn)}` : 'no warning'}${l.crit != null ? `, critical ${String(l.crit)}` : ''} ${String(l.unit)} (${String(l.level)}${l.tag != null ? ` ${String(l.tag)}` : ''})`).join('; ') + '.'));
     }
     // a collection that could not read in full, or at all, says so with its reason; what is shown above is then its last read
     const notOk = reads.filter(r => r.status === 'partial' || r.status === 'error' || (r.status === 'skipped' && r.collection !== 'mssql_ag'));
PATCH
}

if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"
  BIN=$WORK/pgvigil
fi
echo "binary: $BIN ($(git log --oneline -1 2>/dev/null | cut -c1-12 || echo 'no git'))"

lab_up
echo "--- A. the lab"
DNAME=$(Q "$PUB" "SELECT CAST(data_source AS nvarchar(256)) FROM sys.servers WHERE is_distributor = 1")
[[ "${DNAME,,}" == "${DIST,,}" ]] || fail "A: the publisher's distributor is '$DNAME', not $DIST"
for n in "$DIST" "$PUB"; do
  step "monitoring login" "$n" <<SQL
CREATE LOGIN [$LM] WITH PASSWORD = N'\$(PM)', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO [$LM]; GRANT VIEW ANY DEFINITION TO [$LM];
SQL
done
step "monitoring users" "$DIST" <<SQL
USE msdb; CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];
GO
USE distribution; CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];
SQL
for n in "$DIST" "$PUB"; do [ "$(Q "$n" "SELECT IS_SRVROLEMEMBER('sysadmin', N'$LM')")" = 0 ] || fail "A: $LM is sysadmin on $n"; done
D=distribution.dbo
DA_TRAN=$(Q "$DIST" "SELECT name FROM $D.MSdistribution_agents WHERE publication = N'pgvr_tran' AND subscriber_db = N'pgvr_sub'")
DA_SNAP=$(Q "$DIST" "SELECT name FROM $D.MSdistribution_agents WHERE publication = N'pgvr_snap' AND subscriber_db = N'pgvr_sub'")
LR=$(Q "$DIST" "SELECT name FROM $D.MSlogreader_agents")
SN_TRAN=$(Q "$DIST" "SELECT name FROM $D.MSsnapshot_agents WHERE publication = N'pgvr_tran'")
SN_SNAP=$(Q "$DIST" "SELECT name FROM $D.MSsnapshot_agents WHERE publication = N'pgvr_snap'")
echo "  agents: distribution $DA_TRAN / $DA_SNAP, log reader $LR, snapshot $SN_TRAN / $SN_SNAP"
echo "A: OK"

ip_of() { docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$1"; }
export MSSQL_DIST_DSN="sqlserver://$LM:$PM@$(ip_of "$DIST"):1433?database=master&encrypt=true&TrustServerCertificate=true"
export MSSQL_PUB_DSN="sqlserver://$LM:$PM@$(ip_of "$PUB"):1433?database=master&encrypt=true&TrustServerCertificate=true"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $NDIST
    engine: sqlserver
    dsn: env:MSSQL_DIST_DSN
  - name: $NPUB
    engine: sqlserver
    dsn: env:MSSQL_PUB_DSN
EOF
psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" >/dev/null; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
"$BIN" migrate -config "$CFG" >/dev/null
# rd <instance>: one read of mssql_replication; an error or a read that is not 'ok' ends the run
rd() {
  "$BIN" collect -config "$CFG" -once mssql_replication -instance "$1" > "$OUT" 2>&1 || { mask < "$OUT"; fail "the read of $1"; }
  local st; st=$(q "select c.status || ' ' || coalesce(c.note, '') from pgvigil.collection_dates c join pgvigil.instances i using (instance_id) where i.name = '$1' and c.collection = 'mssql_replication'")
  [[ "$st" == "ok "* ]] || fail "the read of $1 is not ok: $st"
}
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
# fnd <instance id>: its replication findings, severity:check:object, sorted
fnd() { q "select coalesce(string_agg(severity || ':' || check_name || ':' || object, ',' order by check_name, object), '') from pgvigil.mssql_repl_findings where instance_id = $1"; }
# detail <instance id> <check>: the finding's text
detail() { q "select detail from pgvigil.mssql_repl_findings where instance_id = $1 and check_name = '$2' limit 1"; }
# thr <instance id> <key> <warn> <crit>: a threshold at the INSTANCE level through the UI's door; inh: back to the level above
thr() { local o; o=$(q "select pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'set', 'key', '$2', 'level', 'instance', 'instance_id', $1, 'warn', $3::numeric, 'crit', $4::numeric, 'ui_user', 'proof'))->>'outcome'")
  [ "$o" = done ] || fail "the threshold $2 at instance $1: $o"; }
inh() { local o; o=$(q "select pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'inherit', 'key', '$2', 'level', 'instance', 'instance_id', $1, 'ui_user', 'proof'))->>'outcome'")
  [ "$o" = done ] || fail "inherit $2 at instance $1: $o"; }
# sv <instance id> <agent name> <expression>: one value of the stored row of an agent
sv() { q "select $3 from pgvigil.mssql_replication_state where instance_id = $1 and agent_name = '$2' and kind in ('subscription', 'agent')"; }
# sa's commands waiting for a distribution agent, its job's state
und_sa() { Q "$DIST" "SELECT ISNULL(SUM(s.UndelivCmdsInDistDB), 0) FROM $D.MSdistribution_status s JOIN $D.MSdistribution_agents a ON a.id = s.agent_id WHERE a.name = N'$1'"; }
job_sa() { Q "$DIST" "SELECT CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'running' ELSE 'stopped' END FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'$1' AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)"; }
pending_sa() { Q "$PUB" "SELECT cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE N'%:Databases%' AND counter_name = N'Repl. Pending Xacts' AND instance_name = N'pgvr_pub'"; }
# poll <tries> <seconds> <test command...>: read the distributor (or the publisher: POLL_ON) until the test holds
poll() { local tries=$1 pause=$2; shift 2
  for _ in $(seq 1 "$tries"); do rd "${POLL_ON:-$NDIST}"; if "$@"; then return 0; fi; sleep "$pause"; done
  return 1; }
# wait_until <seconds> <epoch>: sleep until that many seconds after the epoch (at once when past)
wait_until() { local d=$(( $1 - ($(date +%s) - $2) )); if [ "$d" -gt 0 ]; then sleep "$d"; fi; return 0; }
W0=$(q "select now()")

echo "--- B. a healthy read of the distributor and of the publisher"
until_is 20 3 "$DIST" stopped "$(printf "SELECT CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'running' ELSE 'stopped' END FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'%s' AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)" "$DA_SNAP")" \
  || fail "B: the snapshot subscription's agent is still running after its run (sa reads $GOT)"
rd "$NDIST"; rd "$NPUB"
ID=$(iid "$NDIST"); IP=$(iid "$NPUB")
# the names: every row names the publisher and the subscriber by the containers' own names (any case): a remote
# distributor's tables carry ids of its own server map, never of its sys.servers
got=$(q "select count(*) filter (where lower(publisher) is distinct from lower('$PUB')) || ':' || count(*) filter (where kind = 'subscription' and lower(subscriber) is distinct from lower('$SUB')) || ':' || count(*) from pgvigil.mssql_replication_state where instance_id = $ID")
[ "$got" = "0:0:7" ] || fail "B: rows naming another publisher or subscriber (wrong:wrong:all): $got"
SUBNAME=$(sv "$ID" "$DA_TRAN" subscriber)
got=$(q "select string_agg(publication || ':' || publication_type || ':' || articles, ',' order by publication) from pgvigil.mssql_replication_state where instance_id = $ID and kind = 'publication'")
[ "$got" = "pgvr_snap:snapshot:1,pgvr_tran:transactional:1" ] || fail "B: publications: $got"
got=$(q "select string_agg(agent_name || ':' || subscriber || '.' || subscriber_db || ':' || subscription_type || ':' || subscription_status || ':' || job_state || ':' || continuous, ',' order by publication) from pgvigil.mssql_replication_state where instance_id = $ID and kind = 'subscription'")
[ "$got" = "$DA_SNAP:$SUBNAME.pgvr_sub:push:active:stopped:false,$DA_TRAN:$SUBNAME.pgvr_sub:push:active:running:true" ] || fail "B: subscriptions: $got"
got=$(q "select string_agg(agent_type || ':' || agent_name || ':' || job_state || ':' || continuous, ',' order by agent_type, agent_name) from pgvigil.mssql_replication_state where instance_id = $ID and kind = 'agent'")
want=$(printf 'logreader:%s:running:true,snapshot:%s:stopped:false,snapshot:%s:stopped:false' "$LR" "$(printf '%s\n%s\n' "$SN_SNAP" "$SN_TRAN" | LC_ALL=C sort | head -1)" "$(printf '%s\n%s\n' "$SN_SNAP" "$SN_TRAN" | LC_ALL=C sort | tail -1)")
[ "$got" = "$want" ] || fail "B: agents: $got (want $want)"
for a in "$DA_TRAN" "$DA_SNAP"; do
  [ "$(sv "$ID" "$a" "coalesce(undistributed, 0)")" = "$(und_sa "$a")" ] || fail "B: undistributed of $a: $(sv "$ID" "$a" undistributed), sa $(und_sa "$a")"
done
[ "$(q "select count(*) from pgvigil.mssql_replication_state where instance_id = $ID and (failing_since is not null or error_text is not null or oldest_pending_at is not null)")" = 0 ] || fail "B: a failing time, an error or a waiting command on a healthy distributor"
[ "$(q "select count(*) from pgvigil.mssql_replication_state where instance_id = $IP and kind <> 'published_db'")" = 0 ] || fail "B: the publisher stored distributor rows"
got=$(q "select database_name || ':' || upper(distributor) || ':' || distributor_local || ':' || pending_xacts from pgvigil.mssql_replication_state where instance_id = $IP and kind = 'published_db'")
[ "$got" = "pgvr_pub:${DIST^^}:false:$(pending_sa)" ] || fail "B: the publisher side: $got"
[ -z "$(fnd "$ID")$(fnd "$IP")" ] || fail "B: findings on a healthy lab: $(fnd "$ID") / $(fnd "$IP")"
[ "$(q "select count(*) || ':' || count(distinct series) from pgvigil.mssql_repl_sample where instance_id = $ID")" = "5:5" ] || fail "B: the distributor's samples"
[ "$(q "select count(*) || ':' || min(series) from pgvigil.mssql_repl_sample where instance_id = $IP")" = "1:published:pgvr_pub" ] || fail "B: the publisher's sample"
[ "$(q "select count(*) || ':' || sum(reads) from pgvigil.mssql_repl_hourly where instance_id in ($ID, $IP)")" = "6:6" ] || fail "B: the hour rows"
[ "$(q "select latency_s from pgvigil.mssql_repl_sample where instance_id = $ID and series = 'distribution:$DA_TRAN'")" = 0 ] || fail "B: the judged latency of a subscription with nothing waiting"
echo "B: OK"

echo "--- C. the trend under a write"
Q "$PUB" "INSERT pgvr_pub.dbo.t_tran (id, v) SELECT TOP (20000) 1000 + ROW_NUMBER() OVER (ORDER BY (SELECT 0)), REPLICATE(N'x', 100) FROM sys.all_objects a CROSS JOIN sys.all_objects b" >/dev/null
sleep 5; rd "$NPUB"
[ "$(q "select trans_per_s > 0 from pgvigil.mssql_repl_sample where instance_id = $IP order by snapshot_at desc limit 1")" = t ] || fail "C: the publisher's transactions per second did not move"
tc_drained() { [ "$(sv "$ID" "$DA_TRAN" "coalesce(undistributed, -1)")" = 0 ]; }
poll 6 10 tc_drained || fail "C: the 20,000 commands did not drain in 60 s"
echo "C: OK (delivery rate $(sv "$ID" "$DA_TRAN" delivery_rate) commands/s)"

echo "--- D. the subscriber's table locked: latency and a silent agent"
thr "$ID" repl_latency 1 3; thr "$ID" repl_agent_silent 2 null
( SQLCMDPASSWORD="$SA" docker exec -e SQLCMDPASSWORD "$SUB" "${SQLCMD[@]}" -S localhost -U sa -b -Q "BEGIN TRAN; UPDATE pgvr_sub.dbo.t_tran WITH (TABLOCKX) SET v = v WHERE id = 1; WAITFOR DELAY '00:03:40'; ROLLBACK" >/dev/null 2>&1 ) &
BLOCKER=$!
sleep 3
TW=$(Q "$PUB" "SELECT CONVERT(varchar(23), SYSUTCDATETIME(), 126)"); TWS=$(date +%s)
Q "$PUB" "INSERT pgvr_pub.dbo.t_tran (id, v) SELECT TOP (100) 50000 + ROW_NUMBER() OVER (ORDER BY (SELECT 0)), N'blocked' FROM sys.all_objects" >/dev/null
until_is 30 2 "$DIST" 100 "SELECT ISNULL(SUM(s.UndelivCmdsInDistDB), 0) FROM $D.MSdistribution_status s JOIN $D.MSdistribution_agents a ON a.id = s.agent_id WHERE a.name = N'$DA_TRAN'" \
  || fail "D: sa never saw the 100 commands waiting (last $GOT)"
wait_until 150 "$TWS"
rd "$NDIST"
[ "$(sv "$ID" "$DA_TRAN" undistributed)" = 100 ] || fail "D: undistributed $(sv "$ID" "$DA_TRAN" undistributed), sa 100"
[ "$(sv "$ID" "$DA_TRAN" "oldest_pending_at between '${TW}Z'::timestamptz - interval '2 seconds' and '${TW}Z'::timestamptz + interval '30 seconds'")" = t ] \
  || fail "D: the oldest waiting command's entry time $(sv "$ID" "$DA_TRAN" oldest_pending_at) is not within 30 s after the write at ${TW}Z"
[ "$(q "select latency_s >= 120 from pgvigil.mssql_repl_sample where instance_id = $ID and series = 'distribution:$DA_TRAN' order by snapshot_at desc limit 1")" = t ] || fail "D: the judged latency"
want="warning:a replication agent writes nothing:distribution / $DA_TRAN,warning:replication latency over the threshold:pgvr_tran -> $SUBNAME.pgvr_sub"
[ "$(fnd "$ID")" = "$want" ] || fail "D: the findings at 150 s: $(fnd "$ID") (want $want)"
echo "  $(detail "$ID" 'replication latency over the threshold')"
echo "  $(detail "$ID" 'a replication agent writes nothing')"
[ "$(q "select count(*) from pgvigil.findings where instance_id = $ID and source = 'mssql_hadr' and setting = 'replication latency over the threshold'")" = 1 ] \
  || fail "J: the latency finding is not in pgvigil.findings (source mssql_hadr)"
echo "J: OK (pgvigil.findings carries it, source mssql_hadr)"
wait_until 210 "$TWS"
rd "$NDIST"
want="warning:a replication agent writes nothing:distribution / $DA_TRAN,critical:replication latency over the threshold:pgvr_tran -> $SUBNAME.pgvr_sub"
[ "$(fnd "$ID")" = "$want" ] || fail "D: the findings at 210 s: $(fnd "$ID") (want $want)"
wait "$BLOCKER" 2>/dev/null || true; BLOCKER=
d_clear() { [ "$(sv "$ID" "$DA_TRAN" "coalesce(undistributed, -1)")" = 0 ] && [ -z "$(fnd "$ID")" ]; }
poll 12 10 d_clear || fail "D: not clear 120 s after the lock: undistributed $(sv "$ID" "$DA_TRAN" undistributed), findings $(fnd "$ID")"
inh "$ID" repl_latency; inh "$ID" repl_agent_silent
echo "D: OK"

echo "--- E. the transactional distribution agent's job stopped"
Q "$DIST" "EXEC msdb.dbo.sp_stop_job @job_name = N'$DA_TRAN'" >/dev/null
until_is 15 2 "$DIST" stopped "SELECT CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'running' ELSE 'stopped' END FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'$DA_TRAN' AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)" \
  || fail "E: the job did not stop (sa reads $GOT)"
Q "$PUB" "INSERT pgvr_pub.dbo.t_tran (id, v) SELECT TOP (50) 60000 + ROW_NUMBER() OVER (ORDER BY (SELECT 0)), N'stopped' FROM sys.all_objects" >/dev/null
until_is 30 2 "$DIST" 50 "SELECT ISNULL(SUM(s.UndelivCmdsInDistDB), 0) FROM $D.MSdistribution_status s JOIN $D.MSdistribution_agents a ON a.id = s.agent_id WHERE a.name = N'$DA_TRAN'" \
  || fail "E: sa never saw the 50 commands waiting (last $GOT)"
rd "$NDIST"
[ "$(sv "$ID" "$DA_TRAN" "job_state || ':' || continuous || ':' || undistributed")" = "stopped:true:50" ] || fail "E: the first read: $(sv "$ID" "$DA_TRAN" "job_state || ':' || continuous || ':' || undistributed")"
[ -z "$(fnd "$ID")" ] || fail "E: a finding at the first read of a stopped job: $(fnd "$ID")"
rd "$NDIST"
[ "$(fnd "$ID")" = "warning:a replication agent is stopped:distribution / $DA_TRAN" ] || fail "E: the second read: $(fnd "$ID")"
detail "$ID" 'a replication agent is stopped' | grep -q '50 commands wait' || fail "E: the text: $(detail "$ID" 'a replication agent is stopped')"
echo "  $(detail "$ID" 'a replication agent is stopped')"
Q "$DIST" "EXEC msdb.dbo.sp_start_job @job_name = N'$DA_TRAN'" >/dev/null
e_clear() { [ "$(sv "$ID" "$DA_TRAN" "job_state || ':' || coalesce(undistributed, -1)")" = "running:0" ] && [ -z "$(fnd "$ID")" ]; }
poll 9 10 e_clear || fail "E: not clear 90 s after the start: $(sv "$ID" "$DA_TRAN" "job_state || ':' || undistributed") / $(fnd "$ID")"
echo "E: OK"

echo "--- F. the log reader's job stopped: the publisher side"
thr "$IP" repl_agent_silent 1 null
rd "$NPUB"
[ "$(q "select pending_xacts from pgvigil.mssql_replication_state where instance_id = $IP and kind = 'published_db'")" = 0 ] || fail "F: transactions pending before the stop"
TOK=$(date +%s)
Q "$DIST" "EXEC msdb.dbo.sp_stop_job @job_name = N'$LR'" >/dev/null
until_is 15 2 "$DIST" stopped "SELECT CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'running' ELSE 'stopped' END FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'$LR' AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions)" \
  || fail "F: the log reader's job did not stop (sa reads $GOT)"
for i in 1 2 3 4 5; do Q "$PUB" "INSERT pgvr_pub.dbo.t_tran (id, v) VALUES (7000$i, N'log reader stopped')" >/dev/null; done
until_is 15 2 "$PUB" 5 "SELECT cntr_value FROM sys.dm_os_performance_counters WHERE object_name LIKE N'%:Databases%' AND counter_name = N'Repl. Pending Xacts' AND instance_name = N'pgvr_pub'" \
  || fail "F: sa's counter of pending transactions reads $GOT, not 5"
rd "$NPUB"
[ "$(q "select pending_xacts from pgvigil.mssql_replication_state where instance_id = $IP and kind = 'published_db'")" = 5 ] || fail "F: the stored pending transactions"
[ -z "$(fnd "$IP")" ] || fail "F: a finding at the first read: $(fnd "$IP")"
rd "$NDIST"; rd "$NDIST"
[ "$(fnd "$ID")" = "warning:a replication agent is stopped:logreader / $LR" ] || fail "F: the distributor's findings: $(fnd "$ID")"
wait_until 70 "$TOK"
rd "$NPUB"
[ "$(fnd "$IP")" = "warning:replicated transactions wait in the log of a published database:pgvr_pub" ] || fail "F: the publisher's findings: $(fnd "$IP")"
detail "$IP" 'replicated transactions wait in the log of a published database' | grep -q 'another server' || fail "F: the text does not name the distributor as another server"
echo "  $(detail "$IP" 'replicated transactions wait in the log of a published database')"
Q "$DIST" "EXEC msdb.dbo.sp_start_job @job_name = N'$LR'" >/dev/null
f_clear() { [ "$(q "select pending_xacts from pgvigil.mssql_replication_state where instance_id = $IP and kind = 'published_db'")" = 0 ] && [ -z "$(fnd "$IP")" ]; }
POLL_ON=$NPUB poll 12 10 f_clear || fail "F: the publisher not clear 120 s after the start: $(fnd "$IP")"
f_clear2() { [ "$(sv "$ID" "$LR" job_state)" = running ] && [ -z "$(fnd "$ID")" ]; }
poll 6 10 f_clear2 || fail "F: the distributor not clear: $(fnd "$ID")"
inh "$IP" repl_agent_silent
echo "F: OK"

echo "--- G. a row missing at the subscriber: the agent fails, then keeps retrying"
thr "$ID" repl_agent_retrying 1 null
Q "$SUB" "DELETE pgvr_sub.dbo.t_tran WHERE id = 5" >/dev/null
Q "$PUB" "UPDATE pgvr_pub.dbo.t_tran SET v = N'conflict' WHERE id = 5" >/dev/null
g_failing() { [ "$(sv "$ID" "$DA_TRAN" "failing_since is not null")" = t ]; }
poll 30 5 g_failing || fail "G: no failing time stored in 150 s (runstatus $(sv "$ID" "$DA_TRAN" runstatus))"
AGID=$(Q "$DIST" "SELECT id FROM $D.MSdistribution_agents WHERE name = N'$DA_TRAN'")
FS_SA=$(Q "$DIST" "SELECT CONVERT(varchar(23), MIN(z.time), 126) FROM $D.MSdistribution_history z WHERE z.agent_id = $AGID AND z.runstatus IN (5, 6) AND z.time > ISNULL((SELECT MAX(y.time) FROM $D.MSdistribution_history y WHERE y.agent_id = $AGID AND y.runstatus IN (2, 4)), '19000101')")
[ "$(sv "$ID" "$DA_TRAN" "abs(extract(epoch FROM failing_since - '${FS_SA}Z'::timestamptz)) <= 2")" = t ] || fail "G: failing_since $(sv "$ID" "$DA_TRAN" failing_since), sa ${FS_SA}Z"
[ "$(Q "$DIST" "SELECT COUNT(*) FROM $D.MSrepl_errors WHERE error_code = N'20598'")" -ge 1 ] || fail "G: sa sees no error 20598 in MSrepl_errors"
echo "  sa: failing since ${FS_SA}Z, MSrepl_errors holds 20598; stored: runstatus $(sv "$ID" "$DA_TRAN" runstatus), error $(sv "$ID" "$DA_TRAN" "coalesce(error_code, '-') || ': ' || left(coalesce(error_text, '-'), 200)")"
[ "$(sv "$ID" "$DA_TRAN" error_code)" = 20598 ] || fail "G: the stored error code is $(sv "$ID" "$DA_TRAN" error_code), not 20598"
sv "$ID" "$DA_TRAN" error_text | grep -q 'The row was not found at the Subscriber' || fail "G: the stored error text: $(sv "$ID" "$DA_TRAN" error_text)"
[ "$(fnd "$ID")" = "warning:a replication agent failed:distribution / $DA_TRAN" ] || fail "G: the findings while it fails: $(fnd "$ID")"
detail "$ID" 'a replication agent failed' | grep -q 'Error 20598' || fail "G: the failed text carries no error: $(detail "$ID" 'a replication agent failed')"
echo "  $(detail "$ID" 'a replication agent failed')"
wait_until 65 "$(date -d "${FS_SA}Z" +%s)"
rd "$NDIST"
[ "$(fnd "$ID")" = "warning:a replication agent keeps failing or retrying:distribution / $DA_TRAN" ] || fail "G: a minute after the first failure: $(fnd "$ID")"
echo "  $(detail "$ID" 'a replication agent keeps failing or retrying')"
Q "$SUB" "INSERT pgvr_sub.dbo.t_tran (id, v) VALUES (5, N'put back')" >/dev/null
g_clear() { [ "$(sv "$ID" "$DA_TRAN" "failing_since is null")" = t ] && [ -z "$(fnd "$ID")" ]; }
poll 15 10 g_clear || fail "G: not clear 150 s after the row came back: $(fnd "$ID")"
inh "$ID" repl_agent_retrying
echo "G: OK"

echo "--- H. the snapshot folder unwritable: the snapshot agent fails"
docker exec -u 0 "$DIST" chmod 000 /var/opt/mssql/ReplData
Q "$PUB" "EXEC pgvr_pub.dbo.sp_startpublication_snapshot @publication = N'pgvr_snap'" >/dev/null
h_failed() { [ "$(sv "$ID" "$SN_SNAP" runstatus)" = 6 ]; }
if ! poll 18 5 h_failed; then docker exec -u 0 "$DIST" chmod 755 /var/opt/mssql/ReplData; fail "H: the snapshot agent did not fail in 90 s (runstatus $(sv "$ID" "$SN_SNAP" runstatus))"; fi
docker exec -u 0 "$DIST" chmod 755 /var/opt/mssql/ReplData
[ "$(fnd "$ID")" = "warning:a replication agent failed:snapshot / $SN_SNAP" ] || fail "H: the findings: $(fnd "$ID")"
[ -n "$(sv "$ID" "$SN_SNAP" error_text)" ] || fail "H: no error text stored"
echo "  $(detail "$ID" 'a replication agent failed')"
Q "$PUB" "EXEC pgvr_pub.dbo.sp_startpublication_snapshot @publication = N'pgvr_snap'" >/dev/null 2>&1 || true
h_clear() { [ "$(sv "$ID" "$SN_SNAP" runstatus)" = 2 ] && [ -z "$(fnd "$ID")" ]; }
poll 18 10 h_clear || fail "H: not clear after the folder came back: runstatus $(sv "$ID" "$SN_SNAP" runstatus), $(fnd "$ID")"
echo "H: OK"

echo "--- I. the trend"
got=$(q "select max(latency_s) >= 120, max(undistributed) >= 100, max(failing) >= 1, max(stopped) >= 1, min(source) from pgvigil.mssql_repl_series($ID, '$W0', now(), 60)")
[ "$got" = "t|t|t|t|reads" ] || fail "I: the series from the reads: $got"
got=$(q "select max(latency_s) >= 120, max(undistributed) >= 100, min(source) from pgvigil.mssql_repl_series($ID, now() - interval '3 days', now(), 3600)")
[ "$got" = "t|t|hours" ] || fail "I: the series from the hours: $got"
got=$(q "select count(*) filter (where h.reads <> (select count(*) from pgvigil.mssql_repl_sample s where s.instance_id = h.instance_id and s.series = h.series and date_trunc('hour', s.snapshot_at) = h.hour)) || ':' || count(*) from pgvigil.mssql_repl_hourly h where h.instance_id in ($ID, $IP)")
[ "${got%%:*}" = 0 ] || fail "I: hour rows whose reads differ from their samples: $got"
echo "I: OK ($(q "select count(*) from pgvigil.mssql_repl_series($ID, '$W0', now(), 60)") buckets of a minute; ${got#*:} hour rows)"

echo "--- N. the page's wiring (the lead's files: applied in a scratch copy)"
SCR=$WORK/scratch; mkdir -p "$SCR"
tar --exclude=./web/node_modules --exclude=./bin --exclude=./.git -cf - . | tar -C "$SCR" -xf -
if grep -q "mssql_repl_series" "$SCR/internal/web/q_mssql_hadr.go"; then
  echo "  the tree carries the wiring already: the scratch copy is built as it is"
else
  wiring_patch > "$WORK/wiring.patch"
  (cd "$SCR" && git apply --check "$WORK/wiring.patch" && git apply "$WORK/wiring.patch") || fail "N: the wiring patch does not apply to this tree"
  echo "  the wiring patch applied (the lead's files: web/src/mssql_hadr.ts, internal/web/q_mssql_hadr.go, docs/sqlserver-hadr.md)"
fi
(cd "$SCR/web" && npm ci --no-audit --no-fund > "$WORK/npm.log" 2>&1 && npm run build > "$WORK/web.log" 2>&1) || { tail -20 "$WORK/web.log" 2>/dev/null; tail -5 "$WORK/npm.log"; fail "N: the web build (tsc and esbuild) of the wired copy"; }
(cd "$SCR" && CGO_ENABLED=0 go build -o "$WORK/pgvigil-wired" ./cmd/pgvigil) || fail "N: the build of the wired copy"
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
"$WORK/pgvigil-wired" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
kill -0 "$SRVPID" 2>/dev/null || fail "N: serve exited: $(mask < "$WORK/serve.log" | tail -5)"
FROM=$(q "select to_char(('$W0'::timestamptz - interval '1 minute') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"); TO=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
api() { local code; code=$(curl -s -o "$WORK/body" -w '%{http_code}' "$U/api/mssql/availability?instance=$ID&from=$FROM&to=$TO&part=$1"); [ "$code" = 200 ] || fail "N: part $1 answered $code: $(head -c 300 "$WORK/body")"; cat "$WORK/body"; }
got=$(api replseries | python3 -c 'import json, sys
d = json.load(sys.stdin)["replseries"]
rows = [dict(zip(d["columns"], r)) for r in d["rows"]]
print(len(rows), max(float(r.get("latency_s") or 0) for r in rows) >= 120, max(float(r.get("undistributed") or 0) for r in rows) >= 100)')
[[ "$got" =~ ^[0-9]+\ True\ True$ ]] && [ "${got%% *}" -ge 2 ] || fail "N: replseries: $got"
got=$(api replication | python3 -c 'import json, sys
d = json.load(sys.stdin)["replication"]
rows = [dict(zip(d["columns"], r)) for r in d["rows"]]
sub = [r for r in rows if r.get("kind") == "subscription" and r.get("publication") == "pgvr_tran"][0]
print(sub.get("job_state"), sub.get("continuous"), int(float(sub.get("latency_s") or 0)), sub.get("subscription_status"))')
[ "$got" = "running True 0 active" ] || fail "N: the replication part's new columns: $got"
got=$(api repllimits | python3 -c 'import json, sys
d = json.load(sys.stdin)["repllimits"]
rows = [dict(zip(d["columns"], r)) for r in d["rows"]]
print(",".join("%s:%s:%s" % (r["key"], int(float(r["warn"])), r["level"]) for r in rows))')
[ "$got" = "repl_agent_retrying:10:default,repl_agent_silent:15:default,repl_latency:5:default" ] || fail "N: repllimits: $got"
grep -q "Replication latency: the oldest command waiting" "$SCR/internal/web/dist/app.js" || fail "N: the bundle lacks the latency chart"
kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null || true; SRVPID=
echo "N: OK (tsc and the bundle built; replseries, replication and repllimits answer with the new rows)"

echo "--- K. the statements as the monitoring login, the unit tests"
PGVIGIL_MSSQL_TEST_DSN="$MSSQL_DIST_DSN" PGVIGIL_MSSQL_TEST_DISTRIBUTION=distribution go test ./internal/mssql/ -run 'TestHADRStatementsLive' -count=1 > "$OUT" 2>&1 || { mask < "$OUT" | tail -20; fail "K: TestHADRStatementsLive"; }
go test ./internal/mssql/ -count=1 > "$OUT" 2>&1 || { mask < "$OUT" | tail -20; fail "K: go test ./internal/mssql/"; }
echo "K: OK"

echo "--- L. stubbed rows through the import"
ST=$(q "select pgvigil.ensure_instance('proof-repl-stub-$SUF', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
PG=$(q "select pgvigil.ensure_instance('proof-repl-pg-$SUF', 'postgres', '17.0', 170000, false, '{}', 'postgres')")
imp() { q "select pgvigil.import_mssql_replication($ST, '$1'::timestamptz, '$2'::jsonb)" >/dev/null; }
SUBROW='{"kind": "subscription", "distribution_db": "distribution", "agent_type": "distribution", "agent_name": "pull-agent", "publisher": "P", "publisher_db": "pdb", "publication": "pubx", "subscriber": "S", "subscriber_db": "sdb", "subscription_type": "pull", "subscription_status": "active", "runstatus": 4, "undistributed": 0}'
MSDB='{"kind": "subscription", "distribution_db": "distribution", "agent_type": "distribution", "agent_name": "push-agent", "publisher": "P", "publisher_db": "pdb", "publication": "pubx", "subscriber": "S", "subscriber_db": "sdb2", "subscription_type": "push", "subscription_status": "active", "runstatus": 4, "undistributed": 0}'
JOB='{"kind": "agent_job", "distribution_db": "distribution", "agent_type": "distribution", "agent_name": "pull-agent", "job_state": "not here", "continuous": null}'
PUBROW='{"kind": "published_db", "database_name": "pdb", "distributor": "D", "distributor_local": 0, "pending_xacts": 0, "repl_trans_total": 10}'
T1=$(q "select now() - interval '3 minutes'"); T2=$(q "select now() - interval '1 minute'")
imp "$T1" "[$SUBROW, $MSDB, $JOB, $PUBROW, {\"kind\": \"collector_error\", \"source\": \"distribution.msdb\", \"message\": \"x\"}]"
imp "$T2" "[$SUBROW, $MSDB, $JOB, {\"kind\": \"collector_error\", \"source\": \"distribution.msdb\", \"message\": \"x\"}, {\"kind\": \"collector_error\", \"source\": \"published databases\", \"message\": \"y\"}]"
[ "$(q "select string_agg(agent_name || ':' || coalesce(job_state, 'NULL'), ',' order by agent_name) from pgvigil.mssql_replication_state where instance_id = $ST and kind = 'subscription'")" = "pull-agent:not here,push-agent:NULL" ] || fail "L: the jobs merged"
[ -z "$(fnd "$ST")" ] || fail "L: a finding for a pull agent or an unread job: $(fnd "$ST")"
[ "$(q "select count(*) || ':' || bool_and(snapshot_at = '$T1'::timestamptz)::text from pgvigil.mssql_replication_state where instance_id = $ST and kind = 'published_db'")" = "1:true" ] || fail "L: the publisher's rows were not kept through a failed read"
H1=$(q "select sum(reads) from pgvigil.mssql_repl_hourly where instance_id = $ST")
imp "$T2" "[$SUBROW, $MSDB, $JOB]"
[ "$(q "select sum(reads) from pgvigil.mssql_repl_hourly where instance_id = $ST")" = "$H1" ] || fail "L: a re-run of one read added to the hours"
imp "$T1" "[]"
[ "$(q "select count(*) from pgvigil.mssql_replication_state where instance_id = $ST and kind = 'subscription'")" = 2 ] || fail "L: an older read imported late changed the state"
r=$(q "select x->>'outcome' || '|' || (x->>'detail') from pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'set', 'key', 'repl_latency', 'level', 'instance', 'instance_id', $PG, 'warn', 1, 'ui_user', 'proof')) x")
[ "$r" = "refused|no SQL Server instance $PG" ] || fail "L: repl_latency at a PostgreSQL instance: $r"
r=$(q "select pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'set', 'key', 'uptime', 'level', 'instance', 'instance_id', $ST, 'warn', 48, 'crit', 12, 'ui_user', 'proof'))->>'outcome'")
[ "$r" = done ] || fail "L: uptime at a SQL Server instance: $r"
r=$(q "select x->>'outcome' || '|' || (x->>'detail') from pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'set', 'key', 'amcheck_age', 'level', 'instance', 'instance_id', $ST, 'warn', 7, 'ui_user', 'proof')) x")
[ "$r" = "refused|no PostgreSQL instance $ST" ] || fail "L: amcheck_age at a SQL Server instance: $r"
echo "L: OK"
echo "NOT PROVEN: merge replication (SQL Server on Linux has none; Windows waits on Q10), peer-to-peer, a live pull subscription, Managed Instance, SQL Server 2016-2019 and 2025, a distributor in an availability group"
echo "proof-mssql-replication: every part passed"
