package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// azhAvg: the minutes' averaged figures, their maxima and the hour's column stem (0167's hour shape)
var azhAvg = [][3]string{{"avg_cpu_percent", "max_cpu_percent", "cpu"}, {"avg_data_io_percent", "max_data_io_percent", "data_io"},
	{"avg_log_write_percent", "max_log_write_percent", "log_write"}, {"avg_memory_usage_percent", "max_memory_usage_percent", "memory_usage"},
	{"avg_xtp_storage_percent", "max_xtp_storage_percent", "xtp_storage"}, {"avg_instance_cpu_percent", "max_instance_cpu_percent", "instance_cpu"},
	{"avg_instance_memory_percent", "max_instance_memory_percent", "instance_memory"}, {"avg_dtu_percent", "max_dtu_percent", "dtu_percent"},
	{"avg_dtu", "max_dtu", "dtu"}}

// azhHourFromMinutes: every column of an hour row (but instance_id and snapshot_at) computed here from the minutes of
// [$2, $2 + 1 hour) of instance $1, written apart from 0167's generated recompute
func azhHourFromMinutes() string {
	cols := []string{"count(*)::int AS minutes", "sum(samples)::int AS samples"}
	for _, a := range azhAvg {
		cols = append(cols, fmt.Sprintf("sum(%[1]s * samples) AS %[3]s_total, (sum(samples) FILTER (WHERE %[1]s IS NOT NULL))::int AS %[3]s_counted, max(%[2]s) AS %[2]s", a[0], a[1], a[2]))
	}
	cols = append(cols, "max(max_worker_percent) AS max_worker_percent", "max(max_session_percent) AS max_session_percent",
		"min(dtu_limit) AS min_dtu_limit", "max(dtu_limit) AS max_dtu_limit", "min(cpu_limit) AS min_cpu_limit", "max(cpu_limit) AS max_cpu_limit",
		"max(replica_role) AS replica_role")
	for _, h := range []string{"dtu", "cpu", "data", "log"} {
		b := make([]string, 10)
		for k := range b {
			b[k] = fmt.Sprintf("coalesce(sum(%s_buckets[%d]), 0)", h, k+1)
		}
		cols = append(cols, "ARRAY["+strings.Join(b, ", ")+"]::int[] AS "+h+"_buckets")
	}
	return `SELECT ` + strings.Join(cols, ", ") + `
  FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $2 + interval '1 hour' HAVING count(*) > 0`
}

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0167's hours of mssql_azuredb_minute (task
// B2a-N2): each hour's 42 columns equal its minutes' (every figure varied, uneven samples, minutes with no averages);
// a late minute recomputes its hour; a dirty range over corrupted built hours is rebuilt (a heal that adds, or does
// nothing, is caught); two imports of one instance at once leave the hour exact; a failure (no partition can be made)
// keeps the minutes, writes 'rollup failed', and an import in ANOTHER hour heals it; a 'pgvigil purge' heal held open
// past two lock timeouts while an hour's last minute is imported leaves that hour dirty, never short, and the
// import's lock_timeout its own; a heal that read a range keeps it when a failure merged into it meanwhile; hours are
// UTC under a +05:30 session; purge drops a month older than 730 days and keeps the rest. Each row names the broken
// variant it catches. A second run on the same store in the same month passes (the test's months dropped after it).
func TestAzureDBHoursOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("azh-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	// the failure row's month (a plain table named as its partition, then the real one) and the purge row's
	future := time.Now().UTC().AddDate(0, 3, 0)
	part := "mssql_azuredb_hour_" + future.Format("200601")
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_azuredb_hour WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`,
			`DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
		if _, err := pool.Exec(context.Background(), `DROP TABLE IF EXISTS pgvigil.`+part); err != nil {
			t.Error(err)
		}
	}()
	h0 := time.Now().UTC().Truncate(time.Hour).Add(-30 * time.Hour)
	// every figure varies by the minute's index k; every 17th minute carries no averages (counted < samples)
	minute := func(at time.Time, samples int) map[string]any {
		k := int(at.Sub(h0) / time.Minute)
		avg := func(off int) any {
			if k%17 == 0 {
				return nil
			}
			return float64((k*7+off)%97) + 0.25
		}
		top := func(off int) float64 { return float64((k*7+off)%97) + 1.5 }
		var cpuLimit any = 2 + float64(k%2)
		if k%3 == 0 {
			cpuLimit = nil
		}
		role := 0
		if k%5 == 0 {
			role = 1
		}
		bucket := func(off int) []int {
			b := make([]int, 10)
			b[(k+off)%10] = samples
			return b
		}
		return map[string]any{"kind": "minute", "minute": at.Format(time.RFC3339), "samples": samples,
			"avg_cpu_percent": avg(0), "max_cpu_percent": top(0), "avg_data_io_percent": avg(11), "max_data_io_percent": top(11),
			"avg_log_write_percent": avg(23), "max_log_write_percent": top(23), "avg_memory_usage_percent": avg(31), "max_memory_usage_percent": top(31),
			"avg_xtp_storage_percent": avg(41), "max_xtp_storage_percent": top(41), "max_worker_percent": float64(k%13) + 0.5,
			"max_session_percent": float64(k%11) + 0.75, "avg_instance_cpu_percent": avg(53), "max_instance_cpu_percent": top(53),
			"avg_instance_memory_percent": avg(61), "max_instance_memory_percent": top(61), "dtu_limit": 5 + 5*((k/30)%2), "cpu_limit": cpuLimit,
			"replica_role": role, "avg_dtu_percent": avg(71), "max_dtu_percent": top(71), "avg_dtu": avg(83),
			"max_dtu": top(83), "dtu_buckets": bucket(0), "cpu_buckets": bucket(3), "data_buckets": bucket(5), "log_buckets": bucket(7)}
	}
	imp := func(rows ...map[string]any) {
		t.Helper()
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	unstore := func(at time.Time) {
		t.Helper()
		if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at = $2`, id, at); err != nil {
			t.Fatal(err)
		}
	}
	// the hour row against its minutes, column for column (jsonb compares numbers by value: 1.50 = 1.5000)
	fromMinutes := azhHourFromMinutes()
	check := func(what string, hour time.Time) {
		t.Helper()
		var bad string
		if err := pool.QueryRow(ctx, `
WITH m AS (`+fromMinutes+`)
SELECT CASE WHEN h.instance_id IS NULL THEN 'no hour row'
            ELSE coalesce((SELECT string_agg(format('%s: hour %s, minutes %s', d.key, d.hv, d.mv), '; ' ORDER BY d.key)
                             FROM (SELECT coalesce(x.key, y.key) AS key, x.value AS hv, y.value AS mv
                                     FROM jsonb_each(to_jsonb(h) - 'instance_id' - 'snapshot_at') x
                                     FULL JOIN jsonb_each(to_jsonb(m)) y ON y.key = x.key
                                    WHERE x.value IS DISTINCT FROM y.value) d), '') END
  FROM m LEFT JOIN pgvigil.mssql_azuredb_hour h ON h.instance_id = $1 AND h.snapshot_at = $2`, id, hour).Scan(&bad); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
		if bad != "" {
			t.Errorf("%s (%s): %s", what, hour.Format("15:04"), bad)
		}
	}
	str := func(q string, args ...any) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, q, args...).Scan(&s); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return s
	}
	dirty := func() string {
		t.Helper()
		return str(`SELECT coalesce((SELECT to_char(from_at AT TIME ZONE 'UTC', 'DD HH24:MI') || '-' || to_char(to_at AT TIME ZONE 'UTC', 'DD HH24:MI')
		                               FROM pgvigil.mssql_azuredb_hour_dirty WHERE instance_id = $1), 'none')`, id)
	}
	logRows := func(status, like string) string {
		t.Helper()
		return str(`SELECT count(*)::text FROM pgvigil.collection_log WHERE instance_id = $1 AND collection = 'mssql_azuredb_hour' AND status = $2 AND note LIKE $3`,
			id, status, like)
	}
	hourText := func(h time.Time) string { return h.Format("2006-01-02 15:04") }

	// 30 hours of minutes, imported 10 at a time (one statement each), 3 or 4 samples a minute
	for m := 0; m < 30*60; m += 10 {
		rows := []map[string]any{}
		for k := 0; k < 10; k++ {
			rows = append(rows, minute(h0.Add(time.Duration(m+k)*time.Minute), 3+(m+k)%2))
		}
		imp(rows...)
	}
	for _, h := range []int{0, 5, 17, 29} {
		check("a built hour (a figure summed wrong, a column from another's filter, a second trigger call adding)", h0.Add(time.Duration(h)*time.Hour))
	}

	// a late minute in an old hour recomputes that hour (a trigger that skips old hours)
	unstore(h0.Add(7*time.Hour + 30*time.Minute))
	imp(minute(h0.Add(7*time.Hour+30*time.Minute), 4))
	check("a late minute's hour", h0.Add(7*time.Hour))

	// a dirty range over two built hours, both corrupted first, healed by heal_one: each equals its minutes again (a heal
	// that adds doubles them; a heal that does nothing leaves samples 0)
	if _, err := pool.Exec(ctx, `UPDATE pgvigil.mssql_azuredb_hour SET samples = 0, cpu_total = 0 WHERE instance_id = $1 AND snapshot_at IN ($2, $3)`,
		id, h0.Add(2*time.Hour), h0.Add(3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_hour_dirty (instance_id, from_at, to_at, why) VALUES ($1, $2, $3, 'test')`,
		id, h0.Add(2*time.Hour), h0.Add(4*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_heal_one($1)`, id); err != nil {
		t.Fatal(err)
	}
	check("a healed dirty hour", h0.Add(2*time.Hour))
	check("a healed dirty hour", h0.Add(3*time.Hour))
	if d := dirty(); d != "none" {
		t.Errorf("after heal_one: dirty range %s, want none", d)
	}

	// two imports of one instance at once, the first held open in its transaction: the second waits on THIS instance's
	// lock (pg_locks, not any advisory wait of the cluster) and the hour is exact (a missing lock loses a minute); the
	// first commits within 3 s, well inside the trigger's 5 s lock_timeout
	h2 := h0.Add(10 * time.Hour)
	unstore(h2.Add(50 * time.Minute))
	unstore(h2.Add(51 * time.Minute))
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	p1, _ := json.Marshal([]map[string]any{minute(h2.Add(50*time.Minute), 4)})
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(p1)); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		p2, _ := json.Marshal([]map[string]any{minute(h2.Add(51*time.Minute), 3)})
		_, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(p2))
		done <- err
	}()
	waited := false
	for i := 0; i < 30 && !waited; i++ {
		time.Sleep(100 * time.Millisecond)
		_ = pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND objid = $1::int::oid AND objsubid = 2
		                                      AND pid <> pg_backend_pid())`, id).Scan(&waited)
	}
	if !waited {
		t.Error("the second import never waited on the instance's lock")
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	check("two imports at once", h2)
	if d := dirty(); d != "none" {
		t.Errorf("after two imports at once: dirty range %s, want none (the second waited past its lock_timeout)", d)
	}

	// a failure: a plain table named as a future month's partition (it cannot be attached), the minutes kept, the
	// 'rollup failed' row; then, the table gone, an import in ANOTHER hour heals it (a failure that failed the import;
	// a heal that never runs - the failed hour's own import would recompute it without one)
	if _, err := pool.Exec(ctx, `DROP TABLE IF EXISTS pgvigil.`+part); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `CREATE TABLE pgvigil.`+part+` (x int)`); err != nil {
		t.Fatal(err)
	}
	fm := time.Date(future.Year(), future.Month(), 2, 0, 0, 0, 0, time.UTC)
	imp(minute(fm, 4), minute(fm.Add(time.Minute), 3))
	if n := str(`SELECT count(*)::text FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $2 + interval '1 hour'`, id, fm); n != "2" {
		t.Errorf("a failed rollup: %s minutes kept, want 2", n)
	}
	if n := logRows("error", "rollup failed for the hours "+hourText(fm)+"%"); n != "1" {
		t.Errorf("a failed rollup: %s 'rollup failed' rows, want 1", n)
	}
	if _, err := pool.Exec(ctx, `DROP TABLE pgvigil.`+part); err != nil {
		t.Fatal(err)
	}
	unstore(h0.Add(20*time.Hour + 30*time.Minute))
	imp(minute(h0.Add(20*time.Hour+30*time.Minute), 4))
	check("the failed hour, healed by an import in another hour", fm)
	check("that import's own hour", h0.Add(20*time.Hour))
	if d := dirty(); d != "none" {
		t.Errorf("after the heal: dirty range %s, want none", d)
	}
	if n := logRows("ok", "rollup healed: the hours "+hourText(fm)+"%"); n != "1" {
		t.Errorf("%s 'rollup healed' rows, want 1", n)
	}

	// (a) 'pgvigil purge' builds the instance (heal_one, its first_build row gone: the whole range queued, an
	// uncommitted dirty row) and is held open 12 s; meanwhile hour H's last minute is imported under lock_timeout 17s.
	// The import's trigger gives up on the lock at 5 s; its record must wait for the heal (a leaked 5 s gives up again
	// at 10 s, leaves a WARNING alone, and H, rebuilt before the minute committed, short for good), and the import's
	// own lock_timeout is 17s again after it (a leaked 5 s cuts every later statement of the import short)
	hA := h0.Add(15 * time.Hour)
	unstore(hA.Add(59 * time.Minute))
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.mssql_azuredb_hour_first_build WHERE instance_id = $1`, id); err != nil {
		t.Fatal(err)
	}
	purgeTx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := purgeTx.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_heal_one($1)`, id); err != nil {
		_ = purgeTx.Rollback(ctx)
		t.Fatal(err)
	}
	type impResult struct {
		lockTimeout string
		err         error
	}
	impDone := make(chan impResult, 1)
	go func() {
		var res impResult
		defer func() { impDone <- res }()
		itx, err := pool.Begin(ctx)
		if err != nil {
			res.err = err
			return
		}
		defer func() { _ = itx.Rollback(ctx) }()
		pa, _ := json.Marshal([]map[string]any{minute(hA.Add(59*time.Minute), 4)})
		if _, res.err = itx.Exec(ctx, `SET LOCAL lock_timeout = '17s'`); res.err != nil {
			return
		}
		if _, res.err = itx.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(pa)); res.err != nil {
			return
		}
		if res.err = itx.QueryRow(ctx, `SHOW lock_timeout`).Scan(&res.lockTimeout); res.err != nil {
			return
		}
		res.err = itx.Commit(ctx)
	}()
	time.Sleep(12 * time.Second)
	if err := purgeTx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case res := <-impDone:
		if res.err != nil {
			t.Errorf("(a) the import during a held heal: %v", res.err)
		}
		if res.lockTimeout != "17s" {
			t.Errorf("(a) the import's lock_timeout after its trigger: %q, want \"17s\" (the trigger's 5 s leaked)", res.lockTimeout)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("(a) the import did not end 30 s after the heal committed")
	}
	if d := dirty(); d != hA.Format("02 15:04")+"-"+hA.Add(time.Hour).Format("02 15:04") {
		t.Errorf("(a) dirty range %s, want H's hour %s (the record lost)", d, hA.Format("15:04"))
	}
	if n := logRows("error", "rollup failed for the hours "+hourText(hA)+"%"); n != "1" {
		t.Errorf("(a) %s 'rollup failed' rows for H, want 1", n)
	}
	unstore(h0.Add(21*time.Hour + 30*time.Minute))
	imp(minute(h0.Add(21*time.Hour+30*time.Minute), 4)) // the next import, in another hour, heals H
	check("(a) H after the heal held open, healed by the next import", hA)
	if d := dirty(); d != "none" {
		t.Errorf("(a) after the next import: dirty range %s, want none", d)
	}

	// (b) a heal that read a range keeps it when a failure merged into it meanwhile: a committed range [H1, H2 + 1 h);
	// heal_one reads it and waits on H1's hour row another transaction holds; an import of a minute of H2 times out on
	// the instance's lock (5 s), merges H2 into the range (no wider) and commits; the holder lets go; the heal must not
	// remove the range (one that matches from and to alone deletes it and leaves H2 short for good)
	h1b, h2b := h0.Add(24*time.Hour), h0.Add(25*time.Hour)
	unstore(h2b.Add(20 * time.Minute))
	if d := dirty(); d != "none" {
		t.Fatalf("(b) a dirty range before the row: %s", d)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_azuredb_hour_dirty (instance_id, from_at, to_at, why) VALUES ($1, $2, $3, 'test (b)')`,
		id, h1b, h2b.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	holder, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := holder.Exec(ctx, `UPDATE pgvigil.mssql_azuredb_hour SET samples = samples WHERE instance_id = $1 AND snapshot_at = $2`, id, h1b); err != nil {
		_ = holder.Rollback(ctx)
		t.Fatal(err)
	}
	healed := make(chan error, 1)
	go func() {
		_, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_heal_one($1)`, id)
		healed <- err
	}()
	held := false
	for i := 0; i < 30 && !held; i++ {
		time.Sleep(100 * time.Millisecond)
		_ = pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE query LIKE '%mssql_azuredb_hour_heal_one%' AND wait_event_type = 'Lock'
		                                      AND pid <> pg_backend_pid())`).Scan(&held)
	}
	if !held {
		t.Error("(b) the heal never waited on the held hour row: the row tests nothing")
	}
	imp(minute(h2b.Add(20*time.Minute), 4)) // about 5 s: its trigger times out on the instance's lock and records H2
	if err := holder.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-healed:
		if err != nil {
			t.Errorf("(b) the heal: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("(b) the heal did not end 30 s after the holder let go")
	}
	if d, want := dirty(), h1b.Format("02 15:04")+"-"+h2b.Add(time.Hour).Format("02 15:04"); d != want {
		t.Errorf("(b) after the heal: dirty range %s, want %s kept (a failure merged into it while the heal ran)", d, want)
	}
	if _, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_heal_one($1)`, id); err != nil {
		t.Fatal(err)
	}
	check("(b) H2 after the next heal", h2b)
	if d := dirty(); d != "none" {
		t.Errorf("(b) after the next heal: dirty range %s, want none", d)
	}

	// UTC hours under a +05:30 session (a date_trunc in the session's zone keys hours at :30)
	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `SET TimeZone = 'Asia/Kolkata'`); err != nil {
		t.Fatal(err)
	}
	pk, _ := json.Marshal([]map[string]any{minute(h0.Add(12*time.Hour+40*time.Minute), 4)})
	if _, err := conn.Exec(ctx, `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1 AND snapshot_at = $2`, id, h0.Add(12*time.Hour+40*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `SELECT pgvigil.import_mssql_azuredb_resources($1, now(), $2::jsonb)`, id, string(pk)); err != nil {
		t.Fatal(err)
	}
	var odd int
	_ = conn.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_azuredb_hour WHERE instance_id = $1 AND extract(minute FROM snapshot_at AT TIME ZONE 'UTC') <> 0`, id).Scan(&odd)
	conn.Release()
	if odd != 0 {
		t.Errorf("%d hour rows not on a UTC hour under Asia/Kolkata", odd)
	}
	check("an hour imported under +05:30", h0.Add(12*time.Hour))

	// 'pgvigil purge' makes this month's and the next month's hours partition (AzureDBHourMonths), never a trigger call
	// (the review's finding 5: a CREATE ... PARTITION OF takes ACCESS EXCLUSIVE on the parent)
	if err := (&Repo{pool: pool}).AzureDBHourMonths(ctx); err != nil {
		t.Fatal(err)
	}
	for _, m := range []time.Time{time.Now().UTC(), time.Now().UTC().AddDate(0, 1, 0)} {
		if s := str(`SELECT coalesce(to_regclass($1)::text, 'none')`, "pgvigil.mssql_azuredb_hour_"+m.Format("200601")); s == "none" {
			t.Errorf("after AzureDBHourMonths: no hours partition for %s", m.Format("2006-01"))
		}
	}
	if s := str(`SELECT (position('1 month' IN pg_get_functiondef('pgvigil.mssql_azuredb_hour_heal(int, int, boolean)'::regprocedure)) > 0)::text`); s != "false" {
		t.Error("mssql_azuredb_hour_heal (a trigger call's heal) still makes a month ahead")
	}

	// purge's hours: a month older than 730 days dropped (another such month of the store may go too), the rest kept
	old := time.Now().UTC().AddDate(-3, 0, 0)
	if _, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_partition($1)`, old); err != nil {
		t.Fatal(err)
	}
	// a child whose name ends in six digits that are no month (a table named after an OID past 100,000, N4-P10's
	// shape): purge reads no month from it and leaves it - never 22008 from parsing '_100017' as 1000-17
	oddPart := fmt.Sprintf("mssql_azuredb_hour_odd_%d", 100017)
	if _, err := pool.Exec(ctx, `CREATE TABLE pgvigil.`+oddPart+` PARTITION OF pgvigil.mssql_azuredb_hour FOR VALUES FROM ('2201-01-01 00:00+00') TO ('2201-02-01 00:00+00')`); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DROP TABLE IF EXISTS pgvigil.`+oddPart); err != nil {
			t.Error(err)
		}
	}()
	var dropped []string
	if err := pool.QueryRow(ctx, `SELECT pgvigil.mssql_azuredb_hour_purge()`).Scan(&dropped); err != nil {
		t.Fatalf("purge with a child named %s (six digits, no month): %v", oddPart, err)
	}
	if slices.Contains(dropped, oddPart) {
		t.Errorf("purge dropped %s: a name ending in no month", oddPart)
	}
	if !slices.Contains(dropped, "mssql_azuredb_hour_"+old.Format("200601")) {
		t.Errorf("purge dropped %v, want the month over 730 days old among them", dropped)
	}
	if slices.Contains(dropped, "mssql_azuredb_hour_"+h0.Format("200601")) {
		t.Errorf("purge dropped %v: this month's hours are under 730 days old", dropped)
	}
	check("an hour kept by purge", h0.Add(5*time.Hour))
}
