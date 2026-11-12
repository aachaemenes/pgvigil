#!/usr/bin/env bash
# Proof of task 162: the backup_tools and rolechange collections, migration 0103 and /api/pg/* (q_pg_backups.go).
#
#   PG             the PostgreSQL major of the monitored server (default 18); the proof builds the image
#                  pgvigil-proof-pgbackrest:<PG> once (postgres:<PG> plus the PGDG package pgbackrest) and keeps it.
#   REPO_PG        the repository server's major (default: PG).
#   PGVIGIL_BIN    a pgvigil binary; default: the proof builds one into its temp folder (go build, the tree as it is).
#   Needs: docker, psql, curl, python3; go without PGVIGIL_BIN.
# Two containers of the proof's own on 127.0.0.1 ports the system hands out: the monitored one (a primary archiving with
# pgBackRest into a repository inside the container, logging_collector on; later a streaming standby on its port 5433
# and a file-fed standby restored by pgBackRest on 5434, both inside it) and a plain repository server. The collector's
# host has no pgBackRest: a stand-in 'pgbackrest' on the proof's PATH runs 'docker exec -u postgres <container>
# pgbackrest "$@"', which is the binary and the repository the collector would reach on a host set up for it
# (docs/backups-postgres.md); a stand-in 'barman' prints a recorded 'barman -f json list-backups' answer (barman 3.20's
# JsonOutputWriter shape: barman itself is not run). Both containers are removed with their volumes at the end, and that
# is read back (Z). Nothing that existed before the run is touched; port 8008 (Patroni's default) is used only when free.
#
# Expected (written before the first run):
#  A. pgBackRest. stanza 'demo' made, a full backup, a write and two WAL switches, a diff backup, two more switches.
#     collect -once backup_tools as a pg_monitor-only login (the stand-in on PATH): ok. pg_backup_detect tools 1,
#     archive_command_set true, is_replica false. pg_backup_tools pgbackrest|demo: state ok, status_code 0, named_by
#     archive_command, backup_count 2, archive_max 24 hex characters. pg_base_backups: 2 present rows, one 'full' and
#     one 'diff'; the full's db_size_bytes equals the 'info.size' pgbackrest's own JSON gives for that label (read here
#     through the stand-in) and is over 1 MB; the diff's prior is the full's label; the newest (the diff) has
#     wal_since_segments >= 2 and wal_since_bytes = wal_since_segments * 16 MB. pg_base_backup_status: last_type diff,
#     full_age_h under 1, full_warn_h 192 (the default, level 'default'). No 'base backups' row in pg_backups_checks.
#  A2. the stand-in off PATH: collect: pg_backup_tools state no_binary, message names archive_command and pgbackrest;
#     pg_backups_findings one info row 'pgbackrest not on the collector host'; the 2 backups still present; no
#     'base backups' check row (a missing binary is a finding, never a red cell).
#  A3. the instance's full_backup_age set to warn 0.01 h / crit 1000 h (import_pg_threshold, done), the stand-in back,
#     40 s after the full backup ended, collect: one 'base backups' check row, warning, 'full backup older than 0.01 h',
#     object demo. Refusals, each 'refused' with its reason and no row: key 'nope'; level 'database' for full_backup_age;
#     warn 'abc'; crit 5 under warn 10 (full_backup_age grows: refused); inherit on a level without a row. inherit:
#     done, the check row gone at the next collect.
#  A4. barman: restore_command set to 'barman-wal-restore -U barman backuphost pg1 %f %p' (PostgreSQL 14 and later:
#     a reload; on 13 the part is said 'not run': restore_command is a postmaster setting there) and the barman
#     stand-in on PATH: pg_backup_tools barman|pg1 state ok named_by restore_command, backup_count 3; pg_base_backups
#     barman rows: 20261111T100000 full ok size 52428800, 20261110T100000 status error (FAILED), 20261111T120000
#     running (STARTED, no end time); 'newest backup failed' is NOT a check (the newest ended backup is the DONE one).
#     restore_command reset afterwards; the next collect marks barman|pg1 is_present false and keeps its backups.
#  B. a role change. A streaming standby (pg_basebackup -R inside the container, port 5433, cluster_name pv_standby).
#     collect -once rolechange on it: pg_role_state is_replica true, timeline 1, timeline_source 'wal receiver',
#     system_identifier = the primary's. pg_promote(); collect: pg_role_changes exactly 1 row for it: promotion, standby
#     -> primary, timeline 1 -> 2, changed_at_source 'history file' (00000002.history), changed_at between prev_read_at
#     and detected_at (the server's clock against the repository's: within a minute either side), postmaster_restarted
#     false, held_secs NULL. A third collect: still 1 row. pg_role_state since = that changed_at.
#  C. log shipping. A standby restored by 'pgbackrest --type=standby restore' (port 5434, restore_command
#     archive-get, no primary_conninfo). collect backup_tools on it: pg_backup_detect is_replica true, has_receiver false,
#     restore_command_set true; pg_backup_tools pgbackrest|demo named_by restore_command; pg_wal_replay present,
#     has_receiver false, replay_lsn set. With rolechange and backups collected on the primary, pg_wal_replay_status
#     names the primary (the same system identifier). The rule itself on seeded rows (S).
#  D. a crash. The server-log door made for the monitoring login; collect serverlog; a backend killed with SIGSEGV;
#     the server restarts the others. collect serverlog: pg_crashes exactly 1 row, signal 11; pg_crash_state status
#     critical; a 'crashes' check row, critical. An acknowledgement (import_ack: kind ack, check_key dumps, the instance,
#     done): pg_crashes acked_by 'proof', pg_crash_state status ok, open_30d 0, no 'crashes' check row.
#  E. the statement store: collect extensions on the primary: pg_stmt_store_state available true, preloaded false
#     (the image does not preload it).
#  F. uptime: the primary started minutes ago: an 'uptime' check row, critical, 'uptime under 12 h' (default). The
#     instance's uptime set to warn 0 / crit 0: no row. The tag 'proofpg' (the config's tags) at crit 1000 h / warn 2000 h
#     with the instance level ended (inherit): critical again, threshold_level 'tag'. The instance at warn 0 / crit 0
#     again: no row (the instance wins over the tag).
#  H. the web side, a -no-login server with the wiring: GET /api/pg/backups (the 6 parts, tools 1+ row), /api/pg/state
#     (the 10 parts), /api/pg/replication (links holds the primary and both standbys), /api/pg/thresholds (keys 8),
#     /api/pg/backups/fleet: each 200. /api/overview has rows of check_group 'uptime'. POST /api/pg/thresholds with the
#     header and no login: 403; without the header: 403.
#  I. Patroni (only when 127.0.0.1:8008 is free): a stand-in /cluster on it (2 members) and a session named 'Patroni
#     heartbeat' on the promoted standby: collect rolechange: pg_patroni_read ok true, members 2; pg_patroni_members
#     pg1 leader, pg2 replica with lag_bytes 0. The session closed: the next collect marks both absent.
#  S. the rules on seeded rows in the same repository (instances of their own):
#     s1 a file-fed standby (no receiver) 90 min behind, its primary not in the fleet: 'replay delay over 60 min' warning
#     s2 the same at 300 min: critical
#     s3 a streaming standby 300 min behind (has_receiver true): nothing (the Replication tab's rule)
#     s4 a file-fed standby 300 min behind whose primary (same system id, archiver row) archived up to a segment the
#        standby has replayed past: caught_up true, nothing
#     s5 amcheck: db1 clean 10 d ago -> 'amcheck older than 7 d' warning; db2 clean 20 d ago -> critical; db3 no run ->
#        'amcheck never clean' critical; db2 at the database level warn 30 / crit 60 -> nothing for db2
#     s6 an instance with databases and no amcheck run: no check row, one info finding 'amcheck never run'
#     s7 pg_stat_statements: dealloc 100 then 160 within a day under one stats_reset -> 'statements evicted' warning,
#        detail '60 eviction(s) in 24 h'; track none on another -> 'statement tracking off'
#     s8 rolechange: a primary read, then a standby read whose postmaster started between the reads -> one row
#        demotion, changed_at_source 'postmaster start'; a standby whose checkpoint timeline reads lower than before
#        -> no row
#     s9 retention: an RDS cloud row with retention 10: nothing; the root retention set to warn 14: 'retention under 14
#        days' warning (0022's rule with the UI threshold); reset: nothing. The archive-age line keeps its 0022 text
#        ('last archive older than 60 min') with no UI row.
#  U. the Go cases in a scratch copy of the tree (a test file written there, never in the tree): detectBackupTools on
#     nine commands, walSegmentsBetween, parseBarman / parseBarmanCloud on recorded answers, roleTimeline. go vet and
#     the collect and web packages' tests pass.
#  Z. both containers and their volumes gone.
#  [Run 1, box job s162-proof1, 2026-11-11 15:42 PST, PostgreSQL 18, load 14-17 on 16 CPUs: A and A2 as expected; A3
#  failed: no 'base backups' row 40 s after the full with full_backup_age at 0.01 h. Cause: the rule compared the age
#  rounded to a tenth of an hour (0.0) with the threshold. Fixed in 0103 (the rules compare unrounded seconds; amcheck
#  age had the same rounding), the expectation unchanged.]
#  [Run 2, s162-proof2, 15:45 PST, PG 18: every part as expected, PROOF OK. Run 3, s162-proof3, 15:50 PST: PROOF OK on 13
#  (A4 not run) and 16.]
#  [The review's fold (agent-runs/20261111-154515-reviewer), expected before run 4:
#   A3 one more refusal: archive_age warn 0.4 (whole minutes only).
#   A4 the barman answer as barman writes a failed and a running backup (no end, no size): 4 backups, the newest ended
#      one FAILED (20261111T110000): one 'newest backup failed' row, warning, object pg1; the FAILED and running ones
#      placed by their id's time; backup_count 4; after the reset the 4 stay present.
#   [Run 4, s162-proof4, 16:07 PST: PROOF OK on 13; on 18 and 16 A4 failed: the barman stand-in checked the old argument
#   list, and the fold puts '--' before the server name (the collector was right); the stand-in now expects
#   '-f json list-backups -- pg1'.]
#   S8 b: receiver timeline 1, checkpoint 1, receiver 2: exactly one 'timeline' row (1 -> 2); then checkpoint 1: no row,
#      the state stays on 2.
#   S9 b: the root retention at critical 12 alone: 'retention at or under 12 days' critical for retention 10.
#   S10 a pgBackRest read with status 99 (an unreadable repository) and no backup keeps both backups present and the
#      count 2; a read whose labels hold three names but whose backup rows are only the newest keeps the older two; a read
#      with status 2 (no valid backup) and no label marks them absent.
#   S11 full_backup_age at critical 0.5 h alone on an instance whose full ended an hour ago: one row, critical, 'full
#      backup older than 0.5 h'; amcheck_age at critical 5 d alone: db1 (10 d) critical.
#   S12 Patroni answered (one member), then failed (ok false): the member absent, the read row ok false.
#   U  more cases: a barman server name starting with '-' names no tool; --cloud-provider google-cloud-storage and an
#      --endpoint-url pass on as options, an unknown provider names no tool; keepBackups keeps an older full past the
#      newest 50; barman-cloud's ctime fields before 3.13; barman without backup_type is full; a failed barman backup is
#      placed by its id.]
set -euo pipefail
PG=${PG:-18}; RPG=${REPO_PG:-$PG}
IMG=pgvigil-proof-pgbackrest:$PG
WORK=$(mktemp -d); SUF=$(basename "$WORK" | tr -dc 'a-z0-9' | tail -c 8)
MON_CT=pgv162-mon-$SUF; REPO_CT=pgv162-repo-$SUF
SUPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))'); MON=pgv162mon; MONPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
REPO_DB=pgvigil_162_$SUF
CIDS=(); HTTPPID=""; SRVPID=""; HOLD=""
rc=0
cleanup() {
  set +e
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null
  [[ -n "$HTTPPID" ]] && kill "$HTTPPID" 2>/dev/null
  [[ -n "$HOLD" ]] && kill "$HOLD" 2>/dev/null
  for c in "${CIDS[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1; done
  local left=0
  for c in "${CIDS[@]}"; do docker inspect "$c" >/dev/null 2>&1 && left=$((left + 1)); done
  echo "Z: containers of this proof left: $left"
  [[ $left -eq 0 ]] || { echo "FAIL: Z: $left left" >&2; rc=1; }
  rm -rf "$WORK"
  exit $rc
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; rc=1; exit 1; }
ok() { echo "  OK $*"; }
for t in docker psql curl python3; do command -v "$t" >/dev/null || fail "$t is not on this machine"; done
echo "proof-pg-backups-roles: PostgreSQL $PG, repository $RPG; load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) CPUs"

