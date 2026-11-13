package mssql

// The actions door of the SQL Server engine: KILL one session, start or stop one SQL Server Agent job. It is the
// only place pgvigil sends a statement that changes anything on a monitored SQL Server, and it never does so with
// the read login.
//
// Two logins take part, each with the least it needs:
//   - the instance's read login (VIEW SERVER STATE, db_datareader in msdb) reads the target: the session with its
//     login, host, program, open transaction count and last statement, or the job with its name, owner and state.
//     The actions login cannot read another login's session, so the check runs here;
//   - the actions login (actions_dsn; ALTER ANY CONNECTION for a kill, SQLAgentOperatorRole in msdb for the jobs,
//     never sysadmin, never CONTROL SERVER, never the read login) sends the one statement and nothing else.
//
// An action is two steps. Preview reads the target and returns what the user is shown; Execute gets those values
// back with the user's reason and sends the statement only when the target is still the one shown: a session id
// whose login time or login differs now belongs to another session and is refused, a job whose name differs is
// refused. Both connections are open and the actions login is checked before that last read, so the read and the
// statement are two round trips apart on two open connections; a session id reused inside that window would be
// missed, which is the residue of keeping the actions login at ALTER ANY CONNECTION alone.
//
// Off unless the instance has an actions_dsn AND its actions: list names the action.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// ActionKind is one action of the door.
type ActionKind string

// The actions an instance's allow list may name.
const (
	ActionKill     ActionKind = "kill"
	ActionJobStart ActionKind = "job_start"
	ActionJobStop  ActionKind = "job_stop"
)

// ActionKinds lists every action, in the order the documentation gives them.
var ActionKinds = []ActionKind{ActionKill, ActionJobStart, ActionJobStop}

// ValidAction says whether s names an action (the config's validation of an actions: list).
func ValidAction(s string) bool {
	for _, k := range ActionKinds {
		if string(k) == s {
			return true
		}
	}
	return false
}

// The three outcomes of an attempt, the words pgvigil.actions_log keeps.
const (
	OutcomeDone    = "done"    // the statement was sent and the server accepted it
	OutcomeRefused = "refused" // a check said no; nothing was sent
	OutcomeFailed  = "failed"  // the checks passed and the server refused or failed the statement
)

// Reason limits: a reason is typed by a person and kept in the audit table.
const (
	MinActionReason = 5
	MaxActionReason = 500
)

// Door is what an action needs on one SQL Server instance (resolved connection strings).
type Door struct {
	Monitor string // the instance's read login (dsn)
	Actions string // the actions login (actions_dsn); "" = none
	// Configured says actions_dsn is set in the config, so an empty Actions means it did not resolve.
	Configured bool
	// Allow is the instance's actions: list; an action not named there is off.
	Allow []string
}

// Allows says whether the instance's allow list names the action.
func (d Door) Allows(k ActionKind) bool {
	for _, a := range d.Allow {
		if a == string(k) {
			return true
		}
	}
	return false
}

// Off is the reason the door cannot do k on the instance, or "" when it can.
func (d Door) Off(instance string, k ActionKind) string {
	switch {
	case d.Actions == "" && d.Configured:
		return fmt.Sprintf("instance %s: actions_dsn is configured but resolved to an empty string (an unset variable or an unreadable file)", instance)
	case d.Actions == "":
		return fmt.Sprintf("instance %s has no actions_dsn: no action runs there (docs/sqlserver-actions.md has the login to create)", instance)
	case !d.Allows(k):
		return fmt.Sprintf("instance %s: %s is not on the instance's actions: list", instance, k)
	}
	return ""
}

