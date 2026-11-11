#!/usr/bin/env bash
# Proof of the PostgreSQL database options and setting overrides (task 163): the dbsettings collection, migration 0104,
# /api/pg/dboptions and its fleet part, and the page pg_dboptions.ts, on PostgreSQL 13, 16 and 18.
#
#   PGVIGIL_BIN     a pgvigil binary to use (it must carry the page's wiring); default: the proof builds one from a
#                   temporary copy of this tree, with the wiring applied there while the tree lacks it (the WIRING BLOCK
#                   of the task's report: web.go's two routes, router.ts's two tabs, main.ts's two pages).
#   PGDBO_VERSIONS  the monitored PostgreSQL majors (default "13 16 18"); PGDBO_REPO_PG the repository's (default 13, the
#                   oldest the CI covers); PGDBO_PAGE_PG the server whose page is read in the browser (default the last).
#   PGDBO_SHOTS     a folder for the page's pictures (default: inside the temporary folder, removed at the end).
#   Needs: docker, psql, curl, python3; go, node and npm with web/node_modules ('npm ci' in web/ first) and chromium
#   without PGVIGIL_BIN (chromium and node with it).
# Containers of the proof's own on 127.0.0.1 ports the system hands out: one per monitored version and a repository
# server; all are removed with their volumes at the end, and that is read back. Nothing that exists before the run is
# touched. The collector reads as a login holding pg_monitor only; the seeds are made as the containers' superuser.
#
# Expected (written before the first run). On each version V:
#  A. migrate applies 0104 on the repository server. Each collection of the page (instance, databases, connections,
#     versions, dbsettings) ends ok as the pg_monitor login.
#  B. no override: pg_db_role_settings holds 0 rows for the instance, pg_db_role_settings_read holds its read with
#     overrides 0; pg_db_options holds one row per database of a hand read of pg_database; the database postgres reads
#     connection limit ok ('no limit'), allow connections ok, encoding ok (UTF8).
#  C. the server refuses ALTER DATABASE ... SET autovacuum = off ('cannot be changed now': autovacuum is a reload
#     setting), so the critical override of a database is track_counts = off and of a role zero_damaged_pages = on.
#     Seeded (16 overrides; the review's spellings among them): ALTER DATABASE dbo_t SET track_counts = off, jit =
#     'true', random_page_cost = '1.1e0', timezone = 'UTC'; ALTER ROLE dbo_app SET zero_damaged_pages = on,
#     log_statement = 'ALL', idle_in_transaction_session_timeout = '2.5s', statement_timeout = '2.5ms' (if the server
#     takes it), app.tenant = 'x' (a placeholder), enable_indexscan = 'of', work_mem = '1.3GB', log_min_messages =
#     'debug'; ALTER ROLE dbo_app IN DATABASE dbo_t SET synchronous_commit = off, idle_in_transaction_session_timeout =
#     '5min', statement_timeout = '0.1d'; ALTER ROLE ALL SET work_mem = '256MB'. After dbsettings:
#     - the rows equal a hand read of pg_db_role_setting (one per name=value), each scope as set; timezone is stored
#       and kept as TimeZone, known (a string: not read);
#     - no override the server knows is left unread but the string; every value read equals pg_settings.setting after a
#       set_config of the raw text on the server itself, and pinned: work_mem 262144 (all roles) and 1362944 (1.3GB,
#       rounded to whole MB first), 2.5s 2500, 5min 300000, 0.1d 7200000, ALL all, true on, of off, 1.1e0 1.1, debug
#       debug2;
#     - every override's status equals what 0099's rule view, run from its own file over the override's value, says
#       (crit / warn / ok / none); the placeholder is none, known false;
#     - track_counts at scope database and zero_damaged_pages at scope role are crit with severity critical while the
#       server's own are ok (green); 9 overrides break a rule (the two critical; synchronous_commit, both work_mem, jit,
#       log_statement, enable_indexscan, log_min_messages), a number from the seeds;
#     - pg_override_findings holds one row per override whose status is crit or warn, exactly those;
#     - pgvigil.setting_rules holds exactly the rows 0099's view yields on the same store (0 only in either), and its
#       rule lines are 0099's word for word once the scope key is taken out (a text comparison);
#     - an instance read now takes ALTER ROLE ALL SET work_mem as the server's value (pg_settings source global): the
#       server's work_mem reads 262144, and that override's row says its server value is read under it.
#  D. connection limit: CREATE DATABASE dbo_c CONNECTION LIMIT 1 and one session of dbo_hold in it: a second session of
#     dbo_hold is refused by the server ('too many connections'); after connections and databases dbo_c's cell is crit
#     ('reached') with a critical finding 'database connection limit'. CONNECTION LIMIT 5 and four sessions: warn
#     ('near'), a warning finding. The sessions ended: ok, the finding gone. CONNECTION LIMIT 0: warn 'closed'.
#     [Run 1, box job s163-proof1, 2026-11-11 15:17 PST: A to C green on PostgreSQL 13; D let the second session in.
#     Cause: the sessions logged in as dbo_app, whose statement_timeout C had set to 2.5 ms, so the held session ended
#     at once. Fixed: the held sessions log in as dbo_hold, a role without overrides, and a hold is read again a second
#     later; the expectation unchanged.]
#     ALLOW_CONNECTIONS false on dbo_x: allow warn with its finding; true again: ok, gone. dbo_l (LATIN1, C): encoding
#     warn (advice, an info finding); its collation cell grey (C has no version on 15+, 'PostgreSQL 15+' on 13);
#     template0's encoding cell grey. The collation cell (15+): datcollversion of dbo_t written to '0.0' by hand: after
#     versions warn, recorded 0.0; ALTER DATABASE dbo_t REFRESH COLLATION VERSION: ok again. On 13 every collation cell
#     is grey. Data checksums: each row's cell is ok where the server's data_checksums (a hand read) is on, warn where it
#     is off (the images: off before 18, on from 18). xid age: each row's age equals the server's age(datfrozenxid) at
#     the read within the xids used since; ok on a fresh server; dbo_x frozen (VACUUM FREEZE) and a few xids used after:
#     in a transaction rolled back, with the stored freeze age set just above dbo_x's age, dbo_x is ok and every older
#     database warn (at least one each), and an age written as 1.2 billion is crit.
#     [Run 5, box job s163-proof5, 15:40 PST: C green up to the instance read, which read 262144 warn as expected; the
#     flag came back as psql's 't' for 'true': the query casts it to text since.]
#     [Run 4, box job s163-proof4, 15:39 PST: C's hand read differed only in 'timezone' against the stored 'TimeZone':
#     the comparison is case-blind on the name since, the spelling checked on its own.]
#     [Run 2, box job s163-proof2, 15:18 PST: the freeze age of 100 found no database at or past it ('warn 0 0': a
#     fresh cluster's ages are under 100). Run 3 set it to the smallest age, which the review showed cannot fail its
#     'younger stays ok' half; the frozen dbo_x makes both halves able to fail.]
#  E. the fleet's risk counts (pg_dboption_risks) while dbo_c is at its limit and the overrides are set: at_limit 1,
#     not_utf8 1 (template0 not judged), overrides_broken 9, overrides_critical 2, checksums_off = the databases when
#     data_checksums is off, else 0; each count equals a count of pg_db_options / override_rules.
#  F. undo: every override RESET: after dbsettings 0 rows, the findings gone; an instance read: the server's work_mem
#     4096 and green again, track_counts and zero_damaged_pages green.
#  G. the API (on PGDBO_PAGE_PG, which must be one of the versions; while C to E are seeded): /api/pg/dboptions?instance=
#     <id> answers 200 with the parts state, databases, overrides, overrides_read, findings, their row counts the
#     views'; ?part=overrides alone; /api/pg/dboptions/fleet one risks row per active PostgreSQL instance.
#  H. the page in a headless Chromium, light and dark theme, solid and quiet status style (four pictures): the
#     Databases grid and the Setting overrides grid drawn; dbo_c's connection cell red with a title 'deviates:
#     critical: reached ...'; the database override of track_counts red beside the server's value green; a grey cell;
#     every coloured cell carries a title; no exception. The fleet page: the instance's 'At connection limit' count is a
#     red link to risk=at_limit, which opens a grid of exactly dbo_c. PASS is printed only when G and H ran.
#  The collection versions may end 'partial' (a part it reads elsewhere); the run says so in a line.
#  Z. every container and its volumes gone: 0 left.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSIONS=$(echo ${PGDBO_VERSIONS:-13 16 18}); RPG=${PGDBO_REPO_PG:-13}; PAGE_PG=${PGDBO_PAGE_PG:-${VERSIONS##* }}
[[ " $VERSIONS " == *" $PAGE_PG "* ]] || { echo "FAIL: PGDBO_PAGE_PG $PAGE_PG is not one of the versions ($VERSIONS)" >&2; exit 1; }
PAGE_RAN=""
SUF=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
SUPW=s$RANDOM$RANDOM$RANDOM; MONPW=m$RANDOM$RANDOM$RANDOM; APPPW=a$RANDOM$RANDOM$RANDOM
MON=dbo_mon_$SUF; REPO_DB=pgvigil_dbo_$SUF
WORK=$(mktemp -d); CIDS=(); HOLD=(); SRVPID=""; CHRPID=""
SHOTS=${PGDBO_SHOTS:-$WORK/shots}; mkdir -p "$SHOTS"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
cleanup() {
  local rc=$? left vols=""
  set +e   # every step of the cleanup runs, whatever one of them returns
  [[ -n "$CHRPID" ]] && kill -- -"$CHRPID" 2>/dev/null
  for p in "${HOLD[@]}" $SRVPID $CHRPID; do kill "$p" 2>/dev/null; done
  for c in "${CIDS[@]}"; do vols+=" $(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$c" 2>/dev/null)"; done
  [[ ${#CIDS[@]} -gt 0 ]] && docker rm -f -v "${CIDS[@]}" >/dev/null 2>&1
  wait 2>/dev/null
  left=0
  for c in "${CIDS[@]}"; do docker inspect "$c" >/dev/null 2>&1 && left=$((left + 1)); done
  for v in $vols; do docker volume inspect "$v" >/dev/null 2>&1 && left=$((left + 1)); done
  rm -rf "$WORK"
  echo "Z: containers and volumes of this proof left: $left"
  [[ $left -eq 0 ]] || { echo "FAIL: Z: $left left" >&2; rc=1; }
  exit $rc
}
trap cleanup EXIT
for t in docker psql curl python3 node chromium setsid; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done

# ---- the binary: this tree's bundle and the page's wiring, built in a temporary copy
if [[ -n "${PGVIGIL_BIN:-}" ]]; then
  BIN=$PGVIGIL_BIN; WIRED="a given binary"
else
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN is not set"
  [[ -d web/node_modules ]] || fail "no web/node_modules: run 'npm ci' in web/ first"
  mkdir -p "$WORK/src"
  tar --exclude=./web/node_modules --exclude=./.git --exclude=./bin -cf - . | tar -xf - -C "$WORK/src"
  ln -s "$PWD/web/node_modules" "$WORK/src/web/node_modules"
  if grep -q 'pgDbOptionsView' web/src/main.ts; then
    WIRED="wired in this tree"
  else
    python3 -I - "$WORK/src" <<'PY' || fail "the wiring no longer applies to the copy (web.go, router.ts or main.ts changed): see the report's WIRING BLOCK"
import sys, os
root = sys.argv[1]
def edit(path, old, new):
    p = os.path.join(root, path); s = open(p).read()
    assert s.count(old) == 1, '%s: %d matches of %r' % (path, s.count(old), old[:60])
    open(p, 'w').write(s.replace(old, new))
edit('internal/web/web.go', '\tapi.HandleFunc("GET /api/pgconfig", s.PGConfig)\n',
     '\tapi.HandleFunc("GET /api/pgconfig", s.PGConfig)\n\tapi.HandleFunc("GET /api/pg/dboptions", s.PGDBOptions)\n\tapi.HandleFunc("GET /api/pg/dboptions/fleet", s.PGDBOptionsFleet)\n')
edit('web/src/router.ts', "mssqlrisks: 'SQL Server options', ", "mssqlrisks: 'SQL Server options', pgrisks: 'PostgreSQL options', ")
edit('web/src/router.ts', "config: 'Configuration', findings: 'Findings',", "config: 'Configuration', pgdboptions: 'Database options', findings: 'Findings',")
edit('web/src/router.ts', "tabs: ['versions', 'extensions', 'roles', 'diff', 'mssqlrisks'] }", "tabs: ['versions', 'extensions', 'roles', 'diff', 'mssqlrisks', 'pgrisks'] }")
edit('web/src/router.ts', "tabs: ['config', 'extensions', 'versions', 'roles', 'audit', 'schema', 'actions'] }", "tabs: ['config', 'pgdboptions', 'extensions', 'versions', 'roles', 'audit', 'schema', 'actions'] }")
edit('web/src/router.ts', "  if (keep && c.tab === 'mssqlchecks') {",
     "  if (keep && c.tab === 'pgdboptions') {\n    const cur = new URLSearchParams(location.hash.split('?')[1] ?? '');\n    const v = cur.get('risk'); if (v) q.set('risk', v);\n  }\n  if (keep && c.tab === 'mssqlchecks') {")
edit('web/src/main.ts', "import { mssqlChecksFleetView, mssqlChecksView } from './mssql_checks';\n",
     "import { mssqlChecksFleetView, mssqlChecksView } from './mssql_checks';\nimport { pgDbOptionsFleetView, pgDbOptionsView } from './pg_dboptions';\n")
edit('web/src/main.ts', "dms, config,\n", "dms, config, pgdboptions: pgDbOptionsView,\n")
edit('web/src/main.ts', "mssqlrisks: mssqlChecksFleetView, ", "mssqlrisks: mssqlChecksFleetView, pgrisks: pgDbOptionsFleetView, ")
PY
    WIRED="wired in a temporary copy (the report's WIRING BLOCK)"
  fi
  (cd "$WORK/src/web" && npm run build >"$WORK/web.log" 2>&1) || { tail -30 "$WORK/web.log"; fail "the web build"; }
  (cd "$WORK/src" && CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil) || fail "the go build"
  BIN=$WORK/pgvigil
fi
echo "binary: $WIRED"

freeport() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
up() {   # the image restarts the server once after its first start: two answers a second apart
  local dsn=$1 n=0
  for _ in $(seq 1 120); do
    if psql "$dsn" -XAtqc 'select 1' >/dev/null 2>&1; then n=$((n + 1)); [[ $n -ge 2 ]] && return 0; else n=0; fi
    sleep 1
  done
  return 1
}
declare -A PORT SU MONDSN APPDSN INST
start_pg() {   # start_pg <key> <major>
  local k=$1 v=$2 p
  p=$(freeport); PORT[$k]=$p
  CIDS+=("pgdbo$SUF-$k")   # by name, before the run: a container created and not started is removed too
  docker run -d --name "pgdbo$SUF-$k" -e POSTGRES_PASSWORD="$SUPW" -p "127.0.0.1:$p:5432" "postgres:$v" > "$WORK/$k.id" \
    || fail "the PostgreSQL $v container did not start"
  SU[$k]="host=127.0.0.1 port=$p user=postgres password=$SUPW dbname=postgres sslmode=disable"
}
echo "--- A. the servers: PostgreSQL $VERSIONS monitored, $RPG the repository"
start_pg repo "$RPG"
for v in $VERSIONS; do start_pg "$v" "$v"; done
up "${SU[repo]}" || fail "A: the repository server did not come up: $(docker logs "pgdbo$SUF-repo" 2>&1 | tail -5)"
for v in $VERSIONS; do
  up "${SU[$v]}" || fail "A: PostgreSQL $v did not come up: $(docker logs "pgdbo$SUF-$v" 2>&1 | tail -5)"
  psql "${SU[$v]}" -XAtq -v ON_ERROR_STOP=1 -c "create role $MON login password '$MONPW' in role pg_monitor" \
    -c "create role dbo_app login password '$APPPW'" -c "create role dbo_hold login password '$APPPW'" -c "create database dbo_t" -c "create database dbo_x" \
    -c "create database dbo_l encoding 'LATIN1' lc_collate 'C' lc_ctype 'C' template template0" >/dev/null
  MONDSN[$v]="host=127.0.0.1 port=${PORT[$v]} user=$MON password=$MONPW dbname=postgres sslmode=disable"
  # the sessions of D log in as dbo_hold: dbo_app carries C's overrides (its statement_timeout would end a held session)
  APPDSN[$v]="host=127.0.0.1 port=${PORT[$v]} user=dbo_hold password=$APPPW sslmode=disable"
  INST[$v]=pgdbo-$v-$SUF
  export "MON_DSN_$v=${MONDSN[$v]}"
done
psql "${SU[repo]}" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=${PORT[repo]} user=postgres password=$SUPW dbname=$REPO_DB sslmode=disable"
CFG=$WORK/pgvigil.yaml
{ echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  for v in $VERSIONS; do echo "  - name: ${INST[$v]}"; echo "    dsn: env:MON_DSN_$v"; done; } > "$CFG"
"$BIN" migrate -config "$CFG" >"$WORK/migrate.out" 2>&1 || { tail -5 "$WORK/migrate.out"; fail "A: migrate"; }
[[ $(psql "$PGVIGIL_REPO_DSN" -XAtqc "select count(*) from pgvigil.schema_version where filename like '0104%'" 2>/dev/null || echo 0) == 1 ]] \
  || [[ $(psql "$PGVIGIL_REPO_DSN" -XAtqc "select to_regclass('pgvigil.pg_db_role_settings') is not null") == t ]] || fail "A: 0104 was not applied"
ok "A: migrate applied 0104 on PostgreSQL $RPG"

q() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
qf() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -f "$1"; }
s() { local v=$1; shift; psql "${SU[$v]}" -XAtq -v ON_ERROR_STOP=1 -c "$*"; }
collect() {   # collect <v> <collection>...
  local v=$1 c; shift
  for c in "$@"; do
    "$BIN" collect -config "$CFG" -instance "${INST[$v]}" -once "$c" >"$WORK/collect.out" 2>&1 || fail "collect $c on PostgreSQL $v: $(tail -3 "$WORK/collect.out")"
    st=$(q "select status from pgvigil.collection_dates where instance_id = $(iid "$v") and collection = '$c'")
    [[ $st == ok ]] || [[ $c == versions && $st == partial ]] \
      || fail "collect $c on PostgreSQL $v did not end ok: $(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id = $(iid "$v") and collection = '$c'")"
    [[ $st == ok ]] || echo "  (collect $c on PostgreSQL $v ended $st: $(q "select coalesce(note, '') from pgvigil.collection_dates where instance_id = $(iid "$v") and collection = '$c'"))"
  done
}
iid() { q "select instance_id from pgvigil.instances where name = '${INST[$1]}'"; }
all() { collect "$1" instance databases connections versions dbsettings; }

