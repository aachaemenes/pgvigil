package config

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/microsoft/go-mssqldb/msdsn"
)

func TestMergeKeepsFileFirstAndSkipsBadPageRows(t *testing.T) {
	file := []Instance{{Name: "pg1", Engine: EnginePostgres, DSNRaw: "env:X", Platform: "auto", QueryText: "full"}}
	page := []PageInstance{
		{Name: "pg1", Engine: EnginePostgres, DSNRef: "file:/etc/pgvigil/instances/pg1.dsn"}, // the file's name: left out
		{Name: "sql1", Engine: EngineSQLServer, DSNRef: "file:/etc/pgvigil/instances/sql1.dsn", Tags: []string{"group:Prod"}},
		{Name: "off", Engine: EnginePostgres, DSNRef: "file:/x/off.dsn", Disabled: true}, // disabled: not run, not an error
		{Name: "bad ref", Engine: EnginePostgres, DSNRef: "host=x password=y"},           // name and ref both wrong
		{Name: "inline", Engine: EnginePostgres, DSNRef: "host=x password=y"},            // a connection string, never run
		{Name: "eng", Engine: "oracle", DSNRef: "file:/x/eng.dsn"},
	}
	all, skipped := Merge(file, page, "normalized")
	var names []string
	for _, in := range all {
		names = append(names, in.Name)
	}
	if !slices.Equal(names, []string{"pg1", "sql1"}) {
		t.Fatalf("merged %v, want [pg1 sql1]", names)
	}
	if all[0].DSNRaw != "env:X" {
		t.Fatalf("the file's pg1 was replaced: %q", all[0].DSNRaw)
	}
	if all[1].Platform != "auto" || all[1].QueryText != "normalized" || all[1].DSNRaw != "file:/etc/pgvigil/instances/sql1.dsn" {
		t.Fatalf("sql1 = %+v", all[1])
	}
	if len(skipped) != 4 {
		t.Fatalf("skipped %v, want 4 (pg1, bad ref, inline, eng)", skipped)
	}
}

func TestDiffStartsAndStopsByFingerprint(t *testing.T) {
	a := Instance{Name: "a", Engine: EnginePostgres, DSNRaw: "file:/a"}
	b := Instance{Name: "b", Engine: EnginePostgres, DSNRaw: "file:/b"}
	b2 := b
	b2.Tags = []string{"env:prod"}
	c := Instance{Name: "c", Engine: EngineSQLServer, DSNRaw: "file:/c"}
	stop, start := Diff([]Instance{a, b}, []Instance{a, b2, c})
	if !slices.Equal(stop, []string{"b"}) || !slices.Equal(start, []string{"b", "c"}) {
		t.Fatalf("stop %v start %v, want [b] [b c]", stop, start)
	}
	stop, start = Diff([]Instance{a, b2, c}, []Instance{a})
	if !slices.Equal(stop, []string{"b", "c"}) || len(start) != 0 {
		t.Fatalf("stop %v start %v, want [b c] []", stop, start)
	}
	if s, st := Diff([]Instance{a}, []Instance{a}); len(s)+len(st) != 0 {
		t.Fatalf("no change gave %v %v", s, st)
	}
}

type fakeInv struct {
	mu   sync.Mutex
	gen  int64
	list []PageInstance
	fail bool
	read int
}

func (f *fakeInv) InventoryGeneration(context.Context) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		return 0, errors.New("down")
	}
	return f.gen, nil
}

func (f *fakeInv) Inventory(context.Context) ([]PageInstance, int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.read++
	return slices.Clone(f.list), f.gen, nil
}

func TestWatchInventoryAppliesOnlyWhenTheGenerationMoves(t *testing.T) {
	src := &fakeInv{gen: 1, list: []PageInstance{{Name: "p", Engine: EnginePostgres, DSNRef: "file:/p"}}}
	got := make(chan []string, 10)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		WatchInventory(ctx, slog.New(slog.NewTextHandler(io.Discard, nil)), src, nil, []Instance{{Name: "f", Engine: EnginePostgres, DSNRaw: "env:F"}}, "full", 20*time.Millisecond, func(all []Instance) {
			var n []string
			for _, in := range all {
				n = append(n, in.Name)
			}
			got <- n
		})
		close(done)
	}()
	first := <-got
	if !slices.Equal(first, []string{"f", "p"}) {
		t.Fatalf("first %v", first)
	}
	time.Sleep(100 * time.Millisecond)
	select {
	case n := <-got:
		t.Fatalf("applied again without a new generation: %v", n)
	default:
	}
	src.mu.Lock()
	src.gen, src.list = 2, nil
	src.mu.Unlock()
	select {
	case n := <-got:
		if !slices.Equal(n, []string{"f"}) {
			t.Fatalf("after the removal %v", n)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the new generation was not applied")
	}
	src.mu.Lock()
	src.fail = true
	src.mu.Unlock()
	time.Sleep(100 * time.Millisecond)
	select {
	case n := <-got:
		t.Fatalf("a failed read changed the list: %v", n)
	default:
	}
	cancel()
	<-done
}

