package cloudrepl

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/smithy-go"
)

// fakeEvents answers DescribeEvents from a list, one event a page (the Marker), recording each request
type fakeEvents struct {
	mu   sync.Mutex
	list []rdstypes.Event
	err  error
	in   []*rds.DescribeEventsInput
}

func (f *fakeEvents) DescribeEvents(_ context.Context, in *rds.DescribeEventsInput, _ ...func(*rds.Options)) (*rds.DescribeEventsOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.in = append(f.in, in)
	if f.err != nil {
		return nil, f.err
	}
	i := 0
	if in.Marker != nil {
		for k := range f.list {
			if aws.ToString(f.list[k].Message) == *in.Marker {
				i = k
			}
		}
	}
	out := &rds.DescribeEventsOutput{}
	if i < len(f.list) {
		out.Events = f.list[i : i+1]
		if i+1 < len(f.list) {
			out.Marker = f.list[i+1].Message
		}
	}
	return out, nil
}

// P3 (task 390b task 14, the lead's 00:2x): the provider's own failover events. RDS DescribeEvents for the aws: block's
// DB instance (SourceType db-instance, EventCategories failover, the last 2 hours, every page): RDS-EVENT-0013 'Multi-AZ
// instance failover started.' and 0049 'Multi-AZ instance failover completed.' (and 0015's complete, 0050 / 0051's
// activation) are a failover's phases; 0034's 'Abandoning user requested failover' is none; AccessDenied names the
// right. Cloud SQL operations.list for the gcp: block's instance (reverse chronological by start time, paged): a
// FAILOVER operation is its start and, DONE without an error, its end; another type is none; the read stops at the
// first operation that started before the window.
func TestFailoverEvents(t *testing.T) {
	now := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	ev := func(at time.Time, msg string) rdstypes.Event {
		return rdstypes.Event{Date: aws.Time(at), Message: aws.String(msg), SourceIdentifier: aws.String("db1"), EventCategories: []string{"failover"}}
	}
	fe := &fakeEvents{list: []rdstypes.Event{
		ev(now.Add(-30*time.Minute), "Multi-AZ instance failover started."),
		ev(now.Add(-29*time.Minute), "Multi-AZ failover to standby complete - DNS propagation may take a few minutes."),
		ev(now.Add(-28*time.Minute), "Multi-AZ instance failover completed."),
		ev(now.Add(-10*time.Minute), "Abandoning user requested failover since a failover recently occurred on the database instance."),
	}}
	r := &AWSReader{Events: func(context.Context, string) (RDSEventsAPI, error) { return fe, nil }, Now: func() time.Time { return now }}
	fs, err := r.Failovers(context.Background(), "us-east-2", "DB1")
	if err != nil {
		t.Fatal(err)
	}
	phases := map[string]int{}
	for _, f := range fs {
		phases[f.Phase]++
		if f.ResourceID != "db1" || f.Source != "rds events" || f.Message == "" {
			t.Errorf("a failover row %+v", f)
		}
	}
	if phases["started"] != 1 || phases["completed"] != 2 || len(fs) != 3 {
		t.Errorf("phases %v of %d rows, want started 1, completed 2 (0015 and 0049), 0034 left out", phases, len(fs))
	}
	if len(fe.in) != 4 {
		t.Errorf("%d DescribeEvents calls, want 4 (every page)", len(fe.in))
	}
	in := fe.in[0]
	if aws.ToString(in.SourceIdentifier) != "db1" || in.SourceType != rdstypes.SourceTypeDbInstance || strings.Join(in.EventCategories, ",") != "failover" ||
		in.StartTime == nil || !in.StartTime.Equal(now.Add(-2*time.Hour)) {
		t.Errorf("the request %+v: want db1, db-instance, failover, from 2 hours back", in)
	}
	fe.err = &smithy.GenericAPIError{Code: "AccessDenied", Message: "not authorized to perform: rds:DescribeEvents"}
	if _, err := r.Failovers(context.Background(), "us-east-2", "db1"); err == nil || !strings.Contains(err.Error(), "rds:DescribeEvents") {
		t.Errorf("AccessDenied: %v, want the right named", err)
	}

	var pages []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/sql/v1/projects/p1/operations" || req.URL.Query().Get("instance") != "pg-a" {
			t.Errorf("an operations.list request %s", req.URL)
		}
		pages = append(pages, req.URL.Query().Get("pageToken"))
		if req.URL.Query().Get("pageToken") == "" {
			_, _ = w.Write([]byte(`{"items":[
				{"operationType":"BACKUP_VOLUME","status":"DONE","startTime":"2026-11-15T09:50:00Z","endTime":"2026-11-15T09:51:00Z","targetId":"pg-a"},
				{"operationType":"FAILOVER","status":"DONE","startTime":"2026-11-15T09:40:00Z","endTime":"2026-11-15T09:41:30Z","targetId":"pg-a","name":"op-1"}],
				"nextPageToken":"t2"}`))
			return
		}
		_, _ = w.Write([]byte(`{"items":[
			{"operationType":"FAILOVER","status":"RUNNING","startTime":"2026-11-15T09:30:00Z","targetId":"pg-a","name":"op-2"},
			{"operationType":"FAILOVER","status":"DONE","startTime":"2026-11-15T07:00:00Z","endTime":"2026-11-15T07:01:00Z","targetId":"pg-a","name":"op-old"}],
			"nextPageToken":"t3"}`))
	}))
	defer srv.Close()
	g := &GCPReader{HTTP: srv.Client(), AdminURL: srv.URL + "/sql", Now: func() time.Time { return now }}
	fs, err = g.Failovers(context.Background(), "p1", "pg-a")
	if err != nil {
		t.Fatal(err)
	}
	got := []string{}
	for _, f := range fs {
		if f.ResourceID != "p1:pg-a" || f.Source != "cloud sql operations" {
			t.Errorf("a failover row %+v", f)
		}
		got = append(got, f.Phase+"@"+f.At.Format("15:04:05"))
	}
	if strings.Join(got, ",") != "started@09:40:00,completed@09:41:30,started@09:30:00" {
		t.Errorf("Cloud SQL failovers %v, want op-1's start and end, op-2's start (RUNNING), no backup, nothing before 08:00", got)
	}
	if len(pages) != 2 {
		t.Errorf("%d operations.list pages read, want 2 (the second holds an operation older than the window)", len(pages))
	}
}
