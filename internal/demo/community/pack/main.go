// Command pack turns the capture's raw answers (scripts/capture-community-samples.sh: each tool's POST
// /api/community/run answer and, for a procedure, its POST /api/community/params answer, with meta.json) into the
// demo's stored samples: the test server's own names replaced by fixed words, every IPv4 address by "(address)",
// plan XML columns left out, a set cut at 200 rows and a cell at 16 KB (each said in the sample), gzipped JSON one
// file per tool under internal/demo/community/samples. It fails on a run that did not end done, a sample without
// rows, a name the scan denies, or a set over community.MaxBytes; the files of an earlier capture are replaced.
//
//	go run ./internal/demo/community/pack -raw <folder> [-out internal/demo/community/samples]
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/aachaemenes/pgvigil/internal/demo/community"
)

const (
	maxRows = 200
	maxCell = 16 << 10
)

type toolMeta struct {
	Tool        string            `json:"tool"`
	Engine      string            `json:"engine"`
	Kit         string            `json:"kit"`
	Version     string            `json:"version"`
	VersionDate string            `json:"version_date"`
	Help        bool              `json:"help"` // the kit is MIT: its parameters' help text may be stored
	Database    string            `json:"database"`
	Params      map[string]string `json:"params"`
}

type meta struct {
	CapturedAt time.Time         `json:"captured_at"`
	Servers    map[string]string `json:"servers"`
	Tools      []toolMeta        `json:"tools"`
	Replace    [][2]string       `json:"replace"` // the test server's own names and the fixed word each becomes
	Deny       []string          `json:"deny"`
}

type runAnswer struct {
	Runs []struct {
		Outcome string          `json:"outcome"`
		Error   string          `json:"error"`
		Sets    []community.Set `json:"sets"`
	} `json:"runs"`
}

type paramsAnswer struct {
	Params []struct {
		Name      string `json:"name"`
		Type      string `json:"type"`
		MaxLength int    `json:"max_length"`
		Help      string `json:"help"`
	} `json:"params"`
}

func main() {
	raw := flag.String("raw", "", "the capture's raw answers and meta.json")
	out := flag.String("out", filepath.Join("internal", "demo", "community", community.Dir), "where the samples go")
	flag.Parse()
	if *raw == "" {
		fmt.Fprintln(os.Stderr, "pack: -raw <folder> is required")
		os.Exit(2)
	}
	if err := run(*raw, *out); err != nil {
		fmt.Fprintln(os.Stderr, "pack:", err)
		os.Exit(1)
	}
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	return d.Decode(v)
}

// scrubber replaces the test server's own names (longest first, without case) and IPv4 addresses, counting per word.
type scrubber struct {
	res   []*regexp.Regexp
	to    []string
	count map[string]int
}

func newScrubber(pairs [][2]string) *scrubber {
	sort.SliceStable(pairs, func(i, j int) bool { return len(pairs[i][0]) > len(pairs[j][0]) })
	s := &scrubber{count: map[string]int{}}
	for _, p := range pairs {
		// a short name, or one an ordinary cell holds (localhost), would replace parts of ordinary words
		if w := strings.TrimSpace(p[0]); len(w) < 4 || strings.EqualFold(w, "localhost") {
			continue
		}
		s.res = append(s.res, regexp.MustCompile(`(?i)`+regexp.QuoteMeta(p[0])))
		s.to = append(s.to, p[1])
	}
	return s
}

func (s *scrubber) str(v string) string {
	for i, re := range s.res {
		if re.MatchString(v) {
			v = re.ReplaceAllLiteralString(v, s.to[i])
			s.count[s.to[i]]++
		}
	}
	if w := community.ScrubIPv4(v); w != v {
		s.count["(address)"]++
		v = w
	}
	return v
}

// any scrubs a cell: a string, or the strings inside an array or an object (a cell PostgreSQL returns as one)
func (s *scrubber) any(v any) any {
	switch x := v.(type) {
	case string:
		return s.str(x)
	case []any:
		for i := range x {
			x[i] = s.any(x[i])
		}
	case map[string]any:
		for k := range x {
			x[k] = s.any(x[k])
		}
	}
	return v
}

