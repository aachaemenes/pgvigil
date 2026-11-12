package collect

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/aachaemenes/pgvigil/internal/config"
)

func fp(f float64) *float64 { return &f }

func TestParseCustomChecks(t *testing.T) {
	ins := []config.Instance{{Name: "erp01", Tags: []string{"env:prod"}}, {Name: "crm01", Tags: []string{"env:dev", "billing"}}}
	ok := `
repository: {dsn: x}
custom:
  - name: idle_txn
    sql: "SELECT count(*) AS value FROM pg_stat_activity WHERE state = 'idle in transaction';"
    every: 2m
    tags: [env:prod]
    warning: 5
    critical: 20
  - name: hitratio
    sql: SELECT 99.5
    compare: "<"
    warning: 99
    critical: 95
    instances: [crm01]
  - name: prepared
    sql: SELECT gid FROM pg_prepared_xacts
    rule: rows
    critical: 0
`
	checks, present, err := ParseCustomChecks([]byte(ok), ins)
	if err != nil || !present || len(checks) != 3 {
		t.Fatalf("ok config: %v %v %d", err, present, len(checks))
	}
	c := checks[0]
	if c.SQL != "SELECT count(*) AS value FROM pg_stat_activity WHERE state = 'idle in transaction'" || c.Rule != "value" || c.Compare != ">" || c.Cadence() != 2*time.Minute {
		t.Fatalf("defaults and trimming: %+v", c)
	}
	if checks[2].Cadence() != 5*time.Minute || checks[2].Rule != "rows" {
		t.Fatalf("rows check: %+v", checks[2])
	}
	if !checks[0].AppliesTo(ins[0]) || checks[0].AppliesTo(ins[1]) {
		t.Fatal("a tag check runs on the tagged instance only")
	}
	if checks[1].AppliesTo(ins[0]) || !checks[1].AppliesTo(ins[1]) {
		t.Fatal("an instance check runs on the named instance only")
	}
	if !checks[2].AppliesTo(ins[0]) || !checks[2].AppliesTo(ins[1]) || checks[2].Targets() != "every instance" {
		t.Fatal("a check naming nothing runs everywhere")
	}
	plain := CustomCheck{Tags: []string{"billing"}}
	if !plain.AppliesTo(ins[1]) || plain.AppliesTo(ins[0]) {
		t.Fatal("a plain-word tag matches the key tag")
	}

	if _, present, err := ParseCustomChecks([]byte("repository: {dsn: x}\n"), ins); err != nil || present {
		t.Fatalf("no key: %v %v", present, err)
	}
	if cs, present, err := ParseCustomChecks([]byte("custom: []\n"), ins); err != nil || !present || len(cs) != 0 {
		t.Fatalf("an empty list is present: %v %v %d", present, err, len(cs))
	}

	bad := map[string]string{
		"name":       "custom: [{name: Bad Name, sql: SELECT 1}]",
		"no sql":     "custom: [{name: a}]",
		"twice":      "custom: [{name: a, sql: SELECT 1}, {name: a, sql: SELECT 2}]",
		"every":      "custom: [{name: a, sql: SELECT 1, every: 10s}]",
		"every long": "custom: [{name: a, sql: SELECT 1, every: 25h}]",
		"rule":       "custom: [{name: a, sql: SELECT 1, rule: count}]",
		"compare":    "custom: [{name: a, sql: SELECT 1, compare: '=>'}]",
		"order":      "custom: [{name: a, sql: SELECT 1, warning: 10, critical: 5}]",
		"order <":    "custom: [{name: a, sql: SELECT 1, compare: '<', warning: 5, critical: 10}]",
		"tag":        "custom: [{name: a, sql: SELECT 1, tags: ['env:']}]",
		"rows value": "custom: [{name: a, sql: SELECT 1, rule: rows, value: n}]",
	}
	for k, y := range bad {
		if _, _, err := ParseCustomChecks([]byte(y), ins); err == nil {
			t.Errorf("%s: accepted %s", k, y)
		}
	}
	// an instance or a tag the file does not hold is a warning, never an error: the page may hold the instance (204)
	cs, _, warns, err := ParseCustomChecksWarn([]byte("custom: [{name: a, sql: SELECT 1, tags: ['env:prd']}]"), ins)
	if err != nil || len(cs) != 1 || len(warns) != 1 || !strings.Contains(warns[0], "match no instance of the file") {
		t.Errorf("a tag no file instance carries: %v %d %v", err, len(cs), warns)
	}
	cs, _, warns, err = ParseCustomChecksWarn([]byte("custom: [{name: a, sql: SELECT 1, instances: [sql07, erp01]}]"), ins)
	if err != nil || len(cs) != 1 || len(warns) != 1 || !strings.Contains(warns[0], `instance "sql07" is not in the file's instances`) {
		t.Errorf("an instance only the page holds: %v %d %v", err, len(cs), warns)
	}
	// no instance in the file at all (a host whose instances are all in the page): every check loads, with its warning
	cs, _, warns, err = ParseCustomChecksWarn([]byte("custom: [{name: a, sql: SELECT 1}]"), nil)
	if err != nil || len(cs) != 1 || len(warns) != 1 {
		t.Errorf("a check over no file instance: %v %d %v", err, len(cs), warns)
	}
	// a tag one instance carries, beside an unmatched one, is enough
	if _, _, err := ParseCustomChecks([]byte("custom: [{name: a, sql: SELECT 1, tags: ['env:prd', billing]}]"), ins); err != nil {
		t.Errorf("one matching tag: %v", err)
	}
	// <> and == are read as != and =
	cs, _, err := ParseCustomChecks([]byte("custom: [{name: a, sql: SELECT 1, compare: '<>', warning: 1}]"), ins)
	if err != nil || cs[0].Compare != "!=" {
		t.Fatalf("<>: %v %+v", err, cs)
	}
}

