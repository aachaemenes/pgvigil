package kits

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Compare lists how got (this week's run) differs from want (the baseline, or this week's pinned pass): the outcome,
// the sets (aligned by their columns: a set has no name), each aligned set's columns by name, the columns the
// collector reads by name, the procedure's parameters, the form and the help.
func Compare(want, got Run) []Line {
	var out []Line
	add := func(c Class, kind, format string, a ...any) {
		out = append(out, Line{Class: c, Tool: got.Tool, Kind: kind, What: fmt.Sprintf(format, a...)})
	}
	switch {
	case want.Outcome == got.Outcome:
	case got.Outcome == "timeout":
		add(Info, "timeout", "slower than the Run path's limit (was %s): not compared", want.Outcome)
	default:
		add(Break, "outcome", "%s -> %s%s", want.Outcome, got.Outcome, strings.TrimSuffix(": "+got.Message, ": "))
	}
	// the sets and the columns read by name only when this run's sets are comparable: a timeout or a failed run has
	// none to speak of (its outcome line says it)
	if got.Outcome == want.Outcome || got.Outcome == "done" || got.Outcome == "declined" {
		compareSets(got.Tool, want.Sets, got.Sets, got.AtSetCap, add)
		for _, n := range want.ReadByName {
			if !hasColumn(got.Sets, n) {
				add(Break, "read by name", "%s, which pgvigil reads by name, is not in the shape", n)
			}
		}
	}
	if got.AtSetCap {
		add(Info, "set cap", "the run returned more than pgvigil's 50 result sets: the ones past it were not read")
	}
	compareParams(want, got, add)
	compareSiblings(want, got, add)
	if got.Described < want.Described {
		add(Break, "help", "descriptions %d of %d form parameters (was %d): the help form's cells are not read", got.Described, len(got.FormParams), want.Described)
	}
	return out
}

// compareSiblings: a procedure the tool now fails without is BREAK, one it no longer needs DRIFT - unless either side's
// search did not finish (SiblingsUnknown): then one INFO line and nothing compared
func compareSiblings(want, got Run, add func(Class, string, string, ...any)) {
	switch {
	case got.SiblingsUnknown != "":
		add(Info, "siblings unknown", "this run's: %s - not compared", got.SiblingsUnknown)
		return
	case want.SiblingsUnknown != "":
		add(Info, "siblings unknown", "the baseline's: %s - not compared", want.SiblingsUnknown)
		return
	}
	var newSib, goneSib []string
	for _, x := range got.HardSiblings {
		if !slices.Contains(want.HardSiblings, x) {
			newSib = append(newSib, x)
		}
	}
	for _, x := range want.HardSiblings {
		if !slices.Contains(got.HardSiblings, x) {
			goneSib = append(goneSib, x)
		}
	}
	if len(newSib) > 0 {
		add(Break, "new hard sibling", "%s: the run fails without EXECUTE on it (a site that granted only the listed procedures fails)", strings.Join(newSib, ", "))
	}
	if len(goneSib) > 0 {
		add(Drift, "sibling no longer needed", "%s", strings.Join(goneSib, ", "))
	}
}

func hasColumn(sets []Set, name string) bool {
	for _, s := range sets {
		for _, c := range s.Columns {
			if strings.EqualFold(c.Name, name) {
				return true
			}
		}
	}
	return false
}

func names(s Set) []string {
	out := make([]string, len(s.Columns))
	for i, c := range s.Columns {
		out[i] = strings.ToLower(c.Name)
	}
	return out
}

// overlap is the share of two sets' column names they have in common (of the larger)
func overlap(a, b Set) float64 {
	an, bn := names(a), names(b)
	if len(an) == 0 || len(bn) == 0 {
		return 0
	}
	n := 0
	for _, x := range an {
		if slices.Contains(bn, x) {
			n++
		}
	}
	return float64(n) / float64(max(len(an), len(bn)))
}

func colList(s Set) string { return strings.Join(names(s), ", ") }

// compareSets aligns the baseline's sets with this run's in order (a set matches the next one sharing at least half
// its columns, or at its own place the same set without rows: 'no rows', INFO): a set skipped in got is added (DRIFT),
// a set of want with no match is removed (BREAK) - unless got was cut before it (a truncated set, the set cap): then
// the rest is 'unread' (INFO).
func compareSets(tool string, want, got []Set, atCap bool, add func(Class, string, string, ...any)) {
	j := 0
	for i, w := range want {
		if j < len(got) && noRows(tool, w, got[j]) {
			if len(got[j].Columns) == 1 {
				add(Info, "no rows", "set %d came back as its one-column %s set (no rows this run): its columns (%s) not compared", i+1, got[j].Columns[0].Name, colList(w))
			} else {
				add(Info, "no rows", "set %d is the one-column %s set in the baseline (no rows there): this run's columns (%s) are not in it", i+1, w.Columns[0].Name, colList(got[j]))
			}
			j++
			continue
		}
		k := -1
		for x := j; x < len(got); x++ {
			if overlap(w, got[x]) >= 0.5 {
				k = x
				break
			}
		}
		if k < 0 {
			cut := atCap || (len(got) > 0 && got[len(got)-1].Truncated)
			if cut {
				add(Info, "unread", "sets %d-%d of %d not read: the run was cut at set %d", i+1, len(want), len(want), len(got))
				return
			}
			add(Break, "set removed", "set %d (%s) is gone", i+1, colList(w))
			continue
		}
		for x := j; x < k; x++ {
			add(Drift, "set added", "a new set before set %d (%s)", i+1, colList(got[x]))
		}
		compareColumns(i+1, w, got[k], add)
		j = k + 1
	}
	for x := j; x < len(got); x++ {
		add(Drift, "set added", "a new set at the end (%s)", colList(got[x]))
	}
}

