#!/usr/bin/env bash
# Proof of the SQL Server status cells of the Summary (GET /api/mssql/summary, internal/web/q_mssql_summary.go): what
# a cell says when the group's read is fresh, old, failed, skipped or missing, on rows imported for synthetic SQL
# Server instances. No SQL Server is needed.
#   PGVIGIL_ADMIN_DSN  a superuser connection without dbname (creates and drops a scratch database)
#
# Expected (written before the first run), each line a cell as state|sampled|critical|warning|value:
#  A. fresh: mssql_instance read now, the server started 5 hours ago: uptime = ok|true|1|0|5 h.
#  B. old: mssql_instance read 20 days ago, started 21 days ago: uptime = stale|true|0|0|21 d, read_at is that old read.
#  C. a failed run does not hide a critical, and databases are counted: mssql_storage read now with databases
#     SUSPECT, EMERGENCY, OFFLINE and ONLINE, then its next run logged as an error: dbstate = failed|true|2|0| with
#     the two names in the detail and the run's note in err; storage (the same collection) = failed.
#     With only the OFFLINE and ONLINE databases on another instance, read now: dbstate = ok|true|0|1|.
#  D. never: an instance nothing ran on: every one of the fourteen keys is never, none critical or warning.
#  E. skipped: mssql_jobs logged as skipped and nothing else: jobs = n/a; blocking = never.
#  F. clock skew: the server's start time ten minutes AHEAD of the repository: uptime = ok|true|1|0|0 h.
#  G. one collection of a group fresh and another failed (mssql_ag ok now, mssql_replication error now):
#     availability = ok.
#  H. the response carries exactly fourteen keys per SQL Server instance (qs: Query Store, task 129; audit: SQL Server Audit, task 158; disk: a volume's free space, task 176) and no row for a PostgreSQL instance.
#  NOT PROVEN HERE: the page's own wording of these states (web/src/fleet.ts: 'stale', 'read failed', 'n/a', 'not
#  yet', a flag with ', stale' beside it) and the failed-fetch text - a browser render; a configured interval other
#  than the collector's default; the PostgreSQL database-state part (pgdb).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
DB="pgvigil_mssqlsum_$RANDOM"; CFG=$(mktemp); WORK=$(mktemp -d); CREATED=""; SPID=""
cleanup() {
  rc=$?
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null || true
  if [[ -n "$CREATED" ]]; then psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $DB not dropped" >&2; fi
  rm -rf "$CFG" "$WORK"
  exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB"; CREATED=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\n' > "$CFG"
q() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || fail "migrate"
inst() { q "select pgvigil.ensure_instance('sum-$1', 'sqlserver', 'x', 160000, false, '{}', 'sqlserver')"; }
logc() { q "select pgvigil.log_collection($1, '$2', $3, 10, '$4', $5)" >/dev/null; }   # instance, collection, at, status, note
server() { # instance, read at, started at
  q "select pgvigil.import_mssql_instance($1, $2, jsonb_build_array(jsonb_build_object('kind', 'server', 'product_version', '16.0.1000.6'), jsonb_build_object('kind', 'sysinfo', 'cpu_count', 4, 'started_at_utc', to_char(($3) at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'))))" >/dev/null
}
file() { echo "{\"kind\":\"file\",\"database_id\":$1,\"database_name\":\"$2\",\"database_state\":\"$3\",\"file_id\":1,\"file_name\":\"$2_data\",\"type_desc\":\"ROWS\",\"size_bytes\":100,\"used_read\":0,\"growth_bytes\":0,\"growth_pct\":0,\"volume\":\"/data/\"}"; }
VOL='{"kind":"volume","volume":"/data/","total_bytes":1000,"free_bytes":400,"files":1}'

a=$(inst a); server "$a" "now()" "now() - interval '5 hours 10 minutes'"; logc "$a" mssql_instance "now()" ok null
b=$(inst b); server "$b" "now() - interval '20 days'" "now() - interval '21 days 1 hour'"; logc "$b" mssql_instance "now() - interval '20 days'" ok null
c=$(inst c); q "select pgvigil.import_mssql_storage($c, now() - interval '1 minute', '[$VOL,$(file 5 dbs SUSPECT),$(file 6 dbe EMERGENCY),$(file 7 dbo OFFLINE),$(file 8 dbok ONLINE)]'::jsonb)" >/dev/null
logc "$c" mssql_storage "now() - interval '1 minute'" ok null; logc "$c" mssql_storage "now()" error "'the proof''s failed run'"
c2=$(inst c2); q "select pgvigil.import_mssql_storage($c2, now(), '[$VOL,$(file 7 dbo OFFLINE),$(file 8 dbok ONLINE)]'::jsonb)" >/dev/null; logc "$c2" mssql_storage "now()" ok null
d=$(inst d)
e=$(inst e); logc "$e" mssql_jobs "now()" skipped "'not on this kind of server'"
f=$(inst f); server "$f" "now()" "now() + interval '10 minutes'"; logc "$f" mssql_instance "now()" ok null
g=$(inst g); logc "$g" mssql_ag "now()" ok null; logc "$g" mssql_replication "now()" error "'refused'"
pg=$(q "select pgvigil.ensure_instance('sum-pg', 'onprem', '17.0', 170000, false, '{}')")

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
"$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$PORT" 2>"$WORK/serve.log" & SPID=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fsS "http://127.0.0.1:$PORT/api/mssql/summary" > "$WORK/sum.json" || { cat "$WORK/serve.log" >&2; fail "GET /api/mssql/summary"; }
# cell <instance id> <key> [field]: state|sampled|critical|warning|value, or one field of the row
cell() { python3 - "$WORK/sum.json" "$1" "$2" "${3:-}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["cells"]; c = d["columns"]
rows = [dict(zip(c, r)) for r in d["rows"] if r[c.index("instance_id")] == int(sys.argv[2]) and r[c.index("key")] == sys.argv[3]]
if len(rows) != 1: print("ROWS=%d" % len(rows)); sys.exit(0)
r = rows[0]
if sys.argv[4]: print(r[sys.argv[4]] if r[sys.argv[4]] is not None else "")
else: print("%s|%s|%s|%s|%s" % (r["state"], str(r["sampled"]).lower(), r["critical"], r["warning"], r["value"] if r["value"] is not None else ""))
PY
}
want() { local got; got=$(cell "$1" "$2"); [[ "$got" == "$3" ]] || fail "$4: the $2 cell is '$got', want '$3'"; echo "ok   $4: $2 = $got"; }

want "$a" uptime "ok|true|1|0|5 h" "A fresh"
want "$b" uptime "stale|true|0|0|21 d" "B old"
[[ "$(cell "$b" uptime read_at)" == "$(q "select to_char(snapshot_at at time zone 'UTC', 'YYYY-MM-DD') from pgvigil.collection_dates where instance_id=$b and collection='mssql_instance'")"* ]] || fail "B: read_at is '$(cell "$b" uptime read_at)'"
want "$c" dbstate "failed|true|2|0|" "C a failed run"
[[ "$(cell "$c" dbstate detail)" == *"dbe emergency"*"dbs suspect"* ]] || fail "C: the detail: $(cell "$c" dbstate detail)"
[[ "$(cell "$c" dbstate err)" == *"mssql_storage: the proof's failed run"* ]] || fail "C: err: $(cell "$c" dbstate err)"
[[ "$(cell "$c" storage state)" == failed ]] || fail "C: storage state: $(cell "$c" storage state)"
want "$c2" dbstate "ok|true|0|1|" "C offline only"
for k in blocking events availability backups jobs storage disk uptime dbstate agent dbmail dumps qs audit; do
  got=$(cell "$d" $k); [[ "$got" == never\|*\|0\|0\| ]] || fail "D: $k on an instance nothing ran on: '$got'"
done; echo "ok   D never: fourteen keys, none flagged"
want "$e" jobs "n/a|true|0|0|" "E skipped"; [[ "$(cell "$e" blocking state)" == never ]] || fail "E: blocking"
want "$f" uptime "ok|true|1|0|0 h" "F clock skew"
[[ "$(cell "$g" availability state)" == ok ]] || fail "G: availability state: $(cell "$g" availability state)"; echo "ok   G one fresh, one failed: availability = ok"
got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["cells"]; c=d["columns"]; i=c.index("instance_id"); n={}
for r in d["rows"]: n[r[i]]=n.get(r[i],0)+1
print(len(n), sorted(set(n.values())), int(sys.argv[2]) in n)' "$WORK/sum.json" "$pg")
[[ "$got" == "8 [14] False" ]] || fail "H: instances, keys per instance, a PostgreSQL row: $got"; echo "ok   H: 8 instances x 14 keys (the audit cell since 158's join, the disk cell since 176), no PostgreSQL row"
echo "proof-mssql-summary: PASS (A-H)"
