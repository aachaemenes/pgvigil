package config

import (
	"strings"
	"testing"
)

// B9c (B9-13): an instance's actions: list may name job_enable and job_disable on both engines (off until named); an
// unknown kind is still refused with the list of the known ones.
func TestJobToggleActionsList(t *testing.T) {
	ok := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{
		{Name: "pg-toggle", DSNRaw: "host=x", ActionsDSNRaw: "env:PG_ACT", Actions: []string{"job_stop", "job_start", "job_enable", "job_disable"}},
		{Name: "ms-toggle", Engine: "sqlserver", DSNRaw: "env:MS_DSN", ActionsDSNRaw: "env:MS_ACT", Actions: []string{"kill", "job_start", "job_stop", "job_enable", "job_disable"}},
	}}
	if err := ok.Validate(); err != nil {
		t.Fatalf("a config naming job_enable / job_disable was rejected: %v", err)
	}
	for name, in := range map[string]Instance{
		"pg": {Name: "pg-bad", DSNRaw: "host=x", ActionsDSNRaw: "env:PG_ACT", Actions: []string{"job_drop"}},
		"ms": {Name: "ms-bad", Engine: "sqlserver", DSNRaw: "env:MS_DSN", ActionsDSNRaw: "env:MS_ACT", Actions: []string{"job_drop"}},
	} {
		c := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{in}}
		err := c.Validate()
		if err == nil || !strings.Contains(err.Error(), "job_enable") || !strings.Contains(err.Error(), "job_disable") {
			t.Errorf("%s: an unknown kind: %v (want refused, naming job_enable and job_disable among the known ones)", name, err)
		}
	}
}
