#!/usr/bin/env bash
# Proof of task 403b (internal/alerts webhook.go / alerts.go, migration 0154's alert_channel_failing, internal/web
# q_alert_scope.go's part alerts, internal/mcp tools_alerts.go): a 429's Retry-After, 'alert channel failing' and the
# MCP tool alert_history, on a throwaway repository. Nothing leaves the machine: the webhooks post to a sink on
# loopback, the file channel writes into the proof's own folder. Part L alone (PGVIGIL_PROOF_PART=L) posts to a real
# destination; see below.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 14+ cluster as a superuser. The proof makes one repository
#                      database and two logins, all named pgvigil_s2chan_*_<random>, and drops them at the end. Not
#                      dropped: the cluster-wide group roles `pgvigil migrate` makes.
#   The proof builds BIN from a copy of this tree (go build) with scripts/proof-alert-scope-wiring.patch applied (the
#   lead's lines in 0190, web.go, q_alert_rules.go, tools.go; skipped when the tree already holds them, or holds them in a
#   join's own words: the j16 join routes POST /api/alertwindows through s.post; one line of each of the 12 hunks).
#   Needs: psql, curl, python3, ss, go, tar, git (git apply only).
#
# Expected (written before the first run; red first: on 5e53c86 the build has no alert_channel_failing, part M fails):
#  M. a fresh store migrated by BIN: alert_findings' definition reads alert_channel_findings (the wiring's third arm:
#     alert_channel_failing and B24k's alert_channel_quota_low);
#     the index alert_log_channel_at_idx stands; alert_channel_failing answers. The alerter login may read it through
#     alert_findings (a pass runs as that login below).
#  C. 'alert channel failing' (Fixed 21 / 27). Channels: hook2 (webhook to the sink's /c, floor warning), drop (file,
#     floor warning, clear_after 0), hook (webhook to /r, floor critical). The sink answers /c with 500. One Send test of
#     hook2 per pass (a test is an attempt like any send; the tests' 2-minute gap is met by asking each at its own past
#     minute; a pass sends its tests BEFORE it reads what is owed, alerts.go Pass):
#     - while alert_log holds fewer than 3 failed attempts in a row for hook2: drop holds no 'alert channel failing';
#     - the pass of the third failure: drop gets ONE firing file of it - setting 'alert channel failing', value hook2,
#       severity warning, detail 'alert channel failing: webhook to http://127.0.0.1:<port> (json), the last 3 sends
#       failed, ...; last error: ... 500 ...', source 'pgvigil repository', sender 'pgvigil' (the file's envelope);
#     - hook2 never gets its own: no sink body on /c names 'alert channel failing', no alert_state row of hook2 for it;
#     - hook (floor critical) gets none either (K3 at warning: a critical-only channel is not told);
#     - alert_channel_failing's at for hook2 is its first failed attempt (the streak's start), not the third;
#     - a further pass: no second firing file on drop;
#     - the sink answers 200, one more test: its alert_log row is 'test'; that same pass (alert_mark marks the finding
#       gone at the pass's own time, drop's clear_after is 0): drop gets ONE 'resolved' file of it (the recovery), and
#       alert_channel_failing holds no hook2 row; a further pass: no second 'resolved' file.
#  R. Retry-After (Fixed 28), Send tests of hook through the changed sender; per row the sink's requests that carry the
#     test message, and hook's newest alert_log row:
#     - R1 429 'Retry-After: 2', then 200: 2 requests, the second at least 2 s after the first, the same body; 'test';
#     - R2 429 'Retry-After: 30': 1 request; 'failed', the error saying 'more than the 10s a send waits';
#     - R3 429 'Retry-After: 1' twice: 2 requests; 'failed', 'after waiting out a Retry-After of 1s';
#     - R4 429 with no Retry-After: 1 request; 'failed', 'no Retry-After';
#     - R5 500, then 200: 1 request (a 500 is not retried); 'failed'.
#     No error text names the URL's path (/r/token-...).
#  P. alert_history (Added 20). Seeded: instances A, B and C; B with 1,001 alerts fired in the last hour, C with exactly
#     1,000, A with 2 and one more fired 100 days ago and cleared 99 days ago. Through serve (the UI login):
#     - GET /api/alertscope?part=alerts&instance_id=A over 90 days: 2 rows, cut false;
#     - the same for B: 1,000 rows, cut true (filtered by the instance before the limit);
#     - the same for C: 1,000 rows, cut false (nothing was left out);
#     - part=alerts without instance_id: 400 'part alerts needs instance_id'.
#     Through `pgvigil mcp` (the reader login): tools/list names alert_history; tools/call {instance A, hours 2160}: 2
#     alerts (not the 100-day-old one) and a findings_history list; {hours 2161}: an error result naming 1..2160;
#     {from, to 91 days apart}: an error naming 90 days.
#  L. (PGVIGIL_PROOF_PART=L only, on the laptop rules: F3 (a)) one Send test each through the changed
#     senders to the lab's REAL destinations this run has a secret for: slack-live (the lab's Slack incoming webhook,
#     PGV_LIVE_SLACK), po-live (Pushover's Messages API, PGV_LIVE_PO_TOKEN and PGV_LIVE_PO_USER) and az-live (the Azure
#     lab's Logs Ingestion endpoint, PGV_LIVE_AZ_SECRET with the rule's and the app's ids in PGV_LIVE_AZ_ENDPOINT, _DCR,
#     _STREAM, _TENANT and _CLIENT, which are not secrets). PGVIGIL_BIN is a binary cross-built on the lab box and
#     fetched (no build here), PGVIGIL_ADMIN_DSN the lab box's PostgreSQL through a tunnel; the runner reads the
#     secrets from its secrets file into the environment (never a command line, a file or a log). MemAvailable at least
#     4 GB is read first. Each channel's quiet hours cover the day (a test is sent inside them, a finding is not) and its
#     checks: list names no check, so nothing but the test reaches a destination. Expected, per live channel: its
#     alert_log holds one row, outcome 'test'; nothing else is sent. Slack's message and Pushover's notification read 'a
#     test message on channel <name> ... nothing is wrong'; the Azure row (Event 'test') is read back from the workspace
#     by the runner, not here.
#  O. (B24k) Pushover through real passes against a loopback stub of api.pushover.net's documented answers (NOT PROVEN
#     LIVE: no Pushover account). A channel po (floor critical, the seeded instance) and a rule finding (critical) per row:
#     - O1 the stub answers 200, status 1, 500 of 10,000 messages left: po's attempt 'sent'; the post carries the
#       token, the user key, priority 1 and the alert's line; alert_channel_quota holds 500 / 10000; the next pass:
#       drop gets ONE firing file 'pushover quota low', value po;
#     - O2 the stub answers 429 with X-Limit-App-Reset an hour ahead: 'failed', the error opening 'held until <that
#       time>: '; the next pass posts nothing to the stub and its summary says 'held by the destination: po:', and
#       drop gets ONE firing 'alert channel failing' of po (a held channel is a failing one: review B24k 1); a Send
#       test (the stub back at 200) goes through ('test'), which ends the hold, so the same pass sends the owed alert
#       ('sent': a pass answers its tests before it reads the holds) and drop gets ONE resolved file of it;
#     - O3 the stub answers 400: 'failed', 'held until the configuration changes ('; the next pass posts nothing and
#       drop gets a second firing 'alert channel failing' of po; the configuration given a device: the next pass posts
#       again, with device proof1 ('sent'), and the pass after it sends drop the second resolved file (the pass that
#       posts read the findings before its post).
#  U. (B24k) Azure Monitor Logs through a real pass against loopback stubs of the token endpoint and the ingestion URL
#     (NOT PROVEN LIVE: no Log Analytics workspace). A channel az (floor critical): a rule finding: 'sent'; the stub saw
#     one token request (grant_type client_credentials, scope https://monitor.azure.com//.default, the secret) and one
#     upload to /dataCollectionRules/<dcr>/streams/Custom-PgvigilAlerts?api-version=2023-01-01 with 'Bearer <the token>'
#     and a row whose FindingKey is the finding's; the stub answering 400 '{"error":{"code":"InvalidStream",...}}' to the
#     next finding: 'failed', the error holding 'InvalidStream'.
#  Z. (B24k) Zabbix LIVE in containers on this machine (docker; the images zabbix/zabbix-server-pgsql and
#     zabbix-web-nginx-pgsql alpine-7.0-latest and postgres:16-alpine, free): a server with certificate TLS (a CA,
#     its certificate, made here by openssl), three hosts made through its API - pgvigil-proof (a trapper item
#     pgvigil.alert, text), pgvigil-proof-tls (the same item; the host accepts a certificate only, its subject
#     CN=pgvigil-proof), pgvigil-proof-deny (its item's Allowed hosts 192.0.2.1) - and an API token. The server's
#     certificate carries NO Subject Alternative Name (Zabbix reads none). One critical rule finding, one pass, six
#     channels:
#     - zbx (sender, plain, loopback, host pgvigil-proof): 'sent';
#     - zbxtls (sender, certificate TLS, host pgvigil-proof-tls, tls_server_subject and tls_server_issuer the server
#       certificate's, as Zabbix writes them): 'sent' - the chain and the pins checked, no host name (review B24k 4);
#     - zbxname (sender, certificate TLS, host pgvigil-proof-tls, no pin): 'failed', the error naming the certificate
#       (with nothing pinned the server's name is checked, and 127.0.0.1 is not in it);
#     - zbxapi (api, history.push with the token, host pgvigil-proof): 'sent';
#     - zbxclear (sender, plain, host pgvigil-proof-tls): 'failed', 'processed 0 of 1';
#     - zbxdeny (sender, plain, host pgvigil-proof-deny): 'failed', 'processed 0 of 1'.
#     history.get reads back two values on pgvigil-proof's item (zbx's and zbxapi's in one pass: their (clock, ns)
#     differ, review B24k 2) and one on pgvigil-proof-tls's, each a JSON object with the finding's key. Not graded: whether TLS opens the connection before the ZBXD header (a TLS send to a server
#     that answers only TLS succeeding is what is read). The containers, their network and volumes are removed after
#     and read back gone.
#  S. (K2) the Slack bot against a loopback stand-in of chat.postMessage (NOT PROVEN LIVE: no bot token is ever stored).
#     A channel sb (kind slack, the seeded instance, repeat 1h, clear_after 0) and a critical rule finding:
#     - S1 one top-level post (no thread_ts) to C0PROOF0001 with 'Bearer xoxb-proof-...' and an 'Open in pgvigil'
#       button and no Acknowledge (the door is off); alert_threads holds the post's ts for the occurrence;
#     - S2 a repeat (last_sent_at moved 2 h back): one reply with that thread_ts, no reply_broadcast, its own attempt;
#     - S3 the stand-in refusing the reply (cannot_reply_to_message): the alert goes as a new post in the same pass,
#       at least 0.9 s after the refused call; alert_threads' ts is the new post's, older_ts keeps the first post's;
#     - S4 the rule ended: the recovery is a reply in the thread, no reply_broadcast, '[RESOLVED]';
#     - S5 a new rule on the same series fires again: a top-level post, never a reply into the old thread;
#     - S7 one pass with a new firing and a repeat: two calls (a post, a reply), two 'sent' attempts.
#  A. (K4) attachment, a channel drop (file) beside sb; each row counts only the drop files its own pass wrote (an
#     alert's key turns numbers into '#', so the files of parts S and O can carry the same keys):
#     - A0 every 'metric' row of alert_anchor_checks names a metric_catalog key (the table printed);
#     - A1 an anchor (a rule on sessions.waiting_lock at warning) is sent on drop and sb;
#     - A2 a warning finding on the same instance next pass: no firing file on drop, an alert_held 'attached' row
#       under the anchor on drop and sb, one Slack reply in the anchor's thread ('attached under this alert') though sb
#       owes nothing else that pass;
#     - A3 a critical finding: a firing file on drop (a critical is never attached);
#     - A4 the anchor's rule ended: drop's 'resolved' file of the anchor says 'attached while it stood: ', and the
#       attached finding does not fire in that pass (the anchor stands until its recovery);
#     - A5 the next pass: the attached finding, still standing, fires on drop as itself, 'which resolved ';
#     - A7 / A8 a second anchor, muted (import_ack): a warning beside it is sent, and no 'attached' row is written;
#     - A9 / A10 the mute ended: a new warning is attached under it; turned critical, it fires at once, 'and is
#       critical now';
#     - A11 alert_anchor in a rolled-back transaction: two anchors of one post 2 h old hold what sat under the first
#       ('both:proofanchor1'), the second keeps it when the first resolves ('one:proofanchor2'), and a new alert does
#       not attach to an anchor over 60 minutes old ('fresh:none').
#  B. (K5) the Slack door, a served pgvigil built with the proof knob (alerts.slackProofHooks: a loopback stand-in of
#     Slack's hooks host) and requests the proof signs itself (NOT PROVEN LIVE: no public address):
#     - B0 the door off: POST /api/slack/actions answers 404;
#     - B1 the door on: serve logs 'the Slack door is on' with the app; a new post carries Acknowledge (value
#       '<key>|sb') and Mute 1 h with its confirm; 20 such alerts' blocks stay under half of the 256 KB cap;
#     - B2 a signed Acknowledge: 200; the stand-in hooks get one in_channel 'Acknowledged in pgvigil by <user>'; acks
#       holds the alert_ack by that user; ack_log's row has client 'slack:T0PROOF0001/U0PROOF0001' and slack_user;
#     - B3 another signed Acknowledge: an ephemeral 'Already acknowledged by'; B4 B2's exact request again: 200, nothing
#       new; B5 a bad signature, a stale timestamp, a JSON content type: 401 each, nothing at the hooks;
#     - B6 an unmapped Slack user: ephemeral 'not mapped'; a user mapped to no pgvigil user: 'disabled or gone';
#     - B7 Mute 1 h: in_channel 'Muted for 1 h', a mute of the key until about an hour on; again: 'Already muted until';
#     - B7b the occurrence's thread moved to a newer post: a click on its first post still finds it ('Already muted');
#     - B8 a click on a post whose occurrence cleared (a newer post carries the open one): ephemeral 'cleared at';
#     - B9 the link button's click: 200, nothing written, nothing at the hooks;
#     - B10 the door's reads (alert_threads, alert_state, acks, ack_alert_acked, ack_live) as a pgvigil_reader login.
#     NOT PROVEN through serve on a reader and an audit login: B's serve runs on the repository's superuser login (B10
#     runs the reads one by one; the write, import_ack, is the collector's, proof-ack.sh's part R). B's acks are ended
#     after it. Part Z runs before S, A and B (file order), so nothing they leave reaches it.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
: "${PGVIGIL_ADMIN_DSN:?}"
PART=${PGVIGIL_PROOF_PART:-MCRPOUZSAB}
SUF=$RANDOM
REPO=pgvigil_s2chan_$SUF
ALR=pgvigil_s2chan_alr_$SUF; RDR=pgvigil_s2chan_rdr_$SUF
PW=p$RANDOM$RANDOM$RANDOM; UIUSER=proofuser; UIPW=ui$RANDOM$RANDOM$RANDOM
WORK=$(mktemp -d); SRV=""; SINK=""; VEND=""; ZCLEAN=""; SLK=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SINK" ]] && kill "$SINK" 2>/dev/null || true
  [[ -n "$VEND" ]] && kill "$VEND" 2>/dev/null || true
  [[ -n "$SLK" ]] && kill "$SLK" 2>/dev/null || true
  if [[ -n "$ZCLEAN" ]]; then
    docker rm -f -v "$ZCLEAN-web" "$ZCLEAN-srv" "$ZCLEAN-db" >/dev/null 2>&1 || true
    docker network rm "$ZCLEAN" >/dev/null 2>&1 || true
  fi
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" \
    -c "drop role if exists $ALR" -c "drop role if exists $RDR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -E "(^|[:\]])$p$" >/dev/null || { echo "$p"; return; }
  done
  fail "no free port"
}
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
dsn() { echo "$PGVIGIL_ADMIN_DSN dbname=$REPO user=$1 password=$PW"; }
newrepo() {
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" >/dev/null
  export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
  "$BIN" migrate -config "$CFG" >"$WORK/m.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/m.log")"
  q "create role $ALR login password '$PW' in role pgvigil_alerter" >/dev/null
  q "create role $RDR login password '$PW' in role pgvigil_reader" >/dev/null
  export PGV_PROOF_ALERTS_DSN; PGV_PROOF_ALERTS_DSN=$(dsn "$ALR")
}
# pass <tag>: one `pgvigil alerts` pass; a failed send exits non-zero and is graded from alert_log, not from the exit
pass() {
  local tag=$1 rc
  set +e; "$BIN" alerts -config "$CFG" >"$WORK/pass.$tag.out" 2>"$WORK/pass.$tag.err"; rc=$?; set -e
  if grep -qE 'not read|not judged|not written' "$WORK/pass.$tag.out" || grep -qiE 'panic|SQLSTATE|ERROR:' "$WORK/pass.$tag.err"; then
    fail "pass $tag: exit $rc: $(cat "$WORK/pass.$tag.out") $(tr '\n' ' ' < "$WORK/pass.$tag.err" | cut -c1-600)"
  fi
}
# testreq <channel> <minutes ago>: one Send test request through the store's door, asked at that past minute
testreq() {
  local out
  out=$(q "select pgvigil.import_alert_test(now() - interval '$2 minutes', '{\"ui_user\":\"proof\",\"channel\":\"$1\"}'::jsonb)->>'detail'")
  [[ $(q "select outcome is null from pgvigil.alert_tests order by test_id desc limit 1") == t ]] || fail "the test of $1 was refused: $out"
}
# newest <channel>: the outcome and error of its newest Send test. A test's row counts no alert (alert_record counts
# firing, repeat and resolved items only); every alert send counts one at least, so the pass's alert sends after the
# test are skipped.
newest() { q "select outcome || '|' || coalesce(error, '') from pgvigil.alert_log where channel = '$1' and n_firing + n_repeat + n_resolved = 0 order by snapshot_at desc limit 1"; }

