package logparse

import (
	"bufio"
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
// written with the class MISC whichever of misc and misc_set turned it on (pgaudit 18.0; LogClass names it). A field that holds a comma, a double quote or a line break is double-quoted
// and a quote inside it doubled; a statement of several lines continues on tab-led lines like any other entry.
// The statement is '<not logged>' under pgaudit.log_statement = off and '<previously logged>' for the later entries
// of one statement under pgaudit.log_statement_once; the parameters are '<none>', '<not logged>' (pgaudit.log_parameter
// off) or '<long param suppressed>'.

// Audit is the kind of a pgaudit entry. ParseIn does not return it (an AUDIT line is a LOG line no rule of
// classifyInto takes); ScanAudit reads them.
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

// LogClass is the pgaudit.log class an entry belongs to: the line's own class, but MISC_SET for a SET or a RESET,
// which pgaudit writes as MISC.
func (e AuditEntry) LogClass() string {
	if e.Class == AuditMisc && (e.Command == "SET" || e.Command == "RESET") {
		return AuditMiscSet
	}
	return e.Class
}

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
	// Key identifies the entry from its first line alone (time text, level, pid, message), as Event.Key does.
	Key string
}

const auditPrefix = "AUDIT: "

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

// ScanAudit reads log text in the prefix ParseIn reads ('%t:%r:%u@%d:[%p]:', the on-prem reader's rewrite included)
// and calls fn for every pgaudit entry, in the order of the log. loc is the server's log_timezone (ParseIn). Lines
// of other entries are passed over without being parsed.
func ScanAudit(r io.Reader, loc *time.Location, fn func(AuditEntry)) error {
	if loc == nil {
		loc = time.UTC
	}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	var cur *AuditEntry
	var msg strings.Builder
	flush := func() {
		if cur == nil {
			return
		}
		if e, ok := ParseAuditMessage(msg.String()); ok {
			e.At, e.Client, e.User, e.Database, e.PID, e.Key = cur.At, cur.Client, cur.User, cur.Database, cur.PID, cur.Key
			fn(e)
		}
		cur = nil
	}
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if strings.HasPrefix(line, "\t") {
			if cur != nil {
				msg.WriteByte('\n')
				msg.WriteString(line[1:])
			}
			continue
		}
		// a line with no prefix is passed over (ParseIn does the same); a prefixed one ends the entry before it. Most
		// lines of a log are not pgaudit's: they are matched against the prefix only while an entry is open
		if !strings.Contains(line, auditPrefix) {
			if cur != nil && prefixRE.MatchString(line) {
				flush()
			}
			continue
		}
		m := prefixRE.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		flush()
		if !strings.HasPrefix(m[8], auditPrefix) {
			continue
		}
		layout := "2006-01-02 15:04:05"
		if len(m[1]) > 19 {
			layout += ".999999"
		}
		at, err := time.ParseInLocation(layout, m[1], zoneOf(m[2], loc))
		if err != nil {
			continue
		}
		pid, _ := strconv.Atoi(m[6])
		cur = &AuditEntry{At: at, Client: m[3], User: m[4], Database: m[5], PID: pid,
			Key: m[1] + " " + m[2] + "|" + m[7] + "|" + m[6] + "|" + m[8]}
		msg.Reset()
		msg.WriteString(m[8])
	}
	flush()
	return sc.Err()
}

// ParseAudit returns the pgaudit entries of log text (ScanAudit into a list).
func ParseAudit(r io.Reader, loc *time.Location) ([]AuditEntry, error) {
	var out []AuditEntry
	err := ScanAudit(r, loc, func(e AuditEntry) { out = append(out, e) })
	return out, err
}

