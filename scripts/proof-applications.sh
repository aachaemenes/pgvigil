#!/usr/bin/env bash
# Proof of applications (task 310, migration 0136) on a throwaway repository database: the store's rows (section S).
# The API, the page and the owner-routed alerts add their sections as they are built.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a SUPERUSER (the proof creates pgvigil_proof_app_<n> and a
#                      reader login there, and drops both at the end)
#   PGVIGIL_BIN        the pgvigil binary (default bin/pgvigil)
#
# The store's API as this proof calls it (each write answers {outcome: done | refused, detail, ...} and writes one
# admin_audit row per attempt; ui_user and client come from the HTTP door):
#   import_app_application(at, {op add|edit|rename|remove, ui_user, client, app_id, version, name, description, tier,
#                               environment, cmdb_url, source, force, with_assignments})
#   import_app_contact(at, {op add|edit|remove, ui_user, app_id, contact_id, role, kind, name, email, phone})
#   import_app_assign(at, {op assign|unassign, ui_user, app_id, targets: [{instance_id, database}], environment, source,
#                          force})
#   app_effective(instance_id, database) -> (app_id, name, src 'database' | 'instance')
#   app_databases(app_id) -> (instance_id, database_name, own, absent_since, renamed_to)
#   app_unassigned() -> (instance_id, database_name): every present database with no effective application
#
# Rows (each 'ok' or 'FAIL'; the script goes on after a FAIL and exits 1 when any row failed):
#  S1  (A1) Billing assigned at instance P -> db1 and db2 of P resolve to Billing 'instance'; P's merged tags hold
#      'application:Billing'
#  S2  (A2) Payroll assigned to P.db2 -> db2 Payroll 'database', db1 Billing 'instance'; P's tags hold both
#  S3  (A3) Billing renamed 'Billing System: EU' with its read version -> P's tags hold the new tag and not the old one;
#      the rename's audit row names both names; a second rename with the old version is refused
#  S4  (A4) P.db2 unassigned -> db2 resolves to the instance's application; removing an assigned application is
#      refused, with with_assignments done, and no application:* tag is left on P
#  S5  (A5, both engines) a database assigned by its own row and then dropped on the server (PostgreSQL: not in the
#      next list read; SQL Server: is_present false, then the row deleted as 0090 does after 30 days) keeps its
#      assignment, shown with absent_since, and is not on app_unassigned(); its application's tag leaves the instance
#      when that absent database was its only assignment there (O-D11)
#  S6  (A6) a new database read on P is on app_unassigned() at once; template0 / template1 and SQL Server's master /
#      model / msdb / tempdb never are
#  S7  (A7) an entered description written with source 'import:cmdb' is refused 'conflict' and unchanged; with force
#      the import wins and the field's source is 'import:cmdb'
#  S8  (A8) every write attempt of this proof left its admin_audit row(s): one per target of an assign or unassign,
#      one for a refusal (each call carries its own client tag)
#  S9  (A9) P's application tags survive ensure_instance with config tags that lack them; a config tag
#      'application:Rogue' is not in P's merged tags; an override row on the key 'application' is refused by the table,
#      and Admin > Instances' write refuses a tag with the key 'application'
#  S10 (A10, the store's half) pgvigil_reader holds EXECUTE on no import_app_ function and SELECT on no ui_app_ table
#  S11 (A14, the store's half) a contact added and edited with a planted e-mail and phone: no admin_audit row holds
#      either value
#  S12 a PostgreSQL database renamed on the server (the same dbid) keeps no silent assignment under its new name:
#      app_databases shows the old name absent with renamed_to the new name
#  S13 one target twice in one assign call, and a call over 500 targets, are refused, nothing written
#  S14 an instance removed (its instances row deleted) takes its assignments with it (ON DELETE CASCADE)
#  S15 purge(30) leaves every app_ and ui_app_ row in place
#  S17 a pg threshold and a drive threshold scoped by application:Payroll: a rename without retag is refused naming
#      them; with retag the rename is done and both carry the new tag; an application whose tag scopes a drive
#      threshold is removed only with retag, which ends the threshold
#  S16 a database marked 'not an application' (import_app_assign op mark) leaves app_unassigned(); unmarked, it is back
# On a tree without 0136 every row FAILs as 'not on this tree': the red run.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
SUF=$RANDOM
DB=pgvigil_proof_app_$SUF; RD=pgvigil_app_rd_$SUF
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml
NFAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; NFAIL=$((NFAIL + 1)); }
cleanup() {
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" -c "drop role if exists $RD" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || { echo "FAIL setup: create database"; exit 1; }
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q()  { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { echo "FAIL setup: migrate"; tail -5 "$WORK/migrate.out"; exit 1; }
if [[ $(q "select to_regprocedure('pgvigil.import_app_application(timestamptz, jsonb)') is not null") != t ]]; then
  for row in S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15 S16 S17; do bad "$row not on this tree (no import_app_application)"; done
  echo "proof-applications: $NFAIL FAIL"; exit 1
fi

# write attempts of this proof, counted in a file: most calls run inside $(...), a subshell whose variables do not come
# back (the first run counted 10 of them and gave several calls one client tag)
: > "$WORK/calls"
wr() {    # $1 the function (application | contact | assign), $2 the payload's JSON without ui_user: the answer's JSON
  echo "$1" >> "$WORK/calls"
  q "select pgvigil.import_app_$1(now(), '{\"ui_user\": \"proof\", \"client\": \"proof-applications#$(wc -l < "$WORK/calls")\"}'::jsonb || '$2'::jsonb)"
}
field() { python3 -I -c 'import json, sys; v = json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }
tags()  { q "select array_to_string(tags, ',') from pgvigil.instance_tags_merged where instance_id = $1"; }
eff()   { q "select coalesce((select name || '/' || src from pgvigil.app_effective($1, '$2')), 'none')"; }
dbs()   { q "select pgvigil.import_databases($1, now(), '$2'::jsonb)" >/dev/null; }
pgdb()  { printf '{"dbid": %s, "datname": "%s", "is_template": %s, "allow_conn": true, "can_connect": true, "size_bytes": 1}' "$1" "$2" "${3:-false}"; }

PGI=$(q "select pgvigil.ensure_instance('proof-app-pg', 'onprem', '18.0', 180000, false, '{}'::text[])")
MSI=$(q "select pgvigil.ensure_instance('proof-app-ms', 'onprem', '16.0', 160000, false, '{}'::text[], 'sqlserver')")
dbs "$PGI" "[$(pgdb 1 template0 true), $(pgdb 2 template1 true), $(pgdb 5 postgres), $(pgdb 16384 db1), $(pgdb 16385 db2)]"
q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, is_system, snapshot_at) values
   ($MSI, 'master', 1, true, now()), ($MSI, 'model', 3, true, now()), ($MSI, 'msdb', 4, true, now()), ($MSI, 'tempdb', 2, true, now()),
   ($MSI, 'sales', 5, false, now()), ($MSI, 'hr', 6, false, now())" >/dev/null

# ---------------- S1 / S2 ----------------
ans=$(wr application '{"op": "add", "name": "Billing", "tier": 1, "environment": "production"}'); BILL=$(field "$ans" app_id)
ans=$(wr application '{"op": "add", "name": "Payroll", "tier": 2, "environment": "production"}'); PAY=$(field "$ans" app_id)
wr assign "{\"op\": \"assign\", \"app_id\": $BILL, \"targets\": [{\"instance_id\": $PGI, \"database\": null}]}" >/dev/null
r1="$(eff "$PGI" db1) $(eff "$PGI" db2)"
[[ $r1 == "Billing/instance Billing/instance" && ",$(tags "$PGI")," == *",application:Billing,"* ]] \
  && ok "S1 Billing at the instance: db1, db2 inherit it; the instance holds application:Billing" || bad "S1 db1 / db2: $r1; tags: $(tags "$PGI")"
wr assign "{\"op\": \"assign\", \"app_id\": $PAY, \"targets\": [{\"instance_id\": $PGI, \"database\": \"db2\"}]}" >/dev/null
r2="$(eff "$PGI" db1) $(eff "$PGI" db2)"; t2=",$(tags "$PGI"),"
[[ $r2 == "Billing/instance Payroll/database" && $t2 == *",application:Billing,"* && $t2 == *",application:Payroll,"* ]] \
  && ok "S2 db2 its own Payroll, db1 Billing inherited; the instance holds both tags" || bad "S2 db1 / db2: $r2; tags: $t2"

# ---------------- S3 ----------------
ver=$(q "select version from pgvigil.app_applications where app_id = $BILL")
ans=$(wr application "{\"op\": \"rename\", \"app_id\": $BILL, \"version\": $ver, \"name\": \"Billing System: EU\"}")
stale=$(wr application "{\"op\": \"rename\", \"app_id\": $BILL, \"version\": $ver, \"name\": \"Billing Again\"}")
t3=",$(tags "$PGI"),"; aud=$(q "select detail from pgvigil.admin_audit where op = 'app_rename' and outcome = 'done' order by audit_id desc limit 1")
[[ $(field "$ans" outcome) == done && $t3 == *",application:Billing System: EU,"* && $t3 != *",application:Billing,"* \
   && $aud == *"Billing"* && $aud == *"Billing System: EU"* && $(field "$stale" outcome) == refused ]] \
  && ok "S3 the rename follows into the tag at the next read; its audit row names both; a stale version refused" \
  || bad "S3 rename $(field "$ans" outcome) ($(field "$ans" detail)); tags $t3; audit '$aud'; stale: $(field "$stale" outcome) $(field "$stale" detail)"

# ---------------- S4 ----------------
wr assign "{\"op\": \"unassign\", \"app_id\": $PAY, \"targets\": [{\"instance_id\": $PGI, \"database\": \"db2\"}]}" >/dev/null
back=$(eff "$PGI" db2)
ver=$(q "select version from pgvigil.app_applications where app_id = $BILL")
rf=$(wr application "{\"op\": \"remove\", \"app_id\": $BILL, \"version\": $ver}")
dn=$(wr application "{\"op\": \"remove\", \"app_id\": $BILL, \"version\": $ver, \"with_assignments\": true}")
[[ $back == "Billing System: EU/instance" && $(field "$rf" outcome) == refused && $(field "$dn" outcome) == done && ",$(tags "$PGI")," != *",application:"* ]] \
  && ok "S4 db2 falls back to the instance's; an assigned application's remove refused, with with_assignments done; no application tag left" \
  || bad "S4 db2 $back; remove $(field "$rf" outcome) / with_assignments $(field "$dn" outcome) ($(field "$dn" detail)); tags $(tags "$PGI")"

# ---------------- S5 ----------------
wr assign "{\"op\": \"assign\", \"app_id\": $PAY, \"targets\": [{\"instance_id\": $PGI, \"database\": \"db1\"}, {\"instance_id\": $MSI, \"database\": \"hr\"}]}" >/dev/null
dbs "$PGI" "[$(pgdb 1 template0 true), $(pgdb 2 template1 true), $(pgdb 5 postgres), $(pgdb 16385 db2)]"   # db1 dropped
q "update pgvigil.mssql_database_option set is_present = false where instance_id = $MSI and database_name = 'hr'" >/dev/null
q "delete from pgvigil.mssql_database_option where instance_id = $MSI and database_name = 'hr'" >/dev/null   # 0090's delete after 30 days
abs=$(q "select string_agg(database_name || ':' || (absent_since is not null)::text, ',' order by database_name) from pgvigil.app_databases($PAY)")
un=$(q "select string_agg(database_name, ',' order by database_name) from pgvigil.app_unassigned() where database_name in ('db1', 'hr')")
[[ $abs == "db1:true,hr:true" && -z "$un" && ",$(tags "$PGI")," != *",application:Payroll,"* && ",$(tags "$MSI")," != *",application:Payroll,"* ]] \
  && ok "S5 a dropped database keeps its assignment, absent since, off Unassigned (both engines); its only tag leaves the instance" \
  || bad "S5 assignments [$abs]; unassigned [$un]; tags P $(tags "$PGI") S $(tags "$MSI")"

# ---------------- S6 ----------------
dbs "$PGI" "[$(pgdb 1 template0 true), $(pgdb 2 template1 true), $(pgdb 5 postgres), $(pgdb 16385 db2), $(pgdb 16390 db3)]"
un=$(q "select string_agg(database_name, ',' order by database_name) from pgvigil.app_unassigned() where instance_id in ($PGI, $MSI)")
[[ ",$un," == *",db3,"* && ",$un," != *",template0,"* && ",$un," != *",template1,"* && ",$un," != *",master,"* \
   && ",$un," != *",model,"* && ",$un," != *",msdb,"* && ",$un," != *",tempdb,"* ]] \
  && ok "S6 a new database is on Unassigned at its first read; no system database is" || bad "S6 unassigned: [$un]"

# ---------------- S16 ----------------
wr assign "{\"op\": \"mark\", \"targets\": [{\"instance_id\": $PGI, \"database\": \"postgres\"}]}" >/dev/null
m1=$(q "select count(*) from pgvigil.app_unassigned() where instance_id = $PGI and database_name = 'postgres'")
wr assign "{\"op\": \"unmark\", \"targets\": [{\"instance_id\": $PGI, \"database\": \"postgres\"}]}" >/dev/null
m2=$(q "select count(*) from pgvigil.app_unassigned() where instance_id = $PGI and database_name = 'postgres'")
[[ $m1 == 0 && $m2 == 1 ]] && ok "S16 a database marked 'not an application' leaves Unassigned; unmarked it is back" || bad "S16 on Unassigned marked: $m1, unmarked: $m2"

# ---------------- S7 ----------------
ver=$(q "select version from pgvigil.app_applications where app_id = $PAY")
wr application "{\"op\": \"edit\", \"app_id\": $PAY, \"version\": $ver, \"description\": \"typed\"}" >/dev/null
ver=$(q "select version from pgvigil.app_applications where app_id = $PAY")
cf=$(wr application "{\"op\": \"edit\", \"app_id\": $PAY, \"version\": $ver, \"description\": \"from cmdb\", \"source\": \"import:cmdb\"}")
d1=$(q "select description from pgvigil.app_applications where app_id = $PAY")
ver=$(q "select version from pgvigil.app_applications where app_id = $PAY")
fo=$(wr application "{\"op\": \"edit\", \"app_id\": $PAY, \"version\": $ver, \"description\": \"from cmdb\", \"source\": \"import:cmdb\", \"force\": true}")
d2=$(q "select description || '|' || (select source from pgvigil.app_field_source where object_kind = 'application' and object_id = $PAY and field = 'description') from pgvigil.app_applications where app_id = $PAY")
[[ $(field "$cf" outcome) == refused && $(field "$cf" detail) == *conflict* && $d1 == typed && $(field "$fo" outcome) == done && $d2 == "from cmdb|import:cmdb" ]] \
  && ok "S7 an entered field over an import refused 'conflict' and kept; forced, the import wins with its source" \
  || bad "S7 conflict: $(field "$cf" outcome) '$(field "$cf" detail)' kept '$d1'; forced: $(field "$fo" outcome) -> '$d2'"

# ---------------- S9 ----------------
wr assign "{\"op\": \"assign\", \"app_id\": $PAY, \"targets\": [{\"instance_id\": $PGI, \"database\": null}]}" >/dev/null
q "select pgvigil.ensure_instance('proof-app-pg', 'onprem', '18.0', 180000, false, array['env:prod', 'application:Rogue'])" >/dev/null
t9=",$(tags "$PGI"),"
ov=$(q "insert into pgvigil.instance_tag_overrides (instance_id, key, vals) values ($PGI, 'application', array['Rogue'])" 2>&1); ovrc=$?
ai=$(q "select pgvigil.import_admin_instance(now(), '{\"op\": \"add\", \"ui_user\": \"proof\", \"client\": \"proof-s9\", \"name\": \"pageinst\", \"engine\": \"postgres\", \"dsn_ref\": \"file:/x\", \"host\": \"h\", \"auth\": \"password\", \"tags\": [\"application:Rogue\"]}'::jsonb)")
[[ $t9 == *",application:Payroll,"* && $t9 == *",env:prod,"* && $t9 != *"Rogue"* && $ovrc != 0 && $(field "$ai" outcome) == refused && $(field "$ai" detail) == *Applications* ]] \
  && ok "S9 the application tag survives the collector's re-make; a file's application:Rogue is not taken; an override on the key refused" \
  || bad "S9 tags $t9; override rc $ovrc: ${ov:0:120}; Admin > Instances: $(field "$ai" outcome) '$(field "$ai" detail)'"

# ---------------- S10 ----------------
leak=$(q "select coalesce(string_agg(x, ', '), '') from (
  select p.proname::text x from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'pgvigil' and p.proname like 'import\_app\_%' and has_function_privilege('pgvigil_reader', p.oid, 'EXECUTE')
  union all
  select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'pgvigil' and c.relname like 'ui\_app\_%' and c.relkind in ('r', 'v') and has_table_privilege('pgvigil_reader', c.oid, 'SELECT')) z")
nf=$(q "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname like 'import\_app\_%'")
[[ -z "$leak" && $nf -ge 3 ]] && ok "S10 the reader may execute none of the $nf import_app_ functions and read no ui_app_ table" || bad "S10 the reader may use: [$leak] ($nf import_app_ functions)"

# ---------------- S11 ----------------
con=$(wr contact "{\"op\": \"add\", \"app_id\": $PAY, \"role\": \"technical owner\", \"kind\": \"person\", \"name\": \"Pat Planted\", \"email\": \"planted.$SUF@example.com\", \"phone\": \"+1 555 0$SUF\"}")
CID=$(field "$con" contact_id)
wr contact "{\"op\": \"edit\", \"contact_id\": $CID, \"email\": \"moved.$SUF@example.com\", \"phone\": \"+1 555 9$SUF\"}" >/dev/null
hits=$(q "select count(*) from pgvigil.admin_audit where detail ~ '(planted|moved)\\.$SUF@' or detail ~ '555 [09]$SUF'")
[[ -n "$CID" && $hits == 0 ]] && ok "S11 a contact's e-mail and phone, added and changed, appear in no audit row" || bad "S11 contact '$CID' ($(field "$con" detail)); audit rows with them: $hits"

# ---------------- S12 ----------------
wr assign "{\"op\": \"assign\", \"app_id\": $PAY, \"targets\": [{\"instance_id\": $PGI, \"database\": \"db3\"}]}" >/dev/null
dbs "$PGI" "[$(pgdb 1 template0 true), $(pgdb 2 template1 true), $(pgdb 5 postgres), $(pgdb 16385 db2), $(pgdb 16390 db3new)]"   # db3 renamed in place
rn=$(q "select database_name || ':' || (absent_since is not null)::text || ':' || coalesce(renamed_to, '') from pgvigil.app_databases($PAY) where own and database_name in ('db3', 'db3new')")
own=$(q "select count(*) from pgvigil.app_assignments where instance_id = $PGI and database_name = 'db3new'")
[[ $rn == "db3:true:db3new" && $own == 0 ]] && ok "S12 a renamed database's assignment stays on the old name, absent, renamed_to offered; none taken silently" \
  || bad "S12 [$rn], assignments on the new name: $own"

# ---------------- S17 ----------------
pname=$(q "select name from pgvigil.app_applications where app_id = $PAY")
pk=$(q "select min(key) from pgvigil.pg_threshold_keys")
q "insert into pgvigil.pg_thresholds (key, level, tag, warn, crit, created_by, created_at) values ('$pk', 'tag', 'application:$pname', 1, 2, 'proof', now())" >/dev/null
q "insert into pgvigil.drive_thresholds (level, tag, warn_pct, crit_pct, created_by, created_at) values ('tag', 'application:$pname', 20, 10, 'proof', now())" >/dev/null
ver=$(q "select version from pgvigil.app_applications where app_id = $PAY")
nt=$(wr application "{\"op\": \"rename\", \"app_id\": $PAY, \"version\": $ver, \"name\": \"Payroll Two\"}")
rt=$(wr application "{\"op\": \"rename\", \"app_id\": $PAY, \"version\": $ver, \"name\": \"Payroll Two\", \"retag\": true}")
tg=$(q "select (select string_agg(distinct tag, ',') from pgvigil.pg_thresholds where ended_at is null and tag like 'application:Payroll%') || '|' || (select string_agg(distinct tag, ',') from pgvigil.drive_thresholds where ended_at is null and tag like 'application:Payroll%')")
tmp=$(wr application '{"op": "add", "name": "Temp App"}'); TMP=$(field "$tmp" app_id)
q "insert into pgvigil.drive_thresholds (level, tag, warn_pct, crit_pct, created_by, created_at) values ('tag', 'application:Temp App', 20, 10, 'proof', now())" >/dev/null
ver=$(q "select version from pgvigil.app_applications where app_id = $TMP")
rm1=$(wr application "{\"op\": \"remove\", \"app_id\": $TMP, \"version\": $ver}")
rm2=$(wr application "{\"op\": \"remove\", \"app_id\": $TMP, \"version\": $ver, \"retag\": true}")
live=$(q "select count(*) from pgvigil.drive_thresholds where tag = 'application:Temp App' and ended_at is null")
[[ $(field "$nt" outcome) == refused && $(field "$nt" detail) == *"pg threshold"* && $(field "$nt" detail) == *"drive threshold"* \
   && $(field "$rt" outcome) == done && $tg == "application:Payroll Two|application:Payroll Two" \
   && $(field "$rm1" outcome) == refused && $(field "$rm2" outcome) == done && $live == 0 ]] \
  && ok "S17 a rename over tag-scoped thresholds refused unless ticked, then rewritten; a remove ends them only when ticked" \
  || bad "S17 rename unticked: $(field "$nt" outcome) '$(field "$nt" detail)'; ticked: $(field "$rt" outcome) -> [$tg]; remove: $(field "$rm1" outcome) / $(field "$rm2" outcome), live $live"

# ---------------- S13 ----------------
n0=$(q "select count(*) from pgvigil.app_assignments")
tw=$(wr assign "{\"op\": \"assign\", \"app_id\": $PAY, \"targets\": [{\"instance_id\": $MSI, \"database\": \"sales\"}, {\"instance_id\": $MSI, \"database\": \"sales\"}]}")
big=$(python3 -I -c "import json, sys; print(json.dumps({'op': 'assign', 'app_id': int(sys.argv[1]), 'targets': [{'instance_id': int(sys.argv[2]), 'database': 'x%d' % i} for i in range(501)]}))" "$PAY" "$MSI")
ov=$(wr assign "$big")
n1=$(q "select count(*) from pgvigil.app_assignments")
[[ $(field "$tw" outcome) == refused && $(field "$ov" outcome) == refused && $n0 == "$n1" ]] \
  && ok "S13 one target twice, and 501 targets, refused with nothing written" || bad "S13 twice: $(field "$tw" outcome) '$(field "$tw" detail)'; 501: $(field "$ov" outcome); rows $n0 -> $n1"

# ---------------- S15 (before S14 removes P) ----------------
before=$(q "select (select count(*) from pgvigil.app_applications) || '/' || (select count(*) from pgvigil.app_assignments) || '/' || (select count(*) from pgvigil.ui_app_contacts)")
q "select pgvigil.purge(30)" >/dev/null
after=$(q "select (select count(*) from pgvigil.app_applications) || '/' || (select count(*) from pgvigil.app_assignments) || '/' || (select count(*) from pgvigil.ui_app_contacts)")
[[ $before == "$after" ]] && ok "S15 purge(30) left the applications, assignments and contacts ($after)" || bad "S15 before $before, after $after"

# ---------------- S14 ----------------
np=$(q "select count(*) from pgvigil.app_assignments where instance_id = $PGI")
q "delete from pgvigil.instances where instance_id = $PGI" >/dev/null
nq=$(q "select count(*) from pgvigil.app_assignments where instance_id = $PGI")
[[ $np -gt 0 && $nq == 0 ]] && ok "S14 an instance's removal takes its $np assignments with it" || bad "S14 assignments of the removed instance: $np -> $nq"

# ---------------- S8 (last: every write attempt above) ----------------
NATT=$(wc -l < "$WORK/calls")
na=$(q "select count(distinct client) from pgvigil.admin_audit where op like 'app\_%' and client like 'proof-applications#%'")
nr=$(q "select count(*) from pgvigil.admin_audit where op like 'app\_%' and client like 'proof-applications#%' and outcome = 'refused'")
rc8=$(q "select count(*) from (select client from pgvigil.admin_audit where op like 'app\_%' and client like 'proof-applications#%' and outcome = 'refused' group by client having count(*) > 1) z")
[[ $na == "$NATT" && $rc8 == 0 ]] && ok "S8 every write attempt left its audit row(s) ($na of $NATT calls; $nr refusals, one row each)" || bad "S8 calls with audit rows $na of $NATT; refused calls with more than one row: $rc8"

echo "proof-applications: $NFAIL FAIL"
[[ $NFAIL == 0 ]]
