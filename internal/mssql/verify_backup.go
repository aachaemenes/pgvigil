package mssql

// verify_backup (task 301b, dbachecks' Database#6): RESTORE VERIFYONLY of one backup set through the actions door - off
// unless the instance has an actions_dsn AND its actions: list names verify_backup, and off by default in the site's
// switch list (the lead's O1): it gives the actions login CREATE DATABASE, so that login can restore a copy of any
// database whose backup file the SQL Server service account can read (probe 301bP1: both forms of the right do it, the
// copy owned by the login). VERIFYONLY itself creates no database and writes no restorehistory row (301bP1).
//
// Three steps, the first two inside the request, the third detached from it (a verify of a large backup runs for
// minutes or hours, past the request's 30 seconds):
//   - VerifyPreview: the read login reads the set by its backup_set_uuid - the disk families of mirror 0, the position
//     in the media, whether it has checksums, its size - and says when it is not offered (a URL, tape or virtual device;
//     password-protected or encrypted media);
//   - VerifyPrepare: the request carries only the uuid (a GUID: the door's rule that no statement holds a value but a
//     number or a GUID) and what Preview showed; the set is read again and any difference refuses; the actions login
//     is checked (another login than the read one, the same server, never sysadmin / CONTROL SERVER, never dbcreator or
//     ALTER ANY DATABASE, CREATE DATABASE in master); a running verify (a RESTORE of program 'pgvigil-actions') refuses;
//     RESTORE HEADERONLY of the file and position on the ACTIONS login (it needs CREATE DATABASE too: 301bP1) must name
//     the set's uuid as its BackupSetGUID (301bP2) - else the file now holds another backup set;
//   - VerifyRun: RESTORE VERIFYONLY FROM DISK = @d1[, DISK = @d2 ...] WITH FILE = @f[, CHECKSUM], the paths and the
//     position as parameters (sp_executesql: the audit keeps a statement with no path in it), CHECKSUM only where the
//     set has checksums (Msg 3187 otherwise: 301bP1), the server's own notices kept ('The backup set on file 1 is
//     valid.').
// The caller (the web door, in the WIRING patch) audits 'started' before it starts VerifyRun, the end when it returns,
// 'cut by shutdown' when serve stops under it, and holds one verify per instance (an advisory lock on the repository).

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/golang-sql/sqlexp"
	mssqldb "github.com/microsoft/go-mssqldb"
)

// ActionVerifyBackup is the door's action for RESTORE VERIFYONLY (the WIRING patch adds it to ActionKinds).
const ActionVerifyBackup ActionKind = "verify_backup"

// The outcomes of a detached run beside done / refused / failed (0191 widens actions_log's CHECK with them).
const (
	OutcomeStarted       = "started"         // the checks passed and the verify started
	OutcomeCutByShutdown = "cut by shutdown" // serve stopped under the verify
	OutcomeEndedUnknown  = "ended unknown"   // a 'started' with no end, found when serve started again
)

// VerifyTimeoutDefault bounds one verify (the config's verify_timeout, the WIRING patch's).
const VerifyTimeoutDefault = 2 * time.Hour

// VerifySet is one backup set as the read login saw it: what the user is shown, and what the confirm step carries back.
type VerifySet struct {
	UUID         string   `json:"backup_set_uuid"`
	Database     string   `json:"database"`
	Type         string   `json:"backup_type"`
	FinishUTC    string   `json:"finish_utc"`
	Position     int      `json:"position"`
	HasChecksums bool     `json:"has_checksums"`
	SizeBytes    int64    `json:"size_bytes"`
	Paths        []string `json:"paths"`
	NotOffered   string   `json:"not_offered,omitempty"`
	devices      []int
	password     bool
	encrypted    bool
}

// VerifyRequest is one verify attempt: the set's uuid and what Preview showed of it, and who asks.
type VerifyRequest struct {
	Instance string
	UUID     string
	Shown    VerifySet
	Reason   string
	User     string
	Client   string
}

// VerifyResult is how a step ended, with the statement (sent, or that would have been sent) and the server's words.
type VerifyResult struct {
	Outcome       string `json:"outcome"`
	Detail        string `json:"detail"`
	Statement     string `json:"statement,omitempty"`
	ServerMessage string `json:"server_message,omitempty"`
	Set           VerifySet
}

// VerifyJob is a prepared verify: the set read last and the statement VerifyRun sends.
type VerifyJob struct {
	Request   VerifyRequest
	Set       VerifySet
	Statement string
}

// verifySetSQL reads one set by its uuid (the read login: db_datareader in msdb, or guest): the first backupset row of
// the uuid (verifyOneSetSQL) - a RESTORE on the server the set came from may write a second row of the same uuid into
// msdb, and its families would be listed twice.
var verifySetSQL = `SELECT CAST(bs.database_name AS nvarchar(128)), CASE bs.type WHEN 'D' THEN 'full' WHEN 'I' THEN 'diff' WHEN 'L' THEN 'log' ELSE bs.type END,
  ` + backupUTC("bs.backup_finish_date") + `, CAST(bs.position AS int), CAST(bs.has_backup_checksums AS int), CAST(bs.backup_size AS bigint),
  CAST(bs.is_password_protected AS int), CAST(ISNULL(ms.is_encrypted, 0) AS int) | CASE WHEN bs.key_algorithm IS NULL OR bs.key_algorithm = N'NO_Encryption' THEN 0 ELSE 1 END,
  CAST(ISNULL(ms.is_password_protected, 0) AS int)
FROM msdb.dbo.backupset bs
LEFT JOIN msdb.dbo.backupmediaset ms ON ms.media_set_id = bs.media_set_id
WHERE ` + verifyOneSetSQL

// verifyFamiliesSQL: the set's media families of mirror 0 in order (a striped set names every family).
var verifyFamiliesSQL = `SELECT CAST(f.device_type AS int), CAST(f.physical_device_name AS nvarchar(260))
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = bs.media_set_id AND f.mirror = 0
WHERE ` + verifyOneSetSQL + `
ORDER BY f.family_sequence_number`

// verifyOneSetSQL picks the first backupset row of the uuid @p1.
const verifyOneSetSQL = `bs.backup_set_id = (SELECT MIN(x.backup_set_id) FROM msdb.dbo.backupset x WHERE x.backup_set_uuid = CAST(@p1 AS uniqueidentifier))`

// verifyActorSQL: what the actions login holds beside actorSQL's sysadmin / CONTROL SERVER.
const verifyActorSQL = `SELECT CAST(ISNULL(IS_SRVROLEMEMBER('dbcreator'), 0) AS int),
  CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY DATABASE'), 0) AS int),
  CAST(ISNULL(HAS_PERMS_BY_NAME(N'master', 'DATABASE', 'CREATE DATABASE'), 0) AS int)`

// verifyRunningSQL (the read login, VIEW SERVER STATE): a RESTORE running in a session of the actions door.
const verifyRunningSQL = `SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
WHERE s.program_name = N'pgvigil-actions' AND r.command LIKE N'RESTORE%'`

