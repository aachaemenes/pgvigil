package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
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

// TestSourceAutoAddSwitchL237 (RELNOTES L237, the lead's 05:32 (1)): the source's switch 'add the servers it finds by
// itself' is off on a new source; on is refused unless the file's door doors.discovery_auto_add is open (serve passes
// it) and the source is a cloud one; the change is in the source's audit row; off clears the source's auto notes.
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
	if o, d := add(list, "sqlserver_list", map[string]any{"auto_add": true, "auto_add_door": true, "ref": "/etc/pgvigil/servers.csv"}); o != "refused" || !strings.Contains(d, "cloud") {
		t.Errorf("a list source with the switch: %s %q, want refused (a cloud source's switch)", o, d)
	}
	if o, d := add(plain, "gcp", nil); o != "done" {
		t.Fatalf("a source without the key: %s %q", o, d)
	}
	_ = pool.QueryRow(ctx, `SELECT auto_add FROM pgvigil.admin_sources WHERE name = $1`, plain).Scan(&on)
	if on {
		t.Error("a new source's switch is off by default")
	}
	var id int64
	if err := pool.QueryRow(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, auto_note) VALUES ($1, 'gcp:l237:sql:n1', 'postgres', 'h', 'needs a person: x') RETURNING proposal_id`, cloud).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if o, d := l237Source(ctx, t, pool, map[string]any{"op": "edit", "ui_user": "l237", "name": cloud, "auto_add": false}); o != "done" {
		t.Fatalf("the switch off: %s %q", o, d)
	}
	var note *string
	_ = pool.QueryRow(ctx, `SELECT auto_add FROM pgvigil.admin_sources WHERE name = $1`, cloud).Scan(&on)
	_ = pool.QueryRow(ctx, `SELECT auto_note FROM pgvigil.admin_proposals WHERE proposal_id = $1`, id).Scan(&note)
	if on || note != nil {
		t.Errorf("after the switch off: auto_add %v, the proposal's note %v (want off, none)", on, note)
	}
}

// TestAutoAddGateL237: the auto step runs only for a cloud source with its switch on and the file's door open.
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
	if autoAddLimit != 25 {
		t.Errorf("25 a read (the lead's 05:32 (4)): %d", autoAddLimit)
	}
}

// TestAutoAddL237 (RELNOTES L237 (2)-(5)): a cloud source with its switch on adds a proposal the page's Test reaches,
// through the page's own approve as auto:<source>; a proposal the approve would ask a person to tick (here a pausing
// server) is left 'needs a person: <the approve's words>'; a failed Test is left with its words; a gone or ignored
// proposal is not touched; past the bound, 'waits for the next read'; one 'source read' audit row 'added n by
// itself'. The servers are this test's own store (its host as 127.0.0.1 and as localhost: two servers to the approve).
func TestAutoAddL237(t *testing.T) {
	ctx, pool, dsn, sfx := l237Store(t)
	pc, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "pgvigil.yaml")
	if err := os.WriteFile(cfgPath, []byte("repository:\n  dsn: env:X\ninstances: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	credFile := filepath.Join(dir, "cred.json")
	cred, _ := json.Marshal(map[string]string{"login": pc.User, "password": pc.Password, "extra": "sslmode=disable"})
	if err := os.WriteFile(credFile, cred, 0o600); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closed := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	src := fmt.Sprintf("l237-auto-%d", sfx)
	t.Cleanup(func() {
		bg := context.Background()
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_instances WHERE name IN (SELECT instance_name FROM pgvigil.admin_proposals WHERE source = $1 AND instance_name IS NOT NULL)`, src)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_proposals WHERE source = $1`, src)
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_sources WHERE name = $1`, src)
	})
	auth := "password"
	if pc.Password == "" {
		auth = "pgpass" // a store on trust: the source's login alone, no password (the page's own '.pgpass' form)
	}
	if o, d := l237Source(ctx, t, pool, map[string]any{"op": "add", "ui_user": "l237", "name": src, "kind": "gcp", "ref": "file:/x/gcp.json",
		"credential_ref": "file:" + credFile, "auth": auth, "every_s": "3600", "auto_add": true, "auto_add_door": true}); o != "done" {
		t.Fatalf("the source: %s %q", o, d)
	}
	ins := func(server, host string, port int, set string) int64 {
		var id int64
		if err := pool.QueryRow(ctx, `INSERT INTO pgvigil.admin_proposals (source, server, engine, host, port, dbname, platform)
		                               VALUES ($1, $2, 'postgres', $3, $4, $5, 'cloudsql') RETURNING proposal_id`, src, server, host, port, pc.Database).Scan(&id); err != nil {
			t.Fatalf("proposal %s: %v", server, err)
		}
		if set != "" {
			if _, err := pool.Exec(ctx, `UPDATE pgvigil.admin_proposals SET `+set+` WHERE proposal_id = $1`, id); err != nil {
				t.Fatal(err)
			}
		}
		return id
	}
	pAdd := ins(fmt.Sprintf("gcp:l237:sql:add%d", sfx), "127.0.0.1", int(pc.Port), "")
	pPause := ins(fmt.Sprintf("gcp:l237:sql:pause%d", sfx), "localhost", int(pc.Port), "auto_pause = true, serverless = 'the server pauses when idle (this test)'")
	pDown := ins(fmt.Sprintf("gcp:l237:sql:down%d", sfx), "127.0.0.1", closed, "")
	pGone := ins(fmt.Sprintf("gcp:l237:sql:gone%d", sfx), "127.0.0.1", closed, "gone = true")
	pIgn := ins(fmt.Sprintf("gcp:l237:sql:ign%d", sfx), "127.0.0.1", closed, "state = 'ignored'")

	defer config.SetPageCloud(config.Doors{})
	config.SetPageCloud(config.Doors{DiscoveryAutoAdd: true})
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: collectorPool(ctx, t, pool, dsn, sfx)}}
	s.SetInstancesAdmin(InstancesAdmin{ConfigPath: cfgPath})
	t.Cleanup(func() { instancesAdmins.Delete(s.self()) })
	sr, err := s.sourceByName(ctx, src)
	if err != nil || !sr.AutoAdd {
		t.Fatalf("the source row: %+v %v", sr, err)
	}
	res := s.autoAdd(ctx, sr)
	t.Logf("autoAdd: %v", res)

	type row struct {
		state, by, inst string
		note            *string
	}
	read := func(id int64) row {
		var r row
		var by, inst *string
		if err := pool.QueryRow(ctx, `SELECT state, decided_by, instance_name, auto_note FROM pgvigil.admin_proposals WHERE proposal_id = $1`, id).Scan(&r.state, &by, &inst, &r.note); err != nil {
			t.Fatal(err)
		}
		if by != nil {
			r.by = *by
		}
		if inst != nil {
			r.inst = *inst
		}
		return r
	}
	noteHas := func(r row, w string) bool { return r.note != nil && strings.Contains(*r.note, w) }
	if r := read(pAdd); r.state != "approved" || r.by != "auto:"+src || r.inst == "" || r.note != nil {
		t.Errorf("the reachable proposal: %+v, want approved by auto:%s with no note", r, src)
	} else {
		var n int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instances WHERE name = $1`, r.inst).Scan(&n)
		if n != 1 {
			t.Errorf("its instance %s: %d rows", r.inst, n)
		}
	}
	if r := read(pPause); r.state != "proposed" || !noteHas(r, "needs a person: ") || !noteHas(r, "paus") {
		t.Errorf("the pausing proposal: %+v, want proposed with 'needs a person: ...pauses...'", r)
	}
	if r := read(pDown); r.state != "proposed" || !noteHas(r, "the test failed: ") {
		t.Errorf("the unreachable proposal: %+v, want proposed with 'the test failed: ...'", r)
	}
	for _, id := range []int64{pGone, pIgn} {
		if r := read(id); r.note != nil || r.state == "approved" {
			t.Errorf("a gone or ignored proposal is not touched: %+v", r)
		}
	}
	var audits, tests int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'source read' AND target = $1 AND ui_user = $2 AND detail LIKE 'added 1 by itself%'`, src, "auto:"+src).Scan(&audits)
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE op = 'proposal test' AND ui_user = $1`, "auto:"+src).Scan(&tests)
	if audits != 1 || tests < 2 {
		t.Errorf("the audit: %d 'source read' rows 'added 1 by itself', %d tests by auto:%s (want 1 and 2+)", audits, tests, src)
	}

	// the bound: one a read here - the second reachable server waits for the next read
	saved := autoAddLimit
	autoAddLimit = 1
	defer func() { autoAddLimit = saved }()
	_, _ = pool.Exec(ctx, `UPDATE pgvigil.admin_proposals SET auto_pause = false, auto_note = NULL WHERE proposal_id = $1`, pPause)
	pMore := ins(fmt.Sprintf("gcp:l237:sql:more%d", sfx), "localhost", int(pc.Port), "")
	_ = s.autoAdd(ctx, sr)
	approved := 0
	for _, id := range []int64{pPause, pMore} {
		if r := read(id); r.state == "approved" {
			approved++
		} else if !noteHas(r, "waits for the next read") {
			t.Errorf("past the bound: %+v, want 'waits for the next read'", r)
		}
	}
	if approved != 1 {
		t.Errorf("one added a read with the bound at 1: %d", approved)
	}
}
