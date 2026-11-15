#!/usr/bin/env bash
# proof-uiroles.sh - proof of the per-user web UI roles (task B24f: viewer / operator / admin; the role migration *_ui_roles.sql,
# internal/web/roles.go's s.post and its needs table, the CLI's -role and 'user role') on a throwaway repository.
# Every POST route of web.go is called by a viewer, an operator and an admin with a small body; a call below the
# route's need is refused 403 with the role's words, a call at or above it gets the route's own answer.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a superuser (the proof makes its database with a random
#                      suffix and drops it at the end)
#   PGVIGIL_BIN        the build to prove; default bin/pgvigil
#
# The needs (docs/roles.md's table is the same list; internal/web/roles_test.go compares it with web.go):
#   anyone   login, logout
#   viewer   mssql/actions/preview, community/glenn/parse, community/params, customreports/run,
#            reportmail/rendered
#   operator actions/cancel, actions/terminate, mssql/actions/run (KILL, job start / stop, plan evict), jobs/actions/
#            stop and start, ack, ack/end, alerts/dismiss, alerts/mute, alerts/test, plans/explain, plans/analyze,
#            plans/hypo, indexes/advise (the lead 13:3x), community/run, reportmail/send, reportmail/test
#   admin    admin/instances, admin/sources, admin/proposals, admin/dbadash_moves, admin/applications (and contacts,
#            assign, routes, import), alertrules, alertrules/end, drives/thresholds, pg/thresholds, jobs/thresholds,
#            jobs/exclusions, customreports, reportmail
#
# Expected (written before its first run; the RED run on rel-j15-fix 48fe228c, no role anywhere yet):
#   M (the migration and the CLI, R2): M1 the column (ui_users.role text NOT NULL, default 'viewer', a CHECK of the three
#     names) FAIL - no column; M2 a user that existed before the role migration reads admin after it FAIL - no
#     *_ui_roles.sql; M3 the first 'user add' without -role makes an admin and says 'first enabled admin', the second a
#     viewer FAIL; M4 'user add -role operator' and 'user role <name> viewer' FAIL (no flag, no command); M5 a bad role
#     refused by the CLI with the three names and by the CHECK FAIL; M6 ui_password_hash answers admins only (an older
#     serve on this store) FAIL - no operator can be made; M7 ui_login_of: one row (hash, role) for an enabled user, NULLs
#     for an unknown or a disabled one FAIL - no function.
#   U (the users): each 'user add -role' FAILs, and the user is added without a role so R1 still runs.
#   R1 (each route x viewer / operator / admin): every row below its need FAIL - the route answers as it does today
#     (its own words, never 'needs the <role> role'); every row at or above its need ok. Counted: 41 routes, the two
#     'anyone' ones by the login and logout rows.
#   SRC (SourcesAdminWrite, the lead 00:1x): an operator's and a viewer's add / edit / enable / disable / remove / sync
#     / sweep FAIL (not refused); the source rows unchanged ok.
#   S5 (a fleet-wide or open-ended mute or blackout needs admin): the operator's four wide rows FAIL (a mute on every
#     instance, over a tag, with no end; a blackout with no end); the operator's one-instance blackout with an end ok;
#     the admin's fleet-wide mute ok. (A blackout over a tag is refused for everyone already: 'a blackout names one
#     instance', no row.) S5e, the edit of a mute rule (POST /api/alerts/mute op edit writes its successor): the
#     operator's edit of a fleet-wide rule, and of a one-instance rule to every instance, over a tag or with no end
#     FAIL (not refused: the edit is role-checked no further than operator); the operator's edit of a one-instance
#     rule that keeps its instance and an end ok; the admin's edit to every instance ok.
#   The fold of review-18 (b24f1 N5 / S4; written before the run that carries it): S5 the operator's one-alert mute
#     (finding_key, no instance) with an end: its own answer, not the role's words; the 7-day ceiling (the lead 13:3x):
#     the operator's mute of one instance ending in 30 days and blackout ending 9999-12-31 refused with the admin
#     words, its edit to an end 30 days away refused; R1's indexes/advise row at operator; A4 GET /api/applications/
#     unassigned as a viewer and an operator: can_edit false, why_not 'changing an application needs the admin role:
#     <user> is a viewer / an operator ...'; as the admin: can_edit true.
#   S9: the header row ok (403 'X-Pgvigil'; admin_audit and acks unchanged); the demoted user FAIL (no 'user role'); the
#     disabled user ok (401, as today); the lookup error FAIL (no ui_login_of to move aside); -no-login's words ok
#     (unchanged); logout ok.
#   The last line: 'proof-uiroles: <n> FAIL' and rc 1.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=$(realpath "${PGVIGIL_BIN:-bin/pgvigil}")
SUF=$RANDOM; DB=pgvigil_rolesproof_$SUF
WORK=$(mktemp -d); SRV=""; SRV2=""
FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL: $*"; exit 1; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in psql curl ss python3; do command -v $t >/dev/null || die "$t is not on this machine"; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 12000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  die "no free port"
}
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || die "create database $DB"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
CFG=$WORK/none.yaml
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.log" 2>&1 || die "migrate: $(tail -3 "$WORK/migrate.log")"
MIG=$(ls internal/repo/sql/*_ui_roles.sql 2>/dev/null | head -1)
echo "== the role migration: ${MIG:-none}"
PW() { echo "pw-$1-$SUF-long-enough"; }
useradd() {   # useradd <name> [role]: prints the CLI's own output
  if [[ -n "${2:-}" ]]; then PGVIGIL_PASSWORD=$(PW "$1") "$BIN" user add -config "$CFG" -role "$2" "$1" 2>&1
  else PGVIGIL_PASSWORD=$(PW "$1") "$BIN" user add -config "$CFG" "$1" 2>&1; fi
}
roleof() { q "select role from pgvigil.ui_users where username = '$1'"; }

# ---- M: the migration and the CLI (R2) -------------------------------------------------------------------------------
got=$(q "select data_type || '|' || is_nullable || '|' || coalesce(column_default, '') from information_schema.columns where table_schema = 'pgvigil' and table_name = 'ui_users' and column_name = 'role'")
chk=$(q "select string_agg(pg_get_constraintdef(oid), ' ') from pg_constraint where conrelid = 'pgvigil.ui_users'::regclass and contype = 'c'")
if [[ $got == "text|NO|'viewer'::text" && $chk == *viewer* && $chk == *operator* && $chk == *admin* ]]; then ok "M1: ui_users.role text NOT NULL default 'viewer', the CHECK names viewer / operator / admin"
else bad "M1: ui_users.role: '$got'; its CHECK: '$chk'"; fi
# M3 first: the store has no user yet
out=$(useradd first$SUF)
if [[ $(roleof first$SUF) == admin && $out == *"first enabled admin"* ]]; then ok "M3: the first user without -role is admin ('$out')"
else bad "M3: the first user without -role: role '$(roleof first$SUF)', said '$out'"; fi
out=$(useradd second$SUF)
[[ $(roleof second$SUF) == viewer ]] && ok "M3: the second user without -role is a viewer" || bad "M3: the second user without -role: role '$(roleof second$SUF)' ($out)"
# M2: a user that existed before the role migration (the migration applied again over a row inserted without a role)
if [[ -z $MIG ]]; then bad "M2: no internal/repo/sql/*_ui_roles.sql"
else
  V=$(basename "$MIG")
  out=$(q "begin; delete from pgvigil.schema_version where version = '$V'; alter table pgvigil.ui_users drop column role;
    insert into pgvigil.ui_users (username, password_hash) values ('old$SUF', (select password_hash from pgvigil.ui_users where username = 'first$SUF')); commit;")
  out2=$("$BIN" migrate -config "$CFG" 2>&1)
  [[ $(roleof old$SUF) == admin && $(roleof first$SUF) == admin ]] && ok "M2: users from before $V read admin after it" \
    || bad "M2: after $V again: old '$(roleof old$SUF)', first '$(roleof first$SUF)' ($out | $(tail -2 <<< "$out2"))"
fi
out=$(useradd op$SUF operator)
[[ $(roleof op$SUF) == operator ]] && ok "M4: user add -role operator" || bad "M4: user add -role operator: '$(roleof op$SUF)' ($out)"
out=$("$BIN" user role -config "$CFG" op$SUF viewer 2>&1)
[[ $(roleof op$SUF) == viewer ]] && ok "M4: user role op$SUF viewer ('$out')" || bad "M4: user role: '$(roleof op$SUF)' ($out)"
"$BIN" user role -config "$CFG" op$SUF operator >/dev/null 2>&1
out=$("$BIN" user list -config "$CFG" 2>&1)
grep -E "^op$SUF .*operator" <<< "$out" >/dev/null && ok "M4: user list shows the role" || bad "M4: user list: $(grep "op$SUF" <<< "$out")"
out=$(useradd boss$SUF boss)
if [[ -z $(roleof boss$SUF) && $out == *viewer* && $out == *operator* && $out == *admin* && $out != *ui_users_role_check* ]]; then ok "M5: -role boss refused by the CLI ('$out')"
else bad "M5: -role boss: role '$(roleof boss$SUF)', said '$out'"; fi
out=$(q "update pgvigil.ui_users set role = 'boss' where username = 'second$SUF'")
[[ $out == *"check constraint"* ]] && ok "M5: the CHECK refuses role 'boss'" || bad "M5: an UPDATE to 'boss': $out"
hv=$(q "select coalesce(pgvigil.ui_password_hash('op$SUF'), 'NULL')"); ha=$(q "select coalesce(pgvigil.ui_password_hash('first$SUF'), 'NULL')")
# the operator must exist with its role: a NULL for a user that is not there proves nothing (roles-red1 graded M6 ok
# on a base where no operator could be made)
[[ $(roleof op$SUF) == operator && $hv == NULL && $ha == \$argon2id\$* ]] && ok "M6: ui_password_hash answers an admin only (an older serve admits admins)" || bad "M6: ui_password_hash: operator ('$(roleof op$SUF)') '${hv:0:20}', admin '${ha:0:20}'"
a=$(q "select (password_hash like '\$argon2id\$%')::text || '|' || coalesce(role, 'NULL') from pgvigil.ui_login_of('OP$SUF')")
u=$(q "select count(*) || '|' || count(password_hash) || '|' || count(role) from pgvigil.ui_login_of('nobody$SUF')")
if [[ $a == "true|operator" && $u == "1|0|0" ]]; then ok "M7: ui_login_of: (hash, role) for an enabled user (any case), one row of NULLs for an unknown"
else bad "M7: ui_login_of: enabled '$a', unknown '$u'"; fi

# ---- U: the users of R1 ---------------------------------------------------------------------------------------------
declare -A ROLE=([v$SUF]=viewer [o$SUF]=operator [a$SUF]=admin [dem$SUF]=admin [dis$SUF]=operator)
for u in v$SUF o$SUF a$SUF dem$SUF dis$SUF; do
  out=$(useradd "$u" "${ROLE[$u]}")
  if [[ $(roleof "$u") != "${ROLE[$u]}" ]]; then
    bad "U: user add -role ${ROLE[$u]} $u: '$(roleof "$u")' ($out)"
    [[ -z $(q "select 1 from pgvigil.ui_users where username = '$u'") ]] && useradd "$u" >/dev/null
  fi
done

# ---- serve with the login -------------------------------------------------------------------------------------------
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U/" && break; kill -0 $SRV 2>/dev/null || die "serve died: $(tail -3 "$WORK/serve.log")"; sleep 0.5; done
login() {   # login <user>: its own cookie jar; prints the code
  curl -s -o "$WORK/login.body" -w '%{http_code}' -c "$WORK/$1.jar" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' \
    --data "{\"username\":\"$1\",\"password\":\"$(PW "$1")\"}" "$U/api/login"
}
post() {   # post <user> <path> <body>: prints '<code> <body>'
  local c; c=$(curl -s -o "$WORK/post.body" -w '%{http_code}' -b "$WORK/$1.jar" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$3" "$U$2")
  echo "$c $(tr -d '\n' < "$WORK/post.body" | cut -c1-220)"
}
for u in v$SUF o$SUF a$SUF dem$SUF dis$SUF; do
  c=$(login "$u"); [[ $c == 200 ]] || bad "login $u: $c $(cat "$WORK/login.body")"
done
ok "login: every user signs in with no session first (anyone)"
art() { [[ $1 == viewer ]] && echo a || echo an; }
rank() { case $1 in viewer) echo 1 ;; operator) echo 2 ;; admin) echo 3 ;; *) echo 0 ;; esac; }
ROLEWORDS='needs the (viewer|operator|admin) role'
# grade <user> <need> <path> <body> [what]
grade() {
  local u=$1 need=$2 p=$3 body=$4 what=${5:-$3} role=${ROLE[$1]} res code
  res=$(post "$u" "$p" "$body"); code=${res%% *}
  if (( $(rank "$role") < $(rank "$need") )); then
    if [[ $code == 403 && $res =~ needs\ the\ $need\ role && $res == *"$u is $(art "$role") $role"* ]]; then ok "R1 $role $what: refused ($res)"
    else bad "R1 $role $what (needs $need): not refused with the role's words: $res"; fi
  else
    if [[ $code != 401 && ! $res =~ $ROLEWORDS ]]; then ok "R1 $role $what: its own answer ($code)"
    else bad "R1 $role $what (needs $need): $res"; fi
  fi
}
ROUTES=(
  "operator /api/indexes/advise" "viewer /api/mssql/actions/preview" "viewer /api/community/glenn/parse" "viewer /api/community/params"
  "viewer /api/customreports/run" "viewer /api/reportmail/rendered"
  "operator /api/actions/cancel" "operator /api/actions/terminate" "operator /api/mssql/actions/run" "operator /api/jobs/actions/stop"
  "operator /api/jobs/actions/start" "operator /api/ack" "operator /api/ack/end" "operator /api/alerts/dismiss" "operator /api/alerts/mute"
  "operator /api/alerts/test" "operator /api/plans/explain" "operator /api/plans/analyze" "operator /api/plans/hypo" "operator /api/community/run"
  "operator /api/reportmail/send" "operator /api/reportmail/test"
  "admin /api/admin/instances" "admin /api/admin/sources" "admin /api/admin/proposals" "admin /api/admin/dbadash_moves"
  "admin /api/admin/applications" "admin /api/admin/applications/contacts" "admin /api/admin/applications/assign"
  "admin /api/admin/applications/routes" "admin /api/admin/applications/import" "admin /api/alertrules" "admin /api/alertrules/end"
  "admin /api/drives/thresholds" "admin /api/pg/thresholds" "admin /api/jobs/thresholds" "admin /api/jobs/exclusions"
  "admin /api/customreports" "admin /api/reportmail"
)
echo "== R1: ${#ROUTES[@]} routes (and login, logout) x viewer / operator / admin"
for r in "${ROUTES[@]}"; do
  for u in v$SUF o$SUF a$SUF; do grade "$u" ${r%% *} "${r#* }" '{}'; done
done

# ---- SRC: SourcesAdminWrite's ops (the lead 00:1x) ------------------------------------------------------------------
before=$(q "select count(*) from pgvigil.admin_sources" 2>&1)
for op in add edit enable disable remove sync sweep; do
  for u in o$SUF v$SUF; do grade "$u" admin /api/admin/sources "{\"op\":\"$op\",\"name\":\"src$SUF\",\"kind\":\"aws\"}" "admin/sources op $op"; done
done
[[ $(q "select count(*) from pgvigil.admin_sources" 2>&1) == "$before" ]] && ok "SRC: the source rows unchanged ($before)" || bad "SRC: the source rows: $before before, $(q "select count(*) from pgvigil.admin_sources") after"

# ---- S5: a fleet-wide or open-ended mute or blackout needs admin ----------------------------------------------------
# an end inside the 7-day ceiling (the lead 13:3x: an end more than 7 days away is open-ended), and one past it
END="\"until\":\"$(date -u -d '+2 days' +%Y-%m-%dT%H:%M:%SZ)\""
FAR="\"until\":\"$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)\""
s5() {   # s5 <user> <want: admin|own> <body> <what>
  local res code; res=$(post "$1" /api/ack "$3"); code=${res%% *}
  if [[ $2 == admin ]]; then
    [[ $code == 403 && $res == *"a fleet-wide or open-ended mute needs the admin role"* ]] && ok "S5 ${ROLE[$1]} $4: refused ($res)" || bad "S5 ${ROLE[$1]} $4: $res"
  else
    [[ $code != 401 && ! $res =~ $ROLEWORDS ]] && ok "S5 ${ROLE[$1]} $4: its own answer ($res)" || bad "S5 ${ROLE[$1]} $4: $res"
  fi
}
s5 o$SUF admin "{\"kind\":\"mute\",\"check_key\":\"x\",$END}" "a mute on every instance"
s5 o$SUF admin '{"kind":"blackout","instance_id":999999}' "a blackout with no end"
s5 o$SUF admin "{\"kind\":\"mute\",\"tag\":\"prod\",\"check_key\":\"x\",$END}" "a mute over a tag"
s5 o$SUF admin '{"kind":"mute","instance_id":999999,"check_key":"x"}' "a mute with no end"
s5 o$SUF admin "{\"kind\":\"mute\",\"instance_id\":999999,\"check_key\":\"x\",$FAR}" "a mute of one instance with an end 30 days away"
s5 o$SUF admin "{\"kind\":\"blackout\",\"instance_id\":999999,\"until\":\"9999-12-31T00:00:00Z\"}" "a blackout of one instance ending 9999-12-31"
# a blackout over a tag is refused for every user before B24f ('a blackout names one instance', 409: roles-red1): no row
s5 o$SUF own "{\"kind\":\"blackout\",\"instance_id\":999999,$END}" "a blackout of one instance with an end"
s5 a$SUF own "{\"kind\":\"mute\",\"check_key\":\"x\",$END}" "a mute on every instance"
# a one-alert mute (finding_key) is one scope whatever instance it names (review-18 b24f1 N5)
s5 o$SUF own "{\"kind\":\"mute\",\"finding_key\":\"proof-one-$SUF\",$END}" "a one-alert mute with an end"

# ---- A4: every application answer says the role (review-18 b24f1 S4) -------------------------------------------------
for u in v$SUF o$SUF a$SUF; do
  c=$(curl -s -o "$WORK/app.body" -w '%{http_code}' -b "$WORK/$u.jar" "$U/api/applications/unassigned")
  got=$(python3 -c "import json,sys; d=json.load(open('$WORK/app.body')); print(str(d.get('can_edit')) + '|' + str(d.get('why_not', '')))" 2>&1)
  if [[ ${ROLE[$u]} == admin ]]; then
    [[ $c == 200 && $got == "True|" ]] && ok "A4 admin GET applications/unassigned: can_edit true" || bad "A4 admin applications/unassigned: $c $got"
  else
    [[ $c == 200 && $got == "False|changing an application needs the admin role: $u is $(art "${ROLE[$u]}") ${ROLE[$u]} "* ]] \
      && ok "A4 ${ROLE[$u]} GET applications/unassigned: can_edit false with the role's words" || bad "A4 ${ROLE[$u]} applications/unassigned: $c $got"
  fi
done

# S5e: an edit writes the rule's successor, a mute like any other. Two rules of the admin's: one on every instance,
# one on an instance registered for these rows
IID=$(q "select pgvigil.ensure_instance('roles-i$SUF', 'onprem', '18', 180000, false, '{}')")
post a$SUF /api/ack "{\"kind\":\"mute\",\"instance_id\":$IID,\"check_key\":\"y\",$END}" > /dev/null
WIDE=$(q "select coalesce(max(ack_id), 0) from pgvigil.acks where kind = 'mute' and instance_id is null and ended_at is null")
ONE=$(q "select coalesce(max(ack_id), 0) from pgvigil.acks where kind = 'mute' and instance_id = $IID and ended_at is null")
if [[ $WIDE == 0 || $ONE == 0 ]]; then bad "S5e: the admin's two mute rules are not in the store (every instance: $WIDE, one instance: $ONE): no edit row ran"
else
  s5e() {   # s5e <user> <want: admin|own> <body> <what>
    local res code; res=$(post "$1" /api/alerts/mute "$3"); code=${res%% *}
    if [[ $2 == admin ]]; then
      [[ $code == 403 && $res == *"a fleet-wide or open-ended mute needs the admin role"* && $res == *"$1 is"* ]] && ok "S5e ${ROLE[$1]} $4: refused ($res)" || bad "S5e ${ROLE[$1]} $4: $res"
    else
      [[ $code == 200 && $res == *done* ]] && ok "S5e ${ROLE[$1]} $4: done ($res)" || bad "S5e ${ROLE[$1]} $4: $res"
    fi
  }
  one() { q "select coalesce(max(ack_id), 0) from pgvigil.acks where kind = 'mute' and instance_id = $IID and ended_at is null"; }
  s5e o$SUF admin "{\"op\":\"edit\",\"ack_id\":$WIDE,\"check_key\":\"x\",$END}" "the edit of a rule on every instance"
  s5e o$SUF admin "{\"op\":\"edit\",\"ack_id\":$(one),\"any_instance\":true,\"check_key\":\"y\",$END}" "an edit to every instance"
  s5e o$SUF admin "{\"op\":\"edit\",\"ack_id\":$(one),\"check_key\":\"y\",\"tag\":\"prod\",$END}" "an edit that adds a tag"
  s5e o$SUF admin "{\"op\":\"edit\",\"ack_id\":$(one),\"check_key\":\"y\"}" "an edit with no end"
  s5e o$SUF admin "{\"op\":\"edit\",\"ack_id\":$(one),\"check_key\":\"y\",$FAR}" "an edit with an end 30 days away"
  s5e o$SUF own "{\"op\":\"edit\",\"ack_id\":$(one),\"check_key\":\"z\",$END}" "an edit that keeps its one instance and an end"
  s5e a$SUF own "{\"op\":\"edit\",\"ack_id\":$(one),\"any_instance\":true,\"check_key\":\"z\",$END}" "an edit to every instance"
fi

# ---- S9 --------------------------------------------------------------------------------------------------------------
aud0=$(q "select count(*) from pgvigil.admin_audit"); ack0=$(q "select count(*) from pgvigil.acks")
c=$(curl -s -o "$WORK/h.body" -w '%{http_code}' -b "$WORK/a$SUF.jar" -H 'Content-Type: application/json' --data '{"kind":"note","note":"x"}' "$U/api/ack")
[[ $c == 403 && $(cat "$WORK/h.body") == *X-Pgvigil* && $(q "select count(*) from pgvigil.admin_audit") == "$aud0" && $(q "select count(*) from pgvigil.acks") == "$ack0" ]] \
  && ok "S9 a POST without the header: 403 '$(cat "$WORK/h.body")', nothing written" || bad "S9 without the header: $c $(cat "$WORK/h.body")"
r1=$(post dem$SUF /api/admin/applications '{}')
"$BIN" user role -config "$CFG" dem$SUF viewer > "$WORK/dem.out" 2>&1; ROLE[dem$SUF]=viewer
r2=$(post dem$SUF /api/admin/applications '{}')
[[ ! $r1 =~ $ROLEWORDS && ${r2%% *} == 403 && $r2 == *"needs the admin role"* && $r2 == *"dem$SUF is a viewer"* ]] \
  && ok "S9 a user demoted mid-session: the next POST refused ($r2)" || bad "S9 demoted mid-session: before '$r1', after '$r2' ($(cat "$WORK/dem.out"))"
"$BIN" user disable -config "$CFG" dis$SUF >/dev/null 2>&1
r=$(post dis$SUF /api/ack '{"kind":"note","note":"x"}')
[[ ${r%% *} == 401 ]] && ok "S9 a user disabled mid-session: 401" || bad "S9 disabled mid-session: $r"
# serve signs in to the repository as its superuser here, which no REVOKE stops: the lookup fails by the function's
# name moved aside for the row, and put back
out=$(q "alter function pgvigil.ui_login_of(text) rename to ui_login_of_away")
if [[ $out == *ERROR* ]]; then bad "S9 the lookup error: the function could not be moved aside ($out)"
else
  r=$(post a$SUF /api/ack '{"kind":"note","note":"x"}'); g=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/a$SUF.jar" "$U/api/session")
  q "alter function pgvigil.ui_login_of_away(text) rename to ui_login_of" >/dev/null
  [[ ${r%% *} == 503 && $r == *"the role could not be read"* ]] && ok "S9 the role lookup failing: a POST 503 ($r); GET /api/session $g" || bad "S9 the lookup error: $r (GET $g)"
fi
P2=$(freeport)
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$P2" -no-login > "$WORK/serve2.log" 2>&1 & SRV2=$!
for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$P2/" && break; sleep 0.5; done
c=$(curl -s -o "$WORK/nl.body" -w '%{http_code}' -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$P2/api/admin/applications")
[[ $c == 403 && $(cat "$WORK/nl.body") == *"runs with -no-login"* ]] && ok "S9 -no-login: its words unchanged ($(cat "$WORK/nl.body"))" || bad "S9 -no-login: $c $(cat "$WORK/nl.body")"
for u in v$SUF o$SUF a$SUF; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/$u.jar" -H 'X-Pgvigil: 1' -X POST "$U/api/logout")
  [[ $c == 204 ]] || bad "S9 logout $u: $c"
done
ok "S9 logout: each user (anyone)"

echo "proof-uiroles: $FAILS FAIL"
(( FAILS == 0 )) && echo "PASS: proof-uiroles" || exit 1
