package web

import (
	"fmt"
	"testing"
)

// TestCollectorStreaksGoneHostOnAStore (the lead's 11-15 19:2x, red first): collector_streaks rows of a host that never
// beats again - uninstalled, renamed, its machine gone - were never deleted: the beat's trim takes only the BEATING
// host's rows and purge() never names the table. A beat of a live collector now removes a host's streak rows when every
// run of that host last beat 8 days ago or more (its last heartbeat row goes in the same beat); a host with one run still
// beating keeps them. In one transaction rolled back. RED on 0121 as it was: the gone host's rows stay.
func TestCollectorStreaksGoneHostOnAStore(t *testing.T) {
	ctx, tx, col, sfx := f9Store(t)
	gone, back := fmt.Sprintf("gone-%d", sfx), fmt.Sprintf("back-%d", sfx)
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
		fmt.Sprintf("sg-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	// gone: one run, last beat 9 days ago; back: an old run 9 days ago and a new run beating now (a restarted service)
	for _, r := range []struct{ id, host, at string }{{gone + "-r1", gone, "9 days"}, {back + "-r1", back, "9 days"}, {back + "-r2", back, "0 days"}} {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
			VALUES ($1, $2, 'linux', 'service', 'x', 1, now() - interval '10 days', now() - $3::interval)`, r.id, r.host, r.at); err != nil {
			t.Fatal(err)
		}
	}
	for _, h := range []string{gone, back} {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_streaks (instance_id, collection, host, fail_streak, last_error, last_run_at, failing_since)
			VALUES ($1, 'activity', $2, 3, 'timeout', now() - interval '9 days', now() - interval '9 days')`, id, h); err != nil {
			t.Fatal(err)
		}
	}
	var known bool
	if err := tx.QueryRow(ctx, `SELECT pgvigil.import_collector_beat($1, date_trunc('minute', now()), '{}'::jsonb)`, col).Scan(&known); err != nil || !known {
		t.Fatalf("the live collector's beat: %v (known %v)", err, known)
	}
	for h, want := range map[string]int{gone: 0, back: 1} {
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collector_streaks WHERE host = $1`, h).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != want {
			t.Errorf("host %s: %d streak rows after a live collector's beat, want %d (gone 8 days: none; a run still beating: kept)", h, n, want)
		}
	}
	var hb int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collector_heartbeat WHERE host IN ($1, $2)`, gone, back).Scan(&hb); err != nil || hb != 1 {
		t.Errorf("the heartbeat rows left of the two hosts: %d (%v), want 1 (back's new run)", hb, err)
	}
}
