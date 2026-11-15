package web

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestProbeJudgedFoldOnAStore (the B24h-1 fold F4: the review of 60991f0e part b #7 / #12; a box row:
// PGVIGIL_REPO_TEST_DSN): collector_probe_judged on three hosts of one collector, one transaction rolled back -
//   - 'stale': probes 15 to 19 minutes old, answered at 30 ms (over the 10 ms warning), none since: no ping slow (#7c:
//     an old reading never stands);
//   - 'deflt': the default mode's probes (scheduled false) of the last 4 minutes, none answered, the host answered
//     once: neither ping slow nor not answering (#7, the lead's 12:4x (a): per-minute rows only);
//   - 'opened': per-minute probes of the last 3 minutes, none answered, the host answered once - and a connection of
//     its instance opened a minute ago: not answering is false (#12: an opened connection is an answer).
//
// A control host 'silent' (as 'opened' with no connection opened) reads not answering, so the rows can fail.
func TestProbeJudgedFoldOnAStore(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	sfx := time.Now().UnixNano() % 1000000000
	col := fmt.Sprintf("pj-%d", sfx)
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '1 hour', now())`, col); err != nil {
		t.Fatal(err)
	}
	ids := map[string]int{}
	for k, name := range []string{"stale", "deflt", "opened", "silent"} {
		var id int
		if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
			fmt.Sprintf("pj-%s-%d", name, sfx)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[name] = id
		host, addr := fmt.Sprintf("%s-%d", name, sfx), fmt.Sprintf("10.8.%d.1:5432", k)
		// the instance's load rows name its host (collector_instance_hosts); 'opened' opened a connection a minute ago,
		// the others opened none in the last 3 minutes
		for m := 1; m <= 6; m++ {
			opened := 0
			if name == "opened" && m == 1 {
				opened = 1
			}
			if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target)
				VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, 1, $4, 1, 1, 0, $5)`, m, id, col, opened, "postgres:"+host+":5432"); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_probe_host (collector_id, host, address, first_probed, last_answered, last_method)
			VALUES ($1, $2, $3, now() - interval '1 hour', now() - interval '30 minutes', 'tcp')`, col, host, addr); err != nil {
			t.Fatal(err)
		}
		rows := map[string][][2]int{ // minutes back, answered
			"stale": {{15, 1}, {16, 1}, {17, 1}, {18, 1}, {19, 1}}, "deflt": {{1, 0}, {2, 0}, {3, 0}, {4, 0}},
			"opened": {{1, 0}, {2, 0}, {3, 0}}, "silent": {{1, 0}, {2, 0}, {3, 0}}}[name]
		for _, r := range rows {
			ms := 0
			if r[1] == 1 {
				ms = 30
			}
			if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max, scheduled)
				VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, $4, 'tcp', 1, $5, $6::bigint, $6::int, $7)`, r[0], col, host, addr, r[1], ms, name != "deflt"); err != nil {
				t.Fatal(err)
			}
		}
	}
	got := map[string]string{}
	rs, err := tx.Query(ctx, `SELECT j.instance_id, coalesce(j.ping_slow, false)::text || '|' || coalesce(j.not_answering, false)::text
	                            FROM pgvigil.collector_probe_judged j WHERE j.collector_host = $1`, col)
	if err != nil {
		t.Fatalf("the judged view: %v", err)
	}
	for rs.Next() {
		var id int
		var v string
		if err := rs.Scan(&id, &v); err != nil {
			t.Fatal(err)
		}
		for n, x := range ids {
			if x == id {
				got[n] = v
			}
		}
	}
	rs.Close()
	for name, want := range map[string]string{"stale": "false|false", "deflt": "false|false", "opened": "false|false", "silent": "false|true"} {
		if g, ok := got[name]; !ok && want != "false|false" || ok && g != want {
			t.Errorf("%s: ping slow | not answering = %q (listed %v), want %q", name, g, ok, want)
		}
	}
}
