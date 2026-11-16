#!/usr/bin/env bash
# Proof of 'pgvigil migrate -print' (ST7): the statements migrate would run, printed and applied by psql, make the same
# repository migrate makes, and the print itself changes nothing. Scratch databases and one scratch login on the server
# PGVIGIL_REPO_DSN names (an admin connection; its own database is not touched), dropped at the end.
# Needs go, psql and pg_dump (pg_dump's major at least the server's) on this machine.
#   PGVIGIL_REPO_DSN   an admin connection string (CREATEDB, CREATEROLE) to a scratch PostgreSQL server
#   PGVIGIL_BIN        a pgvigil binary of this tree (default: built here)
# Expected (written before the first run):
#   T go test    go test -count=1 -run TestMigratePrint ./internal/repo/: ok (T1-T6); at the red commit 900df151 every one
#                of T1-T6 FAILS (the stub writes nothing)
#   A migrate    'pgvigil migrate' on an empty database (ref): exit 0, schema_version holds every file of the tree
#   B print      'migrate -print' on another empty database (fresh): exit 0, stderr says nothing was applied, the header
#                says 'applied: none' and 'pending: <the tree's count> file(s): 0001_core.sql .. <the newest>'; fresh has
#                no pgvigil schema after it (the print wrote nothing)
#   C apply      psql -X -v ON_ERROR_STOP=1 -f <the script> on fresh: exit 0; schema_version holds every file; jit=off is
#                the database setting of both; pg_dump -s of fresh and of ref are the same (pg_dump's \restrict key
#                lines set aside)
#   D again      a second -print on fresh: exit 0, 'pending: none', every line a comment
#   E at N       two schema_version rows of fresh taken out (a middle file and the newest): -print names exactly those
#                two, in order, in its header, its guard and its files; schema_version, the count of pg_class and
#                pg_db_role_setting read the same before and after the print
#   F guard      the two rows put back (as if a migrate ran meanwhile), E's script through psql: exit 3, 'applied since
#                this script was printed' on stderr, schema_version unchanged
#   G reader     a login with only CONNECT, USAGE on schema pgvigil and SELECT on pgvigil.schema_version: -print exit 0,
#                'pending: none'
#   H exits      -print against a closed port: exit 1, nothing on stdout; -print with no such config file: exit 3, nothing
#                on stdout
# NOT PROVEN here: the jit step's WARNING branch (the script run by a login that does not own the database).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_REPO_DSN:?an admin connection string to a scratch server}"
ADMIN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REF=pgvigil_mpref_$SUF; FRESH=pgvigil_mpfresh_$SUF; READER=pgvigil_mpread_$SUF; RPW=p$RANDOM$RANDOM
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
cleanup() {
  psql "$ADMIN" -XAtq -c "drop database if exists $REF with (force)" -c "drop database if exists $FRESH with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN" -XAtq -c "drop role if exists $READER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
q() { psql "$ADMIN dbname=$1" -XAt -v ON_ERROR_STOP=1 -c "$2"; }
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  BIN=$WORK/pgvigil
  go build -o "$BIN" ./cmd/pgvigil
fi
cat > "$CFG" <<'EOF'
repository:
  dsn: env:PGVIGIL_REPO_DSN
EOF
NFILES=$(find internal/repo/sql -maxdepth 1 -name '*.sql' | wc -l)
FIRST=$(find internal/repo/sql -maxdepth 1 -name '*.sql' -printf '%f\n' | LC_ALL=C sort | head -1)
NEWEST=$(find internal/repo/sql -maxdepth 1 -name '*.sql' -printf '%f\n' | LC_ALL=C sort | tail -1)
MIDDLE=$(find internal/repo/sql -maxdepth 1 -name '*.sql' -printf '%f\n' | LC_ALL=C sort | sed -n "$((NFILES / 2))p")

echo "== T go test =="
go test -count=1 -run TestMigratePrint ./internal/repo/ > "$WORK/t.out" 2>&1 || { cat "$WORK/t.out" >&2; fail "T: go test"; }
ok "T $(tail -1 "$WORK/t.out")"

psql "$ADMIN" -XAtq -v ON_ERROR_STOP=1 -c "create database $REF" -c "create database $FRESH" >/dev/null

echo "== A migrate =="
PGVIGIL_REPO_DSN="$ADMIN dbname=$REF" "$BIN" migrate -config "$CFG" 2> "$WORK/a.err" || { cat "$WORK/a.err" >&2; fail "A: migrate"; }
[ "$(q "$REF" "select count(*) from pgvigil.schema_version")" = "$NFILES" ] || fail "A: schema_version does not hold the tree's $NFILES files"
ok "A migrate: $NFILES files"

echo "== B print (fresh) =="
PGVIGIL_REPO_DSN="$ADMIN dbname=$FRESH" "$BIN" migrate -config "$CFG" -print > "$WORK/fresh.sql" 2> "$WORK/b.err" || { cat "$WORK/b.err" >&2; fail "B: -print"; }
grep -q 'nothing was applied' "$WORK/b.err" || fail "B: stderr does not say nothing was applied: $(cat "$WORK/b.err")"
grep -qx -- '-- applied: none (no pgvigil.schema_version: a fresh repository)' "$WORK/fresh.sql" || fail "B: no 'applied: none' line"
grep -qx -- "-- pending: $NFILES file(s): $FIRST .. $NEWEST" "$WORK/fresh.sql" || fail "B: no 'pending: $NFILES file(s): $FIRST .. $NEWEST' line: $(grep -- '-- pending' "$WORK/fresh.sql")"
[ "$(q "$FRESH" "select to_regnamespace('pgvigil') is null")" = "t" ] || fail "B: the print made the pgvigil schema"
ok "B print: $(wc -l < "$WORK/fresh.sql") lines, $NFILES files pending, fresh untouched"

echo "== C apply =="
rc=0; psql "$ADMIN dbname=$FRESH" -X -q -v ON_ERROR_STOP=1 -f "$WORK/fresh.sql" > "$WORK/c.out" 2>&1 || rc=$?
[ "$rc" = 0 ] || { tail -20 "$WORK/c.out" >&2; fail "C: psql exit $rc"; }
[ "$(q "$FRESH" "select count(*) from pgvigil.schema_version")" = "$NFILES" ] || fail "C: schema_version does not hold $NFILES files"
for db in "$REF" "$FRESH"; do
  j=$(q "$db" "select coalesce(string_agg(x, ','), '') from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) x where d.datname = current_database() and s.setrole = 0 and x like 'jit=%'")
  [ "$j" = "jit=off" ] || fail "C: $db's jit setting is '$j', not jit=off"
done
pg_dump "$ADMIN dbname=$REF" -s | grep -vE '^\\(un)?restrict ' > "$WORK/ref.dump"
pg_dump "$ADMIN dbname=$FRESH" -s | grep -vE '^\\(un)?restrict ' > "$WORK/fresh.dump"
diff -q "$WORK/ref.dump" "$WORK/fresh.dump" >/dev/null || { diff "$WORK/ref.dump" "$WORK/fresh.dump" | head -20 >&2; fail "C: pg_dump -s differs"; }
ok "C apply: psql exit 0, $NFILES files, jit=off on both, pg_dump -s the same ($(wc -l < "$WORK/ref.dump") lines)"

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
grep -qF "ARRAY['$MIDDLE', '$NEWEST']" "$WORK/atn.sql" || fail "E: the guard does not name exactly the two"
[ "$(grep -c '^-- file ' "$WORK/atn.sql")" = 2 ] || fail "E: not two files"
grep -q "^-- file $MIDDLE (1 of 2)$" "$WORK/atn.sql" && grep -q "^-- file $NEWEST (2 of 2)$" "$WORK/atn.sql" || fail "E: the files are not $MIDDLE then $NEWEST"
ok "E at N: $MIDDLE and $NEWEST pending, the repository unchanged by the print"

echo "== F guard =="
q "$FRESH" "insert into pgvigil.schema_version (version) values ('$MIDDLE'), ('$NEWEST')" >/dev/null
sv=$(q "$FRESH" "select string_agg(version, ',' order by version) from pgvigil.schema_version")
set +e
psql "$ADMIN dbname=$FRESH" -X -q -v ON_ERROR_STOP=1 -f "$WORK/atn.sql" > "$WORK/f.out" 2>&1; rc=$?
set -e
[ "$rc" = 3 ] || fail "F: psql exit $rc, not 3"
grep -q 'applied since this script was printed' "$WORK/f.out" || fail "F: no guard message: $(tail -3 "$WORK/f.out")"
[ "$(q "$FRESH" "select string_agg(version, ',' order by version) from pgvigil.schema_version")" = "$sv" ] || fail "F: schema_version changed"
ok "F guard: psql exit 3, schema_version unchanged"

echo "== G reader =="
psql "$ADMIN" -XAtq -v ON_ERROR_STOP=1 -c "create role $READER login password '$RPW'" -c "grant connect on database $FRESH to $READER" >/dev/null
q "$FRESH" "grant usage on schema pgvigil to $READER; grant select on pgvigil.schema_version to $READER" >/dev/null
PGVIGIL_REPO_DSN="$ADMIN dbname=$FRESH user=$READER password=$RPW" "$BIN" migrate -config "$CFG" -print > "$WORK/g.sql" 2> "$WORK/g.err" || { cat "$WORK/g.err" >&2; fail "G: -print as the reader"; }
grep -q -- '-- pending: none' "$WORK/g.sql" || fail "G: no 'pending: none'"
ok "G reader: -print as a SELECT-only login"

echo "== H exits =="
set +e
PGVIGIL_REPO_DSN="host=127.0.0.1 port=1 dbname=x connect_timeout=5" "$BIN" migrate -config "$CFG" -print > "$WORK/h1.out" 2>/dev/null; rc1=$?
"$BIN" migrate -config "$WORK/none.yaml" -print > "$WORK/h2.out" 2>/dev/null; rc2=$?
set -e
[ "$rc1" = 1 ] && [ ! -s "$WORK/h1.out" ] || fail "H: a closed port: exit $rc1, stdout $(wc -c < "$WORK/h1.out") bytes"
[ "$rc2" = 3 ] && [ ! -s "$WORK/h2.out" ] || fail "H: no config file: exit $rc2, stdout $(wc -c < "$WORK/h2.out") bytes"
ok "H exits: closed port 1, no config 3, nothing on stdout"

echo "PROOF OK: migrate -print (T A B C D E F G H)"
