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
#  M11 (R4's mark arm, as built) an import's mark of a database a person marked: done, nothing written, the mark the
#      person's;  M12 (review A, M4) a payload whose line numbers repeat: refused in words
# On a tree without 0146 M1-M7 and M10 FAIL: the red run (6a3b56b).
#
# Section F, the file through the API (a serve whose reads are a login IN ROLE pgvigil_reader, pgvigil_auth and whose
# writes go through a login IN ROLE pgvigil_collector; a PostgreSQL server and a SQL Server one):
#  F1  (R1, R15, R7's keys) the CSV export (BOM, attachment) imported as it is: absent databases on both engines, an
#      inheriting database blank with its inherited_from, keys '=x' / '-name' guarded - 0 adds, changes, conflicts,
#      unknown, refused; applied: the app_* rows' md5 (never last_seen / engine_db_id) the same, one summary audit row
#  F2  (R2) an add, changes on both engines, a conflict, an unknown server: previewed exactly, applied unticked - the
#      conflict kept, no server made;  F3 (R3) the conflict ticked: applied, source import:proof
#  F4  (R5) a page write between the preview and the apply: refused whole;  F5 (R5b) a collector list read between
#      them: not refused
#  F6  (R6) the export as a semicolon file under the bar's two mark lines: no change
#  F7  (R7) '=SUM(1)' and "'=x" descriptions: stored as typed, guarded in the CSV, read back with no change
#  F8  (R8, the API half) no contact, user name or client address in the CSV or the grid's answer; an email / owner
#      column of an imported file listed as not read, no contact made
#  F9  (R9) no login 401, no header 403 (the import), no login 401 (the CSV); nothing written
#  F10 (R10, R20) an .xlsx with shared strings, blank cells left out, a boolean 'no', a number 2024: no change
#  F11 (R11) refused lines with their numbers; F12 (R12) audit rows: none for a dry run or a refused line, one per
#      change and one summary; F13 (R13) over 5 MB, over 20000 lines refused in words, 20000 lines applied in time
#  F14 (R14) a store without 0146's functions answers in words;  F16 (R16) a database renamed between export and
#      import: no change;  F17 (R17) an application renamed between them: the old name previewed as an add
#  F18 (R18) a second import while one holds the lock: refused at once;  F19 (R19) a credential-shaped cell refused,
#      its text in no answer or audit row;  F21 (R21) '(none)': nothing on an inheriting database (the preview says so),
#      a conflict on a person's own assignment (removed when ticked), a change on an import's (any case of the word)
#  The review's rows (agent-runs 20261114-151618 / 152723 / 153929 / 155152): F22 a ticked application conflict's words
#  name every field it writes; F23 a line refused later adds or refuses no application; F24 an .xlsx with a repeated
#  row number refused in words; F25 a server-level line applied, its tag move counted; F26 (P-6, as built) an import's
#  re-assign of its own row under a person's server is a change; F19b one cell at a time for the credential check
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
  for x in ${EXTRA_ROLES:-}; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $x" >/dev/null 2>&1 || true; done
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
# M11 (R4's mark arm, as built): an import's mark of a database a person marked changes nothing and is no refusal
au0=$(q "select count(*) from pgvigil.admin_audit")
a=$(wi assign "{\"op\": \"mark\", \"targets\": [{\"instance_id\": $MI, \"database\": \"m2\"}]}")
msrc=$(q "select source from pgvigil.app_not_application where instance_id = $MI and database_name = 'm2'")
[[ $(field "$a" outcome) == done && $(field "$a" written) == 0 && $msrc == entered && $(q "select count(*) from pgvigil.admin_audit") == "$au0" ]] \
  && ok "M11 an import's mark of a database a person marked: done, 0 written, the mark still the person's, no audit row" || bad "M11 '$a'; source '$msrc'"
# M9: the same writes forced
f1=$(wi assign "{\"op\": \"unassign\", \"force\": true, \"app_id\": $EA, \"targets\": [{\"instance_id\": $MI, \"database\": \"m1\"}]}")
f2=$(wi assign "{\"op\": \"unmark\", \"force\": true, \"targets\": [{\"instance_id\": $MI, \"database\": \"m2\"}]}")
f4=$(wi assign "{\"op\": \"assign\", \"force\": true, \"app_id\": $EB, \"targets\": [{\"instance_id\": $MI2, \"database\": \"n1\"}]}")
f6=$(wi contact "{\"op\": \"edit\", \"force\": true, \"app_id\": $EA, \"contact_id\": ${EC:-0}, \"ord\": 9}")
f5=$(wi application "{\"op\": \"remove\", \"force\": true, \"app_id\": ${IA:-0}, \"version\": 1, \"with_assignments\": true}")
o9="$(field "$f1" outcome) $(field "$f2" outcome) $(field "$f4" outcome) $(field "$f6" outcome) $(field "$f5" outcome)"
land="$(asg_of "$MI" "'m1'") $(q "select count(*) from pgvigil.app_not_application where instance_id = $MI and database_name = 'm2'") $(asg_of "$MI2" "'n1'") $(q "select ord from pgvigil.ui_app_contacts where contact_id = ${EC:-0}") $(q "select count(*) from pgvigil.app_applications where app_id = ${IA:-0}")"
[[ $o9 == "done done done done done" && $land == "none 0 $EB|-|import:proof 9 0" ]] && ok "M9 the same imports forced: done and written (m1 unassigned, m2 unmarked, n1 the import's M Other, ord 9, M Imported removed)" \
  || bad "M9 outcomes '$o9' ($(field "$f5" detail)); landed '$land' (want 'none 0 $EB|-|import:proof 9 0')"
# M10
a=$(wp application '{"op": "add", "name": "(none)"}')
[[ $(field "$a" outcome) == refused && $(q "select count(*) from pgvigil.app_applications where name = '(none)'") == 0 ]] \
  && ok "M10 an application named '(none)' (the file's unassign token) refused ('$(field "$a" detail | cut -c1-90)')" || bad "M10 '$a'"
# M12 (review A, M4): the planner keys every join on the line: a payload whose line numbers repeat is refused in words
a=$(qc "select pgvigil.import_app_file(now(), '{\"ui_user\": \"importer\", \"client\": \"proof\", \"dry\": true, \"rows\": [{\"line\": 2, \"instance\": \"proof-imp-m\", \"database\": \"m4\", \"application\": \"M Other\"}, {\"line\": 2, \"instance\": \"proof-imp-m\", \"database\": \"m3\", \"application\": \"M Entered\"}]}'::jsonb)")
[[ $(field "$a" outcome) == refused && $(field "$a" detail) == *"line 2"* ]] && ok "M12 a payload whose line numbers repeat: refused ('$(field "$a" detail | cut -c1-80)')" || bad "M12 '${a:0:200}'"
fi

# ================= F: the file through the API (a serve on non-superuser logins, both engines) =================
if want F; then
UIL=pgvigil_imp_ui_$SUF; COLF=pgvigil_imp_cf_$SUF
USR=proofuser; UPW="pw-proof-312-$SUF-$RANDOM"
printf 'repository:\n  dsn: "%s"\ninstances: []\n' "$PGVIGIL_REPO_DSN" > "$WORK/owner.yaml"
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$WORK/owner.yaml" "$USR" > "$WORK/useradd.out" 2>&1 || bad "F setup: user add ($(tail -1 "$WORK/useradd.out"))"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create role $UIL login in role pgvigil_reader, pgvigil_auth" \
  -c "create role $COLF login in role pgvigil_collector" > "$WORK/logins.out" 2>&1 || bad "F setup: the serve's logins ($(tail -1 "$WORK/logins.out"))"
