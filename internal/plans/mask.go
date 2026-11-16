package plans

import (
	"encoding/json"
	"strings"
)

// exprKeys are the plan properties that hold expressions, where a statement's literals show up (a filter's
// constant, an index condition's value, an output column's expression, the query text).
var exprKeys = map[string]bool{
	"Filter": true, "Index Cond": true, "Recheck Cond": true, "Hash Cond": true, "Merge Cond": true, "Join Filter": true,
	"TID Cond": true, "One-Time Filter": true, "Output": true, "Sort Key": true, "Presorted Key": true, "Group Key": true,
	"Cache Key": true, "Function Call": true, "Table Function Call": true, "Query Text": true, "Query Parameters": true,
	"Order By": true, "Run Condition": true, "Hash Key": true, "Repeatable Seed": true, "Sampling Parameters": true,
	"Window": true, "Conflict Filter": true, "Remote SQL": true, "Partial Key": true,
	// a GROUPING SETS node's sets: an array of key lists per set (read on PostgreSQL 18.6 and 13.23)
	"Group Keys": true, "Hash Keys": true,
	// the text form's tablesample line ('Sampling: bernoulli (..) REPEATABLE (..)'; TEXT-NOW-L review L2)
	"Sampling": true,
}

// Mask applies the instance's query-text policy (config query_text) to a plan row, as the collector's text
// policy does to statement rows: "none" leaves no plan (ok false: the row is not stored, since a plan's
// conditions carry the statement's literals); "normalized" passes every expression property (and the query) through
// normalize, which replaces literals, and rebuilds the stored text from the masked form; "full" or "" changes
// nothing.
func Mask(r *Row, mode string, normalize func(string) string) (ok bool) {
	switch mode {
	case "", "full":
		return true
	case "none":
		return false
	}
	if r.Query != "" {
		r.Query = normalize(r.Query)
	}
	if r.Format == "text" {
		lines := strings.Split(r.PlanText, "\n")
		for i, l := range lines {
			body := strings.TrimLeft(l, " ")
			if strings.HasPrefix(body, "->") || isNodeLine(body) {
				continue
			}
			k, v, found := strings.Cut(body, ": ")
			if found && exprKeys[k] {
				lines[i] = l[:len(l)-len(body)] + k + ": " + normalize(v)
			}
		}
		r.PlanText = strings.Join(lines, "\n")
	}
	if r.Plan != nil {
		var v any
		if err := json.Unmarshal(r.Plan, &v); err == nil {
			maskValue(v, normalize)
			if b, err := json.Marshal(v); err == nil {
				r.Plan = b
				if r.Format == "json" {
					r.PlanText = string(b)
				}
			}
		}
	} else if r.Format == "json" {
		r.PlanText = "" // a JSON plan that did not parse cannot be masked: it is not kept
		return false
	}
	if strings.HasPrefix(r.PlanKey, string(r.Source)+":") {
		// a digest key was computed over the raw text in Build: recomputed over the masked text, so the stored row
		// carries no hash of a literal (the query_text promise of README: not even its hash)
		r.PlanKey = digestKey(r.Source, r.Datname, r.Query, r.PlanText, r.CapturedAt)
	}
	return true
}

func maskValue(v any, normalize func(string) string) {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if exprKeys[k] {
				x[k] = normalizeAll(e, normalize)
				continue
			}
			maskValue(e, normalize)
		}
	case []any:
		for _, e := range x {
			maskValue(e, normalize)
		}
	}
}

// normalizeAll is an expression property's value with every string in it normalized, at any depth of arrays (a
// grouping set's "Group Keys" is an array of key lists).
func normalizeAll(v any, normalize func(string) string) any {
	switch x := v.(type) {
	case string:
		return normalize(x)
	case []any:
		for i, e := range x {
			x[i] = normalizeAll(e, normalize)
		}
	}
	return v
}
