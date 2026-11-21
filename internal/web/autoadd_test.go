package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// l237Store opens the test store (skipped without PGVIGIL_REPO_TEST_DSN) and a name suffix.
func l237Store(t *testing.T) (context.Context, *pgxpool.Pool, string, int64) {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return ctx, pool, dsn, time.Now().UnixNano() % 1000000000
}

func l237Source(ctx context.Context, t *testing.T, pool *pgxpool.Pool, payload map[string]any) (string, string) {
	t.Helper()
	b, _ := json.Marshal(payload)
	var o, d string
	if err := pool.QueryRow(ctx, `SELECT r->>'outcome', coalesce(r->>'detail', '') FROM pgvigil.import_admin_source(now(), $1::jsonb) AS t(r)`, string(b)).Scan(&o, &d); err != nil {
		t.Fatalf("import_admin_source %v: %v", payload, err)
	}
	return o, d
}

// l237LastEdit is the detail of the newest 'source edit' audit row of source.
func l237LastEdit(ctx context.Context, t *testing.T, pool *pgxpool.Pool, source string) string {
	t.Helper()
	var d string
	_ = pool.QueryRow(ctx, `SELECT coalesce(detail, '') FROM pgvigil.admin_audit WHERE op = 'source edit' AND target = $1 ORDER BY at DESC, ctid DESC LIMIT 1`, source).Scan(&d)
	return d
}

