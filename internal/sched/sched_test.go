package sched

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// fakeInv is the repository's page list: a generation, the list, a failing read.
type fakeInv struct {
	mu   sync.Mutex
	gen  int64
	list []config.PageInstance
	fail bool
}

func (f *fakeInv) InventoryGeneration(context.Context) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		return 0, errors.New("the repository is down")
	}
	return f.gen, nil
}

func (f *fakeInv) Inventory(context.Context) ([]config.PageInstance, int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail {
		return nil, 0, errors.New("the repository is down")
	}
	return slices.Clone(f.list), f.gen, nil
}

func (f *fakeInv) set(fn func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	fn()
	f.gen++
}

// event is one loop's start or end, in order.
type event struct {
	kind, name, dsn string
}

// syncBuf is a log sink the test reads while the watcher writes.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

type rig struct {
	t      *testing.T
	mu     sync.Mutex
	events []event
	live   map[string]string // name -> the dsn its running loop has
	logs   *syncBuf
	held   bool
}

// start is the scheduler's start func: one loop per instance that records its start, waits for its stop, takes a
// moment as a cancelled run's last write does, and records its end.
func (r *rig) start(ctx context.Context, in config.Instance, wg *sync.WaitGroup) int {
	r.mu.Lock()
	r.events = append(r.events, event{"start", in.Name, in.DSNRaw})
	r.live[in.Name] = in.DSNRaw
	r.mu.Unlock()
	wg.Add(1)
	go func() {
		defer wg.Done()
		<-ctx.Done()
		time.Sleep(30 * time.Millisecond)
		r.mu.Lock()
		r.events = append(r.events, event{"end", in.Name, in.DSNRaw})
		if r.live[in.Name] == in.DSNRaw {
			delete(r.live, in.Name)
		}
		r.mu.Unlock()
	}()
	return 1
}

func (r *rig) hold(context.Context) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.held, nil
}

func (r *rig) setHeld(v bool) {
	r.mu.Lock()
	r.held = v
	r.mu.Unlock()
}

// until waits for cond (2 s at most).
func (r *rig) until(what string, cond func(live map[string]string) bool) {
	r.t.Helper()
	for i := 0; i < 200; i++ {
		r.mu.Lock()
		ok := cond(r.live)
		r.mu.Unlock()
		if ok {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.t.Fatalf("%s: live %v, events %v\nlog:\n%s", what, r.live, r.events, r.logs.String())
}

func names(live map[string]string) string {
	var n []string
	for k := range live {
		n = append(n, k)
	}
	slices.Sort(n)
	return strings.Join(n, " ")
}

// Add, change, disable, remove, a failed read and another collector holding the page's instances, through the
// real watcher and apply over a fake repository.
func TestApplyFollowsThePageList(t *testing.T) {
	inv := &fakeInv{gen: 1, list: []config.PageInstance{{Name: "p1", Engine: config.EnginePostgres, DSNRef: "file:/i/p1-a.dsn"}}}
	r := &rig{t: t, live: map[string]string{}, logs: &syncBuf{}, held: true}
	log := slog.New(slog.NewTextHandler(r.logs, nil))
	s := newScheduler(log, 2*time.Second, r.start)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	file := []config.Instance{{Name: "f1", Engine: config.EnginePostgres, DSNRaw: "env:F1"}}
	go func() {
		config.WatchInventory(ctx, log, inv, r.hold, file, "full", 20*time.Millisecond, func(all []config.Instance) { s.apply(ctx, all) })
		s.wait()
		close(done)
	}()
	r.until("the first list", func(l map[string]string) bool { return names(l) == "f1 p1" })

	// add
	inv.set(func() {
		inv.list = append(inv.list, config.PageInstance{Name: "p2", Engine: config.EnginePostgres, DSNRef: "file:/i/p2-a.dsn"})
	})
	r.until("an add", func(l map[string]string) bool { return names(l) == "f1 p1 p2" })

	// change: p1's new credential file; its old loop ends before its new one starts
	inv.set(func() { inv.list[0].DSNRef = "file:/i/p1-b.dsn" })
	r.until("a change", func(l map[string]string) bool { return l["p1"] == "file:/i/p1-b.dsn" })
	r.mu.Lock()
	endOld, startNew := -1, -1
	for i, e := range r.events {
		switch {
		case e.kind == "end" && e.name == "p1" && e.dsn == "file:/i/p1-a.dsn":
			endOld = i
		case e.kind == "start" && e.name == "p1" && e.dsn == "file:/i/p1-b.dsn":
			startNew = i
		}
	}
	r.mu.Unlock()
	if endOld < 0 || startNew < 0 || endOld > startNew {
		t.Fatalf("the changed instance's new loop started before its old one ended (end %d, start %d): %v", endOld, startNew, r.events)
	}

	// disable
	inv.set(func() { inv.list[1].Disabled = true })
	r.until("a disable", func(l map[string]string) bool { return names(l) == "f1 p1" })

	// remove
	inv.set(func() { inv.list = inv.list[1:] })
	r.until("a remove", func(l map[string]string) bool { return names(l) == "f1" })

	// a failed read keeps the last list, said once
	inv.set(func() {
		inv.list = append(inv.list, config.PageInstance{Name: "p3", Engine: config.EnginePostgres, DSNRef: "file:/i/p3-a.dsn"})
		inv.fail = true
	})
	time.Sleep(150 * time.Millisecond)
	r.mu.Lock()
	got := names(r.live)
	r.mu.Unlock()
	if got != "f1" {
		t.Fatalf("a failed read changed the list: %s", got)
	}
	if n := strings.Count(r.logs.String(), "could not be read"); n != 1 {
		t.Fatalf("the failed read was logged %d times (want once)", n)
	}
	inv.set(func() { inv.fail = false })
	r.until("the read back", func(l map[string]string) bool { return names(l) == "f1 p3" })

	// another collector holds the page's instances: the file's only, said once; back when the lock is free again
	r.setHeld(false)
	r.until("the lock lost", func(l map[string]string) bool { return names(l) == "f1" })
	time.Sleep(100 * time.Millisecond)
	if n := strings.Count(r.logs.String(), "another collector holds the page's instances"); n != 1 {
		t.Fatalf("another holder was logged %d times (want once)", n)
	}
	r.setHeld(true)
	r.until("the lock back", func(l map[string]string) bool { return names(l) == "f1 p3" })

	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("Run's loops did not end after the cancel")
	}
}

// A changed instance whose old loop never ends starts anyway after the wait, with a warning.
func TestApplyWaitIsBounded(t *testing.T) {
	logs := &syncBuf{}
	stuck := make(chan struct{})
	defer close(stuck)
	starts := 0
	s := newScheduler(slog.New(slog.NewTextHandler(logs, nil)), 50*time.Millisecond, func(_ context.Context, _ config.Instance, wg *sync.WaitGroup) int {
		starts++
		wg.Add(1)
		go func() { defer wg.Done(); <-stuck }()
		return 1
	})
	ctx := context.Background()
	s.apply(ctx, []config.Instance{{Name: "a", DSNRaw: "x"}})
	t0 := time.Now()
	s.apply(ctx, []config.Instance{{Name: "a", DSNRaw: "y"}})
	if d := time.Since(t0); starts != 2 || d < 50*time.Millisecond || d > time.Second {
		t.Fatalf("starts %d after %v (want 2 after about 50 ms)", starts, d)
	}
	if !strings.Contains(logs.String(), "did not end in time") {
		t.Fatalf("no warning: %s", logs.String())
	}
}
