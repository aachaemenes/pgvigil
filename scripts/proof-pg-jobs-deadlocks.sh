#!/usr/bin/env bash
# Proof of the PostgreSQL twins of DBA Dash's job and deadlock pages (task 161: migration 0102, internal/collect/jobs_actions.go,
# internal/web/q_jobs_actions.go, internal/web/q_pg_deadlocks.go, web/src/jobs_running.ts, web/src/pg_deadlocks.ts).
#
# Needs: docker, psql, curl, python3, go, node, npm and chromium, at the repository root. Per PostgreSQL major in
# PGVIGIL_PROOF_PGS (default "13 16 18") it builds (once, kept for the next run) the image pgvigil-proof-pgcron:<major>
# (postgres:<major> with PGDG's postgresql-<major>-cron and pgagent), starts a container of it (pg_cron preloaded, the
# log collector on, a throwaway superuser password made here and never printed), and uses that one server as both the
# repository (database pgvigil_repo) and the monitored server (database postgres). What it makes and removes on every
# exit path: the container (with its volume), the scratch folder; nothing else is touched. The images stay (docker rmi
# pgvigil-proof-pgcron:<major> removes them).
# The routes, the tabs and the config's job actions are the lead's files (web.go, serve.go, config.go, router.ts, main.ts,
# jobs_pg.ts; logparse.go keeps a deadlock's CONTEXT line): where the tree lacks them, the scratch build applies
# PGVIGIL_PGJD_WIRING (the slice's wiring patch) and the proof says so.
#
# Expected (written before the first run), on each major:
#  A. migrate applies 0102: job_step_runs and job_exclusions exist, actions_log's CHECK names job_stop in its postgres branch.
#     [review fold] the config refuses on a PostgreSQL instance actions: [kill] ('unknown action'), [job_stop, job_stop]
#     ('twice') and [job_stop] without actions_dsn ('no actions_dsn').
#  B. pg_cron Stop: a job 'pgv161_sleeper' (select pg_sleep(600), every minute, as the plain login jobber) starts; after
#     the jobs read, GET /api/jobs/running lists its run with that run's job_pid; POST /api/jobs/actions/stop is 403 without
#     the X-Pgvigil header (not audited), 409 with a confirmation that is not the job's name, 409 with a job_pid that is not
#     the run's ('job_pid is'), 409 on the second instance whose actions: list does not name job_stop ('does not name
#     job_stop', its running state says off with that reason), and 200 done with the right one: the run ends 'failed' with
#     'canceling statement due to user request' within 15 s. actions_log then holds for job_stop: door done=1 refused=2,
#     off refused=1, every row with the UI user, the reason and the job's name; the done row's pid = the job_pid and its
#     statement 'SELECT pg_cancel_backend(<pid>)'. [review fold] a reason holding a NUL is 400 and a SQL Server instance's
#     id 400, neither audited (the job_stop row count unchanged).
#  C. Running now from crafted rows (a stub instance): a job with 3 successful runs of 10 s and a run started 300 s ago: one
#     row, ok_runs 3, avg_secs 10, estimated_end = start + 10 s, over_average true; a second job whose running run the newest
#     read no longer listed is not a row.
#  D. pgAgent: a pgAgent daemon as the plain login agentrunner; a job 'pgv161_agent' (step 'a nap' select pg_sleep(600), step
#     'b after' select 1, on error fail, no schedule) and a disabled one. [run s161-proof2, graded: the steps were 'nap' and
#     'after' and the run stored after=succeeded before nap=failed - pgAgent runs a job's steps in the order of their names,
#     so 'after' ran first; the names now carry the order, the expectation below is unchanged] Run now: 409 on the disabled job ('disabled'), 409 on the second
#     instance, 200 done on pgv161_agent (jobnextrun = now()), the run starts within 75 s with step 'a nap' running ([review
#     fold] its code is a 1,500-character comment then select pg_sleep(600): longer than track_activity_query_size, so
#     the session is found by the cut text's start, while another session of app161 runs another statement on the same
#     database); Run now again
#     409 ('running now'); after the jobs and job_steps reads the Running now row has current_step 'a nap'; Stop 200 done with
#     the pid of agentrunner's session running select pg_sleep(600); the run ends failed within 30 s; after the reads
#     job_step_runs holds 'a nap' failed with output naming the cancel and no 'b after' row (on error fail ends the run);
#     /api/jobs/steps counts 'a nap' failed 1;
#     job_status gives pgv161_agent step_fail_24h 1. actions_log job_start: door done=1 refused=2, off refused=1.
#  E. Exclusions: job_failures holds the two failed jobs; an instance exclusion name 'pgv161_s*' takes the sleeper out
#     (job_failures 1, job_status 'excluded' with the pattern in its reason); '**' refused, the same exclusion again refused
#     ('in force already'); a fleet exclusion name 'PGV161_AGENT' (any case) leaves 0; ending both gives 2 again.
#     [review fold] an add whose body carries ui_user 'spoof' is created_by the UI login.
#  F. A deadlock between two sessions of app161 (application_name pgv161-a and pgv161-b) on dl161, the activity read while
#     both sleep inside their transactions: two serverlog reads store exactly one deadlock event; /api/pg/deadlocks gives 1
#     deadlock, its 2 processes with both pids, the victim the pid that got the error, 2 transaction locks each with one
#     waiter and one holder, relation dl161 named, 1 group, by_user app161, by_application pgv161-a and pgv161-b, by_relation
#     dl161; [review fold] total 1 and the trend's buckets sum to 1. The two sessions are waited for (both active in
#     pg_sleep, bounded at 15 s) before the activity read.
#  G. A pg_cron job changed twice (schedule, then command) with a jobs read after each: /api/jobs/history's changes carry 3
#     scripts; v1 -> v2 differ in exactly the schedule line, v2 -> v3 in exactly the command line.
#  H. The pages in a headless Chromium: the Deadlocks tab draws the graph (an svg.deadlock-graph with 2 process boxes, 1
#     victim box, the word VICTIM) and the groups grid has 1 row; the Jobs tab shows Running now, pgAgent steps, the
#     exclusions and the schedule in words 'at 04:10 every day'; no exception and no console error on either.
#  I. The parser's cases as tests in the scratch copy (the slice owns no test file): a two-process DETAIL; the same under
#     the 'normalized' policy (every number '?': processes by place, blocked by the next one); a three-process cycle; a
#     relation lock 'relation 16384 of database 5'; a statement of two lines; a CONTEXT line naming the relation; and the
#     job action request's shape (pg_cron run now refused, a short reason refused). [review fold] the 'normalized' case is
#     the detail as collect.ApplyTextPolicy stores it (one line), and gives 2 locks (one per holder); the demo's one-line
#     detail gives 2 processes; an empty 'Process N:' line leaves that process without a statement; the statement
#     targets of a SELECT ... FROM now() ... FROM jobs FOR UPDATE (jobs), '/* app */ UPDATE t' (t) and 'BEGIN; UPDATE t' (t).
#  J. every container this run made is gone (0 left), and its volume with it.
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$HOME/go/bin:/usr/local/go/bin:$PATH
for t in docker psql curl python3 go node npm chromium setsid; do command -v $t >/dev/null || { echo "FAIL: $t missing" >&2; exit 1; }; done
[ -f go.mod ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
PGS=${PGVIGIL_PROOF_PGS:-13 16 18}
SUF=$RANDOM; WORK=$(mktemp -d); CT=; SRVPID=; WEBPID=; CHRPID=; VOLS=
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { local rc=$?; set +e
  for p in "$SRVPID" "$WEBPID" "$CHRPID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "$SRVPID" "$WEBPID" "$CHRPID"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  [ -n "$CT" ] && docker rm -f -v "$CT" >/dev/null 2>&1
  rm -rf "$WORK"; exit $rc; }
trap cleanup EXIT INT TERM
echo "load: $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPUs (shared box)"

# --- the scratch build: the tree, the wiring where it lacks it, part I's tests, the bundle, the binary
mkdir -p "$WORK/src"; tar --exclude=./web/node_modules --exclude=./.git --exclude=./bin -cf - . | tar -C "$WORK/src" -xf -
if grep -q '/api/jobs/running' internal/web/web.go; then echo "binary: wired in this tree"
else
  : "${PGVIGIL_PGJD_WIRING:?the tree lacks the routes: name the wiring patch in PGVIGIL_PGJD_WIRING}"
  WIRING=$(realpath "$PGVIGIL_PGJD_WIRING")
  (cd "$WORK/src" && git apply "$WIRING") || fail "the wiring patch does not apply"
  echo "binary: wired in a scratch build (the join applies the same patch)"
fi
cat > "$WORK/src/internal/web/pgdl161_proof_test.go" <<'GOTEST'
package web

import (
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func TestPgDl161(t *testing.T) {
	two := "Process 101 waits for ShareLock on transaction 900; blocked by process 202.\nProcess 202 waits for ShareLock on transaction 901; blocked by process 101.\nProcess 101: UPDATE dl SET v = 1 WHERE id = 2\nProcess 202: UPDATE dl SET v = 2\n  WHERE id = 1\nCONTEXT: while updating tuple (0,2) in relation \"dl\""
	d := parsePgDeadlock(two, "UPDATE dl SET v = 1 WHERE id = 2", 101)
	if !d.Parsed || len(d.Processes) != 2 || len(d.Resources) != 2 {
		t.Fatalf("two: %+v", d)
	}
	p0, p1 := d.Processes[0], d.Processes[1]
	if !p0.Victim || p1.Victim || p0.BlockedBy != "process 202" || p1.BlockedBy != "process 101" {
		t.Fatalf("two: victim / blocked by: %+v %+v", p0, p1)
	}
	if deref(p1.Statement) != "UPDATE dl SET v = 2\n  WHERE id = 1" {
		t.Fatalf("two: a statement of two lines: %q", deref(p1.Statement))
	}
	if deref(p0.Relation) != "dl" || deref(p0.RelationFrom) != "context" || deref(p1.Relation) != "dl" || deref(p1.RelationFrom) != "statement" {
		t.Fatalf("two: relations %q/%q %q/%q", deref(p0.Relation), deref(p0.RelationFrom), deref(p1.Relation), deref(p1.RelationFrom))
	}
	for _, r := range d.Resources {
		if r.Type != "transaction" || len(r.Owners) != 1 || len(r.Waiters) != 1 || deref(r.Owners[0].Mode) != "ExclusiveLock" {
			t.Fatalf("two: lock %+v", r)
		}
	}
	// the detail as the 'normalized' policy stores it
	rows := []collect.Row{{"kind": "event", "kind_of": "deadlock", "detail": two}}
	collect.ApplyTextPolicy(rows, "normalized")
	norm, _ := rows[0]["detail"].(string)
	if strings.Contains(norm, "\n") || strings.Contains(norm, "101") {
		t.Fatalf("normalized: the policy kept a newline or a number: %q", norm)
	}
	n := parsePgDeadlock(norm, "", 101)
	if !n.Parsed || len(n.Processes) != 2 || n.Processes[0].Process != "process #1" || n.Processes[0].BlockedBy != "process #2" ||
		n.Processes[1].BlockedBy != "process #1" || !n.Processes[0].Victim || len(n.Resources) != 2 {
		t.Fatalf("normalized %q: %+v", norm, n)
	}
	for _, r := range n.Resources {
		if len(r.Owners) != 1 || len(r.Waiters) != 1 {
			t.Fatalf("normalized: a lock %+v", r)
		}
	}
	demo := parsePgDeadlock("Process 2001 waits for ShareLock on transaction 88002001; blocked by process 3000. Process 3000 waits for ShareLock on transaction 88003000; blocked by process 2001.", "update x", 2001)
	if len(demo.Processes) != 2 || deref(demo.Processes[0].WaitsOn) != "transaction 88002001" || demo.Processes[0].BlockedBy != "process 3000" {
		t.Fatalf("demo: %+v", demo.Processes)
	}
	empty := parsePgDeadlock("Process 5 waits for ShareLock on transaction 9; blocked by process 6.\nProcess 6 waits for ShareLock on transaction 8; blocked by process 5.\nProcess 5:\nProcess 6: UPDATE t SET v = 1", "", 5)
	if empty.Processes[0].Statement != nil || deref(empty.Processes[1].Statement) != "UPDATE t SET v = 1" {
		t.Fatalf("empty statement line: %q %q", deref(empty.Processes[0].Statement), deref(empty.Processes[1].Statement))
	}
	for in, want := range map[string]string{
		"SELECT extract(epoch from now()) FROM jobs WHERE id = 1 FOR UPDATE": "jobs",
		"/* app */ UPDATE t SET v = 1":                                      "t",
		"BEGIN; UPDATE public.t SET v = 1":                                  "public.t",
		"Start Transaction; -- note\nDELETE FROM s.x WHERE id = 1":         "s.x",
		"select 1":                                                          "",
	} {
		if got := stmtTarget(in); got != want {
			t.Fatalf("stmtTarget(%q) = %q, want %q", in, got, want)
		}
	}
	three := "Process 1 waits for ExclusiveLock on tuple (0,1) of relation 16384 of database 5; blocked by process 2.\nProcess 2 waits for ShareLock on transaction 7; blocked by process 3.\nProcess 3 waits for AccessExclusiveLock on relation 16384 of database 5; blocked by process 1.\nProcess 1: SELECT 1\nProcess 2: SELECT 2\nProcess 3: LOCK TABLE public.x"
	h := parsePgDeadlock(three, "", 3)
	if len(h.Processes) != 3 || !h.Processes[2].Victim || h.Processes[0].lockRel == nil || h.Processes[0].lockRel.rel != 16384 || h.Processes[0].lockRel.db != 5 ||
		h.Processes[2].lockRel == nil || h.Processes[0].lockKind != "tuple" || h.Processes[2].lockKind != "relation" || h.Processes[1].lockKind != "transaction" {
		t.Fatalf("three: %+v %+v %+v", h.Processes[0], h.Processes[1], h.Processes[2])
	}
	if e := parsePgDeadlock("", "UPDATE x", 9); e.Parsed || len(e.Processes) != 0 {
		t.Fatalf("empty: %+v", e)
	}
	if got := dlShape("UPDATE dl SET v = 'a''b' WHERE id = 42"); got != "UPDATE dl SET v = ? WHERE id = ?" {
		t.Fatalf("shape: %q", got)
	}
}
GOTEST
cat > "$WORK/src/internal/collect/jobact161_proof_test.go" <<'GOTEST'
package collect

import "testing"

func TestJobAction161(t *testing.T) {
	ok := JobActionRequest{Kind: JobStop, Scheduler: "pg_cron", JobID: 1, JobName: "j", RunID: 2, PID: 3, Reason: "a reason", User: "u"}
	if err := ValidateJobAction(ok); err != nil {
		t.Fatalf("a good stop refused: %v", err)
	}
	for name, r := range map[string]JobActionRequest{
		"pg_cron run now":  {Kind: JobStart, Scheduler: "pg_cron", JobID: 1, JobName: "j", Reason: "a reason", User: "u"},
		"short reason":     {Kind: JobStop, Scheduler: "pg_cron", JobID: 1, JobName: "j", RunID: 2, PID: 3, Reason: "abc", User: "u"},
		"no run":           {Kind: JobStop, Scheduler: "pgagent", JobID: 1, JobName: "j", Reason: "a reason", User: "u"},
		"no pid (pg_cron)": {Kind: JobStop, Scheduler: "pg_cron", JobID: 1, JobName: "j", RunID: 2, Reason: "a reason", User: "u"},
		"no user":          {Kind: JobStart, Scheduler: "pgagent", JobID: 1, JobName: "j", Reason: "a reason"},
		"other scheduler":  {Kind: JobStart, Scheduler: "sqlagent", JobID: 1, JobName: "j", Reason: "a reason", User: "u"},
	} {
		if err := ValidateJobAction(r); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}
GOTEST
echo "--- I. the parser's and the request's cases"
(cd "$WORK/src" && go test -count=1 -run 'TestPgDl161|TestJobAction161' ./internal/web ./internal/collect) || fail "I: the cases"
echo "I: OK"
(cd "$WORK/src/web" && npm ci --silent >/dev/null 2>&1 && npm run --silent build >/dev/null 2>&1) || fail "the bundle did not build"
(cd "$WORK/src" && CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil) || fail "the binary did not build"
BIN=$WORK/pgvigil

# the page check (part H), over the browser's debugging port
cat > "$WORK/page.mjs" <<'PAGE'
const [port, base, inst] = process.argv.slice(2);
setTimeout(() => { console.log('FAIL the page check did not end in 120 s'); process.exit(2); }, 120000).unref();
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(); let thrown = [];
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? d.params.exceptionDetails?.text ?? 'exception');
  if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') thrown.push('console.error: ' + d.params.args.map(a => a.value ?? a.description ?? '').join(' '));
  if (d.method === 'Log.entryAdded' && d.params.entry.level === 'error') thrown.push('log: ' + d.params.entry.text + ' ' + (d.params.entry.url ?? ''));
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => { const d = await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true }); return d.result?.result?.value; };
const until = async (expr, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(250); } return null; };
let failed = 0;
const check = (label, ok, what) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: ${what}`); };
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Log.enable');
const errBoxes = `[...document.querySelectorAll('main p.error')].map(p => p.textContent.trim())`;
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1200, deviceScaleFactor: 1, mobile: false });
const heads = `[...document.querySelectorAll('main h3')].map(h => h.textContent.trim())`;
// the Deadlocks tab
thrown = [];
await cmd('Page.navigate', { url: `${base}/#/pg_deadlocks?i=${inst}` });
const dl = await until(`(() => { const s = document.querySelector('main svg.deadlock-graph'); if (!s) return null;
  const g = [...document.querySelectorAll('main h3')].find(h => h.textContent.startsWith('Grouped by'));
  let t = g?.nextElementSibling; while (t && !t.querySelector?.('table') && t.tagName !== 'TABLE') t = t.nextElementSibling;
  const rows = (t?.tagName === 'TABLE' ? t : t?.querySelector('table'))?.querySelectorAll('tbody tr').length ?? -1;
  return { procs: s.querySelectorAll('.dl-process').length, victims: s.querySelectorAll('.dl-victim').length, victimWord: s.textContent.includes('VICTIM'), groups: rows }; })()`);
