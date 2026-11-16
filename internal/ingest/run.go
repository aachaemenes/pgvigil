package ingest

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sync"
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

// Retry asks one bundle to be read again (0329's remote_retry, 'pgvigil ingest -retry'): its open marks (not its gaps)
// cleared and a retry recorded, so the next round reads it even past its stream's newest bundle (loaded after a gap);
// the batches already in stay in. The marks cleared; refused when the seq's marks name more than one stream.
func Retry(ctx context.Context, pool *pgxpool.Pool, site, collector, key string, seq uint64) (int64, error) {
	var n int64
	err := pool.QueryRow(ctx, `SELECT pgvigil.remote_retry($1, $2, $3, $4)`, site, collector, key, int64(seq)).Scan(&n)
	return n, err
}

// CheckIngestLogin refuses, in words, an ingest login that is the repository's owner, a superuser or a member of
// pgvigil_collector, or that is not a member of pgvigil_ingest (0329's ingest door is that role's alone).
func CheckIngestLogin(ctx context.Context, pool *pgxpool.Pool) error {
	var user string
	var owner, super, collector, ingest bool
	err := pool.QueryRow(ctx, `SELECT current_user,
	       coalesce((SELECT n.nspowner = r.oid FROM pg_namespace n WHERE n.nspname = 'pgvigil'), false),
	       r.rolsuper,
	       pg_has_role(current_user, 'pgvigil_collector', 'MEMBER'),
	       coalesce((SELECT pg_has_role(current_user, 'pgvigil_ingest', 'MEMBER') FROM pg_roles WHERE rolname = 'pgvigil_ingest'), false)
	  FROM pg_roles r WHERE r.rolname = current_user`).Scan(&user, &owner, &super, &collector, &ingest)
	if err != nil {
		return fmt.Errorf("ingest_dsn: its login could not be checked: %w", err)
	}
	switch {
	case owner:
		return fmt.Errorf("ingest_dsn: %s is the repository's owner - ingest runs on a login in pgvigil_ingest only, never the owner's", user)
	case super:
		return fmt.Errorf("ingest_dsn: %s is a superuser - ingest runs on a login in pgvigil_ingest only", user)
	case collector:
		return fmt.Errorf("ingest_dsn: %s is a member of pgvigil_collector - a collector login may not load a site's bundles; give ingest a login in pgvigil_ingest alone", user)
	case !ingest:
		return fmt.Errorf("ingest_dsn: %s is not a member of pgvigil_ingest ('pgvigil roles' makes a login in it)", user)
	}
	return nil
}

// minEvery is the Loop's floor: a round never comes sooner than a minute after the last
const minEvery = time.Minute

// Loop runs a round of every site every 'every' (a minute at least) until ctx ends - the run loop's ingest, wired by
// cmd/pgvigil's run on ingest's own pool. remote_sites: is synced into the repository at each round until it takes;
// each site runs on its own goroutine (the site's lock serialises one site; a site catching up never ages the others).
func Loop(ctx context.Context, pool *pgxpool.Pool, sites []Site, every time.Duration, log *slog.Logger) {
	if every < minEvery {
		every = minEvery
	}
	synced := false
	t := time.NewTimer(0)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if !synced {
			if err := (PoolHub{Pool: pool}).SyncSites(ctx, sites); err != nil {
				log.Error("remote_sites: not synced into the repository (again at the next round)", "err", err)
			} else {
				synced = true
			}
		}
		var wg sync.WaitGroup
		for _, s := range sites {
			wg.Add(1)
			go func(s Site) {
				defer wg.Done()
				res, held, err := SiteRound(ctx, pool, s, log)
				switch {
				case err != nil:
					log.Error("remote ingest", "site", s.Name, "err", err)
				case held:
					log.Info("remote ingest: another loop holds the site", "site", s.Name)
				}
				if res != (Result{}) {
					log.Info("remote ingest", "site", s.Name, "loaded", res.Loaded, "set_aside", res.SetAside, "still_set_aside", res.Kept, "late", res.Late,
						"conflicts", res.Conflicts, "gaps", res.Gaps, "waiting", res.Waiting)
				}
			}(s)
		}
		wg.Wait()
		t.Reset(every)
	}
}

// Line is one site's round in words.
func (r Result) Line(site string) string {
	return fmt.Sprintf("site %s: %d loaded, %d already in, %d set aside, %d still set aside, %d late, %d in conflict, %d gaps gone past, %d waiting",
		site, r.Loaded, r.Skipped, r.SetAside, r.Kept, r.Late, r.Conflicts, r.Gaps, r.Waiting)
}
