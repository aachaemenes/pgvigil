package plans

import (
	"strings"
	"unicode"
)

// Scan is what a statement's text says about itself, read outside its string literals, quoted identifiers,
// dollar-quoted bodies and comments: its first keyword, its highest $n parameter, and whether a ';' is followed
// by more text (two statements).
type Scan struct {
	Keyword  string // upper case: SELECT, WITH, INSERT, ...; "" for an empty text
	MaxParam int    // 0 = no $n parameter
	Multiple bool
	// Unterminated is a quote, a dollar quote or a block comment left open
	Unterminated bool
}

// ScanSQL reads a statement's text.
func ScanSQL(s string) Scan {
	var out Scan
	rs := []rune(s)
	n := len(rs)
	semi := false
	for i := 0; i < n; i++ {
		c := rs[i]
		switch {
		case c == '-' && i+1 < n && rs[i+1] == '-':
			for i < n && rs[i] != '\n' {
				i++
			}
			continue
		case c == '/' && i+1 < n && rs[i+1] == '*':
			depth := 1
			i += 2
			for i < n && depth > 0 {
				switch {
				case rs[i] == '/' && i+1 < n && rs[i+1] == '*':
					depth++
					i += 2
				case rs[i] == '*' && i+1 < n && rs[i+1] == '/':
					depth--
					i += 2
				default:
					i++
				}
			}
			if depth > 0 {
				out.Unterminated = true
			}
			i--
			continue
		case unicode.IsSpace(c):
			continue
		}
		if semi {
			out.Multiple = true
		}
		switch c {
		case ';':
			semi = true
		case '\'', '"':
			j := i + 1
			for ; j < n; j++ {
				if rs[j] == c {
					if j+1 < n && rs[j+1] == c { // a doubled quote
						j++
						continue
					}
					break
				}
				if c == '\'' && rs[j] == '\\' && i > 0 && (rs[i-1] == 'E' || rs[i-1] == 'e') && j+1 < n {
					j++
				}
			}
			if j >= n {
				out.Unterminated = true
			}
			i = j
		case '$':
			j := i + 1
			for j < n && unicode.IsDigit(rs[j]) {
				j++
			}
			if j > i+1 && (j >= n || !isIdent(rs[j])) && (i == 0 || !isIdent(rs[i-1])) {
				p := 0
				for _, d := range rs[i+1 : j] {
					p = p*10 + int(d-'0')
					if p > 65535 {
						break
					}
				}
				out.MaxParam = max(out.MaxParam, p)
				i = j - 1
				continue
			}
			// a dollar quote: $$ or $tag$ (the tag does not start with a digit)
			k := i + 1
			for k < n && isIdent(rs[k]) && (k != i+1 || !unicode.IsDigit(rs[k])) {
				k++
			}
			if k < n && rs[k] == '$' && (i == 0 || !isIdent(rs[i-1])) {
				tag := string(rs[i : k+1])
				rest := string(rs[k+1:])
				end := strings.Index(rest, tag)
				if end < 0 {
					out.Unterminated = true
					i = n
					continue
				}
				i = k + len([]rune(rest[:end])) + len([]rune(tag))
				continue
			}
		default:
			if out.Keyword == "" && isIdent(c) {
				j := i
				for j < n && isIdent(rs[j]) {
					j++
				}
				out.Keyword = strings.ToUpper(string(rs[i:j]))
				i = j - 1
			} else if c == '(' && out.Keyword == "" {
				out.Keyword = "("
			}
		}
	}
	return out
}

func isIdent(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) }

// Explainable says whether EXPLAIN without ANALYZE may plan the statement: one statement of a kind EXPLAIN
// accepts (SELECT, a WITH query, VALUES, TABLE, INSERT, UPDATE, DELETE, MERGE). Planning only: nothing runs.
func (s Scan) Explainable() (bool, string) {
	switch {
	case s.Unterminated:
		return false, "the statement has an unterminated quote or comment"
	case s.Multiple:
		return false, "the text holds more than one statement"
	}
	switch s.Keyword {
	case "SELECT", "WITH", "VALUES", "TABLE", "(", "INSERT", "UPDATE", "DELETE", "MERGE":
		return true, ""
	case "":
		return false, "the statement is empty"
	}
	return false, s.Keyword + " cannot be explained: only SELECT, WITH, VALUES, TABLE, INSERT, UPDATE, DELETE and MERGE"
}

// ReadOnlyKind says whether the statement is a query EXPLAIN ANALYZE may execute: a SELECT, a WITH query, VALUES
// or TABLE. A WITH holding a data-modifying CTE passes this check and is stopped by the read-only transaction it
// runs in.
func (s Scan) ReadOnlyKind() (bool, string) {
	if ok, why := s.Explainable(); !ok {
		return false, why
	}
	switch s.Keyword {
	case "SELECT", "WITH", "VALUES", "TABLE", "(":
		return true, ""
	}
	return false, s.Keyword + " is not executed: EXPLAIN ANALYZE runs SELECT statements only (the plain EXPLAIN shows its plan without running it)"
}
