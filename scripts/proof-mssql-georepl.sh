#!/usr/bin/env bash
# Proof of task 390a on a real pair: Azure SQL Database's active geo-replication (mssql_georepl) and failover groups
# (mssql_failover_groups) as pgvigil reads, stores, judges and shows them, each fault made, its finding read, cleared
# and the clear read. It drives the lab itself (scripts/lab/azure-sqldb.sh geo-up, fg-make, fg-policy, fg-failover,
# geo-unlink) on a basic lab that is up, allowed and has its logins, and leaves the geo pieces to the lab's down.
#
# Runs on the machine that holds the Azure CLI sign-in (no credential or token goes to a cloud box: the lab rule of
# 2026-11-14), against a repository reached from there (the A1-E form: the box's PostgreSQL through a tunnel).
# Needs: docker (sqlcmd from PGVIGIL_SQLCMD_IMAGE), psql, jq, python3, az signed in (the faults, and G2's token through
# azidentity's default chain: the Azure CLI's sign-in), PGVIGIL_BIN (a built pgvigil) or a go toolchain, and
#   PGVIGIL_ADMIN_DSN    a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the repository is made there)
#   PGVIGIL_LAB_STATE    the lab's state file, default .lab/azure-sqldb.env (a basic lab: up, allow, logins)
#   PGVIGIL_PROOF_MY_IP  this machine's public IPv4 (allow is run again for both servers after geo-up)
#   PGVIGIL_LAB_AZ_SUBSCRIPTION, PGVIGIL_LAB_AZ_GROUP, PGVIGIL_LAB_AZ_GEO_REGION, PGVIGIL_LAB_PROOF  as the lab script
#
# Expected (written before the first run; red first: on a tree without 390a, mssql_georepl and mssql_failover_groups
# are unknown collections and every G row FAILs):
#  G-A one database, no link: mssql_georepl ok; mssql_georepl_read links 0 and server_read = the lab's server; no state.
#  G-B geo-up: within 10 minutes both databases read one link with the SAME link_guid, PRIMARY on the lab's server and
#      SECONDARY on the geo server; CATCH_UP required (SEEDING when a read caught it); an 'added' event on each; the
#      secondary's replication_lag_sec NULL; the API's links part shows the partner's instance on each side.
#  G-C a write burst on the primary (2 minutes of inserts into the proof's own table), then 5 idle minutes: a sample
#      each minute; the idle and the burst maxima of replication_lag_sec and unsent_s printed; then a tag-level tier
#      between them (georepl_data_loss warn in minutes) and a second burst held 6 minutes: the 'geo-replication data
#      loss' finding read (warning), the tier taken back (inherit), the clear read. Whether last_replication advances on
#      an idle primary (ack_age_s stays small) is printed: the docs' line follows it (fold 8).
#  G-D fg-make (Manual): mssql_failover_groups' row (role Primary on the lab's server, rw_policy Manual, the geo server
#      a Secondary partner, the database in it, secondary_type Geo); fg-policy Automatic: a 'policy' event, grace 60.
#  G-E fg-failover (planned): the role events on both databases (PRIMARY->SECONDARY and back), the group's 'role' event,
#      each finding critical for the hour; the Activity Log's 'failover' operation stored within 25 minutes, or the
#      trial's NOT PROVEN line with what the log answered.
#  G-E2 an instance configured on the group's listener (<group>.database.windows.net): before the failover it reads the
#      lab's server, after it the geo server: a 'partner' event and its critical finding (the read reached the other
#      server: server_read changed).
#  G-F fg-failover force: the same events (the view cannot tell planned from forced); the Activity Log's 'forced
#      failover' operation, or the trial's line.
#  G-G geo-unlink: 'removed' on both databases, the state rows gone, the 24-hour warning; the group's 'removed' event.
#  G-H the rights: the proof's CONNECT-only user is skipped 'the login lacks VIEW DATABASE STATE'; pgv_conn
#      (##MS_ServerStateReader##, no user) reads or is skipped with its reason (printed: one trial); an instance with
#      an azure: block naming a server the identity cannot read stores Resource Manager's refusal with its code; an
#      instance without one is skipped 'no azure: block'.
set -Eeuo pipefail
trap 'echo "STOPPED: line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
: "${PGVIGIL_PROOF_MY_IP:?the public IPv4 of this machine}"
STATE=${PGVIGIL_LAB_STATE:-.lab/azure-sqldb.env}
IMG=${PGVIGIL_SQLCMD_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
LAB=scripts/lab/azure-sqldb.sh
for t in docker psql jq python3 az; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
[ -r "$STATE" ] || { echo "FAIL: no lab state file $STATE (azure-sqldb.sh up, allow, logins on the basic tier)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE"
: "${AZ_SERVER:?} ${AZ_HOST:?} ${AZ_DB:?} ${ADMIN_USER:?} ${ADMIN_PW:?} ${MON_USER:?} ${MON_PW:?} ${CONN_USER:?} ${CONN_PW:?}"
[ "${AZ_TIER:-}" = basic ] || { echo "FAIL: the lab is not the basic tier" >&2; exit 1; }
SUF=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
REPO_DB=pgvigil_geoproof_$SUF; N=proof-geo-$SUF; TAG=geoproof$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml
export SQLCMDPASSWORD="$ADMIN_PW"
MADE_DB=; MADE_T=; MADE_NR=
NR_USER=pgvproof_nr_$SUF; NR_PW=$(printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')")
FAILS=(); NOTPROVEN=()
bad() { FAILS+=("$*"); echo "  FAIL: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }
# sq <host> "<sql>": rows as the setup login on that server's copy of the database, '|' between columns
sq() { local h=$1 out rc=0
  out=$(docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$h,1433" -U "$ADMIN_USER" \
    -d "$AZ_DB" -C -b -I -l 60 -h -1 -s '|' -W -i /dev/stdin <<<"SET NOCOUNT ON; $2" 2>&1) || rc=$?
  [ $rc -eq 0 ] || { echo "FAIL: a read as the setup login on $h failed ($rc): $(tr '\n' ' ' <<<"$out" | cut -c1-400)" >&2; return $rc; }
  printf '%s\n' "$out"; }
cleanup() {
  rc=$?; set +e; trap '' INT TERM
  if [ -n "$MADE_T" ]; then sq "$AZ_HOST" "DROP TABLE IF EXISTS dbo.pgvproof_geo_$SUF" >/dev/null 2>&1 || echo "CLEANUP: dbo.pgvproof_geo_$SUF not dropped (down removes the database)" >&2; fi
  if [ -n "$MADE_NR" ]; then sq "$AZ_HOST" "DROP USER IF EXISTS [$NR_USER]" >/dev/null 2>&1 || echo "CLEANUP: $NR_USER not dropped (down removes the database)" >&2; fi
  if [ -n "$MADE_DB" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [ -n "${PGVIGIL_BIN:-}" ]; then BIN=$PGVIGIL_BIN; else
  command -v go >/dev/null || die "go is not on this machine and PGVIGIL_BIN names no binary"
  CGO_ENABLED=0 go build -trimpath -o "$WORK/pgvigil" ./cmd/pgvigil; BIN=$WORK/pgvigil; fi

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_DB=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
dsn() { printf 'sqlserver://%s:%s@%s:1433?database=%s&encrypt=true' "$1" "$2" "$3" "$AZ_DB"; }
export GEO_P_DSN; GEO_P_DSN=$(dsn "$MON_USER" "$MON_PW" "$AZ_HOST")
export GEO_NR_DSN; GEO_NR_DSN=$(dsn "$NR_USER" "$NR_PW" "$AZ_HOST")
export GEO_CONN_DSN; GEO_CONN_DSN=$(dsn "$CONN_USER" "$CONN_PW" "$AZ_HOST")
writecfg() {   # the instances; the geo side and the listener once the lab has them
  { echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
    for x in "p|GEO_P_DSN|$AZ_SERVER" "nr|GEO_NR_DSN|" "conn|GEO_CONN_DSN|" "noaz|GEO_P_DSN|" "deny|GEO_P_DSN|pgv-proof-none-$SUF" ${GEO_SERVER:+"s|GEO_S_DSN|$GEO_SERVER"} ${FG_NAME:+"l|GEO_L_DSN|$AZ_SERVER"}; do
      IFS='|' read -r k v srv <<<"$x"
      printf '  - name: %s-%s\n    engine: sqlserver\n    dsn: env:%s\n    tags: [%s]\n' "$N" "$k" "$v" "$TAG"
      if [ -n "$srv" ]; then printf '    azure:\n      subscription: %s\n      resource_group: %s\n      server: %s\n' "$PGVIGIL_LAB_AZ_SUBSCRIPTION" "$PGVIGIL_LAB_AZ_GROUP" "$srv"; fi
    done; } > "$CFG"; }
run() { "$BIN" collect -config "$CFG" -once "$2" -instance "$N-$1" > "$WORK/$2.$1.out" 2>&1 || true; }
status() { q "SELECT d.status || '|' || coalesce(d.note, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$N-$1' AND d.collection = '$2'"; }
iid() { q "SELECT instance_id FROM pgvigil.instances WHERE name = '$N-$1'"; }
writecfg; "$BIN" migrate -config "$CFG" >/dev/null
( umask 077; printf "CREATE USER [%s] WITH PASSWORD = '%s';\n" "$NR_USER" "$NR_PW" > "$WORK/nr.sql" )
docker run --rm -i -e SQLCMDPASSWORD --entrypoint /opt/mssql-tools18/bin/sqlcmd "$IMG" -S "tcp:$AZ_HOST,1433" -U "$ADMIN_USER" -d "$AZ_DB" -C -b -l 60 -i /dev/stdin < "$WORK/nr.sql" >/dev/null && MADE_NR=1 || bad "G-H: the CONNECT-only user was not made"
rm -f "$WORK/nr.sql"

echo "--- G-A one database, no link"
run p mssql_instance; run p mssql_georepl
S=$(status p mssql_georepl); R=$(q "SELECT links || '|' || server_read FROM pgvigil.mssql_georepl_read WHERE instance_id = $(iid p)")
echo "  mssql_georepl: $S; read: $R"
[[ $S == ok* ]] && [ "$R" = "0|$AZ_SERVER" ] && echo "G-A: OK" || bad "G-A: '$S' '$R' (want ok and 0|$AZ_SERVER)"

echo "--- G-B geo-up (a second server, the Basic geo-secondary)"
"$LAB" geo-up | sed 's/^/  lab: /'
# shellcheck disable=SC1090
. "$STATE"
"$LAB" allow "$PGVIGIL_PROOF_MY_IP" | sed 's/^/  lab: /'; "$LAB" logins | sed 's/^/  lab: /'
export GEO_S_DSN; GEO_S_DSN=$(dsn "$MON_USER" "$MON_PW" "$GEO_HOST")
writecfg
SEEN_SEEDING=
for i in $(seq 1 10); do
  for k in p s; do run "$k" mssql_instance; run "$k" mssql_georepl; done
  st=$(q "SELECT string_agg(s.role_desc || ':' || s.replication_state_desc, ',' ORDER BY s.role_desc) FROM pgvigil.mssql_georepl_state s WHERE s.instance_id IN ($(iid p), $(iid s))")
  [[ ${st:-} == *SEEDING* ]] && SEEN_SEEDING=1
  [ "${st:-}" = "PRIMARY:CATCH_UP,SECONDARY:CATCH_UP" ] && break; sleep 60
done
echo "  after ${i} minute(s): $st${SEEN_SEEDING:+ (SEEDING read before)}"
G=$(q "SELECT count(DISTINCT link_guid) || '|' || count(*) FROM pgvigil.mssql_georepl_state WHERE instance_id IN ($(iid p), $(iid s))")
SL=$(q "SELECT coalesce(replication_lag_sec::text, 'NULL') FROM pgvigil.mssql_georepl_state WHERE instance_id = $(iid s)")
AD=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_events WHERE instance_id IN ($(iid p), $(iid s)) AND kind = 'added'")
[ "$st" = "PRIMARY:CATCH_UP,SECONDARY:CATCH_UP" ] && [ "$G" = "1|2" ] && [ "$SL" = NULL ] && [ "$AD" = 2 ] && echo "G-B: OK" \
  || bad "G-B: states '$st', link_guids|rows '$G', the secondary's lag '$SL', added events '$AD' (want both CATCH_UP, 1|2, NULL, 2)"

echo "--- G-C the lag under a burst and idle"
sq "$AZ_HOST" "CREATE TABLE dbo.pgvproof_geo_$SUF (id int IDENTITY PRIMARY KEY, pad char(2000) NOT NULL DEFAULT 'x')" >/dev/null; MADE_T=1
burst() { sq "$AZ_HOST" "DECLARE @end datetime2 = DATEADD(second, $1, SYSUTCDATETIME()); WHILE SYSUTCDATETIME() < @end BEGIN INSERT dbo.pgvproof_geo_$SUF DEFAULT VALUES; END" >/dev/null & }
burst 120; BP=$!
for i in $(seq 1 7); do sleep 60; run p mssql_georepl; done
wait "$BP" || true
VALS=$(q "SELECT max(replication_lag_sec) FILTER (WHERE snapshot_at > now() - interval '7 minutes' AND snapshot_at <= now() - interval '5 minutes') || '|' ||
             max(unsent_s) FILTER (WHERE snapshot_at > now() - interval '7 minutes' AND snapshot_at <= now() - interval '5 minutes') || '|' ||
             coalesce(max(replication_lag_sec) FILTER (WHERE snapshot_at > now() - interval '4 minutes'), 0) || '|' ||
             coalesce(max(unsent_s) FILTER (WHERE snapshot_at > now() - interval '4 minutes'), 0) || '|' ||
             coalesce(max(ack_age_s) FILTER (WHERE snapshot_at > now() - interval '4 minutes'), -1)
             FROM pgvigil.mssql_georepl_sample WHERE instance_id = $(iid p)")
echo "  burst max lag|unsent, idle max lag|unsent|ack age: $VALS"
IFS='|' read -r BL BU IL IU IA <<<"$VALS"
TIER=$(python3 -c "b=max(float('${BL:-0}' or 0), float('${BU:-0}' or 0)); i=max(float('${IL:-0}' or 0), float('${IU:-0}' or 0)); t=((b+i)/2)/60; print(f'{max(round(t, 2), 0.01):.2f}' if b > i else '')")   # import_pg_threshold takes 2 decimals (0190: ^[0-9]{1,7}(\.[0-9]{1,2})?$)
if [ -z "$TIER" ]; then NOTPROVEN+=("G-C: the burst raised no lag over the idle values ($VALS): the tier row not run")
else
  q "SELECT pgvigil.import_pg_threshold(now(), '{\"op\":\"set\",\"ui_user\":\"proof\",\"key\":\"georepl_data_loss\",\"level\":\"tag\",\"tag\":\"$TAG\",\"warn\":$TIER}'::jsonb)" > "$WORK/tier.out"
  if grep -q refused "$WORK/tier.out"; then bad "G-C: the tier $TIER was refused: $(cat "$WORK/tier.out")"; fi
  burst 400; BP=$!
  for i in $(seq 1 7); do sleep 60; run p mssql_georepl; done
  FD=$(q "SELECT severity FROM pgvigil.mssql_georepl_findings WHERE instance_id = $(iid p) AND check_name = 'geo-replication data loss'")
  wait "$BP" || true
  q "SELECT pgvigil.import_pg_threshold(now(), '{\"op\":\"inherit\",\"ui_user\":\"proof\",\"key\":\"georepl_data_loss\",\"level\":\"tag\",\"tag\":\"$TAG\"}'::jsonb)" >/dev/null
  run p mssql_georepl
  FC=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_findings WHERE instance_id = $(iid p) AND check_name = 'geo-replication data loss'")
  [ "$FD" = warning ] && [ "$FC" = 0 ] && echo "G-C: OK (tier $TIER min: fired warning, cleared)" || bad "G-C: the tier $TIER min gave '$FD', after inherit $FC finding(s) (want warning, then 0)"
fi
echo "  idle acknowledgement age: ${IA}s (fold 8: a 'no acknowledgement' check only if it stays small on an idle primary)"

echo "--- G-D the failover group"
"$LAB" fg-make | sed 's/^/  lab: /'
# shellcheck disable=SC1090
. "$STATE"
export GEO_L_DSN; GEO_L_DSN=$(dsn "$MON_USER" "$MON_PW" "$FG_NAME.database.windows.net")
writecfg
run p mssql_failover_groups
FG=$(q "SELECT role || '|' || rw_policy || '|' || secondary_type || '|' || (partners->0->>'server') || '|' || (databases ? '$AZ_DB')::text FROM pgvigil.mssql_failover_groups WHERE group_name = '$FG_NAME'")
echo "  group: $FG ($(status p mssql_failover_groups))"
"$LAB" fg-policy Automatic | sed 's/^/  lab: /'
sleep 310; run p mssql_failover_groups
PE=$(q "SELECT count(*) || '|' || max(new_value) FROM pgvigil.mssql_failover_group_events WHERE group_name = '$FG_NAME' AND kind = 'policy'")
[ "$FG" = "Primary|Manual|Geo|$GEO_SERVER|true" ] && [[ $PE == 1\|Automatic* ]] && echo "G-D: OK" || bad "G-D: group '$FG', policy events '$PE' (want Primary|Manual|Geo|$GEO_SERVER|true, then 1|Automatic 60)"

echo "--- G-E / G-E2 a planned failover"
for k in p s l; do run "$k" mssql_instance; run "$k" mssql_georepl; done
BEFORE_L=$(q "SELECT server_read FROM pgvigil.mssql_georepl_read WHERE instance_id = $(iid l)")
"$LAB" fg-failover | sed 's/^/  lab: /'
sleep 60
for k in p s l; do run "$k" mssql_instance; run "$k" mssql_georepl; done
sleep 250; run s mssql_failover_groups; run p mssql_failover_groups
RE=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_events WHERE instance_id IN ($(iid p), $(iid s)) AND kind = 'role'")
RF=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_findings WHERE instance_id IN ($(iid p), $(iid s)) AND check_name = 'geo-replication role changed' AND severity = 'critical'")
GE=$(q "SELECT count(*) FROM pgvigil.mssql_failover_group_events WHERE group_name = '$FG_NAME' AND kind = 'role'")
AFTER_L=$(q "SELECT server_read FROM pgvigil.mssql_georepl_read WHERE instance_id = $(iid l)")
PL=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_events WHERE instance_id = $(iid l) AND kind = 'partner'")
[ "$RE" = 2 ] && [ "$RF" = 2 ] && [ "$GE" -ge 1 ] && echo "G-E: OK" || bad "G-E: role events $RE, critical findings $RF, the group's role events $GE (want 2, 2, 1+)"
[ "$BEFORE_L" = "$AZ_SERVER" ] && [ "$AFTER_L" = "$GEO_SERVER" ] && [ "$PL" = 1 ] && echo "G-E2: OK" || bad "G-E2: the listener read '$BEFORE_L' then '$AFTER_L', partner events $PL (want $AZ_SERVER, $GEO_SERVER, 1)"

echo "--- G-F a forced failover back"
"$LAB" fg-failover force | sed 's/^/  lab: /'
sleep 60; for k in p s; do run "$k" mssql_georepl; done
RE2=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_events WHERE instance_id IN ($(iid p), $(iid s)) AND kind = 'role'")
[ "$RE2" = 4 ] && echo "G-F: OK (the view's events are the planned failover's)" || bad "G-F: role events $RE2 (want 4)"
echo "  the Activity Log (a trial), waited up to 20 minutes:"
OPS=
for i in $(seq 1 4); do run p mssql_failover_groups; OPS=$(q "SELECT string_agg(new_value || ' ' || old_value, ', ' ORDER BY at) FROM pgvigil.mssql_failover_group_events WHERE group_name = '$FG_NAME' AND kind = 'operation'"); [[ ${OPS:-} == *forced* ]] && break; sleep 300; done
echo "  operations: ${OPS:-none}; the collection: $(status p mssql_failover_groups)"
[[ ${OPS:-} == *failover* ]] || NOTPROVEN+=("G-E / G-F: the Activity Log gave no failover operation in 20 minutes (planned / forced not told: the view's window only)")

echo "--- G-G geo-unlink"
"$LAB" geo-unlink | sed 's/^/  lab: /'
sleep 30; for k in p s; do run "$k" mssql_georepl; done; run p mssql_failover_groups
RM=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_events WHERE instance_id IN ($(iid p), $(iid s)) AND kind = 'removed'")
LS=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_state WHERE instance_id IN ($(iid p), $(iid s))")
RW=$(q "SELECT count(*) FROM pgvigil.mssql_georepl_findings WHERE instance_id IN ($(iid p), $(iid s)) AND check_name = 'geo-replication link removed' AND severity = 'warning'")
GR=$(q "SELECT count(*) FROM pgvigil.mssql_failover_group_events WHERE group_name = '$FG_NAME' AND kind = 'removed'")
[ "$RM" = 2 ] && [ "$LS" = 0 ] && [ "$RW" = 2 ] && [ "$GR" -ge 1 ] && echo "G-G: OK" || bad "G-G: removed $RM, state rows $LS, warnings $RW, the group's removed $GR (want 2, 0, 2, 1+)"

echo "--- G-H the rights and the doors"
run nr mssql_instance; run nr mssql_georepl; run conn mssql_instance; run conn mssql_georepl
run noaz mssql_instance; run noaz mssql_failover_groups; run deny mssql_instance; run deny mssql_failover_groups
NR=$(status nr mssql_georepl); CN=$(status conn mssql_georepl); NA=$(status noaz mssql_failover_groups); DN=$(status deny mssql_failover_groups)
echo "  CONNECT only: $NR"; echo "  pgv_conn (one trial): $CN"; echo "  no azure: block: $NA"; echo "  a server that does not exist (404): $DN"
[[ $NR == "skipped|the login lacks VIEW DATABASE STATE"* ]] || bad "G-H: the CONNECT-only user's mssql_georepl is '$NR'"
[[ $NA == "skipped|no azure: block"* ]] || bad "G-H: no azure: block gives '$NA'"
[[ $DN == error*"Resource Manager answered 404"* ]] || bad "G-H: a server that does not exist gives '$DN' (want Resource Manager's 404 with its code, stored, no crash)"
NOTPROVEN+=("G-H: a 403 for an identity without failoverGroups/read, and the docs' read-only custom role: every G2 read runs on the laptop's own az sign-in, and no identity of the lab's own is made in the tenant (a Go case covers the 403's words)")

echo "=== NOT PROVEN: Managed Instance (a second instance), a SUSPENDED link (no way to make one), several secondaries (preview), the usgov / china clouds (no lab)${NOTPROVEN:+; }${NOTPROVEN[*]:-}"
if [ ${#FAILS[@]} -eq 0 ]; then echo "=== proof-mssql-georepl: PASS"; else printf '=== proof-mssql-georepl: FAIL (%s)\n' "${#FAILS[@]}"; printf '  %s\n' "${FAILS[@]}"; exit 1; fi