check('the Deadlocks tab', dl && dl.procs === 2 && dl.victims === 1 && dl.victimWord && dl.groups === 1, JSON.stringify(dl));
await sleep(500);
thrown.push(...(await ev(errBoxes)).map(x => 'error box: ' + x));
check('the Deadlocks tab: no exception, no error', thrown.length === 0, thrown.join(' | ') || 'none');
// the Jobs tab
thrown = [];
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(300);
await cmd('Page.navigate', { url: `${base}/#/jobs?i=${inst}` });
const jb = await until(`(() => { const h = ${heads}; if (!h.some(x => x.startsWith('Running now'))) return null;
  return { running: true, steps: h.some(x => x.startsWith('pgAgent steps')), excl: h.includes('Left out of the job checks'),
           words: [...document.querySelectorAll('main td')].some(td => td.textContent.trim() === 'at 04:10 every day') }; })()`, 30000);
check('the Jobs tab', jb && jb.steps && jb.excl && jb.words, JSON.stringify(jb));
await sleep(500);
thrown.push(...(await ev(errBoxes)).map(x => 'error box: ' + x));
check('the Jobs tab: no exception, no error', thrown.length === 0, thrown.join(' | ') || 'none');
ws.close();
process.exit(failed ? 1 : 0);
PAGE