// Target is what the read login saw of a session or a job: what the user is shown before the confirm step, and
// what the confirm step carries back.
type Target struct {
	// a session (kill)
	SessionID int    `json:"session_id,omitempty"`
	LoginTime string `json:"login_time,omitempty"` // UTC, RFC 3339: with the session id it names one session
	Login     string `json:"login,omitempty"`
	Host      string `json:"host,omitempty"`
	Program   string `json:"program,omitempty"`
	Database  string `json:"database,omitempty"`
	Status    string `json:"status,omitempty"`
	OpenTran  int    `json:"open_transaction_count,omitempty"`
	Statement string `json:"statement,omitempty"` // the session's last statement (its input buffer)
	// a job (job_start, job_stop)
	JobID    string `json:"job_id,omitempty"`
	JobName  string `json:"job_name,omitempty"`
	JobOwner string `json:"job_owner,omitempty"`
	JobState string `json:"job_state,omitempty"` // running | idle
	// set by the read, never sent back
	userProcess bool
	readerSPID  int
	readerLogin string
}

// ActionRequest is one attempt: the action, the target's identity as the user was shown it, and who asks.
type ActionRequest struct {
	Instance  string
	Kind      ActionKind
	SessionID int    // kill
	LoginTime string // kill: of the session shown
	Login     string // kill: of the session shown
	JobID     string // job_start, job_stop
	JobName   string // of the job shown
	Reason    string
	User      string // the UI login
	Client    string // the client address
}

// ActionResult is how an attempt ended, with the statement (sent, or that would have been sent), the server's own
// message for it and what the check saw of the target.
type ActionResult struct {
	Outcome       string `json:"outcome"`
	Detail        string `json:"detail"`
	Statement     string `json:"statement,omitempty"`
	ServerMessage string `json:"server_message,omitempty"`
	Target        Target `json:"-"`
}

func refusedAction(format string, a ...any) ActionResult {
	return ActionResult{Outcome: OutcomeRefused, Detail: fmt.Sprintf(format, a...)}
}

var jobIDForm = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

// ValidateAction checks the request's own shape (no connection needed).
func ValidateAction(r ActionRequest) error {
	switch r.Kind {
	case ActionKill:
		if r.SessionID <= 0 || r.SessionID > 32767 {
			return errors.New("session_id must be a session id")
		}
		if _, err := time.Parse(time.RFC3339Nano, r.LoginTime); err != nil {
			return errors.New("login_time of the session shown is missing or not a timestamp")
		}
		if strings.TrimSpace(r.Login) == "" {
			return errors.New("the login of the session shown is required")
		}
	case ActionJobStart, ActionJobStop:
		if !jobIDForm.MatchString(r.JobID) {
			return errors.New("job_id must be a job's id (a GUID)")
		}
		if strings.TrimSpace(r.JobName) == "" {
			return errors.New("the name of the job shown is required")
		}
	default:
		return fmt.Errorf("unknown action %q", r.Kind)
	}
	switch {
	case len([]rune(strings.TrimSpace(r.Reason))) < MinActionReason:
		return fmt.Errorf("a reason of at least %d characters is required", MinActionReason)
	case len([]rune(r.Reason)) > MaxActionReason:
		return fmt.Errorf("the reason is longer than %d characters", MaxActionReason)
	case strings.ContainsRune(r.Reason, 0):
		return errors.New("the reason holds a NUL character")
	case strings.TrimSpace(r.User) == "":
		return errors.New("no UI user: actions need the UI login")
	}
	return nil
}

// Statement is the one statement an action sends. A session id and a job id are the only values in it: the id is
// a number, the job id a GUID whose form ValidateAction checked.
func Statement(k ActionKind, sessionID int, jobID string) string {
	switch k {
	case ActionKill:
		return fmt.Sprintf("KILL %d", sessionID)
	case ActionJobStart:
		return fmt.Sprintf("EXEC msdb.dbo.sp_start_job @job_id = '%s'", strings.ToUpper(jobID))
	case ActionJobStop:
		return fmt.Sprintf("EXEC msdb.dbo.sp_stop_job @job_id = '%s'", strings.ToUpper(jobID))
	}
	return ""
}

