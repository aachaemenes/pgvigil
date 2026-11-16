package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/ingest"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// runIngest is `pgvigil ingest`: one round of every site of remote_sites: (-once, the default), or one bundle read
// again (-retry <site>/<collector>/<instance-key>/<day>/<seq>-<end>: its marks cleared, then its site's round - the
// batches already in stay in, so only the rest loads). `pgvigil run` on a hub runs the same rounds in its loop.
func runIngest(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("pgvigil ingest", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	_ = fs.Bool("once", true, "one round of every site, then exit (the default)")
	retry := fs.String("retry", "", "a bundle's folder in its drop (<site>/<collector>/<instance-key>/<day>/<seq>-<end>): read it again")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	if fs.NArg() > 0 {
		return &usageError{fmt.Errorf("ingest: unexpected argument %q", fs.Arg(0))}
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return &configError{err}
	}
	if len(cfg.RemoteSites) == 0 {
		return &configError{errors.New("ingest: the configuration has no remote_sites: (docs/remote-collector.md)")}
	}
	var only string
	if *retry != "" {
		ref, err := format.ParseDir(*retry)
		if err != nil {
			return &usageError{fmt.Errorf("ingest -retry: %w", err)}
		}
		only = ref.Site
		pool, err := pgxpool.New(ctx, cfg.Repository.DSN())
		if err != nil {
			return err
		}
		n, err := ingest.Retry(ctx, pool, ref.Site, ref.Collector, ref.InstanceKey, ref.Seq)
		pool.Close()
		if err != nil {
			return err
		}
		fmt.Printf("ingest -retry %s: %d mark(s) cleared; reading the site again\n", *retry, n)
	}
	sites, err := ingest.Sites(ctx, cfg.RemoteSites, ingest.OpenDrop)
	if err != nil {
		return &configError{err}
	}
	pool, err := pgxpool.New(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := (ingest.PoolHub{Pool: pool}).SyncSites(ctx, sites); err != nil {
		return err
	}
	failed := false
	for _, s := range sites {
		if only != "" && s.Name != only {
			continue
		}
		res, held, err := ingest.SiteRound(ctx, pool, s, log)
		switch {
		case err != nil:
			failed = true
			fmt.Printf("site %s: %v\n", s.Name, err)
		case held:
			fmt.Printf("site %s: another loop holds it now (a pgvigil run on this repository): nothing read\n", s.Name)
		default:
			fmt.Println(res.Line(s.Name))
		}
	}
	if failed {
		return errors.New("ingest: a site's round failed (above)")
	}
	return nil
}
