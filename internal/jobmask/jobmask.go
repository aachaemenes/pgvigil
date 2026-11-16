// Package jobmask masks the passwords and keys a job's text can carry - a step's command or code, a connection
// string, a run's output - on both engines. It imports nothing of pgvigil's, so the collectors (collect.MaskJobText)
// and the repository's migrations use the same rules.
package jobmask

import (
	"regexp"
	"strings"
)

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
//   - a command line's -Password, -pw, -pwd, -P on a line naming bcp, sqlcmd, osql or isql (a PowerShell -Path
//     stays), LiteSpeed's tools' --Key, --TgtKey, --JobP / -jobp and -BackupKey, and -K on a line naming one of
//     them (sqllitespeed, slssqlmaint, slsfastcompression, extractor: sqlcmd's -K ReadOnly stays); the string
//     given to ConvertTo-SecureString (each value bare, in quotes, or
//     inside another string with its quotes doubled, as in xp_cmdshell's string); the password of
//     'net use \\host\share <password>'; dtexec's /DE and /Decrypt.
//
// A value's form is read by its place (insideLiteral): inside another string its quotes are doubled, outside one
// they are not, so an empty value (two quotes) is never read as the text up to the next pair of quotes and an empty
// value inside a string (four quotes) stays that string's. A value its text never closes (a read or msdb cut it) is
// masked to the end of the text.
var (
	maskTSQLRE = regexp.MustCompile(`(?i)(\bPASSWORD|\bMEDIAPASSWORD|\bSECRET|@\w*(?:password|passwd|pwd|secret)\w*|@(?:EncryptionKey|jobp)\b)\s*=\s*`)
	maskSqbRE  = regexp.MustCompile(`(?i)\bsqbutility\s+1032(?:\s*,\s*(?:N?''(?:[^']|'''')*''|N?'(?:[^']|'')*'|[^,']*)){4}\s*,\s*`)
	maskKVRE   = regexp.MustCompile(`(?i)\b\w*(?:password|passwd|pwd|secret)\w*\s*[=:]\s*`)
	maskURIRE  = regexp.MustCompile(`(://[^:/@\s]+:)([^@\s/]+)(@)`)
	maskArgRE  = regexp.MustCompile(`(?:^|\s)(?i:-Password|-pwd|-pw|-BackupKey|-jobp|--JobP|--Key|--TgtKey)\b\s*`)
	maskArgPRE = regexp.MustCompile(`(?:^|\s)-P\s*`)
	maskArgKRE = regexp.MustCompile(`(?:^|\s)-K\s+`)
	// the tools whose -P is a password (a PowerShell -Path is not) and LiteSpeed's, whose -K is the key (sqlcmd's
	// -K ReadOnly is not), named as a command (not as Invoke-Sqlcmd)
	lineToolsP = regexp.MustCompile(`(?i)(?:^|[\s\\/'"(&$%{])(?:bcp|sqlcmd|osql|isql)(?:\.exe)?(?:\s|$|['"%}])`)
	lineToolsK = regexp.MustCompile(`(?i)(?:^|[\s\\/'"(&$%{])(?:sqllitespeed|slssqlmaint|slsfastcompression|extractor)(?:\.exe)?(?:\s|$|['"%}])`)
	// -P's rule never reads -Password, -Pwd or -Pw (names maskArgRE masks the value of): its value would be the name's rest
	notArgP      = regexp.MustCompile(`^-(?i:Password|pwd|pw)\b`)
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
	line   *regexp.Regexp // the rule only on a (logical) line this matches (the tool's name), nil = on any line
	unless *regexp.Regexp // not where the switch (from its -) matches this, nil = never
}

var (
	maskTSQL   = maskRule{name: maskTSQLRE, quoted: true, word: valWordTSQL, wordIf: nameBareKey, keep: valWordKeep}
	maskSqb    = maskRule{name: maskSqbRE, quoted: true, word: valWordTSQL, keep: valWordKeep}
	maskKV     = maskRule{name: maskKVRE, dq: true, word: valWordKV}
	maskArg    = maskRule{name: maskArgRE, dq: true, word: valWordArg}
	maskArgP   = maskRule{name: maskArgPRE, dq: true, word: valWordArg, line: lineToolsP, unless: notArgP}
	maskArgK   = maskRule{name: maskArgKRE, dq: true, word: valWordArg, line: lineToolsK}
	maskSecure = maskRule{name: maskSecureRE, dq: true, word: valWordArg}
)

