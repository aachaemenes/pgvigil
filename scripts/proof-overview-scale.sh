#!/usr/bin/env bash
# Proof of the overview's 24 h deadlock and checksum check: correctness cases imported through
# pgvigil.import_dbstats (so the restart epoch is set as in production) and a bulk load for time.
# The check's SQL is read from internal/web/queries.go, so the proof follows the code.
#   PGVIGIL_ADMIN_DSN  a superuser connection (creates and drops a scratch database)
#   SCALE_N, SCALE_D   bulk instances x databases, one day at 1 minute (default 20 x 20; 100 x 40 = 5.76 M rows)
#   BUDGET_MS          the check's time limit, cold first call (default 5000; serve cuts a check at 15 s)
# Cases (1,440 one-minute imports each, stats_reset NULL unless named):
#   crash     deadlocks 100->105, then restart 0->3; one old checksum failure that the restart clears -> 8 deadlocks, warning
#   failover  deadlocks 5000->5002, then the former replica 2->3                                      -> 3 deadlocks, warning
#   reset     stats_reset moves mid-day: deadlocks 0->1, then 0->7                                    -> 8 deadlocks, warning
#   checksum  checksum_failures 0->2 in the last 10 minutes, deadlocks steady                         -> critical, 2 failures, 0 deadlocks
#   quiet     nothing changes                                                                          -> no row
# Expected: exactly those 4 case rows, every bulk database 2 deadlocks (N*D rows), under the budget.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
N=${SCALE_N:-20}; D=${SCALE_D:-20}; BUDGET=${BUDGET_MS:-5000}
DB="pgvigil_it_scale_$RANDOM"; CFG=$(mktemp); CREATED=""
cleanup() {
  rm -f "$CFG"
  [[ -n "$CREATED" ]] && psql "$PGVIGIL_ADMIN_DSN" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$PGVIGIL_ADMIN_DSN" -XAtq -c "create database $DB"; CREATED=1
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: scale\n    dsn: "dbname=none"\n' > "$CFG"
"$BIN" migrate -config "$CFG" >/dev/null 2>&1 || fail "migrate"
P() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
P -c "insert into pgvigil.instances(name, platform) values ('case', 'postgres')"
P -c "insert into pgvigil.instances(name, platform) select 'bulk'||g, 'postgres' from generate_series(1,$N) g"
C=$(P -c "select instance_id from pgvigil.instances where name = 'case'")
# the cases, one import per minute, oldest first; m = minutes ago (1439 .. 0)
P -c "do \$\$ declare m int; t timestamptz; b timestamptz := date_trunc('minute', now()); begin
  for m in reverse 1439..0 loop
    t := b - make_interval(mins => m);
    perform pgvigil.import_dbstats($C, t, jsonb_build_array(
      jsonb_build_object('kind','db','dbid',1,'datname','crash','xact_commit', case when m >= 700 then 100000 - m else 1440 - m end,
        'deadlocks', case when m >= 700 then 100 + (1439 - m) / 147 else (699 - m) / 233 end,
        'checksum_failures', case when m >= 700 then 1 else 0 end),
      jsonb_build_object('kind','db','dbid',2,'datname','failover','xact_commit', case when m >= 700 then 900000 - m else 5000 - m end,
        'deadlocks', case when m >= 700 then 5000 + (1439 - m) / 369 else 2 + (699 - m) / 699 end, 'checksum_failures', 0),
      jsonb_build_object('kind','db','dbid',3,'datname','reset','xact_commit', 100000 - m,
        'stats_reset', case when m >= 700 then '2026-01-01T00:00:00Z' else '2026-06-01T00:00:00Z' end,
        'deadlocks', case when m >= 700 then (1439 - m) / 739 else (699 - m) / 99 end, 'checksum_failures', 0),
      jsonb_build_object('kind','db','dbid',4,'datname','checksum','xact_commit', 100000 - m, 'deadlocks', 9,
        'checksum_failures', case when m < 10 then 2 else 0 end),
      jsonb_build_object('kind','db','dbid',5,'datname','quiet','xact_commit', 100000, 'deadlocks', 4, 'checksum_failures', 0)));
  end loop; end \$\$"
EP=$(P -c "select string_agg(datname || '=' || n, ' ' order by datname) from (select datname, count(distinct epoch) n from pgvigil.dbstats where instance_id = $C group by datname) x")
[[ "$EP" == "checksum=1 crash=2 failover=2 quiet=1 reset=2" ]] || fail "epochs: $EP"
# bulk load for time (epoch 0, every series rising)
P -c "select pgvigil.ensure_month_partition('dbstats', now() - interval '1 day'), pgvigil.ensure_month_partition('dbstats', now())" >/dev/null
P -c "insert into pgvigil.dbstats(instance_id, snapshot_at, dbid, datname, xact_commit, deadlocks, checksum_failures, epoch)
      select i.instance_id, date_trunc('minute', now()) - make_interval(mins => m), d, 'db'||d, (1440-m)*100, (1440-m)/500, 0, 0
        from pgvigil.instances i, generate_series(1,$D) d, generate_series(0,1439) m where i.name like 'bulk%'"
P -c "analyze pgvigil.dbstats"
Q=$(awk '/"deadlocks and checksums", `/{f=1;next} f&&/`},/{sub(/`},.*/,""); print; f=0; next} f' internal/web/queries.go)
grep -q "WHERE dl > 0 OR ck > 0" <<<"$Q" || fail "check SQL not extracted whole from queries.go"
TOUT=$(P -c "\timing on" -c "$Q")
MS=$(sed -n 's/^Time: \([0-9]*\)\..*/\1/p' <<<"$TOUT"); OUT=$(grep -v '^Time: ' <<<"$TOUT")
[[ "$MS" =~ ^[0-9]+$ ]] || fail "no timing line"
CASES=$(grep "^$C|" <<<"$OUT" | cut -d'|' -f2-4,6 | sort | tr '\n' ';')
WANT="critical|checksum failures (24 h)|checksum|2 checksum failure(s); 0 deadlock(s);warning|deadlocks (24 h)|crash|8 deadlock(s);warning|deadlocks (24 h)|failover|3 deadlock(s);warning|deadlocks (24 h)|reset|8 deadlock(s);"
[[ "$CASES" == "$WANT" ]] || fail "cases: $CASES"
BULK=$(grep -vc "^$C|" <<<"$OUT" || true); BAD=$(grep -v "^$C|" <<<"$OUT" | grep -vc "^[0-9]*|warning|deadlocks (24 h)|db[0-9]*|.*|2 deadlock(s)$" || true)
[[ "$BULK" -eq $((N*D)) && "$BAD" -eq 0 ]] || fail "bulk rows $BULK (expected $((N*D))), $BAD not 2 deadlocks"
[[ "$MS" -le "$BUDGET" ]] || fail "check took $MS ms, budget $BUDGET ms"
echo "OK: overview deadlock check, 4 cases right, $((N*D*1440)) bulk rows, $BULK bulk result rows, $MS ms cold (budget $BUDGET ms)"
