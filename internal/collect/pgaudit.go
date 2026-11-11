package collect

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/logparse"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// pgauditCollector is the audit read of a PostgreSQL server (pgaudit).
//
// Health, every run, from the connected database (nothing here needs more than pg_monitor): whether the library is
// loaded (its own settings exist in a backend only then: pgaudit loads through shared_preload_libraries or not at
// all), the preload list where the login may read it, every pgaudit.* setting of pg_settings with its source, every
// ALTER DATABASE / ALTER ROLE ... SET pgaudit.* of pg_db_role_setting, and where the server log goes.
//
// Events, only on a server that has pgaudit loaded: the 'AUDIT:' lines of the server log, read on a pass of its own
// through the doors the log readers use (on-prem: pg_ls_logdir and the client DBA's read door, serverlog.go; RDS and
// Aurora: the log group in CloudWatch Logs, logs.go) from a cursor of its own ('pgaudit:' + the reader's source).
// ROLE and DDL entries become rows (who, when, database, command, object), and so does a SET or a RESET (pgaudit.log's
// misc_set) of a setting that changes who the session is, what is audited or logged, or what the server enforces
// (auditIsRow). Every other entry is only counted: READ, WRITE, FUNCTION and MISC, and every other SET, per
// setting name (an application's SET search_path, a pooler's SET application_name and this collector's own four
// session settings run with every connection: as rows they would bury the ones that matter). The statement text and
// the parameters of a row are kept only when the instance's config says audit_text: true, and then under the
// instance's query_text policy (normalized masks the literals and keeps no parameters, none keeps nothing); a
// counted entry never keeps text.
//
// Counting once: like the log readers, each run re-reads an overlap behind its cursor. A row is dropped on the
// re-read by its key; a count has no key, so the collector counts per second and per source (the log file or
// stream) and the import adds only what a second gained over what it had counted (pgvigil.pgaudit_count_secs,
// 0100): a second read again in full counts what it counted before or more, a second read from its middle counts
// less and changes nothing. For that a read starts at a whole second, and one second (pgauditGuard) before the
// second it has to count again: backends stamp their lines before they write them, so at a second's edge a line
// can sit a few lines before one stamped earlier, and a read that began exactly at the edge would miss it. An entry
// cut by the end of a read (its last lines not written yet) is left to the next read, which has it whole: taken
// twice it could be a count the first time and a row the second.
//
// Not pgaudit's: a session can raise a message that has the form of an audit entry (RAISE LOG 'AUDIT: ...'). The
// server writes such a message with its CONTEXT and STATEMENT lines, which pgaudit's own never have; the parser marks
// it Forged and it is neither a row nor a count: the state row carries how many the read met, the newest and whose.
// The last entry of a read has nothing after it yet, so while it is younger than pgauditSettle it waits for the next
// read, which sees what follows it.
//
// Rows by kind:
//
//	state    loaded, preload_libraries, log_where, log_read (ok | off | not read), log_read_reason, log_source,
//	         keep_text, entries_read, last_entry_at, forged_lines, forged_at, forged_by           (one)
//	setting  scope (server | database | role | role in database), datname, rolname, name, value, source
//	event    at, audit_type, class, command, object_type, object_name, target_role, usename, datname, client, pid,
//	         statement_id, substatement_id, row_count, statement, parameters, source, event_key
//	count    source, sec, usename, datname, class, command, object_type, object_name, entries
//	cursor   source, read_to
//
// class is the pgaudit.log class (logparse.AuditEntry.LogClass): MISC_SET for a SET or a RESET, which the log line
// itself carries as MISC.
type pgauditCollector struct{}

func init() { Register(pgauditCollector{}) }

const (
	// pgauditMaxEvents is the CloudWatch read's cap per run: audit lines are many (one per statement under read or
	// write auditing), so it is ten times the log reader's.
	pgauditMaxEvents = 200000
	// pgauditGuard is how far before the second it must count again a read starts (the collector's comment).
	pgauditGuard = time.Second
	// pgauditSettle is how old a read's last entry must be to be taken without the line that follows it.
	pgauditSettle = 5 * time.Second
)

