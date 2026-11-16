package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/golang-sql/sqlexp"
	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// blitzCollector is mssql_blitz (B20-2): the stored weekly sp_Blitz. sp_Blitz is the SQL Server First Responder Kit's
// (MIT, Copyright (c) Brent Ozar Unlimited); pgvigil never installs or copies it: it is called where the DBA installed
// it (the instance's setting names the database, master by default) when the monitoring login may EXECUTE it. The
// collection ticks hourly, and a run goes ahead only when the repository says it is due (0273's mssql_blitz_due: the
// instance's switch, else the site default - off unless an admin turns it on - and the weekly slot in the site's
// zone), so the collector's restarts at an inventory change never run it twice in a week.
//
// The call is EXEC [db].[dbo].[sp_Blitz] @CheckServerInfo = 1, @CheckUserDatabaseObjects = 0 (D4: no per-database
// object checks) under the site's timeout, never with a parameter that writes or sends (@Output..., @EmailRecipients).
// Its version first, with @VersionCheckMode = 1 (sp_Blitz sets @Version and @VersionDate and returns at once). The
// server's messages are read through the driver's message queue (sqlexp), so one that comes without a result set is
// kept, and each run is stored with its outcome:
//   - the findings set alone: 'done';
//   - the set with an error of severity 11 or more (a check sp_Blitz could not run: no EXECUTE on one of the kit's
//     other procedures, a divide by zero inside it - even as sa): 'done with messages', the set and the messages kept;
//   - no set, and only messages below severity 11: 'refused' with them (without VIEW SERVER STATE sp_Blitz says so at
//     severity 0 and returns);
//   - no set, and an error: 'failed' with it; no set and no message: 'failed';
//   - past its timeout: 'timed out' (sp_Blitz is stopped; the rows read so far are dropped).
//
// Not installed, no EXECUTE, off and not due are skips with their words (no run stored, the collection's note says
// why); a stored run of any outcome counts for its week.
//
// Rights: EXECUTE on sp_Blitz; VIEW SERVER STATE (without it sp_Blitz refuses); sp_Blitz reads more with VIEW ANY
// DEFINITION and CONNECT ANY DATABASE, and runs the kit's other procedures it finds (EXECUTE on them, or a kept 229).
// Not yet on Azure SQL Database (there sp_Blitz lives in the user database and a three-part call is refused).
type blitzCollector struct{}

func init() { Register(blitzCollector{}) }

func (blitzCollector) Name() string                   { return Prefix + "blitz" }
func (blitzCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: the site's timeout for sp_Blitz's own statement is at most blitzTimeoutMax; the run's frame a little more.
func (blitzCollector) Timeout() time.Duration { return blitzTimeoutMax + 2*time.Minute }

func (blitzCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not yet on Azure SQL Database (sp_Blitz lives in the user database there and a three-part call is refused)"
	}
	return true, ""
}

const (
	blitzTimeoutMax = 1800 * time.Second // 0273's check on mssql_blitz_site.timeout_s
	blitzRowsMax    = 5000               // a run's findings kept at most (sp_Blitz returns a few dozen to a few hundred)
	blitzMsgsMax    = 50                 // a run's server messages kept at most
	blitzTextMax    = 4000               // characters of a Details cell or a message (sp_Blitz's Details is nvarchar(4000))
	blitzKitURL     = "https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit"
)

// Run is the read without the repository's plan: RunOnce calls RunPlanned (PlanCollector); a run asked for without a
// plan is not run.
func (blitzCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, fmt.Errorf("the weekly sp_Blitz runs only when the repository says it is due: %w", collect.ErrSkip)
}

