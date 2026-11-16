package alerts

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// RuleRequest is the body of POST /api/alertrules (and of /api/alertrules/end, which reads rule_id alone): one alert
// rule to add, edit, switch on or off, or end (migrations 0085 and 0154; minimum role operator, B24f).
type RuleRequest struct {
	Op             string   `json:"op"` // add (the default) | edit | enable | disable
	RuleID         int64    `json:"rule_id"`
	Metric         string   `json:"metric"` // a key of pgvigil.metric_catalog: family.metric
	Dir            string   `json:"op_dir"` // above | below | rises | above_baseline (0154)
	Warning        *float64 `json:"warning"`
	Critical       *float64 `json:"critical"`
	ForMinutes     *int     `json:"for_minutes"`
	Scope          string   `json:"scope"` // fleet | tag | tags (0154: ScopeTags) | instance
	Tag            string   `json:"tag"`
	ScopeTags      []string `json:"scope_tags"` // tags: (key1 = a OR key1 = b) AND key2 = c
	InstanceID     int      `json:"instance_id"`
	Database       string   `json:"database"`
	Name           string   `json:"name"`
	Note           string   `json:"note"`
	BandPct        *float64 `json:"band_pct"`        // above_baseline: per cent above the hour's baseline (default 20)
	Zone           string   `json:"zone"`            // above_baseline: the IANA zone its hours are read in
	IgnoreFlapping *bool    `json:"ignore_flapping"` // never held as flapping (SQLWATCH's per-check opt-out)
}

// ruleDirs are the operators a rule may use: the threshold family (above, below), a rise between two samples, and
// above the hour's baseline (0154's families).
var ruleDirs = map[string]bool{"above": true, "below": true, "rises": true, "above_baseline": true}

// MaxScopeTags bounds a tag list (alert_rules' and alert_windows' checks).
const MaxScopeTags = 20

// ScopeTagList parses a tag list into the written form pgvigil.instance_tags_merged holds, refusing an empty one,
// more than MaxScopeTags, or a tag that does not parse.
func ScopeTagList(in []string) ([]string, error) {
	var out []string
	for _, raw := range in {
		if strings.TrimSpace(raw) == "" {
			continue
		}
		t, err := config.ParseTag(raw)
		if err != nil {
			return nil, err
		}
		out = append(out, t.String())
	}
	if len(out) == 0 {
		return nil, errors.New("a tags scope names at least one tag")
	}
	if len(out) > MaxScopeTags {
		return nil, fmt.Errorf("a tags scope names at most %d tags", MaxScopeTags)
	}
	return out, nil
}

// ruleOps are the ops a request may name itself; end comes only from its own route (RulePayload's forced).
var ruleOps = map[string]bool{"add": true, "edit": true, "enable": true, "disable": true}

// MaxRuleMinutes is the longest 'for n minutes' a rule may ask (a day).
const MaxRuleMinutes = 1440

