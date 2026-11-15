package web

// GET /api/mssql/agent-alerts-script?instance=N (C13, B9d; its route is a WIRING line of web.go): the script that
// creates the SQL Server Agent alerts the instance's checks ask for, for the Checks page's 'The script that creates
// them' disclosure. pgvigil prints it and never runs it; the reply carries it as text. The script names an operator
// the last read found enabled and with an e-mail address (the first by name), else a commented placeholder; its
// Availability Group block is in the text, made only where the server has Availability Groups on when it runs. Where
// the platform rules alerts out, the reply says why and carries no script.

import (
	"errors"
	"fmt"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

const sqlAgentAlertsScriptFacts = `
SELECT i.name, i.engine, coalesce(i.platform, ''),
       coalesce((SELECT m.engine_edition FROM pgvigil.mssql_instance m WHERE m.instance_id = i.instance_id), 0),
       coalesce((SELECT o.name FROM pgvigil.mssql_agent_operator o
                  WHERE o.instance_id = i.instance_id AND o.enabled AND o.has_email ORDER BY o.name LIMIT 1), '')
  FROM pgvigil.instances i
 WHERE i.instance_id = $1`

// MSSQLAgentAlertsScript is GET /api/mssql/agent-alerts-script?instance=N.
func (s *Server) MSSQLAgentAlertsScript(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var name, engine, platform, op string
	var edition int
	err = s.pool.QueryRow(r.Context(), sqlAgentAlertsScriptFacts, id).Scan(&name, &engine, &platform, &edition, &op)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if engine != "sqlserver" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %s is not a SQL Server instance", name))
		return
	}
	out := struct {
		Applicable bool   `json:"applicable"`
		Reason     string `json:"reason,omitempty"`
		Operator   string `json:"operator,omitempty"`
		Script     string `json:"script,omitempty"`
	}{}
	if out.Reason = mssql.AgentAlertsNotApplicable(platform, edition); out.Reason != "" {
		s.reply(w, r, out, nil)
		return
	}
	script, err := mssql.AgentAlertsScript(mssql.AgentAlertsOptions{Operator: op, AG: true, Placeholder: op == ""})
	if err != nil {
		// an operator's name the script cannot carry (a control character): the placeholder instead
		op = ""
		script, err = mssql.AgentAlertsScript(mssql.AgentAlertsOptions{AG: true, Placeholder: true})
	}
	out.Applicable, out.Operator, out.Script = err == nil, op, script
	s.reply(w, r, out, err)
}
