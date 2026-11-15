package mssql

import (
	"strings"
	"testing"
	"time"
)

// mssql_georepl (task 390a G1): Azure SQL Database's active geo-replication links as the database itself sees them.
func TestGeoReplApplies(t *testing.T) {
	c, ok := Get(Prefix + "georepl")
	if !ok {
		t.Fatal("mssql_georepl is not registered")
	}
	cases := []struct {
		what string
		info Info
		ok   bool
		why  string
	}{
		{"Azure SQL Database with VIEW DATABASE STATE", Info{Kind: KindAzureDB, ViewDatabaseState: true}, true, ""},
		{"Azure SQL Database without it", Info{Kind: KindAzureDB}, false, "VIEW DATABASE STATE"},
		{"a server", Info{Kind: KindServer, ViewDatabaseState: true, ViewServerState: true}, false, "Azure SQL Database"},
		{"Managed Instance", Info{Kind: KindAzureMI, ViewDatabaseState: true, ViewServerState: true}, false, "Managed Instance"},
	}
	for _, x := range cases {
		got, why := c.Applies(x.info)
		if got != x.ok || !strings.Contains(why, x.why) {
			t.Errorf("%s: Applies = %v %q, want %v containing %q", x.what, got, why, x.ok, x.why)
		}
	}
	if d := c.(interface{ DefaultInterval() time.Duration }).DefaultInterval(); d != time.Minute {
		t.Errorf("interval %v, want a minute (as mssql_ag)", d)
	}
}

// The read names all twelve columns of sys.dm_geo_replication_link_status, the acknowledgement's age computed on
// the server, the logical server and database the read reached, and every time in UTC.
func TestGeoReplSQL(t *testing.T) {
	for _, col := range []string{"link_guid", "partner_server", "partner_database", "last_replication", "replication_lag_sec",
		"replication_state", "replication_state_desc", "role", "role_desc", "secondary_allow_connections",
		"secondary_allow_connections_desc", "last_commit", "ack_age_s", "@@SERVERNAME", "DB_NAME()", "SWITCHOFFSET"} {
		if !strings.Contains(georeplSQL, col) {
			t.Errorf("the read lacks %s", col)
		}
	}
	if !strings.Contains(georeplSQL, "FROM sys.dm_geo_replication_link_status") {
		t.Error("the read is not sys.dm_geo_replication_link_status")
	}
}

// A read always hands over its 'read' row first (the server and database reached), so a database with no link
// stores 'no link' and a link that is gone is told apart from a read that did not happen.
func TestGeoReplRows(t *testing.T) {
	rows := georeplRows([]map[string]any{{"server_read": "pgv-a", "database_name": "db1"}}, nil)
	if len(rows) != 1 || rows[0]["kind"] != "read" || rows[0]["links"] != 0 || rows[0]["server_read"] != "pgv-a" {
		t.Fatalf("no link: %v", rows)
	}
	links := []map[string]any{{"link_guid": "g1", "role": int64(0), "server_read": "pgv-a", "database_name": "db1",
		"replication_lag_sec": int64(3), "last_commit": "2026-11-14T10:00:05.0000000Z", "last_replication": "2026-11-14T10:00:01.0000000Z"}}
	rows = georeplRows(links, links)
	if len(rows) != 2 || rows[0]["kind"] != "read" || rows[0]["links"] != 1 || rows[1]["kind"] != "link" || rows[1]["link_guid"] != "g1" {
		t.Fatalf("one link: %v", rows)
	}
	if rows[1]["unsent_s"] != 4.0 {
		t.Errorf("unsent window = %v, want 4 (last_commit - last_replication on the primary)", rows[1]["unsent_s"])
	}
	sec := []map[string]any{{"link_guid": "g1", "role": int64(1), "last_commit": "2026-11-14T10:00:05Z", "last_replication": nil}}
	if r := georeplRows(sec, sec); r[1]["unsent_s"] != nil {
		t.Errorf("a secondary's unsent window = %v, want none (Microsoft: lag on the primary only)", r[1]["unsent_s"])
	}
}
