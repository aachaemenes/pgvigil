package web

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// remoteSeed seeds remote instances and collectors the way the store holds them (review B, B1 / S1): through 0329's
// ledgers (remote_site_sync, import_remote_ensure, remote_bundle_begin / remote_bundle_done, remote_mark) when 0329's
// views are on the store - the joined tree, where V serves -, else into tables NAMED AS 0329's views with their
// columns (docs/remote-bundle-format.md's last section; V's branch alone), which the row that made them drops at its
// end. A table of that name the row did not make (an older run's) fails the row.
type remoteSeed struct {
	// queryText: the next instance's bundles' query_text ('' = hash, the remote default); configured: a site's
	// collectors as remote_sites: lists them (absent = every one seen is listed)
	queryText  string
	configured map[string][]string
	t          *testing.T
	ctx        context.Context
	pool       *pgxpool.Pool
	ledger     bool
	seq        int
	sites      []string
	ids        []int
}

var remoteFixtureDDL = []string{
	`CREATE TABLE pgvigil.remote_instance_state (instance_id int PRIMARY KEY, name text, engine text, site text,
	   collector text, as_of timestamptz, interval_secs int, expected_every_secs int, loaded_at timestamptz, query_text text)`,
	`CREATE TABLE pgvigil.remote_collection_interval (instance_id int, collection text, interval_secs int,
	   PRIMARY KEY (instance_id, collection))`,
	`CREATE TABLE pgvigil.remote_collector_state (site text, collector text, pgvigil_version text, host text,
	   heartbeat_at timestamptz, instances int, fail_streak int, newest_bundle_at timestamptz, gaps int, set_aside int,
	   newest_set_aside_reason text, late int, conflicts int, expected_every_secs int, newest_loaded_at timestamptz,
	   configured boolean, PRIMARY KEY (site, collector))`,
}

// remoteRelKind: pg_class.relkind of pgvigil.remote_instance_state ('v' 0329's view, 'r' a fixture table), "" none
func remoteRelKind(ctx context.Context, t *testing.T, pool *pgxpool.Pool) string {
	t.Helper()
	var kind *string
	if err := pool.QueryRow(ctx, `SELECT c.relkind::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
	                              WHERE n.nspname = 'pgvigil' AND c.relname = 'remote_instance_state'`).Scan(&kind); err != nil && err != pgx.ErrNoRows {
		t.Fatal(err)
	}
	if kind == nil {
		return ""
	}
	return *kind
}

func newRemoteSeed(ctx context.Context, t *testing.T, pool *pgxpool.Pool) *remoteSeed {
	t.Helper()
	s := &remoteSeed{t: t, ctx: ctx, pool: pool}
	switch k := remoteRelKind(ctx, t, pool); k {
	case "v":
		s.ledger = true
	case "":
		for _, q := range remoteFixtureDDL {
			if _, err := pool.Exec(ctx, q); err != nil {
				t.Fatal(err)
			}
		}
		t.Cleanup(func() {
			if _, err := pool.Exec(context.Background(), `DROP TABLE IF EXISTS pgvigil.remote_instance_state, pgvigil.remote_collection_interval, pgvigil.remote_collector_state`); err != nil {
				t.Errorf("the row's fixture tables not dropped: %v", err)
			}
		})
	default:
		t.Fatalf("pgvigil.remote_instance_state is a relation of kind %q this row did not make (an older run's fixture): drop it before the row", k)
	}
	t.Cleanup(s.clean)
	return s
}

func (s *remoteSeed) exec(q string, args ...any) {
	s.t.Helper()
	if _, err := s.pool.Exec(s.ctx, q, args...); err != nil {
		s.t.Fatalf("%s: %v", strings.Fields(q)[1], err)
	}
}

