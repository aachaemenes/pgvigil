#!/usr/bin/env bash
# proof-app-import.sh - task 312, the applications inventory's file round trip (migration 0146, q_app_import.go,
# the Inventory grid and Import section of web/src/applications.ts). A throwaway repository on the PostgreSQL that
# PGVIGIL_ADMIN_DSN names (a superuser, as the box's container gives it); PGVIGIL_BIN a binary of this tree.
# Every row prints 'ok' or 'FAIL'; the last line counts the FAILs. IMP_ONLY=<letters> runs those sections alone.
#
# Section M, the import-never-overwrites rule (review A m3 and the 312 pass, 2): 0136's writes called as a login IN
# ROLE pgvigil_collector with source import:proof, unforced, against rows a person entered:
#  M1 an unassign of an entered assignment: refused 'conflict', the row kept
#  M2 an unmark of an entered mark: refused 'conflict', the mark kept
#  M3 a same-application re-assign with another environment over an entered row: refused, the environment kept
#  M4 a database-level assign under an entered server-level assignment of another application: refused
#  M5 a remove of an application whose contact was entered: refused, the application and its contact kept
#  M6 a contact's ord changed by an import over an entered contact: refused, the ord kept
#  M7 an import's re-assign that changes nothing (same application, no environment): no write - set_at, set_by and
#     the audit count unchanged, the source still the import's
#  M8 a person's re-assign of an imported row takes it over: source 'entered'
#  M9 each of M1-M6 forced (force true): done - the refusals are the rule's, not a broken write
#  M10 an application named '(none)' (the file's unassign token) refused in words
# On a tree without 0146 M1-M7 and M10 FAIL: the red run (6a3b56b).
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
ONLY=${IMP_ONLY:-}
want() { [[ -z "$ONLY" || "$ONLY" == *"$1"* ]]; }
SUF=$RANDOM
DB=pgvigil_proof_imp_$SUF; COLL=pgvigil_imp_col_$SUF
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml
NFAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; NFAIL=$((NFAIL + 1)); }
cleanup() {
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" -c "drop role if exists $COLL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || { echo "FAIL setup: create database"; exit 1; }
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q()  { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { echo "FAIL setup: migrate"; tail -5 "$WORK/migrate.out"; exit 1; }
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create role $COLL login in role pgvigil_collector" > "$WORK/coll.out" 2>&1 \
  || { echo "FAIL setup: the collector login ($(tail -1 "$WORK/coll.out"))"; exit 1; }
qc() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB user=$COLL" -XAt -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
# a write as a person (the superuser, source entered) and as an import (the collector login, source import:proof)
wp() { q "select pgvigil.import_app_$1(now(), '{\"ui_user\": \"person\", \"client\": \"proof\"}'::jsonb || '$2'::jsonb)"; }
wi() { qc "select pgvigil.import_app_$1(now(), '{\"ui_user\": \"importer\", \"client\": \"proof\", \"source\": \"import:proof\"}'::jsonb || '$2'::jsonb)"; }
field() { python3 -I -c 'import json, sys
try: v = json.loads(sys.argv[1]).get(sys.argv[2])
except Exception: v = "(not json: " + sys.argv[1][:120] + ")"
print("" if v is None else v)' "$1" "$2"; }
pgdb() { printf '{"dbid": %s, "datname": "%s", "is_template": false, "allow_conn": true, "can_connect": true, "size_bytes": 1}' "$1" "$2"; }
dbs()  { q "select pgvigil.import_databases($1, now(), '$2'::jsonb)" >/dev/null; }
newinst() { q "select pgvigil.ensure_instance('$1', 'onprem', '18.0', 180000, false, '{}'::text[])"; }
HAS0146=$(q "select to_regprocedure('pgvigil.import_app_file(timestamptz, jsonb)') is not null")
echo "read: 0146 on this tree: $HAS0146"

# ================= M: the import-never-overwrites rule =================
if want M; then
MI=$(newinst proof-imp-m); dbs "$MI" "[$(pgdb 70001 m1), $(pgdb 70002 m2), $(pgdb 70003 m3), $(pgdb 70004 m4)]"
MI2=$(newinst proof-imp-m2); dbs "$MI2" "[$(pgdb 70011 n1)]"
EA=$(field "$(wp application '{"op": "add", "name": "M Entered"}')" app_id)
EB=$(field "$(wp application '{"op": "add", "name": "M Other"}')" app_id)
# entered rows: m1 assigned to EA (production), m2 marked, the server MI2 assigned to EA, m3 assigned to EA by an import
wp assign "{\"op\": \"assign\", \"app_id\": $EA, \"environment\": \"production\", \"targets\": [{\"instance_id\": $MI, \"database\": \"m1\"}]}" >/dev/null
wp assign "{\"op\": \"mark\", \"targets\": [{\"instance_id\": $MI, \"database\": \"m2\"}]}" >/dev/null
wp assign "{\"op\": \"assign\", \"app_id\": $EA, \"targets\": [{\"instance_id\": $MI2, \"database\": null}]}" >/dev/null
wi assign "{\"op\": \"assign\", \"app_id\": $EA, \"targets\": [{\"instance_id\": $MI, \"database\": \"m3\"}]}" >/dev/null
# an application the import made, with a contact a person entered; a contact of EA a person entered
IA=$(field "$(wi application '{"op": "add", "name": "M Imported"}')" app_id)
IC=$(field "$(wp contact "{\"op\": \"add\", \"app_id\": ${IA:-0}, \"role\": \"support\", \"kind\": \"team\", \"name\": \"M Team\", \"email\": \"m-team@example.org\"}")" contact_id)
EC=$(field "$(wp contact "{\"op\": \"add\", \"app_id\": $EA, \"role\": \"support\", \"kind\": \"team\", \"name\": \"M Team 2\", \"email\": \"m-team2@example.org\"}")" contact_id)
asg_of() { q "select coalesce((select app_id || '|' || coalesce(environment, '-') || '|' || source from pgvigil.app_assignments where instance_id = $1 and coalesce(database_name, '') = coalesce($2, '')), 'none')"; }
[[ -n $EA && -n $EB && -n $IA && -n $IC && -n $EC && $(asg_of "$MI" "'m1'") == "$EA|production|entered" && $(asg_of "$MI" "'m3'") == "$EA|-|import:proof" ]] \
  || bad "M setup: applications '$EA' '$EB' '$IA', contacts '$IC' '$EC'; m1 $(asg_of "$MI" "'m1'"), m3 $(asg_of "$MI" "'m3'")"
conflicted() { [[ $(field "$1" outcome) == refused && $(field "$1" detail) == *conflict* ]]; }
# M1
a=$(wi assign "{\"op\": \"unassign\", \"app_id\": $EA, \"targets\": [{\"instance_id\": $MI, \"database\": \"m1\"}]}")
conflicted "$a" && [[ $(asg_of "$MI" "'m1'") == "$EA|production|entered" ]] && ok "M1 an import's unassign of an entered assignment: refused 'conflict', kept" || bad "M1 '$a'; m1 now $(asg_of "$MI" "'m1'")"
# M2
a=$(wi assign "{\"op\": \"unmark\", \"targets\": [{\"instance_id\": $MI, \"database\": \"m2\"}]}")
marked=$(q "select count(*) from pgvigil.app_not_application where instance_id = $MI and database_name = 'm2'")
conflicted "$a" && [[ $marked == 1 ]] && ok "M2 an import's unmark of an entered mark: refused 'conflict', kept" || bad "M2 '$a'; marks $marked"
# M3
a=$(wi assign "{\"op\": \"assign\", \"app_id\": $EA, \"environment\": \"test\", \"targets\": [{\"instance_id\": $MI, \"database\": \"m1\"}]}")
conflicted "$a" && [[ $(asg_of "$MI" "'m1'") == "$EA|production|entered" ]] && ok "M3 an import's same-application re-assign with another environment over an entered row: refused, production kept" || bad "M3 '$a'; m1 now $(asg_of "$MI" "'m1'")"
# M4
a=$(wi assign "{\"op\": \"assign\", \"app_id\": $EB, \"targets\": [{\"instance_id\": $MI2, \"database\": \"n1\"}]}")
conflicted "$a" && [[ $(asg_of "$MI2" "'n1'") == none ]] && ok "M4 an import's database-level assign under an entered server-level assignment of another application: refused" || bad "M4 '$a'; n1 now $(asg_of "$MI2" "'n1'")"
# M5
a=$(wi application "{\"op\": \"remove\", \"app_id\": ${IA:-0}, \"version\": 1, \"with_assignments\": true}")
left=$(q "select (select count(*) from pgvigil.app_applications where app_id = ${IA:-0}) || '|' || (select count(*) from pgvigil.ui_app_contacts where contact_id = ${IC:-0})")
conflicted "$a" && [[ $left == "1|1" ]] && ok "M5 an import's remove of an application whose contact a person entered: refused, both kept" || bad "M5 '$a'; application|contact left $left"
# M6
ord0=$(q "select ord from pgvigil.ui_app_contacts where contact_id = ${EC:-0}")
a=$(wi contact "{\"op\": \"edit\", \"app_id\": $EA, \"contact_id\": ${EC:-0}, \"ord\": 9}")
conflicted "$a" && [[ $(q "select ord from pgvigil.ui_app_contacts where contact_id = ${EC:-0}") == "$ord0" ]] && ok "M6 an import's change of an entered contact's ord: refused, ord $ord0 kept" || bad "M6 '$a'; ord $ord0 -> $(q "select ord from pgvigil.ui_app_contacts where contact_id = ${EC:-0}")"
# M7
st0=$(q "select set_at || '|' || set_by from pgvigil.app_assignments where instance_id = $MI and database_name = 'm3'"); au0=$(q "select count(*) from pgvigil.admin_audit")
a=$(wi assign "{\"op\": \"assign\", \"app_id\": $EA, \"targets\": [{\"instance_id\": $MI, \"database\": \"m3\"}]}")
st1=$(q "select set_at || '|' || set_by from pgvigil.app_assignments where instance_id = $MI and database_name = 'm3'"); au1=$(q "select count(*) from pgvigil.admin_audit")
[[ $(field "$a" outcome) == done && $st1 == "$st0" && $au1 == "$au0" && $(asg_of "$MI" "'m3'") == "$EA|-|import:proof" ]] \
  && ok "M7 an import's re-assign that changes nothing: no write (set_at / set_by kept, no audit row), still the import's" || bad "M7 '$a'; set $st0 -> $st1; audit $au0 -> $au1; m3 $(asg_of "$MI" "'m3'")"
# M8
wp assign "{\"op\": \"assign\", \"app_id\": $EA, \"targets\": [{\"instance_id\": $MI, \"database\": \"m3\"}]}" >/dev/null
[[ $(asg_of "$MI" "'m3'") == "$EA|-|entered" ]] && ok "M8 a person's re-assign of an imported row takes it over as entered" || bad "M8 m3 $(asg_of "$MI" "'m3'")"
# M9: the same writes forced
f1=$(wi assign "{\"op\": \"unassign\", \"force\": true, \"app_id\": $EA, \"targets\": [{\"instance_id\": $MI, \"database\": \"m1\"}]}")
f2=$(wi assign "{\"op\": \"unmark\", \"force\": true, \"targets\": [{\"instance_id\": $MI, \"database\": \"m2\"}]}")
f4=$(wi assign "{\"op\": \"assign\", \"force\": true, \"app_id\": $EB, \"targets\": [{\"instance_id\": $MI2, \"database\": \"n1\"}]}")
f6=$(wi contact "{\"op\": \"edit\", \"force\": true, \"app_id\": $EA, \"contact_id\": ${EC:-0}, \"ord\": 9}")
f5=$(wi application "{\"op\": \"remove\", \"force\": true, \"app_id\": ${IA:-0}, \"version\": 1, \"with_assignments\": true}")
o9="$(field "$f1" outcome) $(field "$f2" outcome) $(field "$f4" outcome) $(field "$f6" outcome) $(field "$f5" outcome)"
[[ $o9 == "done done done done done" ]] && ok "M9 the same imports forced: done (unassign, unmark, the database under the server, ord, remove)" || bad "M9 outcomes '$o9' ($(field "$f5" detail))"
# M10
a=$(wp application '{"op": "add", "name": "(none)"}')
[[ $(field "$a" outcome) == refused && $(q "select count(*) from pgvigil.app_applications where name = '(none)'") == 0 ]] \
  && ok "M10 an application named '(none)' (the file's unassign token) refused ('$(field "$a" detail | cut -c1-90)')" || bad "M10 '$a'"
fi

echo "proof-app-import: $NFAIL FAIL"
[[ $NFAIL == 0 ]]
