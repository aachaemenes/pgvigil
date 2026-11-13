#!/usr/bin/env bash
# Proof of the demo's write door (task B7): on `pgvigil demo -serve` the writes that touch only pgvigil's repository
# work on the demo's own instances as the built-in user 'demo', and nothing else is written.
#   PROOF_DOOR_ONLY=A  the API part alone (no browser)
#   PGVIGIL_ADMIN_DSN  a superuser connection to a sandbox server, without dbname. The proof makes its own repository
#                      database (its name holds the second, this shell's pid and a random number) and drops it at the
#                      end - only when this run made it; nothing that exists before the run is touched.
#   DOOR_SHOTS         the folder the shots go under (default .vis/door-shots): each run writes into a folder of its
#                      own there, named as its database, and deletes nothing
# Needs chromium, node, psql, curl, python3, go, ss, timeout.
# The ground the proof makes itself, by SQL as the user 'proof' with the client 'proof' (never through the door), so
# that a refusal is asked where a broken door would write: in the same repository a real instance (prod-db1), a real
# instance tagged 'demo' by hand (prod-db2) and an instance with the demo's tag AND its name prefix that this demo
# process did not seed (demo-proof-stale); for prod-db1 a live silence, a live mute rule, an open alert with a live
# dismissal, two crash restarts and the failed jobs of a demo instance; for demo-proof-stale a live silence stored by its NAME alone; for
# prod-db2 a live acknowledgement of its Memory Dump cell; one alert channel the configuration no longer names.
# Expected (written before the first run):
#  A. the API beside the page, on a demo serve with one real instance (prod-db1) and one real instance tagged 'demo' by
#     hand (prod-db2) added to the same repository:
#     - GET /api/ack: writable false, the reason names pgvigil demo -serve, door user 'demo', as many door instances as
#       the demo seeded
#     - a write without the X-Pgvigil header: 403 'the X-Pgvigil header is required'
#     - a silence on a demo instance: 200 done; the acknowledge log's row: demo / demo door / add / done; its end: 200
#     - prod-db1 and prod-db2: 403 '<name> is not one of this demo's instances: changing it needs pgvigil serve with a
#       signed-in user'; nothing written for them
#     - a root drive threshold: 403 'a root change would reach past the demo's instances'; a job exclusion (root, a
#       demo instance's, prod-db1's) and a job's threshold (a demo instance's, prod-db1's): 403 'this change is not made
#       through the demo' - their pages are not taught the door, so the route is not the door's [the fold of the
#       merge's review, A2]; a mute on every instance: 403 'an every-instance change would reach past ...'
#     [Added at the fold of the merge's review, C1 and C2:]
#     - the REAL instance is refused on every route the wiring moved, not on the silence add alone: prod-db1's drive
#       threshold and PostgreSQL threshold, the end of its silence (made by the proof), the pause of its mute rule
#       (the proof's), the dismissal of its open alert and the END of that alert's dismissal (the proof's own: the
#       door finds a dismissal's instance by a lookup of its own): each 403 'prod-db1 is not one of this demo's
#       instances'
#     - demo-proof-stale - the demo's tag and its prefix, not seeded by this process: the one case where 'seeded by
#       this process' is what refuses - a silence by its id: 403 'demo-proof-stale is not one of this demo's
#       instances'; the end of its silence stored by NAME: the same 403; the door still names as many instances as
#       the demo seeded
#     - the proof's own rows stand as it made them: '4 of 4 acknowledge rows live' (prod-db1's silence and mute rule,
#       demo-proof-stale's silence stored by name, prod-db2's Memory Dump acknowledgement: none ended, none paused),
#       '1 dismissal(s) of the alert, 1 live'; and no row but the proof's own names prod-db1, prod-db2 or
#       demo-proof-stale (by id or by name, the log too)
#     - after the counted change the proof ends its own two silences, its mute rule and its dismissal by SQL: 'done
#       done done done' (part B's pages then show a Silence that is off and prod-db1's alert open)
#     - every request is bounded (curl --connect-timeout 5 --max-time 60): a server that never answers fails its line
#     - an instance-level drive threshold on a demo instance: 200 done, its row created_by demo; inherit: 200
#     - an alert's key of one demo instance with another demo instance's id: 403 'the alert belongs to another instance'
#     - Send test: 403 '... pgvigil demo -serve runs no sender ...'; an alert rule: 403 '... judged by the alert sender,
#       which pgvigil demo -serve does not run ...'; cancel: 403 'actions are off on this server (no actions
#       configuration)'; Admin > Instances: 403 '... writes connection secrets and connects to servers ...'
#     - every row the door wrote names demo: no ack_log row with client 'demo door' and another user
#     - nothing else was written: over the tables the page's write functions touch (acks, ack_log, the three threshold
#       tables, job_exclusions, alert_dismissals, alert_rules, alert_tests, instances), counted before part A's first
#       request and after its last, the whole change is 'acks +1 ack_log +2 drive_thresholds +1', no threshold of demo
#       is live and no door row is without an instance [added at the review's fold]
#     [Added at the review's fold, red on the tree before it:]
#     - the seed's own silence (stored by its instance's NAME, without an id; read from the store by its client
#       'demo seed', the oldest when the seed made several) is listed by GET /api/ack under that instance's id, so the
#       page can offer its Unsilence
#     - GET /api/jobs/thresholds and GET /api/jobs/exclusions (pages whose controls stay off on a demo serve until
#       they are taught the door): writable false, 'this page's ... are off on pgvigil demo -serve', never 'saved as
#       user demo' beside a control that is off
#  B. the page, by clicks (scripts/demodoor-check.mjs): 'ok door', 'ok seat' (the footer says whose door this is),
#     [every click that writes is judged on the log rows IT wrote: every row newer than the newest one read before
#     the click - their COUNT exactly what the click names (one; a dialog's N; the page's N), each of the kind, the
#     operation and the instance the click names; a dialog's answer is 'done N of N saved' or 'done ended', word for
#     word. Each row waits for its own condition on the page (up to 15 s), never a fixed time and one read]
#     'ok R1' (the Summary's strip, where the page said 'Acknowledge is off' before the door - that sentence is gone;
#     Acknowledge, Save - the line leaves the strip, its cells read acknowledged, the list
#     says 'acknowledged by demo', the log's new row demo / demo door / ack / add / done / <its name>), 'ok R1b-a' and
#     'ok R1b-b' (a demo instance's OWN pages - one with a failed job run, another than R1's and than the one the seed
#     silenced where there is one (were it the seed's, the row would unsilence first, then silence): (a) the header's
#     Silence on its Summary page - 'done ... saved', the silenced mark and Unsilence drawn, the log demo / demo door /
#     silence / add / done / <its name> - then Unsilence - 'done ended', the mark gone, Silence back, the log's row end;
#     (b) the Acknowledge of its failed job on its Jobs page - 'done ... saved', the cell then reads 'acknowledged
#     <time>' with Clear on, the log demo / demo door / job / add / done / <its name>. [First box run, vis-b7a: the
#     row looked for an Acknowledge on the instance's own Summary page and that page draws none - the strip with it
#     is the fleet Summary's; the row was rewritten for the controls an instance's pages do offer.]), 'ok R3'
#     (Unacknowledge - one cell back, the log's row end by demo), 'ok R2' (Options > Memory Dumps > Acknowledge Dumps on the MIXED store - prod-db1's
#     Memory Dump cell is critical too: 'Memory dumps acknowledged on N instance(s) until a newer dump; 1 instance(s)
#     not the demo's left alone.', never 'not saved', the log's N new rows acknowledgements of demo instances; the
#     same menu item AGAIN finds none left - 'No demo instance has a Memory dumps cell with a warning or a critical to
#     acknowledge; 1 instance(s) not the demo's left alone.', 0 new log rows [B3]),
#     'ok R2b' (Options > Memory Dumps > Configure Thresholds, Clear: 'done N acknowledgement(s) ended: the dumps show
#     again; 1 acknowledgement(s) of instances not the demo's left alone.', the log's k new rows ends by demo, k not
#     under R2's N [B3]),
#     'ok R2c' (the dialog again, only prod-db2's acknowledgement in force: Clear is aria-disabled, never the disabled
#     attribute, with 'the acknowledgements in force are of instances that are not the demo's: ...' beside it, and the
#     date beside it reads 'Not acknowledged' [the fold's own review, part A finding 3]), 'ok R7' (prod-db1's
#     Silence, prod-db2's - a real instance tagged demo by hand - AND demo-proof-stale's [C2] are aria-disabled, never
#     the disabled attribute, each with its reason as visible text naming it as not one of this demo's instances; a
#     Silence that is on stands in the row of an instance the door names), 'ok R6' (Silence a demo instance from its
#     row, then the Unsilence of that same instance), 'ok R4' (a note on a ticked alert of a demo instance), 'ok R9a'
#     (EVERY Send test - the one of the channel the configuration no longer names among them [B6] - and Mute similar
#     are off: aria-disabled, never the disabled attribute, each with its reason in words), 'ok R15' (the Alerts
#     page's pickers [B2]: the Instance list of 'Silenced servers and blackouts' holds the door's instances alone, the
#     first one picked; New mute rule's dialog offers no 'any instance' and the door's instances alone, the first one
#     picked), 'ok R6b' (the demo's own seeded silence - stored by its instance's name - has its
#     Unsilence in the Alerts page's list of silenced servers: clicked, 'done ended', the log's row end by demo),
#     'ok R16' (prod-db1's own pages on the demo serve [B5]: its Jobs page with two failed jobs and its PostgreSQL
#     state page with two crash restarts say the reason ONCE - 'Acknowledge is off: prod-db1 is not one of this demo's
#     instances: ...' - every off Acknowledge points at that sentence, none carries it in its grid cell),
#     'ok R10' (a pgvigil serve -no-login started by the proof on the same repository, a server that writes nothing:
#     on the Summary, the Alerts page and a Jobs page with a failed job every off control has a description, no two
#     of a page's reason sentences say the same words, the sentence's words stand once in the page's text and in no
#     grid cell - the reason is said once per page; an instance's header is its own and read apart; its footer's seat
#     reads 'read only, actions off' - the plain footer, which proof-frame's demo serve never draws [C9]; its
#     Summary's dump dialog shows Clear aria-disabled with '... this server runs with -no-login' - an
#     acknowledgement stands and this server ends none [part A finding 3]) [both added
#     at the review's fold], and DONE-2's rows: 'ok R14' (a bulk action over a mixed scope: an alert of a demo
#     instance and the real instance's alert ticked, Acknowledge alerts: 'partly done 1 of 2 saved; 1 refused:
#     prod-db1 is not one of this demo's instances ...', ONE new log row, the demo alert's), 'ok R12' (every page of
#     the mixed store - the root and four instances, the real one among them - walked: no control that is off and
#     shown in a page's main or its dialogs lacks its reason as visible words, no sentence ends at its colon, no page
#     drew only an error; the top bar and the drill pages behind a row are not walked), 'ok R13' (the threshold
#     dialogs: a level wider than one instance is off in words before any request, one demo instance's own level is
#     on), 'demodoor-check: every row ok', then, read from the repository: 'ok B the seed's own
#     silence ... is ended in the store, by demo', 'ok B prod-db2's Memory Dump acknowledgement (the proof's own)
#     still stands', 'ok B nothing was written by the page for prod-db1, prod-db2 or demo-proof-stale', 'ok B outside
#     the acknowledge store the page's clicks changed nothing', 'ok B the Memory Dump acknowledgements the page made
#     through the door: N made, 0 still live', and 'ok B the
#     serve -no-login, written to once: 403 'acknowledgements need the UI login: this server runs with -no-login',
#     the counts equal before and after' [C1]. Shots are kept of R1, R1b, R7, R4, R15's dialog, R6b, R16's two
#     pages, R10's Summary and R12's seven pages whose off controls say why since DONE-2 (24, in a folder of this run's
#     own under DOOR_SHOTS; one that could not be taken is a FAIL line).
# NOT shown: a door whose instance list was read from the repository when it opened (a re-seed removes every instance
# with the demo's tag and prefix before the door opens, so none can stand there at the start; demo-proof-stale is made
# after it); Send test's own reason on a signed-in serve whose configuration lost a channel (no such serve is started).
# Last line: 'proof-demodoor: OK'. A scratch database that could not be dropped is a FAIL line after it and exit 1.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_door_$(date +%s)_$$_$RANDOM"; MADE=""; PORT=""; PORT2=""; CDP=""; SRV=""; SRV2=""; CHR=""; FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
die() { echo "FAIL $*" >&2; exit 1; }
cleanup() {
  # nothing in here may fail the run by accident (a failing command in an EXIT trap turns exit 0 into 1) and nothing
  # may wait without an end: the three processes are asked to end, each given 10 s, then killed outright (a Chromium that does
  # not answer must not hold the database and the box job's lease) and waited for before their files go (Chromium
  # writes its profile while it shuts down). The database is dropped only when THIS run made it (a create that
  # failed on a name already there must never drop the other run's database), and one that could not be dropped is
  # SAID, never swallowed
  set +e
  local p n out
  for p in "$SRV" "$SRV2" "$CHR"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  for p in "$SRV" "$SRV2" "$CHR"; do
    [[ -n "$p" ]] || continue
    for n in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
  done
  local left=""
  if [[ -n "$MADE" ]]; then
    out=$(timeout 60 psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" 2>&1) || { echo "FAIL the scratch database $DB was not dropped: $out"; left=1; }
  fi
  rm -rf "$WORK" || true
  # the one thing here that fails the run: a database left behind (a runner that grades by the exit code must see it)
  if [[ -n "$left" ]]; then exit 1; fi
}
trap cleanup EXIT
for t in chromium node psql curl python3 go ss timeout; do command -v $t >/dev/null || die "$t is not on this machine"; done
node -e 'process.exit(typeof WebSocket === "function" && typeof fetch === "function" ? 0 : 1)' || die "node $(node --version) has no global WebSocket: the click script needs node 22 or later"
# two ports for the two servers (Chromium picks its own, below). A port is picked minutes before it is bound - the
# build and the seed come first - and another proof on the same box may take it meanwhile: a server is believed only
# when the process THIS run started is the one listening on its port (owns)
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || die "no two free ports"; PORT2=$((PORT + 1))
owns() { ss -ltnpH "sport = :$2" 2>/dev/null | grep -q "pid=$1,"; }   # owns <pid> <port>
CURL=(curl --connect-timeout 5 --max-time 60)

echo "== build, seed the demo into $DB and serve it on 127.0.0.1:$PORT"
BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil; BIN="$WORK/pgvigil"; fi
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
MADE=1
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$BIN" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; die "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; die "the demo did not come up"; }
owns "$SRV" "$PORT" || die "port $PORT is not held by this run's demo serve (pid $SRV): $(ss -ltnpH "sport = :$PORT" 2>&1 | head -2)"
U="http://127.0.0.1:$PORT"
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
N=$(q "select count(*) from pgvigil.instances where 'demo' = any (tags)")
D1=$(q "select instance_id from pgvigil.instances where 'demo' = any (tags) order by instance_id limit 1")
[[ -n "$D1" ]] || die "the rig: the demo seeded no instance tagged demo"
D1N=$(q "select name from pgvigil.instances where instance_id = $D1")
D2=$(q "select s.instance_id from pgvigil.alert_state s join pgvigil.instances i using (instance_id) where 'demo' = any (i.tags) and s.instance_id <> $D1 order by s.last_sent_at desc limit 1")
KEY=$(q "select finding_key from pgvigil.alert_state where instance_id = $D2 order by last_sent_at desc limit 1")
REAL=$(q "select pgvigil.ensure_instance('prod-db1', 'onprem', 'real', 160004, false, '{prod}')")
TAGGED=$(q "select pgvigil.ensure_instance('prod-db2', 'onprem', 'real', 160004, false, '{demo}')")
# the demo's tag AND its name prefix, made after this demo process seeded: not one of the instances the door was given
STALE=$(q "select pgvigil.ensure_instance('demo-proof-stale', 'onprem', 'real', 160004, false, '{demo}')")
[[ -n "$D1" && -n "$D2" && -n "$KEY" && -n "$REAL" && -n "$TAGGED" && -n "$STALE" ]] || die "the rig: demo instances $D1 / $D2, key '$KEY', prod-db1 $REAL, prod-db2 $TAGGED, demo-proof-stale $STALE"
# R1b's ground: the demo instances with a failed job run (pg_cron / pgAgent, or SQL Server Agent's job outcome row),
# PostgreSQL's first, as [{id, name, tab}] - tab is that engine's Jobs page
JOBS=$(q "select coalesce(json_agg(json_build_object('id', x.instance_id, 'name', x.name, 'tab', x.tab) order by x.ord, x.instance_id), '[]')
  from (select i.instance_id, i.name, case when i.engine = 'postgres' then 'jobs' else 'mssqljobs' end as tab, case when i.engine = 'postgres' then 0 else 1 end as ord
          from pgvigil.instances i
         where 'demo' = any (i.tags)
           and (exists (select 1 from pgvigil.job_runs r where r.instance_id = i.instance_id and r.status in ('failed', 'internal error'))
             or exists (select 1 from pgvigil.mssql_job_runs r where r.instance_id = i.instance_id and r.step_id = 0 and r.run_status = 0))) x")
echo "the demo instances with a failed job run: $JOBS"
# ---- the proof's own ground, by SQL as the user 'proof' with the client 'proof' (never through the door): the rows a
# broken door would end, pause, dismiss or acknowledge for an instance that is not the demo's
padd() { q "select pgvigil.import_ack(now(), '$1'::jsonb)->>'ack_id'"; }   # one row of the store; prints its id
PW='"ui_user":"proof","client":"proof"'
PS=$(padd "{\"op\":\"add\",\"kind\":\"silence\",\"instance_id\":$REAL,\"instance_name\":\"prod-db1\",\"note\":\"door proof ground\",$PW}")
PN=$(padd "{\"op\":\"add\",\"kind\":\"silence\",\"instance_name\":\"demo-proof-stale\",\"note\":\"door proof ground\",$PW}")   # by its NAME alone, as the seed stores its own
PM=$(padd "{\"op\":\"add\",\"kind\":\"mute\",\"instance_id\":$REAL,\"instance_name\":\"prod-db1\",\"match_text\":\"door proof\",$PW}")
PD=$(padd "{\"op\":\"add\",\"kind\":\"ack\",\"instance_id\":$TAGGED,\"instance_name\":\"prod-db2\",\"check_key\":\"dumps\",\"seen_state\":\"door proof\",$PW}")
[[ -n "$PS" && -n "$PN" && -n "$PM" && -n "$PD" ]] || die "the rig: the proof's own rows were not made: silence '$PS', silence by name '$PN', mute '$PM', dumps acknowledgement '$PD'"
# one open alert of prod-db1 (its key in an alert key's shape, 32 hexadecimal digits) and its dismissal (the proof's own,
# through the function the route calls): the door finds a dismissal's instance by a lookup of its own, asked below
RKEY=$(q "select md5('door-proof-real-1')")
q "insert into pgvigil.alert_state (channel, finding_key, instance_id, instance_name, severity, source, setting, value, first_sent_at, last_sent_at)
   values ('demo-spool', '$RKEY', $REAL, 'prod-db1', 'critical', 'pgvigil', 'door proof', 'a real instance''s alert', now(), now())" >/dev/null
PX=$(q "select pgvigil.import_alert_dismiss(now(), '{\"op\":\"add\",\"finding_key\":\"$RKEY\",\"reason\":\"door proof ground\",$PW}'::jsonb)->>'dismiss_id'")
[[ -n "$PX" ]] || die "the rig: the proof's own dismissal of prod-db1's alert was not made"
# two crash restarts in prod-db1's log (its Memory Dump cell on the Summary turns critical; its state page lists both)
q "insert into pgvigil.log_events (instance_id, snapshot_at, kind, pid, detail, source, event_key)
   select $REAL, now() - x.ago, 'crash', 4242, 'server process (PID 4242) was terminated by signal 11: Segmentation fault', 'door proof', 'door-proof-' || x.n
     from (values (interval '30 minutes', 1), (interval '2 hours', 2)) x(ago, n)" >/dev/null
# the jobs of a demo PostgreSQL instance with two failed jobs, copied onto prod-db1 (its Jobs page: two Acknowledge cells)
JSRC=$(q "select i.instance_id from pgvigil.instances i where 'demo' = any (i.tags) and i.engine = 'postgres'
            and (select count(distinct r.job_id) from pgvigil.job_runs r where r.instance_id = i.instance_id and r.status in ('failed', 'internal error')) >= 2
          order by i.instance_id limit 1")
[[ -n "$JSRC" ]] || die "the rig: no demo PostgreSQL instance with two failed jobs to copy onto prod-db1"
q "insert into pgvigil.jobs select (jsonb_populate_record(null::pgvigil.jobs, to_jsonb(j) || jsonb_build_object('instance_id', $REAL))).* from pgvigil.jobs j where j.instance_id = $JSRC;
   insert into pgvigil.job_runs select (jsonb_populate_record(null::pgvigil.job_runs, to_jsonb(r) || jsonb_build_object('instance_id', $REAL))).* from pgvigil.job_runs r where r.instance_id = $JSRC" >/dev/null
# one alert channel the configuration no longer names (its Send test)
q "insert into pgvigil.alert_channels (name, kind, destination, min_severity, repeat_secs, recovery, is_configured, configured_at, updated_at)
   values ('proof-gone', 'file', '/nonexistent/door-proof', 'warning', 0, false, false, now(), now())" >/dev/null
# what part A may change, counted before its first request and after its last: only the tables the page's write
# functions touch (the live fleet goes on writing its own snapshots beside them)
counts() { q "select concat_ws(' ', 'acks', (select count(*) from pgvigil.acks), 'ack_log', (select count(*) from pgvigil.ack_log),
  'drive_thresholds', (select count(*) from pgvigil.drive_thresholds), 'pg_thresholds', (select count(*) from pgvigil.pg_thresholds),
  'job_thresholds', (select count(*) from pgvigil.job_thresholds), 'job_exclusions', (select count(*) from pgvigil.job_exclusions),
  'alert_dismissals', (select count(*) from pgvigil.alert_dismissals), 'alert_rules', (select count(*) from pgvigil.alert_rules),
  'alert_tests', (select count(*) from pgvigil.alert_tests), 'instances', (select count(*) from pgvigil.instances))"; }
C0=$(counts)

echo "== A. the API"
H=(-H 'X-Pgvigil: 1' -H 'Content-Type: application/json')
# every request of the proof is bounded (CURL): a server that accepts and never answers - the door's pool at its
# connection limit - must fail a line (code 000), never hold the run, its database and the box job's lease
post() { local path=$1 body=$2; shift 2; CODE=$("${CURL[@]}" -s -o "$WORK/ans" -w '%{http_code}' -X POST "$@" -d "$body" "$U/api/$path") || true; ANS=$(head -c 600 "$WORK/ans" 2>/dev/null || true); }
want() { # want <label> <code> <words the answer must hold>
  if [[ "$CODE" == "$2" && "$ANS" == *"$3"* ]]; then ok "A $1: $CODE $(echo "$ANS" | head -c 170)"; else fail "A $1: $CODE $ANS (want $2 with '$3')"; fi; }
G=$("${CURL[@]}" -s "$U/api/ack?part=acks" | python3 -c 'import json,sys; d=json.load(sys.stdin); x=d.get("door") or {}; print(d.get("writable"), "|", x.get("user"), "|", len(x.get("instances") or []), "|", d.get("reason"))')
if [[ "$G" == "False | demo | $N | "*"pgvigil demo -serve"* && "$G" != *"-no-login"* ]]; then ok "A the door as the page is told: writable False, user demo, $N instances; '${G##*| }'"; else fail "A GET /api/ack: $G (want False | demo | $N | ... pgvigil demo -serve ...)"; fi
# the seed's silence, read from the store by its client (the oldest, had the seed made several; the proof's own
# silences stand beside it): GET /api/ack lists it live, under its instance's own id
SEED=$(q "select instance_name from pgvigil.acks where kind = 'silence' and client = 'demo seed' and ended_at is null order by ack_id limit 1")
SEEDID=$(q "select coalesce((select instance_id::text from pgvigil.instances where name = '$SEED'), 'no such instance')")
SS=$("${CURL[@]}" -s "$U/api/ack?part=acks" | python3 -c 'import json,sys
t=json.load(sys.stdin)["acks"]; r=[dict(zip(t["columns"],x)) for x in t["rows"]]
s=[x for x in r if x["kind"]=="silence" and x["live"] and x["client"]=="demo seed" and x["instance"]==sys.argv[1]]
print(len(s), "|", ",".join(str(x["instance_id"]) for x in s))' "$SEED")
if [[ -n "$SEED" && "$SS" == "1 | $SEEDID" ]]; then ok "A the seed's silence ($SEED, read by its client 'demo seed') is listed under its instance's id: $SS"; else fail "A the seed's silence: instance '$SEED', listed '$SS' (want 1 | $SEEDID)"; fi
for pair in "thresholds:jobs/thresholds?instance=$D1" "job exclusions:jobs/exclusions?instance=$D1"; do
  G=$("${CURL[@]}" -s "$U/api/${pair#*:}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("writable"), "|", d.get("reason"))')
  if [[ "$G" == "False | this page's ${pair%%:*} are off on pgvigil demo -serve"* && "$G" != *"saved as user demo"* ]]; then ok "A GET /api/${pair#*:}: $G"; else fail "A GET /api/${pair#*:}: $G (want False | this page's ${pair%%:*} are off on pgvigil demo -serve ...)"; fi
done
post ack "{\"kind\":\"silence\",\"instance_id\":$D1,\"note\":\"x\"}" -H 'Content-Type: application/json'; want "no header" 403 "the X-Pgvigil header is required"
post ack "{\"kind\":\"silence\",\"instance_id\":$D1,\"note\":\"door proof\"}" "${H[@]}"; want "a silence on a demo instance" 200 '"outcome":"done"'
AID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ack_id") or 0)' "$WORK/ans")
L=$(q "select concat_ws(' / ', ui_user, client, kind, op, outcome, instance_name) from pgvigil.ack_log order by log_id desc limit 1")
if [[ "$L" == "demo / demo door / silence / add / done / $D1N" ]]; then ok "A its log row: $L"; else fail "A its log row: $L (want demo / demo door / silence / add / done / $D1N)"; fi
post ack/end "{\"ack_id\":$AID}" "${H[@]}"; want "its end" 200 '"outcome":"done"'
for pair in "$REAL:prod-db1" "$TAGGED:prod-db2" "$STALE:demo-proof-stale"; do
  post ack "{\"kind\":\"silence\",\"instance_id\":${pair%%:*},\"note\":\"x\"}" "${H[@]}"; want "${pair##*:} (not the demo's)" 403 "${pair##*:} is not one of this demo's instances: changing it needs pgvigil serve with a signed-in user"
done
# the real instance on EVERY route the wiring moved onto the door's seat, each asked where a broken door would write
NOT1="prod-db1 is not one of this demo's instances"
post drives/thresholds "{\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$REAL,\"warn\":20,\"crit\":10}" "${H[@]}"; want "prod-db1's drive threshold" 403 "$NOT1"
post pg/thresholds "{\"op\":\"set\",\"key\":\"uptime\",\"level\":\"instance\",\"instance_id\":$REAL,\"warn\":1,\"crit\":0.5}" "${H[@]}"; want "prod-db1's PostgreSQL threshold" 403 "$NOT1"
post ack/end "{\"ack_id\":$PS}" "${H[@]}"; want "the end of prod-db1's silence (the proof's row)" 403 "$NOT1"
post alerts/mute "{\"op\":\"pause\",\"ack_id\":$PM}" "${H[@]}"; want "the pause of prod-db1's mute rule (the proof's row)" 403 "$NOT1"
post alerts/dismiss "{\"op\":\"add\",\"finding_key\":\"$RKEY\",\"reason\":\"x\"}" "${H[@]}"; want "the dismissal of prod-db1's open alert (the proof's row)" 403 "$NOT1"
post alerts/dismiss "{\"op\":\"end\",\"dismiss_id\":$PX}" "${H[@]}"; want "the end of that alert's dismissal (the proof's row)" 403 "$NOT1"
post ack/end "{\"ack_id\":$PN}" "${H[@]}"; want "the end of demo-proof-stale's silence, stored by its name (the proof's row)" 403 "demo-proof-stale is not one of this demo's instances"
# the proof's own five rows as it made them: prod-db1's silence and mute rule, demo-proof-stale's silence stored by
# name, prod-db2's Memory Dump acknowledgement - none ended, none paused - and the one dismissal of prod-db1's alert, live
OWN=$(q "select (select count(*) from pgvigil.acks where ack_id in ($PS, $PN, $PM, $PD) and ended_at is null and paused_at is null) || ' of 4 acknowledge rows live, '
  || (select count(*) from pgvigil.alert_dismissals where finding_key = '$RKEY') || ' dismissal(s) of the alert, ' || (select count(*) from pgvigil.alert_dismissals where dismiss_id = $PX and ended_at is null) || ' live'")
if [[ "$OWN" == "4 of 4 acknowledge rows live, 1 dismissal(s) of the alert, 1 live" ]]; then ok "A the proof's own rows stand as it made them: $OWN"; else fail "A the proof's own rows: $OWN (want 4 of 4 acknowledge rows live, 1 dismissal(s) of the alert, 1 live)"; fi
NAMES="'prod-db1', 'prod-db2', 'demo-proof-stale'"
if [[ $(q "select (select count(*) from pgvigil.acks where client is distinct from 'proof' and (instance_id in ($REAL, $TAGGED, $STALE) or instance_name in ($NAMES))) + (select count(*) from pgvigil.ack_log where client is distinct from 'proof' and instance_name in ($NAMES))") == 0 ]]; then ok "A nothing written for prod-db1, prod-db2 or demo-proof-stale (by id or by name, the log too; the proof's own rows apart)"; else fail "A a row was written for an instance that is not the demo's"; fi
post drives/thresholds '{"op":"set","level":"root","warn":20,"crit":10}' "${H[@]}"; want "a root drive threshold" 403 "a root change would reach past the demo's instances"
# a job's thresholds and the job exclusions: their pages are not taught the door, so the route is not the door's -
# for a demo instance as for a real one, at every level
NOJ="this change is not made through the demo"
post jobs/exclusions '{"op":"add","level":"root","pattern":"x"}' "${H[@]}"; want "a root job exclusion" 403 "$NOJ"
for pair in "a demo instance:$D1" "prod-db1:$REAL"; do
  post jobs/thresholds "{\"op\":\"set\",\"level\":\"instance\",\"instance_id\":${pair##*:},\"fail_24h_warn\":3}" "${H[@]}"; want "a job's threshold on ${pair%%:*}" 403 "$NOJ"
  post jobs/exclusions "{\"op\":\"add\",\"level\":\"instance\",\"instance_id\":${pair##*:},\"pattern\":\"x\"}" "${H[@]}"; want "a job exclusion on ${pair%%:*}" 403 "$NOJ"
done
post ack '{"kind":"mute","match_text":"jit","note":"x"}' "${H[@]}"; want "a mute on every instance" 403 "an every-instance change would reach past the demo's instances"
post drives/thresholds "{\"op\":\"set\",\"level\":\"instance\",\"instance_id\":$D1,\"warn\":20,\"crit\":10}" "${H[@]}"; want "an instance's drive threshold" 200 '"outcome":"done"'
[[ $(q "select created_by from pgvigil.drive_thresholds where instance_id = $D1 order by threshold_id desc limit 1") == demo ]] && ok "A its row is demo's" || fail "A the threshold's created_by"
post drives/thresholds "{\"op\":\"inherit\",\"level\":\"instance\",\"instance_id\":$D1}" "${H[@]}"; want "inherit" 200 '"outcome":"done"'
post ack "{\"kind\":\"alert_ack\",\"finding_key\":\"$KEY\",\"instance_id\":$D1}" "${H[@]}"; want "an alert's key with another instance's id" 403 "the alert belongs to another instance"
post alerts/test '{"channel":"ops"}' "${H[@]}"; want "Send test" 403 "pgvigil demo -serve runs no sender"
post alertrules '{"name":"x"}' "${H[@]}"; want "an alert rule" 403 "judged by the alert sender, which pgvigil demo -serve does not run"
post actions/cancel "{\"instance_id\":$D1,\"pid\":1,\"reason\":\"x\"}" "${H[@]}"; want "cancel" 403 "actions are off on this server (no actions configuration)"
post admin/instances '{"op":"add","name":"x"}' "${H[@]}"; want "Admin > Instances" 403 "writes connection secrets and connects to servers"
if [[ $(q "select count(*) from pgvigil.ack_log where client = 'demo door' and ui_user is distinct from 'demo'") == 0 ]]; then ok "A every row through the door names demo"; else fail "A a door row names another user"; fi
# nothing else was written: over the tables the page's write functions touch, part A's whole change is one silence
# (made and ended: one acks row, two log rows) and one drive threshold (set, then ended by inherit: one row, none live)
C1=$(counts)
DELTA=$(python3 -c 'import sys
a, b = sys.argv[1].split(), sys.argv[2].split()
d = {a[i]: int(b[i + 1]) - int(a[i + 1]) for i in range(0, len(a), 2)}
print(" ".join(f"{k} {v:+d}" for k, v in d.items() if v) or "nothing")' "$C0" "$C1")
LIVE=$(q "select (select count(*) from pgvigil.drive_thresholds where ended_at is null and created_by = 'demo') || ' live threshold(s) of demo, ' || (select count(*) from pgvigil.acks where client = 'demo door' and instance_id is null) || ' door row(s) without an instance'")
if [[ "$DELTA" == "acks +1 ack_log +2 drive_thresholds +1" && "$LIVE" == "0 live threshold(s) of demo, 0 door row(s) without an instance" ]]; then ok "A nothing else was written: $DELTA; $LIVE"; else fail "A what part A changed: $DELTA; $LIVE (want acks +1 ack_log +2 drive_thresholds +1; 0 live threshold(s) of demo, 0 door row(s) without an instance)"; fi
# the proof ends its own silences, its mute rule and its dismissal itself (by SQL, as 'proof'): the pages of part B
# then show prod-db1 and demo-proof-stale with a Silence that is off and prod-db1's alert open, as a visitor meets
# them; prod-db2's Memory Dump acknowledgement stays for R2b. An end that is not 'done' is a FAIL line (part B would
# meet another page than the one its rows name)
ENDS=""
for a in $PS $PN $PM; do ENDS+="$(q "select pgvigil.import_ack(now(), '{\"op\":\"end\",\"ack_id\":$a,$PW}'::jsonb)->>'outcome'") "; done
ENDS+="$(q "select pgvigil.import_alert_dismiss(now(), '{\"op\":\"end\",\"dismiss_id\":$PX,$PW}'::jsonb)->>'outcome'")"
if [[ "$ENDS" == "done done done done" ]]; then ok "A the proof ended its own two silences, its mute rule and its dismissal: $ENDS"; else fail "A the proof's own ends: '$ENDS' (want done done done done)"; fi

if [[ "${PROOF_DOOR_ONLY:-}" == A ]]; then
  if (( FAILS )); then echo "FAIL: $FAILS"; exit 1; fi
  echo "proof-demodoor: part A OK (part B, the page by clicks, not run: PROOF_DOOR_ONLY=A)"; exit 0
fi
echo "== B. the page, by clicks"
# Chromium picks its own debugging port (0) and writes it into its profile folder: no port chosen ahead that another
# proof's Chromium could hold by now, so this run can only ever drive its own browser
chromium --headless=new --remote-debugging-port=0 --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 150); do [[ -s "$WORK/chrome/DevToolsActivePort" ]] && break; kill -0 $CHR 2>/dev/null || break; sleep 0.2; done
CDP=$(head -1 "$WORK/chrome/DevToolsActivePort" 2>/dev/null || true)
[[ "$CDP" =~ ^[0-9]+$ ]] || { tail -3 "$WORK/chrome.log"; die "chromium wrote no debugging port into its profile (DevToolsActivePort)"; }
for _ in $(seq 1 50); do curl --max-time 5 -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.2; done
curl --max-time 5 -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || die "chromium's CDP port $CDP never answered"
# the shots: a folder of this run's own (named as its database), nothing deleted - an earlier run's picture can
# neither stand in for a missing one nor be lost to this run
SHOTS=${DOOR_SHOTS:-$PWD/.vis/door-shots}/$DB
mkdir -p "$SHOTS"
# R10's ground: a pgvigil serve -no-login on the same repository (a server that writes nothing at all), read only
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$WORK/none.yaml"
PGVIGIL_REPO_DSN="$DSN" "$BIN" serve -no-login -config "$WORK/none.yaml" -listen "127.0.0.1:$PORT2" > "$WORK/serve.log" 2>&1 &
SRV2=$!
U2="http://127.0.0.1:$PORT2"
for _ in $(seq 1 60); do kill -0 $SRV2 2>/dev/null || break; curl --max-time 5 -sf -o /dev/null "$U2/" && break; sleep 0.5; done
# believed only when this run's own process answers on the port (another job's server on it would be read as ours)
if ! kill -0 $SRV2 2>/dev/null || ! owns "$SRV2" "$PORT2" || ! curl --max-time 5 -sf -o /dev/null "$U2/"; then fail "R10 the serve -no-login is not up on its own port $PORT2 (pid $SRV2): $(tail -2 "$WORK/serve.log" | tr '\n' ' ')"; U2=""; fi
# the rig as the click script reads it: the instances with a failed job, the instance of the seed's own silence, the
# real instance tagged demo by hand, the instance with the demo's tag and prefix this process did not seed, prod-db1's
# id (its own pages), the channel the configuration no longer names, the serve -no-login
RIG=$(python3 -c 'import json,sys; print(json.dumps({"jobs": json.loads(sys.argv[1]), "seed": sys.argv[2], "tagged": sys.argv[3], "nologin": sys.argv[4], "stale": sys.argv[5], "real_id": int(sys.argv[6]), "gone": sys.argv[7]}))' "$JOBS" "$SEED" prod-db2 "${U2:+$U2/}" demo-proof-stale "$REAL" proof-gone)
CN0=$(counts)   # the store before the page is clicked: what the clicks may change is the acknowledge store alone
timeout 900 node scripts/demodoor-check.mjs "$CDP" "$U" prod-db1 "$SHOTS" "$RIG" || { echo "FAIL the click script ended with exit $? (124 = cut at 900 s)"; FAILS=$((FAILS + 1)); }
CN1=$(counts)
echo "shots: $(ls "$SHOTS" 2>/dev/null | wc -l) in $SHOTS"
# R6b's other half, read from the store: the seed's own silence (client 'demo seed') was ended, by demo
SE=$(q "select coalesce(string_agg(coalesce(ended_by, 'not ended'), ','), 'no such row') from pgvigil.acks where kind = 'silence' and client = 'demo seed' and instance_name = '$SEED'")
if [[ "$SE" == demo ]]; then ok "B the seed's own silence ($SEED) is ended in the store, by demo"; else fail "B the seed's own silence: $SE (want ended by demo)"; fi
# R2b's other half: Clear ended the demo's acknowledgements and left the one of prod-db2 (the proof's own row) alone
PDL=$(q "select coalesce((select case when ended_at is null then 'live' else 'ended by ' || ended_by end from pgvigil.acks where ack_id = $PD), 'no such row')")
if [[ "$PDL" == live ]]; then ok "B prod-db2's Memory Dump acknowledgement (the proof's own) still stands: $PDL"; else fail "B prod-db2's Memory Dump acknowledgement: $PDL (want live)"; fi
# every page row's other half: the page wrote nothing for an instance that is not the demo's
PGW=$(q "select (select count(*) from pgvigil.acks where client is distinct from 'proof' and (instance_id in ($REAL, $TAGGED, $STALE) or instance_name in ($NAMES) or finding_key = '$RKEY')) + (select count(*) from pgvigil.ack_log where client is distinct from 'proof' and instance_name in ($NAMES))")
if [[ "$PGW" == 0 ]]; then ok "B nothing was written by the page for prod-db1, prod-db2 or demo-proof-stale (by id or by name, prod-db1's alert, the log too)"; else fail "B $PGW row(s) written by the page for an instance that is not the demo's"; fi
# and outside the acknowledge store the clicks wrote nothing at all: the threshold tables, the job exclusions, the
# dismissals, the alert rules and tests and the instances count the same before and after the page
OTHER=$(python3 -c 'import sys
a, b = sys.argv[1].split(), sys.argv[2].split()
d = {a[i]: int(b[i + 1]) - int(a[i + 1]) for i in range(0, len(a), 2) if a[i] not in ("acks", "ack_log")}
print(" ".join(f"{k} {v:+d}" for k, v in d.items() if v) or "nothing")' "$CN0" "$CN1")
if [[ "$OTHER" == nothing ]]; then ok "B outside the acknowledge store the page's clicks changed $OTHER (thresholds, job exclusions, dismissals, alert rules and tests, instances)"; else fail "B outside the acknowledge store the page's clicks changed: $OTHER (want nothing)"; fi
# R2 and R2b's other half: every Memory Dump acknowledgement the page made through the door was ended by Clear
DL=$(q "select count(*) || ' made, ' || count(*) filter (where ended_at is null) || ' still live' from pgvigil.acks where kind = 'ack' and check_key = 'dumps' and client = 'demo door'")
if [[ "$DL" =~ ^[1-9][0-9]*\ made,\ 0\ still\ live$ ]]; then ok "B the Memory Dump acknowledgements the page made through the door: $DL (Clear ended each)"; else fail "B the Memory Dump acknowledgements the page made through the door: $DL (want 1 or more made, 0 still live)"; fi
# the serve -no-login is WRITTEN to once (R10 only read it): refused in the plain serve's own words, and the store's
# counts equal before and after - a seat that gave a serve without the login the door's user would write here
if [[ -n "$U2" ]]; then
  CB=$(counts)
  CODE=$("${CURL[@]}" -s -o "$WORK/ans" -w '%{http_code}' -X POST "${H[@]}" -d "{\"kind\":\"silence\",\"instance_id\":$D1,\"note\":\"x\"}" "$U2/api/ack") || true; ANS=$(head -c 600 "$WORK/ans" 2>/dev/null || true)
  CA=$(counts)
  if [[ "$CODE" == 403 && "$ANS" == *"acknowledgements need the UI login: this server runs with -no-login"* && "$CB" == "$CA" ]]; then ok "B the serve -no-login, written to once: $CODE $(echo "$ANS" | head -c 120), the counts equal before and after"; else fail "B the serve -no-login, written to once: $CODE $ANS; counts before '$CB', after '$CA' (want 403 'acknowledgements need the UI login: this server runs with -no-login', the counts equal)"; fi
fi

if (( FAILS )); then echo "FAIL: $FAILS"; exit 1; fi
echo "proof-demodoor: OK"
