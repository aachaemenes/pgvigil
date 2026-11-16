#!/usr/bin/env bash
# The request queue's click walk (CQ-A): pgvigil serve in queue mode (actions.via queue) on a fresh repository, a
# collector with cq.enabled holding two real servers (SQL Server 2022 with the First Responder Kit and sp_WhoIsActive,
# PostgreSQL 16 with pg_stat_statements, each in its own container), and a headless Chromium that clicks Community tools
# > Run for sp_Blitz and for one PostgreSQL tool, a Cancel through the queue, and reads every off control's words on
# the community and Running pages (scripts/cq-walk.mjs: rows W1-W9, the runs grid G3 G5 G6 G9 G10, the shot overlay S3). Then the repository's own rows of the walk's
# requests: state, holder, the asker, a stored result, and the audit row with via queue. Lab only: every password is
# made here at random and never leaves this host; no cloud credential.
#
#   bash scripts/proof-cq-walk.sh            from the top of the tree
#
#   PGVIGIL_BIN            the pgvigil binary (built from this tree with the wiring patches and the web bundle in)
#   PGVIGIL_COMMUNITY_DIR  frk-install-all.sql and sp_WhoIsActive.sql (required: the walk runs sp_Blitz and sp_WhoIsActive)
#   CQ_WALK_OUT            the folder of the shots, clicks.tsv, requests.txt, rows.txt and the logs (default .cq-walk)
#   CQ_WALK_PGTOOL         the PostgreSQL tool the walk runs (default pg_settings_changed)
#   Needs docker, psql, node 22+, chromium (or chromium-browser / google-chrome), curl, python3, ss, od.
# Exit: 0 every row ok; 1 a FAIL (said on its line).
set -u
cd "$(dirname "$0")/.." || exit 1
OUT=$(realpath -m "${CQ_WALK_OUT:-.cq-walk}"); mkdir -p "$OUT/log" || exit 1
PGTOOL=${CQ_WALK_PGTOOL:-pg_settings_changed}
N=$(( $(od -An -N3 -tu4 /dev/urandom | tr -d ' ') % 900000 + 100000 ))
PW="Cw$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
NET=cqwnet_$N; RCT=cqwrepo_$N; PCT=cqwpg_$N; MCT=cqwms_$N
RUN=""; SERVE=""; CHR=""; MADE=()
trap 'exit 1' TERM
fail() { echo "FAIL: $*" >&2; kill -TERM $$; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  for p in "$CHR" "$SERVE" "$RUN"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  wait 2>/dev/null || true
  rm -rf "$OUT/log/chrome-profile"   # the browser's profile holds the UI session's cookie: never fetched as evidence
  local k c   # the containers before the network they sit on: the newest first
  for (( k = ${#MADE[@]} - 1; k >= 0; k-- )); do c=${MADE[k]}; case $c in net:*) docker network rm "${c#net:}" >/dev/null 2>&1 ;; *) docker rm -f -v "$c" >/dev/null 2>&1 ;; esac; done
  rm -f "$OUT/col.yaml" "$OUT/serve.yaml" "$OUT/owner.yaml"
  return 0
}
trap cleanup EXIT
for t in docker psql node curl free ss od; do command -v $t >/dev/null || fail "$t is not on this machine"; done
CHROME=$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)
[[ -n "$CHROME" ]] || fail "no chromium on this machine"
BIN=$(realpath "${PGVIGIL_BIN:?names the pgvigil binary}")
CDIR=${PGVIGIL_COMMUNITY_DIR:?names the folder of frk-install-all.sql and sp_WhoIsActive.sql}
for f in frk-install-all.sql sp_WhoIsActive.sql; do [[ -r "$CDIR/$f" ]] || fail "$CDIR/$f is missing"; done
freeport() { local p; for _ in $(seq 1 50); do p=$((20000 + RANDOM % 20000)); ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }; done; fail "no free port"; }
echo "cq walk $N on $(hostname): load $(cut -d' ' -f1-3 /proc/loadavg), $(free -m | awk '/^Mem:/{print $7}') MB available"

# ---- the containers: the repository, the PostgreSQL server, the SQL Server -----------------------------------------
docker network create "$NET" >/dev/null || fail "docker network create $NET"; MADE+=("net:$NET")
RP=$(freeport)
docker run -d --name "$RCT" --network "$NET" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 -c max_connections=300 >/dev/null || fail "the repository container"
MADE+=("$RCT")
PP=$(freeport)
docker run -d --name "$PCT" --network "$NET" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$PP:5432" postgres:16 -c shared_preload_libraries=pg_stat_statements -c track_io_timing=on >/dev/null || fail "the PostgreSQL container"
MADE+=("$PCT")
MSSQL_SA_PASSWORD="Pw$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!a1"; export MSSQL_SA_PASSWORD SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
MP=$(freeport)
docker run -d --name "$MCT" --network "$NET" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MP:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "the SQL Server container"
MADE+=("$MCT")
sq() { docker exec -e SQLCMDPASSWORD "$MCT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1" 2>&1; }
sqf() { docker exec -i -e SQLCMDPASSWORD "$MCT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -d master -i /dev/stdin < "$1" >/dev/null 2>&1; }
RADM="host=127.0.0.1 port=$RP user=postgres password=$PW"; PADM="host=127.0.0.1 port=$PP user=postgres password=$PW"
for _ in $(seq 1 60); do psql "$RADM dbname=postgres" -XAtqc "select 1" >/dev/null 2>&1 && psql "$PADM dbname=postgres" -XAtqc "select 1" >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || fail "the SQL Server never answered"

# the repository: migrated by its owner; the collector's login and serve's (reader + auth + requester)
psql "$RADM dbname=postgres" -XAtqc "create database pgvigil" >/dev/null || fail "create database pgvigil"
export CQ_OWNER="$RADM dbname=pgvigil"
printf 'repository:\n  dsn: env:CQ_OWNER\ninstances: []\n' > "$OUT/owner.yaml"
"$BIN" migrate -config "$OUT/owner.yaml" > "$OUT/log/migrate.log" 2>&1 || fail "migrate: $(tail -3 "$OUT/log/migrate.log")"
rq() { psql "$CQ_OWNER" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
rq "create role cqw_col login password '$PW' in role pgvigil_collector; create role cqw_ui login password '$PW' in role pgvigil_reader, pgvigil_auth, pgvigil_requester" >/dev/null || fail "the repository logins"
export CQ_COL="host=127.0.0.1 port=$RP user=cqw_col password=$PW dbname=pgvigil"
export CQ_UI="host=127.0.0.1 port=$RP user=cqw_ui password=$PW dbname=pgvigil"
ok "the repository: postgres:18 in $RCT, migrated (newest $(rq "select max(version) from pgvigil.schema_version")), logins cqw_col and cqw_ui (reader + auth + requester)"

# the PostgreSQL server: pg_stat_statements and a pg_monitor login
psql "$PADM dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create extension if not exists pg_stat_statements; create role cqw_mon login password '$PW' in role pg_monitor" >/dev/null || fail "the PostgreSQL server's login"
export CQ_PG="host=127.0.0.1 port=$PP user=cqw_mon password=$PW dbname=postgres"
ok "PostgreSQL 16 in $PCT with pg_stat_statements, the login cqw_mon (pg_monitor)"

# the SQL Server: the First Responder Kit and sp_WhoIsActive, a read login
for f in frk-install-all.sql sp_WhoIsActive.sql; do sqf "$CDIR/$f" || fail "$f did not install"; done
RPW="Rd$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!b2"
sq "CREATE LOGIN cqw_reader WITH PASSWORD = '$RPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO cqw_reader; GRANT VIEW ANY DEFINITION TO cqw_reader; GRANT CONNECT ANY DATABASE TO cqw_reader; CREATE USER cqw_reader FOR LOGIN cqw_reader;" >/dev/null || fail "the SQL Server read login"
sq "CREATE USER cqw_reader FOR LOGIN cqw_reader; ALTER ROLE db_datareader ADD MEMBER cqw_reader;" msdb >/dev/null || fail "the read login's msdb user"
sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'GRANT EXECUTE ON dbo.' + QUOTENAME(name) + N' TO cqw_reader; ' FROM sys.procedures WHERE is_ms_shipped = 0 AND schema_id = 1; EXEC (@s);" >/dev/null || fail "the read login's EXECUTE grants"
export CQ_MS="sqlserver://cqw_reader:$RPW@127.0.0.1:$MP?database=master&encrypt=true&TrustServerCertificate=true"
ok "SQL Server 2022 in $MCT, the First Responder Kit and sp_WhoIsActive installed ($(sq "SELECT count(*) FROM sys.procedures WHERE name LIKE N'sp[_]Blitz%' OR name = N'sp_WhoIsActive'" | tr -dc '0-9') procedures), the login cqw_reader"

# ---- the collector (cq.enabled) and serve (actions.via queue) -------------------------------------------------------
inst() { printf '  - name: walk-pg\n    dsn: env:%s\n  - name: walk-ms\n    engine: sqlserver\n    dsn: env:%s\n' "$1" "$2"; }
{ printf 'repository:\n  dsn: env:CQ_COL\ncq:\n  enabled: true\n  workers: 4\ninstances:\n'; inst CQ_PG CQ_MS; } > "$OUT/col.yaml"
"$BIN" run -config "$OUT/col.yaml" > "$OUT/log/run.log" 2>&1 & RUN=$!
PGID=""; MSID=""; w=0
for w in $(seq 0 179); do
  PGID=$(rq "select instance_id from pgvigil.instances where name = 'walk-pg'"); MSID=$(rq "select instance_id from pgvigil.instances where name = 'walk-ms'")
  [[ -n "$PGID" && -n "$MSID" && $(rq "select count(*) from pgvigil.action_doors where kind = 'community_run' and name = '' and open") -ge 2 && $(rq "select count(distinct instance) from pgvigil.cq_tools where present") -ge 2 ]] && break
  sleep 1
done
[[ -n "$PGID" && -n "$MSID" ]] || fail "the collector did not register both instances in 180 s: $(tail -5 "$OUT/log/run.log")"
[[ $(rq "select count(*) from pgvigil.action_doors where kind = 'community_run' and name = '' and open") -ge 2 ]] || fail "the collector published no open community door for both instances in 180 s: $(tail -5 "$OUT/log/run.log")"
[[ $(rq "select count(distinct instance) from pgvigil.cq_tools where present") -ge 2 ]] || fail "the collector published no present tool for both instances in 180 s: $(tail -5 "$OUT/log/run.log")"
ok "the collector holds walk-pg (id $PGID) and walk-ms (id $MSID) after $w s: community doors open $(rq "select count(*) from pgvigil.action_doors where kind = 'community_run' and name = '' and open"), tools present $(rq "select count(*) from pgvigil.cq_tools where present")"
UIUSER=walk_alice; UIPW="Ui$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$OUT/owner.yaml" $UIUSER >/dev/null 2>&1 || fail "user add"
{ printf 'repository:\n  dsn: env:CQ_COL\nactions:\n  via: queue\ninstances:\n'; inst CQ_NONE CQ_NONE; } > "$OUT/serve.yaml"
UP=$(freeport); U="http://127.0.0.1:$UP/"
# serve gets none of the servers' or the owner's credentials in its environment: queue mode connects to nothing but the
# repository, and the log line below is not its only proof
env -u CQ_PG -u CQ_MS -u CQ_OWNER -u CQ_COL -u MSSQL_SA_PASSWORD -u SQLCMDPASSWORD "$BIN" serve -config "$OUT/serve.yaml" -dsn env:CQ_UI -listen "127.0.0.1:$UP" > "$OUT/log/serve.log" 2>&1 & SERVE=$!
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U" && break; sleep 1; done
curl -sf -o /dev/null "$U" || fail "serve does not answer: $(tail -5 "$OUT/log/serve.log")"
grep -q 'connects to no monitored server' "$OUT/log/serve.log" || fail "serve's log does not say queue mode: $(tail -5 "$OUT/log/serve.log")"
ok "serve in queue mode on $U (it connects to no monitored server), the UI user $UIUSER"

# ---- the walk ------------------------------------------------------------------------------------------------------
CP=$(freeport)
"$CHROME" --headless=new --no-sandbox --disable-gpu --remote-debugging-port="$CP" --user-data-dir="$OUT/log/chrome-profile" about:blank > "$OUT/log/chromium.log" 2>&1 & CHR=$!
for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:$CP/json/version" && break; sleep 1; done
curl -sf -o /dev/null "http://127.0.0.1:$CP/json/version" || fail "chromium's debug port never answered: $(tail -5 "$OUT/log/chromium.log")"
CQ_WALK_PW=$UIPW node scripts/cq-walk.mjs "$CP" "$U" "$UIUSER" "$OUT" "$MSID" "$PGID" "$PGTOOL"; WRC=$?
rm -rf "$OUT/log/chrome-profile"

# ---- the repository's own rows of the walk's requests --------------------------------------------------------------
IDS=$(awk '{print $2}' "$OUT/requests.txt" 2>/dev/null | grep -E '^[0-9]+$' | paste -sd, -)
if [[ -n "$IDS" ]]; then
  rq "select r.request_id, r.kind, r.instance, r.state, r.ui_user, r.taken_host, r.keep, d.result is not null as result_stored, r.cleared_at is not null as cleared, left(coalesce(nullif(r.outcome, ''), nullif(r.refusal, ''), ''), 120)
        from pgvigil.action_requests r left join pgvigil.ui_action_data d using (request_id) where r.request_id in ($IDS) order by 1" > "$OUT/rows.txt"
  rq "select payload->>'request_id', op, tool, instance, instance_id, ui_user, outcome, rows, payload->>'via', payload->>'collector'
        from pgvigil.custom_report_log where payload->>'via' = 'queue' and (payload->>'request_id')::bigint in ($IDS) order by 1" > "$OUT/audit.txt" 2>&1
  echo "the walk's requests ($IDS), as the repository holds them:"; sed 's/^/  /' "$OUT/rows.txt"
  echo "their audit rows (custom_report_log, via queue):"; sed 's/^/  /' "$OUT/audit.txt"
  while read -r wr id; do
    st=$(rq "select state from pgvigil.action_requests where request_id = $id")
    case $wr in
      W6) [[ $st == cancelled ]] || { echo "FAIL: $wr's request $id is $st in the repository (want cancelled)"; WRC=1; } ;;
      W9) [[ $st == failed ]] || { echo "FAIL: $wr's request $id is $st in the repository (want failed)"; WRC=1; }
          [[ $(rq "select count(*) from pgvigil.custom_report_log where payload->>'via' = 'queue' and payload->>'request_id' = '$id' and outcome = 'failed'") == 1 ]] || { echo "FAIL: $wr's request $id has no failed audit row with via queue"; WRC=1; } ;;
      *) [[ $st == done ]] || { echo "FAIL: $wr's request $id is $st in the repository (want done)"; WRC=1; }
         [[ $(rq "select count(*) from pgvigil.custom_report_log where payload->>'via' = 'queue' and payload->>'request_id' = '$id'") == 1 ]] || { echo "FAIL: $wr's request $id has no audit row with via queue"; WRC=1; } ;;
    esac
  done < "$OUT/requests.txt"
else echo "FAIL: the walk made no request"; WRC=1; fi
# the logs go back as evidence: none may hold a password this run made
leak=0; for v in "$PW" "$RPW" "$UIPW" "$MSSQL_SA_PASSWORD"; do grep -rqF -- "$v" "$OUT" 2>/dev/null && leak=1; done
[[ $leak == 0 ]] && ok "no password of this run in $OUT (the logs, clicks.tsv, rows.txt)" || { echo "FAIL: a password of this run is written under $OUT"; WRC=1; }
[[ $WRC == 0 ]] && echo "OK cq walk $N: every row ok" || echo "cq walk $N: FAIL (rc $WRC)"
exit $WRC
