#!/usr/bin/env bash
# capture-community-samples.sh - the demo's stored samples of the community tools (internal/demo/community/samples).
#
# Builds two test servers for the capture and nothing else - a SQL Server 2022 container and a PostgreSQL cluster of its
# own (initdb on a free port; never a shared cluster: another job's databases, paths and statements would be stored) -
# loaded with the demo's own invented names (SQL Server: the database Sales with dbo.Customer, Orders, OrderLine, Stock
# and AuditLog, the logins orders_app and stock_job, as internal/demo/mssql_*_demo.go name them; PostgreSQL: the
# database erp with schema_demo.go's tables items, order_lines and user_sessions and the function order_total, the
# roles app_erp, app_readonly and erp_deploy), and makes on them what each tool reads: a workload, Query Store on, a
# deadlock, a blocking chain with a sleeping head held while the tools that read running sessions run, the blocked
# process threshold at 5 s with the keeper_HumanEvents_blocking session a DBA makes with sp_HumanEvents, the error
# log's lines, duplicate, unused and invalid indexes, a sequence at 80 % of its range, settings changed, an idle in
# transaction holder and a prepared transaction. Then pgvigil serve (the UI login on) runs every tool once through
# POST /api/community/run with the parameters written below - the page's own run path, its answer kept as it came -
# and the procedures' forms through POST /api/community/params; the pack command (internal/demo/community/pack)
# scrubs and stores them, and the package's tests check them with this machine's own names denied.
#
# Box only (docker, a PostgreSQL install with initdb, go, psql, curl, python3, ss). Nothing here is part of a proof.
#   PGVIGIL_ADMIN_DSN      a superuser of a PostgreSQL server for the throwaway repository database (keyword form)
#   PGVIGIL_COMMUNITY_DIR  the kits: frk-install-all.sql, darlingdata.sql, sp_WhoIsActive.sql (installed in master)
#   PGVIGIL_BIN            the pgvigil binary (default: built from this tree)
#   PGVIGIL_SAMPLE_RAW     a folder to keep the raw answers in (default: removed with the temp folder)
#   PGVIGIL_SAMPLE_DENY    more words no sample may hold, comma-separated (this machine's host name and cloud project
#                          are added here by themselves)
# Expected: one line 'capt <tool>: done, <sets> sets, <rows> rows' per tool (23), the pack's line per file and its
# total under 1 MB, the package's tests ok, and the last line 'capture: 23 samples, <bytes> bytes, deny 0'; exit 0.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
: "${PGVIGIL_ADMIN_DSN:?PGVIGIL_ADMIN_DSN (a superuser, keyword form) is required}"
: "${PGVIGIL_COMMUNITY_DIR:?PGVIGIL_COMMUNITY_DIR (the kits) is required}"
CDIR=$(realpath "$PGVIGIL_COMMUNITY_DIR")
N=$RANDOM$RANDOM
WORK=$(mktemp -d)
RAW=${PGVIGIL_SAMPLE_RAW:-$WORK/raw}; mkdir -p "$RAW"; RAW=$(realpath "$RAW")
# the raw answers and meta.json hold this machine's own names: never inside the repository unless git ignores them
case "$RAW/" in "$ROOT"/*) git -C "$ROOT" check-ignore -q "$RAW" 2>/dev/null || { echo "FAIL: PGVIGIL_SAMPLE_RAW is inside the repository and not ignored: keep the raw answers outside it" >&2; exit 1; };; esac
REPO=capt_repo_$N; CT=capt-mssql-$N
PGD=$WORK/pgdata; SOCK=$WORK/sock; mkdir -p "$SOCK"
SRV=""; MADE_CT=""; PGUP=""; HOLD=()
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  for p in "${HOLD[@]}" "$SRV"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [[ -n "$MADE_CT" ]] && docker rm -f -v "$CT" >/dev/null 2>&1 || true
  [[ -n "$PGUP" ]] && "$PGCTL" -D "$PGD" -m immediate stop >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in docker psql curl python3 ss go; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for f in frk-install-all.sql darlingdata.sql sp_WhoIsActive.sql; do [[ -r "$CDIR/$f" ]] || fail "$CDIR/$f is missing"; done
[[ -r "$ROOT/scripts/lib/kitsetup.sh" ]] || fail "scripts/lib/kitsetup.sh is missing"
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 12000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}
pw() { echo "$1$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!a1"; }

# ---- the kits' versions, from their own source (the sample line says them) ----------------------------------------
grep -q "SELECT @Version = '8.34', @VersionDate = '20260702'" "$CDIR/frk-install-all.sql" || fail "the First Responder Kit is not 8.34 (2026-07-02): the table below names it"
grep -q 'Who Is Active? v2200.20260409' "$CDIR/sp_WhoIsActive.sql" || fail "sp_WhoIsActive is not v2200.20260409"
darling_version() {   # a DarlingData procedure's @version from its own ALTER PROCEDURE block
  awk -v p="dbo.$1" '$0 ~ "CREATE PROCEDURE " p " AS" {on=1} on && /@version = '\''/ {gsub(/[^0-9.]/, "", $3); print $3; exit}' "$CDIR/darlingdata.sql"
}
declare -A DV
for p in sp_PressureDetector sp_QuickieStore sp_HumanEventsBlockViewer sp_HealthParser sp_LogHunter sp_IndexCleanup; do
  DV[$p]=$(darling_version "$p"); [[ -n ${DV[$p]} ]] || fail "no @version for $p in darlingdata.sql"
done
grep -q "@version_date = '20261101'" "$CDIR/darlingdata.sql" || fail "DarlingData is not the 2026-11-01 release"

# ---- the binary ---------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$(realpath "$PGVIGIL_BIN"); else
  BIN=$WORK/pgvigil; CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil || fail "go build"
fi

# ---- SQL Server 2022 (the state both this capture and kitwatch.sh run the tools against: scripts/lib/kitsetup.sh) -
echo "--- SQL Server: the container (host name testsql01)"
. "$ROOT/scripts/lib/kitsetup.sh"
ks_container
echo "ok   $MS_SERVER"
ks_install "$CDIR/frk-install-all.sql" $KS_PROCS_FRK || fail "frk-install-all.sql $KS_WHY"
ks_install "$CDIR/darlingdata.sql" $KS_PROCS_DARLING || fail "darlingdata.sql $KS_WHY"
ks_install "$CDIR/sp_WhoIsActive.sql" $KS_PROCS_WIA || fail "sp_WhoIsActive.sql $KS_WHY"
echo "ok   the kits installed in master, every procedure there"
ks_sales; ks_grant_kits
ks_keeper || fail "$KS_WHY"
echo "ok   Sales, the logins, Query Store, the threshold 5 s, keeper_HumanEvents_blocking running"

echo "--- SQL Server: a deadlock, the workload, the error log"
ks_workload || fail "$KS_WHY"
echo "ok   a deadlock in system_health, the workload ran, Query Store flushed"

# ---- PostgreSQL: a cluster of its own ------------------------------------------------------------------------------
echo "--- PostgreSQL: a cluster of its own"
INITDB=$(command -v initdb || ls /usr/lib/postgresql/*/bin/initdb 2>/dev/null | sort -V | tail -1)
[[ -x "$INITDB" ]] || fail "initdb is not on this machine"
PGCTL=$(dirname "$INITDB")/pg_ctl; PP=$(freeport)
"$INITDB" -D "$PGD" -U postgres --auth-local=trust --auth-host=scram-sha-256 >"$WORK/initdb.log" 2>&1 || fail "initdb: $(tail -3 "$WORK/initdb.log")"
"$PGCTL" -D "$PGD" -o "-p $PP -k $SOCK -c listen_addresses=localhost -c shared_preload_libraries=pg_stat_statements -c max_prepared_transactions=5 -c work_mem=16MB -c random_page_cost=1.1 -c log_min_duration_statement=1000 -c track_io_timing=on -c shared_buffers=64MB" \
  -l "$WORK/pg.log" -w start >/dev/null || fail "the cluster did not start: $(tail -3 "$WORK/pg.log")"
