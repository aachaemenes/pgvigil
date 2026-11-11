#!/usr/bin/env bash
# Proof of the server log's grouped events, the logged-statement percentiles and the checkpoint causes (parity3 task
# 126): the error and checkpoint kinds, the level and message shape (0079), /api/logs/groups, /api/slow/percentiles
# and the IO endpoint's checkpoint parts.
#
#   ADMIN_DSN    a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN): the proof makes its own
#                repository database there (random suffix) and drops it at the end.
#   LG_PORT      the port of the PostgreSQL 18 throwaway cluster (default 5497); initdb and pg_ctl on PATH.
#   LG13_PORT    the port of the PostgreSQL 13 throwaway container (default 5498; docker image postgres:13).
#   LG_HOLD      seconds to keep the server and the repository up after the checks (a look at the pages); unset: none.
#   PG13_PROOF   the stopped container the migration is proven on (default pgv-pg13-proof, 127.0.0.1:5413, trust):
#                started, a fresh database migrated, the database dropped, the container stopped again.
# The monitored servers are throwaways this proof makes (logging_collector on, log_checkpoints on, log_temp_files 0,
# log_min_duration_statement 0, checkpoint_timeout 1h so no timed checkpoint lands in the run) and removes at the end.
# The build must serve the three routes (the lead's wiring: notes WIRING BLOCK); without them the API sections fail.
#
# Expected (written before the first run):
#  A. PostgreSQL 18, the workload (one superuser session unless said): select from three missing tables (nosuch_a,
#     nosuch_b, nosuch_c); two duplicate keys on a table t (ids 1 and 2); select 1/0; two ROLLBACKs outside a
#     transaction; a statement timeout (50 ms on pg_sleep(1)); a login as a role that does not exist; a sort over
#     300,000 rows with work_mem 64kB (temp files); then collect serverlog.
#     /api/logs/groups (window: the run): exactly these six groups, by (level, kind, message, events):
#       ERROR   error    relation "..." does not exist                                    3
#       ERROR   error    duplicate key value violates unique constraint "..."             2
#       WARNING error    there is no transaction in progress                              2
#       ERROR   error    division by zero                                                 1
#       ERROR   timeout  canceling statement due to statement timeout                     1
#       FATAL   auth_fail role "..." does not exist                                       1
#     totals: events 10, groups 6, max_per_group 3; levels ERROR 7, WARNING 2, FATAL 1.
#     /api/logs/groups/rows for the relation group: matched 3, three rows newest first, their details naming
#     nosuch_c, nosuch_b, nosuch_a in that order; the duplicate-key rows carry DETAIL: Key (id)=(...) in the detail.
#     level=WARNING: one group, 2 events.
#  B. the Go and SQL shape rules agree: for every stored event of a message-detail kind and of kind error,
#     pgvigil.log_message_shape(first line of detail) = message (0 differences), on PostgreSQL 18 and 13.
#  C. the largest temp files: temp_total.files = the number of 'temporary file:' lines in the raw log file (read by
#     the superuser with pg_read_file), temp_total.largest and temp_files[0].size_bytes = the largest size among
#     those lines; temp_files[0] has datname postgres, usename postgres and a statement naming the proof's tag.
#  D. the percentiles: /api/slow/percentiles (min 0, tz UTC) equals a hand computation in Python over the stored
#     slow durations of the window: per UTC hour the count, min, max and the nearest-rank p90 / p95 / p99
#     (sorted[ceil(p * n) - 1]); every one of the ten buckets' counts; meta.statements = n;
#     meta.log_min_duration_statement '0'. The workload's slow statements include pg_sleep of 2, 7, 30, 70, 200 and
#     600 ms and 1.1 s, so at least seven buckets are non-empty.
#  E. a forced checkpoint on PostgreSQL 18: dbstats read, CHECKPOINT, dbstats read, collect serverlog.
#     /api/io: checkpoint_totals requested 1, timed 0; checkpoint_causes exactly one row (checkpoint, requested, 1);
#     checkpoint_log one row: cause requested, flags containing 'force', started_at <= completed_at, buffers and
#     total_secs not null.
#  F. the same on PostgreSQL 13 (the docker throwaway, its own repository rows): checkpoint_totals requested 1,
#     timed 0 (pg_stat_bgwriter); causes one row requested 1; checkpoint_log one row, cause requested, the
#     PostgreSQL 13 complete line's buffers and total_secs read; a select from a missing table gives the group
#     'relation "..." does not exist' ERROR 1.
#  [first run 2026-11-10 17:54: two differences. (1) the relation group read 'relation "..." does not exist at
#   character ...': the server appends the cursor position to the message line; the shape now drops a trailing
#   ' at character N' (Go and SQL), graded against the expectation as written. (2) WARNING 1, not 2: the two
#   ROLLBACKs ran in one session in the same millisecond and share the event key (time text, level, pid, message:
#   0013's), so they are one event - a stated limit (docs/logs.md); the workload now runs them in two sessions.]
#  [run 4: F causes read requested 1 and shutdown 1: the postgres:13 image's entrypoint starts a temporary server on
#   first init and shuts it down, and that shutdown checkpoint's start line fell inside the window; F's window now
#   starts after the container is up, graded against the expectation as written. Run 3 found a real fault, fixed in
#   q_io.go: '$2 - interval' resolved $2 as an interval (the checkpoint queries answered 500).]
#  G. 0079 on PostgreSQL 13 (pgv-pg13-proof): a fresh database migrated without error; import_logs of a payload with
#     level and message stores both; a second import of the same event with a longer detail keeps one row; the
#     kind check accepts 'error' and 'checkpoint'.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
PORT=${LG_PORT:-5497}; P13=${LG13_PORT:-5498}; PG13_PROOF=${PG13_PROOF:-pgv-pg13-proof}
SUF=$RANDOM; TAG=pgvlg$SUF
REPO_DB=pgvigil_lgproof_$SUF; MON=pgvigil_lgmon_$SUF; MONPW=p$RANDOM$RANDOM
C13=pgv-lg13-$SUF; G13DB=pgvigil_lg13_$SUF
DIR=$(mktemp -d); CFG=$(mktemp); SPORT=$((18000 + SUF % 1000)); U="http://127.0.0.1:$SPORT"; SRVPID=
PG13_WAS_RUNNING=unread   # read right before G: the container is shared with other proofs
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  pg_ctl -D "$DIR/data" stop -m fast -s >/dev/null 2>&1 || true
  docker rm -f "$C13" >/dev/null 2>&1 || true
  psql "host=127.0.0.1 port=5413 user=postgres dbname=postgres" -XAtq -c "drop database if exists $G13DB with (force)" >/dev/null 2>&1 || true
  [[ "$PG13_WAS_RUNNING" == false ]] && docker stop "$PG13_PROOF" >/dev/null 2>&1 || true
  rm -rf "$DIR" "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