func (pgauditCollector) Name() string                   { return "pgaudit" }
func (pgauditCollector) DefaultInterval() time.Duration { return time.Minute }
func (pgauditCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

func (pgauditCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("pgaudit needs the instance config: %w", ErrSkip)
}

// pgauditLoadedSQL: pgaudit.log_catalog is a boolean only when the library defined it; a pgaudit.* line of
// postgresql.conf without the library is a placeholder of type string.
const pgauditLoadedSQL = `SELECT EXISTS (SELECT 1 FROM pg_settings WHERE name = 'pgaudit.log_catalog' AND vartype = 'bool')`

// pgauditServerSQL: the server's pgaudit.* settings as this session sees them, with where each value comes from.
const pgauditServerSQL = `
SELECT 'setting' AS kind, 'server' AS scope, '' AS datname, '' AS rolname, name::text AS name, setting::text AS value, source::text AS source
  FROM pg_settings
 WHERE name LIKE 'pgaudit.%'
 ORDER BY name`

// pgauditScopedSQL: ALTER DATABASE / ALTER ROLE [IN DATABASE] ... SET pgaudit.*; pg_db_role_setting is readable by
// every login.
const pgauditScopedSQL = `
SELECT 'setting' AS kind,
       CASE WHEN s.setdatabase <> 0 AND s.setrole <> 0 THEN 'role in database' WHEN s.setrole <> 0 THEN 'role' ELSE 'database' END AS scope,
       coalesce(d.datname, CASE WHEN s.setdatabase <> 0 THEN s.setdatabase::text ELSE '' END)::text AS datname,
       coalesce(r.rolname, CASE WHEN s.setrole <> 0 THEN s.setrole::text ELSE '' END)::text AS rolname,
       split_part(c.cfg, '=', 1) AS name, substr(c.cfg, strpos(c.cfg, '=') + 1) AS value, NULL::text AS source
  FROM pg_db_role_setting s
  CROSS JOIN LATERAL unnest(s.setconfig) c(cfg)
  LEFT JOIN pg_database d ON d.oid = s.setdatabase
  LEFT JOIN pg_roles r ON r.oid = s.setrole
 WHERE c.cfg LIKE 'pgaudit.%'
 ORDER BY 2, 3, 4, 5`

// pgauditPlaceholderSQL: without the library a pgaudit.* line of postgresql.conf (or of ALTER SYSTEM) is a
// placeholder: pg_settings does not list it, current_setting returns it. Read only when the library is not loaded.
const pgauditPlaceholderSQL = `
SELECT 'setting' AS kind, 'server' AS scope, '' AS datname, '' AS rolname, n AS name, current_setting(n, true) AS value,
       'not loaded: a placeholder' AS source
  FROM unnest(ARRAY['pgaudit.log', 'pgaudit.log_catalog', 'pgaudit.log_client', 'pgaudit.log_level', 'pgaudit.log_parameter',
                    'pgaudit.log_parameter_max_size', 'pgaudit.log_relation', 'pgaudit.log_rows', 'pgaudit.log_statement',
                    'pgaudit.log_statement_once', 'pgaudit.role']) n
 WHERE current_setting(n, true) IS NOT NULL
 ORDER BY 5`

// pgauditLogSQL: the settings that say where the log goes; pg_settings leaves out the ones the login may not read
// (log_directory and log_filename need pg_read_all_settings) instead of raising an error.
const pgauditLogSQL = `
SELECT name::text, setting::text FROM pg_settings
 WHERE name IN ('shared_preload_libraries', 'logging_collector', 'log_destination', 'log_directory', 'log_filename')`

func (pgauditCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, cursor CursorFunc) ([]Row, error) {
	var loaded bool
	if err := conn.QueryRow(ctx, pgauditLoadedSQL).Scan(&loaded); err != nil {
		return nil, fmt.Errorf("pgaudit loaded: %w", err)
	}
	var out []Row
	settings := []string{pgauditServerSQL, pgauditScopedSQL}
	if !loaded {
		settings = []string{pgauditPlaceholderSQL, pgauditScopedSQL}
	}
	for _, q := range settings {
		r, err := conn.Query(ctx, q)
		if err != nil {
			return nil, fmt.Errorf("pgaudit settings: %w", err)
		}
		rows, err := rowsToMaps(r)
		if err != nil {
			return nil, fmt.Errorf("pgaudit settings: %w", err)
		}
		out = append(out, rows...)
	}
	set := map[string]string{}
	r, err := conn.Query(ctx, pgauditLogSQL)
	if err != nil {
		return nil, fmt.Errorf("pgaudit log settings: %w", err)
	}
	for r.Next() {
		var n, v string
		if err := r.Scan(&n, &v); err != nil {
			r.Close()
			return nil, err
		}
		set[n] = v
	}
	r.Close()
	if err := r.Err(); err != nil {
		return nil, err
	}

	keepText := in.AuditText
	state := Row{"kind": "state", "loaded": loaded, "keep_text": keepText, "log_where": pgauditLogWhere(info, in, set)}
	if v, ok := set["shared_preload_libraries"]; ok {
		state["preload_libraries"] = v
	}
	if !loaded {
		state["log_read"], state["log_read_reason"] = "off", "pgaudit is not loaded: there are no audit lines to read"
		return append(out, state), nil
	}

	agg := newAuditAgg(keepText, keepText && (in.QueryText == "" || in.QueryText == "full"))
	source, readTo, extra, why, err := pgauditRead(ctx, conn, info, in, cursor, agg)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		// a read that failed part-way (a file gone, CloudWatch refusing) stores nothing of the log and leaves the
		// cursor where it was; the settings read above stand, and the run ends partial with the reason
		state["log_read"], state["log_read_reason"] = "not read", err.Error()
		return append(out, state, Row{"kind": "collector_error", "source": "pgaudit", "message": err.Error()}), nil
	}
	if why != "" {
		state["log_read"], state["log_read_reason"] = "not read", why
		return append(out, state), nil
	}
	state["log_read"], state["log_source"], state["entries_read"] = "ok", source, agg.entries
	if !agg.newest.IsZero() {
		state["last_entry_at"] = agg.newest.UTC()
	}
	if state["forged_lines"] = agg.forged; agg.forged > 0 {
		state["forged_at"], state["forged_by"] = agg.forgedAt.UTC(), agg.forgedBy
	}
	out = append(out, state)
	out = append(out, agg.rows()...)
	out = append(out, extra...)
	out = append(out, Row{"kind": "cursor", "source": "pgaudit:" + source, "read_to": readTo.UTC()})
	return out, nil
}

