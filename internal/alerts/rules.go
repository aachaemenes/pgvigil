package alerts

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"unicode/utf8"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// RuleRequest is the body of POST /api/alertrules (and of /api/alertrules/end, which reads rule_id alone): one alert
// rule to add, edit, switch on or off, or end (migration 0085).
type RuleRequest struct {
	Op         string   `json:"op"` // add (the default) | edit | enable | disable
	RuleID     int64    `json:"rule_id"`
	Metric     string   `json:"metric"` // a key of pgvigil.metric_catalog: family.metric
	Dir        string   `json:"op_dir"` // above | below
	Warning    *float64 `json:"warning"`
	Critical   *float64 `json:"critical"`
	ForMinutes *int     `json:"for_minutes"`
	Scope      string   `json:"scope"` // fleet | tag | instance
	Tag        string   `json:"tag"`
	InstanceID int      `json:"instance_id"`
	Database   string   `json:"database"`
	Name       string   `json:"name"`
	Note       string   `json:"note"`
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
	if in.Dir != "above" && in.Dir != "below" {
		return nil, errors.New("op_dir must be above or below")
	}
	if in.Warning == nil && in.Critical == nil {
		return nil, errors.New("a rule needs a warning or a critical value")
	}
	if in.Warning != nil && in.Critical != nil &&
		((in.Dir == "above" && *in.Critical < *in.Warning) || (in.Dir == "below" && *in.Critical > *in.Warning)) {
		return nil, errors.New("critical must be at or beyond warning (above: critical >= warning; below: critical <= warning)")
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
		return nil, errors.New("scope must be fleet, tag or instance")
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
