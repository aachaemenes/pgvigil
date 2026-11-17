package web

// Save Table's write door (task 7b, DBA Dash's From Data Table / From Grid): POST /api/actions/save_table writes a
// grid's rows as a NEW table into the door login's own schema pgvigil_saved on the page's own instance, through the
// instance's actions login; GET /api/actions/save_table says whether the From items are on there, and offers the
// databases. An administrator's opt-in, off by default: doors: save_table in pgvigil.yaml AND save_table in the
// instance's actions: list (internal/savetable has the gates, the identifiers and the values' rules; internal/actions
// and internal/mssql the two engines' connections and writes).
//
// The gates, in order: the X-Pgvigil header and the admin role (s.post); doors.save_table on, not queue mode, the
// actions door's audit on; one save at a time in this serve (TryLock: never a waiting Lock); the write deadline moved
// past the save's budget (review-29 S4: serve's WriteTimeout is 75 s); the body through MaxBytesReader and Decode's
// streamed limits (S5); the instance, not a page instance. None of those writes an audit row (as every action). Then
// the audit door first - no audit, no write - and savetable.Check's gates 5-9, each refusal an audit row; then a
// 'started' row, the write, and its end row (review-29 N7).
//
// The routes are wired by scripts/savetable-wiring.patch (web.go's two lines, serve.go's switch, report.go's key).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/savetable"
)

// saveTableBodyMax is the body's cap: 32 MiB (a larger grid: Script Data Table writes it as a file).
const saveTableBodyMax = 32 << 20

// saveTableBudget is a save's work: the statement and the bulk copy; the write deadline is moved past it.
const saveTableBudget = 120 * time.Second

// saveTableBusy is the refusal while another save runs in this serve.
const saveTableBusy = "another Save Table is running on this serve: try again when it ends"

func init() {
	routeWhat["POST /api/actions/save_table"] = "saving a grid as a table on an instance"
}

// saveTableState is one serve's switch and its one-save-at-a-time lock.
type saveTableState struct {
	on bool
	mu sync.Mutex
}

var saveTables sync.Map // *Server -> *saveTableState

// EnableSaveTable is serve's doors.save_table (the wiring patch): off unless pgvigil.yaml turns it on.
func (s *Server) EnableSaveTable(on bool) { saveTables.Store(s.self(), &saveTableState{on: on}) }

func (s *Server) saveTable() *saveTableState {
	if v, ok := saveTables.Load(s.self()); ok {
		return v.(*saveTableState)
	}
	return &saveTableState{} // never enabled: off
}

// saveDoor is either engine's door: the two connections Save Table checks on and writes through.
type saveDoor interface {
	SaveConns(ctx context.Context, database string, budget time.Duration) (savetable.Conn, savetable.Writer, func(), error)
}

// saveInstance is what the config says of the instance (savetable.Instance) and its door, nil when it has none here.
func (s *Server) saveInstance(name, engine string) (savetable.Instance, saveDoor) {
	in := savetable.Instance{Name: name, Engine: engine}
	ds := s.doorsNow()
	switch engine {
	case savetable.Postgres:
		if d, ok := ds.PG[name]; ok {
			in.Page, in.Allowed = d.Page, slices.Contains(d.Allow, "save_table")
			in.Configured, in.Resolved = d.Configured || d.Actions != "", d.Actions != ""
			return in, d
		}
	case savetable.SQLServer:
		if d, ok := ds.MS[name]; ok {
			in.Page, in.Allowed = d.Page, slices.Contains(d.Allow, "save_table")
			in.Configured, in.Resolved = d.Configured || d.Actions != "", d.Actions != ""
			return in, d
		}
	}
	return in, nil
}

