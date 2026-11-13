#!/usr/bin/env bash
# Proof of alerts on REAL channels (task 142): one finding of the proof's own fires to a real mail server, a Microsoft
# Teams Workflows webhook, a Slack incoming webhook and PagerDuty's Events API, and its recovery follows on all four.
# scripts/proof-alerts.sh proves the logic against loopback sinks; this proof proves the four providers accept what
# pgvigil sends. It sends real messages: run it only against test destinations.
#
# Needs: psql, openssl, a pgvigil build (PGVIGIL_BIN, default bin/pgvigil) and
#   PGVIGIL_REPO_DSN     a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=...); the proof
#                        makes its own repository database and alerter login (random suffix) and drops both at the end;
#                        the same server is the one monitored instance (one `collect -once instance`).
#   PGV_LIVE_SMTP_USER, PGV_LIVE_SMTP_PASS   the SMTP login (STARTTLS on PGV_LIVE_SMTP_HOST, default
#                        email-smtp.us-east-2.amazonaws.com, port 587); PGV_LIVE_MAIL_FROM (default alerts@pgvigil.com);
#                        PGV_LIVE_MAIL_TO the test mailbox
#   PGV_LIVE_TEAMS       a Teams Workflows webhook URL ("Send webhook alerts to a channel")
#   PGV_LIVE_SLACK       a Slack incoming webhook URL
#   PGV_LIVE_PD          a PagerDuty Events API v2 integration key
# The secrets reach pgvigil as env: names only; nothing of them is written to a file or printed.
#
# Expected (written before the first run):
#  F. the finding 'autovacuum = off' (critical) on the proof's instance, then one `pgvigil alerts` pass: exit 0, a
#     summary line; alert_log holds one 'sent' row per channel - mail, teams, slack, pd - each with n_firing >= 1 and
#     the finding's key among its keys; no 'failed' or 'refused' row. The providers' answers behind 'sent': SMTP 250,
#     Teams 202, Slack 200 'ok', PagerDuty 202 'success' (any other answer is a failed send).
#  R. [review 20261111-092630 B1] the instance read again (the sandbox's real autovacuum is on: the finding leaves the
#     view); pass R0 only stamps the finding missing (exit 0, nothing sent: a missing finding is held until a collection
#     newer than that stamp); the instance read once more; pass R: exit 0, one 'sent' row per channel with
#     n_resolved >= 1 and the finding's key; alert_state's four rows of the finding cleared with recovery_sent_at set.
#  C. [review 20261111-092424 B1] the finding staged again and a pass (four 'sent' rows firing it), then the instance
#     deactivated and up to two passes (a first may only stamp it): pd's row 'sent' with n_resolved >= 1 and the key (PagerDuty's incident resolved); mail,
#     teams and slack one 'cleared' row each with the key (recorded, nothing sent: nothing was fixed).
#  Before F: the staged finding is the instance's only critical one (else other findings would page too: fail first).
#  On every exit after F the cleanup sends PagerDuty a resolve for every dedup key the run's pd channel used (a resolve
#  of a resolved incident is a no-op), so no lab incident stays open; the key goes to curl on stdin, never argv.
#  On the far side (the channels' owner looks): one mail 'pgvigil: 1 new (1 critical)' and one '... resolved'; a Teams card and a Slack
#  line for each; one PagerDuty incident opened then resolved, both events under the dedup key
#  pgvigil:<instance>:<finding key>.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?a superuser connection to a PostgreSQL sandbox, keyword form}"
for v in PGV_LIVE_SMTP_USER PGV_LIVE_SMTP_PASS PGV_LIVE_MAIL_TO PGV_LIVE_TEAMS PGV_LIVE_SLACK PGV_LIVE_PD; do
  [[ -n ${!v:-} ]] || { echo "FAIL: $v is not set"; exit 1; }
