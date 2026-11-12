package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// install takes flags only; uninstall knows -purge, install knows -no-start and -user.
func TestParseInstallArgs(t *testing.T) {
	def := installOptions{Bin: "/b", Config: "/c", User: "u"}
	o, err := parseInstallArgs("install", []string{"-no-start", "-config", "/x/p.yaml"}, def)
	if err != nil || !o.NoStart || o.Config != "/x/p.yaml" || o.Bin != "/b" || o.User != "u" {
		t.Fatalf("install flags: %+v %v", o, err)
	}
	if _, err := parseInstallArgs("install", []string{"extra"}, def); err == nil || !strings.Contains(err.Error(), "flags only") {
		t.Fatalf("a positional argument was accepted: %v", err)
	}
	if _, err := parseInstallArgs("install", []string{"-user", ""}, def); err == nil {
		t.Fatal("an empty -user was accepted")
	}
	o, err = parseInstallArgs("uninstall", []string{"-purge"}, def)
	if err != nil || !o.Purge {
		t.Fatalf("uninstall -purge: %+v %v", o, err)
	}
	if _, err := parseInstallArgs("uninstall", []string{"-no-start"}, def); err == nil {
		t.Fatal("uninstall accepted -no-start")
	}
}

// The template the installer writes is a valid config with no instance and an env: repository DSN: the installer
// keeps the service down until that DSN is filled in (the instances may all be in the page, task 204), and a second
// install never overwrites an edited file.
func TestConfigTemplate(t *testing.T) {
	dir := t.TempDir()
	p, env := filepath.Join(dir, "pgvigil.yaml"), filepath.Join(dir, "pgvigil.env")
	wrote, err := writeIfAbsent(p, configTemplate("env:PGVIGIL_REPO_DSN"), 0o640)
	if err != nil || !wrote {
		t.Fatalf("first write: %v %v", wrote, err)
	}
	t.Setenv("PGVIGIL_REPO_DSN", "")
	if err := os.WriteFile(env, []byte("PGVIGIL_REPO_DSN=\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if ok, why := configReady(p, env); ok || !strings.Contains(why, "is empty yet") {
		t.Fatalf("template: ok=%v why=%q, want not ready (the DSN is empty)", ok, why)
	}
	if err := os.WriteFile(env, []byte("# the repository\nPGVIGIL_REPO_DSN=\"host=r dbname=pgvigil\"\nOTHER=x\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if ok, why := configReady(p, env); !ok {
		t.Fatalf("the env file filled in, no instance in the config: %q (want ready)", why)
	}
	// the env file decides, not the installer's own environment; its last assignment wins
	t.Setenv("PGVIGIL_REPO_DSN", "host=from-the-shell")
	if err := os.WriteFile(env, []byte("PGVIGIL_REPO_DSN=y\nPGVIGIL_REPO_DSN=\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if ok, _ := configReady(p, env); ok {
		t.Fatal("an emptied PGVIGIL_REPO_DSN in the env file counted as ready (the shell's value or an earlier line won)")
	}
	t.Setenv("PGVIGIL_REPO_DSN", "")
	// a file: DSN (the Windows install's repo.dsn beside the config)
	dsnFile := filepath.Join(dir, "repo.dsn")
	if err := os.WriteFile(dsnFile, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	q := filepath.Join(dir, "win.yaml")
	if err := os.WriteFile(q, []byte("repository:\n  dsn: file:"+dsnFile+"\ninstances: []\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if ok, _ := configReady(q, ""); ok {
		t.Fatal("an empty repo.dsn counted as ready")
	}
	if err := os.WriteFile(dsnFile, []byte("host=r dbname=pgvigil\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if ok, why := configReady(q, ""); !ok {
		t.Fatalf("repo.dsn filled in: %q", why)
	}
	if wrote, err := writeIfAbsent(p, "overwritten", 0o640); err != nil || wrote {
		t.Fatalf("second write replaced the file: %v %v", wrote, err)
	}
	if ok, why := configReady(filepath.Join(t.TempDir(), "missing.yaml"), ""); ok || why == "" {
		t.Fatal("a missing config counted as ready")
	}
}

// The installer owns the config's folder (permissions, -purge), so it takes a folder named pgvigil, a
// folder that does not exist yet, or one holding only its own files; anything else is refused.
func TestDedicatedFolder(t *testing.T) {
	root := t.TempDir()
	if err := dedicatedFolder(filepath.Join(root, "etc", "pgvigil"), "pgvigil.yaml"); err != nil {
		t.Errorf("a folder named pgvigil: %v", err)
	}
	if err := dedicatedFolder(filepath.Join(root, "missing"), "pgvigil.yaml"); err != nil {
		t.Errorf("a folder that does not exist yet: %v", err)
	}
	own := filepath.Join(root, "own")
	for _, f := range []string{"pgvigil.yaml", "pgvigil.env", "repo.dsn"} {
		if err := os.WriteFile(filepath.Join(own, f), nil, 0o600); err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatal(err)
		} else if err != nil {
			_ = os.MkdirAll(own, 0o755)
			if err := os.WriteFile(filepath.Join(own, f), nil, 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := dedicatedFolder(own, "pgvigil.yaml"); err != nil {
		t.Errorf("a folder holding only the installer's files: %v", err)
	}
	if err := os.WriteFile(filepath.Join(own, "hosts"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := dedicatedFolder(own, "pgvigil.yaml"); err == nil || !strings.Contains(err.Error(), "hosts") {
		t.Errorf("a shared folder was accepted: %v", err)
	}
}

// A configuration-shape failure exits 3 (the unit's RestartPreventExitStatus), a runtime failure 1.
func TestConfigErrorExitCode(t *testing.T) {
	_, _, err := loadConfig([]string{"-config", filepath.Join(t.TempDir(), "none.yaml")}, false)
	var ec interface{ ExitCode() int }
	if err == nil || !errors.As(err, &ec) || ec.ExitCode() != 3 {
		t.Fatalf("a missing config: %v (want a configError with exit code 3)", err)
	}
	if code := run([]string{"run", "-config", filepath.Join(t.TempDir(), "none.yaml")}); code != 3 {
		t.Fatalf("run with a missing config exited %d, want 3", code)
	}
}

// The repository connection string is resolved as the installed service resolves it (review w9d findings 1 and M3): an
// env: name from the unit's env file only (a name it lacks is empty, whatever the installer's own shell holds), else the
// service's own environment and then the machine's, never this process's; a file: from its file; a literal as written.
func TestServiceRepoDSN(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	envCfg := write("env.yaml", "repository:\n  dsn: env:PGV_REPO\ninstances: []\n")
	envFile := write("pgvigil.env", "PGVIGIL_REPO_DSN=host=a dbname=pgvigil\n")
	t.Setenv("PGV_REPO", "host=from-the-shell dbname=other")
	if dsn, raw, err := serviceRepoDSN(envCfg, envFile); err != nil || dsn != "" || raw != "env:PGV_REPO" {
		t.Errorf("a name the env file lacks: %q %q %v (want empty: the service never sees the installer's shell)", dsn, raw, err)
	}
	write("pgvigil.env", "PGV_REPO=\"host=b dbname=pgvigil\"\n")
	if dsn, _, _ := serviceRepoDSN(envCfg, envFile); dsn != "host=b dbname=pgvigil" {
		t.Errorf("the env file's value: %q", dsn)
	}
	dsnFile := write("repo.dsn", "host=c dbname=pgvigil_test\r\n")
	fileCfg := write("file.yaml", "repository:\n  dsn: file:"+dsnFile+"\ninstances: []\n")
	if dsn, _, _ := serviceRepoDSN(fileCfg, envFile); dsn != "host=c dbname=pgvigil_test" {
		t.Errorf("a file: DSN: %q", dsn)
	}
	litCfg := write("lit.yaml", "repository:\n  dsn: host=d dbname=pgvigil\ninstances: []\n")
	if dsn, _, _ := serviceRepoDSN(litCfg, ""); dsn != "host=d dbname=pgvigil" {
		t.Errorf("a literal DSN: %q", dsn)
	}
	// Windows' order: the service's registry Environment, then the machine environment, never the process's
	oldSvc, oldMachine := serviceEnv, machineEnvValue
	defer func() { serviceEnv, machineEnvValue = oldSvc, oldMachine }()
	svcVals, machineVals := map[string]string{}, map[string]string{}
	serviceEnv = func(n string) (string, bool) { v, ok := svcVals[n]; return v, ok }
	machineEnvValue = func(n string) (string, bool) { v, ok := machineVals[n]; return v, ok }
	if dsn, _, _ := serviceRepoDSN(envCfg, ""); dsn != "" {
		t.Errorf("neither the service's nor the machine's environment names it: %q (want empty, not the shell's)", dsn)
	}
	machineVals["PGV_REPO"] = "host=m dbname=pgvigil"
	if dsn, _, _ := serviceRepoDSN(envCfg, ""); dsn != "host=m dbname=pgvigil" {
		t.Errorf("the machine environment: %q", dsn)
	}
	svcVals["PGV_REPO"] = "host=s dbname=pgvigil"
	if dsn, _, _ := serviceRepoDSN(envCfg, ""); dsn != "host=s dbname=pgvigil" {
		t.Errorf("the service's own environment first: %q", dsn)
	}
	// no service environment on the platform: the process's own, as the binary run by hand
	serviceEnv, machineEnvValue = nil, nil
	if dsn, _, _ := serviceRepoDSN(envCfg, ""); dsn != "host=from-the-shell dbname=other" {
		t.Errorf("no service environment: %q", dsn)
	}
	if _, _, err := serviceRepoDSN(filepath.Join(dir, "missing.yaml"), ""); err == nil {
		t.Error("a missing config resolved")
	}
	if dsn, configured, err := hostRepoDSN(installOptions{Config: filepath.Join(dir, "missing.yaml")}, ""); dsn != "" || configured || err != nil {
		t.Errorf("hostRepoDSN of a missing config: %q %v %v", dsn, configured, err)
	}
	if dsn, configured, err := hostRepoDSN(installOptions{Config: envCfg}, envFile); dsn != "host=b dbname=pgvigil" || !configured || err != nil {
		t.Errorf("hostRepoDSN: %q %v %v", dsn, configured, err)
	}
}

// envFileValue: the last assignment wins; a value wholly in one pair of quotes loses them, a quote inside or at one end
// stays (the cases of 203's envValue test, review w9d M10).
func TestEnvFileValue(t *testing.T) {
	f := filepath.Join(t.TempDir(), "pgvigil.env")
	body := "# the repository\nPGVIGIL_REPO_DSN=\nPGVIGIL_OTHER=x\nPGVIGIL_REPO_DSN=host=127.0.0.1 port=5432 user=pgvigil_agent password='a b' dbname=pgvigil\n" +
		"Q=\"quoted value\"\nS='single'\nEND=host=x password='p w'\nexport E=exported\n"
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{
		"PGVIGIL_REPO_DSN": "host=127.0.0.1 port=5432 user=pgvigil_agent password='a b' dbname=pgvigil",
		"Q":                "quoted value",
		"S":                "single",
		"END":              "host=x password='p w'",
		"E":                "exported",
	} {
		if v, found := envFileValue(f, name); !found || v != want {
			t.Errorf("%s: %q (found %v), want %q", name, v, found, want)
		}
	}
	if v, found := envFileValue(f, "MISSING"); found || v != "" {
		t.Errorf("a missing name: %q %v", v, found)
	}
	if v, found := envFileValue(filepath.Join(t.TempDir(), "none"), "PGVIGIL_REPO_DSN"); found || v != "" {
		t.Errorf("a missing file: %q %v", v, found)
	}
}

// The page's credential folders are listed one by one with their file count; an absent one says so; a link is kept and
// named with its target, and the configuration folder's own list leaves it out (review w9d M6).
func TestCredentialItems(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "instances", "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"instances/a.dsn", "instances/sub/b.dsn"} {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	var removed []string
	items, own := credentialItems(dir, func(d string) error { removed = append(removed, filepath.Base(d)); return nil })
	if len(items) != 2 || !items[0].present || items[0].what != "the page's credential folder "+filepath.Join(dir, "instances")+" (2 files: the monitored servers' passwords)" ||
		items[1].present || items[1].what != "the page's credential folder "+filepath.Join(dir, "sources") || strings.Join(own, ",") != "instances,sources" {
		t.Fatalf("items %+v own %v", items, own)
	}
	if err := items[0].remove(); err != nil || strings.Join(removed, ",") != "instances" {
		t.Fatalf("remove: %v %v", err, removed)
	}
	target := t.TempDir()
	if err := os.Symlink(target, filepath.Join(dir, "sources")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	items, own = credentialItems(dir, func(string) error { return nil })
	if !items[1].present || items[1].remove != nil || !strings.Contains(items[1].kept, "a link to "+target) || strings.Join(own, ",") != "instances" {
		t.Fatalf("a linked folder: %+v own %v", items[1], own)
	}
}