BIN=${PGVIGIL_BIN:-}
if [[ -z "$BIN" ]]; then
  command -v go >/dev/null || fail "go is not on this machine and PGVIGIL_BIN is not set"
  BIN=$WORK/pgvigil
  CGO_ENABLED=0 go build -o "$BIN" ./cmd/pgvigil || fail "go build"
fi

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  docker build -q -t "$IMG" - >/dev/null <<EOF || fail "the image did not build (postgres:$PG plus pgbackrest from PGDG)"
FROM postgres:$PG
RUN apt-get update && apt-get install -y --no-install-recommends pgbackrest && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/lib/pgbackrest /var/log/pgbackrest /etc/pgbackrest && chown postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /etc/pgbackrest
EOF
fi
freeport() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
MPORT=$(freeport); SPORT=$(freeport); FPORT=$(freeport); RPORT=$(freeport); AP=$(freeport)
docker run -d --name "$MON_CT" -e POSTGRES_PASSWORD="$SUPW" -p "127.0.0.1:$MPORT:5432" -p "127.0.0.1:$SPORT:5433" -p "127.0.0.1:$FPORT:5434" "$IMG" \
  postgres -c wal_level=replica -c archive_mode=on -c "archive_command=pgbackrest --stanza=demo archive-push %p" -c logging_collector=on \
  -c "log_line_prefix=%m [%p] %q%u@%d " -c cluster_name=pv_primary -c archive_timeout=0 > "$WORK/mon.id" || fail "the monitored container did not start"
CIDS+=("$(cat "$WORK/mon.id")")
docker run -d --name "$REPO_CT" -e POSTGRES_PASSWORD="$SUPW" -p "127.0.0.1:$RPORT:5432" "postgres:$RPG" > "$WORK/repo.id" || fail "the repository container did not start"
CIDS+=("$(cat "$WORK/repo.id")")
SU="host=127.0.0.1 port=$MPORT user=postgres password=$SUPW dbname=postgres sslmode=disable"
RSU="host=127.0.0.1 port=$RPORT user=postgres password=$SUPW dbname=postgres sslmode=disable"
up() { local n=0; for _ in $(seq 1 120); do if psql "$1" -XAtqc 'select 1' >/dev/null 2>&1; then n=$((n + 1)); [[ $n -ge 2 ]] && return 0; else n=0; fi; sleep 1; done; return 1; }
up "$SU" || fail "the monitored server did not come up: $(docker logs "$MON_CT" 2>&1 | tail -5)"
up "$RSU" || fail "the repository server did not come up"
su() { psql "$SU" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
dx() { docker exec -u postgres "$MON_CT" "$@"; }
PGDATA_C=$(docker exec "$MON_CT" sh -c 'echo $PGDATA')
docker exec -u postgres "$MON_CT" sh -c "printf '[global]\nrepo1-path=/var/lib/pgbackrest\nrepo1-retention-full=4\nstart-fast=y\nlog-level-console=warn\nlog-level-file=off\n\n[demo]\npg1-path=$PGDATA_C\n' > /etc/pgbackrest/pgbackrest.conf"
su "create role $MON login password '$MONPW' in role pg_monitor"
export MON_DSN="host=127.0.0.1 port=$MPORT user=$MON password=$MONPW dbname=postgres sslmode=disable"
export SB_DSN="host=127.0.0.1 port=$SPORT user=$MON password=$MONPW dbname=postgres sslmode=disable"
export FS_DSN="host=127.0.0.1 port=$FPORT user=$MON password=$MONPW dbname=postgres sslmode=disable"
psql "$RSU" -XAtq -c "create database $REPO_DB" >/dev/null
export PGVIGIL_REPO_DSN="host=127.0.0.1 port=$RPORT user=postgres password=$SUPW dbname=$REPO_DB sslmode=disable"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
CFG=$WORK/pgvigil.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: pv-primary
    dsn: env:MON_DSN
    tags: [proofpg]
  - name: pv-standby
    dsn: env:SB_DSN
  - name: pv-fileship
    dsn: env:FS_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null || fail "migrate"
SHIM=$WORK/shim; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec docker exec -u postgres %s pgbackrest "$@"\n' "$MON_CT" > "$SHIM/pgbackrest"; chmod +x "$SHIM/pgbackrest"
NOSHIM_PATH=$PATH; SHIM_PATH=$SHIM:$PATH
collect() {   # instance collection [PATH]
  local out; out=$(PATH=${3:-$SHIM_PATH} "$BIN" collect -config "$CFG" -instance "$1" -once "$2" 2>&1) || { echo "$out" >&2; fail "collect $2 on $1"; }
}
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }

echo "--- A. pgBackRest"
dx pgbackrest --stanza=demo stanza-create >/dev/null || fail "A: stanza-create"
dx pgbackrest --stanza=demo --type=full backup >/dev/null || fail "A: full backup"
su "create table t162 as select g, md5(g::text) m from generate_series(1, 50000) g"
su "select pg_switch_wal()" >/dev/null; su "insert into t162 select g, 'x' from generate_series(1, 1000) g"; su "select pg_switch_wal()" >/dev/null
dx pgbackrest --stanza=demo --type=diff backup >/dev/null || fail "A: diff backup"
FULL_END=$(date +%s)
for _ in 1 2; do su "insert into t162 select g, 'y' from generate_series(1, 1000) g"; su "select pg_switch_wal()" >/dev/null; done
for _ in $(seq 1 30); do [[ $(su "select failed_count = 0 and last_archived_wal is not null from pg_stat_archiver") == t ]] && break; sleep 1; done
sleep 2
collect pv-primary instance; collect pv-primary backup_tools
P=$(iid pv-primary)
[[ $(q "select tools || '|' || archive_command_set || '|' || is_replica from pgvigil.pg_backup_detect where instance_id = $P") == "1|true|false" ]] || fail "A: detect: $(q "select * from pgvigil.pg_backup_detect where instance_id = $P")"
[[ $(q "select state || '|' || status_code || '|' || named_by || '|' || backup_count || '|' || (archive_max ~ '^[0-9A-F]{24}$') from pgvigil.pg_backup_tools where instance_id = $P and tool = 'pgbackrest' and name = 'demo'") == "ok|0|archive_command|2|true" ]] \
  || fail "A: tool row: $(q "select * from pgvigil.pg_backup_tools where instance_id = $P")"
[[ $(q "select string_agg(backup_type, ',' order by backup_type) from pgvigil.pg_base_backups where instance_id = $P and is_present") == "diff,full" ]] || fail "A: backup kinds"
FULL=$(q "select label from pgvigil.pg_base_backups where instance_id = $P and backup_type = 'full'")
OWN=$(PATH=$SHIM_PATH pgbackrest --output=json --stanza=demo info | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print([b['info']['size'] for b in d['backup'] if b['label']=='$FULL'][0])")
[[ $(q "select db_size_bytes from pgvigil.pg_base_backups where instance_id = $P and label = '$FULL'") == "$OWN" ]] || fail "A: the full's size is not pgbackrest's $OWN"
(( OWN > 1048576 )) || fail "A: the full is $OWN bytes"
[[ $(q "select prior from pgvigil.pg_base_backups where instance_id = $P and backup_type = 'diff'") == "$FULL" ]] || fail "A: the diff's prior"
[[ $(q "select (wal_since_segments >= 2 and wal_since_bytes = wal_since_segments * 16777216)::text from pgvigil.pg_base_backups where instance_id = $P and backup_type = 'diff'") == true ]] \
  || fail "A: WAL since: $(q "select wal_since_segments, wal_since_bytes from pgvigil.pg_base_backups where instance_id = $P and backup_type = 'diff'")"
[[ $(q "select last_type || '|' || (full_age_h < 1) || '|' || full_warn_h || '|' || full_level from pgvigil.pg_base_backup_status where instance_id = $P") == "diff|true|192|default" ]] || fail "A: status"
[[ $(q "select count(*) from pgvigil.pg_backups_checks where instance_id = $P and check_group = 'base backups'") == 0 ]] || fail "A: a check row on fresh backups"
ok "A: stanza demo, full $FULL of $OWN bytes, a diff on it, WAL since counted"

collect pv-primary backup_tools "$NOSHIM_PATH"
[[ $(q "select state || '|' || (message like '%archive_command%pgbackrest%') from pgvigil.pg_backup_tools where instance_id = $P and tool = 'pgbackrest'") == "no_binary|true" ]] || fail "A2: no_binary"
[[ $(q "select count(*) from pgvigil.pg_backups_findings where instance_id = $P and setting = 'pgbackrest not on the collector host' and severity = 'info'") == 1 ]] || fail "A2: the finding"
[[ $(q "select count(*) from pgvigil.pg_base_backups where instance_id = $P and is_present") == 2 ]] || fail "A2: backups lost on a missing binary"
[[ $(q "select count(*) from pgvigil.pg_backups_checks where instance_id = $P and check_group = 'base backups'") == 0 ]] || fail "A2: a missing binary made a check row"
ok "A2: no binary on the host: a finding, the backups kept"

thr() { q "select pgvigil.import_pg_threshold(now(), '$1'::jsonb)->>'outcome'"; }
[[ $(thr "{\"op\":\"set\",\"key\":\"full_backup_age\",\"level\":\"instance\",\"instance_id\":$P,\"warn\":\"0.01\",\"crit\":\"1000\",\"ui_user\":\"proof\"}") == done ]] || fail "A3: set"
while (( $(date +%s) - FULL_END < 40 )); do sleep 2; done
collect pv-primary backup_tools
[[ $(q "select severity || '|' || check_name || '|' || object from pgvigil.pg_backups_checks where instance_id = $P and check_group = 'base backups'") == "warning|full backup older than 0.01 h|demo" ]] \
  || fail "A3: $(q "select * from pgvigil.pg_backups_checks where instance_id = $P")"
for bad in "{\"op\":\"set\",\"key\":\"nope\",\"level\":\"root\",\"warn\":1}" "{\"op\":\"set\",\"key\":\"full_backup_age\",\"level\":\"database\",\"instance_id\":$P,\"datname\":\"postgres\",\"warn\":1}" \
           "{\"op\":\"set\",\"key\":\"full_backup_age\",\"level\":\"root\",\"warn\":\"abc\"}" "{\"op\":\"set\",\"key\":\"full_backup_age\",\"level\":\"root\",\"warn\":10,\"crit\":5}" \
           "{\"op\":\"inherit\",\"key\":\"uptime\",\"level\":\"root\"}" "{\"op\":\"set\",\"key\":\"archive_age\",\"level\":\"root\",\"warn\":\"0.4\"}"; do
  b=${bad%\}},\"ui_user\":\"proof\"}
  [[ $(thr "$b") == refused ]] || fail "A3: not refused: $b"
done
[[ $(q "select count(*) from pgvigil.pg_thresholds") == 1 ]] || fail "A3: a refusal wrote a row"
[[ $(thr "{\"op\":\"inherit\",\"key\":\"full_backup_age\",\"level\":\"instance\",\"instance_id\":$P,\"ui_user\":\"proof\"}") == done ]] || fail "A3: inherit"
collect pv-primary backup_tools
[[ $(q "select count(*) from pgvigil.pg_backups_checks where instance_id = $P and check_group = 'base backups'") == 0 ]] || fail "A3: the row stayed after inherit"
ok "A3: the instance threshold raised the row, six refusals, inherit cleared it"

if (( PG >= 14 )); then
  cat > "$SHIM/barman" <<'EOF'
