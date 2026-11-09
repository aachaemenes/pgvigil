#!/usr/bin/env bash
# Proof of the dms collection. Two parts:
#   recorded (always): the collector's rows from the recorded API responses in internal/collect/testdata/dms
#                      fill a repository (go test TestDmsFixtureImport with PGVIGIL_REPO_DSN).
#   live (LIVE=1):     `collect -once dms` against a real replication task, read through the lab's Aurora
#                      instance config (aws.dms.tasks), needs an active `aws login --profile <profile>` and
#                      a running task (the lab's dmslab test, Build then Test); RECORD=1 also re-records the
#                      testdata from the live API (account id and host names masked).
#   PGVIGIL_REPO_DSN   repository;  AWS_PROFILE default dba-lab;  CLUSTER default dba-lab-pg;  TASK default dmslab-task
# Expected (live): one dms_tasks row for the task with status running or stopped, its replication instance row,
# a dbo.orders table row with full_load_rows >= 1000, a latency datapoint while running, one sample per collect,
# the second collect adding no task row; overview check rows only when the task is not running clean.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
PROFILE=${AWS_PROFILE:-dba-lab}; REGION=${AWS_REGION:-us-east-2}; CLUSTER=${CLUSTER:-dba-lab-pg}; TASK=${TASK:-dmslab-task}
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }

echo "--- recorded responses -> repository"
PGVIGIL_REPO_DSN="$PGVIGIL_REPO_DSN" go test ./internal/collect -run 'TestDms' -count=1 -v 2>&1 | grep -E '^(=== RUN|--- (PASS|FAIL|SKIP)|PASS|FAIL|ok|\s+dms_test)' || fail "recorded-response tests"
echo "recorded: OK"