func TestBuildDSN(t *testing.T) {
	// the rows below are a Windows collector's (auth windows = SSPI); TestBuildDSNSignIns has the other systems'
	was := dsnGOOS
	dsnGOOS = "windows"
	defer func() { dsnGOOS = was }()
	cases := []struct {
		c    Conn
		want string
		bad  bool
	}{
		{Conn{Engine: EngineSQLServer, Auth: "sql", Host: "sql01", Port: 1433, DBName: "master", Login: "mon", Password: "p@ss w:rd"},
			"sqlserver://mon:p%40ss%20w%3Ard@sql01:1433?database=master&encrypt=true", false},
		{Conn{Engine: EngineSQLServer, Auth: "windows", Host: `sql02\PROD`}, "sqlserver://sql02/PROD?encrypt=true", false},
		{Conn{Engine: EngineSQLServer, Auth: "windows", Host: "sql02", Password: "x"}, "", true},
		{Conn{Engine: EngineSQLServer, Auth: "sql", Host: "sql01", Login: "mon"}, "", true},
		{Conn{Engine: EngineSQLServer, Auth: "sql", Host: "sql01", Login: "mon", Password: "x", Extra: "TrustServerCertificate=true&server=evil"},
			"sqlserver://mon:x@sql01?TrustServerCertificate=true&encrypt=true", false},
		{Conn{Engine: EnginePostgres, Auth: "password", Host: "pg1", Port: 5432, Login: "pgvigil", Password: "it's a pw"},
			`host=pg1 port=5432 dbname=postgres user=pgvigil password='it\'s a pw'`, false},
		{Conn{Engine: EnginePostgres, Auth: "pgpass", Host: "pg1", Login: "pgvigil", Extra: "sslmode=require host=evil"},
			"host=pg1 dbname=postgres user=pgvigil sslmode=require", false},
		{Conn{Engine: EnginePostgres, Auth: "sql", Host: "pg1"}, "", true},
		{Conn{Engine: EnginePostgres, Auth: "password", Host: "pg 1", Login: "a", Password: "b"}, "", true},
	}
	for i, c := range cases {
		got, err := BuildDSN(c.c)
		if c.bad != (err != nil) {
			t.Fatalf("case %d: err %v, want bad=%v", i, err, c.bad)
		}
		if c.want != "" && got != c.want {
			t.Fatalf("case %d:\n got %s\nwant %s", i, got, c.want)
		}
		if !c.bad && c.c.Engine == EngineSQLServer && c.c.Auth == "windows" && strings.Contains(got, "@") {
			t.Fatalf("case %d: a Windows account carries a login: %s", i, got)
		}
	}
}

func TestParseServerList(t *testing.T) {
	plain := "# the fleet\nsql01\nsql02,14330\n10.0.0.5:1433\nsql01\n\n"
	p, err := ParseServerList(strings.NewReader(plain), EngineSQLServer)
	if err != nil {
		t.Fatal(err)
	}
	if len(p) != 3 || p[1].Host != "sql02" || p[1].Port != 14330 || p[2].Host != "10.0.0.5" || p[2].Port != 1433 || p[0].Server != "sql01" {
		t.Fatalf("plain list %+v", p)
	}
	csvText := "host,port,name,tags,dbname\npg1,5432,billing,env:prod team:billing,app\npg2,,,,\n"
	p, err = ParseServerList(strings.NewReader(csvText), EnginePostgres)
	if err != nil {
		t.Fatal(err)
	}
	if len(p) != 2 || p[0].Server != "pg1,5432" || p[0].DBName != "app" || !slices.Equal(p[0].Tags, []string{"env:prod", "team:billing"}) || p[1].Port != 0 {
		t.Fatalf("csv %+v", p)
	}
	if _, err := ParseServerList(strings.NewReader("host,port\npg1,notaport\n"), EnginePostgres); err == nil {
		t.Fatal("a bad port was taken")
	}
	if _, err := ParseServerList(strings.NewReader("two words\n"), EnginePostgres); err == nil {
		t.Fatal("a line with a space was taken")
	}
}