// RulePayload checks a request's shape and builds the payload of pgvigil.import_alert_rule (without ui_user and
// client: the caller's session gives those). forced, when set, is the op whatever the request says (the end route).
// inst resolves an instance id to the name of an active instance, "" when there is none. What a rule may hold beyond
// its shape (a known metric, an instance of the metric's engine, one live rule per metric, scope and database) is the
// function's to refuse, with its log row.
func RulePayload(in RuleRequest, forced string, inst func(id int) string) (map[string]any, error) {
	op := in.Op
	switch {
	case forced != "":
		op = forced
	case op == "":
		op = "add"
	case !ruleOps[op]:
		return nil, errors.New("op must be add, edit, enable or disable (POST /api/alertrules/end ends a rule)")
	}
	pay := map[string]any{"op": op}
	if op != "add" {
		if in.RuleID <= 0 {
			return nil, errors.New("rule_id must be a positive rule id")
		}
		pay["rule_id"] = in.RuleID
	}
	if op != "add" && op != "edit" {
		return pay, nil
	}
	if in.Metric == "" || len(in.Metric) > 100 {
		return nil, errors.New("metric must be a metric key (family.metric)")
	}
	if !ruleDirs[in.Dir] {
		return nil, errors.New("op_dir must be above, below, rises or above_baseline")
	}
	if in.Warning == nil && in.Critical == nil {
		return nil, errors.New("a rule needs a warning or a critical value")
	}
	if in.Warning != nil && in.Critical != nil &&
		((in.Dir != "below" && *in.Critical < *in.Warning) || (in.Dir == "below" && *in.Critical > *in.Warning)) {
		return nil, errors.New("critical must be at or beyond warning (above, rises, above_baseline: critical >= warning; below: critical <= warning)")
	}
	if in.Dir == "above_baseline" {
		if strings.TrimSpace(in.Zone) == "" {
			return nil, errors.New("a baseline rule names its time zone (an IANA name, e.g. America/Chicago)")
		}
		if _, err := time.LoadLocation(strings.TrimSpace(in.Zone)); err != nil {
			return nil, fmt.Errorf("zone %q is not an IANA time zone name", in.Zone)
		}
		pay["zone"] = strings.TrimSpace(in.Zone)
		if in.BandPct != nil {
			if math.IsNaN(*in.BandPct) || *in.BandPct < 0 || *in.BandPct > 1000 {
				return nil, errors.New("band_pct must be 0..1000 (per cent above the baseline)")
			}
			pay["band_pct"] = *in.BandPct
		}
	}
	if in.IgnoreFlapping != nil {
		pay["ignore_flapping"] = *in.IgnoreFlapping
	}
	pay["metric"], pay["op_dir"] = in.Metric, in.Dir
	if in.Warning != nil {
		pay["warning"] = *in.Warning
	}
	if in.Critical != nil {
		pay["critical"] = *in.Critical
	}
	if in.ForMinutes != nil {
		if *in.ForMinutes < 0 || *in.ForMinutes > MaxRuleMinutes {
			return nil, fmt.Errorf("for_minutes must be 0..%d", MaxRuleMinutes)
		}
		pay["for_minutes"] = *in.ForMinutes
	}
	switch in.Scope {
	case "fleet":
	case "tag":
		t, err := config.ParseTag(in.Tag)
		if err != nil {
			return nil, err
		}
		pay["tag"] = t.String() // the written form pgvigil.instance_tags_merged holds
	case "tags":
		tags, err := ScopeTagList(in.ScopeTags)
		if err != nil {
			return nil, err
		}
		pay["scope_tags"] = tags
	case "instance":
		if in.InstanceID <= 0 || in.InstanceID > math.MaxInt32 {
			return nil, errors.New("an instance rule names its instance_id")
		}
		name := inst(in.InstanceID)
		if name == "" {
			return nil, fmt.Errorf("no active instance %d", in.InstanceID)
		}
		pay["instance_name"] = name
	default:
		return nil, errors.New("scope must be fleet, tag, tags or instance")
	}
	pay["scope"] = in.Scope
	// the store's own limits (alert_rules' checks), said here as a request's fault rather than as the store's refusal
	for _, f := range []struct {
		key, val string
		max      int
	}{{"database", in.Database, 200}, {"name", in.Name, 100}, {"note", in.Note, 500}} {
		v := strings.TrimSpace(f.val)
		if utf8.RuneCountInString(v) > f.max {
			return nil, fmt.Errorf("%s must be at most %d characters", f.key, f.max)
		}
		if v != "" {
			pay[f.key] = v
		}
	}
	return pay, nil
}

// WindowRequest is the body of POST /api/alertwindows: one blackout, mute or digest window to add, edit or end
// (migration 0154's import_alert_window; minimum role operator, B24f).
type WindowRequest struct {
	Op              string   `json:"op"` // add (the default) | edit | end
	WindowID        int64    `json:"window_id"`
	Name            string   `json:"name"`
	Action          string   `json:"action"` // blackout | mute | digest
	Scope           string   `json:"scope"`  // fleet | tags | instance
	ScopeTags       []string `json:"scope_tags"`
	InstanceID      int      `json:"instance_id"`
	FromRuleID      int64    `json:"from_rule_id"` // copies the live rule's scope when Scope is empty
	Weekdays        []int    `json:"weekdays"`     // ISO: 1 Monday .. 7 Sunday
	Start           string   `json:"start_local"`  // HH:MM in Zone
	End             string   `json:"end_local"`    // HH:MM in Zone, or 24:00 (the day's end); before Start = across midnight
	Zone            string   `json:"zone"`
	SeverityCeiling string   `json:"severity_ceiling"` // digest: info | warning (default warning); a critical always pages
	StartsAt        string   `json:"starts_at"`
	Until           string   `json:"until"`
	Note            string   `json:"note"`
}

var windowActions = map[string]bool{"blackout": true, "mute": true, "digest": true}

