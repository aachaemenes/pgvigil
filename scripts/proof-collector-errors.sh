#!/usr/bin/env bash
# proof-collector-errors.sh - the collector's error log (/api/collectorerrors, the page #/collectorerrors) and the fleet's SQL Server
# error stream (/api/mssql/errorfleet, the page #/mssqlerrors), on real collector runs and seeded rows.
#
# Needs: docker, psql, curl, python3, chromium (row G), the build to prove at PGVIGIL_BIN (default bin/pgvigil), run from
# the repository root. Two PostgreSQL containers of its own (the repository and a monitored target; trust on 127.0.0.1),
# removed on every exit path. Every expected result below was written before the code it proves.
#
# The contract it proves:
#   GET /api/collectorerrors?[instance=][&tag=][&service=1][&from=&to=][&view=instance|collection|error][&coll=]
#       [&type=Error|Warning|Skipped][&stage=Connect|Collect|Import|Other][&q=][&skipped=1]
#     part rows  - view instance: instance_id, instance, collections, total, errors, warnings, skipped, connect, collect,
#                  import, other, first_at, last_at, last_message, suggestion, help, mark, new_since_mark (a count of 0 is
#                  NULL); view collection: collection, instances, total, the same counts, first_at, last_at, last_message;
#                  view error: log_id, at, instance_id, instance, collection, type, stage, note, acked, link
#     part insights - one row per suggestion kind: kind, instances, text, help
#     part marks    - instance_id, instance, mark (the highest live 'collector errors' log_id), ack_ids
#     the service's own failures: instance_id NULL, instance '(the service)', collection 'alerts' | 'report mail' |
#     'DBA Dash import' | 'export', each with the link of the page that handles it, never with instance=; service=1
#     lists them alone
#   GET /api/mssql/errorfleet?[instance=][&tag=][&from=&to=][&n=][&noise=1]
#     part byerror - error_number, severity (worst), occurrences (not hidden), instances, first_at, last_at, message,
#                    hidden; a number whose every line is hidden is left out unless noise=1
#     part lines   - at, instance_id, instance, error_number, severity, state, class, database, message, source
#                    ('error log' | 'AlwaysOn_health'), noise (its label when noise=1)
#     part noise   - this page's labels (check_key 'error log' or 'error log:<n>'): ack_id, check_key, match_text, instance,
#                    tag, note, hits (lines it hides in the window)
#     part cannot  - error_number, why: a listed number pgvigil keeps no row of (said, not collected)
#     part agstate - instance_id, instance, state: an instance whose AlwaysOn_health capture was not read
#   GET /api/mssql/summary?part=collect - Collection Health's cell (ch_level, ch_n: B6G-N's, honouring the mark) and
#     detail after the instance's 'collector errors' mark
#
# Rows (expected; RED = on main ebf9a9c's build):
#  A. real runs on the target: activity with its import refused (error, Import), schema with ONE database's part refused
#     (partial = Warning, Import: the run goes on), statements with pg_stat_statements created but not preloaded (error,
#     Collect), an unreachable instance (Connect); seeded old rows read by their note ('connect: ' Connect, else Collect),
#     an 'ok' rollup row absent, a skip hidden. Per instance row the types and the stages each add up to Total. C10:
#     two collections denied a right -> the rights suggestion, one -> none, every error 'connect: ' -> unreachable; the
#     insights part names both. RED: no route.
#  B. every count of the instance and collection views lists exactly the rows it counts (view=error with its filters);
#     the service rows' count likewise (service=1). RED: no route.
#  C. the service rows: a failed and a refused alert send, a failed test send (its note starts 'test send'), a failed
#     and a refused report mail, a configured repository not read - and not the unconfigured one, not a sent alert; none
#     at instance=; the reads write nothing (acks, ack_log, collection_log, collection_dates unchanged). RED: no route.
#  Cx. the Parquet export's service row (export_service, 0256): a configured export with a window whose last attempt
#     failed (beside it a window that failed and then went well, and a later window ok), one 4 hours behind (its last
#     run 4 hours back) and one behind for longer that then failed a window are three '(the service)' rows - collection
#     'export', Error, Other, link '#/collector', the note export_service's detail ending ' - since <its start> UTC';
#     an export turned off (runs, no state) and a current one are no rows; none at instance=; the service row's Errors
#     count, now 9, lists its nine rows. The trouble starts at the earlier of the earliest last attempt of a window still
#     failed and 3 hours after the newest window (not the export's last run, not the window that recovered, not the
#     later failure of an export already behind): a range ending a minute after that start holds the row, a range
#     ending a minute before does not. The row is a state read at the range's end, so it is dated there (now for a range
#     that ends later) and its note says since when: the newest rows of the error list. With export_service gone (a
#     repository below 0256) the page still answers: the six other service rows, no export row. The reads write nothing
#     (export_runs, export_state unchanged). RED (498f7bcc): no export row - the rows, their dates and notes and the
#     count of 9 fail; the instance=, below-0256 and no-write rows pass. RED (96ff6ed1, dated at the start, the failure
#     first): the export behind then failing dated at its failure, each row dated at its start (not the range's end), no
#     'since' in the notes, the export rows not the newest; the rest pass.
#  D. the acknowledgement, on Collection Health's cell (ch_level / ch_n: the row moved there from the
#     errors_24h / failing columns B6G-N's Collection Health replaced; counted from the acknowledgement - the errors at
#     or under its mark never count again, A5): X's 1 / 1 (c2 warning) / detail 'c2: the last
#     run failed'; acknowledged up to its newest log_id -> 0 / 0 / no such line, the error view's rows acked; an
#     older-started run logged after it -> 1 / 1; a second acknowledgement -> 0 / 0; Unacknowledge (every live row
#     ended) -> 1 / 2 (c2, c3); a live row with seen_state 'x' -> the part still answers, 1 / 2; ack_log holds every add
#     and end. RED (before the cell read the mark): the cell stays 1 / 1 after the acknowledgement on a Collection Health that reads no ack.
#  E. a skip only with skipped=1; no Retry anywhere (no 'retries' column). RED: no route.
#  F. the stream, own seeded rows: 824 (sev 24, page (1:178064), database ID 5 -> 'database ID 5 (now inv)'), 9002 on
#     two instances ('salesdb', 'hr'), 823 (no database: empty), 1480 from AlwaysOn_health (sev 10, a listed number:
#     'agdb', state empty, class its family), 35206 in the error log AND AlwaysOn_health at the same second (once) plus
#     one in AlwaysOn_health alone; out: a numberless custom-string line, an 18456 at 14, a 3041 at 16. A label
#     'error log:17806' hides the three 17806 lines only (hits 3; the 824 stays); a label 'error log' with no text and
#     an instance-only label hide nothing; noise=1 shows the 17806 lines labelled; tag= narrows to its instances;
#     agstate names the instance whose AlwaysOn_health is stopped; at the window's edges an AlwaysOn_health event whose
#     error-log twin lies just outside the window is counted; n past a 32-bit integer is a 400. RED: no route.
#  G. the pages (headless chromium): #/collectorerrors lists the target; at one instance per collection; Acknowledge
#     offered with no filter over 7 days, not with coll= and not over the last hour (it would cover errors not shown); the page says pgvigil never retries; #/mssqlerrors lists 824 with its
#     Learn link and the stopped AlwaysOn_health; Collection dates links to #/collectorerrors; the error-log finding on
#     #/findings links to #/mssqlerrors. (proof-a11y.sh runs once over the build: both themes, the new tabs.) RED: the
#     pages do not exist.
#  H. a collector login calls the 6-argument and the 7-argument log_collection (no 'function is not unique'): rows in
#     collection_dates and collection_log, stage NULL and 'import'; a reader login is refused. RED: no 7-argument form.
#  Not proven here: drill in place and Back in a browser (G reads the addresses only); both themes (proof-a11y.sh, run
#  once over the build); the Collector page's failure link (this store has no heartbeat runs: its counts are 0); the SQL
#  Server batch path's import stage (internal/mssql xe_test.go TestRunBatched, the swallowing reader included); the
#  'cannot' part's words (a constant).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
PIMG=${PGVIGIL_PG_IMAGE:-postgres:18}
SUF=$$
RCT=cerr-repo-$SUF; TCT=cerr-target-$SUF
RPORT=$((21000 + SUF % 9000)); TPORT=$((31000 + SUF % 9000)); PORT=$((41000 + SUF % 9000)); PORT2=$((PORT + 1))
WORK=$(mktemp -d); SRV=; SRV2=
bad=0
fail() { echo "FAIL: $*" >&2; exit 1; }
check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (got '$1', want '$2')"; bad=$((bad + 1)); fi; }
cleanup() {
  rc=$?; set +e
  [ -n "$SRV" ] && kill "$SRV" >/dev/null 2>&1
  [ -n "$SRV2" ] && kill "$SRV2" >/dev/null 2>&1
  docker rm -f "$RCT" "$TCT" >/dev/null 2>&1 || echo "CLEANUP: containers $RCT / $TCT not removed" >&2
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
[ -x "$BIN" ] || fail "no build at $BIN"

docker run -d --name "$RCT" -e POSTGRES_HOST_AUTH_METHOD=trust -p "127.0.0.1:$RPORT:5432" "$PIMG" -c max_connections=200 >/dev/null
docker run -d --name "$TCT" -e POSTGRES_HOST_AUTH_METHOD=trust -p "127.0.0.1:$TPORT:5432" "$PIMG" >/dev/null
for p in $RPORT $TPORT; do
  for _ in $(seq 1 30); do psql "host=127.0.0.1 port=$p user=postgres" -XAtqc "select 1" >/dev/null 2>&1 && break; sleep 2; done
done
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$RPORT user=postgres dbname=postgres"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
tq() { psql "host=127.0.0.1 port=$TPORT user=postgres dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

# ---- the target: cerr_ok (pg_stat_statements created, not preloaded: its read fails) and cerr_fail (its schema part
# is refused by the repository below)
tq "create database cerr_ok" >/dev/null; tq "create database cerr_fail" >/dev/null
tq "create extension pg_stat_statements; create table cerr_ok_t (id int primary key)" cerr_ok >/dev/null
tq "create table cerr_fail_marker (id int primary key)" cerr_fail >/dev/null
export CERR_PG_DSN="host=127.0.0.1 port=$TPORT user=postgres dbname=cerr_ok sslmode=disable"
export CERR_DOWN_DSN="host=127.0.0.1 port=$((TPORT + 3)) user=postgres dbname=postgres sslmode=disable connect_timeout=3"
PGT=cerr-pg-$SUF; DOWN=cerr-down-$SUF
cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $PGT
    engine: postgres
    dsn: env:CERR_PG_DSN
  - name: $DOWN
    engine: postgres
    dsn: env:CERR_DOWN_DSN
EOF
"$BIN" migrate -config "$WORK/cfg.yaml" > "$WORK/migrate.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/migrate.log")"
fn() { [ "$(q "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname = '$1'")" != 0 ]; }

# ---- the repository refuses two imports: activity always, schema for the cerr_fail database's part only. Each
# import_<collection> is renamed and a wrapper of the same arguments raises or calls it (SECURITY DEFINER kept: the
# collector's door is unchanged for every other part)
refuse() {   # refuse <collection> <SQL condition on p_payload, true = refuse>
  local args; args=$(q "select pg_get_function_identity_arguments('pgvigil.import_$1'::regproc)")
  q "alter function pgvigil.import_$1($args) rename to import_$1_cerr_real" >/dev/null
  q "create function pgvigil.import_$1(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb) returns void
     language plpgsql security definer set search_path = pg_catalog, pgvigil as \$f\$
     BEGIN
       IF $2 THEN RAISE EXCEPTION 'cerr: this import is refused'; END IF;
       PERFORM pgvigil.import_$1_cerr_real(p_instance_id, p_snapshot_at, p_payload);
     END \$f\$" >/dev/null
}
refuse activity "true"
refuse schema "p_payload::text LIKE '%cerr_fail_marker%'"
once() { "$BIN" collect -config "$WORK/cfg.yaml" -once "$1" -instance "$2" > "$WORK/once-$1-$2.log" 2>&1 || true; }
once activity "$PGT"; once schema "$PGT"; once statements "$PGT"; once activity "$DOWN"
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
PGI=$(iid "$PGT"); DNI=$(iid "$DOWN")
[ -n "$PGI" ] && [ -n "$DNI" ] || fail "the two configured instances were not created (see $WORK/once-*.log)"

syn() {   # a synthetic instance: name suffix, engine[, tags as a text[] literal]: its id
  local tg=${3:-}; [ -n "$tg" ] || tg='{}'
  q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
       values ('cerr-$1-$SUF', '$( [ "$2" = sqlserver ] && echo sqlserver || echo onprem )', '$tg', now(), now(), true, '$2') returning instance_id" | head -1
}
lc() { q "select pgvigil.log_collection($1, '$2', now() - interval '$3 minutes', 10, '$4', \$n\$$5\$n\$)" >/dev/null; }
OLD=$(syn old postgres); P=$(syn perm postgres); QI=$(syn one postgres); UI=$(syn down2 postgres)
lc "$OLD" c_conn 30 error "connect: connection refused"; lc "$OLD" c_read 29 error "boom at the read"
lc "$OLD" c_skip 28 skipped "not applicable here"
q "insert into pgvigil.collection_log (instance_id, collection, snapshot_at, duration_ms, status, note)
   values ($OLD, 'job_stats_hourly', now() - interval '27 minutes', 1, 'ok', 'rollup healed: 1 hour')" >/dev/null
lc "$P" p1 20 error "permission denied for table pg_authid"; lc "$P" p2 19 error "must be superuser to read this"
lc "$QI" q1 18 error "permission denied for view pg_stat_x"
lc "$UI" u1 17 error "connect: timeout"; lc "$UI" u2 16 error "connect: timeout"

FROM=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ); TO=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)
"$BIN" serve -config "$WORK/cfg.yaml" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$PORT2" -no-login > "$WORK/serve2.log" 2>&1 & SRV2=$!
U2="http://127.0.0.1:$PORT2"
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U2/" && break; sleep 0.5; done
get() { curl -s "$U2$1" > "$WORK/r.json" || true; }
# py <python expression>: d = the reply; T(part) = its rows as dicts; prints the value, 'NOJSON' when the reply is none
py() { python3 -I -c "
import json, sys
try: d = json.load(open('$WORK/r.json'))
except Exception: print('NOJSON'); sys.exit(0)
def T(p):
    t = d.get(p) if isinstance(d, dict) else None
    if not t: return []
    return [dict(zip(t['columns'], r)) for r in t['rows']]
def C(p):
    t = d.get(p) if isinstance(d, dict) else None
    return t['columns'] if t else []
def one(rows, **kw):
    m = [r for r in rows if all(str(r.get(k)) == str(v) for k, v in kw.items())]
    return m[0] if len(m) == 1 else {}
print($1)"; }
W="from=$FROM&to=$TO"

echo "--- A. real runs, the types and stages, the suggestions"
get "/api/collectorerrors?view=instance&$W"
check "$(py "'|'.join(str(one(T('rows'), instance='$PGT').get(k)) for k in ('total','errors','warnings','connect','collect','import','other'))")" \
  "3|2|1|None|1|2|None" "A: the target - activity's refused import and schema's one refused part Import, statements Collect; schema a Warning"
check "$(py "'|'.join(str(one(T('rows'), instance='$DOWN').get(k)) for k in ('total','errors','connect'))")" "1|1|1" "A: the unreachable instance Connect"
check "$(py "'|'.join(str(one(T('rows'), instance='cerr-old-$SUF').get(k)) for k in ('total','connect','collect','skipped'))")" "2|1|1|None" \
  "A: old rows by their note, the 'ok' rollup row absent, the skip hidden"
check "$(py "all((r['errors'] or 0) + (r['warnings'] or 0) + (r['skipped'] or 0) == r['total'] == (r['connect'] or 0) + (r['collect'] or 0) + (r['import'] or 0) + (r['other'] or 0) for r in T('rows')) and len(T('rows')) > 0")" \
  "True" "A: per row the types and the stages each add up to Total"
check "$(py "'|'.join(str(bool(one(T('rows'), instance=n).get('suggestion'))) for n in ('cerr-perm-$SUF','cerr-one-$SUF','cerr-down2-$SUF'))")|$(py "'unreachable' in str(one(T('rows'), instance='cerr-down2-$SUF').get('suggestion')).lower()")" \
  "True|False|True|True" "A: C10 - two collections denied a right suggest, one does not; every error 'connect: ' says unreachable"
check "$(py "sorted([r['kind'] for r in T('insights')])")|$(py "all('cerr-perm-$SUF' in str(r['instances']) or 'cerr-down2-$SUF' in str(r['instances']) for r in T('insights'))")" \
  "['rights', 'unreachable']|True" "A: one card per suggestion kind, naming its instances"
get "/api/collectorerrors?view=instance&skipped=1&$W"
check "$(py "one(T('rows'), instance='cerr-old-$SUF').get('skipped')")|$(py "one(T('rows'), instance='cerr-old-$SUF').get('total')")" "1|3" "A: skipped=1 counts the skip"

echo "--- B. every count lists the rows it counts"
get "/api/collectorerrors?view=instance&skipped=1&$W"
python3 -I -c "
import json
d = json.load(open('$WORK/r.json')); t = d['rows']
for r in [dict(zip(t['columns'], x)) for x in t['rows']]:
    for col, key, val in [('errors','type','Error'),('warnings','type','Warning'),('skipped','type','Skipped'),('connect','stage','Connect'),
                          ('collect','stage','Collect'),('import','stage','Import'),('other','stage','Other')]:
        if r.get(col):
            sel = 'service=1' if r['instance_id'] is None else 'instance=%d' % r['instance_id']
            print('%s|%s=%s|%d|%s' % (sel, key, val, r[col], r['instance']))
" > "$WORK/b.txt" 2>/dev/null || true
BN=0; BOK=0
while IFS='|' read -r sel f want name; do
  BN=$((BN + 1)); get "/api/collectorerrors?view=error&skipped=1&$sel&$f&$W"
  [ "$(py "len(T('rows'))")" = "$want" ] && BOK=$((BOK + 1)) || echo "     B: $name $f lists $(py "len(T('rows'))"), counts $want"
done < "$WORK/b.txt"
check "$BOK/$BN|$([ "$BN" -ge 10 ] && echo many)" "$BN/$BN|many" "B: each of the instance view's counts lists its rows"
get "/api/collectorerrors?view=collection&skipped=1&instance=$PGI&$W"
CB=$(py "'|'.join('%s=%s' % (r['collection'], r['total']) for r in sorted(T('rows'), key=lambda r: r['collection']))")
CBOK=yes; for kv in ${CB//|/ }; do c=${kv%%=*}; n=${kv##*=}; get "/api/collectorerrors?view=error&skipped=1&instance=$PGI&coll=$c&$W"; [ "$(py "len(T('rows'))")" = "$n" ] || CBOK="no ($c)"; done
check "$CB|$CBOK" "activity=1|schema=1|statements=1|yes" "B: the target's collection view, each Total listing its rows"

echo "--- C. the service's own failures"
q "select pgvigil.ensure_month_partition('alert_log', now()), pgvigil.ensure_month_partition('alert_log', now() - interval '1 hour')" >/dev/null 2>&1 || true
q "insert into pgvigil.alert_log (snapshot_at, channel, kind, destination, outcome, error, keys) values
     (now() - interval '10 minutes', 'ops', 'mail', 'ops@example.invalid', 'failed', 'smtp: 535 authentication failed', '{k1}'),
     (now() - interval '9 minutes', 'ops', 'mail', 'ops@example.invalid', 'refused', 'the server offers no STARTTLS', '{k2}'),
     (now() - interval '8 minutes', 'ops', 'mail', 'ops@example.invalid', 'failed', 'smtp: dial tcp: refused', '{test-7}'),
     (now() - interval '7 minutes', 'ops', 'mail', 'ops@example.invalid', 'sent', NULL, '{k3}')" >/dev/null
q "insert into pgvigil.report_mail_sends (kind, name, route, requested_by, requested_at, taken_at, done_at, channel, recipients, subject, outcome, error) values
     ('now', 'Daily summary', '#/summary', 'proof', now() - interval '6 minutes', now() - interval '6 minutes', now() - interval '359 seconds', 'ops', '{a@example.invalid}', 's', 'failed', 'smtp: 550 mailbox unavailable'),
     ('now', 'Daily summary', '#/summary', 'proof', now() - interval '5 minutes', now() - interval '5 minutes', now() - interval '299 seconds', 'ops', '{a@example.invalid}', 's', 'refused', 'no STARTTLS')" >/dev/null
q "insert into pgvigil.dbadash_repositories (repository, is_configured, status, reason, read_at) values
     ('cerr-repo-1', true, 'not read', 'login failed for user', now() - interval '4 minutes'),
     ('cerr-repo-2', false, 'not read', 'removed from the config', now() - interval '4 minutes'),
     ('cerr-repo-3', true, 'ok', NULL, now() - interval '4 minutes')" >/dev/null
W0=$(q "select (select count(*) from pgvigil.acks) || '/' || (select count(*) from pgvigil.ack_log) || '/' || (select count(*) from pgvigil.collection_log) || '/' || (select count(*) from pgvigil.collection_dates)")
get "/api/collectorerrors?view=error&service=1&$W"
check "$(py "sorted(r['collection'] for r in T('rows'))")" "['DBA Dash import', 'alerts', 'alerts', 'alerts', 'report mail', 'report mail']" \
  "C: failed and refused alert sends, a failed test send, two report mails, one configured repository not read"
check "$(py "sum(1 for r in T('rows') if str(r['note']).startswith('test send'))")|$(py "all(r['instance'] == '(the service)' and r['instance_id'] is None and r['link'] for r in T('rows'))")|$(py "any('cerr-repo-2' in str(r['note']) for r in T('rows'))")" \
  "1|True|False" "C: the test send labelled, each row '(the service)' with its link, the unconfigured repository absent"
get "/api/collectorerrors?view=error&instance=$PGI&$W"
check "$(py "sum(1 for r in T('rows') if r['instance'] == '(the service)')")" "0" "C: no service row at one instance"
get "/api/collectorerrors?view=instance&$W"
SE=$(py "one(T('rows'), instance='(the service)').get('errors')"); SO=$(py "one(T('rows'), instance='(the service)').get('other')")
get "/api/collectorerrors?view=error&service=1&type=Error&$W"; SE2=$(py "len(T('rows'))")
get "/api/collectorerrors?view=error&service=1&stage=Other&$W"; SO2=$(py "len(T('rows'))")
check "$SE|$SO|$SE2|$SO2" "6|6|6|6" "C (B's rule for the service row): its Errors and Other counts each list their six rows"
check "$(q "select (select count(*) from pgvigil.acks) || '/' || (select count(*) from pgvigil.ack_log) || '/' || (select count(*) from pgvigil.collection_log) || '/' || (select count(*) from pgvigil.collection_dates)")" "$W0" "C: the reads wrote nothing"

echo "--- Cx. the Parquet export's service row"
# seeded straight into 0256's tables (the door's own rows are proof-parquet.sh's): cerrx fails window A at its last
# attempt XF; window B failed earlier (XB) and then went well; its newest window is this hour's, so it is not behind.
# cerry stopped 4 hours ago: its newest window ended at XE - 4 h, so it has been behind since XE - 1 h. cerrv has been
# behind since XE - 70 min (its newest window ended XE - 250 min) and then failed a window at XE - 10 min: its trouble
# began when it fell behind. cerrz was turned off (runs, no state); cerrw is current.
XE=$(date -u +%s); XH=$(( XE / 3600 * 3600 )); xts() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
XF=$((XE - 1200)); XB=$((XE - 3000)); YS=$((XE - 3600)); VS=$((XE - 4200)); VF=$((XE - 600))
ymd() { date -u -d "@$1" '+%Y-%m-%d %H:%M'; }
q "insert into pgvigil.export_state (name, destination, configured_at, last_run_at, last_outcome, last_error, newest_window_to) values
     ('cerrx', 's3://cerr/x', '$(xts $((XE - 86400)))', '$(xts $((XE - 300)))', 'ok', NULL, '$(xts $XH)'),
     ('cerry', 's3://cerr/y', '$(xts $((XE - 86400)))', '$(xts $((XE - 14000)))', 'ok', NULL, '$(xts $((XE - 14400)))'),
     ('cerrv', 's3://cerr/v', '$(xts $((XE - 86400)))', '$(xts $VF)', 'failed', 's3: 500 InternalError', '$(xts $((VS - 10800)))'),
     ('cerrw', 's3://cerr/w', '$(xts $((XE - 86400)))', '$(xts $((XE - 300)))', 'ok', NULL, '$(xts $XH)')" >/dev/null
q "insert into pgvigil.export_runs (name, window_from, window_to, started_at, finished_at, outcome, error, login) values
     ('cerrx', '$(xts $((XH - 10800)))', '$(xts $((XH - 7200)))', '$(xts $((XF - 60)))', '$(xts $XF)', 'failed', 's3: 403 AccessDenied', 'proof'),
     ('cerrx', '$(xts $((XH - 7200)))', '$(xts $((XH - 3600)))', '$(xts $((XB - 60)))', '$(xts $XB)', 'failed', 's3: timeout', 'proof'),
     ('cerrx', '$(xts $((XH - 7200)))', '$(xts $((XH - 3600)))', '$(xts $((XE - 360)))', '$(xts $((XE - 330)))', 'ok', NULL, 'proof'),
     ('cerrx', '$(xts $((XH - 3600)))', '$(xts $XH)', '$(xts $((XE - 330)))', '$(xts $((XE - 300)))', 'ok', NULL, 'proof'),
     ('cerry', '$(xts $((XE - 18000)))', '$(xts $((XE - 14400)))', '$(xts $((XE - 14060)))', '$(xts $((XE - 14000)))', 'ok', NULL, 'proof'),
     ('cerrv', '$(xts $((VS - 14400)))', '$(xts $((VS - 10800)))', '$(xts $((VS - 10760)))', '$(xts $((VS - 10700)))', 'ok', NULL, 'proof'),
     ('cerrv', '$(xts $((XH - 3600)))', '$(xts $XH)', '$(xts $((VF - 60)))', '$(xts $VF)', 'failed', 's3: 500 InternalError', 'proof'),
     ('cerrz', '$(xts $((XH - 3600)))', '$(xts $XH)', '$(xts $((XE - 400)))', '$(xts $((XE - 390)))', 'failed', 's3: gone', 'proof'),
     ('cerrw', '$(xts $((XH - 3600)))', '$(xts $XH)', '$(xts $((XE - 330)))', '$(xts $((XE - 300)))', 'ok', NULL, 'proof')" >/dev/null
X0=$(q "select (select count(*) from pgvigil.export_runs) || '/' || (select count(*) from pgvigil.export_state)")
get "/api/collectorerrors?view=error&service=1&coll=export&$W"
check "$(py "sorted(str(r['note'])[:max(0, str(r['note']).find(':'))] for r in T('rows'))")" "['Parquet export cerrv', 'Parquet export cerrx', 'Parquet export cerry']" \
  "Cx: the failing export, the one behind and the one behind then failing are rows; the export turned off and the current one are not"
check "$(py "all((r['instance'], r['instance_id'], r['type'], r['stage'], r['link'], r['acked']) == ('(the service)', None, 'Error', 'Other', '#/collector', False) for r in T('rows')) and len(T('rows')) == 3")|$(py "any('1 window(s) failed at their last attempt' in str(r['note']) and 's3: 403 AccessDenied' in str(r['note']) for r in T('rows'))")|$(py "any('4 hours behind' in str(r['note']) for r in T('rows'))")" \
  "True|True|True" "Cx: each '(the service)', Error, Other, linked to #/collector, never acknowledged; the notes are export_service's"
get "/api/collectorerrors?view=error&instance=$PGI&$W"
check "$(py "sum(1 for r in T('rows') if r['collection'] == 'export' or r['instance'] == '(the service)')")" "0" "Cx: no export row at one instance"
get "/api/collectorerrors?view=instance&$W"; SE=$(py "one(T('rows'), instance='(the service)').get('errors')")
get "/api/collectorerrors?view=error&service=1&type=Error&$W"; SE2=$(py "len(T('rows'))")
check "$SE|$SE2" "9|9" "Cx: the service row's Errors count, nine, lists its nine rows"
seen() { get "/api/collectorerrors?view=error&service=1&coll=export&to=$(xts "$2")"; py "any(str(r['note']).startswith('Parquet export $1:') for r in T('rows'))"; }
check "$(seen cerrx $((XF + 60)))|$(seen cerrx $((XF - 60)))|$(seen cerry $((YS + 60)))|$(seen cerry $((YS - 60)))|$(seen cerrv $((VS + 60)))|$(seen cerrv $((VS - 60)))" "True|False|True|False|True|False" \
  "Cx: the trouble's start - a range ending a minute after it (the failed window's last attempt; 3 hours after the newest window; for the export behind then failing, when it fell behind) holds the row, one ending a minute before does not"
# the row is a state read at the range's end: dated there (now for a range ending later), its note saying since when
atx() { get "/api/collectorerrors?view=error&service=1&coll=export&${3:-to=$(xts "$2")}"; py "next((round(__import__('datetime').datetime.fromisoformat(str(r['at']).replace('Z', '+00:00')).timestamp()) for r in T('rows') if str(r['note']).startswith('Parquet export $1:')), None)"; }
NOWX=$(date -u +%s); ATN=$(atx cerry 0 "to=$(xts $((XE + 3600)))"); NOWY=$(date -u +%s)
check "$(atx cerrx $((XF + 120)))|$([ -n "$ATN" ] && [ "$ATN" != None ] && [ "$ATN" -ge $((NOWX - 2)) ] && [ "$ATN" -le $((NOWY + 2)) ] && echo now)" "$((XF + 120))|now" \
  "Cx: dated at the range's end (a range ending 2 minutes after cerrx's start), and now for a range that ends later"
get "/api/collectorerrors?view=error&service=1&coll=export&$W"
check "$(py "'|'.join(str(r['note']).split(' - since ')[-1] for r in sorted(T('rows'), key=lambda r: r['note']))")" "$(ymd $VS) UTC|$(ymd $XF) UTC|$(ymd $YS) UTC" \
  "Cx: each note ends ' - since <the trouble's start> UTC'"
get "/api/collectorerrors?view=error&service=1&$W"
check "$(py "[r['collection'] for r in T('rows')][:3]")" "['export', 'export', 'export']" "Cx: the export rows, read now, are the newest of the error list"
q "alter view pgvigil.export_service rename to export_service_cerr" >/dev/null
XC=$(curl -s -o "$WORK/r.json" -w '%{http_code}' "$U2/api/collectorerrors?view=error&service=1&$W")
check "$XC|$(py "sorted(r['collection'] for r in T('rows'))")" "200|['DBA Dash import', 'alerts', 'alerts', 'alerts', 'report mail', 'report mail']" \
  "Cx: a repository without export_service (below 0256): the page answers, the six other service rows, no export row"
q "alter view pgvigil.export_service_cerr rename to export_service" >/dev/null
check "$(q "select (select count(*) from pgvigil.export_runs) || '/' || (select count(*) from pgvigil.export_state)")" "$X0" "Cx: the reads wrote nothing"

echo "--- E. skips and retries"
get "/api/collectorerrors?view=error&$W"
check "$(py "sum(1 for r in T('rows') if r['type'] == 'Skipped')")|$(py "len(T('rows')) > 0")" "0|True" "E: no skip without skipped=1 (rows there)"
get "/api/collectorerrors?view=error&skipped=1&$W"
check "$(py "sum(1 for r in T('rows') if r['type'] == 'Skipped')")" "1" "E: the skip with skipped=1"
get "/api/collectorerrors?view=instance&$W"
check "$(py "[c for c in C('rows') if 'retr' in c.lower()]")|$(py "len(C('rows')) > 0")" "[]|True" "E: no Retry column (the columns there)"

echo "--- H. the two forms of log_collection"
q "create role cerr_col login in role pgvigil_collector; create role cerr_rd login in role pgvigil_reader" >/dev/null
CD="${PGVIGIL_REPO_DSN/user=postgres/user=cerr_col}"; RD="${PGVIGIL_REPO_DSN/user=postgres/user=cerr_rd}"
H6=$(psql "$CD" -XAt -c "select pgvigil.log_collection($OLD, 'h6', now(), 1, 'error', 'h six')" >/dev/null 2>&1 && echo ok || echo no)
H7=$(psql "$CD" -XAt -c "select pgvigil.log_collection($OLD, 'h7', now(), 1, 'error', 'h seven', 'import')" >/dev/null 2>&1 && echo ok || echo no)
HR=$(psql "$RD" -XAt -c "select pgvigil.log_collection($OLD, 'h8', now(), 1, 'error', 'h eight', 'import')" 2>&1 || true)
HS=$(q "select string_agg(collection || '=' || coalesce(stage, 'null'), ',' order by collection) from pgvigil.collection_log where instance_id = $OLD and collection in ('h6', 'h7')" 2>&1 || echo "no stage column")
check "$H6|$H7|$HS|$(q "select count(*) from pgvigil.collection_dates where instance_id = $OLD and collection in ('h6', 'h7')")|$(echo "$HR" | grep -c 'permission denied')" \
  "ok|ok|h6=null,h7=import|2|1" "H: the collector calls both forms, the stage kept; the reader refused"

echo "--- D. the acknowledgement"
PGVIGIL_PASSWORD=cerr-ui-pw-$SUF "$BIN" user add -config "$WORK/cfg.yaml" cerr_ui >/dev/null 2>&1 || fail "user add"
"$BIN" serve -config "$WORK/cfg.yaml" -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
U="http://127.0.0.1:$PORT"; JAR=$WORK/jar
for _ in $(seq 1 60); do curl -sf -o /dev/null "$U/" && break; sleep 0.5; done
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"cerr_ui\",\"password\":\"cerr-ui-pw-$SUF\"}" "$U/api/login" >/dev/null
post() { curl -s -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$U$1"; }
X=$(syn ack postgres)
lc "$X" c1 30 error "c1 failed"; lc "$X" c2 20 error "c2 failed"; lc "$X" c2 10 error "c2 failed again"
q "select pgvigil.log_collection($X, 'c1', now() - interval '5 minutes', 10, 'ok', NULL)" >/dev/null
summ() { curl -s "$U2/api/mssql/summary?part=collect" > "$WORK/r.json"; py "'|'.join(str(one(T('collect'), instance_id=$X).get(k)) for k in ('ch_level','ch_n'))"; }
dline() { curl -s "$U2/api/mssql/summary?part=collect" > "$WORK/r.json"; py "any('c2: the last run failed' in s for s in (one(T('collect'), instance_id=$X).get('detail') or []))"; }
check "$(summ)|$(dline)" "1|1|True" "D: before - Collection Health warning, one collection (c2: two failures in a row), its detail line"
L0=$(q "select count(*) from pgvigil.ack_log")
M=$(q "select max(log_id) from pgvigil.collection_log where instance_id = $X")
A1=$(post /api/ack "{\"kind\":\"ack\",\"instance_id\":$X,\"check_key\":\"collector errors\",\"seen_state\":\"log_id:$M\",\"until_change\":true}" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("ack_id"))' 2>/dev/null || echo none)
check "$(summ)|$(dline)" "0|0|False" "D: acknowledged up to log_id $M - Collection Health counts nothing, no detail line"
get "/api/collectorerrors?view=error&instance=$X&$W"
check "$(py "all(r['acked'] for r in T('rows'))")|$(py "len(T('rows'))")" "True|3" "D: the error view marks the acknowledged rows (all three)"
q "select pgvigil.log_collection($X, 'c3', now() - interval '40 minutes', 10, 'error', 'c3 started before the others, logged after the acknowledgement')" >/dev/null
check "$(summ)" "1|1" "D: a run that started earlier but was logged after the mark still counts (c3 warning)"
M2=$(q "select max(log_id) from pgvigil.collection_log where instance_id = $X")
A2=$(post /api/ack "{\"kind\":\"ack\",\"instance_id\":$X,\"check_key\":\"collector errors\",\"seen_state\":\"log_id:$M2\",\"until_change\":true}" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("ack_id"))' 2>/dev/null || echo none)
check "$(summ)" "0|0" "D: a second acknowledgement"
for a in $A1 $A2; do post /api/ack/end "{\"ack_id\":$a}" >/dev/null; done
check "$(summ)" "1|2" "D: Unacknowledge (every live row ended) brings c2 and c3 back"
AX=$(post /api/ack "{\"kind\":\"ack\",\"instance_id\":$X,\"check_key\":\"collector errors\",\"seen_state\":\"x\",\"until_change\":true}" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("outcome"))' 2>/dev/null || echo none)
check "$AX|$(summ)" "done|1|2" "D: a malformed mark (saved) leaves the part answering and counts nothing away"
check "$(( $(q "select count(*) from pgvigil.ack_log") - L0 ))" "5" "D: ack_log holds the three adds and the two ends"

echo "--- F. the fleet's SQL Server error stream"
M1=$(syn m1 sqlserver '{cerrf}'); MM2=$(syn m2 sqlserver '{cerrf}'); M3=$(syn m3 sqlserver)
for tb in mssql_errorlog mssql_ag_events; do
  for at in "now()" "now() - interval '1 hour'"; do   # a run in a month's first hour seeds rows in the month before
    q "select pgvigil.mssql_event_partition('$tb', $at)" >/dev/null 2>&1 || q "select pgvigil.ensure_month_partition('$tb', $at)" >/dev/null
  done
done
el() {   # instance, minutes ago (whole seconds), key, number, severity, class, message
  q "insert into pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, error_number, severity, error_state, class, message)
     values ($1, date_trunc('second', now()) - interval '$2 minutes', 'cerr-$3', now(), localtimestamp, $4, $5, 1, '$6', \$m\$$7\$m\$)" >/dev/null
}
el "$M1" 50 a 824 24 corruption "SQL Server detected a logical consistency-based I/O error: incorrect checksum. It occurred during a read of page (1:178064) in database ID 5 at offset 0x00000057020000 in file 'D:\\data\\inv.mdf'."
for k in 1 2 3; do el "$M1" $((40 + k)) "s$k" 17806 20 general "SSPI handshake failed with error code 0x8009030c, state 14 while establishing a connection with integrated security"; done
el "$M1" 30 c 35206 16 availability "A connection timeout has occurred on a previously established connection to availability replica 'R2'."
q "insert into pgvigil.mssql_ag_events (instance_id, event_at, event_key, snapshot_at, event_name, error_number, severity, family, message) values
     ($M1, date_trunc('second', now()) - interval '30 minutes', 'cerr-ag1', now(), 'error_reported', 35206, 16, 'connection', 'A connection timeout has occurred on a previously established connection to availability replica ''R2''.'),
     ($M1, date_trunc('second', now()) - interval '20 minutes', 'cerr-ag2', now(), 'error_reported', 35206, 16, 'connection', 'A connection timeout has occurred on a previously established connection to availability replica ''R3''.'),
     ($MM2, date_trunc('second', now()) - interval '25 minutes', 'cerr-ag3', now(), 'error_reported', 1480, 10, 'role', 'The availability group database \"agdb\" is changing roles from \"SECONDARY\" to \"PRIMARY\" because of a failover.')" >/dev/null
el "$MM2" 45 d 9002 17 general "The transaction log for database 'salesdb' is full due to 'LOG_BACKUP'."
el "$MM2" 35 e 823 24 io "The operating system returned error 21(The device is not ready.) to SQL Server during a read at offset 0x00000000012000."
q "insert into pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, class, custom, message)
     values ($MM2, now() - interval '33 minutes', 'cerr-f', now(), localtimestamp, 'general', true, 'cerr custom string seen')" >/dev/null
el "$MM2" 32 g 18456 14 general "Login failed for user 'app'. Reason: Password did not match."
el "$M3" 31 h 9002 17 general "The transaction log for database 'hr' is full due to 'ACTIVE_TRANSACTION'."
el "$M3" 29 i 3041 16 general "BACKUP failed to complete the command BACKUP DATABASE hr."
q "insert into pgvigil.mssql_files (instance_id, database_id, file_id, database_name, snapshot_at, first_seen) values ($M1, 5, 1, 'inv', now(), now())" >/dev/null
q "insert into pgvigil.mssql_xe_state (instance_id, capture, snapshot_at, state, state_since, source, session_name) values
     ($M3, 'ag', now(), 'stopped', now() - interval '1 day', 'AlwaysOn_health', 'AlwaysOn_health'),
     ($MM2, 'ag', now(), 'running', now() - interval '1 day', 'AlwaysOn_health', 'AlwaysOn_health')" >/dev/null
oc() { python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("outcome"))' 2>/dev/null || echo none; }
N1=$(post /api/ack "{\"kind\":\"noise\",\"check_key\":\"error log:17806\",\"note\":\"known SSPI noise\"}" | oc)
N2=$(post /api/ack "{\"kind\":\"noise\",\"check_key\":\"error log\",\"note\":\"a label with no text\"}" | oc)
N3=$(post /api/ack "{\"kind\":\"noise\",\"instance_id\":$MM2,\"note\":\"a noisy box (an Alerts-page label)\"}" | oc)
check "$N1|$N2|$N3" "done|done|done" "F: the three labels saved"
get "/api/mssql/errorfleet?$W"
check "$(py "sorted((r['error_number'], r['occurrences'], r['instances'], r['severity']) for r in T('byerror'))")" \
  "[(823, 1, 1, 24), (824, 1, 1, 24), (1480, 1, 1, 10), (9002, 2, 2, 17), (35206, 2, 1, 16)]" \
  "F: by number - the 35206 twin once, the listed 1480 under 17 in, 17806 hidden, a custom line / 18456 / 3041 out"
check "$(py "len(T('lines'))")|$(py "sorted(set(r['source'] for r in T('lines') if r['error_number'] == 35206))")" "7|['AlwaysOn_health', 'error log']" \
  "F: seven lines, 35206 once from each source"
check "$(py "'|'.join(str(one(T('lines'), error_number=n).get('database')) for n in (824, 1480, 823))")|$(py "sorted(r['database'] for r in T('lines') if r['error_number'] == 9002)")" \
  "database ID 5 (now inv)|agdb|None|['hr', 'salesdb']" "F: the database cell - an id with today's name, double quotes, none (NULL), single quotes"
check "$(py "'|'.join(str(one(T('lines'), error_number=1480).get(k)) for k in ('state', 'class'))")" "None|role" "F: an AlwaysOn_health row - no state, its family as its class"
check "$(py "'|'.join('%s=%s' % (r['check_key'], r['hits']) for r in sorted(T('noise'), key=lambda r: str(r['check_key'])))")" \
  "error log=0|error log:17806=3" "F: the page's labels - 17806's hides its three lines, the textless one nothing (the instance-only label is the Alerts page's: not listed, and the M2 lines stay in the counts above)"
get "/api/mssql/errorfleet?noise=1&$W"
check "$(py "len(T('lines'))")|$(py "sorted(set(r['noise'] for r in T('lines') if r['error_number'] == 17806))")|$(py "one(T('byerror'), error_number=17806).get('hidden')")" \
  "10|['known SSPI noise']|3" "F: noise=1 shows the three 17806 lines with their label"
get "/api/mssql/errorfleet?tag=cerrf&$W"
check "$(py "one(T('byerror'), error_number=9002).get('occurrences')")|$(py "sorted(set(r['instance'] for r in T('lines')))")" \
  "1|['cerr-m1-$SUF', 'cerr-m2-$SUF']" "F: a tag narrows to its instances"
check "$(py "[r['instance'] for r in T('agstate')]")|$(py "'agstate' in d")" "[]|True" "F: the tag's instances read AlwaysOn_health (none stopped; the part there)"
get "/api/mssql/errorfleet?$W"
check "$(py "[(r['instance'], r['state']) for r in T('agstate')]")" "[('cerr-m3-$SUF', 'stopped')]" "F: an instance whose AlwaysOn_health is stopped is named"

# the window's edges: an AlwaysOn_health event inside the window whose error-log twin lies just outside it is counted
# (the twin is not in the stream); an error number past a 32-bit integer is refused
ES=$(( $(date +%s) / 60 * 60 - 10800 )); EB=$(date -u -d "@$ES" +%Y-%m-%dT%H:%M:%SZ); EE=$(date -u -d "@$((ES + 600))" +%Y-%m-%dT%H:%M:%SZ)
for tb in mssql_errorlog mssql_ag_events; do
  q "select pgvigil.mssql_event_partition('$tb', '$EB'::timestamptz)" >/dev/null 2>&1 || q "select pgvigil.ensure_month_partition('$tb', '$EB'::timestamptz)" >/dev/null
done
q "insert into pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, error_number, severity, error_state, class, message) values
     ($M1, '$EB'::timestamptz - interval '1 second', 'cerr-edge1', now(), localtimestamp, 35206, 16, 1, 'availability', 'edge: the twin before the start'),
     ($M1, '$EE'::timestamptz + interval '1 second', 'cerr-edge2', now(), localtimestamp, 35206, 16, 1, 'availability', 'edge: the twin after the end')" >/dev/null
q "insert into pgvigil.mssql_ag_events (instance_id, event_at, event_key, snapshot_at, event_name, error_number, severity, family, message) values
     ($M1, '$EB'::timestamptz + interval '1 second', 'cerr-edge3', now(), 'error_reported', 35206, 16, 'connection', 'edge: the event after the start'),
     ($M1, '$EE'::timestamptz - interval '1 second', 'cerr-edge4', now(), 'error_reported', 35206, 16, 'connection', 'edge: the event before the end')" >/dev/null
get "/api/mssql/errorfleet?from=$EB&to=$EE&n=35206"
check "$(py "sorted((r['source'], r['message']) for r in T('lines'))")" \
  "[('AlwaysOn_health', 'edge: the event after the start'), ('AlwaysOn_health', 'edge: the event before the end')]" \
  "F: the window's edges - both AlwaysOn_health events counted, their error-log twins outside the window"
check "$(curl -s -o /dev/null -w '%{http_code}' "$U2/api/mssql/errorfleet?n=3000000000&$W")" "400" "F: an error number past a 32-bit integer refused (400)"

echo "--- G. the pages"
if command -v chromium >/dev/null; then
  page() { timeout 60 chromium --headless=new --no-sandbox --disable-gpu --user-data-dir="$WORK/chrome" --virtual-time-budget=15000 --dump-dom "$U2/#/$1" 2>/dev/null || true; }
  has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }
  G1=$(page "collectorerrors?w=7d"); G2=$(page "collectorerrors?i=$PGI&from=$FROM&to=$TO"); G3=$(page "collectorerrors?coll=activity&w=7d"); G7=$(page "collectorerrors?w=1h")
  check "$(has "$G1" "$PGT")|$(has "$G2" ">schema<")|$(has "$G1" "Acknowledge")|$(has "$G3" "Acknowledge")|$(has "$G7" "Acknowledge")|$(has "$G1" "never retries")" "yes|yes|yes|no|no|yes" \
    "G: the list, one instance per collection, Acknowledge only unfiltered over 24 h or more ending now (not at w=1h), the words on retries"
  G4=$(page "mssqlerrors?from=$FROM&to=$TO")
  check "$(has "$G4" "mssqlserver-824-database-engine-error")|$(has "$G4" "AlwaysOn_health not read")" "yes|yes" "G: the stream with its Learn link and the stopped AlwaysOn_health"
  G5=$(page "collectiondates?i=$PGI"); G6=$(page "findings")
  check "$(has "$G5" "#/collectorerrors")|$(has "$G6" "#/mssqlerrors")" "yes|yes" "G: Collection dates and the error-log finding link to the pages"
else check "no chromium" "chromium" "G: the pages (chromium is not on this machine)"; fi

echo
[ "$bad" = 0 ] && echo "proof-collector-errors: every row ok" || { echo "proof-collector-errors: $bad row(s) FAIL"; exit 1; }
