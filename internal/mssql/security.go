package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// securityCollector is mssql_security (task 408, migration 0159): the security reads the server's own catalog gives -
// every login, public's server permissions, login auditing and HideInstance, how the collector itself signed in, the
// Agent proxies granted to msdb's public role - and, per database, its users, guest's CONNECT, user CLR assemblies,
// certificates with their expiry and use, and the key sizes and algorithms. Hourly; nothing is created or changed on
// the server. The rules (dbachecks 3.0.2's security checks, SQLMonitor's password-expiry notice) are judged in the
// repository (0159's mssql_security_rule_state), each on or off at the fleet, a tag or an instance: the collector reads
// what a rule in force needs and nothing else (a part every rule of which is off is not read).
//
// Rights, per part; a part the login may not read is skipped and its state row says so with the GRANT an admin would
// give (HAS_PERMS_BY_NAME before every object a refusal is likely on, so no read fails half-way):
//
//	logins        sys.server_principals - VIEW ANY DEFINITION (or ALTER ANY LOGIN); without it the server lists the
//	              login itself and the fixed roles only. 'Signed in now' (dbatools' LastLogin) needs VIEW SERVER STATE.
//	server_perms  sys.server_permissions for public - VIEW ANY DEFINITION.
//	registry      AuditLevel (login auditing) and HideInstance: sys.dm_server_registry (VIEW SERVER STATE) first on
//	              Windows, then master.dbo.xp_instance_regread (EXECUTE on it) for each value the DMV has no row for -
//	              in practice both: SQL Server 2022 on Windows (16.0.1000.6, read 2026-11-15) lists neither value in the
//	              DMV, so the EXECUTE right is what reads them on Windows as on Linux (where the DMV answers no rows).
//	              HideInstance does not apply on Linux.
//	auth          the collector's own connection through CONNECTIONPROPERTY (no right needed: sys.dm_exec_connections
//	              refuses even a login's own row without VIEW SERVER STATE); every connection by scheme and transport -
//	              VIEW SERVER STATE.
//	proxies       msdb.dbo.sysproxies and sysproxylogin - SELECT on both (a sysadmin, or a grant in msdb).
//	databases     each ONLINE database the login can enter (HAS_DBACCESS), not a snapshot or a local secondary
//	              replica; its principals, permissions, assemblies, certificates and keys are listed in full with
//	              VIEW ANY DEFINITION (else the database's VIEW DEFINITION). master's certificates are read too (a
//	              departure from dbachecks, which leaves master out: TDE's and backup encryption's certificates live
//	              there).
//
// The pass over the databases starts at a different database each hour and stops 10 seconds before the run's deadline,
// as reports.go does; a database not entered this run keeps its rows and is judged on them only for the rules that
// do not need an absence (0159: absence is judged per database read in that run). Azure SQL Database: the connected
// database's certificates, keys and guest's CONNECT only (its owner and user rules do not apply there).
type securityCollector struct{}

func init() { Register(securityCollector{}) }

func (securityCollector) Name() string                   { return Prefix + "security" }
func (securityCollector) DefaultInterval() time.Duration { return time.Hour }
func (securityCollector) Timeout() time.Duration         { return 3 * time.Minute }

func (securityCollector) Applies(_ Info) (bool, string) {
	return true, ""
}

// SecurityParts names the parts of the read; the repository says which are wanted (0159's
// import_mssql_security_parts(instance_id): a part every rule of which is off is not read).
var SecurityParts = []string{"logins", "server_perms", "registry", "auth", "proxies", "databases"}

// SettingsCollector is a collection whose reads depend on settings the repository holds (task 408): RunOnce asks the
// repository function SettingsFunc for the instance's settings (a JSON object) and calls RunWithSettings with them.
// The runner's branch and repo.MSSQLSettings are the join's wiring (scripts/proof-mssql-security-wiring.patch); until
// it is in, RunOnce calls Run, which reads every part the login has the right for.
type SettingsCollector interface {
	Collector
	SettingsFunc() string
	RunWithSettings(ctx context.Context, conn *sql.Conn, info Info, settings []byte) ([]collect.Row, error)
}

func (securityCollector) SettingsFunc() string { return "import_mssql_security_parts" }

