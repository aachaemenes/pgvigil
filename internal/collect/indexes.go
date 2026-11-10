package collect

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// indexesCollector reads, every hour and per connectable database, the indexes that cost writes and give nothing
// back: unused (no index scan since the usage counters started), redundant (another index on the same table starts
// with its columns), duplicate (another index with exactly its columns, operator classes, expressions and predicate)
// and invalid (a failed CREATE INDEX CONCURRENTLY or REINDEX). Each comes with the DROP line and its undo, shown as
// text: pgvigil never runs them.
//
// The redundant and the invalid reads are postgres_dba's sql/i2_redundant_indexes.sql and sql/i4_invalid_indexes.sql,
// used under its licence:
//
//	BSD 3-Clause License
//	Copyright (c) 2017, Nikolay Samokhvalov
//	All rights reserved.
//	Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
//	following conditions are met:
//	* Redistributions of source code must retain the above copyright notice, this list of conditions and the following
//	  disclaimer.
//	* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the
//	  following disclaimer in the documentation and/or other materials provided with the distribution.
//	* Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote
//	  products derived from this software without specific prior written permission.
//	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
//	INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//	DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//	SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//	SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
//	WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//	OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// The changes: the output columns renamed to pgvigil's, both read as one row per index, with the DO / UNDO lines of
// postgres_dba's sql/i5_indexes_migration.sql pattern (same licence); the undo keeps CONCURRENTLY for a UNIQUE index
// too (the original replaces only "CREATE INDEX"). The redundant read: a duplicate flag (equal columns, operator
// classes, sort options and collations); the shorter index's sort options and collations must lead the longer's
// (the original compares columns and operator classes only); a partition's index left out (it cannot be dropped alone; it follows its
// parent's); a unique index counted redundant only to a primary key on the same columns (the original lets a unique
// index through whenever the other is a primary key, so its DROP removed a uniqueness rule). The invalid read:
// limited to non-catalog schemas, and a partitioned index left out (an index built ON ONLY the parent stays invalid
// until every partition's index is attached: a staged build, and neither CONCURRENTLY line would run on it).
// The unused read is pgvigil's own (postgres_dba's i1 comes from pgx_scripts, whose licence was not read); an unused
// index that covers a redundant or duplicate one is left out of it, so the DO lines never drop both of a pair.
// Every read runs with search_path = pg_catalog, so the DROP and CREATE lines name the schema whatever the login's
// search_path is.
// The fifth read (0056, the inventory) is every index of pg_stat_user_indexes with its definition, size and usage
// counters: the whole list beside the four problem reads; the import keeps it current and writes one row per index
// and UTC day from the day's first read.
type indexesCollector struct{}

func init() { Register(indexesCollector{}) }

