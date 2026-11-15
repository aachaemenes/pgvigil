package mssql

import (
	"encoding/json"
	"sort"
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
		"log restores": logRestoreSQL(true), "log restores without counters": logRestoreSQL(false), "log restore pairs": logRestorePairSQL,
		"log shipping config": lsConfigSQL, "log shipping foreign logs": lsForeignSQL,
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
		// a mirror whose values sys.database_mirroring hides from a login that is not sysadmin: read from its counters
		if !strings.Contains(q, " AS values_hidden,") || !strings.Contains(q, "COALESCE(m.mirroring_role_desc, N'MIRROR')") {
			t.Errorf("counters %v: the statement lacks values_hidden or the MIRROR role of a hidden mirror", with)
		}
		if strings.Contains(q, "m.mirroring_guid IS NULL AND d.state = 1 AND c.redo_queue_kb IS NOT NULL AND IS_SRVROLEMEMBER('sysadmin') = 0") != with {
			t.Errorf("counters %v: a hidden mirror is read = %v", with, !with)
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
		for _, with := range []bool{true, false} {
			if !strings.Contains(logRestoreSQL(with), want) {
				t.Errorf("counters %v: the restore-history read lacks %q", with, want)
			}
		}
	}
	// a mirror a login that is not sysadmin sees with NULL values is still mirrored, by its counter instance; for a
	// sysadmin a NULL row is the answer
	if !strings.Contains(logRestoreSQL(true), "m.mirroring_guid IS NOT NULL OR (IS_SRVROLEMEMBER('sysadmin') = 0 AND EXISTS (SELECT 1 FROM sys.dm_os_performance_counters pc") ||
		!strings.Contains(logRestoreSQL(true), "'%:Database Mirroring%' AND RTRIM(pc.instance_name) = d.name") {
		t.Error("with VIEW SERVER STATE the restore-history read does not take a mirror from its counter instance (not sysadmin only)")
	}
	// without it, and not sysadmin, a RESTORING database is unknown (NULL), never 'not mirrored'
	if strings.Contains(logRestoreSQL(false), "dm_os_performance_counters") ||
		!strings.Contains(logRestoreSQL(false), "WHEN IS_SRVROLEMEMBER('sysadmin') = 1 OR d.state <> 1 THEN 0 END") {
		t.Error("without VIEW SERVER STATE the restore-history read reads the counters, or calls an unclassifiable database not mirrored")
	}
	// restorehistory has no index on the destination: one pass per list, never a scan per database
	for _, with := range []bool{true, false} {
		q := logRestoreSQL(with)
		if strings.Count(q, "ROW_NUMBER() OVER (PARTITION BY rh.destination_database_name") != 2 || strings.Contains(q, "OUTER APPLY") {
			t.Errorf("counters %v: the restore-history read is not one pass per list", with)
		}
	}
	if !strings.Contains(logRestorePairSQL, "x.log_restores, CAST(x.recovery AS int) AS last_with_recovery") {
		t.Error("a pair row does not carry its restore count and whether the newest was WITH RECOVERY")
	}
	if !strings.Contains(logRestorePairSQL, "DB_ID(x.destination_database_name) IS NULL") {
		t.Error("a pair row is not only for a destination that is gone")
	}
}

