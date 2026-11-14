package mssql

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// Amazon RDS for SQL Server's high availability mode and its last failover, two rows of mssql_properties on an RDS
// instance (CLOUDSQL C3-1), from the two procedures AWS gives for them:
//
//   - msdb.dbo.rds_get_high_availability_option: one value, 'Single-AZ', 'Multi-AZ (AlwaysOn)', 'Multi-AZ
//     (Mirroring)' or 'Multi-AZ (Block level replication)' (AWS's Multi-AZ page). R1, a real RDS for SQL Server 2019
//     Standard instance in a single AZ, answered one column high_availability = 'Single-AZ'. Tracked: a change of
//     mode is logged.
//   - msdb.dbo.rds_failover_time: errorlog_available_from and recent_failover_time, null when no failover is left in
//     the error logs (AWS's page 'Determining the last failover time'). It refuses a single-AZ instance (R1: Msg 50000
//     'This procedure can only be used on Multi-AZ RDS Instance.'), so it is asked only when the mode was read and is
//     not Single-AZ. Shown, not tracked: the error logs roll over and the value with them. Its Multi-AZ answer is not
//     proven on a live instance (R2, Multi-AZ, was not approved): the reading follows AWS's page.
//
// The monitoring login needs EXECUTE on each (R1: Msg 229 without it), which the master user may grant. The right is
// optional: without it the row says 'not granted: <the GRANT line>' and the run stays ok; any other error is 'not
// read: <the error>' and the run partial.

const (
	rdsHAProc       = "msdb.dbo.rds_get_high_availability_option"
	rdsFailoverProc = "msdb.dbo.rds_failover_time"
	rdsSingleAZ     = "Single-AZ"
)

// rdsHAAnswer is what the two procedures answered: their rows or their errors (foAsked: the failover procedure was
// called), and the login's name for a GRANT line ("" when not read).
type rdsHAAnswer struct {
	ha      []collect.Row
	haErr   error
	fo      []collect.Row
	foErr   error
	foAsked bool
	login   string
}

// readRDSHA calls the two procedures as the monitoring login.
func readRDSHA(ctx context.Context, conn *sql.Conn) rdsHAAnswer {
	var a rdsHAAnswer
	a.ha, a.haErr = QueryRows(ctx, conn, "EXEC "+rdsHAProc)
	if rdsHAAsksFailover(a.ha, a.haErr) {
		a.foAsked = true
		a.fo, a.foErr = QueryRows(ctx, conn, "EXEC "+rdsFailoverProc)
	}
	if noRightError(a.haErr) || noRightError(a.foErr) {
		if r, err := QueryRows(ctx, conn, "SELECT SUSER_SNAME() AS login"); err == nil && len(r) == 1 {
			a.login = propText(r[0]["login"])
		}
	}
	return a
}

// rdsHAMode is the mode the first procedure answered ("" when none): the column high_availability, or a row's one
// column under another name.
func rdsHAMode(rows []collect.Row) string {
	if len(rows) == 0 {
		return ""
	}
	if v, ok := rows[0]["high_availability"]; ok {
		return propText(v)
	}
	if len(rows[0]) == 1 {
		for _, v := range rows[0] {
			return propText(v)
		}
	}
	return ""
}

// rdsHAAsksFailover says whether rds_failover_time is to be called: the mode was read and is not Single-AZ.
func rdsHAAsksFailover(rows []collect.Row, err error) bool {
	mode := rdsHAMode(rows)
	return err == nil && mode != "" && !strings.EqualFold(mode, rdsSingleAZ)
}

// rdsNotGranted is the note of a refused procedure: the GRANT line its master user runs.
func rdsNotGranted(proc, login string) string {
	who := "[<the monitoring login>]"
	if login != "" {
		who = quoteName(login)
	}
	return "not granted: GRANT EXECUTE ON " + proc + " TO " + who + "; (the master user may grant it)"
}

// rdsServerTime shows a time the procedure read from the server's error log.
func rdsServerTime(v any) string {
	if t, ok := v.(time.Time); ok {
		return t.Format("2006-01-02 15:04:05")
	}
	return propText(v)
}

// rdsHAProps adds the two rows to p and returns the partial rows of an unexpected error.
func rdsHAProps(p *propList, a rdsHAAnswer) []collect.Row {
	const grp, haLabel, foLabel = "Server", "High availability (Amazon RDS)", "Last failover (Amazon RDS)"
	var partial []collect.Row
	fail := func(source string, err error) string {
		partial = append(partial, collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
		return "not read: " + err.Error()
	}
	mode := rdsHAMode(a.ha)
	switch {
	case a.haErr != nil && noRightError(a.haErr):
		p.add("rds_high_availability", grp, haLabel, 155, nil, rdsNotGranted(rdsHAProc, a.login))
	case a.haErr != nil:
		p.add("rds_high_availability", grp, haLabel, 155, nil, fail(rdsHAProc, a.haErr))
	case mode == "":
		partial = append(partial, collect.Row{"kind": "collector_error", "source": rdsHAProc, "message": "the procedure returned no mode"})
		p.add("rds_high_availability", grp, haLabel, 155, nil, "not read: the procedure returned no mode")
	default:
		p.add("rds_high_availability", grp, haLabel, 155, mode, "")
	}

	switch {
	case mode == "":
		p.addUntracked("rds_last_failover", grp, foLabel, 156, nil, "not read: the high availability mode was not read")
	case strings.EqualFold(mode, rdsSingleAZ):
		p.addUntracked("rds_last_failover", grp, foLabel, 156, nil, "none: a Single-AZ instance has no failover (rds_failover_time answers on Multi-AZ only)")
	case !a.foAsked:
		p.addUntracked("rds_last_failover", grp, foLabel, 156, nil, "not read")
	case a.foErr != nil && noRightError(a.foErr):
		p.addUntracked("rds_last_failover", grp, foLabel, 156, nil, rdsNotGranted(rdsFailoverProc, a.login))
	case a.foErr != nil:
		p.addUntracked("rds_last_failover", grp, foLabel, 156, nil, fail(rdsFailoverProc, a.foErr))
	case len(a.fo) == 0:
		partial = append(partial, collect.Row{"kind": "collector_error", "source": rdsFailoverProc, "message": "the procedure returned no row"})
		p.addUntracked("rds_last_failover", grp, foLabel, 156, nil, "not read: the procedure returned no row")
	case a.fo[0]["recent_failover_time"] == nil:
		p.addUntracked("rds_last_failover", grp, foLabel, 156, nil, "none in the error logs since "+rdsServerTime(a.fo[0]["errorlog_available_from"])+" (the server's clock)")
	default:
		p.addUntracked("rds_last_failover", grp, foLabel, 156, rdsServerTime(a.fo[0]["recent_failover_time"]), "the server's clock, from its error logs")
	}
	return partial
}
