#!/usr/bin/env bash
# Proof of 'pgvigil migrate -print' (ST7): the statements migrate would run, printed and applied by psql, make the same
# schema and the same row counts migrate makes, and the print itself changes nothing. Scratch databases and one scratch
# login on the server PGVIGIL_REPO_DSN names (an admin connection; its own database is not touched), dropped at the end;
# the cluster roles the migrations create (pgvigil_collector, _reader, _auth, _alerter, _requester, _exporter, _investigator) stay there.
# Needs go, psql and pg_dump (pg_dump's major at least the server's) on this machine.
#   PGVIGIL_REPO_DSN   an admin connection string (CREATEDB, CREATEROLE) to a scratch PostgreSQL server, in the key=value
#                      form (the script appends ' dbname=...'; a postgres:// URI does not take that)
#   PGVIGIL_BIN        a pgvigil binary of this tree (default: built here)
# Expected (written before the first run; the review-st7 fold's rows marked *):
#   T go test    go test -count=1 -run TestMigratePrint ./internal/repo/ on this tree: ok (T1-T6). Their red at the stub
#                (900df151) is a box job of its own (st7red1), not a row of this script *
#   A migrate    'pgvigil migrate' on an empty database (ref): exit 0, schema_version holds every file of the tree
#   B print      'migrate -print' on another empty database (fresh): exit 0, stderr says nothing was applied, the header
#                says 'applied: none' and 'pending: <the tree's count> file(s): 0001_core.sql .. <the newest>', the first
#                line after the header is '\set ON_ERROR_STOP on' *; fresh has no pgvigil schema after it
#   C apply      psql -X -f <the script> on fresh (no -v: the script's own ON_ERROR_STOP *): exit 0; schema_version holds
#                every file; jit=off is the database setting of both; pg_dump -s of fresh and of ref are the same
#                (pg_dump's \restrict key lines set aside, and the daily parent's day partitions mssql_requests_YYYYMMDD:
#                a run over 00:00 UTC makes other days - their making is proof-partition-deadlock's R3) and so is every
#                pgvigil table's row count *
#   D again      a second -print on fresh: exit 0, 'pending: none', every line a comment
#   E at N       two schema_version rows of fresh taken out (a middle file and the newest): -print names exactly those
#                two, in order, in its header, its guard and its files; schema_version, the count of pg_class and
#                pg_db_role_setting read the same before and after the print
#   F guard      F1 the two rows put back (as if a migrate ran meanwhile): E's script exits 3 with 'applied since then:
#                <the two>'; F2 the two out again and the second file's row out too (a store older than the print, or a
#                row taken out): exit 3 with 'gone since then: <the second file>' *; schema_version unchanged by both
#   G reader     a login with only CONNECT, USAGE on schema pgvigil and SELECT on pgvigil.schema_version: -print exit 0,
#                'pending: none'; G2 that login runs E's script: exit 3, 'is owned by' (the owner check, before any
#                change) and schema_version unchanged *
#   H exits      -print against a closed port: exit 1, nothing on stdout; -print with no such config file: exit 3, nothing
#                on stdout
#   I at N, applied *  a third empty database (partial) with jit = on of its own: the fresh script cut after all but its
#                last 3 files, through psql: exit 0, schema_version holds those; -print there names exactly the last 3;
#                that script through psql: exit 0, every file, pg_dump -s and the row counts as ref's, the database's own
#                jit=on kept and the 'left alone' notice in psql's output
# A run that crosses the first of a month at 00:00 UTC after ref's migrate began makes other months ahead: C's and I's dump
# compares then print NOT PROVEN with that reason instead of a false FAIL (the row counts are still compared).
# NOT PROVEN here: the jit step's WARNING branch (the script run by the owner of schema pgvigil who does not own the
# database); a script printed for a store with a gap, applied (a real gap cannot be made from the embedded files).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_REPO_DSN:?an admin connection string to a scratch server}"
ADMIN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REF=pgvigil_mpref_$SUF; FRESH=pgvigil_mpfresh_$SUF; PARTIAL=pgvigil_mppart_$SUF; READER=pgvigil_mpread_$SUF; RPW=p$RANDOM$RANDOM
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
cleanup() {
  local db
  for db in "$REF" "$FRESH" "$PARTIAL"; do
    psql "$ADMIN" -XAtq -c "drop database if exists $db with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $db not dropped" >&2
  done
  psql "$ADMIN" -XAtq -c "drop role if exists $READER" >/dev/null 2>&1 || echo "CLEANUP: role $READER not dropped" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
q() { psql "$ADMIN dbname=$1" -XAt -v ON_ERROR_STOP=1 -c "$2"; }
# every pgvigil table (plain and partitioned) with its row count, in name order
counts() { q "$1" "select string_agg(c.relname || '=' || (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from pgvigil.%I', c.relname), false, true, '')))[1]::text, ',' order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and c.relkind in ('r', 'p') and not c.relispartition"; }
dumps() { pg_dump "$ADMIN dbname=$1" -s -T 'pgvigil.mssql_requests_2*' | grep -vE '^\\(un)?restrict '; }
# samedump <part> <file>: the dump against ref's; a month turned since ref's dump (UTC) is NOT PROVEN, never a FAIL
samedump() { if diff -q "$WORK/ref.dump" "$2" >/dev/null; then return 0; fi
  if [ "$(date -u +%Y%m)" != "$REFMONTH" ]; then echo "NOT PROVEN $1: pg_dump -s not compared: the run crossed a month's first 00:00 UTC after ref's migrate began (other months ahead)"; return 0; fi
  diff "$WORK/ref.dump" "$2" > "$WORK/$1.diff" || true; head -20 "$WORK/$1.diff" >&2; fail "$1: pg_dump -s differs"; }
jitof() { q "$1" "select coalesce(string_agg(x, ','), '') from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) x where d.datname = current_database() and s.setrole = 0 and x like 'jit=%'"; }
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  BIN=$WORK/pgvigil
  go build -o "$BIN" ./cmd/pgvigil
fi
cat > "$CFG" <<'EOF'
repository:
  dsn: env:PGVIGIL_REPO_DSN
EOF
mapfile -t FILES < <(find internal/repo/sql -maxdepth 1 -name '*.sql' -printf '%f\n' | LC_ALL=C sort)
NFILES=${#FILES[@]}
FIRST=${FILES[0]}; SECOND=${FILES[1]}; NEWEST=${FILES[$((NFILES - 1))]}; MIDDLE=${FILES[$((NFILES / 2))]}
K=$((NFILES - 3))
# a file's header in the printed script, matched whole: a migration's own comment may start '-- file ' too
# (0126_darling_queries.sql L35 '-- file fails whole ...'), so a bare '^-- file ' prefix miscounts the files
HDR='^-- file [0-9][0-9][0-9][0-9]_[^ ]+[.]sql [(][0-9]+ of [0-9]+[)]$'

echo "== T go test =="
go test -count=1 -run TestMigratePrint ./internal/repo/ > "$WORK/t.out" 2>&1 || { cat "$WORK/t.out" >&2; fail "T: go test"; }
ok "T $(tail -1 "$WORK/t.out")"

psql "$ADMIN" -XAtq -v ON_ERROR_STOP=1 -c "create database $REF" -c "create database $FRESH" -c "create database $PARTIAL" >/dev/null

echo "== A migrate =="
REFMONTH=$(date -u +%Y%m)   # read BEFORE the migrate makes ref's months ahead: a month turned during it is a turn too
PGVIGIL_REPO_DSN="$ADMIN dbname=$REF" "$BIN" migrate -config "$CFG" 2> "$WORK/a.err" || { cat "$WORK/a.err" >&2; fail "A: migrate"; }
[ "$(q "$REF" "select count(*) from pgvigil.schema_version")" = "$NFILES" ] || fail "A: schema_version does not hold the tree's $NFILES files"
dumps "$REF" > "$WORK/ref.dump"; REFCOUNTS=$(counts "$REF")
ok "A migrate: $NFILES files"

echo "== B print (fresh) =="
PGVIGIL_REPO_DSN="$ADMIN dbname=$FRESH" "$BIN" migrate -config "$CFG" -print > "$WORK/fresh.sql" 2> "$WORK/b.err" || { cat "$WORK/b.err" >&2; fail "B: -print"; }
grep -q 'nothing was applied' "$WORK/b.err" || fail "B: stderr does not say nothing was applied: $(cat "$WORK/b.err")"
grep -qx -- '-- applied: none (no pgvigil.schema_version: a fresh repository)' "$WORK/fresh.sql" || fail "B: no 'applied: none' line"
grep -qx -- "-- pending: $NFILES file(s): $FIRST .. $NEWEST" "$WORK/fresh.sql" || fail "B: no 'pending: $NFILES file(s): $FIRST .. $NEWEST' line: $(grep -- '-- pending' "$WORK/fresh.sql")"
[ "$(grep -v -e '^--' -e '^$' "$WORK/fresh.sql" | head -1)" = '\set ON_ERROR_STOP on' ] || fail "B: the first line after the header is not '\\set ON_ERROR_STOP on'"
[ "$(q "$FRESH" "select to_regnamespace('pgvigil') is null")" = "t" ] || fail "B: the print made the pgvigil schema"
ok "B print: $(wc -l < "$WORK/fresh.sql") lines, $NFILES files pending, ON_ERROR_STOP first, fresh untouched"

echo "== C apply =="
rc=0; psql "$ADMIN dbname=$FRESH" -X -q -f "$WORK/fresh.sql" > "$WORK/c.out" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -20 "$WORK/c.out" >&2; fail "C: psql exit $rc"; }
[ "$(q "$FRESH" "select count(*) from pgvigil.schema_version")" = "$NFILES" ] || fail "C: schema_version does not hold $NFILES files"
for db in "$REF" "$FRESH"; do [ "$(jitof "$db")" = "jit=off" ] || fail "C: $db's jit setting is '$(jitof "$db")', not jit=off"; done
dumps "$FRESH" > "$WORK/fresh.dump"
samedump C "$WORK/fresh.dump"
[ "$(counts "$FRESH")" = "$REFCOUNTS" ] || fail "C: the row counts differ: ref $REFCOUNTS / fresh $(counts "$FRESH")"
ok "C apply: psql exit 0, $NFILES files, jit=off on both, pg_dump -s the same ($(wc -l < "$WORK/ref.dump") lines), row counts the same"

echo "== D again =="
PGVIGIL_REPO_DSN="$ADMIN dbname=$FRESH" "$BIN" migrate -config "$CFG" -print > "$WORK/again.sql" 2>/dev/null || fail "D: -print"
grep -q -- '-- pending: none' "$WORK/again.sql" || fail "D: no 'pending: none'"
! grep -qv '^--' "$WORK/again.sql" || fail "D: a statement printed: $(grep -v '^--' "$WORK/again.sql" | head -1)"
ok "D again: pending none, $(wc -l < "$WORK/again.sql") comment lines"

echo "== E at N =="
q "$FRESH" "delete from pgvigil.schema_version where version in ('$MIDDLE', '$NEWEST')" >/dev/null
state() { q "$FRESH" "select (select string_agg(version, ',' order by version) from pgvigil.schema_version) || '|' || (select count(*) from pg_class) || '|' || (select coalesce(string_agg(array_to_string(setconfig, ';'), ','), '') from pg_db_role_setting)"; }
before=$(state)
PGVIGIL_REPO_DSN="$ADMIN dbname=$FRESH" "$BIN" migrate -config "$CFG" -print > "$WORK/atn.sql" 2>/dev/null || fail "E: -print"
after=$(state)
[ "$before" = "$after" ] || fail "E: the print changed the repository"
grep -qx -- "-- pending: 2 file(s): $MIDDLE .. $NEWEST" "$WORK/atn.sql" || fail "E: header: $(grep -- '-- pending' "$WORK/atn.sql")"
grep -qF "unnest(ARRAY['$MIDDLE', '$NEWEST']::text[])" "$WORK/atn.sql" || fail "E: the guard does not name exactly the two"
[ "$(grep -cE "$HDR" "$WORK/atn.sql")" = 2 ] || fail "E: not two files"
{ grep -q "^-- file $MIDDLE (1 of 2)$" "$WORK/atn.sql" && grep -q "^-- file $NEWEST (2 of 2)$" "$WORK/atn.sql"; } || fail "E: the files are not $MIDDLE then $NEWEST"
ok "E at N: $MIDDLE and $NEWEST pending, the repository unchanged by the print"

echo "== F guard =="
sv() { q "$FRESH" "select string_agg(version, ',' order by version) from pgvigil.schema_version"; }
runatn() { local rc=0; psql "$ADMIN dbname=$FRESH$1" -X -q -f "$WORK/atn.sql" > "$WORK/f.out" 2>&1 || rc=$?; echo "$rc"; }
q "$FRESH" "insert into pgvigil.schema_version (version) values ('$MIDDLE'), ('$NEWEST')" >/dev/null
s1=$(sv); rc=$(runatn "")
[ "$rc" = 3 ] || fail "F1: psql exit $rc, not 3"
grep -q "applied since then: $MIDDLE, $NEWEST; gone since then: none" "$WORK/f.out" || fail "F1: no guard message: $(tail -3 "$WORK/f.out")"
[ "$(sv)" = "$s1" ] || fail "F1: schema_version changed"
q "$FRESH" "delete from pgvigil.schema_version where version in ('$MIDDLE', '$NEWEST', '$SECOND')" >/dev/null
s2=$(sv); rc=$(runatn "")
[ "$rc" = 3 ] || fail "F2: psql exit $rc, not 3"
grep -q "applied since then: none; gone since then: $SECOND" "$WORK/f.out" || fail "F2: no guard message: $(tail -3 "$WORK/f.out")"
[ "$(sv)" = "$s2" ] || fail "F2: schema_version changed"
q "$FRESH" "insert into pgvigil.schema_version (version) values ('$MIDDLE'), ('$NEWEST'), ('$SECOND')" >/dev/null
ok "F guard: a file applied since (exit 3) and a file gone since (exit 3), schema_version unchanged by both"

echo "== G reader =="
psql "$ADMIN" -XAtq -v ON_ERROR_STOP=1 -c "create role $READER login password '$RPW'" -c "grant connect on database $FRESH to $READER" >/dev/null
q "$FRESH" "grant usage on schema pgvigil to $READER; grant select on pgvigil.schema_version to $READER" >/dev/null
PGVIGIL_REPO_DSN="$ADMIN dbname=$FRESH user=$READER password=$RPW" "$BIN" migrate -config "$CFG" -print > "$WORK/g.sql" 2> "$WORK/g.err" || { cat "$WORK/g.err" >&2; fail "G: -print as the reader"; }
grep -q -- '-- pending: none' "$WORK/g.sql" || fail "G: no 'pending: none'"
s3=$(sv); rc=$(runatn " user=$READER password=$RPW")
[ "$rc" = 3 ] || fail "G2: psql exit $rc as the reader, not 3"
grep -q 'is owned by' "$WORK/f.out" || fail "G2: no owner message: $(tail -3 "$WORK/f.out")"
[ "$(sv)" = "$s3" ] || fail "G2: schema_version changed"
ok "G reader: -print as a SELECT-only login; its run of a script refused by the owner check (exit 3)"

echo "== H exits =="
set +e
PGVIGIL_REPO_DSN="host=127.0.0.1 port=1 dbname=x connect_timeout=5" "$BIN" migrate -config "$CFG" -print > "$WORK/h1.out" 2>/dev/null; rc1=$?
"$BIN" migrate -config "$WORK/none.yaml" -print > "$WORK/h2.out" 2>/dev/null; rc2=$?
set -e
{ [ "$rc1" = 1 ] && [ ! -s "$WORK/h1.out" ]; } || fail "H: a closed port: exit $rc1, stdout $(wc -c < "$WORK/h1.out") bytes"
{ [ "$rc2" = 3 ] && [ ! -s "$WORK/h2.out" ]; } || fail "H: no config file: exit $rc2, stdout $(wc -c < "$WORK/h2.out") bytes"
ok "H exits: closed port 1, no config 3, nothing on stdout"

echo "== I at N, applied =="
psql "$ADMIN" -XAtq -v ON_ERROR_STOP=1 -c "alter database $PARTIAL set jit = on" >/dev/null
awk -v k="$K" -v re="$HDR" '$0 ~ re {n++} n <= k' "$WORK/fresh.sql" > "$WORK/part.sql"
[ "$(grep -cE "$HDR" "$WORK/part.sql")" = "$K" ] || fail "I: the cut holds $(grep -cE "$HDR" "$WORK/part.sql") files, not $K"
# the cut's last file is the K-th of the tree, its COMMIT the cut's last statement
grep -qx -- "-- file ${FILES[$((K - 1))]} ($K of $NFILES)" "$WORK/part.sql" || fail "I: the cut's last file is not ${FILES[$((K - 1))]}"
[ "$(grep -v '^[[:space:]]*$' "$WORK/part.sql" | tail -1)" = "COMMIT;" ] || fail "I: the cut does not end on a file's COMMIT"
rc=0; psql "$ADMIN dbname=$PARTIAL" -X -q -f "$WORK/part.sql" > "$WORK/i1.out" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -20 "$WORK/i1.out" >&2; fail "I: the cut script: psql exit $rc"; }
n=$(q "$PARTIAL" "select count(*) from pgvigil.schema_version") || fail "I: schema_version not read"; [ "$n" = "$K" ] || fail "I: schema_version holds $n files, not $K"
PGVIGIL_REPO_DSN="$ADMIN dbname=$PARTIAL" "$BIN" migrate -config "$CFG" -print > "$WORK/rest.sql" 2>/dev/null || fail "I: -print"
grep -qx -- "-- pending: 3 file(s): ${FILES[$K]} .. $NEWEST" "$WORK/rest.sql" || fail "I: header: $(grep -- '-- pending' "$WORK/rest.sql")"
rc=0; psql "$ADMIN dbname=$PARTIAL" -X -q -f "$WORK/rest.sql" > "$WORK/i2.out" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -20 "$WORK/i2.out" >&2; fail "I: the rest: psql exit $rc"; }
[ "$(q "$PARTIAL" "select count(*) from pgvigil.schema_version")" = "$NFILES" ] || fail "I: schema_version does not hold $NFILES files"
dumps "$PARTIAL" > "$WORK/part.dump"
samedump I "$WORK/part.dump"
[ "$(counts "$PARTIAL")" = "$REFCOUNTS" ] || fail "I: the row counts differ from ref's"
[ "$(jitof "$PARTIAL")" = "jit=on" ] || fail "I: the database's own jit is '$(jitof "$PARTIAL")', not kept at jit=on"
grep -q 'left alone' "$WORK/i1.out" || fail "I: no 'left alone' notice in psql's output"
ok "I at N, applied: $K then 3 files, pg_dump -s and row counts as ref's, the database's own jit=on kept"

echo "PROOF OK: migrate -print (T A B C D E F G H I)"
