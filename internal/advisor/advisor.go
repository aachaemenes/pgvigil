// Package advisor is pgvigil's index advisor, a tool run on demand (never on a schedule): on one database of a
// monitored server where pg_qualstats (Ronan Dunklau and the PoWA team, PostgreSQL licence) and HypoPG (PostgreSQL
// licence) are installed, it asks pg_qualstats_index_advisor() which indexes the predicates it sampled would want,
// then tests each one in the planner as a HYPOTHETICAL index: hypopg_create_index() adds it to this session's planner
// only (nothing is written to the catalog or to disk), the statements that would use it are EXPLAINed (planned, not
// executed: a STABLE or IMMUTABLE function the planner folds does run while planning, in this read-only session) before
// and after, and the cost difference is the gain shown. The session ends with hypopg_reset().
// The advisor never runs a CREATE INDEX: a suggestion is text for a person to review and run.
//
// It connects with the instance's monitoring login, read only, under a statement timeout. EXPLAIN needs SELECT on the
// tables a statement reads, which pg_monitor does not give: a statement whose table the login cannot read is listed
// with that reason (the client DBA's opt-in is pg_read_all_data or a grant on the tables).
package advisor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Options bound one run.
type Options struct {
	MinFilter      int           // pg_qualstats_index_advisor's min_filter: rows a predicate must filter on average (1000)
	MinSelectivity int           // its min_selectivity: the share of rows filtered, in % (30)
	MaxIndexes     int           // suggestions tested (10)
	MaxQueries     int           // statements tested per suggestion (5)
	Timeout        time.Duration // statement_timeout of the session (10 s)
}

func (o Options) withDefaults() Options {
	if o.MinFilter <= 0 {
		o.MinFilter = 1000
	}
	if o.MinSelectivity <= 0 {
		o.MinSelectivity = 30
	}
	if o.MaxIndexes <= 0 {
		o.MaxIndexes = 10
	}
	if o.MaxQueries <= 0 {
		o.MaxQueries = 5
	}
	if o.Timeout <= 0 {
		o.Timeout = 10 * time.Second
	}
	return o
}

// Query is one statement tested against a suggestion.
type Query struct {
	QueryID    int64    `json:"queryid"`
	Query      string   `json:"query,omitempty"`
	CostBefore *float64 `json:"cost_before,omitempty"`
	CostAfter  *float64 `json:"cost_after,omitempty"`
	Gain       *float64 `json:"gain_pct,omitempty"` // (before - after) / before, in %
	Used       bool     `json:"uses_index"`         // the plan with the hypothetical index reads it
	Note       string   `json:"note,omitempty"`     // why it was not tested, or what failed
}

// Suggestion is one index pg_qualstats proposed and how the planner took it.
type Suggestion struct {
	DDL       string   `json:"ddl"`
	Hypo      string   `json:"hypothetical_index,omitempty"` // HypoPG's name for it in this session
	SizeBytes *int64   `json:"estimated_bytes,omitempty"`
	Gain      *float64 `json:"best_gain_pct,omitempty"`
	Queries   []Query  `json:"queries"`
	Note      string   `json:"note,omitempty"`
}

// Report is one run's result.
type Report struct {
	Database    string            `json:"database"`
	At          time.Time         `json:"at"`
	Skipped     string            `json:"skipped,omitempty"` // the run could not happen here, and why
	Suggestions []Suggestion      `json:"suggestions"`
	Unoptimised []json.RawMessage `json:"unoptimised"` // predicates pg_qualstats saw that no index would serve
	Note        string            `json:"note"`
	Cut         string            `json:"cut,omitempty"` // the run stopped early, and where
}

// note is the line every report carries.
const note = "hypothetical indexes in the planner only (HypoPG); statements planned with EXPLAIN, not executed (functions the planner folds while planning do run, in a read-only session); no index was created"

