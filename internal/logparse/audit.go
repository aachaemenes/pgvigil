package logparse

import (
	"bufio"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"
)

// pgaudit's entries. pgaudit writes one server-log line per audited statement or object:
//
//	LOG:  AUDIT: SESSION,1,1,DDL,CREATE TABLE,TABLE,public.account,"create table account (id int, name text)",<not logged>
//
// The fields after 'AUDIT: ' are CSV: the audit type (SESSION, or OBJECT for pgaudit.role's object auditing), the
// statement id and the substatement id (counted per backend), the class (READ, WRITE, FUNCTION, ROLE, DDL, MISC),
// the command tag, the object type and name (where pgaudit knows them: a SELECT's or a DML's relations, a DDL's
// object once the extension's event triggers exist in the database), the statement text, the parameters and, with
// pgaudit.log_rows, the row count. pgaudit.log's class misc_set is not a class of the line: a SET or a RESET is
// written with the class MISC whichever of misc and misc_set turned it on (LogClass names it).
// A field that holds a comma, a double quote or a line break is double-quoted and a quote inside it doubled; a
// statement of several lines continues on tab-led lines like any other entry.
// The statement is '<not logged>' under pgaudit.log_statement = off and '<previously logged>' for the later entries
// of one statement under pgaudit.log_statement_once; the parameters are '<none>', '<not logged>' (pgaudit.log_parameter
// off) or '<long param suppressed>'.
//
// pgaudit hides the statement and the context of its own message and gives it no detail and no hint, so none of the
// lines DETAIL, HINT, QUERY, CONTEXT or STATEMENT ever follows an entry of its process. A message a session raises
// itself (RAISE LOG 'AUDIT: SESSION,...' in a DO block) has the same first line and is followed by its CONTEXT and
// STATEMENT lines: ScanAudit hands such an entry over marked Forged, never as an entry.

// Audit is the kind of a pgaudit entry. ParseIn does not return it (an AUDIT line is no event of its kinds, at any
// level); ScanAudit reads them.
const Audit Kind = "audit"

// The classes of pgaudit.log. A line carries every one but MISC_SET (LogClass).
const (
	AuditRead     = "READ"
	AuditWrite    = "WRITE"
	AuditFunction = "FUNCTION"
	AuditRole     = "ROLE"
	AuditDDL      = "DDL"
	AuditMisc     = "MISC"
	AuditMiscSet  = "MISC_SET"
)

// AuditEntry is one pgaudit line.
type AuditEntry struct {
	At       time.Time
	Client   string
	User     string
	Database string
	PID      int
	// Type is SESSION or OBJECT.
	Type           string
	StatementID    int64
	SubstatementID int64
	Class          string
	Command        string
	ObjectType     string
	ObjectName     string
	// Statement is the statement text, "" when pgaudit did not write it (<not logged>, <previously logged>).
	Statement string
	// Parameters is the parameter list as pgaudit wrote it (its own CSV), "" when there is none or it was not logged.
	Parameters string
	// Rows is the row count of pgaudit.log_rows, -1 when the entry has none.
	Rows int64
	// Truncated says the entry ended inside a quoted field: its last lines were not in the text read (an entry
	// still being written, or a statement cut by the read's end). The fields before the cut are whole.
	Truncated bool
	// Oversize says a line of the entry was longer than the reader keeps (auditLineMax): the fixed fields stand,
	// the statement, the parameters and the row count are dropped. A later read finds the entry the same.
	Oversize bool
	// Last says no line followed the entry in the text read: what comes after it (nothing, for an entry of
	// pgaudit's; a CONTEXT line, for an imitation) is not known yet.
	Last bool
	// Forged says the entry has the form of pgaudit's and is not pgaudit's: a DETAIL, HINT, QUERY, CONTEXT or
	// STATEMENT line of its process follows it.
	Forged bool
	// Key identifies the entry from its first line alone (time text, level, pid, message), as Event.Key does.
	Key string
}

// LogClass is the pgaudit.log class an entry belongs to: the line's own class, but MISC_SET for a SET or a RESET,
// which pgaudit writes as MISC.
func (e AuditEntry) LogClass() string {
	if e.Class == AuditMisc && (e.Command == "SET" || e.Command == "RESET") {
		return AuditMiscSet
	}
	return e.Class
}

