#!/usr/bin/env bash
# Proof of support and problem reports: `pgvigil report` against a throwaway repository seeded with secrets in its
# configuration and in its error notes, and the About page's 'Report a problem' link in a headless Chromium.
#
#   PGVIGIL_ADMIN_DSN        keyword-form connection to a cluster as a login that may create a database and a role
#                            (the proof creates pgvigil_proof_report_<n> and two logins proofrep_*_<n>, and drops them)
#   PGVIGIL_PROOF_NO_RENDER  1 = skip part C (a runner whose chromium does not start); the last line says so
#
# Needs go, psql, unzip and sha256sum; part C also chromium and node, and the web bundle built from this tree
# (cd web && npm ci && npm run build) before the run: the proof builds one binary and uses it throughout.
#
# The seeded values (each carries the run's own tag): the repository password in env:PGVIGIL_REPO_DSN, an inline
# instance password, a Slack-shaped and a Teams-shaped webhook address (path token and sig=; each through an env:
# variable, the only form pgvigil takes for a webhook address), and the site's names:
# two instance names, a host, a login, a database, a tag, two channel names. Three error notes in the repository quote
# them: a failed connection (host, login, database, an IPv4 address, the instance password), a failed webhook post
# (both addresses and the repository password) and a note of an instance the configuration does not list.
#
# Expected (written before the first run):
#   A1 run       exit 0; the terminal names the zip with '6 files', 'instance-1 = <name>', 'instance-id<N> = <other name>
#                (in the repository, not in this configuration file)', 'Nothing was sent.' and support@pgvigil.com
#   A2 zip       mode 600; exactly README.txt, version.txt, config.yaml, repository.txt, instances.txt,
#                collection-errors.txt
#   A3 version   version.txt's first line is `pgvigil version`'s line and holds the build's version v0.0.0-proof143
#   A4 secrets   grep 0: none of the 4 secrets (2 passwords, 2 webhook addresses) nor their 3 tokens, and none of the
#                10 names, is in any file of the zip or on the terminal's 'wrote' lines
#   A5 level     repository.txt: 'repository server: PostgreSQL <the server's version>', 'migration level: <the
#                database's max(schema_version.version)>', 'the repository is current', 'last runs by status ...: 3
#                error, 1 ok'
#   A6 instances instances.txt: instance-1 postgres onprem 18.0 and instance-id<N> postgres rds 16.4; '2 instance(s)'
#   A7 errors    collection-errors.txt: both parts '3 row(s)'; the connection note reads exactly
#                failed to connect to `user=<masked> database=<masked>`: <ip>:5432 (<masked>): server error: FATAL:
#                password authentication failed for user "<masked>" (the string was host=<masked> password=<masked>)
#                the other instance's note names it as instance-id<N>
#   A8 config    config.yaml: 'configuration check: ok', 'dsn: env:PGVIGIL_REPO_DSN # set in the environment of this
#                command', 'name: instance-1', 'platform: onprem', 'activity: 30s', 'format: slack', 'format: teams',
#                both webhook lines as 'url: env:<variable> # set in the environment of this command', the instance's
#                inline string as '<masked> # an inline connection string, keyword form', the tag env:<value> as
#                <masked> (a tag is data, not an env: indirection), no comment of the file copied
#   A9 again     the same -out a second time: exit 1 'exists already', the zip's sha256 unchanged
#   A10 -names   the instance name is in config.yaml and the notes; A4's secrets still grep 0; no alias list printed
#   A11 logins   as a login IN ROLE pgvigil_collector: exit 0, the migration level read, instances.txt and
#                collection-errors.txt say 'this login may not read it'; IN ROLE pgvigil_reader: '2 instance(s)'
#   A12 no repo  -dsn to a closed port: exit 0, 'repository: not read: no connection', the -dsn's password grep 0
#   A13 usage    -errors 0: exit 2, no zip
#   A14 connects (where strace is installed and the admin connection names an IPv4 host) every connect() call of the
#                command goes to the repository's address: no monitored server, no webhook, no name lookup; else
#                'NOT PROVEN (A14)' with the reason
#   C  about     (headless Chromium, the wired bundle) the bar's About link opens #/about; the page's 'Report a problem'
#                link is mailto:support@pgvigil.com with the subject 'pgvigil problem report (v0.0.0-proof143)' and a
#                body holding 'pgvigil: <the version line>', 'Repository: PostgreSQL <version>, migration <level>',
#                'Monitored: 1 x PostgreSQL 16.4 (rds); 1 x PostgreSQL 18.0 (onprem)' and 'Browser: <the user agent>';
#                no instance name and no address of this server in it; the page shows the same lines, the support
#                address and the private vulnerability link; every request the page made went to this server
#                (nothing sent elsewhere), and none was a POST
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
for t in go psql unzip sha256sum; do command -v $t >/dev/null || { echo "FAIL: $t is not on this machine" >&2; exit 1; }; done
TAG=$RANDOM$RANDOM
WORK=$(mktemp -d); DB=pgvigil_proof_report_$TAG; COLL=proofrep_coll_$TAG; READER=proofrep_read_$TAG
PORT=$((31000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
BIN=$WORK/pgvigil; CFG=$WORK/pgvigil.yaml; VER=v0.0.0-proof143
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  # the browser runs in a process group of its own (setsid below): the whole group goes, so no helper of it outlives the run
  if [[ -n "$CHR" ]]; then kill -TERM -- "-$CHR" 2>/dev/null || kill "$CHR" 2>/dev/null || true; fi
  if [[ -n "$SRV" ]]; then kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; fi
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $COLL" -c "drop role if exists $READER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

REPO_PW="Rp-proof143-$TAG-repo"; INST_PW="Ip-proof143-$TAG-inst"; FLAG_PW="Fp-proof143-$TAG-flag"
SLACK_TOKEN="slk${TAG}token143"; TEAMS_FLOW="wf${TAG}proof143"; TEAMS_SIG="sig${TAG}proof143"
SLACK_URL="https://hooks.slack.example/services/T0PROOF/B0PROOF/$SLACK_TOKEN"
TEAMS_URL="https://prod-27.westus.logic.azure.example:443/workflows/$TEAMS_FLOW/triggers/manual/paths/invoke?api-version=2016-06-01&sig=$TEAMS_SIG"
NAME1=proofrep-acme-db01; NAME2=proofrep-other-db02; HOST=proofrep-host.corp.example; LOGIN=proofrep_login; DBNAME=proofrep_db
SECRETS=("$REPO_PW" "$INST_PW" "$SLACK_URL" "$TEAMS_URL" "$SLACK_TOKEN" "$TEAMS_FLOW" "$TEAMS_SIG")
NAMES=("$NAME1" "$NAME2" "$HOST" "$LOGIN" "$DBNAME" "proofrep-prod" "proofrep-slack" "proofrep-teams" "10.20.30.40" "slack.example")

echo "== build one binary ($VER), a repository in $DB"
CGO_ENABLED=0 go build -ldflags "-X main.version=$VER" -o "$BIN" ./cmd/pgvigil
VLINE=$("$BIN" version)
case "$VLINE" in "pgvigil $VER ("*) ;; *) fail "the version line: $VLINE" ;; esac
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB password=$REPO_PW"
q() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -c "$1"; }
cat > "$CFG" <<EOF
# a commented-out line: postgres://owner:$REPO_PW@$HOST/x
repository:
  dsn: env:PGVIGIL_REPO_DSN
