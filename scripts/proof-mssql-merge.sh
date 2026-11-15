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
#      failing since its start, error 20598, type pull; merge-pull2 (a second publication, mpub2, pulled to the same s1
#      as merge-idle) type pull while merge-idle stays push (the type matched to the agent's own publication). Status, undistributed and latency NULL on every
#      merge row; the last run its newest session's end, or its start while it runs; the subscriber SUBX (MSmerge_agents'
#      name: the server map has none). merge-retrying's error stack holds two coded rows in one second (20084, the
#      replication message, and 18456, the engine's): 18456 every time (review q10a S2).
#      [red at first: five 'not read as a merge subscription', five 'still read as an agent row'; at the q10a fold's
#      fixture run, on the code before it: merge-retrying's code 20084 if the tie falls on the row inserted first (it
#      may fall either way: a green there proves nothing), merge-pull2's type green (the tie-break was right, the test
#      could not see it)]. The collector's probe replMergeTablesSQL first: has_merge 1 on this stub (all four tables)
#      [red at the q10repl3 fixture run: the probe's alias was the keyword MERGE, Msg 156 'Incorrect syntax near the
#      keyword 'merge'' - no server had run the probe before].
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
#      - the merge series' samples store latency NULL, the distribution series' a number (0142 :294) [red: merge 0 / 3600];
#      - a log reader (continuous, its job stopped at both reads) of a database pdbm whose only subscriptions are merge
#        ones raises nothing: 'stopped' covers a merge agent itself, never widens the log reader's rule (review q10a S1)
#        [red at the q10a fold's fixture run: 'a replication agent is stopped' on logreader / lr-pdbm].
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
trap 'rm -rf "$WORK"' EXIT   # until a part sets its own cleanup (which removes it too)
OKLINE=   # the final line: printed by cleanup, after everything is removed and read back (review q10c N12)
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
  # mask: in bash itself, so no password reaches a command line (review q10c S3)
  mask() { local l; while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "${l//"$SA"/<sa>}"; done; }
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
    [ $rc = 0 ] && [ -n "$OKLINE" ] && echo "$OKLINE"
    exit $rc
  }
  trap cleanup EXIT
  trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR

  echo "--- the stub server $NODE ($IMG)"
  docker network create --label "pgvmrg=$TAG" "$NET" >/dev/null; MADE_LAB=1
  MSSQL_SA_PASSWORD=$SA docker run -d --name "$NODE" --hostname "$NODE" --network "$NET" --label "pgvmrg=$TAG" -e ACCEPT_EULA=Y \
    -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD -e MSSQL_MEMORY_LIMIT_MB=2048 "$IMG" >/dev/null 2>&1 || fail "docker run of $NODE refused"
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
INSERT dbo.MSpublications VALUES (0, N'p', N'mpub', 1, 2), (0, N'p', N'mpub2', 2, 2);
INSERT dbo.MSmerge_agents VALUES (1, N'merge-idle', 0, N'p', N'mpub', 1, N's1', NULL, N'SUBX'), (2, N'merge-retrying', 0, N'p', N'mpub', 1, N's2', NULL, N'SUBX'),
  (3, N'merge-failed-again', 0, N'p', N'mpub', 1, N's3', NULL, N'SUBX'), (4, N'merge-recovered', 0, N'p', N'mpub', 1, N's4', NULL, N'SUBX'),
  (5, N'merge-never-ok', 0, N'p', N'mpub', 1, N's5', NULL, N'SUBX'), (6, N'merge-pull2', 0, N'p', N'mpub2', 1, N's1', NULL, N'SUBX');
INSERT dbo.MSmerge_subscriptions VALUES (0, N'p', 1, 1, N's1', 0, 1, 0, @b), (0, N'p', 1, 1, N's2', 0, 1, 0, @b), (0, N'p', 1, 1, N's3', 0, 1, 0, @b),
  (0, N'p', 1, 1, N's4', 0, 1, 0, @b), (0, N'p', 1, 1, N's5', 1, 1, 0, @b), (0, N'p', 2, 1, N's1', 1, 1, 0, @b);
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
  (22, DATEADD(minute, -2, @b), N'20084', N'The process could not connect to Subscriber ''SUBX''.'),
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
      $(row distribution dist-subscribed d2 '"subscribed"' 2 "$at" ', "undistributed": 0'), $(job distribution dist-subscribed stopped),
      $(row merge merge-pdbm s9 null 4 "$at" ', "publisher_db": "pdbm"'), $(job merge merge-pdbm running),
      {\"kind\": \"agent\", \"distribution_db\": \"distribution\", \"agent_type\": \"logreader\", \"agent_name\": \"lr-pdbm\", \"publisher\": \"P\", \"publisher_db\": \"pdbm\", \"runstatus\": 2, \"last_run_utc\": \"$at\"},
      $(job logreader lr-pdbm stopped)]"; }
  q "select pgvigil.import_mssql_replication($ST, '$T1'::timestamptz, '$(payload "$L1")'::jsonb)" >/dev/null
  q "select pgvigil.import_mssql_replication($ST, '$T2'::timestamptz, '$(payload "$L2")'::jsonb)" >/dev/null
  WANT='warning:a replication agent failed:merge / merge-failed
