package remote

import (
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// The lead's 11:3x named check (1): a planted statement, query and error-log message on a remote instance appear in no
// byte of the written bundle (each file gunzipped) or of the state folder, under hash and under none.
func TestRemoteBundleHoldsNoText(t *testing.T) {
	for _, mode := range []string{"hash", "none"} {
		t.Run(mode, func(t *testing.T) {
			ctx := context.Background()
			stateDir, out := t.TempDir(), t.TempDir()
			st, _, err := LoadState(stateDir)
			if err != nil {
				t.Fatal(err)
			}
			s := NewStore(st, StoreOptions{Outbox: out, Site: "site1", Collector: "coll1", QueryText: mode, PgvigilVersion: "v",
				SchemaLevel: "0329_remote", Interval: 5 * time.Minute, Now: (&clock{t: t0}).now})
			pg, _ := s.EnsureInstance(ctx, "pg1", "onprem", "18.1", 180001, false, nil)
			ms, _ := s.EnsureInstanceEngine(ctx, "sqlserver", inst.Name, "onprem", "16.0", 16, false, nil)
			planted := []string{"PLANTED-QUERY-7731", "PLANTED-MESSAGE-5512", "PLANTED-STATEMENT-9904"}
			if err := s.Import(ctx, pg, "activity", t0, []map[string]any{{"kind": "session", "pid": 4242, "datname": "app", "state": "active",
				"query": "SELECT * FROM t WHERE secret = '" + planted[0] + "'"}}); err != nil {
				t.Fatal(err)
			}
			if err := s.Import(ctx, ms, "mssql_errorlog", t0, []map[string]any{
				{"kind": "line", "log_at": t0, "line_key": "k1", "logged_local": "2026-11-16T09:50:00", "process": "Logon",
					"message": "Login failed for user '" + planted[1] + "'."},
				{"kind": "state", "reader": "errorlog", "state": "read", "note": nil}}); err != nil {
				t.Fatal(err)
			}
			if err := s.Import(ctx, pg, "logs", t0, []map[string]any{{"kind": "event", "logged_at": t0, "message": "duration: 3 ms",
				"statement": "UPDATE t SET v = '" + planted[2] + "'"}}); err != nil {
				t.Fatal(err)
			}
			for _, n := range []string{"pg1", inst.Name} {
				if _, err := s.CloseInstance(n, t1, nil, format.Heartbeat{Host: "h", Started: t0, At: t1}); err != nil {
					t.Fatal(err)
				}
			}
			for _, root := range []string{out, stateDir} {
				err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
					if err != nil || d.IsDir() {
						return err
					}
					b, err := os.ReadFile(p)
					if err != nil {
						return err
					}
					if strings.HasSuffix(p, ".gz") {
						zr, err := gzip.NewReader(bytes.NewReader(b))
						if err != nil {
							return err
						}
						if b, err = io.ReadAll(zr); err != nil {
							return err
						}
					}
					for _, pl := range planted {
						if bytes.Contains(b, []byte(pl)) {
							t.Errorf("%s holds %s", p, pl)
						}
					}
					return nil
				})
				if err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
