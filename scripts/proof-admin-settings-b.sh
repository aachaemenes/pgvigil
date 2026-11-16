#!/usr/bin/env bash
# Proof of Admin > Instances' Settings, part two (the ServiceConfig takes, ST5b): migration 0266, a SQL Server page
# instance's own thresholds, a paused collection's own interval, expect, the tree's two dialogs for a page instance,
# Thresholds in force's 'Admin > Instances' source, and their hunks in the shared files (scripts/st5b-wiring.patch,
# after scripts/st12-wiring.patch and scripts/st5-wiring.patch: applied to the run's own copy when the tree does not
# hold them).
#
# Expected (written before the first run). One SQL Server 2022 Developer container: a database st5b with one full
# backup whose msdb row is made 40 minutes old (inside 0066's hour of slack before the database's create_date: an
# older set is an earlier incarnation's and the import drops it); pgvigil.yaml holds f-ms (the same server, the file's); the page holds m-a
# (that server, as sa) and p-a (a PostgreSQL 16 container); the collector (pgvigil run) runs throughout.
#  T1  (RED first: PROOF_RED=1 runs on a tree without ST5b) a thresholds write for m-a: the base refuses it (no 200
#      done). Green: (a) m-a's mssql_backups set to 1m in its own write; st5b's backup state is read within 3 minutes.
#      (b) a thresholds-only write {new_database_hours: 0}: done, its takes_effect names the thresholds' next read; within
#      150 s mssql_hadr_limits holds new_database_hours 0 for m-a and st5b's full_status is 'ok' (40 minutes under the
#      default 168 h); Thresholds in force marks new_database_hours 'page' with value 0 and full_backup_hours 'default' 168, no
#      pending. (c) {new_database_hours: 0, full_backup_hours: 0.5}: within 150 s full_backup_hours 0.5 and st5b 'late' - the
#      page's value judges it, not the default; the collector's pid kept through (a)-(c).
#  T2  refusals, each 409 with its words and one audit row: thresholds on p-a (a PostgreSQL instance), a threshold no
#      collector knows (nope), a negative number, backup_exclude not a list, paused for a collection not off, a write
#      whose expect is not the stored settings ('changed since they were read: read them again').
#  D1  GET instance/collections: m-a answers source 'page', writable, its stored thresholds, the catalogue (the running
#      plans box's collection marked box), the floor 60 and the ceiling 2592000; f-ms answers source 'file' and nothing
#      more.
#  D2  pause and resume as the dialogs send them: m-a's mssql_jobs set to 10m; paused ({mssql_jobs: 0}, paused
#      {mssql_jobs: 600}) stored with the words 'paused mssql_jobs (its own 600 s kept)'; resumed ({mssql_jobs: 600}, no
#      paused key) stored; each with the read as its expect.
#  P   (the page, light and dark, signed in) Settings of m-a: its Thresholds table shows full_backup_hours '0.5'; in light
#      redo_queue_kb set to 2048 and saved through the page (stored 2048, the other thresholds kept); Alerts > Rules'
#      Thresholds in force shows m-a's full_backup_hours from 'Admin > Instances' with a link to its Settings; the
#      tree's Pause/Resume Collections on m-a draws its rows with a Save and no pgvigil.yaml lines, on f-ms the lines;
#      Configure Schedule on m-a refuses '30s' in its own words; no error box; axe-core 4.14.0 (WCAG 2.1 A and AA) 0
#      violation nodes on the panel, Thresholds in force and the dialog. Skipped (NOT PROVEN) without chromium and node.
#  L   no answer, serve's log or the collector's log holds either server's password.
#
# Needs: docker (SQL Server 2022 and PostgreSQL 16), psql, curl, python3, a go toolchain, node and npm (the web bundle;
# chromium for P), and ADMIN_DSN: a superuser keyword DSN of a PostgreSQL sandbox for the repository. Everything the run
# makes carries its random suffix and is removed on every exit path the shell can catch; every password is made at run
# time.
#
# NOT PROVEN HERE: an HA/DR finding at a page instance's own value on an availability group (the backups row stands
# for the six collections that store the thresholds); the dialogs' Save clicked in the browser (P draws them, D2 sends
# what they send).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_PG=postgres:16
IMG_SQL=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
PGM=pgvst5b-pg-$SUF; SQM=pgvst5b-sql-$SUF; LBL=pgvigil-proof=st5b
PGDB=pgv_st5b_$SUF; USR=proofdbb$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; RUNPID=; CHRPID=
PG_PW=$(pw); SA_PW=$(pw); UPW=$(pw)
export PG_PW SA_PW
printf 'POSTGRES_PASSWORD=%s\n' "$PG_PW" > "$TMPD/pg.env"
printf 'ACCEPT_EULA=Y\nMSSQL_PID=Developer\nMSSQL_SA_PASSWORD=%s\n' "$SA_PW" > "$TMPD/sql.env"
cleanup() {
  rc=$?
  set +e
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null
  [[ -n "$RUNPID" ]] && kill "$RUNPID" 2>/dev/null
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null; wait "$CHRPID" 2>/dev/null; fi
  for c in "$PGM" "$SQM"; do docker rm -f -v "$c" >/dev/null 2>&1 || { docker inspect "$c" >/dev/null 2>&1 && echo "CLEANUP: container $c not removed" >&2; }; done
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
  echo "left: containers $(docker ps -aq --filter "name=pgvst5b-.*-$SUF" | wc -l)"
  exit $rc
}
trap cleanup EXIT
trap 'echo "FAIL: the proof stopped at line $LINENO: a command failed without its own message" >&2' ERR
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
mq() { PGPASSWORD="$PG_PW" psql "host=127.0.0.1 port=$PP user=postgres dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
sq() { docker exec -i -e SQLCMDPASSWORD="$SA_PW" "$SQM" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -W -h -1 -d master -i /dev/stdin; }
for t in docker go psql curl python3 npm; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
js() { python3 -c 'import json, os, sys
d = {}
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    d[k] = os.environ[v[1:]] if v.startswith("@") else v
print(json.dumps(d))' "$@"; }
# setj NAME SETTINGS [EXPECT]: the body of op 'settings' (the settings object as given; expect the settings as read)
setj() { python3 -c 'import json, sys
b = {"op": "settings", "name": sys.argv[1], "settings": json.loads(sys.argv[2])}
if len(sys.argv) > 3: b["expect"] = json.loads(sys.argv[3])
print(json.dumps(b))' "$@"; }
mkdir -p "$TMPD/answers"
api() { local code; if [[ $# -ge 3 ]]; then printf '%s' "$3" > "$TMPD/body.json"; code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -X "$1" --data @"$TMPD/body.json" "$U/api/$2")
  else code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" "$U/api/$2"); fi; cp "$TMPD/ans.json" "$(mktemp "$TMPD/answers/XXXXXXXX")"; echo "$code"; }
# ans KEY[.KEY]: a value of the last answer (an object or a list as JSON)
ans() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); v = d
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (json.dumps(v, sort_keys=True) if isinstance(v, (dict, list)) else v))' "$TMPD/ans.json" "$1"; }
settings() { api POST admin/instances "$(setj "$@")"; }
stored() { pq "SELECT settings::text FROM pgvigil.admin_instances WHERE name = '$1'"; }
iid() { pq "SELECT instance_id FROM pgvigil.instances WHERE name = '$1'"; }
limit() { pq "SELECT coalesce((SELECT l.$2::text FROM pgvigil.mssql_hadr_limits l JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1'), 'none')"; }
fullstatus() { pq "SELECT coalesce((SELECT j.full_status FROM pgvigil.mssql_backup_judged j WHERE j.instance = '$1' AND j.database_name = 'st5b'), 'none')"; }
# until SECS CMD WANT: CMD's output every 5 s until it is WANT or SECS have passed; prints the last output
until_is() { local end=$(( $(date +%s) + $1 )) v; while :; do v=$($2); [[ "$v" == "$3" ]] && { echo "$v"; return 0; }; (( $(date +%s) >= end )) && { echo "$v"; return 0; }; sleep 5; done; }
# inforce INSTANCE KEY: the Thresholds in force row of a SQL Server threshold (GET alertrules?part=inforce answers the
# part 'inforce' as a table: {"inforce": {"columns", "rows"}}): source|value|pending
inforce() { api GET "alertrules?part=inforce" >/dev/null; python3 -c 'import json, sys; t = json.load(open(sys.argv[1]))["inforce"]; i = {c: n for n, c in enumerate(t["columns"])}
r = [r for r in t["rows"] if r[i["instance"]] == sys.argv[2] and r[i["what"]] == "mssql." + sys.argv[3]]
print("NO ROW" if not r else "|".join("" if r[0][i[c]] is None else str(r[0][i[c]]) for c in ("source", "value", "pending")))' "$TMPD/ans.json" "$1" "$2"; }
# exec: $RUNPID is the collector itself
startrun() { (exec "$TMPD/pgvigil" run -config "$CFGD/pgvigil.yaml") >>"$TMPD/run.log" 2>&1 & RUNPID=$!; }

echo "== A. the monitored servers =="
docker run -d --name "$SQM" --label "$LBL" --env-file "$TMPD/sql.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
docker run -d --name "$PGM" --label "$LBL" --env-file "$TMPD/pg.env" -p 127.0.0.1::5432 "$IMG_PG" >/dev/null
PS=$(docker port "$SQM" 1433/tcp | head -1 | sed 's/.*://'); PP=$(docker port "$PGM" 5432/tcp | head -1 | sed 's/.*://')
for _ in $(seq 1 90); do [[ "$(echo "SET NOCOUNT ON; SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" | sq 2>/dev/null | tr -d '\r ')" == 1 ]] && break; sleep 2; done
for _ in $(seq 1 60); do mq 'select 1' >/dev/null 2>&1 && break; sleep 1; done
mq 'select 1' >/dev/null || fail "A: PostgreSQL did not come up"
sq >/dev/null <<'SQL' || fail "A: the seed of st5b"
CREATE DATABASE st5b;
GO
BACKUP DATABASE st5b TO DISK = N'/var/opt/mssql/data/st5b.bak' WITH INIT;
GO
UPDATE msdb.dbo.backupset SET backup_start_date = DATEADD(minute, -40, backup_start_date), backup_finish_date = DATEADD(minute, -40, backup_finish_date) WHERE database_name = N'st5b';
GO
SQL
AGE=$(echo "SET NOCOUNT ON; SELECT DATEDIFF(minute, MAX(backup_finish_date), GETDATE()) FROM msdb.dbo.backupset WHERE database_name = N'st5b' AND type = 'D'" | sq | tr -d '\r ')
(( AGE >= 35 && AGE <= 45 )) || fail "A: st5b's full backup is $AGE minutes old in msdb (want about 40)"
ok "A: SQL Server 2022 on $PS (st5b's full backup $AGE minutes old in msdb), PostgreSQL 16 on $PP"

echo "== B. the build, the repository, serve, the collector =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git --exclude=./bin -cf - . | tar -C "$GSRC" -xf -
P12=scripts/st12-wiring.patch; P5=scripts/st5-wiring.patch; P5B=scripts/st5b-wiring.patch
has5b() { grep -q 'collectionsSettingsParts(ctx, name, engine)' "$GSRC/internal/web/q_retention.go"; }
has5() { grep -q 's.instanceSettings(w, r, user, in, pay)' "$GSRC/internal/web/q_instances_admin.go"; }
has12() { grep -q 'instanceRights(w, r, user, in)' "$GSRC/internal/web/q_instances_admin.go"; }
if has5b; then echo "B: the tree holds the three wirings (the patches are not applied)"
else
  has12 || (cd "$GSRC" && patch -p1 -s < "$P12") || fail "B: $P12 does not apply"
  has5 || (cd "$GSRC" && patch -p1 -s < "$P5") || fail "B: $P5 does not apply"
  if [[ -z "${PROOF_RED:-}" ]]; then (cd "$GSRC" && patch -p1 -s < "$P5B") || fail "B: $P5B does not apply"; echo "B: the wirings applied to the run's copy"
  else echo "B: RED run - st12's and st5's wirings alone"; fi
fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "B: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "B: the build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFGD=$TMPD/etc; mkdir -p "$CFGD"
export ST5B_MS_DSN="sqlserver://sa:$(python3 -c 'import urllib.parse, os; print(urllib.parse.quote(os.environ["SA_PW"], safe=""))')@127.0.0.1:$PS?database=master&TrustServerCertificate=true"
cat > "$CFGD/pgvigil.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - {name: f-ms, engine: sqlserver, dsn: env:ST5B_MS_DSN}
EOF
"$TMPD/pgvigil" migrate -config "$CFGD/pgvigil.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$CFGD/pgvigil.yaml" "$USR" >/dev/null 2>&1 || fail "B: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
(umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/pgvigil.yaml" -listen "127.0.0.1:$PORT") >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "B: serve exited"; }
P_USR="$USR" P_UPW="$UPW" python3 -c 'import json, os, sys; json.dump({"username": os.environ["P_USR"], "password": os.environ["P_UPW"]}, open(sys.argv[1], "w"))' "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "B: the UI login"
code=$(api POST admin/instances "$(js op=add name=m-a engine=sqlserver host=127.0.0.1 port=$PS dbname=master auth=sql login=sa options=TrustServerCertificate=true password=@SA_PW)")
[[ "$code" == 200 ]] || fail "B: add m-a: $code $(cat "$TMPD/ans.json")"
code=$(api POST admin/instances "$(js op=add name=p-a engine=postgres host=127.0.0.1 port=$PP dbname=postgres auth=password login=postgres password=@PG_PW)")
[[ "$code" == 200 ]] || fail "B: add p-a: $code $(cat "$TMPD/ans.json")"
ok "B: built, migrated, serve on $PORT, signed in as $USR; m-a and p-a added"

if [[ -n "${PROOF_RED:-}" ]]; then
  echo "== T1 RED on the base: a thresholds write =="
  code=$(settings m-a '{"thresholds": {"full_backup_hours": 1}}')
  if [[ "$code" == 200 && "$(ans outcome)" == done ]]; then fail "T1 RED: the base stored thresholds ($code $(head -c 200 "$TMPD/ans.json")): the row is not red on it"; fi
  echo "RED as expected: a thresholds write on the base -> $code $(head -c 300 "$TMPD/ans.json")"
  exit 0
fi

startrun
for _ in $(seq 1 60); do [[ -n "$(iid m-a)" && -n "$(iid f-ms)" ]] && break; sleep 3; done
[[ -n "$(iid m-a)" && -n "$(iid f-ms)" ]] || { tail -30 "$TMPD/run.log" >&2; fail "B: the collector did not register m-a and f-ms within 3 minutes"; }
RUN1=$RUNPID
ok "B: the collector (pid $RUN1) reads m-a and f-ms"

echo "== T1. a SQL Server page instance's own thresholds =="
code=$(settings m-a '{"schedules": {"mssql_backups": 60}}' '{}')
[[ "$code" == 200 && "$(ans outcome)" == done ]] || fail "T1a: the schedule write: $code $(cat "$TMPD/ans.json")"
ST=$(until_is 180 "fullstatus m-a" "not judged")
[[ "$ST" == "not judged" ]] || fail "T1a: st5b on m-a after 3 minutes: full_status '$ST' (want 'not judged': a new database under the default 24 h)"
ok "T1a: m-a's mssql_backups every minute; st5b read, 'not judged' (a new database by the default new_database_hours 24)"
code=$(settings m-a '{"schedules": {"mssql_backups": 60}, "thresholds": {"new_database_hours": 0}}' "$(stored m-a)")
TE=$(ans takes_effect)
[[ "$code" == 200 && "$(ans outcome)" == done && "$TE" == *"its thresholds are stored at the instance's next HA/DR, jobs or backups read" ]] || fail "T1b: the thresholds-only write: $code $(cat "$TMPD/ans.json")"
NDH=$(until_is 150 "limit m-a new_database_hours" 0); ST=$(until_is 60 "fullstatus m-a" ok)
[[ "$NDH" == 0 && "$ST" == ok ]] || fail "T1b: after 150 s m-a's new_database_hours $NDH (want 0), st5b's full_status '$ST' (want ok: about 40 minutes under the default 168 h)"
IF1=$(inforce m-a new_database_hours); IF2=$(inforce m-a full_backup_hours)
[[ "$IF1" == "page|0|" && "$IF2" == "default|168|" ]] || fail "T1b: Thresholds in force: new_database_hours '$IF1' (want 'page|0|'), full_backup_hours '$IF2' (want 'default|168|')"
ok "T1b: a thresholds-only write reached the collector (new_database_hours 0 in mssql_hadr_limits); st5b 'ok' at the default 168 h; in force: new_database_hours '$IF1', full_backup_hours '$IF2'"
code=$(settings m-a '{"schedules": {"mssql_backups": 60}, "thresholds": {"new_database_hours": 0, "full_backup_hours": 0.5}}' "$(stored m-a)")
[[ "$code" == 200 && "$(ans outcome)" == done ]] || fail "T1c: the write: $code $(cat "$TMPD/ans.json")"
FBH=$(until_is 150 "limit m-a full_backup_hours" 0.5); ST=$(until_is 90 "fullstatus m-a" late)
[[ "$FBH" == 0.5 && "$ST" == late ]] || fail "T1c: after 150 s m-a's full_backup_hours $FBH (want 0.5), st5b's full_status '$ST' (want late: about 45 minutes over the page's 30)"
kill -0 "$RUN1" 2>/dev/null || fail "T1: the collector exited"
ok "T1c: full_backup_hours 0.5 from the page judges st5b 'late' (its full backup about 45 minutes old); the collector's pid kept ($RUN1)"

echo "== T2. refusals =="
before=$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance settings' AND outcome = 'refused'")
t2() { local name=$1 set=$2 want=$3 exp=${4:-}; local code; if [[ -n "$exp" ]]; then code=$(settings "$name" "$set" "$exp"); else code=$(settings "$name" "$set"); fi
  [[ "$code" == 409 && "$(ans detail)" == "$want"* ]] || fail "T2: $name $set: $code '$(ans detail)' (want 409 '$want')"; }
t2 p-a '{"thresholds": {"redo_queue_kb": 1}}' "thresholds are a SQL Server instance's (mssql_thresholds); this instance is postgres"
t2 m-a '{"thresholds": {"nope": 1}}' 'mssql threshold "nope" is not known; known: '
t2 m-a '{"thresholds": {"redo_queue_kb": -1}}' "the settings do not parse: its settings in Admin > Instances give threshold redo_queue_kb -1: not a number of 0 or more"
t2 m-a '{"thresholds": {"backup_exclude": "st5b"}}' "the settings do not parse: its settings in Admin > Instances give backup_exclude: not a list of database name patterns, none blank"
t2 m-a '{"paused": {"mssql_jobs": 600}}' "paused mssql_jobs: its schedule is not off"
t2 m-a '{}' "the settings of m-a changed since they were read: read them again" '{}'
after=$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance settings' AND outcome = 'refused'")
(( after - before == 6 )) || fail "T2: $(( after - before )) refused audit rows (want 6)"
ok "T2: 6 refusals, each 409 with its words and one audit row (a PostgreSQL instance, an unknown threshold, a negative number, backup_exclude not a list, paused not off, a stale expect)"

echo "== D1. the dialogs' read =="
api GET "instance/collections?instance=$(iid m-a)" >/dev/null
D1=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))
c = d.get("catalogue") or {}
print("|".join(str(x) for x in (d.get("source"), d.get("writable"), (d.get("settings") or {}).get("thresholds", {}).get("full_backup_hours"),
  (c.get("mssql_running_plans") or {}).get("box"), d.get("settings_floor_s"), d.get("settings_ceiling_s"))))' "$TMPD/ans.json")
[[ "$D1" == "page|True|0.5|True|60|2592000" ]] || fail "D1: m-a's answer '$D1' (want page|True|0.5|True|60|2592000)"
api GET "instance/collections?instance=$(iid f-ms)" >/dev/null
F1=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d.get("source"), "settings" in d, "catalogue" in d)' "$TMPD/ans.json")
[[ "$F1" == "file False False" ]] || fail "D1: f-ms's answer '$F1' (want 'file False False')"
ok "D1: m-a answers page, writable, its full_backup_hours 0.5, the box's collection, the floor 60 and the ceiling 2592000; f-ms answers file alone"

echo "== D2. pause and resume as the dialogs send them =="
TH='"thresholds": {"new_database_hours": 0, "full_backup_hours": 0.5}'
code=$(settings m-a "{\"schedules\": {\"mssql_backups\": 60, \"mssql_jobs\": 600}, $TH}" "$(stored m-a)"); [[ "$code" == 200 ]] || fail "D2: mssql_jobs 10m: $code $(cat "$TMPD/ans.json")"
code=$(settings m-a "{\"schedules\": {\"mssql_backups\": 60, \"mssql_jobs\": 0}, \"paused\": {\"mssql_jobs\": 600}, $TH}" "$(stored m-a)")
[[ "$code" == 200 && "$(ans detail)" == *"paused mssql_jobs (its own 600 s kept)"* ]] || fail "D2: the pause: $code $(cat "$TMPD/ans.json")"
PJ=$(pq "SELECT (settings->'schedules'->>'mssql_jobs') || '|' || coalesce(settings->'paused'->>'mssql_jobs', 'none') FROM pgvigil.admin_instances WHERE name = 'm-a'")
code=$(settings m-a "{\"schedules\": {\"mssql_backups\": 60, \"mssql_jobs\": 600}, $TH}" "$(stored m-a)")
RJ=$(pq "SELECT (settings->'schedules'->>'mssql_jobs') || '|' || coalesce(settings->'paused'->>'mssql_jobs', 'none') FROM pgvigil.admin_instances WHERE name = 'm-a'")
[[ "$code" == 200 && "$PJ" == "0|600" && "$RJ" == "600|none" ]] || fail "D2: paused '$PJ' (want 0|600), resumed '$RJ' (want 600|none): $code $(cat "$TMPD/ans.json")"
ok "D2: mssql_jobs paused with its own 600 s kept ('$PJ'), resumed at it ('$RJ'), each with the read as its expect"

echo "== P. the panel, Thresholds in force, the tree's dialogs =="
if command -v chromium >/dev/null && command -v node >/dev/null && [[ -z "${PROOF_SKIP_PAGE:-}" ]]; then
  (cd "$TMPD" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "P: npm install axe-core failed"
  CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  chromium --headless=new ${PGVIGIL_CHROMIUM_FLAGS:-} --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1200 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "P: chromium's CDP port never answered"
  cat > "$TMPD/p.mjs" <<'JS'
const [port, U, axePath] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => (await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, s = 40) => { for (let i = 0; i < s * 4; i++) { if (await ev(expr)) return true; await sleep(250); } return false; };
const clickPrefix = prefix => ev(`(() => { const b = [...document.querySelectorAll('main button')].find(b => (b.getAttribute('aria-label') ?? '').startsWith(${JSON.stringify(prefix)})); if (!b) return false; b.click(); return true; })()`);
const axe = async () => { await cmd('Runtime.evaluate', { expression: axeSrc }); return JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: v.nodes.slice(0, 3).map(n => n.target.join(' ')) }))))`, true)); };
const treeInst = n => `[...document.querySelectorAll('#tree .tree-inst')].find(x => x.querySelector('a.inst')?.textContent.trim() === ${JSON.stringify(n)})`;
const rightClick = sel => ev(`(() => { const e = ${sel}; if (!e) return false; const r = e.getBoundingClientRect(); e.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 10, clientY: r.top + 5 })); return true; })()`);
const clickItem = label => ev(`(() => { const b = [...document.querySelectorAll('.tm-menu button, .menu button')].find(x => x.textContent.replace(/▸$/, '').startsWith(${JSON.stringify(label)})); if (!b) return false; b.click(); return true; })()`);
const closeDialogs = () => ev(`document.querySelectorAll('dialog[open]').forEach(d => d.close())`);
const openActions = async (inst, label) => { await closeDialogs(); await rightClick(`${treeInst(inst)}?.querySelector('a.inst')`); await sleep(150); await clickItem('Instance Actions'); await sleep(150); return clickItem(label); };
const out = {};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
out.login = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.P_USR)}, password: ${JSON.stringify(process.env.P_UPW)} }) }).then(r => r.status)`, true);
await cmd('Page.reload'); await sleep(800);
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: U + '#/admin_instances' }); await sleep(300); await cmd('Page.reload');
  const r = { drawn: await until(`!!document.querySelector('main .admin-instances')`) };
  await sleep(500);
  r.opened = await clickPrefix('Settings of m-a');
  r.box = await until(`!!document.querySelector('#admin-instance-settings table')`, 20);
  r.fbh = await ev(`document.querySelector('#admin-instance-settings input[aria-label^="full_backup_hours: threshold"]')?.value ?? null`);
  if (theme === 'light') {
    r.set = await ev(`(() => { const i = document.querySelector('#admin-instance-settings input[aria-label^="redo_queue_kb: threshold"]'); if (!i) return false; i.value = '2048'; return true; })()`);
    r.saved = await clickPrefix('Save the settings of m-a');
    await until(`/saved/.test(document.querySelector('.admin-instances p[role=status]')?.textContent ?? '')`, 20);
    r.status = await ev(`document.querySelector('.admin-instances p[role=status]')?.textContent ?? ''`);
    await sleep(500);
    await clickPrefix('Settings of m-a');
    await until(`!!document.querySelector('#admin-instance-settings table')`, 20);
  }
  r.errors = await ev(`document.querySelectorAll('main .error:not([role=status])').length`);
  r.violPanel = await axe();
  await cmd('Page.navigate', { url: U + '#/alertrules' }); await sleep(300); await cmd('Page.reload');
  await until(`[...document.querySelectorAll('main h3')].some(h => h.textContent.startsWith('Thresholds in force'))`);
  await sleep(800);
  r.inforce = await ev(`(() => { const row = [...document.querySelectorAll('main tr')].find(tr => tr.textContent.includes('m-a') && tr.textContent.includes('full_backup_hours')); if (!row) return null;
    const a = row.querySelector('a[href*="admin_instances?settings="]'); return { from: row.textContent.includes('Admin > Instances'), link: a ? a.getAttribute('href') : null }; })()`);
  r.violRules = await axe();
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(300); await cmd('Page.reload');
  await until(`!!(${treeInst('m-a')})`);
  r.prOpen = await openActions('m-a', 'Pause/Resume Collections'); await sleep(1500);
  r.pr = await ev(`(() => { const d = [...document.querySelectorAll('dialog[open]')].pop(); if (!d) return null; return { rows: d.querySelectorAll('tbody tr').length, save: [...d.querySelectorAll('button')].some(b => b.textContent === 'Save'), yaml: !!d.querySelector('pre.tm-yaml') }; })()`);
  r.violDialog = await axe();
  r.prFile = await openActions('f-ms', 'Pause/Resume Collections'); await sleep(1500);
  r.prf = await ev(`(() => { const d = [...document.querySelectorAll('dialog[open]')].pop(); if (!d) return null; return { yaml: !!d.querySelector('pre.tm-yaml'), save: [...d.querySelectorAll('button')].some(b => b.textContent === 'Save') }; })()`);
  if (theme === 'light') {
    await openActions('m-a', 'Configure Schedule'); await sleep(1500);
    r.cs = await ev(`(async () => { const d = [...document.querySelectorAll('dialog[open]')].pop(); if (!d) return null; const i = d.querySelector('tbody input:not([disabled])'); if (!i) return 'no input';
      i.value = '30s'; [...d.querySelectorAll('button')].find(b => b.textContent === 'Save').click(); await new Promise(r => setTimeout(r, 300));
      return d.querySelector('p[role=status]')?.textContent ?? ''; })()`, true);
  }
  await closeDialogs();
  out[theme] = r;
}
console.log(JSON.stringify(out));
process.exit(0);
JS
  P_USR="$USR" P_UPW="$UPW" node "$TMPD/p.mjs" "$CDP" "$U/" "$TMPD/node_modules/axe-core/axe.min.js" > "$TMPD/page.json" 2> "$TMPD/page.err" || fail "P: the page check did not run: $(tail -c 400 "$TMPD/page.err")"
  kill "$CHRPID" 2>/dev/null || true; CHRPID=
  RQ=$(pq "SELECT coalesce(settings->'thresholds'->>'redo_queue_kb', 'none') || '|' || coalesce(settings->'thresholds'->>'full_backup_hours', 'none') FROM pgvigil.admin_instances WHERE name = 'm-a'")
  RQ="$RQ" python3 - "$TMPD/page.json" <<'PY' || fail "P: the page"
