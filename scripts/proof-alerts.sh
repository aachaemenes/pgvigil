#!/usr/bin/env bash
# Proof of alerts out (migration 0059, internal/alerts, task 60) on the sandbox: the demo fleet's findings sent to a
# loopback SMTP sink and a loopback HTTP listener this script runs itself, and to file drops in its own directory.
# Nothing leaves the machine: every destination is 127.0.0.1 or a local directory. The sender connects as a login IN
# ROLE pgvigil_alerter (alerts_dsn), never as the owner.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database and logins
#                      (random suffix) and drops them at the end.
#   PGVIGIL_BIN        a build with the alerts command and the /api/alerts route (the lead's wiring; default bin/pgvigil).
#   python3            the SMTP sink and the HTTP listener.
#
# Every sender pass after B prints its exit code, summary line and stderr into the record (pass <tag>: ...). Expected of
# each: exit 1, the summary line, stderr only dead's and redir's 'alert channel failed' warnings and the 'N alert(s) not
# sent' error; any other exit, no summary line, or a failure of another channel fails the proof. K grades its rows
# against the pass's own mark.
#
# The demo's findings move while the proof runs (some are defined over the last minutes), so every count below is
# graded against what the pass itself recorded (its alert_log rows, the alert rows it opened), never against a later
# read of the findings view. [First form, before the review fold: D graded against the view and failed twice in four
# runs; root cause: a finding entered or left the view between the pass and the read.] Two findings are the proof's
# own and do not move: 'autovacuum is off' (critical) on instance P, made by a non-default setting in its
# instance_state, and P's 'database xid age', whose severity the proof sets through pgvigil.databases.
#
# Expected (written before the run; P1 = mail's alerts opened by B's pass):
#  R. the role contract: the collector login (IN ROLE pgvigil_collector) is refused alert_due and alert_record
#     (permission denied for the function); a reader login (IN ROLE pgvigil_reader) is refused alert_record (permission
#     denied for the table alert_log) and the partition door ("is not the alert sender"); the alerter login reads
#     alert_due.
#  A. [join fold] a configuration without alerts and without alerts_dsn whose repository login is the collector's:
#     `pgvigil alerts` exits 0 with "no channel configured: nothing sent" and writes nothing (alert_log 0 rows).
#     The same with alerts_dsn (the alerter): "no channel configured: nothing sent"; alert_log holds one row, outcome
#     'none', channel NULL; alert_channels and alert_state 0 rows (no sync); nothing received.
#  B. channels at min_severity critical: mail (SMTP, tls none, loopback), hook (webhook json), drop and drop2 (file;
#     drop2 recovery false), grace (file, the default clear_after 10m); redir (a webhook the listener answers with a
#     307), dead (a webhook to a closed port), night (a file drop in its quiet hours); mail, hook, drop and drop2 with
#     clear_after 0. One run, exit 1 (two channels did not send): mail's sent row carries P1 firing, P1 >= 2 and within
#     2 of the view's critical count read before; the message holds P1 "[FIRING CRITICAL]" lines among them P's
#     autovacuum; hook 1 POST of P1, drop, drop2 and grace P1 files each, night 0; the five channels P1 open rows each;
#     redir 1 refused ("redirect: not followed"), dead 1 failed ("connection refused"), no token in any error or
#     destination; alert_channels 9 configured. [join fold] bulk (a webhook at min_severity warning on a listener path
#     of its own): its sent rows carry PB firing, PB > 25, in ceil(PB/25) posts of at most 25 alerts, the posts'
#     alerts PB in all.
#  C. a second run at once: no repeat row in any channel, every row B opened still at send_count 1. mail's open rows
#     moved 6 minutes back (repeat 5m): the third run's mail rows carry n_repeat = mail's rows at send_count 2 (>= 1),
#     the message as many "[REPEAT CRITICAL]" lines; hook, drop, drop2 and grace no repeat.
#  H. the severity hold: P's xid age set to 1.5 billion (critical), a run: mail opens it (one more firing). Set to
#     500 million (warning, under mail's floor), a run: no resolved, its row open, no repeat. Back to 1.6 billion, a
#     run: no new firing, no escalated (the row is open at critical), its send_count unchanged.
#  D. P's autovacuum setting back on (the finding gone), a run [join fold]: no collection of P since, so nothing is
#     resolved: no "[RESOLVED] P" line, its six rows open with missing_since set. A collection of P logged ok, a run:
#     mail's message holds "[RESOLVED] P: pg_gather autovacuum", hook's post an event 'resolved' for it, drop a
#     *-resolved-* file of it, bulk resolved; drop2 no resolved file, its row cleared without recovery (outcome
#     'cleared'); grace: its row open with missing_since set. grace's
#     missing_since moved 11 minutes back, a run: a resolved file of it in grace, the row cleared with recovery_sent_at.
#  K. the instance with the most critical findings deactivated (not P), a run: no "[RESOLVED] <it>" line in any new
#     message, no resolved event of it in a new post or file; its rows on the five channels cleared with
#     recovery_sent_at NULL.
#  F. the API (`pgvigil serve -no-login` on loopback): /api/alerts answers 9 channels (all configured), mail, hook,
#     drop and drop2 with the same open count, grace at least as many [first fold run: grace 5, the others 4: a demo
#     finding left the view within grace's 10-minute clear delay; the four at clear_after 0 resolved it, grace holds it], a log of the last hour with the 'none', 'sent', 'refused',
#     'failed' and 'cleared' outcomes; /api/findings: the rows carrying alert_last_sent with mail in alert_channels are
#     mail's open rows whose finding is in the view, the alert rules' own findings left out (the Alert rules page shows
#     them; the demo's rules raise some since task 131).
#  E. the loop inside `pgvigil run` (an instance: a sandbox database of the proof's own) with the channels dead and
#     drop3 (a file drop scoped to the proof's instance) only, for about 70 s: dead logs at least one more 'failed' row
#     with its error, the process still runs at the end, its log says "alerts: channel failed".
#  W. task 151 (K07, migration 0093), a configuration of its own with alerts_base_url https://pgvigil.example.org and
#     five channels at min_severity critical, clear_after 0: og (opsgenie, the listener's /og), dc (webhook discord),
#     gc (webhook googlechat, the token in its query), capped (file, max_per_hour 3), tplmail (smtp with a subject and a
#     line template). P's autovacuum (critical) set again first. PW = og's firing in W1's pass (PW >= 4).
#     W1 one pass, exit 0, the summary names 'held by max_per_hour': og PW create requests, each 'GenieKey <key>',
#     alias pgvigil:<instance>:<finding key>, priority P1, details.url https://pgvigil.example.org/#/alert?k=<key>&t=;
#     dc and gc PW alert lines in all, each post within 2000 (dc) / 4096 (gc) characters, more than one post when the
#     lines need it, dc's allowed_mentions.parse empty, every line ending in its page's address; capped 3 files, its
#     log a 'sent' row of 3 and a 'capped' row of PW - 3; tplmail's messages 'Subject: PGV <n> new on tplmail' with the
#     n summing to PW and PW 'TPL critical' lines; alert_channels records og as opsgenie, capped's cap 3, tplmail's
#     templates 'subject firing, line firing, subject resolved' and the link base; no key or token in any error or
#     destination.
#  W2 a pass: capped still 3 files and a second 'capped' row of PW - 3 (nothing of the hour left); its sent rows moved
#     61 minutes back, a pass: capped min(PW, 6) files.
#  W3 pgvigil.finding_fix: work_mem 64MB on a setting finding -> "ALTER SYSTEM SET work_mem = '64MB'; SELECT
#     pg_reload_conf();"; a detail with "VACUUM (ANALYZE) public.t;" -> that statement; a detail with a 635-character
#     REINDEX -> 635 characters; a suggested value of two words, a SQL Server finding, a setting name with a ';' -> NULL;
#     over every demo finding without an error.
#     The API (`pgvigil serve` with the UI login on loopback): /api/alerts?k=<P's autovacuum> answers the card (the
#     finding standing, its fix "ALTER SYSTEM SET autovacuum = 'on'; SELECT pg_reload_conf();", threshold 'on'), two
#     firings (B's resolved, W's open) and the sends that carried it; POST /api/alerts/dismiss: no session 401, no
#     header 403, no reason 409, a reason 200, again 409 'already dismissed'; part=dismissed lists it, part=history
#     marks it dismissed; its end 200, the history unmarked; ack_log 'dismiss' rows. Mute rules: one through POST
#     /api/ack on check autovacuum starting in an hour reads 'upcoming' in part=mutes and holds nothing now
#     (pgvigil.ack_hold NULL) but at +2 h; POST /api/alerts/mute edit (starts now) answers its successor, the old row
#     ended, the new one 'replaces' it and holds now; pause: holds nothing, reads 'paused', a second pause 409; resume:
#     holds again; ack_log edit, pause and resume rows; the rule then removed.
#  W4 Send test: POST /api/alerts/test og 200, again 409 'still waits', an unconfigured channel 409; a pass: og a
#     create and a close of alias pgvigil:pgvigil:test-<id>, the request answered 'sent', alert_log outcome 'test' for
#     og; dc's test: a '[TEST] pgvigil:' line.
#  W5 P's autovacuum gone and P read, a pass: og a close of P's alias, dc and gc a '[RESOLVED] P' line, tplmail a
#     'Subject: PGV resolved P'. W6 a second instance with open og alerts deactivated, a pass: og closes each of its
#     aliases (as many as its open og rows), dc, gc and tplmail say nothing of it.
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_alertsproof_$SUF; MDB=pgvigil_alertsmon_$SUF
ALR=pgvigil_alertsproof_alr_$SUF; COL=pgvigil_alertsproof_col_$SUF; RDR=pgvigil_alertsproof_rdr_$SUF; PW=p$RANDOM$RANDOM
WORK=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$WORK"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" -c "drop database if exists $MDB with (force)" \
    -c "drop role if exists $ALR" -c "drop role if exists $COL" -c "drop role if exists $RDR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" -c "create database $MDB" >/dev/null
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
mkdir -p "$WORK/smtp" "$WORK/http" "$WORK/drop" "$WORK/drop2" "$WORK/grace" "$WORK/night" "$WORK/drop3"

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
    def do_PUT(self): self.do_POST()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        for pre, code in (("/og", 202), ("/discord", 204), ("/gchat", 200)):
            if self.path.startswith(pre):
                import json as _j
                d = os.path.join(out, pre[1:]); os.makedirs(d, exist_ok=True)
                p = os.path.join(d, "%06d.json" % next(n))
                rec = {"method": self.command, "path": self.path, "auth": self.headers.get("Authorization", ""), "body": _j.loads(body or b"{}")}
                open(p + ".tmp", "w").write(_j.dumps(rec)); os.rename(p + ".tmp", p)
                self.send_response(code); self.end_headers()
                if code != 204: self.wfile.write(b'{"result":"ok"}')
                return
        if self.path.startswith("/redirect"):
            self.send_response(307); self.send_header("Location", "/elsewhere"); self.end_headers(); return
        if self.path.startswith("/elsewhere"):
            open(os.path.join(out, "elsewhere"), "a").write("hit\n")
        elif self.path.startswith("/bulk"):
            os.makedirs(os.path.join(out, "bulk"), exist_ok=True)
            p = os.path.join(out, "bulk", "%d.json" % next(n))
            open(p + ".tmp", "wb").write(body); os.rename(p + ".tmp", p)
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
export PGV_PROOF_BULK="http://127.0.0.1:$HTTP_PORT/bulk/secret-token"
export PGV_PROOF_DEAD="http://127.0.0.1:$DEAD_PORT/hook/secret-token"
export PGV_PROOF_ALERTS_DSN="$ADMIN_DSN dbname=$REPO_DB user=$ALR password=$PW"
smtp_count() { find "$WORK/smtp" -name '*.eml' | wc -l; }
http_count() { find "$WORK/http" -maxdepth 1 -name '*.json' | wc -l; }
mark() { q "select clock_timestamp()"; }                                  # a run's start, for its log rows
logsum() { q "select coalesce(sum($2), 0) from pgvigil.alert_log where channel = '$1' and snapshot_at >= '$3' ${4:+and outcome = '$4'}"; }
new_eml() { find "$WORK/smtp" -name '*.eml' -newer "$1" -print0 | xargs -0 -r cat; }   # messages after a stamp file
# the hook's posts newer than a stamp: the events of one finding key, or the alerts of one instance
hook_events() { python3 - "$WORK/http" "$1" "$2" "$3" <<'PY'
import json, os, sys, glob
d, st, key, ev = sys.argv[1:5]; t = os.path.getmtime(st)
print(sum(1 for p in glob.glob(d + "/*.json") if os.path.getmtime(p) > t
          for a in json.load(open(p))["alerts"] if a["finding_key"] == key and a["event"] == ev))
PY
}
hook_instance() { python3 - "$WORK/http" "$1" "$2" <<'PY'
import json, os, sys, glob
d, st, inst = sys.argv[1:4]; t = os.path.getmtime(st)
print(sum(1 for p in glob.glob(d + "/*.json") if os.path.getmtime(p) > t
          for a in json.load(open(p))["alerts"] if a["instance"] == inst))
PY
}
stamp() { sleep 0.01; touch "$WORK/stamp.$1"; sleep 0.01; }
# one pass of the sender with its exit code, summary line and stderr kept in the record (never >/dev/null: run 1 at the
# wave F re-merge failed K and could not say why). Every pass is owed exit 1 with a summary line: dead and redir are due
# a send and fail by design on every pass (a failed send opens no row, so they are due again). Exit 0 would mean no
# critical finding was due at all; any other exit, or no summary line, is a crash: both fail the proof with the stderr
# text. A failure of any channel other than dead or redir (the sink or the listener died) fails it too.
pass() {
  local tag=$1 rc
  set +e; "$BIN" alerts -config "$WORK/alerts.yaml" >"$WORK/pass.$tag.out" 2>"$WORK/pass.$tag.err"; rc=$?; set -e
  echo "pass $tag: exit $rc: $(grep -m1 '^alerts: ' "$WORK/pass.$tag.out" || echo '(no summary line)')"
  if [[ -s "$WORK/pass.$tag.err" ]]; then sed "s/^/pass $tag stderr: /" "$WORK/pass.$tag.err"; fi
  if ! { (( rc == 1 )) && grep -q '^alerts: ' "$WORK/pass.$tag.out"; }; then
    fail "pass $tag: exit $rc, want 1 with a summary line: $(tr '\n' ' ' < "$WORK/pass.$tag.err" | cut -c1-600)"
  fi
  if grep 'msg="alert channel failed"' "$WORK/pass.$tag.err" | grep -vq -e 'err="dead: ' -e 'err="redir: '; then
    fail "pass $tag: a channel other than dead or redir failed: $(grep 'msg="alert channel failed"' "$WORK/pass.$tag.err" | grep -v -e 'err="dead: ' -e 'err="redir: ' | tr '\n' ' ' | cut -c1-600)"
  fi
}