done
export PGV_LIVE_SMTP_HOST=${PGV_LIVE_SMTP_HOST:-email-smtp.us-east-2.amazonaws.com}
export PGV_LIVE_MAIL_FROM=${PGV_LIVE_MAIL_FROM:-alerts@pgvigil.com}
SUF=$(openssl rand -hex 4)
DB=pgvigil_live_$SUF
ALR=pgvigil_live_alr_$SUF
PW=$(openssl rand -hex 16)
WORK=$(mktemp -d)
ADMIN_DSN=$PGVIGIL_REPO_DSN
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }
pd_resolve_all() {
  local k n=0
  [[ $(psql "$ADMIN_DSN" -XAtq -c "select count(*) from pg_database where datname = '$DB'" 2>/dev/null) == 1 ]] || return 0
  while read -r k; do
    [[ -n $k ]] || continue
    printf '{"routing_key":"%s","event_action":"resolve","dedup_key":"pgvigil:%s:%s"}' "$PGV_LIVE_PD" "$INST" "$k" |
      curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data @- \
        https://events.pagerduty.com/v2/enqueue | grep -q '^202$' && n=$((n + 1))
  done < <(psql "$ADMIN_DSN dbname=$DB" -XAtq -c "select distinct unnest(keys) from pgvigil.alert_log where channel = 'pd'" 2>/dev/null)
  echo "cleanup: PagerDuty resolve sent for $n key(s) of the run"
}
cleanup() {
  pd_resolve_all || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $DB with (force)" -c "drop role if exists $ALR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

psql "$ADMIN_DSN" -XAtq -c "create database $DB" >/dev/null
export PGV_LIVE_REPO="$ADMIN_DSN dbname=$DB"
export PGV_LIVE_MON="$ADMIN_DSN"
export PGV_LIVE_ALERTS="$ADMIN_DSN dbname=$DB user=$ALR password=$PW"
q() { psql "$PGV_LIVE_REPO" -XAtq -c "$1"; }
INST=live-$SUF
export INST

cat > "$WORK/pgvigil.yaml" <<EOF
repository:
  dsn: env:PGV_LIVE_REPO
instances:
  - name: $INST
    dsn: env:PGV_LIVE_MON
alerts_dsn: env:PGV_LIVE_ALERTS
alerts:
  - {name: mail, kind: smtp, min_severity: critical, clear_after: 0, instances: [$INST],
     smtp: {host: $PGV_LIVE_SMTP_HOST, port: 587, tls: starttls, username: env:PGV_LIVE_SMTP_USER,
            password: env:PGV_LIVE_SMTP_PASS, from: $PGV_LIVE_MAIL_FROM, to: [$PGV_LIVE_MAIL_TO]}}
  - {name: teams, kind: webhook, min_severity: critical, clear_after: 0, instances: [$INST],
     webhook: {url: env:PGV_LIVE_TEAMS, format: teams}}
  - {name: slack, kind: webhook, min_severity: critical, clear_after: 0, instances: [$INST],
     webhook: {url: env:PGV_LIVE_SLACK, format: slack}}
  - {name: pd, kind: pagerduty, min_severity: critical, clear_after: 0, instances: [$INST],
     pagerduty: {routing_key: env:PGV_LIVE_PD}}
EOF

"$BIN" migrate -config "$WORK/pgvigil.yaml" >"$WORK/migrate.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/migrate.log")"
psql "$ADMIN_DSN" -XAtq -c "create role $ALR login password '$PW' in role pgvigil_alerter" >/dev/null
"$BIN" collect -config "$WORK/pgvigil.yaml" -once instance >"$WORK/collect.log" 2>&1 || fail "collect instance: $(tail -3 "$WORK/collect.log")"
PID=$(q "select instance_id from pgvigil.instances where name = '$INST'")
[[ -n $PID ]] || fail "the instance was not stored"
q "update pgvigil.instance_state set non_default_settings = coalesce(non_default_settings, '[]'::jsonb) || '[{\"name\": \"autovacuum\", \"value\": \"off\"}]' where instance_id = $PID" >/dev/null
[[ $(q "select count(*) from pgvigil.alert_findings where instance_id = $PID and setting = 'autovacuum' and severity = 'critical'") == 1 ]] || fail "the autovacuum finding is not in the view"
NCRIT=$(q "select count(*) from pgvigil.alert_findings where instance_id = $PID and severity = 'critical'")
[[ $NCRIT == 1 ]] || fail "the instance has $NCRIT critical findings, not only the proof's: $(q "select string_agg(source || ' ' || setting, ', ') from pgvigil.alert_findings where instance_id = $PID and severity = 'critical'")"
echo "instance $INST (id $PID); the proof's finding: autovacuum = off (critical), the only critical one"

rows() { q "select channel || ':' || outcome || ':' || n_firing || ':' || n_resolved || ':' || coalesce(left(error, 160), '') from pgvigil.alert_log where channel is not null and snapshot_at >= '$1' order by channel"; }
keyed() { q "select count(*) from pgvigil.alert_log l where l.snapshot_at >= '$1' and l.outcome = 'sent' and l.$2 and exists (select 1 from pgvigil.alert_state s where s.instance_id = $PID and s.setting = 'autovacuum' and s.finding_key = any (l.keys))"; }
pass() {
  local tag=$1 rc
  set +e; "$BIN" alerts -config "$WORK/pgvigil.yaml" >"$WORK/pass.$tag.out" 2>"$WORK/pass.$tag.err"; rc=$?; set -e
  echo "pass $tag: exit $rc; $(grep -m1 '^alerts: ' "$WORK/pass.$tag.out" || echo 'no summary line')"
  grep 'msg="alert channel failed"' "$WORK/pass.$tag.err" | sed 's/^/  /' | cut -c1-300 || true
  (( rc == 0 )) || fail "pass $tag exited $rc: $(tail -5 "$WORK/pass.$tag.err" | tr '\n' ' ' | cut -c1-600)"
}

