// Command pgvigil is the collector: it polls PostgreSQL instances on a schedule
// and writes what it finds into the pgvigil repository database.
//
//	pgvigil run      -config pgvigil.yaml            run every scheduled collection until stopped
//	pgvigil collect  -config pgvigil.yaml -once instance [-instance name]
//	pgvigil migrate  -config pgvigil.yaml            apply the repository schema
//	pgvigil migrate  -config pgvigil.yaml -print     print the statements migrate would run (read only: nothing applied)
//	pgvigil alerts   -config pgvigil.yaml            one pass of the alert channels (the alerts: list)
//	pgvigil check    -config pgvigil.yaml [-json] [-instance name]...   the install's read-only health check (its own exit codes: docs/check.md)
//	pgvigil serve    -config pgvigil.yaml [-listen 127.0.0.1:8080] [-tls-cert f -tls-key f]   web UI and JSON API (read only)
//	pgvigil user     <add|passwd|enable|disable|remove|list> -config pgvigil.yaml [name]        the UI's logins
//	pgvigil cert     [-hosts a,b] [-out dir]                                                 a self-signed TLS pair
//	pgvigil demo     [-config f | -pgbin dir] [-serve]                                        seed (and serve) the demo fleet
//	pgvigil roles                                                                            the CREATE ROLE script
//	pgvigil purge    -config pgvigil.yaml [-days 30] [-dry-run]                            the repository's retention, as its owner
//	pgvigil tag      -config pgvigil.yaml [-reset] <instance> [key=value[,value...]] [-key] [key]   fix an instance's tags in the repository
//	pgvigil report   [-config pgvigil.yaml] [-out file.zip] [-dsn env:NAME] [-names] [-errors N]   a local zip of masked diagnostics for a problem report (nothing is sent)
//	pgvigil install   [-bin p] [-config p] [-user a] [-no-start]                             the collector as a service (systemd / Windows)
//	pgvigil install   -upgrade [-owner-dsn-file p | -owner-dsn-env NAME] [-dump f [-pg-dump p] | -no-dump]   the installed collector upgraded: stop, dump, migrate, swap, start (docs/upgrade.md)
//	pgvigil uninstall [-bin p] [-config p] [-user a] [-purge]
//	pgvigil uninstall -all [-bin p] [-config p] [-user a] [-dry-run] [-drop-repository [-confirm-database <name>] [-owner-dsn-file <path> | -owner-dsn-env <NAME>] [-dump <file> [-pg-dump <path>] | -no-dump]]
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
	"time"

	"github.com/aachaemenes/pgvigil/internal/alerts"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/cq"
	"github.com/aachaemenes/pgvigil/internal/dbadash"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/aachaemenes/pgvigil/internal/reportmail"
	"github.com/aachaemenes/pgvigil/internal/sched"
	"github.com/aachaemenes/pgvigil/internal/secrets"
	"github.com/jackc/pgx/v5/pgconn"
)

// version is set by the build (-ldflags "-X main.version=...").
var version = "dev"

func main() { os.Exit(run(os.Args[1:])) }

