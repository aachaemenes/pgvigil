#!/usr/bin/env bash
# The distributed availability group lab: does a distributed group form between two clusterless
# (CLUSTER_TYPE = NONE) availability groups of SQL Server on Linux containers? Four containers on one Docker network:
# d1a + d1b carry ag1 (database dagdb), d2a + d2b carry ag2 (no database: the distributed group seeds it); dag1 is the
# distributed group over ag1 and ag2, each side's LISTENER_URL the primary node's mirroring endpoint (there is no
# listener without a cluster). d2a and d2b get a database of their own first (dagpad, in no group), so dagdb's
# database id on the second group differs from its id on the first: what reads a distributed group's rows by
# database id is then proven against two different ids. Throwaway: no published port; every container and the network of the run removed on any
# exit, and only what this run made (a tag that is taken ends the run before anything is touched).
#
#   scripts/dag/trial.sh              form the lab, check it, remove it
#   KEEP=1 scripts/dag/trial.sh       form the lab and leave it up when it formed (scripts/proof-mssql-dag.sh builds on it)
#   scripts/dag/trial.sh down <tag>   remove the lab of that tag: a kept one, or what a killed run left behind
#
# Needs docker and openssl. From the environment, all optional:
#   PGVIGIL_MSSQL_IMAGE     the image (default mcr.microsoft.com/mssql/server:2022-latest; run on 16.0.4315 only: no other
#                           version is proven). Its sqlcmd is found per image: /opt/mssql-tools18 (with -C), else /opt/mssql-tools.
#   PGVIGIL_DAG_TAG         the lab's name (default pgvdag<8 hex digits>): the containers are <tag>-d1a ... <tag>-d2b, the
#                           network <tag>-net, both labelled pgvdag=<tag>.
#   PGVIGIL_DAG_SA          the sa password (default: random), so a caller that goes on with the lab holds it.
#   PGVIGIL_DAG_MEMORY_MB   MSSQL_MEMORY_LIMIT_MB of each node (default 2048).
# Passwords: none is printed and none is on a command line; the sa password reaches docker and sqlcmd through the
# environment, by name, the master key's and the endpoint logins' as sqlcmd variables from the environment. The sa
# password stays in the containers' configuration (docker inspect) for the life of the lab, as any MSSQL_SA_PASSWORD does.
#
# Expected (each line is checked, not only printed):
#   nodes     four servers answer, each @@SERVERNAME its node name with HADR enabled
#   trusts    a mirroring endpoint STARTED on each node; 12 CONNECT grants on the endpoints, counted on the servers
#   ag1       d1a sees ag1 with d1a PRIMARY and d1b a CONNECTED SECONDARY; dagdb SYNCHRONIZED and HEALTHY on d1b
#   ag2       d2a sees ag2 with d2a PRIMARY and d2b a CONNECTED SECONDARY, before the distributed group is made
#   dag1      CREATE on d1a and JOIN on d2a succeed; d1a lists dag1 with is_distributed = 1
#   seeded    dagdb arrives on d2a (the forwarder) and on d2b by automatic seeding, HEALTHY on both, under another
#             database id than on d1a
#   flow      a row written on d1a is read on d2b (through d1a -> d2a -> d2b) within 60 s
#   roles     d1a sees dag1 with ag1 PRIMARY and ag2 a CONNECTED SECONDARY; d2a sees dag1 with ag2 a CONNECTED SECONDARY
#   then the line 'DAG FORMED' (a caller greps it; the cleanup's line follows it) and exit 0.
# SQL Server refusing the distributed group (its CREATE, its JOIN, its seeding, its flow or its roles): the message,
# 'DAG REFUSED at <step>', exit 3. Anything else that fails is the lab's own: a line 'FAIL: ...', exit 1 - also when the
# cleanup leaves something behind.
set -Eeuo pipefail
NODES=(d1a d1b d2a d2b)