func (s *remoteSeed) site(site string, expected int) {
	s.t.Helper()
	s.sites = append(s.sites, site)
	if s.ledger {
		s.exec(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], $2, $3)`, site, expected, 3*expected)
	}
}

// bundle: one loaded bundle of an instance key through the ledgers, its window ending at 'to' and covering interval
// seconds, its heartbeat's fail streak, the collector's intervals
func (s *remoteSeed) bundle(site, collector, key string, id int, to time.Time, interval, failStreak int, iv map[string]int) {
	s.t.Helper()
	s.seq++
	var bid int64
	qt := s.queryText
	if qt == "" {
		qt = "hash"
	}
	if err := s.pool.QueryRow(s.ctx, `SELECT pgvigil.remote_bundle_begin($1, $2, $3, 'eeeeeeeeeeeeeeee', $4, $5, $6, $7, $8, $9)`, site, collector, key,
		s.seq, to.Add(-time.Duration(interval)*time.Second), to, fmt.Sprintf("d%d", s.seq), id, qt).Scan(&bid); err != nil {
		s.t.Fatalf("remote_bundle_begin: %v", err)
	}
	hb, _ := json.Marshal(map[string]any{"host": "h-" + collector, "started": to.Add(-time.Hour), "at": time.Now(), "instances": 1, "fail_streak": failStreak})
	ivs := []map[string]any{}
	for c, n := range iv {
		ivs = append(ivs, map[string]any{"collection": c, "interval_secs": n})
	}
	ivj, _ := json.Marshal(ivs)
	s.exec(`SELECT pgvigil.remote_bundle_done($1, $2::jsonb, $3::jsonb, 'v0.4.0')`, bid, string(hb), string(ivj))
}

// instance: one remote instance '<site>/<name>' read by collector, its newest bundle ending at asOf and covering
// interval seconds, the collector's per-collection intervals; collector "" = an instance with no bundle yet (no
// collector known, no as_of). Its id.
func (s *remoteSeed) instance(site, collector, engine, name string, asOf time.Time, interval int, iv map[string]int) int {
	s.t.Helper()
	var id int
	if s.ledger {
		if err := s.pool.QueryRow(s.ctx, `SELECT `+s.ensureFn()+`($1, $2, $3, 'onprem', '16.0', 160000, false, '{}'::text[])`, site, engine, name).Scan(&id); err != nil {
			s.t.Fatalf("%s: %v", s.ensureFn(), err)
		}
		s.ids = append(s.ids, id)
		if collector != "" {
			s.bundle(site, collector, name, id, asOf, interval, 0, iv)
		}
		return id
	}
	if err := s.pool.QueryRow(s.ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '16.0', 160000, false, '{}'::text[], $2)`, site+"/"+name, engine).Scan(&id); err != nil {
		s.t.Fatal(err)
	}
	s.ids = append(s.ids, id)
	expected := s.expectedOf(site)
	if collector == "" {
		s.exec(`INSERT INTO pgvigil.remote_instance_state VALUES ($1, $2, $3, $4, NULL, NULL, NULL, $5, NULL, NULL)`, id, site+"/"+name, engine, site, expected)
		return id
	}
	s.exec(`INSERT INTO pgvigil.remote_instance_state VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), $9)`, id, site+"/"+name, engine, site, collector, asOf, interval, expected, s.qtOrHash())
	for c, n := range iv {
		s.exec(`INSERT INTO pgvigil.remote_collection_interval VALUES ($1, $2, $3)`, id, c, n)
	}
	return id
}

// ensureFn: the remote ensure under the name the store's 0329 has (remote_ensure_instance since H's FOLD 1+2+3)
func (s *remoteSeed) ensureFn() string {
	var ok bool
	if err := s.pool.QueryRow(s.ctx, `SELECT to_regproc('pgvigil.remote_ensure_instance') IS NOT NULL`).Scan(&ok); err == nil && ok {
		return "pgvigil.remote_ensure_instance"
	}
	return "pgvigil.import_remote_ensure"
}

func (s *remoteSeed) qtOrHash() string {
	if s.queryText == "" {
		return "hash"
	}
	return s.queryText
}

// configure: the site's collectors as remote_sites: lists them (a collector seen and not listed is 'configured false')
func (s *remoteSeed) configure(site string, colls ...string) {
	s.t.Helper()
	if s.configured == nil {
		s.configured = map[string][]string{}
	}
	s.configured[site] = colls
	if s.ledger {
		s.exec(`SELECT pgvigil.remote_site_sync($1, '{}'::text[], $2, $3, $4::text[])`, site, s.expectedOf(site), 3*s.expectedOf(site), colls)
	}
}

func (s *remoteSeed) isConfigured(site, coll string) bool {
	l, ok := s.configured[site]
	if !ok {
		return true
	}
	for _, c := range l {
		if c == coll {
			return true
		}
	}
	return false
}

// expectedOf: the fixture path's expected_every of a site (the seeds' rule: 3600 for every site the rows name)
func (s *remoteSeed) expectedOf(string) int { return 3600 }