# ---- L: the real destinations (laptop only): the Slack incoming webhook, Pushover, Azure Monitor Logs -------------------
if [[ $PART == L ]]; then
  : "${PGVIGIL_BIN:?a binary cross-built on the lab box and fetched}"
  # the live channels this run has a secret for (the runner puts them in the environment from its secrets file)
  # az-live first: the one most likely to fail goes before the two a person sees (a rerun after a failure names only
  # the failed channel)
  live=()
  [[ -n ${PGV_LIVE_AZ_SECRET:-} ]] && live+=(az-live)
  [[ -n ${PGV_LIVE_SLACK:-} ]] && live+=(slack-live)
  [[ -n ${PGV_LIVE_PO_TOKEN:-} && -n ${PGV_LIVE_PO_USER:-} ]] && live+=(po-live)
  (( ${#live[@]} > 0 )) || fail "no live channel: the runner sets PGV_LIVE_SLACK, PGV_LIVE_PO_TOKEN with PGV_LIVE_PO_USER, or PGV_LIVE_AZ_SECRET"
  if [[ " ${live[*]} " == *" az-live "* ]]; then
    for v in PGV_LIVE_AZ_ENDPOINT PGV_LIVE_AZ_DCR PGV_LIVE_AZ_STREAM PGV_LIVE_AZ_TENANT PGV_LIVE_AZ_CLIENT; do
      [[ -n ${!v:-} ]] || fail "$v is not set (az-live needs the rule's endpoint, id and stream and the app's tenant and client id)"
    done
  fi
  avail=$(awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo)
  (( avail >= 4 )) || fail "MemAvailable ${avail} GB: under the 4 GB the lead's rule needs"
  for t in psql; do command -v $t >/dev/null || fail "$t is not on this machine"; done
  BIN=$PGVIGIL_BIN
  CFG=$WORK/cfg-live.yaml
  # each channel's quiet hours cover the day (a test is sent inside them, a finding is not) and its checks: list names
  # no check, so nothing but the test reaches the destination
  live_quiet="min_severity: critical, quiet_hours: \"00:00-23:59\", timezone: UTC, checks: [proof-none-$SUF]"
  {
    printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\nalerts_dsn: env:PGV_PROOF_ALERTS_DSN\nalerts:\n'
    for c in "${live[@]}"; do
      case $c in
        slack-live) echo "  - {name: slack-live, kind: webhook, $live_quiet, webhook: {url: env:PGV_LIVE_SLACK, format: slack}}" ;;
        po-live) echo "  - {name: po-live, kind: pushover, $live_quiet, pushover: {token: env:PGV_LIVE_PO_TOKEN, user: env:PGV_LIVE_PO_USER}}" ;;
        az-live) echo "  - {name: az-live, kind: azuremonitor, $live_quiet, azuremonitor: {endpoint: \"$PGV_LIVE_AZ_ENDPOINT\", dcr_id: $PGV_LIVE_AZ_DCR, stream: $PGV_LIVE_AZ_STREAM, tenant: $PGV_LIVE_AZ_TENANT, client_id: $PGV_LIVE_AZ_CLIENT, client_secret: env:PGV_LIVE_AZ_SECRET, cloud: public}}" ;;
      esac
    done
  } > "$CFG"
  newrepo
  pass L0
  [[ $(q "select count(*) from pgvigil.alert_log") == 0 ]] || fail "L: pass 0 sent something: $(q "select string_agg(channel || ':' || outcome, ' ') from pgvigil.alert_log")"
  # one Send test per channel, one at a time (a test waits for the pass that answers it)
  for c in "${live[@]}"; do
    testreq "$c" 1
    pass "L-$c"
    got=$(q "select string_agg(outcome, ',' order by snapshot_at) from pgvigil.alert_log where channel = '$c'")
    [[ $got == test ]] || fail "L: $c's attempts: '$got' (wanted one 'test'): $(newest "$c" | cut -d'|' -f2 | cut -c1-300)"
    ok "L: $c: one Send test through the changed sender, answered by the real destination; nothing else sent"
    # the test's finding key, which the destination carries (Azure's FindingKey column): a reader matches this run's row
    echo "L: $c sent finding key test-$(q "select max(test_id) from pgvigil.alert_tests where channel = '$c'")"
  done
  echo "L: test sent at $(q "select to_char(max(snapshot_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') from pgvigil.alert_log")"
  exit 0
fi

for t in psql curl python3 ss go tar git; do command -v $t >/dev/null || fail "$t is not on this machine"; done
# ---- the binary -------------------------------------------------------------------------------------------------------
TREE=$WORK/tree; mkdir -p "$TREE"
tar --exclude=./.git --exclude=./web/node_modules --exclude=./bin -cf - . | tar -xf - -C "$TREE"
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
if (cd "$TREE" && git apply --check "$ROOT/scripts/proof-alert-scope-wiring.patch" 2>/dev/null); then
  (cd "$TREE" && git apply "$ROOT/scripts/proof-alert-scope-wiring.patch") || fail "the wiring patch"
  ok "wiring patch applied to the build's copy"
elif (cd "$TREE" && git apply -R --check "$ROOT/scripts/proof-alert-scope-wiring.patch" 2>/dev/null); then
  ok "the tree already holds the wiring"
elif joined_wiring "$TREE"; then
  ok "the tree holds the wiring in a join's own words (a line of each of the patch's 12 hunks found)"
else
  fail "the wiring patch neither applies nor is applied"
fi
BIN=$WORK/pgvigil
(cd "$TREE" && go build -o "$BIN" ./cmd/pgvigil) || fail "go build"

# ---- the sink: loopback HTTP, per path queue (/r, /c) of answers, every request logged ---------------------------------
cat > "$WORK/sink.py" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8', 'replace')
        qn = self.path.strip('/').split('/')[0]
        with open(os.path.join(work, 'sink.%s.log' % qn), 'a') as f:
            f.write(json.dumps({'t': time.time(), 'path': self.path, 'body': body}) + '\n')
        ans = ''
        qf = os.path.join(work, 'answers.%s' % qn)
        if os.path.exists(qf):
            lines = open(qf).read().splitlines()
            if lines:
                ans, rest = lines[0], lines[1:]
                open(qf, 'w').write(''.join(l + '\n' for l in rest))
        if not ans:
            df = os.path.join(work, 'default.%s' % qn)
            ans = open(df).read().strip() if os.path.exists(df) else '200'
        if ans.startswith('429:'):
            self.send_response(429)
            if ans[4:]:
                self.send_header('Retry-After', ans[4:])
        elif ans == '500':
            self.send_response(500)
        else:
            self.send_response(200)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'ok')
ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
SPORT=$(freeport)
python3 "$WORK/sink.py" "$WORK" "$SPORT" & SINK=$!
for n in $(seq 1 40); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$SPORT/x/ping" && break
  [[ $n == 40 ]] && fail "the sink did not answer"
  sleep 0.25
done
export PGV_PROOF_HOOK_R="http://127.0.0.1:$SPORT/r/token-$SUF" PGV_PROOF_HOOK_C="http://127.0.0.1:$SPORT/c/token-$SUF"
mkdir -p "$WORK/drop"
CFG=$WORK/cfg.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: hook, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_HOOK_R, format: json}}
  - {name: hook2, kind: webhook, min_severity: warning, clear_after: 0, webhook: {url: env:PGV_PROOF_HOOK_C, format: json}}
  - {name: drop, kind: file, min_severity: warning, clear_after: 0, file: {dir: $WORK/drop}}
