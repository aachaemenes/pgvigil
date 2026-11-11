#!/usr/bin/env bash
# Proof of the pgaudit collection, migration 0100 and /api/pgaudit (task 157).
#
#   PGVIGIL_BIN      a pgvigil binary to use; default: the proof builds one into its temp folder (go build).
#   PGAUDIT_PG       the PostgreSQL major of the audited server (default 18); the proof builds the image
#                    pgvigil-proof-pgaudit:<major> once (postgres:<major> plus the PGDG package postgresql-<major>-pgaudit)
#                    and keeps it for the next run.
#   PGAUDIT_REPO_PG  the PostgreSQL major of the repository server (default: PGAUDIT_PG); 13 proves 0100 on the oldest
#                    repository the CI covers.
#   Needs: docker, psql, curl, python3; go (without PGVIGIL_BIN).
# Two containers of the proof's own, on 127.0.0.1 ports the system hands out: the audited server (pgaudit preloaded,
# logging_collector on, log_line_prefix '%m [%p] %q%u@%d ', log_timezone America/Los_Angeles) and a plain repository
# server. Both are removed with their volumes at the end, and that is read back. Nothing that exists before the run
# is touched.
#
# Expected (written before the first run):
#  A. the monitoring login with pg_monitor only, pgaudit.log at its default (none). collect pgaudit ends 'ok' (the
#     health is stored though the log is not read). pgaudit_health: loaded, status 'warning', cell 'loaded, logging
#     nothing', log_read 'not read' with a reason that names pgvigil_read_log. pgaudit_findings holds the finding
#     'pgaudit.log' whose detail starts 'pgaudit preloaded, logging nothing'. No pgaudit cursor, no event row.
#  B. the cell follows pgaudit.log. ALTER SYSTEM SET pgaudit.log = 'ddl, role, read, write, misc_set' and a reload:
#     status 'ok', cell 'ddl, role, read, write, misc_set', the finding gone. ALTER SYSTEM RESET and a reload: status
#     'warning', cell 'loaded, logging nothing', the finding back. ALTER ROLE <app> SET pgaudit.log = 'all' (the
#     server still none): status 'ok', cell '1 database / role setting', a pgaudit_settings row of scope 'role' for
#     that role; the role's setting reset: 'warning' again. ALTER SYSTEM SET pgaudit.log_parameter = on (with the
#     classes set again): the finding 'pgaudit.log_parameter' whose detail starts 'log_parameter on: statement
#     parameters reach the log'; reset: gone.
#  C. the read door made (collect/serverlog.go's pgvigil_read_log), pgaudit.log = 'ddl, role, read, write, misc_set',
#     pgaudit.log_relation on, the extension created in the test database. As the superuser there: CREATE TABLE t and
#     t2, CREATE ROLE <app> ... PASSWORD (a marked comment), GRANT SELECT ON t TO <app> (marked), DROP TABLE t2
#     (marked), SET pgaudit.log_catalog = off. collect: health log_read 'ok'; pgaudit_events holds exactly one row
#     ROLE / CREATE ROLE with object ROLE <app>, exactly one ROLE / GRANT with object public.t and target_role <app>,
#     exactly one DDL / DROP TABLE with object TABLE public.t2, exactly one MISC_SET / SET with object SETTING
#     pgaudit.log_catalog; each by the superuser in the test database, its time within the run. The cursor
#     'pgaudit:serverlog:log' exists.
#     [Run 1, box job s157-proof1, 2026-11-11 13:33 PST: A and B as expected; C found the CREATE ROLE, the GRANT and
#     the DROP TABLE once each and no SET row. Cause: pgaudit 18.0 writes a SET with the class MISC, never MISC_SET
#     (box job s157-rawlog), and the collector kept rows by the line's class. Fixed in the collector (the class is
#     pgaudit.log's: logparse LogClass), the expectation above unchanged. Seen in the same raw log, expected before
#     run 2: pgaudit cuts a CREATE ROLE's text at PASSWORD, so the role's mark is written before the password; and
#     the collector's own session settings are SETs too, so:]
#     No event row is by the monitoring login: its four session SETs per connection are counted (pgaudit_counts holds
#     MISC_SET / SET rows with object SETTING statement_timeout and lock_timeout for it), as is every SET of a
#     setting that is not an audit matter.
#  D. counting once. As <app>: 400 SELECTs of t (a marked literal in each), collect, pg_rotate_logfile(), 600 more,
#     collect: pgaudit_counts sums to exactly 1,000 for role <app>, class READ, command SELECT, object TABLE public.t.
#     Two more collects change neither that sum nor the number of event rows (the overlap is read again and gains
#     nothing). pgaudit_count_secs holds the same 1,000 over more than one source (the two log files).
#  E. the opt-in. Instance 1 has no pgaudit_text: a dump of the whole repository (pg_dump, data only) holds none of
#     the marks (the statements' comments, the SELECTs' literal, the role's password): grep 0. Then instance 2 (the
#     same server, pgaudit_text: true) reads the same log: its CREATE ROLE row's statement holds its mark and not the
#     password, its GRANT row's statement holds its mark, its counts read 1,000 too; the dump still holds neither the
#     SELECTs' literal nor the password (a counted entry never keeps text): grep 0 for both.
#  F. the rules. pgaudit_findings holds 'audit rule: role or privilege change' for instance 1 (value '2 ROLE entries
#     in the last 1 day(s)', the detail naming GRANT and CREATE ROLE) and 'audit rule: audit setting changed by a
#     session' (value '1 MISC_SET entry in the last 1 day(s)').
#     [Before run 2, from run 1's row listing: the door's own REVOKE ... FROM PUBLIC and GRANT ... TO <login> are
#     audited ROLE entries as well, so the value is '4 ROLE entries in the last 1 day(s)'.] Twelve sign-ins with a wrong password, collect
#     serverlog: the finding 'audit rule: failed sign-ins' (value '12 failed sign-ins in the last 1 hour(s)'). The
#     rule switched off (UPDATE pgaudit_rules): the finding gone; on again: back.
#  G. the API (pgvigil serve -no-login). /api/pgaudit?instance=<1>: health.cell is the view's; events holds the four
#     rows of C and no statement column value; counts holds the READ row with entries 1000; signins holds 12 rows;
#     rules holds the six rules, three of them firing. part=nonsense answers 400. /api/pgaudit with no instance lists
#     both instances with their cells.
#  H. rights. pgvigil_collector may run import_pgaudit and may not read pgaudit_events; pgvigil_reader may read
#     pgaudit_events, pgaudit_counts, pgaudit_health, pgaudit_findings and pgaudit_rules.
#  I. a server without pgaudit (the repository server itself as instance 3): status 'off', cell 'not loaded',
#     log_read 'off', no finding. ALTER ROLE ... SET pgaudit.log = 'all' there: status 'warning', cell 'set, not
#     loaded', the finding 'shared_preload_libraries' whose detail starts 'pgaudit settings without pgaudit'.
#  Z. both containers and their volumes are gone (docker ps -a and docker volume ls read back: 0 of the proof's).
set -euo pipefail
cd "$(dirname "$0")/.."
PG=${PGAUDIT_PG:-18}; RPG=${PGAUDIT_REPO_PG:-$PG}
SUF=$RANDOM$RANDOM
MON_CT=pgvaud$SUF-mon; REPO_CT=pgvaud$SUF-repo; IMG=pgvigil-proof-pgaudit:$PG
SUPW=s$RANDOM$RANDOM$RANDOM; MON=pgvaud_mon_$SUF; MONPW=m$RANDOM$RANDOM$RANDOM
APP=pgvaud_app_$SUF; APPPW=PWSECRET$SUF
TDB=pgvaud_db_$SUF; REPO_DB=pgvigil_auditproof_$SUF
I1=proof-audit-$SUF; I2=proof-audit-text-$SUF; I3=proof-audit-none-$SUF
MROLE=MARK${SUF}ROLE; MGRANT=MARK${SUF}GRANT; MDROP=MARK${SUF}DROP; MLIT=MARKLIT$SUF
WORK=$(mktemp -d); SRV=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  docker rm -f -v "$MON_CT" "$REPO_CT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  local left
  left=$(docker ps -aq --filter "name=pgvaud$SUF" | wc -l)
  echo "Z: containers of this proof left: $left"
}
trap cleanup EXIT
for t in docker psql curl python3; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done

BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN is not set"
  BIN=$WORK/pgvigil
  CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil || fail "go build"
fi

echo "--- the image $IMG"
if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  docker build -q -t "$IMG" - >/dev/null <<EOF || fail "the image did not build (postgres:$PG plus postgresql-$PG-pgaudit from PGDG)"
FROM postgres:$PG
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-$PG-pgaudit && rm -rf /var/lib/apt/lists/*
EOF
fi

freeport() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
MPORT=$(freeport); RPORT=$(freeport); WPORT=$(freeport)
echo "--- the audited server (PostgreSQL $PG, pgaudit preloaded) on $MPORT, the repository server (PostgreSQL $RPG) on $RPORT"
docker run -d --name "$MON_CT" -e POSTGRES_PASSWORD="$SUPW" -p "127.0.0.1:$MPORT:5432" "$IMG" \
  postgres -c shared_preload_libraries=pgaudit -c logging_collector=on -c "log_line_prefix=%m [%p] %q%u@%d " \
  -c log_timezone=America/Los_Angeles >/dev/null || fail "the audited server's container did not start"
docker run -d --name "$REPO_CT" -e POSTGRES_PASSWORD="$SUPW" -p "127.0.0.1:$RPORT:5432" "postgres:$RPG" >/dev/null \
  || fail "the repository server's container did not start"
SU="host=127.0.0.1 port=$MPORT user=postgres password=$SUPW dbname=postgres sslmode=disable"
RSU="host=127.0.0.1 port=$RPORT user=postgres password=$SUPW dbname=postgres sslmode=disable"
up() {   # the image restarts the server once after its first start: two answers a second apart
  local dsn=$1 n=0
  for _ in $(seq 1 120); do
    if psql "$dsn" -XAtqc 'select 1' >/dev/null 2>&1; then n=$((n + 1)); [[ $n -ge 2 ]] && return 0; else n=0; fi
    sleep 1
  done
  return 1
}
up "$SU" || fail "the audited server did not come up: $(docker logs "$MON_CT" 2>&1 | tail -5)"
up "$RSU" || fail "the repository server did not come up: $(docker logs "$REPO_CT" 2>&1 | tail -5)"
su() { psql "$SU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
sut() { psql "$SU dbname=$TDB" -XAtq -v ON_ERROR_STOP=1 "$@"; }
[[ $(su "show shared_preload_libraries") == pgaudit ]] || fail "pgaudit is not preloaded on the audited server"
echo "pgaudit $(su "select default_version from pg_available_extensions where name = 'pgaudit'") on $(su "show server_version")"
su "create role $MON login password '$MONPW' in role pg_monitor"
su "create database $TDB"
export MON_DSN="host=127.0.0.1 port=$MPORT user=$MON password=$MONPW dbname=postgres sslmode=disable"
export RMON_DSN="$RSU"

psql "$RSU" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$RPORT user=postgres password=$SUPW dbname=$REPO_DB sslmode=disable"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
CFG=$WORK/pgvigil.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: $I1
    dsn: env:MON_DSN
  - name: $I2
    dsn: env:MON_DSN
    pgaudit_text: true
  - name: $I3
    dsn: env:RMON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
collect() { "$BIN" collect -config "$CFG" -instance "$1" -once "${2:-pgaudit}" >"$WORK/collect.out" 2>&1 || fail "collect ${2:-pgaudit} on $1: $(tail -3 "$WORK/collect.out")"; }
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
st() { q "select status || '|' || coalesce(note, '') from pgvigil.collection_dates where instance_id = $1 and collection = 'pgaudit'"; }
health() { q "select status || '|' || cell from pgvigil.pgaudit_health where instance_id = $1"; }
finding() { q "select count(*) from pgvigil.pgaudit_findings where instance_id = $1 and setting = '$2' and detail like '$3%'"; }
reload() { su "select pg_reload_conf()" >/dev/null; sleep 0.6; }
START=$(su "select now() - interval '2 seconds'")

echo "--- A. loaded, logging nothing, the log not readable"
collect "$I1"
P=$(iid "$I1")
[[ $(st "$P") == "ok|" ]] || fail "A status: $(st "$P")"
[[ $(health "$P") == "warning|loaded, logging nothing" ]] || fail "A health: $(health "$P")"
[[ $(q "select loaded::text || '|' || log_read || '|' || (log_read_reason like '%pgvigil_read_log%')::text from pgvigil.pgaudit_health where instance_id = $P") == "true|not read|true" ]] \
  || fail "A log read: $(q "select loaded, log_read, log_read_reason from pgvigil.pgaudit_health where instance_id = $P")"
[[ $(finding "$P" pgaudit.log 'pgaudit preloaded, logging nothing') == 1 ]] || fail "A: the finding is not there"
[[ $(q "select count(*) from pgvigil.log_cursor where instance_id = $P and source like 'pgaudit:%'") == 0 ]] || fail "A: a cursor without a read"
[[ $(q "select count(*) from pgvigil.pgaudit_events where instance_id = $P") == 0 ]] || fail "A: event rows without a read"
ok "A: $(health "$P"); $(q "select log_read from pgvigil.pgaudit_health where instance_id = $P")"

echo "--- B. the cell follows pgaudit.log"
CLASSES='ddl, role, read, write, misc_set'
su "alter system set pgaudit.log = '$CLASSES'"; reload; collect "$I1"
[[ $(health "$P") == "ok|$CLASSES" ]] || fail "B set: $(health "$P")"
[[ $(finding "$P" pgaudit.log '') == 0 ]] || fail "B set: the finding stayed"
su "alter system reset pgaudit.log"; reload; collect "$I1"
[[ $(health "$P") == "warning|loaded, logging nothing" ]] || fail "B reset: $(health "$P")"
[[ $(finding "$P" pgaudit.log 'pgaudit preloaded, logging nothing') == 1 ]] || fail "B reset: the finding is not back"
su "create role $APP login password 'x$RANDOM$RANDOM'"
su "alter role $APP set pgaudit.log = 'all'"; collect "$I1"
[[ $(health "$P") == "ok|1 database / role setting" ]] || fail "B role: $(health "$P")"
[[ $(q "select count(*) from pgvigil.pgaudit_settings where instance_id = $P and scope = 'role' and rolname = '$APP' and name = 'pgaudit.log' and value = 'all'") == 1 ]] \
  || fail "B role: the role's setting is not stored"
su "alter role $APP reset pgaudit.log"; collect "$I1"
[[ $(health "$P") == "warning|loaded, logging nothing" ]] || fail "B role reset: $(health "$P")"
su "drop role $APP"
su "alter system set pgaudit.log = '$CLASSES'"; su "alter system set pgaudit.log_parameter = on"; reload; collect "$I1"
[[ $(finding "$P" pgaudit.log_parameter 'log_parameter on: statement parameters reach the log') == 1 ]] || fail "B: no log_parameter finding"
su "alter system reset pgaudit.log_parameter"; reload; collect "$I1"
[[ $(finding "$P" pgaudit.log_parameter '') == 0 ]] || fail "B: the log_parameter finding stayed"
ok "B: the cell and the findings follow the settings"

echo "--- C. the door, and the entries kept as rows"
DOOR=$(awk '/^const ServerlogDoorSQL = `/{f=1; sub(/^const ServerlogDoorSQL = `/, "")} f{ if (/`$/) { sub(/`$/, ""); print; exit } print }' internal/collect/serverlog.go)
[[ "$DOOR" == *"pgvigil_read_log"* ]] || fail "C: the door's text was not found in serverlog.go"
printf '%s\n' "${DOOR//<login>/$MON}" | psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null || fail "C: the door was not created"
su "alter system set pgaudit.log_relation = on"; reload
sut -c "create extension pgaudit" >/dev/null
sut >/dev/null <<EOF
create table public.t (id int, note text);
create table public.t2 (id int);
insert into public.t select g, 'row ' || g from generate_series(1, 50) g;
create role /* $MROLE */ $APP login password '$APPPW';
grant select on public.t to $APP /* $MGRANT */;
drop table public.t2 /* $MDROP */;
set pgaudit.log_catalog = off;
EOF
sleep 0.6   # the logging collector writes the file
collect "$I1"
[[ $(st "$P") == "ok|" ]] || fail "C status: $(st "$P")"
[[ $(q "select log_read from pgvigil.pgaudit_health where instance_id = $P") == ok ]] \
  || fail "C: the log is not read: $(q "select log_read_reason from pgvigil.pgaudit_health where instance_id = $P")"
