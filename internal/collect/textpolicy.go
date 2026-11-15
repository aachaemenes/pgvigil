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
// the text as the server shows it, credentials masked (MaskCredentials, under every mode); "normalized" replaces
// every literal with ? and drops comments before the text leaves the collector, and keys the text by a
// hash of that normalized form (one row per statement shape, nothing of the raw text kept); "none"
// stores no statement text and no text hash at all, only the counters. The policy runs in RunOnce on
// every row, after the collector and before the import, so each collector stays unaware of it.

// textPolicyKeys are the row columns that hold statement text: activity and statements rows carry
// query; log rows carry statement and detail (a deadlock's detail quotes the other process's statement).
var textPolicyKeys = []string{"query", "statement", "detail"}

// credentialKeys are the row columns the credential mask runs over under every mode: the statement text keys, the
// slow capture's statement shape and a message (a log line or a read's error can quote a connection string). A new
// text path puts its text under one of these keys (task 415).
var credentialKeys = []string{"query", "statement", "detail", "shape", "message"}

// The credential mask (task 415). Every form below is replaced by <masked> in the text of every row, under every
// text policy, on both engines, before the row leaves the collector:
//   - a private key block: -----BEGIN ... PRIVATE KEY----- (PGP, PEM, RSA, EC ...) to its END line, or to the end of
//     a text the server or a text cap cut before it;
//   - every string literal inside a call of a function that takes a key or a passphrase: pgcrypto's pgp_sym_*,
//     pgp_pub_decrypt*, encrypt*, decrypt*, hmac and crypt, SQL Server's ENCRYPTBYPASSPHRASE and DECRYPTBYPASSPHRASE
//     ('...', E'...', N'...', $tag$...$tag$; an unterminated one to the end of the text);
//   - the literal or 0x value after PASSWORD (= optional: T-SQL and PostgreSQL), SECRET =, IDENTIFIED BY, and a
//     T-SQL parameter whose name holds password, passwd, pwd or secret (@rmtpassword = N'...'); an unterminated
//     literal to the end of the text;
//   - key = value or key: value where the key holds password, passwd, pwd, secret, passfile or sslkey (a connection
//     string, libpq's keywords, SQLCMDPASSWORD with or without spaces);
//   - the password of a URI's user:password@;
//   - a command line's -P (sqlcmd, bcp, osql, isql: the value bare, quoted, or in T-SQL's doubled quotes),
//     -Password, -pw and -pwd; ConvertTo-SecureString's string; net use's password; dtexec's /DE and /Decrypt.
//
// It is a text rule: a password stored as an ordinary column value in an INSERT stays under full and is gone under
// normalized and none. The mask is idempotent: a second pass changes nothing.
var (
	maskKeyBlockRE = regexp.MustCompile(`(?s)-----BEGIN (?:PGP PRIVATE KEY BLOCK|[A-Z0-9 ]*PRIVATE KEY)-----.*?(?:-----END (?:PGP PRIVATE KEY BLOCK|[A-Z0-9 ]*PRIVATE KEY)-----|\z)`)
	maskFuncRE     = regexp.MustCompile(`(?i)\b(?:pgp_sym_encrypt(?:_bytea)?|pgp_sym_decrypt(?:_bytea)?|pgp_pub_decrypt(?:_bytea)?|encrypt(?:_iv)?|decrypt(?:_iv)?|hmac|crypt|encryptbypassphrase|decryptbypassphrase)\s*\(`)
	maskKeywordRE  = regexp.MustCompile(`(?i)(?:\bPASSWORD\b\s*=?\s*|\bSECRET\s*=\s*|\bIDENTIFIED\s+BY\s+|@\w*(?:password|passwd|pwd|secret)\w*\s*=\s*)`)
	maskPairRE     = regexp.MustCompile(`(?i)(\b\w*(?:password|passwd|pwd|secret|passfile|sslkey)\w*\s*[=:]\s*)("[^"]*(?:"|\z)|'(?:[^']|'')*(?:'|\z)|[^;\s,)'"]+)`)
	maskURIRE2     = regexp.MustCompile(`(://[^:/@\s'"]+:)([^@\s/'"]+)(@)`)
	maskArgRE2     = regexp.MustCompile(`((?:^|[\s'"])(?:(?i:-Password|-pwd|-pw)\b|-P)\s*)(''(?:[^']|'''')*''|"[^"]*"|'[^']*'|(?:[^\s']|'')+)`)
	maskSecureRE2  = regexp.MustCompile(`(?i)(ConvertTo-SecureString\s+(?:-String\s+)?)("[^"]*"|'[^']*'|\S+)`)
	maskNetUseRE2  = regexp.MustCompile(`(?i)(\bnet\s+use\s+\S+\s+)([^/\s]\S*)`)
	maskDtsRE2     = regexp.MustCompile(`(?i)(/(?:DE|Decrypt)\s+)("[^"]*"|\S+)`)
)

const masked = "<masked>"