// ValidateVerify checks the request's own shape (no connection needed).
func ValidateVerify(r VerifyRequest) error {
	switch {
	case !jobIDForm.MatchString(r.UUID):
		return errors.New("backup_set_uuid must be a backup set's uuid (a GUID)")
	case !strings.EqualFold(r.Shown.UUID, r.UUID):
		return errors.New("the set shown is not the set asked for")
	case len(r.Shown.Paths) == 0 || r.Shown.Position <= 0:
		return errors.New("the files and position of the set shown are required")
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

// verifyStatement is the statement's text for n disk families: RESTORE VERIFYONLY (or HEADERONLY) with the paths and
// the position as parameters, CHECKSUM only for a verify of a set that has checksums. It holds no path.
func verifyStatement(verb string, n int, checksum bool) string {
	devs := make([]string, n)
	for i := range devs {
		devs[i] = "DISK = @d" + strconv.Itoa(i+1)
	}
	s := "RESTORE " + verb + " FROM " + strings.Join(devs, ", ") + " WITH FILE = @f"
	if checksum && verb == "VERIFYONLY" {
		s += ", CHECKSUM"
	}
	return s
}

// verifyArgs are the statement's parameters: @d1..@dn the paths, @f the position.
func verifyArgs(paths []string, position int) []any {
	args := make([]any, 0, len(paths)+1)
	for i, p := range paths {
		args = append(args, sql.Named("d"+strconv.Itoa(i+1), p))
	}
	return append(args, sql.Named("f", int32(position))) // int, as the probes declared @f (a Go int goes as bigint)
}

// readVerifySet reads one set by its uuid; errNoTarget when msdb has no such set.
func readVerifySet(ctx context.Context, mon *sql.Conn, uuid string) (VerifySet, error) {
	s := VerifySet{UUID: strings.ToUpper(uuid)}
	var checks, pw, enc, mediaPW int
	err := mon.QueryRowContext(ctx, verifySetSQL, uuid).Scan(&s.Database, &s.Type, &s.FinishUTC, &s.Position, &checks, &s.SizeBytes, &pw, &enc, &mediaPW)
	if errors.Is(err, sql.ErrNoRows) {
		return s, errNoTarget
	}
	if err != nil {
		return s, err
	}
	s.HasChecksums, s.password, s.encrypted = checks == 1, pw == 1 || mediaPW == 1, enc == 1
	rows, err := mon.QueryContext(ctx, verifyFamiliesSQL, uuid)
	if err != nil {
		return s, err
	}
	defer func() { _ = rows.Close() }()
	for rows.Next() {
		var dev int
		var path string
		if err := rows.Scan(&dev, &path); err != nil {
			return s, err
		}
		s.devices, s.Paths = append(s.devices, dev), append(s.Paths, path)
	}
	if err := rows.Err(); err != nil {
		return s, err
	}
	s.NotOffered = s.notOffered()
	return s, nil
}

// notOffered is why a set is never verified from the UI, or "" when it may be.
func (s VerifySet) notOffered() string {
	switch {
	case len(s.Paths) == 0:
		return "not offered: msdb names no file of this set"
	case s.password:
		return "not offered: the media is password-protected (VERIFYONLY would need the password)"
	case s.encrypted:
		return "not offered: the backup is encrypted (VERIFYONLY needs the certificate or key on the server)"
	}
	for i, d := range s.devices {
		p := s.Paths[i]
		if d%100 != 2 || strings.Contains(p, "://") || strings.EqualFold(strings.TrimSuffix(p, ":"), "NUL") {
			return "not offered: not a disk backup (a URL, tape, virtual device or NUL)"
		}
	}
	return ""
}

// sameSet says whether the set read now is the one shown: the same database, type and finish, the same files in order,
// position, checksums and size (the typed confirmation is checked against the shown database, so it must be the set's).
func sameSet(now, shown VerifySet) bool {
	if now.Database != shown.Database || now.Type != shown.Type || now.FinishUTC != shown.FinishUTC {
		return false
	}
	if now.Position != shown.Position || now.HasChecksums != shown.HasChecksums || now.SizeBytes != shown.SizeBytes || len(now.Paths) != len(shown.Paths) {
		return false
	}
	for i := range now.Paths {
		if now.Paths[i] != shown.Paths[i] {
			return false
		}
	}
	return true
}

// VerifyPreview reads the set the user picked and what it would send; why is the reason it cannot, or "".
func VerifyPreview(ctx context.Context, d Door, instance, uuid string) (s VerifySet, statement, why string) {
	if !jobIDForm.MatchString(uuid) {
		return s, "", "backup_set_uuid must be a backup set's uuid (a GUID)"
	}
	if off := d.Off(instance, ActionVerifyBackup); off != "" {
		return s, "", off
	}
	if d.Monitor == "" {
		return s, "", fmt.Sprintf("instance %s: the read login's dsn resolved to an empty string", instance)
	}
	mdb, mon, err := openAction(ctx, d.Monitor, "pgvigil-actions-check")
	if err != nil {
		return s, "", fmt.Sprintf("the read login could not connect: %v", err)
	}
	defer func() { _ = mon.Close(); _ = mdb.Close() }()
	s, err = readVerifySet(ctx, mon, uuid)
	switch {
	case errors.Is(err, errNoTarget):
		return s, "", fmt.Sprintf("msdb has no backup set %s (any more)", uuid)
	case err != nil:
		return s, "", fmt.Sprintf("the set could not be read: %v", err)
	case s.NotOffered != "":
		return s, "", s.NotOffered
	}
	return s, verifyStatement("VERIFYONLY", len(s.Paths), s.HasChecksums), ""
}

// VerifyPrepare runs every check of a verify inside the request and returns the job VerifyRun sends, or a refusal.
func VerifyPrepare(ctx context.Context, d Door, r VerifyRequest) (VerifyJob, VerifyResult) {
	stmt := verifyStatement("VERIFYONLY", len(r.Shown.Paths), r.Shown.HasChecksums)
	refuse := func(s VerifySet, format string, a ...any) (VerifyJob, VerifyResult) {
		return VerifyJob{}, VerifyResult{Outcome: OutcomeRefused, Detail: fmt.Sprintf(format, a...), Statement: stmt, Set: s}
	}
	if err := ValidateVerify(r); err != nil {
		return refuse(r.Shown, "%s", err.Error())
	}
	if off := d.Off(r.Instance, ActionVerifyBackup); off != "" {
		return refuse(r.Shown, "%s", off)
	}
	if d.Monitor == "" {
		return refuse(r.Shown, "instance %s: the read login's dsn resolved to an empty string", r.Instance)
	}
	mdb, mon, err := openAction(ctx, d.Monitor, "pgvigil-actions-check")
	if err != nil {
		return refuse(r.Shown, "the read login could not connect to check the set: %v", err)
	}
	defer func() { _ = mon.Close(); _ = mdb.Close() }()
	adb, act, err := openAction(ctx, d.Actions, "pgvigil-actions")
	if err != nil {
		return refuse(r.Shown, "the actions login could not connect: %v; nothing was sent", err)
	}
	defer func() { _ = act.Close(); _ = adb.Close() }()
	var monName, monStart, monLogin, actName, actStart, actLogin string
	var actSPID, sysadmin, control, dbcreator, alterAny, createDB int
	if err := mon.QueryRowContext(ctx, serverSQL2).Scan(&monName, &monStart, &monLogin); err != nil {
		return refuse(r.Shown, "the server check failed: %v", err)
	}
	if err := act.QueryRowContext(ctx, serverSQL2).Scan(&actName, &actStart, &actLogin); err != nil {
		return refuse(r.Shown, "the actions login's server check failed: %v; nothing was sent", err)
	}
	if monName != actName || monStart != actStart {
		return refuse(r.Shown, "actions_dsn reaches another server than the instance's dsn (%s started %s vs %s started %s): nothing was sent", actName, actStart, monName, monStart)
	}
	if err := act.QueryRowContext(ctx, actorSQL).Scan(&actSPID, &sysadmin, &control); err != nil {
		return refuse(r.Shown, "the actions login's own check failed: %v; nothing was sent", err)
	}
	if err := act.QueryRowContext(ctx, verifyActorSQL).Scan(&dbcreator, &alterAny, &createDB); err != nil {
		return refuse(r.Shown, "the actions login's own check failed: %v; nothing was sent", err)
	}
	switch {
	case strings.EqualFold(actLogin, monLogin):
		return refuse(r.Shown, "actions_dsn connects as the read login (%s): the actions login must be a login of its own", actLogin)
	case sysadmin == 1 || control == 1:
		return refuse(r.Shown, "the actions login %s is sysadmin or holds CONTROL SERVER: pgvigil refuses it (docs/sqlserver-actions.md has the grants it needs, and no more)", actLogin)
	case dbcreator == 1 || alterAny == 1:
		return refuse(r.Shown, "the actions login %s is in dbcreator or holds ALTER ANY DATABASE: verify_backup takes CREATE DATABASE in master only (docs/sqlserver-actions.md)", actLogin)
	case createDB != 1:
		return refuse(r.Shown, "the actions login %s has no CREATE DATABASE in master: RESTORE VERIFYONLY needs it (docs/sqlserver-actions.md)", actLogin)
	}
	var running int
	if err := mon.QueryRowContext(ctx, verifyRunningSQL).Scan(&running); err != nil {
		return refuse(r.Shown, "the check for a running verify failed: %v", err)
	}
	if running > 0 {
		return refuse(r.Shown, "a verify of the actions door is running on %s: one at a time", r.Instance)
	}
	now, err := readVerifySet(ctx, mon, r.UUID)
	switch {
	case errors.Is(err, errNoTarget):
		return refuse(r.Shown, "msdb has no backup set %s any more", r.UUID)
	case err != nil:
		return refuse(r.Shown, "the set check failed: %v", err)
	case now.NotOffered != "":
		return refuse(now, "%s", now.NotOffered)
	case !sameSet(now, r.Shown):
		return refuse(now, "backup set %s is not as shown (its files, position, checksums or size changed): read it again", r.UUID)
	}
	if got, err := headerGUID(ctx, act, now); err != nil {
		msg := serverMessage(err)
		return VerifyJob{}, VerifyResult{Outcome: OutcomeFailed, Detail: "RESTORE HEADERONLY failed: " + msg,
			Statement: verifyStatement("HEADERONLY", len(now.Paths), false), ServerMessage: msg, Set: now}
	} else if !strings.EqualFold(got, now.UUID) {
		return refuse(now, "the file now holds another backup set at position %d (BackupSetGUID %s, not %s): nothing was verified", now.Position, got, now.UUID)
	}
	return VerifyJob{Request: r, Set: now, Statement: verifyStatement("VERIFYONLY", len(now.Paths), now.HasChecksums)}, VerifyResult{Outcome: OutcomeStarted, Detail: "the verify started", Statement: stmt, Set: now}
}

// headerGUID reads RESTORE HEADERONLY's BackupSetGUID for the set's position, by the column's name (56 columns on
// SQL Server 2019, 59 on 2022: 301bP1).
func headerGUID(ctx context.Context, act *sql.Conn, s VerifySet) (string, error) {
	rows, err := act.QueryContext(ctx, verifyStatement("HEADERONLY", len(s.Paths), false), verifyArgs(s.Paths, s.Position)...)
	if err != nil {
		return "", err
	}
	defer func() { _ = rows.Close() }()
	cols, err := rows.Columns()
	if err != nil {
		return "", err
	}
	at := -1
	for i, c := range cols {
		if strings.EqualFold(c, "BackupSetGUID") {
			at = i
		}
	}
	if at < 0 {
		return "", errors.New("RESTORE HEADERONLY returned no BackupSetGUID column")
	}
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return "", err
		}
		return "", errors.New("RESTORE HEADERONLY returned no row")
	}
	vals := make([]any, len(cols))
	for i := range vals {
		vals[i] = new(any)
	}
	if err := rows.Scan(vals...); err != nil {
		return "", err
	}
	switch v := (*vals[at].(*any)).(type) {
	case []byte:
		// the driver hands SQL Server's wire order (the first three groups little-endian) by default, RFC order when the
		// DSN sets 'guid conversion=true': the reading of the bytes that names the set's uuid is it
		if len(v) == 16 {
			if rfc := fmt.Sprintf("%X-%X-%X-%X-%X", v[0:4], v[4:6], v[6:8], v[8:10], v[10:16]); strings.EqualFold(rfc, s.UUID) {
				return rfc, nil
			}
		}
		var u mssqldb.UniqueIdentifier
		if err := u.Scan(v); err != nil {
			return "", err
		}
		return u.String(), nil
	case string:
		return strings.ToUpper(v), nil
	default:
		return fmt.Sprint(v), nil
	}
}

