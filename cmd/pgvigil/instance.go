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

// 'pgvigil instance add | list | disable' (PerformanceMonitor 3.5.0's --add-server):
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

// osAccount names the account running the command, for the audit: on Linux the uid's name read from the system's user
// list (never $USER, which a command line sets) and, when it differs, the login's own account (/proc/self/loginuid:
// sudo keeps it and the process cannot change it) - 'root (login alice)'; elsewhere the account the OS names.
func osAccount() string {
	if runtime.GOOS != "linux" {
		if u, err := user.Current(); err == nil && u.Username != "" {
			return u.Username
		}
		return "unknown"
	}
	name := func(uid string) string {
		if u, err := user.LookupId(uid); err == nil && u.Username != "" {
			return u.Username
		}
		return "uid " + uid
	}
	uid := strconv.Itoa(os.Getuid())
	who := name(uid)
	if b, err := os.ReadFile("/proc/self/loginuid"); err == nil {
		if l := strings.TrimSpace(string(b)); l != "" && l != "4294967295" && l != uid {
			who += " (login " + name(l) + ")"
		}
	}
	return who
}

// dsnHolds says whether a connection string names a key, in its keyword or its URL form.
func dsnHolds(dsn, key string) bool {
	if u, err := url.Parse(dsn); err == nil && u.Scheme != "" {
		switch key {
		case "host":
			return u.Hostname() != ""
		case "user":
			return u.User != nil && u.User.Username() != ""
		case "password":
			if u.User != nil {
				if _, ok := u.User.Password(); ok {
					return true
				}
			}
		case "port":
			if u.Port() != "" {
				return true
			}
		case "dbname":
			if strings.Trim(u.Path, "/") != "" {
				return true
			}
		}
		for k := range u.Query() {
			if strings.EqualFold(k, key) {
				return true
			}
		}
		return false
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
		// a service file names what the dsn does not: the administrator's own, never the service's
		if dsnHolds(dsn, "service") || os.Getenv("PGSERVICE") != "" {
			return config.Conn{}, errors.New("the dsn names a service (service= or PGSERVICE): a page instance's connection string names its host, port, database and user itself")
		}
		if keys := pgKeysNotCarried(dsn); len(keys) > 0 {
			return config.Conn{}, fmt.Errorf("the dsn's %s %s not carried by a page instance (it keeps host, port, dbname, user, password and sslmode): name the instance in pgvigil.yaml instead", strings.Join(keys, ", "), map[bool]string{true: "is", false: "are"}[len(keys) == 1])
		}
		pc, err := pgconn.ParseConfig(dsn)
		if err != nil {
			return config.Conn{}, errors.New("the dsn does not read as a PostgreSQL connection string")
		}
		// pgconn makes a fallback of the same host for sslmode prefer (its default): only another host:port is a second
		hosts := map[string]bool{fmt.Sprintf("%s:%d", pc.Host, pc.Port): true}
		for _, f := range pc.Fallbacks {
			hosts[fmt.Sprintf("%s:%d", f.Host, f.Port)] = true
		}
		if len(hosts) > 1 {
			return config.Conn{}, errors.New("the dsn names more than one host: a page instance has one (name a list in pgvigil.yaml)")
		}
		// pgconn fills what the dsn leaves out from this shell (PGPASSWORD, PGPORT, PGDATABASE, the running account's
		// passfile): only what the dsn names is taken, the rest the page's own defaults - never the administrator's
		c := config.Conn{Engine: engine, Auth: "pgpass", Host: pc.Host, Port: 5432, Login: pc.User}
		if dsnHolds(dsn, "port") {
			c.Port = int(pc.Port)
		}
		if dsnHolds(dsn, "dbname") {
			c.DBName = pc.Database
		}
		if dsnHolds(dsn, "password") {
			c.Password, c.Auth = pc.Password, "password"
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

// pgCarried are the PostgreSQL keys a page instance keeps (config.BuildDSN writes them).
var pgCarried = map[string]bool{"host": true, "hostaddr": true, "port": true, "dbname": true, "user": true, "password": true, "sslmode": true}

// pgKeysNotCarried are the keys a PostgreSQL connection string names beyond the ones a page instance keeps.
func pgKeysNotCarried(dsn string) []string {
	var out []string
	if u, err := url.Parse(dsn); err == nil && u.Scheme != "" {
		for k := range u.Query() {
			if !pgCarried[strings.ToLower(k)] {
				out = append(out, k)
			}
		}
		sort.Strings(out)
		return out
	}
	for _, f := range strings.Fields(dsn) {
		if k, _, ok := strings.Cut(f, "="); ok && !pgCarried[strings.ToLower(strings.TrimSpace(k))] {
			out = append(out, strings.TrimSpace(k))
		}
	}
	sort.Strings(out)
	return out
}

// dsnParamGiven says whether a SQL Server connection string names a parameter itself (msdsn adds its defaults): a
// URL's query, or an ADO / ODBC string's ';' parts.
func dsnParamGiven(dsn, key string) bool {
	if u, err := url.Parse(dsn); err == nil && u.Scheme == "sqlserver" {
		for k := range u.Query() {
			if strings.EqualFold(k, key) {
				return true
			}
		}
		return false
	}
	for _, part := range strings.Split(strings.TrimPrefix(dsn, "odbc:"), ";") {
		if k, _, ok := strings.Cut(part, "="); ok && strings.EqualFold(strings.TrimSpace(k), key) {
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
	// everything a refusal can settle, before the connection string is read
	if why := config.PlatformRefusal(*engine, *platform); why != "" {
		return &usageError{errors.New("-platform: " + why)}
	}
	if svcCfg, ok := installedConfigPath(); ok && !samePath(svcCfg, *path) {
		return otherConfigRefusal(*path, svcCfg)
	}
	cfg, err := loadConfigAt(*path, false)
	if err != nil {
		return err
	}
	repoDSN, err := repoDSNOf(*path, cfg)
	if err != nil {
		return err
	}
	for _, f := range fileNamesOf(cfg) {
		if strings.EqualFold(f, *name) {
			return fmt.Errorf("instance %s is named in pgvigil.yaml: a page instance takes another name (nothing read, nothing written)", *name)
		}
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
			return fmt.Errorf("the connection test (the page's own, as %s): %s - nothing written (-no-test to write anyway)", osAccount(), t.Detail)
		}
		// a sign-in of the running account (Windows, Kerberos, a passfile) is this account's, not the service's
		if c.Auth == "windows" || c.Auth == "pgpass" {
			fmt.Printf("the connection test signed in as %s (auth %s): the service signs in as %s, whose sign-in this test did not try\n", osAccount(), c.Auth, account)
		}
	}
	dir := config.SecretDir(*path)
	ref, err := config.WriteSecretAs(dir, *name, built, account)
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, repoDSN)
	if err != nil {
		_ = config.RemoveSecret(dir, ref)
		return fmt.Errorf("the repository: %w", err)
	}
	defer pool.Close()
	if err := instanceWrite(ctx, pool, addPayload(*name, *platform, splitTags(tags), c, ref, osAccount(), fileNamesOf(cfg))); err != nil {
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
// ST1's command-line half: the newest successful collection, as the page's last_collected counts it, through
// pgvigil.admin_instance_ages() - 0480, the collector's login holding no SELECT on the tables).
func instanceRows(ctx context.Context, pool *pgxpool.Pool, cfg *config.Config) ([]instanceRow, error) {
	// the ages through pgvigil.admin_instance_ages() (0480): the configuration's repository login is the collector's,
	// which holds no SELECT on the tables; a read that fails is an error, never every instance 'never' (rows.Err())
	last := map[string]time.Time{}
	rows, err := pool.Query(ctx, `SELECT name, last_at FROM pgvigil.admin_instance_ages() WHERE last_at IS NOT NULL`)
	if err != nil {
		return nil, fmt.Errorf("the last collections: %w", err)
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
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("the last collections: %w", err)
	}
	age := func(n string) string {
		at, ok := last[n]
		if !ok {
			return "no successful run now" // no collection whose last run succeeded (each keeps its last run only)
		}
		return time.Since(at).Round(time.Second).String() + " ago"
	}
	inFile := map[string]bool{}
	for _, in := range cfg.Instances {
		inFile[strings.ToLower(in.Name)] = true
	}
	var out []instanceRow
	for _, in := range cfg.Instances {
		out = append(out, instanceRow{in.Name, "file", in.Engine, "enabled", age(in.Name)})
	}
	// admin_inventory() answers its state row alone (every instance column NULL) when no page instance exists (0193)
	prow, err := pool.Query(ctx, `SELECT name, engine, disabled FROM pgvigil.admin_inventory() WHERE name IS NOT NULL ORDER BY name`)
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
		if inFile[strings.ToLower(n)] { // the collector reads the file's instance of that name, never this row
			out = append(out, instanceRow{n, "page", e, "left out (pgvigil.yaml holds " + n + ")", "-"})
			continue
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
	repoDSN, err := repoDSNOf(*path, cfg)
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, repoDSN)
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
	repoDSN, err := repoDSNOf(*path, cfg)
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, repoDSN)
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

// splitTags splits each -tag on white space, as the page reads its tag field (-tag "env prod" is two tags).
func splitTags(tags []string) []string {
	var out []string
	for _, t := range tags {
		out = append(out, strings.Fields(t)...)
	}
	return out
}

// otherConfigRefusal is add's refusal of a -config that is not the installed service's: why (the credential goes beside
// the configuration the service reads, and the row into that one's repository) and what to do instead.
func otherConfigRefusal(given, svcCfg string) error {
	return fmt.Errorf("-config %s is not the installed service's configuration (%s): a page instance's credential goes beside the configuration the service reads and its row into that configuration's repository, so add takes that one alone - run it again with -config %s, or, for another configuration, on a host where no pgvigil service is installed (nothing read, nothing written)", given, svcCfg, svcCfg)
}
