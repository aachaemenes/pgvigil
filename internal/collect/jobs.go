package collect

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// jobsCollector is the Agent Jobs page of Postgres: pg_cron's job table and its
// run history, and pgAgent's jobs and log where that is installed instead. It
// applies only where one of them exists in the connected database; OS cron is
// invisible to SQL and stays out of scope. Every minute, so a failed run shows
// within the minute; run rows are stored once by (jobid, runid) and the import
// skips the ones already there.
type jobsCollector struct{}

func init() { Register(jobsCollector{}) }

func (jobsCollector) Name() string                   { return "jobs" }
func (jobsCollector) DefaultInterval() time.Duration { return time.Minute }
func (jobsCollector) Applies(info platform.Info) (bool, string) {
	if !info.HasPgCron && !info.HasPgAgent {
		return false, "neither pg_cron nor pgAgent is installed in the connected database (pg_cron lives in cron.database_name, usually postgres)"
	}
	return true, ""
}

// pg_cron: cron.job (jobname from 1.3) and cron.job_run_details (1.4+); the
// last day of runs, so a run that started over an hour ago and then ends is
// still read once more and closed; the import de-duplicates.
// pg_cron's row-level security shows a non-superuser only its own jobs: the
// monitoring login needs bypassrls or superuser-equivalent rights to see all.
const cronJobsSQL = `
SELECT 'job' AS kind, 'pg_cron' AS scheduler, j.jobid::bigint AS job_id, %s AS job_name, j.schedule, j.command,
       j.database::text AS datname, j.username::text AS run_as, j.active, j.nodename, j.nodeport
  FROM cron.job j`

const cronRunsSQL = `
SELECT 'run' AS kind, 'pg_cron' AS scheduler, r.jobid::bigint AS job_id, r.runid::bigint AS run_id, r.job_pid,
       r.database::text AS datname, r.username::text AS run_as, r.command, r.status, r.return_message,
       r.start_time, r.end_time, extract(epoch FROM r.end_time - r.start_time) AS duration_secs
  FROM cron.job_run_details r
 WHERE r.start_time > now() - interval '1 day' OR r.end_time IS NULL`

const pgagentJobsSQL = `
SELECT 'job' AS kind, 'pgagent' AS scheduler, j.jobid::bigint AS job_id, j.jobname AS job_name,
       NULL::text AS schedule, NULL::text AS command, NULL::text AS datname, NULL::text AS run_as,
       j.jobenabled AS active, j.jobhostagent AS nodename, NULL::int AS nodeport,
       j.jobnextrun AS next_run, j.joblastrun AS last_run,
       -- the definition whose versions are kept (task 110): the job, each schedule and each step; a step's code
       -- and connection string masked as a statement's text is
       jsonb_build_object('name', j.jobname, 'enabled', j.jobenabled, 'description', nullif(j.jobdesc, ''),
         'host agent', nullif(j.jobhostagent, ''),
         'schedules', coalesce((SELECT jsonb_object_agg(sc.jscname || ' #' || sc.jscid, jsonb_build_object(
             'enabled', sc.jscenabled, 'start', to_char(sc.jscstart AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
             'end', to_char(sc.jscend AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
             'minutes', pgvigil_bits(sc.jscminutes, 0), 'hours', pgvigil_bits(sc.jschours, 0),
             'weekdays', pgvigil_bits(sc.jscweekdays, 1), 'month days', regexp_replace(pgvigil_bits(sc.jscmonthdays, 1), '(^|,)32$', '\1last'),
             'months', pgvigil_bits(sc.jscmonths, 1)))
           FROM pgagent.pga_schedule sc WHERE sc.jscjobid = j.jobid), '{}'::jsonb),
         'steps', coalesce((SELECT jsonb_object_agg(st.jstname || ' #' || st.jstid, jsonb_build_object(
             'enabled', st.jstenabled, 'kind', CASE st.jstkind WHEN 's' THEN 'SQL' WHEN 'b' THEN 'batch' ELSE st.jstkind::text END,
             'database', nullif(st.jstdbname, ''), 'connection', nullif(%[1]s, ''),
             'on error', CASE st.jstonerror WHEN 'f' THEN 'fail' WHEN 's' THEN 'succeed' WHEN 'i' THEN 'ignore' ELSE st.jstonerror::text END,
             'command', %[2]s))
           FROM pgagent.pga_jobstep st WHERE st.jstjobid = j.jobid), '{}'::jsonb)) AS definition
  FROM pgagent.pga_job j`

