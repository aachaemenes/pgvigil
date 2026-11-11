package alerts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// fakeRow answers one QueryRow with one value (the count alert_rules_run returns, a yes / no, a setting), or with the
// error the repository gave.
type fakeRow struct {
	v   any
	err error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	switch d := dest[0].(type) {
	case *int:
		*d = r.v.(int)
	case *bool:
		*d = r.v.(bool)
	case *string:
		*d = r.v.(string)
	default:
		return fmt.Errorf("fakeRow: no scan into %T", d)
	}
	return nil
}

// fakeRepo is the repository as evalRules talks to it: whether it has alert_rules_run, the session's
// statement_timeout (changed by set_config, as the server would), and what the evaluation answers.
type fakeRepo struct {
	has     bool
	timeout string // the session's statement_timeout now
	run     fakeRow
	calls   []string // each statement's first words, in order
	runArg  any
	during  string // statement_timeout while alert_rules_run ran
}

func (q *fakeRepo) QueryRow(_ context.Context, sql string, args ...any) pgx.Row {
	switch {
	case strings.Contains(sql, "to_regprocedure('pgvigil.alert_rules_run(timestamp with time zone)')"):
		q.calls = append(q.calls, "has")
		return fakeRow{v: q.has}
	case strings.Contains(sql, "current_setting('statement_timeout')"):
		q.calls = append(q.calls, "read")
		return fakeRow{v: q.timeout}
	case strings.Contains(sql, "set_config('statement_timeout', $1, false)"):
		q.calls = append(q.calls, "set "+args[0].(string))
		q.timeout = args[0].(string)
		return fakeRow{v: q.timeout}
	case strings.Contains(sql, "pgvigil.alert_rules_run($1)"):
		q.calls = append(q.calls, "run")
		q.runArg, q.during = args[0], q.timeout
		return q.run
	}
	return fakeRow{err: fmt.Errorf("fakeRepo: an unexpected statement: %s", sql)}
}

func TestEvalRules(t *testing.T) {
	now := time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC)
	ctx := context.Background()

	// three rows firing: asked whether the function is there, the limit set for the call and put back after
	q := &fakeRepo{has: true, timeout: "5min", run: fakeRow{v: 3}}
	n, err := evalRules(ctx, q, now)
	if err != nil || n != 3 {
		t.Fatalf("three rows firing: got %d, %v", n, err)
	}
	if got, want := strings.Join(q.calls, ", "), "has, read, set 30000, run, set 5min"; got != want {
		t.Fatalf("the statements: %s; want %s", got, want)
	}
	if q.runArg != now || q.during != "30000" || q.timeout != "5min" {
		t.Fatalf("the call ran with %v under statement_timeout %q, and left %q; want the pass's time, 30000, 5min", q.runArg, q.during, q.timeout)
	}

	// a repository before 0085: asked, and nothing else is sent (no error here, none in the server's log)
	q = &fakeRepo{has: false, timeout: "0"}
	n, err = evalRules(ctx, q, now)
	if err != nil || n != 0 || strings.Join(q.calls, ", ") != "has" {
		t.Fatalf("no alert_rules_run: got %d, %v after %v; want 0, no error, one statement", n, err, q.calls)
	}

	// a failed evaluation is the pass's to report, and the session's limit still comes back: the server's cut at the
	// limit, a login that may not write the state, an undefined function inside the evaluation (no longer taken for
	// 'a repository before 0085')
	for _, e := range []error{&pgconn.PgError{Code: "57014", Message: "canceling statement due to statement timeout"},
		&pgconn.PgError{Code: "42501", Message: "permission denied for table alert_rule_state"}, &pgconn.PgError{Code: "42883"}} {
		q = &fakeRepo{has: true, timeout: "0", run: fakeRow{v: 9, err: e}}
		n, err = evalRules(ctx, q, now)
		if !errors.Is(err, e) || n != 0 {
			t.Fatalf("a failed evaluation (%v): got %d, %v; want 0 and that error", e, n, err)
		}
		if q.timeout != "0" || q.calls[len(q.calls)-1] != "set 0" {
			t.Fatalf("after a failed evaluation the session's statement_timeout is %q (%v); want it put back to 0", q.timeout, q.calls)
		}
	}
}

func TestResultStringRules(t *testing.T) {
	base := Result{Channels: 2, Sent: 1}
	if got, want := base.String(), "2 channel(s): 1 alert(s) sent, 0 failed, 0 cleared"; got != want {
		t.Fatalf("no rule firing: %q, want %q (the line a pass printed before 0085)", got, want)
	}
	base.RulesFiring = 4
	if got := base.String(); !strings.HasSuffix(got, "; 4 alert rule row(s) firing") {
		t.Fatalf("four rows firing: %q", got)
	}
	base.RulesFiring, base.RulesErr = 0, errors.New("ERROR: canceling statement\n  due to statement timeout")
	if got := base.String(); !strings.HasSuffix(got, "; alert rules not judged: ERROR: canceling statement due to statement timeout") {
		t.Fatalf("a failed evaluation, on one line: %q", got)
	}
	if len(base.Errors) != 0 {
		t.Fatalf("Errors is the channels' list: %v", base.Errors)
	}
}

