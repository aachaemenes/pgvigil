#!/usr/bin/env bash
# Proof of SQL Server security checks (task 408, B15: migration 0159_mssql_security.sql, internal/mssql/security.go,
# internal/web/q_mssql_security.go) on a real SQL Server: every rule provoked on a container of its own, read, cleared
# and read again; the settings at the fleet, a tag and an instance; two lesser logins; and, for what a Linux container
# cannot show, imported rows. pgvigil is built from this tree; `collect -once` runs the collection as the service does.
#
# Needs: docker, go, psql, and
#   ADMIN_DSN    a superuser connection to a PostgreSQL in KEYWORD form (default 'host=127.0.0.1 port=5432 user=postgres
#                dbname=postgres'); the proof makes its own repository database there and drops it.
#   MSSQL_IMAGE  the SQL Server image (default mcr.microsoft.com/mssql/server:2022-latest)
#   PGVIGIL_PARTS  the parts to run (default MABCDE; a version pass runs MA only)
#   PGVIGIL_WIRING 1 (default) applies scripts/proof-mssql-security-wiring.patch (the join's lines in mssql.go, repo.go,
#                  web.go, router.ts, main.ts and 0190) to this copy first: the runner then asks the repository which
#                  parts to read; 0 runs without it (every part the login has the right for is read)
# The proof makes, and removes on every exit path, its repository database and one SQL Server container (its own, a
# throwaway sa password made here). Everything it changes on the server is inside that container.
#
# Expected (written before the first run):
#  M. migrate exits 0 and creates import_mssql_security, import_mssql_security_config, import_mssql_security_parts,
#     mssql_security_rule_state and mssql_security_findings; the rule catalogue holds 26 judged rules and 9 'not enabled'.
# Changed after the first green run (sqltb-s2-408-green1, without the wiring): E1's order (the findings sort by login
# name) and D's fleet row for proxy_public ended at D's end (E's findings had it); the wiring's lines (A0, A3, A6, C0)
# were written before the first wired run. The unwired path's A0 / A3 lines are the ones green1 passed.
#  A. as sa, after the proof plants: a database secdb (compatibility 120) owned by the SQL login sec_owner (CHECK_POLICY
#     off); in it a 1024-bit asymmetric key, a TRIPLE_DES symmetric key, a certificate expired 2020-01-01 (c_old) and one
#     expiring in 10 days (c_soon), the user of a login that is then dropped (sec_gone), guest's CONNECT; a contained
#     database seccdb with a password user; the sysadmin SQL login sec_sys (CHECK_EXPIRATION off, never signed in);
#     VIEW SERVER STATE granted to public. `collect -once mssql_checks` then `mssql_security` exit 0; every part 'read'.
#     A1 the logins stored = sa's hand count of sys.server_principals (S U G E X C K, no ##); A2 secdb's objects per
#     kind = sa's hand count; A3 the verdicts: hit - owner_allow 1, cert_expired 1 (critical: no use), cert_expiring 1,
#     orphaned_user 1, asym_key_size 1, sym_key_algorithm 1, guest_connect 1, contained_sql_auth 1, sa_exists 1,
#     sa_enabled 1, check_policy_off 1 (sec_owner), sysadmin_expiration_off 2 (sa and sec_sys), sysadmin_must_change 1
#     (sec_sys; sa holds the collector's session), public_server_perm 1, builtin_admin 1 (the Linux image has the login),
#     login_audit_all 1 (AuditLevel 2); ok - owner_deny, clr_not_safe, auth_scheme, windows_login_disabled,
#     windows_group_disabled, login_audit_failed, proxy_public, password_expiry; n/a - hide_instance and
#     local_windows_group (Linux); not enabled - the nine D5 rules. A4 the findings are exactly the five rules on by
#     default that hit: owner_allow, cert_expired (critical), cert_expiring, orphaned_user, sa_exists (info).
#     A5 import_mssql_security_parts asks for auth, logins and databases and leaves out proxies, registry, server_perms.
#     With the wiring those three parts are not read ('off') and their four rules say 'not read' (login_audit_failed,
#     login_audit_all, proxy_public, public_server_perm); without it every part is read and they say what A3 lists.
#     A6 (wired): login_audit_all, public_server_perm and proxy_public on at the fleet: the three parts read, the
#     verdicts login_audit_all hit 1, public_server_perm hit 1, proxy_public ok, login_audit_failed ok, and the two hits
#     findings (info, warning); the rows ended again.
#  B. cleared by sa (secdb back to sa, c_old and c_soon dropped, the orphaned user dropped) and read again: the findings
#     are sa_exists alone.
#  C. lesser logins (proxy_public on at the fleet for C, so the proxies part is asked for): sec_lp (VIEW SERVER STATE, VIEW ANY DEFINITION, a user in msdb) - logins and databases read,
#     proxies 'no right' naming GRANT SELECT ON msdb.dbo.sysproxies (P6 of the 13:38 probe); sec_bare (no right beyond
#     public) - logins 'no right' naming GRANT VIEW ANY DEFINITION, and orphaned_user 'not read' (pass F3).
#  D. the settings through import_mssql_security_config: rule:guest_connect on at the fleet makes it a finding; off at
#     the instance's tag secprod removes it (a tag beats the fleet); on at the instance brings it back (the instance beats
#     the tag); ending the instance row returns the tag's off. owner_allow ["sa","sec_owner"] at the instance with secdb
#     re-owned to sec_owner: no owner_allow hit. Refused, each with its log row: rule:nope, cert_warn_days 'abc',
#     pwd_crit_days 30 (over the warning's 20). rule:proxy_public on at the fleet makes the parts function ask for proxies.
#     A replaced row is ended and its successor names it (replaces). D's fleet rows are ended at its end.
#  E. imported rows (what a Linux container cannot show: P5 / P8 of the probe, NTLM, the Windows registry): an instance
#     sec-imported (not Linux, machine HOSTX) with SQL logins expiring in 15, 5, 0, -1 and NULL days (CHECK_EXPIRATION
#     on), the collector signed in with NTLM over TCP from 10.0.0.9, AuditLevel 0, HideInstance 0, a Windows group login
#     HOSTX\Admins and an Agent proxy granted to public. Findings: password_expiry warning (15), critical (5), critical
#     'has expired' (0), none for -1 and NULL; auth_scheme info. Off rules hit: login_audit_failed, login_audit_all,
#     hide_instance, local_windows_group, proxy_public.
set -u
PARTS=${PGVIGIL_PARTS:-MABCDE}
has() { case "$PARTS" in *"$1"*) return 0 ;; esac; return 1; }
SUF=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
ADMIN_DSN=${ADMIN_DSN:-host=127.0.0.1 port=5432 user=postgres dbname=postgres}
IMG=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
REPO_DB=pgvigil_sec_$SUF; SQL=pgv-sec-$SUF; TMPD=$(mktemp -d)
FAILS=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
die() { echo "FAIL (setup) $*"; exit 1; }
want() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1: got [$2], want [$3]"; fi; }
MADE_DB=
cleanup() {
  rc=$?
  docker rm -f "$SQL" >/dev/null 2>&1
  if [ -n "$MADE_DB" ]; then psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || echo "CLEANUP: database $REPO_DB not dropped"; fi
  rm -rf "$TMPD"
  exit $rc
}
trap cleanup EXIT

