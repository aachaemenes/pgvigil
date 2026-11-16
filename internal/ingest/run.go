package ingest

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// MaxRaw is a view file's uncompressed cap on the hub (a bigger file is set aside 'too_big').
const MaxRaw = 512 << 20

// SiteRound runs one round of one site under the site's own lock (a session advisory lock on its own connection:
// one loop per site at a time, across every hub process on the repository); held = another loop has it now.
func SiteRound(ctx context.Context, pool *pgxpool.Pool, s Site, log *slog.Logger) (res Result, held bool, err error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return res, false, err
	}
	defer conn.Release()
	var got bool
	if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtext('pgvigil remote ingest'), hashtext($1))`, s.Name).Scan(&got); err != nil {
		return res, false, err
	}
	if !got {
		return res, true, nil
	}
	defer func() {
		_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(hashtext('pgvigil remote ingest'), hashtext($1))`, s.Name)
	}()
	work, err := os.MkdirTemp("", "pgvigil-ingest-")
	if err != nil {
		return res, false, err
	}
	defer func() { _ = os.RemoveAll(work) }()
	in := &Ingester{Site: s, Hub: PoolHub{Pool: pool}, Allow: AllowList(), Now: time.Now, MaxRaw: MaxRaw, Work: work, Log: log}
	res, err = in.Round(ctx)
	return res, false, err
}

// Retry clears the marks of one bundle (its folder in the drop: <site>/<collector>/<instance-key>/<day>/<seq>-<end>)
// so the next round reads it again; the batches already in stay in (the ledger), so only the rest loads.
func Retry(ctx context.Context, pool *pgxpool.Pool, site, collector, key string, seq uint64) (int64, error) {
	tag, err := pool.Exec(ctx, `UPDATE pgvigil.remote_marks SET cleared_at = now(), cleared_by = 'pgvigil ingest -retry'
	   WHERE site = $1 AND collector = $2 AND instance_key = $3 AND seq = $4 AND cleared_at IS NULL AND kind NOT IN ('gap', 'audit gap')`,
		site, collector, key, int64(seq))
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

// Loop runs a round of every site every 'every' until ctx ends (the run loop's ingest: wired by cmd/pgvigil's run).
func Loop(ctx context.Context, pool *pgxpool.Pool, sites []Site, every time.Duration, log *slog.Logger) {
	if err := (PoolHub{Pool: pool}).SyncSites(ctx, sites); err != nil {
		log.Error("remote_sites: not synced into the repository", "err", err)
	}
	t := time.NewTimer(0)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		for _, s := range sites {
			res, held, err := SiteRound(ctx, pool, s, log)
			switch {
			case err != nil:
				log.Error("remote ingest", "site", s.Name, "err", err)
			case held:
				log.Info("remote ingest: another loop holds the site", "site", s.Name)
			case res != (Result{}):
				log.Info("remote ingest", "site", s.Name, "loaded", res.Loaded, "set_aside", res.SetAside, "late", res.Late,
					"conflicts", res.Conflicts, "gaps", res.Gaps, "waiting", res.Waiting)
			}
		}
		t.Reset(every)
	}
}

// Line is one site's round in words.
func (r Result) Line(site string) string {
	return fmt.Sprintf("site %s: %d loaded, %d already in, %d set aside, %d late, %d in conflict, %d gaps gone past, %d waiting",
		site, r.Loaded, r.Skipped, r.SetAside, r.Late, r.Conflicts, r.Gaps, r.Waiting)
}