// RunPlanned asks the repository whether the run is due, checks where sp_Blitz is and that the login may run it, then
// runs it.
func (blitzCollector) RunPlanned(ctx context.Context, conn *sql.Conn, _ Info, plan func(context.Context) (repo.BlitzPlan, error)) ([]collect.Row, error) {
	p, err := plan(ctx)
	if err != nil {
		return nil, fmt.Errorf("asking the repository whether the weekly sp_Blitz is due: %w", err)
	}
	if p.State != "due" {
		return nil, fmt.Errorf("%s: %w", p.Why, collect.ErrSkip)
	}
	db := p.ProcDB
	if db == "" {
		db = "master"
	}
	timeout := time.Duration(p.TimeoutS) * time.Second
	if timeout <= 0 || timeout > blitzTimeoutMax {
		timeout = blitzTimeoutMax
	}
	obj := bracket(db) + ".[dbo].[sp_Blitz]"
	// the database and whether the login may enter it first: a three-part name in a database the login has no user in
	// (or one not online) is Msg 916, an error, never a NULL (review-22 bzcoll S2: RDS keeps sp_Blitz in a user database)
	var dbID, access sql.NullInt64
	var dbState sql.NullString
	var login string
	if err := conn.QueryRowContext(ctx, `SELECT DB_ID(@db), HAS_DBACCESS(@db), (SELECT d.state_desc FROM sys.databases AS d WHERE d.name = @db), SUSER_SNAME()`,
		sql.Named("db", db)).Scan(&dbID, &access, &dbState, &login); err != nil {
		return nil, fmt.Errorf("reading where sp_Blitz is: %w", err)
	}
	switch {
	case !dbID.Valid:
		return nil, fmt.Errorf("no database %s on this server (the instance's sp_Blitz database is set on its Findings tab): %w", db, collect.ErrSkip)
	case !access.Valid || access.Int64 != 1:
		st := ""
		if dbState.Valid && dbState.String != "ONLINE" {
			st = ": it is " + dbState.String
		}
		return nil, fmt.Errorf("the login %s has no access to the database %s, where sp_Blitz is looked for (no user there, or the database is not online%s): %w",
			login, bracket(db), st, collect.ErrSkip)
	}
	var objID sql.NullInt64
	var canExec int
	if err := conn.QueryRowContext(ctx, `SELECT OBJECT_ID(@obj, 'P'), ISNULL(HAS_PERMS_BY_NAME(@obj, N'OBJECT', N'EXECUTE'), 0)`,
		sql.Named("obj", obj)).Scan(&objID, &canExec); err != nil {
		return nil, fmt.Errorf("reading where sp_Blitz is: %w", err)
	}
	switch {
	case !objID.Valid:
		return nil, fmt.Errorf("sp_Blitz is not in %s.[dbo] as the login %s sees it (a login without EXECUTE or VIEW DEFINITION on it does not see it; pgvigil never installs it: %s): %w",
			bracket(db), login, blitzKitURL, collect.ErrSkip)
	case canExec != 1:
		return nil, fmt.Errorf("no EXECUTE on %s for the login %s (GRANT EXECUTE ON dbo.sp_Blitz in %s to its user there): %w", obj, login, bracket(db), collect.ErrSkip)
	}
	// which databases sp_Blitz's per-database checks will read: its own @db_perms read (fn_my_permissions(<db>,
	// 'DATABASE') for SELECT), run in its database as it runs it; a database without that SELECT is in its #SkipChecks
	dbAll, dbSel, permErr := blitzDBPerms(ctx, conn, db)
	var ver, verDate sql.NullString
	verErr := conn.QueryRowContext(ctx, `DECLARE @v varchar(30), @d datetime;
EXEC `+obj+` @Version = @v OUTPUT, @VersionDate = @d OUTPUT, @VersionCheckMode = 1;
SELECT @v, CONVERT(char(8), @d, 112);`).Scan(&ver, &verDate)

	rctx, rcancel := context.WithTimeout(ctx, timeout)
	defer rcancel()
	t0 := time.Now()
	rd, err := readBlitz(rctx, conn, "EXEC "+obj+" @CheckServerInfo = 1, @CheckUserDatabaseObjects = 0;")
	secs := math.Round(time.Since(t0).Seconds()*10) / 10
	if ctx.Err() != nil { // the collector's shutdown or the run's own frame: nothing is stored
		return nil, ctx.Err()
	}
	timedOut := errors.Is(rctx.Err(), context.DeadlineExceeded)
	if verErr != nil {
		rd.note("sp_Blitz's version was not read (an sp_Blitz without @VersionCheckMode?): " + verErr.Error())
	}
	if rd.cut {
		rd.note(fmt.Sprintf("the run's findings were cut at %d rows", blitzRowsMax))
	}
	switch {
	case permErr != nil:
		rd.note("which databases sp_Blitz's per-database checks read was not read: " + permErr.Error())
	case dbSel < dbAll:
		rd.noteFirst(blitzDBSkipNote(dbAll, dbSel, login))
	}
	outcome, why := blitzOutcome(rd, err, timedOut, int(timeout/time.Second))
	run := collect.Row{"kind": "run", "outcome": outcome, "seconds": secs, "login": login, "proc_db": db,
		"frk_version": nullStr(ver), "frk_version_date": nullStr(verDate), "error": nil}
	if why != "" {
		run["error"] = why
	}
	rows := []collect.Row{run}
	for i, m := range rd.msgs {
		rows = append(rows, collect.Row{"kind": "msg", "n": i + 1, "number": m.number, "severity": m.class, "state": m.state,
			"line": m.line, "proc": m.proc, "message": m.text})
	}
	if outcome == "done" || outcome == "done with messages" {
		for i, f := range rd.rows {
			rows = append(rows, collect.Row{"kind": "finding", "n": i + 1, "check_id": f.checkID, "priority": f.priority,
				"findings_group": f.group, "finding": f.finding, "database_name": f.db, "url": f.url, "message": f.details})
		}
	} else {
		// the run's note: RunOnce stores the collection as partial with it
		rows = append(rows, collect.Row{"kind": "collector_error", "source": "sp_Blitz", "message": why})
	}
	return rows, nil
}

