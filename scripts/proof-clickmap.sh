#!/usr/bin/env bash
# Proof of the Storage folder in DBA Dash's shape and of the click map (task 176), on the demo (12 PostgreSQL and 3 SQL
# Server instances, two days) in a scratch database, served on loopback, with a headless Chromium. Needs go, node,
# chromium, psql, curl, python3 and a superuser connection without dbname.
#   PGVIGIL_ADMIN_DSN     the superuser connection (creates and drops the scratch database)
#   PGVIGIL_DEMO_WAIT_S   how long the demo may take to seed and serve (default 300)
#   PGVIGIL_CLICK_OUT     a file that gets click-check.mjs's JSON (every link, its target, its verdict)
#   CLICK_ALL=1           click every link, not one per column, engine and scope (each link's href is checked either way)
# Expected (written before the first run):
#  T. the drive thresholds (0111), on the demo's repository as its owner:
#     T1 at the default, drives_now's status of every drive is the rule before 0111 (critical under 5 % free, warning
#        under 10 %); host_checks' disk rows are exactly the PostgreSQL drives the old rule raises (read in the last
#        hour), mssql_storage_findings' volume rows exactly the SQL Server volumes it raises (read in the last three
#        hours); each detail names 'warning under 10 %, critical under 5 % (the default)'.
#        [review fold, before the rerun: each engine's old rule exactly - PostgreSQL judged disk_report's rounded
#        free_pct, SQL Server the exact ratio; a fixture at the edges, a scratch instance of each engine with a drive at
#        9.96 % and one at 4.96 % free (SQL Server volumes X: and Y:): PostgreSQL ok and warning (10.0 and 5.0 rounded),
#        SQL Server warning and critical; removed at T8]
#     T2 a root threshold 50 / 40: every drive judged by it (threshold_level root), status recomputed by hand: 0 off.
#     T3 a tag threshold 30 / 20 on the tag most instances carry of those not on every instance: its instances' drives
#        at tag, the others at root.
#     T4 an instance threshold 60 / 55 on demo-onprem-erp01: its drives at instance.
#     T5 a drive threshold 1 / 0.5 on one of its drives: that drive at drive, the instance's others at instance.
#     T6 inherit on that drive: it falls back to 60 / 55 (instance); the ended row keeps ended_by and ended_at.
#     T7 refused, nothing written: critical over warning; a warning of 101; a drive level without a drive; an instance
#        level on instance 0; inherit where the level has no row of its own; op 'drop'.
#     T8 every live row ended (inherit) before the clicks: drives_now back at the default on every drive.
#  R. the reads (a -no-login serve of the demo): GET /api/drives: counts.drives = drives_now's rows; status=critical,
#     warning gives exactly the drives in those states; instance=<erp01> only its drives; instances=0 none; status=bogus
#     400. /api/drives/history for erp01's data volume: 2 points at least; its windows: minutes=525600 (a year) 2 points
#     at least, minutes=5 answers with one point at most and 'newest' = the drive's 5 newest reads (the newest one's
#     used bytes = host_disk_history's), days=90 still taken, minutes=7 and days=45 400. /api/dbspace: one row per active instance
#     with databases (15); a SQL Server row's used is the files' used summed where every file's was read and none
#     where one was not (the demo's database the login cannot enter) [fixed after s176-c2: it said 'each with used read'];
#     instance=<sql01>: databases 1+ and history 2+ points.
#     /api/dbfiles?instance=<sql01>: 1+ files, every status ok, warning or critical; root counts.files = the files of
#     mssql_files present plus the WAL and tablespace rows. /api/driveperf?instance=<sql01>: 1+ steps, every drive one
#     of sql01's volumes or 'drive not read'. POST /api/drives/thresholds: 403 without the header, 403 with the header
#     and no login.
#  C. click-check.mjs: 0 FAIL. From the Summary at the root, the tag folder, demo-onprem-erp01 and demo-onprem-sql01:
#     no link lands on Daily checks; the instance grid's Disk cells land on Drives on both engines, Storage on Drives
#     (PostgreSQL) and Files (SQL Server), Backups on Backups / mssqlbackups, Jobs on the Jobs folder, Corruption on
#     Corruption; the test grid's Disk and Storage open Drives, Backups Backups, Jobs Jobs; a test without a page of its
#     own keeps the address on the Summary; the tree's Storage node opens Drives at the root and the tag folder; every
#     tab of the Storage strip at the four scopes draws its page with no error box.
#     [after s176-c4, before the rerun: a SQL Server instance's Disk cell (the SQL Server summary's own 'disk' key: the
#     volume finding, DBA Dash's Drive Space) lands on Drives too; under an instance the tree's Storage node is checked
#     once the instance's node is opened (not shown, not a FAIL, when the node sits in a closed folder)]
# Expected, task 176b (written before its first run):
#  T1 at the default, now DBA Dash's 20 / 10 (0113): drives_now judges every drive by it (warning under 20 % free,
#     critical under 10 %); host_checks' disk rows and mssql_storage_findings' volume rows are exactly the drives that
#     rule raises; each detail names 'warning under 20 %, critical under 10 % (the default)'; the edge fixture at 19.96 %
#     and 9.96 % free: PostgreSQL /fx1996 ok and /fx996 warning (20.0 and 10.0 rounded), SQL Server X: warning and Y:
#     critical (the exact ratio). T2-T7 as before; T8 back at 20 / 10.
#  T9 the uptime threshold (one dialog, both engines): import_pg_threshold sets 'uptime' at a SQL Server instance
#     (sql01, warning 87600 h, critical 87599 h) and still refuses another key there ('crash'); GET /api/uptime names
#     sql01, its start time, the level 'instance' and those two values; the SQL Server summary's uptime cell is then
#     critical with a detail naming 'set on the instance'; inherit ends it and the detail says 'the default' again.
#  R adds: /api/dbfiles?drive=<sql01's E:\> gives only E:\ files, as many as mssql_files has there; ?drive=<erp01's
#     data volume> holds erp01's pg_wal (a row without a location lives in the data directory) [review fold, before
#     the run: the separate data-directory row is gone, it counted pg_default's bytes twice]; /api/collectiondates: one row per active instance and collection, each status critical, warning,
#     ok or disabled, critical exactly where the last run failed; ?instance=<sql01> its own rows only.
#  C adds: Collection opens Collection dates on both engines; Database state opens Database options (PostgreSQL
#     pgdboptions; SQL Server the Checks page with cv=databases); QS (SQL Server alone) opens mssqlqs, pg_stat_statements (PostgreSQL alone) pgstate; Uptime opens the dialog
#     over the Summary (the address unchanged, the dialog names the instance and 'In force: warning under .. hours,
#     critical under .. hours'), on both engines; no named difference is left for those four; each drive's Files link
#     under erp01 and sql01 opens 'Files on <drive>' listing only that drive's files; the PostgreSQL strip holds Temp.
# Expected, task P08 (written before its first run):
#  T10 DBA Dash's Summary columns, read by the SQL Server summary (GET /api/mssql/summary): with sql01's day-one checks
#     areas read now (checkdb, logspace, corruption, alerts, identity) and its rows - a database never CHECKDB'd and
#     one 9 days since, an agent alert 5 hours ago, a suspect page 3 days ago, an identity column 42.50 % used with
#     120 days left - and a second SQL Server instance (ms2) with only a database checked 9 days ago and the alerts area
#     read without an alert: sql01 checkdb critical 1, value Never, since 9 days back; ms2 checkdb value none, since
#     9 days back; sql01 alerts since 5 h back, ms2 alerts sampled with no since; sql01 corruption since 3 days back;
#     sql01 identity value '42.5% / 120 days'; logspace sampled on sql01. The demo's instance with three memory dumps
#     (the newest 72 h old): dumps warning at the default (48 / 168 h); a root crash threshold of 100 / 200 h
#     (import_pg_threshold, the Memory Dump Thresholds dialog's write) makes it critical. sql01's uptime set to warn
#     under 87600 h at the instance and acknowledged until it changes (import_ack, seen_state 'since <start in ms>',
#     what the Summary's Clear Alert / Acknowledge Uptime write).
#     [review fold 20261111-205600, before the rerun: mssql_checks and mssql_identity logged as run now (else every
#     area reads 'never'); the state checked; whole-hour seeds, the CHECKDB day at 9 UTC midnights; CLICK_EXPECT merged per
#     instance and every (instance, column) pair of it required in the click map; identity '42.5|120', shown '42.5% / 3 months']
#  C adds (click-check.mjs, CLICK_EXPECT): the instance grid's columns are DBA Dash's in its order, then pgvigil's;
#     every cell of a DBA Dash column lands where DBA Dash's Summary.cs tabMapping sends it (Last Good Check DB:
#     corruption / the Checks page's Database options; SQL Agent Alerts: the Checks page's Agent alerts; Backup FULL /
#     DIFF / LOG: backups / mssqlbackups; Log Shipping, Mirroring, Availability Groups: replication or pgbackups /
#     availability; Log Space and File Space: dbfiles; Identity Columns: the Identity columns view; Snapshot Age:
#     Collection dates; Collection Errors (24hrs): Collection dates, a difference argued: DBA Dash's ErrorLog page is
#     P13's); Memory Dump, Is Agent Running and DB Mail are text, no link; the cell texts T10 seeded read 'Never',
#     '9 days', '5hrs', 'Never', '3 days', '42.5% / 3 months', 'View', the dump instance's Memory Dump '3 days', sql01's
#     Instance Uptime 'ack: ...'; the test grid's headers are 'Test', 'Instance Count OK', 'Instance Count Warning',
#     'Instance Count Critical', 'Instance Count N/A', 'Instance Count Acknowledged', its tests sorted by name, each
#     name cell filled with its worst count, Instance Uptime acknowledged 1 or more; the toolbar holds Refresh, View,
#     Options, Clear Filter and 'Refresh Time: ' with its icon; Options opens Memory Dumps, Instance Uptime and Test
#     Summary Max Height % (10% ... 90%, 70% ticked; 40% sets the test pane to 40vh); Memory Dumps > Configure
#     Thresholds opens 'Memory Dump Thresholds' with Critical 100 and Warning 200 (the root row T10 set), its words in
#     DBA Dash's order (Warning, Critical, Acknowledge, Clear, Cancel, Update), the warning check box right of its
#     box and Acknowledge at the labels' left edge; Instance Uptime > Configure Thresholds 'Uptime Threshold Config (root)' with Inherit off and disabled and its
#     Warning box editable; an Uptime cell 'Uptime Threshold Config <instance>' with Inherit, Enabled, Warning / Critical
#     in mins, Uptime:, Start Time:, Clear Alert and Update, 'Warning:' over its box and Root Threshold Config more than
#     100 px right of Inherit (DBA Dash's layout).
#     Task 177 D29 (PerformanceMonitor's links and buttons, kind 'pm'): the Summary row's Silence button (off with why
#     on a server without the UI login, else its confirm 'Silence all alerts for '<name>'?'); on an instance of each
#     engine the header's name (its Summary), the breadcrumb's band dot (named OK / Warning / Critical / Offline), the
#     calendar's Previous / Next month (Next off on this month) and This month, Show as table and back, the newest day
#     with data ('Why this day is <its band>:') and each of its drills landing on that page over that UTC day (View Top
#     Queries always), and the Performance page's 'Zoomed: <from> → <to>' chip.
#     The zoom (w9fold): one drag and the chip's x; two drags, the chip's x and every chart's Reset zoom the range before
#     the first; a custom range, a drag, a chart's Reset zoom pressed (a real press) back to it with no chip.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_click_$RANDOM"; PORT=""; CDP=""; SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in chromium node psql curl python3 go ss; do command -v $t >/dev/null || fail "$t is not on this machine"; done
for _ in $(seq 1 20); do p=$((21000 + RANDOM % 9000)); if ! ss -ltnH "( sport = :$p or sport = :$((p + 1)) )" | grep -q .; then PORT=$p; break; fi; done
[[ -n "$PORT" ]] || fail "no free port pair"; CDP=$((PORT + 1))

