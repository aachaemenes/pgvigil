package demo

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// demoServiceChannel is the alert channel of the demo's failed and refused sends (the Collector errors page's
// '(the service)' rows); its rows are removed and written again at each seed.
const demoServiceChannel = "demo-collector-errors"

// SeedCollectorErrors gives the Collector errors and SQL Server errors pages something to show (0198, B24o): on the
// first PostgreSQL demo instance an import refused, a batch part refused (partial), a failed connection and a skip;
// on the SQL Server demo instances two collections denied a right (the rights suggestion) and a batch import part
// refused; two alert sends of the service that did not go out; an acknowledgement of the PostgreSQL instance's errors;
// error-log lines (824, 9002, 823, three 17806) and AlwaysOn_health events (1480, 35206) on the SQL Server instances,
// with a known-noise label on 17806. The collection_log rows are older than every collection's last run, so no
// collection turns failing: collection_dates is left alone. Run after SeedAcks (whose 'demo seed' rows it shares).
func SeedCollectorErrors(ctx context.Context, pool *pgxpool.Pool, prefix string, end time.Time) error {
	for _, sql := range []string{
		`DELETE FROM pgvigil.collection_log WHERE note LIKE 'demo: %'`,
		`DELETE FROM pgvigil.alert_log WHERE channel = '` + demoServiceChannel + `'`,
		`DELETE FROM pgvigil.mssql_errorlog WHERE line_key LIKE 'demo-errorfleet-%'`,
		`DELETE FROM pgvigil.mssql_ag_events WHERE event_key LIKE 'demo-errorfleet-%'`,
	} {
		if _, err := pool.Exec(ctx, sql); err != nil {
			return err
		}
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
WITH pg AS (SELECT instance_id, name FROM pgvigil.instances WHERE starts_with(name, $2) AND engine = 'postgres' ORDER BY name LIMIT 1),
ms AS (SELECT instance_id, name, row_number() OVER (ORDER BY name) AS k FROM pgvigil.instances WHERE starts_with(name, $2) AND engine = 'sqlserver'),
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
   WHERE ms.k = 1
  UNION ALL
  SELECT ms.instance_id, 'mssql_errorlog', $1::timestamptz - interval '6 hours', 'partial',
         'demo: errorlog: import of a part: ERROR: deadlock detected (SQLSTATE 40P01)', 'import' FROM ms WHERE ms.k = 2
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
WITH ms AS (SELECT instance_id, row_number() OVER (ORDER BY name) AS k FROM pgvigil.instances WHERE starts_with(name, $2) AND engine = 'sqlserver')
INSERT INTO pgvigil.mssql_errorlog (instance_id, log_at, line_key, snapshot_at, logged_local, error_number, severity, error_state, class, message)
SELECT ms.instance_id, date_trunc('second', $1::timestamptz - make_interval(mins => m)), 'demo-errorfleet-' || key, $1::timestamptz,
       (date_trunc('second', $1::timestamptz - make_interval(mins => m)) AT TIME ZONE 'UTC'), n, sev, 1, cls, msg
  FROM ms JOIN (VALUES
    (1, 'a', 400, 824, 24, 'corruption', 'SQL Server detected a logical consistency-based I/O error: incorrect checksum (expected: 0x9a3e399c; actual: 0x9a14b99c). It occurred during a read of page (1:178064) in database ID 6 at offset 0x00000057020000 in file ''D:\Data\Sales.mdf''.'),
    (1, 'b', 300, 17806, 20, 'general', 'SSPI handshake failed with error code 0x8009030c, state 14 while establishing a connection with integrated security; the connection has been closed. [CLIENT: 10.0.0.31]'),
    (1, 'c', 200, 17806, 20, 'general', 'SSPI handshake failed with error code 0x8009030c, state 14 while establishing a connection with integrated security; the connection has been closed. [CLIENT: 10.0.0.31]'),
    (1, 'd', 100, 17806, 20, 'general', 'SSPI handshake failed with error code 0x8009030c, state 14 while establishing a connection with integrated security; the connection has been closed. [CLIENT: 10.0.0.31]'),
    (2, 'e', 250, 9002, 17, 'general', 'The transaction log for database ''SalesDB'' is full due to ''LOG_BACKUP''.'),
    (3, 'f', 150, 823, 24, 'io', 'The operating system returned error 21(The device is not ready.) to SQL Server during a read at offset 0x00000000012000 in file ''E:\Data\HR.mdf''.')
  ) v(k, key, m, n, sev, cls, msg) ON v.k = ms.k`, end, prefix); err != nil {
		return err
	}
	if _, err := pool.Exec(ctx, `
WITH ms AS (SELECT instance_id, row_number() OVER (ORDER BY name) AS k FROM pgvigil.instances WHERE starts_with(name, $2) AND engine = 'sqlserver')
INSERT INTO pgvigil.mssql_ag_events (instance_id, event_at, event_key, snapshot_at, event_name, error_number, severity, family, message)
SELECT ms.instance_id, $1::timestamptz - make_interval(mins => m), 'demo-errorfleet-' || key, $1::timestamptz, 'error_reported', n, sev, fam, msg
  FROM ms JOIN (VALUES
    (2, 'g', 220, 1480, 10, 'role', 'The availability group database "SalesDB" is changing roles from "SECONDARY" to "PRIMARY" because the mirroring session or availability group failed over due to role synchronization.'),
    (1, 'h', 90, 35206, 16, 'connection', 'A connection timeout has occurred on a previously established connection to availability replica ''SQL02'' with id [5E0C8F1A]. Either a networking or a firewall issue exists or the availability replica has transitioned to the resolving role.')
  ) v(k, key, m, n, sev, fam, msg) ON v.k = ms.k`, end, prefix); err != nil {
		return err
	}
	_, err = pool.Exec(ctx, `
WITH pg AS (SELECT instance_id, name FROM pgvigil.instances WHERE starts_with(name, $2) AND engine = 'postgres' ORDER BY name LIMIT 1),
mk AS (SELECT pg.instance_id, pg.name, (SELECT max(l.log_id) FROM pgvigil.collection_log l WHERE l.instance_id = pg.instance_id AND l.note LIKE 'demo: %' AND l.collection IN ('statements', 'schema')) AS mark FROM pg)
SELECT pgvigil.import_ack($1, p) FROM (
  SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','ack','instance_id',instance_id,'instance_name',name,
         'check_key','collector errors','seen_state','log_id:' || mark,'until_change',true,'note','the disk was full: grown on Tuesday') p FROM mk WHERE mark IS NOT NULL
  UNION ALL SELECT jsonb_build_object('op','add','ui_user','demo','client','demo seed','kind','noise','check_key','error log:17806',
         'note','known: the old report server''s service account (SSPI)')) q`, time.Now(), prefix)
	return err
}
