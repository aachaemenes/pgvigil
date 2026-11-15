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
#        read stored bbcustom's two senders, one in state backup and one on a temporary slot [red FAIL on 35e627e: its
#        collector sends no slot; ok from ee6d061]; no 'sender not
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
#        says the receiver is back [red FAIL: no such text; its severity there follows restore_command - a warning while
#        replay is still fed, critical otherwise, which the fold makes a warning: that case reasoned, not run]; second
#        read: gone [red ok]
#   NS2  in NS (the standby read through a login that cannot read primary_conninfo, the receiver held down), hadr-p read
#        twice, then hadr-s once through that login (its word newer than the sender's loss): 'standby gone' critical on
#        hadr-p naming hadrs1 - a standby that cannot tell whether it should stream does
#        not speak for its link [red FAIL: it spoke, nothing was raised]
#   SL2H with max_slot_wal_keep_size 400MB and 'slot_safe_wal' 300 MB, WAL written until safe_wal_size is between 200 and
#        300 MB, one read: no 'slot WAL near its limit' (SL3's 'slot WAL growing' may still hold) - the floor is half the
#        limit when that is smaller [red FAIL: warning]; then
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
#   AF   task 374's Q7 fix (written 2026-11-14 18:4x, after the real reader's Q7 run stored no standby state for it):
#        hadr-s read as 'hadr-sa', platform aurora, through a login whose search_path puts raising stand-ins of
#        pg_last_wal_receive_lsn, pg_last_wal_replay_lsn, pg_last_xact_replay_timestamp and pg_is_wal_replay_paused
#        before pg_catalog (and a stand-in aurora_replica_status: the writer's row and one replica at 20 ms);
#        'standby_replay_lag' warning 0 on it, two reads: its standby state in recovery with no receiver, its read 'ok';
#        no 'Aurora replica lag' and no 'receiver down' on it [red FAIL, 86c4079: the 'standby' read raises - no state,
#        the read partial, 'Aurora replica lag' raised on the reader]
# Task 375's rows (migration 0150), written before the first run 2026-11-14 18:0x PST; red = the tree before 375
# (rel-hadr-s1 ef59fba: no 0150 - its functions, views and checks do not exist, so every row below fails there):
#   RU1  the rig's own samples (hadr-p, hadr-s): every (kind, key, UTC hour) of replication_hourly equals a direct
#        aggregate of replication_sample (reads, lag_bytes and lag_secs min / max / sum / count, active reads), none
#        missing, none extra; a stand-in slot's spill_count 10, 20, 5, 7, 9 at H+10m, 15m, 20m, 59m30s, 60m30s: hour H
#        3 pairs rise 15 (a reset: the later value) gap_rise 2 (the 39-minute pair), H+1 1 pair rise 2 - the same as a
#        direct lag() over the samples [red FAIL]
#   RU2  a late sample at H+59m50s (8): H rise 16, H+1 rise 1; the hours recomputed twice are the same rows (an md5 of
#        the rows read twice: the first red run passed it on two failed reads alike) [red FAIL]
#   RU3  inside BEGIN ... ROLLBACK: a pair across the next month's first second - the trigger makes that month's
#        partition, the pair's rise 4 in the new month's first hour; nothing left after the rollback [red FAIL]
#   RU4  a table holding last month's partition name: an import of a sample there commits (the sample stored), one
#        'rollup failed' row, its hours marked; the table dropped, the next import heals them ('rollup healed', the
#        hour's row, no dirty range) [red FAIL]
#   RU5  replication_hourly_purge drops the month 25 months back and keeps the one 24 months back (730 days); it leaves
#        every hours partition at fillfactor 90 and next month's made (F16, added 18:5x after LD measured 2 of 242
#        updates HOT at 100) [red FAIL]
#   RU6  the stand-in built (heal_one): a 4-hour window reads its 3 samples (100, 300, 200), a 3-day window its 2 hours
#        (300, 200: the same max per hour), building false; a day older than every stored sample month reads the hours
#        (a stand-in hour row 555); hadr-p, never built, reads its samples by hour with building true [red FAIL]
#   LK   a heal holds the stand-in's lock for 8 s: an import meanwhile commits in under 2 s and marks its hours (no hour
#        row); the next import after the lock heals them (2 reads, max 43, no dirty range) [red FAIL]
#   LD   a stand-in standby with 30 days of reads a minute at 300 databases (about 13 M samples, stored with the
#        triggers off: history before the upgrade); its first build from purge (heal_one) while an import of 300
#        databases runs every second: every import under 2 s, the build exits 0, 72x receiver hours, the first build
#        recorded, no build range left; the next import heals the hours marked meanwhile. The build's time, the bytes
#        per hour row and the HOT share of the hours' updates are printed (docs/upgrade.md's line; F16) [red FAIL]
#   CC   hadr-c, a standby of hadr-s (pg_basebackup from it, cluster_name hadrc1): its link row sending hadr-s, status
#        'streaming (cascaded from hadr-s)', sending_in_recovery true [red FAIL]; paired once, hadr-p's link to hadr-s
#        stays 'streaming' [red ok: 0141's pairing, a guard]
#   SQ   max_standby_streaming_delay 0 on hadr-c: 3 queries on it cancelled by a replayed ACCESS EXCLUSIVE lock, one
#        read: 'standby queries cancelled' warning on hadr-c, 'database postgres', its detail '3 queries cancelled ...
#        (confl_lock +3)' [red FAIL]; nothing on hadr-p, and the reads moved 13 minutes back (a stand-in for the
#        window's passing): gone [red ok: guards, they read pgvigil.findings]
#   RB2  hadr-p's bands (never changed role): unknown, primary [red FAIL]
#   CL3  a copy of hadr-p started as a primary (never a standby, one system identifier), both read twice: no cluster
#        finding [red FAIL: it reads pg_cluster_checks, which the red tree lacks - a failed query, not a finding]
#   CL2  hadr-p stopped (a real stop) for 3.5 minutes, hadr-s and hadr-c read: ONE 'cluster without a primary' critical,
#        on hadr-p (the member last seen primary), naming hadr-s's receiver down (hadr-c is cascaded) [red FAIL]
#   CL4  hadr-s promoted while hadr-p is stopped (a switchover): no cluster finding [red FAIL: pg_cluster_checks missing]
#   RB   hadr-s's bands across its promotion: unknown, standby, primary; the standby band ends at the promotion [red FAIL]
#   CL1  hadr-p started again while hadr-s is primary, both read twice: 'two primaries' critical on each, naming the
#        other [red FAIL]
#   CL1b hadr-c (streaming from hadr-s) promoted while hadr-s runs: 'two primaries' on hadr-c naming hadr-s, and on
#        hadr-s naming hadr-c and hadr-p [red FAIL]
# Not proven here (375): a Patroni cluster (the leader's name, 'no leader' left to task 376), a link paired by slot only
# (the topology needs the other's name or cluster_name in the link, or a 'cluster' tag), confl_active_logicalslot
# (PostgreSQL 16+), the hours' series past the cap, the purge command's Go loop (the lead's wiring).
# PROOF_ONLY=R1,R2W,... runs the rig, B, A0, L1 and the named rows only (R1 R1N R1B R2W R2C R2X G L3T L2W L2C L2S L2X L3D
# L6 P S1 S2 S4 S6 S5 SL3 SL2 SL1 SP AU AF RP R3 R3X L4 RU LK LD CC SQ CL; a riding row runs its host: L7 R2W, NS and NS2 G,
# S3 L6, G2 and L5 R3, SL2H SL2, RU1-RU6 RU, CL1-CL4 CL1b RB RB2 CL; AF); an unknown name stops the run; unset = all.
# Prints 'ok' / 'FAIL' per assertion and 'proof-pg-hadr: OK' or 'proof-pg-hadr: <n> FAIL'; exit 0 only when every row passed.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
ROWS=" R1 R1N R1B R2W R2C R2X G L3T L2W L2C L2S L2X L3D L6 P S1 S2 S4 S6 S5 SL3 SL2 SL1 SP AU RP R3 R3X L4 RU LK LD CC SQ CL AF "
if [[ -n "${PROOF_ONLY:-}" ]]; then   # a riding row runs its host row; an unknown name is a typo, not an empty OK
  PO=""; for n in ${PROOF_ONLY//,/ }; do
    case "$n" in L7) n=R2W ;; NS|NS2) n=G ;; S3) n=L6 ;; G2|L5) n=R3 ;; SL2H) n=SL2 ;; RU[1-6]) n=RU ;; CL[1-4]|CL1b|RB|RB2) n=CL ;; esac
    [[ "$ROWS" == *" $n "* ]] || { echo "FAIL PROOF_ONLY names an unknown row: $n"; exit 1; }
    PO+="$n,"; done; PROOF_ONLY=$PO
