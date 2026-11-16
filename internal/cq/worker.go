package cq

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"os"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The worker's clock: the lease is renewed every beatEvery (0200 keeps a worker live 45 s, a run's lease 25 s); the
// poll that claims and reads cancels runs every pollEvery whether or not LISTEN works (a transaction-mode pooler drops
// it); perInstance requests at most run on one instance (the urgent kinds aside); stopWait bounds a clean stop.
const (
	beatEvery   = 15 * time.Second
	pollEvery   = 5 * time.Second
	listenRetry = 5 * time.Second
	perInstance = 2
	stopWait    = 10 * time.Second
	callTimeout = 15 * time.Second
	// publishEvery: the facts a page reads instead of asking per view (the community tools present and their
	// parameters) are published at start, at each change of the held set and this often
	publishEvery   = 10 * time.Minute
	publishTimeout = 60 * time.Second
	publishAtOnce  = 4
	stopCall       = 5 * time.Second
)

// StopBudget is how long the worker's stop may take (each run ended within stopWait, then the lease ended within
// stopCall), with a margin: `pgvigil run` waits this long for it before it exits.
const StopBudget = stopWait + stopCall + 3*time.Second

// NoNUL returns a JSON text with every \u0000 escape replaced by � (both six bytes): PostgreSQL's jsonb and text
// refuse U+0000 (22P05), and a SQL Server text cell may hold NCHAR(0). Every backslash of valid JSON starts an escape
// pair, so stepping over the pairs never mistakes an escaped backslash followed by "u0000" for the escape.
func NoNUL(b []byte) []byte {
	if !bytes.Contains(b, []byte(`\u0000`)) {
		return b
	}
	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); i++ {
		if b[i] != '\\' || i+1 >= len(b) {
			out = append(out, b[i])
			continue
		}
		if b[i+1] == 'u' && i+5 < len(b) && string(b[i+2:i+6]) == "0000" {
			out = append(out, `�`...)
			i += 5
			continue
		}
		out = append(out, b[i], b[i+1])
		i++
	}
	return out
}

// Publisher publishes one held instance's facts into the repository (S5: a page reads them, never a request per view).
type Publisher func(ctx context.Context, env *Env) error

var (
	pubMu      sync.Mutex
	publishers []Publisher
)

// RegisterPublisher adds a publisher; a part of the build calls it from its own file's init.
func RegisterPublisher(p Publisher) {
	pubMu.Lock()
	defer pubMu.Unlock()
	publishers = append(publishers, p)
}

// publish runs every publisher on every held instance, publishAtOnce at a time, each under publishTimeout.
func (w *Worker) publish(ctx context.Context) {
	pubMu.Lock()
	ps := slices.Clone(publishers)
	pubMu.Unlock()
	if len(ps) == 0 {
		return
	}
	w.mu.Lock()
	held := make([]config.Instance, 0, len(w.held))
	for _, in := range w.held {
		held = append(held, in)
	}
	w.mu.Unlock()
	sem := make(chan struct{}, publishAtOnce)
	var wg sync.WaitGroup
	for _, in := range held {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			env := w.env(in)
			for _, p := range ps {
				w.publishOne(ctx, p, &env)
			}
		}()
	}
	wg.Wait()
}

// publishOne runs one publisher on one instance under publishTimeout; a panic in it is logged, never the collector's
// end (the lifted community code ran under net/http's recover before).
func (w *Worker) publishOne(ctx context.Context, p Publisher, env *Env) {
	cctx, cancel := context.WithTimeout(ctx, publishTimeout)
	defer cancel()
	defer func() {
		if v := recover(); v != nil {
			w.log.Error("request queue: a publisher panicked", "instance", env.Instance.Name, "panic", v)
		}
	}()
	if err := p(cctx, env); err != nil {
		w.log.Warn("request queue: a publisher failed", "instance", env.Instance.Name, "err", err)
	}
}

// Source is what the worker reads its held instances from: the repository (the page's list), as the scheduler does.
type Source = config.InventoryReader

// Worker is one collector's request worker.
type Worker struct {
	log    *slog.Logger
	cfg    *config.Config
	pool   *pgxpool.Pool
	id     string
	host   string
	prefix string // this process's page-lease holder prefix: "<host>:<pid>:"

	mu      sync.Mutex
	held    map[string]config.Instance
	running map[int64]*run
	regular int            // running requests in the regular slots
	byInst  map[string]int // running requests per instance (regular kinds)
	wake    chan struct{}
	runs    sync.WaitGroup
}

type run struct {
	req       Request
	cancel    context.CancelFunc
	cancelled bool
	why       string // the words of a cancel: the asker's, or the collector's stop
	urgent    bool
}

