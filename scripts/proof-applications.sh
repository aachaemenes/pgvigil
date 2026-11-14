#!/usr/bin/env bash
# Proof of applications (task 310, migration 0136) on a throwaway repository database: the store's rows (section S).
# The API (H) and the page (P) follow; the owner-routed alerts add their section as they are built.
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
# Section H, the API (serve with a UI login on the same repository; the routes are 310's WIRING of web.go,
# scripts/proof-applications-wiring.patch, applied to the box's copy when the tree lacks them):
#  H1  GET /api/applications: 401 without a login; with one 200, can_edit true, the list holds the applications
#  H2  a POST that sends source 'import:x' is stored 'entered' (the HTTP door forces it)
#  H3  a POST without the X-Pgvigil header 403, without a login 401; nothing written by either
#  H4  an assign of 500 targets (a body over 16 KB) reaches the store's answer (409, its reason); 501 targets 409
#      'at most 500'; a body over the door's 64 KB 400
#  H5  contacts come only from GET /api/applications/{id}/contacts with a login: the planted e-mail and phone are in its
#      answer and in neither the list's nor one application's
#  H6  a serve with -no-login: the contacts' GET 403 'contacts hidden: the login is off'; every POST 403
#  H7  GET /api/applications/unassigned lists a present database with no application
# Section P, the page (Admin > Applications, web/src/applications.ts; its tab and route a WIRING of router.ts and
# main.ts in the same patch; the bundle built from the tree; a headless Chromium over CDP on section H's two serves):
#  P1  the Admin strip lists Applications; the page lists exactly the store's applications
#  P2  Add through the form: stored with tier, environment and description, every field 'entered' by the signed-in user
#  P3  one application opened: its fields with their sources; Edit stores the description, version 2
#  P4  contacts on a click only: a planted e-mail is not on the page before 'Show contacts', is after; a contact added
#      through the form is stored and listed
#  P5  two Unassigned rows ticked and 'Assign the selected' (one call, two audit rows): stored with the environment,
#      gone from Unassigned, listed 'own' on the application
#  P6  Mark the selected not an application: gone from Unassigned, stored, Unmark offered; Unmark: back, the mark gone
#  P7  Rename with a threshold scoped by the tag: refused without the tick (the store's words), done with it, re-tagged
#  P8  Remove asked twice: refused without 'with its assignments', done with the ticks; assignment and threshold gone
#  P9  a PostgreSQL database renamed on the server: 'absent since' and 'renamed to' shown; 'Assign <new> instead' moves it
#  P10 the -no-login serve: at least 8 write controls, every one off with a visible reason; contacts in words
#  P11 axe-core 4.14.0 on the page (an application and its contacts open) light and dark, and read only: 0 nodes
#  P12 the page's Export .xlsx passes scripts/xlsx-check.py and holds no contact value (contacts not shown)
# Section O, owner-routed alerts (a contact's route through a configured smtp channel: one derived channel per route,
# 'contact-<route_id>', the base's relay, repeat, clear_after, quiet hours and cap, scoped by the application's tag;
# real passes of 'pgvigil alerts' against a loopback SMTP sink that keeps each message with its RCPT list):
#  O1  a finding on A's instance mailed to A's routed contact; none of B's to her, none of A's to B's; the base keeps
#      its own scope
#  O2  the route repeats as its base (nothing at once, a repeat after 6 minutes with repeat 5m); its channel row's numbers
#  O3  the base's quiet hours hold its route; the base's max_per_hour caps the route as its own channel
#  O4  a 550 naming the address is logged as 'contact <id>'; no planted address in alert_log, alert_channels,
#      admin_audit, alert_tests, alert_state, the passes' output, the Alerts, rules or Report mail answers
#  O5  a reader login: the routes' door refuses it; ui_app_contact_routes not readable
#  O6  a route whose channel is not in the config sends nothing, named once in three passes
#  O7  a changed e-mail followed at the next pass; the contact removed: its open rows closed with no message
#  O8  an instance carrying A (the instance) and B (one database): its finding mailed to both contacts
#  O9  one address on two contact rows: two copies (O-D7)      O10 a team's group address routed
#  O11 a route through a 63-character base; a repository-wide finding goes to the base, to no route
#  O12 an application name at the tag's 100-byte cap          O13 an address Go's parser refuses: that route alone skipped
#  O14 a route off: its open rows closed with no message; on again: no stale recovery
#  O15 the routes' door failing: the config's channels still send, no route row closed
#  O16 the Send test refused on a route's channel             O17 Report mail and the rules page count config channels only
#  O18 the contacts' answer carries the routes and the configured smtp channels
#  O19 the page: a route added and turned off by clicks; axe 0 nodes with the routes shown
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

# ================= H: the API =================
if [[ -z "${APP_SKIP_HTTP:-}" ]]; then
USR=proofuser; UPW="pw-$SUF-$RANDOM"
printf 'repository:\n  dsn: "%s"\ninstances: []\n' "$PGVIGIL_REPO_DSN" > "$WORK/serve.yaml"
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$WORK/serve.yaml" "$USR" > "$WORK/useradd.out" 2>&1 || bad "H setup: user add ($(tail -1 "$WORK/useradd.out"))"
freeport() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
startserve() {   # $1 port, then serve's own flags
  local port=$1; shift
  "$BIN" serve -config "$WORK/serve.yaml" -listen "127.0.0.1:$port" "$@" > "$WORK/serve-$port.log" 2>&1 & SPIDS+=($!)
  for _ in $(seq 1 100); do curl -s -o /dev/null "http://127.0.0.1:$port/api/session" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
SPIDS=(); trap 'for x in "${SPIDS[@]}"; do kill "$x" 2>/dev/null; done; cleanup' EXIT
PORT=$(freeport); U="http://127.0.0.1:$PORT"
startserve "$PORT" || bad "H setup: serve did not answer ($(tail -3 "$WORK/serve-$PORT.log" | tr '\n' ' '))"
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$WORK/login.json"
lg=$(curl -s -o /dev/null -w '%{http_code}' -c "$WORK/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$WORK/login.json" "$U/api/login")
get()  { curl -s -o "$WORK/ans.json" -w '%{http_code}' -b "$WORK/cj" -H 'X-Pgvigil: 1' "$1/api/$2"; }
post() { printf '%s' "$3" > "$WORK/body.json"; curl -s -o "$WORK/ans.json" -w '%{http_code}' -b "$WORK/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$WORK/body.json" "$1/api/$2"; }
js() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); exec(sys.argv[2])' "$WORK/ans.json" "$1"; }

# H1
c0=$(curl -s -o /dev/null -w '%{http_code}' "$U/api/applications")
c1=$(get "$U" applications)
h1=$(js 'r = d["applications"]; i = r["columns"].index("name"); print(d.get("can_edit"), "|".join(sorted(x[i] for x in r["rows"])))' 2>&1)
[[ $lg == 200 && $c0 == 401 && $c1 == 200 && $h1 == "True "* && $h1 == *"Payroll Two"* ]] \
  && ok "H1 the list: 401 without a login; with one 200, can_edit, the applications ($h1)" || bad "H1 login $lg; no login $c0; with $c1: ${h1:0:200}"

# H2
c2=$(post "$U" admin/applications '{"op": "add", "name": "Http App", "tier": 3, "source": "import:sneak"}')
HAPP=$(js 'print(d.get("app_id", ""))' 2>/dev/null)
src=$(q "select string_agg(distinct source, ',') from pgvigil.app_field_source where object_kind = 'application' and object_id = ${HAPP:-0}")
[[ $c2 == 200 && -n "$HAPP" && $src == entered ]] && ok "H2 a POST's source is 'entered' whatever the body says" || bad "H2 $c2 app '$HAPP', sources [$src]: $(head -c 200 "$WORK/ans.json")"

# H3
n0=$(q "select count(*) from pgvigil.app_applications")
c3a=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/cj" -H 'Content-Type: application/json' --data '{"op": "add", "name": "No Header"}' "$U/api/admin/applications")
c3b=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data '{"op": "add", "name": "No Login"}' "$U/api/admin/applications")
n1=$(q "select count(*) from pgvigil.app_applications")
[[ $c3a == 403 && $c3b == 401 && $n0 == "$n1" ]] && ok "H3 no X-Pgvigil 403, no login 401, nothing written" || bad "H3 no header $c3a, no login $c3b, applications $n0 -> $n1"