command -v initdb >/dev/null && command -v pg_ctl >/dev/null || fail "initdb and pg_ctl must be on PATH"
command -v docker >/dev/null || fail "docker must be on PATH"

echo "--- the monitored servers: PostgreSQL 18 on $PORT (initdb), PostgreSQL 13 on $P13 (docker)"
initdb -D "$DIR/data" -U postgres -A trust >/dev/null 2>&1 || fail "initdb"
cat >> "$DIR/data/postgresql.conf" <<EOF
port = $PORT
listen_addresses = 'localhost'
unix_socket_directories = ''
logging_collector = on
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'UTC'
log_checkpoints = on
log_temp_files = 0
log_min_duration_statement = 0
checkpoint_timeout = '1h'
EOF
pg_ctl -D "$DIR/data" -l "$DIR/server.out" -w -s start >/dev/null 2>&1 || { tail -5 "$DIR/server.out" >&2; fail "the cluster did not start"; }
docker run -d --name "$C13" -p "127.0.0.1:$P13:5432" -e POSTGRES_HOST_AUTH_METHOD=trust postgres:13 \
  -c logging_collector=on -c "log_line_prefix=%m [%p] %q%u@%d " -c log_timezone=UTC -c log_checkpoints=on \
  -c checkpoint_timeout=1h >/dev/null || fail "docker run postgres:13"
