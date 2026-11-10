package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// arg describes one tool argument (its JSON Schema property).
type arg struct {
	name, typ, desc string
	enum            []string
	required        bool
}

// tool is one MCP tool: its schema and the API reads that answer it.
type tool struct {
	Name, Title, Description string
	args                     []arg
	run                      func(ctx context.Context, s *Server, a map[string]any) (any, error)
}

func (t tool) takes(k string) bool {
	for _, a := range t.args {
		if a.name == k {
			return true
		}
	}
	return false
}

func (t tool) argNames() []string {
	var n []string
	for _, a := range t.args {
		n = append(n, a.name)
	}
	if len(n) == 0 {
		return []string{"none"}
	}
	return n
}

func (t tool) schema() map[string]any {
	props := map[string]any{}
	req := []string{}
	for _, a := range t.args {
		p := map[string]any{"type": a.typ, "description": a.desc}
		if len(a.enum) > 0 {
			p["enum"] = a.enum
		}
		props[a.name] = p
		if a.required {
			req = append(req, a.name)
		}
	}
	s := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if len(req) > 0 {
		s["required"] = req
	}
	return s
}

var (
	argInstance = arg{name: "instance", typ: "string", desc: "the instance's name (as fleet_summary lists it) or its instance_id", required: true}
	argFrom     = arg{name: "from", typ: "string", desc: "window start, RFC 3339 (e.g. 2026-11-09T08:00:00Z); default: hours before to"}
	argTo       = arg{name: "to", typ: "string", desc: "window end, RFC 3339; default now"}
	argHours    = arg{name: "hours", typ: "integer", desc: "window length in hours when from is not given (1..744)"}
)

func tools() []tool {
	return []tool{
		{Name: "fleet_summary", Title: "Fleet summary",
			Description: "Every monitored PostgreSQL instance (platform, version, sessions, failing collections) and the fleet's failing daily checks (critical first): the starting point.",
			args:        []arg{{name: "severity", typ: "string", desc: "only checks of this severity", enum: []string{"critical", "warning"}}},
			run:         fleetSummary},
		{Name: "instance_findings", Title: "Instance findings",
			Description: "One instance's failing daily checks (host, storage, vacuum, replication, backups, collections and the rest) and its parameter findings (a setting, its value, the suggested value and why).",
			args:        []arg{argInstance},
			run:         instanceFindings},
		{Name: "blocking_chain", Title: "Blocking chain",
			Description: "The lock-wait chains of one instance at the activity snapshot at or before a time (default the latest): each waiter with its head, depth, the head's state and statement, and the snapshot's session counts.",
			args:        []arg{argInstance, {name: "at", typ: "string", desc: "RFC 3339 time; the snapshot at or before it is read (default the latest)"}},
			run:         blockingChain},
		{Name: "top_statements", Title: "Top statements",
			Description: "One instance's top statements over a window from pg_stat_statements deltas, ordered by total time, calls, IO, mean time, rows, temp or WAL.",
			args: []arg{argInstance, argFrom, argTo, argHours,
				{name: "order", typ: "string", desc: "sort (default time)", enum: []string{"time", "calls", "io", "mean", "rows", "temp", "wal"}},
				{name: "limit", typ: "integer", desc: "rows (1..100, default 20)"}},
			run: topStatements},
		{Name: "plan_findings", Title: "Plan findings",
			Description: "A captured execution plan with the plan rules it hits (plan_id), or, with instance, the plans captured in a window with their rule hits, to find a plan_id.",
			args: []arg{{name: "plan_id", typ: "integer", desc: "the plan to read; without it, instance lists the plans in the window"},
				{name: "instance", typ: "string", desc: "with no plan_id: the instance whose plans to list"},
				{name: "queryid", typ: "string", desc: "with instance: only this statement's plans (any age)"},
				argFrom, argTo, {name: "hours", typ: "integer", desc: "window length in hours when from is not given (1..744, default 24)"}},
			run: planFindings},
		{Name: "table_state", Title: "Table state",
			Description: "One table's latest state on an instance: sizes (heap, TOAST, indexes), live and dead tuples, bloat, visibility, vacuum and analyze times and counts, scans, XID age and the table checks it fails, with its database's summary.",
			args: []arg{argInstance,
				{name: "table", typ: "string", desc: "table name, or schema.table", required: true},
				{name: "database", typ: "string", desc: "database name, when the table name is in more than one"}},
			run: tableState},
		{Name: "storage_forecast", Title: "Storage forecast",
			Description: "Volumes with free space, growth per day over 7 and 30 days and the days until full, soonest first; with instance, also its database and table growth and storage checks.",
			args:        []arg{{name: "instance", typ: "string", desc: "one instance (name or instance_id); without it, the whole fleet and the repository's own size"}},
			run:         storageForecast},
	}
}