schedules:
  activity: 30s
instances:
  - name: $NAME1
    dsn: "host=$HOST port=5432 user=$LOGIN password=$INST_PW dbname=$DBNAME"
    platform: onprem
    tags: [env:proofrep-prod]
alerts:
  - name: proofrep-slack
    kind: webhook
    min_severity: critical
    webhook:
      url: env:PROOFREP_SLACK_URL
      format: slack
  - name: proofrep-teams
    kind: webhook
    webhook:
      url: env:PROOFREP_TEAMS_URL
      format: teams
EOF
export PROOFREP_SLACK_URL="$SLACK_URL" PROOFREP_TEAMS_URL="$TEAMS_URL"
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || fail "migrate"
LEVEL=$(q "select max(version) from pgvigil.schema_version")
SRVVER=$(q "select current_setting('server_version')")
iid=$(q "select pgvigil.ensure_instance('$NAME1', 'onprem', '18.0', 180000, false, '{}'::text[])")
oid=$(q "select pgvigil.ensure_instance('$NAME2', 'rds', '16.4', 160004, false, '{}'::text[])")
NOTE1="failed to connect to \`user=$LOGIN database=$DBNAME\`: 10.20.30.40:5432 ($HOST): server error: FATAL: password authentication failed for user \"$LOGIN\" (the string was host=$HOST password=$INST_PW)"
NOTE2="Post \"$SLACK_URL\": dial tcp: lookup hooks.slack.example: no such host; then $TEAMS_URL was refused; the repository string held $REPO_PW"
NOTE3="instance $NAME2: canceling statement due to statement timeout"
psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -v n1="$NOTE1" -v n2="$NOTE2" -v n3="$NOTE3" >/dev/null <<EOF
select pgvigil.log_collection($iid, 'instance', now() - interval '4 minutes', 40, 'ok', null);
select pgvigil.log_collection($iid, 'activity', now() - interval '3 minutes', 1200, 'error', :'n1');
select pgvigil.log_collection($iid, 'statements', now() - interval '2 minutes', 15, 'error', :'n2');
select pgvigil.log_collection($oid, 'activity', now() - interval '1 minute', 15000, 'error', :'n3');
EOF

