package mssql

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func TestHADRCollectorsRegistered(t *testing.T) {
	for name, every := range map[string]time.Duration{
		"mssql_ag": time.Minute, "mssql_mirroring": time.Minute, "mssql_logshipping": 5 * time.Minute,
		"mssql_replication": 5 * time.Minute, "mssql_jobs": 5 * time.Minute, "mssql_backups": time.Hour,
	} {
		c, ok := Get(name)
		if !ok {
			t.Errorf("%s is not registered", name)
			continue
		}
		if c.DefaultInterval() != every {
			t.Errorf("%s runs every %v; want %v", name, c.DefaultInterval(), every)
		}
		if !HADRCollections[name] {
			t.Errorf("%s is not one of HADRCollections", name)
		}
	}
	if len(HADRCollections) != 6 {
		t.Errorf("HADRCollections has %d names", len(HADRCollections))
	}
}

// a collection that cannot run says which right or feature is missing
func TestHADRApplies(t *testing.T) {
	full := Info{Kind: KindServer, Major: 16, HADREnabled: true, ViewServerState: true, ViewAnyDefinition: true, MsdbAccess: true}
	with := func(f func(*Info)) Info { i := full; f(&i); return i }
	for _, c := range []struct {
		name string
		info Info
		ok   bool
		why  string
	}{
		{"mssql_ag", full, true, ""},
		{"mssql_ag", with(func(i *Info) { i.HADREnabled = false }), false, "Always On is not enabled"},
		{"mssql_ag", with(func(i *Info) { i.ViewServerState = false }), false, "VIEW SERVER STATE"},
		{"mssql_ag", with(func(i *Info) { i.ViewAnyDefinition = false }), false, "VIEW ANY DEFINITION"},
		{"mssql_ag", with(func(i *Info) { i.Kind = KindAzureDB }), false, "Azure SQL Database"},
		{"mssql_mirroring", with(func(i *Info) { i.ViewServerState = false }), true, ""},
		{"mssql_mirroring", with(func(i *Info) { i.Kind = KindAzureDB }), false, "Azure SQL Database"},
		{"mssql_logshipping", with(func(i *Info) { i.MsdbAccess = false }), false, "msdb"},
		{"mssql_logshipping", with(func(i *Info) { i.Kind = KindRDS }), false, "Amazon RDS"},
		{"mssql_jobs", full, true, ""},
		{"mssql_jobs", with(func(i *Info) { i.MsdbAccess = false }), false, "db_datareader"},
		{"mssql_jobs", with(func(i *Info) { i.Kind = KindAzureDB }), false, "no SQL Server Agent"},
		{"mssql_backups", with(func(i *Info) { i.MsdbAccess = false }), false, "msdb"},
		{"mssql_backups", with(func(i *Info) { i.HADREnabled = false }), true, ""},
		{"mssql_replication", with(func(i *Info) { i.MsdbAccess = false }), true, ""},
	} {
		col, _ := Get(c.name)
		ok, why := col.Applies(c.info)
		if ok != c.ok || !strings.Contains(why, c.why) {
			t.Errorf("%s.Applies(%+v) = %v, %q; want %v and %q", c.name, c.info, ok, why, c.ok, c.why)
		}
	}
}

// a column a version lacks is a typed NULL under the same name, never a reference the server refuses
func TestAgSQLVersionGate(t *testing.T) {
	for _, c := range []struct {
		info                 Info
		clusterType, contain bool
	}{
		{Info{Kind: KindServer, Major: 13}, false, false},
		{Info{Kind: KindServer, Major: 14}, true, false},
		{Info{Kind: KindServer, Major: 15}, true, false},
		{Info{Kind: KindServer, Major: 16}, true, true},
		{Info{Kind: KindRDS, Major: 15}, true, false},
		{Info{Kind: KindAzureMI, Major: 12}, true, true},
	} {
		q := agReplicaSQL(c.info)
		if got := strings.Contains(q, "ag.cluster_type_desc"); got != c.clusterType {
			t.Errorf("major %d %s: cluster_type_desc read = %v", c.info.Major, c.info.Kind, got)
		}
		if got := strings.Contains(q, "ag.required_synchronized_secondaries_to_commit"); got != c.clusterType {
			t.Errorf("major %d %s: required_synchronized_secondaries_to_commit read = %v", c.info.Major, c.info.Kind, got)
		}
		if got := strings.Contains(q, "ag.is_contained"); got != c.contain {
			t.Errorf("major %d %s: is_contained read = %v", c.info.Major, c.info.Kind, got)
		}
		for _, alias := range []string{" AS cluster_type,", " AS is_contained,", " AS required_sync_secondaries,", " AS is_distributed,"} {
			if !strings.Contains(q, alias) {
				t.Errorf("major %d: the statement lacks the column%s", c.info.Major, alias)
			}
		}
	}
}

