package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"debug/buildinfo"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/term"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// pgvigil install puts the collector in place as a service and pgvigil uninstall takes the service
// away again; both are thin and re-runnable (a second install is an upgrade: the binary and the unit
// or service definition are replaced, the config is kept, a running service is restarted).
//
//	pgvigil install   [-bin <path>] [-config <path>] [-user <account>] [-no-start]
//	pgvigil install   -upgrade [-owner-dsn-file <path> | -owner-dsn-env <NAME>] [-dump <file> [-pg-dump <path>] | -no-dump]
//	pgvigil uninstall [-config <path>] [-purge]
//	pgvigil uninstall -all [-bin <path>] [-config <path>] [-user <account>] [-dry-run] [-drop-repository [-confirm-database <name>]
//	                  [-owner-dsn-file <path> | -owner-dsn-env <NAME>] [-dump <file> [-pg-dump <path>] | -no-dump]]
//
// uninstall -all (docs/uninstall.md) removes everything of pgvigil on this host in one order: every refusal first, the
// service stopped, the repository (with -drop-repository: the database's name typed, no other collector or session on
// it, a dump, DROP DATABASE, the pgvigil roles nothing else uses), the Windows app, the service definition, the
// binaries, the configuration, the account the install made last. A refusal after the stop starts the collector again.
// -dry-run lists every item, present, absent or kept and why; a second run ends 'nothing of pgvigil is left to remove'.
//
// install -upgrade (the offline installers call it, docs/upgrade.md) upgrades the installed collector to this binary in
// the order upgrade.md gives: every refusal first (the installed service's own paths and account, the repository
// owner's connection, pg_dump not older than the server, room for the dump, no other pgvigil process on the installed
// binary), then stop, dump, migrate, swap (the binary it replaces kept as <bin>.previous), start, the way back printed.
// A failed migrate swaps nothing and starts nothing: the service stays stopped and the way back is printed.
//
// Linux: the binary to -bin (default /usr/local/bin/pgvigil), the config template to -config (default
// /etc/pgvigil/pgvigil.yaml) with /etc/pgvigil/pgvigil.env beside it for PGVIGIL_REPO_DSN, a system
// account (default pgvigil, created when missing), a systemd unit /etc/systemd/system/pgvigil.service
// enabled and started once the repository DSN is filled in (PGVIGIL_REPO_DSN in the env file). Windows: the
// binary to %ProgramFiles%\pgvigil, the config and repo.dsn under %ProgramData%\pgvigil (readable by SYSTEM,
// Administrators and the service's own virtual account NT SERVICE\pgvigil only), the service pgvigil (automatic
// start, restart on failure) started once repo.dsn holds the DSN. The instances are listed in the config or
// added in the page (Admin > Instances); none in the file is fine. Other systems: the binary and the config only.
// Nothing here touches a monitored server or the repository: migrate, roles and user stay separate
// commands run by the repository owner.

// installOptions are the flags of install and uninstall after the platform defaults are applied.
type installOptions struct {
	Bin     string // where the binary lives when installed
	Config  string // the config file
	User    string // the service account (Linux: a system user; Windows: fixed to the virtual account)
	NoStart bool   // write everything, start nothing
	Purge   bool   // uninstall: remove the config folder and the binary too

	Upgrade      bool   // install: upgrade the installed collector (stop, dump, migrate, swap, start)
	OwnerDSNEnv  string // the variable holding the repository owner's connection string
	OwnerDSNFile string // a file holding it (first line); sudo's env_reset drops a variable, a file survives
	Dump         string // the dump file (default: the platform's backup folder, named by version and time)
	NoDump       bool   // no dump: the operator's word that the way back is not wanted
	PgDump       string // pg_dump to use (default: the one on PATH)

	All             bool   // uninstall: everything of pgvigil on this host (docs/uninstall.md)
	DryRun          bool   // uninstall -all: list every item and what would be done, change nothing
	DropRepository  bool   // uninstall -all: drop the repository database and the pgvigil roles too
	ConfirmDatabase string // uninstall -all -drop-repository: the database's name, for a run without a terminal

	set map[string]bool // the flags named on the command line
}

func parseInstallArgs(name string, args []string, def installOptions) (installOptions, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	o := def
	fs.StringVar(&o.Bin, "bin", def.Bin, "path the binary is installed to")
	fs.StringVar(&o.Config, "config", def.Config, "path of the configuration file")
	fs.StringVar(&o.User, "user", def.User, "service account (Linux; install creates it as a system user when missing)")
	// the repository owner's connection and the dump: -upgrade's (install) and -drop-repository's (uninstall -all)
	with := "-upgrade"
	if name == "install" {
		fs.BoolVar(&o.NoStart, "no-start", false, "install and enable, but do not start the service")
		fs.BoolVar(&o.Upgrade, "upgrade", false, "upgrade the installed collector: stop, dump, migrate, swap, start (docs/upgrade.md)")
	} else {
		with = "-drop-repository"
		fs.BoolVar(&o.Purge, "purge", false, "also remove the installer's files, their folder when empty, and the binary")
		fs.BoolVar(&o.All, "all", false, "remove everything of pgvigil on this host: the service, the binaries, the configuration, the account the install made, the Windows app (docs/uninstall.md)")
		fs.BoolVar(&o.DryRun, "dry-run", false, "with -all: list every item, present or absent, and what would be done; change nothing")
		fs.BoolVar(&o.DropRepository, "drop-repository", false, "with -all: also drop the repository database and the pgvigil roles (the database's name typed, a dump first)")
		fs.StringVar(&o.ConfirmDatabase, "confirm-database", "", "with -drop-repository: the repository database's name, for a run without a terminal")
	}
	fs.StringVar(&o.OwnerDSNEnv, "owner-dsn-env", "PGVIGIL_OWNER_DSN", "with "+with+": the environment variable holding the repository owner's connection string")
	fs.StringVar(&o.OwnerDSNFile, "owner-dsn-file", "", "with "+with+": a file holding the repository owner's connection string (first line)")
	fs.StringVar(&o.Dump, "dump", "", "with "+with+": the dump file (default: "+dumpDirHint+")")
	fs.BoolVar(&o.NoDump, "no-dump", false, "with "+with+": take no dump (no copy of the repository is kept)")
	fs.StringVar(&o.PgDump, "pg-dump", "", "with "+with+": the pg_dump to use (default: the one on PATH)")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if fs.NArg() > 0 {
		return o, fmt.Errorf("%s takes flags only, got %q", name, fs.Arg(0))
	}
	o.set = map[string]bool{}
	fs.Visit(func(f *flag.Flag) { o.set[f.Name] = true })
	ownerFlags := []string{"owner-dsn-env", "owner-dsn-file", "dump", "no-dump", "pg-dump"}
	switch {
	case name == "uninstall" && !o.All && (o.DryRun || o.DropRepository):
		return o, errors.New("-dry-run and -drop-repository go with -all")
	case name == "uninstall" && !o.DropRepository:
		for _, n := range append(ownerFlags, "confirm-database") {
			if o.set[n] {
				return o, fmt.Errorf("-%s goes with -drop-repository only", n)
			}
		}
	case name == "install" && !o.Upgrade:
		for _, n := range ownerFlags {
			if o.set[n] {
				return o, fmt.Errorf("-%s goes with -upgrade only", n)
			}
		}
	case o.NoStart:
		return o, errors.New("-upgrade starts the service it stopped: -no-start does not go with it")
	}
	if o.NoDump && (o.set["dump"] || o.set["pg-dump"]) {
		return o, errors.New("-no-dump does not go with -dump or -pg-dump")
	}
	if o.set["owner-dsn-file"] && o.set["owner-dsn-env"] {
		return o, errors.New("-owner-dsn-file and -owner-dsn-env both name the owner's connection string: give one")
	}
	if o.User == "" {
		return o, errors.New("-user must name an account")
	}
	return o, nil
}

func runInstall(log *slog.Logger, args []string) error {
	o, err := parseInstallArgs("install", args, defaultInstallOptions())
	if err != nil {
		return err
	}
	if o.Upgrade {
		return runUpgrade(log, o)
	}
	_, _, err = installService(log, o)
	return err
}

func runUninstall(log *slog.Logger, args []string) error {
	o, err := parseInstallArgs("uninstall", args, defaultInstallOptions())
	if err != nil {
		return err
	}
	// task 201: an uninstall that keeps the repository retires this host in it (pgvigil.import_collector_retire) -
	// its 'collector not seen' alert would otherwise stand for good, hold its instances' alerts and keep every serve's
	// watchdog on. The service's own repository login is read now, before the configuration is removed.
	retire := collectorRetire(o)
	if o.All {
		err = runUninstallAll(log, o)
	} else {
		err = uninstallService(log, o)
	}
	// the retire follows the service, not the whole uninstall: a later step that failed (the configuration's folder,
	// the binary) leaves a host that collects no more; a refusal that changed nothing leaves the service, and no retire
	gone := false
	if upgradeHooksOf != nil {
		_, still, ierr := upgradeHooksOf.installed()
		gone = ierr == nil && !still
	}
	if err == nil || gone {
		retire(log)
	}
	return err
}