SU="host=localhost port=$PORT user=postgres dbname=postgres sslmode=disable"
SU13="host=127.0.0.1 port=$P13 user=postgres dbname=postgres sslmode=disable"
for _ in $(seq 1 100); do psql "$SU13" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 0.2; done
sleep 1   # the image's entrypoint restarts the server once after its first init
for _ in $(seq 1 100); do psql "$SU13" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 0.2; done
su() { psql "$SU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
su13() { psql "$SU13" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
for s in su su13; do
  $s "create role $MON login password '$MONPW' in role pg_monitor"
  $s "grant execute on function pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) to $MON"
done
export MON_DSN="host=localhost port=$PORT user=$MON password=$MONPW dbname=postgres sslmode=disable"
export MON13_DSN="host=127.0.0.1 port=$P13 user=$MON password=$MONPW dbname=postgres sslmode=disable"

psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: lg18-$SUF
    dsn: env:MON_DSN
  - name: lg13-$SUF
    dsn: env:MON13_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once "$1" >/dev/null || fail "collect $1"; }
collect instance
P=$(q "select instance_id from pgvigil.instances where name='lg18-$SUF'")
P13ID=$(q "select instance_id from pgvigil.instances where name='lg13-$SUF'")
FROM=$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)

echo "--- A. the workload on PostgreSQL 18"
su "create table t (id int primary key)"
su "insert into t values (1), (2)"
for x in a b c; do psql "$SU" -XAtq -c "select * from nosuch_$x /* $TAG */" >/dev/null 2>&1 || true; sleep 0.05; done
for x in 1 2; do psql "$SU" -XAtq -c "insert into t values ($x) /* $TAG */" >/dev/null 2>&1 || true; done
psql "$SU" -XAtq -c "select 1/0 /* $TAG */" >/dev/null 2>&1 || true
# two sessions: two identical lines of one pid in one millisecond share the event key (0013) and are stored once
psql "$SU" -XAtq -c "rollback" >/dev/null 2>&1 || true
psql "$SU" -XAtq -c "rollback" >/dev/null 2>&1 || true
psql "$SU" -XAtq -c "set statement_timeout = 50" -c "select pg_sleep(1) /* $TAG */" >/dev/null 2>&1 || true
psql "host=localhost port=$PORT user=nosuchrole_$SUF dbname=postgres sslmode=disable" -XAtqc 'select 1' >/dev/null 2>&1 || true
psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<EOF
set work_mem = '64kB';
select count(*) from (select g from generate_series(1, 300000) g order by g desc) x /* $TAG-temp */;
select pg_sleep(0.002) /* $TAG */; select pg_sleep(0.007) /* $TAG */; select pg_sleep(0.03) /* $TAG */;
select pg_sleep(0.07) /* $TAG */; select pg_sleep(0.2) /* $TAG */; select pg_sleep(0.6) /* $TAG */;
select pg_sleep(1.1) /* $TAG */;
EOF
sleep 0.5
collect serverlog
[[ $(q "select status from pgvigil.collection_dates where instance_id=$P and collection='serverlog'") == ok ]] \
  || fail "A serverlog: $(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$P and collection='serverlog'")"