ev() { q "select count(*) from pgvigil.pgaudit_events where instance_id = $1 and usename = 'postgres' and datname = '$TDB' and snapshot_at >= '$START' and $2"; }
show() { q "select class, command, object_type, object_name, target_role, usename, datname from pgvigil.pgaudit_events where instance_id = $1 order by snapshot_at"; }
[[ $(ev "$P" "class = 'ROLE' and command = 'CREATE ROLE' and object_type = 'ROLE' and object_name = '$APP'") == 1 ]] || fail "C CREATE ROLE: $(show "$P")"
[[ $(ev "$P" "class = 'ROLE' and command = 'GRANT' and object_name = 'public.t' and target_role = '$APP'") == 1 ]] || fail "C GRANT: $(show "$P")"
[[ $(ev "$P" "class = 'DDL' and command = 'DROP TABLE' and object_type = 'TABLE' and object_name = 'public.t2'") == 1 ]] || fail "C DROP TABLE: $(show "$P")"
[[ $(ev "$P" "class = 'MISC_SET' and command = 'SET' and object_type = 'SETTING' and object_name = 'pgaudit.log_catalog'") == 1 ]] || fail "C SET: $(show "$P")"
[[ $(q "select count(*) from pgvigil.log_cursor where instance_id = $P and source = 'pgaudit:serverlog:log'") == 1 ]] \
  || fail "C cursor: $(q "select source from pgvigil.log_cursor where instance_id = $P")"