// Run is `pgvigil run`'s request worker: it returns at once when cq.enabled is off (one line in the log), else it
// blocks until ctx ends, then stops: no new claim, each running request cancelled and ended, the lease ended at once.
func Run(ctx context.Context, log *slog.Logger, cfg *config.Config, src Source) error {
	if !cfg.CQ.Enabled {
		log.Info("request queue off on this collector (cq.enabled in pgvigil.yaml)")
		return nil
	}
	pc, err := pgxpool.ParseConfig(cfg.Repository.DSN())
	if err != nil {
		return fmt.Errorf("cq: %w", err)
	}
	pc.MaxConns = int32(cfg.CQ.Workers + 3)
	pc.ConnConfig.RuntimeParams["application_name"] = "pgvigil-cq"
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return fmt.Errorf("cq: %w", err)
	}
	defer pool.Close()
	host, _ := os.Hostname()
	w := &Worker{log: log, cfg: cfg, pool: pool, host: host,
		id:     fmt.Sprintf("%s/%d/%d", host, os.Getpid(), time.Now().UnixNano()),
		prefix: fmt.Sprintf("%s:%d:", host, os.Getpid()),
		held:   map[string]config.Instance{}, running: map[int64]*run{}, byInst: map[string]int{}, wake: make(chan struct{}, 1)}
	return w.loop(ctx, src)
}

func (w *Worker) loop(ctx context.Context, src Source) error {
	w.log.Info("request queue on", "collector", w.id, "workers", w.cfg.CQ.Workers, "kinds", registered())
	applied := make(chan struct{}, 1)
	go config.WatchInventory(ctx, w.log, src, w.pageHeld, w.cfg.Instances, w.cfg.QueryText, w.cfg.MSSQLCounters, 15*time.Second, func(all []config.Instance) {
		w.setHeld(all)
		select {
		case applied <- struct{}{}:
		default:
		}
	})
	go w.listen(ctx)
	beat := time.NewTicker(beatEvery)
	defer beat.Stop()
	poll := time.NewTicker(pollEvery)
	defer poll.Stop()
	pub := time.NewTicker(publishEvery)
	defer pub.Stop()
	publishing := make(chan struct{}, 1) // one publish pass at a time
	publishNow := func() {
		select {
		case publishing <- struct{}{}:
			go func() { defer func() { <-publishing }(); w.publish(ctx) }()
		default:
		}
	}
	w.beat(ctx)
	for {
		select {
		case <-ctx.Done():
			w.stop()
			return nil
		case <-applied:
			w.heldChanged(ctx)
			w.claim(ctx)
			publishNow()
		case <-pub.C:
			w.publishDoorsNow(ctx) // the doors too: a page credential that resolves now, a row lost from the store
			publishNow()
		case <-beat.C:
			w.beat(ctx)
		case <-poll.C:
			w.cancels(ctx)
			w.claim(ctx)
		case <-w.wake:
			w.cancels(ctx)
			w.claim(ctx)
		}
	}
}

// pageHeld: the page's instances are this worker's while its own process's scheduler holds the page lease.
func (w *Worker) pageHeld(ctx context.Context) (bool, error) {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	var held bool
	err := w.pool.QueryRow(cctx, `SELECT pgvigil.import_cq_page_held($1)`, w.prefix).Scan(&held)
	return held, err
}

// setHeld takes the instances held now (from the inventory's goroutine); the loop then calls heldChanged.
func (w *Worker) setHeld(all []config.Instance) {
	held := make(map[string]config.Instance, len(all))
	for _, in := range all {
		held[in.Name] = in
	}
	w.mu.Lock()
	w.held = held
	w.mu.Unlock()
}

// heldChanged renews the lease with the held set, then publishes its doors, in that order and from the loop's
// goroutine: a door row references its worker's lease row (0200's foreign key), so doors sent before the worker's first
// beat are refused, and a refused publish waits for publishEvery.
func (w *Worker) heldChanged(ctx context.Context) {
	w.beat(ctx)
	w.publishDoorsNow(ctx)
}

// publishDoorsNow publishes the doors of the instances held now (at each change of the held set and every
// publishEvery).
func (w *Worker) publishDoorsNow(ctx context.Context) {
	w.mu.Lock()
	held := maps.Clone(w.held)
	w.mu.Unlock()
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	if err := publishDoors(cctx, w.pool, w.id, doorRows(w.env(config.Instance{}), held)); err != nil {
		w.log.Warn("request queue: the doors were not published", "err", err)
	}
}

