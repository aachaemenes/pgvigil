package web

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestBackupsProof is driven by scripts/proof-backups.sh (part A4): PGVIGIL_BACKUPS_PROOF_DSN is its scratch
// repository and PGVIGIL_BACKUPS_PROOF_INSTANCE the throwaway cluster's instance after the archiver failed and
// caught up; skipped without them. It calls both handlers as the API serves them, with the window parameters a
// browser sends, and runs the overview check, so a query that does not plan fails here, not on the page.
func TestBackupsProof(t *testing.T) {
	dsn, inst := os.Getenv("PGVIGIL_BACKUPS_PROOF_DSN"), os.Getenv("PGVIGIL_BACKUPS_PROOF_INSTANCE")
	if dsn == "" || inst == "" {
		t.Skip("PGVIGIL_BACKUPS_PROOF_DSN / _INSTANCE not set")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(h http.HandlerFunc, path string) map[string]*table {
		t.Helper()
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
		out := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		return out
	}
	col := func(tb *table, name string) int {
		for i, c := range tb.Columns {
			if c == name {
				return i
			}
		}
		t.Fatalf("no column %s in %v", name, tb.Columns)
		return -1
	}
	now := time.Now().UTC()
	q := url.Values{"instance": {inst}, "from": {now.Add(-time.Hour).Format(time.RFC3339)}, "to": {now.Add(time.Minute).Format(time.RFC3339)}}
	d := call(s.Backups, "/api/backups?"+q.Encode())
	if d["status"] == nil || len(d["status"].Rows) != 1 {
		t.Fatalf("status rows = %v, want 1", d["status"])
	}
	if v := d["status"].Rows[0][col(d["status"], "archiver_failing")]; v != false {
		t.Errorf("archiver_failing = %v after the catch-up, want false", v)
	}
	if d["findings"] != nil && len(d["findings"].Rows) != 0 {
		t.Errorf("findings = %v, want none after the catch-up", d["findings"].Rows)
	}
	sr := d["series"]
	if sr == nil || len(sr.Rows) == 0 {
		t.Fatalf("series is empty, want the archiver's buckets over the three reads")
	}
	var archived, failed float64
	for _, r := range sr.Rows {
		a, _ := r[col(sr, "archived")].(float64)
		f, _ := r[col(sr, "failed")].(float64)
		archived, failed = archived+a, failed+f
	}
	if archived < 2 || failed < 1 {
		t.Errorf("series sums: archived %v (want >= 2), failed %v (want >= 1)", archived, failed)
	}
	f := call(s.BackupsFleet, "/api/backups/fleet")
	if f["instances"] == nil || len(f["instances"].Rows) == 0 {
		t.Errorf("fleet rows empty")
	}
	for _, c := range overviewChecks {
		if c.name != "backups" {
			continue
		}
		rows, err := pool.Query(context.Background(), c.sql)
		if err != nil {
			t.Fatalf("overview check: %v", err)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			t.Fatalf("overview check: %v", err)
		}
		return
	}
	t.Error("no 'backups' overview check registered")
}
