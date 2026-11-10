package collect

import (
	"github.com/aachaemenes/pgvigil/internal/logparse"
	"hash/fnv"
	"regexp"
	"strings"
	"unicode"
)

// Query-text policy (config query_text: full | normalized | none). Statement text is the one thing a
// monitor stores that can carry data: a literal in a WHERE clause, a value in an INSERT. "full" keeps
// the text as the server shows it (credentials masked on the way out, always); "normalized" replaces
// every literal with ? and drops comments before the text leaves the collector, and keys the text by a
// hash of that normalized form (one row per statement shape, nothing of the raw text kept); "none"
// stores no statement text and no text hash at all, only the counters. The policy runs in RunOnce on
// every row, after the collector and before the import, so each collector stays unaware of it.

// textPolicyKeys are the row columns that hold statement text: activity and statements rows carry
// query; log rows carry statement and detail (a deadlock's detail quotes the other process's statement).
var textPolicyKeys = []string{"query", "statement", "detail"}

// applyTextPolicy rewrites the text columns of rows in place according to mode; an unknown or empty
// mode is "full" (nothing changes). A row that keys its text by query_hash (activity) gets the hash of
// the normalized text under normalized, so identical shapes share one query_text row and the raw
// text's fingerprint is not kept, and no hash at all under none.
func applyTextPolicy(rows []Row, mode string) {
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

// normalizeSQL rewrites one statement in a single pass over its runes: comments (-- to the end of the
// line, /* */ nested) are dropped, string literals ('..' with ” doubling, E'..' with backslash escapes,
// B'..' X'..' N'..' U&'..', $tag$..$tag$ with the tag matched exactly) and numbers (not a parameter $n,
// not part of an identifier) become ?, double-quoted identifiers stay whole, whitespace collapses to
// one space, and IN (?, ?, ...) collapses to IN (?). One pass, so an unpaired quote inside a comment or
// an escaped quote inside a string never desynchronises what follows. A text rule, not a parser: it is
// meant to keep data out of the repository, not to produce pg_stat_statements' exact form.
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
		case (unicode.IsDigit(c) || (c == '.' && i+1 < n && unicode.IsDigit(in[i+1]))) && !isIdent(prev(i)) && prev(i) != '.':
			j := i
			for j < n && (unicode.IsDigit(in[j]) || in[j] == '.') {
				j++
			}
			if j < n && (in[j] == 'e' || in[j] == 'E') && j+1 < n && (unicode.IsDigit(in[j+1]) || ((in[j+1] == '+' || in[j+1] == '-') && j+2 < n && unicode.IsDigit(in[j+2]))) {
				j += 2
				for j < n && unicode.IsDigit(in[j]) {
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
