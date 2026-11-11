#!/usr/bin/env bash
# Proof of task 131 (migration 0085, internal/alerts, internal/web/q_metrics.go and q_alert_rules.go): the Metrics grid
# over the series the repository already holds, and alert rules on any of its metrics, judged by the alert sender and
# sent through a file drop in the proof's own folder. Nothing leaves the machine.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a PostgreSQL 14+ cluster as a superuser. The proof makes a repository
#                      database, a target database and three logins, all named pgvigil_s3rules_*_<random>, and drops
#                      them at the end. The target instance is that same cluster, read through the target database.
#   PGVIGIL_BIN        a pgvigil binary to use; default: the proof builds one into its temp folder (go build) and uses
#                      it throughout. Its serve must wire GET /api/metrics, /api/metrics/series, /api/alertrules and
#                      POST /api/alertrules, /api/alertrules/end (the lead's wiring in web.go; part B fails without).
#   PGVIGIL_SKIP_PG13  1 = skip part V (no docker here); the proof then prints NOT PROVEN ON POSTGRESQL 13 and its last
#                      line says so. Default: part V starts a postgres:13 container on a loopback port with a
#                      throwaway password, migrates a fresh database there, runs its checks and removes the container.
#   Needs: psql, curl, python3, ss; go (without PGVIGIL_BIN); docker (part V).
#
# Expected (written before the first run):
#  R. the role contract. A login IN ROLE pgvigil_collector (the actions door's audit login) may EXECUTE
#     import_alert_rule and is refused INSERT on alert_rules and UPDATE on alert_rule_log (permission denied); through
#     the function it adds a rule and ends it (2 log rows by 'proof-r'). A login IN ROLE pgvigil_alerter runs
#     alert_rules_run (an integer back), may INSERT into alert_rule_state, may not INSERT into alert_rules and is
#     refused import_alert_rule (permission denied for function). A login IN ROLE pgvigil_reader reads
#     metric_catalog (62 rows) and is refused by alert_rules_run (permission denied for table alert_rule_state).
#     [Run 1 graded: the reader was refused, on the table alert_rule_fired: the statement that stores the state ends
#     in the insert into alert_rule_fired, and that is the table the refusal names. Expected from run 2: permission
#     denied for one of the sender's two tables, alert_rule_state or alert_rule_fired.]
#  B. the write door. POST /api/alertrules without a session 401; with a session and no X-Pgvigil header 403; with
#     both, a malformed request 400 for each of: scope 'all', a warning that is a string, critical inside warning,
#     for_minutes 5000, op 'end' on the add route. None of the seven leaves a row in alert_rules or alert_rule_log.
#     A well-formed request the store refuses (metric sessions.nope) answers 409 with 'no metric', leaves one refused
#     log row and no rule. GET /api/alertrules says writable true and the user. A second serve with -no-login: GET
#     says writable false with a reason naming -no-login, POST (with the header) 403, nothing written.
#  G. the grid equals hand queries. After three activity and three dbstats reads of the target a few seconds apart,
#     GET /api/metrics over a fixed window: sessions.active's max, min, avg, current and sample count equal a hand
#     query on activity_summary (3 samples); database.commits_s's five figures equal a hand rate computed from the raw
#     dbstats rows with lag() (2 samples, max > 0), summed over the databases and, with db=<the target database>, for
#     that database alone. GET /api/metrics/series for sessions.active: step_secs 1, as many points as samples, the
#     last point = current. 400 for metric sessions.nope, for a SQL Server metric on this instance, and for db= on a
#     metric without a per-database series.
#  S. a SQL Server instance's grid (seeded, not collected: the grid is a repository read; the collectors that fill
#     these tables have their own proofs). mssql_requests_summary seeded with blocked = 3, 1, 7, 2, 0 (oldest to
#     newest): requests.blocked reads max 7, min 0, avg 2.6, current 0, 5 samples. With an instance rule 'above 5
#     (warning), 6 (critical)': max_status critical, min_status, avg_status and current_status ok, the row's rule_scope
#     'instance'. The grid lists no PostgreSQL family for it, and the PostgreSQL instance's grid no SQL Server family.
#  F. fires once, clears once, on a real metric. N0 = the target's idle-in-transaction count at the last read. A rule
#     on instance A: sessions.idle_in_txn above N0+1 (warning) for 1 minute. Three sessions are then held idle in
#     transaction; an activity read and a sender pass every few seconds. While the run of samples beyond the value
#     spans under 60 s the rule's state is 'pending' and the drop holds no firing file of it; the first pass that
#     reads 'warning' has a span of 60 s or more and the drop then holds exactly ONE firing file of 'Sessions: idle in
#     transaction'; two more reads and passes add none. The sessions released: a read and a pass (state 'ok', no
#     resolved file yet: 0059 holds a recovery until the instance is read after the alert went missing), a read and a
#     pass: exactly ONE resolved file; another read and pass add none. alert_rule_fired says fired 1.
#  T. a tag's rule wins over the fleet's, both ways. A (tag env:proofa) and B (env:proofb) are the same server under
#     two names. Fleet: sessions.total above 100000; tag env:proofb: above 0. After a read and a pass: B's state
#     'warning' under the tag rule, A's 'ok' under the fleet rule; the grids say rule_scope tag / fleet and
#     current_status warning / ok. Fleet: sessions.connections_pct above 0; tag env:proofa: above 1000: A 'ok' under
#     its tag rule, B 'warning' under the fleet rule. The fleet rules cover 2 instances and are in force on 1 each.
#     A's drop gains no file of either metric.
#  D. a database rule. On A, database.commits_s above -1 for the target database: after two dbstats reads and a pass,
#     a state row for that database 'warning' and none for the instance's summed series; the grid with db=<target>
#     shows the rule (rule_database = the target, current_status warning), the grid without db shows no rule on the
#     row; the drop holds one firing file of 'Database: commits [<target>]'.
#  E. edit, switch, end. An edit of D's rule to above 1e12 answers 200 with a new rule id; the old row is ended by the
#     proof user and the new one replaces it; after a pass the state is 'ok'. Disable 200 (after a pass no state row,
#     in force 0); disable again 409 'already off'; enable 200; end 200; end again 409 'was ended'.
#  A. the audit. alert_rule_log holds, by the proof user and from 127.0.0.1, exactly the done and refused attempts
#     the proof made through the API (counted from the HTTP answers), plus R's two by 'proof-r'; every alert_rules
#     row was created by one of the two.
#  V. PostgreSQL 13. Every migration applies to a fresh database on a postgres:13 container. Seeded there (30
#     activity samples a minute apart, idle in transaction 5 for the newest 10, else 2): metric_grid reads
#     5 | 2 | 3 | 5 | 30; every family's metric_points runs (240 rows in all: the sessions family's); a fleet rule
#     above 3 / 4 for 5 minutes added through import_alert_rule; alert_rules_run returns 1; the state is critical at 5
#     against 4; alert_findings holds 'Sessions: idle in transaction', critical.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
SUF=$RANDOM
REPO=pgvigil_s3rules_$SUF; TGT=pgvigil_s3rules_tgt_$SUF
COL=pgvigil_s3rules_col_$SUF; ALR=pgvigil_s3rules_alr_$SUF; RDR=pgvigil_s3rules_rdr_$SUF
PW=p$RANDOM$RANDOM$RANDOM; UIUSER=proofuser; UIPW=ui$RANDOM$RANDOM$RANDOM
INSTA=proof-rules-a-$SUF; INSTB=proof-rules-b-$SUF; INSTMS=proof-rules-ms-$SUF
HOLDAPP=pv_s3rules_hold_$SUF
WORK=$(mktemp -d); SRV=""; SRV2=""; HOLD=""; HOLDFDS=(); PG13=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
release() {   # ends the held sessions: their input closes (psql leaves, the open transaction rolls back), then the pids
  local fd
  for fd in "${HOLDFDS[@]}"; do exec {fd}>&- || true; done
  HOLDFDS=()
  # shellcheck disable=SC2086
  [[ -n "$HOLD" ]] && kill $HOLD 2>/dev/null || true
  HOLD=""
}
cleanup() {
  release
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$SRV2" ]] && kill "$SRV2" 2>/dev/null || true
  wait 2>/dev/null || true
  [[ -n "$PG13" ]] && docker rm -f "$PG13" >/dev/null 2>&1 || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $REPO with (force)" \
    -c "drop database if exists $TGT with (force)" -c "drop role if exists $COL" -c "drop role if exists $ALR" \
    -c "drop role if exists $RDR" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap '' PIPE   # a held session that died is a failed write the script reports, not a silent end of the script
for t in psql curl python3 ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
freeport() {   # free on 127.0.0.1 and [::1] both
  local p
  for _ in $(seq 1 50); do
    p=$((20000 + RANDOM % 20000))
    ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }
  done
  fail "no free port"
}