# down <tag>: every container and network labelled pgvdag=<tag>, and the volumes those containers mounted; reads back
# what is left and answers 1 when anything is
down() {
  local tag=$1 c v vols=() left_c left_n left_v=0
  for c in $(docker ps -a -q --filter "label=pgvdag=$tag"); do
    while read -r v; do [[ -n "$v" ]] && vols+=("$v"); done < <(docker inspect -f '{{range .Mounts}}{{if .Name}}{{println .Name}}{{end}}{{end}}' "$c" 2>/dev/null || true)
    docker rm -f -v "$c" >/dev/null 2>&1 || true
  done
  for c in $(docker network ls -q --filter "label=pgvdag=$tag"); do docker network rm "$c" >/dev/null 2>&1 || true; done
  for v in ${vols[@]+"${vols[@]}"}; do if docker volume inspect "$v" >/dev/null 2>&1; then left_v=$((left_v + 1)); fi; done
  left_c=$(docker ps -a -q --filter "label=pgvdag=$tag" | wc -l); left_n=$(docker network ls -q --filter "label=pgvdag=$tag" | wc -l)
  echo "cleanup of $tag: containers left $left_c, networks left $left_n, volumes left $left_v"
  [[ $left_c == 0 && $left_n == 0 && $left_v == 0 ]]
}
tag_ok() { [[ "$1" =~ ^[a-z][a-z0-9]{2,39}$ ]]; }

if [[ "${1:-}" == down ]]; then
  command -v docker >/dev/null || { echo "FAIL: docker is not on this machine"; exit 1; }
  tag_ok "${2:-}" || { echo "FAIL: down needs the lab's tag (a lower-case letter, then 2 to 39 letters or digits)"; exit 1; }
  if down "$2"; then exit 0; fi
  echo "FAIL: the lab $2 is not removed in full"; exit 1