func (c securityCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	return c.RunWithSettings(ctx, conn, info, nil)
}

// RunWithSettings reads the parts settings asks for: {"parts": {"logins": true, ...}}; nil or a part not named = read.
func (securityCollector) RunWithSettings(ctx context.Context, conn *sql.Conn, info Info, settings []byte) ([]collect.Row, error) {
	want := map[string]bool{}
	for _, p := range SecurityParts {
		want[p] = true
	}
	if len(settings) > 0 {
		var s struct {
			Parts map[string]bool `json:"parts"`
		}
		if err := json.Unmarshal(settings, &s); err != nil {
			return nil, fmt.Errorf("the security settings: %w", err)
		}
		for p, on := range s.Parts {
			if _, known := want[p]; known {
				want[p] = on
			}
		}
	}
	r := &secRun{ctx: ctx, conn: conn, info: info, want: want}
	return r.run()
}

type secRun struct {
	ctx  context.Context
	conn *sql.Conn
	info Info
	want map[string]bool
	out  []collect.Row
	ctxt secContext
}

// secContext is what the parts need to know about the server and the login, read once.
type secContext struct {
	Linux, VAD, AAL, VSS, VSSS, CanRegread, CanProxies, CanBackupset bool
	Login, Machine                                                   string
}

func (r *secRun) part(name, status, note string) {
	r.out = append(r.out, collect.Row{"kind": "part", "part": name, "status": status, "note": note})
	if status == "failed" {
		r.out = append(r.out, collect.Row{"kind": "collector_error", "source": name, "message": note})
	}
}

// read runs one query of a part; false = it failed (the part's state row says why).
func (r *secRun) read(part, query string, kind string, args ...any) ([]collect.Row, bool) {
	rows, err := QueryRows(r.ctx, r.conn, query, args...)
	if err != nil {
		r.part(part, "failed", "the read failed: "+err.Error())
		return nil, false
	}
	for _, row := range rows {
		row["kind"] = kind
	}
	return rows, true
}

const secContextSQL = `SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(256)) AS machine_name,
  CAST(SUSER_SNAME() AS nvarchar(256)) AS login_name,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION'), 0) AS int) AS vad,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY LOGIN'), 0) AS int) AS aal,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0) AS int) AS vss,
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER SECURITY STATE'), 0) AS int) AS vsss,
  CAST(ISNULL(HAS_PERMS_BY_NAME('msdb.dbo.backupset', 'OBJECT', 'SELECT'), 0) AS int) AS can_backupset,
  CAST(ISNULL(HAS_PERMS_BY_NAME('master.dbo.xp_instance_regread', 'OBJECT', 'EXECUTE'), 0) AS int) AS can_regread,
  CAST(CASE WHEN ISNULL(HAS_PERMS_BY_NAME('msdb.dbo.sysproxies', 'OBJECT', 'SELECT'), 0) = 1
             AND ISNULL(HAS_PERMS_BY_NAME('msdb.dbo.sysproxylogin', 'OBJECT', 'SELECT'), 0) = 1 THEN 1 ELSE 0 END AS int) AS can_proxies`

// the host's platform: sys.dm_os_host_info is SQL Server 2017's; a server without it is Windows
const secHostSQL = `SELECT CAST(host_platform AS nvarchar(256)) AS host_platform FROM sys.dm_os_host_info`