# none of the seeded values in a text; $1 = what the text is
clean() {
  local what=$1 text=$2 s
  shift 2
  for s in "$@"; do
    if grep -qF -- "$s" <<<"$text"; then fail "$what holds the seeded value '$s'"; fi
  done
}
unz() { unzip -p "$1" "${2:-*}"; }

echo "== A. pgvigil report"
Z=$WORK/report.zip
OUT=$("$BIN" report -config "$CFG" -out "$Z") || fail "A1: report exited $?"
echo "$OUT"
grep -qF "wrote $Z (6 files, " <<<"$OUT" || fail "A1: the terminal does not name the zip with 6 files"
grep -qxF "  instance-1 = $NAME1" <<<"$OUT" || fail "A1: no 'instance-1 = $NAME1' line"
grep -qxF "  instance-id$oid = $NAME2 (in the repository, not in this configuration file)" <<<"$OUT" || fail "A1: no line for the instance the configuration does not list"
grep -qF "Nothing was sent." <<<"$OUT" || fail "A1: no 'Nothing was sent.'"
grep -qF "support@pgvigil.com" <<<"$OUT" || fail "A1: the support address is not named"
ok "A1 run: exit 0, 6 files, the two names on the terminal only, 'Nothing was sent.'"

[[ $(stat -c %a "$Z") == 600 ]] || fail "A2: the zip's mode is $(stat -c %a "$Z"), want 600"
LIST=$(unzip -Z1 "$Z" | sort | tr '\n' ' ')
[[ "$LIST" == "README.txt collection-errors.txt config.yaml instances.txt repository.txt version.txt " ]] || fail "A2: the zip holds: $LIST"
ok "A2 zip: mode 600, the six files"

[[ "$(unz "$Z" version.txt | head -1)" == "$VLINE" ]] || fail "A3: version.txt starts with '$(unz "$Z" version.txt | head -1)', want '$VLINE'"
unz "$Z" version.txt | head -1 | grep -qF "$VER" || fail "A3: version.txt does not hold $VER"
ok "A3 version: $(unz "$Z" version.txt | head -1)"

