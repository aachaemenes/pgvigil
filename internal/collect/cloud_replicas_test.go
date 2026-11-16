package collect

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/cloudrepl"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// 390b review part a, finding 7a: cloud_replicas reaches the door only for the instance kind its block reads - an
// aws: block with replicas on an RDS instance, a gcp: block on Cloud SQL; another kind, or no door, skips without a
// call.
func TestCloudReplicasCollection(t *testing.T) {
	reached := 0
	was := cloudReplicasDoor
	defer func() { cloudReplicasDoor = was }()
	cloudReplicasDoor = &cloudrepl.Door{Now: time.Now, NewAWS: func(string) *cloudrepl.AWSReader {
		return &cloudrepl.AWSReader{Now: time.Now, RDS: func(context.Context, string) (cloudrepl.RDSAPI, error) {
			reached++
			return nil, errors.New("the stand-in door was reached")
		}}
	}}
	aws := config.Instance{Name: "pg1", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1", Replicas: true}}
	c := cloudReplicasCollector{}
	rows, err := c.RunInstance(context.Background(), nil, platform.Info{Kind: platform.RDS}, aws, nil)
	var notes []string
	if len(rows) > 0 {
		notes, _ = rows[0]["notes"].([]string)
	}
	if reached != 1 || (err == nil && !strings.Contains(strings.Join(notes, " "), "stand-in")) {
		t.Errorf("an RDS instance with aws.replicas: reached %d, rows %v, err %v - want the door read", reached, rows, err)
	}
	for name, run := range map[string]struct {
		in   config.Instance
		kind platform.Kind
	}{
		"aws on Cloud SQL":  {aws, platform.CloudSQL},
		"aws on Aurora":     {aws, platform.Aurora},
		"no replicas":       {config.Instance{Name: "pg1", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1"}}, platform.RDS},
		"gcp on RDS":        {config.Instance{Name: "pg1", GCP: &config.GCP{Project: "p1", Instance: "pg-a"}}, platform.RDS},
		"no block anywhere": {config.Instance{Name: "pg1"}, platform.RDS},
	} {
		reached = 0
		_, err := c.RunInstance(context.Background(), nil, platform.Info{Kind: run.kind}, run.in, nil)
		if !errors.Is(err, ErrSkip) || reached != 0 {
			t.Errorf("%s: %v (reached %d), want a skip and no call", name, err, reached)
		}
	}
}
