package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

func req(session, blocker, waitMs int64) collect.Row {
	return collect.Row{"kind": "request", "session_id": session, "blocking_session_id": blocker, "wait_ms": waitMs}
}

func bySession(rows []collect.Row) map[int64]collect.Row {
	m := map[int64]collect.Row{}
	for _, r := range rows {
		id, _ := asInt(r["session_id"])
		m[id] = r
	}
	return m
}

// the house head rule on the proof's own shape: a sleeping head, a victim behind it, a third behind the second
func TestBuildChainsSleepingHead(t *testing.T) {
	rows := []collect.Row{req(70, 61, 20000), req(52, 0, 0), req(61, 52, 30000), req(80, 0, 0)}
	b := buildChains(rows)
	m := bySession(rows)
	if len(b) != 1 || b[0]["head_session_id"] != int64(52) || b[0]["victims"] != 2 || b[0]["longest_wait_ms"] != int64(30000) || b[0]["note"] != nil {
		t.Fatalf("blocking rows = %v; want one head 52 with 2 victims and 30000 ms", b)
	}
	for id, want := range map[int64][2]any{52: {int64(52), 0}, 61: {int64(52), 1}, 70: {int64(52), 2}} {
		if m[id]["head_session_id"] != want[0] || m[id]["chain_depth"] != want[1] {
			t.Errorf("session %d: head %v depth %v; want %v", id, m[id]["head_session_id"], m[id]["chain_depth"], want)
		}
	}
	if m[52]["victims"] != 2 || m[52]["longest_victim_wait_ms"] != int64(30000) {
		t.Errorf("the head's own row: victims %v, longest %v", m[52]["victims"], m[52]["longest_victim_wait_ms"])
	}
	if _, has := m[80]["head_session_id"]; has {
		t.Errorf("a session outside every chain carries a head: %v", m[80])
	}
	if _, has := m[61]["victims"]; has {
		t.Errorf("a victim that also blocks is not a head and carries no victim count: %v", m[61])
	}
}

func TestBuildChainsEdges(t *testing.T) {
	// two chains; a head that is not in the snapshot; a session that names itself (a parallel exchange) is not blocked
	rows := []collect.Row{req(60, 55, 1000), req(61, 55, 9000), req(55, 0, 0), req(71, 99, 500), req(90, 90, 4000)}
	b := buildChains(rows)
	if len(b) != 2 || b[0]["head_session_id"] != int64(55) || b[0]["victims"] != 2 || b[0]["longest_wait_ms"] != int64(9000) {
		t.Fatalf("blocking rows = %v", b)
	}
	if b[1]["head_session_id"] != int64(99) || b[1]["victims"] != 1 || b[1]["note"] == nil {
		t.Errorf("the absent head's row = %v; want head 99, one victim, a note", b[1])
	}
	m := bySession(rows)
	if _, has := m[90]["head_session_id"]; has || m[90]["chain_note"] != nil {
		t.Errorf("a session that names itself as its blocker was put in a chain: %v", m[90])
	}

	// a negative blocker has no session: no head, a note; the session behind it inherits the note
	rows = []collect.Row{req(60, -2, 1000), req(61, 60, 500)}
	if b = buildChains(rows); len(b) != 0 {
		t.Errorf("a chain behind an orphaned transaction got a head: %v", b)
	}
	m = bySession(rows)
	if n, _ := m[60]["chain_note"].(string); !strings.Contains(n, "orphaned distributed transaction") {
		t.Errorf("session 60's note = %q", n)
	}
	if n, _ := m[61]["chain_note"].(string); !strings.HasPrefix(n, "behind a session that is blocked by an orphaned") {
		t.Errorf("session 61's note = %q", n)
	}
	if m[60]["head_session_id"] != nil || m[60]["in_cycle"] != false {
		t.Errorf("session 60: %v", m[60])
	}

	// a cycle (a deadlock not yet resolved) and a session behind it: no head, in_cycle, and the walk ends
	rows = []collect.Row{req(60, 61, 1000), req(61, 60, 1000), req(62, 60, 300)}
	if b = buildChains(rows); len(b) != 0 {
		t.Errorf("a cycle got a head: %v", b)
	}
	for id, r := range bySession(rows) {
		if r["in_cycle"] != true || r["head_session_id"] != nil {
			t.Errorf("session %d in a cycle: %v", id, r)
		}
	}

	// MARS: two requests of one session; the one waiting behind another session decides, both rows carry the chain
	rows = []collect.Row{req(60, 0, 0), req(60, 55, 7000), req(55, 0, 0)}
	b = buildChains(rows)
	if len(b) != 1 || b[0]["victims"] != 1 || rows[0]["head_session_id"] != int64(55) || rows[1]["chain_depth"] != 1 {
		t.Errorf("MARS: blocking %v, rows %v", b, rows[:2])
	}
}

