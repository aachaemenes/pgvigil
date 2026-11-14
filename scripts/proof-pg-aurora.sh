#!/usr/bin/env bash
# proof-pg-aurora.sh - an Aurora PostgreSQL reader judged by aurora_replica_status, on a REAL reader (task 374; migration
# 0141): what scripts/proof-pg-hadr.sh's AU row proves on a repository stand-in. Needs: the aws CLI signed in, psql, a
# built pgvigil binary. Costs: a reader instance for about half an hour while PGVIGIL_AURORA_CREATE=1.
#
# Nothing in this file names an account, cluster, instance, profile, region or endpoint: every one comes from the
# environment, and the script refuses to start without them:
#   AWS_PROFILE, AWS_REGION      the aws CLI's own
#   PGVIGIL_AURORA_CLUSTER       an Aurora PostgreSQL cluster with IAM database authentication on
#   PGVIGIL_AURORA_READER        the reader instance's identifier
#   PGVIGIL_AURORA_USER          the database login, signed in through IAM (it creates the repository databases and the
#                                roles 'pgvigil migrate' makes; both removed at the end)
#   PGVIGIL_BIN                  the pgvigil binary under test (the green pass)
#   PGVIGIL_RED_BIN              optional: a binary of the tree before the change (the red pass, same reader, same hour)
#   PGVIGIL_AURORA_CREATE        1 = this script creates the reader (db.serverless, promotion tier 15) and DELETES it on
#                                every exit, then reads back that it is gone; unset = the reader must exist and stays
# The IAM tokens (aws rds generate-db-auth-token, 15 minutes) live only in this process's environment: pgvigil reads
# its DSNs through 'env:' (config.Resolve), the config file names the variables only, psql gets PGPASSWORD per call;
# nothing prints a token or a DSN.
#
# Expected (written before the first run, 2026-11-14 13:5x PST). A 'read' is one `pgvigil collect -once replication` of
# one instance; aurora-w is the writer instance's endpoint, aurora-r the reader's; each pass has its own repository
# database on the writer (pgvigil_q7 green, pgvigil_q7red red), made here and dropped at the end:
#   Q7a  the reader available; the writer and the reader answer through IAM (the first query after an auto-pause waits
#        about 15 s: polled up to 120 s)
#   Q7b  'collect -once instance': pgvigil.instances holds aurora-r and aurora-w, both platform aurora
#   Q7c  two reads of aurora-w: its aurora_replica rows hold the writer's own row (session_id MASTER_SESSION_ID) once
#        and a row for the reader (server_id = PGVIGIL_AURORA_READER) with its lag in seconds
#   Q7d  two reads of aurora-r: its standby state in recovery (whether Aurora shows a WAL receiver is printed, not
#        judged); no 'receiver down' on aurora-r; no link row for aurora-r (pg_repl_link_health)
#   Q7e  'standby_replay_lag' set on aurora-w to warning 0 s / critical 300 s (a real reader lags milliseconds), one read
#        of each: 'Aurora replica lag' warning on aurora-w naming the reader, none for the writer's own row, none raised
#        on aurora-r from its own aurora_replica_status rows (the reader is in recovery); the threshold inherited again
#   red  PGVIGIL_RED_BIN = the tree of task 374 before its review fold (ece715d): every row as above but Q7e's 'none on
#        aurora-r' [red FAIL: no reader exclusion there]; the run reports 'red: as marked' or each difference
#   end  the repository databases dropped, the roles migrate made dropped (by name: the roles after the run that were
#        not there before it); with PGVIGIL_AURORA_CREATE=1 the reader deleted (on any exit) and read back: the
#        cluster's members without it, and describe-db-instances answering DBInstanceNotFound
# Not proven here: a real replica lag past 30 s (it cannot be made on purpose on Aurora); 'Aurora replica lag'
# critical; a cluster with several readers.
# Prints 'ok' / 'FAIL' per assertion and 'proof-pg-aurora: OK' or 'proof-pg-aurora: <n> FAIL'; exit 0 only when the
# green pass passed, the red pass (when run) failed exactly as marked, and the end's removals and read-back held.
set -uo pipefail
cd "$(dirname "$0")/.."
FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }

miss=""
for v in AWS_PROFILE AWS_REGION PGVIGIL_AURORA_CLUSTER PGVIGIL_AURORA_READER PGVIGIL_AURORA_USER PGVIGIL_BIN; do
  [[ -n "${!v:-}" ]] || miss+=" $v"