func (r *secRun) run() ([]collect.Row, error) {
	ctxRows, err := QueryRows(r.ctx, r.conn, secContextSQL)
	if err != nil || len(ctxRows) == 0 {
		if err == nil {
			err = fmt.Errorf("no row")
		}
		return nil, fmt.Errorf("the login's rights: %w", err)
	}
	c := ctxRows[0]
	r.ctxt = secContext{VAD: secFlag(c["vad"]), AAL: secFlag(c["aal"]), VSS: secFlag(c["vss"]), VSSS: secFlag(c["vsss"]),
		CanRegread: secFlag(c["can_regread"]), CanProxies: secFlag(c["can_proxies"]), CanBackupset: secFlag(c["can_backupset"])}
	r.ctxt.Login, _ = c["login_name"].(string)
	r.ctxt.Machine, _ = c["machine_name"].(string)
	if r.info.Kind != KindAzureDB {
		if h, err := QueryRows(r.ctx, r.conn, secHostSQL); err == nil && len(h) == 1 {
			p, _ := h[0]["host_platform"].(string)
			r.ctxt.Linux = strings.EqualFold(p, "Linux")
		}
	}
	r.out = append(r.out, collect.Row{"kind": "context", "machine_name": r.ctxt.Machine, "login_name": r.ctxt.Login,
		"linux": r.ctxt.Linux, "view_any_definition": r.ctxt.VAD, "alter_any_login": r.ctxt.AAL, "view_server_state": r.ctxt.VSS})

	if r.info.Kind == KindAzureDB {
		for _, p := range []string{"logins", "server_perms", "registry", "proxies"} {
			r.part(p, "n/a", "not on Azure SQL Database (no server principals, registry or msdb of its own)")
		}
		r.auth()
		r.databases()
		return r.out, nil
	}
	r.logins()
	r.serverPerms()
	r.registry()
	r.auth()
	r.proxies()
	r.databases()
	return r.out, nil
}

func secFlag(v any) bool { n, _ := asInt(v); return n == 1 }

// skip says a part is not read because every rule it serves is off; true = skipped.
func (r *secRun) skip(part string) bool {
	if r.want[part] {
		return false
	}
	r.part(part, "off", "every rule this part serves is off for this instance: not read")
	return true
}

const secLoginsSQL = `SELECT CAST(p.name AS nvarchar(256)) AS login_name, CAST(p.type AS nvarchar(2)) AS login_type,
  CAST(p.principal_id AS int) AS principal_id, CAST(CASE WHEN p.sid = 0x01 THEN 1 ELSE 0 END AS int) AS is_original_sa,
  CAST(p.is_disabled AS int) AS is_disabled, %s AS created_utc, %s AS modified_utc,
  CAST(CASE WHEN p.type = 'S' THEN LOGINPROPERTY(p.name, 'IsMustChange') END AS int) AS must_change,
  CAST(CASE WHEN p.type = 'S' THEN LOGINPROPERTY(p.name, 'DaysUntilExpiration') END AS int) AS days_until_expiration,
  CAST(l.is_policy_checked AS int) AS is_policy_checked, CAST(l.is_expiration_checked AS int) AS is_expiration_checked,
  CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.server_role_members rm JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
                          WHERE r.name = N'sysadmin' AND rm.member_principal_id = p.principal_id) THEN 1 ELSE 0 END AS int) AS is_sysadmin,
  CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.server_role_members rm JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
                          WHERE r.name = N'setupadmin' AND rm.member_principal_id = p.principal_id)
             AND EXISTS (SELECT 1 FROM sys.server_role_members rm JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
                          WHERE r.name = N'processadmin' AND rm.member_principal_id = p.principal_id) THEN 1 ELSE 0 END AS int) AS rds_master_roles,
  %s AS has_session
FROM sys.server_principals p
LEFT JOIN sys.sql_logins l ON l.principal_id = p.principal_id
WHERE p.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K') AND p.name NOT LIKE N'##%%##'`

func (r *secRun) logins() {
	if r.skip("logins") {
		return
	}
	if !r.ctxt.VAD && !r.ctxt.AAL {
		r.part("logins", "no right", fmt.Sprintf("GRANT VIEW ANY DEFINITION TO [%s]: without it the server lists this login and the fixed roles only", r.ctxt.Login))
		return
	}
	session := "CAST(NULL AS int)"
	if r.ctxt.VSS {
		session = "CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.dm_exec_sessions s WHERE s.login_name = p.name) THEN 1 ELSE 0 END AS int)"
	}
	rows, ok := r.read("logins", fmt.Sprintf(secLoginsSQL, utcText("p.create_date"), utcText("p.modify_date"), session), "login")
	if !ok {
		return
	}
	r.out = append(r.out, rows...)
	note := ""
	if !r.ctxt.VSS {
		note = fmt.Sprintf("'signed in now' not read: GRANT VIEW SERVER STATE TO [%s]", r.ctxt.Login)
	}
	r.part("logins", "read", note)
}

