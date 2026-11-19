package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/microsoft/go-mssqldb/msdsn"
	"golang.org/x/term"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// 'pgvigil instance add | list | disable' (RELNOTES L170, PerformanceMonitor 3.5.0's --add-server; the lead's 04:43):
// Admin > Instances from the command line, run on serve's host. add takes the page's own path - the connection test
// first, the credential sealed for the service's account, the page's repository function with the configuration's
// repository login - and the audit names 'cli:<the OS account>'.

func runInstance(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return &usageError{errors.New("instance takes add, list or disable: 'pgvigil instance add -h'")}
	}
	switch args[0] {
	case "add":
		return runInstanceAdd(ctx, args[1:], os.Stdin)
	case "list":
		return runInstanceList(ctx, args[1:])
	case "disable":
		return runInstanceDisable(ctx, args[1:])
	}
	return &usageError{fmt.Errorf("instance %s: add, list or disable", args[0])}
}

// serviceAccountForSecrets is the installed service's account, which owns the page's credentials ("" = no service).
func serviceAccountForSecrets() string {
	if runtime.GOOS == "windows" {
		acct, _ := installedAccount()
		return acct
	}
	return unitAccount()
}

// osAccount names the account running the command, for the audit.
func osAccount() string {
	if u, err := user.Current(); err == nil && u.Username != "" {
		return u.Username
	}
	return "unknown"
}

// dsnHolds says whether a connection string names a key, in its keyword or its URL form.
func dsnHolds(dsn, key string) bool {
	if u, err := url.Parse(dsn); err == nil && u.Scheme != "" {
		switch key {
		case "host":
			return u.Hostname() != ""
		case "user":
			return u.User != nil && u.User.Username() != ""
		}
	}
	for _, f := range strings.Fields(dsn) {
		if k, _, ok := strings.Cut(f, "="); ok && strings.EqualFold(strings.TrimSpace(k), key) {
			return true
		}
	}
	return false
}

