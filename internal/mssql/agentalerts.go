package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The alerts area of mssql_checks: SQL Server Agent's alerts and operators as msdb holds them, and whether the
// server would tell anyone about a severe error. A new server has no alert and no operator; sp_Blitz raises that
// (its CheckIDs 30, 31, 59, 61, 73, 96, 98, 219) and so does this read:
//
//   - no enabled operator (warning): nothing Agent raises can reach a person;
//   - no alert for any of the severities 19 to 25 (warning), or for some of them (advice);
//   - no alert for the errors 823, 824 and 825, the read errors that mean a damaged page (warning);
//   - an alert that is disabled, one that is enabled and notifies nobody and starts no job, one that leaves the
//     error's text out of its message (advice each);
//   - no fail-safe operator (advice), where the server lets the login read it.
//
// An operator's e-mail address is not stored: the read keeps whether one is set.
//
// Rights: SELECT on msdb.dbo.sysalerts, sysoperators and sysnotifications (db_datareader in msdb); the fail-safe
// operator is read with master.dbo.sp_MSgetalertinfo, which a login without the right to run it does not get: the
// rule is then left out and the area's note says so. Express has no Agent: the area is not read there.

// agentAlertsSQL: every alert with the count of operators it notifies.
var agentAlertsSQL = `SELECT 'alert' AS kind, CAST(a.name AS nvarchar(128)) AS name, CAST(a.message_id AS int) AS message_id,
  CAST(a.severity AS int) AS severity, CAST(a.enabled AS int) AS enabled, CAST(a.delay_between_responses AS int) AS delay_s,
  CAST(a.include_event_description AS int) AS include_event_description, CAST(a.occurrence_count AS int) AS occurrence_count,
  ` + utcText(agentDateTime("a.last_occurrence_date", "a.last_occurrence_time")) + ` AS last_occurrence_utc,
  CAST(CASE WHEN a.job_id IS NULL OR a.job_id = 0x00 THEN 0 ELSE 1 END AS int) AS has_job,
  (SELECT CAST(COUNT(*) AS int) FROM msdb.dbo.sysnotifications n WHERE n.alert_id = a.id) AS notifies
FROM msdb.dbo.sysalerts a
ORDER BY a.name`

// agentOperatorsSQL: every operator, without its addresses.
var agentOperatorsSQL = `SELECT 'operator' AS kind, CAST(o.name AS nvarchar(128)) AS name, CAST(o.enabled AS int) AS enabled,
  CAST(CASE WHEN NULLIF(LTRIM(RTRIM(o.email_address)), N'') IS NULL THEN 0 ELSE 1 END AS int) AS has_email,
  ` + utcText(agentDateTime("o.last_email_date", "o.last_email_time")) + ` AS last_email_utc
FROM msdb.dbo.sysoperators o
ORDER BY o.name`

// failSafeSQL: the Agent's alert settings; the fail-safe operator is one of its columns.
const failSafeSQL = `EXEC master.dbo.sp_MSgetalertinfo @includeaddresses = 0`

// The severities and errors an alert is expected for (sp_Blitz 30 and 61; 96).
var (
	alertSeverities = []int64{19, 20, 21, 22, 23, 24, 25}
	alertErrors     = []int64{823, 824, 825}
)

// runAgentAlerts reads the alerts and operators into the run.
func runAgentAlerts(ctx context.Context, conn *sql.Conn, info Info, c *checksRun) {
	switch {
	case info.EngineEdition == 4:
		c.add(areaRow(AreaAlerts, false, "SQL Server Express has no SQL Server Agent: there are no alerts to read"))
		return
	case !info.MsdbAccess:
		c.unread(AreaAlerts, "msdb.dbo.sysalerts", "the login has no access to msdb: the Agent's alerts and operators were not read")
		return
	}
	alerts, err := QueryRows(ctx, conn, agentAlertsSQL)
	if err != nil {
		c.unread(AreaAlerts, "msdb.dbo.sysalerts", "the Agent's alerts were not read: "+err.Error())
		return
	}
	ops, err := QueryRows(ctx, conn, agentOperatorsSQL)
	if err != nil {
		c.unread(AreaAlerts, "msdb.dbo.sysoperators", "the Agent's operators were not read: "+err.Error())
		return
	}
	// the fail-safe operator: read where the login may, never the area's failure
	failSafe, fsRead, note := "", false, ""
	if fs, ferr := QueryRows(ctx, conn, failSafeSQL); ferr != nil {
		note = "the fail-safe operator was not read (sp_MSgetalertinfo: " + ferr.Error() + ")"
	} else {
		failSafe, fsRead, note = failSafeFromRows(fs)
	}
	c.add(alerts...)
	c.add(ops...)
	c.add(collect.Row{"kind": "agent_alerting", "failsafe_read": b2i(fsRead), "failsafe_operator": nilIfEmpty(strings.TrimSpace(failSafe))})
	c.find(agentAlertFindings(alerts, ops, fsRead, strings.TrimSpace(failSafe))...)
	c.add(areaRow(AreaAlerts, true, note))
}