// pgauditLogWhere says in words where the server log goes.
func pgauditLogWhere(info platform.Info, in config.Instance, set map[string]string) string {
	if info.Kind == platform.RDS || info.Kind == platform.Aurora {
		if in.AWS != nil && in.AWS.PostgresLogGroup() != "" {
			return "CloudWatch Logs, log group " + in.AWS.PostgresLogGroup() + " (the instance's log export; the config's aws: block)"
		}
		return "the instance's log files (RDS); no aws: block in the config names its CloudWatch log group"
	}
	dest, ok := set["log_destination"]
	if !ok {
		return ""
	}
	w := "log_destination " + dest
	if set["logging_collector"] == "on" {
		w += ", logging_collector on"
		if d, ok := set["log_directory"]; ok {
			w += ": files " + set["log_filename"] + " in " + d
		}
	} else {
		w += ", logging_collector off: stderr goes where the service manager sends it"
	}
	return w
}

// pgauditRead reads the audit lines written since the cursor into agg. It returns the reader's source and how far
// it read, or why the log is not read here (the health rows are stored either way).
func pgauditRead(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, cursor CursorFunc, agg *auditAgg) (source string, readTo time.Time, extra []Row, why string, err error) {
	start := func(source string) (time.Time, error) {
		t, ok, err := cursor(ctx, "pgaudit:"+source)
		if err != nil {
			return time.Time{}, err
		}
		return pgauditFrom(t, ok, time.Now()), nil
	}
	switch info.Kind {
	case platform.RDS, platform.Aurora:
		if in.AWS == nil || in.AWS.PostgresLogGroup() == "" {
			return "", time.Time{}, nil, "no aws: block with cluster or db_instance in the config: the audit lines are read from the instance's CloudWatch log group", nil
		}
		group := in.AWS.PostgresLogGroup()
		source = "cloudwatch:" + group
		from, err := start(source)
		if err != nil {
			return "", time.Time{}, nil, "", err
		}
		loc := time.UTC
		var tz string
		if err := conn.QueryRow(ctx, "SELECT current_setting('log_timezone')").Scan(&tz); err == nil {
			if l, err := time.LoadLocation(tz); err == nil {
				loc = l
			}
		}
		fetch, err := fetcherFor(ctx, *in.AWS)
		if err != nil {
			return "", time.Time{}, nil, "", err
		}
		evs, err := fetch(ctx, group, from, pgauditMaxEvents)
		if err != nil {
			return "", time.Time{}, nil, "", err
		}
		readTo, extra := pgauditCloudwatch(evs, source, from, loc, len(evs) >= pgauditMaxEvents, agg)
		return source, readTo, extra, "", nil
	case platform.OnPrem:
		var s serverlogSettings
		err := conn.QueryRow(ctx, `
SELECT current_setting('logging_collector'), current_setting('log_destination'), coalesce(current_setting('log_directory', true), ''),
       current_setting('log_line_prefix'), current_setting('log_timezone'),
       has_function_privilege('pg_catalog.pg_ls_logdir()', 'EXECUTE'),
       has_function_privilege($1, 'EXECUTE'), coalesce((`+serverlogDoorFind+`), '')`, serverlogReadFn).
			Scan(&s.Collector, &s.Destination, &s.Directory, &s.Prefix, &s.TimeZone, &s.CanList, &s.CanRead, &s.Door)
		if err != nil {
			// log_directory is not readable without pg_read_all_settings: a reason, not a failed run
			return "", time.Time{}, nil, "the log settings could not be read (log_directory needs GRANT pg_monitor TO <login>): " + err.Error(), nil
		}
		if why := s.check(); why != "" {
			return "", time.Time{}, nil, why, nil
		}
		lp, err := compilePrefix(s.Prefix)
		if err != nil {
			return "", time.Time{}, nil, err.Error(), nil
		}
		z, err := serverZone(ctx, conn, s.TimeZone)
		if err != nil {
			return "", time.Time{}, nil, "", err
		}
		source = "serverlog:" + s.Directory
		from, err := start(source)
		if err != nil {
			return "", time.Time{}, nil, "", err
		}
		readTo, extra, err := pgauditServerlog(ctx, pgLogDir{conn: conn, dir: s.Directory, door: s.Door}, lp, z, source, from, serverlogMaxBytes, agg)
		if err != nil {
			return "", time.Time{}, nil, "", err
		}
		return source, readTo, extra, "", nil
	}
	return "", time.Time{}, nil, fmt.Sprintf("the log readers cover on-prem servers and RDS / Aurora; on %s the audit settings are read, the audit lines are not", info.Kind), nil
}