EXTRA_ROLES="$UIL $COLF"
printf 'repository:\n  dsn: "%s"\ninstances: []\n' "$PGVIGIL_ADMIN_DSN dbname=$DB user=$COLF" > "$WORK/serve.yaml"
export PGVIGIL_UI_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB user=$UIL"
freeport() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
SPIDS=(); trap 'for x in "${SPIDS[@]}"; do kill "$x" 2>/dev/null; done; cleanup' EXIT
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$WORK/serve.yaml" -dsn env:PGVIGIL_UI_DSN -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SPIDS+=($!)
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$WORK/login.json"
curl -s -o /dev/null -c "$WORK/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$WORK/login.json" "$U/api/login"
get()  { curl -s -o "$WORK/ans.json" -w '%{http_code}' -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/$1"; }
post() { printf '%s' "$2" > "$WORK/body.json"; curl -s -o "$WORK/ans.json" -w '%{http_code}' -b "$WORK/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$WORK/body.json" "$U/api/$1"; }
# imp <file> <query>: the import route with the raw file as the body; the answer in $WORK/ans.json
imp()  { curl -s -o "$WORK/ans.json" -w '%{http_code}' -b "$WORK/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/octet-stream' --data-binary @"$1" "$U/api/admin/applications/import?source=proof&$2"; }
js()   { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); exec(sys.argv[2])' "$WORK/ans.json" "$1" 2>&1; }
cnt()  { js "print(d.get('counts', {}).get('$1', 'x'))"; }
dig()  { js "print(d.get('digest', ''))"; }
item() { js "print('|'.join(i['outcome'] + ':' + i['words'] for i in d.get('items', []) if i.get('line') == $1 and i['kind'] == '${2:-target}'))"; }
# the app_* rows a round trip must not move (never last_seen or engine_db_id: the collector moves them)
appmd5() { q "select md5(coalesce((select string_agg(concat_ws('|', app_id, name, description, tier, environment, cmdb_url, version), ';' order by app_id) from pgvigil.app_applications), '')
  || coalesce((select string_agg(concat_ws('|', instance_id, database_name, app_id, environment, source, set_at, set_by), ';' order by instance_id, database_name) from pgvigil.app_assignments), '')
  || coalesce((select string_agg(concat_ws('|', instance_id, database_name, source, set_at), ';' order by instance_id, database_name) from pgvigil.app_not_application), '')
  || coalesce((select string_agg(concat_ws('|', object_kind, object_id, field, source, set_at), ';' order by object_kind, object_id, field) from pgvigil.app_field_source), ''))"; }
audits() { q "select count(*) from pgvigil.admin_audit"; }
asg() { q "select coalesce((select ap.name || '|' || a.source from pgvigil.app_assignments a join pgvigil.app_applications ap using (app_id) join pgvigil.instances i using (instance_id) where i.name = '$1' and coalesce(a.database_name, '') = '$2'), 'none')"; }

# fixtures: a PostgreSQL server and a SQL Server one; databases whose names start with = and - (key columns through
# the CSV guard), a database named 'no'; an absent assigned database on each engine; an inheriting database; a mark
PGF=$(newinst imp-pg)
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81002 f2), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81005 fgone), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no)]"
MSF=$(q "select pgvigil.ensure_instance('imp-ms', 'onprem', '16.0', 160000, false, '{}'::text[], 'sqlserver')")
q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, is_system, snapshot_at) values
   ($MSF, 'master', 1, true, now()), ($MSF, 'msdb', 4, true, now()), ($MSF, 's1', 5, false, now()), ($MSF, 's2', 6, false, now()), ($MSF, 'sgone', 7, false, now())" >/dev/null
OLD=$(newinst imp-old); q "update pgvigil.instances set is_active = false where instance_id = $OLD" >/dev/null
FA=$(field "$(wp application '{"op": "add", "name": "F Alpha", "tier": 2, "description": "alpha"}')" app_id)
# double-quoted: inside single quotes bash drops the '' and the store got '=x (t-im-g2 F7); SQL reads '' as one '
FB=$(field "$(wi application "{\"op\": \"add\", \"name\": \"F Beta\", \"description\": \"''=x\"}")" app_id)
wp assign "{\"op\": \"assign\", \"app_id\": $FA, \"targets\": [{\"instance_id\": $PGF, \"database\": null}, {\"instance_id\": $MSF, \"database\": \"s1\"}, {\"instance_id\": $PGF, \"database\": \"fgone\"}, {\"instance_id\": $PGF, \"database\": \"=x\"}]}" >/dev/null
wp assign "{\"op\": \"assign\", \"app_id\": $FB, \"targets\": [{\"instance_id\": $PGF, \"database\": \"f1\"}]}" >/dev/null
# forced: under imp-pg's ENTERED server assignment (F Alpha) an unforced import of another application is the m3 conflict (t-im-g2)
wi assign "{\"op\": \"assign\", \"force\": true, \"app_id\": $FB, \"targets\": [{\"instance_id\": $PGF, \"database\": \"f2\"}, {\"instance_id\": $MSF, \"database\": \"sgone\"}, {\"instance_id\": $PGF, \"database\": \"-name\"}]}" >/dev/null
wp assign "{\"op\": \"mark\", \"targets\": [{\"instance_id\": $PGF, \"database\": \"f4\"}]}" >/dev/null
# fgone and sgone dropped on their servers (absent, still named by their assignments)
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81002 f2), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no)]"
q "update pgvigil.mssql_database_option set is_present = false where instance_id = $MSF and database_name = 'sgone'" >/dev/null
[[ -n $FA && -n $FB && $(asg imp-pg f2) == "F Beta|import:proof" && $(asg imp-pg f1) == "F Beta|entered" ]] || bad "F setup: applications '$FA' '$FB'; f1 $(asg imp-pg f1), f2 $(asg imp-pg f2)"

