package logparse

import (
	"regexp"
	"strings"
)

// MessageShape is the key the Logs page groups a message by, pgBadger's normalized event. In order:
//   - the cursor position the server appends (" at character 15") is dropped;
//   - a double-quoted run, from the first double quote of the line to the last, becomes "..." (greedy, so a quote
//     inside a quoted value, such as an array literal's, cannot leave part of the value outside), and so does a
//     single-quoted run;
//   - a tuple id such as (0,5) becomes (...);
//   - every token that holds a digit or an @ becomes ...: a number, a decimal, a range (8..15), an LSN, a path of
//     OIDs, an IP address, a UUID, a hex token, an e-mail address, a $ amount, a name with a number in it
//     (acct_7781); a token is a run of letters, digits and _ . @ $ : / + -;
//   - white space (ASCII) folds to one space; the shape is cut at 300 characters.
//
// The rules are ASCII-only on purpose: pgvigil.log_message_shape (0079) is the same rule in SQL, and a PostgreSQL
// character class follows the server's locale where Go's does not. What a shape can still carry: the words of a
// free-text message (a RAISE EXCEPTION 'customer % ...' with the value written without digits or quotes, an
// unquoted name such as "permission denied for function f"). The collectors mask passwords in it (maskText), and the
// query-text policy 'none' stores no message at all.
func MessageShape(msg string) string {
	s := shapeAtChar.ReplaceAllString(msg, "")
	s = shapeDQ.ReplaceAllString(s, `"..."`)
	s = shapeSQ.ReplaceAllString(s, `'...'`)
	s = shapeTuple.ReplaceAllString(s, `(...)`)
	s = shapeToken.ReplaceAllString(s, `...`)
	s = strings.Trim(shapeSpace.ReplaceAllString(s, " "), " ")
	if r := []rune(s); len(r) > messageShapeMax {
		s = string(r[:messageShapeMax])
	}
	return s
}

// messageShapeMax caps a shape, in characters (the SQL twin's left(..., 300)).
const messageShapeMax = 300

var (
	shapeAtChar = regexp.MustCompile(` at character [0-9]+$`)
	shapeDQ     = regexp.MustCompile(`"[^\n]*"`)
	shapeSQ     = regexp.MustCompile(`'[^\n]*'`)
	shapeTuple  = regexp.MustCompile(`\([0-9]+(?:,[0-9]+)*\)`)
	shapeToken  = regexp.MustCompile(`[A-Za-z0-9_.@$:/+-]*[0-9@][A-Za-z0-9_.@$:/+-]*`)
	shapeSpace  = regexp.MustCompile(`[ \t\n\r\f\v]+`)
)
