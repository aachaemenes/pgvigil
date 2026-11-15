#!/usr/bin/env bash
# Proof of task 301c: the network rows and Win32PrioritySeparation on the Properties page (internal/mssql/properties.go,
# the collection mssql_properties; stored in pgvigil.mssql_property with its change log, migration 0084).
#
# Needs: docker (it starts and removes its own SQL Server 2022 and 2019 Developer containers), psql, a go toolchain at the
# repository root, and
#   PGVIGIL_REPO_DSN   a superuser connection to a PostgreSQL sandbox in KEYWORD form (host=... user=... dbname=...);
#                      the proof makes its own database there and drops it.
# Optional: PGVIGIL_BIN (default bin/pgvigil, built here when missing), PROOF_SKIP_2019=1 (N4 then prints NOT PROVEN).
# Nothing it did not make is touched; every container and the repository database go on every exit path.
#
# Expected (written before the first run; probes P1 and P2 of the report read the registry's answers first):
#  N1 SQL Server 2022 on Linux, the monitoring login (VIEW SERVER STATE; EXECUTE on xp_instance_regread is public's on
#     this image): tcp_port 1433 (= sa's xp_instance_regread of Tcp\IPAll TcpPort) with the note 'SQL Server on Linux:
#     mssql-conf network.tcpport, read through its registry', tcp_port_dynamic no, force_encryption no, protocols_enabled
#     'TCP/IP' with 'met: Linux serves TCP only', tcp_listen_all_ips 'not on Linux: mssql-conf network.ipaddress chooses
#     the address', win32_priority_separation 'not on Linux: a Windows scheduler setting'; force_strict_encryption
#     printed (P1 did not read it: 'no', or 'not read: xp_instance_regread holds no ForceStrictEncryption value');
#     power_plan 'not read: SQL Server on Linux has no Windows power plan ...'; the run neither failed nor partial.
#  N2 `mssql-conf set network.tcpport 1500` and `network.forceencryption 1`, the server restarted, the instance read
#     again at its new port: tcp_port 1500, force_encryption yes; mssql_property_change holds tcp_port 1433 -> 1500 and
#     force_encryption no -> yes for the instance.
#  N3 a login with VIEW SERVER STATE but DENY EXECUTE on xp_instance_regread: the six network rows say 'no right: GRANT
#     EXECUTE ON master.dbo.xp_instance_regread TO [pgvnet_deny]'; the run's output holds no error 229 (the procedure
#     was not called).
#  N4 SQL Server 2019 on Linux, a VIEW SERVER STATE login: tcp_port 1433, force_encryption no, force_strict_encryption
#     'not on this version: ForceStrictEncryption came with SQL Server 2022', protocols_enabled 'TCP/IP'.
#  NOT PROVEN HERE: Windows (sys.dm_server_registry's rows, the IPn entries with ListenOnAllIPs off, Shared Memory and
#  Named Pipes, Win32PrioritySeparation, the power plan's gate on a refused login): the unit tests TestNetworkRows and
#  TestPowerPlanGate hold the rules until the one queued read-only turn on dba-lab-win; Amazon RDS, Managed Instance and
#  Cloud SQL ('not applicable: <platform> runs the host': the unit tests).
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?a superuser keyword DSN of a PostgreSQL sandbox}"
SUF=$RANDOM; SQL=pgvnet-22-$SUF; SQL19=pgvnet-19-$SUF; REPO_DB=pgvigil_netproof_$SUF
WORK=$(mktemp -d); CFG=$WORK/pgvigil.yaml; OUT=$WORK/out
pw() { printf 'Pv9%s!a' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
SAPW=$(pw); PM=$(pw); PD=$(pw); export SQLCMDPASSWORD="$SAPW"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
notproven() { echo "NOT PROVEN: $*"; }
MADE_DB=
cleanup() {
  rc=$?; set +e
  docker rm -f -v "$SQL" "$SQL19" >/dev/null 2>&1
  [ -n "$MADE_DB" ] && psql "$PGVIGIL_REPO_DSN" -XAtqc "DROP DATABASE IF EXISTS $REPO_DB WITH (FORCE)" >/dev/null 2>&1
  rm -rf "$WORK"; echo "left: containers $(docker ps -aq --filter "name=pgvnet-.*-$SUF" | wc -l)"; exit $rc
}
trap cleanup EXIT

# sqlcmd as sa: the password from the environment, never on a command line; $2 the port inside the container
sqn() { docker exec -i -e SQLCMDPASSWORD "$1" /opt/mssql-tools18/bin/sqlcmd -S "localhost,${2:-1433}" -U sa -C -b -I -W -h -1 -s '|' -d master -i /dev/stdin; }
up() { for _ in $(seq 1 90); do [ "$(echo "SET NOCOUNT ON; SELECT CASE WHEN DATABASEPROPERTYEX('msdb','Status')='ONLINE' THEN 1 ELSE 0 END" | sqn "$1" "${2:-1433}" 2>/dev/null | tr -d '\r ')" = 1 ] && return 0; sleep 2; done; return 1; }
RDSN=$(printf '%s' "$PGVIGIL_REPO_DSN" | sed -E "s/dbname=[^ ]+/dbname=$REPO_DB/"); [[ "$RDSN" == *"dbname=$REPO_DB"* ]] || RDSN="$PGVIGIL_REPO_DSN dbname=$REPO_DB"
q() { psql "$RDSN" -XAtqc "$1"; }

echo "== containers"
printf 'ACCEPT_EULA=Y\nMSSQL_PID=Developer\nMSSQL_SA_PASSWORD=%s\n' "$SAPW" > "$WORK/sql.env"; chmod 600 "$WORK/sql.env"
docker run -d --name "$SQL" --label pgvigil-proof=inv301c --env-file "$WORK/sql.env" -p 127.0.0.1::1433 -p 127.0.0.1::1500 mcr.microsoft.com/mssql/server:2022-latest >/dev/null
[ -n "${PROOF_SKIP_2019:-}" ] || docker run -d --name "$SQL19" --label pgvigil-proof=inv301c --env-file "$WORK/sql.env" -p 127.0.0.1::1433 mcr.microsoft.com/mssql/server:2019-latest >/dev/null
up "$SQL" || fail "SQL Server 2022 did not come up"
logins() {
  sqn "$1" "${2:-1433}" >/dev/null <<SQL
CREATE LOGIN pgvnet_mon WITH PASSWORD = N'$PM', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvnet_mon; GRANT VIEW ANY DEFINITION TO pgvnet_mon;
CREATE LOGIN pgvnet_deny WITH PASSWORD = N'$PD', CHECK_POLICY = OFF; GRANT VIEW SERVER STATE TO pgvnet_deny;
CREATE USER pgvnet_deny FOR LOGIN pgvnet_deny; DENY EXECUTE ON master.dbo.xp_instance_regread TO pgvnet_deny;
SQL
}
logins "$SQL"
P22=$(docker port "$SQL" 1433/tcp | head -1 | sed 's/.*://'); P22B=$(docker port "$SQL" 1500/tcp | head -1 | sed 's/.*://')
psql "$PGVIGIL_REPO_DSN" -XAtqc "CREATE DATABASE $REPO_DB" >/dev/null; MADE_DB=1
dsn() { printf 'sqlserver://%s:%s@127.0.0.1:%s?database=master&encrypt=true&TrustServerCertificate=true' "$1" "$2" "$3"; }
export PGVIGIL_REPO_DSN_PROOF="$RDSN" MSSQL_M_DSN="$(dsn pgvnet_mon "$PM" "$P22")" MSSQL_D_DSN="$(dsn pgvnet_deny "$PD" "$P22")"
export MSSQL_19_DSN="$MSSQL_M_DSN"   # replaced below when the 2019 container runs (never read under PROOF_SKIP_2019)
if [ -z "${PROOF_SKIP_2019:-}" ]; then up "$SQL19" || fail "SQL Server 2019 did not come up"; logins "$SQL19"; MSSQL_19_DSN="$(dsn pgvnet_mon "$PM" "$(docker port "$SQL19" 1433/tcp | head -1 | sed 's/.*://')")"; fi
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN_PROOF
instances:
  - name: pgvnet-m
    engine: sqlserver
    dsn: env:MSSQL_M_DSN
  - name: pgvnet-d
    engine: sqlserver
    dsn: env:MSSQL_D_DSN
  - name: pgvnet-19
    engine: sqlserver
    dsn: env:MSSQL_19_DSN
EOF
[ -x "$BIN" ] || go build -o "$BIN" ./cmd/pgvigil
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once mssql_properties -instance "$1" > "$OUT" 2>&1 || { cat "$OUT"; return 1; }; }
# prop <instance> <key>: 'value|note' as stored
prop() { q "select coalesce(p.value, '') || '|' || coalesce(p.note, '') from pgvigil.mssql_property p join pgvigil.instances i using (instance_id) where i.name = '$1' and p.name = '$2'"; }
regread() { echo "SET NOCOUNT ON; DECLARE @v nvarchar(100); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\\Microsoft\\MSSQLServer\\MSSQLServer\\SuperSocketNetLib\\Tcp\\IPAll', N'TcpPort', @v OUTPUT; SELECT @v;" | sqn "$1" "${2:-1433}" | tr -d '\r '; }