// withApp names the session on the SQL Server side (the URL and the ADO forms; an odbc: string is left as it is).
func withApp(dsn, app string) string {
	l := strings.ToLower(dsn)
	switch {
	case strings.HasPrefix(l, "odbc:"):
		return dsn
	case strings.HasPrefix(l, "sqlserver://"):
		if strings.Contains(l, "app+name=") || strings.Contains(l, "app%20name=") || strings.Contains(l, "app name=") {
			return dsn
		}
		if strings.Contains(dsn, "?") {
			return dsn + "&app+name=" + app
		}
		return dsn + "?app+name=" + app
	}
	if strings.Contains(l, "app name") || strings.Contains(l, "application name") {
		return dsn
	}
	return strings.TrimRight(dsn, "; ") + ";app name=" + app
}

// openAction opens one short-lived connection that cannot hang behind a lock.
func openAction(ctx context.Context, dsn, app string) (*sql.DB, *sql.Conn, error) {
	db, err := mssqlopen.Open(withApp(dsn, app))
	if err != nil {
		return nil, nil, err
	}
	db.SetMaxOpenConns(1)
	conn, err := db.Conn(ctx)
	if err != nil {
		_ = db.Close()
		return nil, nil, err
	}
	if _, err := conn.ExecContext(ctx, sessionSetup); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, err
	}
	return db, conn, nil
}

// sessionSQL reads one session as the read login sees it. SQL Server 2016 SP1+. The login time is the server's
// local clock in the DMV: moved to UTC by the server's offset at the read.
const sessionSQL = `SELECT s.session_id, CAST(s.is_user_process AS int), ISNULL(s.login_name, ''), ISNULL(s.host_name, ''),
  ISNULL(s.program_name, ''), ISNULL(DB_NAME(s.database_id), ''), ISNULL(s.status, ''), CAST(s.open_transaction_count AS int),
  CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), s.login_time), 126) + 'Z',
  ISNULL(ib.event_info, ''), @@SPID, SUSER_SNAME()
FROM sys.dm_exec_sessions s
OUTER APPLY sys.dm_exec_input_buffer(s.session_id, NULL) ib
WHERE s.session_id = @p1`

// jobSQL reads one Agent job as the read login sees it (db_datareader in msdb). Running = the newest Agent
// session's activity row for the job has started and not stopped.
const jobSQL = `SELECT CAST(j.job_id AS nvarchar(36)), j.name, ISNULL(SUSER_SNAME(j.owner_sid), ''),
  CASE WHEN a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL THEN 'running' ELSE 'idle' END,
  @@SPID, SUSER_SNAME()
FROM msdb.dbo.sysjobs j
OUTER APPLY (SELECT TOP (1) ja.start_execution_date, ja.stop_execution_date
               FROM msdb.dbo.sysjobactivity ja
              WHERE ja.job_id = j.job_id AND ja.session_id = (SELECT MAX(ss.session_id) FROM msdb.dbo.syssessions ss)
              ORDER BY ja.start_execution_date DESC) a
WHERE j.job_id = CAST(@p1 AS uniqueidentifier)`

// serverSQL is readable by any login: the server's name and the time it started (tempdb is created at startup).
// Two logins that read the same pair reached the same server. The third value is the login itself.
const serverSQL2 = `SELECT ISNULL(@@SERVERNAME, ''), CONVERT(varchar(33), (SELECT create_date FROM sys.databases WHERE database_id = 2), 126), SUSER_SNAME()`

// actorSQL is what the actions login says about itself.
const actorSQL = `SELECT @@SPID, CAST(ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) AS int),
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'CONTROL SERVER'), 0) AS int)`

// errNoTarget: the session or the job is not there (any more).
var errNoTarget = errors.New("not found")

func readSession(ctx context.Context, mon *sql.Conn, sessionID int) (Target, error) {
	var t Target
	var user int
	err := mon.QueryRowContext(ctx, sessionSQL, sessionID).Scan(&t.SessionID, &user, &t.Login, &t.Host, &t.Program, &t.Database,
		&t.Status, &t.OpenTran, &t.LoginTime, &t.Statement, &t.readerSPID, &t.readerLogin)
	if errors.Is(err, sql.ErrNoRows) {
		return t, errNoTarget
	}
	t.userProcess = user == 1
	t.Host, t.Program = strings.TrimSpace(t.Host), strings.TrimSpace(t.Program)
	return t, err
}