// collector: one remote collector of site as the Collector page reads it - its newest loaded bundle (nil: none), its
// heartbeat's fail streak, its open marks by kind in order (the last set-aside one is the newest reason)
func (s *remoteSeed) collector(site, collector string, newest *time.Time, failStreak int, marks ...string) {
	s.t.Helper()
	s.collectorLoaded(site, collector, newest, newest, failStreak, marks...)
}

// collectorLoaded: a collector whose newest bundle (window end 'newest') the hub loaded at 'loaded' (the silence is
// judged on the load: review C S4)
func (s *remoteSeed) collectorLoaded(site, collector string, newest, loaded *time.Time, failStreak int, marks ...string) {
	s.t.Helper()
	key := collector + "-i"
	reason := func(kind string) string { return "mssql_ag.ndjson.gz: " + kind }
	if s.ledger {
		end := time.Now()
		if newest != nil {
			var id int
			if err := s.pool.QueryRow(s.ctx, `SELECT `+s.ensureFn()+`($1, 'postgres', $2, 'onprem', '18.0', 180000, false, '{}'::text[])`, site, key).Scan(&id); err != nil {
				s.t.Fatalf("%s: %v", s.ensureFn(), err)
			}
			s.ids = append(s.ids, id)
			s.bundle(site, collector, key, id, *newest, 300, failStreak, nil)
			end = *newest
			if loaded != nil {
				if err := s.pool.QueryRow(s.ctx, `SELECT 1 FROM pg_attribute WHERE attrelid = 'pgvigil.remote_streams'::regclass AND attname = 'high_loaded_at'`).Scan(new(int)); err == nil {
					s.exec(`UPDATE pgvigil.remote_streams SET high_loaded_at = $3 WHERE site = $1 AND collector = $2`, site, collector, *loaded)
				}
			}
		}
		for i, k := range marks {
			s.exec(`SELECT pgvigil.remote_mark($1, $2, $3, 'eeeeeeeeeeeeeeee', $4, $5, $6, $7, $8)`, site, collector, key, 100+i, end, k, reason(k), fmt.Sprintf("m%d", i))
		}
		return
	}
	var gaps, aside, late, conflicts int
	var newestReason *string
	for _, k := range marks {
		switch k {
		case "gap":
			gaps++
		case "late":
			late++
		case "conflict":
			conflicts++
		case "audit gap":
		default:
			aside++
			r := k + ": " + reason(k)
			newestReason = &r
		}
	}
	instances := 0
	if newest != nil {
		instances = 1
	}
	s.exec(`INSERT INTO pgvigil.remote_collector_state VALUES ($1, $2, 'v0.4.0', $3, now(), $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
		site, collector, "h-"+collector, instances, failStreak, newest, gaps, aside, newestReason, late, conflicts, s.expectedOf(site), loaded, s.isConfigured(site, collector))
}

func (s *remoteSeed) clean() {
	c := context.Background()
	if len(s.ids) > 0 {
		for _, q := range []string{`DELETE FROM pgvigil.collection_dates WHERE instance_id = ANY ($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`} {
			if _, err := s.pool.Exec(c, q, s.ids); err != nil {
				s.t.Log(err)
			}
		}
	}
	if s.ledger && len(s.sites) > 0 {
		for _, q := range []string{`DELETE FROM pgvigil.remote_marks WHERE site = ANY ($1)`, `DELETE FROM pgvigil.remote_bundles WHERE site = ANY ($1)`,
			`DELETE FROM pgvigil.remote_collectors WHERE site = ANY ($1)`, `DELETE FROM pgvigil.remote_streams WHERE site = ANY ($1)`,
			`DELETE FROM pgvigil.remote_sites WHERE name = ANY ($1)`} {
			if _, err := s.pool.Exec(c, q, s.sites); err != nil {
				s.t.Log(err)
			}
		}
	}
}

func remoteStore(t *testing.T) (context.Context, *pgxpool.Pool) {
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
	return ctx, pool
}

func storeRead(ctx context.Context, t *testing.T, pool *pgxpool.Pool, what, q string, args ...any) []map[string]any {
	t.Helper()
	rows, err := pool.Query(ctx, q, args...)
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
	return out
}

// TestRemoteStaleOnAsOf (E3): a remote instance's collections are judged against its as_of (the newest loaded
// bundle's window end) with the intervals its collector reported (remote_collection_interval), never against the
// repository's clock - in the live read (the Summary and the header), Collection dates and the footer's counts
// (sqlFrameStatus: review B S5); the live read carries as_of, site, collector, interval_secs and expected_every_secs
// for the page; an instance the hub reads itself is judged as before.
func TestRemoteStaleOnAsOf(t *testing.T) {
	ctx, pool := remoteStore(t)
	sfx := time.Now().UnixNano() % 1000000000
	site := fmt.Sprintf("e3s%d", sfx)
	seed := newRemoteSeed(ctx, t, pool)
	seed.site(site, 3600)
	// the footer's counts before this row's rows (they are fleet-wide: the row reads its own difference)
	frame := func() (int64, int64) {
		f := storeRead(ctx, t, pool, "the footer", sqlFrameStatus, `{"defaults": {"mssql_storage": 900, "mssql_cpu": 900, "mssql_x": 60}, "instances": {}}`, DefaultStaleSecs, noPermission, "on", true, "")
		h, _ := f[0]["healthy"].(int64)
		st, _ := f[0]["stale"].(int64)
		return h, st
	}
	h0, s0 := frame()
	// (the footer's expectations read the hub's schedule from its own argument: mssql_x every 60 s here)
	asOf := time.Now().Add(-2 * time.Hour).Truncate(time.Second)
	// the collector's own schedule: storage every 5 minutes, CPU every minute
	rem := seed.instance(site, "c1", "sqlserver", fmt.Sprintf("rs-%d", sfx), asOf, 300, map[string]int{"mssql_storage": 300, "mssql_cpu": 60})
	var own int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`, fmt.Sprintf("rs-own-%d", sfx)).Scan(&own); err != nil {
		t.Fatal(err)
	}
	seed.ids = append(seed.ids, own)
	for _, q := range []struct {
		sql  string
		args []any
	}{
		// storage read a minute before the bundle closed (healthy against as_of); CPU 20 minutes before (stale: past 5 min)
		{`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_storage', $2::timestamptz - interval '1 minute', 'ok'),
		   ($1, 'mssql_cpu', $2::timestamptz - interval '20 minutes', 'ok')`, []any{rem, asOf}},
		// review C N3: a collection its collector reported no interval for, 10 minutes before as_of - judged by the default
		// stale age (3 h), never by this hub's own schedule for it (60 s here: stale at 300 s)
		{`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_x', $2::timestamptz - interval '10 minutes', 'ok')`, []any{rem, asOf}},
		{`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status) VALUES ($1, 'mssql_storage', now() - interval '1 minute', 'ok')`, []any{own}},
	} {
		if _, err := pool.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatal(err)
		}
	}
	exp, _ := json.Marshal(map[string]any{"defaults": map[string]int{"mssql_storage": 900, "mssql_cpu": 900, "mssql_x": 60}, "instances": map[string]any{}})
	num := func(v any) int64 { n, _ := v.(int64); return n }
	for _, c := range []struct {
		id             int
		healthy, stale int64
		remote         bool
	}{{rem, 2, 1, true}, {own, 1, 0, false}} {
		live := storeRead(ctx, t, pool, "the live read", sqlAckLive, time.Now(), string(exp), DefaultStaleSecs, noPermission, c.id)
		if len(live) != 1 {
			t.Fatalf("the live read of %d: %d rows", c.id, len(live))
		}
		r := live[0]
		if num(r["coll_healthy"]) != c.healthy || num(r["coll_stale"]) != c.stale {
			t.Errorf("the live read of %v: healthy %v stale %v, want %d / %d", r["instance"], r["coll_healthy"], r["coll_stale"], c.healthy, c.stale)
		}
		if _, has := r["as_of"]; !has {
			t.Errorf("the live read carries no as_of")
			continue
		}
		if c.remote {
			if at, _ := r["as_of"].(time.Time); !at.Equal(asOf) || r["site"] != site || r["collector"] != "c1" || r["interval_secs"] != int32(300) || r["expected_every_secs"] != int32(3600) {
				t.Errorf("the live read's remote fields: as_of %v site %v collector %v interval %v expected %v", r["as_of"], r["site"], r["collector"], r["interval_secs"], r["expected_every_secs"])
			}
			// review C S4: the hub's load time, the silence's clock (never the site's as_of)
			if at, ok := r["loaded_at"].(time.Time); !ok || time.Since(at) > 10*time.Minute {
				t.Errorf("the live read's loaded_at (the hub's load of the newest bundle): %v", r["loaded_at"])
			}
		} else if r["as_of"] != nil || r["site"] != nil {
			t.Errorf("an instance the hub reads itself has remote fields: %v %v", r["as_of"], r["site"])
		}
	}
	got := map[string]any{}
	for _, r := range storeRead(ctx, t, pool, "collection dates", sqlCollectionDates, string(exp), DefaultStaleSecs, 0, []int{rem, own}) {
		got[fmt.Sprintf("%v/%v", r["instance_id"], r["collection"])] = r["status"]
		// review C S6: the age is the snapshot's real age (the hub's clock), the status judged against as_of
		if r["instance_id"] == int32(rem) && r["collection"] == "mssql_storage" {
			if age, _ := r["age_secs"].(int64); age < 7000 {
				t.Errorf("the remote storage read's age_secs: %v, want its real age (over 2 h), not its age at as_of", r["age_secs"])
			}
		}
	}
	for k, want := range map[string]string{fmt.Sprintf("%d/mssql_storage", rem): "ok", fmt.Sprintf("%d/mssql_cpu", rem): "warning", fmt.Sprintf("%d/mssql_x", rem): "ok", fmt.Sprintf("%d/mssql_storage", own): "ok"} {
		if got[k] != want {
			t.Errorf("collection dates %s: %v, want %s", k, got[k], want)
		}
	}
	// the footer: the remote's storage and the own instance's healthy, the remote's CPU stale against as_of
	if h1, s1 := frame(); h1-h0 != 3 || s1-s0 != 1 {
		t.Errorf("the footer's counts moved healthy %+d stale %+d, want +3 / +1 (the remote judged against as_of, mssql_x by the default age)", h1-h0, s1-s0)
	}
}

