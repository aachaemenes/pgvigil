#!/usr/bin/env bash
# The distributed availability group lab, step 1: does a distributed group form between two clusterless
# (CLUSTER_TYPE = NONE) availability groups of SQL Server on Linux containers? Four containers on one Docker network:
# d1a + d1b carry ag1 (database dagdb), d2a + d2b carry ag2 (no database: the distributed group seeds it); dag1 is the
# distributed group over ag1 and ag2, each side's LISTENER_URL the primary node's mirroring endpoint (there is no
# listener without a cluster). Throwaway: a random sa password that is never printed, no published port, every
# container and the network removed on any exit (KEEP=1 leaves them up and prints their names: the proof builds on it).
# Needs docker and openssl. PGVIGIL_MSSQL_IMAGE names the image (default mcr.microsoft.com/mssql/server:2022-latest).
# Expected:
#   nodes     four servers answer, @@SERVERNAME d1a, d1b, d2a, d2b, HADR enabled on each
#   ag1       on d1a: ag1 with d1a PRIMARY and d1b SECONDARY, dagdb SYNCHRONIZED and HEALTHY on d1b
#   ag2       on d2a: ag2 with d2a PRIMARY and d2b SECONDARY, no database yet
#   dag1      CREATE on d1a and JOIN on d2a succeed; on d1a sys.availability_groups shows dag1 is_distributed = 1 with
#             the two "replicas" ag1 and ag2; d1a is PRIMARY of dag1 and d2a (the forwarder) SECONDARY
#   seeded    dagdb arrives on d2a (the forwarder) and on d2b by automatic seeding, HEALTHY on both
#   flow      a row written on d1a is read on d2b (through d1a -> d2a -> d2b) within 60 s
#   last line 'DAG FORMED' and exit 0. SQL Server refusing the distributed group (its CREATE, its JOIN, its seeding or
#   its flow): the message, 'DAG REFUSED at <step>', exit 3. A failure of the lab's own preparation: 'FAIL: ...', exit 1.
set -euo pipefail
IMG="${PGVIGIL_MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}"
TAG="pgvdag$RANDOM"; NET="$TAG-net"; NODES=(d1a d1b d2a d2b)
SA="S$(openssl rand -hex 14)!a"; KP="K$(openssl rand -hex 12)!a"; LP="L$(openssl rand -hex 12)!a"
ct() { echo "$TAG-$1"; }
cleanup() {
  if [[ "${KEEP:-0}" == 1 ]]; then echo "KEEP=1: left up: ${NODES[*]/#/$TAG-} on $NET"; return; fi
  for n in "${NODES[@]}"; do docker rm -f -v "$(ct "$n")" >/dev/null 2>&1 || true; done
  docker network rm "$NET" >/dev/null 2>&1 || true
  left=$(docker ps -a --filter "label=pgvdag=$TAG" -q | wc -l)
  echo "cleanup: containers left $left"
}
trap cleanup EXIT
for t in docker openssl; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine"; exit 1; }; done
# Q <node> <sql>: one batch on a node as sa; the password travels in the environment of the exec, never on sqlcmd's line
Q() { docker exec -e SQLCMDPASSWORD="$SA" "$(ct "$1")" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W -Q "SET NOCOUNT ON; $2"; }
# step <name> <node> <sql>: a batch whose refusal ends the trial with the server's own message
step() { local name=$1 node=$2 sql=$3 out
  if ! out=$(Q "$node" "$sql" 2>&1); then
    echo "$out" | sed "s/$SA/<sa>/g; s/$KP/<key>/g; s/$LP/<login>/g"
    if [[ "$name" == dag1* ]]; then echo "DAG REFUSED at $name"; exit 3; fi
    echo "FAIL: the lab's own step '$name' failed (not a refusal of the distributed group)"; exit 1
  fi
  [[ -n "$out" ]] && echo "$out"; return 0; }

echo "== nodes: four $IMG containers on $NET, one at a time"
docker network create "$NET" >/dev/null
for n in "${NODES[@]}"; do
  docker run -d --name "$(ct "$n")" --hostname "$n" --network "$NET" --network-alias "$n" --label "pgvdag=$TAG" \
    -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD="$SA" -e MSSQL_ENABLE_HADR=1 -e MSSQL_AGENT_ENABLED=true \
    -e MSSQL_MEMORY_LIMIT_MB=2048 "$IMG" >/dev/null
  up=0
  for _ in $(seq 1 120); do
    if Q "$n" "SELECT 1" >/dev/null 2>&1; then up=1; break; fi
    docker inspect -f '{{.State.Running}}' "$(ct "$n")" 2>/dev/null | grep -q true || { docker logs --tail 20 "$(ct "$n")" 2>&1 | sed "s/$SA/<sa>/g"; echo "FAIL: $n stopped at its start"; exit 1; }
    sleep 3
  done
  [[ $up == 1 ]] || { docker logs --tail 20 "$(ct "$n")" 2>&1 | sed "s/$SA/<sa>/g"; echo "FAIL: $n did not answer in 360 s"; exit 1; }
  echo "  $(Q "$n" "SELECT @@SERVERNAME + ' hadr=' + CAST(SERVERPROPERTY('IsHadrEnabled') AS varchar(5)) + ' ' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(30))")"