func TestRulePayload(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	n := func(v int) *int { return &v }
	inst := func(id int) string {
		if id == 7 {
			return "erp01"
		}
		return ""
	}
	full := RuleRequest{Metric: "sessions.idle_in_txn", Dir: "above", Warning: f(3), Critical: f(5), ForMinutes: n(10),
		Scope: "tag", Tag: " Env : prod ", Database: " app ", Name: " idle ", Note: ""}
	pay, err := RulePayload(full, "", inst)
	if err != nil {
		t.Fatalf("a whole add: %v", err)
	}
	want := map[string]any{"op": "add", "metric": "sessions.idle_in_txn", "op_dir": "above", "warning": 3.0, "critical": 5.0,
		"for_minutes": 10, "scope": "tag", "tag": "env:prod", "database": "app", "name": "idle"}
	if len(pay) != len(want) {
		t.Fatalf("the payload: %v, want %v", pay, want)
	}
	for k, v := range want {
		if pay[k] != v {
			t.Fatalf("payload[%s] = %v (%T), want %v (%T)", k, pay[k], pay[k], v, v)
		}
	}

	// an instance rule carries the instance's name; an edit, a switch and an end carry the rule's id
	pay, err = RulePayload(RuleRequest{Op: "edit", RuleID: 4, Metric: "host.cpu_pct", Dir: "below", Critical: f(1), Scope: "instance", InstanceID: 7}, "", inst)
	if err != nil || pay["instance_name"] != "erp01" || pay["rule_id"] != int64(4) || pay["op"] != "edit" || pay["tag"] != nil {
		t.Fatalf("an instance edit: %v, %v", pay, err)
	}
	if _, ok := pay["for_minutes"]; ok {
		t.Fatalf("no for_minutes in the request: the store's default applies, got %v", pay["for_minutes"])
	}
	pay, err = RulePayload(RuleRequest{Op: "disable", RuleID: 4, Metric: "ignored"}, "", inst)
	if err != nil || len(pay) != 2 || pay["op"] != "disable" {
		t.Fatalf("a switch carries op and rule_id alone: %v, %v", pay, err)
	}
	// the end route forces its op whatever the body says
	pay, err = RulePayload(RuleRequest{Op: "add", RuleID: 9}, "end", inst)
	if err != nil || len(pay) != 2 || pay["op"] != "end" || pay["rule_id"] != int64(9) {
		t.Fatalf("the end route: %v, %v", pay, err)
	}

	bad := map[string]RuleRequest{
		"op must be":               {Op: "end", RuleID: 1},
		"rule_id must be":          {Op: "edit", Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "fleet"},
		"metric must be":           {Dir: "above", Warning: f(1), Scope: "fleet"},
		"op_dir must be":           {Metric: "host.cpu_pct", Dir: "over", Warning: f(1), Scope: "fleet"},
		"a warning or a critical":  {Metric: "host.cpu_pct", Dir: "above", Scope: "fleet"},
		"critical >= warning":      {Metric: "host.cpu_pct", Dir: "above", Warning: f(9), Critical: f(5), Scope: "fleet"},
		"critical <= warning":      {Metric: "host.cpu_pct", Dir: "below", Warning: f(5), Critical: f(9), Scope: "fleet"},
		"for_minutes must be":      {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), ForMinutes: n(1441), Scope: "fleet"},
		"scope must be":            {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "all"},
		"has no value":             {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "tag", Tag: "  "},
		"names its instance_id":    {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "instance"},
		"no active instance 8":     {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "instance", InstanceID: 8},
		"name must be at most":     {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "fleet", Name: strings.Repeat("n", 101)},
		"note must be at most":     {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "fleet", Note: strings.Repeat("n", 501)},
		"database must be at most": {Metric: "database.commits_s", Dir: "above", Warning: f(1), Scope: "fleet", Database: strings.Repeat("d", 201)},
	}
	for wantErr, in := range bad {
		pay, err := RulePayload(in, "", inst)
		if err == nil || !strings.Contains(err.Error(), wantErr) || pay != nil {
			t.Errorf("%+v: got %v, %v; want an error holding %q and no payload", in, pay, err, wantErr)
		}
	}
	if _, err := RulePayload(RuleRequest{}, "end", inst); err == nil {
		t.Error("the end route without a rule_id: want an error")
	}
	// an instance id past the column's int4 is a request's fault, not a repository error
	if _, err := RulePayload(RuleRequest{Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "instance", InstanceID: 1 << 31}, "", inst); err == nil || !strings.Contains(err.Error(), "names its instance_id") {
		t.Errorf("an instance id of 2^31: %v", err)
	}
	// the limits count characters, as the store's length() does: 100 two-byte letters are a name
	if _, err := RulePayload(RuleRequest{Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "fleet", Name: strings.Repeat("é", 100)}, "", inst); err != nil {
		t.Errorf("a name of 100 characters: %v", err)
	}
	// equal warning and critical is a rule (one level at one value); for 0 minutes fires at the first sample
	if _, err := RulePayload(RuleRequest{Metric: "host.cpu_pct", Dir: "above", Warning: f(5), Critical: f(5), ForMinutes: n(0), Scope: "fleet"}, "", inst); err != nil {
		t.Errorf("warning = critical, for 0 minutes: %v", err)
	}
}
