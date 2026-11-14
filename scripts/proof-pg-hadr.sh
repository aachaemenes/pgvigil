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
# Expected (written before the first run, 2026-11-14 09:2x PST; the tree before task 370's fix (35e627e) fails R1's second
# assertion, R2W's three, R2C, G's second ('raised again') and R3's last two, and passes B, R1B, G's first, the clears and
# R3's first: 'receiver down' and 'standby gone' do not exist there, so they cannot raise):
#   B    the healthy pair: hadr-s's replication read has a receiver row 'streaming'; hadr-p's has a sender row of
#        application_name hadrs1 'streaming'; no 'receiver down', 'standby gone' or 'sender not streaming' anywhere
#   R1   task 370 (a): pg_basebackup -X stream throttled to 32 kB/s from a third container, read on hadr-p while it runs:
#        the read stores its senders (a sender row in state 'backup', application_name pg_basebackup), and NOT ONE
#        'sender not streaming' row of hadr-p in replication_checks names pg_basebackup (the tree before the fix: one
#        per base-backup sender, state 'backup')
#   R1B  the base backup killed, two reads of hadr-p: no 'standby gone' for it (a base backup is no standby)
#   R2W  task 370 (b), warning: the standby's receiver killed (SIGTERM to pg_stat_wal_receiver's pid) and held down (the
#        primary's pg_hba rejects replication from the standby's address), writes and pg_switch_wal on the primary every
#        2 s so replay advances through restore_command; two reads of hadr-s 10 s apart: 'receiver down' on hadr-s in
#        pgvigil.findings, severity warning; the same check in replication_checks, its detail saying replay advances
#        through restore_command
#   R2C  the 'restore_stall' threshold set to 1 minute on hadr-s through import_pg_threshold (outcome done), the writes
#        stopped (nothing more to restore), a read of hadr-s 15 s later (it sees replay's last move: a move is dated by
#        the read that sees it), 70 s, one more read: 'receiver down' on hadr-s, severity critical,
#        replication_checks' detail saying replay has stopped, the finding's value the same as R2W's (one alert key)
#   R2X  the reject line removed: the receiver reconnects (streaming), one read of hadr-s: 'receiver down' gone from
#        pgvigil.findings and replication_checks
#   G    the managed gate: hadr-s read with 'platform: rds' in its config (the user's own way to name the platform) while
#        its receiver is held down again (two reads): no 'receiver down' for it (a managed replica is the provider's);
#        the plain config back: one read raises it again; the hold lifted after (a forced kind on a real standby: no
#        managed replica here)
#   R3   the standby stopped (docker stop), two reads of hadr-p: 'standby gone' on hadr-p naming hadrs1, severity
#        critical, in pgvigil.findings and in replication_checks; before the second read nothing (one read is no streak)
#   R3X  the standby started again and streaming, one read of hadr-p: 'standby gone' gone
# PROOF_ONLY=R1,R2W,... runs the rig, B and the named rows only (B R1 R1B R2W R2C R2X G R3 R3X); unset = all.
# Prints 'ok' / 'FAIL' per assertion and 'proof-pg-hadr: OK' or 'proof-pg-hadr: <n> FAIL'; exit 0 only when every row passed.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); FAILS=0
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $*"; }
want() { [[ -z "${PROOF_ONLY:-}" || ",${PROOF_ONLY// /}," == *",$1,"* ]]; }
fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
MPW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
RP=$(fp); PP=$(fp); SP=$(fp)
NET=pgvhadr-$$; REPO=pgvhadr-repo-$$; PRI=pgvhadr-p-$$; STB=pgvhadr-s-$$; BB=pgvhadr-bb-$$; ARC=pgvhadr-arc-$$
FEED=""; R2W_VALUE=""
cleanup() {
  [[ -n "$FEED" ]] && kill "$FEED" 2>/dev/null || true
  docker rm -f -v "$BB" "$STB" "$PRI" "$REPO" >/dev/null 2>&1 || true
  docker volume rm "$ARC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  for c in "$BB" "$STB" "$PRI" "$REPO"; do docker inspect "$c" >/dev/null 2>&1 && echo "container $c LEFT"; done
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
  -p "127.0.0.1:$PP:5432" postgres:18 -c wal_level=replica -c max_wal_senders=10 -c archive_mode=on \
  -c "archive_command=test ! -f /archive/wal/%f && cp %p /archive/wal/%f" -c cluster_name=hadrp >/dev/null
RDSN="host=127.0.0.1 port=$RP user=postgres password=$PW sslmode=disable"
PDSN="host=127.0.0.1 port=$PP user=postgres password=$PW sslmode=disable dbname=postgres"
SDSN="host=127.0.0.1 port=$SP user=postgres password=$PW sslmode=disable dbname=postgres"
for d in "$RDSN dbname=postgres" "$PDSN"; do for _ in $(seq 1 60); do psql "$d" -XAtqc 'select 1' >/dev/null 2>&1 && break; sleep 1; done; done; sleep 3
for d in "$RDSN dbname=postgres" "$PDSN"; do psql "$d" -XAtqc 'select 1' >/dev/null 2>&1 || { echo "FAIL the rig: $d does not answer"; exit 1; }; done
psql "$RDSN dbname=postgres" -XAtqc "create database pgvigil" >/dev/null
pq() { psql "$PDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
sq() { psql "$SDSN" -XAtq -c "$1" 2>/dev/null; }
q() { psql "$RDSN dbname=pgvigil" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
pq "create role pgv login password '$MPW' in role pg_monitor" >/dev/null
pq "create table hadr_feed (id bigserial primary key, at timestamptz default now(), pad text)" >/dev/null
# replication from any address with a password (the image's own lines cover local and 'all' databases only)
docker exec "$PRI" bash -c 'echo "host replication all all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
pq "select pg_reload_conf()" >/dev/null
docker run -d --name "$STB" --network "$NET" --network-alias standby --user postgres -e PGPASSWORD="$PW" -v "$ARC:/archive" \
  -p "127.0.0.1:$SP:5432" postgres:18 bash -c 'set -e; D=/var/lib/postgresql/sdata
    if [ ! -s "$D/PG_VERSION" ]; then pg_basebackup -h primary -U postgres -D "$D" -R -X stream -c fast; chmod 700 "$D"; fi
    exec postgres -D "$D" -c cluster_name=hadrs1 -c hot_standby=on -c listen_addresses="*" -c "restore_command=cp /archive/wal/%f %p"' >/dev/null
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
CFG=$WORK/pgvigil.yaml
"$BIN" migrate -config "$WORK/pgvigil.yaml" >"$WORK/migrate.out" 2>&1 || { cat "$WORK/migrate.out"; exit 1; }
"$BIN" collect -config "$WORK/pgvigil.yaml" -once instance >"$WORK/instance.out" 2>&1 || { cat "$WORK/instance.out"; exit 1; }
PID_=$(q "select instance_id from pgvigil.instances where name='hadr-p'")
SID_=$(q "select instance_id from pgvigil.instances where name='hadr-s'")
read_() { # read_ <instance> [n] [gap]: n replication reads of one instance, gap (3) seconds apart
  local n=${2:-1} gap=${3:-3} i
  for ((i = 0; i < n; i++)); do
    (( i > 0 )) && sleep "$gap"
    "$BIN" collect -config "$CFG" -once replication -instance "$1" >>"$WORK/collect.out" 2>&1 || { echo "  (read of $1 failed: $(tail -1 "$WORK/collect.out"))"; }
  done
}
finding() { # finding <instance_id> <setting> -> 'severity|value' lines
  q "select severity || '|' || value from pgvigil.findings where instance_id = $1 and setting = '$2' order by 1"
}
check() { # check <instance_id> <check_name> -> 'object|state' lines of replication_checks
  q "select object || '|' || coalesce(state, '') from pgvigil.replication_checks where instance_id = $1 and check_name = '$2' order by 1"
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

# ---- R1: a base backup's senders -----------------------------------------------------------------------------------
if want R1 || want R1B; then
  docker run -d --name "$BB" --network "$NET" -e PGPASSWORD="$PW" postgres:18 \
    pg_basebackup -h primary -U postgres -D /tmp/bb -X stream --max-rate=32k -c fast >/dev/null
  for _ in $(seq 1 30); do [[ "$(pq "select count(*) from pg_stat_replication where state = 'backup'")" -ge 1 ]] && break; sleep 1; done
  echo "  hadr-p's senders during the base backup: $(pq "select string_agg(application_name || '/' || state, ', ') from pg_stat_replication")"
  read_ hadr-p 2
  if want R1; then
    r=$(q "select count(*) from pgvigil.replication_latest where instance_id = $PID_ and kind = 'sender' and state = 'backup' and detail->>'application_name' = 'pg_basebackup'")
    [[ "$r" -ge 1 ]] && ok "R1 the read stored the base backup's sender (state backup): $r" || fail "R1 no stored sender in state 'backup' (the base backup did not run? $r)"
    r=$(check "$PID_" 'sender not streaming' | grep -c 'pg_basebackup')
    [[ "$r" == "0" ]] && ok "R1 no 'sender not streaming' for pg_basebackup" || fail "R1 'sender not streaming' for the base backup: $(check "$PID_" 'sender not streaming' | tr '\n' ';')"
  fi
  docker rm -f "$BB" >/dev/null 2>&1
  for _ in $(seq 1 20); do [[ "$(pq "select count(*) from pg_stat_replication where application_name = 'pg_basebackup'")" == "0" ]] && break; sleep 1; done
  if want R1B; then
    read_ hadr-p 2
    r=$(finding "$PID_" 'standby gone' | grep -c 'pg_basebackup')
    [[ "$r" == "0" ]] && ok "R1B no 'standby gone' for the finished base backup" || fail "R1B 'standby gone' for a base backup: $(finding "$PID_" 'standby gone' | tr '\n' ';')"
  fi
fi

# ---- R2: the receiver killed and held down -------------------------------------------------------------------------
if want R2W || want R2C || want R2X; then
  if hold_down; then
    feed_on
    l0=$(sq "select pg_last_wal_replay_lsn()"); sleep 8; l1=$(sq "select pg_last_wal_replay_lsn()")
    echo "  receiver held down: wal_receiver rows $(sq "select count(*) from pg_stat_wal_receiver"), replay $l0 -> $l1 through restore_command"
    if want R2W; then
      read_ hadr-s 2 10
      r=$(finding "$SID_" 'receiver down')
      [[ "$r" == warning\|* ]] && ok "R2W 'receiver down' warning on hadr-s: $r" || fail "R2W 'receiver down' on hadr-s: '$r', expected warning"
      R2W_VALUE=${r#*|}
      r=$(check "$SID_" 'receiver down')
      [[ "$r" == *"advances through restore_command"* ]] && ok "R2W replication_checks: $r" || fail "R2W replication_checks without 'advances through restore_command': '$r'"
    fi
    feed_off
    if want R2C; then
      r=$(q "select pgvigil.import_pg_threshold(now(), '{\"op\":\"set\",\"key\":\"restore_stall\",\"level\":\"instance\",\"instance_id\":$SID_,\"crit\":1,\"ui_user\":\"proof\"}'::jsonb)->>'outcome'")
      [[ "$r" == "done" ]] && ok "R2C restore_stall set to 1 min on hadr-s" || fail "R2C the threshold was not set: '$r'"
      # replay's last move is dated by the read that sees it: one read once the last file is restored, then the stall
      sleep 15; read_ hadr-s 1; sleep 70; read_ hadr-s 1
      r=$(finding "$SID_" 'receiver down')
      [[ "$r" == critical\|* ]] && ok "R2C 'receiver down' critical on hadr-s: $r" || fail "R2C 'receiver down' on hadr-s: '$r', expected critical"
      r2=$(check "$SID_" 'receiver down')
      [[ "$r2" == *"replay has stopped"* ]] && ok "R2C replication_checks: $r2" || fail "R2C replication_checks without 'replay has stopped': '$r2'"
      [[ "${r#*|}" == "$R2W_VALUE" ]] && ok "R2C the finding's value kept from R2W (one alert key)" || fail "R2C the value changed: '$R2W_VALUE' -> '${r#*|}'"
    fi
    if lift; then
      if want R2X; then
        read_ hadr-s 1
        r=$(finding "$SID_" 'receiver down'); r2=$(check "$SID_" 'receiver down')
        [[ -z "$r$r2" ]] && ok "R2X 'receiver down' cleared after the receiver came back" || fail "R2X still raised: '$r' / '$r2'"
      fi
    else fail "R2X the receiver did not come back after the lift"; fi
  else fail "R2 the receiver could not be held down"; fi
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
    lift || fail "G the receiver did not come back after the lift"
    read_ hadr-s 1
  else fail "G the receiver could not be held down"; fi
fi

# ---- R3: the standby stopped ---------------------------------------------------------------------------------------
if want R3 || want R3X; then
  read_ hadr-p 1
  docker stop -t 10 "$STB" >/dev/null
  for _ in $(seq 1 20); do [[ "$(pq "select count(*) from pg_stat_replication where application_name = 'hadrs1'")" == "0" ]] && break; sleep 1; done
  read_ hadr-p 1
  if want R3; then
    r=$(finding "$PID_" 'standby gone')
    [[ -z "$r" ]] && ok "R3 one read after the stop: nothing yet" || fail "R3 raised after one read: '$r'"
  fi
  read_ hadr-p 1
  if want R3; then
    r=$(finding "$PID_" 'standby gone')
    [[ "$r" == critical\|*hadrs1* ]] && ok "R3 'standby gone' critical on hadr-p: $r" || fail "R3 'standby gone' on hadr-p: '$r', expected critical naming hadrs1"
    r=$(check "$PID_" 'standby gone')
    [[ "$r" == *hadrs1* ]] && ok "R3 replication_checks: $r" || fail "R3 no 'standby gone' naming hadrs1 in replication_checks: '$r'"
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

if (( FAILS == 0 )); then echo "proof-pg-hadr: OK"; exit 0; fi
echo "proof-pg-hadr: $FAILS FAIL"; exit 1
