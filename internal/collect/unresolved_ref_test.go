package collect

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

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// TestUnresolvedRefAddsNoStreak: a connect whose reference resolved to nothing is no connect attempt - the instance's
// connect streak stays where it was, the error keeps its kind through the connect's mark - while a dial that fails
// still counts.
func TestUnresolvedRefAddsNoStreak(t *testing.T) {
	h, restore := testHeartbeat()
	defer restore()
	in := config.Instance{Name: "u1", Engine: config.EnginePostgres, DSNRaw: "env:PGV_UNRESOLVED_UNSET_X"}
	_ = os.Unsetenv("PGV_UNRESOLVED_UNSET_X")
	for range 3 {
		_, err := Connect(context.Background(), in)
		var ue *UnresolvedRefError
		if !errors.As(err, &ue) || ue.Ref != in.DSNRaw || !strings.Contains(err.Error(), "resolved to an empty string") {
			t.Fatalf("the unset reference's connect: %v, want an UnresolvedRefError naming %s", err, in.DSNRaw)
		}
	}
	if s := h.streaks[[2]string{"u1", connectStreak}]; s != nil && s.fails != 0 {
		t.Errorf("three unresolved references left the connect streak at %d, want 0 (the server was not asked)", s.fails)
	}
	_ = InstanceConnect("u1", errors.New("dial tcp 10.0.0.9:5432: connect: connection timed out"))
	if s := h.streaks[[2]string{"u1", connectStreak}]; s == nil || s.fails != 1 {
		t.Errorf("a failed dial after them: %+v, want the streak at 1", s)
	}
}

// TestUnresolvedRefFindingOnAStore: an unset env: and a dpapi: seal that does not open here each raise the instance's
// one finding 'connection string unresolved' (pgvigil.reference_findings, 0497), once per instance though two of its
// collections met the reference, the object the reference as written and the detail its reason; no connect failure
// is recorded for them; the instance's next good run clears its finding.
func TestUnresolvedRefFindingOnAStore(t *testing.T) {
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
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	sfx := time.Now().UnixNano() % 1000000000
	env := fmt.Sprintf("PGV_REF_UNSET_%d", sfx)
	_ = os.Unsetenv(env)
	insts := []config.Instance{
		{Name: fmt.Sprintf("ref-env-%d", sfx), Engine: config.EnginePostgres, DSNRaw: "env:" + env},
		{Name: fmt.Sprintf("ref-dpapi-%d", sfx), Engine: config.EnginePostgres, DSNRaw: "dpapi:/nonexistent/pgv-moved.dpapi"},
	}
	var two []string
	for _, n := range Names() {
		if c, ok := Get(n); ok {
			if skip, _ := Gated(c, insts[0]); !skip {
				two = append(two, n)
			}
		}
		if len(two) == 2 {
			break
		}
	}
	if len(two) != 2 {
		t.Fatalf("two ungated collections: %v", two)
	}
	for _, in := range insts {
		for _, n := range two {
			if res := RunOnce(ctx, log, r, in, n); res.Err == nil {
				t.Fatalf("%s / %s: no error from an unresolved reference", in.Name, n)
			}
		}
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	for _, in := range insts {
		var id, notes, connects int
		if err := pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, in.Name).Scan(&id); err != nil {
			t.Fatalf("%s: no instance row: %v", in.Name, err)
		}
		_ = pool.QueryRow(ctx, `SELECT count(*) FILTER (WHERE note LIKE 'reference: %'), count(*) FILTER (WHERE note LIKE 'connect%') FROM pgvigil.collection_dates WHERE instance_id = $1`, id).Scan(&notes, &connects)
		if notes != 2 || connects != 0 {
			t.Errorf("%s: %d 'reference: ' runs and %d connect failures, want 2 and 0", in.Name, notes, connects)
		}
		rows, err := pool.Query(ctx, `SELECT severity, setting, value, detail FROM pgvigil.reference_findings WHERE instance_id = $1`, id)
		if err != nil {
			t.Fatalf("pgvigil.reference_findings: %v", err)
		}
		n := 0
		for rows.Next() {
			var sev, setting, value, detail string
			if err := rows.Scan(&sev, &setting, &value, &detail); err != nil {
				t.Fatal(err)
			}
			n++
			if sev != "critical" || setting != "connection string unresolved" || value != in.DSNRaw || !strings.Contains(detail, "The server was not asked") {
				t.Errorf("%s's finding: %s / %s / %q / %q", in.Name, sev, setting, value, detail)
			}
			if strings.HasPrefix(in.DSNRaw, "env:") && !strings.Contains(detail, env) {
				t.Errorf("%s's detail does not name the variable: %q", in.Name, detail)
			}
		}
		rows.Close()
		if n != 1 {
			t.Errorf("%s: %d findings, want one for the instance (two collections met the reference)", in.Name, n)
		}
	}
	var id int
	_ = pool.QueryRow(ctx, `SELECT instance_id FROM pgvigil.instances WHERE name = $1`, insts[0].Name).Scan(&id)
	if err := r.LogCollection(ctx, id, two[0], time.Now().Add(time.Second), time.Second, "ok", ""); err != nil {
		t.Fatal(err)
	}
	var left int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.reference_findings WHERE instance_id = $1`, id).Scan(&left)
	if left != 0 {
		t.Errorf("after a good run of %s: %d findings, want none (the reference resolved)", insts[0].Name, left)
	}
}
