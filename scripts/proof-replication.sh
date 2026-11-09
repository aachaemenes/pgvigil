#!/usr/bin/env bash
# Proof of the replication collection on a throwaway PostgreSQL primary without a standby:
# creates a physical replication slot, writes some WAL, collects, checks the slot row and the
# check view, drops the slot. Needs wal_level >= replica and a free max_replication_slots.
#
#   PGVIGIL_REPO_DSN  repository (the proof's instance row and its data stay there, under the name proof-replication);  ADMIN_DSN  superuser connection to the monitored server
#
# Expected: a 'slot' row for the created slot with active = false and retained_bytes > 0
# after the WAL writes; a 'conflict' row per connectable database; zero 'sender' and
# 'receiver' rows (no standby); replication_checks lists the slot as 'inactive slot retaining WAL'.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
SLOT="pgvigil_proof_$RANDOM"
CFG=$(mktemp)
cleanup() { rm -f "$CFG"; psql "$ADMIN_DSN" -XAtq -c "select pg_drop_replication_slot('$SLOT')" >/dev/null 2>&1 || true; psql "$ADMIN_DSN" -XAtq -c "drop table if exists pgvigil_repl_t" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-replication
    dsn: env:ADMIN_DSN
EOF
[ "$(psql "$ADMIN_DSN" -XAt -c "select current_setting('wal_level') in ('replica','logical')")" = "t" ] || fail "wal_level is minimal"
"$BIN" migrate -config "$CFG" >/dev/null
psql "$ADMIN_DSN" -XAtq -c "select pg_create_physical_replication_slot('$SLOT', true)" >/dev/null
psql "$ADMIN_DSN" -XAtq -c "drop table if exists pgvigil_repl_t" -c "create table pgvigil_repl_t as select g, repeat('x', 500) t from generate_series(1, 20000) g" -c "select pg_switch_wal()" >/dev/null
"$BIN" collect -config "$CFG" -once replication
iid=$(q "select instance_id from pgvigil.instances where name='proof-replication'")
snap=$(q "select max(snapshot_at) from pgvigil.replication_sample where instance_id=$iid")
slot=$(q "select active || '/' || lag_bytes || '/' || coalesce(state,'?') from pgvigil.replication_sample where instance_id=$iid and snapshot_at='$snap' and kind='slot' and key='$SLOT'")
kinds=$(q "select string_agg(kind || '=' || c, ' ' order by kind) from (select kind, count(*) c from pgvigil.replication_sample where instance_id=$iid and snapshot_at='$snap' group by kind) x")
chk=$(q "select count(*) from pgvigil.replication_checks where instance_id=$iid and check_name='inactive slot retaining WAL' and object='$SLOT'")
echo "kinds: $kinds; slot $SLOT active/retained/wal_status = $slot; checks = $chk"
[[ "$slot" == false/* ]] || fail "slot row missing or active: '$slot'"
IFS=/ read -r _ retained _ <<<"$slot"
[ "${retained:-0}" -gt 0 ] || fail "retained_bytes not > 0"
[[ "$kinds" == *"conflict="* ]] || fail "no conflict rows"
[[ "$kinds" != *"sender="* ]] || fail "unexpected sender rows on a server without a standby"
[ "$chk" = "1" ] || fail "replication_checks did not flag the slot"
echo "proof-replication: OK"
