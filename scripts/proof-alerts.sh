#!/usr/bin/env bash
# Proof of alerts out (migration 0059, internal/alerts, task 60) on the sandbox: the demo fleet's findings sent to a
# loopback SMTP sink and a loopback HTTP listener this script runs itself, and to file drops in its own directory.
# Nothing leaves the machine: every destination is 127.0.0.1 or a local directory.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database (random
#                      suffix) and drops it at the end.
#   PGVIGIL_BIN        a build with the alerts command and the /api/alerts route (the lead's wiring; default bin/pgvigil).
#   python3            the SMTP sink and the HTTP listener.
#
# Expected (written before the first run; N = the distinct critical finding keys of the seeded demo, K = those of the
# instance D deactivates, both read from the repository before the sends):
#  A. a configuration without alerts: `pgvigil alerts` prints "no channel configured: nothing sent"; alert_log holds one
#     row, outcome 'none', channel NULL; alert_state 0 rows; the sink and the listener received nothing.
#  B. channels at min_severity critical: mail (SMTP, tls none, loopback), hook (webhook json), drop (file), drop2 (file,
#     recovery false), redir (a webhook the listener answers with a 307 elsewhere), dead (a webhook to a closed port),
#     night (a file drop inside its quiet hours). One run (exit 1: two channels did not send):
#     the sink 1 message holding N "[FIRING CRITICAL]" lines; the listener 1 POST on /hook with N alerts, 0 hits on
#     /elsewhere; drop N files, drop2 N files, night 0 files; alert_log: mail 1 sent, hook 1 sent, drop N sent, drop2
#     N sent, redir 1 refused (error "redirect: not followed"), dead 1 failed (error "connection refused"); alert_state
#     open 4N (mail, hook, drop, drop2); alert_channels 7 rows configured; the command's line names night under quiet hours.
#  C. a second run at once: nothing new sent (the sink 1, the listener 1, drop N files); redir and dead tried again
#     (refused, failed). mail's open rows moved 6 minutes back (repeat 5m): the third run sends mail 1 message of N
#     "[REPEAT CRITICAL]" lines and nothing to hook or drop (repeat 24h); mail's send_count 2 on every open row.
#  D. the instance with the most critical findings deactivated (is_active false: its findings leave the view): the next
#     run sends mail 1 message of K "[RESOLVED]" lines, hook 1 POST with K events 'resolved', drop K files named
#     *-resolved-*; drop2 no new file and one alert_log row outcome 'cleared' with n_resolved K; alert_state: 4K rows
#     cleared, recovery_sent_at set on 3K (mail, hook, drop) and NULL on drop2's K; open 4(N-K).
#  E. the loop inside `pgvigil run` (an instance: a sandbox database of the proof's own), with the channels dead and
#     drop3 (a file drop scoped to the proof's instance alone) only, for about 70 s: dead logs at least one more
#     'failed' row with its error, the process is still running at the end, and its log says "alerts: channel failed".
#  F. the API (`pgvigil serve -no-login` on loopback): /api/alerts answers channels (8 rows: B's 7, five of them no
#     longer configured after E's run, and drop3), open rows of mail, hook, drop and drop2: 4(N-K), a log of the last
#     hour with the 'none', 'sent', 'refused', 'failed' and 'cleared' outcomes; /api/findings: N-K rows carry
#     alert_last_sent with an alert_channels list holding mail.
#     [first run: 13 findings carried alert_last_sent, not 4: E's drop3 sent the proof instance's own findings, so the
#     check counts the findings sent to mail. With D's fold, N-K reads N2 (the critical keys still in the view after
#     D) and the mail count N3 (mail's open rows whose finding is still in the view at F).]
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_alertsproof_$SUF; MDB=pgvigil_alertsmon_$SUF
WORK=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$WORK"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" -c "drop database if exists $MDB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" -c "create database $MDB" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
mkdir -p "$WORK/smtp" "$WORK/http" "$WORK/drop" "$WORK/drop2" "$WORK/night"

