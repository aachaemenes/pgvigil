// Package cq is the request queue's worker (task CQ, migration 0200): in `pgvigil run` with cq.enabled it holds a lease
// on the repository's clock for the instances it collects, claims the requests serve wrote for them (NOTIFY
// pgvigil_request, and a 5 s poll that also reads cancels), runs each with the logins this collector already holds and
// writes the end and the audit rows in one transaction. The kinds are 0200's action_kinds; a kind runs here only when a
// part of the build registered its Runner (Register, from the part's own file); an unregistered kind publishes no door,
// so the insert answers 'not through the queue yet'.
package cq

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// Kind mirrors one row of 0200's action_kinds (the store's copy is the one the insert checks).
type Kind struct {
	Name      string
	Engine    string // postgres, sqlserver or any
	Class     string // action, read or collect
	Urgent    bool   // the worker's reserved slot
	DoorField string // the payload field a door names (a tool, a job), or ""
}

// Kinds is every kind of 0200, by name.
var Kinds = map[string]Kind{
	"pg_cancel":        {"pg_cancel", "postgres", "action", true, ""},
	"pg_terminate":     {"pg_terminate", "postgres", "action", true, ""},
	"pg_job_stop":      {"pg_job_stop", "postgres", "action", true, "job_name"},
	"pg_job_start":     {"pg_job_start", "postgres", "action", false, "job_name"},
	"mssql_preview":    {"mssql_preview", "sqlserver", "read", false, ""},
	"mssql_kill":       {"mssql_kill", "sqlserver", "action", true, ""},
	"mssql_job_start":  {"mssql_job_start", "sqlserver", "action", false, "job_name"},
	"mssql_job_stop":   {"mssql_job_stop", "sqlserver", "action", true, "job_name"},
	"mssql_plan_evict": {"mssql_plan_evict", "sqlserver", "action", false, ""},
	"community_run":    {"community_run", "any", "read", false, "tool"},
	"community_help":   {"community_help", "any", "read", false, "tool"},
	"custom_report":    {"custom_report", "any", "read", false, ""},
	"explain":          {"explain", "postgres", "read", false, ""},
	"explain_analyze":  {"explain_analyze", "postgres", "read", false, ""},
	"hypo_index":       {"hypo_index", "postgres", "read", false, ""},
	"index_advisor":    {"index_advisor", "postgres", "read", false, ""},
	"admin_test":       {"admin_test", "any", "read", false, ""},
	"collect_now":      {"collect_now", "any", "collect", false, ""},
}

// The payloads, one type per kind: the direct handlers' own request bodies (internal/web at 56b7467) less what serve
// checks before the insert (the typed confirm, the session user, the instance id: the request names the instance).
type (
	// PGSignal is the payload of pg_cancel and pg_terminate.
	PGSignal struct {
		PID          int    `json:"pid"`
		BackendStart string `json:"backend_start"`
		Reason       string `json:"reason"`
	}
	// PGJob is the payload of pg_job_start and pg_job_stop.
	PGJob struct {
		Scheduler string `json:"scheduler"`
		JobID     int64  `json:"job_id"`
		JobName   string `json:"job_name"`
		RunID     int64  `json:"run_id,omitempty"`
		JobPID    int    `json:"job_pid,omitempty"`
		Reason    string `json:"reason"`
	}
	// MSPreview is the payload of mssql_preview.
	MSPreview struct {
		Action     string `json:"action"`
		SessionID  int    `json:"session_id,omitempty"`
		JobID      string `json:"job_id,omitempty"`
		PlanHandle string `json:"plan_handle,omitempty"`
	}
	// MSKill is the payload of mssql_kill.
	MSKill struct {
		SessionID int    `json:"session_id"`
		LoginTime string `json:"login_time"`
		Login     string `json:"login"`
		Reason    string `json:"reason"`
	}
	// MSJob is the payload of mssql_job_start and mssql_job_stop.
	MSJob struct {
		JobID   string `json:"job_id"`
		JobName string `json:"job_name"`
		Reason  string `json:"reason"`
	}
	// MSPlanEvict is the payload of mssql_plan_evict.
	MSPlanEvict struct {
		PlanHandle string `json:"plan_handle"`
		Confirm    string `json:"confirm"`
		Reason     string `json:"reason"`
	}
	// CommunityRun is the payload of community_run.
	CommunityRun struct {
		Tool        string            `json:"tool"`
		Database    string            `json:"database,omitempty"`
		Params      map[string]string `json:"params,omitempty"`
		TimeoutSecs int               `json:"timeout_secs,omitempty"`
		QueryName   string            `json:"query_name,omitempty"`
		Text        string            `json:"text,omitempty"`
	}
	// CommunityHelp is the payload of community_help.
	CommunityHelp struct {
		Tool     string `json:"tool"`
		Database string `json:"database,omitempty"`
	}
	// CustomReport is the payload of custom_report.
	CustomReport struct {
		ReportID int64              `json:"report_id"`
		EditedAt string             `json:"edited_at"`
		From     string             `json:"from,omitempty"`
		To       string             `json:"to,omitempty"`
		Params   map[string]*string `json:"params,omitempty"`
	}
	// Explain is the payload of explain.
	Explain struct {
		Statement string `json:"statement"`
		Datname   string `json:"datname,omitempty"`
	}
	// ExplainAnalyze is the payload of explain_analyze.
	ExplainAnalyze struct {
		Statement   string `json:"statement"`
		Datname     string `json:"datname,omitempty"`
		Reason      string `json:"reason"`
		TimeoutSecs int    `json:"timeout_secs,omitempty"`
	}
	// HypoIndex is the payload of hypo_index.
	HypoIndex struct {
		PlanID int64  `json:"plan_id"`
		N      int    `json:"n"`
		Reason string `json:"reason"`
		DDL    string `json:"ddl,omitempty"`
	}
	// IndexAdvisor is the payload of index_advisor.
	IndexAdvisor struct {
		Database string `json:"database"`
	}
	// AdminTest is the payload of admin_test.
	AdminTest struct{}
	// CollectNow is the payload of collect_now.
	CollectNow struct {
		Collection string `json:"collection"`
	}
)

