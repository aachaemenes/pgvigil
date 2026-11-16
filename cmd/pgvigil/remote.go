package main

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
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

// runRemote runs the collector-only mode until ctx ends.
func runRemote(ctx context.Context, log *slog.Logger, cfg *config.Config) error {
	r := cfg.Remote
	lock, err := lockStateDir(r.StateDir)
	if err != nil {
		return err
	}
	defer lock.release()
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
