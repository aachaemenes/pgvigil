package web

// cq_community.go: the community tools through the request queue (task CQ, 486). The worker (internal/cq, in
// `pgvigil run` with cq.enabled) runs community_run and community_help with this collector's own read logins; the run is
// communityExec, the same code serve's direct run calls, so its refusal words are the direct path's. Registered here,
// in package web, because internal/cq must never import internal/web.

import (
	"bytes"
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
// (unset = every tool, as today; a tool is named by its id or its name). A script tool (Glenn Berry's queries: the
// payload carries free SQL text) is shut through the queue unless community_allow names it or says all: any holder of
// the requester login can ask under any user name, where the direct path needs a signed-in user.
func cqCommunityDoors(env *cq.Env) []cq.Door {
	_, _, no := cqReadLogin(env)
	out := []cq.Door{{Name: "", Open: no.Why == "", Why: no.Why}}
	eng := cqEngine(env.Instance)
	list := env.Instance.CommunityAllow
	for _, t := range communityTools {
		if t.Engine != eng {
			continue
		}
		def := t.Kind != "script"
		okID, why := config.Allowed(list, t.ID, "community_allow", def)
		okName, _ := config.Allowed(list, t.Name, "community_allow", def)
		if okID || okName {
			continue
		}
		why = strings.Replace(why, t.ID, t.Name, 1)
		if !def && len(list) == 0 {
			why = fmt.Sprintf("%s sends free SQL text, so through the request queue it runs only where community_allow names it (%s or all) for this instance", t.Name, t.ID)
		}
		out = append(out, cq.Door{Name: t.ID, Open: false, Why: why})
	}
	return out
}

// cqAuditRow writes one custom_report_log row in the worker's transaction (import_custom_report_run, as serve's
// auditRun does); the queue's own names ride in params. The instance's id is resolved by its name in the same
// transaction (a queue run knows only the name), so the community page's run log, read by instance id, lists it.
func cqAuditRow(row map[string]any) func(context.Context, pgx.Tx) error {
	maskAudit(row) // CQ-LIVEMASK: its detail and statement masked before the write (the run log shows them)
	return func(ctx context.Context, tx pgx.Tx) error {
		delete(row, "instance_id")
		if name, _ := row["instance"].(string); name != "" {
			var id *int64
			if err := tx.QueryRow(ctx, `SELECT pgvigil.import_cq_instance_id($1)`, name).Scan(&id); err != nil {
				return err
			}
			if id != nil {
				row["instance_id"] = *id
			}
		}
		b, err := json.Marshal(row)
		if err != nil {
			return err
		}
		var lid int64
		return tx.QueryRow(ctx, `SELECT pgvigil.import_custom_report_run($1, $2::jsonb)`, time.Now(), string(cq.NoNUL(b))).Scan(&lid)
	}
}

func cqParams(env *cq.Env, r cq.Request, in *communityBody) map[string]any {
	return map[string]any{"values": in.Params, "database": in.Database, "via": "queue", "request_id": r.ID, "collector": env.Host}
}

// cqResultMax: 0200's CHECK on a stored result (8 MB), less room for the words around the sets.
var cqResultMax = 8<<20 - 64<<10

// cqStoredSize is the size of a compact JSON text as jsonb's text form writes it, at least: jsonb writes ", " and ": "
// where encoding/json writes "," and ":", one byte more per separator (counted over the whole text, so a comma or a
// colon inside a string counts too: the measure errs large). A number jsonb writes longer than Go (1e+21 as 22
// digits) is past this measure; import_action_finish ends such a result 'failed' with words instead of raising.
func cqStoredSize(b []byte) int {
	return len(b) + bytes.Count(b, []byte{','}) + bytes.Count(b, []byte{':'})
}

// cqSets is a stored result: the run's sets and its words, one shape in both modes ({sets: [{columns, rows, ...}]}).
// Over cqResultMax as stored the rows are cut from the end (the last set first) until it fits, each cut set marked
// truncated and the cut said: 'cut at <n> rows: queue mode keeps 8 MB' (the direct run's reply stops at 24 MB). The
// column names and text cells are masked first (task 488, cq.MaskRows), so the cut measures what is stored; the
// worker masks the whole result again before it stores it (cq.MaskResult, idempotent).
func cqSets(run instanceRun) map[string]any {
	for i := range run.Sets {
		cq.MaskStrings(run.Sets[i].Columns)
		cq.MaskRows(run.Sets[i].Rows)
	}
	out := map[string]any{"sets": run.Sets, "declined": run.Declined, "error": run.Error, "duration_ms": run.DurationMS}
	if b, err := json.Marshal(out); err != nil || cqStoredSize(b) <= cqResultMax {
		return out
	}
	sets := make([]resultSet, len(run.Sets))
	copy(sets, run.Sets)
	for {
		i := len(sets) - 1
		for i >= 0 && len(sets[i].Rows) == 0 {
			i--
		}
		if i < 0 {
			break
		}
		n := len(sets[i].Rows) / 2 // halve the last set with rows until the whole fits
		sets[i].Rows, sets[i].Truncated = sets[i].Rows[:n:n], true
		out["sets"] = sets
		if b, err := json.Marshal(out); err == nil && cqStoredSize(b) <= cqResultMax {
			break
		}
	}
	kept := 0
	for _, x := range sets {
		kept += len(x.Rows)
	}
	out["cut"] = fmt.Sprintf("cut at %d rows: queue mode keeps 8 MB", kept)
	return out
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
	name := env.Instance.Name
	// the login's and the connection's refusals are audited as the direct form's are (op community_form)
	formRefused := func(why string) cq.End {
		return cq.End{State: "refused", Refusal: why, Audit: cqAuditRow(map[string]any{"op": "community_form", "ui_user": r.UIUser,
			"client": r.Client, "tool": t.ID, "instance": name, "outcome": "refused", "detail": why, "door": nilIfEmpty(kind),
			"params": map[string]any{"database": db, "via": "queue", "request_id": r.ID, "collector": env.Host}})}
	}
	if no.Why != "" {
		return formRefused(no.Why)
	}
	dbc, conn, why, err := openMS(ctx, dsn, "pgvigil-community")
	if err != nil || why != "" {
		if why == "" {
			why = err.Error()
		}
		return formRefused(why)
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

// nilIfEmpty: an audit field that is absent rather than "" (import_custom_report_run refuses a door that is not
// file, page or store).
func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// cqToolRow is one row of import_cq_tools' array.
type cqToolRow struct {
	Tool     string `json:"tool"`
	Present  bool   `json:"present"`
	Why      string `json:"why,omitempty"`
	Params   any    `json:"params,omitempty"`
	Database string `json:"database,omitempty"` // SQL Server: the database the presence was checked in
	Shut     string `json:"-"`                  // serve's read: the collector's words when its community_allow shuts the tool
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
			if eng == config.EngineSQLServer {
				row.Database = msDB(c.DB) // one database is checked (the login's default): the page says which
			}
			if row.Why == "" {
				row.Why = hard(c.Tools[t.ID]) // a procedure's id is its name
			}
			installed := c.Installed[strings.ToLower(t.Name)] // keyed lower-case, as Community reads it
			switch t.Kind {
			case "proc":
				row.Present = installed && row.Why == ""
				if row.Present && conn != nil {
					if params, _, found, err := readProcParams(ctx, conn, msDB(c.DB), t.Name, t.Help); err == nil && found {
						row.Params = params
					}
				}
				if !installed && row.Why == "" {
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
