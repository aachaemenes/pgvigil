#!/usr/bin/env bash
# Proof of Admin > Instances' 'Check all' and 'Rights' (the ServiceConfig takes, ST1 and ST2): migration 0261,
# internal/web/q_instances_checks.go and q_instances_rights.go, the rights catalogues internal/mssql/rights.go and
# internal/collect/rights.go, web/src/admin_checks.ts, and their hunks in the two shared files
# (scripts/st12-wiring.patch: applied to the run's own copy when the tree does not hold them).
#
# Expected (written before the first run):
#  C1  Check all. pgvigil.yaml holds eight instances: f-sql (SQL Server 2022, a login with every right), f-pg
#      (PostgreSQL 16), f-down (a port nothing listens on), f-bad (a dsn that does not parse, a password in it) and the
#      four of the Rights rows (f-bare, f-bare2, f-odd, f-pgmon: each connects); the page holds p-up and p-off (added
#      through the API; p-off disabled).
#      a  (the API, one test each) op 'test' of f-sql and f-pg answers ok true 'connected: ...'; of f-down ok false
#         with the connect error, inside 10 seconds; each result is kept (the part 'checks': tested_ok true / true /
#         false) and audited ('instance tested', done); no answer and no 'checks' row holds a password or a dsn.
#         RED on the base (PROOF_RED_C1=1, a build without this branch's wiring): op 'test' of f-down is refused with
#         400 - the base tests no instance of the file.
#      b  after one collection of f-sql and of f-pg: their 'checks' rows hold last_collected and an age of 0 to 120 s
#         equal to the repository's own (within 5 s); f-down's hold none; a collection of f-pg that ended in an error
#         (put into collection_dates by hand) shows failing_n 1 with its name and note.
#      d  f-bad: op 'test' and op 'rights' answer ok false with the fixed words 'the instance's dsn in pgvigil.yaml does
#         not parse (its text is not shown: it may hold a password)'; its password is in no answer, row or log.
#      c  (the page, light) the button 'Check all' fills each row's 'last test' and ends 'Checked 9: 7 connected, 2
#         failed; 1 disabled, not checked.' (the eight of the file and p-up; f-down and f-bad fail); p-off was not asked (its row keeps tested_at NULL, no audit row); after a
#         reload both tables still show the results; 'last collected' reads '<n> second(s)|minute(s) ago' for f-sql.
#  C2  the page's gate (this base has no reader / admin split): op 'test' and op 'rights' without the X-Pgvigil header
#      answer 403, without a session 401; op 'rights' of a name that is neither the page's nor the file's answers ok
#      false 'no instance ...'.
#  R1  f-sql (a login granted every right the catalogue names): Rights answers missing 0, missing_needed 0, an empty
#      script, sp_WhoIsActive 'not installed'.
#  R2  (RED first) f-bare (a login of the public role only): mssql_jobs is skipped for it; Rights lists as missing
#      VIEW SERVER STATE, VIEW ANY DEFINITION, msdb, CONNECT ANY DATABASE (needed; the database it cannot enter
#      named) and, of the optional ones, ALTER TRACE and VIEW SERVER SECURITY AUDIT. It HOLDS the two registry rights
#      and SELECT on restorehistory: SQL Server grants xp_instance_regread and xp_regread to public, and every login
#      reads restorehistory through msdb's guest (the first run wanted them missing: the expectation was wrong, the
#      read right). The script, run by sa exactly as printed, makes the next Rights read missing 0 with an empty
#      script, and mssql_jobs ends ok.
#  R3  f-odd (a login whose name holds a ']' and a space, public only): the script names it as QUOTENAME does and runs
#      as printed; then missing 0.
#  R4  f-pgmon (PostgreSQL 16, a role whose name holds a '"', a capital and a space, without pg_monitor; a database
#      it may not connect to): Rights lists pg_monitor and CONNECT (that database named) as missing, and the
#      optional log and pg_hba rights; the script, run by the superuser as printed, makes the next read missing 0.
#  R5  the read writes nothing: the bare login's server and database permissions and role memberships (SQL Server),
#      the role's memberships and the count of functions named pgvigil_read_log (PostgreSQL), read before and after
#      ten Rights reads, are equal; f-down's Rights answers ok false with the connect error; every Rights click has
#      its audit row ('instance rights').
#  P   (the page, light and dark, signed in) the Rights link of f-bare2 (a second bare login, never granted) fills the
#      box with the list and the script; 'Copy the GRANT script' is there; the page draws with no error box; axe-core 4.14.0
#      (WCAG 2.1 A and AA) 0 violation nodes with the box open. Skipped (NOT PROVEN) without chromium and node.
#  R7  (the review's F1) a database whose name holds a line break, made by sa: Rights of f-bare2 lists its rights and
#      prints NO script, with the reason 'no script is printed: a name this server answered ... holds a line break or
#      a control character ...'; the database is dropped after.
#  R6 is the build's own row (the catalogue tests, red first with a planted check): not rerun here.
#
# Needs: docker (SQL Server 2022 Developer, PostgreSQL 16), psql, curl, python3, a go toolchain, node and npm (the web
# bundle; chromium for C1c and P), and ADMIN_DSN: a superuser keyword DSN of a PostgreSQL sandbox for the repository.
# Everything the run makes carries its random suffix and is removed on every exit path the shell can catch. Every
# password is made at run time and reaches the tools through environment files, the environment or stdin.
#
# NOT PROVEN HERE: Azure SQL Database, Azure SQL Managed Instance, Amazon RDS (which rights are listed there is the
# catalogues' unit tests); SQL Server before 2022 (the audit's row says why); Windows.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
IMG_PG=postgres:16
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvcr-sql-$SUF; PGM=pgvcr-pg-$SUF; LBL=pgvigil-proof=st12
PGDB=pgv_cr_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=
SA_PW=$(pw); FULL_PW=$(pw); BARE_PW=$(pw); ODD_PW=$(pw); PG_PW=$(pw); MON_PW=$(pw); UPW=$(pw); BAD_PW=$(pw)
export PG_PW
printf 'ACCEPT_EULA=Y\nMSSQL_AGENT_ENABLED=true\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
printf 'POSTGRES_PASSWORD=%s\n' "$PG_PW" > "$TMPD/pg.env"
cleanup() {
  rc=$?
  set +e
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null; wait "$CHRPID" 2>/dev/null; fi
  for c in "$SQL" "$PGM"; do docker rm -f -v "$c" >/dev/null 2>&1 || { docker inspect "$c" >/dev/null 2>&1 && echo "CLEANUP: container $c not removed" >&2; }; done
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  rm -rf "$TMPD"
  echo "left: containers $(docker ps -aq --filter "name=pgvcr-.*-$SUF" | wc -l)"
  exit $rc
}
trap cleanup EXIT
# a command that fails without a message of its own says where (set -e would end the proof without a word)
trap 'echo "FAIL: the proof stopped at line $LINENO: a command failed without its own message" >&2' ERR
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# sq: T-SQL as sa through stdin (the password from the container's own environment file)
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
# sqfile FILE: a script as sa, exactly as the file holds it
sqfile() { docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -d master -i /dev/stdin' < "$1"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
# mq: SQL on the monitored PostgreSQL as its superuser
mq() { PGPASSWORD="$PG_PW" psql "host=127.0.0.1 port=$PP user=postgres dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for t in docker go psql curl python3 npm; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"
# js: a JSON body from key=value pairs; a value @NAME is the environment variable NAME
js() { python3 -c 'import json, os, sys
d = {}
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    d[k] = os.environ[v[1:]] if v.startswith("@") else v
print(json.dumps(d))' "$@"; }
# api METHOD path [body]: the answer in $TMPD/ans.json, the code printed. Every answer is kept too under
# $TMPD/answers/ for the leak check, each under a name of its own (api mostly runs inside \$(...), a subshell: a shell
# counter would not move there and the answers would overwrite each other)
mkdir -p "$TMPD/answers"
api() { local code; if [[ $# -ge 3 ]]; then printf '%s' "$3" > "$TMPD/body.json"; code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -X "$1" --data @"$TMPD/body.json" "$U/api/$2");
  else code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" "$U/api/$2"); fi; cp "$TMPD/ans.json" "$(mktemp "$TMPD/answers/XXXXXXXX")"; echo "$code"; }
ans() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); v = d
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list)) else v))' "$TMPD/ans.json" "$1"; }
# check NAME COL: a column of the instance's row in the part 'checks' of the last GET admin/instances
check() { python3 -c 'import json, sys; t = json.load(open(sys.argv[1]))["checks"]; i = {c: n for n, c in enumerate(t["columns"])}
r = [r for r in t["rows"] if r[i["name"]] == sys.argv[2]]
v = r[0][i[sys.argv[3]]] if r else "NO ROW"
print("" if v is None else v)' "$TMPD/ans.json" "$1" "$2"; }
# rights NAME: op rights; state KEY: a right's state in the answer; missing: the keys missing, sorted
rights() { api POST admin/instances "$(js op=rights name="$1")"; }
state() { python3 -c 'import json, sys; t = json.load(open(sys.argv[1])).get("rights") or {"columns": [], "rows": []}; i = {c: n for n, c in enumerate(t["columns"])}
print(next((r[i["state"]] for r in t["rows"] if r[i["key"]] == sys.argv[2]), "NO ROW"))' "$TMPD/ans.json" "$1"; }
missing() { python3 -c 'import json, sys; t = json.load(open(sys.argv[1])).get("rights") or {"columns": [], "rows": []}; i = {c: n for n, c in enumerate(t["columns"])}
print(" ".join(sorted(r[i["key"]] for r in t["rows"] if r[i["state"]] == "missing")))' "$TMPD/ans.json"; }
script() { python3 -c 'import json, sys; sys.stdout.write(json.load(open(sys.argv[1])).get("script") or "")' "$TMPD/ans.json"; }
collect() { "$TMPD/pgvigil" collect -config "$CFGD/pgvigil.yaml" -once "$1" -instance "$2" > "$TMPD/collect.out" 2>&1 || true; }
colstate() { pq "SELECT coalesce((SELECT d.status FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND d.collection = '$2'), 'none')"; }

echo "== A. the servers =="
docker run -d --name "$SQL" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
docker run -d --name "$PGM" --label "$LBL" --env-file "$TMPD/pg.env" -p 127.0.0.1::5432 "$IMG_PG" >/dev/null
up() { local r=; for _ in $(seq 1 90); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" msdb 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done; fail "the SQL Server container did not open msdb in 180 s"; }
up
PS=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://'); PP=$(docker port "$PGM" 5432/tcp | head -1 | sed 's/.*://')
for _ in $(seq 1 60); do mq 'select 1' >/dev/null 2>&1 && break; sleep 1; done; mq 'select 1' >/dev/null || fail "A: PostgreSQL did not come up"
PDOWN=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')   # free now: nothing listens there
FULL=pgc_full_$SUF; BARE=pgc_bare_$SUF; BARE2=pgc_bare2_$SUF; ODD="pgc ]odd $SUF"; UDB=pgcdb_$SUF
ODDQ="[pgc ]]odd $SUF]"
sqok "A: the logins" "CREATE DATABASE [$UDB];
  CREATE LOGIN [$FULL] WITH PASSWORD = '$FULL_PW', CHECK_POLICY = OFF; CREATE LOGIN [$BARE] WITH PASSWORD = '$BARE_PW', CHECK_POLICY = OFF;
  CREATE LOGIN [$BARE2] WITH PASSWORD = '$BARE_PW', CHECK_POLICY = OFF; CREATE LOGIN $ODDQ WITH PASSWORD = '$ODD_PW', CHECK_POLICY = OFF;
  GRANT VIEW SERVER STATE TO [$FULL]; GRANT VIEW ANY DEFINITION TO [$FULL]; GRANT CONNECT ANY DATABASE TO [$FULL]; GRANT ALTER TRACE TO [$FULL];
  GRANT VIEW SERVER SECURITY AUDIT TO [$FULL];
  CREATE USER [$FULL] FOR LOGIN [$FULL]; GRANT EXECUTE ON dbo.xp_instance_regread TO [$FULL]; GRANT EXECUTE ON dbo.xp_regread TO [$FULL];"
sqok "A: the full login's msdb user" "CREATE USER [$FULL] FOR LOGIN [$FULL]; ALTER ROLE db_datareader ADD MEMBER [$FULL];" msdb
PMON="Pgc \"Mon $SUF"; PMONQ="\"Pgc \"\"Mon $SUF\""; CDB=pgc_closed_$SUF
printf "CREATE ROLE %s LOGIN PASSWORD '%s';\n" "$PMONQ" "$MON_PW" | PGPASSWORD="$PG_PW" psql "host=127.0.0.1 port=$PP user=postgres dbname=postgres" -Xq -v ON_ERROR_STOP=1 >/dev/null; mq "CREATE DATABASE $CDB" >/dev/null; mq "REVOKE CONNECT ON DATABASE $CDB FROM PUBLIC" >/dev/null
ok "A: SQL Server on $PS (logins $FULL, $BARE, $BARE2, '$ODD'; a user database $UDB), PostgreSQL on $PP (the role '$PMON' without pg_monitor; $CDB closed to PUBLIC); nothing listens on $PDOWN"

echo "== B. the build, the repository, serve =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git --exclude=./bin -cf - . | tar -C "$GSRC" -xf -
P=scripts/st12-wiring.patch
if [[ -n "${PROOF_RED_C1:-}" ]]; then echo "B: RED run - the wiring is NOT applied (the base's op 'test')"
elif grep -q 'instanceRights(w, r, user, in)' "$GSRC/internal/web/q_instances_admin.go"; then echo "B: the tree holds the wiring (the patch is not applied)"
elif (cd "$GSRC" && patch -p1 --dry-run -s < "$P" >/dev/null); then (cd "$GSRC" && patch -p1 -s < "$P") && echo "B: $P applied to the run's copy"
else fail "B: the tree has no op 'rights' and $P does not apply"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "B: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "B: the build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFGD=$TMPD/etc; mkdir -p "$CFGD"
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
msdsn() { echo "sqlserver://$(enc "$1"):$(enc "$2")@127.0.0.1:$PS?database=master&encrypt=true&TrustServerCertificate=true"; }
export CR_SQL_DSN="$(msdsn "$FULL" "$FULL_PW")" CR_BARE_DSN="$(msdsn "$BARE" "$BARE_PW")" CR_BARE2_DSN="$(msdsn "$BARE2" "$BARE_PW")" CR_ODD_DSN="$(msdsn "$ODD" "$ODD_PW")"
export CR_PG_DSN="host=127.0.0.1 port=$PP user=postgres password=$PG_PW dbname=postgres"
export CR_PGMON_DSN="host=127.0.0.1 port=$PP user='$PMON' password=$MON_PW dbname=postgres"
export CR_DOWN_DSN="host=127.0.0.1 port=$PDOWN user=postgres password=$PG_PW dbname=postgres"
# a dsn that does not parse (sslmode's value misspelled), its password written with spaces around '=': pgconn's own
# masking does not catch that spelling, so its parse error would carry the password (the review's F4)
export CR_BAD_DSN="host=127.0.0.1 port=$PP user=postgres password = '$BAD_PW' dbname=postgres sslmode=verify-ful"
cat > "$CFGD/pgvigil.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - {name: f-sql, engine: sqlserver, dsn: env:CR_SQL_DSN}
  - {name: f-bare, engine: sqlserver, dsn: env:CR_BARE_DSN}
  - {name: f-bare2, engine: sqlserver, dsn: env:CR_BARE2_DSN}
  - {name: f-odd, engine: sqlserver, dsn: env:CR_ODD_DSN}
  - {name: f-pg, dsn: env:CR_PG_DSN}
  - {name: f-pgmon, dsn: env:CR_PGMON_DSN}
  - {name: f-down, dsn: env:CR_DOWN_DSN}
  - {name: f-bad, dsn: env:CR_BAD_DSN}
EOF
"$TMPD/pgvigil" migrate -config "$CFGD/pgvigil.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$CFGD/pgvigil.yaml" "$USR" >/dev/null 2>&1 || fail "B: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
(umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/pgvigil.yaml" -listen "127.0.0.1:$PORT") >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "B: serve exited"; }
P_USR="$USR" P_UPW="$UPW" python3 -c 'import json, os, sys; json.dump({"username": os.environ["P_USR"], "password": os.environ["P_UPW"]}, open(sys.argv[1], "w"))' "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "B: the UI login"
ok "B: built, migrated, serve on $PORT, signed in as $USR"

if [[ -n "${PROOF_RED_C1:-}" ]]; then
  echo "== C1a RED on the base: op 'test' of a file instance =="
  code=$(api POST admin/instances "$(js op=test name=f-down)")
  if [[ "$code" == 200 && "$(ans ok)" == False ]]; then fail "C1a RED: the base answered a file instance's test ($code $(head -c 200 "$TMPD/ans.json")): the row is not red on it"; fi
  echo "RED as expected: op 'test' of f-down on the base -> $code $(head -c 200 "$TMPD/ans.json")"
  exit 0
fi

echo "== C1. Check all =="
A="engine=postgres host=127.0.0.1 port=$PP dbname=postgres auth=password login=postgres"
for n in p-up p-off; do code=$(api POST admin/instances "$(js op=add name=$n $A password=@PG_PW)"); [[ "$code" == 200 ]] || fail "C1: add $n: $code $(cat "$TMPD/ans.json")"; done
code=$(api POST admin/instances "$(js op=disable name=p-off)"); [[ "$code" == 200 ]] || fail "C1: disable p-off: $code $(cat "$TMPD/ans.json")"
# a: the API, one test each
for n in f-sql f-pg; do code=$(api POST admin/instances "$(js op=test name=$n)"); [[ "$code" == 200 && "$(ans ok)" == True && "$(ans detail)" == connected:* && "$(ans kept)" == True ]] || fail "C1a: test $n: $code $(cat "$TMPD/ans.json")"; done
T0=$(date +%s); code=$(api POST admin/instances "$(js op=test name=f-down)"); T1=$(date +%s)
[[ "$code" == 200 && "$(ans ok)" == False && -n "$(ans detail)" && $((T1 - T0)) -le 10 ]] || fail "C1a: test f-down: $code in $((T1 - T0)) s $(cat "$TMPD/ans.json")"
DOWN=$(ans detail | head -c 100)
[[ "$(api GET admin/instances)" == 200 ]] || fail "C1a: GET: $(head -c 300 "$TMPD/ans.json")"
[[ "$(check f-sql tested_ok)|$(check f-pg tested_ok)|$(check f-down tested_ok)|$(check f-sql source)|$(check p-up source)" == "True|True|False|file|page" ]] \
  || fail "C1a: the kept results: f-sql $(check f-sql tested_ok), f-pg $(check f-pg tested_ok), f-down $(check f-down tested_ok); sources $(check f-sql source) / $(check p-up source)"
NA=$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance tested' AND outcome = 'done' AND target IN ('f-sql', 'f-pg', 'f-down')")
[[ "$NA" == 3 ]] || fail "C1a: $NA audit rows of the three tests, want 3"
BADW="the instance's dsn in pgvigil.yaml does not parse (its text is not shown: it may hold a password)"
code=$(api POST admin/instances "$(js op=test name=f-bad)"); [[ "$code" == 200 && "$(ans ok)" == False && "$(ans detail)" == "$BADW" ]] || fail "C1d: test f-bad: $code $(cat "$TMPD/ans.json")"
code=$(rights f-bad); [[ "$code" == 200 && "$(ans ok)" == False && "$(ans detail)" == "$BADW" ]] || fail "C1d: Rights of f-bad: $code $(cat "$TMPD/ans.json")"
ok "C1d: f-bad's dsn does not parse: Test and Rights answer '$BADW'"
ok "C1a: op 'test' of the file's instances: f-sql and f-pg connected, f-down failed in $((T1 - T0)) s ('$DOWN'); the three results kept and audited"
# b: the ages
collect mssql_instance f-sql; collect activity f-pg
pq "INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, duration_ms, status, note)
    SELECT instance_id, 'proof_failing', now(), 1, 'error', 'the proof: a collection that fails now' FROM pgvigil.instances WHERE name = 'f-pg'" >/dev/null
[[ "$(api GET admin/instances)" == 200 ]] || fail "C1b: GET"
for n in f-sql f-pg; do
  AGE=$(check $n collected_age_s); OWN=$(pq "SELECT extract(epoch FROM now() - max(d.snapshot_at))::bigint FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$n' AND d.status = 'ok'")
  [[ "$AGE" =~ ^[0-9]+$ && "$AGE" -le 120 && $((OWN - AGE)) -ge 0 && $((OWN - AGE)) -le 5 ]] || fail "C1b: $n's age '$AGE' s, the repository's own $OWN s (collect: $(tail -2 "$TMPD/collect.out"))"
done
[[ -z "$(check f-down last_collected)" && "$(check f-down failing_n)" == 0 ]] || fail "C1b: f-down: last_collected '$(check f-down last_collected)', failing $(check f-down failing_n)"
[[ "$(check f-pg failing_n)|$(check f-pg failing_collection)|$(check f-pg failing_note)" == "1|proof_failing|the proof: a collection that fails now" ]] || fail "C1b: f-pg's failing: $(check f-pg failing_n)|$(check f-pg failing_collection)|$(check f-pg failing_note)"
ok "C1b: f-sql and f-pg collected: their ages by the repository's clock (f-sql $(check f-sql collected_age_s) s); f-down none; f-pg's failing collection named with its note"

echo "== C2. the page's gate =="
for op in test rights; do
  c1=$(curl -s -o "$TMPD/g1.json" -w '%{http_code}' -b "$TMPD/cj" -H 'Content-Type: application/json' --data "$(js op=$op name=f-pg)" "$U/api/admin/instances")
  c2=$(curl -s -o "$TMPD/g2.json" -w '%{http_code}' -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$(js op=$op name=f-pg)" "$U/api/admin/instances")
  [[ "$c1" == 403 && "$c2" == 401 ]] || fail "C2: op $op without the header $c1 (want 403), without a session $c2 (want 401)"
done
code=$(rights nobody-$SUF); [[ "$code" == 200 && "$(ans ok)" == False && "$(ans detail)" == *"no instance"* ]] || fail "C2: Rights of an unknown name: $code $(cat "$TMPD/ans.json")"
ok "C2: op 'test' and op 'rights' answer 403 without the X-Pgvigil header and 401 without a session; Rights of an unknown name: '$(ans detail)'"

echo "== R1. a login with every right =="
code=$(rights f-sql); [[ "$code" == 200 && "$(ans ok)" == True ]] || fail "R1: $code $(cat "$TMPD/ans.json")"
[[ "$(ans missing)|$(ans missing_needed)|$(script | wc -c)|$(ans login)" == "0|0|0|$FULL" && "$(state sp_whoisactive)" == "not installed:"* ]] \
  || fail "R1: missing $(ans missing) (needed $(ans missing_needed)): $(missing); sp_WhoIsActive '$(state sp_whoisactive)'; the script: $(script | head -5)"
ok "R1: f-sql as $FULL: nothing missing, no script; sp_WhoIsActive '$(state sp_whoisactive | cut -c1-40)...'"

echo "== R2. a login of the public role only (red first) =="
perms() { sq "SELECT (SELECT COUNT(*) FROM sys.server_permissions p JOIN sys.server_principals l ON l.principal_id = p.grantee_principal_id WHERE l.name = N'$1'),
  (SELECT COUNT(*) FROM sys.server_role_members m JOIN sys.server_principals l ON l.principal_id = m.member_principal_id WHERE l.name = N'$1'),
  (SELECT COUNT(*) FROM master.sys.database_principals WHERE name = N'$1'), (SELECT COUNT(*) FROM msdb.sys.database_principals WHERE name = N'$1')" | tr -d ' \r'; }
P0=$(perms "$BARE")
collect mssql_jobs f-bare; J0=$(colstate f-bare mssql_jobs)
code=$(rights f-bare); [[ "$code" == 200 && "$(ans ok)" == True ]] || fail "R2: $code $(cat "$TMPD/ans.json")"
M0=$(missing); N0=$(ans missing_needed)
WANT="audit_events database_access default_trace msdb_reader view_any_definition view_server_state"
HELD="$(state registry_instance)|$(state registry_machine)|$(state restore_history)"
[[ "$M0" == "$WANT" && "$N0" == 4 && "$J0" == skipped && "$HELD" == "held|held|held" ]] || fail "R2 before: missing '$M0' (want '$WANT'), needed $N0 (want 4), the registry rights and restorehistory '$HELD' (want held|held|held), mssql_jobs '$J0' (want skipped): $(tail -2 "$TMPD/collect.out")"
script > "$TMPD/bare.sql"
grep -q "the login cannot enter: .*$UDB" "$TMPD/bare.sql" || fail "R2: the script does not name $UDB: $(grep -n 'cannot enter' "$TMPD/bare.sql")"
grep -q "pgvigil did not run it and never does" "$TMPD/bare.sql" || fail "R2: the script's head: $(head -3 "$TMPD/bare.sql")"
# R5 (SQL Server): ten reads change nothing
for _ in $(seq 1 10); do rights f-bare >/dev/null; done
P1=$(perms "$BARE"); [[ "$P1" == "$P0" ]] || fail "R5: the bare login's permissions before '$P0', after ten Rights reads '$P1'"
sqfile "$TMPD/bare.sql" > "$TMPD/bare.out" 2>&1 || fail "R2: the printed script did not run as sa: $(cat "$TMPD/bare.out")"
code=$(rights f-bare); [[ "$(ans missing)|$(script | wc -c)" == "0|0" ]] || fail "R2 after the script: missing $(ans missing): $(missing)"
collect mssql_jobs f-bare; J1=$(colstate f-bare mssql_jobs)
[[ "$J1" == ok ]] || fail "R2 after the script: mssql_jobs '$J1' (want ok): $(tail -2 "$TMPD/collect.out")"
ok "R2: f-bare as $BARE: mssql_jobs '$J0', 4 needed and 2 optional rights missing ($UDB named; the registry rights and restorehistory held through public and msdb's guest); the printed script ($(wc -l < "$TMPD/bare.sql") lines) run by sa as printed: nothing missing, mssql_jobs '$J1'"
ok "R5 (SQL Server): the login's permissions, role memberships and users ($P0) equal before and after ten Rights reads"

echo "== R3. a login whose name needs quoting =="
code=$(rights f-odd); [[ "$code" == 200 && "$(ans ok)" == True && "$(ans login)" == "$ODD" && "$(ans missing_needed)" == 4 ]] || fail "R3: $code $(cat "$TMPD/ans.json" | head -c 400)"
script > "$TMPD/odd.sql"
grep -qF "GRANT VIEW SERVER STATE TO $ODDQ;" "$TMPD/odd.sql" && grep -qF "DATABASE_PRINCIPAL_ID(N'$ODD')" "$TMPD/odd.sql" || fail "R3: the name in the script: $(grep -n 'GRANT VIEW SERVER STATE\|DATABASE_PRINCIPAL_ID' "$TMPD/odd.sql" | head -3)"
sqfile "$TMPD/odd.sql" > "$TMPD/odd.out" 2>&1 || fail "R3: the printed script did not run: $(cat "$TMPD/odd.out")"
code=$(rights f-odd); [[ "$(ans missing)" == 0 ]] || fail "R3 after the script: missing $(ans missing): $(missing)"
ok "R3: f-odd as '$ODD': the script names it $ODDQ and N'$ODD', runs as printed; then nothing missing"

echo "== R4. PostgreSQL: a role without pg_monitor =="
mem() { mq "SELECT (SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = '$(printf '%s' "$PMON" | sed "s/'/''/g")') || '|' || (SELECT count(*) FROM pg_proc WHERE proname = 'pgvigil_read_log')"; }
G0=$(mem)
code=$(rights f-pgmon); [[ "$code" == 200 && "$(ans ok)" == True && "$(ans login)" == "$PMON" ]] || fail "R4: $code $(cat "$TMPD/ans.json" | head -c 400)"
[[ "$(missing)" == "connect hba_rules pg_monitor server_log_list server_log_read" && "$(ans missing_needed)" == 2 ]] || fail "R4 before: missing '$(missing)', needed $(ans missing_needed)"
script > "$TMPD/pgmon.sql"
grep -qF "GRANT pg_monitor TO $PMONQ;" "$TMPD/pgmon.sql" && grep -qF "GRANT CONNECT ON DATABASE $CDB TO $PMONQ;" "$TMPD/pgmon.sql" || fail "R4: the script: $(grep -n 'GRANT pg_monitor\|GRANT CONNECT' "$TMPD/pgmon.sql")"
for _ in $(seq 1 10); do rights f-pgmon >/dev/null; done
G1=$(mem); [[ "$G1" == "$G0" ]] || fail "R5: the role's memberships and door functions before '$G0', after ten Rights reads '$G1'"
PGPASSWORD="$PG_PW" psql "host=127.0.0.1 port=$PP user=postgres dbname=postgres" -Xq -v ON_ERROR_STOP=1 -f "$TMPD/pgmon.sql" > "$TMPD/pgmon.out" 2>&1 || fail "R4: the printed script did not run: $(cat "$TMPD/pgmon.out")"
code=$(rights f-pgmon); [[ "$(ans missing)|$(script | wc -c)" == "0|0" ]] || fail "R4 after the script: missing $(ans missing): $(missing)"
ok "R4: f-pgmon as '$PMON': pg_monitor and CONNECT ($CDB named) and three optional rights missing; the printed script run by the superuser as printed: nothing missing"
code=$(rights f-down); [[ "$code" == 200 && "$(ans ok)" == False && -n "$(ans detail)" ]] || fail "R5: Rights of f-down: $code $(cat "$TMPD/ans.json")"
NR=$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance rights' AND outcome = 'done'")
[[ "$NR" -ge 28 ]] || fail "R5: $NR audit rows of the Rights clicks (want 28 or more)"
ok "R5 (PostgreSQL): the role's memberships and the door functions ($G0) equal before and after ten Rights reads; Rights of f-down: '$(ans detail | head -c 80)'; $NR Rights clicks audited"

echo "== the answers hold no password and no dsn =="
# grep answers 1 when it finds nothing - the good case here: its status is taken out of the pipeline (under
# pipefail the empty result ended the proof without a word)
# the passwords as a pattern file of mode 600 (grep -f): never on a command line
printf '%s\n' "$SA_PW" "$FULL_PW" "$BARE_PW" "$ODD_PW" "$PG_PW" "$MON_PW" "$UPW" "$BAD_PW" "sqlserver://" "password=" > "$TMPD/leak.pat"
HITS=$({ grep -lF -f "$TMPD/leak.pat" "$TMPD"/answers/* 2>/dev/null || true; } | sort -u | tr '\n' ' ')
[[ -z "$HITS" ]] || fail "a password or a connection string is in an API answer: $HITS"
NANS=$(ls "$TMPD/answers" | wc -l)
[[ "$NANS" -ge 39 ]] || fail "the leak check read $NANS saved answers (want 39 or more: every call of the run)"
pq "SELECT coalesce(detail, '') FROM pgvigil.admin_audit UNION ALL SELECT coalesce(tested_detail, '') FROM pgvigil.admin_file_tests UNION ALL SELECT coalesce(tested_detail, '') FROM pgvigil.admin_instances" > "$TMPD/repo-text.txt"
if grep -qF -f "$TMPD/leak.pat" "$TMPD/repo-text.txt"; then fail "a password or a connection string is in the repository's audit or test rows"; fi
if grep -qF -f "$TMPD/leak.pat" "$TMPD/serve.log"; then fail "a password or a connection string is in serve's log"; fi
ok "no password and no connection string in any of the $NANS API answers, the repository's audit and test rows, or serve's log"

echo "== C1c and P. the page in headless Chromium =="
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
const status = () => ev(`document.querySelector('.admin-instances p[role=status]')?.textContent ?? ''`);
const clickLabel = label => ev(`(() => { const b = [...document.querySelectorAll('main button')].find(b => (b.getAttribute('aria-label') ?? b.textContent.trim()) === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
// the cells of an instance's row, by the table's heading and the row's name
const cells = (heading, name) => ev(`(() => { const h = [...document.querySelectorAll('main h3')].find(e => e.textContent.startsWith(${JSON.stringify(heading)}));
  let g = h?.nextElementSibling; while (g && !g.querySelector('table')) g = g.nextElementSibling;
  const t = g?.querySelector('table'); if (!t) return null;
  const heads = [...t.querySelectorAll('thead tr:first-child th')].map(x => (x.childNodes[0]?.textContent ?? x.textContent).trim());
  const tr = [...t.querySelectorAll('tbody tr')].find(r => r.cells[0]?.textContent.trim() === ${JSON.stringify(name)}); if (!tr) return null;
  const o = {}; heads.forEach((x, i) => { o[x] = tr.cells[i]?.textContent.trim() ?? ''; }); return JSON.stringify(o); })()`).then(v => v ? JSON.parse(v) : null);
const out = {};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
out.login = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.P_USR)}, password: ${JSON.stringify(process.env.P_UPW)} }) }).then(r => r.status)`, true);
await cmd('Page.reload'); await sleep(800);
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: U + '#/admin_instances' }); await sleep(300); await cmd('Page.reload');
  const r = { drawn: await until(`!!document.querySelector('main .admin-instances #admin-check-all')`) };
  if (theme === 'light') {
    r.clicked = await clickLabel('Check all');
    r.done = await until(`/^Checked /.test(document.querySelector('.admin-instances p[role=status]')?.textContent ?? '')`, 60);
    r.status = await status();
    r.rows = { 'f-sql': await cells('Instances from pgvigil.yaml', 'f-sql'), 'f-down': await cells('Instances from pgvigil.yaml', 'f-down'),
               'p-up': await cells('Instances added here', 'p-up'), 'p-off': await cells('Instances added here', 'p-off') };
    await cmd('Page.reload'); await until(`!!document.querySelector('main .admin-instances #admin-check-all')`); await sleep(500);
    r.after = { 'f-sql': await cells('Instances from pgvigil.yaml', 'f-sql'), 'f-down': await cells('Instances from pgvigil.yaml', 'f-down') };
  }
  r.rights = await clickLabel('Rights of f-bare2');
  r.box = await until(`!!document.querySelector('#admin-instance-rights-script')`, 30);
  r.script = await ev(`document.querySelector('#admin-instance-rights-script')?.textContent ?? ''`);
  r.copy = await ev(`[...document.querySelectorAll('#admin-instance-rights button')].some(b => b.textContent.trim() === 'Copy the GRANT script')`);
  r.listed = await ev(`document.querySelectorAll('#admin-instance-rights table tbody tr').length`);
  r.errors = await ev(`document.querySelectorAll('main .error:not([role=status])').length`);
  await cmd('Runtime.evaluate', { expression: axeSrc });
  r.violations = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: v.nodes.slice(0, 3).map(x => x.target.join(' ')) }))))`, true) ?? '[]');
  out[theme] = r;
}
console.log(JSON.stringify(out));
process.exit(0);
JS
  P_USR="$USR" P_UPW="$UPW" node "$TMPD/p.mjs" "$CDP" "$U/" "$TMPD/node_modules/axe-core/axe.min.js" > "$TMPD/page.json" 2> "$TMPD/page.err" || fail "P: the page check did not run: $(tail -c 400 "$TMPD/page.err")"
  kill "$CHRPID" 2>/dev/null || true; CHRPID=
  OFFT=$(pq "SELECT coalesce(tested_at::text, 'NULL') FROM pgvigil.admin_instances WHERE name = 'p-off'"); OFFA=$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'instance tested' AND target = 'p-off'")
  OFFT="$OFFT" OFFA="$OFFA" BARE2="$BARE2" python3 - "$TMPD/page.json" <<'PY' || fail "C1c / P: the page"
import json, os, re, sys
d = json.load(open(sys.argv[1])); bad = []
if d.get("login") != 200: bad.append(f"the page's sign-in answered {d.get('login')}")
l = d["light"]
if not l.get("clicked") or not l.get("done"): bad.append(f"Check all: clicked {l.get('clicked')}, ended {l.get('done')}, the status {l.get('status')!r}")
if l.get("status") != "Checked 9: 7 connected, 2 failed; 1 disabled, not checked.": bad.append(f"Check all's last line: {l.get('status')!r}")
rows = l.get("rows") or {}
for n, want in (("f-sql", "connected"), ("p-up", "connected"), ("f-down", "failed")):
    got = (rows.get(n) or {}).get("last test", "")
    if not got.startswith(want): bad.append(f"{n}'s last test after Check all: {got!r} (want {want} ...)")
if (rows.get("p-off") or {}).get("last test") != "not tested": bad.append(f"p-off's last test: {(rows.get('p-off') or {}).get('last test')!r}")
if os.environ["OFFT"] != "NULL" or os.environ["OFFA"] != "0": bad.append(f"p-off was asked: tested_at {os.environ['OFFT']}, {os.environ['OFFA']} audit rows")
after = l.get("after") or {}
if not (after.get("f-sql") or {}).get("last test", "").startswith("connected") or not (after.get("f-down") or {}).get("last test", "").startswith("failed"):
    bad.append(f"after a reload: f-sql {(after.get('f-sql') or {}).get('last test')!r}, f-down {(after.get('f-down') or {}).get('last test')!r}")
if not re.match(r"^\d+ (second|minute)s? ago", (after.get("f-sql") or {}).get("last collected", "")): bad.append(f"f-sql's last collected: {(after.get('f-sql') or {}).get('last collected')!r}")
if (after.get("f-down") or {}).get("last collected") != "never collected": bad.append(f"f-down's last collected: {(after.get('f-down') or {}).get('last collected')!r}")
for theme in ("light", "dark"):
    r = d[theme]
    if not r.get("drawn") or r.get("errors"): bad.append(f"{theme}: drawn {r.get('drawn')}, error boxes {r.get('errors')}")
    if not r.get("rights") or not r.get("box"): bad.append(f"{theme}: the Rights link {r.get('rights')}, the box {r.get('box')}")
    s = r.get("script") or ""
    if f"GRANT VIEW SERVER STATE TO [{os.environ['BARE2']}];" not in s or "pgvigil did not run it and never does" not in s: bad.append(f"{theme}: the script in the box: {s[:200]!r}")
    if not r.get("copy"): bad.append(f"{theme}: no 'Copy the GRANT script' button")
    if (r.get("listed") or 0) < 9: bad.append(f"{theme}: {r.get('listed')} rights listed, want 9 or more")
    n = sum(v["n"] for v in r.get("violations") or [])
    if n: bad.append(f"{theme}: {n} axe violation node(s): {r['violations']}")
if bad: print("\n".join(bad)); sys.exit(1)
print(f"ok   C1c: Check all on the page: {l['status']!r}; f-sql and p-up connected, f-down failed, p-off not asked; the results and f-sql's age ({after['f-sql']['last collected']!r}) still there after a reload")
print(f"ok   P: light and dark: the page drawn, no error box, the Rights box of f-bare2 with {d['light']['listed']} rights, its script and Copy; 0 axe violation nodes")
PY
else
  notproven "C1c and P: chromium or node is not on this machine (the page's Check all and the Rights box were not clicked)"
fi
echo "== R7. a database whose name holds a line break =="
sqok "R7: the database" "DECLARE @n sysname = N'pgc' + NCHAR(10) + N'lf $SUF', @s nvarchar(400); SET @s = N'CREATE DATABASE ' + QUOTENAME(@n); EXEC (@s);"
code=$(rights f-bare2); NS=$(ans no_script)
[[ "$code" == 200 && "$(ans ok)" == True && "$(script | wc -c)" == 0 && "$NS" == "no script is printed: a name this server answered"*"line break"* && "$(state view_server_state)" == missing ]] \
  || fail "R7: Rights of f-bare2 with the database there: $code, the script $(script | wc -c) bytes, no_script '$NS', view_server_state '$(state view_server_state)'"
sqok "R7: the database dropped" "DECLARE @n sysname = N'pgc' + NCHAR(10) + N'lf $SUF', @s nvarchar(400); SET @s = N'DROP DATABASE ' + QUOTENAME(@n); EXEC (@s);"
ok "R7: with a database named across a line break, Rights of f-bare2 lists its rights and prints no script: '$(printf '%s' "$NS" | cut -c1-90)...'"
NB=$(sq "SELECT COUNT(*) FROM sys.server_permissions p JOIN sys.server_principals l ON l.principal_id = p.grantee_principal_id WHERE l.name = N'$BARE2' AND p.permission_name <> N'CONNECT SQL'" | tr -d ' \r')
[[ "$NB" == 0 ]] || fail "f-bare2 (never granted by the proof) holds $NB server permissions after the run"
echo "NOT PROVEN: Azure SQL Database, Azure SQL Managed Instance, Amazon RDS, SQL Server before 2022, Windows - which rights are listed there is the catalogues' unit tests"
echo "ALL ROWS GREEN"
