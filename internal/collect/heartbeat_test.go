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

// TestRecordTake: a minute's runs per collection and per instance (a skipped run not counted), the connects counted
// at the connect (an opened one, a refused login, a per-database connect), the failed runs in a row kept across takes
// and sent when they change.
func TestRecordTake(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	current.Store(h)
	defer current.Store(nil)
	now := time.Now()
	CountConnect("t1", nil)
	h.record("t1", "postgres", "activity", Result{Rows: 5, Duration: 3 * time.Millisecond}, now)
	CountConnect("t1", fmt.Errorf("connect t1: %w", &pgconn.PgError{Code: "28P01"}))
	h.record("t1", "postgres", "activity", Result{Duration: 20 * time.Millisecond, Err: errors.New("connect t1: refused")}, now)
	CountConnect("t1", nil)                            // the run of tables
	CountConnect("t1", &pgconn.PgError{Code: "28000"}) // its per-database connect refused by pg_hba
	h.record("t1", "postgres", "logs", Result{Note: " (skipped: no log door)"}, now)
	CountConnect("t2", nil)
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
		if l.Instance == "t1" && (l.Attempts != 4 || l.Opened != 2 || l.Auth != 2 || l.Runs != 2 || l.Failures != 1) {
			t.Errorf("t1 load: %+v", l)
		}
		if l.Instance == "t2" && (l.Attempts != 1 || l.Opened != 1 || l.Auth != 0 || l.Runs != 1) {
			t.Errorf("t2 load: %+v", l)
		}
	}
	// t1's failure, and t2's first result since the start (fresh: sent once, 0)
	sk := map[string]int{}
	for _, x := range b.Streaks {
		sk[x.Instance] = x.Fails
	}
	if len(b.Streaks) != 2 || sk["t1"] != 1 || sk["t2"] != 0 {
		t.Errorf("streaks: %+v", b.Streaks)
	}
	// the next minute: nothing new, nothing sent; a success after the failure resets and is sent once
	if b2 := h.take(); len(b2.Runs) != 0 || len(b2.Streaks) != 0 || len(b2.Load) != 0 {
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

// TestNoHeartbeat: without StartHeartbeat (pgvigil collect, a test) counting is a no-op.
func TestNoHeartbeat(t *testing.T) {
	current.Store(nil)
	CountConnect("t1", nil)
	RecordRun("t1", "postgres", "activity", Result{})
}

// TestStreakAfterRestart: a streak loaded from the repository (5 failed in a row before a restart) - the first success
// after the start resets it and is sent; a first failure counts on from 5.
func TestStreakAfterRestart(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{
		{"t1", "activity"}: {fails: 5, fresh: true}, {"t1", "dbstats"}: {fails: 5, fresh: true}}}
	now := time.Now()
	h.record("t1", "postgres", "activity", Result{Rows: 1}, now)
	h.record("t1", "postgres", "dbstats", Result{Err: errors.New("down")}, now)
	h.record("t2", "postgres", "activity", Result{Rows: 1}, now) // never failed: its first result is sent once (0)
	got := map[string]int{}
	for _, s := range h.take().Streaks {
		got[s.Instance+"/"+s.Collection] = s.Fails
	}
	if len(got) != 3 || got["t1/activity"] != 0 || got["t1/dbstats"] != 6 || got["t2/activity"] != 0 {
		t.Errorf("after the restart: %v", got)
	}
	h.record("t2", "postgres", "activity", Result{Rows: 1}, now)
	if b := h.take(); len(b.Streaks) != 0 {
		t.Errorf("a second success was sent: %+v", b.Streaks)
	}
}