# F1 (R1, R15, R7's keys): the CSV export imported as it is: nothing to change, nothing written but the summary row
c=$(curl -s -o "$WORK/inv.csv" -w '%{http_code}' -b "$WORK/cj" -H 'X-Pgvigil: 1' -D "$WORK/inv.hdr" "$U/api/applications/inventory.csv")
csvread() { python3 -I -c 'import csv, sys, io
t = open(sys.argv[1], encoding="utf-8-sig").read(); rows = list(csv.reader(io.StringIO(t)))
h = rows[0]; print("|".join(";".join(r[h.index(c)] for c in sys.argv[2].split(",")) for r in rows[1:] if eval(sys.argv[3])))' "$WORK/inv.csv" "$1" "$2"; }
gone=$(csvread database,absent_since "r[h.index('database')] in ('fgone', 'sgone')")
keys=$(csvread database "r[h.index('instance')] == 'imp-pg' and r[h.index('database')][:2] in (\"'=\", \"'-\")")
inh=$(csvread database,application,inherited_from "r[h.index('database')] == 'f3'")
m0=$(appmd5); a0=$(audits)
p=$(imp "$WORK/inv.csv" "dry=1"); D1=$(dig); pc="$(cnt applications_added)/$(cnt applications_changed)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt unknown_servers)/$(cnt refused)/$(cnt unknown_databases)"; ul="$(cnt unchanged)/$(cnt lines)"
a1=$(audits)
x=$(imp "$WORK/inv.csv" "dry=0&digest=$D1"); xo=$(js "print(d.get('outcome'))")
m1=$(appmd5); a2=$(audits)
[[ $c == 200 && $(head -c 3 "$WORK/inv.csv" | od -An -tx1 | tr -d ' ') == efbbbf && $(grep -ci 'attachment' "$WORK/inv.hdr") == 1 && $gone == *"fgone;2"* && $gone == *"sgone;2"* \
   && $keys == "'-name|'=x" && $inh == "f3;;F Alpha" && $p == 200 && $pc == "0/0/0/0/0/0/0" && ${ul%/*} == "${ul#*/}" && $a1 == "$a0" && $x == 200 && $xo == done && $m1 == "$m0" && $a2 == $((a0 + 1)) ]] \
  && ok "F1 the CSV export imported as it is (both engines, absent fgone / sgone, inherited f3 blank, keys '=x' and '-name' guarded): 0 adds / changes / conflicts / unknown / refused; applied: the app_* rows' md5 the same, one summary audit row" \
  || bad "F1 export $c (absent '$gone'; keys '$keys'; f3 '$inh'); preview $p counts $pc (unchanged/lines $ul); audit $a0 -> $a1 -> $a2; apply $x $xo; md5 same: $([[ $m1 == "$m0" ]] && echo yes || echo no); $(head -c 300 "$WORK/ans.json")"

# F2 (R2): an add, a change, a conflict and an unknown server, on both engines; F3 (R3) the conflict ticked
cat > "$WORK/f2.csv" <<CSV
instance,engine,database,application,environment,tier,cmdb_url
imp-pg,postgres,f3,F Alpha,test,,
imp-pg,postgres,f2,F Alpha,,,
imp-pg,postgres,f1,F Gamma,,3,https://cmdb.example.com/ci/123
imp-ms,sqlserver,s2,F Gamma,,3,https://cmdb.example.com/ci/123
imp-nowhere,postgres,x1,F Gamma,,3,https://cmdb.example.com/ci/123
CSV
n0=$(q "select count(*) from pgvigil.instances")
p=$(imp "$WORK/f2.csv" "dry=1"); D2=$(dig)
pc="$(cnt applications_added)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt unknown_servers)"
i3=$(item 4); i6=$(item 6)
x=$(imp "$WORK/f2.csv" "dry=0&digest=$D2"); xo=$(js "print(d.get('outcome'))")
st="$(asg imp-pg f3) $(asg imp-pg f2) $(asg imp-pg f1) $(asg imp-ms s2)"
# review P, M-4: the file's environment, tier and cmdb_url stored
f2v="$(q "select coalesce(a.environment, '-') from pgvigil.app_assignments a join pgvigil.instances i using (instance_id) where i.name = 'imp-pg' and a.database_name = 'f3'")|$(q "select tier || '|' || cmdb_url from pgvigil.app_applications where name = 'F Gamma'")"
[[ $p == 200 && $pc == "1/3/1/1" && $i3 == conflict:* && $i6 == refused:*"no server named imp-nowhere"* && $x == 200 && $xo == done \
   && $st == "F Alpha|import:proof F Alpha|import:proof F Beta|entered F Gamma|import:proof" && $(q "select count(*) from pgvigil.instances") == "$n0" \
   && $f2v == "test|3|https://cmdb.example.com/ci/123" ]] \
  && ok "F2 an add (F Gamma on s2, tier 3 and its CMDB link from the file), changes on both engines (f3 its own F Alpha in test, f2 re-assigned, s2), a conflict (f1 entered) and an unknown server: previewed exactly; applied unticked - the conflict kept, no server made" \
  || bad "F2 preview $p counts $pc (want 1/3/1/1); line 4 '$i3'; line 6 '$i6'; apply $x $xo; now $st; stored '$f2v'; $(head -c 300 "$WORK/ans.json")"
p=$(imp "$WORK/f2.csv" "dry=1"); D3=$(dig)
x=$(imp "$WORK/f2.csv" "dry=0&digest=$D3&force=t4"); xo=$(js "print(d.get('outcome'))")
[[ $x == 200 && $xo == done && $(asg imp-pg f1) == "F Gamma|import:proof" ]] && ok "F3 the same conflict ticked (force t4): applied, source import:proof" || bad "F3 apply $x $xo; f1 $(asg imp-pg f1); $(head -c 300 "$WORK/ans.json")"

# F4 (R5) a page write between preview and apply: refused whole; F5 (R5b) a collector's list read between them: not refused
printf 'instance,database,application\nimp-pg,f2,F Beta\n' > "$WORK/f4.csv"
imp "$WORK/f4.csv" "dry=1" >/dev/null; D4=$(dig)
# the page write touches the plan: f2 itself re-assigned by hand (an edit of an application the file does not name
# is not in the plan, so the digest rightly stays: t-im-g2)
FG=$(q "select app_id from pgvigil.app_applications where name = 'F Gamma'")
pw=$(post admin/applications/assign "{\"op\": \"assign\", \"app_id\": ${FG:-0}, \"targets\": [{\"instance_id\": $PGF, \"database\": \"f2\"}]}"); pa=$(asg imp-pg f2)
m0=$(appmd5); x=$(imp "$WORK/f4.csv" "dry=0&digest=$D4"); xd=$(js "print(d.get('detail', d.get('error', '')))"); m1=$(appmd5)
[[ $pw == 200 && $pa == "F Gamma|entered" && $x == 409 && $xd == *"changed since the preview"* && $m1 == "$m0" ]] && ok "F4 a page write between the preview and the apply (f2 re-assigned by hand): refused whole ('${xd:0:80}'), nothing written" || bad "F4 page write $pw (f2 $pa); apply $x '$xd'; md5 same: $([[ $m1 == "$m0" ]] && echo yes || echo no)"
# F5: f2 is now entered by hand, so the file's line 2 is a conflict: ticked (t2), the collector's read between
imp "$WORK/f4.csv" "dry=1" >/dev/null; D5=$(dig); i5=$(item 2)
seen() { q "select coalesce(a.engine_db_id::text, '-') || '|' || coalesce(a.last_seen::text, '-') from pgvigil.app_assignments a join pgvigil.instances i using (instance_id) where i.name = 'imp-pg' and a.database_name = 'f2'"; }
s0=$(seen)
# review P, M-5: f2 made again on its server under a new dbid, so the list read moves both columns the digest leaves out
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81202 f2), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no)]"
s1=$(seen)
x=$(imp "$WORK/f4.csv" "dry=0&digest=$D5&force=t2"); xo=$(js "print(d.get('outcome'))")
[[ $i5 == conflict:* && ${s0%%|*} != "${s1%%|*}" && ${s0#*|} != "${s1#*|}" && $x == 200 && $xo == done && $(asg imp-pg f2) == "F Beta|import:proof" ]] && ok "F5 a collector's list read between the preview and the apply (f2's engine_db_id ${s0%%|*} -> ${s1%%|*}, last_seen moved): not refused, applied (its conflict ticked)" || bad "F5 line 2 '$i5'; seen '$s0' -> '$s1'; $x $xo; f2 $(asg imp-pg f2); $(head -c 300 "$WORK/ans.json")"

# F6 (R6): the export as a semicolon file (Excel in a comma-decimal locale) under the bar's two mark lines: no change
curl -s -o "$WORK/inv2.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"
python3 -I -c 'import csv, sys, io
t = open(sys.argv[1], encoding="utf-8-sig").read(); rows = list(csv.reader(io.StringIO(t)))
o = io.StringIO(); w = csv.writer(o, delimiter=";", lineterminator="\r\n"); w.writerow(["sample of a stored read"]); w.writerow(["read 2026-11-14 10:00"]); w.writerows(rows)
open(sys.argv[2], "w", encoding="utf-8-sig").write(o.getvalue())' "$WORK/inv2.csv" "$WORK/semi.csv"
p=$(imp "$WORK/semi.csv" "dry=1"); pc="$(cnt applications_added)/$(cnt applications_changed)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt refused)/$(cnt unknown_databases)/$(cnt lines)"
[[ $p == 200 && $pc == 0/0/0/0/0/0/* && ${pc##*/} -ge 12 ]] && ok "F6 a semicolon file under two mark lines reads as the export: no change ($pc)" || bad "F6 $p $pc; $(head -c 300 "$WORK/ans.json")"

# F7 (R7): '=SUM(1)' as a description: written guarded, read back exactly
printf "instance,database,application,description\nimp-pg,f3,F Gamma,=SUM(1)\n" > "$WORK/f7.csv"
imp "$WORK/f7.csv" "dry=1" >/dev/null; D7=$(dig); i7=$(item 2); imp "$WORK/f7.csv" "dry=0&digest=$D7" >/dev/null
curl -s -o "$WORK/inv3.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"
stored=$(q "select description from pgvigil.app_applications where name = 'F Gamma'"); g7=$(grep -c "'=SUM(1)" "$WORK/inv3.csv")
p=$(imp "$WORK/inv3.csv" "dry=1"); pc="$(cnt applications_changed)/$(cnt targets_changed)"
[[ $stored == "=SUM(1)" && $g7 -ge 1 && $pc == 0/0 && $(q "select description from pgvigil.app_applications where name = 'F Beta'") == "'=x" ]] \
  && ok "F7 '=SUM(1)' and \"'=x\" as descriptions: stored as typed, written with one more ', read back with no change" || bad "F7 stored '$stored'; guarded cells $g7; re-import $pc"
# F26 (review P, P-6; kept as built, for the lead's eye): f3's own F Alpha was the import's (F2), so F7's re-assign to
# F Gamma under imp-pg's ENTERED F Alpha is a change, not a conflict: the person entered the server's application and f3
# did not inherit it (a database that inherits it would be the m3 conflict, F setup / M4)
[[ $i7 == change:* && $(asg imp-pg f3) == "F Gamma|import:proof" ]] && ok "F26 an import's re-assign of its own row (f3) under a person's server application: a change ('${i7:0:60}')" || bad "F26 line 2 '$i7'; f3 $(asg imp-pg f3)"

# F8 (R8, the API half): contacts shown on the page are in no export; an imported email column makes no contact
post admin/applications/contacts "{\"op\": \"add\", \"app_id\": $FA, \"role\": \"support\", \"kind\": \"person\", \"name\": \"Fiona Planted\", \"email\": \"fiona.$SUF@example.com\", \"phone\": \"+1 555 7$SUF\"}" >/dev/null
curl -s -o "$WORK/inv4.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"; get applications/inventory >/dev/null; cp "$WORK/ans.json" "$WORK/inv4.json"
leak=$(cat "$WORK/inv4.csv" "$WORK/inv4.json" | grep -c -i -e 'Fiona Planted' -e "fiona.$SUF@" -e "555 7$SUF" -e "$USR" -e 'person' -e 'importer' -e '127.0.0.1')
c0=$(q "select count(*) from pgvigil.ui_app_contacts")
printf 'instance,database,application,email,owner\nimp-pg,f3,F Gamma,someone.%s@example.com,Someone\n' "$SUF" > "$WORK/f8.csv"
imp "$WORK/f8.csv" "dry=1" >/dev/null; nr=$(js "print(','.join(d['file']['columns_not_read']))"); D8=$(dig)
imp "$WORK/f8.csv" "dry=0&digest=$D8" >/dev/null
[[ $leak == 0 && $nr == "email,owner" && $(q "select count(*) from pgvigil.ui_app_contacts") == "$c0" ]] \
  && ok "F8 no contact, user name or client address in the CSV or the grid's answer; an imported email / owner column listed as not read, no contact made" || bad "F8 hits $leak; not read '$nr'; contacts $c0 -> $(q "select count(*) from pgvigil.ui_app_contacts")"

# F9 (R9): no login, no header: refused, nothing written
m0=$(appmd5)
c1=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Pgvigil: 1' --data-binary @"$WORK/f4.csv" "$U/api/admin/applications/import?source=proof&dry=0")
c2=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/cj" --data-binary @"$WORK/f4.csv" "$U/api/admin/applications/import?source=proof&dry=0")
c3=$(curl -s -o /dev/null -w '%{http_code}' "$U/api/applications/inventory.csv")
[[ $c1 == 401 && $c2 == 403 && $c3 == 401 && $(appmd5) == "$m0" ]] && ok "F9 the import without a login 401, without the header 403, the CSV without a login 401; nothing written" || bad "F9 $c1 $c2 $c3"

# F10 (R10, R20): an .xlsx with shared strings, a blank cell left out mid-row, 'no' as a boolean cell, 2024 as a number
# (review P, P-4: F Year's description 2024 on lines no refusal touches; the database 'no' line counted if unmatched)
q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, is_system, snapshot_at) values ($MSF, 's10', 10, false, now())" >/dev/null
FY=$(field "$(wp application '{"op": "add", "name": "F Year", "description": "2024"}')" app_id)
wp assign "{\"op\": \"assign\", \"app_id\": ${FY:-0}, \"targets\": [{\"instance_id\": $MSF, \"database\": \"s10\"}]}" >/dev/null
curl -s -o "$WORK/inv10.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"
python3 -I - "$WORK/inv10.csv" "$WORK/f10.xlsx" <<'PY'
import csv, io, re, sys, zipfile
from xml.sax.saxutils import escape
rows = list(csv.reader(io.StringIO(open(sys.argv[1], encoding="utf-8-sig").read())))
# the CSV's guard undone as the server undoes it (q_app_import.go csvGuardUndo ^'+[=+\-@\t\r]: one ' off), an .xlsx has
# none; t-im-g3: a one-quote undo left F Beta's "''=x" whole
rows = [[c[1:] if re.match(r"'+[=+\-@\t\r]", c) else c for c in r] for r in rows]
rows.append(["database", "imp-pg", "", "f3", "F Gamma", "", "", "2024"] + [""] * (len(rows[0]) - 8))
ss = []; idx = {}
def si(v):
    if v not in idx: idx[v] = len(ss); ss.append(v)
    return idx[v]
def col(i):
    s = ""
    i += 1
    while i: i, r = divmod(i - 1, 26); s = chr(65 + r) + s
    return s
sheet = []
for n, r in enumerate(rows, 1):
    cells = []
    for i, v in enumerate(r):
        ref = col(i) + str(n)
        if v == "": continue                                  # a blank cell left out, as Excel does
        if v == "no" and n > 1: cells.append('<c r="%s" t="b"><v>0</v></c>' % ref)
        elif v == "2024" and n > 1: cells.append('<c r="%s"><v>2024</v></c>' % ref)
        else: cells.append('<c r="%s" t="s"><v>%d</v></c>' % (ref, si(v)))
    sheet.append('<row r="%d">%s</row>' % (n, "".join(cells)))
z = zipfile.ZipFile(sys.argv[2], "w")
z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
z.writestr("xl/workbook.xml", '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Inventory" sheetId="1" r:id="rId1"/></sheets></workbook>')
z.writestr("xl/_rels/workbook.xml.rels", '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x" Target="worksheets/sheet1.xml"/></Relationships>')
z.writestr("xl/sharedStrings.xml", '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' + "".join("<si><t xml:space=\"preserve\">%s</t></si>" % escape(v) for v in ss) + "</sst>")
z.writestr("xl/worksheets/sheet1.xml", '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + "".join(sheet) + "</sheetData></worksheet>")
z.close()
PY
p=$(imp "$WORK/f10.xlsx" "dry=1"); pc="$(cnt applications_added)/$(cnt applications_changed)/$(cnt targets_changed)/$(cnt refused)/$(cnt unknown_databases)/$(cnt unknown_servers)"; kind=$(js "print(d['file']['kind'])")
i10=$(js "print([i['words'] for i in d.get('items', []) if i['kind'] == 'target' and i['database'] == 'f3'])")
[[ $p == 200 && $kind == xlsx && $pc == 0/0/0/1/0/0 && $i10 == *"same database as line"* && -n $FY ]] \
  && ok "F10 an .xlsx (shared strings, blank cells left out, 'no' a boolean cell, F Year's 2024 a number): the export's rows read with no change and no unknown; the extra f3 line refused as a second line of one database" \
  || bad "F10 $p kind $kind counts $pc; f3 items $i10; $(head -c 300 "$WORK/ans.json")"

# F11 (R11): refused lines with their numbers; the rest previewed
cat > "$WORK/f11.csv" <<CSV
instance,database,application,environment,tier,not_an_application
imp-pg,f3,"a,b",,,
imp-pg,f3,F Gamma,prod,,
imp-pg,f2,F Beta,,5,
imp-pg,f2,F Beta,,,yes
imp-old,x,F Beta,,,
imp-pg,f4,,,,no
imp-pg,template1,F Gamma,,,
imp-pg,f1,F Gamma,test,,
CSV
p=$(imp "$WORK/f11.csv" "dry=1"); D11=$(dig); u11="$(cnt unknown_databases)/$(cnt refused)"
r11="$(item 2 | cut -c1-8)/$(item 3 | cut -c1-8)/$(item 4 | cut -c1-8)/$(item 5 | cut -c1-8)/$(item 6 | cut -c1-8)/$(item 7 | cut -c1-8)/$(item 8 | cut -c1-8)/$(item 9 | cut -c1-7)"
w11="$(item 3)|$(item 6)|$(item 7)"
# review P, M-10: the rest applied (f1's environment), the refused lines and the unticked conflict not
x=$(imp "$WORK/f11.csv" "dry=0&digest=$D11")
e11="$(q "select coalesce(a.environment, '-') from pgvigil.app_assignments a join pgvigil.instances i using (instance_id) where i.name = 'imp-pg' and a.database_name = 'f1'")|$(q "select count(*) from pgvigil.app_not_application m join pgvigil.instances i using (instance_id) where i.name = 'imp-pg' and m.database_name = 'f4'")"
[[ $p == 200 && $r11 == "refused:/refused:/refused:/refused:/refused:/conflict/refused:/change:" && $w11 == *environment*"not an active server"*"marked by hand"* && $u11 == 0/6 && $x == 200 && $e11 == "test|1" ]] \
  && ok "F11 a bad name, a bad environment, a bad tier, an application with not_an_application yes, an inactive server, template1: each refused on its line (template1 counted once: unknown 0, refused 6); the unmark of a person's mark a conflict; applied: f1's environment test, f4 still marked" \
  || bad "F11 $p lines 2-9 '$r11'; unknown/refused $u11 (want 0/6); $w11; apply $x; f1 env|f4 marked '$e11'"

# F12 (R12): a dry run and refused lines write no audit row; an apply one per change and one summary
a0=$(audits); imp "$WORK/f11.csv" "dry=1" >/dev/null; a1=$(audits)
printf 'instance,database,application,tier\nimp-pg,f3,F Alpha,\nimp-ms,s2,F Alpha,\nimp-pg,f3x,F Alpha,\nimp-pg,f1,F Gamma,5\n' > "$WORK/f12.csv"
imp "$WORK/f12.csv" "dry=1" >/dev/null; D12=$(dig); imp "$WORK/f12.csv" "dry=0&digest=$D12" >/dev/null; a2=$(audits)
sum=$(q "select detail from pgvigil.admin_audit where op = 'app_import' order by audit_id desc limit 1")
[[ $a1 == "$a0" && $a2 == $((a0 + 3)) && $sum == *"2 target(s) changed"*"1 unknown database"*"1 refused"* && $sum != *f3x* ]] \
  && ok "F12 a dry run and refused lines: no audit row; an apply: one per change (2) and one summary of counts ('${sum:0:90}')" || bad "F12 audit $a0 -> $a1 -> $a2; summary '$sum'"

# F14 (R14): a store without 0146's functions answers in words, never a SQL error
q "alter function pgvigil.import_app_file(timestamptz, jsonb) rename to import_app_file_hidden" >/dev/null
c1=$(imp "$WORK/f4.csv" "dry=1"); w1=$(js "print(d.get('error', ''))"); c2=$(get applications/inventory.csv); w2=$(js "print(d.get('error', ''))")
c3=$(get applications/inventory); w3=$(js "print(d.get('error', ''))")
q "alter function pgvigil.import_app_file_hidden(timestamptz, jsonb) rename to import_app_file" >/dev/null
[[ $c1 == 409 && $w1 == *"older than this pgvigil"*"pgvigil migrate"* && $c2 == 409 && $w2 == *"older than this pgvigil"* && $c3 == 409 && $w3 == *"older than this pgvigil"* && $w1 != *SQLSTATE* ]] \
  && ok "F14 a repository without 0146's functions: the import, the CSV and the grid's read answer in words ('${w1:0:70}')" || bad "F14 $c1 '$w1'; $c2 '$w2'; $c3 '$w3'"

# F16 (R16): a database renamed on its server between export and import (the same dbid): the old file changes nothing
curl -s -o "$WORK/inv5.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81202 f2new), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no)]"
p=$(imp "$WORK/inv5.csv" "dry=1"); pc="$(cnt applications_changed)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt refused)/$(cnt unknown_databases)"
[[ $p == 200 && $pc == 0/0/0/0/0 ]] && ok "F16 f2 renamed f2new on its server after the export: the old file changes nothing (f2 absent, still named; f2new not in the file)" || bad "F16 $p $pc; $(head -c 300 "$WORK/ans.json")"

# F17 (R17): an application renamed between export and import: the old name comes back as an add, said in the preview
ver=$(q "select version from pgvigil.app_applications where app_id = $FB")
post admin/applications "{\"op\": \"rename\", \"app_id\": $FB, \"version\": $ver, \"name\": \"F Beta Two\"}" >/dev/null
p=$(imp "$WORK/inv5.csv" "dry=1"); a17=$(js "print([i['words'] for i in d.get('items', []) if i['kind'] == 'application'])")
[[ $p == 200 && $(cnt applications_added) == 1 && $a17 == *"a new application F Beta"* ]] && ok "F17 F Beta renamed F Beta Two after the export: the old file previews F Beta as a new application ($a17)" || bad "F17 $p added $(cnt applications_added); $a17"

# F18 (R18): a second import while one runs: refused in words, never queued
psql "$PGVIGIL_REPO_DSN" -XAtq -c "select pg_advisory_lock(hashtext('pgvigil.app_import')); select pg_sleep(8)" >/dev/null 2>&1 & HOLD=$!
sleep 1; c=$(imp "$WORK/f4.csv" "dry=1"); w=$(js "print(d.get('detail', ''))"); wait $HOLD
[[ $c == 409 && $w == *"another import is running"* ]] && ok "F18 an import while another holds its lock: refused at once ('${w:0:60}')" || bad "F18 $c '$w'"

# F19 (R19): a credential-shaped cell: its line refused, its text in no answer and no audit row
# (review A M1 / P P-1, A m3: the secret in the application, the server, the engine; an Azure key, a PEM block, a bearer
# token; the preview's own answer read - it is the one that lists the items)
S19=hunter2x$SUF
cat > "$WORK/f19.csv" <<CSV
instance,engine,database,application,description
imp-pg,,f3,F Alpha,password=$S19
imp-pg,,f3,svc password=$S19,
postgres://u:$S19@h,,f3,F Alpha,
imp-pg,token=$S19,f3,F Alpha,
imp-ms,,s2,F Gamma,AccountKey=$S19
imp-ms,,s2,F Gamma,-----BEGIN PRIVATE KEY----- $S19
imp-ms,,s2,F Gamma,Authorization: Bearer abcdefghijklmnop$S19
CSV
p=$(imp "$WORK/f19.csv" "dry=1"); cp "$WORK/ans.json" "$WORK/f19p.json"; D19=$(dig)
w=$(for l in 2 3 4 5 6 7 8; do item $l | cut -c1-30; done | sort -u | tr '\n' '|')
imp "$WORK/f19.csv" "dry=0&digest=$D19" > /dev/null
hits=$(( $(cat "$WORK/f19p.json" "$WORK/ans.json" | grep -c "$S19") + $(q "select count(*) from pgvigil.admin_audit where detail like '%$S19%' or target like '%$S19%'") ))
[[ $p == 200 && $w == "refused:a cell looks like a cr|" && $hits == 0 ]] && ok "F19 a credential-shaped cell in the description, the application, the server, the engine (a password, a URL's, a token, an Azure key, a PEM block, a bearer token): each line refused, the text in no answer (the preview's items included) and no audit row" || bad "F19 $p lines 2-8 '$w'; hits $hits; $(head -c 300 "$WORK/f19p.json")"
# F19b (review A, m3): each cell checked alone - an application 'Payment Token' beside a description '=SUM(1)' is no credential
printf 'instance,database,application,description\nimp-ms,s2,Payment Token,=SUM(1)\n' > "$WORK/f19b.csv"
p=$(imp "$WORK/f19b.csv" "dry=1"); w=$(item 2)
[[ $p == 200 && $w != refused:* ]] && ok "F19b two cells read alone: 'Payment Token' and '=SUM(1)' make no credential ('${w:0:50}')" || bad "F19b $p '$w'"

# F21 (R21): '(none)' on an inheriting database changes nothing; on a person's own assignment a conflict, removed when ticked
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81202 f2new), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no), $(pgdb 81009 f5)]"
printf 'instance,database,application\nimp-pg,f5,(none)\nimp-ms,s1,(none)\nimp-pg,-name,(None)\n' > "$WORK/f21.csv"
p=$(imp "$WORK/f21.csv" "dry=1"); D21=$(dig); i2=$(js "print([i['words'] for i in d.get('items', []) if i.get('line') == 2])"); i3=$(item 3); i4=$(item 4)
x=$(imp "$WORK/f21.csv" "dry=0&digest=$D21&force=t3")
[[ $p == 200 && $(cnt unchanged) -ge 1 && $i2 == *"inherits F Alpha from its server: (none) changes nothing"* && $i3 == conflict:*unassign* && $i4 == change:unassign* && $x == 200 \
   && $(asg imp-ms s1) == none && $(asg imp-pg f5) == none && $(asg imp-pg -name) == none ]] \
  && ok "F21 '(none)' on f5 (it inherits F Alpha): nothing, the preview says so; on s1 (a person's): a conflict, removed when ticked; '(None)' on -name (the import's): a change, removed unticked" || bad "F21 $p line 2 $i2 / line 3 '$i3' / line 4 '$i4'; apply $x; s1 $(asg imp-ms s1); -name $(asg imp-pg -name); $(head -c 300 "$WORK/ans.json")"