#!/bin/sh
[ "$*" = "-f json list-backups -- pg1" ] || { echo "unexpected: $*" >&2; exit 2; }
cat <<'J'
{"pg1": [{"backup_id": "20261111T120000", "backup_type": "full", "status": "STARTED"},
 {"backup_id": "20261111T110000", "backup_type": "full", "status": "FAILED"},
 {"backup_id": "20261111T100000", "backup_type": "full", "end_time_timestamp": "1794391200", "end_time": "Wed Nov 11 10:00:00 2026", "size_bytes": 52428800, "wal_size_bytes": 16777216, "size": "50.0 MiB", "wal_size": "16.0 MiB", "status": "DONE", "retention_status": "VALID"},
 {"backup_id": "20261110T100000", "backup_type": "full", "status": "FAILED"}]}
J
EOF
  chmod +x "$SHIM/barman"
  su "alter system set restore_command = 'barman-wal-restore -U barman backuphost pg1 %f %p'"; su "select pg_reload_conf()" >/dev/null; sleep 1
  collect pv-primary backup_tools
  [[ $(q "select state || '|' || named_by || '|' || backup_count from pgvigil.pg_backup_tools where instance_id = $P and tool = 'barman' and name = 'pg1'") == "ok|restore_command|4" ]] \
    || fail "A4: $(q "select * from pgvigil.pg_backup_tools where instance_id = $P and tool = 'barman'")"
  R=$(q "select string_agg(label || ':' || status || ':' || coalesce(db_size_bytes::text, '-') || ':' || coalesce(to_char(stopped_at at time zone 'UTC', 'HH24'), '-'), ',' order by label) from pgvigil.pg_base_backups where instance_id = $P and tool = 'barman'")
  [[ $R == "20261110T100000:error:-:-,20261111T100000:ok:52428800:10,20261111T110000:error:-:-,20261111T120000:running:-:-" ]] || fail "A4: barman rows $R"
  [[ $(q "select to_char(started_at at time zone 'UTC', 'YYYYMMDD\"T\"HH24MISS') from pgvigil.pg_base_backups where instance_id = $P and label = '20261111T110000'") == 20261111T110000 ]] || fail "A4: the failed one not placed by its id"
  [[ $(q "select severity || '|' || object || '|' || detail from pgvigil.pg_backups_checks where instance_id = $P and check_name = 'newest backup failed'") == "warning|pg1|20261111T110000 (FAILED)" ]] \
    || fail "A4: newest failed: $(q "select * from pgvigil.pg_backups_checks where instance_id = $P and check_name = 'newest backup failed'")"
  su "alter system reset restore_command"; su "select pg_reload_conf()" >/dev/null; sleep 1
  collect pv-primary backup_tools
  [[ $(q "select is_present from pgvigil.pg_backup_tools where instance_id = $P and tool = 'barman'") == f ]] || fail "A4: barman still present"
  [[ $(q "select count(*) from pgvigil.pg_base_backups where instance_id = $P and tool = 'barman' and is_present") == 4 ]] || fail "A4: barman's backups dropped with the tool"
  ok "A4: barman named by restore_command, its states read, the newest failed one flagged, gone with the setting"
else
  echo "  A4: not run on PostgreSQL $PG (restore_command is a postmaster setting before 14)"
fi

echo "--- B. a role change"
dx pg_basebackup -h /var/run/postgresql -D /tmp/sb -R -X stream -c fast >/dev/null 2>&1 || fail "B: pg_basebackup"
dx sh -c "printf \"port = 5433\nlisten_addresses = '*'\ncluster_name = 'pv_standby'\narchive_mode = off\nlogging_collector = off\n\" >> /tmp/sb/postgresql.auto.conf"
dx pg_ctl -D /tmp/sb -l /tmp/sb.log -w -s start >/dev/null || fail "B: standby start: $(dx tail -5 /tmp/sb.log)"
up "$SB_DSN" || fail "B: the standby does not answer"
for _ in $(seq 1 30); do [[ $(psql "$SB_DSN" -XAtq -c "select status from pg_stat_wal_receiver") == streaming ]] && break; sleep 1; done
collect pv-standby instance; collect pv-standby rolechange; collect pv-primary rolechange
S=$(iid pv-standby)
[[ $(q "select is_replica || '|' || timeline_id || '|' || timeline_source from pgvigil.pg_role_state where instance_id = $S") == "true|1|wal receiver" ]] || fail "B: standby state $(q "select * from pgvigil.pg_role_state where instance_id = $S")"
[[ $(q "select (select system_identifier from pgvigil.pg_role_state where instance_id = $S) = (select system_identifier from pgvigil.pg_role_state where instance_id = $P)") == t ]] || fail "B: system identifiers differ"
psql "$SB_DSN" -XAtq -c "select 1" >/dev/null
psql "host=127.0.0.1 port=$SPORT user=postgres password=$SUPW dbname=postgres sslmode=disable" -XAtq -c "select pg_promote(true, 30)" >/dev/null || fail "B: pg_promote"
collect pv-standby rolechange
[[ $(q "select count(*) from pgvigil.pg_role_changes where instance_id = $S") == 1 ]] || fail "B: role change rows $(q "select count(*) from pgvigil.pg_role_changes where instance_id = $S")"
R=$(q "select change || '|' || from_role || '|' || to_role || '|' || from_timeline || '|' || to_timeline || '|' || changed_at_source || '|' || postmaster_restarted || '|' || coalesce(held_secs::text, 'null') || '|' || (changed_at between prev_read_at - interval '1 minute' and detected_at + interval '1 minute') from pgvigil.pg_role_changes where instance_id = $S")
[[ $R == "promotion|standby|primary|1|2|history file|false|null|true" ]] || fail "B: $R"
collect pv-standby rolechange
[[ $(q "select count(*) from pgvigil.pg_role_changes where instance_id = $S") == 1 ]] || fail "B: a second row on a quiet read"
[[ $(q "select (since = (select changed_at from pgvigil.pg_role_changes where instance_id = $S))::text from pgvigil.pg_role_state where instance_id = $S") == true ]] || fail "B: since"
ok "B: one promotion row, timeline 1 -> 2, its time from 00000002.history"

echo "--- C. log shipping"
dx sh -c 'mkdir -p /tmp/fs && chmod 700 /tmp/fs'
dx pgbackrest --stanza=demo --type=standby --pg1-path=/tmp/fs restore >/dev/null 2>&1 || fail "C: pgbackrest restore"
dx sh -c "printf \"port = 5434\nlisten_addresses = '*'\ncluster_name = 'pv_fileship'\narchive_mode = off\nlogging_collector = off\n\" >> /tmp/fs/postgresql.auto.conf"
dx pg_ctl -D /tmp/fs -l /tmp/fs.log -w -t 120 -s start >/dev/null || fail "C: file-fed standby start: $(dx tail -5 /tmp/fs.log)"
up "$FS_DSN" || fail "C: the file-fed standby does not answer"
collect pv-fileship instance; collect pv-fileship backup_tools; collect pv-fileship rolechange; collect pv-primary rolechange; collect pv-primary backups
F=$(iid pv-fileship)
[[ $(q "select is_replica || '|' || has_receiver || '|' || restore_command_set from pgvigil.pg_backup_detect where instance_id = $F") == "true|false|true" ]] || fail "C: detect $(q "select * from pgvigil.pg_backup_detect where instance_id = $F")"
[[ $(q "select named_by || '|' || state from pgvigil.pg_backup_tools where instance_id = $F and tool = 'pgbackrest' and name = 'demo'") == "restore_command|ok" ]] || fail "C: tool"
[[ $(q "select has_receiver || '|' || (replay_lsn is not null) from pgvigil.pg_wal_replay where instance_id = $F and is_present") == "false|true" ]] || fail "C: replay row"
[[ $(q "select primary_instance from pgvigil.pg_wal_replay_status where instance_id = $F") == pv-primary ]] || fail "C: the primary not found"
echo "  C: caught_up $(q "select caught_up from pgvigil.pg_wal_replay_status where instance_id = $F"), delay $(q "select round(replay_delay_secs) from pgvigil.pg_wal_replay where instance_id = $F") s (observed, not judged)"
ok "C: a file-fed standby: no receiver, restore_command names pgBackRest, its primary found"

