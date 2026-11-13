package dbadash

// The DBADash import (task 92): a DBADash repository's history loaded into pgvigil's own SQL Server tables, so a site
// that moves from DBADash to pgvigil keeps what DBADash collected. It reads the repository through the door's read
// login (SELECT on the dbo schema) and writes the pgvigil repository as its OWNER (the login 'pgvigil migrate' uses):
// the rows go straight into the history tables of the SQL Server engine, one pgvigil row per DBADash row, because the
// collector's import functions take a live read of a server (its clock, its counters, its cursors) and a replay of
// history is not one.
//
// What is imported, per DBADash instance (docs/dbadash.md has the table of mappings and what is not imported):
//   - the instance: a pgvigil SQL Server instance under DBADash's display name, with DBADash's tags (an instance of
//     that name pgvigil already monitors keeps its own description and tags; one stored as PostgreSQL is skipped);
//   - cpu      dbo.CPU                                  -> mssql_cpu_sample
//   - volumes  dbo.DriveSnapshot + dbo.Drives            -> mssql_volume_sample
//   - dbsize   dbo.DBFileSnapshot + DBFiles + Databases  -> mssql_database_size (one row per snapshot and database)
//   - jobruns  dbo.JobHistory + dbo.Jobs                 -> mssql_job_runs
// Idempotent and resumable: a row already stored (the same instance, time and key) is skipped, every batch commits on
// its own, so a run cut short is run again and goes on where it stopped; a dry run reads the counts only. Each mapping
// reports the DBADash rows of the window, the rows inserted now and the rows pgvigil holds for the window after.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// ImportOptions shape one import.
type ImportOptions struct {
	// From and To bound the history taken (UTC); a zero From = everything DBADash keeps, a zero To = now.
	From, To time.Time
	// Instances are DBADash InstanceIDs; empty = every active SQL Server instance (Azure SQL databases left out).
	Instances []int
	// DryRun reads and counts; nothing is written to pgvigil.
	DryRun bool
	// Batch is the rows per insert (one transaction each); 0 = DefaultImportBatch.
	Batch int
	// Names maps a DBADash InstanceID to the pgvigil instance name to use (the name pgvigil.yaml will monitor it
	// under); an instance not named here takes DBADash's display name.
	Names map[int]string
}

// DefaultImportBatch is the rows of one insert.
const DefaultImportBatch = 2000

// ImportCount is one mapping of one instance: what DBADash holds for the window, what was inserted now and what
// pgvigil holds for the window after; Skipped says why nothing was imported.
type ImportCount struct {
	Instance  string `json:"instance"`
	DBADashID int    `json:"dbadash_instance_id"`
	PgvigilID int    `json:"pgvigil_instance_id,omitempty"`
	Mapping   string `json:"mapping"`
	Source    int64  `json:"source"`
	Inserted  int64  `json:"inserted"`
	Stored    int64  `json:"stored"`
	Skipped   string `json:"skipped,omitempty"`
}

// importMapping is one DBADash history table and its pgvigil home. The T-SQL takes @id, @from and @to; rows aliases
// its columns as the insert's record names and orders by time ('at' is the row's UTC time); insert takes $1 the
// pgvigil instance_id, $2 the batch as JSON and $3 the instance's facts ({"linux": bool}) and returns the rows it
// inserted; stored takes $1 instance_id, $2 from, $3 to.
type importMapping struct {
	Key, Table, Count, Rows, Insert, Stored string
	// Facts says the insert takes $3, the instance's facts
	Facts bool
}