# ---- the repository, the demo, the logins ------------------------------------------------------------------------
cat > "$WORK/none.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
EOF
"$BIN" migrate -config "$WORK/none.yaml" > "$WORK/seed.log" 2>&1 || fail "migrate: $(tail -3 "$WORK/seed.log")"
"$BIN" demo -config "$WORK/none.yaml" -days 1 > "$WORK/seed.log" 2>&1 || fail "the demo seed: $(tail -3 "$WORK/seed.log")"
# the demo's own alert record (the demo-spool channel over the history) is cleared: the proof counts its own rows
q "delete from pgvigil.alert_state; delete from pgvigil.alert_log; delete from pgvigil.alert_channels" >/dev/null
psql "$ADMIN_DSN" -XAtq -c "create role $ALR login password '$PW' in role pgvigil_alerter" \
  -c "create role $COL login password '$PW' in role pgvigil_collector" -c "create role $RDR login password '$PW' in role pgvigil_reader" >/dev/null

# P: an active demo instance with a database row; its own two findings
read -r PID PNAME PDB <<<"$(q "select i.instance_id, i.name, d.datname from pgvigil.instances i join pgvigil.databases d using (instance_id)
  where i.is_active and d.is_present and not coalesce(d.is_template, false) order by i.name, d.datname limit 1" | tr '|' ' ')"