// Masking of a job's text (a step's command or code, a connection string, a run's output), both engines: the value
// of every password-shaped item is replaced by <masked> before the row leaves the collector. Covered:
//   - T-SQL PASSWORD = ..., MEDIAPASSWORD = ... (RESTORE's media set password) and SECRET = ...; any @...password,
//     @passwd, @...pwd or @...secret parameter (sp_addlinkedsrvlogin, sp_addlogin, Idera SQL Safe's
//     @encryptedbackuppassword); and by name the backup products' key parameters: @EncryptionKey (Ola Hallengren's
//     DatabaseBackup; LiteSpeed's xp_backup_database / xp_backup_log / xp_restore_* @encryptionkey) and LiteSpeed's
//     @jobp (its encrypted key). A named list, never any parameter whose name holds 'key': @KeyColumns,
//     @EncryptionKeyPlaceholder, @ServerCertificate and KEYSIZE stay readable. The value is a literal 'x' or N'x', the
//     same with each quote doubled, N or not (the text inside a string: Red Gate SQL Backup's master..sqlbackup
//     '-SQL "... WITH PASSWORD = <the doubled form>"', the same in Ola's own call of it, a PASSWORD inside
//     EXEC (N'...')), [x] (Red Gate's square brackets, ]] inside) or, for @EncryptionKey and @jobp, a bare word
//     (T-SQL takes one as a procedure's string argument; NULL, DEFAULT and a @variable stay); Red Gate's clean-up
//     sqbutility 1032 takes the key as its sixth argument. The mask keeps the value's own quoting (the doubled
//     form stays doubled), so the text around it still reads;
//   - key = value pairs whose key holds password, passwd, pwd or secret (a connection string, libpq's keywords,
//     quoted or not); the user:password@ of a URI;
//   - a command line's -P (sqlcmd, bcp), -Password, -pw, -pwd, and LiteSpeed's tools' -K / --Key, --TgtKey,
//     --JobP / -jobp and -BackupKey; the string given to ConvertTo-SecureString (each value bare, in quotes, or
//     inside another string with its quotes doubled, as in xp_cmdshell's string); the password of
//     'net use \\host\share <password>'; dtexec's /DE and /Decrypt.
//
// A value's form is read by its place (insideLiteral): inside another string its quotes are doubled, outside one
// they are not, so an empty value (two quotes) is never read as the text up to the next pair of quotes and an empty
// value inside a string (four quotes) stays that string's. A value its text never closes (a read or msdb cut it) is
// masked to the end of the text.
var (
	maskTSQLRE   = regexp.MustCompile(`(?i)(\bPASSWORD|\bMEDIAPASSWORD|\bSECRET|@\w*(?:password|passwd|pwd|secret)\w*|@(?:EncryptionKey|jobp)\b)\s*=\s*`)
	maskSqbRE    = regexp.MustCompile(`(?i)\bsqbutility\s+1032(?:\s*,\s*(?:N?''(?:[^']|'''')*''|N?'(?:[^']|'')*'|[^,']*)){4}\s*,\s*`)
	maskKVRE     = regexp.MustCompile(`(?i)\b\w*(?:password|passwd|pwd|secret)\w*\s*[=:]\s*`)
	maskURIRE    = regexp.MustCompile(`(://[^:/@\s]+:)([^@\s/]+)(@)`)
	maskArgRE    = regexp.MustCompile(`(?:^|\s)(?:(?i:-Password|-pwd|-pw|-BackupKey|-jobp|--JobP|--Key|--TgtKey)\b|-P|-K\s)\s*`)
	maskSecureRE = regexp.MustCompile(`(?i)ConvertTo-SecureString\s+(?:-String\s+)?`)
	maskNetUseRE = regexp.MustCompile(`(?i)(\bnet\s+use\s+\S+\s+)([^/\s]\S*)`)
	maskDtsRE    = regexp.MustCompile(`(?i)(/(?:DE|Decrypt)\s+)("[^"]*"|\S+)`)

	// a value's forms, each read at the value's start
	valDQ         = regexp.MustCompile(`^"[^"]*"`)
	valSingle     = regexp.MustCompile(`^(?i:N)?'(?:[^']|'')+'`)
	valSingleEnd  = regexp.MustCompile(`^(?i:N)?'(?:[^']|'')*$`)
	valEmpty      = regexp.MustCompile(`^(?i:N)?''`)
	valDoubled    = regexp.MustCompile(`^(?i:N)?''(?:[^']|'''')*''`)
	valDoubledEnd = regexp.MustCompile(`^(?i:N)?''(?:[^']|'''')*$`)
	// outside a string, a doubled value that opens with a key's character: the quotes before it did not pair (an
	// apostrophe in a comment the reading does not know, such as PowerShell's #)
	valDoubledOut = regexp.MustCompile(`^(?i:N)?''[^'\s,;)+"\]}](?:[^']|'''')*''`)
	valBracket    = regexp.MustCompile(`^\[(?:[^\]]|\]\])*\]`)
	valBracketEnd = regexp.MustCompile(`^\[(?:[^\]]|\]\])*$`)
	valWordTSQL   = regexp.MustCompile(`^[\w#$]+`)
	valWordKV     = regexp.MustCompile(`^[^;\s,)'"]+`)
	valWordArg    = regexp.MustCompile(`^\S+`)
	valWordKeep   = regexp.MustCompile(`(?i)^(?:NULL|DEFAULT)$`)
	nameBareKey   = regexp.MustCompile(`(?i)^@(?:EncryptionKey|jobp)$`)
)