func TestThresholdRows(t *testing.T) {
	rows, err := ThresholdRows(nil)
	if err != nil || len(rows) != 1 || len(rows[0]) != 0 {
		t.Fatalf("no thresholds: %v %v", rows, err)
	}
	rows, err = ThresholdRows(map[string]any{"log_backup_minutes": 5, "redo_queue_kb": 2048.0, "backup_exclude": []any{"scratch%", "tmp_%"}})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(rows)
	if string(b) != `[{"backup_exclude":["scratch%","tmp_%"],"log_backup_minutes":5,"redo_queue_kb":2048}]` {
		t.Errorf("payload: %s", b)
	}
	for _, bad := range []map[string]any{
		{"log_backup_minute": 5},        // a misspelt name
		{"log_backup_minutes": -1},      // negative
		{"log_backup_minutes": "soon"},  // not a number
		{"backup_exclude": []any{1}},    // not a pattern
		{"backup_exclude": []any{"  "}}, // an empty pattern
		{"backup_exclude": map[string]any{}},
	} {
		if _, err := ThresholdRows(bad); err == nil {
			t.Errorf("accepted: %v", bad)
		}
	}
	if _, err := ThresholdRows(map[string]any{"nope": 1}); err == nil || !strings.Contains(err.Error(), "full_backup_hours") {
		t.Errorf("the refusal of an unknown name does not list the known ones: %v", err)
	}
}

// the defaults the code lists are the defaults the repository applies (the view mssql_hadr_limits of 0066)
func TestThresholdDefaults(t *testing.T) {
	b, err := os.ReadFile("../repo/sql/0066_mssql_hadr.sql")
	if err != nil {
		t.Fatal(err)
	}
	sqlText := string(b)
	for name, def := range HADRThresholds {
		re := regexp.MustCompile(`coalesce\(t\.` + name + `, ([0-9.]+)\)`)
		m := re.FindStringSubmatch(sqlText)
		if m == nil {
			t.Errorf("%s has no default in mssql_hadr_limits", name)
			continue
		}
		if got, _ := strconv.ParseFloat(m[1], 64); got != def {
			t.Errorf("%s: the view's default is %v, the code's %v", name, got, def)
		}
		if !strings.Contains(sqlText, "'"+name+"'") {
			t.Errorf("%s is not in the import function's list of known names", name)
		}
	}
}

func TestJobsCursor(t *testing.T) {
	run := func(ids ...int64) []collect.Row {
		out := []collect.Row{}
		for _, id := range ids {
			out = append(out, collect.Row{"kind": "run", "history_id": id, "mark": id * 7})
		}
		return out
	}
	// where a read starts
	for _, c := range []struct {
		what string
		last int64
		same bool
		want int64
	}{
		{"a first read", 0, false, 0},
		{"the row at the cursor is the row that was read: a little behind it", 5000, true, 5000 - jobHistoryOverlap},
		{"a cursor inside the overlap", 30, true, 0},
		{"msdb replaced, its numbering already PAST the cursor: the mark differs, from the start", 5000, false, 0},
		{"the cursor's row purged while the collector was stopped: from the start of the kept window", 5000, false, 0},
	} {
		if got := jobsReadFrom(c.last, c.same); got != c.want {
			t.Errorf("%s: read from %d; want %d", c.what, got, c.want)
		}
	}
	// what a batch does to the read position and the cursor
	for _, c := range []struct {
		what                         string
		from, next, mark             int64
		runs                         []collect.Row
		wantFrom, wantNext, wantMark int64
	}{
		{"a first batch", 0, 0, 0, run(31, 35, 40), 40, 40, 280},
		{"only the overlap's rows again: the cursor stays, with its mark", 4950, 5000, 35000, run(4990, 5000), 5000, 5000, 35000},
		{"new rows past the cursor", 4950, 5000, 35000, run(4990, 5000, 5003), 5003, 5003, 35021},
		{"nothing read", 4950, 5000, 35000, nil, 4950, 5000, 35000},
		{"after a replaced msdb the cursor moves BACK to what was read", 0, 0, 0, run(3, 12), 12, 12, 84},
	} {
		from, next, mark := jobsAdvance(c.from, c.next, c.mark, c.runs)
		if from != c.wantFrom || next != c.wantNext || mark != c.wantMark {
			t.Errorf("%s: from %d, cursor %d, mark %d; want %d, %d, %d", c.what, from, next, mark, c.wantFrom, c.wantNext, c.wantMark)
		}
	}
	if !strings.Contains(jobHistorySQL(true), "ORDER BY h.instance_id ASC") || !strings.Contains(jobHistorySQL(false), "ORDER BY h.instance_id DESC") {
		t.Error("a cursor read is oldest first, a read without one newest first")
	}
	if !strings.Contains(jobHistorySQL(true), "h.run_status <> 4") {
		t.Error("a step still in progress must not be stored as a finished run")
	}
	// the import stores a row once by msdb's own integers, never by the converted instant (which moves with the
	// server's offset at the read)
	for _, col := range []string{"h.run_date, h.run_time", " AS mark"} {
		if !strings.Contains(jobHistorySQL(true), col) {
			t.Errorf("the history read lacks %q", col)
		}
	}
}

