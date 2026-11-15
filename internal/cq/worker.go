package cq

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sort"
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
)

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
	go config.WatchInventory(ctx, w.log, src, w.pageHeld, w.cfg.Instances, w.cfg.QueryText, 15*time.Second, func(all []config.Instance) {
		w.setHeld(ctx, all)
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
	w.beat(ctx)
	for {
		select {
		case <-ctx.Done():
			w.stop()
			return nil
		case <-applied:
			w.beat(ctx)
			w.claim(ctx)
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

// setHeld takes the instances held now and publishes their doors.
func (w *Worker) setHeld(ctx context.Context, all []config.Instance) {
	held := make(map[string]config.Instance, len(all))
	for _, in := range all {
		held[in.Name] = in
	}
	w.mu.Lock()
	w.held = held
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

// beat renews the lease (its instances now) and its running rows' lease; the ids it returns are cancels asked.
func (w *Worker) beat(ctx context.Context) {
	cctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	rows, err := w.pool.Query(cctx, `SELECT * FROM pgvigil.import_cq_beat($1, $2, $3)`, w.id, w.host, w.heldNames())
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
		start := time.Now()
		end := w.runOne(rctx, r, raw)
		w.mu.Lock()
		cancelled, why := rr.cancelled, rr.why
		w.mu.Unlock()
		if cancelled && end.State != "refused" {
			end.State, end.Result = "cancelled", nil
			if end.Outcome == "" {
				end.Outcome = why
			}
		} else if errors.Is(rctx.Err(), context.DeadlineExceeded) && end.State != "done" && end.State != "refused" {
			end.State = "failed"
			end.Outcome = "the run passed its time (its request expired while it ran)"
		}
		w.finish(r, end, time.Since(start))
		w.mu.Lock()
		delete(w.running, r.ID)
		if !k.Urgent {
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
	}()
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

// finish writes the end and the run's audit rows in one transaction; a row that is no longer this worker's running
// row (lost, or swept) takes neither.
func (w *Worker) finish(r Request, end End, took time.Duration) {
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	if end.State == "" {
		end.State = "done"
	}
	body := map[string]any{"state": end.State, "outcome": end.Outcome, "refusal": end.Refusal, "rows": end.Rows,
		"duration_ms": took.Milliseconds(), "keep": w.cfg.CQ.ResultKeep}
	if end.Result != nil {
		body["result"] = end.Result
	}
	b, err := json.Marshal(body)
	if err != nil {
		w.log.Warn("request queue: an end was not written", "request", r.ID, "err", err)
		return
	}
	tx, err := w.pool.Begin(ctx)
	if err != nil {
		w.log.Warn("request queue: an end was not written", "request", r.ID, "err", err)
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
		w.log.Warn("request queue: an end was not written", "request", r.ID, "err", err)
		return
	}
	if !ok {
		w.log.Warn("request queue: a run ended after its row was no longer this collector's (lost or swept); its end and audit are dropped", "request", r.ID)
		return
	}
	if err := tx.Commit(ctx); err != nil {
		w.log.Warn("request queue: an end was not written", "request", r.ID, "err", err)
	}
}

// finishBare ends a request 'failed' with words and nothing else.
func (w *Worker) finishBare(r Request, why string) {
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	b, _ := json.Marshal(map[string]any{"state": "failed", "outcome": why})
	if _, err := w.pool.Exec(ctx, `SELECT pgvigil.import_action_finish($1, $2, $3::jsonb)`, w.id, r.ID, string(b)); err != nil {
		w.log.Warn("request queue: an end was not written", "request", r.ID, "err", err)
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
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := w.pool.Exec(ctx, `SELECT pgvigil.import_cq_stop($1)`, w.id); err != nil {
		w.log.Warn("request queue: the lease was not ended at the stop; it lapses in 45 s", "err", err)
	}
	w.log.Info("request queue stopped", "collector", w.id)
}