func TestParsePgServiceNeverReadsThePassword(t *testing.T) {
	conf := "# services\n[billing]\nhost=pg1.example\nport=5433\ndbname=app\nuser=mon\npassword=secret\n\n[reports]\nhost = pg2\n"
	p, err := ParsePgService(strings.NewReader(conf))
	if err != nil {
		t.Fatal(err)
	}
	if len(p) != 2 || p[0].Server != "billing" || p[0].Host != "pg1.example" || p[0].Port != 5433 || p[0].Login != "mon" || p[1].Host != "pg2" {
		t.Fatalf("%+v", p)
	}
	for _, x := range p {
		if strings.Contains(strings.Join([]string{x.Server, x.Host, x.DBName, x.Login, x.DisplayName}, " "), "secret") {
			t.Fatalf("the password reached a proposal: %+v", x)
		}
	}
	if _, err := ParsePgService(strings.NewReader("[nohost]\nport=5432\n")); err == nil {
		t.Fatal("a service with no host was taken")
	}
}

func TestWriteSecretMode0600AndRemove(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("DPAPI on Windows: proven on the Windows sandbox")
	}
	dir := filepath.Join(t.TempDir(), "instances")
	ref, err := WriteSecret(dir, "pg1", "host=pg1 password=x")
	if err != nil {
		t.Fatal(err)
	}
	if !RefOK(ref) || !strings.HasPrefix(ref, "file:") {
		t.Fatalf("ref %q", ref)
	}
	p := strings.TrimPrefix(ref, "file:")
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v, want 0600", st.Mode().Perm())
	}
	if d, _ := os.Stat(dir); d.Mode().Perm() != 0o700 {
		t.Fatalf("the folder's mode %v, want 0700", d.Mode().Perm())
	}
	if Resolve(ref) != "host=pg1 password=x" {
		t.Fatalf("Resolve read %q", Resolve(ref))
	}
	if _, err := WriteSecret(dir, "../escape", "x"); err == nil {
		t.Fatal("a name with a path was taken")
	}
	outside := filepath.Join(t.TempDir(), "keep.dsn")
	_ = os.WriteFile(outside, []byte("x"), 0o600)
	if err := RemoveSecret(dir, "file:"+outside); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("RemoveSecret removed a file outside its folder")
	}
	if err := RemoveSecret(dir, ref); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the secret file stayed")
	}
	left, _ := os.ReadDir(dir)
	if len(left) != 0 {
		t.Fatalf("left in the folder: %v", left)
	}
}

func TestRefOK(t *testing.T) {
	for v, want := range map[string]bool{"file:/etc/x.dsn": true, `dpapi:C:\ProgramData\pgvigil\instances\a.dpapi`: true, "file:x.dsn": false,
		"env:X": false, "host=x": false, "sqlserver://a:b@c": false} {
		if RefOK(v) != want {
			t.Fatalf("RefOK(%q) = %v", v, !want)
		}
	}
}

func TestWriteSecretGivesEachWriteItsOwnFile(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("DPAPI on Windows")
	}
	dir := t.TempDir()
	a, err := WriteSecret(dir, "sql01", "one")
	if err != nil {
		t.Fatal(err)
	}
	b, err := WriteSecret(dir, "sql01", "two")
	if err != nil {
		t.Fatal(err)
	}
	if a == b || Resolve(a) != "one" || Resolve(b) != "two" {
		t.Fatalf("two writes of one name: %s (%q) and %s (%q)", a, Resolve(a), b, Resolve(b))
	}
	if err := RemoveSecret(dir, b); err != nil || Resolve(a) != "one" {
		t.Fatalf("removing the second removed the first: %v", err)
	}
}