// collectorRetire returns what retires this host as a collector once its service is gone: nothing with
// -drop-repository (the repository goes) or -dry-run, nothing where no service was configured. It calls the door on
// the installed service's own repository login; when that cannot be done it names the statement for the repository
// owner, and the uninstall stays done.
func collectorRetire(o installOptions) func(log *slog.Logger) {
	none := func(*slog.Logger) {}
	if o.DropRepository || o.DryRun || upgradeHooksOf == nil || uninstallHooksOf == nil {
		return none
	}
	inst, found, err := upgradeHooksOf.installed()
	if err != nil || !found {
		inst = o
	}
	dsn, configured, derr := uninstallHooksOf.repoDSN(inst)
	if !configured {
		return none
	}
	host, _ := os.Hostname()
	return func(log *slog.Logger) {
		byHand := "this host stays listed as a collector in the repository: as its owner run SELECT pgvigil.import_collector_retire('" +
			strings.ReplaceAll(host, "'", "''") + "') - until then its 'collector not seen' alert stands"
		if derr != nil || strings.TrimSpace(dsn) == "" || host == "" {
			log.Warn(byHand)
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		conn, cerr := pgx.Connect(ctx, dsn)
		if cerr != nil {
			log.Warn(byHand, "err", cerr)
			return
		}
		defer func() { _ = conn.Close(context.Background()) }()
		var n int
		if qerr := conn.QueryRow(ctx, `SELECT pgvigil.import_collector_retire($1)`, host).Scan(&n); qerr != nil {
			log.Warn(byHand, "err", qerr)
			return
		}
		log.Info("this host is retired as a collector in the repository that stays: no 'collector not seen' alert will stand for it", "host", host, "runs", n)
	}
}

// installBinary copies the running executable to dst (mode 0755) through a temporary file in the
// same folder and a rename, so a running service never sees a half-written binary. dst already
// being this executable is a no-op.
func installBinary(log *slog.Logger, dst string) error {
	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("own path: %w", err)
	}
	if self, err = filepath.EvalSymlinks(self); err != nil {
		return fmt.Errorf("own path: %w", err)
	}
	if abs, err := filepath.Abs(dst); err == nil {
		dst = abs
	}
	if same, _ := sameFile(self, dst); same {
		log.Info("binary already in place", "path", dst)
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(self)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".pgvigil-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := io.Copy(tmp, in); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Chmod(tmpName, 0o755); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := replaceFile(tmpName, dst); err != nil {
		_ = os.Remove(tmpName)
		return fmt.Errorf("install %s: %w", dst, err)
	}
	log.Info("binary installed", "path", dst)
	return nil
}

func sameFile(a, b string) (bool, error) {
	fa, err := os.Stat(a)
	if err != nil {
		return false, err
	}
	fb, err := os.Stat(b)
	if err != nil {
		return false, err
	}
	return os.SameFile(fa, fb), nil
}

// writeIfAbsent writes content to path with mode when no file is there yet; an existing file is
// kept (a re-run never overwrites an edited config). It reports whether it wrote.
func writeIfAbsent(path, content string, mode os.FileMode) (bool, error) {
	if _, err := os.Stat(path); err == nil {
		return false, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return false, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return false, err
	}
	if _, err := f.WriteString(content); err != nil {
		_ = f.Close()
		return false, err
	}
	return true, f.Close()
}

// ownFiles are the files the installer itself puts beside the config (and the folder of the Windows log).
// instances/ and sources/ are the page's credential folders (task 204, config.SecretDir / SourceSecretDir), beside the config.
var ownFiles = []string{"pgvigil.yaml", "pgvigil.env", "repo.dsn", "pgvigil.log", "logs", "instances", "sources"}

// dedicatedFolder refuses a config folder that is not the installer's own. The installer sets that
// folder's permissions and -purge removes it, so it must be named pgvigil, or not exist yet, or hold
// nothing but the installer's files: a flat /etc/pgvigil.yaml would hand /etc to the service account
// and a C:\pgvigil.yaml would rewrite the ACL of C:\.
func dedicatedFolder(dir, cfgName string) error {
	if filepath.Base(dir) == "pgvigil" {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.Name() == cfgName || slices.Contains(ownFiles, e.Name()) {
			continue
		}
		return fmt.Errorf("-config %s: its folder %s holds other files (%s); the installer owns that folder (its permissions, -purge), so put the config in a folder of its own, e.g. %s", cfgName, dir, e.Name(), filepath.Join(dir, "pgvigil", cfgName))
	}
	return nil
}

// purgeFolder removes the installer's own files from dir and then dir itself when nothing else is
// left; a folder that still holds other files is kept and named.
func purgeFolder(log *slog.Logger, dir string, files ...string) error {
	for _, f := range files {
		if err := os.Remove(filepath.Join(dir, f)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	_ = os.Remove(filepath.Join(dir, "logs", "pgvigil.log"))
	_ = os.Remove(filepath.Join(dir, "logs"))
	if err := os.Remove(dir); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		log.Info("folder kept: it still holds other files", "path", dir, "files", strings.Join(foreignFiles(dir), ", "))
		return nil
	}
	log.Info("removed", "folder", dir)
	return nil
}

// configError is a configuration-shape failure (the file missing or invalid, no instance named).
// Its exit code 3 lets a service manager tell it from a runtime failure: the systemd unit does not
// restart on it (RestartPreventExitStatus=3) and the Windows service stops without a retry, so a host
// installed before its config is written does not loop at boot.
type configError struct{ err error }

func (e *configError) Error() string { return e.err.Error() }
func (e *configError) Unwrap() error { return e.err }
func (e *configError) ExitCode() int { return 3 }

// serviceEnv reads a variable of the installed service's own environment where the platform keeps one outside a file
// (Windows: the service's registry Environment); nil elsewhere. machineEnvValue reads the machine environment a service
// starts with (Windows: the Session Manager's Environment key), never this process's; nil elsewhere.
var (
	serviceEnv      func(name string) (string, bool)
	machineEnvValue func(name string) (string, bool)
)

// serviceRepoDSN resolves the repository connection string of the config at path the way the installed service does:
// an env:NAME DSN from envFile, the environment file the unit loads, when one is named (a name it lacks is empty: the
// service never sees the installer's own environment), else from the service's own environment (Windows: its registry
// Environment, then the machine environment); a file: DSN from its file; a literal as written. raw is the config's dsn:
// value. Only a platform with no service environment (neither) reads this process's environment, as the binary run by
// hand would.
func serviceRepoDSN(path, envFile string) (dsn, raw string, err error) {
	cfg, err := config.Load(path)
	if err != nil {
		return "", "", err
	}
	raw = cfg.Repository.DSNRaw
	name, isEnv := strings.CutPrefix(raw, "env:")
	switch {
	case !isEnv:
		dsn = cfg.Repository.DSN()
	case envFile != "":
		dsn, _ = envFileValue(envFile, name)
	case serviceEnv != nil:
		v, found := serviceEnv(name)
		if !found && machineEnvValue != nil {
			v, _ = machineEnvValue(name)
		}
		dsn = v
	default:
		dsn = cfg.Repository.DSN()
	}
	return dsn, raw, nil
}

// configReady says whether the service may start: the config loads and its repository DSN resolves, as the service
// resolves it (serviceRepoDSN), to something. The instances may all be in the page (Admin > Instances, task 204), so
// none in the file is fine; with an empty DSN the collector would end with exit 3 at once.
func configReady(path, envFile string) (bool, string) {
	dsn, raw, err := serviceRepoDSN(path, envFile)
	if err != nil {
		return false, err.Error()
	}
	if strings.TrimSpace(dsn) == "" {
		return false, "the repository dsn (" + raw + ") is empty yet"
	}
	return true, ""
}

// envFileValue reads NAME=value from a systemd environment file: the last assignment wins; a value wholly in one pair of
// quotes loses them, a quote inside or at one end only stays (password='a b' at the end of a DSN keeps its quotes).
func envFileValue(path, name string) (string, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	v, found := "", false
	for _, l := range strings.Split(string(b), "\n") {
		k, val, ok := strings.Cut(strings.TrimSpace(l), "=")
		if ok && strings.TrimSpace(strings.TrimPrefix(k, "export ")) == name {
			v, found = strings.TrimSpace(val), true
			if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] && !strings.ContainsRune(v[1:len(v)-1], rune(v[0])) {
				v = v[1 : len(v)-1]
			}
		}
	}
	return v, found
}

// configTemplate is the first config of an installed collector: the repository DSN comes from the
// environment (Linux: the env file beside it) or a file (Windows: repo.dsn beside it), the instance
// list is empty; the service waits until the DSN is filled in.
func configTemplate(repositoryDSN string) string {
	return strings.ReplaceAll(`# pgvigil configuration, written by 'pgvigil install'. Secrets stay out of this file:
#   env:NAME     read from the environment
#   file:/path   read from a file (one line)
# The full reference with every option: deploy/examples/pgvigil.example.yaml in the repository,
# https://github.com/aachaemenes/pgvigil#quick-start
repository:
  dsn: @DSN@

# A collection's default interval for every instance; an instance's own schedules: override it.
schedules:
  instance: 1h

# What statement text the repository may hold: full | normalized | none (an instance can override it).
query_text: full

# The instances to collect: listed here, or added in the page (Admin > Instances). Each dsn is env:NAME or
# file:/path; the login is a pg_monitor member ('pgvigil roles' prints its CREATE ROLE).
instances: []
#  - name: prod-writer
#    dsn: env:PROD_WRITER_DSN
#    platform: auto                   # auto | onprem | rds | aurora | azure | cloudsql | alloydb
#    tags: [prod]
`, "@DSN@", repositoryDSN)
}

// --- install -upgrade

// upgradeHooks is what a platform gives the upgrade; service_linux.go and service_windows.go set it in init. Elsewhere it
// stays nil and -upgrade refuses (the installers run on Linux and Windows).
type upgradeHooks struct {
	installed      func() (o installOptions, found bool, err error) // the installed service's binary, config and account
	privileged     func() error                                     // root (Linux), an elevated token (Windows), or why not
	stop           func(log *slog.Logger) error                     // stop the installed service, wait until it is down
	start          func(log *slog.Logger) error                     // start it again (the way back after a refused dump)
	others         func(bin string) ([]string, error)               // processes running bin that the service does not own
	freeBytes      func(dir string) (uint64, error)
	dumpDir        string                  // where a dump goes by default (outside every folder an uninstall removes)
	secureDumpDir  func(dir string) error  // a folder for the owner of the host only (0700; SYSTEM and Administrators)
	secureDumpFile func(file string) error // the dump file itself in a folder the operator named (Windows: its ACL)
	previous       func(bin string) string
	active         func() bool // the installed service runs now (recorded in the preflight)
}

var upgradeHooksOf *upgradeHooks