// run returns the process exit code: 0 ok, 1 a failure, 2 a usage error, 3 a configuration error - except 'pgvigil
// check', whose error carries its own (1 the configuration, 2 the repository, 3 any WARN or FAIL while the repository
// answers: docs/check.md).
// Deferred cleanup (the signal context) runs before os.Exit this way.
func run(args []string) int {
	if len(args) < 1 {
		usage()
		return 2
	}
	if handled, code := maybeRunAsService(args); handled { // Windows: `run` under the service control manager
		return code
	}
	bad := applyLogLevel("")
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: logLevel}))
	// the process's default logger too: a package that logs through slog's default (the repository before SetLog, a
	// library) and loadFile's override line follow the level
	slog.SetDefault(log)
	warnBadLevel(log, bad)
	secrets.Default.SetLog(log) // a password secret's read and a stale value served are logged
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch args[0] {
	case "version":
		fmt.Println(versionLine())
	case "migrate":
		err = runMigrate(ctx, log, args[1:])
	case "check":
		err = runCheck(ctx, log, args[1:])
	case "secret":
		err = runSecret(args[1:])
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
	case "export":
		err = runExport(ctx, log, args[1:])
	case "tag":
		err = runTag(ctx, args[1:])
	case "report":
		err = runReport(ctx, args[1:])
	case "config":
		err = runConfig(args[1:])
	case "instance":
		err = runInstance(ctx, args[1:])
	case "install":
		err = runInstall(log, args[1:])
	case "uninstall":
		err = runUninstall(log, args[1:])
	case "mcp":
		err = runMCP(ctx, log, args[1:])
	case "mssql-xe":
		err = runMSSQLXE(args[1:])
	case "mssql-agent-alerts":
		err = runMSSQLAgentAlerts(args[1:])
	case "import":
		dbadash.LoadConfig = loadFile // the file's log_level applied as every command's load does
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
	form := fs.String("form", mssql.XEFormServer, "server (SQL Server), rds (Amazon RDS for SQL Server), azuresqlmi, azuresqldb or cloudsql (Google Cloud SQL)")
	captures := fs.String("captures", "", "the optional captures instead of the four sessions (task 411): waits,warnings,warncounts,modules or all")
	text := fs.String("text", "", "with -captures, required: the instance's query_text - full, normalized or none (none leaves the statement text action out)")
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
	if *captures != "" {
		var list []string
		if *captures != "all" {
			list = strings.Split(*captures, ",")
		}
		switch {
		case *drop:
			script, err = mssql.XECapturesDropScript(*id, *form, list)
		case *text == "":
			return errors.New("-captures needs -text full, normalized or none: the instance's query_text (the XE captures tab prints the script with the instance's own policy and settings)")
		default:
			// the CLI reads no repository: the script carries the defaults and says so in its header
			set := mssql.DefaultXECaptureSettings()
			set.Origin = mssql.XECaptureDefaultsOrigin
			script, err = mssql.XECapturesScript(*id, *form, *text, list, set)
		}
	}
	if err != nil {
		return err
	}
	fmt.Print(script)
	return nil
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: pgvigil <run|collect|alerts|migrate|check|secret|roles|serve|user|cert|demo|purge|export|tag|report|config|instance|install|uninstall|mcp|mssql-xe|mssql-agent-alerts|import|version> [-config file] [-once collection] [-instance name]")
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
	cfg, err := loadConfigAt(*path, needInstance)
	if err != nil {
		return nil, nil, err
	}
	cfg.Flags.Once = *once
	cfg.Flags.Instance = *inst
	return cfg, fs, nil
}

// loadConfigAt reads and checks the configuration file at path (loadConfig's checks, for a command with its own flags).
func loadConfigAt(path string, needInstance bool) (*config.Config, error) {
	cfg, err := loadFile(path)
	if err != nil {
		return nil, &configError{err}
	}
	mssqlopen.RequireGMSA(cfg.GMSA) // a Windows sign-in only as the gMSA gmsa: names (task 206)
	if needInstance && len(cfg.Instances) == 0 {
		return nil, &configError{fmt.Errorf("config %s: at least one instance is required", path)}
	}
	if err := checkCollectionNames(cfg); err != nil {
		return nil, &configError{fmt.Errorf("config %s: %w", path, err)}
	}
	// mssql_thresholds: the names and values are the SQL Server engine's (config cannot import it), a sqlserver instance's only
	for _, in := range cfg.Instances {
		if len(in.MSSQLThresholds) == 0 {
			continue
		}
		if in.Engine != config.EngineSQLServer {
			return nil, &configError{fmt.Errorf("config %s: instance %q: mssql_thresholds belongs to an engine: sqlserver instance", path, in.Name)}
		}
		if _, err := mssql.ThresholdRows(in.MSSQLThresholds); err != nil {
			return nil, &configError{fmt.Errorf("config %s: instance %q: mssql_thresholds: %w", path, in.Name, err)}
		}
	}
	// the custom: list (task 61): read from the same file, validated against the instances, the list the custom collection runs
	if err := collect.LoadCustomChecks(path, cfg.Instances); err != nil {
		return nil, &configError{fmt.Errorf("config %s: %w", path, err)}
	}
	return cfg, nil
}

