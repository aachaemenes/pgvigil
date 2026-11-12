#!/usr/bin/env bash
# Proof of who blocks whom now (task 177, darling-open D02): Kill on every SQL Server Running queries session and on
# each chain's head through the actions door, refused without the actions login; implicit transactions shown and
# raised; each head statement's share of the blocked wait (migration 0114); and the PostgreSQL twin (Cancel and
# Terminate on the Running queries rows and the chain head, idle-in-transaction heads included).
# Needs: docker (pulls mcr.microsoft.com/mssql/server:2022-latest), go, psql, curl, python3, node, npm, chromium, and a
# PostgreSQL superuser in ADMIN_DSN (keyword form; default host=127.0.0.1 port=5432 user=postgres dbname=postgres).
# Everything it makes (the container, two databases, three PostgreSQL roles, the Chromium) is removed on every exit
# path; it kills only sessions it started.
#
# Expected (written before the first run):
#  A. a SQL Server 2022 container, a database pgvblk with a table of 10 rows, logins: a monitor (VIEW SERVER STATE),
#     an actions login (ALTER ANY CONNECTION and nothing else), an application login for the sessions below:
#     H1 (host pgvb_h1) SET IMPLICIT_TRANSACTIONS ON, updates row 1 and sleeps with the transaction open; V1 (pgvb_v1)
#     updates row 1 and V2 (pgvb_v2) reads it, both blocked behind H1; I1 (pgvb_i1) SET IMPLICIT_TRANSACTIONS ON,
#     updates row 3 and sleeps, blocking no one; 45 s later H2 (pgvb_h2) BEGIN TRAN, updates row 2 and sleeps, and V3
#     (pgvb_v3) updates row 2, blocked behind H2. A hand read: sys.dm_tran_active_transactions names H1's and I1's
#     transactions implicit_transaction and H2's user_transaction; V1 and V2 lead to H1, V3 to H2.
#  B. two reads of `pgvigil collect -once mssql_requests` 2 s apart, seconds after the sessions (the binary and the repository
#     are made before A's sessions start) [the order changed after s177b-proof1: the build ran between them];
#     B1 the newest snapshot: H1 a head (depth 0) of 2 with is_implicit_tran true, H2 a head of 1 with it false, I1
#        implicit and no head, V1 / V2 under H1 and V3 under H2, as the hand read says;
#     B2 mssql_head_share over the range: 2 head statements; H1's: 2 blocked requests, its blocked wait = V1's + V2's
#        wait in the NEWEST snapshot (each blocked request once, at its longest wait: not the sum over both
#        snapshots), lead (10 % or more), implicit, 2 snapshots; H2's: 1 blocked request, V3's newest wait, not lead
#        (V3 waited a few seconds against about 90 s), not implicit; the shares are 100 x its wait / the range's; the hand read of
#        V1's and V2's wait after the second read is at least the stored one and less than 10 s more;
#     B3 mssql_blocking_findings: 'an implicit transaction blocking' on session H1 and none on H2; 'sessions in
#        implicit transactions' naming session I1; 'a lead blocker' on H1's statement (the hour's blocked wait over a
#        minute) and none on H2's.
#  C. the PostgreSQL twin: in a scratch database a non-superuser role's session updates a row in an open transaction
#     and goes idle (the head), a second session's update of that row waits on it; `collect -once activity`; the hand
#     read: the head 'idle in transaction', the waiter's pg_blocking_pids = the head.
#  D. `pgvigil serve` of this tree (the web bundle rebuilt) with four instances: sqlbox (actions_dsn, actions: [kill]),
#     sqlbox-ro (the same server, no actions_dsn), pgbox (actions_dsn: a role in pg_signal_backend), pgbox-ro (none):
#     D1 GET /api/mssql/running: H1's row with is_implicit_tran true and no headshare part; with part=headshare the
#        function's rows [the part moved apart after review s177b-1];
#     D2 refused without the actions login, each 409 and one audit row with outcome refused: a kill of H1 on sqlbox-ro,
#        a terminate of the PostgreSQL head on pgbox-ro; both sessions still there.
#  E. headless Chromium, signed in:
#     E1 sqlbox's Running queries in light and dark: every session row has a Kill button, on (not aria-disabled) for
#        a session id over 50; the chain tree's two head rows (H1, H2) have 'kill this head' on and no other tree row
#        has one; H1's rows carry the 'implicit' badge, H2's do not; the status line says 'implicit transactions open
#        2, 1 heading a chain'; 'Lead blockers over the range' has 2 rows, H1's share marked lead, H2's not; no error
#        box; pgbox's Running queries: the head's tree row (idle in transaction) and every client session row have
#        Cancel and Terminate on; shots of both pages in both themes, and on sqlbox two more per theme with the part
#        below or right of the first view scrolled in: 'Lead blockers over the range' at the top (blocking-mssql-share-*)
#        and the sessions grid's first Kill button in the middle (blocking-mssql-kill-*) [after s177b-proof4];
#     E2 sqlbox-ro: every Kill button aria-disabled with a title naming actions_dsn, and a click opens no dialog;
#        pgbox-ro: every Terminate button disabled with a title naming actions_dsn;
#     E3 sqlbox at= the first snapshot: no Kill button anywhere and the line 'Kill acts on the newest snapshot only';
#     E4 every '#' link on sqlbox's page lands with no error box;
#     E5 through the buttons: 'kill this head' on H2 in the tree, then Kill on V1's row of the sessions grid, then
#        Terminate on the PostgreSQL head's tree row: each dialog shows the session read by the server, takes the
#        reason and the typed id, and says done. After them: H2 and V1 are gone from sys.dm_exec_sessions and V3 no
#        longer waits; the PostgreSQL head is gone from pg_stat_activity and the waiter no longer waits; the audit holds
#        kill|done|H2|KILL H2, kill|done|V1|KILL V1 (each with its reason and the UI user) and terminate|done|<head pid>.
#        The outcome is read from the dialog's line that starts done / not done / refused / failed (the PostgreSQL
#        dialog's line has no status role) [after s177b-proof3];
#        Each dialog names the login the server read for the session (the application's) [after review s177b-1];
#     E6 'kill this head' on H2 again (the page still shows the snapshot from before the kill): the dialog says not
#        possible and offers no form (the session is gone) [after review s177b-1];
#     E7 the same page with the browser's clock 10 minutes on: no Kill button and the line 'Kill waits for a newer
#        snapshot' (the newest snapshot is past 5 minutes old, DBA Dash's KillRecencyWindow) [after review s177b-1].
# NOT PROVEN HERE: the Kill guard's refusal of a session id given to a new session (read in the code: the preview's
#   login time against the row's; an id is not reused on demand); Kill's absence on a head that is not the holder or
#   whose row is not in the read (read in the code, killable()); B2's 'longest wait' against the newest (the waits only
#   grow between the two reads); a kill on Azure SQL or a Managed Instance; a MARS session's implicit flag over several requests;
#   'a lead blocker' over a full hour of real traffic (the proof's hour holds two snapshots); the findings on the
#   Findings tab (their arm is the lead's join line, written in 0114's header).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/go/bin:/usr/local/go/bin:$PATH"
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG_SQL=mcr.microsoft.com/mssql/server:2022-latest
SUF=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
SQL=pgvb-sql-$SUF; HOSTN=pgvb$SUF; LBL=pgvigil-proof=s177b
PGDB=pgv_blk_$SUF; SCR=pgv_blk_scr_$SUF; MON=pgv_bmon_$SUF; ACT=pgv_bact_$SUF; APP=pgv_bapp_$SUF; USR=proofdba$SUF
PGACT=pgv_bpgact_$SUF; PGAPP=pgv_bpgapp_$SUF
fail() { echo "FAIL: $*" >&2; exit 1; }
pw() { printf 'Pv9%sa!' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }
umask 077
TMPD=$(mktemp -d); SRVPID=; CHRPID=; BG=(); MADE_ROLES=
SHOTS=${PGVIGIL_SHOTS:-$TMPD/shots}; mkdir -p "$SHOTS"
SA_PW=$(pw); MON_PW=$(pw); ACT_PW=$(pw); APP_PW=$(pw); UPW=$(pw); PGACT_PW=$(pw); PGAPP_PW=$(pw)
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSA_PW=%s\n' "$SA_PW" "$SA_PW" > "$TMPD/sa.env"
printf 'APP_PW=%s\n' "$APP_PW" > "$TMPD/app.env"
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  if [[ -n "$CHRPID" ]]; then kill -- "-$CHRPID" 2>/dev/null || kill "$CHRPID" 2>/dev/null || true; wait "$CHRPID" 2>/dev/null || true; fi
  for p in "${BG[@]}"; do kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null || true; done
  docker rm -f -v "$SQL" >/dev/null 2>&1 || { docker inspect "$SQL" >/dev/null 2>&1 && echo "CLEANUP: container $SQL not removed" >&2; }
  for d in "$PGDB" "$SCR"; do
    psql "$ADMIN_DSN" -Xqc "DROP DATABASE IF EXISTS $d WITH (FORCE)" >/dev/null 2>&1 || echo "CLEANUP: database $d not dropped" >&2
  done
  if [[ -n "$MADE_ROLES" ]]; then
    for r in "$PGACT" "$PGAPP"; do psql "$ADMIN_DSN" -Xqc "DROP ROLE IF EXISTS $r" >/dev/null 2>&1 || echo "CLEANUP: role $r not dropped" >&2; done
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT
# sq: T-SQL as sa (stdin, never a command line); sqok: output not wanted, a failure loud
sq() { printf 'SET NOCOUNT ON;\n%s\n' "$1" | docker exec -i --env-file "$TMPD/sa.env" "$SQL" bash -c 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s "|" -d "$0" -i /dev/stdin' "${2:-master}"; }
sqok() { local out; out=$(sq "$2" "${3:-master}" 2>&1) || fail "$1: $out"; }
pq() { psql "$PGDSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
# urlq: the value through the environment, never an argument (a password is one)
urlq() { URLQ_V="$1" python3 -c 'import os,urllib.parse as u; print(u.quote(os.environ["URLQ_V"], safe=""))'; }
for t in docker go psql curl python3 node npm chromium setsid; do command -v "$t" >/dev/null || fail "needs $t"; done
psql "$ADMIN_DSN" -XAtqc "select 1" >/dev/null || fail "ADMIN_DSN does not answer"

# hold <host> <batch>: the application login runs the batch, then stays connected (sqlcmd waits on its stdin), in a
# process group of its own (setsid) that the cleanup ends whole
cat > "$TMPD/hold.sh" <<'HOLD'
{ printf '%s\nGO\n' "$5"; sleep 900; } | docker exec -i --env-file "$2" "$1" bash -c 'SQLCMDPASSWORD=$APP_PW exec /opt/mssql-tools18/bin/sqlcmd -S localhost -U "$0" -C -d pgvblk -H "$1"' "$3" "$4" >/dev/null 2>&1
HOLD
hold() { setsid bash "$TMPD/hold.sh" "$SQL" "$TMPD/app.env" "$APP" "$1" "$2" & BG+=($!); }
sid() { sq "SELECT MIN(session_id) FROM sys.dm_exec_sessions WHERE host_name = '$1'"; }
waitlock() { local s="" n=0; for _ in $(seq 1 40); do s=$(sid "$1"); [[ "$s" =~ ^[0-9]+$ ]] && n=$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id = $s AND wait_type LIKE 'LCK_M_%'") && [[ "$n" -ge 1 ]] && { echo "$s"; return 0; }; sleep 0.5; done; return 1; }
waitopen() { local s=""; for _ in $(seq 1 40); do s=$(sid "$1"); [[ "$s" =~ ^[0-9]+$ ]] && [[ "$(sq "SELECT COUNT(*) FROM sys.dm_tran_session_transactions WHERE session_id = $s")" -ge 1 ]] && { echo "$s"; return 0; }; sleep 0.5; done; return 1; }

echo "== A. two chains on a SQL Server 2022 container =="
docker run -d --name "$SQL" --hostname "$HOSTN" --label "$LBL" --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG_SQL" >/dev/null
ready=
for _ in $(seq 1 90); do ready=$(sq "SELECT CASE WHEN DATABASEPROPERTYEX('msdb', 'Status') = 'ONLINE' THEN 1 ELSE 0 END" 2>/dev/null || true); [[ "$ready" == 1 ]] && break; sleep 2; done
[[ "$ready" == 1 ]] || fail "A: the SQL Server container did not come up in 180 s"
PORT_SQL=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://')
sqok "A: the database" "CREATE DATABASE pgvblk;"
sqok "A: the table" "CREATE TABLE dbo.pgvblk_t (id int NOT NULL CONSTRAINT pk_pgvblk_t PRIMARY KEY, v int NOT NULL DEFAULT 0);
  INSERT dbo.pgvblk_t (id) SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects;" pgvblk
sqok "A: the logins" "CREATE LOGIN [$MON] WITH PASSWORD = '$MON_PW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO [$MON];
  CREATE LOGIN [$ACT] WITH PASSWORD = '$ACT_PW', CHECK_POLICY = OFF; GRANT ALTER ANY CONNECTION TO [$ACT];
  CREATE LOGIN [$APP] WITH PASSWORD = '$APP_PW', CHECK_POLICY = OFF;"
sqok "A: the users" "CREATE USER [$MON] FOR LOGIN [$MON]; GRANT VIEW DEFINITION TO [$MON];
  CREATE USER [$APP] FOR LOGIN [$APP]; ALTER ROLE db_datareader ADD MEMBER [$APP]; ALTER ROLE db_datawriter ADD MEMBER [$APP];" pgvblk
# the binary, the repository and its config before the sessions start: the collects then follow the sessions by seconds

go build -o "$TMPD/pgvigil" ./cmd/pgvigil
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $PGDB" >/dev/null
psql "$ADMIN_DSN" -Xqc "CREATE DATABASE $SCR" >/dev/null
PGDSN="$ADMIN_DSN"; PGDSN="${PGDSN/dbname=postgres/dbname=$PGDB}"; [[ "$PGDSN" == *"dbname=$PGDB"* ]] || PGDSN="$PGDSN dbname=$PGDB"
SCRDSN="$ADMIN_DSN"; SCRDSN="${SCRDSN/dbname=postgres/dbname=$SCR}"; [[ "$SCRDSN" == *"dbname=$SCR"* ]] || SCRDSN="$SCRDSN dbname=$SCR"
# the PostgreSQL roles: the actions role (pg_signal_backend alone) and the application's (no superuser)
MADE_ROLES=1   # before the CREATEs: a half-made pair is dropped too (DROP ROLE IF EXISTS)
psql "$ADMIN_DSN" -XqAt -v ON_ERROR_STOP=1 >/dev/null <<EOF || fail "C: the roles"
CREATE ROLE $PGACT LOGIN NOSUPERUSER PASSWORD '$PGACT_PW' IN ROLE pg_signal_backend;
CREATE ROLE $PGAPP LOGIN NOSUPERUSER PASSWORD '$PGAPP_PW';
EOF
HOSTPART=$(sed -E 's/ *(user|dbname|password)=[^ ]*//g' <<<"$ADMIN_DSN")
export PGV_B_MON="sqlserver://$MON:$(urlq "$MON_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
export PGV_B_ACT="sqlserver://$ACT:$(urlq "$ACT_PW")@127.0.0.1:$PORT_SQL?database=master&encrypt=true&TrustServerCertificate=true"
export PGV_B_PG="$SCRDSN"
export PGV_B_PGACT="$HOSTPART user=$PGACT password=$PGACT_PW dbname=$SCR"
APPDSN="$HOSTPART user=$PGAPP dbname=$SCR"
cat > "$TMPD/b.yaml" <<EOF
repository:
  dsn: "$PGDSN"
instances:
  - name: sqlbox
    engine: sqlserver
    dsn: env:PGV_B_MON
    actions_dsn: env:PGV_B_ACT
    actions: [kill]
  - name: sqlbox-ro
    engine: sqlserver
    dsn: env:PGV_B_MON
  - name: pgbox
    dsn: env:PGV_B_PG
    actions_dsn: env:PGV_B_PGACT
  - name: pgbox-ro
    dsn: env:PGV_B_PG
EOF
"$TMPD/pgvigil" migrate -config "$TMPD/b.yaml" >"$TMPD/migrate.out" 2>&1 || { cat "$TMPD/migrate.out" >&2; fail "B: migrate"; }
coll() { "$TMPD/pgvigil" collect -config "$TMPD/b.yaml" -instance "$1" -once "$2" >"$TMPD/c.out" 2>&1 || { cat "$TMPD/c.out" >&2; fail "B: collect $1 $2"; }; }

hold pgvb_h1 "SET IMPLICIT_TRANSACTIONS ON; UPDATE dbo.pgvblk_t SET v = 1 WHERE id = 1;"
H1=$(waitopen pgvb_h1) || fail "A: H1 did not open its transaction"
hold pgvb_i1 "SET IMPLICIT_TRANSACTIONS ON; UPDATE dbo.pgvblk_t SET v = 1 WHERE id = 3;"
I1=$(waitopen pgvb_i1) || fail "A: I1 did not open its transaction"
hold pgvb_v1 "UPDATE dbo.pgvblk_t SET v = 2 WHERE id = 1;"
V1=$(waitlock pgvb_v1) || fail "A: V1 does not wait on a lock"
hold pgvb_v2 "SELECT v FROM dbo.pgvblk_t WHERE id = 1;"
V2=$(waitlock pgvb_v2) || fail "A: V2 does not wait on a lock"
sleep 45
hold pgvb_h2 "BEGIN TRAN; UPDATE dbo.pgvblk_t SET v = 1 WHERE id = 2;"
H2=$(waitopen pgvb_h2) || fail "A: H2 did not open its transaction"
hold pgvb_v3 "UPDATE dbo.pgvblk_t SET v = 3 WHERE id = 2;"
V3=$(waitlock pgvb_v3) || fail "A: V3 does not wait on a lock"
sleep 2
tn() { sq "SELECT MAX(tat.name) FROM sys.dm_tran_session_transactions st JOIN sys.dm_tran_active_transactions tat ON tat.transaction_id = st.transaction_id WHERE st.session_id = $1"; }
TH1=$(tn "$H1"); TI1=$(tn "$I1"); TH2=$(tn "$H2")
[[ "$TH1" == implicit_transaction && "$TI1" == implicit_transaction && "$TH2" == user_transaction ]] \
  || fail "A: the transaction names: H1 '$TH1', I1 '$TI1', H2 '$TH2' (want implicit_transaction, implicit_transaction, user_transaction)"
# the hand read of who waits behind whom, followed to the head
head_of() { local s=$1 b; for _ in 1 2 3 4 5; do b=$(sq "SELECT ISNULL(MAX(blocking_session_id), 0) FROM sys.dm_exec_requests WHERE session_id = $s"); [[ "$b" == 0 ]] && { echo "$s"; return; }; s=$b; done; echo "?"; }
[[ "$(head_of "$V1")" == "$H1" && "$(head_of "$V2")" == "$H1" && "$(head_of "$V3")" == "$H2" ]] \
  || fail "A: the hand read's heads: V1 -> $(head_of "$V1"), V2 -> $(head_of "$V2"), V3 -> $(head_of "$V3") (want $H1, $H1, $H2)"
echo "ok   A: H1 $H1 (implicit_transaction) heads V1 $V1 and V2 $V2; I1 $I1 (implicit_transaction) blocks no one; H2 $H2 (user_transaction) heads V3 $V3"

echo "== B. the store, the head shares and the findings =="
coll sqlbox mssql_requests; sleep 2; coll sqlbox mssql_requests
HW1=$(sq "SELECT wait_time FROM sys.dm_exec_requests WHERE session_id = $V1"); HW2=$(sq "SELECT wait_time FROM sys.dm_exec_requests WHERE session_id = $V2")
coll sqlbox-ro mssql_requests
SB=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox'"); SBRO=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'sqlbox-ro'")
[[ "$(pq "SELECT count(*) FROM pgvigil.mssql_requests_summary WHERE instance_id = $SB")" == 2 ]] || fail "B: the store holds not 2 snapshots of sqlbox"
FIRST=$(pq "SELECT min(snapshot_at) FROM pgvigil.mssql_requests_summary WHERE instance_id = $SB"); LAST=$(pq "SELECT max(snapshot_at) FROM pgvigil.mssql_requests_summary WHERE instance_id = $SB")
row() { pq "SELECT coalesce(chain_depth::text, '-') || '|' || coalesce(victims::text, '-') || '|' || coalesce(is_implicit_tran::text, '-') || '|' || coalesce(head_session_id::text, '-')
              FROM pgvigil.mssql_requests WHERE instance_id = $SB AND snapshot_at = '$LAST' AND session_id = $1 ORDER BY request_id NULLS FIRST LIMIT 1"; }
RH1=$(row "$H1"); RH2=$(row "$H2"); RI1=$(row "$I1"); RV1=$(row "$V1"); RV2=$(row "$V2"); RV3=$(row "$V3")
[[ "$RH1" == "0|2|true|$H1" ]] || fail "B1: H1's stored row '$RH1' (want 0|2|true|$H1)"
[[ "$RH2" == "0|1|false|$H2" ]] || fail "B1: H2's stored row '$RH2' (want 0|1|false|$H2)"
[[ "$(cut -d'|' -f3 <<<"$RI1")" == true && "$(cut -d'|' -f4 <<<"$RI1")" == "-" ]] || fail "B1: I1's stored row '$RI1' (want implicit and no head)"
[[ "$(cut -d'|' -f4 <<<"$RV1")" == "$H1" && "$(cut -d'|' -f4 <<<"$RV2")" == "$H1" && "$(cut -d'|' -f4 <<<"$RV3")" == "$H2" ]] || fail "B1: the victims' heads: V1 '$RV1', V2 '$RV2', V3 '$RV3'"
echo "ok   B1: the newest snapshot: H1 heads 2 with an implicit transaction, H2 heads 1 with a user one, I1 implicit and no head; V1, V2 under H1, V3 under H2"
SH=$(pq "SELECT head_key || '|' || victims || '|' || blocked_wait_ms || '|' || range_blocked_wait_ms || '|' || share_pct || '|' || lead || '|' || implicit || '|' || snapshots || '|' || coalesce(head_text_id::text, '')
           FROM pgvigil.mssql_head_share($SB, now() - interval '1 hour', now() + interval '1 minute')")
[[ "$(wc -l <<<"$SH")" == 2 ]] || fail "B2: mssql_head_share has not 2 rows: $SH"
lastwait() { pq "SELECT coalesce(sum(wait_ms), 0) FROM pgvigil.mssql_requests WHERE instance_id = $SB AND snapshot_at = '$LAST' AND session_id IN ($1) AND chain_depth > 0"; }
W1=$(lastwait "$V1, $V2"); W3=$(lastwait "$V3")
WBOTH=$(pq "SELECT coalesce(sum(wait_ms), 0) FROM pgvigil.mssql_requests WHERE instance_id = $SB AND session_id IN ($V1, $V2) AND chain_depth > 0")
TOT=$((W1 + W3))
S1=$(python3 -c "print(round(100.0 * $W1 / $TOT, 1))"); S3=$(python3 -c "print(round(100.0 * $W3 / $TOT, 1))")
L1=$(sed -n 1p <<<"$SH"); L2=$(sed -n 2p <<<"$SH")
IFS='|' read -r _ v1 bw1 rt1 sp1 ld1 im1 sn1 TX1 <<<"$L1"
IFS='|' read -r _ v3 bw3 rt3 sp3 ld3 im3 sn3 TX3 <<<"$L2"
[[ "$v1|$bw1|$rt1|$ld1|$im1|$sn1" == "2|$W1|$TOT|true|true|2" ]] || fail "B2: H1's share row '$L1' (want 2 requests, wait $W1, of $TOT, lead, implicit, 2 snapshots)"
[[ "$v3|$bw3|$rt3|$ld3|$im3|$sn3" == "1|$W3|$TOT|false|false|2" ]] || fail "B2: H2's share row '$L2' (want 1 request, wait $W3, of $TOT, not lead, not implicit, 2 snapshots)"
python3 -c "import sys; sys.exit(0 if abs(float('$sp1') - $S1) < 0.051 and abs(float('$sp3') - $S3) < 0.051 else 1)" || fail "B2: the shares $sp1 / $sp3 (want $S1 / $S3)"
[[ "$WBOTH" -gt "$W1" ]] || fail "B2: the sum over both snapshots ($WBOTH) is not larger than the newest ($W1): the dedupe is not shown"
WS1=$(pq "SELECT wait_ms FROM pgvigil.mssql_requests WHERE instance_id = $SB AND snapshot_at = '$LAST' AND session_id = $V1 AND chain_depth > 0 LIMIT 1")
WS2=$(pq "SELECT wait_ms FROM pgvigil.mssql_requests WHERE instance_id = $SB AND snapshot_at = '$LAST' AND session_id = $V2 AND chain_depth > 0 LIMIT 1")
(( HW1 >= WS1 && HW1 - WS1 < 10000 && HW2 >= WS2 && HW2 - WS2 < 10000 )) || fail "B2: the hand read's waits V1 $HW1 / V2 $HW2 against the stored $WS1 / $WS2"
echo "ok   B2: head shares: H1's statement 2 requests, $W1 ms of $TOT ($sp1 %, lead, implicit; the sum over both snapshots would be $WBOTH); H2's 1 request, $W3 ms ($sp3 %, not lead)"
F=$(pq "SELECT check_name || '|' || object FROM pgvigil.mssql_blocking_findings WHERE instance_id = $SB ORDER BY 1")
grep -qx "an implicit transaction blocking|session $H1" <<<"$F" || fail "B3: no implicit-transaction blocking finding on H1: $F"
! grep -q "|session $H2\$" <<<"$F" || fail "B3: a finding on H2: $F"
grep -qx "a lead blocker|statement $TX1" <<<"$F" || fail "B3: no lead-blocker finding on H1's statement $TX1: $F"
! grep -qx "a lead blocker|statement $TX3" <<<"$F" || fail "B3: a lead-blocker finding on H2's statement: $F"
pq "SELECT detail FROM pgvigil.mssql_blocking_findings WHERE instance_id = $SB AND check_name = 'sessions in implicit transactions'" | grep -q "session $I1 " \
  || fail "B3: the implicit-transactions finding does not name I1: $(pq "SELECT detail FROM pgvigil.mssql_blocking_findings WHERE instance_id = $SB AND check_name = 'sessions in implicit transactions'")"
echo "ok   B3: findings: implicit transaction blocking on $H1, sessions in implicit transactions naming $I1, a lead blocker on statement $TX1; none on H2"

echo "== C. the PostgreSQL twin =="
psql "$SCRDSN" -Xq -v ON_ERROR_STOP=1 -c "CREATE TABLE pgvb_t (id int PRIMARY KEY, v int); INSERT INTO pgvb_t SELECT g, 0 FROM generate_series(1, 5) g; GRANT SELECT, UPDATE ON pgvb_t TO $PGAPP;" >/dev/null
cat > "$TMPD/pghold.sh" <<'HOLD'
{ printf '%s\n' "$3"; sleep 900; } | PGPASSWORD="$PGAPP_PW" PGAPPNAME="$2" psql "$1" -Xq >/dev/null 2>&1
HOLD
export PGAPP_PW
setsid bash "$TMPD/pghold.sh" "$APPDSN" pgvb_head "BEGIN; UPDATE pgvb_t SET v = 1 WHERE id = 1;" & BG+=($!)
for _ in $(seq 1 30); do HP=$(psql "$SCRDSN" -XAtqc "SELECT pid FROM pg_stat_activity WHERE application_name = 'pgvb_head' AND state = 'idle in transaction'"); [[ "$HP" =~ ^[0-9]+$ ]] && break; sleep 0.5; done
[[ "${HP:-}" =~ ^[0-9]+$ ]] || fail "C: the head is not idle in transaction"
setsid bash "$TMPD/pghold.sh" "$APPDSN" pgvb_waiter "UPDATE pgvb_t SET v = 2 WHERE id = 1;" & BG+=($!)
for _ in $(seq 1 30); do WP=$(psql "$SCRDSN" -XAtqc "SELECT pid FROM pg_stat_activity WHERE application_name = 'pgvb_waiter' AND wait_event_type = 'Lock'"); [[ "$WP" =~ ^[0-9]+$ ]] && break; sleep 0.5; done
[[ "${WP:-}" =~ ^[0-9]+$ ]] || fail "C: the waiter does not wait on a lock"
[[ "$(psql "$SCRDSN" -XAtqc "SELECT array_to_string(pg_blocking_pids($WP), ',')")" == "$HP" ]] || fail "C: the waiter's blockers are not the head $HP"
coll pgbox activity; coll pgbox-ro activity
PGI=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'pgbox'"); PGRO=$(pq "SELECT instance_id FROM pgvigil.instances WHERE name = 'pgbox-ro'")
echo "ok   C: the head $HP idle in transaction, the waiter $WP blocked by it, as pg_stat_activity and pg_blocking_pids read"

echo "== D. the API under pgvigil serve =="
GSRC=$TMPD/src; mkdir -p "$GSRC"
tar -C . --exclude=./web/node_modules --exclude=./.lab --exclude=./.git -cf - . | tar -C "$GSRC" -xf -
(cd "$GSRC/web" && npm ci --no-audit --no-fund >"$TMPD/web.log" 2>&1 && npm run build >>"$TMPD/web.log" 2>&1) || { tail -20 "$TMPD/web.log" >&2; fail "D: the web build"; }
(cd "$GSRC" && go build -o "$TMPD/pgvigil-g" ./cmd/pgvigil) || fail "D: the build"
PGVIGIL_PASSWORD="$UPW" "$TMPD/pgvigil-g" user add -config "$TMPD/b.yaml" "$USR" >/dev/null 2>&1 || fail "D: user add"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'); U="http://127.0.0.1:$PORT"
"$TMPD/pgvigil-g" serve -config "$TMPD/b.yaml" -listen "127.0.0.1:$PORT" >"$TMPD/serve.log" 2>&1 & SRVPID=$!
for _ in $(seq 1 100); do curl -s -o /dev/null "$U/api/session" 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || { cat "$TMPD/serve.log" >&2; fail "D: serve exited"; }
printf '{"username":"%s","password":"%s"}' "$USR" "$UPW" > "$TMPD/login.json"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -c "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data @"$TMPD/login.json" "$U/api/login")" == 200 ]] || fail "D: the UI login"
curl -s -b "$TMPD/cj" "$U/api/mssql/running?instance=$SB" > "$TMPD/run.json"
curl -s -b "$TMPD/cj" "$U/api/mssql/running?instance=$SB&part=headshare" > "$TMPD/hs.json"
api=$(python3 - "$TMPD/run.json" "$H1" "$TMPD/hs.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
rows = lambda t: [dict(zip(t["columns"], r)) for r in (t or {}).get("rows") or []]
h1 = [r for r in rows(d.get("rows")) if str(r["session_id"]) == sys.argv[2]]
h = json.load(open(sys.argv[3]))
hs = rows(h.get("headshare"))
print(h1[0]["is_implicit_tran"] if h1 else "none", len(hs), "|".join(f"{r['victims']}:{r['blocked_wait_ms']}:{r['lead']}" for r in hs), "headshare" in d)
EOF
)
read -r aimp ahs arows adef <<<"$api"
[[ "$aimp" == True && "$ahs" == 2 && "$arows" == "2:$W1:True|1:$W3:False" && "$adef" == False ]] \
  || fail "D1: the API: H1 implicit $aimp, $ahs head share rows '$arows', headshare in the snapshot's read $adef (want True, 2, 2:$W1:True|1:$W3:False, False)"
echo "ok   D1: GET /api/mssql/running: H1 implicit; part=headshare equal to mssql_head_share, and not in the snapshot's own read"
LT1=$(sq "SELECT CONVERT(varchar(33), DATEADD(minute, -DATEDIFF(minute, GETUTCDATE(), GETDATE()), login_time), 127) + 'Z' FROM sys.dm_exec_sessions WHERE session_id = $H1")
post() { curl -s -o "$TMPD/body" -w '%{http_code}' -b "$TMPD/cj" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data "$2" "$U/api/$1"; }
c1=$(post mssql/actions/run "{\"instance_id\": $SBRO, \"action\": \"kill\", \"session_id\": $H1, \"login_time\": \"$LT1\", \"login\": \"$APP\", \"confirm\": \"$H1\", \"reason\": \"the proof asks without the actions login\"}")
[[ "$c1" == 409 ]] || fail "D2: the kill on sqlbox-ro answered $c1: $(cat "$TMPD/body")"
BS=$(psql "$SCRDSN" -XAtqc "SELECT to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') FROM pg_stat_activity WHERE pid = $HP")
c2=$(post actions/terminate "{\"instance_id\": $PGRO, \"pid\": $HP, \"backend_start\": \"$BS\", \"confirm\": \"$HP\", \"reason\": \"the proof asks without the actions login\"}")
[[ "$c2" == 409 ]] || fail "D2: the terminate on pgbox-ro answered $c2: $(cat "$TMPD/body")"
[[ "$(pq "SELECT count(*) FROM pgvigil.actions_log WHERE instance_name = 'sqlbox-ro' AND action = 'kill' AND outcome = 'refused' AND pid = $H1")" == 1 ]] || fail "D2: no refused kill row for sqlbox-ro"
[[ "$(pq "SELECT count(*) FROM pgvigil.actions_log WHERE instance_name = 'pgbox-ro' AND action = 'terminate' AND outcome = 'refused' AND pid = $HP")" == 1 ]] || fail "D2: no refused terminate row for pgbox-ro"
[[ "$(sid pgvb_h1)" == "$H1" ]] && psql "$SCRDSN" -XAtqc "SELECT 1 FROM pg_stat_activity WHERE pid = $HP" | grep -q 1 || fail "D2: a refused target is gone"
echo "ok   D2: without the actions login: the kill (sqlbox-ro) and the terminate (pgbox-ro) answered 409, each audited as refused, both sessions still there"

echo "== E. the pages in headless Chromium =="
CDP=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
setsid chromium --headless=new --remote-debugging-port="$CDP" --user-data-dir="$TMPD/chrome" --no-first-run --disable-gpu --window-size=1600,1000 about:blank >"$TMPD/chrome.log" 2>&1 & CHRPID=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "E: chromium's CDP port never answered"
FIRST_ISO=$(pq "SELECT to_char(min(snapshot_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') FROM pgvigil.mssql_requests_summary WHERE instance_id = $SB")
cat > "$TMPD/e.mjs" <<'JS'
// prints one line per check; the shell grades them
const [port, U, sb, sbro, pgi, pgro, shots, h2, v1, hp, firstIso, appLogin, pgLogin] = process.argv.slice(2);
const fs = await import('node:fs');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => { for (let i = 0; i < 150; i++) { const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^(Loading|Opening)/.test(e.textContent)) && m.children.length > 0 && !!m.querySelector('h2'); })()`); if (ok) { await sleep(300); return true; } await sleep(100); } return false; };
const go = async (hash) => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const shot = async (name) => { const d = await cmd('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(`${shots}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
// the grid after the h3 whose text matches, as rows of { id (the first cell, tree marks stripped), text, buttons }
const page = () => ev(`(() => { const m = document.querySelector('main');
  const gridAfter = re => { const h = [...m.querySelectorAll('h3')].find(x => re.test(x.textContent)); let g = h?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE') g = g.nextElementSibling; return g; };
  const rows = g => g ? [...g.querySelectorAll('tbody tr')].filter(tr => !tr.querySelector('.empty')).map(tr => ({
    id: (tr.querySelector('td')?.textContent ?? '').replace(/[└\\s]/g, ''), text: tr.textContent,
    buttons: [...tr.querySelectorAll('button[class^=act-]')].map(b => ({ cls: b.className, on: !b.disabled && b.getAttribute('aria-disabled') !== 'true', title: b.title })) })) : [];
  return JSON.stringify({ hash: location.hash, tree: rows(gridAfter(/^Blocking chains/)), sessions: rows(gridAfter(/^(Sessions and requests|Sessions)/)),
    share: rows(gridAfter(/^Lead blockers over the range/)), status: m.querySelector('.running-status')?.textContent ?? '',
    notes: [...m.querySelectorAll('p.meta')].map(p => p.textContent), errors: m.querySelectorAll('.error:not([role=status])').length,
    links: [...new Set([...m.querySelectorAll('a[href^="#"]')].map(a => a.getAttribute('href')))] }); })()`).then(JSON.parse);
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Page.navigate', { url: U + '#/about' }); await sleep(800);
const st = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(process.env.E_USR)}, password: ${JSON.stringify(process.env.E_UPW)} }) }).then(r => r.status)`, true);
console.log(`login ${st}`);
const kills = rs => rs.map(r => ({ id: r.id, k: r.buttons.filter(b => b.cls === 'act-kill').map(b => b.on) }));
for (const theme of ['light', 'dark']) {
  await go('#/about');
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  if (!await go(`#/mssql_running?i=${sb}`)) { console.log(`FAIL render mssql ${theme}`); continue; }
  const s = await page();
  console.log(`mssql ${theme} ${JSON.stringify({ tree: kills(s.tree), implicit: s.tree.filter(r => /implicit/.test(r.text)).map(r => r.id),
    sessions: kills(s.sessions), share: s.share.map(r => /lead/.test(r.text)), status: s.status, errors: s.errors })}`);
  await shot(`blocking-mssql-${theme}`);
  const shareIn = await ev(`(() => { const h = [...document.querySelectorAll('main h3')].find(x => /^Lead blockers over the range/.test(x.textContent)); if (!h) return false; h.scrollIntoView({ block: 'start' }); return h.getBoundingClientRect().top < innerHeight; })()`);
  await sleep(300); await shot(`blocking-mssql-share-${theme}`);
  const killIn = await ev(`(() => { const h = [...document.querySelectorAll('main h3')].find(x => /^(Sessions and requests|Sessions)/.test(x.textContent)); let g = h?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE') g = g.nextElementSibling; const b = g?.querySelector('button.act-kill'); if (!b) return false; b.scrollIntoView({ block: 'center', inline: 'center' }); const r = b.getBoundingClientRect(); return r.left >= 0 && r.right <= innerWidth && r.top >= 0 && r.bottom <= innerHeight; })()`);
  await sleep(300); await shot(`blocking-mssql-kill-${theme}`);
  console.log(`mssql-shots ${theme} share=${shareIn} kill=${killIn}`);
  await ev(`(() => { window.scrollTo(0, 0); return 1; })()`);
  if (!await go(`#/activity?i=${pgi}`)) { console.log(`FAIL render pg ${theme}`); continue; }
  const p = await page();
  const term = rs => rs.map(r => ({ id: r.id, t: r.buttons.filter(b => b.cls === 'act-terminate').map(b => b.on), c: r.buttons.filter(b => b.cls === 'act-cancel').map(b => b.on), idle: /idle in transaction/.test(r.text) }));
  console.log(`pg ${theme} ${JSON.stringify({ tree: term(p.tree), sessions: term(p.sessions), errors: p.errors })}`);
  await shot(`blocking-pg-${theme}`);
}
// E2: without the actions login
await go(`#/mssql_running?i=${sbro}`);
let s = await page();
const roBtns = [...s.tree, ...s.sessions].flatMap(r => r.buttons.filter(b => b.cls === 'act-kill'));
await ev(`(() => { const b = document.querySelector('main button.act-kill'); if (b) b.click(); return 1; })()`); await sleep(500);
const dlg = await ev(`!!document.querySelector('dialog[open]')`);
console.log(`ro mssql buttons=${roBtns.length} off=${roBtns.every(b => !b.on)} titled=${roBtns.every(b => /actions_dsn/.test(b.title))} dialog=${dlg}`);
await go(`#/activity?i=${pgro}`);
s = await page();
const roPg = [...s.tree, ...s.sessions].flatMap(r => r.buttons.filter(b => b.cls === 'act-terminate'));
console.log(`ro pg buttons=${roPg.length} off=${roPg.every(b => !b.on)} titled=${roPg.every(b => /actions_dsn/.test(b.title))}`);
// E3: an earlier snapshot
await go(`#/mssql_running?i=${sb}&at=${encodeURIComponent(firstIso)}`);
s = await page();
const anyKill = [...s.tree, ...s.sessions].some(r => r.buttons.some(b => b.cls === 'act-kill'));
console.log(`earlier kill=${anyKill} note=${s.notes.some(n => /Kill acts on the newest snapshot only/.test(n))} errors=${s.errors}`);
// E4: every '#' link of the page
await go(`#/mssql_running?i=${sb}`);
s = await page();
for (const h of s.links) { const ok = await go(h); const t = ok ? await page() : { errors: -1 }; console.log(`link ${h} rendered=${ok} errors=${t.errors}`); }
// E5: through the buttons; gridRe picks the grid, cls the button, idv the row's first cell
const act = async (hash, gridRe, cls, idv, label, who) => {
  await go(hash);
  const clicked = await ev(`(() => { const m = document.querySelector('main'); const h = [...m.querySelectorAll('h3')].find(x => ${gridRe}.test(x.textContent));
    let g = h?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE') g = g.nextElementSibling; if (!g) return 'no grid';
    const tr = [...g.querySelectorAll('tbody tr')].find(t => (t.querySelector('td')?.textContent ?? '').replace(/[└\\s]/g, '') === '${idv}'); if (!tr) return 'no row';
    const b = tr.querySelector('button.${cls}'); if (!b) return 'no button'; if (b.disabled || b.getAttribute('aria-disabled') === 'true') return 'off: ' + b.title; b.click(); return 'clicked'; })()`);
  if (clicked !== 'clicked') { console.log(`act ${label} ${clicked}`); return; }
  let ready = false;
  for (let i = 0; i < 100 && !ready; i++) { await sleep(100); ready = await ev(`!!document.querySelector('dialog[open] textarea')`); }
  if (!ready) { console.log(`act ${label} no-form ${await ev(`document.querySelector('dialog[open]')?.textContent ?? 'no dialog'`)}`); return; }
  const shown = await ev(`document.querySelector('dialog[open]').textContent.includes(${JSON.stringify(who)})`);
  const sent = await ev(`(() => { const d = document.querySelector('dialog[open]'); const t = d.querySelector('textarea'); t.value = 'the proof clicks ${label}'; t.dispatchEvent(new Event('input'));
    const i = d.querySelector('input[type=text]'); i.value = '${idv}'; i.dispatchEvent(new Event('input')); const b = d.querySelector('button[type=submit]'); if (b.disabled) return 'submit off'; b.click(); return 'sent'; })()`);
  let out = '';
  for (let i = 0; i < 150 && sent === 'sent'; i++) { await sleep(100); out = await ev(`(() => { const d = document.querySelector('dialog[open]'); return d ? ([...d.querySelectorAll('p')].map(x => x.textContent).find(t => /^(done|not done|refused|failed)/.test(t)) ?? '') : ''; })()`); if (/^(done|not done|refused|failed)/.test(out)) break; }
  console.log(`act ${label} shown=${shown} ${sent} outcome=${JSON.stringify(out.slice(0, 160))}`);
  await ev(`(() => { const d = document.querySelector('dialog[open]'); if (d) d.close(); return 1; })()`); await sleep(800);
};
await act(`#/mssql_running?i=${sb}`, '/^Blocking chains/', 'act-kill', h2, 'head-h2', appLogin);
await act(`#/mssql_running?i=${sb}`, '/^Sessions and requests/', 'act-kill', v1, 'row-v1', appLogin);
await act(`#/activity?i=${pgi}`, '/^Blocking chains/', 'act-terminate', hp, 'pg-head', pgLogin);
// E6: H2 again, from the same snapshot: the session is gone
await go(`#/mssql_running?i=${sb}`);
const again = await ev(`(() => { const m = document.querySelector('main'); const h = [...m.querySelectorAll('h3')].find(x => /^Blocking chains/.test(x.textContent));
  let g = h?.nextElementSibling; while (g && !g.querySelector('table') && g.tagName !== 'TABLE') g = g.nextElementSibling;
  const tr = g && [...g.querySelectorAll('tbody tr')].find(t => (t.querySelector('td')?.textContent ?? '').replace(/[└\\s]/g, '') === '${h2}');
  const b = tr?.querySelector('button.act-kill'); if (!b) return 'no button'; b.click(); return 'clicked'; })()`);
