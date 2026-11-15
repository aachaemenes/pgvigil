package web

import (
	"context"
	"fmt"
	"os"
	"strings"
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

// TestProbeThresholdsMatchOnAStore (F4, vis-b24hbj2g): collector_probe_thresholds - B24h's two keys for every instance at
// once - equals pg_threshold instance by instance: the root, a tag's level, an instance's own, and an instance's level
// with no warning (off: never the root's value), each key; and a tag tie (the review of the fold #11: an instance with two
// tags, each with a level row, takes the first tag by name - 0.02 from team:pt.., never 0.03 from team:pu..); one
// transaction rolled back.
func TestProbeThresholdsMatchOnAStore(t *testing.T) {
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
	tag, tag2 := fmt.Sprintf("team:pt%d", sfx), fmt.Sprintf("team:pu%d", sfx)
	ids := map[string]int32{}
	for name, tags := range map[string][]string{"plain": {}, "tagged": {tag}, "own": {tag}, "off": {}, "tie": {tag2, tag}} {
		var id int32
		if err := tx.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, $2::text[], 'postgres')`,
			fmt.Sprintf("pt-%s-%d", name, sfx), tags).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[name] = id
	}
	for _, r := range []struct {
		key, level string
		inst       any
		tag        any
		warn       any
	}{
		{"round_trip_time", "root", nil, nil, 0.05}, {"round_trip_time", "tag", nil, tag, 0.07}, {"round_trip_time", "instance", ids["own"], nil, 0.09},
		{"round_trip_time", "instance", ids["off"], nil, nil}, {"ping_time", "tag", nil, tag, 0.02}, {"ping_time", "tag", nil, tag2, 0.03},
	} {
		if _, err := tx.Exec(ctx, `UPDATE pgvigil.pg_thresholds SET ended_at = now() WHERE ended_at IS NULL AND key = $1 AND level = 'root' AND $2 = 'root'`, r.key, r.level); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.pg_thresholds (key, level, instance_id, tag, warn, created_by, created_at) VALUES ($1, $2, $3, $4, $5, 't', now())`,
			r.key, r.level, r.inst, r.tag, r.warn); err != nil {
			t.Fatalf("%s %s: %v", r.key, r.level, err)
		}
	}
	var bad int
	var sample string
	if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE x.a IS DISTINCT FROM x.b),
	           string_agg(x.name || ' ' || x.key || ' ' || coalesce(x.a::text, 'off') || '/' || coalesce(x.b::text, 'off'), '; ' ORDER BY x.name, x.key)
	      FROM (SELECT i.name, k.key, (SELECT c.warn FROM pgvigil.collector_probe_thresholds c WHERE c.instance_id = i.instance_id AND c.key = k.key) AS a,
	                   (SELECT p.warn FROM pgvigil.pg_threshold(i.instance_id, k.key) p) AS b
	              FROM pgvigil.instances i CROSS JOIN (VALUES ('round_trip_time'), ('ping_time')) k(key)
	             WHERE i.instance_id = ANY ($1)) x`, []int32{ids["plain"], ids["tagged"], ids["own"], ids["off"], ids["tie"]}).Scan(&bad, &sample); err != nil {
		t.Fatalf("the comparison: %v", err)
	}
	if bad != 0 {
		t.Errorf("collector_probe_thresholds differs from pg_threshold on %d of 10: %s", bad, sample)
	}
	if want := "0.09/0.09"; !strings.Contains(sample, "own-"+fmt.Sprint(sfx)+" round_trip_time "+want) || !strings.Contains(sample, "off-"+fmt.Sprint(sfx)+" round_trip_time off/off") ||
		!strings.Contains(sample, "tie-"+fmt.Sprint(sfx)+" ping_time 0.02/0.02") {
		t.Errorf("the levels as set: %s (want own 0.09, off empty, the tie 0.02 by its first tag)", sample)
	}
}

// TestProbeFormingOnAStore (the B24h-1 review part b #5): collector_probe_forming - an instance crossed into a slow round
// trip (its last 5 measured minutes over the warning, the 5 before the newest not) waits while 3 or more of its
// collector host's instances crossed: three crossing together are listed; an instance slow in both windows never
// crossed; two crossing are no forming fold. One transaction rolled back.
func TestProbeFormingOnAStore(t *testing.T) {
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
	for _, crossing := range []int{3, 2} {
		func() {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			sfx := time.Now().UnixNano() % 1000000000
			col := fmt.Sprintf("pf-%d-%d", crossing, sfx)
			if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
				VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '1 hour', now())`, col); err != nil {
				t.Fatal(err)
			}
			want := map[int]bool{}
			for k := 1; k <= crossing+1; k++ {
				var id int
				if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
					fmt.Sprintf("pf-%d-%d-%d", crossing, k, sfx)).Scan(&id); err != nil {
					t.Fatal(err)
				}
				slowBoth := k == crossing+1 // the last one slow in both windows
				for m := 1; m <= 6; m++ {
					ms := 20
					if m == 1 {
						ms = 200 // the newest minute: the 5-minute average goes over 40 ms, the window before stays at 20 ms
					}
					if slowBoth {
						ms = 60
					}
					if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target, rt_count, rt_ms_sum, rt_ms_max)
						VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, 1, 1, 1, 0, 0, $4, 1, $5, $5)`, m, id, col, fmt.Sprintf("postgres:h%d-%d:5432", k, sfx), ms); err != nil {
						t.Fatal(err)
					}
				}
				if !slowBoth && crossing >= 3 {
					want[id] = true
				}
			}
			rs, err := tx.Query(ctx, `SELECT f.instance_id FROM pgvigil.collector_probe_forming f JOIN pgvigil.collector_load l ON l.instance_id = f.instance_id AND l.collector_id = $1 GROUP BY f.instance_id`, col)
			if err != nil {
				t.Fatalf("the forming view: %v", err)
			}
			got := map[int]bool{}
			for rs.Next() {
				var id int
				if err := rs.Scan(&id); err != nil {
					t.Fatal(err)
				}
				got[id] = true
			}
			rs.Close()
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Errorf("%d crossing together: forming %v, want %v", crossing, got, want)
			}
		}()
	}
}