// TestSourceAutoAddSwitchL237: the source's switch 'add the servers it finds by
// itself' is off on a new source; turning it on is refused unless the file's door doors.discovery_auto_add is open
// (serve passes it), and on a source that is not a cloud one in its own words, whatever the door; a switch that is on
// may be turned off, and left on, with the door shut; the audit names the switch only when it changes; off clears the
// source's auto notes and its Tests' counts.
func TestSourceAutoAddSwitchL237(t *testing.T) {
	ctx, pool, _, sfx := l237Store(t)
	cloud, list, plain := fmt.Sprintf("l237-gcp-%d", sfx), fmt.Sprintf("l237-list-%d", sfx), fmt.Sprintf("l237-plain-%d", sfx)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_sources WHERE name = ANY($1)`, []string{cloud, list, plain})
	})
	add := func(name, kind string, extra map[string]any) (string, string) {
		p := map[string]any{"op": "add", "ui_user": "l237", "name": name, "kind": kind, "ref": "file:/x/" + name + ".json", "credential_ref": "file:/x/" + name + ".cred", "every_s": "3600"}
		for k, v := range extra {
			p[k] = v
		}
		return l237Source(ctx, t, pool, p)
	}
	edit := func(name string, extra map[string]any) (string, string) {
		p := map[string]any{"op": "edit", "ui_user": "l237", "name": name}
		for k, v := range extra {
			p[k] = v
		}
		return l237Source(ctx, t, pool, p)
	}
	if o, d := add(cloud, "gcp", map[string]any{"auto_add": true}); o != "refused" || !strings.Contains(d, "doors.discovery_auto_add") {
		t.Errorf("the switch on with the door shut: %s %q, want refused naming doors.discovery_auto_add", o, d)
	}
	if o, d := add(cloud, "gcp", map[string]any{"auto_add": true, "auto_add_door": true}); o != "done" {
		t.Fatalf("the switch on with the door open: %s %q", o, d)
	}
	var on bool
	if err := pool.QueryRow(ctx, `SELECT auto_add FROM pgvigil.admin_sources WHERE name = $1`, cloud).Scan(&on); err != nil || !on {
		t.Errorf("auto_add after the add: %v %v", on, err)
	}
	var audits int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'source add' AND target = $1 AND outcome = 'done' AND detail LIKE '%adds what it finds by itself%'`, cloud).Scan(&audits)
	if audits != 1 {
		t.Errorf("the add's audit row names the switch: %d rows", audits)
	}
	// the kind is judged before the door: a list source hears it is not a cloud source, door shut or open
	for _, door := range []bool{false, true} {
		if o, d := add(list, "sqlserver_list", map[string]any{"auto_add": true, "auto_add_door": door, "ref": "/etc/pgvigil/servers.csv"}); o != "refused" || !strings.Contains(d, "only a cloud source") {
			t.Errorf("a list source with the switch (door %v): %s %q, want refused 'only a cloud source'", door, o, d)
		}
	}
	if o, d := add(plain, "gcp", nil); o != "done" {
		t.Fatalf("a source without the key: %s %q", o, d)
	}
	_ = pool.QueryRow(ctx, `SELECT auto_add FROM pgvigil.admin_sources WHERE name = $1`, plain).Scan(&on)
	if on {
		t.Error("a new source's switch is off by default")
	}
	// a save that leaves the switch as it is names no switch (off left off; on left on with the door shut)
	if o, d := edit(plain, map[string]any{"auto_add": false, "tag_keys": []string{"env"}}); o != "done" || strings.Contains(l237LastEdit(ctx, t, pool, plain), "adds what it finds") {
		t.Errorf("an edit leaving the switch off: %s %q, audit %q - want done naming no switch", o, d, l237LastEdit(ctx, t, pool, plain))
	}
	if o, d := edit(cloud, map[string]any{"auto_add": true}); o != "done" || strings.Contains(l237LastEdit(ctx, t, pool, cloud), "adds what it finds") {
		t.Errorf("an edit leaving the switch on, the door shut: %s %q, audit %q - want done naming no switch", o, d, l237LastEdit(ctx, t, pool, cloud))
	}
	var id int64
	if err := pool.QueryRow(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, auto_note, auto_fails, auto_tested_at)
	                               VALUES ($1, 'gcp:l237:sql:n1', 'postgres', 'h', 'needs a person: x', 2, now()) RETURNING proposal_id`, cloud).Scan(&id); err != nil {
		t.Fatal(err)
	}
	// turned off with the door shut (the page's checkbox is live while it is ticked)
	if o, d := edit(cloud, map[string]any{"auto_add": false}); o != "done" || !strings.Contains(l237LastEdit(ctx, t, pool, cloud), "no longer adds what it finds") {
		t.Fatalf("the switch off, the door shut: %s %q, audit %q", o, d, l237LastEdit(ctx, t, pool, cloud))
	}
	var note *string
	var fails int
	var tested *time.Time
	_ = pool.QueryRow(ctx, `SELECT auto_add FROM pgvigil.admin_sources WHERE name = $1`, cloud).Scan(&on)
	_ = pool.QueryRow(ctx, `SELECT auto_note, auto_fails, auto_tested_at FROM pgvigil.admin_proposals WHERE proposal_id = $1`, id).Scan(&note, &fails, &tested)
	if on || note != nil || fails != 0 || tested != nil {
		t.Errorf("after the switch off: auto_add %v, the proposal's note %v, fails %d, tested %v (want off, none, 0, none)", on, note, fails, tested)
	}
}

// TestAutoAddGateL237: the auto step runs only for a cloud source with its switch on and the file's door open; its
// bounds; a failed Test's next try an hour on, doubling to a day.
func TestAutoAddGateL237(t *testing.T) {
	defer config.SetPageCloud(config.Doors{})
	config.SetPageCloud(config.Doors{DiscoveryAutoAdd: true})
	for _, c := range []struct {
		src  sourceRow
		door bool
		want bool
	}{
		{sourceRow{Kind: "gcp", AutoAdd: true}, true, true},
		{sourceRow{Kind: "azure", AutoAdd: true}, true, true},
		{sourceRow{Kind: "aws", AutoAdd: true}, true, true},
		{sourceRow{Kind: "gcp", AutoAdd: false}, true, false},
		{sourceRow{Kind: "gcp", AutoAdd: true}, false, false},
		{sourceRow{Kind: "sqlserver_list", AutoAdd: true}, true, false},
	} {
		config.SetPageCloud(config.Doors{DiscoveryAutoAdd: c.door})
		if got := autoAddOn(&c.src); got != c.want {
			t.Errorf("%+v door %v: %v, want %v", c.src, c.door, got, c.want)
		}
	}
	config.SetPageCloud(config.Doors{DiscoveryAutoAdd: false})
	if w := (&Server{}).startAutoAdd(context.Background(), &sourceRow{Kind: "gcp", AutoAdd: true}, true); w != nil {
		t.Errorf("startAutoAdd with the door shut: %v, want nothing started", w)
	}
	if autoAddLimit != 25 || autoAddTests != 50 {
		t.Errorf("25 adds and 50 Tests a read: %d, %d", autoAddLimit, autoAddTests)
	}
	t0 := time.Date(2026, 11, 20, 3, 0, 0, 0, time.UTC)
	for fails, want := range map[int]time.Duration{1: 55 * time.Minute, 2: 115 * time.Minute, 5: 16*time.Hour - 5*time.Minute, 6: 24*time.Hour - 5*time.Minute, 40: 24*time.Hour - 5*time.Minute} {
		if got := autoRetry(t0, fails).Sub(t0); got != want {
			t.Errorf("the next try after %d failures: %v, want %v", fails, got, want)
		}
	}
}

// TestProposalNameL237: with no name typed the instance's name is the page's rule - the display
// name without its role, made safe, 63 characters at most - and two servers whose names meet once cut (two databases
// of one Azure SQL server named by their keys), or a name taken, get a short hash of the server: two names, each safe.
func TestProposalNameL237(t *testing.T) {
	safe := regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$`)
	for _, c := range []struct{ display, server, want string }{
		{"sql-orders-prod-eus2/db1", "azure:00000000-1111-2222-3333-444444444444:sql:sql-orders-prod-eus2/db1", "sql-orders-prod-eus2-db1"},
		{"aurora-x-cluster-instance-1 (writer)", "aws:123456789012:us-east-2:rds:aurora-x-cluster-instance-1", "aurora-x-cluster-instance-1"},
		{"", "sql01\\PROD,1433", "sql01-PROD-1433"},
	} {
		if got, cut := proposalName(c.display, c.server); got != c.want || cut {
			t.Errorf("proposalName(%q, %q) = %q cut %v, want %q", c.display, c.server, got, cut, c.want)
		}
	}
	none := func(string) bool { return false }
	k1 := "azure:00000000-1111-2222-3333-444444444444:sql:sql-orders-prod-eus2/orders"
	k2 := "azure:00000000-1111-2222-3333-444444444444:sql:sql-orders-prod-eus2/billing"
	b1, cut1 := proposalName("", k1)
	b2, cut2 := proposalName("", k2)
	if b1 != b2 || !cut1 || !cut2 {
		t.Fatalf("the two keys' cut names: %q %v, %q %v (want the same, both cut: the case this row is about)", b1, cut1, b2, cut2)
	}
	n1, n2 := uniqueName(b1, cut1, k1, none), uniqueName(b2, cut2, k2, none)
	if n1 == n2 || !safe.MatchString(n1) || !safe.MatchString(n2) {
		t.Errorf("two servers met on one name once cut: %q, %q", n1, n2)
	}
	if got := uniqueName("srv1-app", false, "gcp:p:sql:srv1-app", none); got != "srv1-app" {
		t.Errorf("a free uncut name: %q", got)
	}
	taken := func(n string) bool { return n == "srv1-app" }
	if got := uniqueName("srv1-app", false, "gcp:p:sql:srv1-app", taken); got == "srv1-app" || !strings.HasPrefix(got, "srv1-app-") || !safe.MatchString(got) {
		t.Errorf("a taken name: %q, want srv1-app-<hash>", got)
	}
}

