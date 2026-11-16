package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
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
	// its own binary (the lead's 12:2x, the 11:5x rule for the binary too): never the hub's, so install -remote leaves
	// a hub collector's binary on the same box as it was
	o, _ = parseInstallArgs("install", []string{"-remote"}, defaultInstallOptions())
	if o.Bin == defaultInstallOptions().Bin || !strings.Contains(o.Bin, "pgvigil-remote") {
		t.Errorf("install -remote installs to %s, the hub's binary is %s", o.Bin, defaultInstallOptions().Bin)
	}
	if o, err := parseInstallArgs("install", []string{"-remote", "-bin", "/opt/r/pgvigil"}, defaultInstallOptions()); err != nil || o.Bin != "/opt/r/pgvigil" {
		t.Errorf("-remote with -bin: %+v %v", o, err)
	}
}

// uninstall -remote [-purge [-force]] (the lead's 12:2x): the remote names by default, its own binary; -force goes with
// -remote -purge only; -remote is not -all's.
func TestUninstallRemoteArgs(t *testing.T) {
	o, err := parseInstallArgs("uninstall", []string{"-remote", "-purge"}, defaultInstallOptions())
	if err != nil || !o.Remote || !o.Purge || o.Force || o.Config != remoteConfigDefault() || o.User != remoteAccountDefault() || o.Bin == defaultInstallOptions().Bin {
		t.Errorf("uninstall -remote -purge: %+v %v", o, err)
	}
	if o, err := parseInstallArgs("uninstall", []string{"-remote", "-purge", "-force"}, defaultInstallOptions()); err != nil || !o.Force {
		t.Errorf("uninstall -remote -purge -force: %+v %v", o, err)
	}
	for _, bad := range [][]string{{"-force"}, {"-remote", "-force"}, {"-purge", "-force"}, {"-remote", "-all"}, {"-remote", "-all", "-dry-run"}} {
		if _, err := parseInstallArgs("uninstall", bad, defaultInstallOptions()); err == nil {
			t.Errorf("uninstall %v: no error", bad)
		}
	}
}

