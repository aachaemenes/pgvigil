package web

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/dbadash"
)

// TestMoveAddCheck (task 206, W3): the add's refusals before anything is written - the sign-in (Windows only on a
// Windows serve with the gMSA named), the count (1 to 50), DBA Dash's local or pipe connections, a host that is not a
// network name or address (a ConnectionID that is a free-text label), the name rule, the port.
func TestMoveAddCheck(t *testing.T) {
	ok := moveServer{Server: `SQL01\PROD`, DBADashIDs: []int{1}, Host: `sql01\PROD`, Name: "sql01-PROD"}
	many := make([]moveServer, maxMoveAdd+1)
	for i := range many {
		many[i] = ok
	}
	with := func(f func(*moveServer)) []moveServer { s := ok; f(&s); return []moveServer{s} }
	for _, c := range []struct {
		name, auth, gmsa, goos string
		servers                []moveServer
		want                   string // "" = accepted
	}{
		{"sql", "sql", "", "linux", []moveServer{ok}, ""},
		{"entra", "entra", "", "linux", []moveServer{ok}, ""},
		{"entra-identity", "entra-identity", "", "linux", []moveServer{ok}, ""},
		{"windows on linux", "windows", `CORP\pgv$`, "linux", []moveServer{ok}, "Windows authentication needs pgvigil on Windows"},
		{"windows without the gmsa", "windows", "", "windows", []moveServer{ok}, "never the machine account"},
		{"windows with the gmsa", "windows", `CORP\pgv$`, "windows", []moveServer{ok}, ""},
		{"no auth", "", "", "linux", []moveServer{ok}, "auth is sql, entra, entra-identity or windows"},
		{"password (PostgreSQL's)", "password", "", "linux", []moveServer{ok}, "auth is sql"},
		{"none", "sql", "", "linux", nil, "1 to 50 servers"},
		{"51", "sql", "", "linux", many, "1 to 50 servers (got 51)"},
		{"named pipe", "sql", "", "linux", with(func(s *moveServer) { s.Host = `np:\\sql01\pipe\sql\query` }), "named pipe"},
		{"shared memory", "sql", "", "linux", with(func(s *moveServer) { s.Host = "lpc:sql01" }), "named pipe"},
		{"dot", "sql", "", "linux", with(func(s *moveServer) { s.Host = "." }), "on DBA Dash's own host"},
		{"dot instance", "sql", "", "linux", with(func(s *moveServer) { s.Host = `.\SQLEXPRESS` }), "on DBA Dash's own host"},
		{"(local)", "sql", "", "linux", with(func(s *moveServer) { s.Host = "(local)" }), "on DBA Dash's own host"},
		{"localhost,1433", "sql", "", "linux", with(func(s *moveServer) { s.Host = "localhost,1433" }), "on DBA Dash's own host"},
		{"tcp:localhost", "sql", "", "linux", with(func(s *moveServer) { s.Host = "tcp:localhost,1433" }), "on DBA Dash's own host"},
		{"empty host", "sql", "", "linux", with(func(s *moveServer) { s.Host = "" }), "no host: type the server's host and port"},
		{"localhost-like name", "sql", "", "linux", with(func(s *moveServer) { s.Host = "localhost2" }), ""},
		{"a name with a backslash", "sql", "", "linux", with(func(s *moveServer) { s.Name = `sql01\PROD` }), "suggested: SQL01-PROD"},
		{"no name", "sql", "", "linux", with(func(s *moveServer) { s.Name = "" }), "must be 1 to 63"},
		{"64 characters", "sql", "", "linux", with(func(s *moveServer) { s.Name = strings.Repeat("a", 64) }), "must be 1 to 63"},
		{"63 characters", "sql", "", "linux", with(func(s *moveServer) { s.Name = strings.Repeat("a", 63) }), ""},
		{"port 0", "sql", "", "linux", with(func(s *moveServer) { s.Port = "0" }), "not 1 to 65535"},
		{"port 70000", "sql", "", "linux", with(func(s *moveServer) { s.Port = "70000" }), "not 1 to 65535"},
		{"port 1433", "sql", "", "linux", with(func(s *moveServer) { s.Port = "1433" }), ""},
		// a ConnectionID that is a free-text label, not an address: refused with the server, the value and why, never
		// sent to the driver
		{"a free-text label", "sql", "", "linux", with(func(s *moveServer) { s.Host = "SQL01 payroll box (old)" }), `SQL01\PROD: "SQL01 payroll box (old)" is not a network name or address`},
		{"two servers in one label", "sql", "", "linux", with(func(s *moveServer) { s.Host = "X_App and Y_Prod" }), "a space"},
		{"an alias in brackets before the name", "sql", "", "linux", with(func(s *moveServer) { s.Host = "[ERP] SQL01" }), "not a network name or address"},
		{"an alias alone in brackets", "sql", "", "linux", with(func(s *moveServer) { s.Host = "[ERP]" }), "brackets"},
		{"a note in parentheses", "sql", "", "linux", with(func(s *moveServer) { s.Host = "SQL01(old)" }), "not a network name or address"},
		{"a comma before no port", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01,prod" }), "not a network name or address"},
		{"an instance name with a space", "sql", "", "linux", with(func(s *moveServer) { s.Host = `SQL01\MY INST` }), "not a network name or address"},
		{"a DNS name and a port", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01.corp.example.com,14330" }), ""},
		{"tcp: a name and a port", "sql", "", "linux", with(func(s *moveServer) { s.Host = "tcp:sql01,1433" }), ""},
		{"a name with an underscore", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql_01" }), ""},
		{"an IPv4 address", "sql", "", "linux", with(func(s *moveServer) { s.Host = "10.1.2.3" }), ""},
		{"an IPv6 address and a port", "sql", "", "linux", with(func(s *moveServer) { s.Host = "[fe80::1]:1433" }), ""},
		{"an IPv6 address in brackets", "sql", "", "linux", with(func(s *moveServer) { s.Host = "[2001:db8::5]" }), ""},
		{"a host:port", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01:1433" }), ""},
		// the rows web/src/move_address.test.mjs holds beside these (the page's prefill is the same rule)
		{"an IPv4 address in brackets", "sql", "", "linux", with(func(s *moveServer) { s.Host = "[10.1.2.3]" }), "brackets"},
		{"a port out of range in the host", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01,70000" }), "not 1 to 65535"},
		{"an instance name with a hyphen", "sql", "", "linux", with(func(s *moveServer) { s.Host = `SQL01\MY-INST` }), "not a character of an instance name"},
		{"an instance name of 17 characters", "sql", "", "linux", with(func(s *moveServer) { s.Host = `SQL01\` + strings.Repeat("A", 17) }), "not 1 to 16"},
		{"a name ending in a dot", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01." }), "not a host name"},
		{"an IPv6 address alone", "sql", "", "linux", with(func(s *moveServer) { s.Host = "fe80::1" }), ""},
		// an IPv6 address with SQL Server's ',port' (the page took it for a name); spaces around the ',';
		// an unclosed bracket; a port in the host against another in the port field; a 254-byte name of 127 letters
		{"an IPv6 address and ',port'", "sql", "", "linux", with(func(s *moveServer) { s.Host = "fe80::1,1433" }), ""},
		{"tcp: an IPv6 address and ',port'", "sql", "", "linux", with(func(s *moveServer) { s.Host = "tcp:2001:db8::5,1433" }), ""},
		{"a space after the comma", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01, 1433" }), ""},
		{"spaces around the comma", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01 , 1433" }), ""},
		{"a space in the name before the comma", "sql", "", "linux", with(func(s *moveServer) { s.Host = "sql01 old,1433" }), "a space"},
		{"an unclosed bracket", "sql", "", "linux", with(func(s *moveServer) { s.Host = "[fe80::1" }), "a '[' with no ']'"},
		{"a port in the host and another in the field", "sql", "", "linux", with(func(s *moveServer) { s.Host, s.Port = "sql05-listener,1433", "14330" }), "keep one"},
		{"the same port in the host and the field", "sql", "", "linux", with(func(s *moveServer) { s.Host, s.Port = "sql05,1433", "1433" }), ""},
		{"a name of 254 bytes", "sql", "", "linux", with(func(s *moveServer) { s.Host = strings.Repeat("é", 127) }), "not a host name"},
		{"an IPv4-mapped IPv6 address", "sql", "", "linux", with(func(s *moveServer) { s.Host = "::ffff:10.1.2.3" }), ""},
	} {
		err := moveAddCheck(c.auth, winSide{GMSA: c.gmsa, GOOS: c.goos, RunAs: c.gmsa, Host: "PGVHOST"}, c.servers)
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s: refused (%v), want accepted", c.name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s: %v, want an error with %q", c.name, err, c.want)
		}
	}
}

// TestMoveAddWindows: the Windows sign-in only when serve runs as the gMSA gmsa: names, never
// the machine account; the host here is PGVHOST.
func TestMoveAddWindows(t *testing.T) {
	ok := moveServer{Server: "SQL01", DBADashIDs: []int{1}, Host: "sql01", Name: "sql01"}
	for _, c := range []struct {
		name, auth, gmsa, runAs string
		want                    string // "" = accepted; runAs "?" = the account could not be read
	}{
		{"serve as the service's virtual account", "windows", `CORP\pgv$`, `NT SERVICE\pgvigil`, `runs as "NT SERVICE\\pgvigil", not as the gMSA`},
		{"serve as LocalSystem", "windows", `CORP\pgv$`, `NT AUTHORITY\SYSTEM`, "not as the gMSA"},
		{"serve as a DBA's own account", "windows", `CORP\pgv$`, `CORP\dbauser`, "not as the gMSA"},
		{"serve as the gmsa, another case", "windows", `CORP\pgv$`, `corp\PGV$`, ""},
		{"the machine account named as the gmsa", "windows", `CORP\PGVHOST$`, "", "this host's machine account"},
		{"the machine account, lower case", "windows", `CORP\pgvhost$`, "", "this host's machine account"},
		{"the account unread", "windows", `CORP\pgv$`, "?", `runs as "", not as the gMSA`},
		{"sql on windows as another account", "sql", `CORP\pgv$`, `NT SERVICE\pgvigil`, ""},
	} {
		runAs := c.runAs
		if runAs == "?" {
			runAs = ""
		}
		err := moveAddCheck(c.auth, winSide{GMSA: c.gmsa, GOOS: "windows", RunAs: runAs, Host: "PGVHOST"}, []moveServer{ok})
		switch {
		case c.want == "" && err != nil:
			t.Errorf("%s: refused (%v), want accepted", c.name, err)
		case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
			t.Errorf("%s: %v, want an error with %q", c.name, err, c.want)
		}
	}
}

// TestMoveLines (W7, W8): the exact command, the DROP line and the shell quoting.
func TestMoveLines(t *testing.T) {
	at := time.Date(2026, 11, 14, 10, 0, 0, 500, time.FixedZone("PST", -8*3600))
	for _, c := range []struct {
		cfg, repo string
		ids       []int
		cf        *time.Time
		goos      string
		want      string
	}{
		{"/etc/pgvigil/pgvigil.yaml", "corp", []int{3, 7}, nil, "linux", "pgvigil import dbadash -config /etc/pgvigil/pgvigil.yaml -repo corp -instance 3,7"},
		{"/etc/pgvigil/pgvigil.yaml", "corp", []int{3}, &at, "linux", "pgvigil import dbadash -config /etc/pgvigil/pgvigil.yaml -repo corp -instance 3 -to 2026-11-14T18:00:00.0000005Z"},
		{`C:\Program Files\pgvigil\pgvigil.yaml`, "it's", []int{1}, nil, "windows", `pgvigil import dbadash -config 'C:\Program Files\pgvigil\pgvigil.yaml' -repo 'it''s' -instance 1`},
		{"", "corp", []int{1}, nil, "linux", "pgvigil import dbadash -config pgvigil.yaml -repo corp -instance 1"},
		// a POSIX shell's quoting off Windows ('it''s' there is two words)
		{"/srv/my pgvigil/pgvigil.yaml", "it's", []int{1}, nil, "linux", `pgvigil import dbadash -config '/srv/my pgvigil/pgvigil.yaml' -repo 'it'\''s' -instance 1`},
	} {
		if got := moveCommand(c.cfg, c.repo, c.ids, c.cf, c.goos); got != c.want {
			t.Errorf("moveCommand(%q, %q, %v): %q, want %q", c.cfg, c.repo, c.ids, got, c.want)
		}
	}
	for in, want := range map[string]string{"DBADash_1": "DROP EVENT SESSION [DBADash_1] ON SERVER;", "DBADash_a]b": "DROP EVENT SESSION [DBADash_a]]b] ON SERVER;"} {
		if got := dropLine(in); got != want {
			t.Errorf("dropLine(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestMoveMigrateOnAStore (task 206 DONE-2 on a migrated repository, PGVIGIL_REPO_TEST_DSN, skipped without it): the
// page's add moves two servers with one SQL login (one of them DBA Dash lists twice): two credential files 0600, two
// moves with their InstanceIDs, the host and port split from DBA Dash's connection; a second add of one is refused and
// leaves no file; Windows on this (non-Windows) serve is refused before anything; the list shows both 'moving' with
// the exact command and the XE read line (no list since collect_from), then - after pgvigil's first read and an XE list
// of two sessions - 'collecting' with the command's -to, the DROP lines and the slow-query note; the import is refused
// with that command while the repository's switch is off, and before pgvigil's first read when it is on; a tick is kept;
// DBA Dash's services unread are a note.
func TestMoveMigrateOnAStore(t *testing.T) {
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
	defer pool.Close()
	sfx := time.Now().UnixNano() % 1000000000
	repo := fmt.Sprintf("r206mig-%d", sfx)
	srvA, srvB := fmt.Sprintf(`SRVA%d\PROD`, sfx), fmt.Sprintf("SRVB%d", sfx)
	nameA, nameB := fmt.Sprintf("srva%d-PROD", sfx), fmt.Sprintf("srvb%d", sfx)
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_repositories (repository, status, read_at) VALUES ($1, 'ok', now())`, repo); err != nil {
		t.Fatal(err)
	}
	for _, d := range []struct {
		id         int
		inst, conn string
	}{{31, srvA, strings.ToLower(srvA) + ",1433"}, {32, srvA, strings.ToLower(srvA)}, {33, srvB, "tcp:" + strings.ToLower(srvB) + ",14330"}} {
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_instances (repository, instance_id, instance, connection_id, display_name, first_seen, snapshot_at)
		                             VALUES ($1, $2, $3, $4, $3, now(), now())`, repo, d.id, d.inst, d.conn); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		bg := context.Background()
		for _, n := range []string{nameA, nameB} {
			_, _ = pool.Exec(bg, `DELETE FROM pgvigil.admin_instances WHERE name = $1`, n)
			_, _ = pool.Exec(bg, `DELETE FROM pgvigil.instances WHERE name = $1`, n)
		}
		_, _ = pool.Exec(bg, `DELETE FROM pgvigil.dbadash_repositories WHERE repository = $1`, repo)
		dbadash.SetRepositories(nil)
	}()
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "pgvigil.yaml")
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: pool}}
	s.SetInstancesAdmin(InstancesAdmin{ConfigPath: cfgPath, DBADash: map[string]string{repo: "env:PGVIGIL_T206_NONE"}})
	defer instancesAdmins.Delete(s)
	defer moveJobsOf.Delete(s.self())
	dbadash.SetRepositories([]config.DBADashRepo{{Name: repo, DSNRaw: "env:PGVIGIL_T206_NONE"}})
	req := func() *http.Request { return httptest.NewRequest(http.MethodPost, "/api/admin/dbadash_moves", nil) }
	decode := func(w *httptest.ResponseRecorder) map[string]any {
		t.Helper()
		var m map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
			t.Fatalf("%d %s: %v", w.Code, w.Body.String(), err)
		}
		return m
	}
	add := func(auth string, servers ...map[string]any) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		s.moveAdd(w, req(), "t206", repo, map[string]any{"servers": servers, "auth": auth, "login": "pgv_mon", "password": "pw t206"})
		return w
	}
	files := func() int {
		es, _ := os.ReadDir(config.SecretDir(cfgPath))
		return len(es)
	}
	a := map[string]any{"server": srvA, "dbadash_ids": []int{31, 32}, "host": strings.ToLower(srvA) + ",1433", "name": nameA}
	b := map[string]any{"server": srvB, "dbadash_ids": []int{33}, "host": "tcp:" + strings.ToLower(srvB), "port": "14330", "name": nameB}

	// Windows on this serve: refused before anything is written
	// the words of this serve's own OS and account, not Linux's alone
	winWhy := windowsOff(thisWin(""))
	if w := add("windows", a); w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), winWhy) || files() != 0 {
		t.Fatalf("a Windows add on %s: %d %s, %d file(s); want 400 with the words and no file", "linux", w.Code, w.Body.String(), files())
	}
	w := add("sql", a, b)
	res, _ := decode(w)["results"].([]any)
	if w.Code != http.StatusOK || len(res) != 2 {
		t.Fatalf("the add: %d %s", w.Code, w.Body.String())
	}
	for _, x := range res {
		if r := x.(map[string]any); r["outcome"] != "done" {
			t.Fatalf("the add of %v: %v", r["server"], r)
		}
	}
	es, _ := os.ReadDir(config.SecretDir(cfgPath))
	if len(es) != 2 {
		t.Fatalf("credential files after the add: %d, want 2", len(es))
	}
	for _, e := range es {
		if fi, err := e.Info(); err != nil || fi.Mode().Perm() != 0o600 {
			t.Fatalf("credential file %s: mode %v (%v), want 0600", e.Name(), fi.Mode().Perm(), err)
		}
	}
	// each move's own file, holding its own host, port and sign-in
	for _, c := range []struct{ name, at string }{{nameA, "@" + strings.ToLower(strings.Split(srvA, `\`)[0]) + ":1433/prod"}, {nameB, "@" + strings.ToLower(srvB) + ":14330"}} {
		var ref string
		if err := pool.QueryRow(ctx, `SELECT dsn_ref FROM pgvigil.admin_instances WHERE name = $1`, c.name).Scan(&ref); err != nil {
			t.Fatal(err)
		}
		if d := config.Resolve(ref); !strings.Contains(d, "pgv_mon:pw%20t206"+c.at) {
			t.Fatalf("%s: its credential file %s holds %d characters without 'pgv_mon:pw%%20t206%s'", c.name, ref, len(d), c.at)
		}
	}
	var got string
	if err := pool.QueryRow(ctx, `
SELECT string_agg(i.name || '|' || a.host || '|' || coalesce(a.port::text, '-') || '|' || a.auth || '|' || m.server || '|' ||
                  (SELECT string_agg(mi.dbadash_id::text, ',' ORDER BY mi.dbadash_id) FROM pgvigil.dbadash_move_ids mi WHERE mi.instance_id = m.instance_id), ' ; ' ORDER BY i.name)
  FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id JOIN pgvigil.admin_instances a ON a.name = i.name
 WHERE m.repository = $1`, repo).Scan(&got); err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("%s|%s|1433|sql|%s|31,32 ; %s|%s|14330|sql|%s|33", nameA, strings.ToLower(srvA), srvA, nameB, strings.ToLower(srvB), srvB)
	if got != want {
		t.Fatalf("the moves: %q\nwant %q", got, want)
	}
	// a second add of a moved server: refused by 0134, its credential file removed again
	w = add("sql", map[string]any{"server": srvA, "dbadash_ids": []int{31}, "host": "other" + fmt.Sprint(sfx), "name": nameA + "-2"})
	res, _ = decode(w)["results"].([]any)
	if len(res) != 1 || res[0].(map[string]any)["outcome"] != "refused" || !strings.Contains(fmt.Sprint(res[0].(map[string]any)["detail"]), "was moved already") || files() != 2 {
		t.Fatalf("a second add of %s: %s, %d file(s); want refused 'was moved already' and 2 files", srvA, w.Body.String(), files())
	}

	list := func() (map[string]any, map[string]map[string]any) {
		t.Helper()
		w := httptest.NewRecorder()
		s.DBADashMoves(w, httptest.NewRequest(http.MethodGet, "/api/admin/dbadash_moves?repo="+repo, nil))
		if w.Code != http.StatusOK {
			t.Fatalf("the list: %d %s", w.Code, w.Body.String())
		}
		m := decode(w)
		by := map[string]map[string]any{}
		for _, x := range m["servers"].([]any) {
			r := x.(map[string]any)
			by[r["server"].(string)] = r
		}
		return m, by
	}
	m, by := list()
	cmdA := fmt.Sprintf("pgvigil import dbadash -config %s -repo %s -instance 31,32", cfgPath, repo)
	xeA, _ := by[srvA]["xe"].(map[string]any)
	switch {
	case len(by) != 2 || by[srvA]["state"] != "moving" || by[srvB]["state"] != "moving":
		t.Fatalf("the list's states: %v / %v, want moving / moving (%d servers)", by[srvA]["state"], by[srvB]["state"], len(by))
	case by[srvA]["command"] != cmdA:
		t.Fatalf("the command: %q, want %q", by[srvA]["command"], cmdA)
	case xeA == nil || xeA["read"] != xeReadLine || !strings.Contains(fmt.Sprint(xeA["note"]), "has not listed"):
		t.Fatalf("the XE part before any read: %v", xeA)
	case m["import"] != false || !strings.Contains(fmt.Sprint(m["import_off"]), "import: true turns it on"):
		t.Fatalf("the switch: import %v, %v", m["import"], m["import_off"])
	case !strings.Contains(fmt.Sprint(m["agents_note"]), "were not read now") || m["agents"] != nil:
		t.Fatalf("DBA Dash's services unread: note %v, agents %v", m["agents_note"], m["agents"])
	}

	// pgvigil's first read of A, and an XE read listing two DBA Dash sessions after it
	cf := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC)
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.dbadash_moves SET collect_from = $2 WHERE instance_id = (SELECT instance_id FROM pgvigil.instances WHERE name = $1)`, nameA, cf); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_xe_foreign_read (instance_id, read_at, sessions) SELECT instance_id, $2, 2 FROM pgvigil.instances WHERE name = $1;
`, nameA, cf.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_xe_foreign (instance_id, name, running, targets, read_at)
SELECT i.instance_id, x.n, x.r, '{ring_buffer}', $2 FROM pgvigil.instances i, (VALUES ('DBADash_1', true), ('DBADash_SlowQueries', false)) x (n, r) WHERE i.name = $1`, nameA, cf.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	_, by = list()
	xeA, _ = by[srvA]["xe"].(map[string]any)
	cmdA += " -to 2026-11-14T10:00:00Z"
	drops := fmt.Sprint(xeA["drop"])
	switch {
	case by[srvA]["state"] != "collecting" || by[srvA]["command"] != cmdA:
		t.Fatalf("after the first read: %v, %q; want collecting, %q", by[srvA]["state"], by[srvA]["command"], cmdA)
	case xeA["note"] != nil || xeA["read"] != nil:
		t.Fatalf("the XE part after a read: the read line stays: %v", xeA)
	case drops != "[DROP EVENT SESSION [DBADash_1] ON SERVER; DROP EVENT SESSION [DBADash_SlowQueries] ON SERVER;]":
		t.Fatalf("the DROP lines: %s", drops)
	case !strings.Contains(fmt.Sprint(xeA["sessions"]), "event files stay"):
		t.Fatalf("the slow-query session's note: %v", xeA["sessions"])
	}

	hist := func(op, name string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		s.moveHistory(w, req(), "t206", repo, op, name)
		return w
	}
	// the switch off: refused with the command, nothing started
	if w := hist("import", nameA); w.Code != http.StatusConflict || decode(w)["command"] != cmdA {
		t.Fatalf("an import with the switch off: %d %s; want 409 with %q", w.Code, w.Body.String(), cmdA)
	}
	dbadash.SetRepositories([]config.DBADashRepo{{Name: repo, DSNRaw: "env:PGVIGIL_T206_NONE", Import: true}})
	if w := hist("import", nameB); w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "has not read") {
		t.Fatalf("an import before pgvigil's first read: %d %s; want 409 'has not read'", w.Code, w.Body.String())
	}
	if w := hist("count", "nobody-"+fmt.Sprint(sfx)); w.Code != http.StatusNotFound {
		t.Fatalf("a count of a server not moved: %d %s; want 404", w.Code, w.Body.String())
	}
	// the job in serve. A run held elsewhere (a CLI run) is the click's 409 in the store's words; then the
	// click's 202, its job in the list ending failed (the repository's dsn resolves to nothing), the move's run ended
	// failed by the import itself
	_, raw, err := s.callMove(ctx, map[string]any{"op": "run", "ui_user": "cli:t206", "client": "test", "name": nameA})
	var mk struct {
		Outcome string `json:"outcome"`
		RunID   int64  `json:"run_id"`
	}
	if err != nil || json.Unmarshal(raw, &mk) != nil || mk.Outcome != "done" {
		t.Fatalf("a CLI run's mark: %s %v", raw, err)
	}
	if w := hist("import", nameA); w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "runs already: started by cli:t206") {
		t.Fatalf("an import while a CLI run holds the move: %d %s; want 409 with the store's words", w.Code, w.Body.String())
	}
	if _, _, err := s.callMove(ctx, map[string]any{"op": "ended", "ui_user": "cli:t206", "client": "test", "name": nameA, "run_id": mk.RunID, "imported": map[string]any{}, "outcome": "failed", "detail": "held by the test"}); err != nil {
		t.Fatal(err)
	}
	if w := hist("import", nameA); w.Code != http.StatusAccepted || decode(w)["outcome"] != "started" {
		t.Fatalf("the import: %d %s; want 202 started", w.Code, w.Body.String())
	}
	var job map[string]any
	for i := 0; i < 100 && (job == nil || job["ended"] == nil); i++ {
		time.Sleep(100 * time.Millisecond)
		_, by = list()
		job, _ = by[srvA]["job"].(map[string]any)
	}
	if job == nil || job["ended"] == nil || !strings.HasPrefix(fmt.Sprint(job["outcome"]), "failed: ") || by[srvA]["state"] != "import failed" {
		t.Fatalf("the job after its run: %v, state %v; want ended 'failed: ...' and 'import failed'", job, by[srvA]["state"])
	}
	if err := pool.QueryRow(ctx, `SELECT m.run_by || '|' || m.run_outcome || '|' || (m.run_ended IS NOT NULL)
  FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id WHERE i.name = $1`, nameA).Scan(&got); err != nil || got != "t206|failed|true" {
		t.Fatalf("the move's run after the job: %q (%v), want t206|failed|true", got, err)
	}
	s.closeMoveJobs()
	// the dispatcher (the door's checks, an unknown repository or op) and the GET without a repository
	s.auth = newAuth(func(context.Context, string) (string, error) { return "h", nil }, false, time.Hour)
	tok, err := s.auth.issue("t206", "h")
	if err != nil {
		t.Fatal(err)
	}
	disp := func(header bool, body map[string]any) *httptest.ResponseRecorder {
		b, _ := json.Marshal(body)
		r := httptest.NewRequest(http.MethodPost, "/api/admin/dbadash_moves", bytes.NewReader(b))
		r.AddCookie(&http.Cookie{Name: sessionCookie, Value: tok})
		if header {
			r.Header.Set(loginHeader, "1")
		}
		w := httptest.NewRecorder()
		s.DBADashMovesWrite(w, r)
		return w
	}
	for _, c := range []struct {
		name   string
		header bool
		body   map[string]any
		code   int
		words  string
	}{
		{"no X-Pgvigil header", false, map[string]any{"repo": repo, "op": "tick"}, http.StatusForbidden, "X-Pgvigil"},
		{"an unknown repository", true, map[string]any{"repo": "nope-" + repo, "op": "count", "name": nameA}, http.StatusNotFound, ""},
		{"an unknown op", true, map[string]any{"repo": repo, "op": "coffee"}, http.StatusBadRequest, "op is add, count, import or tick"},
		{"servers not a list of objects", true, map[string]any{"repo": repo, "op": "add", "auth": "sql", "servers": "SQL01"}, http.StatusBadRequest, "servers:"},
	} {
		if w := disp(c.header, c.body); w.Code != c.code || !strings.Contains(w.Body.String(), c.words) {
			t.Fatalf("%s: %d %s; want %d with %q", c.name, w.Code, w.Body.String(), c.code, c.words)
		}
	}
	{
		w := httptest.NewRecorder()
		s.DBADashMoves(w, httptest.NewRequest(http.MethodGet, "/api/admin/dbadash_moves", nil))
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"name":"`+repo+`"`) || !strings.Contains(w.Body.String(), `"max_add":50`) {
			t.Fatalf("the GET without a repository: %d %s", w.Code, w.Body.String())
		}
		w = httptest.NewRecorder()
		s.DBADashMoves(w, httptest.NewRequest(http.MethodGet, "/api/admin/dbadash_moves?repo=nope-"+repo, nil))
		if w.Code != http.StatusNotFound {
			t.Fatalf("the GET of an unknown repository: %d %s", w.Code, w.Body.String())
		}
	}
	// the checklist
	tickIn := func(rp, step string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		s.moveTick(w, req(), "t206", rp, map[string]any{"name": nameA, "step": step})
		return w
	}
	tick := func(step string) *httptest.ResponseRecorder { return tickIn(repo, step) }
	if w := tick("coffee"); w.Code != http.StatusBadRequest {
		t.Fatalf("a tick of an unknown step: %d, want 400", w.Code)
	}
	// a tick names a server moved from THIS repository
	if w := tickIn("other-"+repo, "xe_dropped"); w.Code != http.StatusNotFound {
		t.Fatalf("a tick through another repository: %d %s, want 404", w.Code, w.Body.String())
	}
	if w := tick("xe_dropped"); w.Code != http.StatusOK {
		t.Fatalf("a tick: %d %s", w.Code, w.Body.String())
	}
	if err := pool.QueryRow(ctx, `SELECT coalesce(m.ticks->'xe_dropped'->>'done', '-') || '|' || coalesce(m.ticks->'xe_dropped'->>'by', '-')
  FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id WHERE i.name = $1`, nameA).Scan(&got); err != nil || got != "true|t206" {
		t.Fatalf("the tick kept: %q (%v), want true|t206", got, err)
	}
}

// TestMoveCountsAndOutcome: a server DBA Dash lists twice has its sources summed and its stored
// rows once; the job's inserts are summed over its InstanceIDs at each read; an InstanceID DBA Dash no longer holds is
// a note, never a partial.
func TestMoveCountsAndOutcome(t *testing.T) {
	got := []dbadash.ImportCount{
		{DBADashID: 31, Mapping: "cpu", Source: 300, Stored: 500},
		{DBADashID: 32, Mapping: "cpu", Source: 200, Stored: 500},
		{DBADashID: 31, Mapping: "jobruns", Source: 4, Stored: 4},
		{DBADashID: 32, Mapping: "jobruns", Source: 1, Stored: 4, Skipped: "waiting for the collector's first jobs read"},
		{DBADashID: 77, Mapping: "-", Skipped: "no SQL Server instance with this InstanceID in the repository (an Azure SQL database, or unknown)"},
	}
	c := moveCounts(got)
	if cpu := c["cpu"].(map[string]any); cpu["source"] != int64(500) || cpu["stored"] != int64(500) {
		t.Errorf("cpu: %v, want source 500 (300 + 200) and stored 500 (once)", cpu)
	}
	if jr := c["jobruns"].(map[string]any); jr["source"] != int64(5) || jr["skipped"] == nil {
		t.Errorf("jobruns: %v, want source 5 and the skip kept", jr)
	}
	if _, ok := c["-"]; ok {
		t.Errorf("the '-' line counted: %v", c)
	}
	outcome, notes := jobOutcome(got, nil)
	if outcome != "partial: jobruns: waiting for the collector's first jobs read" || len(notes) != 1 || !strings.Contains(notes[0], "InstanceID 77") {
		t.Errorf("the outcome: %q, notes %v", outcome, notes)
	}
	if outcome, notes = jobOutcome(got[4:], nil); outcome != "ok" || len(notes) != 1 {
		t.Errorf("only a '-' line: %q %v, want ok with its note", outcome, notes)
	}
	if outcome, _ = jobOutcome(got, errors.New("boom")); outcome != "failed: boom" {
		t.Errorf("an error: %q", outcome)
	}
	j := &moveJob{byID: map[int]map[string]int64{31: {"cpu": 300, "jobruns": 4}, 32: {"cpu": 120}}}
	if cj := copyJob(j); cj.Inserted["cpu"] != 420 || cj.Inserted["jobruns"] != 4 || cj.byID != nil {
		t.Errorf("the job's inserts: %v, want cpu 420 (300 + 120), jobruns 4", cj.Inserted)
	}
}

// TestAgentLines: a DBA Dash service may be stopped only when every active server it collects is ready
// to switch; each waiting server is named once; a service with no active server may be stopped (each removed in DBA
// Dash after its move).
func TestAgentLines(t *testing.T) {
	ag := func(id int, ins ...dbadash.AgentInstance) dbadash.Agent {
		return dbadash.Agent{ID: id, Host: "DDHOST", Service: "DBADashService", Instances: ins}
	}
	in := func(id int, server string) dbadash.AgentInstance {
		return dbadash.AgentInstance{ID: id, Server: server}
	}
	for _, c := range []struct {
		name    string
		agent   dbadash.Agent
		ready   map[int]bool
		waiting string // the waiting list joined by '|'
		stop    string // "" = no stop line
	}{
		{"all ready", ag(1, in(31, "SQL01"), in(32, "SQL01"), in(40, "SQL02")), map[int]bool{31: true, 32: true, 40: true}, "", "stop the DBA Dash service DBADashService on DDHOST"},
		{"one not ready", ag(1, in(31, "SQL01"), in(40, "SQL02")), map[int]bool{31: true}, "SQL02", ""},
		{"one server under two ids, neither ready: named once", ag(1, in(31, "SQL01"), in(32, "sql01")), map[int]bool{}, "SQL01", ""},
		{"half of a server ready", ag(1, in(31, "SQL01"), in(32, "SQL01")), map[int]bool{31: true}, "SQL01", ""},
		{"no Instance name: its id", ag(1, in(55, "")), map[int]bool{}, "InstanceID 55", ""},
		{"an Azure SQL database (never moved) waits", ag(1, in(31, "SQL01"), in(70, "pool-db")), map[int]bool{31: true}, "pool-db", ""},
		{"no active server", ag(2), map[int]bool{}, "", "stop the DBA Dash service DBADashService on DDHOST if it still runs: it collects no active server now"},
		{"ready keyed by DBA Dash's id, not another", ag(1, in(31, "SQL01")), map[int]bool{1: true}, "SQL01", ""},
	} {
		got := agentLines([]dbadash.Agent{c.agent}, c.ready)
		if len(got) != 1 {
			t.Fatalf("%s: %d lines", c.name, len(got))
		}
		if w := strings.Join(got[0].Waiting, "|"); w != c.waiting || got[0].Stop != c.stop {
			t.Errorf("%s: waiting %q stop %q; want %q, %q", c.name, w, got[0].Stop, c.waiting, c.stop)
		}
	}
}
