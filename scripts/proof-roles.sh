#!/usr/bin/env bash
# Proof of the repository access contract on a throwaway PostgreSQL that hosts the repository:
# a login holding only pgvigil_collector can run a collection into the repository but cannot read
# a sample table or migrate; a login holding only pgvigil_reader can read a view and call a read
# function but cannot call an import function.
#   PGVIGIL_REPO_DSN  repository owner connection (superuser or the schema owner; creates the logins)
#   ADMIN_DSN         connection to the monitored server (the target of the collection)
# Expected: collect as the collector login = ok; SELECT on pgvigil.activity_sample as the collector
# = permission denied; migrate as the collector = fails; SELECT on pgvigil.activity_latest as the
# reader = ok; import_instance(...) as the reader = permission denied.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
C="pgvigil_it_coll_$RANDOM"; R="pgvigil_it_read_$RANDOM"; PW="pw$RANDOM$RANDOM"
CFG=$(mktemp)
cleanup() { rm -f "$CFG"; psql "$PGVIGIL_REPO_DSN" -XAtq -c "drop role if exists $C" -c "drop role if exists $R" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
HOST=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select coalesce(host(inet_server_addr()),'localhost')")
PORT=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select inet_server_port()")
DB=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select current_database()")

"$BIN" migrate -config <(printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: proof-roles\n    dsn: env:ADMIN_DSN\n') >/dev/null
psql "$PGVIGIL_REPO_DSN" -XAtq -c "create role $C login password '$PW' in role pgvigil_collector" -c "create role $R login password '$PW' in role pgvigil_reader" >/dev/null
export COLL_DSN="host=$HOST port=$PORT user=$C password=$PW dbname=$DB sslmode=disable"
READ_DSN="host=$HOST port=$PORT user=$R password=$PW dbname=$DB sslmode=disable"
printf 'repository:\n  dsn: env:COLL_DSN\ninstances:\n  - name: proof-roles\n    dsn: env:ADMIN_DSN\n' > "$CFG"

"$BIN" collect -config "$CFG" -once instance || fail "collect as the collector login failed"
out=$(psql "$COLL_DSN" -XAt -c "select count(*) from pgvigil.activity_sample" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "collector could read activity_sample: $out"
out=$(psql "$COLL_DSN" -XAt -c "select count(*) from pgvigil.instance_state" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "collector could read instance_state: $out"
if "$BIN" migrate -config "$CFG" >/dev/null 2>&1; then fail "migrate as the collector login succeeded"; fi
# the daemon starts as the collector login (it checks the schema, it does not migrate)
timeout 8 "$BIN" run -config "$CFG" >/dev/null 2>&1 & RUNPID=$!
sleep 5; kill -0 "$RUNPID" 2>/dev/null || fail "pgvigil run exited early as the collector login"
kill "$RUNPID" 2>/dev/null || true; wait "$RUNPID" 2>/dev/null || true
cnt=$(psql "$READ_DSN" -XAt -c "select count(*) from pgvigil.activity_latest" 2>&1) || fail "reader could not read activity_latest: $cnt"
psql "$READ_DSN" -XAtq -c "select * from pgvigil.blocking_chains(1, now()) limit 1" >/dev/null 2>&1 || fail "reader could not call blocking_chains"
out=$(psql "$READ_DSN" -XAt -c "select pgvigil.import_instance(1, now(), '[]'::jsonb)" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "reader could call import_instance: $out"
echo "proof-roles: OK (collector: collect yes, run yes, read no, migrate no; reader: read yes, import no)"
