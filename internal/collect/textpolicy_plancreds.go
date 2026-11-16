package collect

import (
	"html"
	"regexp"
	"strings"
)

// A showplan's ParameterList names each parameter's compiled value, and MaskXML masks a credential-named one's there
// (maskPlanParmRE). Under OPTION (RECOMPILE), or for a local variable a statement compiles with its value, there is no
// ParameterList entry: the value is compiled into the plan as a constant of the statement's expressions (a seek's
// ScalarString and ConstValue, a conversion warning's Expression), where nothing names the parameter it came from. So a
// statement whose own text names a credential-named @parameter that its plan does not list with a value has every
// literal of those expression attributes masked - its strings, numbers and binary values alike (a number may be the
// secret), the constants a reader can no longer tell apart. The statement's text, every other attribute, and every
// other statement of the plan keep their bytes.

var (
	// planCredParamRE: a credential-named parameter or variable, the names MaskCredentials' parameter form knows
	planCredParamRE = regexp.MustCompile(`(?i)@\w*(?:password|passwd|pwd|secret)\w*`)
	// planExprAttrs: the attributes of a showplan that hold an expression with its constants
	planExprAttrs = map[string]bool{"ScalarString": true, "ConstValue": true, "Expression": true}
)

// planTag is one start tag of a document: where it begins, its end, and its element's name.
type planTag struct {
	at, end int
	name    string
}

// planTags lists the start tags of s in order (a '<' and a letter; comments, CDATA sections, instructions and end tags
// are not start tags; a tag the text ends inside ends the list).
func planTags(s string) []planTag {
	var out []planTag
	for i := 0; i < len(s); {
		lt := strings.IndexByte(s[i:], '<')
		if lt < 0 {
			break
		}
		i += lt
		if i+1 >= len(s) || !isASCIILetter(s[i+1]) {
			i++
			continue
		}
		e := xmlTagEnd(s[i:])
		if e < 0 {
			break
		}
		n := i + 1
		for n < len(s) && (isASCIILetter(s[n]) || s[n] >= '0' && s[n] <= '9' || s[n] == '_' || s[n] == ':' || s[n] == '-' || s[n] == '.') {
			n++
		}
		out = append(out, planTag{i, i + e, s[i+1 : n]})
		i += e
	}
	return out
}

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

// maskPlanCredStatements is the statement pass of MaskXML over a document already masked tag by tag: each showplan
// statement (a Stmt... element, up to the next one) whose text names a credential-named @parameter that no
// ColumnReference of it lists with a compiled or runtime value has its expression attributes' literals masked
// (maskPlanLiterals). Idempotent.
func maskPlanCredStatements(s string) string {
	if !strings.Contains(s, "StatementText=") {
		return s
	}
	tags := planTags(s)
	var starts []int
	for k, t := range tags {
		if strings.HasPrefix(t.name, "Stmt") {
			starts = append(starts, k)
		}
	}
	if len(starts) == 0 {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	pos := 0
	for n, k := range starts {
		last := len(tags)
		if n+1 < len(starts) {
			last = starts[n+1]
		}
		text, _ := planAttr(s[tags[k].at:tags[k].end], "StatementText")
		unlisted := map[string]bool{}
		for _, p := range planCredParamRE.FindAllString(text, -1) {
			unlisted[strings.ToLower(p)] = true
		}
		if len(unlisted) > 0 {
			for _, t := range tags[k:last] {
				if t.name != "ColumnReference" {
					continue
				}
				tag := s[t.at:t.end]
				col, _ := planAttr(tag, "Column")
				_, compiled := planAttr(tag, "ParameterCompiledValue")
				_, runtime := planAttr(tag, "ParameterRuntimeValue")
				if compiled || runtime {
					delete(unlisted, strings.ToLower(col))
				}
			}
		}
		if len(unlisted) == 0 {
			continue
		}
		for _, t := range tags[k:last] {
			b.WriteString(s[pos:t.at])
			b.WriteString(maskPlanExprAttrs(s[t.at:t.end]))
			pos = t.end
		}
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
