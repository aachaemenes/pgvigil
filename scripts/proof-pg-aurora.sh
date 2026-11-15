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
#   PGVIGIL_AURORA_CREATE        1 = this script creates the reader (db.serverless, promotion tier 15, tagged
#                                pgvigil-proof = this run's id) and DELETES it on every exit, then reads back that it is
#                                gone; unset = the reader must exist and stays
# The IAM tokens (aws rds generate-db-auth-token, 15 minutes) live only in this process's environment: pgvigil reads
# its DSNs through 'env:' (config.Resolve), the config file names the variables only, psql gets PGPASSWORD per call;
# nothing prints a token or a DSN. An aws error line is printed with any 12-digit account id masked.
#
# Expected (written before the first run, 2026-11-14 13:5x PST; the review fold 17:2x). A 'read' is one
# `pgvigil collect -once replication` of one instance; aurora-w is the writer instance's endpoint, aurora-r the
# reader's; each pass has its own repository database on the writer (pgvigil_q7 green, pgvigil_q7red red), made here
# and dropped at the end:
#   Q7a  the reader available; the writer and the reader answer through IAM (the first query after an auto-pause waits
#        about 15 s: polled for about 2 minutes); the reader in recovery; the writer's roles read (the end drops only
#        pgvigil_* roles absent from that list; no list = no run)
#   Q7a-probe (info, not graded; review 21:27 #2) each function the Aurora 'standby' read leaves out, called on the
#        reader as the IAM login (read only): pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
#        pg_last_xact_replay_timestamp(), pg_is_wal_replay_paused(), pg_stat_wal_receiver - its answer or its ERROR line
#        printed (which calls Aurora rejects: no AWS page says)
#   Q7b  'collect -once instance': pgvigil.instances holds aurora-r and aurora-w, both platform aurora
#   Q7c  two reads of aurora-w: its aurora_replica rows hold the writer's own row (session_id MASTER_SESSION_ID) once
#        and a row for the reader (server_id = PGVIGIL_AURORA_READER) with its lag in seconds
#   Q7d  two reads of aurora-r: its standby state in recovery (whether Aurora shows a WAL receiver is printed, not
#        judged); no 'receiver down' on aurora-r; no link row for aurora-r (pg_repl_link_health)
#   Q7e  'standby_replay_lag' set on aurora-w AND aurora-r to warning 0 s / critical 300 s (a real reader lags
#        milliseconds; the default 30 s would hide the rule), one read of each:
#        Q7e-pre     aurora-r's own aurora_replica_status rows hold a replica row with a lag (the rule's input there:
#                    with warning 0 a 0 on aurora-r can come from the in-recovery exclusion alone)
#        Q7e-writer  'Aurora replica lag' warning on aurora-w naming the reader, none for the writer's own row
#        Q7e-reader  none raised on aurora-r (the reader is in recovery)
#        Q7f         aurora-w made inactive in the pass's repository (a stand-in for no monitored writer: only the
#                    reader endpoint configured, or the writer's read failing): 'Aurora replica lag' warning on aurora-r
#                    naming the reader (review 21:27 #1: the reader raises when no fresh writer reads the replica);
#                    aurora-w active again after [red ok: 86c4079 stores no state for the reader, so it raises anyway]
#        Q7e-reset   the threshold inherited again on both (outcome done)
#   Q7i  (info, not graded; review 21:27, outside this task's files) one 'rolechange', 'backups' and 'dbstats' read of
#        aurora-r: whether those collectors fail on a real reader (they call pg_stat_wal_receiver or the WAL position
#        functions); each read's exit printed, its error in the print below
#   Q7d-read aurora-r's replication read 'ok' (the collector's 'standby' read on an Aurora reader); every read of the
#        pass that did not succeed is printed with its error from collection_log (every read, not only the newest of a
#        collection: review 21:27 #3), host names masked. A failed repository query is 'not read' for Q7d and Q7d-read,
#        never their marked failure (review 21:27 #4)
#   red  PGVIGIL_RED_BIN = the tree before the Aurora 'standby' read (86c4079; the first lab run, 18:21 PST, red ece715d,
#        found Q7d failing on both trees: no standby state stored for the real reader): every row as above but Q7d,
#        Q7d-read and Q7e-reader [red FAIL: the 'standby' read raises on the reader - no state, so no reader exclusion;
#        Q7e-reader's mark is a count of 1 or more read, a failed read or a row never run is a difference]; the run
#        reports 'red: as marked' or each difference
#   end  the delete of the reader sent FIRST (with PGVIGIL_AURORA_CREATE=1; a refusal waits for 'available' and tries
#        again, 3 times, then prints the command to run by hand; never when the reader has become the cluster's
#        writer - printed, by hand); then the repository databases dropped and the pgvigil_* roles absent before the
#        run dropped, both read back absent; then the deletion awaited and read back: the cluster's members without the
#        reader, describe-db-instances answering DBInstanceNotFound. A stop during the create deletes the reader only
#        when it carries this run's tag. A stop during the end is ignored (the end must send the delete).
# Not proven here: a real replica lag past 30 s (it cannot be made on purpose on Aurora); 'Aurora replica lag'
# critical; a cluster with several readers.
# Prints 'ok' / 'FAIL' per assertion and 'proof-pg-aurora: OK' or 'proof-pg-aurora: <n> FAIL'; exit 0 only when the
# green pass passed, the red pass (when run) failed exactly as marked, and the end's removals and read-backs held.
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
RUNID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
WORK=$(mktemp -d); CREATING=0; CREATED=0; CLEANED=0; ENDFAILS=0; DBS=""; ROLES0=""; W=""; WH=""; RH=""
mask() { sed -E 's/[0-9]{12}/<account>/g'; }   # an ARN in an aws error carries the account id
maskh() { mask | { if [[ -n "$WH" && -n "$RH" ]]; then sed -e "s/$WH/<writer>/g" -e "s/$RH/<reader>/g"; else cat; fi; }; }   # and the endpoints
endfail() { echo "FAIL end: $*"; ENDFAILS=$((ENDFAILS + 1)); }
member_ids() { aws rds describe-db-clusters --db-cluster-identifier "$C" --query 'DBClusters[0].DBClusterMembers[].DBInstanceIdentifier' --output text 2>/dev/null | tr '\t' ' '; }
writer_id() { aws rds describe-db-clusters --db-cluster-identifier "$C" --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier' --output text 2>/dev/null; }
endpoint() { aws rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null; }
tok() { aws rds generate-db-auth-token --hostname "$1" --port 5432 --username "$U"; }
psqlh() { # psqlh <host> <database> <sql>: one statement as the IAM login, the token in psql's environment only
  local t; t=$(tok "$1") || return 1
  PGPASSWORD=$t PGCONNECT_TIMEOUT=20 psql "host=$1 port=5432 user=$U dbname=$2 sslmode=require" -XAtq -v ON_ERROR_STOP=1 -c "$3"
}
q() { local o; o=$(psqlh "$WH" "$DB" "$1" 2>"$WORK/q.err") && { [[ -n "$o" ]] && printf '%s\n' "$o"; return 0; }; echo "QUERY FAILED: $(tail -1 "$WORK/q.err")"; return 1; }
wake() { local end=$((SECONDS + 120)); while (( SECONDS < end )); do psqlh "$1" postgres 'select 1' >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
new_roles() { # the writer's pgvigil_* roles absent from the list read before the run, one per line; a failed read = 1
  local o r; o=$(psqlh "$WH" postgres "select rolname from pg_roles where rolname like 'pgvigil\_%' order by 1" 2>/dev/null) || return 1
  while IFS= read -r r; do [[ -n "$r" ]] && ! grep -qxF -- "$r" "$WORK/roles0" && printf '%s\n' "$r"; done <<<"$o"
  return 0
}
del_reader() { # delete-db-instance; a refusal waits for 'available' and tries again (3 times); 0 = sent, or gone already
  local i
  for i in 1 2 3; do
    aws rds delete-db-instance --db-instance-identifier "$R" >/dev/null 2>"$WORK/del.err" && return 0
    grep -q DBInstanceNotFound "$WORK/del.err" && return 0
    echo "  delete-db-instance refused ($(tail -1 "$WORK/del.err" | mask)); waiting for the reader to be available, then again ($i of 3)"
    aws rds wait db-instance-available --db-instance-identifier "$R" >/dev/null 2>&1
  done
  return 1
}

cleanup() {
  (( CLEANED )) && return 0
  CLEANED=1
  trap '' INT TERM HUP   # a stop during the end is ignored: the delete is sent first and must be
  set +e
  local sent=0 t wr d r n m g left inlist
  if (( CREATING && ! CREATED )); then   # stopped during the create, or the create failed: only a reader with this run's tag
    t=$(aws rds describe-db-instances --db-instance-identifier "$R" --query "DBInstances[0].TagList[?Key=='pgvigil-proof'].Value" --output text 2>/dev/null)
    if [[ "$t" == "$RUNID" ]]; then CREATED=1; echo "  the reader exists with this run's tag: it is deleted"
    else echo "  no reader with this run's tag found; if the create was sent, check by hand: aws rds describe-db-instances --db-instance-identifier $R"; fi
  fi
  if (( CREATED )); then
    wr=$(writer_id)
    if [[ "$wr" == "$R" ]]; then
      endfail "the reader $R is now the cluster's WRITER (a failover during the run): NOT deleted; by hand: aws rds failover-db-cluster --db-cluster-identifier $C --target-db-instance-identifier $W, then aws rds delete-db-instance --db-instance-identifier $R"
    elif del_reader; then sent=1; echo "  delete-db-instance sent for the reader (created by this run) at $(date -u '+%H:%M:%S') UTC"
    else endfail "delete-db-instance refused 3 times ($(tail -1 "$WORK/del.err" | mask)); by hand: aws rds delete-db-instance --db-instance-identifier $R --profile $AWS_PROFILE --region $AWS_REGION"; fi
  fi
  if [[ -n "$DBS$ROLES0" && -n "$WH" ]]; then
    if wake "$WH"; then
      for d in $DBS; do psqlh "$WH" postgres "drop database if exists $d with (force)" >/dev/null 2>&1 && echo "  dropped database $d" || endfail "database $d not dropped"; done
      if [[ -n "$ROLES0" ]]; then
        if left=$(new_roles); then
          while IFS= read -r r; do
            [[ -n "$r" ]] || continue
            [[ "$r" =~ ^pgvigil_[a-z0-9_]+$ ]] || { endfail "role $r (absent before the run) has a name outside pgvigil_[a-z0-9_]: not dropped"; continue; }
            psqlh "$WH" postgres "drop role \"$r\"" >/dev/null 2>&1 && echo "  dropped role $r (made by this run)" || endfail "role $r (made by this run) not dropped"
          done <<<"$left"
        else endfail "the writer's roles were not listed: this run's roles NOT dropped"; fi
      fi
      if [[ -n "$DBS" ]]; then
        inlist=""; for d in $DBS; do inlist+="${inlist:+,}'$d'"; done
        n=$(psqlh "$WH" postgres "select count(*) from pg_database where datname in ($inlist)" 2>/dev/null)
        [[ "$n" == "0" ]] && ok "end: the databases [$DBS ] read back absent" || endfail "the databases [$DBS ] read back: ${n:-not read}"
      fi
      if [[ -n "$ROLES0" ]]; then
        left=$(new_roles) && [[ -z "$left" ]] && ok "end: no pgvigil_* role made by this run is left" || endfail "roles made by this run left: [${left//$'\n'/ }] (empty = not read)"
      fi
    else endfail "the writer did not answer in about 2 minutes: databases [$DBS ] and this run's roles NOT dropped"; fi
  fi
  if (( sent )); then
    echo "  waiting for the deletion (the aws waiter: up to 30 minutes)"
    aws rds wait db-instance-deleted --db-instance-identifier "$R" 2>/dev/null || endfail "the wait for the deletion ended early"
    m=$(member_ids); g=$(aws rds describe-db-instances --db-instance-identifier "$R" 2>&1 >/dev/null | grep -o DBInstanceNotFound | head -1)
    echo "  read-back $(date -u '+%H:%M:%S') UTC: cluster members [$m]; describe-db-instances of the reader: ${g:-still found}"
    [[ -n "$m" && " $m " != *" $R "* && "$g" == "DBInstanceNotFound" ]] && ok "end: the reader is gone" || endfail "the reader is NOT gone"
  fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP   # a stop is an exit: the EXIT trap deletes what this run made

# ---- the writer and the reader ----------------------------------------------------------------------------------------
W=$(writer_id)
[[ -n "$W" && "$W" != "None" ]] || { echo "proof-pg-aurora: refused - no writer found in the cluster"; exit 2; }
[[ "$W" != "$R" ]] || { echo "proof-pg-aurora: refused - PGVIGIL_AURORA_READER names the writer"; exit 2; }
WH=$(endpoint "$W")
[[ -n "$WH" && "$WH" != "None" ]] || { echo "proof-pg-aurora: refused - no endpoint read for the writer"; exit 2; }
if [[ "${PGVIGIL_AURORA_CREATE:-}" == "1" ]]; then
  aws rds describe-db-instances --db-instance-identifier "$R" >/dev/null 2>"$WORK/pre.err" \
    && { echo "proof-pg-aurora: refused - $R exists already (this script deletes only a reader it created)"; exit 2; }
  grep -q DBInstanceNotFound "$WORK/pre.err" || { echo "proof-pg-aurora: refused - the reader's absence was not read: $(tail -1 "$WORK/pre.err" | mask)"; exit 2; }
  ENG=$(aws rds describe-db-clusters --db-cluster-identifier "$C" --query 'DBClusters[0].Engine' --output text)
  CREATING=1
  if aws rds create-db-instance --db-instance-identifier "$R" --db-cluster-identifier "$C" --engine "$ENG" \
       --db-instance-class db.serverless --promotion-tier 15 --tags "Key=pgvigil-proof,Value=$RUNID" >/dev/null 2>"$WORK/create.err"; then
    CREATED=1; echo "  the reader created at $(date -u '+%H:%M:%S') UTC (tag pgvigil-proof=$RUNID); waiting for it to be available"
  else
    fail "Q7a the reader was not created: $(tail -1 "$WORK/create.err" | mask)"; exit 3
  fi
  aws rds wait db-instance-available --db-instance-identifier "$R" || { fail "Q7a the reader did not become available"; exit 1; }
else
  [[ " $(member_ids) " == *" $R "* ]] || { echo "proof-pg-aurora: refused - $R is not a member of the cluster (set PGVIGIL_AURORA_CREATE=1 to make it)"; exit 2; }
fi
RH=$(endpoint "$R")
[[ -n "$RH" && "$RH" != "None" ]] || { fail "Q7a no endpoint read for the reader"; exit 1; }
wake "$WH" && wake "$RH" && ok "Q7a the reader available; the writer and the reader answer through IAM" || { fail "Q7a an instance did not answer through IAM in about 2 minutes"; exit 1; }
[[ "$(psqlh "$RH" postgres 'select pg_is_in_recovery()')" == "t" ]] || { fail "Q7a the reader is not in recovery"; exit 1; }
for f in 'pg_last_wal_receive_lsn()' 'pg_last_wal_replay_lsn()' 'pg_last_xact_replay_timestamp()' 'pg_is_wal_replay_paused()' '(select count(*) from pg_stat_wal_receiver)'; do
  o=$(psqlh "$RH" postgres "select $f" 2>&1); e=$(grep -m1 ERROR <<<"$o")
  echo "  Q7a-probe on the reader: select $f -> $(printf '%s' "${e:-answered: ${o:-null}}" | maskh)"
done
psqlh "$WH" postgres "select rolname from pg_roles order by 1" >"$WORK/roles0" 2>/dev/null && [[ -s "$WORK/roles0" ]] \
  || { fail "Q7a the writer's roles were not read (the end drops only pgvigil_* roles absent from that list)"; exit 1; }
ROLES0=1

# ---- one pass: a binary, its own repository database ---------------------------------------------------------------------
dsn() { echo "host=$1 port=5432 user=$U dbname=$2 sslmode=require password='$(tok "$1")'"; }
refresh() { Q7_REPO_DSN=$(dsn "$WH" "$DB"); Q7_W_DSN=$(dsn "$WH" postgres); Q7_R_DSN=$(dsn "$RH" postgres); export Q7_REPO_DSN Q7_W_DSN Q7_R_DSN; }
zero() { [[ "$1" == "0" ]] && echo 1 || { [[ "$1" =~ ^[1-9][0-9]*$ ]] && echo 0 || echo x; }; }   # a count: 1 = none, 0 = some, x = not read
PASS=""; RAN=""; RED_EXPECT=" Q7d Q7d-read Q7e-reader "; REDMISS=0
chk() { # chk <id> <1 = held | 0 = did not hold | x = not read> <message>: a green row counts; a red row is graded against RED_EXPECT
  RAN+=" $1 "
  if [[ "$PASS" == green ]]; then [[ "$2" == 1 ]] && ok "$1 $3" || fail "$1 $3"
  elif [[ "$RED_EXPECT" == *" $1 "* ]]; then
    case $2 in
      0) echo "ok   red $1 failed as marked: $3" ;;
      1) echo "FAIL red $1 passed on the red tree: $3"; REDMISS=$((REDMISS + 1)) ;;
      *) echo "FAIL red $1 not read (a failed read is not the marked failure): $3"; REDMISS=$((REDMISS + 1)) ;;
    esac
  else [[ "$2" == 1 ]] && echo "ok   red $1 $3" || { echo "FAIL red $1 (not marked to fail): $3"; REDMISS=$((REDMISS + 1)); }; fi
}
run_pass() { # run_pass <green|red> <binary> <database>
  PASS=$1; BIN=$2; DB=$3; RAN=""
  psqlh "$WH" postgres "select 1 from pg_database where datname = '$DB'" | grep -q 1 && { fail "$PASS: database $DB exists already (never dropped by this run)"; return; }
  DBS+=" $DB"   # before the create: a stop between the two still drops it (absent a line above)
  psqlh "$WH" postgres "create database $DB" >/dev/null || { fail "$PASS: database $DB not created"; return; }
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
  thr() { q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"$1\",\"key\":\"standby_replay_lag\",\"level\":\"instance\",\"instance_id\":$2$3,\"ui_user\":\"proof\"}'::jsonb)->>'outcome'"; }
  r=$(q "select string_agg(name || ' ' || platform, ', ' order by name) from pgvigil.instances")
  chk Q7b "$([[ "$r" == "aurora-r aurora, aurora-w aurora" ]] && echo 1 || echo 0)" "instances: $r"
  AW=$(q "select instance_id from pgvigil.instances where name = 'aurora-w'"); AR=$(q "select instance_id from pgvigil.instances where name = 'aurora-r'")
  [[ "$AW" =~ ^[0-9]+$ && "$AR" =~ ^[0-9]+$ ]] || { fail "$PASS: the instance ids were not read (aurora-w '$AW', aurora-r '$AR')"; return; }
  rd aurora-w 2
  r=$(q "select count(*) filter (where state = 'MASTER_SESSION_ID') || '|' || count(*) filter (where key = '$R' and lag_secs is not null) || '|' || coalesce(max(lag_secs) filter (where key = '$R'), -1) from pgvigil.replication_latest where instance_id = $AW and kind = 'aurora_replica'")
  chk Q7c "$([[ "$r" == 1\|1\|* ]] && echo 1 || echo 0)" "aurora-w's aurora_replica rows: the writer's own 1, the reader's 1, its lag ${r##*|} s ($r)"
  rd aurora-r 2
  r=$(q "select coalesce(in_recovery::text, 'null') || '|' || coalesce(has_receiver::text, 'null') from pgvigil.pg_repl_standby_state where instance_id = $AR")
  r2=$(q "select count(*) from pgvigil.findings where instance_id = $AR and setting = 'receiver down'")
  r3=$(q "select count(*) from pgvigil.pg_repl_link_health where standby_id = $AR")
  chk Q7d "$(if [[ "$r$r2$r3" == *"QUERY FAILED"* ]]; then echo x; elif [[ "$r" == true\|* && "$r2" == "0" && "$r3" == "0" ]]; then echo 1; else echo 0; fi)" "aurora-r in recovery (in_recovery|has_receiver: $r), 'receiver down' $r2, link rows $r3"
  r=$(q "select d.status || coalesce(': ' || d.note, '') from pgvigil.collection_dates d where d.instance_id = $AR and d.collection = 'replication' order by d.snapshot_at desc limit 1")
  chk Q7d-read "$(case "$r" in ok*) echo 1 ;; partial*|error*) echo 0 ;; *) echo x ;; esac)" "aurora-r's replication read: $(printf '%s' "${r:-none}" | maskh)"
  r=$(thr set "$AW" ',"warn":0,"crit":300'); r2=$(thr set "$AR" ',"warn":0,"crit":300')
  [[ "$r|$r2" == "done|done" ]] || fail "$PASS: Q7e the thresholds were not set: aurora-w '$r', aurora-r '$r2'"
  rd aurora-w 1; rd aurora-r 1
  r=$(q "select count(*) from pgvigil.replication_latest where instance_id = $AR and kind = 'aurora_replica' and coalesce(state, '') <> 'MASTER_SESSION_ID' and lag_secs is not null and snapshot_at > now() - interval '30 minutes'")
  chk Q7e-pre "$([[ "$r" =~ ^[1-9][0-9]*$ ]] && echo 1 || echo 0)" "aurora-r's own aurora_replica_status rows: replica rows with a lag $r (with warning 0 a 0 below comes from the in-recovery rule alone)"
  r=$(q "select string_agg(severity || ' ' || value, '; ' order by value) from pgvigil.findings where instance_id = $AW and setting = 'Aurora replica lag'")
  chk Q7e-writer "$([[ "$r" == "warning replica $R:"* && "$r" != *"replica $W:"* ]] && echo 1 || echo 0)" "'Aurora replica lag' on aurora-w names the reader, not the writer's own row: ${r:-none}"
  r=$(q "select count(*) from pgvigil.findings where instance_id = $AR and setting = 'Aurora replica lag'")
  chk Q7e-reader "$(zero "$r")" "'Aurora replica lag' raised on aurora-r: $r"
  q "update pgvigil.instances set is_active = false where instance_id = $AW" >/dev/null
  r=$(q "select string_agg(severity || ' ' || value, '; ' order by value) from pgvigil.findings where instance_id = $AR and setting = 'Aurora replica lag'")
  q "update pgvigil.instances set is_active = true where instance_id = $AW" >/dev/null
  chk Q7f "$(if [[ "$r" == *"QUERY FAILED"* ]]; then echo x; elif [[ "$r" == *"replica $R:"* && "$r" != *"replica $W:"* ]]; then echo 1; else echo 0; fi)" "no monitored writer (aurora-w inactive): 'Aurora replica lag' on aurora-r: ${r:-none}"
  for c in rolechange backups dbstats; do   # Q7i, info: the other collectors that read recovery state, on the real reader
    refresh; "$BIN" collect -config "$CFG" -once "$c" -instance aurora-r >>"$WORK/$DB-collect.out" 2>&1; echo "  $PASS: Q7i (info) a '$c' read of aurora-r exit $?"
  done
  # every read that did not succeed, with the collector's error (the evidence a failed read leaves; the first lab run
  # lost it): collection_log keeps each one, collection_dates only the newest of a collection
  echo "  $PASS: the reads that did not succeed: $(q "select coalesce(string_agg(i.name || ' ' || l.collection || ' ' || to_char(l.snapshot_at at time zone 'UTC', 'HH24:MI:SS') || ' ' || l.status || ': ' || coalesce(l.note, ''), '; ' order by l.snapshot_at, i.name), 'none')
                                                    from pgvigil.collection_log l join pgvigil.instances i using (instance_id) where l.status <> 'ok'" | maskh)"
  r=$(thr inherit "$AW" ""); r2=$(thr inherit "$AR" "")
  chk Q7e-reset "$([[ "$r|$r2" == "done|done" ]] && echo 1 || echo 0)" "the threshold inherited again: aurora-w $r, aurora-r $r2"
}

run_pass green "$PGVIGIL_BIN" pgvigil_q7
if [[ -n "${PGVIGIL_RED_BIN:-}" ]]; then
  run_pass red "$PGVIGIL_RED_BIN" pgvigil_q7red
  for id in $RED_EXPECT; do [[ "$RAN" == *" $id "* ]] || { echo "FAIL red $id never ran (a marked row must run to fail as marked)"; REDMISS=$((REDMISS + 1)); }; done
  (( REDMISS == 0 )) && echo "red: as marked" || { echo "red: $REDMISS difference(s) from the marks"; FAILS=$((FAILS + REDMISS)); }
fi

cleanup; trap - EXIT
FAILS=$((FAILS + ENDFAILS))
if (( FAILS == 0 )); then echo "proof-pg-aurora: OK"; exit 0; fi
echo "proof-pg-aurora: $FAILS FAIL"; exit 1
