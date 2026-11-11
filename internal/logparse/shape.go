package logparse

import (
	"regexp"
	"strings"
)

// MessageShape is the key the Logs page groups a message by, pgBadger's normalized event: a double-quoted name, a
// single-quoted literal, a tuple id, an LSN and every number become ..., and white space folds, so 'relation "a"
// does not exist' and 'relation "b" does not exist' are one group. The shape carries no literal and no number of
// the message, so it is stored whatever the query-text policy (a message such as 'invalid input syntax for type
// integer: "abc"' keeps its words, never the value). An unquoted name (permission denied for function f) stays:
// the message alone cannot tell it from a word. pgvigil.log_message_shape (0079) is the same rule in SQL, for the
// rows read before 0079 stored a shape; the proof checks the two agree.
func MessageShape(msg string) string {
	s := shapeDQ.ReplaceAllString(msg, `"..."`)
	s = shapeSQ.ReplaceAllString(s, `'...'`)
	s = shapeLSN.ReplaceAllString(s, `.../...`)
	s = shapeTuple.ReplaceAllString(s, `(...)`)
	s = shapeRange.ReplaceAllString(s, `${1}...`)
	s = shapeNum.ReplaceAllString(s, `${1}...`)
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > messageShapeMax {
		s = strings.ToValidUTF8(s[:messageShapeMax], "")
	}
	return s
}

// messageShapeMax caps a shape (bytes); the SQL twin cuts at the same length in characters, equal for ASCII.
const messageShapeMax = 300

var (
	shapeDQ    = regexp.MustCompile(`"(?:[^"]|"")*"`)
	shapeSQ    = regexp.MustCompile(`'(?:[^']|'')*'`)
	shapeLSN   = regexp.MustCompile(`\b[0-9A-F]+/[0-9A-F]+\b`)
	shapeTuple = regexp.MustCompile(`\(\d+(?:,\d+)*\)`)
	shapeRange = regexp.MustCompile(`(^|[^\w.$])\d+\.\.\d+\b`) // a block range: blocks 8..15
	// a number not inside a name: preceded by the start or a character that is not a letter, digit, _, . or $, and
	// followed by a word boundary (Go's regexp has no look-around; \b after a digit means a non-word character next)
	shapeNum = regexp.MustCompile(`(^|[^\w.$])\d+(?:\.\d+)?\b`)
)