[[ $(q "select count(*) from pgvigil.pgaudit_events where instance_id = $P and usename = '$MON'") == 0 ]] || fail "C: the monitoring login's own SETs are rows: $(show "$P")"
OWN=$(q "select string_agg(distinct object_name, ',' order by object_name) from pgvigil.pgaudit_counts where instance_id = $P and usename = '$MON' and class = 'MISC_SET' and command = 'SET' and object_type = 'SETTING' and object_name in ('statement_timeout', 'lock_timeout')")
[[ "$OWN" == "lock_timeout,statement_timeout" ]] || fail "C: the monitoring login's SETs are not counted by setting: '$OWN' ($(q "select usename, class, command, object_type, object_name, sum(entries) from pgvigil.pgaudit_counts where instance_id = $P group by 1, 2, 3, 4, 5"))"
ok "C: CREATE ROLE, GRANT, DROP TABLE and SET each found once ($(q "select count(*) from pgvigil.pgaudit_events where instance_id = $P") rows in all)"

echo "--- D. 1,000 SELECTs counted once"
APP_DSN="host=127.0.0.1 port=$MPORT user=$APP password=$APPPW dbname=$TDB sslmode=disable"
selects() { for n in $(seq 1 "$1"); do echo "select note from public.t where id = $((n % 50 + 1)) and note <> '$MLIT';"; done | psql "$APP_DSN" -XAtq -v ON_ERROR_STOP=1 >/dev/null; }
reads() { q "select coalesce(sum(entries), 0) from pgvigil.pgaudit_counts where instance_id = $1 and usename = '$APP' and class = 'READ' and command = 'SELECT' and object_type = 'TABLE' and object_name = 'public.t'"; }
selects 400; sleep 0.6; collect "$I1"
[[ $(reads "$P") == 400 ]] || fail "D after 400: $(reads "$P") ($(q "select usename, class, command, object_type, object_name, sum(entries) from pgvigil.pgaudit_counts where instance_id = $P group by 1, 2, 3, 4, 5"))"
su "select pg_rotate_logfile()" >/dev/null; sleep 1.2
selects 600; sleep 0.6; collect "$I1"
[[ $(reads "$P") == 1000 ]] || fail "D after 1,000: $(reads "$P")"
N1=$(q "select count(*) from pgvigil.pgaudit_events where instance_id = $P")
collect "$I1"; collect "$I1"
[[ $(reads "$P") == 1000 ]] || fail "D: a re-read changed the count: $(reads "$P")"
[[ $(q "select count(*) from pgvigil.pgaudit_events where instance_id = $P and usename = 'postgres' and datname = '$TDB'") == \
   $(q "select count(*) from pgvigil.pgaudit_events where instance_id = $P and usename = 'postgres' and datname = '$TDB' and snapshot_at >= '$START'") ]] || fail "D: rows outside the run"