// dumpDirHint names the default dump folders in the flag's help (the hooks hold the one of this platform).
const dumpDirHint = `/var/backups/pgvigil on Linux, %ProgramData%\pgvigil-backups on Windows`

// upgradePlan is everything the preflight read; nothing has changed on the host when it is complete.
type upgradePlan struct {
	inst         installOptions
	ownerDSN     string
	database     string
	serverMajor  int
	dbBytes      int64
	pgDump       string
	pgDumpMajor  int
	dumpFile     string
	ownDumpDir   bool // the dump's folder is the default one or one this upgrade makes: locked to root / Administrators
	previous     string
	hasPrevious  bool
	conn         string // the owner's connection string without its password (pg_dump's command line)
	password     string // the password alone (pg_dump's temporary password file)
	sameBinary   bool   // the installed binary is already this one (a re-run after a half upgrade)
	wasActive    bool   // the service ran when the preflight read it: only such a service is started again after a refusal
	installedVer string // what the installed binary says it is
}

func runUpgrade(log *slog.Logger, o installOptions) error {
	h := upgradeHooksOf
	if h == nil {
		return errors.New("-upgrade runs on Linux and Windows, where the installers place the collector as a service")
	}
	p, err := upgradePreflight(log, h, o)
	if err != nil {
		return fmt.Errorf("upgrade refused, nothing was changed: %w", err)
	}
	fmt.Printf("upgrade of the installed collector: %s (%s) to %s\n  config %s, account %s, repository database %s (%s, PostgreSQL %d)\n",
		p.inst.Bin, p.installedVer, version, p.inst.Config, p.inst.User, p.database, humanBytes(p.dbBytes), p.serverMajor)
	if p.dumpFile != "" {
		fmt.Printf("  the dump: %s (pg_dump %d, %s)\n", p.dumpFile, p.pgDumpMajor, p.pgDump)
	} else {
		fmt.Printf("  no dump (-no-dump): the way back has no copy of the repository\n")
	}
	// the copy of the installed binary comes first, while the service still runs: a copy that cannot be made (a
	// read-only or full disk, no right) ends the upgrade before anything else changes, never after the migrate
	if p.sameBinary {
		fmt.Printf("1. the installed binary is already this one: %s is left as it is\n", p.previous)
	} else {
		if err := copyFileMode(p.inst.Bin, p.previous, 0o755); err != nil {
			return fmt.Errorf("upgrade refused, nothing else was changed: keeping the installed binary as %s: %w", p.previous, err)
		}
		fmt.Printf("1. kept the previous binary as %s\n", p.previous)
	}
	_, p.hasPrevious = fileExists(p.previous)
	// an interrupt while the service is down: say where the host stands and what takes it back, remove the password file
	stopped := make(chan struct{})
	defer close(stopped)
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sig)
	go func() {
		select {
		case <-sig:
			if f := passFile.Load(); f != nil {
				_ = os.Remove(*f)
			}
			fmt.Fprintf(os.Stderr, "\ninterrupted: the service is stopped and the upgrade did not finish (the migrate may have run). %s\n", wayBack(p, false))
			os.Exit(130)
		case <-stopped:
		}
	}()
	if err := h.stop(log); err != nil {
		return fmt.Errorf("stopping the service: %w (nothing else was changed)", err)
	}
	fmt.Printf("2. stopped the service\n")
	if p.dumpFile != "" {
		if err := upgradeDump(h, p); err != nil {
			// nothing has changed but the stop (and the copy beside the binary): the old collector runs again
			if !p.wasActive {
				return fmt.Errorf("the dump failed; the service was not running before the upgrade and is left stopped; nothing else was changed: %w", err)
			}
			if serr := h.start(log); serr != nil {
				return fmt.Errorf("the dump failed (%v) and the service did not start again (%v): start it by hand; nothing else was changed", err, serr)
			}
			return fmt.Errorf("the dump failed, the service runs again on the previous binary, nothing else was changed: %w", err)
		}
		fmt.Printf("3. dumped the repository to %s\n", p.dumpFile)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	n, err := upgradeMigrate(ctx, p.ownerDSN)
	if err != nil {
		fmt.Fprintf(os.Stderr, "the migrate failed: the binary was not swapped and the service stays stopped. %s\n", wayBack(p, false))
		return fmt.Errorf("migrate: %w", err)
	}
	fmt.Printf("4. migrated the repository: %d file(s) applied\n", n)
	inst := p.inst
	inst.Upgrade, inst.NoStart = false, false
	// step 5 says what installService did: it alone asks the gate (the repository DSN, task 204) from the service's own
	// environment, after its own files are in place, and checks the start
	started, why, err := installService(log, inst)
	if err != nil {
		fmt.Fprintf(os.Stderr, "the install of the new binary did not finish: %s\n", wayBack(p, false))
		return err
	}
	if started {
		fmt.Printf("5. swapped the binary and started the service\n%s\n", wayBack(p, true))
	} else {
		fmt.Printf("5. swapped the binary; the service is enabled, not started (%s)\n%s\n", why, wayBack(p, true))
	}
	return nil
}

// passFile is the password file of a running pg_dump, for the interrupt handler to remove.
var passFile atomic.Pointer[string]

func fileExists(path string) (os.FileInfo, bool) {
	st, err := os.Stat(path)
	return st, err == nil
}

// upgradePreflight reads everything the upgrade needs and refuses before any change.
func upgradePreflight(log *slog.Logger, h *upgradeHooks, o installOptions) (*upgradePlan, error) {
	if err := h.privileged(); err != nil {
		return nil, err
	}
	inst, found, err := h.installed()
	if err != nil {
		return nil, fmt.Errorf("reading the installed service: %w", err)
	}
	if !found {
		return nil, errors.New("no installed collector was found: run install without -upgrade for a fresh install")
	}
	// the installed service's own paths and account rule; a flag that names another is refused (an install made with
	// -bin, -config or -user is upgraded in place, never moved to the defaults)
	for _, f := range []struct{ name, flag, installed string }{{"bin", o.Bin, inst.Bin}, {"config", o.Config, inst.Config}, {"user", o.User, inst.User}} {
		if o.set[f.name] && !samePath(f.flag, f.installed) {
			return nil, fmt.Errorf("-%s %s disagrees with the installed service's %s: leave the flag out (the upgrade keeps the installed paths and account)", f.name, f.flag, f.installed)
		}
	}
	// the swap's own refusal (a config folder holding files the installer does not own) comes now, never after the migrate
	if err := dedicatedFolder(filepath.Dir(inst.Config), filepath.Base(inst.Config)); err != nil {
		return nil, err
	}
	inst.Upgrade = true
	p := &upgradePlan{inst: inst, previous: h.previous(inst.Bin), wasActive: h.active()}
	if p.ownerDSN, err = ownerDSN(o); err != nil {
		return nil, err
	}
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	if _, ok := fileExists(inst.Bin); !ok {
		return nil, fmt.Errorf("the installed service runs %s, and there is no such file: run install without -upgrade", inst.Bin)
	}
	if p.sameBinary, err = sameContent(self, inst.Bin); err != nil {
		return nil, fmt.Errorf("comparing %s with this binary: %w", inst.Bin, err)
	}
	p.installedVer = binaryVersion(inst.Bin)
	if p.conn, p.password, err = splitPassword(p.ownerDSN); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := ownerFacts(ctx, p); err != nil {
		return nil, err
	}
	if others, err := h.others(inst.Bin); err != nil {
		return nil, fmt.Errorf("looking for other pgvigil processes: %w", err)
	} else if len(others) > 0 {
		return nil, fmt.Errorf("other processes run the installed binary (a serve, the app): stop them first, the swap would leave them on the old binary over the new schema:\n  %s", strings.Join(others, "\n  "))
	}
	if o.NoDump {
		return p, nil
	}
	if err := dumpPreflight(h, o, p, fileSafe(version)); err != nil {
		return nil, err
	}
	log.Debug("preflight done", "dump", p.dumpFile)
	return p, nil
}

// dumpPreflight finds pg_dump (not older than the server), names the dump file (default: the platform's backup folder,
// pgvigil-before-<what>-<UTC time>.dump) and checks the room for it; it makes nothing.
func dumpPreflight(h *upgradeHooks, o installOptions, p *upgradePlan, what string) error {
	var err error
	p.pgDump = o.PgDump
	if p.pgDump == "" {
		if p.pgDump, err = exec.LookPath("pg_dump"); err != nil {
			return errors.New("no pg_dump on PATH: name one with -pg-dump <path> (its major version at least the server's), or take no dump with -no-dump")
		}
	}
	if p.pgDumpMajor, err = pgDumpMajor(p.pgDump); err != nil {
		return err
	}
	if p.pgDumpMajor < p.serverMajor {
		return fmt.Errorf("%s is pg_dump %d and the repository's server is PostgreSQL %d: pg_dump refuses a server newer than itself; name a pg_dump %d or newer with -pg-dump, or take no dump with -no-dump", p.pgDump, p.pgDumpMajor, p.serverMajor, p.serverMajor)
	}
	p.dumpFile = o.Dump
	if p.dumpFile == "" {
		p.dumpFile = filepath.Join(h.dumpDir, fmt.Sprintf("pgvigil-before-%s-%s.dump", what, time.Now().UTC().Format("20060102T150405Z")))
	}
	if p.dumpFile, err = filepath.Abs(p.dumpFile); err != nil {
		return err
	}
	// only the default folder, or one this run makes, is locked down; a folder the operator named (a home, /tmp)
	// keeps its own owner and permissions and only the file is made the host owner's alone
	if dd := filepath.Dir(p.dumpFile); samePath(dd, h.dumpDir) {
		p.ownDumpDir = true
	} else if _, ok := fileExists(dd); !ok {
		p.ownDumpDir = true
	}
	if _, err := os.Stat(p.dumpFile); err == nil {
		return fmt.Errorf("the dump file %s is already there: name another with -dump", p.dumpFile)
	}
	// the room is read on the folder or, while it does not exist yet, on its nearest existing parent: the preflight
	// makes nothing (the folder is made in the dump step, after the stop)
	dir := existingParent(filepath.Dir(p.dumpFile))
	free, err := h.freeBytes(dir)
	if err != nil {
		return fmt.Errorf("free space in %s: %w", dir, err)
	}
	// a custom-format dump is compressed and smaller than the database; the database's own size is the bound taken
	if int64(free) < p.dbBytes {
		return fmt.Errorf("%s has %s free and the repository is %s: free some room or name another place with -dump", dir, humanBytes(int64(free)), humanBytes(p.dbBytes))
	}
	return nil
}