// VerifyRun sends the verify on a connection of its own and waits for the server's words (the caller bounds ctx by
// verify_timeout and cancels it when serve stops).
func VerifyRun(ctx context.Context, d Door, job VerifyJob) VerifyResult {
	res := VerifyResult{Statement: job.Statement, Set: job.Set}
	adb, act, err := openAction(ctx, d.Actions, "pgvigil-actions")
	if err != nil {
		res.Outcome, res.Detail = OutcomeFailed, fmt.Sprintf("the actions login could not connect: %v; nothing was sent", err)
		return res
	}
	defer func() { _ = act.Close(); _ = adb.Close() }()
	var spid int64
	if err := act.QueryRowContext(ctx, `SELECT CAST(@@SPID AS bigint)`).Scan(&spid); err != nil {
		res.Outcome, res.Detail = OutcomeFailed, "the actions login's session could not be read: "+serverMessage(err)+"; nothing was sent"
		return res
	}
	wctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	watched := make(chan struct{})
	go func() { defer close(watched); watchVerify(wctx, cancel, d.Monitor, spid) }()
	notices, errs := runWithMessages(wctx, act, job.Statement, verifyArgs(job.Set.Paths, job.Set.Position)...)
	lost := errors.Is(context.Cause(wctx), errVerifyLost)
	cancel(nil)
	<-watched
	res.ServerMessage = strings.Join(append(append([]string{}, errs...), notices...), " | ")
	switch {
	case lost:
		res.Outcome, res.Detail = OutcomeFailed, "the verify's connection to the server was lost: its session no longer runs the RESTORE (the server restarted, failed over or ended the session)"
	case ctx.Err() != nil:
		res.Outcome, res.Detail = OutcomeFailed, "the verify did not end before its limit: "+ctx.Err().Error()
	case len(errs) > 0:
		res.Outcome, res.Detail = OutcomeFailed, "the server refused or failed the verify: "+errs[0]
	default:
		res.Outcome, res.Detail = OutcomeDone, "the verify ended without an error"
	}
	return res
}