func TestJudge(t *testing.T) {
	cases := []struct {
		v          *float64
		cmp        string
		warn, crit *float64
		want       string
	}{
		{fp(3), ">", fp(5), fp(20), "ok"},
		{fp(5), ">", fp(5), fp(20), "ok"},
		{fp(6), ">", fp(5), fp(20), "warning"},
		{fp(21), ">", fp(5), fp(20), "critical"},
		{fp(5), ">=", fp(5), fp(20), "warning"},
		{fp(98), "<", fp(99), fp(95), "warning"},
		{fp(90), "<", fp(99), fp(95), "critical"},
		{fp(95), "<=", fp(99), fp(95), "critical"},
		{fp(1), "=", nil, fp(1), "critical"},
		{fp(2), "!=", fp(1), nil, "warning"},
		{nil, ">", fp(0), fp(0), "ok"},
		{fp(100), ">", nil, nil, "ok"},
	}
	for i, c := range cases {
		if got := judge(c.v, c.cmp, c.warn, c.crit); got != c.want {
			t.Errorf("case %d: %s, want %s", i, got, c.want)
		}
	}
}

func TestNumberAndCell(t *testing.T) {
	for _, v := range []any{int16(2), int32(2), int64(2), float32(2), 2.0, "2", " 2 ", true} {
		f, ok, err := numberOf(v)
		want := 2.0
		if v == true {
			want = 1
		}
		if err != nil || !ok || f != want {
			t.Errorf("numberOf(%T %v) = %v %v %v", v, v, f, ok, err)
		}
	}
	if _, ok, err := numberOf(nil); ok || err != nil {
		t.Error("NULL is no value and no error")
	}
	for _, v := range []any{"abc", "NaN", time.Now(), []byte{1}, math.NaN(), math.Inf(1), float32(math.Inf(-1))} {
		if _, _, err := numberOf(v); err == nil {
			t.Errorf("numberOf(%T) took a non-number", v)
		}
	}
	if s := cellOf("host=db password=hunter2 user=x"); strings.Contains(s.(string), "hunter2") {
		t.Errorf("a password in a cell is kept: %v", s)
	}
	if s := cellOf("ALTER ROLE app PASSWORD 'hunter2'"); strings.Contains(s.(string), "hunter2") {
		t.Errorf("a password in a statement is kept: %v", s)
	}
	if s := cellOf(strings.Repeat("é", 3000)).(string); len([]rune(s)) != customMaxCell {
		t.Errorf("a long cell is cut to %d runes, got %d", customMaxCell, len([]rune(s)))
	}
	if v := cellOf(int64(7)); v != int64(7) {
		t.Errorf("a number stays a number: %v", v)
	}
	u := [16]byte{0x41, 0x09, 0xca, 0xa3, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
	if v := cellOf(u); v != "4109caa3-0001-0203-0405-060708090a0b" {
		t.Errorf("a uuid cell: %v", v)
	}
	for want, iv := range map[string]pgtype.Interval{
		"1 day 02:00:00":           {Days: 1, Microseconds: 7200e6, Valid: true},
		"1 year 2 mons 00:00:01.5": {Months: 14, Microseconds: 1500000, Valid: true},
		"00:00:00":                 {Valid: true},
		"-00:01:05":                {Microseconds: -65e6, Valid: true},
		"3 days":                   {Days: 3, Valid: true},
	} {
		if v := cellOf(iv); v != want {
			t.Errorf("an interval cell: %v, want %s", v, want)
		}
	}
	at := time.Date(2026, 11, 10, 9, 0, 0, 0, time.FixedZone("x", 3600))
	if v := cellOf(at); v != "2026-11-10T08:00:00Z" {
		t.Errorf("a time is UTC RFC 3339: %v", v)
	}
}

func TestCustomDue(t *testing.T) {
	cc := &customCollector{last: map[string]time.Time{}}
	c := CustomCheck{Name: "a", Every: config.Duration{Duration: 5 * time.Minute}}
	t0 := time.Date(2026, 11, 10, 9, 0, 0, 0, time.UTC)
	if !cc.due("i", c, t0) {
		t.Fatal("the first tick runs")
	}
	if cc.due("i", c, t0.Add(time.Minute)) || cc.due("i", c, t0.Add(4*time.Minute)) {
		t.Fatal("a tick inside the cadence does not run")
	}
	if !cc.due("i", c, t0.Add(5*time.Minute-3*time.Second)) {
		t.Fatal("the tick at the cadence (a little early) runs")
	}
	if !cc.due("j", c, t0.Add(time.Minute)) {
		t.Fatal("another instance keeps its own clock")
	}
}

func TestCustomGate(t *testing.T) {
	defer SetCustomChecks(nil, false)
	cc := &customCollector{last: map[string]time.Time{}}
	SetCustomChecks(nil, false)
	if ok, _ := cc.Configured(config.Instance{Name: "x"}); ok {
		t.Fatal("no custom: key = off")
	}
	SetCustomChecks(nil, true)
	if ok, _ := cc.Configured(config.Instance{Name: "x"}); !ok {
		t.Fatal("custom: [] = on (the next run marks the old checks gone)")
	}
}

// TestCustomRunSandbox runs checks on a real server: PGVIGIL_CUSTOM_TEST_DSN (scripts/proof-custom.sh sets it to its
// pg_monitor login); skipped without it.
func TestCustomRunSandbox(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_CUSTOM_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_CUSTOM_TEST_DSN not set")
	}
	ctx := context.Background()
	conn, err := Connect(ctx, config.Instance{Name: "t", DSNRaw: dsn})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	run := func(c CustomCheck, qt string) customResult {
		t.Helper()
		if c.Rule == "" {
			c.Rule = "value"
		}
		if c.Compare == "" {
			c.Compare = ">"
		}
		return runCustom(ctx, conn, c, qt)
	}
	r := run(CustomCheck{Name: "v", SQL: "SELECT 'x' AS label, 7::numeric AS value", Warning: fp(5), Critical: fp(10)}, "full")
	if r.Status != "warning" || r.Value == nil || *r.Value != 7 || r.RowCount != 1 || len(r.Cells) != 1 {
		t.Fatalf("value check: %+v", r)
	}
	r = run(CustomCheck{Name: "r", SQL: "SELECT g FROM generate_series(1, 150) g", Rule: "rows", Critical: fp(100)}, "full")
	if r.Status != "critical" || *r.Value != 150 || len(r.Cells) != customMaxRows || !strings.Contains(r.Note, "100 of 150") {
		t.Fatalf("rows check: %+v", r)
	}
	r = run(CustomCheck{Name: "n", SQL: "SELECT g FROM generate_series(1, 3) g", Rule: "rows"}, "none")
	if r.Status != "ok" || r.Kept || r.Cells != nil || r.RowCount != 3 {
		t.Fatalf("rows under query_text none: %+v", r)
	}
	r = run(CustomCheck{Name: "w", SQL: "CREATE TABLE pgvigil_custom_write_test (a int)"}, "full")
	if r.Status != "error" || !strings.Contains(r.Err, "read-only transaction") {
		t.Fatalf("a write is the check's error: %+v", r)
	}
	r = run(CustomCheck{Name: "m", SQL: "SELECT 1; SELECT 2"}, "full")
	if r.Status != "error" {
		t.Fatalf("two statements are refused: %+v", r)
	}
	// a SET inside the check is rolled back with it: the session stays read only
	r = run(CustomCheck{Name: "s", SQL: "SELECT set_config('default_transaction_read_only', 'off', false) AS value"}, "full")
	if r.Status != "error" {
		t.Logf("set_config as a value: %+v", r) // 'off' is not a number: the check's error either way
	}
	var ro string
	if err := conn.QueryRow(ctx, "SHOW default_transaction_read_only").Scan(&ro); err != nil || ro != "on" {
		t.Fatalf("the session is no longer read only after a check's set_config: %q %v", ro, err)
	}
	r = run(CustomCheck{Name: "e", SQL: "SELECT 1/0 AS value"}, "full")
	if r.Status != "error" || !strings.Contains(r.Err, "division by zero") {
		t.Fatalf("an erroring check: %+v", r)
	}
	r = run(CustomCheck{Name: "c", SQL: "SELECT 1 AS a", Value: "b"}, "full")
	if r.Status != "error" || !strings.Contains(r.Err, `"b"`) {
		t.Fatalf("a missing value column: %+v", r)
	}
	r = run(CustomCheck{Name: "t", SQL: "SELECT 'abc' AS value"}, "full")
	if r.Status != "error" {
		t.Fatalf("a text value: %+v", r)
	}
	r = run(CustomCheck{Name: "z", SQL: "SELECT 1 AS value WHERE false", Critical: fp(0)}, "full")
	if r.Status != "ok" || r.Value != nil || !strings.Contains(r.Note, "no row") {
		t.Fatalf("no row: %+v", r)
	}
	// a non-finite value is the check's error, and the result still marshals (the payload of the whole instance did not)
	for _, sql := range []string{"SELECT 'NaN'::float8 AS value", "SELECT 'Infinity'::float8 AS value", "SELECT '-Infinity'::float4 AS value"} {
		r = run(CustomCheck{Name: "f", SQL: sql}, "full")
		if r.Status != "error" || !strings.Contains(r.Err, "not a finite number") {
			t.Fatalf("%s: %+v", sql, r)
		}
		if _, err := json.Marshal([]Row{r.row("f")}); err != nil {
			t.Fatalf("%s: the result does not marshal: %v", sql, err)
		}
	}
	// NaN in a kept cell (not the value) is text; uuid and interval cells read as PostgreSQL writes them
	r = run(CustomCheck{Name: "k", SQL: "SELECT 1 AS value, 'NaN'::float8 AS f, '4109caa3-0001-0203-0405-060708090a0b'::uuid AS u, interval '1 day 2 hours' AS i"}, "full")
	if r.Status != "ok" || len(r.Cells) != 1 || r.Cells[0][1] != "NaN" || r.Cells[0][2] != "4109caa3-0001-0203-0405-060708090a0b" || r.Cells[0][3] != "1 day 02:00:00" {
		t.Fatalf("cells: %+v", r)
	}
	if _, err := json.Marshal([]Row{r.row("k")}); err != nil {
		t.Fatalf("the cells do not marshal: %v", err)
	}
	if err := customRights(ctx, conn); err != nil {
		t.Fatalf("a pg_monitor login is refused: %v", err)
	}
	if sdsn := os.Getenv("PGVIGIL_CUSTOM_TEST_SUPER_DSN"); sdsn != "" {
		sc, err := Connect(ctx, config.Instance{Name: "s", DSNRaw: sdsn})
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = sc.Close(ctx) }()
		if err := customRights(ctx, sc); err == nil || !strings.Contains(err.Error(), "superuser") {
			t.Fatalf("a superuser login is not refused: %v", err)
		}
	}
	// the connection still works after the failures
	var one int
	if err := conn.QueryRow(ctx, "SELECT 1", pgx.QueryExecModeSimpleProtocol).Scan(&one); err != nil || one != 1 {
		t.Fatalf("the connection after the checks: %v", err)
	}
}
