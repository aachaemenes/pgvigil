package web

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestServerDownStopMinuteOnAStore (SV's red, j15k / j15u: the server's own 'collector or network' never formed after
// target2 stopped): collector_server_down_at on a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped without it), in
// one transaction rolled back. Three instances on one dial target read every minute, answered at M-2 and M-1; the server
// stops a few seconds into minute M (the proof stops target2 at :02, right after the beat that ended its wait). At M two
// of them made only unanswered connects (their 'down' spell begins at M) and ONE had answered before the stop (its row
// at M answered 1 of 6: its spell begins at M+1); from M+1 every connect of the three goes unanswered. The quorum's
// anchor is M, the earliest new down spell's start. Cases, the beats' order of collector_spells_take minute by minute:
//   - 'stop inside the minute' (the red): the server is down from M, the three its set - an answer BEFORE a member's own
//     down spell began is no evidence the server answers. RED on 0121 as it was: no row (the member's answered row at
//     M, at or after the anchor, ruled the server out for good).
//   - 'stop at the minute's edge' (the control): the three down from M alike - one row on both.
//   - 'a fourth answers' (the guard): a fourth instance on the target, never down, answers at M+1 - no row on both (an
//     answer from an instance not in the down set at or after the anchor is the server answering).
//   - 'a member answers after the anchor' (the guard): one member down at M, answered at M+1, down again from M+2 - no
//     row on both (only the anchor minute's answers of the down set are ambiguous: an answer after it is the server's).
func TestServerDownStopMinuteOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	for _, c := range []struct {
		name    string
		mixedM  bool // one member answered 1 of 6 at M (before the stop)
		fourth  bool // a fourth instance on the target answers at every minute
		flap    bool // the second member answers at M+1
		wantRow bool
	}{
		{"stop inside the minute", true, false, false, true},
		{"stop at the minute's edge", false, false, false, true},
		{"a fourth answers", true, true, false, false},
		{"a member answers after the anchor", false, false, true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			pool, err := pgxpool.New(ctx, dsn)
			if err != nil {
				t.Fatal(err)
			}
			defer pool.Close()
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			sfx := time.Now().UnixNano() % 1000000000
			col, host, target := fmt.Sprintf("sd-%d", sfx), fmt.Sprintf("sdhost-%d", sfx), fmt.Sprintf("postgres:sdtarget%d:5432", sfx)
			if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at, span_s)
				VALUES ($1, $2, 'linux', 'service', 'x', 1, now() - interval '1 hour', now(), 60)`, col, host); err != nil {
				t.Fatal(err)
			}
			n := 3
			if c.fourth {
				n = 4
			}
			ids := make([]int, n)
			for i := range ids {
				if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
					fmt.Sprintf("sd%d-%d", i+1, sfx)).Scan(&ids[i]); err != nil {
					t.Fatal(err)
				}
			}
			// minutes relative to M = date_trunc('minute', now()) - 3 minutes: -2 .. +2; every row 6 connects
			row := func(off, i int) (opened, noanswer int) {
				switch {
				case i == 3: // the fourth: always answered
					return 6, 0
				case off < 0:
					return 6, 0
				case off == 0 && i == 1 && c.mixedM:
					return 1, 5 // answered before the stop
				case off == 1 && i == 1 && c.flap:
					return 6, 0 // answered after the anchor
				default:
					return 0, 6
				}
			}
			for off := -2; off <= 2; off++ {
				for i, id := range ids {
					opened, noanswer := row(off, i)
					if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, noanswer, target, interval_s)
						VALUES (date_trunc('minute', now()) - interval '3 minutes' + make_interval(mins => $1), $2, $3, 6, $4, 6, 6 - $4, 0, $5, $6, 10)`,
						off, id, col, opened, noanswer, target); err != nil {
						t.Fatal(err)
					}
				}
				if _, err := tx.Exec(ctx, `SELECT pgvigil.collector_spells_take($1, date_trunc('minute', now()) - interval '3 minutes' + make_interval(mins => $2))`, col, off); err != nil {
					t.Fatal(err)
				}
			}
			var got []string
			rows, err := tx.Query(ctx, `SELECT d.target || ' since M' || (extract(epoch FROM d.since - (date_trunc('minute', now()) - interval '3 minutes')) / 60)::int
			                                   || ' n' || cardinality(d.instances)
			                              FROM pgvigil.collector_server_down_at($1, date_trunc('minute', now()) - interval '1 minute') d`, host)
			if err != nil {
				t.Fatal(err)
			}
			got, err = pgx.CollectRows(rows, pgx.RowTo[string])
			if err != nil {
				t.Fatal(err)
			}
			want := []string{}
			if c.wantRow {
				want = []string{target + " since M0 n3"}
			}
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Errorf("collector_server_down_at: %q, want %q", got, want)
			}
		})
	}
}
