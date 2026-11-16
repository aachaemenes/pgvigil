package mssql

// Task 407 (B13 storage depth): its own test file, so no other branch's edit of storage_test.go meets it.

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

func TestStorageDepthCollectorsRegistered(t *testing.T) {
	for name, want := range map[string]time.Duration{"mssql_storage_depth": time.Hour, "mssql_tables": 6 * time.Hour} {
		c, ok := Get(name)
		if !ok {
			t.Fatalf("%s is not registered", name)
		}
		if c.DefaultInterval() != want {
			t.Errorf("%s: interval %v, want %v (on by default)", name, c.DefaultInterval(), want)
		}
	}
	if runTimeout(tablesCollector{}) != 10*time.Minute {
		t.Errorf("mssql_tables: the run's deadline is %v", runTimeout(tablesCollector{}))
	}
}

// Each new collection has its own Applies: never on Azure SQL Database, VIEW SERVER STATE (or 2022's VIEW SERVER
// PERFORMANCE STATE, asked in the run) and VIEW ANY DEFINITION.
func TestStorageDepthApplies(t *testing.T) {
	full := Info{Kind: KindServer, Major: 16, ViewServerState: true, ViewAnyDefinition: true}
	for _, c := range []struct {
		name         string
		info         Info
		depth, table bool
		why          string
	}{
		{"full rights", full, true, true, ""},
		{"Azure SQL Database", Info{Kind: KindAzureDB, ViewServerState: true, ViewAnyDefinition: true}, false, false, "Azure SQL Database"},
		{"2019 without VIEW SERVER STATE", Info{Kind: KindServer, Major: 15, ViewAnyDefinition: true}, false, false, "VIEW SERVER STATE"},
		// 2022: VIEW SERVER PERFORMANCE STATE is asked in the run (perfState), so the collections apply
		{"2022 without VIEW SERVER STATE", Info{Kind: KindServer, Major: 16, ViewAnyDefinition: true}, true, true, ""},
		// the paths and drives need no VIEW ANY DEFINITION (the orphan list says so in its note); the tables do
		{"without VIEW ANY DEFINITION", Info{Kind: KindServer, Major: 16, ViewServerState: true}, true, false, "VIEW ANY DEFINITION"},
	} {
		for _, x := range []struct {
			col  Collector
			want bool
		}{{storageDepthCollector{}, c.depth}, {tablesCollector{}, c.table}} {
			ok, why := x.col.Applies(c.info)
			if ok != x.want || (!ok && c.why != "" && !strings.Contains(why, c.why)) {
				t.Errorf("%s, %s: got %v %q", x.col.Name(), c.name, ok, why)
			}
		}
	}
}

func TestUsedStatementAndSpaceRow(t *testing.T) {
	if usedStatement(Info{ViewServerState: true, ViewAnyDefinition: true}, true) != usedSpaceSQL {
		t.Error("the space split is not read with both rights")
	}
	if usedStatement(Info{ViewAnyDefinition: true}, false) != usedSQL {
		t.Error("a login without VIEW SERVER STATE must keep 0067's statement (no partition stats)")
	}
	db := dbRef{id: 5, name: "sales", quoted: "[sales]"}
	if spaceRow(db, []collect.Row{{"file_id": int64(1)}}) != nil {
		t.Error("a read without the split gives no space row")
	}
	r := spaceRow(db, []collect.Row{{"file_id": int64(1), "reserved_kb": int64(800), "used_kb": int64(640), "data_kb": int64(512)},
		{"file_id": int64(2), "reserved_kb": int64(800), "used_kb": int64(640), "data_kb": int64(512)}})
	if r == nil || r["kind"] != "space" || r["database_name"] != "sales" || r["reserved_kb"] != int64(800) || r["data_kb"] != int64(512) {
		t.Errorf("space row: %v", r)
	}
}

func TestCompressionAndTableRow(t *testing.T) {
	for _, c := range []struct {
		row  collect.Row
		want string
	}{
		{collect.Row{"c_none": int64(1)}, "NONE"},
		{collect.Row{"c_page": int64(4)}, "PAGE"},
		{collect.Row{"c_row": int64(3), "c_page": int64(9), "c_none": int64(0)}, "mixed: ROW 3, PAGE 9"},
		{collect.Row{"c_cs": int64(1)}, "COLUMNSTORE"},
		{collect.Row{}, ""},
	} {
		if got := compressionText(c.row); got != c.want {
			t.Errorf("%v: %q, want %q", c.row, got, c.want)
		}
	}
	disk := tableRow("db1", collect.Row{"schema_name": "dbo", "table_name": "t", "table_type": "clustered", "parts": int64(1), "c_page": int64(1),
		"row_count": int64(10), "reserved_kb": int64(144), "used_kb": int64(136), "data_kb": int64(96)})
	if disk["index_kb"] != int64(40) || disk["compression"] != "PAGE" || disk["database_name"] != "db1" {
		t.Errorf("disk table: %v", disk)
	}
	mem := tableRow("db1", collect.Row{"schema_name": "dbo", "table_name": "m", "table_type": "memory-optimized", "row_count": int64(10),
		"reserved_kb": int64(0), "used_kb": int64(0), "data_kb": int64(0), "xtp_allocated_kb": int64(2048), "xtp_used_kb": int64(1500), "xtp_table_used_kb": int64(1000)})
	if mem["reserved_kb"] != int64(2048) || mem["used_kb"] != int64(1500) || mem["data_kb"] != int64(1000) || mem["index_kb"] != int64(500) {
		t.Errorf("memory-optimized table: %v", mem)
	}
}

