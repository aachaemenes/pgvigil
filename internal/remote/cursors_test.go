package remote

import (
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
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
	got = moves(t, "mssql_backup_files", t1, []map[string]any{{"kind": "cursor", "last_set_id": int64(55), "mark": int64(2)}}, nil)
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
	if len(got) != 2 || !atOf(got["schema_ddl:app"]).Equal(t0.Add(3*time.Minute)) || !atOf(got["schema_ddl:crm"]).Equal(t0.Add(2*time.Minute)) {
		t.Errorf("schema_ddl: %+v", got)
	}
}

func at(t time.Time) *time.Time { return &t }

func names(c format.Cursor) string { return strings.Join(c.Names, ",") }

// mssql_hadr_read (0066 L134-153) guards jobs, backup_files and backup_history: a batch older than the collection's
// last read moves nothing; the same time or later is the newest and is recorded. import_mssql_jobs takes the first
// cursor row (LIMIT 1) and moves only when newest (0094 L217-222); a NULL mark is stored as NULL.
func TestCursorMovesHadrGuard(t *testing.T) {
	cur := map[string]format.Cursor{
		"hadr_read:mssql_jobs": {Source: "hadr_read:mssql_jobs", Kind: "log", At: at(t1)},
		"jobs":                 {Source: "jobs", Kind: "seq", Seq: 900},
	}
	if got := moves(t, "mssql_jobs", t0, []map[string]any{{"kind": "cursor", "last_history_id": int64(950), "mark": int64(8)}}, cur); len(got) != 0 {
		t.Errorf("an older batch moved: %+v", got)
	}
	got := moves(t, "mssql_jobs", t1, []map[string]any{{"kind": "cursor", "last_history_id": int64(960), "mark": int64(9)}, {"kind": "cursor", "last_history_id": int64(970), "mark": int64(1)}}, cur)
	if got["jobs"].Seq != 960 || got["jobs_mark"].Seq != 9 || !atOf(got["hadr_read:mssql_jobs"]).Equal(t1) {
		t.Errorf("the same time, the first cursor row: %+v", got)
	}
	later := t1.Add(time.Hour)
	got = moves(t, "mssql_jobs", later, []map[string]any{{"kind": "cursor", "mark": int64(3)}, {"kind": "cursor", "last_history_id": int64(980)}}, cur)
	if _, moved := got["jobs"]; moved || !atOf(got["hadr_read:mssql_jobs"]).Equal(later) {
		t.Errorf("a first cursor row without last_history_id moved jobs, or the read was not recorded: %+v", got)
	}
	got = moves(t, "mssql_jobs", later, []map[string]any{{"kind": "cursor", "last_history_id": int64(990)}}, cur)
	if got["jobs"].Seq != 990 || got["jobs_mark"].Kind != "null" {
		t.Errorf("a cursor row without its mark: %+v", got)
	}
}

// import_mssql_backup_history (0191 L154-276): the first batch inserts the cursor row as the batch has it (restores
// too, whatever restore_read says); later batches keep a value the batch does not carry (coalesce), move restores
// only when restore_read = 'read', and send last_set_id to 0 on v_again (a cursor read listing a database the last
// read did not list), the mark kept. A read listing databases replaces the list; an empty name is no database.
func TestCursorMovesBackupHistory(t *testing.T) {
	db := func(n string) map[string]any { return map[string]any{"kind": "database", "database_name": n} }
	bh := func(id, mark int64) map[string]any {
		return map[string]any{"kind": "cursor", "source": "backup_history", "last_id": id, "mark": mark}
	}
	rh := func(id, mark int64) map[string]any {
		return map[string]any{"kind": "cursor", "source": "restore_history", "last_id": id, "mark": mark}
	}
	read := func(from int64, restore string) map[string]any {
		return map[string]any{"kind": "read", "from_set_id": from, "restore_read": restore}
	}
	got := moves(t, "mssql_backup_history", t0, []map[string]any{db("app"), db(""), read(0, "no right"), bh(10, 1), rh(4, 9)}, nil)
	if got["backup_history"].Seq != 10 || got["backup_history_mark"].Seq != 1 || got["restore_history"].Seq != 4 || got["restore_history_mark"].Seq != 9 ||
		names(got["backup_history_dbs"]) != "app" || !atOf(got["hadr_read:mssql_backup_history"]).Equal(t0) {
		t.Fatalf("the first batch: %+v", got)
	}
	cur := got
	got = moves(t, "mssql_backup_history", t1, []map[string]any{db("crm"), db("app"), read(10, "no right"), bh(20, 2), rh(5, 10)}, cur)
	if got["backup_history"].Seq != 0 || got["backup_history_mark"].Seq != 2 || names(got["backup_history_dbs"]) != "app,crm" {
		t.Errorf("again: %+v", got)
	}
	if _, moved := got["restore_history"]; moved {
		t.Errorf("restores moved while not read: %+v", got)
	}
	if got := moves(t, "mssql_backup_history", t1, []map[string]any{db("app"), db("new"), read(10, "read")}, cur); got["backup_history"].Kind != "seq" || got["backup_history"].Seq != 0 {
		t.Errorf("again without a cursor row: %+v", got)
	}
	got = moves(t, "mssql_backup_history", t1, []map[string]any{db("app"), read(10, "read"), rh(6, 11)}, cur)
	if _, moved := got["backup_history"]; moved || got["restore_history"].Seq != 6 || names(got["backup_history_dbs"]) != "app" {
		t.Errorf("no backup cursor row, restores read: %+v", got)
	}
	got = moves(t, "mssql_backup_history", t1, []map[string]any{read(10, "read"), bh(30, 3)}, cur)
	if _, listed := got["backup_history_dbs"]; listed || got["backup_history"].Seq != 30 {
		t.Errorf("a read listing no database: %+v", got)
	}
	if got := moves(t, "mssql_backup_history", t0.Add(-time.Minute), []map[string]any{db("app"), bh(40, 4)}, cur); len(got) != 0 {
		t.Errorf("an older batch moved: %+v", got)
	}
}

// import_mssql_backup_files (0140 L328-510): a read listing databases puts into 'unlisted' every database it does
// not list that is unlisted already or holds stored sets, and deletes the sets of a database it does not list or
// lists as created anew (more than 3900 s apart, mssql_recreated); a set is stored for a listed database, type full /
// diff / log, finished no earlier than an hour before the database's creation. A cursor read ('from' > 0) listing an
// unlisted database again sends the cursor to 0 and its mark to NULL (v_back); with no cursor row yet and a non-empty
// list, the row is made at 0 with a NULL mark.
func TestCursorMovesBackupFiles(t *testing.T) {
	made := t0.Add(-240 * time.Hour)
	db := func(n string, created time.Time) map[string]any {
		return map[string]any{"kind": "database", "database_name": n, "created_utc": created}
	}
	set := func(n string, finish time.Time) map[string]any {
		return map[string]any{"kind": "set", "database_name": n, "backup_type": "full", "is_copy_only": 0, "backup_set_id": int64(1), "finish_utc": finish}
	}
	read := func(from int64) map[string]any { return map[string]any{"kind": "read", "cursor": true, "from": from} }
	cursor := func(id, mark int64) map[string]any {
		return map[string]any{"kind": "cursor", "last_set_id": id, "mark": mark}
	}
	step := func(cur map[string]format.Cursor, when time.Time, rows ...map[string]any) map[string]format.Cursor {
		next := map[string]format.Cursor{}
		for k, v := range cur {
			next[k] = v
		}
		for k, v := range moves(t, "mssql_backup_files", when, rows, cur) {
			next[k] = v
		}
		return next
	}
	s := step(nil, t0, db("app", made), db("crm", made), set("crm", t0.Add(-time.Hour)), read(0), cursor(55, 2))
	if s["backup_sets"].Seq != 55 || s["backup_sets_mark"].Seq != 2 || names(s["backup_sets_unlisted"]) != "" {
		t.Fatalf("the first batch: %+v", s)
	}
	s = step(s, t1, db("app", made), read(55), cursor(60, 3))
	if s["backup_sets"].Seq != 60 || names(s["backup_sets_unlisted"]) != "crm" {
		t.Fatalf("crm not listed: %+v", s)
	}
	if back := step(s, t1.Add(time.Minute), db("app", made), db("crm", made), read(0), cursor(70, 4)); back["backup_sets"].Seq != 70 || back["backup_sets_mark"].Seq != 4 {
		t.Errorf("a whole read ('from' 0) went back: %+v", back)
	}
	if old := moves(t, "mssql_backup_files", t0, []map[string]any{db("app", made), db("crm", made), read(60), cursor(70, 4)}, s); len(old) != 0 {
		t.Errorf("an older batch moved: %+v", old)
	}
	s = step(s, t1.Add(time.Minute), db("app", made), db("crm", made), read(60), cursor(70, 4))
	if s["backup_sets"].Seq != 0 || s["backup_sets_mark"].Kind != "null" || names(s["backup_sets_unlisted"]) != "" {
		t.Errorf("crm listed again on a cursor read: %+v", s)
	}

	// no cursor row yet: the list makes the row at 0
	s = step(nil, t0, db("app", made), db("crm", made), set("crm", t0.Add(-time.Hour)), set("app", made.Add(-2*time.Hour)))
	if _, made := s["backup_sets"]; made {
		t.Errorf("a row made with nothing unlisted: %+v", s)
	}
	s = step(s, t1, db("crm", made))
	if _, made := s["backup_sets"]; made || names(s["backup_sets_unlisted"]) != "" {
		t.Errorf("app's set finished over an hour before its creation is not stored, so app is not unlisted: %+v", s)
	}
	s = step(s, t1.Add(time.Minute), db("app", made))
	if s["backup_sets"].Kind != "seq" || s["backup_sets"].Seq != 0 || s["backup_sets_mark"].Kind != "null" || names(s["backup_sets_unlisted"]) != "crm" {
		t.Errorf("crm's stored set unlisted: the row made at 0: %+v", s)
	}

	// created anew: its sets go, so a later read that does not list it leaves it out of the list
	s = step(nil, t0, db("crm", made), set("crm", t0.Add(-time.Hour)), cursor(5, 1))
	again := step(s, t1, db("crm", made.Add(2*time.Hour)))
	if again = step(again, t1.Add(time.Minute), db("app", made)); names(again["backup_sets_unlisted"]) != "" {
		t.Errorf("a database created anew kept its sets: %+v", again)
	}
	near := step(s, t1, db("crm", made.Add(30*time.Minute)))
	if near = step(near, t1.Add(time.Minute), db("app", made)); names(near["backup_sets_unlisted"]) != "crm" {
		t.Errorf("a creation time 30 minutes apart is the same database: %+v", near)
	}
}

