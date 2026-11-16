package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/remote"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
	"github.com/aachaemenes/pgvigil/internal/repo"
	"github.com/aachaemenes/pgvigil/internal/sched"
)

// The remote collector's run (R1, task 6): `pgvigil run` with a remote: block and no repository. It writes only its
// outbox and its state folder (a read-only root file system is enough: the Kubernetes pod of phase 2), exits non-zero
// on a fatal error, and holds the state folder's lock while it runs.

const signingKeyFile = "signing.key"

// stateLock is a remote collector's hold on its state folder: one collector per folder.
type stateLock struct{ f *os.File }

func (l *stateLock) release() {
	if l != nil && l.f != nil {
		unlockFile(l.f)
		_ = l.f.Close()
	}
}

func lockStateDir(dir string) (*stateLock, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("remote.state_dir %s: %w", dir, err)
	}
	f, err := os.OpenFile(filepath.Join(dir, "pgvigil.lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("remote.state_dir %s: %w", dir, err)
	}
	if err := lockFile(f); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("remote.state_dir %s: another remote collector holds it (%v) - one collector per state folder", dir, err)
	}
	return &stateLock{f: f}, nil
}

// checkRemoteFolders holds install --remote's two folders to the unit's rules: absolute, two different folders, and on
// Linux never under /home (ProtectHome=yes hides it from the service).
func checkRemoteFolders(outbox, stateDir string) error {
	for _, d := range []string{outbox, stateDir} {
		if !filepath.IsAbs(d) {
			return fmt.Errorf("remote.outbox and remote.state_dir must be absolute paths for the service (got %q)", d)
		}
		if runtime.GOOS == "linux" && (d == "/home" || strings.HasPrefix(filepath.Clean(d), "/home/")) {
			return fmt.Errorf("%s is under /home, which the service cannot see (ProtectHome=yes): put the outbox and the state folder under /var/lib", d)
		}
	}
	if filepath.Clean(outbox) == filepath.Clean(stateDir) {
		return fmt.Errorf("remote.outbox and remote.state_dir must be two folders (both %s)", outbox)
	}
	return nil
}

// remoteConfigTemplate is the remote collector's first config (the installer writes it when there is none): no
// repository, a remote: block whose site and collector the site fills in, no instance yet - the service is enabled and
// waits until they are filled in (remoteReady).
func remoteConfigTemplate(outbox, stateDir string) string {
	return fmt.Sprintf(`# pgvigil remote collector: writes interval bundles of its instances for a pgvigil hub (docs/remote-collector.md).
# No repository here: fill in remote.site and remote.collector (the hub's remote_sites: names them) and list the instances.
remote:
  site: ""          # this site's name on the hub: a-z 0-9 _ . - (up to 63)
  collector: ""     # this box's name within the site
  interval: 5m      # how long a bundle covers (1m to 60m)
  outbox: %q
  state_dir: %q
  keep_days: 7      # a bundle is kept this long after it was pushed (or written, without a push)
  max_mb: 2048      # the outbox's cap: past it the oldest bundle goes first, logged ERROR
  sign: false       # true: each manifest signed with this box's key (pgvigil remote init)
query_text: hash    # hash (a statement's fingerprint) or none: no statement text leaves this box
instances: []
`, outbox, stateDir)
}

// remoteReady says whether a remote collector's config can run: it loads, has its remote: block with a site and a
// collector, and lists an instance.
func remoteReady(path string) (bool, string) {
	cfg, err := config.Load(path)
	switch {
	case err != nil:
		return false, err.Error()
	case cfg.Remote == nil:
		return false, path + " has no remote: block"
	case cfg.Remote.Site == "" || cfg.Remote.Collector == "":
		return false, "remote.site and remote.collector are not set yet in " + path
	case len(cfg.Instances) == 0:
		return false, "no instance is listed yet in " + path
	}
	return true, ""
}

