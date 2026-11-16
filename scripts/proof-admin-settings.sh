#!/usr/bin/env bash
# Proof of Admin > Instances' Settings (the ServiceConfig takes, ST5a): migration 0263, internal/config/page_settings.go,
# internal/engines/page_settings.go, internal/web/q_instances_settings.go, cmd/pgvigil/serve_settings.go,
# web/src/admin_settings.ts, and their hunks in the shared files (scripts/st5-wiring.patch, after scripts/st12-wiring.patch:
# applied to the run's own copy when the tree does not hold them).
#
# Expected (written before the first run). pgvigil.yaml holds one instance, f-pg, and the global line
# schedules: {dbstats: 0}; the page holds p-a and p-b, both on one PostgreSQL 16 (pg_stat_statements loaded); the collector
# (pgvigil run) runs throughout.
#  S1  (RED first) p-a's statements 5m -> 1m and dbstats (the file's global 0) -> 1m, set through op 'settings': within
#      4 minutes the collector runs p-a's statements and dbstats 3 times or more each, without a restart of its own (its
#      pid kept); p-b keeps its statements at 5 minutes (1 run at most in the window) and never runs dbstats (the global
#      0 stands for it). The answer is done with the words 'settings of p-a saved: dbstats every 60 s, statements every 60 s'.
#      RED on the base (PROOF_RED=1: st12's patch alone): op 'settings' answers 400 - the base has no such op.
#  S2  p-a's activity set off: no run of it for 2 minutes while p-b's runs go on; Collection Dates says 'disabled'
#      for it (interval 0); set back to its default: it runs again within 2 minutes.
#  M1  p-a's activity set to 1h and its last run made 30 minutes old by hand: Collection Dates gives it interval 3600 and
#      status ok (stale at 3 hours), p-b's activity interval 60.
#  S3  a session sleeps with the marker st5a-marker in its text; p-a's query_text set to none: p-a's activity samples of
#      that session after the change carry no text (query_hash NULL in every one, 1 or more samples), p-b's carry the
#      marker's text.
#  S4  refusals, each answered 409 with its words and one audit row ('instance settings', refused): a collection no
#      engine has, a SQL Server collection, 5 seconds (under the minute), 30 days and a minute, query_text 'raw',
#      pgbouncer (never on an instance added here), f-pg (an instance of pgvigil.yaml); the running plans box's
#      collection on a SQL Server instance added here (NOT PROVEN when the page cannot add one to a server that is down).
#  M5  amcheck (opt-in: the catalogue's builtin 0) set on p-b: done; the catalogue lists pgbouncer as never here and
#      mssql_running_plans as the box's.
#  R   the collector stopped and started again: p-a's statements run 2 times or more within 150 s (its 1m read at start).
#  P   (the page, light and dark, signed in) Settings of p-a opens the box: statements '1m', query_text 'none'; in light
#      dbstats set to 2h and saved through the page (stored 7200); no error box; axe-core 4.14.0 (WCAG 2.1 A and AA) 0
#      violation nodes with the box open. Skipped (NOT PROVEN) without chromium and node.
#  L   no answer, serve's log or the collector's log holds the monitored server's password.
#
# Needs: docker (PostgreSQL 16), psql, curl, python3, a go toolchain, node and npm (the web bundle; chromium for P), and
# ADMIN_DSN: a superuser keyword DSN of a PostgreSQL sandbox for the repository. Everything the run makes carries its random
# suffix and is removed on every exit path the shell can catch; every password is made at run time.
#
# NOT PROVEN HERE: a SQL Server instance's own schedules (the engine's check and the catalogue are unit tests; the
# collector applies both engines' alike); serve's text policy on a SQL Server instance's Query Store search with its read
# door shut (TestPageDoorsSettings: the door set's policy).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_PG=postgres:16
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
PGM=pgvst5-pg-$SUF; LBL=pgvigil-proof=st5a
PGDB=pgv_st5_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; RUNPID=; CHRPID=; SLEEPER=
PG_PW=$(pw); UPW=$(pw)
export PG_PW
printf 'POSTGRES_PASSWORD=%s\n' "$PG_PW" > "$TMPD/pg.env"
cleanup() {
  rc=$?
  set +e
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null
  [[ -n "$RUNPID" ]] && kill "$RUNPID" 2>/dev/null
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null; wait "$CHRPID" 2>/dev/null; fi
  docker rm -f -v "$PGM" >/dev/null 2>&1 || { docker inspect "$PGM" >/dev/null 2>&1 && echo "CLEANUP: container $PGM not removed" >&2; }
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
  echo "left: containers $(docker ps -aq --filter "name=pgvst5-.*-$SUF" | wc -l)"
  exit $rc
}
trap cleanup EXIT
trap 'echo "FAIL: the proof stopped at line $LINENO: a command failed without its own message" >&2' ERR
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
mq() { PGPASSWORD="$PG_PW" psql "host=127.0.0.1 port=$PP user=postgres dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for t in docker go psql curl python3 npm; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
js() { python3 -c 'import json, os, sys
d = {}
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    d[k] = os.environ[v[1:]] if v.startswith("@") else v
print(json.dumps(d))' "$@"; }
# setj NAME JSON: the body of op 'settings' with the settings object as given
setj() { python3 -c 'import json, sys; print(json.dumps({"op": "settings", "name": sys.argv[1], "settings": json.loads(sys.argv[2])}))' "$1" "$2"; }
mkdir -p "$TMPD/answers"
api() { local code; if [[ $# -ge 3 ]]; then printf '%s' "$3" > "$TMPD/body.json"; code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -X "$1" --data @"$TMPD/body.json" "$U/api/$2")
  else code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" "$U/api/$2"); fi; cp "$TMPD/ans.json" "$(mktemp "$TMPD/answers/XXXXXXXX")"; echo "$code"; }
ans() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); v = d
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list)) else v))' "$TMPD/ans.json" "$1"; }
# settings NAME JSON: op 'settings', the answer's code
settings() { api POST admin/instances "$(setj "$1" "$2")"; }
iid() { pq "SELECT instance_id FROM pgvigil.instances WHERE name = '$1'"; }
snapat() { pq "SELECT coalesce((SELECT d.snapshot_at::text FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND d.collection = '$2'), 'none')"; }
# watch SECS: every 3 s, each series' collection_dates.snapshot_at (instance:collection, the args after SECS) into
# $TMPD/w.<series>; runs SERIES: how many runs ended in the window (the distinct times after the first one seen)
watch() { local secs=$1; shift; local end=$(( $(date +%s) + secs )); for s in "$@"; do : > "$TMPD/w.${s/:/.}"; done
  while (( $(date +%s) < end )); do for s in "$@"; do snapat "${s%%:*}" "${s#*:}" >> "$TMPD/w.${s/:/.}"; done; sleep 3; done; }
