package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// jobsCollector is mssql_jobs: SQL Server Agent from msdb. Per job its owner, enabled flag, schedules and next
// run, the last outcome with its duration and message, and whether it runs now; per step the last outcome and
// duration; and the job history (msdb.dbo.sysjobhistory) read forward from a cursor on its instance_id, so a row
// is read once. msdb's integer dates and times are turned into datetimes on the server and then into UTC.
//
// The running-jobs filter (the newest row of msdb.dbo.syssessions) and the history read's shape (past a cursor on
// instance_id, run_status 4 "in progress" left out) are ported from DBA Dash 4.24.1, DBADash/SQL/SQLRunningJobs.sql
// and SQLJobHistory.sql (MIT, Copyright 2022 Trimble, Inc.).
type jobsCollector struct{}

func init() { Register(jobsCollector{}) }

func (jobsCollector) Name() string                   { return Prefix + "jobs" }
func (jobsCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (jobsCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "Azure SQL Database has no SQL Server Agent"
	case !info.MsdbAccess:
		return false, "the login has no access to msdb (a user there with db_datareader)"
	}
	return true, ""
}

// msdbReadable asks whether the login may read one table of msdb. Info.MsdbAccess only says the login can enter
// msdb, which msdb's guest user allows to every login; the right to a table is asked per table, and a login
// without it is skipped with the missing right instead of failing on a permission error.
func msdbReadable(ctx context.Context, conn *sql.Conn, table string) error {
	var ok sql.NullInt64
	if err := conn.QueryRowContext(ctx, "SELECT HAS_PERMS_BY_NAME(N'msdb.dbo."+table+"', 'OBJECT', 'SELECT')").Scan(&ok); err != nil {
		return err
	}
	if ok.Int64 != 1 {
		return fmt.Errorf("the login has no access to msdb.dbo.%s (a user in msdb with db_datareader is the missing right): %w", table, collect.ErrSkip)
	}
	return nil
}

// SeqCursorFunc reads how far a source of this instance was read (false: never).
type SeqCursorFunc func(ctx context.Context, source string) (last int64, ok bool, err error)

// CursorCollector is what a collector adds when it reads on from where its last read ended. RunOnce calls RunFrom
// in place of Run when the collector has it; the cursor itself is advanced by the collection's import function,
// in the transaction that stores the rows.
type CursorCollector interface {
	RunFrom(ctx context.Context, conn *sql.Conn, info Info, cursor SeqCursorFunc) ([]collect.Row, error)
}

const (
	// JobsCursorSource names the sysjobhistory cursor: the instance_id of the newest row read.
	JobsCursorSource = "jobs"
	// JobsMarkSource names the cursor row's mark: a checksum of what that row was. msdb's history numbering starts
	// again when msdb is replaced (a restore, a new server under the old name); the mark tells "the row at the
	// cursor is still the row that was read" from "another row has that number now".
	JobsMarkSource = "jobs_mark"
	// jobHistoryDays is the kept window: a first read, and a read after a long stop, go back this far and no further.
	jobHistoryDays = 7
	// jobHistoryBatch bounds one statement; a run reads batch after batch until it has caught up.
	jobHistoryBatch = 5000
	// jobHistoryBatches bounds one run; a longer backlog is read on by the next runs.
	jobHistoryBatches = 20
	// jobHistoryOverlap is how far behind the cursor a read starts: an identity value is allocated before its row
	// is visible, so a row just below the newest one read can appear late. The import stores a row once.
	jobHistoryOverlap = 50
)

// agentDateTime is the datetime of msdb's integer date (yyyymmdd) and time (hhmmss) pair, NULL for a date of 0.
func agentDateTime(d, t string) string {
	return "CASE WHEN " + d + " >= 19000101 THEN DATETIMEFROMPARTS(" + d + " / 10000, " + d + " / 100 % 100, " + d + " % 100, " +
		t + " / 10000, " + t + " / 100 % 100, " + t + " % 100, 0) END"
}

// agentSeconds is the seconds of msdb's integer duration (hhmmss, the hours unbounded).
func agentSeconds(d string) string {
	return "(" + d + " / 10000 * 3600 + " + d + " / 100 % 100 * 60 + " + d + " % 100)"
}

