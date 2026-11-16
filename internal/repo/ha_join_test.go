package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// haJoinFreshStore is a database made for one test on the server PGVIGIL_REPO_TEST_DSN names (skipped without it; that
// login must be able to create a database), migrated from nothing by this binary's embedded files in name order and
// dropped when the test ends. A fresh database, not the scratch store the other store tests share: the HA join's
// faults are faults of the ORDER the files run in (0141-0144 and 0150 arrive below the join's own 0190, which is
// edited in place), and a store that applied an older 0190 never runs the new one.
func haJoinFreshStore(t *testing.T, ctx context.Context) *Repo {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("pgvha_%d", time.Now().UnixNano()%1_000_000_000)
	if _, err := admin.Exec(ctx, `CREATE DATABASE `+pgx.Identifier{name}.Sanitize()); err != nil {
		_ = admin.Close(ctx)
		t.Fatalf("a fresh database for the HA join's test: %v", err)
	}
	t.Cleanup(func() { // registered first: it runs last, after the store's pool below is closed
		bg := context.Background()
		if _, err := admin.Exec(bg, `DROP DATABASE IF EXISTS `+pgx.Identifier{name}.Sanitize()+` WITH (FORCE)`); err != nil {
			t.Errorf("drop %s: %v", name, err)
		}
		_ = admin.Close(bg)
	})
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.Database = name
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-repo"
	// jit off, as serve's own pool (web.go: the findings view crosses jit_above_cost on a near-empty store and each read
	// then compiles for a minute). Migrate sets it on the database for NEW sessions only, and this pool's first session
	// is the one that migrates: without the line every read of pgvigil.findings below would run on it with jit on.
	cfg.ConnConfig.RuntimeParams["jit"] = "off"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	r := &Repo{pool: pool}
	start := time.Now()
	n, err := r.Migrate(ctx)
	if err != nil {
		t.Fatalf("a fresh migrate of the joined tree stopped after %d file(s): %v", n, err)
	}
	t.Logf("the fresh migrate of %s: %d files in %s", name, n, time.Since(start).Round(time.Second))
	return r
}