// blitzOutcome is a run's outcome and, when it did not finish with its findings, why.
func blitzOutcome(rd blitzRead, err error, timedOut bool, timeoutS int) (outcome, why string) {
	switch {
	case timedOut:
		// the words name no cause: a lost connection can leave the read waiting to the deadline (bzcoll S1)
		return "timed out", fmt.Sprintf("no end of sp_Blitz within %d s, the site's timeout (still running, or the connection was lost): it was stopped", timeoutS)
	case err != nil:
		// readBlitz keeps every server error as a message: an error here is the connection's or the driver's, and a
		// set it cut is never stored as findings (bzcoll S1 / N2)
		if rd.set {
			return "failed", "the read of sp_Blitz's result ended early: " + err.Error()
		}
		return "failed", err.Error()
	case !rd.set && rd.errs > 0:
		return "failed", rd.joined(11)
	case !rd.set && rd.server() > 0:
		return "refused", rd.joined(0)
	case !rd.set:
		return "failed", "sp_Blitz returned no result set and no message"
	case rd.errs > 0:
		return "done with messages", ""
	}
	return "done", ""
}

// blitzRead is what one sp_Blitz call returned: its findings set (the first set with sp_Blitz's columns), the server's
// messages in their order, how many of them are errors (severity 11 or more).
type blitzRead struct {
	set  bool
	rows []blitzFinding
	msgs []blitzMsg
	errs int
	cut  bool
}

type blitzFinding struct {
	checkID, priority                any // int64 or nil
	group, finding, db, url, details any // string or nil
}

type blitzMsg struct {
	number     int32
	class      uint8
	state      uint8
	line       int32
	proc, text string
}

// readBlitz runs stmt and reads every message and result set through the driver's message queue: an error inside the
// procedure does not end the read, and a severity-0 message (RAISERROR ... 0, or PRINT) is kept.
func readBlitz(ctx context.Context, conn *sql.Conn, stmt string) (blitzRead, error) {
	var rd blitzRead
	retmsg := &sqlexp.ReturnMessage{}
	rows, err := conn.QueryContext(ctx, stmt, retmsg)
	if err != nil {
		return rd, err
	}
	defer func() { _ = rows.Close() }()
	for active := true; active; {
		switch m := retmsg.Message(ctx).(type) {
		case sqlexp.MsgNotice:
			rd.add(m.Message)
		case sqlexp.MsgError:
			// a server error (an mssqldb.Error) is kept and the read goes on; any other is the connection's own: the
			// driver queues nothing after it, so the read ends here, never at the deadline (bzcoll S1)
			var me mssqldb.Error
			if !errors.As(m.Error, &me) {
				return rd, m.Error
			}
			rd.add(m.Error)
		case sqlexp.MsgNext:
			if err := rd.readSet(rows); err != nil {
				return rd, err
			}
		case sqlexp.MsgNextResultSet:
			active = rows.NextResultSet()
		}
	}
	if err := ctx.Err(); err != nil {
		return rd, err
	}
	// a server error came as a message above; anything else here is the connection's own
	var me mssqldb.Error
	if err := rows.Err(); err != nil && !errors.As(err, &me) {
		return rd, err
	}
	return rd, nil
}

