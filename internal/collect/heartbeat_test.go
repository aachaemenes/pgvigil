package collect

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

type msErr struct{ n int32 }

func (e msErr) Error() string         { return fmt.Sprintf("mssql: %d", e.n) }
func (e msErr) SQLErrorNumber() int32 { return e.n }

func TestAuthFailure(t *testing.T) {
	for _, c := range []struct {
		err  error
		want bool
	}{
		{&pgconn.PgError{Code: "28P01"}, true},
		{fmt.Errorf("connect: %w", &pgconn.PgError{Code: "28000"}), true},
		{&pgconn.PgError{Code: "57014"}, false},
		{msErr{18456}, true},
		{fmt.Errorf("login: %w", msErr{18456}), true},
		{msErr{4060}, false},
		{errors.New("dial tcp: connection refused"), false},
		{nil, false},
	} {
		if got := AuthFailure(c.err); got != c.want {
			t.Errorf("AuthFailure(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

func TestBucket(t *testing.T) {
	for d, want := range map[time.Duration]int{0: 0, 500 * time.Microsecond: 0, time.Millisecond: 1, 3 * time.Millisecond: 2,
		4 * time.Millisecond: 3, time.Second: 10, 200 * time.Second: histBuckets - 1} {
		if got := bucket(d); got != want {
			t.Errorf("bucket(%v) = %d, want %d", d, got, want)
		}
	}
}

// TestRecordTake: a minute's runs per collection and per instance, a skipped run counted as a connection only, the
// failed runs in a row kept across takes and sent when they change.
func TestRecordTake(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	now := time.Now()
	h.record("t1", "postgres", "activity", Result{Rows: 5, Duration: 3 * time.Millisecond}, now)
	h.record("t1", "postgres", "activity", Result{Duration: 20 * time.Millisecond, Err: &pgconn.PgError{Code: "28P01"}}, now)
	h.record("t1", "postgres", "logs", Result{Note: " (skipped: no log door)"}, now)
	h.record("t2", "sqlserver", "activity", Result{Rows: 2, Duration: time.Millisecond}, now)
	b := h.take()
	if len(b.Runs) != 2 || len(b.Load) != 2 || b.Instances != 2 {
		t.Fatalf("take: runs %d, load %d, instances %d", len(b.Runs), len(b.Load), b.Instances)
	}
	for _, r := range b.Runs {
		if r.Engine == "postgres" && (r.Runs != 2 || r.Failures != 1 || r.Rows != 5 || r.DurMax != 20 || r.Hist[2] != 1 || r.Hist[5] != 1) {
			t.Errorf("postgres activity: %+v", r)
		}
	}
	for _, l := range b.Load {
		if l.Instance == "t1" && (l.Connections != 3 || l.Runs != 2 || l.Failures != 1 || l.Auth != 1) {
			t.Errorf("t1 load: %+v", l)
		}
	}
	if len(b.Streaks) != 1 || b.Streaks[0].Instance != "t1" || b.Streaks[0].Fails != 1 {
		t.Errorf("streaks: %+v", b.Streaks)
	}
	// the next minute: nothing new, nothing sent; a success after the failure resets and is sent once
	if b2 := h.take(); len(b2.Runs) != 0 || len(b2.Streaks) != 0 {
		t.Errorf("an empty minute sent %+v", b2)
	}
	h.record("t1", "postgres", "activity", Result{Rows: 1}, now)
	if b3 := h.take(); len(b3.Streaks) != 1 || b3.Streaks[0].Fails != 0 {
		t.Errorf("the reset: %+v", b3.Streaks)
	}
	h.record("t1", "postgres", "activity", Result{Rows: 1}, now)
	if b4 := h.take(); len(b4.Streaks) != 0 {
		t.Errorf("a success after a success was sent: %+v", b4.Streaks)
	}
}