// remoteServiceLog is where a remote collector's service writes its log when no terminal takes stderr (Windows): its
// state folder, the one place besides the outbox it may write (R2); ok false for a config without a remote: block.
func remoteServiceLog(cfgPath string) (string, bool) {
	cfg, err := config.Load(cfgPath)
	if err != nil || cfg.Remote == nil || cfg.Remote.StateDir == "" {
		return "", false
	}
	return filepath.Join(cfg.Remote.StateDir, "pgvigil-remote.log"), true
}

// remoteFolders are a remote collector's outbox and state folder: its config's remote: block, else the install's
// defaults (env: and file: values stay unresolved in Load, so a shell without the service's environment reads them).
func remoteFolders(cfgPath string) (outbox, stateDir string) {
	if cfg, err := config.Load(cfgPath); err == nil && cfg.Remote != nil && cfg.Remote.Outbox != "" && cfg.Remote.StateDir != "" {
		return cfg.Remote.Outbox, cfg.Remote.StateDir
	}
	return remoteFolderDefaults()
}

// remotePurgeGuard is uninstall -remote -purge's refusal while the outbox holds bundles not pushed (the lead's 12:2x):
// the collector cannot know whether the site's own transfer carried them; -force removes them too. Nothing is changed
// when it refuses.
func remotePurgeGuard(o installOptions) error {
	if !o.Purge || o.Force {
		return nil
	}
	outbox, _ := remoteFolders(o.Config)
	if outbox == "" {
		return nil
	}
	n, newest, err := remote.OutboxHolds(outbox)
	if err != nil {
		return fmt.Errorf("uninstall -remote -purge: the outbox %s cannot be read (%v): nothing was removed", outbox, err)
	}
	if n == 0 {
		return nil
	}
	return fmt.Errorf("uninstall -remote -purge: the outbox %s holds %d bundle(s) not pushed, the newest ending %s: a bundle not yet carried to the hub is lost - let the site's transfer carry them first, or give -force to remove them too; nothing was removed",
		outbox, n, newest.UTC().Format("2006-01-02 15:04:05 UTC"))
}

// removeRemoteParent removes the outbox's and the state folder's shared parent once both are gone, only when it is
// named pgvigil-remote and empty (Linux's /var/lib/pgvigil-remote; on Windows the parent is the config folder, which
// purgeFolder handles); any other parent is never touched.
func removeRemoteParent(log *slog.Logger, outbox, stateDir string) {
	parent := filepath.Dir(filepath.Clean(outbox))
	if parent != filepath.Dir(filepath.Clean(stateDir)) || filepath.Base(parent) != "pgvigil-remote" {
		return
	}
	if err := os.Remove(parent); err == nil { // only an empty folder goes
		log.Info("removed", "folder", parent)
	}
}