let gone = '';
for (let i = 0; i < 100 && again === 'clicked'; i++) { await sleep(100); gone = await ev(`(() => { const d = document.querySelector('dialog[open]'); return d && !/Reading the session/.test(d.textContent) ? (d.querySelector('textarea') ? 'form ' : 'noform ') + d.textContent : ''; })()`); if (gone) break; }
console.log(`gone ${again} ${JSON.stringify(gone.slice(0, 200))}`);
await ev(`(() => { const d = document.querySelector('dialog[open]'); if (d) d.close(); return 1; })()`); await sleep(500);
// E7: the browser's clock 10 minutes on: the newest snapshot is past the 5 minutes Kill waits for
await cmd('Page.addScriptToEvaluateOnNewDocument', { source: 'const __pgvNow = Date.now; Date.now = () => __pgvNow() + 600000;' });
await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
await go(`#/mssql_running?i=${sb}`);
s = await page();
console.log(`stale kill=${[...s.tree, ...s.sessions].some(r => r.buttons.some(b => b.cls === 'act-kill'))} note=${s.notes.some(n => /^Kill waits for a newer snapshot/.test(n))} errors=${s.errors}`);
ws.close();
JS
out=$(E_USR="$USR" E_UPW="$UPW" node "$TMPD/e.mjs" "$CDP" "$U" "$SB" "$SBRO" "$PGI" "$PGRO" "$SHOTS" "$H2" "$V1" "$HP" "$FIRST_ISO" "$APP" "$PGAPP" 2>&1) || { echo "$out" >&2; fail "E: the browser script"; }
echo "$out"
grep -q '^login 200$' <<<"$out" || fail "E: the UI login in the browser"
for theme in light dark; do
  line=$(grep "^mssql $theme " <<<"$out" | sed "s/^mssql $theme //") || fail "E1: no SQL Server page ($theme)"
  python3 - "$line" "$H1" "$H2" <<'EOF' || fail "E1: the SQL Server page ($theme): $line"
