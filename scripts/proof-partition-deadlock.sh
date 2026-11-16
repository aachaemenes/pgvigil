#!/usr/bin/env bash
# Proof of the import deadlock at a new month's partition, and of its fix (partitions made ahead, each in its own short
# transaction, by pgvigil.import_partition_make; repo.Import's retry of an import ended by SQLSTATE 40P01, up to three
# tries, from rel-j15dl). It runs on a throwaway
# repository database and reads the server's own log for 'deadlock detected'.
#
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a SUPERUSER (the proof creates pgvigil_proof_pd_<n>, an
#                      event trigger and a login there, reads the server log with pg_read_file, drops all at the end);
#                      the cluster runs with logging_collector = on and deadlock_timeout = 1s (the default)
#   PGVIGIL_BIN        the pgvigil binary (default bin/pgvigil)
#   PD_SEEDS           demo seeds over a month boundary for R8 (default 1)
#
# Before any row: R10's read - the relation locks a partition make holds while its transaction is open, for a parent
# with a foreign key to pgvigil.instances (pi_load) and one without (activity_sample), printed as 'read:' lines.
# Rows (each 'ok' or 'FAIL'; the script goes on after a FAIL and exits 1 when any row failed):
#  R10a the make of pi_load's partition locks no pgvigil relation but pi_load, its own partitioned indexes (ShareUpdate-
#       Exclusive or weaker), the new relations, pgvigil.instances in ShareRowExclusive or weaker and instances' indexes
#       in AccessShare (a contradiction of the 450 ms rule otherwise: STOP and ask)
#  R1   two imports of import_activity sharing query_hash 4242 - B (this month's last minute) upserts the hash in an
#       open transaction, A imports the next month's first second, B imports once A waits plus 1.5 s - both commit
#       and the server log holds no 'deadlock detected' since R1 began; B saw A wait before its own import
#  R2   no partition was made inside an import_<collection> call (an event trigger records every partition made, with
#       the statement that made it) during R1
#  R3   right after migrate every partitioned parent of schema pgvigil has its current and next month (mssql_requests:
#       today and the next two days); each ahead-made partition's index definitions equal those of a partition the
#       parent's own maker makes for a month three months back
#  R4   the maker pgvigil.partition_parents() names for each parent equals the maker the migrations call for it (the
#       static map: literal table names, and the VALUES lists of the event imports)
#  R5   with an open transaction holding ROW EXCLUSIVE on activity_sample, import_partition_make of a missing month
#       answers 'busy' in 0.4 to 1.0 s; an insert into activity_sample started meanwhile ends within 1.0 s; after the
#       holder commits the make answers 'made'
#  R6   (the SQL part) a beat whose run carries retries 1 stores collector_runs.retries 1
#  R7   pgvigil run (no instances) puts back next month's activity_sample partition, dropped before it starts, in its
#       first pass, and logs 'partitions ahead'
#  R8   PD_SEEDS demo seeds of (today's UTC day + 5) days, so they cross the first of this month on any day: each
#       ends rc 0, no 'deadlock detected' in
#       the log since R8 began, and no partition made inside an import_<collection> call
#  R10b with an open transaction holding ROW EXCLUSIVE on pgvigil.instances, the make of pi_load's missing month
#       answers 'busy' in under 1.0 s
#  R11  the delete of an instance (it holds instances, then cascades into pi_load) while a make of pi_load's missing
#       month waits: the delete commits, the make answers within 1.0 s, no 'deadlock detected' since R11 began
#  R12  as a login IN ROLE pgvigil_collector: import_partition_make refuses a table that is not a pgvigil parent, a NULL
#       time, a start more than 62 days ahead (22023 each) and an earlier month of alert_log (42501: 0059's door keeps
#       those the owner's); import_partitions_due refuses a span over 400 days (22023) and answers a lawful one; a make of
#       the month after next answers 'made' (dropped after), one of next month 'exists'
#  R14  a beat whose run has no retries key is stored, retries 0
# On a tree without the fix (no import_partition_make), R1, R2, R3, R4, R7 and R8's partition clause are expected to
# FAIL and R5, R6, R10b, R11, R12 and R14 FAIL as 'not on this tree': that is the red run.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?}"
SEEDS=${PD_SEEDS:-1}
SUF=$RANDOM
DB=pgvigil_proof_pd_$SUF; COL=pgvigil_pd_col_$SUF; PW=p$RANDOM$RANDOM
WORK=$(mktemp -d); CFG=$WORK/cfg.yaml; BG=()
NFAIL=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; NFAIL=$((NFAIL + 1)); }
cleanup() {
  for p in "${BG[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" -c "drop role if exists $COL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null || { echo "FAIL setup: create database"; exit 1; }
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
q()  { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
qq() { psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }
now_s() { date +%s.%N; }
since() { python3 -c "import sys; print(f'{float(sys.argv[2]) - float(sys.argv[1]):.2f}')" "$1" "$2"; }

# the server log, read through the server (pg_current_logfile is relative to its data folder)
LOGF=$(q "select coalesce(pg_current_logfile('stderr'), '')")
[[ -n "$LOGF" ]] || { echo "FAIL setup: the cluster runs without logging_collector (no server log to read)"; exit 1; }
[[ $(q "show deadlock_timeout") == 1s ]] || { echo "FAIL setup: deadlock_timeout is $(q 'show deadlock_timeout'), not 1s"; exit 1; }
# a mark is the log's size and the database's deadlock count (pg_stat_database.deadlocks: a log rotated mid-run still
# counts); a failed read answers ERR, which no row takes for 0 (the review's part P, 4)
dlstat() { q "select deadlocks from pg_stat_database where datname = current_database()"; }
logpos() { local s d; s=$(q "select (pg_stat_file('$LOGF')).size") && d=$(dlstat) || { echo ERR; return; }; echo "$s:$d"; }
logsince() { q "select pg_read_file('$LOGF', ${1%%:*}, (pg_stat_file('$LOGF')).size - ${1%%:*})"; }
deadlocks_since() {   # the larger of the log's 'deadlock detected' lines and the stats' count since the mark
  local t n m
  [[ $1 == *:* ]] || { echo ERR; return; }
  t=$(logsince "$1") || { echo ERR; return; }
  n=$(grep -c 'deadlock detected' <<<"$t")
  m=$(dlstat) || { echo ERR; return; }
  m=$((m - ${1##*:})); echo $((n > m ? n : m))
}

# the event trigger: every partition made, with the top-level statement that made it (a definer function of this login)
psql "$PGVIGIL_REPO_DSN" -XAtq -v ON_ERROR_STOP=1 >/dev/null <<'SQL' || { echo "FAIL setup: the event trigger"; exit 1; }
CREATE TABLE public.pd_ddl (at timestamptz NOT NULL DEFAULT clock_timestamp(), pid int NOT NULL DEFAULT pg_backend_pid(),
                            obj text NOT NULL, query text);
CREATE FUNCTION public.pd_ddl_rec() RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE command_tag = 'CREATE TABLE' LOOP
    IF EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = r.objid AND c.relispartition) THEN
      INSERT INTO public.pd_ddl (obj, query) VALUES (r.object_identity, left(current_query(), 300));
    END IF;
  END LOOP;
END $$;
CREATE EVENT TRIGGER pd_ddl ON ddl_command_end WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION public.pd_ddl_rec();
SQL
import_made_since() {   # partitions made inside an import_<collection> call since a time (the make door excluded); ERR on a failed read
  q "select coalesce(string_agg(obj || ' by ' || left(regexp_replace(query, '\s+', ' ', 'g'), 80), '; ' order by at), '')
       from public.pd_ddl where at >= '$1' and query ~* 'import_[a-z_]+\s*\(' and query !~* 'import_partition_make'" || echo "ERR: the read of public.pd_ddl failed"
}

printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances: []\n' > "$CFG"
"$BIN" migrate -config "$CFG" > "$WORK/migrate.out" 2>&1 || { echo "FAIL setup: migrate"; tail -5 "$WORK/migrate.out"; exit 1; }
HAVEFIX=$(q "select to_regprocedure('pgvigil.import_partition_make(text, timestamp with time zone)') is not null")
echo "tree: $([[ $HAVEFIX == t ]] && echo 'with import_partition_make' || echo 'WITHOUT the fix (the red run)'); $(grep -m1 -i 'applied\|migrat' "$WORK/migrate.out" | cut -c1-120)"
CUR=$(q "select to_char(date_trunc('month', now() at time zone 'utc'), 'YYYY-MM-DD') || ' 00:00:00+00'")
NEXT=$(q "select to_char(date_trunc('month', now() at time zone 'utc') + interval '1 month', 'YYYY-MM-DD') || ' 00:00:00+00'")
M2=$(q "select to_char(date_trunc('month', now() at time zone 'utc') + interval '2 months', 'YYYY-MM-DD') || ' 00:00:00+00'")
LAST=$(q "select to_char(date_trunc('month', now() at time zone 'utc') + interval '1 month' - interval '1 minute', 'YYYY-MM-DD HH24:MI:SS') || '+00'")
NEXTYM=$(q "select to_char('$NEXT'::timestamptz at time zone 'utc', 'YYYYMM')")
M2YM=$(q "select to_char('$M2'::timestamptz at time zone 'utc', 'YYYYMM')")
I1=$(q "select pgvigil.ensure_instance('pd-a-$SUF', 'onprem', '18.0', 180000, false, '{}'::text[])")
I2=$(q "select pgvigil.ensure_instance('pd-b-$SUF', 'onprem', '18.0', 180000, false, '{}'::text[])")
I3=$(q "select pgvigil.ensure_instance('pd-c-$SUF', 'aurora', '18.0', 180000, false, '{}'::text[])")
PAY='[{"kind":"session","pid":4242,"state":"active","query_hash":4242,"query":"select 4242"}]'
mk() { if [[ $HAVEFIX == t ]]; then q "select pgvigil.import_partition_make('$1', '$2')"; else echo "no-door"; fi; }

# ---------------- R10: the locks a partition make holds (both trees: the maker the imports call) ----------------
echo "== R10 the locks of an open partition make"
r10() {   # $1 parent, $2 month: the make in an open transaction, its relation locks read from another session
  local app=pd-x-$1 pid
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "set application_name = '$app'" -c "begin" \
    -c "select pgvigil.ensure_month_partition('$1', '$2')" -c "select pg_sleep(4)" -c "rollback" >/dev/null 2>&1 &
  pid=$!; BG+=("$pid")
  for _ in $(seq 1 40); do [[ $(q "select count(*) from pg_stat_activity where application_name = '$app' and query like '%pg_sleep%'") == 1 ]] && break; sleep 0.1; done
  q "select coalesce(n.nspname || '.', '') || coalesce(c.relname, l.relation::text) || ' ' || l.mode || case when l.granted then '' else ' (waiting)' end
       from pg_locks l join pg_stat_activity a on a.pid = l.pid left join pg_class c on c.oid = l.relation
       left join pg_namespace n on n.oid = c.relnamespace
      where a.application_name = '$app' and l.locktype = 'relation' order by 1" | sed "s/^/read: R10 $1: /"
  q "select coalesce(n.nspname || '.', '') || coalesce(c.relname, l.relation::text) || '|' || l.mode
       from pg_locks l join pg_stat_activity a on a.pid = l.pid left join pg_class c on c.oid = l.relation
       left join pg_namespace n on n.oid = c.relnamespace
      where a.application_name = '$app' and l.locktype = 'relation'" > "$WORK/r10-$1.txt"
  wait "$pid" 2>/dev/null
}
r10 pi_load "$M2"
r10 activity_sample "$M2"
# allowed beside pi_load and the new relations (unnamed oids to another session): the parent's own partitioned indexes in
# ShareUpdateExclusive or weaker (the new partition's index is attached to them), pgvigil.instances in ShareRowExclusive or
# weaker (the foreign key's triggers) and instances' indexes in AccessShare (the key read) - none conflicts with the ROW
# EXCLUSIVE of an import or a cascade (t-pd-r1: the first list missed the two index kinds; the rule is unchanged)
pidx=$(q "select string_agg('pgvigil.' || c.relname, ' ') from pg_index i join pg_class c on c.oid = i.indexrelid where i.indrelid = 'pgvigil.pi_load'::regclass")
iidx=$(q "select string_agg('pgvigil.' || c.relname, ' ') from pg_index i join pg_class c on c.oid = i.indexrelid where i.indrelid = 'pgvigil.instances'::regclass")
other=$(awk -F'|' -v pidx=" $pidx " -v iidx=" $iidx " '
  $1 !~ /^pgvigil\./ || $1 == "pgvigil.pi_load" { next }
  index(pidx, " " $1 " ") && ($2 == "ShareUpdateExclusiveLock" || $2 == "RowExclusiveLock" || $2 == "RowShareLock" || $2 == "AccessShareLock") { next }
  $1 == "pgvigil.instances" && ($2 == "ShareRowExclusiveLock" || $2 == "ShareLock" || $2 == "RowExclusiveLock" || $2 == "RowShareLock" || $2 == "AccessShareLock") { next }
  index(iidx, " " $1 " ") && $2 == "AccessShareLock" { next }
  { print $1 " " $2 }' "$WORK/r10-pi_load.txt" | tr '\n' ' ')
inst=$(awk -F'|' '$1 == "pgvigil.instances" {print $2}' "$WORK/r10-pi_load.txt" | sort -u | tr '\n' ' ')
if ! grep -qx 'pgvigil.pi_load|AccessExclusiveLock' "$WORK/r10-pi_load.txt"; then
  bad "R10a the read holds no AccessExclusiveLock on pgvigil.pi_load (an empty or failed read): $(head -c 200 "$WORK/r10-pi_load.txt" | tr '\n' ' ')"
elif [[ -z "$other" ]]; then
  ok "R10a the make of pi_load's partition locks pi_load and its own indexes, the new relations, and pgvigil.instances in ${inst:-no mode} (its indexes AccessShare) only"
else
  bad "R10a CONTRADICTION (stop and ask): the make of pi_load's partition also locks [${other}] / instances in [${inst}]"
fi

# ---------------- R1 / R2: the deadlock, deterministic ----------------
echo "== R1 two imports sharing a query_hash across the month boundary"
qq "select pgvigil.ensure_month_partition('activity_sample', '$CUR')"   # B's month exists, as in the incident (a no-op after the fix's migrate)
P1=$(logpos); T1=$(q "select clock_timestamp()")
qq "delete from pgvigil.query_text where query_hash = 4242"
psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 > "$WORK/r1-b.out" 2>&1 <<SQL &
SET application_name = 'pd-B';
BEGIN;
INSERT INTO pgvigil.query_text AS t (query_hash, first_seen, last_seen, query) VALUES (4242, '$LAST', '$LAST', 'select 4242')
  ON CONFLICT (query_hash) DO UPDATE SET last_seen = EXCLUDED.last_seen;
DO \$\$
DECLARE w boolean := false;
BEGIN
  FOR i IN 1..200 LOOP
    PERFORM pg_stat_clear_snapshot();
    w := EXISTS (SELECT 1 FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
                  WHERE a.application_name = 'pd-A' AND NOT l.granted);
    EXIT WHEN w;
    PERFORM pg_sleep(0.1);
  END LOOP;
  IF w THEN RAISE NOTICE 'pd: A waits'; END IF;
END \$\$;
SELECT pg_sleep(1.5);
SELECT pgvigil.import_activity($I2, '$LAST', '$PAY'::jsonb);
COMMIT;
SQL
PB=$!; BG+=("$PB")
for _ in $(seq 1 50); do [[ $(q "select count(*) from pg_stat_activity where application_name = 'pd-B' and query like 'DO%'") == 1 ]] && break; sleep 0.1; done
psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "set application_name = 'pd-A'" \
  -c "select pgvigil.import_activity($I1, '$NEXT', '$PAY'::jsonb)" > "$WORK/r1-a.out" 2>&1 &
PA=$!; BG+=("$PA")
wait "$PB"; RB=$?; wait "$PA"; RA=$?
D1=$(deadlocks_since "$P1")
AW=no; grep -q 'pd: A waits' "$WORK/r1-b.out" && AW=yes   # A waited on B's row before B's import (the cycle's first half)
if [[ $RA == 0 && $RB == 0 && $D1 == 0 && $AW == yes ]]; then
  ok "R1 A waited on B, both imports committed, 0 'deadlock detected'"
else
  bad "R1 A waited: $AW; A rc $RA, B rc $RB, 'deadlock detected' $D1 time(s); B: $(grep -m1 -E 'ERROR|FATAL' "$WORK/r1-b.out" | cut -c1-120); A: $(grep -m1 -E 'ERROR|FATAL' "$WORK/r1-a.out" | cut -c1-120)"
fi
if [[ $D1 -gt 0 ]]; then   # the lead's [inferred] relation: read while the database lives
  rel=$(logsince "$P1" | grep -m1 -oE 'waits for RowExclusiveLock on relation [0-9]+' | grep -oE '[0-9]+$')
  [[ -n "$rel" ]] && echo "read: R1 the logged RowExclusiveLock wait is on $(q "select coalesce(($rel)::oid::regclass::text, 'oid $rel')") (activity_sample's oid $(q "select 'pgvigil.activity_sample'::regclass::oid"))"
  logsince "$P1" | grep -A3 'deadlock detected' | head -6 | cut -c1-220 | sed 's/^/read: R1 log: /'
fi
made=$(import_made_since "$T1")
if [[ -z "$made" ]]; then ok "R2 no partition made inside an import call during R1"; else bad "R2 made inside an import: $made"; fi

# ---------------- R3 / R4: every parent ahead, by its own maker ----------------
echo "== R3 / R4 every partitioned parent"
python3 -I - internal/repo/sql > "$WORK/makers.txt" <<'PY'
import re, sys, glob, os
d = sys.argv[1]; m = {}
for f in sorted(glob.glob(os.path.join(d, '*.sql'))):
    s = re.sub(r'--[^\n]*', '', open(f).read())
    for fn, mk in (('ensure_month_partition', 'month'), ('dbadash_import_months', 'month'), ('mssql_ensure_day_partition', 'day'),
                   ('mssql_event_partition', 'event')):
        for x in re.finditer(fn + r"\s*\(\s*'(\w+)'", s):
            m.setdefault(x.group(1), set()).add(mk)
    # a table passed as a variable: the VALUES list of the loop that calls the event maker with v_t.tbl
    for body in re.finditer(r'AS \$\$(.*?)\$\$', s, re.S):
        b = body.group(1)
        if re.search(r'mssql_event_partition\s*\(\s*v_t\.tbl', b):
            for vals in re.finditer(r'VALUES\s*(\(.*?\))\s*\)\s*x\s*\(', b, re.S):
                for t in re.findall(r"\(\s*'(\w+)'", vals.group(1)):
                    m.setdefault(t, set()).add('event')
for t in sorted(m):
    print(t + '|' + ','.join(sorted(m[t])))
PY
q "select c.relname from pg_partitioned_table pt join pg_class c on c.oid = pt.partrelid
    join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and not c.relispartition" | LC_ALL=C sort > "$WORK/parents.txt"   # one collation for comm / join (part P, 7)
echo "read: R3 $(wc -l < "$WORK/parents.txt") partitioned parents; the migrations' makers: $(cut -d'|' -f2 "$WORK/makers.txt" | sort | uniq -c | tr '\n' ' ')"
nomaker=$(LC_ALL=C comm -23 "$WORK/parents.txt" <(cut -d'|' -f1 "$WORK/makers.txt" | LC_ALL=C sort) | tr '\n' ' ')
multi=$(grep ',' "$WORK/makers.txt" | tr '\n' ' ')
missing=""; nmiss=0
while read -r p; do
  mkr=$(awk -F'|' -v p="$p" '$1 == p {print $2}' "$WORK/makers.txt")
  if [[ $mkr == day ]]; then
    names=$(q "select string_agg('$p' || '_' || to_char((now() at time zone 'utc')::date + d, 'YYYYMMDD'), ' ') from generate_series(0, 2) d")
  else
    names="${p}_$(q "select to_char('$CUR'::timestamptz at time zone 'utc', 'YYYYMM')") ${p}_$NEXTYM"
  fi
  for nm in $names; do
    [[ $(q "select to_regclass('pgvigil.$nm') is not null") == t ]] || { nmiss=$((nmiss + 1)); [[ $nmiss -le 6 ]] && missing+="$nm "; }
  done
done < "$WORK/parents.txt"
if [[ $nmiss == 0 && -z "$nomaker" ]]; then ok "R3 after migrate every parent has its current and next month (mssql_requests: today + 2 days)"
else bad "R3 after migrate $nmiss partition(s) missing (e.g. $missing)${nomaker:+; parents no migration makes: $nomaker}"; fi
if [[ $HAVEFIX == t ]]; then
  idiff=""; nid=0
  while IFS='|' read -r p mkr; do
    grep -qx "$p" "$WORK/parents.txt" || continue
    [[ $mkr == day ]] && continue   # the daily parent's old-path day is checked by its own maker below
    case $mkr in month) fn=ensure_month_partition ;; event) fn=mssql_event_partition ;; *) continue ;; esac
    old=$(q "select to_char(date_trunc('month', now() at time zone 'utc') - interval '3 months', 'YYYYMM')")
    qq "select pgvigil.$fn('$p', (date_trunc('month', now() at time zone 'utc') - interval '3 months') at time zone 'utc')"
    # the index set without the names PostgreSQL makes up (a long partition name's index name is cut to 63 bytes, the
    # month with it: t-pd-g1's mssql_health_components): the columns, uniqueness and method
    norm="regexp_replace(regexp_replace(indexdef, 'INDEX [^ ]+ ON ', 'INDEX x ON '), '${p}_[0-9]{6}', 'P', 'g')"
    a=$(q "select string_agg($norm, ' ; ' order by $norm) from pg_indexes where schemaname = 'pgvigil' and tablename = '${p}_$old'")
    b=$(q "select string_agg($norm, ' ; ' order by $norm) from pg_indexes where schemaname = 'pgvigil' and tablename = '${p}_$NEXTYM'")
    [[ "$a" == "$b" ]] || { nid=$((nid + 1)); [[ $nid -le 3 ]] && idiff+="$p: old [$a] ahead [$b]; "; }
  done < "$WORK/makers.txt"
  [[ $nid == 0 ]] && ok "R3 every ahead-made month partition has the index set its parent's own maker gives" || bad "R3 $nid parent(s) differ: $idiff"
  comp=$(q "select parent || '|' || maker from pgvigil.partition_parents() order by 1" 2>&1)
  wrong=$(LC_ALL=C join -t'|' <(LC_ALL=C sort "$WORK/makers.txt") <(echo "$comp" | LC_ALL=C sort) | awk -F'|' '$2 != $3' | head -5 | tr '\n' ' ')
  absent=$(LC_ALL=C comm -23 "$WORK/parents.txt" <(echo "$comp" | cut -d'|' -f1 | LC_ALL=C sort) | tr '\n' ' ')
  [[ -z "$wrong" && -z "$absent" && -z "$multi" ]] && ok "R4 partition_parents() names each parent's maker as its migrations call it ($(echo "$comp" | wc -l) parents)" \
    || bad "R4 maker differs: [$wrong] not listed: [$absent] two makers: [$multi]"
else
  bad "R3 index sets: not on this tree (no ahead partitions)"
  bad "R4 not on this tree (no partition_parents)"
fi

# ---------------- R5: busy behind a holder ----------------
echo "== R5 busy behind an open insert"
if [[ $HAVEFIX == t ]]; then
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "set application_name = 'pd-H'" -c "begin" \
    -c "insert into pgvigil.activity_sample (instance_id, snapshot_at, pid) values ($I1, now(), 1)" -c "select pg_sleep(4)" -c "commit" >/dev/null 2>&1 &
  PH=$!; BG+=("$PH")
  for _ in $(seq 1 40); do [[ $(q "select count(*) from pg_stat_activity where application_name = 'pd-H' and query like '%pg_sleep%'") == 1 ]] && break; sleep 0.1; done
  ( t0=$(now_s); r=$(mk activity_sample "$M2" 2>&1); t1=$(now_s); echo "$r|$(since "$t0" "$t1")" > "$WORK/r5-make.txt" ) &
  PM=$!; sleep 0.1
  t0=$(now_s); qq "insert into pgvigil.activity_sample (instance_id, snapshot_at, pid) values ($I1, now(), 2)"; t1=$(now_s); ins=$(since "$t0" "$t1")
  wait "$PM"; IFS='|' read -r ans took < "$WORK/r5-make.txt"
  wait "$PH"
  again=$(mk activity_sample "$M2")
  if [[ $ans == busy ]] && python3 -c "import sys; a, b = float(sys.argv[1]), float(sys.argv[2]); sys.exit(0 if 0.4 <= a <= 1.0 and b <= 1.0 else 1)" "$took" "$ins" && [[ $again == made ]]; then
    ok "R5 make behind an open insert: busy in ${took} s; an insert meanwhile ${ins} s; after the commit: made"
  else bad "R5 make answered '$ans' in ${took} s, the insert took ${ins} s, the second make '$again'"; fi
  qq "drop table if exists pgvigil.activity_sample_$M2YM"
else bad "R5 not on this tree"; fi

# ---------------- R6 (SQL) / R14: the beat's retries ----------------
echo "== R6 / R14 the beat's retries"
qq "select pgvigil.import_collector_claim('pd-c-$SUF', 'pd-host', 'linux/amd64', 'proof', 'proof', 1)"
H19='[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'
if [[ $(q "select count(*) from information_schema.columns where table_schema = 'pgvigil' and table_name = 'collector_runs' and column_name = 'retries'") == 1 ]]; then
  qq "select pgvigil.import_collector_beat('pd-c-$SUF', date_trunc('minute', now()), '{\"runs\":[{\"engine\":\"postgres\",\"collection\":\"activity\",\"runs\":2,\"failures\":0,\"rows\":1,\"dur_sum\":5,\"dur_max\":5,\"hist\":$H19,\"retries\":1}]}')"
  [[ $(q "select sum(retries) from pgvigil.collector_runs where collector_id = 'pd-c-$SUF' and collection = 'activity'") == 1 ]] \
    && ok "R6 a beat carrying retries 1 stores collector_runs.retries 1" || bad "R6 collector_runs.retries is not 1"
  if out=$(q "select pgvigil.import_collector_beat('pd-c-$SUF', date_trunc('minute', now()) - interval '1 minute', '{\"runs\":[{\"engine\":\"postgres\",\"collection\":\"dbstats\",\"runs\":1,\"failures\":0,\"rows\":1,\"dur_sum\":5,\"dur_max\":5,\"hist\":$H19}]}')" 2>&1) \
     && [[ $(q "select retries from pgvigil.collector_runs where collector_id = 'pd-c-$SUF' and collection = 'dbstats'") == 0 ]]; then
    ok "R14 a beat without the retries key is stored, retries 0"
  else bad "R14 a beat without the retries key: ${out:0:160}"; fi
else bad "R6 not on this tree (no collector_runs.retries)"; bad "R14 not on this tree"; fi

# ---------------- R10b / R11: a foreign-key parent against a delete of an instance ----------------
echo "== R10b / R11 pi_load against pgvigil.instances"
qq "insert into pgvigil.pi_load (instance_id, snapshot_at, dim_group, dim_key, read_at) values ($I3, now(), 'total', 'total', now())"
if [[ $HAVEFIX == t ]]; then
  psql "$PGVIGIL_REPO_DSN" -XAtq -c "set application_name = 'pd-U'" -c "begin" \
    -c "update pgvigil.instances set last_seen = now() where instance_id = $I2" -c "select pg_sleep(3)" -c "commit" >/dev/null 2>&1 &
  PU=$!; BG+=("$PU")
  for _ in $(seq 1 40); do [[ $(q "select count(*) from pg_stat_activity where application_name = 'pd-U' and query like '%pg_sleep%'") == 1 ]] && break; sleep 0.1; done
  t0=$(now_s); ans=$(mk pi_load "$M2" 2>&1); t1=$(now_s); took=$(since "$t0" "$t1"); wait "$PU"
  if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)" "$took" && [[ $ans == busy ]]; then
    ok "R10b the make of pi_load beside an open update of instances answered '$ans' in ${took} s"
  else bad "R10b the make answered '$ans' in ${took} s"; fi
  qq "drop table if exists pgvigil.pi_load_$M2YM"
  P11=$(logpos)
  psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 > "$WORK/r11-d.out" 2>&1 <<SQL &
SET application_name = 'pd-D';
BEGIN;
UPDATE pgvigil.instances SET last_seen = now() WHERE instance_id = $I3;
DO \$\$
BEGIN
  FOR i IN 1..30 LOOP
    PERFORM pg_stat_clear_snapshot();
    EXIT WHEN EXISTS (SELECT 1 FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE a.application_name = 'pd-M' AND NOT l.granted)
           OR (i > 5 AND NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = 'pd-M' AND state = 'active'));
    PERFORM pg_sleep(0.1);
  END LOOP;
