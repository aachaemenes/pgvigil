package mssql

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_schema: SQL Server schema history (task A26; PerformanceMonitor 3.13's 'Added 26', DBA Dash's schema
// snapshots). Per database in the instance's mssql_schema.databases scope, one row per object - schemas, tables (with
// each column, index, constraint and DML trigger as its own row, its table as parent), views, procedures, functions,
// synonyms, sequences and user types - with its definition as pgvigil's own canonical text from the catalog, into
// 0058's tables through 0267's import_mssql_schema, so the Schema tab, the schema findings, purge and the Diff page
// serve SQL Server as they serve PostgreSQL.
//
// When a database is read: a pass asks the repository (import_mssql_schema_due) which databases are due a WHOLE read
// - never read, another database on a reused id, a restore, a committed CREATE / ALTER / DROP the default trace's
// reader stored since the database's last read (trusted only while that reader is current), a reader gap, a torn
// read, or the daily reconcile - and reads them oldest first inside a 5-minute pass, 120 seconds a database; every
// other database of the scope is sent 'seen' (kept as it was). The trace keeps neither schema nor object id, so a
// database is re-read whole, never object by object: import_schema's unit is the database.
//
// What a definition holds: the catalog's facts in a fixed order, and for a module (procedure, function, trigger) its
// signature - parameters, EXECUTE AS, SCHEMABINDING, ANSI_NULLS, QUOTED_IDENTIFIER, ENCRYPTION, a CLR method - then
// its body: as TEXT under the instance's query_text 'full' (credentials masked, collect.MaskJobText), as
// 'body sha256:<16 hex>' under 'normalized' or 'none'. A view's text is kept (masked) under every policy. The hash
// and def_hash are ALWAYS taken over the signature and the body's sha, never the text: a change of query_text, or a
// mask, is never a schema change.
//
// Reads: READ COMMITTED with LOCK_TIMEOUT 5000 (never READ UNCOMMITTED: a catalog read through a writer's
// uncommitted DDL would store objects that never were); a fingerprint (objects, their newest modify_date, indexes)
// before and after the read - different = the read is not stored ('torn', read again next pass). A database the login
// cannot see the definitions of (no VIEW DEFINITION) is 'not readable' and records no change; over 10,000 tables and
// views, or over 160 MB of definitions even with bodies as hashes, 'partial': its stored snapshot is kept.
//
// Rights: VIEW ANY DEFINITION (or VIEW DEFINITION in each database), CONNECT ANY DATABASE (or a user in each);
// msdb's restorehistory for telling a restore from another database on the same id. SQL Server 2016 or later (the
// reads use FOR JSON).

type schemaCollector struct{}

func init() { Register(schemaCollector{}) }

const (
	schemaPass      = 5 * time.Minute
	schemaPerDB     = 120 * time.Second
	schemaMaxTables = 10000     // tables and views of one database (PerformanceMonitor's cap; their children inside)
	schemaMaxText   = 160 << 20 // bytes of definitions one database's import takes
	schemaMaxDef    = 20000     // characters of one stored definition (0058's cut; the hashes are taken before it)
)

func (schemaCollector) Name() string                   { return Prefix + "schema" }
func (schemaCollector) DefaultInterval() time.Duration { return 15 * time.Minute }
func (schemaCollector) Timeout() time.Duration         { return schemaPass + batchMargin + 30*time.Second }

func (schemaCollector) Applies(info Info) (bool, string) {
	if info.Major > 0 && info.Major < 13 {
		return false, "the schema history needs SQL Server 2016 or later (its reads use FOR JSON)"
	}
	return true, ""
}

// Run is the read without the batch path (no repository): nothing is in scope there.
func (c schemaCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	var out []collect.Row
	err := c.RunBatches(ctx, conn, info, BatchOptions{}, nil, func(rows []collect.Row) error {
		out = append(out, rows...)
		return nil
	})
	return out, err
}

// schemaInScope reads mssql_schema.databases in DBA Dash's grammar: '*' every database, a name that one, '-name' leaves
// one out (case ignored); a list of '-name' entries alone means every other database.
func schemaInScope(list []string) func(name string) bool {
	all, names, out := false, map[string]bool{}, map[string]bool{}
	for _, e := range list {
		e = strings.TrimSpace(e)
		switch {
		case e == "":
		case e == "*":
			all = true
		case strings.HasPrefix(e, "-"):
			out[strings.ToLower(strings.TrimSpace(e[1:]))] = true
		default:
			names[strings.ToLower(e)] = true
		}
	}
	if !all && len(names) == 0 && len(out) > 0 {
		all = true
	}
	return func(name string) bool {
		n := strings.ToLower(name)
		return (all || names[n]) && !out[n]
	}
}

// schemaQuote quotes one part of an identity when it holds a dot, a space or a double quote (pg_identify_object's
// rule), so 'a.b'.'c' and 'a'.'b.c' never meet.
func schemaQuote(p string) string {
	if p == "" || strings.ContainsAny(p, `. "`) {
		return `"` + strings.ReplaceAll(p, `"`, `""`) + `"`
	}
	return p
}

// schemaObj is one row of the catalog read.
type schemaObj struct {
	kind, schema, name, pschema, pname string
	def, body, owner                   string
	hasBody                            bool
}

func (o schemaObj) identity() string {
	switch o.kind {
	case "schema":
		return schemaQuote(o.schema)
	case "column":
		return schemaQuote(o.pschema) + "." + schemaQuote(o.pname) + "." + schemaQuote(o.name)
	case "index", "constraint", "trigger":
		return schemaQuote(o.name) + " on " + schemaQuote(o.pschema) + "." + schemaQuote(o.pname)
	}
	return schemaQuote(o.schema) + "." + schemaQuote(o.name)
}

func (o schemaObj) parent() any {
	if o.pname == "" {
		return nil
	}
	return schemaQuote(o.pschema) + "." + schemaQuote(o.pname)
}

func sha16(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}

// schemaForms returns the stored definition (under the policy) and the hashed form (policy-free): the facts, then for
// a body 'body sha256:<16 hex>' of the raw text. The body's text is stored (masked) under 'full' (or no policy set:
// the configuration's default) and, for a view, always.
func schemaForms(o schemaObj, mode string) (stored, hashed string) {
	hashed = o.def
	if o.hasBody {
		hashed += "\nbody sha256:" + sha16(o.body)
	}
	stored = hashed
	if o.hasBody && (o.kind == "view" || mode == "" || mode == "full") {
		stored = o.def + "\n" + collect.MaskJobText(o.body)
	}
	return stored, hashed
}

// schemaRow is the import's 'obj' row of one object.
func schemaRow(db userDB, o schemaObj, mode string) collect.Row {
	stored, hashed := schemaForms(o, mode)
	hash := sha256.Sum256([]byte(o.kind + "\x00" + hashed + "\x00" + o.owner))
	defHash := sha256.Sum256([]byte(hashed))
	var owner any
	if o.owner != "" {
		owner = o.owner
	}
	objectName := o.name
	if o.kind == "schema" {
		objectName = o.schema
	}
	return collect.Row{"kind": "obj", "dbid": db.id, "datname": db.name, "object_kind": o.kind, "identity": o.identity(),
		"schema_name": o.schema, "object_name": objectName, "parent": o.parent(), "definition": cutRunes(stored, schemaMaxDef),
		"owner": owner, "acl": nil, "hash": hex.EncodeToString(hash[:16]), "def_hash": hex.EncodeToString(defHash[:16])}
}

// schemaFingerprint is what a read compares before and after itself.
type schemaFingerprint struct {
	objects, indexes, tablesViews int64
	newest                        string
	viewDefinition                bool
}

const schemaFingerprintSQL = `SELECT COUNT_BIG(*) AS objects, CONVERT(varchar(27), MAX(o.modify_date), 126) AS newest,
  (SELECT COUNT_BIG(*) FROM sys.indexes) AS indexes,
  (SELECT COUNT_BIG(*) FROM sys.objects v WHERE v.type IN ('U', 'V') AND v.is_ms_shipped = 0) AS tables_views,
  CAST(ISNULL(HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DEFINITION'), 0) AS int) AS view_definition
FROM sys.objects o`

func readSchemaFingerprint(ctx context.Context, conn *sql.Conn, quoted string) (schemaFingerprint, error) {
	rows, err := qsRead(ctx, conn, quoted, schemaFingerprintSQL, "")
	if err != nil {
		return schemaFingerprint{}, err
	}
	if len(rows) != 1 {
		return schemaFingerprint{}, fmt.Errorf("the fingerprint returned %d rows", len(rows))
	}
	r := rows[0]
	n := func(k string) int64 { v, _ := r[k].(int64); return v }
	newest, _ := r["newest"].(string)
	return schemaFingerprint{objects: n("objects"), indexes: n("indexes"), tablesViews: n("tables_views"), newest: newest,
		viewDefinition: n("view_definition") == 1}, nil
}

func (a schemaFingerprint) same(b schemaFingerprint) bool {
	return a.objects == b.objects && a.indexes == b.indexes && a.tablesViews == b.tablesViews && a.newest == b.newest
}

// The catalog read: three statements run inside the database, each returning the same eight columns.
const schemaColumns = `CAST(%s AS nvarchar(20)) AS kind, CAST(%s AS nvarchar(128)) AS schema_name, CAST(%s AS nvarchar(128)) AS object_name,
  CAST(%s AS nvarchar(128)) AS parent_schema, CAST(%s AS nvarchar(128)) AS parent_name, CAST(%s AS nvarchar(max)) AS def,
  CAST(%s AS nvarchar(max)) AS body, CAST(%s AS nvarchar(128)) AS owner, CAST(%s AS int) AS has_body`

func schemaCols(kind, schema, name, pschema, pname, def, body, owner, hasBody string) string {
	return fmt.Sprintf(schemaColumns, kind, schema, name, pschema, pname, def, body, owner, hasBody)
}

const schemaJSONCols = `(SELECT c.name AS n, TYPE_NAME(c.user_type_id) AS t, c.max_length AS l, c.precision AS p, c.scale AS s, c.is_nullable AS nu
  FROM sys.columns c WHERE c.object_id = tt.type_table_object_id ORDER BY c.column_id FOR JSON PATH)`

func schemaKeyCols(objectID, indexID string) string {
	return `ISNULL((SELECT c.name AS n, ic.is_descending_key AS d FROM sys.index_columns ic
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
   WHERE ic.object_id = ` + objectID + ` AND ic.index_id = ` + indexID + ` AND ic.key_ordinal > 0 ORDER BY ic.key_ordinal FOR JSON PATH), N'[]')`
}

var schemaObjectsSQL = `WITH o AS (
  SELECT ob.object_id, ob.name, ob.type, ob.parent_object_id, SCHEMA_NAME(ob.schema_id) AS sch,
         USER_NAME(COALESCE(ob.principal_id, s.principal_id)) AS owner
    FROM sys.objects ob JOIN sys.schemas s ON s.schema_id = ob.schema_id
   WHERE ob.is_ms_shipped = 0)
SELECT ` + schemaCols("'schema'", "s.name", "NULL", "NULL", "NULL", "N'schema'", "NULL", "USER_NAME(s.principal_id)", "0") + `
  FROM sys.schemas s WHERE s.schema_id < 16384 AND s.name NOT IN (N'sys', N'INFORMATION_SCHEMA', N'guest')
UNION ALL
SELECT ` + schemaCols("'table'", "o.sch", "o.name", "NULL", "NULL", `CONCAT(N'table',
    CASE WHEN t.temporal_type = 2 THEN N' system-versioned, history ' + QUOTENAME(SCHEMA_NAME(h.schema_id)) + N'.' + QUOTENAME(h.name) END,
    CASE WHEN t.temporal_type = 1 THEN N' history table' END,
    CASE WHEN t.is_memory_optimized = 1 THEN N' memory-optimized ' + LOWER(t.durability_desc) END,
    N' lock escalation ' + LOWER(t.lock_escalation_desc),
    (SELECT TOP (1) N' partitioned by ' + ps.name + N' (' + pc.name + N')' FROM sys.indexes pi
       JOIN sys.partition_schemes ps ON ps.data_space_id = pi.data_space_id
       JOIN sys.index_columns pic ON pic.object_id = pi.object_id AND pic.index_id = pi.index_id AND pic.partition_ordinal = 1
       JOIN sys.columns pc ON pc.object_id = pic.object_id AND pc.column_id = pic.column_id
      WHERE pi.object_id = t.object_id AND pi.index_id <= 1))`, "NULL", "o.owner", "0") + `
  FROM sys.tables t JOIN o ON o.object_id = t.object_id LEFT JOIN sys.tables h ON h.object_id = t.history_table_id
UNION ALL
SELECT ` + schemaCols("'view'", "o.sch", "o.name", "NULL", "NULL",
	`CONCAT(N'view', CASE WHEN m.is_schema_bound = 1 THEN N' schemabinding' END, CASE WHEN m.object_id IS NOT NULL AND m.definition IS NULL THEN N' encrypted' END)`,
	"m.definition", "o.owner", "CASE WHEN m.definition IS NULL THEN 0 ELSE 1 END") + `
  FROM sys.views v JOIN o ON o.object_id = v.object_id LEFT JOIN sys.sql_modules m ON m.object_id = v.object_id
UNION ALL
SELECT ` + schemaCols(`CASE WHEN o.type IN ('P', 'PC', 'X', 'RF') THEN 'procedure' WHEN o.type IN ('TR', 'TA') THEN 'trigger' ELSE 'function' END`,
	"o.sch", "o.name", `CASE WHEN o.type IN ('TR', 'TA') THEN SCHEMA_NAME(p.schema_id) END`, `CASE WHEN o.type IN ('TR', 'TA') THEN p.name END`,
	`CONCAT(CASE WHEN o.type IN ('P', 'PC', 'X', 'RF') THEN N'procedure' WHEN o.type IN ('TR', 'TA') THEN N'trigger' ELSE N'function' END,
    N' ', RTRIM(o.type),
    N' parameters ', ISNULL((SELECT pa.name AS n, TYPE_NAME(pa.user_type_id) AS t, pa.max_length AS l, pa.precision AS p, pa.scale AS s,
                                    pa.is_output AS o FROM sys.parameters pa WHERE pa.object_id = o.object_id ORDER BY pa.parameter_id FOR JSON PATH), N'[]'),
    CASE WHEN m.execute_as_principal_id = -2 THEN N' execute as owner'
         WHEN m.execute_as_principal_id IS NOT NULL THEN N' execute as ' + ISNULL(USER_NAME(m.execute_as_principal_id), N'?') END,
    CASE WHEN m.is_schema_bound = 1 THEN N' schemabinding' END,
    CASE WHEN m.object_id IS NOT NULL THEN N' ansi_nulls ' + CASE WHEN m.uses_ansi_nulls = 1 THEN N'on' ELSE N'off' END
                                         + N' quoted_identifier ' + CASE WHEN m.uses_quoted_identifier = 1 THEN N'on' ELSE N'off' END END,
    CASE WHEN m.object_id IS NOT NULL AND m.definition IS NULL THEN N' encrypted' END,
    CASE WHEN am.object_id IS NOT NULL THEN N' clr ' + asm.name + N'.' + am.assembly_class + N'.' + am.assembly_method END)`,
	"m.definition", "o.owner", "CASE WHEN m.definition IS NULL THEN 0 ELSE 1 END") + `
  FROM o LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
  LEFT JOIN sys.assembly_modules am ON am.object_id = o.object_id LEFT JOIN sys.assemblies asm ON asm.assembly_id = am.assembly_id
  LEFT JOIN sys.objects p ON p.object_id = o.parent_object_id
 WHERE o.type IN ('P', 'PC', 'X', 'RF', 'FN', 'IF', 'TF', 'FS', 'FT', 'AF', 'TR', 'TA') AND (o.type NOT IN ('TR', 'TA') OR o.parent_object_id <> 0)
UNION ALL
SELECT ` + schemaCols("'synonym'", "o.sch", "o.name", "NULL", "NULL", "CONCAT(N'synonym for ', sy.base_object_name)", "NULL", "o.owner", "0") + `
  FROM sys.synonyms sy JOIN o ON o.object_id = sy.object_id
UNION ALL
SELECT ` + schemaCols("'sequence'", "o.sch", "o.name", "NULL", "NULL", `CONCAT(N'sequence ', TYPE_NAME(sq.user_type_id),
    N' start ', CONVERT(nvarchar(40), sq.start_value), N' increment ', CONVERT(nvarchar(40), sq.increment),
    N' min ', CONVERT(nvarchar(40), sq.minimum_value), N' max ', CONVERT(nvarchar(40), sq.maximum_value),
    CASE WHEN sq.is_cycling = 1 THEN N' cycle' END,
    CASE WHEN sq.is_cached = 1 THEN N' cache ' + ISNULL(CONVERT(nvarchar(20), sq.cache_size), N'default') ELSE N' no cache' END)`, "NULL", "o.owner", "0") + `
  FROM sys.sequences sq JOIN o ON o.object_id = sq.object_id
UNION ALL
SELECT ` + schemaCols("'type'", "SCHEMA_NAME(ty.schema_id)", "ty.name", "NULL", "NULL", `CONCAT(N'type ',
    CASE WHEN ty.is_table_type = 1 THEN N'table ' + ISNULL(`+schemaJSONCols+`, N'[]')
         ELSE TYPE_NAME(ty.system_type_id) + N'(' + CONVERT(nvarchar(10), ty.max_length) + N',' + CONVERT(nvarchar(5), ty.precision)
              + N',' + CONVERT(nvarchar(5), ty.scale) + N')' + CASE WHEN ty.is_nullable = 1 THEN N' null' ELSE N' not null' END END)`,
	"NULL", "USER_NAME(COALESCE(ty.principal_id, (SELECT s2.principal_id FROM sys.schemas s2 WHERE s2.schema_id = ty.schema_id)))", "0") + `
  FROM sys.types ty LEFT JOIN sys.table_types tt ON tt.user_type_id = ty.user_type_id WHERE ty.is_user_defined = 1`

var schemaColumnsSQL = `SELECT ` + schemaCols("'column'", "SCHEMA_NAME(t.schema_id)", "c.name", "SCHEMA_NAME(t.schema_id)", "t.name", `CONCAT(N'column ',
    CONVERT(nvarchar(10), c.column_id), N' ', TYPE_NAME(c.user_type_id),
    CASE WHEN TYPE_NAME(c.system_type_id) IN (N'varchar', N'char', N'varbinary', N'binary')
           THEN N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CONVERT(nvarchar(10), c.max_length) END + N')'
         WHEN TYPE_NAME(c.system_type_id) IN (N'nvarchar', N'nchar')
           THEN N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CONVERT(nvarchar(10), c.max_length / 2) END + N')'
         WHEN TYPE_NAME(c.system_type_id) IN (N'decimal', N'numeric')
           THEN N'(' + CONVERT(nvarchar(5), c.precision) + N',' + CONVERT(nvarchar(5), c.scale) + N')'
         WHEN TYPE_NAME(c.system_type_id) IN (N'datetime2', N'time', N'datetimeoffset') THEN N'(' + CONVERT(nvarchar(5), c.scale) + N')' END,
    CASE WHEN c.is_nullable = 1 THEN N' null' ELSE N' not null' END,
    CASE WHEN ic.object_id IS NOT NULL THEN N' identity(' + CONVERT(nvarchar(40), ic.seed_value) + N',' + CONVERT(nvarchar(40), ic.increment_value) + N')' END,
    CASE WHEN cc.object_id IS NOT NULL THEN N' as ' + cc.definition + CASE WHEN cc.is_persisted = 1 THEN N' persisted' ELSE N'' END END,
    N' collate ' + c.collation_name,
    CASE WHEN c.is_sparse = 1 THEN N' sparse' END)`, "NULL", "NULL", "0") + `
  FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id AND t.is_ms_shipped = 0
  LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
  LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id`

var schemaChildrenSQL = `SELECT ` + schemaCols("'index'", "SCHEMA_NAME(ob.schema_id)", "i.name", "SCHEMA_NAME(ob.schema_id)", "ob.name", `CONCAT(N'index ',
    LOWER(i.type_desc), CASE WHEN i.is_unique = 1 THEN N' unique' END, N' keys ', `+schemaKeyCols("i.object_id", "i.index_id")+`,
    N' include ', ISNULL((SELECT c.name AS n FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1 ORDER BY c.name FOR JSON PATH), N'[]'),
    CASE WHEN i.has_filter = 1 THEN N' where ' + i.filter_definition END, N' on ' + ds.name)`, "NULL", "NULL", "0") + `
  FROM sys.indexes i JOIN sys.objects ob ON ob.object_id = i.object_id AND ob.is_ms_shipped = 0 AND ob.type IN ('U', 'V')
  LEFT JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
 WHERE i.type > 0 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.is_hypothetical = 0 AND i.name IS NOT NULL
UNION ALL
SELECT ` + schemaCols("'constraint'", "SCHEMA_NAME(kc.schema_id)", "kc.name", "SCHEMA_NAME(t.schema_id)", "t.name", `CONCAT(
    CASE kc.type WHEN 'PK' THEN N'primary key ' ELSE N'unique ' END, LOWER(i.type_desc), N' keys ', `+schemaKeyCols("i.object_id", "i.index_id")+`,
    N' on ' + ds.name)`, "NULL", "NULL", "0") + `
  FROM sys.key_constraints kc JOIN sys.tables t ON t.object_id = kc.parent_object_id AND t.is_ms_shipped = 0
  JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
  LEFT JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
UNION ALL
SELECT ` + schemaCols("'constraint'", "SCHEMA_NAME(fk.schema_id)", "fk.name", "SCHEMA_NAME(t.schema_id)", "t.name", `CONCAT(N'foreign key ',
    ISNULL((SELECT pc.name AS c, rc.name AS r FROM sys.foreign_key_columns fkc
              JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
              JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
             WHERE fkc.constraint_object_id = fk.object_id ORDER BY fkc.constraint_column_id FOR JSON PATH), N'[]'),
    N' references ', QUOTENAME(SCHEMA_NAME(r.schema_id)), N'.', QUOTENAME(r.name),
    N' on delete ', LOWER(fk.delete_referential_action_desc), N' on update ', LOWER(fk.update_referential_action_desc))`, "NULL", "NULL", "0") + `
  FROM sys.foreign_keys fk JOIN sys.tables t ON t.object_id = fk.parent_object_id AND t.is_ms_shipped = 0
  JOIN sys.objects r ON r.object_id = fk.referenced_object_id
UNION ALL
SELECT ` + schemaCols("'constraint'", "SCHEMA_NAME(ck.schema_id)", "ck.name", "SCHEMA_NAME(t.schema_id)", "t.name", "CONCAT(N'check ', ck.definition)", "NULL", "NULL", "0") + `
  FROM sys.check_constraints ck JOIN sys.tables t ON t.object_id = ck.parent_object_id AND t.is_ms_shipped = 0
UNION ALL
SELECT ` + schemaCols("'constraint'", "SCHEMA_NAME(dc.schema_id)", "dc.name", "SCHEMA_NAME(t.schema_id)", "t.name", "CONCAT(N'default ', c.name, N' ', dc.definition)", "NULL", "NULL", "0") + `
  FROM sys.default_constraints dc JOIN sys.tables t ON t.object_id = dc.parent_object_id AND t.is_ms_shipped = 0
  JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id`

func schemaObjs(rows []collect.Row) []schemaObj {
	out := make([]schemaObj, 0, len(rows))
	for _, r := range rows {
		s := func(k string) string { v, _ := r[k].(string); return v }
		hb, _ := r["has_body"].(int64)
		out = append(out, schemaObj{kind: s("kind"), schema: s("schema_name"), name: s("object_name"), pschema: s("parent_schema"),
			pname: s("parent_name"), def: s("def"), body: s("body"), owner: s("owner"), hasBody: hb == 1})
	}
	return out
}

// schemaRead is one database's whole read: its rows, its state ('read', 'hashes', 'not readable', 'partial', 'torn')
// and a note, and the server's UTC clock taken before the read.
func schemaRead(ctx context.Context, conn *sql.Conn, db userDB, mode string) (rows []collect.Row, state, note string, readAt time.Time, err error) {
	if err = conn.QueryRowContext(ctx, `SELECT TODATETIMEOFFSET(SYSUTCDATETIME(), 0)`).Scan(&readAt); err != nil {
		return nil, "", "", readAt, err
	}
	before, err := readSchemaFingerprint(ctx, conn, db.quoted)
	if err != nil {
		return nil, "", "", readAt, err
	}
	if !before.viewDefinition {
		return nil, "not readable", "not readable: the login lacks VIEW DEFINITION in this database (GRANT VIEW DEFINITION there, or VIEW ANY DEFINITION on the server); no change is recorded until it can", readAt, nil
	}
	if before.tablesViews > schemaMaxTables {
		return nil, "partial", fmt.Sprintf("not snapshotted: %d tables and views, over the %d one read takes; the stored snapshot is kept", before.tablesViews, schemaMaxTables), readAt, nil
	}
	var objs []schemaObj
	for _, q := range []string{schemaObjectsSQL, schemaColumnsSQL, schemaChildrenSQL} {
		raw, qerr := qsRead(ctx, conn, db.quoted, q, "")
		if qerr != nil {
			return nil, "", "", readAt, qerr
		}
		objs = append(objs, schemaObjs(raw)...)
	}
	after, err := readSchemaFingerprint(ctx, conn, db.quoted)
	if err != nil {
		return nil, "", "", readAt, err
	}
	if !before.same(after) {
		return nil, "torn", "not stored: a schema change came during the read (read again next pass)", readAt, nil
	}
	state = "read"
	rows = schemaRows(db, objs, mode)
	if schemaTextBytes(rows) > schemaMaxText && (mode == "" || mode == "full") {
		rows, state, note = schemaRows(db, objs, "none"), "hashes", "bodies kept as hashes: their text is over 160 MB"
	}
	if schemaTextBytes(rows) > schemaMaxText {
		return nil, "partial", "not snapshotted: over 160 MB of definitions even with bodies as hashes; the stored snapshot is kept", readAt, nil
	}
	return rows, state, note, readAt, nil
}

func schemaRows(db userDB, objs []schemaObj, mode string) []collect.Row {
	rows := make([]collect.Row, 0, len(objs))
	for _, o := range objs {
		rows = append(rows, schemaRow(db, o, mode))
	}
	return rows
}

func schemaTextBytes(rows []collect.Row) int {
	n := 0
	for _, r := range rows {
		d, _ := r["definition"].(string)
		n += len(d)
	}
	return n
}

// schemaNoTrace is the reason this server has no default trace to trust, ” when it may have one (the reader's own
// state, in the repository, says the rest).
func schemaNoTrace(ctx context.Context, conn *sql.Conn, info Info) string {
	if info.Kind == KindAzureDB {
		return "Azure SQL Database has no default trace"
	}
	var on sql.NullInt64
	if err := conn.QueryRowContext(ctx, `SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'default trace enabled'`).Scan(&on); err == nil && on.Valid && on.Int64 == 0 {
		return "the default trace is switched off on this server ('default trace enabled' is 0)"
	}
	return ""
}

// mssqlDBRow is the 'mssql_db' row of one database: its identity, its state and note, and the server's clock of a
// whole read.
func mssqlDBRow(db userDB, state, note string, readAt *time.Time) collect.Row {
	r := collect.Row{"kind": "mssql_db", "database_id": db.id, "name": db.name, "create_date": db.row["created_at"],
		"restored_at": db.row["last_restore"], "state": state, "note": nil}
	if note != "" {
		r["note"] = note
	}
	if readAt != nil {
		r["read_at"] = readAt.UTC()
	}
	return r
}

type schemaDue struct {
	TraceOK  bool    `json:"trace_ok"`
	TraceWhy *string `json:"trace_why"`
	Due      []struct {
		ID     int64  `json:"database_id"`
		Reason string `json:"reason"`
	} `json:"due"`
}

// RunBatches is one pass: the due databases read whole, one batch each; then one batch with every other database of
// the scope ('seen', or its state), their errors, and the run's end.
func (c schemaCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, _ CursorFunc, emit EmitFunc) error {
	if len(opt.SchemaDatabases) == 0 {
		return fmt.Errorf("off on this instance: no mssql_schema.databases in pgvigil.yaml: %w", collect.ErrSkip)
	}
	start := time.Now()
	if _, err := conn.ExecContext(ctx, `SET TRANSACTION ISOLATION LEVEL READ COMMITTED; SET LOCK_TIMEOUT 5000;`); err != nil {
		return err
	}
	all, _, err := userDatabases(ctx, conn, info)
	if err != nil {
		return err
	}
	inScope := schemaInScope(opt.SchemaDatabases)
	var final []collect.Row
	keep := func(db userDB, state, note string, isErr bool) {
		final = append(final, mssqlDBRow(db, state, note, nil), collect.Row{"kind": "seen", "dbid": db.id})
		if isErr {
			final = append(final, collect.Row{"kind": "collector_error", "source": "schema:" + db.name, "message": note})
		}
	}
	var readable []userDB
	for _, db := range all {
		switch {
		case !inScope(db.name):
		case db.secondary:
			keep(db, "secondary", "not read: a secondary replica of an availability group here; its schema is its primary's", false)
		case db.state != "ONLINE":
			st := "offline"
			if strings.EqualFold(db.state, "RESTORING") {
				st = "restoring"
			}
			keep(db, st, "not read: the database is "+strings.ToLower(db.state)+"; its snapshot is kept", false)
		case !db.canEnter:
			keep(db, "no access", "not read: the login cannot enter the database (CONNECT ANY DATABASE, or a user in it, is the missing right); its snapshot is kept", true)
		default:
			readable = append(readable, db)
		}
	}

	// which are due, in the order to read them
	reason := map[int64]string{}
	var order []int64
	if opt.SchemaDue != nil {
		var now time.Time
		if err := conn.QueryRowContext(ctx, `SELECT TODATETIMEOFFSET(SYSUTCDATETIME(), 0)`).Scan(&now); err != nil {
			return err
		}
		list := make([]map[string]any, 0, len(readable))
		for _, db := range readable {
			list = append(list, map[string]any{"database_id": db.id, "name": db.name, "create_date": db.row["created_at"], "restored_at": db.row["last_restore"]})
		}
		b, err := json.Marshal(map[string]any{"now": now.UTC(), "no_trace": schemaNoTrace(ctx, conn, info), "dbs": list})
		if err != nil {
			return err
		}
		raw, err := opt.SchemaDue(ctx, b)
		if err != nil {
			return err
		}
		var d schemaDue
		if err := json.Unmarshal(raw, &d); err != nil {
			return fmt.Errorf("import_mssql_schema_due's reply: %w", err)
		}
		for _, x := range d.Due {
			reason[x.ID] = x.Reason
			order = append(order, x.ID)
		}
	} else {
		for _, db := range readable {
			reason[db.id] = "new"
			order = append(order, db.id)
		}
	}
	byID := map[int64]userDB{}
	for _, db := range readable {
		byID[db.id] = db
	}
	pass := start.Add(schemaPass)
	if !opt.Deadline.IsZero() && opt.Deadline.Before(pass) {
		pass = opt.Deadline
	}
	done := map[int64]bool{}
	for _, id := range order {
		db, ok := byID[id]
		if !ok {
			continue
		}
		done[id] = true
		if ctx.Err() != nil || time.Now().After(pass) {
			keep(db, "seen", "due ("+reason[id]+"), not read this pass: the pass's 5 minutes ran out; the next pass reads it first", false)
			continue
		}
		dctx, cancel := context.WithTimeout(ctx, schemaPerDB)
		rows, state, note, readAt, rerr := schemaRead(dctx, conn, db, opt.QueryText)
		cancel()
		switch {
		case rerr != nil:
			keep(db, "seen", "the read failed ("+reason[id]+"): "+rerr.Error(), true)
		case state == "read" || state == "hashes":
			batch := append([]collect.Row{mssqlDBRow(db, state, note, &readAt),
				{"kind": "db", "dbid": db.id, "datname": db.name, "read_at": readAt.UTC(), "objects": len(rows)}}, rows...)
			if err := emit(batch); err != nil {
				return err
			}
		default:
			keep(db, state, note, state != "torn")
		}
	}
	// every other readable database of the scope: kept as it was
	ids := make([]int64, 0, len(readable))
	for _, db := range readable {
		if !done[db.id] {
			ids = append(ids, db.id)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		keep(byID[id], "seen", "", false)
	}
	final = append(final, collect.Row{"kind": "end"})
	return emit(final)
}