// uninstallRemote is `pgvigil uninstall -remote [-purge [-force]]` (the lead's 12:2x): the remote collector's service
// stopped and removed - never the hub's; with -purge its outbox, its state folder, its config folder's own files and
// its binary, each folder removed once empty and anything else in them kept and named.
func uninstallRemote(log *slog.Logger, o installOptions) error {
	outbox, stateDir := remoteFolders(o.Config)
	held, _, _ := remote.OutboxHolds(outbox)
	if err := remotePurgeGuard(o); err != nil {
		return err
	}
	if err := removeRemoteService(log); err != nil {
		return err
	}
	cfgDir := filepath.Dir(o.Config)
	if !o.Purge {
		fmt.Printf("the remote collector's service is gone; kept: %s, %s, %s and %s (uninstall -remote -purge removes them).\n", cfgDir, outbox, stateDir, o.Bin)
		return nil
	}
	if outbox != "" {
		n, kept, err := remote.PurgeOutbox(outbox)
		if err != nil {
			return fmt.Errorf("the outbox %s: %w", outbox, err)
		}
		if held > 0 {
			fmt.Printf("removed with -force: %d bundle(s) not pushed (a bundle not yet carried to the hub is lost)\n", held)
		}
		log.Info("outbox purged", "path", outbox, "bundles", n)
		for _, k := range kept {
			fmt.Printf("kept, not the collector's: %s\n", k)
		}
	}
	if stateDir != "" {
		kept, err := remote.PurgeState(stateDir)
		if err != nil {
			return fmt.Errorf("the state folder %s: %w", stateDir, err)
		}
		log.Info("state folder purged", "path", stateDir)
		for _, k := range kept {
			fmt.Printf("kept, not the collector's: %s\n", filepath.Join(stateDir, k))
		}
	}
	if outbox != "" && stateDir != "" {
		removeRemoteParent(log, outbox, stateDir)
	}
	base := filepath.Base(o.Config)
	if err := purgeFolder(log, cfgDir, base, strings.TrimSuffix(base, filepath.Ext(base))+".env"); err != nil {
		return err
	}
	if err := os.Remove(o.Bin); err != nil && !errors.Is(err, os.ErrNotExist) {
		fmt.Printf("%s could not be removed (%v): delete it by hand once this process has exited.\n", o.Bin, err)
	} else {
		log.Info("removed", "binary", o.Bin)
		if runtime.GOOS == "windows" { // its own folder under Program Files; never a shared bin folder
			if err := os.Remove(filepath.Dir(o.Bin)); err != nil && !errors.Is(err, os.ErrNotExist) {
				log.Info("folder kept: it still holds other files", "path", filepath.Dir(o.Bin))
			}
		}
	}
	return nil
}

func sweepOutbox(outbox string, keepDays, maxMB int, now time.Time) int {
	aged, capped := remote.SweepOutbox(outbox, keepDays, maxMB, now)
	return aged + capped
}

// readSigningKey reads the collector's Ed25519 key (pgvigil remote init: the 64-byte private key in hex, mode 0600).
func readSigningKey(stateDir string) (ed25519.PrivateKey, error) {
	b, err := os.ReadFile(filepath.Join(stateDir, signingKeyFile))
	if err != nil {
		return nil, fmt.Errorf("remote.sign: the signing key: %w (make it with pgvigil remote init)", err)
	}
	k, err := hex.DecodeString(strings.TrimSpace(string(b)))
	if err != nil || len(k) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("remote.sign: %s is not an Ed25519 private key", filepath.Join(stateDir, signingKeyFile))
	}
	return ed25519.PrivateKey(k), nil
}

// remoteInit makes the collector's Ed25519 signing key in its state folder once (the 64-byte private key in hex, mode
// 0600, never printed) and prints its public key as the hub's remote_sites keys: take it, 'ed25519:<base64>'; a key
// already there is kept and its public key printed again. It returns that line.
func remoteInit(stateDir string, out io.Writer) (string, error) {
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return "", fmt.Errorf("remote.state_dir %s: %w", stateDir, err)
	}
	path := filepath.Join(stateDir, signingKeyFile)
	key, err := readSigningKey(stateDir)
	made := false
	if err != nil {
		if _, statErr := os.Stat(path); statErr == nil {
			return "", err // a file there that is no key: never overwritten
		}
		if _, key, err = ed25519.GenerateKey(rand.Reader); err != nil {
			return "", err
		}
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return "", fmt.Errorf("the signing key %s: %w", path, err)
		}
		if _, err := f.WriteString(hex.EncodeToString(key) + "\n"); err != nil {
			_ = f.Close()
			return "", err
		}
		if err := f.Sync(); err != nil {
			_ = f.Close()
			return "", err
		}
		if err := f.Close(); err != nil {
			return "", err
		}
		made = true
	}
	line := "ed25519:" + base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))
	if made {
		fmt.Fprintf(out, "made the signing key %s (mode 0600; keep it on this box only)\n", path)
	} else {
		fmt.Fprintf(out, "the signing key %s is kept as it is\n", path)
	}
	fmt.Fprintf(out, "its public key, for the hub's remote_sites: collectors: keys: and remote.sign: true here:\n%s\n", line)
	return line, nil
}