// valueForm is one way a value is written and its masked form where the value's quoting is kept.
type valueForm struct {
	re   *regexp.Regexp
	mask string
}

var (
	formsOutside = []valueForm{{valSingle, "'<masked>'"}, {valDoubledOut, "''<masked>''"}, {valSingleEnd, "'<masked>"},
		{valEmpty, "'<masked>'"}, {valBracket, "[<masked>]"}, {valBracketEnd, "[<masked>"}}
	formsInside = []valueForm{{valDoubled, "''<masked>''"}, {valDoubledEnd, "''<masked>"}, {valBracket, "[<masked>]"},
		{valBracketEnd, "[<masked>"}, {valSingle, "'<masked>'"}, {valSingleEnd, "'<masked>"}, {valEmpty, "'<masked>'"}}
)

// maskRule masks the value after each match of name.
type maskRule struct {
	name   *regexp.Regexp // the text before the value; its group 1, when it has one, is the parameter's name
	quoted bool           // the mask keeps the value's quoting (T-SQL); else the whole value becomes <masked>
	dq     bool           // a "..." value is one
	word   *regexp.Regexp // a value without quotes, nil = none
	wordIf *regexp.Regexp // a value without quotes only after a name matching this, nil = after any
	keep   *regexp.Regexp // a word that is no secret (NULL), nil = none
}

var (
	maskTSQL   = maskRule{name: maskTSQLRE, quoted: true, word: valWordTSQL, wordIf: nameBareKey, keep: valWordKeep}
	maskSqb    = maskRule{name: maskSqbRE, quoted: true, word: valWordTSQL, keep: valWordKeep}
	maskKV     = maskRule{name: maskKVRE, dq: true, word: valWordKV}
	maskArg    = maskRule{name: maskArgRE, dq: true, word: valWordArg}
	maskSecure = maskRule{name: maskSecureRE, dq: true, word: valWordArg}
)

// MaskJobText is a job's text with every password it carries, in the forms above, replaced by <masked>.
func MaskJobText(s string) string {
	s = maskTSQL.apply(s)
	s = maskSqb.apply(s)
	s = maskURIRE.ReplaceAllString(s, "${1}<masked>${3}")
	s = maskKV.apply(s)
	s = maskArg.apply(s)
	s = maskSecure.apply(s)
	s = maskNetUseRE.ReplaceAllString(s, "${1}<masked>")
	return maskDtsRE.ReplaceAllString(s, "${1}<masked>")
}

