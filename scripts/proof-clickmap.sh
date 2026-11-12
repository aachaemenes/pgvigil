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
#     400. /api/drives/history for erp01's data volume: 2 points at least. /api/dbspace: one row per active instance
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
# the edges: a scratch instance of each engine with a drive at 9.96 % and one at 4.96 % free, read now
q "insert into pgvigil.instances (name, platform, engine) values ('fx-drive-pg', 'onprem', 'postgres'), ('fx-drive-ms', 'onprem', 'sqlserver')" >/dev/null
FXP=$(q "select instance_id from pgvigil.instances where name = 'fx-drive-pg'"); FXM=$(q "select instance_id from pgvigil.instances where name = 'fx-drive-ms'")
q "insert into pgvigil.host_disks (instance_id, mount_point, snapshot_at, source, total_bytes, used_bytes, free_bytes, first_seen)
   values ($FXP, '/fx996', now(), 'system_stats', 100000, 90040, 9960, now()), ($FXP, '/fx496', now(), 'system_stats', 100000, 95040, 4960, now());
   insert into pgvigil.mssql_volumes (instance_id, volume, total_bytes, free_bytes, files, snapshot_at)
   values ($FXM, 'X:', 100000, 9960, 1, now()), ($FXM, 'Y:', 100000, 4960, 1, now())" >/dev/null
FX=$(q "select string_agg(engine || ' ' || drive || ' ' || status, ', ' order by engine, drive) from pgvigil.drives_now where instance_id in ($FXP, $FXM)")
[[ "$FX" == 'postgres /fx496 warning, postgres /fx996 ok, sqlserver X: warning, sqlserver Y: critical' ]] || fail "T1: the edge fixture: $FX"
N=$(q "select count(*) from pgvigil.drives_now"); NPG=$(q "select count(*) from pgvigil.drives_now where engine = 'postgres'"); NMS=$(q "select count(*) from pgvigil.drives_now where engine = 'sqlserver'")
(( NPG > 0 && NMS > 0 )) || fail "T: the demo's drives: $NPG PostgreSQL, $NMS SQL Server"
[[ $(off "'default|10|5'") == 0 ]] || fail "T1: drives off the old rule at the default: $(off "'default|10|5'")"
OLDPG=$(q "select coalesce(string_agg(instance_id || ':' || mount_point || ':' || case when free_pct < 5 then 'critical' else 'warning' end, ',' order by instance_id, mount_point), '') from pgvigil.disk_report where free_pct < 10 and snapshot_at > now() - interval '1 hour'")
NEWPG=$(q "select coalesce(string_agg(instance_id || ':' || object || ':' || severity, ',' order by instance_id, object), '') from pgvigil.host_checks where check_group = 'disk'")
[[ "$OLDPG" == "$NEWPG" ]] || fail "T1: host_checks' disk rows [$NEWPG], the old rule [$OLDPG]"
OLDMS=$(q "select coalesce(string_agg(instance_id || ':' || volume || ':' || case when 100.0 * free_bytes / total_bytes < 5 then 'critical' else 'warning' end, ',' order by instance_id, volume), '') from pgvigil.mssql_volumes where is_present and total_bytes > 0 and free_bytes is not null and 100.0 * free_bytes / total_bytes < 10 and snapshot_at > now() - interval '3 hours'")
NEWMS=$(q "select coalesce(string_agg(instance_id || ':' || object || ':' || severity, ',' order by instance_id, object), '') from pgvigil.mssql_storage_findings where check_name = 'a volume under 10 % free'")
[[ "$OLDMS" == "$NEWMS" ]] || fail "T1: mssql_storage_findings' volume rows [$NEWMS], the old rule [$OLDMS]"
[[ -n "$NEWPG$NEWMS" ]] || fail "T1: the demo raises no drive row on either engine (nothing compared)"
[[ $(q "select count(*) from (select detail from pgvigil.host_checks where check_group = 'disk' union all select detail from pgvigil.mssql_storage_findings where check_name = 'a volume under 10 % free') x where detail not like '%warning under 10 %, critical under 5 % (the default)%'") == 0 ]] || fail "T1: a detail without the threshold in force"
ok "T1: $N drives ($NPG PostgreSQL, $NMS SQL Server, the edge fixture's 4 among them: $FX) at the default judge as before 0111; host_checks [$NEWPG], mssql_storage_findings [$NEWMS]"
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
[[ $(off "'default|10|5'") == 0 && $(q "select count(*) from pgvigil.drive_thresholds where ended_at is null") == 0 ]] || fail "T8: not back at the default"
q "delete from pgvigil.instances where instance_id in ($FXP, $FXM)" >/dev/null
ok "T8: every level inherited: the default again"

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
NI=$(js dbspace "print(len(rows('instances')))"); [[ "$NI" == $(q "select count(*) from pgvigil.instances where is_active") ]] || fail "R: dbspace rows $NI"
USED=$(q "select coalesce(string_agg(i.name || ':' || coalesce(x.u::text, 'none'), ',' order by i.name), '') from pgvigil.instances i cross join lateral (select case when bool_and(f.used_read) then sum(f.used_bytes) end u from pgvigil.mssql_files f where f.instance_id = i.instance_id and f.is_present) x where i.is_active and i.engine = 'sqlserver'")
[[ $(js dbspace "print(','.join(sorted(r['instance'] + ':' + (str(int(r['used_bytes'])) if r['used_bytes'] is not None else 'none') for r in rows('instances') if r['engine'] == 'sqlserver')))") == "$USED" ]] || fail "R: SQL Server used [$USED] differs from dbspace's"
[[ "$USED" == *none* && "$USED" == *[0-9]* ]] || fail "R: the demo's SQL Server rows hold no unread or no read used ($USED): the case is not exercised"
[[ $(js "dbspace?instance=$SQL1" "print(int(len(rows('databases')) >= 1 and len(rows('history')) >= 2))") == 1 ]] || fail "R: dbspace of sql01"
[[ $(js "dbfiles?instance=$SQL1" "print(int(len(rows('files')) >= 1 and all(r['status'] in ('ok','warning','critical') for r in rows('files'))))") == 1 ]] || fail "R: dbfiles of sql01"
[[ $(js dbfiles "print(rows('counts')[0]['files'])") == $(q "select (select count(*) from pgvigil.mssql_files f join pgvigil.instances i using (instance_id) where f.is_present and i.is_active) + (select count(*) from pgvigil.storage_state s join pgvigil.instances i using (instance_id) where s.is_present and s.kind in ('wal','tablespace') and i.is_active)") ]] || fail "R: dbfiles counts"
VOLS=$(q "select string_agg(volume, '|') from pgvigil.mssql_volumes where instance_id = $SQL1")
# the volume names travel through the environment: a Windows name ends in a backslash, which a quoted literal would eat
[[ $(VOLS="$VOLS" js "driveperf?instance=$SQL1" "v=set(os.environ['VOLS'].split('|'))|{'drive not read'}; r=rows('series'); print(int(len(r) >= 1 and all(x['drive'] in v for x in r)))") == 1 ]] || fail "R: driveperf of sql01"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "$U/api/drives/thresholds") == 403 ]] || fail "R: a write without the header"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Pgvigil: 1' -d '{}' "$U/api/drives/thresholds") == 403 ]] || fail "R: a write without the login"
ok "R: drives, history ($H points), dbspace ($NI instances), dbfiles, driveperf answer as the repository says; the write door refuses without the header and the login"