echo "== build, seed the demo into $DB and serve it on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
DSN="$PGVIGIL_ADMIN_DSN dbname=$DB"
"$WORK/pgvigil" demo -dsn "$DSN" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
T0=$SECONDS
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-300}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { tail -5 "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-300} s"; }
echo "the demo served after $((SECONDS - T0)) s"
U="http://127.0.0.1:$PORT"
q() { psql "$DSN" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
ERP=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-erp01'"); SQL1=$(q "select instance_id from pgvigil.instances where name = 'demo-onprem-sql01'")
[[ -n "$ERP" && -n "$SQL1" ]] || fail "the demo's erp01 or sql01 is missing"
# the tag folder: the tag most instances carry of those not on every instance (a tag on all of them tests no 'other')
TAG=$(q "select t from pgvigil.instance_tags_merged m join pgvigil.instances i using (instance_id) cross join unnest(m.tags) t where i.is_active group by t having count(*) < (select count(*) from pgvigil.instances where is_active) order by count(*) desc, t limit 1")
[[ -n "$TAG" ]] || fail "the demo has no tag that some but not all instances carry"
put() { q "select pgvigil.import_drive_threshold(now(), '$1'::jsonb)->>'outcome'"; }
# off: drives whose status differs from a hand computation with the threshold each should carry ($1: an SQL CASE
# over d giving 'level|warn|crit'); each engine judged by its old rule (PostgreSQL the rounded per cent, SQL Server the
# exact ratio)
off() { q "select count(*) from (select d.*, $1 as want, case when d.engine = 'sqlserver' then 100.0 * d.free_bytes / nullif(d.total_bytes, 0)
                                  else round(100.0 * d.free_bytes / nullif(d.total_bytes, 0), 1) end as p from pgvigil.drives_now d) x
           where x.total_bytes > 0 and x.free_bytes is not null and (
             x.threshold_level || '|' || x.warn_pct || '|' || x.crit_pct <> split_part(x.want, '|', 1) || '|' || split_part(x.want, '|', 2)::numeric || '|' || split_part(x.want, '|', 3)::numeric
             or x.status <> case when x.p < split_part(x.want, '|', 3)::numeric then 'critical'
                                 when x.p < split_part(x.want, '|', 2)::numeric then 'warning' else 'ok' end)"; }

echo "== T the drive thresholds"
# the edges of the default (20 / 10, 0113): a scratch instance of each engine with a drive at 19.96 % and one at 9.96 % free, read now
q "insert into pgvigil.instances (name, platform, engine) values ('fx-drive-pg', 'onprem', 'postgres'), ('fx-drive-ms', 'onprem', 'sqlserver')" >/dev/null
FXP=$(q "select instance_id from pgvigil.instances where name = 'fx-drive-pg'"); FXM=$(q "select instance_id from pgvigil.instances where name = 'fx-drive-ms'")
q "insert into pgvigil.host_disks (instance_id, mount_point, snapshot_at, source, total_bytes, used_bytes, free_bytes, first_seen)
   values ($FXP, '/fx1996', now(), 'system_stats', 100000, 80040, 19960, now()), ($FXP, '/fx996', now(), 'system_stats', 100000, 90040, 9960, now());
   insert into pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, files, snapshot_at)
   values ($FXM, 'X:', 100000, 19960, 1, now()), ($FXM, 'Y:', 100000, 9960, 1, now())" >/dev/null