// runMigrate applies the repository schema, or with -print (ST7, a change-controlled site) writes to stdout the
// statements it would run on this repository and applies nothing (the repository is only read).
func runMigrate(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("pgvigil migrate", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	doPrint := fs.Bool("print", false, "print the statements migrate would run on the repository to stdout; nothing is applied")
	fs.String("once", "", "not used by migrate (accepted as before)")
	fs.String("instance", "", "not used by migrate (accepted as before)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := loadConfigAt(*path, false)
	if err != nil {
		return err
	}
	repoDSN, err := repoDSNOf(*path, cfg)
	if err != nil {
		return err
	}
	r, err := repo.Open(ctx, repoDSN)
	if err != nil {
		return err
	}
	defer r.Close()
	if *doPrint {
		if err := r.MigrateScript(ctx, os.Stdout, versionLine()); err != nil {
			return err
		}
		log.Info("migrate -print: the script is on stdout; nothing was applied")
		return nil
	}
	r.SetLog(log)
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
	warnInlinePasswords(log, cfg) // L9
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
	repoDSN, err := repoDSNOf("", cfg)
	if err != nil {
		return err
	}
	r, err := repo.Open(ctx, repoDSN)
	if err != nil {
		return err
	}
	defer r.Close()
	// partitions ahead (0271, N4), as the scheduler does at its start: this run's imports make no partition in the
	// normal path
	if res, err := r.PartitionsAhead(ctx, time.Now()); err != nil {
		log.Warn("partitions ahead: not all made", "due", res.Due, "made", res.Made, "busy", res.Busy, "err", err)
	}
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
			// the page's Settings judge a name with the same check (engines.CheckPageSettings)
			if err := engines.CheckCollection(in.Engine, n); err != nil {
				if _, ok := engines.EngineOf(n); !ok {
					return fmt.Errorf("instance %q %s: %v; known: %v", in.Name, where, err, engines.Names())
				}
				return fmt.Errorf("instance %q %s: %v", in.Name, where, err)
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
	warnInlinePasswords(log, cfg) // L9: an inline PostgreSQL password still loads, with a warning naming the fix
	for _, w := range collect.CustomWarnings() {
		log.Warn(w)
	}
	logSecretEndpoints(ctx, log, cfg)
	// an empty repository dsn (a fresh install's env file not filled yet) is a config error: exit 3, which the unit's
	// RestartPreventExitStatus=3 and the Windows service's recovery leave stopped - never a restart loop
	if strings.TrimSpace(cfg.Repository.DSN()) == "" {
		return emptyRepoDSN(fs.Lookup("config").Value.String(), cfg.Repository.DSNRaw)
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
	r.SetLog(log) // the repository's own lines (an import ended by a deadlock) on the process's logger and level
	ok, latest, err := r.SchemaCurrent(ctx)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("repository schema is behind this binary (needs %s): run 'pgvigil migrate' as the repository owner", latest)
	}
	// task 201: the heartbeat (the Collector page; many collectors may share a repository, one per host)
	waitBeat, err := collect.StartHeartbeat(ctx, log, cfg.Repository.DSN(), collect.HeartbeatInfo{Version: version, SendsAlerts: len(ast.Channels) > 0, Probe: cfg.Probe, ProbeEveryMinute: cfg.ProbeEveryMinute})
	if err != nil {
		return err
	}
	defer waitBeat() // the last minute and the stop mark are written before the process ends
	// L9 (0455): the instances whose dsn carries an inline password become a finding on each - the names only
	if err := collect.NoteInlinePasswords(ctx, cfg.InlinePasswordInstances()); err != nil {
		log.Warn("the inline-password finding was not written", "err", err)
	}
	go func() {
		if err := dbadash.Run(ctx, log, cfg.Repository.DSN(), cfg.DBADash); err != nil {
			log.Error("dbadash door stopped", "err", err)
		}
	}()
	// TEXT-NOW: the alert sends follow each instance's query_text policy as the file states it now
	alerts.SetTextPolicy(alerts.PolicyOfConfig(cfg.QueryText, queryTextByName(cfg)))
	go func() {
		if err := alerts.Run(ctx, log, alertsDSN, ast.Channels); err != nil {
			log.Error("alert loop stopped", "err", err)
		}
	}()
	// task 171: the report mails queued by serve, mailed through the smtp channels on the sender's login
	go func() {
		if err := reportmail.Run(ctx, log, alertsDSN, ast.Channels); err != nil {
			log.Error("report mail loop stopped", "err", err)
		}
	}()
	// task CQ: the request worker (cq.enabled; off = it returns at once): the actions and community runs serve wrote into
	// the repository for the instances this collector holds; its stop (each run ended, the lease ended) is waited for
	cqDone := make(chan struct{})
	go func() {
		defer close(cqDone)
		if err := cq.Run(ctx, log, cfg, r); err != nil {
			log.Error("request queue stopped", "err", err)
		}
	}()
	defer func() {
		select {
		case <-cqDone:
		case <-time.After(cq.StopBudget): // its own stop's bound: each run ended, then the lease
			log.Warn("request queue: its stop did not finish in time", "waited", cq.StopBudget)
		}
	}()
	return sched.Run(ctx, log, r, cfg)
}

// logSecretEndpoints prints, at start, the endpoint each password_secret is read from as the SDK's chain resolved it
// (a configured AWS_ENDPOINT_URL_SECRETS_MANAGER, a profile's use_fips_endpoint, the China partition): the host a
// locked-down site opens (task B24e)
func logSecretEndpoints(ctx context.Context, log *slog.Logger, cfg *config.Config) {
	for _, in := range cfg.Instances {
		ref := in.SecretRef()
		if ref == nil {
			continue
		}
		ep, err := secrets.Default.Endpoint(ctx, *ref)
		if err != nil {
			log.Warn("password_secret: the endpoint could not be resolved", "instance", in.Name, "secret", ref.ID, "err", err)
			continue
		}
		log.Info("password_secret", "instance", in.Name, "secret", ref.ID, "region", ref.Region, "endpoint", ep)
	}
}

// queryTextByName is the file's instances' query_text policies, by name (TEXT-NOW: the alert sends follow them).
func queryTextByName(cfg *config.Config) map[string]string {
	m := map[string]string{}
	for _, in := range cfg.Instances {
		m[in.Name] = in.QueryText
	}
	return m
}

// emptyWhy is " - <why>" for a dsn reference that resolves to nothing (RELNOTES L145: the variable, the file, a dpapi:
// blob sealed on another host, a value of white space), "" when there is no reason to add. The reference is judged as
// it was resolved: trimmed (config's DSN methods trim it too).
func emptyWhy(raw string) string {
	if w := config.WhyEmpty(strings.TrimSpace(raw)); w != "" {
		return " - " + w
	}
	return ""
}

// emptyRepoDSN is the refusal of a repository dsn that resolves to nothing: its reason when there is one, else the
// fresh install's fix (the env file or the file it names); path "" leaves the configuration's name out.
func emptyRepoDSN(path, raw string) error {
	head := "the repository dsn"
	if path != "" {
		head = "config " + path + ": the repository dsn"
	}
	if why := emptyWhy(raw); why != "" {
		return &configError{fmt.Errorf("%s (%s) resolves to nothing%s", head, raw, why)}
	}
	return &configError{fmt.Errorf("%s (%s) resolves to nothing: fill in the env file or the file it names", head, raw)}
}

// repoDSNOf is the configuration's repository dsn, or emptyRepoDSN's refusal: every command that opens the repository
// refuses one that resolves to nothing in run's words (exit 3), never repo.Open's.
func repoDSNOf(path string, cfg *config.Config) (string, error) {
	d := cfg.Repository.DSN()
	if strings.TrimSpace(d) == "" {
		return "", emptyRepoDSN(path, cfg.Repository.DSNRaw)
	}
	return d, nil
}

// logLevel is the level every logger of this process reads (RELNOTES L172): info until the environment's
// PGVIGIL_LOG_LEVEL or the configuration's log_level says otherwise.
var logLevel = new(slog.LevelVar)

// loadFile reads the configuration file at path and applies its log_level (PGVIGIL_LOG_LEVEL wins): every command
// that reads pgvigil.yaml reads it here, so the level holds for serve, mcp, purge and the rest as for run
// (TestEveryConfigLoadAppliesTheLevel keeps it so). When the variable is set and differs from the file's
// log_level, one Warn line names both: on a service the variable outlives restarts and upgrades.
func loadFile(path string) (*config.Config, error) {
	cfg, err := config.Load(path)
	if err != nil {
		return nil, err
	}
	applyLogLevel(cfg.LogLevel)
	if env := strings.TrimSpace(os.Getenv("PGVIGIL_LOG_LEVEL")); env != "" && cfg.LogLevel != "" {
		ev, envErr := config.ParseLogLevel(env)
		fv, fileErr := config.ParseLogLevel(cfg.LogLevel)
		if envErr == nil && fileErr == nil && ev != fv {
			slog.Warn("PGVIGIL_LOG_LEVEL overrides the configuration's log_level", "PGVIGIL_LOG_LEVEL", env, "log_level", cfg.LogLevel, "config", path)
		}
	}
	return cfg, nil
}

// warnBadLevel writes the one line for a PGVIGIL_LOG_LEVEL that is no level word (applyLogLevel's bad): the console
// and the Windows service write the same line.
func warnBadLevel(log *slog.Logger, bad string) {
	if bad != "" {
		log.Warn("PGVIGIL_LOG_LEVEL is not a log level (debug, info, warn or error): ignored", "value", bad)
	}
}

// applyLogLevel sets logLevel from PGVIGIL_LOG_LEVEL, which wins, else from file (the configuration's log_level, ""
// at start); it returns the variable's value when that is no level word (it is then ignored).
func applyLogLevel(file string) (bad string) {
	if env := strings.TrimSpace(os.Getenv("PGVIGIL_LOG_LEVEL")); env != "" {
		if lv, err := config.ParseLogLevel(env); err == nil {
			logLevel.Set(lv)
			return ""
		}
		bad = env
	}
	if lv, err := config.ParseLogLevel(file); err == nil && file != "" {
		logLevel.Set(lv)
	}
	return bad
}
