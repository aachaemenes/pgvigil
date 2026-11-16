package remote

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"
	"time"
)

// schemaStep is one step of the schema-due sequence: a batch imported (view, at, rows), or a due asked (at, payload) with
// what 0267 answers.
type schemaStep struct {
	view    string
	at      time.Time
	rows    []map[string]any
	payload map[string]any
	want    *schemaAnswer
}

type schemaAnswer struct {
	TraceOK  bool       `json:"trace_ok"`
	TraceWhy *string    `json:"trace_why"`
	Oldest   *time.Time `json:"oldest_read_at"`
	Due      []struct {
		ID     int64  `json:"database_id"`
		Reason string `json:"reason"`
	} `json:"due"`
}

func (a schemaAnswer) dueList() [][2]any {
	out := [][2]any{}
	for _, d := range a.Due {
		out = append(out, [2]any{d.ID, d.Reason})
	}
	return out
}

func sp(s string) *string       { return &s }
func tp(t time.Time) *time.Time { return &t }

func due(at time.Time, why *string, ok bool, oldest *time.Time, list ...any) *schemaAnswer {
	a := &schemaAnswer{TraceOK: ok, TraceWhy: why, Oldest: oldest}
	for i := 0; i+1 < len(list); i += 2 {
		a.Due = append(a.Due, struct {
			ID     int64  `json:"database_id"`
			Reason string `json:"reason"`
		}{int64(list[i].(int)), list[i+1].(string)})
	}
	return a
}

// schemaSteps: three databases (1 app, 2 crm read-only, 3 hr) through every reason of 0267's import_mssql_schema_due
// - new, restore, ddl, gap, retry, reconcile - the read-only branch, a partial attempt, the trace's states and its why
// texts, the end of a pass marking the unlisted gone.
func schemaSteps() []schemaStep {
	m := func(d time.Duration) time.Time { return t0.Add(d) }
	mdb := func(id int, name, local, state string, readAt, partialAt any) map[string]any {
		return map[string]any{"kind": "mssql_db", "database_id": id, "name": name, "create_local": local, "state": state, "read_at": readAt, "partial_at": partialAt}
	}
	db := func(id int, name string, readAt time.Time) map[string]any {
		return map[string]any{"kind": "db", "dbid": id, "datname": name, "read_at": readAt, "objects": 0}
	}
	trace := func(state string, note any) map[string]any {
		return map[string]any{"kind": "state", "reader": "defaulttrace", "state": state, "note": note}
	}
	dbs := func(list ...map[string]any) []any {
		out := []any{}
		for _, x := range list {
			out = append(out, x)
		}
		return out
	}
	app := map[string]any{"database_id": 1, "name": "app", "create_local": "L1"}
	crm := map[string]any{"database_id": 2, "name": "crm", "create_local": "L2", "read_only": true}
	hr := map[string]any{"database_id": 3, "name": "hr", "create_local": "L3"}
	appRestored := map[string]any{"database_id": 1, "name": "app", "create_local": "L1", "restored_at": m(5 * time.Minute)}
	crmNew := map[string]any{"database_id": 2, "name": "crm", "create_local": "L2x", "read_only": true}
	notRead := "the default trace has not been read on this instance"
	return []schemaStep{
		{at: m(0), payload: map[string]any{"now": m(0), "dbs": dbs(app, crm, hr)}, want: due(m(0), &notRead, false, nil, 1, "new", 2, "new", 3, "new")},
		{view: "mssql_schema", at: m(time.Minute), rows: []map[string]any{
			mdb(1, "app", "L1", "read", m(time.Minute), nil), mdb(2, "crm", "L2", "read", m(time.Minute), nil), mdb(3, "hr", "L3", "read", m(time.Minute), nil),
			db(1, "app", m(time.Minute)), db(2, "crm", m(time.Minute)), db(3, "hr", m(time.Minute)), {"kind": "end"}}},
		{view: "mssql_defaulttrace", at: m(time.Minute), rows: []map[string]any{trace("read", nil)}},
		{at: m(2 * time.Minute), payload: map[string]any{"now": m(2 * time.Minute), "dbs": dbs(app, crm, hr)}, want: due(m(0), nil, true, tp(m(time.Minute)))},
		{view: "mssql_defaulttrace", at: m(3 * time.Minute), rows: []map[string]any{trace("read", nil),
			{"kind": "trace", "trace_kind": "ddl", "event_at": m(150 * time.Second), "event_key": "k1", "logged_local": "2026-11-16T09:52:30", "event_class": 164, "database_name": "app"}}},
		{at: m(4 * time.Minute), payload: map[string]any{"now": m(4 * time.Minute), "dbs": dbs(app, crm, hr)}, want: due(m(0), nil, true, tp(m(time.Minute)), 1, "ddl")},
		{view: "mssql_defaulttrace", at: m(5 * time.Minute), rows: []map[string]any{trace("read", "4 events were not read (the file rolled over)")}},
		{at: m(6 * time.Minute), payload: map[string]any{"now": m(6 * time.Minute), "dbs": dbs(app, crm, hr)}, want: due(m(0), nil, true, tp(m(time.Minute)), 1, "ddl", 3, "gap")},
		{at: m(6 * time.Minute), payload: map[string]any{"now": m(6 * time.Minute), "dbs": dbs(appRestored, crmNew, hr)}, want: due(m(0), nil, true, tp(m(time.Minute)), 2, "new", 1, "restore", 3, "gap")},
		{view: "mssql_schema", at: m(7 * time.Minute), rows: []map[string]any{
			mdb(3, "hr", "L3", "read", m(7*time.Minute), nil), mdb(2, "crm", "L2", "partial", nil, m(7*time.Minute)), db(3, "hr", m(7*time.Minute))}},
		{view: "mssql_schema", at: m(8 * time.Minute), rows: []map[string]any{mdb(3, "hr", "L3", "torn", nil, nil)}},
		{at: m(9 * time.Minute), payload: map[string]any{"now": m(9 * time.Minute), "dbs": dbs(app, hr)}, want: due(m(0), nil, true, tp(m(time.Minute)), 1, "ddl", 3, "retry")},
		{at: m(26 * time.Hour), payload: map[string]any{"now": m(26 * time.Hour), "dbs": dbs(app, crm, hr)},
			want: due(m(0), sp("the default trace was last read 2026-11-16 17:55 UTC"), false, tp(m(time.Minute)), 1, "gap", 3, "retry", 2, "reconcile")},
		{view: "mssql_schema", at: m(27 * time.Hour), rows: []map[string]any{mdb(1, "app", "L1", "seen", nil, nil), {"kind": "seen", "dbid": 1}, {"kind": "end"}}},
		{at: m(27*time.Hour + time.Minute), payload: map[string]any{"now": m(27*time.Hour + time.Minute), "dbs": dbs(app, crm, hr)},
			want: due(m(0), sp("the default trace was last read 2026-11-16 17:55 UTC"), false, tp(m(time.Minute)), 2, "new", 3, "new", 1, "gap")},
		{view: "mssql_defaulttrace", at: m(28 * time.Hour), rows: []map[string]any{trace("no right", nil)}},
		{at: m(28 * time.Hour), payload: map[string]any{"now": m(28 * time.Hour), "dbs": dbs(app)},
			want: due(m(0), sp("the default trace cannot be read: the login lacks ALTER TRACE"), false, tp(m(time.Minute)), 1, "gap")},
		{at: m(28 * time.Hour), payload: map[string]any{"now": m(28 * time.Hour), "no_trace": "Azure SQL Database keeps no default trace", "dbs": dbs(app)},
			want: due(m(0), sp("Azure SQL Database keeps no default trace"), false, tp(m(time.Minute)), 1, "gap")},
	}
}

