package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/ingest"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// runIngest is `pgvigil ingest`: one round of every site of remote_sites: (-once, the default and only mode), or one
// bundle read again (-retry <site>/<collector>/<instance-key>/<day>/<seq>-<end>, its folder in the drop: its marks
// cleared and a retry recorded, then its site's round - the batches already in stay in, so only the rest loads). It runs
// on its own pool on ingest_dsn: (a login in pgvigil_ingest, checked first). `pgvigil run` on a hub runs the same rounds
// in its loop.
func runIngest(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("pgvigil ingest", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	once := fs.Bool("once", true, "one round of every site, then exit (the only mode: the loop is pgvigil run's)")
	retry := fs.String("retry", "", "a bundle's folder in its drop, relative to the drop (<site>/<collector>/<instance-key>/<day>/<seq>-<end>): read it again")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	if fs.NArg() > 0 {
		return &usageError{fmt.Errorf("ingest: unexpected argument %q", fs.Arg(0))}
	}
	if !*once {
		return &usageError{errors.New("ingest: -once=false: pgvigil ingest runs one round and exits; the loop is pgvigil run's on a hub")}
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return &configError{err}
	}
	if len(cfg.RemoteSites) == 0 {
		return &configError{errors.New("ingest: the configuration has no remote_sites: (docs/remote-collector.md)")}
	}
	var ref format.Ref
	if *retry != "" {
		dir := strings.Trim(strings.TrimSpace(*retry), "/")
		if ref, err = format.ParseDir(dir); err != nil {
			return &usageError{fmt.Errorf("ingest -retry %s: %w (the folder is relative to the drop: <site>/<collector>/<instance-key>/<day>/<seq>-<end>)", *retry, err)}
		}
		var site *config.RemoteSite
		for i := range cfg.RemoteSites {
			if cfg.RemoteSites[i].Name == ref.Site {
				site = &cfg.RemoteSites[i]
			}
		}
		if site == nil {
			return &usageError{fmt.Errorf("ingest -retry: site %s is not in remote_sites: - nothing cleared", ref.Site)}
		}
		listed := false
		for _, c := range site.Collectors {
			listed = listed || c.Name == ref.Collector
		}
		if !listed {
			return &usageError{fmt.Errorf("ingest -retry: collector %s is not one site %s lists in remote_sites: - nothing cleared", ref.Collector, ref.Site)}
		}
	}
	if strings.TrimSpace(cfg.IngestDSN()) == "" {
		return &configError{errors.New("ingest: no ingest_dsn: - ingest runs on its own login, a member of pgvigil_ingest ('pgvigil roles' makes one), never the collector's or the owner's; remote_sites: is not read without it")}
	}
	sites, err := ingest.Sites(ctx, cfg.RemoteSites, ingest.OpenDrop)
	if err != nil {
		return &configError{err}
	}
	pool, err := pgxpool.New(ctx, cfg.IngestDSN())
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := ingest.CheckIngestLogin(ctx, pool); err != nil {
		return &configError{err}
	}
	if *retry != "" {
		n, err := ingest.Retry(ctx, pool, ref.Site, ref.Collector, ref.InstanceKey, ref.Seq)
		if err != nil {
			return err
		}
		fmt.Printf("ingest -retry %s: %d mark(s) cleared; reading the site again\n", ref.Dir(), n)
	}
	if err := (ingest.PoolHub{Pool: pool}).SyncSites(ctx, sites); err != nil {
		return err
	}
	failed := false
	for _, s := range sites {
		if *retry != "" && s.Name != ref.Site {
			continue
		}
		res, held, err := ingest.SiteRound(ctx, pool, s, log)
		switch {
		case err != nil:
			failed = true
			fmt.Printf("site %s: %v\n", s.Name, err)
		case held && *retry != "":
			fmt.Printf("site %s: a pgvigil run on this repository holds it now: its loop reads the bundle at its next round\n", s.Name)
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