// newPayload is the empty payload of a kind, for Decode.
func newPayload(kind string) (any, bool) {
	switch kind {
	case "pg_cancel", "pg_terminate":
		return &PGSignal{}, true
	case "pg_job_stop", "pg_job_start":
		return &PGJob{}, true
	case "mssql_preview":
		return &MSPreview{}, true
	case "mssql_kill":
		return &MSKill{}, true
	case "mssql_job_start", "mssql_job_stop":
		return &MSJob{}, true
	case "mssql_plan_evict":
		return &MSPlanEvict{}, true
	case "community_run":
		return &CommunityRun{}, true
	case "community_help":
		return &CommunityHelp{}, true
	case "custom_report":
		return &CustomReport{}, true
	case "explain":
		return &Explain{}, true
	case "explain_analyze":
		return &ExplainAnalyze{}, true
	case "hypo_index":
		return &HypoIndex{}, true
	case "index_advisor":
		return &IndexAdvisor{}, true
	case "admin_test":
		return &AdminTest{}, true
	case "collect_now":
		return &CollectNow{}, true
	}
	return nil, false
}

// Decode reads a claimed request's payload into its kind's type, strictly: a key the type does not have refuses the
// run here too (the insert refused it already; a row the owner wrote by hand is refused the same way).
func Decode(kind string, raw []byte) (any, error) {
	p, ok := newPayload(kind)
	if !ok {
		return nil, fmt.Errorf("the queue knows no kind %s", kind)
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if err := d.Decode(p); err != nil {
		return nil, fmt.Errorf("%s: the payload does not fit the kind: %w", kind, err)
	}
	return p, nil
}

// Request is one claimed request.
type Request struct {
	ID        int64
	Kind      string
	Instance  string
	UIUser    string
	Client    string
	Payload   any           // the kind's type, decoded
	Remaining time.Duration // expires_at - now() on the repository clock at the claim
}

// Env is what a runner gets besides the request: the instance as this collector holds it, the whole configuration
// (the doors read it), the repository pool (a runner that reads the store: a custom report's SQL, a stored plan) and
// this worker's names.
type Env struct {
	Log         *slog.Logger
	Cfg         *config.Config
	Instance    config.Instance
	Repo        *pgxpool.Pool
	CollectorID string
	Host        string
}

// End is a run's end. State is done, failed, refused or cancelled; Result (a read's sets) is stored for its asker;
// Audit writes the run's audit rows through the existing import_* functions in the transaction that writes the end,
// so a run whose audit row fails ends with neither.
type End struct {
	State   string
	Outcome string
	Refusal string
	Result  any
	Rows    int
	Audit   func(ctx context.Context, tx pgx.Tx) error
}

// Door is one door of a kind on one instance: Name "" is the kind's own; a name is a tool or a job (ST4's lists).
type Door struct {
	Name string
	Open bool
	Why  string
}

// Runner runs one kind: Doors says, from this collector's configuration alone, which doors of the kind the instance
// has (the words are the direct path's own); Run runs a request whose doors were open at the claim and are checked
// again by the worker before Run. Run returns done only when its work completed: a run its context cut returns
// failed (the worker then records a cancel's own words, or the deadline's), since the worker reads a done that comes
// with a cancel as a run that had ended before the cancel landed.
type Runner interface {
	Doors(env *Env) []Door
	Run(ctx context.Context, env *Env, r Request) End
}

var (
	regMu    sync.RWMutex
	registry = map[string]Runner{}
)

// Register makes a kind runnable through the queue. A part of the build calls it from its own file's init; a second
// registration of a kind, or one of a kind 0200 does not know, is a programming error.
func Register(kind string, r Runner) {
	regMu.Lock()
	defer regMu.Unlock()
	if _, ok := Kinds[kind]; !ok {
		panic("cq: Register of a kind 0200 does not know: " + kind)
	}
	if _, dup := registry[kind]; dup {
		panic("cq: a second Register of " + kind)
	}
	registry[kind] = r
}

// runnerOf is the registered runner of a kind, or nil.
func runnerOf(kind string) Runner {
	regMu.RLock()
	defer regMu.RUnlock()
	return registry[kind]
}

// registered is the registered kinds in name order.
func registered() []string {
	regMu.RLock()
	defer regMu.RUnlock()
	out := make([]string, 0, len(registry))
	for k := range registry {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