warning:a replication agent is stopped:distribution / dist-active
warning:a replication agent is stopped:merge / merge-stopped
warning:a replication agent keeps failing or retrying:merge / merge-failing'
  GOT=$(q "select severity || ':' || check_name || ':' || object from pgvigil.mssql_repl_findings where instance_id = $ST order by check_name, object")
  if [ "$GOT" = "$WANT" ]; then ok "T4: the findings as expected"; else red "T4-findings"; diff <(echo "$WANT") <(echo "$GOT") | sed 's/^/    /' || true; fi
  LAT=$(q "select string_agg(agent_type || '/' || coalesce(subscriber_db, '?') || '=' || coalesce(latency_s::text, 'null'), ',' order by agent_type, subscriber_db) from pgvigil.mssql_repl_sample where instance_id = $ST and snapshot_at = '$T2'::timestamptz and kind = 'subscription'")
  if [ "$LAT" = "distribution/d1=0,distribution/d2=0,merge/s1=null,merge/s2=null,merge/s3=null,merge/s4=null,merge/s9=null" ]; then ok "T4: the samples' latency (merge NULL): $LAT"; else red "T4-samples" "$LAT"; fi
  echo "--- T5. removed (cleanup follows)"
  if [ ${#RED[@]} -gt 0 ]; then echo "PART T RED: ${RED[*]}"; exit 1; fi
  OKLINE="PROOF OK (part T)"
  exit 0
fi

# ---- part W: the Windows lab
# Needs: docker (the SQL Server image above for its sqlcmd only, one helper container on the host's network), psql,
# python3, a go toolchain at the repository root, PGVIGIL_REPO_DSN as part T, and
#   PGVIGIL_MIRROR_HOST    the lab host's address (win-mirroring.ps1's firewall rule admits this machine only)
#   PGVIGIL_MIRROR_SA_FILE the lab's sa password file (win-mirroring.ps1's secret\sa.pw, copied here, mode 600)
# Optional: PGVIGIL_MERGE_PORTS (default 14331,14332: the publisher and its own distributor, the subscriber).
# The lab: win-mirroring.ps1 up, then win-merge.ps1 up (VERDICT UP) on the host. What part W makes, and removes on
# every exit path: the helper container (pgvmrgw<8 hex>), a monitoring login on the publisher (VIEW SERVER STATE, VIEW
# ANY DEFINITION, a user with db_datareader in msdb and in distribution), its repository database. Every fault it
# makes it undoes (the subscriber password back to sa's, the merge agent's job running), read back; the merge
# objects themselves are win-merge.ps1 down's.
#
# Expected, part W (written before its first run, 2026-11-14):
#  MG1. both instances answer as sa (@@SERVERNAME '<host>\PGVPRINCIPAL' / '<host>\PGVMIRROR'); as win-merge.ps1 up
#       left it: one merge agent for pgvm_merge, its job running, 120 rows on each side; no monitoring login or helper
#       of an earlier run.
#  MG2. the monitoring login made; no sysadmin.
#  MG3. a healthy read of the publisher: mssql_replication ok. publication: '<publisher>|pgvmerge|pgvm_merge|merge|1'.
#       the merge subscription: one row, kind subscription, agent_type merge, the agent's name, subscriber '<host>\
#       PGVMIRROR'.pgvmerge_sub, push, status NULL, runstatus / last run / message = sa's newest session at the read
#       (sa read before and after it: either), not failing, job running and continuous; no merge row of kind agent;
#       the snapshot agent's row runstatus 2, its job stopped and not continuous; published_db pgvmerge 'merge',
#       distributor local; the merge series' sample latency NULL. No replication finding. A second read 90 s later:
#       the stored last run moved (an idle continuous merge agent writes a session per poll; if it does not, 'a
#       replication agent writes nothing' would fire on an idle merge agent after 15 minutes: RED MG3-idle; sa's
#       sessions are printed with their duration, the data for that fix: a session that stays open with a growing
#       duration would make the last run start + duration). A stored row that moved between sa's two reads is read
#       once more before a red.
#  MG4. the subscriber password made wrong (sp_changemergesubscription, the job restarted as Microsoft's page asks):
#       BASE = sa's newest session id once the job has stopped; within 180 s a retry or failed session (5 / 6) newer
#       than BASE (never the stop's own session); the next read: runstatus = sa's, failing since = sa's own reading
#       of the rule (the start of the first retry / failed session after the newest succeeded / idle one; sa's
#       sessions printed, and the offset from the job's start: a negative one is the stop's own session); an error
#       code and text (expected 18456, a failed login: printed, not graded); 'a replication agent failed' (warning) on
#       'merge / <agent>'. The retrying threshold at 1 minute (instance level): once the failure is over a minute old,
#       'a replication agent keeps failing or retrying' and no 'failed'. The password back, the job restarted: within
#       180 s a good session (2 / 4) newer than the new BASE; the read: not failing, neither finding; the threshold
#       inherited again.
#  MG5. the merge agent's job stopped (sa's sessions printed: what a stop leaves): two reads: job_state stopped,
#       continuous; 'a replication agent is stopped' (warning) on 'merge / <agent>'. Started: running within 60 s, a
#       good session newer than BASE within 180 s; the read: no finding.
#  MG6. TestHADRStatementsLive and TestReplicationStatementsLive as the monitoring login on the real distribution
#       database: both PASS.
#  MG7. the login dropped (read back) before the final line; the helper and the repository removed by cleanup, then
#       'PROOF OK (part W)' (cleanup prints it only when everything is removed).
#  NOT PROVEN HERE: a pull merge subscription (its agent at the subscriber: 'not here'), a remote distributor for
#  merge, web synchronization, merge conflicts as a measure, SQL Server 2016-2019 and 2025.
for t in docker psql python3 go; do command -v $t >/dev/null || fail "$t is not on this machine"; done
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of the PostgreSQL sandbox}" "${PGVIGIL_MIRROR_HOST:?the lab host}" "${PGVIGIL_MIRROR_SA_FILE:?the lab sa password file}"
IFS=, read -r PPORT MPORT <<<"${PGVIGIL_MERGE_PORTS:-14331,14332}"
H=$PGVIGIL_MIRROR_HOST
[ -r "$PGVIGIL_MIRROR_SA_FILE" ] || fail "cannot read $PGVIGIL_MIRROR_SA_FILE"
SAPW=$(tr -d '\r\n' < "$PGVIGIL_MIRROR_SA_FILE")   # handed to S / Sin only, never exported
ADMIN_DSN=$PGVIGIL_REPO_DSN
HX=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'); TAG=pgvmrgw$HX
REPO_DB=pgvigil_mergelab_$HX; LM=pgvmrg_mon_$HX
PM="Pv9$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
BADPW="Wr0ng$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CFG=$WORK/pgvigil.yaml
HELPER=; MADE_REPO=; MADE_LOGIN=; PW_WRONG=; JOB_STOPPED=; I=
declare -A PORT=([p]=$PPORT [m]=$MPORT) NAME=([p]=PGVPRINCIPAL [m]=PGVMIRROR)
# mask: in bash itself, so no password reaches a command line (review q10c S3)
mask() { local l; while IFS= read -r l || [ -n "$l" ]; do l=${l//"$SAPW"/<sa>}; l=${l//"$PM"/<monitor>}; l=${l//"$BADPW"/<wrong>}; printf '%s\n' "$l"; done; }
S() { SQLCMDPASSWORD=$SAPW docker exec -e SQLCMDPASSWORD "$TAG" /opt/mssql-tools18/bin/sqlcmd -C -S "tcp:$H,${PORT[$1]}" -U sa -b -I -W -h -1 -s '|' -d "${3:-master}" -Q "SET NOCOUNT ON; $2"; }
# Sin <node> [db]: a batch on stdin; it may name the passwords as the sqlcmd variables $(MSA), $(MPM) and $(MBAD)
Sin() { SQLCMDPASSWORD=$SAPW MSA=$SAPW MPM=$PM MBAD=$BADPW docker exec -i -e SQLCMDPASSWORD -e MSA -e MPM -e MBAD "$TAG" /opt/mssql-tools18/bin/sqlcmd -C -S "tcp:$H,${PORT[$1]}" -U sa -b -I -W -h -1 -d "${2:-master}" -i /dev/stdin; }
Sq() { S "$@" >"$WORK/sq" 2>&1 || { mask < "$WORK/sq" >&2; fail "sqlcmd on ${NAME[$1]}: ${2:0:70}"; }; }
D=distribution.dbo
# the subscriber password: sa's again (or the wrong one), then the job restarted (Microsoft: the change takes effect
# when the agent starts again)
set_pw() { Sin p pgvmerge >"$WORK/sin" 2>&1 <<SQL || { mask < "$WORK/sin"; return 1; }
SET NOCOUNT ON;
EXEC sp_changemergesubscription @publication = N'pgvm_merge', @subscriber = N'$MSN', @subscriber_db = N'pgvmerge_sub',
     @property = N'subscriber_password', @value = N'\$($1)';
SQL
}
running() { S p "SELECT COUNT(*) FROM msdb.dbo.sysjobactivity a JOIN msdb.dbo.sysjobs j ON j.job_id = a.job_id WHERE j.name = N'$JOB' AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL"; }
wait_running() { local want=$1; for _ in $(seq 1 30); do [ "$(running)" = "$want" ] && return 0; sleep 2; done; return 1; }
stop_job() { [ "$(running)" = 1 ] && Sq p "EXEC msdb.dbo.sp_stop_job @job_name = N'$JOB'"; wait_running 0; }
start_job() { [ "$(running)" = 0 ] && Sq p "EXEC msdb.dbo.sp_start_job @job_name = N'$JOB'"; wait_running 1; }
# drop_login: the monitoring login and its users, read back (0 = gone)
drop_login() {
  S p "IF USER_ID('$LM') IS NOT NULL DROP USER [$LM];" msdb >/dev/null 2>&1 || true
  S p "IF USER_ID('$LM') IS NOT NULL DROP USER [$LM];" distribution >/dev/null 2>&1 || true
  S p "IF SUSER_ID('$LM') IS NOT NULL DROP LOGIN [$LM];" >/dev/null 2>&1 || true
  [ "$(S p "SELECT COUNT(*) FROM sys.server_principals WHERE name = '$LM'" 2>/dev/null)" = 0 ]
}
cleanup() {
  local rc=$?
  trap - ERR; set +e
  if [ -n "$HELPER" ]; then
    if [ -n "$PW_WRONG" ]; then
      { stop_job; set_pw MSA && start_job; } >/dev/null 2>&1 && echo "cleanup: the subscriber password back to sa's, the job running" \
        || { echo "CLEANUP: the subscriber password or the job is not back (win-merge.ps1 down removes the merge either way)" >&2; [ $rc = 0 ] && rc=1; }
    elif [ -n "$JOB_STOPPED" ]; then
      start_job >/dev/null 2>&1 && echo "cleanup: the merge job running again" || { echo "CLEANUP: the merge job is not running" >&2; [ $rc = 0 ] && rc=1; }
    fi
    if [ -n "$MADE_LOGIN" ]; then
      drop_login && echo "cleanup: login $LM dropped (read back)" || { echo "CLEANUP: login $LM left on PGVPRINCIPAL" >&2; [ $rc = 0 ] && rc=1; }
    fi
    docker rm -f "$TAG" >/dev/null 2>&1
    [ -z "$(docker ps -a -q --filter "label=pgvmrgw=$TAG")" ] || { echo "CLEANUP: the helper $TAG is left" >&2; [ $rc = 0 ] && rc=1; }
  fi
  [ -n "$MADE_REPO" ] && { psql "$ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK"
  [ $rc = 0 ] && [ -n "$OKLINE" ] && echo "$OKLINE"
  exit $rc
}
trap cleanup EXIT
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR
[ -f go.mod ] || fail "run from the repository root"
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "the build"; BIN=$WORK/pgvigil; fi
left=$(docker ps -a --filter label=pgvmrgw --format '{{.Names}}' | tr '\n' ' ')
[ -z "$left" ] || fail "MG1: helper containers of an earlier run: $left (docker rm -f them)"
docker run -d --name "$TAG" --network host --label "pgvmrgw=$TAG" --entrypoint sleep "$IMG" infinity >/dev/null; HELPER=1

echo "--- MG1. the lab as sa"
PSN=$(S p "SELECT @@SERVERNAME") || fail "MG1: PGVPRINCIPAL on $H:$PPORT does not answer"
MSN=$(S m "SELECT @@SERVERNAME") || fail "MG1: PGVMIRROR on $H:$MPORT does not answer"
[[ ${PSN^^} == *'\PGVPRINCIPAL' && ${MSN^^} == *'\PGVMIRROR' ]] || fail "MG1: the servers are '$PSN' on $PPORT and '$MSN' on $MPORT (want <host>\PGVPRINCIPAL, <host>\PGVMIRROR: PGVIGIL_MERGE_PORTS swapped?)"
AGENT=$(S p "SELECT name FROM $D.MSmerge_agents WHERE publication = N'pgvm_merge'")
JOB=$(S p "SELECT j.name FROM msdb.dbo.sysjobs j JOIN $D.MSmerge_agents a ON j.job_id = CAST(a.job_id AS uniqueidentifier) WHERE a.publication = N'pgvm_merge'")
[ -n "$AGENT" ] && [ -n "$JOB" ] || fail "MG1: no merge agent or job for pgvm_merge (win-merge.ps1 up first)"
[ "$(running)" = 1 ] || fail "MG1: the merge job '$JOB' is not running"
ROWS="$(S p "SELECT COUNT(*) FROM dbo.t_merge" pgvmerge)/$(S m "SELECT COUNT(*) FROM dbo.t_merge" pgvmerge_sub)"
[ "$ROWS" = 120/120 ] || fail "MG1: rows $ROWS (want 120/120)"
leftl=$(S p "SELECT ISNULL(STRING_AGG(name, ','), '') FROM sys.server_principals WHERE name LIKE 'pgvmrg[_]mon[_]%'")
[ -z "$leftl" ] || fail "MG1: a monitoring login of an earlier run: $leftl (drop it by hand)"
ok "MG1: publisher $PSN, subscriber $MSN; merge agent '$AGENT', job '$JOB' running; rows $ROWS"

echo "--- MG2. the monitoring login"
MADE_LOGIN=1   # before the batch: a failure after CREATE LOGIN still drops it (review q10c N7)
Sin p >"$WORK/sin" 2>&1 <<SQL || { mask < "$WORK/sin"; fail "MG2: the login"; }
SET NOCOUNT ON;
CREATE LOGIN [$LM] WITH PASSWORD = N'\$(MPM)', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO [$LM]; GRANT VIEW ANY DEFINITION TO [$LM];
GO
USE msdb; CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];
GO
USE distribution; CREATE USER [$LM] FOR LOGIN [$LM]; ALTER ROLE db_datareader ADD MEMBER [$LM];
SQL
[ "$(S p "SELECT IS_SRVROLEMEMBER('sysadmin', N'$LM')")" = 0 ] || fail "MG2: $LM is sysadmin"
export MSSQL_MERGE_PUB_DSN="sqlserver://$LM:$PM@$H:$PPORT?database=master&encrypt=true&TrustServerCertificate=true"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: mergeproof-pub\n    engine: sqlserver\n    dsn: env:MSSQL_MERGE_PUB_DSN\n' > "$CFG"
psql "$ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" >/dev/null; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
"$BIN" migrate -config "$CFG" > "$OUT" 2>&1 || { mask < "$OUT"; fail "the migrate"; }
ok "MG2: $LM, no sysadmin"
rd() {
  "$BIN" collect -config "$CFG" -once mssql_replication -instance mergeproof-pub > "$OUT" 2>&1 || { mask < "$OUT"; fail "the read of the publisher"; }
  local st; st=$(q "select c.status || ' ' || coalesce(c.note, '') from pgvigil.collection_dates c join pgvigil.instances i using (instance_id) where i.name = 'mergeproof-pub' and c.collection = 'mssql_replication'")
  [[ "$st" == "ok "* ]] || fail "the read of the publisher is not ok: $st"
  [ -n "$I" ] || I=$(q "select instance_id from pgvigil.instances where name = 'mergeproof-pub'")
}
fnd() { q "select coalesce(string_agg(severity || ':' || check_name || ':' || object, ',' order by check_name, object), '') from pgvigil.mssql_repl_findings where instance_id = $I"; }
# sa's newest session of the merge agent: runstatus|last run (epoch s, UTC)|its newest message
sa_sess() { local sid
  sid=$(S p "SELECT TOP (1) x.session_id FROM $D.MSmerge_sessions x JOIN $D.MSmerge_agents a ON a.id = x.agent_id WHERE a.publication = N'pgvm_merge' ORDER BY x.session_id DESC")
  echo "$(S p "SELECT CONCAT(runstatus, '|', DATEDIFF_BIG(second, '19700101', DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), COALESCE(end_time, start_time)))) FROM $D.MSmerge_sessions WHERE session_id = $sid")|$(S p "SELECT TOP (1) CAST(LEFT(y.comments, 1000) AS nvarchar(1000)) FROM $D.MSmerge_history y WHERE y.session_id = $sid ORDER BY y.timestamp DESC")"; }
st_sess() { q "select runstatus || '|' || floor(extract(epoch from last_run_at))::bigint || '|' || coalesce(status_text, '') from pgvigil.mssql_replication_state where instance_id = $I and kind = 'subscription' and agent_type = 'merge'"; }
sa_sessions() { S p "SELECT TOP (8) CONCAT(x.session_id, ' ', x.runstatus, ' ', CONVERT(varchar(19), x.start_time, 126), ' - ', ISNULL(CONVERT(varchar(19), x.end_time, 126), ''), ' duration ', ISNULL(CAST(x.duration AS varchar(12)), 'null')) FROM $D.MSmerge_sessions x JOIN $D.MSmerge_agents a ON a.id = x.agent_id WHERE a.publication = N'pgvm_merge' ORDER BY x.session_id DESC" | sed 's/^/      /'; }
mrow() { q "select $1 from pgvigil.mssql_replication_state where instance_id = $I and kind = 'subscription' and agent_type = 'merge'"; }
# the merge agent's sessions as sa reads them: the newest id; the newest runstatus; the rule's failing time (epoch s, UTC,
# as utcText converts: the start of the first retry / failed session after the newest succeeded / idle one, or null)
MSES="$D.MSmerge_sessions x JOIN $D.MSmerge_agents a ON a.id = x.agent_id WHERE a.publication = N'pgvm_merge'"
newest_sid() { S p "SELECT ISNULL(MAX(x.session_id), 0) FROM $MSES"; }
newest_rs() { S p "SELECT TOP (1) x.runstatus FROM $MSES ORDER BY x.session_id DESC"; }
sa_since() { S p "SELECT ISNULL(CAST(DATEDIFF_BIG(second, '19700101', DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), MIN(x.start_time))) AS varchar(20)), 'null') FROM $MSES AND x.runstatus IN (5, 6) AND x.session_id > ISNULL((SELECT MAX(y.session_id) FROM $D.MSmerge_sessions y WHERE y.agent_id = a.id AND y.runstatus IN (2, 4)), -2147483648)"; }
# wait_sess <base> <runstatus list>: up to 180 s for a session newer than base in one of those states; prints its runstatus
wait_sess() { local r; for _ in $(seq 1 36); do
    r=$(S p "SELECT TOP (1) x.runstatus FROM $MSES AND x.session_id > $1 AND x.runstatus IN ($2) ORDER BY x.session_id DESC") || r=
    [ -n "$r" ] && { echo "$r"; return 0; }; sleep 5; done; return 1; }

echo "--- MG3. a healthy read"
for try in 1 2; do   # once more when the newest session moved past both of sa's reads during the read (review q10c N9)
  A1=$(sa_sess); rd; A2=$(sa_sess); GOTS=$(st_sess)
  { [ "$GOTS" = "$A1" ] || [ "$GOTS" = "$A2" ]; } && break
  [ $try = 2 ] || echo "    the session moved during the read: read again"
done
[ "$GOTS" = "$A1" ] || [ "$GOTS" = "$A2" ] || red MG3-session "stored '$GOTS', sa '$A1' / '$A2'"
lc() { tr '[:upper:]' '[:lower:]'; }
PUBROW=$(q "select publisher || '|' || publisher_db || '|' || publication || '|' || publication_type || '|' || articles from pgvigil.mssql_replication_state where instance_id = $I and kind = 'publication'")
[ "$(echo "$PUBROW" | lc)" = "$(echo "$PSN|pgvmerge|pgvm_merge|merge|1" | lc)" ] || red MG3-publication "$PUBROW"
SUBROW=$(mrow "count(*) over () || '|' || agent_name || '|' || subscriber || '|' || subscriber_db || '|' || coalesce(subscription_type, 'null') || '|' || coalesce(subscription_status, 'null') || '|' || coalesce(failing_since::text, 'null') || '|' || coalesce(job_state, 'null') || '|' || coalesce(continuous::text, 'null')")
[ "$(echo "$SUBROW" | lc)" = "$(echo "1|$AGENT|$MSN|pgvmerge_sub|push|null|null|running|true" | lc)" ] || red MG3-subscription "$SUBROW"
[ "$(q "select count(*) from pgvigil.mssql_replication_state where instance_id = $I and kind = 'agent' and agent_type = 'merge'")" = 0 ] || red MG3-agentrow "a merge row of kind agent"
SNAP=$(q "select runstatus || '|' || coalesce(job_state, 'null') || '|' || coalesce(continuous::text, 'null') from pgvigil.mssql_replication_state where instance_id = $I and kind = 'agent' and agent_type = 'snapshot'")
[ "$SNAP" = "2|stopped|false" ] || red MG3-snapshot "$SNAP"
PUBDB=$(q "select database_name || '|' || publication_type || '|' || distributor_local from pgvigil.mssql_replication_state where instance_id = $I and kind = 'published_db'")
[ "$PUBDB" = "pgvmerge|merge|true" ] || red MG3-published "$PUBDB"
[ "$(q "select count(*) from pgvigil.mssql_repl_sample where instance_id = $I and agent_type = 'merge' and latency_s is not null")" = 0 ] || red MG3-sample "a merge sample with a latency"
[ -z "$(fnd)" ] || red MG3-findings "$(fnd)"
L1=$(mrow "floor(extract(epoch from last_run_at))::bigint"); sleep 90; rd; L2=$(mrow "floor(extract(epoch from last_run_at))::bigint")
echo "    the stored last run: $L1, 90 s later $L2; sa's sessions:"; sa_sessions
[ "$L2" -gt "$L1" ] || red MG3-idle "the last run did not move in 90 s"
ok "MG3: subscription '$SUBROW'; session '$GOTS'; publication '$PUBROW'; snapshot '$SNAP'; published '$PUBDB'"

echo "--- MG4. the merge agent fails"
JOB_STOPPED=1; stop_job || fail "MG4: the job did not stop"   # flags before their action (review q10c N7)
BASE=$(newest_sid)   # the stop's own session and every older one are not the fault's (review q10c S4)
PW_WRONG=1; set_pw MBAD || fail "MG4: the wrong password"
start_job || fail "MG4: the job did not start"; JOB_STOPPED=
T0=$(S p "SELECT DATEDIFF_BIG(second, '19700101', SYSUTCDATETIME())")
FAILED=$(wait_sess "$BASE" "5, 6") || FAILED=
echo "    a retry / failed session newer than $BASE: ${FAILED:-none in 180 s}; sa's sessions:"; sa_sessions
echo "    sa's newest MSrepl_errors rows (the failure's stack, as SQL Server wrote it):"
S p "SELECT TOP (6) CONCAT(id, ' ', CONVERT(varchar(23), time, 126), ' code ', ISNULL(error_code, ''), ': ', LEFT(CAST(error_text AS nvarchar(max)), 140)) FROM $D.MSrepl_errors ORDER BY time DESC, id DESC" | mask | sed 's/^/      /'
if [ -n "$FAILED" ]; then
  for try in 1 2; do
    R1=$(newest_rs); SS1=$(sa_since); rd; R2=$(newest_rs); SS2=$(sa_since)
    F=$(mrow "runstatus || '|' || coalesce(floor(extract(epoch from failing_since))::bigint::text, 'null') || '|' || coalesce(error_code, 'null') || '|' || coalesce(error_text, 'null')")
    IFS='|' read -r FRS FSINCE FCODE _ <<<"$F"
    { [ "$FRS" = "$R1" ] || [ "$FRS" = "$R2" ]; } && { [ "$FSINCE" = "$SS1" ] || [ "$FSINCE" = "$SS2" ]; } && break
    [ $try = 2 ] || echo "    the sessions moved during the read: read again"
  done
  echo "    stored: $F" | mask
  [ "$FRS" = "$R1" ] || [ "$FRS" = "$R2" ] || red MG4-runstatus "stored $FRS, sa $R1 / $R2"
  [ "$FSINCE" = "$SS1" ] || [ "$FSINCE" = "$SS2" ] || red MG4-since "stored $FSINCE, sa's rule $SS1 / $SS2"
  [[ $FSINCE =~ ^[0-9]+$ ]] && echo "    failing since: $(( FSINCE - T0 )) s from the job's start after the change (negative: the stop's own session)"
  [ "$FCODE" = 18456 ] || echo "    the error code is $FCODE, not 18456 (said, not a red: the code SQL Server gave)"
  [ "$FCODE" != null ] || red MG4-error "no error code"
  [[ "$(fnd)" == *"warning:a replication agent failed:merge / $AGENT"* ]] || red MG4-failed "$(fnd)"
  o=$(q "select pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'set', 'key', 'repl_agent_retrying', 'level', 'instance', 'instance_id', $I, 'warn', 1, 'ui_user', 'proof'))->>'outcome'")
  [ "$o" = done ] || fail "MG4: the retrying threshold: $o"
  if [[ $FSINCE =~ ^[0-9]+$ ]]; then   # a stored null failing time leaves no time to wait for (review q10c S2)
    wait_s=$(( FSINCE + 70 - $(S p "SELECT DATEDIFF_BIG(second, '19700101', SYSUTCDATETIME())") )); [ "$wait_s" -gt 0 ] && sleep "$wait_s"
    rd
    FS=$(fnd)
    [[ "$FS" == *"a replication agent keeps failing or retrying:merge / $AGENT"* && "$FS" != *"a replication agent failed:merge / $AGENT"* ]] || red MG4-keeps "$FS"
  else
    red MG4-keeps "no failing time stored: the threshold step not run"
  fi
else
  red MG4-nofailure "no retry or failed session newer than $BASE in 180 s"
fi
JOB_STOPPED=1; stop_job || fail "MG4: the job did not stop"
BASE=$(newest_sid)
set_pw MSA || fail "MG4: the password back"; PW_WRONG=
start_job || fail "MG4: the job did not start"; JOB_STOPPED=
GOOD=$(wait_sess "$BASE" "2, 4") || GOOD=
[ -n "$GOOD" ] || red MG4-recovery "no good session newer than $BASE in 180 s"
rd
[ "$(mrow "coalesce(failing_since::text, 'null')")" = null ] || red MG4-cleared "still failing: $(mrow "failing_since")"
FS=$(fnd); [[ "$FS" != *"merge / $AGENT"* ]] || red MG4-cleared "$FS"
q "select pgvigil.import_pg_threshold(now(), jsonb_build_object('op', 'inherit', 'key', 'repl_agent_retrying', 'level', 'instance', 'instance_id', $I, 'ui_user', 'proof'))" >/dev/null
ok "MG4: done (any RED line above names a difference)"

echo "--- MG5. the merge agent's job stopped"
JOB_STOPPED=1; stop_job || fail "MG5: the job did not stop"
BASE=$(newest_sid)
echo "    sa's sessions after the stop (what a stop leaves):"; sa_sessions
rd; sleep 5; rd
[ "$(mrow "coalesce(job_state, 'null') || '|' || coalesce(continuous::text, 'null')")" = "stopped|true" ] || red MG5-job "$(mrow "job_state || '|' || continuous")"
[[ "$(fnd)" == *"warning:a replication agent is stopped:merge / $AGENT"* ]] || red MG5-stopped "$(fnd)"
SDET=$(q "select detail from pgvigil.mssql_repl_findings where instance_id = $I and object = 'merge / $AGENT' limit 1" || true)
start_job || fail "MG5: the job did not start"; JOB_STOPPED=
GOOD=$(wait_sess "$BASE" "2, 4") || GOOD=   # the clearing read only after a session of the new run (review q10c S4)
[ -n "$GOOD" ] || red MG5-good "no good session newer than $BASE in 180 s"
rd
[ -z "$(fnd)" ] || red MG5-cleared "$(fnd)"
ok "MG5: stopped -> '$SDET'; none after the start"

echo "--- MG6. the statements as the monitoring login"
# printed for the read's cost and its match (review q10a, could not verify): the merge tables' indexes, and whether
# MSmerge_subscriptions' publication_id is MSpublications' on this distributor
S p "SELECT CONCAT(t.name, ': ', i.name, ' (', STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal), ')') FROM distribution.sys.indexes i JOIN distribution.sys.tables t ON t.object_id = i.object_id JOIN distribution.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0 JOIN distribution.sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id WHERE t.name IN ('MSmerge_sessions', 'MSmerge_history', 'MSmerge_agents', 'MSmerge_subscriptions') GROUP BY t.name, i.name ORDER BY t.name, i.name" | sed 's/^/    index /'
echo "    publication ids (MSpublications | MSmerge_subscriptions): $(S p "SELECT CONCAT(p.publication_id, '|', m.publication_id) FROM $D.MSpublications p JOIN $D.MSmerge_subscriptions m ON m.publisher_id = p.publisher_id AND m.publisher_db = p.publisher_db WHERE p.publication = N'pgvm_merge'" | tr '\n' ' ')"
if PGVIGIL_MSSQL_TEST_DSN="$MSSQL_MERGE_PUB_DSN" PGVIGIL_MSSQL_TEST_DISTRIBUTION=distribution \
   go test ./internal/mssql/ -run 'TestHADRStatementsLive|TestReplicationStatementsLive' -count=1 -v > "$OUT" 2>&1 \
   && [ "$(grep -c -E '^--- PASS: (TestHADRStatementsLive|TestReplicationStatementsLive)' "$OUT")" = 2 ]; then
  ok "MG6: both live tests pass"
else mask < "$OUT" | tail -20; red MG6 "the live tests"; fi
echo "--- MG7. removed"
if drop_login; then MADE_LOGIN=; ok "MG7: login $LM dropped (read back); the helper and the repository: cleanup follows"
else red MG7-login "login $LM left on PGVPRINCIPAL (cleanup tries again)"; fi
if [ ${#RED[@]} -gt 0 ]; then echo "PART W RED: ${RED[*]}"; exit 1; fi
OKLINE="PROOF OK (part W)"
exit 0