# ---- the one binary ----------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_BIN:-}" ]]; then
  BIN=$(realpath "$PGVIGIL_BIN")
else
  command -v go >/dev/null || fail "go is not on this machine (or give PGVIGIL_BIN)"
  BIN=$WORK/pgvigil
  go build -o "$BIN" ./cmd/pgvigil || fail "go build"
fi
[[ -x "$BIN" ]] || fail "no binary at $BIN"

# ---- the repository, the target, the configuration -----------------------------------------------------------------------
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $REPO" -c "create database $TGT" >/dev/null
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
export TGT_DSN="$PGVIGIL_ADMIN_DSN dbname=$TGT"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
tq() { psql "$TGT_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
mkdir "$WORK/drop"
cat > "$WORK/cfg.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
alerts_dsn: env:PGV_PROOF_ALERTS_DSN
alerts:
  - {name: drop, kind: file, min_severity: warning, clear_after: 0, instances: [$INSTA], file: {dir: $WORK/drop}}
instances:
  - name: $INSTA
    dsn: env:TGT_DSN
    tags: [env:proofa]
  - name: $INSTB
    dsn: env:TGT_DSN
    tags: [env:proofb]
EOF
CFG=$WORK/cfg.yaml
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || fail "migrate"
[[ $(q "select count(*) from pgvigil.schema_version where version = '0085_alert_rules.sql'") == 1 ]] || fail "0085 not applied"
(( $(q "select current_setting('server_version_num')::int / 10000") >= 14 )) || fail "PGVIGIL_ADMIN_DSN is not PostgreSQL 14 or newer"
ok "migrate applied 0085 on PostgreSQL $(q "select current_setting('server_version')")"

HOST=$(q "select coalesce(host(inet_server_addr()), 'localhost')"); DBPORT=$(q "select current_setting('port')")
dsn() { echo "host=$HOST port=$DBPORT user=$1 password=$PW dbname=$REPO sslmode=disable"; }
psql "$PGVIGIL_REPO_DSN" -XAtq -c "create role $COL login password '$PW' in role pgvigil_collector" \
  -c "create role $ALR login password '$PW' in role pgvigil_alerter" \
  -c "create role $RDR login password '$PW' in role pgvigil_reader" >/dev/null
export PGV_PROOF_ALERTS_DSN; PGV_PROOF_ALERTS_DSN=$(dsn "$ALR")
as() { local who=$1; shift; psql "$(dsn "$who")" -XAt "$@" 2>&1 || true; }

# ---- R: the role contract ---------------------------------------------------------------------------------------------
[[ $(as "$COL" -c "select has_function_privilege('pgvigil.import_alert_rule(timestamptz, jsonb)', 'EXECUTE')") == t ]] || fail "R: the collector may not call import_alert_rule"
out=$(as "$COL" -c "insert into pgvigil.alert_rules (metric, op, warning, scope, created_by, created_at) values ('host.load1', 'above', 1, 'fleet', 'x', now())")
[[ $out == *"permission denied"* ]] || fail "R: the collector inserted into alert_rules: $out"
out=$(as "$COL" -c "update pgvigil.alert_rule_log set detail = 'x'")
[[ $out == *"permission denied"* ]] || fail "R: the collector updated alert_rule_log: $out"
out=$(as "$COL" -c "select j->>'outcome', j->>'rule_id' from pgvigil.import_alert_rule(now(), '{\"op\":\"add\",\"ui_user\":\"proof-r\",\"client\":\"psql\",\"metric\":\"host.load1\",\"op_dir\":\"above\",\"warning\":1000000,\"scope\":\"fleet\"}') j")
[[ $out == done\|* ]] || fail "R: the collector's add through the function: $out"
RRULE=${out#done|}
out=$(as "$COL" -c "select pgvigil.import_alert_rule(now(), '{\"op\":\"end\",\"ui_user\":\"proof-r\",\"client\":\"psql\",\"rule_id\":$RRULE}')->>'outcome'")
[[ $out == done ]] || fail "R: the collector's end through the function: $out"
[[ $(as "$ALR" -c "select pgvigil.alert_rules_run(now())") =~ ^[0-9]+$ ]] || fail "R: the alerter could not run alert_rules_run: $(as "$ALR" -c "select pgvigil.alert_rules_run(now())")"
[[ $(as "$ALR" -c "select has_table_privilege('pgvigil.alert_rule_state', 'INSERT'), has_table_privilege('pgvigil.alert_rules', 'INSERT')") == "t|f" ]] || fail "R: the alerter's rights on alert_rule_state / alert_rules"
out=$(as "$ALR" -c "select pgvigil.import_alert_rule(now(), '{\"op\":\"end\",\"ui_user\":\"x\",\"rule_id\":$RRULE}')")
[[ $out == *"permission denied for function"* ]] || fail "R: the alerter called import_alert_rule: $out"
[[ $(as "$RDR" -c "select count(*) from pgvigil.metric_catalog") == 62 ]] || fail "R: the reader's metric_catalog: $(as "$RDR" -c "select count(*) from pgvigil.metric_catalog")"
out=$(as "$RDR" -c "select pgvigil.alert_rules_run(now())")
[[ $out == *"permission denied for table alert_rule_state"* || $out == *"permission denied for table alert_rule_fired"* ]] || fail "R: the reader ran alert_rules_run: $out"
ok "R: the collector writes rules only through import_alert_rule; the alerter judges and stores the state, writes no rule; the reader reads"

# ---- the first reads: the instances exist, the series have points ------------------------------------------------------
collect() { "$BIN" collect -config "$CFG" -once "$1" >/dev/null 2>"$WORK/collect.err" || fail "collect $1: $(tail -3 "$WORK/collect.err")"; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
FROM=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
for i in 1 2 3; do
  for _ in $(seq 1 15); do tq "select 1" >/dev/null; done   # commits on the target between the reads
  sleep 1.2                                                 # the backends' counts reach the shared statistics
  collect activity; collect dbstats
  [[ $i == 3 ]] || sleep 2
done
sleep 1.1; TO=$(now_utc)
id_of() { q "select instance_id from pgvigil.instances where name = '$1'"; }
AID=$(id_of "$INSTA"); BID=$(id_of "$INSTB")
[[ -n $AID && -n $BID ]] || fail "the two instances are not in the repository"

# ---- serve: one with the login, one without ----------------------------------------------------------------------------
PGVIGIL_PASSWORD=$UIPW "$BIN" user add -config "$CFG" $UIUSER >/dev/null 2>&1 || fail "user add"
PORT=$(freeport); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" >> "$WORK/serve.log" 2>&1 &
SRV=$!
PORT2=$(freeport); while [[ $PORT2 == "$PORT" ]]; do PORT2=$(freeport); done; U2="http://127.0.0.1:$PORT2"
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT2" -no-login >> "$WORK/serve2.log" 2>&1 &
SRV2=$!
for pair in "$SRV $U serve.log" "$SRV2 $U2 serve2.log"; do
  read -r pid url log <<<"$pair"
  for n in $(seq 1 60); do
    curl -sf -o /dev/null "$url/" && break
    kill -0 "$pid" 2>/dev/null || fail "serve died: $(tail -3 "$WORK/$log")"
    [[ $n == 60 ]] && fail "serve did not answer on $url"
    sleep 0.5
  done
done
JAR=$WORK/jar
code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
post() { code -b "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$2" "$U/api/$1"; }
getj() { curl -s -b "$JAR" "$U/api/$1" -o "$2" -w '%{http_code}'; }   # getj <path?query> <file>: the code
body_has() { grep -qF "$1" "$WORK/body"; }
rows_log() { q "select count(*) from pgvigil.alert_rule_log"; }
rows_rules() { q "select count(*) from pgvigil.alert_rules"; }

# ---- B: the write door -------------------------------------------------------------------------------------------------
GOOD='{"metric":"host.load1","op_dir":"above","warning":1000000,"scope":"fleet"}'
LOG0=$(rows_log); RULES0=$(rows_rules)
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$GOOD" "$U/api/alertrules") == 401 ]] || fail "B: no session: $(cat "$WORK/body")"
curl -s -c "$JAR" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$UIUSER\",\"password\":\"$UIPW\"}" "$U/api/login" >/dev/null
[[ -n $(awk '$6 == "pgvigil_session" {print $7}' "$JAR") ]] || fail "no session cookie in the jar"
[[ $(code -b "$JAR" -H 'Content-Type: application/json' -d "$GOOD" "$U/api/alertrules") == 403 ]] || fail "B: no header: $(cat "$WORK/body")"
while IFS='|' read -r what json; do
  [[ $(post alertrules "$json") == 400 ]] || fail "B: $what: $(cat "$WORK/body")"
done <<'EOF'
scope all|{"metric":"host.load1","op_dir":"above","warning":1,"scope":"all"}
a string for warning|{"metric":"host.load1","op_dir":"above","warning":"x","scope":"fleet"}
critical inside warning|{"metric":"host.load1","op_dir":"above","warning":9,"critical":5,"scope":"fleet"}
for_minutes 5000|{"metric":"host.load1","op_dir":"above","warning":1,"for_minutes":5000,"scope":"fleet"}
op end on the add route|{"op":"end","rule_id":1}
EOF
[[ $(rows_log) == "$LOG0" && $(rows_rules) == "$RULES0" ]] || fail "B: a 401, 403 or 400 left a row (log $(rows_log) was $LOG0, rules $(rows_rules) was $RULES0)"
: > "$WORK/api.log"
api() {   # api <path> <json> <code wanted>: one write through the API; its outcome is counted in api.log, its rule id kept
  local c; c=$(post "$1" "$2")
  [[ $c == "$3" ]] || fail "POST /api/$1 $2: $c, wanted $3: $(cat "$WORK/body")"
  case $c in 200) echo done >> "$WORK/api.log" ;; 409) echo refused >> "$WORK/api.log" ;; esac
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("rule_id") or "")' "$WORK/body" > "$WORK/last_id"
}
last_id() { cat "$WORK/last_id"; }
api alertrules '{"metric":"sessions.nope","op_dir":"above","warning":1,"scope":"fleet"}' 409
body_has "no metric" || fail "B: the unknown metric's refusal: $(cat "$WORK/body")"
[[ $(rows_log) == $((LOG0 + 1)) && $(rows_rules) == "$RULES0" ]] || fail "B: the refused request: log $(rows_log), rules $(rows_rules)"
[[ $(getj 'alertrules?part=rules' "$WORK/r.json") == 200 ]] || fail "B: GET /api/alertrules: $(cat "$WORK/r.json")"
[[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["writable"], d["user"])' "$WORK/r.json") == "True $UIUSER" ]] || fail "B: GET does not say writable and the user: $(cat "$WORK/r.json")"
curl -s "$U2/api/alertrules?part=rules" -o "$WORK/r2.json"
[[ $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["writable"], "-no-login" in d.get("reason", ""))' "$WORK/r2.json") == "False True" ]] || fail "B: the -no-login serve: $(cat "$WORK/r2.json")"
[[ $(code -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "$GOOD" "$U2/api/alertrules") == 403 ]] || fail "B: the -no-login serve took a write: $(cat "$WORK/body")"
[[ $(rows_log) == $((LOG0 + 1)) && $(rows_rules) == "$RULES0" ]] || fail "B: the -no-login serve wrote"
ok "B: 401 without a session, 403 without the header, 400 for five malformed requests, none logged; an unknown metric 409 and logged; no login = read only"

# ---- G: the grid equals hand queries -----------------------------------------------------------------------------------
cell() {   # cell <file> <key> <column>: one cell of the grid
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["grid"]; c=d["columns"]
r=[x for x in d["rows"] if x[c.index("key")]==sys.argv[2]]
print("" if not r or r[0][c.index(sys.argv[3])] is None else r[0][c.index(sys.argv[3])])' "$@"
}
same() { python3 -c 'import sys
a,b=float(sys.argv[1]),float(sys.argv[2]); sys.exit(0 if abs(a-b) <= 1e-6*max(1.0,abs(a),abs(b)) else 1)' "$1" "$2" 2>/dev/null; }
five() {   # five <file> <key> <hand: max|min|avg|current|samples> <what>
  local i=0 col got want
  for col in max_value min_value avg_value current_value samples; do
    i=$((i + 1)); got=$(cell "$1" "$2" $col); want=$(cut -d'|' -f$i <<<"$3")
    [[ -n $got && -n $want ]] && same "$got" "$want" || fail "G: $4: $2 $col reads '$got', the hand query '$want' (hand: $3)"
  done
}
[[ $(getj "metrics?instance=$AID&from=$FROM&to=$TO" "$WORK/ga.json") == 200 ]] || fail "G: GET /api/metrics: $(cat "$WORK/ga.json")"
HAND=$(q "select max(active), min(active), avg(active), (array_agg(active order by snapshot_at desc))[1], count(*)
            from pgvigil.activity_summary where instance_id = $AID and snapshot_at > '$FROM' and snapshot_at <= '$TO'")
[[ $(cut -d'|' -f5 <<<"$HAND") == 3 ]] || fail "G: the hand query sees $(cut -d'|' -f5 <<<"$HAND") activity samples, expected 3"
five "$WORK/ga.json" sessions.active "$HAND" "the instance"
hand_commits() {   # the rate per read from the raw rows: $1 = an extra filter on dbstats
  q "with w as (
       select d.snapshot_at, d.xact_commit - lag(d.xact_commit) over k as dx,
              extract(epoch from d.snapshot_at - lag(d.snapshot_at) over k)::int as secs,
              (d.stats_reset is distinct from lag(d.stats_reset) over k) as rs
         from pgvigil.dbstats d where d.instance_id = $AID and d.snapshot_at <= '$TO' $1
       window k as (partition by d.dbid order by d.snapshot_at)
     ), r as (
       select snapshot_at, sum(dx)::numeric / max(secs) as v from w
        where secs is not null and secs > 0 and snapshot_at > '$FROM' group by snapshot_at having not bool_or(rs)
     )
     select max(v), min(v), avg(v), (array_agg(v order by snapshot_at desc))[1], count(*) from r"
}
HAND=$(hand_commits "")
[[ $(cut -d'|' -f5 <<<"$HAND") == 2 ]] || fail "G: the hand rate has $(cut -d'|' -f5 <<<"$HAND") points, expected 2"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$(cut -d'|' -f1 <<<"$HAND")" || fail "G: no commit was counted between the reads ($HAND)"
five "$WORK/ga.json" database.commits_s "$HAND" "every database summed"
[[ $(getj "metrics?instance=$AID&from=$FROM&to=$TO&db=$TGT" "$WORK/gd.json") == 200 ]] || fail "G: GET /api/metrics db=: $(cat "$WORK/gd.json")"
HANDDB=$(hand_commits "and d.datname = '$TGT'")
five "$WORK/gd.json" database.commits_s "$HANDDB" "the target database alone"
[[ $(cell "$WORK/gd.json" database.commits_s database) == "$TGT" ]] || fail "G: the database cut does not name its database"
[[ $(getj "metrics/series?instance=$AID&metric=sessions.active&from=$FROM&to=$TO" "$WORK/s.json") == 200 ]] || fail "G: GET /api/metrics/series: $(cat "$WORK/s.json")"
read -r STEP NPTS LASTV < <(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); s=d["series"]; c=s["columns"]
print(d["step_secs"], len(s["rows"]), s["rows"][-1][c.index("value")] if s["rows"] else "none")' "$WORK/s.json")
[[ $STEP == 1 && $NPTS == 3 ]] && same "$LASTV" "$(cell "$WORK/ga.json" sessions.active current_value)" || fail "G: the series: step $STEP, $NPTS points, last $LASTV"
for bad in "metric=sessions.nope" "metric=requests.blocked" "metric=sessions.active&db=$TGT"; do
  [[ $(getj "metrics/series?instance=$AID&$bad&from=$FROM&to=$TO" "$WORK/bad.json") == 400 ]] || fail "G: series $bad did not answer 400: $(cat "$WORK/bad.json")"
done
ok "G: sessions.active and database.commits_s (summed: $HAND; $TGT alone) equal the hand queries; the series has the grid's points; three bad series requests 400"

# ---- S: a SQL Server instance's grid, seeded --------------------------------------------------------------------------
MSID=$(q "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
          values ('$INSTMS', 'sqlserver', '{env:proofms}', now(), now(), true, 'sqlserver') returning instance_id" | head -1)
q "insert into pgvigil.mssql_requests_summary (instance_id, snapshot_at, source, sessions, requests, blocked, heads, longest_wait_ms)
   select $MSID, now() - k * interval '1 minute', 'dmv', 30, 4, (array[0, 2, 7, 1, 3])[k + 1], 1, 100
     from generate_series(0, 4) k" >/dev/null
sleep 1.1; TO2=$(now_utc)
[[ $(getj "metrics?instance=$MSID&from=$FROM&to=$TO2" "$WORK/gm.json") == 200 ]] || fail "S: GET /api/metrics: $(cat "$WORK/gm.json")"
five "$WORK/gm.json" requests.blocked "7|0|2.6|0|5" "the seeded SQL Server series"
api alertrules "{\"metric\":\"requests.blocked\",\"op_dir\":\"above\",\"warning\":5,\"critical\":6,\"for_minutes\":0,\"scope\":\"instance\",\"instance_id\":$MSID}" 200
getj "metrics?instance=$MSID&from=$FROM&to=$TO2" "$WORK/gm.json" >/dev/null
got="$(cell "$WORK/gm.json" requests.blocked max_status) $(cell "$WORK/gm.json" requests.blocked min_status) $(cell "$WORK/gm.json" requests.blocked avg_status) $(cell "$WORK/gm.json" requests.blocked current_status) $(cell "$WORK/gm.json" requests.blocked rule_scope)"
[[ $got == "critical ok ok ok instance" ]] || fail "S: the statuses and scope read '$got'"
fams() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["grid"]; c=d["columns"]; print(" ".join(sorted({r[c.index("family")] for r in d["rows"]})))' "$1"; }
[[ $(fams "$WORK/gm.json") == "cpu host memory requests scheduler" ]] || fail "S: the SQL Server grid's families: $(fams "$WORK/gm.json")"
[[ $(fams "$WORK/ga.json") == "database host io server sessions" ]] || fail "S: the PostgreSQL grid's families: $(fams "$WORK/ga.json")"
ok "S: requests.blocked reads 7 / 0 / 2.6 / 0 over 5 samples; against above 5 / 6 the max is critical and the rest ok; each engine lists its own families"

# ---- F: fires once, clears once ----------------------------------------------------------------------------------------
pass() {   # one sender pass; a channel failure or a rule evaluation that failed fails the proof
  local tag=$1 rc
  set +e; "$BIN" alerts -config "$CFG" >"$WORK/pass.$tag.out" 2>"$WORK/pass.$tag.err"; rc=$?; set -e
  if (( rc != 0 )) || ! grep -q '^alerts: ' "$WORK/pass.$tag.out" || grep -q 'alert rules' "$WORK/pass.$tag.err"; then
    fail "pass $tag: exit $rc: $(cat "$WORK/pass.$tag.out") $(tr '\n' ' ' < "$WORK/pass.$tag.err" | cut -c1-600)"
  fi
}
files() {   # files <event> <setting>: the drop's files of that event and setting
  python3 -c 'import glob,json,sys
n=0
for f in glob.glob(sys.argv[1] + "/*.json"):
    d=json.load(open(f))
    if d.get("event") == sys.argv[2] and d.get("setting") == sys.argv[3]: n += 1
print(n)' "$WORK/drop" "$1" "$2"
}
state_of() { q "select state || ' ' || coalesce(extract(epoch from sample_at - beyond_since)::int, -1) || ' ' || rule_id
                  from pgvigil.alert_rule_state where instance_id = $1 and metric = '$2' and database = '${3:-}'"; }
IDLE='Sessions: idle in transaction'
collect activity
N0=$(q "select idle_in_txn from pgvigil.activity_summary where instance_id = $AID order by snapshot_at desc limit 1")
api alertrules "{\"name\":\"proof idle\",\"metric\":\"sessions.idle_in_txn\",\"op_dir\":\"above\",\"warning\":$((N0 + 1)),\"for_minutes\":1,\"scope\":\"instance\",\"instance_id\":$AID}" 200
FRULE=$(last_id)
# each held session is a psql reading a named pipe this script keeps open: nothing else is left running to wait for
# [run 2: the sessions were fed by '(echo ...; sleep 900) | psql'; the sleeps outlived their psql and the exit trap's
#  wait sat on them for up to 15 minutes after the last line, holding whatever lock the caller ran the proof under]
for i in 1 2 3; do
  mkfifo "$WORK/hold$i"
  PGAPPNAME=$HOLDAPP psql "$TGT_DSN" -XAtq < "$WORK/hold$i" >/dev/null 2>&1 & HOLD="$HOLD $!"
  exec {fd}> "$WORK/hold$i"; HOLDFDS+=("$fd")
  echo "begin; select 1;" >&"$fd"
done
held() { psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAt -c "select count(*) from pg_stat_activity where application_name = '$HOLDAPP' and state = 'idle in transaction'"; }
for n in $(seq 1 100); do [[ $(held) == 3 ]] && break; [[ $n == 100 ]] && fail "F: the three sessions are not idle in transaction ($(held))"; sleep 0.1; done
: > "$WORK/f.log"; FIRED=""
for i in $(seq 1 45); do
  collect activity; pass "f$i"
  read -r STATE SPAN RID <<<"$(state_of "$AID" sessions.idle_in_txn)"
  NF=$(files firing "$IDLE")
  echo "$i $STATE $SPAN $NF" >> "$WORK/f.log"
  [[ $RID == "$FRULE" ]] || fail "F: the state row is rule '$RID', expected $FRULE ($(cat "$WORK/f.log" | tr '\n' ';'))"
  if [[ $STATE == warning ]]; then FIRED=$i; break; fi
  [[ $STATE == pending ]] || fail "F: state '$STATE' while the sessions are held ($(tr '\n' ';' < "$WORK/f.log"))"
  (( SPAN < 60 )) || fail "F: still pending with a span of $SPAN s ($(tr '\n' ';' < "$WORK/f.log"))"
  (( NF == 0 )) || fail "F: a firing file while the rule is pending ($(tr '\n' ';' < "$WORK/f.log"))"
  sleep 4
done
[[ -n $FIRED ]] || fail "F: the rule never fired ($(tr '\n' ';' < "$WORK/f.log"))"
(( FIRED > 1 )) || fail "F: the rule fired at the first pass, before its minute ($(tr '\n' ';' < "$WORK/f.log"))"
(( SPAN >= 60 && NF == 1 )) || fail "F: at the firing pass: span $SPAN s, $NF firing file(s)"
for i in 1 2; do sleep 2; collect activity; pass "fa$i"; done
[[ $(files firing "$IDLE") == 1 && $(files repeat "$IDLE") == 0 ]] || fail "F: after two more passes: $(files firing "$IDLE") firing, $(files repeat "$IDLE") repeat file(s)"
release
for n in $(seq 1 100); do [[ $(held) == 0 ]] && break; [[ $n == 100 ]] && fail "F: the held sessions did not end"; sleep 0.1; done
collect activity; pass fr1
read -r STATE _ <<<"$(state_of "$AID" sessions.idle_in_txn)"
[[ $STATE == ok ]] || fail "F: state '$STATE' after the sessions were released"
[[ $(files resolved "$IDLE") == 0 ]] || fail "F: a resolved file before the instance was read again"
sleep 1; collect activity; pass fr2
[[ $(files resolved "$IDLE") == 1 ]] || fail "F: $(files resolved "$IDLE") resolved file(s) after the read and the pass, expected 1"
sleep 1; collect activity; pass fr3
[[ $(files resolved "$IDLE") == 1 && $(files firing "$IDLE") == 1 ]] || fail "F: at the end $(files firing "$IDLE") firing and $(files resolved "$IDLE") resolved file(s)"
[[ $(q "select fired from pgvigil.alert_rule_fired where rule_id = $FRULE") == 1 ]] || fail "F: alert_rule_fired: $(q "select fired from pgvigil.alert_rule_fired where rule_id = $FRULE")"
ok "F: pending for $((FIRED - 1)) pass(es), fired at pass $FIRED with a span of $SPAN s, one firing file, one resolved file after the release and a read"

# ---- T: a tag's rule wins over the fleet's, both ways --------------------------------------------------------------------
api alertrules '{"metric":"sessions.total","op_dir":"above","warning":100000,"for_minutes":0,"scope":"fleet"}' 200; TF1=$(last_id)
api alertrules '{"metric":"sessions.total","op_dir":"above","warning":0,"for_minutes":0,"scope":"tag","tag":"env:proofb"}' 200; TT1=$(last_id)
api alertrules '{"metric":"sessions.connections_pct","op_dir":"above","warning":0,"for_minutes":0,"scope":"fleet"}' 200; TF2=$(last_id)
api alertrules '{"metric":"sessions.connections_pct","op_dir":"above","warning":1000,"for_minutes":0,"scope":"tag","tag":"env:proofa"}' 200; TT2=$(last_id)
collect activity; pass t1
st() { read -r a _ c <<<"$(state_of "$1" "$2")"; echo "$a $c"; }
[[ $(st "$AID" sessions.total) == "ok $TF1" && $(st "$BID" sessions.total) == "warning $TT1" ]] || fail "T: sessions.total: A '$(st "$AID" sessions.total)', B '$(st "$BID" sessions.total)' (fleet $TF1, tag $TT1)"
[[ $(st "$AID" sessions.connections_pct) == "ok $TT2" && $(st "$BID" sessions.connections_pct) == "warning $TF2" ]] || fail "T: connections_pct: A '$(st "$AID" sessions.connections_pct)', B '$(st "$BID" sessions.connections_pct)' (fleet $TF2, tag $TT2)"
TO3=$(date -u -d '+2 seconds' +%Y-%m-%dT%H:%M:%SZ)
getj "metrics?instance=$AID&from=$FROM&to=$TO3" "$WORK/ta.json" >/dev/null; getj "metrics?instance=$BID&from=$FROM&to=$TO3" "$WORK/tb.json" >/dev/null
got="$(cell "$WORK/ta.json" sessions.total rule_scope) $(cell "$WORK/ta.json" sessions.total current_status) $(cell "$WORK/tb.json" sessions.total rule_scope) $(cell "$WORK/tb.json" sessions.total rule_target) $(cell "$WORK/tb.json" sessions.total current_status)"
[[ $got == "fleet ok tag env:proofb warning" ]] || fail "T: the grids read '$got'"
getj 'alertrules?part=rules' "$WORK/r.json" >/dev/null
rule() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))["rules"]; c=d["columns"]
r=[x for x in d["rows"] if x[c.index("rule_id")]==int(sys.argv[2])][0]
print(" ".join(str(r[c.index(k)]) for k in sys.argv[3:]))' "$WORK/r.json" "$@"; }
[[ $(rule "$TF1" covers in_force firing) == "2 1 0" && $(rule "$TT1" covers in_force firing) == "1 1 1" ]] || fail "T: fleet rule $(rule "$TF1" covers in_force firing), tag rule $(rule "$TT1" covers in_force firing)"
[[ $(files firing 'Sessions: sessions') == 0 && $(files firing 'Sessions: connections used') == 0 ]] || fail "T: A's drop holds a file of a rule that fires on B alone"
ok "T: B fires under its tag's rule where the fleet's would not; A is quiet under its tag's rule where the fleet's fires; the grids and the rule list say which rule is in force"

# ---- D: a database rule ------------------------------------------------------------------------------------------------
DSET="Database: commits [$TGT]"
api alertrules "{\"metric\":\"database.commits_s\",\"op_dir\":\"above\",\"warning\":-1,\"for_minutes\":0,\"scope\":\"instance\",\"instance_id\":$AID,\"database\":\"$TGT\"}" 200; D1=$(last_id)
for _ in 1 2; do tq "select 1" >/dev/null; sleep 1.2; collect dbstats; done
pass d1
read -r STATE _ RID <<<"$(state_of "$AID" database.commits_s "$TGT")"
[[ $STATE == warning && $RID == "$D1" ]] || fail "D: the database's state row: '$STATE' rule '$RID'"
[[ -z $(state_of "$AID" database.commits_s) ]] || fail "D: the instance's summed series has a state row: $(state_of "$AID" database.commits_s)"
TO4=$(date -u -d '+2 seconds' +%Y-%m-%dT%H:%M:%SZ)
getj "metrics?instance=$AID&from=$FROM&to=$TO4&db=$TGT" "$WORK/dd.json" >/dev/null; getj "metrics?instance=$AID&from=$FROM&to=$TO4" "$WORK/da.json" >/dev/null
[[ "$(cell "$WORK/dd.json" database.commits_s rule_database) $(cell "$WORK/dd.json" database.commits_s current_status)" == "$TGT warning" ]] || fail "D: the database cut's row: $(cell "$WORK/dd.json" database.commits_s rule_database) $(cell "$WORK/dd.json" database.commits_s current_status)"
[[ -z $(cell "$WORK/da.json" database.commits_s rule_id) ]] || fail "D: the summed row shows the database's rule"
[[ $(files firing "$DSET") == 1 ]] || fail "D: $(files firing "$DSET") firing file(s) of '$DSET'"
ok "D: the rule on $TGT's own series fires for it alone; the summed row carries no rule"

# ---- E: edit, switch, end ------------------------------------------------------------------------------------------------
api alertrules "{\"op\":\"edit\",\"rule_id\":$D1,\"metric\":\"database.commits_s\",\"op_dir\":\"above\",\"warning\":1e12,\"for_minutes\":0,\"scope\":\"instance\",\"instance_id\":$AID,\"database\":\"$TGT\"}" 200; D2=$(last_id)
[[ -n $D2 && $D2 != "$D1" ]] || fail "E: the edit answered rule id '$D2' (was $D1)"
[[ $(q "select ended_by || ' ' || (ended_at is not null) from pgvigil.alert_rules where rule_id = $D1") == "$UIUSER true" ]] || fail "E: the edited rule is not ended by $UIUSER"
[[ $(q "select replaces from pgvigil.alert_rules where rule_id = $D2") == "$D1" ]] || fail "E: rule $D2 does not replace $D1"
pass e1
read -r STATE _ RID <<<"$(state_of "$AID" database.commits_s "$TGT")"
[[ $STATE == ok && $RID == "$D2" ]] || fail "E: after the edit: '$STATE' rule '$RID'"
api alertrules "{\"op\":\"disable\",\"rule_id\":$D2}" 200
pass e2
[[ -z $(state_of "$AID" database.commits_s "$TGT") ]] || fail "E: a rule switched off still has a state row"
getj 'alertrules?part=rules' "$WORK/r.json" >/dev/null
[[ $(rule "$D2" enabled in_force) == "False 0" ]] || fail "E: the switched-off rule reads $(rule "$D2" enabled in_force)"
api alertrules "{\"op\":\"disable\",\"rule_id\":$D2}" 409; body_has "already off" || fail "E: the second disable: $(cat "$WORK/body")"
api alertrules "{\"op\":\"enable\",\"rule_id\":$D2}" 200
api alertrules/end "{\"rule_id\":$D2}" 200
api alertrules/end "{\"rule_id\":$D2}" 409; body_has "was ended" || fail "E: the second end: $(cat "$WORK/body")"
ok "E: an edit ends the rule and writes its successor; off = in force nowhere; a second disable and a second end are refused"

# ---- A: the audit --------------------------------------------------------------------------------------------------------
DONE=$(grep -c '^done$' "$WORK/api.log" || true); REFUSED=$(grep -c '^refused$' "$WORK/api.log" || true)
got=$(q "select string_agg(outcome || '=' || n, ' ' order by outcome) from (select outcome, count(*) n from pgvigil.alert_rule_log where ui_user = '$UIUSER' group by 1) x")
[[ $got == "done=$DONE refused=$REFUSED" ]] || fail "A: the log holds '$got' by $UIUSER, the proof made done=$DONE refused=$REFUSED"
[[ $(q "select count(*) from pgvigil.alert_rule_log where ui_user = '$UIUSER' and client is distinct from '127.0.0.1'") == 0 ]] || fail "A: a row of $UIUSER from another client"
[[ $(q "select string_agg(ui_user || '=' || n, ' ' order by ui_user) from (select ui_user, count(*) n from pgvigil.alert_rule_log where ui_user <> '$UIUSER' group by 1) x") == "proof-r=2" ]] || fail "A: rows by another user: $(q "select ui_user, count(*) from pgvigil.alert_rule_log group by 1")"
[[ $(q "select count(*) from pgvigil.alert_rules where created_by not in ('$UIUSER', 'proof-r')") == 0 ]] || fail "A: a rule made by another user"
ok "A: the log holds the $DONE done and $REFUSED refused attempts of $UIUSER from 127.0.0.1 and R's two; every rule has its maker"

# ---- V: PostgreSQL 13 ----------------------------------------------------------------------------------------------------
if [[ ${PGVIGIL_SKIP_PG13:-0} == 1 ]]; then
  echo "NOT PROVEN ON POSTGRESQL 13: PGVIGIL_SKIP_PG13=1 (part V skipped)"
  echo "proof-alert-rules: R B G S F T D E A green on PostgreSQL $(q "select current_setting('server_version')"); V NOT RUN"
  exit 0
fi
command -v docker >/dev/null || fail "V: docker is not on this machine (PGVIGIL_SKIP_PG13=1 skips part V and says so)"
P13=$(freeport); PW13=v$RANDOM$RANDOM$RANDOM; PG13=pgv-s3rules-pg13-$SUF
docker run -d --rm --name "$PG13" -e POSTGRES_PASSWORD="$PW13" -p "127.0.0.1:$P13:5432" postgres:13 >/dev/null || fail "V: the postgres:13 container did not start"
export PGV13_DSN="host=127.0.0.1 port=$P13 user=postgres password=$PW13 dbname=pgvigil_s3rules_v13 sslmode=disable"
for n in $(seq 1 90); do
  psql "host=127.0.0.1 port=$P13 user=postgres password=$PW13 dbname=postgres sslmode=disable" -XAtc "select 1" >/dev/null 2>&1 && break
  [[ $n == 90 ]] && fail "V: PostgreSQL 13 did not answer on port $P13"
  sleep 1
done
sleep 2   # the image restarts the server once after its init: wait for the second start
for n in $(seq 1 60); do
  psql "host=127.0.0.1 port=$P13 user=postgres password=$PW13 dbname=postgres sslmode=disable" -XAtc "create database pgvigil_s3rules_v13" >/dev/null 2>&1 && break
  [[ $n == 60 ]] && fail "V: could not create the database on PostgreSQL 13"
  sleep 1
done
v() { psql "$PGV13_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
[[ $(v "select current_setting('server_version_num')::int / 10000") == 13 ]] || fail "V: the container is not PostgreSQL 13"
printf 'repository:\n  dsn: env:PGV13_DSN\ninstances: []\n' > "$WORK/v13.yaml"
"$BIN" migrate -config "$WORK/v13.yaml" >"$WORK/v13.log" 2>&1 || fail "V: migrate on PostgreSQL 13: $(tail -3 "$WORK/v13.log")"
[[ $(v "select count(*) from pgvigil.schema_version where version = '0085_alert_rules.sql'") == 1 ]] || fail "V: 0085 not applied on PostgreSQL 13"
VID=$(v "insert into pgvigil.instances (name, platform, tags, first_seen, last_seen, is_active, engine)
         values ('v13', 'self-managed', '{}', now(), now(), true, 'postgres') returning instance_id" | head -1)
v "insert into pgvigil.activity_summary (instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
                                         active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections)
   select $VID, now() - k * interval '1 minute', 20, 3, 10, case when k < 10 then 5 else 2 end, 0, 0, 0, 12, 30, 1000, 100
     from generate_series(0, 29) k" >/dev/null
got=$(v "select max_value, min_value, round(avg_value::numeric, 6), current_value, samples
           from pgvigil.metric_grid($VID, now() - interval '1 hour', now()) where key = 'sessions.idle_in_txn'")
[[ $got == "5|2|3.000000|5|30" ]] || fail "V: the grid on PostgreSQL 13 reads '$got'"
got=$(v "select count(*) from unnest(array['sessions', 'database', 'server', 'io', 'host', 'requests', 'cpu', 'scheduler', 'memory']) f,
                lateral pgvigil.metric_points($VID, f, now() - interval '1 hour', now()) p")
[[ $got == 240 ]] || fail "V: the nine families' points on PostgreSQL 13: '$got'"
got=$(v "select pgvigil.import_alert_rule(now(), '{\"op\":\"add\",\"ui_user\":\"v13\",\"metric\":\"sessions.idle_in_txn\",\"op_dir\":\"above\",\"warning\":3,\"critical\":4,\"for_minutes\":5,\"scope\":\"fleet\"}')->>'outcome'")
[[ $got == done ]] || fail "V: import_alert_rule on PostgreSQL 13: '$got'"
[[ $(v "select pgvigil.alert_rules_run(now())") == 1 ]] || fail "V: alert_rules_run on PostgreSQL 13"
[[ $(v "select state, value, threshold from pgvigil.alert_rule_state") == "critical|5|4" ]] || fail "V: the state on PostgreSQL 13: $(v "select state, value, threshold from pgvigil.alert_rule_state")"
[[ $(v "select severity, setting from pgvigil.alert_findings where source = 'alert rule'") == "critical|Sessions: idle in transaction" ]] || fail "V: the finding on PostgreSQL 13"
docker rm -f "$PG13" >/dev/null 2>&1 || true; PG13=""
ok "V: PostgreSQL 13: every migration applies; the grid 5 / 2 / 3 / 5 over 30 samples, the nine families read, a rule added, judged critical and listed as a finding"
echo "proof-alert-rules: R B G S F T D E A V green"