echo "--- alert rules: seeded states through import_dms on a scratch instance"
"$BIN" version >/dev/null
SID=$(q "select pgvigil.ensure_instance('dms-checks-proof-$RANDOM', 'aurora', 'proof', 170009, false, '{proof}')")
RI='arn:aws:dms:us-east-2:123456789012:rep:PROOFRI'
seed() { q "select pgvigil.import_dms($SID, now(), \$j\$$1\$j\$::jsonb)" >/dev/null; }
seed "[{\"kind\":\"ri\",\"ri_arn\":\"$RI\",\"ri_id\":\"proof-ri\",\"status\":\"available\",\"allocated_gb\":20,\"free_storage_bytes\":536870912,\"freeable_bytes\":2000000000,\"swap_bytes\":0},
 {\"kind\":\"task\",\"task_arn\":\"arn:aws:dms:us-east-2:123456789012:task:FAILED\",\"task_id\":\"t-failed\",\"ri_arn\":\"$RI\",\"migration_type\":\"full-load-and-cdc\",\"status\":\"failed\",\"last_failure\":\"Last Error  Task error notification received from subtask 0, thread 0 [reason: cannot connect]\",\"latency_warn_secs\":300},
 {\"kind\":\"task\",\"task_arn\":\"arn:aws:dms:us-east-2:123456789012:task:STOPPEDCDC\",\"task_id\":\"t-stopped-cdc\",\"ri_arn\":\"$RI\",\"migration_type\":\"cdc\",\"status\":\"stopped\",\"stop_reason\":\"Stop Reason NORMAL\",\"latency_warn_secs\":300},
 {\"kind\":\"task\",\"task_arn\":\"arn:aws:dms:us-east-2:123456789012:task:DONEFL\",\"task_id\":\"t-done-full-load\",\"ri_arn\":\"$RI\",\"migration_type\":\"full-load\",\"status\":\"stopped\",\"stop_reason\":\"Stop Reason FULL_LOAD_ONLY_FINISHED\",\"progress_pct\":100,\"latency_warn_secs\":300},
 {\"kind\":\"task\",\"task_arn\":\"arn:aws:dms:us-east-2:123456789012:task:LAGGING\",\"task_id\":\"t-lagging\",\"ri_arn\":\"$RI\",\"migration_type\":\"full-load-and-cdc\",\"status\":\"running\",\"latency_source_s\":12,\"latency_target_s\":400,\"latency_at\":\"2026-11-09T12:00:00Z\",\"latency_warn_secs\":300},
 {\"kind\":\"task\",\"task_arn\":\"arn:aws:dms:us-east-2:123456789012:task:LOWDISK\",\"task_id\":\"t-lowdisk\",\"ri_arn\":\"$RI\",\"migration_type\":\"cdc\",\"status\":\"stopped\",\"stop_reason\":\"Stop Reason STOPPED_DUE_TO_LOW_DISK\",\"latency_warn_secs\":300},
 {\"kind\":\"task\",\"task_arn\":\"arn:aws:dms:us-east-2:123456789012:task:HEALTHY\",\"task_id\":\"t-healthy\",\"ri_arn\":\"$RI\",\"migration_type\":\"full-load-and-cdc\",\"status\":\"running\",\"latency_source_s\":2,\"latency_target_s\":1,\"tables_errored\":0,\"latency_warn_secs\":300},
 {\"kind\":\"table\",\"task_arn\":\"arn:aws:dms:us-east-2:123456789012:task:HEALTHY\",\"schema_name\":\"public\",\"table_name\":\"bad\",\"table_state\":\"Table error\",\"full_load_rows\":10,\"full_load_error_rows\":3,\"validation_failed\":2,\"validation_state\":\"Mismatched records\"}]"
GOT=$(q "select check_name || '|' || severity || '|' || object from pgvigil.dms_checks where instance_id=$SID" | sort)
WANT=$(printf '%s\n' 'DMS CDC latency|warning|t-lagging' 'DMS instance storage low|critical|proof-ri' 'DMS validation failures|warning|t-healthy' 'DMS tables in error|warning|t-healthy' 'DMS task failed|critical|t-failed' 'DMS task failed|critical|t-lowdisk' 'DMS task stopped|warning|t-stopped-cdc' | sort)
if [[ "$GOT" != "$WANT" ]]; then echo "got:"; echo "$GOT"; echo "want:"; echo "$WANT"; q "delete from pgvigil.instances where instance_id=$SID" >/dev/null; fail "dms_checks rows differ"; fi
q "delete from pgvigil.instances where instance_id=$SID" >/dev/null
echo "alert rules: OK (7 findings, the finished full-load task and the healthy task's own state raise none)"

[[ "${LIVE:-0}" == 1 ]] || { echo "proof-dms: OK (recorded only; LIVE=1 for the lab task)"; exit 0; }

echo "--- live: task $TASK through $CLUSTER ($PROFILE, $REGION)"
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE" --region "$REGION")
TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username postgres --profile "$PROFILE" --region "$REGION")
export AURORA_DSN="host=$H port=5432 user=postgres dbname=postgres sslmode=require connect_timeout=60 password=$TOKEN"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: lab-aurora-writer
    dsn: env:AURORA_DSN
    aws: {region: $REGION, profile: $PROFILE, cluster: $CLUSTER, dms: {tasks: [$TASK], latency_warn_secs: 300}}
EOF
"$BIN" migrate -config "$CFG" >/dev/null
PGPASSWORD=$TOKEN psql "host=$H port=5432 user=postgres dbname=postgres sslmode=require connect_timeout=60" -XAtq -c "select 1" >/dev/null   # wakes a paused writer
"$BIN" collect -config "$CFG" -once instance >/dev/null
iid=$(q "select instance_id from pgvigil.instances where name='lab-aurora-writer'")
"$BIN" collect -config "$CFG" -once dms || fail "collect dms"
ARN=$(q "select task_arn from pgvigil.dms_tasks where instance_id=$iid and task_id='$TASK' and is_present")
[[ -n "$ARN" ]] || fail "no dms_tasks row for $TASK"
STATUS=$(q "select status from pgvigil.dms_tasks where instance_id=$iid and task_arn='$ARN'")
RI=$(q "select count(*) from pgvigil.dms_instances r join pgvigil.dms_tasks t using (instance_id, ri_arn) where t.task_arn='$ARN' and r.is_present")
ORDERS=$(q "select coalesce(max(full_load_rows), -1) from pgvigil.dms_table_stats where instance_id=$iid and task_arn='$ARN' and schema_name='dbo' and table_name='orders'")
LAT=$(q "select coalesce(latency_source_s::text, 'none') || '/' || coalesce(latency_target_s::text, 'none') from pgvigil.dms_tasks where task_arn='$ARN'")
CPU=$(q "select coalesce(cpu_pct::text, 'none') from pgvigil.dms_instances r join pgvigil.dms_tasks t using (instance_id, ri_arn) where t.task_arn='$ARN'")
LOGNOTE=$(q "select coalesce(status || coalesce(': ' || note, ''), '-') from pgvigil.collection_dates where instance_id=$iid and collection='dms'")
echo "task status=$STATUS replication_instances=$RI orders_full_load_rows=$ORDERS latency(source/target)=$LAT ri_cpu=$CPU collection=$LOGNOTE"
[[ "$STATUS" == running || "$STATUS" == stopped ]] || fail "task status $STATUS"
[[ "$RI" == 1 ]] || fail "replication instance row missing"
[[ "$ORDERS" -ge 1000 ]] || fail "dbo.orders full_load_rows $ORDERS"
[[ "$LOGNOTE" == ok ]] || fail "the collection did not end ok (a metrics error is 'partial'): $LOGNOTE"
if [[ "$STATUS" == running ]]; then [[ "$LAT" != none/none ]] || fail "a running task has no CDC latency datapoint"; fi
[[ "$CPU" != none ]] || fail "no CPUUtilization datapoint for the replication instance"
N1=$(q "select count(*) from pgvigil.dms_tasks where instance_id=$iid"); S1=$(q "select count(*) from pgvigil.dms_task_sample where instance_id=$iid")
"$BIN" collect -config "$CFG" -once dms >/dev/null || fail "second collect"
N2=$(q "select count(*) from pgvigil.dms_tasks where instance_id=$iid"); S2=$(q "select count(*) from pgvigil.dms_task_sample where instance_id=$iid")
[[ "$N1" == "$N2" ]] || fail "a second collect added a task row: $N1 -> $N2"
[[ "$S2" == $((S1 + 1)) ]] || fail "samples $S1 -> $S2, want one more"
CHECKS=$(q "select coalesce(string_agg(check_name || ' (' || severity || '): ' || detail, '; '), 'none') from pgvigil.dms_checks where instance_id=$iid")
echo "checks: $CHECKS"
q "select task_id, status, migration_type, progress_pct, tables_loaded, tables_errored, round(latency_source_s) as lat_src, round(latency_target_s) as lat_tgt, incoming_changes from pgvigil.dms_tasks where instance_id=$iid"
q "select schema_name, table_name, table_state, full_load_rows, inserts, updates, deletes, validation_state from pgvigil.dms_table_stats where instance_id=$iid and task_arn='$ARN' order by 1,2"

if [[ "${RECORD:-0}" == 1 ]]; then
  echo "--- recording the live responses into internal/collect/testdata/dms"
  D=internal/collect/testdata/dms; mkdir -p "$D"
  ACCT=$(aws sts get-caller-identity --query Account --output text --profile "$PROFILE")
  mask() { sed -e "s/$ACCT/123456789012/g" -e 's/\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}/10.0.0.1/g' -e 's/[a-z0-9-]*\.rds\.amazonaws\.com/db.example.internal/g'; }
  aws dms describe-replication-tasks --without-settings --filters "Name=replication-task-id,Values=$TASK" --output json --profile "$PROFILE" --region "$REGION" | mask > "$D/tasks.json"
  RAW_ARN=$(aws dms describe-replication-tasks --without-settings --filters "Name=replication-task-id,Values=$TASK" --query 'ReplicationTasks[0].ReplicationTaskArn' --output text --profile "$PROFILE" --region "$REGION")
  RI_ARN=$(aws dms describe-replication-tasks --without-settings --filters "Name=replication-task-id,Values=$TASK" --query 'ReplicationTasks[0].ReplicationInstanceArn' --output text --profile "$PROFILE" --region "$REGION")
  aws dms describe-table-statistics --replication-task-arn "$RAW_ARN" --output json --profile "$PROFILE" --region "$REGION" | mask > "$D/tables-${RAW_ARN##*:}.json"
  aws dms describe-replication-instances --filters "Name=replication-instance-arn,Values=$RI_ARN" --output json --profile "$PROFILE" --region "$REGION" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)
for r in d["ReplicationInstances"]:
    for k in ("ReplicationInstancePublicIpAddress","ReplicationInstancePublicIpAddresses","ReplicationInstancePrivateIpAddress","ReplicationInstancePrivateIpAddresses","ReplicationInstanceIpv6Addresses","KmsKeyId","VpcSecurityGroups","ReplicationSubnetGroup","ReplicationInstanceEniId","ReplicationInstanceEniIds","DnsNameServers"):
        r.pop(k, None)
print(json.dumps(d, indent=2))' | mask > "$D/instances.json"
  RI_ID=$(aws dms describe-replication-instances --filters "Name=replication-instance-arn,Values=$RI_ARN" --query 'ReplicationInstances[0].ReplicationInstanceIdentifier' --output text --profile "$PROFILE" --region "$REGION")
  # the datapoints the collector read, keyed the way the fake answers them (metric + dimension values)
  END=$(date -u +%Y-%m-%dT%H:%M:%SZ); START=$(date -u -d '-15 min' +%Y-%m-%dT%H:%M:%SZ)
  {
    echo "["
    first=1
    for M in CDCLatencySource CDCLatencyTarget CDCIncomingChanges; do
      V=$(aws cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name "$M" --dimensions "Name=ReplicationInstanceIdentifier,Value=$RI_ID" "Name=ReplicationTaskIdentifier,Value=${RAW_ARN##*:}" --start-time "$START" --end-time "$END" --period 60 --statistics Maximum --query 'sort_by(Datapoints,&Timestamp)[-1].[Maximum,Timestamp]' --output text --profile "$PROFILE" --region "$REGION")
      [[ "$V" == None* || -z "$V" ]] && continue
      read -r VAL AT <<<"$V"; [[ $first == 1 ]] || echo ","; first=0
      printf '  {"metric": "%s", "dims": {"ReplicationInstanceIdentifier": "%s", "ReplicationTaskIdentifier": "%s"}, "value": %s, "at": "%s"}' "$M" "$RI_ID" "${RAW_ARN##*:}" "$VAL" "$AT"
    done
    for MS in CPUUtilization:Average FreeableMemory:Minimum FreeStorageSpace:Minimum SwapUsage:Maximum; do
      M=${MS%%:*}; ST=${MS##*:}
      V=$(aws cloudwatch get-metric-statistics --namespace AWS/DMS --metric-name "$M" --dimensions "Name=ReplicationInstanceIdentifier,Value=$RI_ID" --start-time "$START" --end-time "$END" --period 60 --statistics "$ST" --query "sort_by(Datapoints,&Timestamp)[-1].[$ST,Timestamp]" --output text --profile "$PROFILE" --region "$REGION")
      [[ "$V" == None* || -z "$V" ]] && continue
      read -r VAL AT <<<"$V"; [[ $first == 1 ]] || echo ","; first=0
      printf '  {"metric": "%s", "dims": {"ReplicationInstanceIdentifier": "%s"}, "value": %s, "at": "%s"}' "$M" "$RI_ID" "$VAL" "$AT"
    done
    echo; echo "]"
  } > "$D/metrics.json"
  ls -la "$D"
fi
echo "proof-dms: OK (live task $TASK: $STATUS, orders $ORDERS rows, latency $LAT)"
