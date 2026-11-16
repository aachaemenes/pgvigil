#!/usr/bin/env bash
# Proof of task 403a (migration 0154, internal/alerts digest.go / rules.go / alerts.go, internal/web/q_alert_scope.go):
# windows, the one hold test, the daily digest, tag lists, rule kinds, the baseline, flapping, the findings history and
# a channel's checks, on a throwaway repository. Nothing leaves the machine (a file drop in the proof's own folder).
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 14+ cluster as a superuser. The proof makes two
#                      repository databases and three logins, all named pgvigil_s2scope_*_<random>, and drops them at
#                      the end. Not dropped: the cluster-wide group roles `pgvigil migrate` makes (pgvigil_collector,
#                      pgvigil_reader, pgvigil_alerter, pgvigil_auth).
#   The proof builds two binaries from a copy of this tree (go build): BIN with scripts/proof-alert-scope-wiring.patch
#   applied (the lead's lines in 0190 and web.go; skipped when the tree already holds them), and BIN0, the same tree
#   without 0154, for part M's second store. A tree that holds the wiring in a join's own words (the j16 join: POST
#   /api/alertwindows through s.post, 0300 re-creating alert_due whole after 0154; one line of each of the patch's 12
#   hunks is looked for) builds BIN as it is and no BIN0: part M's store 2 is then NOT PROVEN, because such a tree
#   without 0154 is not the unwired tree and no store meets 0154 after the join file (both arrive with v0.4.0).
#   Needs: psql, curl, python3, ss, go, tar, git (git apply only).
#
# Expected (written before the first run; red first: on the base 6178b52 the build has no 0154 and part M fails):
#  M. migration order (the lead 22:4x: until v0.4.0 the join edits 0190 in place; a store already at 0190 is rebuilt or
#     has 0190's functions re-created by hand at the join). Store 1, migrated fresh by BIN (the wiring applied to its
#     tree): 0154 applied BEFORE 0190 (schema_version.applied_at); alert_due's definition calls alert_hold and
#     alert_checks_match and no longer ack_hold; purge's names findings_history and greatest(p_days, 90). Store 2,
#     migrated by BIN0 (no 0154), then by BIN: 0154 applies AFTER 0190 without an error and the store reads; its
#     alert_due is still 0190's unwired one (no alert_hold), which is why such a store is rebuilt at the join. On both:
#     alert_hold(...) on a key nothing holds is NULL; alert_rule_findings has op_family; alert_findings and
#     alert_rules_effective answer; the index alert_rules_live_uq is gone and alert_rules_live_family_uq stands.
#  R. the role contract (store 1). A login IN ROLE pgvigil_collector may EXECUTE import_alert_window and is refused
#     INSERT on alert_windows. A login IN ROLE pgvigil_alerter may INSERT into alert_held, digest_log, findings_history
#     (has_table_privilege) and runs findings_history_run (an integer back). A login IN ROLE pgvigil_reader may INSERT
#     into none of alert_held, digest_log, findings_history.
#  T. tag lists. alert_tags_match:
#     - '{env:prod,env:stage,app:billing}' against '{env:prod,app:billing}' t;
#     - '{env:prod,app:billing}' against '{env:prod}' f;
#     - '{Env:prod}' against '{env:prod}' t (keys without case);
#     - '{env:Prod}' against '{env:prod}' f (values with case);
#     - '{}' against anything f.
#     alert_scope_norm('{ Env:prod , env:prod, app:x}') = '{app:x,env:prod}'.
#     alert_scope_text('{env:prod,env:stage,app:billing}') = 'app:billing AND (env:prod OR env:stage)'.
#  Z. time, at fixed instants (America/Chicago). A Monday window 22:00-06:00:
#     - holds at Mon 23:30 and Tue 05:59 local;
#     - not at Tue 06:00, nor at Sun 23:30 (Sunday not in it).
#     Spring forward, 2026-03-08: a Sunday window 02:00-03:00 holds at none of 07:00, 07:30, 08:00, 08:30 UTC (the
#     skipped hour), while a Sunday window 01:00-04:00 holds at 07:30 UTC (01:30 CST) and 08:30 UTC (03:30 CDT) - the
#     zone is read (review M6). Fall back, 2026-11-01: a Sunday window 01:00-02:00 holds at 06:30 UTC (01:30 CDT) AND at
#     07:30 UTC (01:30 CST). A whole day 00:00-24:00 holds at 23:59:30 (review M5).
#     digest_due at chosen times (a channel with digest_hour 3 UTC): owed once at 06:00 with no digest (a restart across
#     the hour); none once it is recorded; none at 02:00 the next day; owed at 05:00 the next day, since the last one.
#     digest_hour_at:
#     - 2026-03-08 09:00 UTC, hour 2 = 2026-03-08 08:00 UTC (02:00 is skipped: 03:00 CDT);
#     - 2026-03-08 07:30 UTC, hour 2 = 2026-03-07 08:00 UTC (yesterday's 02:00 CST).
#     alert_rule_hour_at 2026-11-02 15:45 UTC = 15:00 UTC (09:45 CST). The repeated hour of 2026-11-01 (06:30 and 07:30
#     UTC) is printed, not graded: PostgreSQL reads an ambiguous local time one way for both, so the baseline's cache
#     keeps one key for the two passes of that hour (a cache key only: the samples are read by instant).
#  C. checks. alert_checks_match:
#     - '{backups}' against source 'Backups' t;
#     - '{backups}' against 'blocking' / setting 'x' f;
#     - '{}' against anything t;
#     - '{x}' against setting 'X' t.
#  W. the window write door (serve with BIN). POST /api/alertwindows without a session 401; with a session and no
#     X-Pgvigil header 403; with both, 400 for each of: action 'pause', weekday 8, start 22:00 = end 22:00, zone
#     'Mars/Base', ceiling 'critical' on a digest, a ceiling on a mute, no scope and no from_rule_id. None of the nine
#     leaves a row in alert_windows or alert_window_log. A request the store refuses (from_rule_id of an ended rule)
#     answers 409 'no live rule' with one refused log row. add 200 (a window id); edit 200 (a new id; the old row ended
#     by the proof user, the new one replaces it); end 200; end again 409 'already ended'. GET /api/alertscope?part=
#     windows lists both rows.
#  H. the hold test (store 1, functions called at chosen times, no sends). One seeded instance (tags env:proofh,
#     app:h). A finding key K of it, source 'alert rule', severity warning.
#     - a live ack mute on it plus a window blackout covering now: blackout via window;
#     - an ack blackout plus a window blackout: blackout via ack;
#     - a window mute plus a digest window: mute;
#     - a digest window alone: digest via window; with severity critical: NULL;
#     - a fleet window against source 'pgvigil repository': NULL;
#     - a tags window (env:proofh AND app:h) matches; (env:proofh AND app:other) does not.
#     Digest holds only on a channel with a digest (alert_hold's p_digest): the same digest window on a channel without
#     one: NULL (review 20261114-230812 blocker 1).
#     Carry-over: an alert_held digest row of K on channel c, every window ended:
#     - the hold is 'digest' via carry;
#     - with an open alert_state row of (c, K): NULL;
#     - last_at 20 min old but missing_since NULL (the sender away: quiet hours, a back-off): still carried (review H2);
#     - missing_since 20 min old (the finding gone longer than clear_after): NULL.
#  K. rule kinds (seeded activity_summary samples, alert_rules_run at chosen times):
#     - a threshold rule (idle_in_txn above 3) and a rises rule (rises by more than 4, for 0 min) on one metric and
#       scope both live: two alert_rule_state rows (threshold, rise). A jump 2 -> 8: both fire, two findings, the rise
#       finding's value 'rises 4 between two samples for 0 min; last rise 6'. The threshold finding's value is 0085's
#       form 'above 3 for 0 min; last sample 8';
#     - a tags rule (env:proofh) above 100 overrides the fleet rule of its kind on the seeded instance:
#       alert_rule_overrides says (fleet rule, by the tags rule, 1);
#     - baseline (America/Chicago, band 20, warning 5), 7 days of the hour at 10, now 11: ok (11 < 12 = the greater of
#       5 and 10 x 1.2);
#     - the same with 6 days: warning, its detail 'no baseline yet (6 of 7 days)';
#     - 7 days at 0, now 3: ok; now 6: warning.
#  F. flapping (a rule above 3 for 0 min, ignore_flapping false; 12 runs a minute apart):
#     - samples 8 8 0 0 8 8 0 0 8 8 0 0: 5 changes in 11, ratio 0.45, flapping_since set at the 12th run;
#     - an alert_state row sent on channel c after the mark: alert_hold of the finding is 'flapping';
#     - 12 more steady runs at 8: the mark drops (NULL);
#     - the same alternation under a rule with ignore_flapping: never marked.
#  Y. history (findings_history_run at chosen times on the seeded rule finding; the rows of the seeded instance only):
#     - opened: 1 'open' row;
#     - its severity changed: 1 'severity' row;
#     - 59 min later: no row; 61 min later: 1 'sample' row (with metric_value);
#     - gone: 1 'close' row.
#     The history rows = the changes plus the samples (4); findings_history_last holds none of its keys after the close.
#  D. the digest, by real passes of BIN (the wiring applied). A file channel 'dig' with digest_hour = the current UTC
#     hour (timezone UTC), a channel 'drop' with no digest_hour, a fleet digest window covering now (ceiling warning),
#     and a rule finding at warning on the seeded instance:
#     - pass 1: 'drop' gets the firing (no digest: the window holds nothing there, review blocker 1); 'dig' gets no
#       firing and one digest file (one group naming the instance); digest_log sent; alert_held holds dig's row;
#     - pass 2: no second digest, no firing on dig;
#     - the window ended, pass 3: no firing on dig (the carry-over);
#     - the finding cleared, passes 4 and 5: no resolved file on dig;
#     - a critical finding while a new digest window covers now: a critical file on dig at once;
#     - a second channel 'dig2' with digest_hour now and nothing held: digest_log 'empty', no file in its drop;
#     - a mute window, then a blackout window, over a standing finding: alert_mark logs a 'mute' and a 'blackout' row
#       for 'drop' (the held-sends log per kind, review M7).
#  A pass's summary line must not say 'findings history not written' or 'digests not read'.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
: "${PGVIGIL_ADMIN_DSN:?}"
SUF=$RANDOM
REPO=pgvigil_s2scope_$SUF; REPO2=pgvigil_s2scope_m_$SUF
COL=pgvigil_s2scope_col_$SUF; ALR=pgvigil_s2scope_alr_$SUF; RDR=pgvigil_s2scope_rdr_$SUF
PW=p$RANDOM$RANDOM$RANDOM; UIUSER=proofuser; UIPW=ui$RANDOM$RANDOM$RANDOM
INSTH=proof-scope-h-$SUF
WORK=$(mktemp -d); SRV=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" \
    -c "drop database if exists $REPO2 with (force)" -c "drop role if exists $COL" -c "drop role if exists $ALR" \
    -c "drop role if exists $RDR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in psql curl python3 ss go tar git; do command -v $t >/dev/null || fail "$t is not on this machine"; done