WIRED=0
if [ "${PGVIGIL_WIRING:-1}" = 1 ] && ! grep -q 'mssql/security' internal/web/web.go; then
  git apply scripts/proof-mssql-security-wiring.patch 2>/dev/null || patch -p1 < scripts/proof-mssql-security-wiring.patch >/dev/null || die "the wiring patch"
fi
grep -q 'mssql/security' internal/web/web.go && WIRED=1
echo "wiring: $WIRED"
go build -o "$TMPD/pgvigil" ./cmd/pgvigil || die "go build"
BIN=$TMPD/pgvigil
pw() { printf 'Ps9%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); LPW=$(pw)
# the sa password reaches sqlcmd through the environment, by name: never on a command line another user can list
export SQLCMDPASSWORD="$SAPW"
printf 'ACCEPT_EULA=Y\nMSSQL_SA_PASSWORD=%s\nMSSQL_MEMORY_LIMIT_MB=2048\n' "$SAPW" > "$TMPD/sa.env"
docker run -d --name "$SQL" --memory 3g --env-file "$TMPD/sa.env" -p 127.0.0.1::1433 "$IMG" >/dev/null || die "docker run $IMG"
PORT=$(docker port "$SQL" 1433 | head -1 | sed 's/.*://')
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
docker exec "$SQL" test -x "$SQLCMD" || SQLCMD=/opt/mssql-tools/bin/sqlcmd
sq() { docker exec -e SQLCMDPASSWORD "$SQL" $SQLCMD -S localhost -U sa -C -b -W -h -1 -d "${2:-master}" -Q "SET NOCOUNT ON; $1"; }
for _ in $(seq 1 90); do sq "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq "SELECT 1" >/dev/null 2>&1 || die "SQL Server did not answer"
echo "server: $(sq "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40))")"

psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" || die "the repository database"; MADE_DB=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
sq "CREATE LOGIN sec_lp WITH PASSWORD = '$LPW', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF; GRANT VIEW SERVER STATE TO sec_lp; GRANT VIEW ANY DEFINITION TO sec_lp; CREATE LOGIN sec_bare WITH PASSWORD = '$LPW', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;" || die "the lesser logins"
sq "CREATE USER sec_lp FOR LOGIN sec_lp;" msdb || die "sec_lp's msdb user"
export SEC_SA_DSN="sqlserver://sa:$SAPW@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
export SEC_LP_DSN="sqlserver://sec_lp:$LPW@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
export SEC_BARE_DSN="sqlserver://sec_bare:$LPW@127.0.0.1:$PORT?database=master&encrypt=true&TrustServerCertificate=true"
CFG=$TMPD/pgvigil.yaml
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: sec-sa
    engine: sqlserver
    dsn: env:SEC_SA_DSN
    tags: [secprod]
  - name: sec-lp
    engine: sqlserver
    dsn: env:SEC_LP_DSN
  - name: sec-bare
    engine: sqlserver
    dsn: env:SEC_BARE_DSN
EOF
collect() { "$BIN" collect -config "$CFG" -once "$1" -instance "$2" > "$TMPD/c.out" 2>&1 || bad "collect -once $1 on $2: $(tail -3 "$TMPD/c.out")"; }
iid() { q "select instance_id from pgvigil.instances where name = '$1'"; }
verdicts() { q "select string_agg(rule_key || '=' || verdict || CASE WHEN verdict = 'hit' THEN ':' || hits ELSE '' END, ' ' order by sort) from pgvigil.mssql_security_rule_state where instance_id = $1"; }
findings() { q "select coalesce(string_agg(check_name || '/' || severity, '; ' order by check_name, object), '') from pgvigil.mssql_security_findings where instance_id = $1"; }
cfg() { q "select pgvigil.import_mssql_security_config(now(), '$1'::jsonb)->>'outcome'"; }
base='"ui_user": "proof", "client": "127.0.0.1"'
endkey() { for k in "$@"; do for id in $(q "select config_id from pgvigil.mssql_security_config where scope = 'fleet' and key = '$k' and ended_at is null"); do cfg "{$base, \"op\": \"end\", \"config_id\": \"$id\"}" >/dev/null; done; done; }

if has M; then
  echo "--- M. the migration"
  "$BIN" migrate -config "$CFG" > "$TMPD/m.out" 2>&1 && pass "M1: migrate exit 0" || die "migrate: $(tail -3 "$TMPD/m.out")"
  want "M2: the objects exist" "$(q "select count(*) from pg_proc where proname in ('import_mssql_security', 'import_mssql_security_config', 'import_mssql_security_parts')")|$(q "select count(*) from pg_views where viewname in ('mssql_security_rule_state', 'mssql_security_findings')")" "3|2"
  want "M3: the rule catalogue" "$(q "select count(*) filter (where part is not null) || '|' || count(*) filter (where part is null) from pgvigil.mssql_security_rule_defs")" "26|9"
fi

