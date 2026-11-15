package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// georeplCollector is mssql_georepl (task 390a G1): an Azure SQL Database's active geo-replication links, read in the
// database itself from sys.dm_geo_replication_link_status (Microsoft: a row for each link "between primary and
// secondary databases ... This includes both primary and secondary databases"; empty in master; VIEW DATABASE STATE
// in the database). The lag and last_replication are "available on the primary database only"; last_commit is the
// primary's last commit on the primary and the secondary's own on a secondary. A link removed by deleting the
// secondary "disappears" from the view. DBA Dash reads none of this (4.25.0).
//
// Every read hands over a 'read' row first - the logical server and the database the connection reached (behind a
// failover group's listener the server changes at a failover while the configured name does not) and the number of
// links - so a database with no link stores 'no link' and a link that is gone is told from a read that did not
// happen. The acknowledgement's age (now - last_replication) is computed on the server, so the collector's clock
// plays no part. Managed Instance (the same view, per database) is not read here: not in 390a.
type georeplCollector struct{}

func init() { Register(georeplCollector{}) }

func (georeplCollector) Name() string                   { return Prefix + "georepl" }
func (georeplCollector) DefaultInterval() time.Duration { return time.Minute }
func (georeplCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureMI:
		return false, "a Managed Instance's geo-replication (per database) is not read yet"
	case info.Kind != KindAzureDB:
		return false, "active geo-replication (sys.dm_geo_replication_link_status) is Azure SQL Database's"
	case !info.ViewDatabaseState:
		return false, "the login lacks VIEW DATABASE STATE: sys.dm_geo_replication_link_status is not readable"
	}
	return true, ""
}

// georeplUTC: a datetimeoffset as UTC text (the view's times carry the primary's offset)
func georeplUTC(col string) string {
	return isUTCText("CAST(SWITCHOFFSET(" + col + ", '+00:00') AS datetime2(7))")
}

// georeplSQL: all twelve columns of the view, the acknowledgement's age in seconds on the server's clock, and the
// server and database the connection reached (one row even with no link: the LEFT JOIN to the one-row read).
var georeplSQL = `SELECT CAST(@@SERVERNAME AS nvarchar(256)) AS server_read, CAST(DB_NAME() AS nvarchar(128)) AS database_name,
  CAST(l.link_guid AS nvarchar(36)) AS link_guid,
  CAST(l.partner_server AS nvarchar(256)) AS partner_server, CAST(l.partner_database AS nvarchar(256)) AS partner_database,
  CAST(l.role AS int) AS role, CAST(l.role_desc AS nvarchar(60)) AS role_desc,
  CAST(l.replication_state AS int) AS replication_state, CAST(l.replication_state_desc AS nvarchar(60)) AS replication_state_desc,
  l.replication_lag_sec,
  ` + georeplUTC("l.last_replication") + ` AS last_replication,
  ` + georeplUTC("l.last_commit") + ` AS last_commit,
  CAST(l.secondary_allow_connections AS int) AS secondary_allow_connections,
  CAST(l.secondary_allow_connections_desc AS nvarchar(60)) AS secondary_allow_connections_desc,
  DATEDIFF(second, l.last_replication, SYSDATETIMEOFFSET()) AS ack_age_s
FROM (SELECT 1 AS one) r
LEFT JOIN sys.dm_geo_replication_link_status l ON 1 = 1
ORDER BY l.partner_server, l.partner_database`

func (georeplCollector) Run(ctx context.Context, conn *sql.Conn, _ Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, georeplSQL)
	if err != nil {
		return nil, err
	}
	links := make([]map[string]any, 0, len(rows))
	all := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		all = append(all, r)
		if r["link_guid"] != nil {
			links = append(links, r)
		}
	}
	return georeplRows(all, links), nil
}

// georeplRows: the 'read' row (from the first row read: the server and database are on every row) and one 'link'
// row per link, with the unsent window on a primary (last_commit - last_replication, both on the primary's clock;
// none when either is missing or on a secondary, whose last_replication Microsoft leaves to the primary).
func georeplRows(all, links []map[string]any) []collect.Row {
	read := collect.Row{"kind": "read", "links": len(links)}
	if len(all) > 0 {
		read["server_read"], read["database_name"] = all[0]["server_read"], all[0]["database_name"]
	}
	out := []collect.Row{read}
	for _, l := range links {
		row := collect.Row{"kind": "link"}
		for k, v := range l {
			if k != "server_read" && k != "database_name" {
				row[k] = v
			}
		}
		row["unsent_s"] = nil
		if role, ok := l["role"].(int64); ok && role == 0 {
			row["unsent_s"] = unsentSeconds(l["last_commit"], l["last_replication"])
		}
		out = append(out, row)
	}
	return out
}

// unsentSeconds: last_commit - last_replication in seconds (0 when the acknowledgement is newer), nil without both
func unsentSeconds(commit, repl any) any {
	c, ok1 := parseUTCText(commit)
	r, ok2 := parseUTCText(repl)
	if !ok1 || !ok2 {
		return nil
	}
	d := c.Sub(r).Seconds()
	if d < 0 {
		d = 0
	}
	return d
}

func parseUTCText(v any) (time.Time, bool) {
	s, ok := v.(string)
	if !ok || s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	return t, err == nil
}
