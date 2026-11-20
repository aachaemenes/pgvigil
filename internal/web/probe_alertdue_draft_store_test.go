package web

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestProbeAlertDueDraftOnAStore (BJb4, BJb5, BJf3, BJf4; a box row:
// PGVIGIL_REPO_TEST_DSN): alert_due with B24h's line 3 terms, each case in its own transaction rolled back. Until the
// release migration writes them into 0300, PGVIGIL_ALERTDUE_DRAFT names the draft files applied first (comma-separated,
// from the repository root: scripts/probe-alertdue-draft-base.sql alone = 0190's alert_due, the red run; with
// scripts/probe-alertdue-draft.sql = line 3 in, the green run); after 0300, PGVIGIL_ALERTDUE_DRAFT=none runs it on the
// store as migrated.
//   - BJb4: a server not answering (its 'collector or network' parent stands) whose host stopped answering the probe -
//     the host's 'host not answering ping' row is held with its instances (a host row has no instance id);
//   - BJb5 / BJf3: a collector not seen for 11 minutes - its open 'network slow from this collector' and a host's open
//     'host not answering ping' (missing 11 minutes, over clear_after) are not 'resolved': the probes stopped with it;
//   - BJf4 (t): 3 of a collector's 10 hosts cross a slow ping together (no fold yet: 3 of 10) - their new host rows wait;
//   - BJf4 (t+1): 6 of 10 slow (3 slow before, 3 crossing) - the fold fires and the host rows are held under it.
//   - BJf9a: the same fold while ONE other server of the collector is not answering (a 'server not
//     answering' parent: the collector still probes every other host) - the fold still fires, and a recovered host's open
//     'ping slow' (missing 11 minutes) is 'resolved'; only a collector not seen stops its probes.
func TestProbeAlertDueDraftOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	draft := os.Getenv("PGVIGIL_ALERTDUE_DRAFT")
	if draft == "" {
		// a store migrated to 0300 (the release migration that writes alert_due's probe terms) is read as migrated, never skipped:
		// an unset switch must not hide a red in those terms (collection_worst_store_test.go reads its own switch the
		// same way); schema_version.version is the migration's file name, '0300' compared as text
		var joined bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pgvigil.schema_version WHERE version >= '0300')`).Scan(&joined); err != nil {
			t.Fatal(err)
		}
		if !joined {
			t.Skip("PGVIGIL_ALERTDUE_DRAFT is not set and the store has no 0300 yet (the draft files until then)")
		}
		draft = "none"
	}
	var sqls []string
	if draft != "none" {
		for _, f := range strings.Split(draft, ",") {
			b, err := os.ReadFile(filepath.Join("..", "..", strings.TrimSpace(f)))
			if err != nil {
				t.Fatalf("the draft %s: %v", f, err)
			}
			sqls = append(sqls, string(b))
		}
	}
	sfx := time.Now().UnixNano() % 1000000000
	inTx := func(name string, body func(c *draftCase)) {
		t.Run(name, func(t *testing.T) {
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			for _, s := range sqls { // several statements a file: the simple protocol (pgconn's Exec), in the transaction
				if _, err := tx.Conn().PgConn().Exec(ctx, s).ReadAll(); err != nil {
					t.Fatalf("applying the draft: %v", err)
				}
			}
			body(&draftCase{t: t, tx: tx, ctx: ctx})
		})
	}

	inTx("BJb4", func(c *draftCase) {
		col, host := fmt.Sprintf("bj4-%d", sfx), fmt.Sprintf("db1-%d", sfx)
		c.collector(col, 0)
		for k := 1; k <= 3; k++ {
			id := c.instance(fmt.Sprintf("bj4-%d-%d", k, sfx))
			for m := 10; m >= 5; m-- {
				c.load(col, id, m, 1, 0, host)
			}
			for m := 4; m >= 1; m-- {
				c.load(col, id, m, 0, 1, host)
			}
			c.exec(`INSERT INTO pgvigil.collector_spells (host, instance_id, kind, since, last)
				VALUES ($1, $2, 'down', date_trunc('minute', now()) - interval '4 minutes', date_trunc('minute', now()) - interval '1 minute')`, col, id)
		}
		c.probeHost(col, host, "10.6.0.5:5432")
		for m := 8; m >= 5; m-- {
			c.probe(col, host, "10.6.0.5:5432", m, 1, 2)
		}
		for m := 3; m >= 1; m-- {
			c.probe(col, host, "10.6.0.5:5432", m, 0, 0)
		}
		var parents int
		if err := c.tx.QueryRow(c.ctx, `SELECT count(*) FROM pgvigil.collector_parent WHERE host = $1`, col).Scan(&parents); err != nil || parents != 1 {
			c.t.Fatalf("the control: %d 'collector or network' parent(s) of %s (%v), want 1 (a server not answering)", parents, col, err)
		}
		if got := c.due(host); got != "" {
			c.t.Errorf("a server not answering whose host stopped answering the probe: %q, want nothing (the host row held with its instances)", got)
		}
	})

	inTx("BJb5+BJf3", func(c *draftCase) {
		col, host := fmt.Sprintf("bj5-%d", sfx), fmt.Sprintf("db9-%d", sfx)
		c.collector(col, 11)
		id := c.instance(fmt.Sprintf("bj5-%d", sfx))
		for m := 14; m >= 12; m-- {
			c.load(col, id, m, 1, 0, host)
		}
		c.probeHost(col, host, "10.6.0.9:5432")
		c.openAlert("network slow from this collector", col)
		c.openAlert("host not answering ping", host)
		var parents int
		if err := c.tx.QueryRow(c.ctx, `SELECT count(*) FROM pgvigil.collector_parent WHERE host = $1`, col).Scan(&parents); err != nil || parents != 1 {
			c.t.Fatalf("the control: %d parent(s) of %s (%v), want 1 (collector not seen)", parents, col, err)
		}
		if got := c.due(col, host); got != "" {
			c.t.Errorf("a collector not seen for 11 minutes: %q, want nothing (its fold and its host's row stay open)", got)
		}
	})

	fold := func(c *draftCase, col string, slowBefore, crossing int) (hosts []string) {
		c.collector(col, 0)
		for k := 1; k <= 10; k++ {
			host := fmt.Sprintf("%s-h%d", col, k)
			hosts = append(hosts, host)
			id := c.instance("i-" + host)
			for m := 3; m >= 1; m-- {
				c.load(col, id, m, 1, 0, host)
			}
			for m := 6; m >= 1; m-- {
				ms := 2
				if k <= slowBefore {
					ms = 30
				} else if k <= slowBefore+crossing && m == 1 {
					ms = 50
				}
				c.probe(col, host, fmt.Sprintf("10.5.%d.%d:5432", sfx%200, k), m, 1, ms)
			}
		}
		return hosts
	}
	inTx("BJf4 t", func(c *draftCase) {
		col := fmt.Sprintf("bf4a-%d", sfx)
		hosts := fold(c, col, 0, 3)
		if got := c.due(append(hosts, col)...); got != "" {
			c.t.Errorf("3 of 10 hosts crossing a slow ping together: %q, want nothing (their host rows wait for the fold)", got)
		}
	})
	inTx("BJf9a", func(c *draftCase) {
		col := fmt.Sprintf("bf9a-%d", sfx)
		hosts := fold(c, col, 3, 3)
		// db7: one other server of the collector, not answering for 4 minutes (as BJb4's), so 'server not answering' stands
		db7 := fmt.Sprintf("db7-%d", sfx)
		for k := 1; k <= 3; k++ {
			id := c.instance(fmt.Sprintf("bf9a-db7-%d-%d", k, sfx))
			for m := 10; m >= 5; m-- {
				c.load(col, id, m, 1, 0, db7)
			}
			for m := 4; m >= 1; m-- {
				c.load(col, id, m, 0, 1, db7)
			}
			c.exec(`INSERT INTO pgvigil.collector_spells (host, instance_id, kind, since, last)
				VALUES ($1, $2, 'down', date_trunc('minute', now()) - interval '4 minutes', date_trunc('minute', now()) - interval '1 minute')`, col, id)
		}
		// the recovered host: the tenth (never slow in this minute), its 'ping slow' row open and missing 11 minutes
		well := hosts[9]
		c.probeHost(col, well, fmt.Sprintf("10.5.%d.10:5432", sfx%200))
		c.openAlert("ping slow", well)
		var why string
		if err := c.tx.QueryRow(c.ctx, `SELECT string_agg(why, ',') FROM pgvigil.collector_parent WHERE host = $1`, col).Scan(&why); err != nil || why != "server not answering" {
			c.t.Fatalf("the control: the parents of %s are %q (%v), want 'server not answering' alone", col, why, err)
		}
		if got, want := c.due(append(hosts, col)...), "firing network slow from this collector "+col+"; resolved ping slow "+well; got != want {
			c.t.Errorf("the fold beside one other server not answering: %q, want %q (that parent stops no probe)", got, want)
		}
	})
	inTx("BJf4 t+1", func(c *draftCase) {
		col := fmt.Sprintf("bf4b-%d", sfx)
		hosts := fold(c, col, 3, 3)
		if got, want := c.due(append(hosts, col)...), "firing network slow from this collector "+col; got != want {
			c.t.Errorf("6 of 10 hosts slow: %q, want %q (the fold alone, the host rows held under it)", got, want)
		}
	})
}

// draftCase: one case of TestProbeAlertDueDraftOnAStore - its subtest, its transaction
type draftCase struct {
	t   *testing.T
	tx  pgx.Tx
	ctx context.Context
}

func (c *draftCase) exec(sql string, args ...any) {
	c.t.Helper()
	if _, err := c.tx.Exec(c.ctx, sql, args...); err != nil {
		f := strings.Fields(sql)
		c.t.Fatalf("%s %s: %v", f[0], f[2], err)
	}
}

func (c *draftCase) collector(col string, beatAgo int) {
	c.t.Helper()
	c.exec(`INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '2 hours', now() - make_interval(mins => $2))`, col, beatAgo)
}

func (c *draftCase) instance(name string) int {
	c.t.Helper()
	var id int
	if err := c.tx.QueryRow(c.ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`, name).Scan(&id); err != nil {
		c.t.Fatal(err)
	}
	return id
}

