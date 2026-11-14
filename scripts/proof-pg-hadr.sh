#!/usr/bin/env bash
# proof-pg-hadr.sh - PostgreSQL streaming replication health on a real primary / standby pair (tasks 370-372, 374;
# migration 0141, internal/collect/replication.go). Needs: docker, psql, go (unless PGVIGIL_BIN names a built binary).
#
# The rig: a docker network with a repository (PostgreSQL 18), a primary (PostgreSQL 18, cluster_name hadrp, WAL archived
# to a shared volume) and a streaming standby made from it with pg_basebackup -R -X stream (cluster_name hadrs1, the same
# archive as its restore_command). pgvigil collects both through a login that holds pg_monitor only (instances hadr-p,
# hadr-s); each 'read' below is one `pgvigil collect -once replication` (a second read follows a few seconds later
# where a rule needs two reads in a row).
#
# Expected, written before each run: task 370's rows 2026-11-14 09:2x PST, task 371's rows and the 370 review fold
# 10:0x PST. Each row says what the red tree 35e627e (before task 370) gives: [red FAIL] - the rule, view or key is not
# there - or [red ok] (a rule that does not exist cannot raise; a read that does not need 0141).
#   B    the healthy pair: hadr-s's receiver row 'streaming'; hadr-p's sender row of application_name hadrs1 'streaming';
#        no 'receiver down', 'standby gone' or 'sender not streaming' anywhere [red ok]
#   A0   no 'amcheck never run' finding on hadr-p (no databases collection read: 0103's arm needs a present database;
#        0141 re-creates that view) [red ok on 35e627e; red FAIL on ee6d061, whose copy lost the arm's last two filters -
#        run red in pdfp-hadr-s1-redfoldee; A0 proves the present-database filter live, the amcheck_runs filter by the
#        line-by-line text check only]
#   L1   ONE row of pg_repl_link_health for link app:hadrs1@<address>: source sender, sending hadr-p, standby hadr-s,
#        status streaming, no finding [red FAIL: no view]
#   R1   task 370 (a): pg_basebackup -X stream --no-slot at 32 kB/s from a third container (its WAL streamer has no slot:
#        only its name keeps it from being a link), two reads of hadr-p while it runs: a stored sender row in state
#        'backup' [red ok]; no 'sender not streaming' naming pg_basebackup [red FAIL; since 371 that rule judges
#        logical senders only, so it cannot fail on the tip]; no link row for pg_basebackup [red FAIL: no view; on 7636cca
#        ok - the fold's row: it holds the name clause of pg_link_sender]
#   R1N  the same with PGAPPNAME=bbcustom and a slot (no default name to go by: its state and its temporary slot): the
#        read stored bbcustom's two senders, one in state backup and one on a temporary slot [red ok]; no 'sender not
#        streaming' naming bbcustom while it runs [red FAIL], no link row for bbcustom [red FAIL: no view]; killed, two
#        reads: no 'standby gone' for it [red ok]
#   R1B  the base backups killed, two reads of hadr-p: no 'standby gone' for pg_basebackup [red ok]
#   R2W  task 370 (b): the standby's receiver killed and held down (the primary's pg_hba rejects the standby's address),
#        writes and pg_switch_wal every 2 s so replay advances through restore_command, two reads of hadr-s 10 s apart:
#        'receiver down' warning on hadr-s in pgvigil.findings, replication_checks' detail 'advances through
#        restore_command' [red FAIL x2]
#   L7   then hadr-p read twice and hadr-s once: 'receiver down' on hadr-s and NO 'standby gone' on hadr-p (one finding
#        per link: the standby read since its sender vanished speaks for the link) [red FAIL: 370 alone raised both]
#   R2C  'restore_stall' set to 1 min on hadr-s (import_pg_threshold: done), the writes stopped, a read 15 s later (a
#        move is dated by the read that sees it), 70 s, a read: 'receiver down' critical, replication_checks' detail
#        'replay has stopped', the finding's value non-empty and the same as R2W's (one alert key) [red FAIL x4]
#   R2X  the reject line removed, the receiver streaming, two reads of hadr-s (one read with a receiver holds the fault:
#        a receiver that connects and then fails shows its row a moment every retry): 'receiver down' gone [red ok]
#   G    hadr-s read with 'platform: rds' in its config while held down again (two reads): no 'receiver down' [red ok];
#        the plain config, one read: raised again [red FAIL]
#   NS   then hadr-s read twice through a login holding pg_read_all_stats and pg_stat_scan_tables but not
#        pg_read_all_settings: its standby row stored with conninfo_set unknown (null) [red FAIL: no standby row] and no
#        'receiver down' (unknown is not judged) [red ok]; the hold lifted after
#   L3T  replay stalled on the standby (a standby session holds a lock that a replayed ACCESS EXCLUSIVE needs;
#        max_standby_streaming_delay -1) with an insert a second on the primary for 40 s (a stuck apply position reports
#        a growing replay_lag): one read of hadr-p raises nothing (one read is no pair) [red ok], the next 'standby lag'
#        warning on hadr-p naming hadrs1, its detail replay_lag and no bytes (under 50 MB) [red FAIL x2]
#   L2W  still stalled, past 60 MB written, two reads of hadr-p: 'standby lag' warning naming hadrs1, its detail the
#        bytes not yet replayed [red FAIL x2]; hadr-s read too: no 'standby lag' on it [red ok]
#   L2C  past 110 MB, two more reads: 'standby lag' critical on hadr-p [red FAIL]
#   L2S  hadr-p's links made stale in the repository (checked_at an hour back: a stand-in for a primary not read), two
#        reads of hadr-s: 'standby lag' critical on hadr-s judged on 'received - replayed on the standby' [red FAIL x2],
#        none on hadr-p [red ok]
#   L2X  the lock released, replay caught up and its replay_lag cleared (NULL), hadr-p and hadr-s read once: no
#        'standby lag' anywhere [red ok]
#   L3D  recovery_min_apply_delay 60 s on the standby, an insert a second for 75 s, hadr-s read, hadr-p read twice: the
#        primary's replay_lag 30 s or more (the default 30 s tier alone would warn) [red ok] and no 'standby lag' [red
#        ok]; the delay removed after
#   L6   a physical slot hadr_spare and synchronous_standby_names 'FIRST 1 (hadrs1, hadr_absent)', one read of hadr-p:
#        link rows slot:hadr_spare 'missing: physical slot inactive' (no finding) and app:hadr_absent 'missing: named in
#        synchronous_standby_names'; hadrs1's link sync_state sync [red FAIL x3: no view]
#   S3   task 372, in L6: app:hadr_absent's row carries 'synchronous standby absent' warning on hadr-p (num_sync 1 holds:
#        hadrs1 is sync) [red FAIL on 255f44c: the row is there, with no finding] and no 'synchronous commits waiting'
#        [red ok]; L6 and S3 undone after (marks corrected after the review: 372red showed the row without a finding)
# Task 372 (written before its first run, 2026-11-14 10:4x PST):
#   P    pg_sync_standbys: '2 (a, b)' FIRST 2 {a,b}; 'a, b' FIRST 1 {a,b}; 'ANY 1 (*)' 'ANY *' 1 no names;
#        '"Quoted", b' FIRST 1 {Quoted,b}; 'first 3 (x)' FIRST 3 {x}; '*' 'FIRST *' 1; '' nothing [red FAIL on 35e627e: no
#        function - run red in pdfp-hadr-s1-redfold35; red ok on 255f44c: the function came with task 371]
#   S1   synchronous_standby_names 'FIRST 1 (hadrs1)', hadrs1 sync, one read of hadr-p: no 'synchronous commits waiting'
#        [red ok]
#   S2   the receiver held down: an insert on the primary waits (a session in wait_event SyncRep, watched), one read of
#        hadr-p: 'synchronous commits waiting' critical, its detail naming hadrs1 not connected and that every commit
#        waits [red FAIL x2]; S2X the hold lifted: the waiting insert completes, one read: gone [red ok]
#   S4   'ANY 2 (hadrs1, hadr_absent)': hadrs1 in quorum, one short of 2 - an insert waits, one read: 'synchronous
#        commits waiting' critical naming hadr_absent [red FAIL]; the setting reset releases the insert
#   S6   'ANY 2 (hadrs1, hadr_absent)' with synchronous_commit local at the server: an insert completes within 10 s, one
#        read: 'synchronous commits waiting' WARNING (commits at the default do not wait) [red FAIL x1: the insert completing
#        is the server's own behaviour - mark corrected after 372's first red run]
#   S5   'ANY 1 (*)': hadrs1 in quorum, one read: no 'synchronous commits waiting' [red ok]; everything reset after
# Task 374 (written before its first run, 2026-11-14 11:3x PST; red = 16cc0fb, task 373's tree):
#   SL3  a physical slot hadr_grow reserving WAL, read; its hourly mark moved an hour back in the repository with 2 GB
#        less retained (a stand-in for the hour: the growth arithmetic is the import's), one read: 'slot WAL growing'
#        warning on hadr-p naming hadr_grow [red FAIL]
#   SL2  max_slot_wal_keep_size 400MB and 'slot_safe_wal' 300 MB on hadr-p (import_pg_threshold: done [red FAIL: no
#        such key before 374]), WAL written until safe_wal_size is under 190 MB (half the limit, 200, is the floor since
#        the review fold; 200MB / 150 MB / 80 MB written before it), one read: 'slot WAL near its limit' warning for
#        hadr_grow (one finding per slot: it outranks growing) [red FAIL]
#   SL1  about 300 MB more and a checkpoint: the slot loses its WAL (wal_status lost), one read: 'slot invalidated'
#        critical, its value the stable text and its detail naming wal_removed (PostgreSQL 17 on: invalidation_reason;
#        the run of b0e72a5 looked for the reason in the value and failed on a right finding) [red FAIL x2]; the slot
#        dropped, the setting and the threshold reset
#   SP   a test_decoding slot hadr_dec, logical_decoding_work_mem 64kB, a 20000-row transaction decoded through
#        pg_logical_slot_get_changes, one read: a slot_stats row for hadr_dec with spill_bytes over 0 [red FAIL]; undone
#   AU   Aurora, a repository stand-in until Q7 (an Aurora reader for the proof hour) is answered - not proven on Aurora:
#        an instance aurora-w (platform aurora) imported with aurora_replica_status rows (its own MASTER_SESSION_ID row
#        at 0 ms, reader-1 at 400 s, reader-2 at 45 s): 'Aurora replica lag' critical for reader-1 and warning for
#        reader-2 [red FAIL: one assertion for both readers], none for the writer's own row [red ok: a guard] (the marks
#        corrected after the red run, which said 'x2'); an instance aurora-r (platform aurora) imported twice as
#        a reader in recovery with primary_conninfo set and no WAL receiver: no 'receiver down' [red ok: gated since
#        370] and no link row [red FAIL: 371 made it a standby-only link]
#   R3   the standby stopped, hadr-p and hadr-s read once (hadr-s's connect fails): nothing yet [red ok]
#   G2   hadr-p read with 'platform: rds' in its config: no 'standby gone' on a managed platform [red ok]
#   R3   the plain config, one read of hadr-p: 'standby gone' critical naming hadrs1 in pgvigil.findings and
#        replication_checks [red FAIL x2]
#   L5   link app:hadrs1@<address> 'down: standby unreachable', its finding 'standby gone' critical on hadr-p, no link
#        finding on hadr-s [red FAIL x2: no view]
#   R3X  the standby started and streaming (its address may change: the vanished link is then 'replaced'), one read of
#        hadr-p: 'standby gone' gone [red ok]
#   L4   last: every sender row hadr-p stored for hadrs1 is keyed by the link - no pid in the key, one key per address
#        [red FAIL: keyed '...#<pid>']
# The review fold (2026-11-14 12:5x PST, written before its runs; red = 7636cca, the tree before the fold):
#   R2X  first read after the lift (a receiver back, the fault held for one read): 'receiver down' WARNING whose detail
#        says the receiver is back [red FAIL: critical]; second read: gone [red ok]
#   NS2  in NS (the standby read through a login that cannot read primary_conninfo, the receiver held down), hadr-p read
#        twice: 'standby gone' critical on hadr-p naming hadrs1 - a standby that cannot tell whether it should stream does
#        not speak for its link [red FAIL: it spoke, nothing was raised]
#   SL2H with max_slot_wal_keep_size 400MB and 'slot_safe_wal' 300 MB, WAL written until safe_wal_size is between 200 and
#        300 MB, one read: no slot finding - the floor is half the limit when that is smaller [red FAIL: warning]; then
#        SL2 below 200 MB as before, SL1 after about 300 MB more and a checkpoint
#   AU   the writer's own row at 400 s (over both tiers): still nothing for it [red ok: the MASTER_SESSION_ID filter];
#        aurora-r imported as a reader in recovery WITH the same aurora_replica_status rows: no 'Aurora replica lag' on
#        aurora-r [red FAIL: a reader raised them too]
#   RP   replay paused on hadr-s (pg_wal_replay_pause), hadr-p read once, hadr-s read once: nothing yet [red ok]; a second
#        read: 'replay paused' critical on hadr-s, the link row 'replay paused' [red FAIL x2 on 35e627e: no rule, no view;
#        red ok on 7636cca]; resumed, one read: gone [red ok]
#   S2X  the waiting insert's row is in hadr_feed [red ok]
#   read a failed read of an instance counts as a FAIL (the stopped standby's read in R3 excepted), and a failed
#        repository query answers 'QUERY FAILED' (a negative row cannot pass on an empty answer)
#   (info) 0118's own 'replay lag' arm (darling_alert_findings: a sender 30 s behind) is counted where L3T and L3D run;
#        the lead drops that arm at the join; the proof does not judge it.
# Not proven here: a promotion (the role-change drop of a server's links), a failed 'standby' or 'senders' read leaving
# the state as it was, a receiver that connects and then fails (the hysteresis is in the import, its row R2X's), the
# 'replaced' test (a standby back under another link: a slot added or dropped, two standbys of one name), a standby
# without restore_command (critical at once: the rig's standby always has one), 'slot WAL near its limit' critical on
# wal_status unreserved, 'standby gone' for an unmonitored or stale standby, a server before PostgreSQL 17 (wal_status
# lost without invalidation_reason), a database walsender (a table copy) kept out of the links, a named synchronous
# standby whose link is down, 'sending server not read', a WAL receiver without a replay position (pg_receivewal),
# 0006's standby-side 'replay lag' for a standby no monitored primary sends to.
# PROOF_ONLY=R1,R2W,... runs the rig, B, A0, L1 and the named rows only (R1 R1N R1B R2W R2C R2X G L3T L2W L2C L2S L2X L3D
# L6 P S1 S2 S4 S6 S5 SL3 SL2 SL1 SP AU RP R3 R3X L4; a riding row runs its host: L7 R2W, NS and NS2 G, S3 L6, G2 and L5
# R3, SL2H SL2); an unknown name stops the run; unset = all.
# Prints 'ok' / 'FAIL' per assertion and 'proof-pg-hadr: OK' or 'proof-pg-hadr: <n> FAIL'; exit 0 only when every row passed.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
ROWS=" R1 R1N R1B R2W R2C R2X G L3T L2W L2C L2S L2X L3D L6 P S1 S2 S4 S6 S5 SL3 SL2 SL1 SP AU RP R3 R3X L4 "
if [[ -n "${PROOF_ONLY:-}" ]]; then   # a riding row runs its host row; an unknown name is a typo, not an empty OK
  PO=""; for n in ${PROOF_ONLY//,/ }; do
    case "$n" in L7) n=R2W ;; NS|NS2) n=G ;; S3) n=L6 ;; G2|L5) n=R3 ;; SL2H) n=SL2 ;; esac
    [[ "$ROWS" == *" $n "* ]] || { echo "FAIL PROOF_ONLY names an unknown row: $n"; exit 1; }
    PO+="$n,"; done; PROOF_ONLY=$PO