const auditPrefix = "AUDIT: "

const (
	// auditLineMax is the longest line the reader keeps whole (ParseIn's limit); of a longer one it keeps the first
	// auditLineKeep bytes, which hold an entry's fixed fields.
	auditLineMax  = 16 << 20
	auditLineKeep = 64 << 10
)

// auditHidden are the texts pgaudit writes in place of a statement or a parameter list it does not log.
func auditHidden(s string) bool {
	return s == "<not logged>" || s == "<previously logged>" || s == "<none>"
}

// splitAuditCSV splits pgaudit's CSV. ok is false when the text ends inside a quoted field: the fields before it
// are whole and the last one holds what was read of the cut field.
func splitAuditCSV(s string) (fields []string, ok bool) {
	i := 0
	for {
		if i < len(s) && s[i] == '"' {
			var b strings.Builder
			i++
			closed := false
			for i < len(s) {
				if s[i] == '"' {
					if i+1 < len(s) && s[i+1] == '"' {
						b.WriteByte('"')
						i += 2
						continue
					}
					closed = true
					i++
					break
				}
				b.WriteByte(s[i])
				i++
			}
			fields = append(fields, b.String())
			if !closed {
				return fields, false
			}
			// what follows a closing quote up to the next comma is not pgaudit's: skipped
			for i < len(s) && s[i] != ',' {
				i++
			}
		} else {
			j := strings.IndexByte(s[i:], ',')
			if j < 0 {
				fields = append(fields, s[i:])
				return fields, true
			}
			fields = append(fields, s[i:i+j])
			i += j
		}
		if i >= len(s) {
			return fields, true
		}
		i++ // the comma
		if i == len(s) {
			fields = append(fields, "")
			return fields, true
		}
	}
}

// ParseAuditMessage reads one entry's message ('AUDIT: SESSION,1,1,...', with its continuation lines joined by line
// breaks). False when the message is not pgaudit's or its fixed fields (type, ids, class, command, object type and
// name) are not all there.
func ParseAuditMessage(msg string) (AuditEntry, bool) {
	rest, found := strings.CutPrefix(msg, auditPrefix)
	if !found {
		return AuditEntry{}, false
	}
	f, whole := splitAuditCSV(rest)
	// a cut inside one of the seven fixed fields leaves nothing to trust
	if len(f) < 7 || (!whole && len(f) == 7) {
		return AuditEntry{}, false
	}
	if f[0] != "SESSION" && f[0] != "OBJECT" {
		return AuditEntry{}, false
	}
	sid, err1 := strconv.ParseInt(f[1], 10, 64)
	sub, err2 := strconv.ParseInt(f[2], 10, 64)
	if err1 != nil || err2 != nil || f[3] == "" {
		return AuditEntry{}, false
	}
	e := AuditEntry{Type: f[0], StatementID: sid, SubstatementID: sub, Class: f[3], Command: f[4],
		ObjectType: f[5], ObjectName: f[6], Rows: -1, Truncated: !whole}
	if len(f) > 7 && !auditHidden(f[7]) {
		e.Statement = f[7]
	}
	if len(f) > 8 && !auditHidden(f[8]) {
		e.Parameters = f[8]
	}
	if len(f) > 9 && whole {
		if n, err := strconv.ParseInt(f[9], 10, 64); err == nil {
			e.Rows = n
		}
	}
	return e, true
}

// readLogLine reads one line without its line break. Of a line longer than auditLineMax it returns the first
// auditLineKeep bytes and long = true. io.EOF comes with the last line, or alone when nothing is left.
func readLogLine(br *bufio.Reader) (line string, long bool, err error) {
	var buf []byte
	for {
		part, e := br.ReadSlice('\n')
		switch {
		case long:
		case len(buf)+len(part) > auditLineMax:
			long = true
			buf = append(buf, part...)
			if len(buf) > auditLineKeep {
				buf = buf[:auditLineKeep]
			}
		default:
			buf = append(buf, part...)
		}
		if errors.Is(e, bufio.ErrBufferFull) {
			continue
		}
		err = e
		break
	}
	if !long {
		buf = []byte(strings.TrimRight(string(buf), "\r\n"))
	}
	return string(buf), long, err
}