q "update pgvigil.instance_state set non_default_settings = coalesce(non_default_settings, '[]'::jsonb) || '[{\"name\": \"autovacuum\", \"value\": \"off\"}]' where instance_id = $PID" >/dev/null
[[ $(q "select count(*) from pgvigil.alert_findings where instance_id = $PID and setting = 'autovacuum' and severity = 'critical'") == 1 ]] || fail "P's autovacuum finding is not in the view"
echo "P = $PNAME ($PDB)"

# ---- R: the role contract ------------------------------------------------------------------------------------------
CH='[{"name": "x", "min_severity": "info", "repeat_secs": 0, "clear_after_secs": 0, "recovery": true}]'
REC='{"channel": "x", "outcome": "cleared", "items": []}'
as() { psql "$ADMIN_DSN dbname=$REPO_DB user=$1 password=$PW" -XAt -v ON_ERROR_STOP=1 -c "$2" 2>&1 || true; }
[[ $(as "$COL" "select count(*) from pgvigil.alert_due(now(), '$CH')") == *"permission denied for function alert_due"* ]] || fail "R: the collector read alert_due"
[[ $(as "$COL" "select pgvigil.alert_record(now(), '$REC')") == *"permission denied for function alert_record"* ]] || fail "R: the collector called alert_record"
[[ $(as "$RDR" "select pgvigil.alert_record(now(), '$REC')") == *"permission denied for table alert_log"* ]] || fail "R: a reader wrote alert_log: $(as "$RDR" "select pgvigil.alert_record(now(), '$REC')")"
[[ $(as "$RDR" "select pgvigil.alert_log_partition(now())") == *"is not the alert sender"* ]] || fail "R: a reader used the partition door"
[[ $(as "$ALR" "select count(*) > 0 from pgvigil.alert_due(now(), '$CH')") == t ]] || fail "R: the alerter cannot read alert_due"
ok "R: collector refused, reader cannot write, alerter reads"

# ---- A: no channel ---------------------------------------------------------------------------------------------------
export PGV_PROOF_COL_DSN="$ADMIN_DSN dbname=$REPO_DB user=$COL password=$PW"
printf 'repository:\n  dsn: env:PGV_PROOF_COL_DSN\n' > "$WORK/collector.yaml"
set +e; out=$("$BIN" alerts -config "$WORK/collector.yaml" 2>"$WORK/a0.err"); rc=$?; set -e
(( rc == 0 )) && [[ $out == *"no channel configured: nothing sent"* ]] || fail "A: as the collector, exit $rc: $out $(cat "$WORK/a0.err")"
[[ $(q "select count(*) from pgvigil.alert_log") == 0 ]] || fail "A: the collector's run wrote alert_log"
ok "A: no channel as the collector's login: exit 0, nothing written"
out=$("$BIN" alerts -config "$WORK/none.yaml")
[[ $out == *"no channel configured: nothing sent"* ]] || fail "A: the command said: $out"
[[ $(q "select count(*), count(*) filter (where outcome = 'none' and channel is null) from pgvigil.alert_log") == "1|1" ]] || fail "A: alert_log"
[[ $(q "select (select count(*) from pgvigil.alert_state) + (select count(*) from pgvigil.alert_channels)") == 0 ]] || fail "A: a channel or an alert row was written"
[[ $(smtp_count) == 0 && $(http_count) == 0 ]] || fail "A: something was sent"
ok "A: no channel, nothing sent, no sync, the log's 'none' row"

NV=$(q "select count(distinct finding_key) from pgvigil.alert_findings where severity = 'critical'")
DEACT=$(q "select instance from pgvigil.alert_findings where severity = 'critical' and instance_id <> $PID group by instance order by count(distinct finding_key) desc, instance limit 1")

# ---- B: the channels ---------------------------------------------------------------------------------------------------
H0=$(date -u +%H); H2=$(( (10#$H0 + 2) % 24 ))
cat > "$WORK/alerts.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: mail, kind: smtp, min_severity: critical, repeat: 5m, clear_after: 0,
     smtp: {host: 127.0.0.1, port: $SMTP_PORT, tls: none, from: pgvigil@example.org, to: [dba@example.org]}}
  - {name: hook, kind: webhook, min_severity: critical, clear_after: 0, webhook: {url: env:PGV_PROOF_HOOK, format: json}}
  - {name: drop, kind: file, min_severity: critical, clear_after: 0, file: {dir: $WORK/drop}}
  - {name: drop2, kind: file, min_severity: critical, clear_after: 0, recovery: false, file: {dir: $WORK/drop2}}
  - {name: grace, kind: file, min_severity: critical, file: {dir: $WORK/grace}}
  - {name: redir, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_REDIR, format: slack}}
  - {name: dead, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_DEAD, format: teams}}
  - {name: bulk, kind: webhook, min_severity: warning, clear_after: 0, webhook: {url: env:PGV_PROOF_BULK, format: json}}
  - {name: night, kind: file, min_severity: critical, quiet_hours: "$(printf %02d $((10#$H0))):00-$(printf %02d $H2):00", file: {dir: $WORK/night}}
EOF
TB=$(mark)
set +e; out=$("$BIN" alerts -config "$WORK/alerts.yaml" 2>"$WORK/b.err"); rc=$?; set -e
echo "B: $out (exit $rc)"
(( rc == 1 )) || fail "B: exit $rc, want 1; $(cat "$WORK/b.err")"
[[ $out == *"quiet hours: night"* ]] || fail "B: night is not named under quiet hours"
P1=$(logsum mail n_firing "$TB" sent)
(( P1 >= 2 && P1 >= NV - 2 && P1 <= NV + 2 )) || fail "B: mail opened $P1, the view held $NV critical keys"
[[ $(smtp_count) == 1 && $(grep -c '^\[FIRING CRITICAL\]' "$WORK/smtp/1.eml") == "$P1" ]] || fail "B: the mail's firing lines"
grep -q "^\[FIRING CRITICAL\] $PNAME: pg_gather autovacuum = off" "$WORK/smtp/1.eml" || fail "B: P's autovacuum is not in the mail"
[[ $(http_count) == 1 ]] || fail "B: the listener holds $(http_count) post(s)"
[[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["alerts"]), {a["event"] for a in d["alerts"]}=={"firing"})' "$(find "$WORK/http" -maxdepth 1 -name '*.json')") == "$P1 True" ]] || fail "B: the hook's body"
[[ ! -e "$WORK/http/elsewhere" ]] || fail "B: the redirect was followed"
for d in drop drop2 grace; do [[ $(ls "$WORK/$d" | wc -l) == "$P1" ]] || fail "B: $d holds $(ls "$WORK/$d" | wc -l) files"; done
[[ $(ls "$WORK/night" | wc -l) == 0 ]] || fail "B: night wrote in its quiet hours"
python3 -c 'import json,sys,glob; [json.load(open(p)) for p in glob.glob(sys.argv[1]+"/*.json")]' "$WORK/drop" || fail "B: a dropped file is not JSON"
[[ $(q "select string_agg(distinct n::text, ',') from (select count(*) n from pgvigil.alert_state where cleared_at is null and channel <> 'bulk' group by channel) x") == "$P1" ]] || fail "B: the channels' open rows differ"
[[ $(q "select count(distinct channel) from pgvigil.alert_state") == 6 ]] || fail "B: open rows on other than the six channels"
PB=$(logsum bulk n_firing "$TB" sent)
(( PB > 25 )) || fail "B: bulk opened $PB, not over 25"
BULK=$(python3 -c 'import json,sys,glob; n=[len(json.load(open(p))["alerts"]) for p in glob.glob(sys.argv[1]+"/*.json")]; print(len(n), max(n or [0]), sum(n))' "$WORK/http/bulk")
[[ $BULK == "$(( (PB + 24) / 25 )) 25 $PB" ]] || fail "B: bulk's posts for $PB alerts: $BULK"
[[ $(q "select outcome || ':' || count(*) from pgvigil.alert_log where channel in ('redir', 'dead') group by outcome order by 1" | tr '\n' ' ') == "failed:1 refused:1 " ]] || fail "B: redir and dead"
[[ $(q "select error from pgvigil.alert_log where channel = 'redir'") == *"redirect: not followed"* ]] || fail "B: redir's error"
[[ $(q "select error from pgvigil.alert_log where channel = 'dead'") == *"connection refused"* ]] || fail "B: dead's error"
[[ $(q "select count(*) from pgvigil.alert_log where error like '%secret-token%'") == 0 ]] || fail "B: an error shows a webhook token"
[[ $(q "select count(*) from pgvigil.alert_channels where destination like '%secret-token%'") == 0 ]] || fail "B: a destination shows a webhook token"
[[ $(q "select count(*) from pgvigil.alert_channels where is_configured") == 9 ]] || fail "B: alert_channels"
ok "B: $P1 critical alerts to mail (1 message), hook (1 post), drop, drop2 and grace; night held, redir refused, dead failed; bulk $PB alerts in posts of at most 25"

