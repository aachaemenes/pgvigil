package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// The SQL Server storage depth API (task 407, migration 0158): GET /api/mssql/storage_depth is the depth the Storage
// and Database files tabs add - days until each volume is full, the space split inside each database, tempdb's pages
// against its capacity, every table with its compression and its size over time, the tables that grew most and those
// that did not grow, the default paths, the fixed drives, the orphaned files, the build's checks and whether each of
// its collections ran. GET /api/mssql/dbio is IO per database (or per volume) over the page's range and the same range
// a day or a week before. Every query reads 0158's objects (and 0067 / 0074's tables they build on); a PostgreSQL
// instance has no row in them and gets empty parts.

// sqlDepthForecast: each volume (one row per Linux file system) with its growth and days until full.
const sqlDepthForecast = `SELECT * FROM pgvigil.mssql_volume_forecast($1) ORDER BY days_until_full NULLS LAST, volume`

// sqlDepthSpace: every present database with its newest space split (the last day's reads); a database whose split
// was not read keeps its row, with the reason its files carry (used_note), for the page's grey 'not read'.
const sqlDepthSpace = `
SELECT d.database_name, s.snapshot_at, s.reserved_bytes, s.data_bytes, s.index_bytes, s.unused_bytes, s.unallocated_bytes,
       s.log_size_bytes, s.log_used_bytes, greatest(s.log_size_bytes - s.log_used_bytes, 0) AS log_free_bytes, d.note AS not_read_note
  FROM (SELECT f.database_name, min(f.used_note) AS note FROM pgvigil.mssql_files f
         WHERE f.instance_id = $1 AND f.is_present AND f.database_name IS NOT NULL GROUP BY f.database_name) d
  LEFT JOIN LATERAL (SELECT * FROM pgvigil.mssql_database_space s
                      WHERE s.instance_id = $1 AND s.database_name = d.database_name AND s.snapshot_at > now() - interval '1 day'
                      ORDER BY s.snapshot_at DESC LIMIT 1) s ON true
 ORDER BY d.database_name`

// sqlDepthSpaceSeries: one database's split over the window ($3), the newest read per $4-second bucket.
const sqlDepthSpaceSeries = `
SELECT DISTINCT ON (1) to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at, s.data_bytes, s.index_bytes,
       s.unused_bytes, s.unallocated_bytes, s.log_used_bytes, greatest(s.log_size_bytes - s.log_used_bytes, 0) AS log_free_bytes
  FROM pgvigil.mssql_database_space s
 WHERE s.instance_id = $1 AND s.database_name = $2 AND s.snapshot_at > now() - make_interval(days => $3)
 ORDER BY 1, s.snapshot_at DESC`

const sqlDepthTempdb = `SELECT * FROM pgvigil.mssql_tempdb_capacity WHERE instance_id = $1`

// sqlDepthPending: the IOs pending at the newest file IO read (NULL = the pending list was not read at it), and how
// many of them the operating system still held.
const sqlDepthPending = `
SELECT r.snapshot_at, r.pending_ios, r.pending_in_os FROM pgvigil.mssql_fileio_read r
 WHERE r.instance_id = $1 AND r.snapshot_at > now() - interval '1 day' ORDER BY r.snapshot_at DESC LIMIT 1`

// sqlDepthTempdbSeries: tempdb's pages over the page's range, per $4-second bucket (the largest read of each).
const sqlDepthTempdbSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       max(s.user_object_bytes) AS user_object_bytes, max(s.internal_object_bytes) AS internal_object_bytes,
       max(s.reserved_bytes) AS version_store_bytes, max(s.mixed_extent_bytes) AS mixed_extent_bytes,
       min(s.unallocated_bytes) AS unallocated_bytes, max(s.tempdb_data_bytes) AS size_bytes
  FROM pgvigil.mssql_versionstore_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND s.unallocated_bytes IS NOT NULL
 GROUP BY 1 ORDER BY 1`

// sqlDepthTables: every present table of one database, with its growth over the window where it is known.
const sqlDepthTables = `
SELECT t.schema_name, t.table_name, t.table_type, t.temporal, t.graph, t.compression, t.partitions, t.row_count, t.reserved_kb,
       t.used_kb, t.data_kb, t.index_kb, t.first_seen, t.changed_at, t.snapshot_at, g.rows_grown, g.used_kb_grown, g.kb_per_day
  FROM pgvigil.mssql_tables t
  LEFT JOIN pgvigil.mssql_table_growth($1, $3, $2) g ON g.database_name = t.database_name AND g.schema_name = t.schema_name AND g.table_name = t.table_name
 WHERE t.instance_id = $1 AND t.database_name = $2 AND t.is_present
 ORDER BY t.reserved_kb DESC NULLS LAST, t.schema_name, t.table_name`

// sqlDepthGrowth: the growth of the window computed once, two lists: 'grew' - the 25 tables that grew most (by the
// space they use); 'not_grown' - the 25 largest whose rows and size did not change, with how many there are.
const sqlDepthGrowth = `
WITH g AS MATERIALIZED (SELECT * FROM pgvigil.mssql_table_growth($1, $2))
(SELECT 'grew' AS list, g.*, NULL::bigint AS tables_not_grown FROM g WHERE g.used_kb_grown > 0 OR g.rows_grown > 0
  ORDER BY g.used_kb_grown DESC, g.rows_grown DESC LIMIT 25)
