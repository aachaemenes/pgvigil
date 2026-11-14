package mssql

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// hadrS3Statements is every statement the HA depth work (mirroring, availability group gaps, log shipping from
// restore history, the failover cluster instance) added or changed.
func hadrS3Statements(info Info) map[string]string {
	return map[string]string{
		"ag replicas": agReplicaSQL(info), "ag databases": agDatabaseSQL, "ag database cluster": agDatabaseClusterSQL,
		"ag routing": agRoutingSQL, "ag seeding": agSeedingSQL, "ag endpoint": agEndpointSQL, "ag counters": agCountersSQL,
		"ag health session": agHealthSessionSQL,
		"mirroring":         mirroringSQL(true), "mirroring without counters": mirroringSQL(false), "mirroring endpoint": mirroringEndpointSQL,
		"log restores": logRestoreSQL, "log restore pairs": logRestorePairSQL,
		"fci flag": fciFlagSQL, "fci nodes": fciNodesSQL,
	}
}

// nothing the work added writes or changes the session
func TestHADRS3StatementsReadOnly(t *testing.T) {
	info := Info{Kind: KindServer, Major: 16, HADREnabled: true, ViewServerState: true, ViewAnyDefinition: true}
	for name, q := range hadrS3Statements(info) {
		up := strings.ToUpper(q)
		for _, never := range []string{"INSERT ", "UPDATE ", "DELETE ", "MERGE ", "EXEC ", "EXECUTE ", "CREATE ", "ALTER ", "DROP ",
			"SET LOCK_TIMEOUT", "SET TRANSACTION", "SET DEADLOCK_PRIORITY", "BACKUP ", "RESTORE ", "KILL ", "DBCC "} {
			if strings.Contains(up, never) {
				t.Errorf("%s contains %q", name, never)
			}
		}
		if s := strings.TrimSpace(up); !strings.HasPrefix(s, "SELECT") && !strings.HasPrefix(s, "WITH") {
			t.Errorf("%s is not a SELECT", name)
		}
	}
}

// the mirroring read carries the role sequence (a swap between two reads) and the cumulative counters with their
// types; without VIEW SERVER STATE the counters are typed NULLs under the same names
func TestMirroringS3Columns(t *testing.T) {
	for _, with := range []bool{true, false} {
		q := mirroringSQL(with)
		for _, alias := range []string{" AS role_sequence,", " AS state_code,", " AS database_state,", " AS log_bytes_sent_total", " AS redo_bytes_total",
			" AS txn_delay_ms_total", " AS mirrored_write_txns_total", " AS log_bytes_sent_type", " AS txn_delay_type", " AS mirrored_write_txns_type"} {
			if !strings.Contains(q, alias) {
				t.Errorf("counters %v: the statement lacks%s", with, alias)
			}
		}
		if strings.Contains(q, "dm_os_performance_counters") != with {
			t.Errorf("counters %v: the performance counters are read = %v", with, !with)
		}
	}
}