func TestRotateFromAndFileNames(t *testing.T) {
	rows := []collect.Row{{"name": "a"}, {"name": "b"}, {"name": "c"}}
	got := rotateFrom(rows, 1)
	if got[0]["name"] != "b" || got[2]["name"] != "a" || len(got) != 3 {
		t.Errorf("rotated: %v", got)
	}
	for _, c := range []struct {
		cur  Cursor
		n    int
		want int
	}{{Cursor{}, 5, 0}, {Cursor{Found: true, LastSeq: 3}, 5, 3}, {Cursor{Found: true, LastSeq: 7}, 5, 2}, {Cursor{Found: true, LastSeq: 4}, 0, 0}} {
		if got := tablesStart(c.cur, c.n); got != c.want {
			t.Errorf("tablesStart(%+v, %d) = %d, want %d", c.cur, c.n, got, c.want)
		}
	}
	for path, want := range map[string]bool{"/var/opt/mssql/data/model_replicatedmaster.mdf": true, `C:\Data\MODEL_MSDBLOG.LDF`: true, "/d/sales.mdf": false} {
		if serverOwnFile(path) != want {
			t.Errorf("server's own file %s: %v", path, !want)
		}
	}
	for path, want := range map[string]bool{`D:\Data\x.MDF`: true, "/var/opt/mssql/data/y.ndf": true, "z.LDF": true, "w.bak": false, "v.mdf.old": false} {
		if isDataOrLogFile(path) != want {
			t.Errorf("%s: %v", path, !want)
		}
	}
}

// The IOs pending are matched to a file by its path, without case on both platforms; a file with none reads 0.
func TestApplyPending(t *testing.T) {
	files := []collect.Row{{"file_handle": "0x00000000000004C8"}, {"file_handle": "0x0000000000000550"}, {"file_handle": nil}}
	ios, inOS := applyPending(files, []collect.Row{
		{"handle": "0x00000000000004c8", "pending_ios": int64(3), "pending_in_os": int64(2)},
		{"handle": "0x00000000000009A0", "pending_ios": int64(4), "pending_in_os": int64(1)}, // no file row has it
	})
	if files[0]["pending_ios"] != int64(3) || files[0]["pending_in_os"] != int64(2) {
		t.Errorf("matched by handle, any case: %v", files[0])
	}
	if files[1]["pending_ios"] != int64(0) || files[2]["pending_ios"] != int64(0) {
		t.Errorf("a file with none pending reads 0: %v %v", files[1], files[2])
	}
	if ios != 7 || inOS != 3 {
		t.Errorf("the totals count every pending row, matched or not: %d %d", ios, inOS)
	}
	for i, f := range files {
		if _, ok := f["file_handle"]; ok {
			t.Errorf("file %d: the handle is not stored: %v", i, f)
		}
	}
}

