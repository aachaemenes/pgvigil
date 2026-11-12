package mssql

import (
	"fmt"
	"testing"

	mssqldb "github.com/microsoft/go-mssqldb"
)

// msg567 is the text of Msg 567 as sys.messages holds it ("File '%.*ls' is not a recognizable trace file."), naming a file.
func msg567(file string) string {
	return fmt.Sprintf("File '%s' is not a recognizable trace file.", file)
}

// The set read that failed on an older file goes on from the file after it; the current file, a file of another
// folder, a newer number or a message without a file name gives no restart (the read stays failed).
func TestTraceRestartFile(t *testing.T) {
	win := `C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\Log\`
	for _, c := range []struct {
		name, msg, current, restart, skipped string
		ok                                   bool
	}{
		{"the oldest file of log_7-log_11", msg567(win + "log_7.trc"), win + "log_11.trc", win + "log_8.trc", win + "log_7.trc", true},
		{"two digits", msg567(win + "log_9.trc"), win + "log_12.trc", win + "log_10.trc", win + "log_9.trc", true},
		{"the file before the current one", msg567(win + "log_10.trc"), win + "log_11.trc", win + "log_11.trc", win + "log_10.trc", true},
		{"a Linux server", msg567("/var/opt/mssql/log/log_3.trc"), "/var/opt/mssql/log/log_5.trc", "/var/opt/mssql/log/log_4.trc", "/var/opt/mssql/log/log_3.trc", true},
		{"the folder in another case (Windows)", msg567(`C:\PROGRAM FILES\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\LOG\log_7.trc`), win + "log_11.trc", win + "log_8.trc",
			`C:\PROGRAM FILES\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\LOG\log_7.trc`, true},
		{"the current file", msg567(win + "log_11.trc"), win + "log_11.trc", "", win + "log_11.trc", false},
		{"a newer number than the current", msg567(win + "log_12.trc"), win + "log_11.trc", "", win + "log_12.trc", false},
		{"another folder", msg567(`D:\old\log_7.trc`), win + "log_11.trc", "", `D:\old\log_7.trc`, false},
		{"not of the set's form", msg567(win + "mytrace.trc"), win + "log_11.trc", "", win + "mytrace.trc", false},
		{"no file in the message", "Msg 567 without a name", win + "log_11.trc", "", "", false},
		{"the current path not of the set's form", msg567(win + "log_7.trc"), win + "log.trc", "", win + "log_7.trc", false},
	} {
		restart, skipped, ok := traceRestartFile(c.msg, c.current)
		if restart != c.restart || skipped != c.skipped || ok != c.ok {
			t.Errorf("%s: traceRestartFile = %q, %q, %v; want %q, %q, %v", c.name, restart, skipped, ok, c.restart, c.skipped, c.ok)
		}
	}
	// the restarts move forward by number, not by text (log_10 sorts before log_8 as text)
	if a, b := traceFileNumber(win+"log_10.trc"), traceFileNumber(win+"log_8.trc"); a != 10 || b != 8 || a <= b {
		t.Errorf("traceFileNumber: log_10 = %d, log_8 = %d", a, b)
	}
	if n := traceFileNumber(win + "log.trc"); n != -1 {
		t.Errorf("traceFileNumber(log.trc) = %d, want -1", n)
	}
}

// The reader takes the number and the file from the driver's error: 567 through mssqlErrNumber, the file through
// err.Error(), wrapped or not.
func TestTraceUnreadableFromDriverError(t *testing.T) {
	file := `C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\Log\log_7.trc`
	base := mssqldb.Error{Number: traceUnreadable, Message: msg567(file)}
	for _, err := range []error{base, fmt.Errorf("read: %w", base)} {
		if n := mssqlErrNumber(err); n != traceUnreadable {
			t.Errorf("mssqlErrNumber(%v) = %d, want %d", err, n, traceUnreadable)
		}
		if _, skipped, ok := traceRestartFile(err.Error(), `C:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\Log\log_11.trc`); !ok || skipped != file {
			t.Errorf("from %q: skipped %q, ok %v", err.Error(), skipped, ok)
		}
	}
}