// TestHAJoinOnAFreshStore: what the HA join (task 389) must hold on a store migrated from nothing.
//
//  1. The migrate itself ends, and the store reads current. 0141 stores threshold keys in megabytes (standby_lag_bytes,
//     slot_safe_wal, slot_growth) and 0150 one as a count (standby_conflicts); the join's 0190 runs after both and sets
//     the keys' unit check again for the slow-connect tier's 'seconds': its list holds every unit a stored key has
//     (a list of seconds, minutes, hours and days alone fails on the stored rows and ends the migrate at 0190).
//  2. A threshold key is taken at the instance and database level by an instance of the key's engines (0142's
//     pg_threshold_keys.engines): a SQL Server key (0142's repl_latency, 0143's ag_data_loss and logship_restore_age)
//     by a SQL Server instance and not by a PostgreSQL one, a PostgreSQL key the other way round, and uptime and the
//     slow-connect tier's connect_time by both. 0142 and 0190 each re-create import_pg_threshold whole and 0190 runs
//     last: its function reads the engines too, and its connect_time row names both.
//  3. purge() reaches what the HA files store without end: the monthly partitions of mssql_repl_sample (0142) and of
//     mssql_ag_replica_sample, mssql_ag_dbcounter_sample, mssql_mirroring_sample and mssql_logrestore_sample (0143)
//     go with purge()'s other sample parents; the role changes of a mirrored database, the owner changes of a failover
//     cluster instance and the seeding rows no read has replaced go by their time, as mssql_ag_failovers does; and
//     replication_hourly's months go by their own age through replication_hourly_purge() in purge()'s last block
//     (0150), named among the run's dropped partitions. A row or a month inside the age stays. mssql_repl_hourly
//     (0142) keeps a year of hours: its import trims a live instance's, purge() the rest of one no longer read.
//  4. The slices' findings reach pgvigil.findings, the one view the alerts and the Findings page read: a Patroni
//     cluster that two reads a minute apart find without a leader (0144's pg_patroni_checks) is a critical
//     'patroni no leader' finding of source 'patroni' there (0144 leaves that union arm to the join's 0190).
//  5. purge() and an availability group's import take the three AG sample parents in ONE order. purge() drops old
//     months by parent name (mssql_ag_dbcounter_sample, mssql_ag_replica_sample, mssql_ag_sample) and holds each
//     parent to its end; import_mssql_ag wrote them the other way round, so an import in flight held the last two and
//     waited for the first while purge held the first and waited for the second - PostgreSQL ends one of them
//     (40P01; purge has no retry). Shown with two sessions: a transaction holds the first parent as purge does after
//     its first drop, the import runs and waits, the transaction asks for the second parent - it gets it at once, and
//     the import ends without an error when the transaction commits.
//  6. 'pgvigil purge' builds the replication hours (0150) of an instance that waits for its first build: its stored
//     samples and no first build queued make it pending (replication_hourly_pending); Repo.ReplicationHourlyHeal
//     makes its months, builds it, queues the first build - it is pending no more and its hours are stored.
//  7. A fault the HA files judge is said once. 0118's alert set held two rules the HA files now judge with tiers of
//     their own: 'replay lag' (a sender 30 s behind; 0141's 'standby lag' judges the link over two reads) and 'AG
//     secondary behind' (a secondary 300 s behind; 0143's 'a secondary would lose data in a failover'). With a
//     standby 400 s behind at two reads a minute apart, and an availability group's secondary the same, each HA
//     finding stands in pgvigil.findings and neither of 0118's two names does.
//  8. Two files re-create pgvigil.mssql_hadr_findings whole: 0142 (0066's view less its two replication arms, with one
//     UNION ALL of its own mssql_repl_findings) and 0143 (every arm of the HA slice, and that same UNION ALL). In name
//     order 0143 runs last and its view stands. A guard on the view as the store ends with it: it reads
//     mssql_repl_findings, keeps 0143's arms, holds no replication arm of its own, and mssql_repl_findings is 0142's
//     (0143 makes a stand-in of 0066's two arms only where the view is missing).
//  9. Replication hours that could not be written are said. 0150's trigger never fails the import that stores the
//     samples: it keeps the hours as a range to rebuild and writes a 'rollup failed' row to collection_log
//     (collection 'replication_hourly'); the heal writes 'rollup healed'. From the failed row until the healed one the
//     instance carries the warning 'replication hours not rolled up' in pgvigil.findings (source 'pgvigil collector',
//     its value the samples' table), as the job statistics' hours do under their own name. Driven by 0150's own
//     writers, so a change of their notes shows here.
func TestHAJoinOnAFreshStore(t *testing.T) {
	// 5 minutes, under go test's own 10 for the package: a migrate that hangs ends here, where the cleanup still runs
	// and drops the database (a package timeout would leave pgvha_<n> behind)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	r := haJoinFreshStore(t, ctx)
	str := func(sql string, args ...any) string {
		t.Helper()
		var s string
		if err := r.pool.QueryRow(ctx, sql, args...).Scan(&s); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
		return s
	}
	want := func(what, got, exp string) {
		t.Helper()
		if got != exp {
			t.Errorf("%s:\n got  %s\n want %s", what, got, exp)
		}
	}

	// 1. the migrate ended (haJoinFreshStore), the store is current, the unit check takes every stored unit
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	if ok, name, err := r.SchemaCurrent(ctx); err != nil || !ok || name != names[len(names)-1] {
		t.Fatalf("the fresh store: SchemaCurrent = %v, %q, %v; want true, %s", ok, name, err, names[len(names)-1])
	}
	check := str(`SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
	               WHERE c.conrelid = 'pgvigil.pg_threshold_keys'::regclass AND c.conname = 'pg_threshold_keys_unit_check'`)
	for _, u := range []string{"seconds", "minutes", "hours", "days", "MB", "count"} {
		if !strings.Contains(check, "'"+u+"'") {
			t.Errorf("pg_threshold_keys' unit check lacks %q: %s", u, check)
		}
	}
	want("the keys in megabytes and counts (0141, 0150) and the slow-connect key (0190)",
		str(`SELECT string_agg(key || '=' || unit, ' ' ORDER BY key) FROM pgvigil.pg_threshold_keys
		      WHERE unit IN ('MB', 'count') OR key = 'connect_time'`),
		"connect_time=seconds slot_growth=MB slot_safe_wal=MB standby_conflicts=count standby_lag_bytes=MB")

	// 2. the engines rule of import_pg_threshold, as the store ends with it
	sfx := time.Now().UnixNano() % 1_000_000
	var ms, pg int
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("hajoin-ms-%d", sfx)).Scan(&ms); err != nil {
		t.Fatal(err)
	}
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '17.0', 170000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("hajoin-pg-%d", sfx)).Scan(&pg); err != nil {
		t.Fatal(err)
	}
	set := func(key, level string, inst int, db, warn, crit string) string {
		t.Helper()
		return str(`SELECT x->>'outcome' || ': ' || (x->>'detail')
		              FROM pgvigil.import_pg_threshold(now(), jsonb_strip_nulls(jsonb_build_object('op', 'set', 'ui_user', 'ha-join-test',
		                     'key', $1::text, 'level', $2::text, 'instance_id', $3::text, 'datname', nullif($4::text, ''),
		                     'warn', $5::text, 'crit', $6::text))) x`, key, level, fmt.Sprint(inst), db, warn, crit)
	}
	want("the engines of the two keys both engines take",
		str(`SELECT string_agg(key || '=' || array_to_string(engines, '+'), ' ' ORDER BY key) FROM pgvigil.pg_threshold_keys
		      WHERE key IN ('uptime', 'connect_time')`), "connect_time=postgres+sqlserver uptime=postgres+sqlserver")
	want("0142's repl_latency at a SQL Server instance", set("repl_latency", "instance", ms, "", "5", "30"), "done: set")
	want("0142's repl_latency at a PostgreSQL instance", set("repl_latency", "instance", pg, "", "5", "30"),
		fmt.Sprintf("refused: no SQL Server instance %d", pg))
	want("0143's ag_data_loss at a SQL Server instance", set("ag_data_loss", "instance", ms, "", "1", "5"), "done: set")
	want("0143's logship_restore_age at a SQL Server instance's database", set("logship_restore_age", "database", ms, "db1", "60", "120"), "done: set")
	want("0141's standby_replay_lag at a SQL Server instance", set("standby_replay_lag", "instance", ms, "", "30", "300"),
		fmt.Sprintf("refused: no PostgreSQL instance %d", ms))
	want("0141's standby_replay_lag at a PostgreSQL instance", set("standby_replay_lag", "instance", pg, "", "30", "300"), "done: set")
	want("connect_time at a SQL Server instance", set("connect_time", "instance", ms, "", "1", "2"), "done: set")
	want("connect_time at a PostgreSQL instance", set("connect_time", "instance", pg, "", "1", "2"), "done: set")
	want("uptime at a SQL Server instance", set("uptime", "instance", ms, "", "48", "12"), "done: set")

	// 3. purge(): an old month of each sample parent and of the hours table, an old and a new row of each dated table
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := r.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%v\n%s", err, sql)
		}
	}
	parents := []string{"mssql_ag_dbcounter_sample", "mssql_ag_replica_sample", "mssql_logrestore_sample", "mssql_mirroring_sample",
		"mssql_repl_sample", "replication_hourly"}
	for _, p := range parents {
		exec(`SELECT pgvigil.ensure_month_partition($1, '2019-03-15 00:00+00')`, p)
		want("March 2019's partition of "+p+" before the purge", str(`SELECT (to_regclass('pgvigil.' || $1 || '_201903') IS NOT NULL)::text`, p), "true")
	}
	exec(`INSERT INTO pgvigil.mssql_mirroring_role_changes (instance_id, database_name, at)
	      VALUES ($1, 'db1', now() - interval '400 days'), ($1, 'db1', now() - interval '1 day')`, ms)
	exec(`INSERT INTO pgvigil.mssql_fci_owner_changes (instance_id, at, old_node, new_node)
	      VALUES ($1, now() - interval '400 days', 'n1', 'n2'), ($1, now() - interval '1 day', 'n2', 'n1')`, ms)
	exec(`INSERT INTO pgvigil.mssql_ag_seeding (instance_id, group_id, database_name, remote_replica, snapshot_at, group_name)
	      VALUES ($1, 'g-old', 'db1', '', now() - interval '400 days', 'ag1'), ($1, 'g-new', 'db1', '', now() - interval '1 day', 'ag1')`, ms)
	exec(`INSERT INTO pgvigil.mssql_repl_hourly (instance_id, hour, series, kind, reads)
	      VALUES ($1, date_trunc('hour', now() - interval '800 days'), 's1', 'subscription', 1),
	             ($1, date_trunc('hour', now() - interval '300 days'), 's1', 'subscription', 1)`, ms)
	exec(`SELECT pgvigil.purge(30)`)
	dropped := str(`SELECT coalesce(array_to_string(partitions_dropped, ' '), '') FROM pgvigil.purge_runs ORDER BY finished_at DESC LIMIT 1`)
	for _, p := range parents {
		want("March 2019's partition of "+p+" after purge(30)", str(`SELECT (to_regclass('pgvigil.' || $1 || '_201903') IS NOT NULL)::text`, p), "false")
		if !strings.Contains(" "+dropped+" ", " "+p+"_201903 ") {
			t.Errorf("the purge run's dropped partitions lack %s_201903: %s", p, dropped)
		}
	}
	for _, c := range [][2]string{{"mssql_mirroring_role_changes", "at"}, {"mssql_fci_owner_changes", "at"}, {"mssql_ag_seeding", "snapshot_at"}} {
		want("the rows of "+c[0]+" after purge(30) (all / inside the age)",
			str(fmt.Sprintf(`SELECT count(*) || ' / ' || count(*) FILTER (WHERE %s > now() - interval '30 days') FROM pgvigil.%s WHERE instance_id = $1`,
				c[1], c[0]), ms), "1 / 1")
	}
	// an instance no import reaches any more: its hours past the year go with purge (the import's own trim never runs)
	want("the hours of mssql_repl_hourly after purge(30) (all / inside the year)",
		str(`SELECT count(*) || ' / ' || count(*) FILTER (WHERE hour > now() - interval '366 days') FROM pgvigil.mssql_repl_hourly WHERE instance_id = $1`, ms),
		"1 / 1")

	// 4. Patroni: a leader, then none at two reads 70 s apart (scripts/proof-patroni.sh's seeded row s1)
	var pat int
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '18.0', 180000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("hajoin-pat-%d", sfx)).Scan(&pat); err != nil {
		t.Fatal(err)
	}
	patRead := func(leader string) string {
		return `{"kind":"patroni_read","url":"u","ok":true,"cluster_ok":true,"scope":"c1","members":2,"leader":` + leader + `,"system_identifier":"s-c1"}`
	}
	patMember := func(member, role, state string) string {
		return `{"kind":"patroni","member":"` + member + `","role":"` + role + `","state":"` + state + `","api_ok":true}`
	}
	patImport := func(secondsAgo int, payload string) {
		t.Helper()
		exec(`SELECT pgvigil.import_patroni($1, now() - $2::int * interval '1 second', $3::jsonb)`, pat, secondsAgo, payload)
	}
	patImport(140, "["+patRead(`"m1"`)+","+patMember("m1", "leader", "running")+","+patMember("m2", "replica", "streaming")+"]")
	patImport(70, "["+patRead("null")+","+patMember("m2", "replica", "running")+"]")
	patImport(0, "["+patRead("null")+","+patMember("m2", "replica", "running")+"]")
	want("the Patroni checks of the cluster without a leader (the control: 0144's own view)",
		str(`SELECT coalesce(string_agg(severity || '|' || check_name || '|' || object, ',' ORDER BY check_name, object), '')
		       FROM pgvigil.pg_patroni_checks WHERE instance_id = $1`, pat), "critical|patroni member down|m1,critical|patroni no leader|c1")
	want("'patroni no leader' in pgvigil.findings",
		str(`SELECT count(*)::text FROM pgvigil.findings WHERE instance_id = $1 AND setting = 'patroni no leader' AND severity = 'critical' AND source = 'patroni'`, pat), "1")

	// 5. the lock order of purge() and import_mssql_ag over the three AG sample parents
	exec(`SELECT pgvigil.import_mssql_ag($1, now() - interval '1 minute', '[]'::jsonb)`, ms) // this month's partitions exist from here on
	pc, err := r.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Release()
	ptx, err := pc.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ptx.Rollback(context.Background()) }()
	for _, q := range []string{`SET LOCAL lock_timeout = '20s'`, `LOCK TABLE pgvigil.mssql_ag_dbcounter_sample IN ACCESS EXCLUSIVE MODE`} {
		if _, err := ptx.Exec(ctx, q); err != nil {
			t.Fatalf("%v\n%s", err, q)
		}
	}
	imported := make(chan error, 1)
	go func() {
		_, err := r.pool.Exec(ctx, `SELECT pgvigil.import_mssql_ag($1, now(), '[]'::jsonb)`, ms)
		imported <- err
	}()
	waits := false
	for i := 0; i < 100 && !waits; i++ { // 10 s at most: the import reaches its wait on the parent the transaction holds
		select {
		case err := <-imported:
			t.Fatalf("the AG import ended before it could wait for the parent the transaction holds: %v", err)
		default:
		}
		waits = str(`SELECT (count(*) > 0)::text FROM pg_locks WHERE relation = 'pgvigil.mssql_ag_dbcounter_sample'::regclass AND NOT granted
		                AND database = (SELECT oid FROM pg_database WHERE datname = current_database())`) == "true"
		if !waits {
			time.Sleep(100 * time.Millisecond)
		}
	}
	if !waits {
		t.Fatal("the import never waited for mssql_ag_dbcounter_sample: the two sessions did not meet")
	}
	if _, err := ptx.Exec(ctx, `LOCK TABLE pgvigil.mssql_ag_replica_sample IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Errorf("the purge-side transaction asking for its next parent while an AG import waits: %v", err)
	}
	if err := ptx.Commit(ctx); err != nil {
		t.Logf("the purge-side transaction's end: %v", err)
	}
	if err := <-imported; err != nil {
		t.Errorf("the AG import that ran beside the purge-side transaction: %v", err)
	}

	// 6. the purge command's heal of the replication hours
	for _, ago := range []string{"3 hours", "2 hours"} {
		exec(`SELECT pgvigil.ensure_month_partition('replication_sample', now() - $1::interval)`, ago)
		exec(`INSERT INTO pgvigil.replication_sample (instance_id, snapshot_at, kind, key, state, lag_bytes, active, detail)
		      VALUES ($1, now() - $2::interval, 'slot', 'hajoin_slot', 'reserved', 1048576, true, '{}'::jsonb)`, pg, ago)
	}
	pending := func() string {
		return str(`SELECT (EXISTS (SELECT 1 FROM pgvigil.replication_hourly_pending() i WHERE i = $1))::text`, pg)
	}
	want("the instance with samples and no first build, before the heal: pending", pending(), "true")
	// the INSERT's own trigger has already written the two hours (0150's replication_hourly_touch): they are taken out,
	// so the hours counted after the heal are the heal's
	exec(`DELETE FROM pgvigil.replication_hourly WHERE instance_id = $1`, pg)
	want("its hours before the heal (the trigger's taken out)", str(`SELECT count(*)::text FROM pgvigil.replication_hourly WHERE instance_id = $1`, pg), "0")
	built, hourRows, failedHeals, err := r.ReplicationHourlyHeal(ctx)
	if err != nil || failedHeals != 0 || built < 1 || hourRows < 2 {
		t.Errorf("ReplicationHourlyHeal = %d instance(s), %d hour rows, %d failed, %v; want 1 or more built, 2 or more hour rows, none failed", built, hourRows, failedHeals, err)
	}
	want("after the heal: pending", pending(), "false")
	want("after the heal: its first build queued / its slot's two hours stored again",
		str(`SELECT (EXISTS (SELECT 1 FROM pgvigil.replication_hourly_first_build b WHERE b.instance_id = $1))::text || ' / ' ||
		            (SELECT count(*) FROM pgvigil.replication_hourly h WHERE h.instance_id = $1 AND h.kind = 'slot' AND h.key = 'hajoin_slot')::text`, pg),
		"true / 2")

	// 7. 0118's 'replay lag' and 'AG secondary behind' beside the HA files' own findings of the same fault
	var lagPG, lagMS int
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '18.0', 180000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("hajoin-lagpg-%d", sfx)).Scan(&lagPG); err != nil {
		t.Fatal(err)
	}
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("hajoin-lagms-%d", sfx)).Scan(&lagMS); err != nil {
		t.Fatal(err)
	}
	// a primary's one physical standby, and an availability group's one secondary: each 400 s behind at both reads
	sender := `[{"kind":"sender","application_name":"sb1","client_addr":"10.0.0.2","state":"streaming","sync_state":"async",` +
		`"replay_lag_bytes":1048576,"flush_lag_bytes":0,"replay_lag_secs":400}]`
	secondary := `[{"kind":"database","group_id":"g1","group_name":"ag1","replica_server":"n2","database_name":"db1","is_local":0,` +
		`"is_primary_replica":0,"synchronization_state":"SYNCHRONIZING","is_suspended":0,"est_data_loss_s":400,"secondary_lag_s":400}]`
	for _, ago := range []string{"60 seconds", "0 seconds"} {
		exec(`SELECT pgvigil.import_replication($1, now() - $2::interval, $3::jsonb)`, lagPG, ago, sender)
		exec(`SELECT pgvigil.import_mssql_ag($1, now() - $2::interval, $3::jsonb)`, lagMS, ago, secondary)
	}
	want("the lagging standby in 0141's own view (the control: pg_hadr_checks)",
		str(`SELECT coalesce(string_agg(severity || '|' || check_name || '|' || object, ',' ORDER BY check_name, object), '')
		       FROM pgvigil.pg_hadr_checks WHERE instance_id = $1`, lagPG), "critical|standby lag|sb1 at 10.0.0.2")
	want("the lagging secondary in 0143's own view (the control: mssql_hadr_findings)",
		str(`SELECT coalesce(string_agg(severity || '|' || check_name || '|' || object, ',' ORDER BY check_name, object), '')
		       FROM pgvigil.mssql_hadr_findings WHERE instance_id = $1 AND check_name = 'a secondary would lose data in a failover'`, lagMS),
		"critical|a secondary would lose data in a failover|ag1 / n2 / db1")
	// one read of pgvigil.findings for the four names: the two HA findings, and 0118's two that say the same fault again
	want("the findings of the lagging standby and the lagging secondary, by name",
		str(`SELECT coalesce(string_agg(x.setting || ' ' || x.n, ', ' ORDER BY x.setting), '')
		       FROM (SELECT f.setting, count(*) AS n FROM pgvigil.findings f
		              WHERE f.instance_id IN ($1, $2)
		                AND f.setting IN ('standby lag', 'a secondary would lose data in a failover', 'replay lag', 'AG secondary behind')
		              GROUP BY f.setting) x`, lagPG, lagMS),
		"a secondary would lose data in a failover 1, standby lag 1")

	// 8. the final mssql_hadr_findings: 0143's view with 0142's change in it
	hadrView := str(`SELECT pg_get_viewdef('pgvigil.mssql_hadr_findings'::regclass)`)
	replView := str(`SELECT pg_get_viewdef('pgvigil.mssql_repl_findings'::regclass)`)
	for _, c := range []struct {
		what, def, text string
		holds           bool
	}{
		{"mssql_hadr_findings reads mssql_repl_findings (0142's one UNION ALL)", hadrView, "mssql_repl_findings", true},
		{"mssql_hadr_findings keeps 0143's arms", hadrView, "a secondary would lose data in a failover", true},
		{"mssql_hadr_findings holds 0066's 'a replication agent failed' arm itself", hadrView, "a replication agent failed", false},
		{"mssql_hadr_findings holds 0066's 'undistributed commands' arm itself", hadrView, "undistributed commands over the threshold", false},
		{"mssql_repl_findings is 0142's view (its 'replication latency' arm)", replView, "replication latency over the threshold", true},
	} {
		if strings.Contains(c.def, c.text) != c.holds {
			t.Errorf("%s: %v, want %v", c.what, !c.holds, c.holds)
		}
	}

	// 9. a failed rollup of the replication hours: 0150's own 'rollup failed' row raises the finding, its heal clears it
	var roll int
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '18.0', 180000, false, '{}'::text[], 'postgres')`,
		fmt.Sprintf("hajoin-roll-%d", sfx)).Scan(&roll); err != nil {
		t.Fatal(err)
	}
	logRows := func(status, like string) string {
		t.Helper()
		return str(`SELECT count(*)::text FROM pgvigil.collection_log
		             WHERE instance_id = $1 AND collection = 'replication_hourly' AND status = $2 AND note LIKE $3`, roll, status, like)
	}
	notRolledUp := func() string {
		t.Helper()
		return str(`SELECT coalesce(string_agg(severity || '|' || value || '|' || source, ',' ORDER BY value), 'none')
		              FROM pgvigil.findings WHERE instance_id = $1 AND setting = 'replication hours not rolled up'`, roll)
	}
	exec(`SELECT pgvigil.replication_hourly_failed($1, date_trunc('hour', now()) - interval '2 hours',
	                                               date_trunc('hour', now()) - interval '1 hour', 'a table in the way')`, roll)
	want("0150's 'rollup failed' row in collection_log (the control)", logRows("error", "rollup failed for the hours %"), "1")
	want("the failed rollup of the replication hours in pgvigil.findings", notRolledUp(), "warning|replication_sample|pgvigil collector")
	exec(`SELECT pgvigil.replication_hourly_heal_one($1)`, roll)
	want("0150's 'rollup healed' row in collection_log (the control)", logRows("ok", "rollup healed: the hours %"), "1")
	want("the finding after the heal", notRolledUp(), "none")
}
