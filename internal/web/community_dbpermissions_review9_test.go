package web

import (
	"os"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestDBPermissionsReview9 (review t11-9's fold, P25 row 75 sp_DBPermissions):
//   - 4: the procedure drops and makes global temp tables (##DBPrincipals, ##DBRoles, ##DBPermissions), so two runs at
//     once on one instance cross their results: the door runs it one at a time per instance (serialRun);
//   - 7: the printed install is one guarded statement (the file installed only when its SHA256 is the pin, in the same
//     statement - a paste run line by line can no longer install a stale file), TLS 1.2 on first, the download checked by
//     Test-Path with its own words, the temp folder by [IO.Path]::GetTempPath() (pwsh on Linux too);
//   - 10: the version is read as DBA Dash reads it (VersionPattern V(?<version>[\d.]+), any case);
//   - 6: whether it needs installing is decided in master (where the block installs it): on another database the
//     block is not printed, a line says why;
//   - 9: msChecks reads VIEW ANY DEFINITION for it (without it the grids hold only what the login sees).
func TestDBPermissionsReview9(t *testing.T) {
	if !serialTools["sp_DBPermissions"] {
		t.Error("serialTools does not name sp_DBPermissions")
	}
	unlock := serialRun(7, "sp_DBPermissions")
	var second atomic.Bool
	done := make(chan struct{})
	go func() {
		u := serialRun(7, "sp_DBPermissions")
		second.Store(true)
		u()
		close(done)
	}()
	time.Sleep(50 * time.Millisecond)
	if second.Load() {
		t.Error("a second run on the same instance did not wait for the first")
	}
	other := serialRun(8, "sp_DBPermissions") // another instance never waits
	other()
	unlock()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("the second run never ran after the first ended")
	}

	inst := dbPermsInstall()
	for _, want := range []string{"[Net.ServicePointManager]::SecurityProtocol", "[IO.Path]::GetTempPath()", "Test-Path -LiteralPath $DbPermsFile"} {
		if !strings.Contains(inst, want) {
			t.Errorf("dbPermsInstall lacks %q", want)
		}
	}
	if !regexp.MustCompile(`(?m)^if \(\(Get-FileHash -Algorithm SHA256 -LiteralPath \$DbPermsFile\)\.Hash -eq '` + dbPermsSHA256 + `'\) \{ Invoke-DbaQuery [^\n]*\} else \{ throw `).MatchString(inst) {
		t.Errorf("dbPermsInstall: the hash check and the install are not one statement:\n%s", inst)
	}

	for in, want := range map[string]string{"-- sp_DBPermissions V7.0.1 (2026)": "7.0.1", "SP_DBPERMISSIONS v7 ": "7", "sp_DBPermissions V7.0": "7.0"} {
		if got := parseVersion(in).Version; got != want {
			t.Errorf("parseVersion(%q) = %q, want %q", in, got, want)
		}
	}

	missing := []toolState{{communityTool: communityTool{ID: "sp_DBPermissions", Name: "sp_DBPermissions", Group: "SQLStudies", Kind: "proc"},
		Installed: new(bool), VersionWord: "not installed"}}
	if s, _ := installScript("x01", "srv", "DBA", missing); strings.Contains(s, "Invoke-DbaQuery") || !strings.Contains(s, "sp_DBPermissions installs into master") {
		t.Errorf("installScript for database DBA prints the master install, or says nothing of it:\n%s", s)
	}
	if s, _ := installScript("x01", "srv", "master", missing); !strings.Contains(s, "Invoke-DbaQuery") {
		t.Errorf("installScript for master does not print the block:\n%s", s)
	}

	b, err := os.ReadFile("q_community.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION')") {
		t.Error("q_community.go's msChecks does not read VIEW ANY DEFINITION for sp_DBPermissions")
	}
}

// TestDBPermissionsTabReview9 (review t11-9's fold): the database page's sp_DBPermissions tab -
//   - 2: its Run button names its need (needControl on community/run: a viewer sees why it is off);
//   - 3: in queue mode it waits for the collector's answer and draws it (isQueued / waitRequest), as the Community page;
//   - 5: when the server says the tool is not usable (t.on false) it shows the server's own needs words;
//   - 12: a database name holding a quote, or named All, is refused with words (the procedure splices @DBName);
//   - 15: a door that is not usable says its reason alone (never 'the door is off' for every reason).
func TestDBPermissionsTabReview9(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	fn := regexp.MustCompile(`(?s)async function dbPermissions\(ctx: Ctx, db: string\): Promise<HTMLElement> \{(.*?)\n\}\n`).FindStringSubmatch(src)
	if fn == nil {
		t.Fatal("mssql_db.ts: no dbPermissions(ctx, db)")
	}
	for _, want := range []string{"needControl(el('button'", "'community/run')", "isQueued(r)", "waitRequest(r, ", "t.needs", "holds a quote", "=== 'all'"} {
		if !strings.Contains(fn[1], want) {
			t.Errorf("dbPermissions lacks %q", want)
		}
	}
	if strings.Contains(fn[1], "The Community tools door is off here") {
		t.Error("dbPermissions still calls every refusal 'the door is off'")
	}
}
