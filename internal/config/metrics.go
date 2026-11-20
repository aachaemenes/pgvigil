package config

// MetricsBlock is pgvigil.yaml's metrics: block, the tuning of serve's Prometheus endpoint (B24d). The endpoint itself
// is off unless doors.prometheus_metrics is on (pagedoor.go); this block changes nothing while it is off.
//
//	doors:
//	  prometheus_metrics: on
//	metrics:
//	  token: file:/etc/pgvigil/metrics.token   # or env:NAME; 32 bytes at least; never the token itself
//	  cache_seconds: 60                         # a body's life before the next render
//	  databases: off                            # each database's own series (the instance totals are always there)
//	  max_databases: 50                         # the per-database series of one instance, largest first
//	  include_databases: [app, billing]         # in place of the largest
//	  tags: off                                 # the instance's tags on pgvigil_instance_info
type MetricsBlock struct {
	Token            string   `yaml:"token"`
	CacheSeconds     int      `yaml:"cache_seconds"`
	Databases        bool     `yaml:"databases"`
	MaxDatabases     int      `yaml:"max_databases"`
	IncludeDatabases []string `yaml:"include_databases"`
	Tags             bool     `yaml:"tags"`
}
