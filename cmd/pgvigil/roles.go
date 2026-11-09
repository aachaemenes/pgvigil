package main

import (
	"fmt"
	"os"
)

// runRoles prints the SQL an operator runs on the repository (as its owner) to
// create logins for the repository roles (the collector; the UI, which also verifies
// UI passwords), and on each monitored server to create the monitoring login. Nothing is executed: the operator reads it,
// fills in the passwords or the identity, and runs it.
func runRoles(args []string) error {
	collector, reader, monitor, act := "pgvigil_agent", "pgvigil_ui", "pgvigil_monitor", "pgvigil_actions"
	if len(args) > 0 && args[0] == "-h" {
		fmt.Fprintln(os.Stderr, "usage: pgvigil roles   prints the CREATE ROLE statements for the repository and the monitored servers")
		return nil
	}
	fmt.Printf(`-- On the pgvigil repository, as its owner (the role that ran 'pgvigil migrate'):
-- the collector's login: may only call the import functions
CREATE ROLE %[1]s LOGIN PASSWORD '<set-me>' IN ROLE pgvigil_collector;
-- the web UI's login ('pgvigil serve -dsn'): SELECT on every table and view, the read functions, and
-- through pgvigil_auth the password check of the UI login (ui_password_hash); the ui_users table itself
-- stays the owner's. Grafana, a script or an MCP server takes a login IN ROLE pgvigil_reader alone.
CREATE ROLE %[2]s LOGIN PASSWORD '<set-me>' IN ROLE pgvigil_reader, pgvigil_auth;

-- On each monitored PostgreSQL server: the monitoring login (pg_monitor is all it needs;
-- on RDS, Aurora, Azure and Cloud SQL prefer the platform's IAM / Entra token login instead of a password)
CREATE ROLE %[3]s LOGIN PASSWORD '<set-me>' IN ROLE pg_monitor;
-- pg_cron (in cron.database_name, usually postgres): its row-level security shows a login only
-- its own jobs; to monitor every job the login needs USAGE on schema cron and BYPASSRLS:
-- GRANT USAGE ON SCHEMA cron TO %[3]s; ALTER ROLE %[3]s BYPASSRLS;   -- not available on RDS: see the docs
-- optional, where pg_stat_statements lives in a schema the login cannot see:
-- GRANT USAGE ON SCHEMA <that schema> TO %[3]s;

-- Optional, per monitored server: the actions login behind the UI's Cancel and Terminate buttons.
-- Absent by default; create it only where the UI may stop sessions. It holds pg_signal_backend and
-- nothing else (never a superuser: pgvigil refuses one, and a superuser's session stays out of its reach).
-- Point the instance's actions_dsn at it (env:NAME or file:/path only); every attempt is kept in the
-- repository's pgvigil.actions_log, written by serve through the config's repository login (pgvigil_collector).
-- CREATE ROLE %[4]s LOGIN PASSWORD '<set-me>' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
-- GRANT pg_signal_backend TO %[4]s;
`, collector, reader, monitor, act)
	return nil
}