done

echo "== endpoints: a master key, a certificate and a mirroring endpoint on each node; every node trusts the other three"
for n in "${NODES[@]}"; do
  step "endpoint $n" "$n" "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$KP';
CREATE CERTIFICATE ${n}_cert WITH SUBJECT = 'AG endpoint $n', EXPIRY_DATE = '2036-01-01';
CREATE ENDPOINT Hadr_endpoint STATE = STARTED AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL) FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE ${n}_cert, ENCRYPTION = REQUIRED ALGORITHM AES, ROLE = ALL);
BACKUP CERTIFICATE ${n}_cert TO FILE = '/var/opt/mssql/data/$n.cer';"
  docker cp "$(ct "$n"):/var/opt/mssql/data/$n.cer" "/tmp/$TAG-$n.cer"
done
for n in "${NODES[@]}"; do for o in "${NODES[@]}"; do [[ $n == "$o" ]] && continue
  docker cp "/tmp/$TAG-$o.cer" "$(ct "$n"):/var/opt/mssql/data/$o.cer"; docker exec -u 0 "$(ct "$n")" chown mssql "/var/opt/mssql/data/$o.cer"
  step "trust $o on $n" "$n" "CREATE LOGIN ${o}_login WITH PASSWORD = '$LP'; CREATE USER ${o}_user FOR LOGIN ${o}_login;
CREATE CERTIFICATE ${o}_cert AUTHORIZATION ${o}_user FROM FILE = '/var/opt/mssql/data/$o.cer'; GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO ${o}_login;"
done; done
rm -f /tmp/$TAG-*.cer
echo "  16 endpoint trusts made (4 nodes, each the other 3 and its own certificate)"

REPL() { echo "N'$1' WITH (ENDPOINT_URL = 'TCP://$1:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))"; }
echo "== ag1 on d1a + d1b with dagdb"
# one batch each: a batch is compiled whole before it runs, so a statement cannot name a database the same batch creates
step "ag1 database: create" d1a "CREATE DATABASE dagdb;"
step "ag1 database: full recovery and a first backup" d1a "ALTER DATABASE dagdb SET RECOVERY FULL; BACKUP DATABASE dagdb TO DISK = '/var/opt/mssql/data/dagdb-seed.bak' WITH INIT;"
step "ag1 database: a table" d1a "CREATE TABLE dagdb.dbo.t (id int IDENTITY PRIMARY KEY, at datetime2 NOT NULL DEFAULT sysutcdatetime(), note varchar(60));"
step "ag1 create" d1a "CREATE AVAILABILITY GROUP ag1 WITH (CLUSTER_TYPE = NONE) FOR DATABASE dagdb REPLICA ON $(REPL d1a), $(REPL d1b);"
step "ag1 join" d1b "ALTER AVAILABILITY GROUP ag1 JOIN WITH (CLUSTER_TYPE = NONE); ALTER AVAILABILITY GROUP ag1 GRANT CREATE ANY DATABASE;"
echo "== ag2 on d2a + d2b, no database"
step "ag2 create" d2a "CREATE AVAILABILITY GROUP ag2 WITH (CLUSTER_TYPE = NONE) FOR REPLICA ON $(REPL d2a), $(REPL d2b);"
step "ag2 join" d2b "ALTER AVAILABILITY GROUP ag2 JOIN WITH (CLUSTER_TYPE = NONE); ALTER AVAILABILITY GROUP ag2 GRANT CREATE ANY DATABASE;"
step "ag2 seeding right" d2a "ALTER AVAILABILITY GROUP ag2 GRANT CREATE ANY DATABASE;"
ok=0
for _ in $(seq 1 60); do
  s=$(Q d1a "SELECT ISNULL((SELECT TOP 1 drs.synchronization_state_desc + ':' + drs.synchronization_health_desc FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id WHERE ar.replica_server_name = 'd1b'), 'none')")
  [[ "$s" == "SYNCHRONIZED:HEALTHY" ]] && { ok=1; break; }; sleep 5
