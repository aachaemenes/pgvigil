// Package mssqlread holds what every path that runs the DBA's own SQL on a SQL Server instance shares: the procedure
// name a configuration may name and its quoting, the form a SQL Server value takes in pgvigil's answers, and the ONE
// fence of the read login (ServerRefusal, DatabaseRefusal) - custom reports (internal/web) and custom checks
// (internal/mssql mssql_custom) both refuse a login with any right outside the documented read login's.
package mssqlread

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb" // the sqlserver driver (BSD-3)
)

// ProcName is a procedure's name as a configuration or a report names one: 1 to 3 parts, each a letter or '_' and
// then letters, digits, '_', '$' or '#', at most 128 characters - no bracket, quote or space, so the name quoted into
// an EXEC is the name written.
var ProcName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_$#]{0,127}(\.[A-Za-z_][A-Za-z0-9_$#]{0,127}){0,2}$`)

// QuoteName is SQL Server's QUOTENAME with brackets: the name in [ ], a ] in it doubled.
func QuoteName(s string) string { return "[" + strings.ReplaceAll(s, "]", "]]") + "]" }

// QuoteProc quotes each part of a dotted procedure name ("Utility.dbo.p" -> "[Utility].[dbo].[p]").
func QuoteProc(name string) string {
	parts := strings.Split(strings.TrimSpace(name), ".")
	for i, p := range parts {
		parts[i] = QuoteName(p)
	}
	return strings.Join(parts, ".")
}

// Type is a SQL Server column's type as a page draws it: number, time or text.
func Type(name string) string {
	switch strings.ToUpper(name) {
	case "INT", "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY", "FLOAT", "REAL":
		return "number"
	case "DATETIMEOFFSET":
		return "time"
	}
	return "text"
}

// Cell turns a go-mssqldb value into the JSON answer's form: a number as a number unless it would lose digits in a
// browser (then its text), a datetimeoffset as RFC 3339 in UTC, a datetime without an offset as the server's wall
// clock (no zone, never moved to the reader's), a uniqueidentifier as its text, other bytes as 0x and upper-case hex.
func Cell(v any, typ string) any {
	t := strings.ToUpper(typ)
	switch x := v.(type) {
	case nil, bool, string, float32:
		return x
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return strconv.FormatFloat(x, 'g', -1, 64)
		}
		return x
	case int64:
		if x > 1<<53 || x < -(1<<53) {
			return strconv.FormatInt(x, 10)
		}
		return x
	case time.Time:
		switch t {
		case "DATE":
			return x.Format("2006-01-02")
		case "TIME":
			return x.Format("15:04:05.9999999")
		case "DATETIMEOFFSET":
			return x.UTC().Format(time.RFC3339Nano)
		}
		return x.Format("2006-01-02 15:04:05.999")
	case []byte:
		switch t {
		case "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY":
			s := string(x)
			if f, err := strconv.ParseFloat(s, 64); err == nil && len(strings.TrimLeft(strings.Replace(s, ".", "", 1), "-0")) <= 15 {
				return f
			}
			return s
		case "UNIQUEIDENTIFIER":
			var u mssqldb.UniqueIdentifier
			if err := u.Scan(x); err == nil {
				return u.String()
			}
		}
		return "0x" + strings.ToUpper(hex.EncodeToString(x))
	}
	return fmt.Sprint(v)
}

// Number is a SQL Server value as a number, for a check's value column: the integer types, real and float, decimal,
// numeric, money and smallmoney (their text), bit (0 / 1). ok = false for NULL; an error for any other type, or a value
// that is no finite number.
func Number(v any, typ string) (f float64, ok bool, err error) {
	switch x := v.(type) {
	case nil:
		return 0, false, nil
	case int64:
		return float64(x), true, nil
	case float64:
		f = x
	case float32:
		f = float64(x)
	case bool:
		if x {
			return 1, true, nil
		}
		return 0, true, nil
	case []byte:
		switch strings.ToUpper(typ) {
		case "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY":
			f, err = strconv.ParseFloat(strings.TrimSpace(string(x)), 64)
			if err != nil {
				return 0, false, fmt.Errorf("%q is not a number", string(x))
			}
		default:
			return 0, false, fmt.Errorf("a %s column is not a number", strings.ToLower(typ))
		}
	case string:
		switch strings.ToUpper(typ) {
		case "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY":
			f, err = strconv.ParseFloat(strings.TrimSpace(x), 64)
			if err != nil {
				return 0, false, fmt.Errorf("%q is not a number", x)
			}
		default:
			return 0, false, fmt.Errorf("a %s column is not a number", strings.ToLower(typ))
		}
	default:
		return 0, false, fmt.Errorf("a %s column is not a number", strings.ToLower(typ))
	}
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, false, fmt.Errorf("%v is not a finite number", f)
	}
	return f, true, nil
}