// runRemoteInit is `pgvigil remote init -config <file>`: the signing key of the file's remote: block (its dispatch line
// in main.go is task 15's WIRING).
func runRemoteInit(args []string) error {
	cfg, _, err := loadConfig(args, false)
	if err != nil {
		return err
	}
	if cfg.Remote == nil {
		return &configError{fmt.Errorf("pgvigil remote init: the config has no remote: block")}
	}
	_, err = remoteInit(cfg.Remote.StateDir, os.Stdout)
	return err
}

// runRemote runs the collector-only mode until ctx ends.
func runRemote(ctx context.Context, log *slog.Logger, cfg *config.Config) error {
	r := cfg.Remote
	lock, err := lockStateDir(r.StateDir)
	if err != nil {
		return err
	}
	defer lock.release()
	// a first start (or one after the outbox was emptied by hand) makes the outbox; the lock made the state folder
	if err := os.MkdirAll(r.Outbox, 0o750); err != nil {
		return fmt.Errorf("remote.outbox %s: %w", r.Outbox, err)
	}
	st, fresh, err := remote.LoadState(r.StateDir)
	if err != nil {
		return err
	}
	if n, err := st.Recover(r.Outbox, r.Site, r.Collector); err != nil {
		return err
	} else if n > 0 {
		log.Info("remote: bundles finished before a stop committed from their manifests", "bundles", n)
	}
	if n, err := remote.CleanParts(r.Outbox); err != nil {
		return err
	} else if n > 0 {
		log.Info("remote: unfinished bundles removed (their intervals are read again)", "bundles", n)
	}
	var key ed25519.PrivateKey
	if r.Sign {
		if key, err = readSigningKey(r.StateDir); err != nil {
			return &configError{err}
		}
	}
	level, err := repo.LatestMigration()
	if err != nil {
		return err
	}
	s := remote.NewStore(st, remote.StoreOptions{Outbox: r.Outbox, Site: r.Site, Collector: r.Collector, QueryText: cfg.QueryText,
		PgvigilVersion: version, SchemaLevel: level, Key: key, Interval: r.Interval.Duration})
	var push *remote.Pusher
	if r.Push != nil {
		if push, err = remote.NewPusher(*r.Push, r.Outbox, r.KeepDays); err != nil {
			return &configError{err}
		}
	}
	host, _ := os.Hostname()
	started := time.Now()
	log.Info("remote collector started", "site", r.Site, "collector", r.Collector, "instances", len(cfg.Instances), "interval", r.Interval.Duration,
		"outbox", r.Outbox, "fresh_state", fresh, "push", push != nil)
	closeAt := func(end time.Time, final bool) {
		open := map[string]bool{}
		for _, n := range s.OpenInstances() {
			open[n] = true
		}
		hb := format.Heartbeat{Host: host, Started: started, At: end, Instances: len(cfg.Instances)}
		for _, in := range cfg.Instances {
			if final && !open[in.Name] {
				continue
			}
			if _, err := s.CloseInstance(in.Name, end, sched.RemoteSchedule(cfg, in), hb); err != nil {
				log.Error("remote: a bundle not closed (its interval is read again)", "instance", in.Name, "err", err)
			}
		}
		if push != nil && !final {
			if n, err := push.Round(ctx, end); err != nil {
				log.Error("remote push: stopped (the next interval tries again)", "pushed", n, "err", err)
			} else if n > 0 {
				log.Info("remote push", "bundles", n, "to", push.String())
			}
			push.Prune(end)
		}
		if aged, capped := remote.SweepOutbox(r.Outbox, r.KeepDays, r.MaxMB, end); capped > 0 {
			log.Error("remote outbox: over remote.max_mb, the oldest bundles removed (the hub sees the gap)", "removed", capped, "max_mb", r.MaxMB)
		} else if aged > 0 {
			log.Info("remote outbox: bundles past remote.keep_days removed", "removed", aged)
		}
	}
	return sched.RunRemote(ctx, log, s, cfg, r.Interval.Duration, closeAt)
}