// dbsOf renders a kept per-database list ([database, time] entries) as "db=unix-micros" in name order.
func dbsOf(c format.Cursor) string {
	out := make([]string, 0, len(c.Names))
	for _, n := range c.Names {
		var f [2]string
		if json.Unmarshal([]byte(n), &f) != nil {
			out = append(out, "?"+n)
			continue
		}
		t, err := time.Parse(time.RFC3339Nano, f[1])
		if err != nil {
			out = append(out, f[0]+"=?")
			continue
		}
		out = append(out, f[0]+"="+strconv.FormatInt(t.UnixMicro(), 10))
	}
	sort.Strings(out)
	return strings.Join(out, ",")
}

func overlay(cur map[string]format.Cursor, moved map[string]format.Cursor) map[string]format.Cursor {
	next := map[string]format.Cursor{}
	for k, v := range cur {
		next[k] = v
	}
	for k, v := range moved {
		next[k] = v
	}
	return next
}

func um(t time.Time) string { return strconv.FormatInt(t.UnixMicro(), 10) }

// import_mssql_stats (0092 L970-1035): mssql_perf_check (L973) refuses a batch without a state row carrying
// server_utc (nothing moves); per 'db' row, a newer read of that database stands (its mssql_stats_db time);
// otherwise its time becomes this read's and, when it was read, 'st:<db>' takes the read's time (a plain write, never
// greatest). The first 'databases' row with a names list drops the guard rows older than this read of the databases
// it does not name; 'st:' cursors stay.
func TestCursorMovesStats(t *testing.T) {
	state := map[string]any{"kind": "state", "server_utc": t0}
	db := func(n string, read bool) map[string]any {
		return map[string]any{"kind": "db", "database_name": n, "read": read}
	}
	if got := moves(t, "mssql_stats", t0, []map[string]any{db("app", true)}, nil); len(got) != 0 {
		t.Errorf("no state row (mssql_perf_check, 0092 L973): %+v", got)
	}
	s := overlay(nil, moves(t, "mssql_stats", t0, []map[string]any{state, db("app", true), db("crm", true), {"kind": "db", "database_name": nil, "read": true}}, nil))
	if !lastAt(s["st:app"]).Equal(t0) || !lastAt(s["st:crm"]).Equal(t0) || s["st:app"].Kind != "mssql" || dbsOf(s["stats_dbs"]) != "app="+um(t0)+",crm="+um(t0) {
		t.Fatalf("the first read: %+v", s)
	}
	b := t0.Add(time.Minute)
	s = overlay(s, moves(t, "mssql_stats", b, []map[string]any{state, db("app", false), {"kind": "databases", "names": []any{"app"}}}, s))
	if !lastAt(s["st:app"]).Equal(t0) || dbsOf(s["stats_dbs"]) != "app="+um(b) || !lastAt(s["st:crm"]).Equal(t0) {
		t.Fatalf("app not read, crm not named: %+v", s)
	}
	c := t0.Add(30 * time.Second)
	s = overlay(s, moves(t, "mssql_stats", c, []map[string]any{state, db("app", true), db("crm", true), {"kind": "databases", "names": "app"}}, s))
	if !lastAt(s["st:app"]).Equal(t0) || !lastAt(s["st:crm"]).Equal(c) || dbsOf(s["stats_dbs"]) != "app="+um(b)+",crm="+um(c) {
		t.Errorf("an older read: app's newer read stands, crm (its guard row dropped) goes back: %+v", s)
	}
}

