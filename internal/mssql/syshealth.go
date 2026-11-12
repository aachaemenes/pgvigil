package mssql

import (
	"context"
	"database/sql"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_syshealth: the component results of sp_server_diagnostics, as system_health keeps them.
//
// SQL Server runs sp_server_diagnostics for itself every five minutes and its system_health session records the
// result of four components (SYSTEM, RESOURCE, QUERY_PROCESSING, IO_SUBSYSTEM): a state (CLEAN, WARNING, ERROR) and
// a document of figures. The reader takes each result from the session's event file, past a cursor of its own
// (source 'syshealth': the Extended Events reader keeps another for the deadlock reports it takes from the same
// files), and stores the state with the figures a finding is made of:
//
//	SYSTEM            spinlock backoffs and a sick spinlock type, latch warnings, access violations, dump requests,
//	                  non-yielding tasks, bad pages detected and fixed, page faults, CPU
//	QUERY_PROCESSING  workers (most, created, idle), pending tasks and the oldest one's wait, the unresolvable
//	                  deadlock and deadlocked schedulers flags
//	IO_SUBSYSTEM      IO latch timeouts, long IOs, the longest pending requests with their files
//	RESOURCE          the last memory notification, out-of-memory exceptions, a pool out of memory, and the memory
//	                  report (process and system counts, the memory manager's figures)
//
// The session is the server's own: pgvigil reads it and never creates, changes, starts or stops it. Needs VIEW
// SERVER STATE; a login without it is the state "no right", never a failure. Not on Azure SQL Database.
//
// Which figures matter and at which value follows sp_HealthParser (Darling Data, LLC; MIT) and the System Events
// page of PerformanceMonitor (the same author; MIT); the reader and its statements are pgvigil's own.

type sysHealthCollector struct{}

// sysHealthEvent is the event the reader stores.
const sysHealthEvent = "sp_server_diagnostics_component_result"

func init() {
	Register(sysHealthCollector{})
	// the event file is read with the Extended Events reader's own file loop, which finds an event's parser by name
	xeParsers[sysHealthEvent] = parseComponentResult
}

func (sysHealthCollector) Name() string                   { return Prefix + "syshealth" }
func (sysHealthCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

// Timeout: the first read goes through every file of the session (weeks of it on a quiet server).
func (sysHealthCollector) Timeout() time.Duration { return 2 * time.Minute }

func (sysHealthCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database (it has no server-scoped system_health session)"
	}
	return true, ""
}

// Run is not the collection's path: RunOnce sends a BatchCollector to RunBatches.
func (sysHealthCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_syshealth reads from a cursor: it runs through the batch path (RunBatches)")
}

// sysHealthBatch is the most events of the file one batch passes over: the session writes mostly events this reader
// does not store (they come back without their XML and only move the cursor).
var sysHealthBatch = envInt("PGVIGIL_MSSQL_SYSHEALTH_BATCH", 20000)

// componentNumber reads an attribute's value as a number where it is one (an address such as 0x0 stays text).
func componentNumber(s string) any {
	s = strings.TrimSpace(s)
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		return n
	}
	if len(s) > 0 && (s[0] >= '0' && s[0] <= '9' || s[0] == '-' || s[0] == '.') && !strings.HasPrefix(strings.ToLower(s), "0x") {
		if f, err := strconv.ParseFloat(s, 64); err == nil {
			return f
		}
	}
	return s
}

// sysHealthLongestMax is how many of an IO result's longest pending requests are kept.
const sysHealthLongestMax = 5

// componentDetail takes a component's document apart: the root element's attributes under the server's own names
// (numbers as numbers), a RESOURCE result's memory report entries under "memory" by their description, and an
// IO_SUBSYSTEM result's longest pending requests under "longest". The long lists a QUERY_PROCESSING result carries
// (top waits, CPU-intensive requests, blocked-process reports) are not stored. A document that does not parse gives
// what was read before the fault.
func componentDetail(doc string) map[string]any {
	out := map[string]any{}
	if strings.TrimSpace(doc) == "" {
		return out
	}
	d := xml.NewDecoder(strings.NewReader(doc))
	depth := 0
	memory := map[string]any{}
	var longest []map[string]any
	for {
		tok, err := d.Token()
		if errors.Is(err, io.EOF) || err != nil {
			break
		}
		switch el := tok.(type) {
		case xml.StartElement:
			depth++
			switch {
			case depth == 1:
				for _, a := range el.Attr {
					out[a.Name.Local] = componentNumber(a.Value)
				}
			case el.Name.Local == "entry":
				var desc, val string
				for _, a := range el.Attr {
					switch a.Name.Local {
					case "description":
						desc = a.Value
					case "value":
						val = a.Value
					}
				}
				if desc != "" {
					memory[desc] = componentNumber(val)
				}
			case el.Name.Local == "pendingRequest" && len(longest) < sysHealthLongestMax:
				req := map[string]any{}
				for _, a := range el.Attr {
					req[a.Name.Local] = componentNumber(a.Value)
				}
				longest = append(longest, req)
			}
		case xml.EndElement:
			depth--
		}
	}
	if len(memory) > 0 {
		out["memory"] = memory
	}
	if len(longest) > 0 {
		out["longest"] = longest
	}
	return out
}

