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

// fakeRow answers one QueryRow: the count alert_rules_run returns, or the error the repository gave.
type fakeRow struct {
	n   int
	err error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	*(dest[0].(*int)) = r.n
	return nil
}

type fakeQuerier struct {
	row  fakeRow
	sql  string
	args []any
}

func (q *fakeQuerier) QueryRow(_ context.Context, sql string, args ...any) pgx.Row {
	q.sql, q.args = sql, args
	return q.row
}

func TestEvalRules(t *testing.T) {
	now := time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC)
	ctx := context.Background()

	q := &fakeQuerier{row: fakeRow{n: 3}}
	n, err := evalRules(ctx, q, now)
	if err != nil || n != 3 {
		t.Fatalf("three rows firing: got %d, %v", n, err)
	}
	if !strings.Contains(q.sql, "pgvigil.alert_rules_run($1)") || len(q.args) != 1 || q.args[0] != now {
		t.Fatalf("the call: %q with %v, want pgvigil.alert_rules_run($1) with the pass's time", q.sql, q.args)
	}

	// a repository before 0085 has no alert_rules_run: no rules, no error (bare and wrapped)
	for _, e := range []error{&pgconn.PgError{Code: "42883"}, fmt.Errorf("query: %w", &pgconn.PgError{Code: "42883"})} {
		n, err = evalRules(ctx, &fakeQuerier{row: fakeRow{err: e}}, now)
		if err != nil || n != 0 {
			t.Fatalf("undefined function (%v): got %d, %v, want 0 and no error", e, n, err)
		}
	}

	// any other failure is the pass's to report: a login that may not write the state, a lost connection
	for _, e := range []error{&pgconn.PgError{Code: "42501", Message: "permission denied for table alert_rule_state"}, errors.New("conn closed")} {
		n, err = evalRules(ctx, &fakeQuerier{row: fakeRow{n: 9, err: e}}, now)
		if err == nil || n != 0 {
			t.Fatalf("a failed evaluation (%v): got %d, %v, want 0 and the error", e, n, err)
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
	base.RulesFiring, base.RulesErr = 0, errors.New("x")
	if got := base.String(); !strings.HasSuffix(got, "; alert rules not judged") {
		t.Fatalf("a failed evaluation: %q", got)
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
		"op must be":              {Op: "end", RuleID: 1},
		"rule_id must be":         {Op: "edit", Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "fleet"},
		"metric must be":          {Dir: "above", Warning: f(1), Scope: "fleet"},
		"op_dir must be":          {Metric: "host.cpu_pct", Dir: "over", Warning: f(1), Scope: "fleet"},
		"a warning or a critical": {Metric: "host.cpu_pct", Dir: "above", Scope: "fleet"},
		"critical >= warning":     {Metric: "host.cpu_pct", Dir: "above", Warning: f(9), Critical: f(5), Scope: "fleet"},
		"critical <= warning":     {Metric: "host.cpu_pct", Dir: "below", Warning: f(5), Critical: f(9), Scope: "fleet"},
		"for_minutes must be":     {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), ForMinutes: n(1441), Scope: "fleet"},
		"scope must be":           {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "all"},
		"has no value":            {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "tag", Tag: "  "},
		"names its instance_id":   {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "instance"},
		"no active instance 8":    {Metric: "host.cpu_pct", Dir: "above", Warning: f(1), Scope: "instance", InstanceID: 8},
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
	// equal warning and critical is a rule (one level at one value); for 0 minutes fires at the first sample
	if _, err := RulePayload(RuleRequest{Metric: "host.cpu_pct", Dir: "above", Warning: f(5), Critical: f(5), ForMinutes: n(0), Scope: "fleet"}, "", inst); err != nil {
		t.Errorf("warning = critical, for 0 minutes: %v", err)
	}
}
