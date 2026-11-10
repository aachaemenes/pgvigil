package collect

// Custom checks (task 61; DBADash's custom collections): the DBA's own SQL, listed under custom: in the configuration,
// run by the collector on the instances or tag folders each check names, at each check's own cadence, as the
// instance's monitoring login (pg_monitor) in the collector's read-only session under its statement and lock timeouts.
// A check is either a value check (one number, from its value column, judged against its warning and critical
// thresholds with its comparison) or a row-count check (the rows it returns, judged the same way). Every run's value,
// its rows (at most customMaxRows, each cell masked and capped) or its error go to the repository (migration 0060:
// custom_checks, custom_results, custom_findings).
//
// Each check runs inside its own READ ONLY transaction that is always rolled back: a statement that writes fails
// there ("cannot execute ... in a read-only transaction") and is recorded as the check's error, never retried; a SET
// the check runs (even default_transaction_read_only) is undone by the rollback before the next check; the extended
// protocol takes one statement only, so "SELECT 1; DELETE ..." is refused by the server as well.
//
// The configuration: custom: is read from the same file as the rest (LoadCustomChecks; config.Load ignores the key):
//
//	custom:
//	  - name: idle_in_transaction          # lower-case letters, digits, '_', '.', '-' (1..63); unique
//	    sql: SELECT count(*) AS value FROM pg_stat_activity WHERE state = 'idle in transaction'
//	    every: 5m                          # cadence: at least 1m, at most 24h (default 5m)
//	    instances: [erp01]                 # configured instance names; and / or
//	    tags: [env:prod]                   # tags (the instance's configured tags); neither = every instance
//	    rule: value                        # value (default) | rows (the row count is the value)
//	    value: value                       # the value column (default: a column named value, else the first)
//	    compare: ">"                       # > (default) >= < <= = !=
//	    warning: 5
//	    critical: 20
//	    description: sessions idle inside a transaction
//
// An emptied list is written custom: [] so the next run marks the instances' checks gone (no custom: key at all and
// the collection is off: the stored checks stay as they were until the purge).

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"net/netip"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"gopkg.in/yaml.v3"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

const (
	customDefaultEvery = 5 * time.Minute
	customMinEvery     = time.Minute
	customMaxEvery     = 24 * time.Hour
	customMaxRows      = 100  // rows kept per run
	customMaxCols      = 50   // columns kept per run
	customMaxCell      = 1000 // characters kept per cell
	customMaxError     = 2000 // characters kept of an error
	customMaxSQL       = 20000
	// customSlack lets a check run on the scheduler's tick that comes a little before its cadence is up
	customSlack = 10 * time.Second
)

// CustomCheck is one entry of the custom: list.
type CustomCheck struct {
	Name        string          `yaml:"name"`
	Description string          `yaml:"description"`
	SQL         string          `yaml:"sql"`
	Every       config.Duration `yaml:"every"`
	Instances   []string        `yaml:"instances"`
	Tags        []string        `yaml:"tags"`
	Rule        string          `yaml:"rule"`
	Value       string          `yaml:"value"`
	Compare     string          `yaml:"compare"`
	Warning     *float64        `yaml:"warning"`
	Critical    *float64        `yaml:"critical"`
}

// Cadence returns the check's interval (the default when unset).
func (c CustomCheck) Cadence() time.Duration {
	if c.Every.Duration <= 0 {
		return customDefaultEvery
	}
	return c.Every.Duration
}

// Targets is the check's instances and tags as one line ("every instance" when it names none).
func (c CustomCheck) Targets() string {
	var parts []string
	if len(c.Instances) > 0 {
		parts = append(parts, "instances: "+strings.Join(c.Instances, ", "))
	}
	if len(c.Tags) > 0 {
		parts = append(parts, "tags: "+strings.Join(c.Tags, ", "))
	}
	if len(parts) == 0 {
		return "every instance"
	}
	return strings.Join(parts, "; ")
}

