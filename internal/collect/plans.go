package collect

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/plans"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// plansCollector reads pg_store_plans where it is installed in the connected database: the plans with the most
// total time, each with its queryid (pg_stat_statements' where the extension keeps both), its planid, its calls
// and total time (cumulative), the database and the role, into pgvigil.plans through import_plans (0029). The
// plan text is what pg_store_plans.plan_format makes it (text by default, JSON when set); internal/plans reads
// either into the JSON form the plan rules read.
//
// pg_store_plans shows another role's plans to a member of pg_read_all_stats (pg_monitor holds it), as
// pg_stat_statements does. Where it is absent the run is skipped with the reason; the other two capture paths
// (auto_explain in the log, the on-demand EXPLAIN) do not depend on it.
type plansCollector struct{}

func init() { Register(plansCollector{}) }

func (plansCollector) Name() string                   { return "plans" }
func (plansCollector) DefaultInterval() time.Duration { return 15 * time.Minute }
func (plansCollector) Applies(platform.Info) (bool, string) {
	return true, "" // whether pg_store_plans is installed is read by the run itself
}

// plansTopN bounds one read: the plans with the most total time.
const plansTopN = 100

// RunInstance applies the instance's query-text policy to the plans (their conditions carry the statements'
// literals): none skips the read, normalized masks every expression of every plan.
func (c plansCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	if in.QueryText == "none" {
		return nil, fmt.Errorf("query_text is none on this instance: a plan's conditions carry the statement's literals, so plans are not read: %w", ErrSkip)
	}
	return c.read(ctx, conn, in.QueryText)
}

func (c plansCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	return c.read(ctx, conn, "")
}

func (plansCollector) read(ctx context.Context, conn *pgx.Conn, mode string) ([]Row, error) {
	var schema string
	err := conn.QueryRow(ctx, `SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_store_plans'`).Scan(&schema)
	if err == pgx.ErrNoRows {
		return nil, fmt.Errorf("pg_store_plans is not installed in the connected database (CREATE EXTENSION pg_store_plans, with it in shared_preload_libraries): %w", ErrSkip)
	}
	if err != nil {
		return nil, fmt.Errorf("pg_store_plans schema: %w", err)
	}
	cols := map[string]bool{}
	rows, err := conn.Query(ctx, `SELECT a.attname FROM pg_attribute a WHERE a.attrelid = ($1 || '.pg_store_plans')::regclass AND a.attnum > 0 AND NOT a.attisdropped`, quoteIdent(schema))
	if err != nil {
		return nil, fmt.Errorf("pg_store_plans columns: %w", err)
	}
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			rows.Close()
			return nil, err
		}
		cols[c] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sql, err := plansQuery(cols, quoteIdent(schema))
	if err != nil {
		return nil, err
	}
	rs, err := conn.Query(ctx, sql)
	if err != nil {
		return nil, fmt.Errorf("pg_store_plans: %w", err)
	}
	defer rs.Close()
	now := time.Now()
	var out []Row
	for rs.Next() {
		var (
			dbid, userid    int64
			queryid, planid int64
			plan            string
			calls           int64
			total           float64
			datname, role   *string
		)
		if err := rs.Scan(&dbid, &userid, &queryid, &planid, &plan, &calls, &total, &datname, &role); err != nil {
			return nil, err
		}
		r := plansRow(now, dbid, userid, queryid, planid, plan, calls, total, plansDeref(datname), plansDeref(role))
		if plans.Mask(&r, mode, normalizeSQL) {
			out = append(out, r.Map())
		}
	}
	return out, rs.Err()
}

// plansQuery builds the read from the columns the installed pg_store_plans has: the queryid that matches
// pg_stat_statements (queryid_stat_statements where the version has it, else queryid), the total time
// (total_exec_time where the version has it, else total_time).
func plansQuery(cols map[string]bool, schema string) (string, error) {
	pick := func(names ...string) string {
		for _, n := range names {
			if cols[n] {
				return "p." + n
			}
		}
		return ""
	}
	qid := pick("queryid_stat_statements", "queryid")
	total := pick("total_exec_time", "total_time")
	if qid == "" || total == "" || !cols["planid"] || !cols["plan"] || !cols["calls"] || !cols["dbid"] || !cols["userid"] {
		return "", fmt.Errorf("pg_store_plans has an unknown shape (columns %v): %w", plansColumns(cols), ErrSkip)
	}
	return fmt.Sprintf(`
SELECT p.dbid::int8, p.userid::int8, coalesce(%s, 0)::int8, p.planid::int8, p.plan, p.calls::int8, %s::float8, d.datname, r.rolname
  FROM %s.pg_store_plans p
  LEFT JOIN pg_database d ON d.oid = p.dbid
  LEFT JOIN pg_roles r    ON r.oid = p.userid
 WHERE p.plan IS NOT NULL AND p.plan NOT LIKE '<insufficient privilege>%%'
 ORDER BY %s DESC
 LIMIT %d`, qid, total, schema, total, plansTopN), nil
}

// plansRow is one pg_store_plans row as an import_plans row; the key holds the database and the role, since a
// queryid and planid pair repeats across them.
func plansRow(at time.Time, dbid, userid, queryid, planid int64, plan string, calls int64, total float64, datname, role string) plans.Row {
	key := "psp:" + strconv.FormatInt(dbid, 10) + ":" + strconv.FormatInt(userid, 10) + ":" + strconv.FormatInt(queryid, 10) + ":" + strconv.FormatInt(planid, 10)
	r := plans.Build(plans.PgStorePlans, at, key, datname, "", plan)
	r.Usename = role
	if queryid != 0 {
		r.QueryID = &queryid
	}
	r.PlanID = &planid
	r.Calls = &calls
	r.TotalMS = &total
	return r
}

func plansDeref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func plansColumns(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// PolicyText is a statement as the instance's query-text policy lets the repository keep it outside a plan (the
// EXPLAIN ANALYZE audit row): the text under full; its shape, literals replaced, under normalized and none (an audit
// row must say what ran, so none keeps the shape rather than nothing).
func PolicyText(s, mode string) string {
	if mode == "normalized" || mode == "none" {
		return normalizeSQL(s)
	}
	return s
}

// MaskPlan applies an instance's query-text policy (full | normalized | none) to a plan row with the collector's own
// normalizer: false = the policy keeps no plan. The web's on-demand EXPLAIN and the log readers' plan lines use it.
func MaskPlan(r *plans.Row, mode string) bool { return plans.Mask(r, mode, normalizeSQL) }