echo "--- D. a crash"
DOOR=$(awk '/^const ServerlogDoorSQL = `/{f=1; sub(/^const ServerlogDoorSQL = `/, "")} f{ if (/`$/) { sub(/`$/, ""); print; exit } print }' internal/collect/serverlog.go)
[[ "$DOOR" == *pgvigil_read_log* ]] || fail "D: the door's text was not found in serverlog.go"
printf '%s\n' "${DOOR//<login>/$MON}" | psql "$SU" -XAtq -v ON_ERROR_STOP=1 >/dev/null || fail "D: the door"
collect pv-primary serverlog
psql "$SU" -XAtq -c "select pg_sleep(60)" >/dev/null 2>&1 & HOLD=$!
for _ in $(seq 1 20); do VP=$(su "select pid from pg_stat_activity where query = 'select pg_sleep(60)' limit 1"); [[ -n "$VP" ]] && break; sleep 0.5; done
[[ -n "$VP" ]] || fail "D: no backend to kill"
docker exec "$MON_CT" kill -SEGV "$VP"
wait "$HOLD" 2>/dev/null || true; HOLD=""
sleep 2; up "$SU" || fail "D: the server did not come back"
for _ in $(seq 1 10); do collect pv-primary serverlog; [[ $(q "select count(*) from pgvigil.pg_crashes where instance_id = $P") -ge 1 ]] && break; sleep 2; done
[[ $(q "select count(*) || '|' || max(signal) from pgvigil.pg_crashes where instance_id = $P") == "1|11" ]] || fail "D: crashes $(q "select at, signal, detail from pgvigil.pg_crashes where instance_id = $P")"
[[ $(q "select status from pgvigil.pg_crash_state where instance_id = $P") == critical ]] || fail "D: crash state"
[[ $(q "select severity from pgvigil.pg_backups_checks where instance_id = $P and check_group = 'crashes'") == critical ]] || fail "D: no critical crashes row"
[[ $(q "select pgvigil.import_ack(now(), '{\"op\":\"add\",\"kind\":\"ack\",\"instance_id\":$P,\"instance_name\":\"pv-primary\",\"check_key\":\"dumps\",\"ui_user\":\"proof\"}'::jsonb)->>'outcome'") == done ]] || fail "D: the ack"
[[ $(q "select acked_by || '|' || (select status || '|' || open_30d from pgvigil.pg_crash_state where instance_id = $P) from pgvigil.pg_crashes where instance_id = $P") == "proof|ok|0" ]] || fail "D: after the ack"
[[ $(q "select count(*) from pgvigil.pg_backups_checks where instance_id = $P and check_group = 'crashes'") == 0 ]] || fail "D: the row stayed after the ack"
ok "D: a SIGSEGV crash restart found once, critical, cleared by an acknowledgement"

echo "--- E. the statement store"
collect pv-primary extensions
[[ $(q "select available || '|' || preloaded from pgvigil.pg_stmt_store_state where instance_id = $P") == "true|false" ]] || fail "E: $(q "select * from pgvigil.pg_stmt_store_state where instance_id = $P")"
ok "E: pg_stat_statements available, not preloaded"

echo "--- F. uptime"
upc() { q "select coalesce(string_agg(severity || '|' || check_name, ','), 'none') from pgvigil.pg_backups_checks where instance_id = $P and check_group = 'uptime'"; }
[[ $(upc) == "critical|uptime under 12 h" ]] || fail "F: default $(upc)"
[[ $(thr "{\"op\":\"set\",\"key\":\"uptime\",\"level\":\"instance\",\"instance_id\":$P,\"warn\":0,\"crit\":0,\"ui_user\":\"proof\"}") == done ]] || fail "F: set"
[[ $(upc) == none ]] || fail "F: instance 0/0 $(upc)"
[[ $(thr "{\"op\":\"set\",\"key\":\"uptime\",\"level\":\"tag\",\"tag\":\"proofpg\",\"warn\":2000,\"crit\":1000,\"ui_user\":\"proof\"}") == done ]] || fail "F: tag"
[[ $(thr "{\"op\":\"inherit\",\"key\":\"uptime\",\"level\":\"instance\",\"instance_id\":$P,\"ui_user\":\"proof\"}") == done ]] || fail "F: inherit"
[[ $(upc) == "critical|uptime under 1000 h" && $(q "select threshold_level from pgvigil.pg_uptime_state where instance_id = $P") == tag ]] || fail "F: tag level $(upc)"
[[ $(thr "{\"op\":\"set\",\"key\":\"uptime\",\"level\":\"instance\",\"instance_id\":$P,\"warn\":0,\"crit\":0,\"ui_user\":\"proof\"}") == done ]] || fail "F: set again"
[[ $(upc) == none ]] || fail "F: the instance did not win over the tag $(upc)"
ok "F: default, instance, tag, the instance over the tag"

echo "--- I. Patroni"
if python3 -c 'import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(("127.0.0.1",8008)) else 1)'; then
  mkdir -p "$WORK/www"
  cat > "$WORK/www/cluster" <<'J'
{"scope": "pvdemo", "members": [{"name": "pg1", "role": "leader", "state": "running", "api_url": "http://127.0.0.1:8008/patroni", "host": "127.0.0.1", "port": 5432, "timeline": 2},
 {"name": "pg2", "role": "replica", "state": "streaming", "api_url": "http://127.0.0.2:8008/patroni", "host": "127.0.0.2", "port": 5432, "timeline": 2, "lag": 0}]}
J
  python3 -m http.server 8008 --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 & HTTPPID=$!
  sleep 1
  psql "$SB_DSN application_name='Patroni heartbeat'" -XAtq -c "select pg_sleep(30)" >/dev/null 2>&1 & HOLD=$!
  sleep 1
  collect pv-standby rolechange
  [[ $(q "select ok || '|' || members from pgvigil.pg_patroni_read where instance_id = $S") == "true|2" ]] || fail "I: read $(q "select * from pgvigil.pg_patroni_read where instance_id = $S")"
  [[ $(q "select string_agg(member || ':' || role || ':' || coalesce(lag_bytes::text, '-'), ',' order by member) from pgvigil.pg_patroni_members where instance_id = $S and is_present") == "pg1:leader:-,pg2:replica:0" ]] || fail "I: members"
  kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null || true; HOLD=""
  psql "host=127.0.0.1 port=$SPORT user=postgres password=$SUPW dbname=postgres sslmode=disable" -XAtq -c "select pg_terminate_backend(pid) from pg_stat_activity where application_name like 'Patroni%'" >/dev/null
  sleep 1; collect pv-standby rolechange
  [[ $(q "select count(*) from pgvigil.pg_patroni_members where instance_id = $S and is_present") == 0 ]] || fail "I: members stayed"
  ok "I: Patroni's /cluster read, two members, gone with the session"
else
  echo "  I: not run: 127.0.0.1:8008 is in use on this machine"
fi

