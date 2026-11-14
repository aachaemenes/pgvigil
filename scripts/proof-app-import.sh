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
#      its text in no answer or audit row;  F21 (R21) '(none)': nothing on an inheriting database, a conflict on a
#      person's own assignment, removed when ticked
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
FB=$(field "$(wi application '{"op": "add", "name": "F Beta", "description": "''=x"}')" app_id)
wp assign "{\"op\": \"assign\", \"app_id\": $FA, \"targets\": [{\"instance_id\": $PGF, \"database\": null}, {\"instance_id\": $MSF, \"database\": \"s1\"}, {\"instance_id\": $PGF, \"database\": \"fgone\"}, {\"instance_id\": $PGF, \"database\": \"=x\"}]}" >/dev/null
wp assign "{\"op\": \"assign\", \"app_id\": $FB, \"targets\": [{\"instance_id\": $PGF, \"database\": \"f1\"}]}" >/dev/null
wi assign "{\"op\": \"assign\", \"app_id\": $FB, \"targets\": [{\"instance_id\": $PGF, \"database\": \"f2\"}, {\"instance_id\": $MSF, \"database\": \"sgone\"}, {\"instance_id\": $PGF, \"database\": \"-name\"}]}" >/dev/null
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
p=$(imp "$WORK/inv.csv" "dry=1"); D1=$(dig); pc="$(cnt applications_added)/$(cnt applications_changed)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt unknown_servers)/$(cnt refused)"
a1=$(audits)
x=$(imp "$WORK/inv.csv" "dry=0&digest=$D1"); xo=$(js "print(d.get('outcome'))")
m1=$(appmd5); a2=$(audits)
[[ $c == 200 && $(head -c 3 "$WORK/inv.csv" | od -An -tx1 | tr -d ' ') == efbbbf && $(grep -ci 'attachment' "$WORK/inv.hdr") == 1 && $gone == *"fgone;2"* && $gone == *"sgone;2"* \
   && $keys == "'-name|'=x" && $inh == "f3;;F Alpha" && $p == 200 && $pc == "0/0/0/0/0/0" && $a1 == "$a0" && $x == 200 && $xo == done && $m1 == "$m0" && $a2 == $((a0 + 1)) ]] \
  && ok "F1 the CSV export imported as it is (both engines, absent fgone / sgone, inherited f3 blank, keys '=x' and '-name' guarded): 0 adds / changes / conflicts / unknown / refused; applied: the app_* rows' md5 the same, one summary audit row" \
  || bad "F1 export $c (absent '$gone'; keys '$keys'; f3 '$inh'); preview $p counts $pc; audit $a0 -> $a1 -> $a2; apply $x $xo; md5 same: $([[ $m1 == "$m0" ]] && echo yes || echo no); $(head -c 300 "$WORK/ans.json")"

# F2 (R2): an add, a change, a conflict and an unknown server, on both engines; F3 (R3) the conflict ticked
cat > "$WORK/f2.csv" <<CSV
instance,engine,database,application,environment
imp-pg,postgres,f3,F Alpha,test
imp-pg,postgres,f2,F Alpha,
imp-pg,postgres,f1,F Gamma,
imp-ms,sqlserver,s2,F Gamma,
imp-nowhere,postgres,x1,F Gamma,
CSV
n0=$(q "select count(*) from pgvigil.instances")
p=$(imp "$WORK/f2.csv" "dry=1"); D2=$(dig)
pc="$(cnt applications_added)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt unknown_servers)"
i3=$(item 4); i6=$(item 6)
x=$(imp "$WORK/f2.csv" "dry=0&digest=$D2"); xo=$(js "print(d.get('outcome'))")
st="$(asg imp-pg f3) $(asg imp-pg f2) $(asg imp-pg f1) $(asg imp-ms s2)"
[[ $p == 200 && $pc == "1/3/1/1" && $i3 == conflict:* && $i6 == refused:*"no server named imp-nowhere"* && $x == 200 && $xo == done \
   && $st == "F Alpha|import:proof F Alpha|import:proof F Beta|entered F Gamma|import:proof" && $(q "select count(*) from pgvigil.instances") == "$n0" ]] \
  && ok "F2 an add (F Gamma on s2), changes on both engines (f3 its own F Alpha in test, f2 re-assigned, s2), a conflict (f1 entered) and an unknown server: previewed exactly; applied unticked - the conflict kept, no server made" \
  || bad "F2 preview $p counts $pc (want 1/3/1/1); line 4 '$i3'; line 6 '$i6'; apply $x $xo; now $st; $(head -c 300 "$WORK/ans.json")"