ALL=$(unz "$Z")
clean "the zip" "$ALL" "${SECRETS[@]}" "${NAMES[@]}"
clean "the terminal's first lines" "$(head -2 <<<"$OUT")" "${SECRETS[@]}" "${NAMES[@]}"
clean "the terminal" "$OUT" "${SECRETS[@]}"
hits=0; for s in "${SECRETS[@]}" "${NAMES[@]}"; do hits=$((hits + $(grep -cF -- "$s" <<<"$ALL" || true))); done
ok "A4 secrets: grep $hits for ${#SECRETS[@]} secrets and ${#NAMES[@]} names over the six files"

R=$(unz "$Z" repository.txt)
grep -qxF "repository server: PostgreSQL $SRVVER" <<<"$R" || fail "A5: the server version line: $R"
grep -qxF "migration level: $LEVEL" <<<"$R" || fail "A5: the migration level, want $LEVEL: $R"
grep -qF "(the repository is current)" <<<"$R" || fail "A5: not 'the repository is current': $R"
grep -qxF "last runs by status (one per instance and collection): 3 error, 1 ok" <<<"$R" || fail "A5: the status counts: $R"
ok "A5 level: PostgreSQL $SRVVER, migration $LEVEL, current; 3 error, 1 ok"

I=$(unz "$Z" instances.txt)
grep -qP "^instance-1\tpostgres\tonprem\t18\.0\ttrue\t" <<<"$I" || fail "A6: instance-1's line: $I"
grep -qP "^instance-id$oid\tpostgres\trds\t16\.4\ttrue\t" <<<"$I" || fail "A6: the other instance's line: $I"
grep -qxF "2 instance(s)" <<<"$I" || fail "A6: not 2 instances: $I"
ok "A6 instances: instance-1 (postgres onprem 18.0), instance-id$oid (postgres rds 16.4)"

E=$(unz "$Z" collection-errors.txt)
[[ $(grep -cxF "3 row(s)" <<<"$E") == 2 ]] || fail "A7: not '3 row(s)' in both parts: $E"
WANT1='failed to connect to `user=<masked> database=<masked>`: <ip>:5432 (<masked>): server error: FATAL: password authentication failed for user "<masked>" (the string was host=<masked> password=<masked>)'
[[ $(grep -cP "^instance-1\tactivity\t[0-9: -]+\t1200\t" <<<"$E") == 2 ]] || fail "A7: instance-1's activity rows: $E"
[[ $(grep -cF -- "$WANT1" <<<"$E") == 2 ]] || fail "A7: the connection note is not as expected: $E"
[[ $(grep -cF "instance instance-id$oid: canceling statement due to statement timeout" <<<"$E") == 2 ]] || fail "A7: the other instance's note: $E"
grep -qF 'Post "<masked>": dial tcp: lookup <masked>: no such host; then <masked> was refused; the repository string held <masked>' <<<"$E" || fail "A7: the webhook note: $E"
ok "A7 errors: 3 rows in both parts, the notes masked as expected"

C=$(unz "$Z" config.yaml)
for want in "# configuration check: ok" "dsn: env:PGVIGIL_REPO_DSN # set in the environment of this command" "name: instance-1" \
  "platform: onprem" "activity: 30s" "format: slack" "format: teams" "min_severity: critical" "tags: [<masked>]" \
  "url: env:PROOFREP_SLACK_URL # set in the environment of this command" "url: env:PROOFREP_TEAMS_URL # set in the environment of this command" \
  "dsn: <masked> # an inline connection string, keyword form"; do
  grep -qF -- "$want" <<<"$C" || fail "A8: config.yaml lacks '$want': $C"
done
grep -q "commented-out" <<<"$C" && fail "A8: a comment of the file was copied: $C"
ok "A8 config: the check ok, the settings shown, the env: names kept, the inline string and the tag masked, no comment copied"

