package cq

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// registerForTest puts a stand-in runner on a kind for one test and takes it back after.
func registerForTest(t *testing.T, kind string, r Runner) {
	t.Helper()
	regMu.Lock()
	old, had := registry[kind]
	registry[kind] = r
	regMu.Unlock()
	t.Cleanup(func() {
		regMu.Lock()
		defer regMu.Unlock()
		if had {
			registry[kind] = old
		} else {
			delete(registry, kind)
		}
	})
}

// standIn: a runner whose doors are open everywhere and whose run is fn.
type standIn struct {
	fn func(ctx context.Context, env *Env, r Request) End
}

func (s standIn) Doors(*Env) []Door { return []Door{{Name: "", Open: true}} }
func (s standIn) Run(ctx context.Context, env *Env, r Request) End {
	return s.fn(ctx, env, r)
}

// noPage is an inventory with no page instances (the file's alone).
type noPage struct{}

func (noPage) InventoryGeneration(context.Context) (int64, error) { return 0, nil }
func (noPage) Inventory(context.Context) ([]config.PageInstance, int64, error) {
	return nil, 0, nil
}

func TestWorkerOffStartsNothing(t *testing.T) {
	cfg := &config.Config{CQ: config.CQ{Enabled: false, Workers: 4, ResultKeep: "read"}}
	done := make(chan error, 1)
	go func() { done <- Run(context.Background(), slog.New(slog.DiscardHandler), cfg, noPage{}) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("an off worker: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("an off worker did not return at once")
	}
}

func TestDecodeIsStrict(t *testing.T) {
	if _, err := Decode("community_run", []byte(`{"tool": "sp_WhoIsActive", "sql": "DROP TABLE t"}`)); err == nil {
		t.Fatal("a payload key the kind does not have was decoded")
	}
	p, err := Decode("mssql_kill", []byte(`{"session_id": 77, "login_time": "2026-11-14T10:00:00Z", "login": "rpt", "reason": "runaway report"}`))
	if err != nil || p.(*MSKill).SessionID != 77 {
		t.Fatalf("a good kill payload: %v %v", p, err)
	}
	if _, err := Decode("drop_database", []byte(`{}`)); err == nil {
		t.Fatal("an unknown kind was decoded")
	}
	for k := range Kinds {
		if _, ok := newPayload(k); !ok {
			t.Fatalf("kind %s has no payload type", k)
		}
	}
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), the worker against 0200 with stand-in runners:
//   - its lease names the file's instances, and only registered kinds publish doors;
//   - an ask is claimed and ended within 2 s (the notify, not the 5 s poll), its result read by its asker;
//   - a cancel of a running request ends it 'cancelled' with the asker's words;
//   - with cq.workers 3, six slow requests over two instances never run more than 3 at once nor more than 2 on one
//     instance, and an urgent kind still runs while every regular slot is busy;
//   - a run past its deadline (the repository's remainder) ends 'failed', 'the run passed its time';
//   - a stop ends a running request 'cancelled' with the collector's words, ends the lease at once, and returns.
func TestWorkerOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	ia, ib := fmt.Sprintf("cq-wa-%d", sfx), fmt.Sprintf("cq-wb-%d", sfx)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.action_requests WHERE instance = ANY($1)`, []string{ia, ib})
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.cq_workers WHERE $1 = ANY(instances) OR $2 = ANY(instances)`, ia, ib)
	})
	t.Setenv("PGVIGIL_CQ_TEST_DSN", dsn)
	cfg := &config.Config{Repository: config.Repository{DSNRaw: "env:PGVIGIL_CQ_TEST_DSN"},
		Instances: []config.Instance{{Name: ia, Engine: config.EnginePostgres}, {Name: ib, Engine: config.EnginePostgres}},
		CQ:        config.CQ{Enabled: true, Workers: 3, ResultKeep: "read"}}

	release := make(chan struct{})
	var mu sync.Mutex
	running, maxAll := 0, 0
	perInst, maxInst := map[string]int{}, 0
	slow := standIn{fn: func(ctx context.Context, env *Env, r Request) End {
		mu.Lock()
		running++
		perInst[r.Instance]++
		maxAll = max(maxAll, running)
		maxInst = max(maxInst, perInst[r.Instance])
		mu.Unlock()
		defer func() { mu.Lock(); running--; perInst[r.Instance]--; mu.Unlock() }()
		select {
		case <-release:
		case <-ctx.Done():
		}
		return End{State: "done", Outcome: "slow"}
	}}
	registerForTest(t, "admin_test", standIn{fn: func(ctx context.Context, env *Env, r Request) End {
		return End{State: "done", Outcome: "tested on " + env.Instance.Name, Rows: 1,
			Result: map[string]any{"sets": []any{map[string]any{"columns": []string{"ok"}, "rows": [][]any{{true}}}}}}
	}})
	registerForTest(t, "index_advisor", standIn{fn: func(ctx context.Context, env *Env, r Request) End {
		<-ctx.Done()
		return End{State: "done"}
	}})
	registerForTest(t, "explain", slow)
	var urgentRan atomic.Bool
	registerForTest(t, "pg_terminate", standIn{fn: func(ctx context.Context, env *Env, r Request) End {
		urgentRan.Store(true)
		return End{State: "done", Outcome: "terminated"}
	}})

	wctx, wstop := context.WithCancel(ctx)
	wdone := make(chan error, 1)
	go func() { wdone <- Run(wctx, slog.New(slog.DiscardHandler), cfg, noPage{}) }()
	defer wstop()

	waitFor := func(what string, d time.Duration, ok func() bool) {
		t.Helper()
		end := time.Now().Add(d)
		for time.Now().Before(end) {
			if ok() {
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatalf("%s: not within %s", what, d)
	}
	var wid string
	waitFor("the lease and the doors", 10*time.Second, func() bool {
		var n int
		err := pool.QueryRow(ctx, `SELECT w.collector_id, count(d.*) FROM pgvigil.cq_workers w
			LEFT JOIN pgvigil.action_doors d ON d.collector_id = w.collector_id AND d.instance = $1 AND d.open
			WHERE $1 = ANY (w.instances) AND w.beat_at IS NOT NULL GROUP BY 1`, ia).Scan(&wid, &n)
		return err == nil && n >= 4
	})
	var other int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.action_doors WHERE collector_id = $1 AND NOT (kind = ANY ($2))`, wid, registered()).Scan(&other); err != nil || other != 0 {
		t.Fatalf("an unregistered kind published %d door(s) (%v)", other, err)
	}

	ask := func(kind, inst, args string) int64 {
		t.Helper()
		var raw []byte
		body := fmt.Sprintf(`{"kind": %q, "instance": %q, "ui_user": "wt", "args": %s}`, kind, inst, args)
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_request($1::jsonb)::text`, body).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var a struct {
			Outcome   string `json:"outcome"`
			Detail    string `json:"detail"`
			RequestID int64  `json:"request_id"`
		}
		_ = json.Unmarshal(raw, &a)
		if a.Outcome != "waiting" {
			t.Fatalf("ask %s: %+v", kind, a)
		}
		return a.RequestID
	}
	stateOf := func(id int64) (string, string) {
		var s, o string
		_ = pool.QueryRow(ctx, `SELECT state, coalesce(outcome, '') FROM pgvigil.action_requests WHERE request_id = $1`, id).Scan(&s, &o)
		return s, o
	}

	// claimed and ended within 2 s, the result for its asker
	t0 := time.Now()
	id := ask("admin_test", ia, `{}`)
	waitFor("admin_test done", 2*time.Second, func() bool { s, _ := stateOf(id); return s == "done" })
	t.Logf("admin_test asked -> done in %s", time.Since(t0).Round(time.Millisecond))
	var res []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ui_action_result($1, 'wt')::text`, id).Scan(&res); err != nil || !strings.Contains(string(res), `"rows": [[true]]`) {
		t.Fatalf("the asker's result: %s %v", res, err)
	}

	// a running request cancelled
	id = ask("index_advisor", ia, `{"database": "postgres"}`)
	waitFor("index_advisor running", 2*time.Second, func() bool { s, _ := stateOf(id); return s == "running" })
	if _, err := pool.Exec(ctx, `SELECT pgvigil.import_action_cancel($1, 'wt')`, id); err != nil {
		t.Fatal(err)
	}
	waitFor("the cancel", 7*time.Second, func() bool { s, _ := stateOf(id); return s == "cancelled" })
	if _, o := stateOf(id); o != "cancelled by its asker while it ran" {
		t.Fatalf("a cancel's words: %q", o)
	}

	// the pool: six slow requests over two instances, three workers, two per instance; an urgent one meanwhile
	var slowIDs []int64
	for k := 0; k < 6; k++ {
		in := ia
		if k%2 == 1 {
			in = ib
		}
		slowIDs = append(slowIDs, ask("explain", in, `{"statement": "SELECT 1"}`))
	}
	waitFor("three running", 3*time.Second, func() bool { mu.Lock(); defer mu.Unlock(); return running == 3 })
	tid := ask("pg_terminate", ia, `{"pid": 4242, "backend_start": "2026-11-14T10:00:00Z", "reason": "stuck vacuum holds xmin"}`)
	waitFor("the urgent kind beside three busy slots", 3*time.Second, func() bool { s, _ := stateOf(tid); return s == "done" })
	time.Sleep(300 * time.Millisecond)
	close(release)
	waitFor("the six slow ones done", 10*time.Second, func() bool {
		for _, s := range slowIDs {
			if st, _ := stateOf(s); st != "done" {
				return false
			}
		}
		return true
	})
	mu.Lock()
	if maxAll > 3 || maxInst > 2 {
		mu.Unlock()
		t.Fatalf("at most %d ran at once (want 3) and %d on one instance (want 2)", maxAll, maxInst)
	}
	mu.Unlock()
	if !urgentRan.Load() {
		t.Fatal("the urgent kind did not run while the regular slots were busy")
	}

	// a stop: a running request ended with the collector's words, the lease ended, Run returns
	id = ask("index_advisor", ia, `{"database": "postgres"}`)
	waitFor("index_advisor running", 2*time.Second, func() bool { s, _ := stateOf(id); return s == "running" })
	wstop()
	select {
	case err := <-wdone:
		if err != nil {
			t.Fatalf("the worker's stop: %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("the worker did not stop in 15 s")
	}
	if s, o := stateOf(id); s != "cancelled" || !strings.Contains(o, "stopped while running it") {
		t.Fatalf("a run at the stop: %s %q", s, o)
	}
	var beat *time.Time
	if err := pool.QueryRow(ctx, `SELECT beat_at FROM pgvigil.cq_workers WHERE collector_id = $1`, wid).Scan(&beat); err != nil || beat != nil {
		t.Fatalf("the lease after a stop: %v %v (want ended)", beat, err)
	}
}

// On a migrated store: a run past its deadline - the repository's remainder at the claim, on this process's monotonic
// clock - ends 'failed' with 'the run passed its time'.
func TestWorkerDeadlineOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	sfx := time.Now().UnixNano() % 1000000000
	inst := fmt.Sprintf("cq-wd-%d", sfx)
	w := &Worker{log: slog.New(slog.DiscardHandler), pool: pool, id: fmt.Sprintf("cq-wd-%d", sfx), host: "test-host",
		cfg:  &config.Config{CQ: config.CQ{Enabled: true, Workers: 2, ResultKeep: "read"}},
		held: map[string]config.Instance{inst: {Name: inst, Engine: config.EnginePostgres}}, running: map[int64]*run{},
		byInst: map[string]int{}, wake: make(chan struct{}, 1)}
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.action_requests WHERE instance = $1`, inst)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.cq_workers WHERE collector_id = $1`, w.id)
	})
	registerForTest(t, "admin_test", standIn{fn: func(ctx context.Context, env *Env, r Request) End {
		<-ctx.Done()
		return End{State: "failed", Outcome: "the stand-in saw its context end"}
	}})
	w.beat(ctx)
	if err := publishDoors(ctx, pool, w.id, doorRows(w.env(config.Instance{}), w.held)); err != nil {
		t.Fatal(err)
	}
	var raw []byte
	if err := pool.QueryRow(ctx, `SELECT pgvigil.import_action_request($1::jsonb)::text`,
		fmt.Sprintf(`{"kind": "admin_test", "instance": %q, "ui_user": "wd", "args": {}}`, inst)).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var id int64
	if err := pool.QueryRow(ctx, `SELECT request_id FROM pgvigil.import_action_claim($1, 1, 0, '{}'::jsonb)`, w.id).Scan(&id); err != nil {
		t.Fatalf("the claim: %v (%s)", err, raw)
	}
	w.start(ctx, Request{ID: id, Kind: "admin_test", Instance: inst, UIUser: "wd", Remaining: 300 * time.Millisecond}, []byte(`{}`))
	w.runs.Wait()
	var s, o string
	if err := pool.QueryRow(ctx, `SELECT state, coalesce(outcome, '') FROM pgvigil.action_requests WHERE request_id = $1`, id).Scan(&s, &o); err != nil {
		t.Fatal(err)
	}
	if s != "failed" || o != "the run passed its time (its request expired while it ran)" {
		t.Fatalf("a run past its deadline: %s %q", s, o)
	}
}

// NoNUL: a \u0000 escape becomes � (jsonb and text refuse U+0000); an escaped backslash followed by the letters
// u0000 is not one (review 20261114-215058 finding 1, a SQL Server text cell holding NCHAR(0)).
func TestNoNUL(t *testing.T) {
	for in, want := range map[string]string{
		`{"a":"x\u0000y"}`: `{"a":"x�y"}`,
		`{"a":"\\u0000"}`:  `{"a":"\\u0000"}`,
		`{"a":"\\\u0000"}`: `{"a":"\\�"}`,
		`{"a":"plain \n"}`: `{"a":"plain \n"}`,
		`["\u0000\u0000"]`: `["��"]`,
	} {
		if got := string(NoNUL([]byte(in))); got != want {
			t.Fatalf("NoNUL(%s) = %s, want %s", in, got, want)
		}
	}
	b, _ := json.Marshal(map[string]string{"cell": "a\x00b"})
	if got := NoNUL(b); !json.Valid(got) || strings.Contains(string(got), `\u0000`) {
		t.Fatalf("NoNUL of Go's own encoding: %s", got)
	}
}

// A runner that panics ends its request 'failed' in the panic's words; the collector goes on (finding 12).
func TestRunPanicEndsFailed(t *testing.T) {
	registerForTest(t, "admin_test", standIn{fn: func(context.Context, *Env, Request) End { panic("boom in a runner") }})
	w := &Worker{log: slog.New(slog.NewTextHandler(os.Stderr, nil)), host: "h1", held: map[string]config.Instance{"i1": {Name: "i1"}}}
	end := w.runSafe(context.Background(), Request{ID: 1, Kind: "admin_test", Instance: "i1"}, []byte(`{}`))
	if end.State != "failed" || !strings.Contains(end.Outcome, "boom in a runner") || !strings.Contains(end.Outcome, "h1") {
		t.Fatalf("a panicking runner: %+v", end)
	}
}
