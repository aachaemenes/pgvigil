-- 0169: the SQL Server index read widened (task D404; C02a; internal/mssql/indexparts.go). Each new
-- value is a catalog or DMV read named by the sp_BlitzIndex 8.34 / sp_IndexCleanup 2.11 line it comes from (compared,
-- never copied; both MIT); the judgements are D405's and D436's (0170, 0212), never the collector's.
--
-- On pgvigil.mssql_index (NULL = not read: a read before 0169, or a part that failed):
--   object_type            U a table, V an indexed view (BI L1786)
--   data_space_name/_type  sys.data_spaces: ROWS_FILEGROUP, PARTITION_SCHEME, ... (BZ L7661-7671)
--   partition_function, pf_type, pf_partitions, pf_range
--                          the scheme's function: its name, argument type ('datetime2(3)'), partition count and range as
--                          its DDL says it ('RANGE RIGHT FOR VALUES (100, 200)') - an index is aligned when its function is
--                          'essentially the same' as its table's (Learn, 'Partitioned tables and indexes')
--   partition_column       the partitioning column, quoted (BI L1630, L3127-3140)
--   any_uncompressed       a partition with DATA_COMPRESSION NONE (IC tests each partition, IC L2287-2289)
--   row_lock_wait_count/_ms, page_lock_wait_count/_ms, page_latch_wait_count/_ms, page_io_latch_wait_count/_ms,
--   forwarded_fetch_count, leaf_delete_count
--                          sys.dm_db_index_operational_stats summed over the partitions (IC L2883-2896; BI L4938-4949):
--                          counted since the object's metadata entered the cache, not since the server's start
--   filter_columns         a filtered index's filter columns by dependency (BI L2907-2925), quoted, by name; NULL when the
--                          index has no filter
--   cs_rebuild_columns     a columnstore index's columns of BI's types with a segment keeping no min / max deep data (BI
--                          L3011-3034): an index built before SQL Server 2022 gains string segment elimination only from a
--                          rebuild; '{}' none; NULL a rowstore index, or not read (before 2022: no min_deep_data)
-- New tables, one row per object of a database's last index read (replaced with it; a dropped database's rows go):
--   mssql_heap         one row per heap of a user table: size, rows, usage, the counters above, its data space, the
--                      table's create date (BI 44-46's sources BI L1809-1812, L1964, L2039-2043)
--   mssql_table_shape  one row per user table and indexed view: total columns, the declared bytes of the non-LOB columns,
--                      the LOB columns (max_length -1), the string-or-LOB columns by BI's test (BI L5708), any sparse column
--                      (IC L2567-2581), any text / ntext / image column (IC L2596-2620), the clustered key's bytes and
--                      key-column count (BI L5568-5575), sys.tables' temporal_type (0 / 1 history / 2 system-versioned)
--                      and history_table_id (BI L2844, L2860-2862)
--   mssql_fk_columns   one row per enabled foreign key: its parent and referenced table, the parent columns in constraint
--                      order (BI L2632-2653)
--   mssql_index_parts  per database: the parts its last index read stored (ixextra, segments, heaps, shape, fks), the
--                      parts cut at 20,000 rows, and why a part was not read (the server's words). A database with no
--                      row here was last read before 0169: every part counts as not read.
-- THE RULES' GATE: a part not read leaves its table without the database's rows, which is safe only for a
-- rule that needs a row to raise. A rule that decides by leaving something out, or by an absence, judges a database
-- only when its parts say so (D405's 0170, D436's 0212): RC (sparse, text / ntext / image and temporal tables are left
-- out from mssql_table_shape) needs 'shape' read; R32 (no indexed view: object_type) needs 'ixextra' read; R72F (a
-- foreign key with no supporting index, the parent read at least once) needs 'fks' and 'heaps' read and neither in
-- parts_capped, besides 0092's capped; R44-46 (no forwarded fetch or delete on any index) need 'ixextra' and 'heaps';
-- R130 needs 'segments'; any other rule needs the part its column comes from. A database not gated through is 'not
-- judged: <part> not read' in the grid, never silently clean.
-- DEPARTURES from the design's words: each part is its own sys.sp_executesql after the index read (the
-- collector catches a part's error), not a TRY ... CATCH inside the index read's statement; the partition function is
-- stored by name (partition_function), not by its id - the page names it, and R65 compares type, count and range.
-- The import: import_mssql_indexes (0164's) renamed import_mssql_indexes_0164 and called unchanged by a new one that
-- then writes the new columns (one UPDATE of the rows 0092 just inserted, through a keyed temp table of the payload's
-- rows: below) and the new tables from the same payload. A
-- batch that did not read a database keeps all of its rows (0092's rule); a part not read leaves its table without
-- that database's rows (a rule judges only what the read holds). The lock order: mssql_index (0092), the usage
-- history's parent (0164), then mssql_heap, mssql_table_shape, mssql_fk_columns, mssql_index_parts. No partitions, so
-- nothing for purge(); an instance's rows go by ON DELETE CASCADE.
SET LOCAL lock_timeout = '20s';

ALTER TABLE pgvigil.mssql_index
  ADD COLUMN IF NOT EXISTS object_type              text,
  ADD COLUMN IF NOT EXISTS data_space_name          text,
  ADD COLUMN IF NOT EXISTS data_space_type          text,
  ADD COLUMN IF NOT EXISTS partition_function       text,
  ADD COLUMN IF NOT EXISTS pf_type                  text,
  ADD COLUMN IF NOT EXISTS pf_partitions            int,
  ADD COLUMN IF NOT EXISTS pf_range                 text,
  ADD COLUMN IF NOT EXISTS partition_column         text,
  ADD COLUMN IF NOT EXISTS any_uncompressed         boolean,
  ADD COLUMN IF NOT EXISTS row_lock_wait_count      bigint,
  ADD COLUMN IF NOT EXISTS row_lock_wait_ms         bigint,
  ADD COLUMN IF NOT EXISTS page_lock_wait_count     bigint,
  ADD COLUMN IF NOT EXISTS page_lock_wait_ms        bigint,
  ADD COLUMN IF NOT EXISTS page_latch_wait_count    bigint,
  ADD COLUMN IF NOT EXISTS page_latch_wait_ms       bigint,
  ADD COLUMN IF NOT EXISTS page_io_latch_wait_count bigint,
  ADD COLUMN IF NOT EXISTS page_io_latch_wait_ms    bigint,
  ADD COLUMN IF NOT EXISTS forwarded_fetch_count    bigint,
  ADD COLUMN IF NOT EXISTS leaf_delete_count        bigint,
  ADD COLUMN IF NOT EXISTS filter_columns           text[],
  ADD COLUMN IF NOT EXISTS cs_rebuild_columns       text[];

CREATE TABLE IF NOT EXISTS pgvigil.mssql_heap (
  instance_id               int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name             text NOT NULL,
  object_id                 bigint NOT NULL,
  database_id               int,
  schema_name               text,
  table_name                text,
  row_count                 bigint,
  size_kb                   bigint,                -- reserved pages
  partitions                int,
  compression               text,                  -- NONE | ROW | PAGE | MIXED (the partitions differ)
  user_seeks                bigint NOT NULL DEFAULT 0,
  user_scans                bigint NOT NULL DEFAULT 0,
  user_lookups              bigint NOT NULL DEFAULT 0,
  user_updates              bigint NOT NULL DEFAULT 0,
  last_read                 timestamptz,
  last_write                timestamptz,
  table_created             timestamptz,
  data_space_name           text,
  data_space_type           text,
  partition_function        text,
  pf_type                   text,
  pf_partitions             int,
  pf_range                  text,
  partition_column          text,
  any_uncompressed          boolean,
  row_lock_wait_count       bigint,
  row_lock_wait_ms          bigint,
  page_lock_wait_count      bigint,
  page_lock_wait_ms         bigint,
  page_latch_wait_count     bigint,
  page_latch_wait_ms        bigint,
  page_io_latch_wait_count  bigint,
  page_io_latch_wait_ms     bigint,
  forwarded_fetch_count     bigint,
  leaf_delete_count         bigint,
  snapshot_at               timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, object_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_table_shape (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name     text NOT NULL,
  object_id         bigint NOT NULL,
  database_id       int,
  schema_name       text,
  table_name        text,
  object_type       text,                  -- U a table, V an indexed view
  total_columns     int,
  nonlob_bytes      int,                   -- the sum of max_length, a (max) column as 0
  lob_columns       int,                   -- max_length -1
  string_columns    int,                   -- varchar / nvarchar / char by user type, or max_length -1 (BI's test; nchar not)
  has_sparse        boolean,
  has_text_image    boolean,
  cx_key_bytes      int,                   -- the clustered index's key columns' declared bytes; NULL: no clustered key
  cx_key_columns    int,
  temporal_type     int,                   -- 0, 1 a history table, 2 system-versioned; NULL a view
  history_table_id  bigint,
  snapshot_at       timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, object_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_fk_columns (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name     text NOT NULL,
  object_id         bigint NOT NULL,       -- the foreign key's
  database_id       int,
  fk_name           text,
  parent_object_id  bigint,
  parent_schema     text,
  parent_table      text,
  ref_object_id     bigint,
  ref_schema        text,
  ref_table         text,
  columns           text[] NOT NULL DEFAULT '{}',   -- the parent's columns in constraint order, each quoted
  snapshot_at       timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, object_id)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_index_parts (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  read_at        timestamptz NOT NULL,     -- the index read these parts belong to
  parts_read     text[] NOT NULL DEFAULT '{}',
  parts_capped   text[] NOT NULL DEFAULT '{}',
  note           text,                     -- why a part was not read, or what was cut
  PRIMARY KEY (instance_id, database_name)
);

DO $$ BEGIN
  IF to_regprocedure('pgvigil.import_mssql_indexes_0164(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_indexes(int, timestamptz, jsonb) RENAME TO import_mssql_indexes_0164;
  END IF;
END $$;

-- payload: 0092's (and 0164's), with on each 'index' row the new mssql_index columns above (filter_columns and
-- cs_rebuild_columns as arrays), on each read 'db' row parts_read, parts_capped (arrays) and parts_note, and the rows
-- {kind:'heap'} (mssql_heap's columns), {kind:'shape'} (mssql_table_shape's), {kind:'fk'} (mssql_fk_columns'; columns an
-- array).
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_indexes(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_dbs text[];
BEGIN
  -- 0092's own lock, taken first (as 0164 does)
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_indexes'), p_instance_id);
  -- the databases this batch reads, before the call (after it their rows carry this read's time); an older read
  -- arriving late changes nothing, as in 0092
  SELECT array_agg(r->>'database_name') INTO v_dbs
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'db' AND r->>'database_name' IS NOT NULL AND coalesce((r->>'read')::boolean, false)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b
                      WHERE b.instance_id = p_instance_id AND b.database_name = r->>'database_name' AND b.snapshot_at > p_snapshot_at);

  PERFORM pgvigil.import_mssql_indexes_0164(p_instance_id, p_snapshot_at, p_payload);

  IF v_dbs IS NOT NULL THEN
    -- the payload's rows that carry the new columns, keyed, so the UPDATE probes a key per row whatever mssql_index's
    -- statistics say: joined straight to jsonb_array_elements, the plan followed statistics that still held the rows
    -- before 0092's rewrite and re-read the whole payload once per index row (the j16 LAST run: 180 s for 20,000)
    CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_ix_extra (
      database_name text, object_id bigint, index_id int, r jsonb, PRIMARY KEY (database_name, object_id, index_id)) ON COMMIT DROP;
    TRUNCATE pgv_mssql_ix_extra;
    INSERT INTO pgv_mssql_ix_extra
    SELECT r->>'database_name', (r->>'object_id')::bigint, (r->>'index_id')::int, r
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'index' AND r->>'database_name' = ANY (v_dbs) AND r->>'object_id' IS NOT NULL AND r->>'index_id' IS NOT NULL
       AND (r ? 'object_type' OR r ? 'cs_rebuild_columns')   -- ixextra's keys or segments' (either part alone)
    ON CONFLICT DO NOTHING;
    UPDATE pgvigil.mssql_index x SET
        object_type = r->>'object_type', data_space_name = r->>'data_space_name', data_space_type = r->>'data_space_type',
        partition_function = r->>'partition_function', pf_type = r->>'pf_type', pf_partitions = (r->>'pf_partitions')::int,
        pf_range = r->>'pf_range', partition_column = r->>'partition_column', any_uncompressed = (r->>'any_uncompressed')::int = 1,
        row_lock_wait_count = (r->>'row_lock_wait_count')::bigint, row_lock_wait_ms = (r->>'row_lock_wait_ms')::bigint,
        page_lock_wait_count = (r->>'page_lock_wait_count')::bigint, page_lock_wait_ms = (r->>'page_lock_wait_ms')::bigint,
        page_latch_wait_count = (r->>'page_latch_wait_count')::bigint, page_latch_wait_ms = (r->>'page_latch_wait_ms')::bigint,
        page_io_latch_wait_count = (r->>'page_io_latch_wait_count')::bigint, page_io_latch_wait_ms = (r->>'page_io_latch_wait_ms')::bigint,
        forwarded_fetch_count = (r->>'forwarded_fetch_count')::bigint, leaf_delete_count = (r->>'leaf_delete_count')::bigint,
        filter_columns = CASE WHEN jsonb_typeof(r->'filter_columns') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'filter_columns')) END,
        cs_rebuild_columns = CASE WHEN jsonb_typeof(r->'cs_rebuild_columns') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'cs_rebuild_columns')) END
      FROM pgv_mssql_ix_extra e   -- r below: e's column, the payload row
     WHERE x.instance_id = p_instance_id AND x.database_name = e.database_name AND x.object_id = e.object_id
       AND x.index_id = e.index_id AND x.snapshot_at = p_snapshot_at;

    DELETE FROM pgvigil.mssql_heap WHERE instance_id = p_instance_id AND database_name = ANY (v_dbs);
    INSERT INTO pgvigil.mssql_heap (instance_id, database_name, object_id, database_id, schema_name, table_name, row_count, size_kb, partitions,
        compression, user_seeks, user_scans, user_lookups, user_updates, last_read, last_write, table_created, data_space_name, data_space_type,
        partition_function, pf_type, pf_partitions, pf_range, partition_column, any_uncompressed, row_lock_wait_count, row_lock_wait_ms,
        page_lock_wait_count, page_lock_wait_ms, page_latch_wait_count, page_latch_wait_ms, page_io_latch_wait_count, page_io_latch_wait_ms,
        forwarded_fetch_count, leaf_delete_count, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name', (r->>'object_id')::bigint)
           p_instance_id, r->>'database_name', (r->>'object_id')::bigint, (r->>'database_id')::int, r->>'schema_name', r->>'table_name',
           (r->>'row_count')::bigint, (r->>'size_kb')::bigint, (r->>'partitions')::int, r->>'compression',
           coalesce((r->>'user_seeks')::bigint, 0), coalesce((r->>'user_scans')::bigint, 0), coalesce((r->>'user_lookups')::bigint, 0),
           coalesce((r->>'user_updates')::bigint, 0), (r->>'last_read')::timestamptz, (r->>'last_write')::timestamptz, (r->>'table_created')::timestamptz,
           r->>'data_space_name', r->>'data_space_type', r->>'partition_function', r->>'pf_type', (r->>'pf_partitions')::int, r->>'pf_range',
           r->>'partition_column', (r->>'any_uncompressed')::int = 1, (r->>'row_lock_wait_count')::bigint, (r->>'row_lock_wait_ms')::bigint,
           (r->>'page_lock_wait_count')::bigint, (r->>'page_lock_wait_ms')::bigint, (r->>'page_latch_wait_count')::bigint, (r->>'page_latch_wait_ms')::bigint,
           (r->>'page_io_latch_wait_count')::bigint, (r->>'page_io_latch_wait_ms')::bigint, (r->>'forwarded_fetch_count')::bigint,
           (r->>'leaf_delete_count')::bigint, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'heap' AND r->>'database_name' = ANY (v_dbs) AND r->>'object_id' IS NOT NULL
     ORDER BY r->>'database_name', (r->>'object_id')::bigint;

    DELETE FROM pgvigil.mssql_table_shape WHERE instance_id = p_instance_id AND database_name = ANY (v_dbs);
    INSERT INTO pgvigil.mssql_table_shape (instance_id, database_name, object_id, database_id, schema_name, table_name, object_type, total_columns,
        nonlob_bytes, lob_columns, string_columns, has_sparse, has_text_image, cx_key_bytes, cx_key_columns, temporal_type, history_table_id, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name', (r->>'object_id')::bigint)
           p_instance_id, r->>'database_name', (r->>'object_id')::bigint, (r->>'database_id')::int, r->>'schema_name', r->>'table_name', r->>'object_type',
           (r->>'total_columns')::int, (r->>'nonlob_bytes')::int, (r->>'lob_columns')::int, (r->>'string_columns')::int,
           (r->>'has_sparse')::int = 1, (r->>'has_text_image')::int = 1, (r->>'cx_key_bytes')::int, (r->>'cx_key_columns')::int,
           (r->>'temporal_type')::int, (r->>'history_table_id')::bigint, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'shape' AND r->>'database_name' = ANY (v_dbs) AND r->>'object_id' IS NOT NULL
     ORDER BY r->>'database_name', (r->>'object_id')::bigint;

    DELETE FROM pgvigil.mssql_fk_columns WHERE instance_id = p_instance_id AND database_name = ANY (v_dbs);
    INSERT INTO pgvigil.mssql_fk_columns (instance_id, database_name, object_id, database_id, fk_name, parent_object_id, parent_schema, parent_table,
        ref_object_id, ref_schema, ref_table, columns, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name', (r->>'object_id')::bigint)
           p_instance_id, r->>'database_name', (r->>'object_id')::bigint, (r->>'database_id')::int, r->>'fk_name', (r->>'parent_object_id')::bigint,
           r->>'parent_schema', r->>'parent_table', (r->>'ref_object_id')::bigint, r->>'ref_schema', r->>'ref_table',
           CASE WHEN jsonb_typeof(r->'columns') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'columns')) ELSE '{}' END, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'fk' AND r->>'database_name' = ANY (v_dbs) AND r->>'object_id' IS NOT NULL
     ORDER BY r->>'database_name', (r->>'object_id')::bigint;

    INSERT INTO pgvigil.mssql_index_parts AS p (instance_id, database_name, read_at, parts_read, parts_capped, note)
    SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', p_snapshot_at,
           CASE WHEN jsonb_typeof(r->'parts_read') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'parts_read')) ELSE '{}' END,
           CASE WHEN jsonb_typeof(r->'parts_capped') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'parts_capped')) ELSE '{}' END,
           r->>'parts_note'
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'db' AND r->>'database_name' = ANY (v_dbs)
     ORDER BY r->>'database_name'
    ON CONFLICT (instance_id, database_name) DO UPDATE SET read_at = EXCLUDED.read_at, parts_read = EXCLUDED.parts_read,
        parts_capped = EXCLUDED.parts_capped, note = EXCLUDED.note;
  END IF;

  -- the run's last batch: 0092 deleted the databases the server no longer lists (mssql_index_db); their rows go here
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'databases') THEN
    DELETE FROM pgvigil.mssql_heap x WHERE x.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name);
    DELETE FROM pgvigil.mssql_table_shape x WHERE x.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name);
    DELETE FROM pgvigil.mssql_fk_columns x WHERE x.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name);
    DELETE FROM pgvigil.mssql_index_parts x WHERE x.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name);
  END IF;
END $$;