echo "--- S. the rules on seeded rows"
seed() { q "select pgvigil.ensure_instance('$1-$SUF', 'onprem', 'x', ${2:-180000}, ${3:-false}, '{}')"; }
SYS=7000000000000000162
for n in s1 s2 s3 s4; do eval "I_$n=$(seed $n 180000 true)"; done
I_s4p=$(seed s4p)
for n in s1 s2 s3 s4; do eval "id=\$I_$n"; q "select pgvigil.import_rolechange($id, now(), '[{\"kind\":\"role\",\"is_replica\":true,\"timeline_id\":1,\"timeline_source\":\"checkpoint\",\"system_identifier\":\"$( [[ $n == s4 ]] && echo $SYS || echo 1$RANDOM )\",\"server_now\":\"$(date -u +%FT%TZ)\"}]')" >/dev/null; done
q "select pgvigil.import_rolechange($I_s4p, now(), '[{\"kind\":\"role\",\"is_replica\":false,\"timeline_id\":1,\"timeline_source\":\"wal file\",\"system_identifier\":\"$SYS\"}]')" >/dev/null
q "select pgvigil.import_backups($I_s4p, now(), '[{\"kind\":\"archiver\",\"name\":\"pg_stat_archiver\",\"archive_mode\":\"on\",\"archive_set\":true,\"archived_count\":5,\"last_archived_wal\":\"000000010000000000000005\",\"last_archived_time\":\"$(date -u +%FT%TZ)\",\"failed_count\":0,\"is_replica\":false,\"wal_segment_bytes\":16777216,\"archive_lag_bytes\":0}]')" >/dev/null
rep() { q "select pgvigil.import_backup_tools($1, now(), '[{\"kind\":\"detect\",\"is_replica\":true,\"has_receiver\":$2,\"restore_command_set\":true,\"tools\":0},{\"kind\":\"replay\",\"has_receiver\":$2,\"replay_delay_secs\":$3,\"replay_lsn\":\"$4\",\"last_replay_at\":\"$(date -u -d "-$(( ${3%.*} ))seconds" +%FT%TZ)\"}]')" >/dev/null; }
rep "$I_s1" false 5400 0/1000000; rep "$I_s2" false 18000 0/1000000; rep "$I_s3" true 18000 0/1000000; rep "$I_s4" false 18000 0/6000100
lsc() { q "select coalesce(string_agg(severity || '|' || check_name, ','), 'none') from pgvigil.pg_backups_checks where instance_id = $1 and check_group = 'log shipping'"; }
[[ $(lsc "$I_s1") == "warning|replay delay over 60 min" ]] || fail "S1 $(lsc "$I_s1")"
[[ $(lsc "$I_s2") == "critical|replay delay over 60 min" ]] || fail "S2 $(lsc "$I_s2")"
[[ $(lsc "$I_s3") == none ]] || fail "S3 $(lsc "$I_s3")"
[[ $(lsc "$I_s4") == none && $(q "select caught_up from pgvigil.pg_wal_replay_status where instance_id = $I_s4") == t ]] || fail "S4 $(lsc "$I_s4") caught_up $(q "select caught_up from pgvigil.pg_wal_replay_status where instance_id = $I_s4")"
ok "S1-S4: log shipping's rule"
I_s5=$(seed s5); I_s6=$(seed s6)
q "insert into pgvigil.databases (instance_id, dbid, datname, snapshot_at, first_seen, is_template, is_present) values ($I_s5, 1, 'db1', now(), now(), false, true), ($I_s5, 2, 'db2', now(), now(), false, true), ($I_s5, 3, 'db3', now(), now(), false, true), ($I_s6, 1, 'db1', now(), now(), false, true)" >/dev/null
for x in "db1 10" "db2 20"; do set -- $x
  q "select pgvigil.import_amcheck($I_s5, now() - interval '$2 days', '[{\"kind\":\"run\",\"datname\":\"$1\",\"check_name\":\"bt_index_check\",\"status\":\"ok\",\"checked\":3,\"total\":3,\"corrupt\":0,\"errors\":0}]')" >/dev/null; done
amc() { q "select coalesce(string_agg(object || '|' || severity || '|' || check_name, ',' order by object), 'none') from pgvigil.pg_backups_checks where instance_id = $1 and check_group = 'amcheck age'"; }
[[ $(amc "$I_s5") == "db1|warning|amcheck older than 7 d,db2|critical|amcheck older than 7 d,db3|critical|amcheck never clean" ]] || fail "S5 $(amc "$I_s5")"
[[ $(thr "{\"op\":\"set\",\"key\":\"amcheck_age\",\"level\":\"database\",\"instance_id\":$I_s5,\"datname\":\"db2\",\"warn\":30,\"crit\":60,\"ui_user\":\"proof\"}") == done ]] || fail "S5: set"
[[ $(amc "$I_s5") == "db1|warning|amcheck older than 7 d,db3|critical|amcheck never clean" ]] || fail "S5 db level $(amc "$I_s5")"
[[ $(amc "$I_s6") == none && $(q "select count(*) from pgvigil.pg_backups_findings where instance_id = $I_s6 and setting = 'amcheck never run' and severity = 'info'") == 1 ]] || fail "S6"
ok "S5-S6: amcheck age"
I_s7=$(seed s7); I_s7b=$(seed s7b)
RS=$(date -u -d '-2 days' +%FT%TZ)
q "insert into pgvigil.statements_info (instance_id, snapshot_at, dealloc, stats_reset) values ($I_s7, now() - interval '12 hours', 100, '$RS'), ($I_s7, now() - interval '1 minute', 160, '$RS')" >/dev/null
q "insert into pgvigil.instance_extension_settings (instance_id, name, snapshot_at, setting) values ($I_s7, 'pg_stat_statements.max', now(), '5000'), ($I_s7b, 'pg_stat_statements.track', now(), 'none')" >/dev/null
[[ $(q "select check_name || '|' || detail from pgvigil.pg_backups_checks where instance_id = $I_s7 and check_group = 'statement store'") == "statements evicted|60 eviction(s) in 24 h: pg_stat_statements.max (5000) is too small for the statements run" ]] || fail "S7 $(q "select * from pgvigil.pg_backups_checks where instance_id = $I_s7")"
[[ $(q "select check_name from pgvigil.pg_backups_checks where instance_id = $I_s7b and check_group = 'statement store'") == "statement tracking off" ]] || fail "S7 track"
ok "S7: the statement store's two rules"
I_s8=$(seed s8); I_s8b=$(seed s8b 180000 true)
T0=$(date -u -d '-10 minutes' +%FT%TZ); T1=$(date -u -d '-5 minutes' +%FT%TZ); TM=$(date -u -d '-7 minutes' +%FT%TZ)
q "select pgvigil.import_rolechange($I_s8, '$T0', '[{\"kind\":\"role\",\"is_replica\":false,\"timeline_id\":3,\"timeline_source\":\"wal file\",\"system_identifier\":\"88\",\"postmaster_start\":\"$(date -u -d '-3 days' +%FT%TZ)\",\"server_now\":\"$T0\"}]')" >/dev/null
q "select pgvigil.import_rolechange($I_s8, '$T1', '[{\"kind\":\"role\",\"is_replica\":true,\"timeline_id\":3,\"timeline_source\":\"wal receiver\",\"system_identifier\":\"88\",\"postmaster_start\":\"$TM\",\"server_now\":\"$T1\"}]')" >/dev/null
[[ $(q "select change || '|' || changed_at_source || '|' || (changed_at = '$TM'::timestamptz) || '|' || postmaster_restarted from pgvigil.pg_role_changes where instance_id = $I_s8") == "demotion|postmaster start|true|true" ]] || fail "S8 demotion"
q "select pgvigil.import_rolechange($I_s8b, now() - interval '2 minutes', '[{\"kind\":\"role\",\"is_replica\":true,\"timeline_id\":4,\"timeline_source\":\"checkpoint\",\"system_identifier\":\"89\"}]')" >/dev/null
q "select pgvigil.import_rolechange($I_s8b, now(), '[{\"kind\":\"role\",\"is_replica\":true,\"timeline_id\":3,\"timeline_source\":\"checkpoint\",\"system_identifier\":\"89\"}]')" >/dev/null
[[ $(q "select count(*) from pgvigil.pg_role_changes where instance_id = $I_s8b") == 0 && $(q "select timeline_id from pgvigil.pg_role_state where instance_id = $I_s8b") == 4 ]] || fail "S8 a lower checkpoint timeline"
I_s8c=$(seed s8c 180000 true)
rc8() { q "select pgvigil.import_rolechange($I_s8c, now() - interval '$1 seconds', '[{\"kind\":\"role\",\"is_replica\":true,\"timeline_id\":$2,\"timeline_source\":\"$3\",\"system_identifier\":\"90\"}]')" >/dev/null; }
rc8 40 1 "wal receiver"; rc8 30 1 checkpoint; rc8 20 2 "wal receiver"; rc8 10 1 checkpoint
[[ $(q "select count(*) || '|' || max(change) || '|' || max(from_timeline) || '|' || max(to_timeline) from pgvigil.pg_role_changes where instance_id = $I_s8c") == "1|timeline|1|2" \
   && $(q "select timeline_id from pgvigil.pg_role_state where instance_id = $I_s8c") == 2 ]] || fail "S8b: $(q "select change, from_timeline, to_timeline from pgvigil.pg_role_changes where instance_id = $I_s8c")"
