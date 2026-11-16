package collect

import (
	"github.com/aachaemenes/pgvigil/internal/logparse"
	"hash/fnv"
	"html"
	"regexp"
	"sort"
	"strings"
	"unicode"
)

// Query-text policy (config query_text: full | normalized | none). Statement text is the one thing a
// monitor stores that can carry data: a literal in a WHERE clause, a value in an INSERT. "full" keeps
// the text as the server shows it, credentials masked (MaskCredentials, under every mode); "normalized" replaces
// every literal with ? and drops comments before the text leaves the collector, and keys the text by a
// hash of that normalized form (one row per statement shape, nothing of the raw text kept); "none"
// stores no statement text and no text hash at all, only the counters. The policy runs in RunOnce on
// every row, after the collector and before the import, so each collector stays unaware of it.

// textPolicyKeys are the row columns that hold statement text: activity and statements rows carry
// query; log rows carry statement and detail (a deadlock's detail quotes the other process's statement).
var textPolicyKeys = []string{"query", "statement", "detail"}

// credentialKeys are the row columns the credential mask runs over under every mode: the statement text keys, the
// slow capture's statement shape, a message (a log line or a read's error can quote a connection string), the
// Extended Events reports (a deadlock's graph and a blocked process report hold each process's input buffer) and a
// plan (its text, and every string of its JSON form). A new text path puts its text under one of these keys (task 415).
var credentialKeys = []string{"query", "statement", "detail", "shape", "message", "graph", "report", "plan_text", "plan"}

// The credential mask (task 415). Every form below is replaced by <masked> in the text of every row, under every
// text policy, on both engines, before the row leaves the collector:
//   - a private key block: -----BEGIN ... PRIVATE KEY----- (PGP, PEM, RSA, EC ...) to its END line, or to the end of a
//     text the server or a text cap cut before it;
//   - every string literal of a call of a function that takes a key, a passphrase or a password: pgcrypto's pgp_sym_*,
//     pgp_pub_decrypt*, encrypt*, decrypt*, hmac and crypt; SQL Server's ENCRYPTBYPASSPHRASE, DECRYPTBYPASSPHRASE,
//     DECRYPTBYCERT, DECRYPTBYASYMKEY, DECRYPTBYKEYAUTOCERT, DECRYPTBYKEYAUTOASYMKEY, SIGNBYCERT, SIGNBYASYMKEY;
//     and every literal of a positional EXEC of sp_addlogin, sp_password, sp_addlinkedsrvlogin, sp_addapprole,
//     sp_approlepassword, sp_setapprole up to the statement's end (a call by name is the keyword rule's);
//   - the value after PASSWORD =, SECRET =, KEY_SOURCE =, IDENTITY_VALUE =, IDENTIFIED BY, a password-named T-SQL
//     parameter (@rmtpassword = N'...') and PostgreSQL's PASSWORD '...' after ROLE / USER / GROUP / WITH /
//     ENCRYPTED / UNENCRYPTED, when it is a literal or a 0x value;
//   - key = value, key: value or key => value where the key holds password, passwd, pwd, secret, passfile or sslkey
//     (a connection string, libpq's keywords, SQLCMDPASSWORD with or without spaces, a named argument p_password =>);
//   - the password of a URI's user:password@;
//   - a command line's -P inside a sqlcmd, bcp, osql or isql command (the value bare, quoted or in T-SQL's doubled
//     quotes), -Password, -pw and -pwd; ConvertTo-SecureString's string; net use's password; dtexec's /DE and /Decrypt.
//
// An XML document (a SQL Server showplan, an Extended Events deadlock graph or blocked process report) is masked by
// MaskXML, value by value, so it stays XML; it also masks a plan's compiled and runtime value of a password-named @
// parameter. A cell that is a processing instruction (a community procedure's <?query ... ?> or <?query_plan ... ?>)
// is taken for a document too, and MaskXML masks the instruction's text.
//
// Inside a literal (dynamic SQL, an xp_cmdshell command, a connection string) a value in T-SQL's doubled quotes
// (two single quotes on each side of it) is one value, and the quote that closes the enclosing literal never starts one: the mask knows the text's
// literals before it looks for a value. It is a text rule: a password stored as an ordinary column value stays under
// full and is gone under normalized and none. Idempotent: a second pass changes nothing.
var (
	maskKeyBlockRE = regexp.MustCompile(`(?s)-----BEGIN (?:PGP PRIVATE KEY BLOCK|[A-Z0-9 ]*PRIVATE KEY)-----.*?(?:-----END (?:PGP PRIVATE KEY BLOCK|[A-Z0-9 ]*PRIVATE KEY)-----|\z)`)
	maskFuncRE     = regexp.MustCompile(`(?i)\b(?:pgp_sym_encrypt(?:_bytea)?|pgp_sym_decrypt(?:_bytea)?|pgp_pub_decrypt(?:_bytea)?|encrypt(?:_iv)?|decrypt(?:_iv)?|hmac|crypt|encryptbypassphrase|decryptbypassphrase|decryptbycert|decryptbyasymkey|decryptbykeyautocert|decryptbykeyautoasymkey|signbycert|signbyasymkey)\s*\(`)
	maskNamedArgRE = regexp.MustCompile(`@\w+\s*=`)
	maskProcRE     = regexp.MustCompile(`(?i)\b(?:sp_addlogin|sp_password|sp_addlinkedsrvlogin|sp_addapprole|sp_approlepassword|sp_setapprole)\b`)
	maskKeywordRE  = regexp.MustCompile(`(?i)(?:\bPASSWORD\b\s*(=\s*)?|\bSECRET\s*=\s*|\bKEY_SOURCE\s*=\s*|\bIDENTITY_VALUE\s*=\s*|\bIDENTIFIED\s+BY\s+|@\w*(?:password|passwd|pwd|secret)\w*\s*=\s*)`)
	maskRoleCtxRE  = regexp.MustCompile(`(?i)\b(?:ROLE|USER|GROUP|WITH|ENCRYPTED|UNENCRYPTED)\s+(?:(?:"[^"]*"|[^\s'"]+)\s+)?$`)
	maskPairRE     = regexp.MustCompile(`(?i)\b\w*(?:password|passwd|pwd|secret|passfile|sslkey)\w*\s*(=>|=|:)\s*`)
	maskURIRE2     = regexp.MustCompile(`(://[^:/@\s'"]+:)([^@\s/'"]+)(@)`)
	maskArgRE2     = regexp.MustCompile(`(?:^|[\s'"])((?i:-Password|-pwd|-pw)\b|-P)\s*`)
	maskCmdRE      = regexp.MustCompile(`(?i)\b(?:sqlcmd|bcp|osql|isql)\b`)
	maskSecureRE2  = regexp.MustCompile(`(?i)(ConvertTo-SecureString\s+(?:-String\s+)?)("[^"]*"|'[^']*'|\S+)`)
	maskNetUseRE2  = regexp.MustCompile(`(?i)(\bnet\s+use\s+\S+\s+)([^/\s]\S*)`)
	maskDtsRE2     = regexp.MustCompile(`(?i)(/(?:DE|Decrypt)\s+)("[^"]*"|\S+)`)
	maskPlanParmRE = regexp.MustCompile(`(?is)<ColumnReference\b[^>]*\bColumn="@\w*(?:password|passwd|pwd|secret)\w*"[^>]*>`)
	maskPlanValRE  = regexp.MustCompile(`(Parameter(?:Compiled|Runtime)Value=")[^"]*(")`)
)

