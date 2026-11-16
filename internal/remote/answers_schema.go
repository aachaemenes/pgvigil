package remote

import (
	"context"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// The schema due (0267 import_mssql_schema_due) reads four things the hub's imports keep; a remote collector keeps them
// from the same batches by these rules:
//   - trace_state / trace_gap: the default trace reader's state row (import_mssql_readers_base 0091 L206-219: written
//     when newer) and the newest read whose note says events were not read (0267's trigger mssql_schema_trace_gap);
//   - trace_ddl: each database name's newest DDL event of the default trace (0091 L181-194's trace rows);
//   - schema_dbs: mssql_schema_dbs (import_mssql_schema 0267 L290-341: a reused database_id, the upsert with its
//     state merge, the end of a pass);
//   - schema_present: schema_databases' is_present per database id (import_schema 0300: its per-database guard, the end
//     of a pass; 0267's reused-id check).
// Two differences are named, not followed: the purge of old trace events (a remote keeps each name's newest, which only
// the age test reads), and '1 day' read as 24 hours (the hub's session time zone could make a DST day 23 or 25).

type traceState struct {
	State string    `json:"state"`
	At    time.Time `json:"at"`
	Note  *string   `json:"note,omitempty"`
}

type schemaDB struct {
	ID          int64      `json:"id"`
	Name        string     `json:"name"`
	CreateLocal *string    `json:"create_local,omitempty"`
	ForkGUID    *string    `json:"fork_guid,omitempty"`
	State       string     `json:"state"`
	ReadAt      *time.Time `json:"read_at,omitempty"`
	PartialAt   *time.Time `json:"partial_at,omitempty"`
	Snapshot    time.Time  `json:"snapshot"`
}

type schemaPresent struct {
	DBID     int64     `json:"dbid"`
	Datname  *string   `json:"datname,omitempty"`
	Snapshot time.Time `json:"snapshot"`
	Present  bool      `json:"present"`
}

var traceGapRE = regexp.MustCompile(`(?i)(were|could) not (be )?read`)

func strOf(m map[string]any, k string) *string {
	if s, ok := jsonText(m, k); ok {
		return &s
	}
	return nil
}

func timeOf(m map[string]any, k string) *time.Time {
	if t, ok := toTime(m[k]); ok {
		tt := t.UTC()
		return &tt
	}
	return nil
}

func sameStrPtr(a, b *string) bool { return (a == nil) == (b == nil) && (a == nil || *a == *b) }

func decodeList[T any](c format.Cursor, ok bool) []T {
	var out []T
	if !ok {
		return out
	}
	for _, n := range c.Names {
		var v T
		if json.Unmarshal([]byte(n), &v) == nil {
			out = append(out, v)
		}
	}
	return out
}

func encodeList[T any](source string, items []T) format.Cursor {
	names := make([]string, 0, len(items))
	for _, it := range items {
		b, _ := json.Marshal(it)
		names = append(names, string(b))
	}
	sort.Strings(names)
	return format.Cursor{Source: source, Kind: "list", Names: names}
}

// readersMoves is the schema due's part of import_mssql_readers (views mssql_errorlog, mssql_defaulttrace,
// mssql_syshealth; their cursor rows are the generic rule's).
func readersMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	at = at.UTC().Truncate(time.Microsecond)
	if st := firstRow(rows, func(r map[string]any) bool {
		k, _ := r["kind"].(string)
		reader, _ := r["reader"].(string)
		state, _ := r["state"].(string)
		return k == "state" && reader == "defaulttrace" && (state == "read" || state == "no right" || state == "off" || state == "failed")
	}); st != nil {
		c, ok := cur("trace_state")
		prev := decodeList[traceState](c, ok)
		if len(prev) == 0 || prev[0].At.Before(at) {
			state, _ := st["state"].(string)
			ts := traceState{State: state, At: at, Note: strOf(st, "note")}
			out["trace_state"] = encodeList("trace_state", []traceState{ts})
			if ts.Note != nil && traceGapRE.MatchString(*ts.Note) {
				if g, ok := cur("trace_gap"); !ok || g.At == nil || g.At.Before(at) {
					out["trace_gap"] = format.Cursor{Source: "trace_gap", Kind: "log", At: &at}
				}
			}
		}
	}
	c, ok := cur("trace_ddl")
	newest := map[string]time.Time{}
	for _, e := range decodeList[[2]string](c, ok) {
		if t, err := time.Parse(time.RFC3339Nano, e[1]); err == nil {
			newest[e[0]] = t
		}
	}
	changed := false
	for _, r := range rows {
		k, _ := r["kind"].(string)
		tk, _ := r["trace_kind"].(string)
		name, named := r["database_name"].(string)
		ev := timeOf(r, "event_at")
		if k != "trace" || tk != "ddl" || !named || ev == nil || r["event_key"] == nil || r["logged_local"] == nil || r["event_class"] == nil {
			continue
		}
		if t, seen := newest[name]; !seen || ev.After(t) {
			newest[name], changed = *ev, true
		}
	}
	if changed {
		items := make([][2]string, 0, len(newest))
		for n, t := range newest {
			items = append(items, [2]string{n, t.Format(time.RFC3339Nano)})
		}
		out["trace_ddl"] = encodeList("trace_ddl", items)
	}
}