func toolList() []any {
	var out []any
	for _, t := range tools() {
		out = append(out, map[string]any{
			"name": t.Name, "title": t.Title, "description": t.Description, "inputSchema": t.schema(),
			"annotations": map[string]any{"title": t.Title, "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
		})
	}
	return out
}

func toolByName(n string) (tool, bool) {
	for _, t := range tools() {
		if t.Name == n {
			return t, true
		}
	}
	return tool{}, false
}

// --- argument helpers ---

func str(a map[string]any, k string) (string, error) {
	v, ok := a[k]
	if !ok || v == nil {
		return "", nil
	}
	switch x := v.(type) {
	case string:
		return strings.TrimSpace(x), nil
	case json.Number:
		return x.String(), nil
	}
	return "", fmt.Errorf("%s must be a string", k)
}

func integer(a map[string]any, k string, def, lo, hi int) (int, error) {
	v, ok := a[k]
	if !ok || v == nil {
		return def, nil
	}
	var n int64
	var err error
	switch x := v.(type) {
	case json.Number:
		n, err = x.Int64()
	case string:
		n, err = strconv.ParseInt(strings.TrimSpace(x), 10, 64)
	default:
		err = errors.New("not a number")
	}
	if err != nil || n < int64(lo) || n > int64(hi) {
		return 0, fmt.Errorf("%s must be an integer %d..%d", k, lo, hi)
	}
	return int(n), nil
}

// window turns from / to / hours into the API's from and to (RFC 3339); the API checks the rest.
func window(a map[string]any, defHours int) (url.Values, error) {
	q := url.Values{}
	from, err := str(a, "from")
	if err != nil {
		return nil, err
	}
	to, err := str(a, "to")
	if err != nil {
		return nil, err
	}
	hours, err := integer(a, "hours", defHours, 1, 744)
	if err != nil {
		return nil, err
	}
	end := time.Now().UTC()
	if to != "" {
		if end, err = time.Parse(time.RFC3339, to); err != nil {
			return nil, fmt.Errorf("to must be RFC 3339 (e.g. 2026-11-09T08:00:00Z): %v", err)
		}
	}
	start := end.Add(-time.Duration(hours) * time.Hour)
	if from != "" {
		if start, err = time.Parse(time.RFC3339, from); err != nil {
			return nil, fmt.Errorf("from must be RFC 3339 (e.g. 2026-11-09T08:00:00Z): %v", err)
		}
	}
	q.Set("from", start.Format(time.RFC3339))
	q.Set("to", end.Format(time.RFC3339))
	return q, nil
}

// instanceRef is one resolved instance.
type instanceRef struct {
	ID   string `json:"instance_id"`
	Name string `json:"name"`
}

// resolve finds an instance by its name (exact, then case-insensitive) or its instance_id.
func (s *Server) resolve(ctx context.Context, a map[string]any, k string) (instanceRef, error) {
	want, err := str(a, k)
	if err != nil {
		return instanceRef{}, err
	}
	if want == "" {
		return instanceRef{}, fmt.Errorf("%s is required (a name from fleet_summary, or an instance_id)", k)
	}
	v, err := s.get(ctx, "/api/instances", nil)
	if err != nil {
		return instanceRef{}, err
	}
	var all []instanceRef
	for _, r := range records(v) {
		all = append(all, instanceRef{ID: fmt.Sprint(r["instance_id"]), Name: fmt.Sprint(r["name"])})
	}
	for _, r := range all {
		if r.Name == want || r.ID == want {
			return r, nil
		}
	}
	for _, r := range all {
		if strings.EqualFold(r.Name, want) {
			return r, nil
		}
	}
	var names []string
	for i, r := range all {
		if i == 30 {
			names = append(names, fmt.Sprintf("... %d more", len(all)-30))
			break
		}
		names = append(names, r.Name)
	}
	return instanceRef{}, fmt.Errorf("no active instance %q; known: %s", want, strings.Join(names, ", "))
}

// records turns an API table {columns, rows} into one object per row.
func records(v any) []map[string]any {
	m, ok := v.(map[string]any)
	if !ok {
		return nil
	}
	cols, _ := m["columns"].([]any)
	rows, _ := m["rows"].([]any)
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		cells, _ := r.([]any)
		rec := make(map[string]any, len(cols))
		for i, c := range cols {
			if i < len(cells) {
				rec[fmt.Sprint(c)] = cells[i]
			}
		}
		out = append(out, rec)
	}
	return out
}

func field(v any, k string) any {
	if m, ok := v.(map[string]any); ok {
		return m[k]
	}
	return nil
}

// --- the tools ---