const masked = "<masked>"

// MaskCredentials is s with every credential in the forms above replaced by <masked>.
func MaskCredentials(s string) string {
	if s == "" {
		return s
	}
	s = maskKeyBlockRE.ReplaceAllString(s, masked)
	s = maskCalls(s)
	s = maskKeywordValues(s)
	s = maskPairs(s)
	s = maskURIRE2.ReplaceAllString(s, "${1}"+masked+"${3}")
	s = maskArgs(s)
	s = maskSecureRE2.ReplaceAllString(s, "${1}"+masked)
	s = maskNetUseRE2.ReplaceAllString(s, "${1}"+masked)
	return maskDtsRE2.ReplaceAllString(s, "${1}"+masked)
}

// MaskXML is the credential mask of an XML document: a SQL Server showplan, an Extended Events deadlock graph or a
// blocked process report. MaskCredentials over the document's text would write a raw <masked> into an attribute value
// or a text node, and the stored document would no longer be XML (the Plan cache's .sqlplan, the deadlock graph and the
// blocked process report pages parse it). Each attribute value and each text node is decoded, masked as MaskCredentials
// masks a text, and written back escaped only when the mask changed it (<masked> as &lt;masked&gt;), so the document
// stays XML and every value the mask leaves alone keeps its bytes. A showplan's ColumnReference of a password-named @
// parameter has its compiled and runtime values masked, and a statement whose text holds a credential word (password,
// passwd, pwd, secret: a parameter's or a column's name) - or is cut at the showplan's length, or has none (a live
// plan), and lists no parameter -
// has its expressions' literals and its auto-parameters' values masked too (OPTION (RECOMPILE) compiles a value in as a
// constant, simple parameterization lists a literal as @1; maskPlanCredStatements, run first, over the text as it came in).
//
// A CDATA section, a comment and a processing instruction hold raw text and are masked as they stand (<masked> inside
// one keeps the document XML). An instruction can be a whole cell: sp_WhoIsActive's formatted output writes a
// session's sql_text and sql_command as <?query -- ... --?> (its non-formatted output has no wrapper) and the
// DarlingData procedures write a statement as <?query ... ?> - a statement like any other. Such a cell is SQL
// Server's own writing and not always XML: a "?>" inside the statement is written as it is, so where an instruction
// ends is piEnd's rule, with its limits. A showplan an instruction wraps (sp_WhoIsActive's <?query_plan ... ?>) is
// masked as a document from <ShowPlanXML on (maskRaw), one level deep.
//
// A document the text ends inside is no longer XML: cut inside a tag, the rest is decoded and masked as a text; cut
// inside a comment, a CDATA section or an instruction, the rest is raw and masked as it stands. Idempotent, as
// MaskCredentials is.
func MaskXML(s string) string { return maskXML(s, false) }

// maskXML is MaskXML; inPlan: s is a showplan an instruction wraps, where a wrapper is not followed again.
func maskXML(s string, inPlan bool) string {
	if s == "" {
		return s
	}
	s = maskPlanCredStatements(s)
	var b strings.Builder
	b.Grow(len(s))
	// opens: where an instruction that opens the text begins (only white space before it); noEnd: a scan found no
	// "?>" that markup or the text's end follows, and none stands further on either (piEnd)
	opens, noEnd := len(s)-len(strings.TrimLeft(s, " \t\r\n")), false
	for i := 0; i < len(s); {
		lt := strings.IndexByte(s[i:], '<')
		if lt < 0 {
			b.WriteString(maskXMLText(s[i:]))
			break
		}
		b.WriteString(maskXMLText(s[i : i+lt]))
		i += lt
		rest := s[i:]
		// open: the section's opening when rest begins a comment, a CDATA section or an instruction (raw text)
		open, closing := "", ""
		switch {
		case strings.HasPrefix(rest, "<!--"):
			open, closing = "<!--", "-->"
		case strings.HasPrefix(rest, "<![CDATA["):
			open, closing = "<![CDATA[", "]]>"
		case strings.HasPrefix(rest, "<?"):
			open, closing = "<?", "?>"
		}
		end := -1
		switch {
		case open == "<?":
			end = piEnd(rest, i == opens, &noEnd)
		case open != "":
			if e := strings.Index(rest[len(open):], closing); e >= 0 {
				end = len(open) + e + len(closing)
			}
		default:
			end = xmlTagEnd(rest)
		}
		if end < 0 {
			if open != "" {
				b.WriteString(open + maskRaw(open, rest[len(open):], inPlan))
			} else {
				b.WriteString(maskXMLCut(rest))
			}
			break
		}
		if open != "" {
			b.WriteString(open + maskRaw(open, rest[len(open):end-len(closing)], inPlan) + closing)
		} else {
			b.WriteString(maskXMLTag(rest[:end]))
		}
		i += end
	}
	return b.String()
}

