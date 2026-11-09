package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// pgvigil install puts the collector in place as a service and pgvigil uninstall takes the service
// away again; both are thin and re-runnable (a second install is an upgrade: the binary and the unit
// or service definition are replaced, the config is kept, a running service is restarted).
//
//	pgvigil install   [-bin <path>] [-config <path>] [-user <account>] [-no-start]
//	pgvigil uninstall [-config <path>] [-purge]
//
// Linux: the binary to -bin (default /usr/local/bin/pgvigil), the config template to -config (default
// /etc/pgvigil/pgvigil.yaml) with /etc/pgvigil/pgvigil.env beside it for PGVIGIL_REPO_DSN, a system
// account (default pgvigil, created when missing), a systemd unit /etc/systemd/system/pgvigil.service
// enabled and started once the config names an instance. Windows: the binary to %ProgramFiles%\pgvigil,
// the config and repo.dsn under %ProgramData%\pgvigil (readable by SYSTEM, Administrators and the
// service's own virtual account NT SERVICE\pgvigil only), the service pgvigil (automatic start, restart
// on failure) started once the config names an instance. Other systems: the binary and the config only.
// Nothing here touches a monitored server or the repository: migrate, roles and user stay separate
// commands run by the repository owner.

// installOptions are the flags of install and uninstall after the platform defaults are applied.
type installOptions struct {
	Bin     string // where the binary lives when installed
	Config  string // the config file
	User    string // the service account (Linux: a system user; Windows: fixed to the virtual account)
	NoStart bool   // write everything, start nothing
	Purge   bool   // uninstall: remove the config folder and the binary too
}

func parseInstallArgs(name string, args []string, def installOptions) (installOptions, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	o := def
	fs.StringVar(&o.Bin, "bin", def.Bin, "path the binary is installed to")
	fs.StringVar(&o.Config, "config", def.Config, "path of the configuration file")
	fs.StringVar(&o.User, "user", def.User, "service account (Linux; install creates it as a system user when missing)")
	if name == "install" {
		fs.BoolVar(&o.NoStart, "no-start", false, "install and enable, but do not start the service")
	} else {
		fs.BoolVar(&o.Purge, "purge", false, "also remove the installer's files, their folder when empty, and the binary")
	}
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if fs.NArg() > 0 {
		return o, fmt.Errorf("%s takes flags only, got %q", name, fs.Arg(0))
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

// configNamesAnInstance says whether the config at path loads and lists at least one instance: the
// service is started only then (a fresh template lists none, and the collector would refuse it).
func configNamesAnInstance(path string) (bool, string) {
	cfg, err := config.Load(path)
	if err != nil {
		return false, err.Error()
	}
	if len(cfg.Instances) == 0 {
		return false, "the config lists no instance yet"
	}
	return true, ""
}

// configTemplate is the first config of an installed collector: the repository DSN comes from the
// environment (Linux: the env file beside it) or a file (Windows: repo.dsn beside it), the instance
// list is empty and the service waits until one is added.
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

# The service starts collecting once this list names an instance. Each dsn is env:NAME or file:/path;
# the login is a pg_monitor member ('pgvigil roles' prints its CREATE ROLE).
instances: []
#  - name: prod-writer
#    dsn: env:PROD_WRITER_DSN
#    platform: auto                   # auto | onprem | rds | aurora | azure | cloudsql | alloydb
#    tags: [prod]
`, "@DSN@", repositoryDSN)
}
