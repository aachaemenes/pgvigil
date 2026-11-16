package demo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Options shape a seed.
type Options struct {
	Prefix    string    // instance name prefix (default "demo-")
	Instances int       // fleet size (default 15: twelve PostgreSQL and three SQL Server; more = copies of the twelve, for a scale run)
	Days      int       // history length (default 7)
	Seed      uint64    // the random seed (same seed and anchor = same data)
	Workers   int       // instances imported in parallel (default 8)
	End       time.Time // the anchor, the last snapshot (default now, to the minute)
	Log       *slog.Logger
}

func (o *Options) defaults() {
	if o.Prefix == "" {
		o.Prefix = "demo-"
	}
	if o.Instances <= 0 {
		o.Instances = FleetSize
	}
	if o.Days <= 0 {
		o.Days = 7
	}
	if o.Workers <= 0 {
		o.Workers = 8
	}
	if o.End.IsZero() {
		o.End = time.Now().UTC().Truncate(time.Minute)
	}
	if o.Log == nil {
		o.Log = slog.New(slog.DiscardHandler)
	}
}

// Stats is what a seed or a tick wrote.
type Stats struct {
	Instances int
	Replaced  int
	Imports   int64
	Rows      int64
	// Retries counts the imports taken again after PostgreSQL ended them as a deadlock's victim (up to
	// repo.ImportDeadlockTries each): 0 when every partition was made ahead (0271).
	Retries int64
	Elapsed time.Duration
	// Anchor is the end of the seeded history: the catch-up ticks, one a minute, come after it.
	Anchor time.Time
}

// Fleet is a seeded fleet: its generators continue from where the seed stopped (Tick).
type Fleet struct {
	pool *pgxpool.Pool
	gens []*Gen
	ids  []int
	opts Options
	last time.Time
}

// IDs are the instance ids this fleet seeded, in its order (the demo's write door writes for these and no other).
func (f *Fleet) IDs() []int { return append([]int(nil), f.ids...) }

// Prefix is the name prefix this fleet was seeded with: the option's, or the default where the option was empty.
func (f *Fleet) Prefix() string { return f.opts.Prefix }

// Replace removes the instances tagged demo whose name starts with prefix, and every row of theirs:
// each table of the pgvigil schema with an instance_id column is cleared for them, then the
// instance rows. Instances without the tag or the prefix are never touched. Needs the owner login.
func Replace(ctx context.Context, pool *pgxpool.Pool, prefix string) (int, error) {
	var n int
	err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		var ids []int32
		if err := tx.QueryRow(ctx, `SELECT coalesce(array_agg(instance_id), '{}') FROM pgvigil.instances
		                             WHERE 'demo' = ANY (tags) AND starts_with(name, $1)`, prefix).Scan(&ids); err != nil {
			return fmt.Errorf("find demo instances: %w", err)
		}
		// the dbadash_* tables carry DBA Dash's InstanceID, not a pgvigil one: they are left out below (a delete by the
		// demo's pgvigil ids would hit a real door's rows that share a number); SeedDBADash replaces the demo's own
		// repository by name, in its own transaction, once the seed has gone through
		n = len(ids)
		if n == 0 {
			return nil
		}
		rows, err := tx.Query(ctx, `
SELECT c.relname FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'instance_id' AND NOT a.attisdropped
 WHERE ns.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition AND c.relname <> 'instances'
   AND c.relname NOT LIKE 'dbadash\_%'
 ORDER BY c.relname`)
		if err != nil {
			return err
		}
		tables, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		for _, t := range tables {
			if _, err := tx.Exec(ctx, fmt.Sprintf(`DELETE FROM pgvigil.%s WHERE instance_id = ANY ($1)`, pgx.Identifier{t}.Sanitize()), ids); err != nil {
				return fmt.Errorf("clear %s: %w", t, err)
			}
		}
		_, err = tx.Exec(ctx, `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, ids)
		return err
	})
	return n, err
}

// Seed replaces the demo instances and imports the history of a new fleet.
func Seed(ctx context.Context, pool *pgxpool.Pool, o Options) (*Fleet, Stats, error) {
	o.defaults()
	began := time.Now()
	var st Stats
	n, err := Replace(ctx, pool, o.Prefix)
	if err != nil {
		return nil, st, err
	}
	st.Replaced = n
	grid := Grid(o.End, o.Days)
	f := &Fleet{pool: pool, opts: o, last: o.End}
	specs := Specs(o.Prefix, o.Instances)
	names := make([]string, len(specs))
	for i, s := range specs {
		names[i] = s.Name
	}
	// ensure_instance rewrites the tags of an instance that has the name: a real instance that
	// happens to carry a demo name would be tagged demo and deleted with its history by the next run
	var taken []string
	if err := pool.QueryRow(ctx, `SELECT coalesce(array_agg(name ORDER BY name), '{}') FROM pgvigil.instances
	                               WHERE name = ANY ($1) AND NOT 'demo' = ANY (tags)`, names).Scan(&taken); err != nil {
		return nil, st, fmt.Errorf("check demo names: %w", err)
	}
	if len(taken) > 0 {
		return nil, st, fmt.Errorf("instance(s) %s exist without the demo tag: nothing seeded; pick another -prefix", strings.Join(taken, ", "))
	}
	// every partition the seed writes is made before its workers start, each make a statement of its own (0271, N4):
	// no import of the seed makes one inside its transaction, so two workers crossing a month side by side cannot
	// deadlock on its parent
	seedPartitions(ctx, pool, o, grid, specs)
	for i, s := range specs {
		var id int
		engine := "postgres"
		if s.Engine != "" {
			engine = s.Engine
		}
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, $3, $4, $5, $6, $7)`,
			s.Name, s.Platform, s.Version, s.VersionNum, s.Replica, s.Tags, engine).Scan(&id); err != nil {
			return nil, st, fmt.Errorf("ensure_instance %s: %w", s.Name, err)
		}
		f.gens = append(f.gens, NewGen(s, i, o.Seed, grid[0], o.End))
		f.ids = append(f.ids, id)
	}
	st.Instances = len(f.gens)
	done := atomic.Int64{}
	err = f.each(ctx, &st, func(ctx context.Context, i int, imp *importer) error {
		for _, t := range grid {
			if err := imp.steps(ctx, f.ids[i], f.gens[i].Step(t)); err != nil {
				return err
			}
		}
		// stamped when this instance's import finished, not at the anchor: a long seed must not
		// leave the overview's stale check firing until the first live tick
		if err := imp.logCollections(ctx, f.ids[i], f.gens[i], time.Now().UTC()); err != nil {
			return err
		}
		if k := done.Add(1); k%50 == 0 || int(k) == len(f.gens) {
			o.Log.Info("demo seed", "instances_done", k, "of", len(f.gens), "elapsed", time.Since(began).Round(time.Second).String())
		}
		return nil
	})
	if err == nil {
		// the DBADash door's recorded repository rides the same seed (dbadash_demo.go), after the fleet's history
		if e := SeedDBADash(ctx, pool, grid[0], o.End); e != nil {
			err = fmt.Errorf("dbadash demo: %w", e)
		}
	}
	if err == nil {
		if e := SeedAlerts(ctx, pool, grid[0], o.End); e != nil {
			err = fmt.Errorf("alerts demo: %w", e)
		}
	}
	if err == nil {
		// acknowledgements, a mute, a known-noise label and a silence (0073), over the alerts just seeded
		if e := SeedAcks(ctx, pool, o.Prefix); e != nil {
			err = fmt.Errorf("acks demo: %w", e)
		}
	}
	if err == nil {
		// alert rules on the demo fleet's metrics, judged once at the seed's end (alert_rules_demo.go, task 131)
		if e := SeedAlertRules(ctx, pool, o.Prefix, o.End); e != nil {
			err = fmt.Errorf("alert rules demo: %w", e)
		}
	}
	if err == nil {
		// made-up applications and their contacts at example.com on three demo instances (apps_demo.go, task 310)
		if e := SeedApplications(ctx, pool, o.Prefix); e != nil {
			err = fmt.Errorf("applications demo: %w", e)
		}
	}
	if err == nil {
		// a PgBouncer in front of one instance, derived from its activity (pooler_demo.go, task 128)
		if e := SeedPooler(ctx, pool, o.Prefix, grid[0].Add(-time.Minute), o.End); e != nil {
			err = fmt.Errorf("pooler demo: %w", e)
		}
	}
	if err == nil {
		err = f.catchUp(ctx, &st)
	}
	st.Elapsed = time.Since(began)
	st.Anchor = o.End
	return f, st, err
}

// mssqlStorageParents are the partitioned parents import_mssql_storage writes (0067): the SQL Server instances' year
// of storage reads before the grid (mssql_demo.go, a read a day) lands in their months.
var mssqlStorageParents = []string{"mssql_database_size", "mssql_volume_sample"}