var importMappings = []importMapping{
	{
		Key: "cpu", Table: "mssql_cpu_sample", Facts: true,
		Count: `SELECT COUNT_BIG(*) FROM dbo.CPU WHERE InstanceID = @id AND EventTime >= @from AND EventTime < @to`,
		Rows: `SELECT EventTime AS at, CAST(SQLProcessCPU AS int) AS sql_pct, CAST(SystemIdleCPU AS int) AS idle_pct
  FROM dbo.CPU WHERE InstanceID = @id AND EventTime >= @from AND EventTime < @to ORDER BY EventTime`,
		// the record number is the time's negative milliseconds: a live read's ring-buffer numbers are positive, so an
		// imported row never stands for a live one; a DBADash minute within 30 s of a stored row (pgvigil's own read of the
		// same ring-buffer record: DBADash timed it with GETUTCDATE, the collector with SYSUTCDATETIME) is skipped; SQL
		// Server on Linux writes no idle figure (always 0): other and idle are NULL there, as the collector stores them
		Insert: `WITH x AS (SELECT * FROM jsonb_to_recordset($2) AS r(at timestamptz, sql_pct int, idle_pct int)),
ins AS (
  INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
  SELECT $1, x.at, -(extract(epoch FROM x.at) * 1000)::bigint, least(greatest(x.sql_pct, 0), 100),
         CASE WHEN ($3::jsonb->>'linux')::boolean THEN NULL ELSE least(greatest(100 - x.sql_pct - x.idle_pct, 0), 100) END,
         CASE WHEN ($3::jsonb->>'linux')::boolean THEN NULL ELSE least(greatest(x.idle_pct, 0), 100) END
    FROM x
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cpu_sample c
                      WHERE c.instance_id = $1 AND c.snapshot_at BETWEEN x.at - interval '30 seconds' AND x.at + interval '30 seconds')
  RETURNING 1)
SELECT count(*) FROM ins`,
		Stored: `SELECT count(*) FROM pgvigil.mssql_cpu_sample WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3`,
	},
	{
		Key: "volumes", Table: "mssql_volume_sample",
		Count: `SELECT COUNT_BIG(*) FROM dbo.DriveSnapshot S JOIN dbo.Drives D ON D.DriveID = S.DriveID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to`,
		Rows: `SELECT S.SnapshotDate AS at, D.Name AS volume, S.Capacity AS total_bytes, S.FreeSpace AS free_bytes
  FROM dbo.DriveSnapshot S JOIN dbo.Drives D ON D.DriveID = S.DriveID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to ORDER BY S.SnapshotDate, S.DriveID`,
		Insert: `WITH x AS (SELECT * FROM jsonb_to_recordset($2) AS r(at timestamptz, volume text, total_bytes bigint, free_bytes bigint)),
ins AS (
  INSERT INTO pgvigil.mssql_volume_sample (instance_id, snapshot_at, volume, total_bytes, free_bytes)
  SELECT $1, x.at, n.volume, x.total_bytes, x.free_bytes
    FROM x
   -- DBADash keeps a mount point in capitals (UPPER(volume_mount_point)): a volume pgvigil already lists keeps its own spelling
   CROSS JOIN LATERAL (SELECT coalesce((SELECT v.volume FROM pgvigil.mssql_volumes v WHERE v.instance_id = $1 AND upper(v.volume) = upper(x.volume)
                                         ORDER BY v.is_present DESC, v.volume LIMIT 1), x.volume) AS volume) n
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_volume_sample v WHERE v.instance_id = $1 AND v.snapshot_at = x.at AND upper(v.volume) = upper(x.volume))
  RETURNING 1)
SELECT count(*) FROM ins`,
		Stored: `SELECT count(*) FROM pgvigil.mssql_volume_sample WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3`,
	},
	{
		// DBADash keeps file sizes in 8 KB pages (sys.database_files' unit): bytes are pages * 8192; the collector's rule
		// (0067's import_mssql_storage): data is every file but the log (type 1), the log the LOG files, a size 0 when the
		// side has no file, a used figure only when every file of that side was read
		Key: "dbsize", Table: "mssql_database_size",
		Count: `SELECT COUNT_BIG(*) FROM (SELECT S.SnapshotDate, F.DatabaseID
  FROM dbo.DBFileSnapshot S JOIN dbo.DBFiles F ON F.FileID = S.FileID JOIN dbo.Databases D ON D.DatabaseID = F.DatabaseID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to
 GROUP BY S.SnapshotDate, F.DatabaseID) g`,
		Rows: `SELECT S.SnapshotDate AS at, MAX(D.name) AS database_name,
       ISNULL(SUM(CASE WHEN F.type <> 1 THEN S.Size END), 0) * 8192 AS data_bytes, ISNULL(SUM(CASE WHEN F.type = 1 THEN S.Size END), 0) * 8192 AS log_bytes,
       CASE WHEN SUM(CASE WHEN F.type <> 1 THEN 1 ELSE 0 END) > 0 AND SUM(CASE WHEN F.type <> 1 AND S.space_used IS NULL THEN 1 ELSE 0 END) = 0
            THEN SUM(CASE WHEN F.type <> 1 THEN S.space_used END) * 8192 END AS data_used_bytes,
       CASE WHEN SUM(CASE WHEN F.type = 1 THEN 1 ELSE 0 END) > 0 AND SUM(CASE WHEN F.type = 1 AND S.space_used IS NULL THEN 1 ELSE 0 END) = 0
            THEN SUM(CASE WHEN F.type = 1 THEN S.space_used END) * 8192 END AS log_used_bytes, COUNT(*) AS files
  FROM dbo.DBFileSnapshot S JOIN dbo.DBFiles F ON F.FileID = S.FileID JOIN dbo.Databases D ON D.DatabaseID = F.DatabaseID
 WHERE D.InstanceID = @id AND S.SnapshotDate >= @from AND S.SnapshotDate < @to
 GROUP BY S.SnapshotDate, F.DatabaseID ORDER BY S.SnapshotDate, F.DatabaseID`,
		Insert: `WITH x AS (SELECT * FROM jsonb_to_recordset($2) AS r(at timestamptz, database_name text, data_bytes bigint, log_bytes bigint,
                                                   data_used_bytes bigint, log_used_bytes bigint, files int)),
ins AS (
  INSERT INTO pgvigil.mssql_database_size (instance_id, snapshot_at, database_name, data_bytes, log_bytes, data_used_bytes, log_used_bytes, files)
  SELECT $1, x.at, x.database_name, x.data_bytes, x.log_bytes, x.data_used_bytes, x.log_used_bytes, x.files
    FROM x
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_database_size d WHERE d.instance_id = $1 AND d.snapshot_at = x.at AND d.database_name = x.database_name)
  RETURNING 1)
SELECT count(*) FROM ins`,
		Stored: `SELECT count(*) FROM pgvigil.mssql_database_size WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3`,
	},
	{
		// DBADash stores a run's start in UTC (msdb's local time plus the instance's UTC offset); msdb's own run_date and
		// run_time integers (the server's local clock) are rebuilt with the instance's CURRENT offset, so a run from before a
		// daylight-saving change shows its local time an hour off (docs/dbadash.md); history_id is msdb's own
		// sysjobhistory.instance_id, which DBADash keeps
		Key: "jobruns", Table: "mssql_job_runs",
		Count: `SELECT COUNT_BIG(*) FROM dbo.JobHistory WHERE InstanceID = @id AND RunDateTime >= @from AND RunDateTime < @to`,
		Rows: `SELECT H.RunDateTime AS at, CAST(H.instance_id AS bigint) AS history_id, CONVERT(char(36), H.job_id) AS job_id, J.name AS job_name,
       H.step_id, H.step_name, H.run_status, H.RunDurationSec AS duration_s, H.sql_message_id, H.sql_severity,
       H.retries_attempted AS retries, H.message, DATEADD(minute, -ISNULL(I.UTCOffset, 0), H.RunDateTime) AS local_at
  FROM dbo.JobHistory H
  JOIN dbo.Instances I ON I.InstanceID = H.InstanceID
  LEFT JOIN dbo.Jobs J ON J.InstanceID = H.InstanceID AND J.job_id = H.job_id
 WHERE H.InstanceID = @id AND H.RunDateTime >= @from AND H.RunDateTime < @to ORDER BY H.RunDateTime, H.instance_id`,
		Insert: `WITH x AS (SELECT * FROM jsonb_to_recordset($2) AS r(at timestamptz, history_id bigint, job_id text, job_name text, step_id int,
                                                   step_name text, run_status int, duration_s bigint, sql_message_id int,
                                                   sql_severity int, retries int, message text, local_at timestamp)),
ins AS (
  INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_date, run_time,
                                      run_status, duration_s, sql_message_id, sql_severity, retries, message)
  SELECT $1, x.at, x.history_id, upper(x.job_id), x.job_name, x.step_id, x.step_name,
         to_char(x.local_at, 'YYYYMMDD')::int, to_char(x.local_at, 'HH24MISS')::int,
         x.run_status, x.duration_s, x.sql_message_id, x.sql_severity, x.retries, x.message
    FROM x
   -- the collector's own key (0072): the history id, job and step within 3 hours, so a row pgvigil read itself is not added again
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs j
                      WHERE j.instance_id = $1 AND j.snapshot_at BETWEEN x.at - interval '3 hours' AND x.at + interval '3 hours'
                        AND j.history_id = x.history_id AND j.job_id = upper(x.job_id) AND j.step_id = x.step_id)
  RETURNING 1)
SELECT count(*) FROM ins`,
		Stored: `SELECT count(*) FROM pgvigil.mssql_job_runs WHERE instance_id = $1 AND snapshot_at >= $2 AND snapshot_at < $3`,
	},
}