// noRowsPlaceholder: the two tools whose section without rows comes back as one column in place of its columns, and
// that column's exact name (sp_HealthParser's finding = 'no queries with significant waits found ...',
// sp_PressureDetector's THREADPOOL = 'No current THREADPOOL waits'): their shape follows the data, not the kit
var noRowsPlaceholder = map[string]string{"sp_HealthParser": "finding", "sp_PressureDetector": "threadpool"}

// noRows: at the set's own place in the order, for those two tools only, one of the two sets is the tool's one-column
// placeholder (its exact name, any case) and the other has three or more columns, one of which names it.
func noRows(tool string, a, b Set) bool {
	ph, ok := noRowsPlaceholder[tool]
	if !ok {
		return false
	}
	one, full := a, b
	if len(one.Columns) != 1 {
		one, full = b, a
	}
	if len(one.Columns) != 1 || len(full.Columns) < 3 || !strings.EqualFold(one.Columns[0].Name, ph) {
		return false
	}
	return slices.ContainsFunc(names(full), func(x string) bool { return strings.Contains(x, ph) })
}

// compareColumns compares one aligned set's columns by name: removed (BREAK), added (DRIFT), the coarse type (BREAK),
// the exact type and nullability (DRIFT), and the order of the columns both have (DRIFT, one line)
func compareColumns(n int, w, g Set, add func(Class, string, string, ...any)) {
	gi := map[string]Column{}
	for _, c := range g.Columns {
		gi[strings.ToLower(c.Name)] = c
	}
	wi := map[string]bool{}
	var wOrder, gOrder []string
	for _, c := range w.Columns {
		k := strings.ToLower(c.Name)
		wi[k] = true
		h, ok := gi[k]
		if !ok {
			add(Break, "column removed", "set %d: %s removed", n, c.Name)
			continue
		}
		wOrder = append(wOrder, k)
		switch {
		case c.Type != h.Type:
			add(Break, "type", "set %d: %s %s -> %s (%s)", n, c.Name, c.Type, h.Type, h.SQLType)
		case c.SQLType != "" && h.SQLType != "" && !strings.EqualFold(c.SQLType, h.SQLType):
			add(Drift, "type", "set %d: %s %s -> %s", n, c.Name, c.SQLType, h.SQLType)
		}
		if c.Nullable != nil && h.Nullable != nil && *c.Nullable != *h.Nullable {
			add(Drift, "nullability", "set %d: %s nullable %v -> %v", n, c.Name, *c.Nullable, *h.Nullable)
		}
	}
	for _, c := range g.Columns {
		k := strings.ToLower(c.Name)
		if !wi[k] {
			add(Drift, "column added", "set %d: %s added (%s)", n, c.Name, c.SQLType)
			continue
		}
		gOrder = append(gOrder, k)
	}
	if !slices.Equal(wOrder, gOrder) {
		add(Drift, "reordered", "set %d: %s (was %s)", n, strings.Join(gOrder, ", "), strings.Join(wOrder, ", "))
	}
}