import json, os, sys
d = json.load(open(sys.argv[1])); bad = []
if d.get("login") != 200: bad.append(f"the page's sign-in answered {d.get('login')}")
for theme in ("light", "dark"):
    r = d[theme]
    if not r.get("drawn") or r.get("errors"): bad.append(f"{theme}: drawn {r.get('drawn')}, error boxes {r.get('errors')}")
    if not r.get("opened") or not r.get("box"): bad.append(f"{theme}: the Settings link {r.get('opened')}, the box {r.get('box')}")
    if r.get("fbh") != "0.5": bad.append(f"{theme}: full_backup_hours in the panel {r.get('fbh')!r} (want '0.5')")
    f = r.get("inforce") or {}
    if not f.get("from") or not (f.get("link") or "").endswith("settings=m-a"): bad.append(f"{theme}: Thresholds in force's m-a full_backup_hours row {f!r} (want from Admin > Instances, a link to its Settings)")
    pr = r.get("pr") or {}
    if not r.get("prOpen") or not pr.get("rows") or not pr.get("save") or pr.get("yaml"): bad.append(f"{theme}: Pause/Resume on m-a {pr!r} (want rows, a Save, no yaml)")
    pf = r.get("prf") or {}
    if not r.get("prFile") or not pf.get("yaml") or pf.get("save"): bad.append(f"{theme}: Pause/Resume on f-ms {pf!r} (want the yaml lines, no Save)")
    for k in ("violPanel", "violRules", "violDialog"):
        n = sum(v["n"] for v in r.get(k) or [])
        if n: bad.append(f"{theme}: {k}: {n} axe violation node(s): {r[k]}")