// MaskCredentials is s with every credential in the forms above replaced by <masked> (the comment above lists them).
func MaskCredentials(s string) string {
	if s == "" {
		return s
	}
	s = maskKeyBlockRE.ReplaceAllString(s, masked)
	s = maskFuncLiterals(s)
	s = maskKeywordLiterals(s)
	s = maskURIRE2.ReplaceAllString(s, "${1}"+masked+"${3}")
	s = maskPairRE.ReplaceAllStringFunc(s, func(m string) string {
		g := maskPairRE.FindStringSubmatch(m)
		if strings.Contains(g[2], masked) {
			return m
		}
		return g[1] + masked
	})
	s = maskArgRE2.ReplaceAllStringFunc(s, func(m string) string {
		g := maskArgRE2.FindStringSubmatch(m)
		return g[1] + masked
	})
	s = maskSecureRE2.ReplaceAllString(s, "${1}"+masked)
	s = maskNetUseRE2.ReplaceAllString(s, "${1}"+masked)
	return maskDtsRE2.ReplaceAllString(s, "${1}"+masked)
}

// maskFuncLiterals replaces every string literal inside the argument list of a key-taking function call (maskFuncRE)
// with '<masked>': from the opening parenthesis to its match, or to the end of the text when the text was cut.
func maskFuncLiterals(s string) string {
	locs := maskFuncRE.FindAllStringIndex(s, -1)
	if locs == nil {
		return s
	}
	in := []rune(s)
	var out strings.Builder
	out.Grow(len(s))
	done := 0 // runes of in already written
	for _, loc := range locs {
		open := len([]rune(s[:loc[1]])) // the rune after '('
		if open <= done {
			continue // inside a call already masked (a nested key function)
		}
		out.WriteString(string(in[done:open]))
		i, depth := open, 1
		for i < len(in) && depth > 0 {
			if j, lit := literalAt(in, i); lit {
				out.WriteString("'" + masked + "'")
				i = j
				continue
			}
			switch in[i] {
			case '(':
				depth++
			case ')':
				depth--
			}
			out.WriteRune(in[i])
			i++
		}
		done = i
	}
	out.WriteString(string(in[done:]))
	return out.String()
}

// maskKeywordLiterals replaces the value after PASSWORD, SECRET =, IDENTIFIED BY or a password-named T-SQL parameter
// with '<masked>' when it is a literal ('...', N'...', E'...', $tag$...$tag$; an unterminated one to the end of the
// text) or a 0x value (a hashed password); anything else (a parameter, NULL, a column) stays.
func maskKeywordLiterals(s string) string {
	locs := maskKeywordRE.FindAllStringIndex(s, -1)
	if locs == nil {
		return s
	}
	in := []rune(s)
	var out strings.Builder
	out.Grow(len(s))
	done := 0
	for _, loc := range locs {
		at := len([]rune(s[:loc[1]]))
		if at < done {
			continue
		}
		if j, lit := literalAt(in, at); lit {
			out.WriteString(string(in[done:at]))
			out.WriteString("'" + masked + "'")
			done = j
			continue
		}
		if at+2 < len(in) && in[at] == '0' && (in[at+1] == 'x' || in[at+1] == 'X') && isHex(in[at+2]) {
			j := at + 2
			for j < len(in) && isHex(in[j]) {
				j++
			}
			out.WriteString(string(in[done:at]))
			out.WriteString("'" + masked + "'")
			done = j
		}
	}
	out.WriteString(string(in[done:]))
	return out.String()
}

func isHex(r rune) bool {
	return unicode.IsDigit(r) || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
}

// literalAt says whether a string literal opens at in[i] and returns the index after it: '...' (a doubled quote
// inside), N'...' (T-SQL's Unicode literal), E'...' (backslash escapes) or $tag$...$tag$ (the tag matched exactly);
// an unterminated literal runs to the end of the text. A letter that ends an identifier (name'...') is not a prefix.
func literalAt(in []rune, i int) (int, bool) {
	n := len(in)
	if i >= n {
		return i, false
	}
	identBefore := i > 0 && (in[i-1] == '_' || unicode.IsLetter(in[i-1]) || unicode.IsDigit(in[i-1]))
	switch c := in[i]; {
	case c == '\'':
		return skipQuoted(in, i, false), true
	case (c == 'N' || c == 'n') && i+1 < n && in[i+1] == '\'' && !identBefore:
		return skipQuoted(in, i+1, false), true
	case (c == 'E' || c == 'e') && i+1 < n && in[i+1] == '\'' && !identBefore:
		return skipQuoted(in, i+1, true), true
	case c == '$' && !identBefore && i+1 < n && !unicode.IsDigit(in[i+1]):
		j := i + 1
		for j < n && (in[j] == '_' || unicode.IsLetter(in[j]) || (j > i+1 && unicode.IsDigit(in[j]))) {
			j++
		}
		if j < n && in[j] == '$' {
			tag := string(in[i : j+1])
			rest := string(in[j+1:])
			if end := strings.Index(rest, tag); end >= 0 {
				return j + 1 + len([]rune(rest[:end])) + len([]rune(tag)), true
			}
			return n, true // an unterminated dollar quote: the rest of the text is its body
		}
	}
	return i, false
}

// maskRowCredentials runs the credential mask over a row's text columns (credentialKeys), whatever the policy.
func maskRowCredentials(r Row) {
	for _, k := range credentialKeys {
		if s, ok := r[k].(string); ok && s != "" {
			if m := MaskCredentials(s); m != s {
				r[k] = m
			}
		}
	}
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