EOF

# ---- M: the store ------------------------------------------------------------------------------------------------------
newrepo
[[ $(q "select pg_get_viewdef('pgvigil.alert_findings'::regclass)") == *alert_channel_findings* ]] || fail "M: alert_findings does not read alert_channel_findings (the wiring's third arm)"
[[ $(q "select pg_get_viewdef('pgvigil.alert_channel_findings'::regclass)") == *alert_channel_failing*alert_channel_quota_low* ]] || fail "M: alert_channel_findings is not the failing and quota views"
[[ $(q "select to_regclass('pgvigil.alert_log_channel_at_idx') is not null") == t ]] || fail "M: no index alert_log_channel_at_idx"
q "select count(*) from pgvigil.alert_channel_failing" >/dev/null || fail "M: alert_channel_failing does not answer"
[[ $(psql "$PGV_PROOF_ALERTS_DSN" -XAt -c "select count(*) >= 0 from pgvigil.alert_findings" 2>&1) == t ]] || fail "M: the alerter cannot read alert_findings"
ok "M: alert_findings reads alert_channel_findings; the index stands; the alerter reads it"

pass sync0   # records the channels (the Send test door needs them), the sink answers 200

# ---- C: 'alert channel failing' -----------------------------------------------------------------------------------------
if [[ $PART == *C* ]]; then
echo 500 > "$WORK/default.c"
streak() {   # failed or refused attempts of hook2 in a row, newest first
  q "select count(*) from (select outcome, sum((outcome not in ('failed', 'refused'))::int) over (order by snapshot_at desc) as okseen
       from pgvigil.alert_log where channel = 'hook2' and outcome in ('sent', 'failed', 'refused', 'test')) x where okseen = 0"
}
dropfiles() { grep -l '"alert channel failing"' "$WORK/drop"/* 2>/dev/null | xargs -r grep -l "\"$1\"" 2>/dev/null | xargs -r grep -l '"hook2"' 2>/dev/null | wc -l; }
reached=""
for k in 1 2 3 4 5 6; do
  testreq hook2 $((55 - 3 * k))
  pass "C$k"
  if (( $(streak) >= 3 )); then reached=$k; break; fi
  (( $(dropfiles firing) == 0 )) || fail "C: drop got 'alert channel failing' with only $(streak) failure(s) in a row"
done
[[ -n $reached ]] || fail "C: hook2 never reached 3 failures in a row: $(streak)"
[[ $(dropfiles firing) == 1 ]] || fail "C: the pass of the third failure: $(dropfiles firing) firing file(s) on drop (the tests go first)"
f=$(grep -l '"alert channel failing"' "$WORK/drop"/* | xargs grep -l '"firing"' | sed -n 1p)
python3 - "$f" "$SPORT" <<'PY' || fail "C: the firing file's fields: $(head -c 800 "$f")"
import json, sys
d = json.load(open(sys.argv[1]))
a = d['alerts'][0] if 'alerts' in d else d
det = a.get('detail', '')
assert a['setting'] == 'alert channel failing' and a['value'] == 'hook2' and a['severity'] == 'warning', a
assert a['source'] == 'pgvigil repository' and d.get('sender') == 'pgvigil', a
assert det.startswith('alert channel failing: webhook to http://127.0.0.1:%s (json), the last 3 sends failed, the newest at ' % sys.argv[2]), det
assert '500' in det and 'token-' not in det, det
PY
! grep -q 'alert channel failing' "$WORK/sink.c.log" || fail "C: hook2 was sent its own failing alert"
[[ $(q "select count(*) from pgvigil.alert_state where setting = 'alert channel failing' and channel in ('hook', 'hook2')") == 0 ]] || fail "C: hook or hook2 holds an alert_state row of it"
[[ $(q "select (select at from pgvigil.alert_channel_failing where value = 'hook2') = (select min(snapshot_at) from pgvigil.alert_log where channel = 'hook2' and outcome in ('failed', 'refused'))") == t ]] || fail "C: alert_channel_failing's at is not hook2's first failed attempt"
pass C-again
[[ $(dropfiles firing) == 1 ]] || fail "C: a second firing file on drop"
echo 200 > "$WORK/default.c"
testreq hook2 2
pass C-ok
[[ $(newest hook2 | cut -d'|' -f1) == test ]] || fail "C: the recovering test: $(newest hook2)"
[[ $(dropfiles resolved) == 1 ]] || fail "C: drop's recovery files in the recovering test's pass: $(dropfiles resolved)"
[[ $(q "select count(*) from pgvigil.alert_channel_failing where value = 'hook2'") == 0 ]] || fail "C: hook2 still failing"
pass C-recover
[[ $(dropfiles resolved) == 1 ]] || fail "C: a second recovery file on drop: $(dropfiles resolved)"
ok "C: after 3 failed attempts in a row drop is told once, hook2 and hook (floor critical) are not; the recovery once"
fi

# ---- R: Retry-After -----------------------------------------------------------------------------------------------------
if [[ $PART == *R* ]]; then
rreqs() { python3 - "$WORK/sink.r.log" "$1" <<'PY'
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1])]
except FileNotFoundError:
    rows = []
rows = [r for r in rows if 'test message' in r['body']][int(sys.argv[2]):]
gap = rows[1]['t'] - rows[0]['t'] if len(rows) > 1 else 0
same = len(rows) < 2 or rows[0]['body'] == rows[1]['body']
print('%d %.1f %s' % (len(rows), gap, same))
PY
}
seen=0
rrow() {     # rrow <name> <answers> <minutes ago> <requests> <outcome> <error words or ''> [<least gap s>]
  local got n gap same
  printf '%b' "$2" > "$WORK/answers.r"
  testreq hook "$3"
  pass "$1"
  read -r n gap same <<<"$(rreqs $seen)"
  got=$(newest hook)
  [[ $n == "$4" && $same == True ]] || fail "$1: $n request(s) (same body $same), wanted $4"
  [[ ${got%%|*} == "$5" ]] || fail "$1: outcome '$got', wanted $5"
  [[ -z $6 || $got == *"$6"* ]] || fail "$1: error '$got' does not say '$6'"
  [[ $got != *token-* ]] || fail "$1: the error names the URL's path: $got"
  [[ -z ${7:-} ]] || python3 -c "import sys; sys.exit(0 if float('$gap') >= $7 else 1)" || fail "$1: the retry came $gap s after the first post (wanted >= $7)"
  seen=$((seen + n))
}
rrow R1 '429:2\n200\n' 40 2 test '' 1.9
rrow R2 '429:30\n' 37 1 failed 'more than the 10s a send waits'
rrow R3 '429:1\n429:1\n' 34 2 failed 'after waiting out a Retry-After of 1s'
rrow R4 '429:\n' 31 1 failed 'no Retry-After'
rrow R5 '500\n200\n' 28 1 failed '500'
ok "R: a short Retry-After waited out and posted once more; a long, missing or second one, and a 500, fail that send"
fi

# ---- P: alert_history -----------------------------------------------------------------------------------------------------
if [[ $PART == *P* ]]; then
IA=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
        values ('proof-chan-a-$SUF', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | sed -n 1p)
IB=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
        values ('proof-chan-b-$SUF', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | sed -n 1p)
IC=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
        values ('proof-chan-c-$SUF', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | sed -n 1p)
st() {   # st <instance id> <key prefix> <n> <fired SQL> <cleared SQL or NULL>
  q "insert into pgvigil.alert_state (channel, finding_key, instance_id, instance_name, source, setting, value, severity,
       first_sent_at, last_sent_at, cleared_at)
     select 'drop', '$2' || g, $1, (select name from pgvigil.instances where instance_id = $1), 'proof', 'check ' || g, 'v',
            'warning', $4 + g * interval '1 second', $4 + g * interval '1 second', $5
       from generate_series(1, $3) g" >/dev/null
}
st "$IB" pb 1001 "now() - interval '1 hour'" NULL
st "$IC" pc 1000 "now() - interval '1 hour'" NULL
st "$IA" pa 2 "now() - interval '30 minutes'" NULL
st "$IA" pold 1 "now() - interval '100 days'" "now() - interval '99 days'"
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
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
FROM=$(date -u -d '-90 days' +%FT%TZ); TO=$(date -u +%FT%TZ)
alerts() {   # alerts <instance id or ''>: 'code rows cut'
  local c
  c=$(curl -s -b "$JAR" -o "$WORK/a.json" -w '%{http_code}' "$U/api/alertscope?part=alerts&from=$FROM&to=$TO${1:+&instance_id=$1}")
  if [[ $c != 200 ]]; then echo "$c 0 -"; return; fi
  python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["alerts"]; c=t["columns"]; r=t["rows"]; print(sys.argv[2], len(r), any(x[c.index("cut")] for x in r))' "$WORK/a.json" "$c"
}
[[ $(alerts "$IA") == "200 2 False" ]] || fail "P: instance A's alerts: $(alerts "$IA")"
[[ $(alerts "$IB") == "200 1000 True" ]] || fail "P: instance B's alerts: $(alerts "$IB")"
[[ $(alerts "$IC") == "200 1000 False" ]] || fail "P: instance C's exactly 1,000 alerts: $(alerts "$IC")"
[[ $(alerts "") == 400* ]] && grep -qF 'part alerts needs instance_id' "$WORK/a.json" || fail "P: part alerts without an instance: $(cat "$WORK/a.json")"
kill "$SRV" 2>/dev/null || true; SRV=""
mcpcall() {  # mcpcall <arguments json>: the tool's reply (the result's text, or 'ERROR <text>')
  local in=$WORK/mcp.in
  {
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"proof-chan","version":"1"}}}'
    echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    echo "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"alert_history\",\"arguments\":$1}}"
  } > "$in"
  PGVIGIL_MCP_DSN="$(dsn "$RDR")" timeout 60 "$BIN" mcp <"$in" >"$WORK/mcp.out" 2>"$WORK/mcp.err" || true
  python3 - "$WORK/mcp.out" <<'PY'
import json, sys
got = {}
for l in open(sys.argv[1]):
    l = l.strip()
    if l:
        m = json.loads(l)
        got[m.get('id')] = m
names = [t['name'] for t in got.get(2, {}).get('result', {}).get('tools', [])]
if 'alert_history' not in names:
    print('NOTLISTED ' + ','.join(names)); sys.exit()
r = got.get(3, {})
if 'error' in r:
    print('ERROR ' + json.dumps(r['error'])); sys.exit()
res = r.get('result', {})
text = ''.join(c.get('text', '') for c in res.get('content', []))
print(('ERROR ' if res.get('isError') else '') + text.replace('\n', ' '))
PY
}
out=$(mcpcall "{\"instance\":\"proof-chan-a-$SUF\",\"hours\":2160}")
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["alerts"]) == 2, d["alerts"]
assert all(not r["finding_key"].startswith("pold") for r in d["alerts"]), d["alerts"]
assert isinstance(d.get("findings_history"), list), d
' "$out" || fail "P: alert_history of A over 2160 hours: $(echo "$out" | cut -c1-600)"
out=$(mcpcall "{\"instance\":\"proof-chan-a-$SUF\",\"hours\":2161}")
[[ $out == ERROR* && $out == *2160* ]] || fail "P: 2161 hours: $(echo "$out" | cut -c1-300)"
out=$(mcpcall "{\"instance\":\"proof-chan-a-$SUF\",\"from\":\"$(date -u -d '-91 days' +%FT%TZ)\",\"to\":\"$TO\"}")
[[ $out == ERROR* && $out == *"90 days"* ]] || fail "P: 91 days: $(echo "$out" | cut -c1-300)"
ok "P: the instance's alerts filtered before the limit; the MCP tool over 90 days and its bounds"
fi
# ---- a seeded instance and its rule findings (O, U, Z) -------------------------------------------------------------------
if [[ $PART == *O* || $PART == *U* || $PART == *Z* || $PART == *S* || $PART == *A* || $PART == *B* ]]; then
INSTH=proof-chan-h-$SUF
HID=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         values ('$INSTH', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | sed -n 1p)
RID=""
# endall: every live rule of the seeded instance ended, found by query (newfinding runs inside $(...), a subshell, so a
# rule id it keeps in a variable never reaches the next call)
endall() {
  local id
  for id in $(q "select rule_id from pgvigil.alert_rules where ended_at is null and instance_name = '$INSTH'"); do
    q "select pgvigil.import_alert_rule(now(), '{\"op\":\"end\",\"ui_user\":\"proof\",\"rule_id\":$id}'::jsonb)->>'outcome'" >/dev/null
  done
}
# newfinding <critical threshold 5-10>: every live rule of the seeded instance ended, a new one on a metric of its own
# (critical at the threshold) judged on a fresh sample; prints the one rule finding of the seeded instance. Each
# threshold has its own metric: a finding's key turns its numbers into '#', so two rules on one metric make one key,
# and the next row would see the last row's alert still open instead of a new one.
newfinding() {
  local k m
  case $1 in
    5) m=sessions.idle_in_txn ;; 6) m=sessions.total ;; 7) m=sessions.active ;; 8) m=sessions.longest_active_secs ;;
    9) m=sessions.longest_idle_txn_secs ;; 10) m=sessions.oldest_xmin_age ;; *) fail "newfinding: no metric for threshold $1" ;;
  esac
  endall
  RID=$(q "select pgvigil.import_alert_rule(now(), '{\"op\":\"add\",\"ui_user\":\"proof\",\"metric\":\"$m\",\"op_dir\":\"above\",\"warning\":$(( $1 - 1 )),\"critical\":$1,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}'::jsonb)->>'rule_id'")
  [[ $RID =~ ^[0-9]+$ ]] || fail "the rule on $m above $1 was not made: $RID"
  # every metric of the six over 10: total 60, active 20, idle_in_txn 50, longest active 30 s, longest idle in
  # transaction 40 s, oldest xmin age 70
  q "insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
       active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
     values ($HID, now() - interval '5 seconds', 60, 20, 5, 50, 0, 0, 0, 30, 40, 70, 100)" >/dev/null
  q "select pgvigil.alert_rules_run(now())" >/dev/null
  k=$(q "select string_agg(finding_key, ',') from pgvigil.alert_findings where instance_id = $HID and source = 'alert rule' and severity = 'critical'")
  [[ $k =~ ^[0-9a-f]+$ ]] || fail "the rule on $m above $1: its finding is '$k' (wanted one critical key)"
  echo "$k"
}
newest_alert() { q "select outcome || '|' || coalesce(error, '') from pgvigil.alert_log where channel = '$1' and n_firing + n_repeat + n_resolved > 0 order by snapshot_at desc limit 1"; }
dropcount() { grep -l "\"$1\"" "$WORK/drop"/* 2>/dev/null | xargs -r grep -l "\"$2\"" 2>/dev/null | xargs -r grep -l "\"$3\"" 2>/dev/null | wc -l; }
# the vendors' stubs on loopback: Pushover's Messages API and Azure's token endpoint and Logs Ingestion upload
AZTEN=0c0ffee0-0b24-4000-8000-00000000b24c; AZCID=00001111-aaaa-2222-bbbb-3333cccc4444; AZDCR=dcr-0123456789abcdef0123456789abcdef
export PGV_PROOF_PO_TOKEN=azGDORePK8gMaC0QOYAMyEE$SUF PGV_PROOF_PO_USER=uQiRzpo4DXghDmr9QzzfQu$SUF PGV_PROOF_AZ_SECRET=s3cr3t-$SUF-$RANDOM
cat > "$WORK/vendor.py" <<'PY'
import json, os, sys, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, port, tenant, dcr = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
def mode(name, default):
    p = os.path.join(work, name)
    return open(p).read().strip() if os.path.exists(p) else default
def log(name, rec):
    with open(os.path.join(work, name), 'a') as f:
        f.write(json.dumps(rec) + '\n')
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, body, hdr=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        for k, v in (hdr or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8', 'replace')
        u = urllib.parse.urlparse(self.path)
        if u.path == '/1/messages.json':
            # Pushover's API page states: 200 with status 1, the X-Limit-App-* headers, 429 when the month is used
            # up, 4xx for a bad request. ASSUMED (not stated): that a 429 carries X-Limit-App-Reset, and the bodies'
            # exact words below.
            form = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
            log('po.log', form)
            m = mode('po.mode', '200')
            if m == '429':
                return self.answer(429, '{"status":0,"errors":["application has exceeded its monthly limit"]}', {'X-Limit-App-Reset': str(int(time.time()) + 3600)})
            if m == '400':
                return self.answer(400, '{"user":"invalid","errors":["user identifier is not a valid user, group, or subscribed user key"],"status":0}')
            return self.answer(200, '{"status":1,"request":"5042853c-402d-4a18-abcb-168734a801de"}',
                               {'X-Limit-App-Limit': '10000', 'X-Limit-App-Remaining': mode('po.left', '9000'), 'X-Limit-App-Reset': str(int(time.time()) + 30 * 86400)})
        # Entra's token endpoint (client credentials) and the Logs Ingestion upload: the tutorial's shapes; ASSUMED
        # (not on the pages read): the 400 body's exact words.
        if u.path == '/%s/oauth2/v2.0/token' % tenant:
            form = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
            n = sum(1 for _ in open(os.path.join(work, 'aztok.log'))) + 1 if os.path.exists(os.path.join(work, 'aztok.log')) else 1
            log('aztok.log', form)
            return self.answer(200, json.dumps({'token_type': 'Bearer', 'expires_in': 3599, 'access_token': 'proof-token-%d' % n}))
        if u.path == '/dataCollectionRules/%s/streams/Custom-PgvigilAlerts' % dcr:
            log('azup.log', {'query': u.query, 'auth': self.headers.get('Authorization'), 'type': self.headers.get('Content-Type'), 'body': raw})
            if mode('az.mode', '204') == '400':
                return self.answer(400, '{"error":{"code":"InvalidStream","message":"The stream Custom-PgvigilAlerts is not declared in the rule"}}')
            self.send_response(204)
            self.end_headers()
            return
        self.answer(404, '{}')
ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
VPORT=$(freeport)
python3 "$WORK/vendor.py" "$WORK" "$VPORT" "$AZTEN" "$AZDCR" & VEND=$!
for n in $(seq 1 40); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$VPORT/x" && break
  [[ $n == 40 ]] && fail "the vendors' stub did not answer"
  sleep 0.25
done
posts() { [[ -f "$WORK/po.log" ]] && wc -l < "$WORK/po.log" || echo 0; }
fi

# ---- O: Pushover (stub) ---------------------------------------------------------------------------------------------------
if [[ $PART == *O* ]]; then
POLINE="  - {name: po, kind: pushover, min_severity: critical, instances: [$INSTH], pushover: {token: env:PGV_PROOF_PO_TOKEN, user: env:PGV_PROOF_PO_USER, url: http://127.0.0.1:$VPORT}}"
cp "$CFG" "$WORK/cfg.base.yaml"; echo "$POLINE" >> "$CFG"
echo 200 > "$WORK/po.mode"; echo 500 > "$WORK/po.left"
K1=$(newfinding 5)
pass O1
[[ $(newest_alert po | cut -d'|' -f1) == sent ]] || fail "O1: po's attempt: $(newest_alert po)"
python3 - "$WORK/po.log" "$K1" "$INSTH" <<'PY' || fail "O1: the post's fields: $(tail -1 "$WORK/po.log" | cut -c1-500)"
import json, os, sys
f = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert f['token'] == os.environ['PGV_PROOF_PO_TOKEN'] and f['user'] == os.environ['PGV_PROOF_PO_USER'], f
assert f['priority'] == '1' and sys.argv[3] in f['message'] and f['title'], f
PY
[[ $(q "select remaining || '/' || quota from pgvigil.alert_channel_quota where channel = 'po'") == 500/10000 ]] || fail "O1: the quota row: $(q "select * from pgvigil.alert_channel_quota")"
pass O1b
[[ $(dropcount 'pushover quota low' firing po) == 1 ]] || fail "O1: drop's 'pushover quota low' files: $(dropcount 'pushover quota low' firing po)"
echo 429 > "$WORK/po.mode"; echo 9000 > "$WORK/po.left"
K2=$(newfinding 6)
pass O2
got=$(newest_alert po)
[[ ${got%%|*} == failed && ${got#*|} =~ ^held\ until\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z:\  ]] || fail "O2: the 429's attempt: $got"
n0=$(posts)
pass O2b
[[ $(posts) == "$n0" ]] || fail "O2: a post while held by the 429"
grep -q 'held by the destination: po:' "$WORK/pass.O2b.out" || fail "O2: the pass does not say po is held: $(cat "$WORK/pass.O2b.out")"
[[ $(dropcount 'alert channel failing' firing po) == 1 ]] || fail "O2: drop's 'alert channel failing' of the held po: $(dropcount 'alert channel failing' firing po) (wanted 1); the view: $(q "select severity || ' ' || detail from pgvigil.alert_channel_failing where value = 'po'")"
echo 200 > "$WORK/po.mode"
testreq po 20
pass O2c
[[ $(newest po | cut -d'|' -f1) == test ]] || fail "O2: the Send test: $(newest po)"
[[ $(newest_alert po | cut -d'|' -f1) == sent ]] || fail "O2: the owed alert after the test: $(newest_alert po)"
[[ $(dropcount 'alert channel failing' resolved po) == 1 ]] || fail "O2: drop's recovery of po's hold: $(dropcount 'alert channel failing' resolved po)"
echo 400 > "$WORK/po.mode"
K3=$(newfinding 7)
pass O3
[[ $(newest_alert po) == "failed|held until the configuration changes ("* ]] || fail "O3: the 400's attempt: $(newest_alert po)"
n0=$(posts)
pass O3b
[[ $(posts) == "$n0" ]] || fail "O3: a post while held by the 400"
[[ $(dropcount 'alert channel failing' firing po) == 2 ]] || fail "O3: drop's 'alert channel failing' of po held by the 400: $(dropcount 'alert channel failing' firing po) firing file(s) (wanted 2)"
cp "$WORK/cfg.base.yaml" "$CFG"; echo "${POLINE%\}\}}, device: proof1}}" >> "$CFG"
echo 200 > "$WORK/po.mode"
pass O3c
[[ $(newest_alert po | cut -d'|' -f1) == sent ]] || fail "O3: after the configuration changed: $(newest_alert po)"
[[ $(tail -1 "$WORK/po.log" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("device",""))') == proof1 ]] || fail "O3: the post after the change has no device proof1"
pass O3d
[[ $(dropcount 'alert channel failing' resolved po) == 2 ]] || fail "O3: drop's recovery after the configuration changed: $(dropcount 'alert channel failing' resolved po)"
cp "$WORK/cfg.base.yaml" "$CFG"
ok "O: Pushover sent with its fields and quota; quota low raised; a 429 held until its reset or a test; a 400 until the configuration changed"
fi

# ---- U: Azure Monitor Logs (stub) -----------------------------------------------------------------------------------------
if [[ $PART == *U* ]]; then
cp "$CFG" "$WORK/cfg.base.yaml"
echo "  - {name: az, kind: azuremonitor, min_severity: critical, instances: [$INSTH], azuremonitor: {endpoint: http://127.0.0.1:$VPORT, dcr_id: $AZDCR, stream: Custom-PgvigilAlerts, tenant: $AZTEN, client_id: $AZCID, client_secret: env:PGV_PROOF_AZ_SECRET, login_url: http://127.0.0.1:$VPORT}}" >> "$CFG"
echo 204 > "$WORK/az.mode"
K4=$(newfinding 8)
pass U1
[[ $(newest_alert az | cut -d'|' -f1) == sent ]] || fail "U1: az's attempt: $(newest_alert az)"
python3 - "$WORK" "$K4" "$AZCID" "$AZDCR" <<'PY' || fail "U1: the stub's requests: $(cat "$WORK/aztok.log" "$WORK/azup.log" 2>/dev/null | cut -c1-400)"
import json, os, sys
w, key, cid = sys.argv[1], sys.argv[2], sys.argv[3]
toks = [json.loads(l) for l in open(os.path.join(w, 'aztok.log'))]
ups = [json.loads(l) for l in open(os.path.join(w, 'azup.log'))]
assert len(toks) == 1, toks
t = toks[0]
assert t['grant_type'] == 'client_credentials' and t['scope'] == 'https://monitor.azure.com//.default' and t['client_id'] == cid, t
assert t['client_secret'] == os.environ['PGV_PROOF_AZ_SECRET'], 'the secret'
assert len(ups) == 1 and ups[0]['query'] == 'api-version=2023-01-01' and ups[0]['auth'] == 'Bearer proof-token-1', ups
rows = json.loads(ups[0]['body'])
assert any(r['FindingKey'] == key and r['Severity'] == 'critical' for r in rows), rows
PY
echo 400 > "$WORK/az.mode"
K5=$(newfinding 9)
pass U2
[[ $(newest_alert az) == failed*InvalidStream* ]] || fail "U2: the 400's attempt: $(newest_alert az)"
cp "$WORK/cfg.base.yaml" "$CFG"
ok "U: Azure Monitor Logs: one token, one upload with the row; a 400 with Azure's words"
fi

# ---- Z: Zabbix live in containers -----------------------------------------------------------------------------------------
if [[ $PART == *Z* ]]; then
for t in docker openssl; do command -v $t >/dev/null || fail "$t is not on this machine (part Z)"; done
ZN=pgv-zbx-$SUF; ZPW=z$RANDOM$RANDOM; ZENC=$WORK/zenc; mkdir -p "$ZENC"
ZCLEAN="$ZN"
# a CA, the server's certificate (no Subject Alternative Name: Zabbix reads none) and the sending host's (CN=pgvigil-proof)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=pgvigil proof CA" -keyout "$ZENC/ca.key" -out "$ZENC/ca.pem" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$ZN-srv" -keyout "$ZENC/server.key" -out "$ZENC/server.csr" 2>/dev/null
printf 'extendedKeyUsage=serverAuth\n' > "$ZENC/srv.ext"
openssl x509 -req -in "$ZENC/server.csr" -CA "$ZENC/ca.pem" -CAkey "$ZENC/ca.key" -CAcreateserial -days 1 -extfile "$ZENC/srv.ext" -out "$ZENC/server.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=pgvigil-proof" -keyout "$ZENC/client.key" -out "$ZENC/client.csr" 2>/dev/null
printf 'extendedKeyUsage=clientAuth\n' > "$ZENC/cli.ext"
openssl x509 -req -in "$ZENC/client.csr" -CA "$ZENC/ca.pem" -CAkey "$ZENC/ca.key" -CAcreateserial -days 1 -extfile "$ZENC/cli.ext" -out "$ZENC/client.crt" 2>/dev/null
chmod 644 "$ZENC"/*   # the container's zabbix user reads them (throwaway keys of this run)
ZP1=$(freeport); ZP2=$(freeport)
docker network create "$ZN" >/dev/null
docker run -d --name "$ZN-db" --network "$ZN" -e POSTGRES_USER=zabbix -e POSTGRES_PASSWORD="$ZPW" -e POSTGRES_DB=zabbix postgres:16-alpine >/dev/null
docker run -d --name "$ZN-srv" --network "$ZN" -e DB_SERVER_HOST="$ZN-db" -e POSTGRES_USER=zabbix -e POSTGRES_PASSWORD="$ZPW" -e POSTGRES_DB=zabbix \
  -e ZBX_TLSCAFILE=ca.pem -e ZBX_TLSCERTFILE=server.crt -e ZBX_TLSKEYFILE=server.key -e ZBX_CACHEUPDATEFREQUENCY=5 \
  -v "$ZENC:/var/lib/zabbix/enc:ro" -p "127.0.0.1:$ZP1:10051" zabbix/zabbix-server-pgsql:alpine-7.0-latest >/dev/null
docker run -d --name "$ZN-web" --network "$ZN" -e ZBX_SERVER_HOST="$ZN-srv" -e DB_SERVER_HOST="$ZN-db" -e POSTGRES_USER=zabbix \
  -e POSTGRES_PASSWORD="$ZPW" -e POSTGRES_DB=zabbix -e PHP_TZ=UTC -p "127.0.0.1:$ZP2:8080" zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest >/dev/null
cat > "$WORK/zapi.py" <<'PY'
import json, sys, urllib.request
url, auth, method, params = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
req = urllib.request.Request(url, data=json.dumps({'jsonrpc': '2.0', 'method': method, 'params': json.loads(params), 'id': 1}).encode(),
                             headers={'Content-Type': 'application/json-rpc', **({'Authorization': 'Bearer ' + auth} if auth else {})})
try:
    ans = json.loads(urllib.request.urlopen(req, timeout=20).read())
except Exception as e:
    print('ERROR %s' % e); sys.exit(1)
if 'error' in ans:
    print('ERROR %s' % json.dumps(ans['error'])); sys.exit(1)
print(json.dumps(ans['result']))
PY
ZURL="http://127.0.0.1:$ZP2/api_jsonrpc.php"
zapi() { python3 "$WORK/zapi.py" "$ZURL" "${ZAUTH:-}" "$1" "$2"; }
for n in $(seq 1 120); do
  zapi apiinfo.version '{}' >/dev/null 2>&1 && break
  [[ $n == 120 ]] && fail "Z: the Zabbix API did not answer in 6 minutes: $(docker logs --tail 5 "$ZN-srv" 2>&1)"
  sleep 3
done
ZAUTH=""; ZAUTH=$(zapi user.login '{"username":"Admin","password":"zabbix"}' | tr -d '"') || fail "Z: user.login: $ZAUTH"
GID=$(zapi hostgroup.create "{\"name\":\"pgvigil proof $SUF\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["groupids"][0])') || fail "Z: hostgroup.create"
mkhost() {   # mkhost <host> <tls_accept 1|4> <trapper_hosts>: the host and its two trapper items (pgvigil.alert text, pgvigil.probe); the alert item's id
  local hid extra=""
  [[ $2 == 4 ]] && extra=',"tls_accept":4,"tls_connect":1,"tls_subject":"CN=pgvigil-proof"'
  hid=$(zapi host.create "{\"host\":\"$1\",\"groups\":[{\"groupid\":\"$GID\"}]$extra}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hostids"][0])') || fail "Z: host.create $1"
  zapi item.create "{\"name\":\"probe\",\"key_\":\"pgvigil.probe\",\"hostid\":\"$hid\",\"type\":2,\"value_type\":4,\"trapper_hosts\":\"$3\"}" >/dev/null || fail "Z: the probe item of $1"
  zapi item.create "{\"name\":\"pgvigil alerts\",\"key_\":\"pgvigil.alert\",\"hostid\":\"$hid\",\"type\":2,\"value_type\":4,\"trapper_hosts\":\"$3\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["itemids"][0])' || fail "Z: the alert item of $1"
}
ZI1=$(mkhost pgvigil-proof 1 "")
ZI2=$(mkhost pgvigil-proof-tls 4 "")
ZI3=$(mkhost pgvigil-proof-deny 1 "192.0.2.1")
UID1=$(zapi user.get '{"filter":{"username":["Admin"]},"output":["userid"]}' | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["userid"])')
TID=$(zapi token.create "{\"name\":\"pgvigil proof $SUF\",\"userid\":\"$UID1\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tokenids"][0])') || fail "Z: token.create"
export PGV_PROOF_ZBX_TOKEN; PGV_PROOF_ZBX_TOKEN=$(zapi token.generate "[\"$TID\"]" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["token"])') || fail "Z: token.generate"
# the server takes the new hosts from its configuration cache: a probe value until it is processed (at most 2 minutes)
probe() { python3 - "$ZP1" <<'PY'
import json, socket, struct, sys
d = json.dumps({'request': 'sender data', 'data': [{'host': 'pgvigil-proof', 'key': 'pgvigil.probe', 'value': 'probe'}]}).encode()
s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=10)
s.sendall(b'ZBXD\x01' + struct.pack('<II', len(d), 0) + d)
b = b''
while True:
    c = s.recv(65536)
    if not c: break
    b += c
print(json.loads(b[13:]).get('info', ''))
PY
}
for n in $(seq 1 40); do
  [[ $(probe 2>/dev/null) == "processed: 1;"* ]] && break
  [[ $n == 40 ]] && fail "Z: the server never took the proof's host: $(probe 2>&1 | tail -1); the server's log: $(docker logs --tail 30 "$ZN-srv" 2>&1)"
  sleep 3
done
cp "$CFG" "$WORK/cfg.base.yaml"
cat >> "$CFG" <<EOF
  - {name: zbx, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof}}
  - {name: zbxtls, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof-tls, tls_ca: $ZENC/ca.pem, tls_cert: $ZENC/client.crt, tls_key: $ZENC/client.key, tls_server_subject: "CN=$ZN-srv", tls_server_issuer: "CN=pgvigil proof CA"}}
  - {name: zbxname, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof-tls, tls_ca: $ZENC/ca.pem, tls_cert: $ZENC/client.crt, tls_key: $ZENC/client.key}}
  - {name: zbxapi, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {mode: api, url: "http://127.0.0.1:$ZP2", token: env:PGV_PROOF_ZBX_TOKEN, host: pgvigil-proof}}
  - {name: zbxclear, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof-tls}}
  - {name: zbxdeny, kind: zabbix, min_severity: critical, instances: [$INSTH], zabbix: {server: "127.0.0.1:$ZP1", host: pgvigil-proof-deny}}
EOF
K6=$(newfinding 10)
pass Z1
for c in zbx zbxtls zbxapi; do
  [[ $(newest_alert $c | cut -d'|' -f1) == sent ]] || fail "Z: $c's attempt: $(newest_alert $c)"
done
for c in zbxclear zbxdeny; do
  [[ $(newest_alert $c) == failed*"processed 0 of 1"* ]] || fail "Z: $c's attempt: $(newest_alert $c)"
done
[[ $(newest_alert zbxname) == failed*certificate* ]] || fail "Z: zbxname (TLS, nothing pinned, no SAN in the server's certificate): $(newest_alert zbxname)"
hist() { zapi history.get "{\"history\":4,\"itemids\":[\"$1\"],\"output\":\"extend\"}" | python3 -c 'import json,sys; v=[json.loads(r["value"]) for r in json.load(sys.stdin)]; print(sum(1 for x in v if x.get("finding_key") == sys.argv[1]))' "$K6"; }
for n in $(seq 1 20); do [[ $(hist "$ZI1") == 2 && $(hist "$ZI2") == 1 ]] && break; sleep 3; done
[[ $(hist "$ZI1") == 2 ]] || fail "Z: pgvigil-proof's item holds $(hist "$ZI1") value(s) of the finding (wanted 2: the sender's and history.push's)"
[[ $(hist "$ZI2") == 1 ]] || fail "Z: pgvigil-proof-tls's item holds $(hist "$ZI2") value(s) of the finding (wanted 1: the TLS sender's)"
[[ $(hist "$ZI3") == 0 ]] || fail "Z: the denied host's item took a value"
cp "$WORK/cfg.base.yaml" "$CFG"
ZVOLS=$(docker inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}} {{end}}{{end}}' "$ZN-web" "$ZN-srv" "$ZN-db" 2>/dev/null | tr -s ' \n' ' ')
docker rm -f -v "$ZN-web" "$ZN-srv" "$ZN-db" >/dev/null; docker network rm "$ZN" >/dev/null; ZCLEAN=""
[[ -z $(docker ps -a --filter "name=$ZN" -q) && -z $(docker network ls --filter "name=$ZN" -q) ]] || fail "Z: a container or the network is left"
for v in $ZVOLS; do ! docker volume inspect "$v" >/dev/null 2>&1 || fail "Z: the volume $v is left"; done
ok "Z: sender plain (loopback), sender with certificate TLS and history.push read back from Zabbix; a host's certificate-only rule and Allowed hosts refuse a plain value"
fi

# ---- S / A / B: the Slack bot, attachment, the Slack door (task 403b K2 / K4 / K5) --------------------------------------
if [[ $PART == *S* || $PART == *A* || $PART == *B* ]]; then
cat > "$WORK/slack.py" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, port = sys.argv[1], int(sys.argv[2])
n = [0]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8', 'replace')
        name = 'hooks' if self.path.startswith('/hooks/') else 'slack'
        with open(os.path.join(work, name + '.log'), 'a') as f:
            f.write(json.dumps({'t': time.time(), 'path': self.path, 'auth': self.headers.get('Authorization', ''), 'body': body}) + '\n')
        ans = {'ok': True}
        if name == 'slack':
            a, qf = '', os.path.join(work, 'answers.slack')
            if os.path.exists(qf):
                lines = open(qf).read().splitlines()
                if lines:
                    a = lines[0]
                    open(qf, 'w').write(''.join(l + '\n' for l in lines[1:]))
            n[0] += 1
            ans = {'ok': False, 'error': a[4:]} if a.startswith('err:') else {'ok': True, 'ts': '1800000000.%06d' % n[0], 'channel': 'C0PROOF0001'}
        b = json.dumps(ans).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)
ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
# sl <log> count | body <i> <field> | auth <i> | gap <i> <j> | has <i> <text>: the stand-in's records
cat > "$WORK/sl.py" <<'PY'
import json, os, sys
f, cmd = sys.argv[1], sys.argv[2]
r = [json.loads(l) for l in open(f)] if os.path.exists(f) else []
if cmd == 'count': print(len(r))
elif int(sys.argv[3]) >= len(r) or (cmd == 'gap' and int(sys.argv[4]) >= len(r)): print('no' if cmd == 'has' else '')   # no such call
elif cmd == 'body': v = json.loads(r[int(sys.argv[3])]['body']).get(sys.argv[4]); print('' if v is None else (json.dumps(v) if not isinstance(v, str) else v))
elif cmd == 'auth': print(r[int(sys.argv[3])]['auth'])
elif cmd == 'gap': print('%.2f' % (r[int(sys.argv[4])]['t'] - r[int(sys.argv[3])]['t']))
elif cmd == 'has': print('yes' if sys.argv[4] in r[int(sys.argv[3])]['body'] else 'no')
PY
sl() { python3 "$WORK/sl.py" "$WORK/slack.log" "$@"; }
hk() { python3 "$WORK/sl.py" "$WORK/hooks.log" "$@"; }
LPORT=$(freeport)
python3 "$WORK/slack.py" "$WORK" "$LPORT" & SLK=$!
for n in $(seq 1 40); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$LPORT/hooks/ping" && break
  [[ $n == 40 ]] && fail "the Slack stand-in did not answer"
  sleep 0.25
done
rm -f "$WORK/hooks.log"
export PGV_PROOF_SLACK="xoxb-proof-$SUF" PGV_PROOF_SIGN="sign-$SUF-$RANDOM"
mkdir -p "$WORK/drop"; rm -f "$WORK/drop"/*
# slackcfg <file> <door: true|false>: sb and drop on the seeded instance
slackcfg() {
  cat > "$1" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts_base_url: https://pgvigil.proof.example/
doors: {slack_actions: $2}
slack_apps:
  - {app_id: A0PROOF0001, team_id: T0PROOF0001, signing_secret: env:PGV_PROOF_SIGN, users: {U0PROOF0001: $UIUSER, U0PROOF0002: nobody$SUF}}
alerts:
  - {name: sb, kind: slack, min_severity: warning, repeat: 1h, clear_after: 0, instances: [$INSTH], slack: {bot_token: env:PGV_PROOF_SLACK, channel: C0PROOF0001, api_url: "http://127.0.0.1:$LPORT/api", app_id: A0PROOF0001}}
  - {name: drop, kind: file, min_severity: warning, clear_after: 0, instances: [$INSTH], file: {dir: $WORK/drop}}
EOF
}
CFG=$WORK/cfg-slack.yaml; slackcfg "$CFG" false
# rule <metric> <warning> <critical>: a live rule on the seeded instance; prints its id
rule() {
  local id
  id=$(q "select pgvigil.import_alert_rule(now(), '{\"op\":\"add\",\"ui_user\":\"proof\",\"metric\":\"$1\",\"op_dir\":\"above\",\"warning\":$2,\"critical\":$3,\"for_minutes\":0,\"scope\":\"instance\",\"instance_name\":\"$INSTH\"}'::jsonb)->>'rule_id'")
  [[ $id =~ ^[0-9]+$ ]] || fail "the rule on $1 was not made: $id"
  echo "$id"
}
endrule() { q "select pgvigil.import_alert_rule(now(), '{\"op\":\"end\",\"ui_user\":\"proof\",\"rule_id\":$1}'::jsonb)->>'outcome'" >/dev/null; }
# sample <idle_in_txn> <waiting_lock> <total> [longest_active_secs]: a fresh activity sample, then the rules judged
sample() {
  q "insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
       active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
     values ($HID, now() - interval '2 seconds', $3, 1, 5, $1, 0, $2, 0, ${4:-1}, 1, 1, 100)" >/dev/null
  q "select pgvigil.alert_rules_run(now())" >/dev/null
}
# collected: the activity collector's run recorded as the collector records it (collection_dates 'activity', ok). An
# instance's finding is resolved only when a collection NEWER than the pass that first missed it says so (0190's
# alert_due), so a row that wants a recovery runs: the pass that marks it missing, collected, the pass that sends it.
collected() { q "insert into pgvigil.collection_dates (instance_id, collection, snapshot_at, status) values ($HID, 'activity', clock_timestamp(), 'ok')
     on conflict (instance_id, collection) do update set snapshot_at = excluded.snapshot_at, status = 'ok', note = null" >/dev/null; }
# gone <tag>: a finding gone, then proven gone: the marking pass, a collection after it, the pass that owes the recovery
gone() { pass "$1-mark"; collected; pass "$1"; }
# apass <tag>: a pass whose drop files are told apart from every earlier part's (an alert's key turns its numbers into
# '#', so another part's finding on the same metric has the same key); dropnew <event> <key> <severity> [text] counts
# the files this pass wrote
apass() { touch "$WORK/drop.mark"; sleep 0.05; pass "$1"; }
dropnew() {
  find "$WORK/drop" -type f -newer "$WORK/drop.mark" -print0 2>/dev/null | xargs -0 -r grep -l "\"$1\"" 2>/dev/null \
    | xargs -r grep -l "\"$2\"" 2>/dev/null | xargs -r grep -l "\"$3\"" 2>/dev/null | xargs -r grep -l -- "${4:-}" 2>/dev/null | wc -l
}
# mute <key>: a mute of the key for an hour, as the UI writes it (import_ack); prints its ack_id. unack <ack_id> ends it.
mute() {
  local id
  id=$(q "select pgvigil.import_ack(now(), '{\"op\":\"add\",\"ui_user\":\"proof\",\"client\":\"proof\",\"kind\":\"mute\",\"finding_key\":\"$1\",\"until\":\"$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)\"}'::jsonb)->>'ack_id'")
  [[ $id =~ ^[0-9]+$ ]] || fail "the mute of $1 was not written: $id"
  echo "$id"
}
unack() { q "select pgvigil.import_ack(now(), '{\"op\":\"end\",\"ui_user\":\"proof\",\"client\":\"proof\",\"ack_id\":$1}'::jsonb)->>'outcome'" >/dev/null; }
keyof() { q "select string_agg(finding_key, ',') from pgvigil.alert_findings where instance_id = $HID and source = 'alert rule' and setting ilike '%$1%'"; }
back() { q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '2 hours' where channel = 'sb' and finding_key = '$1' and cleared_at is null" >/dev/null; }
tsof() { q "select ts from pgvigil.alert_threads where channel = 'sb' and finding_key = '$1' order by posted_at desc limit 1"; }
# sdiag <key> <rule id>: what the store holds for a row that failed - sb's alert_state rows, sb's attempts, the finding,
# the rule's end
sdiag() {
  echo "sb state: $(q "select string_agg(left(finding_key, 10) || ' cleared ' || coalesce(to_char(cleared_at, 'HH24:MI:SS'), '-') || ' missing ' || coalesce(to_char(missing_since, 'HH24:MI:SS'), '-') || ' last ' || coalesce(to_char(last_sent_at, 'HH24:MI:SS'), '-'), '; ') from pgvigil.alert_state where channel = 'sb'")" \
       "| sb log: $(q "select string_agg(outcome || ' f' || n_firing || ' r' || n_repeat || ' z' || n_resolved || coalesce(' ' || left(error, 80), ''), ', ' order by snapshot_at) from pgvigil.alert_log where channel = 'sb'")" \
       "| finding $(q "select count(*) from pgvigil.alert_findings where finding_key = '$1'") row(s) now" \
       "| rule $2 ended: $(q "select ended_at is not null from pgvigil.alert_rules where rule_id = $2")"
}
endall; RID=""   # the earlier parts' rules on the seeded instance (by query: see endall)
sample 0 0 1; pass sab0   # the earlier parts' findings cleared on these channels
SL0=$(sl count)
fi

if [[ $PART == *S* ]]; then
R1=$(rule sessions.idle_in_txn 39 40); sample 50 0 1; KS=$(keyof "idle in")
[[ $KS =~ ^[0-9a-f]+$ ]] || fail "S: the rule's finding is '$KS'"
pass S1
[[ $(sl count) == $((SL0 + 1)) ]] || fail "S1: $(( $(sl count) - SL0 )) calls (wanted one post)"
i=$SL0
[[ -z $(sl body $i thread_ts) && $(sl body $i channel) == C0PROOF0001 && $(sl auth $i) == "Bearer xoxb-proof-$SUF" ]] || fail "S1: the post: thread_ts '$(sl body $i thread_ts)', channel $(sl body $i channel), auth $(sl auth $i | cut -c1-12)"
[[ $(sl has $i pgv_open) == yes && $(sl has $i pgv_ack) == no ]] || fail "S1: the post's buttons (open $(sl has $i pgv_open), ack $(sl has $i pgv_ack))"
TS1=$(tsof "$KS"); [[ $TS1 == 1800000000.* ]] || fail "S1: alert_threads holds '$TS1'"
ok "S1: one top-level post (the link button, no Acknowledge with the door off), its thread $TS1 kept"
back "$KS"; pass S2
i=$((SL0 + 1))
[[ $(sl count) == $((SL0 + 2)) && $(sl body $i thread_ts) == "$TS1" && -z $(sl body $i reply_broadcast) ]] || fail "S2: the repeat: thread_ts '$(sl body $i thread_ts)' broadcast '$(sl body $i reply_broadcast)'"
[[ $(q "select count(*) from pgvigil.alert_log where channel = 'sb' and outcome = 'sent' and n_repeat = 1") -ge 1 ]] || fail "S2: no 'sent' repeat attempt"
ok "S2: the repeat is a reply in thread $TS1, not broadcast, its own attempt"
echo 'err:cannot_reply_to_message' > "$WORK/answers.slack"
back "$KS"; pass S3
[[ $(sl count) == $((SL0 + 4)) ]] || fail "S3: $(( $(sl count) - SL0 - 2 )) calls (wanted the refused reply and a new post)"
[[ $(sl body $((SL0 + 2)) thread_ts) == "$TS1" && -z $(sl body $((SL0 + 3)) thread_ts) ]] || fail "S3: the refused reply then a post"
g=$(sl gap $((SL0 + 2)) $((SL0 + 3))); awk "BEGIN{exit !($g >= 0.9)}" || fail "S3: the two calls $g s apart (wanted at least 0.9)"
TS2=$(tsof "$KS"); [[ $TS2 != "$TS1" ]] || fail "S3: the thread did not move to the new post"
[[ $(q "select older_ts[1] from pgvigil.alert_threads where channel = 'sb' and finding_key = '$KS' order by posted_at desc limit 1") == "$TS1" ]] || fail "S3: older_ts does not keep the first post $TS1"
ok "S3: a reply Slack refused as a reply went as a new post ${g} s later; the thread is now $TS2, the first post $TS1 kept in older_ts (its buttons still act)"
endrule "$R1"; sample 0 0 1; gone S4
i=$((SL0 + 4))
[[ $(sl count) == $((SL0 + 5)) && $(sl body $i thread_ts) == "$TS2" && -z $(sl body $i reply_broadcast) && $(sl has $i RESOLVED) == yes ]] || fail "S4: the recovery: $(( $(sl count) - SL0 )) calls (wanted 5), thread_ts '$(sl body $i thread_ts)' resolved $(sl has $i RESOLVED); $(sdiag "$KS" "$R1")"
ok "S4: the recovery is a reply in thread $TS2, not broadcast"
R1=$(rule sessions.idle_in_txn 39 40); sample 50 0 1; KS2=$(keyof "idle in"); pass S5
i=$((SL0 + 5))
[[ $(sl count) == $((SL0 + 6)) && -z $(sl body $i thread_ts) ]] || fail "S5: the re-fire: thread_ts '$(sl body $i thread_ts)'"
ok "S5: the re-fire is a new top-level post (the key $([[ $KS2 == "$KS" ]] && echo the same || echo new), $(q "select count(*) from pgvigil.alert_threads where channel = 'sb' and finding_key = '$KS2'") thread row(s))"
R2=$(rule sessions.total 9 1000); back "$KS2"; sample 50 0 20; pass S7
[[ $(sl count) == $((SL0 + 8)) ]] || fail "S7: $(( $(sl count) - SL0 - 6 )) calls (wanted a post and a reply)"
[[ -z $(sl body $((SL0 + 6)) thread_ts) && -n $(sl body $((SL0 + 7)) thread_ts) ]] || fail "S7: the post first, then the reply"
ok "S7: a new firing and a repeat in one pass: a post, then a reply ($(sl gap $((SL0 + 6)) $((SL0 + 7))) s apart), two attempts"
endrule "$R1"; endrule "$R2"; sample 0 0 1; gone S8
fi

if [[ $PART == *A* ]]; then
[[ $(q "select count(*) from pgvigil.alert_anchor_checks a where a.match = 'metric' and not exists (select 1 from pgvigil.metric_catalog c where c.key = a.name)") == 0 ]] || fail "A0: a metric row of alert_anchor_checks names no metric_catalog key"
q "select match || ' ' || source || ' ' || name || ' -> ' || kind from pgvigil.alert_anchor_checks order by kind, match, name" | sed 's/^/     /'
ok "A0: every metric row of alert_anchor_checks is a metric_catalog key"
SLA=$(sl count)
RA=$(rule sessions.waiting_lock 3 1000); sample 0 9 1; AK=$(keyof "waiting on a lock"); apass A1
[[ $AK =~ ^[0-9a-f]+$ && $(dropnew firing "$AK" warning) == 1 && $(sl count) == $((SLA + 1)) ]] || fail "A1: the anchor '$AK': drop $(dropnew firing "$AK" warning), slack $(( $(sl count) - SLA ))"
ATS=$(tsof "$AK")
ok "A1: the anchor (sessions.waiting_lock, warning) sent on drop and sb (thread $ATS)"
RB=$(rule sessions.total 9 1000); sample 0 9 20; BK=$(q "select finding_key from pgvigil.alert_findings where instance_id = $HID and source = 'alert rule' and finding_key <> '$AK' limit 1"); apass A2
[[ $(dropnew firing "$BK" warning) == 0 ]] || fail "A2: the attached finding was sent on drop"
[[ $(q "select count(*) from pgvigil.alert_held where hold_kind = 'attached' and finding_key = '$BK' and anchor_key = '$AK' and channel in ('drop', 'sb')") == 2 ]] || fail "A2: alert_held: $(q "select string_agg(channel || ':' || hold_kind || ':' || coalesce(anchor_key, '-'), ' ') from pgvigil.alert_held where finding_key = '$BK'")"
i=$((SLA + 1))
[[ $(sl count) == $((SLA + 2)) && $(sl body $i thread_ts) == "$ATS" && $(sl has $i "attached under this alert") == yes ]] || fail "A2: the Slack reply: $(( $(sl count) - SLA - 1 )) call(s), thread_ts '$(sl body $i thread_ts)'"
ok "A2: a warning finding on the anchor's instance: held 'attached' on drop and sb, one reply in the anchor's thread (sb owed nothing else this pass)"
RC=$(rule sessions.idle_in_txn 39 40); sample 50 9 20; CK=$(q "select finding_key from pgvigil.alert_findings where instance_id = $HID and source = 'alert rule' and severity = 'critical' limit 1"); apass A3
[[ $(dropnew firing "$CK" critical) == 1 ]] || fail "A3: the critical finding was not sent on drop"
ok "A3: a critical finding beside the anchor is sent (never attached)"
endrule "$RA"; sample 50 0 20; pass A4-mark; collected; apass A4
[[ $(dropnew resolved "$AK" warning 'attached while it stood: ') == 1 ]] || fail "A4: the anchor's recovery lists nothing attached"
[[ $(dropnew firing "$BK" warning) == 0 ]] || fail "A4: the attached finding fired in its anchor's recovery pass (the anchor stands until its recovery)"
ok "A4: the anchor's rule ended: its recovery lists what was attached while it stood; the attached finding is still held in that pass"
apass A5
[[ $(dropnew firing "$BK" warning 'which resolved ') == 1 ]] || fail "A5: the released finding did not fire this pass, or its line does not say its anchor resolved: $(find "$WORK/drop" -type f -newer "$WORK/drop.mark" -print0 | xargs -0 -r grep -h -o '"detail":"[^"]*' | cut -c1-200)"
ok "A5: the next pass: the still-standing finding fires as itself, 'was attached to ..., which resolved HH:MM UTC'"
endrule "$RB"; endrule "$RC"; sample 0 0 1; apass A6
# a muted anchor anchors nothing (the review's finding 6: alert_mark writes the attached holds after the others)
RA=$(rule sessions.waiting_lock 3 1000); sample 0 9 1; AK2=$(keyof "waiting on a lock"); apass A7
[[ $(dropnew firing "$AK2" warning) == 1 ]] || fail "A7: the second anchor was not sent"
MID=$(mute "$AK2")
RD=$(rule sessions.active 0 1000); sample 0 9 1; DK=$(keyof "active sessions"); apass A8
[[ $DK =~ ^[0-9a-f]+$ ]] || fail "A8: the finding on sessions.active is '$DK'"
[[ $(dropnew firing "$DK" warning) == 1 ]] || fail "A8: a warning beside a muted anchor was not sent"
[[ $(q "select count(*) from pgvigil.alert_held where hold_kind = 'attached' and finding_key = '$DK'") == 0 ]] || fail "A8: 'attached' rows were written for it: $(q "select string_agg(channel || ' under ' || anchor_key, ' ') from pgvigil.alert_held where hold_kind = 'attached' and finding_key = '$DK'")"
ok "A7/A8: a muted anchor holds nothing: the warning beside it is sent, and no 'attached' row is written for it"
unack "$MID"; endrule "$RD"; sample 0 9 1; apass A8b
# an attached finding that turns critical fires at once and says so (finding 12)
RE=$(rule sessions.longest_active_secs 5 100); sample 0 9 1 10; EK=$(keyof "longest active statement"); apass A9
[[ $EK =~ ^[0-9a-f]+$ && $(dropnew firing "$EK" warning) == 0 && $(q "select count(*) from pgvigil.alert_held where hold_kind = 'attached' and finding_key = '$EK' and anchor_key = '$AK2'") -ge 1 ]] || fail "A9: '$EK' was not attached under the anchor once its mute ended"
sample 0 9 1 200; apass A10
[[ $(dropnew firing "$EK" critical 'and is critical now') == 1 ]] || fail "A10: the attached finding turned critical: $(find "$WORK/drop" -type f -newer "$WORK/drop.mark" -print0 | xargs -0 -r grep -h -o '"detail":"[^"]*' | cut -c1-200)"
ok "A9/A10: attached under the anchor once its mute ended; turned critical, it fires at once: 'was attached to ..., and is critical now'"
endrule "$RA"; endrule "$RE"; sample 0 0 1; apass A10b
# two anchors sent in one post share one hold (hold_id: the post's first send): when one resolves the other still
# holds what sat under the first, even past 60 minutes (finding 7); read through alert_anchor, rolled back
A11=$(psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 <<SQL
begin;
insert into pgvigil.alert_state (channel, finding_key, instance_id, instance_name, source, setting, value, severity, first_sent_at, last_sent_at)
values ('drop', 'proofanchor1', $HID, '$INSTH', 'mssql_running', 'a blocking chain', 'x', 'warning', now() - interval '2 hours', now() - interval '2 hours'),
       ('drop', 'proofanchor2', $HID, '$INSTH', 'mssql_xe', 'deadlocks in the last hour', 'x', 'warning', now() - interval '2 hours', now() - interval '2 hours');
insert into pgvigil.alert_held (hold_kind, hold_id, channel, finding_key, instance_id, instance_name, severity, source, setting, value, first_at, last_at, anchor_key, anchor_first_sent_at)
values ('attached', (extract(epoch from now() - interval '2 hours') * 1000000)::bigint, 'drop', 'proofx', $HID, '$INSTH', 'warning', 'pgvigil host', 'proof', 'x', now() - interval '1 hour', now() - interval '1 minute', 'proofanchor1', now() - interval '2 hours');
select 'both:' || coalesce((select anchor_key from pgvigil.alert_anchor(now(), 'drop', '$INSTH', 'proofx', 'pgvigil host', 'proof', 'warning')), 'none');
update pgvigil.alert_state set cleared_at = now() where channel = 'drop' and finding_key = 'proofanchor1';
select 'one:' || coalesce((select anchor_key from pgvigil.alert_anchor(now(), 'drop', '$INSTH', 'proofx', 'pgvigil host', 'proof', 'warning')), 'none');
select 'fresh:' || coalesce((select anchor_key from pgvigil.alert_anchor(now(), 'drop', '$INSTH', 'proofy', 'pgvigil host', 'proof y', 'warning')), 'none');
rollback;
SQL
)
[[ $(echo "$A11" | tr '\n' ' ') == "both:proofanchor1 one:proofanchor2 fresh:none " ]] || fail "A11: $(echo "$A11" | tr '\n' ' ')"
ok "A11: two anchors of one post (2 h old): the held alert stays under the second when the first resolves; a new alert does not attach to a 2-hour-old anchor"
fi

if [[ $PART == *B* ]]; then
# a clean slate on sb and drop: an alert rule's key turns its numbers into '#', so an alert an earlier part left open
# (A3's critical idle_in_txn, ended at A6 with no collection after it) is the SAME alert as B1's and only repeats after
# an hour - B1 would post nothing. Every rule ended, the findings gone and proven gone (gone: a collection after the
# marking pass), then no rule's alert open on sb
endall; sample 0 0 1; gone B-clean
[[ $(q "select count(*) from pgvigil.alert_state where channel in ('sb', 'drop') and source = 'alert rule' and cleared_at is null") == 0 ]] \
  || fail "B: an earlier part's alert is still open: $(q "select string_agg(channel || ' ' || left(finding_key, 10) || ' ' || severity || ' missing ' || coalesce(to_char(missing_since, 'HH24:MI:SS'), '-'), '; ') from pgvigil.alert_state where channel in ('sb', 'drop') and source = 'alert rule' and cleared_at is null")"
BINB=$WORK/pgvigil-slackproof
(cd "$TREE" && go build -ldflags "-X github.com/aachaemenes/pgvigil/internal/alerts.slackProofHooks=on" -o "$BINB" ./cmd/pgvigil) || fail "go build (the proof knob)"
if [[ $(q "select count(*) from pgvigil.ui_users where username = '$UIUSER'") == 0 ]]; then   # part P may have added it
  PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" "$UIUSER" >/dev/null 2>&1 || fail "B: user add"
fi
PORT=$(freeport); U="http://127.0.0.1:$PORT"
serve_b() {
  "$BINB" serve -config "$1" -listen "127.0.0.1:$PORT" > "$WORK/serve.b.log" 2>&1 & SRV=$!
  for _ in $(seq 1 60); do curl -sf -o /dev/null "$U/" && return; kill -0 "$SRV" 2>/dev/null || fail "B: serve died: $(tail -3 "$WORK/serve.b.log")"; sleep 0.5; done
  fail "B: serve did not answer"
}
stop_b() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null || true; SRV=""; }
serve_b "$CFG"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data 'payload=%7B%7D' "$U/api/slack/actions") == 404 ]] || fail "B0: the door off does not answer 404"
stop_b
ok "B0: the door off: 404"
CFGB=$WORK/cfg-slackdoor.yaml; slackcfg "$CFGB" true; CFG=$CFGB
serve_b "$CFGB"
grep -q 'the Slack door is on.*A0PROOF0001' "$WORK/serve.b.log" || fail "B1: no start line: $(grep -i slack "$WORK/serve.b.log" | sed -n 1,2p)"
SLB=$(sl count)
RK=$(rule sessions.idle_in_txn 39 40); sample 50 0 1; KB=$(keyof "idle in")
set +e; "$BINB" alerts -config "$CFGB" >"$WORK/pass.B1.out" 2>&1; set -e
i=$SLB
[[ $(sl has $i "\"$KB|sb\"") == yes && $(sl has $i pgv_mute1h) == yes && $(sl has $i '"confirm"') == yes ]] || fail "B1: the post's buttons: '$(sl body $i blocks | cut -c1-300)'; $(( $(sl count) - SLB )) call(s) in the pass; key '$KB'; $(sdiag "$KB" "$RK"); the pass: $(tr '\n' ' ' < "$WORK/pass.B1.out" | cut -c1-300)"
bl=$(sl body $i blocks | wc -c); (( bl * 20 < 128 * 1024 )) || fail "B1: one alert's blocks $bl bytes: 20 would pass half the cap"
PTS=$(tsof "$KB")
ok "B1: the door on (start line), the post carries Acknowledge '$KB|sb' and Mute 1 h with its confirm; $bl bytes of blocks a post (20 under half of 256 KB)"
# click <user> <action> <value> <post ts> [ts offset] [content type] [secret]: a signed request; prints the HTTP code
cat > "$WORK/sign.py" <<'PY'
import hashlib, hmac, json, sys, time, urllib.parse
secret, user, action, value, mts, off, hooks, out = sys.argv[1:9]
ts = str(int(time.time()) + int(off))
p = {'type': 'block_actions', 'api_app_id': 'A0PROOF0001', 'team': {'id': 'T0PROOF0001'}, 'user': {'id': user},
     'container': {'message_ts': mts, 'channel_id': 'C0PROOF0001'}, 'response_url': hooks, 'token': 'ignored',
     'actions': [{'action_id': action, 'value': value, 'action_ts': ts + '.000100'}]}
body = urllib.parse.urlencode({'payload': json.dumps(p)})
sig = 'v0=' + hmac.new(secret.encode(), ('v0:' + ts + ':' + body).encode(), hashlib.sha256).hexdigest()
open(out, 'w').write(json.dumps({'ts': ts, 'sig': sig, 'body': body}))
PY
REQ=$WORK/req.json
mkreq() { python3 "$WORK/sign.py" "${7:-$PGV_PROOF_SIGN}" "$1" "$2" "$3" "$4" "${5:-0}" "http://127.0.0.1:$LPORT/hooks/$RANDOM" "$REQ"; }
sendreq() {
  local ts sig body
  ts=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ts"])' "$REQ")
  sig=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sig"])' "$REQ")
  python3 -c 'import json,sys; open(sys.argv[2],"w").write(json.load(open(sys.argv[1]))["body"])' "$REQ" "$WORK/req.body"
  curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: ${1:-application/x-www-form-urlencoded}" -H "X-Slack-Request-Timestamp: $ts" -H "X-Slack-Signature: $sig" --data-binary "@$WORK/req.body" "$U/api/slack/actions"
}
waithooks() { for _ in $(seq 1 40); do [[ $(hk count) -ge $1 ]] && return; sleep 0.25; done; fail "$2: the stand-in hooks got $(hk count) answer(s) (wanted $1)"; }
mkreq U0PROOF0001 pgv_ack "$KB|sb" "$PTS"; [[ $(sendreq) == 200 ]] || fail "B2: the signed click"
cp "$REQ" "$WORK/req.b2.json"
waithooks 1 B2
[[ $(hk has 0 '"in_channel"') == yes && $(hk has 0 "Acknowledged in pgvigil by $UIUSER") == yes ]] || fail "B2: the answer: $(hk body 0 text)"
[[ $(q "select count(*) from pgvigil.acks where kind = 'alert_ack' and finding_key = '$KB' and created_by = '$UIUSER'") == 1 ]] || fail "B2: acks"
[[ $(q "select count(*) from pgvigil.ack_log where client = 'slack:T0PROOF0001/U0PROOF0001' and payload->>'slack_user' = 'U0PROOF0001' and outcome = 'done'") == 1 ]] || fail "B2: ack_log's Slack identity"
ok "B2: a signed Acknowledge: 200, 'Acknowledged in pgvigil by $UIUSER', the alert_ack and its audit row with the Slack identity"
mkreq U0PROOF0001 pgv_ack "$KB|sb" "$PTS"; [[ $(sendreq) == 200 ]] || fail "B3: the second click"; waithooks 2 B3
[[ $(hk has 1 '"ephemeral"') == yes && $(hk has 1 'Already acknowledged by') == yes ]] || fail "B3: $(hk body 1 text)"
cp "$WORK/req.b2.json" "$REQ"; [[ $(sendreq) == 200 ]] || fail "B4: the replay's code"; sleep 2
[[ $(hk count) == 2 && $(q "select count(*) from pgvigil.acks where finding_key = '$KB'") == 1 ]] || fail "B4: the replay wrote or answered"
ok "B3/B4: a second Acknowledge: 'Already acknowledged by'; the exact request replayed: 200, nothing new"
mkreq U0PROOF0001 pgv_ack "$KB|sb" "$PTS" 0 x wrong-secret; c1=$(sendreq)
mkreq U0PROOF0001 pgv_ack "$KB|sb" "$PTS" -400; c2=$(sendreq)
mkreq U0PROOF0001 pgv_ack "$KB|sb" "$PTS"; c3=$(sendreq application/json)
[[ "$c1 $c2 $c3" == "401 401 401" ]] || fail "B5: bad signature, stale, JSON type answered $c1 $c2 $c3"; sleep 1
[[ $(hk count) == 2 ]] || fail "B5: a refused request was answered at the hooks"
ok "B5: a bad signature, a stale timestamp and a JSON body: 401 each, nothing at the hooks"
mkreq U0PROOF0009 pgv_ack "$KB|sb" "$PTS"; sendreq >/dev/null; waithooks 3 B6
mkreq U0PROOF0002 pgv_ack "$KB|sb" "$PTS"; sendreq >/dev/null; waithooks 4 B6
[[ $(hk has 2 'not mapped') == yes && $(hk has 3 'disabled or gone') == yes && $(hk has 2 '"ephemeral"') == yes ]] || fail "B6: $(hk body 2 text) / $(hk body 3 text)"
ok "B6: an unmapped Slack user and a user mapped to no pgvigil user: refused to the clicker alone"
mkreq U0PROOF0001 pgv_mute1h "$KB|sb" "$PTS"; sendreq >/dev/null; waithooks 5 B7
[[ $(hk has 4 'Muted for 1 h in pgvigil by') == yes && $(q "select count(*) from pgvigil.acks where kind = 'mute' and finding_key = '$KB' and until between now() + interval '55 minutes' and now() + interval '65 minutes'") == 1 ]] || fail "B7: $(hk body 4 text)"
mkreq U0PROOF0001 pgv_mute1h "$KB|sb" "$PTS"; sendreq >/dev/null; waithooks 6 B7
[[ $(hk has 5 'Already muted until') == yes ]] || fail "B7 again: $(hk body 5 text)"
ok "B7: Mute 1 h: written until about an hour on; again: 'Already muted until'"
# the occurrence's thread moved to a newer post (a reply Slack refused opens one; S3): its first post's buttons act
q "update pgvigil.alert_threads set older_ts = array[ts], ts = '1800000999.000001' where channel = 'sb' and finding_key = '$KB'
     and first_sent_at = (select first_sent_at from pgvigil.alert_state where channel = 'sb' and finding_key = '$KB' and cleared_at is null)" >/dev/null
mkreq U0PROOF0001 pgv_mute1h "$KB|sb" "$PTS"; sendreq >/dev/null; waithooks 7 B7b
[[ $(hk has 6 'Already muted until') == yes ]] || fail "B7b: a click on the occurrence's first post: $(hk body 6 text)"
ok "B7b: the thread moved to a newer post: a click on the first post still finds the open occurrence ('Already muted until')"
q "update pgvigil.alert_state set cleared_at = now() where channel = 'sb' and finding_key = '$KB' and cleared_at is null" >/dev/null
mkreq U0PROOF0001 pgv_ack "$KB|sb" "$PTS"; sendreq >/dev/null; waithooks 8 B8
[[ $(hk has 7 'cleared at') == yes ]] || fail "B8: $(hk body 7 text)"
ok "B8: a click on a post whose occurrence cleared: 'cleared at'"
mkreq U0PROOF0001 pgv_open "" "$PTS"; [[ $(sendreq) == 200 ]] || fail "B9: the link click"; sleep 1
[[ $(hk count) == 8 ]] || fail "B9: the link click was answered"
ok "B9: the link button's click: 200, nothing written or answered"
stop_b
# B's serve ran on the repository's superuser login: the door's reads are run here as a pgvigil_reader login, one by
# one (its write, import_ack, is the collector's: proof-ack.sh's part R)
rq() { psql "$(dsn "$RDR")" -XAt -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
r1=$(rq "select count(*) from pgvigil.alert_threads where channel = 'sb' and finding_key = '$KB' and slack_channel = 'C0PROOF0001' and ('$PTS' = ts or '$PTS' = any (older_ts))")
r2=$(rq "select count(*) from pgvigil.alert_state where channel = 'sb' and finding_key = '$KB'")
r3=$(rq "select count(*) from pgvigil.acks a where a.kind = 'alert_ack' and a.finding_key = '$KB' and pgvigil.ack_alert_acked(now(), '$KB', now() - interval '1 day')")
r4=$(rq "select count(*) from pgvigil.acks a where a.kind = 'mute' and a.finding_key = '$KB' and pgvigil.ack_live(a.ended_at, a.starts_at, a.until, now())")
[[ $r1 == 1 && $r2 =~ ^[1-9][0-9]*$ && $r3 =~ ^[0-9]+$ && $r4 == 1 ]] || fail "B10: the door's reads as the reader: '$r1' '$r2' '$r3' '$r4'"
ok "B10: the door's reads (alert_threads with older_ts, alert_state, acks with ack_alert_acked and ack_live) run as a pgvigil_reader login"
for id in $(q "select ack_id from pgvigil.acks where finding_key = '$KB' and ended_at is null"); do unack "$id"; done
endrule "$RK"
fi

echo "PROOF OK $PART"
