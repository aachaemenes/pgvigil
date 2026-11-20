package mssql

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// TestUnresolvedRefFindingSQLServerOnAStore: a SQL Server instance whose reference resolves to nothing - an unset env:
// and a dpapi: seal that does not open here - is never asked: its runs carry the unresolved-reference kind (so the
// connect streak skips them), no connect failure is recorded, the instance's one finding 'connection string
// unresolved' stands (pgvigil.reference_findings, 0497) though two collections met the reference, and a good run
// clears it. No SQL Server is needed: nothing is dialled.
func TestUnresolvedRefFindingSQLServerOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	sfx := time.Now().UnixNano() % 1000000000
	env := fmt.Sprintf("PGV_MSREF_UNSET_%d", sfx)
	_ = os.Unsetenv(env)
	insts := []config.Instance{
		{Name: fmt.Sprintf("msref-env-%d", sfx), Engine: config.EngineSQLServer, DSNRaw: "env:" + env},
		{Name: fmt.Sprintf("msref-dpapi-%d", sfx), Engine: config.EngineSQLServer, DSNRaw: "dpapi:/nonexistent/pgv-ms-moved.dpapi"},
	}
	var two []string
	for _, n := range Names() {
		c, ok := Get(n)
		if !ok {
			continue
		}
		if ic, isIC := c.(InstanceCollector); isIC {
			if want, _ := ic.Wants(insts[0]); !want {
				continue
			}
		}
		two = append(two, n)
		if len(two) == 2 {
			break
		}
	}
	if len(two) != 2 {
		t.Fatalf("two SQL Server collections that run on a plain instance: %v", two)
	}
	for _, in := range insts {
		for _, n := range two {
			res := RunOnce(ctx, log, r, in, n)
			var ue *collect.UnresolvedRefError
			if !errors.As(res.Err, &ue) || ue.Ref != in.DSNRaw {
				t.Fatalf("%s / %s: %v, want the unresolved-reference kind naming %s", in.Name, n, res.Err, in.DSNRaw)
			}
		}
	}
	for _, in := range insts {
		var id, notes, connects, findings int
		if err := pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, in.Name).Scan(&id); err != nil {
			t.Fatalf("%s: no instance row: %v", in.Name, err)
		}
		_ = pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE note LIKE 'reference: %'), count(*) FILTER (WHERE note LIKE 'connect%') FROM pgvigil.collection_dates WHERE instance_id = $1`, id).Scan(&notes, &connects)
		if notes != 2 || connects != 0 {
			t.Errorf("%s: %d 'reference: ' runs and %d connect failures, want 2 and 0", in.Name, notes, connects)
		}
		var value, detail string
		if err := pool.QueryRow(ctx, `SELECT count(*) OVER (), value, detail FROM pgvigil.reference_findings WHERE instance_id = $1`, id).Scan(&findings, &value, &detail); err != nil {
			t.Fatalf("%s's finding in pgvigil.reference_findings: %v", in.Name, err)
		}
		if findings != 1 || value != in.DSNRaw || !strings.Contains(detail, "The server was not asked") {
			t.Errorf("%s: %d finding(s), object %q, detail %q - want one, the reference, 'The server was not asked'", in.Name, findings, value, detail)
		}
	}
	var id int
	_ = pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, insts[1].Name).Scan(&id)
	if err := r.LogCollection(ctx, id, two[0], time.Now().Add(time.Second), time.Second, "ok", ""); err != nil {
		t.Fatal(err)
	}
	var left int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.reference_findings WHERE instance_id = $1`, id).Scan(&left)
	if left != 0 {
		t.Errorf("after a good run of %s: %d findings, want none", insts[1].Name, left)
	}
}