// pgauditFrom is where a read starts: one overlap behind the cursor (an hour back on the first read), at a whole
// second, one guard second earlier (the collector's comment on counting once).
func pgauditFrom(cursor time.Time, found bool, now time.Time) time.Time {
	from := now.Add(-logsFirstRead)
	if found {
		from = cursor.Add(-logsOverlap)
	}
	return from.Truncate(time.Second).Add(-pgauditGuard)
}

// pgauditReadTo is the cursor after a read that started at from and whose newest line (or the line after one it
// had to skip) is last. A read that took everything there was: last. A read that hit its cap: one overlap past
// last, so the next starts a guard second before last's second - unless that is no later than this read's own
// start (the cap was spent inside the first two seconds), where the cursor goes one second on instead and stalled
// says so: the next read then starts a second later, whatever the log holds.
func pgauditReadTo(from, last time.Time, full bool) (readTo time.Time, stalled bool) {
	switch {
	case last.IsZero():
		return from, false
	case !full && last.After(from):
		return last, false
	case !full:
		return from, false
	case last.Truncate(time.Second).Before(from.Add(pgauditGuard + time.Second)):
		return from.Add(pgauditGuard + time.Second + logsOverlap), true
	}
	return last.Add(logsOverlap), false
}

// pgauditServerlog reads the audit lines of the stderr files written since from (a whole second), oldest first, up
// to maxBytes, into agg, and returns how far it read: serverlogRows' walk, the cursor by pgauditReadTo. A run that
// had to move its cursor on without having read everything before it adds a collector_error row that says so.
func pgauditServerlog(ctx context.Context, dir logDir, lp *linePrefix, z *logZone, source string, from time.Time, maxBytes int64, agg *auditAgg) (time.Time, []Row, error) {
	files, err := dir.List(ctx)
	if err != nil {
		return time.Time{}, nil, err
	}
	sort.Slice(files, func(i, j int) bool {
		if !files[i].Modified.Equal(files[j].Modified) {
			return files[i].Modified.Before(files[j].Modified)
		}
		return files[i].Name < files[j].Name
	})
	var extra []Row
	var last, skipTo time.Time
	budget, full := maxBytes, false
	z.misses = 0
	for _, f := range files {
		if strings.HasSuffix(f.Name, ".csv") || strings.HasSuffix(f.Name, ".json") || f.Modified.Add(time.Second).Before(from) || f.Size == 0 {
			continue
		}
		if budget <= 0 {
			full = true
			break
		}
		start, err := seekTime(ctx, dir, lp, z, f, from)
		if err != nil {
			return time.Time{}, nil, err
		}
		if start >= f.Size {
			continue
		}
		end := f.Size
		if end-start > budget {
			end, full = start+budget, true
		}
		buf, err := readRange(ctx, dir, f.Name, start, end)
		if err != nil {
			return time.Time{}, nil, err
		}
		budget -= int64(len(buf))
		if i := bytes.LastIndexByte(buf, '\n'); i >= 0 { // a line still being written is read next run
			buf = buf[:i+1]
		} else {
			buf = nil
		}
		text, newest := lp.rewrite(strings.ToValidUTF8(string(buf), "�"), z)
		if newest.After(last) {
			last = newest
		}
		if full && !newest.After(from) && end < f.Size { // no progress: one line longer than the budget, go past it
			_, t, ok, err := nextLine(ctx, dir, lp, z, f, end)
			if err != nil {
				return time.Time{}, nil, err
			}
			if ok {
				skipTo = t
			}
		}
		src := source + ":" + f.Name
		_ = logparse.ScanAudit(strings.NewReader(text), time.UTC, func(e logparse.AuditEntry) { agg.add(src, f.Name, e) }) // rewrite writes UTC times
		if full {
			break
		}
	}
	if full && !skipTo.IsZero() { // past a line longer than the budget: the line after it stands for the newest read
		last = skipTo
	}
	readTo, stalled := pgauditReadTo(from, last, full)
	if stalled {
		extra = append(extra, Row{"kind": "collector_error", "source": "pgaudit", "message": fmt.Sprintf(
			"more than %d MB of server log in the two seconds from %s, or a line longer than that: what is left of them is not read",
			maxBytes>>20, from.UTC().Format(time.RFC3339))})
	}
	if z.misses > 0 {
		extra = append(extra, Row{"kind": "collector_error", "source": "pgaudit", "message": fmt.Sprintf(
			"%d log lines skipped: their time zone is neither one the collector can load (log_timezone %q) nor an abbreviation of pg_timezone_abbrevs", z.misses, z.name)})
	}
	return readTo, extra, nil
}

