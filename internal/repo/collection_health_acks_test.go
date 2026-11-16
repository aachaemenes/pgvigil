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
// errors' whose seen_state 'log_id:<n>' marks the highest error it covers). The errors at or under the mark stop
// counting - the status ok, the cell's level 0 - and never count again: the lead's 02:5x A5 call, DBA Dash's count from
// the acknowledgement, so a newer error starts a new streak (one in a row: warning, level 1), and the rate counts only
// the failed and partial runs logged past the mark (review A #2: partial runs after an acknowledged failure; #6: an
// older-started run logged after the mark). Driven by the writers the collector and the page use (log_collection,
// import_ack; the beat's hourly rows through import_collection_health).
func TestCollectionHealthHonoursAcksOnAFreshStore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	r := haJoinFreshStore(t, ctx)
	// one instance per case (the cell is the instance's): its id and name
	inst := func(tag string) (int, string) {
		t.Helper()
		name := fmt.Sprintf("chack%s-%d", tag, time.Now().UnixNano()%1_000_000)
		var id int
		if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'auto', NULL::text, NULL::int, false, '{}'::text[], 'postgres')`, name).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id, name
	}
	logRun := func(id int, ago time.Duration, status, note string) {
		t.Helper()
		if _, err := r.pool.Exec(ctx, `SELECT pgvigil.log_collection($1, 'c2', now() - make_interval(secs => $2), 10, $3, $4)`,
			id, ago.Seconds(), status, note); err != nil {
			t.Fatal(err)
		}
	}
	read := func(id int) (status string, cf, level, n int) {
		t.Helper()
		if err := r.pool.QueryRow(ctx, `SELECT coalesce(c.status, 'absent'), coalesce(c.consecutive_failures, -1),
		                                       coalesce((SELECT s.level FROM pgvigil.collection_health_summary() s WHERE s.instance_id = $1), -1),
		                                       coalesce((SELECT s.n FROM pgvigil.collection_health_summary() s WHERE s.instance_id = $1), -1)
		                                  FROM (SELECT 1) one
		                                  LEFT JOIN pgvigil.collection_health(now() - interval '1 day') c ON c.instance_id = $1 AND c.collection = 'c2'`, id).
			Scan(&status, &cf, &level, &n); err != nil {
			t.Fatal(err)
		}
		return
	}
	// ack: the error log page's Acknowledge of every error logged so far for the instance
	ack := func(id int, name string) {
		t.Helper()
		var mark int64
		if err := r.pool.QueryRow(ctx, `SELECT max(log_id) FROM pgvigil.collection_log WHERE instance_id = $1`, id).Scan(&mark); err != nil {
			t.Fatal(err)
		}
		var outcome string
		if err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_ack(now(), jsonb_build_object('op', 'add', 'ui_user', 'chack', 'kind', 'ack',
		  'instance_id', $1::int, 'instance_name', $2::text, 'check_key', 'collector errors', 'seen_state', 'log_id:' || $3::bigint,
		  'until_change', true))->>'outcome'`, id, name, mark).Scan(&outcome); err != nil || outcome != "done" {
			t.Fatalf("%s: the acknowledgement up to log_id %d: %q, %v", name, mark, outcome, err)
		}
	}

	// 1. two failures, the acknowledgement, a newer error: one in a row, warning - never the three of the run status
	id, name := inst("a")
	logRun(id, 20*time.Minute, "error", "c2 failed")
	logRun(id, 10*time.Minute, "error", "c2 failed again")
	if st, cf, lv, n := read(id); st != "warning" || cf != 2 || lv != 1 || n != 1 {
		t.Fatalf("before: c2 %q, %d in a row, the cell's level %d and count %d - want warning, 2, 1, 1 (two failures in a row, never succeeded)", st, cf, lv, n)
	}
	ack(id, name)
	if st, cf, lv, n := read(id); st != "ok" || cf != 0 || lv != 0 || n != 0 {
		t.Errorf("acknowledged: c2 %q, %d in a row, the cell's level %d and count %d - want ok, 0, 0, 0 (nothing counts until a newer error)", st, cf, lv, n)
	}
	logRun(id, 0, "error", "c2 failed after the acknowledgement")
	if st, cf, lv, n := read(id); st != "warning" || cf != 1 || lv != 1 || n != 1 {
		t.Errorf("a newer error: c2 %q, %d in a row, the cell's level %d and count %d - want warning, 1, 1, 1 (a new streak from the acknowledgement: the two before it never count again)", st, cf, lv, n)
	}

	// 2. review A #2: an acknowledged failure, then 20 partial runs (the beat's hour: 21 known runs, 20 partial) - the
	// rate's warning arm counts the partial runs past the mark: warning, as with no acknowledgement
	id, name = inst("b")
	logRun(id, 50*time.Minute, "error", "c2 failed")
	ack(id, name)
	if _, err := r.pool.Exec(ctx, `SELECT pgvigil.log_collection($1, 'c2', now() - make_interval(mins => g), 10, 'partial', 'c2 partial')
	                                 FROM generate_series(40, 21, -1) g`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := r.pool.Exec(ctx, `SELECT pgvigil.import_collection_health('chack-beat', jsonb_build_object('health', jsonb_build_array(jsonb_build_object(
	  'instance', $1::text, 'collection', 'c2', 'hour', date_trunc('hour', now() - interval '30 minutes'), 'runs', 21, 'ok', 0, 'partial', 20,
	  'error', 1, 'skipped', 0, 'rows', 0, 'dur_ms_sum', 210, 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0))))`, name); err != nil {
		t.Fatal(err)
	}
	if st, cf, lv, _ := read(id); st != "warning" || cf != 0 || lv != 1 {
		t.Errorf("an acknowledged failure, then 20 partial runs of 21: c2 %q, %d in a row, the cell's level %d - want warning, 0, 1 (the rate's partial runs past the mark)", st, cf, lv)
	}

	// 3. review A #6: an older-started run logged after the mark counts (its run status never moves: an older run
	// written late), as one in a row past the mark
	id, name = inst("c")
	logRun(id, 20*time.Minute, "error", "c2 failed")
	logRun(id, 10*time.Minute, "error", "c2 failed again")
	ack(id, name)
	logRun(id, 30*time.Minute, "error", "c2 started before the others, logged after the acknowledgement")
	if st, cf, lv, _ := read(id); st != "warning" || cf != 1 || lv != 1 {
		t.Errorf("an older-started run logged after the mark: c2 %q, %d in a row, the cell's level %d - want warning, 1, 1", st, cf, lv)
	}
}