// public's server permissions; the rule (0159) leaves out dbachecks' defaults: VIEW ANY DATABASE and CONNECT on the
// four default T-SQL endpoints (major_id 2-5, Instance.Assertions.ps1's PublicRolePermission query)
const secServerPermsSQL = `SELECT CAST(sp.class_desc AS nvarchar(60)) AS class_desc, CAST(sp.permission_name AS nvarchar(128)) AS permission_name,
  CAST(sp.state_desc AS nvarchar(60)) AS state_desc, CAST(sp.major_id AS int) AS major_id,
  CAST(CASE WHEN sp.class = 105 THEN e.name WHEN sp.class = 101 THEN pr.name END AS nvarchar(256)) AS object_name
FROM sys.server_permissions sp
LEFT JOIN sys.endpoints e ON sp.class = 105 AND e.endpoint_id = sp.major_id
LEFT JOIN sys.server_principals pr ON sp.class = 101 AND pr.principal_id = sp.major_id
WHERE sp.grantee_principal_id = 2`

func (r *secRun) serverPerms() {
	if r.skip("server_perms") {
		return
	}
	if !r.ctxt.VAD {
		r.part("server_perms", "no right", fmt.Sprintf("GRANT VIEW ANY DEFINITION TO [%s]: sys.server_permissions lists only what the login may see", r.ctxt.Login))
		return
	}
	rows, ok := r.read("server_perms", secServerPermsSQL, "server_perm")
	if !ok {
		return
	}
	r.out = append(r.out, rows...)
	r.part("server_perms", "read", "")
}

const secRegistryDMV = `SELECT CAST(value_name AS nvarchar(128)) AS value_name, CAST(value_data AS nvarchar(256)) AS value_data,
  CAST(registry_key AS nvarchar(512)) AS registry_key
FROM sys.dm_server_registry WHERE value_name IN (N'AuditLevel', N'HideInstance')`

// xp_instance_regread maps Software\Microsoft\MSSQLServer to the instance's own key; its return code is the only
// failure signal (an xp_ failure is a message, not an error a TRY / CATCH sees): NULL or non-zero = not read.
const secRegreadSQL = `DECLARE @rc int, @v int;
EXEC @rc = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'%s', N'%s', @v OUTPUT;
SELECT @rc AS rc, @v AS value;`

var secRegistryKeys = map[string]string{
	"AuditLevel":   `Software\Microsoft\MSSQLServer\MSSQLServer`,
	"HideInstance": `Software\Microsoft\MSSQLServer\MSSQLServer\SuperSocketNetLib`,
}

// secRegreadOff: why the security read does not call xp_instance_regread on this platform ("" = it may): the same
// platforms the rights page lists registry_instance as not applying to (hostOnly).
func secRegreadOff(_ Info) string { return "" }

func (r *secRun) registry() {
	if r.skip("registry") {
		return
	}
	names := []string{"AuditLevel", "HideInstance"}
	if r.ctxt.Linux {
		names = []string{"AuditLevel"} // HideInstance is SQL Server Browser's, which Linux does not have
	}
	got := map[string]string{}
	var notes []string
	if !r.ctxt.Linux && r.ctxt.VSS {
		if rows, err := QueryRows(r.ctx, r.conn, secRegistryDMV); err == nil {
			for _, row := range rows {
				n, _ := row["value_name"].(string)
				v, _ := row["value_data"].(string)
				if n != "" {
					got[n] = v
				}
			}
		} else {
			notes = append(notes, "sys.dm_server_registry: "+err.Error())
		}
	}
	for _, n := range names {
		if _, ok := got[n]; ok {
			r.out = append(r.out, collect.Row{"kind": "registry", "value_name": n, "value": got[n], "source": "sys.dm_server_registry"})
			continue
		}
		if !r.ctxt.CanRegread {
			notes = append(notes, fmt.Sprintf("%s not read: GRANT EXECUTE ON master.dbo.xp_instance_regread TO [%s]", n, r.ctxt.Login))
			continue
		}
		rows, err := QueryRows(r.ctx, r.conn, fmt.Sprintf(secRegreadSQL, secRegistryKeys[n], n))
		if err != nil || len(rows) == 0 {
			why := "no answer"
			if err != nil {
				why = err.Error()
			}
			notes = append(notes, fmt.Sprintf("%s not read: xp_instance_regread: %s", n, why))
			continue
		}
		rc, rcOK := asInt(rows[0]["rc"])
		if !rcOK || rc != 0 {
			notes = append(notes, fmt.Sprintf("%s not read: xp_instance_regread answered %v", n, rows[0]["rc"]))
			continue
		}
		val := ""
		if v, ok := asInt(rows[0]["value"]); ok {
			val = fmt.Sprint(v)
		}
		r.out = append(r.out, collect.Row{"kind": "registry", "value_name": n, "value": nilIfEmptyStr(val), "source": "xp_instance_regread"})
	}
	if r.ctxt.Linux {
		r.out = append(r.out, collect.Row{"kind": "registry_na", "value_name": "HideInstance", "note": "not on Linux (no SQL Server Browser)"})
	}
	// read when at least one value was; else 'no right' when a missing right is why, 'failed' otherwise
	status := "read"
	if len(notes) >= len(names) {
		status = "failed"
		if !r.ctxt.CanRegread {
			status = "no right"
		}
	}
	r.part("registry", status, strings.Join(notes, "; "))
}

func nilIfEmptyStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

const secAuthOwnSQL = `SELECT CAST(CONNECTIONPROPERTY('auth_scheme') AS nvarchar(40)) AS auth_scheme,
  CAST(CONNECTIONPROPERTY('net_transport') AS nvarchar(40)) AS net_transport,
  CAST(CONNECTIONPROPERTY('client_net_address') AS nvarchar(48)) AS client_address,
  CAST(CONNECTIONPROPERTY('local_net_address') AS nvarchar(48)) AS local_address`

const secAuthAllSQL = `SELECT CAST(c.auth_scheme AS nvarchar(40)) AS auth_scheme, CAST(c.net_transport AS nvarchar(40)) AS net_transport,
  CAST(COUNT(*) AS int) AS connections
FROM sys.dm_exec_connections c GROUP BY c.auth_scheme, c.net_transport`

func (r *secRun) auth() {
	if r.skip("auth") {
		return
	}
	rows, ok := r.read("auth", secAuthOwnSQL, "auth_own")
	if !ok {
		return
	}
	r.out = append(r.out, rows...)
	note := ""
	if r.ctxt.VSS && r.info.Kind != KindAzureDB {
		all, ok := r.read("auth", secAuthAllSQL, "auth_count")
		if !ok {
			return
		}
		r.out = append(r.out, all...)
	} else if r.info.Kind != KindAzureDB {
		note = fmt.Sprintf("the server's connections by scheme not read: GRANT VIEW SERVER STATE TO [%s]", r.ctxt.Login)
	}
	r.part("auth", "read", note)
}

// a proxy and whether msdb's public role may use it (sysproxylogin flags 2 = an msdb role, its sid the role's)
const secProxiesSQL = `SELECT CAST(p.name AS nvarchar(256)) AS proxy_name, CAST(p.enabled AS int) AS enabled,
  CAST(c.name AS nvarchar(256)) AS credential_name,
  CAST(CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysproxylogin pl JOIN msdb.sys.database_principals dp ON dp.sid = pl.sid
                          WHERE pl.proxy_id = p.proxy_id AND pl.flags = 2 AND dp.name = N'public') THEN 1 ELSE 0 END AS int) AS public_granted
FROM msdb.dbo.sysproxies p
LEFT JOIN sys.credentials c ON c.credential_id = p.credential_id`

func (r *secRun) proxies() {
	if r.skip("proxies") {
		return
	}
	if !r.ctxt.CanProxies {
		r.part("proxies", "no right", fmt.Sprintf("GRANT SELECT ON msdb.dbo.sysproxies and msdb.dbo.sysproxylogin TO [%s] (a user in msdb): a non-sysadmin is refused them", r.ctxt.Login))
		return
	}
	rows, ok := r.read("proxies", secProxiesSQL, "proxy")
	if !ok {
		return
	}
	r.out = append(r.out, rows...)
	r.part("proxies", "read", "")
}

