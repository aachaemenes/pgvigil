package repo

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// TestSaveTableAuditOnAStore (task 7b, a box row: PGVIGIL_REPO_TEST_DSN). On a store migrated from nothing:
//
//  1. THE THIRD NAMED CHECK (the lead 11-17 02:17, review-29 S6): actions_log's three CHECKs are the UNION of their
//     newest texts - 0300_join_release3.sql:2690-2697 and 0347_qsdd_s3_actions.sql:19-29 (rel-qsdd-force 8532f272) -
//     plus save_table: every action of each engine is taken, save_table and the two Query Store actions with no pid,
//     every outcome of 0300's list for every action, and 'requested' for qs_force_plan / qs_unforce_plan only. A row
//     per action, so a store migrated FROM NOTHING in name order loses none. NOT a store that ran 0362 and later gets
//     0347: rel-qsdd-force's 0347 (8532f272 / 18794012 dropped verify_backup, job_enable, job_disable and the outcomes
//     started / cut by shutdown / ended unknown; cbff8726 carries 0300's union and the Query Store actions) has NO
//     save_table [per review-31 part B S11, not read here] - the lead's join line (FINDING 0347 LACKS SAVE_TABLE).
//  3. review-31 part B S9: the audit login, IN ROLE pgvigil_collector, may call import_save_table_log (the route
//     answers 503 otherwise) and it runs as its owner with a pinned search_path; N19: PostgreSQL's cancel and
//     terminate with no pid are refused, as SQL Server's kill.
//  2. 0362's pgvigil.import_save_table_log (review-29 S3): the engine from pgvigil.instances, never the column's
//     'postgres' default; the target and the database kept; pid NULL; another action refused with an error.
func TestSaveTableAuditOnAStore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	r := haJoinFreshStore(ctx, t)
	pool := r.pool
	inst := func(name, engine string) int {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}', $2)`, name, engine).Scan(&id); err != nil {
			t.Fatalf("instance %s: %v", name, err)
		}
		return id
	}
	pg, ms := inst("st-pg", "postgres"), inst("st-ms", "sqlserver")
	row := func(id int, name, engine, action, outcome string, pid any) error {
		_, err := pool.Exec(ctx, `INSERT INTO pgvigil.actions_log (instance_id, instance_name, at, ui_user, engine, action, pid, reason, outcome)
		                          VALUES ($1, $2, now(), 'proof', $3, $4, $5, 'proof', $6)`, id, name, engine, action, pid, outcome)
		return err
	}
	// 1. the union, one row per action and engine (pid NULL where the action names no session)
	union := map[string][]string{
		"postgres":  {"cancel", "terminate", "explain_analyze", "hypo_index", "job_stop", "job_start", "job_enable", "job_disable", "save_table"},
		"sqlserver": {"kill", "job_start", "job_stop", "plan_evict", "verify_backup", "job_enable", "job_disable", "qs_force_plan", "qs_unforce_plan", "save_table"},
	}
	withPID := map[string]bool{"cancel": true, "terminate": true, "kill": true}
	for engine, acts := range union {
		id, name := pg, "st-pg"
		if engine == "sqlserver" {
			id, name = ms, "st-ms"
		}
		for _, a := range acts {
			var pid any
			if withPID[a] {
				pid = 42
			}
			for _, o := range []string{"done", "refused", "failed", "started", "cut by shutdown", "ended unknown"} {
				if err := row(id, name, engine, a, o, pid); err != nil {
					t.Errorf("%s %s outcome %q (pid %v): %v - want taken (the union of 0300:2690-2697, 0347:19-29 and 0362)", engine, a, o, pid, firstLine(err))
				}
			}
		}
	}
	for _, a := range []string{"qs_force_plan", "qs_unforce_plan"} {
		if err := row(ms, "st-ms", "sqlserver", a, "requested", nil); err != nil {
			t.Errorf("sqlserver %s 'requested': %v - want taken (0347:28-29)", a, firstLine(err))
		}
	}
	for _, c := range []struct{ engine, action string }{{"sqlserver", "kill"}, {"sqlserver", "save_table"}, {"postgres", "save_table"}} {
		id := pg
		if c.engine == "sqlserver" {
			id = ms
		}
		if err := row(id, "st-x", c.engine, c.action, "requested", nil); err == nil {
			t.Errorf("%s %s 'requested': taken - want refused ('requested' is the Query Store actions' alone)", c.engine, c.action)
		}
	}
	for _, c := range []struct{ engine, action string }{{"postgres", "kill"}, {"sqlserver", "cancel"}, {"postgres", "qs_force_plan"}} {
		id := pg
		if c.engine == "sqlserver" {
			id = ms
		}
		if err := row(id, "st-x", c.engine, c.action, "done", 1); err == nil {
			t.Errorf("%s %s: taken - want refused (another engine's action)", c.engine, c.action)
		}
	}
	if err := row(ms, "st-ms", "sqlserver", "kill", "done", nil); err == nil {
		t.Errorf("sqlserver kill with no pid: taken - want refused (a kill names its session)")
	}
	for _, a := range []string{"cancel", "terminate"} { // N19
		if err := row(pg, "st-pg", "postgres", a, "done", nil); err == nil {
			t.Errorf("postgres %s with no pid: taken - want refused (it names its session)", a)
		}
	}

	// 2. import_save_table_log
	var have bool
	if err := pool.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.import_save_table_log(int, timestamptz, jsonb)') IS NOT NULL`).Scan(&have); err != nil || !have {
		t.Fatalf("pgvigil.import_save_table_log(int, timestamptz, jsonb): present=%v %v - want 0362's function", have, err)
	}
	// 3. S9: the collector's door - EXECUTE for pgvigil_collector, SECURITY DEFINER, a pinned search_path
	var exec, secdef bool
	var conf string
	if err := pool.QueryRow(ctx, `SELECT has_function_privilege('pgvigil_collector', p.oid, 'EXECUTE'), p.prosecdef, coalesce(array_to_string(p.proconfig, ','), '')
	                                FROM pg_proc p WHERE p.oid = 'pgvigil.import_save_table_log(int, timestamptz, jsonb)'::regprocedure`).Scan(&exec, &secdef, &conf); err != nil || !exec || !secdef || !strings.Contains(conf, "search_path=") {
		t.Errorf("import_save_table_log: pgvigil_collector EXECUTE %v, SECURITY DEFINER %v, settings %q, %v - want true, true, a search_path", exec, secdef, conf, err)
	}
	imp := func(id int, payload string) error {
		_, err := pool.Exec(ctx, `SELECT pgvigil.import_save_table_log($1, now(), $2::jsonb)`, id, payload)
		return err
	}
	for _, c := range []struct {
		id             int
		name, engine   string
		target, dbname string
	}{
		{pg, "st-pg", "postgres", `app.pgvigil_saved.20261117021800`, "app"},
		{ms, "st-ms", "sqlserver", `Sales.pgvigil_saved.a]b`, "Sales"},
	} {
		p := fmt.Sprintf(`[{"instance_name": %q, "ui_user": "proof", "client": "10.0.0.9", "action": "save_table", "pid": 0, "reason": "Save Table", "outcome": "started", "target": %q, "datname": %q, "detail": "10000 rows"}]`, c.name, c.target, c.dbname)
		if err := imp(c.id, p); err != nil {
			t.Errorf("%s: import_save_table_log: %v", c.engine, firstLine(err))
			continue
		}
		var engine, target, datname string
		var pid *int
		if err := pool.QueryRow(ctx, `SELECT engine, coalesce(target, ''), coalesce(datname, ''), pid FROM pgvigil.actions_log
		                               WHERE instance_id = $1 AND action = 'save_table' AND ui_user = 'proof' AND outcome = 'started' AND client = '10.0.0.9'
		                               ORDER BY action_id DESC LIMIT 1`, c.id).Scan(&engine, &target, &datname, &pid); err != nil {
			t.Errorf("%s: the imported row: %v", c.engine, err)
			continue
		}
		if engine != c.engine || target != c.target || datname != c.dbname || pid != nil {
			t.Errorf("%s: the row reads engine %q target %q datname %q pid %v - want %q %q %q NULL", c.engine, engine, target, datname, pid, c.engine, c.target, c.dbname)
		}
	}
	if err := imp(pg, `[{"instance_name": "st-pg", "ui_user": "proof", "action": "terminate", "pid": 7, "reason": "x", "outcome": "done"}]`); err == nil {
		t.Errorf("import_save_table_log took a terminate row - want an error (a row of another action is never written there)")
	}
}

func firstLine(err error) string { return strings.SplitN(err.Error(), "\n", 2)[0] }
