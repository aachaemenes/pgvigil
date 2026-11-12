//go:build linux

package main

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	unitPath = "/etc/systemd/system/pgvigil.service"
	envName  = "pgvigil.env"
)

func defaultInstallOptions() installOptions {
	return installOptions{Bin: "/usr/local/bin/pgvigil", Config: "/etc/pgvigil/pgvigil.yaml", User: "pgvigil"}
}

// renderUnit is the systemd unit for the given paths and account (its primary group is the group;
// no Group= line, which would name a group that need not exist). The collector writes nothing on the
// host (its logs go to the journal through stderr), so the file system is read only to it. Exit 3 is
// a configuration error (no instance named yet): systemd does not restart on it, so a host that boots
// before its config is written fails once instead of looping.
func renderUnit(bin, cfg, envFile, account string) string {
	return fmt.Sprintf(`[Unit]
Description=pgvigil PostgreSQL monitoring collector
Documentation=https://github.com/aachaemenes/pgvigil
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%[4]s
EnvironmentFile=%[3]s
ExecStart=%[1]s run -config %[2]s
Restart=on-failure
RestartSec=10s
RestartPreventExitStatus=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
DevicePolicy=closed
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
RemoveIPC=yes
UMask=0077
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged

[Install]
WantedBy=multi-user.target
`, bin, cfg, envFile, account)
}

const envTemplate = `# Environment of the pgvigil service (read by systemd, never by a shell: no quotes needed, no expansion).
# The repository login of the collector: 'pgvigil roles' prints its CREATE ROLE; the owner runs migrate.
PGVIGIL_REPO_DSN=
# One line per monitored instance named in pgvigil.yaml as env:NAME, for example:
# PROD_WRITER_DSN=host=db.example.internal port=5432 user=pgvigil dbname=postgres sslmode=require
`

func systemdRunning() bool {
	st, err := os.Stat("/run/systemd/system")
	return err == nil && st.IsDir()
}