// add keeps one server message (a notice or an error); its severity decides whether it counts as an error.
func (rd *blitzRead) add(v any) {
	var me mssqldb.Error
	switch x := v.(type) {
	case mssqldb.Error:
		me = x
	case error:
		if !errors.As(x, &me) {
			me = mssqldb.Error{Message: x.Error(), Class: 16}
		}
	case fmt.Stringer:
		me = mssqldb.Error{Message: x.String()}
	default:
		return
	}
	if me.Class >= 11 {
		rd.errs++
	}
	m := blitzMsg{number: me.Number, class: me.Class, state: me.State, line: me.LineNo, proc: me.ProcName, text: cutText(strings.TrimSpace(me.Message))}
	if len(rd.msgs) >= blitzMsgsMax && me.Class >= 11 {
		// the list is full: an error takes the place of the oldest notice, so a run's errors are kept over its notices
		for i, k := range rd.msgs {
			if k.class < 11 && k.proc != "pgvigil" {
				rd.msgs = append(rd.msgs[:i], rd.msgs[i+1:]...)
				break
			}
		}
	}
	if len(rd.msgs) < blitzMsgsMax {
		rd.msgs = append(rd.msgs, m)
	}
}

// server: how many of the kept messages are the server's (pgvigil's own notes left out: bzcoll N1).
func (rd blitzRead) server() int {
	n := 0
	for _, m := range rd.msgs {
		if m.proc != "pgvigil" {
			n++
		}
	}
	return n
}

// note is pgvigil's own line among a run's messages (number 0, severity 0).
func (rd *blitzRead) note(s string) {
	if len(rd.msgs) < blitzMsgsMax {
		rd.msgs = append(rd.msgs, blitzMsg{proc: "pgvigil", text: cutText(s)})
	}
}

// noteFirst is pgvigil's own line at the head of a run's messages, kept over the cap: a full list gives up its newest
// notice of the server's (else its newest message) for it.
func (rd *blitzRead) noteFirst(s string) {
	rd.msgs = append([]blitzMsg{{proc: "pgvigil", text: cutText(s)}}, rd.msgs...)
	if len(rd.msgs) <= blitzMsgsMax {
		return
	}
	drop := len(rd.msgs) - 1
	for i := len(rd.msgs) - 1; i > 0; i-- {
		if rd.msgs[i].class < 11 && rd.msgs[i].proc != "pgvigil" {
			drop = i
			break
		}
	}
	rd.msgs = append(rd.msgs[:drop], rd.msgs[drop+1:]...)
}

// blitzDBPermsSQL is sp_Blitz 8.34's own @db_perms read (its lines 'Databases where we don't have read permissions'):
// every database, and those where fn_my_permissions(<db>, 'DATABASE') lists SELECT. Read from sp_Blitz's database,
// that function lists only what a server right implies (b20-b0diag3: a SELECT granted to the login's user inside a
// database does not count; diag5: SELECT ALL USER SECURABLES does not either), so the default grants read none.
const blitzDBPermsSQL = `SELECT (SELECT COUNT(*) FROM sys.databases),
  (SELECT COUNT(DISTINCT d.database_id) FROM sys.databases AS d CROSS APPLY fn_my_permissions(d.name, N'DATABASE') AS fmp
    WHERE fmp.permission_name = N'SELECT')`

// blitzDBPerms runs blitzDBPermsSQL in the database db (sp_executesql there), as sp_Blitz runs its own read.
func blitzDBPerms(ctx context.Context, conn *sql.Conn, db string) (all, sel int, err error) {
	err = conn.QueryRowContext(ctx, "EXEC "+bracket(db)+".sys.sp_executesql @stmt", sql.Named("stmt", blitzDBPermsSQL)).Scan(&all, &sel)
	return all, sel, err
}

// blitzDBSkipNote is the run's note when sp_Blitz's per-database checks leave databases out (the lead 05:0x: the
// page never stays silent about it).
func blitzDBSkipNote(all, sel int, login string) string {
	what := fmt.Sprintf("ran on no database (0 of %d)", all)
	if sel > 0 {
		what = fmt.Sprintf("left out %d of %d databases", all-sel, all)
	}
	return "sp_Blitz's per-database checks " + what + ": sp_Blitz reads which databases it may check with " +
		"fn_my_permissions(<database>, 'DATABASE') from its own database, and that read lists SELECT for the login " + login +
		" only through a server right - a SELECT granted inside a database does not count, and SELECT ALL USER SECURABLES " +
		"does not change it; only sysadmin does, which pgvigil never asks for. The Checks tab judges the database " +
		"options on its own (auto-close, auto-shrink, page verify, the statistics options, the owner, the last good DBCC CHECKDB)."
}