// Run connects to database (empty = the DSN's own) with dsn and runs the advisor.
func Run(ctx context.Context, dsn, database string, o Options) (Report, error) {
	o = o.withDefaults()
	rep := Report{At: time.Now().UTC(), Suggestions: []Suggestion{}, Unoptimised: []json.RawMessage{}, Note: note}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return rep, errors.New("the monitoring dsn does not parse")
	}
	if database != "" {
		cfg.Database = database
	}
	cfg.ConnectTimeout = 10 * time.Second
	rp := cfg.RuntimeParams
	rp["application_name"] = "pgvigil-advisor"
	rp["default_transaction_read_only"] = "on"
	rp["statement_timeout"] = fmt.Sprint(o.Timeout.Milliseconds())
	rp["lock_timeout"] = "1000"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return rep, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(context.WithoutCancel(ctx)) }()
	return run(ctx, conn, rep, o)
}

type extInfo struct {
	qualstats, hypopg, pgss string // schema of each, "" = absent
	version                 int
}

func readExt(ctx context.Context, conn *pgx.Conn) (extInfo, error) {
	var e extInfo
	var db string
	err := conn.QueryRow(ctx, `
SELECT current_database()::text, current_setting('server_version_num')::int,
       coalesce((SELECT n.nspname::text FROM pg_extension x JOIN pg_namespace n ON n.oid = x.extnamespace WHERE x.extname = 'pg_qualstats'), ''),
       coalesce((SELECT n.nspname::text FROM pg_extension x JOIN pg_namespace n ON n.oid = x.extnamespace WHERE x.extname = 'hypopg'), ''),
       coalesce((SELECT n.nspname::text FROM pg_extension x JOIN pg_namespace n ON n.oid = x.extnamespace WHERE x.extname = 'pg_stat_statements'), '')`).
		Scan(&db, &e.version, &e.qualstats, &e.hypopg, &e.pgss)
	return e, err
}