// AuditTarget names what an entry acted on where pgaudit's own object fields are empty, from the statement text:
// the names are identifiers, never a literal, so they are kept without the statement.
//
//   - CREATE / ALTER / DROP ROLE (USER, GROUP): object type ROLE, the role's name (a DROP's list, comma separated);
//   - GRANT / REVOKE: the object after ON ('TABLE public.account' is type TABLE, name public.account; a longer form
//     stays as written: 'ALL TABLES IN SCHEMA app') or, for a role membership, the roles granted (type ROLE); role
//     is the grantee list after TO / FROM;
//   - SET / RESET (LogClass MISC_SET): object type SETTING and the setting's name, never its value; SET ROLE and SET
//     SESSION AUTHORIZATION are the settings role and session_authorization with the role they take in role.
//
// An entry whose object pgaudit named keeps it; an entry without statement text (pgaudit.log_statement off) gives
// nothing more.
func AuditTarget(e AuditEntry) (objectType, objectName, role string) {
	objectType, objectName = e.ObjectType, e.ObjectName
	class := e.LogClass()
	if e.Statement == "" || (class != AuditRole && class != AuditMiscSet) {
		return objectType, objectName, ""
	}
	t := sqlTokens(e.Statement)
	if len(t) == 0 {
		return objectType, objectName, ""
	}
	var typ, name string
	switch {
	case class == AuditMiscSet:
		typ, name, role = setTarget(t)
	case t[0].is("GRANT") || t[0].is("REVOKE"):
		typ, name, role = grantTarget(t)
	case len(t) > 1 && (t[0].is("CREATE") || t[0].is("ALTER") || t[0].is("DROP")) && (t[1].is("ROLE") || t[1].is("USER") || t[1].is("GROUP")):
		typ, name = "ROLE", roleNames(t[2:], t[0].is("DROP"))
	}
	if objectName == "" && name != "" {
		objectName = name
		if objectType == "" {
			objectType = typ
		}
	}
	return objectType, objectName, role
}

// sqlToken is a word, a quoted identifier or one punctuation character of a statement; a string literal is the
// token lit (its text is never kept).
type sqlToken struct {
	text   string
	quoted bool // a "quoted identifier"
	punct  bool
	lit    bool
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
		if !(c >= 'a' && c <= 'z' || c == '_' || i > 0 && c >= '0' && c <= '9') {
			plain = false
			break
		}
	}
	if plain {
		return t.text
	}
	return `"` + strings.ReplaceAll(t.text, `"`, `""`) + `"`
}