# the 0099 rule view, from its own file, as a temporary view over a source named by the caller
R99=internal/repo/sql/0099_pg_setting_rules.sql
[[ "$(sed -n 12p $R99)" == "CREATE OR REPLACE VIEW pgvigil.setting_rules AS" ]] || fail "0099's setting_rules view is not at line 12"
[[ "$(sed -n 105p $R99)" == "  FROM c JOIN v ON v.instance_id = c.instance_id AND v.name = c.name;" ]] || fail "0099's setting_rules view does not end at line 105"
rules99() { echo "CREATE TEMP VIEW $1 AS"; sed -n 13,105p $R99 | sed "s/FROM pgvigil.instance_settings\$/FROM $2/"; }

# rules_text: 0104's rule lines with the scope key taken out = 0099's lines 13-105 with its source renamed
R104=internal/repo/sql/0104_pg_db_options.sql
rules_text() {
  python3 -I - "$R99" "$R104" <<'PY' || fail "C: 0104's rule lines are not 0099's"
import sys
r99 = open(sys.argv[1]).read().split('\n')[12:105]
t = open(sys.argv[2]).read()
a = t.index('CREATE OR REPLACE VIEW pgvigil.setting_rules_scoped AS\n') + len('CREATE OR REPLACE VIEW pgvigil.setting_rules_scoped AS\n')
b = t.index('\n\n', a)
body = t[a:b]
for old, new in [
    ('instance_id, k, scope, dbid, datname, roleid, rolname, snapshot_at', 'instance_id, snapshot_at'),
    ('FROM pgvigil.setting_values', 'FROM pgvigil.instance_settings'),
    ('instance_id, k, name, ', 'instance_id, name, '), ('v.instance_id, v.k, v.name, ', 'v.instance_id, v.name, '),
    (' AND c.k = v.k', ''), (' AND v.k = r.k', ''), (' AND v.k = c.k', ''),
    ('v.instance_id, v.scope, v.dbid, v.datname, v.roleid, v.rolname, ', 'v.instance_id, ')]:
    body = body.replace(old, new)
mine = body.split('\n')
if mine != r99:
    import difflib
    print('\n'.join(list(difflib.unified_diff(r99, mine, lineterm=''))[:20]))
    sys.exit(1)
print('ok: C: 0104\'s %d rule lines = 0099\'s once the scope key is taken out' % len(mine))
PY
}