// ownerDSN is the repository owner's connection string: from -owner-dsn-file, else the variable -owner-dsn-env names.
func ownerDSN(o installOptions) (string, error) {
	if o.OwnerDSNFile != "" {
		b, err := os.ReadFile(o.OwnerDSNFile)
		if err != nil {
			return "", fmt.Errorf("-owner-dsn-file: %w", err)
		}
		line, _, _ := strings.Cut(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
		if strings.TrimSpace(line) == "" {
			return "", fmt.Errorf("-owner-dsn-file %s is empty", o.OwnerDSNFile)
		}
		return strings.TrimSpace(line), nil
	}
	if v := strings.TrimSpace(os.Getenv(o.OwnerDSNEnv)); v != "" {
		// read once and dropped: no child of this run (pg_dump, the installed binary's version) inherits the password
		_ = os.Unsetenv(o.OwnerDSNEnv)
		return v, nil
	}
	return "", fmt.Errorf("the repository owner's connection string is not given: put it in a file readable by root only and name it with -owner-dsn-file <path>, or set %s (sudo drops variables: use -owner-dsn-file or sudo --preserve-env=%s); the service's own login can neither migrate nor drop the repository (docs/upgrade.md, docs/uninstall.md)", o.OwnerDSNEnv, o.OwnerDSNEnv)
}

// ownerFacts connects as the owner: the database, the server's major version, the size, and that this login may migrate.
func ownerFacts(ctx context.Context, p *upgradePlan) error {
	c, err := pgx.Connect(ctx, p.ownerDSN)
	if err != nil {
		return fmt.Errorf("connecting with the owner's connection string: %w", err)
	}
	defer func() { _ = c.Close(context.WithoutCancel(ctx)) }()
	var num int
	var owner bool
	var hasSchema bool
	err = c.QueryRow(ctx, `SELECT current_database(), current_setting('server_version_num')::int, pg_database_size(current_database()),
	  to_regclass('pgvigil.schema_version') IS NOT NULL`).Scan(&p.database, &num, &p.dbBytes, &hasSchema)
	if err != nil {
		return fmt.Errorf("reading the repository as its owner: %w", err)
	}
	p.serverMajor = num / 10000
	if !hasSchema {
		return fmt.Errorf("the database %s holds no pgvigil schema: the owner's connection string names another database", p.database)
	}
	// the owner is the role that owns the pgvigil schema (the login that ran the first migrate), not the database's
	if err := c.QueryRow(ctx, `SELECT pg_has_role(current_user, (SELECT nspowner FROM pg_namespace WHERE nspname = 'pgvigil'), 'USAGE')
	  OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)`).Scan(&owner); err != nil {
		return err
	}
	if !owner {
		return fmt.Errorf("the owner's connection string logs in as a role that does not own the pgvigil schema in %s: name the login that ran the first 'pgvigil migrate'", p.database)
	}
	// a repository newer than this build is a downgrade: the way back of docs/upgrade.md, never this command
	latest, err := repo.LatestMigration()
	if err != nil {
		return err
	}
	var newest string
	if err := c.QueryRow(ctx, `SELECT coalesce(max(version), '') FROM pgvigil.schema_version`).Scan(&newest); err != nil {
		return err
	}
	if newest > latest {
		return fmt.Errorf("the repository holds %s, newer than this build's newest migration %s: this build is older than the installed one; going back is docs/upgrade.md's 'The way back', not an upgrade", newest, latest)
	}
	return nil
}

// upgradeDump runs pg_dump as the owner into a file made 0600 first (pg_dump writes into it and keeps its mode); the
// password goes through a temporary password file of the host's owner only, never a command line or the environment.
func upgradeDump(h *upgradeHooks, p *upgradePlan) error {
	if p.ownDumpDir {
		if err := h.secureDumpDir(filepath.Dir(p.dumpFile)); err != nil {
			return fmt.Errorf("the dump folder %s: %w", filepath.Dir(p.dumpFile), err)
		}
	}
	f, err := os.OpenFile(p.dumpFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	_ = f.Close()
	if !p.ownDumpDir {
		if err := h.secureDumpFile(p.dumpFile); err != nil {
			_ = os.Remove(p.dumpFile)
			return fmt.Errorf("the dump file %s: %w", p.dumpFile, err)
		}
	}
	cmd := exec.Command(p.pgDump, "--format=custom", "--no-password", "--file="+p.dumpFile, "--dbname="+p.conn)
	// the environment without a password libpq would take over the file (PGPASSWORD wins over PGPASSFILE)
	for _, e := range os.Environ() {
		if k, _, _ := strings.Cut(e, "="); k != "PGPASSWORD" && k != "PGPASSFILE" {
			cmd.Env = append(cmd.Env, e)
		}
	}
	if p.password != "" {
		pf, err := os.CreateTemp("", "pgvigil-pgpass-*")
		if err != nil {
			return err
		}
		name := pf.Name()
		passFile.Store(&name)
		defer func() { _ = os.Remove(name); passFile.Store(nil) }()
		_ = pf.Chmod(0o600)
		if _, err := pf.WriteString("*:*:*:*:" + pgpassEscape(p.password) + "\n"); err != nil {
			_ = pf.Close()
			return err
		}
		if err := pf.Close(); err != nil {
			return err
		}
		cmd.Env = append(cmd.Env, "PGPASSFILE="+name)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		_ = os.Remove(p.dumpFile)
		return fmt.Errorf("pg_dump: %v: %s", err, strings.TrimSpace(string(out)))
	}
	if st, err := os.Stat(p.dumpFile); err != nil || st.Size() == 0 {
		return fmt.Errorf("pg_dump wrote nothing to %s", p.dumpFile)
	}
	return nil
}

func upgradeMigrate(ctx context.Context, dsn string) (int, error) {
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		return 0, err
	}
	defer r.Close()
	return r.Migrate(ctx)
}

// wayBack is the text that takes the host back to before the upgrade; swapped: the new binary is in place.
func wayBack(p *upgradePlan, swapped bool) string {
	var b strings.Builder
	b.WriteString("The way back:\n")
	switch {
	case swapped && p.hasPrevious:
		fmt.Fprintf(&b, "  stop the service; put the previous binary back: %s over %s\n", p.previous, p.inst.Bin)
	case swapped:
		fmt.Fprintf(&b, "  stop the service; no previous binary was kept (%s was already this one): install the previous release's binary\n", p.inst.Bin)
	case p.hasPrevious:
		fmt.Fprintf(&b, "  the previous binary is kept as %s; if %s is no longer it ('pgvigil version'), put it back over it\n", p.previous, p.inst.Bin)
	default:
		fmt.Fprintf(&b, "  the binary %s was not swapped\n", p.inst.Bin)
	}
	if p.dumpFile != "" {
		fmt.Fprintf(&b, "  restore the dump as the owner into a new, empty database and make it the repository (docs/upgrade.md, 'The way back'):\n    pg_restore --exit-on-error -d <the owner's connection to the new database> %s\n", p.dumpFile)
	} else {
		b.WriteString("  no dump was taken (-no-dump): the repository cannot be put back to before the migrate\n")
	}
	b.WriteString("  then start the service.")
	return b.String()
}

// splitPassword returns a connection string without its password, and the password: a URI's user info and its password
// parameter, or a keyword / value string's password entry (libpq's quoting: single quotes, backslash escapes).
func splitPassword(dsn string) (string, string, error) {
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		u, err := url.Parse(dsn)
		if err != nil {
			return "", "", fmt.Errorf("the owner's connection string: %w", err)
		}
		var pw string
		if u.User != nil {
			if v, ok := u.User.Password(); ok {
				pw = v
			}
			u.User = url.User(u.User.Username())
		}
		q := u.Query()
		if v := q.Get("password"); v != "" {
			pw = v
		}
		q.Del("password")
		u.RawQuery = q.Encode()
		return u.String(), pw, nil
	}
	kv, err := parseConninfo(dsn)
	if err != nil {
		return "", "", err
	}
	var pw string
	var parts []string
	for _, e := range kv {
		if e[0] == "password" {
			pw = e[1]
			continue
		}
		parts = append(parts, e[0]+"="+conninfoQuote(e[1]))
	}
	return strings.Join(parts, " "), pw, nil
}

// parseConninfo splits a libpq keyword / value string into its pairs in order.
func parseConninfo(s string) ([][2]string, error) {
	var out [][2]string
	i := 0
	for {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
			i++
		}
		if i >= len(s) {
			return out, nil
		}
		j := i
		for j < len(s) && s[j] != '=' && s[j] != ' ' && s[j] != '\t' {
			j++
		}
		key := s[i:j]
		for j < len(s) && (s[j] == ' ' || s[j] == '\t') {
			j++
		}
		if j >= len(s) || s[j] != '=' || key == "" {
			return nil, fmt.Errorf("the owner's connection string: %q is not keyword=value", key)
		}
		j++
		for j < len(s) && (s[j] == ' ' || s[j] == '\t') {
			j++
		}
		var val strings.Builder
		if j < len(s) && s[j] == '\'' {
			j++
			closed := false
			for j < len(s) {
				if s[j] == '\\' && j+1 < len(s) {
					val.WriteByte(s[j+1])
					j += 2
					continue
				}
				if s[j] == '\'' {
					closed = true
					j++
					break
				}
				val.WriteByte(s[j])
				j++
			}
			if !closed {
				return nil, fmt.Errorf("the owner's connection string: an unclosed quote after %s=", key)
			}
		} else {
			for j < len(s) && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != '\r' {
				if s[j] == '\\' && j+1 < len(s) {
					val.WriteByte(s[j+1])
					j += 2
					continue
				}
				val.WriteByte(s[j])
				j++
			}
		}
		out = append(out, [2]string{key, val.String()})
		i = j
	}
}