FX=$(q "select string_agg(engine || ' ' || drive || ' ' || status, ', ' order by engine, drive) from pgvigil.drives_now where instance_id in ($FXP, $FXM)")
[[ "$FX" == 'postgres /fx1996 ok, postgres /fx996 warning, sqlserver X: warning, sqlserver Y: critical' ]] || fail "T1: the edge fixture: $FX"
N=$(q "select count(*) from pgvigil.drives_now"); NPG=$(q "select count(*) from pgvigil.drives_now where engine = 'postgres'"); NMS=$(q "select count(*) from pgvigil.drives_now where engine = 'sqlserver'")
(( NPG > 0 && NMS > 0 )) || fail "T: the demo's drives: $NPG PostgreSQL, $NMS SQL Server"
[[ $(off "'default|20|10'") == 0 ]] || fail "T1: drives off DBA Dash's rule at the default: $(off "'default|20|10'")"
OLDPG=$(q "select coalesce(string_agg(instance_id || ':' || mount_point || ':' || case when free_pct < 10 then 'critical' else 'warning' end, ',' order by instance_id, mount_point), '') from pgvigil.disk_report where free_pct < 20 and snapshot_at > now() - interval '1 hour'")
NEWPG=$(q "select coalesce(string_agg(instance_id || ':' || object || ':' || severity, ',' order by instance_id, object), '') from pgvigil.host_checks where check_group = 'disk'")
[[ "$OLDPG" == "$NEWPG" ]] || fail "T1: host_checks' disk rows [$NEWPG], the old rule [$OLDPG]"
OLDMS=$(q "select coalesce(string_agg(instance_id || ':' || volume || ':' || case when 100.0 * free_bytes / total_bytes < 10 then 'critical' else 'warning' end, ',' order by instance_id, volume), '') from pgvigil.mssql_volumes where is_present and total_bytes > 0 and free_bytes is not null and 100.0 * free_bytes / total_bytes < 20 and snapshot_at > now() - interval '3 hours'")
NEWMS=$(q "select coalesce(string_agg(instance_id || ':' || object || ':' || severity, ',' order by instance_id, object), '') from pgvigil.mssql_storage_findings where check_name = 'a volume under 10 % free'")
[[ "$OLDMS" == "$NEWMS" ]] || fail "T1: mssql_storage_findings' volume rows [$NEWMS], the old rule [$OLDMS]"
[[ -n "$NEWPG$NEWMS" ]] || fail "T1: the demo raises no drive row on either engine (nothing compared)"
[[ $(q "select count(*) from (select detail from pgvigil.host_checks where check_group = 'disk' union all select detail from pgvigil.mssql_storage_findings where check_name = 'a volume under 10 % free') x where detail not like '%warning under 20 %, critical under 10 % (the default)%'") == 0 ]] || fail "T1: a detail without the threshold in force"
ok "T1: $N drives ($NPG PostgreSQL, $NMS SQL Server, the edge fixture's 4 among them: $FX) at the default judge by DBA Dash's 20 / 10; host_checks [$NEWPG], mssql_storage_findings [$NEWMS]"
[[ $(put '{"op":"set","level":"root","warn":"50","crit":"40","ui_user":"proof"}') == done ]] || fail "T2: root"
[[ $(off "'root|50|40'") == 0 ]] || fail "T2: drives off the root threshold: $(off "'root|50|40'")"
ok "T2: a root 50 / 40 judges every drive"
[[ $(put "{\"op\":\"set\",\"level\":\"tag\",\"tag\":\"$TAG\",\"warn\":\"30\",\"crit\":\"20\",\"ui_user\":\"proof\"}") == done ]] || fail "T3: tag"
TAGGED="case when '$TAG' = any (coalesce((select m.tags from pgvigil.instance_tags_merged m where m.instance_id = d.instance_id), '{}')) then 'tag|30|20' else 'root|50|40' end"
[[ $(off "$TAGGED") == 0 ]] || fail "T3: drives off the tag / root thresholds: $(off "$TAGGED")"
ok "T3: the tag $TAG at 30 / 20 judges its instances' drives, the root the others"
[[ $(put "{\"op\":\"set\",\"level\":\"instance\",\"instance_id\":\"$ERP\",\"warn\":\"60\",\"crit\":\"55\",\"ui_user\":\"proof\"}") == done ]] || fail "T4: instance"
INSTW="case when d.instance_id = $ERP then 'instance|60|55' else $TAGGED end"
[[ $(off "$INSTW") == 0 ]] || fail "T4: drives off: $(off "$INSTW")"
ok "T4: erp01 at 60 / 55"
DRV=$(q "select drive from pgvigil.drives_now where instance_id = $ERP order by drive limit 1")
[[ -n "$DRV" ]] || fail "T5: erp01 has no drive"
[[ $(put "{\"op\":\"set\",\"level\":\"drive\",\"instance_id\":\"$ERP\",\"drive\":\"$DRV\",\"warn\":\"1\",\"crit\":\"0.5\",\"ui_user\":\"proof\"}") == done ]] || fail "T5: drive"
DRVW="case when d.instance_id = $ERP and d.drive = '$DRV' then 'drive|1|0.5' else $INSTW end"
[[ $(off "$DRVW") == 0 ]] || fail "T5: drives off: $(off "$DRVW")"
ok "T5: erp01's $DRV at 1 / 0.5, its other drives at the instance's"
[[ $(put "{\"op\":\"inherit\",\"level\":\"drive\",\"instance_id\":\"$ERP\",\"drive\":\"$DRV\",\"ui_user\":\"proof\"}") == done ]] || fail "T6: inherit"
[[ $(off "$INSTW") == 0 ]] || fail "T6: drives off after inherit: $(off "$INSTW")"
[[ $(q "select count(*) from pgvigil.drive_thresholds where level = 'drive' and ended_at is not null and ended_by = 'proof'") == 1 ]] || fail "T6: the ended row"
ok "T6: inherit: $DRV back to the instance's 60 / 55, the ended row kept"
ROWS=$(q "select count(*) from pgvigil.drive_thresholds")
for bad in '{"op":"set","level":"root","warn":"10","crit":"20","ui_user":"proof"}' '{"op":"set","level":"root","warn":"101","crit":"5","ui_user":"proof"}' \
           "{\"op\":\"set\",\"level\":\"drive\",\"instance_id\":\"$ERP\",\"warn\":\"10\",\"crit\":\"5\",\"ui_user\":\"proof\"}" '{"op":"set","level":"instance","instance_id":"0","warn":"10","crit":"5","ui_user":"proof"}' \
           "{\"op\":\"inherit\",\"level\":\"drive\",\"instance_id\":\"$ERP\",\"drive\":\"$DRV\",\"ui_user\":\"proof\"}" '{"op":"drop","level":"root","ui_user":"proof"}'; do
  [[ $(put "$bad") == refused ]] || fail "T7: not refused: $bad"