// the configuration read names every job of a log shipping setup with what the repository judges (existence, enabled,
// the schedules that still run it and their shortest interval); the foreign-log read takes only this server's own log
// backups that are not copy-only, of the last 24 hours, and judges them by the one shared fragment
func TestLogShippingExtrasText(t *testing.T) {
	for _, want := range []string{"msdb.dbo.log_shipping_primary_databases p", "msdb.dbo.log_shipping_secondary_databases sd",
		"msdb.dbo.log_shipping_monitor_alert a", "p.backup_job_id AS job_id", "s.copy_job_id), (CAST('restore' AS varchar(10)), s.restore_job_id)",
		"a.alert_job_id AS job_id", " AS job_exists,", " AS job_enabled,", " AS enabled_schedules,", " AS interval_min",
		"d.recovery_model_desc", "CAST(sd.restore_mode AS int)", "d.database_id = DB_ID(p.primary_database)"} {
		if !strings.Contains(lsConfigSQL, want) {
			t.Errorf("the configuration read lacks %q", want)
		}
	}
	if strings.Count(lsConfigSQL, "LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = x.job_id") != 3 {
		t.Error("a job the configuration names must be read by LEFT JOIN in each of the three arms (a deleted job is a row, job_exists 0)")
	}
	// a schedule counts only while it still runs the job: enabled, repeating, not ended - in the count AND in the
	// interval of each of the three arms (six subqueries); one of them without it would count a disabled schedule
	if n := strings.Count(lsConfigSQL, lsScheduleRuns); n != 6 {
		t.Errorf("the schedule rule is in %d of the 6 schedule subqueries", n)
	}
	for _, want := range []string{"ss.enabled = 1", "ss.freq_type IN (4, 8, 16, 32)", "ss.active_end_date >= CONVERT(int, CONVERT(char(8), GETDATE(), 112))"} {
		if !strings.Contains(lsScheduleRuns, want) {
			t.Errorf("the schedule rule lacks %q", want)
		}
	}
	// seconds, minutes and hours become minutes; anything else has no interval
	if !strings.Contains(lsJobColumns, "WHEN 2 THEN ss.freq_subday_interval / 60.0 WHEN 4 THEN ss.freq_subday_interval * 1.0") ||
		!strings.Contains(lsJobColumns, "WHEN 8 THEN ss.freq_subday_interval * 60.0 END) AS float)") {
		t.Error("the interval is not seconds / 60, minutes, hours * 60 as a float")
	}
	for _, want := range []string{"bs.type = 'L' AND bs.is_copy_only = 0", "DATEADD(hour, -24, GETDATE())",
		"bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))",
		"mf.physical_device_name AS file_name, p.backup_directory, p.backup_share", " AS started_utc,", " AS finished_utc",
		") mf) x" + lsForeignWhere} {
		if !strings.Contains(lsForeignSQL, want) {
			t.Errorf("the foreign-log read lacks %q", want)
		}
	}
	// each part is its own read: a failure is a collector_error of its source, which the repository's import keys on
	if len(lsParts) != 2 || lsParts[0].source != "log shipping configuration" || lsParts[1].source != "log shipping foreign log backups" {
		t.Errorf("the parts' sources changed: %+v (0143's import keeps a part's stored rows by these names)", lsParts)
	}
}