// auditFollows are the lines pgaudit never writes after an entry (the file's header comment).
func auditFollows(level string) bool {
	switch level {
	case "DETAIL", "HINT", "QUERY", "CONTEXT", "STATEMENT":
		return true
	}
	return false
}

// stripSQLState drops the 'XXXXX: ' that log_error_verbosity = verbose writes before every message. A SQLSTATE is
// five digits and capitals with a digit among them (00000, 42501, XX000, P0001): 'AUDIT: ' itself is no SQLSTATE.
func stripSQLState(msg string) string {
	if len(msg) < 7 || msg[5] != ':' || msg[6] != ' ' {
		return msg
	}
	digit := false
	for i := 0; i < 5; i++ {
		c := msg[i]
		if (c < '0' || c > '9') && (c < 'A' || c > 'Z') {
			return msg
		}
		digit = digit || c >= '0' && c <= '9'
	}
	if !digit {
		return msg
	}
	return msg[7:]
}

// auditTime reads a line's time. As in ParseIn a zone that is neither UTC nor a numeric offset is read in loc; here
// the abbreviation then picks the side of a clock change: in the hour a zone repeats, 01:30 EDT and 01:30 EST are an
// hour apart, and a count filed an hour early lies behind what the reader has closed.
func auditTime(text, abbr string, loc *time.Location) (time.Time, bool) {
	layout := "2006-01-02 15:04:05"
	if len(text) > 19 {
		layout += ".999999"
	}
	t, err := time.ParseInLocation(layout, text, zoneOf(abbr, loc))
	if err != nil {
		return time.Time{}, false
	}
	if n, _ := t.Zone(); n != abbr {
		for _, d := range []time.Duration{-time.Hour, time.Hour} {
			u := t.Add(d)
			if n, _ := u.Zone(); n == abbr && u.Format("2006-01-02 15:04:05") == text[:19] {
				return u, true
			}
		}
	}
	return t, true
}

// ScanAudit reads log text in the prefix ParseIn reads ('%t:%r:%u@%d:[%p]:', the on-prem reader's rewrite included)
// and calls fn for every pgaudit entry, in the order of the log. loc is the server's log_timezone (ParseIn). Lines
// of other entries are passed over without being parsed. An entry ends at the first line that is not one of its
// tab-led continuation lines; when that line is a DETAIL, HINT, QUERY, CONTEXT or STATEMENT line of the same
// process the entry is not pgaudit's and fn gets it marked Forged. The last entry of the text is marked Last.
func ScanAudit(r io.Reader, loc *time.Location, fn func(AuditEntry)) error {
	if loc == nil {
		loc = time.UTC
	}
	br := bufio.NewReaderSize(r, 64*1024)
	var cur *AuditEntry
	var msg strings.Builder
	emit := func(last, forged bool) {
		if cur == nil {
			return
		}
		if e, ok := ParseAuditMessage(msg.String()); ok {
			e.At, e.Client, e.User, e.Database, e.PID, e.Key = cur.At, cur.Client, cur.User, cur.Database, cur.PID, cur.Key
			e.Last, e.Forged = last, forged
			if cur.Oversize {
				e.Oversize, e.Truncated = true, false
				e.Statement, e.Parameters, e.Rows = "", "", -1
			}
			fn(e)
		}
		cur = nil
	}
	for {
		line, long, err := readLogLine(br)
		if err != nil && line == "" {
			if !errors.Is(err, io.EOF) {
				return err
			}
			break
		}
		switch {
		case strings.HasPrefix(line, "\t"):
			if cur != nil {
				if long {
					cur.Oversize = true
				}
				msg.WriteByte('\n')
				msg.WriteString(line[1:])
			}
		case cur == nil && !strings.Contains(line, auditPrefix):
			// most lines of a log are not pgaudit's: they are matched against the prefix only while an entry is open
		default:
			m := prefixRE.FindStringSubmatch(line)
			if cur != nil {
				emit(false, m != nil && auditFollows(m[7]) && m[6] == strconv.Itoa(cur.PID))
			}
			if m == nil {
				break
			}
			first := stripSQLState(m[8])
			if !strings.HasPrefix(first, auditPrefix) {
				break
			}
			at, ok := auditTime(m[1], m[2], loc)
			if !ok {
				break
			}
			pid, _ := strconv.Atoi(m[6])
			cur = &AuditEntry{At: at, Client: m[3], User: m[4], Database: m[5], PID: pid, Oversize: long,
				Key: m[1] + " " + m[2] + "|" + m[7] + "|" + m[6] + "|" + first}
			if long { // the key is the first line's: of an oversize one, the part kept
				cur.Key = m[1] + " " + m[2] + "|" + m[7] + "|" + m[6] + "|" + first[:min(len(first), 512)]
			}
			msg.Reset()
			msg.WriteString(first)
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				return err
			}
			break
		}
	}
	emit(true, false)
	return nil
}

