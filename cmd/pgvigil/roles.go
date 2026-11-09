package main

import (
	"fmt"
	"os"
)

// runRoles prints the SQL an operator runs on the repository (as its owner) to
// create logins for the two repository roles, and on each monitored server to
// create the monitoring login. Nothing is executed: the operator reads it,
// fills in the passwords or the identity, and runs it.
func runRoles(args []string) error {
	collector, reader, monitor := "pgvigil_agent", "pgvigil_ui", "pgvigil_monitor"
	if len(args) > 0 && args[0] == "-h" {
		fmt.Fprintln(os.Stderr, "usage: pgvigil roles   prints the CREATE ROLE statements for the repository and the monitored servers")
		return nil
	}
	fmt.Printf(`-- On the pgvigil repository, as its owner (the role that ran 'pgvigil migrate'):
-- the collector's login: may only call the import functions
CREATE ROLE %[1]s LOGIN PASSWORD '<set-me>' IN ROLE pgvigil_collector;
-- a reader for the UI, Grafana or an MCP server: SELECT on every table, the read functions
CREATE ROLE %[2]s LOGIN PASSWORD '<set-me>' IN ROLE pgvigil_reader;

-- On each monitored PostgreSQL server: the monitoring login (pg_monitor is all it needs;
-- on RDS, Aurora, Azure and Cloud SQL prefer the platform's IAM / Entra token login instead of a password)
CREATE ROLE %[3]s LOGIN PASSWORD '<set-me>' IN ROLE pg_monitor;
-- optional, where pg_stat_statements lives in a schema the login cannot see:
-- GRANT USAGE ON SCHEMA <that schema> TO %[3]s;
`, collector, reader, monitor)
	return nil
}
