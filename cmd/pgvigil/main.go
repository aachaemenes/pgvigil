// Command pgvigil is the collector: it polls PostgreSQL instances on a schedule
// and writes what it finds into the pgvigil repository database.
//
//	pgvigil run      -config pgvigil.yaml            run every scheduled collection until stopped
//	pgvigil collect  -config pgvigil.yaml -once instance [-instance name]
//	pgvigil migrate  -config pgvigil.yaml            apply the repository schema
//	pgvigil alerts   -config pgvigil.yaml            one pass of the alert channels (the alerts: list)
//	pgvigil serve    -config pgvigil.yaml [-listen 127.0.0.1:8080] [-tls-cert f -tls-key f]   web UI and JSON API (read only)
//	pgvigil user     <add|passwd|enable|disable|remove|list> -config pgvigil.yaml [name]        the UI's logins
//	pgvigil cert     [-hosts a,b] [-out dir]                                                 a self-signed TLS pair
//	pgvigil demo     [-config f | -pgbin dir] [-serve]                                        seed (and serve) the demo fleet
//	pgvigil roles                                                                            the CREATE ROLE script
//	pgvigil purge    -config pgvigil.yaml [-days 30] [-dry-run]                            the repository's retention, as its owner
//	pgvigil tag      -config pgvigil.yaml [-reset] <instance> [key=value[,value...]] [-key] [key]   fix an instance's tags in the repository
//	pgvigil report   [-config pgvigil.yaml] [-out file.zip] [-dsn env:NAME] [-names] [-errors N]   a local zip of masked diagnostics for a problem report (nothing is sent)
//	pgvigil install   [-bin p] [-config p] [-user a] [-no-start]                             the collector as a service (systemd / Windows)
//	pgvigil uninstall [-bin p] [-config p] [-user a] [-purge]
//	pgvigil mcp       [-dsn env:PGVIGIL_MCP_DSN] [-config pgvigil.yaml]                   read-only MCP tools on stdio (reader login)
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
	"strings"
	"syscall"

	"github.com/aachaemenes/pgvigil/internal/alerts"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/dbadash"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/aachaemenes/pgvigil/internal/reportmail"
	"github.com/aachaemenes/pgvigil/internal/sched"
	"github.com/jackc/pgx/v5/pgconn"
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
		fmt.Println(versionLine())
	case "migrate":
		err = runMigrate(ctx, log, args[1:])
	case "collect":
		err = runCollect(ctx, log, args[1:])
	case "run":
		err = runScheduler(ctx, log, args[1:])
	case "alerts":
		err = runAlerts(ctx, log, args[1:])
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
	case "tag":
		err = runTag(ctx, args[1:])
	case "report":
		err = runReport(ctx, args[1:])
	case "install":
		err = runInstall(log, args[1:])
	case "uninstall":
		err = runUninstall(log, args[1:])
	case "mcp":
		err = runMCP(ctx, log, args[1:])
	case "mssql-xe":
		err = runMSSQLXE(args[1:])
	case "import":
		err = dbadash.ImportCommand(ctx, log, os.Stdout, args[1:])
	default:
		usage()
		return 2
	}
	if err != nil {
		// a deadlock's or a serialization failure's DETAIL names the two sides, which the message does not; no other
		// error's detail is logged (a constraint violation's carries the failing row, and rows hold statement text)
		var pg *pgconn.PgError
		if errors.As(err, &pg) && (pg.Code == "40P01" || pg.Code == "40001") {
			log.Error("pgvigil failed", "err", err, "detail", pg.Detail, "where", pg.Where)
		} else {
			log.Error("pgvigil failed", "err", err)
		}
		var ec interface{ ExitCode() int }
		if errors.As(err, &ec) {
			return ec.ExitCode() // 3: a configuration error, which a service manager must not retry
		}
		return 1
	}
	return 0
}

// runMSSQLXE prints the Extended Events session script of the SQL Server engine for the server's DBA (-print), or
// the script that drops those sessions (-print -drop). pgvigil never runs either.
func runMSSQLXE(args []string) error {
	fs := flag.NewFlagSet("pgvigil mssql-xe", flag.ContinueOnError)
	doPrint := fs.Bool("print", false, "print the script that creates and starts the sessions")
	drop := fs.Bool("drop", false, "with -print: the script that drops the sessions instead")
	id := fs.String("install-id", "main", "the install id in the session names (pgvigil_<install id>_<capture>): 1 to 20 lower-case letters and digits")
	form := fs.String("form", mssql.XEFormServer, "server (SQL Server, Amazon RDS), azuresqlmi or azuresqldb")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !*doPrint {
		return errors.New("mssql-xe: -print is the only action; pgvigil prints the script and the server's DBA runs it")
	}
	script, err := mssql.XEScript(*id, *form)
	if *drop {
		script, err = mssql.XEDropScript(*id, *form)
	}
	if err != nil {
		return err
	}
	fmt.Print(script)
	return nil
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: pgvigil <run|collect|alerts|migrate|roles|serve|user|cert|demo|purge|tag|report|install|uninstall|mcp|mssql-xe|import|version> [-config file] [-once collection] [-instance name]")
	fmt.Fprintln(os.Stderr, "       "+dbadash.ImportUsage)
}

