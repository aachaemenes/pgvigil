package repo

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
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
	defer func() { _ = plain.Close(ctx) }()
	// pg_jit_available() answers true only while jit is on in the asking session, so it is asked under SET LOCAL jit = on
	var available bool
	if tx, err := plain.Begin(ctx); err != nil {
		t.Fatal(err)
	} else {
		if _, err := tx.Exec(ctx, `SET LOCAL jit = on`); err != nil {
			t.Fatal(err)
		}
		if err := tx.QueryRow(ctx, `SELECT pg_jit_available()`).Scan(&available); err != nil {
			t.Fatal(err)
		}
		_ = tx.Rollback(ctx)
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
	defer func() { _ = own.Close(ctx) }()
	if err := own.QueryRow(ctx, `SHOW jit`).Scan(&jit); err != nil {
		t.Fatal(err)
	}
	if jit != "on" {
		t.Errorf("a session that sends jit = on reads %q; want on (a session's own choice outranks the database's)", jit)
	}

	// a login that does not own the database: no setting written, one warning that carries the statement; then the
	// owner's run writes it back. The test's login is the scratch database's owner or a superuser; it is granted each
	// probe role it makes (from PostgreSQL 16 a role's creator holds only ADMIN on it, and SET ROLE needs membership).
	var db string
	if err := plain.QueryRow(ctx, `SELECT current_database()`).Scan(&db); err != nil {
		t.Fatal(err)
	}
	entry := func() string {
		t.Helper()
		var v *string
		if err := plain.QueryRow(ctx, `SELECT (SELECT substr(x, 5) FROM pg_db_role_setting s, unnest(s.setconfig) x
             WHERE s.setdatabase = d.oid AND s.setrole = 0 AND x LIKE 'jit=%' LIMIT 1) FROM pg_database d WHERE d.datname = current_database()`).Scan(&v); err != nil {
			t.Fatal(err)
		}
		if v == nil {
			return "<none>"
		}
		return *v
	}
	isOff := func() bool { t.Helper(); return entry() == "off" }
	if !isOff() {
		t.Fatalf("after Migrate the database %s holds jit = %s; want off", db, entry())
	}
	qdb := pgx.Identifier{db}.Sanitize()
	exec := func(stmts ...string) {
		t.Helper()
		for _, x := range stmts {
			if _, err := plain.Exec(ctx, x); err != nil {
				t.Fatalf("%s: %v", x, err)
			}
		}
	}
	// whatever happens below, the store's later tests find jit off again (registered before the first RESET)
	defer func() { _, _ = plain.Exec(context.WithoutCancel(ctx), `RESET ROLE; `+jitOffStatement(db)) }()
	defer func() {
		_, _ = plain.Exec(context.WithoutCancel(ctx), `RESET ROLE; DROP ROLE IF EXISTS pgv_jit_probe; DROP ROLE IF EXISTS pgv_jit_owner`)
	}()
	exec(`DROP ROLE IF EXISTS pgv_jit_probe`, `CREATE ROLE pgv_jit_probe NOLOGIN`, `GRANT pgv_jit_probe TO CURRENT_USER`, "ALTER DATABASE "+qdb+" RESET jit")
	exec(`SET ROLE pgv_jit_probe`)
	info, warn, err := repositoryJITOff(ctx, plain)
	if err != nil {
		t.Fatalf("a non-owner's run: %v", err)
	}
	exec(`RESET ROLE`)
	if !strings.Contains(warn, jitOffStatement(db)) || info != "" {
		t.Errorf("a non-owner's run: info %q, warn %q; want no info and the statement %s in the warning", info, warn, jitOffStatement(db))
	}
	if e := entry(); e != "<none>" {
		t.Errorf("a non-owner's run wrote jit = %s", e)
	}
	if info, warn, err := repositoryJITOff(ctx, plain); err != nil || warn != "" || !strings.Contains(info, "jit set off") {
		t.Errorf("the owner's run: info %q, warn %q, err %v; want the 'jit set off' info alone", info, warn, err)
	}
	if !isOff() {
		t.Error("the owner's run did not write jit=off back")
	}

	// a database's own entry is the site's choice: on is kept and named in an info line, never rewritten; off in any
	// spelling PostgreSQL takes is nothing to do - for the owner, and for a non-owner (no warning: it is off already)
	exec("ALTER DATABASE " + qdb + " SET jit = on")
	if info, warn, err := repositoryJITOff(ctx, plain); err != nil || warn != "" || !strings.Contains(info, "sets jit = on itself") {
		t.Errorf("an entry jit = on, the owner's run: info %q, warn %q, err %v; want the 'sets jit = on itself' info alone", info, warn, err)
	}
	if e := entry(); e != "on" {
		t.Errorf("an entry jit = on reads %s after the owner's run; want it kept", e)
	}
	for _, v := range []string{"OFF", "false", "0", "no", "of"} {
		exec("ALTER DATABASE " + qdb + " SET jit = '" + v + "'") // a string constant (OF is a reserved word), stored as typed
		if info, warn, err := repositoryJITOff(ctx, plain); err != nil || info != "" || warn != "" {
			t.Errorf("an entry jit = %s, the owner's run: info %q, warn %q, err %v; want nothing", v, info, warn, err)
		}
		exec(`SET ROLE pgv_jit_probe`)
		info, warn, err := repositoryJITOff(ctx, plain)
		exec(`RESET ROLE`)
		if err != nil || info != "" || warn != "" {
			t.Errorf("an entry jit = %s, a non-owner's run: info %q, warn %q, err %v; want nothing", v, info, warn, err)
		}
		if e := entry(); e != v {
			t.Errorf("an entry jit = %s reads %s after the runs; want it kept", v, e)
		}
	}

	// an owner that is not a superuser (a member of the database's owner role, as a hosted provider's admin login is)
	var owner string
	if err := plain.QueryRow(ctx, `SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()`).Scan(&owner); err != nil {
		t.Fatal(err)
	}
	// A superuser login SETs ROLE to any role without a grant; a login that IS the owner cannot be granted a member
	// of itself (0LP01, a circular membership) - and is then itself the non-superuser owner the Migrate above ran as.
	var super, isOwner bool
	if err := plain.QueryRow(ctx, `SELECT r.rolsuper, d.datdba = r.oid FROM pg_roles r, pg_database d
         WHERE r.rolname = current_user AND d.datname = current_database()`).Scan(&super, &isOwner); err != nil {
		t.Fatal(err)
	}
	if !super && isOwner {
		t.Logf("an owner that is not a superuser: this login (%s) is one; the Migrate above ran that path", owner)
	} else {
		exec(`DROP ROLE IF EXISTS pgv_jit_owner`, `CREATE ROLE pgv_jit_owner NOLOGIN NOSUPERUSER IN ROLE `+pgx.Identifier{owner}.Sanitize())
		if !super {
			exec(`GRANT pgv_jit_owner TO CURRENT_USER`)
		}
		exec("ALTER DATABASE "+qdb+" RESET jit", `SET ROLE pgv_jit_owner`)
		info, warn, err = repositoryJITOff(ctx, plain)
		exec(`RESET ROLE`)
		if err != nil || warn != "" || !strings.Contains(info, "jit set off") {
			t.Errorf("an owner that is not a superuser (a member of %s): info %q, warn %q, err %v; want the 'jit set off' info alone", owner, info, warn, err)
		}
		if !isOff() {
			t.Errorf("an owner that is not a superuser did not write jit=off (the entry reads %s)", entry())
		}
	}

	// Migrate's own log: the write is one info line, the next migrate says nothing about jit
	exec("ALTER DATABASE " + qdb + " RESET jit")
	var buf bytes.Buffer
	r2, err := Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r2.Close()
	r2.SetLog(slog.New(slog.NewTextHandler(&buf, nil)))
	for n := 1; n <= 2; n++ {
		buf.Reset()
		if _, err := r2.Migrate(ctx); err != nil {
			t.Fatalf("migrate %d: %v", n, err)
		}
		lines := []string{}
		for _, l := range strings.Split(buf.String(), "\n") {
			if strings.Contains(strings.ToLower(l), "jit") {
				lines = append(lines, l)
			}
		}
		want := 0
		if n == 1 {
			want = 1
		}
		if len(lines) != want || (n == 1 && (!strings.Contains(lines[0], "level=INFO") || !strings.Contains(lines[0], "jit set off"))) {
			t.Errorf("migrate %d logged %d jit line(s) %q; want %d (the first an INFO 'jit set off')", n, len(lines), lines, want)
		}
	}
	if !isOff() {
		t.Error("Migrate did not write jit=off back")
	}
}

// TestPgBool: a setting's boolean read as PostgreSQL's parse_bool reads it.
func TestPgBool(t *testing.T) {
	for in, want := range map[string][2]bool{
		"on": {true, true}, "ON": {true, true}, "off": {false, true}, "OFF": {false, true}, "of": {false, true},
		"true": {true, true}, "t": {true, true}, "TRU": {true, true}, "false": {false, true}, "f": {false, true}, "fa": {false, true},
		"yes": {true, true}, "y": {true, true}, "no": {false, true}, "n": {false, true}, "1": {true, true}, "0": {false, true},
		"o": {false, false}, "": {false, false}, "2": {false, false}, "onn": {false, false}, "offf": {false, false}, "nope": {false, false},
	} {
		if v, ok := pgBool(in); v != want[0] || ok != want[1] {
			t.Errorf("pgBool(%q) = %v, %v; want %v, %v", in, v, ok, want[0], want[1])
		}
	}
	// the space around a value is not part of it (PostgreSQL trims it)
	if v, ok := pgBool("\t on \n"); !v || !ok {
		t.Errorf("pgBool with space around on = %v, %v; want true, true", v, ok)
	}
}
