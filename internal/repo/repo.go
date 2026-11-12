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
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
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
	names, err := migrationNames()
	if err != nil {
		return 0, err
	}
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
		// re-apply the access contract inside the same transaction: CREATE OR REPLACE resets
		// SECURITY DEFINER, so an import function replaced by this file must not commit without it
		var hasRoles bool
		if err := tx.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.apply_roles()') IS NOT NULL`).Scan(&hasRoles); err != nil {
			_ = tx.Rollback(ctx)
			return applied, err
		}
		if hasRoles {
			if _, err := tx.Exec(ctx, `SELECT pgvigil.apply_roles()`); err != nil {
				_ = tx.Rollback(ctx)
				return applied, fmt.Errorf("apply_roles after %s: %w", n, err)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return applied, err
		}
		applied++
	}
	return applied, nil
}

// migrationNames is the embedded migration files in name order, the order Migrate applies them in.
func migrationNames() ([]string, error) {
	entries, err := fs.ReadDir(migrations, "sql")
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// schemaState is SchemaCurrent's answer from the embedded names (in name order) and the names the store lacks:
// current when none of them is missing, else false and the first missing one in name order; a missing name this
// binary does not carry is not counted. Current names the newest embedded migration.
func schemaState(names, missing []string) (bool, string) {
	lacks := make(map[string]bool, len(missing))
	for _, m := range missing {
		lacks[m] = true
	}
	for _, n := range names {
		if lacks[n] {
			return false, n
		}
	}
	if len(names) == 0 {
		return true, ""
	}
	return true, names[len(names)-1]
}

// SchemaCurrent reports whether every embedded migration is applied, through SECURITY DEFINER functions the
// collector role may call; `pgvigil run` checks this instead of migrating, so the daemon runs with the collector
// login. It asks the store which embedded names schema_version lacks, so a lower-numbered file that arrives after a
// higher one was applied reads behind (Migrate applies every missing file, not only the ones above the newest).
// The name is the first missing migration when the store is behind, else the newest embedded one. A store from
// before the file that adds schema_missing() is behind by that alone: the name is then the first embedded
// migration above its newest (the collector cannot read schema_version itself).
func (r *Repo) SchemaCurrent(ctx context.Context) (bool, string, error) {
	names, err := migrationNames()
	if err != nil {
		return false, "", err
	}
	latest := ""
	if len(names) > 0 {
		latest = names[len(names)-1]
	}
	var missing []string
	err = r.pool.QueryRow(ctx, `SELECT pgvigil.schema_missing($1::text[])`, names).Scan(&missing)
	if err == nil {
		ok, name := schemaState(names, missing)
		return ok, name, nil
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "42883" { // 42883: undefined_function
		return false, latest, fmt.Errorf("schema check (run 'pgvigil migrate' as the repository owner first): %w", err)
	}
	var have *string
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.schema_latest()`).Scan(&have); err != nil {
		return false, latest, fmt.Errorf("schema check (run 'pgvigil migrate' as the repository owner first): %w", err)
	}
	for _, n := range names {
		if have == nil || n > *have {
			return false, n, nil
		}
	}
	return false, latest, fmt.Errorf("schema check: pgvigil.schema_missing() does not exist although %s is applied", *have)
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

// EnsureInstanceEngine is EnsureInstance for an instance of a named engine ("postgres" or "sqlserver"); the repository
// refuses a name already stored under the other engine.
func (r *Repo) EnsureInstanceEngine(ctx context.Context, engine, name, platform, serverVersion string, versionNum int, isReplica bool, tags []string) (int, error) {
	var id int
	err := r.pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, $3, $4, $5, $6, $7)`,
		name, platform, serverVersion, versionNum, isReplica, tags, engine).Scan(&id)
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

// LogCursor returns how far a log source was read for an instance (false: never).
func (r *Repo) LogCursor(ctx context.Context, instanceID int, source string) (time.Time, bool, error) {
	var t *time.Time
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.log_cursor($1, $2)`, instanceID, source).Scan(&t); err != nil {
		return time.Time{}, false, fmt.Errorf("log_cursor: %w", err)
	}
	if t == nil {
		return time.Time{}, false, nil
	}
	return *t, true, nil
}

// MSSQLCursor returns how far a SQL Server source was read for an instance (pgvigil.mssql_cursor; found false: never).
func (r *Repo) MSSQLCursor(ctx context.Context, instanceID int, source string) (fileName string, fileOffset int64, lastEventAt time.Time, lastSeq int64, found bool, err error) {
	var f *string
	var off, seq *int64
	var at *time.Time
	rows, err := r.pool.Query(ctx, `SELECT file_name, file_offset, last_event_at, last_seq FROM pgvigil.import_mssql_cursor($1, $2)`, instanceID, source)
	if err != nil {
		return "", 0, time.Time{}, 0, false, fmt.Errorf("mssql_cursor: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		return "", 0, time.Time{}, 0, false, rows.Err()
	}
	if err := rows.Scan(&f, &off, &at, &seq); err != nil {
		return "", 0, time.Time{}, 0, false, fmt.Errorf("mssql_cursor: %w", err)
	}
	if f != nil {
		fileName = *f
	}
	if off != nil {
		fileOffset = *off
	}
	if at != nil {
		lastEventAt = *at
	}
	if seq != nil {
		lastSeq = *seq
	}
	return fileName, fileOffset, lastEventAt, lastSeq, true, nil
}

// MSSQLSeqCursor returns how far a one-number cursor source of a SQL Server instance was read (pgvigil.mssql_hadr_cursor;
// false: never). The Agent job history reads on from it.
func (r *Repo) MSSQLSeqCursor(ctx context.Context, instanceID int, source string) (int64, bool, error) {
	var n *int64
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.mssql_hadr_cursor($1, $2)`, instanceID, source).Scan(&n); err != nil {
		return 0, false, fmt.Errorf("mssql_hadr_cursor: %w", err)
	}
	if n == nil {
		return 0, false, nil
	}
	return *n, true, nil
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

// Purge calls pgvigil.purge(days) as the connected login (the owner's: the function is granted to
// nobody else) and returns the count it reports, partitions dropped plus rows deleted.
func (r *Repo) Purge(ctx context.Context, days int) (int64, error) {
	var n int64
	if err := r.pool.QueryRow(ctx, `SELECT pgvigil.purge($1)`, days).Scan(&n); err != nil {
		return 0, fmt.Errorf("purge: %w", err)
	}
	return n, nil
}

// PurgeCandidates lists the monthly partitions under schema pgvigil that purge(days) would drop,
// by the function's own rule: the month after the partition's (UTC) lies before now minus days.
// It takes every partitioned series in the schema, so a series the function does not yet name
// would be listed though kept.
func (r *Repo) PurgeCandidates(ctx context.Context, days int) ([]string, error) {
	rows, err := r.pool.Query(ctx, `
SELECT c.relname
  FROM pg_inherits i
  JOIN pg_class c ON c.oid = i.inhrelid
  JOIN pg_class p ON p.oid = i.inhparent
  JOIN pg_namespace ns ON ns.oid = p.relnamespace
 WHERE ns.nspname = 'pgvigil'
   AND c.relname ~ '_[0-9]{6}$'
   AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => $1)
 ORDER BY c.relname`, days)
	if err != nil {
		return nil, fmt.Errorf("purge candidates: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}