// the text leaves the request rows and is carried once per key, under the key the text policy rewrites
func TestShapeRequests(t *testing.T) {
	rows := []collect.Row{
		{"kind": "request", "session_id": int64(60), "blocking_session_id": int64(0), "sql_handle": "0x02AB", "stmt_start": int64(0), "stmt_end": int64(-1),
			"statement": "UPDATE t SET a = 1", "full_chars": int64(18), "wait_type": "WAITFOR", "sw1": "LCK_M_X", "sw1_ms": int64(12), "sw1_tasks": int64(1), "sw2": nil},
		{"kind": "request", "session_id": int64(61), "blocking_session_id": int64(0), "sql_handle": "0x02AB", "stmt_start": int64(0), "stmt_end": int64(-1),
			"statement": "UPDATE t SET a = 1", "full_chars": int64(18), "wait_type": "LCK_M_U"},
		{"kind": "request", "session_id": int64(62), "blocking_session_id": int64(0), "sql_handle": nil, "stmt_start": int64(-1), "stmt_end": int64(-1), "statement": nil},
	}
	out := shapeRequests(rows)
	var texts, reqs []collect.Row
	for _, r := range out {
		switch r["kind"] {
		case "text":
			texts = append(texts, r)
		case "request":
			reqs = append(reqs, r)
		}
	}
	if len(texts) != 1 || texts[0]["statement"] != "UPDATE t SET a = 1" || texts[0]["sql_handle"] != "0x02AB" {
		t.Fatalf("text rows = %v; want one", texts)
	}
	for _, r := range reqs {
		if _, has := r["statement"]; has {
			t.Errorf("a request row still carries its text: %v", r)
		}
		if _, has := r["query_hash"]; has {
			t.Errorf("a request row carries the key 'query_hash', which the text policy replaces with a hash of the text: %v", r)
		}
	}
	if reqs[0]["wait_is_benign"] != true || reqs[1]["wait_is_benign"] != false {
		t.Errorf("benign flags: %v, %v", reqs[0]["wait_is_benign"], reqs[1]["wait_is_benign"])
	}
	sw, _ := reqs[0]["session_waits"].([]map[string]any)
	if len(sw) != 1 || sw[0]["wait"] != "LCK_M_X" || sw[0]["ms"] != int64(12) {
		t.Errorf("session_waits = %v", reqs[0]["session_waits"])
	}
	if reqs[2]["stmt_start"] != nil {
		t.Errorf("a row without a handle keeps offsets: %v", reqs[2])
	}
	// the policy: none drops the text and keeps the key; normalized rewrites the text in the text row
	collect.ApplyTextPolicy(out, "none")
	if texts[0]["statement"] != nil || texts[0]["sql_handle"] != "0x02AB" {
		t.Errorf("under none the text row = %v", texts[0])
	}
	if _, err := json.Marshal(out); err != nil {
		t.Errorf("the payload does not marshal: %v", err)
	}
}

// what the statements may and may not contain: read only, nothing installed, the notice, the parameters of the call
func TestRequestsSQLText(t *testing.T) {
	for _, kind := range []Kind{KindServer, KindRDS, KindAzureMI, KindAzureDB} {
		for _, q := range []string{requestsSQL(sourceDMV, kind), requestsSQL(sourceWIA, kind), whoIsActiveSQL("DBA]x", kind)} {
			if i := strings.Index(q, "{{"); i >= 0 {
				t.Fatalf("%s: an unfilled token at %q", kind, q[i:min(i+30, len(q))])
			}
			u := strings.ToUpper(q)
			for _, bad := range []string{"CREATE PROC", "CREATE EVENT", "ALTER ", "DROP ", "INSERT ", "UPDATE ", "DELETE ", "KILL ", "SP_CONFIGURE", "SET LOCK_TIMEOUT", "SET TRANSACTION", "SET DEADLOCK_PRIORITY"} {
				if strings.Contains(u, bad) {
					t.Errorf("%s: the statement contains %q", kind, bad)
				}
			}
		}
		dmv := requestsSQL(sourceDMV, kind)
		if (kind == KindAzureDB) == strings.Contains(dmv, "sys.sysprocesses") {
			t.Errorf("%s: sys.sysprocesses is read on every kind but Azure SQL Database", kind)
		}
		if (kind == KindAzureDB) != strings.Contains(dmv, "s.database_id = DB_ID()") {
			t.Errorf("%s: the database filter is Azure SQL Database's alone", kind)
		}
		if !strings.Contains(dmv, "r.session_id = s.session_id") || !strings.Contains(dmv, "tk.request_id = r.request_id") {
			t.Errorf("%s: sessions, requests and tasks join on session and request ids", kind)
		}
	}
	w := whoIsActiveSQL("DBA]x", KindServer)
	for _, want := range []string{"[DBA]]x].dbo.sp_WhoIsActive", "@return_schema = 1", "@destination_table = N''#pgvigil_wia''", "@get_transaction_info = 1",
		"@get_outer_command = 1", "@find_block_leaders = 1", "r.request_id = w.request_id", "ISNULL(w.percent_complete, r.percent_complete)", "r.plan_handle"} {
		if !strings.Contains(w, want) {
			t.Errorf("the sp_WhoIsActive call lacks %q", want)
		}
	}
	if !strings.Contains(requestsTemplate, "DBA Dash 4.24.1") || !strings.Contains(requestsTemplate, "Copyright 2022 Trimble, Inc.") {
		t.Error("the ported statement lost its notice")
	}
}