# the digest hour below is the current one: never start in the last minutes of an hour
while (( $(date -u +%-M) >= 50 )); do echo "waiting for the hour to turn (UTC $(date -u +%H:%M))"; sleep 60; done
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -E "(^|[:\]])$p$" >/dev/null || { echo "$p"; return; }
  done
  fail "no free port"
}

# ---- the two binaries ------------------------------------------------------------------------------------------------
TREE=$WORK/tree; TREE0=$WORK/tree0; mkdir -p "$TREE" "$TREE0"
tar --exclude=./.git --exclude=./web/node_modules --exclude=./bin -cf - . | tar -xf - -C "$TREE"
(cd "$TREE" && tar -cf - .) | tar -xf - -C "$TREE0"   # BIN0: the tree as the branch holds it (unwired), without 0154
rm -f "$TREE0/internal/repo/sql/0154_alert_scope.sql"
# joined_wiring <tree>: the patch's 12 hunks in a join's own words (the j16 join's B24F-JOIN-WIRING routes POST
# /api/alertwindows through s.post, so the patch neither applies nor reverses there): one line of each hunk, as text
joined_wiring() { local f s
  while read -r f s; do grep -qF -- "$s" "$1/$f" || return 1; done <<'EOF'
cmd/pgvigil/report.go "page_instance_reads": true, "slack_actions": true,
cmd/pgvigil/report.go "team_id": true, "enterprise_id": true, "signing_secret": true, "users": true,
cmd/pgvigil/serve.go // task 403b K5: the Slack door (doors.slack_actions and slack_apps: in the file), off by default.
docs/mcp.md | `alert_history` | `instance`, `from`, `to`, `hours` |
internal/config/pagedoor.go SlackActions bool `yaml:"slack_actions"`
internal/mcp/applications_test.go {"alert_history", `{"instance":"beta","hours":48}`}, // task 403b
internal/mcp/mcp_test.go if len(list) != 10 { // task 403b: alert_history beside the nine
internal/mcp/tools.go }, alertTools()...) // task 403b: alert_history (tools_alerts.go)
internal/web/q_alert_rules.go AND o.op_family = e.op_family   -- task 403a: rules of another kind work beside it, they are not overridden
internal/web/web.go api.HandleFunc("GET /api/alertscope", s.AlertScope)
internal/web/web.go s.post(api, "POST /api/alertwindows", needOperator, s.AlertWindowWrite)
internal/web/web.go mux.HandleFunc("POST /api/slack/actions", s.slackActions)
EOF
}
JOINED=
if (cd "$TREE" && git apply --check "$ROOT/scripts/proof-alert-scope-wiring.patch" 2>/dev/null); then
  (cd "$TREE" && git apply "$ROOT/scripts/proof-alert-scope-wiring.patch") || fail "the wiring patch"
  ok "wiring patch applied to the build's copy"