// piEnd is the length of the processing instruction s begins with (s starts "<?"); -1 when s holds no end of it.
// XML ends an instruction at its first "?>", but SQL Server writes a "?>" inside an instruction's text as it is (a
// statement that holds one, in a community procedure's <?query ... ?> cell: a password with those two characters, an
// XML document in a literal), and ending there leaves the rest of the statement behind - the tail of a value, or a
// statement whose quotes are then read inside out, its credentials kept. So:
//
//   - The cell is the instruction. One that opens the text (opens) and is not the XML declaration ends at the text's
//     last "?>" when only white space follows that one: the whole statement is masked as one text, and a second pass
//     finds the same end. Where the text does not end so, it ends at the first "?>" that markup follows (a document
//     that opens with an instruction), and where there is none the text ends inside it (-1: a cell cut at the
//     collector's cap is the statement still).
//   - Any other instruction (the declaration; one inside a document) ends at the first "?>" that white space and
//     then "<" or the text's end follows, as markup follows an instruction in the documents stored here; where no
//     "?>" is followed so, at the first one.
//
// noEnd is the caller's, one for a text: once a scan has found no "?>" followed so, none stands further on either,
// and a later instruction is not scanned again (a text of many such instructions is read once).
//
// The limits that remain: a cell INSIDE a document whose statement holds a "?>" that "<" follows (an XML declaration
// in a literal) still ends there, and what follows is masked as tags and text, its quotes read inside out - a
// credential there can stay; a cell cut after such a "?>" the same; a document with text right after an instruction
// (mixed content) ends it at a later "?>" that markup follows, and what stands between is masked raw; a document
// that opens with an instruction other than the declaration and ends with one is taken for one cell. None of the
// stored kinds (a showplan, a deadlock graph, a blocked process report) has one of these shapes, and no further end
// rule is added for a shape nothing stores: code that comes to store a document with a statement's instruction
// inside it owes the narrower end for that shape first (sp_WhoIsActive's own: a line end and then "--?>"). The docs
// say the four (security.html, 'Known limits of that mask').
func piEnd(s string, opens bool, noEnd *bool) int {
	first := strings.Index(s[2:], "?>")
	if first < 0 {
		return -1
	}
	first += 4
	cell := opens && !xmlDeclaration(s)
	if cell {
		if t := strings.TrimRight(s, " \t\r\n"); strings.HasSuffix(t, "?>") {
			return len(t)
		}
	}
	if !*noEnd {
		for end := first; ; {
			if t := strings.TrimLeft(s[end:], " \t\r\n"); t == "" || t[0] == '<' {
				return end
			}
			e := strings.Index(s[end:], "?>")
			if e < 0 {
				break
			}
			end += e + 2
		}
		*noEnd = true
	}
	if cell {
		return -1
	}
	return first
}

// xmlDeclaration: s begins with the XML declaration (<?xml and then white space or its end), not with an instruction
// whose target merely starts so.
func xmlDeclaration(s string) bool {
	return len(s) > 5 && s[:5] == "<?xml" && strings.IndexByte(" \t\r\n?", s[5]) >= 0
}

// maskRaw masks the raw text of a comment, a CDATA section or a processing instruction (body is what stands after
// open): MaskCredentials over it as it stands, nothing decoded. A showplan an instruction wraps - sp_WhoIsActive
// writes a plan that cannot be an xml value as <?query_plan ... ?>, to be saved as a .sqlplan file - is masked as
// the document it is from "<ShowPlanXML" on: a password-named parameter's values are masked (the text mask has no
// rule for them), and a masked value is written escaped, so the plan taken out of the wrapper stays XML. One level:
// inside such a plan (inPlan) an instruction is raw text and no more, so a text of wrappers inside wrappers costs
// one pass and no depth.
func maskRaw(open, body string, inPlan bool) string {
	if open == "<?" && !inPlan {
		if k := strings.Index(body, "<ShowPlanXML"); k >= 0 {
			return MaskCredentials(body[:k]) + maskXML(body[k:], true)
		}
	}
	return MaskCredentials(body)
}

// xmlTagEnd is the length of the tag s begins with (s[0] is '<'), its quoted values skipped; -1 when s ends inside it.
func xmlTagEnd(s string) int {
	var q byte
	for j := 1; j < len(s); j++ {
		switch c := s[j]; {
		case q != 0:
			if c == q {
				q = 0
			}
		case c == '"' || c == '\'':
			q = c
		case c == '>':
			return j + 1
		}
	}
	return -1
}

// xmlAttrRE is one attribute and its value, in double or in single quotes.
var xmlAttrRE = regexp.MustCompile(`(\s[A-Za-z_][\w.:-]*\s*=\s*")([^"]*)(")|(\s[A-Za-z_][\w.:-]*\s*=\s*')([^']*)(')`)

// maskXMLTag masks each attribute value of one tag, then a password-named plan parameter's values.
func maskXMLTag(tag string) string {
	tag = xmlAttrRE.ReplaceAllStringFunc(tag, func(m string) string {
		g := xmlAttrRE.FindStringSubmatch(m)
		head, val, q := g[1], g[2], g[3]
		if head == "" {
			head, val, q = g[4], g[5], g[6]
		}
		if val == "" {
			return m
		}
		dec := html.UnescapeString(val)
		if mv := MaskCredentials(dec); mv != dec {
			return head + xmlAttrEscape(mv) + q
		}
		return m
	})
	if maskPlanParmRE.MatchString(tag) {
		tag = maskPlanValRE.ReplaceAllString(tag, "${1}"+xmlAttrEscape("'"+masked+"'")+"${2}")
	}
	return tag
}

