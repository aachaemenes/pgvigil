package web

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The review of the B24h-1 fold: its #7 / #9 / #4 as store rows
// (box rows: PGVIGIL_REPO_TEST_DSN), each in one transaction rolled back.

// f9Store opens a transaction on the test store and a collector of its own; skips without a store.
func f9Store(t *testing.T) (context.Context, pgx.Tx, string, int64) {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	sfx := time.Now().UnixNano() % 1000000000
	col := fmt.Sprintf("f9-%d", sfx)
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '1 hour', now())`, col); err != nil {
		t.Fatal(err)
	}
	return ctx, tx, col, sfx
}

// f9Instance adds an instance whose load rows (minutes back, opened) name host as its target.
func f9Instance(ctx context.Context, t *testing.T, tx pgx.Tx, col, name, host string, loads map[int]int) int {
	t.Helper()
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`, name).Scan(&id); err != nil {
		t.Fatal(err)
	}
	for m, opened := range loads {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target)
			VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, 1, $4, 1, 0, 0, $5)`, m, id, col, opened, "postgres:"+host+":5432"); err != nil {
			t.Fatal(err)
		}
	}
	return id
}

// f9Probe adds a per-minute probe row of host at addr, minutes back, answered (0 or 1) in ms.
func f9Probe(ctx context.Context, t *testing.T, tx pgx.Tx, col, host, addr string, minute, answered, ms int) {
	t.Helper()
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max, scheduled)
		VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, $4, 'tcp', 1, $5, $6::bigint, $6::int, true)`, minute, col, host, addr, answered, ms); err != nil {
		t.Fatal(err)
	}
}

// f9Judged reads the judged view's ping slow | not answering for an instance ('not listed' when absent).
func f9Judged(ctx context.Context, t *testing.T, tx pgx.Tx, col string, id int) string {
	t.Helper()
	var v string
	if err := tx.QueryRow(ctx, `SELECT coalesce((SELECT j.ping_slow::text || '|' || j.not_answering::text FROM pgvigil.collector_probe_judged j
	                              WHERE j.collector_host = $1 AND j.instance_id = $2), 'not listed')`, col, id).Scan(&v); err != nil {
		t.Fatalf("the judged view: %v", err)
	}
	return v
}

// TestProbeJudgedNewestAddressOnAStore (#7, BJf7): a host whose address moved (an endpoint's failover from A to B, A
// sorting first) is judged by the address probed newest - A's 5 rounds 12 to 8 minutes back, B's 5 rounds 5 to 1, all
// at 30 ms over the 10 ms default: ping slow (A, tied on answers and first by name, was stale: judged on nothing).
func TestProbeJudgedNewestAddressOnAStore(t *testing.T) {
	ctx, tx, col, sfx := f9Store(t)
	host := fmt.Sprintf("moved-%d", sfx)
	id := f9Instance(ctx, t, tx, col, "f9-moved-"+fmt.Sprint(sfx), host, map[int]int{1: 1, 2: 1, 3: 1})
	for m := 8; m <= 12; m++ {
		f9Probe(ctx, t, tx, col, host, "10.7.0.1:5432", m, 1, 30)
	}
	for m := 1; m <= 5; m++ {
		f9Probe(ctx, t, tx, col, host, "10.7.0.2:5432", m, 1, 30)
	}
	if got := f9Judged(ctx, t, tx, col, id); got != "true|false" {
		t.Errorf("a host whose address moved: ping slow | not answering = %q, want 'true|false' (its newest address speaks)", got)
	}
}