# (a series that never moved selects no line: grep's exit 1 is that answer, 0 runs, never a failed pipeline)
runs() { local f="$TMPD/w.${1/:/.}"; local first; first=$(head -1 "$f"); { grep -v -x -F "$first" "$f" || true; } | { grep -v -x none || true; } | sort -u | wc -l; }
# (GET collectiondates answers through multiPart: its table is the part "collections", q_collectiondates.go L59)
coldates() { api GET "collectiondates?instance=$(iid "$1")" >/dev/null; python3 -c 'import json, sys; t = json.load(open(sys.argv[1]))["collections"]; i = {c: n for n, c in enumerate(t["columns"])}
r = [r for r in t["rows"] if r[i["collection"]] == sys.argv[2]]
print("NO ROW" if not r else str(r[0][i["status"]]) + "|" + str(r[0][i["interval_secs"]]))' "$TMPD/ans.json" "$2"; }
# exec: $RUNPID is the collector itself (R stops it; a subshell's pid would leave it running)
startrun() { (exec "$TMPD/pgvigil" run -config "$CFGD/pgvigil.yaml") >>"$TMPD/run.log" 2>&1 & RUNPID=$!; }

echo "== A. the monitored server =="
docker run -d --name "$PGM" --label "$LBL" --env-file "$TMPD/pg.env" -p 127.0.0.1::5432 "$IMG_PG" -c shared_preload_libraries=pg_stat_statements >/dev/null
PP=$(docker port "$PGM" 5432/tcp | head -1 | sed 's/.*://')
for _ in $(seq 1 60); do mq 'select 1' >/dev/null 2>&1 && break; sleep 1; done; mq 'select 1' >/dev/null || fail "A: PostgreSQL did not come up"
mq "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
PDOWN=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
ok "A: PostgreSQL 16 on $PP with pg_stat_statements; nothing listens on $PDOWN"

echo "== B. the build, the repository, serve, the collector =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git --exclude=./bin -cf - . | tar -C "$GSRC" -xf -
P12=scripts/st12-wiring.patch; P5=scripts/st5-wiring.patch
has5() { grep -q 's.instanceSettings(w, r, user, in, pay)' "$GSRC/internal/web/q_instances_admin.go"; }
has12() { grep -q 'instanceRights(w, r, user, in)' "$GSRC/internal/web/q_instances_admin.go"; }
if [[ -n "${PROOF_RED:-}" ]]; then
  if has5; then (cd "$GSRC" && patch -R -p1 -s < "$P5") && echo "B: RED run - $P5 taken out of the run's copy (st12's wiring alone)"
  else has12 || (cd "$GSRC" && patch -p1 -s < "$P12"); echo "B: RED run - st12's wiring alone"; fi
elif has5; then echo "B: the tree holds both wirings (the patches are not applied)"
else has12 || (cd "$GSRC" && patch -p1 -s < "$P12") || fail "B: $P12 does not apply"
  (cd "$GSRC" && patch -p1 -s < "$P5") || fail "B: $P5 does not apply"; echo "B: $P12 and $P5 applied to the run's copy"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "B: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "B: the build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFGD=$TMPD/etc; mkdir -p "$CFGD"
export ST5_PG_DSN="host=127.0.0.1 port=$PP user=postgres password=$PG_PW dbname=postgres"
cat > "$CFGD/pgvigil.yaml" <<EOF
repository:
  dsn: "$PGDSN"
schedules:
  dbstats: 0
instances:
  - {name: f-pg, dsn: env:ST5_PG_DSN}
EOF
"$TMPD/pgvigil" migrate -config "$CFGD/pgvigil.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$CFGD/pgvigil.yaml" "$USR" >/dev/null 2>&1 || fail "B: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
(umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/pgvigil.yaml" -listen "127.0.0.1:$PORT") >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "B: serve exited"; }
P_USR="$USR" P_UPW="$UPW" python3 -c 'import json, os, sys; json.dump({"username": os.environ["P_USR"], "password": os.environ["P_UPW"]}, open(sys.argv[1], "w"))' "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "B: the UI login"
A="engine=postgres host=127.0.0.1 port=$PP dbname=postgres auth=password login=postgres"
for n in p-a p-b; do code=$(api POST admin/instances "$(js op=add name=$n $A password=@PG_PW)"); [[ "$code" == 200 ]] || fail "B: add $n: $code $(cat "$TMPD/ans.json")"; done
ok "B: built, migrated, serve on $PORT, signed in as $USR; p-a and p-b added"

if [[ -n "${PROOF_RED:-}" ]]; then
  echo "== S1 RED on the base: op 'settings' =="
  code=$(settings p-a '{"schedules": {"statements": 60}}')
  if [[ "$code" == 200 || "$code" == 409 ]]; then fail "S1 RED: the base answered op 'settings' ($code $(head -c 200 "$TMPD/ans.json")): the row is not red on it"; fi
  echo "RED as expected: op 'settings' on the base -> $code $(head -c 200 "$TMPD/ans.json")"
  exit 0
fi

startrun
for _ in $(seq 1 60); do [[ "$(snapat p-a activity)" != none && "$(snapat p-b activity)" != none ]] && break; sleep 3; done
[[ "$(snapat p-a activity)" != none && "$(snapat p-b activity)" != none ]] || { tail -30 "$TMPD/run.log" >&2; fail "B: the collector did not read p-a and p-b within 3 minutes"; }
RUN1=$RUNPID
ok "B: the collector (pid $RUN1) reads p-a and p-b"

echo "== S1. statements and dbstats every minute on p-a =="
code=$(settings p-a '{"schedules": {"statements": 60, "dbstats": 60}}')
[[ "$code" == 200 && "$(ans outcome)" == done && "$(ans detail)" == "settings of p-a saved: dbstats every 60 s, statements every 60 s" ]] || fail "S1: the write: $code $(cat "$TMPD/ans.json")"
watch 240 p-a:statements p-a:dbstats p-b:statements p-b:dbstats
S1A=$(runs p-a:statements); S1D=$(runs p-a:dbstats); S1B=$(runs p-b:statements); S1BD=$(snapat p-b dbstats)
kill -0 "$RUN1" 2>/dev/null || fail "S1: the collector exited"
(( S1A >= 3 && S1D >= 3 && S1B <= 1 )) && [[ "$S1BD" == none ]] || fail "S1: in 4 minutes p-a statements $S1A runs, p-a dbstats $S1D, p-b statements $S1B (want >= 3, >= 3, <= 1); p-b dbstats $S1BD (want none)"
ok "S1: in 4 minutes p-a's statements ran $S1A times and its dbstats $S1D (the file's global 0 under its own 1m); p-b's statements $S1B, its dbstats never; the collector's pid kept ($RUN1)"

echo "== S2. activity off on p-a, then its default =="
code=$(settings p-a '{"schedules": {"statements": 60, "dbstats": 60, "activity": 0}}'); [[ "$code" == 200 ]] || fail "S2: off: $code $(cat "$TMPD/ans.json")"
sleep 20
watch 120 p-a:activity p-b:activity
S2A=$(runs p-a:activity); S2B=$(runs p-b:activity); S2C=$(coldates p-a activity)
(( S2A == 0 && S2B >= 1 )) && [[ "$S2C" == "disabled|0" ]] || fail "S2: off for 2 minutes: p-a activity $S2A runs (want 0), p-b $S2B (want >= 1); Collection Dates for p-a's activity $S2C (want disabled|0)"
code=$(settings p-a '{"schedules": {"statements": 60, "dbstats": 60}}'); [[ "$code" == 200 ]] || fail "S2: back: $code $(cat "$TMPD/ans.json")"
watch 120 p-a:activity; S2D=$(runs p-a:activity)
(( S2D >= 1 )) || fail "S2: back to its default: p-a activity $S2D runs in 2 minutes (want >= 1)"
ok "S2: activity off on p-a: 0 runs in 2 minutes beside p-b's $S2B, Collection Dates '$S2C'; at its default again it ran $S2D time(s) in 2 minutes"

echo "== M1. a long interval is not stale =="
code=$(settings p-a '{"schedules": {"statements": 60, "dbstats": 60, "activity": 3600}}'); [[ "$code" == 200 ]] || fail "M1: $code $(cat "$TMPD/ans.json")"
sleep 20
pq "UPDATE pgvigil.collection_dates d SET snapshot_at = now() - interval '30 minutes' FROM pgvigil.instances i WHERE i.instance_id = d.instance_id AND i.name = 'p-a' AND d.collection = 'activity'" >/dev/null
M1A=$(coldates p-a activity); M1B=$(coldates p-b activity)
[[ "$M1A" == "ok|3600" && "$M1B" == *"|60" ]] || fail "M1: Collection Dates: p-a activity $M1A (want ok|3600), p-b activity $M1B (want <status>|60)"
ok "M1: p-a's activity at 1h, its last run 30 minutes old: '$M1A'; p-b's '$M1B'"

echo "== S3. query_text none on p-a =="
docker exec -d "$PGM" psql -U postgres -c "SELECT pg_sleep(900) /* st5a-marker */" >/dev/null
for _ in $(seq 1 20); do SPID=$(mq "SELECT pid FROM pg_stat_activity WHERE query LIKE '%st5a-marker%' AND pid <> pg_backend_pid() LIMIT 1"); [[ -n "$SPID" ]] && break; sleep 1; done
[[ -n "$SPID" ]] || fail "S3: the sleeping session did not start"
code=$(settings p-a '{"schedules": {"statements": 60, "dbstats": 60}, "query_text": "none"}'); [[ "$code" == 200 ]] || fail "S3: $code $(cat "$TMPD/ans.json")"
T3=$(pq "SELECT now()::text"); sleep 150
S3N=$(pq "SELECT count(*) FROM pgvigil.activity_sample a JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'p-a' AND a.pid = $SPID AND a.snapshot_at > '$T3'::timestamptz + interval '20 seconds'")
S3T=$(pq "SELECT count(*) FROM pgvigil.activity_sample a JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'p-a' AND a.pid = $SPID AND a.snapshot_at > '$T3'::timestamptz + interval '20 seconds' AND a.query_hash IS NOT NULL")
S3B=$(pq "SELECT count(*) FROM pgvigil.activity_sample a JOIN pgvigil.instances i USING (instance_id) JOIN pgvigil.query_text q ON q.query_hash = a.query_hash WHERE i.name = 'p-b' AND a.pid = $SPID AND q.query LIKE '%st5a-marker%'")
(( S3N >= 1 && S3T == 0 && S3B >= 1 )) || fail "S3: p-a's samples of the session after the change $S3N (want >= 1), with text $S3T (want 0); p-b's with the marker's text $S3B (want >= 1)"
ok "S3: query_text none on p-a: $S3N sample(s) of the sleeping session after the change, none with text; p-b's $S3B with the marker's text"

echo "== S4. refusals =="
R0=$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance settings' AND outcome = 'refused'")
NR=0
refuse() { local code; code=$(settings "$1" "$2"); [[ "$code" == 409 && "$(ans outcome)" == refused && "$(ans detail)" == "$3"* ]] || fail "S4: $1 $2: $code $(cat "$TMPD/ans.json") (want 409 '$3...')"; NR=$((NR + 1)); }
refuse p-a '{"schedules": {"statements2": 60}}' 'unknown collection "statements2"'
refuse p-a '{"schedules": {"mssql_activity": 60}}' '"mssql_activity" is a sqlserver collection and the instance'"'"'s engine is postgres'
refuse p-a '{"schedules": {"statements": 5}}' 'statements every 5s: an interval set here is a minute or more'
refuse p-a '{"schedules": {"statements": 2592060}}' 'the settings do not parse: its settings in Admin > Instances give statements 2592060'
refuse p-a '{"query_text": "raw"}' 'the settings do not parse: its settings in Admin > Instances give query_text "raw"'
refuse p-a '{"schedules": {"pgbouncer": 60}}' 'pgbouncer never runs on an instance added here: '
refuse f-pg '{}' 'f-pg is an instance of pgvigil.yaml'
MSA="engine=sqlserver host=127.0.0.1 port=$PDOWN dbname=master auth=sql login=sa"
code=$(api POST admin/instances "$(js op=add name=p-ms $MSA password=@PG_PW)")
if [[ "$code" == 200 ]]; then refuse p-ms '{"schedules": {"mssql_running_plans": 60}}' 'mssql_running_plans is the running plans box'"'"'s'; MSW="the running plans box's collection refused"
else notproven "S4: the running plans box's collection on a SQL Server page instance (the page did not add one to a server that is down: $code $(head -c 160 "$TMPD/ans.json"))"; MSW="(the SQL Server row not proven)"; fi
R1=$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance settings' AND outcome = 'refused'")
(( R1 - R0 == NR )) || fail "S4: $((R1 - R0)) refused audit rows for $NR refusals"
ok "S4: $NR refusals, each 409 with its words and one audit row; $MSW"

echo "== M5. amcheck opt-in, the catalogue =="
code=$(settings p-b '{"schedules": {"amcheck": 21600}}'); [[ "$code" == 200 && "$(ans detail)" == "settings of p-b saved: amcheck every 21600 s" ]] || fail "M5: amcheck on p-b: $code $(cat "$TMPD/ans.json")"
[[ "$(api GET admin/instances)" == 200 ]] || fail "M5: GET"
python3 - "$TMPD/ans.json" <<'PY' || fail "M5: the catalogue"
import json, sys
d = json.load(open(sys.argv[1])); c = d.get("settings_catalogue") or {}
pg = {x["name"]: x for x in c.get("postgres", [])}; ms = {x["name"]: x for x in c.get("sqlserver", [])}
bad = []
if pg.get("amcheck", {}).get("builtin_s") != 0 or pg.get("amcheck", {}).get("never"): bad.append(f"amcheck: {pg.get('amcheck')}")
if not pg.get("pgbouncer", {}).get("never"): bad.append(f"pgbouncer: {pg.get('pgbouncer')}")
if not ms.get("mssql_running_plans", {}).get("box"): bad.append(f"mssql_running_plans: {ms.get('mssql_running_plans')}")
if pg.get("dbstats", {}).get("default_s") != 0 or pg.get("dbstats", {}).get("builtin_s") != 60: bad.append(f"dbstats (the file's global 0): {pg.get('dbstats')}")
if d.get("settings_floor_s") != 60: bad.append(f"the floor: {d.get('settings_floor_s')}")
if bad: print("\n".join(bad)); sys.exit(1)
PY
ok "M5: amcheck set on p-b (opt-in, builtin 0); the catalogue: pgbouncer never here, mssql_running_plans the box's, dbstats 0 by the file's global line (its own 60), the floor 60 s"

echo "== R. the collector started again =="
kill "$RUN1"; for _ in $(seq 1 30); do kill -0 "$RUN1" 2>/dev/null || break; sleep 1; done; kill -0 "$RUN1" 2>/dev/null && fail "R: the collector did not stop"
startrun; RUN2=$RUNPID
watch 150 p-a:statements; RS=$(runs p-a:statements)
(( RS >= 2 )) || fail "R: after the start p-a's statements ran $RS times in 150 s (want >= 2: its 1m from the stored settings)"
ok "R: the collector stopped and started again (pid $RUN2): p-a's statements ran $RS times in 150 s"

echo "== P. the panel =="
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
  r.opened = await clickPrefix('Settings of p-a');
  r.box = await until(`!!document.querySelector('#admin-instance-settings table')`, 20);
  r.statements = await ev(`document.querySelector('#admin-instance-settings input[aria-label^="statements: interval"]')?.value ?? null`);
  r.qt = await ev(`document.querySelector('#admin-settings-qt')?.value ?? null`);
  if (theme === 'light') {
    r.set = await ev(`(() => { const i = document.querySelector('#admin-instance-settings input[aria-label^="dbstats: interval"]'); if (!i) return false; i.value = '2h'; return true; })()`);
    r.saved = await clickPrefix('Save the settings of p-a');
    r.status = await until(`/saved/.test(document.querySelector('.admin-instances p[role=status]')?.textContent ?? '')`, 20)
      ? await ev(`document.querySelector('.admin-instances p[role=status]')?.textContent ?? ''`) : await ev(`document.querySelector('.admin-instances p[role=status]')?.textContent ?? ''`);
    await sleep(500);
    r.reopened = await clickPrefix('Settings of p-a');
    await until(`!!document.querySelector('#admin-instance-settings table')`, 20);
  }
  r.errors = await ev(`document.querySelectorAll('main .error:not([role=status])').length`);
  await cmd('Runtime.evaluate', { expression: axeSrc });
  r.violations = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: v.nodes.slice(0, 3).map(n => n.target.join(' ')) }))))`, true));
  out[theme] = r;
}
console.log(JSON.stringify(out));
process.exit(0);
JS
  P_USR="$USR" P_UPW="$UPW" node "$TMPD/p.mjs" "$CDP" "$U/" "$TMPD/node_modules/axe-core/axe.min.js" > "$TMPD/page.json" 2> "$TMPD/page.err" || fail "P: the page check did not run: $(tail -c 400 "$TMPD/page.err")"
  kill "$CHRPID" 2>/dev/null || true; CHRPID=
  DB2H=$(pq "SELECT coalesce(settings->'schedules'->>'dbstats', 'none') FROM pgvigil.admin_instances WHERE name = 'p-a'")
  DB2H="$DB2H" python3 - "$TMPD/page.json" <<'PY' || fail "P: the page"
import json, os, sys
d = json.load(open(sys.argv[1])); bad = []
if d.get("login") != 200: bad.append(f"the page's sign-in answered {d.get('login')}")
for theme in ("light", "dark"):
    r = d[theme]
    if not r.get("drawn") or r.get("errors"): bad.append(f"{theme}: drawn {r.get('drawn')}, error boxes {r.get('errors')}")
    if not r.get("opened") or not r.get("box"): bad.append(f"{theme}: the Settings link {r.get('opened')}, the box {r.get('box')}")
    if r.get("statements") != "1m": bad.append(f"{theme}: statements in the box {r.get('statements')!r} (want '1m')")
    if r.get("qt") != "none": bad.append(f"{theme}: query_text in the box {r.get('qt')!r} (want 'none')")
    n = sum(v["n"] for v in r.get("violations") or [])
    if n: bad.append(f"{theme}: {n} axe violation node(s): {r['violations']}")
l = d["light"]
if not l.get("set") or not l.get("saved") or "saved" not in (l.get("status") or ""): bad.append(f"light: dbstats set {l.get('set')}, Save {l.get('saved')}, the status {l.get('status')!r}")
if os.environ["DB2H"] != "7200": bad.append(f"dbstats stored after the page's save: {os.environ['DB2H']} (want 7200)")
if bad: print("\n".join(bad)); sys.exit(1)
print(f"ok   P: light and dark: Settings of p-a opens the box (statements 1m, query_text none); the page's save of dbstats 2h stored 7200 ({l['status']!r}); no error box; 0 axe violation nodes")
PY
else
  notproven "P: chromium or node is not on this machine (the panel was not opened)"
fi

echo "== L. the password in no answer or log =="
for f in "$TMPD"/answers/* "$TMPD/serve.log" "$TMPD/run.log"; do grep -q -F -- "$PG_PW" "$f" && fail "L: the monitored server's password is in $(basename "$f")"; done
ok "L: the password is in none of the $(ls "$TMPD"/answers | wc -l) answers, serve's log or the collector's log"
echo "ALL ROWS GREEN"