# ---- F: the finding fires on the four channels -------------------------------------------------------------------
TF=$(q "select now()")
pass F
echo "F rows:"; { rows "$TF" || true; } | sed 's/^/  /'
[[ $(q "select count(*) from pgvigil.alert_log where snapshot_at >= '$TF' and outcome in ('failed', 'refused')") == 0 ]] || fail "F: a channel failed or was refused"
[[ $(keyed "$TF" "n_firing >= 1") == 4 ]] || fail "F: not four 'sent' rows carrying the finding"
ok "F: the finding sent to mail, teams, slack and pd"

# ---- R: the finding clears, the recovery follows -----------------------------------------------------------------
"$BIN" collect -config "$WORK/pgvigil.yaml" -once instance >"$WORK/collect2.log" 2>&1 || fail "collect instance (R): $(tail -3 "$WORK/collect2.log")"
[[ $(q "select count(*) from pgvigil.alert_findings where instance_id = $PID and setting = 'autovacuum'") == 0 ]] || fail "R: the sandbox reads autovacuum off itself: the proof cannot clear its finding"
TR0=$(q "select now()")
pass R0
[[ $(q "select count(*) from pgvigil.alert_log where snapshot_at >= '$TR0' and outcome = 'sent'") == 0 ]] || fail "R0: a pass sent before a collection newer than the missing stamp"
"$BIN" collect -config "$WORK/pgvigil.yaml" -once instance >"$WORK/collect3.log" 2>&1 || fail "collect instance (R, third): $(tail -3 "$WORK/collect3.log")"
TR=$(q "select now()")
pass R
echo "R rows:"; { rows "$TR" || true; } | sed 's/^/  /'
[[ $(q "select count(*) from pgvigil.alert_log where snapshot_at >= '$TR' and outcome in ('failed', 'refused')") == 0 ]] || fail "R: a channel failed or was refused"
[[ $(keyed "$TR" "n_resolved >= 1") == 4 ]] || fail "R: not four 'sent' rows resolving the finding"
[[ $(q "select count(*) from pgvigil.alert_state where setting = 'autovacuum' and instance_id = $PID and cleared_at is not null and recovery_sent_at is not null") == 4 ]] \
  || fail "R: alert_state: $(q "select string_agg(channel || ':' || (cleared_at is not null) || ':' || (recovery_sent_at is not null), ' ' order by channel) from pgvigil.alert_state where setting = 'autovacuum' and instance_id = $PID")"
ok "R: the recovery sent to mail, teams, slack and pd; the four rows cleared"
# ---- C: cleared without a fix - PagerDuty resolves, the others record it silently -----------------------------------
q "update pgvigil.instance_state set non_default_settings = coalesce(non_default_settings, '[]'::jsonb) || '[{\"name\": \"autovacuum\", \"value\": \"off\"}]' where instance_id = $PID" >/dev/null
TC1=$(q "select now()")
pass C1
[[ $(keyed "$TC1" "n_firing >= 1") == 4 ]] || fail "C1: not four 'sent' rows firing the finding again: $(rows "$TC1" | tr '\n' ' ')"
q "update pgvigil.instances set is_active = false where instance_id = $PID" >/dev/null
TC2=$(q "select now()")
pass C2
[[ $(keyed "$TC2" "n_resolved >= 1 and l.channel = 'pd'") == 1 ]] || pass C3
echo "C2 rows:"; { rows "$TC2" || true; } | sed 's/^/  /'
[[ $(keyed "$TC2" "n_resolved >= 1 and l.channel = 'pd'") == 1 ]] || fail "C2: pd did not send the resolve"
[[ $(q "select string_agg(l.channel, ',' order by l.channel) from pgvigil.alert_log l where l.snapshot_at >= '$TC2' and l.outcome = 'cleared' and exists (select 1 from pgvigil.alert_state s where s.instance_id = $PID and s.setting = 'autovacuum' and s.finding_key = any (l.keys))") == "mail,slack,teams" ]] \
  || fail "C2: the other channels' cleared rows: $(rows "$TC2" | tr '\n' ' ')"
ok "C: cleared without a fix - pd resolved its incident, mail / teams / slack recorded it without a message"
echo "PASS proof-alerts-live ($INST): look for 'pgvigil: 1 new (1 critical)' then '1 resolved' on each channel"