func readJob(ctx context.Context, mon *sql.Conn, jobID string) (Target, error) {
	var t Target
	err := mon.QueryRowContext(ctx, jobSQL, jobID).Scan(&t.JobID, &t.JobName, &t.JobOwner, &t.JobState, &t.readerSPID, &t.readerLogin)
	if errors.Is(err, sql.ErrNoRows) {
		return t, errNoTarget
	}
	return t, err
}

// sessionRefusal is why a session the read login saw is never killed from the UI, or "" when it may be.
func sessionRefusal(t Target) string {
	switch {
	case !t.userProcess || t.SessionID <= 50:
		return fmt.Sprintf("session %d is a system session: only a user session is killed from the UI", t.SessionID)
	case t.SessionID == t.readerSPID:
		return fmt.Sprintf("session %d is pgvigil's own check session", t.SessionID)
	case strings.EqualFold(t.Login, t.readerLogin):
		return fmt.Sprintf("session %d belongs to pgvigil's own read login (%s): the collector's sessions are never killed from the UI", t.SessionID, t.Login)
	}
	return ""
}

// sameSession says whether the session read now is the one the user was shown: the same login time (to the
// millisecond the DMV keeps) and the same login.
func sameSession(now Target, shownLoginTime, shownLogin string) bool {
	a, err1 := time.Parse(time.RFC3339Nano, now.LoginTime)
	b, err2 := time.Parse(time.RFC3339Nano, shownLoginTime)
	return err1 == nil && err2 == nil && a.Equal(b) && strings.EqualFold(now.Login, shownLogin)
}

// Preview reads the target of an action through the read login: what the user is shown before the confirm step.
// why is the reason there is nothing to confirm (the door is off for the action, the target is gone, a session
// that is never killed); with why set the target holds whatever was read.
func Preview(ctx context.Context, d Door, instance string, k ActionKind, sessionID int, jobID string) (t Target, why string) {
	if off := d.Off(instance, k); off != "" {
		return t, off
	}
	if d.Monitor == "" {
		return t, fmt.Sprintf("instance %s: the read login's dsn resolved to an empty string", instance)
	}
	if k != ActionKill && !jobIDForm.MatchString(jobID) {
		return t, "job_id must be a job's id (a GUID)"
	}
	db, mon, err := openAction(ctx, d.Monitor, "pgvigil-actions-check")
	if err != nil {
		return t, fmt.Sprintf("the read login could not connect to read the target: %v", err)
	}
	defer func() { _ = mon.Close(); _ = db.Close() }()
	if k == ActionKill {
		t, err = readSession(ctx, mon, sessionID)
		switch {
		case errors.Is(err, errNoTarget):
			return t, fmt.Sprintf("session %d is not connected any more: nothing to kill", sessionID)
		case err != nil:
			return t, fmt.Sprintf("the read of session %d failed: %v", sessionID, err)
		}
		return t, sessionRefusal(t)
	}
	t, err = readJob(ctx, mon, jobID)
	switch {
	case errors.Is(err, errNoTarget):
		return t, fmt.Sprintf("job %s does not exist (any more)", jobID)
	case err != nil:
		return t, fmt.Sprintf("the read of job %s failed: %v", jobID, err)
	}
	return t, ""
}