// TestRemoteCollectorPart (E6): the Collector page's remote part names each remote collector with its site's silence -
// sending inside 2 x expected_every, a warning past it, critical past 6 x, 'no bundle yet' before the first - judged by
// its SITE's expected_every (review B S6: a collector with no instance row takes its site's, never 300 s), and the
// ledgers' counts as 0329's view gives them. No red of its own for the part: it is new (its red is its absence).
func TestRemoteCollectorPart(t *testing.T) {
	ctx, pool := remoteStore(t)
	site := fmt.Sprintf("rcp%d", time.Now().UnixNano()%1000000000)
	seed := newRemoteSeed(ctx, t, pool)
	seed.site(site, 3600)
	at := func(d time.Duration) *time.Time { x := time.Now().Add(-d).Truncate(time.Second); return &x }
	seed.configure(site, "ok", "warn", "crit", "none", "skew") // remote_sites: lists these (never "gone")
	seed.collector(site, "ok", at(10*time.Minute), 0)
	seed.collector(site, "warn", at(3*time.Hour), 0, "gap", "checksum", "late", "late")
	seed.collector(site, "crit", at(7*time.Hour), 4, "conflict")
	seed.collector(site, "none", nil, 0, "signature")
	// review C S4: a site clock 3 h behind - the window ended 3 h ago, the hub loaded it 10 minutes ago: sending
	seed.collectorLoaded(site, "skew", at(3*time.Hour), at(10*time.Minute), 0)
	// review C N5 (H part 3 S7): a collector remote_sites: no longer lists - said so, never 'critical' for good
	seed.collector(site, "gone", at(7*time.Hour), 0)
	got := map[string]map[string]any{}
	for _, r := range storeRead(ctx, t, pool, "the Collector page's remote part", sqlCollectorRemote) {
		if r["site"] == site {
			got[fmt.Sprint(r["collector"])] = r
		}
	}
	for c, want := range map[string]string{"ok": "ok", "warn": "warning", "crit": "critical", "none": "no bundle yet", "skew": "ok", "gone": "not in remote_sites:"} {
		if got[c] == nil || got[c]["silence"] != want {
			t.Errorf("collector %s: silence %v, want %s", c, got[c]["silence"], want)
		}
	}
	if r := got["warn"]; r == nil || !strings.HasPrefix(fmt.Sprint(r["newest_set_aside_reason"]), "checksum: ") || r["late"] != int32(2) || r["gaps"] != int32(1) ||
		r["set_aside"] != int32(1) || r["expected_every_secs"] != int32(3600) {
		t.Errorf("collector warn's counts: %v", r)
	}
	if r := got["crit"]; r == nil || r["fail_streak"] != int32(4) || r["conflicts"] != int32(1) {
		t.Errorf("collector crit's counts: %v", r)
	}
	if r := got["none"]; r == nil || r["expected_every_secs"] != int32(3600) || r["set_aside"] != int32(1) {
		t.Errorf("a collector with no bundle and no instance takes its site's expected_every (3600 s): %v", r)
	}
}

