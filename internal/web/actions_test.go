package web

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

func discardLog() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// The door's refusals that need no database: off, no header, the -no-login server.
func TestActionsOff(t *testing.T) {
	s := &Server{log: discardLog()}
	a, err := s.NewActions(context.Background(), &ActionsConfig{LogDSN: "host=x"})
	if err != nil || !strings.Contains(a.off, "-no-login") {
		t.Fatalf("a -no-login server: off=%q err=%v", a.off, err)
	}
	a2, _ := s.NewActions(context.Background(), nil)
	for _, c := range []struct {
		a      *Actions
		header bool
		code   int
		want   string
	}{
		{nil, true, 403, "actions are off"},
		{a2, false, 403, "X-Pgvigil header"},
		{a2, true, 403, "no actions configuration"},
		{a, true, 403, "-no-login"},
	} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/actions/cancel", strings.NewReader(`{}`))
		if c.header {
			req.Header.Set(loginHeader, "1")
		}
		c.a.Cancel(rec, req)
		if rec.Code != c.code || !strings.Contains(rec.Body.String(), c.want) {
			t.Errorf("got %d %q, want %d with %q", rec.Code, rec.Body.String(), c.code, c.want)
		}
	}
}

func TestActionsValidateAndRow(t *testing.T) {
	ok := actions.Request{Kind: actions.Cancel, PID: 7, BackendStart: time.Now(), Reason: "runaway report", User: "u"}
	if err := actions.Validate(ok); err != nil {
		t.Fatalf("a good request: %v", err)
	}
	for name, mut := range map[string]func(*actions.Request){
		"kind":   func(r *actions.Request) { r.Kind = "kill" },
		"pid":    func(r *actions.Request) { r.PID = 0 },
		"start":  func(r *actions.Request) { r.BackendStart = time.Time{} },
		"short":  func(r *actions.Request) { r.Reason = " ab " },
		"long":   func(r *actions.Request) { r.Reason = strings.Repeat("x", actions.MaxReason+1) },
		"nouser": func(r *actions.Request) { r.User = "" },
	} {
		r := ok
		mut(&r)
		if actions.Validate(r) == nil {
			t.Errorf("%s: accepted", name)
		}
		if res := actions.Execute(context.Background(), actions.Door{Monitor: "x", Actions: "y"}, r); res.Outcome != actions.Refused {
			t.Errorf("%s: Execute did not refuse: %+v", name, res)
		}
	}
	if res := actions.Execute(context.Background(), actions.Door{Monitor: "x"}, ok); res.Outcome != actions.Refused || !strings.Contains(res.Detail, "no actions_dsn") {
		t.Errorf("no door: %+v", res)
	}
	row := actions.Row(time.Now(), actions.Request{Kind: actions.Terminate, Reason: "  "}, actions.Result{Outcome: actions.Refused})
	if row.Reason != "(no reason given)" || row.BackendStart != nil {
		t.Errorf("an empty reason / zero start: %+v", row)
	}
	row = actions.Row(time.Now(), actions.Request{Reason: strings.Repeat("é", 600)}, actions.Result{})
	if len([]rune(row.Reason)) != actions.MaxReason {
		t.Errorf("a long reason kept %d runes", len([]rune(row.Reason)))
	}
}