// ServerAllowed are the server rights of the documented read login (docs/sqlserver.md 'The login': VIEW SERVER
// STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE, ALTER TRACE, and public's CONNECT SQL and VIEW ANY DATABASE) as
// sys.fn_my_permissions(NULL, 'SERVER') answers them, with the rows SQL Server 2022 splits two of them into (read on
// 16.0.4295.3: VIEW ANY PERFORMANCE DEFINITION, VIEW ANY SECURITY DEFINITION, VIEW SERVER PERFORMANCE STATE, VIEW
// SERVER SECURITY STATE). Any other row refuses: the list is an allowlist, so a right a later version adds is refused
// by its name until it is named here.
var ServerAllowed = map[string]bool{
	"ALTER TRACE": true, "CONNECT ANY DATABASE": true, "CONNECT SQL": true, "VIEW ANY DATABASE": true, "VIEW ANY DEFINITION": true,
	"VIEW ANY PERFORMANCE DEFINITION": true, "VIEW ANY SECURITY DEFINITION": true, "VIEW SERVER PERFORMANCE STATE": true,
	"VIEW SERVER SECURITY STATE": true, "VIEW SERVER STATE": true,
}

// DatabaseAllowed says whether a row of the database read (sqlDatabaseRights) is a right the DBA's own SQL may run
// with in that database: the database-wide CONNECT, SELECT, REFERENCES, SHOWPLAN and every VIEW right. Any other row
// refuses: a database-wide INSERT, UPDATE, DELETE, ALTER, CONTROL, a CREATE, BACKUP, TAKE OWNERSHIP (db_owner,
// db_ddladmin, db_datawriter, db_securityadmin, db_accessadmin and db_backupoperator all answer with one); a
// database-wide EXECUTE (a sql: check could run every procedure of the database, and a dbo procedure writes dbo's tables
// by ownership chaining: a procedure: check needs EXECUTE on its own procedure only); and every row the read words
// itself ('INSERT on schema dbo', 'owner of schema app', 'IMPERSONATE on user x'): a check that ends the transaction
// it runs in would write.
func DatabaseAllowed(perm string) bool {
	switch perm {
	case "CONNECT", "SELECT", "REFERENCES", "SHOWPLAN":
		return true
	}
	return strings.HasPrefix(perm, "VIEW ")
}

// sqlServerRights is every server right of the session's login that ServerRefusal judges: sysadmin, each row of
// fn_my_permissions(NULL, 'SERVER') (effective: through server roles and the 2022 fixed roles too), every other login
// it may IMPERSONATE (a check could EXECUTE AS LOGIN = that one, as a PostgreSQL check can SET ROLE; the name quoted:
// HAS_PERMS_BY_NAME reads an unquoted 'CORP\sql.admin' as a two-part name and answers 0), and every grant on a server
// object (a login, an endpoint, an availability group) to the login or a server role of its token, but CONNECT and
// VIEW DEFINITION (public's CONNECT on the TSQL endpoints). Every column in the database's collation: the catalog's
// names and a literal may differ (Msg 451 on the sandbox).
const sqlServerRights = `SELECT CAST('role sysadmin' AS nvarchar(300)) COLLATE DATABASE_DEFAULT WHERE IS_SRVROLEMEMBER('sysadmin') = 1
UNION ALL SELECT CAST(permission_name AS nvarchar(300)) COLLATE DATABASE_DEFAULT FROM sys.fn_my_permissions(NULL, 'SERVER')
UNION ALL SELECT CAST(N'IMPERSONATE on login ' + p.name AS nvarchar(300)) COLLATE DATABASE_DEFAULT FROM sys.server_principals p
 WHERE p.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K') AND p.principal_id <> SUSER_ID() AND HAS_PERMS_BY_NAME(QUOTENAME(p.name), 'LOGIN', 'IMPERSONATE') = 1
UNION ALL SELECT CAST(sp.permission_name COLLATE DATABASE_DEFAULT + N' on ' + CASE sp.class
   WHEN 101 THEN N'login ' + ISNULL(SUSER_NAME(sp.major_id) COLLATE DATABASE_DEFAULT, CAST(sp.major_id AS nvarchar(20)))
   WHEN 105 THEN N'endpoint ' + ISNULL((SELECT e.name COLLATE DATABASE_DEFAULT FROM sys.endpoints e WHERE e.endpoint_id = sp.major_id), CAST(sp.major_id AS nvarchar(20)))
   ELSE LOWER(sp.class_desc COLLATE DATABASE_DEFAULT) + N' ' + CAST(sp.major_id AS nvarchar(20)) END AS nvarchar(300)) COLLATE DATABASE_DEFAULT
  FROM sys.server_permissions sp
 WHERE sp.class <> 100 AND sp.state IN ('G', 'W') AND sp.grantee_principal_id IN (SELECT t.principal_id FROM sys.login_token t)
   AND sp.permission_name NOT IN ('CONNECT', 'VIEW DEFINITION', 'IMPERSONATE')`