done
echo "  ag1: dagdb on d1b $s"; [[ $ok == 1 ]] || { echo "FAIL: ag1 did not synchronize in 300 s"; exit 1; }
ROLES="SELECT ag.name + ' ' + ar.replica_server_name + ' ' + ISNULL(ars.role_desc, '-') + ' distributed=' + CAST(ag.is_distributed AS varchar(1)) + ' ' + ag.cluster_type_desc FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id ORDER BY ag.name, ar.replica_server_name"
Q d1a "$ROLES" | sed 's/^/  d1a sees: /'; Q d2a "$ROLES" | sed 's/^/  d2a sees: /'

DSIDE() { echo "N'$1' WITH (LISTENER_URL = 'TCP://$2:5022', AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC)"; }
echo "== dag1: the distributed group over ag1 and ag2"
step "dag1 create (d1a, the global primary)" d1a "CREATE AVAILABILITY GROUP dag1 WITH (DISTRIBUTED) AVAILABILITY GROUP ON $(DSIDE ag1 d1a), $(DSIDE ag2 d2a);"
step "dag1 join (d2a, the forwarder)" d2a "ALTER AVAILABILITY GROUP dag1 JOIN AVAILABILITY GROUP ON $(DSIDE ag1 d1a), $(DSIDE ag2 d2a);"
Q d1a "$ROLES" | sed 's/^/  d1a sees: /'; Q d2a "$ROLES" | sed 's/^/  d2a sees: /'
D=$(Q d1a "SELECT CAST(COUNT(*) AS varchar(5)) FROM sys.availability_groups WHERE name = 'dag1' AND is_distributed = 1")
[[ "$D" == 1 ]] || { echo "DAG REFUSED at dag1 catalog (no dag1 with is_distributed = 1 on d1a)"; exit 3; }

echo "== seeded: dagdb on the forwarder d2a and on d2b"
ok=0
for _ in $(seq 1 72); do
  a=$(Q d2a "SELECT ISNULL((SELECT TOP 1 synchronization_health_desc FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID('dagdb') AND is_local = 1), 'none')")
  b=$(Q d2b "SELECT ISNULL((SELECT TOP 1 synchronization_health_desc FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID('dagdb') AND is_local = 1), 'none')")
  [[ "$a" == HEALTHY && "$b" == HEALTHY ]] && { ok=1; break; }; sleep 5
done
echo "  dagdb on d2a: $a; on d2b: $b"
if [[ $ok != 1 ]]; then
  Q d2a "SELECT TOP 5 'seeding d2a: ' + ISNULL(current_state, '-') + ' ' + ISNULL(failure_state_desc, '-') FROM sys.dm_hadr_automatic_seeding ORDER BY start_time DESC" || true
  Q d1a "SELECT TOP 5 'seeding d1a: ' + ISNULL(current_state, '-') + ' ' + ISNULL(failure_state_desc, '-') FROM sys.dm_hadr_automatic_seeding ORDER BY start_time DESC" || true
  echo "DAG REFUSED at seeding (dagdb not HEALTHY on the second group in 360 s)"; exit 3
fi

echo "== flow: a row written on d1a read on d2b"
step "write" d1a "INSERT dagdb.dbo.t (note) VALUES ('across the distributed group');"
ok=0
for _ in $(seq 1 30); do
  r=$(Q d2b "SELECT CAST(COUNT(*) AS varchar(5)) FROM dagdb.dbo.t WHERE note = 'across the distributed group'" 2>/dev/null || echo 0)
  [[ "$r" == 1 ]] && { ok=1; break; }; sleep 2
done
[[ $ok == 1 ]] || { echo "DAG REFUSED at flow (the row did not reach d2b in 60 s; last read: $r)"; exit 3; }
echo "  the row is on d2b"
echo "== what each node shows for the distributed link"
LINK="SELECT ag.name + ' ' + ar.replica_server_name + ' ' + ISNULL(ars.role_desc, '-') + ' ' + ISNULL(ars.connected_state_desc, '-') + ' ' + ISNULL(ars.synchronization_health_desc, '-') + ' send_kb=' + ISNULL(CAST(drs.log_send_queue_size AS varchar(20)), '-') + ' redo_kb=' + ISNULL(CAST(drs.redo_queue_size AS varchar(20)), '-') FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ar.replica_id WHERE ag.is_distributed = 1 ORDER BY ar.replica_server_name"
for n in d1a d2a d2b; do Q "$n" "$LINK" | sed "s/^/  $n: /"; done
echo "DAG FORMED"