import json, sys
d = json.loads(sys.argv[1]); h1, h2 = sys.argv[2], sys.argv[3]
tree_k = {r["id"]: r["k"] for r in d["tree"]}
heads_on = tree_k.get(h1) == [True] and tree_k.get(h2) == [True]
others_none = all(k == [] for i, k in tree_k.items() if i not in (h1, h2))
rows_ok = len(d["sessions"]) > 0 and all(r["k"] == [int(r["id"]) > 50] for r in d["sessions"] if r["id"].isdigit())
implicit_ok = h1 in d["implicit"] and h2 not in d["implicit"]
status_ok = "implicit transactions open 2, 1 heading a chain" in d["status"]
share_ok = d["share"] == [True, False]
sys.exit(0 if heads_on and others_none and rows_ok and implicit_ok and status_ok and share_ok and d["errors"] == 0 else 1)
EOF
  grep -q "^mssql-shots $theme share=true kill=true$" <<<"$out" || fail "E1: the scrolled SQL Server shots ($theme): $(grep "^mssql-shots $theme" <<<"$out")"
  for f in blocking-mssql-share-$theme blocking-mssql-kill-$theme; do [[ -s "$SHOTS/$f.png" ]] || fail "E1: no shot $f.png"; done
  line=$(grep "^pg $theme " <<<"$out" | sed "s/^pg $theme //") || fail "E1: no PostgreSQL page ($theme)"
  python3 - "$line" "$HP" "$WP" <<'EOF' || fail "E1: the PostgreSQL page ($theme): $line"