echo "--- the API (serve -no-login on $SPORT)"
LOG=$DIR/serve.log
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$SPORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "serve exited: $(cat "$LOG")"
api() { # path: the body, failing on a code other than 200
  local body code
  body=$(curl -s -w '\n%{http_code}' "$U/api/$1"); code=${body##*$'\n'}; body=${body%$'\n'*}
  [[ "$code" == 200 ]] || fail "/api/$1 answered $code: $body"
  printf '%s' "$body"
}
TO=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
W="from=$FROM&to=$TO"
G=$(api "logs/groups?instance=$P&$W")
python3 -I - "$G" <<'EOF' || fail "A groups"
import json, sys
d = json.loads(sys.argv[1])
rows = lambda t: [dict(zip(t["columns"], r)) for r in (t or {"columns": [], "rows": []})["rows"]]
got = sorted((r["level"], r["kind"], r["message"], r["events"]) for r in rows(d["groups"]))
want = sorted([("ERROR", "error", 'relation "..." does not exist', 3),
               ("ERROR", "error", 'duplicate key value violates unique constraint "..."', 2),
               ("WARNING", "error", "there is no transaction in progress", 2),
               ("ERROR", "error", "division by zero", 1),
               ("ERROR", "timeout", "canceling statement due to statement timeout", 1),
               ("FATAL", "auth_fail", 'role "..." does not exist', 1)])
if got != want:
    print("groups:", *got, sep="\n  "); sys.exit(1)
t = rows(d["totals"])[0]
if (t["events"], t["groups"], t["max_per_group"]) != (10, 6, 3):
    print("totals:", t); sys.exit(1)
lv = {r["level"]: r["events"] for r in rows(d["levels"])}
if lv != {"ERROR": 7, "WARNING": 2, "FATAL": 1}:
    print("levels:", lv); sys.exit(1)
print("A groups ok:", len(got), "groups,", t["events"], "events; levels", lv)
EOF
KEY=$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); c=d["groups"]["columns"]; print([dict(zip(c,r)) for r in d["groups"]["rows"] if r[c.index("message")].startswith("relation")][0]["group_key"])' "$G")
DKEY=$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); c=d["groups"]["columns"]; print([dict(zip(c,r)) for r in d["groups"]["rows"] if r[c.index("message")].startswith("duplicate")][0]["group_key"])' "$G")
python3 -I - "$(api "logs/groups/rows?instance=$P&$W&key=$KEY")" "$(api "logs/groups/rows?instance=$P&$W&key=$DKEY")" <<'EOF' || fail "A rows"
import json, sys
rows = lambda t: [dict(zip(t["columns"], r)) for r in t["rows"]]
d, dd = json.loads(sys.argv[1]), json.loads(sys.argv[2])
m = rows(d["meta"])[0]; ev = rows(d["events"])
names = [e["detail"].split('"')[1] for e in ev]
if m["matched"] != 3 or names != ["nosuch_c", "nosuch_b", "nosuch_a"]:
    print("relation rows:", m, names); sys.exit(1)
dk = [e["detail"] for e in rows(dd["events"])]
if len(dk) != 2 or not all("DETAIL: Key (id)=(" in x for x in dk):
    print("duplicate rows:", dk); sys.exit(1)
print("A rows ok:", names, "; duplicate details carry the key")
EOF
python3 -I - "$(api "logs/groups?instance=$P&$W&level=WARNING")" <<'EOF' || fail "A level=WARNING"
import json, sys
d = json.loads(sys.argv[1]); g = [dict(zip(d["groups"]["columns"], r)) for r in d["groups"]["rows"]]
if len(g) != 1 or g[0]["events"] != 2: print(g); sys.exit(1)
print("A level=WARNING ok: one group, 2 events")
EOF