fi
want() { [[ -z "${PROOF_ONLY:-}" || ",${PROOF_ONLY// /}," == *",$1,"* ]]; }
fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
MPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
RP=$(fp); PP=$(fp); SP=$(fp)
NET=pgvhadr-$$; REPO=pgvhadr-repo-$$; PRI=pgvhadr-p-$$; STB=pgvhadr-s-$$; BB=pgvhadr-bb-$$; ARC=pgvhadr-arc-$$
FEED=""; R2W_VALUE=""; HOLD=""; DFEED=""; SYNCW=""
cleanup() {
  [[ -n "$SYNCW" ]] && kill "$SYNCW" 2>/dev/null || true
  [[ -n "$FEED" ]] && kill "$FEED" 2>/dev/null || true
  [[ -n "$HOLD" ]] && kill "$HOLD" 2>/dev/null || true
  [[ -n "$DFEED" ]] && kill "$DFEED" 2>/dev/null || true
  docker rm -f -v "$BB" "$STB" "$PRI" "$REPO" >/dev/null 2>&1 || true
  docker volume rm "$ARC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  for c in "$BB" "$STB" "$PRI" "$REPO"; do docker inspect "$c" >/dev/null 2>&1 && echo "container $c LEFT"; done
  docker volume inspect "$ARC" >/dev/null 2>&1 && echo "volume $ARC LEFT"
  docker network inspect "$NET" >/dev/null 2>&1 && echo "network $NET LEFT"
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- the binary ----------------------------------------------------------------------------------------------------
if [[ -n "${PGVIGIL_BIN:-}" ]]; then BIN=$PGVIGIL_BIN; else
  CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil || { echo "FAIL the binary did not build"; exit 1; }
  BIN=$WORK/pgvigil
fi

# ---- the rig -------------------------------------------------------------------------------------------------------
docker network create "$NET" >/dev/null
docker volume create "$ARC" >/dev/null
docker run --rm -v "$ARC:/archive" postgres:18 bash -c 'mkdir -p /archive/wal && chown -R postgres:postgres /archive' >/dev/null
docker run -d --name "$REPO" --network "$NET" -e POSTGRES_PASSWORD="$PW" -p "127.0.0.1:$RP:5432" postgres:18 >/dev/null
docker run -d --name "$PRI" --network "$NET" --network-alias primary -e POSTGRES_PASSWORD="$PW" -v "$ARC:/archive" \
  -p "127.0.0.1:$PP:5432" postgres:18 -c wal_level=logical -c max_wal_senders=10 -c archive_mode=on \
  -c "archive_command=test ! -f /archive/wal/%f && cp %p /archive/wal/%f" -c cluster_name=hadrp >/dev/null
RDSN="host=127.0.0.1 port=$RP user=postgres password=$PW sslmode=disable"
PDSN="host=127.0.0.1 port=$PP user=postgres password=$PW sslmode=disable dbname=postgres"
SDSN="host=127.0.0.1 port=$SP user=postgres password=$PW sslmode=disable dbname=postgres"
for d in "$RDSN dbname=postgres" "$PDSN"; do for _ in $(seq 1 60); do psql "$d" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done; done; sleep 3
for d in "$RDSN dbname=postgres" "$PDSN"; do psql "$d" -XAtqc 'select 1' >/dev/null 2>&1 || { echo "FAIL the rig: $d does not answer"; exit 1; }; done
psql "$RDSN dbname=postgres" -XAtqc "create database pgvigil" >/dev/null
pq() { psql "$PDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
sq() { psql "$SDSN" -XAtq -c "$1" 2>/dev/null; }
q() { # a failed query answers 'QUERY FAILED: <error>' (exit 1), never an empty answer a negative row would pass on
  local o; if o=$(psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 -c "$1" 2>"$WORK/q.err"); then [[ -n "$o" ]] && printf '%s\n' "$o"; return 0; fi
  echo "QUERY FAILED: $(tail -1 "$WORK/q.err")"; return 1; }
pq "create role pgv login password '$MPW' in role pg_monitor" >/dev/null
pq "create role pgvs login password '$MPW' in role pg_read_all_stats, pg_stat_scan_tables" >/dev/null
pq "create table hadr_feed (id bigserial primary key, at timestamptz default now(), pad text)" >/dev/null
pq "create table hadr_bulk (pad text) with (autovacuum_enabled = off)" >/dev/null
# replication from any address with a password (the image's own lines cover local and 'all' databases only)
docker exec "$PRI" bash -c 'echo "host replication all all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
pq "select pg_reload_conf()" >/dev/null
docker run -d --name "$STB" --network "$NET" --network-alias standby --user postgres -e PGPASSWORD="$PW" -v "$ARC:/archive" \
  -p "127.0.0.1:$SP:5432" postgres:18 bash -c 'set -e; D=/var/lib/postgresql/sdata
    if [ ! -s "$D/PG_VERSION" ]; then pg_basebackup -h primary -U postgres -D "$D" -R -X stream -c fast; chmod 700 "$D"; fi
    exec postgres -D "$D" -c cluster_name=hadrs1 -c hot_standby=on -c listen_addresses="*" -c max_standby_streaming_delay=-1 \
      -c "restore_command=cp /archive/wal/%f %p"' >/dev/null
streaming() { [[ "$(sq "select status from pg_stat_wal_receiver")" == "streaming" ]]; }
for _ in $(seq 1 90); do streaming && break; sleep 1; done
streaming || { echo "FAIL the rig: the standby is not streaming"; docker logs --tail 20 "$STB"; exit 1; }
[[ "$(sq 'select pg_is_in_recovery()')" == "t" ]] || { echo "FAIL the rig: the standby is not in recovery"; exit 1; }
SIP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$STB")

cat > "$WORK/pgvigil.yaml" <<EOF
repository:
  dsn: "$RDSN dbname=pgvigil"
instances:
  - name: hadr-p
    dsn: "host=127.0.0.1 port=$PP user=pgv password=$MPW dbname=postgres sslmode=disable"
  - name: hadr-s
    dsn: "host=127.0.0.1 port=$SP user=pgv password=$MPW dbname=postgres sslmode=disable"
EOF
sed 's#^    dsn: "host=127.0.0.1 port='"$SP"' #    platform: rds\n&#' "$WORK/pgvigil.yaml" > "$WORK/pgvigil-rds.yaml"
grep -q 'platform: rds' "$WORK/pgvigil-rds.yaml" || { echo "FAIL the rig: no rds config"; exit 1; }
sed 's#^    dsn: "host=127.0.0.1 port='"$PP"' #    platform: rds\n&#' "$WORK/pgvigil.yaml" > "$WORK/pgvigil-rdsp.yaml"
sed 's#port='"$SP"' user=pgv #port='"$SP"' user=pgvs #' "$WORK/pgvigil.yaml" > "$WORK/pgvigil-ns.yaml"
grep -q 'platform: rds' "$WORK/pgvigil-rdsp.yaml" && grep -q 'user=pgvs' "$WORK/pgvigil-ns.yaml" || { echo "FAIL the rig: no rdsp / ns config"; exit 1; }
CFG=$WORK/pgvigil.yaml
"$BIN" migrate -config "$WORK/pgvigil.yaml" >"$WORK/migrate.out" 2>&1 || { cat "$WORK/migrate.out"; exit 1; }
"$BIN" collect -config "$WORK/pgvigil.yaml" -once instance >"$WORK/instance.out" 2>&1 || { cat "$WORK/instance.out"; exit 1; }
"$BIN" collect -config "$WORK/pgvigil.yaml" -once rolechange >>"$WORK/instance.out" 2>&1 || echo "  (rolechange: $(tail -1 "$WORK/instance.out"))"
PID_=$(q "select instance_id from pgvigil.instances where name='hadr-p'")
SID_=$(q "select instance_id from pgvigil.instances where name='hadr-s'")
read_() { # read_ <instance> [n] [gap] [may-fail]: n replication reads of one instance, gap (3) seconds apart; a failed
  # read is a FAIL (its rows would prove nothing) unless the caller expects it ('may-fail': a stopped server)
  local n=${2:-1} gap=${3:-3} i
  for ((i = 0; i < n; i++)); do
    (( i > 0 )) && sleep "$gap"
    "$BIN" collect -config "$CFG" -once replication -instance "$1" >>"$WORK/collect.out" 2>&1 || {
      if [[ "${4:-}" == may-fail ]]; then echo "  (read of $1 failed, as expected: $(tail -1 "$WORK/collect.out"))"
      else fail "read of $1 failed: $(tail -1 "$WORK/collect.out")"; fi; }
  done
}
finding() { # finding <instance_id> <setting> -> 'severity|value' lines
  q "select severity || '|' || value from pgvigil.findings where instance_id = $1 and setting = '$2' order by 1"
}
check() { # check <instance_id> <check_name> -> 'object|state' lines of replication_checks
  q "select object || '|' || coalesce(state, '') from pgvigil.replication_checks where instance_id = $1 and check_name = '$2' order by 1"
}
link() { # link <link LIKE pattern> -> 'status|check_name|severity|finding instance|source' of pg_repl_link_health
  q "select status || '|' || coalesce(check_name, '') || '|' || coalesce(severity, '') || '|' || coalesce(finding_id::text, '') || '|' || source from pgvigil.pg_repl_link_health where link like '$1' order by 1"
}
# never empty: an empty value inside $(( )) aborts the block it runs in (no sender row, or the primary not answering)
plag() { local v; v=$(pq "select coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint, 0) from pg_stat_replication where application_name = 'hadrs1'" 2>/dev/null); echo "${v:-0}"; }
lagsec() { local v; v=$(pq "select coalesce(extract(epoch from replay_lag)::numeric(10,1), -1) from pg_stat_replication where application_name = 'hadrs1'" 2>/dev/null); echo "${v:--1}"; }
bulk_to() { # bulk_to <MB>: write on the primary until hadrs1's replay lag is past MB
  local _; for _ in $(seq 1 60); do (( $(plag) >= $1 * 1048576 )) && return 0
    pq "insert into hadr_bulk select repeat(md5(g::text), 31) from generate_series(1, 4000) g" >/dev/null; done; return 1
}
feed_on() { ( while :; do psql "$PDSN" -XAtq -c "insert into hadr_feed (pad) select repeat('x', 200) from generate_series(1, 200)" -c "select pg_switch_wal()" >/dev/null 2>&1; sleep 2; done ) & FEED=$!; }
feed_off() { [[ -n "$FEED" ]] && kill "$FEED" 2>/dev/null; wait "$FEED" 2>/dev/null; FEED=""; }
hold_down() { # reject the standby's replication connections, then kill its receiver
  docker exec "$PRI" bash -c "sed -i '1i host replication all $SIP/32 reject' \"\$PGDATA/pg_hba.conf\""
  pq "select pg_reload_conf()" >/dev/null
  local rp; rp=$(sq "select pid from pg_stat_wal_receiver")
  [[ -n "$rp" ]] && docker exec "$STB" bash -c "kill $rp"
  local _; for _ in $(seq 1 20); do [[ -z "$(sq "select pid from pg_stat_wal_receiver")" ]] && sleep 6 && [[ -z "$(sq "select pid from pg_stat_wal_receiver")" ]] && return 0; sleep 1; done
  return 1
}
lift() {
  docker exec "$PRI" bash -c "sed -i '/^host replication all $SIP\/32 reject/d' \"\$PGDATA/pg_hba.conf\""
  pq "select pg_reload_conf()" >/dev/null
  local _; for _ in $(seq 1 60); do streaming && return 0; sleep 1; done; return 1
}

# ---- B: the healthy pair -------------------------------------------------------------------------------------------
read_ hadr-p 2; read_ hadr-s 2
r=$(q "select coalesce(state, '') from pgvigil.replication_latest where instance_id = $SID_ and kind = 'receiver'")
[[ "$r" == "streaming" ]] && ok "B receiver of hadr-s streaming" || fail "B receiver of hadr-s: '$r', expected streaming"
r=$(q "select coalesce(state, '') from pgvigil.replication_latest where instance_id = $PID_ and kind = 'sender' and detail->>'application_name' = 'hadrs1'")
[[ "$r" == "streaming" ]] && ok "B sender hadrs1 on hadr-p streaming" || fail "B sender hadrs1 on hadr-p: '$r', expected streaming"
for s in 'receiver down' 'standby gone'; do
  r=$(q "select count(*) from pgvigil.findings where setting = '$s' and instance_id in ($PID_, $SID_)")
  [[ "$r" == "0" ]] && ok "B no '$s' finding" || fail "B '$s' finding on the healthy pair: $r"
done
r=$(q "select count(*) from pgvigil.replication_checks where check_name in ('receiver down', 'standby gone', 'sender not streaming') and instance_id in ($PID_, $SID_)")
[[ "$r" == "0" ]] && ok "B no replication_checks row" || fail "B replication_checks rows on the healthy pair: $(q "select string_agg(check_name || ' ' || object, '; ') from pgvigil.replication_checks where instance_id in ($PID_, $SID_)")"

r=$(finding "$PID_" 'amcheck never run')
[[ -z "$r" ]] && ok "A0 no 'amcheck never run' on hadr-p (no database read)" || fail "A0 'amcheck never run' on hadr-p: '$r' (0103's arm lost a filter?)"

# ---- L1: the link of the pair --------------------------------------------------------------------------------------
r=$(link 'app:hadrs1@%')
[[ -n "$r" && "$(wc -l <<<"$r")" == "1" && "$r" == "streaming|||"*"|sender" ]] && ok "L1 one link row app:hadrs1@..., streaming, no finding: $r" || fail "L1 link app:hadrs1@...: '$r'"
r=$(q "select coalesce(sending, '') || '>' || coalesce(standby, '') from pgvigil.pg_repl_link_health where link like 'app:hadrs1@%'")
[[ "$r" == "hadr-p>hadr-s" ]] && ok "L1 paired: $r" || fail "L1 pairing: '$r', expected hadr-p>hadr-s"

# ---- R1: a base backup's senders -----------------------------------------------------------------------------------
if want R1 || want R1N || want R1B; then
  docker run -d --name "$BB" --network "$NET" -e PGPASSWORD="$PW" postgres:18 \
    pg_basebackup -h primary -U postgres -D /tmp/bb -X stream --no-slot --max-rate=32k -c fast >/dev/null
  for _ in $(seq 1 30); do [[ "$(pq "select count(*) from pg_stat_replication where state = 'backup'")" -ge 1 ]] && break; sleep 1; done
  echo "  hadr-p's senders during the base backup: $(pq "select string_agg(application_name || '/' || state, ', ') from pg_stat_replication")"
  read_ hadr-p 2
  if want R1; then
    r=$(q "select count(*) from pgvigil.replication_latest where instance_id = $PID_ and kind = 'sender' and state = 'backup' and detail->>'application_name' = 'pg_basebackup'")
    [[ "$r" -ge 1 ]] && ok "R1 the read stored the base backup's sender (state backup): $r" || fail "R1 no stored sender in state 'backup' (the base backup did not run? $r)"
    r=$(q "select count(*) from pgvigil.replication_checks where instance_id = $PID_ and check_name = 'sender not streaming' and object || coalesce(state, '') like '%pg_basebackup%'")
    [[ "$r" == "0" ]] && ok "R1 no 'sender not streaming' for pg_basebackup" || fail "R1 'sender not streaming' for the base backup: $r"
    r=$(q "select count(*) from pgvigil.pg_repl_link_health where application_name = 'pg_basebackup'")
    [[ "$r" == "0" ]] && ok "R1 no link row for pg_basebackup (its slotless WAL streamer)" || fail "R1 link rows for pg_basebackup: '$r'"
  fi
  docker rm -f -v "$BB" >/dev/null 2>&1
  for _ in $(seq 1 20); do [[ "$(pq "select count(*) from pg_stat_replication where application_name = 'pg_basebackup'")" == "0" ]] && break; sleep 1; done
  if want R1N; then   # a renamed base backup: no default name to go by
    docker run -d --name "$BB" --network "$NET" -e PGPASSWORD="$PW" -e PGAPPNAME=bbcustom postgres:18 \
      pg_basebackup -h primary -U postgres -D /tmp/bb -X stream --max-rate=32k -c fast >/dev/null
    for _ in $(seq 1 30); do [[ "$(pq "select count(*) from pg_stat_replication where application_name = 'bbcustom' and state = 'backup'")" -ge 1 ]] && break; sleep 1; done
    echo "  hadr-p's senders during the renamed base backup: $(pq "select string_agg(r.application_name || '/' || r.state || coalesce('/slot ' || s.slot_name || case when s.temporary then ' (temporary)' else '' end, ''), ', ') from pg_stat_replication r left join pg_replication_slots s on s.active_pid = r.pid")"
    read_ hadr-p 2
    r=$(q "select string_agg(coalesce(state, '?') || '/' || coalesce(detail->>'slot_temporary', 'none'), ',' order by state) from pgvigil.replication_latest where instance_id = $PID_ and kind = 'sender' and detail->>'application_name' = 'bbcustom'")
    [[ "$r" == *"backup/"* && "$r" == *"/true"* ]] && ok "R1N the read stored bbcustom's senders: $r" || fail "R1N bbcustom's stored senders: '$r', expected one in backup and one on a temporary slot"
    r=$(q "select count(*) from pgvigil.replication_checks where instance_id = $PID_ and check_name = 'sender not streaming' and object || coalesce(state, '') like '%bbcustom%'")
    [[ "$r" == "0" ]] && ok "R1N no 'sender not streaming' for bbcustom" || fail "R1N 'sender not streaming' for the renamed base backup: $r"
    r=$(q "select count(*) from pgvigil.pg_repl_link_health where application_name = 'bbcustom'")
    [[ "$r" == "0" ]] && ok "R1N no link row for bbcustom" || fail "R1N link rows for bbcustom: '$r'"
    docker rm -f -v "$BB" >/dev/null 2>&1
    for _ in $(seq 1 20); do [[ "$(pq "select count(*) from pg_stat_replication where application_name = 'bbcustom'")" == "0" ]] && break; sleep 1; done
    read_ hadr-p 2
    r=$(q "select count(*) from pgvigil.findings where instance_id = $PID_ and setting = 'standby gone' and value like '%bbcustom%'")
    [[ "$r" == "0" ]] && ok "R1N no 'standby gone' for the finished renamed base backup" || fail "R1N 'standby gone' for bbcustom: $r"
  fi
  if want R1B; then
    read_ hadr-p 2
    r=$(q "select count(*) from pgvigil.findings where instance_id = $PID_ and setting = 'standby gone' and value like '%pg_basebackup%'")
    [[ "$r" == "0" ]] && ok "R1B no 'standby gone' for the finished base backup" || fail "R1B 'standby gone' for a base backup: $r"
  fi
fi

# ---- R2: the receiver killed and held down -------------------------------------------------------------------------
if want R2W || want R2C || want R2X; then
  if hold_down; then
    feed_on
    l0=$(sq "select pg_last_wal_replay_lsn()"); sleep 8; l1=$(sq "select pg_last_wal_replay_lsn()")
    echo "  receiver held down: wal_receiver rows $(sq "select count(*) from pg_stat_wal_receiver"), replay $l0 -> $l1 through restore_command"
    if want R2W || want R2C || want R2X; then   # R2C compares with R2W's value; R2X's held read needs a fault to hold
      read_ hadr-s 2 10
      r=$(finding "$SID_" 'receiver down'); R2W_VALUE=${r#*|}
    fi
    if want R2W; then
      [[ "$r" == warning\|* ]] && ok "R2W 'receiver down' warning on hadr-s: $r" || fail "R2W 'receiver down' on hadr-s: '$r', expected warning"
      r=$(check "$SID_" 'receiver down')
      [[ "$r" == *"advances through restore_command"* ]] && ok "R2W replication_checks: $r" || fail "R2W replication_checks without 'advances through restore_command': '$r'"
      read_ hadr-p 2; read_ hadr-s 1
      r=$(finding "$PID_" 'standby gone'); r2=$(finding "$SID_" 'receiver down')
      [[ -z "$r" && -n "$r2" ]] && ok "L7 one finding for the link: 'receiver down' on hadr-s, no 'standby gone' on hadr-p" || fail "L7 hadr-p 'standby gone' '$r' / hadr-s 'receiver down' '$r2'"
    fi
    feed_off
    if want R2C; then
      r=$(q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"set\",\"key\":\"restore_stall\",\"level\":\"instance\",\"instance_id\":$SID_,\"crit\":1,\"ui_user\":\"proof\"}'::jsonb)->>'outcome'")
      [[ "$r" == "done" ]] && ok "R2C restore_stall set to 1 min on hadr-s" || fail "R2C the threshold was not set: '$r'"
      # replay's last move is dated by the read that sees it: one read once the last file is restored (replay still
      # for 10 s, polled), then the stall
      for _ in $(seq 1 8); do a=$(sq "select pg_last_wal_replay_lsn()"); sleep 5; b=$(sq "select pg_last_wal_replay_lsn()"); sleep 5
        [[ -n "$a" && "$a" == "$b" && "$b" == "$(sq "select pg_last_wal_replay_lsn()")" ]] && break; done
      read_ hadr-s 1; sleep 70; read_ hadr-s 1
      r=$(finding "$SID_" 'receiver down')
      [[ "$r" == critical\|* ]] && ok "R2C 'receiver down' critical on hadr-s: $r" || fail "R2C 'receiver down' on hadr-s: '$r', expected critical"
      r2=$(check "$SID_" 'receiver down')
      [[ "$r2" == *"replay has stopped"* ]] && ok "R2C replication_checks: $r2" || fail "R2C replication_checks without 'replay has stopped': '$r2'"
      [[ -n "$R2W_VALUE" && "${r#*|}" == "$R2W_VALUE" ]] && ok "R2C the finding's value kept from R2W (one alert key)" || fail "R2C the value changed: '$R2W_VALUE' -> '${r#*|}'"
      q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"inherit\",\"key\":\"restore_stall\",\"level\":\"instance\",\"instance_id\":$SID_,\"ui_user\":\"proof\"}'::jsonb)" >/dev/null
    fi
    if lift; then
      if want R2X; then
        read_ hadr-s 1   # the fault holds for one read with a receiver: a warning that says so
        r=$(finding "$SID_" 'receiver down'); r2=$(check "$SID_" 'receiver down')
        [[ "$r" == warning\|* && "$r2" == *"a WAL receiver is back"* ]] && ok "R2X held for one read as a warning: $r2" || fail "R2X the held read: '$r' / '$r2', expected a warning saying the receiver is back"
        read_ hadr-s 1
        r=$(finding "$SID_" 'receiver down'); r2=$(check "$SID_" 'receiver down')
        [[ -z "$r$r2" ]] && ok "R2X 'receiver down' cleared after the receiver came back" || fail "R2X still raised: '$r' / '$r2'"
      fi
    else fail "R2X the receiver did not come back after the lift"; fi
  else fail "R2 the receiver could not be held down"; lift; fi
fi

# ---- G: the managed-platform gate (a repository stand-in) ----------------------------------------------------------
if want G; then
  if hold_down; then
    CFG=$WORK/pgvigil-rds.yaml; read_ hadr-s 2
    r=$(finding "$SID_" 'receiver down')
    [[ -z "$r" ]] && ok "G no 'receiver down' on a managed platform" || fail "G 'receiver down' raised on platform rds: '$r'"
    CFG=$WORK/pgvigil.yaml; read_ hadr-s 1
    r=$(finding "$SID_" 'receiver down')
    [[ -n "$r" ]] && ok "G onprem again: raised ($r)" || fail "G onprem again: 'receiver down' not raised"
    CFG=$WORK/pgvigil-ns.yaml; read_ hadr-s 2; CFG=$WORK/pgvigil.yaml
    r=$(q "select coalesce(detail->>'conninfo_set', 'null') from pgvigil.replication_latest where instance_id = $SID_ and kind = 'standby'")
    [[ "$r" == "null" ]] && ok "NS a login without pg_read_all_settings: the standby row's conninfo_set unknown" || fail "NS the standby row's conninfo_set: '$r', expected null"
    r=$(finding "$SID_" 'receiver down')
    [[ -z "$r" ]] && ok "NS no 'receiver down' when primary_conninfo cannot be read" || fail "NS raised with primary_conninfo unknown: '$r'"
    read_ hadr-p 2   # the standby cannot say whether it should stream: the sending side's view holds
    r=$(finding "$PID_" 'standby gone')
    [[ "$r" == critical\|*hadrs1* ]] && ok "NS2 'standby gone' on hadr-p while the standby cannot judge its own side: $r" || fail "NS2 'standby gone' on hadr-p: '$r', expected critical naming hadrs1"
    lift || fail "G the receiver did not come back after the lift"
    read_ hadr-s 1; read_ hadr-p 1
  else fail "G the receiver could not be held down"; lift; fi
fi

# ---- L2 / L3: lag tiers --------------------------------------------------------------------------------------------
if want L3T || want L2W || want L2C || want L2S || want L2X; then
  read_ hadr-p 1; read_ hadr-s 1
  ( psql "$SDSN" -XAtq -c "begin; select count(*) from hadr_feed; select pg_sleep(900); commit;" >/dev/null 2>&1 ) & HOLD=$!
  sleep 2
  pq "begin; lock table hadr_feed in access exclusive mode; commit;" >/dev/null
  for _ in $(seq 1 20); do [[ "$(sq "select count(*) from pg_stat_activity where backend_type = 'startup' and wait_event_type = 'Lock'")" -ge 1 ]] && break; sleep 1; done
  echo "  replay stalled: startup waiting on a lock = $(sq "select count(*) from pg_stat_activity where backend_type = 'startup' and wait_event_type = 'Lock'")"
  # a stuck apply position reports a growing replay_lag (the walsender interpolates past its last sample)
  ( for _ in $(seq 1 45); do psql "$PDSN" -XAtq -c "insert into hadr_bulk values ('t')" >/dev/null 2>&1; sleep 1; done ) & DFEED=$!
  sleep 30; for _ in $(seq 1 30); do awk -v v="$(lagsec)" 'BEGIN { exit !(v >= 35) }' && break; sleep 1; done
  read_ hadr-p 1
  if want L3T; then
    r=$(finding "$PID_" 'standby lag')
    [[ -z "$r" ]] && ok "L3T one read with replay_lag $(lagsec) s: nothing yet" || fail "L3T raised after one read: '$r'"
  fi
  sleep 3; read_ hadr-p 1
  wait "$DFEED" 2>/dev/null; DFEED=""
  if want L3T; then
    r=$(finding "$PID_" 'standby lag'); r2=$(check "$PID_" 'standby lag')
    [[ "$r" == warning\|*hadrs1* ]] && ok "L3T 'standby lag' warning on hadr-p: $r" || fail "L3T 'standby lag' on hadr-p: '$r', expected warning (replay_lag $(lagsec) s, $(( $(plag) / 1048576 )) MB)"
    [[ "$r2" == *"replay_lag"* && "$r2" != *"not yet replayed"* ]] && ok "L3T judged on replay_lag alone: $r2" || fail "L3T detail: '$r2', expected replay_lag and no bytes"
    echo "  (info) 0118's 'replay lag' findings on hadr-p now: $(q "select count(*) from pgvigil.findings where instance_id = $PID_ and setting = 'replay lag'")"
  fi
  if bulk_to 60; then
    echo "  hadrs1 replay lag on the primary: $(( $(plag) / 1048576 )) MB, replay_lag $(lagsec) s"
    read_ hadr-p 2; read_ hadr-s 1
    if want L2W; then
      r=$(finding "$PID_" 'standby lag'); r2=$(check "$PID_" 'standby lag')
      [[ "$r" == warning\|*hadrs1* ]] && ok "L2W 'standby lag' warning on hadr-p: $r" || fail "L2W 'standby lag' on hadr-p: '$r', expected warning naming hadrs1 (lag $(( $(plag) / 1048576 )) MB)"
      [[ "$r2" == *"not yet replayed"* ]] && ok "L2W judged on the bytes too: $r2" || fail "L2W detail without bytes: '$r2'"
      r=$(finding "$SID_" 'standby lag')
      [[ -z "$r" ]] && ok "L2W none on hadr-s (one finding per link)" || fail "L2W 'standby lag' on hadr-s too: '$r'"
    fi
    if bulk_to 110; then
      echo "  hadrs1 replay lag on the primary: $(( $(plag) / 1048576 )) MB"
      read_ hadr-p 2
      if want L2C; then
        r=$(finding "$PID_" 'standby lag')
        [[ "$r" == critical\|*hadrs1* ]] && ok "L2C 'standby lag' critical on hadr-p: $r" || fail "L2C 'standby lag' on hadr-p: '$r', expected critical"
      fi
      if want L2S; then
        q "update pgvigil.pg_repl_link_seen set checked_at = checked_at - interval '1 hour' where instance_id = $PID_" >/dev/null
        read_ hadr-s 2
        r=$(finding "$SID_" 'standby lag'); r2=$(check "$SID_" 'standby lag'); r3=$(finding "$PID_" 'standby lag')
        [[ "$r" == critical\|* ]] && ok "L2S 'standby lag' critical on hadr-s: $r" || fail "L2S 'standby lag' on hadr-s: '$r', expected critical"
        [[ "$r2" == *"received - replayed on the standby"* ]] && ok "L2S judged on the standby's bytes" || fail "L2S detail: '$r2'"
        [[ -z "$r3" ]] && ok "L2S none on hadr-p (its read is stale)" || fail "L2S 'standby lag' on hadr-p too: '$r3'"
      fi
    else fail "L2C the lag did not pass 110 MB"; fi
  else fail "L2 the lag did not pass 60 MB (replay not stalled?)"; fi
  # release: end the standby session that holds the lock; replay catches up and its replay_lag clears
  sq "select pg_cancel_backend(pid) from pg_stat_activity where query like '%pg_sleep(900)%' and pid <> pg_backend_pid()" >/dev/null
  kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""
  for _ in $(seq 1 60); do (( $(plag) < 1048576 )) && break; sleep 0.5; done
  echo "  after the release: replay lag $(plag) bytes, replay_lag $(lagsec) s"
  for _ in $(seq 1 90); do [[ "$(lagsec)" == "-1" ]] && break; sleep 1; done
  read_ hadr-p 1; read_ hadr-s 1
  if want L2X; then
    r=$(q "select count(*) from pgvigil.findings where setting = 'standby lag' and instance_id in ($PID_, $SID_)")
    [[ "$r" == "0" ]] && ok "L2X no 'standby lag' once replay caught up (replay_lag $(lagsec))" || fail "L2X 'standby lag' still raised: $(finding "$PID_" 'standby lag') / $(finding "$SID_" 'standby lag')"
  fi
fi

if want L3D; then
  docker exec "$STB" bash -c "echo \"recovery_min_apply_delay = '60s'\" >> /var/lib/postgresql/sdata/postgresql.auto.conf"
  sq "select pg_reload_conf()" >/dev/null; sleep 1
  echo "  standby recovery_min_apply_delay: $(sq "show recovery_min_apply_delay")"
  ( for _ in $(seq 1 75); do psql "$PDSN" -XAtq -c "insert into hadr_feed (pad) values ('d')" >/dev/null 2>&1; sleep 1; done ) & DFEED=$!
  sleep 70
  read_ hadr-s 1; read_ hadr-p 2
  wait "$DFEED" 2>/dev/null
  r0=$(lagsec); r=$(finding "$PID_" 'standby lag')
  (( $(cut -d. -f1 <<<"$r0") >= 30 )) && ok "L3D the primary's replay_lag is $r0 s (the 30 s tier alone would warn)" || fail "L3D replay_lag only '$r0' s: the row proves nothing"
  [[ -z "$r" ]] && ok "L3D no 'standby lag' on a standby delayed 60 s on purpose" || fail "L3D raised on a delayed standby: '$r'"
  echo "  (info) 0118's 'replay lag' findings on hadr-p now: $(q "select count(*) from pgvigil.findings where instance_id = $PID_ and setting = 'replay lag'")"
  docker exec "$STB" bash -c "sed -i '/recovery_min_apply_delay/d' /var/lib/postgresql/sdata/postgresql.auto.conf"
  sq "select pg_reload_conf()" >/dev/null
  for _ in $(seq 1 30); do [[ "$(sq "show recovery_min_apply_delay")" == "0" ]] && break; sleep 1; done
  read_ hadr-s 1; read_ hadr-p 1
fi

# ---- L6: expected links never seen --------------------------------------------------------------------------------
if want L6; then
  pq "select pg_create_physical_replication_slot('hadr_spare')" >/dev/null
  pq "alter system set synchronous_standby_names = 'FIRST 1 (hadrs1, hadr_absent)'" >/dev/null; pq "select pg_reload_conf()" >/dev/null
  for _ in $(seq 1 20); do [[ "$(pq "select sync_state from pg_stat_replication where application_name = 'hadrs1'")" == "sync" ]] && break; sleep 0.5; done
  read_ hadr-p 1
  r=$(link 'slot:hadr_spare'); r2=$(link 'app:hadr_absent')
  [[ "$r" == "missing: physical slot inactive|||"*"|slot" ]] && ok "L6 slot:hadr_spare: $r" || fail "L6 slot:hadr_spare: '$r'"
  [[ "$r2" == "missing: named in synchronous_standby_names|"*"|sync names" ]] && ok "L6 app:hadr_absent: $r2" || fail "L6 app:hadr_absent: '$r2'"
  [[ "$r2" == *"|synchronous standby absent|warning|$PID_|"* ]] && ok "S3 'synchronous standby absent' warning on hadr-p" || fail "S3 app:hadr_absent's finding: '$r2'"
  r=$(finding "$PID_" 'synchronous commits waiting')
  [[ -z "$r" ]] && ok "S3 no 'synchronous commits waiting' (num_sync 1 holds)" || fail "S3 'synchronous commits waiting' raised: '$r'"
  r=$(q "select coalesce(sync_state, '') from pgvigil.pg_repl_link_health where link like 'app:hadrs1@%' and gone_reads = 0")
  [[ "$r" == "sync" ]] && ok "L6 hadrs1's link sync_state sync" || fail "L6 hadrs1's sync_state: '$r'"
  pq "alter system reset synchronous_standby_names" >/dev/null; pq "select pg_reload_conf()" >/dev/null
  pq "select pg_drop_replication_slot('hadr_spare')" >/dev/null
  read_ hadr-p 1
fi

# ---- P / S: synchronous standbys (task 372) ------------------------------------------------------------------------
if want P; then
  for c in "2 (a, b)=FIRST|2|{a,b}" "a, b=FIRST|1|{a,b}" "ANY 1 (*)=ANY *|1|" '"Quoted", b=FIRST|1|{Quoted,b}' "first 3 (x)=FIRST|3|{x}" "*=FIRST *|1|" "=||"; do
    in=${c%%=*}; want_=${c#*=}
    r=$(q "select coalesce(method, '') || '|' || coalesce(num_sync::text, '') || '|' || coalesce(names::text, '') from pgvigil.pg_sync_standbys('$in')" 2>/dev/null || echo error)
    [[ "$r" == "$want_" ]] && ok "P '$in' -> $r" || fail "P '$in' -> '$r', expected '$want_'"
  done
fi
sync_set() { pq "alter system set synchronous_standby_names = '$1'" >/dev/null; pq "select pg_reload_conf()" >/dev/null; sleep 1; }
sync_reset() { pq "alter system reset synchronous_standby_names" >/dev/null; pq "alter system reset synchronous_commit" >/dev/null; pq "select pg_reload_conf()" >/dev/null; sleep 1; }
waiter() { ( psql "$PDSN" -XAtq -c "insert into hadr_feed (pad) values ('sync')" >/dev/null 2>&1 ) & SYNCW=$!
  local _; for _ in $(seq 1 20); do [[ "$(pq "select count(*) from pg_stat_activity where wait_event = 'SyncRep'")" -ge 1 ]] && return 0; sleep 0.5; done; return 1; }
if want S1 || want S2 || want S4 || want S6 || want S5; then
  sync_set 'FIRST 1 (hadrs1)'
  for _ in $(seq 1 20); do [[ "$(pq "select sync_state from pg_stat_replication where application_name = 'hadrs1'")" == "sync" ]] && break; sleep 0.5; done
  read_ hadr-p 1
  if want S1; then
    r=$(finding "$PID_" 'synchronous commits waiting')
    [[ -z "$r" ]] && ok "S1 hadrs1 sync: no 'synchronous commits waiting'" || fail "S1 raised: '$r'"
  fi
  if want S2; then
    if hold_down && waiter; then
      echo "  a commit waits: $(pq "select count(*) from pg_stat_activity where wait_event = 'SyncRep'") session(s) in SyncRep"
      read_ hadr-p 1
      r=$(finding "$PID_" 'synchronous commits waiting'); r2=$(check "$PID_" 'synchronous commits waiting')
      [[ "$r" == critical\|* ]] && ok "S2 'synchronous commits waiting' critical on hadr-p: $r" || fail "S2 on hadr-p: '$r', expected critical"
      [[ "$r2" == *"not connected: hadrs1"* && "$r2" == *"every commit waits"* ]] && ok "S2 detail: $r2" || fail "S2 detail: '$r2'"
      lift || fail "S2X the receiver did not come back"
      for _ in $(seq 1 60); do kill -0 "$SYNCW" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$SYNCW" 2>/dev/null && fail "S2X the waiting insert did not complete" || ok "S2X the waiting insert completed once hadrs1 was back"
      r=$(pq "select count(*) from hadr_feed where pad = 'sync'")
      [[ "$r" == "1" ]] && ok "S2X the waiting insert's row is in hadr_feed" || fail "S2X rows of the waiting insert: '$r'"
      SYNCW=""
      read_ hadr-p 1
      r=$(finding "$PID_" 'synchronous commits waiting')
      [[ -z "$r" ]] && ok "S2X cleared" || fail "S2X still raised: '$r'"
    else fail "S2 no commit waited (or the receiver could not be held down)"; lift; fi
  fi
  if want S4; then
    sync_set 'ANY 2 (hadrs1, hadr_absent)'
    if waiter; then
      read_ hadr-p 1
      r=$(finding "$PID_" 'synchronous commits waiting'); r2=$(check "$PID_" 'synchronous commits waiting')
      [[ "$r" == critical\|* && "$r2" == *"not connected: hadr_absent"* ]] && ok "S4 quorum one short: critical naming hadr_absent" || fail "S4: '$r' / '$r2'"
    else fail "S4 no commit waited under ANY 2"; fi
    sync_reset
    for _ in $(seq 1 20); do kill -0 "$SYNCW" 2>/dev/null || break; sleep 0.5; done; SYNCW=""
  fi
  if want S6; then
    pq "alter system set synchronous_commit = 'local'" >/dev/null; sync_set 'ANY 2 (hadrs1, hadr_absent)'
    if timeout 10 psql "$PDSN" -XAtq -c "insert into hadr_feed (pad) values ('local')" >/dev/null 2>&1; then ok "S6 an insert completes at synchronous_commit local"; else fail "S6 an insert waited at synchronous_commit local"; fi
    read_ hadr-p 1
    r=$(finding "$PID_" 'synchronous commits waiting')
    [[ "$r" == warning\|* ]] && ok "S6 'synchronous commits waiting' warning when commits do not wait: $r" || fail "S6: '$r', expected warning"
    sync_reset
  fi
  if want S5; then
    sync_set 'ANY 1 (*)'
    for _ in $(seq 1 20); do [[ "$(pq "select sync_state from pg_stat_replication where application_name = 'hadrs1'")" == "quorum" ]] && break; sleep 0.5; done
    read_ hadr-p 1
    r=$(finding "$PID_" 'synchronous commits waiting')
    [[ -z "$r" ]] && ok "S5 'ANY 1 (*)' with hadrs1 in quorum: nothing" || fail "S5 raised: '$r'"
  fi
  sync_reset; read_ hadr-p 1
fi

# ---- SL / SP / AU: slots and Aurora (task 374) ----------------------------------------------------------------------
thr() { q "select pgvigil.import_pg_threshold(now(), '$1'::jsonb)->>'outcome'"; }
wal_mb() { local i; for ((i = 0; i < $1 / 4; i++)); do pq "insert into hadr_bulk select repeat(md5(g::text), 31) from generate_series(1, 4000) g" >/dev/null; done; }
slotf() { q "select severity || '|' || setting || '|' || value from pgvigil.findings where instance_id = $PID_ and setting like 'slot %' and value like 'slot $1:%' order by 1"; }
if want SL3 || want SL2 || want SL1; then
  pq "select pg_create_physical_replication_slot('hadr_grow', true)" >/dev/null
  read_ hadr-p 1
  if want SL3; then
    q "update pgvigil.pg_repl_slot_state set mark_at = mark_at - interval '61 minutes', mark_bytes = coalesce(retained_bytes, 0) - 2147483648 where instance_id = $PID_ and slot_name = 'hadr_grow'" >/dev/null 2>&1
    read_ hadr-p 1
    r=$(slotf hadr_grow)
    [[ "$r" == "warning|slot WAL growing|slot hadr_grow:"* ]] && ok "SL3 'slot WAL growing' warning: $r" || fail "SL3: '$r'"
  fi
  pq "alter system set max_slot_wal_keep_size = '400MB'" >/dev/null; pq "select pg_reload_conf()" >/dev/null
  r=$(thr "{\"op\":\"set\",\"key\":\"slot_safe_wal\",\"level\":\"instance\",\"instance_id\":$PID_,\"warn\":300,\"ui_user\":\"proof\"}")
  [[ "$r" == "done" ]] || fail "SL2 the threshold was not set: '$r'"
  safe_mb() { local v; v=$(pq "select coalesce((safe_wal_size / 1048576)::int, -1) from pg_replication_slots where slot_name = 'hadr_grow'" 2>/dev/null); echo "${v:--1}"; }
  for _ in $(seq 1 60); do (( $(safe_mb) < 290 )) && break; wal_mb 8; done
  s=$(safe_mb); echo "  hadr_grow: safe $s MB (SL2H wants it between 200, half the limit, and 300, slot_safe_wal)"
  read_ hadr-p 1
  if want SL2; then
    r=$(slotf hadr_grow)
    if (( s > 200 && s < 300 )); then [[ -z "$r" ]] && ok "SL2H under slot_safe_wal but over half the limit: no slot finding" || fail "SL2H raised at $s MB safe: '$r'"
    else fail "SL2H the slot's safe_wal_size $s MB is not between 200 and 300 MB (the rig wrote too much before SL2)"; fi
  fi
  for _ in $(seq 1 60); do (( $(safe_mb) < 190 )) && break; wal_mb 8; done
  echo "  hadr_grow: $(pq "select wal_status || ', safe ' || pg_size_pretty(safe_wal_size) from pg_replication_slots where slot_name = 'hadr_grow'")"
  read_ hadr-p 1
  if want SL2; then
    r=$(slotf hadr_grow)
    [[ "$r" == "warning|slot WAL near its limit|slot hadr_grow:"* ]] && ok "SL2 'slot WAL near its limit' warning: $r" || fail "SL2: '$r'"
  fi
  wal_mb 300; pq "checkpoint" >/dev/null; wal_mb 8; pq "checkpoint" >/dev/null
  echo "  hadr_grow: $(pq "select coalesce(wal_status, '?') || ', ' || coalesce(invalidation_reason::text, '-') from pg_replication_slots where slot_name = 'hadr_grow'")"
  read_ hadr-p 1
  if want SL1; then
    r=$(slotf hadr_grow); r2=$(check "$PID_" 'slot invalidated')
    [[ "$r" == "critical|slot invalidated|slot hadr_grow: the slot is invalidated" ]] && ok "SL1 'slot invalidated' critical: $r" || fail "SL1: '$r'"
    # the reason is in the detail, never the value (alert keys include the value: it stays fixed while the fault lasts)
    [[ "$r2" == "slot hadr_grow|"*"wal_removed"* ]] && ok "SL1 its detail names wal_removed: $r2" || fail "SL1 detail: '$r2'"
  fi
  pq "select pg_drop_replication_slot('hadr_grow')" >/dev/null
  pq "alter system reset max_slot_wal_keep_size" >/dev/null; pq "select pg_reload_conf()" >/dev/null
  thr "{\"op\":\"inherit\",\"key\":\"slot_safe_wal\",\"level\":\"instance\",\"instance_id\":$PID_,\"ui_user\":\"proof\"}" >/dev/null
  read_ hadr-p 1
fi
if want SP; then
  pq "select pg_create_logical_replication_slot('hadr_dec', 'test_decoding')" >/dev/null
  pq "alter system set logical_decoding_work_mem = '64kB'" >/dev/null; pq "select pg_reload_conf()" >/dev/null
  pq "insert into hadr_feed (pad) select repeat('s', 100) from generate_series(1, 20000)" >/dev/null
  echo "  decoded: $(pq "select count(*) from pg_logical_slot_get_changes('hadr_dec', NULL, NULL)") change(s); spill_bytes $(pq "select spill_bytes from pg_stat_replication_slots where slot_name = 'hadr_dec'")"
  read_ hadr-p 1
  r=$(q "select coalesce(max(lag_bytes), -1) from pgvigil.replication_sample where instance_id = $PID_ and kind = 'slot_stats' and key = 'hadr_dec'")
  [[ "$r" =~ ^[0-9]+$ && "$r" -gt 0 ]] && ok "SP slot_stats row for hadr_dec: spill_bytes $r" || fail "SP slot_stats spill_bytes: '$r'"
  pq "select pg_drop_replication_slot('hadr_dec')" >/dev/null
  pq "alter system reset logical_decoding_work_mem" >/dev/null; pq "select pg_reload_conf()" >/dev/null
  read_ hadr-p 1
fi
if want AU; then
  AW=$(q "select pgvigil.ensure_instance('aurora-w', 'aurora', 'PostgreSQL 16.6', 160006, false, '{}')")
  AR=$(q "select pgvigil.ensure_instance('aurora-r', 'aurora', 'PostgreSQL 16.6', 160006, true, '{}')")
  q "select pgvigil.import_replication($AW, now(), '[{\"kind\":\"aurora_replica\",\"server_id\":\"aurora-w\",\"session_id\":\"MASTER_SESSION_ID\",\"replica_lag_in_msec\":400000},{\"kind\":\"aurora_replica\",\"server_id\":\"reader-1\",\"session_id\":\"s1\",\"replica_lag_in_msec\":400000},{\"kind\":\"aurora_replica\",\"server_id\":\"reader-2\",\"session_id\":\"s2\",\"replica_lag_in_msec\":45000}]'::jsonb)" >/dev/null
  r=$(q "select string_agg(severity || ' ' || value, '; ' order by value) from pgvigil.findings where instance_id = $AW and setting = 'Aurora replica lag'")
  [[ "$r" == "critical replica reader-1:"*"; warning replica reader-2:"* ]] && ok "AU 'Aurora replica lag': critical reader-1, warning reader-2" || fail "AU findings: '$r'"
  [[ "$r" != *"aurora-w"* ]] && ok "AU nothing for the writer's own row" || fail "AU the writer's row raised: '$r'"
  for t in "now() - interval '10 seconds'" "now()"; do
    q "select pgvigil.import_replication($AR, $t, '[{\"kind\":\"standby\",\"has_receiver\":false,\"conninfo_set\":true,\"restore_set\":false,\"replay_lsn\":\"0/3000000\"}]'::jsonb)" >/dev/null
  done
  r=$(finding "$AR" 'receiver down'); r2=$(q "select count(*) from pgvigil.pg_repl_link_health where standby_id = $AR" 2>/dev/null || echo error)
  [[ -z "$r" ]] && ok "AU no 'receiver down' on an Aurora reader" || fail "AU 'receiver down' on aurora-r: '$r'"
  [[ "$r2" == "0" ]] && ok "AU no link row for an Aurora reader" || fail "AU link rows for aurora-r: '$r2'"
  # a reader returns the same aurora_replica_status rows: the writer alone raises them
  q "select pgvigil.import_replication($AR, now() + interval '1 second', '[{\"kind\":\"standby\",\"has_receiver\":false,\"conninfo_set\":true,\"restore_set\":false,\"replay_lsn\":\"0/3000000\"},{\"kind\":\"aurora_replica\",\"server_id\":\"reader-1\",\"session_id\":\"s1\",\"replica_lag_in_msec\":400000},{\"kind\":\"aurora_replica\",\"server_id\":\"reader-2\",\"session_id\":\"s2\",\"replica_lag_in_msec\":45000}]'::jsonb)" >/dev/null
  r=$(q "select count(*) from pgvigil.findings where instance_id = $AR and setting = 'Aurora replica lag'")
  [[ "$r" == "0" ]] && ok "AU no 'Aurora replica lag' raised by a reader" || fail "AU a reader raised 'Aurora replica lag': '$r'"
  q "update pgvigil.instances set is_active = false where instance_id in ($AW, $AR)" >/dev/null
fi

# ---- RP: replay paused on the standby -------------------------------------------------------------------------------
if want RP; then
  sq "select pg_wal_replay_pause()" >/dev/null
  for _ in $(seq 1 20); do [[ "$(sq "select pg_get_wal_replay_pause_state()")" == "paused" ]] && break; sleep 0.5; done
  echo "  hadr-s replay: $(sq "select pg_get_wal_replay_pause_state()")"
  read_ hadr-p 1; read_ hadr-s 1
  r=$(finding "$SID_" 'replay paused')
  [[ -z "$r" ]] && ok "RP one read paused: nothing yet" || fail "RP raised after one read: '$r'"
  read_ hadr-s 1
  r=$(finding "$SID_" 'replay paused'); r2=$(link 'app:hadrs1@%')
  [[ "$r" == "critical|replay: replay is paused" ]] && ok "RP 'replay paused' critical on hadr-s: $r" || fail "RP 'replay paused' on hadr-s: '$r', expected critical"
  [[ "$r2" == "replay paused|replay paused|critical|$SID_|sender" ]] && ok "RP the link row: $r2" || fail "RP link app:hadrs1@...: '$r2'"
  sq "select pg_wal_replay_resume()" >/dev/null
  read_ hadr-s 1
  r=$(finding "$SID_" 'replay paused')
  [[ -z "$r" ]] && ok "RP resumed: gone" || fail "RP still raised after the resume: '$r'"
fi

# ---- R3: the standby stopped ---------------------------------------------------------------------------------------
if want R3 || want R3X; then
  read_ hadr-p 1
  docker stop -t 10 "$STB" >/dev/null
  for _ in $(seq 1 20); do [[ "$(pq "select count(*) from pg_stat_replication where application_name = 'hadrs1'")" == "0" ]] && break; sleep 1; done
  read_ hadr-p 1; read_ hadr-s 1 3 may-fail
  if want R3; then
    r=$(finding "$PID_" 'standby gone')
    [[ -z "$r" ]] && ok "R3 one read after the stop: nothing yet" || fail "R3 raised after one read: '$r'"
  fi
  CFG=$WORK/pgvigil-rdsp.yaml; read_ hadr-p 1; CFG=$WORK/pgvigil.yaml
  if want R3; then
    r=$(finding "$PID_" 'standby gone')
    [[ -z "$r" ]] && ok "G2 no 'standby gone' on a managed platform (hadr-p read as rds)" || fail "G2 raised on platform rds: '$r'"
  fi
  read_ hadr-p 1
  if want R3; then
    r=$(finding "$PID_" 'standby gone')
    [[ "$r" == critical\|*hadrs1* ]] && ok "R3 'standby gone' critical on hadr-p: $r" || fail "R3 'standby gone' on hadr-p: '$r', expected critical naming hadrs1"
    r=$(check "$PID_" 'standby gone')
    [[ "$r" == *hadrs1* ]] && ok "R3 replication_checks: $r" || fail "R3 no 'standby gone' naming hadrs1 in replication_checks: '$r'"
    r=$(link 'app:hadrs1@%')
    [[ "$r" == "down: standby unreachable|standby gone|critical|$PID_|sender" ]] && ok "L5 link shown down: $r" || fail "L5 link app:hadrs1@...: '$r'"
    r=$(q "select count(*) from pgvigil.pg_hadr_checks where instance_id = $SID_")
    [[ "$r" == "0" ]] && ok "L5 no link finding on hadr-s" || fail "L5 link findings on hadr-s: $r"
  fi
  docker start "$STB" >/dev/null
  for _ in $(seq 1 60); do streaming && break; sleep 1; done
  for _ in $(seq 1 20); do [[ "$(pq "select count(*) from pg_stat_replication where application_name = 'hadrs1' and state = 'streaming'")" == "1" ]] && break; sleep 1; done
  if want R3X; then
    read_ hadr-p 1
    r=$(finding "$PID_" 'standby gone'); r2=$(check "$PID_" 'standby gone')
    [[ -z "$r$r2" ]] && ok "R3X 'standby gone' cleared after the standby came back" || fail "R3X still raised: '$r' / '$r2'"
  fi
fi

# ---- L4: the sender's series keyed by the link -----------------------------------------------------------------------
if want L4; then
  r=$(q "select count(distinct key) || '|' || count(distinct detail->>'client_addr') || '|' || count(*) filter (where key like '%#%' or key <> 'app:hadrs1@' || (detail->>'client_addr')) || '|' || count(*) from pgvigil.replication_sample where instance_id = $PID_ and kind = 'sender' and detail->>'application_name' = 'hadrs1'")
  IFS='|' read -r nk na nbad nall <<<"$r"
  floor=10; [[ -n "${PROOF_ONLY:-}" ]] && floor=1   # B alone stores 2 rows; the full run stores dozens
  [[ -n "$nall" && "$nall" -gt "$floor" && "$nk" == "$na" && "$nbad" == "0" ]] && ok "L4 $nall sender rows of hadrs1, keyed app:hadrs1@<address> ($nk key(s) for $na address(es))" || fail "L4 hadrs1's sender keys: keys $nk, addresses $na, off the link key $nbad, rows $nall"
fi

echo "rows run: ${PROOF_ONLY:-all}"
if (( FAILS == 0 )); then echo "proof-pg-hadr: OK"; exit 0; fi
echo "proof-pg-hadr: $FAILS FAIL"; exit 1