// TestAutoLoginHeldL237: a proposal whose login has no name is left to a person - it would sign in
// as serve's own account - except a SQL Server sign-in by the host's identity.
func TestAutoLoginHeldL237(t *testing.T) {
	for _, c := range []struct {
		auth, login string
		held        bool
	}{
		{"pgpass", "", true}, {"password", "", true}, {"sql", "", true}, {"entra", "", true},
		{"pgpass", "pgvigil_ro", false}, {"sql", "pgv", false}, {"windows", "", false}, {"entra-identity", "", false},
	} {
		if got := autoLoginHeld(c.auth, c.login); (got != "") != c.held {
			t.Errorf("auth %q login %q: %q, want held %v", c.auth, c.login, got, c.held)
		}
	}
}

// l237Rig is a cloud source on the test store whose servers are the store itself, a serve with its audit login as the
// collector, and the helpers the store rows read with.
type l237Rig struct {
	ctx    context.Context
	pool   *pgxpool.Pool
	s      *Server
	src    string
	host   string
	alt    string // another name of the store's host ('' when it has none here)
	port   int
	db     string
	closed int
	sfx    int64
	sr     *sourceRow
}

func newL237Rig(t *testing.T, withLogin bool) *l237Rig {
	t.Helper()
	ctx, pool, dsn, sfx := l237Store(t)
	pc, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	r := &l237Rig{ctx: ctx, pool: pool, host: pc.Host, port: int(pc.Port), db: pc.Database, sfx: sfx}
	r.alt = map[string]string{"127.0.0.1": "localhost", "localhost": "127.0.0.1"}[pc.Host]
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "pgvigil.yaml")
	if err := os.WriteFile(cfgPath, []byte("repository:\n  dsn: env:X\ninstances: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cred := map[string]string{"password": pc.Password, "extra": "sslmode=disable"}
	if withLogin {
		cred["login"] = pc.User
	}
	credFile := filepath.Join(dir, "cred.json")
	b, _ := json.Marshal(cred)
	if err := os.WriteFile(credFile, b, 0o600); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	r.closed = ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	r.src = fmt.Sprintf("l237-auto-%d", sfx)
	t.Cleanup(func() {
		bg := context.Background()
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_instances WHERE name IN (SELECT instance_name FROM pgvigil.admin_proposals WHERE source = $1 AND instance_name IS NOT NULL)`, r.src)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_proposals WHERE source = $1`, r.src)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_sources WHERE name = $1`, r.src)
	})
	auth := "password"
	if pc.Password == "" {
		auth = "pgpass" // a store on trust: the source's login alone, no password (the page's own '.pgpass' form)
	}
	if o, d := l237Source(ctx, t, pool, map[string]any{"op": "add", "ui_user": "l237", "name": r.src, "kind": "gcp", "ref": "file:/x/gcp.json",
		"credential_ref": "file:" + credFile, "auth": auth, "every_s": "3600", "auto_add": true, "auto_add_door": true}); o != "done" {
		t.Fatalf("the source: %s %q", o, d)
	}
	config.SetPageCloud(config.Doors{DiscoveryAutoAdd: true})
	t.Cleanup(func() { config.SetPageCloud(config.Doors{}) })
	r.s = &Server{pool: pool, log: discardLog(), actions: &Actions{audit: collectorPool(ctx, t, pool, dsn, sfx)}}
	r.s.SetInstancesAdmin(InstancesAdmin{ConfigPath: cfgPath})
	t.Cleanup(func() { instancesAdmins.Delete(r.s.self()) })
	if r.sr, err = r.s.sourceByName(ctx, r.src); err != nil || !r.sr.AutoAdd {
		t.Fatalf("the source row: %+v %v", r.sr, err)
	}
	return r
}

// ins adds a proposal of the rig's source (its server key, host, port; set: more columns as SQL).
func (r *l237Rig) ins(t *testing.T, server, host string, port int, set string) int64 {
	t.Helper()
	var id int64
	if err := r.pool.QueryRow(r.ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, port, dbname, platform)
	                                   VALUES ($1, $2, 'postgres', $3, $4, $5, 'cloudsql') RETURNING proposal_id`, r.src, server, host, port, r.db).Scan(&id); err != nil {
		t.Fatalf("proposal %s: %v", server, err)
	}
	r.set(t, id, set)
	return id
}

func (r *l237Rig) set(t *testing.T, id int64, set string) {
	t.Helper()
	if set == "" {
		return
	}
	if _, err := r.pool.Exec(r.ctx, `UPDATE pgvigil.admin_proposals SET `+set+` WHERE proposal_id = $1`, id); err != nil {
		t.Fatal(err)
	}
}

type l237Row struct {
	state, by, inst, server string
	note                    *string
	fails                   int
}

func (r *l237Rig) read(t *testing.T, id int64) l237Row {
	t.Helper()
	var x l237Row
	var by, inst *string
	if err := r.pool.QueryRow(r.ctx, `SELECT state, decided_by, instance_name, auto_note, auto_fails, server FROM pgvigil.admin_proposals WHERE proposal_id = $1`, id).
		Scan(&x.state, &by, &inst, &x.note, &x.fails, &x.server); err != nil {
		t.Fatal(err)
	}
	if by != nil {
		x.by = *by
	}
	if inst != nil {
		x.inst = *inst
	}
	return x
}

func (x l237Row) noteHas(w string) bool { return x.note != nil && strings.Contains(*x.note, w) }

// tests counts the 'proposal test' audit rows of a proposal's server by the step.
func (r *l237Rig) tests(t *testing.T, server string) int {
	t.Helper()
	var n int
	_ = r.pool.QueryRow(r.ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'proposal test' AND ui_user = $1 AND target = $2`, "auto:"+r.src, r.src+"/"+server).Scan(&n)
	return n
}

// TestAutoAddL237 (RELNOTES L237 (2)-(5)): a cloud source with its switch on adds a
// proposal the page's Test reaches, through the page's own approve as auto:<source>, named by the page's rule; a
// proposal the approve would ask a person to tick (a pausing server) is left 'needs a person: <the approve's words>'
// with NO Test - nothing connects to it; a failed Test is left with its words and not tested again within its wait;
// a gone or ignored proposal is not touched; the switch turned off between a Test and its approve stops the step, the
// approve not made, every note cleared; past the bounds (adds, Tests), 'waits for the next read'; one 'source read'
// audit row a step. The servers are this test's own store (its host, and its other name when it has one).
func TestAutoAddL237(t *testing.T) {
	r := newL237Rig(t, true)
	t.Cleanup(func() { autoAddPause = nil })
	pAdd := r.ins(t, fmt.Sprintf("gcp:l237:sql:add%d", r.sfx), r.host, r.port, fmt.Sprintf("display_name = 'l237-add-%d (writer)'", r.sfx))
	pPause := r.ins(t, fmt.Sprintf("gcp:l237:sql:pause%d", r.sfx), r.host, r.port, "auto_pause = true, serverless = 'the server pauses when idle (this test)'")
	pDown := r.ins(t, fmt.Sprintf("gcp:l237:sql:down%d", r.sfx), "127.0.0.1", r.closed, "")
	pGone := r.ins(t, fmt.Sprintf("gcp:l237:sql:gone%d", r.sfx), "127.0.0.1", r.closed, "gone = true")
	pIgn := r.ins(t, fmt.Sprintf("gcp:l237:sql:ign%d", r.sfx), "127.0.0.1", r.closed, "state = 'ignored'")

	res := r.s.autoAdd(r.ctx, r.sr)
	t.Logf("step 1: %v", res)
	if x := r.read(t, pAdd); x.state != "approved" || x.by != "auto:"+r.src || x.inst != fmt.Sprintf("l237-add-%d", r.sfx) || x.note != nil {
		t.Errorf("the reachable proposal: %+v, want approved by auto:%s as l237-add-%d (the page's name rule) with no note", x, r.src, r.sfx)
	} else {
		var n int
		_ = r.pool.QueryRow(r.ctx, `SELECT count(*) FROM pgvigil.admin_instances WHERE name = $1`, x.inst).Scan(&n)
		if n != 1 {
			t.Errorf("its instance %s: %d rows", x.inst, n)
		}
	}
	xp := r.read(t, pPause)
	if xp.state != "proposed" || !xp.noteHas("needs a person: ") || !xp.noteHas("paus") {
		t.Errorf("the pausing proposal: %+v, want proposed with 'needs a person: ...pauses...'", xp)
	}
	if n := r.tests(t, xp.server); n != 0 {
		t.Errorf("the pausing proposal was tested %d time(s): a Test connects to it (it would never pause)", n)
	}
	xd := r.read(t, pDown)
	if xd.state != "proposed" || !xd.noteHas("the test failed: ") || xd.fails != 1 {
		t.Errorf("the unreachable proposal: %+v, want proposed with 'the test failed: ...' and one failure counted", xd)
	}
	for _, id := range []int64{pGone, pIgn} {
		if x := r.read(t, id); x.note != nil || x.state == "approved" {
			t.Errorf("a gone or ignored proposal is not touched: %+v", x)
		}
	}
	var audits int
	_ = r.pool.QueryRow(r.ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'source read' AND target = $1 AND ui_user = $2 AND outcome = 'done' AND detail LIKE 'added 1 by itself%'`, r.src, "auto:"+r.src).Scan(&audits)
	if audits != 1 || r.tests(t, r.read(t, pAdd).server) != 1 || r.tests(t, xd.server) != 1 {
		t.Errorf("the audit: %d 'source read' rows 'added 1 by itself' (want 1); Tests: the reachable %d, the unreachable %d (want 1 each)", audits, r.tests(t, r.read(t, pAdd).server), r.tests(t, xd.server))
	}

	// the switch turned off between a Test and its approve: nothing more is added, the notes and counts cleared
	if r.alt == "" {
		t.Logf("the store's host %q has no second name here: the rows after step 1 need one (NOT RUN)", r.host)
		return
	}
	r.set(t, pPause, fmt.Sprintf("auto_pause = false, serverless = NULL, host = '%s'", r.alt))
	autoAddPause = func(int64) {
		autoAddPause = nil
		if o, d := l237Source(r.ctx, t, r.pool, map[string]any{"op": "edit", "ui_user": "l237", "name": r.src, "auto_add": false}); o != "done" {
			t.Errorf("the switch off mid-step: %s %q", o, d)
		}
	}
	res = r.s.autoAdd(r.ctx, r.sr)
	t.Logf("step 2 (the switch off mid-step): %v", res)
	if x := r.read(t, pPause); x.state != "proposed" || x.note != nil {
		t.Errorf("after the switch off between its Test and its approve: %+v, want proposed with no note", x)
	}
	if x := r.read(t, pDown); x.note != nil || x.fails != 0 {
		t.Errorf("another proposal after the switch off: %+v, want no note and no count", x)
	}
	var refused int
	_ = r.pool.QueryRow(r.ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'source read' AND target = $1 AND ui_user = $2 AND outcome = 'refused' AND detail LIKE '%no longer adds%stopped: the source''s switch is off%'`, r.src, "auto:"+r.src).Scan(&refused)
	if res["stopped"] == nil || refused != 1 {
		t.Errorf("the stopped step: %v, %d refused 'source read' rows naming the stop (want 1)", res["stopped"], refused)
	}
	if o, d := l237Source(r.ctx, t, r.pool, map[string]any{"op": "edit", "ui_user": "l237", "name": r.src, "auto_add": true, "auto_add_door": true}); o != "done" {
		t.Fatalf("the switch on again: %s %q", o, d)
	}

	// a failed Test waits before its next try: step 3 tests it again (its count was cleared), step 4 does not
	_ = r.s.autoAdd(r.ctx, r.sr)
	if x := r.read(t, pPause); x.state != "approved" {
		t.Errorf("step 3: the proposal on the store's other name: %+v, want approved", x)
	}
	_ = r.s.autoAdd(r.ctx, r.sr)
	if x := r.read(t, pDown); r.tests(t, x.server) != 2 || !x.noteHas("the test failed") || x.fails != 1 {
		t.Errorf("step 4: the unreachable proposal %+v tested %d time(s) in all (want 2: steps 1 and 3, not 4), its note kept, one failure in a row", x, r.tests(t, x.server))
	}

	// the bounds: no add left, then no Test left - each proposal waits, untested
	pMore := r.ins(t, fmt.Sprintf("gcp:l237:sql:more%d", r.sfx), "127.0.0.1", r.closed+1, "")
	for _, b := range []struct {
		name        string
		limit, test int
	}{{"adds", 0, 50}, {"Tests", 25, 0}} {
		autoAddLimit, autoAddTests = b.limit, b.test
		_ = r.s.autoAdd(r.ctx, r.sr)
		autoAddLimit, autoAddTests = 25, 50
		if x := r.read(t, pMore); !x.noteHas("waits for the next read") || r.tests(t, x.server) != 0 {
			t.Errorf("past the bound of %s: %+v tested %d time(s), want 'waits for the next read' and no Test", b.name, x, r.tests(t, x.server))
		}
	}
}

// TestAutoAddNoLoginL237: a source that holds no login adds nothing by itself and connects to
// nothing - each proposal is left to a person, untested.
func TestAutoAddNoLoginL237(t *testing.T) {
	r := newL237Rig(t, false)
	p := r.ins(t, fmt.Sprintf("gcp:l237:sql:nologin%d", r.sfx), r.host, r.port, "")
	_ = r.s.autoAdd(r.ctx, r.sr)
	if x := r.read(t, p); x.state != "proposed" || !x.noteHas("needs a person: the source holds no login") || r.tests(t, x.server) != 0 {
		t.Errorf("a source with no login: %+v, tested %d time(s) - want proposed, 'needs a person: the source holds no login', no Test", x, r.tests(t, x.server))
	}
}

// TestAutoAddClaimHeldL237: a step that finds its source's claim held (a read, or another step) does nothing and says
// so; no audit row.
func TestAutoAddClaimHeldL237(t *testing.T) {
	r := newL237Rig(t, true)
	var started *time.Time
	if err := r.pool.QueryRow(r.ctx, `SELECT pgvigil.import_admin_source_claim($1, 'l237-other-holder', 120, false)`, r.src).Scan(&started); err != nil || started == nil {
		t.Fatalf("the other holder's claim: %v %v", started, err)
	}
	p := r.ins(t, fmt.Sprintf("gcp:l237:sql:held%d", r.sfx), r.host, r.port, "")
	res := r.s.autoAdd(r.ctx, r.sr)
	var rows int
	_ = r.pool.QueryRow(r.ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'source read' AND target = $1 AND ui_user = $2`, r.src, "auto:"+r.src).Scan(&rows)
	if res["skipped"] == nil || rows != 0 || r.read(t, p).state != "proposed" {
		t.Errorf("a held claim: %v, %d 'source read' rows, the proposal %s - want skipped, none, proposed", res, rows, r.read(t, p).state)
	}
}

// TestAutoAddStoreChecksL237: import_admin_auto_add takes its counts as digits only, and keeps no
// note for a source whose switch is off - it clears them and says so.
func TestAutoAddStoreChecksL237(t *testing.T) {
	r := newL237Rig(t, true)
	p := r.ins(t, fmt.Sprintf("gcp:l237:sql:store%d", r.sfx), "127.0.0.1", r.closed, "")
	call := func(pay map[string]any) (string, string) {
		b, _ := json.Marshal(pay)
		var o, d string
		if err := r.pool.QueryRow(r.ctx, `SELECT x->>'outcome', coalesce(x->>'detail', '') FROM pgvigil.import_admin_auto_add(now(), $1::jsonb) AS t(x)`, string(b)).Scan(&o, &d); err != nil {
			t.Fatal(err)
		}
		return o, d
	}
	pid := fmt.Sprint(p)
	if o, d := call(map[string]any{"source": r.src, "added": "1; DROP", "notes": []map[string]any{{"proposal_id": pid, "note": "x"}}}); o != "refused" || !strings.Contains(d, "a count") || r.read(t, p).note != nil {
		t.Errorf("a count not digits: %s %q, the note %v - want refused, no note", o, d, r.read(t, p).note)
	}
	if o, d := l237Source(r.ctx, t, r.pool, map[string]any{"op": "edit", "ui_user": "l237", "name": r.src, "auto_add": false}); o != "done" {
		t.Fatalf("the switch off: %s %q", o, d)
	}
	if o, d := call(map[string]any{"source": r.src, "added": 0, "notes": []map[string]any{{"proposal_id": pid, "note": "needs a person: x"}}}); o != "refused" || r.read(t, p).note != nil {
		t.Errorf("notes for a source whose switch is off: %s %q, the note %v - want refused, no note", o, d, r.read(t, p).note)
	}
}

// TestApproveRaceL237: two approves of one proposal at one moment under two names (a person's typed name and the auto
// step's own) add one instance, never two - the second waits for the proposal's row and is refused in the store's own
// words ('the proposal is approved, not proposed'). The test holds the row so both approves are inside the store at
// once, then lets go; a rig that cannot hold both there says NOT PROVEN.
func TestApproveRaceL237(t *testing.T) {
	r := newL237Rig(t, true)
	p := r.ins(t, fmt.Sprintf("gcp:l237:sql:race%d", r.sfx), r.host, r.port, "")
	names := []string{fmt.Sprintf("l237-race-a-%d", r.sfx), fmt.Sprintf("l237-race-b-%d", r.sfx)}
	t.Cleanup(func() {
		_, _ = r.pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = ANY($1)`, names)
	})
	hold, err := r.pool.Begin(r.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = hold.Rollback(context.Background()) }()
	if _, err := hold.Exec(r.ctx, `SELECT 1 FROM pgvigil.admin_proposals WHERE proposal_id = $1 FOR UPDATE`, p); err != nil {
		t.Fatal(err)
	}
	outs := make(chan proposalOut, 2)
	for i, n := range names {
		go func(user, name string) {
			outs <- r.s.decideProposal(r.ctx, user, "", map[string]any{"op": "approve", "proposal_id": fmt.Sprint(p), "name": name}, false)
		}(fmt.Sprintf("l237-race-%d", i), n)
	}
	waiting := 0
	for end := time.Now().Add(12 * time.Second); time.Now().Before(end); time.Sleep(100 * time.Millisecond) {
		_ = r.pool.QueryRow(r.ctx, `SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()`).Scan(&waiting)
		if waiting >= 2 {
			break
		}
	}
	if err := hold.Commit(r.ctx); err != nil {
		t.Fatal(err)
	}
	var got []proposalOut
	for range names {
		select {
		case o := <-outs:
			got = append(got, o)
		case <-time.After(30 * time.Second):
			t.Fatal("an approve did not end within 30 s of the row's release")
		}
	}
	var made int
	_ = r.pool.QueryRow(r.ctx, `SELECT count(*) FROM pgvigil.admin_instances WHERE name = ANY($1)`, names).Scan(&made)
	if waiting < 2 {
		t.Skipf("NOT PROVEN: N3 - only %d of the two approves waited on the proposal's row at once here (instances made: %d)", waiting, made)
	}
	done, refused := 0, ""
	for _, o := range got {
		switch {
		case o.err == nil && o.replyErr == nil && o.ans.Outcome == "done":
			done++
		case o.err == nil && o.replyErr == nil:
			refused = o.ans.Detail
		case o.err != nil:
			refused = o.err.Error()
		default:
			refused = o.replyErr.Error()
		}
	}
	if made != 1 || done != 1 || !strings.Contains(refused, "not proposed") {
		t.Errorf("two approves of one proposal at once under two names: %d instance(s) made, %d done, the other %q - want 1, 1 and 'the proposal is approved, not proposed'", made, done, refused)
	}
}