func (s *scrubber) lines() []string {
	var out []string
	for w, n := range s.count {
		out = append(out, fmt.Sprintf("%s (%d cells)", w, n))
	}
	sort.Strings(out)
	return out
}

var planXML = regexp.MustCompile(`^\s*(<\?xml[^>]*>\s*)?<ShowPlanXML`)

func run(raw, out string) error {
	var m meta
	if err := readJSON(filepath.Join(raw, "meta.json"), &m); err != nil {
		return fmt.Errorf("meta.json: %w", err)
	}
	deny := append(append([]string{}, m.Deny...), community.EnvDeny()...)
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	var bad []string
	total := 0
	files := map[string][]byte{}
	for _, t := range m.Tools {
		s, err := one(raw, m, t)
		if err != nil {
			bad = append(bad, t.Tool+": "+err.Error())
			fmt.Printf("pack %s: FAILED %v\n", t.Tool, err)
			continue
		}
		text, err := json.Marshal(s)
		if err != nil {
			return err
		}
		if hits := community.Deny(text, deny); len(hits) > 0 {
			bad = append(bad, t.Tool+": denied: "+strings.Join(hits, "; "))
			fmt.Printf("deny %s: %s\n", t.Tool, strings.Join(hits, "; "))
			continue
		}
		gz, err := community.Encode(s)
		if err != nil {
			return err
		}
		files[t.Tool] = gz
		total += len(gz)
		fmt.Printf("pack %s: %d sets, %d rows, %d bytes (json %d)%s\n", t.Tool, len(s.Sets), s.Rows(), len(gz), len(text), notes(s))
	}
	fmt.Printf("pack: %d samples, %d bytes (cap %d)\n", len(m.Tools)-len(bad), total, community.MaxBytes)
	if total > community.MaxBytes {
		bad = append(bad, fmt.Sprintf("the samples are %d bytes, over the cap of %d", total, community.MaxBytes))
	}
	if len(bad) > 0 {
		return fmt.Errorf("%d problem(s), nothing written (the samples in %s stay as they were):\n  %s", len(bad), out, strings.Join(bad, "\n  "))
	}
	// every sample passed: the earlier capture's files go, these take their place
	old, _ := filepath.Glob(filepath.Join(out, "*.json.gz"))
	for _, f := range old {
		if err := os.Remove(f); err != nil {
			return err
		}
	}
	for tool, gz := range files {
		if err := os.WriteFile(filepath.Join(out, tool+".json.gz"), gz, 0o644); err != nil {
			return err
		}
	}
	return nil
}

func notes(s *community.Sample) string {
	var n []string
	if len(s.Dropped) > 0 {
		n = append(n, "dropped "+strings.Join(s.Dropped, ", "))
	}
	if len(s.Cut) > 0 {
		n = append(n, "cut "+strings.Join(s.Cut, ", "))
	}
	if len(s.Scrubbed) > 0 {
		n = append(n, "scrubbed "+strings.Join(s.Scrubbed, ", "))
	}
	if len(n) == 0 {
		return ""
	}
	return "; " + strings.Join(n, "; ")
}

