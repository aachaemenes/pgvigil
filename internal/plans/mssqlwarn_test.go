package plans

import (
	"bufio"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The plans under testdata/mssqlwarn/captured are real SQL Server 2022 plans taken by testdata/mssqlwarn/capture.sh
// from a throwaway container (invented names only); cases.tsv says what each must raise.

const warnDir = "testdata/mssqlwarn"

type warnCase struct {
	line             int
	name, src        string
	ctp, nowDays     int
	nowSet           bool
	rt               string // "bc", "-" or the explicit k:v list
	raise, not, nj   []string
	rows, note, text string
}

func splitList(s string) []string {
	if s == "-" || s == "" {
		return nil
	}
	return strings.Split(s, ",")
}

func readWarnCases(t *testing.T) []warnCase {
	t.Helper()
	f, err := os.Open(filepath.Join(warnDir, "cases.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []warnCase
	sc := bufio.NewScanner(f)
	n := 0
	for sc.Scan() {
		n++
		ln := sc.Text()
		if ln == "" || strings.HasPrefix(ln, "#") || strings.HasPrefix(ln, "case\t") {
			continue
		}
		col := strings.Split(ln, "\t")
		if len(col) != 8 {
			t.Fatalf("cases.tsv line %d: %d columns, not 8", n, len(col))
		}
		c := warnCase{line: n, name: col[0], src: col[1], rt: "-", raise: splitList(col[3]), not: splitList(col[4]),
			nj: splitList(col[5]), rows: col[6], note: col[7], text: ln}
		for _, tok := range strings.Fields(col[2]) {
			k, v, _ := strings.Cut(tok, "=")
			switch k {
			case "ctp":
				if v != "-" {
					if c.ctp, err = strconv.Atoi(v); err != nil {
						t.Fatalf("cases.tsv line %d: ctp %q", n, v)
					}
				}
			case "now":
				if v != "-" {
					d := strings.TrimSuffix(strings.TrimPrefix(v, "+"), "d")
					if c.nowDays, err = strconv.Atoi(d); err != nil {
						t.Fatalf("cases.tsv line %d: now %q", n, v)
					}
					c.nowSet = true
				}
			case "rt":
				c.rt = v
			default:
				t.Fatalf("cases.tsv line %d: unknown input %q", n, tok)
			}
		}
		out = append(out, c)
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// readOracle reads captured/blitzcache-8.34.tsv: each row of a case by its column names.
func readOracle(t *testing.T) map[string]map[string]string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(warnDir, "captured", "blitzcache-8.34.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	head := strings.Split(lines[0], "\t")
	out := map[string]map[string]string{}
	for _, ln := range lines[1:] {
		f := strings.Split(ln, "\t")
		if len(f) != len(head) {
			t.Fatalf("blitzcache-8.34.tsv: a row of %d fields, not %d", len(f), len(head))
		}
		if f[0] == "-" {
			continue
		}
		r := map[string]string{}
		for i, h := range head {
			r[h] = f[i]
		}
		out[f[0]] = r
	}
	return out
}

func oracleNum(r map[string]string, col string) (float64, bool) {
	v, ok := r[col]
	if !ok || v == "" {
		return 0, false
	}
	f, err := strconv.ParseFloat(v, 64)
	return f, err == nil
}

// runtimeOf builds a case's runtime input: the oracle row's averages (rt=bc) or the explicit list.
func runtimeOf(t *testing.T, c warnCase, oracle map[string]map[string]string) *MSSQLRuntime {
	t.Helper()
	switch c.rt {
	case "-":
		return nil
	case "bc":
		r, ok := oracle[c.name]
		if !ok {
			t.Fatalf("cases.tsv line %d: rt=bc but the oracle holds no row of %s", c.line, c.name)
		}
		rt := &MSSQLRuntime{}
		for col, p := range map[string]**float64{"ExecutionCount": &rt.Executions, "AverageCPU": &rt.AvgCPUMS,
			"AverageReturnedRows": &rt.AvgRows, "AverageWrites": &rt.AvgWritePages, "AvgSpills": &rt.AvgSpillPages} {
			if v, ok := oracleNum(r, col); ok {
				*p = Num(v)
			}
		}
		return rt
	}
	rt := &MSSQLRuntime{}
	for _, kv := range strings.Split(c.rt, ",") {
		k, v, _ := strings.Cut(kv, ":")
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			t.Fatalf("cases.tsv line %d: rt %q", c.line, kv)
		}
		switch k {
		case "exec":
			rt.Executions = Num(f)
		case "cpu":
			rt.AvgCPUMS = Num(f)
		case "rows":
			rt.AvgRows = Num(f)
		case "writes":
			rt.AvgWritePages = Num(f)
		case "spill":
			rt.AvgSpillPages = Num(f)
		case "compile":
			rt.AvgCompileMS = Num(f)
		default:
			t.Fatalf("cases.tsv line %d: unknown runtime number %q", c.line, k)
		}
	}
	return rt
}

// newestStat is the latest StatisticsInfo LastUpdate in the plan (zero when none).
func newestStat(t *testing.T, plan string) time.Time {
	t.Helper()
	root, err := parseShowplan(plan)
	if err != nil {
		t.Fatal(err)
	}
	var last time.Time
	root.walk(func(n *xnode) bool { // the whole document: all() stops at each statement
		if n.name == "StatisticsInfo" {
			if ts, ok := statTime(n.attr("LastUpdate")); ok && ts.After(last) {
				last = ts
			}
		}
		return true
	})
	return last
}

func readPlan(t *testing.T, name, src string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(warnDir, "captured", name+"."+src+".sqlplan"))
	if err != nil {
		t.Fatalf("no captured %s plan of %s: %v", src, name, err)
	}
	return string(b)
}

// codesOf is the set of codes raised (the missing-index hints as 'missing_index_hint').
func codesOf(warns []MSSQLWarning, plan string) []string {
	var out []string
	for _, w := range warns {
		if !slices.Contains(out, w.Code) {
			out = append(out, w.Code)
		}
	}
	if len(MSSQLMissingIndexes(plan)) > 0 {
		out = append(out, "missing_index_hint")
	}
	return out
}

// part1 are the codes of D401 (rules part 1); builtParts says which parts the tests hold the rules to (part 2's
// codes are checked once D402 builds them).
var part1 = []string{"implicit_conversions", "blitz_implicit_conversion", "is_key_lookup_expensive", "lookup",
	"missing_index_count", "missing_index_hint", "function_count", "blitz_scalar_udf", "clr_function_count",
	"is_computed_filter", "is_computed_scalar", "is_mstvf", "tvf_join", "is_table_variable", "is_cursor",
	"cursor_not_forward_only", "is_cursor_dynamic", "near_parallel", "is_forced_serial", "is_spool_expensive",
	"is_spool_more_rows", "is_table_spool_expensive", "is_table_spool_more_rows", "is_sort_expensive",
	"is_remote_query_expensive", "is_big_spills"}

const builtParts = 1

func checked(code string) bool {
	return builtParts >= 2 || slices.Contains(part1, code)
}

func TestMSSQLPlanWarnings(t *testing.T) {
	oracle := readOracle(t)
	for _, c := range readWarnCases(t) {
		t.Run(c.name+"/"+strconv.Itoa(c.line), func(t *testing.T) {
			plan := readPlan(t, c.name, c.src)
			in := MSSQLWarnInput{CostThreshold: c.ctp, Runtime: runtimeOf(t, c, oracle)}
			if c.nowSet {
				last := newestStat(t, plan)
				if last.IsZero() {
					t.Fatalf("now=+%dd but the plan holds no statistics date", c.nowDays)
				}
				in.Now = last.Add(time.Duration(c.nowDays) * 24 * time.Hour)
			}
			warns, nj, err := MSSQLPlanWarnings(plan, in)
			if err != nil {
				t.Fatal(err)
			}
			got := codesOf(warns, plan)
			var njCodes []string
			for _, j := range nj {
				njCodes = append(njCodes, j.Code)
			}
			for _, code := range c.raise {
				if checked(code) && !slices.Contains(got, code) {
					t.Errorf("%s not raised (%s; %s); raised %v", code, c.rows, c.note, got)
				}
			}
			for _, code := range c.not {
				if checked(code) && slices.Contains(got, code) {
					t.Errorf("%s raised but must not be (%s; %s)", code, c.rows, c.note)
				}
			}
			for _, code := range c.nj {
				if checked(code) && !slices.Contains(njCodes, code) {
					t.Errorf("%s not in the not-judged list %v (%s)", code, njCodes, c.note)
				}
			}
		})
	}
}

// oracleCols maps a code to the sp_BlitzCache 8.34 column that holds the same judgement, and how that column fires.
var oracleCols = map[string]struct {
	col  string
	fire func(string) bool
}{}

func oneFires(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f == 1 }
func posFires(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f > 0 }

func init() {
	for _, c := range []string{"implicit_conversions", "is_key_lookup_expensive", "is_computed_filter", "is_computed_scalar",
		"is_mstvf", "tvf_join", "is_table_variable", "is_cursor", "is_cursor_dynamic", "near_parallel", "is_forced_serial",
		"is_spool_expensive", "is_spool_more_rows", "is_table_spool_expensive", "is_table_spool_more_rows", "is_sort_expensive",
		"is_remote_query_expensive", "is_big_spills", "is_row_goal", "is_bad_estimate", "is_adaptive", "is_paul_white_electric",
		"backwards_scan", "is_table_scan", "forced_index", "columnstore_row_mode", "index_dml", "table_dml",
		"low_cost_high_cpu", "stale_stats", "compile_timeout", "is_nonsargable", "unparameterized_query", "plan_warnings",
		"relop_warnings", "busy_loops"} {
		oracleCols[c] = struct {
			col  string
			fire func(string) bool
		}{c, oneFires}
	}
	for _, c := range []string{"missing_index_count", "function_count", "clr_function_count", "select_with_writes"} {
		oracleCols[c] = struct {
			col  string
			fire func(string) bool
		}{c, posFires}
	}
	oracleCols["index_ops"] = struct {
		col  string
		fire func(string) bool
	}{"index_ops", func(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f >= 5 }}
	oracleCols["trace_flags_session"] = struct {
		col  string
		fire func(string) bool
	}{"trace_flags_session", func(v string) bool { return strings.TrimSpace(v) != "" }}
	oracleCols["long_compile"] = struct {
		col  string
		fire func(string) bool
	}{"CompileTime", func(v string) bool { f, err := strconv.ParseFloat(v, 64); return err == nil && f > 5000 }}
	oracleCols["cursor_not_forward_only"] = struct {
		col  string
		fire func(string) bool
	}{"is_forward_only_cursor", func(v string) bool { return v == "0" || strings.HasPrefix(v, "0.") }}
}

// oracleSkip are the codes compared with sp_BlitzCache on no case, each with why (the design's named exceptions).
var oracleSkip = map[string]string{
	"stale_stats":             "sp_BlitzCache compares SYSDATETIME() and a fresh container holds no 7-day-old statistic; pgvigil is given its clock",
	"cursor_not_forward_only": "sp_BlitzCache never sets is_forward_only_cursor to 0 (8.34 L3632, L2797): its words cannot fire",
	"is_cursor":               "sp_BlitzCache's Cursor rests on plan attributes and zero hashes (8.34 L4980-4995), not the plan",
	"busy_loops":              "sp_BlitzCache keeps one arbitrary operator's CASE per statement (8.34 L3461-3470), NULL for most; pgvigil fires on any",
}

func TestMSSQLPlanWarningsBlitzCache(t *testing.T) {
	oracle := readOracle(t)
	ctp := 5
	for name, r := range oracle {
		path := filepath.Join(warnDir, "captured", name+".cache.sqlplan")
		if _, err := os.Stat(path); err != nil {
			continue
		}
		t.Run(name, func(t *testing.T) {
			plan := readPlan(t, name, "cache")
			c := warnCase{name: name, rt: "bc"}
			warns, _, err := MSSQLPlanWarnings(plan, MSSQLWarnInput{CostThreshold: ctp, Runtime: runtimeOf(t, c, oracle)})
			if err != nil {
				t.Fatal(err)
			}
			got := codesOf(warns, plan)
			for code, oc := range oracleCols {
				if _, skip := oracleSkip[code]; skip || !checked(code) {
					continue
				}
				want := oc.fire(r[oc.col])
				if have := slices.Contains(got, code); have != want {
					t.Errorf("%s: pgvigil %v, sp_BlitzCache 8.34 %v (%s = %q)", code, have, want, oc.col, r[oc.col])
				}
			}
		})
	}
}
