#!/usr/bin/env bash
# Proof of the custom checks (migration 0060, internal/collect/custom.go, internal/web/q_custom.go, task 61) on the
# sandbox: a monitored database of its own with one table, a pg_monitor login granted SELECT on it, two instance entries
# on that database with different tags, and a custom: list.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database, a monitored
#                      database and a pg_monitor login, all with a random suffix, and drops them at the end.
#   PGVIGIL_BIN        the binary (default bin/pgvigil); it must carry the join's wiring (loadConfig calls
#                      collect.LoadCustomChecks): without it collect -once custom exits 0 with "skipped", registers no
#                      instance, and step A stops on "A: no instance registered".
#
# Expected (written before the first run):
#  0. go test -run TestCustomRunSandbox as the pg_monitor login: PASS (a value check at warning, a rows check over 100
#     rows kept as 100, rows not kept under query_text none, CREATE TABLE refused 'read-only transaction', two statements
#     refused, a set_config inside a check leaves the session read only, 1/0 an error, a missing value column an error, a
#     text value an error, no row = ok with the note 'no row').
#  A. the table empty; instance a (tag env:proofprod) and b (tag env:proofdev); checks value_n (count, a only, warning 2
#     critical 5), rows_n (rows n > 100, a only, rows rule, warning 0 critical 2), err_div (SELECT 1/0, a only),
#     write_try (DELETE ... RETURNING, a only), tag_dev (SELECT 42, tags [env:proofdev], critical 40). One collect of each:
#     a's results: err_div|error, rows_n|ok|0, value_n|ok|0, write_try|error; err_div's error has 'division by zero',
#     write_try's 'read-only transaction'; the table still has 0 rows. b: tag_dev|critical|42 and nothing else; a has no
#     tag_dev row. custom_findings: a = err_div warning, write_try warning; b = tag_dev critical.
#  B. three rows n = 1, 2, 3; collect a: value_n warning 3, rows_n ok 0; findings of a gain value_n warning.
#  C. three rows n = 101, 102, 103; collect a: value_n critical 6, rows_n critical 3 rows kept with columns ["n"] and
#     rows [[101],[102],[103]]; findings of a: value_n critical, rows_n critical, err_div and write_try warning.
#  D. the chart's series (custom_series over the last hour, 60 s steps, what /api/custom serves): value_n's points sum to
#     3 runs and the largest is 6 (compare >); the raw runs of value_n in order: 0,3,6. The report (custom_report, the
#     root's /api/custom): 5 rows, the first critical; tag_dev on b only.
#  E. [review 2 fold] value_n's runs moved 90 s back (one and a half cadences): not overdue. Then
#     not run in two cadences: value_n's runs moved 3 minutes back (its cadence is 1m) while its last listing stays now
#     (the collection still visits): custom_status overdue true for value_n only; custom_findings of a holds 'custom check
#     value_n' '(not run)'. [review fold, expected before the rerun] E2: a collection that stops visiting (switched off,
#     disabled on the instance, failing to connect) lists nothing: value_n's last listing set back to its last run (3
#     minutes ago): overdue false, no '(not run)' finding (the old rule, measured from now(), fired here forever).
#  F. rows_n taken off the list, collect a: custom_checks rows_n is_present false, no finding of rows_n, the report has 4
#     rows; then custom: [] and a collect of each: every check of a and b gone, the report empty, no custom finding.
#  F2. [join review fold, expected before the run] the checks back on the list, a collect: a's error findings are back;
#     then the custom: key removed (the collection off, nothing listed): the findings stay while the latest listing is
#     within two cadences (at least 5 minutes), and with the listings set 11 minutes back (past two 5-minute cadences, the default) every custom finding of a and b
#     is gone (0), the threshold and error arms included.
#  H. [join review fold, expected before the run] an instance whose DSN is a superuser, with a check on it: collect -once
#     custom on it fails (non-zero) naming 'superuser', and no custom result is stored for it.
#  G. the catalogue: every check of docs/custom.md (18) on instance a, one collect: 18 results; not one error; cluster_id
#     critical (the placeholder id is not the sandbox's).
#     [review 2 fold, expected before the rerun] the monitored database first gets rows for the checks that returned
#     none: a sequence over the whole bigint range (the sequence check overflowed on it) and one at 95 of 100 (both
#     readable by the login), a disabled trigger, a table of 40000 rows with 30000 deleted (autovacuum off on it), a
#     session idle in transaction holding a lock and a second session waiting on it. Then: sequence critical 94.95,
#     disabled_triggers warning 1, bloat warning 1, txn_idle, lockwait and locks with a value (not '-'). prepared_txns
#     keeps no row: max_prepared_transactions is 0 on the sandbox (its SQL is planned, not computed on a row).
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_customproof_$SUF; MDB=pgvigil_custommon_db_$SUF; MON=pgvigil_custommon_$SUF; MONPW=p$RANDOM$RANDOM
A=proof-custom-a-$SUF; B=proof-custom-b-$SUF
CFG=$(mktemp)
BGPIDS=()
cleanup() {
  for p in "${BGPIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  psql "$ADMIN_DSN" -XAtq -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'pgvigil_customproof_$SUF'" >/dev/null 2>&1 || true
  rm -f "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $MDB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" -c "create database $MDB" \
  -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
psql "$ADMIN_DSN dbname=$MDB" -XAtq -c "create table t_proof (n int)" -c "grant select, delete on t_proof to $MON" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export SBX_DSN="$ADMIN_DSN dbname=$MDB user=$MON password=$MONPW"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
m() { psql "$ADMIN_DSN dbname=$MDB" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

head_cfg() {
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $A
    dsn: env:SBX_DSN
    tags: [env:proofprod]
  - name: $B
    dsn: env:SBX_DSN
    tags: [env:proofdev]
EOF
}
checks_cfg() {   # $1 = 1: rows_n is on the list
  head_cfg
  cat >> "$CFG" <<EOF
custom:
  - name: value_n
    sql: SELECT count(*) AS value FROM t_proof
    every: 1m
    instances: [$A]
    warning: 2
    critical: 5
  - name: err_div
    sql: SELECT 1/0 AS value
    instances: [$A]
  - name: write_try
    description: a write-shaped statement (the grant lets the login delete; the read-only transaction refuses it)
    sql: DELETE FROM t_proof RETURNING n
    rule: rows
    instances: [$A]
  - name: tag_dev
    sql: SELECT 42 AS value
    tags: [env:proofdev]
    critical: 40
EOF
  if [[ $1 == 1 ]]; then cat >> "$CFG" <<EOF
  - name: rows_n
    sql: SELECT n FROM t_proof WHERE n > 100 ORDER BY n
    rule: rows
    instances: [$A]
    warning: 0
    critical: 2
EOF
  fi
}
collect() { "$BIN" collect -config "$CFG" -once custom -instance "$1" >/dev/null 2>&1 || fail "collect -once custom -instance $1 failed: $("$BIN" collect -config "$CFG" -once custom -instance "$1" 2>&1 | tail -3)"; }
latest() { q "select check_name || '|' || status || coalesce('|' || pgvigil.custom_fmt(value), '') from pgvigil.custom_status
               where instance_id = $1 order by check_name"; }
findings() { q "select substr(setting, 14) || '|' || severity || '|' || value from pgvigil.custom_findings where instance_id = $1 order by 1"; }

echo "--- 0. the run rules as the pg_monitor login (go test)"
PGVIGIL_CUSTOM_TEST_DSN="$SBX_DSN" go test ./internal/collect/ -run 'TestCustomRunSandbox' -count=1 -v 2>&1 | grep -E '^(--- |ok|FAIL|PASS)' \
  | tee /dev/stderr | grep -q -- '--- PASS: TestCustomRunSandbox' || fail "0: TestCustomRunSandbox"

echo "--- A. an empty table, one collect of each instance"
checks_cfg 1
"$BIN" migrate -config "$CFG" >/dev/null
collect "$A"; collect "$B"
ia=$(q "select instance_id from pgvigil.instances where name = '$A'"); ib=$(q "select instance_id from pgvigil.instances where name = '$B'")
[[ -n $ia && -n $ib ]] || fail "A: no instance registered: PGVIGIL_BIN lacks the custom: wiring (collect.LoadCustomChecks in loadConfig)"
LA=$(latest "$ia"); echo "$LA"
[[ $LA == $'err_div|error\nrows_n|ok|0\nvalue_n|ok|0\nwrite_try|error' ]] || fail "A: a's results"
e1=$(q "select error from pgvigil.custom_status where instance_id = $ia and check_name = 'err_div'")
e2=$(q "select error from pgvigil.custom_status where instance_id = $ia and check_name = 'write_try'")
echo "err_div: $e1"; echo "write_try: $e2"
[[ $e1 == *"division by zero"* && $e2 == *"read-only transaction"* ]] || fail "A: the errors"
[[ $(m "select count(*) from t_proof") == 0 ]] || fail "A: the table changed"
LB=$(latest "$ib"); echo "$LB"; [[ $LB == "tag_dev|critical|42" ]] || fail "A: b's results"
FA=$(findings "$ia"); FB=$(findings "$ib"); echo "$FA"; echo "$FB"
[[ $FA == $'err_div|warning|(error)\nwrite_try|warning|(error)' && $FB == "tag_dev|critical|42" ]] || fail "A: findings"

echo "--- B. three rows"
m "insert into t_proof values (1), (2), (3)" >/dev/null
collect "$A"
LA=$(latest "$ia"); echo "$LA"
[[ $LA == $'err_div|error\nrows_n|ok|0\nvalue_n|warning|3\nwrite_try|error' ]] || fail "B: a's results"
[[ $(m "select count(*) from t_proof") == 3 ]] || fail "B: the write check deleted rows"
[[ $(findings "$ia") == *"value_n|warning|3"* ]] || fail "B: the value_n warning finding"

echo "--- C. three rows over 100"
m "insert into t_proof values (101), (102), (103)" >/dev/null
collect "$A"
LA=$(latest "$ia"); echo "$LA"
[[ $LA == $'err_div|error\nrows_n|critical|3\nvalue_n|critical|6\nwrite_try|error' ]] || fail "C: a's results"
R=$(q "select columns::text || ' ' || rows::text || ' ' || rows_kept from pgvigil.custom_status where instance_id = $ia and check_name = 'rows_n'")
echo "rows_n: $R"; [[ $R == '["n"] [[101], [102], [103]] true' ]] || fail "C: rows_n's rows"
FA=$(findings "$ia"); echo "$FA"
[[ $FA == $'err_div|warning|(error)\nrows_n|critical|3\nvalue_n|critical|6\nwrite_try|warning|(error)' ]] || fail "C: findings"
q "select detail from pgvigil.custom_findings where instance_id = $ia and setting = 'custom check value_n'"

echo "--- D. the chart's series and the report"
S=$(q "select sum(runs) || '|' || pgvigil.custom_fmt(max(value)) from pgvigil.custom_series($ia, now() - interval '1 hour', now() + interval '1 minute', 60) where check_name = 'value_n'")
RAW=$(q "select string_agg(pgvigil.custom_fmt(value), ',' order by snapshot_at) from pgvigil.custom_results where instance_id = $ia and check_name = 'value_n'")
echo "series runs|max: $S; raw: $RAW"; [[ $S == "3|6" && $RAW == "0,3,6" ]] || fail "D: the series"
REP=$(q "select instance || '|' || check_name || '|' || status from pgvigil.custom_report() where instance in ('$A', '$B')")
echo "$REP"
[[ $(wc -l <<<"$REP") == 5 && $(head -1 <<<"$REP") == *"|critical" ]] || fail "D: the report"
[[ $(grep -c '|tag_dev|' <<<"$REP") == 1 && $REP == *"$B|tag_dev|critical"* ]] || fail "D: tag_dev on b only"

echo "--- E. not run in two cadences"
q "update pgvigil.custom_results set snapshot_at = snapshot_at - interval '90 seconds' where instance_id = $ia and check_name = 'value_n'" >/dev/null
O=$(q "select coalesce(string_agg(check_name, ','), '-') from pgvigil.custom_status where instance_id = $ia and overdue")
echo "90 s behind (1.5 cadences): overdue: $O"; [[ $O == - ]] || fail "E: overdue at 1.5 cadences"
q "update pgvigil.custom_results set snapshot_at = snapshot_at - interval '90 seconds' where instance_id = $ia and check_name = 'value_n'" >/dev/null
O=$(q "select string_agg(check_name, ',') from pgvigil.custom_status where instance_id = $ia and overdue")
N=$(q "select count(*) from pgvigil.custom_findings where instance_id = $ia and setting = 'custom check value_n' and value = '(not run)'")
echo "overdue: $O; not-run findings: $N"; [[ $O == value_n && $N == 1 ]] || fail "E"
q "update pgvigil.custom_checks c set snapshot_at = (select max(r.snapshot_at) from pgvigil.custom_results r
     where r.instance_id = c.instance_id and r.check_name = c.check_name) where c.instance_id = $ia and c.check_name = 'value_n'" >/dev/null
O=$(q "select coalesce(string_agg(check_name, ','), '-') from pgvigil.custom_status where instance_id = $ia and overdue")
N=$(q "select count(*) from pgvigil.custom_findings where instance_id = $ia and value = '(not run)'")
echo "E2 a collection that stopped visiting: overdue: $O; not-run findings: $N"; [[ $O == - && $N == 0 ]] || fail "E2"

echo "--- F. a check taken off the list, then custom: []"
checks_cfg 0
collect "$A"
G=$(q "select is_present from pgvigil.custom_checks where instance_id = $ia and check_name = 'rows_n'")
NF=$(q "select count(*) from pgvigil.custom_findings where instance_id = $ia and setting = 'custom check rows_n'")
NR=$(q "select count(*) from pgvigil.custom_report() where instance in ('$A', '$B')")
echo "rows_n present: $G; its findings: $NF; report rows: $NR"; [[ $G == f && $NF == 0 && $NR == 4 ]] || fail "F: rows_n gone"
head_cfg; echo "custom: []" >> "$CFG"
collect "$A"; collect "$B"
P=$(q "select count(*) from pgvigil.custom_checks where instance_id in ($ia, $ib) and is_present")
NR=$(q "select count(*) from pgvigil.custom_report() where instance in ('$A', '$B')")
NF=$(q "select count(*) from pgvigil.custom_findings where instance_id in ($ia, $ib)")
echo "present: $P; report rows: $NR; findings: $NF"; [[ $P == 0 && $NR == 0 && $NF == 0 ]] || fail "F: custom: []"

echo "--- F2. the custom: key removed"
checks_cfg 0
collect "$A"; collect "$B"
NF1=$(q "select count(*) from pgvigil.custom_findings where instance_id in ($ia, $ib)")
head_cfg
"$BIN" collect -config "$CFG" -once custom -instance "$A" >/dev/null 2>&1 || fail "F2: collect without the key"
NF2=$(q "select count(*) from pgvigil.custom_findings where instance_id in ($ia, $ib)")
q "update pgvigil.custom_checks set snapshot_at = snapshot_at - interval '11 minutes' where instance_id in ($ia, $ib)" >/dev/null
NF3=$(q "select count(*) from pgvigil.custom_findings where instance_id in ($ia, $ib)")
echo "findings: listed $NF1; key removed $NF2; listings 11 minutes old $NF3"
[[ $NF1 -ge 3 && $NF2 == "$NF1" && $NF3 == 0 ]] || fail "F2"

echo "--- G. the catalogue of docs/custom.md"
head_cfg; echo "custom:" >> "$CFG"
awk '/^```yaml$/ {on = 1; next} /^```$/ {on = 0} on' docs/custom.md | awk '/^  - name: idle_in_transaction/ {skip = 1} /^  - name: / && !/idle_in_transaction/ {skip = 0} !skip' \
  | grep -v '^custom:$' | sed "s/^  - name: \(.*\)$/  - name: \1\n    instances: [$A]/" >> "$CFG"
n=$(sed -n '/^custom:$/,$p' "$CFG" | grep -c '^  - name: ')
echo "catalogue checks: $n"; [[ $n == 18 ]] || fail "G: the catalogue has $n checks"
m "create sequence s_wide minvalue -9223372036854775808; select nextval('s_wide');
   create sequence s_full maxvalue 100; select setval('s_full', 95);
   grant select on s_wide, s_full to $MON;
   create function f_proof() returns trigger language plpgsql as \$\$ begin return new; end \$\$;
   create trigger trg_proof before insert on t_proof for each row execute function f_proof();
   alter table t_proof disable trigger trg_proof;
   create table t_bloat with (autovacuum_enabled = off) as select g from generate_series(1, 40000) g;
   create table t_lock (a int)" >/dev/null
m "delete from t_bloat where g <= 30000" >/dev/null
( printf 'BEGIN;\nLOCK TABLE t_lock IN ACCESS EXCLUSIVE MODE;\n'; sleep 60 ) \
  | PGAPPNAME=pgvigil_customproof_$SUF psql "$ADMIN_DSN dbname=$MDB" -XAtq >/dev/null 2>&1 & BGPIDS+=($!)
sleep 1
( printf 'SELECT count(*) FROM t_lock;\n'; sleep 60 ) \
  | PGAPPNAME=pgvigil_customproof_$SUF psql "$ADMIN_DSN dbname=$MDB" -XAtq >/dev/null 2>&1 & BGPIDS+=($!)
sleep 2
collect "$A"
C=$(q "select count(*) || '|' || count(*) filter (where r.status = 'error')
         from pgvigil.custom_results r join pgvigil.custom_checks c using (instance_id, check_name)
        where r.instance_id = $ia and c.is_present")
q "select check_name || '|' || status || '|' || coalesce(pgvigil.custom_fmt(value), '-') || coalesce('|' || error, '') from pgvigil.custom_status where instance_id = $ia order by 1"
echo "results|errors: $C"; [[ $C == "18|0" ]] || fail "G: the catalogue's runs"
[[ $(q "select status from pgvigil.custom_status where instance_id = $ia and check_name = 'cluster_id'") == critical ]] || fail "G: cluster_id"
V=$(q "select string_agg(check_name || '|' || status || '|' || coalesce(pgvigil.custom_fmt(value), '-'), ',' order by check_name)
         from pgvigil.custom_status where instance_id = $ia and check_name in ('sequence', 'disabled_triggers', 'bloat')")
echo "seeded: $V"; [[ $V == "bloat|warning|1,disabled_triggers|warning|1,sequence|critical|94.95" ]] || fail "G: the seeded checks"
for c in txn_idle lockwait locks; do
  v=$(q "select coalesce(pgvigil.custom_fmt(value), '-') from pgvigil.custom_status where instance_id = $ia and check_name = '$c'")
  echo "$c: $v"; [[ $v != - ]] || fail "G: $c computed no value on its row"
done

echo "--- H. a superuser login is refused"
export SU_DSN="$ADMIN_DSN dbname=$MDB"
head_cfg
cat >> "$CFG" <<EOF
  - name: proof-custom-su-$SUF
    dsn: env:SU_DSN
custom:
  - name: su_check
    sql: SELECT 1 AS value
    instances: [proof-custom-su-$SUF]
EOF
set +e; OUT=$("$BIN" collect -config "$CFG" -once custom -instance "proof-custom-su-$SUF" 2>&1); rc=$?; set -e
isu=$(q "select instance_id from pgvigil.instances where name = 'proof-custom-su-$SUF'")
NRS=$(q "select count(*) from pgvigil.custom_results where instance_id = ${isu:-0}")
echo "exit $rc; results $NRS; $(grep -o 'custom checks refused[^;]*' <<<"$OUT" | head -1)"
[[ $rc != 0 && $OUT == *"the login is superuser"* && $NRS == 0 ]] || fail "H: a superuser login"
echo "PASS: proof-custom"