func one(raw string, m meta, t toolMeta) (*community.Sample, error) {
	var a runAnswer
	if err := readJSON(filepath.Join(raw, t.Tool+".run.json"), &a); err != nil {
		return nil, err
	}
	if len(a.Runs) != 1 {
		return nil, fmt.Errorf("%d runs in the answer", len(a.Runs))
	}
	r := a.Runs[0]
	if r.Outcome != "done" {
		return nil, fmt.Errorf("the run ended %s: %s", r.Outcome, r.Error)
	}
	sc := newScrubber(m.Replace)
	s := &community.Sample{Tool: t.Tool, Engine: t.Engine, Kit: t.Kit, Version: t.Version, VersionDate: t.VersionDate,
		CapturedAt: m.CapturedAt.UTC().Truncate(time.Second), Server: m.Servers[t.Engine], Database: t.Database, Params: map[string]string{}}
	for k, v := range t.Params {
		s.Params[k] = sc.str(v)
	}
	if p := filepath.Join(raw, t.Tool+".params.json"); fileExists(p) {
		var pa paramsAnswer
		if err := readJSON(p, &pa); err != nil {
			return nil, err
		}
		for _, x := range pa.Params {
			typ := x.Type
			if x.MaxLength != 0 && strings.Contains(strings.ToLower(typ), "char") {
				switch n := x.MaxLength; {
				case n < 0:
					typ += "(max)"
				case strings.HasPrefix(strings.ToLower(typ), "n"):
					typ += fmt.Sprintf("(%d)", n/2) // sys.parameters.max_length is in bytes: two per nchar / nvarchar character
				default:
					typ += fmt.Sprintf("(%d)", n)
				}
			}
			d := community.ParamDoc{Name: x.Name, Type: typ}
			if t.Help {
				d.Help = sc.str(x.Help)
			}
			s.ParamDoc = append(s.ParamDoc, d)
		}
	}
	for i, set := range r.Sets {
		set = dropPlans(set, i, s)
		set = dropOwn(set, i, t.Tool, s)
		if len(set.Rows) > maxRows {
			s.Cut = append(s.Cut, fmt.Sprintf("set %d: the first %d of %d rows", i+1, maxRows, len(set.Rows)))
			set.Rows = set.Rows[:maxRows]
			set.Truncated = true
		}
		cut := 0
		for _, row := range set.Rows {
			for j, v := range row {
				if str, ok := v.(string); ok {
					str = sc.str(str)
					if len(str) > maxCell {
						n := maxCell
						for n > 0 && !utf8.RuneStart(str[n]) { // never half a character
							n--
						}
						str = str[:n] + " [cut for the demo]"
						cut++
					}
					row[j] = str
				} else {
					row[j] = sc.any(v)
				}
			}
		}
		if cut > 0 {
			s.Cut = append(s.Cut, fmt.Sprintf("set %d: %d cells at 16 KB", i+1, cut))
		}
		s.Sets = append(s.Sets, set)
	}
	s.Scrubbed = sc.lines()
	if s.Rows() == 0 {
		return nil, fmt.Errorf("no rows in any of its %d result sets (a sample without rows is not a sample)", len(s.Sets))
	}
	return s, nil
}

// dropOwn leaves out the rows the capture's own logins ran (community.OwnRows names the column per tool), and says so.
func dropOwn(set community.Set, idx int, tool string, s *community.Sample) community.Set {
	c := slices.Index(set.Columns, community.OwnRows[tool])
	if community.OwnRows[tool] == "" || c < 0 {
		return set
	}
	keep, n := make([][]any, 0, len(set.Rows)), 0
	for _, row := range set.Rows {
		if v, ok := row[c].(string); ok && slices.Contains(community.CaptureLogins, v) {
			n++
			continue
		}
		keep = append(keep, row)
	}
	if n > 0 {
		s.Cut = append(s.Cut, fmt.Sprintf("set %d: %d rows of the capture's own login (%s)", idx+1, n, strings.Join(community.CaptureLogins, ", ")))
		set.Rows = keep
	}
	return set
}

// dropPlans leaves out every column of set whose cells hold showplan XML, and says so in the sample.
func dropPlans(set community.Set, idx int, s *community.Sample) community.Set {
	var drop []int
	for c := range set.Columns {
		for _, row := range set.Rows {
			if c < len(row) {
				if str, ok := row[c].(string); ok && planXML.MatchString(str) {
					drop = append(drop, c)
					break
				}
			}
		}
	}
	if len(drop) == 0 {
		return set
	}
	gone := map[int]bool{}
	for _, c := range drop {
		gone[c] = true
		s.Dropped = append(s.Dropped, fmt.Sprintf("%s (set %d: plan XML)", set.Columns[c], idx+1))
	}
	keep := func(n int) []int {
		var k []int
		for i := 0; i < n; i++ {
			if !gone[i] {
				k = append(k, i)
			}
		}
		return k
	}
	k := keep(len(set.Columns))
	out := community.Set{Truncated: set.Truncated}
	for _, i := range k {
		out.Columns = append(out.Columns, set.Columns[i])
		if i < len(set.Types) {
			out.Types = append(out.Types, set.Types[i])
		}
	}
	for _, row := range set.Rows {
		var nr []any
		for _, i := range k {
			if i < len(row) {
				nr = append(nr, row[i])
			}
		}
		out.Rows = append(out.Rows, nr)
	}
	return out
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}