# F22 (review A, M2): a ticked application conflict writes every field its words name - and they name every one
FT=$(field "$(wp application '{"op": "add", "name": "F Tick", "tier": 2}')" app_id)
wi application "{\"op\": \"edit\", \"app_id\": ${FT:-0}, \"version\": 1, \"description\": \"old\"}" >/dev/null
printf 'instance,database,application,tier,description\nimp-ms,s2,F Tick,3,new\n' > "$WORK/f22.csv"
p=$(imp "$WORK/f22.csv" "dry=1"); D22=$(dig)
a22=$(js "print('|'.join(i['id'] + ':' + i['outcome'] + ':' + i['words'] for i in d.get('items', []) if i['kind'] == 'application'))")
x=$(imp "$WORK/f22.csv" "dry=0&digest=$D22&force=${a22%%:*}")
v22=$(q "select tier || '|' || description from pgvigil.app_applications where app_id = ${FT:-0}")
[[ $p == 200 && $a22 == *:conflict:*tier*description* && $x == 200 && $v22 == "3|new" ]] && ok "F22 a ticked application conflict (tier entered, description the import's): its words name both ('${a22:0:110}'), both written" || bad "F22 $p '$a22'; apply $x; tier|description '$v22'"

# F23 (review A, M3): a line refused later (an absent database) adds no application and refuses none
printf 'instance,database,application,tier\nimp-pg,fgone,F New,3\nimp-ms,s2,F Gamma,3\nimp-ms,sgone,F Gamma,4\n' > "$WORK/f23.csv"
p=$(imp "$WORK/f23.csv" "dry=1")
a23=$(js "print('|'.join(i['application'] + ':' + i['outcome'] for i in d.get('items', []) if i['kind'] == 'application'))")
[[ $p == 200 && $(cnt applications_added) == 0 && $a23 != *refused* && $a23 != *"F New"* && $(item 2) == refused:*absent* && $(item 4) == refused:*absent* ]] \
  && ok "F23 lines refused on an absent database: F New not added, F Gamma's item not refused by the absent line's tier ('$a23')" || bad "F23 $p added $(cnt applications_added); items '$a23'; line 2 '$(item 2)'; line 4 '$(item 4)'"

