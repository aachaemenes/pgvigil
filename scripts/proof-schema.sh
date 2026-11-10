#!/usr/bin/env bash
# Proof of the schema snapshots (migration 0058, internal/collect/schema.go, task 59) on the sandbox: two monitored
# databases of its own, a pg_monitor login that reads them, and reads around DDL.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database, two monitored
#                      databases and a pg_monitor login, all with a random suffix, and drops them at the end. The
#                      schema collection reads every connectable database of the server: every check below is limited
#                      to the proof's own databases.
#
# Expected (written before the first run):
#  A. the baseline: MDB holds table t(a int, b text), index t_b on t(b), view v (select now() AS at: no
#     column of t under it, so the ALTER COLUMN TYPEs below run); collect -once schema:
#     MDB's schema_databases row has objects 6 (schema public, table t, columns t.a and t.b, index t_b, view v),
#     ddl_log 'not installed'; no schema_changes row for MDB (the first read is the baseline).
#  B. CREATE TABLE n (x int PRIMARY KEY), ALTER TABLE t ALTER COLUMN a TYPE bigint, DROP INDEX t_b, GRANT SELECT ON t
#     TO the login; collect: MDB's changes, as change|kind|identity|attribute|before|after (empty = NULL):
#       added|table|public.n|||table                              (its column, key constraint and index fold into it)
#       changed|column|public.t.a|definition|integer|bigint
#       changed|table|public.t|acl||{postgres=arwdDxtm/postgres,<login>=r/postgres}
#       dropped|index|public.t_b||CREATE INDEX t_b ON public.t USING btree (b)|
#     no statement on any of them (the event trigger is not installed); schema_findings for MDB: a warning
#     'schema: an object dropped' naming index public.t_b, and an info 'schema: a definition changed' with
#     '1 added, 2 changed'; public.t_b is kept in schema_objects with is_present false.
#  C. the event trigger installed in MDB as the sandbox superuser (the block 'pgvigil roles' prints, commented out; its
#     text from internal/collect/schema.go until the join wires it into roles), then, one statement per call:
#     ALTER TABLE n ADD COLUMN y text; CREATE INDEX n_y ON n (y); REVOKE SELECT ON t FROM <login>;
#     CREATE FUNCTION f(i int) RETURNS int LANGUAGE sql AS 'select i'; collect: ddl_log 'installed', its table
#     public.pgvigil_ddl_log; this read's changes with their statements:
#       added|column|public.n.y      ALTER TABLE n ADD COLUMN y text
#       added|index|public.n_y       CREATE INDEX n_y ON n (y)
#       changed|table|public.t|acl   REVOKE SELECT ON t FROM <login>   (after: the owner's entry alone, not NULL)
#       added|function|public.f(integer)   CREATE FUNCTION f(i int) ...
#     and the trigger's own objects added without a statement (table public.pgvigil_ddl_log, the function
#     public.pgvigil_ddl_capture(): created before the trigger existed; the table's identity sequence folds into the
#     table [review fold: an owned sequence's parent is its table]); B's four changes still have no statement.
#  D. DROP INDEX n_y and ALTER TABLE t ALTER COLUMN b TYPE varchar(20) in MDB; CREATE TABLE z (i int) in MDB2 (no
#     trigger); collect: MDB dropped|index|public.n_y with statement 'DROP INDEX n_y', changed|column|public.t.b
#     text -> character varying(20) with its ALTER TABLE statement; MDB2 added|table|public.z with no statement and
#     ddl_log 'not installed' (the tab says so).
#  E. a late import_schema (its snapshot an hour before the last read, an empty object list for MDB) changes nothing:
#     MDB's change count and present-object count are unchanged; DROP DATABASE MDB2, collect: MDB2's row is_present
#     false and no 'dropped' change for its objects (a database gone is not its objects dropped); schema_findings
#     rows for MDB: one warning, one info.
#  F. [review fold, expected before the run] the cursor never stalls, and temporary objects are not logged: 6,000 rows
#     inserted into MDB's pgvigil_ddl_log in one statement as the superuser (object_identity 'public.burst', inside one
#     second: more than one page of 5,000 inside the read's hour of overlap), then CREATE TABLE w (i int), and in one
#     session CREATE TEMP TABLE tt (i int) and DROP TABLE tt; collect: MDB's schema_ddl_log holds 6,000 'public.burst'
#     rows, the CREATE TABLE w row, and no pg_temp row; the change added|table|public.w carries
#     'CREATE TABLE w (i int)'; a second collect adds no row (each kept once) and MDB's cursor is at the newest row.
#  The ACLs above carry PostgreSQL 17's MAINTAIN privilege (m): on 16 and older the expected text lacks it.
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM$RANDOM
REPO_DB=pgvigil_schemaproof_$SUF; MDB=pgvigil_schemamon_$SUF; MDB2=pgvigil_schemamon2_$SUF
MON=pgvigil_schemamonitor_$SUF; MONPW=p$RANDOM$RANDOM
CFG=$(mktemp); DDL=$(mktemp); ROLES=$(mktemp)
MADE_DBS=(); MADE_ROLE=
# the cleanup drops only what this run created (a name taken by another run fails its create and is never dropped)
cleanup() {
  rm -f "$CFG" "$DDL" "$ROLES"
  for d in "${MADE_DBS[@]}"; do
    psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true
  done
  [[ -n $MADE_ROLE ]] && psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in "$REPO_DB" "$MDB" "$MDB2"; do
  psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create database $d" >/dev/null || fail "create database $d"
  MADE_DBS+=("$d")
done
psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null || fail "create role $MON"
MADE_ROLE=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export SBX_DSN="$ADMIN_DSN dbname=$MDB user=$MON password=$MONPW"
SU=$(psql "$ADMIN_DSN" -XAt -c "select current_user")
m1() { psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-schema-$SUF
    dsn: env:SBX_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once schema >/dev/null 2>&1 || fail "collect -once schema failed"; }
dbid() { q "select dbid from pgvigil.schema_databases where instance_id = $i and datname = '$1'"; }
# the changes of one database found by the newest read of it, as change|kind|identity|attribute|before|after
newest() {
  q "select c.change || '|' || c.kind || '|' || c.identity || '|' || coalesce(c.attribute, '') || '|' || coalesce(c.before, '') || '|' || coalesce(c.after, '')
       from pgvigil.schema_changes c
      where c.instance_id = $i and c.datname = '$1'
        and c.snapshot_at = (select max(snapshot_at) from pgvigil.schema_changes where instance_id = $i and datname = '$1')
      order by c.change, c.kind, c.identity, c.attribute"
}
# the same through schema_changes_window, with the statement: change|kind|identity|attribute|statement
newest_st() {
  q "select w.change || '|' || w.kind || '|' || w.identity || '|' || coalesce(w.attribute, '') || '|' || coalesce(w.statement, '')
       from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $(dbid "$1")) w
      where w.snapshot_at = (select max(snapshot_at) from pgvigil.schema_changes where instance_id = $i and datname = '$1')
      order by w.change, w.kind, w.identity, w.attribute"
}