done
[[ $(q "select count(*) from pgvigil.drive_thresholds") == "$ROWS" ]] || fail "T7: a refusal wrote a row"
ok "T7: six refusals, nothing written"
for p in "{\"op\":\"inherit\",\"level\":\"instance\",\"instance_id\":\"$ERP\",\"ui_user\":\"proof\"}" "{\"op\":\"inherit\",\"level\":\"tag\",\"tag\":\"$TAG\",\"ui_user\":\"proof\"}" '{"op":"inherit","level":"root","ui_user":"proof"}'; do
  [[ $(put "$p") == done ]] || fail "T8: $p"
done
[[ $(off "'default|20|10'") == 0 && $(q "select count(*) from pgvigil.drive_thresholds where ended_at is null") == 0 ]] || fail "T8: not back at the default"
q "delete from pgvigil.instances where instance_id in ($FXP, $FXM)" >/dev/null
ok "T8: every level inherited: the default again"
# T9: the uptime threshold of a SQL Server instance (0113), read back by /api/uptime and the SQL Server summary
pt() { q "select pgvigil.import_pg_threshold(now(), '$1'::jsonb)->>'outcome'"; }
upc() { curl -fs "$U/api/mssql/summary" | python3 -c "import json,sys; d=json.load(sys.stdin)['cells']; r=[dict(zip(d['columns'], x)) for x in d['rows']]; c=[x for x in r if str(x['instance_id']) == sys.argv[1] and x['key'] == 'uptime'][0]; print(str(c['critical']) + '|' + ' '.join(map(str, c['detail'] or [])))" "$SQL1"; }
[[ $(pt "{\"op\":\"set\",\"key\":\"uptime\",\"level\":\"instance\",\"instance_id\":\"$SQL1\",\"warn\":\"87600\",\"crit\":\"87599\",\"ui_user\":\"proof\"}") == done ]] || fail "T9: sql01's uptime threshold refused"
[[ $(pt "{\"op\":\"set\",\"key\":\"crash\",\"level\":\"instance\",\"instance_id\":\"$SQL1\",\"warn\":\"1\",\"crit\":\"1\",\"ui_user\":\"proof\"}") == refused ]] || fail "T9: another key at a SQL Server instance not refused"
UP=$(curl -fs "$U/api/uptime?instance=$SQL1" | python3 -c "import json,sys; d=json.load(sys.stdin)['uptime']; r=dict(zip(d['columns'], d['rows'][0])); print(r['instance'], r['level'], int(float(r['warn'])), int(float(r['crit'])), r['own_id'] is not None, r['started_at'] is not None)")
[[ "$UP" == "demo-onprem-sql01 instance 87600 87599 True True" ]] || fail "T9: /api/uptime: $UP"
C9=$(upc); [[ "$C9" == 1\|*"set on the instance"* ]] || fail "T9: the SQL Server summary's uptime cell with the threshold: $C9"
[[ $(pt "{\"op\":\"inherit\",\"key\":\"uptime\",\"level\":\"instance\",\"instance_id\":\"$SQL1\",\"ui_user\":\"proof\"}") == done ]] || fail "T9: inherit"
C9B=$(upc); [[ "$C9B" == *"the default"* ]] || fail "T9: after inherit: $C9B"
ok "T9: sql01's uptime at 87600 / 87599 h (another key refused there), /api/uptime [$UP], the summary cell [${C9%%|*} critical, set on the instance]; inherit: the default again"