echo "== C the click map (headless Chromium on CDP $CDP)"
chromium --headless=new --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome" --no-first-run --disable-gpu about:blank > "$WORK/chrome.log" 2>&1 &
CHR=$!
for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
node scripts/click-check.mjs "$CDP" "$U/" "${PGVIGIL_CLICK_OUT:-$WORK/click.json}" | tee "$WORK/click.txt" || fail "the click map has a FAIL (above)"
grep -q '^links: .*; 0 FAIL$' "$WORK/click.txt" || fail "click-check.mjs did not end with 0 FAIL"
# the check found what it was to check (a check that collected nothing passes nothing)
python3 - "${PGVIGIL_CLICK_OUT:-$WORK/click.json}" <<'PY' || fail "the click map checked too little (above)"
import json, sys
d = json.load(open(sys.argv[1])); r = d['results']; bad = []
has = lambda **k: [x for x in r if all(x.get(a) == b for a, b in k.items())]
for e in ('postgres', 'sqlserver'):
    for c in ('Disk', 'Storage'):
        if not has(scope='root', kind='cell', column=c, engine=e): bad.append('no %s cell of %s at the root' % (c, e))
for c in ('Disk', 'Storage'):
    if not has(scope='root', kind='test', column=c): bad.append('no %s test link at the root' % c)
for s in ('root', 'tag ' + d['tag']):
    if not [x for x in has(scope=s, kind='tree') if x['verdict'].startswith('ok')]: bad.append('no tree Storage node at ' + s)
for s in ('root', 'tag ' + d['tag'], 'PostgreSQL ' + d['pg'], 'SQL Server ' + d['ms']):
    t = has(scope=s, kind='storage-tab')
    if len(t) < 6: bad.append('%d Storage tabs at %s' % (len(t), s))
print('the click map covered: ' + ('every kind asked' if not bad else '; '.join(bad)))
sys.exit(1 if bad else 0)
PY
echo "PROOF OK"