// jobsSQL: one row per job. SQL Server 2016 SP1 and later. The next run is sysjobactivity's of the Agent's current
// session (exact), else the earliest of sysjobschedules (refreshed by the Agent every 20 minutes).
var jobsSQL = `SELECT 'job' AS kind, j.job_id, CAST(j.name AS nvarchar(128)) AS name, CAST(j.enabled AS int) AS enabled,
  CAST(LEFT(j.description, 1000) AS nvarchar(1000)) AS description,
  CAST(c.name AS nvarchar(128)) AS category, CAST(SUSER_SNAME(j.owner_sid) AS nvarchar(128)) AS owner,
  ` + utcText("j.date_created") + ` AS created_utc, ` + utcText("j.date_modified") + ` AS modified_utc,
  ISNULL(sch.schedules, 0) AS schedules, ISNULL(sch.enabled_schedules, 0) AS enabled_schedules,
  CAST(LEFT(sch.schedule_names, 1000) AS nvarchar(1000)) AS schedule_names,
  ` + utcText("COALESCE(act.next_scheduled_run_date, sch.next_run)") + ` AS next_run_utc,
  js.last_run_outcome AS last_outcome,
  ` + utcText(agentDateTime("js.last_run_date", "js.last_run_time")) + ` AS last_run_utc,
  CASE WHEN js.last_run_date >= 19000101 THEN ` + agentSeconds("js.last_run_duration") + ` END AS last_duration_s,
  CAST(LEFT(js.last_outcome_message, 4000) AS nvarchar(4000)) AS last_message,
  CASE WHEN act.start_execution_date IS NOT NULL AND act.stop_execution_date IS NULL THEN ` + utcText("act.start_execution_date") + ` END AS running_since_utc,
  CASE WHEN act.start_execution_date IS NOT NULL AND act.stop_execution_date IS NULL THEN act.last_executed_step_id END AS running_after_step
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
LEFT JOIN msdb.dbo.sysjobservers js ON js.job_id = j.job_id AND js.server_id = 0
OUTER APPLY (SELECT TOP (1) a.start_execution_date, a.stop_execution_date, a.next_scheduled_run_date, a.last_executed_step_id
               FROM msdb.dbo.sysjobactivity a
              WHERE a.job_id = j.job_id AND a.session_id = (SELECT MAX(s.session_id) FROM msdb.dbo.syssessions s)
              ORDER BY a.run_requested_date DESC) act
OUTER APPLY (SELECT COUNT(*) AS schedules, SUM(CAST(s.enabled AS int)) AS enabled_schedules,
                    MIN(CASE WHEN s.enabled = 1 THEN ` + agentDateTime("x.next_run_date", "x.next_run_time") + ` END) AS next_run,
                    STUFF((SELECT N', ' + s2.name FROM msdb.dbo.sysjobschedules x2 JOIN msdb.dbo.sysschedules s2 ON s2.schedule_id = x2.schedule_id
                            WHERE x2.job_id = j.job_id ORDER BY s2.name FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') AS schedule_names
               FROM msdb.dbo.sysjobschedules x JOIN msdb.dbo.sysschedules s ON s.schedule_id = x.schedule_id
              WHERE x.job_id = j.job_id) sch
ORDER BY j.name`

// jobStepsSQL: one row per step. The command text is not read: a step's command can hold a password.
var jobStepsSQL = `SELECT 'step' AS kind, st.job_id, st.step_id, CAST(st.step_name AS nvarchar(128)) AS step_name,
  CAST(st.subsystem AS nvarchar(40)) AS subsystem, CAST(st.database_name AS nvarchar(128)) AS database_name,
  st.last_run_outcome AS last_outcome,
  ` + utcText(agentDateTime("st.last_run_date", "st.last_run_time")) + ` AS last_run_utc,
  CASE WHEN st.last_run_date >= 19000101 THEN ` + agentSeconds("st.last_run_duration") + ` END AS last_duration_s
FROM msdb.dbo.sysjobsteps st
ORDER BY st.job_id, st.step_id`

// jobHistoryMark is the mark of a sysjobhistory row (h).
const jobHistoryMark = `CAST(CHECKSUM(CAST(h.job_id AS nvarchar(36)), h.step_id, h.run_date, h.run_time) AS bigint)`

// jobHistoryMarkSQL reads the mark of the row at @p1 (no row: msdb no longer has it).
const jobHistoryMarkSQL = `SELECT ` + jobHistoryMark + ` AS mark FROM msdb.dbo.sysjobhistory h WHERE h.instance_id = @p1`