// ParseAudit returns the pgaudit entries of log text (ScanAudit into a list), the Forged ones among them.
func ParseAudit(r io.Reader, loc *time.Location) ([]AuditEntry, error) {
	var out []AuditEntry
	err := ScanAudit(r, loc, func(e AuditEntry) { out = append(out, e) })
	return out, err
}

// AuditObject is what one statement of an entry's text acted on (AuditTargets).
type AuditObject struct {
	Type string // ROLE, SETTING, or the object keyword of a GRANT (TABLE, SCHEMA, ...); "" when the statement names none
	Name string
	Role string // the grantees of a GRANT / REVOKE; the role SET ROLE or SET SESSION AUTHORIZATION takes
}

// AuditTargets reads from an entry's statement text what the entry acted on, for the classes whose object pgaudit
// does not name. The names are identifiers, never a literal, so they can be kept without the statement.
//
//   - CREATE / ALTER / DROP ROLE (USER, GROUP): type ROLE, the role's name (a DROP's list, comma separated; the
//     keywords ALL, CURRENT_USER, CURRENT_ROLE and SESSION_USER in upper case, which no unquoted role name is);
//   - GRANT / REVOKE: the object after ON ('TABLE public.account' is type TABLE, name public.account; a longer form
//     stays as written: 'ALL TABLES IN SCHEMA app') or, for a role membership, the roles granted (type ROLE); Role
//     is the grantee list after TO / FROM;
//   - SET / RESET (LogClass MISC_SET): type SETTING and the setting's name, never its value; SET ROLE and SET
//     SESSION AUTHORIZATION are the settings role and session_authorization with the role they take in Role (none
//     for NONE and DEFAULT, which take no role).
//
// One result per statement of the text that the entry's command tag can name. pgaudit 17 and 18 write each
// statement's own text, so there is one. Releases 13 to 16 write the whole text of a multi-statement string on every
// entry of it: 'SET a = 1; SET b = 2' gives two entries with that text, and each of them gets both results - the
// text does not say which statement an entry is. A statement of another command (the CREATE TABLE before a GRANT)
// is never a result.
//
// Nothing is read (nil) from an entry of another class, from one without statement text (pgaudit.log_statement
// off), and from a text the reader cannot split with certainty: a plain '...' literal that holds a backslash ends
// at a different quote under standard_conforming_strings = off, so what looks like a second statement there can be
// the inside of a literal. A role's name is not read where pgaudit's own redaction may have cut it: pgaudit cuts the
// text of a CREATE or ALTER ROLE at the first 'password' it finds, in a role's name as well (CREATE ROLE
// password_bot is written 'CREATE ROLE password <REDACTED>').
func AuditTargets(e AuditEntry) []AuditObject {
	class := e.LogClass()
	if e.Statement == "" || (class != AuditRole && class != AuditMiscSet) {
		return nil
	}
	tokens, sure := sqlTokens(e.Statement)
	if !sure {
		return nil
	}
	cut := -1 // where pgaudit's redaction cut the text
	if strings.Contains(e.Statement, "<REDACTED>") {
		cut = strings.Index(strings.ToLower(e.Statement), "password")
	}
	var out []AuditObject
	for _, t := range splitStatements(tokens) {
		if !statementIs(t, class, e.Command) {
			continue
		}
		var o AuditObject
		switch {
		case class == AuditMiscSet:
			o.Type, o.Name, o.Role = setTarget(t)
		case t[0].is("GRANT") || t[0].is("REVOKE"):
			o.Type, o.Name, o.Role = grantTarget(t)
		default:
			names, end := roleNames(t[2:], t[0].is("DROP"))
			if cut >= 0 && end > cut && !t[0].is("DROP") {
				names = "" // the name runs into the cut: it may be the head of a longer one
			}
			if names != "" {
				o.Type, o.Name = "ROLE", names
			}
		}
		if o.Name != "" || o.Role != "" {
			out = append(out, o)
		}
	}
	return out
}