# one PostgreSQL major, parts A to H
run_major() {
  local V=$1 PORT SPORT WPORT PW APW UPW USR I IOFF ISTUB U CJ R
  echo "=== PostgreSQL $V"
  if ! docker image inspect "pgvigil-proof-pgcron:$V" >/dev/null 2>&1; then
    printf 'FROM postgres:%s\nRUN apt-get update -qq && apt-get install -y -qq postgresql-%s-cron pgagent >/dev/null && rm -rf /var/lib/apt/lists/*\n' "$V" "$V" \
      | docker build -q -t "pgvigil-proof-pgcron:$V" - >/dev/null || fail "the image pgvigil-proof-pgcron:$V did not build"
  fi
  rnd() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
  PW="pw$(rnd)"; APW="ap$(rnd)"; UPW="ui$(rnd)"; USR="proof161"
  PORT=$((21000 + RANDOM % 9000)); CT="pgv161-$V-$SUF"
  printf 'POSTGRES_PASSWORD=%s\n' "$PW" > "$WORK/env-$V"; chmod 600 "$WORK/env-$V"   # the password off the command line
  docker run -d --name "$CT" --env-file "$WORK/env-$V" -p "127.0.0.1:$PORT:5432" "pgvigil-proof-pgcron:$V" \
    -c shared_preload_libraries=pg_cron -c cron.database_name=postgres -c logging_collector=on -c log_directory=log \
    -c "log_line_prefix=%m [%p] %q%u@%d " -c deadlock_timeout=200ms >/dev/null
  VOLS="$VOLS $(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$CT")"
  for _ in $(seq 1 60); do docker exec "$CT" pg_isready -q -U postgres 2>/dev/null && break; sleep 1; done
  sleep 2
  export PGPASSWORD=$PW
  local ADM="host=127.0.0.1 port=$PORT user=postgres"
  sq() { psql "$ADM dbname=${2:-postgres}" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
  for _ in $(seq 1 30); do sq "select 1" >/dev/null 2>&1 && break; sleep 1; done
  sq "create database pgvigil_repo" >/dev/null
  sq "create extension pg_cron" >/dev/null
  sq "create role jobber login" >/dev/null
  sq "create role pgv161act login password '$APW' nosuperuser in role pg_signal_backend" >/dev/null
  sq "create role app161 login password '$APW'" >/dev/null
  sq "create table public.dl161 (id int primary key, v int); insert into public.dl161 values (1, 0), (2, 0); grant select, update on public.dl161 to app161" >/dev/null
  export PGVIGIL_REPO_DSN="$ADM password=$PW dbname=pgvigil_repo" MON_DSN="$ADM password=$PW dbname=postgres" \
         ACT_DSN="host=127.0.0.1 port=$PORT user=pgv161act password=$APW dbname=postgres"
  local CFG=$WORK/cfg-$V.yaml
  printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: pgjd-%s\n    dsn: env:MON_DSN\n    actions_dsn: env:ACT_DSN\n    actions: [job_stop, job_start]\n  - name: pgjd-%s-off\n    dsn: env:MON_DSN\n    actions_dsn: env:ACT_DSN\n' "$V" "$V" > "$CFG"
  q() { psql "$ADM dbname=pgvigil_repo" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }   # PGPASSWORD: no password in argv

  echo "--- A. migrate"
  "$BIN" migrate -config "$CFG" >/dev/null || fail "A: migrate"
  [ "$(q "select count(*) from pgvigil.schema_version where version = '0102_pg_jobs_deadlocks.sql'")" = 1 ] || fail "A: 0102 not applied"
  [ "$(q "select count(*) from pg_class where oid in ('pgvigil.job_step_runs'::regclass, 'pgvigil.job_exclusions'::regclass)")" = 2 ] || fail "A: the new tables"
  local DEF; DEF=$(q "select pg_get_constraintdef(oid) from pg_constraint where conname = 'actions_log_action_check'")
  [[ "${DEF%%sqlserver*}" == *"'postgres'"*"'job_stop'"* ]] || fail "A: the action check's postgres branch lacks job_stop: $DEF"
  local BAD=$WORK/bad-$V.yaml OUT
  for c in "kill|unknown action" "job_stop, job_stop|twice"; do
    printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: x\n    dsn: env:MON_DSN\n    actions_dsn: env:ACT_DSN\n    actions: [%s]\n' "${c%%|*}" > "$BAD"
    if OUT=$("$BIN" migrate -config "$BAD" 2>&1); then fail "A: actions: [${c%%|*}] was taken on a PostgreSQL instance"; fi
    [[ "$OUT" == *"${c#*|}"* ]] || fail "A: actions: [${c%%|*}]'s refusal: $OUT"
  done
  printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: x\n    dsn: env:MON_DSN\n    actions: [job_stop]\n' > "$BAD"
  if OUT=$("$BIN" migrate -config "$BAD" 2>&1); then fail "A: actions: without actions_dsn was taken"; fi
  [[ "$OUT" == *"no actions_dsn"* ]] || fail "A: actions: without actions_dsn, its refusal: $OUT"
  echo "A: OK"
  PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$CFG" "$USR" >/dev/null 2>&1 || fail "setup: user add"
  "$BIN" collect -config "$CFG" -once instance >/dev/null 2>&1 || true
  I=$(q "select instance_id from pgvigil.instances where name = 'pgjd-$V'"); IOFF=$(q "select instance_id from pgvigil.instances where name = 'pgjd-$V-off'")
  [ -n "$I" ] && [ -n "$IOFF" ] || { "$BIN" collect -config "$CFG" -once jobs >/dev/null 2>&1 || true; I=$(q "select instance_id from pgvigil.instances where name = 'pgjd-$V'"); IOFF=$(q "select instance_id from pgvigil.instances where name = 'pgjd-$V-off'"); }
  [ -n "$I" ] && [ -n "$IOFF" ] || fail "setup: the instances were not registered"
  SPORT=$((31000 + RANDOM % 9000)); U="http://127.0.0.1:$SPORT"; CJ=$WORK/cj-$V
  "$BIN" serve -config "$CFG" -listen "127.0.0.1:$SPORT" >"$WORK/serve-$V.log" 2>&1 & SRVPID=$!
  for _ in $(seq 1 60); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
  [ "$(curl -s -o "$WORK/b" -w '%{http_code}' -c "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "{\"username\":\"$USR\",\"password\":\"$UPW\"}" "$U/api/login")" = 200 ] || fail "setup: the UI login: $(cat "$WORK/b")"
  api() { curl -s -o "$WORK/b" -w '%{http_code}' -b "$CJ" "$U/api/$1"; }
  postj() { curl -s -o "$WORK/b" -w '%{http_code}' -b "$CJ" ${3:+-H 'X-Pgvigil: 1'} -H 'Content-Type: application/json' --data "$2" "$U/api/$1"; }
  js() { python3 -c "import json,sys; d=json.load(open('$WORK/b')); print($1)"; }
  collect() { for c in "$@"; do "$BIN" collect -config "$CFG" -once "$c" >/dev/null 2>&1 || fail "the $c read failed"; done; }

  echo "--- B. pg_cron Stop"
  local JID RUN JPID
  JID=$(sq "select cron.schedule_in_database('pgv161_sleeper', '* * * * *', 'select pg_sleep(600)', 'postgres', 'jobber', true)")
  for _ in $(seq 1 80); do RUN=$(sq "select runid || ' ' || job_pid from cron.job_run_details where jobid = $JID and status = 'running' order by runid limit 1"); [ -n "$RUN" ] && break; sleep 1; done
  [ -n "$RUN" ] || fail "B: the pg_cron run did not start in 80 s"
  JPID=${RUN#* }; RUN=${RUN% *}
  collect jobs
  [ "$(api "jobs/running?instance=$I")" = 200 ] || fail "B: running: $(cat "$WORK/b")"
  [ "$(js "[r for r in [dict(zip(d['running']['columns'], x)) for x in d['running']['rows']] if r['job_name']=='pgv161_sleeper' and r['run_id']==$RUN and r['job_pid']==$JPID].__len__()")" = 1 ] || fail "B: the run is not in Running now: $(cat "$WORK/b" | cut -c1-400)"
  [ "$(js "d['actions']['job_stop']['on']")" = True ] || fail "B: Stop is off on the door instance: $(js "d['actions']")"
  api "jobs/running?instance=$IOFF" >/dev/null; [[ "$(js "d['actions']['job_stop']['reason']")" == *"does not name job_stop"* ]] || fail "B: the off instance's state: $(js "d['actions']")"
  local BODY="{\"instance_id\":$I,\"scheduler\":\"pg_cron\",\"job_id\":$JID,\"job_name\":\"pgv161_sleeper\",\"run_id\":$RUN,\"job_pid\":$JPID,\"reason\":\"proof 161: stop the sleeper\""
  [ "$(postj jobs/actions/stop "$BODY,\"confirm\":\"pgv161_sleeper\"}")" = 403 ] || fail "B: without the header: $(cat "$WORK/b")"
  [ "$(postj jobs/actions/stop "$BODY,\"confirm\":\"wrong\"}" h)" = 409 ] || fail "B: a wrong confirmation: $(cat "$WORK/b")"
  [[ "$(js "d['detail']")" == *"typed confirmation"* ]] || fail "B: the wrong confirmation's reason: $(cat "$WORK/b")"
  [ "$(postj jobs/actions/stop "${BODY/\"job_pid\":$JPID/\"job_pid\":$((JPID + 1))},\"confirm\":\"pgv161_sleeper\"}" h)" = 409 ] || fail "B: another pid: $(cat "$WORK/b")"
  [[ "$(js "d['detail']")" == *"job_pid is"* ]] || fail "B: another pid's reason: $(cat "$WORK/b")"
  [ "$(postj jobs/actions/stop "${BODY/\"instance_id\":$I/\"instance_id\":$IOFF},\"confirm\":\"pgv161_sleeper\"}" h)" = 409 ] || fail "B: the off instance: $(cat "$WORK/b")"
  [[ "$(js "d['detail']")" == *"does not name job_stop"* ]] || fail "B: the off instance's reason: $(cat "$WORK/b")"
  local N0 IMS
  N0=$(q "select count(*) from pgvigil.actions_log where action = 'job_stop'")
  [ "$(postj jobs/actions/stop "${BODY/proof 161: stop the sleeper/proof 161\\u0000 nul},\"confirm\":\"pgv161_sleeper\"}" h)" = 400 ] || fail "B: a NUL: $(cat "$WORK/b")"
  IMS=$(q "select pgvigil.ensure_instance('pgjd-$V-ms', 'onprem', '16', 60000, false, '{}')")
  q "update pgvigil.instances set engine = 'sqlserver' where instance_id = $IMS" >/dev/null
  [ "$(postj jobs/actions/stop "${BODY/\"instance_id\":$I/\"instance_id\":$IMS},\"confirm\":\"pgv161_sleeper\"}" h)" = 400 ] || fail "B: a SQL Server instance: $(cat "$WORK/b")"
  [ "$(q "select count(*) from pgvigil.actions_log where action = 'job_stop'")" = "$N0" ] || fail "B: the NUL or the SQL Server instance wrote an audit row"
  [ "$(postj jobs/actions/stop "$BODY,\"confirm\":\"pgv161_sleeper\"}" h)" = 200 ] || fail "B: the stop: $(cat "$WORK/b")"
  echo "  the stop: $(js "d['detail']")"
  local ST=
  for _ in $(seq 1 15); do ST=$(sq "select status || ': ' || coalesce(return_message, '') from cron.job_run_details where runid = $RUN"); [[ "$ST" == failed* ]] && break; sleep 1; done
  # off, not dropped: the job stays on the server (job_status lists present jobs only, part E reads it)
  sq "select cron.alter_job($JID, active => false)" >/dev/null
  [[ "$ST" == failed*"canceling statement due to user request"* ]] || fail "B: the run after the stop: $ST"
  echo "  the run: $ST"
  R=$(q "select string_agg(n || ':' || outcome || '=' || c, ' ' order by n, outcome) from (select case instance_id when $I then 'door' else 'off' end n, outcome, count(*) c
          from pgvigil.actions_log where instance_id in ($I, $IOFF) and action = 'job_stop' group by 1, 2) x")
  [ "$R" = "door:done=1 door:refused=2 off:refused=1" ] || fail "B: actions_log job_stop holds '$R'"
  [ "$(q "select count(*) from pgvigil.actions_log where action = 'job_stop' and (ui_user <> '$USR' or reason not like 'proof 161%' or target <> 'pgv161_sleeper')")" = 0 ] || fail "B: an audit row misses the user, the reason or the job"
  [ "$(q "select pid || '|' || statement from pgvigil.actions_log where action = 'job_stop' and outcome = 'done'")" = "$JPID|SELECT pg_cancel_backend($JPID)" ] || fail "B: the done row's pid and statement"
  echo "B: OK ($R)"

  echo "--- C. Running now from crafted rows"
  ISTUB=$(q "select pgvigil.ensure_instance('pgjd-$V-stub', 'onprem', '$V', 60000, false, '{}')")
  q "select pgvigil.import_jobs($ISTUB, now() - interval '2 minutes', '[
   {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":900,\"job_name\":\"stub-a\",\"schedule\":\"0 * * * *\",\"command\":\"select 1\",\"datname\":\"app\",\"run_as\":\"app\",\"active\":true},
   {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":901,\"job_name\":\"stub-b\",\"schedule\":\"0 * * * *\",\"command\":\"select 2\",\"datname\":\"app\",\"run_as\":\"app\",\"active\":true},
   {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":900,\"run_id\":1,\"status\":\"succeeded\",\"start_time\":\"$(date -u -d '-3 hour' +%FT%TZ)\",\"end_time\":\"$(date -u -d '-3 hour +10 sec' +%FT%TZ)\",\"duration_secs\":10},
   {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":900,\"run_id\":2,\"status\":\"succeeded\",\"start_time\":\"$(date -u -d '-2 hour' +%FT%TZ)\",\"end_time\":\"$(date -u -d '-2 hour +10 sec' +%FT%TZ)\",\"duration_secs\":10},
   {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":900,\"run_id\":3,\"status\":\"succeeded\",\"start_time\":\"$(date -u -d '-1 hour' +%FT%TZ)\",\"end_time\":\"$(date -u -d '-1 hour +10 sec' +%FT%TZ)\",\"duration_secs\":10},
   {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":901,\"run_id\":9,\"status\":\"running\",\"start_time\":\"$(date -u -d '-10 min' +%FT%TZ)\"}]'::jsonb)" >/dev/null
  q "select pgvigil.import_jobs($ISTUB, now(), '[
   {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":900,\"job_name\":\"stub-a\",\"schedule\":\"0 * * * *\",\"command\":\"select 1\",\"datname\":\"app\",\"run_as\":\"app\",\"active\":true},
   {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":901,\"job_name\":\"stub-b\",\"schedule\":\"0 * * * *\",\"command\":\"select 2\",\"datname\":\"app\",\"run_as\":\"app\",\"active\":true},
   {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":900,\"run_id\":4,\"status\":\"running\",\"start_time\":\"$(date -u -d '-300 sec' +%FT%TZ)\"}]'::jsonb)" >/dev/null
  R=$(q "select count(*) || '|' || string_agg(job_name || ' ' || ok_runs || ' ' || avg_secs || ' ' || (estimated_end = start_time + interval '10 seconds') || ' ' || over_average, ',') from pgvigil.pg_jobs_running($ISTUB)")
  [ "$R" = "1|stub-a 3 10 true true" ] || fail "C: pg_jobs_running gives '$R'"
  echo "C: OK ($R)"

  echo "--- D. pgAgent Run now, Stop and the step log"
  sq "create extension pgagent" >/dev/null
  sq "create role agentrunner login; grant usage on schema pgagent to agentrunner; grant all on all tables in schema pgagent to agentrunner; grant all on all sequences in schema pgagent to agentrunner" >/dev/null
  sq "grant usage on schema pgagent to pgv161act; grant select (jobid, jobenabled, jobagentid), update (jobnextrun) on pgagent.pga_job to pgv161act" >/dev/null
  docker exec -d "$CT" su postgres -c "pgagent -f -l 1 -s /tmp/pgagent.log hostaddr=127.0.0.1 dbname=postgres user=agentrunner" >/dev/null
  for _ in $(seq 1 30); do [ "$(sq "select count(*) from pgagent.pga_jobagent")" -gt 0 ] && break; sleep 1; done
  [ "$(sq "select count(*) from pgagent.pga_jobagent")" -gt 0 ] || fail "D: pgAgent did not connect: $(docker exec "$CT" tail -5 /tmp/pgagent.log 2>&1)"
  local AJ DJ
  AJ=$(sq "with j as (insert into pgagent.pga_job (jobjclid, jobname, jobenabled) values (1, 'pgv161_agent', true) returning jobid),
           s as (insert into pgagent.pga_jobstep (jstjobid, jstname, jstkind, jstdbname, jstonerror, jstcode)
                 select jobid, x.n, 's', 'postgres', 'f', x.c from j, (values ('a nap', '/* pgv161 ' || repeat('x', 1500) || ' */ select pg_sleep(600)'), ('b after', 'select 1')) x(n, c) returning 1)
           select jobid from j, (select count(*) from s) c")
  DJ=$(sq "insert into pgagent.pga_job (jobjclid, jobname, jobenabled) values (1, 'pgv161_disabled', false) returning jobid")
  collect jobs job_steps
  local ABODY="{\"instance_id\":$I,\"scheduler\":\"pgagent\",\"job_id\":$AJ,\"job_name\":\"pgv161_agent\",\"reason\":\"proof 161: run the agent job\",\"confirm\":\"pgv161_agent\"}"
  [ "$(postj jobs/actions/start "{\"instance_id\":$I,\"scheduler\":\"pgagent\",\"job_id\":$DJ,\"job_name\":\"pgv161_disabled\",\"reason\":\"proof 161: a disabled job\",\"confirm\":\"pgv161_disabled\"}" h)" = 409 ] || fail "D: the disabled job: $(cat "$WORK/b")"
  [[ "$(js "d['detail']")" == *"disabled"* ]] || fail "D: the disabled job's reason: $(cat "$WORK/b")"
  [ "$(postj jobs/actions/start "${ABODY/\"instance_id\":$I/\"instance_id\":$IOFF}" h)" = 409 ] || fail "D: the off instance: $(cat "$WORK/b")"
  [ "$(postj jobs/actions/start "$ABODY" h)" = 200 ] || fail "D: Run now: $(cat "$WORK/b")"
  echo "  Run now: $(js "d['detail']")"
  local ARUN=
  for _ in $(seq 1 75); do ARUN=$(sq "select l.jlgid from pgagent.pga_joblog l join pgagent.pga_jobsteplog s on s.jsljlgid = l.jlgid join pgagent.pga_jobstep t on t.jstid = s.jsljstid
                                      where l.jlgjobid = $AJ and l.jlgstatus = 'r' and s.jslstatus = 'r' and t.jstname = 'a nap'"); [ -n "$ARUN" ] && break; sleep 1; done
  [ -n "$ARUN" ] || fail "D: the pgAgent run did not start in 75 s: $(docker exec "$CT" tail -5 /tmp/pgagent.log 2>&1)"
  [ "$(postj jobs/actions/start "$ABODY" h)" = 409 ] || fail "D: Run now while it runs: $(cat "$WORK/b")"
  [[ "$(js "d['detail']")" == *"running now"* ]] || fail "D: Run now while it runs, its reason: $(cat "$WORK/b")"
  collect jobs job_steps
  api "jobs/running?instance=$I" >/dev/null
  [ "$(js "[r['current_step'] for r in [dict(zip(d['running']['columns'], x)) for x in d['running']['rows']] if r['job_name']=='pgv161_agent']")" = "['a nap']" ] || fail "D: Running now's current step: $(cut -c1-400 "$WORK/b")"
  local SPID OTHER
  # another session on the same database, another statement: never the step's
  PGPASSWORD=$APW PGAPPNAME=pgv161-other psql "host=127.0.0.1 port=$PORT user=app161 dbname=postgres" -XAtq -c "select pg_sleep(40)" >/dev/null 2>&1 & OTHER=$!
  for _ in $(seq 1 15); do [ "$(sq "select count(*) from pg_stat_activity where application_name = 'pgv161-other' and state = 'active'")" = 1 ] && break; sleep 1; done
  SPID=$(sq "select pid from pg_stat_activity where usename = 'agentrunner' and query like '/* pgv161 %' and state = 'active'")
  [ -n "$SPID" ] || fail "D: the step's session is not active"
  [ "$(sq "select octet_length(query) < 1500 from pg_stat_activity where pid = $SPID")" = t ] || fail "D: the step's text is not cut (track_activity_query_size), the long-code case proves nothing"
  [ "$(postj jobs/actions/stop "{\"instance_id\":$I,\"scheduler\":\"pgagent\",\"job_id\":$AJ,\"job_name\":\"pgv161_agent\",\"run_id\":$ARUN,\"reason\":\"proof 161: stop the agent job\",\"confirm\":\"pgv161_agent\"}" h)" = 200 ] || fail "D: the pgAgent stop: $(cat "$WORK/b")"
  [ "$(js "d['pid']")" = "$SPID" ] || fail "D: the stop cancelled pid $(js "d['pid']"), the step's session is $SPID"
  kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null || true
  echo "  the stop: $(js "d['detail']")"
  for _ in $(seq 1 30); do [ "$(sq "select jlgstatus from pgagent.pga_joblog where jlgid = $ARUN")" = f ] && break; sleep 1; done
  [ "$(sq "select jlgstatus from pgagent.pga_joblog where jlgid = $ARUN")" = f ] || fail "D: the pgAgent run did not end failed"
  collect jobs job_steps
  R=$(q "select string_agg(step_name || '=' || status, ',' order by step_log_id) from pgvigil.job_step_runs where instance_id = $I and run_id = $ARUN")
  [ "$R" = "a nap=failed" ] || fail "D: job_step_runs of the run: '$R'"
  [[ "$(q "select output from pgvigil.job_step_runs where instance_id = $I and run_id = $ARUN")" == *ancel* ]] || fail "D: the step's output does not name the cancel"
  api "jobs/steps?instance=$I&job=$AJ&from=$(date -u -d '-1 hour' +%FT%TZ)&to=$(date -u -d '+5 min' +%FT%TZ)" >/dev/null
  [ "$(js "[(r['step_name'], r['failed']) for r in [dict(zip(d['steps']['columns'], x)) for x in d['steps']['rows']]]")" = "[('a nap', 1)]" ] || fail "D: /api/jobs/steps: $(cut -c1-300 "$WORK/b")"
  [ "$(q "select step_fail_24h from pgvigil.job_status($I) where job_name = 'pgv161_agent'")" = 1 ] || fail "D: job_status's step failures"
  R=$(q "select string_agg(n || ':' || outcome || '=' || c, ' ' order by n, outcome) from (select case instance_id when $I then 'door' else 'off' end n, outcome, count(*) c
          from pgvigil.actions_log where instance_id in ($I, $IOFF) and action = 'job_start' group by 1, 2) x")
  [ "$R" = "door:done=1 door:refused=2 off:refused=1" ] || fail "D: actions_log job_start holds '$R'"
  echo "D: OK ($R; step log $(q "select string_agg(step_name || '=' || status, ',') from pgvigil.job_step_runs where instance_id = $I"))"

  echo "--- E. exclusions"
  local F0 X1 X2
  F0=$(q "select count(*) from pgvigil.job_failures where instance_id = $I")
  [ "$F0" = 2 ] || fail "E: job_failures before: $F0"
  [ "$(postj jobs/exclusions "{\"op\":\"add\",\"level\":\"instance\",\"instance_id\":$I,\"match_on\":\"name\",\"pattern\":\"pgv161_s*\",\"note\":\"proof 161\"}" h)" = 200 ] || fail "E: add: $(cat "$WORK/b")"
  X1=$(js "d['exclusion_id']")
  [ "$(postj jobs/exclusions "{\"op\":\"add\",\"level\":\"instance\",\"instance_id\":$I,\"match_on\":\"name\",\"pattern\":\"pgv161_d*\",\"ui_user\":\"spoof\",\"client\":\"1.2.3.4\"}" h)" = 200 ] || fail "E: the spoofed add: $(cat "$WORK/b")"
  local XS; XS=$(js "d['exclusion_id']")
  [ "$(q "select created_by || '|' || coalesce(client, '') from pgvigil.job_exclusions where exclusion_id = $XS")" != "spoof|1.2.3.4" ] || fail "E: the body's ui_user / client were taken"
  [ "$(q "select created_by from pgvigil.job_exclusions where exclusion_id = $XS")" = "$USR" ] || fail "E: the spoofed add's created_by"
  [ "$(postj jobs/exclusions "{\"op\":\"end\",\"exclusion_id\":$XS}" h)" = 200 ] || fail "E: end the spoofed add"
  [ "$(q "select count(*) from pgvigil.job_failures where instance_id = $I")" = 1 ] || fail "E: job_failures with the instance exclusion"
  [[ "$(q "select status || ' ' || reason from pgvigil.job_status($I) where job_name = 'pgv161_sleeper'")" == "excluded "*"pgv161_s*"* ]] || fail "E: job_status of the sleeper"
  [ "$(postj jobs/exclusions "{\"op\":\"add\",\"level\":\"instance\",\"instance_id\":$I,\"match_on\":\"name\",\"pattern\":\"**\"}" h)" = 409 ] || fail "E: '**' was taken"
  [ "$(postj jobs/exclusions "{\"op\":\"add\",\"level\":\"instance\",\"instance_id\":$I,\"match_on\":\"name\",\"pattern\":\"pgv161_s*\"}" h)" = 409 ] || fail "E: the same exclusion again"
  [[ "$(js "d['detail']")" == *"in force already"* ]] || fail "E: the duplicate's reason: $(cat "$WORK/b")"
  [ "$(postj jobs/exclusions "{\"op\":\"add\",\"level\":\"root\",\"match_on\":\"name\",\"pattern\":\"PGV161_AGENT\"}" h)" = 200 ] || fail "E: the fleet exclusion: $(cat "$WORK/b")"
  X2=$(js "d['exclusion_id']")
  [ "$(q "select count(*) from pgvigil.job_failures where instance_id = $I")" = 0 ] || fail "E: job_failures with both"
  api "jobs/exclusions?instance=$I" >/dev/null; [ "$(js "len(d['exclusions']['rows'])")" = 2 ] || fail "E: the list"
  for x in "$X1" "$X2"; do [ "$(postj jobs/exclusions "{\"op\":\"end\",\"exclusion_id\":$x}" h)" = 200 ] || fail "E: end $x: $(cat "$WORK/b")"; done
  [ "$(q "select count(*) from pgvigil.job_failures where instance_id = $I")" = 2 ] || fail "E: job_failures after the ends"
  echo "E: OK"

  echo "--- F. a deadlock"
  local AB="host=127.0.0.1 port=$PORT user=app161 dbname=postgres"
  PGPASSWORD=$APW PGAPPNAME=pgv161-a psql "$AB" -XAtq -c "begin" -c "select 'pid ' || pg_backend_pid()" -c "update dl161 set v = 1 where id = 1" -c "select pg_sleep(10)" \
    -c "update dl161 set v = 1 where id = 2" -c "commit" >"$WORK/dla" 2>&1 &
  local PA=$!
  sleep 1
  PGPASSWORD=$APW PGAPPNAME=pgv161-b psql "$AB" -XAtq -c "begin" -c "select 'pid ' || pg_backend_pid()" -c "update dl161 set v = 2 where id = 2" -c "select pg_sleep(5)" \
    -c "update dl161 set v = 2 where id = 1" -c "commit" >"$WORK/dlb" 2>&1 &
  local PB=$!
  # both in their transactions, sleeping, before the activity read (bounded)
  for _ in $(seq 1 30); do [ "$(sq "select count(*) from pg_stat_activity where application_name in ('pgv161-a', 'pgv161-b') and state = 'active' and query like 'select pg_sleep%'")" = 2 ] && break; sleep 0.5; done
  [ "$(sq "select count(*) from pg_stat_activity where application_name in ('pgv161-a', 'pgv161-b') and state = 'active' and query like 'select pg_sleep%'")" = 2 ] || fail "F: the two sessions were not both sleeping inside their transactions"
  collect activity
  wait $PA || true; wait $PB || true
  local PIDA PIDB VIC
  PIDA=$(sed -n 's/^pid //p' "$WORK/dla"); PIDB=$(sed -n 's/^pid //p' "$WORK/dlb")
  if grep -q "deadlock detected" "$WORK/dla"; then VIC=$PIDA; elif grep -q "deadlock detected" "$WORK/dlb"; then VIC=$PIDB; else fail "F: no session got the deadlock: $(cat "$WORK/dla" "$WORK/dlb")"; fi
  sleep 1; collect serverlog serverlog
  [ "$(q "select count(*) from pgvigil.log_events where instance_id = $I and kind = 'deadlock'")" = 1 ] || fail "F: deadlock events stored: $(q "select count(*) from pgvigil.log_events where instance_id = $I and kind = 'deadlock'") ($(q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id = $I and collection = 'serverlog'"))"
  [ "$(api "pg/deadlocks?instance=$I&from=$(date -u -d '-1 hour' +%FT%TZ)&to=$(date -u -d '+5 min' +%FT%TZ)")" = 200 ] || fail "F: the API: $(cat "$WORK/b")"
  R=$(js "(lambda e: '%d %s %s %d %s %s %d %s %s %s' % (len(d['deadlocks']), sorted(p['spid'] for p in e['processes']), [p['spid'] for p in e['processes'] if p['victim']],
          len(e['resources']), sorted(r['type'] for r in e['resources']), sorted((len(r['waiters']), len(r['owners'])) for r in e['resources']), len(d['groups']),
          'dl161' in e['relations'], sorted(c['name'] for c in d['by_user']), sorted(c['name'] for c in d['by_application'])))(d['deadlocks'][0])")
  local WANT
  WANT="1 $(python3 -c "print(sorted([$PIDA, $PIDB]))") [$VIC] 2 ['transaction', 'transaction'] [(1, 1), (1, 1)] 1 True ['app161'] ['pgv161-a', 'pgv161-b']"
  [ "$R" = "$WANT" ] || fail "F: the deadlock read '$R', expected '$WANT'"
  [ "$(js "[c['name'] for c in d['by_relation']]")" = "['dl161']" ] || fail "F: by_relation: $(js "d['by_relation']")"
  [ "$(js "(d['total'], sum(t['deadlocks'] for t in d['trend']))")" = "(1, 1)" ] || fail "F: total and trend: $(js "(d['total'], [t for t in d['trend'] if t['deadlocks']])")"
  echo "F: OK ($R)"

  echo "--- G. a job changed twice: its script diff"
  local GJ
  GJ=$(sq "select cron.schedule_in_database('pgv161_diff', '5 4 * * *', 'select 1', 'postgres', 'jobber', false)")
  collect jobs; sleep 1
  sq "select cron.alter_job($GJ, schedule => '10 4 * * *')" >/dev/null; collect jobs; sleep 1
  sq "select cron.alter_job($GJ, command => 'select 2')" >/dev/null; collect jobs
  [ "$(api "jobs/history?instance=$I&engine=pg&scheduler=pg_cron&job=$GJ")" = 200 ] || fail "G: the history: $(cat "$WORK/b")"
  R=$(python3 - "$WORK/b" <<'PY'
import json, sys, difflib
d = json.load(open(sys.argv[1]))
rows = [dict(zip(d['changes']['columns'], r)) for r in d['changes']['rows']]
rows.sort(key=lambda r: r['version_no'])
s = [r.get('script') or '' for r in rows]
def changed(a, b):
    return [l for l in difflib.unified_diff(a.splitlines(), b.splitlines(), lineterm='', n=0) if l[:1] in '+-' and l[:3] not in ('---', '+++')]
out = [str(len(rows))] + ['|'.join(changed(s[i], s[i + 1])) for i in range(len(s) - 1)]
print(' ;; '.join(out))
PY
)
  [ "$R" = "3 ;; -    schedule => '5 4 * * *',|+    schedule => '10 4 * * *', ;; -    command  => \$cmd\$select 1\$cmd\$,|+    command  => \$cmd\$select 2\$cmd\$," ] || fail "G: the versions' diffs: $R"
  echo "G: OK"

  echo "--- H. the pages"
  WPORT=$((41000 + RANDOM % 9000))
  "$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$WPORT" -no-login >"$WORK/web-$V.log" 2>&1 & WEBPID=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$WPORT/api/health" >/dev/null 2>&1 && break; sleep 0.5; done
  rm -rf "$WORK/chrome"
  setsid chromium --headless=new --remote-debugging-port=0 --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank >"$WORK/chrome.log" 2>&1 & CHRPID=$!
  local CDP=
  for _ in $(seq 1 60); do
    [ -s "$WORK/chrome/DevToolsActivePort" ] && CDP=$(head -1 "$WORK/chrome/DevToolsActivePort")
    [ -n "$CDP" ] && curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5
  done
  [[ "$CDP" =~ ^[0-9]+$ ]] || fail "H: Chromium never answered: $(tail -3 "$WORK/chrome.log")"
  timeout 150 node "$WORK/page.mjs" "$CDP" "http://127.0.0.1:$WPORT" "$I" || fail "H: a check of the pages failed"
  kill "$CHRPID" "$WEBPID" 2>/dev/null; wait "$CHRPID" "$WEBPID" 2>/dev/null || true; CHRPID=; WEBPID=
  echo "H: OK"

  kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null || true; SRVPID=
  docker rm -f -v "$CT" >/dev/null; CT=
  echo "PostgreSQL $V: PASS (A-H)"
}

for V in $PGS; do run_major "$V"; done
echo "--- J. cleanup"
left=$(docker ps -a --format '{{.Names}}' | grep -c "^pgv161-.*-$SUF$" || true)
[ "$left" = 0 ] || fail "J: $left container(s) of this run left"
vleft=0; for v in $VOLS; do docker volume inspect "$v" >/dev/null 2>&1 && vleft=$((vleft + 1)); done
[ "$vleft" = 0 ] || fail "J: $vleft volume(s) of this run left"
echo "J: OK (0 containers and 0 of the run's $(echo $VOLS | wc -w) volumes left)"
echo "proof-pg-jobs-deadlocks: PASS (I, A-H on PostgreSQL $PGS, J)"
