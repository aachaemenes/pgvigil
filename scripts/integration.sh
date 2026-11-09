#!/usr/bin/env bash
# Integration check for the instance collection, run by CI and by hand against a
# throwaway PostgreSQL (never a production server: it runs ALTER SYSTEM).
#
#   PGVIGIL_REPO_DSN   repository connection (superuser or owner; the schema is created here)
#   ADMIN_DSN          superuser connection to the monitored server (creates the pg_monitor login,
#                      changes a server setting with ALTER SYSTEM, resets it, drops the login)
#   PGVIGIL_BIN        path to the pgvigil binary (default bin/pgvigil)
#
# Expected: migrate applies the schema; a pg_monitor-only login collects three times;
# a server-level setting change shows as exactly one history row, its reset as one more;
# the collector's own session settings never appear in non_default_settings.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
ROLE=pgvigil_it
PASS=pgvigil_it_$RANDOM$RANDOM
# keyword form: an IPv6 address such as ::1 needs no brackets here, unlike a URL
HOSTADDR=$(psql "$ADMIN_DSN" -XAt -c "select coalesce(host(inet_server_addr()),'localhost')")
PORT=$(psql "$ADMIN_DSN" -XAt -c "select inet_server_port()")
DBNAME=$(psql "$ADMIN_DSN" -XAt -c 'select current_database()')
TARGET_DSN="host=$HOSTADDR port=$PORT user=$ROLE password=$PASS dbname=$DBNAME sslmode=disable"
CFG=$(mktemp)
trap 'rm -f "$CFG"; psql "$ADMIN_DSN" -XAtq -c "alter system reset work_mem" -c "select pg_reload_conf()" -c "drop role if exists $ROLE" >/dev/null 2>&1 || true' EXIT

INST="it-target-$RANDOM"   # a fresh instance name per run, so the first snapshot is a first sight on a reused repository
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $INST
    dsn: env:IT_TARGET_DSN
    tags: [it]
EOF
export IT_TARGET_DSN="$TARGET_DSN"

fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }

psql "$ADMIN_DSN" -XAtq -c "drop role if exists $ROLE" -c "create role $ROLE login password '$PASS' in role pg_monitor" >/dev/null
psql "$ADMIN_DSN" -XAtq -c "alter system reset work_mem" -c "select pg_reload_conf()" >/dev/null

"$BIN" migrate -config "$CFG"
"$BIN" migrate -config "$CFG"                       # second run: nothing to apply, no error
"$BIN" collect -config "$CFG" -once instance

iid=$(q "select instance_id from pgvigil.instances where name='$INST'")
[ -n "$iid" ] || fail "no instance row"
[ "$(q "select count(*) from pgvigil.instance_setting_history where instance_id=$iid")" = "0" ] || fail "history rows after the first snapshot"
for own in statement_timeout lock_timeout default_transaction_read_only application_name; do
  [ "$(q "select count(*) from pgvigil.instance_state, jsonb_array_elements(non_default_settings) e where instance_id=$iid and e->>'name'='$own'")" = "0" ] \
    || fail "collector's own session setting $own recorded as instance configuration"
done

psql "$ADMIN_DSN" -XAtq -c "alter system set work_mem = '7MB'" -c "select pg_reload_conf()" >/dev/null
sleep 1
"$BIN" collect -config "$CFG" -once instance
[ "$(q "select count(*) from pgvigil.instance_setting_history where instance_id=$iid and name='work_mem' and old_value is null and new_value='7168'")" = "1" ] \
  || fail "expected one history row work_mem NULL -> 7168, got: $(q "select name, old_value, new_value from pgvigil.instance_setting_history where instance_id=$iid")"

psql "$ADMIN_DSN" -XAtq -c "alter system reset work_mem" -c "select pg_reload_conf()" >/dev/null
sleep 1
"$BIN" collect -config "$CFG" -once instance
[ "$(q "select count(*) from pgvigil.instance_setting_history where instance_id=$iid and name='work_mem' and old_value='7168' and new_value is null")" = "1" ] \
  || fail "expected one history row work_mem 7168 -> NULL"
[ "$(q "select count(*) from pgvigil.instance_setting_history where instance_id=$iid")" = "2" ] || fail "more history rows than the two expected"

# failure paths exit 1 before any work
! "$BIN" collect -config "$CFG" -once nosuch >/dev/null 2>&1 || fail "unknown collection exited 0"
! "$BIN" collect -config "$CFG" -once instance -instance nosuch >/dev/null 2>&1 || fail "unknown instance exited 0"

echo "integration: OK (instance $iid, 3 snapshots, 2 history rows, pg_monitor login only)"
