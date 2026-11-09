#!/usr/bin/env bash
# Proof of the versions collection (0035), the release table (internal/versions) and the version findings.
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN). The proof makes its own
#               repository database, a target database and a pg_monitor-only login with a random suffix and drops
#               them at the end; nothing that exists before the run is touched.
#   LAB=1       also run section E against the AWS lab's Aurora cluster (AWS_PROFILE default dba-lab, CLUSTER default
#               dba-lab-pg; IAM authentication, needs an active `aws login --profile <profile>`); read only there.
#
# Expected (written before the first run):
#  A. collect -once versions as the pg_monitor-only login: one instance_versions row with server_version_num =
#     the sandbox's (current_setting), server_version the same as the server's, version_string = version(),
#     postmaster_start = pg_postmaster_start_time(); a database_collations row for the target database (PostgreSQL
#     15+; on the C locale both versions NULL); no version_history row (first read); the collection status ok;
#     version_findings has no row for the instance
#  B. a seeded older read imported before a second collect (18.2 / 'PostgreSQL 18.2 ...' with an older
#     postmaster start) -> the second collect writes exactly one history row: patch|18.2|<server_version>, its
#     applied_at = the server's postmaster start; then a seeded read of the same number with a different version()
#     text -> one 'rebuild' row; versions_fleet shows last_change rebuild
#  C. seeded on a scratch instance: collations app (2.36 -> 2.39), same (2.39 = 2.39), cdb (NULL, C locale);
#     pending maintenance system-update forced in 7 days and os-upgrade auto-applied after 60 days; AWS engine
#     aurora-postgresql 16.4 with targets 16.6 (minor) and 17.4 (major) ->
#       version_findings exactly: collation version|warning|app: 2.36 -> 2.39,
#                                 pending maintenance|info|os-upgrade on db-1, pending maintenance|warning|system-update on cluster-1
#       versions_fleet: pending_actions 2, upgrade_targets '16.6, 17.4', collation_mismatches 1
#     [after the lab run (E listed two undated actions and no finding): an undated action is an info finding too;
#      x's third import adds an undated db-upgrade -> pending maintenance|info|db-upgrade on db-1 joins the findings]
#     a second import with no aws_read row (an AWS error) keeps the targets and both actions; a third, complete,
#     without os-upgrade marks it is_present false (with the undated db-upgrade the fleet's pending_actions stays 2); engine 16.4 -> 16.6
#     writes an 'engine version' history row
#  D. the release table (a throwaway program against internal/versions at 2026-11-09):
#       18.6 -> latest 6, behind 0, EOL 2030-11-14, released 88 days ago (2026-08-13)
#       18.2 -> behind 3 (18.3, 18.4, 18.6: 18.5 was never released)
#       14.10 -> behind 14, EOL 2026-11-12, not passed, 0 months
#       13.5 -> EOL passed, behind 18, release date unknown
#       18.7 -> newer than the table;  9.6 (90624) -> not known
#  [review 1 fold, expected before the rerun:]
#  A2. on PostgreSQL 15+ a second target database created with the ICU provider (icu_locale en-US): its collation row
#      reads provider i, locale en-US (the ICU locale, not datcollate), recorded_version not NULL and = actual_version
#  B2. an Aurora patch (aurora_version 16.4.2 -> 16.4.3, the number unchanged) writes 'aurora patch', not 'rebuild';
#      a major upgrade with an engine change at the same read leaves last_change = 'major upgrade' (the tie-break)
#  C2. an aws_engine row with status deprecated -> version_findings adds engine version|warning|16.4 deprecated
#  D2. Lookup at 2026-11-11 23:00 PST (2026-11-12 07:00 UTC) for 14.10: passed true and months 0 (both read the UTC
#      date); at 2026-11-11 12:00 UTC: passed false, months 0
#  E. (LAB=1) the Aurora cluster: platform aurora, engine aurora-postgresql, an engine_version 17.x, aurora_version
#     set, aws_read_at set, at least one upgrade target, the pending maintenance rows listed (zero is a valid
#     answer: printed), no collector_error (status ok)
#  [run 1 graded: the row matched; the check compared a boolean concatenated into text with 't', which renders
#   'true': the four checks that concatenate a boolean now compare with 'true'.
#   Run 2 graded: B's seed lands after run 1's real read, so the import rightly records it as a downgrade
#   (<server_version> -> 18.2, applied at the seeded start) before the patch row; B expects both rows]
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
SUF=$RANDOM
REPO_DB=pgvigil_verproof_$SUF; T1=pgvigil_ver1_$SUF; T2=pgvigil_ver2_$SUF; MON=pgvigil_vermon_$SUF; MONPW=p$RANDOM$RANDOM
dsn_for() { echo "$ADMIN_DSN dbname=$1"; }   # a later keyword wins, in libpq and in pgx
CFG=$(mktemp); CHK=scripts/tmp-proof-versions-$SUF
cleanup() {
  rm -f "$CFG"; rm -rf "$CHK"
  for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in "$REPO_DB" "$T1"; do psql "$ADMIN_DSN" -XAtq -c "create database $d" >/dev/null; done
psql "$ADMIN_DSN" -XAtq -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN=$(dsn_for "$REPO_DB")
export TGT_DSN; TGT_DSN="$(dsn_for "$T1") user=$MON password=$MONPW"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t1() { psql "$(dsn_for "$T1")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- A. first read"
if (( $(t1 "select current_setting('server_version_num')") >= 150000 )); then
  psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create database $T2 template template0 locale_provider icu icu_locale 'en-US'" >/dev/null
fi
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-ver-$SUF
    dsn: env:TGT_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once versions || fail "collect versions (run 1)"
iid=$(q "select instance_id from pgvigil.instances where name='proof-ver-$SUF'")
[[ $(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='versions'") == ok ]] \
  || fail "status: $(q "select status, note from pgvigil.collection_dates where instance_id=$iid and collection='versions'")"
NUM=$(t1 "select current_setting('server_version_num')"); SV=$(t1 "select current_setting('server_version')")
VS=$(t1 "select version()"); PMS=$(t1 "select pg_postmaster_start_time()")
row=$(q "select server_version_num || '|' || server_version || '|' || (version_string = \$\$$VS\$\$) || '|' || (postmaster_start = '$PMS')
           from pgvigil.instance_versions where instance_id=$iid")
[[ $row == "$NUM|$SV|true|true" ]] || fail "instance_versions: $row (want $NUM|$SV|true|true)"
echo "row: $(q "select server_version_num, server_version, postmaster_start, version_string from pgvigil.instance_versions where instance_id=$iid")"
if (( NUM >= 150000 )); then
  [[ $(q "select count(*) from pgvigil.database_collations where instance_id=$iid and datname='$T1' and is_present") == 1 ]] || fail "no collation row for $T1"
  echo "collations: $(q "select string_agg(datname || ' ' || provider || ' ' || coalesce(recorded_version, 'null') || '/' || coalesce(actual_version, 'null'), ', ') from pgvigil.database_collations where instance_id=$iid and datname='$T1'")"
fi
if (( NUM >= 150000 )); then
  c2=$(q "select provider || '|' || locale || '|' || (recorded_version is not null and recorded_version = actual_version) from pgvigil.database_collations where instance_id=$iid and datname='$T2'")
  [[ $c2 == "i|en-US|true" ]] || fail "ICU collation row: $c2"
  echo "ICU database: $(q "select provider, locale, recorded_version, actual_version from pgvigil.database_collations where instance_id=$iid and datname='$T2'")"
fi
[[ $(q "select count(*) from pgvigil.version_history where instance_id=$iid") == 0 ]] || fail "history on the first read"
[[ $(q "select count(*) from pgvigil.version_findings where instance_id=$iid") == 0 ]] || fail "findings: $(q "select * from pgvigil.version_findings where instance_id=$iid")"

echo "--- B. a seeded old version string, then the real one"
q "select pgvigil.import_versions($iid, now() - interval '1 hour',
     '[{\"kind\":\"server\",\"server_version_num\":180002,\"server_version\":\"18.2\",\"version_string\":\"PostgreSQL 18.2 on x86_64-pc-linux-gnu\",\"postmaster_start\":\"2026-03-01T00:00:00Z\"}]')" >/dev/null
"$BIN" collect -config "$CFG" -once versions || fail "collect versions (run 2)"
h=$(q "select string_agg(change || '|' || old_value || '|' || new_value || '|' || (applied_at = '$PMS'), E'\n' order by changed_at) from pgvigil.version_history where instance_id=$iid")
want=$(printf '%s\n' "downgrade|$SV|18.2|false" "patch|18.2|$SV|true")
[[ "$h" == "$want" ]] || fail "history after the patch: got
$h
want
$want"
echo "history: $h"
q "select pgvigil.import_versions($iid, now() + interval '1 minute',
     '[{\"kind\":\"server\",\"server_version_num\":$NUM,\"server_version\":\"$SV\",\"version_string\":\"PostgreSQL $SV (rebuilt)\",\"postmaster_start\":\"$PMS\"}]')" >/dev/null
[[ $(q "select count(*) from pgvigil.version_history where instance_id=$iid and change='rebuild'") == 1 ]] || fail "no rebuild row"
[[ $(q "select last_change from pgvigil.versions_fleet where instance_id=$iid") == rebuild ]] || fail "fleet last_change: $(q "select last_change from pgvigil.versions_fleet where instance_id=$iid")"

echo "--- C. seeded collations, maintenance and the AWS side"
ix=$(q "select pgvigil.ensure_instance('proof-ver-x-$SUF', 'aurora', '16.4', 160004, false, '{}')")
F7=$(q "select to_json(now() + interval '7 days')#>>'{}'"); A60=$(q "select to_json(now() + interval '60 days')#>>'{}'")
base='{"kind":"server","server_version_num":160004,"server_version":"16.4","version_string":"PostgreSQL 16.4","aurora_version":"16.4.2","postmaster_start":"2026-10-01T00:00:00Z"},
      {"kind":"collation","dbid":1,"datname":"app","provider":"c","locale":"en_US.UTF-8","recorded_version":"2.36","actual_version":"2.39"},
      {"kind":"collation","dbid":2,"datname":"same","provider":"c","locale":"en_US.UTF-8","recorded_version":"2.39","actual_version":"2.39"},
      {"kind":"collation","dbid":3,"datname":"cdb","provider":"c","locale":"C","recorded_version":null,"actual_version":null}'
eng='{"kind":"aws_engine","resource":"cluster:cluster-1","engine":"aurora-postgresql","engine_version":"ENGV","auto_minor_version_upgrade":null,"maintenance_window":"sun:05:00-sun:05:30","members":["db-1"]},
     {"kind":"aws_instance","id":"db-1","class":"db.serverless","engine_version":"ENGV","auto_minor_version_upgrade":true,"maintenance_window":"sun:05:00-sun:05:30","is_writer":true},
     {"kind":"aws_target","engine_version":"17.4","is_major":true,"description":"Aurora PostgreSQL 17.4","auto_upgrade":false},
     {"kind":"aws_target","engine_version":"16.6","is_major":false,"description":"Aurora PostgreSQL 16.6","auto_upgrade":false}'
sysup='{"kind":"aws_pending","resource":"arn:aws:rds:us-east-2:000000000000:cluster:cluster-1","action":"system-update","description":"New operating system update is available","forced_apply":"'$F7'"}'
osup='{"kind":"aws_pending","resource":"arn:aws:rds:us-east-2:000000000000:db:db-1","action":"os-upgrade","description":"OS upgrade","auto_applied_after":"'$A60'"}'
impx() { q "select pgvigil.import_versions($ix, now() + make_interval(secs => $1), '[$2]')" >/dev/null; }
impx 0 "$base, ${eng//ENGV/16.4}, $sysup, $osup, {\"kind\":\"aws_read\"}"
f=$(q "select string_agg(setting || '|' || severity || '|' || value, E'\n' order by setting, value) from pgvigil.version_findings where instance_id=$ix")
want=$(printf '%s\n' "collation version|warning|app: 2.36 -> 2.39" "pending maintenance|info|os-upgrade on db-1" "pending maintenance|warning|system-update on cluster-1")
[[ "$f" == "$want" ]] || fail "findings x: got
$f
want
$want"
echo "findings x:"; echo "$f"
fl() { q "select pending_actions || '|' || upgrade_targets || '|' || collation_mismatches || '|' || auto_minor_version_upgrade from pgvigil.versions_fleet where instance_id=$ix"; }
[[ $(fl) == "2|16.6, 17.4|1|true" ]] || fail "fleet x: $(fl)"
impx 60 "$base"                                         # the AWS side failed: no aws_read row
[[ $(q "select count(*) from pgvigil.version_upgrade_targets where instance_id=$ix") == 2 && $(q "select count(*) from pgvigil.version_pending where instance_id=$ix and is_present") == 2 ]] \
  || fail "an AWS error dropped the AWS rows"
undated='{"kind":"aws_pending","resource":"arn:aws:rds:us-east-2:000000000000:db:db-1","action":"db-upgrade","description":"minor upgrade"}'
impx 120 "$base, ${eng//ENGV/16.6}, $sysup, $undated, {\"kind\":\"aws_read\"}"
[[ $(q "select severity || '|' || suggested from pgvigil.version_findings where instance_id=$ix and value='db-upgrade on db-1'") == "info|apply it in a planned window (no date set: AWS does not apply it on its own yet)" ]] \
  || fail "undated action: $(q "select severity, suggested from pgvigil.version_findings where instance_id=$ix and value='db-upgrade on db-1'"); pending: $(q "select action, resource, is_present from pgvigil.version_pending where instance_id=$ix"); findings: $(q "select severity, value from pgvigil.version_findings where instance_id=$ix")"
[[ $(q "select is_present from pgvigil.version_pending where instance_id=$ix and action='os-upgrade'") == f ]] || fail "os-upgrade still pending"
[[ $(fl) == "2|16.6, 17.4|1|true" ]] || fail "fleet x after: $(fl)"
[[ $(q "select change || '|' || old_value || '|' || new_value from pgvigil.version_history where instance_id=$ix") == "engine version|16.4|16.6" ]] \
  || fail "engine history: $(q "select change, old_value, new_value from pgvigil.version_history where instance_id=$ix")"
echo "fleet x: $(fl); engine history 16.4 -> 16.6"

echo "--- B2/C2. an Aurora patch, a major upgrade with its engine change, a deprecated engine version"
ia=$(q "select pgvigil.ensure_instance('proof-ver-a-$SUF', 'aurora', '16.4', 160004, false, '{}')")
srv() { echo '{"kind":"server","server_version_num":'$1',"server_version":"'$2'","version_string":"PostgreSQL '$2'","aurora_version":"'$3'","postmaster_start":"2026-10-01T00:00:00Z"}'; }
aeng() { echo '{"kind":"aws_engine","resource":"cluster:a","engine":"aurora-postgresql","engine_version":"'$1'","engine_status":"'$2'","auto_minor_version_upgrade":true},{"kind":"aws_read"}'; }
impa() { q "select pgvigil.import_versions($ia, now() + make_interval(secs => $1), '[$2]')" >/dev/null; }
impa 0 "$(srv 160004 16.4 16.4.2), $(aeng 16.4 deprecated)"
impa 60 "$(srv 160004 16.4 16.4.3), $(aeng 16.4 deprecated)"
[[ $(q "select string_agg(change || '|' || old_value || '|' || new_value, ',') from pgvigil.version_history where instance_id=$ia") == "aurora patch|16.4.2|16.4.3" ]] \
  || fail "aurora patch: $(q "select change, old_value, new_value from pgvigil.version_history where instance_id=$ia")"
[[ $(q "select string_agg(setting || '|' || severity || '|' || value, ',') from pgvigil.version_findings where instance_id=$ia") == "engine version|warning|16.4 deprecated" ]] \
  || fail "deprecated finding: $(q "select setting, severity, value from pgvigil.version_findings where instance_id=$ia")"
impa 120 "$(srv 170004 17.4 17.4.1), $(aeng 17.4 available)"
[[ $(q "select last_change from pgvigil.versions_fleet where instance_id=$ia") == "major upgrade" ]] || fail "tie-break: $(q "select last_change from pgvigil.versions_fleet where instance_id=$ia")"
[[ $(q "select count(*) from pgvigil.version_findings where instance_id=$ia") == 0 ]] || fail "deprecated finding stays after the upgrade"
echo "aurora: $(q "select string_agg(change || ' ' || coalesce(old_value, '') || ' -> ' || coalesce(new_value, ''), '; ' order by changed_at, change) from pgvigil.version_history where instance_id=$ia"); last_change major upgrade"

echo "--- D. the release table"
mkdir -p "$CHK"
cat > "$CHK/main.go" <<'EOF'
package main

import (
	"fmt"
	"time"

	"github.com/aachaemenes/pgvigil/internal/versions"
)

func main() {
	now := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	for _, n := range []int{180006, 180002, 140010, 130005, 180007, 90624} {
		s := versions.Lookup(n, now)
		fmt.Printf("%d known=%v latest=%d behind=%d newer=%v eol=%s passed=%v months=%d days=%d\n", n, s.Known, s.Latest, s.BehindBy, s.Newer,
			s.EOL.Format("2006-01-02"), s.EOLPassed, s.EOLInMonths, s.ReleasedDaysAgo)
	}
	pst := time.FixedZone("PST", -8*3600)
	for _, at := range []time.Time{time.Date(2026, 11, 11, 23, 0, 0, 0, pst), time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)} {
		s := versions.Lookup(140010, at)
		fmt.Printf("140010 at %s passed=%v months=%d\n", at.UTC().Format(time.RFC3339), s.EOLPassed, s.EOLInMonths)
	}
}
EOF
got=$(go run "./$CHK")
want="180006 known=true latest=6 behind=0 newer=false eol=2030-11-14 passed=false months=48 days=88
180002 known=true latest=6 behind=3 newer=false eol=2030-11-14 passed=false months=48 days=270
140010 known=true latest=24 behind=14 newer=false eol=2026-11-12 passed=false months=0 days=1096
130005 known=true latest=23 behind=18 newer=false eol=2025-11-13 passed=true months=-11 days=-1
180007 known=true latest=6 behind=0 newer=true eol=2030-11-14 passed=false months=48 days=-1
90624 known=false latest=0 behind=0 newer=false eol=0001-01-01 passed=false months=0 days=-1
140010 at 2026-11-12T07:00:00Z passed=true months=0
140010 at 2026-11-11T12:00:00Z passed=false months=0"
[[ "$got" == "$want" ]] || fail "release table: got
$got
want
$want"
echo "$got"

if [[ ${LAB:-0} == 1 ]]; then
  echo "--- E. the lab's Aurora cluster"
  PROFILE=${AWS_PROFILE:-dba-lab}; CLUSTER=${CLUSTER:-dba-lab-pg}; DBUSER=${DBUSER:-postgres}
  REGION=$(aws configure get region --profile "$PROFILE")
  H=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].Endpoint' --output text --profile "$PROFILE")
  [[ -n "$H" && "$H" != None ]] || fail "no writer endpoint for $CLUSTER"
  TOKEN=$(aws rds generate-db-auth-token --hostname "$H" --port 5432 --username "$DBUSER" --profile "$PROFILE")
  export AURORA_DSN="host=$H port=5432 user=$DBUSER dbname=postgres sslmode=require password=$TOKEN"
  cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: lab-aurora-ver-$SUF
    dsn: env:AURORA_DSN
    aws:
      region: $REGION
      profile: $PROFILE
      cluster: $CLUSTER
EOF
  "$BIN" collect -config "$CFG" -once versions || fail "collect versions (lab)"
  il=$(q "select instance_id from pgvigil.instances where name='lab-aurora-ver-$SUF'")
  st=$(q "select status || coalesce(' (' || note || ')', '') from pgvigil.collection_dates where instance_id=$il and collection='versions'")
  [[ $st == ok ]] || fail "lab status: $st"
  r=$(q "select i.platform || '|' || v.engine || '|' || v.engine_version || '|' || (v.aurora_version is not null) || '|' || (v.aws_read_at is not null)
           from pgvigil.instance_versions v join pgvigil.instances i using (instance_id) where v.instance_id=$il")
  [[ $r == aurora\|aurora-postgresql\|17.*\|true\|true ]] || fail "lab row: $r"
  echo "lab: $(q "select server_version, aurora_version, engine_version, auto_minor_version_upgrade, maintenance_window from pgvigil.instance_versions where instance_id=$il")"
  nt=$(q "select count(*) from pgvigil.version_upgrade_targets where instance_id=$il")
  (( nt >= 1 )) || fail "no upgrade target"
  echo "upgrade targets ($nt):"; q "select engine_version, is_major from pgvigil.version_upgrade_targets where instance_id=$il order by is_major, engine_version"
  echo "pending maintenance ($(q "select count(*) from pgvigil.version_pending where instance_id=$il")):"
  q "select resource, action, auto_applied_after, forced_apply, current_apply, description from pgvigil.version_pending where instance_id=$il"
  echo "members: $(q "select aws_members from pgvigil.instance_versions where instance_id=$il")"
fi
echo "PASS proof-versions"