// the databases: every one the server lists (the import marks a database no longer listed as gone) and whether the
// pass enters it; QUOTENAME on the server makes the name safe inside the EXEC below
const secDatabasesFmt = `SELECT CAST(d.name AS nvarchar(256)) AS name, QUOTENAME(d.name) AS quoted, CAST(d.database_id AS int) AS database_id,
  CAST(d.containment AS int) AS containment,
  CASE WHEN d.state = 0 AND d.database_id <> 2 AND d.source_database_id IS NULL AND HAS_DBACCESS(d.name) = 1 AND %s = 0 THEN 1 ELSE 0 END AS can_enter
FROM sys.databases d
WHERE d.database_id <> 2
ORDER BY d.name`

// secDatabaseSQL: one database's security objects in one statement through its own sp_executesql (%[1]s the
// database's quoted name and a dot, or nothing for the connected database; %[2]s whether a login has the user's SID).
// One kind per branch, the columns shared: users (with whether a login has their SID and whether they hold CONNECT), guest's
// CONNECT, user CLR assemblies, certificates (their use found in master by thumbprint: TDE, backup encryption, an
// endpoint), asymmetric and symmetric keys. ##-named system objects (users too) are left out but ##MS_DatabaseMasterKey##.
const secDatabaseSQL = `EXEC %[1]ssys.sp_executesql N'
SELECT N''user'' AS object_kind, CAST(dp.name AS nvarchar(256)) AS object_name, CAST(dp.type AS nvarchar(4)) AS object_type,
  CAST(dp.authentication_type AS int) AS num1, CAST(DATALENGTH(dp.sid) AS int) AS num2, CAST(dp.principal_id AS int) AS num3,
  CAST(%[2]s AS int) AS flag1,
  CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.database_permissions pe WHERE pe.grantee_principal_id = dp.principal_id
          AND pe.class = 0 AND pe.permission_name = N''CONNECT'' AND pe.state IN (''G'', ''W'')) THEN 1 ELSE 0 END AS int) AS flag2,
  CAST(NULL AS nvarchar(256)) AS text1, CAST(NULL AS nvarchar(256)) AS text2, CAST(NULL AS varchar(40)) AS at_utc
FROM sys.database_principals dp
WHERE dp.type IN (''S'', ''U'', ''G'', ''C'', ''K'', ''E'', ''X'') AND dp.principal_id > 4 AND dp.name NOT LIKE N''##%%##''
UNION ALL
SELECT N''guest_connect'', N''guest'', NULL, NULL, NULL, NULL, NULL, NULL, CAST(pe.state_desc AS nvarchar(256)), NULL, NULL
FROM sys.database_permissions pe
WHERE pe.grantee_principal_id = 2 AND pe.class = 0 AND pe.permission_name = N''CONNECT'' AND pe.state IN (''G'', ''W'')
UNION ALL
SELECT N''assembly'', CAST(a.name AS nvarchar(256)), NULL, NULL, NULL, NULL, CAST(a.is_user_defined AS int), NULL,
  CAST(a.permission_set_desc AS nvarchar(256)), NULL, NULL
FROM sys.assemblies a WHERE a.is_user_defined = 1
UNION ALL
SELECT N''certificate'', CAST(c.name AS nvarchar(256)), NULL, NULL, NULL, NULL, NULL, NULL,
  CAST(c.pvt_key_encryption_type_desc AS nvarchar(256)), CONVERT(nvarchar(256), c.thumbprint, 1),
  CONVERT(varchar(33), c.expiry_date, 126) + ''Z''
FROM sys.certificates c WHERE c.name NOT LIKE N''##%%##''
UNION ALL
SELECT N''asym_key'', CAST(k.name AS nvarchar(256)), NULL, CAST(k.key_length AS int), NULL, NULL, NULL, NULL,
  CAST(k.algorithm_desc AS nvarchar(256)), NULL, NULL
FROM sys.asymmetric_keys k WHERE k.name NOT LIKE N''##%%##''
UNION ALL
SELECT N''sym_key'', CAST(k.name AS nvarchar(256)), NULL, CAST(k.key_length AS int), NULL, NULL, NULL, NULL,
  CAST(k.algorithm_desc AS nvarchar(256)), NULL, NULL
FROM sys.symmetric_keys k WHERE k.name NOT LIKE N''##%%##'' OR k.name = N''##MS_DatabaseMasterKey##'''`

