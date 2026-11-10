package actions

// EXPLAIN ANALYZE through the actions door (task 40). EXPLAIN ANALYZE executes the statement, so it is an action,
// not a read: it runs through the actions login only, never the monitoring login; only a SELECT (a WITH query,
// VALUES, TABLE) is taken, and it runs in a READ ONLY transaction that is rolled back, so a write anywhere in it (a
// data-modifying CTE, a function that writes) fails instead of happening; under a statement timeout; and every
// attempt, refused, failed or done, is a row of pgvigil.actions_log with the statement and the database. The door
// is off per instance until the config turns it on (ExplainGate.Enabled): EXPLAIN ANALYZE on a production server
// is a decision, not a default.
//
// The actions login needs the privileges the statement needs (SELECT on its tables, or pg_read_all_data on 14+);
// that grant is the client DBA's opt-in beside pg_signal_backend, and the refusal says so.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/plans"
)

// ExplainAnalyzeKind is the audit's action name.
const ExplainAnalyzeKind Kind = "explain_analyze"

// Explain timeouts: the default and the most a config may set.
const (
	DefaultExplainTimeout = 30 * time.Second
	MaxExplainTimeout     = 5 * time.Minute
)

// ExplainGate is one instance's EXPLAIN ANALYZE switch: off unless the config turns it on, with the timeout the
// statement runs under (0 = DefaultExplainTimeout).
type ExplainGate struct {
	Enabled bool
	Timeout time.Duration
}

// TimeoutOrDefault is the gate's timeout within its bounds.
func (g ExplainGate) TimeoutOrDefault() time.Duration {
	switch {
	case g.Timeout <= 0:
		return DefaultExplainTimeout
	case g.Timeout > MaxExplainTimeout:
		return MaxExplainTimeout
	}
	return g.Timeout
}

// ExplainRequest is one EXPLAIN ANALYZE attempt as the UI sent it.
type ExplainRequest struct {
	InstanceID int
	Instance   string
	Datname    string
	Statement  string
	Reason     string
	User       string
	Client     string
}

// ValidateExplain checks the request's own shape: the reason, the user, and the statement (one SELECT, no $n
// parameter: EXPLAIN ANALYZE needs the values).
func ValidateExplain(r ExplainRequest) error {
	st := strings.TrimSpace(r.Statement)
	switch {
	case st == "":
		return errors.New("no statement")
	case len(st) > plans.MaxStatement:
		return fmt.Errorf("the statement is longer than %d characters", plans.MaxStatement)
	case strings.ContainsRune(st, 0) || strings.ContainsRune(r.Datname, 0):
		return errors.New("the request holds a NUL character")
	case len([]rune(strings.TrimSpace(r.Reason))) < MinReason:
		return fmt.Errorf("a reason of at least %d characters is required", MinReason)
	case len([]rune(r.Reason)) > MaxReason:
		return fmt.Errorf("the reason is longer than %d characters", MaxReason)
	case strings.ContainsRune(r.Reason, 0):
		return errors.New("the reason holds a NUL character")
	case strings.TrimSpace(r.User) == "":
		return errors.New("no UI user: actions need the UI login")
	}
	sc := plans.ScanSQL(strings.TrimSuffix(st, ";"))
	if ok, why := sc.ReadOnlyKind(); !ok {
		return errors.New(why)
	}
	if sc.MaxParam > 0 {
		return fmt.Errorf("the statement has $n parameters ($%d): EXPLAIN ANALYZE runs it, so it needs the values; the plain EXPLAIN plans it in the generic form without running it", sc.MaxParam)
	}
	return nil
}