// AuditTarget is the entry's object and role: pgaudit's own object fields where it wrote them, else what
// AuditTargets reads from the statement. When several statements of the text can be the entry's and they do not
// agree, nothing is read from the text (the entry keeps pgaudit's fields and no role).
func AuditTarget(e AuditEntry) (objectType, objectName, role string) {
	objectType, objectName = e.ObjectType, e.ObjectName
	ts := AuditTargets(e)
	if len(ts) == 0 {
		return objectType, objectName, ""
	}
	for _, o := range ts[1:] {
		if o != ts[0] {
			return objectType, objectName, ""
		}
	}
	if objectName == "" && ts[0].Name != "" {
		objectName = ts[0].Name
		if objectType == "" {
			objectType = ts[0].Type
		}
	}
	return objectType, objectName, ts[0].Role
}

// splitStatements cuts a token list at the semicolons outside parentheses; empty statements are dropped.
func splitStatements(t []sqlToken) [][]sqlToken {
	var out [][]sqlToken
	start, depth := 0, 0
	for i, x := range t {
		if !x.punct {
			continue
		}
		switch x.text {
		case "(":
			depth++
		case ")":
			depth--
		case ";":
			if depth <= 0 {
				if i > start {
					out = append(out, t[start:i])
				}
				start, depth = i+1, 0
			}
		}
	}
	if start < len(t) {
		out = append(out, t[start:])
	}
	return out
}

// statementIs says whether a statement can be the one an entry's command tag names: a SET for SET, a RESET for
// RESET; CREATE / ALTER / DROP ROLE (USER, GROUP; never USER MAPPING) for that tag; a GRANT or REVOKE with ON for the
// tags GRANT and REVOKE, without ON for GRANT ROLE and REVOKE ROLE (a membership). An entry with no command tag
// takes any statement of its class.
func statementIs(t []sqlToken, class, command string) bool {
	if len(t) == 0 {
		return false
	}
	roleDDL := func(verb string) bool {
		return len(t) > 2 && t[0].is(verb) && (t[1].is("ROLE") || t[1].is("USER") || t[1].is("GROUP")) &&
			(!t[1].is("USER") || !t[2].is("MAPPING"))
	}
	grant := func(verb string, membership bool) bool {
		if !t[0].is(verb) {
			return false
		}
		on, _ := grantCut(t)
		return (on < 0) == membership
	}
	if class == AuditMiscSet {
		if command == "" {
			return t[0].is("SET") || t[0].is("RESET")
		}
		return t[0].is(command)
	}
	switch command {
	case "CREATE ROLE":
		return roleDDL("CREATE")
	case "ALTER ROLE":
		return roleDDL("ALTER")
	case "DROP ROLE":
		return roleDDL("DROP")
	case "GRANT":
		return grant("GRANT", false)
	case "REVOKE":
		return grant("REVOKE", false)
	case "GRANT ROLE":
		return grant("GRANT", true)
	case "REVOKE ROLE":
		return grant("REVOKE", true)
	case "":
		return roleDDL("CREATE") || roleDDL("ALTER") || roleDDL("DROP") || t[0].is("GRANT") || t[0].is("REVOKE")
	}
	return false
}

// sqlToken is a word, a quoted identifier or one punctuation character of a statement; a string literal is the
// token lit (its text is never kept). end is the offset in the statement after the token.
type sqlToken struct {
	text   string
	quoted bool // a "quoted identifier"
	punct  bool
	lit    bool
	end    int
}

// is compares an unquoted word with a keyword, case-blind.
func (t sqlToken) is(kw string) bool {
	return !t.quoted && !t.punct && !t.lit && strings.EqualFold(t.text, kw)
}

