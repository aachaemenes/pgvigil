// Command kitshape is KITWATCH's compare (scripts/kitwatch.sh calls it; nothing here touches a server):
//
//	kitshape compare -want shapes.json -got run.json -out lines.json [-label words]   the tools' lines (internal/community/kits)
//	kitshape ports -manifest ports.json -dir <files> -out lines.json  the ported blocks' lines (files at <dir>/<repo>/<path>)
//	kitshape pin -manifest ports.json -dir <files>                    -baseline: each port's sha256 and items from the files
//	kitshape version <file>...                                        a definition's kit version and date, tab-separated
//	kitshape args                                                     the collector's sp_WhoIsActive parameters
//	kitshape report -lines a.json,b.json [-prev old-report.json] -out report.json -text report.txt
//	kitshape deny <file>...                                           the demo's deny list over files (-baseline's shapes / ports)
//
// report merges the line files, marks each line new or not against the previous run's report, runs the demo's deny
// list over each line (the repository is public: a hit is REDACTED and counted, never dropped with the report), writes
// both forms and exits 1 when a line is BREAK, else 0. deny exits 1 on a hit. Every other subcommand exits 0 on success
// and 3 when it could not run.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/community/kits"
	"github.com/aachaemenes/pgvigil/internal/demo/community"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// Shapes is shapes.json and a week's run file alike: the kits as installed and every tool's run.
type Shapes struct {
	Engine string     `json:"engine,omitempty"`
	Kits   []Kit      `json:"kits"`
	Runs   []kits.Run `json:"runs"`
}

// Kit is one kit as installed: where it came from and what it said it was.
type Kit struct {
	Kit         string `json:"kit"`
	URL         string `json:"url,omitempty"`
	SHA256      string `json:"sha256,omitempty"`
	Version     string `json:"version,omitempty"`
	VersionDate string `json:"version_date,omitempty"`
}

// Report is the run's report: the lines and the verdict.
type Report struct {
	Verdict int         `json:"verdict"`
	Denied  int         `json:"denied"` // lines whose text the deny list redacted
	Lines   []kits.Line `json:"lines"`
}

func main() {
	if len(os.Args) < 2 {
		fail(errors.New("usage: kitshape compare|ports|pin|version|args|report ..."))
	}
	var err error
	code := 0
	switch os.Args[1] {
	case "compare":
		err = compare(os.Args[2:])
	case "ports":
		err = ports(os.Args[2:])
	case "pin":
		err = pin(os.Args[2:])
	case "version":
		for _, f := range os.Args[2:] {
			b, rerr := os.ReadFile(f)
			if rerr != nil {
				fail(rerr)
			}
			v, d, ok := kits.ParseVersion(string(b))
			if !ok {
				v, d = "-", "-"
			}
			fmt.Printf("%s\t%s\t%s\n", f, v, d)
		}
	case "args":
		fmt.Println(mssql.WhoIsActiveArgs)
	case "report":
		code, err = report(os.Args[2:])
	case "deny":
		for _, f := range os.Args[2:] {
			b, rerr := os.ReadFile(f)
			if rerr != nil {
				fail(rerr)
			}
			if hits := community.Deny(b, community.EnvDeny()); len(hits) > 0 {
				fmt.Printf("%s: %s\n", f, strings.Join(hits, "; "))
				code = 1
			}
		}
	default:
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fail(err)
	}
	os.Exit(code)
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "kitshape:", err)
	os.Exit(3)
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

// compare: every baseline tool against this run's (a tool missing from the run is BREAK; a tool new in it is INFO)
func compare(args []string) error {
	fs := flag.NewFlagSet("compare", flag.ContinueOnError)
	want, got, out := fs.String("want", "", "the baseline"), fs.String("got", "", "this run"), fs.String("out", "", "the lines file")
	label := fs.String("label", "", "words after each line's tool (the pinned pass against shapes.json: 'pgvigil or the environment')")
	if err := fs.Parse(args); err != nil {
		return err
	}
	var w, g Shapes
	if err := readJSON(*want, &w); err != nil {
		return fmt.Errorf("the baseline %s: %w", *want, err)
	}
	if err := readJSON(*got, &g); err != nil {
		return fmt.Errorf("the run %s: %w", *got, err)
	}
	byTool := map[string]kits.Run{}
	for _, r := range g.Runs {
		byTool[r.Tool] = r
	}
	var lines []kits.Line
	for _, r := range w.Runs {
		h, ok := byTool[r.Tool]
		if !ok {
			lines = append(lines, kits.Line{Class: kits.Break, Tool: r.Tool, Kind: "tool missing", What: "no run of it in this pass (its kit's install, or the run itself, did not happen)"})
			continue
		}
		lines = append(lines, kits.Compare(r, h)...)
		delete(byTool, r.Tool)
	}
	extra := make([]string, 0, len(byTool))
	for t := range byTool {
		extra = append(extra, t)
	}
	sort.Strings(extra)
	for _, t := range extra {
		lines = append(lines, kits.Line{Class: kits.Info, Tool: t, Kind: "tool new", What: "a run the baseline does not hold"})
	}
	if *label != "" {
		for i := range lines {
			lines[i].Tool += " (" + *label + ")"
		}
	}
	return writeJSON(*out, lines)
}

