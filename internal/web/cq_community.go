package web

// cq_community.go: the community tools through the request queue (task CQ, 486). The worker (internal/cq, in
// `pgvigil run` with cq.enabled) runs community_run and community_help with this collector's own read logins; the run is
// communityExec, the same code serve's direct run calls, so its refusal words are the direct path's. Registered here,
// in package web, because internal/cq must never import internal/web.

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/cq"
)

func init() {
	cq.Register("community_run", cqCommunityRun{})
	cq.Register("community_help", cqCommunityHelp{})
	cq.RegisterPublisher(cqPublishTools)
}

// cqPage: an instance of the worker's held set that is not in its pgvigil.yaml came from Admin > Instances.
func cqPage(env *cq.Env) bool {
	return !slices.ContainsFunc(env.Cfg.Instances, func(in config.Instance) bool { return in.Name == env.Instance.Name })
}

func cqEngine(in config.Instance) string {
	if in.Engine == "" {
		return config.EnginePostgres
	}
	return in.Engine
}

// cqReadLogin is readLogin's answer on the collector: the instance's read login as this collector holds it, or why
// not in readLogin's own words (the page's door also needs this collector's doors.page_instance_reads).
func cqReadLogin(env *cq.Env) (dsn, kind string, no noDoor) {
	name, page := env.Instance.Name, cqPage(env)
	if page && !env.Cfg.Doors.PageInstanceReads {
		return "", "", noDoor{config.PageReadsOff, howFile}
	}
	dsn = env.Instance.DSN()
	switch {
	case dsn == "" && page:
		return "", "", noDoor{"instance " + name + ": its credential is not readable on this host (stored by another host's serve, or a file this account cannot read)", howPageAgain}
	case dsn == "":
		return "", "", noDoor{"instance " + name + ": its read login's dsn (env:, file: or dpapi:) resolved to an empty string on this server", howFile}
	case page:
		return dsn, "page", noDoor{}
	}
	return dsn, "file", noDoor{}
}

// cqCommunityDoors: the kind's door (the read login) and a shut named door per tool ST4's community_allow leaves out
// (unset = every tool, as today; a tool is named by its id or its name).
func cqCommunityDoors(env *cq.Env) []cq.Door {
	_, _, no := cqReadLogin(env)
	out := []cq.Door{{Name: "", Open: no.Why == "", Why: no.Why}}
	eng := cqEngine(env.Instance)
	for _, t := range communityTools {
		if t.Engine != eng {
			continue
		}
		okID, why := config.Allowed(env.Instance.CommunityAllow, t.ID, "community_allow", true)
		okName, _ := config.Allowed(env.Instance.CommunityAllow, t.Name, "community_allow", true)
		if !okID && !okName {
			out = append(out, cq.Door{Name: t.ID, Open: false, Why: strings.Replace(why, t.ID, t.Name, 1)})
		}
	}
	return out
}

// cqAuditRow writes one custom_report_log row in the worker's transaction (import_custom_report_run, as serve's
// auditRun does); the queue's own names ride in params.
func cqAuditRow(row map[string]any) func(context.Context, pgx.Tx) error {
	return func(ctx context.Context, tx pgx.Tx) error {
		b, err := json.Marshal(row)
		if err != nil {
			return err
		}
		var id int64
		return tx.QueryRow(ctx, `SELECT pgvigil.import_custom_report_run($1, $2::jsonb)`, time.Now(), string(b)).Scan(&id)
	}
}

func cqParams(env *cq.Env, r cq.Request, in *communityBody) map[string]any {
	return map[string]any{"values": in.Params, "database": in.Database, "via": "queue", "request_id": r.ID, "collector": env.Host}
}

// cqSets is a stored result: the run's sets and its words, one shape in both modes ({sets: [{columns, rows, ...}]}).
func cqSets(run instanceRun) map[string]any {
	return map[string]any{"sets": run.Sets, "declined": run.Declined, "error": run.Error, "duration_ms": run.DurationMS}
}

// cqTool is the tool of a payload on this instance, or the gate's words.
func cqTool(env *cq.Env, id string) (*communityTool, string) {
	t := findTool(id)
	if t == nil {
		return nil, fmt.Sprintf("no community tool %q", id)
	}
	if eng := cqEngine(env.Instance); eng != t.Engine {
		return nil, fmt.Sprintf("%s is a %s tool and instance %s is %s", t.Name, t.Engine, env.Instance.Name, eng)
	}
	return t, ""
}