// connFromDSN reads a connection string back into the page's fields, so the page's BuildDSN and its checks apply.
func connFromDSN(engine, dsn string) (config.Conn, error) {
	switch engine {
	case config.EnginePostgres:
		if !dsnHolds(dsn, "host") || !dsnHolds(dsn, "user") {
			return config.Conn{}, errors.New("the dsn names no host or no user: give both (a page instance never takes the defaults of the shell running this)")
		}
		pc, err := pgconn.ParseConfig(dsn)
		if err != nil {
			return config.Conn{}, errors.New("the dsn does not read as a PostgreSQL connection string")
		}
		c := config.Conn{Engine: engine, Auth: "pgpass", Host: pc.Host, Port: int(pc.Port), DBName: pc.Database, Login: pc.User, Password: pc.Password}
		if c.Password != "" {
			c.Auth = "password"
		}
		if m := sslmodeOf(dsn); m != "" {
			c.Extra = "sslmode=" + m
		}
		return c, nil
	case config.EngineSQLServer:
		cfg, err := msdsn.Parse(dsn)
		if err != nil {
			return config.Conn{}, errors.New("the dsn does not read as a SQL Server connection string")
		}
		host := cfg.Host
		if cfg.Instance != "" {
			host += `\` + cfg.Instance
		}
		c := config.Conn{Engine: engine, Host: host, Port: int(cfg.Port), DBName: cfg.Database, Login: cfg.User, Password: cfg.Password}
		fa := strings.TrimSpace(cfg.Parameters["fedauth"])
		switch {
		case strings.EqualFold(fa, "ActiveDirectoryServicePrincipal") || strings.EqualFold(fa, "ActiveDirectoryApplication"):
			c.Auth = "entra"
		case strings.EqualFold(fa, "ActiveDirectoryManagedIdentity") || strings.EqualFold(fa, "ActiveDirectoryMSI"):
			c.Auth = "entra-identity"
		case fa != "":
			return config.Conn{}, fmt.Errorf("fedauth %s is not a sign-in the page takes (sql, windows, entra, entra-identity): name it in pgvigil.yaml instead", fa)
		case c.Login != "" || c.Password != "":
			c.Auth = "sql"
		default:
			c.Auth = "windows"
		}
		q := url.Values{}
		for k, v := range cfg.Parameters {
			switch strings.ToLower(k) {
			case "user id", "password", "server", "port", "database", "fedauth", "dial timeout", "connection timeout", "protocol":
				continue
			}
			if dsnParamGiven(dsn, k) {
				q.Set(k, v)
			}
		}
		c.Extra = q.Encode()
		return c, nil
	}
	return config.Conn{}, fmt.Errorf("engine %q: postgres or sqlserver", engine)
}

// dsnParamGiven says whether a SQL Server URL names a query parameter itself (msdsn adds its defaults).
func dsnParamGiven(dsn, key string) bool {
	u, err := url.Parse(dsn)
	if err != nil {
		return false
	}
	for k := range u.Query() {
		if strings.EqualFold(k, key) {
			return true
		}
	}
	return false
}

// sslmodeOf reads a PostgreSQL connection string's sslmode, in its keyword or URL form ("" = none named).
func sslmodeOf(dsn string) string {
	if u, err := url.Parse(dsn); err == nil && u.Scheme != "" {
		return u.Query().Get("sslmode")
	}
	for _, f := range strings.Fields(dsn) {
		if k, v, ok := strings.Cut(f, "="); ok && strings.EqualFold(k, "sslmode") {
			return strings.Trim(v, "'")
		}
	}
	return ""
}

// addPayload is the page's import_admin_instance payload for an add (q_instances_admin.go's): the fields, the
// credential's reference, never the password.
func addPayload(name, platform string, tags []string, c config.Conn, ref, account string, fileNames []string) map[string]any {
	if fileNames == nil {
		fileNames = []string{}
	}
	if tags == nil {
		tags = []string{}
	}
	port := ""
	if c.Port > 0 {
		port = strconv.Itoa(c.Port)
	}
	return map[string]any{"op": "add", "ui_user": "cli:" + account, "client": "cli", "name": name, "file_names": fileNames,
		"engine": c.Engine, "platform": platform, "auth": c.Auth, "host": c.Host, "port": port, "dbname": c.DBName,
		"login": c.Login, "options": c.Extra, "tags": tags, "dsn_ref": ref}
}

// instanceWrite calls the page's own repository function; anything but 'done' is its refusal, in its words.
func instanceWrite(ctx context.Context, pool *pgxpool.Pool, pay map[string]any) error {
	b, err := json.Marshal(pay)
	if err != nil {
		return err
	}
	var out []byte
	wctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := pool.QueryRow(wctx, `SELECT pgvigil.import_admin_instance($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		return err
	}
	var a struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
	}
	if err := json.Unmarshal(out, &a); err != nil {
		return fmt.Errorf("import_admin_instance answered %q", out)
	}
	if a.Outcome != "done" {
		return fmt.Errorf("%s: %s", a.Outcome, a.Detail)
	}
	return nil
}

func fileNamesOf(cfg *config.Config) []string {
	out := []string{}
	for _, in := range cfg.Instances {
		out = append(out, in.Name)
	}
	return out
}

// readDSN reads the dsn from stdin: one line, not shown at a terminal.
func readDSN(in io.Reader) (string, error) {
	if f, ok := in.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		fmt.Fprint(os.Stderr, "the instance's connection string (not shown): ")
		b, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", err
		}
		in = strings.NewReader(string(b))
	}
	s, err := readServicePassword(in)
	if err != nil {
		return "", errors.New("-dsn-stdin: no connection string on stdin (one line)")
	}
	return s, nil
}

func runInstanceAdd(ctx context.Context, args []string, stdin io.Reader) error {
	fs := flag.NewFlagSet("pgvigil instance add", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "the configuration serve runs with (the credential goes beside it)")
	name := fs.String("name", "", "the instance's name (required)")
	engine := fs.String("engine", "", "postgres or sqlserver (required)")
	dsnStdin := fs.Bool("dsn-stdin", false, "the connection string, read from stdin (required; never a flag)")
	platform := fs.String("platform", "auto", "the platform, as the page's: auto, onprem, rds, aurora, azure, cloudsql, alloydb, azuresqldb, azuresqlmi")
	var tags stringsFlag
	fs.Var(&tags, "tag", "a tag (repeatable)")
	noTest := fs.Bool("no-test", false, "write without the page's connection test first")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	if *name == "" || *engine == "" || !*dsnStdin || fs.NArg() > 0 {
		return &usageError{errors.New("instance add takes -name, -engine and -dsn-stdin: pgvigil instance add [-config f] -name n -engine postgres|sqlserver -dsn-stdin [-platform p] [-tag t]... [-no-test]")}
	}
	account := serviceAccountForSecrets()
	if account == "" {
		return errors.New("no installed pgvigil service on this host: the page's credentials belong to the service's account, so add runs on serve's host after 'pgvigil install'")
	}
	cfg, err := loadConfigAt(*path, false)
	if err != nil {
		return err
	}
	dsn, err := readDSN(stdin)
	if err != nil {
		return err
	}
	c, err := connFromDSN(*engine, dsn)
	if err != nil {
		return err
	}
	built, err := config.BuildDSN(c)
	if err != nil {
		return err
	}
	if !*noTest {
		in := config.Instance{Name: *name, Engine: *engine, DSNRaw: built, Platform: *platform}
		t := web.CheckConnection(ctx, *engine, built, nil, in, cfg)
		if !t.OK {
			return fmt.Errorf("the connection test (the page's own): %s - nothing written (-no-test to write anyway)", t.Detail)
		}
	}
	dir := config.SecretDir(*path)
	ref, err := config.WriteSecretAs(dir, *name, built, account)
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, cfg.Repository.DSN())
	if err != nil {
		_ = config.RemoveSecret(dir, ref)
		return fmt.Errorf("the repository: %w", err)
	}
	defer pool.Close()
	if err := instanceWrite(ctx, pool, addPayload(*name, *platform, tags, c, ref, osAccount(), fileNamesOf(cfg))); err != nil {
		_ = config.RemoveSecret(dir, ref)
		return fmt.Errorf("not added: %w", err)
	}
	fmt.Printf("instance %s added (%s at %s, auth %s); its credential is %s, %s's; the collector reads it at its next inventory read\n", *name, c.Engine, c.Host, c.Auth, filepath.Base(strings.TrimPrefix(strings.TrimPrefix(ref, "file:"), "dpapi:")), account)
	return nil
}