// -purge leaves no empty /var/lib/pgvigil-remote behind: the two folders' parent goes when it is named pgvigil-remote
// and empty; a parent of another name, or one still holding a file, stays.
func TestRemoveRemoteParent(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	root := t.TempDir()
	own := filepath.Join(root, "pgvigil-remote")
	if err := os.MkdirAll(own, 0o755); err != nil {
		t.Fatal(err)
	}
	removeRemoteParent(log, filepath.Join(own, "outbox"), filepath.Join(own, "state"))
	if _, err := os.Stat(own); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the empty pgvigil-remote parent is still there (%v)", err)
	}
	other := filepath.Join(root, "data")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	removeRemoteParent(log, filepath.Join(other, "outbox"), filepath.Join(other, "state"))
	if _, err := os.Stat(other); err != nil {
		t.Errorf("a parent of another name went: %v", err)
	}
	held := filepath.Join(root, "x", "pgvigil-remote")
	if err := os.MkdirAll(held, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(held, "keep.me"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	removeRemoteParent(log, filepath.Join(held, "outbox"), filepath.Join(held, "state"))
	if _, err := os.Stat(filepath.Join(held, "keep.me")); err != nil {
		t.Errorf("a pgvigil-remote parent holding a file lost it: %v", err)
	}
}

// uninstall -remote -purge refuses while the outbox holds a bundle not pushed - the collector cannot know whether the
// site's transfer carried it - naming the count, the newest window end and the loss; -force passes; a pushed bundle
// counts as carried.
func TestRemotePurgeGuard(t *testing.T) {
	dir := t.TempDir()
	outbox, state := filepath.Join(dir, "outbox"), filepath.Join(dir, "state")
	p := filepath.Join(dir, "pgvigil-remote.yaml")
	cfg := strings.Replace(remoteConfigTemplate(outbox, state), `site: ""`, `site: plant1`, 1)
	cfg = strings.Replace(cfg, `collector: ""`, `collector: box1`, 1)
	if err := os.WriteFile(p, []byte(cfg), 0o640); err != nil {
		t.Fatal(err)
	}
	o := installOptions{Config: p, Remote: true, Purge: true}
	if err := remotePurgeGuard(o); err != nil {
		t.Errorf("an empty outbox: %v", err)
	}
	end := time.Date(2026, 11, 16, 10, 5, 0, 0, time.UTC)
	b := filepath.Join(outbox, filepath.FromSlash(format.Ref{Site: "plant1", Collector: "box1", InstanceKey: format.InstanceKey("SQL01"), Seq: 7, End: end}.Dir()))
	if err := os.MkdirAll(b, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(b, format.ManifestFile), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := remotePurgeGuard(o)
	for _, want := range []string{"1 bundle", "2026-11-16 10:05:00 UTC", "lost", "-force"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("a bundle not pushed: want %q in %v", want, err)
		}
	}
	o.Force = true
	if err := remotePurgeGuard(o); err != nil {
		t.Errorf("-force: %v", err)
	}
	o.Force = false
	if err := os.WriteFile(b+".pushed", []byte(end.Format(time.RFC3339)), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := remotePurgeGuard(o); err != nil {
		t.Errorf("a pushed bundle only: %v", err)
	}
}

// install -remote again over a new binary (the upgrade path -remote -upgrade's refusal names) finds its folder as the
// first install left it: Linux /etc/pgvigil-remote with the env file, Windows ProgramData\pgvigil-remote with the outbox
// and the state folder inside, and a site's own dsn file (docs/remote-collector.md's sample) - the folder is the
// remote installer's own, as a folder named pgvigil is the hub installer's. A folder of another name stays refused.
func TestRemoteInstallAgain(t *testing.T) {
	root := t.TempDir()
	own := filepath.Join(root, "pgvigil-remote")
	for _, d := range []string{"outbox", "state"} {
		if err := os.MkdirAll(filepath.Join(own, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"pgvigil-remote.yaml", "pgvigil-remote.env", "pg-orders.dsn"} {
		if err := os.WriteFile(filepath.Join(own, f), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := dedicatedFolderOwn(own, "pgvigil-remote.yaml", "pgvigil-remote"); err != nil {
		t.Errorf("install -remote again over the first install's folder: %v", err)
	}
	// each installer takes only its own folder's name (W review S3): the hub's install never takes the remote's
	// folder (it would chown it to the hub's account), the remote's never the hub's
	if err := dedicatedFolder(own, "pgvigil.yaml"); err == nil || !strings.Contains(err.Error(), "holds other files") {
		t.Errorf("the hub's installer took the remote's folder: %v", err)
	}
	hubDir := filepath.Join(root, "pgvigil")
	if err := os.MkdirAll(hubDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hubDir, "pgvigil.env"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := dedicatedFolderOwn(hubDir, "pgvigil-remote.yaml", "pgvigil-remote"); err == nil || !strings.Contains(err.Error(), "holds other files") {
		t.Errorf("the remote's installer took the hub's folder: %v", err)
	}
	other := filepath.Join(root, "srv")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(other, "hosts"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := dedicatedFolderOwn(other, "pgvigil-remote.yaml", "pgvigil-remote"); err == nil || !strings.Contains(err.Error(), "hosts") {
		t.Errorf("a shared folder was accepted for the remote config: %v", err)
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

// fakeRemoteOps stands in for the service manager: its stop may write a bundle (the collector's final close at
// shutdown), every step is recorded.
type fakeRemoteOps struct {
	calls  []string
	onStop func()
}

func (f *fakeRemoteOps) use(t *testing.T) *bytes.Buffer {
	t.Helper()
	saved, savedOut := remoteOps, remoteOut
	remoteOps = remoteServiceOps{
		stop: func(*slog.Logger) (bool, error) {
			f.calls = append(f.calls, "stop")
			if f.onStop != nil {
				f.onStop()
			}
			return true, nil
		},
		start:  func(*slog.Logger) error { f.calls = append(f.calls, "start"); return nil },
		remove: func(_ *slog.Logger, account string) error { f.calls = append(f.calls, "remove "+account); return nil },
	}
	var out bytes.Buffer
	remoteOut = &out
	t.Cleanup(func() { remoteOps, remoteOut = saved, savedOut })
	return &out
}

func remotePurgeConfig(t *testing.T, dir string) (cfgPath, outbox string) {
	t.Helper()
	outbox = filepath.Join(dir, "outbox")
	cfgPath = filepath.Join(dir, "pgvigil-remote.yaml")
	cfg := strings.Replace(remoteConfigTemplate(outbox, filepath.Join(dir, "state")), `site: ""`, `site: plant1`, 1)
	cfg = strings.Replace(cfg, `collector: ""`, `collector: box1`, 1)
	if err := os.WriteFile(cfgPath, []byte(cfg), 0o640); err != nil {
		t.Fatal(err)
	}
	return cfgPath, outbox
}

func putRemoteBundle(t *testing.T, outbox string, seq uint64, pushed bool) {
	t.Helper()
	end := time.Date(2026, 11, 16, 10, 0, 0, 0, time.UTC).Add(time.Duration(seq) * 5 * time.Minute)
	b := filepath.Join(outbox, filepath.FromSlash(format.Ref{Site: "plant1", Collector: "box1", InstanceKey: format.InstanceKey("SQL01"), Seq: seq, End: end}.Dir()))
	if err := os.MkdirAll(b, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(b, format.ManifestFile), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if pushed {
		if err := os.WriteFile(b+".pushed", []byte(end.Format(time.RFC3339)), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

// W review B1: the stop writes a bundle (the collector's final close is never pushed), so the guard counts after the
// stop: every earlier bundle pushed, the final one not -> plain -purge refuses, starts the service again and removes
// nothing; -force removes it and says so; a plain -purge with nothing unsent says nothing of -force.
func TestUninstallRemoteGuardAfterStop(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	dir := t.TempDir()
	p, outbox := remotePurgeConfig(t, dir)
	putRemoteBundle(t, outbox, 1, true)
	f := &fakeRemoteOps{onStop: func() { putRemoteBundle(t, outbox, 2, false) }}
	out := f.use(t)
	o := installOptions{Remote: true, Purge: true, Config: p, Bin: filepath.Join(dir, "bin", "pgvigil-remote"), User: "pgvigil-remote"}
	err := uninstallRemote(log, o)
	if err == nil || !strings.Contains(err.Error(), "1 bundle(s) not pushed") {
		t.Errorf("the final bundle written by the stop: %v", err)
	}
	if strings.Join(f.calls, ",") != "stop,start" {
		t.Errorf("steps %v (want stop, start: nothing removed)", f.calls)
	}
	if _, err := os.Stat(p); err != nil {
		t.Errorf("the refusal removed the config: %v", err)
	}
	f.calls = nil
	o.Force = true
	if err := uninstallRemote(log, o); err != nil {
		t.Errorf("-force: %v", err)
	}
	if strings.Join(f.calls, ",") != "stop,remove pgvigil-remote" {
		t.Errorf("-force steps %v", f.calls)
	}
	if !strings.Contains(out.String(), "removed with -force: 1 bundle(s)") {
		t.Errorf("-force did not name the bundle: %q", out.String())
	}
	dir2 := t.TempDir()
	p2, outbox2 := remotePurgeConfig(t, dir2)
	putRemoteBundle(t, outbox2, 1, true)
	f2 := &fakeRemoteOps{}
	out2 := f2.use(t)
	if err := uninstallRemote(log, installOptions{Remote: true, Purge: true, Config: p2, Bin: filepath.Join(dir2, "pgvigil-remote"), User: "pgvigil-remote"}); err != nil {
		t.Errorf("a pushed-only outbox: %v", err)
	}
	if strings.Contains(out2.String(), "-force") {
		t.Errorf("a plain -purge spoke of -force: %q", out2.String())
	}
}

// W review B2 / S2: -purge removes only what is the remote's - never with the hub's config or binary, never on a
// config that is gone, cannot be read or has no remote: block (the folders would be guessed); nothing is touched.
func TestUninstallRemotePurgeRefusesWhatIsNotItsOwn(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	dir := t.TempDir()
	p, _ := remotePurgeConfig(t, dir)
	broken := filepath.Join(dir, "broken", "pgvigil-remote.yaml")
	hubish := filepath.Join(dir, "hubish", "pgvigil-remote.yaml")
	for _, f := range []struct{ path, body string }{{broken, "remote: [\n"}, {hubish, "instances: []\n"}} {
		if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f.path, []byte(f.body), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	hub := defaultInstallOptions()
	bin := filepath.Join(dir, "pgvigil-remote")
	for _, c := range []struct{ name, cfg, bin, want string }{
		{"the hub's config", hub.Config, bin, "the hub's"},
		{"the hub's binary", p, hub.Bin, "the hub's"},
		{"a config that is gone", filepath.Join(dir, "none.yaml"), bin, "cannot be read"},
		{"a config that does not load", broken, bin, "cannot be read"},
		{"a config with no remote: block", hubish, bin, "no remote: block"},
	} {
		f := &fakeRemoteOps{}
		f.use(t)
		err := uninstallRemote(log, installOptions{Remote: true, Purge: true, Config: c.cfg, Bin: c.bin, User: "pgvigil-remote"})
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want %q in %v", c.name, c.want, err)
		}
		if len(f.calls) != 0 {
			t.Errorf("%s: the service was touched: %v", c.name, f.calls)
		}
	}
	if _, err := os.Stat(p); err != nil {
		t.Errorf("a refusal removed a config: %v", err)
	}
}
