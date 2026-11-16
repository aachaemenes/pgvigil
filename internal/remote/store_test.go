package remote

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newTestStore(t *testing.T, stateDir, outbox string, c *clock) (*Store, *State) {
	t.Helper()
	st, _, err := LoadState(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	s := NewStore(st, StoreOptions{Outbox: outbox, Site: "site1", Collector: "coll1", QueryText: "hash", PgvigilVersion: "v0.4.0-test",
		SchemaLevel: "0329_remote", Interval: 5 * time.Minute, Now: c.now})
	return s, st
}

func closedManifest(t *testing.T, outbox string, ref format.Ref) *format.Manifest {
	t.Helper()
	dir := filepath.Join(outbox, filepath.FromSlash(ref.Dir()))
	m, err := format.DecodeManifest(read(t, filepath.Join(dir, format.ManifestFile)))
	if err != nil {
		t.Fatal(err)
	}
	if err := format.Verify(os.DirFS(dir), m, 1<<20); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	return m
}

func cursorOf(m *format.Manifest, source string) (format.Cursor, bool) {
	for _, c := range m.Cursors {
		if c.Source == source {
			return c, true
		}
	}
	return format.Cursor{}, false
}

// S2: inside an open bundle a cursor read answers the newest value the bundle's batches moved; the committed state
// moves only when the bundle is closed and renamed; a new store over the same state folder answers the committed.
func TestStoreOpenBundleRead(t *testing.T) {
	ctx := context.Background()
	stateDir, out := t.TempDir(), t.TempDir()
	c := &clock{t: t0}
	s, st := newTestStore(t, stateDir, out, c)
	id, err := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0.4295.3", 16, false, []string{"env:prod"})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Import(ctx, id, "mssql_jobs", t0.Add(time.Minute), []map[string]any{{"kind": "read", "cursor": true}, {"kind": "cursor", "last_history_id": int64(900), "mark": int64(7)}}); err != nil {
		t.Fatal(err)
	}
	if n, ok, err := s.MSSQLSeqCursor(ctx, id, "jobs"); err != nil || !ok || n != 900 {
		t.Fatalf("the open bundle's jobs: %d %v %v", n, ok, err)
	}
	if _, ok := st.Cursor(inst.Name, "jobs"); ok {
		t.Fatalf("committed before the close")
	}
	if err := s.LogCollection(ctx, id, "mssql_jobs", t0.Add(time.Minute), 120*time.Millisecond, "ok", ""); err != nil {
		t.Fatal(err)
	}
	c.t = t1
	ref, err := s.CloseInstance(inst.Name, t1, []format.Read{{Collection: "mssql_jobs", IntervalSecs: 300}, {Collection: "mssql_backups", IntervalSecs: 3600}},
		format.Heartbeat{Host: "jump01", Started: t0, At: t1, Instances: 1})
	if err != nil {
		t.Fatal(err)
	}
	m := closedManifest(t, out, ref)
	if j, ok := cursorOf(m, "jobs"); !ok || j.Seq != 900 {
		t.Errorf("the manifest's jobs cursor: %+v %v", j, ok)
	}
	if len(m.Reads) != 2 || m.Reads[0].Collection != "mssql_jobs" || m.Reads[0].Status != format.ReadRan || m.Reads[0].Runs != 1 || m.Reads[0].IntervalSecs != 300 ||
		m.Reads[1].Status != format.ReadSkipped || m.Reads[1].Reason != "not_due" {
		t.Errorf("reads: %+v", m.Reads)
	}
	if len(m.Runs) != 1 || m.Instance.Name != inst.Name || m.Instance.Engine != "sqlserver" || len(m.Files) != 1 || m.Files[0].View != "mssql_jobs" {
		t.Errorf("manifest: %+v", m)
	}
	if j, ok := st.Cursor(inst.Name, "jobs"); !ok || j.Seq != 900 {
		t.Errorf("committed after the close: %+v %v", j, ok)
	}
	s2, _ := newTestStore(t, stateDir, out, c)
	id2, _ := s2.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0.4295.3", 16, false, nil)
	if n, ok, err := s2.MSSQLSeqCursor(ctx, id2, "jobs"); err != nil || !ok || n != 900 || id2 != id {
		t.Errorf("a new store: %d %v %v (id %d, was %d)", n, ok, err, id2, id)
	}
}

