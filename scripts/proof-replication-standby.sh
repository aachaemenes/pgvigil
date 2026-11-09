#!/usr/bin/env bash
# Proof of the replication collection's standby paths on a throwaway standby built from the
# target with pg_basebackup -R into a temp folder (about 60 MB, ~10 s), started on its own port,
# with pg_receivewal attached to it so the standby also has a walsender. Collects against the
# standby and checks the receiver row, the sender row and the slot. Stops and removes everything.
#   PGVIGIL_REPO_DSN  repository (owner connection)
#   ADMIN_DSN         superuser connection to the primary (the sandbox); its pgpass line must cover
#                     the standby's port too (a '*' port entry) so replication connections authenticate
#   STANDBY_PORT      default 5499
# Expected: instance_state.is_replica = true for the standby; replication_sample for its snapshot has
# one 'receiver' row (status streaming, replay_delay_secs numeric), at least one 'sender' row (the
# pg_receivewal client), and the slot row for pg_receivewal's slot with active = true; the senders
# read did not fail in recovery (no collector_error rows).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
PORT=${STANDBY_PORT:-5499}
DIR=$(mktemp -d); WALDIR=$(mktemp -d); CFG=$(mktemp); SLOT="pgvigil_standby_$RANDOM"
PHOST=$(psql "$ADMIN_DSN" -XAt -c "select coalesce(host(inet_server_addr()),'localhost')")
PPORT=$(psql "$ADMIN_DSN" -XAt -c "select inet_server_port()")
PUSER=$(psql "$ADMIN_DSN" -XAt -c "select current_user")
cleanup() {
  [ -n "${RW:-}" ] && kill "$RW" 2>/dev/null || true
  pg_ctl -D "$DIR" stop -m fast -s >/dev/null 2>&1 || true
  rm -rf "$DIR" "$WALDIR" "$CFG"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }

pg_basebackup -h "$PHOST" -p "$PPORT" -U "$PUSER" -D "$DIR" -R -X stream -c fast >/dev/null 2>&1 || fail "pg_basebackup failed (replication access from $PUSER?)"
cat >> "$DIR/postgresql.auto.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = '$DIR'
hot_standby = on
EOF
pg_ctl -D "$DIR" -l "$DIR/standby.log" -w -s start >/dev/null 2>&1 || { tail -5 "$DIR/standby.log" >&2; fail "standby did not start"; }
export STANDBY_DSN="host=localhost port=$PORT user=$PUSER dbname=postgres sslmode=disable"
for i in $(seq 1 20); do psql "$STANDBY_DSN" -XAtq -c "select 1" >/dev/null 2>&1 && break; sleep 0.5; done
[ "$(psql "$STANDBY_DSN" -XAt -c 'select pg_is_in_recovery()')" = "t" ] || fail "standby not in recovery"
# a walsender on the standby: pg_receivewal streaming from it into a temp folder
pg_receivewal -h localhost -p "$PORT" -U "$PUSER" -D "$WALDIR" --create-slot --slot "$SLOT" >/dev/null 2>&1 || true
pg_receivewal -h localhost -p "$PORT" -U "$PUSER" -D "$WALDIR" --slot "$SLOT" --no-sync >/dev/null 2>&1 &
RW=$!
sleep 2
[ "$(psql "$STANDBY_DSN" -XAt -c 'select count(*) from pg_stat_replication')" -ge 1 ] || fail "no walsender on the standby (pg_receivewal did not attach)"

printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: proof-standby\n    dsn: env:STANDBY_DSN\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once instance >/dev/null
"$BIN" collect -config "$CFG" -once replication
iid=$(q "select instance_id from pgvigil.instances where name='proof-standby'")
[ "$(q "select is_replica from pgvigil.instance_state where instance_id=$iid")" = "t" ] || fail "instance_state.is_replica not true"
snap=$(q "select max(snapshot_at) from pgvigil.replication_sample where instance_id=$iid")
kinds=$(q "select string_agg(kind || '=' || c, ' ' order by kind) from (select kind, count(*) c from pgvigil.replication_sample where instance_id=$iid and snapshot_at='$snap' group by kind) x")
recv=$(q "select coalesce(state,'?') || '/' || coalesce(lag_secs::text,'NULL') from pgvigil.replication_sample where instance_id=$iid and snapshot_at='$snap' and kind='receiver'")
errs=$(q "select count(*) from pgvigil.collection_log where instance_id=$iid and collection='replication' and status='partial'")
echo "standby snapshot kinds: $kinds; receiver status/replay_delay = $recv; partial errors = $errs"
[[ "$kinds" == *"receiver=1"* ]] || fail "no receiver row"
[[ "$kinds" == *"sender="* ]] || fail "no sender row on the standby"
[[ "$kinds" == *"slot="* ]] || fail "no slot row"
[ "$errs" = "0" ] || fail "a read failed in recovery: $(q "select note from pgvigil.collection_log where instance_id=$iid and status='partial' order by log_id desc limit 1")"
[[ "$recv" == streaming/* ]] || fail "receiver not streaming: $recv"
[ "$(q "select active from pgvigil.replication_sample where instance_id=$iid and snapshot_at='$snap' and kind='slot' and key='$SLOT'")" = "t" ] || fail "pg_receivewal's slot not active"
echo "proof-replication-standby: OK"