// TestActionsProof is the handler half of scripts/proof-actions.sh; it runs only from there.
func TestActionsProof(t *testing.T) {
	if os.Getenv("PGVIGIL_ACTIONS_PROOF") == "" {
		t.Skip("run by scripts/proof-actions.sh")
	}
	ctx := context.Background()
	repoDSN, mon, act, app := os.Getenv("PGVIGIL_REPO_DSN"), os.Getenv("ACTIONS_MONITOR_DSN"), os.Getenv("ACTIONS_ACTIONS_DSN"), os.Getenv("ACTIONS_APP_DSN")
	inst, nodoor := os.Getenv("ACTIONS_INSTANCE"), os.Getenv("ACTIONS_INSTANCE_NODOOR")
	pool, err := pgxpool.New(ctx, repoDSN)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := &Server{pool: pool, log: discardLog()}
	s.auth = newAuth(func(context.Context, string) (string, error) { return "h", nil }, false, time.Hour)
	tok, err := s.auth.issue("proof-user", "h")
	if err != nil {
		t.Fatal(err)
	}
	a, err := s.NewActions(ctx, &ActionsConfig{LogDSN: os.Getenv("ACTIONS_AUDIT_DSN"), Doors: map[string]actions.Door{
		inst: {Monitor: mon, Actions: act}, nodoor: {Monitor: mon}}})
	if err != nil {
		t.Fatalf("NewActions: %v", err)
	}
	defer a.Close()
	id := func(name string) int {
		var n int
		if err := pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, name).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	iid, nid := id(inst), id(nodoor)

	// a sleeper: a connection running pg_sleep; its pid, its backend_start and the error its sleep ends with
	type sleeper struct {
		conn *pgx.Conn
		pid  int
		bs   time.Time
		done chan error
	}
	sleep := func(dsn string) *sleeper {
		c, err := pgx.Connect(ctx, dsn)
		if err != nil {
			t.Fatal(err)
		}
		sl := &sleeper{conn: c, done: make(chan error, 1)}
		if err := c.QueryRow(ctx, `SELECT pg_backend_pid(), backend_start FROM pg_stat_activity WHERE pid = pg_backend_pid()`).Scan(&sl.pid, &sl.bs); err != nil {
			t.Fatal(err)
		}
		go func() { _, err := c.Exec(ctx, `SELECT pg_sleep(60)`); sl.done <- err }()
		for i := 0; i < 50; i++ { // wait until the sleep is the session's statement
			var st string
			_ = pool.QueryRow(ctx, `SELECT coalesce(state, '') FROM pg_stat_activity WHERE pid = $1`, sl.pid).Scan(&st)
			if st == "active" {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		return sl
	}
	post := func(h http.HandlerFunc, header bool, body map[string]any) (int, map[string]string) {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/actions/x", bytes.NewReader(b))
		req.AddCookie(&http.Cookie{Name: sessionCookie, Value: tok})
		if header {
			req.Header.Set(loginHeader, "1")
		}
		rec := httptest.NewRecorder()
		h(rec, req)
		var out map[string]string
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	body := func(instance int, sl *sleeper, bs time.Time, confirm string) map[string]any {
		return map[string]any{"instance_id": instance, "pid": sl.pid, "backend_start": bs.Format(time.RFC3339Nano),
			"reason": "proof: a runaway sleep", "confirm": confirm}
	}
	sqlState := func(err error) string {
		var pg *pgconn.PgError
		if errors.As(err, &pg) {
			return pg.Code
		}
		if err != nil {
			return err.Error()
		}
		return "no error"
	}
	logCount := func() int {
		var n int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.actions_log WHERE instance_name IN ($1, $2)`, inst, nodoor).Scan(&n)
		return n
	}

	// no header: 403, nothing logged
	a1 := sleep(app)
	defer func() { _ = a1.conn.Close(ctx) }()
	if code, out := post(a.Cancel, false, body(iid, a1, a1.bs, strconv.Itoa(a1.pid))); code != 403 || logCount() != 0 {
		t.Fatalf("no header: %d %v, %d rows logged", code, out, logCount())
	}
	t.Log("ok: a POST without the X-Pgvigil header is 403 and not logged")

	// cancel: the sleep ends with 57014, the session stays
	if code, out := post(a.Cancel, true, body(iid, a1, a1.bs, strconv.Itoa(a1.pid))); code != 200 || out["outcome"] != "done" {
		t.Fatalf("cancel: %d %v", code, out)
	}
	if st := sqlState(<-a1.done); st != "57014" {
		t.Fatalf("the cancelled sleep ended with %s, want 57014", st)
	}
	if err := a1.conn.Ping(ctx); err != nil {
		t.Fatalf("the cancelled session is gone: %v", err)
	}
	t.Log("ok: cancel ended the sleep (57014) and the session stayed")

	// terminate: the connection ends 57P01
	b1 := sleep(app)
	defer func() { _ = b1.conn.Close(ctx) }()
	if code, out := post(a.Terminate, true, body(iid, b1, b1.bs, strconv.Itoa(b1.pid))); code != 200 || out["outcome"] != "done" {
		t.Fatalf("terminate: %d %v", code, out)
	}
	if st := sqlState(<-b1.done); st != "57P01" {
		t.Fatalf("the terminated sleep ended with %s, want 57P01", st)
	}
	t.Log("ok: terminate ended the session (57P01)")

	// the superuser's session: refused, still sleeping
	su := sleep(repoDSN)
	defer func() { _ = su.conn.Close(ctx) }()
	if code, out := post(a.Terminate, true, body(iid, su, su.bs, strconv.Itoa(su.pid))); code != 409 || !strings.Contains(out["detail"], "superuser") {
		t.Fatalf("superuser: %d %v", code, out)
	}
	t.Log("ok: the superuser's session is refused")

	// a stale pid: the row shown started a microsecond apart from the live backend
	c1 := sleep(app)
	defer func() { _ = c1.conn.Close(ctx) }()
	if code, out := post(a.Cancel, true, body(iid, c1, c1.bs.Add(time.Microsecond), strconv.Itoa(c1.pid))); code != 409 || !strings.Contains(out["detail"], "reused") {
		t.Fatalf("stale pid: %d %v", code, out)
	}
	t.Log("ok: a stale pid (backend_start apart) is refused")

	// a confirmation that is not the pid
	if code, out := post(a.Cancel, true, body(iid, c1, c1.bs, "yes")); code != 409 || !strings.Contains(out["detail"], "confirmation") {
		t.Fatalf("wrong confirmation: %d %v", code, out)
	}
	t.Log("ok: a typed confirmation that is not the pid is refused")

	// an instance without actions_dsn
	if code, out := post(a.Cancel, true, body(nid, c1, c1.bs, strconv.Itoa(c1.pid))); code != 409 || !strings.Contains(out["detail"], "no actions_dsn") {
		t.Fatalf("no door: %d %v", code, out)
	}
	t.Log("ok: an instance without actions_dsn is refused")

	// the stale, refused and wrong-confirmation targets were never signalled
	for _, sl := range []*sleeper{su, c1} {
		select {
		case err := <-sl.done:
			t.Fatalf("pid %d was signalled: %v", sl.pid, err)
		default:
		}
		_ = sl.conn.PgConn().CancelRequest(ctx)
		if err := <-sl.done; err == nil {
			t.Fatalf("pid %d: the clean-up cancel did not end its sleep", sl.pid)
		}
	}

	// the log view
	logOf := func(instance int) (bool, string, []string, int) {
		req := httptest.NewRequest(http.MethodGet, "/api/actions/log?instance="+strconv.Itoa(instance), nil)
		rec := httptest.NewRecorder()
		a.Log(rec, req)
		var out struct {
			Enabled    bool     `json:"enabled"`
			Reason     string   `json:"reason"`
			Superusers []string `json:"superusers"`
			Log        table    `json:"log"`
		}
		if rec.Code != 200 {
			t.Fatalf("log %d: %d %s", instance, rec.Code, rec.Body.String())
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return out.Enabled, out.Reason, out.Superusers, len(out.Log.Rows)
	}
	on, _, sus, n := logOf(iid)
	var me string
	_ = pool.QueryRow(ctx, `SELECT current_user`).Scan(&me)
	if !on || !contains(sus, me) || n != 5 {
		t.Fatalf("log of the door instance: enabled=%v superusers=%v rows=%d (want true, %s listed, 5)", on, sus, n, me)
	}
	on, why, _, n := logOf(nid)
	if on || !strings.Contains(why, "no actions_dsn") || n != 1 {
		t.Fatalf("log of the other instance: enabled=%v reason=%q rows=%d", on, why, n)
	}
	t.Log("ok: the log view: enabled with the superusers listed, and disabled with the reason")
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