func conninfoQuote(v string) string {
	if v != "" && !strings.ContainsAny(v, " \t'\\") {
		return v
	}
	return "'" + strings.ReplaceAll(strings.ReplaceAll(v, `\`, `\\`), `'`, `\'`) + "'"
}

// pgpassEscape escapes a password field of a password file (backslash and colon).
func pgpassEscape(v string) string {
	return strings.ReplaceAll(strings.ReplaceAll(v, `\`, `\\`), `:`, `\:`)
}

var pgDumpVersion = regexp.MustCompile(`\(PostgreSQL\)\s+(\d+)`)

func pgDumpMajor(path string) (int, error) {
	out, err := exec.Command(path, "--version").CombinedOutput()
	if err != nil {
		return 0, fmt.Errorf("%s --version: %v: %s", path, err, strings.TrimSpace(string(out)))
	}
	m := pgDumpVersion.FindSubmatch(out)
	if m == nil {
		return 0, fmt.Errorf("%s --version printed %q: not pg_dump's version line", path, strings.TrimSpace(string(out)))
	}
	return strconv.Atoi(string(m[1]))
}

// binaryVersion is the first line of '<bin> version', or what went wrong.
func binaryVersion(bin string) string {
	out, err := exec.Command(bin, "version").Output()
	if err != nil {
		return "version not read: " + err.Error()
	}
	line, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\n")
	return line
}

func sameContent(a, b string) (bool, error) {
	ha, err := fileSHA256(a)
	if err != nil {
		return false, err
	}
	hb, err := fileSHA256(b)
	if err != nil {
		return false, err
	}
	return ha == hb, nil
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// copyFileMode copies src to dst through a temporary file in dst's folder and a rename.
func copyFileMode(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".pgvigil-prev-*")
	if err != nil {
		return err
	}
	if _, err := io.Copy(tmp, in); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := os.Chmod(tmp.Name(), mode); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	if err := replaceFile(tmp.Name(), dst); err != nil {
		_ = os.Remove(tmp.Name())
		return err
	}
	return nil
}

// existingParent is dir itself when it exists, else its nearest existing parent.
func existingParent(dir string) string {
	for d := filepath.Clean(dir); ; d = filepath.Dir(d) {
		if st, err := os.Stat(d); err == nil && st.IsDir() {
			return d
		}
		if filepath.Dir(d) == d {
			return d
		}
	}
}

func samePath(a, b string) bool {
	ca, cb := filepath.Clean(a), filepath.Clean(b)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(ca, cb)
	}
	return ca == cb
}

func fileSafe(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '-' || r == '_' {
			return r
		}
		return '-'
	}, s)
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

// --- uninstall -all (docs/uninstall.md)

// removal is one thing of pgvigil on this host: what it is and where, whether it is there, and either why it stays
// (named on every run) or how it goes. The platform lists them in the order they are removed.
type removal struct {
	what    string
	present bool
	kept    string       // why it stays ("" = removed when present)
	remove  func() error // removes it (nil when absent or kept)
}

// keptErr is a removal that found its item must stay (a folder still holding other files, a group with members, a
// service marked for deletion): the item is named as kept and the run goes on.
type keptErr struct{ why string }

func (e *keptErr) Error() string { return e.why }

// foreignFiles are the names in dir that are not the installer's own (own); nil when dir is absent.
func foreignFiles(dir string, own ...string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var other []string
	for _, e := range entries {
		if !slices.Contains(own, e.Name()) {
			other = append(other, e.Name())
		}
	}
	return other
}

// credentialItems lists the page's credential folders beside the config (task 204: instances/ and sources/, the
// monitored servers' passwords) one by one with their file count; a folder that is a link (or a junction) is kept and
// named with its target, since removing the link would leave the passwords where it points. own gets the names
// removeFolder may take with the configuration folder (a kept link is not among them).
func credentialItems(cfgDir string, removeTree func(string) error) (items []removal, own []string) {
	for _, name := range []string{"instances", "sources"} {
		d := filepath.Join(cfgDir, name)
		it := removal{what: "the page's credential folder " + d}
		fi, err := os.Lstat(d)
		if err != nil {
			items = append(items, it)
			own = append(own, name)
			continue
		}
		it.present = true
		if fi.Mode().Type() != os.ModeDir {
			target, _ := os.Readlink(d)
			it.kept = "a link to " + target + ", not a folder of its own: remove the passwords there by hand, then the link"
			items = append(items, it)
			continue
		}
		n := 0
		_ = filepath.WalkDir(d, func(_ string, e fs.DirEntry, err error) error {
			if err == nil && !e.IsDir() {
				n++
			}
			return nil
		})
		it.what += fmt.Sprintf(" (%d %s: the monitored servers' passwords)", n, map[bool]string{true: "file", false: "files"}[n == 1])
		it.remove = func() error { return removeTree(d) }
		items = append(items, it)
		own = append(own, name)
	}
	return items, own
}

// removeFolder removes the installer's own files from dir, then dir; a folder that still holds anything is kept and
// named (never 'removed' while it is there).
func removeFolder(dir string, own ...string) error {
	if err := purgeFolder(slog.New(slog.DiscardHandler), dir, own...); err != nil {
		return err
	}
	if left := foreignFiles(dir); len(left) > 0 {
		return &keptErr{"it still holds " + strings.Join(left, ", ")}
	}
	return nil
}

// uninstallHooks are the platform's side of uninstall -all (Linux and Windows set them beside upgradeHooksOf).
type uninstallHooks struct {
	privileged func() error
	running    func() bool                                     // the installed service runs (stopped first, started again after a refusal)
	items      func(inst installOptions, found bool) []removal // everything after the repository, in the order removed
	// repoDSN is the repository connection string this host's installed service uses (hostRepoDSN), configured whether
	// its configuration file is there
	repoDSN func(inst installOptions) (dsn string, configured bool, err error)
	// named lists every other process running a pgvigil binary (pgvigilExe), from any path and under any name: a serve
	// run from a bundle's release asset or by go run outlives -all as surely as one on the installed binary (the
	// service's own main process and this one left out)
	named func() ([]string, error)
}

// hostRepoDSN is the repository connection string the service installed at inst resolves (serviceRepoDSN), envFile the
// unit's environment file ("" on Windows); configured says the configuration file is there.
func hostRepoDSN(inst installOptions, envFile string) (string, bool, error) {
	if _, ok := fileExists(inst.Config); !ok {
		return "", false, nil
	}
	dsn, _, err := serviceRepoDSN(inst.Config, envFile)
	return strings.TrimSpace(dsn), true, err
}

var uninstallHooksOf *uninstallHooks

// pgvigilMainPath is the main package every pgvigil binary is built from, whatever its file is called (pgvigil, a
// release asset pgvigil_<v>_linux_amd64, a renamed copy, go run's): uninstall -all's process check reads it from the
// executable's embedded build information.
const pgvigilMainPath = "github.com/aachaemenes/pgvigil/cmd/pgvigil"

// pgvigilExe says whether the executable at file is a pgvigil binary: its build information names pgvigilMainPath;
// when that cannot be read (not a Go binary, unreadable), its name is pgvigil or a release asset's pgvigil_*
// (.exe trimmed), never the app (pgvigil-app*). name is the executable's path as the system reports it.
func pgvigilExe(file, name string) bool {
	if bi, err := buildinfo.ReadFile(file); err == nil {
		return bi.Path == pgvigilMainPath
	}
	b := strings.TrimSuffix(strings.ToLower(filepath.Base(name)), ".exe")
	return b == "pgvigil" || strings.HasPrefix(b, "pgvigil_")
}

// pgvigilGroups are the group roles the migrations create (cluster-wide: uninstall -drop-repository drops them only when
// nothing else uses them).
var pgvigilGroups = []string{"pgvigil_collector", "pgvigil_reader", "pgvigil_auth", "pgvigil_alerter"}

// otherCollectorWait is how long the repository is watched for another collector's write after the local service
// stopped: the shortest collection interval is a minute.
var otherCollectorWait = 75 * time.Second

// dropPlan is everything -drop-repository read before any change.
type dropPlan struct {
	dump      *upgradePlan // the owner's connection, the database, its size and server, the dump file and pg_dump
	present   bool         // the database is there (a re-run after the drop finds the roles only)
	dbOID     int64        // -1 when the database is gone
	dbOwner   string
	maint     string // the server's maintenance database the drop runs from
	login     string // the role the owner's connection logs in as
	loginSup  bool   // that role is a superuser (not named as kept)
	hostLogin string // the login this host's configuration names
	roles     []roleStep
	sessions  []string // other sessions on the database at the preflight
}

// roleStep is one role of the cluster that the repository brought: dropped, or kept and why.
type roleStep struct {
	name  string
	login bool
	drop  bool
	why   string
}

// roleFacts are what decides a role's step (read from pg_roles, pg_auth_members, pg_shdepend, pg_stat_activity).
type roleFacts struct {
	name        string
	super       bool
	canLogin    bool
	memberOf    []string // the roles it is a member of
	usedIn      string   // the databases (or shared objects) other than the repository that record it (pg_shdepend)
	sessionsIn  string   // the databases other than the repository it has a session in
	isConnected bool     // it is the role this uninstall connects as
}

// decideGroup: a pgvigil group is dropped unless something else holds it.
func decideGroup(f roleFacts) roleStep {
	s := roleStep{name: f.name}
	var other []string
	for _, m := range f.memberOf {
		if !slices.Contains(pgvigilGroups, m) {
			other = append(other, m)
		}
	}
	switch {
	case f.super:
		s.why = "a superuser"
	case f.isConnected:
		s.why = "the role this uninstall connects as"
	case len(other) > 0:
		s.why = "a member of " + strings.Join(other, ", ")
	case f.usedIn != "":
		s.why = "used in " + f.usedIn + " (another repository or database)"
	default:
		s.drop, s.why = true, "a pgvigil group"
	}
	return s
}

// decideLogin: a member of the pgvigil groups is dropped only when it is the login this host's configuration names,
// every group it is in is dropped, and nothing else records it or has a session as it; any other is listed.
func decideLogin(f roleFacts, hostLogin string, dropped map[string]bool) roleStep {
	s := roleStep{name: f.name, login: true}
	var notDropped []string
	for _, m := range f.memberOf {
		if !dropped[m] {
			notDropped = append(notDropped, m)
		}
	}
	switch {
	case f.isConnected:
		s.why = "the role this uninstall connects as"
	case f.super:
		s.why = "a superuser"
	case f.name != hostLogin:
		s.why = "not the login this host's configuration names"
	case len(notDropped) > 0:
		s.why = "a member of " + strings.Join(notDropped, ", ") + ", which stay"
	case f.usedIn != "":
		s.why = "used in " + f.usedIn
	case f.sessionsIn != "":
		s.why = "it has a session in " + f.sessionsIn
	default:
		s.drop, s.why = true, "the login this host's configuration names"
	}
	return s
}

func runUninstallAll(log *slog.Logger, o installOptions) error {
	h, uh := upgradeHooksOf, uninstallHooksOf
	if h == nil || uh == nil {
		return errors.New("uninstall -all runs on Linux and Windows, where the installers place the collector as a service")
	}
	if err := uh.privileged(); err != nil {
		return fmt.Errorf("uninstall refused, nothing was changed: %w", err)
	}
	inst, found, err := h.installed()
	if err != nil {
		return fmt.Errorf("uninstall refused, nothing was changed: reading the installed service: %w", err)
	}
	if found {
		for _, f := range []struct{ name, flag, installed string }{{"bin", o.Bin, inst.Bin}, {"config", o.Config, inst.Config}, {"user", o.User, inst.User}} {
			if o.set[f.name] && !samePath(f.flag, f.installed) {
				return fmt.Errorf("uninstall refused, nothing was changed: -%s %s disagrees with the installed service's %s: leave the flag out", f.name, f.flag, f.installed)
			}
		}
	} else {
		inst = o
	}
	// another pgvigil process on the installed binary or its .previous (a serve started by hand or by a unit of the house,
	// the app's) would outlive the uninstall and keep writing (an Add in the page makes instances/ again): refused, as the
	// upgrade refuses it; the dry run lists them
	// and any pgvigil binary from any path or under any name (a bundle's release asset, a renamed copy, go run): each
	// pid said once
	var others []string
	addOthers := func(ps []string) {
		for _, p := range ps {
			pid, _, _ := strings.Cut(p, ":")
			if !slices.ContainsFunc(others, func(o string) bool { q, _, _ := strings.Cut(o, ":"); return q == pid }) {
				others = append(others, p)
			}
		}
	}
	for _, b := range []string{inst.Bin, h.previous(inst.Bin)} {
		ps, err := h.others(b)
		if err != nil {
			return fmt.Errorf("uninstall refused, nothing was changed: looking for other processes on %s: %w", b, err)
		}
		addOthers(ps)
	}
	if uh.named != nil {
		ps, err := uh.named()
		if err != nil {
			return fmt.Errorf("uninstall refused, nothing was changed: looking for other pgvigil processes: %w", err)
		}
		addOthers(ps)
	}
	if len(others) > 0 && !o.DryRun {
		return fmt.Errorf("uninstall refused, nothing was changed: other pgvigil processes run on this host (a serve, the app, a pgvigil from another path): stop them first:\n  %s", strings.Join(others, "\n  "))
	}
	var p *dropPlan
	if o.DropRepository {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		p, err = dropPreflight(ctx, h, uh, o, inst)
		cancel()
		if err != nil {
			return fmt.Errorf("uninstall refused, nothing was changed: %w", err)
		}
	}
	items := uh.items(inst, found)
	todo := printUninstallPlan(o, inst, uh, p, items, others)
	if o.DryRun {
		fmt.Println("dry run: nothing was changed")
		return nil
	}
	if todo == 0 {
		fmt.Println("nothing of pgvigil is left to remove")
		return nil
	}
	if p != nil && (p.present || slices.ContainsFunc(p.roles, func(r roleStep) bool { return r.drop })) {
		if err := confirmDrop(o, p.dump.database); err != nil {
			return fmt.Errorf("uninstall refused, nothing was changed: %w", err)
		}
	}
	// an install at other paths than the defaults: once the service definition is gone, a re-run needs them named
	again := ""
	if def := defaultInstallOptions(); found && (!samePath(inst.Bin, def.Bin) || !samePath(inst.Config, def.Config) || inst.User != def.User) {
		again = fmt.Sprintf(" with -bin %s -config %s -user %s", inst.Bin, inst.Config, inst.User)
	}
	var stopped atomic.Bool  // the service was stopped: read by the interrupt handler too
	var changing atomic.Bool // the drop or a removal has begun: an interrupt no longer starts the service again
	dumping := ""            // the dump file while pg_dump writes it
	var dumpMu sync.Mutex
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sig)
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-sig:
			if f := passFile.Load(); f != nil {
				_ = os.Remove(*f)
			}
			dumpMu.Lock()
			if dumping != "" {
				_ = os.Remove(dumping)
			}
			dumpMu.Unlock()
			if changing.Load() {
				fmt.Fprintf(os.Stderr, "\ninterrupted while removing: what is left is listed by 'pgvigil uninstall -all -dry-run%s'; run the same command again\n", again)
			} else if stopped.Load() {
				if err := h.start(log); err != nil {
					fmt.Fprintf(os.Stderr, "\ninterrupted before any change but the stop, and the service did not start again (%v): start it by hand\n", err)
				} else {
					fmt.Fprintln(os.Stderr, "\ninterrupted before any change but the stop: the service runs again")
				}
			}
			os.Exit(130)
		case <-done:
		}
	}()
	if uh.running() {
		if err := h.stop(log); err != nil {
			return fmt.Errorf("stopping the service: %w (nothing else was changed)", err)
		}
		stopped.Store(true)
		fmt.Println("stopped the service")
	}
	// a refusal after the stop starts the collector again: the host is as it was (but a dump already written)
	dumped := ""
	refuse := func(err error) error {
		kept := "nothing else was changed"
		if dumped != "" {
			kept = "nothing else was changed but the dump " + dumped + " (kept; a re-run takes a new one: leave -dump out or name another file)"
		}
		if stopped.Load() {
			if serr := h.start(log); serr != nil {
				return fmt.Errorf("uninstall refused (%w), and the service did not start again (%v): start it by hand; %s", err, serr, kept)
			}
			return fmt.Errorf("uninstall refused, the service runs again, %s: %w", kept, err)
		}
		return fmt.Errorf("uninstall refused, %s: %w", strings.Replace(kept, "nothing else was", "nothing was", 1), err)
	}
	if p != nil {
		if p.present {
			ctx, cancel := context.WithTimeout(context.Background(), otherCollectorWait+60*time.Second)
			err := repositoryInUse(ctx, p)
			cancel()
			if err != nil {
				return refuse(err)
			}
			if p.dump.dumpFile != "" {
				dumpMu.Lock()
				dumping = p.dump.dumpFile
				dumpMu.Unlock()
				err := upgradeDump(h, p.dump)
				dumpMu.Lock()
				dumping = ""
				dumpMu.Unlock()
				if err != nil {
					return refuse(fmt.Errorf("the dump: %w", err))
				}
				dumped = p.dump.dumpFile
				fmt.Printf("dumped the repository to %s\n", p.dump.dumpFile)
			}
		}
		changing.Store(true)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		err := dropRepository(ctx, p)
		cancel()
		if err != nil {
			if p.present && errors.Is(err, errDropNotDone) {
				changing.Store(false)
				return refuse(err)
			}
			return fmt.Errorf("%w (run the same command again%s once it is fixed)", err, again)
		}
	}
	changing.Store(true)
	for _, it := range items {
		if !it.present || it.kept != "" || it.remove == nil {
			continue
		}
		if err := it.remove(); err != nil {
			var k *keptErr
			if errors.As(err, &k) {
				fmt.Printf("kept: %s: %s\n", it.what, k.why)
				continue
			}
			return fmt.Errorf("removing %s: %w (what is left is above; run the same command again%s once it is fixed)", it.what, err, again)
		}
		fmt.Println("removed:", it.what)
	}
	for _, it := range items {
		if it.present && it.kept != "" {
			fmt.Printf("kept: %s: %s\n", it.what, it.kept)
		}
	}
	if p != nil && p.present && p.dump.dumpFile != "" {
		fmt.Printf("kept: the dump %s: yours to keep or delete\n", p.dump.dumpFile)
	}
	fmt.Println("pgvigil is uninstalled from this host")
	return nil
}

// printUninstallPlan prints every item, the repository's steps and the monitored servers' note; it returns how many
// things would change.
func printUninstallPlan(o installOptions, inst installOptions, uh *uninstallHooks, p *dropPlan, items []removal, others []string) int {
	host, _ := os.Hostname()
	if o.DryRun {
		fmt.Printf("uninstall -all on %s, dry run (nothing is changed):\n", host)
	} else {
		fmt.Printf("uninstall -all on %s:\n", host)
	}
	todo := 0
	line := func(state, what string) { fmt.Printf("  %-8s %s\n", state, what) }
	for _, ps := range others {
		line("running", ps+" (another pgvigil process: the uninstall refuses until it is stopped)")
	}
	for _, it := range items {
		switch {
		case !it.present:
			line("absent", it.what)
		case it.kept != "":
			line("kept", it.what+": "+it.kept)
		default:
			line("remove", it.what)
			todo++
		}
	}
	fmt.Println("the repository:")
	if p == nil {
		dsn, cfg, _ := uh.repoDSN(inst)
		if dsn == "" && !cfg {
			line("absent", "this host's configuration naming a repository: a repository an earlier plain -all kept is dropped by hand (docs/uninstall.md)")
		} else {
			db := "named in " + inst.Config
			if c, err := pgx.ParseConfig(dsn); dsn != "" && err == nil {
				db = fmt.Sprintf("%s on %s:%d", c.Database, c.Host, c.Port)
			}
			line("kept", "the repository database ("+db+") and the pgvigil roles: -drop-repository in this same run drops them; after a plain -all, by hand (docs/uninstall.md)")
			line("kept", "any instances added in the page (Admin > Instances): they stay active in the kept repository while their passwords go with this host's credential folders, so another collector of the repository would report them unreachable; remove them in the page first if the repository lives on")
		}
	} else {
		d := p.dump
		if p.present {
			dump := "no dump (-no-dump): no copy of it is kept"
			if d.dumpFile != "" {
				dump = fmt.Sprintf("a dump first to %s (pg_dump %d)", d.dumpFile, d.pgDumpMajor)
			}
			line("remove", fmt.Sprintf("the database %s (%s, PostgreSQL %d, owner %s), from %s: %s", d.database, humanBytes(d.dbBytes), d.serverMajor, p.dbOwner, p.maint, dump))
			todo++
			for _, s := range p.sessions {
				line("session", s+" (no session but this one may be connected at the drop; the local service stops first)")
			}
		} else {
			line("absent", "the database "+d.database)
		}
		if len(p.roles) == 0 {
			line("absent", "the pgvigil roles")
		}
		for _, r := range p.roles {
			kind := "group"
			if r.login {
				kind = "login"
			}
			if r.drop {
				line("remove", fmt.Sprintf("the %s role %s (%s)", kind, r.name, r.why))
				todo++
			} else {
				line("kept", fmt.Sprintf("the %s role %s: %s; when nothing else uses it: DROP ROLE %s;", kind, r.name, r.why, pgx.Identifier{r.name}.Sanitize()))
			}
		}
		if !p.loginSup && !slices.ContainsFunc(p.roles, func(r roleStep) bool { return r.name == p.login }) {
			line("kept", fmt.Sprintf("the login role %s: the owner's login this uninstall connects as; afterwards, from another login, when nothing else uses it: DROP ROLE %s;", p.login, pgx.Identifier{p.login}.Sanitize()))
		}
	}
	fmt.Println("the monitored servers: never touched here; their monitoring logins (pgvigil roles prints them: pgvigil_monitor, pgvigil_actions, pgvigil_explain) are dropped there by their owners")
	return todo
}

// confirmDrop: the database's name typed at a terminal, or -confirm-database with that name; anything else refuses.
func confirmDrop(o installOptions, database string) error {
	if o.set["confirm-database"] {
		if o.ConfirmDatabase != database {
			return fmt.Errorf("-confirm-database %s is not the repository database's name %s", o.ConfirmDatabase, database)
		}
		return nil
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return fmt.Errorf("-drop-repository drops the database %s: type its name at a terminal, or pass -confirm-database %s", database, database)
	}
	fmt.Printf("type the repository database's name (%s) to drop it with its roles: ", database)
	typed, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	if strings.TrimRight(typed, "\r\n") != database {
		return fmt.Errorf("the name typed is not %s", database)
	}
	return nil
}

// dropPreflight reads the repository and the roles as the owner and decides every step; it changes nothing.
func dropPreflight(ctx context.Context, h *upgradeHooks, uh *uninstallHooks, o installOptions, inst installOptions) (*dropPlan, error) {
	dsn, err := ownerDSN(o)
	if err != nil {
		return nil, err
	}
	d := &upgradePlan{ownerDSN: dsn}
	p := &dropPlan{dump: d, dbOID: -1}
	if d.conn, d.password, err = splitPassword(dsn); err != nil {
		return nil, err
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("the owner's connection string: %w", err)
	}
	d.database = cfg.Database
	if c, err := pgx.ConnectConfig(ctx, cfg); err == nil {
		p.present = true
		var num int
		var hasSchema, mayDrop bool
		err = c.QueryRow(ctx, `SELECT current_database(), current_setting('server_version_num')::int, pg_database_size(current_database()),
		  to_regclass('pgvigil.schema_version') IS NOT NULL, d.oid::int8, pg_get_userbyid(d.datdba),
		  pg_has_role(current_user, d.datdba, 'USAGE') OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
		  FROM pg_database d WHERE d.datname = current_database()`).Scan(&d.database, &num, &d.dbBytes, &hasSchema, &p.dbOID, &p.dbOwner, &mayDrop)
		_ = c.Close(context.WithoutCancel(ctx))
		if err != nil {
			return nil, fmt.Errorf("reading the repository as its owner: %w", err)
		}
		d.serverMajor = num / 10000
		if !hasSchema {
			return nil, fmt.Errorf("the database %s holds no pgvigil schema: the owner's connection string names another database", d.database)
		}
		if !mayDrop {
			return nil, fmt.Errorf("the owner's connection string logs in as a role that may not drop %s (owned by %s): name its owner's login or a superuser's", d.database, p.dbOwner)
		}
	} else if !sqlState(err, "3D000") {
		return nil, fmt.Errorf("connecting with the owner's connection string: %w", err)
	}
	mc, err := connectMaint(ctx, cfg, p)
	if err != nil {
		return nil, err
	}
	defer func() { _ = mc.Close(context.WithoutCancel(ctx)) }()
	var createRole bool
	var num int
	if err := mc.QueryRow(ctx, `SELECT current_user, rolsuper, rolcreaterole, current_setting('server_version_num')::int FROM pg_roles WHERE rolname = current_user`).Scan(&p.login, &p.loginSup, &createRole, &num); err != nil {
		return nil, err
	}
	if d.serverMajor == 0 {
		d.serverMajor = num / 10000
	}
	if !p.loginSup && !createRole {
		return nil, fmt.Errorf("the owner's login %s may not drop roles (neither CREATEROLE nor a superuser): name a login that may", p.login)
	}
	// this host's repository as its service resolves it (an env: name from the unit's env file or the service's
	// environment, a file: from its file); a configuration that resolves to nothing cannot be told from another database
	hostDSN, configured, err := uh.repoDSN(inst)
	if err != nil {
		return nil, fmt.Errorf("this host's configuration %s: %w: -drop-repository cannot tell the owner's database is this host's", inst.Config, err)
	}
	if configured && hostDSN == "" {
		return nil, fmt.Errorf("this host's configuration %s names no repository connection string the uninstall can read: -drop-repository cannot tell it is this host's database", inst.Config)
	}
	if !configured && p.present {
		// the configuration is how the uninstall knows the database is this host's: a plain -all removed it, and any
		// owner's connection string would pass (the join review w9e, finding 3)
		return nil, fmt.Errorf("this host's configuration %s is gone: -drop-repository cannot tell the owner's database is this host's; drop it by hand (docs/uninstall.md)", inst.Config)
	}
	if err := sameRepository(ctx, hostDSN, p); err != nil {
		return nil, err
	}
	if p.roles, err = planRoles(ctx, mc, p); err != nil {
		return nil, fmt.Errorf("reading the roles: %w", err)
	}
	if !p.loginSup && d.serverMajor >= 16 {
		// from PostgreSQL 16 DROP ROLE needs ADMIN OPTION on the role as well as CREATEROLE (a role a superuser made
		// gives the owner none): refused now, never after the database is gone
		for _, r := range p.roles {
			if !r.drop {
				continue
			}
			var admin bool
			if err := mc.QueryRow(ctx, `SELECT pg_has_role(current_user, $1, 'MEMBER WITH ADMIN OPTION')`, r.name).Scan(&admin); err != nil {
				return nil, err
			}
			if !admin {
				return nil, fmt.Errorf("on PostgreSQL %d DROP ROLE needs ADMIN OPTION on the role, and the owner's login %s holds none on %s: as a superuser, GRANT %s TO %s WITH ADMIN OPTION, INHERIT FALSE, SET FALSE; or name a superuser's login",
					d.serverMajor, p.login, r.name, pgx.Identifier{r.name}.Sanitize(), pgx.Identifier{p.login}.Sanitize())
			}
		}
	}
	if p.present {
		rows, err := mc.Query(ctx, `SELECT format('pid %s: %s from %s as %s', pid, coalesce(nullif(application_name, ''), '(no application name)'),
		  coalesce(client_addr::text, 'a local socket'), usename) FROM pg_stat_activity WHERE datname = $1 AND backend_type IS DISTINCT FROM 'autovacuum worker' ORDER BY pid`, d.database)
		if err != nil {
			return nil, err
		}
		if p.sessions, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
			return nil, err
		}
		if !o.NoDump {
			if err := dumpPreflight(h, o, d, "uninstall"); err != nil {
				return nil, err
			}
		}
	}
	return p, nil
}

// sameRepository holds the owner's connection to the repository this host's configuration names (hostDSN, "" when the
// configuration names none): the same database name, and, while it exists, the same database on the same server (its
// oid and the server's start time, read through both connections). It sets p.hostLogin.
func sameRepository(ctx context.Context, hostDSN string, p *dropPlan) error {
	if hostDSN == "" {
		return nil
	}
	hc, err := pgx.ParseConfig(hostDSN)
	if err != nil {
		return fmt.Errorf("this host's repository connection string: %w", err)
	}
	p.hostLogin = hc.User
	if hc.Database != p.dump.database {
		return fmt.Errorf("the owner's connection string names the database %s and this host's configuration %s: name the owner's login to this host's repository", p.dump.database, hc.Database)
	}
	if !p.present {
		return nil
	}
	ident := func(cfg *pgx.ConnConfig) (string, error) {
		c, err := pgx.ConnectConfig(ctx, cfg)
		if err != nil {
			return "", err
		}
		defer func() { _ = c.Close(context.WithoutCancel(ctx)) }()
		var id string
		err = c.QueryRow(ctx, `SELECT (SELECT oid FROM pg_database WHERE datname = current_database())::text || '@' || pg_postmaster_start_time()::text`).Scan(&id)
		return id, err
	}
	oc, err := pgx.ParseConfig(p.dump.ownerDSN)
	if err != nil {
		return err
	}
	ownerID, err := ident(oc)
	if err != nil {
		return err
	}
	hostID, err := ident(hc)
	if err != nil {
		return fmt.Errorf("this host's repository login cannot connect (%v): the drop cannot tell it is the same database; fix the configuration, or uninstall without -drop-repository and drop the repository by hand", err)
	}
	if ownerID != hostID {
		return fmt.Errorf("the owner's connection reaches another database %s than this host's configuration (%s on %s:%d): name the owner's login to this host's repository", p.dump.database, hc.Database, hc.Host, hc.Port)
	}
	return nil
}

// connectMaint connects as the owner to the server's maintenance database (postgres, else template1): DROP DATABASE
// runs from another database than the one it drops.
func connectMaint(ctx context.Context, cfg *pgx.ConnConfig, p *dropPlan) (*pgx.Conn, error) {
	var last error
	for _, db := range []string{"postgres", "template1"} {
		mc := cfg.Copy()
		mc.Database = db
		c, err := pgx.ConnectConfig(ctx, mc)
		if err == nil {
			p.maint = db
			return c, nil
		}
		last = err
	}
	return nil, fmt.Errorf("connecting as the owner to the maintenance database (postgres or template1), where the drop runs from: %w", last)
}

func sqlState(err error, code string) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == code
}

// planRoles reads the pgvigil groups and their members and decides each one's step: logins first, then the groups.
func planRoles(ctx context.Context, c *pgx.Conn, p *dropPlan) ([]roleStep, error) {
	// from PostgreSQL 16 a CREATEROLE login that creates a role is given an ADMIN-only membership of it (no inherit, no
	// SET ROLE): it uses nothing of the role, so it is no member here
	inUse := ""
	if p.dump.serverMajor >= 16 {
		inUse = " AND (m.inherit_option OR m.set_option)"
	}
	facts := func(name string) (roleFacts, bool, error) {
		f := roleFacts{name: name, isConnected: name == p.login}
		var oid int64
		err := c.QueryRow(ctx, `SELECT oid::int8, rolsuper, rolcanlogin FROM pg_roles WHERE rolname = $1`, name).Scan(&oid, &f.super, &f.canLogin)
		if errors.Is(err, pgx.ErrNoRows) {
			return f, false, nil
		}
		if err != nil {
			return f, false, err
		}
		rows, err := c.Query(ctx, `SELECT b.rolname::text FROM pg_auth_members m JOIN pg_roles b ON b.oid = m.roleid WHERE m.member = $1::oid`+inUse+` ORDER BY 1`, oid)
		if err != nil {
			return f, false, err
		}
		if f.memberOf, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
			return f, false, err
		}
		// pg_shdepend is the cluster's record of a role's grants and ownerships per database; the repository's own rows
		// (dbid = its oid, and a grant on the repository database itself) go with the drop
		err = c.QueryRow(ctx, `SELECT coalesce(string_agg(DISTINCT coalesce(d.datname::text, d0.datname::text, 'a shared object'), ', '), '')
		  FROM pg_shdepend s
		  LEFT JOIN pg_database d ON d.oid = s.dbid
		  LEFT JOIN pg_database d0 ON s.dbid = 0 AND s.classid = 'pg_database'::regclass AND d0.oid = s.objid
		  WHERE s.refclassid = 'pg_authid'::regclass AND s.refobjid = $1::oid AND s.deptype <> 'p'
		    AND s.dbid::int8 <> $2 AND NOT (s.dbid = 0 AND s.classid = 'pg_database'::regclass AND s.objid::int8 = $2)`, oid, p.dbOID).Scan(&f.usedIn)
		if err != nil {
			return f, false, err
		}
		err = c.QueryRow(ctx, `SELECT coalesce(string_agg(DISTINCT coalesce(datname::text, '(no database)'), ', '), '') FROM pg_stat_activity
		  WHERE usename = $1 AND datname IS DISTINCT FROM $2`, name, p.dump.database).Scan(&f.sessionsIn)
		return f, true, err
	}
	var groups []roleStep
	dropped := map[string]bool{}
	for _, g := range pgvigilGroups {
		f, ok, err := facts(g)
		if err != nil {
			return nil, err
		}
		if !ok {
			continue
		}
		s := decideGroup(f)
		dropped[g] = s.drop
		groups = append(groups, s)
	}
	rows, err := c.Query(ctx, `SELECT DISTINCT r.rolname::text FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member
	  JOIN pg_roles g ON g.oid = m.roleid WHERE g.rolname = ANY($1) AND NOT r.rolname = ANY($1)`+inUse+` ORDER BY 1`, pgvigilGroups)
	if err != nil {
		return nil, err
	}
	members, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	var steps []roleStep
	for _, m := range members {
		f, ok, err := facts(m)
		if err != nil {
			return nil, err
		}
		if ok {
			steps = append(steps, decideLogin(f, p.hostLogin, dropped))
		}
	}
	return append(steps, groups...), nil
}

// repositoryInUse refuses the drop while another collector writes into the repository or another session is on it:
// collection_dates' newest snapshot read now (the local service is stopped) and again otherCollectorWait later.
func repositoryInUse(ctx context.Context, p *dropPlan) error {
	c, err := pgx.Connect(ctx, p.dump.ownerDSN)
	if err != nil {
		return fmt.Errorf("connecting with the owner's connection string: %w", err)
	}
	defer func() { _ = c.Close(context.WithoutCancel(ctx)) }()
	newest := func() (string, error) {
		var s string
		err := c.QueryRow(ctx, `SELECT coalesce(max(snapshot_at)::text, '') FROM pgvigil.collection_dates`).Scan(&s)
		return s, err
	}
	before, err := newest()
	if err != nil {
		return err
	}
	fmt.Printf("watching the repository for %s: a collector on another host writes within a minute\n", otherCollectorWait)
	select {
	case <-time.After(otherCollectorWait):
	case <-ctx.Done():
		return ctx.Err()
	}
	after, err := newest()
	if err != nil {
		return err
	}
	if after != before {
		return fmt.Errorf("another collector writes into %s (collection_dates' newest snapshot moved from %s to %s while this host's service was stopped): stop it, or point it at another repository, first", p.dump.database, before, after)
	}
	rows, err := c.Query(ctx, `SELECT format('pid %s: %s from %s as %s', pid, coalesce(nullif(application_name, ''), '(no application name)'),
	  coalesce(client_addr::text, 'a local socket'), usename) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()
	  AND backend_type IS DISTINCT FROM 'autovacuum worker' ORDER BY pid`)
	if err != nil {
		return err
	}
	others, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	// every backend on the database counts but an autovacuum worker (DROP DATABASE ends those by itself); a login that
	// may not read another role's session sees its backend_type as NULL, and such a session counts too
	if len(others) > 0 {
		return fmt.Errorf("other sessions are connected to %s (a serve, Grafana, a psql): end them first; the drop never forces them off:\n  %s", p.dump.database, strings.Join(others, "\n  "))
	}
	return nil
}

// errDropNotDone marks a DROP DATABASE that did not happen: nothing but the dump has changed.
var errDropNotDone = errors.New("the database was not dropped")

// dropRepository drops the database from the maintenance database, then the roles one statement each.
func dropRepository(ctx context.Context, p *dropPlan) error {
	cfg, err := pgx.ParseConfig(p.dump.ownerDSN)
	if err != nil {
		return err
	}
	cfg.Database = p.maint
	c, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		if p.present {
			return fmt.Errorf("%w: connecting to %s: %v", errDropNotDone, p.maint, err)
		}
		return err
	}
	defer func() { _ = c.Close(context.WithoutCancel(ctx)) }()
	if p.present {
		if _, err := c.Exec(ctx, "DROP DATABASE "+pgx.Identifier{p.dump.database}.Sanitize()); err != nil {
			var pe *pgconn.PgError
			if errors.As(err, &pe) && pe.Code == "55006" {
				// someone connected after the check: name every backend on the database, whatever its kind
				var who []string
				if rows, qerr := c.Query(ctx, `SELECT format('pid %s: %s, %s from %s as %s, %s', pid, backend_type, coalesce(nullif(application_name, ''), '(no application name)'),
				  coalesce(client_addr::text, 'a local socket'), coalesce(usename::text, '(no user)'), coalesce(state, '(no state)')) FROM pg_stat_activity WHERE datname = $1 ORDER BY pid`, p.dump.database); qerr == nil {
					who, _ = pgx.CollectRows(rows, pgx.RowTo[string])
				}
				return fmt.Errorf("%w: %s (%s); on the database now: %s", errDropNotDone, pe.Message, pe.Detail, strings.Join(who, "; "))
			}
			return fmt.Errorf("%w: %v", errDropNotDone, err)
		}
		fmt.Printf("dropped the database %s\n", p.dump.database)
	}
	var failed []string
	for _, r := range p.roles {
		if !r.drop {
			continue
		}
		if _, err := c.Exec(ctx, "DROP ROLE IF EXISTS "+pgx.Identifier{r.name}.Sanitize()); err != nil {
			failed = append(failed, fmt.Sprintf("%s: %v", r.name, err))
			continue
		}
		fmt.Printf("dropped the role %s\n", r.name)
	}
	if len(failed) > 0 {
		return fmt.Errorf("roles not dropped: %s", strings.Join(failed, "; "))
	}
	return nil
}

// pathWithout is the machine PATH without dir (compared without case and a trailing backslash); found says it was there.
func pathWithout(path, dir string) (string, bool) {
	norm := func(s string) string { return strings.ToLower(strings.TrimRight(strings.TrimSpace(s), `\`)) }
	var keep []string
	found := false
	for _, e := range strings.Split(path, ";") {
		if e != "" && norm(e) == norm(dir) {
			found = true
			continue
		}
		keep = append(keep, e)
	}
	return strings.Join(keep, ";"), found
}