func fleetSummary(ctx context.Context, s *Server, a map[string]any) (any, error) {
	sev, err := str(a, "severity")
	if err != nil {
		return nil, err
	}
	if sev != "" && sev != "critical" && sev != "warning" {
		return nil, errors.New("severity must be critical or warning")
	}
	inst, err := s.get(ctx, "/api/instances", nil)
	if err != nil {
		return nil, err
	}
	ov, err := s.get(ctx, "/api/overview", nil)
	if err != nil {
		return nil, err
	}
	counts := map[string]int{}
	checks := []map[string]any{}
	for _, r := range records(ov) {
		v := fmt.Sprint(r["severity"])
		counts[v]++
		if sev == "" || v == sev {
			checks = append(checks, r)
		}
	}
	return map[string]any{"instances": records(inst), "check_counts": counts, "checks": checks}, nil
}

func instanceFindings(ctx context.Context, s *Server, a map[string]any) (any, error) {
	in, err := s.resolve(ctx, a, "instance")
	if err != nil {
		return nil, err
	}
	ov, err := s.get(ctx, "/api/overview", nil)
	if err != nil {
		return nil, err
	}
	checks := []map[string]any{}
	for _, r := range records(ov) {
		if fmt.Sprint(r["instance_id"]) == in.ID {
			delete(r, "instance_id")
			delete(r, "instance")
			checks = append(checks, r)
		}
	}
	f, err := s.get(ctx, "/api/findings", url.Values{"instance": {in.ID}})
	if err != nil {
		return nil, err
	}
	return map[string]any{"instance": in, "checks": checks, "parameter_findings": records(f)}, nil
}

func blockingChain(ctx context.Context, s *Server, a map[string]any) (any, error) {
	in, err := s.resolve(ctx, a, "instance")
	if err != nil {
		return nil, err
	}
	q := url.Values{"instance": {in.ID}}
	at, err := str(a, "at")
	if err != nil {
		return nil, err
	}
	if at != "" {
		if _, err := time.Parse(time.RFC3339, at); err != nil {
			return nil, fmt.Errorf("at must be RFC 3339 (e.g. 2026-11-09T08:00:00Z): %v", err)
		}
		q.Set("at", at)
	}
	v, err := s.get(ctx, "/api/activity", q)
	if err != nil {
		return nil, err
	}
	snap := field(v, "snapshot_at")
	out := map[string]any{"instance": in, "snapshot_at": snap}
	if snap == nil {
		out["note"] = "no activity snapshot at or before that time"
		return out, nil
	}
	sum := records(field(v, "summary"))
	if len(sum) > 0 {
		delete(sum[0], "instance_id")
		out["sessions"] = sum[0]
	}
	chains := records(field(v, "chains"))
	out["chains"] = chains
	heads := map[string]bool{}
	for _, c := range chains {
		heads[fmt.Sprint(c["head_pid"])] = true
	}
	out["heads"] = len(heads)
	if len(chains) == 0 {
		out["note"] = "no session waited on a lock at this snapshot"
	}
	return out, nil
}

func topStatements(ctx context.Context, s *Server, a map[string]any) (any, error) {
	in, err := s.resolve(ctx, a, "instance")
	if err != nil {
		return nil, err
	}
	q, err := window(a, 1)
	if err != nil {
		return nil, err
	}
	order, err := str(a, "order")
	if err != nil {
		return nil, err
	}
	if order == "" {
		order = "time"
	}
	limit, err := integer(a, "limit", 20, 1, 100)
	if err != nil {
		return nil, err
	}
	q.Set("instance", in.ID)
	q.Set("order", order)
	q.Set("limit", strconv.Itoa(limit))
	v, err := s.get(ctx, "/api/statements", q)
	if err != nil {
		return nil, err
	}
	return map[string]any{"instance": in, "from": q.Get("from"), "to": q.Get("to"), "order": order, "statements": records(v)}, nil
}

func planFindings(ctx context.Context, s *Server, a map[string]any) (any, error) {
	id, err := integer(a, "plan_id", 0, 1, 1<<62)
	if err != nil {
		return nil, err
	}
	if id > 0 {
		v, err := s.get(ctx, "/api/plan", url.Values{"id": {strconv.Itoa(id)}})
		if err != nil {
			return nil, err
		}
		plan := records(field(v, "plan"))
		out := map[string]any{"hits": records(field(v, "hits"))}
		if len(plan) > 0 {
			out["plan"] = plan[0]
		}
		return out, nil
	}
	if _, ok := a["instance"]; !ok {
		return nil, errors.New("give plan_id, or instance to list the plans captured in a window")
	}
	in, err := s.resolve(ctx, a, "instance")
	if err != nil {
		return nil, err
	}
	q, err := window(a, 24)
	if err != nil {
		return nil, err
	}
	q.Set("instance", in.ID)
	qid, err := str(a, "queryid")
	if err != nil {
		return nil, err
	}
	if qid != "" {
		q.Set("queryid", qid)
	}
	v, err := s.get(ctx, "/api/plans", q)
	if err != nil {
		return nil, err
	}
	return map[string]any{"instance": in, "from": q.Get("from"), "to": q.Get("to"), "plans": records(field(v, "plans"))}, nil
}