p=$(imp "$WORK/f2.csv" "dry=1"); D3=$(dig)
x=$(imp "$WORK/f2.csv" "dry=0&digest=$D3&force=t4"); xo=$(js "print(d.get('outcome'))")
[[ $x == 200 && $xo == done && $(asg imp-pg f1) == "F Gamma|import:proof" ]] && ok "F3 the same conflict ticked (force t4): applied, source import:proof" || bad "F3 apply $x $xo; f1 $(asg imp-pg f1); $(head -c 300 "$WORK/ans.json")"

# F4 (R5) a page write between preview and apply: refused whole; F5 (R5b) a collector's list read between them: not refused
printf 'instance,database,application\nimp-pg,f2,F Beta\n' > "$WORK/f4.csv"
imp "$WORK/f4.csv" "dry=1" >/dev/null; D4=$(dig)
ver=$(q "select version from pgvigil.app_applications where app_id = $FA")
post admin/applications "{\"op\": \"edit\", \"app_id\": $FA, \"version\": $ver, \"description\": \"edited between\"}" >/dev/null
m0=$(appmd5); x=$(imp "$WORK/f4.csv" "dry=0&digest=$D4"); xd=$(js "print(d.get('detail', d.get('error', '')))"); m1=$(appmd5)
[[ $x == 409 && $xd == *"changed since the preview"* && $m1 == "$m0" ]] && ok "F4 a page write between the preview and the apply: refused whole ('${xd:0:80}'), nothing written" || bad "F4 $x '$xd'; md5 same: $([[ $m1 == "$m0" ]] && echo yes || echo no)"
imp "$WORK/f4.csv" "dry=1" >/dev/null; D5=$(dig)
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81002 f2), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no)]"
x=$(imp "$WORK/f4.csv" "dry=0&digest=$D5"); xo=$(js "print(d.get('outcome'))")
[[ $x == 200 && $xo == done && $(asg imp-pg f2) == "F Beta|import:proof" ]] && ok "F5 a collector's list read (last_seen, engine_db_id moved) between the preview and the apply: not refused, applied" || bad "F5 $x $xo; f2 $(asg imp-pg f2); $(head -c 300 "$WORK/ans.json")"

# F6 (R6): the export as a semicolon file (Excel in a comma-decimal locale) under the bar's two mark lines: no change
curl -s -o "$WORK/inv2.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"
python3 -I -c 'import csv, sys, io
t = open(sys.argv[1], encoding="utf-8-sig").read(); rows = list(csv.reader(io.StringIO(t)))
o = io.StringIO(); w = csv.writer(o, delimiter=";", lineterminator="\r\n"); w.writerow(["sample of a stored read"]); w.writerow(["read 2026-11-14 10:00"]); w.writerows(rows)
open(sys.argv[2], "w", encoding="utf-8-sig").write(o.getvalue())' "$WORK/inv2.csv" "$WORK/semi.csv"
p=$(imp "$WORK/semi.csv" "dry=1"); pc="$(cnt applications_added)/$(cnt applications_changed)/$(cnt targets_changed)/$(cnt conflicts)/$(cnt refused)/$(cnt lines)"
[[ $p == 200 && $pc == 0/0/0/0/0/* && ${pc##*/} -ge 12 ]] && ok "F6 a semicolon file under two mark lines reads as the export: no change ($pc)" || bad "F6 $p $pc; $(head -c 300 "$WORK/ans.json")"

