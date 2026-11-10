package demo

// Plans for the demo fleet (task 40): the shapes import_plans takes (internal/plans.Row), built by internal/plans from
// plan texts written the way EXPLAIN and auto_explain print them, so the plan rules of 0029 run on them as on a
// captured plan.
//
// Wired in gen.go at the join:
//   Step:        beside actions_log, inside `if t.Equal(g.end) {`:  add("plans", g.planRows())
//   Collections: append "plans" to the final list: ..., "extensions", "versions", "roles", "plans")
//   seed.go:     on every instance the collector's plans run reads pg_store_plans; where it is absent (odd idx)
//                logCollections marks the run skipped with plansSkipNote.

import (
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/plans"
)

// plansSkipNote is the collection log's note where pg_store_plans is absent, in the collector's words.
const plansSkipNote = "pg_store_plans is not installed in the connected database (CREATE EXTENSION pg_store_plans, with it in shared_preload_libraries)"

// demo plan texts: {t1} {t2} {t3} are the application's tables (tables in gen.go), as in statementsFor.
const (
	// the nightly report (stReport) as auto_explain logged it: a sort spilled to disk, the date range's estimate 40x low
	demoPlanReport = `Query Text: SELECT date_trunc('day', created_at) AS d, sum(amount) FROM {t2} WHERE created_at BETWEEN '2026-10-01' AND '2026-11-01' GROUP BY 1 ORDER BY 1
Sort  (cost=61873.55..61874.05 rows=200 width=40) (actual time=1802.114..1802.120 rows=31.00 loops=1)
  Sort Key: (date_trunc('day'::text, created_at))
  Sort Method: quicksort  Memory: 27kB
  ->  GroupAggregate  (cost=59210.12..61865.91 rows=200 width=40) (actual time=1240.551..1802.071 rows=31.00 loops=1)
        Group Key: (date_trunc('day'::text, created_at))
        ->  Sort  (cost=59210.12..59812.62 rows=24100 width=14) (actual time=1240.502..1610.884 rows=964512.00 loops=1)
              Sort Key: (date_trunc('day'::text, created_at))
              Sort Method: external merge  Disk: 28216kB
              ->  Seq Scan on {t2}  (cost=0.00..38411.00 rows=24100 width=14) (actual time=0.019..702.311 rows=964512.00 loops=1)
                    Filter: ((created_at >= '2026-10-01 00:00:00+00'::timestamp with time zone) AND (created_at <= '2026-11-01 00:00:00+00'::timestamp with time zone))
                    Rows Removed by Filter: 35488
Planning Time: 0.412 ms
Execution Time: 1808.344 ms`

	// statement 1 (the account's recent lines) as pg_store_plans keeps it: estimates only, a nested loop over an
	// estimated large outer
	demoPlanAccount = `Limit  (cost=0.85..9644.31 rows=20 width=12)
  ->  Nested Loop  (cost=0.85..1157215.20 rows=2400 width=12)
        ->  Index Scan Backward using {t1}_created_at_idx on {t1}  (cost=0.43..401115.62 rows=24000 width=12)
              Filter: (account_id = $1)
        ->  Index Scan using {t2}_parent_id_idx on {t2}  (cost=0.42..31.49 rows=1 width=8)
              Index Cond: (parent_id = {t1}.id)`

	// statement 0 (the point read) as pg_store_plans keeps it: a clean plan
	demoPlanPoint = `Index Scan using {t1}_pkey on {t1}  (cost=0.43..8.45 rows=1 width=96)
  Index Cond: (id = $1)`

	// the name search (statement 9) as EXPLAIN ANALYZE ran it through the actions door: a filter reading the whole table
	demoPlanSearch = `{"Plan": {"Node Type": "Hash Join", "Join Type": "Right", "Plan Rows": 12, "Actual Rows": 14, "Actual Loops": 1,
  "Hash Cond": "({t3}.owner_id = {t1}.owner_id)",
  "Plans": [
    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Relation Name": "{t3}", "Alias": "{t3}", "Plan Rows": 52000, "Actual Rows": 51870, "Actual Loops": 1},
    {"Node Type": "Hash", "Parent Relationship": "Inner", "Plan Rows": 10, "Actual Rows": 12, "Actual Loops": 1, "Hash Batches": 1, "Original Hash Batches": 1, "Peak Memory Usage": 9,
     "Plans": [
       {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Relation Name": "{t1}", "Alias": "{t1}", "Plan Rows": 10, "Actual Rows": 12, "Actual Loops": 1,
        "Filter": "(name ~~* '%acme%'::text)", "Rows Removed by Filter": 811988}]}]},
 "Planning Time": 0.31, "Triggers": [], "Execution Time": 214.6}`
)

// planRows: the plans of the anchor snapshot. Every instance has an EXPLAIN ANALYZE of the name search an hour before
// the anchor; a primary (not a replica) has the nightly report from auto_explain at 02:00 UTC of the anchor's day; an
// instance of even idx has pg_store_plans (statements 0 and 1, their queryids those of the Statements tab).
func (g *Gen) planRows() []Row {
	s := g.Spec
	t := tables[s.App]
	r := strings.NewReplacer("{t1}", t[0], "{t2}", t[1], "{t3}", t[2])
	db := s.DBs[0]
	var out []Row
	add := func(p plans.Row) { out = append(out, p.Map()) }

	search := plans.Build(plans.ExplainAnalyze, g.end.Add(-time.Hour), "", db, g.stmts[9].text, r.Replace(demoPlanSearch))
	ms := 215.0
	search.DurationMS = &ms
	add(search)

	if !s.Replica {
		night := time.Date(g.end.Year(), g.end.Month(), g.end.Day(), 2, 0, 3, 0, time.UTC)
		if night.After(g.end) {
			night = night.Add(-24 * time.Hour)
		}
		msg := "duration: 1808.344 ms  plan:\n" + r.Replace(demoPlanReport)
		if p, ok := plans.FromLogMessage(night, db, "app_"+s.App, msg); ok {
			add(p)
		}
	}
	if g.idx%2 == 0 {
		for _, st := range []struct {
			i     int
			plan  string
			calls int64
			mean  float64
		}{{0, demoPlanPoint, 1820400, 0.08}, {1, demoPlanAccount, 455100, 1.8}} {
			qid := hash64(s.Name + "|" + g.stmts[st.i].text)
			p := plans.Build(plans.PgStorePlans, g.end, "psp:"+itoa64(dbOID(0))+":16390:"+itoa64(qid)+":"+itoa64(hash64(st.plan)), db, "", r.Replace(st.plan))
			p.QueryID = &qid
			planid := hash64(st.plan)
			p.PlanID = &planid
			calls := st.calls
			p.Calls = &calls
			total := float64(st.calls) * st.mean
			p.TotalMS = &total
			p.Usename = "app_" + s.App
			add(p)
		}
	}
	return out
}

func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
