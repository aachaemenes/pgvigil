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
#     mail's open rows whose finding is in the view.
#  E. the loop inside `pgvigil run` (an instance: a sandbox database of the proof's own) with the channels dead and
#     drop3 (a file drop scoped to the proof's instance) only, for about 70 s: dead logs at least one more 'failed' row
#     with its error, the process still runs at the end, its log says "alerts: channel failed".
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
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
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
[[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["alerts"]), {a["event"] for a in d["alerts"]}=={"firing"})' "$WORK/http/1.json") == "$P1 True" ]] || fail "B: the hook's body"
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
"$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(q "select coalesce(sum(n_repeat), 0) from pgvigil.alert_log where snapshot_at >= '$TC'") == 0 ]] || fail "C: a repeat before the interval"
[[ $(q "select count(*) from pgvigil.alert_state where first_sent_at < '$TC' and send_count <> 1") == 0 ]] || fail "C: a row B opened was sent again"
q "update pgvigil.alert_state set last_sent_at = last_sent_at - interval '6 minutes' where channel = 'mail' and cleared_at is null" >/dev/null
stamp C; TC2=$(mark)
"$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
R2=$(q "select count(*) from pgvigil.alert_state where channel = 'mail' and cleared_at is null and send_count = 2")
(( R2 >= 1 )) || fail "C: no mail row repeated"
[[ $(logsum mail n_repeat "$TC2" sent) == "$R2" ]] || fail "C: mail's repeat rows $(logsum mail n_repeat "$TC2" sent), rows at 2 sends $R2"
[[ $(new_eml "$WORK/stamp.C" | grep -c '^\[REPEAT CRITICAL\]') == "$R2" ]] || fail "C: the repeat's lines"
[[ $(q "select coalesce(sum(n_repeat), 0) from pgvigil.alert_log where snapshot_at >= '$TC2' and channel <> 'mail'") == 0 ]] || fail "C: a channel with repeat 24h repeated"
ok "C: sent once in two runs; $R2 repeated to mail after the interval, no other channel"

# ---- H: the severity hold under the floor ---------------------------------------------------------------------------------
xid() { q "update pgvigil.databases set xid_age = $1 where instance_id = $PID and datname = '$PDB'" >/dev/null; }
xrow() { q "select count(*) filter (where cleared_at is null) || '|' || coalesce(max(send_count) filter (where cleared_at is null), 0) || '|' || count(*) from pgvigil.alert_state where channel = 'mail' and setting = 'database xid age' and instance_id = $PID"; }
xid 1500000000; TH=$(mark); "$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(xrow) == "1|1|1" ]] || fail "H: P's critical xid age not opened on mail: $(xrow)"
xid 500000000; TH2=$(mark); "$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(xrow) == "1|1|1" ]] || fail "H: under the floor the row moved: $(xrow)"
[[ $(q "select count(*) from pgvigil.alert_log where snapshot_at >= '$TH2' and '$(q "select finding_key from pgvigil.alert_state where channel = 'mail' and setting = 'database xid age' and instance_id = $PID")' = any (keys)") == 0 ]] || fail "H: a send for the held finding"
xid 1600000000; TH3=$(mark); "$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(xrow) == "1|1|1" ]] || fail "H: back over the floor it was sent again: $(xrow)"
ok "H: critical -> warning -> critical: one alert, held under the floor, no resolve, no resend"

