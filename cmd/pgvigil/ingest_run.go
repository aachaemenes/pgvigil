package main

// The outbox's ingest inside `pgvigil run` on a hub (task 15's WIRING, OUTBOX H): remote_sites: read on ingest's own
// login (ingest_dsn:, a member of pgvigil_ingest alone), never the collector's or the owner's.

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/ingest"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ingestEvery is how often run takes a round of every remote site: a minute (ingest.Loop's own floor), so a bundle is
// loaded within a minute of its settle.
const ingestEvery = time.Minute

// startIngest opens remote_sites:' drops and ingest's pool, checks its login (the owner, a superuser, a member of
// pgvigil_collector or a login outside pgvigil_ingest refused in words: a configuration error, as `pgvigil ingest`
// says it) and starts the loop. Without ingest_dsn: remote_sites: is not read and a line says so. stop ends the loop,
// waits for it and closes the pool.
func startIngest(ctx context.Context, log *slog.Logger, cfg *config.Config) (stop func(), err error) {
	if strings.TrimSpace(cfg.IngestDSN()) == "" {
		log.Warn("remote_sites: is not read: no ingest_dsn: (a login IN ROLE pgvigil_ingest alone; 'pgvigil roles' prints its CREATE ROLE)",
			"sites", len(cfg.RemoteSites))
		return func() {}, nil
	}
	sites, err := ingest.Sites(ctx, cfg.RemoteSites, ingest.OpenDrop)
	if err != nil {
		return nil, &configError{err}
	}
	pool, err := pgxpool.New(ctx, cfg.IngestDSN())
	if err != nil {
		return nil, &configError{fmt.Errorf("ingest_dsn: %w", err)}
	}
	if err := ingest.CheckIngestLogin(ctx, pool); err != nil {
		pool.Close()
		return nil, &configError{err}
	}
	lctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ingest.Loop(lctx, pool, sites, ingestEvery, log)
	}()
	log.Info("remote sites: ingest started", "sites", len(sites), "every", ingestEvery)
	return func() { cancel(); <-done; pool.Close() }, nil
}
