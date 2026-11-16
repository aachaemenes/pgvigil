package repo

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Partitions made ahead (migration 0271, N4). An import that first meets a month without a partition makes it inside
// its own transaction and holds ACCESS EXCLUSIVE on the parent until it commits; a second import that already wrote a
// shared row (query_text) then waits on the parent while the first waits on that row - a deadlock. So the partitions
// are made before their imports need them, each by pgvigil.import_partition_make in a transaction of its own (one
// parent locked at a time, never inside an import): by Migrate, by the collector's scheduler at its start and every
// hour, by `pgvigil collect`, and by the demo seed for its whole range. The makers inside the imports stay for old or
// late data; an import the server picks as a deadlock's victim is taken again by Import (up to ImportDeadlockTries).

// AheadResult counts one pass: the partitions found missing, made, and left for the next pass because a lock was not
// had within the make's own short lock_timeout. Made counts the makes this pass ran: two passes at once may both count
// a partition the other made a moment before (the counts are for the log).
type AheadResult struct {
	Due, Made, Busy int
}

// AheadWindow is the collector's window at t: the months from t's to the next one, the days of the daily parent from
// t's to two days on.
func AheadWindow(t time.Time) (from, monthsTo, daysTo time.Time) {
	t = t.UTC()
	return t, time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC).AddDate(0, 1, 0), t.Add(48 * time.Hour)
}

// PartitionsAhead makes every partition missing in the window: the months from from's to monthsTo's, the days (of the
// daily parent) from from's to daysTo's. Each make is its own statement outside any transaction of the caller. Every
// due partition is tried; the first error is returned with the counts.
func PartitionsAhead(ctx context.Context, pool *pgxpool.Pool, from, monthsTo, daysTo time.Time) (AheadResult, error) {
	return partitionsAhead(ctx, pool, nil, from, monthsTo, daysTo)
}

// PartitionsAheadOf is PartitionsAhead for the named parents only.
func PartitionsAheadOf(ctx context.Context, pool *pgxpool.Pool, parents []string, from, monthsTo time.Time) (AheadResult, error) {
	only := make(map[string]bool, len(parents))
	for _, p := range parents {
		only[p] = true
	}
	return partitionsAhead(ctx, pool, only, from, monthsTo, monthsTo)
}

func partitionsAhead(ctx context.Context, pool *pgxpool.Pool, only map[string]bool, from, monthsTo, daysTo time.Time) (AheadResult, error) {
	var res AheadResult
	type due struct {
		parent string
		starts time.Time
	}
	to := monthsTo // the series' end: the later of the two, so the last day of a month still reaches daysTo
	if daysTo.After(to) {
		to = daysTo
	}
	rows, err := pool.Query(ctx, `SELECT parent, unit, starts FROM pgvigil.import_partitions_due($1, $2)`, from, to)
	if err != nil {
		return res, fmt.Errorf("partitions due: %w", err)
	}
	var list []due
	dayEnd := time.Date(daysTo.UTC().Year(), daysTo.UTC().Month(), daysTo.UTC().Day(), 0, 0, 0, 0, time.UTC)
	for rows.Next() {
		var d due
		var unit string
		if err := rows.Scan(&d.parent, &unit, &d.starts); err != nil {
			rows.Close()
			return res, fmt.Errorf("partitions due: %w", err)
		}
		if (unit == "day" && d.starts.After(dayEnd)) || (only != nil && !only[d.parent]) {
			continue
		}
		list = append(list, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return res, fmt.Errorf("partitions due: %w", err)
	}
	res.Due = len(list)
	var first error
	for _, d := range list {
		var ans string
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_partition_make($1, $2)`, d.parent, d.starts).Scan(&ans); err != nil {
			if first == nil {
				first = fmt.Errorf("partition of %s at %s: %w", d.parent, d.starts.UTC().Format("2006-01-02"), err)
			}
			if ctx.Err() != nil {
				break
			}
			continue
		}
		switch ans {
		case "made":
			res.Made++
		case "busy":
			res.Busy++
		}
	}
	return res, first
}

// PartitionsAhead is the collector's pass on this repository at now (AheadWindow).
func (r *Repo) PartitionsAhead(ctx context.Context, now time.Time) (AheadResult, error) {
	from, monthsTo, daysTo := AheadWindow(now)
	return PartitionsAhead(ctx, r.pool, from, monthsTo, daysTo)
}

// aheadAfterMigrate is Migrate's pass, after its files are committed and its connection is back in the pool: a failure
// or a busy partition is said, never Migrate's error (the schema is current; the collector's next pass makes the rest).
func (r *Repo) aheadAfterMigrate(ctx context.Context) {
	res, err := r.PartitionsAhead(ctx, time.Now())
	if err != nil || res.Busy > 0 {
		r.logger().Warn("partitions ahead: not all made; the collector's next pass makes the rest",
			"due", res.Due, "made", res.Made, "busy", res.Busy, "err", err)
	}
}
