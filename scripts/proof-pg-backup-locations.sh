#!/usr/bin/env bash
# Proof of task 302: where a PostgreSQL server's base backups and WAL go (migration 0148, internal/collect/backup_dest.go's
# collection backup_dest, the read_tools opt-in in readBackupTool, /api/pg/backup_dest through the lead's wiring,
# scripts/inv-302-wiring.patch on top of 301's and 304's).
#
# Needs: docker (its own PostgreSQL 17, 13 and 18 containers), psql, curl, python3, a go toolchain; and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form; the proof makes its own database
#                      there (a password in it goes to PGPASSWORD, never onto a command line).
# Optional: PGVIGIL_BIN (default bin/pgvigil), PROOF_SKIP_PAGE=1. Everything it makes goes on every exit path.
#
# Expected (written before the first run). Each row sets the monitored server's settings with ALTER SYSTEM and a reload,
# runs `collect -once backup_dest` and reads pgvigil.pg_backup_dest (role|tool|kind|host|container|path|secret_seen):
#  P1  pgBackRest, the configuration read: archive_command 'pgbackrest --stanza=demo archive-push %p'; the collector's
#      PGBACKREST_CONFIG names a file with [global] repo1-path=/var/lib/pgbackrest, repo1-retention-full=2 and a
#      repo1-cipher-pass literal. pgvd-a (read_tools on): source 'pgbackrest configuration' rows wal and base
#      'pgbackrest|posix|||/var/lib/pgbackrest', detail with 'retention 2 full (backups)' and 'not encrypted' (no
#      cipher-type), the read row 'ok'. pgvd-b (read_tools off, the same server): the read row 'off', the finding 'backup
#      tool read off' (info); `collect -once backup_tools` on pgvd-b: pg_backup_tools pgbackrest|demo state not_read, the
#      finding 'base backups not read' (info).
#  P2  the same file as repo1-type=s3, bucket pgvdb, endpoint s3.lab.internal, path /pg, repo1-s3-key and -key-secret
#      literals: 'wal|pgbackrest|s3|s3.lab.internal|pgvdb|/pg|false' from the configuration.
#  P3  barman-wal-archive backup1 pg %p, a stand-in 'barman' on the collector's PATH printing show-servers JSON whose
#      conninfo holds a password literal: source 'barman' rows base 'posix /var/lib/barman/pg/base' and wal
#      '/var/lib/barman/pg/wals', detail with the method and the retention; the stand-in is NOT a real barman (NOT PROVEN:
#      a real barman's answer).
#  P4  'PGPASSWORD=<literal> rsync -a %p backup@host1:/wal/%f': 'wal|rsync|host|host1||/wal|true'; the finding 'a credential
#      is written in the archiver's command' (warning).
#  P5  azcopy with a SAS URL: 'wal|azcopy|azure|acct.blob.core.windows.net||/wal|true'; curl -T to https://user:<literal>@
#      files.lab/wal/%f: 'wal|curl|https|files.lab||/wal|true'.
#  P6  the documented examples: 'test ! -f /mnt/server/archivedir/%f && cp %p /mnt/server/archivedir/%f' ->
#      'wal|copy|posix|||/mnt/server/archivedir|false'; 'gzip < %p > /mnt/server/archivedir/%f.gz' the same directory;
#      restore_command 'cp /mnt/server/archivedir/%f %p' on the primary -> a restore row whose detail says 'set, not in
#      use'; archive_library = basic_archive with basic_archive.archive_directory = /var/lib/postgresql/arch ->
#      'wal|basic_archive|posix|||/var/lib/postgresql/arch' from source archive_library; '/bin/true' -> 'WAL is discarded'
#      (warning).
#  P7  'WALG_S3_PREFIX=s3://pgvdb/wal wal-g wal-push %p' -> 'wal|wal-g|s3||pgvdb|/wal|false'; 'envdir /etc/wal-e.d/env
#      wal-e wal-push %p' -> the envdir named, 'not known'; '/usr/local/bin/archive.sh %p %f' -> 'a script (archive.sh)'.
#  P8  pgvd-off (PostgreSQL 18, archive_mode off): WAL to 'WAL is not archived (archive_mode off)', base backups 'not
#      known'; an entry 'backup1:/srv/pg (a pg_basebackup from cron)' through import_backup_dest_entry shows as entered
#      with who and when, a second one keeps the first as history, a credential entry is refused. NOT PROVEN: the API's
#      POST seat (an admin once the roles join) and 'a reader login cannot write'.
#  P9  barman-cloud-wal-archive with an inline --sse-customer-key literal: 'wal|barman-cloud|s3||pgvbk|/pg|true'.
#  P10 RDS / Aurora: the store test's stubbed row (TestBackupDestOnAStore) - NOT PROVEN live on RDS.
#  P12 PostgreSQL 13 (no archive_library): the read answers, a wal row from archive_command.
#  P12b PostgreSQL 15, archive_command and archive_library both set: the library wins there -
#      'wal|basic_archive|posix|||/var/lib/postgresql/arch|false' from source archive_library.
#  P12c PostgreSQL 17, both set: 'wal|none|||||false' from source archive_library, its detail 'WAL is not archived: both
#      archive_command and archive_library are set' (16 and later refuse to archive: pgarch.c).
#  S   the secrets: after EVERY row, none of the literals of P1-P9 is in that instance's pg_backup_dest / _reads rows or
#      its /api/pg/backup_dest answer (each read replaces the rows whole, so a search at the end alone sees only the last
#      row's); at the end none is in a plain pg_dump of the repository, the collector's output, the serve log or any
#      answer; the positive controls (a planted literal in an entry's note) ARE found by both searches.
#  I   (chromium + node) the Base backups tab with 'Where the backups go' and the fleet Backups page, light and dark:
#      drawn, no error box, 0 axe violation nodes (WCAG 2.1 A / AA).
#  NOT PROVEN HERE: a real barman and a real barman-cloud; RDS live; Azure, GCS, SFTP repositories (parser and
#  configuration only); a Windows server's copy line (the parser's table test); P1's other configuration shapes (a
#  repo1-host only file, no file, the environment over the file, [demo:archive-push], PGBACKREST_CONFIG beside a conf.d,
#  the deprecated un-indexed names, a stanza the file never names: TestPgbrConfig, TestBackupDestToolsFollowTheArchiver);
#  a failing tool printing a password (TestRunToolWords: stderr never read); the collector's debug-level log (the
#  default level's output is searched); barman's wals_directory as a cloud URL (TestBackupDestToolReads' base row holds
#  the URL rule).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of a PostgreSQL sandbox}"
if [[ " $PGVIGIL_REPO_DSN" =~ [[:space:]]password=([^[:space:]]+) ]]; then
  export PGPASSWORD="${BASH_REMATCH[1]}"; PGVIGIL_REPO_DSN=$(printf '%s' " $PGVIGIL_REPO_DSN" | sed -E 's/[[:space:]]password=[^[:space:]]+//; s/^ //')