fi
want() { [[ -z "${PROOF_ONLY:-}" || ",${PROOF_ONLY// /}," == *",$1,"* ]]; }
fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
MPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
RP=$(fp); PP=$(fp); SP=$(fp)
NET=pgvhadr-$$; REPO=pgvhadr-repo-$$; PRI=pgvhadr-p-$$; STB=pgvhadr-s-$$; BB=pgvhadr-bb-$$; ARC=pgvhadr-arc-$$; CAS=pgvhadr-c-$$; CPY=pgvhadr-x-$$
FEED=""; R2W_VALUE=""; HOLD=""; DFEED=""; SYNCW=""
cleanup() {
  [[ -n "$SYNCW" ]] && kill "$SYNCW" 2>/dev/null || true
  [[ -n "$FEED" ]] && kill "$FEED" 2>/dev/null || true
  [[ -n "$HOLD" ]] && kill "$HOLD" 2>/dev/null || true
  [[ -n "$DFEED" ]] && kill "$DFEED" 2>/dev/null || true
  docker rm -f -v "$BB" "$CPY" "$CAS" "$STB" "$PRI" "$REPO" >/dev/null 2>&1 || true
  docker volume rm "$ARC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  for c in "$BB" "$CPY" "$CAS" "$STB" "$PRI" "$REPO"; do docker inspect "$c" >/dev/null 2>&1 && echo "container $c LEFT"; done
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
    # the standby, read AFTER the sender vanished, cannot say whether it should stream: the sending side's view holds
    read_ hadr-p 2; CFG=$WORK/pgvigil-ns.yaml; read_ hadr-s 1; CFG=$WORK/pgvigil.yaml
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
    # SL3's 'slot WAL growing' may still hold here (one finding per slot: 'near its limit' would outrank it)
    if (( s > 200 && s < 300 )); then [[ "$r" != *"near its limit"* ]] && ok "SL2H under slot_safe_wal but over half the limit: no 'slot WAL near its limit' (${r:-no finding})" || fail "SL2H raised at $s MB safe: '$r'"
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

# ---- AF: an Aurora reader whose WAL functions raise (task 374's Q7 fix; a stand-in: hadr-s read as platform aurora) --
if want AF; then
  pq "create schema aurora_fake" >/dev/null
  for f in "pg_last_wal_receive_lsn|pg_lsn" "pg_last_wal_replay_lsn|pg_lsn" "pg_last_xact_replay_timestamp|timestamptz" "pg_is_wal_replay_paused|boolean"; do
    pq "create function aurora_fake.${f%%|*}() returns ${f##*|} language plpgsql as \$\$ begin raise exception 'a stand-in Aurora reader: ${f%%|*}() is not available'; end \$\$" >/dev/null
  done
  pq "create function aurora_fake.aurora_replica_status() returns table (server_id text, session_id text, durable_lsn pg_lsn, highest_lsn_rcvd pg_lsn,
        current_read_lsn pg_lsn, cpu real, iops real, replica_lag_in_msec real, log_stream_speed_in_kib_per_second real, log_buffer_sequence_number bigint,
        oldest_read_view_lsn pg_lsn, last_update_timestamp timestamptz) language sql as \$\$
        select 'hadr-af-w'::text, 'MASTER_SESSION_ID'::text, '0/1'::pg_lsn, null::pg_lsn, null::pg_lsn, 1::real, 1::real, null::real, 0::real, 0::bigint, null::pg_lsn, now()
        union all select 'hadr-af-r', 'af-session', '0/1', '0/1', '0/1', 1, 1, 20, 0, 0, '0/1', now() \$\$" >/dev/null
  # USAGE on the schema: a schema the role may not use is skipped in its search_path, silently (the first red run's rig fault)
  pq "create role pgva login password '$MPW' in role pg_monitor; alter role pgva set search_path = aurora_fake, pg_catalog, public; grant usage on schema aurora_fake to pgva" >/dev/null
  for _ in $(seq 1 30); do [[ "$(sq "select count(*) from pg_proc where proname = 'aurora_replica_status'")" == 1 ]] && break; sleep 1; done
  OCFG=$CFG; { cat "$OCFG"; printf '  - name: hadr-sa\n    platform: aurora\n    dsn: "host=127.0.0.1 port=%s user=pgva password=%s dbname=postgres sslmode=disable"\n' "$SP" "$MPW"; } > "$WORK/pgvigil-af.yaml"
  CFG=$WORK/pgvigil-af.yaml
  "$BIN" collect -config "$CFG" -once instance -instance hadr-sa >>"$WORK/collect.out" 2>&1 || fail "AF instance read of hadr-sa: $(tail -1 "$WORK/collect.out")"
  AFID=$(q "select instance_id from pgvigil.instances where name = 'hadr-sa'")
  r=$(psql "host=127.0.0.1 port=$SP user=pgva password=$MPW sslmode=disable dbname=postgres" -XAtq -c "select pg_last_wal_replay_lsn()" 2>&1 | tail -1)
  [[ "$r" == *"stand-in Aurora reader"* ]] && ok "AF the stand-in raises through hadr-sa's login: $r" || fail "AF the stand-in does not raise: '$r'"
  q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"set\",\"key\":\"standby_replay_lag\",\"level\":\"instance\",\"instance_id\":$AFID,\"warn\":0,\"crit\":300,\"ui_user\":\"proof\"}'::jsonb)" >/dev/null
  read_ hadr-sa 2
  r=$(q "select coalesce((select in_recovery || '|' || has_receiver from pgvigil.pg_repl_standby_state where instance_id = $AFID), 'no state') || '|' ||
             coalesce((select d.status || ' ' || coalesce(d.note, '') from pgvigil.collection_dates d where d.instance_id = $AFID and d.collection = 'replication'
                        order by d.snapshot_at desc limit 1), 'no read')")
  r2=$(finding "$AFID" 'Aurora replica lag'); r3=$(finding "$AFID" 'receiver down')
  [[ "$r" == "true|false|ok"* && -z "$r2$r3" ]] && ok "AF hadr-sa (platform aurora, its WAL functions raise): in recovery, no receiver, the read ok ($r); no 'Aurora replica lag', no 'receiver down' on it" \
    || fail "AF hadr-sa: '$r' (expected true|false|ok), 'Aurora replica lag' '$r2', 'receiver down' '$r3' (expected none)"
  q "update pgvigil.instances set is_active = false where instance_id = $AFID" >/dev/null   # it is hadr-s: the later rows read hadr-s itself
  pq "drop role pgva; drop schema aurora_fake cascade" >/dev/null
  CFG=$OCFG
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

# ---- 375: the hourly rollup (0150), repository rows on a stand-in instance ------------------------------------------
imp() { q "select pgvigil.import_replication($1, $2, '$3'::jsonb)" >/dev/null; }   # imp <instance_id> <timestamptz sql> <payload>: one read
if want RU || want LK || want LD; then
  RU=$(q "select pgvigil.ensure_instance('ru-standin', 'self-managed', '18.0', 180000, false, '{}')")
  H=$(q "select to_char(date_trunc('hour', now() at time zone 'UTC') - interval '3 hours', 'YYYY-MM-DD HH24:00:00+00')")
fi
if want RU; then
  # RU1 the rig's own samples (its two instances) against a direct aggregate of replication_sample, every hour and object
  r=$(q "with d as (select instance_id, kind, key, date_trunc('hour', snapshot_at at time zone 'UTC') at time zone 'UTC' as h, count(*)::int as n,
                           min(lag_bytes) as bmin, max(lag_bytes) as bmax, sum(lag_bytes) as bsum, count(lag_bytes)::int as bn,
                           round(min(lag_secs)::numeric, 6) as smin, round(max(lag_secs)::numeric, 6) as smax, round(sum(lag_secs)::numeric, 6) as ssum,
                           count(lag_secs)::int as sn, (count(*) filter (where active))::int as act
                      from pgvigil.replication_sample where instance_id in ($PID_, $SID_)
                       and (kind in ('receiver', 'slot', 'aurora_replica') or (kind = 'sender' and (key like 'app:%' or key like 'slot:%')))
                     group by 1, 2, 3, 4),
               h as (select instance_id, kind, key, snapshot_at, samples, lag_bytes_min, lag_bytes_max, lag_bytes_sum, lag_bytes_n,
                            round(lag_secs_min::numeric, 6), round(lag_secs_max::numeric, 6), round(lag_secs_sum::numeric, 6), lag_secs_n, active_reads
                       from pgvigil.replication_hourly where instance_id in ($PID_, $SID_) and kind in ('sender', 'receiver', 'slot', 'aurora_replica'))
          select (select count(*) from d) || '|' || (select count(*) from (select * from d except select * from h) x) || '|' || (select count(*) from (select * from h except select * from d) x)")
  IFS='|' read -r n1 n2 n3 <<<"$r"
  [[ "$n1" =~ ^[1-9][0-9]*$ && "$n2" == 0 && "$n3" == 0 ]] && ok "RU1 the rig's $n1 hour rows equal a direct aggregate of its samples (none missing, none extra)" || fail "RU1 hours vs samples (rows|missing|extra): '$r'"
  # RU1 a counter with a reset, a collector gap and a pair across the hour (slot_stats spill_count 10, 20, 5, 7, 9)
  for p in "10 minutes|10" "15 minutes|20" "20 minutes|5" "59 minutes 30 seconds|7" "60 minutes 30 seconds|9"; do
    imp "$RU" "'$H'::timestamptz + interval '${p%%|*}'" "[{\"kind\":\"slot_stats\",\"slot_name\":\"ru_slot\",\"spill_count\":${p##*|}}]"
  done
  r=$(q "select string_agg(to_char(snapshot_at - '$H'::timestamptz, 'HH24') || ' ' || samples || ' ' || (rise->>'spill_count') || ' ' || coalesce(gap_rise->>'spill_count', '-'), '; ' order by snapshot_at)
           from pgvigil.replication_hourly where instance_id = $RU and kind = 'slot_stats' and key = 'ru_slot'")
  d=$(q "with s as (select snapshot_at, (detail->>'spill_count')::numeric as v, lag(snapshot_at) over w as pa, lag((detail->>'spill_count')::numeric) over w as pv
                      from pgvigil.replication_sample where instance_id = $RU and kind = 'slot_stats' and key = 'ru_slot' window w as (order by snapshot_at)),
              p as (select date_trunc('hour', snapshot_at at time zone 'UTC') at time zone 'UTC' as h, case when v >= pv then v - pv else v end as rise, snapshot_at - pa <= interval '10 minutes' as short
                      from s where pa is not null)
         select string_agg(to_char(h - '$H'::timestamptz, 'HH24') || ' ' || n || ' ' || r || ' ' || coalesce(g::text, '-'), '; ' order by h)
           from (select h, count(*) as n, sum(rise) filter (where short) as r, sum(rise) filter (where not short) as g from p group by h) x")
  [[ "$r" == "00 3 15 2; 01 1 2 -" && "$r" == "$d" ]] && ok "RU1 counter rises (hour pairs rise gap): $r = a direct lag() over the samples" || fail "RU1 counter rises: '$r', direct '$d', expected '00 3 15 2; 01 1 2 -'"
  # RU2 a late sample, the last of hour H, changes H+1's rise; a recompute twice = once
  imp "$RU" "'$H'::timestamptz + interval '59 minutes 50 seconds'" '[{"kind":"slot_stats","slot_name":"ru_slot","spill_count":8}]'
  r=$(q "select string_agg(to_char(snapshot_at - '$H'::timestamptz, 'HH24') || ' ' || (rise->>'spill_count'), '; ' order by snapshot_at)
           from pgvigil.replication_hourly where instance_id = $RU and key = 'ru_slot'")
  [[ "$r" == "00 16; 01 1" ]] && ok "RU2 the late sample recomputed hour H (16) and H+1 (1): $r" || fail "RU2 after the late sample: '$r', expected '00 16; 01 1'"
  m1=$(q "select md5(string_agg(h::text, ',' order by kind, key, snapshot_at)) from pgvigil.replication_hourly h where instance_id = $RU")
  r=$(psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 2>&1 <<SQL
begin;
select pg_advisory_xact_lock(hashtext('pgvigil.replication_hourly'), $RU);
select pgvigil.replication_hours($RU, '$H'::timestamptz - interval '1 hour', '$H'::timestamptz + interval '3 hours');
select pgvigil.replication_hours($RU, '$H'::timestamptz - interval '1 hour', '$H'::timestamptz + interval '3 hours');
commit;
SQL
)
  m2=$(q "select md5(string_agg(h::text, ',' order by kind, key, snapshot_at)) from pgvigil.replication_hourly h where instance_id = $RU")
  [[ "$m1" =~ ^[0-9a-f]{32}$ && "$m1" == "$m2" ]] && ok "RU2 the hours recomputed twice are the same rows" || fail "RU2 twice != once ($m1 / $m2; $r)"   # an md5, not two failed reads alike
  # RU3 the month boundary, inside BEGIN ... ROLLBACK (a future sample must not stay: replication_latest takes the newest)
  M=$(q "select to_char(date_trunc('month', now() at time zone 'UTC') + interval '1 month', 'YYYY-MM-DD 00:00:00+00')")
  MP=$(q "select to_char('$M'::timestamptz at time zone 'UTC', 'YYYYMM')")
  r=$(psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 2>&1 <<SQL
begin;
select pgvigil.import_replication($RU, '$M'::timestamptz - interval '1 minute', '[{"kind":"slot_stats","slot_name":"ru_m","spill_count":3}]'::jsonb);
select pgvigil.import_replication($RU, '$M'::timestamptz + interval '30 seconds', '[{"kind":"slot_stats","slot_name":"ru_m","spill_count":7}]'::jsonb);
select (to_regclass('pgvigil.replication_hourly_$MP') is not null) || '|' || coalesce((select rise->>'spill_count' from pgvigil.replication_hourly
         where instance_id = $RU and key = 'ru_m' and snapshot_at = '$M'::timestamptz), 'none');
rollback;
SQL
)
  r=$(tail -1 <<<"$r"); r2=$(q "select count(*) from pgvigil.replication_sample where instance_id = $RU and key = 'ru_m'")
  [[ "$r" == "true|4" && "$r2" == 0 ]] && ok "RU3 across $M: the trigger made replication_hourly_$MP, the pair across the boundary rose 4; rolled back" || fail "RU3 month boundary: '$r' (expected true|4), samples left $r2"
  # RU4 a failure injected (a table holds the partition's name), the import commits, 'rollup failed'; the next import heals
  P=$(q "select to_char(date_trunc('month', now() at time zone 'UTC') - interval '1 month' + interval '14 days 12 hours', 'YYYY-MM-DD HH24:00:00+00')")
  PP_=$(q "select to_char('$P'::timestamptz at time zone 'UTC', 'YYYYMM')")
  if [[ "$(q "select to_regclass('pgvigil.replication_hourly_$PP_') is null")" == t ]]; then
    q "create table pgvigil.replication_hourly_$PP_ (blocker int)" >/dev/null
    imp "$RU" "'$P'::timestamptz" '[{"kind":"slot","slot_name":"ru_fail","retained_bytes":11,"wal_status":"reserved","active":true}]'
    r=$(q "select (select count(*) from pgvigil.replication_sample where instance_id = $RU and key = 'ru_fail') || '|' ||
               (select count(*) from pgvigil.collection_log where instance_id = $RU and collection = 'replication_hourly' and status = 'error' and note like 'rollup failed%') || '|' ||
               (select count(*) from pgvigil.replication_hourly_dirty where instance_id = $RU and source = 'mark')")
    [[ "$r" == "1|1|1" ]] && ok "RU4 the import committed (sample stored), 'rollup failed' logged, its hours marked: $r" || fail "RU4 injected failure (sample|failed rows|mark): '$r', expected 1|1|1"
    q "drop table pgvigil.replication_hourly_$PP_" >/dev/null
    imp "$RU" "now()" '[{"kind":"slot","slot_name":"ru_now","retained_bytes":12,"wal_status":"reserved","active":true}]'
    r=$(q "select (select count(*) from pgvigil.replication_hourly where instance_id = $RU and key = 'ru_fail') || '|' ||
               (select count(*) from pgvigil.collection_log where instance_id = $RU and collection = 'replication_hourly' and status = 'ok' and note like 'rollup healed%') || '|' ||
               (select count(*) from pgvigil.replication_hourly_dirty where instance_id = $RU)")
    [[ "$r" == "1|1|0" ]] && ok "RU4 the next import healed the marked hours ('rollup healed', the hour row there, no dirty range): $r" || fail "RU4 heal (hour rows|healed rows|dirty): '$r', expected 1|1|0"
  else
    fail "RU4 replication_hourly_$PP_ exists already: no partition to block"
  fi
  # RU5 retention: the month 25 months back dropped, the one 24 months back kept (730 days)
  r=$(q "select string_agg(to_char(m, 'YYYYMM'), ',') from (select date_trunc('month', now() at time zone 'UTC') - make_interval(months => k) as m from unnest(array[25, 24]) k) x")
  OLD=${r%%,*}; KEEP=${r##*,}
  q "select pgvigil.ensure_month_partition('replication_hourly', (to_date('${OLD}15', 'YYYYMMDD')::timestamp) at time zone 'UTC'),
            pgvigil.ensure_month_partition('replication_hourly', (to_date('${KEEP}15', 'YYYYMMDD')::timestamp) at time zone 'UTC')" >/dev/null
  r=$(q "select array_to_string(pgvigil.replication_hourly_purge(), ',') || '|' || (to_regclass('pgvigil.replication_hourly_$OLD') is null) || '|' || (to_regclass('pgvigil.replication_hourly_$KEEP') is not null)")
  [[ "$r" == "replication_hourly_$OLD|true|true" ]] && ok "RU5 replication_hourly_purge dropped $OLD, kept $KEEP (730 days): $r" || fail "RU5 retention: '$r', expected replication_hourly_$OLD|true|true"
  r=$(q "select count(*) filter (where not coalesce('fillfactor=90' = any (c.reloptions), false)) || '|' ||
               (to_regclass('pgvigil.replication_hourly_' || to_char(date_trunc('month', now() at time zone 'UTC') + interval '1 month', 'YYYYMM')) is not null)
           from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'pgvigil.replication_hourly'::regclass")
  [[ "$r" == "0|true" ]] && ok "RU5 every hours partition at fillfactor 90, next month's made ahead: $r" || fail "RU5 fillfactor / next month (partitions not at 90|next month there): '$r', expected 0|true"
  # RU6 the series: a 2-day window reads the samples, a 3-day window the hours (the same max per hour); a window older
  # than the stored samples reads the hours; an instance not built says 'building'
  for p in "5 minutes|100" "25 minutes|300" "65 minutes|200"; do
    imp "$RU" "'$H'::timestamptz + interval '${p%%|*}'" "[{\"kind\":\"slot\",\"slot_name\":\"ru_lag\",\"retained_bytes\":${p##*|},\"wal_status\":\"reserved\",\"active\":true}]"
  done
  q "select pgvigil.replication_hourly_heal_one($RU)" >/dev/null
  r=$(q "select count(*) || '|' || string_agg(lag_bytes::text, ',' order by snapshot_at) || '|' || bool_or(building)
           from pgvigil.replication_series($RU, '$H'::timestamptz - interval '1 hour', '$H'::timestamptz + interval '3 hours', 60, 'lag') where key = 'ru_lag'")
  r2=$(q "select count(*) || '|' || string_agg(lag_bytes::text, ',' order by snapshot_at) || '|' || bool_or(building)
            from pgvigil.replication_series($RU, now() - interval '3 days', now(), 432, 'lag') where key = 'ru_lag'")
  [[ "$r" == "3|100,300,200|false" && "$r2" == "2|300,200|false" ]] && ok "RU6 2 days: the samples ($r); 3 days: the hours, the same max per hour ($r2)" || fail "RU6 the switch: 2 days '$r' (expected 3|100,300,200|false), 3 days '$r2' (expected 2|300,200|false)"
  OLDS=$(q "select to_char(min(to_date(right(c.relname, 6) || '01', 'YYYYMMDD')) - interval '1 month' + interval '14 days 10 hours', 'YYYY-MM-DD HH24:00:00+00')
              from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'pgvigil.replication_sample'::regclass and c.relname ~ '_[0-9]{6}\$'")
  q "select pgvigil.ensure_month_partition('replication_hourly', '$OLDS'::timestamptz);
     insert into pgvigil.replication_hourly (instance_id, kind, key, snapshot_at, samples, lag_bytes_max) values ($RU, 'slot', 'ru_hist', '$OLDS'::timestamptz, 60, 555)" >/dev/null
  r=$(q "select count(*) || '|' || string_agg(lag_bytes::text, ',') from pgvigil.replication_series($RU, '$OLDS'::timestamptz - interval '10 hours', '$OLDS'::timestamptz + interval '14 hours', 144, 'lag') where key = 'ru_hist'")
  r2=$(q "select coalesce(bool_and(building), false) || '|' || count(*) from pgvigil.replication_series($PID_, now() - interval '3 days', now(), 432, 'lag')")
  [[ "$r" == "1|555" && "$r2" == true\|* && "${r2#*|}" != 0 ]] && ok "RU6 a day older than the samples reads the hours ($r); hadr-p, not built, reads its samples by hour, building ($r2)" || fail "RU6 old window '$r' (expected 1|555), unbuilt hadr-p '$r2' (expected true|<rows>)"
fi
# ---- LK: an import while the instance's hours are being healed (F4) --------------------------------------------------
if want LK; then
  (psql "$RDSN dbname=pgvigil" -XAtq -c "begin" -c "select pg_advisory_xact_lock(hashtext('pgvigil.replication_hourly'), $RU)" -c "select pg_sleep(8)" -c "commit" >/dev/null 2>&1) & LKH=$!
  sleep 2
  t0=$(date +%s%N); imp "$RU" "now()" '[{"kind":"slot","slot_name":"ru_lk","retained_bytes":42,"wal_status":"reserved","active":true}]'; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  r=$(q "select (select count(*) from pgvigil.replication_hourly where instance_id = $RU and key = 'ru_lk') || '|' || (select count(*) from pgvigil.replication_hourly_dirty where instance_id = $RU and source = 'mark')")
  [[ "$ms" -lt 2000 && "$r" == "0|1" ]] && ok "LK the import while a heal held the lock committed in $ms ms, its hours marked (hour rows|mark): $r" || fail "LK the import under a held lock: $ms ms, '$r' (expected under 2000 ms, 0|1)"
  wait "$LKH" 2>/dev/null
  imp "$RU" "now()" '[{"kind":"slot","slot_name":"ru_lk","retained_bytes":43,"wal_status":"reserved","active":true}]'
  r=$(q "select (select samples || ' ' || lag_bytes_max from pgvigil.replication_hourly where instance_id = $RU and key = 'ru_lk' and snapshot_at = date_trunc('hour', now() at time zone 'UTC') at time zone 'UTC') || '|' ||
             (select count(*) from pgvigil.replication_hourly_dirty where instance_id = $RU)")
  [[ "$r" == "2 43|0" ]] && ok "LK the next import healed the hour (samples max|dirty): $r" || fail "LK after the lock: '$r', expected '2 43|0'"
fi
# ---- LD: the first build of 30 days at 300 databases, the imports going on (F1) -------------------------------------
if want LD; then
  LD=$(q "select pgvigil.ensure_instance('ld-standin', 'self-managed', '18.0', 180000, true, '{}')")
  t0=$(date +%s)
  r=$(psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 2>&1 <<SQL
set session_replication_role = replica;   -- history stored before the upgrade: no trigger
select count(*) from (select pgvigil.ensure_month_partition('replication_sample', d) from generate_series(now() - interval '31 days', now(), interval '1 day') d) x;
insert into pgvigil.replication_sample (instance_id, snapshot_at, kind, key, state, lag_bytes, lag_secs, active, detail)
select $LD, t, 'standby', 'recovery', 'receiving', 1000, NULL, true, '{"kind":"standby","has_receiver":true}'::jsonb
  from generate_series(date_trunc('minute', now()) - interval '30 days', date_trunc('minute', now()) - interval '10 minutes', interval '1 minute') t
union all
select $LD, t, 'receiver', 'hadr_slot', 'streaming', NULL, (extract(epoch from t)::bigint % 17)::float8, NULL, '{"kind":"receiver"}'::jsonb
  from generate_series(date_trunc('minute', now()) - interval '30 days', date_trunc('minute', now()) - interval '10 minutes', interval '1 minute') t
union all
select $LD, t, 'conflict', 'db' || g, NULL, NULL, NULL, NULL,
       jsonb_build_object('kind', 'conflict', 'datname', 'db' || g, 'confl_tablespace', 0, 'confl_lock', (extract(epoch from t)::bigint / 3600 + g) % 5,
                          'confl_snapshot', 0, 'confl_bufferpin', 0, 'confl_deadlock', 0)
  from generate_series(date_trunc('minute', now()) - interval '30 days', date_trunc('minute', now()) - interval '10 minutes', interval '1 minute') t, generate_series(1, 300) g;
select count(*) from pgvigil.replication_sample where instance_id = $LD;
SQL
)
  echo "  LD seeded $(tail -1 <<<"$r") samples in $(( $(date +%s) - t0 )) s"
  # an upgraded store's history is weeks old: checkpointed and vacuumed long ago - the seed's own checkpoint and
  # autovacuum are the rig's, not the upgrade's (the first green run's slowest import, 2092 ms, fell beside them)
  t0=$(date +%s); psql "$RDSN dbname=pgvigil" -XAtq -c "checkpoint" -c "vacuum (analyze) pgvigil.replication_sample" >/dev/null 2>&1
  echo "  LD the seed settled (checkpoint, vacuum analyze) in $(( $(date +%s) - t0 )) s"
  ( s0=$(date +%s%N); psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 -c "select pgvigil.replication_hourly_heal_one($LD)" > "$WORK/ld-build.out" 2>&1
    echo "rc $? ms $(( ($(date +%s%N) - s0) / 1000000 ))" >> "$WORK/ld-build.out" ) & LDB=$!
  sleep 2; worst=0; n=0
  CONF=$(q "select '[' || string_agg(format('{\"kind\":\"conflict\",\"datname\":\"db%s\",\"confl_lock\":0}', g), ',') || ',{\"kind\":\"standby\",\"has_receiver\":true,\"conninfo_set\":true}]' from generate_series(1, 300) g")
  : > "$WORK/ld-times"
  while kill -0 "$LDB" 2>/dev/null && (( n < 200 )); do   # each import's wall time (psql's connect included) and its server time
    t1=$(date +%s%N)
    sv=$(q "with i as (select pgvigil.import_replication($LD, now(), '$CONF'::jsonb)) select round(extract(epoch from clock_timestamp() - statement_timestamp()) * 1000) from i")
    ms=$(( ($(date +%s%N) - t1) / 1000000 )); echo "$ms $sv" >> "$WORK/ld-times"; (( ms > worst )) && worst=$ms; n=$((n + 1)); sleep 1
  done
  echo "  LD imports during the build (ms): wall p50 / p95 / max $(sort -n "$WORK/ld-times" | awk '{a[NR]=$1} END {print a[int(NR*0.5)+1] " / " a[int(NR*0.95)] " / " a[NR]}'), server max $(sort -k2 -n "$WORK/ld-times" | tail -1 | cut -d' ' -f2), over 1 s: $(awk '$1 > 1000' "$WORK/ld-times" | wc -l)"
  wait "$LDB" 2>/dev/null; b=$(tail -1 "$WORK/ld-build.out")
  r=$(q "select (select count(*) from pgvigil.replication_hourly where instance_id = $LD and kind = 'receiver') || '|' ||
             (select count(*) from pgvigil.replication_hourly_first_build where instance_id = $LD) || '|' ||
             (select count(*) from pgvigil.replication_hourly_dirty where instance_id = $LD and source = 'build')")
  echo "  LD the build: $b; $n imports during it, the slowest $worst ms; (receiver hours|first build|build range left) $r"
  [[ "$b" == rc\ 0\ * && "$n" -ge 1 && "$worst" -lt 2000 && "$r" == 72[0-9]\|1\|0 ]] && ok "LD the first build ($b) ran beside $n imports, each under 2 s (slowest $worst ms); 72x receiver hours" || fail "LD build '$b', $n imports, slowest $worst ms, '$r' (expected rc 0, every import under 2000 ms, 72x|1|0)"
  imp "$LD" "now()" "$CONF"
  r=$(q "select count(*) from pgvigil.replication_hourly_dirty where instance_id = $LD")
  [[ "$r" == 0 ]] && ok "LD the import after the build healed the hours marked during it" || fail "LD dirty ranges after the build: $r"
  echo "  LD measured: $(q "select (select count(*) from pgvigil.replication_hourly) || ' hour rows in ' || count(*) || ' partitions, ' || pg_size_pretty(sum(pg_total_relation_size(c.oid))) || ' with indexes, ' || coalesce(round(sum(pg_total_relation_size(c.oid)) / nullif((select count(*) from pgvigil.replication_hourly), 0)), 0) || ' B a row; HOT updates ' || coalesce(sum(s.n_tup_hot_upd), 0) || ' of ' || coalesce(sum(s.n_tup_upd), 0)
                          from pg_inherits i join pg_class c on c.oid = i.inhrelid left join pg_stat_user_tables s on s.relid = c.oid where i.inhparent = 'pgvigil.replication_hourly'::regclass" 2>&1)"
fi
# ---- 375: a cascaded standby, standby queries cancelled, the cluster checks (CL ends the rig) ------------------------
rc_() { local i; for i in "$@"; do "$BIN" collect -config "$CFG" -once rolechange -instance "$i" >>"$WORK/collect.out" 2>&1 || echo "  (rolechange of $i failed: $(tail -1 "$WORK/collect.out"))"; done; }
cdetail() { q "select check_name || '|' || severity || '|' || detail from pgvigil.pg_cluster_checks where instance_id = $1 and check_name = '$2'"; }
if want CC || want SQ || want CL; then
  CP=$(fp); XP=$(fp)
  CDSN="host=127.0.0.1 port=$CP user=postgres password=$PW sslmode=disable dbname=postgres"
  cq() { psql "$CDSN" -XAtq -c "$1" 2>/dev/null; }
  # hadr-c: a standby of the standby (pg_basebackup from hadr-s), max_standby_streaming_delay 0 (its queries yield to replay)
  docker run -d --name "$CAS" --network "$NET" --user postgres -e PGPASSWORD="$PW" -p "127.0.0.1:$CP:5432" postgres:18 bash -c 'set -e; D=/var/lib/postgresql/cdata
    if [ ! -s "$D/PG_VERSION" ]; then pg_basebackup -h standby -U postgres -D "$D" -R -X stream -c fast; chmod 700 "$D"; fi
    exec postgres -D "$D" -c cluster_name=hadrc1 -c hot_standby=on -c listen_addresses="*" -c max_standby_streaming_delay=0' >/dev/null
  for _ in $(seq 1 90); do [[ "$(cq "select status from pg_stat_wal_receiver")" == streaming ]] && break; sleep 1; done
  [[ "$(cq "select status from pg_stat_wal_receiver")" == streaming ]] || { fail "375 rig: hadr-c is not streaming from hadr-s"; docker logs --tail 15 "$CAS"; }
  { cat "$WORK/pgvigil.yaml"; printf '  - name: hadr-c\n    dsn: "host=127.0.0.1 port=%s user=pgv password=%s dbname=postgres sslmode=disable"\n' "$CP" "$MPW"
    printf '  - name: hadr-x\n    dsn: "host=127.0.0.1 port=%s user=pgv password=%s dbname=postgres sslmode=disable"\n' "$XP" "$MPW"; } > "$WORK/pgvigil-375.yaml"
  CFG=$WORK/pgvigil-375.yaml
  "$BIN" collect -config "$CFG" -once instance -instance hadr-c >>"$WORK/collect.out" 2>&1 || fail "375 rig: instance read of hadr-c: $(tail -1 "$WORK/collect.out")"
  CID=$(q "select instance_id from pgvigil.instances where name = 'hadr-c'")
  rc_ hadr-p hadr-s hadr-c
fi
if want CC; then
  read_ hadr-s 2; read_ hadr-c 1; read_ hadr-p 1
  r=$(q "select status || '|' || sending_in_recovery || '|' || coalesce(standby_id::text, '-') from pgvigil.pg_repl_link_health where sending_id = $SID_ and link like 'app:hadrc1@%'")
  [[ "$r" == "streaming (cascaded from hadr-s)|true|$CID" ]] && ok "CC hadr-c's link from hadr-s: $r" || fail "CC the cascaded link (status|sending_in_recovery|standby): '$r', expected 'streaming (cascaded from hadr-s)|true|$CID'"
  r=$(q "select count(*) || '|' || string_agg(status, ',') from pgvigil.pg_repl_link_health where standby_id = $CID")
  r2=$(q "select status from pgvigil.pg_repl_link_health where sending_id = $PID_ and link like 'app:hadrs1@%'")
  [[ "$r" == 1\|* && "$r2" == streaming ]] && ok "CC hadr-c paired once ($r); hadr-p's own link to hadr-s stays 'streaming'" || fail "CC pairing: hadr-c '$r' (expected one row), hadr-p -> hadr-s '$r2' (expected streaming)"
fi
if want SQ; then
  pq "create table if not exists hadr_sq (id int); insert into hadr_sq values (1)" >/dev/null
  for _ in $(seq 1 30); do [[ "$(cq "select count(*) from hadr_sq")" =~ ^[1-9] ]] && break; sleep 1; done
  read_ hadr-c 1   # the counters before
  for k in 1 2 3; do
    ( psql "$CDSN" -XAtq -c "begin" -c "select count(*) from hadr_sq" -c "select pg_sleep(30)" -c "commit" > "$WORK/sq$k.out" 2>&1 ) & SQP=$!
    sleep 2; pq "begin; lock table hadr_sq in access exclusive mode; commit" >/dev/null
    for _ in $(seq 1 25); do kill -0 "$SQP" 2>/dev/null || break; sleep 1; done; kill "$SQP" 2>/dev/null; wait "$SQP" 2>/dev/null
  done
  n=$(grep -l "conflict with recovery" "$WORK"/sq[123].out 2>/dev/null | wc -l)
  read_ hadr-c 1
  r=$(finding "$CID" 'standby queries cancelled'); r2=$(cdetail "$CID" 'standby queries cancelled')
  [[ "$n" == 3 && "$r" == "warning|database postgres: queries cancelled by recovery conflicts (warning at 3 in 10 minutes)" && "$r2" == *"3 queries cancelled"*"confl_lock +3"* ]] \
    && ok "SQ $n standby queries cancelled on hadr-c: '$r' ($r2)" || fail "SQ $n of 3 cancelled; finding '$r', check '$r2' (expected the warning, confl_lock +3)"
  r=$(finding "$PID_" 'standby queries cancelled')
  [[ -z "$r" ]] && ok "SQ nothing on the primary" || fail "SQ raised on hadr-p: '$r'"
  # the window passed: the conflict reads moved 13 minutes back (a stand-in for the wait), the finding is gone
  q "update pgvigil.replication_sample set snapshot_at = snapshot_at - interval '13 minutes' where instance_id = $CID and kind = 'conflict' and snapshot_at > now() - interval '30 minutes'" >/dev/null
  r=$(finding "$CID" 'standby queries cancelled')
  [[ -z "$r" ]] && ok "SQ gone once its reads are past the window" || fail "SQ still raised past the window: '$r'"
fi
if want CL; then
  # RB2 an instance that never changed role: unknown before its first read, then its role
  r=$(q "select string_agg(role, ',' order by from_at) from pgvigil.pg_role_bands($PID_, now() - interval '1 day', now())")
  [[ "$r" == "unknown,primary" ]] && ok "RB2 hadr-p's bands (never changed role): $r" || fail "RB2 hadr-p's bands: '$r', expected unknown,primary"
  # CL3 a promoted copy that never streamed (a backup of hadr-p started as a primary): nothing
  docker run -d --name "$CPY" --network "$NET" --user postgres -e PGPASSWORD="$PW" -p "127.0.0.1:$XP:5432" postgres:18 bash -c 'set -e; D=/var/lib/postgresql/xdata
    if [ ! -s "$D/PG_VERSION" ]; then pg_basebackup -h primary -U postgres -D "$D" -X stream -c fast; chmod 700 "$D"; fi
    exec postgres -D "$D" -c cluster_name=hadrx1 -c listen_addresses="*"' >/dev/null
  for _ in $(seq 1 90); do psql "host=127.0.0.1 port=$XP user=postgres password=$PW sslmode=disable dbname=postgres" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  "$BIN" collect -config "$CFG" -once instance -instance hadr-x >>"$WORK/collect.out" 2>&1 || fail "CL3 instance read of hadr-x: $(tail -1 "$WORK/collect.out")"
  XID=$(q "select instance_id from pgvigil.instances where name = 'hadr-x'")
  rc_ hadr-x hadr-p; sleep 60; rc_ hadr-x hadr-p
  r=$(q "select coalesce(string_agg(instance_id || ' ' || check_name, ', '), '') from pgvigil.pg_cluster_checks where check_name in ('two primaries', 'cluster without a primary')")
  r2=$(q "select (select system_identifier from pgvigil.pg_role_state where instance_id = $XID) = (select system_identifier from pgvigil.pg_role_state where instance_id = $PID_)")
  [[ -z "$r" && "$r2" == t ]] && ok "CL3 a copy of hadr-p started as a primary (one system identifier, never a standby): no cluster finding" || fail "CL3 the copy: '$r' (expected none), same identifier '$r2'"
  docker rm -f -v "$CPY" >/dev/null
  # CL2 the primary stopped (a real stop): hadr-s's receiver down, hadr-c cascaded from hadr-s; past 3 minutes no
  # fresh primary: 'cluster without a primary' critical on hadr-p (the member last seen primary)
  rc_ hadr-p; docker stop "$PRI" >/dev/null
  for k in 1 2 3 4 5 6 7; do sleep 30; read_ hadr-s 1; read_ hadr-c 1; (( k % 2 == 0 )) && rc_ hadr-s hadr-c; done
  rc_ hadr-s hadr-c
  r=$(finding "$PID_" 'cluster without a primary'); r2=$(cdetail "$PID_" 'cluster without a primary')
  r3=$(q "select count(*) from pgvigil.pg_cluster_checks where check_name = 'cluster without a primary'")
  [[ "$r" == critical\|"system identifier "*": no primary: every standby's WAL receiver is down" && "$r2" == *"standbys hadr-s have had no WAL receiver"* && "$r3" == 1 ]] \
    && ok "CL2 'cluster without a primary' on hadr-p once ($r2)" || fail "CL2 '$r' / '$r2' / rows $r3 (expected one critical on hadr-p naming hadr-s)"
  # CL4 a switchover with the old primary stopped: hadr-s promoted; nothing (hadr-p not read), the headless finding gone
  sq "select pg_promote()" >/dev/null
  for _ in $(seq 1 30); do [[ "$(sq 'select pg_is_in_recovery()')" == f ]] && break; sleep 1; done
  rc_ hadr-s; sleep 60; rc_ hadr-s hadr-c; read_ hadr-s 1; read_ hadr-c 1
  r=$(q "select coalesce(string_agg(instance_id || ' ' || check_name, ', '), '') from pgvigil.pg_cluster_checks where check_name in ('two primaries', 'cluster without a primary')")
  [[ -z "$r" ]] && ok "CL4 hadr-s promoted while hadr-p is stopped: no cluster finding" || fail "CL4 after the switchover: '$r', expected none"
  r=$(q "select string_agg(role, ',' order by from_at) from pgvigil.pg_role_bands($SID_, now() - interval '1 day', now())")
  r2=$(q "select to_char(min(to_at), 'HH24:MI') = to_char((select max(changed_at) from pgvigil.pg_role_changes where instance_id = $SID_ and change = 'promotion'), 'HH24:MI')
            from pgvigil.pg_role_bands($SID_, now() - interval '1 day', now()) where role = 'standby'")
  [[ "$r" == "unknown,standby,primary" && "$r2" == t ]] && ok "RB hadr-s's bands across its promotion: $r (the standby band ends at the promotion)" || fail "RB hadr-s's bands: '$r' (expected unknown,standby,primary), ends at the promotion '$r2'"
  # CL1 the old primary back while hadr-s is primary: two primaries, critical on each
  docker start "$PRI" >/dev/null
  for _ in $(seq 1 60); do pq "select 1" >/dev/null 2>&1 && break; sleep 1; done
  rc_ hadr-p hadr-s; sleep 60; rc_ hadr-p hadr-s
  r=$(finding "$PID_" 'two primaries'); r2=$(finding "$SID_" 'two primaries')
  [[ "$r" == "critical|system identifier "*": primary together with hadr-s: a split brain" && "$r2" == "critical|system identifier "*": primary together with hadr-p: a split brain" ]] \
    && ok "CL1 'two primaries' critical on hadr-p and on hadr-s, each naming the other" || fail "CL1 hadr-p '$r', hadr-s '$r2' (expected critical on each naming the other)"
  # CL1b the lead's case: a standby promoted while its primary runs (hadr-c, streaming from hadr-s)
  read_ hadr-s 1
  cq "select pg_promote()" >/dev/null
  for _ in $(seq 1 30); do [[ "$(cq 'select pg_is_in_recovery()')" == f ]] && break; sleep 1; done
  rc_ hadr-c hadr-s; sleep 60; rc_ hadr-c hadr-s
  r=$(finding "$CID" 'two primaries'); r2=$(finding "$SID_" 'two primaries')
  [[ "$r" == *"primary together with hadr-s: a split brain" && "$r2" == *"primary together with hadr-c, hadr-p: a split brain" ]] \
    && ok "CL1b hadr-c promoted while hadr-s runs: 'two primaries' on hadr-c ($r) and hadr-s ($r2)" || fail "CL1b hadr-c '$r', hadr-s '$r2' (expected hadr-c naming hadr-s, hadr-s naming hadr-c and hadr-p)"
fi

echo "rows run: ${PROOF_ONLY:-all}"
if (( FAILS == 0 )); then echo "proof-pg-hadr: OK"; exit 0; fi
echo "proof-pg-hadr: $FAILS FAIL"; exit 1