# same: pgvigil.setting_rules against 0099's view over the same store
same() {
  { rules99 old_rules pgvigil.instance_settings
    echo "SELECT (SELECT count(*) FROM pgvigil.setting_rules) || ' ' ||"
    echo "  (SELECT count(*) FROM (SELECT * FROM old_rules EXCEPT ALL SELECT * FROM pgvigil.setting_rules) a) || ' ' ||"
    echo "  (SELECT count(*) FROM (SELECT * FROM pgvigil.setting_rules EXCEPT ALL SELECT * FROM old_rules) b);"; } > "$WORK/same.sql"
  read -r N A B < <(qf "$WORK/same.sql" | tail -1)
  [[ "$N" -gt 0 && "$A" == 0 && "$B" == 0 ]] || fail "$1: setting_rules differ from 0099's view: $N rows, $A only in 0099's, $B only in the new"
  ok "$1: setting_rules = 0099's view on the same store ($N rows, 0 only in either): no override in the server's rows"
}

# oracle: each override's status from 0099's rule view run over the override's own value
oracle() {   # oracle <v>: prints '<judged> <differ>'
  local id; id=$(iid "$1")
  { echo "CREATE TEMP TABLE iset AS"
    echo "SELECT (row_number() OVER (ORDER BY o.scope, o.dbid, o.roleid, o.name))::int AS instance_id, o.snapshot_at, st.platform,"
    echo "       st.server_version_num, st.is_replica, o.name, o.value, true AS is_set, o.scope AS o_scope, o.dbid AS o_dbid, o.roleid AS o_roleid"
    echo "  FROM pgvigil.pg_db_role_settings o JOIN pgvigil.instance_state st ON st.instance_id = o.instance_id"
    echo " WHERE o.instance_id = $id AND o.value_read;"
    rules99 orules pg_temp.iset
    echo "WITH e AS (SELECT i.o_scope, i.o_dbid, i.o_roleid, i.name,"
    echo "    CASE WHEN NOT coalesce(bool_or(r.applies), false) THEN 'none' WHEN bool_or(r.hit AND r.applies AND r.severity = 'critical') THEN 'crit'"
    echo "         WHEN bool_or(r.hit AND r.applies) THEN 'warn' ELSE 'ok' END AS status"
    echo "    FROM pg_temp.iset i LEFT JOIN orules r ON r.instance_id = i.instance_id GROUP BY 1, 2, 3, 4)"
    echo "SELECT (SELECT count(*) FROM e WHERE e.status <> 'none') || ' ' ||"
    echo "  (SELECT count(*) FROM pgvigil.override_rules o LEFT JOIN e ON e.o_scope = o.scope AND e.o_dbid = o.dbid AND e.o_roleid = o.roleid AND e.name = o.setting"
    echo "    WHERE o.instance_id = $id AND o.status IS DISTINCT FROM coalesce(e.status, 'none'));"; } > "$WORK/oracle.sql"
  qf "$WORK/oracle.sql" | tail -1
}

