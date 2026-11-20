package mssql

import (
	"context"
	"fmt"
	"net"
	"sync/atomic"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// countingSecrets: a stand-in reader that counts its reads and answers one login and password
type countingSecrets struct{ gets atomic.Int32 }

func (c *countingSecrets) Get(context.Context, secrets.Ref) (secrets.Value, error) {
	c.gets.Add(1)
	return secrets.Value{User: "pgv", Password: "from-the-secret", Version: "v1"}, nil
}
func (c *countingSecrets) Refresh(context.Context, secrets.Ref, string) (secrets.Value, bool, error) {
	return secrets.Value{}, false, nil
}
func (c *countingSecrets) Accepted(context.Context, secrets.Ref, string) {}

// closedPort: a local port nothing listens on (a dial there is refused at once)
func closedPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port
}

// TestSecretOnlyInstanceCallers: an instance whose read login has only a password_secret - no
// password in its dsn - is signed in with the secret by the two callers of other slices that met B24e first at the
// join: the backup file check's own pool (301b's openBackupFilePool) and the verify door's read-login checks (VerifyPreview,
// VerifyPrepare; the watch while a verify runs uses the same opener). Each reads the secret before it dials.
func TestSecretOnlyInstanceCallers(t *testing.T) {
	f := &countingSecrets{}
	secretReader = f
	defer func() { secretReader = secrets.Default }()
	dsn := fmt.Sprintf("sqlserver://pgv@127.0.0.1:%d?database=master&encrypt=disable", closedPort(t))

	in := config.Instance{Name: "s1", DSNRaw: dsn, PasswordSecret: &config.PasswordSecret{Ref: "aws-secretsmanager:pgv-read", Region: "us-east-2"}}
	if in.SecretRef() == nil {
		t.Fatal("the instance's password_secret did not parse: the row tests nothing")
	}
	db, err := openBackupFilePool(context.Background(), in)
	if err != nil {
		t.Fatalf("the file check's pool with a secret-only instance: %v", err)
	}
	_ = db.Close()
	if n := f.gets.Load(); n != 1 {
		t.Errorf("the file check's pool read the password_secret %d time(s), want 1 (it dialed the dsn without the secret's password)", n)
	}

	f.gets.Store(0)
	ref := in.SecretRef()
	d := Door{Monitor: dsn, Secret: ref, Actions: dsn, Configured: true, Allow: []string{string(ActionVerifyBackup)}}
	_, _, why := VerifyPreview(context.Background(), d, "s1", "4F1A2B3C-0000-1111-2222-333344445555")
	if n := f.gets.Load(); n != 1 {
		t.Errorf("the verify preview read the password_secret %d time(s) before its dial (%q), want 1", n, why)
	}
}
