// Command pgvigil is the collector: it polls PostgreSQL instances on a schedule
// and writes what it finds into the pgvigil repository database.
//
//	pgvigil run      -config pgvigil.yaml            run every scheduled collection until stopped
//	pgvigil collect  -config pgvigil.yaml -once instance [-instance name]
//	pgvigil migrate  -config pgvigil.yaml            apply the repository schema
//	pgvigil serve    -config pgvigil.yaml [-listen 127.0.0.1:8080] [-tls-cert f -tls-key f]   web UI and JSON API (read only)
//	pgvigil user     <add|passwd|enable|disable|remove|list> -config pgvigil.yaml [name]        the UI's logins
//	pgvigil cert     [-hosts a,b] [-out dir]                                                 a self-signed TLS pair
//	pgvigil demo     [-config f | -pgbin dir] [-serve]                                        seed (and serve) the demo fleet
//	pgvigil roles                                                                            the CREATE ROLE script
//	pgvigil purge    -config pgvigil.yaml [-days 30] [-dry-run]                            the repository's retention, as its owner
//	pgvigil install   [-bin p] [-config p] [-user a] [-no-start]                             the collector as a service (systemd / Windows)
//	pgvigil uninstall [-bin p] [-config p] [-user a] [-purge]
//	pgvigil version
package main

import (
	"context"
	"errors"
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

func main() { os.Exit(run(os.Args[1:])) }

// run returns the process exit code: 0 ok, 1 a failure, 2 a usage error, 3 a configuration error.
// Deferred cleanup (the signal context) runs before os.Exit this way.
func run(args []string) int {
	if len(args) < 1 {
		usage()
		return 2
	}
	if handled, code := maybeRunAsService(args); handled { // Windows: `run` under the service control manager
		return code
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch args[0] {
	case "version":
		fmt.Println("pgvigil", version)
	case "migrate":
		err = runMigrate(ctx, log, args[1:])
	case "collect":
		err = runCollect(ctx, log, args[1:])
	case "run":
		err = runScheduler(ctx, log, args[1:])
	case "roles":
		err = runRoles(args[1:])
	case "serve":
		err = runServe(ctx, log, args[1:])
	case "user":
		err = runUser(ctx, log, args[1:])
	case "cert":
		err = runCert(args[1:])
	case "demo":
		err = runDemo(ctx, log, args[1:])
	case "purge":
		err = runPurge(ctx, log, args[1:])
	case "install":
		err = runInstall(log, args[1:])
	case "uninstall":
		err = runUninstall(log, args[1:])
	default:
		usage()
		return 2
	}
	if err != nil {
		log.Error("pgvigil failed", "err", err)
		var ec interface{ ExitCode() int }
		if errors.As(err, &ec) {
			return ec.ExitCode() // 3: a configuration error, which a service manager must not retry
		}
		return 1
	}
	return 0
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: pgvigil <run|collect|migrate|roles|serve|user|cert|demo|purge|install|uninstall|version> [-config file] [-once collection] [-instance name]")
}

// loadConfig reads the config for the repository commands; needInstance is the collector
// commands' rule (collect, run), not migrate's: a host that only serves the UI lists no instance
// and still migrates its repository.
func loadConfig(args []string, needInstance bool) (*config.Config, *flag.FlagSet, error) {
	fs := flag.NewFlagSet("pgvigil", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	once := fs.String("once", "", "collection to run once (collect only)")
	inst := fs.String("instance", "", "limit to one configured instance (collect only)")
	if err := fs.Parse(args); err != nil {
		return nil, nil, err
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return nil, nil, &configError{err}
	}
	if needInstance && len(cfg.Instances) == 0 {
		return nil, nil, &configError{fmt.Errorf("config %s: at least one instance is required", *path)}
	}
	if err := checkCollectionNames(cfg); err != nil {
		return nil, nil, &configError{fmt.Errorf("config %s: %w", *path, err)}
	}
	cfg.Flags.Once = *once
	cfg.Flags.Instance = *inst
	return cfg, fs, nil
}

func runMigrate(ctx context.Context, log *slog.Logger, args []string) error {
	cfg, _, err := loadConfig(args, false)
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
	cfg, _, err := loadConfig(args, true)
	if err != nil {
		return err
	}
	if cfg.Flags.Once == "" {
		return fmt.Errorf("collect needs -once <collection>; known: %v", collect.Names())
	}
	if _, ok := collect.Get(cfg.Flags.Once); !ok {
		return fmt.Errorf("unknown collection %q; known: %v", cfg.Flags.Once, collect.Names())
	}
	// everything that can be wrong in the arguments fails here, before any connection
	var targets []config.Instance
	for _, in := range cfg.Instances {
		if cfg.Flags.Instance == "" || in.Name == cfg.Flags.Instance {
			targets = append(targets, in)
		}
	}
	if len(targets) == 0 {
		return fmt.Errorf("no configured instance named %q", cfg.Flags.Instance)
	}
	r, err := repo.Open(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer r.Close()
	failed := 0
	for _, in := range targets {
		res := collect.RunOnce(ctx, log, r, in, cfg.Flags.Once)
		if res.Err != nil {
			failed++
			log.Error("collection failed", "instance", in.Name, "collection", cfg.Flags.Once, "err", res.Err)
			continue
		}
		fmt.Printf("%s %s: %d row(s) in %s%s\n", in.Name, cfg.Flags.Once, res.Rows, res.Duration, res.Note)
	}
	if failed > 0 {
		return fmt.Errorf("%d of %d instance(s) failed", failed, len(targets))
	}
	return nil
}

// checkCollectionNames rejects a schedules: or disabled: entry that names no
// collection; the config package cannot import collect, so the check lives here.
func checkCollectionNames(cfg *config.Config) error {
	known := map[string]bool{}
	for _, n := range collect.Names() {
		known[n] = true
	}
	for n := range cfg.Schedules {
		if !known[n] {
			return fmt.Errorf("schedules: unknown collection %q; known: %v", n, collect.Names())
		}
	}
	for _, in := range cfg.Instances {
		for n := range in.Schedules {
			if !known[n] {
				return fmt.Errorf("instance %q schedules: unknown collection %q; known: %v", in.Name, n, collect.Names())
			}
		}
		for _, n := range in.Disabled {
			if !known[n] {
				return fmt.Errorf("instance %q disabled: unknown collection %q; known: %v", in.Name, n, collect.Names())
			}
		}
	}
	return nil
}

func runScheduler(ctx context.Context, log *slog.Logger, args []string) error {
	cfg, _, err := loadConfig(args, true)
	if err != nil {
		return err
	}
	r, err := repo.Open(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer r.Close()
	ok, latest, err := r.SchemaCurrent(ctx)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("repository schema is behind this binary (needs %s): run 'pgvigil migrate' as the repository owner", latest)
	}
	return sched.Run(ctx, log, r, cfg)
}
