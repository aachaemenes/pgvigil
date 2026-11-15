package mssql

// mssql_custom (ST6): the custom: checks written for SQL Server (engine: sqlserver, or a procedure:), run as the
// instance's read login on the instances their instances / tags reach, at each check's cadence, into the same store
// as PostgreSQL's custom checks (pgvigil.import_mssql_custom, migration 0262, is import_custom for a SQL Server
// instance): the Custom tab, the Custom report, the findings and the alerts serve both engines.
//
// The fence (docs/custom.md 'SQL Server'): a transaction does not hold the DBA's own T-SQL - a COMMIT in the text ends
// it, and a trace, an EXECUTE AS, CONTEXT_INFO, SESSION_CONTEXT or a session applock outlives its rollback - so the
// LOGIN'S RIGHTS are the fence, as on PostgreSQL:
//   - before any check the run reads the login's rights (mssqlread.Fence) and refuses the whole collection on the
//     instance, naming each right, when it holds one outside the documented read login's on the server, or a right
//     that writes in ANY database it can open (a check's own T-SQL reaches every one: USE, a three-part name);
//   - each check runs on a CONNECTION OF ITS OWN, closed after it, so nothing a check leaves on its session reaches the
//     next one; inside it: SET XACT_ABORT ON; BEGIN TRANSACTION; EXEC sys.sp_executesql @check; then a rollback;
//   - after it the run reads sys.traces again: a trace the check made, started or stopped is the check's error
//     (pgvigil never stops or closes one: that is the DBA's hand); a check that ended its transaction (Msg 266) is its
//     error too.
//
// A check's result is its FIRST result set: the value of its value column (or its row count), at most
// collect.CustomMaxRows rows kept (only under query_text full), each cell capped; a later result set is counted in its
// note and not read.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssqlread"
)

const (
	// customCheckTimeout bounds one check: its connection, its rights read, its batch and its after-read
	customCheckTimeout = 30 * time.Second
	// customMaxTimeout bounds a whole run however many checks are due
	customMaxTimeout = 10 * time.Minute
)

type customCollector struct {
	mu   sync.Mutex
	last map[string]time.Time // instance NUL check -> the start of its last run in this process
}

func init() { Register(&customCollector{last: map[string]time.Time{}}) }

func (*customCollector) Name() string                   { return "mssql_custom" }
func (*customCollector) DefaultInterval() time.Duration { return time.Minute }

// sqlServerChecks are the configured checks written for SQL Server; ok = the file has a custom: key.
func sqlServerChecks() ([]collect.CustomCheck, bool) {
	all, ok := collect.CustomChecks()
	var out []collect.CustomCheck
	for _, c := range all {
		if c.EngineOf() == config.EngineSQLServer {
			out = append(out, c)
		}
	}
	return out, ok
}

// customOff says why the collection does not visit SQL Server instances ("" = it does): no custom: key, or no check
// of the list is written for SQL Server.
func customOff() string {
	cs, ok := sqlServerChecks()
	switch {
	case !ok:
		return "no custom: list in the configuration"
	case len(cs) == 0:
		return "no custom: check with engine: sqlserver"
	}
	return ""
}

func (*customCollector) Applies(Info) (bool, string) {
	if why := customOff(); why != "" {
		return false, why
	}
	return true, ""
}

// Wants is asked before the frame connects: while the file has no SQL Server check, no SQL Server instance is
// connected to for it. An instance no check reaches is still visited while one exists, so a check taken off it is
// marked gone at its next run (as on PostgreSQL).
func (*customCollector) Wants(config.Instance) (bool, string) {
	if why := customOff(); why != "" {
		return false, why
	}
	return true, ""
}

// Timeout: a check's own bound for each check of the list, and one more for the fence, at most customMaxTimeout.
func (*customCollector) Timeout() time.Duration {
	cs, _ := sqlServerChecks()
	t := customCheckTimeout * time.Duration(len(cs)+1)
	if t > customMaxTimeout {
		t = customMaxTimeout
	}
	return t
}