// loadConfig reads the config for the repository commands; needInstance is collect -once's rule: run takes
// a file with no instance (Admin > Instances may hold them all), and a host that only serves the UI lists none
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
	// mssql_thresholds: the names and values are the SQL Server engine's (config cannot import it), a sqlserver instance's only
	for _, in := range cfg.Instances {
		if len(in.MSSQLThresholds) == 0 {
			continue
		}
		if in.Engine != config.EngineSQLServer {
			return nil, nil, &configError{fmt.Errorf("config %s: instance %q: mssql_thresholds belongs to an engine: sqlserver instance", *path, in.Name)}
		}
		if _, err := mssql.ThresholdRows(in.MSSQLThresholds); err != nil {
			return nil, nil, &configError{fmt.Errorf("config %s: instance %q: mssql_thresholds: %w", *path, in.Name, err)}
		}
	}
	// the custom: list (task 61): read from the same file, validated against the instances, the list the custom collection runs
	if err := collect.LoadCustomChecks(*path, cfg.Instances); err != nil {
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
		return fmt.Errorf("collect needs -once <collection>; known: %v", engines.Names())
	}
	if _, ok := engines.EngineOf(cfg.Flags.Once); !ok {
		return fmt.Errorf("unknown collection %q; known: %v", cfg.Flags.Once, engines.Names())
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
		res := engines.RunOnce(ctx, log, r, in, cfg.Flags.Once)
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
	for n := range cfg.Schedules {
		if _, ok := engines.EngineOf(n); !ok {
			return fmt.Errorf("schedules: unknown collection %q; known: %v", n, engines.Names())
		}
	}
	for _, in := range cfg.Instances {
		// an instance names only its own engine's collections
		check := func(where, n string) error {
			e, ok := engines.EngineOf(n)
			if !ok {
				return fmt.Errorf("instance %q %s: unknown collection %q; known: %v", in.Name, where, n, engines.Names())
			}
			if e != in.Engine {
				return fmt.Errorf("instance %q %s: %q is a %s collection and the instance's engine is %s", in.Name, where, n, e, in.Engine)
			}
			return nil
		}
		for n := range in.Schedules {
			if err := check("schedules", n); err != nil {
				return err
			}
		}
		for _, n := range in.Disabled {
			if err := check("disabled", n); err != nil {
				return err
			}
		}
	}
	return nil
}

func runScheduler(ctx context.Context, log *slog.Logger, args []string) error {
	// no instance in the file is fine: Admin > Instances may hold them all (task 204)
	cfg, fs, err := loadConfig(args, false)
	if err != nil {
		return err
	}
	for _, w := range collect.CustomWarnings() {
		log.Warn(w)
	}
	// an empty repository dsn (a fresh install's env file not filled yet) is a config error: exit 3, which the unit's
	// RestartPreventExitStatus=3 and the Windows service's recovery leave stopped - never a restart loop
	if strings.TrimSpace(cfg.Repository.DSN()) == "" {
		return &configError{fmt.Errorf("config %s: the repository dsn (%s) resolves to nothing: fill in the env file or the file it names",
			fs.Lookup("config").Value.String(), cfg.Repository.DSNRaw)}
	}
	// the alerts: list (task 60): the sender runs beside the scheduler as alerts_dsn (a login IN ROLE pgvigil_alerter), else the repository's dsn
	ast, err := alerts.LoadFile(fs.Lookup("config").Value.String())
	if err != nil {
		return &configError{err}
	}
	alertsDSN := ast.DSN()
	if alertsDSN == "" {
		alertsDSN = cfg.Repository.DSN()
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
	go func() {
		if err := dbadash.Run(ctx, log, cfg.Repository.DSN(), cfg.DBADash); err != nil {
			log.Warn("dbadash door stopped", "err", err)
		}
	}()
	go func() {
		if err := alerts.Run(ctx, log, alertsDSN, ast.Channels); err != nil {
			log.Warn("alert loop stopped", "err", err)
		}
	}()
	// task 171: the report mails queued by serve, mailed through the smtp channels on the sender's login
	go func() {
		if err := reportmail.Run(ctx, log, alertsDSN, ast.Channels); err != nil {
			log.Warn("report mail loop stopped", "err", err)
		}
	}()
	return sched.Run(ctx, log, r, cfg)
}
