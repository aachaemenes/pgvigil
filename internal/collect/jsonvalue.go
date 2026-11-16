package collect

import (
	"math"

	"github.com/jackc/pgx/v5/pgtype"
)

// JSONValue turns a value pgx's rows.Values() returned into one whose JSON form PostgreSQL reads back: the
// repository's imports cast the payload's text ((r->>'valid_until')::timestamptz) and the pages show it.
//
//   - a timestamptz, timestamp or date of +/-infinity: pgx v5 returns a pgtype.InfinityModifier, an int8 that JSON
//     writes as 1 / -1 (the cast then fails on '1' and the whole collection with it - the roles collection on RDS,
//     rdsadmin VALID UNTIL 'infinity'); it becomes 'infinity' / '-infinity'.
//   - a float4 / float8 NaN or +/-Infinity: JSON has no form for it (json.Marshal refuses the whole payload); it
//     becomes 'NaN' / 'Infinity' / '-Infinity', which float4, float8 and numeric read.
//
// Arrays ([]any) and composites (map[string]any) are walked in place. Every other value is returned as it was: a
// numeric's NaN and infinities already marshal as PostgreSQL's text (pgtype.Numeric.MarshalJSON). The types with no
// JSON form the casts read that no collect query returns today (interval, time, uuid, macaddr, bit, tid, the
// geometric types, tsvector, ranges) are left as they were: proof-pginf's sweep lists them.
func JSONValue(v any) any {
	switch x := v.(type) {
	case pgtype.InfinityModifier:
		return x.String()
	case float64:
		return floatText(x, v)
	case float32:
		return floatText(float64(x), v)
	case []any:
		for i := range x {
			x[i] = JSONValue(x[i])
		}
		return x
	case map[string]any:
		for k := range x {
			x[k] = JSONValue(x[k])
		}
		return x
	}
	return v
}

// floatText is PostgreSQL's text for a NaN or an infinity, else the value as it came (its own float type kept).
func floatText(f float64, v any) any {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	}
	return v
}