// errVerifyLost is the watcher's cause: the actions session no longer runs the verify.
var errVerifyLost = errors.New("the verify's session no longer runs the RESTORE")

// verifyWatchEvery is how often watchVerify looks; two looks in a row that miss end the wait.
var verifyWatchEvery = time.Minute

// verifyWatchSQL (the read login): whether it may see other sessions' requests (VIEW SERVER STATE), and whether the
// actions session @p1 still runs a RESTORE.
const verifyWatchSQL = `SELECT CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE'), 0) AS int),
  (SELECT COUNT(*) FROM sys.dm_exec_requests r WHERE r.session_id = @p1 AND r.command LIKE N'RESTORE%')`

// watchVerify ends a verify whose connection was lost (go-mssqldb hands a broken read to its token channel only, so the
// message reader would wait until verify_timeout): every verifyWatchEvery the read login looks for the actions
// session's RESTORE; two looks in a row that miss it (or cannot connect) cancel with errVerifyLost. A read login
// without VIEW SERVER STATE sees no other session's request: nothing is watched then, and the limit is verify_timeout
// (docs/sqlserver-actions.md).
func watchVerify(ctx context.Context, cancel context.CancelCauseFunc, monitor string, spid int64) {
	misses := 0
	t := time.NewTicker(verifyWatchEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		var vss, running int64
		lctx, lcancel := context.WithTimeout(ctx, 20*time.Second)
		mdb, mon, err := openAction(lctx, monitor, "pgvigil-actions-check")
		if err == nil {
			err = mon.QueryRowContext(lctx, verifyWatchSQL, spid).Scan(&vss, &running)
			_ = mon.Close()
			_ = mdb.Close()
		}
		lcancel()
		switch {
		case ctx.Err() != nil:
			return
		case err == nil && vss != 1:
			return
		case err == nil && running > 0:
			misses = 0
			continue
		}
		if misses++; misses >= 2 {
			cancel(errVerifyLost)
			return
		}
	}
}