func tableState(ctx context.Context, s *Server, a map[string]any) (any, error) {
	in, err := s.resolve(ctx, a, "instance")
	if err != nil {
		return nil, err
	}
	name, err := str(a, "table")
	if err != nil {
		return nil, err
	}
	if name == "" {
		return nil, errors.New("table is required (a name, or schema.table)")
	}
	db, err := str(a, "database")
	if err != nil {
		return nil, err
	}
	v, err := s.get(ctx, "/api/tables", url.Values{"instance": {in.ID}})
	if err != nil {
		return nil, err
	}
	schema, rel := "", name
	if i := strings.LastIndex(name, "."); i > 0 {
		schema, rel = name[:i], name[i+1:]
	}
	match := func(fold bool) []map[string]any {
		eq := func(x, y string) bool { return x == y || (fold && strings.EqualFold(x, y)) }
		var out []map[string]any
		for _, r := range records(field(v, "tables")) {
			if !eq(fmt.Sprint(r["table_name"]), rel) || (schema != "" && !eq(fmt.Sprint(r["schema_name"]), schema)) ||
				(db != "" && !eq(fmt.Sprint(r["datname"]), db)) {
				continue
			}
			out = append(out, r)
		}
		return out
	}
	found := match(false)
	if len(found) == 0 {
		found = match(true)
	}
	if len(found) == 0 {
		return nil, fmt.Errorf("no table %q on %s in the latest tables snapshot (the collection keeps the largest and the most changed tables of each database)", name, in.Name)
	}
	dbs := map[string]bool{}
	for _, r := range found {
		dbs[fmt.Sprint(r["datname"])] = true
	}
	var sums []map[string]any
	for _, r := range records(field(v, "databases")) {
		if dbs[fmt.Sprint(r["datname"])] {
			sums = append(sums, r)
		}
	}
	out := map[string]any{"instance": in, "tables": found, "database_summary": sums}
	if len(found) > 1 {
		names := make([]string, 0, len(found))
		for _, r := range found {
			names = append(names, fmt.Sprintf("%v.%v.%v", r["datname"], r["schema_name"], r["table_name"]))
		}
		sort.Strings(names)
		out["note"] = "more than one table matched: " + strings.Join(names, ", ") + " (give database or schema.table)"
	}
	return out, nil
}

func storageForecast(ctx context.Context, s *Server, a map[string]any) (any, error) {
	if _, ok := a["instance"]; !ok {
		v, err := s.get(ctx, "/api/storage/fleet", nil)
		if err != nil {
			return nil, err
		}
		return map[string]any{"volumes": records(field(v, "volumes")), "repository": records(field(v, "repository"))}, nil
	}
	in, err := s.resolve(ctx, a, "instance")
	if err != nil {
		return nil, err
	}
	v, err := s.get(ctx, "/api/storage", url.Values{"instance": {in.ID}})
	if err != nil {
		return nil, err
	}
	return map[string]any{"instance": in, "volumes": records(field(v, "volumes")), "databases": records(field(v, "databases")),
		"tables": records(field(v, "tables")), "checks": records(field(v, "checks"))}, nil
}

// limit caps every list at MaxRows and every string at MaxText, naming each cut.
func (s *Server) limit(v any) any {
	switch x := v.(type) {
	case map[string]any:
		cuts := map[string]string{}
		for k, e := range x {
			if l, ok := e.([]map[string]any); ok && len(l) > s.MaxRows {
				cuts[k+"_cut"] = fmt.Sprintf("%d of %d rows shown", s.MaxRows, len(l))
				e = l[:s.MaxRows]
			}
			x[k] = s.limit(e)
		}
		for k, c := range cuts {
			x[k] = c
		}
		return x
	case []map[string]any:
		for i := range x {
			x[i] = s.limit(x[i]).(map[string]any)
		}
		return x
	case []any:
		for i := range x {
			x[i] = s.limit(x[i])
		}
		return x
	case string:
		x = s.scrub(x)
		if r := []rune(x); len(r) > s.MaxText {
			return string(r[:s.MaxText]) + fmt.Sprintf(" ... [cut at %d of %d characters]", s.MaxText, len(r))
		}
		return x
	case instanceRef:
		return map[string]any{"instance_id": s.limit(x.ID), "name": s.limit(x.Name)}
	}
	return v
}