// Execute runs the checks and, when they pass, sends the statement through the actions login. It never returns an
// error: every way out is a result the caller writes to the audit table. Refused = nothing was sent; failed = the
// statement was sent and the server refused it.
//
// The order keeps the time between the last look at the target and the statement as short as it can be: both
// connections are opened and the actions login is checked FIRST, the target is read and compared LAST, and the
// statement follows on the connection that is already open.
func Execute(ctx context.Context, d Door, r ActionRequest) ActionResult {
	if err := ValidateAction(r); err != nil {
		return refusedAction("%s", err.Error())
	}
	stmt := Statement(r.Kind, r.SessionID, r.JobID)
	// refuse keeps what the check read of the target only when that IS the target shown (t); a refusal before the
	// read, or because the id now belongs to another session, keeps the request's own values in the audit row
	refuse := func(t Target, format string, a ...any) ActionResult {
		res := refusedAction(format, a...)
		res.Statement, res.Target = stmt, t
		return res
	}
	if off := d.Off(r.Instance, r.Kind); off != "" {
		return refuse(Target{}, "%s", off)
	}
	if d.Monitor == "" {
		return refuse(Target{}, "instance %s: the read login's dsn resolved to an empty string", r.Instance)
	}

	// 1. the two connections, and the actions login: another login than the read one, on the same server, and
	// never one that may do everything. Whether it holds the right for THIS statement is the server's to say: a
	// login without ALTER ANY CONNECTION or outside SQLAgentOperatorRole gets the server's own error, kept as the
	// attempt's message
	mdb, mon, err := openAction(ctx, d.Monitor, "pgvigil-actions-check")
	if err != nil {
		return refuse(Target{}, "the read login could not connect to check the target: %v", err)
	}
	defer func() { _ = mon.Close(); _ = mdb.Close() }()
	adb, act, err := openAction(ctx, d.Actions, "pgvigil-actions")
	if err != nil {
		return refuse(Target{}, "the actions login could not connect: %v; nothing was sent", err)
	}
	defer func() { _ = act.Close(); _ = adb.Close() }()
	var monName, monStart, monLogin, actName, actStart, actLogin string
	var actSPID, sysadmin, control int
	if err := mon.QueryRowContext(ctx, serverSQL2).Scan(&monName, &monStart, &monLogin); err != nil {
		return refuse(Target{}, "the server check failed: %v", err)
	}
	if err := act.QueryRowContext(ctx, serverSQL2).Scan(&actName, &actStart, &actLogin); err != nil {
		return refuse(Target{}, "the actions login's server check failed: %v; nothing was sent", err)
	}
	if monName != actName || monStart != actStart {
		return refuse(Target{}, "actions_dsn reaches another server than the instance's dsn (%s started %s vs %s started %s): nothing was sent", actName, actStart, monName, monStart)
	}
	if err := act.QueryRowContext(ctx, actorSQL).Scan(&actSPID, &sysadmin, &control); err != nil {
		return refuse(Target{}, "the actions login's own check failed: %v; nothing was sent", err)
	}
	switch {
	case strings.EqualFold(actLogin, monLogin):
		return refuse(Target{}, "actions_dsn connects as the read login (%s): the actions login must be a login of its own", actLogin)
	case sysadmin == 1 || control == 1:
		return refuse(Target{}, "the actions login %s is sysadmin or holds CONTROL SERVER: pgvigil refuses it (docs/sqlserver-actions.md has the grants it needs, and no more)", actLogin)
	}

	// 2. the target as the read login sees it NOW, compared with the one shown
	var t Target
	if r.Kind == ActionKill {
		t, err = readSession(ctx, mon, r.SessionID)
		switch {
		case errors.Is(err, errNoTarget):
			return refuse(Target{}, "session %d is not connected any more: nothing to kill", r.SessionID)
		case err != nil:
			return refuse(Target{}, "the target check failed: %v", err)
		case !sameSession(t, r.LoginTime, r.Login):
			return refuse(Target{}, "session id %d now belongs to another session (login %s, logged in %s; the one shown was login %s, logged in %s): the session shown has ended and its id was reused",
				r.SessionID, t.Login, t.LoginTime, r.Login, r.LoginTime)
		}
		if why := sessionRefusal(t); why != "" {
			return refuse(t, "%s", why)
		}
		if r.SessionID == actSPID || strings.EqualFold(t.Login, actLogin) {
			return refuse(t, "session %d belongs to the actions login itself (%s)", r.SessionID, actLogin)
		}
	} else {
		t, err = readJob(ctx, mon, r.JobID)
		switch {
		case errors.Is(err, errNoTarget):
			return refuse(Target{}, "job %s does not exist (any more)", r.JobID)
		case err != nil:
			return refuse(Target{}, "the target check failed: %v", err)
		case t.JobName != r.JobName:
			return refuse(Target{}, "job %s is now named %q, not %q as shown: read the job again", r.JobID, t.JobName, r.JobName)
		}
	}

	// 3. the statement, at once, on the connection already open: a session id cannot be a parameter of KILL, so
	// every action sends its text as built from a number (checked above) or a GUID (its form checked by
	// ValidateAction); the audit keeps exactly this text
	if _, err = act.ExecContext(ctx, stmt); err != nil {
		msg := serverMessage(err)
		return ActionResult{Outcome: OutcomeFailed, Detail: fmt.Sprintf("the server refused %s: %s", stmt, msg), Statement: stmt, ServerMessage: msg, Target: t}
	}
	return ActionResult{Outcome: OutcomeDone, Detail: stmt + " sent", Statement: stmt,
		ServerMessage: "the server accepted the statement (it returns no message for it)", Target: t}
}