// The reader answers only sources.go's sources: an unknown source, or one asked through the wrong reader, is an error in
// words; a hub setting is not found; an instance never made is an error.
func TestStoreReaderRefuses(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestStore(t, t.TempDir(), t.TempDir(), &clock{t: t0})
	id, _ := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0", 16, false, nil)
	if _, _, err := s.MSSQLSeqCursor(ctx, id, "nope"); err == nil || !strings.Contains(err.Error(), "no rule") {
		t.Errorf("an unknown source: %v", err)
	}
	if _, _, err := s.LogCursor(ctx, id, "jobs"); err == nil || !strings.Contains(err.Error(), "reader") {
		t.Errorf("the wrong reader: %v", err)
	}
	if _, _, _, _, found, err := s.MSSQLCursor(ctx, id, "errorlog:search"); err != nil || found {
		t.Errorf("a hub setting: %v %v", found, err)
	}
	if _, _, _, _, found, err := s.MSSQLCursor(ctx, id, "st:app"); err != nil || found {
		t.Errorf("a source not read yet: %v %v", found, err)
	}
	if _, _, err := s.MSSQLSeqCursor(ctx, id+99, "jobs"); err == nil {
		t.Errorf("an instance never made: no error")
	}
}

// A source the rules set to NULL is not found; qs_plan answers through the plan's kept state at the store's clock;
// a log source answers its time.
func TestStoreNullQSPlanAndLog(t *testing.T) {
	ctx := context.Background()
	c := &clock{t: t0}
	s, _ := newTestStore(t, t.TempDir(), t.TempDir(), c)
	id, _ := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0", 16, false, nil)
	imp := func(view string, at time.Time, rows ...map[string]any) {
		t.Helper()
		if err := s.Import(ctx, id, view, at, rows); err != nil {
			t.Fatal(err)
		}
	}
	db := func(n string) map[string]any { return map[string]any{"kind": "database", "database_name": n} }
	imp("mssql_backup_files", t0, db("app"), db("crm"), map[string]any{"kind": "set", "database_name": "crm", "backup_type": "full", "is_copy_only": 0, "backup_set_id": int64(1), "finish_utc": t0.Add(-time.Hour)},
		map[string]any{"kind": "cursor", "last_set_id": int64(55), "mark": int64(2)})
	imp("mssql_backup_files", t0.Add(time.Minute), db("app"), map[string]any{"kind": "read", "from": int64(55)}, map[string]any{"kind": "cursor", "last_set_id": int64(60), "mark": int64(3)})
	imp("mssql_backup_files", t0.Add(2*time.Minute), db("app"), db("crm"), map[string]any{"kind": "read", "from": int64(60)}, map[string]any{"kind": "cursor", "last_set_id": int64(70), "mark": int64(4)})
	if n, ok, err := s.MSSQLSeqCursor(ctx, id, "backup_sets"); err != nil || !ok || n != 0 {
		t.Errorf("backup_sets after v_back: %d %v %v", n, ok, err)
	}
	if _, ok, err := s.MSSQLSeqCursor(ctx, id, "backup_sets_mark"); err != nil || ok {
		t.Errorf("a NULL mark is not found: %v %v", ok, err)
	}
	imp("mssql_querystore", t0.Add(3*time.Minute), map[string]any{"kind": "store", "database_name": "app"},
		map[string]any{"kind": "plan", "database_name": "app", "plan_id": int64(11), "query_id": int64(3), "query_hash_hex": "0xAA", "plan_hash_n": int64(777)},
		map[string]any{"kind": "plan_xml", "database_name": "app", "plan_id": int64(11), "statement": nil})
	if n, ok, err := s.MSSQLSeqCursor(ctx, id, "qs_plan:11:app"); err != nil || !ok || n != 777 {
		t.Errorf("qs_plan: %d %v %v", n, ok, err)
	}
	c.t = t0.Add(26 * time.Hour)
	if _, ok, err := s.MSSQLSeqCursor(ctx, id, "qs_plan:11:app"); err != nil || ok {
		t.Errorf("qs_plan a day later: %v %v", ok, err)
	}
	pid, _ := s.EnsureInstanceEngine(ctx, "postgres", "pg1", "onprem", "18.1", 180001, false, nil)
	if err := s.Import(ctx, pid, "logs", t0, []map[string]any{{"kind": "cursor", "source": "serverlog:/var/log/pg", "read_to": t0.Add(-time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	if at, ok, err := s.LogCursor(ctx, pid, "serverlog:/var/log/pg"); err != nil || !ok || !at.Equal(t0.Add(-time.Minute)) {
		t.Errorf("a log source: %v %v %v", at, ok, err)
	}
	if f, off, at, seq, found, err := s.MSSQLCursor(ctx, id, "ix:app"); err != nil || found || f != "" || off != 0 || !at.IsZero() || seq != 0 {
		t.Errorf("never read: %q %d %v %d %v %v", f, off, at, seq, found, err)
	}
}

// A close that fails leaves the committed cursors and the reserved seq: the reader answers the committed value, and the
// next bundle of the instance takes the same seq (its interval is read again).
func TestStoreFailedCloseKeepsCommitted(t *testing.T) {
	ctx := context.Background()
	stateDir, out := t.TempDir(), t.TempDir()
	c := &clock{t: t0}
	s, st := newTestStore(t, stateDir, out, c)
	id, _ := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0", 16, false, nil)
	jobs := func(at time.Time, n int64) {
		t.Helper()
		if err := s.Import(ctx, id, "mssql_jobs", at, []map[string]any{{"kind": "cursor", "last_history_id": n, "mark": int64(1)}}); err != nil {
			t.Fatal(err)
		}
	}
	jobs(t0.Add(time.Minute), 900)
	if _, err := s.CloseInstance(inst.Name, t1, nil, format.Heartbeat{Host: "h", Started: t0, At: t1}); err != nil {
		t.Fatal(err)
	}
	c.t = t1
	jobs(t1.Add(time.Minute), 950)
	parts := findParts(t, out)
	if len(parts) != 1 {
		t.Fatalf("parts: %v", parts)
	}
	if err := os.RemoveAll(parts[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CloseInstance(inst.Name, t1.Add(5*time.Minute), nil, format.Heartbeat{Host: "h", Started: t0, At: t1}); err == nil {
		t.Fatalf("a close with its .part folder gone: no error")
	}
	if n, ok, err := s.MSSQLSeqCursor(ctx, id, "jobs"); err != nil || !ok || n != 900 {
		t.Errorf("after the failed close: %d %v %v", n, ok, err)
	}
	if is := st.Instances[inst.Name]; is == nil || is.Done != 1 || is.Reserved != 2 {
		t.Errorf("the seq: %+v", is)
	}
	jobs(t1.Add(2*time.Minute), 960)
	ref, err := s.CloseInstance(inst.Name, t1.Add(5*time.Minute), nil, format.Heartbeat{Host: "h", Started: t0, At: t1})
	if err != nil || ref.Seq != 2 {
		t.Errorf("the next close takes seq 2: %+v %v", ref, err)
	}
}

// A connect failure of an instance never made opens its bundle with the identity the failure gives; the read of its
// collection is failed; an instance with nothing logged in the interval still gets its bundle (the empty interval).
func TestStoreFailuresAndEmptyInterval(t *testing.T) {
	ctx := context.Background()
	out := t.TempDir()
	s, _ := newTestStore(t, t.TempDir(), out, &clock{t: t0})
	if err := s.LogConnectFailure(ctx, "pg2", "postgres", "onprem", []string{"env:dev"}, "activity", t0.Add(time.Minute), 3*time.Second, errors.New("dial tcp: timeout")); err != nil {
		t.Fatal(err)
	}
	ref, err := s.CloseInstance("pg2", t1, []format.Read{{Collection: "activity", IntervalSecs: 60}}, format.Heartbeat{Host: "h", Started: t0, At: t1, Instances: 2})
	if err != nil {
		t.Fatal(err)
	}
	m := closedManifest(t, out, ref)
	if len(m.Failures) != 1 || m.Failures[0].Kind != "connect" || m.Instance.Engine != "postgres" || m.Instance.Name != "pg2" ||
		len(m.Reads) != 1 || m.Reads[0].Status != format.ReadFailed || m.Reads[0].Failed != 1 || m.Reads[0].Runs != 1 {
		t.Errorf("a connect failure: %+v", m)
	}
	if _, err := s.EnsureInstanceEngine(ctx, "postgres", "pg3", "onprem", "18.1", 180001, false, nil); err != nil {
		t.Fatal(err)
	}
	ref, err = s.CloseInstance("pg3", t1, []format.Read{{Collection: "activity", IntervalSecs: 60}}, format.Heartbeat{Host: "h", Started: t0, At: t1, Instances: 2})
	if err != nil {
		t.Fatal(err)
	}
	if m := closedManifest(t, out, ref); len(m.Files) != 0 || m.Reads[0].Status != format.ReadSkipped {
		t.Errorf("the empty interval: %+v", m)
	}
}
