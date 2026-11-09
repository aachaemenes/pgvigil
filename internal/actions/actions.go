// Package actions is pgvigil's one write door to a monitored server: cancel the statement of a
// session (pg_cancel_backend) or end the session (pg_terminate_backend), on one pid, on a user's
// typed reason, every attempt written to the repository's audit table pgvigil.actions_log.
//
// Two logins take part, each with the least it needs:
//   - the instance's monitoring login (pg_monitor) reads the target from pg_stat_activity: its
//     backend_start, its role and its backend type. The actions login cannot read those columns of
//     another role's session (pg_signal_backend alone sees "<insufficient privilege>"), so the check
//     runs here;
//   - the actions login (pgvigil_actions, GRANT pg_signal_backend, never a superuser, configured per
//     instance as actions_dsn) sends the signal and does nothing else.
//
// The target must be the row the user saw: a pid whose backend_start differs from the one shown is
// another backend that reused the pid and is refused with the reason. The check and the signal are
// two statements on two connections, a few milliseconds apart; a pid reused inside that window would
// be missed, which is the residue of keeping the actions login at pg_signal_backend alone.
package actions

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/jackc/pgx/v5"
)

// Kind is the action: cancel the running statement, or terminate the session.
type Kind string

// The two actions.
const (
	Cancel    Kind = "cancel"
	Terminate Kind = "terminate"
)

// Outcome is what an attempt came to.
type Outcome string

// The three outcomes of an attempt.
const (
	Done    Outcome = "done"    // the signal was sent
	Refused Outcome = "refused" // a check said no; nothing was sent
	Failed  Outcome = "failed"  // the check passed but the signal could not be sent
)

// Reason limits: a reason is typed by a person and kept in the audit table.
const (
	MinReason = 5
	MaxReason = 500
)

// Door is the pair of connection strings an action uses on one monitored server (resolved).
type Door struct {
	Monitor string // the instance's monitoring login (dsn)
	Actions string // the actions login (actions_dsn); "" = no actions on this instance
	// Configured says actions_dsn is set in the config, so an empty Actions means it did not resolve
	// (an unset variable or an unreadable file), not that the instance has none.
	Configured bool
}

// Off is the reason a door cannot act, or "" when it can.
func (d Door) Off(instance string) string {
	switch {
	case d.Actions != "":
		return ""
	case d.Configured:
		return fmt.Sprintf("instance %s: actions_dsn is configured but resolved to an empty string (an unset variable or an unreadable file)", instance)
	}
	return fmt.Sprintf("instance %s has no actions_dsn: cancel and terminate are off there (pgvigil roles prints the login to create)", instance)
}

// DoorsFromConfig maps every configured instance name to its door.
func DoorsFromConfig(cfg *config.Config) map[string]Door {
	m := map[string]Door{}
	for _, in := range cfg.Instances {
		m[in.Name] = Door{Monitor: in.DSN(), Actions: in.ActionsDSN(), Configured: strings.TrimSpace(in.ActionsDSNRaw) != ""}
	}
	return m
}

// Request is one attempt as the UI sent it.
type Request struct {
	InstanceID   int
	Instance     string
	Kind         Kind
	PID          int
	BackendStart time.Time // of the row the user saw
	Reason       string
	User         string // the UI login
	Client       string // the client address
}

// Result is the outcome with its reason, and what the check learnt about the target.
type Result struct {
	Outcome    Outcome `json:"outcome"`
	Detail     string  `json:"detail"`
	TargetUser string  `json:"target_user,omitempty"`
	TargetApp  string  `json:"target_app,omitempty"`
}

// Validate checks the request's own shape (no connection needed).
func Validate(r Request) error {
	switch {
	case r.Kind != Cancel && r.Kind != Terminate:
		return fmt.Errorf("unknown action %q", r.Kind)
	case r.PID <= 0:
		return errors.New("pid must be a positive number")
	case r.BackendStart.IsZero():
		return errors.New("backend_start of the row shown is required")
	case len([]rune(strings.TrimSpace(r.Reason))) < MinReason:
		return fmt.Errorf("a reason of at least %d characters is required", MinReason)
	case len([]rune(r.Reason)) > MaxReason:
		return fmt.Errorf("the reason is longer than %d characters", MaxReason)
	case strings.ContainsRune(r.Reason, 0):
		return errors.New("the reason holds a NUL character")
	case strings.TrimSpace(r.User) == "":
		return errors.New("no UI user: actions need the UI login")
	}
	return nil
}

