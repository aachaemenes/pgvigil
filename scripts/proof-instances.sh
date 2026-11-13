#!/usr/bin/env bash
# Proof of Admin > Instances (task 204; task 103 part 1): instances added, tested, edited, disabled, enabled and
# removed in the tool, and synced from sources into proposals a click approves, the collector taking every change
# without a restart, and no credential in the repository.
#
#   A. a SQL Server 2022 container as a Central Management Server (two groups, Prod and Test, three registered
#      servers: the container under three addresses) and two PostgreSQL 16 containers
#   B. the repository; `pgvigil run` started ONCE on a login IN ROLE pgvigil_collector (no SELECT on any table: it
#      reads the page's list through admin_inventory()), `pgvigil serve`; pgvigil.yaml holds one instance (filepg),
#      shown read-only
#   C. the CMS as a source: three proposed with the tags group:Prod / group:Test, equal to a hand read of msdb; a
#      proposal's Test (nothing written but its audit row); approved; each collected; one deleted from the CMS:
#      marked gone, its instance kept, and its instance row says 'gone from cms1 since <t>'
#   D. a pg_service.conf of the two PostgreSQL servers as a source: two proposed, approved, collected
#   E. the API: test (a wrong and a right password), add, the refusals (a name twice, a file name, a connection
#      change without the password), a tags edit, disable (its collections stop; is_active false, so the fleet's stale
#      check passes it by), enable (they start again; is_active true at the enable), remove (its credential file removed
#      after the 30 s grace, its history kept); every change and refusal in the audit
#   F. the page in headless Chromium, light and dark: every control clicked (the add form's test and add, a row's
#      Test, Edit + Save, Disable, Enable, Remove + Keep, Remove + confirm, Cancel the edit, a source's Read now,
#      Turn off, Turn on, Add the source, Remove + confirm, a proposal's Ignore, Propose again, Approve: its panel's
#      Test, Approve, the duplicate tick and Approve again, the panel's fields labelled), each with
#      what it answered: the click table
#   G. a list source pointed at a .pgpass (0600) is refused with 400 and leaves no row; one at a readable file of
#      .pgpass lines adds the source but its read is refused by line number; no credential anywhere in the
#      repository (every row of every table of the pgvigil schema, read as text), in the API's answer or in the logs;
#      the credential files 0600 in a 0700 folder
#   H. the collector's process is the one started in B (no restart) and logged each list it applied
#   I. a second collector on the repository: it logs once that the page's instances are not its own and
#      collects the file's only (filepg), never a page instance
#   J. the fenced lease: a take-over (the lease made 60 s old) bumps the generation; the first collector, superseded,
#      drops the page's instances at its next tick; released, it takes the lease back with the next generation
#   K. a page instance whose server is down is seen failing (the join's review, finding 1): pg-down (its own
#      PostgreSQL container) collected, disabled, its server stopped, enabled -> is_active true at once and, within one
#      interval, a new 'connect:' error and a 'server unreachable' finding; removed and added again while its server is
#      still down -> the same; pg-never, added while its server is down and never collected -> its instances row at
#      the add (active) and the same finding; sql-down (a SQL Server page instance on A's container, the last row: the
#      container stopped) enabled while down -> the same through the SQL Server collector; the join's w9e: pg-wrong
#      added as sqlserver against a PostgreSQL port (never connects), removed (its row goes: no read reached it) and
#      added again as postgres -> 200 and collected (finding 1); pg-plat added with platform onprem while nothing
#      listens on its port, its server started -> first_seen at or after the start (finding 4); sql-never, a SQL
#      Server page instance never collected (A's container stopped) -> its row at the add and 'server unreachable'
#   L. the page on a serve with no UI login (-no-login, the join's w9c): the list renders read only, a plain note in the
#      page's own words ('adding and changing instances needs the UI login: ...'), no error box, every control that
#      writes disabled saying why on hover, the grids' filters still usable; an add through the API refused with the
#      same words; L2: the same on a serve with the UI login whose repository login is the UI's read-only one (IN ROLE
#      pgvigil_reader, pgvigil_auth: docs/app.md), so the actions door's audit login is off ('... goes through the
#      actions door's audit login, and it is off: the audit login may not write the actions log ...'); the third
#      reason (no actions door) serve never has (it always builds the door): internal/web's TestInstancesOffNoDoor
#   M. a page instance never read (task 205, the lead's 12:23): pg-m, added with platform onprem while nothing listens
#      on its port, is 'not read yet (added <t>)' with no last-seen time on Admin > Servers, the fleet list, its
#      Summary card, /api/instances (last_seen null, added_at set) and pgvigil report's instances.txt; once its
#      server answers, the read's time on all five, the words gone, and first_seen moved to that read (0123's
#      admin_first_read: the 'never read' test whatever the platform)
#
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest and postgres:16), go, psql, curl, python3, node,
# npm, chromium. Everything the run makes carries its random suffix and is removed on every exit path the shell can
# catch. Every password is made at run time and reaches the tools through environment files or the environment.
#
# The wiring (sched.go, repo.go, main.go, serve.go, web.go, config.go's Resolve, main.ts, router.ts) is
# scripts/proof-instances-wiring.patch until the release join holds it: applied to the run's own copy with patch -p1
# when the tree does not hold it yet.
#
# NOT PROVEN HERE: the DBA Dash source (no DBA Dash repository on the box: its read is the one query in
# q_instances_admin.go's readSource), Windows / DPAPI (the Windows sandbox), an Entra service principal (no tenant),
# a Windows account (no domain).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
IMG_PG=postgres:16
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvin-sql-$SUF; PGA=pgvin-pga-$SUF; PGB=pgvin-pgb-$SUF; PGK=pgvin-pgk-$SUF; PGP=pgvin-pgp-$SUF; PGM=pgvin-pgm-$SUF; LBL=pgvigil-proof=s204
PGDB=pgv_in_$SUF; COL=pgv_incol_$SUF; RDL=pgv_inrd_$SUF; USR=proofdba$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; RUNPID=; RUN2PID=; CHRPID=; SRVLPID=; SRVRPID=
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); CMS_PW=$(pw); PG_PW=$(pw); BAD_PW=$(pw); UPW=$(pw); COL_PW=$(pw); PGPASS_PW=$(pw); RDL_PW=$(pw)
export MON_PW CMS_PW PG_PW BAD_PW PGPASS_PW
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
printf 'POSTGRES_PASSWORD=%s\n' "$PG_PW" > "$TMPD/pg.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  [[ -n "$SRVLPID" ]] && kill "$SRVLPID" 2>/dev/null || true
  [[ -n "$SRVRPID" ]] && kill "$SRVRPID" 2>/dev/null || true
  [[ -n "$RUNPID" ]] && kill "$RUNPID" 2>/dev/null || true
  [[ -n "$RUN2PID" ]] && kill "$RUN2PID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  for c in "$SQL" "$PGA" "$PGB" "$PGK" "$PGP" "$PGM"; do docker rm -f -v "$c" >/dev/null 2>&1 || { docker inspect "$c" >/dev/null 2>&1 && echo "CLEANUP: container $c not removed" >&2; }; done
  psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $PGDB WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $PGDB not dropped" >&2
  psql "$ADMIN_DSN" -Xqc "DROP ROLE IF EXISTS $COL" >/dev/null 2>&1 || echo "CLEANUP: role $COL not dropped" >&2
  psql "$ADMIN_DSN" -Xqc "DROP ROLE IF EXISTS $RDL" >/dev/null 2>&1 || echo "CLEANUP: role $RDL not dropped" >&2
  rm -rf "$TMPD"
}
trap cleanup EXIT
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW '"$SQLCMD"' -S localhost -U sa -C -b -I -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for t in docker go psql curl python3 node npm chromium; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

# js: a JSON body from key=value pairs; a value @NAME is the environment variable NAME (a password never on a command line)
js() { python3 -c 'import json, os, sys
d = {}
for a in sys.argv[1:]:
    k, v = a.split("=", 1)
    d[k] = os.environ[v[1:]] if v.startswith("@") else v
print(json.dumps(d))' "$@"; }
# api METHOD path [body]: the answer in $TMPD/ans.json, the status code printed
api() { if [[ $# -ge 3 ]]; then printf '%s' "$3" > "$TMPD/body.json"; curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -X "$1" --data @"$TMPD/body.json" "$U/api/$2";
  else curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cj" "$U/api/$2"; fi; }
ans() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); v = d
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list)) else v))' "$TMPD/ans.json" "$1"; }
# collected NAME: rows of an ok collection of the instance; waitcol NAME [secs]: until there is one
collected() { pq "SELECT count(*) FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND d.status = 'ok'"; }
newest() { pq "SELECT coalesce(max(d.snapshot_at)::text, '') FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1'"; }
waitcol() { for _ in $(seq 1 "${2:-120}"); do [[ "$(collected "$1")" -gt 0 ]] && return 0; sleep 1; done; tail -20 "$TMPD/run.log" >&2; fail "$3: $1 was not collected within ${2:-120} s"; }
gen() { pq "SELECT pgvigil.admin_inventory_generation()"; }