func TestListsRefuseCredentialsWithoutEchoingThem(t *testing.T) {
	for _, in := range []string{"host=pg1 password=S3cret\n", "sqlserver://u:S3cret@h:1433?x=1\n", "# x\n\npg1\nuser@S3cret\n"} {
		_, err := ParseServerList(strings.NewReader(in), EnginePostgres)
		if err == nil {
			t.Fatalf("%q was taken as a server list", in)
		}
		if strings.Contains(err.Error(), "S3cret") {
			t.Fatalf("the error echoes the line: %v", err)
		}
	}
	_, err := ParseServerList(strings.NewReader("# x\n\npg1\nuser@S3cret\n"), EnginePostgres)
	if err == nil || !strings.Contains(err.Error(), "line 4") {
		t.Fatalf("the error does not name the file's line 4: %v", err)
	}
	if _, err := ParseServerList(strings.NewReader("host,port\npg1,x=y\n"), EnginePostgres); err == nil || strings.Contains(err.Error(), "x=y") {
		t.Fatalf("a CSV field with '=': %v", err)
	}
	// a .pgpass line (the collector account's own, the pgpass login mode's file) is no server list: refused by its
	// line number, the password never echoed (the join review of 204, finding 4)
	for _, in := range []string{"pg1\ndb1:5432:*:pgvigil:S3cret\n", "pg1\n*:*:*:pgvigil:S3cret\n", "host,port\npg1,1\ndb1:5432:app:u:S3cret,2\n",
		"pg1\n\\:\\:1:5432:*:pgvigil:S3cret\n"} {
		_, err := ParseServerList(strings.NewReader(in), EnginePostgres)
		if err == nil || strings.Contains(err.Error(), "S3cret") || !strings.Contains(err.Error(), "line 2") && !strings.Contains(err.Error(), "line 3") {
			t.Fatalf("a .pgpass line %q: %v", in, err)
		}
	}
	// an IPv6 address and host:port stay servers
	if got, err := ParseServerList(strings.NewReader("2001:db8:0:0:1:0:0:1\npg2:5433\n[2603:1030:20e:3::23c]:5432\n[2603:1030:20e:3::23c]\n"), EnginePostgres); err != nil || len(got) != 4 {
		t.Fatalf("IPv6 / host:port: %v %v", got, err)
	}
	if _, err := ParseServerList(strings.NewReader("np:sql01\n"), EngineSQLServer); err == nil {
		t.Fatal("a named pipe was taken")
	}
}

func TestSplitHostPortProtocolPrefix(t *testing.T) {
	if h, p := SplitHostPort("tcp:sql01,1433"); h != "sql01" || p != 1433 {
		t.Fatalf("tcp:sql01,1433 -> %s %d", h, p)
	}
	if !NotTCP("np:\\\\sql01\\pipe\\sql\\query") || !NotTCP("lpc:sql01") || NotTCP("tcp:sql01") {
		t.Fatal("NotTCP")
	}
}