import json, sys
d = json.loads(sys.argv[1]); hp, wp = sys.argv[2], sys.argv[3]
head = [r for r in d["tree"] if r["id"] == hp]
head_ok = len(head) == 1 and head[0]["t"] == [True] and head[0]["c"] == [True] and head[0]["idle"]
rows = {r["id"]: r for r in d["sessions"]}
rows_ok = all(i in rows and rows[i]["t"] == [True] for i in (hp, wp))
sys.exit(0 if head_ok and rows_ok and d["errors"] == 0 else 1)
EOF
done
echo "ok   E1: sqlbox: Kill on every session row (on above session 50), 'kill this head' on H1 and H2 only, H1 implicit, the status line, H1 lead in the share table; pgbox: Cancel and Terminate on the idle-in-transaction head and the rows; both themes shot, sqlbox's share table and Kill column scrolled in"
grep -Eq '^ro mssql buttons=[1-9][0-9]* off=true titled=true dialog=false$' <<<"$out" || fail "E2: sqlbox-ro: $(grep '^ro mssql' <<<"$out")"
grep -Eq '^ro pg buttons=[1-9][0-9]* off=true titled=true$' <<<"$out" || fail "E2: pgbox-ro: $(grep '^ro pg' <<<"$out")"
echo "ok   E2: without the actions login every Kill and Terminate button is off with the reason, and a click opens nothing"
grep -q '^earlier kill=false note=true errors=0$' <<<"$out" || fail "E3: the earlier snapshot: $(grep '^earlier' <<<"$out")"
echo "ok   E3: an earlier snapshot offers no Kill and says why"
! grep '^link ' <<<"$out" | grep -qv 'rendered=true errors=0$' || fail "E4: a link did not land: $(grep '^link ' <<<"$out" | grep -v 'rendered=true errors=0$')"
echo "ok   E4: $(grep -c '^link ' <<<"$out") link(s) on the page, each landed"
for l in head-h2 row-v1 pg-head; do grep -Eq "^act $l shown=true sent outcome=\"done" <<<"$out" || fail "E5: $l: $(grep "^act $l" <<<"$out")"; done
sleep 2
[[ -z "$(sq "SELECT session_id FROM sys.dm_exec_sessions WHERE session_id IN ($H2, $V1) AND host_name IN ('pgvb_h2', 'pgvb_v1')")" ]] || fail "E5: H2 or V1 is still connected"
[[ "$(sq "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id = $V3 AND wait_type LIKE 'LCK_M_%'")" == 0 ]] || fail "E5: V3 still waits"
[[ -z "$(psql "$SCRDSN" -XAtqc "SELECT pid FROM pg_stat_activity WHERE pid = $HP")" ]] || fail "E5: the PostgreSQL head $HP is still there"
[[ -z "$(psql "$SCRDSN" -XAtqc "SELECT pid FROM pg_stat_activity WHERE pid = $WP AND wait_event_type = 'Lock'")" ]] || fail "E5: the PostgreSQL waiter still waits"
AUD=$(pq "SELECT instance_name || '|' || action || '|' || outcome || '|' || pid || '|' || coalesce(statement, '') || '|' || reason || '|' || ui_user
            FROM pgvigil.actions_log WHERE outcome = 'done' ORDER BY at")
grep -qx "sqlbox|kill|done|$H2|KILL $H2|the proof clicks head-h2|$USR" <<<"$AUD" || fail "E5: no audit row for the kill of H2: $AUD"
grep -qx "sqlbox|kill|done|$V1|KILL $V1|the proof clicks row-v1|$USR" <<<"$AUD" || fail "E5: no audit row for the kill of V1: $AUD"
grep -q "^pgbox|terminate|done|$HP|.*|the proof clicks pg-head|$USR\$" <<<"$AUD" || fail "E5: no audit row for the terminate of $HP: $AUD"
echo "ok   E5: through the buttons: H2 killed from the tree, V1 from its row, the PostgreSQL head $HP terminated from the tree; each dialog named the login the server read; all gone, the waiters free, three audit rows done"
grep -Eq '^gone clicked "noform .*not possible' <<<"$out" || fail "E6: H2 again: $(grep '^gone' <<<"$out")"
echo "ok   E6: 'kill this head' on the killed H2 from the old snapshot: the dialog says not possible, no form"
grep -q '^stale kill=false note=true errors=0$' <<<"$out" || fail "E7: the stale snapshot: $(grep '^stale' <<<"$out")"
echo "ok   E7: with the newest snapshot past 5 minutes old no Kill is offered and the page says why"
echo "proof-darling-blocking: OK (Kill on the rows and the heads of both engines through the door, refused without it; implicit transactions shown and raised; the head shares and the lead blocker; shots in $SHOTS)"