// joined is the text of the messages at severity min or more, in their order.
func (rd blitzRead) joined(min uint8) string {
	var out []string
	for _, m := range rd.msgs {
		if m.class >= min && m.proc != "pgvigil" {
			s := m.text
			if m.class >= 11 {
				s = fmt.Sprintf("Msg %d, severity %d: %s", m.number, m.class, m.text)
			}
			out = append(out, s)
		}
	}
	return cutText(strings.Join(out, "; "))
}

// blitzColumns: the columns of sp_Blitz's findings set (its TABLE output), in lower case.
var blitzColumns = []string{"priority", "findingsgroup", "finding", "databasename", "url", "details", "checkid"}

// readSet reads one result set: the first with sp_Blitz's columns is the findings, any other is read and dropped.
func (rd *blitzRead) readSet(rows *sql.Rows) error {
	cols, err := rows.Columns()
	if err != nil {
		return err
	}
	idx := map[string]int{}
	for i, c := range cols {
		idx[strings.ToLower(c)] = i
	}
	take := !rd.set
	for _, k := range blitzColumns {
		if _, ok := idx[k]; !ok {
			take = false
		}
	}
	if take {
		rd.set = true
	}
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	for rows.Next() {
		if err := rows.Scan(ptrs...); err != nil {
			return err
		}
		if !take {
			continue
		}
		if len(rd.rows) >= blitzRowsMax {
			rd.cut = true
			continue
		}
		rd.rows = append(rd.rows, blitzFinding{
			checkID: blitzInt(vals[idx["checkid"]]), priority: blitzInt(vals[idx["priority"]]),
			group: blitzText(vals[idx["findingsgroup"]]), finding: blitzText(vals[idx["finding"]]),
			db: blitzText(vals[idx["databasename"]]), url: blitzText(vals[idx["url"]]), details: blitzText(vals[idx["details"]]),
		})
	}
	// a server error is a message (above); any other ended the set: the connection's own (bzcoll S1)
	var me mssqldb.Error
	if err := rows.Err(); err != nil && !errors.As(err, &me) {
		return err
	}
	return nil
}

// blitzInt: an integer cell (TINYINT Priority, INT CheckID) as int64, else nil.
func blitzInt(v any) any {
	switch x := v.(type) {
	case int64:
		return x
	case int32:
		return int64(x)
	case int16:
		return int64(x)
	case uint8:
		return int64(x)
	}
	return nil
}

// blitzText: a text cell as a string cut to blitzTextMax characters, else nil.
func blitzText(v any) any {
	switch x := v.(type) {
	case string:
		return cutText(x)
	case []byte:
		return cutText(string(x))
	}
	return nil
}

func cutText(s string) string {
	if r := []rune(s); len(r) > blitzTextMax {
		return string(r[:blitzTextMax])
	}
	return s
}

func nullStr(s sql.NullString) any {
	if !s.Valid {
		return nil
	}
	return strings.TrimSpace(s.String)
}

// ChecksJudged lists the sp_Blitz CheckIDs the Checks tab (mssql_checks, hourly) already judges by its own rules: the
// weekly section marks each such finding and links to that tab (review-19's overlap line). The server options'
// defaults (sp_Blitz's #ConfigurationDefaults, CheckIDs 1001 and up) and the rules that name an sp_Blitz check;
// TestChecksJudgedCoversTheRules reads the package's source so a rule added there cannot be missed here.
func ChecksJudged() []int {
	seen := map[int]bool{}
	var out []int
	add := func(id int) {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	for _, d := range configDefaults {
		add(d.checkID)
	}
	for _, id := range judgedRules {
		add(id)
	}
	sort.Ints(out)
	return out
}

// judgedRules: the CheckIDs the checks' rules name ("sp_Blitz <n>" in checks.go, dboptions.go, agentalerts.go and the
// other readers, and offByDefault's database options).
var judgedRules = []int{12, 13, 14, 15, 16, 17, 20, 30, 31, 50, 59, 61, 68, 69, 73, 74, 90, 96, 98, 100, 102, 116, 126, 128,
	131, 132, 133, 134, 135, 136, 138, 140, 141, 144, 188, 190, 213, 217, 219, 230, 231, 257, 272, 275, 1020}