// mssqlSchemaMoves is import_mssql_schema's part of the schema due (view mssql_schema; its schema_ddl cursors are the
// generic rule's): mssql_schema_dbs and schema_databases' is_present.
func mssqlSchemaMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	at = at.UTC().Truncate(time.Microsecond)
	cDBs, ok := cur("schema_dbs")
	dbs := map[int64]*schemaDB{}
	for _, d := range decodeList[schemaDB](cDBs, ok) {
		d := d
		dbs[d.ID] = &d
	}
	cPresent, ok := cur("schema_present")
	present := map[int64]*schemaPresent{}
	for _, p := range decodeList[schemaPresent](cPresent, ok) {
		p := p
		present[p.DBID] = &p
	}
	kindRows := func(kind string) []map[string]any {
		var l []map[string]any
		for _, r := range rows {
			if k, _ := r["kind"].(string); k == kind {
				l = append(l, r)
			}
		}
		return l
	}
	// another database on a reused database_id (0267 L296-311)
	for _, r := range kindRows("mssql_db") {
		id, isNum := toInt64(r["database_id"])
		s := dbs[id]
		if !isNum || s == nil || s.State == "gone" || sameStrPtr(s.CreateLocal, strOf(r, "create_local")) {
			continue
		}
		name, restored := strOf(r, "name"), timeOf(r, "restored_at")
		if restored != nil && name != nil && strings.EqualFold(s.Name, *name) && (s.ReadAt == nil || restored.After(*s.ReadAt)) {
			continue
		}
		if p := present[id]; p != nil && p.Present {
			p.Present = false
		}
		s.PartialAt, s.State = nil, "seen"
	}
	// the upsert (0267 L313-326)
	for _, r := range kindRows("mssql_db") {
		id, isNum := toInt64(r["database_id"])
		name, state := strOf(r, "name"), strOf(r, "state")
		if !isNum || name == nil || state == nil {
			continue
		}
		next := &schemaDB{ID: id, Name: *name, CreateLocal: strOf(r, "create_local"), ForkGUID: strOf(r, "fork_guid"), State: *state,
			ReadAt: timeOf(r, "read_at"), PartialAt: timeOf(r, "partial_at"), Snapshot: at}
		if s := dbs[id]; s != nil {
			if next.State == "seen" && (s.State == "torn" || s.State == "partial") {
				next.State = s.State
			}
			if next.ReadAt == nil {
				next.ReadAt = s.ReadAt
			}
			if next.PartialAt == nil {
				next.PartialAt = s.PartialAt
			}
		}
		dbs[id] = next
	}
	// import_schema's schema_databases (0300): a database's row unless a newer snapshot stands; the end of a pass
	listed := map[int64]bool{}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		id, isNum := toInt64(r["dbid"])
		if !isNum || (k != "db" && k != "seen") {
			continue
		}
		listed[id] = true
		if k != "db" {
			continue
		}
		if p := present[id]; p != nil && !p.Snapshot.Before(at) {
			continue
		}
		present[id] = &schemaPresent{DBID: id, Datname: strOf(r, "datname"), Snapshot: at, Present: true}
	}
	ended := len(kindRows("end")) > 0
	if ended {
		errs := map[string]bool{}
		for _, r := range kindRows("collector_error") {
			if src, ok := r["source"].(string); ok {
				errs[src] = true
			}
		}
		for id, p := range present {
			if p.Present && p.Snapshot.Before(at) && !listed[id] && (p.Datname == nil || !errs["schema:"+*p.Datname]) {
				p.Present, p.Snapshot = false, at
			}
		}
		// the end of a pass in import_mssql_schema (0267 L336-339)
		for _, s := range dbs {
			if s.State != "gone" && s.Snapshot.Before(at) {
				s.State, s.Snapshot = "gone", at
			}
		}
	}
	dl := make([]schemaDB, 0, len(dbs))
	for _, s := range dbs {
		dl = append(dl, *s)
	}
	if now := encodeList("schema_dbs", dl); !sameNames(now, cDBs) {
		out["schema_dbs"] = now
	}
	pl := make([]schemaPresent, 0, len(present))
	for _, p := range present {
		pl = append(pl, *p)
	}
	if now := encodeList("schema_present", pl); !sameNames(now, cPresent) {
		out["schema_present"] = now
	}
}