done
[[ -z "$miss" ]] || { echo "proof-pg-aurora: refused - set in the environment:$miss (the header names each)"; exit 2; }
[[ -x "$PGVIGIL_BIN" ]] || { echo "proof-pg-aurora: refused - PGVIGIL_BIN is not an executable file"; exit 2; }
[[ -z "${PGVIGIL_RED_BIN:-}" || -x "$PGVIGIL_RED_BIN" ]] || { echo "proof-pg-aurora: refused - PGVIGIL_RED_BIN is not an executable file"; exit 2; }
command -v aws >/dev/null && command -v psql >/dev/null || { echo "proof-pg-aurora: refused - needs the aws CLI and psql"; exit 2; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "proof-pg-aurora: refused - the aws CLI is not signed in for AWS_PROFILE"; exit 2; }

C=$PGVIGIL_AURORA_CLUSTER; R=$PGVIGIL_AURORA_READER; U=$PGVIGIL_AURORA_USER
WORK=$(mktemp -d); CREATED=0; DBS=""; ROLES0=""; WH=""; RH=""
member_ids() { aws rds describe-db-clusters --db-cluster-identifier "$C" --query 'DBClusters[0].DBClusterMembers[].DBInstanceIdentifier' --output text 2>/dev/null | tr '\t' ' '; }
endpoint() { aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null; }
tok() { aws rds generate-db-auth-token --hostname "$1" --port 5432 --username "$U"; }
psqlh() { # psqlh <host> <database> <sql>: one statement as the IAM login, the token in psql's environment only
  local t; t=$(tok "$1") || return 1
  PGPASSWORD=$t PGCONNECT_TIMEOUT=20 psql "host=$1 port=5432 user=$U dbname=$2 sslmode=require" -XAtq -v ON_ERROR_STOP=1 -c "$3"
}
q() { local o; o=$(psqlh "$WH" "$DB" "$1" 2>"$WORK/q.err") && { [[ -n "$o" ]] && printf '%s\n' "$o"; return 0; }; echo "QUERY FAILED: $(tail -1 "$WORK/q.err")"; return 1; }
wake() { local _; for _ in $(seq 1 24); do psqlh "$1" postgres 'select 1' >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }

