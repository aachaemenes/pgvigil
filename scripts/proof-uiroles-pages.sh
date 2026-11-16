#!/usr/bin/env bash
# proof-uiroles-pages.sh - the per-user roles as the pages draw them (task B24f, R4): pgvigil serve with the UI login on
# a repository the demo seeded, and a headless Chromium that signs in as a viewer, as an operator and as an admin and
# reads every write control of every root page and of one PostgreSQL and one SQL Server instance's pages
# (scripts/roles-check.mjs: a control carries data-need; above the role it is off with the server's refusal words,
# or with the server's own reason, which comes first; at or below the role it is never off for the role).
# The server's side - each route refused below its need - is scripts/proof-uiroles.sh.
#
#   PGVIGIL_ADMIN_DSN    keyword-form connection to a cluster as a superuser (the proof makes its database with a
#                        random suffix and drops it at the end)
#   PGVIGIL_BIN          the build to prove (its embedded pages are the ones read); default bin/pgvigil
#   PGVIGIL_DEMO_WAIT_S  the seed's time limit, default 600
#   PGVIGIL_PAGES_ONLY   'week': the 7-day row alone (no R4 walk of the three roles)
#
# This serve: the repository's own dsn and no instance in its file, so acknowledgements, thresholds, alert rules and
# applications are written here (the role's words show on their controls), and the seeded instances have no actions
# door (cancel, KILL, a job's start, EXPLAIN stay off for the server's own reason: counted, never a FAIL).
#
# Expected (written before its first run):
#   on a build whose pages mark nothing (rel-roles 1daa94a, the red run): per role 'signed in' ok; the header row FAIL
#     (no #role-note); every 'must' row FAIL (10: no control with data-need), every 'words' / 'on' row FAIL (5), the
#     click row FAIL (no Silence with data-need);
#     'roles-check <role>: ... 0 with a control that carries a need'; 'proof-uiroles-pages: 3 role(s) FAIL', rc 1.
#   on the build with the pages: per role 0 FAIL - viewer: the 10 must rows ok, the 5 words rows ok (alerts and an
#     instance's Summary with the operator words; the root Thresholds, Drives and Applications with the admin words),
#     no control on above the role; operator: the 10 must rows, 'on alerts' and 'on pg:summary' ok, the 3 admin words
#     rows ok; admin: the 10 must rows, the 5 'on' rows ok, 0 controls off for the role. Every page rendered.
#     The click row per role: a viewer's click on the off Silence opens nothing; an operator's and an admin's opens
#     its dialog, whose Save carries the operator need and is not off for the role (closed, nothing saved).
#     review-18 part 3 (written before the run that carries it): a button with a need off by the disabled attribute, and
#     a control off for the server's own reason with no words (no title, no visible description), are FAILs; five dialog
#     rows per role - a job's thresholds (opener open to every role: the viewer's and the operator's Save and Inherit
#     off with the admin words, the admin's on), the drive thresholds, a PostgreSQL threshold, a new alert rule and a
#     new mail schedule (openers that need admin: off for the viewer and the operator with the role's words, a click
#     opens nothing; the admin's opens the dialog, no control off for the role).
#     'PASS: proof-uiroles-pages'.
#   The 7-day rows (review-21; written before the run that carries them; scripts/roles-mute-week.mjs):
#     as the operator, the page's clock 60 s ahead of the server's, on one PostgreSQL instance (not roles-check's): the
#     header's Silence with '7 days' picked, and the Alerts page's New mute rule on that instance with '7 days after the
#     start' (start at once), each saved and graded by its own POST /api/ack (the body's until, the answer) - on
#     rel-roles f421753c (each dialog's 7 days = 168 h by the page's clock): two 'FAIL week: ... 403 {"error":"a
#     fleet-wide or open-ended mute needs the admin role: ..."}; its end ... 168.0167 h ...' lines; with the dialogs'
#     7 days 10 minutes short: two 'ok   week: ... 200 {..."outcome":"done"...}; its end ... 167.85 h ...' lines.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
BIN=$(realpath "${PGVIGIL_BIN:-bin/pgvigil}")
SUF=$RANDOM; DB=pgvigil_rolespages_$SUF
WORK=$(mktemp -d); SRV=""; CHR=""
die() { echo "FAIL: $*"; exit 1; }
cleanup() {
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  [[ -n "$SRV" ]] && kill -9 "$SRV" 2>/dev/null || true
  wait 2>/dev/null || true
  for _ in $(seq 1 10); do
    psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 && break
    sleep 0.5
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in psql curl ss chromium node; do command -v $t >/dev/null || die "$t is not on this machine"; done
grep -q 'role-note' internal/web/dist/app.js 2>/dev/null || echo "note: the web bundle in the tree has no role line (the build under proof embeds its own pages)"
freeport() {
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 12000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  die "no free port"
}
echo "== the machine's load at the start: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || die "create database $DB"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
CFG=$WORK/none.yaml
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.log" 2>&1 || die "migrate: $(tail -3 "$WORK/migrate.log")"
timeout "${PGVIGIL_DEMO_WAIT_S:-600}" "$BIN" demo -config "$CFG" -days 1 > "$WORK/seed.log" 2>&1 || die "the demo seed failed or passed ${PGVIGIL_DEMO_WAIT_S:-600} s: $(tail -3 "$WORK/seed.log")"
echo "ok   migrate, and the demo seeded into $DB"

PW() { echo "pw-$1-$SUF-long-enough"; }
declare -A USER=([admin]=pa$SUF [operator]=po$SUF [viewer]=pv$SUF)
# the admin first: the repository's first enabled admin
for role in admin operator viewer; do
  out=$(PGVIGIL_PASSWORD=$(PW "${USER[$role]}") "$BIN" user add -config "$CFG" -role "$role" "${USER[$role]}" 2>&1) || die "user add -role $role: $out"
done

PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 & SRV=$!
for _ in $(seq 1 120); do curl -sf -o /dev/null "$U/" && break; kill -0 $SRV 2>/dev/null || die "serve died: $(tail -3 "$WORK/serve.log")"; sleep 0.5; done
curl -sf -o /dev/null "$U/" || die "serve did not answer in 60 s: $(tail -3 "$WORK/serve.log")"
CDP=$(freeport)
chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || die "chromium's CDP port never answered"

BADROLES=0; WEEKBAD=0
[[ ${PGVIGIL_PAGES_ONLY:-} == week ]] && echo "note: PGVIGIL_PAGES_ONLY=week - no R4 walk"
for role in viewer operator admin; do
  [[ ${PGVIGIL_PAGES_ONLY:-} == week ]] && break
  echo "== R4 as ${USER[$role]} ($role)"
  timeout 1500 node scripts/roles-check.mjs "$CDP" "$U/" "${USER[$role]}" "$(PW "${USER[$role]}")" "$role"; rc=$?
  (( rc == 0 )) || { BADROLES=$((BADROLES + 1)); echo "FAIL roles-check $role: rc $rc"; }
done
echo "== the load at the end: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown); role refusals in serve's log: $(grep -c 'role refused' "$WORK/serve.log")"
# the 7-day end: an operator's Silence with '7 days' picked, the page's clock ahead of the server's
echo "== week as ${USER[operator]} (operator)"
timeout 300 node scripts/roles-mute-week.mjs "$CDP" "$U/" "${USER[operator]}" "$(PW "${USER[operator]}")"; rc=$?
(( rc == 0 )) || { WEEKBAD=1; echo "FAIL roles-mute-week: rc $rc"; }
if (( BADROLES || WEEKBAD )); then echo "proof-uiroles-pages: $BADROLES role(s) FAIL, the 7-day row $( (( WEEKBAD )) && echo FAIL || echo ok)"; exit 1; fi
echo "PASS: proof-uiroles-pages$([[ ${PGVIGIL_PAGES_ONLY:-} == week ]] && echo " (the 7-day rows only)")"
