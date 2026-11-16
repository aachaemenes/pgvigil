package repo

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// TestCollectionHealthHonoursAcksOnAFreshStore: Collection Health reads the instance's live acknowledgement of its
// collector errors (the Collector errors page's Acknowledge: an 'ack' of check_key 'collector errors' whose seen_state
// 'log_id:<n>' marks the highest error it covers) as DBA Dash 4.25.0 reads its ErrorAckDate:
//   - the Summary's judgement (judged_status / judged_failures, read by collection_health_summary): the stored failures in
//     a row count only once a failure is newer than the acknowledgement - a collection_log row above the mark, since the
//     last success - and then whole (Summary_Upd.sql L123); a purged row falls back to the time (the last failure at or
//     after the acknowledgement); the rate's window starts at the acknowledgement's hour rounded up, or 24 hours back,
//     whichever is later (CollectionHealthRateFrom.sql L10-18);
//   - the page's values (status, consecutive_failures, runs, failed) stay raw, as DBA Dash's report keeps them
//     (CollectionHealth_Get.sql L232, L266); a row whose failures in a row the acknowledgement leaves out says so
//     ('acknowledged at <time> by <user>: n in a row before it').
//
// Driven by the writers the collector and the page use (log_collection, import_ack, import_collection_health,
// import_collection_health_threshold). One instance per case: the Summary's cell is the instance's.
func TestCollectionHealthHonoursAcksOnAFreshStore(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	r := haJoinFreshStore(t, ctx)
	inst := func(tag string) (int, string) {
		t.Helper()
		name := fmt.Sprintf("chack%s-%d", tag, time.Now().UnixNano()%1_000_000)
		var id int
		if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'auto', NULL::text, NULL::int, false, '{}'::text[], 'postgres')`, name).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return id, name
	}
	logRun := func(id int, ago time.Duration, status string) {
		t.Helper()
		if _, err := r.pool.Exec(ctx, `SELECT pgvigil.log_collection($1, 'c2', now() - make_interval(secs => $2), 10, $3, $4)`,
			id, ago.Seconds(), status, "c2 "+status); err != nil {
			t.Fatal(err)
		}
	}
	// hour: one hourly row of c2 through the beat's import - the hour that begins hoursBack whole hours before this one
	hour := func(name string, hoursBack, runs, ok, partial, failed int) {
		t.Helper()
		if _, err := r.pool.Exec(ctx, `SELECT pgvigil.import_collection_health('chack-beat', jsonb_build_object('health', jsonb_build_array(jsonb_build_object(
		  'instance', $1::text, 'collection', 'c2', 'hour', date_trunc('hour', now()) - make_interval(hours => $2), 'runs', $3::int, 'ok', $4::int,
		  'partial', $5::int, 'error', $6::int, 'skipped', 0, 'rows', 0, 'dur_ms_sum', 10 * $3::int, 'dur_ms_max', 10, 'over_half', 0, 'over_interval', 0))))`,
			name, hoursBack, runs, ok, partial, failed); err != nil {
			t.Fatal(err)
		}
	}
	// ack: the Collector errors page's Acknowledge of every error logged so far for the instance, made at the given time
	ack := func(id int, name, at string) int64 {
		t.Helper()
		var ackID int64
		if err := r.pool.QueryRow(ctx, `SELECT (pgvigil.import_ack(`+at+`, jsonb_build_object('op', 'add', 'ui_user', 'chack', 'kind', 'ack',
		  'instance_id', $1::int, 'instance_name', $2::text, 'check_key', 'collector errors',
		  'seen_state', 'log_id:' || (SELECT coalesce(max(log_id), 0) FROM pgvigil.collection_log WHERE instance_id = $1),
		  'until_change', true))->>'ack_id')::bigint`, id, name).Scan(&ackID); err != nil {
			t.Fatalf("%s: the acknowledgement at %s: %v", name, at, err)
		}
		return ackID
	}
	unack := func(ackID int64) {
		t.Helper()
		var outcome string
		if err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_ack(now(), jsonb_build_object('op', 'end', 'ui_user', 'chack', 'ack_id', $1::bigint))->>'outcome'`,
			ackID).Scan(&outcome); err != nil || outcome != "done" {
			t.Fatalf("Unacknowledge %d: %q, %v", ackID, outcome, err)
		}
	}
	type row struct {
		status, reason, judged, ackBy string
		cf, judgedCF, runs, failed    int
		level, n                      int
		allNA                         bool
	}
	// read: c2's row of the page's read over the last day (or the given range) and the instance's Summary cell
	read := func(id int, rng string) row {
		t.Helper()
		var x row
		if err := r.pool.QueryRow(ctx, `SELECT coalesce(c.status, 'absent'), coalesce(c.status_reason, ''), coalesce(c.judged_status, 'absent'),
		                                       coalesce(c.ack_by, ''), coalesce(c.consecutive_failures, -1), coalesce(c.judged_failures, -1),
		                                       coalesce(c.runs, -1), coalesce(c.failed, -1),
		                                       coalesce(s.level, -1), coalesce(s.n, -1), coalesce(s.all_na, false)
		                                  FROM (SELECT 1) one
		                                  LEFT JOIN pgvigil.collection_health(`+rng+`) c ON c.instance_id = $1 AND c.collection = 'c2'
		                                  LEFT JOIN pgvigil.collection_health_summary() s ON s.instance_id = $1`, id).
			Scan(&x.status, &x.reason, &x.judged, &x.ackBy, &x.cf, &x.judgedCF, &x.runs, &x.failed, &x.level, &x.n, &x.allNA); err != nil {
			t.Fatal(err)
		}
		return x
	}
	day := "now() - interval '1 day'"

	t.Run("G7a and the page: the Summary masks the streak, the page keeps it; a newer failure brings it back whole", func(t *testing.T) {
		id, name := inst("a")
		logRun(id, 30*time.Minute, "error")
		logRun(id, 20*time.Minute, "error")
		logRun(id, 10*time.Minute, "error")
		if x := read(id, day); x.status != "critical" || x.cf != 3 || x.judged != "critical" || x.judgedCF != 3 || x.level != 2 {
			t.Fatalf("before: %+v - want critical, 3 in a row, judged the same, the cell's level 2", x)
		}
		ack(id, name, "now()")
		x := read(id, day)
		if x.judged != "ok" || x.judgedCF != 0 || x.level != 0 || x.n != 0 || x.allNA {
			t.Errorf("acknowledged, the Summary: judged %q, %d in a row, the cell's level %d, count %d, all N/A %v - want ok, 0, 0, 0, never N/A", x.judged, x.judgedCF, x.level, x.n, x.allNA)
		}
		if x.status != "critical" || x.cf != 3 || x.ackBy != "chack" || !strings.Contains(x.reason, "acknowledged at ") || !strings.Contains(x.reason, " by chack: 3 in a row before it") {
			t.Errorf("acknowledged, the page: %q, %d in a row, ack by %q, reason %q - want critical and 3 as before, the acknowledged words with 3 in a row before it", x.status, x.cf, x.ackBy, x.reason)
		}
		logRun(id, 0, "error")
		x = read(id, day)
		if x.judged != "critical" || x.judgedCF != 4 || x.level != 2 || x.status != "critical" || x.cf != 4 || strings.Contains(x.reason, "acknowledged") {
			t.Errorf("a newer failure: %+v - want critical with 4 in a row on both (the whole streak, as DBA Dash's Summary_Upd L123), no acknowledged words", x)
		}
	})

	t.Run("G7b: the Summary's rate counts from the acknowledgement's hour when it falls on the hour", func(t *testing.T) {
		id, name := inst("b")
		logRun(id, time.Minute, "ok")
		hour(name, 2, 5, 0, 5, 0) // two hours back: 5 partial runs
		hour(name, 1, 5, 5, 0, 0) // the hour after: 5 ok
		if x := read(id, day); x.status != "warning" || x.judged != "warning" || x.level != 1 {
			t.Fatalf("before: %+v - want warning on both (5 partial of 10 runs), the cell's level 1", x)
		}
		ack(id, name, "date_trunc('hour', now()) - interval '1 hour'")
		if x := read(id, day); x.judged != "ok" || x.level != 0 || x.status != "warning" || x.runs != 10 {
			t.Errorf("acknowledged on the hour: %+v - want judged ok (0 of the 5 runs since), the page still warning over its 10 runs", x)
		}
	})

	t.Run("G7e: with no acknowledgement every judged value is the raw one", func(t *testing.T) {
		id, _ := inst("e")
		logRun(id, 20*time.Minute, "error")
		logRun(id, 10*time.Minute, "error")
		if x := read(id, day); x.status != "warning" || x.cf != 2 || x.judged != x.status || x.judgedCF != x.cf || x.ackBy != "" || x.level != 1 {
			t.Errorf("no acknowledgement: %+v - want warning, 2, judged the same, no ack, the cell's level 1", x)
		}
		var differ int
		if err := r.pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collection_health(now() - interval '1 day') c
		                                 WHERE c.ack_at IS NULL AND (c.judged_status IS DISTINCT FROM c.status OR c.judged_failures IS DISTINCT FROM c.consecutive_failures)`).
			Scan(&differ); err != nil {
			t.Fatal(err)
		}
		if differ != 0 {
			t.Errorf("%d row(s) of the store with no acknowledgement judged apart from their raw values - want 0", differ)
		}
	})

	t.Run("G7g: an acknowledgement 30 hours old still masks the streak; the rate is the plain 24 hours", func(t *testing.T) {
		id, name := inst("g")
		logRun(id, 30*time.Minute, "error")
		logRun(id, 20*time.Minute, "error")
		logRun(id, 10*time.Minute, "error")
		ack(id, name, "now() - interval '30 hours'")
		if x := read(id, day); x.judgedCF != 0 || x.judged != "ok" {
			t.Errorf("an old acknowledgement, no hours: %+v - want the streak masked (judged ok, 0 in a row)", x)
		}
		hour(name, 1, 5, 0, 0, 5) // 5 failed runs an hour back: inside the 24 hours, after the acknowledgement
		if x := read(id, day); x.judged != "critical" || x.judgedCF != 0 || x.level != 2 {
			t.Errorf("an old acknowledgement, 5 failed runs an hour back: %+v - want critical by the rate (100 %%, the last run failed), still 0 in a row", x)
		}
	})

	t.Run("G7h: an acknowledgement inside an hour leaves that hour out; the next hour counts", func(t *testing.T) {
		id, name := inst("h")
		logRun(id, time.Minute, "ok")
		hour(name, 1, 5, 0, 5, 0) // an hour back: 5 partial runs
		if x := read(id, day); x.judged != "warning" || x.level != 1 {
			t.Fatalf("before: %+v - want warning (5 partial of 5)", x)
		}
		ack(id, name, "date_trunc('hour', now()) - interval '40 minutes'")
		if x := read(id, day); x.judged != "ok" || x.level != 0 || x.status != "warning" {
			t.Errorf("acknowledged 20 minutes into that hour: %+v - want judged ok (the hour left out until the next), the page warning", x)
		}
		hour(name, 0, 5, 0, 5, 0) // this hour: 5 partial runs, after the acknowledgement's hour
		if x := read(id, day); x.judged != "warning" || x.level != 1 {
			t.Errorf("5 partial runs in the next hour: %+v - want judged warning again", x)
		}
	})

	t.Run("G7i: not monitored wins over an acknowledgement", func(t *testing.T) {
		id, name := inst("i")
		logRun(id, 20*time.Minute, "error")
		logRun(id, 10*time.Minute, "error")
		var outcome string
		if err := r.pool.QueryRow(ctx, `SELECT pgvigil.import_collection_health_threshold(now(), jsonb_build_object('op', 'set', 'instance_id', $1::int,
		  'dont_monitor', true, 'ui_user', 'chack'))->>'outcome'`, id).Scan(&outcome); err != nil || outcome != "done" {
			t.Fatalf("dont_monitor: %q, %v", outcome, err)
		}
		ack(id, name, "now()")
		if x := read(id, day); x.status != "n/a" || x.judged != "n/a" || !x.allNA || x.level != 0 || strings.Contains(x.reason, "acknowledged") {
			t.Errorf("not monitored and acknowledged: %+v - want N/A on both, the cell all N/A, no acknowledged words", x)
		}
	})

	t.Run("G7j: Unacknowledge brings the judgement back", func(t *testing.T) {
		id, name := inst("j")
		logRun(id, 20*time.Minute, "error")
		logRun(id, 10*time.Minute, "error")
		a := ack(id, name, "now()")
		if x := read(id, day); x.judged != "ok" || x.level != 0 {
			t.Fatalf("acknowledged: %+v - want judged ok", x)
		}
		unack(a)
		if x := read(id, day); x.judged != "warning" || x.judgedCF != 2 || x.level != 1 || x.ackBy != "" || strings.Contains(x.reason, "acknowledged") {
			t.Errorf("unacknowledged: %+v - want warning with 2 in a row again, no ack, no acknowledged words", x)
		}
	})

	t.Run("G7l: a purged collection_log row falls back to the time", func(t *testing.T) {
		before, nameB := inst("lb")
		logRun(before, 20*time.Minute, "error")
		logRun(before, 10*time.Minute, "error")
		ack(before, nameB, "now()")
		after, nameA := inst("la")
		logRun(after, 20*time.Minute, "error")
		ack(after, nameA, "now() - interval '15 minutes'")
		logRun(after, 10*time.Minute, "error") // logged past the mark, failed after the acknowledgement's time
		if _, err := r.pool.Exec(ctx, `DELETE FROM pgvigil.collection_log WHERE instance_id IN ($1, $2)`, before, after); err != nil {
			t.Fatal(err)
		}
		if x := read(before, day); x.judged != "ok" || x.judgedCF != 0 {
			t.Errorf("purged, the last failure before the acknowledgement: %+v - want judged ok", x)
		}
		if x := read(after, day); x.judged != "warning" || x.judgedCF != 2 {
			t.Errorf("purged, the last failure after the acknowledgement: %+v - want judged warning with the whole 2 in a row", x)
		}
	})

	t.Run("G7m: a page over a past range is unchanged by an acknowledgement", func(t *testing.T) {
		id, name := inst("m")
		hour(name, 3, 5, 3, 0, 2)
		logRun(id, 20*time.Minute, "error")
		logRun(id, 10*time.Minute, "error")
		past := "date_trunc('hour', now()) - interval '4 hours', NULL::jsonb, date_trunc('hour', now()) - interval '2 hours'"
		x0 := read(id, past)
		ack(id, name, "now()")
		x1 := read(id, past)
		if x1.status != x0.status || x1.cf != x0.cf || x1.runs != x0.runs || x1.failed != x0.failed || x0.runs != 5 || x0.failed != 2 {
			t.Errorf("a past range: before %+v, after %+v - want the same status, failures in a row, 5 runs and 2 failed", x0, x1)
		}
	})
}