echo "== N1 SQL Server 2022 on Linux, the monitoring login"
collect pgvnet-m || fail "N1: the read failed"
grep -q "partial\|skipped" "$OUT" && fail "N1: the read is partial or skipped: $(cat "$OUT")"
SAPORT=$(regread "$SQL")
[ "$(prop pgvnet-m tcp_port)" = "$SAPORT|SQL Server on Linux: mssql-conf network.tcpport, read through its registry" ] && [ "$SAPORT" = 1433 ] || fail "N1 tcp_port: $(prop pgvnet-m tcp_port) (sa reads $SAPORT)"
[ "$(prop pgvnet-m tcp_port_dynamic)" = "no|" ] || fail "N1 tcp_port_dynamic: $(prop pgvnet-m tcp_port_dynamic)"
[ "$(prop pgvnet-m force_encryption)" = "no|SQL Server on Linux: mssql-conf network.forceencryption, read through its registry" ] || fail "N1 force_encryption: $(prop pgvnet-m force_encryption)"
[ "$(prop pgvnet-m protocols_enabled)" = "TCP/IP|met: Linux serves TCP only" ] || fail "N1 protocols_enabled: $(prop pgvnet-m protocols_enabled)"
[ "$(prop pgvnet-m tcp_listen_all_ips)" = "|not on Linux: mssql-conf network.ipaddress chooses the address" ] || fail "N1 tcp_listen_all_ips: $(prop pgvnet-m tcp_listen_all_ips)"
[ "$(prop pgvnet-m win32_priority_separation)" = "|not on Linux: a Windows scheduler setting" ] || fail "N1 win32_priority_separation: $(prop pgvnet-m win32_priority_separation)"
[[ "$(prop pgvnet-m power_plan)" == "|not read: SQL Server on Linux has no Windows power plan"* ]] || fail "N1 power_plan: $(prop pgvnet-m power_plan)"
FSE=$(prop pgvnet-m force_strict_encryption)
case "$FSE" in "no|"|"|not read: xp_instance_regread holds no ForceStrictEncryption value") ;; *) fail "N1 force_strict_encryption: $FSE" ;; esac
ok "N1: tcp_port $SAPORT = sa's read, dynamic no, force_encryption no, protocols TCP/IP (met), listen and Win32PrioritySeparation 'not on Linux'; force_strict_encryption '$FSE'"