// load: one minute of an instance's load row on host's dial target (noanswer = its failed connect, unanswered)
func (c *draftCase) load(col string, id, minute, opened, noanswer int, host string) {
	c.t.Helper()
	c.exec(`INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target, noanswer)
		VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, 1, $4, 1, $5, 0, $6, $5)`, minute, id, col, opened, noanswer, "postgres:"+host+":5432")
}

func (c *draftCase) probe(col, host, addr string, minute, answered, ms int) {
	c.t.Helper()
	c.exec(`INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max, scheduled)
		VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, $4, 'tcp', 1, $5, $6::bigint, $6::int, true)`, minute, col, host, addr, answered, ms)
}

func (c *draftCase) probeHost(col, host, addr string) {
	c.t.Helper()
	c.exec(`INSERT INTO pgvigil.collector_probe_host (collector_id, host, address, first_probed, last_answered, last_method)
		VALUES ($1, $2, $3, now() - interval '1 hour', now() - interval '6 minutes', 'tcp')`, col, host, addr)
}

// openAlert: an open repository-wide alert on channel 'c', missing for 11 minutes (over the default clear_after)
func (c *draftCase) openAlert(setting, value string) {
	c.t.Helper()
	c.exec(`INSERT INTO pgvigil.alert_state (channel, finding_key, instance_id, instance_name, source, setting, value, severity, first_sent_at, last_sent_at, send_count, missing_since)
		VALUES ('c', pgvigil.alert_key(NULL, 'pgvigil repository', $1, $2), NULL, 'pgvigil', 'pgvigil repository', $1, $2, 'warning',
		        now() - interval '40 minutes', now() - interval '20 minutes', 1, now() - interval '11 minutes')`, setting, value)
}

// due: alert_due's repository-wide rows of B24h's kinds for channel 'c' and the values named, as 'event setting value'
// sorted and joined by '; '
func (c *draftCase) due(values ...string) string {
	c.t.Helper()
	rs, err := c.tx.Query(c.ctx, `SELECT event || ' ' || setting || ' ' || value FROM pgvigil.alert_due(now(), '[{"name":"c"}]')
	                               WHERE setting IN ('ping slow', 'host not answering ping', 'network slow from this collector')
	                                 AND source = 'pgvigil repository' AND value = ANY ($1)`, values)
	if err != nil {
		c.t.Fatalf("alert_due: %v", err)
	}
	got, err := pgx.CollectRows(rs, pgx.RowTo[string])
	if err != nil {
		c.t.Fatalf("alert_due: %v", err)
	}
	sort.Strings(got)
	return strings.Join(got, "; ")
}