echo "== A. the servers =="
docker run -d --name "$SQL" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
for c in "$PGA" "$PGB"; do docker run -d --name "$c" --label "$LBL" --env-file "$TMPD/pg.env" -p 127.0.0.1::5432 "$IMG_PG" >/dev/null; done
up() { local r=; for _ in $(seq 1 90); do r=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true); [[ "$r" == 1 ]] && return 0; sleep 2; done; fail "A: the SQL Server container did not come up in 180 s"; }
up
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
SQLIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SQL")
PA=$(docker port "$PGA" 5432/tcp | head -1 | sed 's/.*://'); PB=$(docker port "$PGB" 5432/tcp | head -1 | sed 's/.*://')
for p in "$PA" "$PB"; do for _ in $(seq 1 60); do PGPASSWORD="$PG_PW" psql "host=127.0.0.1 port=$p user=postgres dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  PGPASSWORD="$PG_PW" psql "host=127.0.0.1 port=$p user=postgres dbname=postgres" -XAtqc 'select 1' >/dev/null || fail "A: PostgreSQL on port $p did not come up"; done
CMSL=pgv_cms_$SUF; MONL=pgv_mon_$SUF
sqok "A: the logins" "CREATE LOGIN [$CMSL] WITH PASSWORD = '$CMS_PW', CHECK_POLICY = OFF; CREATE LOGIN [$MONL] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF;
  GRANT VIEW SERVER STATE TO [$MONL]; GRANT VIEW ANY DEFINITION TO [$MONL];
  USE msdb; CREATE USER [$CMSL] FOR LOGIN [$CMSL]; ALTER ROLE ServerGroupReaderRole ADD MEMBER [$CMSL];"
S1="127.0.0.1,$PORT_SQL"; S2="localhost,$PORT_SQL"; S3="$SQLIP,1433"
sqok "A: the CMS groups and servers" "DECLARE @prod int, @test int, @id int;
  EXEC msdb.dbo.sp_sysmanagement_add_shared_server_group @parent_id = 1, @name = N'Prod', @description = N'', @server_type = 0, @server_group_id = @prod OUTPUT;
  EXEC msdb.dbo.sp_sysmanagement_add_shared_server_group @parent_id = 1, @name = N'Test', @description = N'', @server_type = 0, @server_group_id = @test OUTPUT;
  EXEC msdb.dbo.sp_sysmanagement_add_shared_registered_server @name = N'prod one', @server_group_id = @prod, @server_name = N'$S1', @description = N'', @server_type = 0, @server_id = @id OUTPUT;
  EXEC msdb.dbo.sp_sysmanagement_add_shared_registered_server @name = N'prod two', @server_group_id = @prod, @server_name = N'$S2', @description = N'', @server_type = 0, @server_id = @id OUTPUT;
  EXEC msdb.dbo.sp_sysmanagement_add_shared_registered_server @name = N'test one', @server_group_id = @test, @server_name = N'$S3', @description = N'', @server_type = 0, @server_id = @id OUTPUT;" msdb
echo "ok   A: SQL Server on $PORT_SQL (container $SQLIP), the CMS: Prod [$S1, $S2], Test [$S3]; PostgreSQL on $PA and $PB"

echo "== B. the repository, the collector (once), serve =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
P=scripts/proof-instances-wiring.patch
if grep -q 'InstancesAdminView' "$GSRC/internal/web/web.go"; then echo "B: the tree holds the wiring (the patch is not applied)"
elif [[ -f "$GSRC/$P" ]] && (cd "$GSRC" && patch -p1 --dry-run -s < "$P" >/dev/null); then (cd "$GSRC" && patch -p1 -s < "$P") && echo "B: $P applied to the run's copy"
else fail "B: the tree has no /api/admin/instances route and $P does not apply"; fi
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "B: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil" ./cmd/pgvigil) || fail "B: the build"
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
CFGD=$TMPD/etc; mkdir -p "$CFGD"
export PGV_FILE_DSN="host=127.0.0.1 port=$PA user=postgres password=$PG_PW dbname=postgres"
export PGV_COL_DSN="host=127.0.0.1 port=5432 user=$COL password=$COL_PW dbname=$PGDB"
cat > "$CFGD/pgvigil.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: filepg
    dsn: env:PGV_FILE_DSN
    tags: [source:file]
EOF
sed "s|dsn: \"$PGDSN\"|dsn: env:PGV_COL_DSN|" "$CFGD/pgvigil.yaml" > "$CFGD/collector.yaml"
"$TMPD/pgvigil" migrate -config "$CFGD/pgvigil.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
printf "CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE pgvigil_collector;\n" "$COL" "$COL_PW" | psql "$ADMIN_DSN" -Xq -v ON_ERROR_STOP=1 >/dev/null
[[ "$(pq "SELECT has_table_privilege('$COL', 'pgvigil.admin_instances', 'SELECT')")" == f ]] || fail "B: the collector's login can read admin_instances (want only the functions)"
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil" user add -config "$CFGD/pgvigil.yaml" "$USR" >/dev/null 2>&1 || fail "B: user add"
"$TMPD/pgvigil" run -config "$CFGD/collector.yaml" >"$TMPD/run.log" 2>&1 & RUNPID=$!
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
# serve under umask 022 (a service's usual): G's 0600 / 0700 are then the code's own modes, not the proof's umask
(umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/pgvigil.yaml" -listen "127.0.0.1:$PORT") >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "B: serve exited"; }
kill -0 "$RUNPID" 2>/dev/null || { cat "$TMPD/run.log" >&2; fail "B: run exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "B: the UI login"
waitcol filepg 90 "B"
[[ "$(api GET admin/instances)" == 200 ]] || fail "B: GET /api/admin/instances: $(head -c 300 "$TMPD/ans.json")"
python3 - "$TMPD/ans.json" <<'PY' || fail "B: the file's instance in the page: $(head -c 300 "$TMPD/ans.json")"
import json, sys
d = json.load(open(sys.argv[1])); f = d["file"]; i = {c: n for n, c in enumerate(f["columns"])}
rows = [(r[i["name"]], r[i["source"]]) for r in f["rows"]]
assert rows == [("filepg", "from the file")], rows
assert d["page"]["rows"] == [] and d["writable"] is True, d
PY
G0=$(gen)
echo "ok   B: the collector (pid $RUNPID) on $COL (no SELECT on admin_instances) collects filepg from the file; the page lists it read-only; generation $G0"

echo "== C. the CMS as a source =="
B=$(js op=add kind=cms name=cms1 cms_host=127.0.0.1 cms_port="$PORT_SQL" cms_auth=sql cms_login="$CMSL" cms_password=@CMS_PW cms_options=TrustServerCertificate=true \
  auth=sql cred_login="$MONL" cred_password=@MON_PW cred_options=TrustServerCertificate=true every_s=3600)
code=$(api POST admin/sources "$B"); [[ "$code" == 200 && "$(ans sync.new)" == 3 ]] || fail "C: the CMS source: $code $(cat "$TMPD/ans.json")"
HAND=$(sq "SELECT s.server_name + '|group:' + g.name FROM msdb.dbo.sysmanagement_shared_registered_servers s JOIN msdb.dbo.sysmanagement_shared_server_groups g ON g.server_group_id = s.server_group_id ORDER BY 1" msdb | sort)
GOT=$(pq "SELECT server || '|' || array_to_string(tags, ' ') FROM pgvigil.admin_proposals WHERE source = 'cms1' AND state = 'proposed' AND NOT gone ORDER BY 1" | sort)
[[ "$HAND" == "$GOT" && $(wc -l <<<"$GOT") == 3 ]] || fail "C: the proposals [$GOT] differ from msdb [$HAND]"
echo "C: 3 proposed, equal to msdb's registered servers and groups: $(tr '\n' ' ' <<<"$GOT")"
# the proposal's Test (204's connection test with the source's login) before the approve: nothing written but the audit
id=$(pq "SELECT proposal_id FROM pgvigil.admin_proposals WHERE source = 'cms1' AND server = '$S1'")
code=$(api POST admin/proposals "$(js op=test proposal_id="$id")"); [[ "$code" == 200 && "$(ans ok)" == True ]] || fail "C: the proposal's Test: $code $(cat "$TMPD/ans.json")"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_instances")" == 0 && "$(pq "SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'proposal test' AND outcome = 'done' AND detail LIKE 'connected: %'")" == 1 ]] || fail "C: the Test wrote an instance or no audit row"
# the audit row goes through an import_ function the collector's role may run (serve's login is not the owner in a service)
[[ "$(pq "SELECT has_function_privilege('$COL', 'pgvigil.import_admin_proposal_test(timestamptz, jsonb)', 'EXECUTE')")" == t ]] || fail "C: a non-owner serve login could not write the Test's audit row"
echo "C: the Test of $S1's proposal: $(ans detail | head -c 100)"
for s in "$S1" "$S2" "$S3"; do
  id=$(pq "SELECT proposal_id FROM pgvigil.admin_proposals WHERE source = 'cms1' AND server = '$s'")
  code=$(api POST admin/proposals "$(js op=approve proposal_id="$id")"); [[ "$code" == 200 ]] || fail "C: approve $s: $code $(cat "$TMPD/ans.json")"
done
N1=$(pq "SELECT instance_name FROM pgvigil.admin_proposals WHERE server = '$S1'"); N3=$(pq "SELECT instance_name FROM pgvigil.admin_proposals WHERE server = '$S3'")
for s in "$S1" "$S2" "$S3"; do n=$(pq "SELECT instance_name FROM pgvigil.admin_proposals WHERE server = '$s'"); waitcol "$n" 120 "C"; done
GT=$(pq "SELECT string_agg(host || ':' || array_to_string(tags, ' '), ', ' ORDER BY host) FROM pgvigil.admin_instances WHERE source = 'cms:cms1'")
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_instances WHERE source = 'cms:cms1' AND tags && ARRAY['group:Prod', 'group:Test']")" == 3 && "$GT" == *"group:Prod"*"group:Test"* ]] || fail "C: the approved instances' tags: $GT (want all three, Prod and Test)"
sqok "C: delete $S3 from the CMS" "DECLARE @id int = (SELECT server_id FROM msdb.dbo.sysmanagement_shared_registered_servers WHERE server_name = N'$S3');
  EXEC msdb.dbo.sp_sysmanagement_delete_shared_registered_server @server_id = @id;" msdb