// seedWindow is the range of the seed's partitions: the months from the grid's first minute's (a minute before it:
// SeedPooler's first read) to the month after the anchor's, the daily parent's days to two days after the anchor -
// the collector's window at the anchor (repo.AheadWindow), from the grid's start.
func seedWindow(grid []time.Time, end time.Time) (from, monthsTo, daysTo time.Time) {
	_, monthsTo, daysTo = repo.AheadWindow(end)
	return grid[0].UTC().Add(-time.Minute), monthsTo, daysTo
}

// seedPartitions makes the seed's partitions ahead (seedWindow; for a fleet with SQL Server instances also the storage
// year's months). A failure or a busy partition is a warning, as in a collector's pass: the imports still make a
// missing partition themselves.
func seedPartitions(ctx context.Context, pool *pgxpool.Pool, o Options, grid []time.Time, specs []Spec) {
	from, monthsTo, daysTo := seedWindow(grid, o.End)
	res, err := repo.PartitionsAhead(ctx, pool, from, monthsTo, daysTo)
	if yearAgo := o.End.UTC().Add(-365 * 24 * time.Hour); err == nil && hasEngine(specs, EngineSQLServer) && yearAgo.Before(from) {
		var h repo.AheadResult
		h, err = repo.PartitionsAheadOf(ctx, pool, mssqlStorageParents, yearAgo, from)
		res.Due, res.Made, res.Busy = res.Due+h.Due, res.Made+h.Made, res.Busy+h.Busy
	}
	if (err != nil && ctx.Err() == nil) || res.Busy > 0 {
		o.Log.Warn("demo seed: partitions ahead not all made (the imports make the rest)", "due", res.Due, "made", res.Made, "busy", res.Busy, "err", err)
		return
	}
	o.Log.Info("demo seed: partitions ahead", "due", res.Due, "made", res.Made)
}

// hasEngine says whether a fleet holds an instance of the engine ("" is PostgreSQL).
func hasEngine(specs []Spec, engine string) bool {
	for _, s := range specs {
		if s.Engine == engine {
			return true
		}
	}
	return false
}

// catchUpWindow is how far behind now a seed's anchor may be for the seed to tick up to now: the default anchor is
// the minute the seed began, a few minutes back by the time the history is in; an anchor set far in the past (a
// fixed one, for a comparison) is left where it is.
const catchUpWindow = 30 * time.Minute

// catchUp imports the snapshots of the minutes that passed while the history was imported, so the newest read of
// every instance is the current minute's when Seed returns: a rule that reads "the last minutes" (a blocking chain
// in the newest snapshot, a queue over its threshold in every read of the last five) is on the first page a served
// demo shows, not after its first live tick.
func (f *Fleet) catchUp(ctx context.Context, st *Stats) error {
	if time.Since(f.opts.End) > catchUpWindow {
		return nil
	}
	for t := f.last.Add(time.Minute); !t.After(time.Now().UTC().Truncate(time.Minute)); t = f.last.Add(time.Minute) {
		ts, err := f.Tick(ctx, t)
		if err != nil {
			return fmt.Errorf("catch-up tick %s: %w", t.Format(time.RFC3339), err)
		}
		st.Imports += ts.Imports
		st.Rows += ts.Rows
		st.Retries += ts.Retries
	}
	return nil
}

// Tick imports one more snapshot at t for every instance (the live trickle of 'demo -serve'),
// so the stale checks stay quiet and the latest snapshot is always a minute old at most.
func (f *Fleet) Tick(ctx context.Context, t time.Time) (Stats, error) {
	var st Stats
	t = t.UTC().Truncate(time.Minute)
	if !t.After(f.last) {
		return st, nil
	}
	began := time.Now()
	if !t.Truncate(time.Hour).Equal(f.last.UTC().Truncate(time.Hour)) {
		// a new hour: the partitions ahead of the trickle, as a collector's hourly pass makes them (sched)
		f.partitionsPass(ctx, t)
	}
	err := f.each(ctx, &st, func(ctx context.Context, i int, imp *importer) error {
		if err := imp.steps(ctx, f.ids[i], f.gens[i].Step(t)); err != nil {
			return err
		}
		return imp.logCollections(ctx, f.ids[i], f.gens[i], t)
	})
	if err == nil {
		err = SeedPooler(ctx, f.pool, f.opts.Prefix, f.last, t)
	}
	f.last = t
	st.Instances = len(f.gens)
	st.Elapsed = time.Since(began)
	return st, err
}

