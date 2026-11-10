package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// bufferCacheCollector is the hourly read of shared_buffers by relation (task 62): pg_buffercache's view, where the
// extension is installed in the connected database. It is the client DBA's opt-in (CREATE EXTENSION pg_buffercache);
// its view is readable by pg_monitor on PostgreSQL 10 and later, so the read needs no more than the collector's
// standing right. Absent, or not readable, the read stores one total row 'not available' with the reason.
//
// The view lists every buffer of the server; a buffer's relation is named only for the connected database and the
// shared catalogs (pg_filenode_relation resolves a file node in the current database alone): a relation of another
// database keeps its database's name and its file node. The view is read once: the buffers summed per file node (the
// view's rows are buffers; the sum is at most a few thousand rows), the totals from those sums, and the 50 relations
// holding the most buffers kept.
//
// Rows by kind:
//
//	total  status (ok | not available), reason, total_buffers (shared_buffers in pages), used_buffers, dirty_buffers,
//	       block_size   (once)
//	rel    datname, schemaname, relname (NULL outside the connected database), relkind, relfilenode, buffers, dirty,
//	       usage_avg (the mean usage count 0-5), usage_hot (buffers at usage count 3 or more)
type bufferCacheCollector struct{}

func init() { Register(bufferCacheCollector{}) }

func (bufferCacheCollector) Name() string                   { return "buffercache" }
func (bufferCacheCollector) DefaultInterval() time.Duration { return time.Hour }
func (bufferCacheCollector) Applies(platform.Info) (bool, string) {
	return true, "" // the read itself says 'not available' and why
}

// bufferCacheTop bounds the relations kept per read.
const bufferCacheTop = 50

func (bufferCacheCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	notAvailable := func(reason string) []Row {
		return []Row{{"kind": "total", "status": "not available", "reason": reason}}
	}
	var schema *string
	if err := conn.QueryRow(ctx, `
SELECT n.nspname::text FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_buffercache'`).Scan(&schema); err != nil && err != pgx.ErrNoRows {
		return nil, fmt.Errorf("pg_buffercache: %w", err)
	}
	if schema == nil {
		return notAvailable("pg_buffercache is not installed in the connected database (an opt-in: CREATE EXTENSION pg_buffercache; pg_monitor then reads it)"), nil
	}
	view := quoteIdent(*schema) + ".pg_buffercache"
	var canRead bool
	if err := conn.QueryRow(ctx, `SELECT has_table_privilege($1, 'SELECT')`, view).Scan(&canRead); err != nil {
		return nil, fmt.Errorf("pg_buffercache privilege: %w", err)
	}
	if !canRead {
		return notAvailable("the login cannot read pg_buffercache (grant it pg_monitor)"), nil
	}
	// ONE pass over the view (each read of it walks every buffer header; two reads were two full walks): the buffers
	// grouped by file node (unused buffers in the NULL group), materialized once; the totals are its sums and the 50
	// largest file nodes its top rows. Every output row carries the totals; with no relation in the cache there is one
	// row whose relation columns are NULL.
	rows, err := conn.Query(ctx, fmt.Sprintf(`
WITH f AS MATERIALIZED (
  SELECT b.reldatabase, b.reltablespace, b.relfilenode, count(*) AS buffers,
         count(*) FILTER (WHERE b.isdirty) AS dirty, avg(b.usagecount)::float8 AS usage_avg,
         count(*) FILTER (WHERE b.usagecount >= 3) AS usage_hot
    FROM %s b
   GROUP BY 1, 2, 3
), t AS (
  SELECT sum(buffers)::bigint AS total, coalesce(sum(buffers) FILTER (WHERE relfilenode IS NOT NULL), 0)::bigint AS used,
         coalesce(sum(dirty), 0)::bigint AS dirty, current_setting('block_size')::bigint AS block_size
    FROM f
), top AS (
  SELECT f.*, CASE WHEN f.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))
                   THEN pg_filenode_relation(f.reltablespace, f.relfilenode) END AS rel
    FROM f WHERE f.relfilenode IS NOT NULL
   ORDER BY f.buffers DESC
   LIMIT %d
)
SELECT t.total, t.used, t.dirty, t.block_size,
       coalesce(d.datname::text, CASE WHEN r.reldatabase = 0 THEN '(shared catalogs)' END), n.nspname::text, c.relname::text,
       c.relkind::text, r.relfilenode::bigint, r.buffers, r.dirty, r.usage_avg, r.usage_hot
  FROM t
  LEFT JOIN top r ON true
  LEFT JOIN pg_database d ON d.oid = r.reldatabase
  LEFT JOIN pg_class c ON c.oid = r.rel
  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
 ORDER BY r.buffers DESC NULLS LAST`, view, bufferCacheTop))
	if err != nil {
		return nil, fmt.Errorf("pg_buffercache: %w", err)
	}
	defer rows.Close()
	var out []Row
	for rows.Next() {
		var total, used, dirty, blockSize *int64
		var datname, nsp, relname, relkind *string
		var filenode, buffers, dirtyN, hot *int64
		var usage *float64
		if err := rows.Scan(&total, &used, &dirty, &blockSize, &datname, &nsp, &relname, &relkind, &filenode, &buffers, &dirtyN, &usage, &hot); err != nil {
			return nil, err
		}
		if out == nil {
			out = []Row{{"kind": "total", "status": "ok", "reason": nil, "total_buffers": total, "used_buffers": used,
				"dirty_buffers": dirty, "block_size": blockSize}}
		}
		if buffers != nil {
			out = append(out, Row{"kind": "rel", "datname": datname, "schemaname": nsp, "relname": relname, "relkind": relkind,
				"relfilenode": filenode, "buffers": buffers, "dirty": dirtyN, "usage_avg": usage, "usage_hot": hot})
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, fmt.Errorf("pg_buffercache: the read returned no row")
	}
	return out, nil
}
