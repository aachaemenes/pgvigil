package config

import (
	"strings"
	"testing"
)

// Task 390b: the doors of the provider replica metrics. An aws: block on a SQL Server instance takes region, profile,
// db_instance and replicas, never cluster, log_group or dms (the design fold 3); aws.replicas (P1's own door for its new
// calls, off by default: decision Q8) needs a db_instance; a gcp: block (P2: project, instance, an optional
// credentials_file) is PostgreSQL's alone (Cloud SQL for SQL Server's replicas are not read).
func TestCloudReplicaBlocks(t *testing.T) {
	base := func(engine string, a *AWS, g *GCP) Config {
		return Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a", Engine: engine, DSNRaw: "env:X", AWS: a, GCP: g}}}
	}
	cases := []struct {
		what   string
		cfg    Config
		refuse string
	}{
		{"sqlserver: region, profile, db_instance, replicas off (its one reader is the provider replica door: review part a, finding 1)",
			base(EngineSQLServer, &AWS{Region: "us-east-2", Profile: "p", DBInstance: "db1"}, nil), "needs replicas: true and db_instance"},
		{"sqlserver: replicas on", base(EngineSQLServer, &AWS{Region: "us-east-2", DBInstance: "db1", Replicas: true}, nil), ""},
		{"sqlserver: a cluster", base(EngineSQLServer, &AWS{Region: "us-east-2", Cluster: "c1"}, nil), "region, profile, db_instance and replicas"},
		{"sqlserver: a log group", base(EngineSQLServer, &AWS{Region: "us-east-2", DBInstance: "db1", LogGroup: "/x"}, nil), "region, profile, db_instance and replicas"},
		{"sqlserver: dms", base(EngineSQLServer, &AWS{Region: "us-east-2", DBInstance: "db1", DMS: &DMS{}}, nil), "region, profile, db_instance and replicas"},
		{"postgres: replicas on", base(EnginePostgres, &AWS{Region: "us-east-2", DBInstance: "db1", Replicas: true}, nil), ""},
		{"postgres: replicas on a cluster", base(EnginePostgres, &AWS{Region: "us-east-2", Cluster: "c1", Replicas: true}, nil), "needs aws.db_instance"},
		{"postgres: gcp", base(EnginePostgres, nil, &GCP{Project: "p1", Instance: "i1"}), ""},
		{"postgres: gcp with a credentials file", base(EnginePostgres, nil, &GCP{Project: "p1", Instance: "i1", CredentialsFile: "/etc/pgvigil/gcp.json"}), ""},
		{"postgres: gcp without an instance", base(EnginePostgres, nil, &GCP{Project: "p1"}), "names project and instance"},
		{"sqlserver: gcp", base(EngineSQLServer, nil, &GCP{Project: "p1", Instance: "i1"}), "PostgreSQL's"},
	}
	for _, c := range cases {
		err := c.cfg.Validate()
		switch {
		case c.refuse == "" && err != nil:
			t.Errorf("%s: refused: %v", c.what, err)
		case c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)):
			t.Errorf("%s: %v, want a refusal naming %q", c.what, err, c.refuse)
		}
	}
	if k := (GCP{Project: "P1", Instance: "I1"}).ResourceID(); k != "p1:i1" {
		t.Errorf("ResourceID %q, want p1:i1", k)
	}
}