END \$\$;
DELETE FROM pgvigil.instances WHERE instance_id = $I3;
COMMIT;
SQL
  PD=$!; BG+=("$PD")
  for _ in $(seq 1 50); do [[ $(q "select count(*) from pg_stat_activity where application_name = 'pd-D' and query like 'DO%'") == 1 ]] && break; sleep 0.1; done
  t0=$(now_s); ans=$(psql "$PGVIGIL_REPO_DSN" -XAt -c "set application_name = 'pd-M'" -c "select pgvigil.import_partition_make('pi_load', '$M2')" 2>&1 | tail -1); t1=$(now_s); took=$(since "$t0" "$t1")
  wait "$PD"; RD=$?
  D11=$(deadlocks_since "$P11")
  if [[ $RD == 0 && $D11 == 0 && $ans == busy ]] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 1.0 else 1)" "$took"; then
    ok "R11 the instance's delete committed; the make of pi_load answered '$ans' in ${took} s; 0 'deadlock detected'"
  else bad "R11 delete rc $RD ($(grep -m1 ERROR "$WORK/r11-d.out" | cut -c1-100)); make '$ans' in ${took} s; 'deadlock detected' $D11"; fi
else bad "R10b not on this tree"; bad "R11 not on this tree"; fi

# ---------------- R12: the door's refusals as the collector ----------------
echo "== R12 the door as the collector login"
if [[ $HAVEFIX == t ]]; then
  qq "create role $COL login password '$PW' in role pgvigil_collector"
  CDSN="$PGVIGIL_REPO_DSN user=$COL password=$PW"
  cq() { psql "$CDSN" -XAt -v ON_ERROR_STOP=1 -v VERBOSITY=verbose -c "$1" 2>&1; }
  r12=""
  refuse() {   # $1 the SQLSTATE the refusal must carry, $2 what, $3 the call (the review's part P, 5)
    local o
    if o=$(cq "$3"); then r12+="$2 answered; "; elif ! grep -q "ERROR:  $1" <<<"$o"; then r12+="$2 refused [$(grep -m1 ERROR <<<"$o" | cut -c1-90)], not $1; "; fi
  }
  refuse 22023 "a non-parent" "select pgvigil.import_partition_make('instances', now())"
  refuse 22023 "a NULL time" "select pgvigil.import_partition_make('activity_sample', null)"
  refuse 22023 "a start over 62 days ahead" "select pgvigil.import_partition_make('activity_sample', date_trunc('month', now() at time zone 'utc') at time zone 'utc' + interval '3 months')"
  refuse 22023 "a span over 400 days" "select count(*) from pgvigil.import_partitions_due(now(), now() + interval '401 days')"
  refuse 42501 "an earlier month of alert_log" "select pgvigil.import_partition_make('alert_log', now() - interval '45 days')"
  due=$(cq "select count(*) from pgvigil.import_partitions_due(now(), now() + interval '31 days')") && [[ $due =~ ^[0-9]+$ ]] || r12+="a lawful due list failed [$due]; "
  qq "drop table if exists pgvigil.activity_sample_$M2YM"
  lawm=$(cq "select pgvigil.import_partition_make('activity_sample', '$M2')")
  law=$(cq "select pgvigil.import_partition_make('activity_sample', '$NEXT')")
  qq "drop table if exists pgvigil.activity_sample_$M2YM"
  if [[ -z "$r12" && $law == exists && $lawm == made ]]; then
    ok "R12 the collector login: five refusals by SQLSTATE, a lawful due list, a make 'made' (the month after next) and one 'exists'"
  else bad "R12 ${r12}lawful makes answered '$lawm' / '$law'"; fi