func (w *Worker) env(in config.Instance) Env {
	return Env{Log: w.log, Cfg: w.cfg, Instance: in, Repo: w.pool, CollectorID: w.id, Host: w.host}
}

func (w *Worker) heldNames() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	names := make([]string, 0, len(w.held))
	for n := range w.held {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// runningIDs is the ids of the requests this worker runs now (the beat renews these alone).
func (w *Worker) runningIDs() []int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	ids := make([]int64, 0, len(w.running))
	for id := range w.running {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	return ids
}

// beat renews the lease (its instances now) and the lease of the runs it still holds in memory - a row whose finish
// failed, or a claimed row never started, is not renewed and goes 'lost' at the sweep; the ids it returns are cancels
// asked. Every beat comes from the loop's goroutine, after a claim's starts: a claimed row is in w.running by then.
func (w *Worker) beat(ctx context.Context) {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	rows, err := w.pool.Query(cctx, `SELECT * FROM pgvigil.import_cq_beat($1, $2, $3, $4)`, w.id, w.host, w.heldNames(), w.runningIDs())
	if err != nil {
		w.log.Warn("request queue: the lease was not renewed", "err", err)
		return
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		w.log.Warn("request queue: the lease was not renewed", "err", err)
		return
	}
	w.cancelIDs(ids)
}

// cancels: the poll's read of the cancels asked of this worker's running rows (the notify may never come).
func (w *Worker) cancels(ctx context.Context) {
	w.mu.Lock()
	n := len(w.running)
	w.mu.Unlock()
	if n == 0 {
		return
	}
	w.beat(ctx)
}

func (w *Worker) cancelIDs(ids []int64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, id := range ids {
		if r, ok := w.running[id]; ok && !r.cancelled {
			r.cancelled, r.why = true, "cancelled by its asker while it ran"
			r.cancel()
		}
	}
}

// listen holds LISTEN pgvigil_request on a connection of its own and wakes the loop on every notify; a lost
// connection is opened again after listenRetry (the 5 s poll covers the gap, and a pooler that never lets it hold).
func (w *Worker) listen(ctx context.Context) {
	for ctx.Err() == nil {
		conn, err := pgx.Connect(ctx, w.cfg.Repository.DSN())
		if err == nil {
			_, err = conn.Exec(ctx, `LISTEN pgvigil_request`)
		}
		for err == nil {
			_, err = conn.WaitForNotification(ctx)
			if err == nil {
				select {
				case w.wake <- struct{}{}:
				default:
				}
			}
		}
		if conn != nil {
			cctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_ = conn.Close(cctx)
			cancel()
		}
		if ctx.Err() != nil {
			return
		}
		w.log.Debug("request queue: LISTEN lost; the 5 s poll claims meanwhile", "err", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(listenRetry):
		}
	}
}

// room: the regular slots free, the urgent slot free, and per instance what is left of perInstance.
func (w *Worker) room() (free, urgent int, perInst map[string]int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	total := w.cfg.CQ.Workers + 1
	free = w.cfg.CQ.Workers - w.regular
	if left := total - len(w.running); free > left {
		free = left
	}
	if free < 0 {
		free = 0
	}
	urgent = total - len(w.running) - free
	if urgent < 0 {
		urgent = 0
	}
	perInst = map[string]int{}
	for inst, n := range w.byInst {
		perInst[inst] = max(perInstance-n, 0)
	}
	return free, urgent, perInst
}

// claim takes what fits and starts each.
func (w *Worker) claim(ctx context.Context) {
	free, urgent, perInst := w.room()
	if free+urgent == 0 {
		return
	}
	pb, _ := json.Marshal(perInst)
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	rows, err := w.pool.Query(cctx, `SELECT request_id, kind, instance, ui_user, coalesce(client, ''), payload, remaining_ms
		FROM pgvigil.import_action_claim($1, $2, $3, $4::jsonb)`, w.id, free, urgent, string(pb))
	if err != nil {
		w.log.Warn("request queue: the claim failed", "err", err)
		return
	}
	type claimed struct {
		r   Request
		raw []byte
	}
	var got []claimed
	for rows.Next() {
		var c claimed
		var ms int64
		if err := rows.Scan(&c.r.ID, &c.r.Kind, &c.r.Instance, &c.r.UIUser, &c.r.Client, &c.raw, &ms); err != nil {
			w.log.Warn("request queue: a claimed row was not read", "err", err)
			continue
		}
		c.r.Remaining = time.Duration(ms) * time.Millisecond
		got = append(got, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		// the rows read before the error start; a row set running but never read is not in w.running, so the beat does
		// not renew it and the sweep says 'lost' within 30 s
		w.log.Warn("request queue: the claim's rows were not all read; an unread one goes 'lost'", "err", err, "read", len(got))
	}
	for _, c := range got {
		w.start(ctx, c.r, c.raw)
	}
}

// start runs one claimed request in its own goroutine under a deadline of this process's monotonic clock plus the
// repository's remainder (never this host's wall clock against expires_at).
func (w *Worker) start(ctx context.Context, r Request, raw []byte) {
	k := Kinds[r.Kind]
	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), r.Remaining)
	rr := &run{req: r, cancel: cancel, urgent: k.Urgent}
	w.mu.Lock()
	w.running[r.ID] = rr
	if !k.Urgent {
		w.regular++
		w.byInst[r.Instance]++
	}
	w.mu.Unlock()
	w.runs.Add(1)
	go func() {
		defer w.runs.Done()
		defer cancel()
		defer w.done(r, k.Urgent) // recover() works here: done is the deferred call itself
		start := time.Now()
		end := w.runSafe(rctx, r, raw)
		w.mu.Lock()
		cancelled, why := rr.cancelled, rr.why
		w.mu.Unlock()
		switch {
		case cancelled && end.State == "done":
			// the cancel landed after the runner had finished: it ran whole, so its end stays done (for a kill, a
			// 'cancelled' here would be a false word)
			end.Outcome = strings.TrimSpace(end.Outcome + " (the cancel came after it had ended)")
		case cancelled && end.State != "refused":
			// the worker cut it: the cancel's words (the asker's, or the collector's stop), not the runner's own account
			// of its cut context, as the deadline's words below
			end.State, end.Result, end.Outcome = "cancelled", nil, why
		case errors.Is(rctx.Err(), context.DeadlineExceeded) && end.State != "done" && end.State != "refused":
			end.State = "failed"
			end.Outcome = "the run passed its time (its request expired while it ran)"
		}
		w.finish(r, end, time.Since(start))
	}()
}