// ident renders a name token as PostgreSQL would resolve it: an unquoted word folded to lower case, a quoted one in
// its quotes unless it is a plain lower-case name.
func (t sqlToken) ident() string {
	if !t.quoted {
		return strings.ToLower(t.text)
	}
	plain := t.text != ""
	for i, c := range t.text {
		if (c < 'a' || c > 'z') && c != '_' && (i == 0 || c < '0' || c > '9') {
			plain = false
			break
		}
	}
	if plain {
		return t.text
	}
	return `"` + strings.ReplaceAll(t.text, `"`, `""`) + `"`
}

// roleIdent is ident for a role: the keywords that stand for roles stay keywords, in upper case (a role of such a
// name has to be written in quotes, and then reads in lower case).
func (t sqlToken) roleIdent() string {
	for _, kw := range []string{"ALL", "CURRENT_USER", "CURRENT_ROLE", "SESSION_USER"} {
		if t.is(kw) {
			return kw
		}
	}
	return t.ident()
}

// sqlTokens splits a statement: comments dropped, a string literal (plain, E-prefixed, dollar-quoted) reduced to one
// lit token, at most 400 tokens (the statements read here name their target near the start). sure is false when a
// plain literal holds a backslash: where it ends then depends on standard_conforming_strings, and so does everything
// after it.
func sqlTokens(s string) (out []sqlToken, sure bool) {
	sure = true
	for i := 0; i < len(s) && len(out) < 400; {
		c := s[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f':
			i++
		case c == '-' && i+1 < len(s) && s[i+1] == '-':
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			depth := 1
			i += 2
			for i < len(s) && depth > 0 {
				switch {
				case s[i] == '/' && i+1 < len(s) && s[i+1] == '*':
					depth++
					i += 2
				case s[i] == '*' && i+1 < len(s) && s[i+1] == '/':
					depth--
					i += 2
				default:
					i++
				}
			}
		case c == '"':
			var b strings.Builder
			i++
			for i < len(s) {
				if s[i] == '"' {
					if i+1 < len(s) && s[i+1] == '"' {
						b.WriteByte('"')
						i += 2
						continue
					}
					i++
					break
				}
				b.WriteByte(s[i])
				i++
			}
			out = append(out, sqlToken{text: b.String(), quoted: true, end: i})
		case c == '\'':
			escapes := len(out) > 0 && out[len(out)-1].is("E") && out[len(out)-1].end == i
			end := skipSQLString(s, i, escapes)
			if !escapes && strings.IndexByte(s[i:end], '\\') >= 0 {
				sure = false
			}
			i = end
			if escapes {
				out = out[:len(out)-1] // the E of E'...' is part of the literal
			}
			out = append(out, sqlToken{lit: true, end: i})
		case c == '$':
			if end := dollarQuoteEnd(s, i); end > i {
				i = end
				out = append(out, sqlToken{lit: true, end: i})
			} else {
				i++
				out = append(out, sqlToken{text: "$", punct: true, end: i})
			}
		case isWordByte(c):
			j := i
			for j < len(s) && (isWordByte(s[j]) || s[j] == '$') {
				j++
			}
			out = append(out, sqlToken{text: s[i:j], end: j})
			i = j
		default:
			i++
			out = append(out, sqlToken{text: s[i-1 : i], punct: true, end: i})
		}
	}
	return out, sure
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c >= 0x80
}

// skipSQLString returns the index after the string literal that starts at s[i] (a quote); a doubled quote stays
// inside it, and so does a backslash-escaped one in an E-prefixed string.
func skipSQLString(s string, i int, escapes bool) int {
	i++
	for i < len(s) {
		switch {
		case escapes && s[i] == '\\' && i+1 < len(s):
			i += 2
		case s[i] == '\'':
			if i+1 < len(s) && s[i+1] == '\'' {
				i += 2
				continue
			}
			return i + 1
		default:
			i++
		}
	}
	return i
}

// dollarQuoteEnd returns the index after a dollar-quoted string that starts at s[i] ($$...$$, $tag$...$tag$), or i
// when s[i] does not start one (a $1 parameter).
func dollarQuoteEnd(s string, i int) int {
	j := i + 1
	for j < len(s) && isWordByte(s[j]) && (j != i+1 || s[j] < '0' || s[j] > '9') {
		j++
	}
	if j >= len(s) || s[j] != '$' {
		return i
	}
	tag := s[i : j+1]
	if end := strings.Index(s[j+1:], tag); end >= 0 {
		return j + 1 + end + len(tag)
	}
	return len(s)
}