SUM=$(sha256sum < "$Z")
set +e; "$BIN" report -config "$CFG" -out "$Z" > "$WORK/again.out" 2> "$WORK/again.err"; rc=$?; set -e
[[ $rc == 1 ]] || fail "A9: a second run on the same file exited $rc, want 1"
grep -qF "exists already" "$WORK/again.err" || fail "A9: no 'exists already': $(cat "$WORK/again.err")"
[[ "$(sha256sum < "$Z")" == "$SUM" ]] || fail "A9: the zip changed"
ok "A9 again: exit 1, the zip unchanged"

ZN=$WORK/named.zip
OUTN=$("$BIN" report -config "$CFG" -out "$ZN" -names) || fail "A10: report -names exited $?"
ALLN=$(unz "$ZN")
clean "the -names zip" "$ALLN" "${SECRETS[@]}" "$HOST" "$LOGIN" "$DBNAME" "10.20.30.40"
unz "$ZN" config.yaml | grep -qF "name: $NAME1" || fail "A10: -names: config.yaml lacks the instance name"
unz "$ZN" collection-errors.txt | grep -qF "instance $NAME2: canceling statement" || fail "A10: -names: the note lacks the instance name"
grep -q "instance-1 = " <<<"$OUTN" && fail "A10: -names printed an alias list"
ok "A10 -names: the two instance names kept, the secrets and the other names still out"

psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create role $COLL login in role pgvigil_collector" -c "create role $READER login in role pgvigil_reader" >/dev/null
ZC=$WORK/coll.zip
"$BIN" report -config "$CFG" -out "$ZC" -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB user=$COLL" >/dev/null || fail "A11: report as the collector login exited $?"
unz "$ZC" repository.txt | grep -qxF "migration level: $LEVEL" || fail "A11: the collector login did not read the migration level: $(unz "$ZC" repository.txt)"
unz "$ZC" instances.txt | grep -qF "this login may not read it" || fail "A11: instances.txt as the collector: $(unz "$ZC" instances.txt)"
[[ $(unz "$ZC" collection-errors.txt | grep -cF "this login may not read it") == 2 ]] || fail "A11: collection-errors.txt as the collector: $(unz "$ZC" collection-errors.txt)"
ZR=$WORK/reader.zip
"$BIN" report -config "$CFG" -out "$ZR" -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB user=$READER" >/dev/null || fail "A11: report as the reader login exited $?"
unz "$ZR" instances.txt | grep -qxF "2 instance(s)" || fail "A11: instances.txt as the reader: $(unz "$ZR" instances.txt)"
[[ $(unz "$ZR" collection-errors.txt | grep -cxF "3 row(s)") == 2 ]] || fail "A11: collection-errors.txt as the reader: $(unz "$ZR" collection-errors.txt)"
ok "A11 logins: the collector's reads the level and says what it may not read; the reader's reads all"

ZX=$WORK/norepo.zip
"$BIN" report -config "$CFG" -out "$ZX" -dsn "host=127.0.0.1 port=1 user=$LOGIN password=$FLAG_PW dbname=$DBNAME" >/dev/null || fail "A12: report without a repository exited $?"
unz "$ZX" repository.txt | grep -qF "repository: not read: no connection: " || fail "A12: repository.txt: $(unz "$ZX" repository.txt)"
clean "the no-repository zip" "$(unz "$ZX")" "$FLAG_PW" "${SECRETS[@]}" "$LOGIN" "$DBNAME"
[[ "$(unz "$ZX" version.txt | head -1)" == "$VLINE" ]] || fail "A12: version.txt"
ok "A12 no repository: exit 0, 'not read: no connection', the -dsn's password out"

set +e; "$BIN" report -config "$CFG" -out "$WORK/usage.zip" -errors 0 >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 2 && ! -e "$WORK/usage.zip" ]] || fail "A13: -errors 0 exited $rc (want 2) or wrote a zip"
ok "A13 usage: -errors 0 exits 2 and writes nothing"