ok "S8: a demotion timed by the restart, a trailing checkpoint timeline ignored, a rise across a source switch counted once"
I_s9=$(q "select pgvigil.ensure_instance('s9-$SUF', 'rds', 'x', 160000, false, '{}')")
q "select pgvigil.import_backups($I_s9, now(), '[{\"kind\":\"archiver\",\"name\":\"pg_stat_archiver\",\"archive_mode\":\"on\",\"archive_set\":true,\"is_replica\":false,\"wal_segment_bytes\":16777216,\"archive_lag_bytes\":0,\"archive_warn_minutes\":60},{\"kind\":\"cloud\",\"name\":\"db-s9\",\"resource_kind\":\"instance\",\"retention_days\":10},{\"kind\":\"snapshots_read\",\"name\":\"snapshots\",\"count\":0}]')" >/dev/null
ret() { q "select coalesce(string_agg(severity || '|' || check_name, ','), 'none') from pgvigil.backup_rule_hits where instance_id = $I_s9 and check_name like 'retention%'"; }
[[ $(ret) == none ]] || fail "S9 default $(ret)"
[[ $(thr "{\"op\":\"set\",\"key\":\"retention\",\"level\":\"root\",\"warn\":14,\"ui_user\":\"proof\"}") == done ]] || fail "S9 set"
[[ $(ret) == "warning|retention under 14 days" ]] || fail "S9 UI $(ret)"
[[ $(q "select count(*) from pgvigil.backup_findings where instance_id = $I_s9 and setting = 'retention under 14 days' and suggested like '%14 days%'") == 1 ]] || fail "S9 finding"
[[ $(thr "{\"op\":\"inherit\",\"key\":\"retention\",\"level\":\"root\",\"ui_user\":\"proof\"}") == done && $(ret) == none ]] || fail "S9 reset"
[[ $(q "select archive_warn_minutes from pgvigil.backup_status where instance_id = $I_s9") == 60 ]] || fail "S9 archive age"
[[ $(thr "{\"op\":\"set\",\"key\":\"retention\",\"level\":\"root\",\"crit\":12,\"ui_user\":\"proof\"}") == done ]] || fail "S9b set"
[[ $(ret) == "critical|retention at or under 12 days" ]] || fail "S9b $(ret)"
[[ $(thr "{\"op\":\"inherit\",\"key\":\"retention\",\"level\":\"root\",\"ui_user\":\"proof\"}") == done ]] || fail "S9b reset"
ok "S9: retention from the UI (a warning, a critical alone), 0022's lines kept"
I_s10=$(seed s10)
bt() { q "select pgvigil.import_backup_tools($I_s10, now(), '$1')" >/dev/null; }
B1='{"kind":"backup","tool":"pgbackrest","name":"st","label":"L1","backup_type":"full","status":"ok","stopped_at":"2026-11-10T00:00:00Z"}'
B2='{"kind":"backup","tool":"pgbackrest","name":"st","label":"L2","backup_type":"incr","status":"ok","stopped_at":"2026-11-11T00:00:00Z"}'
B3='{"kind":"backup","tool":"pgbackrest","name":"st","label":"L3","backup_type":"incr","status":"ok","stopped_at":"2026-11-11T12:00:00Z"}'
DT='{"kind":"detect","is_replica":false,"tools":1}'
bt "[$DT,{\"kind\":\"tool\",\"tool\":\"pgbackrest\",\"name\":\"st\",\"state\":\"ok\",\"status_code\":0,\"backup_count\":2,\"labels\":[\"L1\",\"L2\"]},$B1,$B2]"
bt "[$DT,{\"kind\":\"tool\",\"tool\":\"pgbackrest\",\"name\":\"st\",\"state\":\"error\",\"status_code\":99,\"status_message\":\"other\",\"backup_count\":0,\"labels\":[]}]"
[[ $(q "select count(*) filter (where is_present) || '|' || (select backup_count from pgvigil.pg_backup_tools where instance_id = $I_s10) from pgvigil.pg_base_backups where instance_id = $I_s10") == "2|2" ]] || fail "S10 status 99 dropped the backups"
bt "[$DT,{\"kind\":\"tool\",\"tool\":\"pgbackrest\",\"name\":\"st\",\"state\":\"ok\",\"status_code\":0,\"backup_count\":3,\"labels\":[\"L1\",\"L2\",\"L3\"]},$B3]"
[[ $(q "select count(*) filter (where is_present) from pgvigil.pg_base_backups where instance_id = $I_s10") == 3 ]] || fail "S10 the labels list"
bt "[$DT,{\"kind\":\"tool\",\"tool\":\"pgbackrest\",\"name\":\"st\",\"state\":\"error\",\"status_code\":2,\"status_message\":\"no valid backups\",\"backup_count\":0,\"labels\":[]}]"
[[ $(q "select count(*) filter (where is_present) from pgvigil.pg_base_backups where instance_id = $I_s10") == 0 ]] || fail "S10 status 2 kept them"
ok "S10: an unreadable repository keeps the backups, the labels list judges absence, status 2 ends them"
I_s11=$(seed s11)
q "select pgvigil.import_backup_tools($I_s11, now(), '[$DT,{\"kind\":\"tool\",\"tool\":\"pgbackrest\",\"name\":\"st\",\"state\":\"ok\",\"status_code\":0,\"labels\":[\"F1\"]},{\"kind\":\"backup\",\"tool\":\"pgbackrest\",\"name\":\"st\",\"label\":\"F1\",\"backup_type\":\"full\",\"status\":\"ok\",\"stopped_at\":\"$(date -u -d '-1 hour' +%FT%TZ)\"}]')" >/dev/null
bbc() { q "select coalesce(string_agg(severity || '|' || check_name, ','), 'none') from pgvigil.pg_backups_checks where instance_id = $I_s11 and check_group = 'base backups'"; }
[[ $(bbc) == none ]] || fail "S11 default $(bbc)"
[[ $(thr "{\"op\":\"set\",\"key\":\"full_backup_age\",\"level\":\"instance\",\"instance_id\":$I_s11,\"crit\":\"0.5\",\"ui_user\":\"proof\"}") == done ]] || fail "S11 set"
[[ $(bbc) == "critical|full backup older than 0.5 h" ]] || fail "S11 $(bbc)"
[[ $(thr "{\"op\":\"set\",\"key\":\"amcheck_age\",\"level\":\"instance\",\"instance_id\":$I_s5,\"crit\":5,\"ui_user\":\"proof\"}") == done ]] || fail "S11 amcheck set"
[[ $(q "select severity || '|' || check_name from pgvigil.pg_backups_checks where instance_id = $I_s5 and object = 'db1' and check_group = 'amcheck age'") == "critical|amcheck older than 5 d" ]] || fail "S11 amcheck $(amc "$I_s5")"
ok "S11: a critical alone judges the full backup's age and amcheck's"
I_s12=$(seed s12)
ROLE12='{"kind":"role","is_replica":false,"timeline_id":1,"timeline_source":"wal file","system_identifier":"91"}'
q "select pgvigil.import_rolechange($I_s12, now(), '[$ROLE12,{\"kind\":\"patroni_read\",\"url\":\"u\",\"ok\":true,\"members\":1,\"scope\":\"sc\"},{\"kind\":\"patroni\",\"member\":\"m1\",\"role\":\"leader\",\"state\":\"running\"}]')" >/dev/null
q "select pgvigil.import_rolechange($I_s12, now(), '[$ROLE12,{\"kind\":\"patroni_read\",\"url\":\"u\",\"ok\":false,\"message\":\"connection refused\"}]')" >/dev/null
[[ $(q "select (select count(*) from pgvigil.pg_patroni_members where instance_id = $I_s12 and is_present) || '|' || ok from pgvigil.pg_patroni_read where instance_id = $I_s12") == "0|false" ]] || fail "S12"
ok "S12: a failed Patroni read takes its members away"

