#!/usr/bin/env bash
# Proof of the PostgreSQL best-practice grid (migration 0099, /api/pgconfig 'rules', the Configuration page): a demo
# fleet is seeded into a throwaway database and served on loopback; the checks read the store with psql and the API
# with curl. Needs go, psql, curl, python3, the web bundle built (`cd web && npm run build`) and a PostgreSQL for the
# throwaway database:
#   PGVIGIL_ADMIN_DSN   keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 240)
# Expected:
#   same      pgvigil.findings holds exactly the rows the view of 0088 yields on the same store (0099 re-creates it on
#             top of pgvigil.setting_rules): more than 0 rows, 0 rows only in the old, 0 rows only in the new
#   rules     pgvigil.setting_rules: 44 rows per PostgreSQL instance that has an instance read (35 rules: 31 name one
#             setting, four name several - 2, 2, 2 and 7; every named setting has a value, set or default; the count
#             is the rule SQL's own, run over one instance with all 41 settings: 29 + 15 rows);
#             no row with hit and not applies (a rule's own condition names its platform)
#   grid      pgvigil.pg_setting_rules(instance): one row per rule-covered setting, 41 per instance (44 rule rows
#             over 41 settings: autovacuum_freeze_max_age and the two max_standby delays carry two rules each),
#             every status one of crit / warn / ok / none; the settings with status crit or warn
#             are exactly the settings of the instance's setting findings (sources pg_gather, pg-collector)
#   fleet     over the demo fleet at least one setting is ok and at least one is warn or crit (both colours are drawn)
#   flip      an instance whose autovacuum row is ok, inside one transaction that is rolled back (the demo's own tick
#             cannot interleave and nothing is left behind): with autovacuum off written into its instance read the row
#             turns crit with severity critical and pgvigil.findings gains its row; after the rollback the row is ok
#             again and the finding is gone
#   pg13      the same transaction with the instance read as PostgreSQL 13: default_toast_compression and
#             idle_session_timeout (both arrived in 14) are 'none', never green; the grid still has 41 rows
#   api       GET /api/pgconfig?instance=<id> answers 200 with a 'rules' table whose columns hold setting, value,
#             suggested, status, severity, detail, platforms and whose row count equals the grid's
#   bundle    internal/web/dist/app.js carries the grid's heading 'Best practice' and its verdict words
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_bestp_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); SRV=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>"$WORK/drop.err" || echo "cleanup: the database $DB was NOT dropped: $(tr '\n' ' ' < "$WORK/drop.err")" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go psql curl python3; do command -v $t >/dev/null || fail "$t is not on this machine"; done
q() { psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "== bundle"
grep -q 'Best practice' internal/web/dist/app.js || fail "the web bundle has no 'Best practice' heading: run 'npm run build' in web/"
grep -q 'meets the rule' internal/web/dist/app.js || fail "the web bundle has no verdict words"
ok "the bundle carries the grid's heading and its verdict words"

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do
  grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break
  kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }
  sleep 1
done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s"; }

echo "== same: pgvigil.findings against the view of 0088"
OLD=internal/repo/sql/0088_parity4_join_qs.sql
[[ "$(sed -n 13p $OLD)" == "CREATE OR REPLACE VIEW pgvigil.findings AS" ]] || fail "0088's findings view is not at line 13"
[[ "$(sed -n 187p $OLD)" == " ORDER BY x.instance_id, x.setting, x.value, x.detail;" ]] || fail "0088's findings view does not end at line 187"
{ echo "CREATE TEMP VIEW old_findings AS"; sed -n 14,187p $OLD
  echo "SELECT (SELECT count(*) FROM pgvigil.findings) || ' ' ||"
  echo "       (SELECT count(*) FROM (SELECT * FROM old_findings EXCEPT SELECT * FROM pgvigil.findings) a) || ' ' ||"
  echo "       (SELECT count(*) FROM (SELECT * FROM pgvigil.findings EXCEPT SELECT * FROM old_findings) b);"; } > "$WORK/same.sql"