echo "--- B. the Go and SQL shape rules agree (PostgreSQL 18 repository)"
MK="'auth_fail','error','corruption','checkpoint','connection_limit','connection_lost','timeout','canceled','autovacuum_cancel','vacuum_skipped','wraparound','checkpoint_frequent','crash','out_of_memory','archive_failed','standby_conflict','serialization_failure','temp_file'"
DIFF=$(q "select count(*) filter (where pgvigil.log_message_shape(split_part(detail, E'\n', 1)) is distinct from message), count(*)
            from pgvigil.log_events where kind in ($MK) and message is not null and detail is not null")
[[ ${DIFF%%|*} == 0 && ${DIFF##*|} -ge 10 ]] || fail "B: $DIFF (differences|compared): $(q "select message || ' <> ' || pgvigil.log_message_shape(split_part(detail, E'\n', 1)) from pgvigil.log_events where kind in ($MK) and message is distinct from pgvigil.log_message_shape(split_part(detail, E'\n', 1)) and message is not null limit 5")"
echo "B ok: ${DIFF##*|} events compared, 0 differences"

echo "--- C. the largest temp files against the raw log"
RAW=$(su "select string_agg(pg_read_file(current_setting('log_directory') || '/' || name), '') from pg_ls_logdir()")
NFILES=$(grep -c 'temporary file: path' <<<"$RAW" || true)
MAXSZ=$(grep -o 'temporary file: path "[^"]*", size [0-9]*' <<<"$RAW" | awk '{print $NF}' | sort -n | tail -1)
[[ "$NFILES" -ge 1 ]] || fail "C: no temporary file line in the raw log"
python3 -I - "$G" "$NFILES" "$MAXSZ" "$TAG-temp" <<'EOF' || fail "C temp files"
import json, sys
d = json.loads(sys.argv[1]); n, mx, tag = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
rows = lambda t: [dict(zip(t["columns"], r)) for r in t["rows"]]
tt = rows(d["temp_total"])[0]; tf = rows(d["temp_files"])
if tt["files"] != n or tt["largest"] != mx or tf[0]["size_bytes"] != mx:
    print("temp:", tt, tf[:1], "raw:", n, mx); sys.exit(1)
f = tf[0]
if f["datname"] != "postgres" or f["usename"] != "postgres" or tag not in (f["statement"] or ""):
    print("largest:", f); sys.exit(1)
print(f"C ok: {n} file(s), the largest {mx} bytes, {f['datname']}/{f['usename']}, statement tagged")
EOF

echo "--- D. the percentiles against a hand computation"
DUR=$(q "select to_char(snapshot_at at time zone 'UTC', 'YYYY-MM-DD HH24') || '|' || duration_ms from pgvigil.log_events
          where instance_id=$P and kind='slow' and snapshot_at > '$FROM' and snapshot_at <= '$TO' and duration_ms is not null")
python3 -I - "$(api "slow/percentiles?instance=$P&$W&min=0&tz=UTC")" "$DUR" <<'EOF' || fail "D percentiles"
import json, math, sys
from datetime import datetime, timezone
d = json.loads(sys.argv[1])
rows = lambda t: [dict(zip(t["columns"], r)) for r in t["rows"]]
by = {}
for line in sys.argv[2].splitlines():
    h, v = line.split("|"); by.setdefault(h, []).append(float(v))
def rank(xs, p): return xs[math.ceil(p * len(xs)) - 1]
hours = rows(d["hours"])
if len(hours) != len(by): print("hours:", [h["hour"] for h in hours], sorted(by)); sys.exit(1)
for h in hours:
    key = datetime.fromisoformat(h["hour_start"]).astimezone(timezone.utc).strftime("%Y-%m-%d %H")
    xs = sorted(by[key])
    want = (len(xs), round(xs[0], 3), round(xs[-1], 3), round(rank(xs, .90), 3), round(rank(xs, .95), 3), round(rank(xs, .99), 3))
    got = (h["statements"], float(h["min_ms"]), float(h["max_ms"]), float(h["p90_ms"]), float(h["p95_ms"]), float(h["p99_ms"]))
    if got != want: print("hour", key, "got", got, "want", want); sys.exit(1)
edges = [0, 1, 5, 10, 25, 50, 100, 500, 1000, 10000, None]
allx = [x for xs in by.values() for x in xs]
want = [sum(1 for x in allx if x >= edges[i] and (edges[i + 1] is None or x < edges[i + 1])) for i in range(10)]
got = [r["statements"] for r in rows(d["histogram"])]
if got != want: print("histogram got", got, "want", want); sys.exit(1)
m = rows(d["meta"])[0]
if m["statements"] != len(allx) or str(m["log_min_duration_statement"]) not in ("0", "0ms"):
    print("meta:", m); sys.exit(1)
if sum(1 for n in got if n) < 7: print("buckets filled:", got); sys.exit(1)
print(f"D ok: {len(allx)} statements in {len(hours)} hour(s), p90/p95/p99 and the ten buckets {got} match; log_min_duration_statement {m['log_min_duration_statement']}")
EOF

checkpoint_case() { # label instance su-function window-from: two dbstats reads around a CHECKPOINT, then the log
  local label=$1 inst=$2 sufn=$3 from=$4
  collect dbstats
  sleep 1.1
  $sufn "checkpoint"
  sleep 1.1
  collect dbstats
  sleep 0.5
  collect serverlog
  [[ $(q "select status from pgvigil.collection_dates where instance_id=$inst and collection='serverlog'") == ok ]] \
    || fail "$label serverlog: $(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id=$inst and collection='serverlog'")"
  local to; to=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
  python3 -I - "$(api "io?instance=$inst&from=$from&to=$to")" "$label" <<'EOF' || fail "$label checkpoints"
import json, sys
d = json.loads(sys.argv[1]); label = sys.argv[2]
rows = lambda t: [dict(zip(t["columns"], r)) for r in (t or {"columns": [], "rows": []})["rows"]]
t = rows(d["checkpoint_totals"])[0]
if (t["requested"], t["timed"]) != (1, 0): print("totals:", t); sys.exit(1)
c = [(r["what"], r["cause"], r["checkpoints"]) for r in rows(d["checkpoint_causes"])]
if c != [("checkpoint", "requested", 1)]: print("causes:", c); sys.exit(1)
l = rows(d["checkpoint_log"])
if len(l) != 1: print("log:", l); sys.exit(1)
r = l[0]
if r["cause"] != "requested" or "force" not in (r["flags"] or "") or r["started_at"] is None or r["started_at"] > r["completed_at"] \
   or r["buffers"] is None or r["total_secs"] is None:
    print("row:", r); sys.exit(1)
print(f"{label} ok: requested 1, timed 0 (counters); cause requested from '{r['flags']}'; {r['buffers']} buffers, write {r['write_secs']} s, sync {r['sync_secs']} s, total {r['total_secs']} s")
EOF
}

echo "--- E. a forced checkpoint on PostgreSQL 18"
checkpoint_case E "$P" su "$FROM"

echo "--- F. the same on PostgreSQL 13, and an error group"
# the window starts now: the image's first-init restart wrote a shutdown checkpoint into the log before this
sleep 1.1; FROM13=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1.1
psql "$SU13" -XAtq -c "select * from nosuch_13 /* $TAG */" >/dev/null 2>&1 || true
checkpoint_case F "$P13ID" su13 "$FROM13"
python3 -I - "$(api "logs/groups?instance=$P13ID&from=$FROM13&to=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)")" <<'EOF' || fail "F groups"
import json, sys
d = json.loads(sys.argv[1]); g = [dict(zip(d["groups"]["columns"], r)) for r in d["groups"]["rows"]]
hit = [x for x in g if x["message"] == 'relation "..." does not exist' and x["level"] == "ERROR" and x["events"] == 1]
if not hit: print(g); sys.exit(1)
print("F groups ok: relation \"...\" does not exist, ERROR, 1")
EOF
DIFF=$(q "select count(*) filter (where pgvigil.log_message_shape(split_part(detail, E'\n', 1)) is distinct from message) from pgvigil.log_events where instance_id=$P13ID and kind in ($MK) and message is not null and detail is not null")
[[ "$DIFF" == 0 ]] || fail "F shapes: $DIFF differences"

echo "--- G. 0079 on PostgreSQL 13 ($PG13_PROOF)"
PG13_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' "$PG13_PROOF" 2>/dev/null || echo missing)
[[ "$PG13_WAS_RUNNING" == missing ]] && fail "G: no container $PG13_PROOF"
docker start "$PG13_PROOF" >/dev/null
G13="host=127.0.0.1 port=5413 user=postgres dbname=postgres sslmode=disable"
for _ in $(seq 1 100); do psql "$G13" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 0.2; done
psql "$G13" -XAtqc "create database $G13DB" >/dev/null
G13CFG=$DIR/g13.yaml
printf 'repository:\n  dsn: env:G13_REPO\ninstances: []\n' > "$G13CFG"
G13_REPO="$G13 dbname=$G13DB" "$BIN" migrate -config "$G13CFG" >/dev/null || fail "G: migrate on PostgreSQL 13"
g13() { psql "$G13 dbname=$G13DB" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
[[ $(g13 "select current_setting('server_version_num')::int / 10000") == 13 ]] || fail "G: not PostgreSQL 13"
g13 "insert into pgvigil.instances (name, platform) values ('g13', 'onprem')" >/dev/null
GI=$(g13 "select instance_id from pgvigil.instances where name='g13'")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ev() { echo "[{\"kind\":\"event\",\"kind_of\":\"$1\",\"at\":\"$NOW\",\"pid\":1,\"detail\":\"$2\",\"source\":\"s\",\"event_key\":\"k$1\",\"level\":\"$3\",\"message\":\"$4\"},{\"kind\":\"cursor\",\"source\":\"s\",\"read_to\":\"$NOW\"}]"; }
g13 "select pgvigil.import_logs($GI, now(), '$(ev error 'relation x does not exist' ERROR 'relation x does not exist')'::jsonb)" >/dev/null
g13 "select pgvigil.import_logs($GI, now(), '$(ev error 'relation x does not exist and more' ERROR 'relation x does not exist')'::jsonb)" >/dev/null
g13 "select pgvigil.import_logs($GI, now(), '$(ev checkpoint 'checkpoint starting: time' LOG 'checkpoint starting: time')'::jsonb)" >/dev/null
R=$(g13 "select string_agg(kind || '/' || level || '/' || message || '/' || detail, ';' order by kind) from pgvigil.log_events where instance_id=$GI")
[[ "$R" == "checkpoint/LOG/checkpoint starting: time/checkpoint starting: time;error/ERROR/relation x does not exist/relation x does not exist and more" ]] \
  || fail "G rows: $R"
[[ $(g13 "select pgvigil.log_message_shape('process 12 still waiting for ShareLock on tuple (0,5) after 1000.5 ms')") == 'process ... still waiting for ShareLock on tuple (...) after ... ms' ]] \
  || fail "G shape on 13: $(g13 "select pgvigil.log_message_shape('process 12 still waiting for ShareLock on tuple (0,5) after 1000.5 ms')")"
echo "G ok: 0079 migrated on PostgreSQL 13; level and message stored, a longer re-read kept one row; the shape rule runs"

if [[ -n "${LG_HOLD:-}" ]]; then   # a look at the pages: the server and the repository stay up this many seconds
  echo "HOLD $LG_HOLD s: $U  instances P=$P (PostgreSQL 18) P13=$P13ID  window from $FROM"
  sleep "$LG_HOLD"
fi
echo "PASS: proof-log-groups (A groups, rows, level; B shapes; C temp files; D percentiles; E PG 18 and F PG 13 checkpoints; G 0079 on PG 13)"