# F7 (R7): '=SUM(1)' as a description: written guarded, read back exactly
printf "instance,database,application,description\nimp-pg,f3,F Gamma,=SUM(1)\n" > "$WORK/f7.csv"
imp "$WORK/f7.csv" "dry=1" >/dev/null; D7=$(dig); imp "$WORK/f7.csv" "dry=0&digest=$D7" >/dev/null
curl -s -o "$WORK/inv3.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"
stored=$(q "select description from pgvigil.app_applications where name = 'F Gamma'"); g7=$(grep -c "'=SUM(1)" "$WORK/inv3.csv")
p=$(imp "$WORK/inv3.csv" "dry=1"); pc="$(cnt applications_changed)/$(cnt targets_changed)"
[[ $stored == "=SUM(1)" && $g7 -ge 1 && $pc == 0/0 && $(q "select description from pgvigil.app_applications where name = 'F Beta'") == "'=x" ]] \
  && ok "F7 '=SUM(1)' and \"'=x\" as descriptions: stored as typed, written with one more ', read back with no change" || bad "F7 stored '$stored'; guarded cells $g7; re-import $pc"

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
python3 -I - "$WORK/inv4.csv" "$WORK/f10.xlsx" <<'PY'
import csv, io, sys, zipfile
from xml.sax.saxutils import escape
rows = list(csv.reader(io.StringIO(open(sys.argv[1], encoding="utf-8-sig").read())))
rows = [[c[1:] if c[:1] == "'" and c[1:2] in "=+-@" else c for c in r] for r in rows]   # the CSV's guard undone: an .xlsx has none
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
p=$(imp "$WORK/f10.xlsx" "dry=1"); pc="$(cnt applications_changed)/$(cnt targets_changed)/$(cnt refused)"; kind=$(js "print(d['file']['kind'])")
i10=$(js "print([i['words'] for i in d.get('items', []) if i['kind'] == 'target' and i['database'] == 'f3'])")
[[ $p == 200 && $kind == xlsx && $pc == 0/0/1 && $i10 == *"same database as line"* ]] \
  && ok "F10 an .xlsx (shared strings, blank cells left out, 'no' a boolean cell, 2024 a number): the export's rows read with no change; the extra f3 line refused as a second line of one database" \
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
CSV
p=$(imp "$WORK/f11.csv" "dry=1")
r11="$(item 2 | cut -c1-8)/$(item 3 | cut -c1-8)/$(item 4 | cut -c1-8)/$(item 5 | cut -c1-8)/$(item 6 | cut -c1-8)/$(item 7 | cut -c1-8)"
w11="$(item 3)|$(item 6)|$(item 7)"
[[ $p == 200 && $r11 == "refused:/refused:/refused:/refused:/refused:/conflict" && $w11 == *environment*"not an active server"*"marked by hand"* ]] \
  && ok "F11 a bad name, a bad environment, a bad tier, an application with not_an_application yes, an inactive server: each refused on its line; the unmark of a person's mark a conflict" \
  || bad "F11 $p lines 2-7 '$r11'; $w11"

# F12 (R12): a dry run and refused lines write no audit row; an apply one per change and one summary
a0=$(audits); imp "$WORK/f11.csv" "dry=1" >/dev/null; a1=$(audits)
printf 'instance,database,application\nimp-pg,f3,F Alpha\nimp-ms,s2,F Alpha\nimp-pg,f3x,F Alpha\n' > "$WORK/f12.csv"
imp "$WORK/f12.csv" "dry=1" >/dev/null; D12=$(dig); imp "$WORK/f12.csv" "dry=0&digest=$D12" >/dev/null; a2=$(audits)
sum=$(q "select detail from pgvigil.admin_audit where op = 'app_import' order by audit_id desc limit 1")
[[ $a1 == "$a0" && $a2 == $((a0 + 3)) && $sum == *"2 target(s) changed"*"1 unknown database"* && $sum != *f3x* ]] \
  && ok "F12 a dry run and refused lines: no audit row; an apply: one per change (2) and one summary of counts ('${sum:0:90}')" || bad "F12 audit $a0 -> $a1 -> $a2; summary '$sum'"