// done gives a run's slot back (deferred first in its goroutine, so a panic in its end gives it back too; the row is
// then out of w.running, the beat stops renewing it and the sweep says 'lost').
func (w *Worker) done(r Request, urgent bool) {
	if v := recover(); v != nil {
		w.log.Error("request queue: a run's end panicked; its row goes 'lost'", "request", r.ID, "panic", v)
	}
	w.mu.Lock()
	delete(w.running, r.ID)
	if !urgent {
		w.regular--
		if w.byInst[r.Instance]--; w.byInst[r.Instance] <= 0 {
			delete(w.byInst, r.Instance)
		}
	}
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}: // a slot is free: claim again
	default:
	}
}

// runSafe is runOne with a panic ended 'failed' in the panic's words: one bad result never stops the collector.
func (w *Worker) runSafe(ctx context.Context, r Request, raw []byte) (end End) {
	defer func() {
		if v := recover(); v != nil {
			w.log.Error("request queue: a run panicked", "request", r.ID, "kind", r.Kind, "panic", v)
			end = End{State: "failed", Outcome: fmt.Sprintf("the collector on %s broke while running it (%v): its log has it", w.host, v)}
		}
	}()
	return w.runOne(ctx, r, raw)
}

// runOne: the payload decoded, the instance this collector holds, the doors checked again, the runner.
func (w *Worker) runOne(ctx context.Context, r Request, raw []byte) End {
	run := runnerOf(r.Kind)
	if run == nil {
		return End{State: "refused", Refusal: fmt.Sprintf("%s is not through the queue yet on %s", r.Kind, r.Instance)}
	}
	p, err := Decode(r.Kind, raw)
	if err != nil {
		return End{State: "refused", Refusal: err.Error()}
	}
	r.Payload = p
	w.mu.Lock()
	in, ok := w.held[r.Instance]
	w.mu.Unlock()
	if !ok {
		return End{State: "refused", Refusal: fmt.Sprintf("the collector on %s no longer holds %s", w.host, r.Instance)}
	}
	env := w.env(in)
	if why := doorNow(&env, r, run); why != "" {
		return End{State: "refused", Refusal: why}
	}
	return run.Run(ctx, &env, r)
}

// endBody is a run's end as import_action_finish (0200) reads it: its state, words, rows, time, the keep and the result.
// An empty outcome or refusal is left out, so 0200 stores NULL, never an empty string: a reader's coalesce(outcome,
// refusal) then shows a refusal's words (CQ-LIVEMASK).
func endBody(end End, took time.Duration, keep string) map[string]any {
	body := map[string]any{"state": end.State, "rows": end.Rows, "duration_ms": took.Milliseconds(), "keep": keep}
	if end.Outcome != "" {
		body["outcome"] = end.Outcome
	}
	if end.Refusal != "" {
		body["refusal"] = end.Refusal
	}
	if end.Result != nil {
		body["result"] = end.Result
	}
	return body
}

