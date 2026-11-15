package cloudrepl

import (
	"context"
	"net/url"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
)

// P3 (task 390b task 14, the lead's 00:2x): the provider's own failover events of the instance itself, handed to 404's
// restart / failover event (0155's instance_events) by the import, where the provider's word wins (an RDS Multi-AZ DB
// instance's or a Cloud SQL HA instance's failover reads 'restart' in 0155: its standby runs no engine until it takes
// over). Read under the same doors as P1 / P2: RDS DescribeEvents is a new call under aws.replicas (its right
// rds:DescribeEvents), Cloud SQL operations.list under the gcp: block (Google's IAM table names cloudsql.instances.get
// and cloudsql.instances.list for it, read 2026-11-15; roles/cloudsql.viewer carries both).

// Failover is one phase of a provider failover of the instance: started or completed, with the provider's words.
type Failover struct {
	ResourceID string
	At         time.Time
	Phase      string // started | completed
	Message    string
	Source     string // rds events | cloud sql operations
	ID         string // Cloud SQL: the operation's name
}

// RDSEventsAPI is the one call P3 makes on RDS.
type RDSEventsAPI interface {
	DescribeEvents(ctx context.Context, in *rds.DescribeEventsInput, opt ...func(*rds.Options)) (*rds.DescribeEventsOutput, error)
}

// failoverWindow: each read looks this far back (RDS keeps events 14 days; the read runs every 5 minutes, and the import
// keeps each phase once)
const failoverWindow = 2 * time.Hour

// rdsPhase: the DB instance failover category's messages (Amazon's event table, RDS-EVENT-0013 / 0015 / 0049 / 0050 /
// 0051, read 2026-11-15): 0034's abandoned request and 0065's partial recovery are no failover
func rdsPhase(msg string) string {
	m := strings.ToLower(msg)
	switch {
	case strings.Contains(m, "abandoning"), strings.Contains(m, "partial failover"):
		return ""
	case strings.Contains(m, "failover started"), strings.Contains(m, "activation started"):
		return "started"
	case strings.Contains(m, "failover completed"), strings.Contains(m, "failover to standby complete"), strings.Contains(m, "activation completed"):
		return "completed"
	}
	return ""
}

// Failovers reads the DB instance's failover events of the last two hours (every page).
func (r *AWSReader) Failovers(ctx context.Context, region, dbInstance string) ([]Failover, error) {
	id := strings.ToLower(strings.TrimSpace(dbInstance))
	if r.Events == nil {
		return nil, nil // a reader without the events seam (a test's stand-in): no P3 read
	}
	api, err := r.Events(ctx, region)
	if err != nil {
		return nil, err
	}
	in := &rds.DescribeEventsInput{SourceIdentifier: aws.String(id), SourceType: rdstypes.SourceTypeDbInstance,
		EventCategories: []string{"failover"}, StartTime: aws.Time(r.Now().UTC().Add(-failoverWindow)), MaxRecords: aws.Int32(100)}
	var out []Failover
	for page := 0; page < 50; page++ {
		res, err := api.DescribeEvents(ctx, in)
		if err != nil {
			return nil, awsErr("rds:DescribeEvents", region, err)
		}
		for _, e := range res.Events {
			msg := aws.ToString(e.Message)
			if ph := rdsPhase(msg); ph != "" && e.Date != nil {
				out = append(out, Failover{ResourceID: id, At: e.Date.UTC(), Phase: ph, Message: msg, Source: "rds events"})
			}
		}
		if aws.ToString(res.Marker) == "" {
			break
		}
		in.Marker = res.Marker
	}
	return out, nil
}

// Failovers reads the Cloud SQL instance's FAILOVER operations that started in the last two hours (operations.list,
// newest start first, paged; the read stops at the first operation older than the window): a start, and an end when
// the operation is DONE without an error.
func (g *GCPReader) Failovers(ctx context.Context, project, instance string) ([]Failover, error) {
	project, instance = strings.TrimSpace(project), strings.TrimSpace(instance)
	id := gcpID(project, instance)
	since := g.Now().UTC().Add(-failoverWindow)
	q := url.Values{}
	q.Set("instance", instance)
	q.Set("maxResults", "100")
	base := strings.TrimRight(g.AdminURL, "/") + "/v1/projects/" + url.PathEscape(project) + "/operations"
	var out []Failover
	for page := 0; page < 20; page++ {
		var res struct {
			Items []struct {
				Name          string     `json:"name"`
				OperationType string     `json:"operationType"`
				Status        string     `json:"status"`
				StartTime     *time.Time `json:"startTime"`
				EndTime       *time.Time `json:"endTime"`
				Error         *struct{}  `json:"error"`
			} `json:"items"`
			NextPageToken string `json:"nextPageToken"`
		}
		if err := g.call(ctx, callOperations, project, base+"?"+q.Encode(), &res); err != nil {
			return nil, err
		}
		older := false
		for _, op := range res.Items {
			if op.StartTime == nil {
				continue
			}
			if op.StartTime.Before(since) {
				older = true
				continue
			}
			if op.OperationType != "FAILOVER" {
				continue
			}
			out = append(out, Failover{ResourceID: id, At: op.StartTime.UTC(), Phase: "started", Message: "Cloud SQL FAILOVER operation " + op.Name + " started",
				Source: "cloud sql operations", ID: op.Name})
			if op.Status == "DONE" && op.Error == nil && op.EndTime != nil {
				out = append(out, Failover{ResourceID: id, At: op.EndTime.UTC(), Phase: "completed", Message: "Cloud SQL FAILOVER operation " + op.Name + " done",
					Source: "cloud sql operations", ID: op.Name})
			}
		}
		if older || res.NextPageToken == "" {
			break
		}
		q.Set("pageToken", res.NextPageToken)
	}
	return out, nil
}
