package sched

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// lockedBuffer is a log sink the loop's goroutine and the test share.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// TestPartitionsStartAndLoop (0271, N4; ported from rel-pdeadlock): startPartitions - Run's partitions duty - makes
// next month's activity_sample partition, dropped before it, in its start pass; then, with the loop at one second, the
// same partition dropped twice more is made again twice. Each make is proven by the scheduler's OWN log line
// ('partitions ahead ... made=1'), so a partition another process made does not count, and a loop that stops after its
// first tick fails the second round. It runs on a database of its own, made from PGVIGIL_REPO_TEST_DSN's server and
// dropped at its end (another package's Migrate on the shared test database would make the month under it).
func TestPartitionsStartAndLoop(t *testing.T) {
	base := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if base == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	if strings.Contains(base, "://") {
		t.Skip("PGVIGIL_REPO_TEST_DSN is a URL: this test makes its database's DSN from the keyword form only")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = admin.Close(context.Background()) }()
	var may bool
	if err := admin.QueryRow(ctx, `SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user`).Scan(&may); err != nil {
		t.Fatal(err)
	}
	if !may {
		t.Skip("the test login may not create a database (CREATEDB): this test needs a database of its own")
	}
	db := fmt.Sprintf("pgvigil_n4s_%d_%d", os.Getpid(), time.Now().UnixNano()%1000000000)
	if _, err := admin.Exec(ctx, `CREATE DATABASE `+db); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := admin.Exec(context.Background(), `DROP DATABASE IF EXISTS `+db+` WITH (FORCE)`); err != nil {
			t.Errorf("drop the test database %s: %v", db, err)
		}
	}()
	dsn := base + " dbname=" + db
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close(context.Background()) }()
	_, monthsTo, _ := repo.AheadWindow(time.Now())
	part := "pgvigil.activity_sample_" + monthsTo.Format("200601")
	drop := func() {
		if _, err := c.Exec(ctx, `DROP TABLE IF EXISTS `+part); err != nil {
			t.Fatal(err)
		}
	}
	exists := func() bool {
		var ok bool
		if err := c.QueryRow(ctx, `SELECT to_regclass($1) IS NOT NULL`, part).Scan(&ok); err != nil {
			t.Fatal(err)
		}
		return ok
	}
	var buf lockedBuffer
	made := func() int { return strings.Count(buf.String(), " made=1 busy=") }
	drop()
	lctx, lcancel := context.WithCancel(ctx)
	defer lcancel()
	startPartitions(lctx, slog.New(slog.NewTextHandler(&buf, nil)), r, time.Second)
	if !exists() || made() != 1 {
		t.Fatalf("the start pass: %s exists %v, its lines %q", part, exists(), buf.String())
	}
	for round := 1; round <= 2; round++ {
		drop()
		ok := false
		for range 50 {
			if made() >= round+1 && exists() {
				ok = true
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		if !ok {
			t.Fatalf("round %d: %s not made again by the loop within 5 s (exists %v); its lines %q", round, part, exists(), buf.String())
		}
	}
}