// import_mssql_constraints (0164 L244-290): the same per-database guard (mssql_constraint_db); a database not read
// takes the read's time and no cursor; a read one also 'ct:<db>'. The first 'databases' row drops every 'ct:' cursor of
// a database it does not name (even one this batch read) and the guard rows older than this read of those. A batch
// without a state row carrying server_utc is refused by mssql_perf_check: nothing moves.
func TestCursorMovesConstraints(t *testing.T) {
	state := map[string]any{"kind": "state", "server_utc": t0}
	db := func(n string, read bool) map[string]any {
		return map[string]any{"kind": "db", "database_name": n, "read": read}
	}
	if got := moves(t, "mssql_constraints", t0, []map[string]any{db("app", true)}, nil); len(got) != 0 {
		t.Errorf("no state row: %+v", got)
	}
	s := overlay(nil, moves(t, "mssql_constraints", t0, []map[string]any{state, db("app", true), db("crm", true)}, nil))
	if !lastAt(s["ct:app"]).Equal(t0) || !lastAt(s["ct:crm"]).Equal(t0) || names(s["ct_dbs"]) != "app,crm" {
		t.Fatalf("the first read: %+v", s)
	}
	b := t0.Add(time.Minute)
	s = overlay(s, moves(t, "mssql_constraints", b, []map[string]any{state, db("app", false), db("new", true), {"kind": "databases", "names": []any{"app"}}}, s))
	if !lastAt(s["ct:app"]).Equal(t0) || s["ct:crm"].Kind != "null" || s["ct:new"].Kind != "null" || names(s["ct_dbs"]) != "app" ||
		dbsOf(s["constraint_dbs"]) != "app="+um(b)+",new="+um(b) {
		t.Fatalf("crm and new not named: %+v", s)
	}
	c := t0.Add(30 * time.Second)
	s = overlay(s, moves(t, "mssql_constraints", c, []map[string]any{state, db("app", true), db("crm", true)}, s))
	if !lastAt(s["ct:app"]).Equal(t0) || !lastAt(s["ct:crm"]).Equal(c) || names(s["ct_dbs"]) != "app,crm" {
		t.Errorf("an older read: %+v", s)
	}
}