// settingAt reads a setting's name at t[i] (a.b for an extension's): lower case and without quotes however it was
// written, as the server looks a setting up (SET "PGAUDIT.LOG" sets pgaudit.log).
func settingAt(t []sqlToken, i int) string {
	if i >= len(t) || t[i].punct || t[i].lit {
		return ""
	}
	name := strings.ToLower(t[i].text)
	i++
	for i+1 < len(t) && t[i].punct && t[i].text == "." && !t[i+1].punct && !t[i+1].lit {
		name += "." + strings.ToLower(t[i+1].text)
		i += 2
	}
	return name
}

// roleNames reads the role of CREATE / ALTER ROLE or the list of DROP ROLE [IF EXISTS] a, b, and the offset in the
// statement after the last name read.
func roleNames(t []sqlToken, list bool) (string, int) {
	i, end := 0, 0
	if i+1 < len(t) && t[i].is("IF") && t[i+1].is("EXISTS") {
		i += 2
	}
	var names []string
	for i < len(t) && !t[i].punct && !t[i].lit {
		names = append(names, t[i].roleIdent())
		end = t[i].end
		i++
		if !list || i >= len(t) || !t[i].punct || t[i].text != "," {
			break
		}
		i++
	}
	return strings.Join(names, ", "), end
}

// grantTarget reads a GRANT or a REVOKE: what it is on and the roles it names after TO / FROM. What it is on is the
// text after ON - a single object keyword becomes the type ('TABLE public.account' is type TABLE, name
// public.account), a longer form stays as written ('ALL TABLES IN SCHEMA app') - or, for a membership grant, the
// roles granted (type ROLE).
func grantTarget(t []sqlToken) (typ, target, roles string) {
	on, cut := grantCut(t)
	if cut < 0 {
		return "", "", ""
	}
	if on >= 0 {
		what := t[on+1 : cut]
		if len(what) > 1 && !what[0].quoted && !what[0].punct && !what[0].lit && grantObjectTypes[strings.ToUpper(what[0].text)] {
			typ, target = strings.ToUpper(what[0].text), joinTokens(what[1:], false)
		} else {
			target = joinTokens(what, true)
		}
	} else {
		// REVOKE ADMIN OPTION FOR r FROM x: the option words are not roles
		start := 1
		for i := 1; i < cut; i++ {
			if t[i].is("FOR") {
				start = i + 1
			}
		}
		typ, target = "ROLE", joinTokens(t[start:cut], false)
	}
	end := len(t)
	for i := cut + 1; i < len(t); i++ {
		if t[i].is("WITH") || t[i].is("GRANTED") || t[i].is("CASCADE") || t[i].is("RESTRICT") {
			end = i
			break
		}
	}
	var names []string
	for i := cut + 1; i < end; i++ {
		if t[i].is("GROUP") || t[i].punct || t[i].lit {
			continue
		}
		names = append(names, t[i].roleIdent())
	}
	return typ, target, strings.Join(names, ", ")
}

// grantCut finds, outside parentheses, the ON of a GRANT or a REVOKE (-1: a role membership) and the TO or FROM
// that starts its grantees (-1: none, the statement is cut).
func grantCut(t []sqlToken) (on, cut int) {
	sep := "TO"
	if t[0].is("REVOKE") {
		sep = "FROM"
	}
	on, cut = -1, -1
	depth := 0
	for i := 1; i < len(t) && cut < 0; i++ {
		switch {
		case t[i].punct && t[i].text == "(":
			depth++
		case t[i].punct && t[i].text == ")":
			depth--
		case depth == 0 && on < 0 && t[i].is("ON"):
			on = i
		case depth == 0 && t[i].is(sep):
			cut = i
		}
	}
	return on, cut
}

// grantObjectTypes are the single keywords GRANT ... ON takes before one kind of object's names.
var grantObjectTypes = map[string]bool{
	"TABLE": true, "SEQUENCE": true, "DATABASE": true, "DOMAIN": true, "SCHEMA": true, "TABLESPACE": true, "TYPE": true,
	"LANGUAGE": true, "FUNCTION": true, "PROCEDURE": true, "ROUTINE": true,
}