// The sign-ins without a stored password (CLOUDSQL C1): auth windows is Kerberos off Windows (never go-mssqldb's NTLM,
// which falls back to a SQL login with an empty user), entra-identity is the host's managed identity; each string read
// back by go-mssqldb's own parser says who signs in, and how.
func TestBuildDSNSignIns(t *testing.T) {
	was := dsnGOOS
	defer func() { dsnGOOS = was }()
	const keytab = "krb5-keytabfile=/etc/pgvigil/pgvigil.keytab&krb5-configfile=/etc/krb5.conf"
	for _, c := range []struct {
		name, goos string
		c          Conn
		user, auth string // the user id and the authenticator the string carries
		fedauth    string
		bad        string // a word of the refusal
	}{
		{"linux windows, a credential cache", "linux", Conn{Auth: "windows", Host: `sql02\PROD`}, "", "krb5", "", ""},
		{"linux windows, a keytab and its principal", "linux", Conn{Auth: "windows", Host: "sql01", Login: "pgvigil-gmsa$@CORP.EXAMPLE.COM", Extra: keytab},
			"pgvigil-gmsa$@CORP.EXAMPLE.COM", "krb5", "", ""},
		{"linux windows, a keytab without its principal", "linux", Conn{Auth: "windows", Host: "sql01", Extra: keytab}, "", "", "", "principal"},
		{"linux windows, a password", "linux", Conn{Auth: "windows", Host: "sql01", Login: "u@R", Password: "x"}, "", "", "", "no password"},
		{"linux windows, NTLM asked in the options", "linux", Conn{Auth: "windows", Host: "sql01", Extra: "authenticator=ntlm"}, "", "", "", "only krb5"},
		{"windows windows, the service's own account", "windows", Conn{Auth: "windows", Host: "sql01", Login: "ignored"}, "", "", "", ""},
		{"windows windows, Kerberos asked in the options", "windows", Conn{Auth: "windows", Host: "sql01", Login: "svc@R", Extra: "authenticator=krb5&" + keytab},
			"svc@R", "krb5", "", ""},
		{"entra-identity, system-assigned", "linux", Conn{Auth: "entra-identity", Host: "srv1.database.windows.net", DBName: "db1"}, "", "", "ActiveDirectoryManagedIdentity", ""},
		{"entra-identity, user-assigned", "linux", Conn{Auth: "entra-identity", Host: "srv1.database.windows.net", Login: "6a1b2c3d-0000-4000-8000-000000000001"},
			"6a1b2c3d-0000-4000-8000-000000000001", "", "ActiveDirectoryManagedIdentity", ""},
		{"entra-identity, a secret", "linux", Conn{Auth: "entra-identity", Host: "srv1.database.windows.net", Password: "x"}, "", "", "", "no secret"},
		{"entra, a service principal", "linux", Conn{Auth: "entra", Host: "srv1.database.windows.net", Login: "app-id@tenant-id", Password: "s3cret"},
			"app-id@tenant-id", "", "ActiveDirectoryServicePrincipal", ""},
		{"sql, fedauth in the options", "linux", Conn{Auth: "sql", Host: "sql01", Login: "mon", Password: "x", Extra: "fedauth=ActiveDirectoryDefault"}, "", "", "", "choose no sign-in"},
		{"sql, a user id in the options", "linux", Conn{Auth: "sql", Host: "sql01", Login: "mon", Password: "x", Extra: "user id=sa"}, "", "", "", "choose no sign-in"},
		{"sql, an authenticator in the options", "linux", Conn{Auth: "sql", Host: "sql01", Login: "mon", Password: "x", Extra: "authenticator=krb5"}, "", "", "", "only krb5"},
	} {
		dsnGOOS = c.goos
		c.c.Engine = EngineSQLServer
		got, err := BuildDSN(c.c)
		if c.bad != "" {
			if err == nil || !strings.Contains(err.Error(), c.bad) {
				t.Errorf("%s: got %q, %v; want a refusal with %q", c.name, got, err, c.bad)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		cfg, err := msdsn.Parse(got)
		if err != nil {
			t.Errorf("%s: go-mssqldb cannot read %s: %v", c.name, got, err)
			continue
		}
		if cfg.User != c.user || cfg.Password != c.c.Password || cfg.Parameters["authenticator"] != c.auth || cfg.Parameters["fedauth"] != c.fedauth {
			t.Errorf("%s: %s reads as user %q password set %v authenticator %q fedauth %q; want user %q authenticator %q fedauth %q",
				c.name, got, cfg.User, cfg.Password != "", cfg.Parameters["authenticator"], cfg.Parameters["fedauth"], c.user, c.auth, c.fedauth)
		}
		if strings.Contains(c.c.Extra, "krb5-keytabfile") && cfg.Parameters["krb5-keytabfile"] != "/etc/pgvigil/pgvigil.keytab" {
			t.Errorf("%s: the keytab reads as %q", c.name, cfg.Parameters["krb5-keytabfile"])
		}
	}
}

func TestBuildDSNRefusesAPasswordInTheOptions(t *testing.T) {
	if _, err := BuildDSN(Conn{Engine: EngineSQLServer, Auth: "windows", Host: "sql01", Extra: "password=x"}); err == nil {
		t.Fatal("a password in the options was taken")
	}
	if _, err := BuildDSN(Conn{Engine: EnginePostgres, Auth: "pgpass", Host: "pg1", Extra: "PWD=x"}); err == nil {
		t.Fatal("PWD in the options was taken")
	}
	if got := QuoteValue(`C:\Program Files\pg_service.conf`); got != `'C:\\Program Files\\pg_service.conf'` {
		t.Fatalf("QuoteValue %s", got)
	}
}

// A failed first read runs the file's instances once, not again on every failed tick, and the read's recovery
// hands the merged list (the join review of 204's fold, finding 7 of its review).
func TestWatchInventoryFailedFirstReadAppliesTheFileOnce(t *testing.T) {
	src := &fakeInv{gen: 1, fail: true, list: []PageInstance{{Name: "p", Engine: EnginePostgres, DSNRef: "file:/p"}}}
	var mu sync.Mutex
	var applied [][]string
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		WatchInventory(ctx, slog.New(slog.NewTextHandler(io.Discard, nil)), src, nil, []Instance{{Name: "f", Engine: EnginePostgres, DSNRaw: "env:F"}}, "full", 20*time.Millisecond, func(all []Instance) {
			var n []string
			for _, in := range all {
				n = append(n, in.Name)
			}
			mu.Lock()
			applied = append(applied, n)
			mu.Unlock()
		})
		close(done)
	}()
	defer func() { cancel(); <-done }()
	time.Sleep(150 * time.Millisecond)
	mu.Lock()
	n := len(applied)
	once := n == 1 && slices.Equal(applied[0], []string{"f"})
	mu.Unlock()
	if !once {
		t.Fatalf("a failing first read applied the list %d times (want the file's list once)", n)
	}
	src.mu.Lock()
	src.fail = false
	src.mu.Unlock()
	for i := 0; i < 100; i++ {
		mu.Lock()
		n = len(applied)
		mu.Unlock()
		if n >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(applied) != 2 || !slices.Equal(applied[1], []string{"f", "p"}) {
		t.Fatalf("after the recovery %v", applied)
	}
}