# ---- C: repeat -----------------------------------------------------------------------------------------------------------
TC=$(mark)
pass C1
[[ $(q "select coalesce(sum(n_repeat), 0) from pgvigil.alert_log where snapshot_at >= '$TC'") == 0 ]] || fail "C: a repeat before the interval"
[[ $(q "select count(*) from pgvigil.alert_state where first_sent_at < '$TC' and send_count <> 1") == 0 ]] || fail "C: a row B opened was sent again"
q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '6 minutes' where channel = 'mail' and cleared_at is null" >/dev/null
stamp C; TC2=$(mark)
pass C2
R2=$(q "select count(*) from pgvigil.alert_state where channel = 'mail' and cleared_at is null and send_count = 2")
(( R2 >= 1 )) || fail "C: no mail row repeated"
[[ $(logsum mail n_repeat "$TC2" sent) == "$R2" ]] || fail "C: mail's repeat rows $(logsum mail n_repeat "$TC2" sent), rows at 2 sends $R2"
[[ $(new_eml "$WORK/stamp.C" | grep -c '^\[REPEAT CRITICAL\]') == "$R2" ]] || fail "C: the repeat's lines"
[[ $(q "select coalesce(sum(n_repeat), 0) from pgvigil.alert_log where snapshot_at >= '$TC2' and channel <> 'mail'") == 0 ]] || fail "C: a channel with repeat 24h repeated"
ok "C: sent once in two runs; $R2 repeated to mail after the interval, no other channel"

# ---- H: the severity hold under the floor ---------------------------------------------------------------------------------
xid() { q "update pgvigil.databases set xid_age = $1 where instance_id = $PID and datname = '$PDB'" >/dev/null; }
xrow() { q "select count(*) filter (where cleared_at is null) || '|' || coalesce(max(send_count) filter (where cleared_at is null), 0) || '|' || count(*) from pgvigil.alert_state where channel = 'mail' and setting = 'database xid age' and instance_id = $PID"; }
xid 1500000000; TH=$(mark); pass H1
[[ $(xrow) == "1|1|1" ]] || fail "H: P's critical xid age not opened on mail: $(xrow)"
xid 500000000; TH2=$(mark); pass H2
[[ $(xrow) == "1|1|1" ]] || fail "H: under the floor the row moved: $(xrow)"
[[ $(q "select count(*) from pgvigil.alert_log where snapshot_at >= '$TH2' and '$(q "select finding_key from pgvigil.alert_state where channel = 'mail' and setting = 'database xid age' and instance_id = $PID")' = any (keys)") == 0 ]] || fail "H: a send for the held finding"
xid 1600000000; TH3=$(mark); pass H3
[[ $(xrow) == "1|1|1" ]] || fail "H: back over the floor it was sent again: $(xrow)"
ok "H: critical -> warning -> critical: one alert, held under the floor, no resolve, no resend"

