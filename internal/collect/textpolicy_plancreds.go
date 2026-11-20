package collect

import (
	"html"
	"regexp"
	"strings"
)

// A showplan's ParameterList names each parameter's compiled value, and MaskXML masks a credential-named one's there
// (maskPlanParmRE). Elsewhere a credential's value is in a plan where nothing names it: under OPTION (RECOMPILE), or for a
// local variable, the value is compiled in as a constant of the statement's expressions (a seek's ScalarString and
// ConstValue, a conversion warning's Expression, the statement a linked server is sent as its RemoteQuery); a literal
// compared with a password column stays in the plan's expressions ('[password]=N'...'', where the text mask's pair rule
// stops at the bracket); and simple or forced parameterization lists the literal as an auto-parameter (@1, @0: the
// stored StatementText is then the parameterized text, read on SQL Server 2022 16.0.4325.4). So a statement whose own
// text holds a credential word - password, passwd, pwd or secret, in any name: a parameter, a column - has every literal
// of those expression attributes masked (strings, numbers and binary values alike: a number may be the secret) and the
// listed values of its auto-parameters and of its credential-named parameters (one with a non-ASCII letter in its name
// too), whether or not its plan lists the parameter (a live plan may carry both); and so does a statement whose text is
// cut at the plan's length and that lists no parameter (planStmtCut), or that has no text at all and lists none (a live
// plan, sys.dm_exec_query_statistics_xml, writes no StatementText: its constants are masked). The statement's text,
// every other attribute, and every other statement of the plan keep their bytes. The words are read from the document as it came in, before the
// tag pass masks it: that pass writes 'PasswordHash = @PasswordHash' as 'PasswordHash = <masked>'.
//
// The rule goes by the words in the statement's own text: a value copied into a variable or a parameter of a statement
// that holds none of them keeps its constants (docs/security.html, 'Known limits of that mask').

var (
	// planCredWordRE: a credential word anywhere in a statement's text (the words MaskCredentials' parameter form knows)
	planCredWordRE = regexp.MustCompile(`(?i)password|passwd|pwd|secret`)
	// planParamColRE: a ColumnReference's Column that is an auto-parameter (@0, @1, ...) or holds a credential word
	planParamColRE = regexp.MustCompile(`(?i)\sColumn\s*=\s*["']@(?:\d+["']|[^"']*(?:password|passwd|pwd|secret))`)
	// planExprAttrs: the attributes of a showplan that hold an expression with its constants (a Remote operator's
	// RemoteSource names the linked server and holds none)
	planExprAttrs = map[string]bool{"ScalarString": true, "ConstValue": true, "Expression": true, "RemoteQuery": true}
)

func isASCIILetter(c byte) bool { return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }

// xmlAttrName is the name in an xmlAttrRE head (' Name="', white space around the '=' allowed).
func xmlAttrName(head string) string {
	if k := strings.IndexByte(head, '='); k >= 0 {
		head = head[:k]
	}
	return strings.TrimSpace(head)
}

// planAttr is the decoded value of the attribute name in a start tag, and whether it is there.
func planAttr(tag, name string) (string, bool) {
	for _, g := range xmlAttrRE.FindAllStringSubmatch(tag, -1) {
		head, val := g[1], g[2]
		if head == "" {
			head, val = g[4], g[5]
		}
		if xmlAttrName(head) == name {
			return html.UnescapeString(val), true
		}
	}
	return "", false
}

// hasPlanExprAttr: the start tag may hold one of planExprAttrs (a cheap look before the attribute-by-attribute pass).
func hasPlanExprAttr(tag string) bool {
	for a := range planExprAttrs {
		if strings.Contains(tag, a) {
			return true
		}
	}
	return false
}

// planStmtCut is the length a showplan keeps of a statement's text (SQL Server 2022 16.0.4325.4 writes 3,999
// characters): a statement at it may name its credential parameter past the cut.
const planStmtCut = 3999