# F24 (review A, M4): an .xlsx whose row numbers repeat is refused in words (every line keyed on its number)
python3 -I - "$WORK/f24.xlsx" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
z.writestr("xl/workbook.xml", '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Inventory" sheetId="1" r:id="rId1"/></sheets></workbook>')
z.writestr("xl/_rels/workbook.xml.rels", '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x" Target="worksheets/sheet1.xml"/></Relationships>')
c = lambda r, v: '<c r="%s" t="inlineStr"><is><t>%s</t></is></c>' % (r, v)
rows = [(1, ["instance", "database", "application"]), (2, ["imp-ms", "s2", "F Alpha"]), (2, ["imp-ms", "s10", "F Gamma"])]
z.writestr("xl/worksheets/sheet1.xml", '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
  + "".join('<row r="%d">%s</row>' % (n, "".join(c("%s%d" % ("ABC"[i], n), v) for i, v in enumerate(vs))) for n, vs in rows) + "</sheetData></worksheet>")
z.close()
PY
p=$(imp "$WORK/f24.xlsx" "dry=1"); w=$(js "print(d.get('error', d.get('detail', '')))")
[[ $p == 400 && $w == *"row 2"* ]] && ok "F24 an .xlsx with row 2 twice: refused in words ('${w:0:70}')" || bad "F24 $p '$w'; $(head -c 200 "$WORK/ans.json")"