code=$(api POST admin/sources "$(js op=sync name=cms1)"); [[ "$code" == 200 && "$(ans gone)" == 1 ]] || fail "C: the read after the delete: $code $(cat "$TMPD/ans.json")"
[[ "$(pq "SELECT gone AND gone_at IS NOT NULL AND state = 'approved' FROM pgvigil.admin_proposals WHERE server = '$S3'")" == t ]] || fail "C: $S3 is not marked gone"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_instances WHERE name = '$N3' AND NOT disabled")" == 1 ]] || fail "C: the gone server's instance was removed or disabled by the sync"
code=$(api GET admin/instances); [[ "$code" == 200 ]] || fail "C: GET /api/admin/instances: $code"
python3 - "$TMPD/ans.json" "$N3" "$N1" <<'PY' || fail "C: the gone instance's row: $(head -c 300 "$TMPD/ans.json")"
import json, sys
d = json.load(open(sys.argv[1])); t = d["page"]; i = {c: n for n, c in enumerate(t["columns"])}
rows = {r[i["name"]]: r for r in t["rows"]}
g, k = rows[sys.argv[2]], rows[sys.argv[3]]
assert g[i["gone_source"]] == "cms1" and g[i["gone_since"]], g
assert k[i["gone_source"]] is None, k   # one its source still lists: no gone line
PY
echo "ok   C: 3 proposed (= msdb), a proposal's Test (connected, nothing written, its audit row), approved, each collected ($N1 ...); $S3 deleted from the CMS: marked gone, its instance $N3 kept and its row says gone from cms1"

echo "== D. a pg_service.conf as a source =="
cat > "$CFGD/pg_service.conf" <<EOF
# two PostgreSQL servers
[svc_a]
host=127.0.0.1
port=$PA
dbname=postgres
user=postgres

[svc_b]
host=127.0.0.1
port=$PB
dbname=postgres
EOF
code=$(api POST admin/sources "$(js op=add kind=pg_service name=pgsvc ref="$CFGD/pg_service.conf" auth=password cred_login=postgres cred_password=@PG_PW every_s=3600)")
[[ "$code" == 200 && "$(ans sync.new)" == 2 ]] || fail "D: the pg_service source: $code $(cat "$TMPD/ans.json")"
for s in svc_a svc_b; do id=$(pq "SELECT proposal_id FROM pgvigil.admin_proposals WHERE source = 'pgsvc' AND server = '$s'")
  # svc_a is 127.0.0.1:$PA as pgvigil.yaml's filepg is: the 'already an instance' tick checks the page's instances only
  # (the repository holds no file instance's host), so no tick here - docs/discovery.md says so
  code=$(api POST admin/proposals "$(js op=approve proposal_id="$id")"); [[ "$code" == 200 ]] || fail "D: approve $s: $code $(cat "$TMPD/ans.json")"; done
waitcol svc_a 120 "D"; waitcol svc_b 120 "D"
echo "ok   D: svc_a and svc_b proposed from the pg_service.conf, approved, collected"

