package web

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
)

// TestQueuedRemoteRefusedOnAStore (review B S4): queue mode's refusal of a remote instance - 403 with R13's words, the
// refusal audited in the run log as the direct path audits it (op, the instance, outcome refused, the words as its
// detail) - and nothing for an instance a collector holds.
func TestQueuedRemoteRefusedOnAStore(t *testing.T) {
	ctx, pool := remoteStore(t)
	s := &Server{log: discardLog(), pool: pool}
	s.actions = &Actions{s: s, audit: pool}
	ds, r := remoteSet()
	s.storeDoors(ds)
	tool := findTool("pg_settings_changed")
	if tool == nil {
		t.Fatal("no pg_settings_changed tool")
	}
	user := "u-rq-" + time.Now().Format("150405.000000")
	t.Cleanup(func() { _, _ = pool.Exec(ctx, `DELETE FROM pgvigil.custom_report_log WHERE ui_user = $1`, user) })
	const pg = "site1/pg01"
	w := httptest.NewRecorder()
	if !s.queuedRemoteRefused(w, httptest.NewRequest(http.MethodPost, "/api/community/run", nil), "community_run", user, pg, communityBody{Tool: tool.ID}, tool) {
		t.Fatal("a remote instance's queued run was not refused")
	}
	want := actions.RemoteOff(pg, r.from())
	if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), want) {
		t.Errorf("the refusal: %d %s, want 403 with %q", w.Code, w.Body.String(), want)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.custom_report_log WHERE ui_user = $1 AND op = 'community_run' AND instance = $2
	    AND outcome = 'refused' AND detail = $3`, user, pg, want).Scan(&n); err != nil || n != 1 {
		t.Errorf("the refusal's audit rows: %d %v, want 1", n, err)
	}
	w = httptest.NewRecorder()
	if s.queuedRemoteRefused(w, httptest.NewRequest(http.MethodPost, "/api/community/run", nil), "community_run", user, "f", communityBody{Tool: tool.ID}, tool) {
		t.Errorf("an instance a collector holds was refused: %d %s", w.Code, w.Body.String())
	}
}