func sameAnswer(t *testing.T, label string, got, want schemaAnswer) {
	t.Helper()
	if got.TraceOK != want.TraceOK || !reflect.DeepEqual(got.TraceWhy, want.TraceWhy) || !reflect.DeepEqual(got.dueList(), want.dueList()) ||
		(got.Oldest == nil) != (want.Oldest == nil) || (got.Oldest != nil && !got.Oldest.Equal(*want.Oldest)) {
		gw, ww := "<nil>", "<nil>"
		if got.TraceWhy != nil {
			gw = *got.TraceWhy
		}
		if want.TraceWhy != nil {
			ww = *want.TraceWhy
		}
		t.Errorf("%s: got ok %v why %q oldest %v due %v; want ok %v why %q oldest %v due %v", label, got.TraceOK, gw, got.Oldest, got.dueList(),
			want.TraceOK, ww, want.Oldest, want.dueList())
	}
}

// The remote store's schema due over the steps: each answer what 0267 gives for the same history.
func TestStoreSchemaDue(t *testing.T) {
	ctx := context.Background()
	s, _ := newTestStore(t, t.TempDir(), t.TempDir(), &clock{t: t0})
	id, _ := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0", 16, false, nil)
	for i, st := range schemaSteps() {
		if st.view != "" {
			if err := s.Import(ctx, id, st.view, st.at, st.rows); err != nil {
				t.Fatalf("step %d import %s: %v", i, st.view, err)
			}
			continue
		}
		b, _ := json.Marshal(st.payload)
		raw, err := s.MSSQLSchemaDue(ctx, id, st.at, b)
		if err != nil {
			t.Fatalf("step %d: %v", i, err)
		}
		var got schemaAnswer
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatalf("step %d: %v: %s", i, err, raw)
		}
		sameAnswer(t, fmt.Sprintf("step %d", i), got, *st.want)
	}
	pid, _ := s.EnsureInstanceEngine(ctx, "postgres", "pg1", "onprem", "18.1", 180001, false, nil)
	if _, err := s.MSSQLSchemaDue(ctx, pid, t0, []byte(`{}`)); err == nil {
		t.Errorf("a PostgreSQL instance's schema due: no error")
	}
}

// The store implements store.Store whole once the three answers are in.
var _ interface {
	MSSQLSchemaDue(ctx context.Context, instanceID int, snapshotAt time.Time, payload []byte) ([]byte, error)
} = (*Store)(nil)