cleanup() {
  set +e
  if [[ -n "$DBS$ROLES0" && -n "$WH" ]] && wake "$WH"; then
    for d in $DBS; do psqlh "$WH" postgres "drop database if exists $d with (force)" >/dev/null 2>&1 && echo "  dropped database $d" || echo "FAIL end: database $d not dropped"; done
    if [[ -n "$ROLES0" ]]; then
      for r in $(psqlh "$WH" postgres "select rolname from pg_roles order by 1" 2>/dev/null); do
        [[ " $ROLES0 " == *" $r "* ]] && continue
        psqlh "$WH" postgres "drop role \"$r\"" >/dev/null 2>&1 && echo "  dropped role $r (made by this run)" || echo "FAIL end: role $r (made by this run) not dropped"
      done
    fi
  elif [[ -n "$DBS" ]]; then echo "FAIL end: the writer did not answer: databases $DBS and this run's roles NOT dropped"; fi
  if (( CREATED )); then
    echo "  deleting the reader (it was created by this run)"
    aws rds delete-db-instance --db-instance-identifier "$R" >/dev/null 2>&1 || echo "FAIL end: delete-db-instance refused"
    aws rds wait db-instance-deleted --db-instance-identifier "$R" 2>/dev/null || echo "FAIL end: the wait for the deletion ended early"
    m=$(member_ids); g=$(aws rds describe-db-instances --db-instance-identifier "$R" 2>&1 >/dev/null | grep -o DBInstanceNotFound | head -1)
    echo "  read-back: cluster members [$m]; describe-db-instances of the reader: ${g:-still found}"
    [[ " $m " != *" $R "* && "$g" == "DBInstanceNotFound" ]] && echo "ok   end: the reader is gone" || echo "FAIL end: the reader is NOT gone"
  fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP   # a stop is an exit: the EXIT trap deletes what this run made

# ---- the writer and the reader ----------------------------------------------------------------------------------------
W=$(aws rds describe-db-clusters --db-cluster-identifier "$C" --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier' --output text 2>/dev/null)
[[ -n "$W" && "$W" != "None" ]] || { echo "proof-pg-aurora: refused - no writer found in the cluster"; exit 2; }
[[ "$W" != "$R" ]] || { echo "proof-pg-aurora: refused - PGVIGIL_AURORA_READER names the writer"; exit 2; }
WH=$(endpoint "$W")
if [[ "${PGVIGIL_AURORA_CREATE:-}" == "1" ]]; then
  aws rds describe-db-instances --db-instance-identifier "$R" >/dev/null 2>&1 \
    && { echo "proof-pg-aurora: refused - $R exists already (this script deletes only a reader it created)"; exit 2; }
  ENG=$(aws rds describe-db-clusters --db-cluster-identifier "$C" --query 'DBClusters[0].Engine' --output text)
  if aws rds create-db-instance --db-instance-identifier "$R" --db-cluster-identifier "$C" --engine "$ENG" \
       --db-instance-class db.serverless --promotion-tier 15 >/dev/null 2>"$WORK/create.err"; then
    CREATED=1; echo "  the reader created at $(date -u '+%H:%M:%S') UTC; waiting for it to be available"
  else
    echo "FAIL Q7a the reader was not created: $(tail -1 "$WORK/create.err")"; echo "proof-pg-aurora: 1 FAIL"; exit 3
  fi
  aws rds wait db-instance-available --db-instance-identifier "$R" || { fail "Q7a the reader did not become available"; exit 1; }
else
  [[ " $(member_ids) " == *" $R "* ]] || { echo "proof-pg-aurora: refused - $R is not a member of the cluster (set PGVIGIL_AURORA_CREATE=1 to make it)"; exit 2; }
fi
RH=$(endpoint "$R")
wake "$WH" && wake "$RH" && ok "Q7a the reader available; the writer and the reader answer through IAM" || { fail "Q7a an instance did not answer through IAM in 120 s"; exit 1; }
[[ "$(psqlh "$RH" postgres 'select pg_is_in_recovery()')" == "t" ]] || { fail "Q7a the reader is not in recovery"; exit 1; }
ROLES0=" $(psqlh "$WH" postgres "select string_agg(rolname, ' ' order by rolname) from pg_roles") "

# ---- one pass: a binary, its own repository database ---------------------------------------------------------------------
dsn() { echo "host=$1 port=5432 user=$U dbname=$2 sslmode=require password='$(tok "$1")'"; }
refresh() { Q7_REPO_DSN=$(dsn "$WH" "$DB"); Q7_W_DSN=$(dsn "$WH" postgres); Q7_R_DSN=$(dsn "$RH" postgres); export Q7_REPO_DSN Q7_W_DSN Q7_R_DSN; }
PASS=""; RED_EXPECT=" Q7e-reader "; REDMISS=0
chk() { # chk <id> <0|1 = ok> <message>: a green row counts; a red row is graded against RED_EXPECT
  if [[ "$PASS" == green ]]; then (( $2 )) && ok "$1 $3" || fail "$1 $3"
  elif [[ "$RED_EXPECT" == *" $1 "* ]]; then (( $2 )) && { echo "FAIL red $1 passed on the red tree: $3"; REDMISS=$((REDMISS + 1)); } || echo "ok   red $1 failed as marked: $3"
  else (( $2 )) && echo "ok   red $1 $3" || { echo "FAIL red $1 (not marked to fail): $3"; REDMISS=$((REDMISS + 1)); }; fi
}
run_pass() { # run_pass <green|red> <binary> <database>
  PASS=$1; BIN=$2; DB=$3
  psqlh "$WH" postgres "select 1 from pg_database where datname = '$DB'" | grep -q 1 && { fail "$PASS: database $DB exists already (never dropped by this run)"; return; }
  psqlh "$WH" postgres "create database $DB" >/dev/null || { fail "$PASS: database $DB not created"; return; }
  DBS+=" $DB"
  cat > "$WORK/$DB.yaml" <<EOF
repository:
  dsn: env:Q7_REPO_DSN
instances:
  - name: aurora-w
    dsn: env:Q7_W_DSN
  - name: aurora-r
    dsn: env:Q7_R_DSN
EOF
  CFG=$WORK/$DB.yaml
  refresh; "$BIN" migrate -config "$CFG" >"$WORK/$DB-migrate.out" 2>&1 || { fail "$PASS: migrate: $(tail -1 "$WORK/$DB-migrate.out")"; return; }
  refresh; "$BIN" collect -config "$CFG" -once instance >"$WORK/$DB-collect.out" 2>&1 || { fail "$PASS: collect instance: $(tail -1 "$WORK/$DB-collect.out")"; return; }
  rd() { local i; for ((i = 0; i < ${2:-1}; i++)); do (( i > 0 )) && sleep 3; refresh
    "$BIN" collect -config "$CFG" -once replication -instance "$1" >>"$WORK/$DB-collect.out" 2>&1 || fail "$PASS: read of $1 failed: $(tail -1 "$WORK/$DB-collect.out")"; done; }
  r=$(q "select string_agg(name || ' ' || platform, ', ' order by name) from pgvigil.instances")
  chk Q7b "$([[ "$r" == "aurora-r aurora, aurora-w aurora" ]] && echo 1 || echo 0)" "instances: $r"
  AW=$(q "select instance_id from pgvigil.instances where name = 'aurora-w'"); AR=$(q "select instance_id from pgvigil.instances where name = 'aurora-r'")
  rd aurora-w 2
  r=$(q "select count(*) filter (where state = 'MASTER_SESSION_ID') || '|' || count(*) filter (where key = '$R' and lag_secs is not null) || '|' || coalesce(max(lag_secs) filter (where key = '$R'), -1) from pgvigil.replication_latest where instance_id = $AW and kind = 'aurora_replica'")
  chk Q7c "$([[ "$r" == 1\|1\|* ]] && echo 1 || echo 0)" "aurora-w's aurora_replica rows: the writer's own 1, the reader's 1, its lag ${r##*|} s ($r)"
  rd aurora-r 2
  r=$(q "select coalesce(in_recovery::text, 'null') || '|' || coalesce(has_receiver::text, 'null') from pgvigil.pg_repl_standby_state where instance_id = $AR")
  r2=$(q "select count(*) from pgvigil.findings where instance_id = $AR and setting = 'receiver down'")
  r3=$(q "select count(*) from pgvigil.pg_repl_link_health where standby_id = $AR")
  chk Q7d "$([[ "$r" == true\|* && "$r2" == "0" && "$r3" == "0" ]] && echo 1 || echo 0)" "aurora-r in recovery (in_recovery|has_receiver: $r), 'receiver down' $r2, link rows $r3"
  r=$(q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"set\",\"key\":\"standby_replay_lag\",\"level\":\"instance\",\"instance_id\":$AW,\"warn\":0,\"crit\":300,\"ui_user\":\"proof\"}'::jsonb)->>'outcome'")
  [[ "$r" == "done" ]] || fail "$PASS: Q7e the threshold was not set: '$r'"
  rd aurora-w 1; rd aurora-r 1
  r=$(q "select string_agg(severity || ' ' || value, '; ' order by value) from pgvigil.findings where instance_id = $AW and setting = 'Aurora replica lag'")
  chk Q7e-writer "$([[ "$r" == "warning replica $R:"* && "$r" != *"replica $W:"* ]] && echo 1 || echo 0)" "'Aurora replica lag' on aurora-w names the reader, not the writer's own row: ${r:-none}"
  r=$(q "select count(*) from pgvigil.findings where instance_id = $AR and setting = 'Aurora replica lag'")
  chk Q7e-reader "$([[ "$r" == "0" ]] && echo 1 || echo 0)" "'Aurora replica lag' raised on aurora-r: $r"
  q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"inherit\",\"key\":\"standby_replay_lag\",\"level\":\"instance\",\"instance_id\":$AW,\"ui_user\":\"proof\"}'::jsonb)" >/dev/null
}

run_pass green "$PGVIGIL_BIN" pgvigil_q7
if [[ -n "${PGVIGIL_RED_BIN:-}" ]]; then
  run_pass red "$PGVIGIL_RED_BIN" pgvigil_q7red
  (( REDMISS == 0 )) && echo "red: as marked" || { echo "red: $REDMISS difference(s) from the marks"; FAILS=$((FAILS + REDMISS)); }
fi

cleanup_out=$(cleanup 2>&1); trap - EXIT; echo "$cleanup_out"
FAILS=$((FAILS + $(grep -c '^FAIL end' <<<"$cleanup_out")))
if (( FAILS == 0 )); then echo "proof-pg-aurora: OK"; exit 0; fi
echo "proof-pg-aurora: $FAILS FAIL"; exit 1