echo "== N2 mssql-conf: TCP port 1500 and forced encryption, a restart"
docker exec -u root "$SQL" /opt/mssql/bin/mssql-conf set network.tcpport 1500 >/dev/null 2>&1
docker exec -u root "$SQL" /opt/mssql/bin/mssql-conf set network.forceencryption 1 >/dev/null 2>&1
docker restart "$SQL" >/dev/null
up "$SQL" 1500 || fail "N2: SQL Server did not come back on 1500"
sleep 1; export MSSQL_M_DSN="$(dsn pgvnet_mon "$PM" "$P22B")"
collect pgvnet-m || fail "N2: the read at the new port failed"
[ "$(prop pgvnet-m tcp_port | cut -d'|' -f1)" = 1500 ] && [ "$(prop pgvnet-m force_encryption | cut -d'|' -f1)" = yes ] || fail "N2: tcp_port $(prop pgvnet-m tcp_port), force_encryption $(prop pgvnet-m force_encryption)"
CH=$(q "select string_agg(c.name || ':' || coalesce(c.old_value, '') || '>' || coalesce(c.new_value, ''), ',' order by c.name) from pgvigil.mssql_property_change c join pgvigil.instances i using (instance_id) where i.name = 'pgvnet-m' and c.name in ('tcp_port', 'force_encryption')")
[ "$CH" = "force_encryption:no>yes,tcp_port:1433>1500" ] || fail "N2: the change log holds '$CH'"
ok "N2: tcp_port 1500, force_encryption yes; the change log: $CH"