// finish writes the end and the run's audit rows in one transaction; a row that is no longer this worker's running
// row (lost, or swept) takes neither.
func (w *Worker) finish(r Request, end End, took time.Duration) {
	if end.State == "" {
		end.State = "done"
	}
	if end.Result != nil {
		// CQ-16 (task 488): every string of a result is masked before it is stored, whatever the kind and whatever its
		// runner masked itself (idempotent); before the call's clock starts. A result with no JSON form (a NaN or an
		// infinity in a cell) is not kept, and the run's audit row is still written: the run did execute.
		m, err := MaskResult(end.Result)
		if err != nil {
			end.State, end.Outcome, m = "failed", fmt.Sprintf("it ran, but its result has no JSON form, so it is not kept: %v", err), nil
		}
		end.Result = m
	}
	// the run's own words too (review 488 S1): action_requests' outcome and refusal are the reader's (Grafana's) to read
	end.Outcome, end.Refusal = MaskText(end.Outcome), MaskText(end.Refusal)
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	b, err := json.Marshal(endBody(end, took, w.cfg.CQ.ResultKeep))
	if err != nil {
		w.finishBare(r, fmt.Sprintf("its end could not be written: %v", err))
		return
	}
	b = NoNUL(b)
	tx, err := w.pool.Begin(ctx)
	if err != nil {
		w.finishBare(r, fmt.Sprintf("its end could not be written: %v", err))
		return
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if end.Audit != nil {
		if err := end.Audit(ctx, tx); err != nil {
			// the audit row failed: the run's rows are withheld, its end says so
			_ = tx.Rollback(ctx)
			w.finishBare(r, fmt.Sprintf("the audit row was not written, so the result is withheld: %v", err))
			return
		}
	}
	var ok bool
	if err := tx.QueryRow(ctx, `SELECT pgvigil.import_action_finish($1, $2, $3::jsonb)`, w.id, r.ID, string(b)).Scan(&ok); err != nil {
		// the end did not go in (a repository blip, the call's time): the transaction is given back first (it may hold
		// the row), then the end is written bare; if that fails too, the row is out of w.running and goes 'lost'
		_ = tx.Rollback(ctx)
		w.finishBare(r, fmt.Sprintf("it ran, but its end could not be written: %v", err))
		return
	}
	if !ok {
		// lost or swept: the end is dropped, the audit rows of a run that did execute are kept
		w.log.Warn("request queue: a run ended after its row was no longer this collector's (lost or swept); its end is dropped, its audit kept", "request", r.ID)
	}
	if err := tx.Commit(ctx); err != nil {
		w.log.Warn("request queue: an end was not written", "request", r.ID, "err", err)
		if ok {
			w.finishBare(r, fmt.Sprintf("it ran, but its end could not be written: %v", err))
		}
	}
}

// finishBare ends a request 'failed' with words and nothing else; a failure here is logged and the row goes 'lost'
// (the beat no longer renews it).
func (w *Worker) finishBare(r Request, why string) {
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	b, _ := json.Marshal(map[string]any{"state": "failed", "outcome": MaskText(why)})
	if _, err := w.pool.Exec(ctx, `SELECT pgvigil.import_action_finish($1, $2, $3::jsonb)`, w.id, r.ID, string(NoNUL(b))); err != nil {
		w.log.Warn("request queue: an end was not written; the request goes 'lost'", "request", r.ID, "err", err)
	}
}

// stop: every running request cancelled and ended (stopWait at most), then the lease ended at once.
func (w *Worker) stop() {
	w.mu.Lock()
	for _, r := range w.running {
		if !r.cancelled {
			r.cancelled, r.why = true, fmt.Sprintf("the collector on %s stopped while running it", w.host)
		}
		r.cancel()
	}
	w.mu.Unlock()
	done := make(chan struct{})
	go func() { w.runs.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(stopWait):
		w.log.Warn("request queue: a run did not end in time at the stop; its row goes 'lost' when its lease lapses")
	}
	ctx, cancel := context.WithTimeout(context.Background(), stopCall)
	defer cancel()
	if _, err := w.pool.Exec(ctx, `SELECT pgvigil.import_cq_stop($1)`, w.id); err != nil {
		w.log.Warn("request queue: the lease was not ended at the stop; it lapses in 45 s", "err", err)
	}
	w.log.Info("request queue stopped", "collector", w.id)
}
