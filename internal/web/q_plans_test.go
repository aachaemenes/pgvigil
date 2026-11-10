package web

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/plans"
)

// The Plan page's refusals that need no database: the door off, no header, the -no-login server; and the buttons'
// reasons.
func TestPlansOff(t *testing.T) {
	s := &Server{log: discardLog()}
	nologin, _ := s.NewActions(context.Background(), &ActionsConfig{LogDSN: "host=x"})
	none, _ := s.NewActions(context.Background(), nil)
	for _, path := range []string{"/api/plans/explain", "/api/plans/analyze"} {
		for _, c := range []struct {
			a      *Actions
			header bool
			code   int
			want   string
		}{
			{nil, true, 403, "actions are off"},
			{none, false, 403, "X-Pgvigil header"},
			{none, true, 403, "no actions configuration"},
			{nologin, true, 403, "-no-login"},
		} {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{"instance_id":1,"statement":"select 1"}`))
			if c.header {
				req.Header.Set(loginHeader, "1")
			}
			if strings.HasSuffix(path, "explain") {
				c.a.Explain(rec, req)
			} else {
				c.a.ExplainAnalyze(rec, req)
			}
			if rec.Code != c.code || !strings.Contains(rec.Body.String(), c.want) {
				t.Errorf("%s: got %d %q, want %d with %q", path, rec.Code, rec.Body.String(), c.code, c.want)
			}
		}
	}
}

func TestPlanButtons(t *testing.T) {
	s := &Server{log: discardLog()}
	s.actions, _ = s.NewActions(context.Background(), &ActionsConfig{LogDSN: "host=x"})
	if b := s.planButtons("i1"); b.Explain || b.Analyze || !strings.Contains(b.ExplainReason, "-no-login") || b.AnalyzeReason != b.ExplainReason {
		t.Errorf("no-login: %+v", b)
	}
	// a door that is on (as NewActions leaves it with the login and the audit pool): the gate decides
	s.actions = &Actions{s: s, doors: map[string]actions.Door{
		"i1": {Monitor: "host=m", Actions: "host=a", Configured: true},
		"i2": {Monitor: "host=m"},
	}}
	if b := s.planButtons("i1"); !b.Explain || b.Analyze || !strings.Contains(b.AnalyzeReason, "off by default") {
		t.Errorf("gate off: %+v", b)
	}
	s.SetPlans(PlansConfig{Gates: map[string]actions.ExplainGate{"i1": {Enabled: true, DSN: "host=e"}, "i2": {Enabled: true}}})
	if b := s.planButtons("i1"); !b.Explain || !b.Analyze {
		t.Errorf("gate on: %+v", b)
	}
	if b := s.planButtons("i2"); !b.Explain || b.Analyze || !strings.Contains(b.AnalyzeReason, "no explain_dsn") {
		t.Errorf("no explain login: %+v", b)
	}
	if b := s.planButtons("i3"); b.Explain || !strings.Contains(b.ExplainReason, "no monitoring dsn") {
		t.Errorf("unknown instance: %+v", b)
	}
}

// TestPlansProof is run by scripts/proof-plans.sh: the real handlers behind a live UI session, the real audit pool on
// a collector login, the on-demand EXPLAIN through a pg_monitor login, EXPLAIN ANALYZE through an explain login
// with SELECT grants only (and the cancel / terminate login refused for it); the monitored server is the proof's throwaway cluster, its superuser (PLANS_SU_DSN) gives the grants
// between the steps. Each step logs "ok: ..." for the script.
func TestPlansProof(t *testing.T) {
	if os.Getenv("PGVIGIL_PLANS_PROOF") == "" {
		t.Skip("run by scripts/proof-plans.sh")
	}
	ctx := context.Background()
	env := func(k string) string {
		v := os.Getenv(k)
		if v == "" {
			t.Fatalf("%s is not set", k)
		}
		return v
	}
	mon, act, suDSN, db := env("PLANS_MONITOR_DSN"), env("PLANS_ACTIONS_DSN"), env("PLANS_SU_DSN"), env("PLANS_DB")
	inst, nodoor, monRole := env("PLANS_INSTANCE"), env("PLANS_INSTANCE_NODOOR"), env("PLANS_MONITOR_ROLE")
	expDSN, expRole := env("PLANS_EXPLAIN_DSN"), env("PLANS_EXPLAIN_ROLE")
	pool, err := pgxpool.New(ctx, env("PGVIGIL_REPO_DSN"))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	suDB := strings.Replace(suDSN, "dbname=postgres", "dbname="+db, 1) // the grants are made in the seeded database
	su, err := pgx.Connect(ctx, suDB)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = su.Close(ctx) }()
	grant := func(sql string) {
		if _, err := su.Exec(ctx, sql); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	s := &Server{pool: pool, log: discardLog()}
	s.auth = newAuth(func(context.Context, string) (string, error) { return "h", nil }, false, time.Hour)
	tok, err := s.auth.issue("proof-user", "h")
	if err != nil {
		t.Fatal(err)
	}
	a, err := s.NewActions(ctx, &ActionsConfig{LogDSN: env("PLANS_AUDIT_DSN"), Doors: map[string]actions.Door{
		inst: {Monitor: mon, Actions: act, Configured: true}, nodoor: {Monitor: mon}}})
	if err != nil {
		t.Fatalf("NewActions: %v", err)
	}
	defer a.Close()
	s.actions = a
	id := func(name string) int {
		var n int
		if err := pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, name).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	iid, nid := id(inst), id(nodoor)
	post := func(h http.HandlerFunc, body map[string]any) (int, map[string]any) {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/plans/x", bytes.NewReader(b))
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: tok})
		req.Header.Set(loginHeader, "1")
		rec := httptest.NewRecorder()
		h(rec, req)
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	str := func(m map[string]any, k string) string { v, _ := m[k].(string); return v }
	planRow := func(id any) (source, note, text string, analyzed bool, rules string) {
		n, _ := id.(float64)
		if err := pool.QueryRow(ctx, `SELECT p.source, coalesce(p.plan_note, ''), p.plan_text, p.analyzed,
		         coalesce((SELECT string_agg(r.rule, ',' ORDER BY r.rule) FROM pgvigil.plan_rules(p.plan) r), '')
		    FROM pgvigil.plans p WHERE p.plan_id = $1`, int64(n)).Scan(&source, &note, &text, &analyzed, &rules); err != nil {
			t.Fatalf("plan %v: %v", id, err)
		}
		return
	}
	rows40 := func() int {
		c, err := pgx.Connect(ctx, suDB)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = c.Close(ctx) }()
		var n int
		_ = c.QueryRow(ctx, `SELECT count(*) FROM t40`).Scan(&n)
		return n
	}
	exp := func(stmt string) map[string]any {
		return map[string]any{"instance_id": iid, "datname": db, "statement": stmt}
	}

	// C. the on-demand EXPLAIN through the monitoring login
	code, out := post(a.Explain, exp("select * from t40 where v = 1"))
	if code != 409 || !strings.Contains(str(out, "error"), "pg_read_all_data") {
		t.Fatalf("explain with pg_monitor alone: %d %v", code, out)
	}
	t.Log("ok: EXPLAIN as a pg_monitor-only login is refused (409) with the grant it lacks")
	grant("GRANT SELECT ON t40 TO " + monRole)
	code, out = post(a.Explain, exp("select * from t40 where v = 1"))
	if code != 200 || out["plan_id"] == nil {
		t.Fatalf("explain after the grant: %d %v", code, out)
	}
	src, note, text, analyzed, rules := planRow(out["plan_id"])
	if src != "explain" || analyzed || note != "" || !strings.Contains(text, `"Seq Scan"`) || rules != "" {
		t.Fatalf("the explained plan: %s %q analyzed=%v rules=%q", src, note, analyzed, rules)
	}
	t.Log("ok: EXPLAIN after GRANT SELECT: 200, stored as source explain, not analyzed, no rule hit (the rules that need actual rows are silent)")
	code, out = post(a.Explain, exp("select * from t40 where v = $1 and id > $2"))
	if code != 200 {
		t.Fatalf("generic explain: %d %v", code, out)
	}
	_, note, text, _, _ = planRow(out["plan_id"])
	if note != plans.GenericNote || !strings.Contains(text, "$1") {
		t.Fatalf("the generic plan: note %q, text %.200s", note, text)
	}
	t.Log("ok: a $n statement is planned in the generic form (the note, $1 in the plan)")
	before := rows40()
	code, out = post(a.Explain, exp("delete from t40"))
	if code != 409 || !strings.Contains(str(out, "error"), "permission denied") || rows40() != before {
		t.Fatalf("explain of a DELETE without the DELETE privilege: %d %v, rows %d -> %d", code, out, before, rows40())
	}
	t.Log("ok: EXPLAIN of a DELETE without the DELETE privilege: refused (409, EXPLAIN checks the statement's privileges)")
	grant("GRANT DELETE ON t40 TO " + monRole)
	code, out = post(a.Explain, exp("delete from t40"))
	grant("REVOKE DELETE ON t40 FROM " + monRole)
	if code != 200 || rows40() != before {
		t.Fatalf("explain of a DELETE: %d %v, rows %d -> %d", code, out, before, rows40())
	}
	t.Log("ok: EXPLAIN of a DELETE with the privilege plans it and deletes nothing (" + itoa(before) + " rows before and after)")
	if code, out = post(a.Explain, exp("select 1; delete from t40")); code != 409 || !strings.Contains(str(out, "error"), "more than one statement") {
		t.Fatalf("two statements: %d %v", code, out)
	}
	t.Log("ok: two statements are refused (409)")

	// D. EXPLAIN ANALYZE through the actions door, on the explain login (never the cancel / terminate login)
	an := func(instance int, stmt, confirm string) map[string]any {
		return map[string]any{"instance_id": instance, "datname": db, "statement": stmt, "reason": "proof: the plan of the slow report", "confirm": confirm}
	}
	gates := func(on bool, dsn string, timeout time.Duration) {
		s.SetPlans(PlansConfig{Gates: map[string]actions.ExplainGate{inst: {Enabled: on, DSN: dsn, Configured: dsn != "", Timeout: timeout}, nodoor: {Enabled: true}}})
	}
	gates(false, expDSN, 0)
	if code, out = post(a.ExplainAnalyze, an(iid, "select * from t40 where v = 1", "analyze")); code != 409 || !strings.Contains(str(out, "error"), "off by default") {
		t.Fatalf("gate off: %d %v", code, out)
	}
	t.Log("ok: EXPLAIN ANALYZE with the gate off: refused (409)")
	if code, out = post(a.ExplainAnalyze, an(nid, "select * from t40 where v = 1", "analyze")); code != 409 || !strings.Contains(str(out, "error"), "no explain_dsn") {
		t.Fatalf("no explain login: %d %v", code, out)
	}
	t.Log("ok: EXPLAIN ANALYZE on an instance without explain_dsn: refused (409)")
	gates(true, act, 0)
	if code, out = post(a.ExplainAnalyze, an(iid, "select * from t40 where v = 1", "analyze")); code != 409 || !strings.Contains(str(out, "error"), "member of pg_signal_backend") {
		t.Fatalf("the cancel / terminate login as the explain login: %d %v", code, out)
	}
	t.Log("ok: the cancel / terminate login (pg_signal_backend) named as explain_dsn: refused (409)")
	gates(true, expDSN, 0)
	if code, out = post(a.ExplainAnalyze, an(iid, "select * from t40 where v = 1", "yes")); code != 409 || !strings.Contains(str(out, "error"), "confirmation") {
		t.Fatalf("wrong confirmation: %d %v", code, out)
	}
	t.Log("ok: a typed confirmation other than analyze: refused (409)")
	if code, out = post(a.ExplainAnalyze, an(iid, "select * from t40 where v = 1", "analyze")); code != 502 || !strings.Contains(str(out, "error"), "privileges") {
		t.Fatalf("explain login without SELECT: %d %v", code, out)
	}
	t.Log("ok: the explain login without SELECT: failed (502) naming the privilege")
	grant("GRANT SELECT ON t40 TO " + expRole)
	if code, out = post(a.ExplainAnalyze, an(iid, "select * from t40 where v = 1", "analyze")); code != 200 || out["plan_id"] == nil {
		t.Fatalf("explain analyze: %d %v", code, out)
	}
	src, _, _, analyzed, rules = planRow(out["plan_id"])
	if src != "explain_analyze" || !analyzed || rules != "filter removes most rows" {
		t.Fatalf("the analyzed plan: %s analyzed=%v rules=%q", src, analyzed, rules)
	}
	t.Log("ok: EXPLAIN ANALYZE done (200): stored as explain_analyze, analyzed, the rule 'filter removes most rows'")
	// a session of another role, and a SELECT that would end it: the explain login may not signal it
	victim, err := pgx.Connect(ctx, mon)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = victim.Close(ctx) }()
	var vpid int
	if err := victim.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&vpid); err != nil {
		t.Fatal(err)
	}
	vdone := make(chan error, 1)
	go func() { _, err := victim.Exec(ctx, `SELECT pg_sleep(20)`); vdone <- err }()
	time.Sleep(300 * time.Millisecond)
	if code, out = post(a.ExplainAnalyze, an(iid, "select pg_terminate_backend(pid) from pg_stat_activity where pid = "+itoa(vpid), "analyze")); code != 502 {
		t.Fatalf("a terminating SELECT: %d %v", code, out)
	}
	alive := false
	_ = su.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = $1)`, vpid).Scan(&alive)
	select {
	case err := <-vdone:
		t.Fatalf("the victim's sleep ended: %v", err)
	default:
	}
	if !alive {
		t.Fatalf("the victim session %d is gone", vpid)
	}
	t.Log("ok: SELECT pg_terminate_backend(<another role's pid>) through the explain login: failed (502), the session lives on (" + str(out, "error") + ")")
	before = rows40()
	if code, out = post(a.ExplainAnalyze, an(iid, "with d as (delete from t40 where id = 1 returning *) select * from d", "analyze")); code != 502 || !strings.Contains(str(out, "error"), "tried to write") || rows40() != before {
		t.Fatalf("a writing CTE: %d %v, rows %d -> %d", code, out, before, rows40())
	}
	t.Log("ok: a data-modifying CTE: failed (502) in the read-only transaction, nothing deleted")
	if code, out = post(a.ExplainAnalyze, an(iid, "delete from t40 where id = 1", "analyze")); code != 409 || !strings.Contains(str(out, "error"), "SELECT statements only") {
		t.Fatalf("a DELETE: %d %v", code, out)
	}
	t.Log("ok: a DELETE: refused (409), SELECT only")
	gates(true, expDSN, time.Second)
	if code, out = post(a.ExplainAnalyze, an(iid, "select pg_sleep(3)", "analyze")); code != 502 || !strings.Contains(str(out, "error"), "timeout") {
		t.Fatalf("the timeout: %d %v", code, out)
	}
	t.Log("ok: a statement over the gate's timeout (1 s): failed (502), cancelled")
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }
