#!/usr/bin/env bash
# Proof of the jobs collection. Two halves: (1) on a server without pg_cron or pgAgent the
# collection is skipped with its reason, not failed; (2) the repository side is proven with a
# crafted payload (two jobs, three runs: one failed, one running, one succeeded) through
# import_jobs, then a second import that ends the running one - because pg_cron needs
# shared_preload_libraries and a restart, which a throwaway server may not offer.
#   PGVIGIL_REPO_DSN  repository (owner connection);  ADMIN_DSN  connection to the monitored server
# Expected: collection_dates jobs = skipped with "neither pg_cron nor pgAgent" when neither is
# installed (or ok when one is); after the crafted imports: jobs = 2, job_runs = 3, job_failures = 1,
# job_running = 0 (the running run ended in the second import), the ended run has an end_time.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}" "${ADMIN_DSN:?}"
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: proof-jobs\n    dsn: env:ADMIN_DSN\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once jobs
iid=$(q "select instance_id from pgvigil.instances where name='proof-jobs'")
st=$(q "select status || coalesce(': ' || note, '') from pgvigil.collection_dates where instance_id=$iid and collection='jobs'")
echo "live collection: $st"
has=$(psql "$ADMIN_DSN" -XAt -c "select (select count(*) from pg_extension where extname='pg_cron') + (select count(*) from pg_namespace where nspname='pgagent')")
if [ "$has" = "0" ]; then [[ "$st" == skipped:*"neither pg_cron nor pgAgent"* ]] || fail "expected a skip with the reason, got '$st'"; else [[ "$st" == ok* ]] || fail "expected ok with a scheduler installed, got '$st'"; fi

# repository side with a crafted payload
q "delete from pgvigil.job_runs where instance_id=$iid; delete from pgvigil.jobs where instance_id=$iid" >/dev/null
q "select pgvigil.import_jobs($iid, now() - interval '2 minutes', '[
 {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"job_name\":\"nightly-vacuum\",\"schedule\":\"0 3 * * *\",\"command\":\"VACUUM ANALYZE\",\"datname\":\"app\",\"run_as\":\"postgres\",\"active\":true},
 {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":2,\"job_name\":\"purge\",\"schedule\":\"*/5 * * * *\",\"command\":\"SELECT purge()\",\"datname\":\"app\",\"run_as\":\"app\",\"active\":true},
 {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"run_id\":101,\"status\":\"failed\",\"return_message\":\"ERROR: relation x does not exist\",\"start_time\":\"$(date -u -d '-30 min' +%FT%TZ)\",\"end_time\":\"$(date -u -d '-29 min' +%FT%TZ)\",\"duration_secs\":60},
 {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":2,\"run_id\":201,\"status\":\"succeeded\",\"return_message\":\"1 row\",\"start_time\":\"$(date -u -d '-10 min' +%FT%TZ)\",\"end_time\":\"$(date -u -d '-10 min' +%FT%TZ)\",\"duration_secs\":0.2},
 {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":2,\"run_id\":202,\"status\":\"running\",\"start_time\":\"$(date -u -d '-1 min' +%FT%TZ)\"}
]'::jsonb)" >/dev/null
r1=$(q "select (select count(*) from pgvigil.jobs where instance_id=$iid) || '/' || (select count(*) from pgvigil.job_runs where instance_id=$iid) || '/' || (select count(*) from pgvigil.job_failures where instance_id=$iid) || '/' || (select count(*) from pgvigil.job_running where instance_id=$iid)")
[ "$r1" = "2/3/1/1" ] || fail "after import 1 expected jobs/runs/failures/running = 2/3/1/1, got $r1"
q "select pgvigil.import_jobs($iid, now(), '[
 {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":1,\"job_name\":\"nightly-vacuum\",\"schedule\":\"0 3 * * *\",\"command\":\"VACUUM ANALYZE\",\"datname\":\"app\",\"run_as\":\"postgres\",\"active\":true},
 {\"kind\":\"job\",\"scheduler\":\"pg_cron\",\"job_id\":2,\"job_name\":\"purge\",\"schedule\":\"*/5 * * * *\",\"command\":\"SELECT purge()\",\"datname\":\"app\",\"run_as\":\"app\",\"active\":true},
 {\"kind\":\"run\",\"scheduler\":\"pg_cron\",\"job_id\":2,\"run_id\":202,\"status\":\"succeeded\",\"return_message\":\"1 row\",\"start_time\":\"$(date -u -d '-1 min' +%FT%TZ)\",\"end_time\":\"$(date -u +%FT%TZ)\",\"duration_secs\":58}
]'::jsonb)" >/dev/null
r2=$(q "select (select count(*) from pgvigil.jobs where instance_id=$iid) || '/' || (select count(*) from pgvigil.job_runs where instance_id=$iid) || '/' || (select count(*) from pgvigil.job_failures where instance_id=$iid) || '/' || (select count(*) from pgvigil.job_running where instance_id=$iid)")
[ "$r2" = "2/3/1/0" ] || fail "after import 2 expected 2/3/1/0, got $r2"
[ "$(q "select end_time is not null from pgvigil.job_runs where instance_id=$iid and run_id=202")" = "t" ] || fail "run 202 kept no end_time"
echo "proof-jobs: OK (live: $st; crafted: 2 jobs, 3 runs, 1 failure, running ended)"
