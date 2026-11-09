#!/usr/bin/env bash
# Proof of the dbstats collection on a throwaway PostgreSQL: two collections with a known
# number of committed transactions and one temp-file spill in between, then the rate views.
#
#   PGVIGIL_REPO_DSN  repository (the proof's instance row and its data stay there, under the name proof-dbstats);  ADMIN_DSN  connection to the monitored server
#
# Also: the io rate function returns rows with non-NULL read_bytes or write_bytes on PG16+ (bytes normalised).
# Expected: snapshot 1 and 2 each hold one dbstats row per connectable database and one
# serverstats row (and iostats rows on PG16+); the rate view for the connected database
# shows xact_commit >= 12 (12 single-statement psql calls plus the collector's own), a
# temp_files delta >= 1, reset = false, interval_secs >= 1; the serverstats_rate row has a
# non-NULL wal_bytes on PG14+; no negative delta anywhere.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-dbstats
    dsn: env:ADMIN_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
db=$(psql "$ADMIN_DSN" -XAt -c "select current_database()")
vnum=$(psql "$ADMIN_DSN" -XAt -c "show server_version_num")

"$BIN" collect -config "$CFG" -once dbstats >/dev/null
iid=$(q "select instance_id from pgvigil.instances where name='proof-dbstats'")
s1=$(q "select max(snapshot_at) from pgvigil.dbstats where instance_id=$iid")
for i in $(seq 1 12); do psql "$ADMIN_DSN" -XAtq -c "select $i" >/dev/null; done
# a sort that spills to a temp file: work_mem at its floor
psql "$ADMIN_DSN" -XAtq -c "set work_mem = '64kB'" -c "select count(*) from (select g from generate_series(1,200000) g order by g desc) x" >/dev/null
sleep 1.2
"$BIN" collect -config "$CFG" -once dbstats >/dev/null
s2=$(q "select max(snapshot_at) from pgvigil.dbstats where instance_id=$iid")
[ "$s1" != "$s2" ] || fail "second snapshot did not land"

dbs=$(q "select count(*) from pgvigil.dbstats where instance_id=$iid and snapshot_at='$s2'")
srv=$(q "select count(*) from pgvigil.serverstats where instance_id=$iid and snapshot_at='$s2'")
io=$(q "select count(*) from pgvigil.iostats where instance_id=$iid and snapshot_at='$s2'")
rate=$(q "select xact_commit || '/' || temp_files || '/' || reset || '/' || interval_secs from pgvigil.dbstats_rate($iid, '$s1', '$s2') where snapshot_at='$s2' and datname='$db'")
echo "snapshot 2: dbstats rows=$dbs serverstats rows=$srv iostats rows=$io; $db rate xact_commit/temp_files/reset/interval=$rate"
[ "$dbs" -ge 1 ] && [ "$srv" -eq 1 ] || fail "row counts"
if [ "$vnum" -ge 160000 ]; then [ "$io" -ge 1 ] || fail "no iostats rows on PG16+"; fi
IFS=/ read -r xc tf rs iv <<<"$rate"
[ "${xc:-0}" -ge 12 ] || fail "xact_commit delta $xc < 12"
[ "${tf:-0}" -ge 1 ] || fail "temp_files delta $tf < 1"
[ "$rs" = "false" ] || fail "reset flag set ($rs)"
[ "${iv:-0}" -ge 1 ] || fail "interval_secs $iv"
neg=$(q "select count(*) from pgvigil.dbstats_rate($iid, '$s1', '$s2') where snapshot_at='$s2' and (xact_commit < 0 or blks_read < 0 or tup_returned < 0 or temp_bytes < 0)")
[ "$neg" = "0" ] || fail "negative deltas: $neg"
if [ "$vnum" -ge 140000 ]; then
  wb=$(q "select coalesce(wal_bytes::text,'NULL') from pgvigil.serverstats_rate($iid, '$s1', '$s2') where snapshot_at='$s2'")
  [ "$wb" != "NULL" ] || fail "wal_bytes delta NULL on PG14+"
fi
if [ "$vnum" -ge 160000 ]; then
  iob=$(q "select count(*) from pgvigil.iostats_rate($iid, '$s1', '$s2') where snapshot_at='$s2' and (read_bytes is not null or write_bytes is not null)")
  [ "${iob:-0}" -ge 1 ] || fail "iostats_rate: no row with normalised bytes"
fi
echo "proof-dbstats: OK"