func (indexesCollector) Name() string                   { return "indexes" }
func (indexesCollector) DefaultInterval() time.Duration { return time.Hour }
func (indexesCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (indexesCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("indexes runs per instance (RunInstance)")
}

// indexesDBSQL: the database read, how many indexes it holds, and since when its usage counters count (the
// database's stats_reset, else the server's start: a crash restart clears them, a clean one keeps them).
const indexesDBSQL = `
SELECT 'db' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname,
       (SELECT count(*) FROM pg_stat_user_indexes)::int AS indexes,
       (SELECT coalesce(sum(pg_relation_size(indexrelid)), 0)::bigint FROM pg_stat_user_indexes) AS index_bytes,
       coalesce((SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()), pg_postmaster_start_time()) AS stats_since,
       pg_is_in_recovery() AS is_replica`

// indexesUnusedSQL: no index scan since the counters started; an index behind a constraint (primary key, unique,
// exclusion) or a partition's index (it follows its parent's) is not a candidate.
const indexesUnusedSQL = `
SELECT 'index' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, s.indexrelid::bigint AS indexrelid, 'unused' AS problem,
       s.schemaname::text AS schema_name, s.relname::text AS table_name, s.indexrelname::text AS index_name,
       am.amname::text AS access_method, pg_relation_size(s.indexrelid) AS index_bytes, pg_relation_size(s.relid) AS table_bytes,
       s.idx_scan, NULL::text AS covered_by, NULL::text AS covered_by_def, pg_get_indexdef(s.indexrelid) AS index_def,
       NULL::boolean AS supports_fk,
       format('DROP INDEX CONCURRENTLY %s;', s.indexrelid::regclass::text) AS drop_sql,
       regexp_replace(pg_get_indexdef(s.indexrelid), '^CREATE (UNIQUE )?INDEX', 'CREATE \1INDEX CONCURRENTLY') || ';' AS undo_sql
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON i.indexrelid = s.indexrelid
  JOIN pg_class c ON c.oid = s.indexrelid
  JOIN pg_am am ON am.oid = c.relam
 WHERE s.idx_scan = 0 AND i.indisvalid AND NOT i.indisunique AND NOT i.indisprimary AND NOT i.indisexclusion
   AND NOT c.relispartition
   AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = s.indexrelid)`

// indexesRedundantSQL is postgres_dba's sql/i2_redundant_indexes.sql (BSD-3, Copyright (c) 2017, Nikolay
// Samokhvalov) with pgvigil's output columns and a duplicate flag.
const indexesRedundantSQL = `
with fk_indexes as (
  select
    n.nspname as schema_name,
    ci.relname as index_name,
    cr.relname as table_name,
    (confrelid::regclass)::text as fk_table_ref,
    array_to_string(indclass, ', ') as opclasses
  from pg_index i
  join pg_class ci on ci.oid = i.indexrelid and ci.relkind = 'i'
  join pg_class cr on cr.oid = i.indrelid and cr.relkind = 'r'
  join pg_namespace n on n.oid = ci.relnamespace
  join pg_constraint cn on cn.conrelid = cr.oid
  left join pg_stat_user_indexes si on si.indexrelid = i.indexrelid
  where
     contype = 'f'
     and i.indisunique is false
     and conkey is not null
     and ci.relpages > 0
     and si.idx_scan < 10
),
index_data as (
  select
    *,
    (select string_agg(lpad(i, 3, '0'), ' ') from unnest(string_to_array(indkey::text, ' ')) i) as columns,
    array_to_string(indclass, ', ') as opclasses
  from pg_index i
  join pg_class ci on ci.oid = i.indexrelid and ci.relkind = 'i'
  where indisvalid = true and ci.relpages > 0 and not ci.relispartition
), redundant_indexes as (
  select
    i2.indexrelid as index_id,
    tnsp.nspname AS schema_name,
    trel.relname AS table_name,
    pg_relation_size(trel.oid) as table_size_bytes,
    irel.relname AS index_name,
    am1.amname as access_method,
    (i1.indexrelid::regclass)::text as reason,
    i1.indexrelid as reason_index_id,
    pg_get_indexdef(i1.indexrelid) main_index_def,
    pg_get_indexdef(i2.indexrelid) index_def,
    pg_relation_size(i2.indexrelid) index_size_bytes,
    s.idx_scan as index_usage,
    i2.opclasses,
    (i1.columns = i2.columns and i1.opclasses = i2.opclasses
     and i1.indoption::text = i2.indoption::text and i1.indcollation::text = i2.indcollation::text) as is_duplicate
  from
    index_data as i1
    join index_data as i2 on (
        i1.indrelid = i2.indrelid
        and i1.indexrelid <> i2.indexrelid
    )
    inner join pg_opclass op1 on i1.indclass[0] = op1.oid
    inner join pg_opclass op2 on i2.indclass[0] = op2.oid
    inner join pg_am am1 on op1.opcmethod = am1.oid
    inner join pg_am am2 on op2.opcmethod = am2.oid
    join pg_stat_user_indexes as s on s.indexrelid = i2.indexrelid
    join pg_class as trel on trel.oid = i2.indrelid
    join pg_namespace as tnsp on trel.relnamespace = tnsp.oid
    join pg_class as irel on irel.oid = i2.indexrelid
  where
    not i2.indisprimary
    and not (
        i2.indisunique and not (i1.indisprimary and i1.columns = i2.columns)
    )
    and am1.amname = am2.amname
    and i1.columns like (i2.columns || '%')
    and i1.opclasses like (i2.opclasses || '%')
    -- pgvigil: the sort options and collations of index 2 lead index 1's too ((a, b DESC) is not served by (a, b))
    and (i1.indoption::text || ' ') like (i2.indoption::text || ' %')
    and (i1.indcollation::text || ' ') like (i2.indcollation::text || ' %')
    and pg_get_expr(i1.indexprs, i1.indrelid) is not distinct from pg_get_expr(i2.indexprs, i2.indrelid)
    and pg_get_expr(i1.indpred, i1.indrelid) is not distinct from pg_get_expr(i2.indpred, i2.indrelid)
), redundant_indexes_fk as (
  select
    ri.*,
    (
      select count(1)
      from fk_indexes fi
      where
        fi.fk_table_ref = ri.table_name
        and fi.opclasses like (ri.opclasses || '%')
     ) > 0 as supports_fk
  from redundant_indexes ri
),
redundant_indexes_tmp_num as (
  select
    row_number() over () num,
    rig.*
  from redundant_indexes_fk rig
  order by index_id
), redundant_indexes_tmp_cut as (
  select
    ri1.*,
    ri2.num as r_num
  from redundant_indexes_tmp_num ri1
  left join redundant_indexes_tmp_num ri2 on ri2.reason_index_id = ri1.index_id and ri1.reason_index_id = ri2.index_id
  where ri1.num < ri2.num or ri2.num is null
), redundant_indexes_cut_grouped as (
  select
    distinct(num),
    *
  from redundant_indexes_tmp_cut
  order by index_size_bytes desc
)
select
  'index' as kind,
  (select oid::bigint from pg_database where datname = current_database()) as dbid,
  current_database()::text as datname,
  index_id::bigint as indexrelid,
  case when bool_or(is_duplicate) then 'duplicate' else 'redundant' end as problem,
  schema_name::text as schema_name,
  table_name::text as table_name,
  index_name::text as index_name,
  access_method::text as access_method,
  index_size_bytes as index_bytes,
  table_size_bytes as table_bytes,
  index_usage as idx_scan,
  string_agg(distinct reason, ', ') as covered_by,
  string_agg(main_index_def, '; ') as covered_by_def,
  string_agg(distinct reason_index_id::text, ',') as covered_by_ids,
  index_def,
  supports_fk,
  format('DROP INDEX CONCURRENTLY %s;', index_id::regclass::text) as drop_sql,
  regexp_replace(index_def, '^CREATE (UNIQUE )?INDEX', 'CREATE \1INDEX CONCURRENTLY') || ';' as undo_sql
from redundant_indexes_cut_grouped
group by
  index_id,
  schema_name,
  table_name,
  table_size_bytes,
  index_name,
  access_method,
  index_def,
  index_size_bytes,
  index_usage,
  supports_fk`

// indexesInvalidSQL is postgres_dba's sql/i4_invalid_indexes.sql (BSD-3, as above) with pgvigil's columns, limited
// to non-catalog schemas. An index being built CONCURRENTLY right now is invalid until it finishes: the next hourly
// read no longer lists it.
const indexesInvalidSQL = `
select
    'index' as kind,
    (select oid::bigint from pg_database where datname = current_database()) as dbid,
    current_database()::text as datname,
    pidx.indexrelid::bigint as indexrelid,
    'invalid' as problem,
    pn.nspname::text as schema_name,
    pct.relname::text as table_name,
    pci.relname::text as index_name,
    am.amname::text as access_method,
    pg_relation_size(pidx.indexrelid) as index_bytes,
    pg_relation_size(pct.oid) as table_bytes,
    NULL::bigint as idx_scan,
    NULL::text as covered_by,
    NULL::text as covered_by_def,
    pg_get_indexdef(pidx.indexrelid) as index_def,
    NULL::boolean as supports_fk,
    format('DROP INDEX CONCURRENTLY %s;', pidx.indexrelid::regclass::text) as drop_sql,
    regexp_replace(pg_get_indexdef(pidx.indexrelid), '^CREATE (UNIQUE )?INDEX', 'CREATE \1INDEX CONCURRENTLY') || ';' as undo_sql
from pg_index pidx
join pg_class as pci on pci.oid = pidx.indexrelid
join pg_class as pct on pct.oid = pidx.indrelid
join pg_am am on am.oid = pci.relam
left join pg_namespace pn on pn.oid = pct.relnamespace
where pidx.indisvalid = false
  and pci.relkind = 'i'
  and pn.nspname not in ('pg_catalog', 'information_schema')`

// indexesInventorySQL: every index of pg_stat_user_indexes (0056): its definition, size and usage counters.
// last_idx_scan exists from PostgreSQL 16: to_jsonb(s) reads it where it is and NULL below, so one statement serves
// every version. A partitioned table's own index (relkind 'I') is not in pg_stat_user_indexes; its partitions' indexes
// are, each marked is_partition. columns is the definition after USING <method>: the key columns, expressions, INCLUDE
// and predicate as pg_get_indexdef prints them.
const indexesInventorySQL = `
SELECT 'inv' AS kind, (SELECT oid::bigint FROM pg_database WHERE datname = current_database()) AS dbid,
       current_database()::text AS datname, s.indexrelid::bigint AS indexrelid, s.relid::bigint AS relid,
       s.schemaname::text AS schema_name, s.relname::text AS table_name, s.indexrelname::text AS index_name,
       am.amname::text AS access_method, i.indisunique AS is_unique, i.indisprimary AS is_primary, i.indisvalid AS is_valid,
       c.relispartition AS is_partition,
       regexp_replace(pg_get_indexdef(s.indexrelid), '^CREATE (UNIQUE )?INDEX .* USING [a-z0-9_]+ ', '') AS columns,
       pg_get_indexdef(s.indexrelid) AS index_def, pg_relation_size(s.indexrelid) AS index_bytes,
       s.idx_scan, s.idx_tup_read, s.idx_tup_fetch, (to_jsonb(s)->>'last_idx_scan')::timestamptz AS last_idx_scan
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON i.indexrelid = s.indexrelid
  JOIN pg_class c ON c.oid = s.indexrelid
  JOIN pg_am am ON am.oid = c.relam`

// RunInstance reads the connected database on conn and every other connectable database on its own connection, up to
// tablesMaxDatabases (the tables collection's bound).
func (indexesCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	dbs, err := tablesDatabases(ctx, conn)
	if err != nil {
		return nil, err
	}
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	out := []Row{}
	if len(dbs) > tablesMaxDatabases {
		// one error row per database left out, so the import keeps its rows as they were instead of marking them gone
		for _, db := range dbs[tablesMaxDatabases:] {
			out = append(out, Row{"kind": "collector_error", "source": "indexes:" + db,
				"message": fmt.Sprintf("%d databases: the first %d by name are read", len(dbs), tablesMaxDatabases)})
		}
		dbs = dbs[:tablesMaxDatabases]
	}
	for _, db := range dbs {
		var rows []Row
		if db == cur {
			rows, err = indexesRead(ctx, conn)
		} else {
			rows, err = indexesReadOther(ctx, in, db)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, Row{"kind": "collector_error", "source": "indexes:" + db, "message": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}

// indexesRead runs the five reads on one database's connection; any failure fails the database as a whole, so its
// stored rows stay as they were. The connection is this collection's own (RunOnce opens one per run; the other
// databases' are opened here), so its search_path is set for the reads and not put back.
func indexesRead(ctx context.Context, conn *pgx.Conn) ([]Row, error) {
	if _, err := conn.Exec(ctx, `SET search_path = pg_catalog`); err != nil {
		return nil, fmt.Errorf("search_path: %w", err)
	}
	out := []Row{}
	for _, q := range []struct{ name, sql string }{
		{"database", indexesDBSQL}, {"unused", indexesUnusedSQL}, {"redundant", indexesRedundantSQL}, {"invalid", indexesInvalidSQL},
		{"inventory", indexesInventorySQL},
	} {
		r, err := conn.Query(ctx, q.sql)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", q.name, err)
		}
		rows, err := rowsToMaps(r)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", q.name, err)
		}
		out = append(out, rows...)
	}
	return dropCovers(out), nil
}

// dropCovers leaves out an unused index that covers a redundant or duplicate one of the same read: its own DO line
// and the covered index's together would leave the columns with no index at all.
func dropCovers(rows []Row) []Row {
	covers := map[string]bool{}
	for _, r := range rows {
		if ids, ok := r["covered_by_ids"].(string); ok && (r["problem"] == "redundant" || r["problem"] == "duplicate") {
			for _, id := range strings.Split(ids, ",") {
				covers[strings.TrimSpace(id)] = true
			}
		}
	}
	out := rows[:0]
	for _, r := range rows {
		if r["problem"] == "unused" && covers[fmt.Sprint(r["indexrelid"])] {
			continue
		}
		out = append(out, r)
	}
	return out
}

// indexesReadOther connects to another database with the instance's DSN and the collector's session settings.
func indexesReadOther(ctx context.Context, in config.Instance, db string) ([]Row, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("dsn %q resolved to an empty string", in.DSNRaw)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.Database = db
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		return nil, fmt.Errorf("session setup: %w", err)
	}
	return indexesRead(ctx, conn)
}