// stubbed rows: a server with nothing hands over an empty JSON array, never null; a read without the counters is partial
func TestMirroringRows(t *testing.T) {
	b, _ := json.Marshal(mirroringRows(nil, true))
	if string(b) != "[]" {
		t.Errorf("no mirrored database: %s", b)
	}
	one := []collect.Row{{"kind": "mirror", "database_name": "sales", "state": "SYNCHRONIZED"}}
	if got := mirroringRows(one, true); len(got) != 1 {
		t.Errorf("with the counters: %v", got)
	}
	got := mirroringRows(one, false)
	if len(got) != 2 || got[1]["kind"] != "collector_error" || !strings.Contains(fmt.Sprint(got[1]["message"]), "VIEW SERVER STATE") {
		t.Errorf("without the counters: %v", got)
	}
	if strings.Contains(mirroringSQL(false), "dm_os_performance_counters") || !strings.Contains(mirroringSQL(true), "dm_os_performance_counters") {
		t.Error("the counters are read only with VIEW SERVER STATE")
	}
	if b, _ := json.Marshal(noRows()); string(b) != "[]" {
		t.Errorf("noRows: %s", b)
	}
}

func TestReplicationText(t *testing.T) {
	if got := quoteName("dist]x"); got != "[dist]]x]" {
		t.Errorf("quoteName: %s", got)
	}
	if got := literal("o'dist"); got != "N'o''dist'" {
		t.Errorf("literal: %s", got)
	}
	r := replNoAccess("distribution")
	if r["kind"] != "collector_error" || !strings.Contains(fmt.Sprint(r["message"]), "db_datareader") || r["source"] != "distribution" {
		t.Errorf("the no-access note: %v", r)
	}
	all := replPublicationsSQL("d") + replSubscriptionsSQL("d") + replAgentsSQL("d") + replDistributorsSQL
	// nothing of replication is ever written or executed: no tracer token, no procedure
	for _, never := range []string{"sp_posttracertoken", "EXEC ", "INSERT ", "UPDATE ", "DELETE ", "sp_replmonitor"} {
		if strings.Contains(strings.ToUpper(all), strings.ToUpper(never)) {
			t.Errorf("the replication read contains %q", never)
		}
	}
}

// no statement of the six collections writes, and none changes the session's settings
func TestHADRStatementsReadOnly(t *testing.T) {
	info := Info{Kind: KindServer, Major: 16, HADREnabled: true, ViewServerState: true}
	for name, q := range hadrStatements(info, "distribution") {
		up := strings.ToUpper(q)
		for _, never := range []string{"INSERT ", "UPDATE ", "DELETE ", "MERGE ", "EXEC ", "EXECUTE ", "CREATE ", "ALTER ", "DROP ", "SET LOCK_TIMEOUT", "SET TRANSACTION", "SET DEADLOCK_PRIORITY", "BACKUP ", "KILL "} {
			if strings.Contains(up, never) {
				t.Errorf("%s contains %q", name, never)
			}
		}
		if !strings.HasPrefix(strings.TrimSpace(up), "SELECT") && !strings.HasPrefix(strings.TrimSpace(up), "WITH") {
			t.Errorf("%s is not a SELECT", name)
		}
	}
}

