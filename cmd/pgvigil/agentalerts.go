package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// runMSSQLAgentAlerts prints the script that creates the SQL Server Agent alerts pgvigil's checks ask for (-print), or
// the script that drops them (-print -drop). pgvigil never runs either: the server's DBA reads it and runs it.
func runMSSQLAgentAlerts(args []string) error { return mssqlAgentAlerts(os.Stdout, args) }

func mssqlAgentAlerts(w io.Writer, args []string) error {
	fs := flag.NewFlagSet("pgvigil mssql-agent-alerts", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	doPrint := fs.Bool("print", false, "print the script that creates the alerts")
	drop := fs.Bool("drop", false, "with -print: the script that drops the '(pgvigil) ...' alerts instead")
	operator := fs.String("operator", "", "the operator each alert e-mails (reused as it is when it exists)")
	email := fs.String("email", "", "with -operator: creates that operator with this address when none of its name exists")
	ag := fs.Bool("ag", false, "the Availability Group alerts too (made only where Availability Groups are on)")
	delay := fs.Int("delay", 0, fmt.Sprintf("seconds between two responses of one alert (0 = %d)", mssql.AgentAlertsDelay))
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("mssql-agent-alerts: %w", err)
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("mssql-agent-alerts: unexpected %q", fs.Arg(0))
	}
	if !*doPrint {
		return errors.New("mssql-agent-alerts: -print is the only action; pgvigil prints the script and the server's DBA runs it")
	}
	if *drop {
		if *operator != "" || *email != "" || *ag || *delay != 0 {
			return errors.New("mssql-agent-alerts: -drop takes no other flag (it drops every '(pgvigil) ...' alert and nothing else)")
		}
		_, err := io.WriteString(w, mssql.AgentAlertsDropScript())
		return err
	}
	script, err := mssql.AgentAlertsScript(mssql.AgentAlertsOptions{Operator: *operator, Email: *email, AG: *ag, DelaySeconds: *delay})
	if err != nil {
		return fmt.Errorf("mssql-agent-alerts: %w", err)
	}
	_, err = io.WriteString(w, script)
	return err
}