// ImportMappings names the mappings in the order they run (the docs' table, the proof's).
func ImportMappings() []string {
	out := make([]string, 0, len(importMappings))
	for _, m := range importMappings {
		out = append(out, m.Key+" -> "+m.Table)
	}
	return out
}

// srcInstance is one DBADash instance to import.
type srcInstance struct {
	ID       int
	Instance string
	Display  string
	Version  string
	Linux    bool
	Edition  int
	Tags     []string
}

// Import loads the history of a DBADash repository (srcDSN, the door's read login) into the pgvigil repository
// (repoDSN, its owner). The error is the whole run's; an instance or mapping that cannot be imported is a count with
// its reason.
func Import(ctx context.Context, log *slog.Logger, srcDSN, repoDSN string, opt ImportOptions) ([]ImportCount, error) {
	if strings.TrimSpace(srcDSN) == "" {
		return nil, errors.New("the DBADash repository's dsn resolved to nothing")
	}
	if opt.Batch <= 0 {
		opt.Batch = DefaultImportBatch
	}
	if opt.To.IsZero() {
		opt.To = time.Now().UTC()
	}
	if opt.From.IsZero() {
		opt.From = time.Date(1900, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	if !opt.From.Before(opt.To) {
		return nil, errors.New("from must be before to")
	}
	db, err := mssqlopen.Open(withAppName(srcDSN))
	if err != nil {
		return nil, fmt.Errorf("dbadash dsn: %w", err)
	}
	defer func() { _ = db.Close() }()
	db.SetMaxOpenConns(1)
	src, err := db.Conn(ctx)
	if err != nil {
		return nil, fmt.Errorf("dbadash connect: %w", err)
	}
	defer func() { _ = src.Close() }()
	var ver sql.NullString
	if err := src.QueryRowContext(ctx, `SELECT TOP (1) Version FROM dbo.DBVersionHistory ORDER BY DeployDate DESC`).Scan(&ver); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("dbo.DBVersionHistory: %w", err)
	}
	if !Proven(ver.String) {
		log.Warn("dbadash import: not proven on this DBADash version", "version", orNone(ver.String), "proven", ProvenVersion)
	}

	insts, leftOut, err := importInstances(ctx, src, opt.Instances)
	if err != nil {
		return nil, err
	}
	for _, t := range leftOut {
		log.Warn("dbadash import: a DBADash tag left out", "why", t)
	}
	out := []ImportCount{}
	found := map[int]bool{}
	for _, in := range insts {
		found[in.ID] = true
	}
	for _, id := range opt.Instances {
		if !found[id] {
			out = append(out, ImportCount{DBADashID: id, Mapping: "-", Skipped: "no active SQL Server instance with this InstanceID in the repository (inactive, an Azure SQL database, or unknown)"})
		}
	}
	pool, err := openImportStore(ctx, repoDSN, opt.DryRun)
	if err != nil {
		return nil, err
	}
	defer pool.Close()
	for _, in := range insts {
		name := in.Display
		if n := strings.TrimSpace(opt.Names[in.ID]); n != "" {
			name = n
		}
		pid, why, err := pgvigilInstance(ctx, log, pool, name, in, opt.DryRun)
		if err != nil {
			return out, err
		}
		for _, m := range importMappings {
			c := ImportCount{Instance: name, DBADashID: in.ID, PgvigilID: pid, Mapping: m.Key, Skipped: why}
			if err := src.QueryRowContext(ctx, m.Count, sql.Named("id", in.ID), sql.Named("from", utc2(opt.From)), sql.Named("to", utc2(opt.To))).Scan(&c.Source); err != nil {
				return out, fmt.Errorf("%s %s: count: %w", name, m.Key, err)
			}
			if why == "" && !opt.DryRun {
				if c.Inserted, err = importOne(ctx, src, pool, m, in, pid, opt); err != nil {
					return out, fmt.Errorf("%s %s: %w", name, m.Key, err)
				}
			}
			if pid > 0 {
				if err := pool.QueryRow(ctx, m.Stored, pid, opt.From, opt.To).Scan(&c.Stored); err != nil {
					return out, fmt.Errorf("%s %s: stored: %w", name, m.Key, err)
				}
			}
			log.Info("dbadash import", "instance", name, "mapping", m.Key, "source", c.Source, "inserted", c.Inserted, "stored", c.Stored, "skipped", c.Skipped)
			out = append(out, c)
		}
	}
	return out, nil
}

// importInstances reads the instances to import: active, not Azure SQL Database, the ids asked for (all when none).
func importInstances(ctx context.Context, src *sql.Conn, want []int) ([]srcInstance, []string, error) {
	// (an id asked for that is not here - inactive, an Azure SQL database, unknown - is reported by Import)
	rows, err := src.QueryContext(ctx, `
SELECT I.InstanceID, I.Instance, ISNULL(I.Alias, I.ConnectionID), ISNULL(I.ProductVersion, ''), ISNULL(I.host_platform, ''), ISNULL(I.EngineEdition, 0)
  FROM dbo.Instances I
 WHERE I.IsActive = 1 AND ISNULL(I.EngineEdition, 0) <> 5
 ORDER BY I.InstanceID`)
	if err != nil {
		return nil, nil, fmt.Errorf("dbo.Instances: %w", err)
	}
	ok := map[int]bool{}
	for _, id := range want {
		ok[id] = true
	}
	var out []srcInstance
	for rows.Next() {
		var in srcInstance
		var plat string
		if err := rows.Scan(&in.ID, &in.Instance, &in.Display, &in.Version, &plat, &in.Edition); err != nil {
			_ = rows.Close()
			return nil, nil, fmt.Errorf("dbo.Instances: %w", err)
		}
		in.Linux = strings.EqualFold(strings.TrimSpace(plat), "Linux")
		if len(want) == 0 || ok[in.ID] {
			out = append(out, in)
		}
	}
	if err := rows.Close(); err != nil {
		return nil, nil, err
	}
	var leftOut []string
	for i := range out {
		tags, skipped, err := instanceTags(ctx, src, out[i].ID)
		if err != nil {
			return nil, nil, err
		}
		out[i].Tags = tags
		leftOut = append(leftOut, skipped...)
	}
	return out, leftOut, nil
}

// instanceTags are DBADash's own tags of an instance as pgvigil's key:value tags; DBADash's system tags (a name in
// braces: {Edition}, {Version} ...) are its own description of the server, which pgvigil reads from the server itself.
// A tag pgvigil's rule refuses (config.ParseTag: a lower-case key of letters, digits, '_', '.', '-'; a value of at most
// 100 characters without a comma) after the key is lower-cased and its spaces made '_' is left out and named.
func instanceTags(ctx context.Context, src *sql.Conn, id int) (tags, skipped []string, err error) {
	rows, err := src.QueryContext(ctx, `
SELECT T.TagName, T.TagValue FROM dbo.InstanceIDsTags IT JOIN dbo.Tags T ON T.TagID = IT.TagID
 WHERE IT.InstanceID = @id AND T.TagName IS NOT NULL AND T.TagName NOT LIKE N'{%' ORDER BY T.TagName, T.TagValue`, sql.Named("id", id))
	if err != nil {
		return nil, nil, fmt.Errorf("dbo.InstanceIDsTags: %w", err)
	}
	defer func() { _ = rows.Close() }()
	tags = []string{}
	for rows.Next() {
		var k string
		var v sql.NullString
		if err := rows.Scan(&k, &v); err != nil {
			return nil, nil, err
		}
		k = strings.ReplaceAll(strings.ToLower(strings.TrimSpace(k)), " ", "_")
		val := strings.TrimSpace(v.String)
		if k == "" || strings.Contains(k, ":") {
			continue
		}
		raw := k + ":" + val
		if val == "" {
			raw = k
		}
		t, perr := config.ParseTag(raw)
		if perr != nil {
			skipped = append(skipped, fmt.Sprintf("DBADash instance %d: %v", id, perr))
			continue
		}
		tags = append(tags, t.String())
	}
	return tags, skipped, rows.Err()
}

// openImportStore connects to the pgvigil repository and checks the login may do what the import does: create a
// month's partition, add an instance and insert into the four history tables (the owner may; the collector and the
// reader may not). A dry run needs to read only.
func openImportStore(ctx context.Context, repoDSN string, dry bool) (*pgxpool.Pool, error) {
	if strings.TrimSpace(repoDSN) == "" {
		return nil, errors.New("the pgvigil repository's dsn is empty")
	}
	cfg, err := pgxpool.ParseConfig(repoDSN)
	if err != nil {
		return nil, fmt.Errorf("repository dsn: %w", err)
	}
	cfg.MaxConns = 2
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-dbadash-import"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("repository: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("repository ping: %w", err)
	}
	if dry {
		return pool, nil
	}
	tables := make([]string, 0, len(importMappings))
	for _, m := range importMappings {
		tables = append(tables, "pgvigil."+m.Table)
	}
	var missing []string
	rows, err := pool.Query(ctx, `
SELECT t FROM unnest($1::text[]) AS t WHERE NOT coalesce(has_table_privilege(to_regclass(t), 'INSERT'), false)
UNION ALL
SELECT f FROM unnest(ARRAY['pgvigil.ensure_month_partition(text, timestamptz)',
                           'pgvigil.ensure_instance(text, text, text, int, boolean, text[], text)']) AS f
 WHERE NOT coalesce(has_function_privilege(to_regprocedure(f), 'EXECUTE'), false)`, tables)
	if err == nil {
		missing, err = pgx.CollectRows(rows, pgx.RowTo[string])
	}
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("repository rights: %w", err)
	}
	if len(missing) > 0 {
		pool.Close()
		return nil, fmt.Errorf("this login may not write what the import writes (%s): run the import with the repository owner's dsn, the one 'pgvigil migrate' uses", strings.Join(missing, ", "))
	}
	return pool, nil
}

