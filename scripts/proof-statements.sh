#!/usr/bin/env bash
# Proof of the statements collection on a throwaway PostgreSQL with pg_stat_statements:
# runs a marker statement a known number of times between collections and checks the deltas,
# then resets the extension's counters and checks the reset flag. Never run against a shared
# server (it calls pg_stat_statements_reset()).
#
#   PGVIGIL_REPO_DSN  repository (the proof's instance row and its data stay there, under the name proof-statements);  ADMIN_DSN  superuser connection to the monitored server
#
# Also checked: a statement absent from the import that first sees a reset is still flagged when it
# returns (the reset time is stored per current row); a payload that names one statement twice (two
# readings of the view while its counters moved) imports whole, the reading with the most calls is
# kept and the next cycle's delta counts from it (migration 0017).
# Expected: snapshot 1 writes no delta for the marker (first sight); after 5 more runs,
# snapshot 2 has one delta row for the marker with calls = 5 and reset = false; after
# pg_stat_statements_reset() and 3 runs, snapshot 3 has one row with calls = 3 and reset = true;
# after another reset and 9 runs (more than the 3 before: calls does NOT drop) snapshot 4 has
# calls = 9 and reset = true; top_statements over the window returns the marker with calls = 17.
# The extension is dropped at the end only if this script created it.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
CFG=$(mktemp)
# a table per run: a column alias is not part of the query id (the extension keeps the first text it saw
# for a query id), so only a different relation gives this run a statement of its own
TAG="m$RANDOM$RANDOM"; TBL="pgvigil_stmt_$TAG"
cleanup() { rm -f "$CFG"; psql "$ADMIN_DSN" -XAtq -c "drop table if exists $TBL" >/dev/null 2>&1 || true; [ "${HAD_EXT:-1}" = "0" ] && psql "$ADMIN_DSN" -XAtq -c "drop extension if exists pg_stat_statements" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
marker() { for i in $(seq 1 "$1"); do psql "$ADMIN_DSN" -XAtq -c "select count(*) as pgvigil_marker from $TBL where id = $i" >/dev/null; done; }

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-statements
    dsn: env:ADMIN_DSN
EOF
HAD_EXT=$(psql "$ADMIN_DSN" -XAt -c "select count(*) from pg_extension where extname='pg_stat_statements'")
psql "$ADMIN_DSN" -XAtq -c "drop table if exists $TBL" -c "create table $TBL (id int)" -c "create extension if not exists pg_stat_statements" >/dev/null
"$BIN" migrate -config "$CFG" >/dev/null
iid_sql="select instance_id from pgvigil.instances where name='proof-statements'"

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

# the overtake case: more calls after the reset than before it, so calls does not drop
psql "$ADMIN_DSN" -XAtq -c "select pg_stat_statements_reset()" >/dev/null
marker 9; sleep 1
"$BIN" collect -config "$CFG" -once statements >/dev/null
r4=$(q "select calls || '/' || reset from pgvigil.statements_delta where instance_id=$iid and queryid=$qid order by snapshot_at desc limit 1")
[ "$r4" = "9/true" ] || fail "snapshot 4 (overtake) expected calls 9 reset true, got '$r4'"
neg=$(q "select count(*) from pgvigil.statements_delta where instance_id=$iid and (calls < 0 or total_exec_ms < 0 or wal_bytes < 0)")
[ "$neg" = "0" ] || fail "negative deltas: $neg"

top=$(q "select round(calls) from pgvigil.top_statements($iid, now() - interval '10 minutes', now(), 500) where queryid=$qid")
[ "$top" = "17" ] || fail "top_statements expected calls 17 for the marker, got '$top'"
# crafted: a cycle whose info row is missing must not turn the next cycle into a mass reset
q "select pgvigil.import_statements($iid, now() - interval '3 minutes', '[{\"kind\":\"stmt\",\"dbid\":1,\"datname\":\"d\",\"userid\":1,\"usename\":\"u\",\"queryid\":424242,\"toplevel\":true,\"calls\":100,\"total_exec_ms\":10,\"rows\":1,\"shared_blks_hit\":0,\"shared_blks_read\":0,\"shared_blks_dirtied\":0,\"shared_blks_written\":0,\"temp_blks_read\":0,\"temp_blks_written\":0,\"blk_read_ms\":0,\"blk_write_ms\":0,\"temp_read_ms\":0,\"temp_write_ms\":0,\"wal_bytes\":0,\"query\":\"crafted\"},{\"kind\":\"info\",\"dealloc\":0,\"stats_reset\":\"2026-01-01T00:00:00Z\"}]'::jsonb)" >/dev/null
q "select pgvigil.import_statements($iid, now() - interval '2 minutes', '[{\"kind\":\"stmt\",\"dbid\":1,\"datname\":\"d\",\"userid\":1,\"usename\":\"u\",\"queryid\":424242,\"toplevel\":true,\"calls\":110,\"total_exec_ms\":11,\"rows\":1,\"shared_blks_hit\":0,\"shared_blks_read\":0,\"shared_blks_dirtied\":0,\"shared_blks_written\":0,\"temp_blks_read\":0,\"temp_blks_written\":0,\"blk_read_ms\":0,\"blk_write_ms\":0,\"temp_read_ms\":0,\"temp_write_ms\":0,\"wal_bytes\":0,\"query\":\"crafted\"}]'::jsonb)" >/dev/null
q "select pgvigil.import_statements($iid, now() - interval '1 minute', '[{\"kind\":\"stmt\",\"dbid\":1,\"datname\":\"d\",\"userid\":1,\"usename\":\"u\",\"queryid\":424242,\"toplevel\":true,\"calls\":120,\"total_exec_ms\":12,\"rows\":1,\"shared_blks_hit\":0,\"shared_blks_read\":0,\"shared_blks_dirtied\":0,\"shared_blks_written\":0,\"temp_blks_read\":0,\"temp_blks_written\":0,\"blk_read_ms\":0,\"blk_write_ms\":0,\"temp_read_ms\":0,\"temp_write_ms\":0,\"wal_bytes\":0,\"query\":\"crafted\"},{\"kind\":\"info\",\"dealloc\":0,\"stats_reset\":\"2026-01-01T00:00:00Z\"}]'::jsonb)" >/dev/null
crafted=$(q "select string_agg(calls || '/' || reset, ' ' order by snapshot_at) from pgvigil.statements_delta where instance_id=$iid and queryid=424242")
[ "$crafted" = "10/false 10/false" ] || fail "info-row gap: expected '10/false 10/false', got '$crafted'"
# crafted: one statement twice in one payload (two readings of the view while the counters moved) must import
# whole; the reading with the most calls is kept and the next cycle's delta counts from it
dup() { printf '{"kind":"stmt","dbid":1,"datname":"d","userid":1,"usename":"u","queryid":434343,"toplevel":true,"calls":%s,"total_exec_ms":%s,"rows":1,"shared_blks_hit":0,"shared_blks_read":0,"shared_blks_dirtied":0,"shared_blks_written":0,"temp_blks_read":0,"temp_blks_written":0,"blk_read_ms":0,"blk_write_ms":0,"temp_read_ms":0,"temp_write_ms":0,"wal_bytes":0,"query":"crafted-dup"}' "$1" "$2"; }
q "select pgvigil.import_statements($iid, now() - interval '50 seconds', '[$(dup 50 5),$(dup 60 6),{\"kind\":\"info\",\"dealloc\":0,\"stats_reset\":\"2026-01-01T00:00:00Z\"}]'::jsonb)" >/dev/null || fail "a payload naming one statement twice failed to import"
cur=$(q "select calls from pgvigil.statements_current where instance_id=$iid and queryid=434343")
[ "$cur" = "60" ] || fail "duplicate key: expected the reading with 60 calls kept, got '$cur'"
q "select pgvigil.import_statements($iid, now() - interval '40 seconds', '[$(dup 70 7),$(dup 65 6.5),{\"kind\":\"info\",\"dealloc\":0,\"stats_reset\":\"2026-01-01T00:00:00Z\"}]'::jsonb)" >/dev/null || fail "the second duplicate payload failed to import"
dd=$(q "select string_agg(calls || '/' || reset, ' ' order by snapshot_at) from pgvigil.statements_delta where instance_id=$iid and queryid=434343")
[ "$dd" = "10/false" ] || fail "duplicate key: expected one delta 10/false, got '$dd'"
q "delete from pgvigil.statements_delta where instance_id=$iid and queryid in (424242, 434343); delete from pgvigil.statements_current where instance_id=$iid and queryid in (424242, 434343); delete from pgvigil.statement_text where instance_id=$iid and queryid in (424242, 434343)" >/dev/null
echo "proof-statements: OK (queryid $qid: first sight no delta, 5/false, 3/true after reset, 9/true after an overtaking reset; window total 17; an info-row gap stays 10/false 10/false; one statement twice in a payload imports whole, 60 kept, next delta 10/false)"
