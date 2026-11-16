package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// One remote collector per state folder: a second lock on the same folder is refused in words while the first holds
// it, and taken once it is released.
func TestRemoteLock(t *testing.T) {
	dir := t.TempDir()
	l1, err := lockStateDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockStateDir(dir); err == nil || !strings.Contains(err.Error(), "another remote collector") {
		t.Errorf("a second lock: %v", err)
	}
	l1.release()
	l2, err := lockStateDir(dir)
	if err != nil {
		t.Errorf("after the release: %v", err)
	} else {
		l2.release()
	}
}

// Retention without a push (R12): a finished bundle goes keep_days after it was written (its window's end); past
// remote.max_mb the oldest bundles go first until the outbox fits; a .part folder and a pushed marker's bundle are the
// push's business, never this sweep's.
func TestRemoteRetention(t *testing.T) {
	out := t.TempDir()
	mk := func(rel string, size int) {
		t.Helper()
		d := filepath.Join(out, filepath.FromSlash(rel))
		if err := os.MkdirAll(d, 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "manifest.json"), []byte("{}"), 0o640); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "v.ndjson.gz"), make([]byte, size), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	old := "site1/coll1/pg1/2026-11-01/0000000001-20261101T000500Z"
	mid := "site1/coll1/pg1/2026-11-15/0000000002-20261115T000500Z"
	newer := "site1/coll1/pg1/2026-11-16/0000000003-20261116T000500Z"
	mk(old, 1<<20)
	mk(mid, 3<<20)
	mk(newer, 3<<20)
	if err := os.MkdirAll(filepath.Join(out, "site1/coll1/pg1/2026-11-16/0000000004-20261116T001000Z.part"), 0o750); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 16, 1, 0, 0, 0, time.UTC)
	gone := sweepOutbox(out, 7, 64, now)
	if gone != 1 {
		t.Errorf("keep_days 7: %d went, want the 2026-11-01 one", gone)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(old))); !os.IsNotExist(err) {
		t.Errorf("the old bundle: %v", err)
	}
	gone = sweepOutbox(out, 7, 4, now) // 6 MB left over a 4 MB cap: the oldest goes
	if gone != 1 {
		t.Errorf("max_mb 4: %d went, want one", gone)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(mid))); !os.IsNotExist(err) {
		t.Errorf("the oldest over the cap: %v", err)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(newer))); err != nil {
		t.Errorf("the newest: %v", err)
	}
	if _, err := os.Stat(filepath.Join(out, "site1/coll1/pg1/2026-11-16/0000000004-20261116T001000Z.part")); err != nil {
		t.Errorf("a .part folder went: %v", err)
	}
}

// pgvigil remote init (the docs' line): the collector's Ed25519 key made once in the state folder (mode 0600, never
// printed), its public key printed as 'ed25519:<base64>' for the hub's keys:; a second run keeps the key and prints the
// same line; a manifest signed with it verifies with the printed key.
func TestRemoteInit(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	var out strings.Builder
	line, err := remoteInit(dir, &out)
	if err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dir, signingKeyFile))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("the key file: %v %v", fi, err)
	}
	key, err := readSigningKey(dir)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(line, "ed25519:"))
	if !strings.HasPrefix(line, "ed25519:") || err != nil || !bytes.Equal(pub, key.Public().(ed25519.PublicKey)) {
		t.Errorf("the printed line %q is not the key's public key", line)
	}
	raw, _ := os.ReadFile(filepath.Join(dir, signingKeyFile))
	if strings.Contains(out.String(), strings.TrimSpace(string(raw))) || !strings.Contains(out.String(), line) {
		t.Errorf("the output prints the private key or lacks the public line: %s", out.String())
	}
	var again strings.Builder
	line2, err := remoteInit(dir, &again)
	raw2, _ := os.ReadFile(filepath.Join(dir, signingKeyFile))
	if err != nil || line2 != line || !bytes.Equal(raw, raw2) {
		t.Errorf("a second run: %q %v (the key changed: %v)", line2, err, !bytes.Equal(raw, raw2))
	}
	man := []byte(`{"format": 1}`)
	if err := format.VerifySignature([][]byte{pub}, man, format.SignManifest(key, man)); err != nil {
		t.Errorf("a manifest signed with the key: %v", err)
	}
}

