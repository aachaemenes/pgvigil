package collect

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// instanceCollector is the first collection of every instance: what it is.
// Everything else keys off its platform and version. It runs hourly and on start.
type instanceCollector struct{}

func init() { Register(instanceCollector{}) }

func (instanceCollector) Name() string                   { return "instance" }
func (instanceCollector) DefaultInterval() time.Duration { return time.Hour }
func (instanceCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

// settingValueSQL is a setting's value as it is stored: a setting that can carry a credential is masked (its presence
// and its changes still show), and a password inside any other value too.
const settingValueSQL = `CASE
              WHEN name IN ('primary_conninfo','archive_command','restore_command','archive_cleanup_command',
                            'recovery_end_command','ssl_passphrase_command','ssl_key_file')
                THEN '<masked>'
              ELSE regexp_replace(setting, '(password|passfile|sslkey|sslpassword)=\S+', '\1=<masked>', 'gi')
            END`

// settingSourcesSQL names the server-level sources: the collector's own SETs (session), role settings (user,
// database user) and client-supplied values are not the instance's configuration.
const settingSourcesSQL = `source IN ('configuration file','command line','environment variable','global','database')`

// Reads only functions and settings every role can see; no superuser needed.
const instanceSQL = `
SELECT
  version()                                         AS server_version,
  current_setting('server_version_num')::int        AS server_version_num,
  pg_is_in_recovery()                               AS is_replica,
  pg_postmaster_start_time()                        AS postmaster_start,
  now()                                             AS server_now,
  current_setting('TimeZone')                       AS time_zone,
  current_database()                                AS connected_database,
  current_user                                      AS connected_user,
  host(inet_server_addr())                          AS server_addr,
  inet_server_port()                                AS server_port,
  current_setting('data_checksums')                 AS data_checksums,
  current_setting('shared_buffers')                 AS shared_buffers,
  current_setting('max_connections')::int           AS max_connections,
  current_setting('work_mem')                       AS work_mem,
  current_setting('wal_level')                      AS wal_level,
  current_setting('track_io_timing')                AS track_io_timing,
  current_setting('log_min_duration_statement')     AS log_min_duration_statement,
  (SELECT count(*) FROM pg_database WHERE NOT datistemplate)   AS database_count,
  (SELECT coalesce(json_agg(json_build_object('name', extname, 'version', extversion) ORDER BY extname), '[]'::json)
     FROM pg_extension)                             AS extensions,
  -- the server-level non-default settings (the change history compares this list)
  (SELECT coalesce(json_agg(json_build_object('name', name, 'value', ` + settingValueSQL + `) ORDER BY name), '[]'::json)
     FROM pg_settings
    WHERE ` + settingSourcesSQL + `) AS non_default_settings,
  -- the same settings with their unit, compiled-in value (boot_val, in the setting's own unit like the value), source,
  -- context and category, and every setting waiting for a restart: a postmaster setting edited from its default and not yet
  -- restarted still reads source 'default', so the source list alone would miss the one case the column is for
  (SELECT coalesce(json_agg(json_build_object('name', name, 'value', ` + settingValueSQL + `, 'unit', unit,
            'boot_val', boot_val, 'source', source, 'context', context, 'pending_restart', pending_restart,
            'category', category) ORDER BY name), '[]'::json)
     FROM pg_settings
    WHERE ` + settingSourcesSQL + ` OR pending_restart) AS settings_detail`

func (instanceCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	rows, err := conn.Query(ctx, instanceSQL)
	if err != nil {
		return nil, err
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, err
	}
	for _, r := range out {
		r["platform"] = string(info.Kind)
		r["has_pg_stat_statements"] = info.HasPgStatStmts
		r["has_pg_cron"] = info.HasPgCron
		r["has_pgagent"] = info.HasPgAgent
		r["has_wait_sampling"] = info.HasWaitSampling
		r["has_log_fdw"] = info.HasLogFdw
	}
	return out, nil
}

// rowsToMaps turns a pgx result into JSON-ready maps keyed by column name.
func rowsToMaps(rows pgx.Rows) ([]Row, error) {
	defer rows.Close()
	descs := rows.FieldDescriptions()
	out := []Row{} // never nil: an empty collection must serialise as [] not null
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return nil, err
		}
		m := make(Row, len(descs))
		for i, d := range descs {
			m[string(d.Name)] = vals[i]
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