// instanceRow is one line of 'pgvigil instance list'.
type instanceRow struct {
	Name, Source, Engine, State, LastAge string
}

// instanceRows lists the file's instances and the page's, each with its last collection's age (RELNOTES L170 with
// ST1's command-line half: the newest snapshot of pgvigil.collection_dates, this command's own read; the page has none).
func instanceRows(ctx context.Context, pool *pgxpool.Pool, cfg *config.Config) ([]instanceRow, error) {
	last := map[string]time.Time{}
	rows, err := pool.Query(ctx, `SELECT i.name, max(c.snapshot_at) FROM pgvigil.instances i JOIN pgvigil.collection_dates c USING (instance_id) GROUP BY i.name`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var n string
		var at time.Time
		if err := rows.Scan(&n, &at); err != nil {
			rows.Close()
			return nil, err
		}
		last[n] = at
	}
	rows.Close()
	age := func(n string) string {
		at, ok := last[n]
		if !ok {
			return "never"
		}
		return time.Since(at).Round(time.Second).String() + " ago"
	}
	var out []instanceRow
	for _, in := range cfg.Instances {
		out = append(out, instanceRow{in.Name, "file", in.Engine, "enabled", age(in.Name)})
	}
	prow, err := pool.Query(ctx, `SELECT name, engine, disabled FROM pgvigil.admin_inventory() ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer prow.Close()
	for prow.Next() {
		var n, e string
		var off bool
		if err := prow.Scan(&n, &e, &off); err != nil {
			return nil, err
		}
		st := "enabled"
		if off {
			st = "disabled"
		}
		out = append(out, instanceRow{n, "page", e, st, age(n)})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, prow.Err()
}

func runInstanceList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("pgvigil instance list", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "the configuration file")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	cfg, err := loadConfigAt(*path, false)
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, cfg.Repository.DSN())
	if err != nil {
		return fmt.Errorf("the repository: %w", err)
	}
	defer pool.Close()
	rows, err := instanceRows(ctx, pool, cfg)
	if err != nil {
		return err
	}
	for _, r := range rows {
		fmt.Printf("%-30s %-5s %-10s %-9s last collection %s\n", r.Name, r.Source, r.Engine, r.State, r.LastAge)
	}
	return nil
}

func runInstanceDisable(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("pgvigil instance disable", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "the configuration file")
	name := fs.String("name", "", "the page instance to disable (a file instance is disabled in pgvigil.yaml)")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	if *name == "" {
		return &usageError{errors.New("instance disable takes -name")}
	}
	cfg, err := loadConfigAt(*path, false)
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, cfg.Repository.DSN())
	if err != nil {
		return fmt.Errorf("the repository: %w", err)
	}
	defer pool.Close()
	if err := instanceWrite(ctx, pool, map[string]any{"op": "disable", "ui_user": "cli:" + osAccount(), "client": "cli", "name": *name, "file_names": fileNamesOf(cfg)}); err != nil {
		return fmt.Errorf("not disabled: %w", err)
	}
	fmt.Printf("instance %s disabled; the collector stops reading it at its next inventory read\n", *name)
	return nil
}
