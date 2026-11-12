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
#     the two names in the detail and the run's note in err; filespace (DBA Dash's File Space, the same collection) = failed.
#     With only the OFFLINE and ONLINE databases on another instance, read now: dbstate = ok|true|0|1|.
#  D. never: an instance nothing ran on: every one of the twenty-three keys is never, none critical or warning.
#  E. skipped: mssql_jobs logged as skipped and nothing else: jobs = n/a; blocking = never.
#  F. clock skew: the server's start time ten minutes AHEAD of the repository: uptime = ok|true|1|0|0 h.
#  G. one collection of a group fresh and another failed (mssql_ag ok now, mssql_replication error now):
#     availability = ok.
#  H. the response carries exactly twenty-three keys per SQL Server instance (qs: Query Store, task 129; audit: SQL Server Audit, task 158; disk: a volume's free space, task 176; task P08, DBA Dash's Summary columns: full / diff / log for backups, filespace for storage, logship and mirroring out of availability, checkdb, logspace, corruption, alerts, identity) and no row for a PostgreSQL instance.
#  I. Memory Dump on the crash threshold (task P08, 0117): instance i with one memory dump written 30 hours ago: with
#     the default (critical under 48 h, warning under 168) dumps = ok|true|1|0|1 file and its since is that dump; after
#     a root 'crash' row of critical 24 / warning 168 (import_pg_threshold, what the Summary's Memory Dump Thresholds
#     dialog's POST /api/pg/thresholds calls) dumps = ok|true|0|1|1 file; the roots part names the root row (crash 24 / 168, its threshold_id) and
#     the key's defaults (crash 48 / 168, uptime 12 / 48).
#  J. the collect part (Snapshot Age, Collection Errors (24hrs)), one row per active instance of either engine: a (only
#     mssql_instance, logged now): age_min = age_max under 60 s, stale 0, failing 0, errors_24h 0; b (logged 20 days
#     ago): stale 1; c (mssql_storage's last run an error, now): failing 1, errors_24h 1; the PostgreSQL instance
#     has a row with no age (nothing ran).
#  NOT PROVEN HERE: the page's own wording of these states (web/src/fleet.ts: 'stale', 'read failed', 'n/a', 'not
#  yet', a flag with ', stale' beside it) and the failed-fetch text - a browser render; a configured interval other
#  than the collector's default; the PostgreSQL database-state part (pgdb); the FULL / DIFF / LOG split of backup
#  findings and the five checks areas' texts (proof-clickmap T10 seeds them); DBA Dash's cell text (the page's).
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
i=$(inst i); q "select pgvigil.import_mssql_services($i, now(), jsonb_build_array(jsonb_build_object('kind', 'agent', 'engine_edition', 3, 'sessions', 2), jsonb_build_object('kind', 'dumps', 'dump_count', 1, 'last_dump_at_utc', to_char((now() - interval '30 hours') at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'))))" >/dev/null
logc "$i" mssql_services "now()" ok null

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
[[ "$(cell "$c" filespace state)" == failed ]] || fail "C: filespace state: $(cell "$c" filespace state)"
want "$c2" dbstate "ok|true|0|1|" "C offline only"
for k in blocking events availability logship mirroring full diff log jobs filespace disk uptime dbstate agent dbmail dumps qs audit checkdb logspace corruption alerts identity; do
  got=$(cell "$d" $k); [[ "$got" == never\|*\|0\|0\| ]] || fail "D: $k on an instance nothing ran on: '$got'"
done; echo "ok   D never: twenty-three keys, none flagged"
want "$e" jobs "n/a|true|0|0|" "E skipped"; [[ "$(cell "$e" blocking state)" == never ]] || fail "E: blocking"
want "$f" uptime "ok|true|1|0|0 h" "F clock skew"
[[ "$(cell "$g" availability state)" == ok ]] || fail "G: availability state: $(cell "$g" availability state)"; echo "ok   G one fresh, one failed: availability = ok"
got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["cells"]; c=d["columns"]; i=c.index("instance_id"); n={}
for r in d["rows"]: n[r[i]]=n.get(r[i],0)+1
print(len(n), sorted(set(n.values())), int(sys.argv[2]) in n)' "$WORK/sum.json" "$pg")
[[ "$got" == "9 [23] False" ]] || fail "H: instances, keys per instance, a PostgreSQL row: $got"; echo "ok   H: 9 instances x 23 keys (task P08's DBA Dash columns), no PostgreSQL row"
want "$i" dumps "ok|true|1|0|1 file" "I the default 48 h"
[[ "$(cell "$i" dumps since)" == "$(q "select to_char(last_dump_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI') from pgvigil.mssql_health where instance_id = $i")"* ]] || fail "I: since is '$(cell "$i" dumps since)'"
# the dialog's write is POST /api/pg/thresholds, a signed-in user's: here its function, as proof-clickmap T9 sets uptime
[[ "$(q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"set\",\"key\":\"crash\",\"level\":\"root\",\"crit\":24,\"warn\":168,\"ui_user\":\"proof\"}'::jsonb)->>'outcome'")" == done ]] || fail "I: set the root crash threshold"
curl -fsS "http://127.0.0.1:$PORT/api/mssql/summary" > "$WORK/sum.json" || fail "GET /api/mssql/summary (2)"
want "$i" dumps "ok|true|0|1|1 file" "I a root crash 24 / 168"
got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["roots"]; c=d["columns"]; R={r[c.index("key")]: dict(zip(c, r)) for r in d["rows"]}
f=lambda v: "-" if v is None else ("%g" % float(v))
print(" ".join("%s:%s/%s:%s/%s:%s" % (k, f(R[k]["crit"]), f(R[k]["warn"]), f(R[k]["crit_default"]), f(R[k]["warn_default"]), "set" if R[k]["threshold_id"] is not None else "none") for k in sorted(R)))' "$WORK/sum.json")
[[ "$got" == "crash:24/168:48/168:set uptime:-/-:12/48:none" ]] || fail "I: the roots part: $got"; echo "ok   I roots: $got"
# collect <instance id>: age_min|age_max|stale|failing|errors_24h ('-' for none)
collect() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["collect"]; c=d["columns"]; R=[dict(zip(c, r)) for r in d["rows"] if r[c.index("instance_id")] == int(sys.argv[2])]
r=R[0] if len(R)==1 else None
print("ROWS=%d" % len(R) if r is None else "|".join("-" if r[k] is None else str(r[k]) for k in ("age_min_secs","age_max_secs","stale","failing","errors_24h")))' "$WORK/sum.json" "$1"; }
ca=$(collect "$a"); IFS='|' read -r amin amax ast afl aer <<< "$ca"
[[ "$amin" =~ ^[0-9]+$ && "$amin" -lt 60 && "$amin" == "$amax" && "$ast|$afl|$aer" == "0|0|0" ]] || fail "J a: $ca"; echo "ok   J a fresh: $ca"
[[ "$(collect "$b" | cut -d'|' -f3)" == 1 ]] || fail "J b: $(collect "$b")"; echo "ok   J b stale: $(collect "$b")"
[[ "$(collect "$c" | cut -d'|' -f4-5)" == "1|1" ]] || fail "J c: $(collect "$c")"; echo "ok   J c failing: $(collect "$c")"
[[ "$(collect "$pg")" == "-|-|0|0|0" ]] || fail "J pg: $(collect "$pg")"; echo "ok   J PostgreSQL instance, nothing ran: $(collect "$pg")"
echo "proof-mssql-summary: PASS (A-J)"