// apply masks every value the rule finds in s; a value already masked (by an earlier rule) is left as it is.
func (r maskRule) apply(s string) string {
	ms := r.name.FindAllStringSubmatchIndex(s, -1)
	if ms == nil {
		return s
	}
	in := insideLiteral(s)
	var b strings.Builder
	last, skip := 0, 0
	for _, m := range ms {
		if m[0] < skip {
			continue // inside the value just read
		}
		name := ""
		if len(m) >= 4 && m[2] >= 0 {
			name = s[m[2]:m[3]]
		}
		n, masked := r.value(s[m[1]:], in[m[1]], name)
		if n == 0 {
			continue
		}
		skip = m[1] + n
		if strings.Contains(s[m[1]:skip], "<masked>") {
			continue
		}
		b.WriteString(s[last:m[1]])
		b.WriteString(masked)
		last = skip
	}
	b.WriteString(s[last:])
	return b.String()
}

// value reads the value at the start of v (inside: v lies inside a literal) and returns its length and its masked
// form; 0 when no value of the rule's forms is there.
func (r maskRule) value(v string, inside bool, name string) (int, string) {
	if r.dq {
		if loc := valDQ.FindStringIndex(v); loc != nil {
			return loc[1], "<masked>"
		}
	}
	forms := formsOutside
	if inside {
		forms = formsInside
	}
	for _, f := range forms {
		if loc := f.re.FindStringIndex(v); loc != nil {
			if r.quoted {
				return loc[1], f.mask
			}
			return loc[1], "<masked>"
		}
	}
	if r.word == nil || (r.wordIf != nil && !r.wordIf.MatchString(name)) {
		return 0, ""
	}
	if loc := r.word.FindStringIndex(v); loc != nil && (r.keep == nil || !r.keep.MatchString(v[:loc[1]])) {
		return loc[1], "<masked>"
	}
	return 0, ""
}

// insideLiteral tells, for each byte of s and for its end, whether it lies inside a single-quoted literal as T-SQL
// reads the text: a quote opens a literal, two quotes inside one stand for a quote, the next lone quote closes it;
// outside a literal a -- comment (to the line's end), a /* */ comment, a [name] (]] inside) and a "name" hide the
// quotes they hold.
func insideLiteral(s string) []bool {
	const (
		code = iota
		literal
		lineComment
		blockComment
		bracketed
		quoted
	)
	in := make([]bool, len(s)+1)
	st := code
	for i := 0; i < len(s); i++ {
		in[i] = st == literal
		c, next := s[i], byte(0)
		if i+1 < len(s) {
			next = s[i+1]
		}
		switch st {
		case code:
			switch {
			case c == '\'':
				st = literal
			case c == '-' && next == '-':
				st = lineComment
			case c == '/' && next == '*':
				st, i = blockComment, i+1
			case c == '[':
				st = bracketed
			case c == '"':
				st = quoted
			}
		case literal:
			switch {
			case c == '\'' && next == '\'':
				i++
				in[i] = true
			case c == '\'':
				st = code
			}
		case lineComment:
			if c == '\n' {
				st = code
			}
		case blockComment:
			if c == '*' && next == '/' {
				st, i = code, i+1
			}
		case bracketed:
			switch {
			case c == ']' && next == ']':
				i++
			case c == ']':
				st = code
			}
		case quoted:
			if c == '"' {
				st = code
			}
		}
	}
	in[len(s)] = st == literal
	return in
}

// maskTree masks every string of a decoded jsonb value (a job's definition) in place.
func maskTree(v any) any {
	switch x := v.(type) {
	case string:
		return MaskJobText(x)
	case map[string]any:
		for k, e := range x {
			x[k] = maskTree(e)
		}
	case []any:
		for i, e := range x {
			x[i] = maskTree(e)
		}
	}
	return v
}

// pgagentBits is the positions of the true elements of a pgAgent schedule array, from base, as text (” = all
// false: pgAgent reads an all-false array as "any").
func pgagentBits(s string) string {
	return bitsRE.ReplaceAllStringFunc(s, func(m string) string {
		parts := bitsRE.FindStringSubmatch(m)
		return "(SELECT coalesce(string_agg((i - 1 + " + parts[2] + ")::text, ',' ORDER BY i), 'any') FROM unnest(" + parts[1] + ") WITH ORDINALITY u(b, i) WHERE b)"
	})
}

