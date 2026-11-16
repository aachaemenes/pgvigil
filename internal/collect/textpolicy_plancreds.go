package collect

import (
	"html"
	"regexp"
	"strings"
)

// A showplan's ParameterList names each parameter's compiled value, and MaskXML masks a credential-named one's there
// (maskPlanParmRE). Under OPTION (RECOMPILE), or for a local variable a statement compiles with its value, the value is
// compiled into the plan as a constant of the statement's expressions (a seek's ScalarString and ConstValue, a
// conversion warning's Expression, the statement a linked server is sent as its RemoteQuery), where nothing names the
// parameter it came from - and a live plan may list the parameter and carry the constant too. So a statement whose own
// text names a credential-named @parameter has every literal of those expression attributes masked - its strings,
// numbers and binary values alike (a number may be the secret), the constants a reader can no longer tell apart -
// whether or not its plan lists the parameter. The statement's text, every other attribute, and every other statement
// of the plan keep their bytes. The names are read from the document as it came in, before the tag pass masks it: that
// pass writes 'PasswordHash = @PasswordHash' as 'PasswordHash = <masked>', which names no parameter.
//
// The rule goes by the name in the statement's own text: a value copied into a variable or a parameter of another name,
// or a name with a non-ASCII letter before the word, keeps its constants (docs/security.html, 'Known limits of that
// mask').

var (
	// planCredParamRE: a credential-named parameter or variable, the names MaskCredentials' parameter form knows
	planCredParamRE = regexp.MustCompile(`(?i)@\w*(?:password|passwd|pwd|secret)\w*`)
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

// maskPlanCredStatements is the statement pass of MaskXML, run over the document as it came in, before the tag pass:
// each showplan statement (a Stmt... start tag, up to the next one) whose StatementText names a credential-named
// @parameter has its expression attributes' literals masked (maskPlanLiterals). The start tags are read as maskXML
// reads them: a comment's, a CDATA section's and an instruction's body is raw text, not tags, and an instruction ends
// where piEnd says (a showplan an instruction wraps is masked by the plan's own maskXML inside it, maskRaw); a tag the
// text ends inside ends the pass. One pass and no list of tags; s itself comes back when nothing is masked.
// Idempotent: a masked literal reads back as itself.
func maskPlanCredStatements(s string) string {
	if !strings.Contains(s, "StatementText=") {
		return s
	}
	var b strings.Builder
	pos, in, changed := 0, false, false // pos: s is written up to here; in: the tags read belong to a statement that names one
	opens, noEnd := len(s)-len(strings.TrimLeft(s, " \t\r\n")), false
	for i := 0; i < len(s); {
		lt := strings.IndexByte(s[i:], '<')
		if lt < 0 {
			break
		}
		i += lt
		rest := s[i:]
		end := 0 // the length of a raw section rest begins with (a comment, a CDATA section, an instruction)
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
			end = piEnd(rest, i == opens, &noEnd)
		case len(rest) < 2 || !isASCIILetter(rest[1]):
			i++ // an end tag, a declaration: no attributes of a statement
			continue
		default:
			end = -2
		}
		if end == -1 {
			break // the text ends inside the section: the rest is raw
		}
		if end > 0 {
			i += end
			continue
		}
		e := xmlTagEnd(rest)
		if e < 0 {
			break
		}
		tag := rest[:e]
		if strings.HasPrefix(tag, "<Stmt") {
			text, _ := planAttr(tag, "StatementText")
			in = planCredParamRE.MatchString(text)
		}
		if in && hasPlanExprAttr(tag) {
			if m := maskPlanExprAttrs(tag); m != tag {
				if !changed {
					b.Grow(len(s) + len(s)/8)
					changed = true
				}
				b.WriteString(s[pos:i])
				b.WriteString(m)
				pos = i + e
			}
		}
		i += e
	}
	if !changed {
		return s
	}
	b.WriteString(s[pos:])
	return b.String()
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
