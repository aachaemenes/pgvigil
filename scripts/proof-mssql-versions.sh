#!/usr/bin/env bash
# Proof that the SQL Server proofs hold on every SQL Server version pgvigil names: each scripts/proof-mssql-*.sh is
# run against a pair of containers of each version's image, the pair joined in a clusterless availability group.
# A column or a statement a version does not have shows as a failed proof of that version.
#
# Needs: docker (a missing image is pulled), psql, curl, jq, python3, ss, flock, timeout, od, a go toolchain at the
# repository root (ONE binary is built and handed to every proof as PGVIGIL_BIN; PGVIGIL_BIN names a built one
# instead, and go is needed all the same: three proofs build or test with it), 4 GB of memory per SQL Server (two
# per version, PGVIGIL_VERSIONS_PARALLEL versions at once), and
#   PGVIGIL_ADMIN_DSN          a superuser connection to a PostgreSQL in KEYWORD form, no dbname and no password in
#                              it (host=... user=...); the proofs that ask for PGVIGIL_REPO_DSN get it with
#                              dbname=postgres.
# Settings (a relative path is taken from the repository root):
#   PGVIGIL_MSSQL_VERSIONS     the versions, default "2017 2019 2022 2025"; a version's image is
#                              <PGVIGIL_MSSQL_IMAGE_REPO>:<version>-latest (default mcr.microsoft.com/mssql/server)
#   PGVIGIL_VERSION_PROOFS     the proofs run on each version, default "base services running xe hadr storage perf
#                              reads querystore actions" (scripts/proof-mssql-<name>.sh). proof-mssql-summary.sh
#                              needs no SQL Server and runs once.
#   PGVIGIL_VERSIONS_PARALLEL  versions run at once, default 2 (the proofs measure durations: four versions at
#                              once on eight CPUs made their timing checks fail). One proof never runs on two
#                              versions at the same time (a lock per proof, and one lock for reads and querystore:
#                              their runs look for a free port in the same range), and one pair boots at a time.
#   PGVIGIL_VERSIONS_TIMEOUT   seconds one proof may take, default 2400; a proof over it is ended and FAILS.
#   PGVIGIL_VERSIONS_WHOISACTIVE  a local copy of sp_WhoIsActive.sql (Adam Machanic's procedure; this script
#                              fetches nothing): it is installed in master on node a of every version, and the
#                              running-queries proof then runs its part B. Not set: that part says NOT PROVEN.
#   PGVIGIL_VERSIONS_OUT       the folder of the logs and of summary.md; default a temp folder, kept and named.
#   PGVIGIL_VERSIONS_KEEP=1    leaves the containers up at the end (to read a failure by hand); it names them.
# Refused, because either would turn a cell green without its proof: PGVIGIL_NO_MSSQL (the reads proof would leave
# out every SQL Server part and exit 0) and a GODEBUG that names x509negativeserial (check C must read the build's
# own setting). PGVIGIL_SKIP_PG13 and PGVIGIL_SKIP_DEMO reach the proofs as the caller set them; what a passed proof
# says it left out is listed under the matrix.
#
# What it makes, and removes at the end (found by this run's label; nothing that existed before the run is
# touched): per version two containers pgvv<yy>a-<n> and pgvv<yy>b-<n> (Developer edition, SQL Server Agent and
# Always On switched on, 4 GB each, published on 127.0.0.1 only, the engine as root in its container: the proofs
# copy script files in and write under /backups as their own sandbox lets them, and the 2019 and later images would
# run the engine as the user mssql, which reads neither), one docker network and one volume (/backups of both
# nodes); on the PostgreSQL of PGVIGIL_ADMIN_DSN one repository database pgvigil_verproof_<n> for check C. The sa
# password is made here, one per run, and is never printed; it reaches sqlcmd, docker and the collector through the
# environment by name and a statement that carries a password goes in on stdin. On each node, as a server in use
# has them and a new container does not: Database Mail switched on and started, and the Agent job 'pgvv seed' with
# sixty history rows dated yesterday. On each pair: certificate endpoints on 5022, the group pgvv_ag over the seed
# database pgvv_seed with automatic seeding, the AlwaysOn_health session started. On the 2017 image, which ships
# sqlcmd under /opt/mssql-tools only, a link /opt/mssql-tools18/bin/sqlcmd inside the container (the proofs call
# that path). Where sp_WhoIsActive.sql was named: that procedure in master on node a.
# What the proofs it runs make is theirs to remove, and each says what in its own header: their repository
# databases on the same PostgreSQL, logins and databases inside this run's containers, and (reads, querystore) a
# postgres:13 container of their own.
# Every exit path the shell can catch removes all of it (the end, a failed check, INT, TERM: a running proof is
# ended through its own cleanup first, and a proof that has not ended 120 s after its TERM is killed: what that
# proof made on the PostgreSQL side, its repository databases and a postgres:13 container of its own, then stays,
# under the names its log holds). A kill -9 of this script cannot: the versions' own shells then run on to
# their last proof and nothing is removed. The first line of the output names the label; after a kill -9 end the
# shells (pkill -f 'proof-mssql-version[s].sh') and remove what the label finds:
#   docker rm -f -v $(docker ps -aq --filter label=<label>); docker volume rm $(docker volume ls -q --filter
#   label=<label>); docker network rm $(docker network ls -q --filter label=<label>)
#
# Expected (written before the first run; C, H and the part of G about AlwaysOn_health before the first run that
# had them):
#  P. the pair, per version: both nodes answer (120 tries two seconds apart, each try five minutes at most); sa's
#     ProductVersion has the major the version names (2017 = 14, 2019 = 15, 2022 = 16, 2025 = 17) on both;
#     @@SERVERNAME is the container's name; Always On is enabled (IsHadrEnabled 1) and SQL Server Agent has its
#     sessions open on both.
#  C. the collector connects, per version, to BOTH nodes: `collect -once mssql_instance` as sa over an encrypted
#     connection (encrypt=true, TrustServerCertificate=true) exits 0 and the repository holds the node as engine
#     sqlserver, platform sqlserver, server_version_num = major * 10000 + minor of sa's ProductVersion (140000,
#     150000, 160000, 170000). SQL Server 2017 generates a certificate with a negative serial number for itself,
#     which Go refuses to parse unless the build says otherwise (go.mod: godebug x509negativeserial=1): without
#     that line this check fails on 2017 with "x509: negative serial number", whatever the connection string says.
#     The control beside it: the same read with GODEBUG=x509negativeserial=0 for that one call fails with exactly
#     that error on both 2017 nodes and passes on 2019, 2022 and 2025; what each node answered is recorded in the
#     summary's row "certificate serial negative" and is never a verdict (the number is the server's own).
#     [The first run with the control, graded: it failed on ONE of the two 2017 nodes (node a yes, node b no) and
#      on neither 2019 node. The server draws the number per certificate, so a 2017 server CAN have a negative one;
#      "both 2017 nodes" above was wrong, and the row stays a record.]
#  H. the server in use, per version, on both nodes: msdb.dbo.sysjobhistory holds 60 rows or more and 'Database
#     Mail XPs' is 1 in use.
#  G. the group, per version: created on node a with CLUSTER_TYPE = NONE, node b joined; node a reads the seed
#     database on node b as SYNCHRONIZED and HEALTHY within 100 tries three seconds apart; AlwaysOn_health runs on
#     both nodes.
#  R. every proof of the list exits 0 on every version: the matrix says PASS in every cell. A cell that FAILS is
#     the finding (the proof's log names the statement and the column); it is never rerun into green here.
#  S. proof-mssql-summary.sh (no SQL Server) exits 0, once.
#  The last line is "proof-mssql-versions: PASS (<versions>; <n> proofs on each, summary once; logs in <folder>)"
#  and the exit code 0 only when P, C, H, G, R and S hold for every version; else the failed cells are listed, the
#  last line says FAIL with their count and the exit code is 1.
#  A PASS cell is the proof's exit code. What a passed proof itself prints as SKIPPED, NOT RUN or NOT PROVEN stays
#  so: those lines are listed under the matrix, per version and proof, and kept in left-out.txt.
#  NOT PROVEN HERE: SQL Server 2016 (no Linux image), Windows hosts, Azure SQL Database, Azure SQL Managed
#  Instance, Amazon RDS for SQL Server; an edition other than Developer; a Windows cluster's group. On a container
#  the proofs find here, proof-mssql-reads.sh leaves out its one server setting change (max server memory), which it
#  makes only on a container of its own; without PGVIGIL_VERSIONS_WHOISACTIVE proof-mssql-running.sh passes with
#  its part B (the sp_WhoIsActive path) not proven. The availability proof's part D on a server with fewer than 50
#  rows of job history: the jobs read starts 50 rows behind its cursor, so on such a server a second read returns
#  the same rows again and that proof's own count (the second read smaller than the first) cannot hold; the seeded
#  history is what lets it run here, and a new server's behaviour is the collector's stated one, not proven.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?a superuser connection to a PostgreSQL in keyword form, no dbname}"
for t in docker psql curl jq python3 ss flock timeout od; do command -v "$t" >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
# go always: with a built binary named, three proofs still need it (base and running skip a part without it, hadr fails)
command -v go >/dev/null || { echo "FAIL: go is not on this machine (the proofs build and test with it, whatever PGVIGIL_BIN names)" >&2; exit 1; }
# what would turn a cell green without its proof: refused, never unset behind the caller's back
[ -z "${PGVIGIL_NO_MSSQL:-}" ] || { echo "FAIL: PGVIGIL_NO_MSSQL is set: proof-mssql-reads.sh would leave out every SQL Server part and still exit 0; unset it" >&2; exit 1; }
case ${GODEBUG:-} in *x509negativeserial*) echo "FAIL: GODEBUG carries x509negativeserial: check C must read the build's own setting; unset it" >&2; exit 1 ;; esac
read -r -a VERSIONS <<<"${PGVIGIL_MSSQL_VERSIONS:-2017 2019 2022 2025}"
read -r -a PROOFS <<<"${PGVIGIL_VERSION_PROOFS:-base services running xe hadr storage perf reads querystore actions}"
IMAGE_REPO=${PGVIGIL_MSSQL_IMAGE_REPO:-mcr.microsoft.com/mssql/server}
PARALLEL=${PGVIGIL_VERSIONS_PARALLEL:-2}; PTIMEOUT=${PGVIGIL_VERSIONS_TIMEOUT:-2400}
[[ $PARALLEL =~ ^[1-9][0-9]*$ && $PTIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: PGVIGIL_VERSIONS_PARALLEL and PGVIGIL_VERSIONS_TIMEOUT are whole numbers above 0" >&2; exit 1; }
[ "${#VERSIONS[@]}" -gt 0 ] && [ "${#PROOFS[@]}" -gt 0 ] || { echo "FAIL: no version or no proof named" >&2; exit 1; }
WHOISACTIVE=${PGVIGIL_VERSIONS_WHOISACTIVE:-}
if [ -n "$WHOISACTIVE" ]; then
  [ -r "$WHOISACTIVE" ] && grep -qi 'sp_WhoIsActive' "$WHOISACTIVE" || { echo "FAIL: PGVIGIL_VERSIONS_WHOISACTIVE names no readable sp_WhoIsActive script: $WHOISACTIVE" >&2; exit 1; }
  WHOISACTIVE=$(cd "$(dirname "$WHOISACTIVE")" && pwd)/$(basename "$WHOISACTIVE")
fi
declare -A MAJOR=([2017]=14 [2019]=15 [2022]=16 [2025]=17)
for ver in "${VERSIONS[@]}"; do [ -n "${MAJOR[$ver]:-}" ] || { echo "FAIL: version $ver is not one of ${!MAJOR[*]}" >&2; exit 1; }; done
for name in "${PROOFS[@]}"; do [ -f "scripts/proof-mssql-$name.sh" ] || { echo "FAIL: no scripts/proof-mssql-$name.sh" >&2; exit 1; }; done

# the names carry a short number; the label that the cleanup removes by is 16 random hex digits, so that two runs
# on one machine that drew the same number never remove each other's containers
SUF=$RANDOM; RUN_LABEL="pgvigil.versions.run=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; AG=pgvv_ag; SEED=pgvv_seed
REPO_DB=pgvigil_verproof_$SUF; MADE_REPO=
OUT=${PGVIGIL_VERSIONS_OUT:-$(mktemp -d)}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d); LOCKS=$WORK/locks; mkdir -p "$LOCKS"
rm -f "$OUT/stop" "$OUT/summary.md" "$OUT"/*/proof.pid   # an earlier run's leftovers in a folder that is reused
pw() { printf 'Pv9%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
# the sa password of every container of this run: in the environment by name, never on a command line
MSSQL_SA_PASSWORD=$(pw); export MSSQL_SA_PASSWORD
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
# sqa <container> <sql>: one statement as sa; sqin <container>: a batch on stdin (a statement that carries a password)
# Each call ends after five minutes at most: a setup step that hangs fails its version, it never holds the others.
sqa() { timeout 300 docker exec -e SQLCMDPASSWORD "$1" "$SQLCMD" -S localhost -U sa -C -b -I -W -h -1 -s '|' -d master -Q "SET NOCOUNT ON; $2"; }
sqin() { timeout 300 docker exec -i -e SQLCMDPASSWORD "$1" "$SQLCMD" -S localhost -U sa -C -b -I -W -h -1 -d master -i /dev/stdin; }

cleanup() {
  rc=$?
  trap - EXIT INT TERM
  set +e
  # no version starts another proof; a running proof is ended through its own timeout wrapper (which hands the
  # signal to the proof, so the proof's own cleanup runs while its server is still there), then waited for
  : > "$OUT/stop"
  for pidfile in "$OUT"/*/proof.pid; do [ -f "$pidfile" ] && kill -TERM "$(cat "$pidfile")" 2>/dev/null; done
  for _ in $(seq 1 150); do [ -z "$(jobs -rp)" ] && break; sleep 1; done
  for pid in $(jobs -rp); do kill -TERM "$pid" 2>/dev/null; done
  if [ -n "${PGVIGIL_VERSIONS_KEEP:-}" ]; then
    echo "KEPT (PGVIGIL_VERSIONS_KEEP): containers $(docker ps -a --filter "label=$RUN_LABEL" --format '{{.Names}}' | tr '\n' ' '); the sa password is in each container's own environment (docker exec -it <container> bash -c 'SQLCMDPASSWORD=\$MSSQL_SA_PASSWORD $SQLCMD -S localhost -U sa -C'); remove them, their network and their volume by the label $RUN_LABEL" >&2
  else
    ids=$(docker ps -aq --filter "label=$RUN_LABEL")
    if [ -n "$ids" ]; then docker rm -f -v $ids >/dev/null 2>&1 || echo "CLEANUP: a container of this run was not removed (label $RUN_LABEL)" >&2; fi
    for vol in $(docker volume ls -q --filter "label=$RUN_LABEL"); do docker volume rm "$vol" >/dev/null 2>&1 || echo "CLEANUP: volume $vol not removed" >&2; done
    for net in $(docker network ls -q --filter "label=$RUN_LABEL"); do docker network rm "$net" >/dev/null 2>&1 || echo "CLEANUP: network $net not removed" >&2; done
  fi
  if [ -n "$MADE_REPO" ]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped" >&2; fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# one binary for every proof of every version
BIN=${PGVIGIL_BIN:-}
if [ -z "$BIN" ]; then
  BIN=$WORK/pgvigil
  CGO_ENABLED=0 go build -trimpath -o "$BIN" ./cmd/pgvigil || { echo "FAIL: the build" >&2; exit 1; }
fi
[ -x "$BIN" ] || { echo "FAIL: no binary at $BIN" >&2; exit 1; }
case $BIN in /*) ;; *) BIN=$PWD/$BIN ;; esac

# the images, pulled one after the other before anything starts (a pull inside a version's own run would count
# against that version's waits)
for ver in "${VERSIONS[@]}"; do
  docker image inspect "$IMAGE_REPO:$ver-latest" >/dev/null 2>&1 || docker pull -q "$IMAGE_REPO:$ver-latest" >/dev/null || { echo "FAIL: the image $IMAGE_REPO:$ver-latest could not be pulled" >&2; exit 1; }
done

# two ports per version, chosen here, one after the other (the versions start in parallel); freeport runs in a
# command substitution, so the caller adds what it took to TAKEN
declare -A PORT_A PORT_B
TAKEN=" "
freeport() {
  local port
  for port in $(seq 21500 21599); do
    case $TAKEN in *" $port "*) continue ;; esac
    ss -ltn | grep -qE "(127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\*):$port " && continue
    echo "$port"; return 0
  done
  return 1
}
for ver in "${VERSIONS[@]}"; do
  port=$(freeport) || { echo "FAIL: no free port between 21500 and 21599" >&2; exit 1; }; PORT_A[$ver]=$port; TAKEN="$TAKEN$port "
  port=$(freeport) || { echo "FAIL: no free port between 21500 and 21599" >&2; exit 1; }; PORT_B[$ver]=$port; TAKEN="$TAKEN$port "
done

# check C's repository and configuration: every node of every version as an instance of its own, read as sa (the
# connection string in the environment, by name)
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" || { echo "FAIL: the repository database $REPO_DB" >&2; exit 1; }
MADE_REPO=1
export PGVV_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO_DB"
CFG=$WORK/versions.yaml
{
  printf 'repository:\n  dsn: env:PGVV_REPO_DSN\ninstances:\n'
  for ver in "${VERSIONS[@]}"; do
    for node in a b; do
      if [ $node = a ]; then port=${PORT_A[$ver]}; else port=${PORT_B[$ver]}; fi
      export "PGVV_DSN_${ver}_$node=sqlserver://sa:$MSSQL_SA_PASSWORD@127.0.0.1:$port?database=master&encrypt=true&TrustServerCertificate=true"
      printf '  - name: pgvv%s%s-%s\n    engine: sqlserver\n    dsn: env:PGVV_DSN_%s_%s\n' "${ver:2:2}" "$node" "$SUF" "$ver" "$node"
    done
  done
} > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || { echo "FAIL: migrate of the repository database $REPO_DB" >&2; exit 1; }

# result <version> <step> <PASS|FAIL> <seconds> <note>: one line per step, read back for the matrix, and said at once
result() {
  printf '%s|%s|%s|%s\n' "$2" "$3" "$4" "$(printf '%s' "$5" | tr '|\n' '/ ' | cut -c1-400)" >> "$OUT/$1/results.txt"
  echo "  SQL Server $1 $2: $3 ($4 s)"
}

# boot_pair <version>: the two containers and the checks of P. Returns 1 with the reason in $WHY.
boot_pair() {
  local ver=$1 yy=${1:2:2} image="$IMAGE_REPO:$1-latest" node ct port got want
  local a="pgvv${yy}a-$SUF" b="pgvv${yy}b-$SUF" net="pgvv${yy}-$SUF" vol="pgvv${yy}-$SUF"
  docker network create --label "$RUN_LABEL" "$net" >/dev/null || { WHY="docker network create"; return 1; }
  docker volume create --label "$RUN_LABEL" "$vol" >/dev/null || { WHY="docker volume create"; return 1; }
  for node in a b; do
    if [ $node = a ]; then ct=$a; port=${PORT_A[$ver]}; else ct=$b; port=${PORT_B[$ver]}; fi
    docker run -d --name "$ct" --hostname "$ct" --network "$net" --label "$RUN_LABEL" --user root -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD \
      -e MSSQL_PID=Developer -e MSSQL_AGENT_ENABLED=true -e MSSQL_ENABLE_HADR=1 -e MSSQL_MEMORY_LIMIT_MB=4096 \
      -p "127.0.0.1:$port:1433" -v "$vol:/backups" "$image" >/dev/null || { WHY="docker run of $ct ($image)"; return 1; }
    # the proofs call /opt/mssql-tools18/bin/sqlcmd: the 2017 image has /opt/mssql-tools only
    docker exec "$ct" sh -c 'test -x /opt/mssql-tools18/bin/sqlcmd || { mkdir -p /opt/mssql-tools18/bin && ln -s /opt/mssql-tools/bin/sqlcmd /opt/mssql-tools18/bin/sqlcmd; }' \
      || { WHY="the sqlcmd link in $ct"; return 1; }
  done
  # P
  for ct in "$a" "$b"; do
    for _ in $(seq 1 120); do
      sqa "$ct" "SELECT 1" >/dev/null 2>&1 && break
      [ "$(docker inspect -f '{{.State.Running}}' "$ct" 2>/dev/null)" = true ] || break   # the server ended: no use waiting
      sleep 2
    done
    sqa "$ct" "SELECT 1" >/dev/null 2>&1 || { WHY="P: $ct never answered (container running: $(docker inspect -f '{{.State.Running}}' "$ct" 2>/dev/null || echo unknown))"; return 1; }
    for _ in $(seq 1 60); do [ "$(sqa "$ct" "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%'" 2>/dev/null)" -gt 0 ] 2>/dev/null && break; sleep 2; done
    want="${MAJOR[$ver]}|$ct|1|1"
    got=$(sqa "$ct" "SELECT CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), 4) AS varchar(4)) + '|' + @@SERVERNAME + '|' + CAST(SERVERPROPERTY('IsHadrEnabled') AS varchar(4)) + '|' + CASE WHEN EXISTS (SELECT 1 FROM sys.dm_exec_sessions WHERE program_name LIKE N'SQLAgent%') THEN '1' ELSE '0' END") \
      || { WHY="P: sa's read of $ct"; return 1; }
    [ "$got" = "$want" ] || { WHY="P: $ct reads major|server name|Always On|Agent = $got (want $want)"; return 1; }
  done
  sqa "$a" "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)) + '|' + CAST(SERVERPROPERTY('ProductLevel') AS varchar(40)) + '|' + ISNULL(CAST(SERVERPROPERTY('ProductUpdateLevel') AS varchar(40)), '') + '|' + CAST(SERVERPROPERTY('Edition') AS varchar(80))" > "$OUT/$ver/build.txt" \
    || { WHY="P: the build of $a"; return 1; }
  docker exec "$a" sh -c '. /etc/os-release; echo "$PRETTY_NAME"' > "$OUT/$ver/os.txt" 2>/dev/null || true
  return 0
}

# start_pair <version>: the pair booted (one pair at a time: with eight servers starting at once on eight CPUs a
# 2025 server ended at its start with a fatal error, errno 11 "resource temporarily unavailable"), then the checks
# C and H and the group of G. Returns 1 with the reason in $WHY.
start_pair() {
  local ver=$1 yy=${1:2:2} node ct rc=0
  local a="pgvv${yy}a-$SUF" b="pgvv${yy}b-$SUF"
  local kp cp tag other out num got
  WHY=
  exec 8>"$LOCKS/boot.lock"; flock 8
  boot_pair "$ver" || rc=$?
  exec 8>&-
  [ $rc = 0 ] || return 1
  # the master key's and the endpoint logins' passwords: random, used in G and not kept. What the server or the
  # collector answers goes to the setup log with every password of this run masked (in the shell itself: a
  # password handed to sed would ride sed's command line)
  kp=$(pw); cp=$(pw)
  mask() { local text; text=$(cat); text=${text//"$kp"/<hidden>}; text=${text//"$cp"/<hidden>}; text=${text//"$MSSQL_SA_PASSWORD"/<hidden>}; [ -z "$text" ] || printf '%s\n' "$text"; }
  # C
  for ct in "$a" "$b"; do
    num=$(sqa "$ct" "SELECT CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), 4) AS int) * 10000 + CAST(PARSENAME(CAST(SERVERPROPERTY('ProductVersion') AS varchar(40)), 3) AS int)") \
      || { WHY="C: sa's read of the version of $ct"; return 1; }
    if ! out=$("$BIN" collect -config "$CFG" -once mssql_instance -instance "$ct" 2>&1); then
      printf '%s\n' "$out" | mask
      WHY="C: the collector could not read $ct: $(printf '%s\n' "$out" | grep -m1 -o 'err=.*' | mask)"; return 1
    fi
    got=$(psql "$PGVV_REPO_DSN" -XAtq -c "select engine || '|' || platform || '|' || server_version_num from pgvigil.instances where name = '$ct'") \
      || { WHY="C: the repository's row of $ct"; return 1; }
    [ "$got" = "sqlserver|sqlserver|$num" ] || { WHY="C: the repository holds $ct as $got (want sqlserver|sqlserver|$num)"; return 1; }
    # the control: the same read with the build's setting switched off for this one call. It tells whether this
    # server's certificate has a negative serial number (recorded, never a verdict: the server makes the number)
    if out=$(GODEBUG=x509negativeserial=0 "$BIN" collect -config "$CFG" -once mssql_instance -instance "$ct" 2>&1); then
      echo "$ct no" >> "$OUT/$ver/negative-serial.txt"
    elif printf '%s\n' "$out" | grep -q 'x509: negative serial number'; then
      echo "$ct yes" >> "$OUT/$ver/negative-serial.txt"
    else
      printf '%s\n' "$out" | mask
      WHY="C: the control read of $ct failed for another reason: $(printf '%s\n' "$out" | grep -m1 -o 'err=.*' | mask)"; return 1
    fi
  done
  # a server in use, not a new one: Database Mail switched on (the services proof reads its queue and expects a
  # login without rights in msdb to be told it cannot), and sixty rows of Agent job history from yesterday for a
  # job of this run's own (the jobs read starts fifty rows behind its cursor, and a proof that counts what a second
  # read returns needs more history than that before its own rows)
  for ct in "$a" "$b"; do
    sqin "$ct" <<'SQL' 2>&1 | mask || { WHY="H: Database Mail or the seeded job history on $ct"; return 1; }
SET NOCOUNT ON;
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;
EXEC sp_configure 'show advanced options', 0; RECONFIGURE;
EXEC msdb.dbo.sysmail_start_sp;
EXEC msdb.dbo.sp_add_job @job_name = N'pgvv seed', @enabled = 1, @owner_login_name = N'sa';
EXEC msdb.dbo.sp_add_jobstep @job_name = N'pgvv seed', @step_id = 1, @step_name = N'one', @subsystem = N'TSQL', @command = N'SELECT 1;';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'pgvv seed';
DECLARE @job uniqueidentifier = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'pgvv seed'),
        @day int = CAST(CONVERT(char(8), DATEADD(day, -1, GETDATE()), 112) AS int), @run int = 0;
WHILE @run < 30
BEGIN
  INSERT msdb.dbo.sysjobhistory (job_id, step_id, step_name, sql_message_id, sql_severity, message, run_status, run_date, run_time, run_duration,
                                 operator_id_emailed, operator_id_netsent, operator_id_paged, retries_attempted, server)
  VALUES (@job, 1, N'one', 0, 0, N'Executed as user: sa. The step succeeded.', 1, @day, 10000 + @run * 100, 0, 0, 0, 0, 0, @@SERVERNAME),
         (@job, 0, N'(Job outcome)', 0, 0, N'The job succeeded.  The Job was invoked by User sa.  The last step to run was step 1 (one).', 1, @day, 10000 + @run * 100, 0, 0, 0, 0, 0, @@SERVERNAME);
  SET @run += 1;
END
SQL
    got=$(sqa "$ct" "SELECT CAST((SELECT COUNT(*) FROM msdb.dbo.sysjobhistory) AS varchar(12)) + '|' + CAST((SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Database Mail XPs') AS varchar(4))") \
      || { WHY="H: sa's read of the seed on $ct"; return 1; }
    [ "${got%%|*}" -ge 60 ] 2>/dev/null && [ "${got##*|}" = 1 ] || { WHY="H: $ct reads job history rows|Database Mail XPs = $got (want 60 or more|1)"; return 1; }
  done
  # sp_WhoIsActive, where a copy was named: the running-queries proof takes its second path only where it is installed
  if [ -n "$WHOISACTIVE" ]; then
    sqin "$a" < "$WHOISACTIVE" 2>&1 | mask || { WHY="H: sp_WhoIsActive did not install on $a"; return 1; }
    [ "$(sqa "$a" "SELECT CASE WHEN OBJECT_ID('master.dbo.sp_WhoIsActive', 'P') IS NULL THEN 0 ELSE 1 END")" = 1 ] || { WHY="H: sp_WhoIsActive is not in master on $a after its script ran"; return 1; }
  fi
  # G: certificate endpoints (each node's public certificate reaches the other through the shared /backups), then
  # the group
  for node in a b; do
    if [ $node = a ]; then ct=$a; else ct=$b; fi
    sqin "$ct" <<EOF 2>&1 | mask || { WHY="G: the endpoint of $ct"; return 1; }
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$kp';
CREATE CERTIFICATE pgvv_${node}_cert WITH SUBJECT = 'pgvigil versions proof node ${node}', EXPIRY_DATE = '20360101';
CREATE ENDPOINT pgvv_hadr STATE = STARTED AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL) FOR DATABASE_MIRRORING (AUTHENTICATION = CERTIFICATE pgvv_${node}_cert, ENCRYPTION = REQUIRED ALGORITHM AES, ROLE = ALL);
BACKUP CERTIFICATE pgvv_${node}_cert TO FILE = '/backups/pgvv_${node}_$SUF.cer';
EOF
  done
  for node in a b; do
    if [ $node = a ]; then ct=$a; other=b; else ct=$b; other=a; fi
    tag=pgvv_${other}
    sqin "$ct" <<EOF 2>&1 | mask || { WHY="G: the other node's certificate on $ct"; return 1; }
CREATE LOGIN ${tag}_login WITH PASSWORD = '$cp', CHECK_POLICY = OFF;
CREATE USER ${tag}_user FOR LOGIN ${tag}_login;
CREATE CERTIFICATE ${tag}_cert AUTHORIZATION ${tag}_user FROM FILE = '/backups/${tag}_$SUF.cer';
GRANT CONNECT ON ENDPOINT::pgvv_hadr TO ${tag}_login;
EOF
  done
  sqa "$a" "CREATE DATABASE [$SEED]; ALTER DATABASE [$SEED] SET RECOVERY FULL; BACKUP DATABASE [$SEED] TO DISK = N'/backups/${SEED}_$SUF.bak' WITH INIT;" \
    || { WHY="G: the seed database on $a"; return 1; }
  sqa "$a" "CREATE AVAILABILITY GROUP [$AG] WITH (CLUSTER_TYPE = NONE, DB_FAILOVER = ON) FOR DATABASE [$SEED] REPLICA ON
 N'$a' WITH (ENDPOINT_URL = N'TCP://$a:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)),
 N'$b' WITH (ENDPOINT_URL = N'TCP://$b:5022', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL));" \
    || { WHY="G: CREATE AVAILABILITY GROUP on $a"; return 1; }
  sqa "$b" "ALTER AVAILABILITY GROUP [$AG] JOIN WITH (CLUSTER_TYPE = NONE); ALTER AVAILABILITY GROUP [$AG] GRANT CREATE ANY DATABASE;" \
    || { WHY="G: the join on $b"; return 1; }
  # the AlwaysOn_health session, which a wizard-made group starts and a group made by statement does not (the
  # Extended Events proof reads the group's events from it and skips that part where it is stopped)
  for ct in "$a" "$b"; do
    sqa "$ct" "IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'AlwaysOn_health') ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START;" \
      || { WHY="G: the AlwaysOn_health session on $ct"; return 1; }
  done
  local state=
  for _ in $(seq 1 100); do
    state=$(sqa "$a" "SELECT ISNULL((SELECT TOP (1) drs.synchronization_state_desc + ':' + drs.synchronization_health_desc FROM sys.availability_replicas ar JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ar.replica_id WHERE ar.replica_server_name = N'$b' AND drs.database_id = DB_ID(N'$SEED')), 'none')" 2>/dev/null || true)
    [ "$state" = "SYNCHRONIZED:HEALTHY" ] && break; sleep 3
  done
  if [ "$state" != "SYNCHRONIZED:HEALTHY" ]; then
    sqa "$a" "SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.last_connect_error_number, ars.last_connect_error_description FROM sys.availability_replicas ar LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id" || true
    sqa "$b" "SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.last_connect_error_number, ars.last_connect_error_description FROM sys.availability_replicas ar LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id" || true
    sqa "$a" "SELECT start_time, current_state, failure_state_desc, error_code FROM sys.dm_hadr_automatic_seeding" || true
    WHY="G: the seed database on $b reads '$state' after 5 minutes (want SYNCHRONIZED:HEALTHY)"; return 1
  fi
  return 0
}

# run_proof <version> <proof>: one proof against the version's pair, its output in <out>/<version>/<proof>.log.
# The lock: one proof never runs on two versions at once. The proof (and what it leaves in the background) never
# holds the lock's descriptor.
run_proof() {
  local ver=$1 name=$2 yy=${1:2:2} rc=0 t0 note lock
  local a="pgvv${yy}a-$SUF" b="pgvv${yy}b-$SUF" log="$OUT/$1/$2.log"
  local addr_a="127.0.0.1:${PORT_A[$ver]}" addr_b="127.0.0.1:${PORT_B[$ver]}"
  # reads and querystore take their UI port from one range (18290-18330): one lock for the two
  case $name in reads|querystore) lock=ui-18290 ;; *) lock=$name ;; esac
  exec 9>"$LOCKS/$lock.lock"; flock 9
  if [ -e "$OUT/stop" ]; then exec 9>&-; return 0; fi
  t0=$SECONDS
  PGVIGIL_BIN="$BIN" PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=postgres" PGVIGIL_MSSQL_AG="$AG" \
    PGVIGIL_MSSQL_CONTAINER="$a" PGVIGIL_MSSQL_ADDR="$addr_a" PGVIGIL_MSSQL_CONTAINER2="$b" PGVIGIL_MSSQL_ADDR2="$addr_b" \
    PGVIGIL_MSSQL_CONTAINERS="$a $b" PGVIGIL_MSSQL_ADDRS="$addr_a $addr_b" \
    timeout -k 120 "$PTIMEOUT" bash "scripts/proof-mssql-$name.sh" >"$log" 2>&1 9>&- &
  echo $! > "$OUT/$ver/proof.pid"
  if [ -e "$OUT/stop" ]; then kill -TERM $! 2>/dev/null || true; fi   # the run was ended between the check above and this line
  wait $! || rc=$?
  rm -f "$OUT/$ver/proof.pid"
  exec 9>&-
  if [ $rc = 0 ]; then
    result "$ver" "$name" PASS $((SECONDS - t0)) "$(grep -v '^[[:space:]]*$' "$log" | tail -1)"
    # what the proof itself says it left out on this server (its exit code does not): listed under the matrix
    grep -E 'SKIPPED|NOT RUN|NOT PROVEN|not proven|not run' "$log" | cut -c1-300 > "$OUT/$ver/$name.left-out.txt" || true
  else
    note=$(grep -m1 -E '^FAIL' "$log" || true)
    [ -n "$note" ] || note=$(grep -m1 -E 'level=ERROR|^Msg [0-9]+, Level 1[1-9]' -A1 "$log" | tr '\n' ' ' || true)
    [ -n "$note" ] || note=$(grep -v '^[[:space:]]*$' "$log" | tail -1 || true)
    if [ -e "$OUT/stop" ]; then note="ended with the run; $note"
    elif [ $rc = 124 ] || [ $rc = 137 ]; then note="over $PTIMEOUT s, ended; $note"; fi
    result "$ver" "$name" FAIL $((SECONDS - t0)) "exit $rc: $note"
  fi
}

# run_version <version> <first proof's index>: the pair, then every proof, the list turned so that the versions
# running side by side start at different proofs
run_version() {
  local ver=$1 first=$2 idx node t0=$SECONDS
  mkdir -p "$OUT/$ver"; : > "$OUT/$ver/results.txt"; rm -f "$OUT/$ver/negative-serial.txt" "$OUT/$ver/build.txt" "$OUT/$ver/os.txt" "$OUT/$ver"/*.left-out.txt
  if start_pair "$ver" > "$OUT/$ver/setup.log" 2>&1; then
    result "$ver" setup PASS $((SECONDS - t0)) "$(cat "$OUT/$ver/build.txt")"
  else
    result "$ver" setup FAIL $((SECONDS - t0)) "$WHY"
    # what each server logged, kept beside the setup log: the containers are gone when the run ends
    for node in a b; do docker logs --tail 120 "pgvv${ver:2:2}$node-$SUF" > "$OUT/$ver/setup-node-$node.log" 2>&1 || true; done
    return 0
  fi
  for idx in $(seq 0 $((${#PROOFS[@]} - 1))); do
    [ -e "$OUT/stop" ] && return 0
    run_proof "$ver" "${PROOFS[$(((first + idx) % ${#PROOFS[@]}))]}"
  done
}

echo "proof-mssql-versions: ${VERSIONS[*]} x ${PROOFS[*]}; $PARALLEL at once; logs in $OUT; this run's label $RUN_LABEL"
vi=0
for ver in "${VERSIONS[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n || true; done
  run_version "$ver" $((vi * ${#PROOFS[@]} / ${#VERSIONS[@]})) &
  vi=$((vi + 1))
done
wait

echo "--- S. proof-mssql-summary.sh (no SQL Server), once"
SUMMARY=PASS
PGVIGIL_BIN="$BIN" timeout -k 120 "$PTIMEOUT" bash scripts/proof-mssql-summary.sh > "$OUT/summary.log" 2>&1 || SUMMARY=FAIL
echo "S: $SUMMARY ($(grep -v '^[[:space:]]*$' "$OUT/summary.log" | tail -1))"

# the matrix, on the screen and in summary.md (the table docs/sqlserver.md is written from)
readfile() { if [ -f "$1" ]; then tr '|' ' ' < "$1"; else echo '-'; fi; }
cell() { awk -F'|' -v step="$2" '$1 == step { print $2; found = 1 } END { if (!found) print "NOT RUN" }' "$OUT/$1/results.txt"; }
BAD=0
{
  printf '| proof |'; for ver in "${VERSIONS[@]}"; do printf ' SQL Server %s |' "$ver"; done; printf '\n'
  printf '| --- |'; for ver in "${VERSIONS[@]}"; do printf ' --- |'; done; printf '\n'
  printf '| build |'; for ver in "${VERSIONS[@]}"; do printf ' %s |' "$(readfile "$OUT/$ver/build.txt")"; done; printf '\n'
  printf '| image |'; for ver in "${VERSIONS[@]}"; do printf ' %s, %s |' "$IMAGE_REPO:$ver-latest" "$(readfile "$OUT/$ver/os.txt")"; done; printf '\n'
  printf '| certificate serial negative (node a, node b) |'; for ver in "${VERSIONS[@]}"; do printf ' %s |' "$(if [ -f "$OUT/$ver/negative-serial.txt" ]; then awk '{ print $2 }' "$OUT/$ver/negative-serial.txt" | paste -sd, -; else echo '-'; fi)"; done; printf '\n'
  for name in setup "${PROOFS[@]}"; do
    printf '| %s |' "$name"; for ver in "${VERSIONS[@]}"; do printf ' %s |' "$(cell "$ver" "$name")"; done; printf '\n'
  done
} > "$OUT/summary.md"
cat "$OUT/summary.md"
echo "--- what the passed proofs themselves left out or name as not proven (a PASS is a proof's exit code)"
for ver in "${VERSIONS[@]}"; do
  for name in "${PROOFS[@]}"; do
    [ -s "$OUT/$ver/$name.left-out.txt" ] || continue
    while IFS= read -r line; do echo "  SQL Server $ver, $name: $line"; done < "$OUT/$ver/$name.left-out.txt"
  done
done | tee "$OUT/left-out.txt"
for ver in "${VERSIONS[@]}"; do
  for name in setup "${PROOFS[@]}"; do
    verdict=$(cell "$ver" "$name")
    [ "$verdict" = PASS ] && continue
    BAD=$((BAD + 1))
    if [ "$verdict" = "NOT RUN" ]; then echo "FAILED CELL: SQL Server $ver, $name: NOT RUN (the setup failed, or the run was ended)"; continue; fi
    echo "FAILED CELL: SQL Server $ver, $name: $verdict: $(awk -F'|' -v step="$name" '$1 == step { print $4 }' "$OUT/$ver/results.txt") (log: $OUT/$ver/$name.log)"
  done
done
[ "$SUMMARY" = PASS ] || BAD=$((BAD + 1))
if [ $BAD -gt 0 ]; then
  echo "proof-mssql-versions: FAIL ($BAD failed or not run of $((${#VERSIONS[@]} * (${#PROOFS[@]} + 1) + 1)) cells; logs in $OUT)"
  exit 1
fi
echo "proof-mssql-versions: PASS (${VERSIONS[*]}; ${#PROOFS[@]} proofs on each, summary once; logs in $OUT)"
