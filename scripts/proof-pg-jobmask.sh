#!/usr/bin/env bash
# Proof that a PostgreSQL role's password (CREATE / ALTER ROLE and USER ... [ ENCRYPTED ] PASSWORD and a string
# constant, no '=') and a user mapping's password option inside a pg_cron or pgAgent job are stored masked (S16b;
# the rules of internal/jobmask, called by the jobs collection on pg_cron's command, pgAgent's step code and a run's
# command before the row, the version and the script are built), and that migration 0272 masks them in a store an
# older build wrote (section U, with PGVIGIL_OLD_SRC, a source tree of the build before the rule).
#
# Needs: docker, psql, pg_dump, python3, go at the repository root. It builds (once, kept for the next run) the image
# pgvigil-proof-pgcron:<PGVIGIL_PROOF_PG, default 16> (postgres:<major> with postgresql-<major>-cron and pgagent: the
# image proof-pg-jobs-deadlocks.sh builds) and starts one container with pg_cron preloaded, which holds the monitored
# database (postgres) and the repositories; the container and its volume are removed on every exit path.
#
# Each form is one job: pg_cron's scheduled for 1 January (never run) but rn1 (run once, then unscheduled), ag1 one
# pgAgent step (no pgAgent daemon: never run). Its secret is a token of its own (S16b<id><run number>). After one read
# of the collection jobs each token is looked for in pgvigil.jobs, job_runs, job_versions and a data-only dump of
# the repository; a keep row's command must be stored as sent. Each form PostgreSQL can run here is also run once
# inside a rolled-back transaction (a NOTE: which string constant forms PASSWORD takes on this major).
#
# Expected (written before the first run, on ac1d3abc's code, no rule for the form): FAIL - stored as read - for r1
# (PASSWORD '...'), r2 (WITH LOGIN ENCRYPTED PASSWORD '...' VALID UNTIL), r3 ($$...$$), r4 ($pw$...$pw$), r5
# (E'...\'...'), r6 (U&'...'), r7 (inside dblink_exec's string, its quotes doubled), r8 (CREATE USER MAPPING ...
# OPTIONS (password '...')), r9 (ALTER USER MAPPING ... OPTIONS (SET password '...')), rl (lower case), rn1 (a run's
# command in job_runs) and ag2 (a pgAgent step, $$...$$): 12 FAIL; ok for ag1 (a pgAgent step's PASSWORD '...': the
# collector's own SQL masks a step's code - maskSQL, internal/collect/columns.go - since before S16) and keep1-keep3
# (PASSWORD NULL with prose, a format() placeholder, a parameter); U: the same 12 FAIL and the dump row FAIL,
# keep1-keep3 unchanged by the migrate (ok): 'PROOF FAILED: 25'. After the rule: every row ok, 'PROOF OK'.
# The rule's review (expected written before its red run, on 5e367e0c's code with these rows): every masked row is
# also read exactly - the job's stored script holds the masked command (the masked file below) and is not the guard's
# text. This build's read: FAIL r10 (a user mapping's sslpassword), r11 (a comment before the value), r12 (E'..'
# inside dblink_exec's string), r13 (a backslash-escaped value inside E'..'), r14 (a password after a dollar body
# holding a lone quote), keep4 (EXECUTE 'ALTER ROLE .. PASSWORD ' || quote_literal(..)) and keep5 ('wrong password '
# || ..: the closing quote read as a value); every older row ok. U: FAIL r1, r3, r4, r5, r6, rl, rn1, ag1, ag2 (the
# migrate replaced the script whole, or for ag1 cut its tail after the mark: a mark right before the closing $cmd$ /
# $code$ read as a key or as a cut value; the masked command is read with its closing delimiter), r10-r14, keep4,
# keep5 and the dump row; ok r2, r7, r8, r9, keep1-keep3: 'PROOF FAILED: 24'. After the fix: every row ok.
set -euo pipefail
export PATH=$HOME/.local/share/mise/shims:$PATH
for t in docker psql pg_dump python3 go; do command -v $t >/dev/null || { echo "FAIL: $t missing" >&2; exit 1; }; done
[ -f go.mod ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
V=${PGVIGIL_PROOF_PG:-16}
SUF=$RANDOM; CT=pgvjm-pg-$SUF
WORK=$(mktemp -d); BIN=$WORK/pgvigil; OUT=$WORK/out
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() { local rc=$?; set +e; docker rm -f -v "$CT" >/dev/null 2>&1; rm -rf "$WORK"; exit $rc; }
trap cleanup EXIT INT TERM
echo "load: $(cut -d' ' -f1-3 /proc/loadavg) (shared box)"
if ! docker image inspect "pgvigil-proof-pgcron:$V" >/dev/null 2>&1; then
  printf 'FROM postgres:%s\nRUN apt-get update -qq && apt-get install -y -qq postgresql-%s-cron pgagent >/dev/null && rm -rf /var/lib/apt/lists/*\n' "$V" "$V" \
    | docker build -q -t "pgvigil-proof-pgcron:$V" - >/dev/null || fail "the image pgvigil-proof-pgcron:$V did not build"
fi
PW="pw$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf 'POSTGRES_PASSWORD=%s\n' "$PW" > "$WORK/env"; chmod 600 "$WORK/env"   # the password off the command line
PORT=$((21000 + RANDOM % 9000))
docker run -d --name "$CT" --env-file "$WORK/env" -p "127.0.0.1:$PORT:5432" "pgvigil-proof-pgcron:$V" \
  -c shared_preload_libraries=pg_cron -c cron.database_name=postgres >/dev/null
for _ in $(seq 1 60); do docker exec "$CT" pg_isready -q -U postgres 2>/dev/null && break; sleep 1; done
export PGPASSWORD=$PW
ADM="host=127.0.0.1 port=$PORT user=postgres"
sq() { psql "$ADM dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
for _ in $(seq 1 30); do sq "select 1" >/dev/null 2>&1 && break; sleep 1; done
sq "create extension pg_cron" >/dev/null
sq "create extension pgagent" >/dev/null
sq "create extension postgres_fdw" >/dev/null
sq "create role s16bapp login; create role s16brun login; create server s16bsrv foreign data wrapper postgres_fdw options (dbname 'postgres')" >/dev/null
echo "NOTE pg_cron $(sq "select extversion from pg_extension where extname = 'pg_cron'"), PostgreSQL $(sq "show server_version")"
sq "create database pgvigil_repo" >/dev/null
sq "create database pgvigil_repo_u" >/dev/null
export PGVIGIL_REPO_DSN="$ADM password=$PW dbname=pgvigil_repo" PGVIGIL_REPO_DSN_U="$ADM password=$PW dbname=pgvigil_repo_u" MON_DSN="$ADM password=$PW dbname=postgres"
NS=pgjm-$SUF
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: %s\n    dsn: env:MON_DSN\n' "$NS" > "$WORK/cfg.yaml"
sed 's/env:PGVIGIL_REPO_DSN$/env:PGVIGIL_REPO_DSN_U/' "$WORK/cfg.yaml" > "$WORK/cfg-u.yaml"
grep -q 'env:PGVIGIL_REPO_DSN_U' "$WORK/cfg-u.yaml" || fail "the U configuration"
q() { psql "$ADM dbname=pgvigil_repo" -XAt -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
qu() { psql "$ADM dbname=pgvigil_repo_u" -XAt -v ON_ERROR_STOP=1 -c "$1" </dev/null; }
go build -o "$BIN" ./cmd/pgvigil

# id ~~ class (leak: masked after the rule; keep: stored exactly as sent, its K16 token readable; run: run once) ~~
# kind (cron | agent) ~~ the command; @@SUF@@ is this run's number
cat > "$WORK/forms.txt" <<'FORMS'
r1 ~~ leak ~~ cron ~~ ALTER ROLE s16bapp PASSWORD 'S16br1@@SUF@@'
r2 ~~ leak ~~ cron ~~ ALTER ROLE s16bapp WITH LOGIN ENCRYPTED PASSWORD 'S16br2@@SUF@@' VALID UNTIL 'infinity'
r3 ~~ leak ~~ cron ~~ CREATE ROLE s16bnew3 LOGIN PASSWORD $$S16br3@@SUF@@$$
r4 ~~ leak ~~ cron ~~ CREATE USER s16bnew4 PASSWORD $pw$S16br4@@SUF@@'x$pw$
r5 ~~ leak ~~ cron ~~ ALTER USER s16bapp PASSWORD E'S16br5@@SUF@@\'x'
r6 ~~ leak ~~ cron ~~ ALTER ROLE s16bapp PASSWORD U&'S16br6@@SUF@@\0061'
r7 ~~ leak ~~ cron ~~ SELECT dblink_exec('dbname=postgres', 'ALTER ROLE s16bapp PASSWORD ''S16br7@@SUF@@''')
r8 ~~ leak ~~ cron ~~ CREATE USER MAPPING FOR s16bapp SERVER s16bsrv OPTIONS (user 's16bapp', password 'S16br8@@SUF@@')
r9 ~~ leak ~~ cron ~~ ALTER USER MAPPING FOR s16bapp SERVER s16bsrv OPTIONS (SET password 'S16br9@@SUF@@')
rl ~~ leak ~~ cron ~~ alter role s16bapp password 'S16brl@@SUF@@'
r10 ~~ leak ~~ cron ~~ CREATE USER MAPPING FOR s16bapp SERVER s16bsrv OPTIONS (user 's16bapp', sslpassword 'S16br10@@SUF@@')
r11 ~~ leak ~~ cron ~~ ALTER ROLE s16bapp PASSWORD /* new */ 'S16br11@@SUF@@'
r12 ~~ leak ~~ cron ~~ SELECT dblink_exec('dbname=postgres', 'ALTER ROLE s16bapp PASSWORD E''S16br12@@SUF@@''')
r13 ~~ leak ~~ cron ~~ DO $d$BEGIN EXECUTE E'ALTER ROLE s16bapp PASSWORD \'S16br13@@SUF@@\''; END$d$
r14 ~~ leak ~~ cron ~~ ALTER ROLE s16bapp PASSWORD $pw$x'y$pw$; ALTER ROLE s16bapp PASSWORD E'S16br14@@SUF@@'
rn1 ~~ run ~~ cron ~~ ALTER ROLE s16brun PASSWORD 'S16brn1@@SUF@@'
ag1 ~~ control ~~ agent ~~ ALTER ROLE s16bapp PASSWORD 'S16bag1@@SUF@@'
ag2 ~~ leak ~~ agent ~~ CREATE ROLE s16bnew5 LOGIN PASSWORD $$S16bag2@@SUF@@$$
keep1 ~~ keep ~~ cron ~~ ALTER ROLE s16bapp PASSWORD NULL; COMMENT ON ROLE s16bapp IS 'K16bk1@@SUF@@ reset the password monthly'
keep2 ~~ keep ~~ cron ~~ DO $d$BEGIN EXECUTE format('ALTER ROLE %I PASSWORD %L', 's16bapp', 'K16bk2@@SUF@@' || NULL); END$d$
keep3 ~~ keep ~~ cron ~~ PREPARE s16bp (text) AS SELECT 'K16bk3@@SUF@@' WHERE $1 = 'password'
keep4 ~~ keep ~~ cron ~~ DO $$BEGIN EXECUTE 'ALTER ROLE s16bapp PASSWORD ' || quote_literal('K16bk4@@SUF@@'); END$$
keep5 ~~ keep ~~ cron ~~ SELECT 'wrong password ' || 'K16bk5@@SUF@@'
FORMS
# each masked row's command as the store must hold it (in the job's script; the run's command for rn1 as well)
cat > "$WORK/masked.txt" <<'MASKED'
r1 ~~ ALTER ROLE s16bapp PASSWORD '<masked>'
r2 ~~ ALTER ROLE s16bapp WITH LOGIN ENCRYPTED PASSWORD '<masked>' VALID UNTIL 'infinity'
r3 ~~ CREATE ROLE s16bnew3 LOGIN PASSWORD '<masked>'
r4 ~~ CREATE USER s16bnew4 PASSWORD '<masked>'
r5 ~~ ALTER USER s16bapp PASSWORD '<masked>'
r6 ~~ ALTER ROLE s16bapp PASSWORD '<masked>'
r7 ~~ SELECT dblink_exec('dbname=postgres', 'ALTER ROLE s16bapp PASSWORD ''<masked>''')
r8 ~~ CREATE USER MAPPING FOR s16bapp SERVER s16bsrv OPTIONS (user 's16bapp', password '<masked>')
r9 ~~ ALTER USER MAPPING FOR s16bapp SERVER s16bsrv OPTIONS (SET password '<masked>')
rl ~~ alter role s16bapp password '<masked>'
r10 ~~ CREATE USER MAPPING FOR s16bapp SERVER s16bsrv OPTIONS (user 's16bapp', sslpassword '<masked>')
r11 ~~ ALTER ROLE s16bapp PASSWORD /* new */ '<masked>'
r12 ~~ SELECT dblink_exec('dbname=postgres', 'ALTER ROLE s16bapp PASSWORD ''<masked>''')
r13 ~~ DO $d$BEGIN EXECUTE E'ALTER ROLE s16bapp PASSWORD \'<masked>\''; END$d$
r14 ~~ ALTER ROLE s16bapp PASSWORD '<masked>'; ALTER ROLE s16bapp PASSWORD '<masked>'
rn1 ~~ ALTER ROLE s16brun PASSWORD '<masked>'
ag1 ~~ ALTER ROLE s16bapp PASSWORD '<masked>'
ag2 ~~ CREATE ROLE s16bnew5 LOGIN PASSWORD '<masked>'
MASKED
python3 -I - "$WORK/forms.txt" "$SUF" "$WORK" <<'PY'
import sys
forms, suf, work = sys.argv[1], sys.argv[2], sys.argv[3]
jobs, runs = [], []
for line in open(forms, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    fid, cls, kind, cmd = line.split(" ~~ ", 3)
    cmd = cmd.replace("@@SUF@@", suf)
    assert "$pgvjm$" not in cmd
    name = "s16b %s %s" % (fid, suf)
    if kind == "agent":
        jobs.append("WITH j AS (INSERT INTO pgagent.pga_job (jobjclid, jobname, jobenabled) VALUES (1, '%s', true) RETURNING jobid) "
                    "INSERT INTO pgagent.pga_jobstep (jstjobid, jstname, jstkind, jstdbname, jstonerror, jstcode) "
                    "SELECT jobid, 'one', 's', 'postgres', 'f', $pgvjm$%s$pgvjm$ FROM j;" % (name, cmd))
    else:
        sched = "2 seconds" if cls == "run" else "0 0 1 1 *"
        jobs.append("SELECT cron.schedule('%s', '%s', $pgvjm$%s$pgvjm$);" % (name, sched, cmd))
    # each form PostgreSQL can run here, once, rolled back (r7 needs dblink and a connection: not run; r9 after r8)
    if fid not in ("r7", "r12", "rn1", "ag1") and cls != "keep":
        pre = "CREATE USER MAPPING FOR s16bapp SERVER s16bsrv OPTIONS (user 's16bapp', password 'x'); " if fid == "r9" else ""
        runs.append((fid, "BEGIN; %s%s; ROLLBACK;" % (pre, cmd)))
open(work + "/jobs.sql", "w").write("\n".join(jobs) + "\n")
for fid, sql in runs:
    open(work + "/run-" + fid + ".sql", "w").write(sql + "\n")
open(work + "/runs.txt", "w").write("\n".join(f for f, _ in runs) + "\n")
PY
for fid in $(cat "$WORK/runs.txt"); do
  if r=$(psql "$ADM dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -f "$WORK/run-$fid.sql" 2>&1 </dev/null); then echo "NOTE PostgreSQL $V takes $fid"
  else echo "NOTE PostgreSQL $V refuses $fid: $(printf '%s' "$r" | tr '\n' ' ' | cut -c1-200)"; fi
done
psql "$ADM dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -f "$WORK/jobs.sql" >/dev/null </dev/null || fail "the jobs were not made"
N=$(sq "select (select count(*) from cron.job where jobname like 's16b % $SUF') + (select count(*) from pgagent.pga_job where jobname like 's16b % $SUF')")
[ "$N" = "$(grep -c ' ~~ ' "$WORK/forms.txt")" ] || fail "made $N jobs of $(grep -c ' ~~ ' "$WORK/forms.txt")"
# rn1 runs (every 2 s) until its first run succeeds, then moves to the yearly schedule - kept in cron.job, so the read
# finds the job as well as its run (an unscheduled job's runs are read, the job is not)
for _ in $(seq 1 45); do [ "$(sq "select count(*) from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 's16b rn1 $SUF' and d.status = 'succeeded'")" -ge 1 ] && break; sleep 1; done
sq "select cron.alter_job((select jobid from cron.job where jobname = 's16b rn1 $SUF'), schedule := '0 0 1 1 *')" >/dev/null
RUNS=$(sq "select count(*) from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 's16b rn1 $SUF'")
[ "$RUNS" -ge 1 ] || fail "rn1 did not run (pg_cron's seconds schedule)"

# count of a token in the store of $1 (q or qu): jobs, job_runs, job_versions
counts() { local f=$1 tok=$2
  echo "jobs $($f "select count(*) from pgvigil.jobs j where j::text like '%$tok%'"), job_runs $($f "select count(*) from pgvigil.job_runs r where r::text like '%$tok%'"), job_versions $($f "select count(*) from pgvigil.job_versions v where v::text like '%$tok%'")"; }
none() { [[ $1 == "jobs 0, job_runs 0, job_versions 0" ]]; }
# the stored command of a job ($1 q or qu)
cmd_of() { $1 "select command from pgvigil.jobs where job_name = 's16b $2 $SUF' order by snapshot_at desc limit 1"; }
# how many of a job's versions hold its masked command ($3) and the delimiter the collector's script closes it with
# ($4: $cmd$, for pg_cron, $code$); for pgAgent: a tail cut after the command fails) in a script that is not the
# guard's text ($1 q or qu)
hasmasked() { local db=pgvigil_repo; [ "$1" = qu ] && db=pgvigil_repo_u
  printf '%s\n' "select count(*) from pgvigil.job_versions where job_name = 's16b $2 $SUF' and position(:'m' in script) > 0 and script not like '%<masked: an older build%';" \
    | psql "$ADM dbname=$db" -XAtq -v ON_ERROR_STOP=1 -v m="$3$4" -f -; }
grade() { local f=$1 dump=$2 tag=$3 line fid rest cls kind sent tok c dm m sc
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fid=${line%% ~~ *}; rest=${line#* ~~ }; cls=${rest%% ~~ *}; rest=${rest#* ~~ }; kind=${rest%% ~~ *}; sent=${rest#* ~~ }; sent=${sent//@@SUF@@/$SUF}
    case $cls in
      keep)
        tok=$(printf '%s\n' "$sent" | grep -o "K16bk[0-9]$SUF")
        c=$(cmd_of "$f" "$fid")
        if [ "$c" = "$sent" ] && [ "$($f "select count(*) from pgvigil.job_versions where job_name = 's16b $fid $SUF' and script like '%$tok%'")" -ge 1 ]; then echo "ok $tag$fid (keep): stored as sent, readable in the script: $c"
        else echo "FAIL $tag$fid (keep): stored [$c], sent [$sent]"; BAD=$((BAD+1)); fi ;;
      *)
        tok=S16b$fid$SUF; c=$(counts "$f" "$tok"); dm=$(grep -c "$tok" "$dump" || true)
        [ "$($f "select count(*) from pgvigil.job_versions where job_name = 's16b $fid $SUF'")" -ge 1 ] || { echo "FAIL $tag$fid: the job was not read (no version)"; BAD=$((BAD+1)); continue; }
        m=$(grep -m1 "^$fid ~~ " "$WORK/masked.txt" || true); m=${m#* ~~ }
        [ -n "$m" ] || fail "no masked text for $fid"
        if [ "$kind" = agent ]; then sc=$(hasmasked "$f" "$fid" "$m" '$code$);'); else sc=$(hasmasked "$f" "$fid" "$m" '$cmd$,'); fi
        if none "$c" && [ "$dm" = 0 ] && [ "$sc" -ge 1 ]; then echo "ok $tag$fid ($cls, $kind): masked ($c, dump 0), the script reads it masked"
        else echo "FAIL $tag$fid ($cls, $kind): $c, dump $dm, scripts holding it masked $sc: $(cmd_of "$f" "$fid") | $($f "select left(script, 160) from pgvigil.job_versions where job_name = 's16b $fid $SUF' order by version_no desc limit 1" | tr '\n' ' ')"; BAD=$((BAD+1)); fi ;;
    esac
  done < "$WORK/forms.txt"; }

BAD=0
"$BIN" migrate -config "$WORK/cfg.yaml" >/dev/null
"$BIN" collect -config "$WORK/cfg.yaml" -once jobs -instance "$NS" >"$OUT" 2>&1 || { cat "$OUT"; fail "collect jobs"; }
[ "$(q "select count(*) from pgvigil.job_runs r join pgvigil.jobs j using (instance_id, scheduler, job_id) where j.job_name = 's16b rn1 $SUF'")" -ge 1 ] || fail "rn1's run was not read"
pg_dump "$ADM dbname=pgvigil_repo" --data-only -n pgvigil > "$WORK/dump.sql" 2>"$WORK/dump.err" || { cat "$WORK/dump.err"; fail "pg_dump of the repository"; }
grade q "$WORK/dump.sql" ""

# U: the same jobs read by the build before the rule into a repository of their own, then this build's migrate
if [ -z "${PGVIGIL_OLD_SRC:-}" ]; then
  echo "NOT PROVEN U: no older build's source given (PGVIGIL_OLD_SRC)"
else
  OLDBIN=$WORK/pgvigil-old; ( cd "$PGVIGIL_OLD_SRC" && go build -o "$OLDBIN" ./cmd/pgvigil ) || fail "the older build"
  "$OLDBIN" migrate -config "$WORK/cfg-u.yaml" >/dev/null
  "$OLDBIN" collect -config "$WORK/cfg-u.yaml" -once jobs -instance "$NS" >"$OUT" 2>&1 || { cat "$OUT"; fail "the older build's collect"; }
  [ "$(qu "select count(*) from pgvigil.jobs where command like '%S16br1$SUF%'")" -ge 1 ] || fail "U: the older build masked r1: the U rows would prove nothing"
  # the older build (one before 0272) wrote the store; this build's migrate runs 0272 over its rows
  [ "$(qu "select count(*) from pgvigil.schema_version where version = '0272_job_text_masked_again.sql'")" = 0 ] || fail "U: the older build already ran 0272 (give a source tree from before it)"
  "$BIN" migrate -config "$WORK/cfg-u.yaml" >"$OUT" 2>&1 || { cat "$OUT"; fail "this build's migrate over the older store"; }
  pg_dump "$ADM dbname=pgvigil_repo_u" --data-only -n pgvigil > "$WORK/dump-u.sql" 2>"$WORK/dump.err" || { cat "$WORK/dump.err"; fail "pg_dump of the U repository"; }
  grade qu "$WORK/dump-u.sql" "U "
  LEFT=$(grep -o "S16b[a-z0-9]*$SUF" "$WORK/dump-u.sql" | sort -u | tr '\n' ' ' || true)
  if [ -z "$LEFT" ]; then echo "ok U no form's secret anywhere in a dump of the whole repository after the migrate"
  else echo "FAIL U the dump of the whole repository after the migrate still holds: $LEFT"; BAD=$((BAD+1)); fi
fi
if [ "$BAD" = 0 ]; then echo "PROOF OK"; else echo "PROOF FAILED: $BAD"; exit 1; fi