# ---- the loopback SMTP sink: every message's DATA into $WORK/smtp/<n>.eml ----------------------------------------
SMTP_PORT=$(freeport)
cat > "$WORK/sink.py" <<'PY'
import socketserver, sys, os, itertools
out = sys.argv[2]; n = itertools.count(1)
class H(socketserver.StreamRequestHandler):
    def say(self, l): self.wfile.write((l + "\r\n").encode())
    def handle(self):
        self.say("220 sink")
        while True:
            l = self.rfile.readline()
            if not l: return
            c = l.decode(errors="replace").strip().upper()
            if c.startswith("EHLO") or c.startswith("HELO"): self.say("250 sink")
            elif c.startswith("MAIL") or c.startswith("RCPT") or c.startswith("RSET") or c.startswith("NOOP"): self.say("250 ok")
            elif c == "DATA":
                self.say("354 go"); buf = []
                while True:
                    d = self.rfile.readline()
                    if not d or d == b".\r\n": break
                    buf.append(d)
                p = os.path.join(out, "%d.eml" % next(n))
                open(p + ".tmp", "wb").write(b"".join(buf)); os.rename(p + ".tmp", p)
                self.say("250 queued")
            elif c == "QUIT": self.say("221 bye"); return
            else: self.say("502 no")
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/sink.py" "$SMTP_PORT" "$WORK/smtp" 2>"$WORK/sink.log" & PIDS+=($!)

# ---- the loopback HTTP listener: POST /hook* bodies into $WORK/http/<n>.json; /redirect answers 307 to /elsewhere --
HTTP_PORT=$(freeport)
cat > "$WORK/listen.py" <<'PY'
import http.server, sys, os, itertools
out = sys.argv[2]; n = itertools.count(1)
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path.startswith("/redirect"):
            self.send_response(307); self.send_header("Location", "/elsewhere"); self.end_headers(); return
        if self.path.startswith("/elsewhere"):
            open(os.path.join(out, "elsewhere"), "a").write("hit\n")
        else:
            p = os.path.join(out, "%d.json" % next(n))
            open(p + ".tmp", "wb").write(body); os.rename(p + ".tmp", p)
        self.send_response(200); self.end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/listen.py" "$HTTP_PORT" "$WORK/http" 2>"$WORK/listen.log" & PIDS+=($!)
DEAD_PORT=$(freeport)   # nothing listens there
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$SMTP_PORT) 2>/dev/null && (exec 3<>/dev/tcp/127.0.0.1/$HTTP_PORT) 2>/dev/null && break; sleep 0.1; done
export PGV_PROOF_HOOK="http://127.0.0.1:$HTTP_PORT/hook/secret-token"
export PGV_PROOF_REDIR="http://127.0.0.1:$HTTP_PORT/redirect/secret-token"
export PGV_PROOF_DEAD="http://127.0.0.1:$DEAD_PORT/hook/secret-token"
smtp_count() { find "$WORK/smtp" -name '*.eml' | wc -l; }
http_count() { find "$WORK/http" -name '*.json' | wc -l; }
newest() { ls -1 "$1" | sort -n | tail -1; }

# ---- A: no channel -----------------------------------------------------------------------------------------------
cat > "$WORK/none.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
EOF
"$BIN" migrate -config "$WORK/none.yaml" >/dev/null 2>&1
"$BIN" demo -config "$WORK/none.yaml" -days 1 >/dev/null 2>&1
# the demo's own alert record (the demo-spool channel over the history) is cleared: the proof counts its own rows
q "delete from pgvigil.alert_state; delete from pgvigil.alert_log; delete from pgvigil.alert_channels" >/dev/null
out=$("$BIN" alerts -config "$WORK/none.yaml")
[[ $out == *"no channel configured: nothing sent"* ]] || fail "A: the command said: $out"
[[ $(q "select count(*), count(*) filter (where outcome = 'none' and channel is null) from pgvigil.alert_log") == "1|1" ]] || fail "A: alert_log $(q 'select * from pgvigil.alert_log')"
[[ $(q "select count(*) from pgvigil.alert_state") == 0 ]] || fail "A: alert_state not empty"
[[ $(smtp_count) == 0 && $(http_count) == 0 ]] || fail "A: something was sent"
ok "A: no channel, nothing sent, the log's 'none' row"