fi
[[ $# == 0 ]] || { echo "FAIL: unknown argument '$1' (none, or: down <tag>)"; exit 1; }

for t in docker openssl; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine"; exit 1; }; done
IMG="${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}"
TAG="${PGVIGIL_DAG_TAG:-pgvdag$(openssl rand -hex 4)}"; NET="$TAG-net"
SA="${PGVIGIL_DAG_SA:-S$(openssl rand -hex 14)!a}"; KP="K$(openssl rand -hex 12)!a"; LP="L$(openssl rand -hex 12)!a"
tag_ok "$TAG" || { echo "FAIL: PGVIGIL_DAG_TAG is a lower-case letter, then 2 to 39 letters or digits"; exit 1; }
[[ "$SA" =~ ^[A-Za-z0-9!_-]{12,100}$ ]] || { echo "FAIL: PGVIGIL_DAG_SA is 12 to 100 letters, digits and ! _ - (it is masked in the output by a pattern)"; exit 1; }
OWN=0; CERTDIR=; SQLCMD=()
ct() { echo "$TAG-$1"; }
mask() { sed "s/$SA/<sa>/g; s/$KP/<key>/g; s/$LP/<login>/g"; }
cleanup() {
  local rc=$?
  trap - ERR; set +e
  [[ -n "$CERTDIR" ]] && rm -rf "$CERTDIR"
  [[ $OWN == 1 ]] || exit "$rc"          # nothing of this run exists: the tag was taken, or it ended before its network
  if [[ "${KEEP:-0}" == 1 && $rc == 0 ]]; then
    echo "KEEP=1: left up: ${NODES[*]/#/$TAG-} on $NET (remove with: scripts/dag/trial.sh down $TAG)"; exit 0
  fi
  down "$TAG" || { echo "FAIL: the cleanup left something of $TAG behind"; [[ $rc == 0 ]] && rc=1; }
  exit "$rc"
}
trap cleanup EXIT
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND"; exit 1' ERR
# Q <node> <sql>: one batch on a node as sa. Every password travels in the environment of the exec, by name; the batch
# names the master key's and the logins' as the sqlcmd variables $(KP) and $(LP)
Q() { SQLCMDPASSWORD="$SA" KP="$KP" LP="$LP" docker exec -e SQLCMDPASSWORD -e KP -e LP "$(ct "$1")" "${SQLCMD[@]}" -S localhost -U sa -b -h -1 -W -Q "SET NOCOUNT ON; $2"; }
# step <name> <node> <sql>: a batch whose refusal ends the trial with the server's own message
step() { local name=$1 node=$2 sql=$3 out
  if ! out=$(Q "$node" "$sql" 2>&1); then
    printf '%s\n' "$out" | mask || true
    if [[ "$name" == dag1* ]]; then echo "DAG REFUSED at $name"; exit 3; fi
    echo "FAIL: the lab's own step '$name' failed (not a refusal of the distributed group)"; exit 1
  fi
  if [[ -n "$out" ]]; then printf '%s\n' "$out" | mask || true; fi
  return 0; }
# RSTATE <group> <replica>: the batch that reads a replica's ROLE:CONNECTED_STATE from the node's own views
RSTATE() { echo "SELECT ISNULL((SELECT TOP 1 ISNULL(ars.role_desc, '-') + ':' + ISNULL(ars.connected_state_desc, '-') FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id WHERE ag.name = '$1' AND ar.replica_server_name = '$2'), 'none')"; }
# expect <node> <group> <replica> <ROLE:CONNECTED_STATE>: what the node says of a replica of a group, checked
expect() { local got
  got=$(Q "$1" "$(RSTATE "$2" "$3")" 2>/dev/null) || got=unread
  if [[ "$got" == "$4" ]]; then echo "  $1 sees $2 / $3 $got"; return 0; fi
  echo "  $1 sees $2 / $3 as $got, not $4"; return 1; }
# until_is <tries> <seconds> <node> <want> <sql>: the batch's one value, read until it is <want>; the last read in $GOT
until_is() { local tries=$1 pause=$2 node=$3 want=$4 sql=$5
  for _ in $(seq 1 "$tries"); do
    GOT=$(Q "$node" "$sql" 2>/dev/null) || GOT=unread
    if [[ "$GOT" == "$want" ]]; then return 0; fi
    sleep "$pause"
  done
  return 1; }

if [[ -n "$(docker ps -a -q --filter "label=pgvdag=$TAG")$(docker network ls -q --filter "label=pgvdag=$TAG")" ]] || docker network inspect "$NET" >/dev/null 2>&1; then
  echo "FAIL: the tag $TAG is taken (a container or a network of it exists); nothing was touched"; exit 1
fi
echo "== nodes: four $IMG containers on $NET, one at a time"
docker network create --label "pgvdag=$TAG" "$NET" >/dev/null; OWN=1
for n in "${NODES[@]}"; do
  MSSQL_SA_PASSWORD="$SA" docker run -d --name "$(ct "$n")" --hostname "$n" --network "$NET" --network-alias "$n" --label "pgvdag=$TAG" \
    -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD -e MSSQL_ENABLE_HADR=1 -e MSSQL_AGENT_ENABLED=true \
    -e MSSQL_MEMORY_LIMIT_MB="${PGVIGIL_DAG_MEMORY_MB:-2048}" "$IMG" >/dev/null
  up=0
  for _ in $(seq 1 120); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$(ct "$n")" 2>/dev/null || true)" != true ]]; then
      docker logs --tail 20 "$(ct "$n")" 2>&1 | mask || true
      echo "FAIL: $n stopped at its start"; exit 1
    fi
    if [[ ${#SQLCMD[@]} == 0 ]]; then
      if docker exec "$(ct "$n")" test -x /opt/mssql-tools18/bin/sqlcmd; then SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -C)
      elif docker exec "$(ct "$n")" test -x /opt/mssql-tools/bin/sqlcmd; then SQLCMD=(/opt/mssql-tools/bin/sqlcmd)
      else echo "FAIL: the image $IMG has no sqlcmd under /opt/mssql-tools18/bin or /opt/mssql-tools/bin"; exit 1; fi
    fi
    if Q "$n" "SELECT 1" >/dev/null 2>&1; then up=1; break; fi
    sleep 3
  done
  if [[ $up != 1 ]]; then docker logs --tail 20 "$(ct "$n")" 2>&1 | mask || true; echo "FAIL: $n did not answer in 360 s"; exit 1; fi
  id=$(Q "$n" "SELECT @@SERVERNAME + '|' + CAST(SERVERPROPERTY('IsHadrEnabled') AS varchar(5)) + '|' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))")
  [[ "$id" == "$n|1|"* ]] || { echo "FAIL: $n answers as '$id' (want @@SERVERNAME $n with HADR enabled: $n|1|<version>)"; exit 1; }
  echo "  $n hadr=1 ${id##*|}"
done

echo "== endpoints: a master key, a certificate and a mirroring endpoint on each node; every node trusts the other three"
CERTDIR=$(mktemp -d)
for n in "${NODES[@]}"; do
  step "endpoint $n" "$n" "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '\$(KP)';
CREATE CERTIFICATE ${n}_cert WITH SUBJECT = 'AG endpoint $n', EXPIRY_DATE = '2036-01-01';
CREATE ENDPOINT Hadr_endpoint STATE = STARTED AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL) FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE ${n}_cert, ENCRYPTION = REQUIRED ALGORITHM AES, ROLE = ALL);
BACKUP CERTIFICATE ${n}_cert TO FILE = '/var/opt/mssql/data/$n.cer';"
  docker cp "$(ct "$n"):/var/opt/mssql/data/$n.cer" "$CERTDIR/$n.cer"
