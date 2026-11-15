package web

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/cq"
)

type cqNoPage struct{}

func (cqNoPage) InventoryGeneration(context.Context) (int64, error) { return 0, nil }
func (cqNoPage) Inventory(context.Context) ([]config.PageInstance, int64, error) {
	return nil, 0, nil
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it) whose server is also the monitored PostgreSQL (a
// login of pg_monitor made here, not a superuser), community tools through the request queue (CQ 486):
//   - the worker publishes the instance's community_run door open and its tools in cq_tools (pg_settings_changed
//     present, with its parameter list);
//   - pg_settings_changed asked through the queue ends done, and its sets equal communityExec's direct run (the same
//     columns, the same rows), read by its asker through ui_action_result;
//   - the run's audit row is custom_report_log's community_run with params via queue and the request's id;
//   - ST4: on an instance whose community_allow names pg_running alone, pg_settings_changed is refused at the insert
//     with the collector's words, and pg_running runs.
func TestCommunityThroughTheQueueOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	pc, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	sfx := time.Now().UnixNano() % 1000000000
	role := fmt.Sprintf("t486r_%d", sfx)
	if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN IN ROLE pg_monitor`, role)); err != nil {
		t.Skipf("this store's login may not make a login role: %v", err)
	}
	t.Cleanup(func() { _, _ = pool.Exec(context.Background(), fmt.Sprintf(`DROP ROLE IF EXISTS %s`, role)) })
	mon := fmt.Sprintf("host=%s port=%d user=%s dbname=%s", pc.Host, pc.Port, role, pc.Database)
	t.Setenv("PGVIGIL_CQ486_MON", mon)
	t.Setenv("PGVIGIL_CQ486_REPO", dsn)
	ia, ib := fmt.Sprintf("cq-c-%d", sfx), fmt.Sprintf("cq-d-%d", sfx)
	t.Cleanup(func() {
		c := context.Background()
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.action_requests WHERE instance = ANY($1)`, []string{ia, ib})
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.cq_workers WHERE $1 = ANY(instances)`, ia)
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.custom_report_log WHERE instance = ANY($1)`, []string{ia, ib})
	})

	// the direct run first
	tool := findTool("pg_settings_changed")
	if tool == nil {
		t.Fatal("no pg_settings_changed tool")
	}
	din := communityBody{Tool: tool.ID, TimeoutSecs: 30}
	direct, _, refused := communityExec(ctx, tool, &din, ia, mon, noDoor{}, instanceRun{Instance: ia, Engine: "postgres", Door: "file"}, "u486", "test")
	if refused != nil || direct.Outcome != "done" || len(direct.Sets) == 0 {
		t.Fatalf("the direct run: %+v %v", direct, refused)
	}

	cfg := &config.Config{Repository: config.Repository{DSNRaw: "env:PGVIGIL_CQ486_REPO"},
		Instances: []config.Instance{{Name: ia, Engine: config.EnginePostgres, DSNRaw: "env:PGVIGIL_CQ486_MON"},
			{Name: ib, Engine: config.EnginePostgres, DSNRaw: "env:PGVIGIL_CQ486_MON", CommunityAllow: []string{"pg_running"}}},
		CQ: config.CQ{Enabled: true, Workers: 2, ResultKeep: "read"}}
	wctx, wstop := context.WithCancel(ctx)
	wdone := make(chan error, 1)
	go func() { wdone <- cq.Run(wctx, slog.New(slog.DiscardHandler), cfg, cqNoPage{}) }()
	defer func() {
		wstop()
		if err := <-wdone; err != nil {
			t.Errorf("the worker's run: %v", err)
		}
	}()

	waitFor := func(what string, d time.Duration, ok func() bool) {
		t.Helper()
		end := time.Now().Add(d)
		for time.Now().Before(end) {
			if ok() {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
		t.Fatalf("%s: not within %s", what, d)
	}
	waitFor("the community door and the tools published", 20*time.Second, func() bool {
		var open, present bool
		var params []byte
		err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pgvigil.action_doors WHERE instance = $1 AND kind = 'community_run' AND name = '' AND open),
			coalesce((SELECT present FROM pgvigil.cq_tools WHERE instance = $1 AND tool = 'pg_settings_changed'), false),
			(SELECT params::text FROM pgvigil.cq_tools WHERE instance = $1 AND tool = 'pg_settings_changed')`, ia).Scan(&open, &present, &params)
		return err == nil && open && present
	})

	ask := func(inst, tool string) (string, string, int64) {
		t.Helper()
		var raw []byte
		body := fmt.Sprintf(`{"kind": "community_run", "instance": %q, "ui_user": "u486", "client": "test", "args": {"tool": %q}}`, inst, tool)
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_request($1::jsonb)::text`, body).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var a struct {
			Outcome, Detail string
			RequestID       int64 `json:"request_id"`
		}
		_ = json.Unmarshal(raw, &a)
		return a.Outcome, a.Detail, a.RequestID
	}
	done := func(id int64) map[string]any {
		t.Helper()
		var m map[string]any
		waitFor(fmt.Sprintf("request %d ended", id), 20*time.Second, func() bool {
			var raw []byte
			if err := pool.QueryRow(ctx, `SELECT pgvigil.ui_action_result($1, 'u486')::text`, id).Scan(&raw); err != nil {
				return false
			}
			m = map[string]any{}
			_ = json.Unmarshal(raw, &m)
			s, _ := m["state"].(string)
			return s != "waiting" && s != "running"
		})
		return m
	}

	out, detail, id := ask(ia, "pg_settings_changed")
	if out != "waiting" {
		t.Fatalf("the ask: %s %s", out, detail)
	}
	m := done(id)
	if m["state"] != "done" {
		t.Fatalf("pg_settings_changed through the queue: %v", m)
	}
	var queued struct {
		Sets []resultSet `json:"sets"`
	}
	b, _ := json.Marshal(m["result"])
	if err := json.Unmarshal(b, &queued); err != nil || len(queued.Sets) != len(direct.Sets) {
		t.Fatalf("the queue's sets %s, the direct run's %d set(s): %v", b, len(direct.Sets), err)
	}
	if strings.Join(queued.Sets[0].Columns, ",") != strings.Join(direct.Sets[0].Columns, ",") || len(queued.Sets[0].Rows) != len(direct.Sets[0].Rows) {
		t.Fatalf("queue %v / %d rows, direct %v / %d rows", queued.Sets[0].Columns, len(queued.Sets[0].Rows), direct.Sets[0].Columns, len(direct.Sets[0].Rows))
	}
	var via string
	if err := pool.QueryRow(ctx, `SELECT params->>'via' FROM pgvigil.custom_report_log
		WHERE op = 'community_run' AND instance = $1 AND tool = 'pg_settings_changed' AND params->>'request_id' = $2`, ia, fmt.Sprint(id)).Scan(&via); err != nil || via != "queue" {
		t.Fatalf("the audit row of request %d: %q %v", id, via, err)
	}

	// ST4: the allow-list of the second instance
	waitFor("the second instance's doors", 20*time.Second, func() bool {
		var n int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.action_doors WHERE instance = $1 AND kind = 'community_run' AND name = 'pg_settings_changed' AND NOT open`, ib).Scan(&n)
		return n == 1
	})
	if out, detail, _ := ask(ib, "pg_settings_changed"); out != "refused" || !strings.Contains(detail, "Settings changed is not in community_allow for this instance") {
		t.Fatalf("a tool outside community_allow: %s %q", out, detail)
	}
	out, detail, id = ask(ib, "pg_running")
	if out != "waiting" {
		t.Fatalf("a tool inside community_allow: %s %s", out, detail)
	}
	if m := done(id); m["state"] != "done" {
		t.Fatalf("pg_running on the allow-listed instance: %v", m)
	}
}

// A result over 8 MB is cut from the end until it fits, the cut said and the cut set marked.
func TestCQSetsCut(t *testing.T) {
	old := cqResultMax
	cqResultMax = 4096
	defer func() { cqResultMax = old }()
	big := resultSet{Columns: []string{"x"}}
	for i := 0; i < 1000; i++ {
		big.Rows = append(big.Rows, []any{strings.Repeat("y", 40)})
	}
	small := resultSet{Columns: []string{"a"}, Rows: [][]any{{1}}}
	out := cqSets(instanceRun{Sets: []resultSet{small, big}})
	b, _ := json.Marshal(out)
	sets := out["sets"].([]resultSet)
	if cqStoredSize(b) > 4096 || !sets[1].Truncated || len(sets[0].Rows) != 1 || !strings.HasPrefix(fmt.Sprint(out["cut"]), "cut at ") {
		t.Fatalf("the cut: %d bytes, %v", len(b), out["cut"])
	}
	if len(big.Rows) != 1000 {
		t.Fatal("the run's own sets were changed by the cut")
	}
	if o := cqSets(instanceRun{Sets: []resultSet{small}}); o["cut"] != nil {
		t.Fatalf("a small result was cut: %v", o["cut"])
	}
}

// The cut is measured as jsonb's text writes it (review 20261114-215058 finding 4): a separator is one byte more there.
func TestCQStoredSize(t *testing.T) {
	if n := cqStoredSize([]byte(`{"a":[1,2]}`)); n != 13 { // jsonb's text: {"a": [1, 2]}
		t.Fatalf("cqStoredSize = %d, want 13", n)
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): a result of 300,000 rows of ten one-digit cells
// (6.6 MB as encoding/json writes it, 9.6 MB as jsonb's text) is cut by cqSets until jsonb's text of it fits
// ui_action_data's 8 MB CHECK (review 20261114-215058 box job 3: before the fold it did not).
func TestCQSetsFitTheStoreOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	set := resultSet{Columns: []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"}}
	for i := 0; i < 300000; i++ {
		set.Rows = append(set.Rows, []any{1, 2, 3, 4, 5, 6, 7, 8, 9, 0})
	}
	out := cqSets(instanceRun{Sets: []resultSet{set}})
	if out["cut"] == nil {
		t.Fatal("a 9.6 MB result was not cut")
	}
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	var n int
	if err := conn.QueryRow(ctx, `SELECT octet_length($1::jsonb::text)`, string(b)).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n > 8388608 {
		t.Fatalf("the cut result is %d bytes as jsonb's text, over the 8 MB CHECK", n)
	}
}

// Glenn Berry's queries carry free SQL text: through the queue their named door is shut unless community_allow names
// them or says all (review 20261114-215058 finding 16); a procedure stays open with the list unset.
func TestCQScriptToolShutByDefault(t *testing.T) {
	door := func(list []string) (cq.Door, bool) {
		in := config.Instance{Name: "ms1", Engine: config.EngineSQLServer, CommunityAllow: list}
		env := &cq.Env{Cfg: &config.Config{Instances: []config.Instance{in}}, Instance: in}
		for _, d := range cqCommunityDoors(env) {
			if d.Name == "glenn_berry" {
				return d, true
			}
		}
		return cq.Door{}, false
	}
	if d, shut := door(nil); !shut || d.Open || !strings.Contains(d.Why, "sends free SQL text") {
		t.Fatalf("glenn_berry with community_allow unset: %+v %v, want a shut door with the words", d, shut)
	}
	for _, list := range [][]string{{"glenn_berry"}, {"SQL Server Diagnostic Queries"}, {"all"}} {
		if d, shut := door(list); shut {
			t.Fatalf("glenn_berry with community_allow %v: %+v, want no shut door", list, d)
		}
	}
	if d, shut := door([]string{"sp_Blitz"}); !shut || !strings.Contains(d.Why, "is not in community_allow") {
		t.Fatalf("glenn_berry with a list that leaves it out: %+v", d)
	}
	in := config.Instance{Name: "ms1", Engine: config.EngineSQLServer}
	for _, d := range cqCommunityDoors(&cq.Env{Cfg: &config.Config{Instances: []config.Instance{in}}, Instance: in}) {
		if d.Name == "sp_WhoIsActive" {
			t.Fatalf("sp_WhoIsActive shut with community_allow unset: %+v", d)
		}
	}
}
