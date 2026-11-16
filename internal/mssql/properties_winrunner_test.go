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
// own #n5_ temp tables (and its table variable), or an EXEC of sys.sp_executesql (the four statements of the code) or
// of a registry / error log read. The four statements themselves are judged here too (no other test holds three of
// them): in them only xp_instance_regread and xp_regread are called, and nothing else is write-shaped. Each batch
// starts with a keyword (a procedure is never called by its bare name), and every line the runner prints ends '|~'.
func TestWindowsRunnerReadsOnly(t *testing.T) {
	_, code := windowsRunner(t)
	verb := regexp.MustCompile(`(?i)\b(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|TRUNCATE|BACKUP|RESTORE|GRANT|DENY|REVOKE|EXEC|EXECUTE|SHUTDOWN|RECONFIGURE|KILL|DBCC|INTO|ENABLE|DISABLE|SEND|WRITETEXT|UPDATETEXT|RAISERROR|WAITFOR)\b`)
	// the code's four statements: reads, and the two registry reads with their OUTPUT
	inCode := regexp.MustCompile(`^(EXEC master\.dbo\.xp_(instance_)?regread N'HKEY_LOCAL_MACHINE'|EXECUTE'\))`)
	for name, q := range map[string]string{"propsGateSQL": propsGateSQL, "propsNetViewSQL": propsNetViewSQL, "propsNetRegSQL": propsNetRegSQL, "propsPrioritySQL": propsPrioritySQL} {
		for _, at := range verb.FindAllStringIndex(q, -1) {
			if rest := q[at[0]:]; !inCode.MatchString(rest) {
				end := len(rest)
				if end > 90 {
					end = 90
				}
				t.Errorf("%s holds a write-shaped word: %q", name, rest[:end])
			}
		}
		// taken out of the runner's text below: judged above, not twice
		code = strings.Replace(code, strings.ReplaceAll(q, "'", "''"), "", 1)
	}
	allowed := regexp.MustCompile(`(?i)^(` +
		`DROP TABLE IF EXISTS #n5_\w+;` +
		`|CREATE TABLE #n5_\w+ \(` +
		`|INSERT #n5_\w+ \(` +
		`|INSERT @n5_keys \(` +
		`|UPDATE #n5_enum SET k = ` +
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
	whole, _ := windowsRunner(t)
	if m := regexp.MustCompile(`(?i)xp_(instance_)?reg(write|delete\w*|add\w*|remove\w*)|xp_cmdshell|sp_configure|WITH\s+LOG`).FindString(whole); m != "" {
		t.Errorf("the runner names %s", m)
	}
	// a batch starts with a keyword: a procedure called by its bare name (no EXEC) as a batch's first statement is refused
	first := regexp.MustCompile(`^(SET|DROP|PRINT|BEGIN|CREATE|DECLARE|SELECT)\b`)
	for i, batch := range regexp.MustCompile(`(?m)^GO\s*$`).Split(code, -1) {
		if b := strings.TrimSpace(batch); b != "" && !first.MatchString(b) {
			end := len(b)
			if end > 60 {
				end = 60
			}
			t.Errorf("batch %d starts with %q, not a keyword", i+1, b[:end])
		}
	}
	// every line it builds or prints ends with the terminator: as many line ends as line starts
	starts := len(regexp.MustCompile(`'N5x?\|`).FindAllStringIndex(code, -1))
	ends := strings.Count(code, `|~'`)
	if starts == 0 || ends != starts {
		t.Errorf("the runner starts %d N5 lines and ends %d with '|~'", starts, ends)
	}
}
