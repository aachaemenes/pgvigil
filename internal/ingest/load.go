package ingest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// PoolHub is the Hub on ingest's own pool - a login in pgvigil_ingest - through 0329's ingest door only: every read and
// write is one of 0329's functions (apply_roles makes them SECURITY DEFINER and pgvigil_ingest's alone: join line 4).
type PoolHub struct{ Pool *pgxpool.Pool }

func (h PoolHub) Newest(ctx context.Context, site, coll, key, stream string) (Newest, bool, error) {
	var n Newest
	var seq int64
	err := h.Pool.QueryRow(ctx, `SELECT stream, high_seq, high_end FROM pgvigil.remote_newest($1, $2, $3, $4)`, site, coll, key, stream).Scan(&n.Stream, &seq, &n.End)
	if errors.Is(err, pgx.ErrNoRows) {
		return Newest{}, false, nil
	}
	n.Seq = uint64(seq)
	return n, err == nil, err
}

func (h PoolHub) Recorded(ctx context.Context, site, coll, key, stream string, seq uint64) (string, string, bool, error) {
	var digest, kind string
	err := h.Pool.QueryRow(ctx, `SELECT digest, kind FROM pgvigil.remote_recorded($1, $2, $3, $4, $5)`, site, coll, key, stream, int64(seq)).Scan(&digest, &kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", false, nil
	}
	return digest, kind, err == nil, err
}

func (h PoolHub) Mark(ctx context.Context, m Mark) (bool, error) {
	var isNew bool
	var end any
	if !m.End.IsZero() {
		end = m.End
	}
	err := h.Pool.QueryRow(ctx, `SELECT pgvigil.remote_mark($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		m.Site, m.Collector, m.Key, m.Stream, int64(m.Seq), end, m.Kind, m.Reason, m.Digest).Scan(&isNew)
	return isNew, err
}

func (h PoolHub) Seen(ctx context.Context, site, coll, key, dir string, _ time.Time) (time.Time, error) {
	var t time.Time
	err := h.Pool.QueryRow(ctx, `SELECT pgvigil.remote_seen($1, $2, $3, $4)`, site, coll, key, dir).Scan(&t)
	return t, err
}

func (h PoolHub) Retries(ctx context.Context, site, coll, key string) ([]time.Time, error) {
	rows, err := h.Pool.Query(ctx, `SELECT pgvigil.remote_retries($1, $2, $3)`, site, coll, key)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[time.Time])
}

// Load loads a checked bundle: the instance (0329's remote_ensure_instance), the bundle's ledger row (a stopped bundle
// resumes on it), each batch in n order through remote_batch - each its own transaction with its ledger row, so a
// second try loads only the rest -, then remote_bundle_done in one transaction: the runs (log_collection), the failures,
// the gap it went past, the bundle's end (the stream's high-water, as_of, the heartbeat, the collector's intervals).
func (h PoolHub) Load(ctx context.Context, s Site, b *Bundle) error {
	m := b.Manifest
	var id int
	err := h.Pool.QueryRow(ctx, `SELECT pgvigil.remote_ensure_instance($1, $2, $3, $4, $5, $6, $7, $8)`, s.Name, m.Instance.Engine, m.Instance.Name,
		m.Instance.Platform, m.Instance.ServerVersion, m.Instance.VersionNum, m.Instance.IsReplica, nonNil(m.Instance.Tags)).Scan(&id)
	if err != nil {
		if strings.Contains(err.Error(), "owned elsewhere") {
			return fmt.Errorf("%w: %v", ErrOwned, err)
		}
		return err
	}
	var bid int64
	if err := h.Pool.QueryRow(ctx, `SELECT pgvigil.remote_bundle_begin($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`, s.Name, m.Collector, b.Ref.InstanceKey,
		m.Stream, int64(m.Seq), m.WindowFrom, m.WindowTo, b.Digest, id, m.QueryText).Scan(&bid); err != nil {
		return err
	}
	for _, x := range b.Batches {
		for attempt := 1; ; attempt++ {
			_, err := h.Pool.Exec(ctx, `SELECT pgvigil.remote_batch($1, $2, $3, $4, $5, $6::jsonb, $7)`, bid, x.View, x.N, id, x.At, string(x.Rows), b.AfterGap)
			if err == nil {
				break
			}
			if attempt == repo.ImportDeadlockTries || !repo.IsDeadlock(err) || ctx.Err() != nil {
				return fmt.Errorf("batch %d (%s): %w", x.N, x.View, err)
			}
		}
	}
	hb, _ := json.Marshal(map[string]any{"host": m.Heartbeat.Host, "started": m.Heartbeat.Started, "at": m.Heartbeat.At, "instances": m.Heartbeat.Instances, "fail_streak": m.Heartbeat.FailStreak})
	iv := make([]map[string]any, 0, len(m.Reads))
	for _, r := range m.Reads {
		iv = append(iv, map[string]any{"collection": r.Collection, "interval_secs": r.IntervalSecs})
	}
	ivj, _ := json.Marshal(iv)
	runs, _ := json.Marshal(nonNilRuns(m))
	fails, _ := json.Marshal(nonNilFailures(m))
	var gap any
	if b.Gap != "" {
		gap = b.Gap
	}
	_, err = h.Pool.Exec(ctx, `SELECT pgvigil.remote_bundle_done($1, $2::jsonb, $3::jsonb, $4, $5::jsonb, $6::jsonb, $7)`,
		bid, string(hb), string(ivj), m.PgvigilVersion, string(runs), string(fails), gap)
	return err
}

// SyncSites writes each site as remote_sites: names it (its collectors too: the pages list a configured collector that
// never sent, and the silence reads expected_every from the store), then retires every site no longer listed.
func (h PoolHub) SyncSites(ctx context.Context, sites []Site) error {
	names := make([]string, 0, len(sites))
	for _, s := range sites {
		colls := make([]string, 0, len(s.Collectors))
		for c := range s.Collectors {
			colls = append(colls, c)
		}
		sort.Strings(colls)
		if _, err := h.Pool.Exec(ctx, `SELECT pgvigil.remote_site_sync($1, $2, $3, $4, $5)`, s.Name, nonNil(s.Tags), int(s.ExpectedEvery.Seconds()), int(s.GapWait.Seconds()), colls); err != nil {
			return fmt.Errorf("remote_site_sync %s: %w", s.Name, err)
		}
		names = append(names, s.Name)
	}
	if _, err := h.Pool.Exec(ctx, `SELECT pgvigil.remote_sites_retire($1::text[])`, names); err != nil {
		return fmt.Errorf("remote_sites_retire: %w", err)
	}
	return nil
}

// nonNilRuns / nonNilFailures: the manifest's runs and failures, an empty list for none (jsonb '[]', never null)
func nonNilRuns(m *format.Manifest) []format.Run {
	if m.Runs == nil {
		return []format.Run{}
	}
	return m.Runs
}

func nonNilFailures(m *format.Manifest) []format.Failure {
	if m.Failures == nil {
		return []format.Failure{}
	}
	return m.Failures
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