[[ $(ev "$P" "class = 'ROLE' and command = 'CREATE ROLE'") == 1 && $(ev "$P" "class = 'DDL' and command = 'DROP TABLE' and object_type = 'TABLE'") == 1 ]] || fail "D: a re-read doubled a row"
SECS=$(q "select sum(entries) || '|' || (count(distinct source) > 1)::text from pgvigil.pgaudit_count_secs where instance_id = $P and usename = '$APP' and class = 'READ' and object_name = 'public.t'")
[[ "$SECS" == "1000|true" ]] || fail "D: the per-second guard reads $SECS"
ok "D: 1,000 READ entries of $APP on public.t, unchanged by two more reads ($N1 event rows before them)"

echo "--- E. no statement text without the opt-in"
dump() { docker exec -e PGPASSWORD="$SUPW" "$REPO_CT" pg_dump -U postgres --data-only -n pgvigil "$REPO_DB" > "$WORK/dump.sql" || fail "E: pg_dump"; }
hits() { grep -c -- "$1" "$WORK/dump.sql" || true; }
dump
[[ $(hits "$APP") -ge 1 ]] || fail "E: the dump does not even hold the role's name (is it the repository's?)"
for m in "$MROLE" "$MGRANT" "$MDROP" "$MLIT" "$APPPW"; do
  [[ $(hits "$m") == 0 ]] || fail "E: the mark $m is in the repository without the opt-in ($(hits "$m") lines)"