# hand: one name=value per row of pg_db_role_setting on the server, as '<scope>|<datname>|<rolname>|<name>|<raw>'
hand_overrides() {
  s "$1" "select case when s.setdatabase <> 0 and s.setrole <> 0 then 'role in database' when s.setrole <> 0 then 'role' when s.setdatabase <> 0 then 'database' else 'all roles' end
            || '|' || coalesce(d.datname, '') || '|' || coalesce(r.rolname, '') || '|' || lower(split_part(c, '=', 1)) || '|' || substr(c, strpos(c, '=') + 1)
       from pg_db_role_setting s cross join lateral unnest(s.setconfig) c left join pg_database d on d.oid = s.setdatabase left join pg_roles r on r.oid = s.setrole order by 1"
}
stored_overrides() {
  # the name case-blind: the store keeps PostgreSQL's own spelling (TimeZone), checked on its own in C
  q "select scope || '|' || datname || '|' || rolname || '|' || lower(name) || '|' || raw_value from pgvigil.pg_db_role_settings where instance_id = $(iid "$1") order by 1"
}
ostatus() { q "select coalesce(string_agg(status || ' ' || coalesce(severity, '-'), ','), 'absent') from pgvigil.override_rules where instance_id = $(iid "$1") and scope = '$2' and setting = '$3'"; }
srvstatus() { q "select status from pgvigil.pg_setting_rules($(iid "$1")) where setting = '$2'"; }
dbcell() { q "select ${3}_status || ' ' || coalesce(${3}_severity, '-') from pgvigil.pg_db_options where instance_id = $(iid "$1") and datname = '$2'"; }
dbfind() { q "select count(*) || ' ' || coalesce(max(severity), '-') from pgvigil.pg_dboption_findings where instance_id = $(iid "$1") and setting = '$2' and value like '$3%'"; }
hold() {   # hold <v> <db> <n>: n sessions of dbo_hold in the database, each asleep until killed
  local i
  for i in $(seq 1 "$3"); do
    psql "${APPDSN[$1]} dbname=$2" -XAtqc "select pg_sleep(600)" >/dev/null 2>&1 & HOLD+=($!)
  done
  for _ in $(seq 1 50); do
    if [[ $(s "$1" "select count(*) from pg_stat_activity where datname = '$2' and usename = 'dbo_hold' and state = 'active'") -ge $3 ]]; then
      sleep 1   # still there a second later: a session that ends at once is no hold
      [[ $(s "$1" "select count(*) from pg_stat_activity where datname = '$2' and usename = 'dbo_hold' and state = 'active'") -ge $3 ]] && return 0
      fail "D: the $3 sessions of dbo_hold in $2 ended within a second on PostgreSQL $1"
    fi
    sleep 0.2
  done
  fail "D: $3 sessions of dbo_hold did not start in $2 on PostgreSQL $1"
}
unhold() {
  s "$1" "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = '$2' and usename = 'dbo_hold'" >/dev/null
  for p in "${HOLD[@]}"; do wait "$p" 2>/dev/null || true; done; HOLD=()
  for _ in $(seq 1 50); do
    [[ $(s "$1" "select count(*) from pg_stat_activity where datname = '$2' and usename = 'dbo_hold'") == 0 ]] && return 0
    sleep 0.2
  done
  fail "D: the sessions of dbo_hold in $2 did not end on PostgreSQL $1"
}

