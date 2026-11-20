package main

import (
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestPageSettingsCatalogueGated: the panel's 'by default' on a page instance is 0 for a collection its gate shuts
// there - amcheck, opt-in per instance, stays off whatever the file's global schedules: say - and the
// file's global value for one that runs.
func TestPageSettingsCatalogueGated(t *testing.T) {
	cfg := &config.Config{Schedules: map[string]config.Duration{"amcheck": {Duration: 24 * time.Hour}, "statements": {Duration: 2 * time.Minute}}}
	got := map[string]int{}
	for _, c := range pageSettingsConfig(cfg).Catalogue[config.EnginePostgres] {
		got[c.Name] = c.DefaultS
	}
	if v, ok := got["amcheck"]; !ok || v != 0 {
		t.Errorf("amcheck by default: %d (listed %t), want 0 (its gate)", v, ok)
	}
	if got["statements"] != 120 {
		t.Errorf("statements by default: %d, want 120 (the file's global schedules:)", got["statements"])
	}
}
