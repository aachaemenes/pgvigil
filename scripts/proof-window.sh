#!/usr/bin/env bash
# Proof of the window read of long runs and idle transactions (pgvigil.long_runs_in_window, 0048) on a
# throwaway PostgreSQL: one session sits idle in a transaction and one runs pg_sleep while the activity
# collection samples twice, 65 s apart; the function is then read with each filter. Never run against a
# shared server.
#
#   PGVIGIL_REPO_DSN  repository (schema created if missing)
#   ADMIN_DSN         superuser connection to the monitored server (also the target here)
#   PGVIGIL_BIN       path to the binary (default bin/pgvigil)
#
# Expected (min 60 s over the window, the whole run about 70 s):
#   state 'idle'   -> 1 row: the holder, state 'idle in transaction', at_least_secs >= 65 (its idle time), txn_secs >= at_least_secs
#   state 'active' -> 1 row: the sleeper, query naming pg_sleep, at_least_secs >= 65
#   no state       -> 2 rows; application 'psql' -> 2 rows; database 'pgvigil_no_such_db' -> 0 rows; user = the login -> 2 rows
#   slow_in_window(min 60) unchanged -> 2 rows
#   activity_summary: 2 samples in the window, each with idle_in_txn >= 1 and active >= 1
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
CFG=$(mktemp); FIFO=$(mktemp -u)
cleanup() { rm -f "$CFG"; for p in "${HOLDER:-}" "${SLEEPER:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -f "$FIFO"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }

cat > "$CFG" <<EOT
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-window
    dsn: env:ADMIN_DSN
EOT
"$BIN" migrate -config "$CFG" >/dev/null
login=$(psql "$ADMIN_DSN" -XAt -c "select current_user")

# the holder: a transaction opened, one statement run, then idle (psql waits on its stdin)
mkfifo "$FIFO"
psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 < "$FIFO" >/dev/null 2>&1 &
HOLDER=$!
exec 3>"$FIFO"
printf 'BEGIN;\nSELECT 1 AS pgvigil_proof_window_holder;\n' >&3
# the sleeper: one active statement for the whole proof
psql "$ADMIN_DSN" -XAtq -c "select pg_sleep(100) /* pgvigil_proof_window_sleeper */" >/dev/null 2>&1 &
SLEEPER=$!
sleep 2
from=$(q "select now() - interval '1 minute'")
"$BIN" collect -config "$CFG" -once activity
sleep 65
"$BIN" collect -config "$CFG" -once activity
to=$(q "select now() + interval '1 minute'")

iid=$(q "select instance_id from pgvigil.instances where name='proof-window'")
f="pgvigil.long_runs_in_window($iid, '$from', '$to', 60"
idle=$(q "select count(*) || '|' || coalesce(min(state),'?') || '|' || coalesce(min(at_least_secs),0) || '|' || coalesce(min(txn_secs),0) || '|' || coalesce(bool_and(query ilike '%pgvigil_proof_window_holder%'),false) from $f, 'idle')")
active=$(q "select count(*) || '|' || coalesce(min(state),'?') || '|' || coalesce(min(at_least_secs),0) || '|' || coalesce(bool_and(query ilike '%pg_sleep%'),false) from $f, 'active')")
both=$(q "select count(*) from $f)")
byapp=$(q "select count(*) from $f, null, null, null, 'psql')")
bydb=$(q "select count(*) from $f, null, null, 'pgvigil_no_such_db')")
byuser=$(q "select count(*) from $f, null, '$login')")
old=$(q "select count(*) from pgvigil.slow_in_window($iid, '$from', '$to', 60)")
summ=$(q "select count(*) || '|' || coalesce(min(idle_in_txn),0) || '|' || coalesce(min(active),0) from pgvigil.activity_summary where instance_id=$iid and snapshot_at between '$from' and '$to'")
echo "idle(count|state|at_least|txn|holder)=$idle active(count|state|at_least|sleeper)=$active both=$both app=$byapp db=$bydb user=$byuser slow_in_window=$old summary(samples|min idle_in_txn|min active)=$summ"
IFS='|' read -r n st secs txn ok <<< "$idle"
[ "$n" = "1" ] && [ "$st" = "idle in transaction" ] && [ "$secs" -ge 65 ] && [ "$txn" -ge "$secs" ] && [ "$ok" = "true" ] || fail "idle filter: $idle"
IFS='|' read -r n st secs ok <<< "$active"
[ "$n" = "1" ] && [ "$st" = "active" ] && [ "$secs" -ge 65 ] && [ "$ok" = "true" ] || fail "active filter: $active"
[ "$both" = "2" ] || fail "no state filter: $both rows, expected 2"
[ "$byapp" = "2" ] || fail "application filter: $byapp rows, expected 2"
[ "$bydb" = "0" ] || fail "database filter: $bydb rows, expected 0"
[ "$byuser" = "2" ] || fail "user filter: $byuser rows, expected 2"
[ "$old" = "2" ] || fail "slow_in_window: $old rows, expected 2"
IFS='|' read -r n i a <<< "$summ"
[ "$n" = "2" ] && [ "$i" -ge 1 ] && [ "$a" -ge 1 ] || fail "summary: $summ"
printf 'ROLLBACK;\n' >&3; exec 3>&-
echo "proof-window: OK"
