package dbadash

import (
	"context"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPgvigilInstanceNeverRead runs the import's instance step against a migrated pgvigil repository (skipped without
// PGVIGIL_IMPORT_TEST_REPO, a DSN its owner may write; the join fold's box run sets it to a throwaway database). A row
// Admin > Instances made and no read reached - whatever the platform the page gave it - takes DBA Dash's version, and
// its platform only when the page left it 'auto'; its first_seen moves to that first read (0122's admin_first_read);
// a row already read is used as it is; a name stored as PostgreSQL is a skip (the join's w9e, finding 4; pgvigil
// import dbadash itself is not run end to end here: its proof needs a DBA Dash repository on Windows).
func TestPgvigilInstanceNeverRead(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_IMPORT_TEST_REPO")
	if dsn == "" {
		t.Skip("PGVIGIL_IMPORT_TEST_REPO not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	names := []string{"nr-auto", "nr-onprem", "nr-read", "nr-pg"}
	clean := func() {
		if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.instances WHERE name = ANY($1)`, names); err != nil {
			t.Fatal(err)
		}
	}
	clean()
	defer clean()
	// as the page's add makes them (0122): no version; one already read (a version); one of the other engine
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.instances (name, platform, engine, tags, first_seen) VALUES
	    ('nr-auto', 'auto', 'sqlserver', '{}', now() - interval '1 day'), ('nr-onprem', 'onprem', 'sqlserver', '{}', now() - interval '1 day'),
	    ('nr-pg', 'auto', 'postgres', '{}', now() - interval '1 day')`); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.instances (name, platform, engine, tags, server_version, first_seen)
	    VALUES ('nr-read', 'onprem', 'sqlserver', '{}', '15.0.4430.1', now() - interval '1 day')`); err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	src := srcInstance{Version: "16.0.4105.2", Edition: 2}
	type row struct {
		platform, version string
		moved             bool
	}
	read := func(name string) row {
		var r row
		if err := pool.QueryRow(ctx, `SELECT platform, coalesce(server_version, ''), first_seen > now() - interval '1 hour' FROM pgvigil.instances WHERE name = $1`, name).
			Scan(&r.platform, &r.version, &r.moved); err != nil {
			t.Fatal(name, err)
		}
		return r
	}
	for _, c := range []struct {
		name string
		want row
	}{
		{"nr-auto", row{"sqlserver", "16.0.4105.2", true}},
		{"nr-onprem", row{"onprem", "16.0.4105.2", true}}, // fold 1 left it unread: its platform was not 'auto'
		{"nr-read", row{"onprem", "15.0.4430.1", false}},
	} {
		if _, skip, err := pgvigilInstance(ctx, log, pool, c.name, src, false); err != nil || skip != "" {
			t.Fatalf("%s: skip %q err %v", c.name, skip, err)
		}
		if got := read(c.name); got != c.want {
			t.Errorf("%s: platform, version, first_seen moved = %+v, want %+v", c.name, got, c.want)
		}
	}
	if _, skip, err := pgvigilInstance(ctx, log, pool, "nr-pg", src, false); err != nil || skip == "" {
		t.Fatalf("a name stored as PostgreSQL: skip %q err %v (want a skip)", skip, err)
	}
	// a dry run writes nothing
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET server_version = NULL, platform = 'onprem' WHERE name = 'nr-onprem'`); err != nil {
		t.Fatal(err)
	}
	if _, _, err := pgvigilInstance(ctx, log, pool, "nr-onprem", src, true); err != nil || read("nr-onprem").version != "" {
		t.Fatalf("a dry run wrote the version: %v %+v", err, read("nr-onprem"))
	}
}