# F25 (review P, M-14): a server-level line applied; the preview counts the server whose application tag moves
SRV=$(newinst imp-srv); dbs "$SRV" "[$(pgdb 5 postgres), $(pgdb 91001 v1)]"
printf 'level,instance,application\nserver,imp-srv,F Gamma\n' > "$WORK/f25.csv"
p=$(imp "$WORK/f25.csv" "dry=1"); D25=$(dig); c25="$(cnt targets_changed)/$(cnt servers_whose_tag_moves)"
x=$(imp "$WORK/f25.csv" "dry=0&digest=$D25")
[[ $p == 200 && $c25 == 1/1 && $x == 200 && $(asg imp-srv '') == "F Gamma|import:proof" ]] && ok "F25 a server-level line: previewed (1 change, 1 server whose tag moves) and applied (imp-srv F Gamma, the import's)" || bad "F25 $p $c25; apply $x; imp-srv $(asg imp-srv '')"
fi

# ================= P: the page (Admin > Applications in a headless Chromium, on section F's serve) =================
#  P1 (R22, R10, R8's page half) the Inventory grid filtered to one server, an application's contacts shown, the
#     inventory's own export: its .xlsx holds every line (read back through the import: as many lines as the API's
#     inventory, nothing to change), and no contact, user name or client address
#     (review C 2 / B M5: a two-line description, 'Yes' and '1.50' entered on the page read back unchanged; C 6: the
#     workbook says every line whatever the filter; P M-9: the lines drawn are imp-ms's alone, the button says it too)
#  P2 a file chosen, its source name typed (the field's pattern compiles: C 5), previewed (two conflicts, one ticked:
#     C 7) and applied by a double click (one apply: C 4): the store holds the change and the ticked one, the unticked
#     kept; focus on the import's result (C 9)
#  P3 (R23) axe-core 4.14.0 on the page with the preview shown, light and dark (dark set on the page: P P-2): 0 nodes
#  P4 (review C 1) a preview of over 200 items: a conflict ticked, the grid's Copy all (which draws every row again),
#     the tick taken off on screen, applied: the conflict kept
# Excel's own save of the workbook is NOT PROVEN (no Excel on the box), nor a LibreOffice re-save (no LibreOffice on
# the box): F10 reads a workbook with shared strings the proof writes.
if want P; then
if [[ -z "${U:-}" ]]; then bad "P needs section F's serve (IMP_ONLY with F)"; else
P_OK=1
for t in chromium node npm unzip; do command -v $t >/dev/null || { P_OK=0; bad "P setup: $t is not on this machine"; }; done
CDP=$(freeport); DL=$WORK/dl; mkdir -p "$DL"
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --window-size=1500,1100 about:blank > "$WORK/chrome.log" 2>&1 & SPIDS+=($!)
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
(cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1); AXE=$WORK/node_modules/axe-core/axe.min.js
[[ -f "$AXE" ]] || { P_OK=0; bad "P setup: axe-core 4.14.0 did not install"; }
# P2's file: an assign (s1, no application now), the unmark of f4 (a person's mark: a conflict, ticked on the page) and
# =x re-assigned (a person's assignment: a conflict left unticked)
printf 'instance,database,application,not_an_application\nimp-ms,s1,F Gamma,\nimp-pg,f4,,no\nimp-pg,=x,F Gamma,\n' > "$WORK/p2.csv"
# P4's file: =x's conflict on line 2, then 205 unknown databases (each an item: over the grid's 200 drawn rows)
python3 -I -c 'import sys; open(sys.argv[1], "w").write("instance,database,application\nimp-pg,=x,F Gamma\n" + "".join("imp-pg,u%03d,F Gamma\n" % i for i in range(205)))' "$WORK/p4.csv"
# P1's values the page takes and a typed export would not give back (review C 2, B M5): a two-line description with
# two spaces, the word Yes, a number-like text - each an application a person entered, on a server of their own
PSV=$(newinst imp-p); dbs "$PSV" "[$(pgdb 5 postgres), $(pgdb 92001 p1), $(pgdb 92002 p2), $(pgdb 92003 p3)]"
for x in "P Multi|line one\\nline  two|p1" "Yes|Yes|p2" "1.50|1.50|p3"; do
  IFS='|' read -r pn pd pdb <<< "$x"
  pa=$(field "$(wp application "{\"op\": \"add\", \"name\": \"$pn\", \"description\": \"$pd\"}")" app_id)
  wp assign "{\"op\": \"assign\", \"app_id\": ${pa:-0}, \"targets\": [{\"instance_id\": $PSV, \"database\": \"$pdb\"}]}" >/dev/null
done
PMULTI=$(q "select description from pgvigil.app_applications where name = 'P Multi'" | od -c | tr -s ' ' | tr -d '\n' | grep -c 'e \\n l')
cat > "$WORK/p.mjs" <<'JS'
const [port, U, dl, axePath, p2file, phase, p4file] = process.argv.slice(2);   // phase 1: P1; phase 2: P2, P3, P4 (P1's file is read back between)
const fs = await import('node:fs');
const env = process.env;
const out = (k, v) => console.log(`${k}=${(typeof v === 'string' ? v : JSON.stringify(v)).replace(/\s+/g, ' ')}`);
const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const bws = new WebSocket(ver.webSocketDebuggerUrl);
await new Promise(r => bws.addEventListener('open', r));
bws.send(JSON.stringify({ id: 1, method: 'Browser.setDownloadBehavior', params: { behavior: 'allow', downloadPath: dl } }));
await new Promise(r => bws.addEventListener('message', r));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
// the import's own status line (the one after its form; the Inventory grid has a status line of its own: t-im-g3)
const fileStatus = () => ev(`document.querySelector('main section.app-file form + p[role=status]')?.textContent ?? ''`);
const ready = async () => { for (let i = 0; i < 150; i++) { if (await ev(`!!document.querySelector('main section.app-file table.grid')`)) { await sleep(400); return true; } await sleep(200); } return false; };
const settle = async () => { let t = ''; for (let i = 0; i < 400; i++) { await sleep(150); t = await fileStatus(); if (t && !/^Working/.test(t)) break; } await sleep(300); return t; };
const go = async hash => { await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150); await cmd('Page.navigate', { url: U + hash }); return ready(); };
const press = label => ev(`(() => { const b = [...document.querySelectorAll('main button, main input[type=checkbox]')].find(b => (b.getAttribute('aria-label') ?? b.textContent.trim()) === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
const newFile = async before => { for (let i = 0; i < 150; i++) { await sleep(200); const f = fs.readdirSync(dl).filter(n => n.endsWith('.xlsx') && !before.has(n)); if (f.length && !fs.readdirSync(dl).some(n => n.endsWith('.crdownload'))) return dl + '/' + f[0]; } return ''; };
const axe = async () => {
  await cmd('Runtime.evaluate', { expression: fs.readFileSync(axePath, 'utf8') });
  return await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => r.violations.reduce((n, v) => n + v.nodes.length, 0) + ' ' + r.violations.map(v => v.id + ':' + v.nodes.map(n => n.target.join(' ')).join(',')).join(';').slice(0, 600))`, true);
};
// the theme set as the page sets it at load (main.ts: data-theme on the root), so a page already drawn changes too
// (review P, P-2: the media emulation alone left data-theme="light" in force)
const theme = async t => { await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(t)}); document.documentElement.setAttribute('data-theme', ${JSON.stringify(t)}); 'ok'`); await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: t }] }); };
const bg = () => ev(`getComputedStyle(document.body).backgroundColor`);
const fileIn = async f => { const doc = await cmd('DOM.getDocument', { depth: 1 }); const node = await cmd('DOM.querySelector', { nodeId: doc.result.root.nodeId, selector: '#app-import-file' });
  return (await cmd('DOM.setFileInputFiles', { nodeId: node.result?.nodeId, files: [f] })).error ? 'error' : 'ok'; };
const submit = () => ev(`(() => { const f = [...document.querySelectorAll('main form')].find(f => f.getAttribute('aria-label') === 'Import a file'); if (!f) return false; f.requestSubmit(); return true; })()`);
const applyBtn = n => ev(`(() => { const b = [...document.querySelectorAll('main section.app-file button')].find(b => b.textContent.startsWith('Apply the import')); if (!b) return false; for (let i = 0; i < ${n}; i++) b.click(); return true; })()`);
const ticked = label => ev(`[...document.querySelectorAll('main input[type=checkbox]')].find(b => b.getAttribute('aria-label') === ${JSON.stringify(label)})?.checked ?? 'none'`);
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('DOM.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1100, deviceScaleFactor: 1, mobile: false });
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
out('login', await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(env.P_USR)}, password: ${JSON.stringify(env.P_UPW)} }) }).then(r => r.status)`, true));
await theme('light');
try {
 if (phase === '1') {
  // P1: an application's contacts shown, the Inventory filtered to imp-ms, the inventory's own export
  out('P1.ready', await go('#/admin_applications'));
  out('P1.open', await press('Open F Alpha')); await sleep(1200);
  out('P1.show', await press('Show contacts of F Alpha')); await sleep(1200);
  out('P1.shown', await ev(`document.body.textContent.includes(${JSON.stringify(env.P_FIONA)})`));
  out('P1.filter', await ev(`(() => { const s = document.querySelector('main section.app-file'); const i = [...s.querySelectorAll('input.filter')].find(x => x.getAttribute('aria-label') === 'Filter instance'); if (!i) return 'no filter';
    i.value = 'imp-ms'; i.dispatchEvent(new Event('input', { bubbles: true })); return 'ok'; })()`));
  await sleep(800);
  out('P1.visible', await ev(`[...document.querySelectorAll('main section.app-file table.grid tbody tr')].filter(r => r.getClientRects().length).length`));
  const before = new Set(fs.readdirSync(dl));
  out('P1.press', await press('Export the inventory (.xlsx)'));
  out('P1.file', (await newFile(before)) || 'none');
  out('P1.status', await fileStatus());
  out('P1.title', await ev(`[...document.querySelectorAll('main section.app-file button')].find(b => b.textContent.startsWith('Export the inventory'))?.title ?? ''`));
 } else {
  // P2: the file chosen, its source name typed, previewed, its conflict ticked, applied
  out('P2.ready', await go('#/admin_applications'));
  out('P2.source', await ev(`(() => { const s = document.querySelector('#app-import-source'); if (!s) return 'no field'; s.value = 'proof'; s.dispatchEvent(new Event('input', { bubbles: true })); return s.value; })()`));
  // C 5: the field's pattern compiles as the browser compiles it (the v flag) and refuses a name with a space
  out('P2.pattern', await ev(`(() => { const s = document.querySelector('#app-import-source'); try { new RegExp('^(?:' + s.pattern + ')$', 'v'); } catch (e) { return 'invalid'; } s.value = 'A B'; const bad = s.validity.patternMismatch; s.value = 'proof'; return bad ? 'ok' : 'no mismatch'; })()`));
  out('P2.set', await fileIn(p2file));
  out('P2.preview', await submit());
  out('P2.previewed', await settle());
  out('P2.counts', await ev(`document.querySelector('main [data-part=import-counts]')?.textContent ?? ''`));
  // P3 before the apply: axe with the preview shown, light and dark (the dark one checked to be dark)
  out('P3.light', await axe()); out('P3.bglight', await bg());
  await theme('dark'); await sleep(400); out('P3.bgdark', await bg()); out('P3.dark', await axe()); await theme('light'); await sleep(200);
  out('P2.tick', await press("Take line 3's change"));
  out('P2.apply', await applyBtn(2));   // a double click: one apply (C 4)
  out('P2.applied', await settle()); await sleep(1500); out('P2.after', await fileStatus());
  out('P2.focus', await ev(`document.activeElement?.closest('section.app-file') ? 'in' : (document.activeElement?.tagName ?? 'none') + ' ' + (document.activeElement?.textContent ?? '').slice(0, 40)`));
  // P4 (C 1): a tick kept by the item, never by the checkbox a redraw replaced
  out('P4.ready', await go('#/admin_applications'));
  out('P4.set', await fileIn(p4file)); out('P4.preview', await submit()); out('P4.previewed', await settle());
  out('P4.tick', await press("Take line 2's change"));
  out('P4.copy', await ev(`(() => { const td = document.querySelector('main [data-part=import-preview] table.grid tbody td'); if (!td) return 'no grid';
    td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 60, clientY: 60 }));
    const m = [...document.querySelectorAll('[role=menuitem]')].find(b => /^Copy all/.test(b.textContent.trim())); if (!m) return 'no menu'; m.click(); return 'ok'; })()`));
  await sleep(600);
  out('P4.untick', await press("Take line 2's change")); out('P4.onscreen', await ticked("Take line 2's change"));
  out('P4.apply', await applyBtn(1)); out('P4.applied', await settle());
 }
} catch (e) { out('ERROR', String(e?.message ?? e)); }
process.exit(0);
JS
if [[ $P_OK == 1 ]]; then
  # phase 1 (P1's export), its read back, then phase 2 (P2's apply): the read back before P2 changes the store (t-im-g3:
  # P2's unmark of f4 made P1's workbook, read after it, one mark to make)
  P_USR=$USR P_UPW=$UPW P_FIONA="fiona.$SUF@example.com" timeout 300 node "$WORK/p.mjs" "$CDP" "$U/" "$DL" "$AXE" "$WORK/p2.csv" 1 "$WORK/p4.csv" > "$WORK/p.out" 2> "$WORK/p.err"
  pv() { sed -n "s/^$1=//p" "$WORK/p.out" | head -1; }
  # P1: the workbook read back through the import's own preview; no contact, user or client in it
  F1X=$(pv P1.file); get applications/inventory >/dev/null; ninv=$(js "print(len(d['rows']))"); nms=$(js "print(sum(1 for r in d['rows'] if r[d['columns'].index('instance')] == 'imp-ms'))")
  if [[ -f "$F1X" ]]; then
    p=$(imp "$F1X" "dry=1"); pc="$(cnt lines)/$(cnt applications_added)/$(cnt applications_changed)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt refused)/$(cnt unknown_databases)"; kind=$(js "print(d.get('file', {}).get('kind'))")
    p1i=$(js "print('|'.join(i['outcome'] + ':' + i['words'][:50] for i in d.get('items', []))[:300])")
    sheets=$(unzip -p "$F1X" xl/workbook.xml | grep -o 'name="[^"]*"' | tr '\n' ' ')
    leak=$(unzip -p "$F1X" | grep -c -i -e 'Fiona Planted' -e "fiona.$SUF@" -e "555 7$SUF" -e "$USR" -e '127.0.0.1')
    about=$(unzip -p "$F1X" | grep -c 'whatever the grid')
    [[ $PMULTI == 1 && $(pv P1.shown) == true && $(pv P1.filter) == ok && $(pv P1.visible) == "$nms" && $p == 200 && $kind == xlsx && $pc == "$ninv/0/0/0/0/0/0" && $sheets == *'name="Inventory"'* && $leak == 0 \
       && $about -ge 1 && $(pv P1.title) == *"whatever the grid"* ]] \
      && ok "P1 contacts shown, the grid filtered to imp-ms ($(pv P1.visible) = its $nms lines drawn of $ninv): the inventory's own .xlsx holds all $ninv lines (read back: nothing to add, change or match - a two-line description, Yes and 1.50 as entered), sheet Inventory saying every line whatever the filter (the button too), no contact / user / client in it" \
      || bad "P1 two-line description stored $PMULTI; shown $(pv P1.shown), filter $(pv P1.filter), drawn $(pv P1.visible) of $nms imp-ms / $ninv; read back $p $kind $pc ($p1i); sheets $sheets; hits $leak; about $about; title '$(pv P1.title)'; status '$(pv P1.status)'"
  else bad "P1 no workbook downloaded (press $(pv P1.press); status '$(pv P1.status)'; $(head -c 200 "$WORK/p.err"))"; fi
  P_USR=$USR P_UPW=$UPW timeout 400 node "$WORK/p.mjs" "$CDP" "$U/" "$DL" "$AXE" "$WORK/p2.csv" 2 "$WORK/p4.csv" >> "$WORK/p.out" 2>> "$WORK/p.err"
  # P2
  [[ $(pv P2.source) == proof && $(pv P2.pattern) == ok && $(pv P2.set) == ok && $(pv P2.previewed) == Previewed* && $(pv P2.counts) == *"2 conflict"* && $(pv P2.tick) == true \
     && $(pv P2.applied) == Applied* && $(pv P2.after) == Applied* && $(pv P2.focus) == in \
     && $(asg imp-ms s1) == "F Gamma|import:proof" && $(q "select count(*) from pgvigil.app_not_application m join pgvigil.instances i using (instance_id) where i.name = 'imp-pg' and m.database_name = 'f4'") == 0 \
     && $(asg imp-pg =x) == "F Alpha|entered" ]] \
    && ok "P2 a file chosen, its source typed (the pattern compiles), previewed ('$(pv P2.counts | cut -c1-80)'), one of two conflicts ticked, applied by a double click (one apply, focus on the result): s1 assigned, f4's hand mark taken off, =x kept" \
    || bad "P2 source '$(pv P2.source)'; pattern '$(pv P2.pattern)'; set $(pv P2.set); '$(pv P2.previewed)'; counts '$(pv P2.counts)'; tick $(pv P2.tick); '$(pv P2.applied)' then '$(pv P2.after)'; focus '$(pv P2.focus)'; s1 $(asg imp-ms s1); =x $(asg imp-pg =x); $(pv ERROR) $(head -c 200 "$WORK/p.err")"
  # P3
  [[ $(pv P3.light) == "0 "* && $(pv P3.dark) == "0 "* && -n $(pv P3.bgdark) && $(pv P3.bgdark) != "$(pv P3.bglight)" ]] && ok "P3 axe-core 4.14.0 with the Inventory and the preview shown: 0 violation nodes, light and dark (the page's background $(pv P3.bglight) / $(pv P3.bgdark))" || bad "P3 light '$(pv P3.light)'; dark '$(pv P3.dark)'; background '$(pv P3.bglight)' / '$(pv P3.bgdark)'"
  # P4
  [[ $(pv P4.previewed) == Previewed* && $(pv P4.tick) == true && $(pv P4.copy) == ok && $(pv P4.untick) == true && $(pv P4.onscreen) == false && $(pv P4.applied) == Applied* && $(asg imp-pg =x) == "F Alpha|entered" ]] \
    && ok "P4 over 200 items: a conflict ticked, Copy all (every row drawn again), the tick taken off on screen, applied: =x kept, the person's" \
    || bad "P4 '$(pv P4.previewed)'; tick $(pv P4.tick); copy $(pv P4.copy); untick $(pv P4.untick) (on screen $(pv P4.onscreen)); '$(pv P4.applied)'; =x $(asg imp-pg =x); $(pv ERROR)"
