#!/usr/bin/env bash
# Proof of the actions door (migration 0028, internal/actions, the handlers of internal/web/actions.go) on
# the sandbox; the sandbox server is both the repository and the monitored server.
#   PGVIGIL_REPO_DSN  repository owner connection (a superuser on the sandbox: its own session is the
#                     superuser target). Creates and drops four logins and two instances with a random suffix.
# The handler's code path runs in the Go test TestActionsProof (internal/web/actions_test.go): the real
# Actions handlers behind a live UI session, the real audit pool on a collector login, the real checks
# through a pg_monitor login and the signals through a login holding pg_signal_backend alone.
# Expected: migrate applies 0028; `pgvigil roles` prints CREATE ROLE pgvigil_actions and GRANT
# pg_signal_backend; a config with an inline actions_dsn is refused ("env:NAME or file:/path"); the
# collector login may EXECUTE import_actions_log and may not UPDATE or DELETE actions_log; through the
# handlers: a POST without the X-Pgvigil header 403 and not logged, a sleeping session of an application
# login cancelled (200 done, its pg_sleep ends with 57014 and the session stays), another terminated (200
# done, its connection ends 57P01), the superuser's own session refused (409 "superuser"), a stale pid (the
# backend_start of the row shown one microsecond off) refused (409 "reused"), a typed confirmation that is
# not the pid refused (409), an instance without actions_dsn refused (409 "no actions_dsn"), GET
# /api/actions/log enabled on the door instance with the superuser listed and disabled with the reason on
# the other; actions_log then holds exactly 6 rows for the two instances: door instance done 2 / refused 3,
# the other refused 1, every row with the UI user, the reason and a detail.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
R=$RANDOM$RANDOM
COL="pgvigil_it_col_$R"; MON="pgvigil_it_mon_$R"; ACT="pgvigil_it_act_$R"; APP="pgvigil_it_app_$R"; PW="pw$RANDOM$RANDOM"
I1="proof-actions-$R"; I2="proof-actions-nodoor-$R"
CFG=$(mktemp); CFG2=$(mktemp)
q() { psql "$PGVIGIL_REPO_DSN" -XAt -c "$1"; }
cleanup() {
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "delete from pgvigil.actions_log where instance_name in ('$I1','$I2')" \
    -c "delete from pgvigil.instances where name in ('$I1','$I2')" >/dev/null 2>&1 || true
  for r in $COL $MON $ACT $APP; do psql "$PGVIGIL_REPO_DSN" -XAtq -c "drop role if exists $r" >/dev/null 2>&1 || true; done
  rm -f "$CFG" "$CFG2"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
HOST=$(q "select coalesce(host(inet_server_addr()),'localhost')")
DBPORT=$(q "select inet_server_port()")
DB=$(q "select current_database()")
dsn() { echo "host=$HOST port=$DBPORT user=$1 password=$PW dbname=$DB sslmode=disable"; }

printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null
[[ $(q "select count(*) from pgvigil.schema_version where version = '0028_actions.sql'") == 1 ]] || fail "0028 not applied"
echo "ok: migrate applied 0028"

out=$("$BIN" roles)
grep -q 'CREATE ROLE pgvigil_actions LOGIN' <<<"$out" || fail "roles does not print CREATE ROLE pgvigil_actions"
grep -q 'GRANT pg_signal_backend TO pgvigil_actions' <<<"$out" || fail "roles does not print the GRANT pg_signal_backend"
echo "ok: roles prints the actions login and its grant"

printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: x\n    dsn: env:X\n    actions_dsn: "host=h user=u password=p"\n' > "$CFG2"
if out=$("$BIN" migrate -config "$CFG2" 2>&1); then fail "an inline actions_dsn was accepted"; fi
[[ "$out" == *"env:NAME or file:/path"* ]] || fail "the inline actions_dsn refusal does not say why: $out"
echo "ok: an inline actions_dsn is refused"

psql "$PGVIGIL_REPO_DSN" -XAtq \
  -c "create role $COL login password '$PW' in role pgvigil_collector" \
  -c "create role $MON login password '$PW' in role pg_monitor" \
  -c "create role $ACT login password '$PW' nosuperuser in role pg_signal_backend" \
  -c "create role $APP login password '$PW'" \
  -c "select pgvigil.ensure_instance('$I1', 'onprem', '18', 180000, false, '{}')" \
  -c "select pgvigil.ensure_instance('$I2', 'onprem', '18', 180000, false, '{}')" >/dev/null

[[ $(psql "$(dsn "$COL")" -XAt -c "select has_function_privilege('pgvigil.import_actions_log(int, timestamptz, jsonb)', 'EXECUTE')") == t ]] \
  || fail "the collector login may not call import_actions_log"
out=$(psql "$(dsn "$COL")" -XAt -c "delete from pgvigil.actions_log" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "the collector login could delete from actions_log: $out"
out=$(psql "$(dsn "$COL")" -XAt -c "update pgvigil.actions_log set reason = 'x'" 2>&1 || true)
[[ "$out" == *"permission denied"* ]] || fail "the collector login could update actions_log: $out"
echo "ok: the collector login writes only through import_actions_log"

export PGVIGIL_ACTIONS_PROOF=1 ACTIONS_AUDIT_DSN="$(dsn "$COL")" ACTIONS_MONITOR_DSN="$(dsn "$MON")" \
  ACTIONS_ACTIONS_DSN="$(dsn "$ACT")" ACTIONS_APP_DSN="$(dsn "$APP")" ACTIONS_INSTANCE="$I1" ACTIONS_INSTANCE_NODOOR="$I2"
GOOUT=$(go test -count=1 -run 'TestActionsProof$' -v ./internal/web/ 2>&1) || { echo "$GOOUT" >&2; fail "TestActionsProof failed"; }
grep -q -- '--- PASS: TestActionsProof' <<<"$GOOUT" || { echo "$GOOUT" >&2; fail "TestActionsProof did not run (skipped?)"; }
grep -E 'actions_test.go:[0-9]+: ok:' <<<"$GOOUT" | sed 's/^ *actions_test.go:[0-9]*: //'

got=$(q "select string_agg(n || ':' || outcome || '=' || c, ' ' order by n, outcome) from (
           select case instance_name when '$I1' then 'door' else 'nodoor' end n, outcome, count(*) c
             from pgvigil.actions_log where instance_name in ('$I1','$I2') group by 1, 2) x")
[[ "$got" == "door:done=2 door:refused=3 nodoor:refused=1" ]] || fail "actions_log holds '$got', expected 'door:done=2 door:refused=3 nodoor:refused=1'"
bad=$(q "select count(*) from pgvigil.actions_log where instance_name in ('$I1','$I2') and (ui_user = '' or reason = '' or detail is null)")
[[ "$bad" == 0 ]] || fail "$bad audit rows miss the user, the reason or the detail"
echo "ok: actions_log holds every attempt ($got)"
echo "PASS: proof-actions"
