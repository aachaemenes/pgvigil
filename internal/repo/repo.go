// Package repo writes to the pgvigil repository database.
//
// The schema lives in repo/sql as numbered migration files embedded in the
// binary; Migrate applies the ones not yet recorded in pgvigil.schema_version.
// Each collection has an import function pgvigil.import_<name>(instance_id,
// snapshot_at, payload jsonb) that unpacks a JSONB array of rows into its
// tables, so the collector never knows the table shapes.
package repo

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed sql/*.sql
var migrations embed.FS

// Repo is an open repository.
type Repo struct {
	pool *pgxpool.Pool
}

// Open connects to the repository.
func Open(ctx context.Context, dsn string) (*Repo, error) {
	if strings.TrimSpace(dsn) == "" {
		return nil, fmt.Errorf("repository dsn is empty (env or file indirection resolved to nothing)")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("repository dsn: %w", err)
	}
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-repo"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("repository: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("repository ping: %w", err)
	}
	return &Repo{pool: pool}, nil
}

// Close releases the pool.
func (r *Repo) Close() { r.pool.Close() }

// migrateLockKey is the advisory lock that serialises concurrent migrates
// (a collector restarted by systemd while an operator runs `pgvigil migrate`).
const migrateLockKey int64 = 7265471133001

// Migrate applies pending migration files in name order; returns how many ran.
// The whole run holds a session advisory lock on one dedicated connection, so a
// second migrate waits and then finds nothing to do.
func (r *Repo) Migrate(ctx context.Context) (int, error) {
	c, err := r.pool.Acquire(ctx)
	if err != nil {
		return 0, fmt.Errorf("migrate: %w", err)
	}
	defer c.Release()
	if _, err := c.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrateLockKey); err != nil {
		return 0, fmt.Errorf("migrate lock: %w", err)
	}
	defer func() { _, _ = c.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, migrateLockKey) }()

	if _, err := c.Exec(ctx, `CREATE SCHEMA IF NOT EXISTS pgvigil;
CREATE TABLE IF NOT EXISTS pgvigil.schema_version (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);`); err != nil {
		return 0, fmt.Errorf("schema_version: %w", err)
	}
	entries, err := fs.ReadDir(migrations, "sql")
	if err != nil {
		return 0, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	applied := 0
	for _, n := range names {
		var exists bool
		if err := c.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pgvigil.schema_version WHERE version = $1)`, n).Scan(&exists); err != nil {
			return applied, err
		}
		if exists {
			continue
		}
		body, err := migrations.ReadFile("sql/" + n)
		if err != nil {
			return applied, err
		}
		tx, err := c.Begin(ctx)
		if err != nil {
			return applied, err
		}
		if _, err := tx.Exec(ctx, string(body)); err != nil {
			_ = tx.Rollback(ctx)
			return applied, fmt.Errorf("migration %s: %w", n, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.schema_version (version) VALUES ($1)`, n); err != nil {
			_ = tx.Rollback(ctx)
			return applied, err
		}
		if err := tx.Commit(ctx); err != nil {
			return applied, err
		}
		applied++
	}
	return applied, nil
}

// EnsureInstance upserts the instance row and returns its id.
func (r *Repo) EnsureInstance(ctx context.Context, name, platform, serverVersion string, versionNum int, isReplica bool, tags []string) (int, error) {
	var id int
	err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, $3, $4, $5, $6)`,
		name, platform, serverVersion, versionNum, isReplica, tags).Scan(&id)
	if err != nil {
		return 0, fmt.Errorf("ensure_instance %s: %w", name, err)
	}
	return id, nil
}

// Import hands a collection's rows to its import function.
func (r *Repo) Import(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, rows []map[string]any) error {
	payload, err := json.Marshal(rows)
	if err != nil {
		return fmt.Errorf("marshal %s: %w", collection, err)
	}
	if !validIdent(collection) {
		return fmt.Errorf("collection name %q is not a valid identifier", collection)
	}
	_, err = r.pool.Exec(ctx, fmt.Sprintf(`SELECT pgvigil.import_%s($1, $2, $3::jsonb)`, collection), instanceID, snapshotAt, string(payload))
	return err
}

// LogCollection records when a collection ran and how it ended.
func (r *Repo) LogCollection(ctx context.Context, instanceID int, collection string, snapshotAt time.Time, d time.Duration, status, note string) error {
	_, err := r.pool.Exec(ctx, `SELECT pgvigil.log_collection($1, $2, $3, $4, $5, $6)`,
		instanceID, collection, snapshotAt, int(d.Milliseconds()), status, nullIfEmpty(note))
	return err
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// validIdent allows only lower-case letters, digits and underscores (collection names).
func validIdent(s string) bool {
	if s == "" {
		return false
	}
	for i, c := range s {
		switch {
		case c >= 'a' && c <= 'z', c == '_':
		case c >= '0' && c <= '9' && i > 0:
		default:
			return false
		}
	}
	return true
}