// install -remote: the remote names by default (the lead's 11:5x), -config / -user still choose; never with -upgrade.
func TestInstallRemoteArgs(t *testing.T) {
	o, err := parseInstallArgs("install", []string{"-remote"}, defaultInstallOptions())
	if err != nil || !o.Remote || o.Config != remoteConfigDefault() || o.User != remoteAccountDefault() {
		t.Errorf("-remote: %+v %v", o, err)
	}
	o, err = parseInstallArgs("install", []string{"-remote", "-config", "/srv/r.yaml", "-user", "collector"}, defaultInstallOptions())
	if err != nil || o.Config != "/srv/r.yaml" || o.User != "collector" {
		t.Errorf("-remote with -config and -user: %+v %v", o, err)
	}
	if _, err := parseInstallArgs("install", []string{"-remote", "-upgrade"}, defaultInstallOptions()); err == nil {
		t.Errorf("-remote -upgrade: no error")
	}
	if o, err := parseInstallArgs("install", nil, defaultInstallOptions()); err != nil || o.Remote || o.Config == remoteConfigDefault() {
		t.Errorf("no -remote: %+v %v", o, err)
	}
}

// The remote sample config the installer writes is not ready until its site and an instance are filled in (the service
// is enabled, not started); a filled one is ready.
func TestRemoteReady(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "pgvigil-remote.yaml")
	if err := os.WriteFile(p, []byte(remoteConfigTemplate(filepath.Join(dir, "outbox"), filepath.Join(dir, "state"))), 0o640); err != nil {
		t.Fatal(err)
	}
	if ready, why := remoteReady(p); ready || why == "" {
		t.Errorf("the sample: ready %v (%s)", ready, why)
	}
	filled := strings.Replace(remoteConfigTemplate(filepath.Join(dir, "outbox"), filepath.Join(dir, "state")), `site: ""`, `site: plant1`, 1)
	filled = strings.Replace(filled, `collector: ""`, `collector: box1`, 1)
	filled = strings.Replace(filled, "instances: []", "instances:\n  - name: pg1\n    dsn: host=127.0.0.1 user=pgvigil dbname=postgres", 1)
	if err := os.WriteFile(p, []byte(filled), 0o640); err != nil {
		t.Fatal(err)
	}
	if ready, why := remoteReady(p); !ready {
		t.Errorf("a filled config: not ready (%s)", why)
	}
}

// A remote collector's service log goes into its state folder - the one place besides the outbox it may write (R2) -
// as pgvigil-remote.log; a config without a remote: block keeps the hub's log place (ok false).
func TestRemoteServiceLog(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "pgvigil-remote.yaml")
	cfg := strings.Replace(remoteConfigTemplate(filepath.Join(dir, "outbox"), filepath.Join(dir, "state")), `site: ""`, `site: plant1`, 1)
	cfg = strings.Replace(cfg, `collector: ""`, `collector: box1`, 1)
	if err := os.WriteFile(p, []byte(cfg), 0o640); err != nil {
		t.Fatal(err)
	}
	if got, ok := remoteServiceLog(p); !ok || got != filepath.Join(dir, "state", "pgvigil-remote.log") {
		t.Errorf("the remote log: %q %v", got, ok)
	}
	hub := filepath.Join(dir, "pgvigil.yaml")
	if err := os.WriteFile(hub, []byte("repository:\n  dsn: host=x\ninstances: []\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, ok := remoteServiceLog(hub); ok {
		t.Errorf("a hub config took the remote log place")
	}
}

// THE WIRING (task 15, W's lines): `pgvigil run` with a remote: block goes to the remote collector (here with no
// instance and a context already ended: it takes the lock, writes its state, closes nothing and returns), never to the
// repository's 'dsn resolves to nothing'; `pgvigil remote init` is dispatched; `pgvigil remote` alone is usage (2).
func TestRemoteWiring(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "pgvigil-remote.yaml")
	cfg := strings.Replace(remoteConfigTemplate(filepath.Join(dir, "outbox"), filepath.Join(dir, "state")), `site: ""`, `site: plant1`, 1)
	cfg = strings.Replace(cfg, `collector: ""`, `collector: box1`, 1)
	if err := os.WriteFile(p, []byte(cfg), 0o640); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := runScheduler(ctx, slog.New(slog.NewTextHandler(io.Discard, nil)), []string{"-config", p}); err != nil {
		t.Fatalf("run with a remote: block: %v", err)
	}
	for _, f := range []string{"pgvigil.lock", "state.json"} {
		if _, err := os.Stat(filepath.Join(dir, "state", f)); err != nil {
			t.Errorf("the remote run left no %s: %v", f, err)
		}
	}
	if code := run([]string{"remote", "init", "-config", p}); code != 0 {
		t.Errorf("remote init through the dispatch: exit %d", code)
	}
	if _, err := os.Stat(filepath.Join(dir, "state", signingKeyFile)); err != nil {
		t.Errorf("remote init made no key: %v", err)
	}
	if code := run([]string{"remote"}); code != 2 {
		t.Errorf("remote with no subcommand: exit %d, want 2", code)
	}
}