// WindowPayload checks a window request's shape and builds the payload of pgvigil.import_alert_window (without ui_user
// and client). inst resolves an instance id to an active instance's name ("" for none). The store refuses what needs
// its own data (an unknown zone on the server, a rule that is not live), with its log row.
func WindowPayload(in WindowRequest, inst func(id int) string) (map[string]any, error) {
	op := in.Op
	if op == "" {
		op = "add"
	}
	if op != "add" && op != "edit" && op != "end" {
		return nil, errors.New("op must be add, edit or end")
	}
	pay := map[string]any{"op": op}
	if op != "add" {
		if in.WindowID <= 0 {
			return nil, errors.New("window_id must be a positive window id")
		}
		pay["window_id"] = in.WindowID
	}
	if op == "end" {
		return pay, nil
	}
	if !windowActions[in.Action] {
		return nil, errors.New("action must be blackout, mute or digest")
	}
	pay["action"] = in.Action
	switch in.Scope {
	case "":
		if in.FromRuleID <= 0 {
			return nil, errors.New("scope must be fleet, tags or instance (or from_rule_id to copy a rule's)")
		}
	case "fleet":
	case "tags":
		tags, err := ScopeTagList(in.ScopeTags)
		if err != nil {
			return nil, err
		}
		pay["scope_tags"] = tags
	case "instance":
		if in.InstanceID <= 0 || in.InstanceID > math.MaxInt32 {
			return nil, errors.New("an instance window names its instance_id")
		}
		name := inst(in.InstanceID)
		if name == "" {
			return nil, fmt.Errorf("no active instance %d", in.InstanceID)
		}
		pay["instance_name"] = name
	default:
		return nil, errors.New("scope must be fleet, tags or instance")
	}
	if in.Scope != "" {
		pay["scope"] = in.Scope
	}
	if in.FromRuleID > 0 {
		pay["from_rule_id"] = in.FromRuleID
	}
	if len(in.Weekdays) == 0 || len(in.Weekdays) > 7 {
		return nil, errors.New("weekdays names 1 to 7 days (1 Monday .. 7 Sunday)")
	}
	for _, d := range in.Weekdays {
		if d < 1 || d > 7 {
			return nil, fmt.Errorf("weekday %d is not 1 (Monday) .. 7 (Sunday)", d)
		}
	}
	pay["weekdays"] = in.Weekdays
	start, err := time.Parse("15:04", in.Start)
	if err != nil {
		return nil, errors.New("start_local is HH:MM")
	}
	end, err := time.Parse("15:04", in.End)
	if in.End == "24:00" { // the day's end: a whole day is 00:00-24:00
		end, err = time.Parse("15:04", "23:59")
		end = end.Add(time.Minute)
	}
	if err != nil {
		return nil, errors.New("end_local is HH:MM (or 24:00, the day's end)")
	}
	if start.Equal(end) {
		return nil, errors.New("a window starts and ends at different times (end before start = across midnight)")
	}
	pay["start_local"], pay["end_local"] = in.Start, in.End
	zone := strings.TrimSpace(in.Zone)
	if _, err := time.LoadLocation(zone); err != nil || zone == "" {
		return nil, fmt.Errorf("zone %q is not an IANA time zone name (e.g. America/Chicago)", in.Zone)
	}
	pay["zone"] = zone
	if in.Action == "digest" {
		c := in.SeverityCeiling
		if c == "" {
			c = "warning"
		}
		if c != "info" && c != "warning" {
			return nil, errors.New("a digest window holds info or warning alerts only: a critical always pages at once")
		}
		pay["severity_ceiling"] = c
	} else if in.SeverityCeiling != "" {
		return nil, errors.New("severity_ceiling belongs to a digest window only")
	}
	for _, t := range []struct{ key, val string }{{"starts_at", in.StartsAt}, {"until", in.Until}} {
		if t.val == "" {
			continue
		}
		if _, err := time.Parse(time.RFC3339, t.val); err != nil {
			return nil, fmt.Errorf("%s must be an RFC 3339 time", t.key)
		}
		pay[t.key] = t.val
	}
	for _, f := range []struct {
		key, val string
		max      int
	}{{"name", in.Name, 100}, {"note", in.Note, 500}} {
		v := strings.TrimSpace(f.val)
		if utf8.RuneCountInString(v) > f.max {
			return nil, fmt.Errorf("%s must be at most %d characters", f.key, f.max)
		}
		if v != "" {
			pay[f.key] = v
		}
	}
	return pay, nil
}
