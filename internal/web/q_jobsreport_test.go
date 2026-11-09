package web

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestJobsReportProof is driven by scripts/proof-jobs-report.sh: PGVIGIL_JOBS_PROOF_DSN is its scratch
// repository and PGVIGIL_JOBS_PROOF_INSTANCE the seeded instance; skipped without them. It calls the handler
// and the overview as the API serves them and checks the shapes the proof's header names.
func TestJobsReportProof(t *testing.T) {
	dsn, inst := os.Getenv("PGVIGIL_JOBS_PROOF_DSN"), os.Getenv("PGVIGIL_JOBS_PROOF_INSTANCE")
	if dsn == "" || inst == "" {
		t.Skip("PGVIGIL_JOBS_PROOF_DSN / PGVIGIL_JOBS_PROOF_INSTANCE not set")
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
			// the overview is one table
			var one table
			if err2 := json.Unmarshal(rec.Body.Bytes(), &one); err2 != nil {
				t.Fatalf("%s: %v", path, err)
			}
			out["overview"] = &one
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

	d := call(s.JobsReport, "/api/jobsreport?instance="+inst+"&from=2000-01-01T00:00:00Z&to=2000-01-20T00:00:00Z")
	if len(d["trend"].Rows) != 0 {
		t.Errorf("a window with no runs has %d trend rows", len(d["trend"].Rows))
	}
	d = call(s.JobsReport, "/api/jobsreport?instance="+inst+"&from="+os.Getenv("PGVIGIL_JOBS_PROOF_FROM"))
	jobs, checks := d["jobs"], d["checks"]
	t.Logf("instance: %d jobs, %d checks, %d trend rows", len(jobs.Rows), len(checks.Rows), len(d["trend"].Rows))
	if len(jobs.Rows) != 7 {
		t.Errorf("jobs = %d, want 7", len(jobs.Rows))
	}
	if len(checks.Rows) != 4 {
		t.Errorf("checks = %d, want 4", len(checks.Rows))
	}
	if len(d["trend"].Rows) == 0 {
		t.Error("no trend rows over the seeded window")
	}
	// the problem jobs sort first among the present ones
	name := col(jobs, "job_name")
	first := map[string]bool{}
	for _, r := range jobs.Rows[:4] {
		first[r[name].(string)] = true
	}
	for _, n := range []string{"fails-3", "slow", "missed", "agent-down"} {
		if !first[n] {
			t.Errorf("%s is not among the first four rows: %v", n, first)
		}
	}

	f := call(s.JobsReport, "/api/jobsreport")
	c := f["counts"]
	t.Logf("fleet: counts %v, %d jobs", c.Rows[0], len(f["jobs"].Rows))
	if len(f["jobs"].Rows) != 4 {
		t.Errorf("fleet problem jobs = %d, want 4", len(f["jobs"].Rows))
	}
	want := map[string]int64{"jobs": 6, "failing": 1, "missed": 2, "over_average": 1, "instances": 1}
	for k, v := range want {
		if got, _ := c.Rows[0][col(c, k)].(float64); int64(got) != v {
			t.Errorf("fleet %s = %v, want %d", k, c.Rows[0][col(c, k)], v)
		}
	}

	o := call(s.overview, "/api/overview")["overview"]
	n, id := 0, col(o, "instance_id")
	for _, r := range o.Rows {
		if r[col(o, "check_group")] == "jobs report" {
			n++
			if v, _ := r[id].(float64); strconv.Itoa(int(v)) != inst {
				t.Errorf("an overview row of instance %v", r[id])
			}
		}
		if r[col(o, "check_name")] == "check could not run" {
			t.Errorf("an overview check failed: %v", r)
		}
	}
	t.Logf("overview: %d 'jobs report' rows", n)
	if n != 4 {
		t.Errorf("overview 'jobs report' rows = %d, want 4", n)
	}
}
