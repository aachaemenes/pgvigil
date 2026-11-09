#!/usr/bin/env bash
# Proof of the roles collection (0020): roles and their attributes, memberships, a database ACL, a schema ACL and a
# default privilege, the hba rules read or skipped with the reason, the role findings and the change history.
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN). The proof makes its own
#               repository database, two target databases, a pg_monitor-only login and its test roles, all with a
#               random suffix, and drops them at the end; nothing that exists before the run is touched (the
#               server's pg_hba.conf is read, never changed: the hba change is shown on seeded imports, part C).
#
# Expected (written before the first run):
#  A. collect -once roles as the pg_monitor-only login (MON), the target DSN on tgt1 (tgt2 a second database), after:
#       roles  own (NOLOGIN, owns schema s_<suf> in tgt1), grp (NOLOGIN), rw (LOGIN, member of grp), su (SUPERUSER
#              NOLOGIN), cr (CREATEROLE NOLOGIN), br (BYPASSRLS NOLOGIN)
#       GRANT CONNECT, TEMPORARY ON DATABASE tgt1 TO rw; GRANT CREATE ON DATABASE tgt2 TO grp;
#       GRANT USAGE ON SCHEMA s_<suf> TO grp; ALTER DEFAULT PRIVILEGES FOR ROLE own IN SCHEMA s_<suf> GRANT SELECT ON TABLES TO grp
#     - role_attributes, the six proof roles with role_flags: br 'bypassrls', cr 'createrole', grp '', own '', rw 'login',
#       su 'superuser'; and MON 'login'
#     - role_members: grp <- rw (admin false), pg_monitor <- MON
#     - acl_databases: tgt1 rw|CONNECT,TEMPORARY by <admin>; tgt2 grp|CREATE by <admin>; tgt1 not is_default
#     - acl_schemas: tgt1 s_<suf>: grp|USAGE by own, own|CREATE,USAGE by own
#     - acl_default_privileges: tgt1, for own in s_<suf> on table: grp|SELECT by own
#     - role_state: login MON, has_pg_monitor t, hba_status 'skipped' with a note naming the superuser rule;
#       no hba_rules rows; collection status ok
#     - role_findings for the proof roles exactly:
#         BYPASSRLS|warning|br, CREATEROLE|warning|cr, superuser|warning|su
#     - no role_history rows (the first read)
#  B. changes, then collect again as MON: CREATE ROLE nw LOGIN; GRANT grp TO nw (a new member); REVOKE TEMPORARY ON
#     DATABASE tgt1 FROM rw (a dropped grant); REVOKE USAGE ON SCHEMA s_<suf> FROM grp; ALTER ROLE cr NOCREATEROLE;
#     DROP ROLE br. role_history of this read, for the proof's objects, exactly:
#         database acl|<tgt1>|rw (by <admin>)|changed|CONNECT,TEMPORARY|CONNECT
#         member||grp <- nw (by <boot>)|granted||
#         role||br|removed|bypassrls|
#         role||cr|changed|createrole|
#         role||nw|added||login
#         schema acl|<tgt1>|s_<suf>: grp (by own)|revoked|USAGE|
#     role_findings for the proof roles exactly: superuser|warning|su; br is_present false; status ok
#  B2. a second instance on the same server read as the superuser: role_state hba_status 'read', a 32-character
#      checksum, hba_rules = the count pg_hba_file_rules shows, rules in line order; no pg_monitor finding (a
#      superuser holds every role)
#  C. import_roles seeded on scratch instances (the rules the sandbox cannot show without touching what it holds):
#       x (onprem): postgres (oid 10, superuser, login), dba_x (superuser), app_x (CREATEROLE), mon_x (the collector's
#          login, no pg_monitor), rw_x (login, granted CONNECT on both databases a and b, owned by postgres), exp_x
#          (login, member of grp_x, VALID UNTIL 2020), lone_x (login, named by no hba rule), peer_x (login, VALID UNTIL
#          2020, admitted by peer); hba read: local all postgres peer; host all +grp_x md5; host all mon_x scram;
#          host all rw_x scram; local all peer_x peer; host replication all trust (replication only: admits no login)
#          -> exactly: CREATEROLE|warning|app_x, granted on every database|info|rw_x, login without a way in|info|exp_x,
#             login without a way in|info|lone_x, pg_monitor|warning|mon_x, superuser|warning|dba_x
#       y (rds): rdsadmin (superuser, oid 16390), rds_superuser (CREATEROLE), admin_y (CREATEROLE, CREATEDB, login,
#          member of rds_superuser), app_y (BYPASSRLS); hba skipped -> exactly BYPASSRLS|warning|app_y
#     x again with the hba read skipped: the rules stay present, role_state keeps the checksum, no history;
#     x a third time, read, with 'host all lone_x 0.0.0.0/0 scram-sha-256' added and the replication rule gone ->
#     history exactly: hba checksum|pg_hba.conf|changed|<sum1>|<sum3>, hba rule|host all lone_x 0.0.0.0/0 scram-sha-256|added,
#     hba rule|host replication all 10.0.0.0/8 trust|removed; lone_x's finding gone.
#  D. role_flags and role_is_platform: role_flags(super, login, connlimit 5, valid until 2030-01-01) =
#     'superuser,login,connection limit 5,valid until 2030-01-01 00:00 UTC'; role_is_platform: rds rdsadmin t,
#     onprem rdsadmin f, any pg_monitor t, any oid 10 t, azure azure_pg_admin t, onprem app f.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
SUF=$RANDOM
REPO_DB=pgvigil_rolproof_$SUF; T1=pgvigil_rol1_$SUF; T2=pgvigil_rol2_$SUF
MON=pgvigil_rolmon_$SUF; MONPW=p$RANDOM$RANDOM
OWN=pgvigil_rown_$SUF; GRP=pgvigil_rgrp_$SUF; RW=pgvigil_rrw_$SUF; SU=pgvigil_rsu_$SUF; CR=pgvigil_rcr_$SUF; BR=pgvigil_rbr_$SUF; NW=pgvigil_rnw_$SUF
SCH=s_$SUF
dsn_for() { echo "$ADMIN_DSN dbname=$1"; }   # a later keyword wins, in libpq and in pgx
CFG=$(mktemp)
cleanup() {
  rm -f "$CFG"
  for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  for r in "$NW" "$RW" "$GRP" "$OWN" "$SU" "$CR" "$BR" "$MON"; do psql "$ADMIN_DSN" -XAtq -c "drop role if exists $r" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for d in "$REPO_DB" "$T1" "$T2"; do adm "create database $d" >/dev/null; done
adm "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
ADM=$(adm "select current_user"); BOOT=$(adm "select rolname from pg_roles where oid = 10")
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN=$(dsn_for "$REPO_DB")
export TGT_DSN; TGT_DSN="$(dsn_for "$T1") user=$MON password=$MONPW"
export SU_DSN; SU_DSN="$(dsn_for "$T1")"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t1() { psql "$(dsn_for "$T1")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- A. first read as the pg_monitor-only login"
adm "create role $OWN nologin; create role $GRP nologin; create role $RW login in role $GRP;
     create role $SU superuser nologin; create role $CR createrole nologin; create role $BR bypassrls nologin;
     grant connect, temporary on database $T1 to $RW; grant create on database $T2 to $GRP" >/dev/null
t1 "create schema $SCH authorization $OWN; grant usage on schema $SCH to $GRP;
    alter default privileges for role $OWN in schema $SCH grant select on tables to $GRP" >/dev/null

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-roles-$SUF
    dsn: env:TGT_DSN
  - name: proof-roles-su-$SUF
    dsn: env:SU_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once roles -instance "proof-roles-$SUF" || fail "collect roles (run 1)"
iid=$(q "select instance_id from pgvigil.instances where name='proof-roles-$SUF'")
st() { q "select status || coalesce(': ' || note, '') from pgvigil.collection_dates where instance_id=$1 and collection='roles'"; }
[[ $(st "$iid") == ok* ]] || fail "collection status: $(st "$iid")"
mine="like '%\_$SUF'"
flags=$(q "select string_agg(rolname || '=' || pgvigil.role_flags(super, inherit, createrole, createdb, canlogin, replication, bypassrls, connlimit, valid_until), ' ' order by rolname)
             from pgvigil.role_attributes where instance_id=$iid and is_present and rolname $mine")
want="$BR=bypassrls $CR=createrole $GRP= $MON=login $OWN= $RW=login $SU=superuser"
[[ "$flags" == "$want" ]] || fail "roles: got '$flags' want '$want'"
echo "roles: $flags"
mem=$(q "select string_agg(role_name || ' <- ' || member_name || ' admin=' || admin_option, '; ' order by role_name, member_name)
           from pgvigil.role_members where instance_id=$iid and is_present and member_name $mine")
want="pg_monitor <- $MON admin=false; $GRP <- $RW admin=false"
[[ "$mem" == "$want" ]] || fail "members: got '$mem' want '$want'"
echo "members: $mem"
dacl=$(q "select string_agg(datname || ' ' || grantee || '|' || privileges || ' by ' || grantor, '; ' order by datname, grantee)
            from pgvigil.acl_databases where instance_id=$iid and is_present and datname in ('$T1','$T2') and grantee $mine")
want="$T1 $RW|CONNECT,TEMPORARY by $ADM; $T2 $GRP|CREATE by $ADM"
[[ "$dacl" == "$want" ]] || fail "database ACL: got '$dacl' want '$want'"
[[ $(q "select bool_or(is_default) from pgvigil.acl_databases where instance_id=$iid and datname='$T1'") == f ]] || fail "tgt1 ACL marked default"
echo "database ACL: $dacl"
sacl=$(q "select string_agg(schema_name || ': ' || grantee || '|' || privileges || ' by ' || grantor, '; ' order by grantee)
            from pgvigil.acl_schemas where instance_id=$iid and is_present and datname='$T1' and schema_name='$SCH'")
want="$SCH: $GRP|USAGE by $OWN; $SCH: $OWN|CREATE,USAGE by $OWN"
[[ "$sacl" == "$want" ]] || fail "schema ACL: got '$sacl' want '$want'"
echo "schema ACL: $sacl"
defp=$(q "select string_agg('for ' || owner || ' in ' || schema_name || ' on ' || objtype || ': ' || grantee || '|' || privileges || ' by ' || grantor, '; ')
            from pgvigil.acl_default_privileges where instance_id=$iid and is_present and datname='$T1' and owner='$OWN'")
want="for $OWN in $SCH on table: $GRP|SELECT by $OWN"
[[ "$defp" == "$want" ]] || fail "default privileges: got '$defp' want '$want'"
echo "default privileges: $defp"
state=$(q "select login_name || '|' || login_has_pg_monitor || '|' || hba_status from pgvigil.role_state where instance_id=$iid")
[[ "$state" == "$MON|true|skipped" ]] || fail "role_state: '$state'"
note=$(q "select hba_note from pgvigil.role_state where instance_id=$iid")
[[ "$note" == *superuser* ]] || fail "hba skip note: '$note'"
[[ $(q "select count(*) from pgvigil.hba_rules where instance_id=$iid") == 0 ]] || fail "hba rows on a skipped read"
echo "hba: skipped - $note"
fnd() { q "select string_agg(setting || '|' || severity || '|' || value, E'\n' order by setting, severity, value) from pgvigil.role_findings where instance_id=$1 $2"; }
want=$(printf '%s\n' "BYPASSRLS|warning|$BR" "CREATEROLE|warning|$CR" "superuser|warning|$SU")
got=$(fnd "$iid" "and value $mine")
[[ "$got" == "$want" ]] || fail "findings A: got
$got
want
$want"
echo "findings:"; echo "$got"
[[ $(q "select count(*) from pgvigil.role_history where instance_id=$iid") == 0 ]] || fail "history on the first read"

echo "--- B. changes"
adm "create role $NW login; grant $GRP to $NW; revoke temporary on database $T1 from $RW; alter role $CR nocreaterole; drop role $BR" >/dev/null
t1 "revoke usage on schema $SCH from $GRP" >/dev/null
sleep 1.1
"$BIN" collect -config "$CFG" -once roles -instance "proof-roles-$SUF" || fail "collect roles (run 2)"
[[ $(st "$iid") == ok ]] || fail "status run 2: $(st "$iid")"
S2=$(q "select max(changed_at) from pgvigil.role_history where instance_id=$iid")
hist=$(q "select string_agg(object_kind || '|' || coalesce(datname, '') || '|' || object || '|' || change || '|' || coalesce(old_value, '') || '|' || coalesce(new_value, ''), E'\n'
                            order by object_kind, object)
            from pgvigil.role_history where instance_id=$iid and changed_at='$S2' and (object like '%$SUF%')")
want=$(printf '%s\n' "database acl|$T1|$RW (by $ADM)|changed|CONNECT,TEMPORARY|CONNECT" \
                     "member||$GRP <- $NW (by $BOOT)|granted||" \
                     "role||$BR|removed|bypassrls|" \
                     "role||$CR|changed|createrole|" \
                     "role||$NW|added||login" \
                     "schema acl|$T1|$SCH: $GRP (by $OWN)|revoked|USAGE|")
[[ "$hist" == "$want" ]] || fail "history: got
$hist
want
$want"
echo "history:"; echo "$hist"
got=$(fnd "$iid" "and value $mine")
[[ "$got" == "superuser|warning|$SU" ]] || fail "findings B: $got"
[[ $(q "select is_present from pgvigil.role_attributes where instance_id=$iid and rolname='$BR'") == f ]] || fail "$BR still present"
echo "findings after: $got"

echo "--- B2. the hba rules read as a superuser"
"$BIN" collect -config "$CFG" -once roles -instance "proof-roles-su-$SUF" || fail "collect roles (superuser)"
isu=$(q "select instance_id from pgvigil.instances where name='proof-roles-su-$SUF'")
[[ $(st "$isu") == ok ]] || fail "status su: $(st "$isu")"
NRULES=$(adm "select count(*) from pg_hba_file_rules")
hs=$(q "select hba_status || '|' || length(hba_checksum) || '|' || hba_rules from pgvigil.role_state where instance_id=$isu")
[[ "$hs" == "read|32|$NRULES" ]] || fail "hba state as superuser: '$hs' (server has $NRULES rules)"
[[ $(q "select count(*) from pgvigil.hba_rules where instance_id=$isu and is_present") == "$NRULES" ]] || fail "hba rows"
echo "hba: read, $NRULES rule(s), checksum $(q "select hba_checksum from pgvigil.role_state where instance_id=$isu")"
q "select line_number, pgvigil.role_hba_text(type, databases, users, address, netmask, auth_method, options, error) from pgvigil.hba_rules where instance_id=$isu order by line_number"
[[ $(q "select count(*) from pgvigil.role_findings where instance_id=$isu and setting='pg_monitor'") == 0 ]] || fail "pg_monitor finding on a superuser login"

echo "--- C. seeded rules"
seed() { q "select pgvigil.ensure_instance('proof-roles-$1-$SUF', '$2', '16.4', 160004, false, '{}')"; }
imp() { q "select pgvigil.import_roles($1, now() + make_interval(secs => $2), '$3'::jsonb)" >/dev/null; }
ix=$(seed x onprem); iy=$(seed y rds)
role() { # name oid super createrole createdb login bypassrls valid_until
  printf '{"kind":"role","name":"%s","oid":%s,"super":%s,"inherit":true,"createrole":%s,"createdb":%s,"canlogin":%s,"replication":false,"bypassrls":%s,"connlimit":-1,"valid_until":%s,"config":null}' "$@"; }
XROLES="$(role postgres 10 true true true true true null),$(role dba_x 16400 true false false false false null),
$(role app_x 16401 false true false false false null),$(role mon_x 16402 false false false true false null),
$(role rw_x 16403 false false false true false null),$(role exp_x 16404 false false false true false '"2020-01-01T00:00:00Z"'),
$(role grp_x 16405 false false false false false null),$(role lone_x 16406 false false false true false null),
$(role peer_x 16407 false false false true false '"2020-01-01T00:00:00Z"')"
XMEM='{"kind":"member","role":"grp_x","member":"exp_x","grantor":"postgres","admin_option":false,"inherit_option":true,"set_option":true}'
XACL='{"kind":"dbacls","names":["a","b"]},{"kind":"databases","names":["a","b"]},
{"kind":"dbacl","datname":"a","owner":"postgres","grantee":"postgres","grantor":"postgres","privileges":"CONNECT,CREATE,TEMPORARY","grantable":"","is_default":false},
{"kind":"dbacl","datname":"a","owner":"postgres","grantee":"PUBLIC","grantor":"postgres","privileges":"CONNECT,TEMPORARY","grantable":"","is_default":false},
{"kind":"dbacl","datname":"a","owner":"postgres","grantee":"rw_x","grantor":"postgres","privileges":"CONNECT","grantable":"","is_default":false},
{"kind":"dbacl","datname":"b","owner":"postgres","grantee":"postgres","grantor":"postgres","privileges":"CONNECT,CREATE,TEMPORARY","grantable":"","is_default":false},
{"kind":"dbacl","datname":"b","owner":"postgres","grantee":"rw_x","grantor":"postgres","privileges":"CONNECT","grantable":"","is_default":false}'
hba() { # line type db users address method
  printf '{"kind":"hba","rule_number":%s,"file_name":"/etc/pg_hba.conf","line_number":%s,"type":"%s","databases":["%s"],"users":["%s"],"address":%s,"netmask":null,"auth_method":"%s","options":null,"error":null}' "$1" "$1" "$2" "$3" "$4" "$5" "$6"; }
H1="$(hba 1 local all postgres null peer),$(hba 2 host all +grp_x '"0.0.0.0/0"' md5),$(hba 3 host all mon_x '"10.0.0.0/8"' scram-sha-256),
$(hba 4 host all rw_x '"10.0.0.0/8"' scram-sha-256),$(hba 5 local all peer_x null peer),$(hba 6 host replication all '"10.0.0.0/8"' trust)"
imp "$ix" 0 "[{\"kind\":\"login\",\"name\":\"mon_x\",\"is_super\":false,\"has_pg_monitor\":false},$XROLES,$XMEM,$XACL,$H1,
              {\"kind\":\"hba_state\",\"status\":\"read\",\"note\":\"\",\"checksum\":\"sum1\",\"rules\":6}]"
imp "$iy" 0 "[{\"kind\":\"login\",\"name\":\"admin_y\",\"is_super\":false,\"has_pg_monitor\":true},
              $(role rdsadmin 16390 true true true true true null),$(role rds_superuser 16391 false true true false false null),
              $(role admin_y 16500 false true true true false null),$(role app_y 16501 false false false true true null),
              {\"kind\":\"member\",\"role\":\"rds_superuser\",\"member\":\"admin_y\",\"grantor\":\"rdsadmin\",\"admin_option\":false},
              {\"kind\":\"hba_state\",\"status\":\"skipped\",\"note\":\"pg_hba_file_rules is readable by a superuser only\"}]"
want_x=$(printf '%s\n' "CREATEROLE|warning|app_x" "granted on every database|info|rw_x" "login without a way in|info|exp_x" \
                       "login without a way in|info|lone_x" "pg_monitor|warning|mon_x" "superuser|warning|dba_x")
want_y="BYPASSRLS|warning|app_y"
for c in x y; do
  id=$(eval echo "\$i$c"); want=$(eval echo "\"\$want_$c\""); got=$(fnd "$id" "")
  [[ "$got" == "$want" ]] || fail "findings $c: got
$got
want
$want"
  echo "findings $c:"; echo "$got"
done
# x again, the hba read skipped: the rules and the checksum stay, no history
imp "$ix" 60 "[{\"kind\":\"login\",\"name\":\"mon_x\",\"is_super\":false,\"has_pg_monitor\":false},$XROLES,$XMEM,$XACL,
               {\"kind\":\"hba_state\",\"status\":\"skipped\",\"note\":\"permission denied\"}]"
[[ $(q "select count(*) from pgvigil.hba_rules where instance_id=$ix and is_present") == 6 ]] || fail "x rules dropped on a skipped read"
[[ $(q "select hba_status || '|' || hba_checksum || '|' || hba_rules from pgvigil.role_state where instance_id=$ix") == "skipped|sum1|6" ]] \
  || fail "x state after a skip: $(q "select hba_status, hba_checksum, hba_rules from pgvigil.role_state where instance_id=$ix")"
[[ $(q "select count(*) from pgvigil.role_history where instance_id=$ix") == 0 ]] || fail "x history after a skip: $(q "select * from pgvigil.role_history where instance_id=$ix")"
# x a third time, read, one rule added and the replication rule gone
H3="$(hba 1 local all postgres null peer),$(hba 2 host all +grp_x '"0.0.0.0/0"' md5),$(hba 3 host all mon_x '"10.0.0.0/8"' scram-sha-256),
$(hba 4 host all rw_x '"10.0.0.0/8"' scram-sha-256),$(hba 5 local all peer_x null peer),$(hba 6 host all lone_x '"0.0.0.0/0"' scram-sha-256)"
imp "$ix" 120 "[{\"kind\":\"login\",\"name\":\"mon_x\",\"is_super\":false,\"has_pg_monitor\":false},$XROLES,$XMEM,$XACL,$H3,
                {\"kind\":\"hba_state\",\"status\":\"read\",\"note\":\"\",\"checksum\":\"sum3\",\"rules\":6}]"
hx=$(q "select string_agg(object_kind || '|' || object || '|' || change || '|' || coalesce(old_value, '') || '|' || coalesce(new_value, ''), E'\n' order by object_kind, object)
          from pgvigil.role_history where instance_id=$ix")
want=$(printf '%s\n' "hba checksum|pg_hba.conf|changed|sum1|sum3" "hba rule|host all lone_x 0.0.0.0/0 scram-sha-256|added||" \
                     "hba rule|host replication all 10.0.0.0/8 trust|removed||")
[[ "$hx" == "$want" ]] || fail "x hba history: got
$hx
want
$want"
echo "x hba history:"; echo "$hx"
[[ $(q "select count(*) from pgvigil.role_findings where instance_id=$ix and value='lone_x'") == 0 ]] || fail "lone_x finding stays"

echo "--- D. role_flags and role_is_platform"
[[ $(q "select pgvigil.role_flags(true, true, false, false, true, false, false, 5, '2030-01-01 00:00+00')") == "superuser,login,connection limit 5,valid until 2030-01-01 00:00 UTC" ]] \
  || fail "role_flags: $(q "select pgvigil.role_flags(true, true, false, false, true, false, false, 5, '2030-01-01 00:00+00')")"
[[ $(q "select pgvigil.role_is_platform('rds','rdsadmin',16390), pgvigil.role_is_platform('onprem','rdsadmin',16390), pgvigil.role_is_platform('onprem','pg_monitor',3373),
             pgvigil.role_is_platform('onprem','postgres',10), pgvigil.role_is_platform('azure','azure_pg_admin',16390), pgvigil.role_is_platform('onprem','app',16500)") == "t|f|t|t|t|f" ]] \
  || fail "role_is_platform"
echo "PASS proof-roles-acl"