# T10 (task P08): DBA Dash's Summary columns of the SQL Server summary, seeded on sql01 and a second SQL Server instance
MS2=$(q "select instance_id from pgvigil.instances where engine = 'sqlserver' and is_active and instance_id <> $SQL1 order by name limit 1")
DUMPI=$(q "select instance_id from pgvigil.mssql_health where dump_count > 0 order by instance_id limit 1")
[[ -n "$MS2" && -n "$DUMPI" ]] || fail "T10: the demo has no second SQL Server instance ($MS2) or none with a memory dump ($DUMPI)"
UTC="'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'"
q "insert into pgvigil.mssql_check_area (instance_id, area, is_read, snapshot_at, read_at)
   select i, a, true, now(), now() from unnest(array[$SQL1, $MS2]) i cross join unnest(array['checkdb','logspace','corruption','alerts','identity']) a
   on conflict (instance_id, area) do update set is_read = true, note = null, snapshot_at = now(), read_at = now()" >/dev/null
q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, state, options, snapshot_at) values
   ($SQL1, 'p08_never', 901, 'ONLINE', '{\"last_good_checkdb\": \"never\"}', now()),
   ($SQL1, 'p08_old', 902, 'ONLINE', jsonb_build_object('last_good_checkdb', to_char((date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '9 days' + interval '1 hour') at time zone 'UTC', $UTC)), now()),
   ($MS2, 'p08_old', 902, 'ONLINE', jsonb_build_object('last_good_checkdb', to_char((date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '9 days' + interval '1 hour') at time zone 'UTC', $UTC)), now())
   on conflict (instance_id, database_name) do update set options = excluded.options, is_present = true, snapshot_at = now()" >/dev/null
q "insert into pgvigil.mssql_check_finding (instance_id, area, check_name, object, rule, severity, value, detail, first_seen, snapshot_at)
   values ($SQL1, 'checkdb', 'last good CHECKDB', 'p08_never', 'sp_Blitz 68', 'critical', 'never', 'DBCC CHECKDB has never completed without error on this database', now(), now())
   on conflict do nothing" >/dev/null
q "insert into pgvigil.mssql_agent_alert (instance_id, name, message_id, severity, enabled, occurrence_count, last_occurrence_at, snapshot_at)
   values ($SQL1, 'p08 severity 19', 0, 19, true, 1, now() - interval '5 hours 10 minutes', now()) on conflict (instance_id, name) do update set last_occurrence_at = excluded.last_occurrence_at" >/dev/null
q "insert into pgvigil.mssql_suspect_page (instance_id, database_id, file_id, page_id, event_type, database_name, event, error_count, last_update_at, snapshot_at)
   values ($SQL1, 902, 1, 4711, 1, 'p08_old', '823 error', 1, now() - interval '73 hours', now()) on conflict do nothing" >/dev/null
q "insert into pgvigil.mssql_identity_column (instance_id, database_name, schema_name, table_name, column_name, type_name, last_value, max_value, pct_used, status, days_left, snapshot_at)
   values ($SQL1, 'p08_old', 'dbo', 'orders', 'id', 'int', 912680550, 2147483647, 42.50, 'ok', 120, now()) on conflict do nothing" >/dev/null