func systemctl(args ...string) (string, error) {
	var out bytes.Buffer
	cmd := exec.Command("systemctl", args...)
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

// ensureAccount looks the service account up and creates it as a system user without a home or a
// login shell when missing (useradd, else busybox adduser). It returns its uid and gid.
func ensureAccount(log *slog.Logger, name string) (int, int, error) {
	u, err := user.Lookup(name)
	if err != nil {
		var unknown user.UnknownUserError
		if !errors.As(err, &unknown) {
			return 0, 0, err
		}
		// a static binary's user.Lookup reads /etc/passwd only; an account served by LDAP or SSSD is
		// found through id (NSS) before anything is created
		if uidOut, e1 := exec.Command("id", "-u", name).Output(); e1 == nil {
			if gidOut, e2 := exec.Command("id", "-g", name).Output(); e2 == nil {
				uid, e3 := strconv.Atoi(strings.TrimSpace(string(uidOut)))
				gid, e4 := strconv.Atoi(strings.TrimSpace(string(gidOut)))
				if e3 == nil && e4 == nil {
					log.Info("service account found through the name service", "user", name)
					return uid, gid, nil
				}
			}
		}
		var out []byte
		if _, lookErr := exec.LookPath("useradd"); lookErr == nil {
			out, err = exec.Command("useradd", "--system", "--no-create-home", "--user-group", "--shell", "/usr/sbin/nologin", name).CombinedOutput()
		} else if _, lookErr := exec.LookPath("adduser"); lookErr == nil {
			out, err = exec.Command("adduser", "-S", "-D", "-H", "-s", "/sbin/nologin", name).CombinedOutput()
		} else {
			return 0, 0, fmt.Errorf("no useradd or adduser on this system: create the account %q (a system user, no login) and run install again, or name an existing one with -user", name)
		}
		if err != nil {
			return 0, 0, fmt.Errorf("creating the account %q: %v: %s", name, err, strings.TrimSpace(string(out)))
		}
		log.Info("service account created", "user", name)
		if u, err = user.Lookup(name); err != nil {
			return 0, 0, err
		}
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return 0, 0, err
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return 0, 0, err
	}
	return uid, gid, nil
}

func installService(log *slog.Logger, o installOptions) error {
	if os.Geteuid() != 0 {
		return errors.New("install needs root: run it with sudo")
	}
	_, gid, err := ensureAccount(log, o.User)
	if err != nil {
		return err
	}
	if err := installBinary(log, o.Bin); err != nil {
		return err
	}
	cfgDir := filepath.Dir(o.Config)
	envFile := filepath.Join(cfgDir, envName)
	if err := dedicatedFolder(cfgDir, filepath.Base(o.Config)); err != nil {
		return err
	}
	if err := os.MkdirAll(cfgDir, 0o750); err != nil {
		return err
	}
	if err := os.Chown(cfgDir, 0, gid); err != nil {
		return fmt.Errorf("chown %s: %w", cfgDir, err)
	}
	if err := os.Chmod(cfgDir, 0o750); err != nil {
		return err
	}
	for _, f := range []struct{ path, content string }{{o.Config, configTemplate("env:PGVIGIL_REPO_DSN")}, {envFile, envTemplate}} {
		wrote, err := writeIfAbsent(f.path, f.content, 0o640)
		if err != nil {
			return err
		}
		if err := os.Chown(f.path, 0, gid); err != nil {
			return fmt.Errorf("chown %s: %w", f.path, err)
		}
		if wrote {
			log.Info("written", "path", f.path)
		} else {
			log.Info("kept", "path", f.path)
		}
	}
	if err := writeFile(unitPath, renderUnit(o.Bin, o.Config, envFile, o.User), 0o644); err != nil {
		return err
	}
	log.Info("unit written", "path", unitPath)
	if !systemdRunning() {
		fmt.Printf("systemd is not running here: the unit is written; start the collector with\n  %s run -config %s\nafter editing %s and %s.\n", o.Bin, o.Config, o.Config, envFile)
		return nil
	}
	if out, err := systemctl("daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %v: %s", err, out)
	}
	if out, err := systemctl("enable", "pgvigil.service"); err != nil {
		return fmt.Errorf("systemctl enable: %v: %s", err, out)
	}
	ready, why := configReady(o.Config, envFile)
	if o.NoStart || !ready {
		if !ready {
			log.Info("service enabled, not started", "why", why)
		}
		if state, _ := systemctl("is-active", "pgvigil.service"); state == "active" {
			fmt.Printf("pgvigil is upgraded and enabled; the running service still runs the previous binary until: systemctl restart pgvigil\n")
			return nil
		}
		fmt.Printf("pgvigil is installed and enabled. Next:\n  1. %s: the repository login in PGVIGIL_REPO_DSN (and one line per instance the config names by env:)\n  2. %s: list the instances, or add them later in the page (Admin > Instances)\n  3. systemctl start pgvigil && systemctl status pgvigil (or run this installer again)\n", envFile, o.Config)
		return nil
	}
	restarted := time.Now()
	if out, err := systemctl("restart", "pgvigil.service"); err != nil {
		return fmt.Errorf("systemctl restart: %v: %s", err, out)
	}
	// Type=simple reads 'active' from the exec on, so a start that fails in its first seconds (the repository's
	// schema behind this binary, a refused repository login) still looks up at a first glance: the unit counts as
	// running only after it stayed active for upSettle; a start that failed is named with its reason
	up := true
	for waited := time.Duration(0); waited < upSettle; waited += upStep {
		time.Sleep(upStep)
		if state, _ := systemctl("is-active", "pgvigil.service"); state != "active" {
			up = false
			break
		}
	}
	if up {
		fmt.Printf("pgvigil is installed and running (systemctl status pgvigil; journalctl -u pgvigil -f).\n")
		return nil
	}
	journal := func() string {
		out, _ := exec.Command("journalctl", "-u", "pgvigil.service", "--no-pager", "-o", "cat", "-n", "20",
			"--since", restarted.Add(-time.Second).Format("2006-01-02 15:04:05")).CombinedOutput()
		return string(out)
	}
	msg, known := startFailure(journal())
	if !known {
		// journald takes the process's last line in on its own clock: the unit's state can be seen before that line
		time.Sleep(time.Second)
		msg, known = startFailure(journal())
	}
	if !known {
		// an unknown reason: the unit's own last lines, readable, above the one-line error
		out, _ := systemctl("status", "--no-pager", "-n", "10", "pgvigil.service")
		fmt.Fprintf(os.Stderr, "%s\n", out)
	}
	return errors.New(msg)
}

const (
	upSettle = 4 * time.Second // how long the unit must stay active before the installer calls it running
	upStep   = 500 * time.Millisecond
)

// schemaBehind is the line 'pgvigil run' ends with when the repository's schema is older than the binary (main.go).
var schemaBehind = regexp.MustCompile(`repository schema is behind this binary \(needs ([^)\s]+)\)`)

// startFailure turns the unit's last journal lines into the installer's one-line error. The one start failure an
// upgrade meets by design is the schema behind the new binary (the installer ran before 'pgvigil migrate'): that
// one is said in full, with what is already done and the one command left; any other is pointed at the journal.
func startFailure(journal string) (msg string, known bool) {
	if m := schemaBehind.FindStringSubmatch(journal); m != nil {
		return "the service did not come up: the repository schema is behind this binary (needs " + m[1] +
			"). The binary and the service are installed; run 'pgvigil migrate' as the repository owner and the service starts by itself (systemd retries it every 10 s)", true
	}
	return "the service did not come up (its status is above; the reason is in: journalctl -u pgvigil -n 50)", false
}

