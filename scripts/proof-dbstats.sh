#!/usr/bin/env bash
# Proof of the dbstats and iostats collections on a throwaway PostgreSQL: two runs of each with a
# known number of committed transactions and one temp-file spill in between, then the rate functions.
#
#   PGVIGIL_REPO_DSN  repository (the proof's instance row and its data stay there, under the name proof-dbstats);  ADMIN_DSN  connection to the monitored server
#
# Expected: dbstats snapshots 1 and 2 each hold one dbstats row per connectable database and one
# serverstats row, and NO iostats row (pg_stat_io left this collection for its own); the rate
# function for the connected database shows xact_commit >= 12 (12 single-statement psql calls plus
# the collector's own), a temp_files delta >= 1, reset = false, interval_secs >= 1; the
# serverstats_rate row has a non-NULL wal_bytes on PG14+; no negative delta anywhere. iostats: on
# PG16+ its two runs land two snapshots of pg_stat_io rows (>= 1 each), its collection status is ok,
# and iostats_rate returns a row with non-NULL read_bytes or write_bytes (bytes normalised) for the
# second; below PG16 the collection is logged as skipped and the table holds no row of the instance.
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
"$BIN" collect -config "$CFG" -once iostats >/dev/null
iid=$(q "select instance_id from pgvigil.instances where name='proof-dbstats'")
s1=$(q "select max(snapshot_at) from pgvigil.dbstats where instance_id=$iid")
i1=$(q "select coalesce(max(snapshot_at)::text, '') from pgvigil.iostats where instance_id=$iid")
for i in $(seq 1 12); do psql "$ADMIN_DSN" -XAtq -c "select $i" >/dev/null; done
# a sort that spills to a temp file: work_mem at its floor
psql "$ADMIN_DSN" -XAtq -c "set work_mem = '64kB'" -c "select count(*) from (select g from generate_series(1,200000) g order by g desc) x" >/dev/null
sleep 1.2
"$BIN" collect -config "$CFG" -once dbstats >/dev/null
"$BIN" collect -config "$CFG" -once iostats >/dev/null
s2=$(q "select max(snapshot_at) from pgvigil.dbstats where instance_id=$iid")
[ "$s1" != "$s2" ] || fail "second snapshot did not land"

dbs=$(q "select count(*) from pgvigil.dbstats where instance_id=$iid and snapshot_at='$s2'")
srv=$(q "select count(*) from pgvigil.serverstats where instance_id=$iid and snapshot_at='$s2'")
io_at_dbstats=$(q "select count(*) from pgvigil.iostats where instance_id=$iid and snapshot_at in ('$s1', '$s2')")
rate=$(q "select xact_commit || '/' || temp_files || '/' || reset || '/' || interval_secs from pgvigil.dbstats_rate($iid, '$s1', '$s2') where snapshot_at='$s2' and datname='$db'")
echo "snapshot 2: dbstats rows=$dbs serverstats rows=$srv iostats rows at the dbstats snapshots=$io_at_dbstats; $db rate xact_commit/temp_files/reset/interval=$rate"
[ "$dbs" -ge 1 ] && [ "$srv" -eq 1 ] || fail "row counts"
[ "$io_at_dbstats" = "0" ] || fail "dbstats still stores pg_stat_io rows ($io_at_dbstats)"
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

# iostats: its own collection since 0018 (5 minutes by default; two runs here, seconds apart)
iost=$(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='iostats'")
if [ "$vnum" -ge 160000 ]; then
  [ "$iost" = "ok" ] || fail "iostats collection status '$iost' on PG16+ (want ok)"
  i2=$(q "select max(snapshot_at) from pgvigil.iostats where instance_id=$iid")
  [ -n "$i1" ] && [ "$i1" != "$i2" ] || fail "iostats: two snapshots expected (first '$i1', last '$i2')"
  io=$(q "select count(*) from pgvigil.iostats where instance_id=$iid and snapshot_at='$i2'")
  [ "$io" -ge 1 ] || fail "no iostats rows on PG16+"
  iob=$(q "select count(*) from pgvigil.iostats_rate($iid, '$i1', '$i2') where snapshot_at='$i2' and (read_bytes is not null or write_bytes is not null)")
  [ "${iob:-0}" -ge 1 ] || fail "iostats_rate: no row with normalised bytes"
  echo "iostats: snapshot 2 rows=$io, rate rows with bytes=$iob, collection status $iost"
else
  [ "$iost" = "skipped" ] || fail "iostats collection status '$iost' below PG16 (want skipped)"
  io=$(q "select count(*) from pgvigil.iostats where instance_id=$iid")
  [ "$io" = "0" ] || fail "iostats rows below PG16: $io"
  echo "iostats: skipped below PG16, no rows, as expected"
fi
echo "proof-dbstats: OK"