if has A; then
  echo "--- A. as sa: every rule provoked"
  sq "CREATE LOGIN sec_owner WITH PASSWORD = '$LPW', CHECK_POLICY = OFF; CREATE LOGIN sec_sys WITH PASSWORD = '$LPW', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF; ALTER SERVER ROLE sysadmin ADD MEMBER sec_sys; CREATE LOGIN sec_gone WITH PASSWORD = '$LPW', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF; GRANT VIEW SERVER STATE TO public;" || die "A: the logins"
  sq "CREATE DATABASE secdb; ALTER DATABASE secdb SET COMPATIBILITY_LEVEL = 120; ALTER AUTHORIZATION ON DATABASE::secdb TO sec_owner;" || die "A: secdb"
  sq "CREATE USER sec_gone FOR LOGIN sec_gone; GRANT CONNECT TO guest;
      CREATE ASYMMETRIC KEY k1024 WITH ALGORITHM = RSA_1024 ENCRYPTION BY PASSWORD = N'Kx-1!long-enough-2026';
      CREATE SYMMETRIC KEY k3des WITH ALGORITHM = TRIPLE_DES ENCRYPTION BY PASSWORD = N'Kx-1!long-enough-2026';
      CREATE CERTIFICATE c_old ENCRYPTION BY PASSWORD = N'Kx-1!long-enough-2026' WITH SUBJECT = N'old', START_DATE = '20190101', EXPIRY_DATE = '20200101';
      DECLARE @d nvarchar(8) = CONVERT(nvarchar(8), DATEADD(day, 10, GETUTCDATE()), 112);
      EXEC (N'CREATE CERTIFICATE c_soon ENCRYPTION BY PASSWORD = N''Kx-1!long-enough-2026'' WITH SUBJECT = N''soon'', EXPIRY_DATE = ''' + @d + N'''');" secdb > /dev/null || die "A: secdb's objects"
  sq "DROP LOGIN sec_gone;" || die "A: drop sec_gone"
  sq "EXEC sp_configure 'contained database authentication', 1; RECONFIGURE; CREATE DATABASE seccdb CONTAINMENT = PARTIAL;" > /dev/null || die "A: seccdb"
  sq "CREATE USER sec_cu WITH PASSWORD = N'Cu-1!long-enough-2026';" seccdb || die "A: the contained user"
  collect mssql_checks sec-sa
  collect mssql_security sec-sa
  SA=$(iid sec-sa)
  if [ "$WIRED" = 1 ]; then A0="auth=read databases=read logins=read proxies=off registry=off server_perms=off"; else A0="auth=read databases=read logins=read proxies=read registry=read server_perms=read"; fi
  want "A0: the parts read" "$(q "select string_agg(part || '=' || status, ' ' order by part) from pgvigil.mssql_security_read where instance_id = $SA")" "$A0"
  want "A1: the logins equal sa's hand count" "$(q "select count(*) from pgvigil.mssql_security_logins where instance_id = $SA and is_present")" \
    "$(sq "SELECT COUNT(*) FROM sys.server_principals WHERE type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K') AND name NOT LIKE '##%##'")"
  HAND=$(sq "SELECT CONCAT((SELECT COUNT(*) FROM sys.database_principals WHERE type IN ('S','U','G','C','K','E','X') AND principal_id > 4), '|', (SELECT COUNT(*) FROM sys.certificates WHERE name NOT LIKE '##%##'), '|', (SELECT COUNT(*) FROM sys.asymmetric_keys WHERE name NOT LIKE '##%##'), '|', (SELECT COUNT(*) FROM sys.symmetric_keys WHERE name NOT LIKE '##%##' OR name = '##MS_DatabaseMasterKey##'), '|', (SELECT COUNT(*) FROM sys.database_permissions WHERE grantee_principal_id = 2 AND class = 0 AND permission_name = 'CONNECT' AND state IN ('G', 'W')))" secdb)
  want "A2: secdb's objects equal sa's hand count (users|certificates|asymmetric|symmetric|guest)" \
    "$(q "select count(*) filter (where object_kind = 'user') || '|' || count(*) filter (where object_kind = 'certificate') || '|' || count(*) filter (where object_kind = 'asym_key') || '|' || count(*) filter (where object_kind = 'sym_key') || '|' || count(*) filter (where object_kind = 'guest_connect') from pgvigil.mssql_security_db_objects where instance_id = $SA and database_name = 'secdb'")" "$HAND"
  if [ "$WIRED" = 1 ]; then GATED="login_audit_failed=not read login_audit_all=not read proxy_public=not read"; PSP="public_server_perm=not read"
  else GATED="login_audit_failed=ok login_audit_all=hit:1 proxy_public=ok"; PSP="public_server_perm=hit:1"; fi
  want "A3: the verdicts" "$(verdicts "$SA")" \
    "owner_allow=hit:1 owner_deny=ok cert_expired=hit:1 cert_expiring=hit:1 orphaned_user=hit:1 clr_not_safe=ok guest_connect=hit:1 asym_key_size=hit:1 sym_key_algorithm=hit:1 contained_sql_auth=hit:1 auth_scheme=ok sa_exists=hit:1 sa_enabled=hit:1 windows_login_disabled=ok windows_group_disabled=ok builtin_admin=hit:1 local_windows_group=n/a $GATED hide_instance=n/a check_policy_off=hit:1 sysadmin_expiration_off=hit:2 sysadmin_must_change=hit:1 $PSP password_expiry=ok ad_user_found=not enabled ad_password_expired=not enabled ad_locked=not enabled ad_enabled=not enabled ad_group_found=not enabled engine_service_admin=not enabled agent_service_admin=not enabled fulltext_service_admin=not enabled spn=not enabled"
  want "A4: the findings" "$(findings "$SA")" \
    "a certificate expires soon/warning; a certificate has expired/critical; a login named sa exists/info; an orphaned database user/warning; database owner not in the allow-list/warning"
  want "A5: the parts the rules in force need" "$(q "select pgvigil.import_mssql_security_parts($SA)::text")" \
    '{"parts": {"auth": true, "logins": true, "proxies": false, "registry": false, "databases": true, "server_perms": false}}'
  if [ "$WIRED" = 1 ]; then
    for k in login_audit_all public_server_perm proxy_public; do cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"rule:$k\", \"value\": \"on\"}" >/dev/null; done
    collect mssql_security sec-sa
    want "A6: the three parts read once their rules are on" "$(q "select string_agg(part || '=' || status, ' ' order by part) from pgvigil.mssql_security_read where instance_id = $SA and part in ('proxies', 'registry', 'server_perms')")" "proxies=read registry=read server_perms=read"
    want "A6: their verdicts" "$(q "select string_agg(rule_key || '=' || verdict || CASE WHEN verdict = 'hit' THEN ':' || hits ELSE '' END, ' ' order by sort) from pgvigil.mssql_security_rule_state where instance_id = $SA and rule_key in ('login_audit_failed', 'login_audit_all', 'proxy_public', 'public_server_perm')")" \
      "login_audit_failed=ok login_audit_all=hit:1 proxy_public=ok public_server_perm=hit:1"
    want "A6: their findings" "$(q "select string_agg(check_name || '/' || severity, '; ' order by check_name) from pgvigil.mssql_security_findings where instance_id = $SA and check_name in ('successful logins are not audited', 'public holds a server permission beyond the defaults')")" \
      "public holds a server permission beyond the defaults/warning; successful logins are not audited/info"
    endkey rule:login_audit_all rule:public_server_perm rule:proxy_public
  fi
fi

if has B; then
  echo "--- B. cleared and read again"
  sq "ALTER AUTHORIZATION ON DATABASE::secdb TO sa;" || bad "B: re-own secdb"
  sq "DROP CERTIFICATE c_old; DROP CERTIFICATE c_soon; DROP USER sec_gone;" secdb || bad "B: drop the certificates and the user"
  collect mssql_checks sec-sa
  collect mssql_security sec-sa
  want "B1: the findings after the clear" "$(findings "$(iid sec-sa)")" "a login named sa exists/info"
fi

if has C; then
  echo "--- C. lesser logins"
  cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"rule:proxy_public\", \"value\": \"on\"}" >/dev/null
  collect mssql_security sec-lp
  collect mssql_security sec-bare
  LP=$(iid sec-lp); BARE=$(iid sec-bare)
  want "C1: sec_lp reads the logins and the databases" "$(q "select string_agg(part || '=' || status, ' ' order by part) from pgvigil.mssql_security_read where instance_id = $LP and part in ('logins', 'databases')")" "databases=read logins=read"
  want "C2: sec_lp's proxies 'no right' with the grant" "$(q "select status || '|' || (note like 'GRANT SELECT ON msdb.dbo.sysproxies%')::text from pgvigil.mssql_security_read where instance_id = $LP and part = 'proxies'")" "no right|true"
  echo "  sec_lp's registry: $(q "select status || ' ' || coalesce(note, '') from pgvigil.mssql_security_read where instance_id = $LP and part = 'registry'") (the server's answer, written down)"
  want "C3: sec_bare's logins 'no right' with the grant" "$(q "select status || '|' || (note like 'GRANT VIEW ANY DEFINITION TO [sec_bare]%')::text from pgvigil.mssql_security_read where instance_id = $BARE and part = 'logins'")" "no right|true"
  want "C4: sec_bare's orphaned_user not read" "$(q "select verdict from pgvigil.mssql_security_rule_state where instance_id = $BARE and rule_key = 'orphaned_user'")" "not read"
  endkey rule:proxy_public
fi

if has D; then
  echo "--- D. the settings"
  SA=$(iid sec-sa)
  want "D1: guest_connect on at the fleet" "$(cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"rule:guest_connect\", \"value\": \"on\"}")|$(q "select count(*) from pgvigil.mssql_security_findings where instance_id = $SA and check_name = 'guest holds CONNECT in a user database'")" "done|1"
  want "D2: off at the tag secprod beats the fleet" "$(cfg "{$base, \"op\": \"add\", \"scope\": \"tag\", \"tag\": \"secprod\", \"key\": \"rule:guest_connect\", \"value\": \"off\"}")|$(q "select count(*) from pgvigil.mssql_security_findings where instance_id = $SA and check_name = 'guest holds CONNECT in a user database'")|$(q "select set_at from pgvigil.mssql_security_settings where instance_id = $SA and key = 'rule:guest_connect'")" "done|0|tag"
  want "D3: on at the instance beats the tag" "$(cfg "{$base, \"op\": \"add\", \"scope\": \"instance\", \"instance_name\": \"sec-sa\", \"key\": \"rule:guest_connect\", \"value\": \"on\"}")|$(q "select count(*) from pgvigil.mssql_security_findings where instance_id = $SA and check_name = 'guest holds CONNECT in a user database'")" "done|1"
  CID=$(q "select config_id from pgvigil.mssql_security_config where scope = 'instance' and key = 'rule:guest_connect' and ended_at is null")
  want "D4: ending the instance row returns the tag's off" "$(cfg "{$base, \"op\": \"end\", \"config_id\": \"$CID\"}")|$(q "select value || '/' || set_at from pgvigil.mssql_security_settings where instance_id = $SA and key = 'rule:guest_connect'")" "done|off/tag"
  sq "ALTER AUTHORIZATION ON DATABASE::secdb TO sec_owner;" || bad "D: re-own secdb"
  collect mssql_checks sec-sa
  want "D5: the allow-list at the instance" "$(cfg "{$base, \"op\": \"add\", \"scope\": \"instance\", \"instance_name\": \"sec-sa\", \"key\": \"owner_allow\", \"value\": \"[\\\"sa\\\", \\\"sec_owner\\\"]\"}")|$(q "select verdict from pgvigil.mssql_security_rule_state where instance_id = $SA and rule_key = 'owner_allow'")" "done|ok"
  want "D6: three refusals, each logged" "$(cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"rule:nope\", \"value\": \"on\"}") $(cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"cert_warn_days\", \"value\": \"abc\"}") $(cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"pwd_crit_days\", \"value\": \"30\"}")|$(q "select count(*) from pgvigil.mssql_security_config_log where outcome = 'refused'")" "refused refused refused|3"
  want "D7: proxy_public on at the fleet asks for the proxies part" "$(cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"rule:proxy_public\", \"value\": \"on\"}")|$(q "select (pgvigil.import_mssql_security_parts($SA)->'parts'->>'proxies')")" "done|true"
  cfg "{$base, \"op\": \"add\", \"scope\": \"fleet\", \"key\": \"rule:guest_connect\", \"value\": \"off\"}" >/dev/null
  want "D8: a replaced row is ended and named by its successor" "$(q "select count(*) from pgvigil.mssql_security_config n join pgvigil.mssql_security_config o on o.config_id = n.replaces where n.key = 'rule:guest_connect' and n.scope = 'fleet' and o.ended_at is not null and n.ended_at is null")" "1"
  endkey rule:guest_connect rule:proxy_public
fi

if has E; then
  echo "--- E. imported rows: what a Linux container cannot show"
  "$BIN" migrate -config "$CFG" >/dev/null 2>&1
  IMP=$(q "select pgvigil.ensure_instance('sec-imported', 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')")
  PAY='[{"kind": "context", "machine_name": "HOSTX", "login_name": "DOMAIN\\pgv", "linux": false, "view_any_definition": true, "alter_any_login": false, "view_server_state": true},
   {"kind": "part", "part": "logins", "status": "read"}, {"kind": "part", "part": "auth", "status": "read"},
   {"kind": "part", "part": "registry", "status": "read"}, {"kind": "part", "part": "proxies", "status": "read"},
   {"kind": "login", "login_name": "exp15", "login_type": "S", "is_disabled": 0, "is_expiration_checked": 1, "is_policy_checked": 1, "days_until_expiration": 15},
   {"kind": "login", "login_name": "exp5", "login_type": "S", "is_disabled": 0, "is_expiration_checked": 1, "is_policy_checked": 1, "days_until_expiration": 5},
   {"kind": "login", "login_name": "exp0", "login_type": "S", "is_disabled": 0, "is_expiration_checked": 1, "is_policy_checked": 1, "days_until_expiration": 0},
   {"kind": "login", "login_name": "never", "login_type": "S", "is_disabled": 0, "is_expiration_checked": 1, "is_policy_checked": 1, "days_until_expiration": -1},
   {"kind": "login", "login_name": "unknown", "login_type": "S", "is_disabled": 0, "is_expiration_checked": 1, "is_policy_checked": 1, "days_until_expiration": null},
   {"kind": "login", "login_name": "HOSTX\\Admins", "login_type": "G", "is_disabled": 0},
   {"kind": "auth_own", "auth_scheme": "NTLM", "net_transport": "TCP", "client_address": "10.0.0.9", "local_address": "10.0.0.5"},
   {"kind": "auth_count", "auth_scheme": "NTLM", "net_transport": "TCP", "connections": 7},
   {"kind": "registry", "value_name": "AuditLevel", "value": "0", "source": "sys.dm_server_registry"},
   {"kind": "registry", "value_name": "HideInstance", "value": "0", "source": "sys.dm_server_registry"},
   {"kind": "proxy", "proxy_name": "px", "enabled": 1, "credential_name": "cred", "public_granted": 1}]'
  q "select pgvigil.import_mssql_security($IMP, now(), \$p\$$PAY\$p\$::jsonb)" >/dev/null || bad "E: the import"
  want "E1: the findings" "$(findings "$IMP")" \
    "a SQL login's password expires soon/critical; a SQL login's password expires soon/warning; a SQL login's password expires soon/critical; the collector signed in with NTLM/info"
  want "E2: the expired one says so" "$(q "select detail from pgvigil.mssql_security_hits where instance_id = $IMP and object = 'exp0'")" "the password of the SQL login exp0 has expired"
  want "E3: the off rules see the rest" "$(q "select string_agg(rule_key, ' ' order by sort) from pgvigil.mssql_security_rule_state where instance_id = $IMP and verdict = 'hit' and not is_on")" \
    "local_windows_group login_audit_failed login_audit_all proxy_public hide_instance"
fi

if [ "$FAILS" = 0 ]; then echo "PROOF OK: proof-mssql-security ($PARTS)"; exit 0; fi
echo "PROOF FAILED: $FAILS check(s)"; exit 1