// joinTokens writes tokens back as text: names as PostgreSQL resolves them, a dot tight, a comma followed by a
// space; with keywords, an unquoted word that is an object keyword of GRANT stays upper case.
func joinTokens(t []sqlToken, keywords bool) string {
	var b strings.Builder
	for i, x := range t {
		switch {
		case x.lit:
			continue
		case x.punct:
			if x.text == "," {
				b.WriteString(", ")
			} else {
				b.WriteString(x.text)
			}
			continue
		}
		if i > 0 && b.Len() > 0 {
			if last := b.String()[b.Len()-1]; last != '.' && last != ' ' && last != '(' {
				b.WriteByte(' ')
			}
		}
		if keywords && !x.quoted && grantKeywords[strings.ToUpper(x.text)] {
			b.WriteString(strings.ToUpper(x.text))
		} else {
			b.WriteString(x.ident())
		}
	}
	return strings.TrimSpace(b.String())
}

// grantKeywords are the words GRANT ... ON takes before an object's name.
var grantKeywords = map[string]bool{
	"TABLE": true, "TABLES": true, "ALL": true, "IN": true, "SCHEMA": true, "SEQUENCE": true, "SEQUENCES": true,
	"DATABASE": true, "DOMAIN": true, "FOREIGN": true, "DATA": true, "WRAPPER": true, "SERVER": true, "FUNCTION": true,
	"FUNCTIONS": true, "PROCEDURE": true, "PROCEDURES": true, "ROUTINE": true, "ROUTINES": true, "LANGUAGE": true,
	"LARGE": true, "OBJECT": true, "PARAMETER": true, "TABLESPACE": true, "TYPE": true,
}

// setTarget reads a SET or a RESET: the setting's name, and the role of SET ROLE / SET SESSION AUTHORIZATION (none
// for a literal, and for NONE and DEFAULT, which give the session's own role back).
func setTarget(t []sqlToken) (typ, name, role string) {
	roleAt := func(i int, keyword string) string {
		if i >= len(t) || t[i].punct || t[i].lit || t[i].is(keyword) {
			return ""
		}
		return t[i].roleIdent()
	}
	// the forms whose setting is not their first word
	special := func(i int) (string, string, bool) {
		switch {
		case i >= len(t):
			return "", "", true
		case t[i].is("SESSION") && i+1 < len(t) && t[i+1].is("AUTHORIZATION"):
			return "session_authorization", roleAt(i+2, "DEFAULT"), true
		case t[i].is("SESSION") && i+1 < len(t) && t[i+1].is("CHARACTERISTICS"):
			return "transaction", "", true
		case t[i].is("ROLE"):
			return "role", roleAt(i+1, "NONE"), true
		case t[i].is("TIME") && i+1 < len(t) && t[i+1].is("ZONE"):
			return "timezone", "", true
		case t[i].is("XML") && i+1 < len(t) && t[i+1].is("OPTION"):
			return "xmloption", "", true
		case t[i].is("TRANSACTION"):
			return "transaction", "", true
		case t[i].is("CONSTRAINTS"):
			return "constraints", "", true
		case t[i].is("NAMES"):
			return "client_encoding", "", true
		case t[i].is("SCHEMA") && i+1 < len(t) && t[i+1].lit:
			return "search_path", "", true
		}
		return "", "", false
	}
	i := 1
	if t[0].is("RESET") {
		n, _, ok := special(i)
		if !ok {
			n = settingAt(t, i)
		}
		if n == "" {
			return "", "", ""
		}
		return "SETTING", n, "" // a RESET takes no role
	}
	if !t[0].is("SET") {
		return "", "", ""
	}
	if n, r, ok := special(i); ok {
		if n == "" {
			return "", "", ""
		}
		return "SETTING", n, r
	}
	if t[i].is("LOCAL") || t[i].is("SESSION") {
		i++
		if n, r, ok := special(i); ok {
			if n == "" {
				return "", "", ""
			}
			return "SETTING", n, r
		}
	}
	n := settingAt(t, i)
	if n == "" {
		return "", "", ""
	}
	return "SETTING", n, ""
}