// TestReadRemoteOnAStore (review B S2 / S3 / S1): readRemote reads every instance a site owns - one whose collector
// is not known yet (its bundles all set aside or loading: collector NULL) reads with an empty collector, never failing
// the read - and, on a store with no remote_instance_state at all (a repository before 0329, after the fixture rows
// dropped their tables: V's branch alone), answers none and no error.
func TestReadRemoteOnAStore(t *testing.T) {
	ctx, pool := remoteStore(t)
	if remoteRelKind(ctx, t, pool) == "" {
		if rows, err := readRemote(ctx, pool); err != nil || rows != nil {
			t.Errorf("readRemote before 0329: %v %v, want none and no error", rows, err)
		}
	} else {
		t.Log("0329's view is on this store: the 'before 0329' half is V's branch alone's")
	}
	sfx := time.Now().UnixNano() % 1000000000
	site := fmt.Sprintf("rr%d", sfx)
	seed := newRemoteSeed(ctx, t, pool)
	seed.site(site, 3600)
	asOf := time.Now().Add(-10 * time.Minute).Truncate(time.Second)
	seed.instance(site, "c1", "sqlserver", "SQL01", asOf, 300, nil)
	seed.instance(site, "", "postgres", "pg-new", time.Time{}, 0, nil)
	rows, err := readRemote(ctx, pool)
	if err != nil {
		t.Fatalf("readRemote: %v", err)
	}
	by := map[string]remoteRow{}
	for _, r := range rows {
		by[r.Name] = r
	}
	if r, ok := by[site+"/SQL01"]; !ok || r.Engine != "sqlserver" || r.Door.Site != site || r.Door.Collector != "c1" || !r.Door.AsOf.Equal(asOf) ||
		r.Door.Every != 5*time.Minute || r.Door.ExpectedEvery != time.Hour {
		t.Errorf("readRemote's SQL01: %+v (found %v)", r, ok)
	}
	if r, ok := by[site+"/pg-new"]; !ok || r.Door.Collector != "" || r.Door.Site != site || !r.Door.AsOf.IsZero() {
		t.Errorf("readRemote's instance with no collector yet: %+v (found %v)", r, ok)
	} else if why := r.Door.from(); why != "a remote collector of site "+site {
		t.Errorf("its door's words: %q, want 'a remote collector of site %s'", why, site)
	}
}