else bad "R12 not on this tree"; fi

# ---------------- R7: the collector's start pass ----------------
echo "== R7 pgvigil run's start pass"
qq "drop table if exists pgvigil.activity_sample_$NEXTYM"
"$BIN" run -config "$CFG" > "$WORK/run.out" 2>&1 &
PR=$!; BG+=("$PR")
back=f
for _ in $(seq 1 30); do [[ $(q "select to_regclass('pgvigil.activity_sample_$NEXTYM') is not null") == t ]] && { back=t; break; }; sleep 0.5; done
kill "$PR" 2>/dev/null; wait "$PR" 2>/dev/null
if [[ $back == t ]] && grep -q 'partitions ahead' "$WORK/run.out"; then ok "R7 pgvigil run's first pass made activity_sample_$NEXTYM again ($(grep -m1 'partitions ahead' "$WORK/run.out" | cut -c1-140))"
else bad "R7 after 15 s of pgvigil run: activity_sample_$NEXTYM there: $back; log: $(grep -m1 -i 'partition' "$WORK/run.out" | cut -c1-120)"; qq "select pgvigil.ensure_month_partition('activity_sample', '$NEXT')"; fi

# ---------------- R8: the demo seed over a month boundary ----------------
SDAYS=$((10#$(date -u +%d) + 5))   # back past the first of this month on any day (the review's part P, 6; demo takes 1-60)
echo "== R8 $SEEDS demo seed(s) of $SDAYS days"
P8=$(logpos); T8=$(q "select clock_timestamp()"); rcs=""
for n in $(seq 1 "$SEEDS"); do
  s0=$(now_s); "$BIN" demo -dsn "$PGVIGIL_REPO_DSN" -days "$SDAYS" -workers 8 > "$WORK/seed-$n.out" 2>&1; rc=$?; s1=$(now_s)
  rcs+="$rc "; echo "read: R8 seed $n rc $rc in $(since "$s0" "$s1") s$([[ $rc != 0 ]] && echo ": $(grep -m1 -iE 'error|fail' "$WORK/seed-$n.out" | cut -c1-160)")"
done
D8=$(deadlocks_since "$P8"); made=$(import_made_since "$T8")
[[ $(tr -d ' 0' <<<"$rcs") == "" && $D8 == 0 ]] && ok "R8 $SEEDS seed(s) rc 0, 0 'deadlock detected'" || bad "R8 seed rc [$rcs], 'deadlock detected' $D8"
[[ -z "$made" ]] && ok "R8 no partition made inside an import call during the seeds" || bad "R8 made inside imports: $(cut -c1-400 <<<"$made") ($(tr ';' '\n' <<<"$made" | grep -c .) in all)"

echo "proof-partition-deadlock: $NFAIL FAIL"
[[ $NFAIL == 0 ]]