// sqlDatabaseRights is the same in one database (run there by its own sp_executesql): each row of
// fn_my_permissions(NULL, 'DATABASE'); every other user the session may IMPERSONATE there (the name quoted); every
// grant on a securable of the database (an object or a column, a schema, a principal, a queue, a key ...) to the user
// or a role of its token but SELECT, REFERENCES, VIEW DEFINITION, VIEW CHANGE TRACKING and an object's EXECUTE (a
// procedure: check's own grant); and every schema it owns that holds an object, and every object it owns (an owner
// writes what it owns: ALTER, INSERT, UPDATE, DELETE need no grant). A fixed role owns an empty schema of its name
// (db_datareader's): an empty schema is no write without a database-wide CREATE, read above.
const sqlDatabaseRights = `SELECT CAST(permission_name AS nvarchar(300)) COLLATE DATABASE_DEFAULT FROM sys.fn_my_permissions(NULL, 'DATABASE')
UNION ALL SELECT CAST(N'IMPERSONATE on user ' + p.name AS nvarchar(300)) COLLATE DATABASE_DEFAULT FROM sys.database_principals p
 WHERE p.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K') AND p.principal_id <> USER_ID() AND HAS_PERMS_BY_NAME(QUOTENAME(p.name), 'USER', 'IMPERSONATE') = 1
UNION ALL SELECT CAST(dp.permission_name COLLATE DATABASE_DEFAULT + N' on ' + CASE dp.class
   WHEN 1 THEN N'object ' + ISNULL(OBJECT_SCHEMA_NAME(dp.major_id) COLLATE DATABASE_DEFAULT + N'.' + OBJECT_NAME(dp.major_id) COLLATE DATABASE_DEFAULT, CAST(dp.major_id AS nvarchar(20)))
   WHEN 3 THEN N'schema ' + ISNULL(SCHEMA_NAME(dp.major_id) COLLATE DATABASE_DEFAULT, CAST(dp.major_id AS nvarchar(20)))
   WHEN 4 THEN N'principal ' + ISNULL(USER_NAME(dp.major_id) COLLATE DATABASE_DEFAULT, CAST(dp.major_id AS nvarchar(20)))
   ELSE LOWER(dp.class_desc COLLATE DATABASE_DEFAULT) + N' ' + CAST(dp.major_id AS nvarchar(20)) END AS nvarchar(300)) COLLATE DATABASE_DEFAULT
  FROM sys.database_permissions dp
 WHERE dp.class > 0 AND dp.state IN ('G', 'W') AND dp.grantee_principal_id IN (SELECT t.principal_id FROM sys.user_token t)
   AND dp.permission_name NOT IN ('SELECT', 'REFERENCES', 'VIEW DEFINITION', 'VIEW CHANGE TRACKING', 'IMPERSONATE')
   AND NOT (dp.class = 1 AND dp.permission_name = 'EXECUTE')
UNION ALL SELECT CAST(N'owner of schema ' + s.name AS nvarchar(300)) COLLATE DATABASE_DEFAULT FROM sys.schemas s
 WHERE s.principal_id IN (SELECT t.principal_id FROM sys.user_token t) AND EXISTS (SELECT 1 FROM sys.objects o WHERE o.schema_id = s.schema_id)
UNION ALL SELECT CAST(N'owner of object ' + SCHEMA_NAME(o.schema_id) + N'.' + o.name AS nvarchar(300)) COLLATE DATABASE_DEFAULT FROM sys.objects o
 WHERE o.principal_id IN (SELECT t.principal_id FROM sys.user_token t)`

