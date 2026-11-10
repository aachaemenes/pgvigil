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
	return true
}

func maskValue(v any, normalize func(string) string) {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			if exprKeys[k] {
				switch s := e.(type) {
				case string:
					x[k] = normalize(s)
				case []any:
					for i, it := range s {
						if str, ok := it.(string); ok {
							s[i] = normalize(str)
						}
					}
				}
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