// MSSQLSchemaDue answers 0267's import_mssql_schema_due over the kept lists: the default trace's trust and why, the
// oldest whole read, and the due databases by reason (new, restore, ddl, gap, retry, reconcile), then the oldest read
// first, then the id.
func (s *Store) MSSQLSchemaDue(_ context.Context, instanceID int, snapshotAt time.Time, payload []byte) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	name, err := s.name(instanceID)
	if err != nil {
		return nil, err
	}
	var p map[string]any
	if err := json.Unmarshal(payload, &p); err != nil || p == nil {
		p = map[string]any{}
	}
	now := snapshotAt.UTC()
	if t := timeOf(p, "now"); t != nil {
		now = *t
	}
	noTrace := ""
	if v := strOf(p, "no_trace"); v != nil {
		noTrace = *v
	}
	c, ok := s.cursorLocked(name, "trace_state")
	tsl := decodeList[traceState](c, ok)
	var why *string
	set := func(w string) { why = &w }
	traceOK := false
	switch {
	case noTrace != "":
		set(noTrace)
	case len(tsl) == 0:
		set("the default trace has not been read on this instance")
	case tsl[0].State == "no right":
		set("the default trace cannot be read: the login lacks ALTER TRACE")
	case tsl[0].State == "off":
		set("the default trace is switched off on this server")
	case tsl[0].State == "failed":
		w := "the default trace's last read failed"
		if tsl[0].Note != nil {
			w += ": " + *tsl[0].Note
		}
		set(w)
	case !tsl[0].At.After(snapshotAt.Add(-15 * time.Minute)):
		set("the default trace was last read " + tsl[0].At.UTC().Format("2006-01-02 15:04") + " UTC")
	}
	traceOK = len(tsl) > 0 && tsl[0].State == "read" && tsl[0].At.After(snapshotAt.Add(-15*time.Minute)) && noTrace == ""
	var gap *time.Time
	if g, ok := s.cursorLocked(name, "trace_gap"); ok && g.At != nil {
		gap = g.At
	}
	c, ok = s.cursorLocked(name, "trace_ddl")
	ddl := map[string]time.Time{}
	for _, e := range decodeList[[2]string](c, ok) {
		if t, err := time.Parse(time.RFC3339Nano, e[1]); err == nil {
			ddl[e[0]] = t
		}
	}
	c, ok = s.cursorLocked(name, "schema_dbs")
	dbs := map[int64]schemaDB{}
	var oldest *time.Time
	for _, d := range decodeList[schemaDB](c, ok) {
		dbs[d.ID] = d
		if d.State != "gone" && d.ReadAt != nil && (oldest == nil || d.ReadAt.Before(*oldest)) {
			t := *d.ReadAt
			oldest = &t
		}
	}
	c, ok = s.cursorLocked(name, "schema_present")
	present := map[int64]bool{}
	for _, x := range decodeList[schemaPresent](c, ok) {
		present[x.DBID] = x.Present
	}
	type dueRow struct {
		id     int64
		reason string
		since  *time.Time
	}
	var rows []dueRow
	list, _ := p["dbs"].([]any)
	for _, e := range list {
		m, ok := e.(map[string]any)
		if !ok {
			continue
		}
		id, isNum := toInt64(m["database_id"])
		if !isNum {
			continue
		}
		dname, local, fork, restored := strOf(m, "name"), strOf(m, "create_local"), strOf(m, "fork_guid"), timeOf(m, "restored_at")
		readOnly := toBool(m["read_only"])
		st, have := dbs[id]
		tried := have && st.PartialAt != nil && (st.ReadAt == nil || st.PartialAt.After(*st.ReadAt))
		var since *time.Time
		if have {
			since = st.ReadAt
			if tried {
				since = st.PartialAt
			}
		}
		sameName := have && dname != nil && strings.EqualFold(st.Name, *dname)
		reason := ""
		switch {
		case !have || st.State == "gone":
			reason = "new"
		case !sameStrPtr(st.CreateLocal, local) && !(restored != nil && sameName && st.ReadAt != nil && restored.After(*st.ReadAt)):
			reason = "new"
		case !tried && (st.ReadAt == nil || !present[id]):
			reason = "new"
		case since == nil:
			reason = "new"
		case readOnly:
			if since.Before(now.Add(-24 * time.Hour)) {
				reason = "reconcile"
			}
		case (restored != nil && sameName && restored.After(*since)) || (fork != nil && !sameStrPtr(st.ForkGUID, fork)):
			reason = "restore"
		case traceOK && ddlSince(ddl, *since, dname, &st.Name):
			reason = "ddl"
		case gap != nil && gap.After(*since):
			reason = "gap"
		case st.State == "torn":
			reason = "retry"
		case since.Before(now.Add(-24 * time.Hour)):
			reason = "reconcile"
		}
		if reason != "" {
			rows = append(rows, dueRow{id: id, reason: reason, since: since})
		}
	}
	rank := map[string]int{"new": 1, "restore": 2, "ddl": 3, "gap": 4, "retry": 5, "reconcile": 6}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if rank[a.reason] != rank[b.reason] {
			return rank[a.reason] < rank[b.reason]
		}
		if (a.since == nil) != (b.since == nil) {
			return a.since == nil
		}
		if a.since != nil && !a.since.Equal(*b.since) {
			return a.since.Before(*b.since)
		}
		return a.id < b.id
	})
	type dueOut struct {
		ID     int64  `json:"database_id"`
		Reason string `json:"reason"`
	}
	outDue := []dueOut{}
	for _, r := range rows {
		outDue = append(outDue, dueOut{r.id, r.reason})
	}
	return json.Marshal(struct {
		TraceOK  bool       `json:"trace_ok"`
		TraceWhy *string    `json:"trace_why"`
		Oldest   *time.Time `json:"oldest_read_at"`
		Due      []dueOut   `json:"due"`
	}{traceOK, why, oldest, outDue})
}

// ddlSince: a DDL event of the default trace under one of the names at or after since.
func ddlSince(ddl map[string]time.Time, since time.Time, names ...*string) bool {
	for _, n := range names {
		if n == nil {
			continue
		}
		if t, seen := ddl[*n]; seen && !t.Before(since) {
			return true
		}
	}
	return false
}
