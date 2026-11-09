// Command pgvigil is the collector: it polls PostgreSQL instances on a schedule
// and writes what it finds into the pgvigil repository database.
//
//	pgvigil run      -config pgvigil.yaml            run every scheduled collection until stopped
//	pgvigil collect  -config pgvigil.yaml -once instance [-instance name]
//	pgvigil migrate  -config pgvigil.yaml            apply the repository schema
//	pgvigil version
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/aachaemenes/pgvigil/internal/sched"
)

// version is set by the build (-ldflags "-X main.version=...").
var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch os.Args[1] {
	case "version":
		fmt.Println("pgvigil", version)
	case "migrate":
		err = runMigrate(ctx, log, os.Args[2:])
	case "collect":
		err = runCollect(ctx, log, os.Args[2:])
	case "run":
		err = runScheduler(ctx, log, os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		log.Error("pgvigil failed", "err", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: pgvigil <run|collect|migrate|version> [-config file] [-once collection] [-instance name]")
}

func loadConfig(args []string) (*config.Config, *flag.FlagSet, error) {
	fs := flag.NewFlagSet("pgvigil", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	once := fs.String("once", "", "collection to run once (collect only)")
	inst := fs.String("instance", "", "limit to one configured instance (collect only)")
	if err := fs.Parse(args); err != nil {
		return nil, nil, err
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return nil, nil, err
	}
	cfg.Flags.Once = *once
	cfg.Flags.Instance = *inst
	return cfg, fs, nil
}

func runMigrate(ctx context.Context, log *slog.Logger, args []string) error {
	cfg, _, err := loadConfig(args)
	if err != nil {
		return err
	}
	r, err := repo.Open(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer r.Close()
	n, err := r.Migrate(ctx)
	if err != nil {
		return err
	}
	log.Info("repository schema is current", "applied", n)
	return nil
}

func runCollect(ctx context.Context, log *slog.Logger, args []string) error {
	cfg, _, err := loadConfig(args)
	if err != nil {
		return err
	}
	if cfg.Flags.Once == "" {
		return fmt.Errorf("collect needs -once <collection>; known: %v", collect.Names())
	}
	if _, ok := collect.Get(cfg.Flags.Once); !ok {
		return fmt.Errorf("unknown collection %q; known: %v", cfg.Flags.Once, collect.Names())
	}
	r, err := repo.Open(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer r.Close()
	failed, matched := 0, 0
	for _, in := range cfg.Instances {
		if cfg.Flags.Instance != "" && in.Name != cfg.Flags.Instance {
			continue
		}
		matched++
		res := collect.RunOnce(ctx, log, r, in, cfg.Flags.Once)
		if res.Err != nil {
			failed++
			log.Error("collection failed", "instance", in.Name, "collection", cfg.Flags.Once, "err", res.Err)
			continue
		}
		fmt.Printf("%s %s: %d row(s) in %s%s\n", in.Name, cfg.Flags.Once, res.Rows, res.Duration, res.Note)
	}
	if matched == 0 {
		return fmt.Errorf("no configured instance named %q", cfg.Flags.Instance)
	}
	if failed > 0 {
		return fmt.Errorf("%d of %d instance(s) failed", failed, matched)
	}
	return nil
}

func runScheduler(ctx context.Context, log *slog.Logger, args []string) error {
	cfg, _, err := loadConfig(args)
	if err != nil {
		return err
	}
	r, err := repo.Open(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return sched.Run(ctx, log, r, cfg)
}
