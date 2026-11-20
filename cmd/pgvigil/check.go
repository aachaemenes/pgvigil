package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/alerts"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// 'pgvigil check' (L181, PerformanceMonitor's --validate-config / --check-settings): a read-only health check of an
// install - the configuration as 'run' loads it, the repository's reach, level, size and (for a store on this host)
// free space, and one connection test per instance through the page's own test (web.CheckConnection). Nothing is
// written to the repository or to a monitored server. Exit 0 = all OK; 1 = the configuration does not load (or a
// usage error); 2 = the repository is unreachable or newer than this build; 3 = any WARN or a failed instance.

// inlinePasswordWords: the fix for an inline PostgreSQL password, in the words the load's WARN and 'pgvigil check'
// share (L9; config.go's sqlserver refusal names the same two reference forms).
// rn-l9 B2: env: and file: hold the WHOLE connection string, never the password alone; N3: the seal writes a dpapi:
// reference on Windows, a file elsewhere.
const inlinePasswordWords = "its dsn carries an inline password: move the whole connection string to env:NAME or file:/path - 'pgvigil secret seal -name <instance>' seals it (a dpapi: reference on Windows, a file elsewhere) - or the password alone to a passfile or password_secret (the inline form is discouraged)"

// warnInlinePasswords (L9): the collector's load warns once for each PostgreSQL instance whose dsn in pgvigil.yaml
// carries an inline password - the configuration keeps loading; the password itself is never logged.
func warnInlinePasswords(log *slog.Logger, cfg *config.Config) {
	for _, name := range cfg.InlinePasswordInstances() {
		log.Warn("instance "+name+": "+inlinePasswordWords, "instance", name)
	}
}

// checkRow is one line of 'pgvigil check': OK | WARN | FAIL, what it judged, and the words.
type checkRow struct {
	Level string `json:"level"`
	What  string `json:"what"`
	Words string `json:"words"`
}

// checkExit carries the command's exit code through main's error path.
type checkExit struct{ code, warns, fails int }

func (e *checkExit) Error() string {
	return fmt.Sprintf("check: %d warning(s), %d failure(s)", e.warns, e.fails)
}
func (e *checkExit) ExitCode() int { return e.code }

// stringsFlag collects a repeatable flag's values.
type stringsFlag []string

func (f *stringsFlag) String() string     { return strings.Join(*f, ",") }
func (f *stringsFlag) Set(v string) error { *f = append(*f, v); return nil }

func runCheck(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("pgvigil check", flag.ContinueOnError)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	asJSON := fs.Bool("json", false, "print the rows as JSON")
	var only stringsFlag
	fs.Var(&only, "instance", "test this instance alone (repeatable); the configuration and repository checks still run")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 { // rn-l181 N8: 'pgvigil check /etc/pgvigil/pgvigil.yaml' must not check ./pgvigil.yaml
		return fmt.Errorf("pgvigil check: unexpected argument %q - the file is -config <path>", fs.Arg(0))
	}
	rows, exit := checkRun(ctx, log, *path, only)
	if *asJSON {
		b, err := json.MarshalIndent(rows, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(b))
	} else {
		for _, r := range rows {
			if _, err := fmt.Fprintf(os.Stdout, "%-4s %s: %s\n", r.Level, r.What, r.Words); err != nil {
				return err
			}
		}
	}
	if exit == 0 {
		return nil
	}
	warns, fails := 0, 0
	for _, r := range rows {
		switch r.Level {
		case "WARN":
			warns++
		case "FAIL":
			fails++
		}
	}
	return &checkExit{code: exit, warns: warns, fails: fails}
}

// pgSpecNames: the PostgreSQL collections' names (a test writes an all-off schedules: block from it).
func pgSpecNames() []string {
	var out []string
	for _, s := range engines.Specs(config.EnginePostgres) {
		out = append(out, s.Name)
	}
	return out
}

