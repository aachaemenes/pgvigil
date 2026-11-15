// Package kits is KITWATCH's model of what pgvigil depends on in the community kits (the First Responder Kit,
// DarlingData, sp_WhoIsActive, PerformanceMonitor's ported reads): a tool's run as pgvigil's Run path answers it, the
// form and help /params gives, the columns the collector reads by name, and the blocks pgvigil's Go code ports. The
// weekly workflow (scripts/kitwatch.sh, .github/workflows/kitwatch.yml) runs the pinned and the newest kits through
// pgvigil and compares them here (cmd/kitshape); shapes.json and ports.json beside this file are the baseline.
//
// A difference is a Line of one of two classes (F4 of the design pass): BREAK - what pgvigil's code or page depends on
// changed (a column it reads by name, a coarse type, a set or column removed, a preset parameter, the help's
// descriptions, a new form parameter the write filter does not take out, a run that stops succeeding) - and DRIFT,
// what it does not (a column or set added, an exact type inside one coarse type, nullability, order, a parameter the
// filter takes out, a ported block or list that moved). INFO lines say what could not be compared (a set not read
// after a truncation, the set cap, a timeout).
package kits

import (
	"regexp"
	"strings"
)

// Class is a line's weight: BREAK turns the run red, DRIFT is a warning, INFO says what was not compared.
type Class string

// The three classes of a line.
const (
	Break Class = "BREAK" // pgvigil's code or page depends on what changed: the run is red
	Drift Class = "DRIFT" // a change pgvigil does not depend on: a warning on a green run
	Info  Class = "INFO"  // what could not be compared
)

// Column is one result column as the Run path answers it with exact_types: the page's coarse type (number / time /
// text) and the driver's SQL type and nullability (nil = the driver did not say).
type Column struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	SQLType  string `json:"sql_type,omitempty"`
	Nullable *bool  `json:"nullable,omitempty"`
}

// Set is one result set; Truncated: the Run path cut it (rows or bytes), so the sets after it were not read.
type Set struct {
	Columns   []Column `json:"columns"`
	Truncated bool     `json:"truncated,omitempty"`
}

// Param is one parameter of the installed procedure (sys.parameters).
type Param struct {
	Name   string `json:"name"`
	Type   string `json:"type"`
	Output bool   `json:"output,omitempty"`
}

// Run is one tool's shape: its kit and version, the run's outcome and sets, the form's parameters (what /params
// offers: the write filter has taken out what writes), every parameter of the procedure, how many form parameters carry
// a description, the parameters pgvigil's presets pass, and for the collector's entry the columns read by name.
type Run struct {
	Tool        string   `json:"tool"`
	Kit         string   `json:"kit"`
	Version     string   `json:"version,omitempty"`
	VersionDate string   `json:"version_date,omitempty"`
	SHA256      string   `json:"sha256,omitempty"`
	Outcome     string   `json:"outcome"` // done | declined | refused | failed | timeout
	Message     string   `json:"message,omitempty"`
	Sets        []Set    `json:"sets"`
	AtSetCap    bool     `json:"at_set_cap,omitempty"`
	FormParams  []string `json:"form_params,omitempty"`
	AllParams   []Param  `json:"all_params,omitempty"`
	Described   int      `json:"described"`
	Presets     []string `json:"presets,omitempty"`
	ReadByName  []string `json:"read_by_name,omitempty"`
	// HardSiblings: the kit procedures without whose EXECUTE the tool's run with the form's defaults fails (F3: found by
	// revoking every other kit procedure from the read login and running it, then one at a time)
	HardSiblings []string `json:"hard_siblings,omitempty"`
}

// Line is one difference, keyed by tool, kind and what for 'new since the last run'.
type Line struct {
	Class Class  `json:"class"`
	Tool  string `json:"tool"`
	Kind  string `json:"kind"`
	What  string `json:"what"`
	New   bool   `json:"new,omitempty"`
}

func (l Line) key() string { return l.Tool + "\x1f" + l.Kind + "\x1f" + l.What }

// Verdict is the run's exit for these lines: 1 when one is BREAK, else 0 (DRIFT and INFO warn only).
func Verdict(ls []Line) int {
	for _, l := range ls {
		if l.Class == Break {
			return 1
		}
	}
	return 0
}