echo "== E. the API: test, add, the refusals, edit, disable, enable, remove =="
T="op=test engine=postgres host=127.0.0.1 port=$PB dbname=postgres auth=password login=postgres"
code=$(api POST admin/instances "$(js $T password=@BAD_PW)"); [[ "$code" == 200 && "$(ans ok)" == False ]] || fail "E: a test with a wrong password: $code $(cat "$TMPD/ans.json")"
WRONG=$(ans detail | head -c 120)
code=$(api POST admin/instances "$(js $T password=@PG_PW)"); [[ "$code" == 200 && "$(ans ok)" == True ]] || fail "E: a test with the right password: $code $(cat "$TMPD/ans.json")"
echo "E: test: wrong password -> '$WRONG'; right -> '$(ans detail)'"
A="engine=postgres host=127.0.0.1 port=$PB dbname=postgres auth=password login=postgres tags=env:proof"
G1=$(gen)
code=$(api POST admin/instances "$(js op=add name=pg-manual $A password=@PG_PW)"); [[ "$code" == 200 ]] || fail "E: add: $code $(cat "$TMPD/ans.json")"
[[ "$(gen)" -gt "$G1" ]] || fail "E: add did not move the generation"
waitcol pg-manual 120 "E"
code=$(api POST admin/instances "$(js op=add name=pg-manual $A password=@PG_PW)"); [[ "$code" == 409 && "$(ans detail)" == *"exists already"* ]] || fail "E: a name twice: $code $(cat "$TMPD/ans.json")"
code=$(api POST admin/instances "$(js op=add name=filepg $A password=@PG_PW)"); [[ "$code" == 409 && "$(ans detail)" == *"pgvigil.yaml"* ]] || fail "E: the file's name: $code $(cat "$TMPD/ans.json")"
code=$(api POST admin/instances "$(js op=edit name=pg-manual engine=postgres host=localhost port=$PB dbname=postgres auth=password login=postgres tags=env:proof)")
[[ "$code" == 409 ]] || fail "E: a host change without the password was taken: $code $(cat "$TMPD/ans.json")"
code=$(api POST admin/instances "$(js op=edit name=pg-manual $A "tags=env:proof team:dba")"); [[ "$code" == 200 ]] || fail "E: a tags edit: $code $(cat "$TMPD/ans.json")"
[[ "$(pq "SELECT array_to_string(tags, ' ') FROM pgvigil.admin_instances WHERE name = 'pg-manual'")" == "env:proof team:dba" ]] || fail "E: the tags edit was not stored"
code=$(api POST admin/instances "$(js op=test name=pg-manual)"); [[ "$code" == 200 && "$(ans ok)" == True ]] || fail "E: the stored instance's test: $code $(cat "$TMPD/ans.json")"
[[ "$(pq "SELECT tested_ok FROM pgvigil.admin_instances WHERE name = 'pg-manual'")" == t ]] || fail "E: the test result was not kept"
code=$(api POST admin/instances "$(js op=disable name=pg-manual)"); [[ "$code" == 200 ]] || fail "E: disable: $code"
# a run in flight at the disable calls ensure_instance as the collector: admin_keep_removed keeps it inactive
psql "$PGV_COL_DSN" -XAtq -v ON_ERROR_STOP=1 -c "SELECT pgvigil.ensure_instance('pg-manual', 'auto', '', 0, false, '{}')" >/dev/null || fail "E: ensure_instance as the collector"
[[ "$(pq "SELECT is_active FROM pgvigil.instances WHERE name = 'pg-manual'")" == f ]] || fail "E: a run in flight set the disabled pg-manual active again (admin_keep_removed)"
sleep 30; D0=$(newest pg-manual); sleep 75; D1=$(newest pg-manual)
[[ "$D0" == "$D1" ]] || fail "E: pg-manual was collected after the disable ($D0 -> $D1)"
[[ "$(pq "SELECT is_active FROM pgvigil.instances WHERE name = 'pg-manual'")" == f ]] || fail "E: pg-manual is still active after the disable (the fleet's stale check would flag it)"
code=$(api POST admin/instances "$(js op=enable name=pg-manual)"); [[ "$code" == 200 ]] || fail "E: enable: $code"
for _ in $(seq 1 120); do [[ "$(newest pg-manual)" > "$D1" ]] && break; sleep 1; done
[[ "$(newest pg-manual)" > "$D1" ]] || fail "E: pg-manual was not collected again after the enable"
[[ "$(pq "SELECT is_active FROM pgvigil.instances WHERE name = 'pg-manual'")" == t ]] || fail "E: pg-manual is not active after the enable and a run"
REF=$(pq "SELECT dsn_ref FROM pgvigil.admin_instances WHERE name = 'pg-manual'"); RF=${REF#file:}
[[ -f "$RF" ]] || fail "E: the credential file $RF is missing"
code=$(api POST admin/instances "$(js op=remove name=pg-manual)"); [[ "$code" == 200 ]] || fail "E: remove: $code"
[[ -e "$RF" ]] || fail "E: the credential file went at once (the collector may still read it for 15 s: 30 s grace)"
RM="$(pq "SELECT count(*) FROM pgvigil.admin_instances WHERE name = 'pg-manual'")|$(pq "SELECT is_active FROM pgvigil.instances WHERE name = 'pg-manual'")"
[[ "$RM" == "0|f" ]] || fail "E: the remove: admin rows|is_active = $RM (want 0|f)"
[[ "$(collected pg-manual)" -gt 0 ]] || fail "E: the remove dropped the history"
sleep 30; R0=$(newest pg-manual); sleep 75; [[ "$(newest pg-manual)" == "$R0" ]] || fail "E: pg-manual was collected after the remove"
[[ ! -e "$RF" ]] || fail "E: the credential file stayed 105 s after the remove (the grace is 30 s)"
[[ "$(pq "SELECT is_active FROM pgvigil.instances WHERE name = 'pg-manual'")" == f ]] || fail "E: pg-manual is active again after the remove (a run in flight)"
AUD=$(pq "SELECT string_agg(op || ':' || outcome, ' ' ORDER BY audit_id) FROM pgvigil.admin_audit WHERE target = 'pg-manual'")
for w in "instance add:done" "instance add:refused" "instance edit:done" "instance tested:done" "instance disable:done" "instance enable:done" "instance remove:done"; do
  [[ "$AUD" == *"$w"* ]] || fail "E: the audit lacks '$w': $AUD"; done
echo "ok   E: tests (wrong: refused by the server, right: connected), add (collected), refusals (twice, a file name, a connection change without the password), a tags edit, disable (not collected for 75 s), enable (collected again), remove (its file gone, history kept, not collected); the audit: $AUD"

echo "== F. the page in headless Chromium =="
sqok "F: a fourth server in the CMS" "DECLARE @test int = (SELECT server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups WHERE name = N'Test'), @id int;
  EXEC msdb.dbo.sp_sysmanagement_add_shared_registered_server @name = N'nobody', @server_group_id = @test, @server_name = N'ignoreme.invalid', @description = N'', @server_type = 0, @server_id = @id OUTPUT;" msdb
printf 'host,port,name,tags\n127.0.0.1,%s,csv one,env:csv\n' "$PA" > "$CFGD/servers.csv"; chmod 644 "$CFGD/servers.csv"  # a server list is readable: the page refuses one only its owner reads (the proof's umask is 077)
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1200 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "F: chromium's CDP port never answered"
cat > "$TMPD/f.mjs" <<'JS'
// one line per check: 'page <theme> {...}' and 'click <label> -> <status>'; the shell grades them
const [port, U, shots, pa, csv] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ready = async () => { for (let i = 0; i < 150; i++) { if (await ev(`!!document.querySelector('main .admin-instances h2')`)) { await sleep(400); return true; } await sleep(200); } return false; };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
const status = () => ev(`document.querySelector('.admin-instances p[role=status]')?.textContent ?? ''`);
// click a button by its aria-label (or its text), then wait for the status line to settle
const click = async (label, settle = true) => {
  const ok = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(b => (b.getAttribute('aria-label') ?? b.textContent.trim()) === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
  if (!ok) { console.log(`click ${JSON.stringify(label)} -> NOT FOUND`); return ''; }
  let s = '';
  for (let i = 0; i < 100 && settle; i++) { await sleep(200); s = await status(); if (!/^(Working|Connecting)/.test(s)) break; }
  await sleep(300);
  console.log(`click ${JSON.stringify(label)} -> ${JSON.stringify(settle ? s : 'armed')}`);
  return s;
};
const fill = (form, vals) => ev(`(() => { const f = [...document.querySelectorAll('main form')].find(f => f.getAttribute('aria-label') === ${JSON.stringify(form)});
  for (const [k, v] of Object.entries(${JSON.stringify(vals)})) { const c = f.querySelector('[name="' + k + '"]'); c.value = v; c.dispatchEvent(new Event('change')); c.dispatchEvent(new Event('input')); } return true; })()`);
const submit = async (form, label) => { await ev(`[...document.querySelectorAll('main form')].find(f => f.getAttribute('aria-label') === ${JSON.stringify(form)}).querySelector('button[type=submit]').textContent`); return click(label); };
const state = () => ev(`(() => { const m = document.querySelector('main'); const h = [...m.querySelectorAll('h3')];
  const rows = t => { const x = h.find(e => e.textContent.startsWith(t)); let g = x?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE' && g.tagName !== 'H3') g = g.nextElementSibling; return g && g.tagName !== 'H3' ? [...g.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')).length : -1; };
  return JSON.stringify({ page: rows('Instances added here'), file: rows('Instances from pgvigil.yaml'), sources: rows('Sync sources'), proposals: rows('Proposed servers'), audit: rows('Changes'),
    labelled: [...m.querySelectorAll('input, select')].every(c => c.closest('label') || c.getAttribute('aria-label')), errors: m.querySelectorAll('.error:not([role=status])').length }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
console.log(`login ${await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.F_USR)}, password: ${JSON.stringify(process.env.F_UPW)} }) }).then(r => r.status)`, true)}`);
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await cmd('Page.navigate', { url: U + '#/admin_instances' });
  if (!await ready()) { console.log(`FAIL render ${theme}`); continue; }
  console.log(`page ${theme} ${JSON.stringify(await state())}`);
  await shot(`admin-instances-${theme}`);
}
// the add form: test, add; the new row's controls
await fill('Add or edit an instance', { engine: 'postgres' });
await fill('Add or edit an instance', { name: 'pg-click', host: '127.0.0.1', port: pa, dbname: 'postgres', auth: 'password', login: 'postgres', password: process.env.PG_PW, tags: 'env:click' });
await click('Test the connection');
await submit('Add or edit an instance', 'Add');
await click('Test pg-click');
await click('Edit pg-click', false); console.log(`edit-legend ${JSON.stringify(await ev(`document.querySelector('main form legend').textContent`))}`);
await click('Cancel the edit', false); console.log(`cancel-legend ${JSON.stringify(await ev(`document.querySelector('main form legend').textContent`))}`);
await click('Edit pg-click', false);
await fill('Add or edit an instance', { tags: 'env:click team:page' });
await submit('Add or edit an instance', 'Save');
await click('Disable pg-click');
await click('Enable pg-click');
await click('Remove pg-click', false); await click('Keep pg-click');
console.log(`kept ${await ev(`[...document.querySelectorAll('main button')].some(b => b.getAttribute('aria-label') === 'Remove pg-click') && ![...document.querySelectorAll('main button')].some(b => b.getAttribute('aria-label') === 'Confirm: remove pg-click')`)}`);
await click('Remove pg-click', false); await click('Confirm: remove pg-click');
// a source: read now (the fourth CMS server comes in), its proposal ignored, proposed again, approved
await click('Read cms1 now');
await click('Ignore ignoreme.invalid');
await click('Propose ignoreme.invalid again');
await click('Ignore ignoreme.invalid');
await click('Turn off cms1'); await click('Turn on cms1');
// a list source added through its form, its server approved, the source removed
await fill('Add a sync source', { kind: 'pg_csv' });
await fill('Add a sync source', { name: 'csv1', ref: csv, auth: 'password', cred_login: 'postgres', cred_password: process.env.PG_PW, every_min: '60' });
await submit('Add a sync source', 'Add the source');
// Approve opens the row's panel (task 205): Test, then Approve - the server is already an instance (D's svc_a, the
// same host and port): the tick, then Approve again
await click(`Approve 127.0.0.1,${pa}`, false);
await click(`Test the connection to 127.0.0.1,${pa}`);
await click(`Approve 127.0.0.1,${pa} now`);
console.log(`tick ${await ev(`(() => { const c = [...document.querySelectorAll('main input[type=checkbox]')].find(c => c.getAttribute('aria-label') === 'Tick: duplicate for 127.0.0.1,${pa}'); if (!c) return 'NOT FOUND'; c.click(); return c.checked; })()`)}`);
console.log(`panel ${JSON.stringify(await state())}`);
const again = await click(`Approve 127.0.0.1,${pa} now`);
console.log(`approve-ticked ${JSON.stringify(again)}`);
await click('Remove source csv1', false); await click('Confirm: remove source csv1');
console.log(`after ${JSON.stringify(await state())}`);
await shot('admin-instances-after-dark');
ws.close(); process.exit(0);
JS
out=$(F_USR="$USR" F_UPW="$UPW" node "$TMPD/f.mjs" "$CDP" "$U/" "$SHOTS" "$PA" "$CFGD/servers.csv") || fail "F: the Chromium walk stopped: $out"
echo "$out"
echo "$out" | grep -q '^login 200$' || fail "F: the UI login in Chromium"
! echo "$out" | grep -q '^FAIL\|NOT FOUND' || fail "F: a page did not render or a control was not found"
for theme in light dark; do echo "$out" | grep "^page $theme " | grep -q '"labelled":true,"errors":0' || fail "F: the page ($theme): $(echo "$out" | grep "^page $theme ")"; done
grade() { echo "$out" | grep -F "click \"$1\" -> " | head -1 | grep -qE -- "$2" || fail "F: '$1' answered $(echo "$out" | grep -F "click \"$1\" -> " | head -1) (want /$2/)"; }
grade 'Test the connection' 'connected: PostgreSQL'; grade 'Add' 'Added pg-click'; grade 'Test pg-click' 'pg-click: connected'
echo "$out" | grep -q '^edit-legend "Edit pg-click"' && echo "$out" | grep -q '^cancel-legend "Add an instance"' || fail "F: Edit / Cancel the edit"
grade 'Save' 'Saved pg-click'; grade 'Disable pg-click' 'disabled'; grade 'Enable pg-click' 'enabled'
echo "$out" | grep -q '^kept true$' || fail "F: Keep did not put the row's Remove back (or left the confirm)"
grade 'Confirm: remove pg-click' 'pg-click removed'; grade 'Read cms1 now' 'cms1 read'; grade 'Ignore ignoreme.invalid' 'ignored'
grade 'Propose ignoreme.invalid again' 'proposed again'; grade 'Turn off cms1' 'turned off'; grade 'Turn on cms1' 'turned on'
grade 'Add the source' 'Source csv1 added and read'; grade "Test the connection to 127.0.0.1,$PA" ': connected'
grade "Approve 127.0.0.1,$PA now" 'Not approved yet: .*already an instance'; echo "$out" | grep -q '^tick true$' || fail "F: the duplicate tick"
echo "$out" | grep '^panel ' | grep -q '"labelled":true,"errors":0' || fail "F: the approve panel's fields (open) are not all labelled: $(echo "$out" | grep '^panel ')"
echo "$out" | grep -q '^approve-ticked ".*approved' || fail "F: Approve again with the tick: $(echo "$out" | grep '^approve-ticked')"
grade 'Confirm: remove source csv1' 'Source csv1 removed'
[[ "$(pq "SELECT array_to_string(tags, ' ') FROM pgvigil.admin_instances WHERE name = 'pg-click'")" == "" ]] || fail "F: pg-click is still in admin_instances after the confirm"
[[ "$(pq "SELECT state FROM pgvigil.admin_proposals WHERE server = 'ignoreme.invalid'")" == ignored ]] || fail "F: ignoreme.invalid is not ignored"
NCSV=$(pq "SELECT name FROM pgvigil.admin_instances WHERE source = 'pg_csv:csv1'"); [[ -n "$NCSV" ]] || fail "F: the CSV's approved server is not an instance (a removed source keeps its approved instances)"
waitcol "$NCSV" 120 "F"
echo "ok   F: the page in light and dark (every field labelled, no error); $(echo "$out" | grep -c '^click ') clicks, each answered as above; the CSV source's server $NCSV collected after its source was removed"