UNION ALL
(SELECT 'not_grown', g.*, count(*) OVER () FROM g WHERE g.used_kb_grown = 0 AND g.rows_grown = 0
  ORDER BY g.used_kb DESC LIMIT 25)`

// sqlDepthTablesRead: per database, whether its tables were read (the growth lists leave out the others).
const sqlDepthTablesRead = `
SELECT database_name, read_at, read_ok, note, first_read_at, ok_at FROM pgvigil.mssql_tables_db_read
 WHERE instance_id = $1 ORDER BY read_ok, database_name`

const sqlDepthTableSeries = `SELECT * FROM pgvigil.mssql_table_series($1, $2, $3, $4, $5, $6)`

const sqlDepthPaths = `SELECT * FROM pgvigil.mssql_storage_paths WHERE instance_id = $1`

// sqlDepthDrives: every fixed drive with its free space; its size and free per cent where a volume of the database
// files is the same drive (sys.dm_os_enumerate_fixed_drives gives no size).
const sqlDepthDrives = `
SELECT d.drive, d.drive_type, d.free_bytes, d.snapshot_at, v.total_bytes,
       round(100.0 * d.free_bytes / nullif(v.total_bytes, 0), 1) AS free_pct, dn.status, v.files
  FROM pgvigil.mssql_fixed_drives d
  LEFT JOIN pgvigil.mssql_volumes v ON v.instance_id = d.instance_id AND v.is_present AND lower(v.volume) = lower(d.drive)
  LEFT JOIN pgvigil.drives_now dn ON dn.instance_id = d.instance_id AND dn.drive = v.volume
 WHERE d.instance_id = $1 AND d.is_present
 ORDER BY d.drive`

const sqlDepthOrphans = `SELECT path, size_bytes, snapshot_at, note FROM pgvigil.mssql_orphan_files WHERE instance_id = $1 ORDER BY path`

const sqlDepthChecks = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_storage_depth_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, check_name, object`

// sqlDepthRuns: each collection the depth reads, with its newest run, its outcome and note (a skipped collection says
// which right it lacks: the page shows that part grey, 'not read', never green), and status 'off' where the instance's
// configuration switches it off ($2: the server's expected intervals, 0 = disabled there, as the Collection dates page
// reads them) - off whether it ran before or never. collection_dates keeps the last run whatever its status
// (collection_log only those not ok: pgvigil.log_collection, 0001); a collection with no run has no snapshot.
const sqlDepthRuns = `
SELECT w.collection, d.snapshot_at,
       CASE WHEN ($2::jsonb -> 'instances' -> i.name ->> w.collection)::int = 0 THEN 'off' ELSE d.status END AS status, d.note
  FROM (VALUES ('mssql_storage'), ('mssql_storage_depth'), ('mssql_tables'), ('mssql_fileio'), ('mssql_versionstore')) w (collection)
  CROSS JOIN (SELECT name FROM pgvigil.instances WHERE instance_id = $1) i
  LEFT JOIN pgvigil.collection_dates d ON d.instance_id = $1 AND d.collection = w.collection`