func run(ctx context.Context, conn *pgx.Conn, rep Report, o Options) (Report, error) {
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&rep.Database); err != nil {
		return rep, err
	}
	e, err := readExt(ctx, conn)
	if err != nil {
		return rep, fmt.Errorf("extensions: %w", err)
	}
	switch {
	case e.qualstats == "" && e.hypopg == "":
		rep.Skipped = "neither pg_qualstats nor hypopg is installed in database " + rep.Database
		return rep, nil
	case e.qualstats == "":
		rep.Skipped = "pg_qualstats is not installed in database " + rep.Database + " (it proposes the indexes)"
		return rep, nil
	case e.hypopg == "":
		rep.Skipped = "hypopg is not installed in database " + rep.Database + " (it tests them in the planner)"
		return rep, nil
	}
	var raw []byte
	if err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT %s.pg_qualstats_index_advisor(min_filter => $1, min_selectivity => $2)::text`, ident(e.qualstats)),
		o.MinFilter, o.MinSelectivity).Scan(&raw); err != nil {
		return rep, fmt.Errorf("pg_qualstats_index_advisor: %w", err)
	}
	var adv struct {
		Indexes []struct {
			DDL      string  `json:"ddl"`
			QueryIDs []int64 `json:"queryids"`
		} `json:"indexes"`
		Unoptimised []json.RawMessage `json:"unoptimised"`
	}
	if err := json.Unmarshal(raw, &adv); err != nil {
		return rep, fmt.Errorf("pg_qualstats_index_advisor answer: %w", err)
	}
	if adv.Unoptimised != nil {
		rep.Unoptimised = adv.Unoptimised
	}
	// whatever happens below, the session's hypothetical indexes go away with it; reset them anyway
	defer func() {
		_, _ = conn.Exec(context.WithoutCancel(ctx), fmt.Sprintf(`SELECT %s.hypopg_reset()`, ident(e.hypopg)))
	}()
	for i, ix := range adv.Indexes {
		if i >= o.MaxIndexes {
			break
		}
		if ctx.Err() != nil {
			rep.Cut = fmt.Sprintf("the run's time ran out after %d of %d suggestions: the rest were not tested", i, min(len(adv.Indexes), o.MaxIndexes))
			break
		}
		s := testOne(ctx, conn, e, ix.DDL, ix.QueryIDs, o)
		if ctx.Err() != nil {
			// this suggestion's notes are the cut-off's errors, not its own
			rep.Cut = fmt.Sprintf("the run's time ran out during suggestion %d of %d: it and the rest are not reported", i+1, min(len(adv.Indexes), o.MaxIndexes))
			break
		}
		rep.Suggestions = append(rep.Suggestions, s)
	}
	return rep, nil
}

// createIndexRE is the only statement shape handed to hypopg_create_index.
var createIndexRE = regexp.MustCompile(`(?i)^\s*CREATE\s+INDEX\s+ON\s+[^;]+$`)

func testOne(ctx context.Context, conn *pgx.Conn, e extInfo, ddl string, ids []int64, o Options) Suggestion {
	s := Suggestion{DDL: ddl, Queries: []Query{}}
	if !createIndexRE.MatchString(ddl) {
		s.Note = "not a plain CREATE INDEX ON ...: not tested"
		return s
	}
	type plan struct {
		q    Query
		text string
	}
	var ps []plan
	for i, id := range ids {
		if i >= o.MaxQueries {
			break
		}
		q := Query{QueryID: id}
		text, why := queryText(ctx, conn, e, id)
		q.Query = clip(text, 2000)
		if why == "" {
			why = explainable(text, e.version)
		}
		if why != "" {
			q.Note = why
		} else if c, _, err := cost(ctx, conn, text, e.version); err != nil {
			q.Note = explainErr(err)
		} else {
			q.CostBefore = &c
		}
		ps = append(ps, plan{q, text})
	}
	var name string
	if err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT indexname FROM %s.hypopg_create_index($1)`, ident(e.hypopg)), ddl).Scan(&name); err != nil {
		s.Note = "hypopg_create_index: " + err.Error()
		for _, p := range ps {
			s.Queries = append(s.Queries, p.q)
		}
		return s
	}
	s.Hypo = name
	var size int64
	if err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT %[1]s.hypopg_relation_size(h.indexrelid) FROM %[1]s.hypopg() h WHERE h.indexname = $1`, ident(e.hypopg)), name).Scan(&size); err == nil {
		s.SizeBytes = &size
	}
	for _, p := range ps {
		q := p.q
		if q.CostBefore != nil {
			if c, js, err := cost(ctx, conn, p.text, e.version); err != nil {
				q.Note = explainErr(err)
			} else {
				q.CostAfter = &c
				q.Used = strings.Contains(js, name)
				if *q.CostBefore > 0 {
					g := 100 * (*q.CostBefore - c) / *q.CostBefore
					q.Gain = &g
					if q.Used && (s.Gain == nil || g > *s.Gain) {
						s.Gain = &g
					}
				}
			}
		}
		s.Queries = append(s.Queries, q)
	}
	_, _ = conn.Exec(ctx, fmt.Sprintf(`SELECT %s.hypopg_reset()`, ident(e.hypopg)))
	return s
}

// queryText finds a statement's text: pg_stat_statements' normalised text first ($n for the constants), else
// pg_qualstats' example query (with its constants, when pg_qualstats samples them).
//
// Below PostgreSQL 16 a normalised text ($n) cannot be planned (no GENERIC_PLAN), so there the example, which carries
// its constants, is tried first. A read that fails says why (a cut-off run, a missing grant), never "no text".
func queryText(ctx context.Context, conn *pgx.Conn, e extInfo, id int64) (string, string) {
	normalised := func() (*string, error) {
		if e.pgss == "" {
			return nil, nil
		}
		var t *string
		err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT query FROM %s.pg_stat_statements
 WHERE queryid = $1 AND dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) LIMIT 1`, ident(e.pgss)), id).Scan(&t)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return t, err
	}
	example := func() (*string, error) {
		var t *string
		err := conn.QueryRow(ctx, fmt.Sprintf(`SELECT %s.pg_qualstats_example_query($1)`, ident(e.qualstats)), id).Scan(&t)
		return t, err
	}
	usable := func(t *string) bool { return t != nil && *t != "" && !strings.HasPrefix(*t, "<insufficient") }
	first, second := normalised, example
	if e.version < 160000 {
		first, second = example, normalised
	}
	var errs []string
	for _, f := range []func() (*string, error){first, second} {
		t, err := f()
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		if usable(t) {
			return *t, ""
		}
	}
	if len(errs) > 0 {
		return "", "the statement text could not be read: " + strings.Join(errs, "; ")
	}
	return "", "no statement text: neither pg_stat_statements nor a pg_qualstats example has it"
}