for i in $SQL1 $MS2; do for c in mssql_checks mssql_identity; do q "select pgvigil.log_collection($i, '$c', now(), 10, 'ok', null)" >/dev/null; done; done
# cell <instance id> <key>: state|critical|warning|value|since hours|since UTC midnights|sampled ('-' for no since)
cellP() { curl -fs "$U/api/mssql/summary" | python3 -c "
import json, sys, datetime
d = json.load(sys.stdin)['cells']; r = [dict(zip(d['columns'], x)) for x in d['rows']]
c = [x for x in r if str(x['instance_id']) == sys.argv[1] and x['key'] == sys.argv[2]]
if len(c) != 1: print('ROWS=%d' % len(c)); sys.exit()
c = c[0]; s = c['since']; now = datetime.datetime.now(datetime.timezone.utc)
t = None if s is None else datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).astimezone(datetime.timezone.utc)
h = '-' if t is None else str(int((now - t).total_seconds() // 3600)); dd = '-' if t is None else str((now.date() - t.date()).days)
print('%s|%s|%s|%s|%s|%s|%s' % (c['state'], c['critical'], c['warning'], c['value'] if c['value'] is not None else '-', h, dd, str(c['sampled']).lower()))" "$1" "$2"; }
want10() { local got; got=$(cellP "$1" "$2"); [[ "$got" == $3 ]] || fail "T10: $4: the $2 cell is '$got', want '$3'"; echo "     $4: $2 = $got"; }
want10 "$SQL1" checkdb "ok|1|0|Never|*|9|true" "sql01 a database never checked, the oldest 9 UTC midnights back"
want10 "$MS2" checkdb "ok|0|0|-|*|9|true" "ms2 checked 9 UTC midnights back"
want10 "$SQL1" alerts "ok|*|*|*|5|*|true" "sql01 an alert 5 h 10 min ago"
want10 "$MS2" alerts "ok|*|*|*|-|-|true" "ms2 no alert"
want10 "$SQL1" corruption "ok|*|*|*|73|*|true" "sql01 a suspect page 73 h ago"
want10 "$SQL1" identity "ok|*|*|42.5|120|-|-|true" "sql01 identity (per cent|days left)"
want10 "$SQL1" logspace "ok|*|*|*|-|-|true" "sql01 log space read"
want10 "$DUMPI" dumps "*|0|1|3 files|*|*|true" "the dump instance at the default 48 / 168 h"
[[ $(pt "{\"op\":\"set\",\"key\":\"crash\",\"level\":\"root\",\"warn\":\"200\",\"crit\":\"100\",\"ui_user\":\"proof\"}") == done ]] || fail "T10: the root crash threshold refused"
want10 "$DUMPI" dumps "*|1|0|3 files|*|*|true" "the dump instance under a root 100 / 200 h"
[[ $(pt "{\"op\":\"set\",\"key\":\"uptime\",\"level\":\"instance\",\"instance_id\":\"$SQL1\",\"warn\":\"87600\",\"ui_user\":\"proof\"}") == done ]] || fail "T10: sql01's uptime warning refused"
want10 "$SQL1" uptime "*|0|1|*|*|*|true" "sql01 uptime under its own warning of 87600 h"
SINCE=$(q "select 'since ' || floor(extract(epoch from started_at) * 1000)::bigint from pgvigil.mssql_instance where instance_id = $SQL1")
[[ $(q "select pgvigil.import_ack(now(), '{\"op\":\"add\",\"kind\":\"ack\",\"instance_id\":$SQL1,\"instance_name\":\"demo-onprem-sql01\",\"check_key\":\"uptime\",\"seen_state\":\"$SINCE\",\"until_change\":true,\"ui_user\":\"proof\"}'::jsonb)->>'outcome'") == done ]] || fail "T10: the uptime acknowledgement refused"
ok "T10: sql01 / ms2 / the dump instance's DBA Dash cells as seeded; the root crash threshold moves the dump cell; sql01's uptime warning acknowledged ($SINCE)"
DUMPN=$(q "select name from pgvigil.instances where instance_id = $DUMPI"); MS2N=$(q "select name from pgvigil.instances where instance_id = $MS2")
# one entry per instance, merged (the dump instance may be sql01: two keys of one name would leave only the last)
export CLICK_EXPECT=$(python3 -c 'import json, sys
e = {}
def add(inst, col, text): e.setdefault(inst, {})[col] = text
s1, ms2, dmp = sys.argv[1:4]
for col, text in (("Last Good Check DB", "Never"), ("SQL Agent Alerts", "5hrs"), ("Corruption", "3 days"), ("Identity Columns", "42.5% / 3 months"), ("Log Space", "View"), ("Instance Uptime", "ack: *")): add(s1, col, text)
add(ms2, "Last Good Check DB", "9 days"); add(ms2, "SQL Agent Alerts", "Never"); add(dmp, "Memory Dump", "3 days")
print(json.dumps(e))' demo-onprem-sql01 "$MS2N" "$DUMPN")
export CLICK_DUMP_ROOT="100|200"

echo "== R the reads"
js() { curl -fs "$U/api/$1" | python3 -c "import json,sys,os; d=json.load(sys.stdin); rows=lambda p: [dict(zip(d[p]['columns'], r)) for r in (d.get(p) or {'columns':[],'rows':[]})['rows']]; $2"; }
# counted again here: T's count held the edge fixture, removed at T8
N=$(q "select count(*) from pgvigil.drives_now")
[[ $(js drives "print(rows('counts')[0]['drives'])") == "$N" ]] || fail "R: counts.drives ($N in drives_now)"
[[ $(js "drives?status=critical,warning" "print(len(rows('drives')))") == $(q "select count(*) from pgvigil.drives_now where status in ('critical','warning')") ]] || fail "R: status=critical,warning"
[[ $(js "drives?instance=$ERP" "print(len({r['instance_id'] for r in rows('drives')}), len(rows('drives')))") == "1 $(q "select count(*) from pgvigil.drives_now where instance_id = $ERP")" ]] || fail "R: instance=erp01"
[[ $(js "drives?instances=0" "print(len(rows('drives')))") == 0 ]] || fail "R: instances=0"
[[ $(curl -s -o /dev/null -w '%{http_code}' "$U/api/drives?status=bogus") == 400 ]] || fail "R: status=bogus"
DATA=$(q "select mount_point from pgvigil.host_disks where instance_id = $ERP and is_present order by holds_data desc nulls last limit 1")
H=$(js "drives/history?instance=$ERP&drive=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DATA")" "print(len(rows('history')))")
(( H >= 2 )) || fail "R: drives/history of $DATA: $H points"
DQ=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DATA")
HY=$(js "drives/history?instance=$ERP&drive=$DQ&minutes=525600" "print(len(rows('history')))"); (( HY >= 2 )) || fail "R: drives/history over a year: $HY points"
# the newest read's bytes are read from the repository before and after the API call: a read stored between the two is no fault
U5Q="select used_bytes from pgvigil.host_disk_history where instance_id = $ERP and mount_point = \$\$$DATA\$\$ order by snapshot_at desc limit 1"
U5A=$(q "$U5Q")
H5=$(js "drives/history?instance=$ERP&drive=$DQ&minutes=5" "n=rows('newest'); print(len(rows('history')), len(n), int(n[0]['used_bytes']))")
U5B=$(q "$U5Q")
[[ "$H5" =~ ^[0-1]\ 5\ ($U5A|$U5B)$ ]] || fail "R: drives/history over 5 minutes: '$H5' (points: one at most, a PostgreSQL volume is stored every 15 minutes; the 5 newest reads; the newest read's used bytes, the repository's $U5A / $U5B)"
(( $(js "drives/history?instance=$ERP&drive=$DQ&days=90" "print(len(rows('history')))") >= 2 )) || fail "R: drives/history days=90"
for bad in minutes=7 days=45 minutes=x; do
  [[ $(curl -s -o /dev/null -w '%{http_code}' "$U/api/drives/history?instance=$ERP&drive=$DQ&$bad") == 400 ]] || fail "R: drives/history $bad is not refused"
done
NI=$(js dbspace "print(len(rows('instances')))"); [[ "$NI" == $(q "select count(*) from pgvigil.instances where is_active") ]] || fail "R: dbspace rows $NI"
USED=$(q "select coalesce(string_agg(i.name || ':' || coalesce(x.u::text, 'none'), ',' order by i.name), '') from pgvigil.instances i cross join lateral (select case when bool_and(f.used_read) then sum(f.used_bytes) end u from pgvigil.mssql_files f where f.instance_id = i.instance_id and f.is_present) x where i.is_active and i.engine = 'sqlserver'")
[[ $(js dbspace "print(','.join(sorted(r['instance'] + ':' + (str(int(r['used_bytes'])) if r['used_bytes'] is not None else 'none') for r in rows('instances') if r['engine'] == 'sqlserver')))") == "$USED" ]] || fail "R: SQL Server used [$USED] differs from dbspace's"
[[ "$USED" == *none* && "$USED" == *[0-9]* ]] || fail "R: the demo's SQL Server rows hold no unread or no read used ($USED): the case is not exercised"
[[ $(js "dbspace?instance=$SQL1" "print(int(len(rows('databases')) >= 1 and len(rows('history')) >= 2))") == 1 ]] || fail "R: dbspace of sql01"
[[ $(js "dbfiles?instance=$SQL1" "print(int(len(rows('files')) >= 1 and all(r['status'] in ('ok','warning','critical') for r in rows('files'))))") == 1 ]] || fail "R: dbfiles of sql01"
[[ $(js dbfiles "print(rows('counts')[0]['files'])") == $(q "select (select count(*) from pgvigil.mssql_files f join pgvigil.instances i using (instance_id) where f.is_present and i.is_active) + (select count(*) from pgvigil.storage_state s join pgvigil.instances i using (instance_id) where s.is_present and s.kind in ('wal','tablespace') and i.is_active)") ]] || fail "R: dbfiles counts"
# a drive's files (task 176b): sql01's E:\ only, as many as mssql_files puts there; erp01's data volume holds its pg_wal (no location: the data directory's)
EVOL=$(q "select volume from pgvigil.mssql_files where instance_id = $SQL1 and is_present and volume is not null group by volume order by count(*) desc, volume limit 1")
EQ=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$EVOL")
[[ $(VOL="$EVOL" js "dbfiles?instance=$SQL1&drive=$EQ" "r=rows('files'); print(int(len(r) >= 1 and all(x['drive'] == os.environ['VOL'] for x in r)), len(r))") == "1 $(q "select count(*) from pgvigil.mssql_files where instance_id = $SQL1 and is_present and volume = '$EVOL'")" ]] || fail "R: dbfiles of sql01 on $EVOL"
DQ=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$DATA")
[[ $(js "dbfiles?instance=$ERP&drive=$DQ" "print(int(any(x['file'] == 'pg_wal' for x in rows('files'))))") == 1 ]] || fail "R: erp01's pg_wal not on $DATA"
# the collection dates: one row per active instance and collection; critical exactly where the last run failed
[[ $(js collectiondates "print(len(rows('collections')))") == $(q "select count(*) from pgvigil.collection_dates c join pgvigil.instances i using (instance_id) where i.is_active") ]] || fail "R: collectiondates rows"
[[ $(js collectiondates "r=rows('collections'); print(int(all(x['status'] in ('critical','warning','ok','disabled') for x in r) and all((x['status'] == 'critical') == (x['last_status'] == 'error') for x in r if x['status'] != 'disabled')))") == 1 ]] || fail "R: collectiondates statuses"
[[ $(js "collectiondates?instance=$SQL1" "r=rows('collections'); print(int(len(r) >= 1 and all(str(x['instance_id']) == '$SQL1' for x in r)))") == 1 ]] || fail "R: collectiondates of sql01"
VOLS=$(q "select string_agg(volume, '|') from pgvigil.mssql_volumes where instance_id = $SQL1")
# the volume names travel through the environment: a Windows name ends in a backslash, which a quoted literal would eat
[[ $(VOLS="$VOLS" js "driveperf?instance=$SQL1" "v=set(os.environ['VOLS'].split('|'))|{'drive not read'}; r=rows('series'); print(int(len(r) >= 1 and all(x['drive'] in v for x in r)))") == 1 ]] || fail "R: driveperf of sql01"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "$U/api/drives/thresholds") == 403 ]] || fail "R: a write without the header"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Pgvigil: 1' -d '{}' "$U/api/drives/thresholds") == 403 ]] || fail "R: a write without the login"
ok "R: drives, history ($H points; a year $HY; 5 minutes '$H5'; a window off the list refused), dbspace ($NI instances), dbfiles (sql01 on $EVOL, erp01's pg_wal on $DATA), driveperf, collectiondates answer as the repository says; the write door refuses without the header and the login"

