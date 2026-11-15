#!/usr/bin/env bash
# Proof of CQ-A (migration 0200, internal/cq, internal/web q_requests.go / cq_community.go / community_exec.go,
# web/src/request.ts, docs/queue.md): community tools through the repository's request queue, run by the collector,
# while serve runs in a container on a network that reaches ONLY the repository and holds no instance credential.
#
#   PGVIGIL_ADMIN_DSN      keyword-form connection to a PostgreSQL 14+ cluster as a superuser, no dbname (the monitored
#                          PostgreSQL target: a database cqt_<n> and a pg_monitor login made here, dropped at the end).
#                          Required: the script stops before it makes anything without it.
#   PGVIGIL_COMMUNITY_DIR  frk-install-all.sql, darlingdata.sql, sp_WhoIsActive.sql (as proof-customreports.sh); without
#                          sp_WhoIsActive.sql the SQL Server rows are NOT PROVEN, said so.
#   PGVIGIL_BIN            a built binary; default: built here.
#   Needs: docker (the repository container, serve's container, SQL Server 2022), psql, curl, python3; pgbouncer on the
#   PATH for P3 (else P3 is NOT PROVEN, said so).
#
# What it makes: a docker network cqnet_<n>; the repository in a postgres:18 container on it (its port published on
# 127.0.0.1 for the collectors on this host); serve in a container on cqnet_<n> ONLY, its pgvigil.yaml with actions:
# via: queue, the instances' names and NO credential (dsn: env:CQ_NONE, unset there), its repository login IN ROLE
# pgvigil_reader, pgvigil_auth, pgvigil_requester given with -dsn while the file's repository dsn names the COLLECTOR's
# login (the queue must run on serve's own login: on the file's, serve would refuse to start); the collectors on this host with cq: enabled: true; a direct-mode
# serve on this host's loopback for the comparison. Each thing is removed at the end only if this run made it.
#
# Every check stops the script, a check inside $( ) too (fail signals the script itself): no row prints ok after a FAIL.
#
# Rows (expected written before each run in the report; red first: on a tree without 0200 the migrate or the first ask
# fails):
#   N   serve in its container starts with -dsn naming the UI's login while its file names the collector's, and answers;
#       serve's container reaches the repository and NOT the targets (TCP to the PostgreSQL target and to the SQL Server
#       container both fail from inside it, while a container on the SQL Server's own network reaches it: the probe can
#       succeed); serve's log says it connects to no monitored server
#   P1  through serve's API: pg_running, pg_settings_changed, sp_WhoIsActive (show_own_spid 1), sp_Blitz and
#       sp_WhoIsActive's @help each answer 202 {request_id}, then done on GET /api/requests/<id>?wait=25 with sets;
#       pg_settings_changed's sets equal the direct serve's (columns, row count); sp_WhoIsActive's columns equal;
#       each run's custom_report_log row says via queue with its request id and carries the instance's id
#   P8  sp_WhoIsActive with @destination_table refused at the worker ('has no parameter @destination_table pgvigil
#       passes'); Glenn Berry's free SQL refused at the insert with community_allow unset ('sends free SQL text'); a
#       forged kind refused at the insert
#   P13 a reader login (Grafana's shape) gets 42501 on ui_action_data and on ui_action_result; a second UI user's GET of
#       the first's request: 403 'this run was asked by another user' (the masked line waits for 488)
#   P2  20 asks: the claim within 1 s of the insert (median of taken_at - asked_at) and the GET's answer within 1 s of
#       done_at (median)
#   P6  cancel: a waiting request (the collector stopped with SIGSTOP) 'cancelled' at once; a running sp_WhoIsActive
#       (@delta_interval 30) 'cancelled' within 10 s and no WAITFOR of the read login left on the server
#   P5  a healthy sp_WhoIsActive run of 45 s (@delta_interval 45) ends done, never 'lost'; an ask made when the minute
#       heartbeat is at least 50 s old is accepted and done; a SIGKILLed collector's running request is 'lost' within
#       30 s of its last renewal (+5 s for the sweep), and after a second collector that holds the instance ran for
#       20 s it is still lost, taken by the first, with no audit row (nobody finished it)
#   P9  two collectors holding one instance (both live leases seen): 200 asks (20 rounds of 10, the open-request cap),
#       each done exactly once (200 audit rows, 200 distinct request ids), taken by both collectors
#   P3  the collector's repository dsn through pgbouncer in transaction mode: 10 asks each done and claimed within 6 s
#       (the 5 s poll), and a running cancel still ends 'cancelled'
set -u
export LC_ALL=C
: "${PGVIGIL_ADMIN_DSN:?names the monitored PostgreSQL target as a superuser, keyword form, no dbname}"
WORK=$(mktemp -d); N=$(( $(od -An -N3 -tu4 /dev/urandom | tr -d ' ') % 900000 + 100000 )); NOTPROVEN=()
PW="Cq$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
NET=cqnet_$N; RCT=cqrepo_$N; SCT=cqserve_$N; MCT=cqms_$N; TGT=cqt_$N; MON=cqmon_$N
RUN1=""; RUN2=""; DIRECT=""; BOUNCER=""
# each set only after its create succeeded: a name another run holds is never removed by this one
MADE_NET=""; MADE_RCT=""; MADE_SCT=""; MADE_MS=""; MADE_TGT=""; MADE_MON=""
trap 'exit 1' TERM
fail() { echo "FAIL: $*" >&2; kill -TERM $$; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  rm -rf "$WORK"   # first: serve.yaml holds the repository password
  for p in "$RUN1" "$RUN2" "$DIRECT" "$BOUNCER"; do [[ -n "$p" ]] && { kill -CONT "$p" 2>/dev/null; kill "$p" 2>/dev/null; } || true; done
  wait 2>/dev/null || true
  [[ -n "$MADE_SCT" ]] && docker rm -f -v "$SCT" >/dev/null 2>&1
  [[ -n "$MADE_RCT" ]] && docker rm -f -v "$RCT" >/dev/null 2>&1
  [[ -n "$MADE_MS" ]] && docker rm -f -v "$MCT" >/dev/null 2>&1
  [[ -n "$MADE_NET" ]] && docker network rm "$NET" >/dev/null 2>&1
  [[ -n "$MADE_TGT" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $TGT with (force)" >/dev/null 2>&1
  [[ -n "$MADE_MON" ]] && psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
for t in psql curl python3 docker ss od; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() { local p; for _ in $(seq 1 50); do p=$((20000 + RANDOM % 20000)); ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }; done; fail "no free port"; }
if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$(realpath "$PGVIGIL_BIN"); else BIN=$WORK/pgvigil; CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil || fail "go build"; fi
echo "cq proof $N"

# ---- the repository in a container -----------------------------------------------------------------------------------
docker network create "$NET" >/dev/null || fail "docker network create $NET"
MADE_NET=1
RP=$(freeport)
docker run -d --name "$RCT" --network "$NET" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 -c max_connections=300 >/dev/null || fail "the repository container $RCT"
MADE_RCT=1
for _ in $(seq 1 60); do psql "host=127.0.0.1 port=$RP user=postgres password=$PW dbname=postgres" -XAtqc "select 1" >/dev/null 2>&1 && break; sleep 1; done
RADM="host=127.0.0.1 port=$RP user=postgres password=$PW"
psql "$RADM dbname=postgres" -XAtqc "create database pgvigil" >/dev/null || fail "create database pgvigil"
export CQ_OWNER="$RADM dbname=pgvigil"
printf 'repository:\n  dsn: env:CQ_OWNER\ninstances: []\n' > "$WORK/owner.yaml"
"$BIN" migrate -config "$WORK/owner.yaml" > "$WORK/migrate.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/migrate.log")"
rq() { psql "$CQ_OWNER" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
[[ $(rq "select to_regclass('pgvigil.action_requests') is not null") == t ]] || fail "0200 is not applied"
rq "create role cq_col login password '$PW' in role pgvigil_collector; create role cq_ui login password '$PW' in role pgvigil_reader, pgvigil_auth, pgvigil_requester;
    create role cq_graf login password '$PW' in role pgvigil_reader;" >/dev/null || fail "the repository logins"
export CQ_COL="host=127.0.0.1 port=$RP user=cq_col password=$PW dbname=pgvigil"
export CQ_UI_HOST="host=127.0.0.1 port=$RP user=cq_ui password=$PW dbname=pgvigil"
ok "the repository: postgres:18 in $RCT, migrated (0200), logins cq_col / cq_ui (reader + auth + requester) / cq_graf"

# ---- the targets ---------------------------------------------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $TGT" >/dev/null || fail "the PostgreSQL target database $TGT"
MADE_TGT=1
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create role $MON login password '$PW' in role pg_monitor" >/dev/null || fail "the PostgreSQL target login $MON"
MADE_MON=1
export TGT_MON="$PGVIGIL_ADMIN_DSN dbname=$TGT user=$MON password=$PW"
CDIR=${PGVIGIL_COMMUNITY_DIR:-}; MS=""
if [[ -n "$CDIR" && -r "$CDIR/sp_WhoIsActive.sql" ]]; then
  MSSQL_SA_PASSWORD="Pg$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!a1"; export MSSQL_SA_PASSWORD SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  MP=$(freeport)
  docker run -d --name "$MCT" -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD -p "127.0.0.1:$MP:1433" "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}" >/dev/null || fail "the SQL Server container $MCT"
  MADE_MS=1
  sq() { docker exec -e SQLCMDPASSWORD "$MCT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -W -h -1 -U sa -d "${2:-master}" -Q "SET NOCOUNT ON; $1" 2>&1; }
  sqf() { docker exec -i -e SQLCMDPASSWORD "$MCT" /opt/mssql-tools18/bin/sqlcmd -S localhost -C -b -I -U sa -d master -i /dev/stdin < "$1" >/dev/null 2>&1; }
  for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
  for f in frk-install-all.sql sp_WhoIsActive.sql; do [[ -r "$CDIR/$f" ]] && { sqf "$CDIR/$f" || fail "$f did not install"; }; done
  RPW="Rd$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')!b2"
  sq "CREATE LOGIN cq_reader WITH PASSWORD = '$RPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO cq_reader; GRANT VIEW ANY DEFINITION TO cq_reader; GRANT CONNECT ANY DATABASE TO cq_reader; CREATE USER cq_reader FOR LOGIN cq_reader;" >/dev/null
  sq "CREATE USER cq_reader FOR LOGIN cq_reader; ALTER ROLE db_datareader ADD MEMBER cq_reader;" msdb >/dev/null
  sq "DECLARE @s nvarchar(max) = N''; SELECT @s += N'GRANT EXECUTE ON dbo.' + QUOTENAME(name) + N' TO cq_reader; ' FROM sys.procedures WHERE is_ms_shipped = 0 AND schema_id = 1; EXEC (@s);" >/dev/null
  export MS_R="sqlserver://cq_reader:$RPW@127.0.0.1:$MP?database=master&encrypt=true&TrustServerCertificate=true"
  MS=1
  ok "SQL Server 2022 in $MCT, sp_WhoIsActive and the First Responder Kit installed, cq_reader"
else NOTPROVEN+=("the SQL Server rows of N (its leg), P1, P6, P8 (sp_WhoIsActive.sql not given in PGVIGIL_COMMUNITY_DIR)"); fi

# ---- the collectors (this host) and the two serves ----------------------------------------------------------------
inst() { printf '  - name: cq-pg\n    dsn: env:%s\n' "$1"; [[ -n "$MS" ]] && printf '  - name: cq-ms\n    engine: sqlserver\n    dsn: env:%s\n' "$2"; return 0; }
{ printf 'repository:\n  dsn: env:CQ_COL\ncq:\n  enabled: true\n  workers: 4\ninstances:\n'; inst TGT_MON MS_R; } > "$WORK/col.yaml"
startrun() { "$BIN" run -config "$1" > "$2" 2>&1 & echo $!; }
RUN1=$(startrun "$WORK/col.yaml" "$WORK/run1.log")
want=1; [[ -n "$MS" ]] && want=2
for _ in $(seq 1 60); do
  [[ $(rq "select count(*) from pgvigil.action_doors d join pgvigil.cq_workers w using (collector_id) where w.beat_at > now() - interval '45 seconds' and d.kind = 'community_run' and d.name = '' and d.open") -ge $want ]] && break; sleep 1
done
[[ $(rq "select count(*) from pgvigil.action_doors where kind = 'community_run' and name = '' and open") -ge $want ]] || fail "the collector published no open community door: $(tail -5 "$WORK/run1.log")"
for _ in $(seq 1 90); do [[ $(rq "select count(*) from pgvigil.cq_tools where present") -ge 3 ]] && break; sleep 1; done
ok "the collector holds $want instance(s), the community doors open, $(rq "select count(*) from pgvigil.cq_tools where present") tool(s) published present"
# the proof reaches serve as https://127.0.0.1:$SP (curl -k): the container's name ($SCT, with an underscore, which a
# certificate's DNS name cannot hold) is not one of the certificate's hosts
CERT_OUT=$("$BIN" cert -hosts "localhost,127.0.0.1" -out "$WORK" 2>&1) || fail "pgvigil cert: $CERT_OUT"
{ printf 'repository:\n  dsn: "host=%s port=5432 user=cq_col password=%s dbname=pgvigil"\nactions:\n  via: queue\ninstances:\n' "$RCT" "$PW"; inst CQ_NONE CQ_NONE; } > "$WORK/serve.yaml"
UIUSER=cq_alice; UIPW="Ui$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; UI2=cq_bob
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$WORK/owner.yaml" $UIUSER >/dev/null 2>&1 || fail "user add"
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$WORK/owner.yaml" $UI2 >/dev/null 2>&1 || fail "user add 2"
SP=$(freeport)
docker run -d --name "$SCT" --network "$NET" -p "127.0.0.1:$SP:8443" -v "$BIN:/pgvigil:ro" -v "$WORK/serve.yaml:/serve.yaml:ro" \
  -v "$WORK/pgvigil.crt:/pgvigil.crt:ro" -v "$WORK/pgvigil.key:/pgvigil.key:ro" -e CQ_UI_IN="host=$RCT port=5432 user=cq_ui password=$PW dbname=pgvigil" postgres:18 \
  /pgvigil serve -config /serve.yaml -dsn env:CQ_UI_IN -listen 0.0.0.0:8443 -tls-cert /pgvigil.crt -tls-key /pgvigil.key >/dev/null || fail "serve's container $SCT"
MADE_SCT=1
U="https://127.0.0.1:$SP"
for _ in $(seq 1 60); do curl -skf -o /dev/null "$U/" && break; sleep 1; done
curl -skf -o /dev/null "$U/" || fail "serve in its container does not answer (a start refused on the file's collector login means the queue did not take -dsn): $(docker logs "$SCT" 2>&1 | tail -5)"
DP=$(freeport); DU="http://127.0.0.1:$DP"
{ printf 'repository:\n  dsn: env:CQ_COL\ninstances:\n'; inst TGT_MON MS_R; } > "$WORK/direct.yaml"
"$BIN" serve -config "$WORK/direct.yaml" -dsn env:CQ_UI_HOST -listen "127.0.0.1:$DP" > "$WORK/direct.log" 2>&1 & DIRECT=$!
for _ in $(seq 1 60); do curl -sf -o /dev/null "$DU/" && break; sleep 1; done
login() { curl -sk -c "$1" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$2\",\"password\":\"$UIPW\"}" "$3/api/login" >/dev/null; }
JAR=$WORK/jar; JAR2=$WORK/jar2; DJAR=$WORK/djar
login "$JAR" $UIUSER "$U"; login "$JAR2" $UI2 "$U"; login "$DJAR" $UIUSER "$DU"
code() { curl -sk --max-time 40 -o "$WORK/body" -w '%{http_code}' "$@"; }
post() { code -b "${3:-$JAR}" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "${4:-$U}/api/$1"; }
getc() { code -b "${2:-$JAR}" "${3:-$U}/api/$1"; }
js() { python3 -c "import json,sys; d=json.load(open('$WORK/body')); print($1)"; }
isid() { [[ $1 =~ ^[0-9]+$ ]] || fail "not a request id: '$1'"; }
PGID=$(rq "select instance_id from pgvigil.instances where name = 'cq-pg'"); MSID=""; [[ -n "$MS" ]] && MSID=$(rq "select instance_id from pgvigil.instances where name = 'cq-ms'")
[[ -n "$PGID" ]] || fail "cq-pg is not registered (the collector's first read): $(tail -5 "$WORK/run1.log")"

# ---- N: serve reaches the repository and not the targets ----------------------------------------------------------
GW=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NET")
[[ -n "$GW" ]] || fail "N: no gateway address for $NET"
PGPORT=$(python3 -c "import re,sys; m=re.search(r'port=(\d+)', sys.argv[1]); print(m.group(1) if m else 5432)" "$PGVIGIL_ADMIN_DSN")
reach() { docker exec "$SCT" timeout 4 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }
reach "$RCT" 5432 || fail "N: serve's container cannot reach the repository"
# the PostgreSQL leg means something only when the target answers on an address a container could reach: a probe
# container on the default bridge must reach it first (review 20261115-124313 #4: a target on loopback only refuses
# every container, isolated or not)
BGW=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' bridge 2>/dev/null)
if [[ -n "$BGW" ]] && docker run --rm postgres:18 timeout 4 bash -c "</dev/tcp/$BGW/$PGPORT" >/dev/null 2>&1; then
  reach "$GW" "$PGPORT" && fail "N: serve's container reaches the PostgreSQL target on $GW:$PGPORT"
  NPG="the PostgreSQL target refused from inside it, reached from bridge at $BGW"
else
  NOTPROVEN+=("N's PostgreSQL leg: no container reaches the target at all (a probe on bridge does not reach ${BGW:-its gateway}:$PGPORT), so serve's refusal proves nothing")
  NPG="the PostgreSQL leg NOT PROVEN (below)"
fi
if [[ -n "$MS" ]]; then
  MIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$MCT" | awk '{print $1}')
  [[ -n "$MIP" ]] || fail "N: no address for the SQL Server container $MCT"
  MNET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$MCT" | awk '{print $1}')
  docker run --rm --network "$MNET" postgres:18 timeout 4 bash -c "</dev/tcp/$MIP/1433" >/dev/null 2>&1 || fail "N: the probe's positive control: a container on $MNET does not reach $MIP:1433"
  reach "$MIP" 1433 && fail "N: serve's container reaches the SQL Server container"
fi
docker logs "$SCT" 2>&1 | grep -q 'connects to no monitored server' || fail "N: serve's log does not say queue mode"
ok "N: serve's container reaches the repository only ($NPG${MS:+; the SQL Server at $MIP refused from inside it, reached from $MNET}); serve says queue mode"

# ---- P1 through serve's API ------------------------------------------------------------------------------------------
waitreq() {   # waitreq <id> [jar]: GET until the request ended; prints its state
  local s=""
  isid "$1"
  for _ in $(seq 1 6); do
    getc "requests/$1?wait=25" "${2:-$JAR}" >/dev/null; s=$(js "d.get('state', d.get('error', ''))")
    [[ $s != waiting && $s != running ]] && break
  done
  echo "$s"
}
ask() {   # ask <path> <body>: the 202's request id, or fails
  local c id; c=$(post "$1" "$2"); [[ $c == 202 ]] || fail "$1 $2: $c $(cat "$WORK/body")"; id=$(js "d['request_id']"); isid "$id"; echo "$id"
}
qrun() { local id; id=$(ask community/run "$1"); [[ $(waitreq "$id") == done ]] || fail "P1: $1 through the queue: $(cat "$WORK/body")"; cp "$WORK/body" "$WORK/q-$2.json"; echo "$id"; }
ID1=$(qrun "{\"instance_id\":$PGID,\"tool\":\"pg_running\"}" pgrun); isid "$ID1"
ID2=$(qrun "{\"instance_id\":$PGID,\"tool\":\"pg_settings_changed\"}" pgset); isid "$ID2"
[[ $(post community/run "{\"instance_id\":$PGID,\"tool\":\"pg_settings_changed\"}" "$DJAR" "$DU") == 200 ]] || fail "P1: the direct run: $(cat "$WORK/body")"
cp "$WORK/body" "$WORK/d-pgset.json"
python3 - "$WORK/q-pgset.json" "$WORK/d-pgset.json" <<'PY' || fail "P1: pg_settings_changed: the queue's sets differ from the direct run's"
import json, sys
q = json.load(open(sys.argv[1]))['result']['sets']; d = json.load(open(sys.argv[2]))['runs'][0]['sets']
assert len(q) == len(d) and all(a['columns'] == b['columns'] and len(a['rows']) == len(b['rows']) for a, b in zip(q, d)), (q, d)
PY
IDS="$ID1,$ID2"; NIDS=2
if [[ -n "$MS" ]]; then
  ID3=$(qrun "{\"instance_id\":$MSID,\"tool\":\"sp_WhoIsActive\",\"params\":{\"show_own_spid\":\"1\"}}" who); isid "$ID3"
  ID4=$(qrun "{\"instance_id\":$MSID,\"tool\":\"sp_Blitz\"}" blitz); isid "$ID4"
  ID5=$(ask "community/run?help=1" "{\"instance_id\":$MSID,\"tool\":\"sp_WhoIsActive\"}"); isid "$ID5"
  [[ $(waitreq "$ID5") == done ]] || fail "P1: sp_WhoIsActive's help: $(cat "$WORK/body")"
  [[ $(post community/run "{\"instance_id\":$MSID,\"tool\":\"sp_WhoIsActive\",\"params\":{\"show_own_spid\":\"1\"}}" "$DJAR" "$DU") == 200 ]] || fail "P1: the direct sp_WhoIsActive: $(cat "$WORK/body")"
  python3 - "$WORK/q-who.json" "$WORK/body" <<'PY' || fail "P1: sp_WhoIsActive: the queue's columns differ from the direct run's"
import json, sys
q = json.load(open(sys.argv[1]))['result']['sets']; d = json.load(open(sys.argv[2]))['runs'][0]['sets']
assert q and d and q[0]['columns'] == d[0]['columns'], (q[:1], d[:1])
PY
  IDS="$IDS,$ID3,$ID4,$ID5"; NIDS=5
fi
read -r n nid nreq <<<"$(rq "select count(*), count(instance_id), count(distinct payload->>'request_id') from pgvigil.custom_report_log where payload->>'via' = 'queue' and (payload->>'request_id')::bigint in ($IDS)" | tr '|' ' ')"
[[ $n == "$NIDS" && $nid == "$NIDS" && $nreq == "$NIDS" ]] || fail "P1: $n audit row(s) with via queue for requests $IDS, $nid with the instance's id, $nreq distinct requests (want $NIDS each)"
ok "P1: $NIDS community runs through serve's container, each done with its sets and its audit row (via queue, the instance's id); pg_settings_changed equal to the direct run, sp_WhoIsActive's columns equal"

# ---- P8, P13 ---------------------------------------------------------------------------------------------------------
if [[ -n "$MS" ]]; then
  id=$(ask community/run "{\"instance_id\":$MSID,\"tool\":\"sp_WhoIsActive\",\"params\":{\"destination_table\":\"dbo.x\"}}"); isid "$id"
  [[ $(waitreq "$id") == refused ]] && grep -q 'has no parameter @destination_table pgvigil passes' "$WORK/body" || fail "P8: the table-writing parameter at the worker: $(cat "$WORK/body")"
  c=$(post community/run "{\"instance_id\":$MSID,\"tool\":\"glenn_berry\",\"text\":\"SELECT 1 AS x\",\"query_name\":\"1 x\"}")
  [[ $c == 400 ]] && grep -q 'sends free SQL text' "$WORK/body" || fail "P8: Glenn Berry's free SQL with community_allow unset: $c $(cat "$WORK/body")"
fi
out=$(rq "select pgvigil.import_action_request('{\"kind\": \"drop_database\", \"instance\": \"cq-pg\", \"ui_user\": \"x\", \"args\": {}}'::jsonb)->>'detail'")
[[ $out == "the queue knows no kind drop_database" ]] || fail "P8: a forged kind: $out"
GRAF="host=127.0.0.1 port=$RP user=cq_graf password=$PW dbname=pgvigil"
# by SQLSTATE, never the message's words (review #13); the control: the same login reads action_requests (0200's header)
out=$(psql "$GRAF" -XAtq -v VERBOSITY=sqlstate -c "select count(*) from pgvigil.action_requests" 2>&1) || fail "P13: the reader's control - it cannot read action_requests: $out"
out=$(psql "$GRAF" -XAtq -v VERBOSITY=sqlstate -c "select count(*) from pgvigil.ui_action_data" 2>&1 || true)
[[ $out == *42501* ]] || fail "P13: the reader read ui_action_data: $out"
out=$(psql "$GRAF" -XAtq -v VERBOSITY=sqlstate -c "select pgvigil.ui_action_result($ID1, '$UIUSER')" 2>&1 || true)
[[ $out == *42501* ]] || fail "P13: the reader called ui_action_result: $out"
[[ $(getc "requests/$ID1" "$JAR2") == 403 ]] && grep -q 'this run was asked by another user' "$WORK/body" || fail "P13: the second user's GET: $(cat "$WORK/body")"
ok "P8: the table-writing parameter refused at the worker${MS:+, the free SQL of Glenn Berry at the insert}, a forged kind at the insert; P13: the reader 42501 on ui_action_data and ui_action_result (it reads action_requests), the second user 403"

# ---- P2: latency ----------------------------------------------------------------------------------------------------
: > "$WORK/lat"
for k in $(seq 1 20); do
  id=$(ask community/run "{\"instance_id\":$PGID,\"tool\":\"pg_settings_changed\"}"); isid "$id"
  [[ $(waitreq "$id") == done ]] || fail "P2: ask $k: $(cat "$WORK/body")"; t_get=$(date +%s.%N)
  echo "$id $t_get" >> "$WORK/lat"
done
python3 - "$WORK/lat" "$CQ_OWNER" <<'PY' || fail "P2: over 1 s"
import subprocess, sys, statistics
rows = [l.split() for l in open(sys.argv[1])]
ids = ','.join(r[0] for r in rows)
out = subprocess.run(['psql', sys.argv[2], '-XAtc', f"select request_id, extract(epoch from taken_at - asked_at), extract(epoch from done_at) from pgvigil.action_requests where request_id in ({ids})"], capture_output=True, text=True, check=True).stdout
db = {int(a): (float(b), float(c)) for a, b, c in (l.split('|') for l in out.split())}
assert len(db) == 20, f"{len(db)} rows of 20"
claim = statistics.median(db[int(i)][0] for i, _ in rows); answer = statistics.median(float(t) - db[int(i)][1] for i, t in rows)
assert claim < 1 and answer < 1, f"the claim {claim:.3f} s, the answer {answer:.3f} s (medians)"
print(f"ok   P2: 20 asks: the claim {claim:.3f} s after the insert, the GET answered {answer:.3f} s after the end (medians)")
PY

# ---- P6: cancel -----------------------------------------------------------------------------------------------------
kill -STOP "$RUN1"
id=$(ask community/run "{\"instance_id\":$PGID,\"tool\":\"pg_running\"}"); isid "$id"
[[ $(post "requests/$id/cancel" '{}') == 200 ]] && [[ $(rq "select state from pgvigil.action_requests where request_id = $id") == cancelled ]] || fail "P6: a waiting cancel: $(cat "$WORK/body")"
kill -CONT "$RUN1"
cancel_running() {   # cancel_running <label>: prints the seconds the cancel took; any check failing stops the script
  local id t0
  id=$(ask community/run "{\"instance_id\":$MSID,\"tool\":\"sp_WhoIsActive\",\"params\":{\"delta_interval\":\"30\"},\"timeout_secs\":60}"); isid "$id"
  for _ in $(seq 1 40); do [[ $(rq "select state from pgvigil.action_requests where request_id = $id") == running ]] && break; sleep 0.5; done
  [[ $(rq "select state from pgvigil.action_requests where request_id = $id") == running ]] || fail "P6 $1: the run never started: $(rq "select state, outcome from pgvigil.action_requests where request_id = $id")"
  sleep 3; t0=$(date +%s)
  [[ $(post "requests/$id/cancel" '{}') == 200 ]] || fail "P6 $1: the cancel POST: $(cat "$WORK/body")"
  for _ in $(seq 1 20); do [[ $(rq "select state from pgvigil.action_requests where request_id = $id") == cancelled ]] && break; sleep 0.5; done
  [[ $(rq "select state from pgvigil.action_requests where request_id = $id") == cancelled ]] || fail "P6 $1: a running cancel: $(rq "select state, outcome from pgvigil.action_requests where request_id = $id")"
  [[ $(sq "SELECT count(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.login_name = 'cq_reader' AND r.wait_type = 'WAITFOR'" | tr -d ' \r') == 0 ]] || fail "P6 $1: a WAITFOR of the read login is left"
  echo "$(( $(date +%s) - t0 ))"
}
if [[ -n "$MS" ]]; then
  s=$(cancel_running direct); [[ $s =~ ^[0-9]+$ && $s -le 10 ]] || fail "P6: a running cancel took '$s' s (want 10 at most)"
  ok "P6: a waiting cancel at once; a running sp_WhoIsActive cancelled in ${s} s, no WAITFOR left"
else ok "P6: a waiting cancel at once (the running cancel needs SQL Server)"; fi

# ---- P5: the lease --------------------------------------------------------------------------------------------------
if [[ -n "$MS" ]]; then
  id=$(ask community/run "{\"instance_id\":$MSID,\"tool\":\"sp_WhoIsActive\",\"params\":{\"delta_interval\":\"45\"},\"timeout_secs\":60}"); isid "$id"
  [[ $(waitreq "$id") == done ]] || fail "P5: a healthy 45 s run: $(rq "select state, outcome from pgvigil.action_requests where request_id = $id")"
  # the age is read AT the ask (asked_at against the newest beat), never before it: a beat landing between the two
  # reads would leave the row's words true and the ask fresh (review #6); a beat after the ask = that try again
  age=""
  for try in 1 2 3; do
    for _ in $(seq 1 70); do [[ $(rq "select extract(epoch from now() - max(beat_at))::int >= 50 from pgvigil.collector_heartbeat where stopped_at is null") == t ]] && break; sleep 1; done
    id=$(ask community/run "{\"instance_id\":$PGID,\"tool\":\"pg_running\"}"); isid "$id"
    age=$(rq "select extract(epoch from r.asked_at - h.b)::int from pgvigil.action_requests r, (select max(beat_at) b from pgvigil.collector_heartbeat where stopped_at is null) h where r.request_id = $id")
    [[ $(waitreq "$id") == done ]] || fail "P5: the ask with the heartbeat ${age} s old: $(cat "$WORK/body")"
    [[ $age =~ ^[0-9]+$ && $age -ge 50 ]] && break
  done
  [[ $age =~ ^[0-9]+$ && $age -ge 50 ]] || fail "P5: no ask in 3 tries met a heartbeat 50 s old at its asked_at (last '$age')"
  id=$(ask community/run "{\"instance_id\":$MSID,\"tool\":\"sp_WhoIsActive\",\"params\":{\"delta_interval\":\"50\"},\"timeout_secs\":60}"); isid "$id"
  for _ in $(seq 1 40); do [[ $(rq "select state from pgvigil.action_requests where request_id = $id") == running ]] && break; sleep 0.5; done
  holder=$(rq "select taken_by from pgvigil.action_requests where request_id = $id and state = 'running'")
  [[ -n "$holder" ]] || fail "P5: the 50 s run never started: $(rq "select state, outcome from pgvigil.action_requests where request_id = $id")"
  sleep 2; kill -KILL "$RUN1"; RUN1=""
  renew=$(rq "select extract(epoch from lease_until - interval '25 seconds') from pgvigil.action_requests where request_id = $id")
  for _ in $(seq 1 80); do getc "requests/$id" >/dev/null; [[ $(js "d['state']") == lost ]] && break; sleep 0.5; done
  [[ $(js "d['state']") == lost ]] || fail "P5: a SIGKILLed collector's run is not lost: $(cat "$WORK/body")"
  late=$(rq "select round(extract(epoch from done_at) - $renew)::int from pgvigil.action_requests where request_id = $id")
  [[ $late =~ ^-?[0-9]+$ && $late -le 35 ]] || fail "P5: lost '$late' s after its last renewal (want 30 + 5 for the sweep)"
  RUN2=$(startrun "$WORK/col.yaml" "$WORK/run2.log")
  live=0; for _ in $(seq 1 60); do live=$(rq "select count(*) from pgvigil.cq_workers where beat_at > now() - interval '45 seconds' and collector_id <> '$holder' and 'cq-ms' = any(instances)"); [[ $live -ge 1 ]] && break; sleep 1; done
  [[ $live -ge 1 ]] || fail "P5: the next collector holds no live lease on cq-ms: $(tail -5 "$WORK/run2.log")"
  sleep 20
  [[ $(rq "select state || '/' || taken_by from pgvigil.action_requests where request_id = $id") == "lost/$holder" ]] || fail "P5: the lost request changed: $(rq "select state, taken_by from pgvigil.action_requests where request_id = $id")"
  [[ $(rq "select count(*) from pgvigil.custom_report_log where payload->>'request_id' = '$id'") == 0 ]] || fail "P5: the lost request has an audit row: someone finished it"
  ok "P5: a healthy 45 s run done (never lost); an ask with the minute heartbeat ${age} s old accepted and done; a SIGKILLed collector's run lost ${late} s after its last renewal, still lost and unfinished (no audit row) after the next collector held cq-ms for 20 s"
  RUN1=$RUN2; RUN2=""
else NOTPROVEN+=("P5 (a run long enough to kill under needs sp_WhoIsActive)"); fi

# ---- P9: two collectors holding one instance ------------------------------------------------------------------------
{ printf 'repository:\n  dsn: env:CQ_COL\ncq:\n  enabled: true\n  workers: 4\ninstances:\n'; printf '  - name: cq-pg\n    dsn: env:TGT_MON\n'; } > "$WORK/col2.yaml"
RUN2=$(startrun "$WORK/col2.yaml" "$WORK/run2.log")
live=0
for _ in $(seq 1 30); do live=$(rq "select count(*) from pgvigil.cq_workers where beat_at > now() - interval '45 seconds' and collector_id <> '${holder:-}' and 'cq-pg' = any(instances)"); [[ $live -ge 2 ]] && break; sleep 1; done
[[ $live -ge 2 ]] || fail "P9: $live live lease(s) on cq-pg, want 2: $(tail -5 "$WORK/run2.log")"
: > "$WORK/p9"
for round in $(seq 1 20); do
  ids=()
  for k in $(seq 1 10); do id=$(ask community/run "{\"instance_id\":$PGID,\"tool\":\"pg_settings_changed\"}"); isid "$id"; ids+=("$id"); done
  for i in "${ids[@]}"; do [[ $(waitreq "$i") == done ]] || fail "P9: round $round, request $i: $(cat "$WORK/body")"; echo "$i" >> "$WORK/p9"; done
done
P9=$(paste -sd, "$WORK/p9")
read -r done_n holders <<<"$(rq "select count(*) filter (where state = 'done'), count(distinct taken_by) from pgvigil.action_requests where request_id in ($P9)" | tr '|' ' ')"
read -r arows aids <<<"$(rq "select count(*), count(distinct payload->>'request_id') from pgvigil.custom_report_log where (payload->>'request_id')::bigint in ($P9)" | tr '|' ' ')"
[[ $done_n == 200 && $arows == 200 && $aids == 200 && $holders == 2 ]] || fail "P9: done $done_n, audit rows $arows, distinct ids $aids (want 200 each), taken by $holders collector(s) (want 2)"
ok "P9: two collectors (2 live leases), 200 asks: 200 done, 200 audit rows of 200 distinct requests, taken by both"
kill "$RUN2" 2>/dev/null; for _ in $(seq 1 30); do kill -0 "$RUN2" 2>/dev/null || break; sleep 1; done
kill -0 "$RUN2" 2>/dev/null && fail "P9: its second collector did not stop on TERM in 30 s"; RUN2=""

# ---- P3: through pgbouncer in transaction mode ----------------------------------------------------------------------
if command -v pgbouncer >/dev/null; then
  BP=$(freeport)
  printf '[databases]\npgvigil = host=127.0.0.1 port=%s dbname=pgvigil\n[pgbouncer]\nlisten_addr = 127.0.0.1\nlisten_port = %s\nauth_type = trust\nauth_file = %s/users.txt\npool_mode = transaction\nmax_client_conn = 200\ndefault_pool_size = 20\nignore_startup_parameters = extra_float_digits,application_name\nunix_socket_dir =\n' "$RP" "$BP" "$WORK" > "$WORK/pgb.ini"
  printf '"cq_col" "%s"\n' "$PW" > "$WORK/users.txt"
  pgbouncer "$WORK/pgb.ini" > "$WORK/pgb.log" 2>&1 & BOUNCER=$!
  # PgBouncer listening first (the shim may pull its image), then the direct collector stopped and seen gone, then the
  # pooled collector's own live lease (review #1); its asks must be taken by it alone (review #2)
  for _ in $(seq 1 180); do (exec 3<>"/dev/tcp/127.0.0.1/$BP") 2>/dev/null && break; kill -0 "$BOUNCER" 2>/dev/null || fail "P3: pgbouncer ended: $(tail -3 "$WORK/pgb.log")"; sleep 1; done
  (exec 3<>"/dev/tcp/127.0.0.1/$BP") 2>/dev/null || fail "P3: nothing listens on 127.0.0.1:$BP after 180 s: $(tail -3 "$WORK/pgb.log")"
  OLDW=$(rq "select coalesce(string_agg(quote_literal(collector_id), ','), quote_literal('')) from pgvigil.cq_workers")
  kill "$RUN1" 2>/dev/null; for _ in $(seq 1 30); do kill -0 "$RUN1" 2>/dev/null || break; sleep 1; done
  kill -0 "$RUN1" 2>/dev/null && fail "P3: the direct collector did not stop on TERM in 30 s"
  export CQ_COL_PGB="host=127.0.0.1 port=$BP user=cq_col password=$PW dbname=pgvigil"
  sed 's/env:CQ_COL$/env:CQ_COL_PGB/' "$WORK/col.yaml" > "$WORK/col-pgb.yaml"
  RUN1=$(startrun "$WORK/col-pgb.yaml" "$WORK/run-pgb.log")
  live=0; for _ in $(seq 1 60); do live=$(rq "select count(*) from pgvigil.cq_workers where beat_at > now() - interval '45 seconds' and collector_id not in ($OLDW) and 'cq-pg' = any(instances)"); [[ $live -ge 1 ]] && break; sleep 1; done
  [[ $live -ge 1 ]] || fail "P3: the collector behind pgbouncer holds no live lease: $(tail -5 "$WORK/run-pgb.log")"
  worst=0; P3IDS=""
  for k in $(seq 1 10); do
    id=$(ask community/run "{\"instance_id\":$PGID,\"tool\":\"pg_running\"}"); isid "$id"
    [[ $(waitreq "$id") == done ]] || fail "P3: ask $k behind pgbouncer: $(cat "$WORK/body"); $(tail -3 "$WORK/run-pgb.log")"
    P3IDS="${P3IDS:+$P3IDS,}$id"
    w=$(rq "select ceil(extract(epoch from taken_at - asked_at))::int from pgvigil.action_requests where request_id = $id")
    [[ $w =~ ^[0-9]+$ ]] || fail "P3: ask $k has no claim time: '$w'"
    [[ $w -gt $worst ]] && worst=$w
  done
  [[ $worst -le 6 ]] || fail "P3: a claim behind pgbouncer took $worst s (want the 5 s poll)"
  read -r p3n p3by <<<"$(rq "select count(*) filter (where taken_by not in ($OLDW)), count(distinct taken_by) from pgvigil.action_requests where request_id in ($P3IDS)" | tr '|' ' ')"
  [[ $p3n == 10 && $p3by == 1 ]] || fail "P3: $p3n of the 10 asks taken by a collector that started behind pgbouncer, $p3by taker(s) (want 10 by 1)"
  s=""
  if [[ -n "$MS" ]]; then s=$(cancel_running pgbouncer); [[ $s =~ ^[0-9]+$ && $s -le 10 ]] || fail "P3: a running cancel behind pgbouncer took '$s' s"
  else NOTPROVEN+=("P3's running cancel behind pgbouncer (it needs SQL Server's sp_WhoIsActive)"); fi
  ok "P3: behind pgbouncer (transaction mode) 10 asks done, each claimed within $worst s by the pooled collector alone${MS:+; a running cancel ended in ${s} s}"
else NOTPROVEN+=("P3: pgbouncer is not on this machine"); fi

for np in "${NOTPROVEN[@]}"; do echo "NOT PROVEN: $np"; done
echo "OK cq proof $N"