// sqlTokens splits a statement: comments dropped, a string literal (plain, E-prefixed, dollar-quoted) reduced to one lit
// token, at most 400 tokens (the statements read here name their target near the start).
func sqlTokens(s string) []sqlToken {
	var out []sqlToken
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
			out = append(out, sqlToken{text: b.String(), quoted: true})
		case c == '\'':
			i = skipSQLString(s, i, len(out) > 0 && out[len(out)-1].is("E"))
			if n := len(out); n > 0 && out[n-1].is("E") {
				out = out[:n-1] // the E of E'...' is part of the literal
			}
			out = append(out, sqlToken{lit: true})
		case c == '$':
			if end := dollarQuoteEnd(s, i); end > i {
				i = end
				out = append(out, sqlToken{lit: true})
			} else {
				out = append(out, sqlToken{text: "$", punct: true})
				i++
			}
		case isWordByte(c):
			j := i
			for j < len(s) && (isWordByte(s[j]) || s[j] == '$') {
				j++
			}
			out = append(out, sqlToken{text: s[i:j]})
			i = j
		default:
			out = append(out, sqlToken{text: s[i : i+1], punct: true})
			i++
		}
	}
	return out
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
	for j < len(s) && (isWordByte(s[j]) && !(j == i+1 && s[j] >= '0' && s[j] <= '9')) {
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

// nameAt reads a possibly qualified name (a.b.c) at t[i] and returns it with the index after it; "" when t[i] is
// not a name.
func nameAt(t []sqlToken, i int) (string, int) {
	if i >= len(t) || t[i].punct || t[i].lit {
		return "", i
	}
	name := t[i].ident()
	i++
	for i+1 < len(t) && t[i].punct && t[i].text == "." && !t[i+1].punct && !t[i+1].lit {
		name += "." + t[i+1].ident()
		i += 2
	}
	return name, i
}

// roleNames reads the role of CREATE / ALTER ROLE or the list of DROP ROLE [IF EXISTS] a, b.
func roleNames(t []sqlToken, list bool) string {
	i := 0
	if i+1 < len(t) && t[i].is("IF") && t[i+1].is("EXISTS") {
		i += 2
	}
	var names []string
	for i < len(t) {
		n, next := nameAt(t, i)
		if n == "" {
			break
		}
		names = append(names, n)
		i = next
		if !list || i >= len(t) || !t[i].punct || t[i].text != "," {
			break
		}
		i++
	}
	return strings.Join(names, ", ")
}

// grantTarget reads a GRANT or a REVOKE: what it is on and the roles it names after TO / FROM. What it is on is the
// text after ON - a single object keyword becomes the type ('TABLE public.account' is type TABLE, name
// public.account), a longer form stays as written ('ALL TABLES IN SCHEMA app') - or, for a membership grant, the
// roles granted (type ROLE).
func grantTarget(t []sqlToken) (typ, target, roles string) {
	sep := "TO"
	if t[0].is("REVOKE") {
		sep = "FROM"
	}
	on, cut, depth := -1, -1, 0
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
		if t[i].is("WITH") || t[i].is("GRANTED") || t[i].is("CASCADE") || t[i].is("RESTRICT") || t[i].punct && t[i].text == ";" {
			end = i
			break
		}
	}
	var names []string
	for i := cut + 1; i < end; {
		if t[i].is("GROUP") || t[i].punct {
			i++
			continue
		}
		n, next := nameAt(t, i)
		if n == "" {
			i++
			continue
		}
		names = append(names, n)
		i = next
	}
	return typ, target, strings.Join(names, ", ")
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

// setTarget reads a SET or a RESET: the setting's name, and the role of SET ROLE / SET SESSION AUTHORIZATION.
func setTarget(t []sqlToken) (typ, name, role string) {
	i := 1
	if t[0].is("RESET") {
		switch {
		case i+1 < len(t) && t[i].is("SESSION") && t[i+1].is("AUTHORIZATION"):
			return "SETTING", "session_authorization", ""
		case i < len(t):
			n, _ := nameAt(t, i)
			return "SETTING", n, ""
		}
		return "", "", ""
	}
	if !t[0].is("SET") {
		return "", "", ""
	}
	if i < len(t) && (t[i].is("LOCAL") || t[i].is("SESSION")) {
		// SET SESSION AUTHORIZATION and SET SESSION CHARACTERISTICS are their own forms
		if t[i].is("SESSION") && i+1 < len(t) && t[i+1].is("AUTHORIZATION") {
			r, _ := nameAt(t, i+2)
			if i+2 < len(t) && t[i+2].lit {
				r = ""
			}
			return "SETTING", "session_authorization", r
		}
		if t[i].is("SESSION") && i+1 < len(t) && t[i+1].is("CHARACTERISTICS") {
			return "SETTING", "transaction", ""
		}
		i++
	}
	switch {
	case i >= len(t):
		return "", "", ""
	case t[i].is("ROLE"):
		r, _ := nameAt(t, i+1)
		if i+1 < len(t) && t[i+1].lit {
			r = ""
		}
		return "SETTING", "role", r
	case t[i].is("SESSION") && i+1 < len(t) && t[i+1].is("AUTHORIZATION"):
		r, _ := nameAt(t, i+2)
		if i+2 < len(t) && t[i+2].lit {
			r = ""
		}
		return "SETTING", "session_authorization", r
	case t[i].is("TIME") && i+1 < len(t) && t[i+1].is("ZONE"):
		return "SETTING", "timezone", ""
	case t[i].is("TRANSACTION"):
		return "SETTING", "transaction", ""
	case t[i].is("CONSTRAINTS"):
		return "SETTING", "constraints", ""
	case t[i].is("NAMES"):
		return "SETTING", "client_encoding", ""
	}
	n, _ := nameAt(t, i)
	return "SETTING", n, ""
}