// sqlEveryDatabaseRights is sqlDatabaseRights in every database the session can open, in one batch the server loops
// (a check's own T-SQL can reach any of them: USE, or a three-part name). A database it cannot open now (offline,
// restoring, a secondary that refuses reads) answers one 'NOT READ: <the error>' row and is skipped: a check run as
// the same login cannot open it either; when NO database answers its rights the fence fails (an error the loop
// swallowed for each one must never read as "nothing to refuse"). The read is sqlDatabaseRights itself, its quotes
// doubled: one text for both reads.
var sqlEveryDatabaseRights = `SET NOCOUNT ON;
DECLARE @pgv_r TABLE (db sysname, p nvarchar(300));
DECLARE @pgv_db sysname, @pgv_s nvarchar(max);
DECLARE pgv_c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.databases WHERE state = 0 AND HAS_DBACCESS(name) = 1;
OPEN pgv_c;
FETCH NEXT FROM pgv_c INTO @pgv_db;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @pgv_s = N'USE ' + QUOTENAME(@pgv_db) + N'; SELECT DB_NAME() COLLATE DATABASE_DEFAULT, x.p FROM (
` + strings.ReplaceAll(sqlDatabaseRights, "'", "''") + `
) AS x (p);';
  BEGIN TRY
    INSERT @pgv_r EXEC (@pgv_s);
  END TRY
  BEGIN CATCH
    INSERT @pgv_r VALUES (@pgv_db, N'NOT READ: ' + LEFT(ERROR_MESSAGE(), 280));
  END CATCH
  FETCH NEXT FROM pgv_c INTO @pgv_db;
END
CLOSE pgv_c;
DEALLOCATE pgv_c;
SELECT db, p FROM @pgv_r;`

// readWords is what passes in a database, as a refusal says it.
const readWords = "the database-wide CONNECT, SELECT, REFERENCES, SHOWPLAN and VIEW rights; SELECT, REFERENCES and VIEW DEFINITION on a schema or an object, EXECUTE on a procedure; no schema holding objects owned"

// DatabasesRefusal reads the login's rights in every database it can open and says why the DBA's own SQL may not run
// as it ("" = it may): each database where it holds a right outside DatabaseAllowed, with those rights.
func DatabasesRefusal(ctx context.Context, conn *sql.Conn) (string, error) {
	rows, err := conn.QueryContext(ctx, sqlEveryDatabaseRights)
	if err != nil {
		return "", fmt.Errorf("reading the login's rights in each database: %w", err)
	}
	defer func() { _ = rows.Close() }()
	extra := map[string]map[string]bool{}
	read, notRead := map[string]bool{}, ""
	for rows.Next() {
		var db, p string
		if err := rows.Scan(&db, &p); err != nil {
			return "", fmt.Errorf("reading the login's rights in each database: %w", err)
		}
		if strings.HasPrefix(p, "NOT READ: ") {
			notRead = db + ": " + strings.TrimPrefix(p, "NOT READ: ")
			continue
		}
		read[db] = true
		if !DatabaseAllowed(p) {
			if extra[db] == nil {
				extra[db] = map[string]bool{}
			}
			extra[db][p] = true
		}
	}
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("reading the login's rights in each database: %w", err)
	}
	if len(read) == 0 {
		return "", fmt.Errorf("the login's rights were read in no database (the last refusal: %s)", notRead)
	}
	if len(extra) == 0 {
		return "", nil
	}
	dbs := make([]string, 0, len(extra))
	for db := range extra {
		dbs = append(dbs, db)
	}
	sort.Strings(dbs)
	var parts []string
	for _, db := range dbs {
		ps := make([]string, 0, len(extra[db]))
		for p := range extra[db] {
			ps = append(ps, p)
		}
		sort.Strings(ps)
		parts = append(parts, "in database "+db+" "+strings.Join(ps, ", "))
	}
	return "the read login holds " + strings.Join(parts, "; ") + ": the DBA's own SQL can reach every database the login opens (USE, a three-part name), so it runs only where the login can read and not write in each (" + readWords + ")", nil
}