// MSSQLStorageDepth is GET /api/mssql/storage_depth?instance=N&days=30[&db=name][&schema=s&table=t][&from=&to=][&part=...].
func (s *Server) MSSQLStorageDepth(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	days := 30
	if v := q.Get("days"); v != "" {
		if days, err = strconv.Atoi(v); err != nil || !storageDays[days] {
			writeErr(w, http.StatusBadRequest, errors.New("days must be one of 7, 30, 90, 180, 365"))
			return
		}
	}
	var db, schema, table any
	if v := q.Get("db"); v != "" {
		db = v
	}
	if v := q.Get("schema"); v != "" {
		schema = v
	}
	if v := q.Get("table"); v != "" {
		table = v
	}
	bucket := days * 86400 / 300
	if bucket < 3600 {
		bucket = 3600
	}
	step := stepSecs(from, to)
	exp, err := json.Marshal(s.expected)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	parts := []part{
		{"forecast", sqlDepthForecast, []any{id}},
		{"space", sqlDepthSpace, []any{id}},
		{"tempdb", sqlDepthTempdb, []any{id}},
		{"tempdb_series", sqlDepthTempdbSeries, []any{id, from, to, step}},
		{"growth", sqlDepthGrowth, []any{id, days}},
		{"tables_read", sqlDepthTablesRead, []any{id}},
		{"paths", sqlDepthPaths, []any{id}},
		{"drives", sqlDepthDrives, []any{id}},
		{"orphans", sqlDepthOrphans, []any{id}},
		{"checks", sqlDepthChecks, []any{id}},
		{"runs", sqlDepthRuns, []any{id, string(exp)}},
		{"pending", sqlDepthPending, []any{id}},
	}
	if db != nil {
		parts = append(parts, part{"space_series", sqlDepthSpaceSeries, []any{id, db, days, bucket}},
			part{"tables", sqlDepthTables, []any{id, db, days}})
		if schema != nil && table != nil {
			parts = append(parts, part{"table_series", sqlDepthTableSeries, []any{id, db, schema, table, time.Now().AddDate(0, 0, -days), time.Now()}})
		}
	}
	s.multiParts(w, r, parts)
}

// multiParts is multiPart that also takes ?parts=a,b,c: a page view asks for the parts it draws, never the whole set
// (the growth lists and the tables' join cost more than one database's space). An unknown name is a 400.
func (s *Server) multiParts(w http.ResponseWriter, r *http.Request, parts []part) {
	list := r.URL.Query().Get("parts")
	if list == "" {
		s.multiPart(w, r, parts)
		return
	}
	by := map[string]part{}
	names := make([]string, 0, len(parts))
	for _, p := range parts {
		by[p.name] = p
		names = append(names, p.name)
	}
	var ps []part
	seen := map[string]bool{}
	for _, n := range strings.Split(list, ",") {
		n = strings.TrimSpace(n)
		p, ok := by[n]
		if !ok {
			writeErr(w, http.StatusBadRequest, errors.New("parts must name some of "+strings.Join(names, ", ")))
			return
		}
		if !seen[n] {
			seen[n] = true
			ps = append(ps, p)
		}
	}
	s.multi(w, r, ps)
}

// stepSecs: a chart's step over the range, about 300 points, at least a minute.
func stepSecs(from, to time.Time) int {
	n := int(to.Sub(from).Seconds()) / 300
	if n < 60 {
		return 60
	}
	return n
}

// sqlDBIOGrid: every database's (or volume's) totals over the range.
const sqlDBIOGrid = `SELECT * FROM pgvigil.mssql_io_totals($1, $2, $3, $4) ORDER BY read_bytes + write_bytes DESC, name`

// sqlDBIOSeriesOf: the named databases ($5) per step; mssql_db_io keeps only their rows before it sums the steps.
const sqlDBIOSeriesOf = `SELECT io.* FROM pgvigil.mssql_db_io($1, $2, $3, $4, $5::text[]) io`

// sqlDBIOTop: the top $4 databases by bytes moved in the range (the grid by volume does not name them).
const sqlDBIOTop = `SELECT t.name FROM pgvigil.mssql_io_totals($1, $2, $3, 'database') t ORDER BY t.read_bytes + t.write_bytes DESC, t.name LIMIT $4`

// sqlDBIOSeries: the top $5 databases by bytes moved in the range, per step (a request for the one part 'series').
const sqlDBIOSeries = `
SELECT io.* FROM pgvigil.mssql_db_io($1, $2, $3, $4,
         ARRAY(SELECT t.name FROM pgvigil.mssql_io_totals($1, $2, $3, 'database') t
                ORDER BY t.read_bytes + t.write_bytes DESC, t.name LIMIT $5)) io`

const sqlDBIOCompare = `SELECT * FROM pgvigil.mssql_io_compare($1, $2, $3, $4::interval, $5)`