// maskXMLText masks one text node: decoded, masked, escaped again when the mask changed it.
func maskXMLText(t string) string {
	if strings.TrimSpace(t) == "" {
		return t
	}
	dec := html.UnescapeString(t)
	if mv := MaskCredentials(dec); mv != dec {
		return xmlTextEscape(mv)
	}
	return t
}

// maskXMLCut masks the rest of a document cut inside a tag: decoded first, so a literal SQL Server wrote as &apos;
// is one, and written raw (the document is no longer XML).
func maskXMLCut(t string) string {
	dec := html.UnescapeString(t)
	if mv := MaskCredentials(dec); mv != dec {
		return mv
	}
	return t
}

// xmlAttrEscape writes a value for an attribute: the five entities and the line ends as SQL Server writes them.
func xmlAttrEscape(v string) string {
	var b strings.Builder
	for _, r := range v {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		case '\'':
			b.WriteString("&apos;")
		case '\r':
			b.WriteString("&#xD;")
		case '\n':
			b.WriteString("&#xA;")
		case '\t':
			b.WriteString("&#x9;")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// xmlTextEscape writes a text node's value: &, < and >.
func xmlTextEscape(v string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(v)
}

// looksXML: s begins (after white space) with a tag, a declaration, a processing instruction or a comment. A statement
// or a message of either engine does not - but a cell a community procedure writes as an instruction (<?query ... ?>)
// does, and MaskXML masks its text as the statement it is. PostgreSQL's placeholders (<IDLE>, <insufficient
// privilege>) read as one tag with nothing to mask.
func looksXML(s string) bool {
	t := strings.TrimLeft(s, " \t\r\n")
	if len(t) < 2 || t[0] != '<' {
		return false
	}
	c := t[1]
	return c == '?' || c == '!' || c == '_' || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}

// maskStored is the credential mask of one stored value: MaskXML for an XML document, MaskCredentials otherwise.
func maskStored(s string) string {
	if looksXML(s) {
		return MaskXML(s)
	}
	return MaskCredentials(s)
}

// litSpan is one string literal of a text, by byte offsets: start (its prefix letter or its opening quote), end (after
// its closing quote; the text's end when unterminated).
type litSpan struct{ start, end int }

// literalSpans lists the top-level string literals of s in one pass, as normalizeSQL reads them: comments (-- to the
// end of the line, /* */ nested) and double-quoted identifiers are skipped, '...' doubles a quote, E'...' takes
// backslash escapes, N'...' / B'...' / X'...' are prefixed forms, $tag$...$tag$ matches its tag exactly; an
// unterminated literal runs to the end. Every delimiter is ASCII, so byte offsets are safe in UTF-8 text.
func literalSpans(s string) []litSpan {
	var out []litSpan
	n := len(s)
	for i := 0; i < n; {
		c := s[i]
		switch {
		case c == '-' && i+1 < n && s[i+1] == '-':
			for i < n && s[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < n && s[i+1] == '*':
			depth := 1
			i += 2
			for i < n && depth > 0 {
				switch {
				case s[i] == '/' && i+1 < n && s[i+1] == '*':
					depth++
					i += 2
				case s[i] == '*' && i+1 < n && s[i+1] == '/':
					depth--
					i += 2
				default:
					i++
				}
			}
		case c == '"':
			j := i + 1
			for j < n && (s[j] != '"' || (j+1 < n && s[j+1] == '"')) {
				if s[j] == '"' {
					j++
				}
				j++
			}
			i = j + 1
		default:
			if j, ok := literalAtB(s, i); ok {
				out = append(out, litSpan{i, j})
				i = j
				continue
			}
			i++
		}
	}
	return out
}

func identByte(c byte) bool {
	return c == '_' || c == '$' || c == '@' || c == '#' || (c >= '0' && c <= '9') || (c|0x20 >= 'a' && c|0x20 <= 'z') || c >= 0x80
}

// literalAtB says whether a literal opens at s[i] and returns the index after it ('...', N'...', E'...', B'/X'...,
// $tag$...$tag$); a prefix letter that ends a longer word is not a prefix.
func literalAtB(s string, i int) (int, bool) {
	n := len(s)
	if i >= n {
		return i, false
	}
	identBefore := i > 0 && identByte(s[i-1])
	switch c := s[i]; {
	case c == '\'':
		return skipQuotedB(s, i, false), true
	case (c == 'N' || c == 'n' || c == 'B' || c == 'b' || c == 'X' || c == 'x') && i+1 < n && s[i+1] == '\'' && !identBefore:
		return skipQuotedB(s, i+1, false), true
	case (c == 'E' || c == 'e') && i+1 < n && s[i+1] == '\'' && !identBefore:
		return skipQuotedB(s, i+1, true), true
	case c == '$' && !identBefore && i+1 < n && (s[i+1] < '0' || s[i+1] > '9'):
		j := i + 1
		for j < n && (s[j] == '_' || (s[j]|0x20 >= 'a' && s[j]|0x20 <= 'z') || (j > i+1 && s[j] >= '0' && s[j] <= '9') || s[j] >= 0x80) {
			j++
		}
		if j < n && s[j] == '$' {
			tag := s[i : j+1]
			if end := strings.Index(s[j+1:], tag); end >= 0 {
				return j + 1 + end + len(tag), true
			}
			return n, true
		}
	}
	return i, false
}

// skipQuotedB is skipQuoted over bytes: the index after the literal whose quote is s[i].
func skipQuotedB(s string, i int, backslash bool) int {
	n := len(s)
	for j := i + 1; j < n; {
		switch {
		case backslash && s[j] == '\\':
			j += 2
		case s[j] == '\'':
			if j+1 < n && s[j+1] == '\'' {
				j += 2
				continue
			}
			return j + 1
		default:
			j++
		}
	}
	return n
}

// enclosing is the literal that holds offset p after its opening quote (start < p < end), if any.
func enclosing(spans []litSpan, p int) (litSpan, bool) {
	k := sort.Search(len(spans), func(i int) bool { return spans[i].end > p })
	if k < len(spans) && spans[k].start < p {
		return spans[k], true
	}
	return litSpan{}, false
}

// closeAt is where the enclosing literal's body ends: its closing quote, or the text's end when unterminated.
func closeAt(s string, l litSpan) int {
	if l.end > 0 && l.end <= len(s) && s[l.end-1] == '\'' && l.end-1 > l.start {
		return l.end - 1
	}
	return l.end
}

// innerValue is the value that starts at p inside an enclosing literal: one in T-SQL's doubled quotes (up to the next
// pair or the literal's end), else a bare word up to a space, ; , ) " or a quote. The end offset and whether it is
// the doubled-quote form; ok false = no value.
func innerValue(s string, p, stop int) (end int, doubled bool, ok bool) {
	if p >= stop {
		return p, false, false
	}
	if strings.HasPrefix(s[p:stop], "''") {
		if k := strings.Index(s[p+2:stop], "''"); k >= 0 {
			return p + 2 + k + 2, true, true
		}
		return stop, true, true
	}
	if s[p] == '"' { // a value in double quotes (an OLE DB connection string's Pwd="..."): to its closing quote, quotes included
		if k := strings.IndexByte(s[p+1:stop], '"'); k >= 0 {
			return p + 1 + k + 1, false, true
		}
		return stop, false, true
	}
	j := p
	for j < stop && !strings.ContainsRune(" \t\r\n;,)\"'", rune(s[j])) {
		j++
	}
	return j, false, j > p
}

type edit struct {
	from, to int
	with     string
}

// apply makes non-overlapping edits (in offset order; an edit overlapping an earlier one is dropped).
func apply(s string, eds []edit) string {
	if len(eds) == 0 {
		return s
	}
	sort.SliceStable(eds, func(i, j int) bool { return eds[i].from < eds[j].from })
	var b strings.Builder
	b.Grow(len(s))
	at := 0
	for _, e := range eds {
		if e.from < at || e.to < e.from {
			continue
		}
		b.WriteString(s[at:e.from])
		b.WriteString(e.with)
		at = e.to
	}
	b.WriteString(s[at:])
	return b.String()
}

// maskLiteralsIn masks every literal in s[from:to]: inside an enclosing literal the doubled-quote ones,
// outside it the top-level ones.
func maskLiteralsIn(s string, spans []litSpan, from, to int, eds []edit) []edit {
	if l, in := enclosing(spans, from); in {
		stop := closeAt(s, l)
		if to > stop {
			to = stop
		}
		for p := from; p < to; {
			if strings.HasPrefix(s[p:to], "''") {
				end, _, _ := innerValue(s, p, to)
				eds = append(eds, edit{p, end, "''" + masked + "''"})
				p = end
				continue
			}
			p++
		}
		return eds
	}
	// outside a literal: every literal that opens in the range, found by walking it (the span list skips "..." regions,
	// where a plan's StatementText keeps its statement)
	for p := from; p < to; {
		if e, ok := literalAtB(s, p); ok {
			eds = append(eds, edit{p, e, "'" + masked + "'"})
			p = e
			continue
		}
		p++
	}
	return eds
}

// maskCalls masks the literals of a key-taking function call (to its closing parenthesis, or the end) and of an EXEC
// of a password-taking procedure (to the statement's end: a ; or a line break outside a literal, or the end).
func maskCalls(s string) string {
	fl := maskFuncRE.FindAllStringIndex(s, -1)
	pl := maskProcRE.FindAllStringIndex(s, -1)
	if fl == nil && pl == nil {
		return s
	}
	spans := literalSpans(s)
	var eds []edit
	for _, loc := range fl {
		open := loc[1] // after '('
		stop := len(s)
		if l, in := enclosing(spans, loc[0]); in {
			stop = closeAt(s, l)
		}
		depth, j := 1, open
		for j < stop && depth > 0 {
			if e, ok := literalAtB(s, j); ok && !isInside(spans, loc[0]) {
				j = e
				continue
			}
			if strings.HasPrefix(s[j:stop], "''") {
				end, _, _ := innerValue(s, j, stop)
				j = end
				continue
			}
			switch s[j] {
			case '(':
				depth++
			case ')':
				depth--
			}
			j++
		}
		eds = maskLiteralsIn(s, spans, open, j, eds)
	}
	for _, loc := range pl {
		stop := len(s)
		if l, in := enclosing(spans, loc[0]); in {
			stop = closeAt(s, l)
		}
		end := loc[1]
		for end < stop {
			if e, ok := literalAtB(s, end); ok && !isInside(spans, loc[0]) {
				end = e
				continue
			}
			if s[end] == ';' || s[end] == '\n' {
				break
			}
			end++
		}
		// a call by name (@loginame = ..., @passwd = ...) is the keyword rule's: only a positional call's literals are all masked
		if maskNamedArgRE.MatchString(s[loc[1]:end]) {
			continue
		}
		eds = maskLiteralsIn(s, spans, loc[1], end, eds)
	}
	return apply(s, eds)
}

func isInside(spans []litSpan, p int) bool { _, in := enclosing(spans, p); return in }

// maskKeywordValues masks the literal or 0x value after a password keyword. Outside a literal: a literal that opens
// right after the keyword; the =-less PASSWORD only after ROLE / USER / GROUP / WITH / ENCRYPTED / UNENCRYPTED.
// Inside one: a value in doubled quotes, or (after an =) a bare word; never the enclosing literal's closing quote.
func maskKeywordValues(s string) string {
	locs := maskKeywordRE.FindAllStringSubmatchIndex(s, -1)
	if locs == nil {
		return s
	}
	spans := literalSpans(s)
	var eds []edit
	for _, loc := range locs {
		kw, at := loc[0], loc[1]
		word := strings.ToUpper(strings.TrimSpace(s[kw:min(kw+8, len(s))]))
		bare := strings.HasPrefix(word, "PASSWORD") && loc[2] < 0 // PASSWORD without its =
		byForm := strings.HasPrefix(word, "IDENTIFI")
		if l, in := enclosing(spans, kw); in {
			stop := closeAt(s, l)
			end, doubled, ok := innerValue(s, at, stop)
			if !ok || ((bare || byForm) && !doubled) {
				continue
			}
			if bare && !maskRoleCtxRE.MatchString(s[l.start:kw]) {
				continue
			}
			if doubled {
				eds = append(eds, edit{at, end, "''" + masked + "''"})
			} else {
				eds = append(eds, edit{at, end, masked})
			}
			continue
		}
		if bare && !maskRoleCtxRE.MatchString(s[max(0, kw-200):kw]) {
			continue
		}
		if e, ok := literalAtB(s, at); ok {
			eds = append(eds, edit{at, e, "'" + masked + "'"})
			continue
		}
		if at+2 < len(s) && s[at] == '0' && (s[at+1] == 'x' || s[at+1] == 'X') && isHexB(s[at+2]) {
			j := at + 2
			for j < len(s) && isHexB(s[j]) {
				j++
			}
			eds = append(eds, edit{at, j, "'" + masked + "'"})
		}
	}
	return apply(s, eds)
}

func isHexB(c byte) bool { return (c >= '0' && c <= '9') || (c|0x20 >= 'a' && c|0x20 <= 'f') }

// maskPairs masks the value of a password-named key = value, key: value or key => value. Inside a literal: a
// doubled-quote value or a bare word; outside: a "..." value, a literal, or a bare word. A '::' cast is not a pair, and
// a value already masked is left as it is.
func maskPairs(s string) string {
	locs := maskPairRE.FindAllStringSubmatchIndex(s, -1)
	if locs == nil {
		return s
	}
	spans := literalSpans(s)
	var eds []edit
	for _, loc := range locs {
		at := loc[1]
		if s[loc[2]:loc[3]] == ":" && ((loc[3] < len(s) && s[loc[3]] == ':') || (loc[2] > 0 && s[loc[2]-1] == ':')) {
			continue // password::text is a cast
		}
		var end int
		var with string
		if l, in := enclosing(spans, loc[0]); in {
			e, doubled, ok := innerValue(s, at, closeAt(s, l))
			if !ok {
				continue
			}
			end, with = e, masked
			if doubled {
				with = "''" + masked + "''"
			}
		} else {
			switch {
			case at < len(s) && s[at] == '"':
				end = len(s)
				if k := strings.IndexByte(s[at+1:], '"'); k >= 0 {
					end = at + 1 + k + 1
				}
				with = masked
			default:
				if e, ok := literalAtB(s, at); ok {
					end, with = e, "'"+masked+"'"
				} else {
					end = at
					for end < len(s) && !strings.ContainsRune(" \t\r\n;,()'\"", rune(s[end])) {
						end++
					}
					with = masked
				}
			}
		}
		if end <= at || strings.Contains(s[at:end], masked) {
			continue
		}
		eds = append(eds, edit{at, end, with})
	}
	return apply(s, eds)
}

// maskArgs masks a command line's password switch: -P inside a sqlcmd / bcp / osql / isql command (the command word
// before it in the same literal, or in the text when outside one), -Password, -pw and -pwd anywhere.
func maskArgs(s string) string {
	locs := maskArgRE2.FindAllStringSubmatchIndex(s, -1)
	if locs == nil {
		return s
	}
	spans := literalSpans(s)
	var eds []edit
	for _, loc := range locs {
		sw := s[loc[2]:loc[3]]
		at := loc[1]
		l, in := enclosing(spans, loc[2])
		if sw == "-P" {
			ctx := s[:loc[2]]
			if in {
				ctx = s[l.start:loc[2]]
			}
			if !maskCmdRE.MatchString(ctx) {
				continue
			}
		}
		var end int
		var with = masked
		if in {
			e, _, ok := innerValue(s, at, closeAt(s, l))
			if !ok {
				continue
			}
			end = e
		} else {
			switch {
			case at < len(s) && s[at] == '"':
				end = len(s)
				if k := strings.IndexByte(s[at+1:], '"'); k >= 0 {
					end = at + 1 + k + 1
				}
			case at < len(s) && s[at] == '\'':
				end = skipQuotedB(s, at, false)
			default:
				end = at
				for end < len(s) && !strings.ContainsRune(" \t\r\n", rune(s[end])) {
					end++
				}
			}
		}
		if end <= at || s[at:end] == masked {
			continue
		}
		eds = append(eds, edit{at, end, with})
	}
	return apply(s, eds)
}

// maskRowCredentials runs the credential mask over a row's text columns (credentialKeys), whatever the policy; a
// plan's JSON form (a map or a list) has every string inside it masked.
func maskRowCredentials(r Row) {
	for _, k := range credentialKeys {
		switch v := r[k].(type) {
		case string:
			if v != "" {
				if m := maskStored(v); m != v {
					r[k] = m
				}
			}
		case map[string]any, []any:
			r[k] = maskAny(v)
		}
	}
}

// maskAny masks every string of a decoded JSON value.
func maskAny(v any) any {
	switch x := v.(type) {
	case string:
		return maskStored(x)
	case map[string]any:
		for k, e := range x {
			x[k] = maskAny(e)
		}
	case []any:
		for i, e := range x {
			x[i] = maskAny(e)
		}
	}
	return v
}

// ApplyTextPolicy is the instance's query-text policy for another engine's collector package: the same rewrite
// RunOnce applies to a PostgreSQL collection's rows.
func ApplyTextPolicy(rows []Row, mode string) { applyTextPolicy(rows, mode) }

// applyTextPolicy rewrites the text columns of rows in place according to mode; an unknown or empty
// mode is "full" (the credential mask alone). A row that keys its text by query_hash (activity) gets the hash of
// the normalized text under normalized, so identical shapes share one query_text row and the raw
// text's fingerprint is not kept, and no hash at all under none. The credential mask runs first under every mode
// (task 415): under full it is all that changes the text, and a server-side hash (query_hash under full) stays.
func applyTextPolicy(rows []Row, mode string) {
	for _, r := range rows {
		maskRowCredentials(r)
	}
	if mode == "" || mode == "full" {
		return
	}
	for _, r := range rows {
		// the detail of a corruption event and of the pganalyze classes' events is the server's own message (a damaged
		// page, a temp file's size, a crash's signal, a conflict's reason: logparse keeps any statement text out of it,
		// in "statement", which follows the policy below), so it stays whole; a plan carries the statement's text and
		// literals and a normalized plan loses its shape and every number, so plans are stored under full only
		kind, _ := r["kind_of"].(string)
		if kind == "plan" {
			r["statement"] = nil
		}
		// a log event's message shape (logparse.MessageShape, 0079) masks quoted text, numbers and any token with a
		// digit or an @, but a free-text message can still carry words: none stores no message. An 'error' event's
		// detail quotes the server's DETAIL / CONTEXT lines (Key (email)=(...), Failing row contains (...)), which the
		// SQL normalizer cannot mask: normalized stores none of it (the message shape groups the event).
		// (log events only: a collector_error's message is the reason the run's note names, an AlwaysOn event's the server's)
		if _, has := r["message"]; has && mode == "none" && r["kind"] == "event" {
			r["message"] = nil
		}
		if kind == "error" && mode == "normalized" {
			r["detail"] = nil
		}
		for _, k := range textPolicyKeys {
			if k == "detail" && logparse.DetailIsMessage(logparse.Kind(kind)) {
				continue
			}
			v, ok := r[k]
			if !ok || v == nil {
				continue
			}
			s, isStr := v.(string)
			if !isStr {
				continue
			}
			switch mode {
			case "none":
				r[k] = nil
			case "normalized":
				r[k] = normalizeSQL(s)
			}
		}
		if _, has := r["query_hash"]; has {
			switch mode {
			case "none":
				r["query_hash"] = nil
			case "normalized":
				if q, ok := r["query"].(string); ok && q != "" {
					r["query_hash"] = textHash(q)
				} else {
					r["query_hash"] = nil
				}
			}
		}
	}
}

// textHash keys normalized text: FNV-64a as a signed 64-bit value (the column is bigint). It differs
// from the server-side hashtextextended used under full, so a repository that switches modes keeps two
// key spaces; each row joins its own text row either way.
func textHash(s string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(s))
	return int64(h.Sum64())
}

var normInListRE = regexp.MustCompile(`(?i)(\bIN\s*)\(\s*\?(?:\s*,\s*\?)+\s*\)`)

// moneyEnd: in[i] is a digit after '$'; the end of a money literal with a decimal point ($12.50, and $12. with no
// fraction digits), or -1 when there is no point or a name follows it ($1.name, $1."col": a PostgreSQL parameter's
// field), never a money literal.
func moneyEnd(in []rune, i int) int {
	for i < len(in) && unicode.IsDigit(in[i]) {
		i++
	}
	if i >= len(in) || in[i] != '.' {
		return -1
	}
	i++
	if i < len(in) && (unicode.IsLetter(in[i]) || in[i] == '_' || in[i] == '"') {
		return -1
	}
	for i < len(in) && unicode.IsDigit(in[i]) {
		i++
	}
	return i
}

// radixRun: the end of the digits of a radix literal whose letter is in[i] (x, o or b), '_' between digits.
func radixRun(in []rune, i int) int {
	letter, j := in[i], i+1
	for j < len(in) && (radixDigit(letter, in[j]) || in[j] == '_' && j+1 < len(in) && radixDigit(letter, in[j+1])) {
		j++
	}
	return j
}

// radixAt: in[i] is '0' and in[i+1] a radix letter that begins a literal - x always (T-SQL writes an empty binary
// value as 0x), o and b only with a digit of their base after them.
func radixAt(in []rune, i int) bool {
	if in[i+1] == 'x' || in[i+1] == 'X' {
		return true
	}
	return i+2 < len(in) && radixDigit(in[i+1], in[i+2])
}

// radixDigit: r is a digit of the base the letter names (x hexadecimal, o octal, b binary).
func radixDigit(letter, r rune) bool {
	switch letter {
	case 'x', 'X':
		return unicode.IsDigit(r) || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F'
	case 'o', 'O':
		return r >= '0' && r <= '7'
	}
	return r == '0' || r == '1'
}

// normalizeSQL rewrites one statement in a single pass over its runes: comments (-- to the end of the line, /* */
// nested) are dropped, string literals ('..' with ” doubling, E'..' with backslash escapes, B'..' X'..' N'..' U&'..',
// $tag$..$tag$ with the tag matched exactly), numbers (not a parameter $n, not part of an identifier; '_' between
// digits), 0x / 0o / 0b literals and money with a decimal point ($12.50) become ?, double-quoted identifiers stay
// whole, whitespace collapses to one space, and IN (?, ?, ...) collapses to IN (?). One pass, so an unpaired quote
// inside a comment or an escaped quote inside a string never desynchronises what follows. A text rule, not a parser: it
// is meant to keep data out of the repository, not to produce pg_stat_statements' exact form.
func normalizeSQL(s string) string {
	in := []rune(s)
	var out strings.Builder
	out.Grow(len(s))
	n := len(in)
	space := false // a pending space: emitted before the next token, never doubled or trailing
	emit := func(r rune) {
		if space && out.Len() > 0 {
			out.WriteByte(' ')
		}
		space = false
		out.WriteRune(r)
	}
	isIdent := func(r rune) bool { return r == '_' || r == '$' || unicode.IsLetter(r) || unicode.IsDigit(r) }
	prev := func(i int) rune { // the rune before position i (for the number and prefix rules)
		if i == 0 {
			return ' '
		}
		return in[i-1]
	}
	for i := 0; i < n; {
		c := in[i]
		switch {
		case unicode.IsSpace(c):
			space = true
			i++
		case c == '-' && i+1 < n && in[i+1] == '-': // line comment: dropped
			for i < n && in[i] != '\n' {
				i++
			}
			space = true
		case c == '/' && i+1 < n && in[i+1] == '*': // block comment, nested as Postgres nests them: dropped
			depth := 1
			i += 2
			for i < n && depth > 0 {
				switch {
				case in[i] == '/' && i+1 < n && in[i+1] == '*':
					depth++
					i += 2
				case in[i] == '*' && i+1 < n && in[i+1] == '/':
					depth--
					i += 2
				default:
					i++
				}
			}
			space = true
		case c == '"': // a quoted identifier stays whole ("" doubles a quote inside it)
			j := i + 1
			for j < n {
				if in[j] == '"' {
					if j+1 < n && in[j+1] == '"' {
						j += 2
						continue
					}
					break
				}
				j++
			}
			for k := i; k <= j && k < n; k++ {
				emit(in[k])
			}
			i = j + 1
		case c == '\'':
			i = skipQuoted(in, i, false)
			emit('?')
		case (c == 'e' || c == 'E') && i+1 < n && in[i+1] == '\'' && !isIdent(prev(i)): // E'..' with backslash escapes
			i = skipQuoted(in, i+1, true)
			emit('?')
		case (c == 'b' || c == 'B' || c == 'x' || c == 'X' || c == 'n' || c == 'N') && i+1 < n && in[i+1] == '\'' && !isIdent(prev(i)):
			i = skipQuoted(in, i+1, false)
			emit('?')
		case (c == 'u' || c == 'U') && i+2 < n && in[i+1] == '&' && in[i+2] == '\'' && !isIdent(prev(i)): // U&'..'
			i = skipQuoted(in, i+2, false)
			emit('?')
		case c == '$' && !isIdent(prev(i)) && i+2 < n && in[i+1] == '.' && unicode.IsDigit(in[i+2]):
			// money with no integer digits ($.5; TEXT-NOW-L review M1): never a parameter or a dollar quote
			j := i + 2
			for j < n && unicode.IsDigit(in[j]) {
				j++
			}
			emit('?')
			i = j
		case c == '$' && !isIdent(prev(i)) && i+1 < n && !unicode.IsDigit(in[i+1]): // $tag$ ... $tag$ (a $1 parameter falls through)
			j := i + 1
			for j < n && (in[j] == '_' || unicode.IsLetter(in[j]) || (j > i+1 && unicode.IsDigit(in[j]))) {
				j++
			}
			if j < n && in[j] == '$' {
				tag := string(in[i : j+1])
				rest := string(in[j+1:])
				if end := strings.Index(rest, tag); end >= 0 {
					i = j + 1 + len([]rune(rest[:end])) + len([]rune(tag))
					emit('?')
					continue
				}
			}
			emit(c) // not a dollar quote: a $ on its own
			i++
		case c == '$' && !isIdent(prev(i)) && i+1 < n && unicode.IsDigit(in[i+1]) && moneyEnd(in, i+1) >= 0:
			// T-SQL money with a decimal point ($12.50, $12., -$3.25: the sign stays, as a number's does); $1, $1.name and
			// $1."col", PostgreSQL's parameters, have no point or a name after it and fall through to stay as they are
			emit('?')
			i = moneyEnd(in, i+1)
		case c == '0' && i+1 < n && strings.ContainsRune("xXoObB", in[i+1]) && !isIdent(prev(i)) && prev(i) != '.' && radixAt(in, i):
			// a binary literal (T-SQL 0x..., an empty 0x too) or PostgreSQL 16's 0x / 0o / 0b integers, '_' between digits
			emit('?')
			i = radixRun(in, i+1)
		case c == '?' && i+1 < n && !isIdent(prev(i)) && (strings.ContainsRune("xXoObB", in[i+1]) && radixAt(in, i) || in[i+1] == '_' && i+2 < n && unicode.IsDigit(in[i+2])):
			// read-repair (TEXT-NOW-L review H1): a text the normalizer stored before 0x / 0o / 0b and '_' were literals
			// ('0xDEADBEEF' -> '?xDEADBEEF', '1_000' -> '?_000') is read again under normalized: the '?' takes the digits
			// it left behind
			emit('?')
			if in[i+1] == '_' {
				j := i + 1
				for j < n && (unicode.IsDigit(in[j]) || in[j] == '_' && j+1 < n && unicode.IsDigit(in[j+1])) {
					j++
				}
				i = j
			} else {
				i = radixRun(in, i+1)
			}
		case (unicode.IsDigit(c) || (c == '.' && i+1 < n && unicode.IsDigit(in[i+1]))) && !isIdent(prev(i)) && prev(i) != '.':
			j := i
			for j < n && (unicode.IsDigit(in[j]) || in[j] == '.' || in[j] == '_' && j+1 < n && unicode.IsDigit(in[j+1])) {
				j++
			}
			if j < n && (in[j] == 'e' || in[j] == 'E') && j+1 < n && (unicode.IsDigit(in[j+1]) || ((in[j+1] == '+' || in[j+1] == '-') && j+2 < n && unicode.IsDigit(in[j+2]))) {
				j += 2
				for j < n && (unicode.IsDigit(in[j]) || in[j] == '_' && j+1 < n && unicode.IsDigit(in[j+1])) { // PostgreSQL 16's 1e1_0 (review L1)
					j++
				}
			}
			emit('?')
			i = j
		default:
			emit(c)
			i++
		}
	}
	return normInListRE.ReplaceAllString(out.String(), "${1}(?)")
}

// skipQuoted returns the index after the string literal that opens at in[i] (a quote); ” always
// doubles a quote, and with backslash set (E'..') a backslash escapes the next rune. An unterminated
// literal runs to the end: everything after an open quote is literal, never SQL.
func skipQuoted(in []rune, i int, backslash bool) int {
	n := len(in)
	j := i + 1
	for j < n {
		switch {
		case backslash && in[j] == '\\':
			j += 2
		case in[j] == '\'':
			if j+1 < n && in[j+1] == '\'' {
				j += 2
				continue
			}
			return j + 1
		default:
			j++
		}
	}
	return n
}