type cqCommunityRun struct{}

func (cqCommunityRun) Doors(env *cq.Env) []cq.Door { return cqCommunityDoors(env) }

func (cqCommunityRun) Run(ctx context.Context, env *cq.Env, r cq.Request) cq.End {
	p := r.Payload.(*cq.CommunityRun)
	t, why := cqTool(env, p.Tool)
	if why != "" {
		return cq.End{State: "refused", Refusal: why}
	}
	db, err := communityDB(p.Database)
	if err != nil {
		return cq.End{State: "refused", Refusal: err.Error()}
	}
	in := communityBody{Tool: p.Tool, Database: db, Params: p.Params, TimeoutSecs: p.TimeoutSecs, Text: p.Text, QueryName: p.QueryName}
	if in.TimeoutSecs == 0 {
		in.TimeoutSecs = 60
	}
	if in.TimeoutSecs < 1 || in.TimeoutSecs > 60 {
		return cq.End{State: "refused", Refusal: "timeout_secs is 1 to 60"}
	}
	dsn, kind, no := cqReadLogin(env)
	name := env.Instance.Name
	run := instanceRun{Instance: name, Engine: t.Engine, Door: kind}
	run, stmt, refused := communityExec(ctx, t, &in, name, dsn, no, run, r.UIUser, r.Client)
	if refused != nil {
		row := refused.row
		row["outcome"], row["detail"] = "refused", refused.err.Error()
		row["params"] = cqParams(env, r, &in)
		return cq.End{State: "refused", Refusal: refused.err.Error(), Audit: cqAuditRow(row)}
	}
	row := run.audit(map[string]any{"op": "community_run", "ui_user": r.UIUser, "client": r.Client, "tool": t.ID,
		"report_name": in.QueryName, "instance": name, "outcome": run.Outcome, "detail": run.Error,
		"rows": run.Rows, "duration_ms": run.DurationMS, "statement": stmt, "params": cqParams(env, r, &in)})
	end := cq.End{State: run.Outcome, Rows: run.Rows, Result: cqSets(run), Audit: cqAuditRow(row)}
	switch run.Outcome {
	case "done":
		end.Outcome = fmt.Sprintf("%s on %s: %d set(s), %d row(s)", t.Name, name, len(run.Sets), run.Rows)
	case "refused":
		end.Refusal = run.Error
	default:
		end.State, end.Outcome = "failed", run.Error
	}
	return end
}

type cqCommunityHelp struct{}

func (cqCommunityHelp) Doors(env *cq.Env) []cq.Door { return cqCommunityDoors(env) }

// Run is the procedure's own @help, as the direct form's (CommunityParams): the procedure found in the database, its
// help run under 30 s and 2,000 rows, audited 'community_help'.
func (cqCommunityHelp) Run(ctx context.Context, env *cq.Env, r cq.Request) cq.End {
	p := r.Payload.(*cq.CommunityHelp)
	t, why := cqTool(env, p.Tool)
	if why != "" {
		return cq.End{State: "refused", Refusal: why}
	}
	if t.Kind != "proc" || t.Help == "" {
		return cq.End{State: "refused", Refusal: fmt.Sprintf("%s has no help parameter pgvigil runs", t.Name)}
	}
	db, err := communityDB(p.Database)
	if err != nil {
		return cq.End{State: "refused", Refusal: err.Error()}
	}
	dsn, kind, no := cqReadLogin(env)
	if no.Why != "" {
		return cq.End{State: "refused", Refusal: no.Why}
	}
	name := env.Instance.Name
	dbc, conn, why, err := openMS(ctx, dsn, "pgvigil-community")
	if err != nil || why != "" {
		if why == "" {
			why = err.Error()
		}
		return cq.End{State: "refused", Refusal: why}
	}
	defer func() { _ = conn.Close(); _ = dbc.Close() }()
	db = msDB(db)
	params, _, found, err := readProcParams(ctx, conn, db, t.Name, t.Help)
	switch {
	case err != nil:
		return cq.End{State: "failed", Outcome: fmt.Sprintf("the parameters of %s could not be read: %v", t.Name, err)}
	case !found:
		return cq.End{State: "refused", Refusal: fmt.Sprintf("%s is not installed in %s on %s: pgvigil never installs it; get it from %s", t.Name, db, name, t.URL)}
	}
	stmt := "EXEC " + msQuote(db) + ".[dbo]." + msQuote(t.Name) + " " + t.Help + " = 1"
	t0 := time.Now()
	hctx, hcancel := context.WithTimeout(ctx, 30*time.Second)
	var sets []resultSet
	var rows *sql.Rows
	rows, err = conn.QueryContext(hctx, stmt)
	if err == nil {
		sets, err = readMS(rows, 2000, &sizer{}, hcancel)
	}
	hcancel()
	run := instanceRun{Instance: name, Door: kind}
	run.finish(t0, sets, "", err)
	descs := helpText(run.Sets)
	help := map[string]string{}
	for _, pr := range params {
		k := strings.ToLower(strings.TrimPrefix(pr.Name, "@"))
		help[k] = descs[k]
	}
	row := run.audit(map[string]any{"op": "community_help", "ui_user": r.UIUser, "client": r.Client, "tool": t.ID,
		"instance": name, "outcome": run.Outcome, "detail": run.Error, "rows": run.Rows,
		"duration_ms": run.DurationMS, "statement": stmt, "params": map[string]any{"database": db, "via": "queue", "request_id": r.ID, "collector": env.Host}})
	res := cqSets(run)
	res["params"], res["help"] = params, help
	end := cq.End{State: "done", Rows: run.Rows, Result: res, Audit: cqAuditRow(row),
		Outcome: fmt.Sprintf("%s @help on %s: %d row(s)", t.Name, name, run.Rows)}
	if run.Outcome != "done" {
		end.State, end.Outcome = "failed", run.Error
	}
	return end
}