// checkRun runs every check and returns the rows and the exit code (C5).
func checkRun(ctx context.Context, log *slog.Logger, path string, only []string) ([]checkRow, int) {
	var rows []checkRow
	add := func(level, what, words string) { rows = append(rows, checkRow{level, what, words}) }
	log.Debug("check", "config", path, "only", only)
	cfg, err := loadConfigAt(path, false)
	if err != nil {
		add("FAIL", "configuration", err.Error())
		return rows, 1
	}
	// rn-l181 S1 (a): the alerts: block as 'run' loads it (its channels, the slack door, alerts_dsn, base_url)
	if _, err := alerts.LoadFile(path); err != nil {
		add("FAIL", "configuration", err.Error())
		return rows, 1
	}
	add("OK", "configuration", fmt.Sprintf("%s loads: %d instance(s) in the file", path, len(cfg.Instances)))
	// C2: the configuration's warnings
	for _, name := range cfg.InlinePasswordInstances() {
		add("WARN", "instance "+name, inlinePasswordWords)
	}
	// L169: who may read the files that can hold a secret (check changes nothing; a FAIL prints its fix)
	for _, r := range secretFileRows(path) {
		add(r.Level, r.What, r.Words)
	}
	// L241: every env: / file: / dpapi: reference of the file
	referenceRows(path, add)
	for _, in := range cfg.Instances {
		eng := engineName(in)
		runnable := 0
		for _, c := range engines.Specs(eng) {
			if cfg.Interval(in, c.Name, c.Default) <= 0 {
				continue
			}
			if skip, _ := engines.Gated(in, c.Name); skip {
				continue
			}
			runnable++
		}
		if runnable == 0 {
			add("WARN", "instance "+in.Name, "no collection is left to run there (every one is off by schedules:/disabled: or gated)")
		}
	}
	// C3: the repository
	repoBad := false
	all := cfg.Instances
	rctx, rcancel := context.WithTimeout(ctx, 15*time.Second)
	repoDSN := cfg.Repository.DSN()
	var rc *pgx.Conn
	if repoDSN == "" {
		// never connected: an empty dsn is libpq's defaults (PGHOST / PGPORT, else localhost, as this OS account)
		err = fmt.Errorf("dsn %q resolved to an empty string (%s): nothing was connected", cfg.Repository.DSNRaw, collect.EmptyDSNWhy(cfg.Repository.DSNRaw))
	} else {
		// rn-l181 B2: parsed as the pool parses it, so a pool_* key of the dsn (README: pool_max_conns) never reaches
		// the server as a startup parameter (sched.go's rule)
		var pc *pgxpool.Config
		if pc, err = pgxpool.ParseConfig(repoDSN); err == nil {
			rc, err = pgx.ConnectConfig(rctx, pc.ConnConfig)
		}
		if err != nil {
			err = fmt.Errorf("unreachable: %w", err)
		}
	}
	if err != nil {
		rcancel()
		add("FAIL", "repository", err.Error())
		repoBad = true
		add("WARN", "inventory", "Admin > Instances was not read: the repository was not reached; the file's instances alone are tested")
	} else {
		// rn-l181 B1 / S2: the level read as 'run' reads it - through the SECURITY DEFINER functions the collector
		// login may call (it reads no table): behind = an embedded migration the store lacks, whatever its number;
		// newer = the store's newest applied version past this build's newest
		latest, lerr := repo.LatestMigration()
		var have *string
		herr := rc.QueryRow(rctx, `SELECT pgvigil.schema_latest()`).Scan(&have)
		current, need, serr := repo.SchemaCurrentWith(rctx, rc)
		var size int64
		zerr := rc.QueryRow(rctx, `SELECT pg_database_size(current_database())`).Scan(&size)
		sizeWords := fmtGiB(size)
		if zerr != nil {
			sizeWords = "its size not read: " + zerr.Error()
		}
		switch {
		case lerr != nil:
			add("FAIL", "repository", lerr.Error())
			repoBad = true
		case herr == nil && have != nil && *have > latest:
			add("FAIL", "repository", fmt.Sprintf("written by a newer pgvigil (%s; this build carries %s): this build must not run on it", *have, latest))
			repoBad = true
		case serr != nil:
			add("FAIL", "repository", "the level was not read: "+serr.Error())
			repoBad = true
		case !current:
			add("WARN", "repository", fmt.Sprintf("behind this build (it lacks %s): run pgvigil migrate", need))
		default:
			add("OK", "repository", fmt.Sprintf("at %s (this build's level), %s", latest, sizeWords))
		}
		if zerr == nil {
			checkSpace(rctx, rc, size, add)
		}
		_ = rc.Close(context.WithoutCancel(ctx))
		rcancel()
		// Q3 (a): the scheduler's whole set - the file's instances and Admin > Instances' enabled inventory; every
		// path that reads no inventory says so (rn-l181 N3), the open bounded with the read
		ictx, icancel := context.WithTimeout(ctx, 10*time.Second)
		if r, rerr := repo.Open(ictx, repoDSN); rerr != nil {
			add("WARN", "inventory", "Admin > Instances was not read: "+rerr.Error())
		} else {
			if page, _, perr := r.Inventory(ictx); perr == nil {
				merged, skipped, dropped := config.MergeNotes(cfg.Instances, page, cfg.QueryText, cfg.MSSQLCounters)
				all = merged
				for _, s := range skipped {
					add("WARN", "inventory", s)
				}
				for _, d := range dropped { // rn-l181 N4: the scheduler logs these as warnings too
					add("WARN", "inventory", d)
				}
			} else {
				add("WARN", "inventory", "Admin > Instances was not read: "+perr.Error())
			}
			r.Close()
		}
		icancel()
	}

	// C4: one connection test per instance, at most 8 at a time, 10 s each (web.CheckConnection's own bound)
	want := map[string]bool{}
	for _, n := range only {
		want[n] = true
	}
	type res struct {
		in  config.Instance
		t   web.CheckResult
		why string
	}
	out := make([]res, 0, len(all))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for _, in := range all {
		if len(want) > 0 && !want[in.Name] {
			continue
		}
		wg.Add(1)
		go func(in config.Instance) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			r := res{in: in}
			if dsn := in.DSN(); dsn == "" {
				r.why = fmt.Sprintf("dsn %q resolved to an empty string (%s)", in.DSNRaw, collect.EmptyDSNWhy(in.DSNRaw))
			} else {
				r.t = web.CheckConnection(ctx, engineName(in), dsn, in.SecretRef(), in, cfg)
			}
			mu.Lock()
			out = append(out, r)
			mu.Unlock()
		}(in)
	}
	wg.Wait()
	// rn-l181 N5: in name order, so two runs on one site print alike; S4: a -instance that names nothing is a FAIL
	sort.Slice(out, func(i, j int) bool { return out[i].in.Name < out[j].in.Name })
	known := map[string]bool{}
	for _, in := range all {
		known[in.Name] = true
	}
	for _, n := range only {
		if !known[n] {
			add("FAIL", "instance "+n, "no instance of that name in the file or on Admin > Instances: nothing was tested")
		}
	}
	for _, r := range out {
		for _, row := range instanceCheckRows(r.in.Name, r.t, r.why) {
			add(row.Level, row.What, row.Words)
		}
	}
	// C5: the exit
	switch {
	case repoBad:
		return rows, 2
	default:
		for _, r := range rows {
			if r.Level != "OK" {
				return rows, 3
			}
		}
	}
	return rows, 0
}

