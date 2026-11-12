package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// jobsCollector is mssql_jobs: SQL Server Agent from msdb. Per job its owner, enabled flag, schedules and next
// run, the last outcome with its duration and message, and whether it runs now; per step the last outcome and
// duration; and the job history (msdb.dbo.sysjobhistory) read forward from a cursor on its instance_id, so a row
// is read once. msdb's integer dates and times are turned into datetimes on the server and then into UTC.
//
// Each job row also carries the job as one T-SQL script (agentScript, task 154): what DBA Dash keeps as a job's DDL.
// The repository stores it with every version of the job's definition, so two versions compare as text.
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
  CASE WHEN act.start_execution_date IS NOT NULL AND act.stop_execution_date IS NULL THEN act.last_executed_step_id END AS running_after_step,
  j.start_step_id, j.notify_level_email, CAST(oe.name AS nvarchar(128)) AS notify_email_operator,
  j.notify_level_page, CAST(op.name AS nvarchar(128)) AS notify_page_operator, j.notify_level_eventlog, j.delete_level
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysoperators oe ON oe.id = j.notify_email_operator_id
LEFT JOIN msdb.dbo.sysoperators op ON op.id = j.notify_page_operator_id
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

// jobStepsSQL: one row per step. The command is read for the job's definition (its versions, task 110) and masked
// before it leaves the collector (collect.MaskJobText): a step's command can hold a password.
var jobStepsSQL = `SELECT 'step' AS kind, st.job_id, st.step_id, CAST(st.step_name AS nvarchar(128)) AS step_name,
  CAST(LEFT(st.command, 8000) AS nvarchar(max)) AS command, CAST(DATALENGTH(st.command) / 2 AS int) AS command_chars, st.flags, st.on_success_action, st.on_success_step_id, st.on_fail_action, st.on_fail_step_id,
  st.retry_attempts, st.retry_interval, CAST(st.output_file_name AS nvarchar(260)) AS output_file, CAST(px.name AS nvarchar(128)) AS proxy,
  CAST(st.subsystem AS nvarchar(40)) AS subsystem, CAST(st.database_name AS nvarchar(128)) AS database_name,
  st.last_run_outcome AS last_outcome,
  ` + utcText(agentDateTime("st.last_run_date", "st.last_run_time")) + ` AS last_run_utc,
  CASE WHEN st.last_run_date >= 19000101 THEN ` + agentSeconds("st.last_run_duration") + ` END AS last_duration_s
FROM msdb.dbo.sysjobsteps st
LEFT JOIN msdb.dbo.sysproxies px ON px.proxy_id = st.proxy_id
ORDER BY st.job_id, st.step_id`

// jobSchedulesSQL: one row per schedule a job has, with msdb's own terms; the collector puts them in words
// (scheduleWords). schedule_key is the schedule's name and number: two schedules of one job may share a name.
var jobSchedulesSQL = `SELECT 'schedule' AS kind, x.job_id, s.schedule_id, CAST(s.name AS nvarchar(128)) AS schedule_name,
  CAST(s.name AS nvarchar(128)) + N' #' + CAST(s.schedule_id AS nvarchar(12)) AS schedule_key, CAST(s.enabled AS int) AS enabled,
  s.freq_type, s.freq_interval, s.freq_subday_type, s.freq_subday_interval, s.freq_relative_interval, s.freq_recurrence_factor,
  s.active_start_date, s.active_end_date, s.active_start_time, s.active_end_time
FROM msdb.dbo.sysjobschedules x
JOIN msdb.dbo.sysschedules s ON s.schedule_id = x.schedule_id
ORDER BY x.job_id, s.name, s.schedule_id`

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

// jobTables are the msdb tables the read touches: a login without SELECT on any one of them is skipped with that table
// named, never failed on a permission error halfway (Amazon RDS's master user can grant three of them).
var jobTables = []string{"sysjobs", "sysjobhistory", "sysjobsteps", "sysjobschedules", "sysschedules", "syscategories", "sysjobactivity", "sysjobservers", "sysoperators", "sysproxies", "syssessions"}

