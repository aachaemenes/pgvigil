package demo

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// demoServiceChannel is the alert channel of the demo's failed and refused sends (the Collector errors page's
// '(the service)' rows); its rows are removed and written again at each seed.
const demoServiceChannel = "demo-collector-errors"

// SeedCollectorErrors gives the Collector errors and SQL Server errors pages something to show (0198): on the
// first PostgreSQL demo instance an import refused, a batch part refused (partial), a failed connection and a skip;
// on -sql03 two collections denied a right (the rights suggestion), on -sql01 a batch import part refused; two alert
// sends of the service that did not go out; an acknowledgement of the PostgreSQL instance's errors; error-log lines on
// -sql01 (824 in database ID 5, its Sales; 9002 for staging_import, whose log is never backed up; three 17806) and
// -sql02 (823), AlwaysOn_health events on -sql01, the group's primary (1480 at its failover, 35206 to DEMO-SQL02); a
// known-noise label on 17806. Every row is the demo fleet's only (instances tagged demo whose name starts with
// prefix; the label carries tag 'demo', so a real instance's 17806 lines stay shown). The collection_log rows are older
// than every collection's last run, so no collection turns failing: collection_dates is left alone. Run after SeedAcks
// (whose 'demo seed' rows it shares).
func SeedCollectorErrors(ctx context.Context, pool *pgxpool.Pool, prefix string, end time.Time) error {
	const demoIDs = `(SELECT instance_id FROM pgvigil.instances WHERE 'demo' = ANY (tags) AND starts_with(name, $1))`
	for _, sql := range []string{
		`DELETE FROM pgvigil.collection_log WHERE note LIKE 'demo: %' AND instance_id IN ` + demoIDs,
		`DELETE FROM pgvigil.mssql_errorlog WHERE line_key LIKE 'demo-errorfleet-%' AND instance_id IN ` + demoIDs,
		`DELETE FROM pgvigil.mssql_ag_events WHERE event_key LIKE 'demo-errorfleet-%' AND instance_id IN ` + demoIDs,
	} {
		if _, err := pool.Exec(ctx, sql, prefix); err != nil {
			return err
		}
	}
	if _, err := pool.Exec(ctx, `DELETE FROM pgvigil.alert_log WHERE channel = '`+demoServiceChannel+`'`); err != nil {
		return err
	}
	for _, sql := range []string{
		`SELECT pgvigil.ensure_month_partition('alert_log', $1::timestamptz)`,
		`SELECT pgvigil.mssql_event_partition('mssql_errorlog', $1::timestamptz)`,
		`SELECT pgvigil.mssql_event_partition('mssql_ag_events', $1::timestamptz)`,
		`SELECT pgvigil.mssql_event_partition('mssql_errorlog', $1::timestamptz - interval '1 day')`,
		`SELECT pgvigil.mssql_event_partition('mssql_ag_events', $1::timestamptz - interval '1 day')`,
	} {
		if _, err := pool.Exec(ctx, sql, end); err != nil {
			return err
		}
	}
	_, err := pool.Exec(ctx, `
WITH pg AS (SELECT instance_id, name FROM pgvigil.instances WHERE 'demo' = ANY (tags) AND starts_with(name, $2) AND engine = 'postgres' ORDER BY name LIMIT 1),
ms AS (SELECT instance_id, name FROM pgvigil.instances WHERE 'demo' = ANY (tags) AND starts_with(name, $2) AND engine = 'sqlserver'),
l AS (
  SELECT pg.instance_id, c, $1::timestamptz - make_interval(hours => h) AS at, st, note, stage FROM pg, (VALUES
    ('statements', 30, 'error', 'demo: import statements: ERROR: could not extend file "base/16384/2619": No space left on device (SQLSTATE 53100)', 'import'),
    ('schema', 20, 'partial', 'demo: schema:reporting: import: ERROR: canceling statement due to statement timeout (SQLSTATE 57014)', 'import'),
    ('activity', 12, 'error', 'demo: connect: dial tcp 10.0.0.14:5432: connect: connection refused', 'connect'),
    ('tables', 8, 'skipped', 'demo: the login cannot read pg_class of database archive', NULL)) v(c, h, st, note, stage)
  UNION ALL
  SELECT ms.instance_id, c, $1::timestamptz - make_interval(hours => h), st, note, stage FROM ms, (VALUES
    ('mssql_jobs', 26, 'error', 'demo: The SELECT permission was denied on the object ''sysjobhistory'', database ''msdb''.', 'collect'),
    ('mssql_audit', 25, 'error', 'demo: VIEW SERVER STATE permission was denied on object ''server''.', 'collect')) v(c, h, st, note, stage)
   WHERE ms.name LIKE '%-sql03'
  UNION ALL
  SELECT ms.instance_id, 'mssql_errorlog', $1::timestamptz - interval '6 hours', 'partial',
         'demo: errorlog: import of a part: ERROR: deadlock detected (SQLSTATE 40P01)', 'import' FROM ms WHERE ms.name LIKE '%-sql01'
)
INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, duration_ms, status, note, stage)
SELECT l.instance_id, l.c, l.at, 900, l.st, l.note, l.stage FROM l`, end, prefix)
	if err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, `
INSERT INTO pgvigil.alert_log (snapshot_at, channel, kind, destination, outcome, error, keys) VALUES
  ($1::timestamptz - interval '3 hours', '`+demoServiceChannel+`', 'mail', 'dba-team@example.com', 'failed', 'smtp: 535 5.7.8 authentication failed', '{demo-svc-1}'),
  ($1::timestamptz - interval '2 hours', '`+demoServiceChannel+`', 'webhook', 'https://hooks.example.com/dba', 'refused', 'the address answered a redirect: not followed', '{demo-svc-2}')`, end); err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, `
WITH ms AS (SELECT instance_id, name FROM pgvigil.instances WHERE 'demo' = ANY (tags) AND starts_with(name, $2) AND engine = 'sqlserver')
INSERT INTO pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, error_number, severity, error_state, class, message)
SELECT ms.instance_id, date_trunc('second', $1::timestamptz - make_interval(mins => m)), 'demo-errorfleet-' || key, $1::timestamptz,
       (date_trunc('second', $1::timestamptz - make_interval(mins => m)) AT TIME ZONE 'UTC'), n, sev, 1, cls, msg
  FROM ms JOIN (VALUES
    ('-sql01', 'a', 400, 824, 24, 'corruption', 'SQL Server detected a logical consistency-based I/O error: incorrect checksum (expected: 0x9a3e399c; actual: 0x9a14b99c). It occurred during a read of page (1:178064) in database ID 5 at offset 0x00000057020000 in file ''E:\Data\Sales.mdf''.'),
    ('-sql01', 'b', 300, 17806, 20, 'general', 'SSPI handshake failed with error code 0x8009030c, state 14 while establishing a connection with integrated security; the connection has been closed. [CLIENT: 10.0.0.31]'),
    ('-sql01', 'c', 200, 17806, 20, 'general', 'SSPI handshake failed with error code 0x8009030c, state 14 while establishing a connection with integrated security; the connection has been closed. [CLIENT: 10.0.0.31]'),
    ('-sql01', 'd', 100, 17806, 20, 'general', 'SSPI handshake failed with error code 0x8009030c, state 14 while establishing a connection with integrated security; the connection has been closed. [CLIENT: 10.0.0.31]'),
    ('-sql01', 'e', 250, 9002, 17, 'general', 'The transaction log for database ''staging_import'' is full due to ''LOG_BACKUP''.'),
    ('-sql02', 'f', 150, 823, 24, 'io', 'The operating system returned error 21(The device is not ready.) to SQL Server during a read at offset 0x00000000012000 in file ''D:\Data\Vault.mdf''.')
  ) v(sfx, key, m, n, sev, cls, msg) ON ms.name LIKE '%' || v.sfx`, end, prefix); err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, `
WITH ms AS (SELECT instance_id, name FROM pgvigil.instances WHERE 'demo' = ANY (tags) AND starts_with(name, $2) AND engine = 'sqlserver')
INSERT INTO pgvigil.mssql_ag_events (instance_id, event_at, event_key, snapshot_at, event_name, error_number, severity, family, message)
SELECT ms.instance_id, $1::timestamptz - make_interval(mins => m), 'demo-errorfleet-' || key, $1::timestamptz, 'error_reported', n, sev, fam, msg
  FROM ms JOIN (VALUES
    ('-sql01', 'g', 30, 1480, 10, 'role', 'The availability group database "Sales" is changing roles from "SECONDARY" to "PRIMARY" because the mirroring session or availability group failed over due to role synchronization.'),
    ('-sql01', 'h', 90, 35206, 16, 'connection', 'A connection timeout has occurred on a previously established connection to availability replica ''DEMO-SQL02'' with id [5E0C8F1A]. Either a networking or a firewall issue exists or the availability replica has transitioned to the resolving role.')
  ) v(sfx, key, m, n, sev, fam, msg) ON ms.name LIKE '%' || v.sfx`, end, prefix); err != nil {
		return err
	}
	_, err = pool.Exec(ctx, `
WITH pg AS (SELECT instance_id, name FROM pgvigil.instances WHERE 'demo' = ANY (tags) AND starts_with(name, $2) AND engine = 'postgres' ORDER BY name LIMIT 1),
mk AS (SELECT pg.instance_id, pg.name, (SELECT max(l.log_id) FROM pgvigil.collection_log l WHERE l.instance_id = pg.instance_id AND l.note LIKE 'demo: %' AND l.collection IN ('statements', 'schema')) AS mark FROM pg)
SELECT pgvigil.import_ack($1, p) FROM (
  SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','ack','instance_id',instance_id,'instance_name',name,
         'check_key','collector errors','seen_state','log_id:' || mark,'until_change',true,'note','the disk was full: grown on Tuesday') p FROM mk WHERE mark IS NOT NULL
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','noise','check_key','error log:17806','tag','demo',
         'note','known: the old report server''s service account (SSPI)')) q`, time.Now(), prefix)
	return err
}