done
[[ $(q "select count(*) from pgvigil.pgaudit_events where instance_id = $P and (statement is not null or parameters is not null)") == 0 ]] || fail "E: a row keeps text"
ok "E: grep 0 for the five marks in the repository's dump ($(wc -l < "$WORK/dump.sql") lines)"
collect "$I2"
T=$(iid "$I2")
[[ $(q "select keep_text from pgvigil.pgaudit_health where instance_id = $T") == t ]] || fail "E: instance 2 does not say it keeps text"
[[ $(q "select count(*) from pgvigil.pgaudit_events where instance_id = $T and command = 'CREATE ROLE' and object_name = '$APP' and statement like '%$MROLE%' and statement not like '%$APPPW%'") == 1 ]] \
  || fail "E opt-in CREATE ROLE: $(q "select statement from pgvigil.pgaudit_events where instance_id = $T and command = 'CREATE ROLE'")"
[[ $(q "select count(*) from pgvigil.pgaudit_events where instance_id = $T and command = 'GRANT' and statement like '%$MGRANT%'") == 1 ]] || fail "E opt-in GRANT"
[[ $(reads "$T") == 1000 ]] || fail "E: instance 2 counts $(reads "$T")"
dump
[[ $(hits "$MROLE") -ge 1 ]] || fail "E: the opt-in instance's statement is not in the dump"
for m in "$MLIT" "$APPPW"; do
  [[ $(hits "$m") == 0 ]] || fail "E: $m is in the repository with the opt-in ($(hits "$m") lines)"
