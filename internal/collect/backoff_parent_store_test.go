package collect

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestParentHoldsThroughTheBackoffOnAStore (rn-l214 B-1, the lead's (a) of 21:19; the reviewer's repository fixture):
// one collector host reads 6 instances, each collection every minute; at t five of them stop answering together (a
// shared cause) while the sixth is read every minute on. The gate decides every tick (the real rule: connectBackoff,
// instanceConnectTimed, record, take - a held tick writes no load row), so the five write load rows only at their
// probe minutes, and each minute's beat goes through import_collector_beat as the heartbeat sends it (minute M at
// M+1:02). The 'instances failing together' parent (collector_parent, 0121) must still stand at t+20 and at t+30.
// With the window uncapped (15 minutes) the five dead spells fall behind the host's newest minute by more than its
// span + 3 minutes from about t+13 - the probes at t+12 and t+21 - and the parent ends: each instance's critical
// 'server unreachable' is then sent on its own, the storm the parent exists to stop.
func TestParentHoldsThroughTheBackoffOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	for _, after := range []int{20, 30} {
		t.Run(fmt.Sprintf("t+%d", after), func(t *testing.T) { parentAfterOutage(t, dsn, after, false) })
	}
	// the lead's 21:55: a mixed host - pg4 read every 2 minutes beside 1-minute instances - fails with them; its wait is
	// capped by the HOST's span, so it stays a member every minute: with its own interval's cap (2 + 2) its probes fall
	// 6 minutes apart (t+16, t+22, t+28 at its phase), behind the host's span + 3 minutes at t+22 and t+28, and the
	// parent holds 4 instances there, not 5 - so every minute from t+20 to t+30 is read, not the two ends alone
	for after := 20; after <= 30; after++ {
		t.Run(fmt.Sprintf("mixed t+%d", after), func(t *testing.T) { parentAfterOutage(t, dsn, after, true) })
	}
}

func parentAfterOutage(t *testing.T, dsn string, after int, mixed bool) {
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }() // nothing stays: the rows, spells and streaks go with the transaction
	// t: a whole minute, `after` minutes before the transaction's now() (the views read now(): t+after is now)
	var start time.Time
	if err := tx.QueryRow(ctx, `SELECT date_trunc('minute', now()) - make_interval(mins => $1)`, after).Scan(&start); err != nil {
		t.Fatal(err)
	}
	col := fmt.Sprintf("b1-%d-%d", after, time.Now().UnixNano()%1000000000)
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '2 hours', now())`, col); err != nil {
		t.Fatal(err)
	}
	h, restore := testHeartbeat()
	defer restore()
	const failing = 5 // pg0..pg4 fail from t; pg5 answers throughout
	names := make([]string, 6)
	every := make([]time.Duration, 6)
	for i := range names {
		names[i] = fmt.Sprintf("%s-pg%d", col, i)
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed')`, names[i]); err != nil {
			t.Fatal(err)
		}
		every[i] = time.Minute
		if mixed && i == 4 {
			every[i] = 2 * time.Minute
		}
		BackoffStart(names[i], every[i]) // sched's startInstance: the instance's shortest interval
	}
	// each instance's minute loop ticks at its own phase (sched's random first start); 5 minutes of health first
	type tick struct {
		at   time.Time
		inst int
	}
	var ticks []tick
	for i := range names {
		phase := time.Duration(3+7*i) * time.Second
		for at := start.Add(-6*time.Minute + phase); at.Before(start.Add(time.Duration(after) * time.Minute)); at = at.Add(every[i]) {
			ticks = append(ticks, tick{at, i})
		}
	}
	sort.Slice(ticks, func(a, b int) bool { return ticks[a].at.Before(ticks[b].at) })
	lost := errors.New("dial tcp 10.9.9.9:5432: connect: connection timed out")
	beatAt := start.Add(-6*time.Minute + time.Minute + 2*time.Second) // the beat of minute t-6
	beat := func(minute time.Time) {
		body, err := json.Marshal(h.take())
		if err != nil {
			t.Fatal(err)
		}
		var known bool
		if err := tx.QueryRow(ctx, `SELECT pgvigil.import_collector_beat($1, $2, $3::jsonb)`, col, minute, string(body)).Scan(&known); err != nil || !known {
			t.Fatalf("the beat of %v: known %v, %v", minute, known, err)
		}
	}
	probes := map[int][]int{} // instance: the minutes (from t) its failing connects were made in
	for _, k := range ticks {
		for !k.at.Before(beatAt) {
			beat(beatAt.Add(-time.Minute - 2*time.Second))
			beatAt = beatAt.Add(time.Minute)
		}
		name := names[k.inst]
		skip, note, release := ConnectBackoff(name, k.at)
		if skip {
			h.record(name, "postgres", "activity", Result{Note: note, Held: true}, k.at, every[k.inst])
			continue
		}
		done := k.at.Add(2 * time.Second) // the connect's answer (or its failure) two seconds in
		if k.inst < failing && !k.at.Before(start) {
			err := h.instanceConnectTimed(name, lost, done, 0)
			h.record(name, "postgres", "activity", Result{Err: err, Duration: 2 * time.Second}, done, every[k.inst])
			probes[k.inst] = append(probes[k.inst], int(k.at.Sub(start)/time.Minute))
		} else {
			_ = h.instanceConnectTimed(name, nil, done, 40*time.Millisecond)
			h.record(name, "postgres", "activity", Result{Rows: 12, Duration: 2 * time.Second}, done, every[k.inst])
		}
		if release != nil {
			release()
		}
	}
	for beatAt.Before(start.Add(time.Duration(after)*time.Minute + 3*time.Second)) { // the last whole minute's beat
		beat(beatAt.Add(-time.Minute - 2*time.Second))
		beatAt = beatAt.Add(time.Minute)
	}
	t.Logf("failing connects at the minutes (from t): pg0 %v, pg4 (every %v) %v", probes[0], every[4], probes[4])
	var why string
	var held int
	err = tx.QueryRow(ctx, `SELECT why, cardinality(instances) FROM pgvigil.collector_parent WHERE host = $1`, col).Scan(&why, &held)
	if errors.Is(err, pgx.ErrNoRows) {
		var spells string
		_ = tx.QueryRow(ctx, `SELECT string_agg(format('%s %s..%s', kind, to_char(since, 'HH24:MI'), to_char(last, 'HH24:MI')), '; ' ORDER BY instance_id, kind)
			FROM pgvigil.collector_spells WHERE host = $1 AND ended_at IS NULL`, col).Scan(&spells)
		t.Fatalf("at t+%d no 'collector or network' parent stands for the 5 instances failing together since t: their alerts go out one by one (open spells: %s)", after, spells)
	}
	if err != nil {
		t.Fatal(err)
	}
	if why != "instances failing together" || held != failing {
		t.Errorf("at t+%d the parent is %q holding %d instance(s); want 'instances failing together' holding %d", after, why, held, failing)
	}
}