// TestReadRemoteNoGrantOnAStore (review B N3): a serve login with no SELECT on the remote instances (0329 grants it to
// pgvigil_reader) gets that said - the grant named - not a generic read error
func TestReadRemoteNoGrantOnAStore(t *testing.T) {
	ctx, pool := remoteStore(t)
	newRemoteSeed(ctx, t, pool) // the relation exists (0329's view, or the fixture table)
	pc, err := pgx.ParseConfig(os.Getenv("PGVIGIL_REPO_TEST_DSN"))
	if err != nil {
		t.Fatal(err)
	}
	role := fmt.Sprintf("rrng_%d", time.Now().UnixNano()%1000000000)
	if _, err := pool.Exec(ctx, fmt.Sprintf(`CREATE ROLE %s LOGIN`, role)); err != nil {
		t.Skipf("this store's login may not make a login role: %v", err)
	}
	t.Cleanup(func() { _, _ = pool.Exec(context.Background(), fmt.Sprintf(`DROP ROLE IF EXISTS %s`, role)) })
	np, err := pgxpool.New(ctx, fmt.Sprintf("host=%s port=%d user=%s dbname=%s", pc.Host, pc.Port, role, pc.Database))
	if err != nil {
		t.Fatal(err)
	}
	defer np.Close()
	if _, err := readRemote(ctx, np); err == nil || !strings.Contains(err.Error(), "pgvigil_reader") || !strings.Contains(err.Error(), "SELECT") {
		t.Errorf("readRemote as a login with no grant: %v, want the grant named (SELECT ... pgvigil_reader)", err)
	}
}