echo "== N3 a login denied EXECUTE on xp_instance_regread"
export MSSQL_D_DSN="$(dsn pgvnet_deny "$PD" "$P22B")"
collect pgvnet-d || fail "N3: the read failed"
grep -q "229\|EXECUTE permission was denied" "$OUT" && fail "N3: the procedure was called: $(cat "$OUT")"
NR="no right: GRANT EXECUTE ON master.dbo.xp_instance_regread TO [pgvnet_deny]"
for k in tcp_port tcp_port_dynamic tcp_listen_all_ips force_encryption force_strict_encryption protocols_enabled; do
  [ "$(prop pgvnet-d "$k")" = "|$NR" ] || fail "N3 $k: $(prop pgvnet-d "$k")"
done
ok "N3: the six network rows say '$NR'; no error 229 in the run"

echo "== N4 SQL Server 2019 on Linux"
if [ -n "${PROOF_SKIP_2019:-}" ]; then notproven "N4: PROOF_SKIP_2019"; else
  collect pgvnet-19 || fail "N4: the read failed"
  [ "$(prop pgvnet-19 tcp_port | cut -d'|' -f1)" = 1433 ] && [ "$(prop pgvnet-19 force_encryption | cut -d'|' -f1)" = no ] || fail "N4: tcp_port $(prop pgvnet-19 tcp_port), force_encryption $(prop pgvnet-19 force_encryption)"
  [ "$(prop pgvnet-19 force_strict_encryption)" = "|not on this version: ForceStrictEncryption came with SQL Server 2022" ] || fail "N4 force_strict_encryption: $(prop pgvnet-19 force_strict_encryption)"
  [ "$(prop pgvnet-19 protocols_enabled)" = "TCP/IP|met: Linux serves TCP only" ] || fail "N4 protocols_enabled: $(prop pgvnet-19 protocols_enabled)"
  ok "N4: SQL Server $(echo "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))" | sqn "$SQL19" | tr -d '\r '): tcp_port 1433, force_encryption no, strict 'not on this version', TCP/IP"
fi
notproven "Windows live (sys.dm_server_registry, the IPn entries, Shared Memory / Named Pipes, Win32PrioritySeparation, the power plan's gate): the unit tests until the queued read-only turn on dba-lab-win"
notproven "Amazon RDS, Managed Instance, Cloud SQL: 'not applicable' by the unit tests"
echo "ALL ROWS GREEN"