// saveDatabases is the instance's databases as its last read lists them (present ones; SQL Server's snapshots left
// out: read only).
func (s *Server) saveDatabases(ctx context.Context, id int, engine string) ([]savetable.Database, error) {
	q := `SELECT datname, 0, coalesce(is_template, false), false FROM pgvigil.databases
	       WHERE instance_id = $1 AND is_present ORDER BY datname`
	if engine == savetable.SQLServer {
		q = `SELECT database_name, coalesce(database_id, 0), false, false FROM pgvigil.mssql_database_option
		      WHERE instance_id = $1 AND is_present AND NOT is_snapshot ORDER BY database_name`
	}
	rows, err := s.pool.Query(ctx, q, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []savetable.Database
	for rows.Next() {
		var d savetable.Database
		if err := rows.Scan(&d.Name, &d.ID, &d.IsTemplate, &d.IsDistributor); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// saveInstanceOf reads the instance's name and engine.
func (s *Server) saveInstanceOf(ctx context.Context, id int) (string, string, error) {
	var name, engine string
	err := s.pool.QueryRow(ctx, `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name, &engine)
	return name, engine, err
}

// saveOff is why the From items are off for every instance of this serve, "" when the serve lets them on.
func (s *Server) saveOff() string {
	switch {
	case !s.saveTable().on:
		return savetable.OffSwitch
	case s.queue() != nil:
		return queueNotYet
	case s.actions == nil:
		return "off: actions are off on this server"
	case s.actions.off != "":
		return "off: " + s.actions.off
	}
	return ""
}

// SaveTableState is GET /api/actions/save_table?instance_id=N: {on, off, instance, engine, databases, confirm} - off
// holds the first switch that is off (the lead 11-17 02:17's order; the schema is read at Save), databases the ones
// a table may go into (system and template ones left out).
func (s *Server) SaveTableState(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.URL.Query().Get("instance_id"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	name, engine, err := s.saveInstanceOf(ctx, id)
	if err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	in, _ := s.saveInstance(name, engine)
	off := s.saveOff()
	if off == "" {
		off = savetable.OffWords(true, in)
	}
	if off == "" && !s.roleCan(r)["admin"] {
		off = "off: saving a grid as a table needs the admin role"
	}
	out := map[string]any{"on": off == "", "off": off, "instance": name, "engine": engine, "databases": []string{}}
	if off == "" {
		dbs, err := s.saveDatabases(ctx, id, engine)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the instance's databases: %w", err))
			return
		}
		names := []string{}
		for _, d := range dbs {
			if savetable.RefuseDatabase(engine, d) == "" {
				names = append(names, d.Name)
			}
		}
		out["databases"] = names
		out["schema"] = savetable.Schema
	}
	writeJSONNoStore(w, http.StatusOK, out)
}

// SaveTable is POST /api/actions/save_table?instance_id=N (admin; the body: savetable.Body).
func (s *Server) SaveTable(w http.ResponseWriter, r *http.Request) {
	// review-29 S4: the deadline first, as AppImport (q_app_import.go); a writer that cannot move it keeps the save
	// inside serve's 75 s
	budget := saveTableBudget
	if err := http.NewResponseController(w).SetWriteDeadline(time.Now().Add(budget + 30*time.Second)); err != nil {
		budget = 60 * time.Second
	}
	if off := s.saveOff(); off != "" {
		writeErr(w, http.StatusForbidden, errors.New(off))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	st := s.saveTable()
	if !st.mu.TryLock() {
		writeErr(w, http.StatusConflict, errors.New(saveTableBusy))
		return
	}
	defer st.mu.Unlock()
	id, err := strconv.Atoi(r.URL.Query().Get("instance_id"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), budget)
	defer cancel()
	name, engine, err := s.saveInstanceOf(ctx, id)
	if err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	b, err := savetable.Decode(http.MaxBytesReader(w, r.Body, saveTableBodyMax), engine, savetable.DefaultLimits)
	if err != nil {
		if mbe := (*http.MaxBytesError)(nil); errors.As(err, &mbe) {
			writeErr(w, http.StatusRequestEntityTooLarge, errors.New("the grid is over 32 MiB: Script Data Table writes it as a file"))
			return
		}
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if b.InstanceID != id {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("the body names instance %d, the request %d: nothing was written", b.InstanceID, id))
		return
	}
	in, door := s.saveInstance(name, engine)
	if in.Page {
		writeErr(w, http.StatusForbidden, errors.New(savetable.OffWords(true, in)))
		return
	}
	// the audit door first: an attempt that cannot be written is not made (as every action, actions.go)
	if err := s.actions.audit.Ping(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was written", err))
		return
	}
	var may bool
	if err := s.actions.audit.QueryRow(ctx, `SELECT coalesce(has_function_privilege(to_regprocedure('pgvigil.import_save_table_log(int, timestamptz, jsonb)'), 'EXECUTE'), false)`).Scan(&may); err != nil || !may {
		writeErr(w, http.StatusServiceUnavailable, errors.New("the audit login may not write Save Table's rows (pgvigil.import_save_table_log: migrate the repository): nothing was written"))
		return
	}
	dbs, err := s.saveDatabases(ctx, id, engine)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the instance's databases: %w", err))
		return
	}
	var act savetable.Writer
	closeAll := func() {}
	defer func() { closeAll() }()
	open := func(ctx context.Context) (savetable.Conn, savetable.Conn, error) {
		if door == nil {
			return nil, nil, errors.New("the instance has no actions door here")
		}
		m, a, c, err := door.SaveConns(ctx, b.Database, budget)
		if err != nil {
			return nil, nil, err
		}
		act, closeAll = a, c
		return m, a, nil
	}
	v := savetable.Check(ctx, in, dbs, b, open)
	t := savetable.Target{Database: b.Database, Schema: savetable.Schema, Table: b.Table}
	from := "From Grid"
	if b.From == "data" {
		from = "From Data Table"
	}
	row := map[string]any{"instance_name": name, "ui_user": user, "client": clientIP(r), "action": "save_table",
		"reason": "Save Table: " + from, "datname": b.Database, "target": t.Display()}
	audit := func(outcome, detail string) error {
		row["at"], row["outcome"], row["detail"] = time.Now(), outcome, detail
		p, err := json.Marshal([]any{row})
		if err == nil {
			_, err = s.actions.audit.Exec(context.WithoutCancel(ctx), `SELECT pgvigil.import_save_table_log($1, now(), $2::jsonb)`, id, string(p))
		}
		if err != nil {
			s.log.Error("save table: the audit row was not written", "instance", name, "target", t.Display(), "user", user,
				"outcome", outcome, "detail", detail, "err", err)
		}
		return err
	}
	answer := func(outcome, detail string, n int64) {
		code := http.StatusOK
		switch outcome {
		case "refused":
			code = http.StatusConflict
		case "failed":
			code = http.StatusBadGateway
		}
		s.log.Info("save table: attempt", "instance", name, "target", t.Display(), "user", user, "outcome", outcome, "detail", detail)
		writeJSONNoStore(w, code, map[string]any{"outcome": outcome, "detail": detail, "rows": n})
	}
	if v.Outcome != "" {
		if err := audit(v.Outcome, v.Words); err != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s: %s; the audit row could not be written: %v", v.Outcome, v.Words, err))
			return
		}
		answer(v.Outcome, v.Words, 0)
		return
	}
	if err := audit("started", fmt.Sprintf("%d rows, %d columns", len(v.Rows), len(b.Cols))); err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was written", err))
		return
	}
	n, err := act.Write(ctx, t, b.Cols, v.Rows)
	outcome, detail := "done", fmt.Sprintf("Saved %d rows to %s", n, t.Display())
	switch {
	case errors.Is(err, savetable.ErrExists):
		outcome, detail, n = "refused", fmt.Sprintf("the table %s exists: pgvigil never overwrites a table", t.Display()), 0
	case err != nil:
		outcome, detail, n = "failed", fmt.Sprintf("the save of %s failed, nothing was kept (the transaction rolled back): %v", t.Display(), err), 0
	case v.NULs > 0:
		detail += fmt.Sprintf("; %d NUL character(s) dropped from text cells", v.NULs)
	}
	if err := audit(outcome, detail); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s: %s; its audit row could not be written (the started row stands): %v", outcome, detail, err))
		return
	}
	answer(outcome, detail, n)
}
