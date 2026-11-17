#!/usr/bin/env bash
# Proof of Save Table's write door (task 7b: internal/savetable, internal/actions/savetable.go,
# internal/mssql/savetable.go, internal/web/savetable.go, migration 0362) THROUGH THE API of a running `pgvigil serve`,
# as signed-in UI users, on both engines: the box's PostgreSQL (the store, and the monitored PostgreSQL in databases of
# this run's own) and a SQL Server 2022 container of this run's own. Every attempt is read back from
# pgvigil.actions_log, every written table from the server it went to.
#
# Needs: docker, psql, curl, python3, and
#   PGVIGIL_ADMIN_DSN  a superuser connection to the PostgreSQL in KEYWORD form, no dbname (host=... port=... user=...)
#   PGVIGIL_BIN        a build of this tree WITH scripts/savetable-wiring.patch applied (the routes, the switch)
# It makes its repository database, three target databases and one template, five PostgreSQL logins, a SQL Server
# container with four logins and two databases (the sa password through an env file, never a command line), two UI
# users and two serves; everything is dropped at the end, on every exit path.
#
# Expected (written 11-17 02:4x before the first run; the lead's three named checks are C1 / C2, E and the store's
# TestSaveTableAuditOnAStore):
#  A. the switch off (a serve without doors.save_table): GET /api/actions/save_table says off 'off: an administrator
#     turns on doors: save_table in pgvigil.yaml'; the POST 403 with those words; no actions_log row.
#  B. the switch on: GET on pg-save is on with the schema pgvigil_saved and its databases without template1 (and the
#     run's template database); on ms-save on without master; on pg-nolist off 'off: this instance's actions: list
#     does not name save_table'. An operator's POST 403 (the admin role's words); no row.
#  C1. NAMED CHECK (1) and (2), PostgreSQL: a grid of 10,003 rows into the table x"y]z.w;-- with a column txt "q" ]x
#     - the values ''); DROP TABLE t;--', a]b"c'd, x<NUL>y, 9007199254740993, a time with its offset, a date, true /
#     false and nulls: 200 'Saved 10003 rows to <db>.pgvigil_saved.x"y]z.w;--; 1 NUL character(s) dropped from text
#     cells'; read back as the superuser: ONE new relation in pgvigil_saved named exactly x"y]z.w;--, 10,003 rows,
#     every value equal to the one sent (the NUL dropped: xy), the decoy table t of the database untouched.
#  C2. the same on SQL Server into [pgvigil_saved].[x"y]]z.w;--] of SaveDB: 200, the same read back.
#  D. no overwrite: the PostgreSQL save again: 409 'exists: pgvigil never overwrites a table', still 10,003 rows.
#  J1. a dotted name on SQL Server: the table dbo.Customers (3 rows) lands in [pgvigil_saved].[dbo.Customers]; the
#     decoys [dbo].[Customers] and [pgvigil_saved].[Customers] hold 0 rows.
#  E. the refusals, each 409 with its words and ONE audit row: pg-nolist (the list); the table name typed as the
#     confirmation; template1; a database without the schema (the schema's words); a schema owned by another login;
#     pg-same (the read login: 'login of its own'); pg-super ('superuser'); a value that is no whole number ('row 1,
#     column id', the value never in the words); SQL Server: a '#' table, master, a database without the schema,
#     ms-sys ('sysadmin').
#  F. the body's limits: over 32 MiB 413 'over 32 MiB'; 1,025 columns on SQL Server 400 '1024'; no row for either.
#  G. the audit: exactly 19 save_table rows - started 3, done 3, refused 13; the started / done pairs of C1, C2, J1
#     with engine postgres / sqlserver, the target and the database, pid NULL; no row's detail holds the refused value.
#  J4. why the schema is the door login's own (review-29 B2), on SQL Server: with CREATE TABLE and ALTER on dbo the
#     actions login drops dbo.victim; with only its own schema it cannot (Msg 3701) and creates
#     pgvigil_saved.j4 (sa restores the state between the two).
#  K. review-31 part A2's rows (after G, so G's counts stand):
#   K1 (SF3) a body whose database holds a NUL: 409 'control character' and ONE audit row with datname and target
#      '(a refused name)' (before the fix: 500 and no row); a table name holding U+202E: 409 'invisible character',
#      the row's target '(a refused name)', its datname the database.
#   K2 (SF2) a database whose OWNER (no superuser) set search_path = public, pg_catalog and planted a domain
#      public.text whose check runs a function of his: the save is done and the new column is pg_catalog.text (before
#      the fix: failed, the owner's function ran as the actions login).
#   K3 (NIT 5) with ALTER ROLE <actions login> SET default_transaction_read_only = on a save is still done.
#   K4 (SF1) SQL Server: a database whose db_owner member (no sysadmin) made a DDL trigger on CREATE_TABLE that logs
#      what the caller may do, the actions login holding ALTER ANY CONNECTION as docs/sqlserver-actions.md grants it:
#      the save is done, the trigger ran ONCE as the actions login's database user and found ALTER ANY CONNECTION = 0
#      (before the fix: 1 - a database owner's code with the right to end sessions).
#   K5 (SF4) SQL Server: a distribution database with the schema and the grant in place: refused 'replication
#      distribution database', no table made - or 'NOT PROVEN K5' when the container cannot be made a distributor.
#   K6 (NIT 6) SQL Server: an actions login in db_owner of the target: refused naming db_owner.
#  NOT PROVEN HERE: J5 (a save over serve's 75 s WriteTimeout: the route moves its deadline as AppImport does);
#  'another server' (one PostgreSQL and one SQL Server only: the unit rows hold it); Azure SQL Database, RDS.
# The last line 'proof-savetable: <n> FAIL' (0 = every row ok); rc 1 when any failed.
set -uo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_ADMIN_DSN:?a superuser keyword DSN without dbname}"
SUF=$RANDOM
REPO=pgv_st_repo_$SUF; TDB=pgv_st_t_$SUF; NOS=pgv_st_nos_$SUF; OTH=pgv_st_oth_$SUF; TPL=pgv_st_tpl_$SUF; SPD=pgv_st_sp_$SUF
MON=pgv_st_mon_$SUF; ACT=pgv_st_act_$SUF; OWN=pgv_st_own_$SUF
pw() { printf 'Pv9%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
PPW=$(pw); MSPW=$(pw); UPW=$(pw)
W=$(mktemp -d); CT=savetable-mssql-$SUF; SRV=; SRV2=; FAILS=0
cleanup() {
  [[ -n $SRV ]] && kill "$SRV" 2>/dev/null; [[ -n $SRV2 ]] && kill "$SRV2" 2>/dev/null
  docker rm -fv "$CT" >/dev/null 2>&1
  for d in $REPO $TDB $NOS $OTH $SPD; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1; done
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "alter database $TPL is_template false" -c "drop database if exists $TPL with (force)" >/dev/null 2>&1
  for r in $MON $ACT $OWN; do psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop role if exists $r" >/dev/null 2>&1; done
  rm -rf "$W"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL setup: $*"; echo "proof-savetable: setup FAIL"; exit 1; }
for t in docker psql curl python3; do command -v $t >/dev/null || die "$t is not on this machine"; done
adm() { psql "$PGVIGIL_ADMIN_DSN dbname=${2:-postgres}" -XAt -v ON_ERROR_STOP=1 -c "$1"; }

# ---- the SQL Server container (the sa password in an env file) -------------------------------------------------------
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nSQLCMDPASSWORD=%s\n' "$(pw)Aa1!" "" > "$W/sa.env"
SAPW=$(sed -n 's/^MSSQL_SA_PASSWORD=//p' "$W/sa.env"); sed -i "s/^SQLCMDPASSWORD=.*/SQLCMDPASSWORD=$SAPW/" "$W/sa.env"
docker run -d --name "$CT" --env-file "$W/sa.env" -p 127.0.0.1::1433 mcr.microsoft.com/mssql/server:2022-latest >/dev/null || die "the SQL Server container did not start"
MSPORT=$(docker port "$CT" 1433/tcp | head -1 | sed 's/.*://')
sq() { docker exec --env-file "$W/sa.env" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -s '|' -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || die "the SQL Server container did not answer in 180 s"
msdsn() { echo "sqlserver://$1:$2@127.0.0.1:$MSPORT?database=master&encrypt=true&TrustServerCertificate=true"; }
sq "CREATE LOGIN msmon WITH PASSWORD = '$MSPW', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO msmon;
    CREATE LOGIN msact WITH PASSWORD = '$MSPW', CHECK_POLICY = OFF;
    CREATE LOGIN mssys WITH PASSWORD = '$MSPW', CHECK_POLICY = OFF; ALTER SERVER ROLE sysadmin ADD MEMBER mssys;
    CREATE LOGIN msown WITH PASSWORD = '$MSPW', CHECK_POLICY = OFF;
    CREATE DATABASE SaveDB; CREATE DATABASE NoSchemaDB;" >/dev/null || die "SQL Server logins and databases"
sq "CREATE USER msact FOR LOGIN msact; GRANT CREATE TABLE TO msact;
    EXEC ('CREATE SCHEMA pgvigil_saved AUTHORIZATION msact');
    CREATE TABLE dbo.Customers (a int); CREATE TABLE pgvigil_saved.Customers (a int);
    CREATE USER msown FOR LOGIN msown; ALTER ROLE db_owner ADD MEMBER msown;" SaveDB >/dev/null || die "SaveDB"
sq "CREATE USER msact FOR LOGIN msact; GRANT CREATE TABLE TO msact;" NoSchemaDB >/dev/null || die "NoSchemaDB"

# ---- PostgreSQL: the store, the targets, the logins ------------------------------------------------------------------
adm "create database $REPO" >/dev/null && adm "create database $TDB" >/dev/null && adm "create database $NOS" >/dev/null \
  && adm "create database $OTH" >/dev/null && adm "create database $TPL is_template true" >/dev/null || die "the databases"
adm "create role $MON login password '$PPW' in role pg_monitor" >/dev/null && adm "create role $ACT login password '$PPW'" >/dev/null || die "the roles"
adm "create schema pgvigil_saved authorization $ACT; create table public.t (a int); insert into public.t values (1), (2)" "$TDB" >/dev/null || die "the target database"
adm "create schema pgvigil_saved authorization $MON" "$OTH" >/dev/null || die "the other owner's schema"
HOST=$(adm "select coalesce(host(inet_server_addr()), '127.0.0.1')"); PORT5=$(adm "select current_setting('port')")
pgdsn() { echo "host=$HOST port=$PORT5 user=$1 password=$PPW dbname=$TDB sslmode=disable"; }
export PGVIGIL_REPO_DSN="$PGVIGIL_ADMIN_DSN dbname=$REPO"
export PGS_MON PGS_MON2 PGS_ACT PGS_SUP MSS_MON MSS_ACT MSS_SYS MSS_OWN
PGS_MON=$(pgdsn "$MON"); PGS_MON2=$PGS_MON; PGS_ACT=$(pgdsn "$ACT"); PGS_SUP="$PGVIGIL_ADMIN_DSN dbname=$TDB"
MSS_MON=$(msdsn msmon "$MSPW"); MSS_ACT=$(msdsn msact "$MSPW"); MSS_SYS=$(msdsn mssys "$MSPW"); MSS_OWN=$(msdsn msown "$MSPW")
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$W/on.yaml" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
doors:
  save_table: on
instances:
  - {name: pg-save-$SUF, dsn: "env:PGS_MON", actions_dsn: "env:PGS_ACT", actions: [save_table]}
  - {name: pg-nolist-$SUF, dsn: "env:PGS_MON", actions_dsn: "env:PGS_ACT"}
  - {name: pg-same-$SUF, dsn: "env:PGS_MON", actions_dsn: "env:PGS_MON2", actions: [save_table]}
  - {name: pg-super-$SUF, dsn: "env:PGS_MON", actions_dsn: "env:PGS_SUP", actions: [save_table]}
  - {name: ms-save-$SUF, engine: sqlserver, dsn: "env:MSS_MON", actions_dsn: "env:MSS_ACT", actions: [save_table]}
  - {name: ms-sys-$SUF, engine: sqlserver, dsn: "env:MSS_MON", actions_dsn: "env:MSS_SYS", actions: [save_table]}
  - {name: ms-own-$SUF, engine: sqlserver, dsn: "env:MSS_MON", actions_dsn: "env:MSS_OWN", actions: [save_table]}
EOF
sed '/^doors:/,/^  save_table:/d' "$W/on.yaml" > "$W/off.yaml"
"$BIN" migrate -config "$W/on.yaml" > "$W/migrate.log" 2>&1 || die "migrate: $(tail -3 "$W/migrate.log")"
id_of() { q "select pgvigil.ensure_instance('$1', 'onprem', '16.0', 160000, false, '{}', '$2')"; }
for n in pg-save pg-nolist pg-same pg-super; do declare "ID_${n//-/_}=$(id_of "$n-$SUF" postgres)"; done
for n in ms-save ms-sys ms-own; do declare "ID_${n//-/_}=$(id_of "$n-$SUF" sqlserver)"; done
for id in $ID_pg_save $ID_pg_nolist $ID_pg_same $ID_pg_super; do
  q "insert into pgvigil.databases (instance_id, dbid, datname, snapshot_at, is_template, first_seen, is_present)
     values ($id, 1, '$TDB', now(), false, now(), true), ($id, 2, '$NOS', now(), false, now(), true),
            ($id, 3, '$OTH', now(), false, now(), true), ($id, 4, 'template1', now(), true, now(), true),
            ($id, 5, '$TPL', now(), true, now(), true)" >/dev/null
done
SAVEID=$(sq "SELECT DB_ID('SaveDB')"); NOSID=$(sq "SELECT DB_ID('NoSchemaDB')")
for id in $ID_ms_save $ID_ms_sys $ID_ms_own; do
  q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, snapshot_at, is_present)
     values ($id, 'SaveDB', $SAVEID, now(), true), ($id, 'NoSchemaDB', $NOSID, now(), true), ($id, 'master', 1, now(), true)" >/dev/null
done
PGVIGIL_PASSWORD=$UPW "$BIN" user add -config "$W/on.yaml" stadmin > /dev/null 2>&1 || die "user add (the first: admin)"
PGVIGIL_PASSWORD=$UPW "$BIN" user add -config "$W/on.yaml" -role operator stop > /dev/null 2>&1 || die "user add (operator)"
freeport() { local p; for _ in $(seq 1 50); do p=$((20000 + RANDOM % 20000)); ss -ltn | awk '{print $4}' | grep -qE "(^|[:\]])$p$" || { echo "$p"; return; }; done; die "no free port"; }
serve() { "$BIN" serve -config "$1" -listen "127.0.0.1:$2" >> "$W/serve-$2.log" 2>&1 & local p=$!
  for _ in $(seq 1 60); do curl -sf -o /dev/null "http://127.0.0.1:$2/" && { echo $p; return; }; kill -0 $p 2>/dev/null || die "serve died: $(tail -3 "$W/serve-$2.log")"; sleep 0.5; done; die "serve did not answer"; }
P1=$(freeport); SRV=$(serve "$W/on.yaml" "$P1"); P2=$(freeport); SRV2=$(serve "$W/off.yaml" "$P2")
login() { curl -s -c "$W/jar-$1-$2" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' -d "{\"username\":\"$1\",\"password\":\"$UPW\"}" "http://127.0.0.1:$2/api/login" >/dev/null; }
login stadmin "$P1"; login stop "$P1"; login stadmin "$P2"
code() { curl -s -o "$W/body" -w '%{http_code}' "$@"; }
said() { python3 -c 'import json,sys; b=open(sys.argv[1]).read();
try: d=json.loads(b); print(d.get("detail") or d.get("error") or d.get("off") or b)
except Exception: print(b[:300])' "$W/body"; }
rows() { q "select count(*) from pgvigil.actions_log where action = 'save_table'"; }

# ---- the bodies (python: the hostile names and values, and what each read back must print) ----------------------------
python3 - "$W" "$TDB" "$SUF" <<'PY'
import json, sys, os
w, tdb, suf = sys.argv[1], sys.argv[2], sys.argv[3]
cols = [{"name": "id", "type": "int"}, {"name": 'txt "q" ]x', "type": "text"}, {"name": "amt", "type": "dec"},
        {"name": "w", "type": "time"}, {"name": "d", "type": "day"}, {"name": "flag", "type": "bool"}, {"name": "big", "type": "int"}]
rows = [[1, "'); DROP TABLE t;--", 1.5, "2026-11-17T02:10:00-08:00", "2026-11-17", True, 9007199254740993],
        [2, "a]b\"c'd", -0.0000000001, None, None, False, 2],
        [3, "x\u0000y", None, "2026-11-17T10:10:00Z", "2026-01-31", None, 3]]
rows += [[i, "r%d" % i, i / 8, "2026-11-17T00:00:00Z", "2026-11-17", i % 2 == 0, i] for i in range(4, 10004)]
def body(inst, db, table, confirm, c=cols, r=rows, frm="grid"):
    return {"instance_id": int(inst), "database": db, "table": table, "from": frm, "confirm": confirm, "cols": c, "rows": r}
json.dump({"cols": cols, "rows": rows}, open(os.path.join(w, "grid.json"), "w"))
# the expected read back: count, the three hostile rows, the sums (both engines print them alike)
exp = ["10003", "1|'); DROP TABLE t;--|1.5000000000|2026-11-17T10:10:00|2026-11-17|1|9007199254740993",
       "2|a]b\"c'd|-0.0000000001|NULL|NULL|0|2", "3|xy|NULL|2026-11-17T10:10:00|2026-01-31|NULL|3",
       "sum_id %d sum_big %d" % (sum(r[0] for r in rows), sum(r[6] for r in rows))]
open(os.path.join(w, "expect.txt"), "w").write("\n".join(exp) + "\n")
PY
mk() {   # mk <file> <instance_id> <database> <table> <confirm> [python edit of b]
  python3 - "$W" "$@" <<'PY'
import json, sys, os
w, f, inst, db, table, confirm = sys.argv[1:7]
g = json.load(open(os.path.join(w, "grid.json")))
b = {"instance_id": int(inst), "database": db, "table": table, "from": "grid", "confirm": confirm, "cols": g["cols"], "rows": g["rows"]}
if len(sys.argv) > 7: exec(sys.argv[7])
json.dump(b, open(os.path.join(w, f), "w"))
PY
}
post() { code -b "$W/jar-$1-$2" -H 'X-Pgvigil: 1' -H 'Content-Type: application/json' --data-binary "@$W/$4" "http://127.0.0.1:$2/api/actions/save_table?instance_id=$3"; }
HN='x"y]z.w;--'
mk pg.json "$ID_pg_save" "$TDB" "$HN" "pg-save-$SUF/$TDB"
mk ms.json "$ID_ms_save" SaveDB "$HN" "ms-save-$SUF/SaveDB"

# ---- A: the switch off ---------------------------------------------------------------------------------------------------
c=$(code -b "$W/jar-stadmin-$P2" "http://127.0.0.1:$P2/api/actions/save_table?instance_id=$ID_pg_save")
[[ $c == 200 && $(said) == "off: an administrator turns on doors: save_table in pgvigil.yaml" ]] && ok "A: GET with the switch off: $(said)" || bad "A: GET with the switch off: $c $(said)"
c=$(post stadmin "$P2" "$ID_pg_save" pg.json)
[[ $c == 403 && $(said) == *"turns on doors: save_table"* && $(rows) == 0 ]] && ok "A: POST with the switch off 403, no row" || bad "A: POST with the switch off: $c $(said); rows $(rows)"

# ---- B: the switch on --------------------------------------------------------------------------------------------------
st() { code -b "$W/jar-stadmin-$P1" "http://127.0.0.1:$P1/api/actions/save_table?instance_id=$1" >/dev/null; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["on"], d.get("schema"), ",".join(d["databases"]), d["off"])' "$W/body"; }
s=$(st "$ID_pg_save"); [[ $s == "True pgvigil_saved $NOS,$OTH,$TDB " || $s == "True pgvigil_saved $NOS,$OTH,$TDB" ]] && ok "B: pg-save on, its databases without the templates" || bad "B: pg-save's state: $s"
s=$(st "$ID_ms_save"); [[ $s == "True pgvigil_saved NoSchemaDB,SaveDB"* ]] && ok "B: ms-save on, its databases without master" || bad "B: ms-save's state: $s"
s=$(st "$ID_pg_nolist"); [[ $s == "False None  off: this instance's actions: list does not name save_table" ]] && ok "B: pg-nolist off with the list's words" || bad "B: pg-nolist's state: $s"
c=$(post stop "$P1" "$ID_pg_save" pg.json)
[[ $c == 403 && $(said) == *"needs the admin role"* && $(rows) == 0 ]] && ok "B: an operator's POST 403 ($(said)), no row" || bad "B: an operator's POST: $c $(said); rows $(rows)"

# ---- C1 / D: PostgreSQL ------------------------------------------------------------------------------------------------
c=$(post stadmin "$P1" "$ID_pg_save" pg.json)
[[ $c == 200 && $(said) == "Saved 10003 rows to $TDB.pgvigil_saved.$HN; 1 NUL character(s) dropped from text cells" ]] && ok "C1: PostgreSQL: $(said)" || bad "C1: PostgreSQL: $c $(said)"
python3 - "$W" <<'PY' > "$W/rb_pg.sql"
t = '"pgvigil_saved"."x""y]z.w;--"'; c = '"txt ""q"" ]x"'
print(f"select count(*) from {t};")
print(f"select id || '|' || {c} || '|' || coalesce(to_char(amt, 'FM9999999990.0000000000'), 'NULL') || '|' || coalesce(to_char(w at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS'), 'NULL') || '|' || coalesce(d::text, 'NULL') || '|' || coalesce((flag::int)::text, 'NULL') || '|' || big from {t} where id <= 3 order by id;")
print(f"select 'sum_id ' || sum(id) || ' sum_big ' || sum(big) from {t};")
PY
psql "$PGVIGIL_ADMIN_DSN dbname=$TDB" -XAt -f "$W/rb_pg.sql" > "$W/got_pg.txt" 2>&1
if diff "$W/expect.txt" "$W/got_pg.txt" > "$W/diff_pg.txt"; then ok "C1: read back equal: 10,003 rows, the three hostile rows, the sums"; else bad "C1: read back differs: $(head -c 600 "$W/diff_pg.txt")"; fi
rel=$(adm "select string_agg(c.relname, ',') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil_saved' and c.relkind = 'r'" "$TDB")
dec=$(adm "select string_agg(a::text, ',' order by a) from public.t" "$TDB")
[[ $rel == "$HN" && $dec == "1,2" ]] && ok "C1: one relation in pgvigil_saved named exactly $rel; the decoy t untouched" || bad "C1: the relations '$rel', the decoy '$dec'"
c=$(post stadmin "$P1" "$ID_pg_save" pg.json)
n=$(adm "select count(*) from pgvigil_saved.\"x\"\"y]z.w;--\"" "$TDB")
[[ $c == 409 && $(said) == *"exists: pgvigil never overwrites a table"* && $n == 10003 ]] && ok "D: the same save again 409 ($(said)); still $n rows" || bad "D: again: $c $(said); rows $n"

# ---- C2 / J1: SQL Server -----------------------------------------------------------------------------------------------
c=$(post stadmin "$P1" "$ID_ms_save" ms.json)
[[ $c == 200 && $(said) == "Saved 10003 rows to SaveDB.pgvigil_saved.$HN; 1 NUL character(s) dropped from text cells" ]] && ok "C2: SQL Server: $(said)" || bad "C2: SQL Server: $c $(said)"
python3 - <<'PY' > "$W/rb_ms.sql"
t = '[pgvigil_saved].[x"y]]z.w;--]'; c = '[txt "q" ]]x]'
print("SET NOCOUNT ON;")
print(f"SELECT COUNT(*) FROM {t};")
print(f"SELECT CAST(id AS varchar(20)) + '|' + {c} + '|' + ISNULL(CONVERT(varchar(50), amt), 'NULL') + '|' + ISNULL(CONVERT(varchar(30), SWITCHOFFSET(w, '+00:00'), 126), 'NULL') + '|' + ISNULL(CONVERT(varchar(10), d, 23), 'NULL') + '|' + ISNULL(CAST(CAST(flag AS int) AS varchar(1)), 'NULL') + '|' + CAST(big AS varchar(20)) FROM {t} WHERE id <= 3 ORDER BY id;")
print(f"SELECT 'sum_id ' + CAST(SUM(CAST(id AS bigint)) AS varchar(30)) + ' sum_big ' + CAST(SUM(CAST(big AS decimal(38,0))) AS varchar(40)) FROM {t};")
print("GO")
PY
docker cp "$W/rb_ms.sql" "$CT:/tmp/rb_ms.sql" >/dev/null
docker exec --env-file "$W/sa.env" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -W -h -1 -d SaveDB -i /tmp/rb_ms.sql > "$W/got_ms.txt" 2>&1
if diff "$W/expect.txt" "$W/got_ms.txt" > "$W/diff_ms.txt"; then ok "C2: read back equal on SQL Server"; else bad "C2: read back differs: $(head -c 600 "$W/diff_ms.txt")"; fi
mk j1.json "$ID_ms_save" SaveDB dbo.Customers "ms-save-$SUF/SaveDB" 'b["rows"] = [[i, "j%d" % i, None, None, None, None, i] for i in (1, 2, 3)]'
c=$(post stadmin "$P1" "$ID_ms_save" j1.json)
j=$(sq "SELECT CAST((SELECT COUNT(*) FROM [pgvigil_saved].[dbo.Customers]) AS varchar) + ',' + CAST((SELECT COUNT(*) FROM [dbo].[Customers]) AS varchar) + ',' + CAST((SELECT COUNT(*) FROM [pgvigil_saved].[Customers]) AS varchar)" SaveDB 2>&1)
[[ $c == 200 && $j == "3,0,0" ]] && ok "J1: dbo.Customers landed in [pgvigil_saved].[dbo.Customers] (3), the decoys 0 / 0" || bad "J1: $c $(said); counts $j"

# ---- E: the refusals, one row each ---------------------------------------------------------------------------------------
refuse() {   # refuse <label> <instance id> <body file> <words>
  local r0 c; r0=$(rows); c=$(post stadmin "$P1" "$2" "$3")
  [[ $c == 409 && $(said) == *"$4"* && $(rows) == $((r0 + 1)) ]] && ok "E: $1: $(said)" || bad "E: $1: $c $(said); rows $r0 -> $(rows)"
}
small='b["rows"] = b["rows"][:3]'
mk e1.json "$ID_pg_nolist" "$TDB" e1 "pg-nolist-$SUF/$TDB" "$small"; refuse "pg-nolist" "$ID_pg_nolist" e1.json "list does not name save_table"
mk e2.json "$ID_pg_save" "$TDB" e2 "e2" "$small"; refuse "the table name typed" "$ID_pg_save" e2.json "typed confirmation is not pg-save-$SUF/$TDB"
mk e3.json "$ID_pg_save" template1 e3 "pg-save-$SUF/template1" "$small"; refuse "template1" "$ID_pg_save" e3.json "is a template"
mk e4.json "$ID_pg_save" "$NOS" e4 "pg-save-$SUF/$NOS" "$small"; refuse "no schema" "$ID_pg_save" e4.json "has no schema pgvigil_saved"
mk e5.json "$ID_pg_save" "$OTH" e5 "pg-save-$SUF/$OTH" "$small"; refuse "another login's schema" "$ID_pg_save" e5.json "owned by another login"
mk e6.json "$ID_pg_same" "$TDB" e6 "pg-same-$SUF/$TDB" "$small"; refuse "pg-same" "$ID_pg_same" e6.json "login of its own"
mk e7.json "$ID_pg_super" "$TDB" e7 "pg-super-$SUF/$TDB" "$small"; refuse "pg-super" "$ID_pg_super" e7.json "superuser"
mk e8.json "$ID_pg_save" "$TDB" e8 "pg-save-$SUF/$TDB" 'b["rows"] = [["s3cr3t-abc", "x", None, None, None, None, 1]]'; refuse "a value" "$ID_pg_save" e8.json "row 1, column id"
[[ $(said) != *s3cr3t* ]] && ok "E: the value's refusal does not hold the value" || bad "E: the value is in the words: $(said)"
mk e9.json "$ID_ms_save" SaveDB '#x' "ms-save-$SUF/SaveDB" "$small"; refuse "a '#' table" "$ID_ms_save" e9.json "#"
mk e10.json "$ID_ms_save" master e10 "ms-save-$SUF/master" "$small"; refuse "master" "$ID_ms_save" e10.json "system database"
mk e11.json "$ID_ms_save" NoSchemaDB e11 "ms-save-$SUF/NoSchemaDB" "$small"; refuse "no schema (SQL Server)" "$ID_ms_save" e11.json "has no schema pgvigil_saved"
mk e12.json "$ID_ms_sys" SaveDB e12 "ms-sys-$SUF/SaveDB" "$small"; refuse "ms-sys" "$ID_ms_sys" e12.json "sysadmin"

# ---- F: the body's limits ----------------------------------------------------------------------------------------------
python3 - "$W" "$ID_pg_save" "$TDB" "$SUF" <<'PY'
import json, sys, os
w, inst, db, suf = sys.argv[1:5]
with open(os.path.join(w, "big.json"), "w") as f:
    f.write(json.dumps({"instance_id": int(inst), "database": db, "table": "big", "from": "grid", "confirm": "x", "cols": [{"name": "t", "type": "text"}]})[:-1])
    f.write(', "rows": [' + ",".join(['["' + "x" * (1 << 20) + '"]'] * 40) + "]}")
PY
mk wide.json "$ID_ms_save" SaveDB wide "ms-save-$SUF/SaveDB" 'b["cols"] = [{"name": "c%d" % i, "type": "int"} for i in range(1025)]; b["rows"] = []'
r0=$(rows); c=$(post stadmin "$P1" "$ID_pg_save" big.json)
[[ $c == 413 && $(said) == *"over 32 MiB"* ]] && ok "F: a 40 MiB body 413: $(said)" || bad "F: the big body: $c $(said)"
c=$(post stadmin "$P1" "$ID_ms_save" wide.json)
[[ $c == 400 && $(said) == *1024* && $(rows) == "$r0" ]] && ok "F: 1,025 columns on SQL Server 400 ($(said)); no row for either" || bad "F: the wide body: $c $(said); rows $r0 -> $(rows)"

# ---- G: the audit ------------------------------------------------------------------------------------------------------
g=$(q "select string_agg(outcome || ':' || n, ' ' order by outcome) from (select outcome, count(*) n from pgvigil.actions_log where action = 'save_table' group by 1) x")
[[ $g == "done:3 refused:13 started:3" ]] && ok "G: $g" || bad "G: the outcomes $g (want done:3 refused:13 started:3)"
pairs=$(q "select string_agg(engine || '|' || outcome || '|' || coalesce(datname, '') || '|' || coalesce(target, '') || '|' || (pid is null)::text, ';' order by action_id)
            from pgvigil.actions_log where action = 'save_table' and outcome in ('started', 'done')")
want="postgres|started|$TDB|$TDB.pgvigil_saved.$HN|true;postgres|done|$TDB|$TDB.pgvigil_saved.$HN|true;sqlserver|started|SaveDB|SaveDB.pgvigil_saved.$HN|true;sqlserver|done|SaveDB|SaveDB.pgvigil_saved.$HN|true;sqlserver|started|SaveDB|SaveDB.pgvigil_saved.dbo.Customers|true;sqlserver|done|SaveDB|SaveDB.pgvigil_saved.dbo.Customers|true"
[[ $pairs == "$want" ]] && ok "G: the started / done pairs: engine, database, target, pid NULL" || bad "G: the pairs: $pairs"
[[ $(q "select count(*) from pgvigil.actions_log where detail like '%s3cr3t%'") == 0 ]] && ok "G: no row holds the refused value" || bad "G: a row holds the refused value"

# ---- J4: why the door login's own schema ---------------------------------------------------------------------------------
sq "CREATE TABLE dbo.victim (a int); GRANT ALTER ON SCHEMA::dbo TO msact;" SaveDB >/dev/null
a=$(docker exec -e SQLCMDPASSWORD="$MSPW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U msact -C -b -d SaveDB -Q "DROP TABLE dbo.victim" 2>&1; echo "rc=$?")
sq "REVOKE ALTER ON SCHEMA::dbo FROM msact; IF OBJECT_ID('dbo.victim') IS NULL CREATE TABLE dbo.victim (a int);" SaveDB >/dev/null
b=$(docker exec -e SQLCMDPASSWORD="$MSPW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U msact -C -b -d SaveDB -Q "DROP TABLE dbo.victim" 2>&1; echo "rc=$?")
c=$(docker exec -e SQLCMDPASSWORD="$MSPW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U msact -C -b -d SaveDB -Q "CREATE TABLE pgvigil_saved.j4 (i int)" 2>&1; echo "rc=$?")
[[ $a == *"rc=0" && $b == *3701* && $c == *"rc=0" ]] && ok "J4: with ALTER on dbo the actions login dropped dbo.victim; with its own schema only it cannot (3701) and creates pgvigil_saved.j4" \
  || bad "J4: with ALTER '$a'; without '$(echo "$b" | tail -2 | tr '\n' ' ')'; own schema '$c'"

# ---- K: review-31 part A2's rows (after G: its counts stand) -------------------------------------------------------------
last() { q "select coalesce(datname, '') || '|' || coalesce(target, '') || '|' || outcome from pgvigil.actions_log where action = 'save_table' order by action_id desc limit 1"; }
kref() {   # kref <label> <instance id> <body file> <words>: 409 with the words and ONE more audit row
  local r0 c; r0=$(rows); c=$(post stadmin "$P1" "$2" "$3")
  [[ $c == 409 && $(said) == *"$4"* && $(rows) == $((r0 + 1)) ]] && ok "$1: $(said)" || bad "$1: $c $(said); rows $r0 -> $(rows)"
}
# K1 (SF3): a refused name never reaches the audit row raw, and its refusal still writes its row
mk k1a.json "$ID_pg_save" "$TDB" k1a "x" 'b["database"] = "app\x00x"; b["rows"] = b["rows"][:3]'
kref "K1: a NUL in the database's name" "$ID_pg_save" k1a.json "control character"
[[ $(last) == "(a refused name)|(a refused name)|refused" ]] && ok "K1: its audit row names no name: $(last)" || bad "K1: the audit row: $(last)"
mk k1b.json "$ID_pg_save" "$TDB" k1b "pg-save-$SUF/$TDB" 'b["table"] = "a‮b"; b["rows"] = b["rows"][:3]'
kref "K1: U+202E in the table's name" "$ID_pg_save" k1b.json "invisible character"
[[ $(last) == "$TDB|(a refused name)|refused" ]] && ok "K1: its audit row: the database, no table name" || bad "K1: the audit row: $(last)"
# K2 (SF2): the database's owner (no superuser) sets its search_path and plants public.text
adm "create role $OWN login password '$PPW'" >/dev/null && adm "create database $SPD owner $OWN" >/dev/null || bad "K2 setup: the owner and his database"
psql "host=$HOST port=$PORT5 user=$OWN password=$PPW dbname=$SPD sslmode=disable" -XAtq -v ON_ERROR_STOP=1 \
  -c "alter database $SPD set search_path = public, pg_catalog" \
  -c "create function public.f(v pg_catalog.text) returns boolean language sql as \$\$ select current_user <> '$ACT' \$\$" \
  -c "create domain public.text as pg_catalog.text check (public.f(value))" > "$W/k2.log" 2>&1 || bad "K2 setup: the owner's search_path and domain: $(tail -2 "$W/k2.log")"
adm "create schema pgvigil_saved authorization $ACT" "$SPD" >/dev/null || bad "K2 setup: the schema"
q "insert into pgvigil.databases (instance_id, dbid, datname, snapshot_at, is_template, first_seen, is_present) values ($ID_pg_save, 6, '$SPD', now(), false, now(), true)" >/dev/null
mk k2.json "$ID_pg_save" "$SPD" k2 "pg-save-$SUF/$SPD" 'b["cols"] = [{"name": "t", "type": "text"}]; b["rows"] = [["one"], ["two"]]'
c=$(post stadmin "$P1" "$ID_pg_save" k2.json)
k=$(adm "select (a.atttypid = 'pg_catalog.text'::pg_catalog.regtype)::pg_catalog.text || ',' || (select count(*) from pgvigil_saved.k2) from pg_catalog.pg_attribute a where a.attrelid = 'pgvigil_saved.k2'::pg_catalog.regclass and a.attnum = 1" "$SPD" 2>&1)
[[ $c == 200 && $(said) == "Saved 2 rows to $SPD.pgvigil_saved.k2" && $k == "true,2" ]] && ok "K2: the owner's search_path and public.text: $(said); the column is pg_catalog.text" || bad "K2: $c $(said); the column and rows '$k'"
# K3 (NIT 5): the role's own read-only default
adm "alter role $ACT set default_transaction_read_only = on" >/dev/null
mk k3.json "$ID_pg_save" "$TDB" k3 "pg-save-$SUF/$TDB" 'b["rows"] = b["rows"][:2]'
c=$(post stadmin "$P1" "$ID_pg_save" k3.json)
[[ $c == 200 && $(said) == "Saved 2 rows to $TDB.pgvigil_saved.k3" ]] && ok "K3: the role's default_transaction_read_only = on: $(said)" || bad "K3: $c $(said)"
adm "alter role $ACT reset default_transaction_read_only" >/dev/null
# K4 (SF1): a database DDL trigger of a db_owner member
sq "CREATE DATABASE TrigDB; GRANT ALTER ANY CONNECTION TO msact;" >/dev/null || bad "K4 setup: TrigDB"
sq "CREATE USER msact FOR LOGIN msact; GRANT CREATE TABLE TO msact; EXEC ('CREATE SCHEMA pgvigil_saved AUTHORIZATION msact');
    CREATE USER msown FOR LOGIN msown; ALTER ROLE db_owner ADD MEMBER msown;
    CREATE TABLE dbo.probe_log (n int IDENTITY, orig sysname, usr sysname NULL, kill_perm int NULL); GRANT INSERT ON dbo.probe_log TO public;" TrigDB >/dev/null || bad "K4 setup: TrigDB's users"
# CREATE TRIGGER alone in its batch (sq puts SET NOCOUNT ON first), made by the db_owner member himself
t=$(docker exec -e SQLCMDPASSWORD="$MSPW" "$CT" /opt/mssql-tools18/bin/sqlcmd -S localhost -U msown -C -b -d TrigDB -Q "CREATE TRIGGER probe ON DATABASE FOR CREATE_TABLE AS INSERT dbo.probe_log (orig, usr, kill_perm) SELECT ORIGINAL_LOGIN(), USER_NAME(), HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY CONNECTION');" 2>&1; echo "rc=$?")
[[ $t == *"rc=0" && $(sq "SELECT COUNT(*) FROM sys.triggers WHERE parent_class = 0 AND is_disabled = 0" TrigDB) == 1 ]] || bad "K4 setup: the trigger: $t"
q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, snapshot_at, is_present) values ($ID_ms_save, 'TrigDB', $(sq "SELECT DB_ID('TrigDB')"), now(), true)" >/dev/null
mk k4.json "$ID_ms_save" TrigDB k4 "ms-save-$SUF/TrigDB" 'b["rows"] = b["rows"][:2]'
c=$(post stadmin "$P1" "$ID_ms_save" k4.json)
k=$(sq "SELECT CAST(COUNT(*) AS varchar(9)) + '|' + ISNULL(MIN(orig), '') + '|' + ISNULL(MIN(usr), '') + '|' + ISNULL(CAST(MIN(kill_perm) AS varchar(9)), '') + '|' + CAST((SELECT COUNT(*) FROM pgvigil_saved.k4) AS varchar(9)) FROM dbo.probe_log" TrigDB 2>&1)
[[ $c == 200 && $(said) == "Saved 2 rows to TrigDB.pgvigil_saved.k4" && $k == "1|msact|msact|0|2" ]] && ok "K4: a db_owner's DDL trigger ran once as the door's database user and found ALTER ANY CONNECTION = 0; $(said)" || bad "K4: $c $(said); the trigger's log (rows|login|user|ALTER ANY CONNECTION|rows saved) '$k'"
sq "REVOKE ALTER ANY CONNECTION FROM msact;" >/dev/null
# K5 (SF4): a distribution database
sq "DECLARE @s sysname = CAST(SERVERPROPERTY('ServerName') AS sysname); EXEC sp_adddistributor @distributor = @s, @password = N'$MSPW'; EXEC sp_adddistributiondb @database = N'distribution';" > "$W/k5.log" 2>&1
if [[ $(sq "SELECT CAST(is_distributor AS int) FROM sys.databases WHERE name = 'distribution'" 2>/dev/null) == 1 ]]; then
  sq "CREATE USER msact FOR LOGIN msact; GRANT CREATE TABLE TO msact; EXEC ('CREATE SCHEMA pgvigil_saved AUTHORIZATION msact');" distribution >/dev/null || bad "K5 setup: the schema in distribution"
  q "insert into pgvigil.mssql_database_option (instance_id, database_name, database_id, snapshot_at, is_present) values ($ID_ms_save, 'distribution', $(sq "SELECT DB_ID('distribution')"), now(), true)" >/dev/null
  mk k5.json "$ID_ms_save" distribution k5 "ms-save-$SUF/distribution" "$small"
  kref "K5: a distribution database" "$ID_ms_save" k5.json "replication distribution database"
  [[ $(sq "SELECT COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID('pgvigil_saved')" distribution) == 0 ]] && ok "K5: no table in distribution's pgvigil_saved" || bad "K5: a table was made in distribution"
else
  echo "NOT PROVEN K5: the container did not become a distributor ($(tail -2 "$W/k5.log" | tr '\n' ' ' | cut -c1-200)): the unit row TestCheckReadsThePlace holds the refusal"
fi
# K6 (NIT 6): an actions login in db_owner of the target
mk k6.json "$ID_ms_own" SaveDB k6 "ms-own-$SUF/SaveDB" "$small"
kref "K6: an actions login in db_owner" "$ID_ms_own" k6.json "db_owner"

echo "proof-savetable: $FAILS FAIL"
exit $(( FAILS > 0 ))