// MSSQLDBIO is GET /api/mssql/dbio?instance=N&from=&to=[&by=database|volume][&compare=1d|7d][&top=10][&part=...].
func (s *Server) MSSQLDBIO(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	by := "database"
	if v := q.Get("by"); v != "" {
		if v != "database" && v != "volume" {
			writeErr(w, http.StatusBadRequest, errors.New("by must be database or volume"))
			return
		}
		by = v
	}
	shift := "1 day"
	switch q.Get("compare") {
	case "", "1d":
	case "7d":
		shift = "7 days"
	default:
		writeErr(w, http.StatusBadRequest, errors.New("compare must be 1d or 7d"))
		return
	}
	top := 10
	if v := q.Get("top"); v != "" {
		if top, err = strconv.Atoi(v); err != nil || top < 1 || top > 50 {
			writeErr(w, http.StatusBadRequest, errors.New("top must be 1 to 50"))
			return
		}
	}
	if r.URL.Query().Get("part") != "" {
		s.multiPart(w, r, []part{
			{"grid", sqlDBIOGrid, []any{id, from, to, by}},
			{"series", sqlDBIOSeries, []any{id, from, to, stepSecs(from, to), top}},
			{"compare", sqlDBIOCompare, []any{id, from, to, shift, by}},
		})
		return
	}
	// the whole reply sums the range's minute rows twice, not four times: the grid once (by database its first names
	// are the series' top N), the shifted window once (joined to the grid here for the compare)
	ctx := r.Context()
	grid, err := s.query(ctx, sqlDBIOGrid, id, from, to, by)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("grid: %w", err))
		return
	}
	names := firstNames(grid, top)
	if by != "database" {
		t, err := s.query(ctx, sqlDBIOTop, id, from, to, top)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("series: %w", err))
			return
		}
		names = firstNames(t, top)
	}
	series, err := s.query(ctx, sqlDBIOSeriesOf, id, from, to, stepSecs(from, to), names)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("series: %w", err))
		return
	}
	days := 1
	if shift == "7 days" {
		days = 7
	}
	before, err := s.query(ctx, sqlDBIOGrid, id, from.AddDate(0, 0, -days), to.AddDate(0, 0, -days), by)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("compare: %w", err))
		return
	}
	s.reply(w, r, map[string]*table{"grid": grid, "series": series, "compare": compareIO(grid, before)}, nil)
}

// firstNames: the 'name' column of a table's first n rows (the grid is ordered by bytes moved).
func firstNames(t *table, n int) []string {
	k := colIndex(t, "name")
	out := []string{}
	for _, row := range t.Rows {
		if len(out) == n || k < 0 {
			break
		}
		if v, ok := row[k].(string); ok {
			out = append(out, v)
		}
	}
	return out
}

// colIndex: a column's index in a table, -1 when absent.
func colIndex(t *table, name string) int {
	for i, c := range t.Columns {
		if c == name {
			return i
		}
	}
	return -1
}

// compareIO joins the range's totals (now) to the shifted window's (before) by name, in mssql_io_compare's columns:
// now's names in their order, then the names only before had, by name.
func compareIO(now, before *table) *table {
	cols := []string{"name", "mb_s", "mb_s_before", "read_latency_ms", "read_latency_ms_before", "write_latency_ms", "write_latency_ms_before",
		"reads", "reads_before", "writes", "writes_before", "secs", "secs_before"}
	pick := func(t *table, row []any, c string) any {
		if row == nil {
			return nil
		}
		if k := colIndex(t, c); k >= 0 {
			return row[k]
		}
		return nil
	}
	out := &table{Columns: cols, Rows: [][]any{}}
	na, nb := colIndex(now, "name"), colIndex(before, "name")
	if na < 0 || nb < 0 {
		return out
	}
	byName := map[string][]any{}
	for _, row := range before.Rows {
		if v, ok := row[nb].(string); ok {
			byName[v] = row
		}
	}
	add := func(name string, a, b []any) {
		out.Rows = append(out.Rows, []any{name, pick(now, a, "mb_s"), pick(before, b, "mb_s"), pick(now, a, "read_latency_ms"), pick(before, b, "read_latency_ms"),
			pick(now, a, "write_latency_ms"), pick(before, b, "write_latency_ms"), pick(now, a, "reads"), pick(before, b, "reads"),
			pick(now, a, "writes"), pick(before, b, "writes"), pick(now, a, "secs"), pick(before, b, "secs")})
	}
	seen := map[string]bool{}
	for _, row := range now.Rows {
		name, _ := row[na].(string)
		seen[name] = true
		add(name, row, byName[name])
	}
	var rest []string
	for name := range byName {
		if !seen[name] {
			rest = append(rest, name)
		}
	}
	sort.Strings(rest)
	for _, name := range rest {
		add(name, nil, byName[name])
	}
	return out
}