var (
	paramRE   = regexp.MustCompile(`\$[0-9]+`)
	commentRE = regexp.MustCompile(`(?s)^(\s+|--[^\n]*\n|/\*.*?\*/)+`)
	selectRE  = regexp.MustCompile(`(?i)^(SELECT|WITH|TABLE|VALUES)\b`)
	writeRE   = regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE)\b`)
)

// explainable says why a text is not EXPLAINed here ("" = it is): a SELECT only (a WITH that writes is not), one
// statement, and $n parameters only where EXPLAIN (GENERIC_PLAN) exists (PostgreSQL 16).
func explainable(text string, version int) string {
	t := strings.TrimSpace(commentRE.ReplaceAllString(text, ""))
	switch {
	case !selectRE.MatchString(t):
		return "not a SELECT: the advisor plans reads only"
	case strings.HasPrefix(strings.ToUpper(t), "WITH") && writeRE.MatchString(t):
		return "a WITH that may write: not planned"
	case strings.Contains(strings.TrimRight(t, "; \n\t"), ";"):
		return "more than one statement: not planned"
	case paramRE.MatchString(t) && version < 160000:
		return "a parameterised statement needs EXPLAIN (GENERIC_PLAN), PostgreSQL 16 or later"
	}
	return ""
}

// cost EXPLAINs a statement without executing it and returns the plan's total cost and its JSON.
func cost(ctx context.Context, conn *pgx.Conn, text string, version int) (float64, string, error) {
	opts := "FORMAT JSON"
	if paramRE.MatchString(text) && version >= 160000 {
		opts = "GENERIC_PLAN, FORMAT JSON"
	}
	// the simple query protocol, raw: the statement's own $n stay in its text for GENERIC_PLAN (pgx's extended and
	// simple modes both read them as pgx's parameters). explainable has refused any text with a ';' inside, so this
	// is one statement, and the session is read only.
	res, err := conn.PgConn().Exec(ctx, "EXPLAIN ("+opts+") "+strings.TrimRight(strings.TrimSpace(text), "; \n\t")).ReadAll()
	if err != nil {
		return 0, "", err
	}
	if len(res) != 1 || len(res[0].Rows) != 1 || len(res[0].Rows[0]) != 1 {
		return 0, "", errors.New("EXPLAIN answered more than one row or result")
	}
	js := string(res[0].Rows[0][0])
	var p []struct {
		Plan struct {
			TotalCost float64 `json:"Total Cost"`
		} `json:"Plan"`
	}
	if err := json.Unmarshal([]byte(js), &p); err != nil || len(p) == 0 {
		return 0, js, fmt.Errorf("EXPLAIN answer: %v", err)
	}
	return p[0].Plan.TotalCost, js, nil
}

func explainErr(err error) string {
	s := err.Error()
	if strings.Contains(s, "permission denied") {
		return "EXPLAIN: " + s + " (EXPLAIN needs SELECT on the table: the client DBA's opt-in is pg_read_all_data or a grant to the monitoring login)"
	}
	return "EXPLAIN: " + s
}

func ident(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