// AppliesTo says whether the check runs on the instance: no instances and no tags = every instance; else the
// instance is named, or carries one of the tags (key and value, as config.ParseTag reads both).
func (c CustomCheck) AppliesTo(in config.Instance) bool {
	if len(c.Instances) == 0 && len(c.Tags) == 0 {
		return true
	}
	for _, n := range c.Instances {
		if n == in.Name {
			return true
		}
	}
	have := in.TagPairs()
	for _, s := range c.Tags {
		want, err := config.ParseTag(s)
		if err != nil {
			continue
		}
		for _, t := range have {
			if t.Key == want.Key && t.Value == want.Value {
				return true
			}
		}
	}
	return false
}

var customNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,62}$`)

// validate checks one entry and fills its defaults; known = the configured instance names.
func (c *CustomCheck) validate(i int, known map[string]bool) error {
	c.Name = strings.TrimSpace(c.Name)
	if !customNameRE.MatchString(c.Name) {
		return fmt.Errorf("custom[%d]: name %q must be lower-case letters, digits, '_', '.' or '-' (1..63, starting with a letter or digit)", i, c.Name)
	}
	c.SQL = strings.TrimSpace(c.SQL)
	c.SQL = strings.TrimSpace(strings.TrimSuffix(c.SQL, ";"))
	if c.SQL == "" {
		return fmt.Errorf("custom %q: sql is required", c.Name)
	}
	if len(c.SQL) > customMaxSQL {
		return fmt.Errorf("custom %q: sql is longer than %d characters", c.Name, customMaxSQL)
	}
	if d := c.Every.Duration; d != 0 && (d < customMinEvery || d > customMaxEvery) {
		return fmt.Errorf("custom %q: every must be between 1m and 24h (got %s)", c.Name, d)
	}
	c.Rule = strings.ToLower(strings.TrimSpace(c.Rule))
	switch c.Rule {
	case "":
		c.Rule = "value"
	case "value", "rows":
	default:
		return fmt.Errorf("custom %q: rule must be value or rows (got %q)", c.Name, c.Rule)
	}
	c.Value = strings.TrimSpace(c.Value)
	if c.Rule == "rows" && c.Value != "" {
		return fmt.Errorf("custom %q: value names a column, which a rows rule does not read", c.Name)
	}
	c.Compare = strings.TrimSpace(c.Compare)
	switch c.Compare {
	case "":
		c.Compare = ">"
	case ">", ">=", "<", "<=", "=", "!=":
	case "<>", "==":
		c.Compare = map[string]string{"<>": "!=", "==": "="}[c.Compare]
	default:
		return fmt.Errorf("custom %q: compare must be one of > >= < <= = != (got %q)", c.Name, c.Compare)
	}
	for _, f := range []*float64{c.Warning, c.Critical} {
		if f != nil && (math.IsNaN(*f) || math.IsInf(*f, 0)) {
			return fmt.Errorf("custom %q: a threshold must be a finite number", c.Name)
		}
	}
	if c.Warning != nil && c.Critical != nil && c.Compare != "=" && c.Compare != "!=" {
		w, k := *c.Warning, *c.Critical
		if (c.Compare[0] == '>' && k < w) || (c.Compare[0] == '<' && k > w) {
			return fmt.Errorf("custom %q: critical %v is reached before warning %v with compare %s", c.Name, k, w, c.Compare)
		}
	}
	for _, n := range c.Instances {
		if !known[n] {
			return fmt.Errorf("custom %q: instance %q is not in the instances: list", c.Name, n)
		}
	}
	for _, s := range c.Tags {
		if _, err := config.ParseTag(s); err != nil {
			return fmt.Errorf("custom %q: %w", c.Name, err)
		}
	}
	if len(c.Description) > 500 {
		return fmt.Errorf("custom %q: description is longer than 500 characters", c.Name)
	}
	return nil
}

// customState is the configured list, set once at start by LoadCustomChecks.
var customState struct {
	sync.RWMutex
	configured bool // the file has a custom: key (an empty list included)
	checks     []CustomCheck
}

// ParseCustomChecks reads the custom: key of a configuration file's bytes and validates it against the configured
// instances; present = the key is in the file (custom: [] included).
func ParseCustomChecks(b []byte, instances []config.Instance) (checks []CustomCheck, present bool, err error) {
	var f struct {
		Custom *[]CustomCheck `yaml:"custom"`
	}
	if err := yaml.Unmarshal(b, &f); err != nil {
		return nil, false, fmt.Errorf("custom: %w", err)
	}
	if f.Custom == nil {
		return nil, false, nil
	}
	known := map[string]bool{}
	for _, in := range instances {
		known[in.Name] = true
	}
	seen := map[string]bool{}
	out := *f.Custom
	for i := range out {
		if err := out[i].validate(i, known); err != nil {
			return nil, true, err
		}
		if seen[out[i].Name] {
			return nil, true, fmt.Errorf("custom %q is listed twice", out[i].Name)
		}
		seen[out[i].Name] = true
	}
	return out, true, nil
}

// LoadCustomChecks reads the custom: list of the configuration file at path (after config.Load) and makes it the
// list the custom collection runs.
func LoadCustomChecks(path string, instances []config.Instance) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("custom: %w", err)
	}
	checks, present, err := ParseCustomChecks(b, instances)
	if err != nil {
		return err
	}
	SetCustomChecks(checks, present)
	return nil
}

// SetCustomChecks replaces the list (tests and LoadCustomChecks).
func SetCustomChecks(checks []CustomCheck, configured bool) {
	customState.Lock()
	defer customState.Unlock()
	customState.checks = append([]CustomCheck(nil), checks...)
	customState.configured = configured
}

// CustomChecks returns the configured list and whether the file has a custom: key.
func CustomChecks() ([]CustomCheck, bool) {
	customState.RLock()
	defer customState.RUnlock()
	return append([]CustomCheck(nil), customState.checks...), customState.configured
}

// CustomFor returns the checks that run on the instance, by name.
func CustomFor(in config.Instance) []CustomCheck {
	all, _ := CustomChecks()
	var out []CustomCheck
	for _, c := range all {
		if c.AppliesTo(in) {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

type customCollector struct {
	mu   sync.Mutex
	last map[string]time.Time // instance NUL check -> the start of its last run in this process
}

func init() { Register(&customCollector{last: map[string]time.Time{}}) }

func (*customCollector) Name() string                   { return "custom" }
func (*customCollector) DefaultInterval() time.Duration { return time.Minute }
func (*customCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

// Configured: on while the file has a custom: key. An instance no check names is still visited, so a check taken
// off it (or the list emptied to custom: []) is marked gone at its next run.
func (*customCollector) Configured(config.Instance) (bool, string) {
	if _, ok := CustomChecks(); !ok {
		return false, "no custom: list in the configuration"
	}
	return true, ""
}

func (*customCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, errors.New("custom runs per instance (RunInstance)")
}

// due says whether a check runs at now on the instance, and records the run when it does.
func (cc *customCollector) due(inst string, c CustomCheck, now time.Time) bool {
	cc.mu.Lock()
	defer cc.mu.Unlock()
	k := inst + "\x00" + c.Name
	if t, ok := cc.last[k]; ok && now.Sub(t) < c.Cadence()-customSlack && now.After(t) {
		return false
	}
	cc.last[k] = now
	return true
}

// RunInstance runs the instance's due checks. The payload: one state row (every check that applies to the
// instance, due or not, so the repository marks the others gone), one check row per such check (its definition),
// and one result row per check run now.
func (cc *customCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	checks := CustomFor(in)
	names := make([]string, 0, len(checks))
	for _, c := range checks {
		names = append(names, c.Name)
	}
	rows := []Row{{"kind": "state", "checks": names}}
	now := time.Now()
	for _, c := range checks {
		rows = append(rows, Row{
			"kind": "check", "check_name": c.Name, "description": nilIfEmpty(c.Description), "sql": c.SQL,
			"every_secs": int(c.Cadence() / time.Second), "rule": c.Rule, "value_column": nilIfEmpty(c.Value),
			"compare": c.Compare, "warning": c.Warning, "critical": c.Critical, "targets": c.Targets(),
		})
	}
	for _, c := range checks {
		if !cc.due(in.Name, c, now) {
			continue
		}
		res := runCustom(ctx, conn, c, in.QueryText)
		rows = append(rows, res.row(c.Name))
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return rows, nil
}

// customResult is one run of one check.
type customResult struct {
	Status   string // ok | warning | critical | error
	Value    *float64
	RowCount int
	Columns  []string
	Cells    [][]any // nil when the rows are not kept
	Kept     bool
	Note     string
	Err      string
	Took     time.Duration
}

func (r customResult) row(name string) Row {
	out := Row{
		"kind": "result", "check_name": name, "status": r.Status, "row_count": r.RowCount,
		"columns": r.Columns, "rows_kept": r.Kept, "note": nilIfEmpty(r.Note), "error": nilIfEmpty(r.Err),
		"duration_ms": r.Took.Milliseconds(),
	}
	if r.Value != nil {
		out["value"] = *r.Value
	}
	if r.Kept {
		out["rows"] = r.Cells
	}
	return out
}

// runCustom runs one check in its own read-only transaction, always rolled back.
func runCustom(ctx context.Context, conn *pgx.Conn, c CustomCheck, queryText string) (res customResult) {
	start := time.Now()
	defer func() { res.Took = time.Since(start) }()
	fail := func(err error) customResult {
		return customResult{Status: "error", Err: capText(maskText(err.Error()), customMaxError)}
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return fail(err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	// QueryExecModeDescribeExec: the unnamed prepared statement (nothing left in the connection's cache) and the
	// extended protocol's one statement
	rs, err := tx.Query(ctx, c.SQL, pgx.QueryExecModeDescribeExec)
	if err != nil {
		return fail(err)
	}
	defer rs.Close()
	fds := rs.FieldDescriptions()
	cols := make([]string, 0, len(fds))
	for i, f := range fds {
		if i >= customMaxCols {
			break
		}
		cols = append(cols, f.Name)
	}
	vi := -1
	if c.Rule == "value" {
		vi = valueIndex(fds, c.Value)
		if vi < 0 && len(fds) > 0 {
			rs.Close()
			return fail(fmt.Errorf("the value column %q is not among the columns the check returns (%s)", c.Value, strings.Join(cols, ", ")))
		}
	}
	keep := queryText == "" || queryText == "full"
	var cells [][]any
	var value *float64
	n := 0
	for rs.Next() {
		vals, err := rs.Values()
		if err != nil {
			rs.Close()
			return fail(err)
		}
		if n == 0 && vi >= 0 {
			v, ok, err := numberOf(vals[vi])
			if err != nil {
				rs.Close()
				return fail(fmt.Errorf("the value column %q: %w", fds[vi].Name, err))
			}
			if ok {
				value = &v
			}
		}
		if keep && n < customMaxRows {
			row := make([]any, 0, len(cols))
			for i := range cols {
				row = append(row, cellOf(vals[i]))
			}
			cells = append(cells, row)
		}
		n++
	}
	if err := rs.Err(); err != nil {
		return fail(err)
	}
	if len(fds) == 0 {
		return fail(errors.New("the statement returns no columns: a check is a SELECT (or a statement with RETURNING rows)"))
	}
	res = customResult{RowCount: n, Columns: cols, Kept: keep, Cells: cells}
	if keep && cells == nil {
		res.Cells = [][]any{}
	}
	switch {
	case !keep:
		res.Note = "rows not kept: query_text is " + queryText
	case n > customMaxRows:
		res.Note = fmt.Sprintf("the first %d of %d rows kept", customMaxRows, n)
	}
	if c.Rule == "rows" {
		v := float64(n)
		value = &v
	} else if value == nil {
		if res.Note != "" {
			res.Note += "; "
		}
		if n == 0 {
			res.Note += "no row: nothing to judge"
		} else {
			res.Note += "the value is NULL: nothing to judge"
		}
	}
	res.Value = value
	res.Status = judge(value, c.Compare, c.Warning, c.Critical)
	return res
}

// valueIndex finds the value column: the named one, else a column named value, else the first; -1 = the named
// one is absent.
func valueIndex(fds []pgconn.FieldDescription, name string) int {
	if name != "" {
		for i, f := range fds {
			if f.Name == name {
				return i
			}
		}
		return -1
	}
	for i, f := range fds {
		if f.Name == "value" {
			return i
		}
	}
	if len(fds) > 0 {
		return 0
	}
	return -1
}

// judge applies the thresholds: critical first, then warning; no value or no threshold reached = ok.
func judge(v *float64, cmp string, warn, crit *float64) string {
	if v == nil {
		return "ok"
	}
	hit := func(t *float64) bool {
		if t == nil {
			return false
		}
		switch cmp {
		case ">=":
			return *v >= *t
		case "<":
			return *v < *t
		case "<=":
			return *v <= *t
		case "=":
			return *v == *t
		case "!=":
			return *v != *t
		default:
			return *v > *t
		}
	}
	switch {
	case hit(crit):
		return "critical"
	case hit(warn):
		return "warning"
	}
	return "ok"
}

// numberOf reads a value cell as a number; ok false = NULL.
func numberOf(v any) (f float64, ok bool, err error) {
	switch x := v.(type) {
	case nil:
		return 0, false, nil
	case int16:
		return float64(x), true, nil
	case int32:
		return float64(x), true, nil
	case int64:
		return float64(x), true, nil
	case int:
		return float64(x), true, nil
	case uint32:
		return float64(x), true, nil
	case uint64:
		return float64(x), true, nil
	case float32:
		return float64(x), true, nil
	case float64:
		return x, true, nil
	case bool:
		if x {
			return 1, true, nil
		}
		return 0, true, nil
	case pgtype.Numeric:
		if !x.Valid {
			return 0, false, nil
		}
		if x.NaN || x.InfinityModifier != pgtype.Finite {
			return 0, false, errors.New("the value is NaN or infinite")
		}
		fv, err := x.Float64Value()
		if err != nil {
			return 0, false, err
		}
		return fv.Float64, fv.Valid, nil
	case time.Duration:
		return x.Seconds(), true, nil
	case pgtype.Interval:
		if !x.Valid {
			return 0, false, nil
		}
		// a month as 30 days, a day as 24 hours (the server's own justify rule)
		return float64(x.Microseconds)/1e6 + float64(x.Days)*86400 + float64(x.Months)*30*86400, true, nil
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
			return 0, false, fmt.Errorf("%q is not a number", capText(x, 40))
		}
		return f, true, nil
	}
	return 0, false, fmt.Errorf("a %T is not a number", v)
}

// cellOf turns a result cell into a JSON value: numbers and booleans as they are, everything else as text, masked
// (a password in a connection string or an ALTER ROLE) and capped.
func cellOf(v any) any {
	switch x := v.(type) {
	case nil:
		return nil
	case bool, int16, int32, int64, int, uint32, uint64:
		return x
	case float32:
		if math.IsNaN(float64(x)) || math.IsInf(float64(x), 0) {
			return strconv.FormatFloat(float64(x), 'g', -1, 32)
		}
		return x
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return strconv.FormatFloat(x, 'g', -1, 64)
		}
		return x
	case pgtype.Numeric:
		if !x.Valid {
			return nil
		}
		if f, err := x.Float64Value(); err == nil && f.Valid && !x.NaN && x.InfinityModifier == pgtype.Finite && x.Exp >= -15 && bigFits(x.Int) {
			return f.Float64
		}
		b, err := x.MarshalJSON()
		if err != nil {
			return nil
		}
		return capText(strings.Trim(string(b), `"`), customMaxCell)
	case time.Time:
		return x.UTC().Format(time.RFC3339Nano)
	case []byte:
		return capText(`\x`+hex.EncodeToString(x), customMaxCell)
	case string:
		return capText(maskText(x), customMaxCell)
	case netip.Prefix:
		if x.IsSingleIP() {
			return x.Addr().String()
		}
		return x.String()
	case fmt.Stringer:
		return capText(maskText(x.String()), customMaxCell)
	}
	b, err := json.Marshal(v)
	if err != nil {
		return capText(fmt.Sprint(v), customMaxCell)
	}
	return capText(maskText(string(b)), customMaxCell)
}

// bigFits keeps a numeric whose digits a float64 holds exactly (up to 15 significant digits) as a JSON number.
func bigFits(i *big.Int) bool {
	if i == nil {
		return true
	}
	return len(new(big.Int).Abs(i).String()) <= 15
}

// capText cuts s to n characters (runes).
func capText(s string, n int) string {
	if len(s) <= n {
		return s
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}