fi
fi
fi

# ================= B: the limits (last: its 20000 targets would weigh on every read before it) =================
if want B; then
if [[ -z "${U:-}" ]]; then bad "B needs section F's serve (IMP_ONLY with F)"; else
# F13 (R13): over 5 MB, over 20000 lines: refused in words; 20000 lines previewed and applied inside the timeout
python3 -I -c 'import sys; open(sys.argv[1], "w").write("instance,application,description\n" + ("imp-pg,X," + "d" * 200 + "\n") * 26000)' "$WORK/big.csv"
c1=$(imp "$WORK/big.csv" "dry=1"); w1=$(js "print(d.get('error', ''))")
python3 -I -c 'import sys; open(sys.argv[1], "w").write("instance,application\n" + "imp-pg,X\n" * 20001)' "$WORK/many.csv"
c2=$(imp "$WORK/many.csv" "dry=1"); w2=$(js "print(d.get('error', ''))")
# 100 servers of 200 databases each: 20000 targets, as a fleet holds them
q "do \$d\$ declare k int; iid int; begin for k in 0..99 loop
     iid := pgvigil.ensure_instance('imp-big' || lpad(k::text, 3, '0'), 'onprem', '18.0', 180000, false, '{}'::text[]);
     perform pgvigil.import_databases(iid, now(), (select jsonb_agg(jsonb_build_object('dbid', 90000 + j, 'datname', 'b' || lpad(j::text, 3, '0'), 'is_template', false,
                                                   'allow_conn', true, 'can_connect', true, 'size_bytes', 1)) from generate_series(0, 199) j));
   end loop; end \$d\$" >/dev/null