// Text is a job's text with every password it carries, in the forms above, replaced by <masked>.
func Text(s string) string {
	s = maskTSQL.apply(s)
	s = maskSqb.apply(s)
	s = maskURIRE.ReplaceAllString(s, "${1}<masked>${3}")
	s = maskKV.apply(s)
	s = maskArg.apply(s)
	s = maskArgP.apply(s)
	s = maskArgK.apply(s)
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
		if !r.at(s, m) {
			continue
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

// at says whether the rule applies at match m of s: on its tool's line, and not at a switch it leaves to another rule.
func (r maskRule) at(s string, m []int) bool {
	if r.line == nil && r.unless == nil {
		return true
	}
	dash := m[0] + strings.IndexByte(s[m[0]:m[1]], '-')
	if r.unless != nil && r.unless.MatchString(s[dash:]) {
		return false
	}
	return r.line == nil || r.line.MatchString(lineAt(s, dash))
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

// Stored is a text an older build stored, masked again by today's rules: first a mark (<masked>) the older rules
// left inside a value - the rest of the value, its key, after the mark - is widened to the value's end (widen), then
// Text masks every form those rules did not know. The text is not always what Text makes from the job's own text
// today (the older mark keeps its shape), so a job's next read may write one version; it never leaves a key.
func Stored(s string) string { return Text(widen(s)) }

var (
	markRE = regexp.MustCompile(`('*)<masked>`)
	// the rest of a value after a mark the older rules made of its opening quotes (an empty literal taken at the
	// start of a doubled value): to the value's closing quotes, twice the mark's own, or the text's end
	restQ1 = regexp.MustCompile(`^(?:[^']|'''')*(?:''|$)`)
	restQ2 = regexp.MustCompile(`^(?:[^']|'{8})*(?:''''|$)`)
	// a bracketed value an older word rule cut at a space, a comma, a semicolon or a parenthesis: the rest to its ],
	// no [, quote or line break between
	restBracket = regexp.MustCompile(`^[\s,;)][^\[\]\n'"]*\]`)
)

// markEnds is what may follow a complete mark: the value ended there.
const markEnds = " \t\r\n,;)\"@}]+"

// widen drops the rest of each value an older build's rules masked only in part (see Stored), keeping its mark.
func widen(s string) string {
	ms := markRE.FindAllStringSubmatchIndex(s, -1)
	if ms == nil {
		return s
	}
	var in []bool
	var b strings.Builder
	last := 0
	for _, m := range ms {
		if m[0] < last {
			continue
		}
		q, end := m[3]-m[2], m[1]
		if q > 0 {
			if !strings.HasPrefix(s[end:], strings.Repeat("'", q)) {
				continue // not a mark the older rules made
			}
			end += q
		}
		rest, n := s[end:], 0
		switch {
		case rest == "":
		case q == 1 && !strings.ContainsRune(markEnds+"'", rune(rest[0])):
			n = len(restQ1.FindString(rest))
		case q == 2 && !strings.ContainsRune(markEnds+"'", rune(rest[0])):
			n = len(restQ2.FindString(rest))
		case q > 0:
		case rest[0] == '\'':
			// a word rule took the N of N'...': the literal after the mark. Inside a string a lone quote closes that
			// string (the older key = value rule stopped at it: the mark is complete); only a doubled value's
			// opening quotes followed by its text are the rest of a value there
			if in == nil {
				in = insideLiteral(s)
			}
			if !in[end] {
				n, _ = maskRule{}.value(rest, false, "")
			} else if len(rest) > 2 && rest[1] == '\'' && !strings.ContainsRune(markEnds+"'", rune(rest[2])) {
				n, _ = maskRule{}.value(rest, true, "")
			}
		case strings.ContainsRune(" \t,;)", rune(rest[0])):
			n = len(restBracket.FindString(rest))
		case !strings.ContainsRune(markEnds, rune(rest[0])):
			// a switch's rule took the opening quotes of a doubled value
			n = len(restQ1.FindString(rest))
		}
		if n == 0 {
			continue
		}
		b.WriteString(s[last:end])
		last = end + n
	}
	if last == 0 {
		return s
	}
	b.WriteString(s[last:])
	return b.String()
}

// agentLiteralRE is a SQL Server Agent job script's @command (a step's command) or @description (the job's) literal
// as the collector's agentScript writes it (internal/mssql tsqlN: N'...' with each quote of the text doubled).
var agentLiteralRE = regexp.MustCompile(`@(command|description) = N'((?:[^']|'')*)'`)

// GuardedCommand is what StoredScript leaves of a script's command that still holds a key after its masking; a
// description is left as @description = N'<masked: an older build stored this text unmasked>'.
const GuardedCommand = "@command = N'<masked: an older build stored this command unmasked>'"

// GuardedText is what StoredValue leaves of a text that still holds a key after its masking.
const GuardedText = "<masked: an older build stored this text unmasked>"

// StoredValue is a text an older build stored, masked again (Stored); a text that still holds a key after that
// (HoldsKey) is replaced whole by GuardedText.
func StoredValue(s string) string {
	if m := Stored(s); !HoldsKey(m) {
		return m
	}
	return GuardedText
}

// Prefilter is a pattern (case-insensitive; PostgreSQL's ~* and Go's (?is) read it alike) every text that Stored,
// StoredScript or StoredValue would change matches - each rule's name, the mark - also in a jsonb value's text form;
// a migration reads only the rows that match it.
const Prefilter = `pass|pwd|secret|key|jobp|<masked>|-p|-k|securestring|net.{0,6}use|/de|sqbutility|://[^[:space:]]*@`

// StoredScript is a job's stored script masked again. A SQL Server Agent script is decoded the way agentScript
// encodes it: each @command and @description literal's content is unescaped one level, masked as a step's text is
// (Stored), and escaped back; a text that still holds a key after that (HoldsKey: a form no rule reads, such as a key
// two levels of dynamic SQL deep) is replaced whole (GuardedCommand). A script without such a literal (pg_cron's,
// pgAgent's) is masked as a text (StoredValue).
func StoredScript(s string) string {
	if !agentLiteralRE.MatchString(s) {
		return StoredValue(s)
	}
	return agentLiteralRE.ReplaceAllStringFunc(s, func(lit string) string {
		g := agentLiteralRE.FindStringSubmatch(lit)
		cmd := strings.ReplaceAll(g[2], "''", "'")
		m := Stored(cmd)
		if HoldsKey(m) {
			if g[1] == "command" {
				return GuardedCommand
			}
			return "@" + g[1] + " = N'" + GuardedText + "'"
		}
		if m == cmd {
			return lit
		}
		return "@" + g[1] + " = N'" + strings.ReplaceAll(m, "'", "''") + "'"
	})
}

// HoldsKey reports whether s, already masked, still holds a value after a key's name: a name of the rules above
// (-P and -K on their tools' lines only) followed by a value that is neither <masked> nor empty, NULL, DEFAULT or a
// @variable, or text right after a <masked> mark inside the value (the rest of a value the rules read in part).
func HoldsKey(s string) bool {
	for _, r := range []maskRule{maskTSQL, maskSqb, maskKV, maskArg, maskArgP, maskArgK, maskSecure} {
		for _, m := range r.name.FindAllStringIndex(s, -1) {
			if !r.at(s, m) {
				continue
			}
			if keyAfter(s[m[1]:]) {
				return true
			}
		}
	}
	return false
}

// keyAfter: the value at the start of v is a key left unmasked (see HoldsKey).
func keyAfter(v string) bool {
	if len(v) > 1 && (v[0] == 'N' || v[0] == 'n') && v[1] == '\'' {
		v = v[1:]
	}
	v = strings.TrimLeft(v, `'["`)
	if rest, ok := strings.CutPrefix(v, "<masked>"); ok {
		if restBracket.MatchString(rest) {
			return true // a bracketed value's rest after a cut mark
		}
		rest = strings.TrimLeft(rest, `'"]`)
		return rest != "" && !strings.ContainsRune(markEnds, rune(rest[0]))
	}
	if v == "" || strings.ContainsRune(markEnds, rune(v[0])) || v[0] == '@' {
		return false
	}
	w := valWordTSQL.FindString(v)
	return w == "" || !valWordKeep.MatchString(w)
}

// lineAt is the logical line of s holding byte i: its physical line joined with the lines a continuation (cmd's ^,
// PowerShell's backtick, a shell's \ at a line's end) joins to it.
func lineAt(s string, i int) string {
	start := strings.LastIndexByte(s[:i], '\n') + 1
	for start > 0 && continued(s[:start-1]) {
		start = strings.LastIndexByte(s[:start-1], '\n') + 1
	}
	end := len(s)
	if j := strings.IndexByte(s[i:], '\n'); j >= 0 {
		end = i + j
	}
	for end < len(s) && continued(s[:end]) {
		end++
		if j := strings.IndexByte(s[end:], '\n'); j >= 0 {
			end += j
		} else {
			end = len(s)
		}
	}
	return s[start:end]
}

// continued: the text's last line ends in a continuation character (trailing spaces and a CR aside).
func continued(s string) bool {
	t := strings.TrimRight(s, " \t\r")
	return t != "" && strings.ContainsRune("`^\\", rune(t[len(t)-1]))
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
