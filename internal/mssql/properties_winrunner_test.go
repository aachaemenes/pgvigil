package mssql

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// windowsRunner is scripts/proof-mssql-properties-windows.sql (task 301c's row N5: one read-only pass on a Windows
// instance), its comment lines taken out and its line ends as the repository keeps them.
func windowsRunner(t *testing.T) (whole, code string) {
	t.Helper()
	b, err := os.ReadFile("../../scripts/proof-mssql-properties-windows.sql")
	if err != nil {
		t.Fatal(err)
	}
	whole = strings.ReplaceAll(string(b), "\r\n", "\n")
	var keep []string
	for _, l := range strings.Split(whole, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "--") {
			keep = append(keep, l)
		}
	}
	return whole, strings.Join(keep, "\n")
}

// TestWindowsRunnerSendsTheCodesStatements: the runner sends the four statements the collection sends for its network
// rows and Win32PrioritySeparation - each constant's text, its quotes doubled, is in the runner once, as the one
// literal of an EXEC sys.sp_executesql. A change of a statement here without the runner (or the other way) fails.
func TestWindowsRunnerSendsTheCodesStatements(t *testing.T) {
	_, code := windowsRunner(t)
	for name, q := range map[string]string{
		"propsGateSQL": propsGateSQL, "propsNetViewSQL": propsNetViewSQL, "propsNetRegSQL": propsNetRegSQL, "propsPrioritySQL": propsPrioritySQL,
	} {
		lit := "EXEC sys.sp_executesql N'" + strings.ReplaceAll(q, "'", "''") + "';"
		if n := strings.Count(code, lit); n != 1 {
			t.Errorf("%s: the runner holds the statement's text %d times, want once", name, n)
		}
	}
	if n := strings.Count(code, "sp_executesql"); n != 4 {
		t.Errorf("the runner calls sp_executesql %d times, want 4 (the four statements only)", n)
	}
}

// TestWindowsRunnerReadsOnly: the runner changes nothing on the server. Every write-shaped word in it is one of: its
// own #n5_ temp tables (and its table variable), or an EXEC of sys.sp_executesql (the four statements above, which
// TestBackupHistorySQLReadsOnly and the collection's own tests hold read-only) or of a registry / error log read.
// Every line it prints for the fixture ends with '|~'.
func TestWindowsRunnerReadsOnly(t *testing.T) {
	_, code := windowsRunner(t)
	// the four embedded statements are the code's (the test above): taken out, so their own words are not judged twice
	for _, q := range []string{propsGateSQL, propsNetViewSQL, propsNetRegSQL, propsPrioritySQL} {
		code = strings.Replace(code, strings.ReplaceAll(q, "'", "''"), "", 1)
	}
	verb := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|BACKUP|RESTORE|GRANT|DENY|REVOKE|EXEC|EXECUTE|SHUTDOWN|RECONFIGURE|KILL|DBCC)\b`)
	allowed := regexp.MustCompile(`(?i)^(` +
		`DROP TABLE IF EXISTS #n5_\w+;` +
		`|CREATE TABLE #n5_\w+ \(` +
		`|INSERT #n5_\w+ \(` +
		`|INSERT @n5_keys \(` +
		`|UPDATE #n5_enum SET k = ` +
		`|DELETE FROM #n5_enum WHERE k IS NULL;` +
		`|EXEC sys\.sp_executesql N'';` +
		`|EXEC @n5_rc = master\.dbo\.(xp_instance_regenumvalues|xp_regenumvalues|xp_instance_regread) N'HKEY_LOCAL_MACHINE'` +
		`|EXEC @rc = master\.dbo\.xp_instance_regenumkeys N'HKEY_LOCAL_MACHINE'` +
		`|EXEC master\.dbo\.xp_readerrorlog 0, 1, N'` +
		`)`)
	for _, at := range verb.FindAllStringIndex(code, -1) {
		rest := code[at[0]:]
		if !allowed.MatchString(rest) {
			end := len(rest)
			if end > 90 {
				end = 90
			}
			t.Errorf("a write-shaped word the runner may not hold: %q", rest[:end])
		}
	}
	for _, proc := range []string{"xp_regwrite", "xp_instance_regwrite", "xp_regdeletevalue", "xp_regdeletekey", "xp_regaddmultistring", "xp_regremovemultistring", "xp_cmdshell", "sp_configure"} {
		if strings.Contains(strings.ToLower(code), proc) {
			t.Errorf("the runner names %s", proc)
		}
	}
	// every fixture line it builds or prints ends with the terminator
	lines := regexp.MustCompile(`N'N5x?\|`).FindAllStringIndex(code, -1)
	ends := strings.Count(code, `|~'`)
	if len(lines) == 0 || ends < len(lines) {
		t.Errorf("the runner starts %d N5 lines and ends %d with '|~'", len(lines), ends)
	}
}
