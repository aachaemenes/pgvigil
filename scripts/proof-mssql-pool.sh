#!/usr/bin/env bash
# Proof of an Azure SQL Database elastic pool's reads (CLOUDSQL C4) and of the entra-identity sign-in (CLOUDSQL C1)
# against a live lab: scripts/lab/azure-sqldb.sh with PGVIGIL_LAB_AZ_TIER=pool (up; allow <this machine> <the VM>;
# vmdoor <this machine>; logins). Runs on the machine the lab admits (the one that holds its state file and the VM's
# key); part E runs ON the lab's VM over ssh, as its system-assigned managed identity.
#
# Needs: go, psql, ssh, scp, jq, and
#   PGVIGIL_ADMIN_DSN   a superuser connection to a PostgreSQL in KEYWORD form, no dbname (the store is made there)
#   PGVIGIL_LAB_STATE   the lab's state file, default .lab/azure-sqldb.env (its passwords reach the tests and the
#                       collector through the environment by name; none is printed)
# Settings: PGVIGIL_SKIP_VM=1 leaves out part E (said as NOT RUN, and the verdict is then not PASS).
#
# What it makes, and removes on every exit path the shell can catch: a store database pgvigil_poolproof_<n> on the
# PostgreSQL; on the VM, a folder ~/pgvproof with two binaries, and PostgreSQL 16 from Ubuntu's archive with a store
# database owned by a superuser role of the VM's admin name (peer sign-in over the socket; the VM itself goes with
# the lab's down). Nothing is made in the monitored databases.
#
# Expected (written before the first run):
#  P  (internal/mssql TestPoolLive, as pgv_pool on the first pooled database)
#     P0 detection: azuresqldb, engine edition 5, service objective ElasticPool, VIEW SERVER STATE true (its role);
#        the contained user with VIEW DATABASE STATE alone: azuresqldb, and mssql_pool skipped for VIEW SERVER STATE
#     P1 every complete minute the collector returns equals internal/mssql's arithmetic over the server admin's read
#        of the same view right after (samples, averages, maxima, the minute's last storage figures)
#     P3 pgv_conn (##MS_ServerStateReader## + ##MS_DatabaseConnector##, no user) on the second database: recorded
#     P4 without the tag: skipped with 'tag the instance pool:<name>' (or the name, recorded)
#  S  (the store: both pooled databases as instances tagged pool:<pool>, `collect -once mssql_pool` on each in turn)
#     S1 the first run stores its complete minutes, read_by = the first instance; the second run, right after, adds
#        no row for a minute the first stored (its rows, if any, are minutes newer than the first's newest)
#     S2 mssql_pool_storage_status of the first instance: 'OK' (a near-empty Basic pool: allocated far below 80 %),
#        the pool named, the default thresholds 0.8 / 0.9 (numeric(5,4): 0.8000 / 0.9000)
#  E  (on the VM, as its system-assigned identity)
#     E1 internal/mssqlopen TestEntraIdentityLive: 5 new connects to the first database sign in as one identity,
#        VIEW DATABASE STATE held
#     E2 the second database (no user for the identity) refuses it
#     E3 pgvigil collect -once mssql_instance with the instance's dsn the one BuildDSN writes for auth entra-identity
#        (fedauth=ActiveDirectoryManagedIdentity, no login, no password): the instance stored as engine sqlserver,
#        platform azuresqldb
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection in keyword form, no dbname}"
STATE=${PGVIGIL_LAB_STATE:-.lab/azure-sqldb.env}
fail() { echo "FAIL: $*" >&2; exit 1; }
for t in go psql ssh scp jq; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
[ -r "$STATE" ] || fail "no lab state file $STATE (scripts/lab/azure-sqldb.sh up with PGVIGIL_LAB_AZ_TIER=pool)"
# shellcheck disable=SC1090
. "$STATE"
[ "${AZ_TIER:-}" = pool ] || fail "$STATE is not the pool tier's"
umask 077
WORK=$(mktemp -d); N=$RANDOM; STORE="pgvigil_poolproof_$N"
VMS=(ssh -i "$VM_KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$WORK/known_hosts" -o ConnectTimeout=20 "$VM_ADMIN@$VM_IP")
cleanup() {
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $STORE with (force)" >/dev/null 2>&1 || true
  [ "${PGVIGIL_SKIP_VM:-}" = 1 ] || "${VMS[@]}" 'rm -rf ~/pgvproof; sudo -u postgres dropdb --if-exists pgvproof; sudo -u postgres dropuser --if-exists pgv' >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
dsn() { printf 'sqlserver://%s:%s@%s:%s?database=%s&encrypt=true' "$1" "$2" "$AZ_HOST" "$AZ_PORT" "$3"; }
export PGVIGIL_POOL_DSN PGVIGIL_POOL_ADMIN_DSN PGVIGIL_POOL_USER_DSN PGVIGIL_POOL_CONN_DSN PGVIGIL_POOL_TAG="$AZ_POOL"
PGVIGIL_POOL_DSN=$(dsn "$POOL_USER" "$POOL_PW" "$AZ_DB"); PGVIGIL_POOL_ADMIN_DSN=$(dsn "$ADMIN_USER" "$ADMIN_PW" "$AZ_DB")
PGVIGIL_POOL_USER_DSN=$(dsn "$MON_USER" "$MON_PW" "$AZ_DB"); PGVIGIL_POOL_CONN_DSN=$(dsn "$CONN_USER" "$CONN_PW" "$AZ_DB2")
VERDICT=PASS

echo "== P: TestPoolLive (internal/mssql) as $POOL_USER on $AZ_DB"
if go test -count=1 -run '^TestPoolLive$' -v ./internal/mssql 2>&1 | tee "$WORK/p.txt" | grep -E '^\s+pool_live_test.go|^(--- |ok|FAIL)'; then :; fi
grep -q '^--- PASS: TestPoolLive' "$WORK/p.txt" || { VERDICT=FAIL; echo "P: FAIL (above)"; }

echo "== S: the store ($STORE), both pooled databases as instances tagged pool:$AZ_POOL"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $STORE" >/dev/null
export PGV_POOL1_DSN="$PGVIGIL_POOL_DSN" PGV_POOL2_DSN; PGV_POOL2_DSN=$(dsn "$POOL_USER" "$POOL_PW" "$AZ_DB2")
cat > "$WORK/pgvigil.yaml" <<EOF
repository:
  dsn: "$PGVIGIL_ADMIN_DSN dbname=$STORE"
instances:
  - name: pool1
    engine: sqlserver
    dsn: env:PGV_POOL1_DSN
    tags: [pool:$AZ_POOL]
  - name: pool2
    engine: sqlserver
    dsn: env:PGV_POOL2_DSN
    tags: [pool:$AZ_POOL]
EOF
"$WORK/pgvigil" migrate -config "$WORK/pgvigil.yaml" 2>&1 | tail -1
for i in pool1 pool2; do "$WORK/pgvigil" collect -config "$WORK/pgvigil.yaml" -once mssql_instance -instance "$i" > "$WORK/$i.instance.out" 2>&1 || true; done
"$WORK/pgvigil" collect -config "$WORK/pgvigil.yaml" -once mssql_pool -instance pool1 > "$WORK/pool1.out" 2>&1 || true
q() { psql "$PGVIGIL_ADMIN_DSN dbname=$STORE" -XAtq -F '|' -c "$1"; }
ID1=$(q "select instance_id from pgvigil.instances where name = 'pool1'"); ID2=$(q "select instance_id from pgvigil.instances where name = 'pool2'")
[ -n "$ID1" ] && [ -n "$ID2" ] || { cat "$WORK"/pool*.out; fail "S: the instances were not stored"; }
R1=$(q "select count(*), count(*) filter (where instance_id = $ID1), max(snapshot_at) from pgvigil.mssql_pool_minute")
"$WORK/pgvigil" collect -config "$WORK/pgvigil.yaml" -once mssql_pool -instance pool2 > "$WORK/pool2.out" 2>&1 || true
R2=$(q "select count(*), count(*) filter (where instance_id = $ID2), count(*) filter (where instance_id = $ID2 and snapshot_at <= '${R1##*|}')
          from pgvigil.mssql_pool_minute")
echo "   after pool1's run: rows|pool1's|newest = $R1"
echo "   after pool2's run: rows|pool2's|pool2's at or before pool1's newest = $R2"
IFS='|' read -r n1 own1 _ <<<"$R1"; IFS='|' read -r n2 own2 old2 <<<"$R2"
if [ "${n1:-0}" -gt 0 ] && [ "$n1" = "$own1" ] && [ "$old2" = 0 ] && [ "$n2" = $((n1 + own2)) ]; then echo "ok   S1"; else VERDICT=FAIL; echo "FAIL S1"; tail -3 "$WORK/pool1.out" "$WORK/pool2.out"; fi
S2=$(q "select status, round(allocated_storage_percent, 2), pool, warning, critical from pgvigil.mssql_pool_storage_status($ID1)")
echo "   mssql_pool_storage_status(pool1) = $S2"
if [[ "$S2" == "OK|"*"|$AZ_POOL|0.8000|0.9000" ]]; then echo "ok   S2"; else VERDICT=FAIL; echo "FAIL S2"; fi
grep -h 'platform\|level=ERROR\|level=WARN' "$WORK/pool1.instance.out" | head -3 || true

if [ "${PGVIGIL_SKIP_VM:-}" = 1 ]; then
  echo "== E: NOT RUN (PGVIGIL_SKIP_VM=1)"; VERDICT="$VERDICT (E NOT RUN)"
else
  echo "== E: on the VM $VM_NAME as its system-assigned identity"
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go test -c -o "$WORK/mssqlopen.test" ./internal/mssqlopen
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$WORK/pgvigil-linux" ./cmd/pgvigil
  "${VMS[@]}" 'mkdir -p ~/pgvproof'
  scp -q -i "$VM_KEY" -o UserKnownHostsFile="$WORK/known_hosts" "$WORK/mssqlopen.test" "$WORK/pgvigil-linux" "$VM_ADMIN@$VM_IP:pgvproof/"
  "${VMS[@]}" "cd ~/pgvproof && PGVIGIL_ENTRA_HOST=$AZ_HOST PGVIGIL_ENTRA_DB=$AZ_DB PGVIGIL_ENTRA_NOUSER=$AZ_DB2 ./mssqlopen.test -test.run '^TestEntraIdentityLive\$' -test.v -test.count=1" 2>&1 | tee "$WORK/e.txt" | grep -E 'live_test.go|^(--- |ok|PASS|FAIL)' || true
  grep -q '^--- PASS: TestEntraIdentityLive' "$WORK/e.txt" && grep -q 'E2 refused as expected' "$WORK/e.txt" || { VERDICT=FAIL; echo "E1 / E2: FAIL (above)"; }
  echo "   E3: PostgreSQL 16 from Ubuntu's archive on the VM, a store, collect -once mssql_instance with auth entra-identity"
  "${VMS[@]}" "sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y postgresql >/dev/null && sudo -u postgres createuser -s $VM_ADMIN && sudo -u postgres createdb -O $VM_ADMIN pgvproof" \
    || fail "E3: PostgreSQL did not install on the VM"
  "${VMS[@]}" "cd ~/pgvproof && cat > pgvigil.yaml <<EOF
repository:
  dsn: \"host=/var/run/postgresql dbname=pgvproof\"
instances:
  - name: entra1
    engine: sqlserver
    dsn: \"sqlserver://$AZ_HOST?database=$AZ_DB&fedauth=ActiveDirectoryManagedIdentity\"
EOF
./pgvigil-linux migrate -config pgvigil.yaml 2>&1 | tail -1; ./pgvigil-linux collect -config pgvigil.yaml -once mssql_instance -instance entra1 2>&1 | tail -3; psql -h /var/run/postgresql -d pgvproof -XAtq -F '|' -c \"select engine, platform from pgvigil.instances where name = 'entra1'\"" 2>&1 | tee "$WORK/e3.txt" | sed 's/^/   /'
  if tail -1 "$WORK/e3.txt" | grep -qx 'sqlserver|azuresqldb'; then echo "ok   E3"; else VERDICT=FAIL; echo "FAIL E3"; fi
fi
echo "proof-mssql-pool: $VERDICT"
[ "$VERDICT" = PASS ]
