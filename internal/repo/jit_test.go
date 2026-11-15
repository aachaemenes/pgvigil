package repo

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestJITOffStatement: the statement migrate runs (and prints for a database's owner) names the database as a quoted
// identifier, so an odd name cannot change the statement.
func TestJITOffStatement(t *testing.T) {
	for db, want := range map[string]string{
		"pgvigil":         `ALTER DATABASE "pgvigil" SET jit = off`,
		`we"ird db`:       `ALTER DATABASE "we""ird db" SET jit = off`,
		"x; DROP TABLE y": `ALTER DATABASE "x; DROP TABLE y" SET jit = off`,
	} {
		if got := jitOffStatement(db); got != want {
			t.Errorf("jitOffStatement(%q) = %s; want %s", db, got, want)
		}
	}
}

// explained is the part of EXPLAIN (ANALYZE, FORMAT JSON) this test reads.
type explained []struct {
	Plan struct {
		TotalCost float64 `json:"Total Cost"`
	} `json:"Plan"`
	JIT *struct {
		Functions int             `json:"Functions"`
		Options   map[string]bool `json:"Options"`
		Timing    json.RawMessage `json:"Timing"`
	} `json:"JIT"`
	ExecutionTime float64 `json:"Execution Time"`
}

// TestRepositorySessionsRunWithoutJIT: on a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it) whose server
// can compile with jit, a NEW session that sends no startup parameter of pgvigil's (a Grafana, psql or BI login's
// session) reads jit = off after Migrate, and its read of the findings view compiles nothing; a session that names
// jit = on itself keeps it. THE CONTROL (fail, never skip): the same read with jit on shows a JIT section with
// inlining and optimisation, so the read does cross the server's jit thresholds - without it a green would prove
// nothing. The timings with jit on and off are printed, never asserted.
func TestRepositorySessionsRunWithoutJIT(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	r, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.Migrate(ctx); err != nil {
		r.Close()
		t.Fatal(err)
	}
	r.Close()

	plain, err := pgx.Connect(ctx, dsn) // a session with no startup parameter of pgvigil's
	if err != nil {
		t.Fatal(err)
	}
	defer plain.Close(ctx)
	var available bool
	if err := plain.QueryRow(ctx, `SELECT pg_jit_available()`).Scan(&available); err != nil {
		t.Fatal(err)
	}
	if !available {
		t.Fatal("the control cannot run: pg_jit_available() is false on this server (a PostgreSQL with its LLVM module is needed)")
	}
	var jit, above, inline, optimize string
	if err := plain.QueryRow(ctx, `SELECT current_setting('jit'), current_setting('jit_above_cost'),
       current_setting('jit_inline_above_cost'), current_setting('jit_optimize_above_cost')`).Scan(&jit, &above, &inline, &optimize); err != nil {
		t.Fatal(err)
	}
	if jit != "off" {
		t.Errorf("a new session without startup parameters reads jit = %q after Migrate; want off", jit)
	}

	const read = `EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM pgvigil.findings WHERE instance_id = -1`
	explain := func(set string) explained {
		t.Helper()
		tx, err := plain.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = tx.Rollback(ctx) }()
		if set != "" {
			if _, err := tx.Exec(ctx, set); err != nil {
				t.Fatal(err)
			}
		}
		var raw string
		if err := tx.QueryRow(ctx, read).Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var e explained
		if err := json.Unmarshal([]byte(raw), &e); err != nil || len(e) != 1 {
			t.Fatalf("EXPLAIN's JSON: %v (%d plans)", err, len(e))
		}
		return e
	}
	on := explain("SET LOCAL jit = on")
	off := explain("")
	t.Logf("findings read: total cost %.0f (jit_above_cost %s, inline %s, optimize %s); jit on %.0f ms, the plain session %.0f ms",
		on[0].Plan.TotalCost, above, inline, optimize, on[0].ExecutionTime, off[0].ExecutionTime)
	if j := on[0].JIT; j == nil {
		t.Errorf("THE CONTROL: with jit on the read shows no JIT section (total cost %.0f, jit_above_cost %s): the test proves nothing on this store", on[0].Plan.TotalCost, above)
	} else {
		t.Logf("jit on: %d functions, options %v, timing %s", j.Functions, j.Options, j.Timing)
		if !j.Options["Inlining"] || !j.Options["Optimization"] {
			t.Errorf("THE CONTROL: with jit on the read is not inlined and optimised (options %v; inline %s, optimize %s against cost %.0f)", j.Options, inline, optimize, on[0].Plan.TotalCost)
		}
	}
	if j := off[0].JIT; j != nil {
		t.Errorf("the plain session still compiled the read with jit: %d functions, timing %s", j.Functions, j.Timing)
	}

	// an explicit choice wins: a session that names jit = on itself (a startup parameter) keeps it
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.RuntimeParams["jit"] = "on"
	own, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer own.Close(ctx)
	if err := own.QueryRow(ctx, `SHOW jit`).Scan(&jit); err != nil {
		t.Fatal(err)
	}
	if jit != "on" {
		t.Errorf("a session that sends jit = on reads %q; want on (a session's own choice outranks the database's)", jit)
	}

	// a login that does not own the database: no setting written, one warning that carries the statement; then the
	// owner's run writes it back (the test's login is the scratch database's owner or a superuser)
	var db string
	if err := plain.QueryRow(ctx, `SELECT current_database()`).Scan(&db); err != nil {
		t.Fatal(err)
	}
	isOff := func() bool {
		t.Helper()
		var off bool
		if err := plain.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
             WHERE d.datname = current_database() AND s.setrole = 0 AND 'jit=off' = ANY (s.setconfig))`).Scan(&off); err != nil {
			t.Fatal(err)
		}
		return off
	}
	if !isOff() {
		t.Fatalf("after Migrate the database %s holds no jit=off setting", db)
	}
	for _, s := range []string{`DROP ROLE IF EXISTS pgv_jit_probe`, `CREATE ROLE pgv_jit_probe NOLOGIN`, "ALTER DATABASE " + pgx.Identifier{db}.Sanitize() + " RESET jit"} {
		if _, err := plain.Exec(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
	defer func() { _, _ = plain.Exec(context.WithoutCancel(ctx), `RESET ROLE; DROP ROLE IF EXISTS pgv_jit_probe`) }()
	if _, err := plain.Exec(ctx, `SET ROLE pgv_jit_probe`); err != nil {
		t.Fatal(err)
	}
	warn, err := repositoryJITOff(ctx, plain)
	if err != nil {
		t.Fatalf("a non-owner's run: %v", err)
	}
	if _, err := plain.Exec(ctx, `RESET ROLE`); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(warn, jitOffStatement(db)) {
		t.Errorf("a non-owner's run warns %q; want the statement %s in it", warn, jitOffStatement(db))
	}
	if isOff() {
		t.Error("a non-owner's run wrote the jit=off setting")
	}
	if warn, err := repositoryJITOff(ctx, plain); err != nil || warn != "" {
		t.Errorf("the owner's run: warn %q, err %v; want neither", warn, err)
	}
	if !isOff() {
		t.Error("the owner's run did not write jit=off back")
	}
}
