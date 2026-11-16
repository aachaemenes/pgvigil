package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestThresholdsInForceFallbackOnAStore (ST5b, the build review's M2): Thresholds in force reads the Admin > Instances
// source through admin_instance_settings(); where that cannot be called (a store before 'pgvigil migrate', 42883, or a
// serve login without EXECUTE, 42501) the inforce part alone is read without it and says so in inforce_note - the
// rest of GET /api/alertrules is answered as before. Any other error stays the whole answer's.
func TestThresholdsInForceFallbackOnAStore(t *testing.T) {
	for code, want := range map[string]bool{"42883": true, "42501": true, "XX000": false, "42P01": false} {
		if got := inforceNoPage(&pgconn.PgError{Code: code}) != ""; got != want {
			t.Errorf("SQLSTATE %s: a fallback %v, want %v", code, got, want)
		}
	}
	if inforceNoPage(nil) != "" || inforceNoPage(errors.New("connection reset")) != "" {
		t.Error("a nil or a non-SQL error takes the fallback")
	}
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
	s := &Server{pool: pool, log: discardLog()}
	for name, q := range map[string]string{"with the page's source": sqlThresholdsInForce, "without it": sqlThresholdsInForceNoPage} {
		if _, err := s.query(ctx, q, []string{}); err != nil {
			t.Errorf("Thresholds in force %s on the store: %v", name, err)
		}
	}
	get := func() (int, map[string]any) {
		t.Helper()
		w := httptest.NewRecorder()
		s.AlertRules(w, httptest.NewRequest(http.MethodGet, "/api/alertrules", nil))
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}
	// the page's source read through a function this store does not have: the 42883 of a store before 0263
	was := sqlThresholdsInForce
	t.Cleanup(func() { sqlThresholdsInForce = was })
	sqlThresholdsInForce = sqlThresholdsInForceHead +
		strings.Replace(inforcePageJoin, "pgvigil.admin_instance_settings()", "pgvigil.admin_instance_settings_st5b_none()", 1) + sqlThresholdsInForceTail
	code, out := get()
	if code != http.StatusOK {
		t.Fatalf("GET alertrules without the page's function: %d %v", code, out)
	}
	for _, k := range []string{"rules", "state", "log", "catalog", "sender", "inforce"} {
		if _, ok := out[k]; !ok {
			t.Errorf("part %s missing: %v", k, out)
		}
	}
	if note, _ := out["inforce_note"].(string); !strings.HasPrefix(note, "Admin > Instances is not read here: this repository has no pgvigil.admin_instance_settings() yet") {
		t.Errorf("inforce_note: %q", note)
	}
	sqlThresholdsInForce = was
	if code, out := get(); code != http.StatusOK || out["inforce_note"] != nil {
		t.Errorf("GET alertrules on a migrated store: %d, note %v (want 200, no note)", code, out["inforce_note"])
	}
}
