// Package plans reads PostgreSQL execution plans for the plans table (migration 0029): a plan as EXPLAIN
// (FORMAT JSON) returns it, as auto_explain writes it to the server log (JSON or text), or as pg_store_plans keeps
// it, turned into one import row with the plan as captured (what the viewer draws) and its JSON form (what the
// plan rules in 0029 read). A text plan is parsed into the JSON shape EXPLAIN would have given for the fields the
// rules use (ParseText); the original text is always kept.
//
// It also runs the on-demand EXPLAIN without execution through the monitoring login (Explain): the generic plan of
// a parameterised statement (PREPARE + plan_cache_mode = force_generic_plan), a plain EXPLAIN otherwise.
package plans

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Source is where a plan came from (the plans.source column).
type Source string

// The four sources.
const (
	PgStorePlans   Source = "pg_store_plans"
	AutoExplain    Source = "auto_explain"
	Explained      Source = "explain"
	ExplainAnalyze Source = "explain_analyze"
)

// Row is one import_plans row.
type Row struct {
	PlanKey    string          `json:"plan_key"`
	Source     Source          `json:"source"`
	CapturedAt time.Time       `json:"captured_at"`
	QueryID    *int64          `json:"queryid,omitempty"`
	PlanID     *int64          `json:"planid,omitempty"`
	Datname    string          `json:"datname,omitempty"`
	Usename    string          `json:"usename,omitempty"`
	Query      string          `json:"query,omitempty"`
	DurationMS *float64        `json:"duration_ms,omitempty"`
	Calls      *int64          `json:"calls,omitempty"`
	TotalMS    *float64        `json:"total_ms,omitempty"`
	Analyzed   bool            `json:"analyzed"`
	Format     string          `json:"format"` // json | text
	PlanText   string          `json:"plan_text"`
	Plan       json.RawMessage `json:"plan,omitempty"` // the JSON form; absent when a text plan could not be parsed
	PlanNote   string          `json:"plan_note,omitempty"`
}

// Map is the row as the collector's generic row type (collect.Row) wants it.
func (r Row) Map() map[string]any {
	b, _ := json.Marshal(r)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	return m
}

// maxPlanText caps a stored plan: a plan of a statement over thousands of partitions runs to megabytes.
const maxPlanText = 2 << 20

// Build turns a captured plan (JSON or text, as EXPLAIN or auto_explain wrote it) into a row: the JSON form when
// it parses, the analysed flag, the query text from the plan when the caller has none, and a plan key (the source's
// own identity when given, else a digest of the source, the database, the query and the plan).
func Build(src Source, at time.Time, key, datname, query, planText string) Row {
	r := Row{Source: src, CapturedAt: at.UTC(), Datname: datname, Query: query, PlanText: strings.TrimSpace(planText)}
	if len(r.PlanText) > maxPlanText {
		r.PlanText = r.PlanText[:maxPlanText]
		r.PlanNote = fmt.Sprintf("the plan was longer than %d bytes and was cut: the rules did not read it", maxPlanText)
	}
	var obj map[string]any
	var err error
	if strings.HasPrefix(r.PlanText, "{") || strings.HasPrefix(r.PlanText, "[") {
		r.Format = "json"
		obj, err = NormalizeJSON([]byte(r.PlanText))
	} else {
		r.Format = "text"
		obj, err = ParseText(r.PlanText)
	}
	switch {
	case r.PlanNote != "":
	case err != nil:
		r.PlanNote = "the plan could not be read: " + err.Error()
	default:
		if b, err := json.Marshal(obj); err == nil {
			r.Plan = b
		}
		r.Analyzed = analyzed(obj)
		if r.Query == "" {
			if q, ok := obj["Query Text"].(string); ok {
				r.Query = q
			}
		}
	}
	if key == "" {
		key = digestKey(src, datname, r.Query, r.PlanText, at)
	}
	r.PlanKey = key
	return r
}

// digestKey is the plan key of a plan without an identity of its own (auto_explain, EXPLAIN): the source and a
// digest of the database, the query, the plan text and the capture time. Mask recomputes it from the masked text
// under normalized, so nothing of the raw text, not even its hash, is kept.
func digestKey(src Source, datname, query, planText string, at time.Time) string {
	h := md5.Sum([]byte(string(src) + "\x00" + datname + "\x00" + query + "\x00" + planText + "\x00" + at.UTC().Format(time.RFC3339Nano)))
	return string(src) + ":" + hex.EncodeToString(h[:])
}

// NormalizeJSON takes EXPLAIN (FORMAT JSON)'s output (an array of one object per statement) or auto_explain's (one
// object) and returns the first statement's object: {"Plan": {...}, "Planning Time", "Execution Time", ...}.
func NormalizeJSON(b []byte) (map[string]any, error) {
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	if a, ok := v.([]any); ok {
		if len(a) == 0 {
			return nil, errors.New("an empty JSON plan")
		}
		v = a[0]
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("the JSON plan is not an object")
	}
	if _, ok := m["Plan"].(map[string]any); !ok {
		return nil, errors.New(`the JSON plan has no "Plan" object`)
	}
	return m, nil
}

func analyzed(obj map[string]any) bool {
	p, ok := obj["Plan"].(map[string]any)
	if !ok {
		return false
	}
	_, ok = p["Actual Loops"]
	return ok
}

// autoExplainRE is the head of an auto_explain message: "duration: 12.345 ms  plan:" then the plan.
var autoExplainRE = regexp.MustCompile(`(?s)^\s*duration:\s*([0-9.]+)\s*ms\s+plan:[ \t]*(?:\r?\n)?(.*)$`)

// FromLogMessage reads an auto_explain message (the log line's message after "LOG:  ", its continuation lines
// with or without the log writer's leading tab) into a row: the duration, the plan in its format, the query text
// from the plan. ok is false when the message is not auto_explain's.
func FromLogMessage(at time.Time, datname, usename, msg string) (Row, bool) {
	m := autoExplainRE.FindStringSubmatch(msg)
	if m == nil {
		return Row{}, false
	}
	body := untab(m[2])
	r := Build(AutoExplain, at, "", datname, "", body)
	if r.Format == "text" && r.Plan != nil {
		r.PlanText = planOnly(r.PlanText) // the query is kept in its own column; a viewer reads the text as a plan
	}
	r.Usename = usename
	if d, err := strconv.ParseFloat(m[1], 64); err == nil {
		r.DurationMS = &d
	}
	return r, true
}

// untab removes the one leading tab the server's log writer puts after each newline of a message.
func untab(s string) string {
	lines := strings.Split(s, "\n")
	all := true
	for _, l := range lines {
		if l != "" && !strings.HasPrefix(l, "\t") {
			all = false
			break
		}
	}
	if !all {
		return s
	}
	for i, l := range lines {
		lines[i] = strings.TrimPrefix(l, "\t")
	}
	return strings.Join(lines, "\n")
}

// planOnly drops the lines before a text plan's first node (auto_explain's "Query Text:" and "Query Parameters:").
func planOnly(text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		if isNodeLine(strings.TrimSpace(l)) {
			return strings.Join(lines[i:], "\n")
		}
	}
	return text
}
