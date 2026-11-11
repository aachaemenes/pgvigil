#!/usr/bin/env bash
# Proof of pgvigil's monitoring of a SQL Server DISTRIBUTED availability group (task 160): the lab of
# scripts/dag/trial.sh (four SQL Server containers: ag1 on d1a + d1b, ag2 on d2a + d2b, both clusterless, and the
# distributed group dag1 over them, database dagdb), pgvigil's own collector reading all four nodes into a throwaway
# repository, and what pgvigil then STORES and SHOWS graded against what sa reads on the nodes.
#
# Needs: docker, openssl, psql, curl, python3, rsync, setsid, a go toolchain, node and npm with web/node_modules ('npm
# ci' in web/ first), chromium, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...).
#   PGVIGIL_BIN        optional: a built binary with its bundle, instead of the build of this tree.
# The nodes publish no port: the collector reaches each at its address on the lab's Docker network, as a monitoring
# login of the proof's own (one SID on all four nodes; VIEW SERVER STATE and VIEW ANY DEFINITION, nothing else; sa is
# never in pgvigil's configuration). Nothing has to resolve the names d1a ... d2b: pgvigil ties the groups by their
# ids, never by a server's name.
#
# What it makes, and removes at the end on every exit path: the lab (its containers and network, by scripts/dag/trial.sh
# down, read back: 0 containers, 0 networks, 0 volumes), its own repository database, a temporary folder with the build.
# What stays: the repository's migration creates the cluster-wide NOLOGIN roles pgvigil_collector, pgvigil_reader,
# pgvigil_auth and pgvigil_alerter on the PostgreSQL server where they do not exist yet, as every pgvigil proof does.
#
# The lead's wiring (internal/web/q_mssql_hadr.go: the part "distributed" of /api/mssql/availability): where the tree
# does not have it yet, the build is made in a temporary copy with scripts/dag/wiring-q_mssql_hadr.patch applied, and
# the proof says so. The web bundle is always built from this tree's web/src (in the copy: the committed bundle is not
# touched).
#
# Expected (each written before the run that first tested it; read on the lab's nodes with sa on 2026-11-11, SQL Server
# 2022 16.0.4315):
#  A. the lab forms ('DAG FORMED'); the monitoring login exists on the four nodes with one SID and is no sysadmin.
#     dagdb has another database id on d2a than on d1a (the lab's filler database), and the link's row on d1a carries
#     d1a's OWN id of dagdb: what the collector joins and names by is the local id.
#  B. one read of mssql_ag per node, none partial or skipped. Stored:
#     d1a (the global primary)  dag1 with sa's group id, is_distributed, two member rows: ag1 PRIMARY, CONNECTED, local;
#                               ag2 SECONDARY, CONNECTED, HEALTHY, not local; primary ag1. ONE database row of dag1: ag2 /
#                               dagdb, not local, with a send queue, a redo queue, a lag (secondary_lag_s) and an
#                               estimated data loss (the collector's fix: it was NULL before).
#     d2a (the forwarder)       dag1 with the SAME group id: ag2 SECONDARY, CONNECTED, local; ag1 with no role (not
#                               visible from there); primary ag1. No database row of dag1.
#     d1b, d2b (secondaries)    no row of dag1 at all; their own group with themselves SECONDARY.
#     In the repository the four instances hold ONE distributed group (one group id), in 4 rows.
#     The plain groups under it are read as before the fix: on d1a ag1's rows are d1a without an estimated data loss
#     (a primary's own row) and d1b with one; on d2a the same for ag2; on d1b and d2b their own row, without one.
#     TestAgDistributedLive passes on each node for its side (global, forwarder, secondary, secondary): no database
#     row read twice, the plain groups' estimates as above, and on the global primary the link's estimate within 3 s
#     of the local primary's last commit less the link row's, read from the views again.
#  C. the tie. /api/mssql/availability?part=distributed answers the same tree for each of the four instances: dag1
#     over ag1 (PRIMARY) with d1a 'global primary' and d1b 'secondary', and ag2 (SECONDARY, CONNECTED) with d2a
#     'forwarder' and d2b 'secondary', each replica with the monitored instance it is, the asked instance's own
#     replica marked. So d2b, which stores nothing of dag1, is tied to it through its own group ag2.
#  D. the link under a write load (600,000 rows written on d1a while d1a is read back to back): every sample of dag1 /
#     ag2 / dagdb in mssql_ag_sample carries a send queue and an estimated data loss (numbers, never NULL), and the
#     largest redo queue among them is above 0 (the trial read 5,836 to 20,644 KB at every read under this load).
#     Within 60 s after the load (one bound for both) the link's queues are stored, both under 1,000 KB, and d2b
#     counts as many rows as d1a.
#  E. a suspended database (dagdb's data movement suspended on the forwarder). On d1a: dag1 / ag2 / dagdb stored as
#     suspended; findings 'a database is suspended' [dag1 / ag2 / dagdb] and 'a replica is not healthy' [dag1 / ag2],
#     both critical. On d2a: 'a database is suspended' [ag2 / d2a / dagdb]. On d2b: 'a database is not synchronizing'
#     [ag2 / d2b / dagdb]. After rows written on d1a the link's estimated data loss and its lag are both 2 s or more,
#     and TestAgDistributedLive on d1a finds the estimate within 3 s of the views' own times (a gap of seconds now).
#     The undo (RESUME): within 90 s no instance has a finding and the link is SYNCHRONIZING, not suspended.
#  F. the forwarder node stopped (docker stop d2a). On d1a: 'a replica is not connected' [dag1 / ag2] and 'a database
#     is not synchronizing' [dag1 / ag2 / dagdb], critical. On d2b: 'a replica is not connected' [ag2 / d2b]. The read
#     of d2a fails and stores nothing (its rows keep their last read's time). The tree asked on d1a says ag2 is
#     DISCONNECTED (the global primary's read of the link wins over the forwarder's own last read). The undo (docker
#     start): within 120 s no instance has a finding, d2a is read again, primary of ag2 and SECONDARY of dag1.
#  G. the second group's secondary stopped (docker stop d2b). On d2a: 'a replica is not connected' [ag2 / d2b],
#     critical. On d1a: NOTHING, at the read that first shows it on d2a and again 10 s later - the global primary does
#     not see it, which is why the forwarder is monitored too. The undo (docker start): within 120 s no instance has a
#     finding.
#  H. a planned failover of dag1 to ag2 by Microsoft's sequence for SQL Server 2022: both sides SYNCHRONOUS_COMMIT, the
#     link SYNCHRONIZED, REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1 (read back), the last hardened LSN of dagdb
#     equal - and the same at two reads 2 s apart - on d1b (the global primary's own secondary, its own row), on d1a's
#     row of the link and on d2a (the forwarder, its own row); ROLE = SECONDARY on d1a; d1b's and d2a's own rows equal
#     and steady again; FORCE_FAILOVER_ALLOW_DATA_LOSS on d2a, the setting back to 0 on d1a (read back). The global
#     primary's OWN row is not compared: it reads one log block behind its secondaries (read on the lab: 3448 on d1a's
#     own row with 3456 on d1b, on the link and on d2a), so it can equal the forwarder's while the forwarder lacks a
#     block d1b has; forced in that state, d1b stays REVERTING (undoing that block). d1a's own row is printed with each
#     check. Not seen by the check: a log block on d1a alone (neither d1b nor d2a has it) - the views give no reading
#     that tells it apart (d1a's own row has read both one block behind d1b and equal to it before a clean failover).
#     Then Microsoft's optional step 9: both sides asynchronous again. Seen as a role change, within 120 s of the force
#     in both primaries' own reads (the new forwarder's own member row reads DISCONNECTED for some seconds first): on d2a dag1 is ag2 PRIMARY (local) over ag1 SECONDARY, CONNECTED, primary ag2, and the
#     link's database row (dag1 / ag1 / dagdb, with its estimated data loss) is now d2a's; on d1a dag1 is ag1 SECONDARY
#     (local), ag2 with no role, primary ag2, no database row of dag1. mssql_ag_failovers holds exactly one row for
#     dag1 on d1a and one on d2a, 'ag1>ag2', and none for ag1 or ag2 on any instance (no member group changed its own
#     primary, in this step or in F and G); the finding 'the primary of a group changed' [dag1] (critical) is on both.
#     The tree: d2a 'global primary', d1a 'forwarder'. Within 120 s the link dag1 / ag1 / dagdb is SYNCHRONIZED on d2a
#     and ag1's secondary d1b SYNCHRONIZED on d1a; a row written on d2a is then read on d1b within 60 s. After step 9
#     the link on d2a is stored ASYNCHRONOUS_COMMIT and SYNCHRONIZING within 60 s, and the API's databases of d2a carry
#     each row's commit mode (the link asynchronous, ag2's secondary d2b synchronous).
#  I. stubbed rows through the import (three cases the lab does not stage):
#     1. only the global primary is monitored: the other member group comes as one row, no replica, its listener named.
#     2. the old global primary no longer answers (its last read is ten minutes old and names itself PRIMARY) and the
#        other side's fresh read names itself the group's primary and gives the old side no role: ONE global primary
#        (the fresh side's), the old side's member group SECONDARY with its primary a 'forwarder', its two replicas
#        marked stale, and no state of the link taken from the old read (none is shown).
#     3. a ten-minute-old read of a global primary that says the link is CONNECTED against the forwarder's fresh read
#        that says DISCONNECTED: DISCONNECTED.
#  J. the page, in a headless Chromium, after the failover: the Availability tab of d2a, of d1a and of d2b each draws
#     dag1 ONCE, as a tree over ag2 [PRIMARY] (d2a global primary, d2b secondary) and ag1 [SECONDARY] (d1a forwarder,
#     d1b secondary), the page's own server marked, above the member group's own section, which says 'member of the
#     distributed group dag1'; the heading's card names the global primary 'd2a (primary of ag2)' and the forwarder
#     'd1a (primary of ag1)'; on d2b's page d2a links to its instance's Availability tab; on a primary's page the
#     Replicas grid says '<group> (member group)'; no member group is marked stale. The page of the stub of case I.2
#     draws ONE global primary, marks the old side's member group 'stale: its replicas as last read ...' and names the
#     forwarder with ', as last read ...', and its Databases grid marks the database of its synchronous secondary that
#     is SYNCHRONIZING with the class warn (the lab's d2a page: the asynchronous link SYNCHRONIZING, no class). The tree
#     is read twice, from the words drawn and from the nodes' own
#     attributes, and both must be the expected one. No error on any of the four pages: no error box, no read marked
#     error, partial or skipped, no exception in the page's script.
#  K. everything removed: the lab read back as 0 containers, 0 networks, 0 volumes; the repository database dropped.
#  NOT PROVEN HERE: a distributed group over Windows clusters with listeners (the lab is clusterless: each side's
#  LISTENER_URL is its primary's endpoint); a forced failover with data loss; a failover INSIDE a member group while it
#  is in the distributed group; a member group whose primary is not monitored on a live server (J proves it over
#  stubbed rows); a queue held over its threshold for five minutes; SQL Server 2016 to 2019 and 2025.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail() { echo "FAIL: $*" >&2; exit 1; }
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR
: "${PGVIGIL_REPO_DSN:?a superuser connection to a PostgreSQL sandbox, in keyword form}"
for t in docker openssl psql curl python3 rsync go node npm chromium setsid; do command -v $t >/dev/null || fail "$t is not on this machine"; done
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
TAG="pgvdagp$(openssl rand -hex 4)"; NODES=(d1a d1b d2a d2b)
SA="S$(openssl rand -hex 14)!a"; MP="Pv9$(openssl rand -hex 16)"; LM="pgvdag_mon_$SUF"; SID="0x9A$(openssl rand -hex 15 | tr a-f A-F)"
REPO_DB=pgvigil_dagproof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out; LOG=$WORK/serve.log
LAB=; MADE_REPO=; SRVPID=; CHRPID=; LOADPID=; SQLCMD=()
declare -A N I
for n in "${NODES[@]}"; do N[$n]="dagproof-$n-$SUF"; done
# stop_browser: this run's Chromium and nothing else. It is started in a process group of its own (setsid), so the
# group is the browser this run started with its helpers, also behind a launcher that does not exec; no process is
# ever looked up by name. It is gone before its profile folder is removed.
stop_browser() { if [ -n "$CHRPID" ]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  CHRPID=; }
cleanup() {
  rc=$?
  trap - ERR; set +e
  [ -n "$SRVPID" ] && { kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null; }
  stop_browser
  [ -n "$LOADPID" ] && { kill "$LOADPID" 2>/dev/null; wait "$LOADPID" 2>/dev/null; }
  if [ -n "$LAB" ]; then bash scripts/dag/trial.sh down "$TAG" || { echo "CLEANUP: the lab $TAG is not removed in full" >&2; [ $rc = 0 ] && rc=1; }; fi
  if [ -n "$MADE_REPO" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || { echo "CLEANUP: database $REPO_DB not dropped" >&2; [ $rc = 0 ] && rc=1; }; fi
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
ct() { echo "$TAG-$1"; }
# Q <node> <sql>: one batch on a node as sa; the passwords travel in the environment of the exec, by name ($(MP) in a
# batch is the monitoring login's password as a sqlcmd variable)
Q() { SQLCMDPASSWORD="$SA" MP="$MP" docker exec -e SQLCMDPASSWORD -e MP "$(ct "$1")" "${SQLCMD[@]}" -S localhost -U sa -b -h -1 -W -s '|' -Q "SET NOCOUNT ON; $2"; }
# X <node> <what the step is> <sql>: a statement that changes the lab; refused = the server's own message, then FAIL
X() { local out
  if ! out=$(Q "$1" "$3" 2>&1); then printf '%s\n' "$out" | sed "s/$SA/<sa>/g; s/$MP/<password>/g" >&2; fail "$2 (on $1) was refused"; fi; }
# until_q <tries> <seconds> <node> <want> <sql>: sa's one value on a node, read until it is <want>; the last read in
# $GOT (a read that failed: 'unread: ' and the server's message)
until_q() { local tries=$1 pause=$2 node=$3 want=$4 sql=$5
  for _ in $(seq 1 "$tries"); do
    GOT=$(Q "$node" "$sql" 2>&1) || GOT="unread: ${GOT//$'\n'/ }"
    if [ "$GOT" = "$want" ]; then return 0; fi
    sleep "$pause"
  done
  return 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
addr() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(ct "$1")"; }
dsnvar() { echo "MSSQL_DAG_${1^^}_DSN"; }
setdsn() { local ip; ip=$(addr "$1"); [ -n "$ip" ] || fail "$1 has no address on the lab's network"
  export "$(dsnvar "$1")=sqlserver://$LM:$MP@$ip:1433?database=master&encrypt=true&TrustServerCertificate=true&dial+timeout=5"; }
# read1 <node>: one read of mssql_ag; must be whole
read1() { "$BIN" collect -config "$CFG" -once mssql_ag -instance "${N[$1]}" >"$OUT" 2>&1 || { cat "$OUT"; fail "the read of $1 failed"; }
  if grep -q "partial\|skipped" "$OUT"; then cat "$OUT"; fail "the read of $1 is partial or skipped"; fi; }
readall() { local n; for n in "$@"; do read1 "$n"; done; }
# livetest <node> <side>: TestAgDistributedLive on the node as the monitoring login, for the side the node has in dag1
livetest() { local v; v=$(dsnvar "$1")
  PGVIGIL_MSSQL_TEST_DSN="${!v}" PGVIGIL_MSSQL_TEST_DAG="dag1:$2" go test ./internal/mssql -run 'TestAgDistributedLive' -count=1 -v >"$OUT" 2>&1 || { sed "s/$MP/<password>/g" "$OUT"; fail "TestAgDistributedLive on $1 as the $2 node"; }
  grep -q "^--- PASS: TestAgDistributedLive" "$OUT" || { sed "s/$MP/<password>/g" "$OUT"; fail "TestAgDistributedLive did not run on $1"; }; }
# sa_states <node>...: what sa reads of every database replica on a node (for a failure's message)
sa_states() { local n; for n in "$@"; do echo "  sa on $n:"; Q "$n" "SELECT '    ' + ISNULL(ag.name, '?') + ' / ' + ISNULL(ar.replica_server_name, '?') + ' / ' + ISNULL(DB_NAME(drs.database_id), '?') + ' local=' + CAST(drs.is_local AS varchar(1)) + ' ' + ISNULL(drs.synchronization_state_desc, '-') + ' ' + ISNULL(drs.synchronization_health_desc, '-') + ' suspended=' + ISNULL(CAST(drs.is_suspended AS varchar(1)), '-') + ISNULL(' (' + drs.suspend_reason_desc + ')', '') + ' lsn=' + ISNULL(CAST(drs.last_hardened_lsn AS varchar(30)), '-') FROM sys.dm_hadr_database_replica_states drs LEFT JOIN sys.availability_groups ag ON ag.group_id = drs.group_id LEFT JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id ORDER BY ag.name, ar.replica_server_name" 2>&1 || true; done; }
# findings <node>: the instance's HA/DR findings as 'severity:finding [object]; ...', or none
findings() { q "select coalesce(string_agg(severity || ':' || check_name || ' [' || object || ']', '; ' order by check_name, object), 'none') from pgvigil.mssql_hadr_findings where instance_id=${I[$1]}"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# members <node>: dag1's member rows as the instance stores them
members() { q "select coalesce(string_agg(replica_server || ':' || coalesce(role, '-') || ':' || coalesce(connected_state, '-') || ':' || is_local, ' ' order by replica_server), 'none') || ' primary=' || coalesce(min(primary_replica), '-') from pgvigil.mssql_ag_state where instance_id=${I[$1]} and group_name='dag1'"; }
api() { local code; code=$(curl -s -o "$LOG.body" -w '%{http_code}' "$U/api/$1"); [ "$code" = 200 ] || fail "/api/$1 answered $code: $(cat "$LOG.body")"; cat "$LOG.body"; }
# tree_of <node>: the API's part "distributed" for the instance, one line
tree_of() { api "mssql/availability?instance=${I[$1]}&part=distributed" | python3 -c '
import json, sys
t = json.load(sys.stdin).get("distributed") or {"columns": [], "rows": []}
rows = [dict(zip(t["columns"], r)) for r in t["rows"]]
print("; ".join("%s: %s[%s %s]/%s=%s@%s%s" % (r["dag_name"], r["member"], r["member_role"], r["member_connected"], r["replica_server"],
      r["dag_role"], r["replica_instance"], "*" if r["is_this_instance"] else "") for r in rows) or "none")'; }
# tree <asked node> <global primary node> <forwarder node> <the secondary member group's connected state>: the tree expected
tree() { local me=$1 gp=$2 fw=$3 link=$4 out= side mrole prole n role star
  for side in "$gp" "$fw"; do
    if [ "$side" = "$gp" ]; then mrole="PRIMARY CONNECTED"; prole="global primary"; else mrole="SECONDARY $link"; prole=forwarder; fi
    for n in "$side" "d${side:1:1}b"; do
      if [ "$n" = "$side" ]; then role=$prole; else role=secondary; fi
      if [ "$n" = "$me" ]; then star='*'; else star=; fi
      out+="${out:+; }dag1: ag${side:1:1}[$mrole]/$n=$role@${N[$n]}$star"
    done
  done
  echo "$out"; }
# settle <seconds> <what> <nodes to read each round> -- <command that must succeed>
settle() { local limit=$1 what=$2; shift 2; local nodes=() t0=$SECONDS
  while [ "$1" != -- ]; do nodes+=("$1"); shift; done; shift
  while :; do
    readall "${nodes[@]}"
    if "$@"; then
      if [ $((SECONDS - t0)) -le "$limit" ]; then echo "  $what after $((SECONDS - t0)) s"; return 0; fi
      echo "  $what only after $((SECONDS - t0)) s: past the $limit s allowed"; return 1
    fi
    if [ $((SECONDS - t0)) -ge "$limit" ]; then return 1; fi
    sleep 3
  done; }
quiet() { local n; for n in "${NODES[@]}"; do [ "$(findings "$n")" = none ] || return 1; done; }

# ---- the binary: this tree's web bundle and the wiring, built in a temporary copy
if [ -n "${PGVIGIL_BIN:-}" ]; then
  BIN=$PGVIGIL_BIN; WIRED="a given binary"
else
  [ -d web/node_modules ] || fail "no web/node_modules: run 'npm ci' in web/ first"
  rsync -a --exclude node_modules --exclude bin --exclude .git ./ "$WORK/src/"
  ln -s "$PWD/web/node_modules" "$WORK/src/web/node_modules"
  if grep -q 'sqlMSSQLAgDistributed' internal/web/q_mssql_hadr.go; then
    WIRED="wired in this tree"
  else
    (cd "$WORK/src" && { git apply --whitespace=nowarn scripts/dag/wiring-q_mssql_hadr.patch 2>/dev/null || patch -p1 -s < scripts/dag/wiring-q_mssql_hadr.patch; }) \
      || fail "scripts/dag/wiring-q_mssql_hadr.patch no longer applies to internal/web/q_mssql_hadr.go"
    WIRED="wired in a temporary copy (scripts/dag/wiring-q_mssql_hadr.patch: the join applies the same patch)"
  fi
  (cd "$WORK/src/web" && npm run build >"$WORK/web.log" 2>&1) || { tail -30 "$WORK/web.log"; fail "the web build"; }
  (cd "$WORK/src" && CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil) || fail "the go build"
  BIN=$WORK/pgvigil
fi
echo "binary: $WIRED"

echo "--- A. the lab, and the monitoring login"
LAB=1
KEEP=1 PGVIGIL_DAG_TAG="$TAG" PGVIGIL_DAG_SA="$SA" bash scripts/dag/trial.sh 2>&1 | tee "$OUT" || fail "A: the lab did not form (the line above says why)"
grep -qx 'DAG FORMED' "$OUT" || fail "A: no 'DAG FORMED' line"
if docker exec "$(ct d1a)" test -x /opt/mssql-tools18/bin/sqlcmd; then SQLCMD=(/opt/mssql-tools18/bin/sqlcmd -C); else SQLCMD=(/opt/mssql-tools/bin/sqlcmd); fi
for n in "${NODES[@]}"; do
  X "$n" "A: the monitoring login" "CREATE LOGIN [$LM] WITH PASSWORD = '\$(MP)', SID = $SID, CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$LM]; GRANT VIEW ANY DEFINITION TO [$LM];"
  got=$(Q "$n" "SELECT CONVERT(varchar(40), SUSER_SID('$LM'), 1) + '|' + CAST(IS_SRVROLEMEMBER('sysadmin', '$LM') AS varchar(2))")
  [ "$got" = "$SID|0" ] || fail "A: the monitoring login on $n is '$got' (want its SID and no sysadmin: <sid>|0)"
  setdsn "$n"
done
echo "  the monitoring login is on the four nodes with one SID, no sysadmin"
DAGID=$(Q d1a "SELECT LOWER(CAST(group_id AS varchar(36))) FROM sys.availability_groups WHERE name = 'dag1'")
[ "$(Q d2a "SELECT LOWER(CAST(group_id AS varchar(36))) FROM sys.availability_groups WHERE name = 'dag1'")" = "$DAGID" ] || fail "A: dag1 has another group id on d2a than on d1a (the proof's premise)"
IDS="$(Q d1a "SELECT CAST(drs.database_id AS varchar(10)) + '|' + CAST(DB_ID('dagdb') AS varchar(10)) FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_groups ag ON ag.group_id = drs.group_id WHERE ag.name = 'dag1'")|$(Q d2a "SELECT CAST(DB_ID('dagdb') AS varchar(10))")"
echo "  database id of the link's row on d1a | of dagdb on d1a | of dagdb on d2a: $IDS"
IFS='|' read -r LINKID ID1 ID2 <<<"$IDS"
[ -n "$LINKID" ] && [ "$LINKID" = "$ID1" ] && [ "$ID1" != "$ID2" ] || fail "A: the link's row on d1a does not carry d1a's own database id of dagdb, or dagdb has one id on both groups"
echo "A: OK"

psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB"; MADE_REPO=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
{ echo "repository:"; echo "  dsn: env:PGVIGIL_REPO_DSN"; echo "instances:"
  for n in "${NODES[@]}"; do echo "  - name: ${N[$n]}"; echo "    engine: sqlserver"; echo "    dsn: env:$(dsnvar "$n")"; done; } > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null

echo "--- B. one read per node, as the monitoring login: what is stored"
readall "${NODES[@]}"
for n in "${NODES[@]}"; do I[$n]=$(q "select instance_id from pgvigil.instances where name='${N[$n]}'"); [ -n "${I[$n]}" ] || fail "B: no instance for $n"; done
ALL="${I[d1a]}, ${I[d1b]}, ${I[d2a]}, ${I[d2b]}"
echo "  d1a stores dag1 as: $(members d1a)"; echo "  d2a stores dag1 as: $(members d2a)"
[ "$(members d1a)" = "ag1:PRIMARY:CONNECTED:true ag2:SECONDARY:CONNECTED:false primary=ag1" ] || fail "B: dag1 on the global primary"
[ "$(members d2a)" = "ag1:-:-:false ag2:SECONDARY:CONNECTED:true primary=ag1" ] || fail "B: dag1 on the forwarder"
[ "$(q "select synchronization_health from pgvigil.mssql_ag_state where instance_id=${I[d1a]} and group_name='dag1' and replica_server='ag2'")" = HEALTHY ] || fail "B: the health of ag2 as the global primary reads it"
[ "$(q "select count(distinct lower(group_id)) || '|' || count(*) || '|' || bool_and(lower(group_id) = '$DAGID') || '|' || bool_and(group_name = 'dag1') from pgvigil.mssql_ag_state where instance_id in ($ALL) and is_distributed")" = "1|4|true|true" ] \
  || fail "B: the four instances do not hold ONE distributed group in 4 rows with sa's group id: $(q "select instance_id, group_id, group_name, replica_server from pgvigil.mssql_ag_state where instance_id in ($ALL) and is_distributed")"
[ "$(q "select count(*) from pgvigil.mssql_ag_state where instance_id in (${I[d1b]}, ${I[d2b]}) and (group_name='dag1' or is_distributed)")" = 0 ] || fail "B: a secondary stores a row of dag1"
for p in d1b:ag1:d1a d2b:ag2:d2a; do IFS=: read -r n g pr <<<"$p"
  [ "$(q "select string_agg(replica_server || ':' || coalesce(role, '-') || ':' || is_local, ' ' order by replica_server) from pgvigil.mssql_ag_state where instance_id=${I[$n]} and group_name='$g'")" = "$pr:-:false $n:SECONDARY:true" ] || fail "B: $g as its secondary $n stores it"
done
L=$(q "select count(*) || '|' || min(replica_server) || '|' || min(database_name) || '|' || bool_or(is_local) || '|' || bool_and(log_send_queue_kb is not null) || '|' || bool_and(redo_queue_kb is not null) || '|' || bool_and(secondary_lag_s is not null) || '|' || bool_and(est_data_loss_s is not null) from pgvigil.mssql_ag_database_state where instance_id=${I[d1a]} and group_name='dag1'")
echo "  the link's database row on d1a (rows | member | database | local | send queue | redo queue | lag | est. data loss stored): $L"
[ "$L" = "1|ag2|dagdb|false|true|true|true|true" ] || fail "B: the link's database row on the global primary"
[ "$(q "select count(*) from pgvigil.mssql_ag_database_state where instance_id in (${I[d2a]}, ${I[d1b]}, ${I[d2b]}) and group_name='dag1'")" = 0 ] || fail "B: a database row of dag1 off the global primary"
[ "$(q "select count(*) from pgvigil.collection_dates where instance_id in ($ALL) and collection='mssql_ag' and status='ok'")" = 4 ] || fail "B: collection_dates"
plain() { q "select coalesce(string_agg(replica_server || ':' || (est_data_loss_s is not null), ' ' order by replica_server), 'none') from pgvigil.mssql_ag_database_state where instance_id=${I[$1]} and group_name <> 'dag1'"; }
P="$(plain d1a) / $(plain d1b) / $(plain d2a) / $(plain d2b)"
echo "  the plain groups' rows, replica:estimate stored, on d1a / d1b / d2a / d2b: $P"
[ "$P" = "d1a:false d1b:true / d1b:false / d2a:false d2b:true / d2b:false" ] || fail "B: the plain groups' estimated data loss is not as before the distributed group's fix"
for p in d1a:global d1b:secondary d2a:forwarder d2b:secondary; do livetest "${p%%:*}" "${p##*:}"; done
echo "B: OK (TestAgDistributedLive passed on the four nodes, each for its side)"

echo "--- C. the tie: one tree for every instance"
: >"$LOG"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:0" -no-login >>"$LOG" 2>&1 & SRVPID=$!
U=
for _ in $(seq 1 100); do
  U=$(sed -n 's/.*pgvigil serve started.*url=\(http:\/\/127\.0\.0\.1:[0-9]*\)\/.*/\1/p' "$LOG" | head -1)
  if [ -n "$U" ]; then break; fi
  kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
  sleep 0.1
done
[ -n "$U" ] || fail "serve did not say where it listens within 10 s: $(cat "$LOG")"
api instances | grep -c "${N[d1a]}" >/dev/null || fail "C: the server at $U does not list this run's instances"
for n in "${NODES[@]}"; do
  got=$(tree_of "$n"); want=$(tree "$n" d1a d2a CONNECTED)
  [ "$got" = "$want" ] || fail "C: the tree asked on $n: $got   WANT $want"
done
echo "  $(tree_of d2b)"
echo "C: OK (the same tree on the four instances; d2b is tied to dag1 through ag2)"

echo "--- D. the link under a write load"
T0=$(q "select now()")
( for _ in 1 2 3 4 5 6; do X d1a "D: the write load" "INSERT dagdb.dbo.t (note) SELECT TOP (100000) REPLICATE('x', 60) FROM sys.all_columns a CROSS JOIN sys.all_columns b;"; done ) & LOADPID=$!
while kill -0 "$LOADPID" 2>/dev/null; do read1 d1a; done
wait "$LOADPID" || fail "D: the write load failed"; LOADPID=
TD=$SECONDS
S=$(q "select count(*) || '|' || coalesce(max(redo_queue_kb), 0) || '|' || coalesce(max(log_send_queue_kb), 0) || '|' || bool_and(log_send_queue_kb is not null) || '|' || bool_and(est_data_loss_s is not null) from pgvigil.mssql_ag_sample where instance_id=${I[d1a]} and group_name='dag1' and replica_server='ag2' and database_name='dagdb' and snapshot_at > '$T0'")
echo "  samples of the link under the load (reads | largest redo queue KB | largest send queue KB | send queue stored | est. data loss stored): $S"
IFS='|' read -r NS RMAX _ SQOK LOSSOK <<<"$S"
[ "$NS" -ge 3 ] || fail "D: fewer than 3 reads fell into the load"
[ "$SQOK" = true ] && [ "$LOSSOK" = true ] || fail "D: a sample of the link has no send queue or no estimated data loss"
[ "$RMAX" -gt 0 ] || fail "D: no read saw a redo queue across the link under the load"
drained() { [ "$(q "select (log_send_queue_kb < 1000 and redo_queue_kb < 1000) from pgvigil.mssql_ag_database_state where instance_id=${I[d1a]} and group_name='dag1' and database_name='dagdb'")" = t ]; }
settle 60 "the link's queues are stored and under 1,000 KB" d1a -- drained || fail "D: the link did not drain in 60 s"
C1=$(Q d1a "SELECT COUNT(*) FROM dagdb.dbo.t")
LEFT=$((60 - (SECONDS - TD))); [ "$LEFT" -ge 2 ] || LEFT=2
until_q $((LEFT / 2)) 2 d2b "$C1" "SELECT COUNT(*) FROM dagdb.dbo.t" || fail "D: 60 s after the load d2b counts $GOT rows, d1a $C1"
[ $((SECONDS - TD)) -le 60 ] || fail "D: the drain and d2b's count took $((SECONDS - TD)) s, past the 60 s allowed"
echo "D: OK ($NS reads under the load, the redo queue up to $RMAX KB; $C1 rows on d1a and on d2b)"

echo "--- E. a suspended database (on the forwarder)"
X d2a "E: SUSPEND" "ALTER DATABASE dagdb SET HADR SUSPEND;"
sleep 3
X d1a "E: a row while suspended" "INSERT dagdb.dbo.t (note) VALUES ('while suspended 1');"; sleep 3
X d1a "E: a second row while suspended" "INSERT dagdb.dbo.t (note) VALUES ('while suspended 2');"; sleep 1
readall "${NODES[@]}"
F1=$(findings d1a); F3=$(findings d2a); F4=$(findings d2b)
echo "  d1a: $F1"; echo "  d2a: $F3"; echo "  d2b: $F4"
[ "$(q "select is_suspended from pgvigil.mssql_ag_database_state where instance_id=${I[d1a]} and group_name='dag1' and replica_server='ag2' and database_name='dagdb'")" = t ] || fail "E: the link's database is not stored as suspended on d1a"
has "$F1" "critical:a database is suspended [dag1 / ag2 / dagdb]" && has "$F1" "critical:a replica is not healthy [dag1 / ag2]" || fail "E: the findings on the global primary"
has "$F3" "critical:a database is suspended [ag2 / d2a / dagdb]" || fail "E: the finding on the forwarder"
has "$F4" "critical:a database is not synchronizing [ag2 / d2b / dagdb]" || fail "E: the finding on the second group's secondary"
X=$(q "select est_data_loss_s || '|' || secondary_lag_s from pgvigil.mssql_ag_database_state where instance_id=${I[d1a]} and group_name='dag1' and database_name='dagdb'")
echo "  the link while suspended, after two rows on d1a: estimated data loss | lag = $X s"
[ "${X%%|*}" -ge 2 ] && [ "${X##*|}" -ge 2 ] || fail "E: the link's estimated data loss or lag did not grow while suspended"
livetest d1a global
grep -o "database dagdb: estimated data loss.*" "$OUT" | sed 's/^/  the live test on d1a: /' || true
X d2a "E: RESUME" "ALTER DATABASE dagdb SET HADR RESUME;"
settle 90 "no finding on any instance" "${NODES[@]}" -- quiet || fail "E: findings stay after RESUME: d1a $(findings d1a) / d2a $(findings d2a) / d2b $(findings d2b)"
[ "$(q "select synchronization_state || '|' || is_suspended from pgvigil.mssql_ag_database_state where instance_id=${I[d1a]} and group_name='dag1' and database_name='dagdb'")" = "SYNCHRONIZING|false" ] || fail "E: the link after RESUME"
echo "E: OK"

# stop_node / start_node <node>: the container, and after a start the server answering and its address read again
start_node() { docker start "$(ct "$1")" >/dev/null; until_q 60 3 "$1" 1 "SELECT 1" || fail "$1 did not answer within 180 s of its start"; setdsn "$1"; }
echo "--- F. the forwarder node stopped"
LAST3=$(q "select max(snapshot_at) from pgvigil.mssql_ag_state where instance_id=${I[d2a]}")
docker stop "$(ct d2a)" >/dev/null
seen_down() { has "$(findings d1a)" "critical:a replica is not connected [dag1 / ag2]"; }
settle 90 "d1a reports the link down" d1a d2b -- seen_down || fail "F: no 'a replica is not connected' [dag1 / ag2] on d1a: $(findings d1a)"
F1=$(findings d1a); F4=$(findings d2b)
echo "  d1a: $F1"; echo "  d2b: $F4"
has "$F1" "critical:a database is not synchronizing [dag1 / ag2 / dagdb]" || fail "F: the link's database on the global primary"
has "$F4" "critical:a replica is not connected [ag2 / d2b]" || fail "F: the second group's secondary does not report its lost primary"
if "$BIN" collect -config "$CFG" -once mssql_ag -instance "${N[d2a]}" >"$OUT" 2>&1; then cat "$OUT"; fail "F: the read of the stopped node did not fail"; fi
[ "$(q "select max(snapshot_at) from pgvigil.mssql_ag_state where instance_id=${I[d2a]}")" = "$LAST3" ] || fail "F: the failed read of d2a changed its stored state"
got=$(tree_of d1a); want=$(tree d1a d1a d2a DISCONNECTED)
[ "$got" = "$want" ] || fail "F: the tree asked on d1a while d2a is down: $got   WANT $want"
start_node d2a
settle 120 "no finding on any instance" "${NODES[@]}" -- quiet || fail "F: findings stay after the start: d1a $(findings d1a) / d2a $(findings d2a) / d2b $(findings d2b)"
[ "$(members d2a)" = "ag1:-:-:false ag2:SECONDARY:CONNECTED:true primary=ag1" ] || fail "F: dag1 on d2a after its start: $(members d2a)"
[ "$(q "select role from pgvigil.mssql_ag_state where instance_id=${I[d2a]} and group_name='ag2' and replica_server='d2a'")" = PRIMARY ] || fail "F: d2a is not the primary of ag2 after its start"
echo "F: OK"

echo "--- G. the second group's secondary stopped"
docker stop "$(ct d2b)" >/dev/null
seen_d2b() { has "$(findings d2a)" "critical:a replica is not connected [ag2 / d2b]"; }
settle 90 "d2a reports its secondary down" d1a d2a -- seen_d2b || fail "G: no 'a replica is not connected' [ag2 / d2b] on d2a: $(findings d2a)"
echo "  d2a: $(findings d2a)"; echo "  d1a: $(findings d1a)"
[ "$(findings d1a)" = none ] || fail "G: the global primary reports something of a stopped secondary of the other group (the proof expected it blind to it)"
sleep 10; readall d1a d2a
echo "  10 s later: d2a: $(findings d2a); d1a: $(findings d1a)"
seen_d2b || fail "G: d2a no longer reports its stopped secondary"
[ "$(findings d1a)" = none ] || fail "G: 10 s later the global primary reports something of the stopped secondary: $(findings d1a)"
start_node d2b
settle 120 "no finding on any instance" "${NODES[@]}" -- quiet || fail "G: findings stay after the start: d2a $(findings d2a) / d2b $(findings d2b)"
echo "G: OK (seen on the forwarder only: the global primary alone would not have shown it)"

echo "--- H. a planned failover of dag1 to ag2"
readall "${NODES[@]}"
SYNC="ALTER AVAILABILITY GROUP dag1 MODIFY AVAILABILITY GROUP ON 'ag1' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT), 'ag2' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);"
OWNLSN="SELECT ISNULL(CAST(last_hardened_lsn AS varchar(30)), '-') FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID('dagdb') AND is_local = 1"
LINKLSN="SELECT ISNULL(CAST(drs.last_hardened_lsn AS varchar(30)), '-') FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_groups ag ON ag.group_id = drs.group_id WHERE ag.name = 'dag1' AND drs.database_id = DB_ID('dagdb')"
RSSC="SELECT CAST(required_synchronized_secondaries_to_commit AS varchar(5)) FROM sys.availability_groups WHERE name = 'dag1'"
X d1a "H: both sides synchronous" "$SYNC"; X d2a "H: both sides synchronous" "$SYNC"
until_q 30 2 d1a SYNCHRONIZED "SELECT ISNULL((SELECT TOP 1 drs.synchronization_state_desc FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_groups ag ON ag.group_id = drs.group_id WHERE ag.name = 'dag1' AND drs.is_local = 0), 'none')" \
  || fail "H: the link is $GOT, not SYNCHRONIZED, 60 s after both sides were made synchronous"
X d1a "H: REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1" "ALTER AVAILABILITY GROUP dag1 SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1);"
[ "$(Q d1a "$RSSC")" = 1 ] || fail "H: the setting is not 1 on d1a"
# lsns <with the link: 1|0>: 'd1b|link|d2a' last hardened LSNs of dagdb (d1b's and d2a's own rows, d1a's row of the
# link; '-' for the link when it is not asked), 'unread' for a read that failed
lsns() { local b f l=-
  b=$(Q d1b "$OWNLSN" 2>&1) || b="unread: ${b//$'\n'/ }"; f=$(Q d2a "$OWNLSN" 2>&1) || f="unread: ${f//$'\n'/ }"
  if [ "$1" = 1 ]; then l=$(Q d1a "$LINKLSN" 2>&1) || l="unread: ${l//$'\n'/ }"; fi
  echo "$b|$l|$f"; }
# lsn_ready <label> <with the link: 1|0>: the LSNs equal (the link's too when asked) and the same 2 s later
lsn_ready() { local x= y= b l f
  for _ in $(seq 1 15); do
    y=; x=$(lsns "$2"); IFS='|' read -r b l f <<<"$x"
    if [[ "$b" =~ ^[0-9]+$ ]] && [ "$b" = "$f" ] && { [ "$2" = 0 ] || [ "$l" = "$b" ]; }; then
      sleep 2; y=$(lsns "$2")
      if [ "$y" = "$x" ]; then echo "  $1: the last hardened LSN of dagdb on d1b | the link on d1a | d2a: $x, the same 2 s later (d1a's own row: $(Q d1a "$OWNLSN" 2>&1))"; return 0; fi
    fi
    sleep 2
  done
  echo "  $1: the last hardened LSNs on d1b | the link on d1a | d2a are not equal and steady: $x${y:+, then $y}; d1a's own row: $(Q d1a "$OWNLSN" 2>&1)"; return 1; }
lsn_ready "before the role change" 1 || fail "H: the forwarder has not hardened what the global primary's group has; the role is not changed"
X d1a "H: ROLE = SECONDARY" "ALTER AVAILABILITY GROUP dag1 SET (ROLE = SECONDARY);"
# Microsoft's SQL Server 2022 sequence has no way back from here but its own remaining steps: a mismatch ends the proof
lsn_ready "with both sides secondary" 0 || fail "H: d1b and d2a differ with both sides secondary; the failover is not forced and the lab is removed as it stands"
X d2a "H: FORCE_FAILOVER_ALLOW_DATA_LOSS" "ALTER AVAILABILITY GROUP dag1 FORCE_FAILOVER_ALLOW_DATA_LOSS;"
X d1a "H: REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0" "ALTER AVAILABILITY GROUP dag1 SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0);"
[ "$(Q d1a "$RSSC")" = 0 ] || fail "H: the setting is not back to 0 on d1a"
# the tree takes the link's state from the new global primary's read; the new forwarder's own member row says
# DISCONNECTED for some seconds after the force (read +3 s DISCONNECTED, +13 s CONNECTED by hand): both primaries' own
# stored rows are waited for too
moved() { [ "$(tree_of d2a)" = "$(tree d2a d2a d1a CONNECTED)" ] && [ "$(members d2a)" = "ag1:SECONDARY:CONNECTED:false ag2:PRIMARY:CONNECTED:true primary=ag2" ] && [ "$(members d1a)" = "ag1:SECONDARY:CONNECTED:true ag2:-:-:false primary=ag2" ]; }
settle 120 "the tree shows d2a as the global primary and both primaries' own rows the new roles" "${NODES[@]}" -- moved || {
  sa_states d1a d1b d2a
  echo "  sa on d1a, dag1's replicas: $(Q d1a "SELECT ar.replica_server_name + '=' + ISNULL(ars.role_desc, '-') + '/' + ISNULL(ars.connected_state_desc, '-') + ISNULL(' (' + ars.last_connect_error_description + ')', '') + ' ' FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id WHERE ag.name = 'dag1'" 2>&1 | tr '\n' ' ')"
  fail "H: 120 s after the failover: the tree $(tree_of d2a) (WANT $(tree d2a d2a d1a CONNECTED)); d2a stores $(members d2a); d1a stores $(members d1a)"; }
echo "  d2a stores dag1 as: $(members d2a)"; echo "  d1a stores dag1 as: $(members d1a)"
[ "$(members d2a)" = "ag1:SECONDARY:CONNECTED:false ag2:PRIMARY:CONNECTED:true primary=ag2" ] || fail "H: dag1 on the new global primary"
[ "$(members d1a)" = "ag1:SECONDARY:CONNECTED:true ag2:-:-:false primary=ag2" ] || fail "H: dag1 on the new forwarder"
for n in "${NODES[@]}"; do got=$(tree_of "$n"); want=$(tree "$n" d2a d1a CONNECTED); [ "$got" = "$want" ] || fail "H: the tree asked on $n: $got   WANT $want"; done
[ "$(q "select count(*) || '|' || min(replica_server) || '|' || min(database_name) || '|' || bool_and(est_data_loss_s is not null) from pgvigil.mssql_ag_database_state where instance_id=${I[d2a]} and group_name='dag1'")" = "1|ag1|dagdb|true" ] || fail "H: the link's database row on the new global primary"
[ "$(q "select count(*) from pgvigil.mssql_ag_database_state where instance_id=${I[d1a]} and group_name='dag1'")" = 0 ] || fail "H: the new forwarder still stores a database row of dag1"
FO=$(q "select coalesce(string_agg(i.name || ' ' || f.group_name || ' ' || f.old_primary || '>' || f.new_primary, '; ' order by i.name, f.at), 'none') from pgvigil.mssql_ag_failovers f join pgvigil.instances i using (instance_id) where f.instance_id in ($ALL)")
echo "  the role changes kept: $FO"
[ "$FO" = "${N[d1a]} dag1 ag1>ag2; ${N[d2a]} dag1 ag1>ag2" ] || fail "H: mssql_ag_failovers (want one row for dag1 on d1a and one on d2a, none for ag1 or ag2)"
for n in d1a d2a; do has "$(findings "$n")" "critical:the primary of a group changed [dag1]" || fail "H: no 'the primary of a group changed' [dag1] on $n: $(findings "$n")"; done
synced() { [ "$(q "select coalesce((select synchronization_state from pgvigil.mssql_ag_database_state where instance_id=${I[d2a]} and group_name='dag1' and replica_server='ag1' and database_name='dagdb'), '-') || '|' || coalesce((select synchronization_state from pgvigil.mssql_ag_database_state where instance_id=${I[d1a]} and group_name='ag1' and replica_server='d1b' and database_name='dagdb'), '-')")" = "SYNCHRONIZED|SYNCHRONIZED" ]; }
settle 120 "the link on d2a and ag1's secondary on d1a are SYNCHRONIZED" d1a d2a -- synced || { sa_states d1a d1b d2a; fail "H: after the failover the link (dag1 / ag1 on d2a) or ag1's secondary (d1b on d1a) is not SYNCHRONIZED in 120 s"; }
X d2a "H: a row on the new global primary" "INSERT dagdb.dbo.t (note) VALUES ('written on d2a after the failover');"
until_q 30 2 d1b 1 "SELECT COUNT(*) FROM dagdb.dbo.t WHERE note = 'written on d2a after the failover'" || {
  sa_states d1a d1b d2a
  echo "  the read on d1b: $(Q d1b "SELECT COUNT(*) FROM dagdb.dbo.t WHERE note = 'written on d2a after the failover'" 2>&1 | tr '\n' ' ')"
  fail "H: the row written on d2a did not reach d1b in 60 s (last read: $GOT)"; }
# Microsoft's optional step 9: both sides asynchronous again, the link as the lab began (and the cell the page marks by
# the commit mode: SYNCHRONIZING over an asynchronous link is no warning)
ASYNC="ALTER AVAILABILITY GROUP dag1 MODIFY AVAILABILITY GROUP ON 'ag1' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT), 'ag2' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);"
X d2a "H: step 9, asynchronous again" "$ASYNC"; X d1a "H: step 9, asynchronous again" "$ASYNC"
asyncd() { [ "$(q "select r.availability_mode || '|' || d.synchronization_state from pgvigil.mssql_ag_database_state d join pgvigil.mssql_ag_state r on r.instance_id = d.instance_id and r.group_id = d.group_id and r.replica_server = d.replica_server where d.instance_id=${I[d2a]} and d.group_name='dag1' and d.database_name='dagdb'")" = "ASYNCHRONOUS_COMMIT|SYNCHRONIZING" ]; }
settle 60 "the link is asynchronous and SYNCHRONIZING again" d1a d2a -- asyncd || fail "H: after step 9 the link on d2a is not ASYNCHRONOUS_COMMIT and SYNCHRONIZING"
api "mssql/availability?instance=${I[d2a]}&part=databases" | python3 -c '
import json, sys
t = json.load(sys.stdin)["databases"]; rows = {(r["group_name"], r["replica_server"]): r for r in (dict(zip(t["columns"], x)) for x in t["rows"])}
link, sec = rows.get(("dag1", "ag1"), {}), rows.get(("ag2", "d2b"), {})
assert link.get("availability_mode") == "ASYNCHRONOUS_COMMIT" and link.get("synchronization_state") == "SYNCHRONIZING", link
assert sec.get("availability_mode") == "SYNCHRONOUS_COMMIT", sec' || fail "H: the API's databases of d2a do not carry the commit mode (the link asynchronous, ag2's secondary synchronous)"
echo "  step 9: the link is asynchronous and SYNCHRONIZING, the API's databases carry each row's commit mode"
echo "H: OK (a row written on d2a is on d1b)"

echo "--- I. stubbed rows through the import"
imp() { q "select pgvigil.import_mssql_ag($1, $2, \$j\$$3\$j\$::jsonb)" >/dev/null; }
stub() { q "select pgvigil.ensure_instance('$1', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')"; }
# stubrows <group id of the distributed group> <its name> <the member group it names as primary> <local member group>
#   <its role> <its connected state> <other member group> <its role | null> <its connected state | null>
#   <group id of the local member group> <its primary, this server> <its secondary>: one read of a primary of a member group
# [<a database of the local group> <its state on the secondary>]: a database row of the secondary as the primary reads it
stubrows() { python3 -c '
import json, sys
dag_id, dag, dag_primary, local, lrole, lconn, other, orole, oconn, gid, prim, sec = sys.argv[1:13]
db = sys.argv[13:15]
nul = lambda v: None if v == "null" else v
own = {"kind": "replica", "group_id": gid, "group_name": local, "cluster_type": "WSFC", "is_distributed": 0, "primary_replica": prim, "synchronization_health": "HEALTHY", "connected_state": "CONNECTED", "availability_mode": "SYNCHRONOUS_COMMIT"}
dist = {"kind": "replica", "group_id": dag_id, "group_name": dag, "is_distributed": 1, "primary_replica": dag_primary}
print(json.dumps([
    dict(own, replica_server=prim, is_local=1, role="PRIMARY"), dict(own, replica_server=sec, is_local=0, role="SECONDARY"),
    dict(dist, replica_server=local, endpoint_url="TCP://%s-listener:5022" % local, is_local=1, role=lrole, connected_state=lconn, synchronization_health="HEALTHY"),
    dict(dist, replica_server=other, endpoint_url="TCP://%s-listener:5022" % other, is_local=0, role=nul(orole), connected_state=nul(oconn))]
    + ([{"kind": "database", "group_id": gid, "group_name": local, "replica_server": sec, "database_name": db[0], "is_local": 0, "is_primary_replica": 0,
         "synchronization_state": db[1], "synchronization_health": "HEALTHY", "is_suspended": 0}] if len(db) == 2 else [])))' "$@"; }
# stubtree <instance id>: the part "distributed" for a stub, one line
stubtree() { api "mssql/availability?instance=$1&part=distributed" | python3 -c '
import json, sys
t = json.load(sys.stdin).get("distributed") or {"columns": [], "rows": []}
rows = [dict(zip(t["columns"], r)) for r in t["rows"]]
print("; ".join("%s[%s %s]/%s=%s stale=%s read=%s url=%s" % (r["member"], r["member_role"], r["member_connected"], r["replica_server"], r["dag_role"],
      r["replica_stale"], r["member_instance"] is not None, r["member_url"]) for r in rows) or "none")'; }
S1=$(stub "stub-dag-only-global-$SUF")
imp "$S1" "now()" "$(stubrows AAAAAAAA-0000-0000-0000-000000000001 sdag sag1 sag1 PRIMARY CONNECTED sag2 SECONDARY CONNECTED AAAAAAAA-0000-0000-0000-0000000000A1 sa sb)"
got=$(stubtree "$S1"); echo "  1. only the global primary monitored: $got"
[ "$got" = "sag1[PRIMARY CONNECTED]/sa=global primary stale=False read=True url=TCP://sag1-listener:5022; sag1[PRIMARY CONNECTED]/sb=secondary stale=False read=True url=TCP://sag1-listener:5022; sag2[SECONDARY CONNECTED]/None=None stale=False read=False url=TCP://sag2-listener:5022" ] \
  || fail "I.1: a distributed group of which only the global primary is monitored"
S2=$(stub "stub-dag-old-global-$SUF"); S3=$(stub "stub-dag-new-global-$SUF")
imp "$S2" "now() - interval '10 minutes'" "$(stubrows BBBBBBBB-0000-0000-0000-000000000001 tdag tag1 tag1 PRIMARY CONNECTED tag2 SECONDARY CONNECTED BBBBBBBB-0000-0000-0000-0000000000A1 ta tb)"
imp "$S3" "now()" "$(stubrows BBBBBBBB-0000-0000-0000-000000000001 tdag tag2 tag2 PRIMARY CONNECTED tag1 null null BBBBBBBB-0000-0000-0000-0000000000A2 tc td tdb SYNCHRONIZING)"
got=$(stubtree "$S3"); echo "  2. the old global primary's ten-minute-old read against the new one's fresh read: $got"
[ "$got" = "tag2[PRIMARY CONNECTED]/tc=global primary stale=False read=True url=TCP://tag2-listener:5022; tag2[PRIMARY CONNECTED]/td=secondary stale=False read=True url=TCP://tag2-listener:5022; tag1[SECONDARY None]/ta=forwarder stale=True read=True url=TCP://tag1-listener:5022; tag1[SECONDARY None]/tb=secondary stale=True read=True url=TCP://tag1-listener:5022" ] \
  || fail "I.2: an old read of the side that no longer answers is drawn as current (two global primaries, a state from the old read, or no stale mark)"
S4=$(stub "stub-dag-stale-global-$SUF"); S5=$(stub "stub-dag-fresh-forwarder-$SUF")
imp "$S4" "now() - interval '10 minutes'" "$(stubrows CCCCCCCC-0000-0000-0000-000000000001 udag ug1 ug1 PRIMARY CONNECTED ug2 SECONDARY CONNECTED CCCCCCCC-0000-0000-0000-0000000000A1 ua ub)"
imp "$S5" "now()" "$(stubrows CCCCCCCC-0000-0000-0000-000000000001 udag ug1 ug2 SECONDARY DISCONNECTED ug1 null null CCCCCCCC-0000-0000-0000-0000000000A2 uc ud)"
got=$(stubtree "$S5" | tr ';' '\n' | sed 's/^ *//; s/\/.*//' | sort -u | tr '\n' ' ')
echo "  3. a ten-minute-old CONNECTED of the global primary against the forwarder's fresh DISCONNECTED: $got"
[ "$got" = "ug1[PRIMARY None] ug2[SECONDARY DISCONNECTED] " ] || fail "I.3: a stale read of the other side outvoted a fresh one"
echo "I: OK"

echo "--- J. the page"
readall "${NODES[@]}"     # every node read again: no member group of the lab is older than the page's five minutes
setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHRPID=$!
CDP=
for _ in $(seq 1 60); do
  if [ -s "$WORK/chrome/DevToolsActivePort" ]; then CDP=$(head -1 "$WORK/chrome/DevToolsActivePort"); fi
  if [ -n "$CDP" ] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
[[ "$CDP" =~ ^[0-9]+$ ]] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "J: this run's Chromium never answered on its debugging port: $(tail -3 "$WORK/chrome.log")"
page_tree() { local me=$1 out= side n role
  for side in d2a d1a; do
    out+="${out:+; }ag${side:1:1}[$([ $side = d2a ] && echo PRIMARY || echo SECONDARY)]: "
    for n in "$side" "d${side:1:1}b"; do
      if [ "$n" = "$side" ]; then role=$([ $side = d2a ] && echo "global primary" || echo forwarder); else role=secondary; fi
      out+="$n=$role$([ "$n" = "$me" ] && echo '*' || true)$([ "$n" = "$side" ] && echo ', ' || true)"
    done
  done
  echo "dag1: $out"; }
python3 - "$WORK/cases.json" <<CASES
import json, sys
lab = {"dag": "dag1", "global": "d2a (primary of ag2)", "forwarder": "d1a (primary of ag1)", "stale": []}
cases = [
  dict(lab, label="the page of d2a", instance=${I[d2a]}, tree="$(page_tree d2a)", memberOf="ag2", link={"replica": "d1a", "instance": ${I[d1a]}}, grid="ag1 (member group)",
       dbCells=[{"group": "dag1", "replica": "ag1", "database": "dagdb", "state": "synchronizing", "cls": ""},
                {"group": "ag2", "replica": "d2b", "database": "dagdb", "state": "synchronized", "cls": ""}]),
  dict(lab, label="the page of d1a", instance=${I[d1a]}, tree="$(page_tree d1a)", memberOf="ag1", link={"replica": "d2a", "instance": ${I[d2a]}}, grid="ag2 (member group)"),
  dict(lab, label="the page of d2b", instance=${I[d2b]}, tree="$(page_tree d2b)", memberOf="ag2", link={"replica": "d2a", "instance": ${I[d2a]}}, grid=None),
  {"label": "the page of the stub whose other side no longer answers", "instance": $S3, "dag": "tdag",
   "tree": "tdag: tag2[PRIMARY]: tc=global primary*, td=secondary; tag1[SECONDARY]: ta=forwarder, tb=secondary",
   "global": "tc (primary of tag2)", "forwarder": "ta (primary of tag1)", "forwarderStale": True, "memberOf": "tag2",
   "link": {"replica": "ta", "instance": $S2}, "grid": "tag1 (member group)", "stale": ["tag1"],
   "dbCells": [{"group": "tag2", "replica": "td", "database": "tdb", "state": "synchronizing", "cls": "warn"}]},
]
json.dump(cases, open(sys.argv[1], "w"))
CASES
node scripts/dag/page-check.mjs "$CDP" "$U" "$WORK/cases.json" || fail "J: a check of the page failed"
stop_browser
echo "J: OK"

echo "--- K. everything removed"
kill "$SRVPID" 2>/dev/null || true; wait "$SRVPID" 2>/dev/null || true; SRVPID=
bash scripts/dag/trial.sh down "$TAG" | tee "$OUT" || fail "K: the lab is not removed in full"
LAB=
grep -q "containers left 0, networks left 0, volumes left 0" "$OUT" || fail "K: the read back of the removal"
psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null; MADE_REPO=
[ "$(psql "$ADMIN_DSN" -XAtq -c "select count(*) from pg_database where datname='$REPO_DB'")" = 0 ] || fail "K: the repository database is still there"
echo "K: OK (0 containers, 0 networks, 0 volumes; the repository database dropped)"

echo "NOT PROVEN: a distributed group over Windows clusters with listeners; a forced failover with data loss; a failover inside a member group; a member group whose primary is not monitored on a live server (stubbed rows only); a queue over its threshold for five minutes; SQL Server 2016 to 2019 and 2025"
echo "proof-mssql-dag: PASS (A, B, C, D, E, F, G, H, I, J, K; $WIRED)"