N=$(q "select count(distinct finding_key) from pgvigil.alert_findings where severity = 'critical'")
DEACT=$(q "select instance from pgvigil.alert_findings where severity = 'critical' group by instance order by count(distinct finding_key) desc, instance limit 1")
K=$(q "select count(distinct finding_key) from pgvigil.alert_findings where severity = 'critical' and instance = '$DEACT'")
(( N > 0 && K > 0 && K < N )) || fail "the demo's critical findings: N=$N K=$K"
echo "N=$N critical finding(s); D deactivates $DEACT (K=$K)"

# ---- B: the channels ---------------------------------------------------------------------------------------------
H0=$(date -u +%H); H2=$(( (10#$H0 + 2) % 24 ))
cat > "$WORK/alerts.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts:
  - {name: mail, kind: smtp, min_severity: critical, repeat: 5m,
     smtp: {host: 127.0.0.1, port: $SMTP_PORT, tls: none, from: pgvigil@example.org, to: [dba@example.org]}}
  - {name: hook, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_HOOK, format: json}}
  - {name: drop, kind: file, min_severity: critical, file: {dir: $WORK/drop}}
  - {name: drop2, kind: file, min_severity: critical, recovery: false, file: {dir: $WORK/drop2}}
  - {name: redir, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_REDIR, format: slack}}
  - {name: dead, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_DEAD, format: teams}}
  - {name: night, kind: file, min_severity: critical, quiet_hours: "$(printf %02d $((10#$H0))):00-$(printf %02d $H2):00", file: {dir: $WORK/night}}
EOF
set +e; out=$("$BIN" alerts -config "$WORK/alerts.yaml" 2>"$WORK/b.err"); rc=$?; set -e
echo "B: $out (exit $rc)"
(( rc == 1 )) || fail "B: exit $rc, want 1 (two channels did not send); $(cat "$WORK/b.err")"
[[ $out == *"quiet hours: night"* ]] || fail "B: night is not named under quiet hours"
[[ $(smtp_count) == 1 ]] || fail "B: the sink holds $(smtp_count) message(s)"
[[ $(grep -c '^\[FIRING CRITICAL\]' "$WORK/smtp/1.eml") == "$N" ]] || fail "B: the mail's firing lines: $(grep -c '^\[FIRING CRITICAL\]' "$WORK/smtp/1.eml")"
[[ $(http_count) == 1 ]] || fail "B: the listener holds $(http_count) post(s)"
[[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["alerts"]), {a["event"] for a in d["alerts"]}=={"firing"})' "$WORK/http/1.json") == "$N True" ]] || fail "B: the hook's body"
[[ ! -e "$WORK/http/elsewhere" ]] || fail "B: the redirect was followed"
[[ $(ls "$WORK/drop" | wc -l) == "$N" && $(ls "$WORK/drop2" | wc -l) == "$N" && $(ls "$WORK/night" | wc -l) == 0 ]] || fail "B: files drop $(ls "$WORK/drop" | wc -l), drop2 $(ls "$WORK/drop2" | wc -l), night $(ls "$WORK/night" | wc -l)"
python3 -c 'import json,sys,glob; [json.load(open(p)) for p in glob.glob(sys.argv[1]+"/*.json")]' "$WORK/drop" || fail "B: a dropped file is not JSON"
log=$(q "select channel || ':' || outcome || ':' || count(*) from pgvigil.alert_log where channel is not null group by channel, outcome order by 1" | tr '\n' ' ')
[[ $log == "dead:failed:1 drop2:sent:$N drop:sent:$N hook:sent:1 mail:sent:1 redir:refused:1 " ]] || fail "B: alert_log $log"
[[ $(q "select error from pgvigil.alert_log where channel = 'redir'") == *"redirect: not followed"* ]] || fail "B: redir's error"
[[ $(q "select error from pgvigil.alert_log where channel = 'dead'") == *"connection refused"* ]] || fail "B: dead's error $(q "select error from pgvigil.alert_log where channel = 'dead'")"
[[ $(q "select count(*) from pgvigil.alert_log where error like '%secret-token%'") == 0 ]] || fail "B: an error shows a webhook token"
[[ $(q "select count(*) from pgvigil.alert_state where cleared_at is null") == $((4 * N)) ]] || fail "B: open rows $(q "select count(*) from pgvigil.alert_state where cleared_at is null")"
[[ $(q "select count(*) from pgvigil.alert_channels where is_configured") == 7 ]] || fail "B: alert_channels"
[[ $(q "select count(*) from pgvigil.alert_channels where destination like '%secret-token%'") == 0 ]] || fail "B: a destination shows a webhook token"
ok "B: mail 1 message of $N, hook 1 post of $N, drop and drop2 $N files each, night held, redir refused, dead failed"