// ServerRefusal reads the login's server rights and says why the DBA's own SQL may not run as it ("" = it may): every
// right outside ServerAllowed, by name, sorted. azureDB: an Azure SQL Database answers no server scope (its rights are
// the database's: DatabaseRefusal), and the read is skipped there.
func ServerRefusal(ctx context.Context, conn *sql.Conn, azureDB bool) (string, error) {
	if azureDB {
		return "", nil
	}
	rows, err := conn.QueryContext(ctx, sqlServerRights)
	if err != nil {
		return "", fmt.Errorf("reading the login's server rights: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var extra []string
	seen := map[string]bool{}
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return "", fmt.Errorf("reading the login's server rights: %w", err)
		}
		if !ServerAllowed[p] && !seen[p] {
			seen[p] = true
			extra = append(extra, p)
		}
	}
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("reading the login's server rights: %w", err)
	}
	if len(extra) == 0 {
		return "", nil
	}
	sort.Strings(extra)
	return "the read login holds " + strings.Join(extra, ", ") + ", outside the documented read login's rights (docs/sqlserver.md 'The login': VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE, ALTER TRACE)", nil
}

// DatabaseRefusal reads the login's rights in one database (database "" = the session's own) and says why the DBA's
// own SQL may not run there ("" = it may). A database that does not exist, or that the login cannot open, is an
// error in those words.
func DatabaseRefusal(ctx context.Context, conn *sql.Conn, database string) (string, error) {
	stmt := "EXEC sys.sp_executesql @stmt"
	where := "the database the dsn connects to"
	if database != "" {
		stmt = "EXEC " + QuoteName(database) + ".sys.sp_executesql @stmt"
		where = "database " + database
	}
	rows, err := conn.QueryContext(ctx, stmt, sql.Named("stmt", sqlDatabaseRights))
	if err != nil {
		var me mssqldb.Error
		if ok := asMSSQL(err, &me); ok && (me.Number == 911 || me.Number == 916 || me.Number == 2812) {
			return "", fmt.Errorf("%s does not exist or the read login cannot open it (Msg %d)", where, me.Number)
		}
		return "", fmt.Errorf("reading the login's rights in %s: %w", where, err)
	}
	defer func() { _ = rows.Close() }()
	var extra []string
	seen := map[string]bool{}
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return "", fmt.Errorf("reading the login's rights in %s: %w", where, err)
		}
		if !DatabaseAllowed(p) && !seen[p] {
			seen[p] = true
			extra = append(extra, p)
		}
	}
	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("reading the login's rights in %s: %w", where, err)
	}
	if len(extra) == 0 {
		return "", nil
	}
	sort.Strings(extra)
	return "in " + where + " the read login holds " + strings.Join(extra, ", ") + ": the DBA's own SQL runs only where the login can read and not write (" + readWords + ")", nil
}

// Fence is the one check before the DBA's own SQL runs as the read login on a SQL Server: the server rights
// (ServerRefusal), then the rights in every database the login can open (DatabasesRefusal). An Azure SQL Database
// answers no server scope and no other database: its own database's rights alone (DatabaseRefusal). "" = it may run.
func Fence(ctx context.Context, conn *sql.Conn) (string, error) {
	var edition sql.NullInt64
	if err := conn.QueryRowContext(ctx, "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int)").Scan(&edition); err != nil {
		return "", fmt.Errorf("reading the server's edition: %w", err)
	}
	if edition.Valid && edition.Int64 == 5 {
		return DatabaseRefusal(ctx, conn, "")
	}
	why, err := ServerRefusal(ctx, conn, false)
	if err != nil || why != "" {
		return why, err
	}
	return DatabasesRefusal(ctx, conn)
}

// asMSSQL finds the server's error inside err.
func asMSSQL(err error, out *mssqldb.Error) bool { return errors.As(err, out) }

// ErrorNumber is the SQL Server error number inside err (0 = none).
func ErrorNumber(err error) int32 {
	var me mssqldb.Error
	if asMSSQL(err, &me) {
		return me.Number
	}
	return 0
}

// HasErrorNumber says whether the server raised any of nums among the errors inside err (the driver keeps every error
// of a request, the last one on top: a Msg 266 and pgvigil's own 50266 after it come as one error).
func HasErrorNumber(err error, nums ...int32) bool {
	var me mssqldb.Error
	if !asMSSQL(err, &me) {
		return false
	}
	all := me.All
	if len(all) == 0 {
		all = []mssqldb.Error{me}
	}
	for _, e := range all {
		for _, n := range nums {
			if e.Number == n {
				return true
			}
		}
	}
	return false
}