// compareParams: a preset's parameter gone (BREAK), a new parameter the page's form offers - the write filter did not
// take it out (BREAK: decide whether it writes), a parameter added that the filter takes out, a parameter gone, a
// parameter's type (DRIFT); one line per kind.
func compareParams(want, got Run, add func(Class, string, string, ...any)) {
	in := func(ps []Param, n string) (Param, bool) {
		for _, p := range ps {
			if strings.EqualFold(p.Name, n) {
				return p, true
			}
		}
		return Param{}, false
	}
	var presetGone, gone, added, offered, retyped []string
	for _, p := range want.AllParams {
		h, ok := in(got.AllParams, p.Name)
		switch {
		case !ok && slices.ContainsFunc(want.Presets, func(s string) bool { return strings.EqualFold(s, p.Name) }):
			presetGone = append(presetGone, p.Name)
		case !ok:
			gone = append(gone, p.Name)
		case !strings.EqualFold(p.Type, h.Type) || p.Output != h.Output:
			retyped = append(retyped, fmt.Sprintf("%s %s -> %s", p.Name, p.Type, h.Type))
		}
	}
	for _, n := range want.Presets {
		if _, ok := in(want.AllParams, n); !ok {
			if _, ok := in(got.AllParams, n); !ok && len(got.AllParams) > 0 {
				presetGone = append(presetGone, n)
			}
		}
	}
	for _, n := range got.FormParams {
		if !slices.ContainsFunc(want.FormParams, func(s string) bool { return strings.EqualFold(s, n) }) {
			if _, had := in(want.AllParams, n); !had {
				offered = append(offered, n)
			}
		}
	}
	for _, p := range got.AllParams {
		if _, ok := in(want.AllParams, p.Name); !ok && !slices.ContainsFunc(offered, func(s string) bool { return strings.EqualFold(s, p.Name) }) {
			added = append(added, p.Name)
		}
	}
	if len(presetGone) > 0 {
		add(Break, "preset parameter removed", "%s, which a pgvigil preset passes, is gone: the run is refused", strings.Join(presetGone, ", "))
	}
	if len(offered) > 0 {
		add(Break, "new form parameter", "%s offered on the form: decide whether it writes (q_community.go's writeParam)", strings.Join(offered, ", "))
	}
	if len(added) > 0 {
		add(Drift, "parameter added", "%s (the form's write filter takes it out)", strings.Join(added, ", "))
	}
	if len(gone) > 0 {
		add(Drift, "parameter removed", "%s", strings.Join(gone, ", "))
	}
	if len(retyped) > 0 {
		add(Drift, "parameter type", "%s", strings.Join(retyped, "; "))
	}
}

// Port is one block pgvigil's Go code ports from a kit's file (ports.json): the file, the version it follows, the two
// anchors around the block, the block's sha256 and, for a data list, the items (ItemRE's first group over the block).
type Port struct {
	Name    string   `json:"name"`
	GoFile  string   `json:"go_file"`
	Repo    string   `json:"repo"`
	Path    string   `json:"path"`
	Follows string   `json:"follows"`
	Begin   string   `json:"begin"`
	End     string   `json:"end"`
	SHA256  string   `json:"sha256"`
	ItemRE  string   `json:"item_re,omitempty"`
	Items   []string `json:"items,omitempty"`
}

// Block finds the port's block in a file: from Begin through the first End after it ("" when an anchor is gone).
func (p Port) Block(file []byte) string {
	s := string(file)
	b := strings.Index(s, p.Begin)
	if b < 0 {
		return ""
	}
	e := strings.Index(s[b:], p.End)
	if e < 0 {
		return ""
	}
	return s[b : b+e+len(p.End)]
}

// ItemsOf reads a list port's items from a block.
func (p Port) ItemsOf(block string) []string {
	if p.ItemRE == "" {
		return nil
	}
	var out []string
	for _, m := range regexp.MustCompile(p.ItemRE).FindAllStringSubmatch(block, -1) {
		if len(m) > 1 {
			out = append(out, m[1])
		}
	}
	return out
}

// Hash is a block's sha256 in hex.
func Hash(block string) string {
	h := sha256.Sum256([]byte(block))
	return hex.EncodeToString(h[:])
}

// PortFileGone: the port's file is not in the newest kit (the fetch's 404): DRIFT, as an anchor gone - the block moved
// or went, re-read where (a fetch that failed otherwise stops the run: kitwatch.sh's exit 3)
func PortFileGone(p Port) []Line {
	return []Line{{Class: Drift, Tool: p.Name, Kind: "file gone", What: fmt.Sprintf("port %s (%s): %s/%s is gone from the newest kit: re-read where it moved", p.Name, p.GoFile, p.Repo, p.Path)}}
}

// ComparePort says how the newest file's block differs from the port's (never BREAK: a stale copy does not stop
// pgvigil, it is a 're-read').
func ComparePort(p Port, file []byte) []Line {
	at := fmt.Sprintf("port %s (%s)", p.Name, p.GoFile)
	block := p.Block(file)
	if block == "" {
		return []Line{{Class: Drift, Tool: p.Name, Kind: "anchor gone", What: fmt.Sprintf("%s: the anchors are not in %s: re-read it", at, p.Path)}}
	}
	if Hash(block) == p.SHA256 {
		return nil
	}
	if p.ItemRE != "" {
		now := p.ItemsOf(block)
		var diff []string
		for _, x := range now {
			if !slices.Contains(p.Items, x) {
				diff = append(diff, "+"+x)
			}
		}
		for _, x := range p.Items {
			if !slices.Contains(now, x) {
				diff = append(diff, "-"+x)
			}
		}
		if len(diff) > 0 {
			sort.Strings(diff)
			return []Line{{Class: Drift, Tool: p.Name, Kind: "list", What: fmt.Sprintf("%s: %s - re-read", at, strings.Join(diff, ", "))}}
		}
	}
	return []Line{{Class: Drift, Tool: p.Name, Kind: "block changed", What: fmt.Sprintf("%s: %s changed between the anchors - re-read", at, p.Path)}}
}
