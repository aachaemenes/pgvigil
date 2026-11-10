package dbadash

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// Store writes reads into the pgvigil repository through 0052's import functions (the collector's door).
type Store struct{ pool *pgxpool.Pool }

// OpenStore connects to the pgvigil repository (its own small pool: the door runs beside the collections).
func OpenStore(ctx context.Context, repoDSN string) (*Store, error) {
	if strings.TrimSpace(repoDSN) == "" {
		return nil, fmt.Errorf("repository dsn is empty")
	}
	cfg, err := pgxpool.ParseConfig(repoDSN)
	if err != nil {
		return nil, fmt.Errorf("repository dsn: %w", err)
	}
	cfg.MaxConns = 2
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-dbadash"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("repository: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("repository ping: %w", err)
	}
	return &Store{pool: pool}, nil
}

// Close releases the pool.
func (s *Store) Close() { s.pool.Close() }

// Configured records which repositories the configuration lists now (the others leave the tree).
func (s *Store) Configured(ctx context.Context, names []string) error {
	if names == nil {
		names = []string{}
	}
	_, err := s.pool.Exec(ctx, `SELECT pgvigil.import_dbadash_configured($1)`, names)
	return err
}

// Save stores one read of one repository.
func (s *Store) Save(ctx context.Context, name string, at time.Time, p Payload) error {
	b, err := json.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	_, err = s.pool.Exec(ctx, `SELECT pgvigil.import_dbadash($1, $2, $3::jsonb)`, name, at, string(b))
	return err
}

// reasonMax caps the stored reason (a driver error can carry a long chain).
const reasonMax = 500

// ReadOne reads one repository and stores the result: the rows, or 'not read' with the reason. The returned error is
// the store's only (a repository that does not answer is a stored state, not a failure of the door).
func (s *Store) ReadOne(ctx context.Context, log *slog.Logger, r config.DBADashRepo) (Payload, error) {
	at := time.Now().UTC()
	p, err := Read(ctx, r.DSN())
	if err != nil {
		reason := err.Error()
		if len(reason) > reasonMax {
			reason = reason[:reasonMax]
		}
		p = NotRead(reason)
		log.Warn("dbadash repository not read", "repository", r.Name, "reason", reason)
	}
	if serr := s.Save(ctx, r.Name, at, p); serr != nil {
		return p, fmt.Errorf("dbadash %s: store: %w", r.Name, serr)
	}
	log.Debug("dbadash repository read", "repository", r.Name, "status", p.Status, "instances", len(p.Instances))
	return p, nil
}

// Once reads every configured repository once (the proof drives it) and returns the payloads by name. An empty list
// records that no repository is configured (the last one leaves the tree) and reads nothing.
func Once(ctx context.Context, log *slog.Logger, repoDSN string, repos []config.DBADashRepo) (map[string]Payload, error) {
	st, err := OpenStore(ctx, repoDSN)
	if err != nil {
		return nil, err
	}
	defer st.Close()
	if err := st.Configured(ctx, names(repos)); err != nil {
		return nil, fmt.Errorf("dbadash configured: %w", err)
	}
	out := map[string]Payload{}
	for _, r := range repos {
		p, err := st.ReadOne(ctx, log, r)
		if err != nil {
			return out, err
		}
		out[r.Name] = p
	}
	return out, nil
}

// Run reads every configured repository at its interval until ctx is cancelled (pgvigil run starts it beside the
// scheduler). It first records which repositories the configuration lists (an emptied list takes the last one out of
// the tree) and then, with an empty list, returns. A repository that cannot be opened or recorded at the start (the
// pgvigil repository down for a moment) is retried every retryEvery until it answers or ctx ends: the door never stops
// for the life of the process on one failed start. One goroutine per repository: a slow one never delays another.
func Run(ctx context.Context, log *slog.Logger, repoDSN string, repos []config.DBADashRepo) error {
	st := openUntil(ctx, log, repoDSN, repos)
	if st == nil {
		return nil // ctx ended before the store answered
	}
	defer st.Close()
	if len(repos) == 0 {
		log.Info("dbadash door off: no repository configured")
		return nil
	}
	var wg sync.WaitGroup
	for _, r := range repos {
		wg.Add(1)
		go func(r config.DBADashRepo) {
			defer wg.Done()
			loop(ctx, log, st, r)
		}(r)
	}
	log.Info("dbadash door started", "repositories", len(repos))
	<-ctx.Done()
	wg.Wait()
	return nil
}

// retryEvery is how long the door waits between attempts to open the store and record the configured repositories.
const retryEvery = time.Minute

// openUntil opens the store and records the configured repositories, retrying every retryEvery; nil when ctx ends first.
func openUntil(ctx context.Context, log *slog.Logger, repoDSN string, repos []config.DBADashRepo) *Store {
	for {
		st, err := OpenStore(ctx, repoDSN)
		if err == nil {
			cerr := st.Configured(ctx, names(repos))
			if cerr == nil {
				return st
			}
			err = fmt.Errorf("dbadash configured: %w", cerr)
			st.Close()
		}
		if ctx.Err() != nil {
			return nil
		}
		log.Warn("dbadash door not started, retrying", "in", retryEvery.String(), "err", err)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(retryEvery):
		}
	}
}

func loop(ctx context.Context, log *slog.Logger, st *Store, r config.DBADashRepo) {
	iv := r.Every()
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Duration(rand.Int64N(int64(10 * time.Second)))):
	}
	run := func() {
		if _, err := st.ReadOne(ctx, log, r); err != nil && ctx.Err() == nil {
			log.Warn("dbadash read failed", "repository", r.Name, "err", err)
		}
	}
	run()
	t := time.NewTicker(iv)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			run()
		}
	}
}

func names(repos []config.DBADashRepo) []string {
	out := make([]string, 0, len(repos))
	for _, r := range repos {
		out = append(out, r.Name)
	}
	return out
}