done
ok "E: with pgaudit_text the rows keep their statement ($(q "select statement from pgvigil.pgaudit_events where instance_id = $T and command = 'CREATE ROLE' and object_name = '$APP'")); the SELECTs' literal and the password are nowhere"

echo "--- F. the rules"
fval() { q "select value from pgvigil.pgaudit_findings where instance_id = $1 and setting = 'audit rule: $2'"; }
[[ $(fval "$P" 'role or privilege change') == "4 ROLE entries in the last 1 day(s)" ]] || fail "F role rule: '$(fval "$P" 'role or privilege change')' ($(show "$P"))"
[[ $(q "select (detail like '%GRANT%' and detail like '%CREATE ROLE%')::text from pgvigil.pgaudit_findings where instance_id = $P and setting = 'audit rule: role or privilege change'") == true ]] || fail "F: the role rule's detail"
[[ $(fval "$P" 'audit setting changed by a session') == "1 MISC_SET entry in the last 1 day(s)" ]] || fail "F set rule: '$(fval "$P" 'audit setting changed by a session')'"
for _ in $(seq 1 12); do
  psql "host=127.0.0.1 port=$MPORT user=$APP password=wrong$RANDOM dbname=$TDB sslmode=disable" -XAtqc 'select 1' >/dev/null 2>&1 && fail "F: a wrong password signed in"
done
sleep 0.6
collect "$I1" serverlog
[[ $(fval "$P" 'failed sign-ins') == "12 failed sign-ins in the last 1 hour(s)" ]] \
  || fail "F sign-in rule: '$(fval "$P" 'failed sign-ins')' ($(q "select count(*) from pgvigil.log_events where instance_id = $P and kind = 'auth_fail'") auth_fail events)"
q "update pgvigil.pgaudit_rules set is_enabled = false where name = 'failed sign-ins'" >/dev/null
[[ -z $(fval "$P" 'failed sign-ins') ]] || fail "F: a rule switched off still fires"
q "update pgvigil.pgaudit_rules set is_enabled = true where name = 'failed sign-ins'" >/dev/null
[[ -n $(fval "$P" 'failed sign-ins') ]] || fail "F: the rule switched on again does not fire"
ok "F: the role, the setting and the sign-in rules fire; a rule switched off does not"