// pgvigilInstance finds or (not in a dry run) creates the pgvigil SQL Server instance for a DBADash instance. An
// existing SQL Server instance of that name is used as it is (its description and tags are pgvigil's), except that a
// row Admin > Instances made at its add and pgvigil never read (no version, no mssql_instance read: whatever platform
// the page gave it - the join's w9e, finding 4) takes DBA Dash's version, and its platform when the page left it
// 'auto', as a new one would; one stored as PostgreSQL is a skip with its reason.
func pgvigilInstance(ctx context.Context, log *slog.Logger, pool *pgxpool.Pool, name string, in srcInstance, dry bool) (int, string, error) {
	var id int
	var engine string
	var never bool
	err := pool.QueryRow(ctx, `SELECT i.instance_id, i.engine, (i.server_version IS NULL
	    AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_instance m WHERE m.instance_id = i.instance_id)) FROM pgvigil.instances i WHERE i.name = $1`, name).Scan(&id, &engine, &never)
	platform := "sqlserver"
	if in.Edition == 8 { // DBADash's EngineEdition 8: Azure SQL Managed Instance (internal/mssql detect.go's kinds)
		platform = "azuresqlmi"
	}
	switch {
	case err == nil && engine == "sqlserver":
		if never && !dry {
			// is_active and the tags stay the page's (a disabled page instance stays disabled)
			if _, err := pool.Exec(ctx, `UPDATE pgvigil.instances SET platform = CASE WHEN platform = 'auto' THEN $2 ELSE platform END,
			     server_version = $3, server_version_num = $4
			     WHERE instance_id = $1 AND server_version IS NULL`, id, platform, nullIfEmpty(in.Version), versionNum(in.Version)); err != nil {
				return 0, "", fmt.Errorf("the page instance %s: %w", name, err)
			}
			log.Info("dbadash import: a page instance never read takes the source's platform and version", "name", name, "instance_id", id, "platform", platform)
		}
		return id, "", nil
	case err == nil:
		return 0, fmt.Sprintf("pgvigil stores %s as a %s instance: give the SQL Server its own name (the import's name map)", name, engine), nil
	case !errors.Is(err, pgx.ErrNoRows):
		return 0, "", fmt.Errorf("pgvigil.instances: %w", err)
	}
	if dry {
		return 0, "", nil
	}
	err = pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, $2, $3, $4, false, $5, 'sqlserver')`,
		name, platform, nullIfEmpty(in.Version), versionNum(in.Version), in.Tags).Scan(&id)
	if err != nil {
		return 0, "", fmt.Errorf("ensure_instance %s: %w", name, err)
	}
	log.Info("dbadash import: instance added", "name", name, "instance_id", id, "platform", platform, "tags", in.Tags)
	return id, "", nil
}

func nullIfEmpty(s string) any {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return s
}

// versionNum is a SQL Server ProductVersion as pgvigil stores it: major * 10000 + minor (16.0.4295.3 -> 160000);
// nil when it does not parse.
func versionNum(v string) any {
	var major, minor int
	if n, _ := fmt.Sscanf(strings.TrimSpace(v), "%d.%d", &major, &minor); n < 1 || major <= 0 {
		return nil
	}
	return major*10000 + minor
}

// importOne copies one mapping of one instance in batches, each batch one transaction with its months' partitions.
func importOne(ctx context.Context, src *sql.Conn, pool *pgxpool.Pool, m importMapping, in srcInstance, pid int, opt ImportOptions) (int64, error) {
	rows, err := src.QueryContext(ctx, m.Rows, sql.Named("id", in.ID), sql.Named("from", utc2(opt.From)), sql.Named("to", utc2(opt.To)))
	if err != nil {
		return 0, fmt.Errorf("read: %w", err)
	}
	defer func() { _ = rows.Close() }()
	cols, err := rows.Columns()
	if err != nil {
		return 0, err
	}
	facts, _ := json.Marshal(map[string]any{"linux": in.Linux})
	var total int64
	batch := make([]map[string]any, 0, opt.Batch)
	months := map[time.Time]bool{}
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		payload, err := json.Marshal(batch)
		if err != nil {
			return err
		}
		n, err := insertBatch(ctx, pool, m, pid, payload, facts, months)
		if err != nil {
			return err
		}
		total += n
		batch = batch[:0]
		months = map[time.Time]bool{}
		return nil
	}
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return total, fmt.Errorf("read: %w", err)
		}
		rec := make(map[string]any, len(cols))
		for i, c := range cols {
			rec[c] = importValue(vals[i])
		}
		at, ok := vals[0].(time.Time)
		if !ok {
			return total, fmt.Errorf("read: the row's time is %T, not a date", vals[0])
		}
		u := at.UTC()
		months[time.Date(u.Year(), u.Month(), 1, 0, 0, 0, 0, time.UTC)] = true
		batch = append(batch, rec)
		if len(batch) >= opt.Batch {
			if err := flush(); err != nil {
				return total, err
			}
		}
	}
	if err := rows.Err(); err != nil {
		return total, fmt.Errorf("read: %w", err)
	}
	return total, flush()
}

// insertBatch writes one batch in one transaction: the months' partitions first (in time order), then the rows.
func insertBatch(ctx context.Context, pool *pgxpool.Pool, m importMapping, pid int, payload, facts []byte, months map[time.Time]bool) (int64, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	ms := make([]time.Time, 0, len(months))
	for t := range months {
		ms = append(ms, t)
	}
	sort.Slice(ms, func(i, j int) bool { return ms[i].Before(ms[j]) })
	for _, t := range ms {
		if _, err := tx.Exec(ctx, `SELECT pgvigil.ensure_month_partition($1, $2)`, m.Table, t); err != nil {
			return 0, fmt.Errorf("partition %s %s: %w", m.Table, t.Format("2006-01"), err)
		}
	}
	args := []any{pid, string(payload)}
	if m.Facts {
		args = append(args, string(facts))
	}
	var n int64
	if err := tx.QueryRow(ctx, m.Insert, args...).Scan(&n); err != nil {
		return 0, fmt.Errorf("insert: %w", err)
	}
	return n, tx.Commit(ctx)
}

// importValue makes a DBADash value a JSON value for jsonb_to_recordset: a date as RFC 3339 in UTC (DBADash keeps
// UTC: the wall clock as stored), a decimal as its text (a job id is read as text by the T-SQL itself).
func importValue(v any) any {
	switch x := v.(type) {
	case time.Time:
		return time.Date(x.Year(), x.Month(), x.Day(), x.Hour(), x.Minute(), x.Second(), x.Nanosecond(), time.UTC).Format(time.RFC3339Nano)
	case []byte:
		return string(x)
	}
	return v
}