fi
SUF=$RANDOM; C17=pgvd-17-$SUF; C13=pgvd-13-$SUF; C18=pgvd-18-$SUF; C15=pgvd-15-$SUF; REPO_DB=pgvigil_bdproof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out
pw() { printf 'Pd9%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SUPW=$(pw); MONPW=$(pw)
LIT1="cipherLIT$(pw)"; LIT2="AKIALIT$(pw)"; LIT3="s3secretLIT$(pw)"; LIT4="barmanLIT$(pw)"; LIT5="pgpassLIT$(pw)"; LIT6="sseLIT$(pw)"; LIT7="userpwLIT$(pw)"
PLANTED="PGVD-PLANTED-$(pw)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
MADE_DB=; SRVPID=; CHR=
cleanup() {
  rc=$?; set +e
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
  [ -n "$CHR" ] && kill "$CHR" 2>/dev/null
  docker rm -f -v "$C17" "$C13" "$C18" "$C15" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && psql "$PGVIGIL_REPO_DSN" -XAtqc "DROP DATABASE IF EXISTS $REPO_DB WITH (FORCE)" >/dev/null 2>&1
  rm -rf "$WORK"; echo "left: containers $(docker ps -aq --filter "name=pgvd-.*-$SUF" | wc -l)"; exit $rc
}
trap cleanup EXIT
RDSN=$(printf '%s' "$PGVIGIL_REPO_DSN" | sed -E "s/dbname=[^ ]+/dbname=$REPO_DB/"); [[ "$RDSN" == *"dbname=$REPO_DB"* ]] || RDSN="$PGVIGIL_REPO_DSN dbname=$REPO_DB"
q() { psql "$RDSN" -XAtqc "$1"; }
su() { local c=$1; shift; docker exec -i "$c" psql -U postgres -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "== containers and the store"
for spec in "$C17 17 on" "$C13 13 on" "$C18 18 off" "$C15 15 on"; do
  set -- $spec
  # archive_mode alone on the command line: a setting given there outranks ALTER SYSTEM (PostgreSQL's config docs,
  # 'Parameter Interaction via the Shell'), and every row changes archive_command with ALTER SYSTEM. PostgreSQL 15's
  # ALTER SYSTEM refuses a custom setting no loaded module defines (17 takes it), so basic_archive's directory is
  # given to 15 at its start, the one row that never changes it
  extra=(); [ "$2" = 15 ] && extra=(-c basic_archive.archive_directory=/var/lib/postgresql/arch)
  docker run -d --name "$1" --label pgvigil-proof=inv302 -e POSTGRES_PASSWORD="$SUPW" -p 127.0.0.1::5432 "postgres:$2" -c archive_mode="$3" "${extra[@]}" >/dev/null
done
for c in "$C17" "$C13" "$C18" "$C15"; do
  for _ in $(seq 1 60); do docker exec "$c" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
  su "$c" "CREATE ROLE pgvd_mon LOGIN PASSWORD '$MONPW' IN ROLE pg_monitor" >/dev/null
  su "$c" "ALTER SYSTEM SET archive_command = '/bin/true'" >/dev/null; su "$c" "SELECT pg_reload_conf()" >/dev/null
done
sleep 1
# ALTER SYSTEM's value is read where it was applied (pg_file_settings); SHOW is the effective value. PostgreSQL 16 and
# later SHOW archive_command as '(disabled)' while archive_mode is off (xlog.c show_archive_command), so the off
# container (18) wants '(disabled)' there, every other container the command itself
for spec in "$C17 on" "$C13 on" "$C18 off" "$C15 on"; do
  set -- $spec
  F=$(su "$1" "SELECT setting FROM pg_file_settings WHERE name = 'archive_command' AND applied"); S=$(su "$1" "SHOW archive_command")
  want=/bin/true; [ "$2" = off ] && want='(disabled)'
  [ "$F" = /bin/true ] && [ "$S" = "$want" ] || fail "the store: $1's archive_command did not take ALTER SYSTEM (applied: [$F], SHOW: [$S], want [/bin/true] and [$want])"
done
port() { docker port "$1" 5432/tcp | head -1 | sed 's/.*://'; }
psql "$PGVIGIL_REPO_DSN" -XAtqc "CREATE DATABASE $REPO_DB" >/dev/null; MADE_DB=1
export PGVIGIL_REPO_DSN_PROOF="$RDSN"
export PD17_DSN="host=127.0.0.1 port=$(port "$C17") user=pgvd_mon password=$MONPW dbname=postgres sslmode=disable"
export PD13_DSN="host=127.0.0.1 port=$(port "$C13") user=pgvd_mon password=$MONPW dbname=postgres sslmode=disable"
export PD18_DSN="host=127.0.0.1 port=$(port "$C18") user=pgvd_mon password=$MONPW dbname=postgres sslmode=disable"
export PD15_DSN="host=127.0.0.1 port=$(port "$C15") user=pgvd_mon password=$MONPW dbname=postgres sslmode=disable"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN_PROOF
instances:
  - name: pgvd-a
    dsn: env:PD17_DSN
    backups:
      read_tools: true
  - name: pgvd-b
    dsn: env:PD17_DSN
  - name: pgvd-13
    dsn: env:PD13_DSN
  - name: pgvd-off
    dsn: env:PD18_DSN
  - name: pgvd-15
    dsn: env:PD15_DSN
EOF
[ -x "$BIN" ] || go build -o "$BIN" ./cmd/pgvigil
"$BIN" migrate -config "$CFG" >/dev/null
SHIM=$WORK/shim; mkdir -p "$SHIM"
export PGBACKREST_CONFIG="$WORK/pgbackrest.conf"
collect() { PATH="$SHIM:$PATH" "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$OUT" 2>&1 || { cat "$OUT"; return 1; }; cat "$OUT" >> "$WORK/collect.log"; }
iid() { q "select instance_id from pgvigil.instances where name='$1'"; }
# the row's command must be the server's own before the read (the value is never printed: some rows carry a literal)
setcmd() { su "$C17" "ALTER SYSTEM SET archive_command = \$q\$$1\$q\$" >/dev/null; su "$C17" "SELECT pg_reload_conf()" >/dev/null; sleep 1
  [ "$(su "$C17" "SHOW archive_command")" = "$1" ] || fail "setcmd: the server's archive_command is not the row's command after the reload"; }
dests() { q "select coalesce(string_agg(concat_ws('|', role, coalesce(tool, ''), coalesce(dest_kind, ''), coalesce(host, ''), coalesce(container, ''), coalesce(path, ''), secret_seen::text), ' ;; ' order by role, seq), '') from pgvigil.pg_backup_dest where instance_id=$(iid "$1") and source='$2'"; }
detail() { q "select coalesce(string_agg(detail, ' ;; ' order by role, seq), '') from pgvigil.pg_backup_dest where instance_id=$(iid "$1") and source='$2'"; }
# the check's name is a psql variable (:'n' quotes it): names hold an apostrophe ('the archiver's command')
finding() { psql "$RDSN" -XAtq -v n="$2" -v i="$(iid "$1")" <<< "select count(*) from pgvigil.pg_backup_dest_findings where instance_id=:i and check_name=:'n'"; }
# what one instance's read stored and what the API answers for it (the per-row secret search's text)
rowtext() { q "select coalesce(string_agg(d::text, ' '), '') from pgvigil.pg_backup_dest d where instance_id=$(iid "$1")"
  q "select coalesce(string_agg(r::text, ' '), '') from pgvigil.pg_backup_dest_reads r where instance_id=$(iid "$1")"
  curl -s "$U/api/pg/backup_dest?instance=$(iid "$1")"; }
leakcheck() { local t lit; t=$(rowtext "$2"); for lit in "$LIT1" "$LIT2" "$LIT3" "$LIT4" "$LIT5" "$LIT6" "$LIT7"; do
  [[ "$t" == *"$lit"* ]] && fail "S: row $1 stored or answered a secret literal"; done; return 0; }
row() { collect backup_dest "${2:-pgvd-a}" || fail "$1: the read"; leakcheck "$1" "${2:-pgvd-a}"; }

# serve from the start: every row's API answer is searched (the read replaces its rows, so the end sees only the last)
PORT=$((20000 + RANDOM % 10000)); U="http://127.0.0.1:$PORT"
"$BIN" serve -config "$CFG" -dsn env:PGVIGIL_REPO_DSN_PROOF -listen "127.0.0.1:$PORT" -no-login > "$WORK/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "$U/api/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "$U/api/health" >/dev/null || fail "serve did not answer"


echo "== P1 pgBackRest: its configuration (read_tools on and off)"
printf '[global]\nrepo1-path=/var/lib/pgbackrest\nrepo1-retention-full=2\nrepo1-cipher-pass=%s\n[demo]\npg1-path=/var/lib/postgresql/data\n' "$LIT1" > "$PGBACKREST_CONFIG"
setcmd 'pgbackrest --stanza=demo archive-push %p'
row P1; collect backup_dest pgvd-b || fail "P1: pgvd-b's read"
G=$(dests pgvd-a 'pgbackrest configuration'); D=$(detail pgvd-a 'pgbackrest configuration')
[ "$G" = "base|pgbackrest|posix|||/var/lib/pgbackrest|false ;; wal|pgbackrest|posix|||/var/lib/pgbackrest|false" ] && [[ "$D" == *"retention 2 full (backups)"* ]] && [[ "$D" == *"not encrypted"* ]] || fail "P1 on: $G | $D | every row: $(q "select string_agg(concat_ws('|', source, role, coalesce(tool,''), coalesce(dest_kind,''), coalesce(path,''), coalesce(detail,'')), ' ;; ') from pgvigil.pg_backup_dest where instance_id=$(iid pgvd-a)") | reads: $(q "select string_agg(tool || ' ' || name || ' ' || state || ' ' || coalesce(message, ''), ' ;; ') from pgvigil.pg_backup_dest_reads where instance_id=$(iid pgvd-a)") | archive_command now: $(su "$C17" "SHOW archive_command") | the collector: $(tail -c 600 "$OUT" | tr '\n' ' ')"
[ "$(q "select state from pgvigil.pg_backup_dest_reads where instance_id=$(iid pgvd-a)")" = ok ] || fail "P1: pgvd-a's read state"
[ "$(q "select state from pgvigil.pg_backup_dest_reads where instance_id=$(iid pgvd-b)")" = off ] && [ "$(finding pgvd-b 'backup tool read off')" = 1 ] || fail "P1 off: $(q "select state from pgvigil.pg_backup_dest_reads where instance_id=$(iid pgvd-b)")"
collect backup_tools pgvd-b || fail "P1: backup_tools on pgvd-b"
[ "$(q "select state from pgvigil.pg_backup_tools where instance_id=$(iid pgvd-b) and tool='pgbackrest'")" = not_read ] && [ "$(finding pgvd-b 'base backups not read')" = 1 ] || fail "P1: 162's gate: $(q "select state || ' ' || coalesce(message, '') from pgvigil.pg_backup_tools where instance_id=$(iid pgvd-b)")"
ok "P1: on - $G ($D); off - the read 'off', 'backup tool read off'; backup_tools 'not_read' and 'base backups not read'"
notproven "P1 off: that no tool ran and no file was read rests on the gate's own 'off' word here (TestBackupDestToolReads counts the runs: 0)"

echo "== P2 pgBackRest: an s3 repository in the configuration"
printf '[global]\nrepo1-type=s3\nrepo1-s3-bucket=pgvdb\nrepo1-s3-endpoint=s3.lab.internal\nrepo1-path=/pg\nrepo1-s3-key=%s\nrepo1-s3-key-secret=%s\n' "$LIT2" "$LIT3" > "$PGBACKREST_CONFIG"
row P2; G=$(dests pgvd-a 'pgbackrest configuration')
[[ "$G" == *"wal|pgbackrest|s3|s3.lab.internal|pgvdb|/pg|false"* ]] || fail "P2: $G"; ok "P2: $G"

echo "== P3 barman: show-servers through a stand-in"
printf '#!/bin/sh\ncat <<JSON\n{"pg": {"conninfo": "host=pg1 user=barman password=%s", "ssh_command": "ssh postgres@pg1", "barman_home": "/var/lib/barman", "backup_directory": "/var/lib/barman/pg", "basebackups_directory": "/var/lib/barman/pg/base", "wals_directory": "/var/lib/barman/pg/wals", "backup_method": "rsync", "archiver": true, "retention_policy": "REDUNDANCY 2"}}\nJSON\n' "$LIT4" > "$SHIM/barman"; chmod +x "$SHIM/barman"
setcmd 'barman-wal-archive backup1 pg %p'
row P3; G=$(dests pgvd-a barman); D=$(detail pgvd-a barman)
[ "$G" = "base|barman|posix|||/var/lib/barman/pg/base|false ;; wal|barman|posix|||/var/lib/barman/pg/wals|false" ] && [[ "$D" == *"backup method rsync"* ]] && [[ "$D" == *"retention REDUNDANCY 2"* ]] || fail "P3: $G | $D"
ok "P3: $G"; notproven "P3: a real barman's show-servers (a stand-in printed the documented keys)"

echo "== P4 - P7, P9: the command's shapes"
shape() { setcmd "$2"; row "$1"; G=$(q "select coalesce(string_agg(concat_ws('|', role, coalesce(tool, ''), coalesce(dest_kind, ''), coalesce(host, ''), coalesce(container, ''), coalesce(path, ''), secret_seen::text), ' ;; ' order by seq), '') from pgvigil.pg_backup_dest where instance_id=$(iid pgvd-a) and source='archive_command' and role='wal'"); [ "$G" = "$3" ] || fail "$1: '$2' -> $G (want $3)"; ok "$1: $G"; }
shape P4 "PGPASSWORD=$LIT5 rsync -a %p backup@host1:/wal/%f" "wal|rsync|host|host1||/wal|true"
[ "$(finding pgvd-a "a credential is written in the archiver's command")" = 1 ] || fail "P4: the finding"; ok "P4: the finding 'a credential is written in the archiver's command'"
shape P5 "azcopy copy %p 'https://acct.blob.core.windows.net/wal/%f?sv=2020&sig=$LIT5'" "wal|azcopy|azure|acct.blob.core.windows.net||/wal|true"
shape P5b "curl -T %p https://user:$LIT7@files.lab/wal/%f" "wal|curl|https|files.lab||/wal|true"
shape P6 "test ! -f /mnt/server/archivedir/%f && cp %p /mnt/server/archivedir/%f" "wal|copy|posix|||/mnt/server/archivedir|false"
shape P6b "gzip < %p > /mnt/server/archivedir/%f.gz" "wal|copy|posix|||/mnt/server/archivedir|false"
su "$C17" "ALTER SYSTEM SET restore_command = 'cp /mnt/server/archivedir/%f %p'" >/dev/null; su "$C17" "SELECT pg_reload_conf()" >/dev/null; sleep 1
row P6c; D=$(detail pgvd-a restore_command)
[[ "$D" == *"set, not in use: this server is a primary"* ]] || fail "P6c: the restore row: $D"; ok "P6c: restore_command on a primary: $D"
shape P7 "WALG_S3_PREFIX=s3://pgvdb/wal wal-g wal-push %p" "wal|wal-g|s3||pgvdb|/wal|false"
shape P7b "envdir /etc/wal-e.d/env wal-e wal-push %p" "wal|wal-e|||||false"
[[ "$(detail pgvd-a archive_command)" == "the destination is in the envdir /etc/wal-e.d/env on the server - not known"* ]] || fail "P7b: $(detail pgvd-a archive_command)"
shape P7c "/usr/local/bin/archive.sh %p %f" "wal|script|||||false"
[[ "$(detail pgvd-a archive_command)" == "a script (archive.sh)"* ]] || fail "P7c: $(detail pgvd-a archive_command)"
shape P9 "barman-cloud-wal-archive --sse-customer-key $LIT6 s3://pgvbk/pg main %p" "wal|barman-cloud|s3||pgvbk|/pg|true"
shape P6d "/bin/true" "wal|none|discard||||false"
[ "$(finding pgvd-a 'WAL is discarded')" = 1 ] || fail "P6d: the finding"; ok "P6d: 'WAL is discarded' (warning)"
echo "== P12c PostgreSQL 17: archive_command and archive_library both set"
su "$C17" "ALTER SYSTEM SET archive_library = 'basic_archive'" >/dev/null; su "$C17" "ALTER SYSTEM SET basic_archive.archive_directory = '/var/lib/postgresql/arch'" >/dev/null
su "$C17" "SELECT pg_reload_conf()" >/dev/null; sleep 1
row P12c; G=$(dests pgvd-a archive_library); D=$(detail pgvd-a archive_library)
[ "$G" = "wal|none|||||false" ] && [[ "$D" == "WAL is not archived: both archive_command and archive_library are set"* ]] || fail "P12c: $G | $D"; ok "P12c: $G ($D)"
su "$C17" "ALTER SYSTEM SET archive_command = ''" >/dev/null
su "$C17" "SELECT pg_reload_conf()" >/dev/null; sleep 1
row P6e; G=$(dests pgvd-a archive_library)
[ "$G" = "wal|basic_archive|posix|||/var/lib/postgresql/arch|false" ] || fail "P6e: basic_archive: $G"; ok "P6e: $G"

echo "== P8 archive_mode off, the entry"
row P8 pgvd-off
W=$(q "select coalesce(read_text, '') from pgvigil.pg_backup_destinations where instance_id=$(iid pgvd-off) and role='wal'")
B=$(q "select coalesce(not_known, '') from pgvigil.pg_backup_destinations where instance_id=$(iid pgvd-off) and role='base'")
[[ "$W" == *"WAL is not archived (archive_mode off)"* ]] && [ "$B" = "not known" ] || fail "P8: $W | $B"
q "select pgvigil.import_backup_dest_entry($(iid pgvd-off), 'base', 'backup1:/srv/pg (a pg_basebackup from cron)', '$PLANTED', 'proof')" >/dev/null
q "select pgvigil.import_backup_dest_entry($(iid pgvd-off), 'base', 'backup1:/srv/pg2', null, 'proof')" >/dev/null
E=$(q "select entered_text || '|' || entered_by from pgvigil.pg_backup_destinations where instance_id=$(iid pgvd-off) and role='base'")
H=$(q "select count(*) || '/' || count(*) filter (where ended_at is null) from pgvigil.pg_backup_dest_entered where instance_id=$(iid pgvd-off)")
[ "$E" = "backup1:/srv/pg2|proof" ] && [ "$H" = "2/1" ] || fail "P8: the entry $E, history $H"
if q "select pgvigil.import_backup_dest_entry($(iid pgvd-off), 'wal', 'https://u:$LIT7@h/x', null, 'proof')" >/dev/null 2>&1; then fail "P8: a credential entry was taken"; fi
ok "P8: $W; base 'not known'; the entry $E, history $H; a credential refused"
[[ "$(rowtext pgvd-off)" == *"$PLANTED"* ]] || fail "S: the per-row search's positive control (the entry's note in the API answer) was not found: it proves nothing"
ok "S (per row): the per-row search finds the planted note in pgvd-off's answer"
notproven "P8: the API's POST seat and 'a reader login cannot write' (admin once the roles join)"

echo "== P12 PostgreSQL 13"
row P12 pgvd-13; G=$(dests pgvd-13 archive_command)
[ "$G" = "wal|none|discard||||false" ] || fail "P12: $G"; ok "P12: PostgreSQL 13 read (no archive_library): $G"
echo "== P12b PostgreSQL 15: both set, the library wins"
su "$C15" "ALTER SYSTEM SET archive_command = \$q\$cp %p /x/%f\$q\$" >/dev/null; su "$C15" "ALTER SYSTEM SET archive_library = 'basic_archive'" >/dev/null
su "$C15" "SELECT pg_reload_conf()" >/dev/null; sleep 1
row P12b pgvd-15; G=$(dests pgvd-15 archive_library)
[ "$G" = "wal|basic_archive|posix|||/var/lib/postgresql/arch|false" ] || fail "P12b: $G"; ok "P12b: PostgreSQL 15, both set: $G"

echo "== S the secrets (the end search)"
for n in pgvd-a pgvd-b pgvd-13 pgvd-off pgvd-15; do curl -s "$U/api/pg/backup_dest?instance=$(iid $n)" >> "$WORK/api.json"; done
curl -s "$U/api/pg/backup_dest/fleet" >> "$WORK/api.json"
pg_dump "$RDSN" --data-only --no-owner > "$WORK/dump.sql"
for lit in "$LIT1" "$LIT2" "$LIT3" "$LIT4" "$LIT5" "$LIT6" "$LIT7"; do
  for f in dump.sql collect.log serve.log api.json; do
    grep -qF "$lit" "$WORK/$f" && fail "S: a secret literal is in $f"
  done
done
grep -qF "$PLANTED" "$WORK/dump.sql" || fail "S: the positive control was not found: the search proves nothing"
grep -q '"base_to"' "$WORK/api.json" || fail "S: the fleet answer has no base_to"
ok "S: none of the seven literals in the dump, the collector's output, the serve log or the API; the planted control found"

echo "== I the pages in a headless Chromium"
if command -v chromium >/dev/null && command -v node >/dev/null && [ -z "${PROOF_SKIP_PAGE:-}" ]; then
  (cd "$WORK" && npm install --silent --no-audit --no-fund --no-package-lock axe-core@4.14.0 >/dev/null 2>&1) || fail "I: npm install axe-core failed"
  CDP=$((PORT + 1)); chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
  CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  cat > "$WORK/page.mjs" <<'JS'
const [port, U, axePath, inst] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => (await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise })).result?.result?.value;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, s = 30) => { for (let i = 0; i < s * 4; i++) { if (await ev(expr)) return true; await sleep(250); } return false; };
const out = {};
for (const theme of ['light', 'dark']) {
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(500);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const [name, hash, ready] of [['tab', `#/pgbackups?i=${inst}`, `!!document.querySelector('#pg-backup-dest table.grid')`],
                                     ['fleet', '#/backups', `[...document.querySelectorAll('th')].some(h => h.textContent.trim().startsWith('base backups to'))`]]) {
    await cmd('Page.navigate', { url: U + hash }); await sleep(300);
    const drawn = await until(ready);
    const r = { drawn, errors: await ev(`document.querySelectorAll('main .error').length`), text: await ev(`document.querySelector('#pg-backup-dest')?.textContent ?? ''`) };
    await cmd('Runtime.evaluate', { expression: axeSrc });
    r.violations = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: v.nodes.slice(0, 3).map(x => x.target.join(' ')) }))))`, true) ?? '[]');
    out[`${name}-${theme}`] = r;
  }
}
console.log(JSON.stringify(out));
process.exit(0);
JS
  node "$WORK/page.mjs" "$CDP" "$U/" "$WORK/node_modules/axe-core/axe.min.js" "$(iid pgvd-a)" > "$WORK/page.json" 2> "$WORK/page.err" || fail "I: the page check did not run: $(tail -c 400 "$WORK/page.err")"
  kill "$CHR" 2>/dev/null || true; CHR=
  python3 - "$WORK/page.json" <<'PYI' || fail "I: the pages"
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for k, r in d.items():
    if not r["drawn"] or r["errors"]: bad.append(f"{k}: drawn {r['drawn']}, error boxes {r['errors']}")
    n = sum(v["n"] for v in r["violations"])
    if n: bad.append(f"{k}: {n} axe violation node(s): {r['violations']}")
if "WAL to" not in d["tab-light"]["text"] or "base backups to" not in d["tab-light"]["text"]: bad.append("the tab lacks its two lines")
if bad: print("\n".join(bad)); sys.exit(1)
print("ok   I: the Base backups tab's 'Where the backups go' and the fleet Backups page, light and dark: drawn, no error box, 0 axe violation nodes")
PYI
else notproven "I: the pages - no chromium or node here (or PROOF_SKIP_PAGE)"; fi
notproven "P10: RDS / Aurora live (TestBackupDestOnAStore holds the line); a real barman and barman-cloud; Azure, GCS, SFTP repositories"
echo "ALL ROWS GREEN"
