package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// A page instance's own settings (Admin > Instances' Settings, the ServiceConfig takes' ST5a; migration 0263): per
// collection an interval or off, and the statement-text policy - what pgvigil.yaml's schedules:, disabled: and
// query_text: are for an instance of the file. Merge applies them as the file's are applied, so a page instance's
// effective interval follows the same order (Interval): off, then its own value, then the file's global schedules:,
// then the running plans box (PageDefaults), then the collection's default.

// PageScheduleFloor is the shortest interval a page instance's own schedule may take: the Settings panel and the tree's
// Configure Schedule judge by it (the dialog has always said 'a minute or more'). pgvigil.yaml's own values are not
// held to it.
const PageScheduleFloor = time.Minute

// PageScheduleCeiling is the longest one (0263's own check of the stored shape says the same 30 days).
const PageScheduleCeiling = 30 * 24 * time.Hour

// PageSettings is admin_instances.settings read: Schedules per collection (0 = off); QueryText "" = pgvigil.yaml's;
// Thresholds a SQL Server instance's own mssql_thresholds (0266, ST5b: each number a float64, backup_exclude a
// []string - what mssql.ThresholdRows takes); Paused the own interval of a collection Pause Collections set off, kept
// for its Resume (no schedule: the collection stays off).
type PageSettings struct {
	Schedules  map[string]time.Duration
	QueryText  string
	Thresholds map[string]any
	Paused     map[string]time.Duration
}

// ParsePageSettings reads admin_instances.settings ({"schedules": {"<collection>": <seconds>}, "query_text": "..."});
// nothing = every default. The page refuses a bad value on write (0263); this guards a hand edit of the row.
func ParsePageSettings(raw []byte) (PageSettings, error) {
	var ps PageSettings
	if len(bytes.TrimSpace(raw)) == 0 {
		return ps, nil
	}
	var v struct {
		Schedules  map[string]json.Number     `json:"schedules"`
		QueryText  *string                    `json:"query_text"`
		Thresholds map[string]json.RawMessage `json:"thresholds"`
		Paused     map[string]json.Number     `json:"paused"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	dec.DisallowUnknownFields()
	if err := dec.Decode(&v); err != nil {
		return PageSettings{}, fmt.Errorf("its settings in Admin > Instances do not parse: %v", err)
	}
	for k, n := range v.Schedules {
		sec, err := n.Int64()
		// the ceiling in seconds before the multiplication: a huge number would wrap round to a small interval
		if err != nil || sec < 0 || sec > int64(PageScheduleCeiling/time.Second) {
			return PageSettings{}, fmt.Errorf("its settings in Admin > Instances give %s %s: not whole seconds from 0 (off) to 30 days", k, n)
		}
		if ps.Schedules == nil {
			ps.Schedules = map[string]time.Duration{}
		}
		ps.Schedules[k] = time.Duration(sec) * time.Second
	}
	for k, n := range v.Paused {
		sec, err := n.Int64()
		if err != nil || sec < int64(PageScheduleFloor/time.Second) || sec > int64(PageScheduleCeiling/time.Second) {
			return PageSettings{}, fmt.Errorf("its settings in Admin > Instances give paused %s %s: not whole seconds from 60 to 30 days", k, n)
		}
		if ps.Paused == nil {
			ps.Paused = map[string]time.Duration{}
		}
		ps.Paused[k] = time.Duration(sec) * time.Second
	}
	if err := ps.readThresholds(v.Thresholds); err != nil {
		return PageSettings{}, err
	}
	if v.QueryText != nil {
		if !validQueryText(*v.QueryText) {
			return PageSettings{}, fmt.Errorf("its settings in Admin > Instances give query_text %q: not full, normalized or none", *v.QueryText)
		}
		ps.QueryText = *v.QueryText
	}
	return ps, nil
}

// patternBlank is what a blank backup_exclude pattern holds only: 0266's btrim set exactly (strings.TrimSpace also
// trims Unicode spaces, which 0266 would keep - one set on both sides)
const patternBlank = " \t\n\v\f\r"

// readThresholds reads the stored thresholds: a number of 0 or more each, backup_exclude a list of non-blank patterns
// (the names are serve's and 0266's to judge: config cannot import mssql).
func (ps *PageSettings) readThresholds(raw map[string]json.RawMessage) error {
	for k, r := range raw {
		if ps.Thresholds == nil {
			ps.Thresholds = map[string]any{}
		}
		if k == "backup_exclude" {
			var pats []string
			if err := json.Unmarshal(r, &pats); err != nil || pats == nil {
				return fmt.Errorf("its settings in Admin > Instances give backup_exclude: not a list of database name patterns, none blank")
			}
			for _, p := range pats {
				if strings.Trim(p, patternBlank) == "" {
					return fmt.Errorf("its settings in Admin > Instances give backup_exclude: not a list of database name patterns, none blank")
				}
			}
			ps.Thresholds[k] = pats
			continue
		}
		var n float64
		if err := json.Unmarshal(r, &n); err != nil || n < 0 || string(bytes.TrimSpace(r)) == "null" {
			return fmt.Errorf("its settings in Admin > Instances give threshold %s %s: not a number of 0 or more", k, bytes.TrimSpace(r))
		}
		ps.Thresholds[k] = n
	}
	return nil
}

// Stored is the settings as admin_instances.settings holds them (whole seconds; a key left out = the default).
func (ps PageSettings) Stored() map[string]any {
	out := map[string]any{}
	if len(ps.Schedules) > 0 {
		sch := map[string]int64{}
		for k, d := range ps.Schedules {
			sch[k] = int64(d / time.Second)
		}
		out["schedules"] = sch
	}
	if ps.QueryText != "" {
		out["query_text"] = ps.QueryText
	}
	if len(ps.Thresholds) > 0 {
		th := map[string]any{}
		for k, v := range ps.Thresholds {
			th[k] = v
		}
		out["thresholds"] = th
	}
	if len(ps.Paused) > 0 {
		pa := map[string]int64{}
		for k, d := range ps.Paused {
			pa[k] = int64(d / time.Second)
		}
		out["paused"] = pa
	}
	return out
}

// apply puts the settings on an instance as pgvigil.yaml's schedules:, disabled: and query_text: would: a zero is a
// collection named in disabled:, any other value its own schedule.
func (ps PageSettings) apply(in *Instance) {
	keys := make([]string, 0, len(ps.Schedules))
	for k := range ps.Schedules {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if d := ps.Schedules[k]; d == 0 {
			in.Disabled = append(in.Disabled, k)
		} else {
			if in.Schedules == nil {
				in.Schedules = map[string]Duration{}
			}
			in.Schedules[k] = Duration{Duration: d}
		}
	}
	if ps.QueryText != "" {
		in.QueryText = ps.QueryText
	}
	if len(ps.Thresholds) > 0 {
		in.MSSQLThresholds = map[string]any{}
		for k, v := range ps.Thresholds {
			in.MSSQLThresholds[k] = v
		}
	}
}