// serverMessage is the server's own text for an error, with its number where the driver gives one.
func serverMessage(err error) string {
	var me mssqldb.Error
	if errors.As(err, &me) {
		return fmt.Sprintf("Msg %d, Level %d, State %d: %s", me.Number, me.Class, me.State, me.Message)
	}
	return err.Error()
}

// ActionLogRow is one audit row as pgvigil.import_mssql_actions_log reads it.
type ActionLogRow struct {
	At            time.Time `json:"at"`
	Instance      string    `json:"instance_name"`
	UIUser        string    `json:"ui_user"`
	Client        string    `json:"client"`
	Action        string    `json:"action"`
	PID           *int      `json:"pid"`
	BackendStart  *string   `json:"backend_start"`
	TargetUser    string    `json:"target_user"`
	TargetApp     string    `json:"target_app"`
	TargetHost    string    `json:"target_host"`
	Target        string    `json:"target"`
	TargetID      string    `json:"target_id"`
	Reason        string    `json:"reason"`
	Outcome       string    `json:"outcome"`
	Detail        string    `json:"detail"`
	Statement     string    `json:"statement"`
	ServerMessage string    `json:"server_message"`
}

// ActionRow builds the audit row of an attempt. What the check read of the target wins over what the request
// said of it; a refusal before any read keeps the request's own values.
func ActionRow(at time.Time, r ActionRequest, res ActionResult) ActionLogRow {
	nul := func(s string) string { return strings.ReplaceAll(s, "\x00", "") } // jsonb refuses \u0000: the row must land
	reason := strings.TrimSpace(r.Reason)
	if reason == "" {
		reason = "(no reason given)"
	}
	if rs := []rune(reason); len(rs) > MaxActionReason {
		reason = string(rs[:MaxActionReason])
	}
	row := ActionLogRow{At: at, Instance: r.Instance, UIUser: nul(r.User), Client: nul(r.Client), Action: string(r.Kind),
		Reason: nul(reason), Outcome: res.Outcome, Detail: nul(res.Detail), Statement: nul(res.Statement), ServerMessage: nul(res.ServerMessage)}
	t := res.Target
	if r.Kind == ActionKill {
		pid := r.SessionID
		if pid < 0 || pid > 32767 {
			pid = 0 // a refused request with a number that is no session id: the row must still land (pid is an int)
		}
		row.PID = &pid
		lt := r.LoginTime
		if t.LoginTime != "" {
			lt = t.LoginTime
		}
		if ts, err := time.Parse(time.RFC3339Nano, lt); err == nil {
			v := ts.UTC().Format(time.RFC3339Nano)
			row.BackendStart = &v
		}
		row.TargetUser, row.TargetApp, row.TargetHost = nul(first(t.Login, r.Login)), nul(t.Program), nul(t.Host)
		return row
	}
	row.Target, row.TargetID, row.TargetUser = nul(first(t.JobName, r.JobName)), nul(r.JobID), nul(t.JobOwner)
	return row
}

func first(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// ActionPayload is the jsonb argument of pgvigil.import_mssql_actions_log.
func ActionPayload(rows ...ActionLogRow) ([]byte, error) { return json.Marshal(rows) }

// ActionImportSQL is the audit write; $1 instance_id, $2 the attempt's time, $3 the payload.
const ActionImportSQL = `SELECT pgvigil.import_mssql_actions_log($1, $2, $3::jsonb)`