func portFile(dir string, p kits.Port) string {
	return filepath.Join(dir, filepath.FromSlash(p.Repo), filepath.FromSlash(p.Path))
}

// ports: each port's block in the newest file (a file not fetched is a line, not a stop)
func ports(args []string) error {
	fs := flag.NewFlagSet("ports", flag.ContinueOnError)
	manifest, dir, out := fs.String("manifest", "", "ports.json"), fs.String("dir", "", "the fetched files"), fs.String("out", "", "the lines file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	var ps []kits.Port
	if err := readJSON(*manifest, &ps); err != nil {
		return fmt.Errorf("the manifest %s: %w", *manifest, err)
	}
	var lines []kits.Line
	for _, p := range ps {
		b, err := os.ReadFile(portFile(*dir, p))
		if err != nil {
			lines = append(lines, kits.Line{Class: kits.Info, Tool: p.Name, Kind: "not fetched", What: fmt.Sprintf("port %s (%s): %s/%s was not read: %v", p.Name, p.GoFile, p.Repo, p.Path, err)})
			continue
		}
		lines = append(lines, kits.ComparePort(p, b)...)
	}
	return writeJSON(*out, lines)
}

// pin: -baseline - each port's sha256 and items from the files, written back into the manifest
func pin(args []string) error {
	fs := flag.NewFlagSet("pin", flag.ContinueOnError)
	manifest, dir := fs.String("manifest", "", "ports.json"), fs.String("dir", "", "the fetched files")
	if err := fs.Parse(args); err != nil {
		return err
	}
	var ps []kits.Port
	if err := readJSON(*manifest, &ps); err != nil {
		return fmt.Errorf("the manifest %s: %w", *manifest, err)
	}
	for i, p := range ps {
		b, err := os.ReadFile(portFile(*dir, p))
		if err != nil {
			return fmt.Errorf("port %s: %w", p.Name, err)
		}
		block := p.Block(b)
		if block == "" {
			return fmt.Errorf("port %s: its anchors are not in %s", p.Name, p.Path)
		}
		ps[i].SHA256, ps[i].Items = kits.Hash(block), p.ItemsOf(block)
	}
	return writeJSON(*manifest, ps)
}

// report: the merged lines, each marked new or not against the previous report; exit 1 on a BREAK line
func report(args []string) (int, error) {
	fs := flag.NewFlagSet("report", flag.ContinueOnError)
	files, prev := fs.String("lines", "", "comma-separated line files"), fs.String("prev", "", "the previous run's report.json")
	out, text := fs.String("out", "", "report.json"), fs.String("text", "", "report.txt")
	if err := fs.Parse(args); err != nil {
		return 3, err
	}
	var all []kits.Line
	for _, f := range strings.Split(*files, ",") {
		if f == "" {
			continue
		}
		var ls []kits.Line
		if err := readJSON(f, &ls); err != nil {
			return 3, fmt.Errorf("the lines %s: %w", f, err)
		}
		all = append(all, ls...)
	}
	if *prev != "" {
		var old Report
		if err := readJSON(*prev, &old); err == nil {
			kits.MarkNew(all, old.Lines)
		}
	}
	denied := 0
	for i := range all {
		all[i].What = community.ScrubIPv4(all[i].What)
		if hits := community.Deny([]byte(all[i].Tool+" "+all[i].What), community.EnvDeny()); len(hits) > 0 {
			all[i].What, denied = "(redacted: the text held "+strings.Join(hits, "; ")+")", denied+1
		}
	}
	r := Report{Verdict: kits.Verdict(all), Denied: denied, Lines: all}
	if r.Lines == nil {
		r.Lines = []kits.Line{}
	}
	if err := writeJSON(*out, r); err != nil {
		return 3, err
	}
	var b strings.Builder
	order := map[kits.Class]int{kits.Break: 0, kits.Drift: 1, kits.Info: 2}
	sort.SliceStable(all, func(i, j int) bool { return order[all[i].Class] < order[all[j].Class] })
	for _, l := range all {
		mark := ""
		if l.New {
			mark = " (new)"
		}
		fmt.Fprintf(&b, "%-5s %s %s: %s%s\n", l.Class, l.Tool, l.Kind, l.What, mark)
	}
	if len(all) == 0 {
		b.WriteString("SAME: no difference\n")
	}
	if err := os.WriteFile(*text, []byte(b.String()), 0o644); err != nil {
		return 3, err
	}
	return r.Verdict, nil
}