func (*customCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_custom runs per instance (the frame's InstanceCollector: scripts/proof-st6-wiring.patch)")
}

// due says whether a check runs at now on the instance, and records the run when it does.
func (cc *customCollector) due(inst string, c collect.CustomCheck, now time.Time) bool {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	k := inst + "\x00" + c.Name
	if t, ok := cc.last[k]; ok && now.Sub(t) < c.Cadence()-collect.CustomSlack && now.After(t) {
		return false
	}
	cc.last[k] = now
	return true
}

// RunInstance runs the instance's due checks. The payload is the PostgreSQL collection's (import_custom's): one
// state row (every check that applies to the instance, due or not, so the repository marks the others gone), one
// check row per such check (its definition, its sql the batch as it runs), and one result row per check run now.
func (cc *customCollector) RunInstance(ctx context.Context, conn *sql.Conn, info Info, in config.Instance) ([]collect.Row, error) {
	checks := collect.CustomFor(in)
	if len(checks) > 0 {
		why, err := mssqlread.Fence(ctx, conn)
		if err != nil {
			return nil, fmt.Errorf("custom: %w", err)
		}
		if why != "" {
			return nil, fmt.Errorf("custom checks refused on this instance: %s; the custom checks run the DBA's own T-SQL and run only as the documented read login (docs/custom.md 'SQL Server')", why)
		}
	}
	names := make([]string, 0, len(checks))
	for _, c := range checks {
		names = append(names, c.Name)
	}
	rows := []collect.Row{{"kind": "state", "checks": names}}
	for _, c := range checks {
		rows = append(rows, collect.Row{
			"kind": "check", "check_name": c.Name, "description": nilIfEmpty(c.Description), "sql": customBatch(c),
			"every_secs": int(c.Cadence() / time.Second), "rule": c.Rule, "value_column": nilIfEmpty(c.Value),
			"compare": c.Compare, "warning": c.Warning, "critical": c.Critical, "targets": c.Targets(),
		})
	}
	now := time.Now()
	for _, c := range checks {
		if !cc.due(in.Name, c, now) {
			continue
		}
		res := runCustomCheck(ctx, in, info, c)
		rows = append(rows, res.row(c.Name))
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return rows, nil
}

// customBatch is the check's T-SQL as it runs inside sp_executesql: its sql: (after USE [database] when it names
// one), or the EXEC of its procedure: with no parameter, every part quoted.
func customBatch(c collect.CustomCheck) string {
	if c.Procedure != "" {
		return "EXEC " + mssqlread.QuoteProc(c.Procedure) + ";"
	}
	if c.Database != "" {
		return "USE " + mssqlread.QuoteName(c.Database) + ";\n" + c.SQL
	}
	return c.SQL
}

// customRun is the batch that holds a check: its own transaction, rolled back.
const customRun = `SET XACT_ABORT ON;
BEGIN TRANSACTION;
EXEC sys.sp_executesql @pgvigil_check;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;`

// customResult is one run of one check (the PostgreSQL collection's result row).
type customResult struct {
	Status   string // ok | warning | critical | error
	Value    *float64
	RowCount int
	Columns  []string
	Cells    [][]any
	Kept     bool
	Note     string
	Err      string
	Took     time.Duration
}

func (r customResult) row(name string) collect.Row {
	out := collect.Row{
		"kind": "result", "check_name": name, "status": r.Status, "row_count": r.RowCount,
		"columns": r.Columns, "rows_kept": r.Kept, "note": nilIfEmpty(r.Note), "error": nilIfEmpty(r.Err),
		"duration_ms": r.Took.Milliseconds(),
	}
	if r.Value != nil {
		out["value"] = *r.Value
	}
	if r.Kept {
		out["rows"] = r.Cells
	}
	return out
}

// runCustomCheck runs one check on a connection of its own.
func runCustomCheck(ctx context.Context, in config.Instance, info Info, c collect.CustomCheck) (res customResult) {
	start := time.Now()
	defer func() { res.Took = time.Since(start) }()
	cctx, cancel := context.WithTimeout(ctx, customCheckTimeout)
	defer cancel()
	fail := func(err error) customResult {
		// the check's own deadline, whatever error the driver made of its cancel
		if errors.Is(cctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil {
			err = context.DeadlineExceeded
		}
		return customResult{Status: "error", Err: collect.CapCustomText(collect.MaskCustomText(customErrText(err, c)), collect.CustomMaxError)}
	}
	db, conn, err := Connect(cctx, in)
	if err != nil {
		return fail(err)
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	azureDB := info.EngineEdition == 5
	var login0 string
	if err := conn.QueryRowContext(cctx, "SELECT SUSER_SNAME()").Scan(&login0); err != nil {
		return fail(err)
	}
	before, traced, err := readTraces(cctx, conn, azureDB)
	if err != nil {
		return fail(err)
	}
	keep := in.QueryText == "" || in.QueryText == "full"
	res, err = readCheck(cctx, conn, c, keep)
	if err != nil {
		return fail(err)
	}
	if traced {
		// a check that ran EXECUTE AS left its session as another principal (it cannot be reverted from outside): the
		// traces are read again on a connection of the read login's own
		tconn := conn
		var login1 string
		if err := conn.QueryRowContext(cctx, "SELECT CASE WHEN SUSER_SNAME() = ORIGINAL_LOGIN() THEN SUSER_SNAME() ELSE N'' END").Scan(&login1); err != nil || login1 != login0 {
			db2, conn2, err := Connect(cctx, in)
			if err != nil {
				return fail(fmt.Errorf("the traces were not read after the check (its session was left as another principal, and a new connection failed): %w", err))
			}
			defer func() { _ = conn2.Close(); _ = db2.Close() }()
			tconn = conn2
		}
		after, _, err := readTraces(cctx, tconn, azureDB)
		if err != nil {
			return fail(fmt.Errorf("the traces were not read after the check: %w", err))
		}
		if changed := traceChanges(before, after); changed != "" {
			return fail(errors.New("the check " + changed + ": pgvigil leaves it as it is (stopping or closing it is the DBA's hand: sp_trace_setstatus); a custom check never changes a trace"))
		}
	}
	return res
}

// readCheck runs the batch and reads its first result set.
func readCheck(ctx context.Context, conn *sql.Conn, c collect.CustomCheck, keep bool) (customResult, error) {
	rows, err := conn.QueryContext(ctx, customRun, sql.Named("pgvigil_check", customBatch(c)))
	if err != nil {
		return customResult{}, err
	}
	defer func() { _ = rows.Close() }()
	cts, err := rows.ColumnTypes()
	if err != nil {
		return customResult{}, err
	}
	// a batch whose first statements return no rows (a SET, a USE) still has its result set further on
	for len(cts) == 0 && rows.NextResultSet() {
		if cts, err = rows.ColumnTypes(); err != nil {
			return customResult{}, err
		}
	}
	if len(cts) == 0 {
		if err := rows.Err(); err != nil {
			return customResult{}, err
		}
		return customResult{}, errors.New("the check returns no rows: a check is a SELECT, or a procedure that returns a result set")
	}
	cols := make([]string, 0, len(cts))
	for i, ct := range cts {
		if i >= collect.CustomMaxCols {
			break
		}
		cols = append(cols, ct.Name())
	}
	vi := -1
	if c.Rule == "value" {
		if vi = valueColumn(cts, c.Value); vi < 0 {
			return customResult{}, fmt.Errorf("the value column %q is not among the columns the check returns (%s)", c.Value, strings.Join(cols, ", "))
		}
	}
	var cells [][]any
	var value *float64
	n := 0
	vals := make([]any, len(cts))
	ptrs := make([]any, len(cts))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	for rows.Next() {
		if err := rows.Scan(ptrs...); err != nil {
			return customResult{}, err
		}
		if n == 0 && vi >= 0 {
			v, ok, err := mssqlread.Number(vals[vi], cts[vi].DatabaseTypeName())
			if err != nil {
				return customResult{}, fmt.Errorf("the value column %q: %w", cts[vi].Name(), err)
			}
			if ok {
				value = &v
			}
		}
		if keep && n < collect.CustomMaxRows {
			row := make([]any, 0, len(cols))
			for i := range cols {
				row = append(row, customCell(mssqlread.Cell(vals[i], cts[i].DatabaseTypeName())))
			}
			cells = append(cells, row)
		}
		n++
	}
	if err := rows.Err(); err != nil {
		return customResult{}, err
	}
	more := 0
	for rows.NextResultSet() {
		if cts2, err := rows.ColumnTypes(); err == nil && len(cts2) > 0 {
			more++
		}
	}
	if err := rows.Err(); err != nil {
		return customResult{}, err
	}
	res := customResult{RowCount: n, Columns: cols, Kept: keep, Cells: cells}
	if keep && cells == nil {
		res.Cells = [][]any{}
	}
	var notes []string
	switch {
	case !keep:
		notes = append(notes, "rows not kept: query_text is not full")
	case n > collect.CustomMaxRows:
		notes = append(notes, fmt.Sprintf("the first %d of %d rows kept", collect.CustomMaxRows, n))
	}
	if len(cts) > collect.CustomMaxCols {
		notes = append(notes, fmt.Sprintf("the first %d of %d columns kept", collect.CustomMaxCols, len(cts)))
	}
	if more > 0 {
		notes = append(notes, fmt.Sprintf("the first of %d result sets read", more+1))
	}
	if c.Rule == "rows" {
		v := float64(n)
		value = &v
	} else if value == nil {
		if n == 0 {
			notes = append(notes, "no row: nothing to judge")
		} else {
			notes = append(notes, "the value is NULL: nothing to judge")
		}
	}
	res.Note = strings.Join(notes, "; ")
	res.Value = value
	res.Status = collect.JudgeCustom(value, c.Compare, c.Warning, c.Critical)
	return res, nil
}

// valueColumn finds the value column: the named one (as SQL Server compares names, without case), else a column
// named value, else the first; -1 = the named one is absent.
func valueColumn(cts []*sql.ColumnType, name string) int {
	if name != "" {
		for i, ct := range cts {
			if strings.EqualFold(ct.Name(), name) {
				return i
			}
		}
		return -1
	}
	for i, ct := range cts {
		if strings.EqualFold(ct.Name(), "value") {
			return i
		}
	}
	return 0
}

// customCell caps a text cell at collect.CustomMaxCell characters.
func customCell(v any) any {
	if s, ok := v.(string); ok {
		return collect.CapCustomText(s, collect.CustomMaxCell)
	}
	return v
}

// customErrText is a check's error in words: the server's own message, with what the number means for a check.
func customErrText(err error, c collect.CustomCheck) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Sprintf("the check did not finish within %d s (its connection, its rights read and its batch): stopped", int(customCheckTimeout.Seconds()))
	}
	switch mssqlread.ErrorNumber(err) {
	case 266:
		return "the check ended the transaction it ran in (a COMMIT or a ROLLBACK inside it): a custom check is read only, and what it changed after that was not rolled back - " + err.Error()
	case 2812:
		if c.Procedure != "" {
			return fmt.Sprintf("procedure %s does not exist, or the read login may not see it (Msg 2812): create it, and GRANT EXECUTE on it to the read login", c.Procedure)
		}
	case 229:
		if c.Procedure != "" {
			return fmt.Sprintf("the read login may not run procedure %s (Msg 229): GRANT EXECUTE on it to the read login - %s", c.Procedure, err.Error())
		}
	}
	return err.Error()
}

// readTraces is the server's traces (id -> status, path and start), read only where the login holds ALTER TRACE (a
// login without it can make none, and sees none); traced = they were read. An Azure SQL Database has no traces.
func readTraces(ctx context.Context, conn *sql.Conn, azureDB bool) (map[int]string, bool, error) {
	if azureDB {
		return nil, false, nil
	}
	var may sql.NullInt64
	if err := conn.QueryRowContext(ctx, "SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER TRACE')").Scan(&may); err != nil {
		return nil, false, fmt.Errorf("reading the right to see traces: %w", err)
	}
	if !may.Valid || may.Int64 != 1 {
		return nil, false, nil
	}
	rows, err := conn.QueryContext(ctx, "SELECT id, status, ISNULL(path, N''), CONVERT(nvarchar(30), start_time, 126) FROM sys.traces")
	if err != nil {
		return nil, false, fmt.Errorf("reading the traces: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := map[int]string{}
	for rows.Next() {
		var id, status int
		var path string
		var started sql.NullString
		if err := rows.Scan(&id, &status, &path, &started); err != nil {
			return nil, false, fmt.Errorf("reading the traces: %w", err)
		}
		out[id] = fmt.Sprintf("%d\x00%s\x00%s", status, path, started.String)
	}
	return out, true, rows.Err()
}

// traceChanges says which traces a check made, started, stopped or closed ("" = none).
func traceChanges(before, after map[int]string) string {
	var said []string
	path := func(v string) string {
		if p := strings.Split(v, "\x00"); len(p) > 1 && p[1] != "" {
			return " (" + p[1] + ")"
		}
		return ""
	}
	status := func(v string) string { return strings.SplitN(v, "\x00", 2)[0] }
	ids := map[int]bool{}
	for id := range before {
		ids[id] = true
	}
	for id := range after {
		ids[id] = true
	}
	list := make([]int, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}
	sort.Ints(list)
	for _, id := range list {
		b, wasThere := before[id]
		a, isThere := after[id]
		switch {
		case !wasThere && isThere:
			said = append(said, fmt.Sprintf("made trace %d%s", id, path(a)))
		case wasThere && !isThere:
			said = append(said, fmt.Sprintf("closed trace %d%s", id, path(b)))
		case status(a) != status(b) && status(a) == "1":
			said = append(said, fmt.Sprintf("started trace %d%s", id, path(a)))
		case status(a) != status(b):
			said = append(said, fmt.Sprintf("stopped trace %d%s", id, path(a)))
		}
	}
	return strings.Join(said, ", ")
}
