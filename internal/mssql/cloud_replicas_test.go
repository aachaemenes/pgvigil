package mssql

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/cloudrepl"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// 390b review part a, finding 7a: mssql_cloud_replicas reaches the door only for an RDS for SQL Server instance whose
// aws: block has replicas: true; another kind, a gcp: block or no switch skips without a call.
func TestMSSQLCloudReplicasCollection(t *testing.T) {
	reached := 0
	was := cloudReplicasDoor
	defer func() { cloudReplicasDoor = was }()
	cloudReplicasDoor = &cloudrepl.Door{Now: time.Now, NewAWS: func(string) *cloudrepl.AWSReader {
		return &cloudrepl.AWSReader{Now: time.Now, RDS: func(context.Context, string) (cloudrepl.RDSAPI, error) {
			reached++
			return nil, errors.New("the stand-in door was reached")
		}}
	}}
	aws := config.Instance{Name: "ms1", Engine: "sqlserver", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1", Replicas: true}}
	c := cloudReplicasCollector{}
	if _, err := c.RunInstance(context.Background(), nil, Info{Kind: KindRDS}, aws); reached != 1 {
		t.Errorf("an RDS for SQL Server instance with aws.replicas: reached %d (%v), want the door read", reached, err)
	}
	for name, run := range map[string]struct {
		in   config.Instance
		kind Kind
	}{
		"on a server":     {aws, KindServer},
		"on Azure SQL MI": {aws, KindAzureMI},
		"no replicas":     {config.Instance{Name: "ms1", Engine: "sqlserver", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1"}}, KindRDS},
		"a gcp: block":    {config.Instance{Name: "ms1", Engine: "sqlserver", GCP: &config.GCP{Project: "p1", Instance: "x"}}, KindRDS},
		"no block at all": {config.Instance{Name: "ms1", Engine: "sqlserver"}, KindRDS},
	} {
		reached = 0
		if _, err := c.RunInstance(context.Background(), nil, Info{Kind: run.kind}, run.in); !errors.Is(err, collect.ErrSkip) || reached != 0 {
			t.Errorf("%s: %v (reached %d), want a skip and no call", name, err, reached)
		}
	}
}