// MarkNew marks each line the previous run's report did not have.
func MarkNew(now, prev []Line) {
	had := map[string]bool{}
	for _, l := range prev {
		had[l.key()] = true
	}
	for i := range now {
		now[i].New = !had[now[i].key()]
	}
}

var (
	frkVersion    = regexp.MustCompile(`@Version\s*=\s*'([^']+)'\s*,\s*@VersionDate\s*=\s*'(\d{8})'`)
	darlingVer    = regexp.MustCompile(`@version\s*=\s*'([^']+)'`)
	darlingDate   = regexp.MustCompile(`@version_date\s*=\s*'(\d{8})'`)
	whoIsActiveRE = regexp.MustCompile(`Who Is Active\? (v\d+\.(\d{8}))`)
)

// ParseVersion reads a kit's version and its date (yyyymmdd) from a procedure's own definition: FRK's
// "@Version = '8.34', @VersionDate = '20260702'", DarlingData's "@version = '6.11'" and "@version_date = '20261101'",
// sp_WhoIsActive's header "Who Is Active? v2200.20260409". Nothing is executed (F14).
func ParseVersion(def string) (version, date string, ok bool) {
	if m := frkVersion.FindStringSubmatch(def); m != nil {
		return m[1], m[2], true
	}
	if m := whoIsActiveRE.FindStringSubmatch(def); m != nil {
		return m[1], m[2], true
	}
	v, d := darlingVer.FindStringSubmatch(def), darlingDate.FindStringSubmatch(def)
	if v != nil && d != nil {
		return v[1], d[1], true
	}
	return "", "", false
}

// Newer says whether version date a (yyyymmdd) is after b; a kit's versions are compared by date (F14).
func Newer(a, b string) bool {
	return len(a) == 8 && len(b) == 8 && strings.Compare(a, b) > 0
}

// Version is a kit's version as pgvigil was checked against it (shapes.json's pinned pass; pinned_test.go keeps the
// two equal): the kit, the version string and its date (yyyymmdd).
type Version struct {
	Kit, Version, Date string
}

// Tools are the 13 community procedures pgvigil runs (the Run path; sp_WhoIsActive the collector too).
var Tools = []string{"sp_Blitz", "sp_BlitzCache", "sp_BlitzFirst", "sp_BlitzIndex", "sp_BlitzLock", "sp_BlitzWho",
	"sp_PressureDetector", "sp_QuickieStore", "sp_HumanEventsBlockViewer", "sp_HealthParser", "sp_LogHunter", "sp_IndexCleanup",
	"sp_WhoIsActive"}

var checked = map[string]Version{
	"sp_Blitz": {"First Responder Kit", "8.34", "20260702"}, "sp_BlitzCache": {"First Responder Kit", "8.34", "20260702"},
	"sp_BlitzFirst": {"First Responder Kit", "8.34", "20260702"}, "sp_BlitzIndex": {"First Responder Kit", "8.34", "20260702"},
	"sp_BlitzLock": {"First Responder Kit", "8.34", "20260702"}, "sp_BlitzWho": {"First Responder Kit", "8.34", "20260702"},
	"sp_PressureDetector": {"DarlingData", "6.11", "20261101"}, "sp_QuickieStore": {"DarlingData", "6.11", "20261101"},
	"sp_HumanEventsBlockViewer": {"DarlingData", "5.11", "20261101"}, "sp_HealthParser": {"DarlingData", "3.11", "20261101"},
	"sp_LogHunter": {"DarlingData", "3.11", "20261101"}, "sp_IndexCleanup": {"DarlingData", "2.11", "20261101"},
	"sp_WhoIsActive": {"sp_WhoIsActive", "v2200.20260409", "20260409"},
}

// Checked is the version pgvigil was checked against for a tool it runs (false: not one of them).
func Checked(tool string) (Version, bool) {
	v, ok := checked[tool]
	return v, ok
}

// NewerThanChecked says whether an installed version dated date is newer than the one pgvigil was checked against.
func NewerThanChecked(tool, date string) bool {
	c, ok := Checked(tool)
	return ok && Newer(date, c.Date)
}
