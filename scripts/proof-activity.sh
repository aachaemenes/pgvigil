#!/usr/bin/env bash
# Proof of the activity collection on a throwaway PostgreSQL: seeds a lock chain
# (one idle-in-transaction holder, two Lock waiters), collects once, and checks the
# snapshot, the summary and pgvigil.blocking_chains. Never run against a shared server.
#
#   PGVIGIL_REPO_DSN  repository (schema created if missing)
#   ADMIN_DSN         superuser connection to the monitored server (also the target here)
#   PGVIGIL_BIN       path to the binary (default bin/pgvigil)
#
# Expected: 3 session rows (1 'idle in transaction' holder, 2 'active' Lock waiters whose
# blocking_pids contain the holder); summary waiting_lock = 2, idle_in_txn >= 1;
# blocking_chains returns 2 rows, both with head_pid = the holder and depth 1.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
CFG=$(mktemp); FIFO=$(mktemp -u)
# every step tolerates an already-gone process: under set -e a failing kill would end the trap early
cleanup() { rm -f "$CFG"; for p in "${HOLDER:-}" "${W1:-}" "${W2:-}" "${W3:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -f "$FIFO"; psql "$ADMIN_DSN" -XAtq -c "drop table if exists pgvigil_proof_t" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-activity
    dsn: env:ADMIN_DSN
EOF

psql "$ADMIN_DSN" -XAtq -c "drop table if exists pgvigil_proof_t" -c "create table pgvigil_proof_t (id int)" >/dev/null
"$BIN" migrate -config "$CFG" >/dev/null

# holder: open a transaction, take the lock, then sit idle (psql waits on its stdin)
mkfifo "$FIFO"
psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 < "$FIFO" >/dev/null 2>&1 &
HOLDER=$!
exec 3>"$FIFO"
printf 'BEGIN;\nLOCK TABLE pgvigil_proof_t IN ACCESS EXCLUSIVE MODE;\nSELECT pg_sleep(0.2);\n' >&3
sleep 1
# two waiters
psql "$ADMIN_DSN" -XAtq -c "select count(*) from pgvigil_proof_t" >/dev/null 2>&1 &
W1=$!
psql "$ADMIN_DSN" -XAtq -c "select count(*) from pgvigil_proof_t" >/dev/null 2>&1 &
W2=$!
sleep 1.5

"$BIN" collect -config "$CFG" -once activity

iid=$(q "select instance_id from pgvigil.instances where name='proof-activity'")
snap=$(q "select max(snapshot_at) from pgvigil.activity_summary where instance_id=$iid")
[ -n "$snap" ] || fail "no summary row"
sessions=$(q "select count(*) from pgvigil.activity_sample where instance_id=$iid and snapshot_at='$snap'")
holders=$(q "select count(*) from pgvigil.activity_sample where instance_id=$iid and snapshot_at='$snap' and state='idle in transaction'")
waiters=$(q "select count(*) from pgvigil.activity_sample where instance_id=$iid and snapshot_at='$snap' and state='active' and wait_event_type='Lock' and cardinality(blocking_pids) >= 1")
summary=$(q "select waiting_lock || '/' || idle_in_txn || '/' || total from pgvigil.activity_summary where instance_id=$iid and snapshot_at='$snap'")
chains=$(q "select count(*) || ' rows, heads=' || count(distinct head_pid) || ', maxdepth=' || coalesce(max(depth),0) || ', cycles=' || count(*) filter (where in_cycle) || ', head_state=' || coalesce(min(head_state),'?') from pgvigil.blocking_chains($iid, '$snap')")
echo "sessions=$sessions holders=$holders waiters=$waiters summary(waiting_lock/idle_in_txn/total)=$summary chains: $chains"
[ "$holders" -ge 1 ] || fail "no idle-in-transaction holder captured"
[ "$waiters" -eq 2 ] || fail "expected 2 Lock waiters with blocking_pids, got $waiters"
[ "${summary%%/*}" -eq 2 ] || fail "summary waiting_lock != 2"
# two waiters on one head: exactly one row each, the head idle in transaction, no cycle.
# (on an exclusive-lock queue a later waiter also lists the waiters ahead of it, which are
#  Lock waiters themselves and so are followed, never reported as heads)
[[ "$chains" == 2\ rows,\ heads=1,\ maxdepth=*,\ cycles=0,\ head_state=idle\ in\ transaction ]] || fail "chains: $chains"
[ "$(q "select count(*) from pgvigil.activity_sample where instance_id=$iid and snapshot_at='$snap' and is_blocker")" = "1" ] || fail "expected exactly one is_blocker row (the holder)"
# release the holder and confirm the next snapshot is quiet
printf 'ROLLBACK;\n' >&3; exec 3>&-; wait $W1 $W2 2>/dev/null || true; sleep 0.5
"$BIN" collect -config "$CFG" -once activity >/dev/null
snap2=$(q "select max(snapshot_at) from pgvigil.activity_summary where instance_id=$iid")
[ "$(q "select waiting_lock from pgvigil.activity_summary where instance_id=$iid and snapshot_at='$snap2'")" = "0" ] || fail "waiting_lock not 0 after release"
echo "proof-activity: OK"
