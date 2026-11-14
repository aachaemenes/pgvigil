#!/usr/bin/env bash
# Proof of task 376: the rolechange collection's Patroni read (internal/collect/patroni.go), migration 0144 and the Patroni parts of
# /api/pg/state, /api/pg/replication and /api/overview, on a REAL Patroni cluster.
#
#   PG             the PostgreSQL major of the members (default 17); the proof builds the image
#                  pgvigil-proof-patroni:<PG> once (postgres:<PG> plus PGDG's packages patroni and python3-etcd,
#                  openssl) and keeps it.
#   ETCD_IMG       the DCS (default gcr.io/etcd-development/etcd:v3.5.17).
#   PGVIGIL_BIN    a pgvigil binary; default: the proof builds one into its temp folder (go build, the tree as it is).
#   Needs: docker, psql, curl, python3; go without PGVIGIL_BIN (and for part U).
# The proof's own docker network (a /24 it picks that no other network holds), one etcd (named, not addressed: a
# stopped etcd's name fails at once in docker's DNS, its address only after ARP gives up), three Patroni members pat1,
# pat2, pat3 (scope pvp) on fixed addresses the box reaches directly, and a repository server on a 127.0.0.1 port the
# system hands out. pgvigil monitors each member as an instance (pv-pat1..3, tag proofpat) through its address, port
# 5432, as a pg_monitor-only login. Everything is removed with its volumes at the end, and that is read back (Z).
# Nothing that existed before the run is touched.
#
# Expected (written before the first run; times are the proof's own waits, 'collect' = pgvigil collect -once rolechange):
#  A. a healthy cluster, the default endpoint (http://<member>:8008, read because Patroni's sessions are connected).
#     collect pv-pat1, pv-pat2, pv-pat3 (in that order: their instance ids rise). pv-pat1's pg_patroni_read: ok true,
#     cluster_ok true, configured false, scope pvp, members 3, leader pat1, paused false, system_identifier = pat1's
#     pg_control_system(). pg_patroni_members of pv-pat1: 3 present - pat1 leader running, pat2 and pat3 replica
#     streaming with a lag_bytes number; each api_ok true, version 4.x, pending_restart false, failsafe_active false,
#     dcs_last_seen within 60 s of the read. pg_patroni_clusters: one row for pvp, judged by pv-pat1, read_by 3.
#     pg_patroni_checks for pvp: none. The same read's role row: pg_role_state of pv-pat1 is_replica false.
#  B. a pending restart: patronictl edit-config max_connections 100 -> 120; once /cluster says pending, collect
#     pv-pat1: the 3 members pending_restart true, reason 'max_connections 100 -> 120'; no check (30 min default).
#     The tag proofpat's patroni_pending_restart at warn 0: collect: 3 'patroni pending restart' warning rows (pat1,
#     pat2, pat3), detail naming 'max_connections 100 -> 120'. patronictl restart (all members); once no member is
#     pending, collect: pending_restart false on the 3, no row. The tag row inherited (ended).
#  C. paused: patronictl pause --wait; collect pv-pat1: paused true, paused_since set; each member's own paused true.
#     No check at the default (15 min). The tag's patroni_paused at crit 0: collect: one 'patroni paused' critical row,
#     object pvp. The tag row inherited.
#  D. a member's PostgreSQL stopped while paused (pg_ctl stop on pat3; Patroni keeps it stopped): once /cluster lists
#     pat3 'stopped', collect pv-pat1: pat3 present, state stopped, lag_text unknown, down_reason 'state stopped',
#     down_since this read; no 'patroni member down' yet (age 0 under the 1-minute default). 55 s later collect again:
#     one 'patroni member down' critical row, object pat3, detail 'Patroni lists it stopped since ...'.
#  E. no leader: still paused, pat1's container stopped (Patroni and PostgreSQL with it). Once pat2's /cluster has no
#     leader and no pat1 (its key expires: ttl 30 s), collect pv-pat2; then wait until pv-pat1's last read is 125 s
#     older than now (the judge hands over after 120 s) and at least 55 s after the first, collect pv-pat2 again:
#     pg_patroni_clusters judged by pv-pat2; pv-pat2's read leader NULL, no_leader_since its first read; checks on
#     pv-pat2: 'patroni no leader' critical, object pvp, detail naming the pause; 'patroni member down' critical for
#     pat1 ('gone from the cluster ... last seen as leader') and for pat3 (stopped); 'patroni paused' NOT (the default
#     15 min; part C's tag row ended). /api/overview holds the 'patroni no leader' row under check_group 'patroni';
#     /api/pg/state?instance=pv-pat2 its parts 'patroni' (pat1 listed down) and 'patroni_checks' (the 3 rows);
#     /api/pg/replication's 'patroni' part marks pv-pat2 judges true.
#  F. resumed: patronictl resume; once a leader is elected and pat2 and pat3 serve, collect pv-pat2: leader set,
#     no_leader_since NULL, paused false; no 'no leader', 'paused' or pat3 row; 'patroni member down' for pat1 only.
#     pat1's container started: once /cluster lists pat1 streaming, collect pv-pat2, pv-pat1, pv-pat3: no check row
#     for pvp at all; pv-pat1 judges again (the lowest id).
#  G. the DCS down (failsafe_mode is on in the cluster's settings) - run LAST, after U (PATRONI_G=0 skips it); attempt 4
#     after the 10:4x diagnosis (a member that rejoined 2 s before the outage was outside the leader's failsafe list and
#     said failsafe false, truthfully). The members' REST API back on http 8008 first. (1) The leader's GET /failsafe
#     (Patroni 4.1.5 api.py L832-846: {member: its /patroni url}, from the leader's DCS cache) waited for, 120 s at most,
#     until it names pat1, pat2 and pat3 at http 8008; on the timeout: 'G: not proven: the leader's failsafe topology
#     never held all members (<what it held>)' and the proof goes on. (2) The tag's patroni_dcs_last_seen at warn 0.25
#     min; etcd stopped; the leader's own /patroni failsafe_mode_is_active true waited for (120 s). (3) collect pv-pat1,
#     pv-pat2, each followed at once by that member's own /patroni: each read ok true, cluster_ok false, message
#     starting '/cluster:', members 1, the leader still the one read before; each own member row present with
#     failsafe_active EQUAL to its /patroni's failsafe_mode_is_active, dcs_last_seen older than the read; no down_since
#     on any member of pv-pat1 or pv-pat2; 'patroni DCS not reached' warning rows for pat1 and pat2 (their contact 15 s
#     old or more), the words 'failsafe mode keeps the leader running' on a row exactly when that member's row says
#     failsafe_active; no other check of the cluster. etcd started; once /cluster answers, collect pv-pat1:
#     cluster_ok true, members 3; the tag row inherited; collect: no check on pv-pat1.
#  H. another port and TLS. A CA, a server certificate for the three addresses and a client certificate made with
#     openssl. The members' REST API moved to https on 8009 (restapi certfile / keyfile / cafile, verify_client
#     optional, authentication set: Patroni's GETs need none), Patroni reloaded (SIGHUP): once https://pat1:8009
#     answers, collect:
#       pv-pat1 (default endpoint): ok false, message 'connection refused'; a second read 55 s on: 'patroni API not
#       answering' warning on pv-pat1;
#       pv-fresh (pat1, no patroni: block, never read before): ok false; pg_patroni_findings one info row 'patroni API
#       not found'; no check row;
#       pv-tls (url https://pat1:8009, ca_file): ok true, cluster_ok true, members 3, every member api_ok true (each
#       member's https api_url read with the CA);
#       pv-tlshttp (url http://pat1:8009): message 'the endpoint answers in TLS: name it https:// ...';
#       pv-noca (url https://pat1:8009, no ca_file): message naming a CA the collector does not trust.
#     verify_client required (reloaded): pv-tls: message 'the endpoint asks for a client certificate ...';
#     pv-mtls (ca_file, cert_file, key_file): ok true, members 3, every api_ok true.
#  S. the rules on seeded rows (import_patroni called directly, instances of their own, the times around now()):
#     s1 a leader, then none at -70 s and now: 'patroni no leader' critical; the first no-leader read alone: none
#     s2 a member listed at -140 s, gone at -70 s and now: 'patroni member down' critical, 'gone from the cluster'
#     s3 a read of the endpoint's own member only (cluster_ok false) after a full read: the leader kept, the others not
#        present, no down_since on them, no check
#     s4 two failed reads 70 s apart after a good one: 'patroni API not answering' warning, no member present (0103's
#        rule, its S12); never good and not configured: no check, one info finding 'patroni API not found'
#     s5 '[]' (no Patroni any more): the read row gone, no member present, no check
#     s6 a pending restart read three times: pending_restart_since stays the first read's; false: NULL
#     s7 two instances reading one cluster with a member down: the check once, on the lower instance id
#     s8 import_rolechange with a role row and Patroni rows: the Patroni rows stored (handed to import_patroni); the
#        next role read without them: the read row gone
#     s10 two instances of one cluster, the lower id reading only its own member (cut from the DCS), the higher one
#        listing m2 stopped twice 70 s apart: 'patroni member down' m2 on the higher id, nothing on the lower
#     s9 a member present at a read 8 days ago, missing from a good read: not present, no down_since, no 'patroni
#        member down'
#  U. the Go cases on a copy of the tree (go test): the endpoint's url rules, the pending-restart reason's text, a
#     read of recorded Patroni 4.1.5 answers (members, pause, a stopped member, lag 'unknown', dcs_last_seen; each
#     api_url asked at <host:port>/patroni whatever path it holds), a member whose address answers for another member, /cluster hanging past 3 s (the endpoint's own /patroni read instead), a TLS endpoint
#     asked over http and a plain one over https, an unknown CA; config's patroni: block rules.
#  Z. every container, the network and the image's run left nothing: 0 containers of this proof.
set -euo pipefail
PG=${PG:-17}
ETCD_IMG=${ETCD_IMG:-gcr.io/etcd-development/etcd:v3.5.17}
IMG=pgvigil-proof-patroni:$PG
WORK=$(mktemp -d); SUF=$(basename "$WORK" | tr -dc 'a-z0-9' | tail -c 8)
NET=pvp-$SUF; ETCD_CT=pvp-$SUF-etcd; REPO_CT=pvp-$SUF-repo
SUPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))'); REPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
MON=pgvpat; MONPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
REPO_DB=pgvigil_376_$SUF
CIDS=(); SRVPID=""; NETMADE=""
rc=0
cleanup() {
  local st=$?
  set +e
  # a command that failed outside fail() (set -e) is a failure too
  [[ $rc -eq 0 && $st -ne 0 ]] && { echo "FAIL: exit $st outside a check" >&2; rc=$st; }
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null
  for c in "${CIDS[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1; done
  [[ -n "$NETMADE" ]] && docker network rm "$NET" >/dev/null 2>&1
  local left=0
  for c in "${CIDS[@]}"; do docker inspect "$c" >/dev/null 2>&1 && left=$((left + 1)); done
  [[ -n "$NETMADE" ]] && docker network inspect "$NET" >/dev/null 2>&1 && left=$((left + 1))
  echo "Z: containers and networks of this proof left: $left"
  [[ $left -eq 0 ]] || { echo "FAIL: Z: $left left" >&2; rc=1; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; rc=1; exit 1; }
ok() { echo "  OK $*"; }
for t in docker psql curl python3; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
echo "proof-patroni: PostgreSQL $PG, $ETCD_IMG; load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPUs"

BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN is not set"
  BIN=$WORK/pgvigil
  CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil || fail "go build"
fi
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  docker build -q -t "$IMG" - >/dev/null <<EOF || fail "the image did not build (postgres:$PG plus patroni and python3-etcd from PGDG)"
FROM postgres:$PG
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends patroni python3-etcd openssl >/dev/null && rm -rf /var/lib/apt/lists/*
EOF
fi
PATRONI_V=$(docker run --rm "$IMG" patroni --version 2>/dev/null | awk '{print $2}')
echo "Patroni $PATRONI_V"

# the network: a /24 no other docker network holds, the members on fixed addresses (their certificate names them)
for _ in $(seq 1 8); do
  SUB=10.$((RANDOM % 200 + 30)).$((RANDOM % 250 + 1))
  docker network create --subnet "$SUB.0/24" "$NET" >/dev/null 2>&1 && { NETMADE=1; break; }
done
[[ -n "$NETMADE" ]] || fail "no free /24 for the proof's network"
EIP=$SUB.10; IP1=$SUB.11; IP2=$SUB.12; IP3=$SUB.13
ipof() { case $1 in pat1) echo "$IP1";; pat2) echo "$IP2";; pat3) echo "$IP3";; esac; }

# certificates: a CA, a server certificate for the three addresses, a client certificate (part H)
CERTS=$WORK/certs; mkdir -p "$CERTS"
# (the extensions a strict X509 check asks for - a CA with keyUsage, leaves with their key ids and purpose: Patroni's
# TLS server verifies the client certificate that way on the image's Python; checked with openssl verify -x509_strict)
docker run --rm -u "$(id -u):$(id -g)" -v "$CERTS:/c" -w /c -e HOME=/c "$IMG" sh -c "
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=pvp-ca -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout ca.key -out ca.pem 2>/dev/null &&
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' > leaf.ext &&
  { cat leaf.ext; printf 'extendedKeyUsage=serverAuth\nsubjectAltName=IP:$IP1,IP:$IP2,IP:$IP3\n'; } > server.ext &&
  { cat leaf.ext; printf 'extendedKeyUsage=clientAuth\n'; } > client.ext &&
  openssl req -newkey rsa:2048 -nodes -subj /CN=pvp-api -keyout server.key -out server.csr 2>/dev/null &&
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile server.ext -out server.pem 2>/dev/null &&
  openssl req -newkey rsa:2048 -nodes -subj /CN=pgvigil -keyout client.key -out client.csr 2>/dev/null &&
  openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile client.ext -out client.pem 2>/dev/null &&
  openssl verify -x509_strict -purpose sslserver -CAfile ca.pem server.pem >/dev/null &&
  openssl verify -x509_strict -purpose sslclient -CAfile ca.pem client.pem >/dev/null &&
  chmod 644 *.key" || fail "the certificates"
echo "Python on the members: $(docker run --rm "$IMG" python3 --version 2>&1)"

# Patroni's configuration: one template per REST API shape; the member's name and address filled in at its start. They
# sit in $WORK/p, readable by the members' postgres user ($WORK itself is mktemp's 0700)
TP=$WORK/p; mkdir -p "$TP"; chmod 755 "$TP"
tmpl() {   # <file> <restapi block>
  cat > "$TP/$1" <<EOF
scope: pvp
namespace: /pvp-$SUF/
name: NAME
restapi:
$2
etcd3:
  hosts: $ETCD_CT:2379
bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    failsafe_mode: true
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 100
        wal_log_hints: 'on'
  initdb: [{encoding: UTF8}]
  pg_hba:
    - local all all trust
    - host replication replicator 0.0.0.0/0 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256
postgresql:
  listen: 0.0.0.0:5432
  connect_address: IP:5432
  data_dir: /var/lib/postgresql/pat
  bin_dir: /usr/lib/postgresql/$PG/bin
  pgpass: /tmp/pgpass
  authentication:
    superuser: {username: postgres, password: $SUPW}
    replication: {username: replicator, password: $REPW}
    rewind: {username: postgres, password: $SUPW}
  parameters:
    unix_socket_directories: /var/run/postgresql
EOF
  chmod 644 "$TP/$1"
}
tmpl plain.yml "  listen: 0.0.0.0:8008
  connect_address: IP:8008"
TLSBLOCK="  listen: 0.0.0.0:8009
  connect_address: IP:8009
  certfile: /certs/server.pem
  keyfile: /certs/server.key
  cafile: /certs/ca.pem
  authentication: {username: pvadmin, password: $REPW}"
tmpl tls-optional.yml "$TLSBLOCK
  verify_client: optional"
tmpl tls-required.yml "$TLSBLOCK
  verify_client: required"
docker run -d --name "$ETCD_CT" --network "$NET" --ip "$EIP" "$ETCD_IMG" etcd --name e1 --data-dir /tmp/e \
  --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls "http://$ETCD_CT:2379" --listen-peer-urls http://0.0.0.0:2380 \
  --initial-advertise-peer-urls "http://$ETCD_CT:2380" --initial-cluster "e1=http://$ETCD_CT:2380" > "$WORK/etcd.id" || fail "etcd did not start"
CIDS+=("$(cat "$WORK/etcd.id")")
member() {   # <n>: start pat<n> on the plain template (its config re-made from /p/current.yml at every start)
  docker run -d --name "pvp-$SUF-pat$1" --hostname "pat$1" --network "$NET" --ip "$(ipof "pat$1")" -u postgres \
    -v "$TP:/p:ro" -v "$CERTS:/certs:ro" -e TMPL=plain.yml --entrypoint bash "$IMG" \
    -c "t=\$(cat /tmp/tmpl 2>/dev/null || echo \$TMPL); sed -e s/NAME/pat$1/ -e s/IP/\$(hostname -i)/g /p/\$t > /tmp/p.yml; exec patroni /tmp/p.yml" > "$WORK/pat$1.id" \
    || fail "pat$1 did not start"
  CIDS+=("$(cat "$WORK/pat$1.id")")
}
ct() { echo "pvp-$SUF-$1"; }
api() { curl -s -m 3 "http://$(ipof "$1"):8008/$2"; }
jq_() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
$1"; }
waitfor() {   # <seconds> <what> <command...>: poll every 2 s; on a timeout each member's last log lines
  local s=$1 what=$2; shift 2
  for _ in $(seq 1 $((s / 2))); do "$@" && return 0; sleep 2; done
  for n in 1 2 3; do docker logs --tail 8 "pvp-$SUF-pat$n" 2>&1 | sed "s/^/  pat$n: /" >&2; done
  fail "waited $s s for $what"
}
ctl() { docker exec "$(ct "$1")" patronictl -c /tmp/p.yml "${@:2}"; }

member 1
waitfor 120 "pat1 to lead" sh -c "curl -s -m 3 http://$IP1:8008/cluster | grep -q '\"leader\"'"
member 2; member 3
streaming3() { [[ $(api pat1 cluster | jq_ "print(sum(1 for m in d['members'] if m['state'] == 'streaming'))") == 2 ]]; }
waitfor 180 "pat2 and pat3 to stream" streaming3
docker exec "$(ct pat1)" psql -h /var/run/postgresql -U postgres -XAtqc "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null || fail "the monitoring login"
SYSID=$(docker exec "$(ct pat1)" psql -h /var/run/postgresql -U postgres -XAtqc "select system_identifier from pg_control_system()")

docker run -d --name "$REPO_CT" -e POSTGRES_PASSWORD="$SUPW" -p "127.0.0.1:0:5432" "postgres:$PG" > "$WORK/repo.id" || fail "the repository container did not start"
CIDS+=("$(cat "$WORK/repo.id")")
RPORT=$(docker port "$REPO_CT" 5432/tcp | head -1 | sed 's/.*://')
RSU="host=127.0.0.1 port=$RPORT user=postgres password=$SUPW dbname=postgres sslmode=disable"
for _ in $(seq 1 60); do psql "$RSU" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
psql "$RSU" -XAtq -c "create database $REPO_DB" >/dev/null || fail "the repository database"
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$RPORT user=postgres password=$SUPW dbname=$REPO_DB sslmode=disable"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
for n in 1 2 3; do export "PAT${n}_DSN=host=$(ipof "pat$n") port=5432 user=$MON password=$MONPW dbname=postgres sslmode=disable connect_timeout=5"; done
CFG=$WORK/pgvigil.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: pv-pat1
    dsn: env:PAT1_DSN
    tags: [proofpat]
  - name: pv-pat2
    dsn: env:PAT2_DSN
    tags: [proofpat]
  - name: pv-pat3
    dsn: env:PAT3_DSN
    tags: [proofpat]
  - name: pv-fresh
    dsn: env:PAT1_DSN
    tags: [proofpat]
  - name: pv-tls
    dsn: env:PAT1_DSN
    tags: [proofpat]
    patroni: {url: "https://$IP1:8009", ca_file: $CERTS/ca.pem}
  - name: pv-tlshttp
    dsn: env:PAT1_DSN
    tags: [proofpat]
    patroni: {url: "http://$IP1:8009/cluster"}
  - name: pv-noca
    dsn: env:PAT1_DSN
    tags: [proofpat]
    patroni: {url: "https://$IP1:8009"}
  - name: pv-mtls
    dsn: env:PAT1_DSN
    tags: [proofpat]
    patroni: {url: "https://$IP1:8009", ca_file: $CERTS/ca.pem, cert_file: $CERTS/client.pem, key_file: $CERTS/client.key}
EOF
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
collect() {   # <instance> [collection]
  local out; out=$("$BIN" collect -config "$CFG" -instance "$1" -once "${2:-rolechange}" 2>&1) || { echo "$out" >&2; fail "collect ${2:-rolechange} on $1"; }
}
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
thr() { q "select pgvigil.import_pg_threshold(now(), '$1'::jsonb)->>'outcome'"; }
tagset() { [[ $(thr "{\"op\":\"set\",\"key\":\"$1\",\"level\":\"tag\",\"tag\":\"proofpat\",\"warn\":$2,\"crit\":$3,\"ui_user\":\"proof\"}") == done ]] || fail "threshold $1 at the tag"; }
taginherit() { [[ $(thr "{\"op\":\"inherit\",\"key\":\"$1\",\"level\":\"tag\",\"tag\":\"proofpat\",\"ui_user\":\"proof\"}") == done ]] || fail "inherit $1 at the tag"; }
checks() { q "select string_agg(severity || '|' || check_name || '|' || object, ',' order by check_name, object) from pgvigil.pg_patroni_checks where instance_id = $1"; }
members() { q "select string_agg(member || ':' || coalesce(role, '-') || ':' || coalesce(state, '-') || ':' || is_present, ',' order by member) from pgvigil.pg_patroni_members where instance_id = $1"; }

echo "--- A. a healthy cluster, the default endpoint"
collect pv-pat1; collect pv-pat2; collect pv-pat3
P1=$(iid pv-pat1); P2=$(iid pv-pat2); P3=$(iid pv-pat3)
(( P1 < P2 && P2 < P3 )) || fail "A: the instance ids $P1 $P2 $P3 do not rise"
[[ $(q "select concat_ws('|', ok, cluster_ok, configured, scope, members, leader, paused, system_identifier) from pgvigil.pg_patroni_read where instance_id = $P1") == "t|t|f|pvp|3|pat1|f|$SYSID" ]] \
  || fail "A: read $(q "select * from pgvigil.pg_patroni_read where instance_id = $P1")"
[[ $(members "$P1") == "pat1:leader:running:true,pat2:replica:streaming:true,pat3:replica:streaming:true" ]] || fail "A: members $(members "$P1")"
[[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $P1 and api_ok and version ~ '^4\.' and not pending_restart and not failsafe_active
        and dcs_last_seen > snapshot_at - interval '60 seconds' and (role = 'leader' or lag_bytes >= 0)") == 3 ]] \
  || fail "A: member states $(q "select member, api_ok, version, pending_restart, failsafe_active, dcs_last_seen, snapshot_at, lag_bytes from pgvigil.pg_patroni_members where instance_id = $P1")"
[[ $(q "select concat_ws('|', instance_id, read_by) from pgvigil.pg_patroni_clusters where scope = 'pvp'") == "$P1|3" ]] || fail "A: clusters $(q "select * from pgvigil.pg_patroni_clusters")"
[[ -z $(checks "$P1") ]] || fail "A: checks $(checks "$P1")"
[[ $(q "select is_replica from pgvigil.pg_role_state where instance_id = $P1") == f ]] || fail "A: the role row"
ok "A: 3 members read whole from pat1's REST API with the role read; the cluster judged once"

echo "--- B. a pending restart"
ctl pat1 edit-config --force -p max_connections=120 >/dev/null || fail "B: edit-config"
pending3() { [[ $(api pat1 cluster | jq_ "print(sum(1 for m in d['members'] if m.get('pending_restart')))") == 3 ]]; }
waitfor 90 "3 members pending a restart" pending3
collect pv-pat1
[[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $P1 and is_present and pending_restart and pending_restart_reason = 'max_connections 100 -> 120'") == 3 ]] \
  || fail "B: pending $(q "select member, pending_restart, pending_restart_reason from pgvigil.pg_patroni_members where instance_id = $P1")"
[[ -z $(checks "$P1") ]] || fail "B: a check under the 30-minute default: $(checks "$P1")"
tagset patroni_pending_restart 0 null
collect pv-pat1
[[ $(checks "$P1") == "warning|patroni pending restart|pat1,warning|patroni pending restart|pat2,warning|patroni pending restart|pat3" ]] || fail "B: checks $(checks "$P1")"
[[ $(q "select count(*) from pgvigil.pg_patroni_checks where instance_id = $P1 and detail like '%max_connections 100 -> 120%'") == 3 ]] || fail "B: the reason in the detail"
ctl pat1 restart pvp --force >/dev/null || fail "B: patronictl restart"
nopending() { [[ $(api pat1 cluster | jq_ "print(sum(1 for m in d['members'] if m.get('pending_restart')), sum(1 for m in d['members'] if m['state'] in ('running', 'streaming')))") == "0 3" ]]; }
waitfor 120 "the restart to end" nopending
collect pv-pat1
[[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $P1 and is_present and not pending_restart and pending_restart_since is null") == 3 ]] || fail "B: still pending after the restart"
[[ -z $(checks "$P1") ]] || fail "B: checks after the restart $(checks "$P1")"
taginherit patroni_pending_restart
ok "B: a pending restart and its reason on 3 members, a warning at the tag's 0, gone after patronictl restart"

echo "--- C. paused"
ctl pat1 pause --wait >/dev/null || fail "C: pause"
collect pv-pat1
[[ $(q "select concat_ws('|', paused, paused_since is not null) from pgvigil.pg_patroni_read where instance_id = $P1") == "t|t" ]] || fail "C: read not paused"
[[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $P1 and is_present and paused") == 3 ]] || fail "C: members' own pause"
[[ -z $(checks "$P1") ]] || fail "C: a check under the 15-minute default: $(checks "$P1")"
tagset patroni_paused null 0
collect pv-pat1
[[ $(checks "$P1") == "critical|patroni paused|pvp" ]] || fail "C: checks $(checks "$P1")"
taginherit patroni_paused
ok "C: the pause read on the cluster and on each member; critical at the tag's 0"

echo "--- D. a member's PostgreSQL stopped while paused"
docker exec "$(ct pat3)" pg_ctl -D /var/lib/postgresql/pat stop -m fast >/dev/null 2>&1 || fail "D: pg_ctl stop"
stopped3() { [[ $(api pat1 cluster | jq_ "print([m['state'] for m in d['members'] if m['name'] == 'pat3'])") == "['stopped']" ]]; }
waitfor 60 "pat3 listed stopped" stopped3
collect pv-pat1; D1=$(date +%s)
[[ $(q "select concat_ws('|', state, lag_text, down_reason, down_since = snapshot_at, is_present) from pgvigil.pg_patroni_members where instance_id = $P1 and member = 'pat3'") == "stopped|unknown|state stopped|t|t" ]] \
  || fail "D: pat3 $(q "select * from pgvigil.pg_patroni_members where instance_id = $P1 and member = 'pat3'")"
[[ -z $(checks "$P1") ]] || fail "D: a member-down row on its first read: $(checks "$P1")"
while (( $(date +%s) - D1 < 55 )); do sleep 2; done
collect pv-pat1
[[ $(checks "$P1") == "critical|patroni member down|pat3" ]] || fail "D: checks $(checks "$P1")"
[[ $(q "select detail like 'Patroni lists it stopped since %' from pgvigil.pg_patroni_checks where instance_id = $P1") == t ]] || fail "D: the detail"
ok "D: pat3 stopped, down on the second read a minute later (critical)"

echo "--- E. no leader (paused, the leader's container stopped)"
P1LAST=$(q "select extract(epoch from snapshot_at)::bigint from pgvigil.pg_patroni_read where instance_id = $P1")
docker stop -t 5 "$(ct pat1)" >/dev/null || fail "E: docker stop pat1"
noleader() { [[ $(api pat2 cluster | jq_ "print(any(m['role'] in ('leader', 'standby_leader') for m in d['members']), any(m['name'] == 'pat1' for m in d['members']))") == "False False" ]]; }
waitfor 120 "pat2's /cluster without a leader and without pat1" noleader
collect pv-pat2; E1=$(date +%s)
[[ $(q "select concat_ws('|', ok, leader is null, no_leader_since = snapshot_at, paused) from pgvigil.pg_patroni_read where instance_id = $P2") == "t|t|t|t" ]] \
  || fail "E: pv-pat2's read $(q "select * from pgvigil.pg_patroni_read where instance_id = $P2")"
while (( $(date +%s) - E1 < 55 || $(date +%s) - P1LAST < 125 )); do sleep 2; done
collect pv-pat2
[[ $(q "select instance_id from pgvigil.pg_patroni_clusters where scope = 'pvp'") == "$P2" ]] || fail "E: the judge $(q "select * from pgvigil.pg_patroni_clusters")"
[[ $(checks "$P2") == "critical|patroni member down|pat1,critical|patroni member down|pat3,critical|patroni no leader|pvp" ]] || fail "E: checks $(checks "$P2")"
[[ $(q "select detail like '%paused%' from pgvigil.pg_patroni_checks where instance_id = $P2 and check_name = 'patroni no leader'") == t ]] || fail "E: the no-leader detail"
[[ $(q "select detail like 'gone from the cluster since % last seen as leader, running%' from pgvigil.pg_patroni_checks where instance_id = $P2 and object = 'pat1'") == t ]] \
  || fail "E: pat1's detail $(q "select detail from pgvigil.pg_patroni_checks where instance_id = $P2 and object = 'pat1'")"
echo "--- E/W. the web side"
AP=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
U="http://127.0.0.1:$AP"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$AP" -no-login >"$WORK/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
js() { curl -fsS "$U/api/$1" | python3 -c "import json,sys
d=json.load(sys.stdin)
def rows(k):
    t=d.get(k) or {'columns':[],'rows':[]}; return [dict(zip(t['columns'],r)) for r in t['rows']]
$2"; }
[[ $(js "overview" "print(any(r.get('check_group')=='patroni' and r.get('check_name')=='patroni no leader' for r in [dict(zip(d['columns'],r)) for r in d['rows']]))") == True ]] || fail "W: /api/overview"
[[ $(js "pg/state?instance=$P2" "print(sorted(r['member'] for r in rows('patroni') if r['down_since'] is not None), len(rows('patroni_checks')))") == "['pat1', 'pat3'] 3" ]] || fail "W: /api/pg/state"
[[ $(js "pg/replication" "print([r['judges'] for r in rows('patroni') if r['instance'] == 'pv-pat2'])") == "[True]" ]] || fail "W: /api/pg/replication"
kill "$SRVPID" 2>/dev/null; SRVPID=""
ok "E: no leader and two members down, judged on pv-pat2 after the hand-over; the three reads of the web side"

echo "--- F. resumed, pat1 back"
ctl pat2 resume --wait >/dev/null || fail "F: resume"
led() { [[ $(api pat2 cluster | jq_ "print(len(d['members']), sum(1 for m in d['members'] if m['role'] == 'leader'), all(m['state'] in ('running', 'streaming') for m in d['members']))") == "2 1 True" ]]; }
waitfor 120 "a leader, pat2 and pat3 serving" led
collect pv-pat2
[[ $(q "select concat_ws('|', leader is not null, no_leader_since is null, paused) from pgvigil.pg_patroni_read where instance_id = $P2") == "t|t|f" ]] || fail "F: pv-pat2's read"
[[ $(checks "$P2") == "critical|patroni member down|pat1" ]] || fail "F: checks $(checks "$P2")"
docker start "$(ct pat1)" >/dev/null || fail "F: docker start pat1"
back1() { [[ $(api pat2 cluster | jq_ "print([m['state'] for m in d['members'] if m['name'] == 'pat1'])") == "['streaming']" ]]; }
waitfor 180 "pat1 streaming again" back1
collect pv-pat2; collect pv-pat1; collect pv-pat3
[[ -z $(q "select string_agg(check_name, ',') from pgvigil.pg_patroni_checks c join pgvigil.instances i using (instance_id) where i.name like 'pv-pat%'") ]] || fail "F: checks left $(checks "$P1") / $(checks "$P2")"
[[ $(q "select instance_id from pgvigil.pg_patroni_clusters where scope = 'pvp'") == "$P1" ]] || fail "F: the judge is not pv-pat1 again"
ok "F: a leader elected on resume, pat1 rejoined; no check left, pv-pat1 judges again"

echo "--- H. another port and TLS"
retls() {   # <template>: every member's REST API to it, Patroni reloaded
  for n in 1 2 3; do docker exec "$(ct "pat$n")" sh -c "echo $1 > /tmp/tmpl; sed -e s/NAME/pat$n/ -e s/IP/\$(hostname -i)/g /p/$1 > /tmp/p.yml" || fail "H: $1 on pat$n"; docker kill -s HUP "$(ct "pat$n")" >/dev/null; done
}
retls tls-optional.yml
tlsup() { [[ $(curl -s -m 3 --cacert "$CERTS/ca.pem" "https://$IP1:8009/cluster" | jq_ "print(sum(1 for m in d['members'] if m['api_url'].startswith('https://')))") == 3 ]]; }
waitfor 90 "the members' REST API on https 8009" tlsup
collect pv-pat1; H1=$(date +%s); collect pv-fresh; collect pv-tls; collect pv-tlshttp; collect pv-noca
F=$(iid pv-fresh); T=$(iid pv-tls); TH=$(iid pv-tlshttp); NC=$(iid pv-noca)
[[ $(q "select concat_ws('|', ok, configured, message) from pgvigil.pg_patroni_read where instance_id = $P1") == "f|f|connection refused" ]] || fail "H: pv-pat1 $(q "select * from pgvigil.pg_patroni_read where instance_id = $P1")"
[[ $(q "select concat_ws('|', ok, cluster_ok, configured, members) from pgvigil.pg_patroni_read where instance_id = $T") == "t|t|t|3" ]] || fail "H: pv-tls $(q "select * from pgvigil.pg_patroni_read where instance_id = $T")"
[[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $T and is_present and api_ok and api_url like 'https://%:8009/patroni'") == 3 ]] || fail "H: pv-tls members $(members "$T")"
[[ $(q "select message from pgvigil.pg_patroni_read where instance_id = $TH") == "the endpoint answers in TLS: name it https:// in the instance's patroni.url" ]] || fail "H: pv-tlshttp $(q "select message from pgvigil.pg_patroni_read where instance_id = $TH")"
[[ $(q "select message like '%signed by a CA the collector does not trust%' from pgvigil.pg_patroni_read where instance_id = $NC") == t ]] || fail "H: pv-noca $(q "select message from pgvigil.pg_patroni_read where instance_id = $NC")"
[[ $(q "select string_agg(setting, ',') from pgvigil.pg_patroni_findings where instance_id = $F") == "patroni API not found" ]] || fail "H: pv-fresh's finding $(q "select * from pgvigil.pg_patroni_findings where instance_id = $F")"
[[ -z $(checks "$F") ]] || fail "H: pv-fresh has a check $(checks "$F")"
while (( $(date +%s) - H1 < 55 )); do sleep 2; done
collect pv-pat1
[[ $(checks "$P1") == "warning|patroni API not answering|http://$IP1:8008/cluster" ]] || fail "H: pv-pat1 checks $(checks "$P1")"
retls tls-required.yml
needcert() { [[ $(curl -s -m 3 -o /dev/null -w '%{http_code}' --cacert "$CERTS/ca.pem" "https://$IP1:8009/patroni") != 200 ]]; }
waitfor 90 "verify_client required" needcert
collect pv-tls; collect pv-mtls; M=$(iid pv-mtls)
[[ $(q "select message from pgvigil.pg_patroni_read where instance_id = $T") == "the endpoint asks for a client certificate: name it in patroni.cert_file and patroni.key_file" ]] \
  || fail "H: pv-tls without a client certificate: $(q "select message from pgvigil.pg_patroni_read where instance_id = $T")"
[[ $(q "select concat_ws('|', ok, cluster_ok, members) from pgvigil.pg_patroni_read where instance_id = $M") == "t|t|3" ]] || fail "H: pv-mtls $(q "select * from pgvigil.pg_patroni_read where instance_id = $M")"
[[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $M and is_present and api_ok") == 3 ]] || fail "H: pv-mtls members"
ok "H: https on 8009 read with the CA, then with a client certificate; each wrong setting says what to change"

echo "--- S. the rules on seeded rows"
seed() { q "select pgvigil.ensure_instance('$1-$SUF', 'onprem', 'x', 180000, false, '{}')"; }
imp() { q "select pgvigil.import_patroni($1, now() - interval '$2 seconds', '$3'::jsonb)" >/dev/null; }
R() { echo "{\"kind\":\"patroni_read\",\"url\":\"u\",\"ok\":true,\"cluster_ok\":${3:-true},\"scope\":\"$1\",\"members\":2,\"leader\":$2,\"system_identifier\":\"s-$1\"}"; }
Mb() { echo "{\"kind\":\"patroni\",\"member\":\"$1\",\"role\":\"$2\",\"state\":\"$3\",\"api_ok\":true${4:+,$4}}"; }
sc() { q "select string_agg(severity || '|' || check_name || '|' || object, ',' order by check_name, object) from pgvigil.pg_patroni_checks where instance_id = $1"; }
s1=$(seed pv-s1)
imp "$s1" 140 "[$(R c1 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica streaming)]"
imp "$s1" 70 "[$(R c1 null),$(Mb m2 replica running)]"
[[ $(sc "$s1" | tr ',' '\n' | grep -c 'no leader') == 0 ]] || fail "s1: the first no-leader read raised it"
imp "$s1" 0 "[$(R c1 null),$(Mb m2 replica running)]"
[[ $(sc "$s1") == "critical|patroni member down|m1,critical|patroni no leader|c1" ]] || fail "s1/s2: $(sc "$s1")"
[[ $(q "select detail like 'gone from the cluster since %' from pgvigil.pg_patroni_checks where instance_id = $s1 and object = 'm1'") == t ]] || fail "s2: the detail"
ok "s1 no leader on the second read; s2 a member gone, down on the second read"
s3=$(seed pv-s3)
imp "$s3" 10 "[$(R c3 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica streaming)]"
imp "$s3" 0 "[$(R c3 null false),$(Mb m2 replica running)]"
[[ "$(q "select concat_ws('|', leader, cluster_ok, no_leader_since is null) from pgvigil.pg_patroni_read where instance_id = $s3")|$(members "$s3")|$(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $s3 and down_since is not null")" \
   == "m1|f|t|m1:leader:running:false,m2:replica:running:true|0" ]] || fail "s3: $(q "select * from pgvigil.pg_patroni_read where instance_id = $s3") / $(members "$s3")"
[[ -z $(sc "$s3") ]] || fail "s3: $(sc "$s3")"
ok "s3 an own-member read keeps the leader and judges no one"
s4=$(seed pv-s4); s4b=$(seed pv-s4b)
imp "$s4" 200 "[$(R c4 '"m1"'),$(Mb m1 leader running)]"
imp "$s4" 70 '[{"kind":"patroni_read","url":"u4","ok":false,"message":"connection refused"}]'
imp "$s4" 0 '[{"kind":"patroni_read","url":"u4","ok":false,"message":"connection refused"}]'
[[ $(sc "$s4") == "warning|patroni API not answering|u4" ]] || fail "s4: $(sc "$s4")"
imp "$s4b" 70 '[{"kind":"patroni_read","url":"u4b","ok":false,"message":"connection refused"}]'
imp "$s4b" 0 '[{"kind":"patroni_read","url":"u4b","ok":false,"message":"connection refused"}]'
[[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $s4 and is_present") == 0 ]] || fail "s4: a failed read left members on the page"
[[ -z $(sc "$s4b") && $(q "select string_agg(severity || '|' || setting, ',') from pgvigil.pg_patroni_findings where instance_id = $s4b") == "info|patroni API not found" ]] || fail "s4b: $(sc "$s4b")"
ok "s4 a failing API after a good read warns and takes the members off the page; never good and not configured: an info finding"
s5=$(seed pv-s5)
imp "$s5" 10 "[$(R c5 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica stopped)]"
imp "$s5" 0 '[]'
[[ "$(q "select count(*) from pgvigil.pg_patroni_read where instance_id = $s5")|$(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $s5 and (is_present or down_since is not null)")|$(sc "$s5")" == "0|0|" ]] || fail "s5"
ok "s5 no Patroni any more: nothing kept, nothing judged"
s6=$(seed pv-s6)
PR='"pending_restart":true,"pending_restart_reason":"shared_buffers 128MB -> 256MB"'
imp "$s6" 140 "[$(R c6 '"m1"'),$(Mb m1 leader running "$PR")]"
imp "$s6" 70 "[$(R c6 '"m1"'),$(Mb m1 leader running "$PR")]"
imp "$s6" 0 "[$(R c6 '"m1"'),$(Mb m1 leader running "$PR")]"
[[ $(q "select extract(epoch from snapshot_at - pending_restart_since)::int between 135 and 145 from pgvigil.pg_patroni_members where instance_id = $s6") == t ]] || fail "s6: since"
imp "$s6" 0 "[$(R c6 '"m1"'),$(Mb m1 leader running)]"
[[ $(q "select concat_ws('|', pending_restart, pending_restart_since is null) from pgvigil.pg_patroni_members where instance_id = $s6") == "f|t" ]] || fail "s6: cleared"
ok "s6 a pending restart ages from its first read and clears"
s7a=$(seed pv-s7a); s7b=$(seed pv-s7b)
for i in $s7b $s7a; do
  imp "$i" 140 "[$(R c7 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica streaming)]"
  imp "$i" 70 "[$(R c7 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica stopped)]"
  imp "$i" 0 "[$(R c7 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica stopped)]"
done
[[ "$(sc "$s7a")|$(sc "$s7b")" == "critical|patroni member down|m2|" ]] || fail "s7: $(sc "$s7a") / $(sc "$s7b")"
ok "s7 one cluster read twice is judged once, on the lower id"
s8=$(seed pv-s8)
q "select pgvigil.import_rolechange($s8, now() - interval '60 seconds', '[{\"kind\":\"role\",\"is_replica\":false,\"timeline_id\":1},{\"kind\":\"patroni_read\",\"url\":\"u\",\"ok\":true,\"members\":1,\"scope\":\"c8\",\"leader\":\"m1\"},{\"kind\":\"patroni\",\"member\":\"m1\",\"role\":\"leader\",\"state\":\"running\"}]')" >/dev/null
[[ "$(q "select count(*) from pgvigil.pg_patroni_read where instance_id = $s8")|$(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $s8 and is_present")|$(q "select count(*) from pgvigil.pg_role_state where instance_id = $s8")" == "1|1|1" ]] || fail "s8: forwarded"
q "select pgvigil.import_rolechange($s8, now(), '[{\"kind\":\"role\",\"is_replica\":false,\"timeline_id\":1}]')" >/dev/null
[[ "$(q "select count(*) from pgvigil.pg_patroni_read where instance_id = $s8")|$(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $s8 and is_present")" == "0|0" ]] || fail "s8: a role read without Patroni"
ok "s8 a role read hands its Patroni rows on; one without them ends Patroni's state"
s9=$(seed pv-s9)
imp "$s9" 0 "[$(R c9 '"m1"'),$(Mb m1 leader running),$(Mb m9 replica streaming)]"
q "update pgvigil.pg_patroni_members set snapshot_at = now() - interval '8 days' where instance_id = $s9 and member = 'm9'" >/dev/null
imp "$s9" 0 "[$(R c9 '"m1"'),$(Mb m1 leader running)]"
q "update pgvigil.pg_patroni_read set snapshot_at = snapshot_at + interval '61 seconds' where instance_id = $s9" >/dev/null
[[ -z $(sc "$s9") && $(q "select concat_ws('|', is_present, down_since is null) from pgvigil.pg_patroni_members where instance_id = $s9 and member = 'm9'") == "f|t" ]] || fail "s9: $(sc "$s9")"
ok "s9 a member last seen 8 days ago is not down"
s10a=$(seed pv-s10a); s10b=$(seed pv-s10b)
imp "$s10b" 140 "[$(R c10 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica streaming)]"
imp "$s10b" 70 "[$(R c10 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica stopped)]"
imp "$s10a" 30 "[$(R c10 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica streaming)]"
imp "$s10a" 5 "[$(R c10 null false),$(Mb m1 leader running)]"
imp "$s10b" 0 "[$(R c10 '"m1"'),$(Mb m1 leader running),$(Mb m2 replica stopped)]"
[[ "$(sc "$s10a")|$(sc "$s10b")" == "|critical|patroni member down|m2" ]] || fail "s10: $(sc "$s10a") / $(sc "$s10b")"
ok "s10 a lower id that reads only its own member does not judge: the whole read does"

echo "--- U. the Go cases"
UT=$WORK/u; mkdir -p "$UT"; tar --exclude=./web/node_modules --exclude=./.git -cf - . | tar -C "$UT" -xf -
cat > "$UT/internal/collect/zz_proof376_test.go" <<'GO'
package collect

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

func TestProof376Base(t *testing.T) {
	for in, want := range map[string]string{
		"http://10.0.0.5:8008": "http://10.0.0.5:8008", "https://h:8009/": "https://h:8009", "https://h:8009/cluster": "https://h:8009",
		"http://h/patroni": "http://h", "ftp://h:21": "", "http://:8008": "", "http://u:p@h:8008": "", "http://h:8008/x": "", "http://h:8008?a=1": "",
	} {
		got, err := patroniBase(in)
		if (want == "") != (err != nil) || got != want {
			t.Errorf("patroniBase(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if got := patroniDefaultBase("host=/var/run/postgresql user=x"); got != "http://127.0.0.1:8008" {
		t.Errorf("socket dsn: %q", got)
	}
	if got := patroniDefaultBase("host=fe80::1 user=x"); got != "http://[fe80::1]:8008" {
		t.Errorf("v6 dsn: %q", got)
	}
}

func TestProof376Reason(t *testing.T) {
	r := patroniReason([]byte(`{"shared_buffers":{"old_value":"128MB","new_value":"256MB"},"max_connections":{"old_value":"100","new_value":"120"}}`))
	if r != "max_connections 100 -> 120, shared_buffers 128MB -> 256MB" {
		t.Errorf("reason %q", r)
	}
	if patroniReason(nil) != "" || patroniReason([]byte("null")) != "" || patroniReason([]byte(`"x"`)) != "" {
		t.Error("an empty or odd reason gave text")
	}
}

// the answers recorded from Patroni 4.1.5 (paused, pat3's PostgreSQL stopped, a pending restart): the cluster endpoint
// and one server per member (its api_url rebuilt as <host:port>/patroni); pat2's address answers for pat1
func recorded(t *testing.T, hangCluster bool) *httptest.Server {
	member := func(status int, body string) *httptest.Server {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/patroni" {
				http.NotFound(w, r)
				return
			}
			w.WriteHeader(status)
			_, _ = w.Write([]byte(body))
		}))
		t.Cleanup(s.Close)
		return s
	}
	m1 := member(200, `{"state": "running", "role": "primary", "timeline": 1, "pause": true, "dcs_last_seen": 1794676285, "database_system_identifier": "7708075559413981218", "pending_restart": true, "pending_restart_reason": {"max_connections": {"old_value": "100", "new_value": "120"}}, "patroni": {"version": "4.1.5", "scope": "pvx", "name": "pat1"}}`)
	m2 := member(200, `{"state": "running", "role": "primary", "dcs_last_seen": 1, "patroni": {"version": "4.1.5", "scope": "pvx", "name": "pat1"}}`)
	m3 := member(503, `{"state": "stopped", "role": "replica", "pause": true, "dcs_last_seen": 1794676285, "failsafe_mode_is_active": true, "patroni": {"version": "4.1.5", "scope": "pvx", "name": "pat3"}}`)
	mux := http.NewServeMux()
	mux.HandleFunc("/cluster", func(w http.ResponseWriter, r *http.Request) {
		if hangCluster {
			time.Sleep(4 * time.Second)
		}
		_, _ = w.Write([]byte(`{"members": [{"name": "pat1", "role": "leader", "state": "running", "api_url": "` + m1.URL + `/patroni", "host": "172.27.0.3", "port": 5432, "timeline": 1, "pending_restart": true, "pending_restart_reason": {"max_connections": {"old_value": "100", "new_value": "120"}}}, {"name": "pat2", "role": "replica", "state": "streaming", "api_url": "` + m2.URL + `/patroni?x=1", "host": "172.27.0.4", "port": 5432, "timeline": 1, "receive_lag": 0, "replay_lag": 0, "lag": 0, "lsn": "0/5000060"}, {"name": "pat3", "role": "replica", "state": "stopped", "api_url": "` + m3.URL + `/somewhere/else", "host": "172.27.0.5", "port": 5432, "receive_lag": "unknown", "replay_lag": "unknown", "lag": "unknown"}], "pause": true, "scope": "pvx"}`))
	})
	mux.HandleFunc("/patroni", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"state": "running", "role": "primary", "timeline": 2, "cluster_unlocked": true, "failsafe_mode_is_active": true, "dcs_last_seen": 1794676494, "database_system_identifier": "77", "patroni": {"version": "4.1.5", "scope": "pvx", "name": "pat2"}}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestProof376Read(t *testing.T) {
	srv := recorded(t, false)
	rows := patroniRead(context.Background(), patroniEndpoint{base: srv.URL, client: patroniHTTP(nil)})
	if len(rows) != 4 {
		t.Fatalf("%d rows", len(rows))
	}
	rd := rows[0]
	if rd["ok"] != true || rd["cluster_ok"] != true || rd["paused"] != true || rd["leader"] != "pat1" || rd["members"] != 3 || rd["system_identifier"] != "7708075559413981218" {
		t.Errorf("read %v", rd)
	}
	p1, p2, p3 := rows[1], rows[2], rows[3]
	if p1["pending_restart_reason"] != "max_connections 100 -> 120" || p1["api_ok"] != true || p1["version"] != "4.1.5" || p1["paused"] != true {
		t.Errorf("pat1 %v", p1)
	}
	if !p1["dcs_last_seen"].(time.Time).Equal(time.Unix(1794676285, 0)) {
		t.Errorf("pat1 dcs %v", p1["dcs_last_seen"])
	}
	if p2["api_ok"] != false || p2["api_message"] != `api_url answers for member "pat1"` || p2["lag_bytes"] != int64(0) || p2["dcs_last_seen"] != nil {
		t.Errorf("pat2 (its address answers for pat1) %v", p2)
	}
	if p3["state"] != "stopped" || p3["lag_text"] != "unknown" || p3["api_ok"] != true || p3["failsafe_active"] != true {
		t.Errorf("pat3 (a 503 with the member's state) %v", p3)
	}
}

func TestProof376Fallback(t *testing.T) {
	srv := recorded(t, true)
	start := time.Now()
	rows := patroniRead(context.Background(), patroniEndpoint{base: srv.URL, client: patroniHTTP(nil)})
	if el := time.Since(start); el > 5*time.Second {
		t.Errorf("took %v", el)
	}
	if len(rows) != 2 || rows[0]["ok"] != true || rows[0]["cluster_ok"] != false || rows[0]["message"] != "/cluster: no answer in 3s" {
		t.Fatalf("rows %v", rows)
	}
	if m := rows[1]; m["member"] != "pat2" || m["self"] != true || m["failsafe_active"] != true || m["role"] != "primary" {
		t.Errorf("own member %v", m)
	}
}

func TestProof376TLS(t *testing.T) {
	ts := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(`{}`)) }))
	defer ts.Close()
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(`{}`)) }))
	defer plain.Close()
	var v map[string]any
	ctx := context.Background()
	rows := patroniRead(ctx, patroniEndpoint{base: strings.Replace(ts.URL, "https://", "http://", 1), client: patroniHTTP(nil)})
	if len(rows) != 1 || rows[0]["message"] != patroniTLSHint {
		t.Errorf("TLS over http: %v", rows)
	}
	err := patroniGet(ctx, patroniHTTP(nil), strings.Replace(plain.URL, "http://", "https://", 1)+"/cluster", &v, false)
	if err == nil || !strings.HasPrefix(err.Error(), "the endpoint answers plain HTTP") {
		t.Errorf("plain over https: %v", err)
	}
	err = patroniGet(ctx, patroniHTTP(nil), ts.URL+"/cluster", &v, false)
	if err == nil || !strings.Contains(err.Error(), "signed by a CA the collector does not trust") {
		t.Errorf("unknown CA: %v", err)
	}
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, certPEM(ts), 0o600); err != nil {
		t.Fatal(err)
	}
	ep, err := patroniEndpointOf(config.Instance{Patroni: &config.Patroni{URL: ts.URL, CAFile: ca}})
	if err != nil || !ep.configured {
		t.Fatalf("endpoint %v %v", ep, err)
	}
	if err := patroniGet(ctx, ep.client, ep.base+"/cluster", &v, false); err != nil {
		t.Errorf("with the CA: %v", err)
	}
	if _, err := patroniEndpointOf(config.Instance{Patroni: &config.Patroni{URL: ts.URL, CAFile: "/nonexistent/ca.pem"}}); err == nil || !strings.HasPrefix(err.Error(), "patroni.ca_file") {
		t.Errorf("a missing ca_file: %v", err)
	}
	if _, err := patroniEndpointOf(config.Instance{Patroni: &config.Patroni{URL: ts.URL, CertFile: ca}}); err == nil || err.Error() != "patroni: cert_file and key_file go together" {
		t.Errorf("a cert without its key: %v", err)
	}
}
GO
cat > "$UT/internal/collect/zz_proof376_pem_test.go" <<'GO'
package collect

import (
	"encoding/pem"
	"net/http/httptest"
)

func certPEM(ts *httptest.Server) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ts.Certificate().Raw})
}
GO
cat > "$UT/internal/config/zz_proof376_test.go" <<'GO'
package config

import "testing"

func TestProof376Validate(t *testing.T) {
	for _, c := range []struct {
		p    *Patroni
		want string
	}{
		{nil, ""},
		{&Patroni{URL: "https://h:8009", CAFile: "/ca", CertFile: "/c", KeyFile: "/k"}, ""},
		{&Patroni{URL: "http://h:8008/cluster"}, ""},
		{&Patroni{}, "patroni: the block needs a url (http(s)://host:port)"},
		{&Patroni{CAFile: "/ca"}, "patroni: ca_file, cert_file and key_file need a url"},
		{&Patroni{URL: "ftp://h"}, `patroni.url "ftp://h": the scheme must be http or https`},
		{&Patroni{URL: "https://h:8009", CertFile: "/c"}, "patroni: cert_file and key_file go together"},
		{&Patroni{URL: "http://h:8008", CAFile: "/ca"}, `patroni.url "http://h:8008" is http: ca_file, cert_file and key_file are for https`},
		{&Patroni{URL: "http://h:8008/x"}, `patroni.url "http://h:8008/x": a scheme, a host and a port only`},
	} {
		err := c.p.validate()
		if got := ""; err != nil {
			got = err.Error()
			if got != c.want {
				t.Errorf("%+v: %q, want %q", c.p, got, c.want)
			}
		} else if c.want != "" {
			t.Errorf("%+v: no error, want %q", c.p, c.want)
		}
	}
}
GO
(cd "$UT" && go test -count=1 -run 'TestProof376' ./internal/collect/ ./internal/config/ 2>&1 | tail -15) | tee "$WORK/u.out"
grep -q '^FAIL\|^--- FAIL\|panic:' "$WORK/u.out" && fail "U: the Go cases"
[[ $(grep -c '^ok ' "$WORK/u.out") == 2 ]] || fail "U: not both packages ran"
ok "U: the Go cases"
echo "--- G. the DCS down (failsafe mode)"
if [[ ${PATRONI_G:-1} == 1 ]]; then
  retls plain.yml
  plainup() { [[ $(api pat1 cluster | jq_ "print(sum(1 for m in d['members'] if m['api_url'].startswith('http://')))") == 3 ]]; }
  waitfor 90 "the members' REST API back on http 8008" plainup
  LEADER=$(api pat1 cluster | jq_ "print([m['name'] for m in d['members'] if m['role'] == 'leader'][0])") || fail "G: no leader in /cluster"
  topo() { api "$LEADER" failsafe | jq_ "print(','.join(k + '=' + ('http' if v.startswith('http://') and ':8008/' in v else v) for k, v in sorted(d.items())))"; }
  HELD=""
  for _ in $(seq 1 60); do HELD=$(topo || true); [[ $HELD == "pat1=http,pat2=http,pat3=http" ]] && break; sleep 2; done
  if [[ $HELD != "pat1=http,pat2=http,pat3=http" ]]; then
    [[ -n $HELD ]] || HELD="nothing read from the GET /failsafe of $LEADER"
    echo "  G: not proven: the leader's failsafe topology never held all members ($HELD)"
  else
    echo "  G: the leader $LEADER's failsafe topology holds pat1, pat2, pat3 at http 8008"
    tagset patroni_dcs_last_seen 0.25 30
    docker stop -t 2 "$ETCD_CT" >/dev/null || fail "G: docker stop etcd"
    lfs() { [[ $(api "$LEADER" patroni | jq_ "print(d.get('failsafe_mode_is_active', False))") == True ]]; }
    waitfor 120 "the leader's failsafe mode" lfs
    for n in 1 2; do
      i=$(iid "pv-pat$n")
      collect "pv-pat$n"
      own=$(api "pat$n" patroni | jq_ "print('t' if d.get('failsafe_mode_is_active') else 'f')") || fail "G: pat$n's own /patroni"
      [[ $(q "select concat_ws('|', ok, cluster_ok, message like '/cluster:%', members, leader) from pgvigil.pg_patroni_read where instance_id = $i") == "t|f|t|1|$LEADER" ]] \
        || fail "G: read of pv-pat$n $(q "select * from pgvigil.pg_patroni_read where instance_id = $i")"
      [[ $(q "select concat_ws('|', is_present, failsafe_active, dcs_last_seen < snapshot_at) from pgvigil.pg_patroni_members where instance_id = $i and member = 'pat$n'") == "t|$own|t" ]] \
        || fail "G: pat$n's row against its own /patroni (failsafe $own): $(q "select member, is_present, failsafe_active, dcs_last_seen, snapshot_at, api_ok from pgvigil.pg_patroni_members where instance_id = $i")"
      echo "  G: pat$n's row failsafe_active = its own /patroni's ($own)"
    done
    [[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id in ($P1, $P2) and down_since is not null") == 0 ]] || fail "G: a down_since from an own-member read"
    [[ $(q "select string_agg(severity || '|' || check_name || '|' || object, ',' order by object) from pgvigil.pg_patroni_checks c where c.instance_id in (select instance_id from pgvigil.pg_patroni_read where scope = 'pvp') and object in ('pat1', 'pat2')") \
       == "warning|patroni DCS not reached|pat1,warning|patroni DCS not reached|pat2" ]] || fail "G: checks $(q "select * from pgvigil.pg_patroni_checks")"
    [[ $(q "select bool_and((c.detail like '%failsafe mode keeps the leader running%') = m.failsafe_active)
              from pgvigil.pg_patroni_checks c join pgvigil.pg_patroni_members m on m.member = c.object and m.instance_id = (select instance_id from pgvigil.instances where name = 'pv-' || c.object)
             where c.object in ('pat1', 'pat2') and c.instance_id in (select instance_id from pgvigil.pg_patroni_read where scope = 'pvp')") == t ]] || fail "G: the failsafe words"
    [[ $(q "select count(*) from pgvigil.pg_patroni_checks where instance_id in (select instance_id from pgvigil.pg_patroni_read where scope = 'pvp')
             and (check_name <> 'patroni DCS not reached' or object not in ('pat1', 'pat2', 'pat3'))") == 0 ]] || fail "G: another check $(q "select * from pgvigil.pg_patroni_checks")"
    docker start "$ETCD_CT" >/dev/null || fail "G: docker start etcd"
    clusterok() { [[ $(api pat1 cluster | jq_ "print(len(d['members']))") == 3 ]]; }
    waitfor 90 "/cluster to answer again" clusterok
    collect pv-pat1
    [[ $(q "select concat_ws('|', cluster_ok, members) from pgvigil.pg_patroni_read where instance_id = $P1") == "t|3" ]] || fail "G: back"
    taginherit patroni_dcs_last_seen
    collect pv-pat1
    [[ -z $(checks "$P1") ]] || fail "G: checks after etcd came back $(checks "$P1")"
    ok "G: with etcd down each member's own state read and stored as it says (failsafe as the member says), the DCS contact ageing, the leader kept"
  fi
else
  echo "  G: not proven: skipped (PATRONI_G=0)"
fi
echo "PASS proof-patroni"