// ExplainAnalyze runs the checks and, when they pass, EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) of the statement
// through the actions login, in a read-only transaction rolled back at the end. It never returns an error: every
// way out is a Result the caller writes to the audit table; a done attempt carries the plan row (source
// explain_analyze) for import_plans.
func ExplainAnalyze(ctx context.Context, d Door, g ExplainGate, r ExplainRequest) (Result, *plans.Row) {
	if err := ValidateExplain(r); err != nil {
		return refused("%s", err.Error()), nil
	}
	if !g.Enabled {
		return refused("EXPLAIN ANALYZE is off on instance %s: it executes the statement, so it is turned on per instance in the config (explain_analyze), off by default", r.Instance), nil
	}
	if off := d.Off(r.Instance); off != "" {
		return refused("%s", off), nil
	}
	if d.Monitor == "" {
		return refused("instance %s: the monitoring dsn resolved to an empty string", r.Instance), nil
	}
	timeout := g.TimeoutOrDefault()
	ctx, cancel := context.WithTimeout(ctx, timeout+30*time.Second)
	defer cancel()
	stmt := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(r.Statement), ";"))

	// the two logins must reach one server (the monitoring login is the instance the user looked at)
	mon, err := plans.Connect(ctx, d.Monitor, "", "pgvigil-actions-check", 5*time.Second)
	if err != nil {
		return refused("the monitoring login could not connect to check the server: %v", err), nil
	}
	defer func() { _ = mon.Close(context.WithoutCancel(ctx)) }()
	act, err := plans.Connect(ctx, d.Actions, r.Datname, "pgvigil-actions-explain", timeout)
	if err != nil {
		return Result{Outcome: Failed, Detail: fmt.Sprintf("the actions login could not connect to %s: %v", dbName(r.Datname), err)}, nil
	}
	defer func() { _ = act.Close(context.WithoutCancel(ctx)) }()
	var monStart, actStart time.Time
	if err := mon.QueryRow(ctx, `SELECT pg_postmaster_start_time()`).Scan(&monStart); err != nil {
		return refused("the server check failed: %v", err), nil
	}
	var actSuper bool
	if err := act.QueryRow(ctx, `SELECT pg_postmaster_start_time(), (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)`).Scan(&actStart, &actSuper); err != nil {
		return Result{Outcome: Failed, Detail: fmt.Sprintf("the actions login's server check failed: %v", err)}, nil
	}
	if !monStart.Equal(actStart) {
		return refused("actions_dsn reaches another server than the instance's dsn (server started %s vs %s): nothing was run",
			actStart.UTC().Format(time.RFC3339), monStart.UTC().Format(time.RFC3339)), nil
	}
	if actSuper {
		return refused("the actions login is a superuser: pgvigil refuses it (create pgvigil_actions without SUPERUSER; pgvigil roles prints it)"), nil
	}

	tx, err := act.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return Result{Outcome: Failed, Detail: fmt.Sprintf("BEGIN READ ONLY failed: %v", err)}, nil
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	mode := pgx.QueryExecModeExec // the extended protocol: one statement only
	if _, err := tx.Exec(ctx, fmt.Sprintf(`SET LOCAL statement_timeout = %d`, timeout.Milliseconds()), mode); err != nil {
		return Result{Outcome: Failed, Detail: fmt.Sprintf("statement_timeout: %v", err)}, nil
	}
	start := time.Now()
	var planJSON string
	err = tx.QueryRow(ctx, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) `+stmt, mode).Scan(&planJSON)
	took := time.Since(start)
	if err != nil {
		return Result{Outcome: Failed, Detail: explainFailure(err, timeout)}, nil
	}
	row := plans.Build(plans.ExplainAnalyze, time.Now(), "", r.Datname, stmt, planJSON)
	ms := float64(took.Microseconds()) / 1000
	row.DurationMS = &ms
	return Result{Outcome: Done, Detail: fmt.Sprintf("EXPLAIN ANALYZE ran in %s (read-only transaction, rolled back; timeout %s)", took.Round(time.Millisecond), timeout)}, &row
}

func dbName(datname string) string {
	if datname == "" {
		return "the dsn's database"
	}
	return "database " + datname
}

func explainFailure(err error, timeout time.Duration) string {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "25006":
			return "the statement tried to write (" + pg.Message + "): it ran in a read-only transaction, so nothing was written"
		case "57014":
			return fmt.Sprintf("the statement ran longer than the timeout %s and was cancelled", timeout)
		case "42501":
			return pg.Message + ": the actions login needs the statement's privileges (SELECT on its tables, or pg_read_all_data on 14+), the client DBA's opt-in"
		}
		return fmt.Sprintf("%s (SQLSTATE %s)", pg.Message, pg.Code)
	}
	return err.Error()
}

// ExplainLogRow is the audit row of an EXPLAIN ANALYZE attempt: the common row with the database and the
// statement (0029's columns); its pid is 0 and stored NULL.
type ExplainLogRow struct {
	LogRow
	Datname   string `json:"datname"`
	Statement string `json:"statement"`
}

// ExplainRow builds the audit row of an attempt.
func ExplainRow(at time.Time, r ExplainRequest, res Result) ExplainLogRow {
	base := Row(at, Request{Instance: r.Instance, Kind: ExplainAnalyzeKind, Reason: r.Reason, User: r.User, Client: r.Client}, res)
	st := strings.ReplaceAll(strings.TrimSpace(r.Statement), "\x00", "")
	if rs := []rune(st); len(rs) > plans.MaxStatement {
		st = string(rs[:plans.MaxStatement])
	}
	return ExplainLogRow{LogRow: base, Datname: strings.ReplaceAll(r.Datname, "\x00", ""), Statement: st}
}