// hadrStatements is every statement of the six collections, for the tests that walk them all.
func hadrStatements(info Info, distributionDB string) map[string]string {
	return map[string]string{
		"ag replicas": agReplicaSQL(info), "ag databases": agDatabaseSQL, "ag listeners": agListenerSQL, "ag cluster": agClusterSQL,
		"mirroring": mirroringSQL(true), "mirroring without counters": mirroringSQL(false),
		"logshipping primary": logshippingPrimarySQL, "logshipping secondary": logshippingSecondarySQL,
		"replication distributors": replDistributorsSQL, "replication publications": replPublicationsSQL(distributionDB),
		"replication subscriptions": replSubscriptionsSQL(distributionDB), "replication agents": replAgentsSQL(distributionDB),
		"jobs": jobsSQL, "job steps": jobStepsSQL, "job history mark": jobHistoryMarkSQL,
		"job history forward": jobHistorySQL(true), "job history newest": jobHistorySQL(false),
		"backup databases": backupDatabasesSQL(true), "backup databases without groups": backupDatabasesSQL(false),
		"backups": backupsSQL, "backup history": backupHistorySQL,
	}
}

// Every statement against a real server (PGVIGIL_MSSQL_TEST_DSN; nothing is written). The statements that need a
// feature the server lacks are still compiled by it: under SET NOEXEC ON the server parses and binds a batch and
// runs nothing. The replication statements name the database in PGVIGIL_MSSQL_TEST_DISTRIBUTION (a distribution
// database, or a stand-in with tables of the same shape: then they are also RUN and must return its rows);
// without it they are compiled against the name "distribution". proof-mssql-hadr.sh runs this as its login.
func TestHADRStatementsLive(t *testing.T) {
	ctx, conn, info := liveConn(t)
	dist := os.Getenv("PGVIGIL_MSSQL_TEST_DISTRIBUTION")
	name := dist
	if name == "" {
		name = "distribution"
	}
	stmts := hadrStatements(info, name)
	if _, err := conn.ExecContext(ctx, "SET NOEXEC ON"); err != nil {
		t.Fatal(err)
	}
	for what, q := range stmts {
		if strings.Contains(q, "@p1") {
			q = strings.ReplaceAll(q, "@p1", "0")
		}
		if _, err := conn.ExecContext(ctx, q); err != nil {
			t.Errorf("%s does not compile: %v", what, err)
		}
	}
	if _, err := conn.ExecContext(ctx, "SET NOEXEC OFF"); err != nil {
		t.Fatal(err)
	}
	for what, q := range stmts {
		switch {
		case strings.HasPrefix(what, "replication ") && what != "replication distributors" && dist == "":
			continue
		case strings.HasPrefix(what, "ag ") && (!info.HADREnabled || !info.ViewServerState):
			continue
		case what == "mirroring" && !info.ViewServerState:
			continue
		case (strings.HasPrefix(what, "job") || strings.HasPrefix(what, "logshipping") || what == "backups" || what == "backup history") && !info.MsdbAccess:
			continue
		case what == "backup databases" && !info.HADREnabled:
			continue
		}
		var args []any
		if strings.Contains(q, "@p1") {
			args = append(args, int64(0))
		}
		rows, err := QueryRows(ctx, conn, q, args...)
		if err != nil {
			t.Errorf("%s: %v", what, err)
			continue
		}
		if _, err := json.Marshal(rows); err != nil {
			t.Errorf("%s: the rows do not marshal: %v", what, err)
		}
		t.Logf("%s: %d row(s)", what, len(rows))
		if dist != "" && strings.HasPrefix(what, "replication ") && what != "replication distributors" && len(rows) == 0 {
			t.Errorf("%s returned no row from %s", what, dist)
		}
		for _, r := range rows {
			for col, v := range r {
				if s, ok := v.(string); ok && strings.HasSuffix(col, "_utc") && !strings.HasSuffix(s, "Z") {
					t.Errorf("%s.%s = %q: an instant must end in Z", what, col, s)
				}
			}
		}
	}
}