// cqToolRow is one row of import_cq_tools' array.
type cqToolRow struct {
	Tool    string `json:"tool"`
	Present bool   `json:"present"`
	Why     string `json:"why,omitempty"`
	Params  any    `json:"params,omitempty"`
}

// cqPublishTools publishes which community tools this instance has, why not, and each present procedure's parameter
// list (the form's), from this collector's read login: the presence checks serve runs per page view (msChecks,
// pgChecks) with no reader pool (the form's presets stay serve's), the parameters as the direct form reads them.
func cqPublishTools(ctx context.Context, env *cq.Env) error {
	name, eng := env.Instance.Name, cqEngine(env.Instance)
	dsn, _, no := cqReadLogin(env)
	var rows []cqToolRow
	hard := func(ns []toolNeed) string {
		var w []string
		for _, n := range ns {
			if n.Hard {
				w = append(w, n.What)
			}
		}
		return strings.Join(w, "; ")
	}
	if no.Why != "" {
		for _, t := range communityTools {
			if t.Engine == eng {
				rows = append(rows, cqToolRow{Tool: t.ID, Why: no.Why})
			}
		}
	} else {
		s := &Server{log: env.Log}
		var c *communityCheck
		if eng == config.EngineSQLServer {
			c = s.msChecks(ctx, 0, name, dsn, "")
		} else {
			c = s.pgChecks(ctx, name, dsn, "")
		}
		inst := hard(c.Inst)
		var dbc *sql.DB
		var conn *sql.Conn
		if eng == config.EngineSQLServer && inst == "" {
			var why string
			var err error
			if dbc, conn, why, err = openMS(ctx, dsn, "pgvigil-community"); err != nil || why != "" {
				dbc, conn = nil, nil
			} else {
				defer func() { _ = conn.Close(); _ = dbc.Close() }()
			}
		}
		for _, t := range communityTools {
			if t.Engine != eng {
				continue
			}
			row := cqToolRow{Tool: t.ID, Why: inst}
			if row.Why == "" {
				row.Why = hard(append(c.Tools[t.Name], c.Tools[t.ID]...))
			}
			switch {
			case t.Kind == "proc":
				row.Present = c.Installed[t.Name] && row.Why == ""
				if row.Present && conn != nil {
					if params, _, found, err := readProcParams(ctx, conn, msDB(c.DB), t.Name, t.Help); err == nil && found {
						row.Params = params
					}
				}
				if !c.Installed[t.Name] && row.Why == "" {
					row.Why = fmt.Sprintf("%s is not installed in %s on %s: pgvigil never installs it; get it from %s", t.Name, msDB(c.DB), name, t.URL)
				}
			default:
				row.Present, row.Params = row.Why == "", t.Params
			}
			rows = append(rows, row)
		}
	}
	b, err := json.Marshal(rows)
	if err != nil {
		return err
	}
	_, err = env.Repo.Exec(ctx, `SELECT pgvigil.import_cq_tools($1, $2, $3::jsonb)`, env.CollectorID, name, string(b))
	return err
}