// maskPlanCredStatements is the statement pass of MaskXML, run over the document as it came in, before the tag pass:
// each showplan statement (a Stmt... start tag, up to the next one) whose StatementText holds a credential word - or is
// at the showplan's cut (planStmtCut) or absent (a live plan) and which lists no parameter, the shapes a credential
// compiled in where no word can be read leaves (locked down by default) - has its
// expression attributes' literals masked
// (maskPlanLiterals) and the listed values of its auto-parameters and credential-named parameters. The start tags are read as maskXML reads them (nextPlanTag); a tag
// the text ends inside ends the pass. One pass and no list of tags (a statement at the cut reads ahead to the next
// statement once); s itself comes back when nothing is masked. Idempotent: a masked literal reads back as itself.
func maskPlanCredStatements(s string) string {
	if !strings.Contains(s, "<Stmt") { // a showplan's statements; a live plan's carry no StatementText
		return s
	}
	var b strings.Builder
	pos, in, changed := 0, false, false // pos: s is written up to here; in: the tags read belong to a masked statement
	opens, noEnd := len(s)-len(strings.TrimLeft(s, " \t\r\n")), false
	for i := 0; ; {
		at, e, ok := nextPlanTag(s, i, opens, &noEnd)
		if !ok {
			break
		}
		tag := s[at : at+e]
		if strings.HasPrefix(tag, "<Stmt") {
			text, _ := planAttr(tag, "StatementText")
			// the words; a text cut at the plan's length, or no text at all (a live plan: sys.dm_exec_query_statistics_xml
			// writes none), with no ParameterList: the words cannot be read
			in = planCredWordRE.MatchString(text) || (text == "" || utf16Len(text) >= planStmtCut) && !planListsParams(s, at+e, opens, noEnd)
		}
		if in {
			m := tag
			if hasPlanExprAttr(tag) {
				m = maskPlanExprAttrs(tag)
			}
			if strings.HasPrefix(tag, "<ColumnReference") && planParamColRE.MatchString(tag) {
				m = maskPlanValRE.ReplaceAllString(m, "${1}"+xmlAttrEscape("'"+masked+"'")+"${2}")
			}
			if m != tag {
				if !changed {
					b.Grow(len(s) + len(s)/8)
					changed = true
				}
				b.WriteString(s[pos:at])
				b.WriteString(m)
				pos = at + e
			}
		}
		i = at + e
	}
	if !changed {
		return s
	}
	b.WriteString(s[pos:])
	return b.String()
}

// nextPlanTag is the next start tag of s from i on, read as maskXML reads a document: where it begins and its length.
// A comment's, a CDATA section's and an instruction's body is raw text, not tags (an instruction ends where piEnd
// says; opens and noEnd are piEnd's), and an end tag or a declaration holds no attributes of a statement. ok is false
// at the text's end, or where it ends inside a tag or a section.
func nextPlanTag(s string, i, opens int, noEnd *bool) (at, n int, ok bool) {
	for i < len(s) {
		lt := strings.IndexByte(s[i:], '<')
		if lt < 0 {
			return 0, 0, false
		}
		i += lt
		rest := s[i:]
		var end int // the length of the raw section rest begins with (each case below sets it)
		switch {
		case strings.HasPrefix(rest, "<!--"):
			if end = strings.Index(rest[4:], "-->"); end >= 0 {
				end += 4 + 3
			}
		case strings.HasPrefix(rest, "<![CDATA["):
			if end = strings.Index(rest[9:], "]]>"); end >= 0 {
				end += 9 + 3
			}
		case strings.HasPrefix(rest, "<?"):
			end = piEnd(rest, i == opens, noEnd)
		case len(rest) < 2 || !isASCIILetter(rest[1]):
			i++
			continue
		default:
			if e := xmlTagEnd(rest); e > 0 {
				return i, e, true
			}
			return 0, 0, false
		}
		if end < 0 {
			return 0, 0, false
		}
		i += end
	}
	return 0, 0, false
}

