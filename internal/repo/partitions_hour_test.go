package repo

import (
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestPartitionsAheadHourTables: the hour tables ranged on snapshot_at are made ahead by their own makers - 0151's
// hour_partition_0151 (cloud_replica_hour, mssql_georepl_hour) and 0167's mssql_azuredb_hour_partition - each month
// with fillfactor 80 and no index beside its primary key, never by 0002's ensure_month_partition: its (instance_id,
// snapshot_at) index fails on cloud_replica_hour, which has no instance_id (42703: the pass made 206 of 208, every
// month), and adds a second index without the fillfactor to the other two. With next month's partitions of the three
// dropped, one pass over them makes all three, each in its own maker's shape.
func TestPartitionsAheadHourTables(t *testing.T) {
	ctx, r, _, _ := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	from, monthsTo, _ := AheadWindow(time.Now())
	next := monthsTo.Format("200601")
	hours := []string{"cloud_replica_hour", "mssql_georepl_hour", "mssql_azuredb_hour"}
	for _, p := range hours {
		if _, err := r.pool.Exec(ctx, `DROP TABLE IF EXISTS `+pgx.Identifier{"pgvigil", p + "_" + next}.Sanitize()); err != nil {
			t.Fatal(err)
		}
	}
	res, err := PartitionsAheadOf(ctx, r.pool, hours, from, monthsTo)
	if err != nil {
		t.Fatalf("the hour tables' pass: %v (due %d, made %d, busy %d)", err, res.Due, res.Made, res.Busy)
	}
	for _, p := range hours {
		name := p + "_" + next
		var opts []string
		var others int
		var found bool
		err := r.pool.QueryRow(ctx, `SELECT true, coalesce(c.reloptions, '{}'),
		       (SELECT count(*) FROM pg_index i WHERE i.indrelid = c.oid AND NOT i.indisprimary)::int
		  FROM pg_class c WHERE c.oid = to_regclass('pgvigil.' || quote_ident($1))`, name).Scan(&found, &opts, &others)
		if err == pgx.ErrNoRows {
			t.Errorf("%s: not made by the pass", name)
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if !slices.Contains(opts, "fillfactor=80") {
			t.Errorf("%s: options %v, want fillfactor=80 (its own maker's)", name, opts)
		}
		if others != 0 {
			t.Errorf("%s: %d index(es) beside its primary key, want none (ensure_month_partition's (instance_id, snapshot_at) index is not its maker's)", name, others)
		}
	}
}
