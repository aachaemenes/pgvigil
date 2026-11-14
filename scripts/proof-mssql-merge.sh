#!/usr/bin/env bash
# Proof of pgvigil's monitoring of SQL Server MERGE replication (task 385's merge rows; internal/mssql/replication.go,
# migration 0142). A merge agent is its subscription: the distributor's subscriptions statement reads it (kind
# 'subscription', agent_type 'merge') with its newest session, its failing time and error; the findings judge it as
# they judge a distribution agent, except latency (merge keeps no commands in the distribution database).
#
#   scripts/proof-mssql-merge.sh stubs   part T: on any docker host. SQL Server on Linux has no merge replication, so a
#                                        stub database with tables in the shape of a distribution database's carries
#                                        crafted merge history; and merge subscription rows go through the import into
#                                        a throwaway repository.
#   scripts/proof-mssql-merge.sh lab     part W: the real merge publication of scripts/lab/win-merge.ps1 on the Windows
#                                        lab of scripts/lab/win-mirroring.ps1, read from another machine.
#
# Needs (part T): docker, psql, a go toolchain at the repository root, and PGVIGIL_REPO_DSN, a superuser connection to
# a PostgreSQL sandbox in KEYWORD form; PGVIGIL_MSSQL_IMAGE optional (default
# mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04).
# What part T makes, and removes on every exit path: one container and its network (labelled pgvmrg=<tag>, read
# back: 0 containers, 0 networks), its repository database. No password is printed or put on a command line.
#
# Expected, part T (written before its first run, 2026-11-14; the first run is on the tree BEFORE the read and 0142
# change: every T row below red there, as named in brackets):
#  T1. TestReplicationMergeShape: the subscriptions statement reads MSmerge_agents, MSmerge_sessions, MSmerge_history,
#      MSmerge_subscriptions; the agents statement no longer reads MSmerge_agents. [red: both]
#  T2. TestReplicationMergeLive over the stub's five merge agents, each one subscription row and no agent row:
#      merge-idle runstatus 4, not failing; merge-retrying (healthy 40 min ago, retries since 8 min) runstatus 5,
#      failing since its first retry session's start, error 18456 (the code-bearing row of the newest failed session's
#      error, never the deadlock row of a healthy session); merge-failed-again (failed 6 h ago, healthy 5 h ago, failed
#      5 min ago, a session in progress now) runstatus 3, failing since 5 min, error 2627; merge-recovered (failed,
#      then idle) runstatus 4, not failing; merge-never-ok (one failed session, a pull subscription) runstatus 6,
#      failing since its start, error 20598, type pull. Status, undistributed and latency NULL on every merge row.
#      [red: five 'not read as a merge subscription', five 'still read as an agent row']
#  T3. go test ./internal/mssql/ (the unit tests, no server). [green before and after]
#  T4. stored merge subscription rows, two reads 2 minutes apart, through import_mssql_replication on a stub instance:
#      findings exactly
#        warning:a replication agent failed:merge / merge-failed
#        warning:a replication agent is stopped:distribution / dist-active
#        warning:a replication agent is stopped:merge / merge-stopped
#        warning:a replication agent keeps failing or retrying:merge / merge-failing
#      - a continuous merge agent whose job is stopped at both reads is 'stopped' though the distributor keeps no
#        status for a merge subscription (0142 :457) [red: absent]; a distribution subscription that is 'subscribed'
#        (not active) with its job stopped stays silent (the rule is not widened past merge) [green before];
#      - a merge row carrying commands and an hour-old pending age (never read for merge: the guard) raises no latency
#        finding (0142 :411) [red: critical 'replication latency over the threshold' on mpub -> S.s2];
#      - the merge series' samples store latency NULL, the distribution series' a number (0142 :294) [red: merge 0 / 3600].
#  T5. the container, its network and the repository removed. 'PROOF OK (part T)'.
#
# Expected, part W: in the header of part W below.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*" >&2; exit 1; }
IMG="${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04}"
MODE=${1:-}
[[ "$MODE" == stubs || "$MODE" == lab ]] || fail "usage: scripts/proof-mssql-merge.sh stubs | lab"
WORK=$(mktemp -d); OUT=$WORK/out
RED=()   # rows that are not as expected; the run goes on so one run shows every row
red() { echo "RED $*"; RED+=("$1"); }
ok() { echo "ok $*"; }