// instanceCheckRows: one instance's rows - a FAIL (why: a dsn that resolved to nothing; or the connection test's own
// words), or its OK row and, for a server this build does not know (L217), a WARN with what was read.
func instanceCheckRows(name string, t web.CheckResult, why string) []checkRow {
	what := "instance " + name
	switch {
	case why != "":
		return []checkRow{{"FAIL", what, why}}
	case !t.OK:
		return []checkRow{{"FAIL", what, t.Detail}}
	}
	words := t.Detail
	if t.ListNote != "" {
		words += "; " + t.ListNote
	}
	if n := len(t.NotRun); n > 0 {
		parts := make([]string, 0, n)
		for _, nr := range t.NotRun {
			parts = append(parts, nr.Name+" ("+nr.Why+")")
		}
		words += fmt.Sprintf("; %d of %d collections will not run there: %s", n, t.Collections, strings.Join(parts, ", "))
	}
	rows := []checkRow{{"OK", what, words}}
	if t.Unknown != "" {
		rows = append(rows, checkRow{"WARN", what, t.Unknown})
	}
	return rows
}

// referenceRows (RELNOTES L241): one FAIL for each env: / file: / dpapi: reference of the file that resolves to
// nothing, with config.WhyEmpty's words (the reference, never what it read); one OK row when every one resolves. The
// repository's dsn and each instance's dsn are left to their own rows, which FAIL them with the same words.
func referenceRows(path string, add func(level, what, words string)) {
	refs, err := config.FileReferences(path)
	if err != nil {
		add("WARN", "references", "the file was not read for its references: "+err.Error())
		return
	}
	n, bad := 0, 0
	for _, r := range refs {
		if r.Where == "repository.dsn" || (strings.HasPrefix(r.Where, "instances[") && strings.HasSuffix(r.Where, "].dsn")) {
			continue
		}
		n++
		if why := config.WhyEmpty(r.Raw); why != "" {
			bad++
			add("FAIL", "reference "+r.Where, r.Raw+" resolves to nothing: "+why)
		}
	}
	if n > 0 && bad == 0 {
		add("OK", "references", fmt.Sprintf("every env: / file: / dpapi: reference of the file resolves (%d; the repository's and each instance's dsn have their own rows)", n))
	}
}

