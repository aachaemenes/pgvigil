package web

import (
	"context"
	"encoding/json"
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
		// review 206h: an IPv6 address with SQL Server's ',port' (the page took it for a name); spaces around the ',';
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

// TestMoveAddWindows (reviews 206d 1 / 206e 3): the Windows sign-in only when serve runs as the gMSA gmsa: names, never
// the machine account; the host here is PGVHOST.
func TestMoveAddWindows(t *testing.T) {
	ok := moveServer{Server: "SQL01", DBADashIDs: []int{1}, Host: "sql01", Name: "sql01"}
	for _, c := range []struct {
		name, auth, gmsa, runAs string
		want                    string // "" = accepted; runAs "?" = the account could not be read
	}{
		{"serve as the service's virtual account", "windows", `CORP\pgv$`, `NT SERVICE\pgvigil`, `runs as "NT SERVICE\\pgvigil", not as the gMSA`},
		{"serve as LocalSystem", "windows", `CORP\pgv$`, `NT AUTHORITY\SYSTEM`, "not as the gMSA"},
		{"serve as a DBA's own account", "windows", `CORP\pgv$`, `CORP\allen`, "not as the gMSA"},
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
		want      string
	}{
		{"/etc/pgvigil/pgvigil.yaml", "corp", []int{3, 7}, nil, "pgvigil import dbadash -config /etc/pgvigil/pgvigil.yaml -repo corp -instance 3,7"},
		{"/etc/pgvigil/pgvigil.yaml", "corp", []int{3}, &at, "pgvigil import dbadash -config /etc/pgvigil/pgvigil.yaml -repo corp -instance 3 -to 2026-11-14T18:00:00.0000005Z"},
		{`C:\Program Files\pgvigil\pgvigil.yaml`, "it's", []int{1}, nil, `pgvigil import dbadash -config 'C:\Program Files\pgvigil\pgvigil.yaml' -repo 'it''s' -instance 1`},
		{"", "corp", []int{1}, nil, "pgvigil import dbadash -config pgvigil.yaml -repo corp -instance 1"},
	} {
		if got := moveCommand(c.cfg, c.repo, c.ids, c.cf); got != c.want {
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
	defer moveJobsOf.Delete(s)
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
	if w := add("windows", a); w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "Windows authentication needs pgvigil on Windows") || files() != 0 {
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
	// the checklist
	tick := func(step string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		s.moveTick(w, req(), "t206", map[string]any{"name": nameA, "step": step})
		return w
	}
	if w := tick("coffee"); w.Code != http.StatusBadRequest {
		t.Fatalf("a tick of an unknown step: %d, want 400", w.Code)
	}
	if w := tick("xe_dropped"); w.Code != http.StatusOK {
		t.Fatalf("a tick: %d %s", w.Code, w.Body.String())
	}
	if err := pool.QueryRow(ctx, `SELECT coalesce(m.ticks->'xe_dropped'->>'done', '-') || '|' || coalesce(m.ticks->'xe_dropped'->>'by', '-')
  FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id WHERE i.name = $1`, nameA).Scan(&got); err != nil || got != "true|t206" {
		t.Fatalf("the tick kept: %q (%v), want true|t206", got, err)
	}
}