// TestProbeOpenedPerHostOnAStore (#9): an opened connection answers for its HOST since the silence began - an instance
// read every 5 minutes on a host whose other instance opened a connection a minute ago is not 'not answering' (the
// per-instance 3-minute term flapped it); a connection opened BEFORE the silence's oldest probed minute answers nothing
// (the control: a wider fixed window would hide a host that went down 5 minutes after its last connection).
func TestProbeOpenedPerHostOnAStore(t *testing.T) {
	ctx, tx, col, sfx := f9Store(t)
	shared, early := fmt.Sprintf("shared-%d", sfx), fmt.Sprintf("early-%d", sfx)
	slow := f9Instance(ctx, t, tx, col, "f9-slow-"+fmt.Sprint(sfx), shared, map[int]int{4: 1, 9: 1})
	fast := f9Instance(ctx, t, tx, col, "f9-fast-"+fmt.Sprint(sfx), shared, map[int]int{1: 1, 2: 1, 3: 1, 4: 1})
	before := f9Instance(ctx, t, tx, col, "f9-early-"+fmt.Sprint(sfx), early, map[int]int{5: 1, 6: 0, 7: 0})
	for _, h := range [][2]string{{shared, "10.7.1.1:5432"}, {early, "10.7.1.2:5432"}} {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_probe_host (collector_id, host, address, first_probed, last_answered, last_method)
			VALUES ($1, $2, $3, now() - interval '1 hour', now() - interval '30 minutes', 'tcp')`, col, h[0], h[1]); err != nil {
			t.Fatal(err)
		}
		for m := 1; m <= 3; m++ {
			f9Probe(ctx, t, tx, col, h[0], h[1], m, 0, 0)
		}
	}
	for name, c := range map[string]struct {
		id   int
		want string
	}{"the 5-minute instance on a host answering a connection": {slow, "false|false"}, "the host's instance that opened": {fast, "false|false"},
		"a connection opened before the silence": {before, "false|true"}} {
		if got := f9Judged(ctx, t, tx, col, c.id); got != c.want {
			t.Errorf("%s: ping slow | not answering = %q, want %q", name, got, c.want)
		}
	}
}

// TestProbeFormingHostsOnAStore (#4, BJf4's view half): collector_probe_forming_hosts - a host whose ping crossed (its
// last 5 probed minutes over its instance's warning, the 5 before the newest not) while 3 or more of its collector's
// hosts crossed: three crossing together are listed; a host slow in both windows never crossed; a calm one is not; two
// crossing are no forming fold. A staggered crossing (one host a pass before the others) is not covered: the first is
// sent, as SLOW-CONNECT's collector_slow_forming does.
func TestProbeFormingHostsOnAStore(t *testing.T) {
	for _, crossing := range []int{3, 2} {
		t.Run(fmt.Sprint(crossing), func(t *testing.T) {
			ctx, tx, col, sfx := f9Store(t)
			var want []string
			for k := 1; k <= crossing+2; k++ {
				host := fmt.Sprintf("fh%d-%d-%d", k, crossing, sfx)
				f9Instance(ctx, t, tx, col, "f9-"+host, host, map[int]int{1: 1, 2: 1, 3: 1})
				kind := map[bool]string{true: "cross", false: ""}[k <= crossing]
				switch k {
				case crossing + 1:
					kind = "both"
				case crossing + 2:
					kind = "calm"
				}
				for m := 1; m <= 6; m++ {
					ms := 2 // the window before the newest: 2 ms, under the 10 ms default
					switch {
					case kind == "cross" && m == 1:
						ms = 50 // the newest minute: the last 5 average 11.6 ms, over it
					case kind == "both":
						ms = 30
					}
					f9Probe(ctx, t, tx, col, host, fmt.Sprintf("10.7.2.%d:5432", k), m, 1, ms)
				}
				if kind == "cross" && crossing >= 3 {
					want = append(want, host)
				}
			}
			rs, err := tx.Query(ctx, `SELECT host FROM pgvigil.collector_probe_forming_hosts WHERE collector_host = $1`, col)
			if err != nil {
				t.Fatalf("the forming hosts view: %v", err)
			}
			got, err := pgx.CollectRows(rs, pgx.RowTo[string])
			if err != nil {
				t.Fatal(err)
			}
			sort.Strings(got)
			sort.Strings(want)
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Errorf("%d hosts crossing together: forming hosts %v, want %v", crossing, got, want)
			}
		})
	}
}