# ---- C: repeat -----------------------------------------------------------------------------------------------------
"$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(smtp_count) == 1 && $(http_count) == 1 && $(ls "$WORK/drop" | wc -l) == "$N" ]] || fail "C: the second run sent again"
[[ $(q "select count(*) from pgvigil.alert_log where channel in ('redir', 'dead')") == 4 ]] || fail "C: redir and dead not tried again"
q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '6 minutes' where channel = 'mail' and cleared_at is null" >/dev/null
"$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(smtp_count) == 2 ]] || fail "C: the repeat: the sink holds $(smtp_count)"
[[ $(grep -c '^\[REPEAT CRITICAL\]' "$WORK/smtp/2.eml") == "$N" ]] || fail "C: the repeat's lines"
[[ $(http_count) == 1 && $(ls "$WORK/drop" | wc -l) == "$N" ]] || fail "C: hook or drop repeated before 24h"
[[ $(q "select min(send_count) || '|' || max(send_count) from pgvigil.alert_state where channel = 'mail' and cleared_at is null") == "2|2" ]] || fail "C: mail's send_count"
ok "C: a standing finding sent once in two runs; again after the repeat interval, mail only"

# ---- D: recovery -----------------------------------------------------------------------------------------------------
q "update pgvigil.instances set is_active = false where name = '$DEACT'" >/dev/null
"$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(smtp_count) == 3 ]] || fail "D: the sink holds $(smtp_count) message(s); alert_log: $(q "select channel || ':' || outcome || ':' || n_firing || '/' || n_repeat || '/' || n_resolved from pgvigil.alert_log where channel = 'mail' order by snapshot_at" | tr '\n' ' ')"
# [runs 1 and 3: D failed on the mail's RESOLVED line count, runs 2 and 4 passed. Root cause: a demo finding defined
#  over a recent time window can enter or leave the view between the pass and a later read of the view, so a count
#  taken from the view after the pass races the pass. The checks now count the deactivated instance's alerts (K, fixed
#  before the pass) and grade the rest against what the pass itself recorded: mail's rows cleared at the pass's time
#  are the message's RESOLVED lines, and the four channels hold the same open rows.]
DCLR=$(q "select count(*) from pgvigil.alert_state where channel = 'mail' and cleared_at = (select max(cleared_at) from pgvigil.alert_state where channel = 'mail')")
[[ $(grep -c "^\[RESOLVED\] $DEACT:" "$WORK/smtp/3.eml") == "$K" ]] || fail "D: the mail's resolved lines of $DEACT: $(grep '^\[' "$WORK/smtp/3.eml")"
[[ $(grep -c '^\[RESOLVED\]' "$WORK/smtp/3.eml") == "$DCLR" ]] || fail "D: the mail's resolved lines are not mail's $DCLR rows cleared by the pass: $(grep '^\[' "$WORK/smtp/3.eml")"
[[ $(http_count) == 2 ]] || fail "D: the hook's posts $(http_count)"
[[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); a=[x for x in d["alerts"] if x["instance"]==sys.argv[2]]; print(len(a), {x["event"] for x in a}=={"resolved"})' "$WORK/http/2.json" "$DEACT") == "$K True" ]] || fail "D: the hook's body"
[[ $(grep -l "\"instance\": \"$DEACT\"" "$WORK"/drop/*-resolved-* 2>/dev/null | wc -l) == "$K" ]] || fail "D: drop's resolved files of $DEACT"
[[ $(ls "$WORK/drop2" | grep -c -- '-resolved-') == 0 ]] || fail "D: drop2 (recovery false) wrote a resolved file"
[[ $(q "select outcome || ':' || n_resolved from pgvigil.alert_log where channel = 'drop2' and outcome = 'cleared'") == "cleared:$DCLR" ]] || fail "D: drop2's cleared row"
[[ $(q "select count(*), count(recovery_sent_at) from pgvigil.alert_state where cleared_at is not null and instance_name = '$DEACT'") == "$((4 * K))|$((3 * K))" ]] || fail "D: cleared rows of $DEACT"
N2=$(q "select count(*) from pgvigil.alert_state where channel = 'mail' and cleared_at is null")
[[ $(q "select string_agg(distinct n::text, ',') from (select count(*) filter (where cleared_at is null) n from pgvigil.alert_state where channel in ('mail', 'hook', 'drop', 'drop2') group by channel) x") == "$N2" ]] || fail "D: the four channels' open rows differ"
(( N2 > 0 && N2 <= N - K + 2 )) || fail "D: mail's open rows $N2 (N-K = $((N - K)))"
ok "D: recovery to mail, hook and drop ($K each), drop2 cleared silently"

# ---- E: the loop inside pgvigil run ----------------------------------------------------------------------------------
cat > "$WORK/run.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-alerts-$SUF
    dsn: "$ADMIN_DSN dbname=$MDB"
alerts:
  - {name: drop3, kind: file, min_severity: info, instances: [proof-alerts-$SUF], file: {dir: $WORK/drop3}}
  - {name: dead, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_DEAD, format: teams}}
EOF
mkdir -p "$WORK/drop3"
before=$(q "select count(*) from pgvigil.alert_log where channel = 'dead'")
"$BIN" run -config "$WORK/run.yaml" > "$WORK/run.log" 2>&1 & RUN=$!; PIDS+=($RUN)
sleep 70
kill -0 $RUN 2>/dev/null || { tail -20 "$WORK/run.log"; fail "E: pgvigil run stopped"; }
after=$(q "select count(*) from pgvigil.alert_log where channel = 'dead' and outcome = 'failed' and error like '%connection refused%'")
(( after > before )) || fail "E: dead's failed rows $before -> $after"
grep -q 'alerts: channel failed' "$WORK/run.log" || fail "E: the run's log does not say a channel failed"
kill $RUN; wait $RUN 2>/dev/null || true
ok "E: the loop logs dead's error ($before -> $after failed rows) and goes on"

# ---- F: the API -------------------------------------------------------------------------------------------------------
UI_PORT=$(freeport)
"$BIN" serve -config "$WORK/none.yaml" -no-login -listen "127.0.0.1:$UI_PORT" > "$WORK/serve.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 100); do curl -fs "http://127.0.0.1:$UI_PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$UI_PORT/api/alerts" > "$WORK/alerts.json" || fail "F: /api/alerts"
curl -fs "http://127.0.0.1:$UI_PORT/api/findings" > "$WORK/findings.json" || fail "F: /api/findings"
# the findings the Findings column shows as sent to mail: mail's open rows whose finding is still in the view
N3=$(q "select count(*) from pgvigil.alert_state s where s.channel = 'mail' and s.cleared_at is null and exists (select 1 from pgvigil.alert_findings f where f.finding_key = s.finding_key)")
python3 - "$WORK/alerts.json" "$WORK/findings.json" "$N2" "$N3" <<'PY' || fail "F: the API's rows"
import json, sys
a = json.load(open(sys.argv[1])); f = json.load(open(sys.argv[2])); N2, N3 = int(sys.argv[3]), int(sys.argv[4])
def rows(t):
    return [dict(zip(t["columns"], r)) for r in t["rows"]] if t and "columns" in t else (t or [])
ch, op, lg = rows(a["channels"]), rows(a["open"]), rows(a["log"])
names = sorted(c["name"] for c in ch)
assert names == ["dead", "drop", "drop2", "drop3", "hook", "mail", "night", "redir"], names
assert sum(1 for c in ch if c["is_configured"]) == 2, ch
op4 = [r for r in op if r["channel"] in ("mail", "hook", "drop", "drop2")]
assert len(op4) == 4 * N2, (len(op4), N2)
outs = {r["outcome"] for r in lg}
assert {"none", "sent", "refused", "failed", "cleared"} <= outs, outs
fr = rows(f)
sent = [r for r in fr if r.get("alert_last_sent") and "mail" in (r.get("alert_channels") or [])]
assert len(sent) == N3 and N3 > 0, (len(sent), N3)
assert all("mail" in r["alert_channels"] for r in sent)
print("F: channels", len(ch), "open", len(op4), "log", len(lg), "findings sent", len(sent))
PY
ok "F: /api/alerts and the Findings column"
echo "PROOF OK: alerts"
