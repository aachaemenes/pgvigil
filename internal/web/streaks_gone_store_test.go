package web

import (
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5"
)

// TestCollectorStreaksGoneHostOnAStore (red first): collector_streaks rows of a host that never
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

// TestCollectorStreaksBackAfter8DaysOnAStore (the STREAKS review's #1, red first): a host back after 8 days or more
// counts from 0 in every topology. With ONE collector nothing beats while its host is away, so the gone-host delete
// never runs and the old streak rows stay; a new run of the host then read them back through import_collector_streaks
// (no age filter) and counted on from them - 'collection failing' could fire on the first failure after the return, its
// start 10 days old. import_collector_streaks now returns only streaks written in the last 8 days. Control: a host
// restarted an hour after its last beat keeps counting (its streak returned). In one transaction rolled back. RED on
// 0121 as it was: the 9-day-old streak is returned.
func TestCollectorStreaksBackAfter8DaysOnAStore(t *testing.T) {
	ctx, tx, _, sfx := f9Store(t)
	away, restarted := fmt.Sprintf("away-%d", sfx), fmt.Sprintf("restarted-%d", sfx)
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
		fmt.Sprintf("sb-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	// away: its only run last beat 9 days ago (a streak of 5 written then); restarted: its run last beat an hour ago (a
	// streak of 3 written then); each host then starts a new run (the claim a starting collector writes first)
	for _, r := range []struct {
		host, at string
		fails    int
	}{{away, "9 days", 5}, {restarted, "1 hour", 3}} {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
			VALUES ($1 || '-r1', $1, 'linux', 'service', 'x', 1, now() - interval '10 days', now() - $2::interval)`, r.host, r.at); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_streaks (instance_id, collection, host, fail_streak, last_error, last_run_at, failing_since)
			VALUES ($1, 'activity', $2, $3, 'timeout', now() - $4::interval, now() - $4::interval - interval '5 minutes')`, id, r.host, r.fails, r.at); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_claim($1 || '-r2', $1, 'linux', 'service', 'x', 2)`, r.host); err != nil {
			t.Fatal(err)
		}
	}
	for h, want := range map[string]string{away: "[]", restarted: "[activity 3]"} {
		rows, err := tx.Query(ctx, `SELECT collection || ' ' || fail_streak FROM pgvigil.import_collector_streaks($1)`, h)
		if err != nil {
			t.Fatal(err)
		}
		got, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			t.Fatal(err)
		}
		if fmt.Sprint(got) != want {
			t.Errorf("host %s: import_collector_streaks %v after its new run's claim, want %s (back after 8 days: counts from 0; restarted within them: counts on)", h, got, want)
		}
	}
}
