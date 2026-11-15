package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/community/kits"
)

// kitsCollector is mssql_kits (KITWATCH K4.3, the design's F14): once a day, the version of each community procedure
// pgvigil runs as it is installed on the server - in master and in the connection's database - read from the
// procedure's DEFINITION: the server cuts three snippets out of OBJECT_DEFINITION (FRK's '@Version = ..., @VersionDate
// = ...' line, DarlingData's '@version_date = ...', sp_WhoIsActive's 'Who Is Active? v...' header) and kits.ParseVersion
// reads them. Nothing of the kits is executed: running the newest, unchecked code unattended on every server is the
// risk KITWATCH watches. A login without VIEW DEFINITION reads 'not readable' (OBJECT_DEFINITION answers NULL), never
// an error; modify_date is kept either way. The Community tools page shows the installed version beside the one
// pgvigil was checked against, and pgvigil.kit_versions_fleet counts the fleet's instances per version.
type kitsCollector struct{}

func init() { Register(kitsCollector{}) }

func (kitsCollector) Name() string                   { return Prefix + "kits" }
func (kitsCollector) DefaultInterval() time.Duration { return 24 * time.Hour }
func (kitsCollector) Applies(Info) (bool, string)    { return true, "" }

// kitVersionsSQL reads the procedures in the database it runs in (the connection's, or master's through
// master.sys.sp_executesql): the name, modify_date, whether the definition is readable and the three snippets
var kitVersionsSQL = `SELECT DB_NAME() AS database_name, o.name AS procedure_name, CONVERT(varchar(33), o.modify_date, 126) AS modify_date,
       CASE WHEN d.def IS NULL THEN 0 ELSE 1 END AS readable,
       SUBSTRING(d.def, NULLIF(PATINDEX(N'%@Version =%', d.def), 0), 120) AS v1,
       SUBSTRING(d.def, NULLIF(PATINDEX(N'%@version[_]date =%', d.def), 0), 40) AS v2,
       SUBSTRING(d.def, NULLIF(PATINDEX(N'%Who Is Active? v%', d.def), 0), 40) AS v3
  FROM sys.procedures o
  CROSS APPLY (SELECT OBJECT_DEFINITION(o.object_id) AS def) d
 WHERE o.schema_id = 1 AND o.name IN (` + kitNames() + `)`

func kitNames() string {
	q := make([]string, len(kits.Tools))
	for i, t := range kits.Tools {
		q[i] = "N'" + t + "'"
	}
	return strings.Join(q, ", ")
}

func (kitsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, kitVersionsSQL)
	if err != nil {
		return nil, fmt.Errorf("the community procedures of the connection's database: %w", err)
	}
	// master too, where the kits are usually installed (an Azure SQL Database has no master to read from here)
	if info.Kind != KindAzureDB {
		m, err := QueryRows(ctx, conn, "EXEC master.sys.sp_executesql N'"+strings.ReplaceAll(kitVersionsSQL, "'", "''")+"'")
		if err != nil {
			return nil, fmt.Errorf("the community procedures of master: %w", err)
		}
		seen := map[string]bool{}
		for _, r := range rows {
			seen[fmt.Sprint(r["database_name"], "/", r["procedure_name"])] = true
		}
		for _, r := range m {
			if !seen[fmt.Sprint(r["database_name"], "/", r["procedure_name"])] {
				rows = append(rows, r)
			}
		}
	}
	return kitVersionPayload(rows), nil
}

// kitVersionPayload is one read's payload: the 'read' row and a 'proc' row per installed procedure (its database, its
// version and date when its definition said them, its modify_date, whether the definition was readable)
func kitVersionPayload(rows []collect.Row) []collect.Row {
	out := []collect.Row{{"kind": "read"}}
	for _, r := range rows {
		var snip []string
		for _, k := range []string{"v1", "v2", "v3"} {
			if s, ok := r[k].(string); ok && s != "" {
				snip = append(snip, s)
			}
		}
		version, date, _ := kits.ParseVersion(strings.Join(snip, "\n"))
		readable, _ := asInt(r["readable"])
		out = append(out, collect.Row{"kind": "proc", "database_name": r["database_name"], "procedure_name": r["procedure_name"],
			"version": version, "version_date": date, "modify_date": fmt.Sprint(r["modify_date"]), "readable": readable == 1})
	}
	return out
}