echo "== G. no credential in the repository, the API or the logs =="
PGPASS_FILE=$TMPD/pgpass; printf '127.0.0.1:%s:*:postgres:%s\n' "$PA" "$PGPASS_PW" > "$PGPASS_FILE"; chmod 600 "$PGPASS_FILE"
code=$(api POST admin/sources "$(js op=add kind=sqlserver_list name=pgpass1 ref="$PGPASS_FILE" every_s=3600)")
[[ "$code" == 400 && "$(pq "SELECT count(*) FROM pgvigil.admin_sources WHERE name = 'pgpass1'")" == 0 ]] || fail "G: a 0600 .pgpass as a list source: $code $(head -c 300 "$TMPD/ans.json") (want 400, no row)"
grep -q 'owner only' "$TMPD/ans.json" || fail "G: the refusal does not say why: $(head -c 300 "$TMPD/ans.json")"
chmod 644 "$PGPASS_FILE"
code=$(api POST admin/sources "$(js op=add kind=pg_csv name=pgpass2 ref="$PGPASS_FILE" every_s=3600)")
[[ "$code" == 200 && "$(ans sync_error)" == *".pgpass line"* && "$(ans sync_error)" == *"line 1"* ]] || fail "G: a readable file of .pgpass lines: $code $(head -c 300 "$TMPD/ans.json") (want its read refused by line number)"
[[ "$(pq "SELECT count(*) FROM pgvigil.admin_proposals WHERE source = 'pgpass2'")" == 0 ]] || fail "G: the .pgpass file was read into proposals"
code=$(api POST admin/sources "$(js op=remove name=pgpass2)"); [[ "$code" == 200 ]] || fail "G: remove pgpass2: $code"
echo "G: a 0600 .pgpass refused (400, no row); a readable one's read refused by line number, no proposal"
for _ in $(seq 1 40); do (( $(find "$CFGD/instances" -type f | wc -l) == $(pq "SELECT count(*) FROM pgvigil.admin_instances") )) && break; sleep 1; done  # the 30 s grace of the files F replaced
TABLES=$(pq "SELECT c.oid::regclass FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition ORDER BY 1")
NT=0; HITS=""
for t in $TABLES; do NT=$((NT + 1))
  for v in MON_PW CMS_PW PG_PW BAD_PW PGPASS_PW; do n=$(pq "SELECT count(*) FROM $t x WHERE strpos(x::text, '${!v}') > 0"); [[ "$n" == 0 ]] || HITS+=" $t:$v=$n"; done; done