l = d["light"]
if not l.get("set") or not l.get("saved") or "saved" not in (l.get("status") or ""): bad.append(f"light: redo_queue_kb set {l.get('set')}, Save {l.get('saved')}, the status {l.get('status')!r}")
if os.environ["RQ"] != "2048|0.5": bad.append(f"the thresholds stored after the page's save: {os.environ['RQ']} (want 2048|0.5)")
if "an interval set here is 1m or more" not in (l.get("cs") or ""): bad.append(f"light: Configure Schedule's answer to 30s {l.get('cs')!r}")
if bad: print("\n".join(bad)); sys.exit(1)
print(f"ok   P: light and dark: m-a's Thresholds table shows full_backup_hours 0.5; the page's save of redo_queue_kb 2048 stored (full_backup_hours kept); Thresholds in force from Admin > Instances with its Settings link; Pause/Resume on m-a with a Save and no yaml, on f-ms the yaml; Configure Schedule refuses 30s ({l['cs']!r}); 0 axe violation nodes")
PY
else
  notproven "P: chromium or node is not on this machine (the pages were not opened)"
fi

echo "== L. the passwords in no answer or log =="
for f in "$TMPD"/answers/* "$TMPD/serve.log" "$TMPD/run.log"; do
  grep -q -F -- "$PG_PW" "$f" && fail "L: the PostgreSQL password is in $(basename "$f")"
  grep -q -F -- "$SA_PW" "$f" && fail "L: the SQL Server password is in $(basename "$f")"
done
ok "L: neither password is in the $(ls "$TMPD"/answers | wc -l) answers, serve's log or the collector's log"
echo "ALL ROWS GREEN"