var bitsRE = regexp.MustCompile(`pgvigil_bits\(([a-z.]+), ([01])\)`)

// pgAgent's runs with the step that ended the run: a failed run's first failed step (its result and output), else
// the last step that ran.
const pgagentRunsSQL = `
SELECT 'run' AS kind, 'pgagent' AS scheduler, l.jlgjobid::bigint AS job_id, l.jlgid::bigint AS run_id, NULL::int AS job_pid,
       NULL::text AS datname, NULL::text AS run_as, NULL::text AS command,
       CASE l.jlgstatus WHEN 's' THEN 'succeeded' WHEN 'f' THEN 'failed' WHEN 'i' THEN 'internal error'
                        WHEN 'd' THEN 'aborted' WHEN 'r' THEN 'running' ELSE l.jlgstatus END AS status,
       left(fs.jsloutput, 4000) AS return_message, fs.jstname AS failed_step, fs.jslresult AS step_result, l.jlgstart AS start_time,
       CASE WHEN l.jlgstatus = 'r' THEN NULL ELSE l.jlgstart + l.jlgduration END AS end_time,
       extract(epoch FROM l.jlgduration) AS duration_secs
  FROM pgagent.pga_joblog l
  LEFT JOIN LATERAL (SELECT st.jstname, sl.jslresult, %s AS jsloutput
                       FROM pgagent.pga_jobsteplog sl
                       LEFT JOIN pgagent.pga_jobstep st ON st.jstid = sl.jsljstid
                      WHERE sl.jsljlgid = l.jlgid
                      ORDER BY (sl.jslstatus IN ('f', 'i')) DESC, sl.jslstart DESC LIMIT 1) fs
         ON l.jlgstatus IN ('f', 'i', 'd')
 WHERE l.jlgstart > now() - interval '1 day' OR l.jlgstatus = 'r'`