if [[ "$MODE" == stubs ]]; then
  for t in docker psql go openssl; do command -v $t >/dev/null || fail "$t is not on this machine"; done
  : "${PGVIGIL_REPO_DSN:?a superuser connection to a PostgreSQL sandbox, in keyword form}"
  ADMIN_DSN=$PGVIGIL_REPO_DSN
  HX=$(openssl rand -hex 3); TAG="pgvmrg$HX"; NET="$TAG-net"; NODE="mstub$HX"
  SA="S$(openssl rand -hex 14)!a"; export SA
  REPO_DB=pgvigil_mergeproof_$HX; MADE_REPO=; MADE_LAB=
  mask() { sed "s/$SA/<sa>/g"; }
  cleanup() {
    local rc=$? left_c left_n
    trap - ERR; set +e
    if [ -n "$MADE_LAB" ]; then
      docker rm -f -v "$NODE" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
      left_c=$(docker ps -a -q --filter "label=pgvmrg=$TAG" | wc -l); left_n=$(docker network ls -q --filter "label=pgvmrg=$TAG" | wc -l)
      echo "cleanup of $TAG: containers left $left_c, networks left $left_n"
      [[ $left_c == 0 && $left_n == 0 ]] || { echo "CLEANUP: $TAG not removed in full" >&2; [ $rc = 0 ] && rc=1; }
    fi
    [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
    rm -rf "$WORK"
    exit $rc
  }
  trap cleanup EXIT
  trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR

  echo "--- the stub server $NODE ($IMG)"
  docker network create --label "pgvmrg=$TAG" "$NET" >/dev/null; MADE_LAB=1
  docker run -d --name "$NODE" --hostname "$NODE" --network "$NET" --label "pgvmrg=$TAG" -e ACCEPT_EULA=Y -e MSSQL_PID=Developer \
    -e MSSQL_SA_PASSWORD="$SA" -e MSSQL_MEMORY_LIMIT_MB=2048 "$IMG" >/dev/null 2>&1 || fail "docker run of $NODE refused"
  SQLCMD=()
  for _ in $(seq 1 120); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$NODE" 2>/dev/null || true)" == true ]] || { docker logs --tail 20 "$NODE" 2>&1 | mask; fail "$NODE stopped at its start"; }
    if [[ ${#SQLCMD[@]} == 0 ]]; then
      if docker exec "$NODE" test -x /opt/mssql-tools18/bin/sqlcmd; then SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -C)
      elif docker exec "$NODE" test -x /opt/mssql-tools/bin/sqlcmd; then SQLCMD=(/opt/mssql-tools/bin/sqlcmd)
      else fail "the image $IMG has no sqlcmd"; fi
    fi
    if SQLCMDPASSWORD="$SA" docker exec -e SQLCMDPASSWORD "$NODE" "${SQLCMD[@]}" -S localhost -U sa -b -Q "SELECT 1" >/dev/null 2>&1; then break; fi
    sleep 3
  done
  QIN() { SQLCMDPASSWORD="$SA" docker exec -i -e SQLCMDPASSWORD "$NODE" "${SQLCMD[@]}" -S localhost -U sa -b -I -h -1 -W -i /dev/stdin; }
  # the stub: the tables the subscriptions and agents statements read, in a distribution database's shape (the merge
  # tables' columns as Microsoft's pages for MSmerge_agents, MSmerge_sessions, MSmerge_history, MSmerge_subscriptions
  # list them, the ones read here), and crafted history; 'expected since' marks the session whose start the failing
  # time must equal, 'expected code <n>' the cause code
  QIN > "$OUT" 2>&1 <<'SQL' || { mask < "$OUT"; fail "the stub database"; }
SET NOCOUNT ON;
CREATE DATABASE pgvm_stub;
GO
USE pgvm_stub;
CREATE TABLE dbo.MSdistribution_agents (id int, name nvarchar(100), publisher_database_id int, publisher_id smallint, publisher_db sysname,
  publication sysname, subscriber_id smallint, subscriber_db sysname, subscription_type int);
CREATE TABLE dbo.MSdistribution_history (agent_id int, runstatus int, start_time datetime, time datetime, comments nvarchar(4000),
  xact_seqno varbinary(16), delivery_latency int, delivery_rate float, error_id int, timestamp timestamp);
CREATE TABLE dbo.stub_status (agent_id int, UndelivCmdsInDistDB int);
EXEC('CREATE VIEW dbo.MSdistribution_status AS SELECT agent_id, UndelivCmdsInDistDB FROM dbo.stub_status');
CREATE TABLE dbo.MSsubscriptions (publisher_database_id int, article_id int, agent_id int, status tinyint);
CREATE TABLE dbo.MSrepl_transactions (publisher_database_id int, xact_seqno varbinary(16), entry_time datetime);
CREATE TABLE dbo.MSrepl_commands (publisher_database_id int, xact_seqno varbinary(16), article_id int);
CREATE TABLE dbo.MSrepl_errors (id int, time datetime, error_code sysname NULL, error_text ntext NULL);
CREATE TABLE dbo.MSlogreader_agents (id int, name nvarchar(100), publisher_id smallint, publisher_db sysname, job_id binary(16));
CREATE TABLE dbo.MSlogreader_history (agent_id int, runstatus int, start_time datetime, time datetime, comments nvarchar(4000),
  xact_seqno varbinary(16), delivery_latency int, error_id int, timestamp timestamp);
CREATE TABLE dbo.MSsnapshot_agents (id int, name nvarchar(100), publisher_id smallint, publisher_db sysname, publication sysname, job_id binary(16));
CREATE TABLE dbo.MSsnapshot_history (agent_id int, runstatus int, start_time datetime, time datetime, comments nvarchar(1000), error_id int, timestamp timestamp);
CREATE TABLE dbo.MSpublications (publisher_id smallint, publisher_db sysname, publication sysname, publication_id int, publication_type int);
CREATE TABLE dbo.MSmerge_agents (id int, name nvarchar(100), publisher_id smallint, publisher_db sysname, publication sysname,
  subscriber_id smallint, subscriber_db sysname, job_id binary(16), subscriber_name sysname NULL);
CREATE TABLE dbo.MSmerge_sessions (session_id int, agent_id int, start_time datetime, end_time datetime NULL, delivery_rate float NULL,
  runstatus int, timestamp timestamp);
CREATE TABLE dbo.MSmerge_history (session_id int, agent_id int, comments nvarchar(255), error_id int, timestamp timestamp);
CREATE TABLE dbo.MSmerge_subscriptions (publisher_id smallint, publisher_db sysname, publication_id int, subscriber_id smallint,
  subscriber_db sysname, subscription_type int, sync_type tinyint, status tinyint, subscription_time datetime);
DECLARE @b datetime = GETDATE();
INSERT dbo.MSpublications VALUES (0, N'p', N'mpub', 1, 2);
INSERT dbo.MSmerge_agents VALUES (1, N'merge-idle', 0, N'p', N'mpub', 1, N's1', NULL, N'SUBX'), (2, N'merge-retrying', 0, N'p', N'mpub', 1, N's2', NULL, N'SUBX'),
  (3, N'merge-failed-again', 0, N'p', N'mpub', 1, N's3', NULL, N'SUBX'), (4, N'merge-recovered', 0, N'p', N'mpub', 1, N's4', NULL, N'SUBX'),
  (5, N'merge-never-ok', 0, N'p', N'mpub', 1, N's5', NULL, N'SUBX');
INSERT dbo.MSmerge_subscriptions VALUES (0, N'p', 1, 1, N's1', 0, 1, 0, @b), (0, N'p', 1, 1, N's2', 0, 1, 0, @b), (0, N'p', 1, 1, N's3', 0, 1, 0, @b),
  (0, N'p', 1, 1, N's4', 0, 1, 0, @b), (0, N'p', 1, 1, N's5', 1, 1, 0, @b);
INSERT dbo.MSmerge_sessions (session_id, agent_id, start_time, end_time, delivery_rate, runstatus) VALUES
  (101, 1, DATEADD(minute, -3, @b), DATEADD(minute, -2, @b), 0, 4), (102, 1, DATEADD(minute, -2, @b), DATEADD(minute, -1, @b), 0, 4),
  (201, 2, DATEADD(minute, -40, @b), DATEADD(minute, -39, @b), 12.5, 2), (202, 2, DATEADD(minute, -8, @b), DATEADD(minute, -7, @b), NULL, 5),
  (203, 2, DATEADD(minute, -2, @b), NULL, NULL, 5),
  (301, 3, DATEADD(hour, -6, @b), DATEADD(minute, -359, @b), NULL, 6), (302, 3, DATEADD(hour, -5, @b), DATEADD(minute, -299, @b), 3, 2),
  (303, 3, DATEADD(minute, -5, @b), DATEADD(minute, -4, @b), NULL, 6), (304, 3, DATEADD(minute, -3, @b), NULL, NULL, 3),
  (401, 4, DATEADD(minute, -20, @b), DATEADD(minute, -19, @b), NULL, 6), (402, 4, DATEADD(minute, -10, @b), DATEADD(minute, -9, @b), 0, 4),
  (501, 5, DATEADD(minute, -3, @b), DATEADD(minute, -2, @b), NULL, 6);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (101, 1, N'No data needed to be merged.', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (102, 1, N'No data needed to be merged.', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (201, 2, N'Merged 5 data changes (5 inserts, 0 updates, 0 deletes, 0 conflicts).', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (201, 2, N'A deadlock was retried (a healthy session''s error).', 23);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (202, 2, N'expected since', 21);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (203, 2, N'expected code 18456', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (203, 2, N'The merge process could not connect to the Subscriber ''SUBX''.', 22);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (301, 3, N'an old failure', 31);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (302, 3, N'Merged 3 data changes.', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (303, 3, N'expected since', 32);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (303, 3, N'expected code 2627', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (304, 3, N'Uploading data changes to the Publisher.', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (401, 4, N'failed', 41);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (402, 4, N'No data needed to be merged.', 0);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (501, 5, N'expected since', 51);
INSERT dbo.MSmerge_history (session_id, agent_id, comments, error_id) VALUES (501, 5, N'expected code 20598', 0);
INSERT dbo.MSrepl_errors (id, time, error_code, error_text) VALUES
  (21, DATEADD(minute, -8, @b), N'', N'The merge process was unable to connect to the Subscriber.'),
  (22, DATEADD(minute, -2, @b), N'', N'The merge process could not connect to the Subscriber ''SUBX''.'),
  (22, DATEADD(minute, -2, @b), N'18456', N'Login failed for user ''sa''.'),
  (23, DATEADD(minute, -40, @b), N'1205', N'Transaction was deadlocked and has been chosen as the deadlock victim.'),
  (31, DATEADD(hour, -6, @b), N'20598', N'an old failure'),
  (32, DATEADD(minute, -5, @b), N'2627', N'Violation of PRIMARY KEY constraint ''PK_t''. Cannot insert duplicate key in object ''dbo.t''.'),
  (41, DATEADD(minute, -20, @b), N'1205', N'Transaction was deadlocked.'),
  (51, DATEADD(minute, -3, @b), N'20598', N'The row was not found at the Subscriber when applying the replicated command.');
SQL
  IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$NODE")
  export PGVIGIL_MSSQL_TEST_DSN="sqlserver://sa:$SA@$IP:1433?database=master&encrypt=true&TrustServerCertificate=true"

  echo "--- T1-T3. the statements"
  for t in TestReplicationMergeShape TestReplicationMergeLive; do
    if PGVIGIL_MSSQL_TEST_MERGESTUB=pgvm_stub go test ./internal/mssql/ -run "^$t\$" -count=1 -v > "$OUT" 2>&1; then
      { grep -E '^\s+replication_merge_test.go:[0-9]+: merge-' "$OUT" || true; } | sed 's/^ */    /'   # none for the shape test: grep exits 1
      grep -q "^--- PASS: $t" "$OUT" && ok "$t" || red "$t" "(not run: skipped?)"
    else
      { grep -E '^\s+replication_merge_test.go:[0-9]+:' "$OUT" || true; } | mask | sed 's/^ */    /' | head -30
      red "$t"
    fi
  done
  if go test ./internal/mssql/ -count=1 > "$OUT" 2>&1; then ok "T3: go test ./internal/mssql/"; else mask < "$OUT" | tail -20; red "T3"; fi

  echo "--- T4. stored merge rows through the import"
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"
  psql "$ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" >/dev/null; MADE_REPO=1
  export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
  printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/cfg.yaml"
  "$WORK/pgvigil" migrate -config "$WORK/cfg.yaml" > "$OUT" 2>&1 || { cat "$OUT"; fail "the migrate"; }
  q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
  ST=$(q "select pgvigil.ensure_instance('proof-merge-stub-$HX', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')")
  T1=$(q "select now() - interval '3 minutes'"); T2=$(q "select now() - interval '1 minute'")
  L1=$(q "select now() - interval '4 minutes'"); L2=$(q "select now() - interval '2 minutes'")
  F12=$(q "select now() - interval '12 minutes'"); F1=$(q "select now() - interval '90 seconds'")
  # row <agent type> <name> <subscriber db> <status> <runstatus> <last run> [extra json]: one subscription row
  row() { printf '{"kind": "subscription", "distribution_db": "distribution", "agent_type": "%s", "agent_name": "%s", "publisher": "P", "publisher_db": "pdb", "publication": "mpub", "subscriber": "S", "subscriber_db": "%s", "subscription_type": "push", "subscription_status": %s, "runstatus": %s, "last_run_utc": "%s"%s}' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}"; }
  job() { printf '{"kind": "agent_job", "distribution_db": "distribution", "agent_type": "%s", "agent_name": "%s", "job_state": "%s", "continuous": 1}' "$1" "$2" "$3"; }
  payload() { local at=$1
    echo "[$(row merge merge-stopped s1 null 2 "$at"), $(job merge merge-stopped stopped),
      $(row merge merge-latency-guard s2 null 4 "$at" ', "undistributed": 100, "oldest_pending_age_s": 3600'), $(job merge merge-latency-guard running),
      $(row merge merge-failing s3 null 5 "$at" ", \"failing_since_utc\": \"$F12\""), $(job merge merge-failing running),
      $(row merge merge-failed s4 null 6 "$at" ", \"failing_since_utc\": \"$F1\""), $(job merge merge-failed running),
      $(row distribution dist-active d1 '"active"' 2 "$at" ', "undistributed": 0'), $(job distribution dist-active stopped),
      $(row distribution dist-subscribed d2 '"subscribed"' 2 "$at" ', "undistributed": 0'), $(job distribution dist-subscribed stopped)]"; }
  q "select pgvigil.import_mssql_replication($ST, '$T1'::timestamptz, '$(payload "$L1")'::jsonb)" >/dev/null
  q "select pgvigil.import_mssql_replication($ST, '$T2'::timestamptz, '$(payload "$L2")'::jsonb)" >/dev/null
  WANT='warning:a replication agent failed:merge / merge-failed
warning:a replication agent is stopped:distribution / dist-active
warning:a replication agent is stopped:merge / merge-stopped
warning:a replication agent keeps failing or retrying:merge / merge-failing'
  GOT=$(q "select severity || ':' || check_name || ':' || object from pgvigil.mssql_repl_findings where instance_id = $ST order by check_name, object")
  if [ "$GOT" = "$WANT" ]; then ok "T4: the findings as expected"; else red "T4-findings"; diff <(echo "$WANT") <(echo "$GOT") | sed 's/^/    /' || true; fi
  LAT=$(q "select string_agg(agent_type || '/' || coalesce(subscriber_db, '?') || '=' || coalesce(latency_s::text, 'null'), ',' order by agent_type, subscriber_db) from pgvigil.mssql_repl_sample where instance_id = $ST and snapshot_at = '$T2'::timestamptz")
  if [ "$LAT" = "distribution/d1=0,distribution/d2=0,merge/s1=null,merge/s2=null,merge/s3=null,merge/s4=null" ]; then ok "T4: the samples' latency (merge NULL): $LAT"; else red "T4-samples" "$LAT"; fi
  echo "--- T5. removed (cleanup follows)"
  if [ ${#RED[@]} -gt 0 ]; then echo "PART T RED: ${RED[*]}"; exit 1; fi
  echo "PROOF OK (part T)"
  exit 0
fi

# ---- part W: the Windows lab
fail "part W is not written yet"