// pgauditCloudwatch reads the audit lines of the fetched events, stream by stream, into agg and returns how far the
// read went: logRows' cursor rule for a batch that took everything (the earliest of the streams' latest events),
// pgauditReadTo for a full one.
func pgauditCloudwatch(evs []cwEvent, source string, from time.Time, loc *time.Location, full bool, agg *auditAgg) (time.Time, []Row) {
	byStream := map[string][]cwEvent{}
	latest := map[string]time.Time{}
	var last time.Time
	for _, e := range evs {
		byStream[e.Stream] = append(byStream[e.Stream], e)
		if e.Time.After(latest[e.Stream]) {
			latest[e.Stream] = e.Time
		}
		if e.Time.After(last) {
			last = e.Time
		}
	}
	readTo := from
	var extra []Row
	if full {
		var stalled bool
		if readTo, stalled = pgauditReadTo(from, last, true); stalled {
			extra = append(extra, Row{"kind": "collector_error", "source": "pgaudit", "message": fmt.Sprintf(
				"more than %d log events in the two seconds from %s: what is left of them is not read", len(evs), from.UTC().Format(time.RFC3339))})
		}
	} else {
		first := true
		for _, t := range latest {
			if first || t.Before(readTo) {
				readTo, first = t, false
			}
		}
		if readTo.Before(from) {
			readTo = from
		}
	}
	streams := make([]string, 0, len(byStream))
	for s := range byStream {
		streams = append(streams, s)
	}
	sort.Strings(streams)
	for _, s := range streams {
		list := byStream[s]
		sort.SliceStable(list, func(i, j int) bool { return list[i].Time.Before(list[j].Time) })
		var b strings.Builder
		for _, e := range list {
			b.WriteString(strings.TrimRight(e.Message, "\n"))
			b.WriteByte('\n')
		}
		src := source + ":" + s
		_ = logparse.ScanAudit(strings.NewReader(b.String()), loc, func(e logparse.AuditEntry) { agg.add(src, s, e) })
	}
	return readTo, extra
}