// import_mssql_querystore (0083 L271-470, called unchanged by 0126 and 0157) behind mssql_hadr_read: each listed
// store row is upserted at this read's time (its newest_interval kept); a batch with a store row drops the store rows
// older than this read (their cursor with them); 'qs_since:<db>' is the greatest interval_start of the batch's ended
// intervals of a database with a forced_read marker, where its store row is, as epoch seconds (floor).
func TestCursorMovesQueryStore(t *testing.T) {
	store := func(n string) map[string]any { return map[string]any{"kind": "store", "database_name": n} }
	marker := func(n string) map[string]any { return map[string]any{"kind": "forced_read", "database_name": n} }
	interval := func(n string, start time.Time) map[string]any {
		return map[string]any{"kind": "interval", "database_name": n, "interval_start": start, "interval_end": start.Add(time.Hour)}
	}
	i1 := t0.Add(-3*time.Hour + 500*time.Millisecond)
	s := overlay(nil, moves(t, "mssql_querystore", t0, []map[string]any{store("app"), store("crm"), marker("app"), interval("app", i1), interval("app", i1.Add(-time.Hour)), interval("crm", i1), interval("gone", i1), marker("gone")}, nil))
	if s["qs_since:app"].Seq != i1.Unix() || s["qs_since:app"].Kind != "seq" {
		t.Fatalf("app: %+v", s)
	}
	if _, ok := s["qs_since:crm"]; ok {
		t.Errorf("crm had no marker: %+v", s)
	}
	if _, ok := s["qs_since:gone"]; ok {
		t.Errorf("gone has no store row: %+v", s)
	}
	b := t0.Add(time.Minute)
	s = overlay(s, moves(t, "mssql_querystore", b, []map[string]any{store("app"), marker("app"), interval("app", i1.Add(-2*time.Hour))}, s))
	if s["qs_since:app"].Seq != i1.Unix() || dbsOf(s["qs_stores"]) != "app="+um(b) {
		t.Errorf("an older interval, crm not listed: %+v", s)
	}
	s = overlay(s, moves(t, "mssql_querystore", b, []map[string]any{store("crm"), marker("crm"), interval("crm", i1.Add(time.Hour))}, s))
	if s["qs_since:crm"].Seq != i1.Add(time.Hour).Unix() || dbsOf(s["qs_stores"]) != "app="+um(b)+",crm="+um(b) {
		t.Errorf("crm again at the same time (app's row stays): %+v", s)
	}
	s = overlay(s, moves(t, "mssql_querystore", b.Add(time.Minute), []map[string]any{store("app")}, s))
	if s["qs_since:crm"].Kind != "null" || dbsOf(s["qs_stores"]) != "app="+um(b.Add(time.Minute)) {
		t.Errorf("crm's store row dropped: %+v", s)
	}
	if got := moves(t, "mssql_querystore", t0, []map[string]any{store("app"), marker("app"), interval("app", t1)}, s); len(got) != 0 {
		t.Errorf("an older batch moved: %+v", got)
	}
}

// import_mssql_azuredb_resources (0145 L135-185): 'azdb_since' is the greatest stored minute (GREATEST ignores the
// NULL of a batch without minute rows), as epoch seconds; no guard.
func TestCursorMovesAzureDB(t *testing.T) {
	minute := func(m time.Time) map[string]any { return map[string]any{"kind": "minute", "minute": m, "samples": 4} }
	if got := moves(t, "mssql_azuredb_resources", t0, []map[string]any{{"kind": "gap"}}, nil); len(got) != 0 {
		t.Errorf("no minute row: %+v", got)
	}
	s := overlay(nil, moves(t, "mssql_azuredb_resources", t0, []map[string]any{minute(t0.Add(-2 * time.Minute)), minute(t0.Add(-time.Minute)), minute(t0.Add(-3 * time.Minute))}, nil))
	if s["azdb_since"].Kind != "seq" || s["azdb_since"].Seq != t0.Add(-time.Minute).Unix() {
		t.Fatalf("the newest minute: %+v", s)
	}
	if s = overlay(s, moves(t, "mssql_azuredb_resources", t1, []map[string]any{minute(t0.Add(-10 * time.Minute))}, s)); s["azdb_since"].Seq != t0.Add(-time.Minute).Unix() {
		t.Errorf("an older minute moved it back: %+v", s)
	}
}

// lastAt and atOf read a cursor's time, the zero time when it has none (a missing cursor fails its row, never panics).
func lastAt(c format.Cursor) time.Time {
	if c.LastEventAt == nil {
		return time.Time{}
	}
	return *c.LastEventAt
}

func atOf(c format.Cursor) time.Time {
	if c.At == nil {
		return time.Time{}
	}
	return *c.At
}

// A remote collector never sends plan XML: its query_text is hash or none (config refuses full on a remote), and
// every mode but full drops a plan row's statement (textpolicy.go). So no plan of a remote instance holds XML, and
// import_mssql_querystore's policy update (0083 L410-413: a forced_read marker clears the XML a plan holds) never
// moves one - the qs_plan rule needs no list of a database's plans. This row holds the premise.
func TestRemotePlanXMLNeverKept(t *testing.T) {
	for _, mode := range []string{"hash", "none"} {
		rows := []collect.Row{
			{"kind": "plan_xml", "kind_of": "plan", "database_name": "app", "plan_id": int64(1), "statement": "<ShowPlanXML/>"},
			{"kind": "forced_read", "kind_of": "plan", "database_name": "app", "statement": "kept"},
		}
		collect.ApplyTextPolicy(rows, mode)
		for _, r := range rows {
			if v, has := r["statement"]; !has || v != nil {
				t.Errorf("%s: %s kept its statement %v", mode, r["kind"], v)
			}
		}
	}
}