for V in $VERSIONS; do
  echo "=== PostgreSQL $V ($(s "$V" "show server_version"))"
  all "$V"; ID=$(iid "$V")
  echo "--- B. no override"
  [[ $(q "select count(*) from pgvigil.pg_db_role_settings where instance_id = $ID") == 0 ]] || fail "B: override rows on a server without any"
  [[ $(q "select overrides from pgvigil.pg_db_role_settings_read where instance_id = $ID") == 0 ]] || fail "B: no read row with overrides 0"
  HD=$(s "$V" "select count(*) from pg_database"); SD=$(q "select count(*) from pgvigil.pg_db_options where instance_id = $ID")
  [[ "$HD" == "$SD" ]] || fail "B: pg_db_options holds $SD databases, the server $HD"
  [[ "$(dbcell "$V" postgres conn) $(dbcell "$V" postgres allow) $(dbcell "$V" postgres encoding)" == "ok - ok - ok -" ]] \
    || fail "B: postgres reads conn / allow / encoding '$(dbcell "$V" postgres conn) / $(dbcell "$V" postgres allow) / $(dbcell "$V" postgres encoding)'"
  ok "B: 0 overrides, read; $SD databases = the server's; postgres green on connection limit, allow connections and encoding"

  echo "--- C. overrides"
  if s "$V" "alter database dbo_t set autovacuum = off" >"$WORK/av.out" 2>&1; then fail "C: the server took ALTER DATABASE ... SET autovacuum"; fi
  grep -q 'cannot be changed now' "$WORK/av.out" || fail "C: the refusal reads '$(cat "$WORK/av.out")'"
  ok "C: the server refuses ALTER DATABASE ... SET autovacuum = off ($(grep -o 'parameter "autovacuum" cannot be changed now' "$WORK/av.out"))"
  s "$V" "alter database dbo_t set track_counts = off" >/dev/null
  s "$V" "alter role dbo_app set zero_damaged_pages = on" >/dev/null
  s "$V" "alter role dbo_app in database dbo_t set synchronous_commit = off" >/dev/null
  s "$V" "alter role all set work_mem = '256MB'" >/dev/null
  s "$V" "alter database dbo_t set jit = 'true'" >/dev/null
  s "$V" "alter role dbo_app set log_statement = 'ALL'" >/dev/null
  s "$V" "alter role dbo_app set idle_in_transaction_session_timeout = '2.5s'" >/dev/null
  if s "$V" "alter role dbo_app set statement_timeout = '2.5ms'" >/dev/null 2>"$WORK/st.err"; then echo "statement_timeout '2.5ms' taken"; else echo "statement_timeout '2.5ms' refused: $(head -1 "$WORK/st.err")"; fi
  s "$V" "alter role dbo_app set app.tenant = 'x'" >/dev/null
  s "$V" "alter role dbo_app set enable_indexscan = 'of'" >/dev/null
  s "$V" "alter role dbo_app set work_mem = '1.3GB'" >/dev/null
  s "$V" "alter role dbo_app set log_min_messages = 'debug'" >/dev/null
  s "$V" "alter database dbo_t set random_page_cost = '1.1e0'" >/dev/null
  s "$V" "alter database dbo_t set timezone = 'UTC'" >/dev/null
  s "$V" "alter role dbo_app in database dbo_t set idle_in_transaction_session_timeout = '5min'" >/dev/null
  s "$V" "alter role dbo_app in database dbo_t set statement_timeout = '0.1d'" >/dev/null
  collect "$V" dbsettings
  hand_overrides "$V" | LC_ALL=C sort > "$WORK/hand.txt"; stored_overrides "$V" | LC_ALL=C sort > "$WORK/stored.txt"
  cmp -s "$WORK/hand.txt" "$WORK/stored.txt" || { diff "$WORK/hand.txt" "$WORK/stored.txt" || true; fail "C: the stored overrides differ from the server's pg_db_role_setting"; }
  NO=$(q "select count(*) from pgvigil.pg_db_role_settings where instance_id = $ID")
  ok "C: $NO stored overrides = the server's pg_db_role_setting, scope by scope"
  # every value read, against the server's own reading of the raw text
  BAD=0; NH=0
  while IFS='|' read -r name raw val; do
    printf 'begin;\nselect set_config(%s, %s, true) is null;\nselect setting from pg_settings where name = %s;\nrollback;\n' \
      "'$name'" "'$raw'" "'$name'" > "$WORK/hand.sql"
    got=$(psql "${SU[$V]}" -XAtq -v ON_ERROR_STOP=1 -f "$WORK/hand.sql" < /dev/null | tail -1) || fail "C: the server did not read $name = '$raw'"
    NH=$((NH + 1))
    [[ "$got" == "$val" ]] || { echo "  $name '$raw': the collector read '$val', the server '$got'"; BAD=$((BAD + 1)); }
  done < <(q "select name || '|' || raw_value || '|' || value from pgvigil.pg_db_role_settings where instance_id = $ID and known and value_read order by 1")
  [[ $BAD == 0 ]] || fail "C: $BAD of $NH values differ from the server's own reading"
  UNREAD=$(q "select coalesce(string_agg(name || ' (' || scope || ')', ', '), '') from pgvigil.pg_db_role_settings where instance_id = $ID and known and not value_read and vartype <> 'string'")
  [[ -z "$UNREAD" ]] || fail "C: overrides the server knows left unread: $UNREAD"
  PIN=$(q "select string_agg(scope || ':' || name || '=' || value, ' ' order by scope, name) from pgvigil.pg_db_role_settings where instance_id = $ID
           and (name in ('work_mem', 'idle_in_transaction_session_timeout', 'log_statement', 'jit', 'enable_indexscan', 'random_page_cost', 'log_min_messages')
                or (scope = 'role in database' and name = 'statement_timeout'))")
  WANT_PIN="all roles:work_mem=262144 database:jit=on database:random_page_cost=1.1 role:enable_indexscan=off role:idle_in_transaction_session_timeout=2500 role:log_min_messages=debug2 role:log_statement=all role:work_mem=1362944 role in database:idle_in_transaction_session_timeout=300000 role in database:statement_timeout=7200000"
  [[ "$PIN" == "$WANT_PIN" ]] || fail "C: the pinned values read '$PIN', expected '$WANT_PIN'"
  TZ_ROW=$(q "select name || ' ' || known || ' ' || value_read from pgvigil.pg_db_role_settings where instance_id = $ID and lower(name) = 'timezone'")
  [[ "$TZ_ROW" == "TimeZone true false" ]] || fail "C: timezone reads '$TZ_ROW', expected 'TimeZone true false'"
  ok "C: no known override left unread but the string; pinned: $PIN; TimeZone known, a string not read"
  ok "C: $NH values in the base unit = pg_settings.setting after set_config of the raw text ($(q "select string_agg(name || ' ' || raw_value || '=' || value, ', ' order by name) from pgvigil.pg_db_role_settings where instance_id = $ID and name in ('work_mem', 'idle_in_transaction_session_timeout', 'log_statement', 'jit')"))"
  read -r JUDGED DIFFER <<< "$(oracle "$V")"
  [[ "$JUDGED" -gt 0 && "$DIFFER" == 0 ]] || fail "C: $DIFFER overrides whose status differs from 0099's rules over their value ($JUDGED judged)"
  ok "C: every override's status = 0099's rule view over its value ($JUDGED judged by a rule, 0 differ)"
  [[ $(q "select known::text || ' ' || status from pgvigil.override_rules where instance_id = $ID and setting = 'app.tenant'") == "false none" ]] || fail "C: the placeholder is not 'known false, none'"
  [[ "$(ostatus "$V" database track_counts)" == "crit critical" && "$(srvstatus "$V" track_counts)" == ok ]] \
    || fail "C: track_counts: the database override '$(ostatus "$V" database track_counts)', the server '$(srvstatus "$V" track_counts)'"
  [[ "$(ostatus "$V" role zero_damaged_pages)" == "crit critical" && "$(srvstatus "$V" zero_damaged_pages)" == ok ]] \
    || fail "C: zero_damaged_pages: the role override '$(ostatus "$V" role zero_damaged_pages)', the server '$(srvstatus "$V" zero_damaged_pages)'"
  [[ "$(ostatus "$V" 'role in database' synchronous_commit)" == "warn warning" && "$(ostatus "$V" 'all roles' work_mem)" == "warn warning" ]] \
    || fail "C: synchronous_commit '$(ostatus "$V" 'role in database' synchronous_commit)', work_mem '$(ostatus "$V" 'all roles' work_mem)', expected warn warning"
  ok "C: track_counts (database) and zero_damaged_pages (role) red with the server's own green; synchronous_commit (role in database) and work_mem (all roles) yellow"
  F1=$(q "select count(*) from pgvigil.pg_override_findings where instance_id = $ID")
  F2=$(q "select count(*) from pgvigil.override_rules where instance_id = $ID and status in ('crit', 'warn')")
  [[ "$F2" == 9 ]] || fail "C: $F2 overrides break a rule, the seeds make 9: $(q "select string_agg(setting || ' ' || scope || ' ' || status, ', ') from pgvigil.override_rules where instance_id = $ID")"
  F3=$(q "select count(*) from pgvigil.pg_override_findings f where instance_id = $ID and severity = 'critical' and (value like 'DATABASE dbo_t SET track_counts = off' or value like 'ROLE dbo_app SET zero_damaged_pages = on')")
  [[ "$F1" == "$F2" && "$F1" -gt 0 && "$F3" == 2 ]] || fail "C: $F1 override findings, $F2 broken overrides, $F3 of the two critical ones"
  ok "C: $F1 override findings = the broken overrides (9 from the seeds), the two critical ones among them"
  same "C"
  rules_text
  collect "$V" instance
  WM=$(q "select value || ' ' || status from pgvigil.pg_setting_rules($ID) where setting = 'work_mem'")
  WF=$(q "select server_from_override::text from pgvigil.pg_override_rules($ID) where scope = 'all roles' and setting = 'work_mem'")
  [[ "$WM $WF" == "262144 warn true" ]] || fail "C: after an instance read the server's work_mem and the override's flag read '$WM $WF', expected '262144 warn true'"
  ok "C: an instance read takes ALTER ROLE ALL SET work_mem as the server's (262144, yellow); the override says its server value is read under it"

  echo "--- D. database options"
  s "$V" "create database dbo_c connection limit 1" >/dev/null
  hold "$V" dbo_c 1
  if psql "${APPDSN[$V]} dbname=dbo_c" -XAtqc "select 1" >"$WORK/second.out" 2>&1; then fail "D: a second session of dbo_hold was let into dbo_c (limit 1)"; fi
  grep -q 'too many connections' "$WORK/second.out" || fail "D: the second session failed otherwise: $(cat "$WORK/second.out")"
  collect "$V" databases connections
  [[ "$(dbcell "$V" dbo_c conn)" == "crit critical" ]] || fail "D: dbo_c at its limit reads '$(dbcell "$V" dbo_c conn)'"
  [[ "$(q "select conn_note from pgvigil.pg_db_options where instance_id = $ID and datname = 'dbo_c'")" == reached* ]] || fail "D: dbo_c's note is not 'reached ...'"
  [[ "$(dbfind "$V" 'database connection limit' dbo_c)" == "1 critical" ]] || fail "D: the critical finding of dbo_c: '$(dbfind "$V" 'database connection limit' dbo_c)'"
  ok "D: dbo_c limit 1, 1 session of dbo_hold: the server refuses a second; the cell red 'reached' with its critical finding"
  # E. the fleet's counts while dbo_c is at its limit and the overrides are set
  read -r AL NU OB OC CO DBN DCK < <(q "select at_limit, not_utf8, overrides_broken, overrides_critical, checksums_off, databases,
      (select count(*) from pgvigil.pg_db_options o where o.instance_id = r.instance_id and o.checksums_status = 'warn')
      from pgvigil.pg_dboption_risks r where instance_id = $ID" | tr '|' ' ')
  CKS=$(s "$V" "show data_checksums")
  WANT_CK=$([[ $CKS == off ]] && echo "$DBN" || echo 0)
  [[ "$AL" == 1 && "$NU" == 1 && "$OB" == "$F2" && "$OB" == 9 && "$OC" == 2 && "$CO" == "$WANT_CK" && "$DCK" == "$CO" ]] \
    || fail "E: at_limit $AL, not_utf8 $NU, overrides_broken $OB (want $F2), overrides_critical $OC, checksums_off $CO (data_checksums $CKS, $DBN databases)"
  ok "E: the fleet's counts: at_limit 1, not_utf8 1, overrides_broken $OB, overrides_critical 2, checksums_off $CO (data_checksums $CKS)"
  if [[ "$V" == "$PAGE_PG" ]]; then
    echo "--- G. the API and H. the page, on PostgreSQL $V"
    "$BIN" serve -config "$CFG" -listen "127.0.0.1:0" -no-login >"$WORK/serve.log" 2>&1 & SRVPID=$!
    U=
    for _ in $(seq 1 60); do
      U=$(sed -n 's/.*pgvigil serve started.*url=\(http:\/\/127\.0\.0\.1:[0-9]*\)\/.*/\1/p' "$WORK/serve.log" | head -1)
      [[ -n "$U" ]] && break; kill -0 "$SRVPID" 2>/dev/null || { cat "$WORK/serve.log"; fail "G: serve died"; }; sleep 0.5
    done
    [[ -n "$U" ]] || { tail -5 "$WORK/serve.log"; fail "G: serve did not start"; }
    curl -fsS "$U/api/pg/dboptions?instance=$ID" > "$WORK/api.json" || fail "G: GET /api/pg/dboptions?instance=$ID"
    curl -fsS "$U/api/pg/dboptions?instance=$ID&part=overrides" > "$WORK/api1.json" || fail "G: ?part=overrides"
    curl -fsS "$U/api/pg/dboptions/fleet" > "$WORK/fleet.json" || fail "G: GET /api/pg/dboptions/fleet"
    NDB=$(q "select count(*) from pgvigil.pg_db_options where instance_id = $ID"); NOV=$(q "select count(*) from pgvigil.pg_override_rules($ID)")
    NF=$(q "select (select count(*) from pgvigil.pg_override_findings where instance_id = $ID) + (select count(*) from pgvigil.pg_dboption_findings where instance_id = $ID)")
    NI=$(q "select count(*) from pgvigil.instances where engine = 'postgres' and is_active")
    python3 -I - "$WORK/api.json" "$WORK/api1.json" "$WORK/fleet.json" "$NDB" "$NOV" "$NF" "$NI" <<'PY' || fail "G: the API is not as expected"
import json, sys
d, one, fl = (json.load(open(p)) for p in sys.argv[1:4])
ndb, nov, nf, ni = map(int, sys.argv[4:8])
for k in ('state', 'databases', 'overrides', 'overrides_read', 'findings'):
    assert d.get(k) is not None, 'no part ' + k
assert len(d['databases']['rows']) == ndb, 'databases %d, the view %d' % (len(d['databases']['rows']), ndb)
assert len(d['overrides']['rows']) == nov, 'overrides %d, the view %d' % (len(d['overrides']['rows']), nov)
assert len(d['findings']['rows']) == nf, 'findings %d, the views %d' % (len(d['findings']['rows']), nf)
assert set(one) == {'overrides'}, 'part=overrides answered %s' % sorted(one)
assert len(fl['risks']['rows']) == ni, 'risks %d, active PostgreSQL instances %d' % (len(fl['risks']['rows']), ni)
PY
    ok "G: /api/pg/dboptions: $NDB databases, $NOV overrides, $NF findings as the views; part=overrides alone; the fleet $NI rows"
    setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHRPID=$!
    CDP=
    for _ in $(seq 1 60); do
      [[ -s "$WORK/chrome/DevToolsActivePort" ]] && CDP=$(head -1 "$WORK/chrome/DevToolsActivePort")
      [[ -n "$CDP" ]] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break
      sleep 0.5
    done
    [[ "$CDP" =~ ^[0-9]+$ ]] || fail "H: Chromium never answered on its debugging port: $(tail -3 "$WORK/chrome.log")"
    cat > "$WORK/page.mjs" <<'JS'
const [port, base, id, shots] = process.argv.slice(2);
const fs = await import('node:fs');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let n = 0; const wait = new Map(); const thrown = [];
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? 'exception');
  if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') thrown.push('console.error: ' + d.params.args.map(a => a.value ?? '').join(' '));
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++n; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => { const d = await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const until = async (e, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(e); if (v) return v; await sleep(200); } return null; };
let failed = 0;
const check = (label, okay, what) => { if (!okay) failed++; console.log(`${okay ? 'ok  ' : 'FAIL'} ${label}: ${what}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1400, deviceScaleFactor: 1, mobile: false });
const READ = `(() => {
  const main = document.querySelector('main'); const t = e => (e?.textContent ?? '').trim();
  const gridAfter = h => { let e = h?.nextElementSibling; while (e && !e.querySelector?.('table')) e = e.nextElementSibling; return e?.querySelector('table'); };
  const hs = [...main.querySelectorAll('h3')];
  const tableOf = name => gridAfter(hs.find(h => t(h) === name));
  const rowsOf = tb => { if (!tb) return []; const heads = [...tb.querySelectorAll('thead th')].map(th => t(th).replace(/\\s+/g, ' '));
    return [...tb.querySelectorAll('tbody tr')].map(tr => Object.fromEntries([...tr.children].map((td, i) => [heads[i] ?? String(i), { text: t(td), cls: td.className, title: td.querySelector('[title]')?.title ?? td.title ?? '' }]))); };
  const coloured = [...main.querySelectorAll('td.status')];
  return { dbs: rowsOf(tableOf('Databases')), ovs: rowsOf(tableOf('Setting overrides')),
           untitled: coloured.filter(td => !(td.querySelector('[title]')?.title || td.title)).length, coloured: coloured.length,
           grey: main.querySelectorAll('td.status.none').length, theme: document.documentElement.getAttribute('data-theme'),
           status: document.documentElement.getAttribute('data-status'), bg: getComputedStyle(document.body).backgroundColor,
           crit: (() => { const c = main.querySelector('td.status.crit'); return c ? getComputedStyle(c).backgroundColor : ''; })() };
})()`;
const key = (row, head) => Object.entries(row).find(([k]) => String(k).startsWith(head))?.[1] ?? { text: '', cls: '', title: '' };
const seen = {};
for (const theme of ['light', 'dark']) for (const style of ['solid', 'quiet']) {
  const label = `${theme} / ${style}`; thrown.length = 0;
  await cmd('Page.navigate', { url: `${base}/#/about` }); await sleep(500);
  await ev(`localStorage.setItem('pgvigil.theme', '${theme}'); localStorage.setItem('pgvigil.status', '${style}'); true`);
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await cmd('Page.navigate', { url: `${base}/#/pgdboptions?i=${id}` });
  const ready = await until(`(() => { const m = document.querySelector('main'); return m && [...m.querySelectorAll('h3')].some(h => h.textContent.trim() === 'Setting overrides') && m.querySelectorAll('td.status').length > 0; })()`);
  check(label, !!ready, 'the page drew its two grids');
  if (!ready) continue;
  await sleep(300);
  const r = await ev(READ);
  seen[label] = r;
  const c = r.dbs.find(x => key(x, 'database').text === 'dbo_c');
  const cc = c ? key(c, 'connection') : null;
  check(label, cc && /\bstatus crit\b/.test(cc.cls) && cc.title.startsWith('deviates: critical: reached'), `dbo_c's connection cell '${cc?.text}' ${cc?.cls} '${cc?.title?.slice(0, 50)}'`);
  const tc = r.ovs.find(x => key(x, 'setting').text === 'track_counts');
  const tv = tc ? key(tc, 'value') : null, sv = tc ? key(tc, 'the') : null;
  check(label, tv && /\bstatus crit\b/.test(tv.cls) && tv.title.startsWith('deviates: critical') && sv && /\bstatus ok\b/.test(sv.cls),
    `track_counts override '${tv?.text}' ${tv?.cls}, the server's '${sv?.text}' ${sv?.cls}`);
  check(label, r.grey > 0, `${r.grey} grey cells`);
  check(label, r.coloured > 0 && r.untitled === 0, `${r.coloured} coloured cells, ${r.untitled} without a title`);
  check(label, r.theme === theme && (style === 'quiet' ? r.status === 'quiet' : r.status === null), `data-theme ${r.theme}, data-status ${r.status}`);
  check(label, thrown.length === 0, thrown.length ? thrown.join(' | ').slice(0, 300) : 'no exception');
  const shot = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  fs.writeFileSync(`${shots}/pgdboptions-${theme}-${style}.png`, Buffer.from(shot.result.data, 'base64'));
}
const bg = k => seen[k]?.bg ?? '?';
check('themes', bg('light / solid') === bg('light / quiet') && bg('dark / solid') === bg('dark / quiet') && bg('light / solid') !== bg('dark / solid'),
  `the body's background: light ${bg('light / solid')} / ${bg('light / quiet')}, dark ${bg('dark / solid')} / ${bg('dark / quiet')}`);
check('styles', seen['light / solid']?.crit && seen['light / solid'].crit !== seen['light / quiet']?.crit, `a red cell solid ${seen['light / solid']?.crit}, quiet ${seen['light / quiet']?.crit}`);
// the fleet page: the count is a red link that opens the databases behind it
thrown.length = 0;
await cmd('Page.navigate', { url: `${base}/#/pgrisks` });
const href = await until(`(() => { const a = [...document.querySelectorAll('main td.status.crit a')].find(a => a.href.includes('i=${id}') && a.href.includes('risk=at_limit')); return a ? a.getAttribute('href') : ''; })()`);
check('fleet', !!href, `the at-limit count of instance ${id} is a red link: ${href}`);
if (href) {
  await cmd('Page.navigate', { url: `${base}/${href}` });
  const got = await until(`(() => { const t = [...document.querySelectorAll('main h3')].find(h => h.textContent.trim() === 'Databases'); let e = t?.nextElementSibling; while (e && !e.querySelector?.('table')) e = e.nextElementSibling; const rows = e ? [...e.querySelectorAll('tbody tr')] : []; return rows.length ? rows.map(r => r.children[0].textContent.trim()).join(',') : ''; })()`);
  check('fleet', got === 'dbo_c', `the link opens: ${got}`);
  const shot = await cmd('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${shots}/pgrisks-at-limit.png`, Buffer.from(shot.result.data, 'base64'));
}
check('fleet', thrown.length === 0, thrown.length ? thrown.join(' | ').slice(0, 300) : 'no exception');
ws.close();
process.exit(failed ? 1 : 0);
JS
    node "$WORK/page.mjs" "$CDP" "$U" "$ID" "$SHOTS" || fail "H: a check of the page failed"
    ok "H: the page in light and dark, solid and quiet (pictures in $SHOTS); the fleet's count opens dbo_c"
    PAGE_RAN=yes
    kill -- -"$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; CHRPID=""
  fi
  unhold "$V" dbo_c
  s "$V" "alter database dbo_c connection limit 5" >/dev/null
  hold "$V" dbo_c 4
  collect "$V" databases connections
  [[ "$(dbcell "$V" dbo_c conn)" == "warn warning" && "$(dbfind "$V" 'database connection limit' dbo_c)" == "1 warning" ]] \
    || fail "D: limit 5 with 4 sessions reads '$(dbcell "$V" dbo_c conn)', finding '$(dbfind "$V" 'database connection limit' dbo_c)'"
  unhold "$V" dbo_c
  collect "$V" connections
  [[ "$(dbcell "$V" dbo_c conn)" == "ok -" && "$(dbfind "$V" 'database connection limit' dbo_c)" == "0 -" ]] || fail "D: no session left reads '$(dbcell "$V" dbo_c conn)'"
  s "$V" "alter database dbo_c connection limit 0" >/dev/null; collect "$V" databases
  CZ=$(dbcell "$V" dbo_c conn); CN=$(q "select conn_note from pgvigil.pg_db_options where instance_id = $ID and datname = 'dbo_c'")
  [[ "$CZ" == "warn warning" && "$CN" == closed* ]] || fail "D: CONNECTION LIMIT 0 reads '$CZ' '$CN'"
  s "$V" "alter database dbo_c connection limit -1" >/dev/null; collect "$V" databases
  ok "D: limit 5 with 4 sessions yellow 'near' with a warning finding; the sessions ended: green, the finding gone; limit 0 yellow 'closed'"
  s "$V" "alter database dbo_x allow_connections false" >/dev/null; collect "$V" databases
  [[ "$(dbcell "$V" dbo_x allow) $(dbfind "$V" 'database allow connections' dbo_x)" == "warn warning 1 warning" ]] || fail "D: dbo_x closed reads '$(dbcell "$V" dbo_x allow)'"
  s "$V" "alter database dbo_x allow_connections true" >/dev/null; collect "$V" databases
  [[ "$(dbcell "$V" dbo_x allow) $(dbfind "$V" 'database allow connections' dbo_x)" == "ok - 0 -" ]] || fail "D: dbo_x open again reads '$(dbcell "$V" dbo_x allow)'"
  ok "D: dbo_x ALLOW_CONNECTIONS false yellow with its finding; true: green, gone"
  [[ "$(dbcell "$V" dbo_l encoding) $(dbfind "$V" 'database encoding' dbo_l)" == "warn info 1 info" ]] || fail "D: dbo_l LATIN1 reads '$(dbcell "$V" dbo_l encoding)'"
  [[ "$(dbcell "$V" dbo_l collation)" == "none -" ]] || fail "D: dbo_l's collation (C) reads '$(dbcell "$V" dbo_l collation)'"
  [[ "$(dbcell "$V" template0 encoding)" == "none -" ]] || fail "D: template0's encoding reads '$(dbcell "$V" template0 encoding)'"
  ok "D: dbo_l LATIN1 yellow advice with an info finding; its collation cell grey; template0's encoding grey"
  if [[ $(s "$V" "show server_version_num") -ge 150000 ]]; then
    REC=$(s "$V" "select datcollversion from pg_database where datname = 'dbo_t'")
    [[ "$(dbcell "$V" dbo_t collation)" == "ok -" ]] || fail "D: dbo_t's collation ($REC) reads '$(dbcell "$V" dbo_t collation)'"
    s "$V" "update pg_database set datcollversion = '0.0' where datname = 'dbo_t'" >/dev/null; collect "$V" versions
    [[ "$(dbcell "$V" dbo_t collation)" == "warn warning" && $(q "select recorded_version from pgvigil.pg_db_options where instance_id = $ID and datname = 'dbo_t'") == 0.0 ]] \
      || fail "D: dbo_t with 0.0 recorded reads '$(dbcell "$V" dbo_t collation)'"
    s "$V" "alter database dbo_t refresh collation version" >/dev/null 2>&1; collect "$V" versions
    [[ "$(dbcell "$V" dbo_t collation)" == "ok -" ]] || fail "D: dbo_t refreshed reads '$(dbcell "$V" dbo_t collation)'"
    ok "D: dbo_t's collation $REC green; 0.0 recorded: yellow; REFRESH COLLATION VERSION: green"
  else
    [[ $(q "select count(*) from pgvigil.pg_db_options where instance_id = $ID and collation_status <> 'none'") == 0 ]] || fail "D: a collation cell judged on PostgreSQL $V"
    ok "D: every collation cell grey on PostgreSQL $V"
  fi
  WANT=$([[ $CKS == on ]] && echo ok || echo warn)
  [[ $(q "select count(*) from pgvigil.pg_db_options where instance_id = $ID and checksums_status <> '$WANT'") == 0 ]] || fail "D: a checksums cell not '$WANT' with data_checksums $CKS"
  ok "D: data_checksums $CKS: every row's checksums cell $WANT"
  XB=$(s "$V" "select coalesce(string_agg(datname || '=' || age(datfrozenxid), ' ' order by datname), '') from pg_database")
  XS=$(q "select coalesce(string_agg(datname || '=' || xid_age, ' ' order by datname), '') from pgvigil.pg_db_options where instance_id = $ID")
  python3 -I - "$XB" "$XS" <<'PY' || fail "D: the stored xid ages differ from the server's beyond the xids used since: $XS / $XB"
import sys
srv = dict(x.split('=') for x in sys.argv[1].split()); st = dict(x.split('=') for x in sys.argv[2].split())
assert srv.keys() == st.keys(), (sorted(srv), sorted(st))
for k in srv:
    assert 0 <= int(srv[k]) - int(st[k]) <= 200, (k, srv[k], st[k])
PY
  [[ $(q "select count(*) from pgvigil.pg_db_options where instance_id = $ID and xid_status <> 'ok'") == 0 ]] || fail "D: an xid cell not green on a fresh server"
  psql "${SU[$V]} dbname=dbo_x" -XAtq -v ON_ERROR_STOP=1 -c "vacuum freeze" >/dev/null || fail "D: vacuum freeze in dbo_x"
  for _ in 1 2 3; do s "$V" "select txid_current()" >/dev/null; done
  collect "$V" databases
  XX=$(q "select xid_age from pgvigil.databases where instance_id = $ID and datname = 'dbo_x'")
  FMA=$((XX + 1))
  OLDER=$(q "select count(*) from pgvigil.databases where instance_id = $ID and is_present and xid_age >= $FMA")
  [[ "$OLDER" -ge 1 ]] || fail "D: no database older than the frozen dbo_x ($XX): $(q "select string_agg(datname || '=' || xid_age, ' ') from pgvigil.databases where instance_id = $ID and is_present")"
  cat > "$WORK/xid.sql" <<SQL
BEGIN;
UPDATE pgvigil.instance_state SET non_default_settings = coalesce(non_default_settings, '[]'::jsonb) || '[{"name": "autovacuum_freeze_max_age", "value": "$FMA"}]'::jsonb WHERE instance_id = $ID;
SELECT 'warn ' || (SELECT count(*) FROM pgvigil.pg_db_options WHERE instance_id = $ID AND xid_age >= $FMA AND xid_status <> 'warn') || ' ' || (SELECT count(*) FROM pgvigil.pg_db_options WHERE instance_id = $ID AND xid_age >= $FMA)
  || ' ' || (SELECT count(*) FROM pgvigil.pg_db_options WHERE instance_id = $ID AND xid_age < $FMA AND xid_status <> 'ok');
UPDATE pgvigil.databases SET xid_age = 1200000000 WHERE instance_id = $ID AND datname = 'dbo_t';
SELECT 'crit ' || xid_status || ' ' || xid_severity FROM pgvigil.pg_db_options WHERE instance_id = $ID AND datname = 'dbo_t';
ROLLBACK;
SQL
  XO=$(qf "$WORK/xid.sql") || fail "D: the rolled-back xid transaction failed"
  grep -qE '^warn 0 [1-9][0-9]* 0$' <<< "$XO" || fail "D: freeze age $FMA: '$(grep '^warn' <<< "$XO")'"
  YOUNGER=$(q "select count(*) from pgvigil.databases where instance_id = $ID and is_present and xid_age < $FMA")
  [[ "$YOUNGER" -ge 1 ]] || fail "D: no database younger than $FMA"
  grep -qx 'crit crit critical' <<< "$XO" || fail "D: age 1.2 billion: '$(grep '^crit' <<< "$XO")'"
  ok "D: xid ages = the server's; green; dbo_x frozen to $XX, freeze age $FMA: $YOUNGER younger green, $(grep '^warn' <<< "$XO" | cut -d' ' -f3) older yellow; 1.2 billion red (rolled back)"

  echo "--- F. undo"
  s "$V" "alter database dbo_t reset all" >/dev/null; s "$V" "alter role dbo_app reset all" >/dev/null
  s "$V" "alter role dbo_app in database dbo_t reset all" >/dev/null; s "$V" "alter role all reset all" >/dev/null
  collect "$V" dbsettings
  [[ $(q "select count(*) from pgvigil.pg_db_role_settings where instance_id = $ID") == 0 && $(q "select count(*) from pgvigil.pg_override_findings where instance_id = $ID") == 0 ]] \
    || fail "F: rows or findings left after RESET"
  collect "$V" instance
  SV="$(srvstatus "$V" track_counts) $(srvstatus "$V" zero_damaged_pages) $(q "select value || ' ' || status from pgvigil.pg_setting_rules($ID) where setting = 'work_mem'")"
  [[ "$SV" == "ok ok 4096 ok" ]] || fail "F: after RESET and an instance read the server reads '$SV', expected 'ok ok 4096 ok'"
  same "F"
  ok "F: every override RESET: 0 rows, 0 findings; an instance read: work_mem 4096 green, track_counts and zero_damaged_pages green"
done
[[ -n "$PAGE_RAN" ]] || fail "G and H did not run (PGDBO_PAGE_PG $PAGE_PG)"
echo "proof-pg-dboptions: PASS on PostgreSQL $VERSIONS (repository $RPG)"