// parseComponentResult turns one sp_server_diagnostics_component_result event into its row.
func parseComponentResult(e *xeEvent, c xeContext) collect.Row {
	t, ok := e.at()
	if !ok {
		return nil
	}
	component, _ := e.mapped("component").(string)
	component = strings.ToUpper(strings.TrimSpace(component))
	if component == "" {
		return nil
	}
	state, _ := e.mapped("state").(string)
	state = strings.ToUpper(strings.TrimSpace(state))
	if state == "" {
		state = "UNKNOWN"
	}
	detail := componentDetail(e.doc("data"))
	if component == "QUERY_PROCESSING" {
		// its blockingTasks: system_health's blocked-process reports, stored as reports by the repository (0116)
		if b := blockingTasks(t, e.doc("data"), c); len(b) > 0 {
			detail[BlockingTasksKey] = b
		}
	}
	return collect.Row{"kind": "component", "event_at": t.Format(time.RFC3339Nano), "component": component, "state": state,
		"detail": detail}
}

// RunBatches reads system_health's event file past the reader's cursor and stores the component results.
func (sysHealthCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	if !info.ViewServerState {
		return emit([]collect.Row{readerStateRow(sysHealthSource, readerNoRight,
			"the login lacks VIEW SERVER STATE: the system_health session and its event file cannot be read")})
	}
	targets, err := xeListTargets(ctx, conn, info)
	if err != nil {
		if noRightError(err) {
			return emit([]collect.Row{readerStateRow(sysHealthSource, readerNoRight, "the login may not read the event sessions: "+err.Error())})
		}
		return err
	}
	s := xeGroup(targets)["system_health"]
	switch {
	case s == nil:
		return emit([]collect.Row{readerStateRow(sysHealthSource, readerOff, "this server has no system_health session")})
	case !s.running:
		return emit([]collect.Row{readerStateRow(sysHealthSource, readerOff,
			"the system_health session is stopped (SQL Server starts it with the server): ALTER EVENT SESSION [system_health] ON SERVER STATE = START is the DBA's step")})
	}
	failed := func(err error) error {
		return emit([]collect.Row{readerStateRow(sysHealthSource, readerFailed, err.Error()),
			{"kind": "collector_error", "source": "system_health", "message": err.Error()}})
	}
	t, ok := s.targets["event_file"]
	if !ok {
		// a session a DBA changed, or a platform that writes it to a ring buffer only: not a failed read
		return emit([]collect.Row{readerStateRow(sysHealthSource, readerOff,
			"system_health has no event_file target on this server: this reader takes the component results from the file only")})
	}
	var ft xeFileTarget
	if err := xml.Unmarshal([]byte(t.targetData), &ft); err != nil || ft.File.Name == "" {
		return failed(errors.New("the event file target of system_health names no file"))
	}
	pattern := xeFilePattern(ft.File.Name)
	if pattern == "" {
		return failed(fmt.Errorf("the event file of system_health has an unexpected name: %s", ft.File.Name))
	}
	r := &xeRun{ctx: ctx, conn: conn, info: info, opt: opt, cursor: cursor, emit: emit, now: time.Now()}
	side := collect.Row{}
	if err := r.readFile(sysHealthSource, pattern, []string{sysHealthEvent}, sysHealthBatch,
		xeContext{source: "system_health", session: "system_health", queryText: opt.QueryText}, side); err != nil {
		if noRightError(err) {
			return emit([]collect.Row{readerStateRow(sysHealthSource, readerNoRight, "the login may not read the event file: "+err.Error())})
		}
		return failed(err)
	}
	state := readerStateRow(sysHealthSource, readerRead, "")
	state["scope"] = "event_file"
	state["scanned"], state["stored"] = side["new_events"], side["new_events"]
	if note, ok := side["note"].(string); ok {
		state["note"] = strOrNil(note)
	}
	if cur, err := cursor(ctx, sysHealthSource); err == nil && cur.Found {
		state["newest_at"] = instantText(cur.LastEventAt)
	}
	return emit([]collect.Row{state})
}