echo "--- G. the API"
"$BIN" serve -config "$CFG" -no-login -listen "127.0.0.1:$WPORT" > "$WORK/serve.out" 2>&1 & SRV=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$WPORT/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
kill -0 "$SRV" 2>/dev/null || fail "G: serve exited: $(cat "$WORK/serve.out")"
U="http://127.0.0.1:$WPORT/api/pgaudit"
curl -fs "$U?instance=$P" > "$WORK/audit.json" || fail "G: /api/pgaudit (is the route wired in web.go?)"
API=$(python3 - "$WORK/audit.json" "$APP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); app = sys.argv[2]
def rows(part):
    t = d[part]
    return [dict(zip(t["columns"], r)) for r in (t["rows"] or [])]
h = rows("health")[0]
ev = rows("events")
wanted = [("ROLE", "CREATE ROLE"), ("ROLE", "GRANT"), ("DDL", "DROP TABLE"), ("MISC_SET", "SET")]
found = sum(1 for w in wanted if sum(1 for e in ev if (e["class"], e["command"]) == w and e["datname"].startswith("pgvaud_db_")
                                    and (e["object_type"] or "") != "INDEX") == 1)
text = sum(1 for e in ev if e["statement"] is not None or e["parameters"] is not None)
reads = sum(c["entries"] for c in rows("counts") if c["usename"] == app and c["class"] == "READ" and c["object_name"] == "public.t")
rules = rows("rules")
print("|".join(str(x) for x in [h["status"], h["cell"], found, text, reads, len(rows("signins")), len(rules), sum(1 for r in rules if r["fires"])]))
PY
)
[[ "$API" == "ok|$CLASSES|4|0|1000|12|6|3" ]] || fail "G: the API reads $API"
code=$(curl -s -o /dev/null -w '%{http_code}' "$U?instance=$P&part=nonsense"); [[ "$code" == 400 ]] || fail "G: an unknown part answered $code"
FLEET=$(curl -fs "$U" | python3 -c 'import json, sys
t = json.load(sys.stdin)["instances"]; i = t["columns"].index("instance"); c = t["columns"].index("cell")
print(";".join(sorted(r[i] + "=" + r[c] for r in t["rows"])))')
[[ "$FLEET" == "$I1=$CLASSES;$I2=$CLASSES" ]] || fail "G fleet: $FLEET"
kill "$SRV" 2>/dev/null || true; SRV=""
ok "G: $API; fleet $FLEET"

echo "--- H. rights"
R=$(q "select has_function_privilege('pgvigil_collector', 'pgvigil.import_pgaudit(int, timestamptz, jsonb)', 'EXECUTE')::text || '|' ||
              has_table_privilege('pgvigil_collector', 'pgvigil.pgaudit_events', 'SELECT')::text || '|' ||
              (has_table_privilege('pgvigil_reader', 'pgvigil.pgaudit_events', 'SELECT') and has_table_privilege('pgvigil_reader', 'pgvigil.pgaudit_counts', 'SELECT')
               and has_table_privilege('pgvigil_reader', 'pgvigil.pgaudit_health', 'SELECT') and has_table_privilege('pgvigil_reader', 'pgvigil.pgaudit_findings', 'SELECT')
               and has_table_privilege('pgvigil_reader', 'pgvigil.pgaudit_rules', 'SELECT'))::text")
[[ "$R" == "true|false|true" ]] || fail "H: $R"
ok "H: the collector imports and does not read; the reader reads"

echo "--- I. a server without pgaudit"
collect "$I3"
N=$(iid "$I3")
[[ $(health "$N") == "off|not loaded" ]] || fail "I: $(health "$N")"
[[ $(q "select log_read from pgvigil.pgaudit_health where instance_id = $N") == off ]] || fail "I log_read"
[[ $(q "select count(*) from pgvigil.pgaudit_findings where instance_id = $N") == 0 ]] || fail "I: a finding on a server without pgaudit"
psql "$RSU" -XAtq -v ON_ERROR_STOP=1 -c "create role pgvaud_none_$SUF" -c "alter role pgvaud_none_$SUF set pgaudit.log = 'all'" >/dev/null || fail "I: the role's setting was refused"
collect "$I3"
[[ $(health "$N") == "warning|set, not loaded" ]] || fail "I set: $(health "$N")"
[[ $(finding "$N" shared_preload_libraries 'pgaudit settings without pgaudit') == 1 ]] || fail "I: no finding for a setting without the library"
ok "I: off without pgaudit; a pgaudit.* value without the library is a finding"

echo "PASS: proof-pgaudit (audited server PostgreSQL $PG, repository PostgreSQL $RPG)"