# F14 (R14): a store without 0146's functions answers in words, never a SQL error
q "alter function pgvigil.import_app_file(timestamptz, jsonb) rename to import_app_file_hidden" >/dev/null
c1=$(imp "$WORK/f4.csv" "dry=1"); w1=$(js "print(d.get('error', ''))"); c2=$(get applications/inventory.csv); w2=$(js "print(d.get('error', ''))")
q "alter function pgvigil.import_app_file_hidden(timestamptz, jsonb) rename to import_app_file" >/dev/null
[[ $c1 == 409 && $w1 == *"older than this pgvigil"*"pgvigil migrate"* && $c2 == 409 && $w2 == *"older than this pgvigil"* && $w1 != *SQLSTATE* ]] \
  && ok "F14 a repository without 0146's functions: the import and the CSV answer in words ('${w1:0:70}')" || bad "F14 $c1 '$w1'; $c2 '$w2'"

# F16 (R16): a database renamed on its server between export and import (the same dbid): the old file changes nothing
curl -s -o "$WORK/inv5.csv" -b "$WORK/cj" -H 'X-Pgvigil: 1' "$U/api/applications/inventory.csv"
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81002 f2new), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no)]"
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
printf 'instance,database,application,description\nimp-pg,f3,F Alpha,password=hunter2x%s\n' "$SUF" > "$WORK/f19.csv"
p=$(imp "$WORK/f19.csv" "dry=1"); w=$(item 2); D19=$(dig); imp "$WORK/f19.csv" "dry=0&digest=$D19" > /dev/null
hits=$(( $(grep -c "hunter2x$SUF" "$WORK/ans.json") + $(q "select count(*) from pgvigil.admin_audit where detail like '%hunter2x$SUF%' or target like '%hunter2x$SUF%'") ))
[[ $p == 200 && $w == refused:*credential* && $hits == 0 ]] && ok "F19 a credential-shaped cell: its line refused ('${w:0:70}'), its text in no answer and no audit row" || bad "F19 $p '$w'; hits $hits"

# F21 (R21): '(none)' on an inheriting database changes nothing; on a person's own assignment a conflict, removed when ticked
printf 'instance,database,application\nimp-pg,-name,(none)\nimp-ms,s1,(none)\n' > "$WORK/f21.csv"
dbs "$PGF" "[$(pgdb 5 postgres), $(pgdb 81001 f1), $(pgdb 81002 f2new), $(pgdb 81003 f3), $(pgdb 81004 f4), $(pgdb 81006 '=x'), $(pgdb 81007 '-name'), $(pgdb 81008 no), $(pgdb 81009 f5)]"
printf 'instance,database,application\nimp-pg,f5,(none)\nimp-ms,s1,(none)\n' > "$WORK/f21.csv"
p=$(imp "$WORK/f21.csv" "dry=1"); D21=$(dig); i2=$(js "print([i['words'] for i in d.get('items', []) if i.get('line') == 2])"); i3=$(item 3)
x=$(imp "$WORK/f21.csv" "dry=0&digest=$D21&force=t3")
[[ $p == 200 && $(cnt unchanged) -ge 1 && $i3 == conflict:*unassign* && $x == 200 && $(asg imp-ms s1) == none && $(asg imp-pg f5) == none ]] \
  && ok "F21 '(none)' on f5 (it inherits F Alpha): nothing; on s1 (a person's): a conflict, removed when ticked" || bad "F21 $p line 2 $i2 / line 3 '$i3'; apply $x; s1 $(asg imp-ms s1); $(head -c 300 "$WORK/ans.json")"
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

echo "proof-app-import: $NFAIL FAIL"
[[ $NFAIL == 0 ]]
