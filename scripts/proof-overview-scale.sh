#!/usr/bin/env bash
# Proof of the overview's 24 h deadlock and checksum check at scale: a scratch repository with
# N instances x D databases x one day at a 1-minute cadence, one stats reset in the middle of the
# day (instance 1, db1) and one checksum failure (instance 2, db3). The check's SQL is read from
# internal/web/queries.go, so the proof follows the code.
#   PGVIGIL_ADMIN_DSN  a superuser connection (creates and drops the scratch database)
#   SCALE_N, SCALE_D   instances and databases (default 20 x 20; 100 x 40 is the 5.76 M-row case)
#   BUDGET_MS          the check's time limit (default 5000; serve cuts the whole check at 15 s)
# Expected: N*D result rows; db1 of instance 1 = 8 deadlocks (1 before the reset, 7 after);
# every other database = 2; instance 2 db3 critical with 2 checksum failures; under the budget.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
N=${SCALE_N:-20}; D=${SCALE_D:-20}; BUDGET=${BUDGET_MS:-5000}
DB="pgvigil_it_scale_$RANDOM"; CFG=$(mktemp)
cleanup() { rm -f "$CFG"; psql "$PGVIGIL_ADMIN_DSN" -XAtq -c "drop database if exists $DB" >/dev/null 2>&1 || true; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$PGVIGIL_ADMIN_DSN" -XAtq -c "create database $DB"
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: scale\n    dsn: "dbname=none"\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || fail "migrate"
P() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
P -c "insert into pgvigil.instances(name, platform) select 'scale'||g, 'postgres' from generate_series(1,$N) g"
P -c "select pgvigil.ensure_month_partition('dbstats', now() - interval '1 day'), pgvigil.ensure_month_partition('dbstats', now())" >/dev/null
P -c "insert into pgvigil.dbstats(instance_id, snapshot_at, dbid, datname, stats_reset, xact_commit, deadlocks, checksum_failures)
      select i.instance_id, date_trunc('minute', now()) - make_interval(mins => m), d, 'db'||d,
             case when i.name='scale1' and d=1 and m < 700 then now() - interval '700 minutes' else now() - interval '30 days' end,
             (1440-m)*100,
             case when i.name='scale1' and d=1 and m < 700 then (700-m)/100 else (1440-m)/500 end,
             case when i.name='scale2' and d=3 and m < 10 then 2 else 0 end
        from pgvigil.instances i, generate_series(1,$D) d, generate_series(0,1439) m"
P -c "analyze pgvigil.dbstats"
Q=$(awk '/"deadlocks and checksums", `/{f=1;next} f&&/`},/{f=0} f' internal/web/queries.go)
[[ -n "$Q" ]] || fail "check SQL not found in queries.go"
OUT=$(P -c "$Q")
MS=$(P -c "\timing on" -c "$Q" | sed -n 's/^Time: \([0-9]*\)\..*/\1/p')
ROWS=$(wc -l <<<"$OUT")
[[ "$ROWS" -eq $((N*D)) ]] || fail "rows $ROWS, expected $((N*D))"
R1=$(P -c "select instance_id from pgvigil.instances where name='scale1'"); R2=$(P -c "select instance_id from pgvigil.instances where name='scale2'")
grep -q "^$R1|warning|deadlocks (24 h)|db1|.*|8 deadlock(s)$" <<<"$OUT" || fail "reset epoch sum wrong: $(grep "^$R1|.*|db1|" <<<"$OUT")"
grep -q "^$R2|critical|checksum failures (24 h)|db3|.*|2 checksum failure(s); 2 deadlock(s)$" <<<"$OUT" || fail "checksum row wrong"
OTHER=$(grep -v "^$R1|warning|deadlocks (24 h)|db1|" <<<"$OUT" | grep -v "^$R2|critical|" | grep -vc "|2 deadlock(s)$" || true)
[[ "$OTHER" -eq 0 ]] || fail "$OTHER rows not 2 deadlocks"
[[ "$MS" -le "$BUDGET" ]] || fail "check took $MS ms, budget $BUDGET ms"
echo "OK: overview deadlock check $((N*D*1440)) rows, $ROWS result rows, $MS ms (budget $BUDGET ms)"
