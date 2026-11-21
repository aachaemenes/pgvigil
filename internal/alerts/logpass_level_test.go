package alerts

import (
	"bytes"
	"errors"
	"log/slog"
	"strings"
	"testing"
)

// TestLogPassFailuresAreErrors: a failed pass and unjudged rules are Error lines, so log_level: error still says that
// alerts are not going out; a Send test request not read stays a warning.
func TestLogPassFailuresAreErrors(t *testing.T) {
	for _, c := range []struct {
		res   Result
		err   error
		msg   string
		level string
	}{
		{Result{}, errors.New("connection refused"), `msg="alerts pass failed"`, "level=ERROR"},
		{Result{RulesErr: errors.New("permission denied")}, nil, `msg="alerts: the alert rules were not judged in this pass"`, "level=ERROR"},
		{Result{TestsErr: errors.New("permission denied")}, nil, `msg="alerts: the Send test requests were not read in this pass"`, "level=WARN"},
	} {
		var buf bytes.Buffer
		logPass(slog.New(slog.NewTextHandler(&buf, nil)), c.res, c.err)
		got := strings.TrimSpace(buf.String())
		if !strings.Contains(got, c.msg) || !strings.Contains(got, c.level) {
			t.Errorf("logPass wrote %q, want %s at %s", got, c.msg, c.level)
		}
	}
}