// runWithMessages runs one statement through go-mssqldb's message reader and returns the server's notices and errors
// in the order the server sent them (a refusal comes as several errors: Msg 3201 then Msg 3013 - all are kept).
func runWithMessages(ctx context.Context, c *sql.Conn, query string, args ...any) (notices, errs []string) {
	retmsg := &sqlexp.ReturnMessage{}
	rows, err := c.QueryContext(ctx, query, append([]any{retmsg}, args...)...)
	if err != nil {
		return nil, []string{serverMessage(err)}
	}
	defer func() { _ = rows.Close() }()
	for active := true; active; {
		switch m := retmsg.Message(ctx).(type) {
		case sqlexp.MsgNotice:
			notices = append(notices, m.Message.String())
		case sqlexp.MsgError:
			errs = append(errs, serverMessage(m.Error))
		case sqlexp.MsgNext:
			for rows.Next() {
			}
		case sqlexp.MsgNextResultSet:
			active = rows.NextResultSet()
		case nil:
			active = false
		}
		if ctx.Err() != nil {
			break
		}
	}
	if err := rows.Err(); err != nil && ctx.Err() == nil {
		errs = append(errs, serverMessage(err))
	}
	return notices, errs
}

// VerifyRow builds the audit row of a verify step: no pid, the set's database, type and finish as the target, its
// uuid as the target id.
func VerifyRow(at time.Time, r VerifyRequest, res VerifyResult) ActionLogRow {
	nul := func(s string) string { return strings.ReplaceAll(s, "\x00", "") }
	reason := strings.TrimSpace(r.Reason)
	if reason == "" {
		reason = "(no reason given)"
	}
	if rs := []rune(reason); len(rs) > MaxActionReason {
		reason = string(rs[:MaxActionReason])
	}
	s := res.Set
	if s.UUID == "" {
		s = r.Shown
	}
	target := strings.TrimSpace(s.Database + " " + s.Type + " " + s.FinishUTC)
	return ActionLogRow{At: at, Instance: r.Instance, UIUser: nul(r.User), Client: nul(r.Client), Action: string(ActionVerifyBackup),
		Target: nul(target), TargetID: nul(strings.ToUpper(r.UUID)), Reason: nul(reason), Outcome: res.Outcome, Detail: nul(res.Detail),
		Statement: nul(res.Statement), ServerMessage: nul(res.ServerMessage)}
}