elif (cd "$TREE" && git apply -R --check "$ROOT/scripts/proof-alert-scope-wiring.patch" 2>/dev/null); then
  ok "the tree already holds the wiring"
elif joined_wiring "$TREE"; then
  JOINED=1; ok "the tree holds the wiring in a join's own words (a line of each of the patch's 12 hunks found)"
else
  fail "the wiring patch neither applies nor is applied"
fi
BIN=$WORK/pgvigil; BIN0=$WORK/pgvigil0
(cd "$TREE" && go build -o "$BIN" ./cmd/pgvigil) || fail "go build"
if [[ -z $JOINED ]]; then (cd "$TREE0" && go build -o "$BIN0" ./cmd/pgvigil) || fail "go build (no 0154)"; fi

# ---- M: migration order ------------------------------------------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" -c "create database $REPO2" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO" PGVIGIL_REPO2_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO2"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
q2() { psql "$PGVIGIL_REPO2_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
mkdir -p "$WORK/drop" "$WORK/dig" "$WORK/dig2"
HOUR=$(date -u +%-H)
cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: drop, kind: file, min_severity: warning, clear_after: 0, instances: [$INSTH], file: {dir: $WORK/drop}}
  - {name: dig, kind: file, min_severity: warning, clear_after: 0, digest_hour: $HOUR, timezone: UTC, instances: [$INSTH], file: {dir: $WORK/dig}}
  - {name: dig2, kind: file, min_severity: warning, clear_after: 0, digest_hour: $HOUR, timezone: UTC, instances: [nobody-$SUF], file: {dir: $WORK/dig2}}
EOF
printf 'repository:\n  dsn: env:PGVIGIL_REPO2_DSN\n' > "$WORK/cfg2.yaml"
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" >"$WORK/m1.log" 2>&1 || fail "migrate store 1: $(tail -3 "$WORK/m1.log")"
order() { "$1" "select string_agg(version, ' ' ORDER BY applied_at, version) FROM pgvigil.schema_version WHERE version IN ('0154_alert_scope.sql', '0190_join_release2.sql')"; }
[[ $(order q) == "0154_alert_scope.sql 0190_join_release2.sql" ]] || fail "M: store 1's order: $(order q)"
fdef() { "$1" "select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pgvigil' and p.proname = '$2'"; }
d=$(fdef q alert_due)
[[ $d == *"alert_hold("* && $d == *"alert_checks_match("* && $d != *"ack_hold("* ]] || fail "M: store 1's alert_due is not the wired one"
d=$(fdef q purge)
[[ $d == *"findings_history"* && $d == *"greatest(p_days, 90)"* ]] || fail "M: store 1's purge lacks the history's or the alert log's days"
STORES="q q2"
if [[ -z $JOINED ]]; then
  "$BIN0" migrate -config "$WORK/cfg2.yaml" >"$WORK/m2a.log" 2>&1 || fail "migrate store 2 without 0154: $(tail -3 "$WORK/m2a.log")"
  [[ $(q2 "select count(*) from pgvigil.schema_version where version = '0154_alert_scope.sql'") == 0 ]] || fail "M: store 2 holds 0154 before BIN"
  "$BIN" migrate -config "$WORK/cfg2.yaml" >"$WORK/m2b.log" 2>&1 || fail "migrate store 2 with 0154 last: $(tail -3 "$WORK/m2b.log")"
  [[ $(order q2) == "0190_join_release2.sql 0154_alert_scope.sql" ]] || fail "M: store 2's order: $(order q2)"
  [[ $(fdef q2 alert_due) != *"alert_hold("* ]] || fail "M: store 2's alert_due is wired: BIN0 was not built from the unwired tree"
else
  STORES="q"
  echo "NOT PROVEN M2: store 2 (0154 after the join file) - on a tree whose wiring is in its join file the tree without 0154 is not the unwired tree, and no store meets 0154 after it (both arrive with v0.4.0)"
fi
for f in $STORES; do
  [[ $($f "select pgvigil.alert_hold(now(), 'c', 'i', '{}', 'k', 's', 'x', 'v', 'warning') is null") == t ]] || fail "M ($f): alert_hold on nothing is not NULL"
  [[ $($f "select count(*) from information_schema.columns where table_schema = 'pgvigil' and table_name = 'alert_rule_findings' and column_name = 'op_family'") == 1 ]] || fail "M ($f): no op_family"
  $f "select count(*) from pgvigil.alert_findings" >/dev/null || fail "M ($f): alert_findings"
  $f "select count(*) from pgvigil.alert_rules_effective" >/dev/null || fail "M ($f): alert_rules_effective"
  [[ $($f "select (to_regclass('pgvigil.alert_rules_live_uq') is null)::text || (to_regclass('pgvigil.alert_rules_live_family_uq') is not null)::text") == truetrue ]] || fail "M ($f): the rule index"
done
if [[ -z $JOINED ]]; then
  ok "M: a fresh store holds 0154 then the wired 0190 (alert_due through alert_hold, purge's days); 0154 applies on a store at 0190"
else
  ok "M: a fresh store holds 0154 then 0190, its alert_due through alert_hold and its purge with the history's days (the join file's)"
fi

