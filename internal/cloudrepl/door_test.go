package cloudrepl

import (
	"context"
	"strings"
	"testing"
	"time"

	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/smithy-go"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The collections' door (task 390b task 5): which door an instance's config names (P1 only with aws.replicas, P2 with a
// gcp: block), the import's rows from one read (a read row first naming the instance's own resource, then the
// resources and the datapoints), a refusal's sentence on the read row and in a collector_error row (the run is
// partial; the store counts the door's failed reads: fold 15), and a throttle resting the door until its next interval
// (one call, never again by the run's other instances; then read again).
func TestDoorRows(t *testing.T) {
	// the reason fits what the instance holds: its aws: block is there and only the switch is off, so the words name
	// the key (aws.replicas is off) and never read as a missing block (no 'aws:' - j16's TestNotRunningOnTheConfig)
	if p, why := Which(config.Instance{AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1"}}); p != "" || !strings.Contains(why, "aws.replicas is off") || strings.Contains(why, "aws:") {
		t.Errorf("an aws: block without replicas: %q %q, want no door and 'aws.replicas is off' without 'aws:'", p, why)
	}
	if p, _ := Which(config.Instance{AWS: &config.AWS{DBInstance: "db1", Replicas: true}}); p != "aws" {
		t.Errorf("aws.replicas: %q, want aws", p)
	}
	if p, _ := Which(config.Instance{GCP: &config.GCP{Project: "p1", Instance: "pg-a"}}); p != "gcp" {
		t.Errorf("a gcp: block: %q, want gcp", p)
	}
	if p, why := Which(config.Instance{}); p != "" || why == "" {
		t.Errorf("no block: %q %q", p, why)
	}

	now := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	east := &fakeRDS{list: []rdstypes.DBInstance{
		db("db1", "available", "", []string{"db1-r1"}),
		db("db1-r1", "available", "db1", nil, replicating("replicating")),
	}}
	cw := &fakeCW{lag: map[string][]float64{"db1-r1": {3, 4}}}
	var regionAsked string
	d := &Door{
		Now: func() time.Time { return now },
		Region: func(_ context.Context, profile string) (string, error) {
			regionAsked = profile
			return "us-east-2", nil
		},
		NewAWS: func(string) *AWSReader {
			return &AWSReader{
				RDS: func(context.Context, string) (RDSAPI, error) { return east, nil },
				CW:  func(context.Context, string) (CWAPI, error) { return cw, nil },
				Now: func() time.Time { return now },
			}
		},
	}
	in := config.Instance{Name: "pg1", AWS: &config.AWS{Profile: "lab", DBInstance: "DB1", Replicas: true}}
	rows, err := d.Rows(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	if regionAsked != "lab" {
		t.Errorf("no aws.region: the profile's region not asked (%q)", regionAsked)
	}
	if len(rows) == 0 || rows[0]["kind"] != "read" || rows[0]["provider"] != "aws" || rows[0]["resource_id"] != east1+"db1" {
		t.Fatalf("the first row %v, want the read row naming db1 (lower case)", rows)
	}
	kinds := map[string]int{}
	for _, r := range rows {
		kinds[r["kind"].(string)]++
		if r["kind"] == "point" {
			if _, err := time.Parse(time.RFC3339, r["at"].(string)); err != nil || r["metric"] != "replica_lag" || r["resource_id"] != east1+"db1-r1" {
				t.Errorf("a point row %v", r)
			}
		}
		if r["kind"] == "resource" && r["resource_id"] == east1+"db1-r1" && (r["source_id"] != east1+"db1" || r["repl_status"] != "replicating" || r["role"] != "replica") {
			t.Errorf("db1-r1's row %v", r)
		}
	}
	if kinds["read"] != 1 || kinds["resource"] != 2 || kinds["point"] != 2 || kinds["collector_error"] != 0 {
		t.Errorf("rows by kind %v, want read 1, resource 2, point 2, no collector_error", kinds)
	}

	// a throttle: the read row carries the sentence, a collector_error row names it; the run's next instance on the
	// same door makes no call; past the interval the door is read again
	east.list, east.err, east.calls = nil, &smithy.GenericAPIError{Code: "Throttling", Message: "Rate exceeded"}, 0
	now = now.Add(5 * time.Minute)
	for i := range 2 {
		rows, err = d.Rows(context.Background(), in)
		if err != nil {
			t.Fatalf("throttled read %d: %v", i, err)
		}
		notes, _ := rows[0]["notes"].([]string)
		if len(notes) != 1 || !strings.Contains(notes[0], "throttled") || len(rows) != 2 || rows[1]["kind"] != "collector_error" {
			t.Errorf("throttled read %d: %v, want the read row with the sentence and a collector_error row", i, rows)
		}
	}
	if east.calls != 1 {
		t.Errorf("DescribeDBInstances calls while throttled: %d, want 1 (the door rests until its next interval)", east.calls)
	}
	now = now.Add(5 * time.Minute)
	if _, err = d.Rows(context.Background(), in); err != nil || east.calls != 2 {
		t.Errorf("past the interval: %v, %d calls, want the door read again", err, east.calls)
	}
}
