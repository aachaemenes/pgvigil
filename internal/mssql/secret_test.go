package mssql

import (
	"context"
	"errors"
	"fmt"
	"net"
	"testing"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// a stand-in reader: Refresh answers next (retry when its version differs)
type fakeSecrets struct{ cur, next secrets.Value }

func (f *fakeSecrets) Get(context.Context, secrets.Ref) (secrets.Value, error) { return f.cur, nil }
func (f *fakeSecrets) Refresh(_ context.Context, _ secrets.Ref, failed string) (secrets.Value, bool, error) {
	return f.next, f.next.Version != failed, nil
}
func (f *fakeSecrets) Accepted(context.Context, secrets.Ref, string) {}

// The retry's second connect failing gives its own error and no db (Connect then never closes a nil
// *sql.DB: the panic that took the process down), with the new version's own login (an alternating-users rotation),
// on a deadline of its own.
func TestSecretRetryFails(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close() // nothing listens there now: the second connect is refused
	f := &fakeSecrets{next: secrets.Value{User: "b", Password: "p2", Version: "v2"}}
	secretReader = f
	defer func() { secretReader = secrets.Default }()
	ref := secrets.Ref{ID: "s", Region: "us-east-2"}
	s := instanceSecret{ref: &ref, val: secrets.Value{User: "a", Password: "p1", Version: "v1"}, user: "a"}
	dsn := fmt.Sprintf("sqlserver://127.0.0.1:%d?database=master&encrypt=disable", port)
	dl := &deadlineDialer{keepAlive: 30 * time.Second, until: time.Now().Add(-time.Second)} // the first connect's 10 s spent
	t0 := time.Now().Add(-time.Minute)
	db, conn, retried, err := s.retry(context.Background(), mssqldb.Error{Number: 18456}, dsn, dsn, dl, &t0)
	if !retried || db != nil || conn != nil || err == nil {
		t.Fatalf("a failed second connect: db %v conn %v retried %v err %v, want retried with its own error and no db", db, conn, retried, err)
	}
	if s.user != "b" || s.val.Version != "v2" {
		t.Errorf("the retry signed in as %q with %s, want the new version's own login b with v2", s.user, s.val.Version)
	}
	if time.Since(t0) > 5*time.Second {
		t.Error("t0 not restarted for the retry's own dial")
	}
	if !dl.until.After(time.Now()) {
		t.Error("the retry kept the first connect's spent deadline")
	}
	// not an 18456: the first answer stands
	if _, _, retried, _ := s.retry(context.Background(), errors.New("i/o timeout"), dsn, dsn, dl, &t0); retried {
		t.Error("a retry on an error that is not a refused login")
	}
}

// One SQL login rule - the dsn's login wins and must be the secret's username (no case), else the secret's;
// neither, or a DOMAIN\user login, refused.
func TestMSLogin(t *testing.T) {
	for _, c := range []struct {
		dsn, secretUser, want, code string
	}{
		{"sqlserver://h:1433?database=d", "pgv", "pgv", ""},
		{"sqlserver://PGV@h:1433?database=d", "pgv", "PGV", ""},
		{"sqlserver://other@h:1433?database=d", "pgv", "", "LoginMismatch"},
		{"sqlserver://h:1433?database=d", "", "", "NoLogin"},
		{`server=h;user id=CORP\svc;database=d`, "", "", "WindowsLogin"},
	} {
		got, err := msLogin(c.dsn, secrets.Value{User: c.secretUser, Password: "x"})
		var re *secrets.ReadError
		switch {
		case c.code == "" && (err != nil || got != c.want):
			t.Errorf("%s / %q: %q %v, want %q", c.dsn, c.secretUser, got, err, c.want)
		case c.code != "" && (!errors.As(err, &re) || re.Code != c.code):
			t.Errorf("%s / %q: %v, want %s", c.dsn, c.secretUser, err, c.code)
		}
	}
}