PGUP=1
SU="host=$SOCK port=$PP user=postgres"
pq() { psql "$SU dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
PGV=$(pq "show server_version"); PG_SERVER="PostgreSQL ${PGV%% *}"
echo "ok   $PG_SERVER"
PPW=$(pw Pg)
pq "create role app_erp login; create role app_readonly; create role erp_deploy login; create role pgvigil_read login password '$PPW' in role pg_monitor" >/dev/null
pq "create database erp owner app_erp" >/dev/null
psql "$SU dbname=erp" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
create extension pg_stat_statements;
set role app_erp;
create table items (id bigint generated always as identity primary key, created_at timestamptz not null default now(), sku text not null, name text not null, price numeric(12,2) not null);
create table order_lines (id bigint generated always as identity primary key, created_at timestamptz not null default now(), item_id bigint not null references items, amount numeric(14,2) not null default 0, status text not null default 'open');
create table user_sessions (id bigint generated always as identity primary key, created_at timestamptz not null default now(), user_name text not null, last_seen timestamptz) with (autovacuum_enabled = false);
create function order_total(bigint) returns numeric language sql stable as $$ select sum(amount) from order_lines where id = $1 $$;
insert into items (sku, name, price) select 'SKU-' || g, 'item ' || g, (g % 500) + 0.99 from generate_series(1, 5000) g;
insert into order_lines (item_id, amount, status, created_at) select 1 + g % 5000, (g % 10000) / 100.0, (array['open', 'shipped', 'closed'])[1 + g % 3], now() - (g || ' minutes')::interval from generate_series(1, 200000) g;
insert into user_sessions (user_name, last_seen) select 'user' || (g % 300), now() - (g || ' seconds')::interval from generate_series(1, 50000) g;
create index items_sku_idx on items (sku);
create index items_sku_idx1 on items (sku);
create index order_lines_item_idx on order_lines (item_id);
create index user_sessions_last_seen_idx on user_sessions (last_seen);
create sequence invoice_no_seq as integer;
select setval('invoice_no_seq', 1717986918);
delete from user_sessions where id % 5 = 0;
grant select on all tables in schema public to app_readonly;
grant select, update on items, order_lines to erp_deploy;
grant select on sequence invoice_no_seq to pgvigil_read;
reset role;
analyze items;
analyze order_lines;
alter database erp set statement_timeout = '30s';
alter system set shared_buffers = '128MB';
select pg_reload_conf();
SQL
# a unique index built concurrently over duplicates fails and is left invalid (the 'Invalid indexes' read)
psql "$SU dbname=erp" -XAtq -c "create unique index concurrently order_lines_status_key on order_lines (status)" >/dev/null 2>&1 || true
[[ $(pq "select count(*) from pg_index where not indisvalid" erp) == 1 ]] || fail "no invalid index was left"
# the workload (pg_stat_statements' statements), over the unix socket as the application
{
  for i in $(seq 1 40); do
    echo "select i.sku, sum(ol.amount) from order_lines ol join items i on i.id = ol.item_id where ol.status = 'open' group by i.sku order by 2 desc limit 20;"
    echo "select order_total(g) from generate_series($i, $((i + 200))) g;"
    for j in $(seq 1 10); do echo "update user_sessions set last_seen = now() where id = $((i * 10 + j));"; echo "select * from items where sku = 'SKU-$((i * j))';"; done
  done
} > "$WORK/workload.sql"
pq "select pg_stat_statements_reset()" erp >/dev/null   # Top statements: the workload's, not the load's
PGAPPNAME=erp-api psql "host=$SOCK port=$PP user=app_erp dbname=erp" -XAtq -f "$WORK/workload.sql" >/dev/null || fail "the PostgreSQL workload"
echo "ok   erp loaded (5,000 items, 200,000 order lines), the workload ran, an invalid index, a sequence at 80 %"

# ---- serve over the two test servers ---------------------------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null
export CAPT_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
export CAPT_MS_R="sqlserver://pgvigil_read:$RPW@$ADDR?database=master&encrypt=true&TrustServerCertificate=true"
export CAPT_PG_R="host=localhost port=$PP dbname=erp user=pgvigil_read password=$PPW"
cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:CAPT_REPO_DSN
instances:
  - name: testsql01
    engine: sqlserver
    dsn: env:CAPT_MS_R
  - name: testpg01
    dsn: env:CAPT_PG_R
EOF
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" >"$WORK/migrate.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/migrate.log")"
"$BIN" collect -config "$CFG" -once activity >"$WORK/collect.log" 2>&1 || true
"$BIN" collect -config "$CFG" -once mssql_instance >>"$WORK/collect.log" 2>&1 || true
q() { psql "$CAPT_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
MSID=$(q "select instance_id from pgvigil.instances where name = 'testsql01'"); PGID=$(q "select instance_id from pgvigil.instances where name = 'testpg01'")
[[ -n $MSID && -n $PGID ]] || fail "the two instances are not registered: $(tail -5 "$WORK/collect.log")"
UIPW=$(pw Ui)
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" capture >/dev/null 2>&1 || fail "user add"
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >"$WORK/serve.log" 2>&1 & SRV=$!
for n in $(seq 1 60); do curl -sf -o /dev/null "$U/" && break; kill -0 "$SRV" 2>/dev/null || fail "serve died: $(tail -3 "$WORK/serve.log")"; [[ $n == 60 ]] && fail "serve did not answer"; sleep 0.5; done
JAR=$WORK/jar
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"capture\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
[[ -n $(awk '$6 == "pgvigil_session" {print $7}' "$JAR") ]] || fail "no session cookie"
post() { curl -s --max-time 90 -o "$2" -w '%{http_code}' -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$1" "$U/api/$3"; }
curl -s -b "$JAR" -o "$WORK/ms-tools.json" "$U/api/community?instance=$MSID"
curl -s -b "$JAR" -o "$WORK/pg-tools.json" "$U/api/community?instance=$PGID&database=erp"
python3 - "$WORK/ms-tools.json" "$WORK/pg-tools.json" <<'PY' || fail "a tool is not ready on the test servers"
import json, sys
for f in sys.argv[1:]:
    d = json.load(open(f))
    off = [f"{t['id']} ({t['state']}: {'; '.join(n['what'] for n in t['needs'] if n['hard'])})" for t in d['tools'] if not t['on'] and t['kind'] != 'script']
    if off or not d['enabled']:
        print('not ready:', d.get('reason', ''), off); sys.exit(1)
print('ok   every tool ready on both test servers')
PY

# capt <tool> <instance> <database> <params json>: the form, then the run; its answer kept. MARK (when set): words the
# rows must hold - the rig's own subject, so a sample shows what it was built for, never rows that are there either way;
# NOKIT (when set): no kit's own statement may be among the rows (a plan cache or Query Store read)
TOOLS_META=()
capt() {
  local tool=$1 inst=$2 db=$3 params=$4 code
  if [[ $inst == "$MSID" ]]; then
    code=$(post "{\"instance_id\":$inst,\"tool\":\"$tool\",\"database\":\"\"}" "$RAW/$tool.params.json" community/params)
    [[ $code == 200 ]] || fail "$tool: the form answered $code: $(head -c 300 "$RAW/$tool.params.json")"
  fi
  code=$(post "{\"instance_id\":$inst,\"tool\":\"$tool\",\"database\":\"$db\",\"params\":$params,\"timeout_secs\":60}" "$RAW/$tool.run.json" community/run)
  [[ $code == 200 ]] || fail "$tool: the run answered $code: $(head -c 300 "$RAW/$tool.run.json")"
  ks_mark "$RAW/$tool.run.json" "$tool" "${MARK:-}" "${NOKIT:-}" || fail "$tool: the run did not end done with rows of its subject"
}

FRK='"kit":"First Responder Kit","version":"8.34","version_date":"2026-07-02","help":true'
dar() { echo "\"kit\":\"DarlingData\",\"version\":\"${DV[$1]}\",\"version_date\":\"2026-11-01\",\"help\":true"; }
WIA='"kit":"sp_WhoIsActive","version":"v2200.20260409","version_date":"2026-04-09","help":false'
ms() {   # ms <tool> <database> <params json> <kit fields> (MARK / NOKIT from the caller's environment)
  capt "$1" "$MSID" "$2" "$3"
  TOOLS_META+=("{\"tool\":\"$1\",\"engine\":\"sqlserver\",\"database\":\"${2:-master}\",\"params\":$3,$4}")
}
kitmeta() { case $1 in sp_Blitz*) echo "$FRK" ;; sp_WhoIsActive) echo "$WIA" ;; *) dar "$1" ;; esac; }
ms_phase() {   # the tools of one phase of KS_SQL_RUNS, in its order
  local row tool ph mark nokit params
  for row in "${KS_SQL_RUNS[@]}"; do
    IFS='~' read -r tool ph mark nokit params <<<"$row"
    [[ $ph == "$1" ]] || continue
    MARK=$mark NOKIT=$nokit ms "$tool" "" "$params" "$(kitmeta "$tool")"
  done
}
echo "--- SQL Server: the plan cache and Query Store of Sales, before any kit ran there (their rows are statements)"
ms_phase before
echo "--- SQL Server: the chain held (a sleeping head with an open transaction, two sessions waiting on it)"
ks_chain_hold || fail "$KS_WHY"
echo "ok   the chain is held"
ms_phase chain
ks_chain_release
echo "ok   the chain released"
ms_phase after