// secHasLogin: whether a server principal has the database user's SID (an orphaned user has none)
const secHasLogin = `CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals sp WHERE sp.sid = dp.sid) THEN 1 ELSE 0 END`

func (r *secRun) dbName() (string, error) {
	var n string
	err := r.conn.QueryRowContext(r.ctx, `SELECT CAST(DB_NAME() AS nvarchar(256))`).Scan(&n)
	return n, err
}

// a certificate's use, read in master by thumbprint: a database encryption key's encryptor (TDE), a backup encrypted
// with it in the last 90 days, a mirroring / availability group or Service Broker endpoint's certificate. Each test
// runs only with its own right (certUseSQL): one the login lacks is NULL (not read), never a refused statement.
const secCertUseSQL = `SELECT CONVERT(nvarchar(256), c.thumbprint, 1) AS thumbprint,
  CAST(%s AS int) AS tde,
  CAST(%s AS int) AS backup_encryptor,
  CAST(%s AS int) AS mirroring_endpoint,
  CAST(%s AS int) AS broker_endpoint
FROM master.sys.certificates c WHERE c.name NOT LIKE N'##%%##'`

// certUseSQL is secCertUseSQL with each test the login has the right for, and the rights it lacks (for the part's
// note): sys.dm_database_encryption_keys needs VIEW SERVER STATE (VIEW SERVER SECURITY STATE on 2022), msdb's backupset
// SELECT on it, and the endpoints' catalog views show every endpoint only with VIEW ANY DEFINITION.
func (r *secRun) certUseSQL() (string, []string) {
	tde, backup, mirroring, broker := "NULL", "NULL", "NULL", "NULL"
	var missing []string
	if r.ctxt.VSS || r.ctxt.VSSS {
		tde = `CASE WHEN EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys k WHERE k.encryptor_thumbprint = c.thumbprint) THEN 1 ELSE 0 END`
	} else {
		missing = append(missing, "TDE: GRANT VIEW SERVER STATE")
	}
	if r.ctxt.CanBackupset {
		backup = `CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.backupset b WHERE b.encryptor_thumbprint = c.thumbprint AND b.backup_finish_date > DATEADD(day, -90, GETDATE())) THEN 1 ELSE 0 END`
	} else {
		missing = append(missing, "backup encryption: GRANT SELECT ON msdb.dbo.backupset")
	}
	if r.ctxt.VAD {
		mirroring = `CASE WHEN EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints e WHERE e.certificate_id = c.certificate_id) THEN 1 ELSE 0 END`
		broker = `CASE WHEN EXISTS (SELECT 1 FROM sys.service_broker_endpoints e WHERE e.certificate_id = c.certificate_id) THEN 1 ELSE 0 END`
	} else {
		missing = append(missing, "endpoints: GRANT VIEW ANY DEFINITION")
	}
	return fmt.Sprintf(secCertUseSQL, tde, backup, mirroring, broker), missing
}