// auditCountKey is one count: a second of one source, and who did what to what.
type auditCountKey struct {
	source                                                 string
	sec                                                    int64
	user, database, class, command, objectType, objectName string
}

// auditAgg turns audit entries into the collection's rows: a row per entry auditIsRow keeps, a count per second and
// key for every other one.
type auditAgg struct {
	keepText, keepParams bool
	now                  time.Time // the read's time: what pgauditSettle is measured from
	events               []Row
	counts               map[auditCountKey]int64
	entries              int64
	newest               time.Time
	forged               int64     // entries that have pgaudit's form and are not pgaudit's
	forgedAt             time.Time // the newest of them
	forgedBy             string    // its user@database
}

func newAuditAgg(keepText, keepParams bool) *auditAgg {
	return &auditAgg{keepText: keepText, keepParams: keepParams, now: time.Now(), counts: map[auditCountKey]int64{}}
}

// auditIsRow says whether an entry is kept as a row: every ROLE and DDL entry, and a SET or RESET that matters to
// an audit. setting and role are what logparse.AuditTarget read from the statement ("" when it was not logged:
// such a SET is counted).
//
// The SETs kept: the audit itself (pgaudit.*); what reaches the server log (every log_* setting: a session may set
// them only as a superuser or by a grant); what the server enforces on the session (row_security,
// session_replication_role: triggers and rules off; allow_system_table_mods); and SET SESSION AUTHORIZATION to a
// named role (a superuser acting as another role). Counted, not kept: SET SESSION AUTHORIZATION DEFAULT and its
// RESET (the session's own role back: some poolers send it with every release of a connection), SET ROLE (an
// application that takes a role per request does it thousands of times an hour; the count's object names the role
// taken) and every other setting.
func auditIsRow(class, setting, role string) bool {
	switch class {
	case logparse.AuditRole, logparse.AuditDDL:
		return true
	case logparse.AuditMiscSet:
		switch setting {
		case "session_authorization":
			return role != ""
		case "row_security", "session_replication_role", "allow_system_table_mods":
			return true
		}
		return strings.HasPrefix(setting, "pgaudit.") || strings.HasPrefix(setting, "log_")
	}
	return false
}