echo "== C the click map (headless Chromium on CDP $CDP)"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
node scripts/click-check.mjs "$CDP" "$U/" "${PGVIGIL_CLICK_OUT:-$WORK/click.json}" | tee "$WORK/click.txt" || fail "the click map has a FAIL (above)"
grep -q '^links: .*; 0 FAIL$' "$WORK/click.txt" || fail "click-check.mjs did not end with 0 FAIL"
# the check found what it was to check (a check that collected nothing passes nothing)
python3 - "${PGVIGIL_CLICK_OUT:-$WORK/click.json}" <<'PY' || fail "the click map checked too little (above)"
import json, os, sys
d = json.load(open(sys.argv[1])); r = d['results']; bad = []
has = lambda **k: [x for x in r if all(x.get(a) == b for a, b in k.items())]
# task P08: DBA Dash's columns: each with a link on the engines that read it, at the root
for c, engines in (('Drive Space', ('postgres', 'sqlserver')), ('Backup FULL', ('postgres', 'sqlserver')), ('Agent Jobs', ('postgres', 'sqlserver')),
                   ('Last Good Check DB', ('postgres', 'sqlserver')), ('SQL Agent Alerts', ('sqlserver',)), ('Corruption', ('sqlserver',)),
                   ('Identity Columns', ('sqlserver',)), ('Log Space', ('sqlserver',)), ('Availability Groups', ('postgres', 'sqlserver')),
                   ('Snapshot Age', ('postgres', 'sqlserver')), ('Collection Errors (24hrs)', ('postgres', 'sqlserver'))):
    for e in engines:
        if not has(scope='root', kind='cell', column=c, engine=e): bad.append('no %s cell of %s at the root' % (c, e))