# ---- D: the finding clears -------------------------------------------------------------------------------------------------
q "update pgvigil.instance_state set non_default_settings = (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(non_default_settings) x where x->>'name' <> 'autovacuum') where instance_id = $PID" >/dev/null
AKEY=$(q "select finding_key from pgvigil.alert_state where channel = 'mail' and setting = 'autovacuum' and instance_id = $PID and cleared_at is null")
[[ -n $AKEY ]] || fail "D: no open mail row of P's autovacuum"
stamp D0; "$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
new_eml "$WORK/stamp.D0" | grep -q "^\[RESOLVED\] $PNAME:" && fail "D: resolved with no collection of $PNAME since the finding went missing"
[[ $(q "select count(*) || '|' || count(missing_since) from pgvigil.alert_state where finding_key = '$AKEY' and cleared_at is null") == "6|6" ]] || fail "D: the held rows: $(q "select count(*) || '|' || count(missing_since) from pgvigil.alert_state where finding_key = '$AKEY' and cleared_at is null")"
q "select pgvigil.log_collection($PID, 'instance', clock_timestamp(), 1, 'ok', null)" >/dev/null
stamp D; "$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
new_eml "$WORK/stamp.D" | grep -q "^\[RESOLVED\] $PNAME: pg_gather autovacuum" || fail "D: no resolved line in the mail"
[[ $(hook_events "$WORK/stamp.D" "$AKEY" resolved) == 1 ]] || fail "D: the hook's resolved event"
[[ $(grep -l "\"finding_key\": \"$AKEY\"" "$WORK"/drop/*-resolved-* 2>/dev/null | wc -l) == 1 ]] || fail "D: drop's resolved file"
[[ $(ls "$WORK/drop2" | grep -c -- '-resolved-') == 0 ]] || fail "D: drop2 (recovery false) wrote a resolved file"
[[ $(q "select count(*) from pgvigil.alert_log where channel = 'drop2' and outcome = 'cleared' and '$AKEY' = any (keys)") == 1 ]] || fail "D: drop2's cleared row"
[[ $(q "select string_agg(channel || ':' || (cleared_at is not null) || ':' || (recovery_sent_at is not null) || ':' || (missing_since is not null), ' ' order by channel) from pgvigil.alert_state where finding_key = '$AKEY'") == "bulk:true:true:true drop:true:true:true drop2:true:false:true grace:false:false:true hook:true:true:true mail:true:true:true" ]] || fail "D: the rows of P's autovacuum: $(q "select string_agg(channel || ':' || (cleared_at is not null) || ':' || (recovery_sent_at is not null) || ':' || (missing_since is not null), ' ' order by channel) from pgvigil.alert_state where finding_key = '$AKEY'")"
q "update pgvigil.alert_state set missing_since = missing_since - interval '11 minutes' where channel = 'grace' and finding_key = '$AKEY'" >/dev/null
"$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
[[ $(grep -l "\"finding_key\": \"$AKEY\"" "$WORK"/grace/*-resolved-* 2>/dev/null | wc -l) == 1 ]] || fail "D: grace's resolved file after the clear delay"
[[ $(q "select (cleared_at is not null) || ':' || (recovery_sent_at is not null) from pgvigil.alert_state where channel = 'grace' and finding_key = '$AKEY'") == "true:true" ]] || fail "D: grace's row"
ok "D: P's autovacuum held while P went unread, then resolved to mail, hook and drop, cleared silently on drop2, held on grace until its clear delay"

# ---- K: an instance deactivated: cleared without a message ------------------------------------------------------------------
KN=$(q "select count(*) from pgvigil.alert_state where cleared_at is null and instance_name = '$DEACT'")
(( KN >= 5 )) || fail "K: $DEACT has $KN open rows"
q "update pgvigil.instances set is_active = false where name = '$DEACT'" >/dev/null
stamp K; "$BIN" alerts -config "$WORK/alerts.yaml" >/dev/null 2>&1 || true
new_eml "$WORK/stamp.K" | grep -q "^\[RESOLVED\] $DEACT:" && fail "K: a recovery mail for the deactivated $DEACT"
[[ $(hook_instance "$WORK/stamp.K" "$DEACT") == 0 ]] || fail "K: a hook post for $DEACT"
[[ $(find "$WORK/drop" "$WORK/grace" -newer "$WORK/stamp.K" -name '*-resolved-*' -print0 | xargs -0 -r grep -l "\"instance\": \"$DEACT\"" | wc -l) == 0 ]] || fail "K: a resolved file for $DEACT"
[[ $(q "select count(*) || '|' || count(recovery_sent_at) from pgvigil.alert_state where instance_name = '$DEACT' and cleared_at > now() - interval '1 minute'") == "$KN|0" ]] || fail "K: $DEACT's rows: $(q "select count(*) || '|' || count(recovery_sent_at) from pgvigil.alert_state where instance_name = '$DEACT' and cleared_at > now() - interval '1 minute'")"
ok "K: $DEACT deactivated: its $KN alert rows cleared without a message"

# ---- F: the API ------------------------------------------------------------------------------------------------------------
UI_PORT=$(freeport)
"$BIN" serve -config "$WORK/none.yaml" -no-login -listen "127.0.0.1:$UI_PORT" > "$WORK/serve.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 100); do curl -fs "http://127.0.0.1:$UI_PORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$UI_PORT/api/alerts" > "$WORK/alerts.json" || fail "F: /api/alerts"
curl -fs "http://127.0.0.1:$UI_PORT/api/findings" > "$WORK/findings.json" || fail "F: /api/findings"
N3=$(q "select count(*) from pgvigil.alert_state s where s.channel = 'mail' and s.cleared_at is null and exists (select 1 from pgvigil.alert_findings f where f.finding_key = s.finding_key)")
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
echo "PROOF OK: alerts"
