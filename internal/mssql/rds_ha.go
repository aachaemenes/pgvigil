package mssql

import (
	"context"
	"database/sql"
	"errors"
	"sort"
	"strings"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// Amazon RDS for SQL Server's high availability mode and its last failover, two rows of mssql_properties on an RDS
// instance, from the two procedures AWS gives for them:
//
//   - msdb.dbo.rds_get_high_availability_option: one value, 'Single-AZ', 'Multi-AZ (AlwaysOn)', 'Multi-AZ
//     (Mirroring)' or 'Multi-AZ (Block level replication)' (AWS's Multi-AZ page). A real RDS for SQL Server 2019
//     Standard instance in a single AZ answered one column high_availability = 'Single-AZ' (scripts/proof-mssql-rds.sh,
//     part S, 2026-11-14). Tracked: a change of mode is logged.
//   - msdb.dbo.rds_failover_time: errorlog_available_from and recent_failover_time, null when no failover is left in
//     the error logs (AWS's page 'Determining the last failover time'; it names no time zone, so the times are shown
//     as the procedure returns them). It refuses a single-AZ instance (Msg 50000 'This procedure can only be used on
//     Multi-AZ RDS Instance.', read on the same instance), so it is asked only when the mode was read and is not
//     Single-AZ. Shown, not tracked. Its Multi-AZ answer is not proven on a live instance: the reading follows AWS's
//     page and a stub of its shape (TestRDSHALive).
//
// A real answer of 'none' (a Single-AZ instance, no failover in the logs) is the value 'none', never a missing value:
// the page counts a missing value as not read, and the store keeps the last value read over a missing one.
//
// The monitoring login needs EXECUTE on each (Msg 229 naming the procedure without it), which the master user may
// grant in msdb. The right is optional: without it the row says 'not granted: <the USE msdb; GRANT lines>' and the
// run stays ok. A refusal by the failover procedure itself (Msg 50000) is said and the run stays ok; any other error
// is 'not read: <the error>' and the run partial.

const (
	rdsHAName       = "rds_get_high_availability_option"
	rdsFailoverName = "rds_failover_time"
	rdsSingleAZ     = "Single-AZ"
	rdsTimeWords    = "as the procedure returns it; AWS names no time zone"
)

// rdsHAAnswer is what the two procedures answered: their rows or their errors (foAsked: the failover procedure was
// called), and the login's user name in msdb for the GRANT lines ("" when not read).
type rdsHAAnswer struct {
	ha      []collect.Row
	haErr   error
	fo      []collect.Row
	foErr   error
	foAsked bool
	user    string
}

// readRDSHA calls the two procedures as the monitoring login.
func readRDSHA(ctx context.Context, conn *sql.Conn) rdsHAAnswer {
	var a rdsHAAnswer
	a.ha, a.haErr = QueryRows(ctx, conn, "EXEC msdb.dbo."+rdsHAName)
	if rdsHAAsksFailover(a.ha, a.haErr) {
		a.foAsked = true
		a.fo, a.foErr = QueryRows(ctx, conn, "EXEC msdb.dbo."+rdsFailoverName)
	}
	if rdsRefused(a.haErr, rdsHAName) || rdsRefused(a.foErr, rdsFailoverName) {
		// GRANT takes the user in msdb, which may be named otherwise than the login
		if r, err := QueryRows(ctx, conn, "SELECT name FROM msdb.sys.database_principals WHERE sid = SUSER_SID()"); err == nil && len(r) == 1 {
			a.user = propText(r[0]["name"])
		}
	}
	return a
}

// rdsRefused says whether err is the server's EXECUTE refusal of this procedure (Msg 229 naming it). Another
// permission error (from an object inside the procedure) is not: its message is shown instead.
func rdsRefused(err error, proc string) bool {
	var me mssqldb.Error
	return errors.As(err, &me) && me.Number == 229 && strings.Contains(me.Message, "'"+proc+"'")
}

// rdsMessage is the server's message of an error, or the error's text.
func rdsMessage(err error) string {
	var me mssqldb.Error
	if errors.As(err, &me) && me.Message != "" {
		return me.Message
	}
	return err.Error()
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

// rdsGrant is the lines the master user runs for the procedures: in msdb, to the login's user there.
func rdsGrant(user string, procs ...string) string {
	who := "[<the monitoring login's user in msdb>]"
	if user != "" {
		who = quoteName(user)
	}
	var b strings.Builder
	b.WriteString("USE msdb;")
	for _, p := range procs {
		b.WriteString(" GRANT EXECUTE ON dbo." + p + " TO " + who + ";")
	}
	return b.String()
}

// rdsServerTime shows a time the procedure returned: QueryRows hands datetime and datetime2 over as zone-less text
// (2020-05-05T18:57:51.89), datetimeoffset as a time.Time in UTC.
func rdsServerTime(v any) string {
	switch x := v.(type) {
	case time.Time:
		return x.Format("2006-01-02 15:04:05") + " UTC"
	case string:
		for _, layout := range []string{"2006-01-02T15:04:05.9999999", "2006-01-02 15:04:05.9999999"} {
			if t, err := time.Parse(layout, x); err == nil {
				return t.Format("2006-01-02 15:04:05")
			}
		}
	}
	return propText(v)
}

func rdsColumns(r collect.Row) string {
	names := make([]string, 0, len(r))
	for k := range r {
		names = append(names, k)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// rdsHAProps adds the two rows to p and returns the partial rows of an unexpected answer.
func rdsHAProps(p *propList, a rdsHAAnswer) []collect.Row {
	const grp, haLabel, foLabel = "Server", "High availability (Amazon RDS)", "Last failover (Amazon RDS)"
	var partial []collect.Row
	fail := func(proc, msg string) string {
		partial = append(partial, collect.Row{"kind": "collector_error", "source": "msdb.dbo." + proc, "message": msg})
		return "not read: " + msg
	}
	mode := rdsHAMode(a.ha)
	haRefused := rdsRefused(a.haErr, rdsHAName)
	switch {
	case haRefused:
		p.add("rds_high_availability", grp, haLabel, 155, nil, "not granted: "+rdsGrant(a.user, rdsHAName, rdsFailoverName)+
			" (the master user may grant them; the second is for the last failover on a Multi-AZ instance)")
	case a.haErr != nil:
		p.add("rds_high_availability", grp, haLabel, 155, nil, fail(rdsHAName, rdsMessage(a.haErr)))
	case mode == "":
		p.add("rds_high_availability", grp, haLabel, 155, nil, fail(rdsHAName, "the procedure returned no mode"))
	default:
		p.add("rds_high_availability", grp, haLabel, 155, mode, "")
	}

	fo := func(value any, note string) { p.addUntracked("rds_last_failover", grp, foLabel, 156, value, note) }
	switch {
	case haRefused:
		fo(nil, "not read: the high availability mode was not granted (the row above names the GRANT lines)")
	case mode == "":
		fo(nil, "not read: the high availability mode was not read")
	case strings.EqualFold(mode, rdsSingleAZ):
		fo("none", "a Single-AZ instance has no failover (rds_failover_time answers on Multi-AZ only)")
	case !a.foAsked:
		fo(nil, "not read: the failover time was not asked")
	case rdsRefused(a.foErr, rdsFailoverName):
		fo(nil, "not granted: "+rdsGrant(a.user, rdsFailoverName)+" (the master user may grant it)")
	case mssqlErrNumber(a.foErr) == 50000:
		fo(nil, "refused by the procedure: "+rdsMessage(a.foErr))
	case a.foErr != nil:
		fo(nil, fail(rdsFailoverName, rdsMessage(a.foErr)))
	case len(a.fo) == 0:
		fo(nil, fail(rdsFailoverName, "the procedure returned no row"))
	default:
		r := a.fo[0]
		recent, okRecent := r["recent_failover_time"]
		from, okFrom := r["errorlog_available_from"]
		switch {
		case !okRecent || !okFrom:
			fo(nil, fail(rdsFailoverName, "the answer lacks recent_failover_time or errorlog_available_from (columns: "+rdsColumns(r)+")"))
		case recent == nil:
			fo("none", "no failover in the error logs since "+rdsServerTime(from)+" ("+rdsTimeWords+")")
		default:
			fo(rdsServerTime(recent), "the most recent failover in the error logs ("+rdsTimeWords+")")
		}
	}
	return partial
}