// qs_plan:<id>:<db> (mssql_hadr_cursor 0300 L1688-1693) answers a plan's hash when its XML is stored, or was looked
// at under the text policy within 24 h. The plan's row follows 0083 L369-424: a plan row upserts it (a changed hash,
// query id or query hash clears the XML state and its check time; xml_note marks it 'too large', cleared by the next
// plain row), a plan_xml row sets 'stored' or 'policy' at the read's time on a plan that has a row. Kept as
// 'qs_plan_state:<id>:<db>'. One difference on the safe side: a state whose last plan row is over 24 h old counts as
// absent (the hub's purge keeps a plan at least a day), so the remote never says stored where the hub may not.
func TestCursorMovesQSPlan(t *testing.T) {
	store := map[string]any{"kind": "store", "database_name": "app"}
	plan := func(id, hash, qid int64, qh string) map[string]any {
		return map[string]any{"kind": "plan", "database_name": "app", "plan_id": id, "query_id": qid, "query_hash_hex": qh, "plan_hash_n": hash}
	}
	xml := func(id int64, stmt any) map[string]any {
		return map[string]any{"kind": "plan_xml", "database_name": "app", "plan_id": id, "statement": stmt}
	}
	big := plan(13, 999, 5, "0xCC")
	big["xml_note"] = "too large"
	s := overlay(nil, moves(t, "mssql_querystore", t0, []map[string]any{store, plan(11, 777, 3, "0xAA"), plan(12, 888, 4, "0xBB"), big,
		xml(11, nil), xml(12, "<ShowPlanXML/>"), xml(99, nil), {"kind": "plan", "database_name": "app", "plan_id": int64(20), "plan_hash_n": int64(1)}}, nil))
	answer := func(id string, now time.Time) (int64, bool) { return qsPlanAnswer(s["qs_plan_state:"+id+":app"], now) }
	for _, c := range []struct {
		id   string
		now  time.Time
		want int64
		ok   bool
	}{
		{"11", t0.Add(time.Minute), 777, true},    // policy, checked within 24 h
		{"12", t0.Add(time.Minute), 888, true},    // stored
		{"13", t0.Add(time.Minute), 0, false},     // too large
		{"99", t0.Add(time.Minute), 0, false},     // a plan_xml row for a plan with no row
		{"20", t0.Add(time.Minute), 0, false},     // a plan row without its query_id
		{"11", t0.Add(25 * time.Hour), 0, false},  // policy checked over 24 h ago
		{"12", t0.Add(25 * time.Hour), 0, false},  // stored, but its last plan row is over 24 h old (the safe side)
		{"12", t0.Add(23 * time.Hour), 888, true}, // within the day
	} {
		if n, ok := answer(c.id, c.now); ok != c.ok || n != c.want {
			t.Errorf("plan %s at %s: %d %v, want %d %v", c.id, c.now.Format(time.RFC3339), n, ok, c.want, c.ok)
		}
	}
	if _, kept := s["qs_plan_state:99:app"]; kept {
		t.Errorf("a plan_xml row made a plan's row: %+v", s["qs_plan_state:99:app"])
	}
	b := t0.Add(time.Hour)
	s = overlay(s, moves(t, "mssql_querystore", b, []map[string]any{store, plan(11, 777, 3, "0xAA"), plan(12, 889, 4, "0xBB"), plan(13, 999, 5, "0xCC")}, s))
	if n, ok := answer("11", b); !ok || n != 777 {
		t.Errorf("an unchanged plan row kept its policy state: %d %v", n, ok)
	}
	if _, ok := answer("12", b); ok {
		t.Errorf("a changed hash kept its stored state")
	}
	if _, ok := answer("13", b); ok {
		t.Errorf("'too large' cleared by a plain row is no state")
	}
	s = overlay(s, moves(t, "mssql_querystore", b.Add(time.Hour), []map[string]any{store, xml(13, "")}, s))
	if n, ok := answer("13", b.Add(time.Hour)); !ok || n != 999 {
		t.Errorf("an empty statement is policy (nullif): %d %v", n, ok)
	}
	late := t0.Add(30 * time.Hour)
	s = overlay(s, moves(t, "mssql_querystore", late, []map[string]any{store, plan(13, 999, 5, "0xCC")}, s))
	if _, ok := answer("13", late.Add(time.Minute)); ok {
		t.Errorf("a plan row over 24 h after the last one takes a fresh row (no XML state)")
	}
	if got := moves(t, "mssql_querystore", b, []map[string]any{store, xml(11, "<ShowPlanXML/>")}, s); len(got) != 0 {
		t.Errorf("an older batch moved: %+v", got)
	}
}