func TestWaitLists(t *testing.T) {
	if len(benignWaits) != 57 {
		t.Errorf("benign waits: %d; the list ported from sp_BlitzFirst 8.34 has 57", len(benignWaits))
	}
	for w := range benignWaits {
		if w != strings.ToUpper(w) || strings.HasPrefix(w, "LCK_") || waitCategories[w] != "" {
			t.Errorf("benign wait %q is lower case, a lock wait or also a categorised wait", w)
		}
	}
	for w, want := range map[string]string{"LCK_M_X": "Locking", "LCK_M_SCH_M": "Locking", "WRITELOG": "Transaction log", "CXPACKET": "Parallelism", "WAITFOR": "", "XYZ": ""} {
		if got := waitCategory(w); got != want {
			t.Errorf("waitCategory(%q) = %q; want %q", w, got, want)
		}
	}
	if !benignWaits["WAITFOR"] || benignWaits["LCK_M_X"] {
		t.Error("WAITFOR is benign and a lock wait is not")
	}
}

func liveConn(t *testing.T) (context.Context, *sql.Conn, Info) {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_MSSQL_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_MSSQL_TEST_DSN is not set")
	}
	t.Setenv("PGVIGIL_MSSQL_TEST_DSN_RESOLVED", dsn)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	db, conn, err := Connect(ctx, config.Instance{Name: "live", Engine: config.EngineSQLServer, DSNRaw: "env:PGVIGIL_MSSQL_TEST_DSN_RESOLVED"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(); _ = db.Close() })
	info, err := Detect(ctx, conn, "")
	if err != nil {
		t.Fatal(err)
	}
	return ctx, conn, info
}

// Both collections against a server: the statements run as the login of the DSN and the payload has its fixed rows.
func TestRunningLive(t *testing.T) {
	ctx, conn, info := liveConn(t)
	rows, err := requestsCollector{}.Run(ctx, conn, info)
	if err != nil {
		t.Fatal(err)
	}
	var summary collect.Row
	for _, r := range rows {
		if r["kind"] == "summary" {
			summary = r
		}
	}
	if summary == nil || summary["server_utc"] == nil || (summary["source"] != sourceDMV && summary["source"] != sourceWIA) {
		t.Fatalf("the summary row = %v", summary)
	}
	if _, err := json.Marshal(rows); err != nil {
		t.Fatal(err)
	}
	t.Logf("mssql_requests: %d rows, source %v (%v), read in %v ms", len(rows), summary["source"], summary["source_note"], summary["read_ms"])
	// the DMV form is run whatever the source was, so both statements are proven on the server
	if _, err := QueryRows(ctx, conn, requestsSQL(sourceDMV, info.Kind)); err != nil {
		t.Fatalf("the DMV read: %v", err)
	}
	w, err := waitsCollector{}.Run(ctx, conn, info)
	if err != nil {
		t.Fatal(err)
	}
	if len(w) < 10 || w[0]["kind"] != "state" || w[0]["server_start"] == nil {
		t.Fatalf("mssql_waits: %d rows, first %v", len(w), w[0])
	}
}

// How long the DMV read takes with many sessions: PGVIGIL_MSSQL_TEST_SESSIONS sessions are opened, each holding an
// open transaction (so each is a row of the snapshot), and the read is timed five times.
func TestRequestsManySessionsLive(t *testing.T) {
	n, _ := strconv.Atoi(os.Getenv("PGVIGIL_MSSQL_TEST_SESSIONS"))
	if n <= 0 {
		t.Skip("PGVIGIL_MSSQL_TEST_SESSIONS is not set")
	}
	ctx, conn, info := liveConn(t)
	load, err := sql.Open("sqlserver", withAppName(os.Getenv("PGVIGIL_MSSQL_TEST_DSN")))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = load.Close() }()
	load.SetMaxOpenConns(n)
	held := make([]*sql.Tx, 0, n)
	defer func() {
		for _, tx := range held {
			_ = tx.Rollback()
		}
	}()
	for range n {
		tx, err := load.BeginTx(ctx, nil)
		if err != nil {
			t.Fatalf("after %d sessions: %v", len(held), err)
		}
		if _, err := tx.ExecContext(ctx, "SELECT 1"); err != nil {
			t.Fatal(err)
		}
		held = append(held, tx)
	}
	var best, worst time.Duration
	var got int
	for i := range 5 {
		t0 := time.Now()
		rows, err := QueryRows(ctx, conn, requestsSQL(sourceDMV, info.Kind))
		if err != nil {
			t.Fatal(err)
		}
		d := time.Since(t0)
		if i == 0 || d < best {
			best = d
		}
		if d > worst {
			worst = d
		}
		got = len(rows)
	}
	if got < n {
		t.Errorf("the snapshot holds %d rows with %d sessions holding a transaction", got, n)
	}
	t.Logf("MANY-SESSIONS: %d sessions with an open transaction, %d rows, the DMV read took %d to %d ms over 5 reads", n, got, best.Milliseconds(), worst.Milliseconds())
}