func refused(format string, a ...any) Result {
	return Result{Outcome: Refused, Detail: fmt.Sprintf(format, a...)}
}

// connect opens a short-lived connection that cannot hang on a busy server.
func connect(ctx context.Context, dsn, app string) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	if cfg.ConnectTimeout == 0 || cfg.ConnectTimeout > 10*time.Second {
		cfg.ConnectTimeout = 10 * time.Second
	}
	rp := cfg.RuntimeParams
	rp["application_name"] = app
	rp["statement_timeout"] = "5000"
	rp["lock_timeout"] = "1000"
	rp["default_transaction_read_only"] = "on" // pg_cancel_backend / pg_terminate_backend run in a read-only transaction
	return pgx.ConnectConfig(ctx, cfg)
}

// Execute runs the checks and, when they pass, sends the signal. It never returns an error: every
// way out is a Result the caller writes to the audit table.
func Execute(ctx context.Context, d Door, r Request) Result {
	if err := Validate(r); err != nil {
		return refused("%s", err.Error())
	}
	if off := d.Off(r.Instance); off != "" {
		return refused("%s", off)
	}
	if d.Monitor == "" {
		return refused("instance %s: the monitoring dsn resolved to an empty string", r.Instance)
	}

	// 1. the target as the monitoring login sees it
	mon, err := connect(ctx, d.Monitor, "pgvigil-actions-check")
	if err != nil {
		return refused("the monitoring login could not connect to check the target: %v", err)
	}
	defer func() { _ = mon.Close(ctx) }()
	var (
		bs              *time.Time
		usename, app    *string
		btype           *string
		super, canWatch bool
	)
	if err := mon.QueryRow(ctx, `SELECT pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')`).Scan(&canWatch); err != nil {
		return refused("the target check failed: %v", err)
	}
	if !canWatch {
		return refused("the monitoring login cannot read every session (it needs pg_monitor or pg_read_all_stats): the target cannot be checked")
	}
	err = mon.QueryRow(ctx, `
SELECT a.backend_start, a.usename, a.application_name, a.backend_type, coalesce(r.rolsuper, false)
  FROM pg_stat_activity a LEFT JOIN pg_roles r ON r.oid = a.usesysid
 WHERE a.pid = $1`, r.PID).Scan(&bs, &usename, &app, &btype, &super)
	if errors.Is(err, pgx.ErrNoRows) {
		return refused("pid %d is not running any more: nothing to %s", r.PID, r.Kind)
	}
	if err != nil {
		return refused("the target check failed: %v", err)
	}
	res := Result{TargetUser: deref(usename), TargetApp: deref(app)}
	switch {
	case bs == nil || !bs.Equal(r.BackendStart):
		res.Outcome, res.Detail = Refused, fmt.Sprintf("pid %d now belongs to another backend (started %s; the row shown started %s): the session shown has ended and the pid was reused",
			r.PID, fmtTS(bs), r.BackendStart.UTC().Format(time.RFC3339Nano))
		return res
	case super:
		res.Outcome, res.Detail = Refused, fmt.Sprintf("pid %d belongs to the superuser %s: the actions login holds pg_signal_backend only and a superuser's backend stays out of its reach", r.PID, res.TargetUser)
		return res
	case deref(btype) != "client backend":
		res.Outcome, res.Detail = Refused, fmt.Sprintf("pid %d is a %s, not a client backend: only a client session is cancelled or terminated from the UI", r.PID, orNone(btype))
		return res
	}

	// 2. the signal, through the actions login
	act, err := connect(ctx, d.Actions, "pgvigil-actions")
	if err != nil {
		res.Outcome, res.Detail = Failed, fmt.Sprintf("the actions login could not connect: %v", err)
		return res
	}
	defer func() { _ = act.Close(ctx) }()
	// the two logins must reach one server: a copy-pasted actions_dsn naming another host would signal an
	// unrelated session there. pg_postmaster_start_time() is readable by any login.
	var monStart, actStart time.Time
	if err := mon.QueryRow(ctx, `SELECT pg_postmaster_start_time()`).Scan(&monStart); err != nil {
		res.Outcome, res.Detail = Refused, fmt.Sprintf("the server check failed: %v", err)
		return res
	}
	if err := act.QueryRow(ctx, `SELECT pg_postmaster_start_time()`).Scan(&actStart); err != nil {
		res.Outcome, res.Detail = Failed, fmt.Sprintf("the actions login's server check failed: %v", err)
		return res
	}
	if !monStart.Equal(actStart) {
		res.Outcome, res.Detail = Refused, fmt.Sprintf("actions_dsn reaches another server than the instance's dsn (server started %s vs %s): nothing was sent",
			actStart.UTC().Format(time.RFC3339), monStart.UTC().Format(time.RFC3339))
		return res
	}
	var actSuper, signal bool
	if err := act.QueryRow(ctx, `SELECT r.rolsuper, pg_has_role(current_user, 'pg_signal_backend', 'USAGE')
	                               FROM pg_roles r WHERE r.rolname = current_user`).Scan(&actSuper, &signal); err != nil {
		res.Outcome, res.Detail = Failed, fmt.Sprintf("the actions login's role check failed: %v", err)
		return res
	}
	if actSuper {
		res.Outcome, res.Detail = Refused, "the actions login is a superuser: pgvigil refuses it (create pgvigil_actions with pg_signal_backend only; pgvigil roles prints it)"
		return res
	}
	if !signal {
		res.Outcome, res.Detail = Refused, "the actions login does not hold pg_signal_backend (GRANT pg_signal_backend TO pgvigil_actions)"
		return res
	}
	fn := "pg_cancel_backend"
	if r.Kind == Terminate {
		fn = "pg_terminate_backend"
	}
	var ok bool
	if err := act.QueryRow(ctx, `SELECT `+fn+`($1)`, r.PID).Scan(&ok); err != nil {
		res.Outcome, res.Detail = Failed, fmt.Sprintf("%s(%d) failed: %v", fn, r.PID, err)
		return res
	}
	if !ok {
		res.Outcome, res.Detail = Failed, fmt.Sprintf("%s(%d) returned false: the backend had already exited", fn, r.PID)
		return res
	}
	res.Outcome, res.Detail = Done, fmt.Sprintf("%s(%d) sent", fn, r.PID)
	return res
}

