#!/usr/bin/env bash
# Proof of B24d, serve's Prometheus endpoint (internal/web/metrics_prom.go, 0196_metrics_newest.sql, scripts/proof-prometheus-wiring.patch,
# docs/prometheus.md). A demo fleet (1 day) is seeded into a throwaway database and served by `pgvigil serve` with its
# UI login on a login IN ROLE pgvigil_reader, pgvigil_auth (P9: never the owner). Prometheus 3.5.0 (pinned, its
# sha256sums.txt checked) gives promtool and the scrape. Box only (dba-lab-box), never the laptop.
#   PGVIGIL_ADMIN_DSN   the box's PostgreSQL as its owner (a database is made and dropped)
#   PROM_SCALE          instances of the P8 scale run (default 1000; 0 = P8 NOT PROVEN)
# Expected (red on a build without /metrics):
#   P1 off       serve with no doors: GET /metrics 404 naming doors.prometheus_metrics, never the page shell
#   P2 start     doors on under -no-login without metrics.token: serve exits non-zero naming metrics.token; a token file
#                of 10 bytes: exits naming '32'; env:NAME of an unset variable: exits; a 40-byte token: starts
#   P3 gate      no credentials 401 (WWW-Authenticate Bearer); a wrong token 401; the token differing in its last byte
#                401; 'Bearer ' empty 401; ?token=<token> 400; the token 200; a signed-in session 200; the token on
#                /api/instances 401 (the bearer never opens the API); under -no-login a stale cookie 401 and serve still
#                up; serve's log after these holds neither the token nor 'Authorization'
#   P4 format    promtool check metrics: no error (its lint warnings printed); Content-Type 'text/plain;
#                version=0.0.4; charset=utf-8' on the plain and the gzip reply; every name's HELP and TYPE once with all
#                its samples right after (metric-first, read by python); a server named with a quote, a backslash and
#                a line feed escaped in its labels (and promtool still clean)
#   P5 values    on every active instance of both engines, metric_grid's fresh 'current' = metrics_newest's value, both
#                ways (0 differences), after a counter reset seeded on one database - the families /metrics does not
#                export yet (promNotExported, read from internal/web/metrics_prom.go) left out of the grid side, and
#                metrics_newest returning no key of them (NOT PROVEN for their values); the body's pgvigil_sessions /
#                pgvigil_requests_blocked / pgvigil_memory_total_bytes / pgvigil_cpu_sql_ratio = metrics_newest
#                converted; the catalog keys no demo instance produces listed (NOT PROVEN for those)
#   P6 stale     one instance's sessions rows of the last 15 minutes deleted: after a render its pgvigil_sessions is
#                gone and its pgvigil_sample_timestamp_seconds{family="sessions"} is there, older than 600 s
#   P7 scrape    Prometheus 3.5.0 scrapes https://<the box's address>:<port>/metrics (serve's TLS listen with the
#                `pgvigil cert` pair, tls_config.ca_file, authorization.credentials_file, gzip): up == 1;
#                pgvigil_instance_info has one series per active instance; an instance set inactive leaves the
#                scrape's result within 3 scrapes
#   P8 scale     PROM_SCALE instances: the cold render under 10 s (pgvigil_metrics_render_seconds), the series and
#                the body's bytes printed, 8 concurrent scrapes after expiry share ONE render (one
#                pgvigil_metrics_last_render_timestamp_seconds value)
#   P10 rotate   the token file rewritten while Prometheus scrapes every 5 s, the OLD token read 200 right after the
#                rewrite, credentials_file changed 3 s later: min_over_time(up[90s]) == 1 a minute later (the window
#                holds the scrapes that sent the old token: no refused scrape)
# Amended before any run: P2 greps each refusal's own words; P4 waits
# for a render after the odd server's insert (P6's way); P5 reads psql's CSV (a name with a line feed) and leaves the
# odd server out of its four-value check; P6 checks the instance was there before; P8 needs 20 x PROM_SCALE series
# at least, every one of the 8 scrapes a body, and says NOT PROVEN when the seeded data is not fresh (and that
# 50 databases per instance is not seeded); the address is the first IPv4, the role name random, the 'last byte'
# token always differs; the release's tarball checked against its own sha256sums.txt (a corrupted download caught,
# a replaced release not: no checksum from another source is at hand), the box's architecture read.
set -uo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d /tmp/pgv-prom-XXXXXX)
SFX=$RANDOM; DB=pgv_prom_$SFX; DB8=pgv_prom8_$SFX
PORT=$((20000 + RANDOM % 10000)); PORT2=$((PORT + 1)); PORT3=$((PORT + 2)); PPORT=$((PORT + 3))
PROMV=3.5.0
case "$(uname -m)" in x86_64) PARCH=amd64 ;; aarch64|arm64) PARCH=arm64 ;; *) PARCH=unknown ;; esac
bad=0; UNWIRE=0; PIDS=()
no() { echo "FAIL $*"; bad=$((bad + 1)); }
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*"; exit 1; }
cleanup() {
  rc=$?
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  [[ $UNWIRE == 1 ]] && { git apply -R scripts/proof-prometheus-wiring.patch || { echo "FAIL the wiring patch was not taken back"; rc=1; }; }
  for d in $DB $DB8; do timeout 300 psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1; done
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists pgv_prom_ui_$SFX" >/dev/null 2>&1
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
for t in go psql curl python3 tar sha256sum; do command -v $t >/dev/null || fail "$t is not on this machine"; done

if grep -q 'PromMetrics' internal/web/web.go; then echo "wiring: already in this tree"
else git apply scripts/proof-prometheus-wiring.patch || fail "scripts/proof-prometheus-wiring.patch does not apply"; UNWIRE=1; echo "wiring: scripts/proof-prometheus-wiring.patch applied for this run"; fi
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || fail "build"
BIN=$WORK/pgvigil

echo "== Prometheus $PROMV (pinned; its sha256sums.txt checked)"
U=https://github.com/prometheus/prometheus/releases/download/v$PROMV
(cd "$WORK" && curl -fsSLO "$U/prometheus-$PROMV.linux-$PARCH.tar.gz" && curl -fsSLO "$U/sha256sums.txt" \
  && grep " prometheus-$PROMV.linux-$PARCH.tar.gz\$" sha256sums.txt | sha256sum -c - >/dev/null && tar xzf "prometheus-$PROMV.linux-$PARCH.tar.gz") \
  || fail "Prometheus $PROMV download or checksum"
PROM=$WORK/prometheus-$PROMV.linux-$PARCH

echo "== seed the demo (1 day) into $DB"
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || fail "create database"
"$BIN" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -days 1 > "$WORK/demo.log" 2>&1 || { tail -5 "$WORK/demo.log"; fail "the demo seed"; }
Q() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
PW=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists pgv_prom_ui_$SFX" -c "create role pgv_prom_ui_$SFX login password '$PW' in role pgvigil_reader, pgvigil_auth" >/dev/null || fail "the serve login"
HOSTPART=$(sed -nE 's/.*host=([^ ]+).*/\1/p' <<< "$PGVIGIL_ADMIN_DSN"); PORTPART=$(sed -nE 's/.*port=([0-9]+).*/\1/p' <<< "$PGVIGIL_ADMIN_DSN")
export UI_DSN="host=${HOSTPART:-127.0.0.1} port=${PORTPART:-5432} user=pgv_prom_ui_$SFX password=$PW dbname=$DB sslmode=disable"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
TOK=$(head -c 30 /dev/urandom | base64 | tr -dc 'A-Za-z0-9'); TOK=${TOK}abcdefghij0123456789; TOK=${TOK:0:40}
printf '%s\n' "$TOK" > "$WORK/token"; chmod 600 "$WORK/token"
printf '%s' "${TOK:0:10}" > "$WORK/short"
cfg() { # cfg <file> <doors block on|off> [extra metrics lines]
  { printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n'
    [[ $2 == on ]] && printf 'doors:\n  prometheus_metrics: on\nmetrics:\n  cache_seconds: 5\n%s' "${3:-}"; } > "$1"; }
start() { # start <log> <base url> <serve args...>: serve in the background, its pid in SPID; waits until it answers
  "$BIN" serve "${@:3}" > "$1" 2>&1 & SPID=$!; PIDS+=($SPID)
  for _ in $(seq 1 150); do [[ $(curl -sk -o /dev/null -w '%{http_code}' "$2/api/session") != 000 ]] && return 0; kill -0 $SPID 2>/dev/null || return 1; sleep 0.2; done; return 1; }
code() { curl -sk -o "$WORK/body" -w '%{http_code}' "$@"; }

echo "== P1 off"; b0=$bad
cfg "$WORK/off.yaml" off
start "$WORK/off.log" "http://127.0.0.1:$PORT" -config "$WORK/off.yaml" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" || fail "the off serve did not start: $(tail -3 "$WORK/off.log")"
c=$(code "http://127.0.0.1:$PORT/metrics")
[[ $c == 404 ]] && grep -q 'doors.prometheus_metrics' "$WORK/body" && ! grep -qi '<!doctype' "$WORK/body" || no "P1: $c $(head -c 200 "$WORK/body")"
kill $SPID; wait $SPID 2>/dev/null
[[ $bad -eq $b0 ]] && ok "P1 off: 404, '$(head -c 90 "$WORK/body")...'"

echo "== P2 start checks"; b0=$bad
cfg "$WORK/p2a.yaml" on
"$BIN" serve -config "$WORK/p2a.yaml" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" -no-login > "$WORK/p2a.log" 2>&1 & p=$!; sleep 4
if kill -0 $p 2>/dev/null; then kill $p; no "P2: -no-login without a token started"; else grep -q 'metrics.token' "$WORK/p2a.log" || no "P2: -no-login without a token: $(tail -1 "$WORK/p2a.log")"; fi
cfg "$WORK/p2b.yaml" on "  token: file:$WORK/short"$'\n'
"$BIN" serve -config "$WORK/p2b.yaml" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" > "$WORK/p2b.log" 2>&1 & p=$!; sleep 4
if kill -0 $p 2>/dev/null; then kill $p; no "P2: a 10-byte token started"; else grep -q 'it needs 32' "$WORK/p2b.log" || no "P2: the short token: $(tail -1 "$WORK/p2b.log")"; fi
cfg "$WORK/p2c.yaml" on "  token: env:PGV_PROM_UNSET_$RANDOM"$'\n'
"$BIN" serve -config "$WORK/p2c.yaml" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" > "$WORK/p2c.log" 2>&1 & p=$!; sleep 4
if kill -0 $p 2>/dev/null; then kill $p; no "P2: an unset env token started"; else grep -q 'metrics.token' "$WORK/p2c.log" || no "P2: the unset env token: $(tail -1 "$WORK/p2c.log")"; fi
wait 2>/dev/null
[[ $bad -eq $b0 ]] && ok "P2 start: refused without a token under -no-login, at 10 bytes, on an unset env:NAME"

echo "== the main serve (login on, token file, loopback)"
cfg "$WORK/on.yaml" on "  token: file:$WORK/token"$'\n'
USR=promproof; UPW=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')x9Q
PGVIGIL_PASSWORD="$UPW" "$BIN" user add -config "$WORK/on.yaml" "$USR" >/dev/null 2>&1 || fail "user add"
start "$WORK/on.log" "http://127.0.0.1:$PORT" -config "$WORK/on.yaml" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" || fail "the main serve: $(tail -3 "$WORK/on.log")"
MAIN=$SPID; B="http://127.0.0.1:$PORT"
grep -q 'doors.prometheus_metrics is on' "$WORK/on.log" || no "P1: no start WARN naming what is open"

echo "== P3 the gate"; b0=$bad
h() { echo "Authorization: Bearer $1"; }
[[ $(code "$B/metrics") == 401 ]] && curl -s -D - -o /dev/null "$B/metrics" | grep -qi '^www-authenticate: Bearer' || no "P3: no credentials"
[[ $(code -H "$(h "$(printf 'x%.0s' $(seq 40))")" "$B/metrics") == 401 ]] || no "P3: a wrong token"
LASTB=Z; [[ ${TOK:39:1} == Z ]] && LASTB=Y
[[ $(code -H "$(h "${TOK:0:39}$LASTB")" "$B/metrics") == 401 ]] || no "P3: the last byte differs"
[[ $(code -H "Authorization: Bearer " "$B/metrics") == 401 ]] || no "P3: 'Bearer ' empty"
[[ $(code "$B/metrics?token=$TOK") == 400 ]] || no "P3: a token in the URL"
[[ $(code -H "$(h "$TOK")" "$B/metrics") == 200 ]] || no "P3: the token: $(head -c 200 "$WORK/body")"
[[ $(code -H "$(h "$TOK")" "$B/api/instances") == 401 ]] || no "P3: the token opened /api/instances"
CJ=$WORK/cj
[[ $(curl -s -o /dev/null -w '%{http_code}' -c "$CJ" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "{\"username\":\"$USR\",\"password\":\"$UPW\"}" "$B/api/login") == 200 ]] || no "P3: login"
[[ $(code -b "$CJ" "$B/metrics") == 200 ]] || no "P3: a signed-in session"
cfg "$WORK/nl.yaml" on "  token: file:$WORK/token"$'\n'
start "$WORK/nl.log" "http://127.0.0.1:$PORT3" -config "$WORK/nl.yaml" -dsn env:UI_DSN -listen "127.0.0.1:$PORT3" -no-login || no "P3: the -no-login serve with a token did not start"
NL=$SPID
[[ $(code -H 'Cookie: pgvigil_session=stale0000' "http://127.0.0.1:$PORT3/metrics") == 401 ]] && kill -0 $NL 2>/dev/null || no "P3: a stale cookie under -no-login"
kill $NL 2>/dev/null
for f in "$WORK/on.log" "$WORK/nl.log"; do grep -q -- "$TOK" "$f" && no "P3: the token is in $(basename "$f")"; grep -qi 'authorization' "$f" && no "P3: 'Authorization' in $(basename "$f")"; done
[[ $bad -eq $b0 ]] && ok "P3 gate: 401 x4 (none, wrong, last byte, empty), the URL token 400, the token 200, a session 200, the token on /api/instances 401, a stale cookie under -no-login 401 with serve up, no token or header in the logs"

echo "== P4 format"; b0=$bad
psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<SQL || no "P4: the odd server"
SELECT pgvigil.ensure_instance(E'proof"odd\\\\name\nline', 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres');
INSERT INTO pgvigil.activity_summary (instance_id, snapshot_at, total, active, max_connections)
SELECT instance_id, now(), 4, 1, 100 FROM pgvigil.instances WHERE name = E'proof"odd\\\\name\nline';
SQL
# the body of the last 5 s is served and one 5-10 s old too (a render starts behind it): wait for a body with the odd
# server, at most 30 s
for _ in $(seq 1 15); do sleep 2; curl -s -H "$(h "$TOK")" -D "$WORK/hdr" -o "$WORK/m.txt" "$B/metrics"; grep -q 'proof' "$WORK/m.txt" && break; done
curl -s -H "$(h "$TOK")" -H 'Accept-Encoding: gzip' -D "$WORK/hdrz" -o "$WORK/m.gz" "$B/metrics"
grep -qi '^content-type: text/plain; version=0.0.4; charset=utf-8' "$WORK/hdr" || no "P4: plain Content-Type $(grep -i content-type "$WORK/hdr")"
grep -qi '^content-type: text/plain; version=0.0.4; charset=utf-8' "$WORK/hdrz" && grep -qi '^content-encoding: gzip' "$WORK/hdrz" || no "P4: gzip headers"
gunzip -c "$WORK/m.gz" > "$WORK/mz.txt" 2>/dev/null && [[ -s "$WORK/mz.txt" ]] || no "P4: the gzip body"
"$PROM/promtool" check metrics < "$WORK/m.txt" > "$WORK/promtool.txt" 2>&1; prc=$?
[[ $prc -eq 0 ]] || no "P4: promtool rc $prc: $(head -5 "$WORK/promtool.txt")"
grep -q 'server="proof\\"odd\\\\name\\nline"' "$WORK/m.txt" || no "P4: the odd server's label not escaped: $(grep -m1 'proof' "$WORK/m.txt")"
LAY=$(python3 -I - "$WORK/m.txt" <<'PY'
import sys
seen, cur, bad = set(), None, []
for ln in open(sys.argv[1]):
    if ln.startswith('# TYPE '):
        n = ln.split()[2]
        if n in seen: bad.append('TYPE twice ' + n)
        seen.add(n); cur = n; continue
    if ln.startswith('#') or not ln.strip(): continue
    n = ln.split('{')[0].split(' ')[0]
    if n != cur: bad.append('sample of %s under %s' % (n, cur))
print('; '.join(bad[:3]) if bad else 'ok %d names' % len(seen))
PY
)
[[ $LAY == ok* ]] || no "P4: layout: $LAY"
[[ $bad -eq $b0 ]] && ok "P4 format: promtool rc 0 ($(wc -l < "$WORK/promtool.txt") lint line(s)), Content-Type on both replies, gzip, $LAY metric-first, the odd server escaped"

echo "== P5 values"; b0=$bad
# the families /metrics does not export yet, read from the product (PROMNAMES' promNotExported): an entry that goes is
# compared here by itself
NOEXP=$(sed -n '/^var promNotExported = map\[string\]string{/,/^}/p' internal/web/metrics_prom.go | grep -oE '^[[:space:]]+"[a-z_]+":' | tr -d ' \t":' | sort | tr '\n' ' ')
[[ -n "$NOEXP" ]] || no "P5: promNotExported's families could not be read from internal/web/metrics_prom.go"
NOEXPSQL=$(for f in $NOEXP; do printf "'%s'," "$f"; done | sed 's/,$//'); [[ -n "$NOEXPSQL" ]] || NOEXPSQL="''"
LEAK=$(Q "SELECT coalesce(string_agg(DISTINCT family, ',' ORDER BY family), '') FROM pgvigil.metrics_newest() WHERE family IN ($NOEXPSQL)")
[[ -z "$LEAK" ]] || no "P5: metrics_newest returns the families promNotExported says /metrics does not export: $LEAK"
Q "UPDATE pgvigil.dbstats d SET stats_reset = now() FROM (SELECT instance_id, dbid, max(snapshot_at) m FROM pgvigil.dbstats
     WHERE snapshot_at > now() - interval '30 minutes' GROUP BY 1, 2 ORDER BY 1, 2 LIMIT 1) x
   WHERE d.instance_id = x.instance_id AND d.dbid = x.dbid AND d.snapshot_at = x.m" >/dev/null || no "P5: the reset"
DIFF=$(Q "WITH i AS (SELECT instance_id FROM pgvigil.instances WHERE is_active),
  g AS (SELECT i.instance_id, g.key, g.current_value FROM i CROSS JOIN LATERAL pgvigil.metric_grid(i.instance_id, now() - interval '1 hour', now()) g
          JOIN pgvigil.metric_catalog c ON c.key = g.key WHERE g.current_value IS NOT NULL AND g.current_at > now() - make_interval(secs => c.fresh_secs)
           AND split_part(g.key, '.', 1) NOT IN ($NOEXPSQL)),
  n AS (SELECT instance_id, family || '.' || metric AS key, value FROM pgvigil.metrics_newest() WHERE database IS NULL AND metric <> 'cut')
  SELECT count(*) || '|' || coalesce(string_agg(DISTINCT coalesce(g.key, n.key), ',' ), '') FROM g FULL JOIN n USING (instance_id, key)
   WHERE g.key IS NULL OR n.key IS NULL OR abs(g.current_value - n.value) > 1e-9 * greatest(1, abs(g.current_value))")
[[ ${DIFF%%|*} == 0 ]] || no "P5: $DIFF (count|keys differing between the grid and metrics_newest)"
NOTPROD=$(Q "SELECT string_agg(c.key, ',' ORDER BY c.key) FROM pgvigil.metric_catalog c
   WHERE split_part(c.key, '.', 1) NOT IN ($NOEXPSQL) AND NOT EXISTS (SELECT 1 FROM pgvigil.metrics_newest() n WHERE n.family || '.' || n.metric = c.key)")
NK=$(Q "SELECT count(DISTINCT family || '.' || metric) FROM pgvigil.metrics_newest() WHERE metric <> 'cut'")
sleep 6
curl -s -H "$(h "$TOK")" -o "$WORK/m5.txt" "$B/metrics"
python3 -I - "$WORK/m5.txt" "$PGVIGIL_ADMIN_DSN dbname=$DB" > "$WORK/p5conv.txt" <<'PY' || no "P5: the body against metrics_newest: $(cat "$WORK/p5conv.txt")"
import subprocess, sys
body = {}
for ln in open(sys.argv[1]):
    if ln.startswith('#') or not ln.strip(): continue
    k, v = ln.rsplit(' ', 1); body[k] = float(v)
import csv, io
rows = subprocess.run(['psql', sys.argv[2], '-Xq', '--csv', '-t', '-c', """
  SELECT i.name, i.engine, n.family || '.' || n.metric, n.value FROM pgvigil.metrics_newest() n JOIN pgvigil.instances i USING (instance_id)
   WHERE n.database IS NULL AND i.name NOT LIKE 'proof%' AND n.family || '.' || n.metric IN ('sessions.total', 'requests.blocked', 'memory.total_mb', 'cpu.sql_pct')"""],
   capture_output=True, text=True, check=True).stdout
rows = list(csv.reader(io.StringIO(rows)))
name = {'sessions.total': ('pgvigil_sessions', 1), 'requests.blocked': ('pgvigil_requests_blocked', 1),
        'memory.total_mb': ('pgvigil_memory_total_bytes', 1048576), 'cpu.sql_pct': ('pgvigil_cpu_sql_ratio', 0.01)}
bad, n = [], 0
for r in rows:
    if len(r) != 4: continue
    srv, eng, key, val = r
    if '"' in srv or '\\' in srv: continue
    m, f = name[key]
    k = '%s{server="%s",engine="%s"}' % (m, srv, eng)
    if k not in body or abs(body[k] - float(val) * f) > 1e-9 * max(1, abs(float(val) * f)): bad.append('%s %s vs %s' % (k, body.get(k), float(val) * f))
    n += 1
print('; '.join(bad[:3]) if bad else 'ok %d values' % n); sys.exit(1 if bad or n == 0 else 0)
PY
[[ $bad -eq $b0 ]] && ok "P5 values: 0 differences with metric_grid on every active instance after a reset; $NK keys produced; the body $(cat "$WORK/p5conv.txt") converted"
[[ -n "$NOTPROD" ]] && echo "NOT PROVEN P5: catalog keys no demo instance produces: $NOTPROD"
echo "NOT PROVEN P5: the families /metrics does not export yet (promNotExported), their values not compared: $NOEXP"

echo "== P6 stale"; b0=$bad
SI=$(Q "SELECT i.name FROM pgvigil.instances i WHERE i.is_active AND i.engine = 'postgres' AND i.name LIKE 'demo-%' ORDER BY i.name LIMIT 1")
grep -q "^pgvigil_sessions{server=\"$SI\"," "$WORK/m5.txt" || no "P6: $SI had no pgvigil_sessions before the delete (nothing to see go)"
Q "DELETE FROM pgvigil.activity_summary a USING pgvigil.instances i WHERE i.instance_id = a.instance_id AND i.name = '$SI' AND a.snapshot_at > now() - interval '15 minutes'" >/dev/null
sleep 11; curl -s -H "$(h "$TOK")" -o /dev/null "$B/metrics"; sleep 3
curl -s -H "$(h "$TOK")" -o "$WORK/m6.txt" "$B/metrics"
TS=$(grep "^pgvigil_sample_timestamp_seconds{server=\"$SI\",family=\"sessions\"} " "$WORK/m6.txt" | awk '{print $2}')
grep -q "^pgvigil_sessions{server=\"$SI\"," "$WORK/m6.txt" && no "P6: $SI's stale pgvigil_sessions is still there"
[[ -n "$TS" ]] && python3 -I -c "import sys,time; sys.exit(0 if time.time() - float('$TS') > 600 else 1)" || no "P6: $SI's sessions timestamp '$TS'"
[[ $bad -eq $b0 ]] && ok "P6 stale: $SI's pgvigil_sessions left out, its sessions timestamp $TS (> 600 s old)"
kill $MAIN; wait $MAIN 2>/dev/null

echo "== P7 Prometheus scrapes a TLS listen; P10 rotation"; b0=$bad
IP=$(hostname -I | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); [[ -n "$IP" ]] || fail "no non-loopback address"
"$BIN" cert -hosts "$IP" -out "$WORK" >/dev/null 2>&1 || fail "pgvigil cert"
start "$WORK/tls.log" "https://$IP:$PORT2" -config "$WORK/on.yaml" -dsn env:UI_DSN -listen "$IP:$PORT2" -tls-cert "$WORK/pgvigil.crt" -tls-key "$WORK/pgvigil.key" || fail "the TLS serve: $(tail -3 "$WORK/tls.log")"
TLS=$SPID
printf '%s' "$TOK" > "$WORK/prom.token"
cat > "$WORK/prom.yml" <<EOF
global: {scrape_interval: 5s, scrape_timeout: 4s}
scrape_configs:
  - job_name: pgvigil
    scheme: https
    authorization: {type: Bearer, credentials_file: $WORK/prom.token}
    tls_config: {ca_file: $WORK/pgvigil.crt}
    static_configs: [{targets: ['$IP:$PORT2']}]
EOF
"$PROM/prometheus" --config.file="$WORK/prom.yml" --storage.tsdb.path="$WORK/tsdb" --web.listen-address="127.0.0.1:$PPORT" > "$WORK/prom.log" 2>&1 & PIDS+=($!)
pq() { curl -s --data-urlencode "query=$1" "http://127.0.0.1:$PPORT/api/v1/query" | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(len(r), r[0]["value"][1] if r else "")'; }
sleep 25
UP=$(pq 'up{job="pgvigil"}'); NI=$(pq 'count(pgvigil_instance_info)'); NA=$(Q "SELECT count(*) FROM pgvigil.instances WHERE is_active")
[[ ${UP#* } == 1 ]] || no "P7: up = '$UP' ($(tail -2 "$WORK/prom.log"))"
[[ ${NI#* } == "$NA" ]] || no "P7: pgvigil_instance_info series '$NI', active instances $NA"
curl -sk --compressed -H "$(h "$TOK")" -D "$WORK/hdr7" -o /dev/null "https://$IP:$PORT2/metrics"; grep -qi '^content-encoding: gzip' "$WORK/hdr7" || no "P7: no gzip over TLS"
GONE=$(Q "UPDATE pgvigil.instances SET is_active = false WHERE name = (SELECT name FROM pgvigil.instances WHERE is_active AND name LIKE 'demo-%' ORDER BY name DESC LIMIT 1) RETURNING name")
sleep 20
[[ $(pq "pgvigil_instance_info{server=\"$GONE\"}") == "0 " ]] || no "P7: $GONE still scraped after it was set inactive"
# P10: the server's token file first, Prometheus' credentials_file 3 s later
NEWTOK=$(head -c 40 /dev/urandom | base64 | tr -dc 'A-Za-z0-9'); NEWTOK=${NEWTOK}0123456789abcdefghijklmnopqrstuvwxyz; NEWTOK=${NEWTOK:0:44}
printf '%s\n' "$NEWTOK" > "$WORK/token"; sleep 1.2
[[ $(code -H "$(h "$TOK")" "https://$IP:$PORT2/metrics") == 200 ]] || no "P10: the old token refused right after the rewrite"
sleep 2; printf '%s' "$NEWTOK" > "$WORK/prom.token"
sleep 60
MIN=$(pq 'min_over_time(up{job="pgvigil"}[90s])')
[[ ${MIN#* } == 1 ]] || no "P10: min_over_time(up[90s]) '$MIN' after the rotation"
[[ $(code -H "$(h "$NEWTOK")" "https://$IP:$PORT2/metrics") == 200 ]] || no "P10: the new token"
[[ $bad -eq $b0 ]] && ok "P7 scrape: Prometheus $PROMV over TLS at $IP:$PORT2, up 1, $NA instance_info series, gzip, $GONE gone when set inactive; P10 rotate: the old token 200 after the rewrite, min_over_time(up[90s]) 1, the new token 200"
kill $TLS 2>/dev/null

echo "== P8 scale"; b0=$bad
# P8 starts only under a 5-minute load below PROM_LOAD_MAX (8), waited for PROM_LOAD_WAIT s (300): on a loaded box the
# seed of 1,000 instances outlasts the demo's 30-minute catch-up (2170 s at a load of 25) and the render reads stale
# data; the demo takes whole days only (-days 1 at least), so a shorter seed is not at hand
load5() { cut -d' ' -f2 /proc/loadavg; }
P8GO=1; w0=$(date +%s)
if [[ ${PROM_SCALE:-1000} -gt 0 ]]; then
  until awk -v l="$(load5)" -v m="${PROM_LOAD_MAX:-8}" 'BEGIN { exit !(l + 0 < m + 0) }'; do
    (( $(date +%s) - w0 >= ${PROM_LOAD_WAIT:-300} )) && { P8GO=0; break; }; sleep 15
  done
fi
if [[ ${PROM_SCALE:-1000} -gt 0 && $P8GO == 0 ]]; then
  echo "NOT PROVEN P8: the box's 5-minute load stayed at ${PROM_LOAD_MAX:-8} or more for ${PROM_LOAD_WAIT:-300} s (now $(load5)): the seed of ${PROM_SCALE:-1000} instances is not started on a loaded box"
elif [[ ${PROM_SCALE:-1000} -gt 0 ]]; then
  echo "P8 starts at a 5-minute load of $(load5) (waited $(( $(date +%s) - w0 )) s)"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB8" >/dev/null || fail "create $DB8"
  t0=$(date +%s); "$BIN" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB8" -days 1 -instances "${PROM_SCALE:-1000}" -workers 16 > "$WORK/demo8.log" 2>&1 || { tail -3 "$WORK/demo8.log"; fail "the scale seed"; }
  echo "seeded ${PROM_SCALE:-1000} instances in $(( $(date +%s) - t0 )) s"
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "grant connect on database $DB8 to pgv_prom_ui_$SFX" >/dev/null 2>&1
  export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB8"; export UI_DSN="${UI_DSN/dbname=$DB/dbname=$DB8}"
  printf '%s\n' "$TOK" > "$WORK/token"
  "$BIN" migrate -config "$WORK/on.yaml" >/dev/null 2>&1
  start "$WORK/s8.log" "http://127.0.0.1:$PORT" -config "$WORK/on.yaml" -dsn env:UI_DSN -listen "127.0.0.1:$PORT" || fail "the scale serve: $(tail -3 "$WORK/s8.log")"
  S8=$SPID
  AGE=$(psql "$PGVIGIL_ADMIN_DSN dbname=$DB8" -XAtq -c "select coalesce(extract(epoch from now() - max(snapshot_at))::int, 99999) from pgvigil.activity_summary")
  [[ ${AGE:-99999} -le 600 ]] || echo "NOT PROVEN P8: the seeded data's newest read is ${AGE} s old (the seed ran past its catch-up): the render had nothing fresh to read"
  t1=$(date +%s.%N); curl -s -H "$(h "$TOK")" -H 'X-Prometheus-Scrape-Timeout-Seconds: 60' -o "$WORK/m8.txt" "$B/metrics"; t2=$(date +%s.%N)
  RS=$(awk '/^pgvigil_metrics_render_seconds /{print $2}' "$WORK/m8.txt"); SER=$(awk '/^pgvigil_metrics_series /{print $2}' "$WORK/m8.txt")
  python3 -I -c "import sys; sys.exit(0 if float('${RS:-99}') < 10 else 1)" || no "P8: the cold render took ${RS:-?} s (want under 10)"
  [[ ${AGE:-99999} -gt 600 || ${SER%.*} -ge $(( 20 * ${PROM_SCALE:-1000} )) ]] 2>/dev/null || no "P8: $SER series for ${PROM_SCALE:-1000} instances (want 20 per instance at least)"
  sleep 11
  # the eight scrapes' own pids waited for, never a bare 'wait': Prometheus (P7) and the scale serve are children
  # of this shell too and never exit by themselves, so a bare 'wait' here never returned (rp1, 2026-11-15)
  CP=(); for i in $(seq 1 8); do curl -s -m 90 -H "$(h "$TOK")" -H 'X-Prometheus-Scrape-Timeout-Seconds: 60' -o "$WORK/c$i.txt" "$B/metrics" & CP+=($!); done; wait "${CP[@]}"
  NR=$(cat "$WORK"/c*.txt | awk '/^pgvigil_metrics_last_render_timestamp_seconds /{print $2}' | sort -u | wc -l)
  NB=$(grep -l '^pgvigil_metrics_last_render_timestamp_seconds ' "$WORK"/c*.txt | wc -l)
  [[ $NB == 8 ]] || no "P8: $NB of the 8 concurrent scrapes got a body"
  [[ $NR == 1 ]] || no "P8: 8 concurrent scrapes saw $NR render(s)"
  [[ $bad -eq $b0 ]] && ok "P8 scale: ${PROM_SCALE:-1000} instances, the cold render $RS s (the first reply $(python3 -I -c "print(round($t2 - $t1, 2))") s), $SER series, $(wc -c < "$WORK/m8.txt") bytes, 8 concurrent scrapes after expiry: $NR render"
  kill $S8 2>/dev/null
else echo "NOT PROVEN P8: PROM_SCALE=0"; fi

echo "NOT PROVEN: SQL Server's figures on a live instance (the demo's SQL Server rows are generated); Prometheus 2.x; remote_write; 50 databases per instance with metrics.databases on (P8 seeds the demo's few)"
echo "proof-prometheus: $bad failed row(s)"
[[ $bad -eq 0 ]]