// RunFrom reads the jobs, their steps and the history past the cursor.
func (jobsCollector) RunFrom(ctx context.Context, conn *sql.Conn, info Info, cursor SeqCursorFunc) ([]collect.Row, error) {
	for _, t := range jobTables {
		if err := msdbReadable(ctx, conn, t); err != nil {
			if info.Kind == KindRDS && errors.Is(err, collect.ErrSkip) {
				return nil, fmt.Errorf("the login has no access to msdb.dbo.%s, which the Amazon RDS master user cannot grant (it may grant sysjobs, sysjobhistory and sysjobactivity only): %w", t, collect.ErrSkip)
			}
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
	for _, st := range steps {
		if c, ok := st["command"].(string); ok {
			st["command"] = collect.MaskJobText(c)
		}
	}
	schedules, err := QueryRows(ctx, conn, jobSchedulesSQL)
	if err != nil {
		return nil, err
	}
	for _, sc := range schedules {
		sc["runs"] = scheduleWords(sc)
	}
	// the script of each job, from the masked steps and the schedules' own terms
	for _, j := range rows {
		id, _ := j["job_id"].(string)
		j["script"], j["script_format"] = agentScript(j, rowsOfJob(steps, id), rowsOfJob(schedules, id)), AgentScriptFormat
	}
	for _, st := range steps {
		st["on_success"] = stepAction(st["on_success_action"], st["on_success_step_id"])
		st["on_fail"] = stepAction(st["on_fail_action"], st["on_fail_step_id"])
		for _, k := range []string{"on_success_action", "on_success_step_id", "on_fail_action", "on_fail_step_id", "command_chars", "flags"} {
			delete(st, k)
		}
	}
	rows = append(rows, steps...)
	rows = append(rows, schedules...)
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

// AgentScriptFormat numbers the way agentScript writes a script: a change to the builder takes the next number, so
// the repository rewrites the newest version's script in place instead of storing a version of every job (0094).
const AgentScriptFormat = 1

// rowsOfJob is the rows of one job, in the order they were read (steps by step_id, schedules by name).
func rowsOfJob(rows []collect.Row, jobID string) []collect.Row {
	var out []collect.Row
	for _, r := range rows {
		if id, _ := r["job_id"].(string); id == jobID {
			out = append(out, r)
		}
	}
	return out
}

// tsqlN is a text as a T-SQL Unicode literal.
func tsqlN(v any) string {
	s, _ := v.(string)
	return "N'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// oneLine is a name on one line (a comment line of the script must not break).
var oneLine = strings.NewReplacer("\r", " ", "\n", " ")

// agentScript is one job as the T-SQL that makes it again: sp_add_job, a sp_add_jobstep per step, a
// sp_add_jobschedule per schedule and sp_add_jobserver, one parameter per line so that two versions compare line by
// line. It is built from what the collector read and nothing else: a step's command is the masked one (a password
// stays <masked> in the script), a command longer than the 8,000 characters read says so, and nothing that moves
// without a change to the job (ids, dates of creation and change, the last run) is in it. A schedule is written as
// the job's own (sp_add_jobschedule), also when msdb shares it between jobs.
func agentScript(job collect.Row, steps, schedules []collect.Row) string {
	var b strings.Builder
	name := tsqlN(job["name"])
	n := func(v any) int64 { x, _ := num(v); return x }
	text := func(v any) (string, bool) { s, ok := v.(string); return s, ok && s != "" }
	// call writes one procedure call: its parameters one per line, the last one closed by the semicolon
	call := func(proc string, params []string) {
		b.WriteString("EXEC msdb.dbo." + proc + "\n")
		for i, p := range params {
			end := ","
			if i == len(params)-1 {
				end = ";"
			}
			b.WriteString("    " + p + end + "\n")
		}
	}
	jobName, _ := job["name"].(string)
	b.WriteString("-- SQL Server Agent job: " + oneLine.Replace(jobName) + "\n")
	if c, ok := text(job["category"]); ok && c != "[Uncategorized (Local)]" {
		b.WriteString("IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = " + tsqlN(c) + " AND category_class = 1)\n")
		b.WriteString("    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = " + tsqlN(c) + ";\n")
	}
	p := []string{"@job_name = " + name, fmt.Sprintf("@enabled = %d", n(job["enabled"]))}
	if d, ok := text(job["description"]); ok {
		p = append(p, "@description = "+tsqlN(d))
	}
	if c, ok := text(job["category"]); ok {
		p = append(p, "@category_name = "+tsqlN(c))
	}
	if o, ok := text(job["owner"]); ok {
		p = append(p, "@owner_login_name = "+tsqlN(o))
	}
	p = append(p, fmt.Sprintf("@notify_level_eventlog = %d", n(job["notify_level_eventlog"])),
		fmt.Sprintf("@notify_level_email = %d", n(job["notify_level_email"])),
		fmt.Sprintf("@notify_level_page = %d", n(job["notify_level_page"])),
		fmt.Sprintf("@delete_level = %d", n(job["delete_level"])))
	if o, ok := text(job["notify_email_operator"]); ok {
		p = append(p, "@notify_email_operator_name = "+tsqlN(o))
	}
	if o, ok := text(job["notify_page_operator"]); ok {
		p = append(p, "@notify_page_operator_name = "+tsqlN(o))
	}
	call("sp_add_job", p)
	for _, st := range steps {
		stepName, _ := st["step_name"].(string)
		fmt.Fprintf(&b, "\n-- step %d: %s\n", n(st["step_id"]), oneLine.Replace(stepName))
		// the length of the command as stored (masking lengthens the text read, never what was cut)
		if n(st["command_chars"]) > 8000 {
			fmt.Fprintf(&b, "-- the command is %d characters long: the first 8,000 are below\n", n(st["command_chars"]))
		}
		p := []string{"@job_name = " + name, fmt.Sprintf("@step_id = %d", n(st["step_id"])), "@step_name = " + tsqlN(st["step_name"]),
			"@subsystem = " + tsqlN(st["subsystem"])}
		if d, ok := text(st["database_name"]); ok {
			p = append(p, "@database_name = "+tsqlN(d))
		}
		p = append(p, "@command = "+tsqlN(st["command"]),
			fmt.Sprintf("@on_success_action = %d", n(st["on_success_action"])), fmt.Sprintf("@on_success_step_id = %d", n(st["on_success_step_id"])),
			fmt.Sprintf("@on_fail_action = %d", n(st["on_fail_action"])), fmt.Sprintf("@on_fail_step_id = %d", n(st["on_fail_step_id"])),
			fmt.Sprintf("@retry_attempts = %d", n(st["retry_attempts"])), fmt.Sprintf("@retry_interval = %d", n(st["retry_interval"])),
			fmt.Sprintf("@flags = %d", n(st["flags"])))
		if o, ok := text(st["output_file"]); ok {
			p = append(p, "@output_file_name = "+tsqlN(o))
		}
		if x, ok := text(st["proxy"]); ok {
			p = append(p, "@proxy_name = "+tsqlN(x))
		}
		call("sp_add_jobstep", p)
	}
	if s := n(job["start_step_id"]); s > 1 {
		b.WriteString("\n")
		call("sp_update_job", []string{"@job_name = " + name, fmt.Sprintf("@start_step_id = %d", s)})
	}
	for _, sc := range schedules {
		words, _ := sc["runs"].(string)
		b.WriteString("\n-- schedule: " + words + "\n")
		call("sp_add_jobschedule", []string{"@job_name = " + name, "@name = " + tsqlN(sc["schedule_name"]),
			fmt.Sprintf("@enabled = %d", n(sc["enabled"])),
			fmt.Sprintf("@freq_type = %d", n(sc["freq_type"])), fmt.Sprintf("@freq_interval = %d", n(sc["freq_interval"])),
			fmt.Sprintf("@freq_subday_type = %d", n(sc["freq_subday_type"])), fmt.Sprintf("@freq_subday_interval = %d", n(sc["freq_subday_interval"])),
			fmt.Sprintf("@freq_relative_interval = %d", n(sc["freq_relative_interval"])),
			fmt.Sprintf("@freq_recurrence_factor = %d", n(sc["freq_recurrence_factor"])),
			fmt.Sprintf("@active_start_date = %d", n(sc["active_start_date"])), fmt.Sprintf("@active_end_date = %d", n(sc["active_end_date"])),
			fmt.Sprintf("@active_start_time = %d", n(sc["active_start_time"])), fmt.Sprintf("@active_end_time = %d", n(sc["active_end_time"]))})
	}
	// the job's own server as its target: msdb lists it (sysjobservers) for every job the Agent runs
	if job["last_outcome"] != nil {
		b.WriteString("\n")
		call("sp_add_jobserver", []string{"@job_name = " + name, "@server_name = N'(local)'"})
	}
	return b.String()
}

// num is a whole number QueryRows returned (msdb's tinyint, smallint and int columns), false for NULL.
func num(v any) (int64, bool) {
	switch x := v.(type) {
	case int64:
		return x, true
	case int32:
		return int64(x), true
	case int16:
		return int64(x), true
	case int:
		return int64(x), true
	case uint8:
		return int64(x), true
	}
	return 0, false
}

// stepAction is what a step does when it ends (sysjobsteps.on_success_action / on_fail_action) in words.
func stepAction(action, step any) string {
	a, ok := num(action)
	if !ok {
		return ""
	}
	switch a {
	case 1:
		return "quit reporting success"
	case 2:
		return "quit reporting failure"
	case 3:
		return "go to the next step"
	case 4:
		n, _ := num(step)
		return fmt.Sprintf("go to step %d", n)
	}
	return fmt.Sprintf("action %d", a)
}

// agentClock is msdb's hhmmss time as hh:mm (hh:mm:ss when it has seconds).
func agentClock(t int64) string {
	if t%100 != 0 {
		return fmt.Sprintf("%02d:%02d:%02d", t/10000, t/100%100, t%100)
	}
	return fmt.Sprintf("%02d:%02d", t/10000, t/100%100)
}

var weekdays = []string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}

// scheduleWords puts one msdb.dbo.sysschedules row in words, on the server's clock: "every day every 15 minutes
// between 00:00 and 23:59:59", "every week on Monday, Friday at 02:10", "every month on the last weekday at 01:00".
func scheduleWords(r map[string]any) string {
	ft, _ := num(r["freq_type"])
	fi, _ := num(r["freq_interval"])
	rf, _ := num(r["freq_recurrence_factor"])
	every := func(n int64, one, many string) string {
		if n <= 1 {
			return "every " + one
		}
		return fmt.Sprintf("every %d %s", n, many)
	}
	var day string
	switch ft {
	case 1:
		d, _ := num(r["active_start_date"])
		t, _ := num(r["active_start_time"])
		return fmt.Sprintf("once on %04d-%02d-%02d at %s", d/10000, d/100%100, d%100, agentClock(t))
	case 4:
		day = every(fi, "day", "days")
	case 8:
		var on []string
		for i, w := range weekdays {
			if fi&(1<<i) != 0 {
				on = append(on, w)
			}
		}
		day = every(rf, "week", "weeks") + " on " + strings.Join(on, ", ")
	case 16:
		day = every(rf, "month", "months") + fmt.Sprintf(" on day %d", fi)
	case 32:
		rel, _ := num(r["freq_relative_interval"])
		which := map[int64]string{1: "first", 2: "second", 4: "third", 8: "fourth", 16: "last"}[rel]
		what := map[int64]string{8: "day", 9: "weekday", 10: "weekend day"}[fi]
		if fi >= 1 && fi <= 7 {
			what = weekdays[fi-1]
		}
		day = every(rf, "month", "months") + " on the " + which + " " + what
	case 64:
		return "when SQL Server Agent starts"
	case 128:
		return "when the computer is idle"
	default:
		return fmt.Sprintf("freq_type %d", ft)
	}
	st, _ := num(r["freq_subday_type"])
	si, _ := num(r["freq_subday_interval"])
	from, _ := num(r["active_start_time"])
	to, _ := num(r["active_end_time"])
	unit := map[int64]string{2: "second", 4: "minute", 8: "hour"}[st]
	if unit == "" {
		return day + " at " + agentClock(from)
	}
	return day + " " + every(si, unit, unit+"s") + " between " + agentClock(from) + " and " + agentClock(to)
}

// traceFlagsCollector is mssql_traceflags: the trace flags switched on (DBCC TRACESTATUS(-1): any login may run
// it), every hour. It is the one read of the flags: the repository keeps them as last read and each flag's added /
// removed history (migration 0094, import_mssql_traceflags), and the day-one checks' 'traceflags' area is judged
// here from the same rows (checks.go's traceFlagRows: what each global flag does and whether it belongs on, the
// advised flags that are off) and stored by the same import. The 'read' row says the command ran: a server with no
// flag on returns no row, and that is a read too.
type traceFlagsCollector struct{}

func init() { Register(traceFlagsCollector{}) }

func (traceFlagsCollector) Name() string                   { return Prefix + "traceflags" }
func (traceFlagsCollector) DefaultInterval() time.Duration { return time.Hour }
func (traceFlagsCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "Azure SQL Database has no server-wide trace flags to read"
	}
	return true, ""
}

// traceFlagsSQL is checks.go's

func (traceFlagsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	flags, err := QueryRows(ctx, conn, traceFlagsSQL)
	if err != nil {
		return nil, err
	}
	return traceFlagPayload(flags, info), nil
}

// traceFlagPayload is one read's payload: the 'read' row, a 'flag' row per flag that is on ({trace_flag, global,
// session}; a global one with its verdict: status, severity, rule, explain), an 'advised' row per advised flag that
// is off (its verdict: status, severity, rule, explain), the checks' 'area' row and their findings.
func traceFlagPayload(flags []collect.Row, info Info) []collect.Row {
	on := make([]collect.Row, 0, len(flags))
	for _, f := range flags {
		// the command's columns: TraceFlag, Status, Global, Session; a flag listed with Status 0 is off
		if st, ok := num(f["Status"]); ok && st == 0 {
			continue
		}
		on = append(on, f)
	}
	verdicts, findings := traceFlagRows(on, info)
	byFlag := map[int64]collect.Row{}
	out := []collect.Row{{"kind": "read"}}
	for _, v := range verdicts {
		f, _ := v["flag"].(int64)
		if v["is_on"] == 1 {
			byFlag[f] = v
			continue
		}
		out = append(out, collect.Row{"kind": "advised", "trace_flag": f, "status": v["status"], "severity": v["severity"], "rule": v["rule"],
			"explain": v["explain"]})
	}
	for _, f := range on {
		r := collect.Row{"kind": "flag", "trace_flag": f["TraceFlag"], "global": f["Global"], "session": f["Session"]}
		if tf, ok := num(f["TraceFlag"]); ok && f["Global"] == int64(1) {
			if v, ok := byFlag[tf]; ok {
				r["status"], r["severity"], r["rule"], r["explain"] = v["status"], v["severity"], v["rule"], v["explain"]
			}
		}
		out = append(out, r)
	}
	out = append(out, areaRow(AreaTraceFlags, true, ""))
	for _, fd := range findings {
		out = append(out, fd.row())
	}
	return out
}
