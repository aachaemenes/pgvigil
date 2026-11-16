package ingest

// The FOLD 1+2 rows that call what the fold adds (CheckIngestLogin, Ingester.MaxBundle): their red is their absence, so
// the box job's red step runs without this file.

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/export"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// TestIngestLoginOnAStore (FOLD 1 B5 as answered): ingest's login is refused in words when it is the repository's
// owner, a superuser, a member of pgvigil_collector or not a member of pgvigil_ingest; a login in pgvigil_ingest
// passes, and a site round runs AS it (the join draft's ingest door applied)
func TestIngestLoginOnAStore(t *testing.T) {
	f := newFold1(t, "f1il")
	if !f.drafted() {
		t.Skip("scripts/remote-join-draft.sql is not applied on this store")
	}
	t.Cleanup(f.cleanup)
	pc, err := pgx.ParseConfig(os.Getenv("PGVIGIL_REPO_TEST_DSN"))
	if err != nil {
		t.Fatal(err)
	}
	sfx := time.Now().UnixNano() % 1000000000
	login := func(name, opts string) *pgxpool.Pool {
		t.Helper()
		if err := f.exec(fmt.Sprintf(`CREATE ROLE %s LOGIN %s`, name, opts)); err != nil {
			t.Skipf("this store's login may not make a login role: %v", err)
		}
		t.Cleanup(func() { _ = f.exec(fmt.Sprintf(`DROP ROLE IF EXISTS %s`, name)) })
		p, err := pgxpool.New(f.ctx, fmt.Sprintf("host=%s port=%d user=%s dbname=%s", pc.Host, pc.Port, name, pc.Database))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(p.Close)
		return p
	}
	for _, c := range []struct {
		what string
		pool *pgxpool.Pool
		want string
	}{
		{"the store's own login (the owner)", f.pool, "owner"},
		{"a superuser", login(fmt.Sprintf("f1su_%d", sfx), "SUPERUSER"), "superuser"},
		{"a collector login", login(fmt.Sprintf("f1co_%d", sfx), "IN ROLE pgvigil_collector"), "pgvigil_collector"},
		{"a login in no role", login(fmt.Sprintf("f1no_%d", sfx), ""), "pgvigil_ingest"},
	} {
		if err := CheckIngestLogin(f.ctx, c.pool); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want a refusal naming %q", c.what, err, c.want)
		}
	}
	ing := login(fmt.Sprintf("f1in_%d", sfx), "IN ROLE pgvigil_ingest")
	if err := CheckIngestLogin(f.ctx, ing); err != nil {
		t.Fatalf("a login in pgvigil_ingest: %v", err)
	}
	root := t.TempDir()
	writeAGBundle(t, root, f.site, 1, time.Now().UTC().Add(-2*time.Hour).Truncate(time.Minute))
	s := Site{Name: f.site, Drop: export.NewFolder(root), ExpectedEvery: 5 * time.Minute, GapWait: 15 * time.Minute, Collectors: map[string][][]byte{"c1": nil}}
	if err := (PoolHub{Pool: ing}).SyncSites(f.ctx, []Site{s}); err != nil {
		t.Fatalf("SyncSites as the ingest login: %v", err)
	}
	res, held, err := SiteRound(f.ctx, ing, s, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil || held || res.Loaded != 1 {
		t.Errorf("a site round as the ingest login: held %v, %+v, %v - want 1 loaded", held, res, err)
	}
}

// TestRoundBundleCap (FOLD 2 S2): a bundle whose views' raw bytes sum over the per-bundle cap is set aside 'too_big'
// before any view file is fetched
func TestRoundBundleCap(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	r := d.write("st1", 1, "mssql_activity", nil)
	in := d.ingester(h, r.End.Add(time.Hour), nil)
	in.MaxBundle = 10
	round(t, in)
	eq(t, "over the cap", h.markKinds(), []string{"st1/1:" + format.KindTooBig})
	eq(t, "nothing loaded", len(h.loads), 0)
}