echo "--- PostgreSQL: an idle in transaction head, two sessions waiting on it, a prepared transaction"
mkfifo "$WORK/pghead.in"
PGAPPNAME=erp-api psql "host=$SOCK port=$PP user=app_erp dbname=erp" -XAtq < "$WORK/pghead.in" >/dev/null 2>&1 & HOLD+=($!)
exec 8>"$WORK/pghead.in"
printf "begin isolation level repeatable read;\nselect count(*) from items;\nupdate order_lines set status = 'held' where id = 1;\n" >&8
sleep 1
PGAPPNAME=erp-batch psql "host=$SOCK port=$PP user=erp_deploy dbname=erp" -XAtq -c "update order_lines set amount = amount + 1 where id = 1" >/dev/null 2>&1 & HOLD+=($!)
PGAPPNAME=erp-api psql "host=$SOCK port=$PP user=app_erp dbname=erp" -XAtq -c "update order_lines set status = 'open' where id = 1" >/dev/null 2>&1 & HOLD+=($!)
printf "begin;\nupdate items set price = price where id = 7;\nprepare transaction 'erp_batch_42';\n" | PGAPPNAME=erp-batch psql "host=$SOCK port=$PP user=erp_deploy dbname=erp" -XAtq -v ON_ERROR_STOP=1 >/dev/null || fail "the prepared transaction"
for _ in $(seq 1 30); do [[ $(pq "select count(*) from pg_stat_activity where wait_event_type = 'Lock'") -ge 2 ]] && break; sleep 1; done
[[ $(pq "select count(*) from pg_stat_activity where wait_event_type = 'Lock'") -ge 2 ]] || fail "the PostgreSQL chain did not form"
sleep 3
pg() {   # pg <tool> <params json>
  capt "$1" "$PGID" erp "$2"
  TOOLS_META+=("{\"tool\":\"$1\",\"engine\":\"postgres\",\"database\":\"erp\",\"params\":$2,\"kit\":\"pgvigil\",\"version\":\"own read\",\"version_date\":\"\",\"help\":false}")
}
MARK='idle in transaction' pg pg_running '{}'
MARK='head' pg pg_blocking '{}'
MARK='erp_batch_42' pg pg_xmin_horizon '{}'
MARK='order_lines|user_sessions' pg pg_top_statements '{}'
MARK='order_lines' pg pg_table_sizes '{}'
MARK='user_sessions_last_seen_idx' pg pg_unused_indexes '{}'
MARK='items_sku_idx1' pg pg_duplicate_indexes '{}'
MARK='order_lines_status_key' pg pg_invalid_indexes '{}'
MARK='max_prepared_transactions' pg pg_settings_changed '{}'
MARK='invoice_no_seq' pg pg_sequences '{}'
exec 8>&-
pq "rollback prepared 'erp_batch_42'" >/dev/null 2>&1 || true

