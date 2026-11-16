package remote

import (
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

func moves(t *testing.T, view string, at time.Time, rows []map[string]any, cur map[string]format.Cursor) map[string]format.Cursor {
	t.Helper()
	out := map[string]format.Cursor{}
	for _, c := range cursorMoves(view, at, rows, func(s string) (format.Cursor, bool) { c, ok := cur[s]; return c, ok }) {
		out[c.Source] = c
	}
	return out
}

// An explicit log cursor row moves its source to the later of the stored time and read_to (0079 L87-90, 0053
// L113-116, 0100 L284-287: greatest).
func TestCursorMovesLogRows(t *testing.T) {
	old, newer := t0, t0.Add(time.Hour)
	got := moves(t, "logs", t1, []map[string]any{{"kind": "event", "message": "x"}, {"kind": "cursor", "source": "csvlog:/var/log", "read_to": newer}}, nil)
	if c := got["csvlog:/var/log"]; c.Kind != "log" || c.At == nil || !c.At.Equal(newer) {
		t.Fatalf("first read: %+v", got)
	}
	got = moves(t, "pgaudit", t1, []map[string]any{{"kind": "cursor", "source": "pgaudit:x", "read_to": old.Format(time.RFC3339Nano)}},
		map[string]format.Cursor{"pgaudit:x": {Source: "pgaudit:x", Kind: "log", At: &newer}})
	if c := got["pgaudit:x"]; !c.At.Equal(newer) {
		t.Errorf("an older read_to moved the cursor back: %+v", c)
	}
}

// An explicit SQL Server cursor row (mssql.Cursor.Row) sets its source from the batch's last row of that source
// (0065 / 0162 L466-471, 0158, 0160, 0161: DISTINCT ON (source) ... ORDER BY n DESC).
func TestCursorMovesMSSQLRows(t *testing.T) {
	got := moves(t, "mssql_errorlog", t1, []map[string]any{
		{"kind": "cursor", "source": "errorlog", "file_name": "ERRORLOG", "file_offset": int64(10), "last_event_at": t0.Format(time.RFC3339Nano), "last_seq": int64(0)},
		{"kind": "cursor", "source": "errorlog", "file_name": "ERRORLOG.1", "file_offset": int64(20), "last_event_at": t1.Format(time.RFC3339Nano), "last_seq": int64(3)},
		{"kind": "cursor", "source": "xe:blocked", "file_name": nil, "file_offset": nil, "last_event_at": nil, "last_seq": int64(42)},
	}, nil)
	e := got["errorlog"]
	if e.Kind != "mssql" || e.FileName != "ERRORLOG.1" || e.FileOffset != 20 || e.LastEventAt == nil || !e.LastEventAt.Equal(t1) || e.LastSeq != 3 {
		t.Errorf("errorlog: %+v", e)
	}
	if x := got["xe:blocked"]; x.Kind != "mssql" || x.LastSeq != 42 || x.FileName != "" || x.LastEventAt != nil {
		t.Errorf("xe: %+v", x)
	}
}

// The one-number families: jobs (last_history_id, mark), backup_sets (last_set_id, mark) and the history sources
// (source, last_id, mark), each with its _mark source, as mssql_hadr_cursor answers them (0300 L1682-1705).
func TestCursorMovesSeqRows(t *testing.T) {
	got := moves(t, "mssql_jobs", t1, []map[string]any{{"kind": "read", "cursor": true}, {"kind": "cursor", "last_history_id": int64(900), "mark": int64(7)}}, nil)
	if got["jobs"].Kind != "seq" || got["jobs"].Seq != 900 || got["jobs_mark"].Seq != 7 {
		t.Errorf("jobs: %+v", got)
	}
	got = moves(t, "mssql_backups", t1, []map[string]any{{"kind": "cursor", "last_set_id": int64(55), "mark": int64(2)}}, nil)
	if got["backup_sets"].Seq != 55 || got["backup_sets_mark"].Seq != 2 {
		t.Errorf("backup_sets: %+v", got)
	}
	got = moves(t, "mssql_backup_history", t1, []map[string]any{
		{"kind": "cursor", "source": "backup_history", "last_id": int64(10), "mark": int64(1)},
		{"kind": "cursor", "source": "restore_history", "last_id": int64(4), "mark": int64(9)},
	}, nil)
	if got["backup_history"].Seq != 10 || got["backup_history_mark"].Seq != 1 || got["restore_history"].Seq != 4 || got["restore_history_mark"].Seq != 9 {
		t.Errorf("history: %+v", got)
	}
}

// amcheck's cursor moves to the batch's time only when the batch holds a run (0023 L51-56), never back.
func TestCursorMovesAmcheck(t *testing.T) {
	if got := moves(t, "amcheck", t1, []map[string]any{{"kind": "note"}}, nil); len(got) != 0 {
		t.Errorf("no run row: %+v", got)
	}
	got := moves(t, "amcheck", t1, []map[string]any{{"kind": "run"}}, nil)
	if c := got["amcheck"]; c.Kind != "log" || !c.At.Equal(t1) {
		t.Errorf("a run: %+v", got)
	}
	later := t1.Add(time.Hour)
	got = moves(t, "amcheck", t1, []map[string]any{{"kind": "run"}}, map[string]format.Cursor{"amcheck": {Source: "amcheck", Kind: "log", At: &later}})
	if c := got["amcheck"]; !c.At.Equal(later) {
		t.Errorf("moved back: %+v", c)
	}
}

// The schema read's ddl cursor per database: the newest ddl logged_at or ddl_cursor read_to of the batch (0300
// L2316-2322), forward only.
func TestCursorMovesSchemaDDL(t *testing.T) {
	got := moves(t, "schema", t1, []map[string]any{
		{"kind": "ddl", "datname": "app", "logged_at": t0.Add(time.Minute)},
		{"kind": "ddl", "datname": "app", "logged_at": t0.Add(3 * time.Minute)},
		{"kind": "ddl_cursor", "datname": "crm", "read_to": t0.Add(2 * time.Minute).Format(time.RFC3339Nano)},
		{"kind": "ddl", "datname": nil, "logged_at": t1},
		{"kind": "table", "datname": "app"},
	}, nil)
	if len(got) != 2 || !got["schema_ddl:app"].At.Equal(t0.Add(3*time.Minute)) || !got["schema_ddl:crm"].At.Equal(t0.Add(2*time.Minute)) {
		t.Errorf("schema_ddl: %+v", got)
	}
}