# H4
big() { python3 -I -c 'import json, sys; print(json.dumps({"op": "assign", "app_id": int(sys.argv[1]), "targets": [{"instance_id": int(sys.argv[2]), "database": "missing_database_%05d" % i} for i in range(int(sys.argv[3]))]}))' "$HAPP" "$MSI" "$1"; }
b500=$(big 500); c4a=$(post "$U" admin/applications/assign "$b500"); d4a=$(js 'print(d.get("detail", ""))' 2>&1)
c4b=$(post "$U" admin/applications/assign "$(big 501)"); d4b=$(js 'print(d.get("detail", ""))' 2>&1)
c4c=$(post "$U" admin/applications/assign "$(python3 -I -c 'print("{\"op\": \"assign\", \"pad\": \"" + "x" * 70000 + "\"}")')")
[[ ${#b500} -gt 16384 && $c4a == 409 && $d4a == *"not a database"* && $c4b == 409 && $d4b == *"at most 500"* && $c4c == 400 ]] \
  && ok "H4 500 targets (${#b500} bytes) reach the store's answer; 501 refused 'at most 500'; a body over 64 KB 400" \
  || bad "H4 500: $c4a '${d4a:0:100}' (${#b500} bytes); 501: $c4b '${d4b:0:100}'; oversize: $c4c"

# H5
post "$U" admin/applications/contacts "{\"op\": \"add\", \"app_id\": $HAPP, \"role\": \"support\", \"kind\": \"person\", \"name\": \"Hal Http\", \"email\": \"h5.$SUF@example.com\", \"phone\": \"+1 555 5$SUF\"}" >/dev/null
c5a=$(get "$U" "applications/$HAPP/contacts"); in_c=$(grep -c "h5.$SUF@example.com" "$WORK/ans.json"); grep -q "555 5$SUF" "$WORK/ans.json" && in_p=1 || in_p=0
get "$U" applications >/dev/null; l5=$(grep -c "h5.$SUF\|555 5$SUF" "$WORK/ans.json")
get "$U" "applications/$HAPP" >/dev/null; o5=$(grep -c "h5.$SUF\|555 5$SUF" "$WORK/ans.json")
[[ $c5a == 200 && $in_c == 1 && $in_p == 1 && $l5 == 0 && $o5 == 0 ]] && ok "H5 contacts only from their own GET with a login; none in the list or one application's answer" \
  || bad "H5 contacts GET $c5a (e-mail $in_c, phone $in_p); in the list $l5; in one application $o5"

# H7
c7=$(get "$U" applications/unassigned); h7=$(js 'r = d["unassigned"]; i = r["columns"].index("database_name"); print(",".join(x[i] for x in r["rows"]))' 2>&1)
[[ $c7 == 200 && ",$h7," == *",sales,"* ]] && ok "H7 Unassigned lists a present database with no application (sales)" || bad "H7 $c7: ${h7:0:200}"

# H6 (a second serve, -no-login, on the same repository)
P6=$(freeport)
if startserve "$P6" -no-login; then
  c6a=$(curl -s -o "$WORK/ans.json" -w '%{http_code}' -H 'X-Pgvigil: 1' "http://127.0.0.1:$P6/api/applications/$HAPP/contacts"); d6=$(cat "$WORK/ans.json")
  c6b=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data '{"op": "add", "name": "No Login Serve"}' "http://127.0.0.1:$P6/api/admin/applications")
  [[ $c6a == 403 && $d6 == *"contacts hidden: the login is off"* && $c6b == 403 ]] && ok "H6 -no-login: contacts 403 'contacts hidden: the login is off', a POST 403" \
    || bad "H6 contacts $c6a '${d6:0:120}', POST $c6b"
else bad "H6 setup: the -no-login serve did not answer ($(tail -3 "$WORK/serve-$P6.log" | tr '\n' ' '))"; fi
# ================= P: the page (Admin > Applications in a headless Chromium over CDP, on the H section's serves) =================
# the bundle is built from this tree on the box (.ap/run.sh: npm ci, npm run build) with 310's WIRING of router.ts and
# main.ts applied; a binary without the page's route is the red: every P row 'not on this tree'
PROWS="P1 P2 P3 P4 P5 P6 P7 P8 P9 P10 P11 P12"
if ! grep -a -q 'admin_applications' "$BIN"; then
  for row in $PROWS; do bad "$row not on this tree (no Admin > Applications in the bundle)"; done
else
P_SET=1
for t in chromium node npm unzip; do command -v $t >/dev/null || { P_SET=0; bad "P setup: $t is not on this machine"; }; done
# the page's own fleet: a PostgreSQL instance (pdb1-pdb3) and a SQL Server one (Orders, Ledger); 'Page Rename' on pdb3
# with a pg threshold scoped by its tag
PPI=$(q "select pgvigil.ensure_instance('proof-page-pg', 'onprem', '18.0', 180000, false, '{}'::text[])")
PMI=$(q "select pgvigil.ensure_instance('proof-page-ms', 'onprem', '16.0', 160000, false, '{}'::text[], 'sqlserver')")
dbs "$PPI" "[$(pgdb 40001 pdb1), $(pgdb 40002 pdb2), $(pgdb 40003 pdb3)]"
q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, is_system, snapshot_at) values
   ($PMI, 'Orders', 7, false, now()), ($PMI, 'Ledger', 8, false, now())" >/dev/null
ans=$(wr application '{"op": "add", "name": "Page Rename", "tier": 3}'); PREN=$(field "$ans" app_id)
wr assign "{\"op\": \"assign\", \"app_id\": $PREN, \"targets\": [{\"instance_id\": $PPI, \"database\": \"pdb3\"}]}" >/dev/null
pk=$(q "select min(key) from pgvigil.pg_threshold_keys")
q "insert into pgvigil.pg_thresholds (key, level, tag, warn, crit, created_by, created_at) values ('$pk', 'tag', 'application:Page Rename', 1, 2, 'proof', now())" >/dev/null
TEAM="page-team.$SUF@example.com"
CDP=$(freeport); DL=$WORK/dl; mkdir -p "$DL"
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu --window-size=1500,1100 about:blank > "$WORK/chrome.log" 2>&1 & SPIDS+=($!)
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
(cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1); AXE=$WORK/node_modules/axe-core/axe.min.js
[[ -f "$AXE" ]] || { P_SET=0; bad "P setup: axe-core 4.14.0 did not install"; }
cat > "$WORK/p.mjs" <<'JS'
// the page clicked as a user would: each step prints KEY=value; the shell grades the lines and the store
const [port, U, U6, dl, axePath, mode] = process.argv.slice(2);   // mode 'routes': section O's O19 only
const fs = await import('node:fs');
const { execFileSync } = await import('node:child_process');
const env = process.env;
const sql = s => execFileSync('psql', [env.PGVIGIL_REPO_DSN, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', s], { encoding: 'utf8' }).trim();
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
const status = () => ev(`document.querySelector('main .applications p[role=status]')?.textContent ?? ''`);
const ready = async () => { for (let i = 0; i < 150; i++) { if (await ev(`!!document.querySelector('main .applications h2')`) && !/^Working/.test(await status())) { await sleep(300); return true; } await sleep(200); } return false; };
const settle = async () => { let t = ''; for (let i = 0; i < 300; i++) { await sleep(150); t = await status(); if (!/^Working/.test(t)) break; } await sleep(300); return t; };
const go = async (base, hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150); await cmd('Page.navigate', { url: base + hash }); return ready(); };
// a button or a tick by its aria-label; the status line after it settles
const click = async label => {
  const ok = await ev(`(() => { const b = [...document.querySelectorAll('main button, main input[type=checkbox]')].find(b => b.getAttribute('aria-label') === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
  return ok ? await settle() : `NOT FOUND ${label}`;
};
const formOf = label => `[...document.querySelectorAll('main form')].find(f => f.getAttribute('aria-label') === ${JSON.stringify(label)})`;
// a form's fields by name: a tick takes true / false, a list its option's value or its words
const fill = (form, vals) => ev(`(() => { const f = ${formOf(form)}; if (!f) return 'no form'; for (const [k, v] of Object.entries(${JSON.stringify(vals)})) {
  const c = f.querySelector('[name="' + k + '"]'); if (!c) return 'no field ' + k;
  if (c.type === 'checkbox') c.checked = !!v;
  else if (c.tagName === 'SELECT' && ![...c.options].some(o => o.value === v)) { const o = [...c.options].find(o => o.textContent.trim() === v); if (!o) return 'no option ' + v; c.value = o.value; }
  else c.value = v;
  c.dispatchEvent(new Event('input', { bubbles: true })); c.dispatchEvent(new Event('change', { bubbles: true })); } return 'ok'; })()`);
const submit = async form => (await ev(`(() => { const f = ${formOf(form)}; if (!f) return false; f.requestSubmit(); return true; })()`)) ? await settle() : `NOT FOUND form ${form}`;
// one application's servers and databases as the page lists them: a row per tr, keyed by the header's labels
const panelRows = name => ev(`(() => { const s = document.querySelector('main section[aria-label=' + JSON.stringify('Application ' + ${JSON.stringify(name)}) + ']'); if (!s) return null;
  const t = s.querySelector('table.grid[data-part=databases]'); if (!t) return [];
  const h = [...t.querySelectorAll('thead tr:first-child th')].map(x => (x.querySelector('.th-label') ?? x).textContent.trim());
  return [...t.querySelectorAll('tbody tr')].map(r => Object.fromEntries([...r.children].map((c, i) => [h[i], c.textContent.replace(/\\s+/g, ' ').trim()]))); })()`);
const ticks = () => ev(`[...document.querySelectorAll('main input[type=checkbox]')].map(c => c.getAttribute('aria-label') ?? '').filter(l => l.startsWith('Select ')).join('|')`);
const axe = async () => {
  await cmd('Runtime.evaluate', { expression: fs.readFileSync(axePath, 'utf8') });
  return await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => r.violations.reduce((n, v) => n + v.nodes.length, 0) + ' ' + r.violations.map(v => v.id + ':' + v.nodes.map(n => n.target.join(' ')).join(',')).join(';').slice(0, 600))`, true);
};
const theme = async t => { await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(t)}); 'ok'`); await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: t }] }); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1100, deviceScaleFactor: 1, mobile: false });
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
out('login', await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(env.P_USR)}, password: ${JSON.stringify(env.P_UPW)} }) }).then(r => r.status)`, true));
await theme('light');
if (mode === 'routes') {
  // O19: a route added for Dee on the page and turned off, by clicks; axe with the routes shown
  try {
    await go(U, '#/admin_applications'); await click('Open O App D'); await click('Show contacts of O App D');
    out('R.fill', await fill('Route alerts of O App D', { contact_id: 'Dee', channel: 'mail', min_severity: 'warning' }));
    out('R.status', await submit('Route alerts of O App D'));
    out('R.added', await ev(`[...document.querySelectorAll('main button')].some(b => b.getAttribute('aria-label') === 'Turn off the route of Dee via mail')`));
    out('R.off', await click('Turn off the route of Dee via mail'));
    out('R.axe', await axe());
  } catch (e) { out('ERROR', String(e?.message ?? e)); }
  ws.close(); bws.close(); process.exit(0);
}
try {
  // P1 the tab and the list
  out('P1.ready', await go(U, '#/admin_applications'));
  out('P1.strip', await ev(`[...document.querySelectorAll('#tabs a')].map(a => a.textContent.trim()).join('|')`));
  out('P1.names', await ev(`[...document.querySelectorAll('main .applications button')].map(b => b.getAttribute('aria-label') ?? '').filter(l => l.startsWith('Open ')).map(l => l.slice(5)).join('|')`));
  // P2 add through the form
  out('P2.fill', await fill('Add an application', { name: 'Page Added', tier: '2', environment: 'test', description: 'added by the page' }));
  out('P2.status', await submit('Add an application'));
  out('P2.store', sql(`select tier || '|' || environment || '|' || description || '|' || (select string_agg(distinct source || '/' || set_by, ',') from pgvigil.app_field_source f where f.object_kind = 'application' and f.object_id = a.app_id) from pgvigil.app_applications a where name = 'Page Added'`));
  // P3 open it: each field's source; edit the description
  out('P3.open', await click('Open Page Added'));
  out('P3.sources', await ev(`document.querySelector('main section[aria-label="Application Page Added"]')?.textContent.replace(/\\s+/g, ' ').match(/entered by \\S+/g)?.length ?? 0`));
  out('P3.fill', await fill('Edit Page Added', { description: 'edited by the page' }));
  out('P3.status', await submit('Edit Page Added'));
  // P4 contacts on a click only; a contact added through the form
  out('P4.open', await click('Open Http App'));
  out('P4.before', await ev(`document.body.textContent.includes(${JSON.stringify(env.P_EMAIL)})`));
  out('P4.show', await click('Show contacts of Http App'));
  out('P4.after', await ev(`document.body.textContent.includes(${JSON.stringify(env.P_EMAIL)})`));
  out('P4.fill', await fill('Add a contact to Http App', { role: 'technical owner', kind: 'team', name: 'Page Team', email: env.P_TEAM }));
  out('P4.status', await submit('Add a contact to Http App'));
  out('P4.listed', await ev(`document.body.textContent.includes(${JSON.stringify(env.P_TEAM)})`));
  // P5 two Unassigned rows ticked, assigned in one call
  await go(U, '#/admin_applications');
  out('P5.before', await ticks());
  await click('Select pdb1 on proof-page-pg'); await click('Select Orders on proof-page-ms');
  out('P5.fill', await fill('Assign the selected databases', { app_id: 'Page Added', environment: 'production' }));
  out('P5.status', await submit('Assign the selected databases'));
  out('P5.after', await ticks());
  out('P5.store', sql(`select string_agg(i.name || '/' || x.database_name || '/' || x.environment || '/' || x.set_by, ',' order by i.name) from pgvigil.app_assignments x join pgvigil.instances i using (instance_id) join pgvigil.app_applications a using (app_id) where a.name = 'Page Added'`));
  out('P5.audit', sql(`select count(*) from pgvigil.admin_audit where op = 'app_assign' and outcome = 'done' and ui_user = '${env.P_USR}' and target in ('instance ${env.P_PPI} database pdb1', 'instance ${env.P_PMI} database Orders')`));
  await click('Open Page Added');
  out('P5.rows', (await panelRows('Page Added') ?? []).map(r => `${r.database}:${r.assigned}:${r.environment}`).join('|'));
  // P6 mark and unmark
  await click('Select Ledger on proof-page-ms');
  out('P6.status', await click('Mark the selected not an application'));
  out('P6.gone', !(await ticks()).split('|').includes('Select Ledger on proof-page-ms'));
  out('P6.unmarkable', await ev(`[...document.querySelectorAll('main button')].some(b => b.getAttribute('aria-label') === 'Unmark Ledger on proof-page-ms')`));
  out('P6.store', sql(`select count(*) from pgvigil.app_not_application where instance_id = ${env.P_PMI} and database_name = 'Ledger'`));
  out('P6.unmark', await click('Unmark Ledger on proof-page-ms'));
  out('P6.back', (await ticks()).split('|').includes('Select Ledger on proof-page-ms'));
  // P7 rename with a tag-scoped threshold: refused without the tick, done with it
  await click('Open Page Rename');
  out('P7.fill', await fill('Rename Page Rename', { new_name: 'Page Renamed' }));
  out('P7.refused', await submit('Rename Page Rename'));
  out('P7.fill2', await fill('Rename Page Rename', { new_name: 'Page Renamed', retag: true }));
  out('P7.done', await submit('Rename Page Rename'));
  out('P7.store', sql(`select (select count(*) from pgvigil.pg_thresholds where ended_at is null and tag = 'application:Page Renamed') || '|' || (select count(*) from pgvigil.pg_thresholds where ended_at is null and tag = 'application:Page Rename') || '|' || (select count(*) from pgvigil.app_applications where name = 'Page Renamed')`));
  // P8 remove an assigned application: asked twice; refused without its ticks, done with them
  out('P8.ask', await click('Remove Page Renamed'));
  out('P8.refused', await click('Confirm: remove Page Renamed'));
  out('P8.fill', await fill('Remove Page Renamed', { with_assignments: true, retag: true }));
  await click('Remove Page Renamed');
  out('P8.done', await click('Confirm: remove Page Renamed'));
  // P9 pdb1 renamed on the server (the same dbid): absent since, renamed to, and the offer taken
  sql(`select pgvigil.import_databases(${env.P_PPI}, now(), '[{"dbid": 40001, "datname": "pdb1_new", "is_template": false, "allow_conn": true, "can_connect": true, "size_bytes": 1},
       {"dbid": 40002, "datname": "pdb2", "is_template": false, "allow_conn": true, "can_connect": true, "size_bytes": 1},
       {"dbid": 40003, "datname": "pdb3", "is_template": false, "allow_conn": true, "can_connect": true, "size_bytes": 1}]'::jsonb)`);
  await go(U, '#/admin_applications'); await click('Open Page Added');
  const r9 = (await panelRows('Page Added') ?? []).find(r => r.database === 'pdb1') ?? {};
  out('P9.row', `${r9['absent since'] ?? '-'}|${r9['renamed to'] ?? '-'}`);
  out('P9.offer', await click('Assign pdb1_new to Page Added instead'));
  out('P9.after', (await panelRows('Page Added') ?? []).map(r => `${r.database}:${r.assigned}`).join('|'));
  // P12 the page's export with an application open and its contacts not shown
  await go(U, '#/admin_applications'); await click('Open Http App');
  const before = new Set(fs.readdirSync(dl));
  out('P12.press', await ev(`(() => { const b = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Export .xlsx'); if (!b) return false; b.click(); return true; })()`));
  let file = '';
  for (let i = 0; i < 100 && !file; i++) { await sleep(200); const f = fs.readdirSync(dl).filter(n => n.endsWith('.xlsx') && !before.has(n)); if (f.length && !fs.readdirSync(dl).some(n => n.endsWith('.crdownload'))) file = dl + '/' + f[0]; }
  out('P12.file', file || 'none');
  // P11 axe on the page with an application and its contacts open, light and dark
  for (const t of ['light', 'dark']) {
    await theme(t); await go(U, '#/admin_applications'); await click('Open Http App'); await click('Show contacts of Http App');
    out(`P11.${t}`, await axe());
  }
  // P10 the -no-login serve: every write control off with a visible reason; contacts in words; axe there too
  await cmd('Page.navigate', { url: U6 + '#/about' }); await sleep(500); await theme('light');
  out('P10.ready', await go(U6, '#/admin_applications'));
  await click('Open Http App');
  out('P10.controls', await ev(`(() => {
    const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
    const w = [...document.querySelectorAll('main .applications form button, main .applications form input, main .applications form select, main .applications form textarea, main .applications .actions button, main .applications .actions input')].filter(vis);
    const off = e => e.disabled || e.getAttribute('aria-disabled') === 'true';
    const said = e => (e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).some(i => { const x = document.getElementById(i); return vis(x) && x.textContent.trim().length > 10; });
    return w.length + ' on:' + w.filter(e => !off(e)).length + ' unsaid:' + w.filter(e => off(e) && !said(e)).length; })()`));
  out('P10.contacts', await click('Show contacts of Http App'));
  out('P10.words', await ev(`document.querySelector('main section[aria-label="Application Http App"]')?.textContent.includes('contacts hidden: the login is off') ?? false`));
  for (const t of ['light', 'dark']) { await theme(t); await go(U6, '#/admin_applications'); await click('Open Http App'); out(`P11.ro_${t}`, await axe()); }
} catch (e) { out('ERROR', String(e?.message ?? e)); }
ws.close(); bws.close();
JS
if [[ $P_SET == 1 ]]; then
  P1WANT=$(q "select string_agg(name, '|' order by name collate \"C\") from pgvigil.app_applications")   # the list as P1 reads it
  P_USR=$USR P_UPW=$UPW P_EMAIL="h5.$SUF@example.com" P_TEAM="$TEAM" P_PPI=$PPI P_PMI=$PMI \
    timeout 600 node "$WORK/p.mjs" "$CDP" "$U/" "http://127.0.0.1:$P6/" "$DL" "$AXE" > "$WORK/p.out" 2> "$WORK/p.err"; echo "read: the page's click run ended rc $? ($(wc -l < "$WORK/p.out") lines)"
  pv() { sed -n "s/^$1=//p" "$WORK/p.out" | head -1; }
  grep -q '^ERROR=' "$WORK/p.out" && echo "read: the click run stopped: $(pv ERROR | cut -c1-300)"
  # P1
  want=$P1WANT; have=$(pv P1.names | tr '|' '\n' | LC_ALL=C sort | paste -sd'|')
  [[ $(pv P1.ready) == true && "|$(pv P1.strip)|" == *"|Applications|"* && -n "$want" && "$have" == "$want" ]] \
    && ok "P1 the Admin strip lists Applications; the page lists the store's applications ($have)" || bad "P1 ready $(pv P1.ready); strip '$(pv P1.strip)'; page '$have' / store '$want'"
  # P2
  # P2, P5 and P7 grade the store as read right after their step (later steps change it: t-ap-g6 graded the end state)
  p2=$(pv P2.store)
  [[ $(pv P2.fill) == ok && $p2 == "2|test|added by the page|entered/$USR" ]] && ok "P2 Add through the form: stored, every field entered by $USR ($(pv P2.status))" || bad "P2 fill $(pv P2.fill); store '$p2'; status '$(pv P2.status)'"
  # P3
  p3=$(q "select description || '|' || version from pgvigil.app_applications where name = 'Page Added'")
  [[ $(pv P3.sources) -ge 4 && $p3 == "edited by the page|2" ]] && ok "P3 one application's fields with their sources ($(pv P3.sources) 'entered by'); Edit stored, version 2" || bad "P3 sources $(pv P3.sources); store '$p3'; status '$(pv P3.status)'"
  # P4
  p4=$(q "select count(*) from pgvigil.ui_app_contacts c join pgvigil.app_applications a using (app_id) where a.name = 'Http App' and c.name = 'Page Team' and c.kind = 'team' and c.role = 'technical owner' and c.email = '$TEAM'")
  [[ $(pv P4.before) == false && $(pv P4.after) == true && $p4 == 1 && $(pv P4.listed) == true ]] && ok "P4 contacts on a click only (the planted e-mail absent before, shown after); a contact added through the form stored and listed" \
    || bad "P4 before $(pv P4.before), after $(pv P4.after); stored $p4, listed $(pv P4.listed); status '$(pv P4.status)'"
  # P5
  p5=$(pv P5.store); n5=$(pv P5.audit)
  a5="|$(pv P5.after)|"; r5="|$(pv P5.rows)|"
  [[ "|$(pv P5.before)|" == *"|Select pdb1 on proof-page-pg|"* && $p5 == "proof-page-ms/Orders/production/$USR,proof-page-pg/pdb1/production/$USR" && $n5 == 2 \
     && $a5 != *"|Select pdb1 on proof-page-pg|"* && $a5 != *"|Select Orders on proof-page-ms|"* && $a5 == *"|Select pdb2 on proof-page-pg|"* && $r5 == *"|pdb1:own:production|"* && $r5 == *"|Orders:own:production|"* ]] \
    && ok "P5 two ticked rows assigned in one call (two audit rows), gone from Unassigned, listed own on the application" || bad "P5 store '$p5' (audit $n5); Unassigned after '$(pv P5.after)'; rows '$(pv P5.rows)'; status '$(pv P5.status)'"
  # P6
  m6=$(q "select count(*) from pgvigil.app_not_application where instance_id = $PMI and database_name = 'Ledger'")
  [[ $(pv P6.gone) == true && $(pv P6.unmarkable) == true && $(pv P6.store) == 1 && $(pv P6.back) == true && $m6 == 0 ]] && ok "P6 Mark: Ledger left Unassigned (stored) and Unmark is offered; Unmark: back on Unassigned, the mark gone" \
    || bad "P6 gone $(pv P6.gone), unmark offered $(pv P6.unmarkable), stored $(pv P6.store), back $(pv P6.back), left $m6; '$(pv P6.status)' / '$(pv P6.unmark)'"
  # P7
  t7=$(pv P7.store)
  [[ $(pv P7.refused) == *"tick to rewrite"* && $(pv P7.done) != "Not done"* && $(pv P7.fill2) == ok && $t7 == "1|0|1" ]] && ok "P7 Rename: refused without the tick (the store's words), done with it; the threshold re-tagged" \
    || bad "P7 refused '$(pv P7.refused)'; done '$(pv P7.done)'; store (new|old|renamed) $t7"
  # P8
  t8=$(q "select (select count(*) from pgvigil.app_applications where app_id = $PREN) || '|' || (select count(*) from pgvigil.app_assignments where app_id = $PREN) || '|' || (select count(*) from pgvigil.pg_thresholds where ended_at is null and tag = 'application:Page Renamed')")
  [[ $(pv P8.refused) == *"assigned to"* && $(pv P8.fill) == ok && $(pv P8.done) != "Not done"* && $t8 == "0|0|0" ]] && ok "P8 Remove asked twice: refused without 'with its assignments', done with the ticks; its assignment and tag-scoped threshold gone" \
    || bad "P8 ask '$(pv P8.ask)'; refused '$(pv P8.refused)'; done '$(pv P8.done)'; store (app|assignments|threshold) $t8"
  # P9
  t9=$(q "select string_agg(database_name, ',' order by database_name) from pgvigil.app_assignments x join pgvigil.app_applications a using (app_id) where a.name = 'Page Added' and x.instance_id = $PPI")
  r9=$(pv P9.row)
  [[ ${r9%%|*} != "-" && -n ${r9%%|*} && ${r9#*|} == pdb1_new* && $t9 == pdb1_new && "|$(pv P9.after)|" == *"|pdb1_new:own|"* ]] && ok "P9 a renamed database: absent since and 'renamed to pdb1_new' shown; the offer moved the assignment" \
    || bad "P9 row (absent|renamed) '$r9'; store '$t9'; after '$(pv P9.after)'; offer '$(pv P9.offer)'"
  # P10
  c10=$(pv P10.controls); n10=${c10%% *}
  [[ $(pv P10.ready) == true && $n10 -ge 8 && $c10 == *" on:0 unsaid:0" && $(pv P10.words) == true ]] && ok "P10 -no-login: $n10 write controls, every one off with a visible reason; contacts: 'contacts hidden: the login is off'" \
    || bad "P10 ready $(pv P10.ready); controls '$c10'; contacts words $(pv P10.words) ('$(pv P10.contacts)')"
  # P11
  [[ $(pv P11.light) == "0 "* && $(pv P11.dark) == "0 "* && $(pv P11.ro_light) == "0 "* && $(pv P11.ro_dark) == "0 "* ]] && ok "P11 axe-core 4.14.0: 0 violation nodes, light and dark, writable (contacts open) and read only" \
    || bad "P11 light '$(pv P11.light)'; dark '$(pv P11.dark)'; read only '$(pv P11.ro_light)' / '$(pv P11.ro_dark)'"
  # P12
  F12=$(pv P12.file)
  if [[ -f "$F12" ]]; then
    x12=$(python3 -I scripts/xlsx-check.py rules "$F12" 2>&1 | tail -1)
    leak=$(unzip -p "$F12" | grep -c -e "h5.$SUF@example.com" -e "555 5$SUF" -e "$TEAM")
    has=$(unzip -p "$F12" | grep -c 'Http App')
    [[ $x12 == *": PASS" && $leak == 0 && $has -ge 1 ]] && ok "P12 the page's Export .xlsx passes xlsx-check and holds no contact value (contacts not shown)" \
      || bad "P12 xlsx-check '$x12'; contact values in the file $leak; 'Http App' parts $has"
  else bad "P12 no workbook downloaded (press $(pv P12.press))"; fi
  [[ -s "$WORK/p.err" ]] && echo "read: the click run's stderr: $(head -c 300 "$WORK/p.err" | tr '\n' ' ')"
else
  for row in $PROWS; do bad "$row not run (P setup)"; done
fi
fi
# ================= O: owner-routed alerts (a contact's route through a configured smtp channel) =================
# real passes of 'pgvigil alerts' against a loopback SMTP sink that keeps each message with its RCPT list and refuses
# one planted address with a 550 naming it; the routes through the store's door (Ann's through the HTTP door)
OROWS="O1 O2 O3 O4 O5 O6 O7 O8 O9 O10 O11 O12 O13 O14 O15 O16 O17 O18 O19"
SINK=$(freeport); mkdir -p "$WORK/smtp"
REFUSED="refused.$SUF@example.com"
cat > "$WORK/sink.py" <<'PY'
import socketserver, sys, os, itertools
out, refuse = sys.argv[2], sys.argv[3].lower(); n = itertools.count(1)
class H(socketserver.StreamRequestHandler):
    def say(self, l): self.wfile.write((l + "\r\n").encode())
    def handle(self):
        self.say("220 sink"); rcpt = []
        while True:
            l = self.rfile.readline()
            if not l: return
            raw = l.decode(errors="replace").strip(); c = raw.upper()
            if c.startswith("EHLO") or c.startswith("HELO"): self.say("250 sink")
            elif c.startswith("MAIL"): rcpt = []; self.say("250 ok")
            elif c.startswith("RCPT"):
                a = raw.split(":", 1)[1].strip().strip("<>").lower()
                if a == refuse: self.say("550 5.1.1 <%s>: recipient address rejected: user unknown" % a)
                else: rcpt.append(a); self.say("250 ok")
            elif c.startswith("RSET") or c.startswith("NOOP"): self.say("250 ok")
            elif c == "DATA":
                self.say("354 go"); buf = []
                while True:
                    d = self.rfile.readline()
                    if not d or d == b".\r\n": break
                    buf.append(d)
                p = os.path.join(out, "%d.eml" % next(n))
                open(p + ".tmp", "wb").write(("X-Rcpt: " + ",".join(rcpt) + "\r\n").encode() + b"".join(buf)); os.rename(p + ".tmp", p)
                self.say("250 queued")
            elif c == "QUIT": self.say("221 bye"); return
            else: self.say("502 no")
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 -I "$WORK/sink.py" "$SINK" "$WORK/smtp" "$REFUSED" 2> "$WORK/sink.log" & SPIDS+=($!)
# mails <stamp> <address> [word]: the messages the sink kept after the stamp with that RCPT (and that word in them)
cat > "$WORK/eml.py" <<'PY'
import glob, os, sys
d, stamp, addr = sys.argv[1], sys.argv[2], sys.argv[3].lower(); word = sys.argv[4] if len(sys.argv) > 4 else ""
t = os.path.getmtime(stamp) if stamp else 0; n = 0
for p in glob.glob(os.path.join(d, "*.eml")):
    if os.path.getmtime(p) <= t: continue
    b = open(p, encoding="utf-8", errors="replace").read()
    if addr not in b.split("\r\n", 1)[0][len("X-Rcpt: "):].split(","): continue
    if word and word.lower() not in b.lower(): continue
    n += 1
print(n)
PY
mails() { python3 -I "$WORK/eml.py" "$WORK/smtp" "$WORK/stamp.$1" "$2" "${3:-}"; }
NPASS=0
opass() {   # one pass of the sender: the stamp before it, its exit code, its output kept
  NPASS=$((NPASS + 1)); sleep 0.02; touch "$WORK/stamp.$NPASS"; sleep 0.02
  "$BIN" alerts -config "$WORK/o.yaml" > "$WORK/opass.$NPASS.out" 2> "$WORK/opass.$NPASS.err"; ORC=$?
  echo "read: pass $NPASS rc $ORC: $(grep -m1 '^alerts: ' "$WORK/opass.$NPASS.out" | cut -c1-300)"
}
crit() {    # a critical finding on an instance: autovacuum off in its state (the settings rule), read back
  q "insert into pgvigil.instance_state (instance_id, snapshot_at, non_default_settings) values ($1, now(), '[{\"name\": \"autovacuum\", \"value\": \"off\"}]'::jsonb)
     on conflict (instance_id) do update set snapshot_at = excluded.snapshot_at, non_default_settings = excluded.non_default_settings" >/dev/null
  q "select count(*) from pgvigil.alert_findings where instance_id = $1 and severity = 'critical'"
}
newinst() { q "select pgvigil.ensure_instance('$1', 'onprem', '18.0', 180000, false, '{}'::text[])"; }
OA=$(newinst proof-o-a); OB=$(newinst proof-o-b); OC=$(newinst proof-o-c); OD1=$(newinst proof-o-d1); OD2=$(newinst proof-o-d2); OL=$(newinst proof-o-l)
dbs "$OC" "[$(pgdb 50001 cdb1)]"
for i in $OA $OB $OC $OD1 $OD2 $OL; do n=$(crit "$i"); [[ $n -ge 1 ]] || bad "O setup: no critical finding on instance $i after the plant ($n)"; done
LNAME=$(python3 -I -c 'print("Long " + "L" * 95)')   # 100 bytes: the tag value's cap
app()  { field "$(wr application "{\"op\": \"add\", \"name\": \"$1\"}")" app_id; }
asg()  { wr assign "{\"op\": \"assign\", \"app_id\": $1, \"targets\": [{\"instance_id\": $2, \"database\": ${3:-null}}]}" >/dev/null; }
con()  { field "$(wr contact "{\"op\": \"add\", \"app_id\": $1, \"role\": \"support\", \"kind\": \"$2\", \"name\": \"$3\", \"email\": \"$4\"}")" contact_id; }
OAPP=$(app 'O App A'); OBPP=$(app 'O App B'); ODPP=$(app 'O App D'); OLPP=$(app "$LNAME")
asg "$OAPP" "$OA"; asg "$OAPP" "$OC"; asg "$OBPP" "$OB"; asg "$OBPP" "$OC" '"cdb1"'; asg "$ODPP" "$OD1"; asg "$ODPP" "$OD2"; asg "$OLPP" "$OL"
ANN="ann.$SUF@example.com"; BOB="bob.$SUF@example.com"; DEE="dee.$SUF@example.com"; LEE="lee.$SUF@example.com"; WES="wes.$SUF@example.com"
TEAMA="a-team.$SUF@example.com"; QUINN="bad\\\"q.$SUF@example.com"; QPLAIN="bad\"q.$SUF@example.com"; DBA="dba.$SUF@example.org"; WBASE="w.$SUF@example.org"
CANN=$(con "$OAPP" person Ann "$ANN"); CDUP=$(con "$OAPP" person 'Ann again' "$ANN"); CTEAM=$(con "$OAPP" team 'A Team' "$TEAMA")
CQ=$(con "$OAPP" person Quinn "$QUINN"); CWES=$(con "$OAPP" person Wes "$WES"); CBOB=$(con "$OBPP" person Bob "$BOB")
CDEE=$(con "$ODPP" person Dee "$DEE"); CLEE=$(con "$OLPP" person Lee "$LEE")
[[ -n "$CANN$CQ" && $(q "select email from pgvigil.ui_app_contacts where contact_id = ${CQ:-0}") == "$QPLAIN" ]] || bad "O setup: the contacts (Quinn's address as stored: $(q "select email from pgvigil.ui_app_contacts where contact_id = ${CQ:-0}"))"
# the repository-wide finding ('purge not run in 2 days', warning): no purge run, an instance seen 3 days ago
q "delete from pgvigil.purge_runs; update pgvigil.instances set first_seen = now() - interval '3 days' where instance_id = $OA" >/dev/null
RW=$(q "select count(*) from pgvigil.alert_findings where source = 'pgvigil repository' and setting = 'purge not run in 2 days'")
H0=$(date -u +%H); H2=$(( (10#$H0 + 2) % 24 ))
LONGB=mailw-$(python3 -I -c 'print("w" * 57)')     # a base name of 63 characters
cat > "$WORK/o.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts:
  - {name: mail, kind: smtp, min_severity: critical, repeat: 5m, clear_after: 0, instances: [proof-o-b],
     smtp: {host: 127.0.0.1, port: $SINK, tls: none, from: pgvigil@example.org, to: [$DBA]}}
  - {name: mailq, kind: smtp, min_severity: critical, tags: [env:nowhere], timezone: UTC,
     quiet_hours: "$(printf %02d $((10#$H0))):00-$(printf %02d $H2):00",
     smtp: {host: 127.0.0.1, port: $SINK, tls: none, from: pgvigil@example.org, to: [q.$SUF@example.org]}}
  - {name: mailcap, kind: smtp, min_severity: critical, max_per_hour: 1, tags: [env:nowhere],
     smtp: {host: 127.0.0.1, port: $SINK, tls: none, from: pgvigil@example.org, to: [cap.$SUF@example.org]}}
  - {name: $LONGB, kind: smtp, min_severity: warning, tags: [env:nowhere],
     smtp: {host: 127.0.0.1, port: $SINK, tls: none, from: pgvigil@example.org, to: [$WBASE]}}
EOF
echo "read: O fixtures - instances a $OA b $OB c $OC d1 $OD1 d2 $OD2 l $OL; applications A $OAPP B $OBPP D $ODPP L $OLPP; a repository-wide 'purge not run' finding: $RW"
HAS_ROUTES=$(q "select to_regprocedure('pgvigil.import_app_contact_route(timestamptz, jsonb)') is not null")
rset() {    # rset <contact> <channel> [min_severity] [enabled]: the route's id ('' when refused or not on this tree)
  [[ $HAS_ROUTES == t ]] || return 0
  local sev=${3:+, \"min_severity\": \"$3\"} en=${4:+, \"enabled\": $4}
  field "$(wr contact_route "{\"op\": \"set\", \"contact_id\": $1, \"channel\": \"$2\"$sev$en}")" route_id
}
RANN=""
if [[ $HAS_ROUTES == t ]]; then
  # Ann's route through the HTTP door (the page's API), the others through the store's
  c=$(post "$U" admin/applications/routes "{\"op\": \"set\", \"contact_id\": $CANN, \"channel\": \"mail\"}"); RANN=$(js 'print(d.get("route_id", ""))' 2>/dev/null)
  [[ $c == 200 && -n $RANN ]] || echo "read: Ann's route through the HTTP door: $c $(head -c 200 "$WORK/ans.json")"
else echo "read: no routes on this tree (no import_app_contact_route): every route below is unset"; fi
RDUP=$(rset "$CDUP" mail); RTEAM=$(rset "$CTEAM" mail); RQ=$(rset "$CQ" mail); RWES=$(rset "$CWES" "$LONGB"); RBOB=$(rset "$CBOB" mail)
RGONE=$(rset "$CBOB" mailgone); RDQ=$(rset "$CDEE" mailq); RDC=$(rset "$CDEE" mailcap); RLEE=$(rset "$CLEE" mail)
ch() { echo "contact-$1"; }
open_rows() { q "select count(*) from pgvigil.alert_state where channel = '$(ch "$1")' and cleared_at is null"; }

opass                                                                     # pass 1
P1=$NPASS
o1a=$(mails $P1 "$ANN" proof-o-a); o1b=$(mails $P1 "$ANN" proof-o-b); o1bob=$(mails $P1 "$BOB" proof-o-a); o1dba=$(mails $P1 "$DBA" proof-o-b); o1dbaa=$(mails $P1 "$DBA" proof-o-a)
[[ -n $RANN && $o1a -ge 1 && $o1b == 0 && $o1bob == 0 && $o1dba -ge 1 && $o1dbaa == 0 ]] \
  && ok "O1 a finding on A's instance mailed to A's routed contact, none of B's to her, none of A's to B's contact; the base 'mail' kept its own scope (B's instance)" \
  || bad "O1 route '$RANN'; to Ann: A's $o1a, B's $o1b; to Bob A's $o1bob; base to dba: B's $o1dba, A's $o1dbaa"
o8a=$(mails $P1 "$ANN" proof-o-c); o8b=$(mails $P1 "$BOB" proof-o-c)
[[ -n $RANN && -n $RBOB && $o8a -ge 1 && $o8b -ge 1 ]] && ok "O8 proof-o-c carries A (the instance) and B (its database cdb1): its finding mailed to Ann and to Bob" || bad "O8 to Ann $o8a, to Bob $o8b (routes '$RANN' '$RBOB')"
o9=$(mails $P1 "$ANN")
[[ -n $RDUP && $o9 == 2 ]] && ok "O9 one address on two contact rows: two copies in one pass (duplicates accepted, O-D7)" || bad "O9 messages to Ann's address in pass 1: $o9 (want 2; route '$RDUP')"
o10=$(mails $P1 "$TEAMA" proof-o-a)
[[ -n $RTEAM && $o10 -ge 1 ]] && ok "O10 a team's group address routed: mailed A's finding" || bad "O10 to the team's address $o10 (route '$RTEAM')"
o11=$(mails $P1 "$WES" proof-o-a); o11w=$(mails $P1 "$WES" 'purge not run'); o11base=$(mails $P1 "$WBASE" 'purge not run')
[[ -n $RWES && $o11 -ge 1 && $RW -ge 1 && $o11base -ge 1 && $o11w == 0 ]] \
  && ok "O11 a route through a 63-character base: mailed A's finding; the repository-wide 'purge not run' went to the base only, to no route" \
  || bad "O11 Wes: A's $o11, repository-wide $o11w; the base's repository-wide $o11base (finding standing: $RW; route '$RWES')"
o12=$(mails $P1 "$LEE" proof-o-l)
[[ -n $RLEE && $o12 -ge 1 ]] && ok "O12 an application named at the tag's 100-byte cap: its contact mailed" || bad "O12 to Lee $o12 (route '$RLEE')"
o3q=$(mails $P1 "$DEE"); o3qs=$( [[ -n $RDQ ]] && open_rows "$RDQ" || echo x)
o3c=$(q "select coalesce(sum(cardinality(keys)), 0) from pgvigil.alert_log where channel = '$(ch "${RDC:-0}")' and outcome = 'capped'")
o3s=$(q "select count(*) from pgvigil.alert_log where channel = '$(ch "${RDC:-0}")' and outcome = 'sent'")
[[ -n $RDQ && -n $RDC && $o3qs == 0 && $o3q == 1 && $o3c -ge 1 && $o3s == 1 ]] \
  && ok "O3 the base's quiet hours hold its route (no row, no message on mailq's route); the base's max_per_hour 1 caps its route as its own channel (1 message, $o3c held)" \
  || bad "O3 quiet route rows '$o3qs'; Dee's messages $o3q (want 1: mailcap's one); capped items $o3c, sent rows $o3s (routes '$RDQ' '$RDC')"
o13a=$(mails $P1 "$QPLAIN"); o13n=$(q "select count(*) from pgvigil.alert_log where channel = '$(ch "${RQ:-0}")' and error like '%contact $CQ%'")
o13s=$(mails $P1 "$ANN" proof-o-a)
[[ -n $RQ && $o13a == 0 && $o13n == 1 && $o13s -ge 1 ]] && ok "O13 an address Go's parser refuses: that route alone skipped, named in the log by its contact id; the others sent" \
  || bad "O13 to Quinn $o13a; log rows $o13n; Ann still mailed $o13s (route '$RQ')"

opass                                                                     # pass 2, right after
P2=$NPASS
o2now=$(mails $P2 "$ANN")
q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '6 minutes' where channel = '$(ch "${RANN:-0}")'" >/dev/null
opass                                                                     # pass 3, Ann's state 6 minutes older
P3=$NPASS
o2rep=$(mails $P3 "$ANN" '[REPEAT CRITICAL] proof-o-a')
o2cfg=$(q "select repeat_secs || '|' || clear_after_secs || '|' || max_per_hour || '|' || is_configured from pgvigil.alert_channels where name = '$(ch "${RANN:-0}")'")
[[ -n $RANN && $o2now == 0 && $o2rep -ge 1 && $o2cfg == "300|0|0|t" ]] \
  && ok "O2 the route repeats as its base: nothing again at once, a repeat after 6 minutes (repeat 5m); its channel row 300 s / 0 / no cap, configured" \
  || bad "O2 at once $o2now; after 6 minutes $o2rep; channel row '$o2cfg' (route '$RANN')"
o6=$(q "select count(*) from pgvigil.alert_log where channel = '$(ch "${RGONE:-0}")' and error like '%mailgone%not configured%'")
o6m=$(q "select count(*) from pgvigil.alert_log where channel = '$(ch "${RGONE:-0}")' and outcome = 'sent'"); o13o=$(q "select count(*) from pgvigil.alert_log where channel = '$(ch "${RQ:-0}")'")
[[ -n $RGONE && $o6 == 1 && $o6m == 0 && $o13o == 1 ]] && ok "O6 a route whose channel is not in the config sends nothing and is named once in three passes (so is the unparsable address)" \
  || bad "O6 'not configured' rows $o6, sent $o6m; Quinn's rows $o13o (routes '$RGONE' '$RQ')"

# O7: Ann's e-mail changed, then her contact removed
wr contact "{\"op\": \"edit\", \"app_id\": $OAPP, \"contact_id\": $CANN, \"email\": \"ann2.$SUF@example.com\"}" >/dev/null
q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '6 minutes' where channel = '$(ch "${RANN:-0}")'" >/dev/null
opass; P4=$NPASS
o7new=$(mails $P4 "ann2.$SUF@example.com" proof-o-a)
# off then on: the team's route turned off (its open rows closed, no message), on again (no stale recovery)
offrows=$( [[ -n $RTEAM ]] && open_rows "$RTEAM" || echo 0)
rset "$CTEAM" mail '' false >/dev/null
opass; P5=$NPASS
o14off=$(mails $P5 "$TEAMA"); o14rows=$( [[ -n $RTEAM ]] && open_rows "$RTEAM" || echo x); o14log=$(q "select count(*) from pgvigil.alert_log where channel = '$(ch "${RTEAM:-0}")' and outcome = 'cleared'")
rset "$CTEAM" mail '' true >/dev/null
opass; P6=$NPASS
o14res=$(mails $P6 "$TEAMA" '[RESOLVED]')
[[ -n $RTEAM && $offrows -ge 1 && $o14off == 0 && $o14rows == 0 && $o14log -ge 1 && $o14res == 0 ]] \
  && ok "O14 a route turned off: its $offrows open row(s) closed 'cleared' with no message; on again: no stale recovery" \
  || bad "O14 open before $offrows; off: messages $o14off, open rows $o14rows, cleared rows $o14log; on: 'resolved' messages $o14res"
wr contact "{\"op\": \"remove\", \"app_id\": $OAPP, \"contact_id\": $CANN}" >/dev/null
annrows=$( [[ -n $RANN ]] && open_rows "$RANN" || echo 0)
opass; P7=$NPASS
o7gone=$(mails $P7 "ann2.$SUF@example.com"); o7rows=$( [[ -n $RANN ]] && open_rows "$RANN" || echo x)
[[ -n $RANN && $o7new -ge 1 && $(mails $P4 "$ANN" proof-o-a) == 0 && $annrows -ge 1 && $o7gone == 0 && $o7rows == 0 ]] \
  && ok "O7 a changed e-mail is mailed at the next pass (the old address not); the contact removed: its route's $annrows open row(s) closed with no message" \
  || bad "O7 new address $o7new (old $(mails $P4 "$ANN" proof-o-a)); open before removal $annrows; after: messages $o7gone, open rows $o7rows"

# O15: a failed door: the config's channels still send, no route row is closed
DEF=$(q "select pg_get_functiondef('pgvigil.alert_contact_routes()'::regprocedure)" 2>/dev/null)
bobrows=$( [[ -n $RBOB ]] && open_rows "$RBOB" || echo 0)
# the door made to fail (its body raises first), restored from its own definition after the pass
[[ -n "$DEF" ]] && q "do \$d\$ begin execute replace(pg_get_functiondef('pgvigil.alert_contact_routes()'::regprocedure), 'BEGIN', 'BEGIN RAISE EXCEPTION ''proof: the door fails'';'); end \$d\$" >/dev/null
o15door=$(q "select count(*) from pgvigil.alert_contact_routes()" 2>&1 | tail -1)
T8=$(q "select now()")
q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '6 minutes' where channel = 'mail'" >/dev/null
opass; P8=$NPASS
o15dba=$(mails $P8 "$DBA" '[REPEAT CRITICAL] proof-o-b'); o15rows=$( [[ -n $RBOB ]] && open_rows "$RBOB" || echo x)
o15clr=$(q "select count(*) from pgvigil.alert_log where channel like 'contact-%' and outcome = 'cleared' and snapshot_at >= '$T8'")
[[ -n "$DEF" ]] && { printf '%s;\n' "$DEF" | psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 >/dev/null || bad "O15 setup: the door's definition was not restored"; }
[[ -n $RBOB && -n "$DEF" && $o15door == *"the door fails"* && $o15dba -ge 1 && $bobrows -ge 1 && $o15rows == "$bobrows" && $o15clr == 0 ]] \
  && ok "O15 the routes' door failing: the base still sent its repeat; Bob's $bobrows open row(s) left open, no route row closed" \
  || bad "O15 door saved '${DEF:0:40}', made to fail: '${o15door:0:80}'; base repeat $o15dba; Bob's open rows $bobrows -> $o15rows; route rows cleared $o15clr"

# O4: a contact the relay refuses (550 naming the address): the error says 'contact <id>'; no planted address anywhere
CREX=$(con "$OBPP" person Rex "$REFUSED"); RREX=$(rset "$CREX" mail)
opass; P9=$NPASS
o4err=$(q "select coalesce(string_agg(error, ' | '), '') from pgvigil.alert_log where channel = '$(ch "${RREX:-0}")' and outcome in ('failed', 'refused')")
get "$U" alerts > /dev/null; cp "$WORK/ans.json" "$WORK/o-alerts.json"; get "$U" alertrules > /dev/null; cp "$WORK/ans.json" "$WORK/o-rules.json"
get "$U" reportmail > /dev/null; cp "$WORK/ans.json" "$WORK/o-reportmail.json"
leaks=0; where4=""
for a in "$ANN" "ann2.$SUF@example.com" "$BOB" "$DEE" "$LEE" "$WES" "$TEAMA" "$QPLAIN" "$REFUSED"; do
  for t in alert_log alert_channels admin_audit alert_tests alert_state; do
    n=$(q "select count(*) from pgvigil.$t x where strpos(lower(row_to_json(x)::text), lower('${a//\'/\'\'}')) > 0"); [[ $n == 0 ]] || { leaks=$((leaks + n)); where4+=" $t:$a"; }
  done
  n=$(cat "$WORK"/opass.*.out "$WORK"/opass.*.err "$WORK/o-alerts.json" "$WORK/o-rules.json" "$WORK/o-reportmail.json" | grep -c -i -F "$a"); [[ $n == 0 ]] || { leaks=$((leaks + n)); where4+=" outputs:$a"; }
done
[[ -n $RREX && $o4err == *"contact $CREX"* && $o4err != *"$REFUSED"* && $leaks == 0 ]] \
  && ok "O4 the relay's 550 is logged as 'contact $CREX'; no planted address in alert_log, alert_channels, admin_audit, alert_tests, alert_state, the passes' output and log, the Alerts, rules or Report mail answers" \
  || bad "O4 the refused route's error '${o4err:0:200}'; $leaks hit(s):$where4"

# O5: a reader may not read the routes: the door refuses it, the table is not its
RD2=pgvigil_app_rd2_$SUF; RPW="rpw-$SUF-$RANDOM"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create role $RD2 login password '$RPW' in role pgvigil_reader" >/dev/null 2>&1
asrd() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB user=$RD2 password=$RPW" -XAt -c "$1" 2>&1; }
o5a=$(asrd "select count(*) from pgvigil.alert_contact_routes()"); o5b=$(asrd "select count(*) from pgvigil.ui_app_contact_routes")
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $RD2" >/dev/null 2>&1
[[ $o5a == *"not the alert sender"* && $o5b == *"permission denied"* ]] && ok "O5 a reader login: the routes' door refuses it, ui_app_contact_routes is not readable (the custom-report path: pdfp-relw4-s1's fix, not this tree's)" \
  || bad "O5 door: '${o5a:0:120}'; table: '${o5b:0:120}'"

# O16: the Send test is refused on a route; O17: Report mail and the rules page count the configured channels only
o16=$(q "select pgvigil.import_alert_test(now(), '{\"ui_user\": \"proof\", \"channel\": \"$(ch "${RBOB:-0}")\"}'::jsonb)")
[[ -n $RBOB && $o16 == *refused* && $o16 == *route* ]] && ok "O16 a Send test on a route's channel is refused ('${o16:0:120}')" || bad "O16 '$o16'"
o17r=$(grep -c '"contact-' "$WORK/o-reportmail.json"); o17n=$(python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
def find(x):
    if isinstance(x, dict):
        if "columns" in x and "channels" in x["columns"]: return x["rows"][0][x["columns"].index("channels")]
        for v in x.values():
            r = find(v)
            if r is not None: return r
    return None
print(find(d))' "$WORK/o-rules.json" 2>&1)
[[ -n $RBOB && $o17r == 0 && $o17n == 4 ]] && ok "O17 Report mail lists no route's channel; the rules page counts the 4 configured channels" || bad "O17 contact- channels in Report mail's answer $o17r; the rules page's channel count '$o17n' (want 4)"

# O18: the page's API: one application's contacts carry their routes and the configured smtp channels a route may use
c18=$(get "$U" "applications/$OBPP/contacts")
o18=$(js 'r = d.get("routes") or {"columns": [], "rows": []}; c = d.get("channels") or {"columns": [], "rows": []}
ri = r["columns"].index("channel_name") if "channel_name" in r["columns"] else 0; ci = c["columns"].index("name") if "name" in c["columns"] else 0
print(",".join(sorted(x[ri] for x in r["rows"])) + "|" + ",".join(sorted(x[ci] for x in c["rows"])))' 2>&1)
[[ $c18 == 200 && $o18 == "mail,mail,mailgone|mail,mailcap,mailq,$LONGB" ]] && ok "O18 B's contacts carry their routes (mail, mail, mailgone) and the four configured smtp channels, no route's" \
  || bad "O18 $c18 '$o18'"

# O19: the page's route controls, clicked (the click run of section P in its 'routes' mode, on the same browser)
if [[ ${P_SET:-0} == 1 && $HAS_ROUTES == t ]]; then
  P_USR=$USR P_UPW=$UPW timeout 300 node "$WORK/p.mjs" "$CDP" "$U/" "http://127.0.0.1:$P6/" "$DL" "$AXE" routes > "$WORK/o19.out" 2> "$WORK/o19.err"
  ov() { sed -n "s/^$1=//p" "$WORK/o19.out" | head -1; }
  o19=$(q "select string_agg(r.channel_name || '/' || coalesce(r.min_severity, 'base') || '/' || r.enabled::text, ',') from pgvigil.ui_app_contact_routes r where r.contact_id = $CDEE and r.channel_name = 'mail'")
  o19a=$(q "select count(*) from pgvigil.admin_audit where op = 'app_route' and outcome = 'done' and ui_user = '$USR' and target = 'contact $CDEE'")
  [[ $(ov R.fill) == ok && $(ov R.added) == true && $o19 == "mail/warning/false" && $o19a == 2 && $(ov R.axe) == "0 "* ]] \
    && ok "O19 the page: a route added for Dee (mail from warning) and turned off by clicks; two audit rows; axe 0 nodes with the routes shown" \
    || bad "O19 fill $(ov R.fill), listed $(ov R.added); store '$o19'; audit $o19a; axe '$(ov R.axe)'; status '$(ov R.status)' / '$(ov R.off)'; $(head -c 200 "$WORK/o19.err")"
else bad "O19 not run (the page's click run or the routes are not on this tree)"; fi
fi

echo "proof-applications: $NFAIL FAIL"
[[ $NFAIL == 0 ]]