// msdb's integer dates, times and durations, converted by the server
func TestAgentDateTimeLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	rows, err := QueryRows(ctx, conn, "SELECT "+agentDateTime("v.d", "v.t")+" AS dt, "+agentSeconds("v.dur")+" AS secs, "+
		agentDateTime("v.zero", "v.t")+` AS none FROM (SELECT 20261110 AS d, 93005 AS t, 1013020 AS dur, 0 AS zero) v`)
	if err != nil {
		t.Fatal(err)
	}
	if rows[0]["dt"] != "2026-11-10T09:30:05" || rows[0]["secs"] != int64(101*3600+30*60+20) || rows[0]["none"] != nil {
		t.Errorf("got %v", rows[0])
	}
	rows, err = QueryRows(ctx, conn, "SELECT "+utcText("GETDATE()")+" AS now_utc, CONVERT(varchar(33), GETUTCDATE(), 126) AS want, "+utcText("CAST(NULL AS datetime)")+" AS none")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := rows[0]["now_utc"].(string)
	want, _ := rows[0]["want"].(string)
	if len(got) < 17 || len(want) < 16 || got[:16] != want[:16] || !strings.HasSuffix(got, "Z") || rows[0]["none"] != nil {
		t.Errorf("utcText(GETDATE()) = %q; the server's UTC clock says %q; NULL gave %v", got, want, rows[0]["none"])
	}
}

// where a backup went, row by row, decided by the server: a NUL backup, an availability group's seeding stream, and
// the look-alikes that ARE backups (a copy-only snapshot backup through a virtual device, a named copy-only backup
// through one, a plain full backup to one)
func TestBackupSinkLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	rows, err := QueryRows(ctx, conn, `SELECT v.what, `+backupSinkExpr+` AS sink
FROM (VALUES
  ('nul',          'L', 0, 0, CAST(NULL AS nvarchar(128)), 2, N'NUL'),
  ('nul lower',    'D', 0, 0, NULL, 2, N'nul'),
  ('seeding',      'D', 1, 0, NULL, 7, N'{3D2B8CBA-183F-4AD5-BFD5-584770188291}'),
  ('vss copy',     'D', 1, 1, NULL, 7, N'{3D2B8CBA-183F-4AD5-BFD5-584770188291}'),
  ('named vdi',    'D', 1, 0, N'nightly', 7, N'{3D2B8CBA-183F-4AD5-BFD5-584770188291}'),
  ('vdi full',     'D', 0, 0, NULL, 7, N'{3D2B8CBA-183F-4AD5-BFD5-584770188291}'),
  ('vdi log',      'L', 1, 0, NULL, 7, N'{3D2B8CBA-183F-4AD5-BFD5-584770188291}'),
  ('vdi other',    'D', 1, 0, NULL, 7, N'CommVault-stream-1'),
  ('disk',         'D', 1, 0, NULL, 2, N'/backups/a.bak')
) v(what, type, is_copy_only, is_snapshot, name, device_type, physical_device_name)
CROSS APPLY (SELECT v.type AS type, v.is_copy_only AS is_copy_only, v.is_snapshot AS is_snapshot, v.name AS name) bs
CROSS APPLY (SELECT v.device_type AS device_type, v.physical_device_name AS physical_device_name) mf`)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"nul": "nul", "nul lower": "nul", "seeding": "seeding", "vss copy": "backup", "named vdi": "backup",
		"vdi full": "backup", "vdi log": "backup", "vdi other": "backup", "disk": "backup"}
	if len(rows) != len(want) {
		t.Fatalf("%d rows", len(rows))
	}
	for _, r := range rows {
		if what, _ := r["what"].(string); r["sink"] != want[what] {
			t.Errorf("%s: sink %v; want %s", what, r["sink"], want[what])
		}
	}
}

// backupset.time_zone is local time less UTC in 15-minute units: -32 is eight hours behind, 22 is 05:30 ahead, 127
// is unknown (then the server's own offset at the read)
func TestBackupUTCLive(t *testing.T) {
	ctx, conn, _ := liveConn(t)
	rows, err := QueryRows(ctx, conn, `SELECT bs.time_zone, `+backupUTC("bs.d")+` AS utc, `+utcText("bs.d")+` AS by_offset
FROM (VALUES (CAST(-32 AS smallint), CAST('2026-03-01T04:00:00' AS datetime)), (22, '2026-03-01T04:00:00'), (0, '2026-03-01T04:00:00'), (127, '2026-03-01T04:00:00')) bs(time_zone, d)`)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		want := map[int64]string{-32: "2026-03-01T12:00:00Z", 22: "2026-02-28T22:30:00Z", 0: "2026-03-01T04:00:00Z"}[r["time_zone"].(int64)]
		if r["time_zone"] == int64(127) {
			want, _ = r["by_offset"].(string)
		}
		if r["utc"] != want {
			t.Errorf("time_zone %v: %v; want %s", r["time_zone"], r["utc"], want)
		}
	}
}
