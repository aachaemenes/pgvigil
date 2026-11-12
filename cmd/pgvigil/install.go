package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
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
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// pgvigil install puts the collector in place as a service and pgvigil uninstall takes the service
// away again; both are thin and re-runnable (a second install is an upgrade: the binary and the unit
// or service definition are replaced, the config is kept, a running service is restarted).
//
//	pgvigil install   [-bin <path>] [-config <path>] [-user <account>] [-no-start]
//	pgvigil install   -upgrade [-owner-dsn-file <path> | -owner-dsn-env <NAME>] [-dump <file> | -no-dump] [-pg-dump <path>]
//	pgvigil uninstall [-config <path>] [-purge]
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

	set map[string]bool // the flags named on the command line
}

func parseInstallArgs(name string, args []string, def installOptions) (installOptions, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	o := def
	fs.StringVar(&o.Bin, "bin", def.Bin, "path the binary is installed to")
	fs.StringVar(&o.Config, "config", def.Config, "path of the configuration file")
	fs.StringVar(&o.User, "user", def.User, "service account (Linux; install creates it as a system user when missing)")
	if name == "install" {
		fs.BoolVar(&o.NoStart, "no-start", false, "install and enable, but do not start the service")
		fs.BoolVar(&o.Upgrade, "upgrade", false, "upgrade the installed collector: stop, dump, migrate, swap, start (docs/upgrade.md)")
		fs.StringVar(&o.OwnerDSNEnv, "owner-dsn-env", "PGVIGIL_OWNER_DSN", "with -upgrade: the environment variable holding the repository owner's connection string")
		fs.StringVar(&o.OwnerDSNFile, "owner-dsn-file", "", "with -upgrade: a file holding the repository owner's connection string (first line)")
		fs.StringVar(&o.Dump, "dump", "", "with -upgrade: the dump file (default: "+dumpDirHint+")")
		fs.BoolVar(&o.NoDump, "no-dump", false, "with -upgrade: take no dump (the way back then has no repository copy)")
		fs.StringVar(&o.PgDump, "pg-dump", "", "with -upgrade: the pg_dump to use (default: the one on PATH)")
	} else {
		fs.BoolVar(&o.Purge, "purge", false, "also remove the installer's files, their folder when empty, and the binary")
	}
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if fs.NArg() > 0 {
		return o, fmt.Errorf("%s takes flags only, got %q", name, fs.Arg(0))
	}
	o.set = map[string]bool{}
	fs.Visit(func(f *flag.Flag) { o.set[f.Name] = true })
	switch {
	case !o.Upgrade:
		for _, n := range []string{"owner-dsn-env", "owner-dsn-file", "dump", "no-dump", "pg-dump"} {
			if o.set[n] {
				return o, fmt.Errorf("-%s goes with -upgrade only", n)
			}
		}
	case o.NoStart:
		return o, errors.New("-upgrade starts the service it stopped: -no-start does not go with it")
	case o.NoDump && (o.set["dump"] || o.set["pg-dump"]):
		return o, errors.New("-no-dump does not go with -dump or -pg-dump")
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
	return installService(log, o)
}

func runUninstall(log *slog.Logger, args []string) error {
	o, err := parseInstallArgs("uninstall", args, defaultInstallOptions())
	if err != nil {
		return err
	}
	return uninstallService(log, o)
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
var ownFiles = []string{"pgvigil.yaml", "pgvigil.env", "repo.dsn", "pgvigil.log", "logs"}

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
		log.Info("folder kept: it still holds other files", "path", dir)
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

// configReady says whether the service may start: the config loads and its repository DSN resolves to something
// (an env:NAME DSN read from envFile, the environment file the unit loads, when one is named; a file: DSN from its
// file). The instances may all be in the page (Admin > Instances, task 204), so none in the file is fine; with an
// empty DSN the collector would end with exit 3 at once.
func configReady(path, envFile string) (bool, string) {
	cfg, err := config.Load(path)
	if err != nil {
		return false, err.Error()
	}
	raw := cfg.Repository.DSNRaw
	dsn := cfg.Repository.DSN()
	if name, ok := strings.CutPrefix(raw, "env:"); ok && envFile != "" {
		if v, found := envFileValue(envFile, name); found {
			dsn = v
		}
	}
	if strings.TrimSpace(dsn) == "" {
		return false, "the repository dsn (" + raw + ") is empty yet"
	}
	return true, ""
}

// envFileValue reads NAME=value from a systemd environment file: the last assignment wins, quotes are stripped.
func envFileValue(path, name string) (string, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	v, found := "", false
	for _, l := range strings.Split(string(b), "\n") {
		k, val, ok := strings.Cut(strings.TrimSpace(l), "=")
		if ok && strings.TrimSpace(strings.TrimPrefix(k, "export ")) == name {
			v, found = strings.Trim(strings.TrimSpace(val), `"'`), true
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
	ready          func(o installOptions) (bool, string) // installService's own gate: may the service start (configReady), or why not
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
	ready, why := h.ready(inst) // the gate installService starts the service by: the repository DSN, not an instance in the file (task 204)
	if err := installService(log, inst); err != nil {
		fmt.Fprintf(os.Stderr, "the install of the new binary did not finish: %s\n", wayBack(p, false))
		return err
	}
	if ready {
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
	inst.Upgrade = true
	p := &upgradePlan{inst: inst, previous: h.previous(inst.Bin)}
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
	p.pgDump = o.PgDump
	if p.pgDump == "" {
		if p.pgDump, err = exec.LookPath("pg_dump"); err != nil {
			return nil, errors.New("no pg_dump on PATH: name one with -pg-dump <path> (its major version at least the server's), or take no dump with -no-dump")
		}
	}
	if p.pgDumpMajor, err = pgDumpMajor(p.pgDump); err != nil {
		return nil, err
	}
	if p.pgDumpMajor < p.serverMajor {
		return nil, fmt.Errorf("%s is pg_dump %d and the repository's server is PostgreSQL %d: pg_dump refuses a server newer than itself; name a pg_dump %d or newer with -pg-dump, or take no dump with -no-dump", p.pgDump, p.pgDumpMajor, p.serverMajor, p.serverMajor)
	}
	p.dumpFile = o.Dump
	if p.dumpFile == "" {
		p.dumpFile = filepath.Join(h.dumpDir, fmt.Sprintf("pgvigil-before-%s-%s.dump", fileSafe(version), time.Now().UTC().Format("20060102T150405Z")))
	}
	if p.dumpFile, err = filepath.Abs(p.dumpFile); err != nil {
		return nil, err
	}
	// only the default folder, or one this upgrade makes, is locked down; a folder the operator named (a home, /tmp)
	// keeps its own owner and permissions and only the file is made the host owner's alone
	if dd := filepath.Dir(p.dumpFile); samePath(dd, h.dumpDir) {
		p.ownDumpDir = true
	} else if _, ok := fileExists(dd); !ok {
		p.ownDumpDir = true
	}
	if _, err := os.Stat(p.dumpFile); err == nil {
		return nil, fmt.Errorf("the dump file %s is already there: name another with -dump", p.dumpFile)
	}
	// the room is read on the folder or, while it does not exist yet, on its nearest existing parent: the preflight
	// makes nothing (the folder is made in the dump step, after the stop)
	dir := existingParent(filepath.Dir(p.dumpFile))
	free, err := h.freeBytes(dir)
	if err != nil {
		return nil, fmt.Errorf("free space in %s: %w", dir, err)
	}
	// a custom-format dump is compressed and smaller than the database; the database's own size is the bound taken
	if int64(free) < p.dbBytes {
		return nil, fmt.Errorf("%s has %s free and the repository is %s: free some room or name another place with -dump", dir, humanBytes(int64(free)), humanBytes(p.dbBytes))
	}
	log.Debug("preflight done", "dump", p.dumpFile)
	return p, nil
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
	return "", fmt.Errorf("the repository owner's connection string is not given: put it in a file readable by root only and name it with -owner-dsn-file <path>, or set %s (sudo drops variables: use -owner-dsn-file or sudo --preserve-env=%s); the service's own login cannot migrate (docs/upgrade.md)", o.OwnerDSNEnv, o.OwnerDSNEnv)
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
