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
	// RED: the wiring held back - nothing checked, nothing started
	_, _, _, _, _ = ctx, log, cfg, ingest.Sites, pgxpool.New
	_, _, _ = fmt.Sprint, strings.TrimSpace, time.Minute
	return func() {}, nil
}
