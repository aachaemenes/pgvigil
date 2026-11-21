package config

import (
	"log/slog"
	"strings"
	"testing"
)

// TestLogLevelL172 (RELNOTES L172, PerformanceMonitor 3.7.0's log verbosity as a setting): log_level takes debug,
// info, warn or error in any case; empty is info; any other word is refused at load in words.
func TestLogLevelL172(t *testing.T) {
	for v, want := range map[string]slog.Level{"": slog.LevelInfo, "debug": slog.LevelDebug, "Info": slog.LevelInfo, "WARN": slog.LevelWarn, "error": slog.LevelError} {
		got, err := ParseLogLevel(v)
		if err != nil || got != want {
			t.Errorf("%q: %v, %v; want %v", v, got, err, want)
		}
	}
	for _, v := range []string{"verbose", "warning", "2"} {
		if _, err := ParseLogLevel(v); err == nil || !strings.Contains(err.Error(), "debug, info, warn or error") {
			t.Errorf("%q: %v, want a refusal naming the four", v, err)
		}
		c := Config{Repository: Repository{DSNRaw: "r"}, LogLevel: v}
		if err := c.Validate(); err == nil || !strings.Contains(err.Error(), "log_level") {
			t.Errorf("Validate with log_level %q: %v, want a refusal naming log_level", v, err)
		}
	}
}
