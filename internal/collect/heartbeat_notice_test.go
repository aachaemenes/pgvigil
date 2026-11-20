package collect

import (
	"bytes"
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// TestRepoNoticesLogsWarning: a WARNING the repository raises on the beat's connection reaches the
// collector's log - import_collection_health warns when the 'collections run long' stamps fail (its hour rows kept),
// and a failure that repeats each beat turns the forming wait off; a NOTICE stays out of the log; the severity is read
// unlocalized (a server in another language says 'WARNUNG'); StartHeartbeat's pool carries it
func TestRepoNoticesLogsWarning(t *testing.T) {
	var buf bytes.Buffer
	f := repoNotices(slog.New(slog.NewTextHandler(&buf, nil)))
	f(nil, &pgconn.Notice{Severity: "NOTICE", SeverityUnlocalized: "NOTICE", Message: "a notice"})
	f(nil, &pgconn.Notice{Severity: "WARNING", SeverityUnlocalized: "WARNING", Message: "collection_runs_long_since: ph1 not stamped: boom"})
	f(nil, &pgconn.Notice{Severity: "WARNUNG", SeverityUnlocalized: "WARNING", Message: "localized"})
	f(nil, nil)
	out := buf.String()
	if strings.Contains(out, "a notice") {
		t.Errorf("a NOTICE was logged: %s", out)
	}
	for _, want := range []string{"ph1 not stamped: boom", "localized"} {
		if !strings.Contains(out, want) {
			t.Errorf("the WARNING %q was not logged: %s", want, out)
		}
	}
	if n := strings.Count(out, "level=WARN"); n != 2 {
		t.Errorf("%d WARN line(s), want 2: %s", n, out)
	}
	src, err := os.ReadFile("heartbeat.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "cfg.ConnConfig.OnNotice = repoNotices(log)") {
		t.Errorf("StartHeartbeat's pool does not log the repository's warnings (cfg.ConnConfig.OnNotice = repoNotices(log))")
	}
}
