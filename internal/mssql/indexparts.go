package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The index read widened (Darling slice 3, task D404; sp_BlitzIndex 8.34's and sp_IndexCleanup 2.11's sources, each
// read named by its line in docs and in 0169): after a database's index read, five more reads of the same database,
// each a SELECT through its own sys.sp_executesql (nothing written). A part that fails - the read login's lock timeout,
// a right denied, any error - is stored as not read with the server's words on the database's row
// (pgvigil.mssql_index_parts), and the index read and the other parts stand.
//
//	ixextra   per index: the object type (U table, V indexed view), the data space (name and type: ROWS_FILEGROUP,
//	          PARTITION_SCHEME, ...), the partition function (name, argument type, partition count, its range as
//	          'RANGE RIGHT FOR VALUES (...)'), the partitioning column, whether any partition is uncompressed, the
//	          operational counters summed over the partitions (sys.dm_db_index_operational_stats: row and page lock
//	          waits, page latch and page I/O latch waits, forwarded fetches, leaf deletes - counted since the object's
//	          metadata entered the cache, not since the server's start) and a filtered index's filter columns: the
//	          table's columns whose bracketed name the server's filter_definition holds (sp_IndexCleanup's way, IC
//	          L8180; the server writes every column of a filter bracketed). sp_BlitzIndex reads them from
//	          sys.sql_expression_dependencies (BI L2907-2925), which only db_owner may read by default (Learn): the read
//	          login gets Msg 229 there (box run d404-g1). Merged into the index rows.
//	segments  per columnstore index: its columns of sp_BlitzIndex's types (char / varchar / nchar / nvarchar / binary /
//	          varbinary not (max), uniqueidentifier, datetimeoffset of scale over 2) with a compressed segment that keeps
//	          no min / max deep data - such an index was built before SQL Server 2022 and gains string segment
//	          elimination only from a rebuild. Read only where sys.column_store_segments has min_deep_data (2022 and
//	          Azure); elsewhere the index's list stays empty-unknown (NULL) and the database's row says why.
//	heaps     one row per heap of a user table: size, rows, usage, the operational counters, the data space, the
//	          table's create date (stored in pgvigil.mssql_heap: no consumer of mssql_index sees index 0).
//	shape     one row per user table and indexed view: total columns, the declared bytes of the non-LOB columns,
//	          the LOB columns (max_length -1), the string-or-LOB columns by sp_BlitzIndex's own test (the type named by
//	          user type IN varchar / nvarchar / char, or max_length -1), any sparse column, any text / ntext / image
//	          column, the clustered key's bytes and key-column count, and sys.tables' temporal_type and history table.
//	fks       one row per enabled foreign key: its parent and referenced table and the parent columns in constraint
//	          order. Whether an index supports it is the repository's judgement, never the collector's.
//
// heaps, shape and fks keep at most ixIndexCap rows each (the heaps the largest first, the rest by name); the
// database's row names a part that was cut.

// indexParts names the parts in the order they are read.
var indexParts = []string{"ixextra", "segments", "heaps", "shape", "fks"}

// ixBase is the set every part shares with indexesSQL: user tables and indexed views, not memory-optimized.
const ixBase = `o.is_ms_shipped = 0 AND o.type IN ('U', 'V')
  AND NOT EXISTS (SELECT 1 FROM sys.tables mt WHERE mt.object_id = o.object_id AND mt.is_memory_optimized = 1)`

// ixSpaceCols / ixSpaceJoins: the data space, the partition function and the partitioning column of index i, whether
// any of its partitions is uncompressed, and its operational counters summed over the partitions.
const ixSpaceCols = `CAST(ds.name AS nvarchar(128)) AS data_space_name, CAST(ds.type_desc AS nvarchar(60)) AS data_space_type,
  CAST(pf.name AS nvarchar(128)) AS partition_function, CAST(pf.arg_type AS nvarchar(200)) AS pf_type, CAST(pf.fanout AS int) AS pf_partitions,
  CAST(pf.on_right AS int) AS pf_on_right, pf.values_json AS pf_values_json, CAST(pc.name AS nvarchar(128)) AS partition_column,
  CAST(pt.unc AS int) AS any_uncompressed,
  CAST(os.rlc AS bigint) AS row_lock_wait_count, CAST(os.rlm AS bigint) AS row_lock_wait_ms, CAST(os.plc AS bigint) AS page_lock_wait_count,
  CAST(os.plm AS bigint) AS page_lock_wait_ms, CAST(os.pac AS bigint) AS page_latch_wait_count, CAST(os.pam AS bigint) AS page_latch_wait_ms,
  CAST(os.pic AS bigint) AS page_io_latch_wait_count, CAST(os.pim AS bigint) AS page_io_latch_wait_ms,
  CAST(os.ff AS bigint) AS forwarded_fetch_count, CAST(os.ld AS bigint) AS leaf_delete_count`

const ixSpaceJoins = `LEFT JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
OUTER APPLY (SELECT f.name, f.fanout, f.boundary_value_on_right AS on_right,
                    TYPE_NAME(pp.user_type_id) + CASE
                      WHEN TYPE_NAME(pp.system_type_id) IN ('varchar', 'char', 'varbinary', 'binary') THEN '(' + CAST(pp.max_length AS varchar(10)) + ')'
                      WHEN TYPE_NAME(pp.system_type_id) IN ('nvarchar', 'nchar') THEN '(' + CAST(pp.max_length / 2 AS varchar(10)) + ')'
                      WHEN TYPE_NAME(pp.system_type_id) IN ('decimal', 'numeric') THEN '(' + CAST(pp.precision AS varchar(3)) + ',' + CAST(pp.scale AS varchar(3)) + ')'
                      WHEN TYPE_NAME(pp.system_type_id) IN ('datetime2', 'time', 'datetimeoffset') THEN '(' + CAST(pp.scale AS varchar(3)) + ')'
                      ELSE '' END AS arg_type,
                    (SELECT ` + pfValueText + ` AS v FROM sys.partition_range_values v
                      WHERE v.function_id = f.function_id ORDER BY v.boundary_id FOR JSON PATH) AS values_json
               FROM sys.partition_schemes sch JOIN sys.partition_functions f ON f.function_id = sch.function_id
               JOIN sys.partition_parameters pp ON pp.function_id = f.function_id AND pp.parameter_id = 1
              WHERE sch.data_space_id = i.data_space_id) pf
OUTER APPLY (SELECT TOP (1) c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.partition_ordinal = 1) pc
OUTER APPLY (SELECT MAX(CASE WHEN p.data_compression = 0 THEN 1 ELSE 0 END) AS unc FROM sys.partitions p
              WHERE p.object_id = i.object_id AND p.index_id = i.index_id) pt
LEFT JOIN (SELECT z.object_id, z.index_id, SUM(z.row_lock_wait_count) AS rlc, SUM(z.row_lock_wait_in_ms) AS rlm, SUM(z.page_lock_wait_count) AS plc,
                  SUM(z.page_lock_wait_in_ms) AS plm, SUM(z.page_latch_wait_count) AS pac, SUM(z.page_latch_wait_in_ms) AS pam,
                  SUM(z.page_io_latch_wait_count) AS pic, SUM(z.page_io_latch_wait_in_ms) AS pim, SUM(z.forwarded_fetch_count) AS ff,
                  SUM(z.leaf_delete_count) AS ld
             FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) z GROUP BY z.object_id, z.index_id) os
       ON os.object_id = i.object_id AND os.index_id = i.index_id`

// pfValueText is a partition boundary (a sql_variant) as its DDL would write it, with nothing lost: a sql_variant cast
// to nvarchar takes style 0, so a datetime2 reads 'Jan  1 2026 12:00AM' (its seconds and fractions gone; box run
// d404-g3), money keeps 2 decimals and float 6 digits - two functions that differ there would read 'essentially the
// same'. datetime and smalldatetime by style 121 ('2026-01-31 23:59:59.997'), datetime2, datetimeoffset and time at 7
// digits, money at 4 decimals (style 2), float and real at 17 digits (style 3, SQL Server 2016 and later), binary as
// 0x hex (style 1), a string quoted ('m', N'm'); every other type as it casts.
const pfValueText = `CASE
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') IN ('datetime', 'smalldatetime') THEN CONVERT(nvarchar(4000), CAST(v.value AS datetime), 121)
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') = 'datetime2' THEN CONVERT(nvarchar(4000), CAST(v.value AS datetime2(7)), 121)
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') = 'datetimeoffset' THEN CONVERT(nvarchar(4000), CAST(v.value AS datetimeoffset(7)), 121)
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') = 'time' THEN CONVERT(nvarchar(4000), CAST(v.value AS time(7)), 114)
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') IN ('money', 'smallmoney') THEN CONVERT(nvarchar(4000), CAST(v.value AS money), 2)
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') IN ('float', 'real') THEN CONVERT(nvarchar(4000), CAST(v.value AS float), 3)
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') IN ('binary', 'varbinary') THEN CONVERT(nvarchar(4000), CAST(v.value AS varbinary(8000)), 1)
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') IN ('char', 'varchar') THEN N'''' + REPLACE(CAST(v.value AS nvarchar(4000)), N'''', N'''''') + N''''
  WHEN SQL_VARIANT_PROPERTY(v.value, 'BaseType') IN ('nchar', 'nvarchar') THEN N'N''' + REPLACE(CAST(v.value AS nvarchar(4000)), N'''', N'''''') + N''''
  ELSE CAST(v.value AS nvarchar(4000)) END`

// ixExtraSQL: per index of indexesSQL's set, what the index read does not carry.
var ixExtraSQL = `SELECT CAST(i.object_id AS bigint) AS object_id, CAST(i.index_id AS int) AS index_id, CAST(RTRIM(o.type) AS nvarchar(2)) AS object_type,
  ` + ixSpaceCols + `,
  CASE WHEN i.has_filter = 1 THEN ISNULL((SELECT c.name AS n FROM sys.columns c
         WHERE c.object_id = i.object_id AND CHARINDEX(QUOTENAME(c.name) COLLATE DATABASE_DEFAULT, i.filter_definition COLLATE DATABASE_DEFAULT) > 0
         ORDER BY c.name FOR JSON PATH), N'[]') END AS filter_json
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id
` + ixSpaceJoins + `
WHERE i.index_id > 0 AND ` + ixBase

// ixSegmentsProbe: whether this server's sys.column_store_segments has min_deep_data (SQL Server 2022, Azure).
const ixSegmentsProbe = `SELECT CAST(COUNT(*) AS int) AS n FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.column_store_segments') AND name = N'min_deep_data'`

// ixSegmentsSQL: sp_BlitzIndex 8.34 L3011-3034's test, per columnstore index and column.
const ixSegmentsSQL = `SELECT DISTINCT CAST(p.object_id AS bigint) AS object_id, CAST(p.index_id AS int) AS index_id, CAST(c.name AS nvarchar(128)) AS column_name
FROM sys.column_store_segments seg
JOIN sys.partitions p ON seg.partition_id = p.partition_id
JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.index_columns ic ON ic.object_id = p.object_id AND ic.index_id = p.index_id AND ic.index_column_id = seg.column_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.types t ON c.system_type_id = t.system_type_id AND t.user_type_id = t.system_type_id
WHERE i.type IN (5, 6) AND seg.row_count > 0 AND seg.min_deep_data IS NULL AND seg.max_deep_data IS NULL
  AND ((t.name IN (N'char', N'varchar', N'nchar', N'nvarchar', N'binary', N'varbinary') AND c.max_length <> -1)
       OR t.name = N'uniqueidentifier' OR (t.name = N'datetimeoffset' AND c.scale > 2))`

// ixHeapsSQL: the heaps of user tables, the largest first.
var ixHeapsSQL = `SELECT TOP (@cap) 'heap' AS kind, CAST(i.object_id AS bigint) AS object_id,
  CAST(SCHEMA_NAME(o.schema_id) AS nvarchar(128)) AS schema_name, CAST(o.name AS nvarchar(128)) AS table_name,
  CAST(ps.row_count AS bigint) AS row_count, CAST(ps.reserved_kb AS bigint) AS size_kb, CAST(ISNULL(pn.n, 0) AS int) AS partitions,
  CAST(pn.compression AS nvarchar(60)) AS compression,
  CAST(ISNULL(us.user_seeks, 0) AS bigint) AS user_seeks, CAST(ISNULL(us.user_scans, 0) AS bigint) AS user_scans,
  CAST(ISNULL(us.user_lookups, 0) AS bigint) AS user_lookups, CAST(ISNULL(us.user_updates, 0) AS bigint) AS user_updates,
  ` + utcOf("(SELECT MAX(x.v) FROM (VALUES (us.last_user_seek), (us.last_user_scan), (us.last_user_lookup)) x(v))") + ` AS last_read,
  ` + utcOf("us.last_user_update") + ` AS last_write, ` + utcOf("o.create_date") + ` AS table_created,
  ` + ixSpaceCols + `
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id
LEFT JOIN (SELECT p.object_id, SUM(p.row_count) AS row_count, SUM(p.reserved_page_count) * 8 AS reserved_kb
             FROM sys.dm_db_partition_stats p WHERE p.index_id = 0 GROUP BY p.object_id) ps ON ps.object_id = i.object_id
LEFT JOIN (SELECT p.object_id, COUNT(*) AS n,
                  CASE WHEN MIN(p.data_compression_desc) = MAX(p.data_compression_desc) THEN MIN(p.data_compression_desc) ELSE N'MIXED' END AS compression
             FROM sys.partitions p WHERE p.index_id = 0 GROUP BY p.object_id) pn ON pn.object_id = i.object_id
LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = 0
` + ixSpaceJoins + `
WHERE i.index_id = 0 AND o.type = 'U' AND ` + ixBase + `
ORDER BY ISNULL(ps.reserved_kb, 0) DESC, i.object_id`

// ixShapeSQL: per user table and indexed view, its columns' shape and its temporal type (sp_BlitzIndex L1627-1663,
// L5568-5575, L5698-5708; sp_IndexCleanup's sparse and text / ntext / image tests), by name.
var ixShapeSQL = `SELECT TOP (@cap) 'shape' AS kind, CAST(o.object_id AS bigint) AS object_id,
  CAST(SCHEMA_NAME(o.schema_id) AS nvarchar(128)) AS schema_name, CAST(o.name AS nvarchar(128)) AS table_name, CAST(RTRIM(o.type) AS nvarchar(2)) AS object_type,
  CAST(cl.n AS int) AS total_columns, CAST(cl.nonlob AS int) AS nonlob_bytes, CAST(cl.lob AS int) AS lob_columns, CAST(cl.str AS int) AS string_columns,
  CAST(cl.sp AS int) AS has_sparse, CAST(cl.ti AS int) AS has_text_image, CAST(k.kb AS int) AS cx_key_bytes, CAST(k.kc AS int) AS cx_key_columns,
  CAST(tb.temporal_type AS int) AS temporal_type, CAST(tb.history_table_id AS bigint) AS history_table_id
FROM sys.objects o
LEFT JOIN sys.tables tb ON tb.object_id = o.object_id
CROSS APPLY (SELECT COUNT(*) AS n, SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END) AS nonlob,
                    SUM(CASE WHEN c.max_length = -1 THEN 1 ELSE 0 END) AS lob,
                    SUM(CASE WHEN t.name IN (N'varchar', N'nvarchar', N'char') OR c.max_length = -1 THEN 1 ELSE 0 END) AS str,
                    MAX(CAST(c.is_sparse AS int)) AS sp, MAX(CASE WHEN c.system_type_id IN (34, 35, 99) THEN 1 ELSE 0 END) AS ti
               FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE c.object_id = o.object_id) cl
OUTER APPLY (SELECT SUM(CASE WHEN c.max_length = -1 THEN 0 ELSE c.max_length END) AS kb, COUNT(*) AS kc
               FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
              WHERE ic.object_id = o.object_id AND ic.index_id = 1 AND ic.key_ordinal > 0 HAVING COUNT(*) > 0) k
WHERE ` + ixBase + ` AND (o.type = 'U' OR EXISTS (SELECT 1 FROM sys.indexes iv WHERE iv.object_id = o.object_id AND iv.index_id = 1))
ORDER BY SCHEMA_NAME(o.schema_id), o.name`

// ixFKSQL: the enabled foreign keys, their parent columns in constraint order, by parent table and name.
const ixFKSQL = `SELECT TOP (@cap) 'fk' AS kind, CAST(fk.object_id AS bigint) AS object_id, CAST(fk.name AS nvarchar(128)) AS fk_name,
  CAST(fk.parent_object_id AS bigint) AS parent_object_id, CAST(OBJECT_SCHEMA_NAME(fk.parent_object_id) AS nvarchar(128)) AS parent_schema,
  CAST(OBJECT_NAME(fk.parent_object_id) AS nvarchar(128)) AS parent_table, CAST(fk.referenced_object_id AS bigint) AS ref_object_id,
  CAST(OBJECT_SCHEMA_NAME(fk.referenced_object_id) AS nvarchar(128)) AS ref_schema, CAST(OBJECT_NAME(fk.referenced_object_id) AS nvarchar(128)) AS ref_table,
  (SELECT c.name AS n FROM sys.foreign_key_columns k JOIN sys.columns c ON c.object_id = k.parent_object_id AND c.column_id = k.parent_column_id
    WHERE k.constraint_object_id = fk.object_id ORDER BY k.constraint_column_id FOR JSON PATH) AS cols_json
FROM sys.foreign_keys fk
WHERE fk.is_disabled = 0 AND fk.is_ms_shipped = 0
  AND NOT EXISTS (SELECT 1 FROM sys.tables mt WHERE mt.object_id = fk.parent_object_id AND mt.is_memory_optimized = 1)
ORDER BY OBJECT_SCHEMA_NAME(fk.parent_object_id), OBJECT_NAME(fk.parent_object_id), fk.name`

// ixKey is an index's identity inside a database.
type ixKey struct {
	object int64
	index  int64
}

func ixKeyOf(r collect.Row) ixKey {
	o, _ := r["object_id"].(int64)
	i, _ := r["index_id"].(int64)
	return ixKey{o, i}
}

// nameList turns the server's FOR JSON array of {n: name} into quoted names (empty: no name).
func nameList(v any) ([]string, error) {
	cols, err := indexColumns(v)
	if err != nil {
		return nil, err
	}
	for i, c := range cols {
		cols[i] = strings.TrimSuffix(c, " DESC")
	}
	return cols, nil
}

// pfRange is a partition function's range as its DDL says it: 'RANGE RIGHT FOR VALUES (100, 200)'.
func pfRange(onRight any, valuesJSON any) (any, error) {
	s, ok := valuesJSON.(string)
	if !ok {
		return nil, nil
	}
	var vals []struct {
		V *string `json:"v"`
	}
	if strings.TrimSpace(s) != "" {
		if err := json.Unmarshal([]byte(s), &vals); err != nil {
			return nil, err
		}
	}
	out := make([]string, 0, len(vals))
	for _, v := range vals {
		if v.V == nil {
			out = append(out, "NULL")
		} else {
			out = append(out, *v.V)
		}
	}
	side := "LEFT"
	if r, _ := onRight.(int64); r == 1 {
		side = "RIGHT"
	}
	return "RANGE " + side + " FOR VALUES (" + strings.Join(out, ", ") + ")", nil
}

// spaceFields moves a part's data-space and counter columns into dst: the range built, the partitioning column quoted.
func spaceFields(dst, src collect.Row) error {
	for _, k := range []string{"data_space_name", "data_space_type", "partition_function", "pf_type", "pf_partitions", "any_uncompressed",
		"row_lock_wait_count", "row_lock_wait_ms", "page_lock_wait_count", "page_lock_wait_ms", "page_latch_wait_count", "page_latch_wait_ms",
		"page_io_latch_wait_count", "page_io_latch_wait_ms", "forwarded_fetch_count", "leaf_delete_count"} {
		dst[k] = src[k]
	}
	rng, err := pfRange(src["pf_on_right"], src["pf_values_json"])
	if err != nil {
		return err
	}
	dst["pf_range"] = rng
	delete(dst, "pf_on_right")
	delete(dst, "pf_values_json")
	if c, ok := src["partition_column"].(string); ok && c != "" {
		dst["partition_column"] = quoteName(c)
	} else {
		dst["partition_column"] = nil
	}
	return nil
}

// mergeExtra puts the ixextra part's columns on the index rows it names; an index the part did not list keeps them
// absent (NULL: not read).
func mergeExtra(idx []collect.Row, extra []collect.Row) (bad int) {
	by := make(map[ixKey]collect.Row, len(extra))
	for _, e := range extra {
		by[ixKeyOf(e)] = e
	}
	for _, r := range idx {
		e, ok := by[ixKeyOf(r)]
		if !ok {
			continue
		}
		// a scratch row first: a row that cannot be read leaves the index row as it was (review NIT 1)
		t := collect.Row{"object_type": e["object_type"]}
		if err := spaceFields(t, e); err != nil {
			bad++
			continue
		}
		if e["filter_json"] != nil {
			cols, err := nameList(e["filter_json"])
			if err != nil {
				bad++
				continue
			}
			t["filter_columns"] = cols
		}
		for k, v := range t {
			r[k] = v
		}
	}
	return bad
}

// isColumnstore: the index type of a columnstore index (CLUSTERED COLUMNSTORE, NONCLUSTERED COLUMNSTORE).
func isColumnstore(r collect.Row) bool {
	t, _ := r["index_type"].(string)
	return strings.HasSuffix(t, "COLUMNSTORE")
}

// mergeSegments gives every columnstore index its list of columns needing a rebuild (empty: none), quoted, by name.
func mergeSegments(idx []collect.Row, segs []collect.Row) {
	by := map[ixKey][]string{}
	for _, s := range segs {
		if c, ok := s["column_name"].(string); ok {
			k := ixKeyOf(s)
			by[k] = append(by[k], quoteName(c))
		}
	}
	for _, r := range idx {
		if !isColumnstore(r) {
			continue
		}
		cols := by[ixKeyOf(r)]
		sort.Strings(cols)
		if cols == nil {
			cols = []string{}
		}
		r["cs_rebuild_columns"] = cols
	}
}

// partRows names a part's rows with their database and finishes their columns; a row that cannot be read is dropped
// and counted.
func partRows(db userDB, part string, rows []collect.Row) (out []collect.Row, bad int) {
	out = make([]collect.Row, 0, len(rows))
	for _, r := range rows {
		switch part {
		case "heaps":
			if err := spaceFields(r, r); err != nil {
				bad++
				continue
			}
		case "fks":
			cols, err := nameList(r["cols_json"])
			if err != nil {
				bad++
				continue
			}
			delete(r, "cols_json")
			r["columns"] = cols
		}
		r["database_id"], r["database_name"] = db.id, db.name
		out = append(out, r)
	}
	return out, bad
}

// partResult is what the parts of one database's read left: the rows to store, the database row's words, and the
// parts that failed with the server's error (the run's last batch counts them: a failed part makes the run partial).
type partResult struct {
	rows   []collect.Row
	read   []string
	capped []string
	notes  []string
	failed map[string]error
}

// deepData is the run's one probe of sys.column_store_segments: ok, the column min_deep_data exists; err, the probe
// itself failed.
type deepData struct {
	ok  bool
	err error
}

// readIndexParts runs the five parts in a database whose index read succeeded: the index rows take ixextra's and
// segments' columns, the other parts' rows are returned. A context that ends, or the run's soft deadline passed
// (opt.Deadline, the one the index read keeps: the run's last batch still needs its time), stops the parts left.
func readIndexParts(ctx context.Context, conn *sql.Conn, db userDB, idx []collect.Row, deep deepData, deadline time.Time) partResult {
	res := partResult{failed: map[string]error{}}
	for _, p := range indexParts {
		if ctx.Err() != nil || (!deadline.IsZero() && time.Now().After(deadline)) {
			res.notes = append(res.notes, partWords[p]+": not read this time (the run's deadline came)")
			continue
		}
		var rows []collect.Row
		var err error
		switch p {
		case "ixextra":
			rows, err = qsRead(ctx, conn, db.quoted, ixExtraSQL, "")
		case "segments":
			if deep.err != nil {
				res.notes = append(res.notes, partWords[p]+": not read: the probe of sys.column_store_segments failed: "+deep.err.Error())
				continue
			}
			if !deep.ok {
				res.notes = append(res.notes, partWords[p]+": not read (sys.column_store_segments keeps no min_deep_data before SQL Server 2022)")
				continue
			}
			rows, err = qsRead(ctx, conn, db.quoted, ixSegmentsSQL, "")
		case "heaps":
			rows, err = qsRead(ctx, conn, db.quoted, ixHeapsSQL, "@cap int", sql.Named("cap", ixIndexCap+1))
		case "shape":
			rows, err = qsRead(ctx, conn, db.quoted, ixShapeSQL, "@cap int", sql.Named("cap", ixIndexCap+1))
		case "fks":
			rows, err = qsRead(ctx, conn, db.quoted, ixFKSQL, "@cap int", sql.Named("cap", ixIndexCap+1))
		}
		if err != nil {
			res.notes = append(res.notes, partWords[p]+": not read: "+err.Error())
			if ctx.Err() == nil {
				res.failed[p] = err
			}
			continue
		}
		switch p {
		case "ixextra":
			if bad := mergeExtra(idx, rows); bad > 0 {
				res.notes = append(res.notes, fmt.Sprintf("%s: %d row(s) could not be read", partWords[p], bad))
			}
		case "segments":
			mergeSegments(idx, rows)
		default:
			if len(rows) > ixIndexCap {
				rows = rows[:ixIndexCap]
				res.capped = append(res.capped, p)
				res.notes = append(res.notes, fmt.Sprintf("%s: more than %d: the first %d are stored", partWords[p], ixIndexCap, ixIndexCap))
			}
			out, bad := partRows(db, p, rows)
			if bad > 0 {
				res.notes = append(res.notes, fmt.Sprintf("%s: %d row(s) could not be read; they are not stored", partWords[p], bad))
			}
			res.rows = append(res.rows, out...)
		}
		res.read = append(res.read, p)
	}
	return res
}

// partWords names each part in a database row's note.
var partWords = map[string]string{
	"ixextra":  "data spaces, operational counters and filter columns",
	"segments": "columnstore segments",
	"heaps":    "heaps",
	"shape":    "table shapes",
	"fks":      "foreign keys",
}

// partSource names the view a part's failure is counted under in the run's collector_error rows.
var partSource = map[string]string{
	"ixextra":  "sys.dm_db_index_operational_stats",
	"segments": "sys.column_store_segments",
	"heaps":    "sys.dm_db_partition_stats",
	"shape":    "sys.columns",
	"fks":      "sys.foreign_key_columns",
}

// hasDeepData asks the server once per run whether sys.column_store_segments has min_deep_data.
func hasDeepData(ctx context.Context, conn *sql.Conn) deepData {
	var n sql.NullInt64
	if err := conn.QueryRowContext(ctx, ixSegmentsProbe).Scan(&n); err != nil {
		return deepData{err: err}
	}
	return deepData{ok: n.Int64 > 0}
}

// partFailures is the run's count of failed parts: per part, the databases and the first error.
type partFailures map[string]*struct {
	dbs   []string
	first error
}

func (f partFailures) add(db string, failed map[string]error) {
	for p, err := range failed {
		if f[p] == nil {
			f[p] = &struct {
				dbs   []string
				first error
			}{first: err}
		}
		f[p].dbs = append(f[p].dbs, db)
	}
}

// rows are the run's collector_error rows, one per failed part (a failed part makes the run partial, batch.go).
func (f partFailures) rows() []collect.Row {
	var out []collect.Row
	for _, p := range indexParts {
		x := f[p]
		if x == nil {
			continue
		}
		out = append(out, collect.Row{"kind": "collector_error", "source": partSource[p],
			"message": fmt.Sprintf("the %s of %d database(s) were not read (%s): %v; the index read of each stands", partWords[p], len(x.dbs), firstFew(x.dbs, 5), x.first)})
	}
	return out
}