// LogRow is one audit row as import_actions_log reads it.
type LogRow struct {
	At           time.Time `json:"at"`
	Instance     string    `json:"instance_name"`
	UIUser       string    `json:"ui_user"`
	Client       string    `json:"client"`
	Action       Kind      `json:"action"`
	PID          int       `json:"pid"`
	BackendStart *string   `json:"backend_start"`
	TargetUser   string    `json:"target_user"`
	TargetApp    string    `json:"target_app"`
	Reason       string    `json:"reason"`
	Outcome      Outcome   `json:"outcome"`
	Detail       string    `json:"detail"`
}

// Row builds the audit row of an attempt.
func Row(at time.Time, r Request, res Result) LogRow {
	var bs *string
	if !r.BackendStart.IsZero() {
		v := r.BackendStart.UTC().Format(time.RFC3339Nano)
		bs = &v
	}
	reason := strings.TrimSpace(r.Reason)
	if reason == "" {
		reason = "(no reason given)"
	}
	if rs := []rune(reason); len(rs) > MaxReason {
		reason = string(rs[:MaxReason])
	}
	nul := func(s string) string { return strings.ReplaceAll(s, "\x00", "") } // jsonb refuses \u0000: the row must land
	return LogRow{At: at, Instance: r.Instance, UIUser: nul(r.User), Client: nul(r.Client), Action: r.Kind, PID: r.PID, BackendStart: bs,
		TargetUser: nul(res.TargetUser), TargetApp: nul(res.TargetApp), Reason: nul(reason), Outcome: res.Outcome, Detail: nul(res.Detail)}
}

// Payload is the jsonb argument of pgvigil.import_actions_log.
func Payload(rows ...LogRow) ([]byte, error) { return json.Marshal(rows) }

// ImportSQL is the audit write; $1 instance_id, $2 the attempt's time, $3 the payload.
const ImportSQL = `SELECT pgvigil.import_actions_log($1, $2, $3::jsonb)`

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func orNone(p *string) string {
	if p == nil || *p == "" {
		return "backend of unknown type"
	}
	return *p
}

func fmtTS(t *time.Time) string {
	if t == nil {
		return "unknown"
	}
	return t.UTC().Format(time.RFC3339Nano)
}
