package repo

import (
	"fmt"
	"testing"
)

// TestDBADashHealthWords (the lead 11-14 06:1x, 0138): the door's Collection Errors column follows DBA Dash's version
// as the door read it - 'Collection Health' on a repository at 4.25.0 or later, 'DBA Dash Errors (24hrs)' before, both
// over repositories of both kinds - and each instance's count follows what DBA Dash's 4.25.0 Summary_Upd used for it:
// collections at warning or critical where the instance has collection runs (the detail CollectionHealth), the errors of
// 24 hours otherwise. A version that is not dot-separated digits is read as older.
func TestDBADashHealthWords(t *testing.T) {
	ctx, pool, sfx := moveStore(t)
	old, neu, odd := fmt.Sprintf("r425o-%d", sfx), fmt.Sprintf("r425n-%d", sfx), fmt.Sprintf("r425x-%d", sfx)
	for repo, ver := range map[string]string{old: "4.24.1.0", neu: "4.25.0.0", odd: "beta"} {
		moveRepo(ctx, t, pool, repo, "SQL"+repo, 1, 2)
		if _, err := pool.Exec(ctx, `UPDATE pgvigil.dbadash_repositories SET version = $2 WHERE repository = $1`, repo, ver); err != nil {
			t.Fatal(err)
		}
	}
	// on 4.25.0: instance 1 with collection runs, instance 2 without (a service older than 4.25.0 collects it)
	sum := func(repo string, id int, details string) {
		t.Helper()
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.dbadash_summary (repository, instance_id, snapshot_at, statuses, details)
VALUES ($1, $2, now(), '{"CollectionErrorStatus": 2}', $3::jsonb)`, repo, id, details); err != nil {
			t.Fatal(err)
		}
	}
	sum(neu, 1, `{"CollectionErrorCount": 3, "CollectionHealth": true}`)
	sum(neu, 2, `{"CollectionErrorCount": 5, "CollectionHealth": false}`)
	sum(old, 1, `{"CollectionErrorCount": 4}`)
	cell := func(repo string, id int) string {
		t.Helper()
		var label, detail string
		if err := pool.QueryRow(ctx, `SELECT label, coalesce(detail, '') FROM pgvigil.dbadash_statuses($1, $2) WHERE status_key = 'CollectionErrorStatus'`, repo, id).Scan(&label, &detail); err != nil {
			t.Fatalf("%s %d: %v", repo, id, err)
		}
		return label + " | " + detail
	}
	for _, c := range []struct {
		repo string
		id   int
		want string
	}{
		{neu, 1, "Collection Health | 3 collection(s) at warning or critical"},
		{neu, 2, "Collection Health | 5 error(s) in 24 h"},
		{old, 1, "DBA Dash Errors (24hrs) | 4 error(s) in 24 h"},
	} {
		if got := cell(c.repo, c.id); got != c.want {
			t.Errorf("%s instance %d: %q, want %q", c.repo, c.id, got, c.want)
		}
	}
	label := func(repo any) string {
		t.Helper()
		var l string
		if err := pool.QueryRow(ctx, `SELECT label FROM pgvigil.dbadash_checks($1) WHERE status_key = 'CollectionErrorStatus'`, repo).Scan(&l); err != nil {
			t.Fatal(err)
		}
		return l
	}
	for repo, want := range map[string]string{neu: "Collection Health", old: "DBA Dash Errors (24hrs)", odd: "DBA Dash Errors (24hrs)"} {
		if got := label(repo); got != want {
			t.Errorf("the header of %s: %q, want %q", repo, got, want)
		}
	}
	// every configured repository at once (the fleet grid without a repository): this store holds both kinds now
	if got := label(nil); got != "Collection Health / DBA Dash Errors (24hrs)" {
		t.Errorf("the header over every repository: %q, want both words", got)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.dbadash_checks($1)`, neu).Scan(&n); err != nil || n != 26 {
		t.Errorf("dbadash_checks(repo): %d rows (%v), want the 26 of 0052", n, err)
	}
	for v, want := range map[string]bool{"4.25.0.0": true, "4.25": true, "4.26.1.0": true, "5.0.0.0": true, "4.24.1.0": false, "4.19.0.0": false, "": false, "4.25.0-beta": false} {
		var got bool
		if err := pool.QueryRow(ctx, `SELECT pgvigil.dbadash_health_version($1)`, v).Scan(&got); err != nil || got != want {
			t.Errorf("dbadash_health_version(%q) = %v (%v), want %v", v, got, err, want)
		}
	}
}