func (r *secRun) databases() {
	if r.skip("databases") {
		return
	}
	if r.info.Kind == KindAzureDB {
		// the connected database alone: its certificates, keys, assemblies and guest's CONNECT; its users are listed
		// without a login test (a logical server's logins are not readable from a user database), and the owner and
		// user rules do not judge them (0159)
		rows, ok := r.read("databases", fmt.Sprintf(secDatabaseSQL, "", "NULL"), "dbobject")
		if !ok {
			return
		}
		name, _ := r.dbName()
		r.out = append(r.out, collect.Row{"kind": "database", "database_name": name, "entered": true},
			collect.Row{"kind": "dbread", "database_name": name})
		for _, o := range rows {
			o["database_name"] = name
		}
		r.out = append(r.out, rows...)
		r.part("databases", "read", "Azure SQL Database: the connected database only; its owner and user rules do not apply")
		return
	}
	local := "0"
	if r.info.HADREnabled {
		local = userDBLocalSecondary
	}
	dbs, err := QueryRows(r.ctx, r.conn, fmt.Sprintf(secDatabasesFmt, local))
	if err != nil {
		r.part("databases", "failed", "the database list failed: "+err.Error())
		return
	}
	var enter []collect.Row
	for _, db := range dbs {
		name, _ := db["name"].(string)
		if name == "" {
			continue
		}
		row := collect.Row{"kind": "database", "database_name": name, "containment": db["containment"], "entered": false}
		if n, _ := asInt(db["can_enter"]); n == 1 {
			enter = append(enter, db)
		} else {
			row["note"] = "not entered: not online, a snapshot, a local secondary replica or no access (HAS_DBACCESS)"
		}
		r.out = append(r.out, row)
	}
	// the certificates' use, once, from master: a test without its right, or a failed read, leaves the use unknown
	// (the hit keeps the rule's severity and says so), never the database read
	use := map[string]collect.Row{}
	useSQL, useMissing := r.certUseSQL()
	useNote := ""
	if rows, err := QueryRows(r.ctx, r.conn, useSQL); err == nil {
		for _, u := range rows {
			if t, ok := u["thumbprint"].(string); ok {
				use[t] = u
			}
		}
		if len(useMissing) > 0 {
			useNote = fmt.Sprintf("master's certificate use not read in full (%s TO [%s])", strings.Join(useMissing, "; "), r.ctxt.Login)
		}
	} else {
		useNote = "master's certificate use not read: " + err.Error()
	}
	if len(enter) > 1 {
		k := int(time.Now().Unix()/3600) % len(enter)
		enter = append(enter[k:], enter[:k]...)
	}
	stop, hasStop := r.ctx.Deadline()
	var failed, cut []string
	for _, db := range enter {
		name, _ := db["name"].(string)
		quoted, _ := db["quoted"].(string)
		if len(cut) > 0 || r.ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second) {
			cut = append(cut, name)
			continue
		}
		rows, err := QueryRows(r.ctx, r.conn, fmt.Sprintf(secDatabaseSQL, quoted+".", secHasLogin))
		if err != nil {
			if r.ctx.Err() != nil {
				cut = append(cut, name)
				continue
			}
			failed = append(failed, name)
			continue
		}
		r.out = append(r.out, collect.Row{"kind": "dbread", "database_name": name})
		for _, o := range rows {
			o["kind"], o["database_name"] = "dbobject", name
			if k, _ := o["object_kind"].(string); k == "certificate" && name == "master" {
				t, _ := o["text2"].(string)
				o["use"] = certUse(use[t])
			}
			r.out = append(r.out, o)
		}
	}
	var parts []string
	if len(failed) > 0 {
		parts = append(parts, fmt.Sprintf("%d database(s) not read (%s)", len(failed), firstFew(failed, 5)))
	}
	if len(cut) > 0 {
		parts = append(parts, fmt.Sprintf("the run's deadline came before %d database(s): the next hours start further on", len(cut)))
	}
	if !r.ctxt.VAD {
		parts = append(parts, fmt.Sprintf("each database lists only what the login may see without VIEW ANY DEFINITION: GRANT VIEW ANY DEFINITION TO [%s]", r.ctxt.Login))
	}
	if useNote != "" {
		parts = append(parts, useNote)
	}
	r.part("databases", "read", strings.Join(parts, "; "))
}

// certUse names a master certificate's use (TDE, backup encryption, an endpoint) from its row of the use read; a
// certificate of another database has its own uses (signing, Service Broker dialogs, a key's encryption) the read
// does not trace, and is never asked. No use found where a test was not read (NULL), or no row at all, is
// "unknown": the hit keeps the rule's severity and says its use was not read (0159).
func certUse(u collect.Row) any {
	if u == nil {
		return "unknown"
	}
	var uses []string
	unread := false
	for _, t := range []struct{ col, name string }{{"backup_encryptor", "backup encryption"}, {"broker_endpoint", "Service Broker endpoint"},
		{"mirroring_endpoint", "mirroring / availability group endpoint"}, {"tde", "TDE"}} {
		if u[t.col] == nil {
			unread = true
		} else if secFlag(u[t.col]) {
			uses = append(uses, t.name)
		}
	}
	if len(uses) == 0 {
		if unread {
			return "unknown"
		}
		return nil
	}
	return strings.Join(uses, ", ")
}
