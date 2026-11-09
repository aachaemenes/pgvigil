#!/usr/bin/env bash
# Proof of the statements collection on a throwaway PostgreSQL with pg_stat_statements:
# runs a marker statement a known number of times between collections and checks the deltas,
# then resets the extension's counters and checks the reset flag. Never run against a shared
# server (it calls pg_stat_statements_reset()).
#
#   PGVIGIL_REPO_DSN  repository;  ADMIN_DSN  superuser connection to the monitored server
#
# Expected: snapshot 1 writes no delta for the marker (first sight); after 5 more runs,
# snapshot 2 has one delta row for the marker with calls = 5 and reset = false; after
# pg_stat_statements_reset() and 3 runs, snapshot 3 has one row with calls = 3 and reset = true;
# top_statements over the window returns the marker with calls = 8.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
CFG=$(mktemp)
# a table per run: a column alias is not part of the query id (the extension keeps the first text it saw
# for a query id), so only a different relation gives this run a statement of its own
TAG="m$RANDOM$RANDOM"; TBL="pgvigil_stmt_$TAG"
trap 'rm -f "$CFG"; psql "$ADMIN_DSN" -XAtq -c "drop table if exists $TBL" >/dev/null 2>&1 || true' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
marker() { for i in $(seq 1 "$1"); do psql "$ADMIN_DSN" -XAtq -c "select count(*) as pgvigil_marker from $TBL where id = $i" >/dev/null; done; }

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-target
    dsn: env:ADMIN_DSN
EOF
psql "$ADMIN_DSN" -XAtq -c "drop table if exists $TBL" -c "create table $TBL (id int)" -c "create extension if not exists pg_stat_statements" >/dev/null
"$BIN" migrate -config "$CFG" >/dev/null
iid_sql="select instance_id from pgvigil.instances where name='proof-target'"

marker 2
"$BIN" collect -config "$CFG" -once statements >/dev/null
iid=$(q "$iid_sql")
qid=$(q "select queryid from pgvigil.statement_text where instance_id=$iid and query like '%from $TBL where%' limit 1")
[ -n "$qid" ] || fail "marker statement text not captured"
[ "$(q "select count(*) from pgvigil.statements_delta where instance_id=$iid and queryid=$qid")" = "0" ] || fail "a delta row on first sight"

marker 5; sleep 1
"$BIN" collect -config "$CFG" -once statements >/dev/null
r2=$(q "select calls || '/' || reset from pgvigil.statements_delta where instance_id=$iid and queryid=$qid order by snapshot_at desc limit 1")
[ "$r2" = "5/false" ] || fail "snapshot 2 expected calls 5 reset false, got '$r2'"

psql "$ADMIN_DSN" -XAtq -c "select pg_stat_statements_reset()" >/dev/null
marker 3; sleep 1
"$BIN" collect -config "$CFG" -once statements >/dev/null
r3=$(q "select calls || '/' || reset from pgvigil.statements_delta where instance_id=$iid and queryid=$qid order by snapshot_at desc limit 1")
[ "$r3" = "3/true" ] || fail "snapshot 3 expected calls 3 reset true, got '$r3'"

top=$(q "select calls from pgvigil.top_statements($iid, now() - interval '10 minutes', now(), 500) where queryid=$qid")
[ "$top" = "8" ] || fail "top_statements expected calls 8 for the marker, got '$top'"
echo "proof-statements: OK (queryid $qid: first sight no delta, then 5/false, then 3/true after reset; window total 8)"