# ---- meta, the pack, the tests ---------------------------------------------------------------------------------------
HOST=$(hostname); HOSTF=$(hostname -f 2>/dev/null || hostname)
PROJECT=$(curl -s --max-time 3 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/project/project-id 2>/dev/null || true)
# on GCE the full host name carries the project (<host>.<zone>.c.<project>.internal): its name, or the capture stops
if [[ -z $PROJECT && $HOSTF == *.c.*.internal ]]; then PROJECT=${HOSTF#*.c.}; PROJECT=${PROJECT%.internal}; fi
[[ -n $PROJECT || $HOSTF != *.internal ]] || fail "this machine's cloud project could not be read: its name would not be denied"
DENY_ALL="$HOST,$HOSTF,${CID:0:12},$REPO${PROJECT:+,$PROJECT}${PGVIGIL_SAMPLE_DENY:+,$PGVIGIL_SAMPLE_DENY}"
TOOLS_JSON=$(IFS=,; echo "[${TOOLS_META[*]}]")
export M_MS="$MS_SERVER" M_PG="$PG_SERVER" M_TOOLS="$TOOLS_JSON" M_DENY="$DENY_ALL" M_PGD="$PGD" M_SOCK="$SOCK" M_WORK="$WORK" M_CID="$CID" M_CT="$CT" M_HOSTF="$HOSTF" M_HOST="$HOST" M_REPO="$REPO" M_ROOT="$ROOT"
python3 - "$RAW/meta.json" <<'PY'
import json, sys, datetime, os
e = os.environ
m = {
  "captured_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
  "servers": {"sqlserver": e['M_MS'], "postgres": e['M_PG']},
  "tools": json.loads(e['M_TOOLS']),
  "replace": [[e['M_PGD'], "/var/lib/postgresql/data"], [e['M_SOCK'], "/var/run/postgresql"], [e['M_WORK'], "/tmp/capture"],
              [e['M_CID'], "testsql01"], [e['M_CID'][:12], "testsql01"], [e['M_CT'], "testsql01"], [e['M_HOSTF'], "pgvigil-host"], [e['M_HOST'], "pgvigil-host"],
              [e['M_REPO'], "pgvigil"], [e['M_ROOT'], "/opt/pgvigil"]],
  "deny": [w for w in e['M_DENY'].split(",") if w.strip()],
}
json.dump(m, open(sys.argv[1], "w"), indent=1)
print(f"ok   meta: {len(m['tools'])} tools, {len(m['replace'])} replacements, {len(m['deny'])} denied words")
PY
go run ./internal/demo/community/pack -raw "$RAW" | tee "$WORK/pack.log" || fail "the pack"
PGVIGIL_SAMPLE_DENY="$DENY_ALL" go test -count=1 -v -run 'TestStoredSamples|TestDeny' ./internal/demo/community/ 2>&1 | tail -6
[[ ${PIPESTATUS[0]} == 0 ]] || fail "the package's tests"
n=$(ls internal/demo/community/samples/*.json.gz | wc -l); bytes=$(cat internal/demo/community/samples/*.json.gz | wc -c)
[[ $n == 23 ]] || fail "$n samples, 23 expected"
echo "capture: $n samples, $bytes bytes, deny 0"