// jobHistorySQL reads sysjobhistory past @p1, inside the kept window, oldest first (a cursor read) or newest first
// (a read without a cursor: the newest batch of the window). Step 0 is the job's own outcome row.
func jobHistorySQL(forward bool) string {
	order := "DESC"
	if forward {
		order = "ASC"
	}
	return fmt.Sprintf(`SELECT TOP (%d) 'run' AS kind, h.instance_id AS history_id, h.job_id, CAST(j.name AS nvarchar(128)) AS job_name,
  h.step_id, CAST(h.step_name AS nvarchar(128)) AS step_name, h.run_status, h.run_date, h.run_time,
  `+jobHistoryMark+` AS mark,
  %s AS duration_s,
  %s AS run_utc,
  h.sql_message_id, h.sql_severity, h.retries_attempted AS retries,
  CAST(LEFT(h.message, 4000) AS nvarchar(4000)) AS message
FROM msdb.dbo.sysjobhistory h
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.instance_id > @p1 AND h.run_status <> 4
  AND h.run_date >= CAST(CONVERT(char(8), DATEADD(day, -%d, GETDATE()), 112) AS int)
ORDER BY h.instance_id %s`, jobHistoryBatch, agentSeconds("h.run_duration"), utcText(agentDateTime("h.run_date", "h.run_time")), jobHistoryDays, order)
}

// Run is the read without a cursor (a RunOnce that does not know CursorCollector): the newest batch of the kept
// window every time. The import stores a history row once (by its number, job, step and msdb's own date and time,
// not by the converted instant), so nothing is doubled; it is only read again.
func (c jobsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	return c.RunFrom(ctx, conn, info, nil)
}

// RunFrom reads the jobs, their steps and the history past the cursor.
func (jobsCollector) RunFrom(ctx context.Context, conn *sql.Conn, _ Info, cursor SeqCursorFunc) ([]collect.Row, error) {
	for _, t := range []string{"sysjobs", "sysjobhistory"} {
		if err := msdbReadable(ctx, conn, t); err != nil {
			return nil, err
		}
	}
	rows, err := QueryRows(ctx, conn, jobsSQL)
	if err != nil {
		return nil, err
	}
	steps, err := QueryRows(ctx, conn, jobStepsSQL)
	if err != nil {
		return nil, err
	}
	rows = append(rows, steps...)
	if cursor == nil {
		runs, err := QueryRows(ctx, conn, jobHistorySQL(false), int64(0))
		if err != nil {
			return nil, err
		}
		return append(append(rows, runs...), collect.Row{"kind": "read", "cursor": false}), nil
	}
	last, haveLast, err := cursor(ctx, JobsCursorSource)
	if err != nil {
		return nil, fmt.Errorf("jobs cursor: %w", err)
	}
	mark, haveMark, err := cursor(ctx, JobsMarkSource)
	if err != nil {
		return nil, fmt.Errorf("jobs cursor mark: %w", err)
	}
	same := false
	if haveLast && haveMark && last > 0 {
		var now sql.NullInt64
		switch err := conn.QueryRowContext(ctx, jobHistoryMarkSQL, last).Scan(&now); {
		case err == sql.ErrNoRows:
		case err != nil:
			return nil, err
		default:
			same = now.Valid && now.Int64 == mark
		}
	}
	from := jobsReadFrom(last, same)
	next, nextMark := last, mark
	if !same {
		next, nextMark = 0, 0
	}
	for range jobHistoryBatches {
		runs, err := QueryRows(ctx, conn, jobHistorySQL(true), from)
		if err != nil {
			return nil, err
		}
		rows = append(rows, runs...)
		from, next, nextMark = jobsAdvance(from, next, nextMark, runs)
		if len(runs) < jobHistoryBatch {
			break
		}
	}
	return append(rows, collect.Row{"kind": "read", "cursor": true},
		collect.Row{"kind": "cursor", "last_history_id": next, "mark": nextMark}), nil
}

// jobsReadFrom is where a read starts: a little behind the cursor while the row at the cursor is still the row
// that was read (same); from the start of the kept window when it is not - msdb was replaced, or the row was
// purged while the collector was stopped. A read from the start loses nothing: the import stores a row once.
func jobsReadFrom(last int64, same bool) int64 {
	if !same || last <= jobHistoryOverlap {
		return 0
	}
	return last - jobHistoryOverlap
}

// jobsAdvance moves the read position and the cursor past one batch: the newest row read and its mark.
func jobsAdvance(from, next, nextMark int64, runs []collect.Row) (int64, int64, int64) {
	for _, r := range runs {
		id, ok := r["history_id"].(int64)
		if !ok {
			continue
		}
		if id > from {
			from = id
		}
		if id >= next {
			next = id
			nextMark, _ = r["mark"].(int64)
		}
	}
	return from, next, nextMark
}
