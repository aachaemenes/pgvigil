package config

import (
	"strings"
	"testing"
)

// 390b review part a, finding 1: on engine sqlserver the aws: block's one reader is the provider replica door, so a
// block without replicas: true and db_instance opens nothing and is refused in words (the base 'aws block' case of
// TestEngine expects this refusal).
func TestSQLServerAWSBlock(t *testing.T) {
	ok := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a", Engine: "sqlserver", DSNRaw: "env:X",
		AWS: &AWS{Region: "us-east-2", DBInstance: "db1", Replicas: true}}}}
	if err := ok.Validate(); err != nil {
		t.Errorf("the replica door's block: %v", err)
	}
	for name, a := range map[string]*AWS{"empty": {}, "no replicas": {DBInstance: "db1"}, "no db_instance": {Replicas: true}} {
		c := Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a", Engine: "sqlserver", DSNRaw: "env:X", AWS: a}}}
		if err := c.Validate(); err == nil || !strings.Contains(err.Error(), "replicas: true and db_instance") {
			t.Errorf("%s: %v, want the refusal naming replicas: true and db_instance", name, err)
		}
	}
}
