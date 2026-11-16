package config

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// TestProbeConfig (B24h-1d; the B24h fold's B24h-a): 'probe: icmp | tcp | off' ("" = icmp) and 'probe_every_minute'
// (false by default: the probe runs after a failed collection only)
func TestProbeConfig(t *testing.T) {
	for _, v := range []string{"", "icmp", "tcp", "off"} {
		c := Config{Repository: Repository{DSNRaw: "r"}, Probe: v}
		if err := c.Validate(); err != nil {
			t.Errorf("probe %q: %v, want accepted", v, err)
		}
	}
	c := Config{Repository: Repository{DSNRaw: "r"}, Probe: "ping"}
	if err := c.Validate(); err == nil || !strings.Contains(err.Error(), "icmp, tcp or off") {
		t.Errorf("probe 'ping': %v, want refused naming icmp, tcp or off", err)
	}
	var y Config
	if err := yaml.Unmarshal([]byte("repository: {dsn: r}\nprobe: tcp\nprobe_every_minute: true\n"), &y); err != nil || y.Probe != "tcp" || !y.ProbeEveryMinute {
		t.Errorf("yaml: %+v %v, want probe tcp and probe_every_minute true", y.Probe, err)
	}
}