// the failover cluster read: only a server someone runs, with VIEW SERVER STATE; only the flag's value 1 reads nodes
func TestFCIApplies(t *testing.T) {
	c, ok := Get("mssql_fci")
	if !ok {
		t.Fatal("mssql_fci is not registered")
	}
	if c.DefaultInterval() != time.Minute {
		t.Errorf("mssql_fci runs every %v", c.DefaultInterval())
	}
	if HADRCollections["mssql_fci"] {
		t.Error("mssql_fci reads no threshold of mssql_hadr_thresholds")
	}
	full := Info{Kind: KindServer, Major: 16, ViewServerState: true}
	for _, x := range []struct {
		info Info
		ok   bool
		why  string
	}{
		{full, true, ""},
		{Info{Kind: KindServer, Major: 16}, false, "VIEW SERVER STATE"},
		{Info{Kind: KindRDS, Major: 15, ViewServerState: true}, false, "managed service"},
		{Info{Kind: KindAzureMI, Major: 12, ViewServerState: true}, false, "managed service"},
		{Info{Kind: KindAzureDB, Major: 12, ViewServerState: true}, false, "managed service"},
		{Info{Kind: KindCloudSQL, Major: 16, ViewServerState: true}, false, "managed service"},
	} {
		ok, why := c.Applies(x.info)
		if ok != x.ok || !strings.Contains(why, x.why) {
			t.Errorf("Applies(%+v) = %v, %q; want %v and %q", x.info, ok, why, x.ok, x.why)
		}
	}
	for _, x := range []struct {
		rows []collect.Row
		want bool
	}{
		{nil, false},
		{[]collect.Row{{"is_clustered": int64(0)}}, false},
		{[]collect.Row{{"is_clustered": int64(1)}}, true},
		{[]collect.Row{{"is_clustered": nil}}, false},
		{[]collect.Row{{"is_clustered": int64(1)}, {"is_clustered": int64(1)}}, false},
	} {
		if got := fciClustered(x.rows); got != x.want {
			t.Errorf("fciClustered(%v) = %v", x.rows, got)
		}
	}
}

// the restore-history read leaves the system databases and snapshots out, keeps the mirror / group flags for the
// repository, and converts the primary's clock by backupset.time_zone (127 = unknown)
func TestLogRestoreText(t *testing.T) {
	for _, want := range []string{"d.database_id > 4", "d.source_database_id IS NULL", "rh.restore_type = 'L'",
		"DATEADD(day, -14, GETDATE())", "lr.time_zone = 127", "DATEADD(minute, -15 * lr.time_zone, lr.backup_start_date)",
		" AS is_mirrored,", " AS in_availability_group,", "d.state = 1 OR d.is_in_standby = 1"} {
		if !strings.Contains(logRestoreSQL, want) {
			t.Errorf("the restore-history read lacks %q", want)
		}
	}
	if !strings.Contains(logRestorePairSQL, "DB_ID(x.destination_database_name) IS NULL") {
		t.Error("a pair row is not only for a destination that is gone")
	}
}

// Every statement of the work against a real server (PGVIGIL_MSSQL_TEST_DSN; nothing is written): compiled under
// SET NOEXEC ON whatever the server has, then run where its feature and the login's rights allow; every instant ends
// in Z. scripts/proof-mssql-hadr.sh (part S), proof-mssql-mirroring.sh and proof-mssql-logshipping.sh run this as
// their monitoring login.
func TestHADRS3StatementsLive(t *testing.T) {
	ctx, conn, info := liveConn(t)
	stmts := hadrS3Statements(info)
	if _, err := conn.ExecContext(ctx, "SET NOEXEC ON"); err != nil {
		t.Fatal(err)
	}
	for what, q := range stmts {
		if _, err := conn.ExecContext(ctx, q); err != nil {
			t.Errorf("%s does not compile: %v", what, err)
		}
	}
	if _, err := conn.ExecContext(ctx, "SET NOEXEC OFF"); err != nil {
		t.Fatal(err)
	}
	for what, q := range stmts {
		switch {
		case strings.HasPrefix(what, "ag ") && (!info.HADREnabled || !info.ViewServerState):
			continue
		case (what == "mirroring" || strings.HasPrefix(what, "fci")) && !info.ViewServerState:
			continue
		case strings.HasPrefix(what, "log restore") && !info.MsdbAccess:
			continue
		}
		rows, err := QueryRows(ctx, conn, q)
		if err != nil {
			t.Errorf("%s: %v", what, err)
			continue
		}
		if _, err := json.Marshal(rows); err != nil {
			t.Errorf("%s: the rows do not marshal: %v", what, err)
		}
		t.Logf("%s: %d row(s)", what, len(rows))
		for _, r := range rows {
			for col, v := range r {
				if s, ok := v.(string); ok && strings.HasSuffix(col, "_utc") && !strings.HasSuffix(s, "Z") {
					t.Errorf("%s.%s = %q: an instant must end in Z", what, col, s)
				}
			}
		}
	}
}
