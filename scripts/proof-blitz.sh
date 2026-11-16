#!/usr/bin/env bash
# Proof of B20-2, the stored weekly sp_Blitz (collection mssql_blitz: internal/mssql/blitz.go; migration
# 0273_long_range_reports.sql's mssql_blitz_* tables and functions; internal/web/q_blitz.go; web/src/blitz.ts, the
# instance Findings tab's 'sp_Blitz weekly' section). pgvigil never installs sp_Blitz: the proof installs the First
# Responder Kit itself, in its own SQL Server container, from the file the caller hands it.
#
# Needs: docker, psql, curl, python3, ss, go (without PGVIGIL_BIN); chromium and node for part P (PGVIGIL_SKIP_PAGES=1
# leaves P out, said in a NOT PROVEN line), and
#   PGVIGIL_ADMIN_DSN       a superuser connection to a PostgreSQL in KEYWORD form, no dbname, no password in it.
#   PGVIGIL_COMMUNITY_DIR   a folder holding frk-install-all.sql (the First Responder Kit's Install-All-Scripts.sql).
#                           This script fetches nothing.
#   MSSQL_IMAGE             default mcr.microsoft.com/mssql/server:2022-latest.
# What it makes, removed on every exit the shell can catch: the container pgv-bz-mssql-<n> (a throwaway sa password,
# never printed), the repository database pgvigil_bz_<n>, a serve on a free loopback port, a headless Chromium.
#
# Expected (written before the first run; job B's numbers, design lines 37 / 58 / 62 / 66):
#  B0 (the setup, on any tree): the kit installs; as the monitoring login L1 (VIEW SERVER STATE, VIEW ANY DEFINITION,
#     CONNECT ANY DATABASE, EXECUTE on master.dbo.sp_Blitz only) sp_Blitz @OutputType = 'COUNT' answers a number n
#     over 0 and @OutputType = 'RSV' prints n rows; a mismatch is the proof's own parse and stops it.
#  S  migrate holds the B20-2 store: pgvigil.mssql_blitz_site (one row, off), mssql_blitz_setting, mssql_blitz_run,
#     mssql_blitz_finding, mssql_blitz_due(int, timestamptz), import_mssql_blitz(int, timestamptz, jsonb). RED ON THE
#     BASE: 'FAIL: S: ...' and the proof stops (exit 1) - nothing below runs there.
#  W  the switch's route POST /api/mssql/blitz/settings: an operator and a viewer get 403 'changing the weekly
#     sp_Blitz needs the admin role' and nothing is written; the admin writes (200 'done', an admin_audit row
#     op mssql_blitz_instance outcome done); run_hour 25 and the zone 'Mars/Olympus' are 409 refused with words, an
#     admin_audit row each outcome refused, the site row unchanged.
#  G  off by default: a fresh instance's state is 'off' with the words 'the site default is off'; collect -once
#     mssql_blitz says skipped with those words and stores no run; its collection_dates note holds them. The site
#     default on: an instance with no row of its own is 'due' and runs; its own switch off wins over the site's on
#     ('its own switch'); the site default back off: the instance with no row is 'off' again.
#  A  (L1, its switch on) a due run: collect exits 0; ONE run stored, outcome 'done with messages' (job B: Msg 229, no
#     EXECUTE on master.dbo.sp_BlitzBackups, is among its messages), frk_version and frk_version_date as the kit
#     file's sp_Blitz says, login L1, proc_db master, seconds over 0, findings = its finding rows; then, as L1 at once,
#     sp_Blitz's own COUNT equals the stored count, and the stored FindingsGroups and CheckIDs equal RSV's (as
#     multisets).
#  H  a second collect in the same week: skipped 'not due yet', still one run; the state 'not due' names the next time.
#  C  sa (a sysadmin; the collector does not refuse one): 'done with messages' (job B: Msg 8134, divide by zero, even
#     as sa) and its findings = sa's own COUNT.
#  D  L2 (EXECUTE on sp_Blitz, no VIEW SERVER STATE): a run stored 'refused', its error 'The user L2 does not have VIEW
#     SERVER STATE permissions.', no finding; collect says partial with that message.
#  E  L3 (VIEW SERVER STATE, VIEW ANY DEFINITION, no EXECUTE): skipped 'no EXECUTE on [master].[dbo].[sp_Blitz] for
#     the login L3', no run stored, the state's 'last' note the same words.
#  F  sp_Blitz's database set to an empty database: skipped 'sp_Blitz is not in [<db>].[dbo]', no run; set to a
#     database that does not exist: skipped 'no database <db> on this server', no run.
#  I  the site timeout 1 s: a run stored 'timed out', its error naming the 1 s timeout, no finding; collect says
#     partial; the timeout back to 600 s.
#  J  13 runs leave 12: 11 older runs seeded into the store, run A's moved back a week, a real run: 12 runs left, the
#     oldest gone; then 12 newer failed runs (11 seeded, one real: the 1 s timeout) keep the
#     newest successful run and its findings (13 rows: the newest 12 plus it).
#  K  GET /api/mssql/blitz?instance=N: the parts state, last, runs, shown, findings, judged; 'shown' is the newest
#     successful run with the newest run's outcome beside it ('timed out' after J); its findings = the stored rows;
#     judged holds 12, 13, 14 and 1001 (rules the Checks tab judges) and a finding is judged exactly when its CheckID is
#     in that list; the state 'not due' (the timed-out run is this week's).
#  M  import_mssql_blitz refuses a PostgreSQL instance; the same payload twice stores one run.
#  P  the page (admin): #/findings?i=N has the section 'sp_Blitz weekly'; one folding group per FindingsGroup of the
#     shown run plus All, each summary naming its group and count; every http(s) URL cell a link; a judged CheckID a
#     link to the instance's Checks tab; the database filter lists every DatabaseName of the run. As the viewer: the
#     instance's Save is off (aria-disabled) and the page says 'changing the weekly sp_Blitz needs the admin role'.
#  The last line 'PASS proof-blitz (W G A H C D E F I J K M P)' and exit 0; any row's FAIL prints and the end is
#  'FAIL: proof-blitz: <n> row(s)' and exit 1.
#  NOT PROVEN HERE: a busy instance's run time and a real week passing (the store's runs are moved back instead),
#  Azure SQL Managed Instance, Amazon RDS (sp_Blitz in a user database there: F's setting is the path), Windows.
set -uo pipefail
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
: "${PGVIGIL_COMMUNITY_DIR:?a folder holding frk-install-all.sql}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FRK=$PGVIGIL_COMMUNITY_DIR/frk-install-all.sql
SUF=$RANDOM$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; OUT=$WORK/out
REPO_DB=pgvigil_bz_$SUF; CT=pgv-bz-mssql-$SUF
L1=pgv_bz_mon_$SUF; L2=pgv_bz_novss_$SUF; L3=pgv_bz_noexec_$SUF
DBE=pgvbz_empty_$SUF
N=bz-mon-$SUF; NV=bz-novss-$SUF; NX=bz-noexec-$SUF; NS=bz-sa-$SUF; NI=bz-inst-$SUF; NT=bz-time-$SUF; NZ=bz-site-$SUF
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
P1=$(pw); P2=$(pw); P3=$(pw)
FAILS=0; ROWS=""
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL: $*"; exit 1; }
row() { ROWS+=" $1"; }
freeport() { local l p; l=$(ss -ltn); for p in $(seq "$1" "$2"); do grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$p " <<<"$l" || { echo "$p"; return; }; done; return 1; }
MADE_REPO=; MADE_CT=; SRV=; CHR=
cleanup() {
  rc=$?
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true
  [ -n "$CHR" ] && kill "$CHR" 2>/dev/null || true
  wait 2>/dev/null || true
  [ -n "$MADE_CT" ] && { docker rm -f -v "$CT" >/dev/null 2>&1 || echo "CLEANUP: container $CT not removed" >&2; }
  [ -n "$MADE_REPO" ] && { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; }
  rm -rf "$WORK" || true
  exit $rc
}
trap cleanup EXIT
for t in docker psql curl python3 ss; do command -v $t >/dev/null || die "$t is not on this machine"; done
[[ -s $FRK ]] || die "no $FRK (the First Responder Kit's Install-All-Scripts.sql): this proof fetches nothing"
# sp_Blitz's own version lines in the kit file (the first after its ALTER PROCEDURE)
FRKV=$(awk '/ALTER PROCEDURE \[dbo\]\.\[sp_Blitz\][[:space:]]*$/ {f = 1} f && /SELECT @Version = / {print; exit}' "$FRK" | tr -d '\r')
FRKD=$(grep -oE "@VersionDate = '[0-9]{8}'" <<<"$FRKV" | grep -oE '[0-9]{8}'); FRKV=$(grep -oE "@Version = '[0-9.]+'" <<<"$FRKV" | grep -oE "[0-9][0-9.]*")
[[ -n $FRKV && -n $FRKD ]] || die "the kit file's sp_Blitz version line was not found"
echo "container $CT, repository $REPO_DB; the kit's sp_Blitz $FRKV ($FRKD)"

BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  command -v go >/dev/null || die "go is not on this machine and PGVIGIL_BIN names no binary"
  BIN=$WORK/pgvigil; (cd "$ROOT" && CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil) || die "the build"
fi

echo "--- B0. the SQL Server, the kit, the logins"
MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MPORT=$(freeport 22500 22599) || die "no free port for the SQL Server container"
ADDR=127.0.0.1:$MPORT; MADE_CT=1
docker run -d --name "$CT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -e MSSQL_PID=Developer -p "127.0.0.1:$MPORT:1433" \
  "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || die "docker run of the SQL Server container"
# sq <sql> [database]: as sa; a failure prints sqlcmd's output to stderr
sq() {
  local o
  o=$(docker exec -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -s '|' -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1" 2>&1) || { printf 'sqlcmd failed: %s\n' "$o" >&2; return 1; }
  [ -z "$o" ] || printf '%s\n' "$o"
}
# as <login> <password> <sql>: the call as that login (-y 0: whole values; -y and -W do not go together)
as() { docker exec -e SQLCMDPASSWORD="$2" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -I -y 0 -h -1 -U "$1" -d master -Q "SET NOCOUNT ON; $3" 2>&1; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null || die "the SQL Server in $CT does not answer"
echo "  $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40))")"
docker exec -i -e SQLCMDPASSWORD "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -d master -i /dev/stdin < "$FRK" > "$WORK/frk.log" 2>&1 \
  || die "the kit's install: $(tail -3 "$WORK/frk.log")"
[[ $(sq "SELECT CASE WHEN OBJECT_ID('master.dbo.sp_Blitz') IS NULL THEN 'missing' ELSE 'installed' END") == installed ]] || die "B0: sp_Blitz is not in master after the kit's install"
sq "CREATE LOGIN [$L1] WITH PASSWORD = N'$P1', CHECK_POLICY = OFF; CREATE LOGIN [$L2] WITH PASSWORD = N'$P2', CHECK_POLICY = OFF; CREATE LOGIN [$L3] WITH PASSWORD = N'$P3', CHECK_POLICY = OFF;
GRANT VIEW SERVER STATE TO [$L1]; GRANT VIEW ANY DEFINITION TO [$L1]; GRANT CONNECT ANY DATABASE TO [$L1];
GRANT VIEW SERVER STATE TO [$L3]; GRANT VIEW ANY DEFINITION TO [$L3]; GRANT CONNECT ANY DATABASE TO [$L3];
CREATE USER [$L1] FOR LOGIN [$L1]; CREATE USER [$L2] FOR LOGIN [$L2]; GRANT EXECUTE ON dbo.sp_Blitz TO [$L1]; GRANT EXECUTE ON dbo.sp_Blitz TO [$L2];
CREATE DATABASE [$DBE];" >/dev/null || die "B0: the logins"
CALL="EXEC dbo.sp_Blitz @CheckServerInfo = 1, @CheckUserDatabaseObjects = 0"
blitzCount() { as "$1" "$2" "$CALL, @OutputType = 'COUNT';" | grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' | tail -1 | tr -d ' \r'; }
# RSV: one line per finding, CHAR(31) between Priority, CheckID, FindingsGroup, Finding, DatabaseName, URL, Details (a
# Details with a line break goes on below its line: only the lines that open with two numbers are rows)
blitzRSV() { as "$1" "$2" "$CALL, @OutputType = 'RSV';" | tr -d '\r' | grep -aE $'^[0-9]+\x1f[0-9]+\x1f'; }
B0N=$(blitzCount "$L1" "$P1"); B0R=$(blitzRSV "$L1" "$P1" | wc -l)
[[ $B0N =~ ^[0-9]+$ && $B0N -gt 0 && $B0N == "$B0R" ]] || die "B0: as $L1 COUNT '$B0N' and RSV $B0R rows disagree (the proof's parse)"
echo "B0: OK (as the monitoring login sp_Blitz counts $B0N findings, RSV prints $B0R rows)"

echo "--- S. the store"
adm() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB" >/dev/null || die "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
mon() { echo "sqlserver://$1:$2@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"; }
export MS_L1=$(mon "$L1" "$P1") MS_L2=$(mon "$L2" "$P2") MS_L3=$(mon "$L3" "$P3") MS_SA=$(mon sa "$MSSQL_SA_PASSWORD")
{
  echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  for p in "$N MS_L1" "$NV MS_L2" "$NX MS_L3" "$NS MS_SA" "$NI MS_L1" "$NT MS_L1" "$NZ MS_L1"; do
    set -- $p; printf '  - name: %s\n    engine: sqlserver\n    dsn: env:%s\n' "$1" "$2"
  done
} > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.log" 2>&1 || die "migrate: $(tail -3 "$WORK/migrate.log")"
S=$(q "select (to_regclass('pgvigil.mssql_blitz_site') is not null and to_regclass('pgvigil.mssql_blitz_setting') is not null
          and to_regclass('pgvigil.mssql_blitz_run') is not null and to_regclass('pgvigil.mssql_blitz_finding') is not null
          and to_regprocedure('pgvigil.mssql_blitz_due(int, timestamptz)') is not null
          and to_regprocedure('pgvigil.import_mssql_blitz(int, timestamptz, jsonb)') is not null)::text")
[[ $S == true ]] || die "S: migrate holds no B20-2 store (mssql_blitz_site / _setting / _run / _finding, mssql_blitz_due, import_mssql_blitz)"
[[ $(q "select count(*) || '|' || bool_and(not enabled) from pgvigil.mssql_blitz_site") == "1|true" ]] || die "S: the site row: $(q "select row_to_json(s) from pgvigil.mssql_blitz_site s")"
echo "S: OK (the store; the site row off)"

# the instances' ids: one collect each so the rows exist (an unknown instance is made at its first read)
collect() { "$BIN" collect -config "$CFG" -once mssql_blitz -instance "$1" > "$OUT" 2>&1; local r=$?; cat "$OUT"; return $r; }
for nm in $N $NV $NX $NS $NI $NT $NZ; do collect "$nm" >/dev/null || die "the first collect of $nm: $(cat "$OUT")"; done
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
I=$(iid $N); IV=$(iid $NV); IX=$(iid $NX); IS=$(iid $NS); II=$(iid $NI); IT=$(iid $NT); IZ=$(iid $NZ)
runs() { q "select count(*) from pgvigil.mssql_blitz_run where instance_id = $1"; }
note() { q "select coalesce(status, '') || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id = $1 and collection = 'mssql_blitz'"; }
state() { q "select state || '|' || why from pgvigil.mssql_blitz_due($1)"; }

echo "--- the serve, the users"
PW() { echo "pw-$1-$SUF-long-enough"; }
for who in "bzadmin$SUF admin" "bzop$SUF operator" "bzview$SUF viewer"; do
  set -- $who; PGVIGIL_PASSWORD=$(PW "$1") "$BIN" user add -config "$CFG" -role "$2" "$1" > "$WORK/user.log" 2>&1 || die "user add $1: $(cat "$WORK/user.log")"
done
PORT=$(freeport 18400 18460) || die "no free port for the serve"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
U=http://127.0.0.1:$PORT
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U/" && break; kill -0 "$SRV" 2>/dev/null || die "serve died: $(tail -3 "$WORK/serve.log")"; sleep 0.5; done
curl -sf -o /dev/null "$U/" || die "the serve did not answer: $(tail -5 "$WORK/serve.log")"
login() { curl -s -o "$WORK/login.body" -w '%{http_code}' -c "$WORK/$1.jar" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "{\"username\":\"$1\",\"password\":\"$(PW "$1")\"}" "$U/api/login"; }
for who in bzadmin$SUF bzop$SUF bzview$SUF; do [[ $(login "$who") == 200 ]] || die "the login of $who: $(cat "$WORK/login.body")"; done
# post <user> <json>: the switch's route; the code, the body in $WORK/post.body
post() { curl -s -o "$WORK/post.body" -w '%{http_code}' -b "$WORK/$1.jar" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$2" "$U/api/mssql/blitz/settings"; }
A=bzadmin$SUF
on() { [[ $(post $A "{\"op\":\"instance\",\"instance_id\":$1,\"enabled\":${2:-true}${3:+,\"proc_db\":\"$3\"}}") == 200 ]] || bad "the switch of instance $1: $(cat "$WORK/post.body")"; }
site() { [[ $(post $A "{\"op\":\"site\",$1}") == 200 ]] || bad "the site default ($1): $(cat "$WORK/post.body")"; }

echo "--- W. the switch's route"
aud0=$(q "select count(*) from pgvigil.admin_audit")
for who in bzop$SUF bzview$SUF; do
  c=$(post "$who" "{\"op\":\"instance\",\"instance_id\":$I,\"enabled\":true}")
  [[ $c == 403 && $(cat "$WORK/post.body") == *"changing the weekly sp_Blitz needs the admin role"* ]] && ok "W: $who refused 403 in the admin words" || bad "W: $who: $c $(cat "$WORK/post.body")"
done
[[ $(q "select count(*) from pgvigil.mssql_blitz_setting") == 0 && $(q "select count(*) from pgvigil.admin_audit") == "$aud0" ]] && ok "W: the refused writes wrote nothing" || bad "W: a refused write wrote a row"
c=$(post $A '{"op":"site","run_hour":25}'); [[ $c == 409 && $(cat "$WORK/post.body") == *hour* ]] && ok "W: run_hour 25 refused 409 ($(cat "$WORK/post.body"))" || bad "W: run_hour 25: $c $(cat "$WORK/post.body")"
c=$(post $A '{"op":"site","run_tz":"Mars/Olympus"}'); [[ $c == 409 && $(cat "$WORK/post.body") == *"time zone"* ]] && ok "W: the zone Mars/Olympus refused 409" || bad "W: the zone: $c $(cat "$WORK/post.body")"
[[ $(q "select run_hour || '|' || run_tz from pgvigil.mssql_blitz_site") == "2|UTC" && $(q "select count(*) from pgvigil.admin_audit where op = 'mssql_blitz_site' and outcome = 'refused'") == 2 ]] \
  && ok "W: the site row unchanged, both refusals audited" || bad "W: after the refusals: site $(q "select row_to_json(s) from pgvigil.mssql_blitz_site s"), audit $(q "select count(*) from pgvigil.admin_audit where op = 'mssql_blitz_site'")"
row W

echo "--- G. off by default, the site default"
st=$(state "$I"); collect "$N" >/dev/null
[[ $st == "off|"*"the site default is off"* ]] && ok "G: a fresh instance is off ($st)" || bad "G: the fresh state: $st"
[[ $(cat "$OUT") == *"skipped: "*"the site default is off"* && $(runs "$I") == 0 && $(note "$I") == "skipped|"*"the site default is off"* ]] && ok "G: collect skipped in the off words, no run, the note kept" || bad "G: $(cat "$OUT") runs $(runs "$I") note $(note "$I")"
site '"enabled":true'
[[ $(state "$IZ") == "due|"* ]] && ok "G: the site default on: an instance with no row of its own is due" || bad "G: site on, no row: $(state "$IZ")"
collect "$NZ" >/dev/null; [[ $(runs "$IZ") == 1 ]] && ok "G: it ran ($(q "select outcome from pgvigil.mssql_blitz_run where instance_id = $IZ"))" || bad "G: no run under the site default: $(cat "$OUT")"
on "$IZ" false
[[ $(state "$IZ") == "off|"*"its own switch"* ]] && ok "G: its own switch off wins over the site's on" || bad "G: own off, site on: $(state "$IZ")"
[[ $(post $A "{\"op\":\"instance\",\"instance_id\":$IZ,\"enabled\":null}") == 200 ]] || bad "G: back to the site default: $(cat "$WORK/post.body")"
site '"enabled":false'
[[ $(state "$IZ") == "off|"*"the site default is off"* ]] && ok "G: the site default off again: off" || bad "G: site off again: $(state "$IZ")"
row G

echo "--- A. a due run as the monitoring login"
on "$I"
[[ $(q "select count(*) from pgvigil.admin_audit where op = 'mssql_blitz_instance' and outcome = 'done' and ui_user = '$A'") -ge 1 ]] && ok "W: the admin's switch audited (done)" || bad "W: no done audit row for the admin's switch"
[[ $(q "select coalesce(enabled::text, 'null') || '|' || updated_by from pgvigil.mssql_blitz_setting where instance_id = $I") == "true|$A" ]] || bad "W: the setting row: $(q "select row_to_json(b) from pgvigil.mssql_blitz_setting b where instance_id = $I")"
[[ $(state "$I") == "due|"* ]] || bad "A: the state before the run: $(state "$I")"
collect "$N" > /dev/null; crc=$?
NOW_N=$(blitzCount "$L1" "$P1"); blitzRSV "$L1" "$P1" > "$WORK/rsv.txt"
run1=$(q "select outcome || '|' || frk_version || '|' || to_char(frk_version_date, 'YYYYMMDD') || '|' || login || '|' || proc_db || '|' || (seconds > 0) || '|' || findings from pgvigil.mssql_blitz_run where instance_id = $I")
echo "  the run: $run1; sp_Blitz's own COUNT now $NOW_N"
[[ $crc == 0 && $(runs "$I") == 1 && $run1 == "done with messages|$FRKV|$FRKD|$L1|master|true|"* ]] && ok "A: one run stored, done with messages, the kit's version, the login, master" || bad "A: rc $crc runs $(runs "$I"): $run1 / $(cat "$OUT")"
R1=$(q "select run_id from pgvigil.mssql_blitz_run where instance_id = $I order by started_at desc limit 1")
[[ $(q "select count(*) from pgvigil.mssql_blitz_run r, jsonb_array_elements(r.messages) m where r.run_id = ${R1:-0} and (m->>'number')::int = 229") -ge 1 ]] && ok "A: Msg 229 (sp_BlitzBackups) kept among the messages" || bad "A: the messages: $(q "select messages from pgvigil.mssql_blitz_run where run_id = ${R1:-0}")"
FN=$(q "select count(*) from pgvigil.mssql_blitz_finding where run_id = ${R1:-0}")
[[ $FN == "${run1##*|}" && $FN == "$NOW_N" ]] && ok "A: $FN findings stored = the run's count = sp_Blitz's own COUNT" || bad "A: stored $FN, the run says ${run1##*|}, COUNT $NOW_N"
q "select coalesce(findings_group, '(N/A)') from pgvigil.mssql_blitz_finding where run_id = ${R1:-0} order by 1" > "$WORK/g.db"; cut -d$'\x1f' -f3 "$WORK/rsv.txt" | sort > "$WORK/g.rsv"
q "select check_id from pgvigil.mssql_blitz_finding where run_id = ${R1:-0} order by 1" > "$WORK/c.db"; cut -d$'\x1f' -f2 "$WORK/rsv.txt" | sort -n > "$WORK/c.rsv"
LC_ALL=C sort "$WORK/g.db" -o "$WORK/g.db"; LC_ALL=C sort "$WORK/g.rsv" -o "$WORK/g.rsv"
cmp -s "$WORK/g.db" "$WORK/g.rsv" && cmp -s "$WORK/c.db" "$WORK/c.rsv" && ok "A: the stored FindingsGroups and CheckIDs equal RSV's ($(sort -u "$WORK/g.db" | wc -l) groups)" \
  || bad "A: groups / CheckIDs differ: $(diff "$WORK/g.db" "$WORK/g.rsv" | head -5 | tr '\n' ' ') / $(diff "$WORK/c.db" "$WORK/c.rsv" | head -5 | tr '\n' ' ')"
row A

echo "--- H. the same week again"
collect "$N" >/dev/null
[[ $(cat "$OUT") == *"skipped: not due yet"* && $(runs "$I") == 1 && $(state "$I") == "not due|"*"the next is due"* ]] && ok "H: not due yet, still one run ($(state "$I" | cut -c1-160))" || bad "H: $(cat "$OUT") runs $(runs "$I") state $(state "$I")"
row H

echo "--- C. sa"
on "$IS"; collect "$NS" >/dev/null
SAN=$(blitzCount sa "$MSSQL_SA_PASSWORD")
c1=$(q "select outcome || '|' || findings from pgvigil.mssql_blitz_run where instance_id = $IS")
[[ $c1 == "done with messages|$SAN" && $(q "select count(*) from pgvigil.mssql_blitz_run r, jsonb_array_elements(r.messages) m where r.instance_id = $IS and (m->>'number')::int = 8134") -ge 1 ]] \
  && ok "C: sa: done with messages (8134 kept), $SAN findings = sa's COUNT" || bad "C: sa: $c1 (sa's COUNT $SAN), messages $(q "select messages from pgvigil.mssql_blitz_run where instance_id = $IS")"
row C

echo "--- D. no VIEW SERVER STATE"
on "$IV"; collect "$NV" >/dev/null
d1=$(q "select outcome || '|' || findings || '|' || coalesce(error, '') from pgvigil.mssql_blitz_run where instance_id = $IV")
[[ $d1 == "refused|0|"*"The user $L2 does not have VIEW SERVER STATE permissions."* && $(cat "$OUT") == *"partial: "*"VIEW SERVER STATE"* ]] && ok "D: refused with sp_Blitz's own words, no finding, collect partial" || bad "D: $d1 / $(cat "$OUT")"
row D

echo "--- E. no EXECUTE"
on "$IX"; collect "$NX" >/dev/null
[[ $(cat "$OUT") == *"skipped: no EXECUTE on [master].[dbo].[sp_Blitz] for the login $L3"* && $(runs "$IX") == 0 && $(note "$IX") == "skipped|no EXECUTE on"* ]] && ok "E: skipped, no EXECUTE, no run" || bad "E: $(cat "$OUT") runs $(runs "$IX") note $(note "$IX")"
row E

echo "--- F. not installed"
on "$II" true "$DBE"; collect "$NI" >/dev/null
[[ $(cat "$OUT") == *"skipped: sp_Blitz is not in [$DBE].[dbo]"* && $(runs "$II") == 0 ]] && ok "F: an empty database: not installed, no run" || bad "F: $(cat "$OUT") runs $(runs "$II")"
on "$II" true "nosuch_$SUF"; collect "$NI" >/dev/null
[[ $(cat "$OUT") == *"skipped: no database nosuch_$SUF on this server"* && $(runs "$II") == 0 ]] && ok "F: a database that does not exist: said, no run" || bad "F: $(cat "$OUT") runs $(runs "$II")"
row F

echo "--- I. a forced timeout"
site '"timeout_s":1'; on "$IT"; collect "$NT" >/dev/null
i1=$(q "select outcome || '|' || findings || '|' || coalesce(error, '') from pgvigil.mssql_blitz_run where instance_id = $IT")
[[ $i1 == "timed out|0|"*"1 s"* && $(cat "$OUT") == *"partial: "* ]] && ok "I: timed out at 1 s, no finding, collect partial ($i1)" || bad "I: $i1 / $(cat "$OUT")"
site '"timeout_s":600'
row I

echo "--- J. 12 runs kept"
# a week cannot pass in a proof: the stored runs move back instead, in this proof's own repository
q "update pgvigil.mssql_blitz_run set started_at = started_at - interval '8 days' where instance_id = $I" >/dev/null
q "insert into pgvigil.mssql_blitz_run (instance_id, started_at, seconds, outcome, error, messages, findings)
   select $I, now() - make_interval(days => 8 + 7 * k), 1, 'failed', 'seeded by the proof', '[]', 0 from generate_series(1, 11) k" >/dev/null
OLD1=$(q "select run_id from pgvigil.mssql_blitz_run where instance_id = $I order by started_at limit 1")
OLD2=$(q "select run_id from pgvigil.mssql_blitz_run where instance_id = $I order by started_at offset 1 limit 1")
collect "$N" >/dev/null
gone=$(q "select count(*) filter (where run_id = $OLD1) || '|' || count(*) filter (where run_id = $OLD2) || '|' || count(*) filter (where run_id = $R1) from pgvigil.mssql_blitz_run")
[[ $(runs "$I") == 12 && $gone == "0|1|1" ]] && ok "J: 13 runs leave 12 (the oldest gone, the next kept, run A kept)" || bad "J: runs $(runs "$I"), oldest|next|A left: $gone"
R2=$(q "select run_id from pgvigil.mssql_blitz_run where instance_id = $I order by started_at desc limit 1")
R2N=$(q "select findings from pgvigil.mssql_blitz_run where run_id = $R2")
q "update pgvigil.mssql_blitz_run set started_at = started_at - interval '200 days' where instance_id = $I" >/dev/null
q "insert into pgvigil.mssql_blitz_run (instance_id, started_at, seconds, outcome, error, messages, findings)
   select $I, now() - make_interval(days => 8 + 7 * k), 1, 'failed', 'seeded by the proof', '[]', 0 from generate_series(1, 11) k" >/dev/null
site '"timeout_s":1'; collect "$N" >/dev/null; site '"timeout_s":600'
j2=$(q "select count(*) || '|' || count(*) filter (where run_id = $R2) || '|' || (select count(*) from pgvigil.mssql_blitz_finding where run_id = $R2) from pgvigil.mssql_blitz_run where instance_id = $I")
[[ $j2 == "13|1|$R2N" && $(q "select outcome from pgvigil.mssql_blitz_run where instance_id = $I order by started_at desc limit 1") == "timed out" ]] \
  && ok "J: 12 newer failed runs keep the newest successful run and its $R2N findings (13 rows)" || bad "J: $j2 (want 13|1|$R2N)"
row J

echo "--- K. the API"
curl -s -b "$WORK/$A.jar" "$U/api/mssql/blitz?instance=$I" > "$WORK/k.json"
kv=$(python3 - "$WORK/k.json" "$R2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); r2 = int(sys.argv[2])
def objs(p): t = d[p]; return [dict(zip(t['columns'], r)) for r in t['rows']]
parts = ','.join(sorted(d.keys()))
sh = objs('shown'); f = objs('findings'); j = [x['check_id'] for x in objs('judged')]
okj = all(bool(x['judged']) == (x['check_id'] in j) for x in f)
print(parts, len(sh) == 1 and sh[0]['run_id'] == r2, sh[0]['newest_outcome'] if sh else None, len(f), all(k in j for k in (12, 13, 14, 1001)), okj, objs('state')[0]['state'])
PY
) || kv="unreadable: $(head -c 300 "$WORK/k.json")"
[[ $kv == "findings,judged,last,runs,shown,state True timed out $R2N True True not due" ]] \
  && ok "K: the six parts; shown = the newest successful run, the newest 'timed out' beside it; $R2N findings; judged right ($kv)" || bad "K: $kv"
row K

echo "--- M. the import's guards"
PGI=$(q "select pgvigil.ensure_instance('bz-pg-$SUF', 'onprem', '18', 180000, false, '{}'::text[])")
m1=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "select pgvigil.import_mssql_blitz($PGI, now(), '[{\"kind\":\"run\",\"outcome\":\"done\"}]')" 2>&1)
[[ $m1 == *"not a SQL Server instance"* ]] && ok "M: a PostgreSQL instance refused" || bad "M: $m1"
PAY='[{"kind":"run","outcome":"done","seconds":1.5,"login":"x"},{"kind":"finding","n":1,"check_id":1,"priority":1,"findings_group":"G","finding":"F"}]'
r0=$(runs "$IV"); q "select pgvigil.import_mssql_blitz($IV, '2026-01-04T03:00:00Z', '$PAY')" >/dev/null; q "select pgvigil.import_mssql_blitz($IV, '2026-01-04T03:00:00Z', '$PAY')" >/dev/null
[[ $(runs "$IV") == $((r0 + 1)) ]] && ok "M: the same payload twice stores one run" || bad "M: runs $r0 -> $(runs "$IV")"
row M

echo "--- P. the page"
if [[ ${PGVIGIL_SKIP_PAGES:-0} == 1 ]]; then
  echo "NOT PROVEN: P (PGVIGIL_SKIP_PAGES=1): the section was not drawn in a browser"
else
  for t in chromium node; do command -v $t >/dev/null || die "P: $t is not on this machine (PGVIGIL_SKIP_PAGES=1 leaves P out)"; done
  grep -q 'sp_Blitz weekly' "$ROOT/internal/web/dist/app.js" || bad "P: the web bundle has no 'sp_Blitz weekly' section (run 'npm run build' in web/)"
  CDP=$(freeport 19400 19460) || die "no free port for Chromium"
  chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  cat > "$WORK/p.mjs" <<'JS'
const [port, base, cookie, hash] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const t = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(res => { const i = ++id; wait.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
await cmd('Network.enable'); await cmd('Page.enable');
await cmd('Network.setCookie', { name: 'pgvigil_session', value: cookie, url: base });
await cmd('Page.navigate', { url: base + hash });
let out = null;
for (let i = 0; i < 60 && !out; i++) {
  await sleep(500);
  const r = await cmd('Runtime.evaluate', { returnByValue: true, expression: `(() => {
    const sec = [...document.querySelectorAll('main section')].find(s => s.querySelector('h2')?.textContent.trim() === 'sp_Blitz weekly');
    if (!sec || !sec.querySelector('details.blitz-group')) return null;
    const groups = [...sec.querySelectorAll('details.blitz-group')].map(d => ({ group: d.dataset.group, summary: d.querySelector('summary')?.textContent.trim() ?? '' }));
    const all = sec.querySelector('details.blitz-group[data-group="All"]');
    const links = all ? [...all.querySelectorAll('td a')].map(a => a.getAttribute('href') ?? '') : [];
    const urlCells = all ? [...all.querySelectorAll('td[data-key="url"]')].map(td => ({ text: td.textContent.trim(), a: !!td.querySelector('a') })) : [];
    const judged = all ? [...all.querySelectorAll('a.blitz-judged')].map(a => a.getAttribute('href') ?? '') : [];
    const dbs = [...(sec.querySelector('select.blitz-db')?.options ?? [])].map(o => o.value);
    const save = sec.querySelector('button.blitz-save');
    return { groups, urlCells, links, judged, dbs, saveOff: save?.getAttribute('aria-disabled') ?? null, text: sec.textContent };
  })()` });
  out = r.result?.result?.value ?? null;
}
console.log(JSON.stringify(out));
await fetch(`http://127.0.0.1:${port}/json/close/${t.id}`).catch(() => {});
process.exit(0);
JS
  ck() { awk '$6 == "pgvigil_session" {print $7}' "$WORK/$1.jar"; }
  timeout 90 node "$WORK/p.mjs" "$CDP" "$U/" "$(ck $A)" "#/findings?i=$I" > "$WORK/p.admin.json" 2>"$WORK/p.err" || bad "P: the page driver (admin): $(tail -3 "$WORK/p.err")"
  timeout 90 node "$WORK/p.mjs" "$CDP" "$U/" "$(ck bzview$SUF)" "#/findings?i=$I" > "$WORK/p.view.json" 2>>"$WORK/p.err" || bad "P: the page driver (viewer): $(tail -3 "$WORK/p.err")"
  q "select findings_group || '|' || count(*) from pgvigil.mssql_blitz_finding where run_id = $R2 group by 1 order by 1" > "$WORK/p.groups"
  q "select coalesce(database_name, '') from pgvigil.mssql_blitz_finding where run_id = $R2 and coalesce(database_name, '') <> '' group by 1 order by 1" > "$WORK/p.dbs"
  pv=$(python3 - "$WORK/p.admin.json" "$WORK/p.view.json" "$WORK/p.groups" "$WORK/p.dbs" "$R2N" "$I" <<'PY'
import json, sys
a = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1] or 'null'); v = json.loads(open(sys.argv[2]).read().strip().splitlines()[-1] or 'null')
want = dict(l.rsplit('|', 1) for l in open(sys.argv[3]).read().splitlines() if l)
dbs = [l for l in open(sys.argv[4]).read().splitlines() if l]
n, inst = sys.argv[5], sys.argv[6]
if not a: print('admin: no section'); sys.exit()
got = {g['group']: g['summary'] for g in a['groups']}
bad = []
if set(got) != set(want) | {'All'}: bad.append('groups %s want %s + All' % (sorted(got), sorted(want)))
for g, c in want.items():
    if g in got and (g not in got[g] or c not in got[g]): bad.append('summary %r for %s (%s)' % (got[g], g, c))
if 'All' in got and n not in got['All']: bad.append('All says %r (want %s)' % (got['All'], n))
for u in a['urlCells']:
    if u['text'].startswith(('http://', 'https://')) and not u['a']: bad.append('url not a link: ' + u['text'][:80])
if not a['judged'] or not all(('mssqlchecks' in h and ('i=' + inst) in h) for h in a['judged']): bad.append('judged links %s' % a['judged'][:3])
if [d for d in a['dbs'] if d] != dbs: bad.append('database filter %s want %s' % (a['dbs'][:6], dbs[:6]))
if not v: bad.append('viewer: no section')
elif v['saveOff'] != 'true' or 'changing the weekly sp_Blitz needs the admin role' not in v['text']: bad.append('viewer Save %s, words %s' % (v['saveOff'], 'changing the weekly sp_Blitz needs the admin role' in v['text']))
print('ok %d groups + All, %d url cells, %d judged links, %d databases' % (len(want), len(a['urlCells']), len(a['judged']), len(dbs)) if not bad else 'BAD ' + '; '.join(bad))
PY
)
  [[ $pv == ok* ]] && ok "P: $pv; the viewer's Save off with the admin words" || bad "P: $pv"
  row P
fi

if (( FAILS > 0 )); then echo "FAIL: proof-blitz: $FAILS row(s)"; exit 1; fi
echo "PASS proof-blitz ($(echo $ROWS))"
