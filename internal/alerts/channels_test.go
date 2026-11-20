package alerts

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// task 403b: a 429's Retry-After (PerformanceMonitor Fixed 28).

func TestRetryAfter(t *testing.T) {
	now := time.Date(2026, 11, 15, 8, 0, 0, 0, time.UTC)
	cases := []struct {
		h    string
		want time.Duration
		ok   bool
	}{
		{"2", 2 * time.Second, true},
		{" 10 ", 10 * time.Second, true},
		{"0", 0, true},
		{"11", 11 * time.Second, false},
		{"9223372037", 0, false},  // n seconds overflows time.Duration: refused, never a negative (immediate) wait
		{"10000000000", 0, false}, // far past the overflow: refused the same way
		{"", 0, false},
		{"-1", 0, false},
		{"soon", 0, false},
		{now.Add(5 * time.Second).Format(http.TimeFormat), 5 * time.Second, true},
		{now.Add(60 * time.Second).Format(http.TimeFormat), 60 * time.Second, false},
		{now.Add(-time.Minute).Format(http.TimeFormat), 0, true},
	}
	for _, c := range cases {
		d, ok := retryAfter(c.h, now)
		if ok != c.ok || (c.ok && d != c.want) {
			t.Errorf("Retry-After %q: %s %v, want %s %v", c.h, d, ok, c.want, c.ok)
		}
	}
}

func TestWebhookRetryAfter(t *testing.T) {
	var waited []time.Duration
	old := retryWait
	retryWait = func(_ context.Context, d time.Duration) error { waited = append(waited, d); return nil }
	t.Cleanup(func() { retryWait = old })
	cases := []struct {
		name    string
		answers []string // per post: "429:<Retry-After>" or "200"
		posts   int
		ok      bool
		errHas  string
		waits   int
	}{
		{"2 s waited, posted once more", []string{"429:2", "200"}, 2, true, "", 1},
		{"30 s not waited", []string{"429:30", "200"}, 1, false, "more than the 10s a send waits", 0},
		{"no Retry-After", []string{"429:", "200"}, 1, false, "no Retry-After", 0},
		{"a second 429 fails", []string{"429:1", "429:1", "200"}, 2, false, "after waiting out a Retry-After of 1s", 1},
		{"a 500 is not retried", []string{"500", "200"}, 1, false, "500", 0},
	}
	for _, c := range cases {
		waited = nil
		var mu sync.Mutex
		var bodies []string
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			b, _ := io.ReadAll(r.Body)
			mu.Lock()
			n := len(bodies)
			bodies = append(bodies, string(b))
			mu.Unlock()
			a := c.answers[min(n, len(c.answers)-1)]
			switch {
			case strings.HasPrefix(a, "429:"):
				if v := strings.TrimPrefix(a, "429:"); v != "" {
					w.Header().Set("Retry-After", v)
				}
				w.WriteHeader(http.StatusTooManyRequests)
			case a == "500":
				w.WriteHeader(http.StatusInternalServerError)
			}
		}))
		err := webhookFor(t, srv.URL+"/hook/secret-token", "slack").send(context.Background(), msg(crit))
		srv.Close()
		if (err == nil) != c.ok || (c.errHas != "" && (err == nil || !strings.Contains(err.Error(), c.errHas))) {
			t.Errorf("%s: err %v, want ok %v containing %q", c.name, err, c.ok, c.errHas)
		}
		if err != nil && strings.Contains(err.Error(), "secret-token") {
			t.Errorf("%s: the error shows the URL's token: %v", c.name, err)
		}
		if len(bodies) != c.posts {
			t.Errorf("%s: %d posts, want %d", c.name, len(bodies), c.posts)
		}
		if len(bodies) == 2 && bodies[0] != bodies[1] {
			t.Errorf("%s: the second post's body differs from the first", c.name)
		}
		if len(waited) != c.waits {
			t.Errorf("%s: waited %v, want %d wait(s)", c.name, waited, c.waits)
		}
	}
}

func TestRetryWaitEndsWithTheSend(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := retryWait(ctx, 5*time.Second); err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("retryWait past the send's deadline: err %v after %s, want the context's error at once", err, time.Since(start))
	}
}

// task 403b: the 'alert channel failing' alert goes on every channel but the one it names.
func TestFailingChannel(t *testing.T) {
	own := Alert{Event: "firing", Source: "pgvigil repository", Setting: "alert channel failing", Value: "dba-mail"}
	if got := own.failingChannel(); got != "dba-mail" {
		t.Fatalf("failingChannel %q, want dba-mail", got)
	}
	for _, a := range []Alert{
		{Source: "pgvigil repository", Setting: "collector or network", Value: "dba-mail"},
		{Source: "alert rule", Setting: "alert channel failing", Value: "dba-mail"},
		crit,
	} {
		if got := a.failingChannel(); got != "" {
			t.Errorf("%s / %s: failingChannel %q, want none", a.Source, a.Setting, got)
		}
	}
}

// the kinds are read out of alert_channels_kind_check's definition as pg_get_constraintdef prints it.
func TestStoreKindRE(t *testing.T) {
	def := `CHECK ((kind = ANY (ARRAY['smtp'::text, 'webhook'::text, 'file'::text, 'pagerduty'::text, 'opsgenie'::text])))`
	var got []string
	for _, m := range storeKindRE.FindAllStringSubmatch(def, -1) {
		got = append(got, m[1])
	}
	if strings.Join(got, ",") != "smtp,webhook,file,pagerduty,opsgenie" {
		t.Errorf("kinds %v", got)
	}
}