echo "--- H. the web side"
U="http://127.0.0.1:$AP"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN -listen "127.0.0.1:$AP" -no-login >"$WORK/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
js() { curl -fsS "$U/api/$1" | python3 -c "import json,sys
d=json.load(sys.stdin)
def rows(k):
    t=d.get(k) or {'columns':[],'rows':[]}; return [dict(zip(t['columns'],r)) for r in t['rows']]
$2"; }
[[ $(js "pg/backups?instance=$P" "print(len(d), len(rows('tools')) >= 1)") == "6 True" ]] || fail "H: pg/backups"
[[ $(js "pg/state?instance=$S" "print(len(d), len(rows('changes')))") == "10 1" ]] || fail "H: pg/state"
[[ $(js "pg/replication" "print(sorted(r['instance'] for r in rows('links') if r['instance'].startswith('pv-')))") == "['pv-fileship', 'pv-primary', 'pv-standby']" ]] || fail "H: pg/replication"
[[ $(js "pg/thresholds" "print(len(rows('keys')))") == 8 ]] || fail "H: pg/thresholds"
[[ $(js "pg/backups/fleet" "print(len(rows('tools')) >= 1)") == True ]] || fail "H: pg/backups/fleet"
[[ $(js "overview" "print(any(r['check_group']=='uptime' for r in rows('x') or [dict(zip(d['columns'],r)) for r in d['rows']]))") == True ]] || fail "H: overview"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Pgvigil: 1' -d '{}' "$U/api/pg/thresholds") == 403 ]] || fail "H: a write without the login"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "$U/api/pg/thresholds") == 403 ]] || fail "H: a write without the header"
ok "H: five reads answer, the write door refuses without the login"

echo "--- U. the Go cases"
UT=$WORK/u; mkdir -p "$UT"; tar --exclude=./web/node_modules --exclude=./.git -cf - . | tar -C "$UT" -xf -
cat > "$UT/internal/collect/zz_proof162_test.go" <<'GO'
package collect

import (
	"testing"
	"time"
)

func TestProof162Detect(t *testing.T) {
	cases := []struct{ arch, rest, want string }{
		{"pgbackrest --stanza=main archive-push %p", "", "pgbackrest:main:archive_command"},
		{"/usr/bin/pgbackrest --config=/etc/x.conf --stanza main archive-push %p", "", "pgbackrest:main:archive_command"},
		{"(disabled)", "pgbackrest --stanza=demo archive-get %f \"%p\"", "pgbackrest:demo:restore_command"},
		{"barman-wal-archive backup pg1 %p", "", "barman:pg1:archive_command"},
		{"barman-wal-archive -U barman --port 2222 backup pg2 %p", "", "barman:pg2:archive_command"},
		{"barman-wal-archive -z backup pg3 %p", "", "barman:pg3:archive_command"},
		{"rsync -a %p barman@backup:/var/lib/barman/pg4/incoming/%f", "", "barman:pg4:archive_command"},
		{"barman-cloud-wal-archive --cloud-provider aws-s3 s3://bucket/path pg5 %p", "", "barman-cloud:pg5:archive_command"},
		{"cp %p /mnt/archive/%f", "", ""},
		{"barman-wal-archive backuphost --version %p", "", ""},
		{"barman-cloud-wal-archive --cloud-provider nope s3://b/p pg6 %p", "", ""},
	}
	for _, c := range cases {
		got := ""
		for _, b := range detectBackupTools(c.arch, c.rest) {
			got = b.tool + ":" + b.name + ":" + b.from
			break
		}
		if got != c.want {
			t.Errorf("%q / %q: %q, want %q", c.arch, c.rest, got, c.want)
		}
	}
}

func TestProof162CloudOptions(t *testing.T) {
	b := detectBackupTools("barman-cloud-wal-archive --cloud-provider=google-cloud-storage --endpoint-url https://minio.local:9000 gs://bkt/pg pg1 %p", "")
	if len(b) != 1 || b[0].url != "gs://bkt/pg" || b[0].name != "pg1" || len(b[0].opts) != 2 ||
		b[0].opts[0] != "--cloud-provider=google-cloud-storage" || b[0].opts[1] != "--endpoint-url=https://minio.local:9000" {
		t.Fatalf("cloud options: %+v", b)
	}
}

func TestProof162Keep(t *testing.T) {
	var rows []Row
	for i := 0; i < 60; i++ {
		typ := "incr"
		if i == 55 {
			typ = "full"
		}
		rows = append(rows, Row{"label": i, "backup_type": typ, "status": "ok"})
	}
	k := keepBackups(rows, 50)
	if len(k) != 51 || k[50]["label"] != 55 {
		t.Fatalf("kept %d, last %v", len(k), k[len(k)-1]["label"])
	}
}

func TestProof162Segments(t *testing.T) {
	seg := int64(16 << 20)
	if n, ok := walSegmentsBetween("000000010000000000000003", "000000010000000100000002", seg); !ok || n != 255 {
		t.Errorf("across a log file: %d %v", n, ok)
	}
	if n, ok := walSegmentsBetween("000000010000000000000009", "000000010000000000000003", seg); !ok || n != 0 {
		t.Errorf("behind: %d %v", n, ok)
	}
	if _, ok := walSegmentsBetween("x", "000000010000000000000003", seg); ok {
		t.Error("a bad name passed")
	}
}

func TestProof162Barman(t *testing.T) {
	rows, err := parseBarman([]byte(`{"pg1":[{"backup_id":"A","backup_type":"incremental","status":"DONE","end_time_timestamp":"1762855200","size_bytes":10,"wal_size_bytes":5}]}`), "pg1")
	if err != nil || len(rows) != 1 || rows[0]["backup_type"] != "incremental" || rows[0]["status"] != "ok" {
		t.Fatalf("barman: %v %v", rows, err)
	}
	if at, _ := rows[0]["stopped_at"].(time.Time); at.Unix() != 1762855200 {
		t.Errorf("end time %v", rows[0]["stopped_at"])
	}
	if _, err := parseBarman([]byte(`{"other":[]}`), "pg1"); err == nil {
		t.Error("a missing server passed")
	}
	cl, err := parseBarmanCloud([]byte(`{"backups_list":[{"backup_id":"B","status":"DONE","mode":"concurrent","begin_time_iso":"2026-11-11T10:00:00+00:00","end_time_iso":"2026-11-11T10:05:00+00:00","size":99,"begin_wal":"000000010000000000000002","end_wal":"000000010000000000000003"}]}`), "pg5")
	if err != nil || len(cl) != 1 || cl[0]["db_size_bytes"].(*int64) == nil || *cl[0]["db_size_bytes"].(*int64) != 99 {
		t.Fatalf("barman-cloud: %v %v", cl, err)
	}
}

func TestProof162BarmanOld(t *testing.T) {
	cl, err := parseBarmanCloud([]byte(`{"backups_list":[{"backup_id":"C","status":"DONE","begin_time":"Wed Nov 11 10:00:00 2026","end_time":"Wed Nov 11 10:05:00 2026"}]}`), "pg5")
	if err != nil || len(cl) != 1 || cl[0]["backup_type"] != "full" {
		t.Fatalf("barman-cloud before 3.13: %v %v", cl, err)
	}
	if at, _ := cl[0]["stopped_at"].(time.Time); at.Format(time.RFC3339) != "2026-11-11T10:05:00Z" {
		t.Errorf("ctime end %v", cl[0]["stopped_at"])
	}
	b, err := parseBarman([]byte(`{"pg1":[{"backup_id":"20261111T110000","status":"FAILED"},{"backup_id":"X","status":"DONE","end_time_timestamp":"1794391200"}]}`), "pg1")
	if err != nil || len(b) != 2 {
		t.Fatalf("barman: %v %v", b, err)
	}
	for _, r := range b {
		if r["backup_type"] != "full" {
			t.Errorf("%v: type %v", r["label"], r["backup_type"])
		}
		if r["label"] == "20261111T110000" {
			if at, _ := r["started_at"].(time.Time); at.Format(time.RFC3339) != "2026-11-11T11:00:00Z" || r["status"] != "error" {
				t.Errorf("the failed one: %v %v", r["started_at"], r["status"])
			}
		}
	}
}

func TestProof162Timeline(t *testing.T) {
	ck := int64(3)
	if v, s := roleTimeline(false, int64(5), nil, &ck); v != int64(5) || s != "wal file" {
		t.Errorf("primary %v %s", v, s)
	}
	if v, s := roleTimeline(true, nil, int32(4), &ck); v != int64(4) || s != "wal receiver" {
		t.Errorf("standby %v %s", v, s)
	}
	if v, s := roleTimeline(true, nil, nil, &ck); v != int64(3) || s != "checkpoint" {
		t.Errorf("file-fed %v %s", v, s)
	}
}
GO
(cd "$UT" && go vet ./internal/collect ./internal/web && go test ./internal/collect ./internal/web -count=1 -run 'Proof162|.' >"$WORK/u.log" 2>&1) || { tail -30 "$WORK/u.log"; fail "U: go vet / go test"; }
grep -q '^ok' "$WORK/u.log" || { cat "$WORK/u.log"; fail "U"; }
ok "U: the Go cases, vet and the packages' tests"
echo "PROOF OK"
