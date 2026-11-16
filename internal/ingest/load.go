package ingest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// PoolHub is the Hub on the repository's pool (migration 0329).
type PoolHub struct{ Pool *pgxpool.Pool }

func (h PoolHub) Newest(ctx context.Context, site, coll, key, stream string) (Newest, bool, error) {
	var n Newest
	err := h.Pool.QueryRow(ctx, `SELECT stream, high_seq, high_end FROM pgvigil.remote_streams
	   WHERE site = $1 AND collector = $2 AND instance_key = $3 AND ($4 = '' OR stream = $4) ORDER BY high_end DESC LIMIT 1`,
		site, coll, key, stream).Scan(&n.Stream, &n.Seq, &n.End)
	if errors.Is(err, pgx.ErrNoRows) {
		return Newest{}, false, nil
	}
	return n, err == nil, err
}

func (h PoolHub) Recorded(ctx context.Context, site, coll, key, stream string, seq uint64) (string, string, bool, error) {
	var digest, kind string
	err := h.Pool.QueryRow(ctx, `
SELECT digest, kind FROM (
  SELECT digest, 'loaded' AS kind, 0 AS o, loaded_at AS at FROM pgvigil.remote_bundles
   WHERE site = $1 AND collector = $2 AND instance_key = $3 AND stream = $4 AND seq = $5 AND state = 'loaded'
  UNION ALL
  SELECT digest, kind, 1, marked_at FROM pgvigil.remote_marks
   WHERE site = $1 AND collector = $2 AND instance_key = $3 AND stream = $4 AND seq = $5 AND cleared_at IS NULL
     AND kind NOT IN ('gap', 'audit gap')) x
 ORDER BY o, at DESC LIMIT 1`, site, coll, key, stream, int64(seq)).Scan(&digest, &kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, nil
	}
	return digest, kind, err == nil, err
}

func (h PoolHub) Mark(ctx context.Context, m Mark) error {
	_, err := h.Pool.Exec(ctx, `SELECT pgvigil.remote_mark($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		m.Site, m.Collector, m.Key, m.Stream, int64(m.Seq), m.End, m.Kind, m.Reason, m.Digest)
	return err
}

// Load loads a checked bundle: the instance (0329's import_remote_ensure), the bundle's ledger row (a stopped bundle
// resumes on it), each batch in n order through import_remote_batch - each its own transaction with its ledger row,
// so a second try loads only the rest -, then in one transaction the runs (log_collection), the failures, the bundle's
// end (the stream's high-water, as_of, the heartbeat, the collector's intervals).
func (h PoolHub) Load(ctx context.Context, s Site, b *Bundle) error {
	m := b.Manifest
	var id int
	err := h.Pool.QueryRow(ctx, `SELECT pgvigil.import_remote_ensure($1, $2, $3, $4, $5, $6, $7, $8)`, s.Name, m.Instance.Engine, m.Instance.Name,
		m.Instance.Platform, m.Instance.ServerVersion, m.Instance.VersionNum, m.Instance.IsReplica, nonNil(m.Instance.Tags)).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "owned elsewhere") {
			return fmt.Errorf("%w: %v", ErrOwned, err)
		}
		return err
	}
	var bid int64
	if err := h.Pool.QueryRow(ctx, `SELECT pgvigil.remote_bundle_begin($1, $2, $3, $4, $5, $6, $7, $8, $9)`, s.Name, m.Collector, b.Ref.InstanceKey,
		m.Stream, int64(m.Seq), m.WindowFrom, m.WindowTo, b.Digest, id).Scan(&bid); err != nil {
		return err
	}
	for _, x := range b.Batches {
		for attempt := 1; ; attempt++ {
			_, err := h.Pool.Exec(ctx, `SELECT pgvigil.import_remote_batch($1, $2, $3, $4, $5, $6::jsonb, $7)`, bid, x.View, x.N, id, x.At, string(x.Rows), b.AfterGap)
			if err == nil {
				break
			}
			if attempt == repo.ImportDeadlockTries || !repo.IsDeadlock(err) || ctx.Err() != nil {
				return fmt.Errorf("batch %d (%s): %w", x.N, x.View, err)
			}
		}
	}
	tx, err := h.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	for _, r := range m.Runs {
		if _, err := tx.Exec(ctx, `SELECT pgvigil.log_collection($1, $2, $3, $4, $5, $6, $7::text)`, id, r.Collection, r.At, int(r.Ms), r.Status, nullIfEmpty(r.Note), nullIfEmpty(r.Stage)); err != nil {
			return fmt.Errorf("run %s: %w", r.Collection, err)
		}
	}
	name := s.Name + "/" + m.Instance.Name
	for _, f := range m.Failures {
		var q string
		var args []any
		switch f.Kind {
		case "connect", "secret":
			q, args = `SELECT pgvigil.import_connect_failure($1, $2, $3, $4, $5, $6, $7, $8)`, []any{name, f.Collection, f.At, int(f.Ms), f.Kind + ": " + f.Cause, m.Instance.Engine, m.Instance.Platform, nonNil(m.Instance.Tags)}
		default:
			q, args = `SELECT pgvigil.import_run_failure($1, $2, $3, $4, $5, $6)`, []any{name, m.Instance.Engine, f.Collection, f.At, int(f.Ms), f.Cause}
		}
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			return fmt.Errorf("failure %s: %w", f.Collection, err)
		}
	}
	hb, _ := json.Marshal(map[string]any{"host": m.Heartbeat.Host, "started": m.Heartbeat.Started, "at": m.Heartbeat.At, "instances": m.Heartbeat.Instances, "fail_streak": m.Heartbeat.FailStreak})
	iv := make([]map[string]any, 0, len(m.Reads))
	for _, r := range m.Reads {
		iv = append(iv, map[string]any{"collection": r.Collection, "interval_secs": r.IntervalSecs})
	}
	ivj, _ := json.Marshal(iv)
	if _, err := tx.Exec(ctx, `SELECT pgvigil.remote_bundle_done($1, $2::jsonb, $3::jsonb, $4)`, bid, string(hb), string(ivj), m.PgvigilVersion); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// SyncSites writes each site as remote_sites: names it (the pages read expected_every from the store).
func (h PoolHub) SyncSites(ctx context.Context, sites []Site) error {
	for _, s := range sites {
		if _, err := h.Pool.Exec(ctx, `SELECT pgvigil.remote_site_sync($1, $2, $3, $4)`, s.Name, nonNil(s.Tags), int(s.ExpectedEvery.Seconds()), int(s.GapWait.Seconds())); err != nil {
			return fmt.Errorf("remote_site_sync %s: %w", s.Name, err)
		}
	}
	return nil
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
