package cloudrepl

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// P2 (task 390b): a Cloud SQL for PostgreSQL instance's topology from the Cloud SQL Admin API (instances.get:
// masterInstanceName, replicaNames, state), and from Cloud Monitoring (timeSeries.list) each replica's
// database/replication/replica_lag (s) and replication/state (Running / Stopped / Error) on the REPLICA's
// cloudsql_database resource, and database/postgresql/replication/replica_byte_lag (replay_location) on the PRIMARY's
// per replica_name; a 15-minute window; every page; a refused Monitoring call keeps the topology with its sentence; a
// 429 is *Throttled.
func TestGCPReplicas(t *testing.T) {
	var mu sync.Mutex
	var filters []string
	monStatus := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/sql/v1/projects/p1/instances/pg-a":
			_, _ = w.Write([]byte(`{"name":"pg-a","project":"p1","region":"us-central1","databaseVersion":"POSTGRES_16","state":"RUNNABLE",
				"instanceType":"CLOUD_SQL_INSTANCE","replicaNames":["pg-a-r1"]}`))
		case "/sql/v1/projects/p1/instances/pg-a-r1":
			_, _ = w.Write([]byte(`{"name":"pg-a-r1","project":"p1","region":"us-central1","databaseVersion":"POSTGRES_16","state":"RUNNABLE",
				"instanceType":"READ_REPLICA_INSTANCE","masterInstanceName":"p1:pg-a"}`))
		case "/mon/v3/projects/p1/timeSeries":
			if monStatus != http.StatusOK {
				if monStatus == http.StatusTooManyRequests {
					w.Header().Set("Retry-After", "60")
				}
				w.WriteHeader(monStatus)
				_, _ = w.Write([]byte(`{"error":{"code":403,"message":"Permission monitoring.timeSeries.list denied","status":"PERMISSION_DENIED"}}`))
				return
			}
			f := r.URL.Query().Get("filter")
			filters = append(filters, f)
			if r.URL.Query().Get("interval.startTime") == "" || r.URL.Query().Get("interval.endTime") == "" {
				t.Errorf("a timeSeries.list without its interval: %s", r.URL.RawQuery)
			}
			switch {
			case strings.Contains(f, `database/replication/replica_lag"`) && r.URL.Query().Get("pageToken") == "":
				_, _ = w.Write([]byte(`{"timeSeries":[{"resource":{"type":"cloudsql_database","labels":{"database_id":"p1:pg-a-r1"}},
					"points":[{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"doubleValue":1.5}}]}],"nextPageToken":"t2"}`))
			case strings.Contains(f, `database/replication/replica_lag"`):
				_, _ = w.Write([]byte(`{"timeSeries":[{"resource":{"type":"cloudsql_database","labels":{"database_id":"p1:pg-a-r1"}},
					"points":[{"interval":{"endTime":"2026-11-14T09:57:00Z"},"value":{"doubleValue":2.5}}]}]}`))
			case strings.Contains(f, `database/replication/state"`):
				_, _ = w.Write([]byte(`{"timeSeries":[{"metric":{"labels":{"state":"Running"}},"resource":{"labels":{"database_id":"p1:pg-a-r1"}},
					"points":[{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"boolValue":true}}]},
					{"metric":{"labels":{"state":"Stopped"}},"resource":{"labels":{"database_id":"p1:pg-a-r1"}},
					"points":[{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"boolValue":false}}]}]}`))
			case strings.Contains(f, `replica_byte_lag"`):
				_, _ = w.Write([]byte(`{"timeSeries":[{"metric":{"labels":{"replica_name":"pg-a-r1","replica_lag_type":"replay_location"}},
					"resource":{"labels":{"database_id":"p1:pg-a"}},"points":[{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"int64Value":"4096"}}]},
					{"metric":{"labels":{"replica_name":"pg-a-r1","replica_lag_type":"sent_location"}},
					"resource":{"labels":{"database_id":"p1:pg-a"}},"points":[{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"int64Value":"10"}}]}]}`))
			default:
				_, _ = w.Write([]byte(`{}`))
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	now := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC)
	g := &GCPReader{HTTP: srv.Client(), AdminURL: srv.URL + "/sql", MonitoringURL: srv.URL + "/mon", Now: func() time.Time { return now }}
	res, pts, notes, err := g.Read(context.Background(), "p1", "pg-a")
	if err != nil || len(notes) != 0 {
		t.Fatalf("Read pg-a: %v %v", err, notes)
	}
	byID := map[string]Resource{}
	for _, x := range res {
		byID[x.ID] = x
	}
	if a := byID["p1:pg-a"]; a.Role != "source" || strings.Join(a.ReplicaIDs, ",") != "p1:pg-a-r1" || a.Provider != "gcp" || a.Engine != "POSTGRES_16" || a.Status != "RUNNABLE" {
		t.Errorf("pg-a: %+v", a)
	}
	if r1 := byID["p1:pg-a-r1"]; r1.Role != "replica" || r1.SourceID != "p1:pg-a" || r1.ReplStatus != "Running" || r1.Region != "us-central1" {
		t.Errorf("pg-a-r1: %+v", r1)
	}
	lag, bytes := 0, 0
	for _, p := range pts {
		switch {
		case p.Metric == "replica_lag" && p.ResourceID == "p1:pg-a-r1" && p.Unit == "s":
			lag++
		case p.Metric == "replica_byte_lag" && p.ResourceID == "p1:pg-a-r1" && p.Unit == "bytes" && p.Value == 4096:
			bytes++
		default:
			t.Errorf("a point %+v", p)
		}
	}
	if lag != 2 || bytes != 1 {
		t.Errorf("points: %d lag (want 2: two pages), %d byte lag (want 1: replay_location only)", lag, bytes)
	}
	for _, want := range []string{`resource.labels.database_id = "p1:pg-a-r1"`, `resource.labels.database_id = "p1:pg-a"`} {
		found := false
		for _, f := range filters {
			if strings.Contains(f, want) && strings.Contains(f, `metric.type = "cloudsql.googleapis.com/`) {
				found = true
			}
		}
		if !found {
			t.Errorf("no timeSeries filter holds %q: %q", want, filters)
		}
	}
	// the replica's own read: its source and its own lag
	res, pts, _, err = g.Read(context.Background(), "p1", "pg-a-r1")
	if err != nil || len(res) != 2 || len(pts) < 2 {
		t.Errorf("Read pg-a-r1: %v, %d resources, %d points", err, len(res), len(pts))
	}
	// a refused Monitoring call: the topology stands, the sentence names the right
	monStatus = http.StatusForbidden
	res, pts, notes, err = g.Read(context.Background(), "p1", "pg-a")
	if err != nil || len(res) != 2 || len(pts) != 0 || len(notes) == 0 || !strings.Contains(notes[0], "monitoring.timeSeries.list") {
		t.Errorf("a refused Monitoring call: %v, %d resources, %d points, notes %q", err, len(res), len(pts), notes)
	}
	monStatus = http.StatusTooManyRequests
	if _, _, _, err = g.Read(context.Background(), "p1", "pg-a"); !errors.As(err, new(*Throttled)) {
		t.Errorf("a 429: %v, want *Throttled", err)
	}
}