# ---- D: the finding clears -------------------------------------------------------------------------------------------------
q "update pgvigil.instance_state set non_default_settings = (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(non_default_settings) x where x->>'name' <> 'autovacuum') where instance_id = $PID" >/dev/null
AKEY=$(q "select finding_key from pgvigil.alert_state where channel = 'mail' and setting = 'autovacuum' and instance_id = $PID and cleared_at is null")
[[ -n $AKEY ]] || fail "D: no open mail row of P's autovacuum"
stamp D0; pass D0
new_eml "$WORK/stamp.D0" | grep -q "^\[RESOLVED\] $PNAME:" && fail "D: resolved with no collection of $PNAME since the finding went missing"
[[ $(q "select count(*) || '|' || count(missing_since) from pgvigil.alert_state where finding_key = '$AKEY' and cleared_at is null") == "6|6" ]] || fail "D: the held rows: $(q "select count(*) || '|' || count(missing_since) from pgvigil.alert_state where finding_key = '$AKEY' and cleared_at is null")"
q "select pgvigil.log_collection($PID, 'instance', clock_timestamp(), 1, 'ok', null)" >/dev/null
stamp D; pass D1
new_eml "$WORK/stamp.D" | grep -q "^\[RESOLVED\] $PNAME: pg_gather autovacuum" || fail "D: no resolved line in the mail"
[[ $(hook_events "$WORK/stamp.D" "$AKEY" resolved) == 1 ]] || fail "D: the hook's resolved event"
[[ $(grep -l "\"finding_key\": \"$AKEY\"" "$WORK"/drop/*-resolved-* 2>/dev/null | wc -l) == 1 ]] || fail "D: drop's resolved file"
[[ $(ls "$WORK/drop2" | grep -c -- '-resolved-') == 0 ]] || fail "D: drop2 (recovery false) wrote a resolved file"
[[ $(q "select count(*) from pgvigil.alert_log where channel = 'drop2' and outcome = 'cleared' and '$AKEY' = any (keys)") == 1 ]] || fail "D: drop2's cleared row"
[[ $(q "select string_agg(channel || ':' || (cleared_at is not null) || ':' || (recovery_sent_at is not null) || ':' || (missing_since is not null), ' ' order by channel) from pgvigil.alert_state where finding_key = '$AKEY'") == "bulk:true:true:true drop:true:true:true drop2:true:false:true grace:false:false:true hook:true:true:true mail:true:true:true" ]] || fail "D: the rows of P's autovacuum: $(q "select string_agg(channel || ':' || (cleared_at is not null) || ':' || (recovery_sent_at is not null) || ':' || (missing_since is not null), ' ' order by channel) from pgvigil.alert_state where finding_key = '$AKEY'")"
q "update pgvigil.alert_state set missing_since = missing_since - interval '11 minutes' where channel = 'grace' and finding_key = '$AKEY'" >/dev/null
pass D2
[[ $(grep -l "\"finding_key\": \"$AKEY\"" "$WORK"/grace/*-resolved-* 2>/dev/null | wc -l) == 1 ]] || fail "D: grace's resolved file after the clear delay"
[[ $(q "select (cleared_at is not null) || ':' || (recovery_sent_at is not null) from pgvigil.alert_state where channel = 'grace' and finding_key = '$AKEY'") == "true:true" ]] || fail "D: grace's row"
ok "D: P's autovacuum held while P went unread, then resolved to mail, hook and drop, cleared silently on drop2, held on grace until its clear delay"

# ---- K: an instance deactivated: cleared without a message ------------------------------------------------------------------
KN=$(q "select count(*) from pgvigil.alert_state where cleared_at is null and instance_name = '$DEACT'")
(( KN >= 5 )) || fail "K: $DEACT has $KN open rows"
q "update pgvigil.instances set is_active = false where name = '$DEACT'" >/dev/null
stamp K; TK=$(mark); pass K
new_eml "$WORK/stamp.K" | grep -q "^\[RESOLVED\] $DEACT:" && fail "K: a recovery mail for the deactivated $DEACT"
[[ $(hook_instance "$WORK/stamp.K" "$DEACT") == 0 ]] || fail "K: a hook post for $DEACT"
[[ $(find "$WORK/drop" "$WORK/grace" -newer "$WORK/stamp.K" -name '*-resolved-*' -print0 | xargs -0 -r grep -l "\"instance\": \"$DEACT\"" | wc -l) == 0 ]] || fail "K: a resolved file for $DEACT"
# cleared by THIS pass (cleared_at at or after its mark), never 'within the last minute'; on a failure the rows' state
krows() { q "select count(*) filter (where cleared_at >= '$TK') || '|' || count(recovery_sent_at) filter (where cleared_at >= '$TK') from pgvigil.alert_state where instance_name = '$DEACT'"; }
kstate() { q "select 'open ' || count(*) filter (where cleared_at is null) || ', of them with missing_since ' || count(missing_since) filter (where cleared_at is null) || ', cleared before the mark ' || count(*) filter (where cleared_at < '$TK') || ', rows in alert_findings ' || (select count(*) from pgvigil.alert_findings f where f.instance = '$DEACT') || ', is_active ' || coalesce((select is_active::text from pgvigil.instances where name = '$DEACT'), 'no instance row') from pgvigil.alert_state where instance_name = '$DEACT'"; }
[[ $(krows) == "$KN|0" ]] || fail "K: $DEACT's rows cleared by the pass|with recovery: $(krows), want $KN|0; $(kstate)"
ok "K: $DEACT deactivated: its $KN alert rows cleared without a message"

# ---- F: the API ------------------------------------------------------------------------------------------------------------
UI_PORT=$(freeport)
"$BIN" serve -config "$WORK/none.yaml" -no-login -listen "127.0.0.1:$UI_PORT" > "$WORK/serve.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 100); do curl -fs "http://127.0.0.1:$UI_PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$UI_PORT/api/alerts" > "$WORK/alerts.json" || fail "F: /api/alerts: $(curl -s "http://127.0.0.1:$UI_PORT/api/alerts" | head -c 800)"
curl -fs "http://127.0.0.1:$UI_PORT/api/findings" > "$WORK/findings.json" || fail "F: /api/findings: $(curl -s "http://127.0.0.1:$UI_PORT/api/findings" | head -c 800)"
# /api/findings lists pgvigil.findings; alert_findings also holds the alert rules' own findings (0085: source 'alert rule',
# shown on the Alert rules page, not in the Findings grid), which the demo's rules raise: they are not counted here
N3=$(q "select count(*) from pgvigil.alert_state s where s.channel = 'mail' and s.cleared_at is null and exists (select 1 from pgvigil.alert_findings f where f.finding_key = s.finding_key and f.source <> 'alert rule')")
python3 - "$WORK/alerts.json" "$WORK/findings.json" "$N3" <<'PY' || fail "F: the API's rows"
import json, sys
a = json.load(open(sys.argv[1])); f = json.load(open(sys.argv[2])); N3 = int(sys.argv[3])
def rows(t):
    return [dict(zip(t["columns"], r)) for r in t["rows"]] if t and "columns" in t else (t or [])
ch, op, lg = rows(a["channels"]), rows(a["open"]), rows(a["log"])
names = sorted(c["name"] for c in ch)
assert names == ["bulk", "dead", "drop", "drop2", "grace", "hook", "mail", "night", "redir"], names
assert all(c["is_configured"] for c in ch), ch
counts = {c: sum(1 for r in op if r["channel"] == c) for c in ("mail", "hook", "drop", "drop2", "grace")}
# grace (clear_after 10m) may hold a finding that left the view in the last 10 minutes, which the four at 0 resolved
assert len({counts[c] for c in ("mail", "hook", "drop", "drop2")}) == 1 and counts["mail"] > 0 and counts["grace"] >= counts["mail"], counts
outs = {r["outcome"] for r in lg}
assert {"none", "sent", "refused", "failed", "cleared"} <= outs, outs
sent = [r for r in rows(f) if r.get("alert_last_sent") and "mail" in (r.get("alert_channels") or [])]
assert len(sent) == N3 and N3 > 0, (len(sent), N3)
print("F: channels", len(ch), "open per channel", counts["mail"], "log", len(lg), "findings sent to mail", len(sent))
PY
ok "F: /api/alerts and the Findings column"

# ---- E: the loop inside pgvigil run ------------------------------------------------------------------------------------------
cat > "$WORK/run.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
instances:
  - name: proof-alerts-$SUF
    dsn: "$ADMIN_DSN dbname=$MDB"
alerts:
  - {name: drop3, kind: file, min_severity: info, instances: [proof-alerts-$SUF], file: {dir: $WORK/drop3}}
  - {name: dead, kind: webhook, min_severity: critical, webhook: {url: env:PGV_PROOF_DEAD, format: teams}}
EOF
before=$(q "select count(*) from pgvigil.alert_log where channel = 'dead' and outcome = 'failed'")
"$BIN" run -config "$WORK/run.yaml" > "$WORK/run.log" 2>&1 & RUN=$!; PIDS+=($RUN)
sleep 70
kill -0 $RUN 2>/dev/null || { tail -20 "$WORK/run.log"; fail "E: pgvigil run stopped"; }
after=$(q "select count(*) from pgvigil.alert_log where channel = 'dead' and outcome = 'failed' and error like '%connection refused%'")
(( after > before )) || fail "E: dead's failed rows $before -> $after"
grep -q 'alerts: channel failed' "$WORK/run.log" || fail "E: the run's log does not say a channel failed"
kill $RUN; wait $RUN 2>/dev/null || true
ok "E: the loop logs dead's error ($before -> $after failed rows) and goes on"
# ---- W: task 151 - Opsgenie, Discord, Google Chat, the cap, templates, the page, triage, mute rules, Send test ------
OGKEY=0123abcd-4567-89ef-0123-$(printf '%012d' "$SUF")
export PGV_PROOF_OG=$OGKEY
export PGV_PROOF_DC="http://127.0.0.1:$HTTP_PORT/discord/api/webhooks/1/secret-token"
export PGV_PROOF_GC="http://127.0.0.1:$HTTP_PORT/gchat/v1/spaces/x/messages?key=secret-token&token=secret-token"
BASE=https://pgvigil.example.org
mkdir -p "$WORK/capped"
cat > "$WORK/w.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts_base_url: $BASE/
alerts:
  - {name: og, kind: opsgenie, min_severity: critical, clear_after: 0, opsgenie: {api_key: env:PGV_PROOF_OG, url: "http://127.0.0.1:$HTTP_PORT/og"}}
  - {name: dc, kind: webhook, min_severity: critical, clear_after: 0, webhook: {url: env:PGV_PROOF_DC, format: discord}}
  - {name: gc, kind: webhook, min_severity: critical, clear_after: 0, webhook: {url: env:PGV_PROOF_GC, format: googlechat}}
  - {name: capped, kind: file, min_severity: critical, clear_after: 0, max_per_hour: 3, file: {dir: $WORK/capped}}
  - name: tplmail
    kind: smtp
    min_severity: critical
    clear_after: 0
    smtp: {host: 127.0.0.1, port: $SMTP_PORT, tls: none, from: pgvigil@example.org, to: [dba@example.org]}
    templates:
      subject: {firing: "PGV {count} new on {channel}", resolved: "PGV resolved {instance}"}
      line: {firing: "TPL {severity} {instance} {setting} = {value}"}
EOF
# one pass of the W configuration: every channel answers, so exit 0 with a summary line
wpass() {
  local tag=$1 rc
  set +e; "$BIN" alerts -config "$WORK/w.yaml" >"$WORK/wpass.$tag.out" 2>"$WORK/wpass.$tag.err"; rc=$?; set -e
  echo "pass $tag: exit $rc: $(grep -m1 '^alerts: ' "$WORK/wpass.$tag.out" || echo '(no summary line)')"
  if [[ -s "$WORK/wpass.$tag.err" ]]; then sed "s/^/pass $tag stderr: /" "$WORK/wpass.$tag.err"; fi
  { (( rc == 0 )) && grep -q '^alerts: ' "$WORK/wpass.$tag.out"; } || fail "pass $tag: exit $rc, want 0 with a summary line: $(tr '\n' ' ' < "$WORK/wpass.$tag.err" | cut -c1-600)"
}
# the listener's records of one route newer than a stamp, as JSON lines
recs() { python3 - "$WORK/http/$1" "$2" <<'PY'
import json, os, sys, glob
d, st = sys.argv[1:3]; t = os.path.getmtime(st)
for p in sorted(glob.glob(d + "/*.json")):
    if os.path.getmtime(p) > t: print(open(p).read())
PY
}
q "update pgvigil.instance_state set non_default_settings = coalesce(non_default_settings, '[]'::jsonb) || '[{\"name\": \"autovacuum\", \"value\": \"off\"}]' where instance_id = $PID" >/dev/null

# W1: the first pass
stamp W1; TW=$(mark)
wpass W1
grep -q 'held by max_per_hour' "$WORK/wpass.W1.out" || fail "W1: the summary does not name the cap"
PW=$(logsum og n_firing "$TW" sent)
(( PW >= 4 )) || fail "W1: og opened $PW alerts, want 4 or more"
python3 - "$WORK/http" "$WORK/stamp.W1" "$PW" "$OGKEY" "$BASE" <<'PY' || fail "W1: the listener's requests"
import json, os, sys, glob
d, st, PW, key, base = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
t = os.path.getmtime(st)
def recs(sub): return [json.load(open(p)) for p in sorted(glob.glob(f"{d}/{sub}/*.json")) if os.path.getmtime(p) > t]
og = recs("og")
assert len(og) == PW and all(r["method"] == "POST" and r["path"] == "/og/v2/alerts" for r in og), [(r["method"], r["path"]) for r in og]
assert all(r["auth"] == "GenieKey " + key for r in og), "auth"
for r in og:
    b = r["body"]
    assert b["priority"] == "P1" and b["alias"].startswith("pgvigil:" + b["entity"] + ":"), b
    k = b["alias"].rsplit(":", 1)[1]
    assert b["details"]["url"].startswith(f"{base}/#/alert?k={k}&t="), b["details"]
for sub, field, limit in (("discord", "content", 2000), ("gchat", "text", 4096)):
    ps = recs(sub)
    lines = [l for p in ps for l in p["body"][field].split("\n")[1:]]
    assert len(lines) == PW, (sub, len(lines), PW, len(ps))
    assert all(len(p["body"][field]) <= limit for p in ps), (sub, [len(p["body"][field]) for p in ps])
    assert all(f"{base}/#/alert?k=" in l for l in lines), (sub, [l for l in lines if base not in l][:2])
    if sub == "discord": assert all(p["body"]["allowed_mentions"] == {"parse": []} for p in ps), "allowed_mentions"
    print(f"W1: {sub} {len(ps)} post(s), {len(lines)} lines, longest {max(len(p['body'][field]) for p in ps)} characters")
print(f"W1: og {len(og)} creates")
PY
python3 - "$WORK/smtp" "$WORK/stamp.W1" "$PW" "$BASE" <<'PY' || fail "W1: tplmail's messages"
import os, sys, glob, re
d, st, PW, base = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]; t = os.path.getmtime(st)
ms = [open(p, errors="replace").read() for p in glob.glob(d + "/*.eml") if os.path.getmtime(p) > t]
subj = [int(m.group(1)) for x in ms for m in [re.search(r"^Subject: PGV (\d+) new on tplmail\r?$", x, re.M)] if m]
assert len(ms) > 0 and len(subj) == len(ms) and sum(subj) == PW, (subj, len(ms), PW)
tpl = [l for x in ms for l in x.splitlines() if l.startswith("TPL critical ")]
assert len(tpl) == PW and all(l.endswith(tuple("0123456789")) and f" {base}/#/alert?k=" in l for l in tpl), (len(tpl), PW, tpl[:2])
print(f"W1: tplmail {len(ms)} message(s), {len(tpl)} TPL lines")
PY
[[ $(ls "$WORK/capped" | wc -l) == 3 ]] || fail "W1: capped holds $(ls "$WORK/capped" | wc -l) files"
[[ $(logsum capped n_firing "$TW" sent) == 3 && $(logsum capped n_firing "$TW" capped) == $((PW - 3)) ]] || fail "W1: capped's log: sent $(logsum capped n_firing "$TW" sent), capped $(logsum capped n_firing "$TW" capped), PW $PW"
[[ $(q "select kind || '|' || (select max_per_hour from pgvigil.alert_channels where name = 'capped') || '|' || (select templates from pgvigil.alert_channels where name = 'tplmail') from pgvigil.alert_channels where name = 'og'") == "opsgenie|3|subject firing, line firing, subject resolved" ]] || fail "W1: alert_channels: $(q "select name, kind, max_per_hour, templates, link_base from pgvigil.alert_channels where is_configured")"
[[ $(q "select count(*) from pgvigil.alert_channels where is_configured and link_base = '$BASE'") == 5 ]] || fail "W1: the link base is not recorded on the five channels"
[[ $(q "select count(*) from pgvigil.alert_log where error like '%secret-token%' or error like '%$OGKEY%' or destination like '%secret-token%' or destination like '%$OGKEY%'") == 0 ]] || fail "W1: a key or a token in the log"
[[ $(q "select count(*) from pgvigil.alert_channels where destination like '%secret-token%' or destination like '%$OGKEY%'") == 0 ]] || fail "W1: a key or a token in a destination"
ok "W1: $PW critical alerts to og (one create each, alias and page address), dc and gc (within their text limits), tplmail (its templates); capped sent 3 and held $((PW - 3))"

# W2: the cap holds through the hour, and lets 3 more go when the hour has passed
TW2=$(mark); wpass W2
[[ $(ls "$WORK/capped" | wc -l) == 3 && $(logsum capped n_firing "$TW2" capped) == $((PW - 3)) && $(logsum capped n_firing "$TW2" sent) == 0 ]] || fail "W2: capped: $(ls "$WORK/capped" | wc -l) files, capped $(logsum capped n_firing "$TW2" capped), sent $(logsum capped n_firing "$TW2" sent)"
q "update pgvigil.alert_log set snapshot_at = snapshot_at - interval '61 minutes' where channel = 'capped' and outcome = 'sent'" >/dev/null
wpass W2b
WANT=$(( PW < 6 ? PW : 6 ))
[[ $(ls "$WORK/capped" | wc -l) == "$WANT" ]] || fail "W2: capped holds $(ls "$WORK/capped" | wc -l) files after the hour, want $WANT"
ok "W2: the cap held every alert while the hour was used, then sent $((WANT - 3)) more"

# W3: the API - the page, dismiss, mute rules (serve with the UI login; the audit login is the repository's dsn)
# a fixed length: \$RANDOM alone can make one shorter than the login's minimum [s151-proof2: 'user add' refused it]
UIUSER=proofui; UIPW="ui$(printf '%05d%05d%05d' $RANDOM $RANDOM $RANDOM)"
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$WORK/none.yaml" $UIUSER >"$WORK/useradd.log" 2>&1 || fail "W3: user add: $(tail -3 "$WORK/useradd.log")"
UI2=$(freeport); U="http://127.0.0.1:$UI2"
"$BIN" serve -config "$WORK/none.yaml" -listen "127.0.0.1:$UI2" > "$WORK/serve2.log" 2>&1 & PIDS+=($!)
for n in $(seq 1 100); do curl -sf -o /dev/null "$U/" && break; [[ $n == 100 ]] && fail "W3: serve did not answer: $(tail -3 "$WORK/serve2.log")"; sleep 0.2; done
JAR=$WORK/jar
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
wpost() { code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$U/api/$1"; }
idof() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/body" "$1"; }
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
[[ -n $(awk '$6 == "pgvigil_session" {print $7}' "$JAR") ]] || fail "W3: no session cookie"
[[ $(q "select finding_key from pgvigil.alert_findings where instance_id = $PID and setting = 'autovacuum'") == "$AKEY" ]] || fail "W3: P's autovacuum is under another key"
# finding_fix's two branches and its refusals [s151-proof1: a {1,400} bound in its pattern (PostgreSQL allows 255) failed
# every /api/alerts read at the first finding taking the detail branch]
LONGD="rebuild it: REINDEX INDEX CONCURRENTLY public.$(printf 'x%.0s' $(seq 1 600)); then ANALYZE"
[[ $(q "select pgvigil.finding_fix('postgres', 'work_mem', true, '64MB', null) || '|' || coalesce(pgvigil.finding_fix('postgres', 'x', false, null, 'run VACUUM (ANALYZE) public.t; then look again'), 'null') || '|' || length(pgvigil.finding_fix('postgres', 'x', null, null, '$LONGD')) || '|' || coalesce(pgvigil.finding_fix('postgres', 'work_mem', true, 'at least 64MB', 'nothing to run'), 'null') || '|' || coalesce(pgvigil.finding_fix('sqlserver', 'max degree', true, '4', null), 'null') || '|' || coalesce(pgvigil.finding_fix('postgres', 'a; drop', true, 'on', null), 'null')") == "ALTER SYSTEM SET work_mem = '64MB'; SELECT pg_reload_conf();|VACUUM (ANALYZE) public.t;|635|null|null|null" ]] || fail "W3: finding_fix: $(q "select pgvigil.finding_fix('postgres', 'work_mem', true, '64MB', null), pgvigil.finding_fix('postgres', 'x', false, null, 'run VACUUM (ANALYZE) public.t; then look again'), length(pgvigil.finding_fix('postgres', 'x', null, null, '$LONGD'))" 2>&1)"
NFIX=$(q "select count(*) from pgvigil.findings y join pgvigil.instances i using (instance_id) where pgvigil.finding_fix(i.engine, y.setting, y.is_set, y.suggested, y.detail) is not null" 2>&1) || fail "W3: finding_fix over the demo's findings: $NFIX"
echo "W3: finding_fix gives a statement for $NFIX of the demo's findings"
curl -s -b "$JAR" "$U/api/alerts?k=$AKEY" -o "$WORK/card.json"
python3 - "$WORK/card.json" <<'PY' || fail "W3: the alert's page: $(head -c 800 "$WORK/card.json")"
import json, sys
d = json.load(open(sys.argv[1]))
rows = lambda t: [dict(zip(t["columns"], r)) for r in t["rows"]] if t and "columns" in t else []
c, o, s = rows(d["card"]), rows(d["occurrences"]), rows(d["sends"])
assert len(c) == 1 and c[0]["fix"] == "ALTER SYSTEM SET autovacuum = 'on'; SELECT pg_reload_conf();" and c[0]["threshold"] == "on", c
assert [x["status"] for x in o] == ["open", "resolved"], [(x["status"], x["channels"]) for x in o]
assert "og" in o[0]["channels"] and "mail" in o[1]["channels"], [x["channels"] for x in o]
assert any(x["channel"] == "og" and x["outcome"] == "sent" for x in s) and any(x["channel"] == "mail" and x["outcome"] == "sent" for x in s), len(s)
print(f"W3: card value {c[0]['value']!r}, firings {len(o)}, sends {len(s)}")
PY
DIS="{\"op\":\"add\",\"finding_key\":\"$AKEY\",\"reason\":\"tolerable for this server\"}"
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$DIS" "$U/api/alerts/dismiss") == 401 ]] || fail "W3: dismiss without a session: $(cat "$WORK/body")"
[[ $(code -b "$JAR" -H 'Content-Type: application/json' -d "$DIS" "$U/api/alerts/dismiss") == 403 ]] || fail "W3: dismiss without the header: $(cat "$WORK/body")"
{ [[ $(wpost alerts/dismiss "{\"op\":\"add\",\"finding_key\":\"$AKEY\",\"reason\":\" \"}") == 409 ]] && grep -q 'needs a reason' "$WORK/body"; } || fail "W3: a dismissal without a reason: $(cat "$WORK/body")"
[[ $(wpost alerts/dismiss "$DIS") == 200 ]] || fail "W3: dismiss: $(cat "$WORK/body")"
DID=$(idof dismiss_id)
{ [[ $(wpost alerts/dismiss "$DIS") == 409 ]] && grep -q 'already dismissed' "$WORK/body"; } || fail "W3: a second dismissal: $(cat "$WORK/body")"
HF=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ); HT=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)
hist() { curl -s -b "$JAR" "$U/api/alerts?part=$1&from=$HF&to=$HT" -o "$WORK/h.json"; python3 - "$WORK/h.json" "$1" "$AKEY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); t = d[sys.argv[2]]
rows = [dict(zip(t["columns"], r)) for r in t["rows"]]
if sys.argv[2] == "history": print(",".join(sorted(str(r["dismissed"]).lower() for r in rows if r["finding_key"] == sys.argv[3])))
else: print(sum(1 for r in rows if r["finding_key"] == sys.argv[3] and r["live"]))
PY
}
[[ $(hist dismissed) == 1 && $(hist history) == "true,true" ]] || fail "W3: dismissed $(hist dismissed), history $(hist history)"
[[ $(wpost alerts/dismiss "{\"op\":\"end\",\"dismiss_id\":$DID}") == 200 ]] || fail "W3: the dismissal's end: $(cat "$WORK/body")"
[[ $(hist dismissed) == 0 && $(hist history) == "false,false" ]] || fail "W3: after the end: dismissed $(hist dismissed), history $(hist history)"
[[ $(q "select string_agg(op || ':' || outcome, ',' order by log_id) from pgvigil.ack_log where kind = 'dismiss'") == "add:refused,add:done,add:refused,end:done" ]] || fail "W3: the dismissals' log: $(q "select string_agg(op || ':' || outcome, ',' order by log_id) from pgvigil.ack_log where kind = 'dismiss'")"
ok "W3: the alert's page (card, fix, threshold, two firings, sends); dismiss 401 / 403 / no reason / done / again, listed, in the history, ended, logged"

TM=$(mark)
hold() { q "select coalesce(pgvigil.ack_hold($1, '$PNAME', coalesce((select tags from pgvigil.instance_tags_merged where instance_id = $PID), '{}'), '$AKEY', 'pg_gather', 'autovacuum', 'off')::text, 'none')"; }
mstate() { curl -s -b "$JAR" "$U/api/alerts?part=mutes" -o "$WORK/m.json"; python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["mutes"]; r=[dict(zip(t["columns"],x)) for x in t["rows"]]; print(next((x["state"] for x in r if str(x["ack_id"])==sys.argv[2]), "absent"))' "$WORK/m.json" "$1"; }
[[ $(wpost ack "{\"kind\":\"mute\",\"check_key\":\"autovacuum\",\"starts_at\":\"$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)\"}") == 200 ]] || fail "W3: the upcoming mute rule: $(cat "$WORK/body")"
M1=$(idof ack_id)
[[ $(mstate "$M1") == upcoming && $(hold "now()") == none && $(hold "now() + interval '2 hours'") == "$M1" ]] || fail "W3: the upcoming rule: $(mstate "$M1"), holds now $(hold "now()"), at +2 h $(hold "now() + interval '2 hours'")"
[[ $(wpost alerts/mute "{\"op\":\"edit\",\"ack_id\":$M1,\"check_key\":\"autovacuum\",\"match_text\":\"off\"}") == 200 ]] || fail "W3: the edit: $(cat "$WORK/body")"
M2=$(idof ack_id)
[[ $M2 != "$M1" && $(q "select (select ended_at is not null from pgvigil.acks where ack_id = $M1) || '|' || (select replaces from pgvigil.acks where ack_id = $M2)") == "true|$M1" && $(hold "now()") == "$M2" ]] || fail "W3: after the edit: M1 $M1 M2 $M2, $(q "select ack_id, ended_at, replaces, starts_at from pgvigil.acks where ack_id in ($M1, $M2)"), holds $(hold "now()")"
[[ $(wpost alerts/mute "{\"op\":\"pause\",\"ack_id\":$M2}") == 200 && $(hold "now()") == none && $(mstate "$M2") == paused ]] || fail "W3: the pause: $(cat "$WORK/body"), holds $(hold "now()"), $(mstate "$M2")"
{ [[ $(wpost alerts/mute "{\"op\":\"pause\",\"ack_id\":$M2}") == 409 ]] && grep -q 'already paused' "$WORK/body"; } || fail "W3: a second pause: $(cat "$WORK/body")"
[[ $(wpost alerts/mute "{\"op\":\"resume\",\"ack_id\":$M2}") == 200 && $(hold "now()") == "$M2" && $(mstate "$M2") == "in force" ]] || fail "W3: the resume: $(cat "$WORK/body"), holds $(hold "now()"), $(mstate "$M2")"
[[ $(q "select string_agg(op || ':' || outcome, ',' order by log_id) from pgvigil.ack_log where kind = 'mute' and at >= '$TM'") == "add:done,add:done,end:done,edit:done,pause:done,pause:refused,resume:done" ]] || fail "W3: the mute rules' log: $(q "select string_agg(op || ':' || outcome, ',' order by log_id) from pgvigil.ack_log where kind = 'mute' and at >= '$TM'")"
[[ $(wpost ack/end "{\"ack_id\":$M2}") == 200 ]] || fail "W3: the rule's removal: $(cat "$WORK/body")"
ok "W3: a mute rule set ahead holds nothing until its start; edited (its successor holds at once), paused (holds nothing), resumed; every step logged"

# W4: Send test
[[ $(wpost alerts/test '{"channel":"og"}') == 200 ]] || fail "W4: the og test: $(cat "$WORK/body")"
TID=$(idof test_id)
{ [[ $(wpost alerts/test '{"channel":"og"}') == 409 ]] && grep -q 'still waits' "$WORK/body"; } || fail "W4: a second og test: $(cat "$WORK/body")"
{ [[ $(wpost alerts/test '{"channel":"mail"}') == 409 ]] && grep -q 'is not configured' "$WORK/body"; } || fail "W4: a test of an unconfigured channel: $(cat "$WORK/body")"
[[ $(wpost alerts/test '{"channel":"dc"}') == 200 ]] || fail "W4: the dc test: $(cat "$WORK/body")"
stamp W4; TW4=$(mark); wpass W4
grep -q '2 test message(s), 0 failed' "$WORK/wpass.W4.out" || fail "W4: the summary does not count the two tests"
python3 - "$WORK/http" "$WORK/stamp.W4" "$TID" <<'PY' || fail "W4: the tests' requests"
import json, os, sys, glob, urllib.parse
d, st, tid = sys.argv[1:4]; t = os.path.getmtime(st)
def recs(sub): return [json.load(open(p)) for p in sorted(glob.glob(f"{d}/{sub}/*.json")) if os.path.getmtime(p) > t]
alias = f"pgvigil:pgvigil:test-{tid}"
og = [r for r in recs("og") if alias in urllib.parse.unquote(r["path"]) or r["body"].get("alias") == alias]
assert [(r["method"], urllib.parse.unquote(r["path"].split("?")[0])) for r in og] == [("POST", "/og/v2/alerts"), ("POST", f"/og/v2/alerts/{alias}/close")], og
dc = [l for r in recs("discord") for l in r["body"]["content"].split("\n") if l.startswith("[TEST] pgvigil: a test message on channel dc")]
assert len(dc) == 1, dc
print("W4: og create + close of", alias, "; dc", dc[0][:80])
PY
[[ $(q "select outcome from pgvigil.alert_tests where test_id = $TID") == sent && $(q "select count(*) from pgvigil.alert_log where channel = 'og' and outcome = 'test' and snapshot_at >= '$TW4'") == 1 ]] || fail "W4: the record: $(q "select test_id, channel, outcome, error from pgvigil.alert_tests")"
ok "W4: Send test asked through the door (a second one and an unconfigured channel refused), sent by the next pass (og: the test and its close), answered and logged"

# W5: P's autovacuum clears
q "update pgvigil.instance_state set non_default_settings = (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(non_default_settings) x where x->>'name' <> 'autovacuum') where instance_id = $PID" >/dev/null
q "select pgvigil.log_collection($PID, 'instance', clock_timestamp(), 1, 'ok', null)" >/dev/null
stamp W5; wpass W5
python3 - "$WORK/http" "$WORK/smtp" "$WORK/stamp.W5" "$PNAME" "$AKEY" <<'PY' || fail "W5: the recoveries"
import json, os, sys, glob, urllib.parse
d, sd, st, pn, key = sys.argv[1:6]; t = os.path.getmtime(st)
def recs(sub): return [json.load(open(p)) for p in sorted(glob.glob(f"{d}/{sub}/*.json")) if os.path.getmtime(p) > t]
closes = [r for r in recs("og") if urllib.parse.unquote(r["path"].split("?")[0]) == f"/og/v2/alerts/pgvigil:{pn}:{key}/close" and r["path"].endswith("?identifierType=alias")]
assert len(closes) == 1, [r["path"] for r in recs("og")]
for sub, field in (("discord", "content"), ("gchat", "text")):
    n = sum(1 for r in recs(sub) for l in r["body"][field].split("\n") if l.startswith(f"[RESOLVED] {pn}: pg_gather autovacuum"))
    assert n == 1, (sub, n)
ms = [open(p, errors="replace").read() for p in glob.glob(sd + "/*.eml") if os.path.getmtime(p) > t]
hit = [m for m in ms if f"\n[RESOLVED] {pn}: pg_gather autovacuum" in m.replace("\r", "")]
assert len(hit) == 1 and any(l.startswith("Subject: PGV ") for l in hit[0].splitlines()), [m[:300] for m in ms]
print("W5: og closed", key[:8], "; dc, gc and tplmail resolved; tplmail's subject:", [l for l in hit[0].splitlines() if l.startswith("Subject:")][0])
PY
ok "W5: P's autovacuum resolved: og closed its alias, dc, gc and tplmail sent the recovery"

# W6: an instance deactivated: og closes its alerts (nothing was fixed), the others say nothing
DEACT2=$(q "select instance_name from pgvigil.alert_state where channel = 'og' and cleared_at is null and instance_id <> $PID group by instance_name order by count(*) desc, instance_name limit 1")
KN2=$(q "select count(*) from pgvigil.alert_state where channel = 'og' and cleared_at is null and instance_name = '$DEACT2'")
[[ -n $DEACT2 ]] && (( KN2 >= 1 )) || fail "W6: no other instance with open og alerts"
q "update pgvigil.instances set is_active = false where name = '$DEACT2'" >/dev/null
stamp W6; wpass W6
python3 - "$WORK/http" "$WORK/smtp" "$WORK/stamp.W6" "$DEACT2" "$KN2" <<'PY' || fail "W6: the cleared alerts"
import json, os, sys, glob, urllib.parse
d, sd, st, inst, kn = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]); t = os.path.getmtime(st)
def recs(sub): return [json.load(open(p)) for p in sorted(glob.glob(f"{d}/{sub}/*.json")) if os.path.getmtime(p) > t]
closes = [r for r in recs("og") if urllib.parse.unquote(r["path"]).startswith(f"/og/v2/alerts/pgvigil:{inst}:") and "/close" in r["path"]]
assert len(closes) == kn and all("cleared without a fix" in r["body"]["note"] for r in closes), (len(closes), kn)
for sub, field in (("discord", "content"), ("gchat", "text")):
    assert not any(f"] {inst}:" in l or l.startswith(f"TPL critical {inst} ") for r in recs(sub) for l in r["body"][field].split("\n")), sub
ms = [open(p, errors="replace").read() for p in glob.glob(sd + "/*.eml") if os.path.getmtime(p) > t]
assert not any(f"] {inst}:" in m for m in ms), "tplmail"
print("W6:", inst, "closed on og:", len(closes))
PY
ok "W6: $DEACT2 deactivated: og closed its $KN2 alerts, dc, gc and tplmail sent nothing"

echo "PROOF OK: alerts"