# ---- R: the role contract ----------------------------------------------------------------------------------------------
dsn() { echo "$PGVIGIL_ADMIN_DSN dbname=$REPO user=$1 password=$PW"; }
q "create role $COL login password '$PW' in role pgvigil_collector" >/dev/null
q "create role $ALR login password '$PW' in role pgvigil_alerter" >/dev/null
q "create role $RDR login password '$PW' in role pgvigil_reader" >/dev/null
export PGV_PROOF_ALERTS_DSN; PGV_PROOF_ALERTS_DSN=$(dsn "$ALR")
as() { local who=$1; shift; psql "$(dsn "$who")" -XAt "$@" 2>&1 || true; }
[[ $(as "$COL" -c "select has_function_privilege('pgvigil.import_alert_window(timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "R: the collector may not call import_alert_window"
out=$(as "$COL" -c "insert into pgvigil.alert_windows (action, scope, weekdays, start_local, end_local, zone, created_by, created_at) values ('mute', 'fleet', '{1}', '01:00', '02:00', 'UTC', 'x', now())")
[[ $out == *"permission denied"* ]] || fail "R: the collector inserted into alert_windows: $out"
for t in alert_held digest_log findings_history; do
  [[ $(as "$ALR" -c "select has_table_privilege('pgvigil.$t', 'INSERT')") == t ]] || fail "R: the alerter may not insert into $t"
  [[ $(as "$RDR" -c "select has_table_privilege('pgvigil.$t', 'INSERT')") == f ]] || fail "R: the reader may insert into $t"
done
[[ $(as "$ALR" -c "select pgvigil.findings_history_run(now())") =~ ^[0-9]+$ ]] || fail "R: the alerter's findings_history_run: $(as "$ALR" -c "select pgvigil.findings_history_run(now())")"
ok "R: the collector writes windows through the door only; the alerter writes the held log, digests and history; the reader none"

# ---- T, Z, C: the pure functions -----------------------------------------------------------------------------------------
eqv() { local got; got=$(q "select ($1)::text"); [[ $got == "$2" ]] || fail "$3: $1 = '$got', wanted '$2'"; }
eqv "pgvigil.alert_tags_match('{env:prod,env:stage,app:billing}', '{env:prod,app:billing}')" true T
eqv "pgvigil.alert_tags_match('{env:prod,app:billing}', '{env:prod}')" false T
eqv "pgvigil.alert_tags_match('{Env:prod}', '{env:prod}')" true T
eqv "pgvigil.alert_tags_match('{env:Prod}', '{env:prod}')" false T
eqv "pgvigil.alert_tags_match('{}', '{env:prod}')" false T
eqv "pgvigil.alert_scope_norm('{ Env:prod , env:prod, app:x}')" "{app:x,env:prod}" T
eqv "pgvigil.alert_scope_text('{env:prod,env:stage,app:billing}')" "app:billing AND (env:prod OR env:stage)" T
ok "T: tag lists"
Z="America/Chicago"
wo() { q "select pgvigil.alert_window_open(('$1')::timestamptz, '$2', '$3', '$4', '$Z')::text"; }
[[ "$(wo '2026-11-16 23:30 America/Chicago' '{1}' 22:00 06:00) $(wo '2026-11-17 05:59 America/Chicago' '{1}' 22:00 06:00)" == "true true" ]] || fail "Z: the Monday night window does not hold Mon 23:30 / Tue 05:59"
[[ "$(wo '2026-11-17 06:00 America/Chicago' '{1}' 22:00 06:00) $(wo '2026-11-15 23:30 America/Chicago' '{1}' 22:00 06:00)" == "false false" ]] || fail "Z: the Monday night window holds Tue 06:00 or Sun 23:30"
for t in '07:00' '07:30' '08:00' '08:30'; do
  [[ $(wo "2026-03-08 $t UTC" '{7}' 02:00 03:00) == false ]] || fail "Z: the skipped hour held at $t UTC"
done
[[ "$(wo '2026-03-08 07:30 UTC' '{7}' 01:00 04:00) $(wo '2026-03-08 08:30 UTC' '{7}' 01:00 04:00)" == "true true" ]] || fail "Z: the spring-forward day's 01:00-04:00 window does not hold"
[[ "$(wo '2026-11-01 06:30 UTC' '{7}' 01:00 02:00) $(wo '2026-11-01 07:30 UTC' '{7}' 01:00 02:00)" == "true true" ]] || fail "Z: the repeated hour is not held twice"
[[ $(wo '2026-11-16 23:59:30 America/Chicago' '{1}' 00:00 24:00) == true ]] || fail "Z: a whole day 00:00-24:00 does not hold at 23:59:30"
dd() { q "select count(*) || '|' || coalesce(to_char(max(since) at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), '') from pgvigil.digest_due(('$1')::timestamptz, '[{\"name\":\"zz$SUF\",\"digest_hour\":3,\"timezone\":\"UTC\"}]'::jsonb)"; }
[[ $(dd '2026-11-20 06:00 UTC') == 1\|* ]] || fail "Z: the digest owed after a restart across its hour: $(dd '2026-11-20 06:00 UTC')"
q "select pgvigil.digest_record('2026-11-20 06:00 UTC', '{\"channel\":\"zz$SUF\",\"due_at\":\"2026-11-20T03:00:00Z\",\"since\":\"2026-11-19T03:00:00Z\",\"outcome\":\"sent\"}'::jsonb)" >/dev/null
[[ $(dd '2026-11-20 06:01 UTC') == 0\|* && $(dd '2026-11-21 02:00 UTC') == 0\|* ]] || fail "Z: a digest owed twice"
[[ $(dd '2026-11-21 05:00 UTC') == "1|2026-11-20 06:00" ]] || fail "Z: the next day's digest: $(dd '2026-11-21 05:00 UTC')"
eqv "pgvigil.digest_hour_at('2026-03-08 09:00 UTC', 2, '$Z') = '2026-03-08 08:00 UTC'" true Z
eqv "pgvigil.digest_hour_at('2026-03-08 07:30 UTC', 2, '$Z') = '2026-03-07 08:00 UTC'" true Z
eqv "pgvigil.alert_rule_hour_at('2026-11-02 15:45 UTC', '$Z') = '2026-11-02 15:00 UTC'" true Z
echo "observed: alert_rule_hour_at of the repeated hour: $(q "select pgvigil.alert_rule_hour_at('2026-11-01 06:30 UTC', '$Z') || ' / ' || pgvigil.alert_rule_hour_at('2026-11-01 07:30 UTC', '$Z')")"
ok "Z: windows across midnight and both DST days; the digest hour; the rule hour"
eqv "pgvigil.alert_checks_match('{backups}', 'Backups', 'x')" true C
eqv "pgvigil.alert_checks_match('{backups}', 'blocking', 'x')" false C
eqv "pgvigil.alert_checks_match('{}', 'blocking', 'x')" true C
eqv "pgvigil.alert_checks_match('{x}', 'blocking', 'X')" true C
ok "C: checks"

# ---- a seeded instance and its samples (H, K, F, Y, D) -------------------------------------------------------------------
HID=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         values ('$INSTH', 'self-managed', '{env:proofh,app:h}', now(), now(), true, 'postgres') returning instance_id" | sed -n 1p)
[[ $(q "select array_to_string(tags, ',') from pgvigil.instance_tags_merged where instance_id = $HID") == *env:proofh* ]] || fail "the seeded instance's tags are not merged"
sample() {   # sample <a SQL time expression> <idle_in_txn>: one activity sample of the seeded instance
  q "insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
       active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
     values ($HID, ($1)::timestamptz, 20, 1, 5, $2, 0, 0, 0, 1, 1, 1, 100)" >/dev/null
}
rule() {     # rule <json>: one rule through the store's door, its id
  q "select pgvigil.import_alert_rule(now(), '$1'::jsonb || '{\"op\":\"add\",\"ui_user\":\"proof\",\"metric\":\"sessions.idle_in_txn\"}'::jsonb)->>'rule_id'"
}
endrule() { q "select pgvigil.import_alert_rule(now(), '{\"op\":\"end\",\"ui_user\":\"proof\",\"rule_id\":$1}'::jsonb)->>'outcome'" >/dev/null; }
win() {      # win <json>: one window through the store's door, its id
  q "select pgvigil.import_alert_window(now(), '$1'::jsonb || '{\"op\":\"add\",\"ui_user\":\"proof\"}'::jsonb)->>'window_id'"
}
endwin() { q "select pgvigil.import_alert_window(now(), '{\"op\":\"end\",\"ui_user\":\"proof\",\"window_id\":$1}'::jsonb)->>'outcome'" >/dev/null; }
ALLDAY='"weekdays":[1,2,3,4,5,6,7],"start_local":"00:00","end_local":"24:00","zone":"UTC"'
hold() {     # hold <channel> <key> <source> <severity> [digest true|false]: alert_hold now on the seeded instance, 'kind/via' or NULL
  q "select coalesce((h).kind || '/' || (h).via, 'NULL') from (select pgvigil.alert_hold(now(), '$1', '$INSTH', '{env:proofh,app:h}', '$2', '$3', 'x', 'v', '$4', 600, ${5:-true}) h) z"
}

# ---- H: the hold test --------------------------------------------------------------------------------------------------
K=hkey$SUF
AM=$(q "select pgvigil.import_ack(now(), '{\"op\":\"add\",\"ui_user\":\"proof\",\"kind\":\"mute\",\"finding_key\":\"$K\"}'::jsonb)->>'ack_id'")
W1=$(win "{\"action\":\"blackout\",\"scope\":\"fleet\",$ALLDAY}")
[[ $(hold c "$K" 'alert rule' warning) == blackout/window ]] || fail "H: ack mute + window blackout: $(hold c "$K" 'alert rule' warning)"
AB=$(q "select pgvigil.import_ack(now(), '{\"op\":\"add\",\"ui_user\":\"proof\",\"kind\":\"blackout\",\"instance_name\":\"$INSTH\",\"starts_at\":\"$(date -u -d '-1 minute' +%FT%TZ)\",\"until\":\"$(date -u -d '+1 hour' +%FT%TZ)\"}'::jsonb)->>'ack_id'")
[[ $(hold c "$K" 'alert rule' warning) == blackout/ack ]] || fail "H: ack blackout + window blackout: $(hold c "$K" 'alert rule' warning)"
for a in "$AM" "$AB"; do q "select pgvigil.import_ack(now(), '{\"op\":\"end\",\"ui_user\":\"proof\",\"ack_id\":$a}'::jsonb)" >/dev/null; done
endwin "$W1"
W2=$(win "{\"action\":\"mute\",\"scope\":\"fleet\",$ALLDAY}"); W3=$(win "{\"action\":\"digest\",\"scope\":\"fleet\",$ALLDAY}")
[[ $(hold c "$K" 'alert rule' warning) == mute/window ]] || fail "H: window mute + digest: $(hold c "$K" 'alert rule' warning)"
endwin "$W2"
[[ $(hold c "$K" 'alert rule' warning) == digest/window ]] || fail "H: digest alone: $(hold c "$K" 'alert rule' warning)"
[[ $(hold c "$K" 'alert rule' warning false) == NULL ]] || fail "H: a digest window held on a channel with no digest"
[[ $(hold c "$K" 'alert rule' critical) == NULL ]] || fail "H: a critical was digest-held"
[[ $(hold c "$K" 'pgvigil repository' warning) == NULL ]] || fail "H: a repository-wide alert was held by a window"
endwin "$W3"
W4=$(win "{\"action\":\"mute\",\"scope\":\"tags\",\"scope_tags\":[\"env:proofh\",\"app:h\"],$ALLDAY}")
[[ $(hold c "$K" 'alert rule' warning) == mute/window ]] || fail "H: the tags window env:proofh AND app:h"
endwin "$W4"
W5=$(win "{\"action\":\"mute\",\"scope\":\"tags\",\"scope_tags\":[\"env:proofh\",\"app:other\"],$ALLDAY}")
[[ $(hold c "$K" 'alert rule' warning) == NULL ]] || fail "H: the tags window env:proofh AND app:other held"
endwin "$W5"
q "insert into pgvigil.alert_held (hold_kind, hold_id, channel, finding_key, instance_name, severity, source, first_at, last_at)
   values ('digest', $W3, 'c', '$K', '$INSTH', 'warning', 'alert rule', now() - interval '5 minutes', now() - interval '2 minutes')" >/dev/null
[[ $(hold c "$K" 'alert rule' warning) == digest/carry ]] || fail "H: the carry-over: $(hold c "$K" 'alert rule' warning)"
q "insert into pgvigil.alert_state (channel, finding_key, instance_name, severity, first_sent_at, last_sent_at)
   values ('c', '$K', '$INSTH', 'warning', now(), now())" >/dev/null
[[ $(hold c "$K" 'alert rule' warning) == NULL ]] || fail "H: the carry-over held an alert sent on the channel"
q "delete from pgvigil.alert_state where channel = 'c' and finding_key = '$K'" >/dev/null
q "update pgvigil.alert_held set last_at = now() - interval '20 minutes' where finding_key = '$K'" >/dev/null
[[ $(hold c "$K" 'alert rule' warning) == digest/carry ]] || fail "H: the carry-over lapsed while the sender was away (missing_since NULL)"
[[ $(hold c "$K" 'alert rule' warning false) == NULL ]] || fail "H: the carry-over held on a channel with no digest"
q "update pgvigil.alert_held set missing_since = now() - interval '20 minutes' where finding_key = '$K'" >/dev/null
[[ $(hold c "$K" 'alert rule' warning) == NULL ]] || fail "H: the carry-over outlived the finding's absence past clear_after"
ok "H: precedence, the ceiling, digest channels only, repository alerts, tag windows, the carry-over and its ends"

# ---- K: rule kinds -------------------------------------------------------------------------------------------------------
T0=$(q "select date_trunc('minute', now())")
RT=$(rule "{\"op_dir\":\"above\",\"warning\":3,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}")
RR=$(rule "{\"op_dir\":\"rises\",\"warning\":4,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}")
[[ -n $RT && -n $RR ]] || fail "K: the threshold and rise rules were not both made ($RT / $RR)"
sample "'$T0'::timestamptz - interval '2 minutes'" 2; sample "'$T0'::timestamptz - interval '1 minute'" 8
q "select pgvigil.alert_rules_run('$T0')" >/dev/null
[[ $(q "select string_agg(op_family, ' ' order by op_family) from pgvigil.alert_rule_state where instance_id = $HID") == "rise threshold" ]] || fail "K: the two families' rows"
[[ $(q "select value from pgvigil.alert_rule_findings where instance_id = $HID and op_family = 'rise'") == "rises 4 between two samples for 0 min; last rise 6" ]] || fail "K: the rise finding: $(q "select value from pgvigil.alert_rule_findings where instance_id = $HID and op_family = 'rise'")"
[[ $(q "select value from pgvigil.alert_rule_findings where instance_id = $HID and op_family = 'threshold'") == "above 3 for 0 min; last sample 8" ]] || fail "K: the threshold finding is not 0085's form"
RF=$(rule '{"op_dir":"above","warning":1000,"for_minutes":0,"scope":"fleet"}')
RG=$(rule '{"op_dir":"above","warning":100,"for_minutes":0,"scope":"tags","scope_tags":["env:proofh"]}')
[[ $(q "select count(*) from pgvigil.alert_rule_overrides where rule_id = $RF and by_rule_id = $RT and instances = 1") == 1 ]] || fail "K: the fleet rule is not overridden by the instance rule on 1"
[[ $(q "select count(*) from pgvigil.alert_rule_overrides where rule_id = $RG and by_rule_id = $RT") == 1 ]] || fail "K: the tags rule is not overridden by the instance rule"
endrule "$RT"
[[ $(q "select count(*) from pgvigil.alert_rule_overrides where rule_id = $RF and by_rule_id = $RG and instances = 1") == 1 ]] || fail "K: the fleet rule is not overridden by the tags rule"
for r in "$RR" "$RF" "$RG"; do endrule "$r"; done
q "delete from pgvigil.activity_summary where instance_id = $HID" >/dev/null
# the baseline: seven days of the hour in America/Chicago, then now
base_days() {   # base_days <n> <value>: the same local hour on each of the last n days
  local d
  for d in $(seq 1 "$1"); do
    sample "('$T0'::timestamptz at time zone '$Z' - interval '$d days') at time zone '$Z'" "$2"
  done
}
baseline_case() {   # baseline_case <days> <day value> <now value>: the rule's state and detail after one run at T0
  q "delete from pgvigil.activity_summary where instance_id = $HID; delete from pgvigil.alert_rule_baseline" >/dev/null
  base_days "$1" "$2"; sample "'$T0'::timestamptz - interval '1 minute'" "$3"
  q "select pgvigil.alert_rules_run('$T0')" >/dev/null
  q "select s.state || '|' || coalesce((select detail from pgvigil.alert_rule_findings f where f.instance_id = $HID and f.op_family = 'baseline'), '')
       from pgvigil.alert_rule_state s where s.instance_id = $HID and s.op_family = 'baseline'"
}
RB=$(rule "{\"op_dir\":\"above_baseline\",\"warning\":5,\"for_minutes\":0,\"band_pct\":20,\"zone\":\"$Z\",\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}")
[[ -n $RB ]] || fail "K: the baseline rule was not made"
got=$(baseline_case 7 10 11); [[ $got == ok\|* ]] || fail "K: 7 days at 10, now 11: '$got' (wanted ok)"
got=$(baseline_case 6 10 11); [[ $got == warning\|*"no baseline yet (6 of 7 days)"* ]] || fail "K: 6 days: '$got'"
got=$(baseline_case 7 0 3); [[ $got == ok\|* ]] || fail "K: a zero baseline, now 3: '$got'"
got=$(baseline_case 7 0 6); [[ $got == warning\|* ]] || fail "K: a zero baseline, now 6: '$got'"
endrule "$RB"
ok "K: rise and threshold side by side (0085's value text kept), the override line, the baseline (relaxed, no baseline yet, zero)"

# ---- F: flapping ---------------------------------------------------------------------------------------------------------
flap_run() {   # flap_run <rule id> <values...>: one sample and one run a minute apart per value, from T0 + 1 h
  local rid=$1 i=0 v at; shift
  for v in "$@"; do
    i=$((i + 1)); at="'$T0'::timestamptz + interval '1 hour' + interval '$((OFF + i)) minutes'"
    sample "$at - interval '10 seconds'" "$v"
    q "select pgvigil.alert_rules_run($at)" >/dev/null
  done
  OFF=$((OFF + i))
}
mark() { q "select coalesce(flapping_since::text, 'NULL') from pgvigil.alert_rule_state where rule_id = $1 and instance_id = $HID"; }
# part K's runs all ran at T0, so its threshold row (evaluated_at T0) outlived its rule (a run deletes only rows it did
# not judge at its own time) and would lend F's series one result: F starts on an empty ring
q "delete from pgvigil.activity_summary where instance_id = $HID; delete from pgvigil.alert_rule_state where instance_id = $HID" >/dev/null
OFF=0
RFL=$(rule "{\"op_dir\":\"above\",\"warning\":3,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}")
flap_run "$RFL" 8 8 0 0 8 8 0 0 8 8 0
[[ $(mark "$RFL") == NULL ]] || fail "F: marked before 12 results"
flap_run "$RFL" 0
[[ $(mark "$RFL") != NULL ]] || fail "F: 5 changes in 11 did not mark the series (results $(q "select results from pgvigil.alert_rule_state where rule_id = $RFL"))"
flap_run "$RFL" 8
FK=$(q "select pgvigil.alert_key(instance_id, source, setting, value) from pgvigil.alert_rule_findings where rule_id = $RFL")
q "insert into pgvigil.alert_state (channel, finding_key, instance_name, severity, first_sent_at, last_sent_at)
   select 'c', '$FK', '$INSTH', 'warning', flapping_since + interval '30 seconds', flapping_since + interval '30 seconds'
     from pgvigil.alert_rule_state where rule_id = $RFL and instance_id = $HID" >/dev/null   # sent once after the mark (the runs are an hour ahead)
[[ $(q "select coalesce((h).kind, 'NULL') from (select pgvigil.alert_hold(now(), 'c', '$INSTH', '{}', '$FK', 'alert rule', s, v, 'warning') h
          from (select setting s, value v from pgvigil.alert_rule_findings where rule_id = $RFL) x) z") == flapping ]] || fail "F: the flapping hold"
flap_run "$RFL" 8 8 8 8 8 8 8 8 8 8 8 8
[[ $(mark "$RFL") == NULL ]] || fail "F: 12 steady results kept the mark"
endrule "$RFL"
q "delete from pgvigil.activity_summary where instance_id = $HID; delete from pgvigil.alert_state where channel = 'c'" >/dev/null
RNF=$(rule "{\"op_dir\":\"above\",\"warning\":3,\"for_minutes\":0,\"ignore_flapping\":true,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}")
flap_run "$RNF" 8 8 0 0 8 8 0 0 8 8 0 0
[[ $(mark "$RNF") == NULL ]] || fail "F: a rule with ignore_flapping was marked"
endrule "$RNF"
ok "F: SQLWATCH's ratio marks, holds after one send, drops when steady; ignore_flapping never marks"

# ---- Y: the findings history ----------------------------------------------------------------------------------------------
q "delete from pgvigil.activity_summary where instance_id = $HID; truncate pgvigil.findings_history_last" >/dev/null
q "delete from pgvigil.findings_history" >/dev/null
RY=$(rule "{\"op_dir\":\"above\",\"warning\":3,\"critical\":9,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}")
hist() { q "select pgvigil.findings_history_run(($1)::timestamptz)" >/dev/null; }   # hist <a SQL time expression>
hrows() { q "select count(*) from pgvigil.findings_history where instance_id = $HID and event = '$1'"; }
TY=$(q "select now()")
sample "'$TY'" 5; q "select pgvigil.alert_rules_run(('$TY')::timestamptz + interval '1 second')" >/dev/null
hist "'$TY'"
[[ $(hrows open) == 1 ]] || fail "Y: no open row"
sample "('$TY')::timestamptz + interval '1 minute'" 10; q "select pgvigil.alert_rules_run(('$TY')::timestamptz + interval '61 seconds')" >/dev/null
hist "('$TY')::timestamptz + interval '62 seconds'"
[[ $(hrows severity) == 1 ]] || fail "Y: no severity row"
hist "('$TY')::timestamptz + interval '59 minutes'"
[[ $(hrows sample) == 0 ]] || fail "Y: a sample before the hour"
hist "('$TY')::timestamptz + interval '63 minutes'"
[[ $(hrows sample) == 1 ]] || fail "Y: no hourly sample"
[[ $(q "select metric_value is not null from pgvigil.findings_history where instance_id = $HID and event = 'sample'") == t ]] || fail "Y: the sample has no metric value"
endrule "$RY"; q "select pgvigil.alert_rules_run(('$TY')::timestamptz + interval '64 minutes')" >/dev/null
hist "('$TY')::timestamptz + interval '65 minutes'"
[[ $(hrows close) == 1 && $(q "select count(*) from pgvigil.findings_history where instance_id = $HID") == 4 ]] || fail "Y: close / total rows"
[[ $(q "select count(*) from pgvigil.findings_history_last l where l.finding_key in (select finding_key from pgvigil.findings_history where instance_id = $HID)") == 0 ]] || fail "Y: findings_history_last still holds the seeded key"
ok "Y: open, severity, the hourly sample, close: 4 rows"

# ---- W: the window write door (serve) -------------------------------------------------------------------------------------
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" $UIUSER >/dev/null 2>&1 || fail "user add"
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >> "$WORK/serve.log" 2>&1 &
SRV=$!
for n in $(seq 1 60); do
  curl -sf -o /dev/null "$U/" && break
  kill -0 "$SRV" 2>/dev/null || fail "serve died: $(tail -3 "$WORK/serve.log")"
  [[ $n == 60 ]] && fail "serve did not answer"
  sleep 0.5
done
JAR=$WORK/jar
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
post() { code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$U/api/$1"; }
rowsw() { q "select (select count(*) from pgvigil.alert_windows) || '/' || (select count(*) from pgvigil.alert_window_log)"; }
GOOD="{\"action\":\"mute\",\"scope\":\"fleet\",$ALLDAY}"
W0=$(rowsw)
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$GOOD" "$U/api/alertwindows") == 401 ]] || fail "W: no session: $(cat "$WORK/body")"
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
[[ $(code -b "$JAR" -H 'Content-Type: application/json' -d "$GOOD" "$U/api/alertwindows") == 403 ]] || fail "W: no header: $(cat "$WORK/body")"
for bad in '"action":"pause","scope":"fleet","weekdays":[1],"start_local":"01:00","end_local":"02:00","zone":"UTC"' \
           '"action":"mute","scope":"fleet","weekdays":[8],"start_local":"01:00","end_local":"02:00","zone":"UTC"' \
           '"action":"mute","scope":"fleet","weekdays":[1],"start_local":"22:00","end_local":"22:00","zone":"UTC"' \
           '"action":"mute","scope":"fleet","weekdays":[1],"start_local":"01:00","end_local":"02:00","zone":"Mars/Base"' \
           '"action":"digest","severity_ceiling":"critical","scope":"fleet","weekdays":[1],"start_local":"01:00","end_local":"02:00","zone":"UTC"' \
           '"action":"mute","severity_ceiling":"info","scope":"fleet","weekdays":[1],"start_local":"01:00","end_local":"02:00","zone":"UTC"' \
           '"action":"mute","weekdays":[1],"start_local":"01:00","end_local":"02:00","zone":"UTC"'; do
  [[ $(post alertwindows "{$bad}") == 400 ]] || fail "W: {$bad} answered $(cat "$WORK/body")"
done
[[ $(rowsw) == "$W0" ]] || fail "W: a refused request left a row ($W0 -> $(rowsw))"
RE=$(rule '{"op_dir":"above","warning":1000,"for_minutes":0,"scope":"fleet"}'); endrule "$RE"
[[ $(post alertwindows "{\"action\":\"mute\",\"from_rule_id\":$RE,\"weekdays\":[1],\"start_local\":\"01:00\",\"end_local\":\"02:00\",\"zone\":\"UTC\"}") == 409 ]] && grep -qF 'no live rule' "$WORK/body" || fail "W: the ended rule's window: $(cat "$WORK/body")"
idw() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("window_id") or "")' "$WORK/body"; }
[[ $(post alertwindows "$GOOD") == 200 ]] || fail "W: add: $(cat "$WORK/body")"; WA=$(idw)
[[ $(post alertwindows "{\"op\":\"edit\",\"window_id\":$WA,\"action\":\"blackout\",\"scope\":\"fleet\",$ALLDAY}") == 200 ]] || fail "W: edit: $(cat "$WORK/body")"; WB=$(idw)
[[ $WB != "$WA" && $(q "select ended_by from pgvigil.alert_windows where window_id = $WA") == "$UIUSER" && $(q "select replaces from pgvigil.alert_windows where window_id = $WB") == "$WA" ]] || fail "W: the edit's rows"
[[ $(post alertwindows "{\"op\":\"end\",\"window_id\":$WB}") == 200 ]] || fail "W: end: $(cat "$WORK/body")"
[[ $(post alertwindows "{\"op\":\"end\",\"window_id\":$WB}") == 409 ]] && grep -qF 'already ended' "$WORK/body" || fail "W: end again: $(cat "$WORK/body")"
curl -s -b "$JAR" "$U/api/alertscope?part=windows" -o "$WORK/w.json"
[[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["windows"]; c=d["columns"]; print(sum(1 for r in d["rows"] if r[c.index("window_id")] in (int(sys.argv[2]), int(sys.argv[3]))))' "$WORK/w.json" "$WA" "$WB") == 2 ]] || fail "W: GET does not list both rows"
kill "$SRV" 2>/dev/null || true; SRV=""
ok "W: the door's 401 / 403 / 400s / 409; add, edit, end, end again; GET lists them"

# ---- D: the digest by real passes -------------------------------------------------------------------------------------------
pass() {
  local tag=$1 rc
  set +e; "$BIN" alerts -config "$CFG" >"$WORK/pass.$tag.out" 2>"$WORK/pass.$tag.err"; rc=$?; set -e
  if (( rc != 0 )) || grep -qE 'findings history not written|digests not read|alert rules not judged' "$WORK/pass.$tag.out"; then
    fail "pass $tag: exit $rc: $(cat "$WORK/pass.$tag.out") $(tr '\n' ' ' < "$WORK/pass.$tag.err" | cut -c1-600)"
  fi
}
files() { grep -l "$2" "$WORK/$1"/* 2>/dev/null | wc -l; }
q "delete from pgvigil.activity_summary where instance_id = $HID" >/dev/null
WD=$(win "{\"action\":\"digest\",\"scope\":\"fleet\",$ALLDAY}")
RD=$(rule "{\"op_dir\":\"above\",\"warning\":3,\"critical\":50,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}")
fresh() { sample "now() - interval '5 seconds'" "$1"; }
fresh 5; pass d1
[[ $(files drop '"firing"') == 1 ]] || fail "D: 'drop' has no digest: pass 1 should send it the firing ($(files drop '"firing"'))"
[[ $(files dig '"firing"') == 0 ]] || fail "D: pass 1 sent dig a firing alert under the digest window"
[[ $(ls "$WORK/dig" | wc -l) == 1 && $(q "select count(*) from pgvigil.digest_log where channel = 'dig' and outcome = 'sent'") == 1 ]] || fail "D: pass 1's digest: $(ls "$WORK/dig") / $(q "select outcome from pgvigil.digest_log")"
grep -qF "$INSTH" "$WORK/dig"/* || fail "D: the digest does not name the instance"
[[ $(q "select count(*) from pgvigil.alert_held where hold_kind = 'digest' and channel = 'dig'") -ge 1 && $(q "select count(*) from pgvigil.alert_held where hold_kind = 'digest' and channel = 'drop'") == 0 ]] || fail "D: the digest rows held (dig one or more, drop none)"
fresh 5; pass d2
[[ $(ls "$WORK/dig" | wc -l) == 1 && $(files dig '"firing"') == 0 ]] || fail "D: pass 2 sent dig a second digest or a firing alert"
endwin "$WD"; fresh 5; pass d3
[[ $(files dig '"firing"') == 0 ]] || fail "D: the window's end fired the digest-held alert on dig"
fresh 0; pass d4; fresh 0; pass d5
[[ $(files dig '"resolved"') == 0 ]] || fail "D: a recovery was sent for a digest-held alert on dig"
WD2=$(win "{\"action\":\"digest\",\"scope\":\"fleet\",$ALLDAY}")
fresh 60; pass d6
[[ $(files dig '"critical"') -ge 1 ]] || fail "D: a critical under a digest window was not paged at once on dig"
[[ $(ls "$WORK/dig2" | wc -l) == 0 && $(q "select count(*) from pgvigil.digest_log where channel = 'dig2' and outcome = 'empty'") == 1 ]] || fail "D: the empty channel: $(ls "$WORK/dig2") / $(q "select string_agg(outcome, ',') from pgvigil.digest_log where channel = 'dig2'")"
endwin "$WD2"
fresh 0; pass d7; fresh 0; pass d8                        # the critical clears on every channel first
WM=$(win "{\"action\":\"mute\",\"scope\":\"fleet\",$ALLDAY}"); fresh 5; pass d9; endwin "$WM"
WK=$(win "{\"action\":\"blackout\",\"scope\":\"fleet\",$ALLDAY}"); fresh 5; pass d10; endwin "$WK"
[[ $(q "select count(distinct hold_kind) from pgvigil.alert_held where channel = 'drop' and hold_kind in ('mute', 'blackout')") == 2 ]] || fail "D: alert_mark did not log a mute and a blackout row for drop"
endrule "$RD"
ok "D: no digest = no digest hold; digest-held (no firing), one digest, no second, the window's end fires nothing, no recovery, a critical pages, an empty day, the held log per kind"

echo "PROOF OK: 403a M R T Z C H K F Y W D"