func uninstallService(log *slog.Logger, o installOptions) error {
	if os.Geteuid() != 0 {
		return errors.New("uninstall needs root: run it with sudo")
	}
	if systemdRunning() {
		if out, err := systemctl("disable", "--now", "pgvigil.service"); err != nil {
			log.Warn("systemctl disable --now", "err", err, "out", out)
		}
	}
	if err := os.Remove(unitPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	log.Info("unit removed", "path", unitPath)
	if systemdRunning() {
		_, _ = systemctl("daemon-reload")
		_, _ = systemctl("reset-failed", "pgvigil.service")
	}
	if o.Purge {
		if err := purgeFolder(log, filepath.Dir(o.Config), filepath.Base(o.Config), envName); err != nil {
			return err
		}
		if err := os.Remove(o.Bin); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		log.Info("removed", "binary", o.Bin)
	} else {
		fmt.Printf("the service is gone; %s and %s are kept (pgvigil uninstall -purge removes them).\n", filepath.Dir(o.Config), o.Bin)
	}
	fmt.Printf("the account %s is kept; remove it with: userdel %s\n", o.User, o.User)
	return nil
}

// maybeRunAsService: Linux services are plain processes under systemd; nothing to wrap.
func maybeRunAsService(_ []string) (bool, int) { return false, 0 }

// replaceFile renames tmp over dst (atomic on one file system).
func replaceFile(tmp, dst string) error { return os.Rename(tmp, dst) }

// writeFile replaces path with content (mode on creation); used for the unit the installer owns.
func writeFile(path, content string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), mode)
}

// --- install -upgrade on Linux (install.go's runUpgrade)

func init() {
	upgradeHooksOf = &upgradeHooks{
		installed:     installedUnit,
		stop:          func(_ *slog.Logger) error { return systemdStop() },
		start:         func(_ *slog.Logger) error { return systemdStart() },
		others:        otherProcesses,
		freeBytes:     freeBytes,
		dumpDir:       "/var/backups/pgvigil",
		secureDumpDir: secureDir,
		// a file in the operator's own folder: made 0600 by the upgrade before pg_dump writes into it, nothing more
		secureDumpFile: func(string) error { return nil },
		privileged: func() error {
			if os.Geteuid() != 0 {
				return errors.New("the upgrade needs root (it stops the service, writes beside the binary and the unit): run it with sudo")
			}
			return nil
		},
		previous: func(bin string) string { return bin + ".previous" },
		ready: func(o installOptions) (bool, string) {
			return configReady(o.Config, filepath.Join(filepath.Dir(o.Config), envName))
		},
	}
}

// installedUnit reads the binary, the config and the account from the unit the installer wrote (renderUnit's
// ExecStart=<bin> run -config <config> and User=<account>).
func installedUnit() (installOptions, bool, error) {
	b, err := os.ReadFile(unitPath)
	if errors.Is(err, os.ErrNotExist) {
		return installOptions{}, false, nil
	}
	if err != nil {
		return installOptions{}, false, err
	}
	return parseUnit(string(b))
}

func parseUnit(unit string) (installOptions, bool, error) {
	var o installOptions
	for _, line := range strings.Split(unit, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch k {
		case "User":
			o.User = strings.TrimSpace(v)
		case "ExecStart":
			f := strings.Fields(v)
			if len(f) >= 4 && f[1] == "run" && f[2] == "-config" {
				o.Bin, o.Config = f[0], f[3]
			}
		}
	}
	if o.Bin == "" || o.Config == "" {
		return o, false, fmt.Errorf("%s has no ExecStart=<binary> run -config <file> line: not the installer's unit", unitPath)
	}
	if o.User == "" {
		return o, false, fmt.Errorf("%s has no User= line: not the installer's unit", unitPath)
	}
	return o, true, nil
}

func systemdStop() error {
	if !systemdRunning() {
		return errors.New("systemd is not running here: stop the collector by hand and run the upgrade's steps of docs/upgrade.md")
	}
	if out, err := systemctl("stop", "pgvigil.service"); err != nil {
		return fmt.Errorf("systemctl stop: %v: %s", err, out)
	}
	if state, _ := systemctl("is-active", "pgvigil.service"); state == "active" || state == "deactivating" {
		return fmt.Errorf("the service is still %s after systemctl stop", state)
	}
	return nil
}

func systemdStart() error {
	if out, err := systemctl("start", "pgvigil.service"); err != nil {
		return fmt.Errorf("systemctl start: %v: %s", err, out)
	}
	return nil
}

// otherProcesses lists the processes whose executable is bin, but the service's own main process and this one.
func otherProcesses(bin string) ([]string, error) {
	want, err := filepath.EvalSymlinks(bin)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	mainPID := 0
	if v, err := systemctl("show", "-p", "MainPID", "--value", "pgvigil.service"); err == nil {
		mainPID, _ = strconv.Atoi(strings.TrimSpace(v))
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == os.Getpid() || pid == mainPID {
			continue
		}
		exe, err := os.Readlink(filepath.Join("/proc", e.Name(), "exe"))
		if err != nil || strings.TrimSuffix(exe, " (deleted)") != want {
			continue
		}
		cmd, _ := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline"))
		out = append(out, fmt.Sprintf("pid %d: %s", pid, strings.TrimSpace(strings.ReplaceAll(string(cmd), "\x00", " "))))
	}
	return out, nil
}

func freeBytes(dir string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return st.Bavail * uint64(st.Bsize), nil
}

// secureDir makes dir (and its missing parents) and leaves dir itself to root alone: 0700, root's.
func secureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chown(dir, 0, 0); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}