echo "--- A. the baseline read"
m1 "create table t (a int, b text); create index t_b on t (b); create view v as select now() as at"
collect
i=$(q "select instance_id from pgvigil.instances where name = 'proof-schema-$SUF'")
A=$(q "select objects || '|' || ddl_log from pgvigil.schema_databases where instance_id = $i and datname = '$MDB'")
echo "MDB: $A"; [[ $A == "6|not installed" ]] || fail "A: objects|ddl_log '$A'"
[[ $(q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'") == 0 ]] || fail "A: a change on the baseline"

echo "--- B. CREATE TABLE, ALTER COLUMN TYPE, DROP INDEX, GRANT"
m1 "create table n (x int primary key)"
m1 "alter table t alter column a type bigint"
m1 "drop index t_b"
m1 "grant select on t to $MON"
collect
B=$(newest "$MDB"); echo "$B"
WANT="added|table|public.n|||table
changed|column|public.t.a|definition|integer|bigint
changed|table|public.t|acl||{$SU=arwdDxtm/$SU,$MON=r/$SU}
dropped|index|public.t_b||CREATE INDEX t_b ON public.t USING btree (b)|"
[[ $B == "$WANT" ]] || fail "B: the changes"
[[ $(newest_st "$MDB" | grep -c '|$') == 4 ]] || fail "B: a statement without the event trigger"
FW=$(q "select detail from pgvigil.schema_findings where instance_id = $i and value = '$MDB' and severity = 'warning' and setting = 'schema: an object dropped'")
FI=$(q "select detail from pgvigil.schema_findings where instance_id = $i and value = '$MDB' and severity = 'info' and setting = 'schema: a definition changed'")
echo "warning: $FW"; echo "info: $FI"
[[ $FW == *"index public.t_b"* ]] || fail "B: the drop finding"
[[ $FI == *"1 added, 2 changed"* ]] || fail "B: the change finding"
[[ $(q "select is_present from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and kind = 'index' and identity = 'public.t_b'") == f ]] || fail "B: the dropped index's row"

echo "--- C. the event trigger, then four statements"
"$BIN" roles > "$ROLES" 2>/dev/null || true
if grep -q pgvigil_ddl_capture "$ROLES"; then
  awk '/^-- CREATE TABLE public.pgvigil_ddl_log/,/^-- CREATE EVENT TRIGGER pgvigil_ddl_drop/' "$ROLES" | sed 's/^-- //' \
    | sed "s/pgvigil_monitor/$MON/g" > "$DDL"
  echo "(the block printed by pgvigil roles)"
else
  awk '/^const SchemaDDLLogSQL = `/{f=1; sub(/^const SchemaDDLLogSQL = `/, "")} f{print} /^CREATE EVENT TRIGGER pgvigil_ddl_drop/{exit}' \
    internal/collect/schema.go | sed "s/<login>/$MON/g" > "$DDL"
  echo "(the block from internal/collect/schema.go: 'pgvigil roles' does not print it yet)"
fi
grep -q "CREATE EVENT TRIGGER pgvigil_ddl_drop" "$DDL" || fail "C: the trigger block was not found"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -f "$DDL" >/dev/null
m1 "ALTER TABLE n ADD COLUMN y text"
m1 "CREATE INDEX n_y ON n (y)"
m1 "REVOKE SELECT ON t FROM $MON"
m1 "CREATE FUNCTION f(i int) RETURNS int LANGUAGE sql AS 'select i'"
collect
C0=$(q "select ddl_log || '|' || ddl_log_table from pgvigil.schema_databases where instance_id = $i and datname = '$MDB'")
echo "MDB: $C0"; [[ $C0 == "installed|public.pgvigil_ddl_log" ]] || fail "C: the trigger's state '$C0'"
C=$(newest_st "$MDB"); echo "$C"
WANT="added|column|public.n.y||ALTER TABLE n ADD COLUMN y text
added|function|public.f(integer)||CREATE FUNCTION f(i int) RETURNS int LANGUAGE sql AS 'select i'
added|function|public.pgvigil_ddl_capture()||
added|index|public.n_y||CREATE INDEX n_y ON n (y)
added|table|public.pgvigil_ddl_log||
changed|table|public.t|acl|REVOKE SELECT ON t FROM $MON"
[[ $C == "$WANT" ]] || fail "C: the changes and their statements"
CA=$(q "select coalesce(after, 'NULL') from pgvigil.schema_changes where instance_id = $i and datname = '$MDB' and identity = 'public.t' and attribute = 'acl' order by snapshot_at desc limit 1")
echo "public.t acl after the REVOKE: $CA"; [[ $CA == "{$SU=arwdDxtm/$SU}" ]] || fail "C: the ACL after the REVOKE"
CB=$(q "select count(*) from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $(dbid "$MDB")) w
         where w.statement is not null and w.snapshot_at < (select max(snapshot_at) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB')")
[[ $CB == 0 ]] || fail "C: B's changes took a statement logged after their read ($CB)"

echo "--- D. a drop and an ALTER COLUMN under the trigger; a database without it"
m1 "DROP INDEX n_y"
m1 "ALTER TABLE t ALTER COLUMN b TYPE varchar(20)"
psql "$ADMIN_DSN dbname=$MDB2" -XAtq -v ON_ERROR_STOP=1 -c "create table z (i int)" >/dev/null
collect   # MDB2's first read was A's (it existed from the start): z is a change
D=$(newest_st "$MDB"); echo "$D"
WANT="changed|column|public.t.b|definition|ALTER TABLE t ALTER COLUMN b TYPE varchar(20)
dropped|index|public.n_y||DROP INDEX n_y"
[[ $D == "$WANT" ]] || fail "D: MDB's changes"
DB=$(q "select before || ' -> ' || after from pgvigil.schema_changes where instance_id = $i and datname = '$MDB' and identity = 'public.t.b'")
echo "public.t.b: $DB"; [[ $DB == "text -> character varying(20)" ]] || fail "D: t.b's before and after"
D2=$(q "select w.change || '|' || w.kind || '|' || w.identity || '|' || coalesce(w.statement, '(none)') || '|' || w.ddl_log
          from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $(dbid "$MDB2")) w")
echo "MDB2: $D2"; [[ $D2 == "added|table|public.z|(none)|not installed" ]] || fail "D: MDB2's change"

echo "--- E. a late read; a database dropped; the findings"
n1=$(q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'")
p1=$(q "select count(*) from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and is_present")
q "select pgvigil.import_schema($i, (select snapshot_at from pgvigil.schema_databases where instance_id = $i and datname = '$MDB') - interval '1 hour',
     json_build_array(json_build_object('kind', 'db', 'dbid', $(dbid "$MDB"), 'datname', '$MDB', 'objects', 0))::jsonb)" >/dev/null
n2=$(q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'")
p2=$(q "select count(*) from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and is_present")
echo "changes $n1 -> $n2, present objects $p1 -> $p2 after a late read"
[[ $n1 == "$n2" && $p1 == "$p2" ]] || fail "E: a late read changed the snapshot"
psql "$ADMIN_DSN" -XAtq -c "drop database $MDB2 with (force)" >/dev/null
collect
E=$(q "select is_present || '|' || (select count(*) from pgvigil.schema_changes c where c.instance_id = $i and c.datname = '$MDB2' and c.change = 'dropped')
         from pgvigil.schema_databases where instance_id = $i and datname = '$MDB2'")
echo "MDB2 present|dropped changes: $E"; [[ $E == "false|0" ]] || fail "E: the dropped database '$E'"
q "select severity || ' | ' || setting || ' | ' || detail from pgvigil.schema_findings where instance_id = $i and value = '$MDB' order by severity desc"
[[ $(q "select string_agg(severity, ',' order by severity) from pgvigil.schema_findings where instance_id = $i and value = '$MDB'") == "info,warning" ]] || fail "E: the findings of MDB"

echo "--- F. a burst over one page, a temp table"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "insert into public.pgvigil_ddl_log (event, command_tag, object_type, schema_name, object_identity, statement)
  select 'ddl_command_end', 'COMMENT', 'table', 'public', 'public.burst', 'COMMENT ON TABLE burst IS ''' || g || '''' from generate_series(1, 6000) g" >/dev/null
m1 "CREATE TABLE w (i int)"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "CREATE TEMP TABLE tt (i int)" -c "DROP TABLE tt" >/dev/null
collect
mdbid=$(dbid "$MDB")
F1=$(q "select count(*) filter (where object_identity = 'public.burst') || '|' || count(*) filter (where statement = 'CREATE TABLE w (i int)')
          || '|' || count(*) filter (where schema_name = 'pg_temp' or object_identity like 'pg_temp.%')
          from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid")
F2=$(q "select coalesce(w.statement, '(none)') from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $mdbid) w
         where w.identity = 'public.w' and w.change = 'added'")
echo "burst|w|temp rows: $F1; public.w: $F2"
[[ $F1 == "6000|1|0" ]] || fail "F: the log rows '$F1'"
[[ $F2 == "CREATE TABLE w (i int)" ]] || fail "F: the statement of public.w '$F2'"
n1=$(q "select count(*) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid")
collect
n2=$(q "select count(*) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid")
F3=$(q "select c.read_to = (select max(snapshot_at) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid)
          from pgvigil.log_cursor c where c.instance_id = $i and c.source = 'schema_ddl:$MDB'")
echo "log rows $n1 -> $n2 after a second read; the cursor at the newest row: $F3"
[[ $n1 == "$n2" && $F3 == t ]] || fail "F: the second read"

echo "PASS: proof-schema (A the baseline: 6 objects, no change; B CREATE TABLE folded, ALTER COLUMN TYPE integer -> bigint, DROP INDEX with its definition, GRANT's ACL before and after, the two findings; C the event trigger installed: each change with its statement, the REVOKE matched by name, earlier changes untouched; D DROP INDEX and ALTER COLUMN with their statements, a database without the trigger: not installed; E a late read changes nothing, a dropped database drops no object; F a burst of 6,000 log rows read in pages, the statement after it found, no temp-table row, each row kept once)"