python3 -I -c 'import sys; open(sys.argv[1], "w").write("instance,database,application\n" + "".join("imp-big%03d,b%03d,F Big\n" % (k, j) for k in range(100) for j in range(200)))' "$WORK/b20k.csv"
t0=$(date +%s); p=$(imp "$WORK/b20k.csv" "dry=1"); D13=$(dig); t1=$(date +%s)
x=$(imp "$WORK/b20k.csv" "dry=0&digest=$D13"); xo=$(js "print(d.get('outcome'), d.get('counts', {}).get('targets_changed'))"); t2=$(date +%s)
nb=$(q "select count(*) from pgvigil.app_assignments a join pgvigil.app_applications p using (app_id) where p.name = 'F Big'")
[[ $c1 == 413 && $w1 == *"over 5 MB"* && $c2 == 400 && $w2 == *"at most 20000"* && $p == 200 && $x == 200 && $xo == "done 20000" && $nb == 20000 ]] \
  && ok "F13 6 MB refused ('${w1:0:40}'), 20001 lines refused ('${w2:0:40}'); 20000 lines previewed in $((t1 - t0)) s and applied in $((t2 - t1)) s (20000 assignments)" \
  || bad "F13 5 MB: $c1 '$w1'; 20001: $c2 '$w2'; 20000: preview $p ($((t1 - t0)) s), apply $x '$xo' ($((t2 - t1)) s), assigned $nb; $(head -c 300 "$WORK/ans.json")"

fi
fi

echo "proof-app-import: $NFAIL FAIL"
[[ $NFAIL == 0 ]]
