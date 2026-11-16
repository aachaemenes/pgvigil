package repo

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// TestCollectionHealthHonoursAcksOnAFreshStore (the j16 join, the lead's 02:2x call (a)): Collection Health - the page's
// pgvigil.collection_health and the Summary cell's collection_health_summary (B6G-N, 0166) - honours B24o's
// acknowledgement of an instance's collector errors (the error log page's Acknowledge: an 'ack' of check_key 'collector
// errors' whose seen_state 'log_id:<n>' marks the highest error it covers). A collection whose newest failure is at or
// under the mark stops counting - its status ok, the cell's level 0 - until a newer error comes, as DBA Dash's
// 'Acknowledge Errors' clears its Summary column. Driven by the writers the collector and the page use
// (log_collection, import_ack).
func TestCollectionHealthHonoursAcksOnAFreshStore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	r := haJoinFreshStore(t, ctx)
	name := fmt.Sprintf("chack-%d", time.Now().UnixNano()%1_000_000)
	var id int
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'auto', NULL::text, NULL::int, false, '{}'::text[], 'postgres')`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	logRun := func(ago time.Duration, status, note string) {
		t.Helper()
		if _, err := r.pool.Exec(ctx, `SELECT pgvigil.log_collection($1, 'c2', now() - make_interval(secs => $2), 10, $3, $4)`,
			id, ago.Seconds(), status, note); err != nil {
			t.Fatal(err)
		}
	}
	read := func() (status string, level, n int) {
		t.Helper()
		if err := r.pool.QueryRow(ctx, `SELECT coalesce((SELECT c.status FROM pgvigil.collection_health(now() - interval '1 day') c
		                                                 WHERE c.instance_id = $1 AND c.collection = 'c2'), 'absent'),
		                                       coalesce((SELECT s.level FROM pgvigil.collection_health_summary() s WHERE s.instance_id = $1), -1),
		                                       coalesce((SELECT s.n FROM pgvigil.collection_health_summary() s WHERE s.instance_id = $1), -1)`, id).
			Scan(&status, &level, &n); err != nil {
			t.Fatal(err)
		}
		return
	}
	logRun(20*time.Minute, "error", "c2 failed")
	logRun(10*time.Minute, "error", "c2 failed again")
	if st, lv, n := read(); st != "warning" || lv != 1 || n != 1 {
		t.Fatalf("before: c2 %q, the cell's level %d and count %d - want warning, 1, 1 (two failures in a row, never succeeded)", st, lv, n)
	}
	var mark int64
	if err := r.pool.QueryRow(ctx, `SELECT max(log_id) FROM pgvigil.collection_log WHERE instance_id = $1`, id).Scan(&mark); err != nil {
		t.Fatal(err)
	}
	var outcome string
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_ack(now(), jsonb_build_object('op', 'add', 'ui_user', 'chack', 'kind', 'ack',
	  'instance_id', $1::int, 'instance_name', $2::text, 'check_key', 'collector errors', 'seen_state', 'log_id:' || $3::bigint,
	  'until_change', true))->>'outcome'`, id, name, mark).Scan(&outcome); err != nil || outcome != "done" {
		t.Fatalf("the acknowledgement up to log_id %d: %q, %v", mark, outcome, err)
	}
	if st, lv, n := read(); st != "ok" || lv != 0 || n != 0 {
		t.Errorf("acknowledged up to log_id %d: c2 %q, the cell's level %d and count %d - want ok, 0, 0 (nothing counts until a newer error)", mark, st, lv, n)
	}
	logRun(0, "error", "c2 failed after the acknowledgement")
	if st, lv, _ := read(); (st != "warning" && st != "critical") || lv < 1 {
		t.Errorf("a newer error: c2 %q, the cell's level %d - want it counted again (warning or critical, level 1 or more)", st, lv)
	}
}