func (jobsCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	out := []Row{}
	run := func(label, sql string) error {
		rows, err := conn.Query(ctx, sql)
		if err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		r, err := rowsToMaps(rows)
		if err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		out = append(out, r...)
		return nil
	}
	if info.HasPgCron {
		cols, err := viewColumns(ctx, conn, "cron.job")
		if err != nil {
			return nil, err
		}
		if err := run("cron.job", fmt.Sprintf(cronJobsSQL, col(cols, "j", "jobname", "text"))); err != nil {
			return nil, err
		}
		if err := run("cron.job_run_details", cronRunsSQL); err != nil {
			return nil, err
		}
		cs := ReadCronSettings(ctx, conn) // the server's clock rides in cs.Now: the runs' start_time is on it
		AddCronTimes(out, cs.Now, cs)
	}
	defer func() {
		for _, r := range out {
			for _, k := range []string{"command", "return_message"} {
				if t, ok := r[k].(string); ok {
					r[k] = MaskJobText(t)
				}
			}
			if d, ok := r["definition"]; ok {
				r["definition"] = maskTree(d)
			}
			// the job's script, from the masked row
			if r["kind"] == "job" {
				r["script"], r["script_format"] = jobScript(r), JobScriptFormat
			}
		}
	}()
	if info.HasPgAgent {
		if err := run("pgagent.pga_job", pgagentBits(fmt.Sprintf(pgagentJobsSQL, maskSQL("st.jstconnstr"), maskSQL("st.jstcode")))); err != nil {
			return nil, err
		}
		if err := run("pgagent.pga_joblog", fmt.Sprintf(pgagentRunsSQL, maskSQL("sl.jsloutput"))); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// The job as one script (task 154; what DBA Dash keeps as a job's DDL): every job row carries 'script', the
// statements that make the job again, built from the row as it leaves the collector (so a password is <masked> in
// the script too). The repository stores it with every version of the job, and two versions compare as text.
//   pg_cron   one cron.schedule_in_database call, a named argument per line (a job without a name: cron.schedule,
//             which takes the schedule and the command only; its database, user and state follow as a comment)
//   pgAgent   the DO block pgAdmin writes for a job: the job, then an INSERT per step and per schedule, the
//             schedule's minutes, hours, weekdays, month days and months as pgAgent's boolean arrays

// JobScriptFormat numbers the way jobScript writes a script: a change to the builder takes the next number, so the
// repository rewrites the newest version's script in place instead of storing a version of every job (0094).
const JobScriptFormat = 1

// sqlLit is a text as a PostgreSQL string literal.
func sqlLit(s string) string {
	if strings.Contains(s, `\`) {
		return "E'" + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), "'", "''") + "'"
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// dollarQuoted is a text between dollar quotes whose tag the text does not hold.
func dollarQuoted(s, tag string) string {
	t := "$" + tag + "$"
	// a text that holds the tag, or ends in it without its last '$' (that end and the closing tag would make one)
	for i := 1; strings.Contains(s, t) || strings.HasSuffix(s, t[:len(t)-1]); i++ {
		t = fmt.Sprintf("$%s%d$", tag, i)
	}
	return t + s + t
}

func textOf(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// cronScript is a pg_cron job row as its script.
func cronScript(r Row) string {
	var b strings.Builder
	name, cmd := textOf(r["job_name"]), textOf(r["command"])
	active := "true"
	if a, ok := r["active"].(bool); ok && !a {
		active = "false"
	}
	if name == "" {
		fmt.Fprintf(&b, "-- pg_cron job %v (no name)\n", r["job_id"])
		b.WriteString("SELECT cron.schedule(\n    schedule => " + sqlLit(textOf(r["schedule"])) + ",\n    command  => " + dollarQuoted(cmd, "cmd") + ");\n")
		b.WriteString("-- as read: database " + sqlLit(textOf(r["datname"])) + ", username " + sqlLit(textOf(r["run_as"])) + ", active " + active + "\n")
		return b.String()
	}
	b.WriteString("-- pg_cron job: " + strings.NewReplacer("\r", " ", "\n", " ").Replace(name) + "\n")
	b.WriteString("SELECT cron.schedule_in_database(\n")
	b.WriteString("    job_name => " + sqlLit(name) + ",\n")
	b.WriteString("    schedule => " + sqlLit(textOf(r["schedule"])) + ",\n")
	b.WriteString("    command  => " + dollarQuoted(cmd, "cmd") + ",\n")
	b.WriteString("    database => " + sqlLit(textOf(r["datname"])) + ",\n")
	b.WriteString("    username => " + sqlLit(textOf(r["run_as"])) + ",\n")
	b.WriteString("    active   => " + active + ");\n")
	return b.String()
}

// keyed is one named part of a pgAgent definition: the key is "<name> #<id>".
type keyed struct {
	name string
	id   int
	v    map[string]any
}

// partsOf is the steps or the schedules of a pgAgent definition in the order of their ids.
func partsOf(v any) []keyed {
	m, _ := v.(map[string]any)
	out := make([]keyed, 0, len(m))
	for k, e := range m {
		p := keyed{name: k}
		if i := strings.LastIndex(k, " #"); i >= 0 {
			p.name = k[:i]
			p.id, _ = strconv.Atoi(k[i+2:])
		}
		p.v, _ = e.(map[string]any)
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].id != out[j].id {
			return out[i].id < out[j].id
		}
		return out[i].name < out[j].name
	})
	return out
}

// bitsArray is pgAgent's boolean array of n elements from the positions the collector read ("0,30", "any" = none
// set; base = the position of the first element; "last" = the 32nd month day).
func bitsArray(v any, n, base int) string {
	set := make([]bool, n)
	for _, p := range strings.Split(textOf(v), ",") {
		p = strings.TrimSpace(p)
		i := -1
		if p == "last" {
			i = n - 1
		} else if x, err := strconv.Atoi(p); err == nil {
			i = x - base
		}
		if i >= 0 && i < n {
			set[i] = true
		}
	}
	var b strings.Builder
	b.WriteString("'{")
	for i, s := range set {
		if i > 0 {
			b.WriteByte(',')
		}
		if s {
			b.WriteByte('t')
		} else {
			b.WriteByte('f')
		}
	}
	b.WriteString("}'::boolean[]")
	return b.String()
}

// agentJobScript is a pgAgent job's definition as its script.
func agentJobScript(def map[string]any) string {
	var b strings.Builder
	yes := func(v any) string {
		if x, ok := v.(bool); ok && !x {
			return "false"
		}
		return "true"
	}
	// a time the collector wrote as 'YYYY-MM-DD HH24:MI:SS UTC', NULL where the definition has none
	ts := func(v any) string {
		if s := textOf(v); s != "" {
			return sqlLit(s) + "::timestamptz"
		}
		return "NULL"
	}
	b.WriteString("-- pgAgent job: " + strings.NewReplacer("\r", " ", "\n", " ").Replace(textOf(def["name"])) + "\n")
	head := b.String()
	b.Reset()
	b.WriteString("\nDECLARE\n    jid integer;\nBEGIN\n")
	b.WriteString("INSERT INTO pgagent.pga_job (jobjclid, jobname, jobdesc, jobhostagent, jobenabled)\nVALUES (\n")
	b.WriteString("    1,\n    " + sqlLit(textOf(def["name"])) + ",\n    " + sqlLit(textOf(def["description"])) + ",\n    " +
		sqlLit(textOf(def["host agent"])) + ",\n    " + yes(def["enabled"]) + ")\nRETURNING jobid INTO jid;\n")
	for _, st := range partsOf(def["steps"]) {
		kind := map[string]string{"SQL": "s", "batch": "b"}[textOf(st.v["kind"])]
		if kind == "" {
			kind = textOf(st.v["kind"])
		}
		onerr := map[string]string{"fail": "f", "succeed": "s", "ignore": "i"}[textOf(st.v["on error"])]
		if onerr == "" {
			onerr = textOf(st.v["on error"])
		}
		b.WriteString("\n-- step: " + strings.NewReplacer("\r", " ", "\n", " ").Replace(st.name) + "\n")
		b.WriteString("INSERT INTO pgagent.pga_jobstep (jstjobid, jstname, jstenabled, jstkind, jstdbname, jstconnstr, jstonerror, jstcode)\nVALUES (\n")
		b.WriteString("    jid,\n    " + sqlLit(st.name) + ",\n    " + yes(st.v["enabled"]) + ",\n    " + sqlLit(kind) + ",\n    " +
			sqlLit(textOf(st.v["database"])) + ",\n    " + sqlLit(textOf(st.v["connection"])) + ",\n    " + sqlLit(onerr) + ",\n    " +
			dollarQuoted(textOf(st.v["command"]), "code") + ");\n")
	}
	for _, sc := range partsOf(def["schedules"]) {
		b.WriteString("\n-- schedule: " + strings.NewReplacer("\r", " ", "\n", " ").Replace(sc.name) + "\n")
		b.WriteString("INSERT INTO pgagent.pga_schedule (jscjobid, jscname, jscenabled, jscstart, jscend, jscminutes, jschours, jscweekdays, jscmonthdays, jscmonths)\nVALUES (\n")
		b.WriteString("    jid,\n    " + sqlLit(sc.name) + ",\n    " + yes(sc.v["enabled"]) + ",\n    " + ts(sc.v["start"]) + ",\n    " + ts(sc.v["end"]) + ",\n")
		b.WriteString("    " + bitsArray(sc.v["minutes"], 60, 0) + ",\n    " + bitsArray(sc.v["hours"], 24, 0) + ",\n    " +
			bitsArray(sc.v["weekdays"], 7, 1) + ",\n    " + bitsArray(sc.v["month days"], 32, 1) + ",\n    " + bitsArray(sc.v["months"], 12, 1) + ");\n")
	}
	b.WriteString("END\n")
	// the block's own quote, never one its text holds (a step that carries a script copied from this page)
	return head + "DO " + dollarQuoted(b.String(), "pgagent") + ";\n"
}

// jobScript is the script of one job row (kind 'job'), by its scheduler.
func jobScript(r Row) string {
	if textOf(r["scheduler"]) == "pgagent" {
		def, _ := r["definition"].(map[string]any)
		return agentJobScript(def)
	}
	return cronScript(r)
}