// checkSpace (Q2 a): the free space beside the store, read only when the store is on this host (judged by the
// address the connection reached, rn-l181 N2: a dsn's first host may not be the one that answered) and its
// data_directory is readable to this login and this process; a WARN under 10 GiB free or under 30 days of the store's
// growth - the beats' repo_bytes reading of one to two days ago, scaled by its age (N1). The collector's login reads
// no table: a growth not read is said, never skipped silently (B1).
func checkSpace(ctx context.Context, rc *pgx.Conn, size int64, add func(level, what, words string)) {
	where, local := "an unknown address", false
	switch a := rc.PgConn().Conn().RemoteAddr().(type) {
	case *net.UnixAddr:
		local = true
	case *net.TCPAddr:
		where, local = a.IP.String(), a.IP.IsLoopback()
	}
	if !local {
		add("OK", "repository space", "not read: the store is on "+where)
		return
	}
	var dir string
	if err := rc.QueryRow(ctx, `SELECT current_setting('data_directory')`).Scan(&dir); err != nil {
		add("OK", "repository space", "not read: data_directory is not readable to this login")
		return
	}
	if _, err := os.Stat(dir); err != nil {
		add("OK", "repository space", "not read: the store's directory is not readable to this process")
		return
	}
	// the platform's own read (the upgrade's: statfs on Linux, GetDiskFreeSpaceEx on Windows); none elsewhere
	if upgradeHooksOf == nil || upgradeHooksOf.freeBytes == nil {
		add("OK", "repository space", "not read: no free-space read on this platform")
		return
	}
	free, err := upgradeHooksOf.freeBytes(dir)
	if err != nil {
		add("OK", "repository space", "not read: "+err.Error())
		return
	}
	var past int64
	var ageS float64
	growth := ""
	gerr := rc.QueryRow(ctx, `SELECT repo_bytes, extract(epoch FROM now() - at)::float8 FROM pgvigil.collector_beats
	  WHERE at <= now() - interval '23 hours' AND at > now() - interval '48 hours' AND repo_bytes IS NOT NULL
	  ORDER BY at DESC LIMIT 1`).Scan(&past, &ageS)
	switch {
	case errors.Is(gerr, pgx.ErrNoRows):
		growth = "; growth not read: no beat of one to two days ago"
	case gerr != nil:
		growth = "; growth not read: " + gerr.Error()
	}
	var perDay int64
	if gerr == nil && ageS > 0 {
		perDay = int64(float64(size-past) * 86400 / ageS)
	}
	switch {
	case free < 10<<30:
		add("WARN", "repository space", fmt.Sprintf("%s free beside the store (under 10 GiB)%s", fmtGiB(int64(free)), growth))
	case perDay > 0 && free < 30*uint64(perDay):
		add("WARN", "repository space", fmt.Sprintf("%s free beside the store: under 30 days at the store's growth (%s a day)", fmtGiB(int64(free)), fmtGiB(perDay)))
	default:
		add("OK", "repository space", fmtGiB(int64(free))+" free beside the store"+growth)
	}
}

// engineName: the instance's engine, postgres when unset.
func engineName(in config.Instance) string {
	if in.Engine == "" {
		return config.EnginePostgres
	}
	return in.Engine
}

// fmtGiB prints bytes as GiB to one place (MiB under one).
func fmtGiB(b int64) string {
	if b < 1<<30 {
		return fmt.Sprintf("%.0f MiB", float64(b)/(1<<20))
	}
	return fmt.Sprintf("%.1f GiB", float64(b)/(1<<30))
}