A_DONE="A1-A14"
RHOST=$(grep -oP '(?<![a-z])host=\K[^ ]+' <<<"$PGVIGIL_ADMIN_DSN" | tail -1 || true)
RPORT=$(grep -oP '(?<![a-z])port=\K[0-9]+' <<<"$PGVIGIL_ADMIN_DSN" | tail -1 || true); RPORT=${RPORT:-5432}
A14_WHY=""
if ! command -v strace >/dev/null; then A14_WHY="strace is not on this machine"
elif ! [[ "$RHOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then A14_WHY="the admin connection's host is not an IPv4 address"
fi
if [[ -z "$A14_WHY" ]]; then
  strace -f -qq -e trace=connect -o "$WORK/connect.log" "$BIN" report -config "$CFG" -out "$WORK/strace.zip" >/dev/null || fail "A14: report under strace exited $?"
  total=$(grep -c 'connect(' "$WORK/connect.log" || true)
  repo=$(grep -cF "sin_port=htons($RPORT), sin_addr=inet_addr(\"$RHOST\")" "$WORK/connect.log" || true)
  [[ $repo -ge 1 && $total == "$repo" ]] || fail "A14: $total connect() calls, $repo of them to the repository at $RHOST:$RPORT; another: $(grep 'connect(' "$WORK/connect.log" | grep -vF "inet_addr(\"$RHOST\")" | head -3)"
  unz "$WORK/strace.zip" instances.txt | grep -qxF "2 instance(s)" || fail "A14: the traced run did not read the repository"
  ok "A14 connects: $total connect() calls, all to the repository at $RHOST:$RPORT"
else
  echo "NOT PROVEN (A14): $A14_WHY"
  A_DONE="A1-A13; A14 not proven: $A14_WHY"
fi

C_WHY=""
if [[ "${PGVIGIL_PROOF_NO_RENDER:-}" == 1 ]]; then
  C_WHY="skipped by PGVIGIL_PROOF_NO_RENDER"
elif ! command -v chromium >/dev/null || ! command -v node >/dev/null; then
  C_WHY="chromium or node is not on this machine"
elif ! grep -qF "Report a problem" internal/web/dist/app.js; then
  C_WHY="the web bundle does not hold the About page (cd web && npm ci && npm run build, with the page wired into router.ts and main.ts)"
fi
if [[ -n "$C_WHY" ]]; then
  echo "NOT PROVEN (C): $C_WHY"
  echo "proof-report: PASS ($A_DONE; C not proven: $C_WHY)"
  exit 0
fi

echo "== C. the About page on 127.0.0.1:$PORT, a headless Chromium on CDP $CDP"
for p in $PORT $CDP; do ss -ltnH "( sport = :$p )" | grep -q . && fail "port $p is in use: run again"; done
"$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 &
SRV=$!
for _ in $(seq 1 100); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/serve.log"; fail "serve died"; }; sleep 0.2; done
curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null || { tail -5 "$WORK/serve.log"; fail "serve did not come up"; }
command -v setsid >/dev/null || fail "setsid is not on this machine"
setsid chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 < /dev/null &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium did not start: its CDP port never answered (PGVIGIL_PROOF_NO_RENDER=1 skips part C)"
cat > "$WORK/about-check.mjs" <<'EOF'
// node about-check.mjs <cdp port> <base url/> <version line> <short version> <server version> <migration> <name 1> <name 2>
const [port, base, vline, ver, srvver, level, name1, name2] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(); const requests = [];
ws.onmessage = m => {
  const d = JSON.parse(m.data);
  if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); }
  if (d.method === 'Network.requestWillBeSent') requests.push({ url: d.params.request.url, method: d.params.request.method });
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => {
  const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true, userGesture: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};
let failed = 0;
const check = (name, okay, detail) => { console.log(`${okay ? 'ok  ' : 'FAIL'} ${name}: ${detail}`); if (!okay) failed++; };
await send('Network.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url: base + '#/summary' });
let link = false;
for (let i = 0; i < 60 && !link; i++) { await sleep(250); link = await ev(`!![...document.querySelectorAll('#bar a')].find(a => a.textContent === 'About')`); }
check('C bar', link, "the bar's About link on the Summary page");
if (link) await ev(`[...document.querySelectorAll('#bar a')].find(a => a.textContent === 'About').click()`);
let shown = false;
for (let i = 0; i < 60 && !shown; i++) { await sleep(250); shown = await ev(`[...document.querySelectorAll('main h2')].some(h => h.textContent === 'About pgvigil')`); }
const hash = await ev('location.hash');
check('C page', shown && hash.startsWith('#/about'), `the About page at ${hash}`);
const p = await ev(`(() => {
  const links = [...document.querySelectorAll('main a')];
  const mail = links.find(a => a.textContent === 'Report a problem');
  return {
    href: mail ? mail.getAttribute('href') : '', ua: navigator.userAgent,
    pre: document.querySelector('main pre')?.textContent ?? '',
    props: [...document.querySelectorAll('main table.props tr')].map(tr => tr.children[0].textContent + '=' + tr.children[1].textContent),
    support: links.some(a => a.getAttribute('href') === 'mailto:support@pgvigil.com' && a.textContent === 'support@pgvigil.com'),
    security: links.find(a => a.textContent === 'Report a vulnerability on GitHub')?.getAttribute('href') ?? '',
  };
})()`);
const m = /^mailto:([^?]+)\?subject=([^&]*)&body=(.*)$/.exec(p.href);
check('C mailto', !!m && m[1] === 'support@pgvigil.com', `'Report a problem' is a mailto link to ${m ? m[1] : '(none: ' + p.href.slice(0, 60) + ')'}`);
const subject = m ? decodeURIComponent(m[2]) : '', body = m ? decodeURIComponent(m[3]) : '';
check('C subject', subject === `pgvigil problem report (${ver})`, `the subject '${subject}'`);
const lines = body.split('\r\n');
const want = [`pgvigil: ${vline}`, `Repository: PostgreSQL ${srvver}, migration ${level.replace(/\.sql$/, '')}`,
  'Monitored: 1 x PostgreSQL 16.4 (rds); 1 x PostgreSQL 18.0 (onprem)', `Browser: ${p.ua}`];
for (const w of want) check('C body', lines.includes(w), `the line '${w}'`);
check('C body start', lines[0] === 'What happened, what you expected instead, and the page it was on:', `the first line '${lines[0]}'`);
const origin = new URL(base);
const leaks = [name1, name2, origin.host, origin.hostname, 'proofrep'].filter(s => body.includes(s) || subject.includes(s));
check('C no names', leaks.length === 0, leaks.length ? `the mail holds ${leaks.join(', ')}` : 'no instance name and no address of this server in the mail');
check('C page lines', p.pre === body.replace(/\r\n/g, '\n'), 'the page shows the lines the mail starts with');
check('C props', p.props.includes(`Version=${vline}`), `the page's Version row: ${p.props.find(x => x.startsWith('Version=')) ?? '(none)'}`);
check('C support', p.support, 'the support address is a mailto link of its own');
check('C security', p.security === 'https://github.com/aachaemenes/pgvigil/security/advisories/new', `the vulnerability link ${p.security}`);
const away = requests.filter(r => !r.url.startsWith(base) && !r.url.startsWith('data:') && r.url !== 'about:blank');
const posts = requests.filter(r => r.method !== 'GET');
check('C nothing sent', away.length === 0 && posts.length === 0 && requests.length > 0,
  `${requests.length} requests, ${away.length} to another address${away.length ? ' (' + away[0].url.slice(0, 80) + ')' : ''}, ${posts.length} not a GET`);
ws.close();
process.exit(failed ? 1 : 0);
EOF
node "$WORK/about-check.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$VLINE" "$VER" "$SRVVER" "$LEVEL" "$NAME1" "$NAME2" || fail "C: a check of the About page did not hold"
echo "proof-report: PASS ($A_DONE, C)"