// lsPathCases: a file, the configuration's folder and share, the database - and whether the file is foreign to log
// shipping. Windows shapes (a local folder, a UNC share named unlike the folder, devices that are no file) and Linux
// ones (SQL Server's own log shipping there joins the folder and the file with a backslash: seen on a real pair).
var lsPathCases = []struct {
	label, file, dir, share, db string
	foreign                     bool
}{
	{"own: in the local folder", `D:\LS\db1_20261115101500.trn`, `D:\LS`, `\\SRV\LSShare`, "db1", false},
	{"own: the folder given with a trailing separator", `D:\LS\x.trn`, `D:\LS\`, ``, "db1", false},
	{"own: the folder given with a trailing space", `D:\LS\x.trn`, `D:\LS `, ``, "db1", false},
	{"own: the folder given with a separator and a space", `D:\LS\x.trn`, `D:\LS\ `, ``, "db1", false},
	{"own: written through the share, named unlike the folder", `\\SRV\LSShare\x.trn`, `D:\LS`, `\\SRV\LSShare`, "db1", false},
	{"own: another case", `d:\ls\X.TRN`, `D:\LS`, ``, "db1", false},
	{"own: Linux, the folder and the file joined by a backslash", `/var/opt/mssql/ship/lsw\lsw_20261115194351.trn`, `/var/opt/mssql/ship/lsw`, `/var/opt/mssql/ship/lsw`, "lsw", false},
	{"own: Linux, forward slashes only", `/var/opt/mssql/ship/lsw/x.trn`, `/var/opt/mssql/ship/lsw/`, ``, "lsw", false},
	{"own: log shipping's own name in the folder it had before a move", `D:\OLD\db1_20261115093000.trn`, `E:\LS`, `\\SRV\LS`, "db1", false},
	{"own: its own name, the database's name holding LIKE wildcards", `X:\o\a_b%c_20261115093000.trn`, `E:\LS`, ``, "a_b%c", false},
	{"own (a known miss): another job writing below the folder", `D:\LS\SRV\db1\LOG\x.trn`, `D:\LS`, ``, "db1", false},
	{"foreign: a sibling folder that starts with the folder's name", `D:\LS2\x.trn`, `D:\LS`, ``, "db1", true},
	{"foreign: another folder, another name", `D:\Backup\db1_backup_2026_11_15_093000.trn`, `E:\LS`, `\\SRV\LS`, "db1", true},
	{"foreign: 13 digits", `D:\OLD\db1_2026111509300.trn`, `E:\LS`, ``, "db1", true},
	{"foreign: 14 characters that are not all digits", `D:\OLD\db1_2026111509300x.trn`, `E:\LS`, ``, "db1", true},
	{"foreign: another database's own name", `D:\OLD\db2_20261115093000.trn`, `E:\LS`, ``, "db1", true},
	{"foreign: the underscore of the database's name is no wildcard", `X:\o\aXb%c_20261115093000.trn`, `E:\LS`, ``, "a_b%c", true},
	{"foreign: its own name with another extension", `D:\OLD\db1_20261115093000.bak`, `E:\LS`, ``, "db1", true},
	{"foreign: the NUL device", `NUL`, `D:\LS`, ``, "db1", true},
	{"foreign: a virtual device", `{6F9619FF-8B86-D011-B42D-00C04FC964FF}`, `D:\LS`, ``, "db1", true},
	{"foreign: a URL", `https://account.blob.core.windows.net/logs/db1.trn`, `D:\LS`, ``, "db1", true},
	{"foreign: no media family", "\x00", `D:\LS`, ``, "db1", true}, // \x00 = a NULL file name
	{"not judged: a configuration with no folder", `D:\Backup\x.trn`, ``, `\\SRV\LS`, "db1", false},
	{"not judged: a folder of spaces", `D:\Backup\x.trn`, `  `, ``, "db1", false},
}

// TestLogShippingForeignPathsLive runs lsForeignWhere - the fragment lsForeignSQL ends with, as it is - over
// lsPathCases on a real server (PGVIGIL_MSSQL_TEST_DSN; nothing is written or read from msdb: the rows are a VALUES
// list). scripts/proof-mssql-logshipping.sh runs it against its primary.
func TestLogShippingForeignPathsLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	lit := func(v string) string {
		if v == "\x00" {
			return "CAST(NULL AS nvarchar(500))"
		}
		return "CAST(N'" + strings.ReplaceAll(v, "'", "''") + "' AS nvarchar(500))"
	}
	var values, want []string
	for _, c := range lsPathCases {
		values = append(values, "("+lit(c.label)+", "+lit(c.file)+", "+lit(c.dir)+", "+lit(c.share)+", "+lit(c.db)+")")
		if c.foreign {
			want = append(want, c.label)
		}
	}
	q := "SELECT x.label FROM (VALUES " + strings.Join(values, ",\n ") + ") x (label, file_name, backup_directory, backup_share, database_name)" + lsForeignWhere
	rows, err := QueryRows(ctx, conn, q)
	if err != nil {
		t.Fatalf("%v\n%s", err, q)
	}
	var got []string
	for _, r := range rows {
		got = append(got, r["label"].(string))
	}
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		isIn := func(list []string, v string) bool {
			for _, x := range list {
				if x == v {
					return true
				}
			}
			return false
		}
		for _, c := range lsPathCases {
			if isIn(got, c.label) != c.foreign {
				t.Errorf("%q: read as foreign = %v, want %v (file %q, folder %q, share %q, database %q)", c.label, !c.foreign, c.foreign, c.file, c.dir, c.share, c.db)
			}
		}
	}
	t.Logf("%d cases: %d foreign, %d own or not judged", len(lsPathCases), len(got), len(lsPathCases)-len(got))
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
		case (what == "mirroring" || what == "log restores" || strings.HasPrefix(what, "fci")) && !info.ViewServerState:
			continue
		case (strings.HasPrefix(what, "log restore") || strings.HasPrefix(what, "log shipping")) && !info.MsdbAccess:
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