read -r NEWN ONLYOLD ONLYNEW < <(psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -v ON_ERROR_STOP=1 -f "$WORK/same.sql" | tail -1)
[[ "$NEWN" -gt 0 && "$ONLYOLD" == 0 && "$ONLYNEW" == 0 ]] || fail "findings differ from 0088's view: $NEWN rows, $ONLYOLD only in the old, $ONLYNEW only in the new"
ok "pgvigil.findings: $NEWN rows, the same as 0088's view (0 only in the old, 0 only in the new)"

echo "== rules"
BAD=$(q "SELECT count(*) FROM (SELECT instance_id FROM pgvigil.setting_rules GROUP BY 1 HAVING count(*) <> 44) x")
INST=$(q "SELECT count(DISTINCT instance_id) FROM pgvigil.setting_rules")
[[ "$INST" -gt 0 && "$BAD" == 0 ]] || fail "setting_rules: $INST instances, $BAD of them without 44 rule rows"
HN=$(q "SELECT count(*) FROM pgvigil.setting_rules WHERE hit AND NOT applies")
[[ "$HN" == 0 ]] || fail "setting_rules: $HN rows hit on a platform the rule is not for"
ok "setting_rules: 44 rule rows on each of $INST instances, none hit outside its platform"

echo "== grid"
G=$(q "WITH i AS (SELECT DISTINCT instance_id FROM pgvigil.setting_rules),
            g AS (SELECT i.instance_id, r.* FROM i, pgvigil.pg_setting_rules(i.instance_id) r),
            want AS (SELECT instance_id, count(DISTINCT setting) n FROM pgvigil.setting_rules GROUP BY 1),
            got AS (SELECT instance_id, count(*) n, count(DISTINCT setting) d FROM g GROUP BY 1)
       SELECT (SELECT count(*) FROM want w LEFT JOIN got o USING (instance_id) WHERE o.n IS NULL OR w.n <> o.n OR o.n <> o.d OR o.n <> 41) || ' ' ||
              (SELECT count(*) FROM g WHERE status NOT IN ('crit', 'warn', 'ok', 'none')) || ' ' ||
              (SELECT count(*) FROM (
                 (SELECT instance_id, setting FROM g WHERE status IN ('crit', 'warn')
                  EXCEPT SELECT instance_id, setting FROM pgvigil.findings WHERE source IN ('pg_gather', 'pg-collector'))
                 UNION ALL
                 (SELECT f.instance_id, f.setting FROM pgvigil.findings f
                   WHERE f.source IN ('pg_gather', 'pg-collector') AND EXISTS (SELECT 1 FROM pgvigil.setting_rules s WHERE s.instance_id = f.instance_id AND s.setting = f.setting)
                  EXCEPT SELECT instance_id, setting FROM g WHERE status IN ('crit', 'warn'))) d) || ' ' ||
              (SELECT count(*) FROM g WHERE status = 'ok') || ' ' || (SELECT count(*) FROM g WHERE status IN ('crit', 'warn')) || ' ' || (SELECT count(*) FROM g)")
read -r GBAD GSTAT GDIFF GOK GDEV GALL <<< "$G"
[[ "$GBAD" == 0 ]] || fail "pg_setting_rules: $GBAD instances without one row per rule-covered setting (41)"
[[ "$GSTAT" == 0 ]] || fail "pg_setting_rules: $GSTAT rows with an unknown status"
[[ "$GDIFF" == 0 ]] || fail "pg_setting_rules: $GDIFF settings where the grid's crit / warn and the setting findings disagree"
ok "grid: one row per rule-covered setting on every instance ($GALL rows), every status known, crit / warn = the setting findings"
[[ "$GOK" -gt 0 && "$GDEV" -gt 0 ]] || fail "fleet: $GOK ok and $GDEV deviating settings: both colours must be drawn"
ok "fleet: $GOK settings meet their rule, $GDEV deviate"

echo "== flip and pg13 (one transaction, rolled back)"
ID=$(q "SELECT i.instance_id FROM (SELECT DISTINCT instance_id FROM pgvigil.setting_rules) i, pgvigil.pg_setting_rules(i.instance_id) r WHERE r.setting = 'autovacuum' AND r.status = 'ok' ORDER BY 1 LIMIT 1")
[[ -n "$ID" ]] || fail "no instance with autovacuum ok in the demo"
AV="SELECT status || ' ' || coalesce(severity, '-') || ' ' || (SELECT count(*) FROM pgvigil.findings WHERE instance_id = $ID AND setting = 'autovacuum') FROM pgvigil.pg_setting_rules($ID) WHERE setting = 'autovacuum'"
cat > "$WORK/flip.sql" <<SQL
BEGIN;
UPDATE pgvigil.instance_state SET non_default_settings = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(non_default_settings) = 'array' THEN non_default_settings ELSE '[]'::jsonb END) e WHERE e->>'name' <> 'autovacuum') || '[{"name": "autovacuum", "value": "off"}]'::jsonb WHERE instance_id = $ID;
SELECT 'flip ' || x FROM ($AV) t(x);
UPDATE pgvigil.instance_state SET server_version_num = 130012 WHERE instance_id = $ID;
SELECT 'pg13 ' || string_agg(setting || '=' || status, ' ' ORDER BY setting) FROM pgvigil.pg_setting_rules($ID) WHERE setting IN ('default_toast_compression', 'idle_session_timeout');
SELECT 'pg13n ' || count(*) FROM pgvigil.pg_setting_rules($ID);
ROLLBACK;
SELECT 'after ' || x FROM ($AV) t(x);
SQL
OUT=$(psql "$PGVIGIL_ADMIN_DSN dbname=$DB" -XAtq -v ON_ERROR_STOP=1 -f "$WORK/flip.sql")
grep -qx 'flip crit critical 1' <<< "$OUT" || fail "flip: autovacuum off on instance $ID gives '$(grep '^flip ' <<< "$OUT")', expected 'flip crit critical 1'"
grep -qx 'after ok - 0' <<< "$OUT" || fail "flip: after the rollback instance $ID gives '$(grep '^after ' <<< "$OUT")', expected 'after ok - 0'"
ok "flip: instance $ID autovacuum off -> crit critical with its finding; rolled back -> ok, the finding gone"
grep -qx 'pg13 default_toast_compression=none idle_session_timeout=none' <<< "$OUT" || fail "pg13: '$(grep '^pg13 ' <<< "$OUT")', expected both settings none"
grep -qx 'pg13n 41' <<< "$OUT" || fail "pg13: '$(grep '^pg13n ' <<< "$OUT")', expected 41 grid rows"
ok "pg13: read as PostgreSQL 13 the two settings that arrived in 14 are 'none'; the grid keeps 41 rows"

echo "== api"
N=$(q "SELECT count(*) FROM pgvigil.pg_setting_rules($ID)")
curl -fsS "http://127.0.0.1:$PORT/api/pgconfig?instance=$ID" > "$WORK/api.json" || fail "GET /api/pgconfig?instance=$ID failed"
python3 - "$WORK/api.json" "$N" <<'PY' || fail "the api's rules table is not as expected"
import json, sys
d = json.load(open(sys.argv[1])); r = d.get('rules')
assert r, 'no rules table'
need = {'setting', 'value', 'suggested', 'status', 'severity', 'detail', 'platforms'}
assert need <= set(r['columns']), 'columns missing: %s' % (need - set(r['columns']))
assert len(r['rows']) == int(sys.argv[2]), 'rows %d, the grid has %s' % (len(r['rows']), sys.argv[2])
assert d.get('settings'), 'the settings table is gone'
PY
ok "api: /api/pgconfig?instance=$ID carries the rules table, $N rows, beside the settings"
echo "proof-pg-bestpractice: OK"
