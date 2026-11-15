package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestBackupLocWiringOnAStore (task 301's wiring, scripts/inv-301-wiring.patch): on a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) the Summary's Backup FULL cell follows mssql_backups alone - its run
// failed and mssql_backup_files fresh reads 'failed', never 'ok' (the design pass's F1) - and counts the new findings by
// the type their names carry; the Detail rows of /api/mssql/backups carry each database's 'to' cells and DBA Dash's flags.
func TestBackupLocWiringOnAStore(t *testing.T) {
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
	id, drop := seedBackupLocations(ctx, t, pool, fmt.Sprintf("bkwire-%d", time.Now().UnixNano()%1000000000))
	defer drop()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status, note)
	                              VALUES ($1, 'mssql_backups', now(), 'error', 'the run hit its 120 s timeout'), ($1, 'mssql_backup_files', now(), 'ok', NULL)`, id); err != nil {
		t.Fatal(err)
	}
	type cell struct {
		state      string
		crit, warn int
		detail     []string
	}
	cells := func() map[string]cell {
		t.Helper()
		rs, err := pool.Query(ctx, sqlMSSQLSummaryCells, `{}`, 3600)
		if err != nil {
			t.Fatal(err)
		}
		defer rs.Close()
		out := map[string]cell{}
		for rs.Next() {
			var iid, crit, warn int
			var key, state string
			var sampled bool
			var value, errText *string
			var detail []string
			var readAt, since *time.Time
			if err := rs.Scan(&iid, &key, &state, &sampled, &crit, &warn, &value, &detail, &readAt, &errText, &since); err != nil {
				t.Fatal(err)
			}
			if iid == id {
				out[key] = cell{state, crit, warn, detail}
			}
		}
		if err := rs.Err(); err != nil {
			t.Fatal(err)
		}
		return out
	}
	c := cells()
	if c["full"].state != "failed" || c["log"].state != "failed" {
		t.Errorf("mssql_backups failed, mssql_backup_files fresh: full %q, log %q - want failed (the new collection never turns the cell green)", c["full"].state, c["log"].state)
	}
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.collection_dates SET status = 'ok', note = NULL WHERE instance_id = $1 AND collection = 'mssql_backups'`, id); err != nil {
		t.Fatal(err)
	}
	c = cells()
	if c["full"].state != "ok" || c["full"].warn != 1 || !strings.Contains(strings.Join(c["full"].detail, " "), "a full backup on the volume of the database's own files: lnx") {
		t.Errorf("full: %+v - want ok with the same-volume warning", c["full"])
	}
	if c["log"].warn != 1 || !strings.Contains(strings.Join(c["log"].detail, " "), "log backups to two destinations: lnx") {
		t.Errorf("log: %+v - want the two-destinations warning", c["log"])
	}
	if c["diff"].warn != 0 {
		t.Errorf("diff: %+v - want no warning", c["diff"])
	}

	rs, err := pool.Query(ctx, sqlMSSQLBackups, id, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer rs.Close()
	got := map[string]string{}
	for rs.Next() {
		v, err := rs.Values()
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]any{}
		for i, f := range rs.FieldDescriptions() {
			m[f.Name] = v[i]
		}
		got[fmt.Sprint(m["database_name"])] = fmt.Sprint(m["full_to"], " | ", m["log_to"], " | ", m["full_checksum"], " ", m["full_compressed"], " ", m["full_encrypted"], " ", m["full_algorithm"])
	}
	if err := rs.Err(); err != nil {
		t.Fatal(err)
	}
	if want := `D:\temp\ | \\nas01\sql\app\ | true true false ZSTD`; got["app"] != want {
		t.Errorf("app's Detail cells: %q, want %q", got["app"], want)
	}
	if want := `/var/opt/mssql/data/ | <nil> | true true false <nil>`; got["lnx"] != want {
		t.Errorf("lnx's Detail cells: %q, want %q", got["lnx"], want)
	}
}