// partitionsPass makes the partitions due at t (repo.AheadWindow); a failure or a busy partition is a warning.
func (f *Fleet) partitionsPass(ctx context.Context, t time.Time) {
	from, monthsTo, daysTo := repo.AheadWindow(t)
	if res, err := repo.PartitionsAhead(ctx, f.pool, from, monthsTo, daysTo); (err != nil && ctx.Err() == nil) || res.Busy > 0 {
		f.opts.Log.Warn("demo tick: partitions ahead not all made", "due", res.Due, "made", res.Made, "busy", res.Busy, "err", err)
	}
}

// each runs fn for every instance on the worker pool; the first error stops the rest.
func (f *Fleet) each(ctx context.Context, st *Stats, fn func(context.Context, int, *importer) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	work := make(chan int)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var first error
	for w := 0; w < f.opts.Workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			imp := &importer{pool: f.pool}
			for i := range work {
				if err := fn(ctx, i, imp); err != nil {
					mu.Lock()
					if first == nil {
						first = fmt.Errorf("%s: %w", f.gens[i].Spec.Name, err)
						cancel()
					}
					mu.Unlock()
				}
			}
			atomic.AddInt64(&st.Imports, imp.imports)
			atomic.AddInt64(&st.Rows, imp.rows)
			atomic.AddInt64(&st.Retries, imp.retries)
		}()
	}
	for i := range f.gens {
		select {
		case work <- i:
		case <-ctx.Done():
		}
	}
	close(work)
	wg.Wait()
	if first == nil && ctx.Err() != nil && !errors.Is(ctx.Err(), context.Canceled) {
		first = ctx.Err()
	}
	return first
}

// importer hands batches to the import functions, one call per batch, each its own transaction
// (import_statements makes an ON COMMIT DROP temp table: two calls in one transaction collide).
type importer struct {
	pool    *pgxpool.Pool
	imports int64
	rows    int64
	retries int64 // imports taken again after a deadlock
}

func (m *importer) steps(ctx context.Context, id int, batches []Batch) error {
	for _, b := range batches {
		payload, err := json.Marshal(b.Rows)
		if err != nil {
			return fmt.Errorf("marshal %s: %w", b.Collection, err)
		}
		// the collection names are this package's own constants: a fixed set, never input
		q := `SELECT pgvigil.import_` + b.Collection + `($1, $2, $3::jsonb)`
		for attempt := 1; ; attempt++ {
			if attempt > 1 {
				m.retries++ // counted when the import is taken again, not when a cancel cuts the pause before it
			}
			_, err = m.pool.Exec(ctx, q, id, b.At, string(payload))
			// the seed's workers cross a month line side by side: a new month's partition and a shared query_text
			// row can deadlock two imports, and PostgreSQL rolls the victim back whole (repo.Import's rule)
			if err == nil || attempt == repo.ImportDeadlockTries || !repo.IsDeadlock(err) || ctx.Err() != nil {
				break
			}
			select {
			case <-ctx.Done():
			case <-time.After(time.Duration(attempt) * 150 * time.Millisecond):
			}
		}
		if err != nil {
			return fmt.Errorf("import_%s at %s: %w", b.Collection, b.At.Format(time.RFC3339), err)
		}
		m.imports++
		m.rows += int64(len(b.Rows))
	}
	return nil
}

// logCollections records each collection's last run as the collector would: ok, or the
// statements collection's error on the instance without pg_stat_statements.
func (m *importer) logCollections(ctx context.Context, id int, g *Gen, at time.Time) error {
	for _, c := range g.Collections() {
		status, note := "ok", ""
		if why := g.mssqlSkipNote(c); why != "" {
			status, note = "skipped", why
		}
		if c == "host" && !g.hostDoor() {
			status, note = "skipped", hostSkipNote
		}
		if (c == "vacuum" || c == "vacuum_tables") && g.Spec.Replica {
			status, note = "skipped", vacuumSkipNote
		}
		if c == "plans" && g.idx%2 == 1 {
			status, note = "skipped", plansSkipNote
		}
		if c == "serverlog" && g.Spec.Replica {
			status, note = "skipped", serverlogSkipNote
		}
		if c == "statements" && g.Spec.StmtBroken {
			status, note = "error", `statements on `+g.Spec.Name+`: ERROR: pg_stat_statements must be loaded via "shared_preload_libraries" (SQLSTATE 55000)`
		}
		if _, err := m.pool.Exec(ctx, `SELECT pgvigil.log_collection($1, $2, $3, $4, $5, $6)`,
			id, c, at, 40+int(noise(g.Spec.Name+c, at)*400), status, nullIf(note)); err != nil {
			return fmt.Errorf("log_collection %s: %w", c, err)
		}
	}
	return nil
}

func nullIf(s string) any {
	if s == "" {
		return nil
	}
	return s
}