func TestLogHolderText(t *testing.T) {
	s := logHolderText(collect.Row{"session_id": int64(57), "login_name": "app", "host_name": "web1", "program_name": "etl",
		"started_at_utc": "2026-11-14T10:00:00Z", "statement": "BEGIN TRAN; UPDATE t SET x = 1"})
	for _, w := range []string{"session 57", "app", "web1", "etl", "2026-11-14T10:00:00Z", "UPDATE t"} {
		if !strings.Contains(s, w) {
			t.Errorf("%q lacks %q", s, w)
		}
	}
	for _, sid := range []any{nil, int64(-2)} {
		d := logHolderText(collect.Row{"session_id": sid, "uow": "8F1A0C2E-0000-0000-0000-000000000001"})
		if !strings.Contains(d, "distributed transaction, uow 8F1A0C2E") {
			t.Errorf("session %v: %q", sid, d)
		}
	}
	// a transaction no session holds with the all-zero uow is a local one: never called distributed
	d := logHolderText(collect.Row{"session_id": nil, "uow": "00000000-0000-0000-0000-000000000000", "transaction_id": int64(9001), "started_at_utc": "t0"})
	if strings.Contains(d, "distributed") || !strings.Contains(d, "holder unknown (no session holds transaction 9001, open since t0)") {
		t.Errorf("zero uow: %q", d)
	}
	// the rule's detail names its read and the holder only on an active-transaction wait
	fn := ruleFn(t, "log_used_pct")
	_, _, det := fn(dbFacts{collect.Row{"state": "ONLINE", "log_used_pct": float64(90), "log_size_mb": float64(100), "log_reuse_wait": "ACTIVE_TRANSACTION",
		"log_holder": "held by session 57 (app, web1, etl), open since x; last statement: y"}}, serverFacts{})
	if !strings.Contains(det, "DBCC SQLPERF(LOGSPACE)") || !strings.Contains(det, "held by session 57") {
		t.Errorf("detail: %q", det)
	}
	_, _, det = fn(dbFacts{collect.Row{"state": "ONLINE", "log_used_pct": float64(90), "log_size_mb": float64(100), "log_reuse_wait": "ACTIVE_TRANSACTION"}}, serverFacts{})
	if !strings.Contains(det, "holder unknown") {
		t.Errorf("no holder read: %q", det)
	}
	_, _, det = fn(dbFacts{collect.Row{"state": "ONLINE", "log_used_pct": float64(90), "log_size_mb": float64(100), "log_reuse_wait": "LOG_BACKUP"}}, serverFacts{})
	if strings.Contains(det, "held by") || strings.Contains(det, "holder") {
		t.Errorf("a log backup wait names no holder: %q", det)
	}
}

// ruleFn finds a database rule's judge by its option key.
func ruleFn(t *testing.T, key string) func(dbFacts, serverFacts) (string, string, string) {
	t.Helper()
	for _, r := range databaseRules {
		if r.key == key {
			return r.judge
		}
	}
	t.Fatalf("no database rule %q", key)
	return nil
}

// mapLogHolders: tempdb's holder is mapped as any database's; a failed read says so on every database that needed it;
// a database below the line or on another wait is left alone; a needed one the read did not list gets nothing.
func TestMapLogHolders(t *testing.T) {
	need := func(id int64) collect.Row {
		return collect.Row{"database_id": id, "log_used_pct": float64(85), "log_reuse_wait": "ACTIVE_TRANSACTION"}
	}
	raw := []collect.Row{need(2), need(7), {"database_id": int64(8), "log_used_pct": float64(20), "log_reuse_wait": "ACTIVE_TRANSACTION"},
		{"database_id": int64(9), "log_used_pct": float64(95), "log_reuse_wait": "LOG_BACKUP"}}
	mapLogHolders(raw, []collect.Row{{"database_id": int64(2), "session_id": int64(61), "login_name": "app"},
		{"database_id": int64(8), "session_id": int64(62)}, {"database_id": int64(9), "session_id": int64(63)}}, nil)
	if h, _ := raw[0]["log_holder"].(string); !strings.Contains(h, "held by session 61 (app,") {
		t.Errorf("tempdb's holder: %q", h)
	}
	if _, ok := raw[1]["log_holder"]; ok {
		t.Errorf("a database the read did not list gets no holder: %v", raw[1])
	}
	for _, r := range raw[2:] {
		if _, ok := r["log_holder"]; ok {
			t.Errorf("a database that needs no holder: %v", r)
		}
	}
	raw = []collect.Row{need(2), need(7)}
	mapLogHolders(raw, nil, errors.New("timeout"))
	for _, r := range raw {
		if r["log_holder"] != "holder not read: timeout" {
			t.Errorf("a failed read: %v", r)
		}
	}
}

// folderOf keeps a root's separator and drops any other trailing one; pathKey compares Windows paths without case and
// with either slash, Linux paths without case.
func TestFolderOfAndPathKey(t *testing.T) {
	for in, want := range map[string]string{`D:\`: `D:\`, `D:`: `D:\`, `D:\Data\`: `D:\Data`, `D:\Data`: `D:\Data`, "/": "/",
		"/var/opt/mssql/data/": "/var/opt/mssql/data", `\\srv\share\db\`: `\\srv\share\db`, "": ""} {
		if got := folderOf(in); got != want {
			t.Errorf("folderOf(%q) = %q, want %q", in, got, want)
		}
	}
	if pathKey(`D:/Data/Sales.MDF`) != pathKey(`d:\data\sales.mdf`) {
		t.Errorf("a Windows path with forward slashes")
	}
	if pathKey("/var/opt/mssql/data/MSDBData.mdf") != pathKey("/var/opt/mssql/data/msdbdata.mdf") {
		t.Errorf("a Linux path without case")
	}
	// a subfolder's file: its parent folder is not the folder listed
	path := `D:\SQL\INST2\DATA\other.mdf`
	i := strings.LastIndexAny(path, `/\`)
	if pathKey(folderOf(path[:i+1])) == pathKey(folderOf(`D:\SQL\`)) {
		t.Errorf("a subfolder's file read as the folder's own")
	}
}
