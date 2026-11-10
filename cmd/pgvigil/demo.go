package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/demo"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// runDemo seeds a repository with the synthetic demo fleet, and with -serve serves it:
//
//	pgvigil demo -config pgvigil.yaml [-dsn env:NAME] [-seed 1] [-instances 12] [-days 7]
//	pgvigil demo -serve [-listen 127.0.0.1:8080] [-open] (-config f | -pgbin <dir> [-pgdata <dir>])
//
// The repository login must own the schema (demo migrates it and replaces the instances tagged
// demo). -pgbin names a portable PostgreSQL (the EDB zip's pgsql\bin, a tarball's bin): demo runs
// initdb into -pgdata, starts it on a free loopback port, uses it as the repository and stops it
// on exit, so a laptop with no admin right and no Docker can run the walk-through. -serve keeps the
// fleet live (one snapshot a minute) and serves on loopback without the UI login.
func runDemo(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("demo", flag.ContinueOnError)
	path := fs.String("config", "", "configuration file naming the repository (not needed with -pgbin)")
	dsn := fs.String("dsn", "", "repository connection string as the owner (or env:NAME / file:path); default the config's")
	pgbin := fs.String("pgbin", "", "portable PostgreSQL bin folder: run a throwaway repository from it")
	pgdata := fs.String("pgdata", "pgvigil-demo-data", "data folder for -pgbin (made on the first run, reused after)")
	serve := fs.Bool("serve", false, "after seeding, serve the UI on loopback without a login and keep the fleet live")
	listen := fs.String("listen", "127.0.0.1:8080", "address to serve on (-serve; loopback only)")
	open := fs.Bool("open", false, "with -serve: open the UI in an app-mode browser window (Edge or Chrome, its own window); the default browser when neither is found")
	seed := fs.Uint64("seed", 1, "random seed: the same seed gives the same fleet")
	n := fs.Int("instances", demo.FleetSize, "instances to seed: twelve PostgreSQL and three SQL Server (more repeats the twelve, for a scale run)")
	days := fs.Int("days", 7, "days of history")
	workers := fs.Int("workers", 8, "instances imported in parallel")
	prefix := fs.String("prefix", "demo-", "instance name prefix; a re-run replaces the demo instances with this prefix")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("demo: unexpected argument %q", fs.Arg(0))
	}
	if *n < 1 || *n > 100000 || *days < 1 || *days > 60 || *workers < 1 || *workers > 64 {
		return errors.New("demo: -instances 1..100000, -days 1..60, -workers 1..64")
	}
	host, _, err := net.SplitHostPort(*listen)
	if err != nil {
		return fmt.Errorf("-listen: %w", err)
	}
	if *serve && host != "127.0.0.1" && host != "localhost" && host != "::1" {
		return errors.New("demo -serve runs without a login and listens on loopback only (127.0.0.1, localhost, ::1)")
	}
	if *open && !*serve {
		return errors.New("demo: -open needs -serve (there is no page to open without it)")
	}

	repoDSN := ""
	switch {
	case *pgbin != "":
		if *path != "" || *dsn != "" {
			return errors.New("demo: -pgbin makes its own repository; leave out -config and -dsn")
		}
		c, err := demo.StartCluster(ctx, log, *pgbin, *pgdata)
		if err != nil {
			return err
		}
		defer c.Stop()
		repoDSN = c.DSN
	case *dsn != "":
		repoDSN = config.Resolve(*dsn)
	case *path != "":
		cfg, err := config.Load(*path)
		if err != nil {
			return err
		}
		repoDSN = cfg.Repository.DSN()
	default:
		return errors.New("demo: name the repository with -config (or -dsn), or run one with -pgbin")
	}

	r, err := repo.Open(ctx, repoDSN)
	if err != nil {
		return err
	}
	applied, err := r.Migrate(ctx)
	r.Close()
	if err != nil {
		return err
	}
	log.Info("demo: repository schema is current", "applied", applied)

	pcfg, err := pgxpool.ParseConfig(repoDSN)
	if err != nil {
		return fmt.Errorf("repository dsn: %w", err)
	}
	pcfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-demo"
	pcfg.MaxConns = int32(*workers + 1)
	pool, err := pgxpool.NewWithConfig(ctx, pcfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	fleet, st, err := demo.Seed(ctx, pool, demo.Options{Prefix: *prefix, Instances: *n, Days: *days, Seed: *seed, Workers: *workers, Log: log})
	if err != nil {
		return err
	}
	fmt.Printf("demo: %d instance(s) seeded (%d replaced), %d import call(s), %d row(s) in %s\n",
		st.Instances, st.Replaced, st.Imports, st.Rows, st.Elapsed.Round(time.Millisecond))
	if !*serve {
		return nil
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	// the accepted Host values come from the bound port (-listen 127.0.0.1:0 picks one)
	port := strconv.Itoa(ln.Addr().(*net.TCPAddr).Port)
	srv, err := web.Open(ctx, log, repoDSN, web.Options{Expected: expectedIntervals(&config.Config{}), Hosts: web.LoopbackHosts(port),
		Tags: web.TagsUI{GroupBy: []string{"env"}, EnvOrder: config.DefaultEnvOrder}})
	if err != nil {
		_ = ln.Close()
		return err
	}
	defer srv.Close()
	hs := &http.Server{Handler: srv.Handler(), ReadHeaderTimeout: 10 * time.Second, WriteTimeout: 75 * time.Second}
	errc := make(chan error, 1)
	go func() { errc <- hs.Serve(ln) }()
	log.Info("pgvigil demo serving", "url", fmt.Sprintf("http://%s/", ln.Addr()), "login", false)
	if *open {
		openWindow(log, browseURL("http", ln.Addr()))
	}

	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			return hs.Shutdown(sctx)
		case err := <-errc:
			if errors.Is(err, http.ErrServerClosed) {
				return nil
			}
			return err
		case now := <-tick.C:
			if _, err := fleet.Tick(ctx, now); err != nil && ctx.Err() == nil {
				log.Warn("demo: live snapshot failed", "err", err)
			}
		}
	}
}