// planListsParams: the statement whose start tag ends at i has a ParameterList before the next statement begins (its
// own QueryPlan holds it, before any statement nested in it). noEnd is a copy: the look ahead leaves the pass's own.
func planListsParams(s string, i, opens int, noEnd bool) bool {
	for {
		at, e, ok := nextPlanTag(s, i, opens, &noEnd)
		if !ok {
			return false
		}
		tag := s[at : at+e]
		if strings.HasPrefix(tag, "<Stmt") {
			return false
		}
		if strings.HasPrefix(tag, "<ParameterList") {
			return true
		}
		i = at + e
	}
}

// utf16Len is the length of s in SQL Server's characters (UTF-16 code units: a character past U+FFFF is two).
func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		n++
		if r > 0xFFFF {
			n++
		}
	}
	return n
}

// maskPlanExprAttrs is a start tag with the literals of its expression attributes masked, written back escaped only
// where the mask changed a value (every other value keeps its bytes).
func maskPlanExprAttrs(tag string) string {
	return xmlAttrRE.ReplaceAllStringFunc(tag, func(m string) string {
		g := xmlAttrRE.FindStringSubmatch(m)
		head, val, q := g[1], g[2], g[3]
		if head == "" {
			head, val, q = g[4], g[5], g[6]
		}
		if !planExprAttrs[xmlAttrName(head)] || val == "" {
			return m
		}
		dec := html.UnescapeString(val)
		if mv := maskPlanLiterals(dec); mv != dec {
			return head + xmlAttrEscape(mv) + q
		}
		return m
	})
}

// maskPlanLiterals is a showplan expression with each literal masked: a string ('...' with a doubled quote inside,
// N'...' too) as '<masked>', a number (digits, a decimal point, an exponent) and a binary value (0x...) as <masked>.
// A bracketed or double-quoted name stays whole, and so do the digits of a name (Expr1003, @p1, #t2).
func maskPlanLiterals(v string) string {
	var b strings.Builder
	n := len(v)
	ident := func(i int) bool { // the byte before i belongs to a name
		if i == 0 {
			return false
		}
		c := v[i-1]
		return isASCIILetter(c) || c >= '0' && c <= '9' || c == '_' || c == '@' || c == '#' || c >= 0x80
	}
	digit := func(i int) bool { return i < n && v[i] >= '0' && v[i] <= '9' }
	for i := 0; i < n; {
		c := v[i]
		switch {
		case c == '[' || c == '"':
			closeCh := c
			if c == '[' {
				closeCh = ']'
			}
			j := i + 1
			for j < n {
				if v[j] == closeCh {
					if j+1 < n && v[j+1] == closeCh {
						j += 2
						continue
					}
					j++
					break
				}
				j++
			}
			b.WriteString(v[i:j])
			i = j
		case c == '\'' || (c == 'N' || c == 'n') && i+1 < n && v[i+1] == '\'' && !ident(i):
			j := i + 1
			if c != '\'' {
				j++
			}
			for j < n {
				if v[j] == '\'' {
					if j+1 < n && v[j+1] == '\'' {
						j += 2
						continue
					}
					j++
					break
				}
				j++
			}
			b.WriteString("'" + masked + "'")
			i = j
		case c == '0' && i+1 < n && (v[i+1] == 'x' || v[i+1] == 'X') && !ident(i):
			j := i + 2
			for j < n && (v[j] >= '0' && v[j] <= '9' || v[j] >= 'a' && v[j] <= 'f' || v[j] >= 'A' && v[j] <= 'F') {
				j++
			}
			b.WriteString(masked)
			i = j
		case (digit(i) || c == '.' && digit(i+1)) && !ident(i):
			j := i
			for j < n && (digit(j) || v[j] == '.') {
				j++
			}
			if j < n && (v[j] == 'e' || v[j] == 'E') && (digit(j+1) || j+2 < n && (v[j+1] == '+' || v[j+1] == '-') && digit(j+2)) {
				j += 2
				for digit(j) {
					j++
				}
			}
			b.WriteString(masked)
			i = j
		default:
			b.WriteByte(c)
			i++
		}
	}
	return b.String()
}