// add takes one entry of a source (source: the row's source column; part: the log file or stream, which keys the
// row with the entry's own key as the log readers key an event).
func (a *auditAgg) add(source, part string, e logparse.AuditEntry) {
	switch {
	case e.Forged:
		a.forged++
		if e.At.After(a.forgedAt) {
			a.forgedAt, a.forgedBy = e.At, e.User+"@"+e.Database
		}
		return
	case e.Truncated:
		return // the next read has the entry whole
	case e.Last && a.now.Sub(e.At) < pgauditSettle:
		return // the next read sees the line after it
	}
	a.entries++
	if e.At.After(a.newest) {
		a.newest = e.At
	}
	class := e.LogClass()
	objType, objName, role := logparse.AuditTarget(e)
	if class == logparse.AuditMiscSet && objName == "" {
		// pgaudit 13 to 16 write the whole text of a multi-statement string on each entry of it, so several SETs can
		// be this entry's. When one of them is an audit matter the entry is kept under it: every entry of that string
		// is, so such a SET is reported more than once and never missed.
		for _, o := range logparse.AuditTargets(e) {
			if auditIsRow(class, o.Name, o.Role) {
				objType, objName, role = o.Type, o.Name, o.Role
				break
			}
		}
	}
	if !auditIsRow(class, objName, role) {
		if class == logparse.AuditMiscSet && objName == "role" && role != "" {
			objName = "role = " + role // a role's name, not a value: who the session became
		}
		k := auditCountKey{source: source, sec: e.At.Unix(), user: e.User, database: e.Database, class: class,
			command: e.Command, objectType: objType, objectName: objName}
		a.counts[k]++
		return
	}
	sum := md5.Sum([]byte(string(logparse.Audit) + "\x00" + part + "\x00" + e.Key))
	row := Row{
		"kind": "event", "at": e.At.UTC(), "audit_type": e.Type, "class": class, "command": e.Command,
		"object_type": nilIfEmpty(objType), "object_name": nilIfEmpty(objName), "target_role": nilIfEmpty(role),
		"usename": e.User, "datname": e.Database, "client": e.Client, "pid": e.PID,
		"statement_id": e.StatementID, "substatement_id": e.SubstatementID,
		"source": source, "event_key": hex.EncodeToString(sum[:]),
	}
	if e.Rows >= 0 {
		row["row_count"] = e.Rows
	}
	if a.keepText {
		row["statement"] = nilIfEmpty(maskText(e.Statement))
	}
	if a.keepParams {
		row["parameters"] = nilIfEmpty(maskText(e.Parameters))
	}
	a.events = append(a.events, row)
}

// rows returns the event rows and the count rows, the counts in a fixed order.
func (a *auditAgg) rows() []Row {
	keys := make([]auditCountKey, 0, len(a.counts))
	for k := range a.counts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		x, y := keys[i], keys[j]
		switch {
		case x.sec != y.sec:
			return x.sec < y.sec
		case x.source != y.source:
			return x.source < y.source
		case x.user != y.user:
			return x.user < y.user
		case x.database != y.database:
			return x.database < y.database
		case x.class != y.class:
			return x.class < y.class
		case x.command != y.command:
			return x.command < y.command
		case x.objectType != y.objectType:
			return x.objectType < y.objectType
		}
		return x.objectName < y.objectName
	})
	out := make([]Row, 0, len(a.events)+len(keys))
	out = append(out, a.events...)
	for _, k := range keys {
		out = append(out, Row{"kind": "count", "source": k.source, "sec": time.Unix(k.sec, 0).UTC(), "usename": k.user,
			"datname": k.database, "class": k.class, "command": k.command, "object_type": k.objectType,
			"object_name": k.objectName, "entries": a.counts[k]})
	}
	return out
}
