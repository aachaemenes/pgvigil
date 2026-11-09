package collect

import (
	"regexp"
	"strings"
)

// Query-text policy (config query_text: full | normalized | none). Statement text is the one thing a
// monitor stores that can carry data: a literal in a WHERE clause, a value in an INSERT. "full" keeps
// the text as the server shows it (credentials masked on the way out, always); "normalized" replaces
// every literal with ? before the text leaves the collector; "none" stores no statement text at all,
// only the hashes and counters. The policy runs in RunOnce on every row, after the collector and
// before the import, so each collector stays unaware of it.

// textPolicyKeys are the row columns that hold statement text: activity and statements rows carry
// query; log rows carry statement and detail (a deadlock's detail quotes the other process's statement).
var textPolicyKeys = []string{"query", "statement", "detail"}

// applyTextPolicy rewrites the text columns of rows in place according to mode; an unknown or empty
// mode is "full" (nothing changes).
func applyTextPolicy(rows []Row, mode string) {
	if mode == "" || mode == "full" {
		return
	}
	for _, r := range rows {
		for _, k := range textPolicyKeys {
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
	}
}

var (
	// order matters: dollar quotes first (they may hold quotes), then quoted strings, then numbers
	normDollarRE = regexp.MustCompile(`(?s)\$([A-Za-z_][A-Za-z0-9_]*)?\$.*?\$([A-Za-z_][A-Za-z0-9_]*)?\$`)
	normStringRE = regexp.MustCompile(`'(?:[^']|'')*'`)
	// a standalone E, B, X or N prefix left in front of a replaced string (E'..' -> E? -> ?)
	normPrefixRE = regexp.MustCompile(`(^|[^A-Za-z0-9_])[EBXNebxn]\?`)
	// a number that is not part of an identifier ("t1", "col2") and not a parameter ($1)
	normNumberRE = regexp.MustCompile(`(^|[^A-Za-z0-9_$.])[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b`)
	normSpaceRE  = regexp.MustCompile(`\s+`)
	normInListRE = regexp.MustCompile(`(?i)(\bIN\s*)\(\s*\?(?:\s*,\s*\?)+\s*\)`)
)

// normalizeSQL replaces string, dollar-quoted and numeric literals with ?, collapses an IN list of
// literals to (?) and whitespace to single spaces. It is a text rule, not a parser: it is meant to keep
// data out of the repository, not to produce pg_stat_statements' exact form.
func normalizeSQL(s string) string {
	s = normDollarRE.ReplaceAllString(s, "?")
	s = normStringRE.ReplaceAllString(s, "?")
	s = normPrefixRE.ReplaceAllString(s, "${1}?")
	s = normNumberRE.ReplaceAllString(s, "${1}?")
	s = normInListRE.ReplaceAllString(s, "${1}(?)")
	s = normSpaceRE.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}