// failSafeFromRows takes the fail-safe operator out of sp_MSgetalertinfo's result: one row whose column
// AlertFailSafeOperator holds the name, NULL when none is set. A result without that row or column is not read,
// never 'none set'.
func failSafeFromRows(fs []collect.Row) (operator string, read bool, note string) {
	if len(fs) != 1 {
		return "", false, fmt.Sprintf("the fail-safe operator was not read: sp_MSgetalertinfo returned %d rows", len(fs))
	}
	v, has := fs[0]["AlertFailSafeOperator"]
	if !has {
		return "", false, "the fail-safe operator was not read: sp_MSgetalertinfo returned no AlertFailSafeOperator column"
	}
	operator, _ = v.(string)
	return strings.TrimSpace(operator), true, ""
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// agentAlertFindings judges the alerts and operators.
func agentAlertFindings(alerts, ops []collect.Row, failSafeRead bool, failSafe string) []checkFinding {
	var out []checkFinding
	add := func(check, object, sev, rule, value, explain string) {
		out = append(out, checkFinding{Area: AreaAlerts, Check: check, Object: object, Severity: sev, Rule: rule, Value: value, Explain: explain})
	}
	enabledOps := 0
	for _, o := range ops {
		if o["enabled"] == int64(1) {
			enabledOps++
		}
	}
	if enabledOps == 0 {
		add("no operator", "SQL Server Agent", sevWarning, "sp_Blitz 31", strconv.Itoa(len(ops)),
			fmt.Sprintf("no enabled operator (%d defined): an alert or a failed job can notify nobody", len(ops)))
	}
	bySev, byErr := map[int64]bool{}, map[int64]bool{}
	for _, a := range alerts {
		name, _ := a["name"].(string)
		if s, _ := a["severity"].(int64); s > 0 {
			bySev[s] = true
		}
		if m, _ := a["message_id"].(int64); m > 0 {
			byErr[m] = true
		}
		if a["enabled"] != int64(1) {
			add("alert disabled", name, sevInfo, "sp_Blitz 98", "0", "the alert '"+name+"' is disabled")
			continue
		}
		n, _ := a["notifies"].(int64)
		if n == 0 && a["has_job"] != int64(1) {
			add("alert without a response", name, sevInfo, "sp_Blitz 59", "0", "the alert '"+name+"' is enabled, notifies no operator and starts no job")
		}
		if a["include_event_description"] == int64(0) {
			add("alert without the error's text", name, sevInfo, "sp_Blitz 219", "0", "the alert '"+name+"' leaves the error's description out of its message")
		}
	}
	missing := func(want []int64, have map[int64]bool) []string {
		var m []string
		for _, w := range want {
			if !have[w] {
				m = append(m, strconv.FormatInt(w, 10))
			}
		}
		return m
	}
	if m := missing(alertSeverities, bySev); len(m) == len(alertSeverities) {
		add("no alerts for severity 19 to 25", "SQL Server Agent", sevWarning, "sp_Blitz 61", "0", "no alert is defined for any severity from 19 to 25: a fatal error is written to the log and nobody is told")
	} else if len(m) > 0 {
		add("alerts missing for some severities", "SQL Server Agent", sevInfo, "sp_Blitz 30", strconv.Itoa(len(alertSeverities)-len(m)),
			"no alert is defined for severity "+strings.Join(m, ", ")+" (of 19 to 25)")
	}
	if m := missing(alertErrors, byErr); len(m) > 0 {
		add("no alerts for corruption errors", "SQL Server Agent", sevWarning, "sp_Blitz 96", strconv.Itoa(len(alertErrors)-len(m)),
			"no alert is defined for error "+strings.Join(m, ", ")+" (823, 824 and 825 are the read errors of a damaged page or a failing disk)")
	}
	if failSafeRead && failSafe == "" {
		add("no fail-safe operator", "SQL Server Agent", sevInfo, "sp_Blitz 73", "0", "no fail-safe operator is set: when an alert's operators cannot be reached nobody is told")
	}
	return out
}