[[ -z "$HITS" ]] || fail "G: a password is in the repository:$HITS"
api GET admin/instances >/dev/null
for v in MON_PW CMS_PW PG_PW BAD_PW PGPASS_PW; do for f in "$TMPD/ans.json" "$TMPD/serve.log" "$TMPD/run.log"; do ! grep -qF -- "${!v}" "$f" || fail "G: $v is in $(basename "$f")"; done; done
NF=0; for d in instances sources; do [[ "$(stat -c %a "$CFGD/$d")" == 700 ]] || fail "G: the credential folder $d is $(stat -c %a "$CFGD/$d")"
  for f in "$CFGD/$d"/*; do NF=$((NF + 1)); [[ "$(stat -c %a "$f")" == 600 ]] || fail "G: $d/$(basename "$f") is $(stat -c %a "$f")"; done; done
NREF=$(pq "SELECT count(*) FROM pgvigil.admin_instances WHERE dsn_ref LIKE 'file:$CFGD/instances/%'")
NLIVE=$(pq "SELECT count(*) FROM pgvigil.admin_instances"); NINST=$(find "$CFGD/instances" -type f | wc -l)
[[ "$NREF" == "$NLIVE" && "$NINST" == "$NLIVE" ]] || fail "G: $NLIVE page instances, $NREF name a file in the folder, $NINST files there (want all equal: no file left behind, none missing)"
echo "ok   G: no password in any row of $NT tables, the API's answer or the two logs; $NF credential file(s) 0600 in 0700 folders (serve under umask 022); $NINST instance files = $NLIVE page instances"

echo "== H. the collector was never restarted =="
kill -0 "$RUNPID" 2>/dev/null || fail "H: the collector stopped"
NA=$(grep -c 'scheduler: instances applied' "$TMPD/run.log" || true)
(( NA >= 8 )) || fail "H: the collector applied $NA lists (want one per change: 8 or more)"
echo "ok   H: pid $RUNPID ran from B to the end and applied $NA lists (generation $G0 -> $(gen))"

echo "== I. a second collector on the repository =="
"$TMPD/pgvigil" run -config "$CFGD/collector.yaml" >"$TMPD/run2.log" 2>&1 & RUN2PID=$!
for _ in $(seq 1 40); do grep -q "are not this collector's now" "$TMPD/run2.log" && break; sleep 1; done
kill -0 "$RUN2PID" 2>/dev/null || { tail -20 "$TMPD/run2.log" >&2; fail "I: the second collector exited"; }
[[ "$(grep -c "are not this collector's now" "$TMPD/run2.log")" == 1 ]] || { tail -20 "$TMPD/run2.log" >&2; fail "I: the second collector did not say once that another holds the page's instances"; }
sleep 20
[[ "$(grep -c "are not this collector's now" "$TMPD/run2.log")" == 1 ]] || fail "I: the second collector said it more than once"
PAGE2=$(grep 'scheduler: instances applied' "$TMPD/run2.log" | grep -oE ' instances=[0-9]+' | tr -d ' ' | sort -u | tr '\n' ' ')
[[ "$PAGE2" == "instances=1 " ]] || { tail -20 "$TMPD/run2.log" >&2; fail "I: the second collector applied [$PAGE2] (want only the file's one instance)"; }
! grep -q 'instances: list read' "$TMPD/run2.log" || { grep -m3 'instances: list read' "$TMPD/run2.log" >&2; fail "I: the second collector read the page's list"; }
kill "$RUN2PID" 2>/dev/null; wait "$RUN2PID" 2>/dev/null || true; RUN2PID=
kill -0 "$RUNPID" 2>/dev/null || fail "I: the first collector stopped"
echo "ok   I: a second collector said once that the page's instances are not its own and applied the file's one instance only"

echo "== J. a fenced lease: a take-over bumps the generation; the superseded holder stops at its next tick, then takes it back =="
last_applied() { grep 'scheduler: instances applied' "$TMPD/run.log" | tail -1 | grep -oE ' instances=[0-9]+' | tr -d ' '; }
BEFORE=$(last_applied); G1=$(pq "SELECT generation FROM pgvigil.admin_page_holder")
NOT0=$(grep -c "are not this collector's now" "$TMPD/run.log" || true); HOLD0=$(grep -c "holds the page's instances now" "$TMPD/run.log" || true)
[[ "$(pq "SELECT holder LIKE '%:$RUNPID:%' FROM pgvigil.admin_page_holder")" == t && "$G1" -ge 1 ]] || fail "J: the first collector (pid $RUNPID) does not hold the lease: $(pq "SELECT holder || ' ' || generation FROM pgvigil.admin_page_holder")"
# a lease 60 s old and a take-over in one transaction (the holder's renewal waits on the row, then finds itself superseded)
TG=$(pq "UPDATE pgvigil.admin_page_holder SET beat = now() - interval '60 seconds'; SELECT pgvigil.import_admin_page_lease('proof-taker', 45)")
[[ "$TG" == $((G1 + 1)) ]] || fail "J: the take-over got generation $TG (want $((G1 + 1)))"
# the docs' bound: its renewal (15 s) and its watcher's tick (15 s), 5 s spare
for _ in $(seq 1 35); do [[ "$(last_applied)" == "instances=1" ]] && break; sleep 1; done
[[ "$(last_applied)" == "instances=1" ]] || fail "J: the superseded holder still runs [$(last_applied)] 35 s after the take-over (want the file's one instance)"
[[ "$(grep -c "are not this collector's now" "$TMPD/run.log")" == $((NOT0 + 1)) ]] || fail "J: the superseded holder did not say once that the page's instances are not its own"
[[ "$(pq "SELECT holder || ' ' || generation FROM pgvigil.admin_page_holder")" == "proof-taker $TG" ]] || fail "J: the superseded holder took the lease back while the taker's was alive"
pq "SELECT pgvigil.import_admin_page_release('proof-taker', $TG)" >/dev/null
for _ in $(seq 1 35); do [[ "$(last_applied)" == "$BEFORE" ]] && break; sleep 1; done
[[ "$(last_applied)" == "$BEFORE" ]] || fail "J: 35 s after the release the first collector runs [$(last_applied)] (want [$BEFORE] again)"
[[ "$(grep -c "holds the page's instances now" "$TMPD/run.log")" == $((HOLD0 + 1)) ]] || fail "J: the take-back was not logged once"
[[ "$(pq "SELECT generation FROM pgvigil.admin_page_holder")" == $((TG + 1)) ]] || fail "J: the take-back's generation is $(pq "SELECT generation FROM pgvigil.admin_page_holder") (want $((TG + 1)))"
echo "ok   J: generation $G1 -> $TG (a take-over: the first collector superseded, the file's instance only) -> $((TG + 1)) (taken back: [$BEFORE] again)"
echo "== K. a page instance whose server is down: enabled, added again, added never collected - each active and unreachable =="
docker run -d --name "$PGK" --label "$LBL" --env-file "$TMPD/pg.env" -p 127.0.0.1::5432 "$IMG_PG" >/dev/null
PK=$(docker port "$PGK" 5432/tcp | head -1 | sed 's/.*://')
for _ in $(seq 1 60); do PGPASSWORD=$PG_PW psql "host=127.0.0.1 port=$PK user=postgres dbname=postgres connect_timeout=2" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
KA="engine=postgres host=127.0.0.1 port=$PK dbname=postgres auth=password login=postgres"
active() { pq "SELECT coalesce((SELECT is_active::text FROM pgvigil.instances WHERE name = '$1'), 'no row')"; }
# unreachable NAME SINCE: a 'connect:' error recorded after SINCE (the repository's clock) and the finding, within 120 s
unreachable() { local e f; for _ in $(seq 1 120); do
    e=$(pq "SELECT count(*) FROM pgvigil.collection_dates d JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND d.status = 'error' AND d.note LIKE 'connect: %' AND d.snapshot_at > '$2'")
    f=$(pq "SELECT count(*) FROM pgvigil.findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = '$1' AND f.setting = 'server unreachable' AND f.severity = 'critical'")
    [[ "$e" -gt 0 && "$f" -gt 0 ]] && return 0; sleep 1; done
  tail -5 "$TMPD/run.log" >&2; fail "K: $3: within 120 s: connect errors after $2 = $e, 'server unreachable' findings = $f (want both > 0)"; }
code=$(api POST admin/instances "$(js op=add name=pg-down $KA password=@PG_PW)"); [[ "$code" == 200 ]] || fail "K: add pg-down: $code $(cat "$TMPD/ans.json")"
waitcol pg-down 120 "K"
code=$(api POST admin/instances "$(js op=disable name=pg-down)"); [[ "$code" == 200 && "$(active pg-down)" == false ]] || fail "K: disable: $code, is_active $(active pg-down)"
docker stop -t 5 "$PGK" >/dev/null || fail "K: docker stop"
T0=$(pq "SELECT now()")
code=$(api POST admin/instances "$(js op=enable name=pg-down)"); [[ "$code" == 200 ]] || fail "K: enable: $code"
[[ "$(active pg-down)" == true ]] || fail "K: pg-down is $(active pg-down) right after the enable (want true: its failed connects are recorded only for an active row)"
unreachable pg-down "$T0" "enabled while its server is down"
echo "K: enabled while down: is_active true at the enable; $(pq "SELECT left(detail, 160) FROM pgvigil.findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'pg-down' AND f.setting = 'server unreachable'")"
code=$(api POST admin/instances "$(js op=remove name=pg-down)"); [[ "$code" == 200 && "$(active pg-down)" == false ]] || fail "K: remove: $code, is_active $(active pg-down)"
[[ "$(pq "SELECT count(*) FROM pgvigil.findings f JOIN pgvigil.instances i USING (instance_id) WHERE i.name = 'pg-down' AND f.setting = 'server unreachable'")" == 0 ]] || fail "K: a removed instance is still said unreachable"
T1=$(pq "SELECT now()")
code=$(api POST admin/instances "$(js op=add name=pg-down $KA password=@PG_PW)"); [[ "$code" == 200 ]] || fail "K: add again: $code $(cat "$TMPD/ans.json")"
[[ "$(active pg-down)" == true ]] || fail "K: pg-down is $(active pg-down) right after the add again (want true)"
unreachable pg-down "$T1" "added again after a remove while its server is down"
T2=$(pq "SELECT now()")
code=$(api POST admin/instances "$(js op=add name=pg-never $KA password=@PG_PW)"); [[ "$code" == 200 ]] || fail "K: add pg-never: $code $(cat "$TMPD/ans.json")"
[[ "$(pq "SELECT is_active::text || ' ' || engine || ' ' || platform FROM pgvigil.instances WHERE name = 'pg-never'")" == "true postgres auto" ]] || fail "K: pg-never's row at the add: [$(pq "SELECT is_active::text || ' ' || engine || ' ' || platform FROM pgvigil.instances WHERE name = 'pg-never'")] (want 'true postgres auto')"
unreachable pg-never "$T2" "added while its server is down, never collected"
for n in pg-down pg-never; do code=$(api POST admin/instances "$(js op=remove name=$n)"); [[ "$code" == 200 ]] || fail "K: remove $n: $code"; done
# the SQL Server collector's path (internal/mssql records its failed connects the same way): A's container, stopped last
SA_="engine=sqlserver host=127.0.0.1 port=$PORT_SQL auth=sql login=$MONL options=TrustServerCertificate=true"
code=$(api POST admin/instances "$(js op=add name=sql-down $SA_ password=@MON_PW)"); [[ "$code" == 200 ]] || fail "K: add sql-down: $code $(cat "$TMPD/ans.json")"
waitcol sql-down 120 "K"
code=$(api POST admin/instances "$(js op=disable name=sql-down)"); [[ "$code" == 200 && "$(active sql-down)" == false ]] || fail "K: disable sql-down: $code, is_active $(active sql-down)"
docker stop -t 5 "$SQL" >/dev/null || fail "K: docker stop the SQL Server"
T3=$(pq "SELECT now()")
code=$(api POST admin/instances "$(js op=enable name=sql-down)"); [[ "$code" == 200 && "$(active sql-down)" == true ]] || fail "K: enable sql-down: $code, is_active $(active sql-down)"
unreachable sql-down "$T3" "a SQL Server enabled while its server is down"
code=$(api POST admin/instances "$(js op=remove name=sql-down)"); [[ "$code" == 200 ]] || fail "K: remove sql-down: $code"
# the join's w9e, finding 1: a page add that never connects left a row that kept its engine for good
code=$(api POST admin/instances "$(js op=add name=pg-wrong engine=sqlserver host=127.0.0.1 port="$PA" auth=sql login=sa options=TrustServerCertificate=true password=@PG_PW)"); [[ "$code" == 200 ]] || fail "K: add pg-wrong as sqlserver: $code $(cat "$TMPD/ans.json")"
T4=$(pq "SELECT now()")
unreachable pg-wrong "$T4" "pg-wrong added as sqlserver against a PostgreSQL port"
code=$(api POST admin/instances "$(js op=remove name=pg-wrong)"); [[ "$code" == 200 ]] || fail "K: remove pg-wrong: $code"
[[ "$(pq "SELECT count(*) FROM pgvigil.instances WHERE name = 'pg-wrong'")" == 0 ]] || fail "K: pg-wrong's row (never read) is still there after its remove: $(pq "SELECT engine, is_active, server_version FROM pgvigil.instances WHERE name = 'pg-wrong'")"
code=$(api POST admin/instances "$(js op=add name=pg-wrong engine=postgres host=127.0.0.1 port="$PA" dbname=postgres auth=password login=postgres password=@PG_PW)")
[[ "$code" == 200 ]] || fail "K: pg-wrong added again as postgres: $code $(cat "$TMPD/ans.json") (want 200)"
waitcol pg-wrong 120 "K"
[[ "$(pq "SELECT engine || ' ' || is_active::text FROM pgvigil.instances WHERE name = 'pg-wrong'")" == "postgres true" ]] || fail "K: pg-wrong after its add as postgres: $(pq "SELECT engine, is_active FROM pgvigil.instances WHERE name = 'pg-wrong'")"
code=$(api POST admin/instances "$(js op=remove name=pg-wrong)"); [[ "$code" == 200 ]] || fail "K: remove pg-wrong (postgres): $code"
[[ "$(pq "SELECT count(*) || ' ' || bool_or(is_active)::text FROM pgvigil.instances WHERE name = 'pg-wrong'")" == "1 false" ]] || fail "K: pg-wrong, read once, must keep its row (history) at its remove: $(pq "SELECT count(*) FROM pgvigil.instances WHERE name = 'pg-wrong'")"
echo "K: pg-wrong: added as sqlserver against a PostgreSQL port (unreachable), removed (its never-read row gone), added again as postgres -> 200 and collected; removed again after a read -> its row kept, inactive"
# the join's w9e, finding 4: an explicit platform's first read moves first_seen (the Diff page's 'history from')
PP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
code=$(api POST admin/instances "$(js op=add name=pg-plat engine=postgres host=127.0.0.1 port="$PP" dbname=postgres auth=password login=postgres platform=onprem password=@PG_PW)"); [[ "$code" == 200 ]] || fail "K: add pg-plat: $code $(cat "$TMPD/ans.json")"
[[ "$(pq "SELECT platform || ' ' || (server_version IS NULL)::text FROM pgvigil.instances WHERE name = 'pg-plat'")" == "onprem true" ]] || fail "K: pg-plat's row at its add: $(pq "SELECT platform, server_version FROM pgvigil.instances WHERE name = 'pg-plat'")"
sleep 2; TP=$(pq "SELECT now()")
docker run -d --name "$PGP" --label "$LBL" --env-file "$TMPD/pg.env" -p "127.0.0.1:$PP:5432" "$IMG_PG" >/dev/null || fail "K: docker run pg-plat's server"
waitcol pg-plat 180 "K"
[[ "$(pq "SELECT (first_seen >= '$TP'::timestamptz)::text FROM pgvigil.instances WHERE name = 'pg-plat'")" == true ]] || fail "K: pg-plat (platform onprem) first read after $TP, but first_seen is $(pq "SELECT first_seen FROM pgvigil.instances WHERE name = 'pg-plat'") (the add's time)"
code=$(api POST admin/instances "$(js op=remove name=pg-plat)"); [[ "$code" == 200 ]] || fail "K: remove pg-plat: $code"
echo "K: pg-plat: added with platform onprem while nothing listened, its server started at $TP: first_seen $(pq "SELECT first_seen FROM pgvigil.instances WHERE name = 'pg-plat'") (moved to its first read)"
# a SQL Server page instance never collected (A's container is stopped since sql-down): its row at the add, reported
T5=$(pq "SELECT now()")
code=$(api POST admin/instances "$(js op=add name=sql-never $SA_ password=@MON_PW)"); [[ "$code" == 200 ]] || fail "K: add sql-never: $code $(cat "$TMPD/ans.json")"
[[ "$(pq "SELECT is_active::text || ' ' || engine || ' ' || platform FROM pgvigil.instances WHERE name = 'sql-never'")" == "true sqlserver auto" ]] || fail "K: sql-never's row at the add: [$(pq "SELECT is_active::text || ' ' || engine || ' ' || platform FROM pgvigil.instances WHERE name = 'sql-never'")]"
unreachable sql-never "$T5" "a SQL Server page instance added while its server is down, never collected"
code=$(api POST admin/instances "$(js op=remove name=sql-never)"); [[ "$code" == 200 ]] || fail "K: remove sql-never: $code"
echo "ok   K: enabled while down, added again after a remove while down, added never collected (PostgreSQL and SQL Server), and a SQL Server enabled while down: each active at once and 'server unreachable' (critical) with a new connect error within one interval; a wrong engine removed and added again (200); an explicit platform's first_seen at its first read"
echo "== L. the page on a serve with no UI login (-no-login): read only, a note, no error box; a write refused in the page's words =="
PORTL=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); UL="http://127.0.0.1:$PORTL"
(umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/pgvigil.yaml" -listen "127.0.0.1:$PORTL" -no-login) >"$TMPD/serve-nl.log" 2>&1 & SRVLPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$UL/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVLPID" 2>/dev/null || { cat "$TMPD/serve-nl.log" >&2; fail "L: the -no-login serve exited"; }
NL='adding and changing instances needs the UI login: this server runs with -no-login'
code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -H 'X-Pgvigil: 1' "$UL/api/admin/instances"); [[ "$code" == 200 && "$(ans writable)" == False && "$(ans why_not)" == "$NL" ]] || fail "L: the list on -no-login: $code $(head -c 300 "$TMPD/ans.json")"
printf '%s' "$(js op=add name=pg-nl engine=postgres host=127.0.0.1 port="$PA" dbname=postgres auth=password login=postgres password=@PG_PW)" > "$TMPD/body.json"
code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/body.json" "$UL/api/admin/instances")
[[ "$code" == 403 && "$(cat "$TMPD/ans.json")" == *"$NL"* && "$(pq "SELECT count(*) FROM pgvigil.admin_instances WHERE name = 'pg-nl'")" == 0 ]] || fail "L: an add on -no-login: $code $(head -c 300 "$TMPD/ans.json")"
cat > "$TMPD/l.mjs" <<'JS'
const [port, U] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true }); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
await cmd('Page.navigate', { url: U + '#/admin_instances?w=1h' });
let ok = false;
for (let i = 0; i < 150 && !ok; i++) { ok = await ev(`!!document.querySelector('main .admin-instances h2')`); if (!ok) await sleep(200); }
await sleep(500);
console.log(`ready ${ok}`);
console.log(`errors ${await ev(`document.querySelectorAll('main .error:not([role=status])').length`)}`);
console.log(`note ${JSON.stringify(await ev(`document.querySelector('main [role=note]')?.textContent ?? ''`))}`);
console.log(`enabled ${await ev(`[...document.querySelectorAll('main form button, main form input, main form select, main form textarea, main .actions button')].filter(c => !c.disabled).length`)}`);
console.log(`filters ${await ev(`[...document.querySelectorAll('main .filter-btn')].filter(b => !b.disabled && (b.title ?? '').startsWith('Filter ')).length`)}`);
console.log(`titles ${await ev(`[...new Set([...document.querySelectorAll('main button:disabled')].map(b => b.title))].join(' | ')`)}`);
console.log(`rows ${await ev(`document.querySelectorAll('main table tbody tr').length`)}`);
// a sort redraws a grid's rows through its columns' formats (the join's w9e, finding 5): each grid's first header
// clicked, then the controls that write counted again
console.log(`sorted ${await ev(`[...document.querySelectorAll('main table.grid thead tr:first-child th:first-child')].map(th => (th.click(), 1)).length`)}`);
await sleep(500);
console.log(`enabled2 ${await ev(`[...document.querySelectorAll('main form button, main form input, main form select, main form textarea, main .actions button')].filter(c => !c.disabled).length`)}`);
console.log(`actions2 ${await ev(`document.querySelectorAll('main .actions button').length`)}`);
ws.close(); process.exit(0);
JS
lout=$(node "$TMPD/l.mjs" "$CDP" "$UL/") || fail "L: the Chromium walk stopped: $lout"
echo "$lout"
echo "$lout" | grep -q '^ready true$' && echo "$lout" | grep -q '^errors 0$' && echo "$lout" | grep -q '^enabled 0$' || fail "L: the page on -no-login (an error box, or a control that writes left enabled)"
[[ "$(echo "$lout" | sed -n 's/^filters //p')" -gt 0 ]] || fail "L: the grids' filters were disabled too (they only read)"
echo "$lout" | grep -qF "note \"Read only: $NL.\"" && echo "$lout" | grep -qxF "titles $NL" || fail "L: the note or the hover words"
[[ "$(echo "$lout" | sed -n 's/^rows //p')" -gt 0 ]] || fail "L: the list did not render"
[[ "$(echo "$lout" | sed -n 's/^sorted //p')" -ge 1 && "$(echo "$lout" | sed -n 's/^actions2 //p')" -gt 0 ]] && echo "$lout" | grep -q '^enabled2 0$' || fail "L: after a sort of each grid a control that writes is enabled again, or no grid / action was redrawn (the join's w9e, finding 5)"
kill "$SRVLPID" 2>/dev/null || true; SRVLPID=
echo "ok   L: on -no-login the page lists the instances read only: the note 'Read only: $NL.', no error box, every control that writes disabled with those words on hover, still after a sort redraws each grid, the filters usable; an add refused 403 with them, nothing written"
# L2: the actions door's audit login off: serve on the UI's read-only repository login (docs/app.md), the UI login on
# (the walk signs in by fetch, then loads the page anew: a hash change alone does not redraw the sign-in form)
printf "CREATE ROLE %s LOGIN PASSWORD '%s' IN ROLE pgvigil_reader, pgvigil_auth;\n" "$RDL" "$RDL_PW" | psql "$ADMIN_DSN" -Xq -v ON_ERROR_STOP=1 >/dev/null || fail "L2: the read-only login"
export PGV_RD_DSN="host=127.0.0.1 port=5432 user=$RDL password=$RDL_PW dbname=$PGDB"
sed "s|dsn: \"$PGDSN\"|dsn: env:PGV_RD_DSN|" "$CFGD/pgvigil.yaml" > "$CFGD/reader.yaml"
PORTR=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); UR="http://127.0.0.1:$PORTR"
(umask 022; exec "$TMPD/pgvigil" serve -config "$CFGD/reader.yaml" -listen "127.0.0.1:$PORTR") >"$TMPD/serve-rd.log" 2>&1 & SRVRPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$UR/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVRPID" 2>/dev/null || { cat "$TMPD/serve-rd.log" >&2; fail "L2: the read-only serve exited"; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cjr" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$UR/api/login")" == 200 ]] || fail "L2: the UI login on the read-only serve"
AL="adding and changing instances goes through the actions door's audit login, and it is off: the audit login may not write the actions log"
code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cjr" -H 'X-Pgvigil: 1' "$UR/api/admin/instances")
[[ "$code" == 200 && "$(ans writable)" == False && "$(ans why_not)" == "$AL"* ]] || fail "L2: the list on the read-only serve: $code $(head -c 300 "$TMPD/ans.json")"
ALW=$(ans why_not)
printf '%s' "$(js op=add name=pg-rd engine=postgres host=127.0.0.1 port="$PA" dbname=postgres auth=password login=postgres password=@PG_PW)" > "$TMPD/body.json"
code=$(curl -s -o "$TMPD/ans.json" -w '%{http_code}' -b "$TMPD/cjr" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/body.json" "$UR/api/admin/instances")
[[ "$code" == 403 && "$(cat "$TMPD/ans.json")" == *"$AL"* && "$(pq "SELECT count(*) FROM pgvigil.admin_instances WHERE name = 'pg-rd'")" == 0 ]] || fail "L2: an add on the read-only serve: $code $(head -c 300 "$TMPD/ans.json")"
sed -e "s|await cmd('Page.navigate', { url: U + '#/admin_instances?w=1h' });|await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);\nconsole.log(\`login \${await ev(\`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: \${JSON.stringify(process.env.F_USR)}, password: \${JSON.stringify(process.env.F_UPW)} }) }).then(r => r.status)\`, true)}\`);\nawait cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);\nawait cmd('Page.navigate', { url: U + '#/admin_instances?w=1h' });|" \
  -e "s|const ev = async (expr) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true }); return d.result?.result?.value; };|const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); return d.result?.result?.value; };|" \
  "$TMPD/l.mjs" > "$TMPD/l2.mjs"
grep -q "^console.log(\`login " "$TMPD/l2.mjs" && grep -q 'awaitPromise = false' "$TMPD/l2.mjs" || fail "L2: the walk's login step was not written"
lout=$(F_USR="$USR" F_UPW="$UPW" node "$TMPD/l2.mjs" "$CDP" "$UR/") || fail "L2: the Chromium walk stopped: $lout"
echo "$lout"
echo "$lout" | grep -q '^login 200$' && echo "$lout" | grep -q '^ready true$' && echo "$lout" | grep -q '^errors 0$' && echo "$lout" | grep -q '^enabled 0$' || fail "L2: the page on the read-only serve (no login, an error box, or a control that writes left enabled)"
[[ "$(echo "$lout" | sed -n 's/^filters //p')" -gt 0 ]] || fail "L2: the grids' filters were disabled too"
echo "$lout" | grep -qF "note \"Read only: $ALW.\"" && echo "$lout" | grep -qxF "titles $ALW" || fail "L2: the note or the hover words (want '$ALW')"
kill "$SRVRPID" 2>/dev/null || true; SRVRPID=; unset PGV_RD_DSN   # its password goes no further
echo "ok   L2: on a serve whose repository login is the UI's read-only one the page lists read only: the note 'Read only: $ALW.', no error box, the controls that write disabled with those words on hover, the filters usable; an add refused 403 with them, nothing written"
echo "== M. a page instance never read: 'not read yet (added ...)' on five places until its first read, then the read's time =="
PM=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
code=$(api POST admin/instances "$(js op=add name=pg-m engine=postgres host=127.0.0.1 port="$PM" dbname=postgres auth=password login=postgres platform=onprem password=@PG_PW)"); [[ "$code" == 200 ]] || fail "M: add pg-m: $code $(cat "$TMPD/ans.json")"
MID=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'pg-m'"); [[ -n "$MID" ]] || fail "M: pg-m has no instances row at its add"
[[ "$(pq "SELECT platform || ' ' || (server_version IS NULL)::text FROM pgvigil.instances WHERE instance_id = $MID")" == "onprem true" ]] || fail "M: pg-m's row at the add: $(pq "SELECT platform, server_version FROM pgvigil.instances WHERE instance_id = $MID")"
ADDED=$(pq "SELECT first_seen FROM pgvigil.instances WHERE instance_id = $MID")
# fleet NAME: the instance's last_seen and added_at in /api/instances ("null" when absent)
fleetrow() { [[ "$(api GET instances)" == 200 ]] || fail "M: GET /api/instances: $(head -c 300 "$TMPD/ans.json")"
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); i = {c: n for n, c in enumerate(d["columns"])}
r = [x for x in d["rows"] if x[i["name"]] == sys.argv[2]]
print(json.dumps([r[0][i["last_seen"]], r[0][i["added_at"]]]) if r else "no row")' "$TMPD/ans.json" "$1"; }
cat > "$TMPD/m.mjs" <<'JS'
const [port, U, id] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let n = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++n; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
console.log(`login ${await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.F_USR)}, password: ${JSON.stringify(process.env.F_UPW)} }) }).then(r => r.status)`, true)}`);
// each place: the page, then the text that names pg-m's read (a row of the grid, or the card's 'last seen' cell)
const places = [
  ['servers', '#/admin?atab=servers', `[...document.querySelectorAll('main table tbody tr')].find(tr => [...tr.cells].some(c => c.textContent.trim() === 'pg-m'))?.textContent ?? ''`],
  ['fleet', '#/summary', `[...document.querySelectorAll('main table tbody tr')].find(tr => tr.cells[0]?.textContent.startsWith('pg-m'))?.cells[0].textContent ?? ''`],
  ['card', `#/summary?i=${id}`, `[...document.querySelectorAll('main table.props th')].find(th => th.textContent.trim() === 'last seen')?.nextElementSibling?.textContent ?? ''`],
];
for (const [name, hash, read] of places) {
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await cmd('Page.navigate', { url: U + hash });
  let t = '';
  for (let i = 0; i < 100 && !t; i++) { await sleep(200); t = await ev(read); }
  console.log(`${name} ${JSON.stringify(t)} errors ${await ev(`document.querySelectorAll('main .error:not([role=status])').length`)}`);
}
ws.close(); process.exit(0);
JS
mwalk() { F_USR="$USR" F_UPW="$UPW" node "$TMPD/m.mjs" "$CDP" "$U/" "$MID" || fail "M: the Chromium walk stopped"; }
mreport() { rm -f "$TMPD/rep.zip"; "$TMPD/pgvigil" report -config "$CFGD/pgvigil.yaml" -out "$TMPD/rep.zip" -names >/dev/null 2>&1 || fail "M: pgvigil report"
  python3 -c 'import sys, zipfile; print("\n".join(l for l in zipfile.ZipFile(sys.argv[1]).read("instances.txt").decode().splitlines() if l.split("\t")[0] == "pg-m"))' "$TMPD/rep.zip"; }
F0=$(fleetrow pg-m); M0=$(mwalk); R0=$(mreport)
echo "M: never read: /api/instances $F0"; echo "$M0"; echo "M: report: $R0"
[[ "$F0" == '[null, "'*'"]' ]] || fail "M: /api/instances of a row never read: $F0 (want last_seen null and added_at set)"
echo "$M0" | grep -q '^login 200$' || fail "M: the walk's login"
for place in servers fleet card; do
  line=$(echo "$M0" | grep "^$place ")
  [[ "$line" == *'not read yet (added '* && "$line" == *' errors 0' ]] || fail "M: $place before the first read: $line (want 'not read yet (added ...)', no error box)"
done
[[ "$R0" == *$'\t''not read yet (added '* ]] || fail "M: pgvigil report before the first read: $R0"
TS=$(pq "SELECT now()")
docker run -d --name "$PGM" --label "$LBL" --env-file "$TMPD/pg.env" -p "127.0.0.1:$PM:5432" "$IMG_PG" >/dev/null || fail "M: docker run"
waitcol pg-m 180 "M"
F1=$(fleetrow pg-m); M1=$(mwalk); R1=$(mreport)
echo "M: read: /api/instances $F1"; echo "$M1"; echo "M: report: $R1"
[[ "$F1" == '["'*'", null]' ]] || fail "M: /api/instances after the first read: $F1 (want last_seen set, added_at null)"
for place in servers fleet card; do
  line=$(echo "$M1" | grep "^$place ")
  [[ "$line" != *'not read yet'* && "$line" == *' errors 0' && "$line" != "$place \"\" errors"* ]] || fail "M: $place after the first read: $line (want the read's time, no 'not read yet')"
done
[[ "$(echo "$M1" | grep '^servers ')" == *pg-m* && "$(echo "$M1" | grep '^servers ')" =~ [0-9]{2}:[0-9]{2} && "$(echo "$M1" | grep '^fleet ')" == 'fleet "pg-m"'* ]] || fail "M: Admin > Servers' row or the fleet list's name after the first read: $(echo "$M1" | grep '^servers \|^fleet ')"
[[ "$(echo "$M1" | grep '^card ')" =~ [0-9]{2}:[0-9]{2} ]] || fail "M: the card's last seen after the first read: $(echo "$M1" | grep '^card ')"
[[ "$R1" != *'not read yet'* && "$R1" =~ [0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] || fail "M: pgvigil report after the first read: $R1"
[[ "$(pq "SELECT (first_seen >= '$TS'::timestamptz AND first_seen > '$ADDED'::timestamptz)::text FROM pgvigil.instances WHERE instance_id = $MID")" == true ]] || fail "M: first_seen did not move to the first read (added $ADDED, server started $TS, first_seen $(pq "SELECT first_seen FROM pgvigil.instances WHERE instance_id = $MID"))"
code=$(api POST admin/instances "$(js op=remove name=pg-m)"); [[ "$code" == 200 ]] || fail "M: remove pg-m: $code"
echo "ok   M: pg-m (platform onprem) added while nothing listened: 'not read yet (added ...)' on Admin > Servers, the fleet list, its Summary card and pgvigil report, /api/instances last_seen null with added_at; after its first read the read's time on all five, the words gone, first_seen moved from $ADDED to the read"
# G2: G's scan again after L2 and M (they came after G), the read-only login's password too: serve's two logs, the
# run's log, the API's last answer and every file of M's report zip
for v in MON_PW CMS_PW PG_PW BAD_PW PGPASS_PW RDL_PW; do for f in "$TMPD/ans.json" "$TMPD/serve.log" "$TMPD/serve-rd.log" "$TMPD/run.log"; do
  [[ -f "$f" ]] || continue; ! grep -qF -- "${!v}" "$f" || fail "G2: $v is in $(basename "$f")"; done; done
[[ -f "$TMPD/rep.zip" ]] || fail "G2: M's report zip is gone"
G2S=$(printf '%s\n' "$MON_PW" "$CMS_PW" "$PG_PW" "$BAD_PW" "$PGPASS_PW" "$RDL_PW") python3 - "$TMPD/rep.zip" <<'PY' || fail "G2: a password is in M's report zip"
import os, sys, zipfile
secrets = [x for x in os.environ["G2S"].splitlines() if x]
z = zipfile.ZipFile(sys.argv[1]); bad = 0
for n in z.namelist():
    t = z.read(n).decode(errors="replace")
    for i, v in enumerate(secrets):
        if v in t:
            print("G2: password %d is in the report's %s" % (i, n)); bad = 1
sys.exit(bad)
PY
echo "ok   G2: after L2 and M no password (the read-only login's too) in serve's two logs, the run's log, the API's last answer or M's report zip ($(python3 -c 'import sys, zipfile; print(len(zipfile.ZipFile(sys.argv[1]).namelist()))' "$TMPD/rep.zip") files)"
echo "proof-instances: OK (the CMS and the pg_service.conf proposed, approved, collected, a gone server marked; add, test, edit, disable, enable, remove through the API and the page in both themes; no credential in the repository, a .pgpass refused as a list; no restart; a second collector leaves the page's instances to the first; a fenced lease; a page instance whose server is down seen unreachable after enable, re-add and a first add; read only on -no-login and with the audit login off, no error box; a page instance never read says so until its first read; the NOT PROVEN lines above stand)"