done
for n in "${NODES[@]}"; do for o in "${NODES[@]}"; do if [[ $n == "$o" ]]; then continue; fi
  docker cp "$CERTDIR/$o.cer" "$(ct "$n"):/var/opt/mssql/data/$o.cer"; docker exec -u 0 "$(ct "$n")" chown mssql "/var/opt/mssql/data/$o.cer"
  step "trust $o on $n" "$n" "CREATE LOGIN ${o}_login WITH PASSWORD = '\$(LP)'; CREATE USER ${o}_user FOR LOGIN ${o}_login;
CREATE CERTIFICATE ${o}_cert AUTHORIZATION ${o}_user FROM FILE = '/var/opt/mssql/data/$o.cer'; GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO ${o}_login;"
done; done
rm -rf "$CERTDIR"; CERTDIR=
TRUSTS=0
for n in "${NODES[@]}"; do
  g=$(Q "$n" "SELECT CAST((SELECT COUNT(*) FROM sys.database_mirroring_endpoints WHERE name = 'Hadr_endpoint' AND state_desc = 'STARTED') AS varchar(5)) + '|' + CAST((SELECT COUNT(*) FROM sys.server_permissions p JOIN sys.endpoints e ON e.endpoint_id = p.major_id WHERE p.class = 105 AND e.name = 'Hadr_endpoint' AND p.permission_name = 'CONNECT' AND p.state = 'G' AND SUSER_NAME(p.grantee_principal_id) LIKE '%[_]login') AS varchar(5))")
  [[ "$g" == "1|$(( ${#NODES[@]} - 1 ))" ]] || { echo "FAIL: $n has endpoint started | CONNECT grants = $g (want 1|$(( ${#NODES[@]} - 1 )))"; exit 1; }
  TRUSTS=$((TRUSTS + ${g#*|}))
done
echo "  $TRUSTS endpoint trusts counted on the servers (${#NODES[@]} nodes, each trusts the other $(( ${#NODES[@]} - 1 )))"

REPL() { echo "N'$1' WITH (ENDPOINT_URL = 'TCP://$1:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))"; }
echo "== ag1 on d1a + d1b with dagdb"
# one batch each: a batch is compiled whole before it runs, so a statement cannot name a database the same batch creates
step "ag1 database: create" d1a "CREATE DATABASE dagdb;"
step "ag1 database: full recovery and a first backup" d1a "ALTER DATABASE dagdb SET RECOVERY FULL; BACKUP DATABASE dagdb TO DISK = '/var/opt/mssql/data/dagdb-seed.bak' WITH INIT;"
step "ag1 database: a table" d1a "CREATE TABLE dagdb.dbo.t (id int IDENTITY PRIMARY KEY, at datetime2 NOT NULL DEFAULT sysutcdatetime(), note varchar(60));"
step "ag1 create" d1a "CREATE AVAILABILITY GROUP ag1 WITH (CLUSTER_TYPE = NONE) FOR DATABASE dagdb REPLICA ON $(REPL d1a), $(REPL d1b);"
step "ag1 join" d1b "ALTER AVAILABILITY GROUP ag1 JOIN WITH (CLUSTER_TYPE = NONE); ALTER AVAILABILITY GROUP ag1 GRANT CREATE ANY DATABASE;"
echo "== ag2 on d2a + d2b, no database of the group (dagpad on each takes the database id dagdb has on d1a)"
step "ag2 filler database on d2a" d2a "CREATE DATABASE dagpad;"
step "ag2 filler database on d2b" d2b "CREATE DATABASE dagpad;"
step "ag2 create" d2a "CREATE AVAILABILITY GROUP ag2 WITH (CLUSTER_TYPE = NONE) FOR REPLICA ON $(REPL d2a), $(REPL d2b);"
step "ag2 join" d2b "ALTER AVAILABILITY GROUP ag2 JOIN WITH (CLUSTER_TYPE = NONE); ALTER AVAILABILITY GROUP ag2 GRANT CREATE ANY DATABASE;"
step "ag2 seeding right" d2a "ALTER AVAILABILITY GROUP ag2 GRANT CREATE ANY DATABASE;"
until_is 60 5 d1a "SYNCHRONIZED:HEALTHY" "SELECT ISNULL((SELECT TOP 1 drs.synchronization_state_desc + ':' + drs.synchronization_health_desc FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id WHERE ar.replica_server_name = 'd1b'), 'none')" \
  || { echo "FAIL: ag1 did not synchronize in 300 s (dagdb on d1b: $GOT)"; exit 1; }
echo "  ag1: dagdb on d1b $GOT"
until_is 60 5 d2a "SECONDARY:CONNECTED" "$(RSTATE ag2 d2b)" || { echo "FAIL: ag2 did not form in 300 s (d2b as d2a sees it: $GOT)"; exit 1; }
if ! { expect d1a ag1 d1a PRIMARY:CONNECTED && expect d1a ag1 d1b SECONDARY:CONNECTED && expect d2a ag2 d2a PRIMARY:CONNECTED && expect d2a ag2 d2b SECONDARY:CONNECTED; }; then
  echo "FAIL: ag1 or ag2 is not formed as the lab needs it (the distributed group was not tried)"; exit 1
fi

DSIDE() { echo "N'$1' WITH (LISTENER_URL = 'TCP://$2:5022', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC)"; }
echo "== dag1: the distributed group over ag1 and ag2"
step "dag1 create (d1a, the global primary)" d1a "CREATE AVAILABILITY GROUP dag1 WITH (DISTRIBUTED) AVAILABILITY GROUP ON $(DSIDE ag1 d1a), $(DSIDE ag2 d2a);"
step "dag1 join (d2a, the forwarder)" d2a "ALTER AVAILABILITY GROUP dag1 JOIN AVAILABILITY GROUP ON $(DSIDE ag1 d1a), $(DSIDE ag2 d2a);"
D=$(Q d1a "SELECT CAST(COUNT(*) AS varchar(5)) FROM sys.availability_groups WHERE name = 'dag1' AND is_distributed = 1")
[[ "$D" == 1 ]] || { echo "DAG REFUSED at dag1 catalog (no dag1 with is_distributed = 1 on d1a)"; exit 3; }

echo "== seeded: dagdb on the forwarder d2a and on d2b"
LOCALDB="SELECT ISNULL((SELECT TOP 1 synchronization_health_desc FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID('dagdb') AND is_local = 1), 'none')"
a=none; b=none; ok=0
for _ in $(seq 1 72); do
  a=$(Q d2a "$LOCALDB" 2>/dev/null) || a=unread
  b=$(Q d2b "$LOCALDB" 2>/dev/null) || b=unread
  if [[ "$a" == HEALTHY && "$b" == HEALTHY ]]; then ok=1; break; fi
  sleep 5
done
echo "  dagdb on d2a: $a; on d2b: $b"
if [[ $ok == 1 ]]; then
  ids="$(Q d1a "SELECT CAST(DB_ID('dagdb') AS varchar(10))")|$(Q d2a "SELECT CAST(DB_ID('dagdb') AS varchar(10))")|$(Q d2b "SELECT CAST(DB_ID('dagdb') AS varchar(10))")"
  echo "  dagdb's database id on d1a | d2a | d2b: $ids"
  [[ "${ids%%|*}" != "$(cut -d'|' -f2 <<<"$ids")" ]] || { echo "FAIL: dagdb has the same database id on d1a and on d2a (the filler database did not take it)"; exit 1; }
fi
if [[ $ok != 1 ]]; then
  Q d2a "SELECT TOP 5 'seeding d2a: ' + ISNULL(current_state, '-') + ' ' + ISNULL(failure_state_desc, '-') FROM sys.dm_hadr_automatic_seeding ORDER BY start_time DESC" || true
  Q d1a "SELECT TOP 5 'seeding d1a: ' + ISNULL(current_state, '-') + ' ' + ISNULL(failure_state_desc, '-') FROM sys.dm_hadr_automatic_seeding ORDER BY start_time DESC" || true
  echo "DAG REFUSED at seeding (dagdb not HEALTHY on the second group in 360 s)"; exit 3
fi

echo "== flow: a row written on d1a read on d2b"
step "write" d1a "INSERT dagdb.dbo.t (note) VALUES ('across the distributed group');"
until_is 30 2 d2b 1 "SELECT CAST(COUNT(*) AS varchar(5)) FROM dagdb.dbo.t WHERE note = 'across the distributed group'" \
  || { echo "DAG REFUSED at flow (the row did not reach d2b in 60 s; last read: $GOT)"; exit 3; }
echo "  the row is on d2b"

echo "== roles: the distributed group as its two primaries see it"
if ! { expect d1a dag1 ag1 PRIMARY:CONNECTED && expect d1a dag1 ag2 SECONDARY:CONNECTED && expect d2a dag1 ag2 SECONDARY:CONNECTED; }; then
  echo "DAG REFUSED at roles (dag1 is not ag1 PRIMARY over a connected ag2 SECONDARY)"; exit 3
fi
echo "== what each node shows for the distributed link"
LINK="SELECT ag.name + ' ' + ar.replica_server_name + ' ' + ISNULL(ars.role_desc, '-') + ' ' + ISNULL(ars.connected_state_desc, '-') + ' ' + ISNULL(ars.synchronization_health_desc, '-') + ' send_kb=' + ISNULL(CAST(drs.log_send_queue_size AS varchar(20)), '-') + ' redo_kb=' + ISNULL(CAST(drs.redo_queue_size AS varchar(20)), '-') FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ar.replica_id WHERE ag.is_distributed = 1 ORDER BY ar.replica_server_name"
for n in d1a d2a d2b; do
  out=$(Q "$n" "$LINK" 2>&1) || out="(not read)"
  if [[ -n "$out" ]]; then printf '%s\n' "$out" | sed "s/^/  $n: /"; else echo "  $n: lists no replica of a distributed group"; fi
done
echo "DAG FORMED"