for c in ('Drive Space', 'Backup FULL', 'Snapshot Age'):
    if not has(scope='root', kind='test', column=c): bad.append('no %s test link at the root' % c)
shape = has(scope='root', kind='shape')
if len(shape) < 13: bad.append('%d Summary shape checks (13 or more besides the texts: headers, order, fill, listing, columns, plain cells, toolbar, Refresh Time, height, Options, its height menu, both dialogs, View)' % len(shape))
pairs = [(i, c) for i, w in json.loads(os.environ.get('CLICK_EXPECT', '{}')).items() for c in w]
seen = {x['column'][:-5] + '|' + x['landed'].split(':')[0] for x in shape if x['column'].endswith(' text')}
missing = ['%s %s' % p for p in pairs if '%s|%s' % (p[1], p[0]) not in seen]
if not pairs or missing: bad.append('the T10 texts not checked: ' + (', '.join(missing) or 'CLICK_EXPECT is empty'))
for s in ('root', 'tag ' + d['tag']):
    if not [x for x in has(scope=s, kind='tree') if x['verdict'].startswith('ok')]: bad.append('no tree Storage node at ' + s)
for s in ('root', 'tag ' + d['tag'], 'PostgreSQL ' + d['pg'], 'SQL Server ' + d['ms']):
    t = has(scope=s, kind='storage-tab')
    if len(t) < 6: bad.append('%d Storage tabs at %s' % (len(t), s))
# task 176b: the four landings DBA Dash's map now holds, the Uptime dialog, a drive's Files, the PostgreSQL Temp tab
for e in ('postgres', 'sqlserver'):
    # QS is SQL Server's Query Store alone; PostgreSQL's statement store is its own column (Allen 2026-11-12)
    for c in ('Snapshot Age', 'Database State', 'QS' if e == 'sqlserver' else 'pg_stat_statements', 'Instance Uptime'):
        got = has(scope='root', kind='cell', column=c, engine=e)
        if not got: bad.append('no %s cell of %s at the root' % (c, e))
        elif any('named difference' in x['verdict'] for x in got): bad.append('%s of %s still a named difference' % (c, e))
    if has(scope='root', kind='cell', column='pg_stat_statements' if e == 'sqlserver' else 'QS', engine=e): bad.append('a %s cell is a link on %s' % ('pg_stat_statements' if e == 'sqlserver' else 'QS', e))
    if not [x for x in r if x['kind'] == 'cell' and x['column'] == 'Instance Uptime' and x['engine'] == e and 'dialog over the Summary' in x['landed']]: bad.append('no Instance Uptime dialog clicked on ' + e)
for s in ('PostgreSQL ' + d['pg'], 'SQL Server ' + d['ms']):
    if not [x for x in has(scope=s, kind='drive-files') if x['verdict'].startswith('ok')]: bad.append('no drive Files link checked at ' + s)
if not has(scope='PostgreSQL ' + d['pg'], kind='storage-tab', column='Temp'): bad.append('no Temp tab under ' + d['pg'])
# task 177 D29: PerformanceMonitor's links and buttons, on an instance of each engine
if not has(scope='root', kind='pm', column='Silence (Summary row)'): bad.append("no Summary row's Silence button checked")
for e, n in (('sqlserver', d['ms']), ('postgres', d['pg'])):
    for c in ('header name', 'breadcrumb dot', 'calendar months', 'calendar table', 'calendar day', 'calendar View Top Queries', 'Performance zoom', 'zoom: two drags', 'zoom: Reset zoom from a custom range'):
        if not has(scope='%s %s' % (e, n), kind='pm', column=c): bad.append('no %s checked on %s' % (c, n))
print('the click map covered: ' + ('every kind asked' if not bad else '; '.join(bad)))
sys.exit(1 if bad else 0)
PY
echo "PROOF OK"
