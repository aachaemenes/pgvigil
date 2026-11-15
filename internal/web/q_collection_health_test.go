package web

import (
	"os"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestCollectionHealthParams: every part of GET /api/collectionhealth references each of its arguments $1..$n and
// none above (PostgreSQL refuses a statement whose parameter it cannot type, an unreferenced one included); the
// collections part has the expected intervals as $7, the others six
func TestCollectionHealthParams(t *testing.T) {
	for name, c := range map[string]struct {
		sql string
		n   int
	}{"instance": {sqlCHInstance, 7}, "collection": {sqlCHCollection, 7}, "runs": {sqlCHRuns, 6}, "cost": {sqlCHCost, 6}, "errors": {sqlCHErrors, 6}} {
		seen := map[int]bool{}
		for _, m := range regexp.MustCompile(`\$([0-9]+)`).FindAllStringSubmatch(c.sql, -1) {
			k, _ := strconv.Atoi(m[1])
			seen[k] = true
		}
		for k := 1; k <= c.n; k++ {
			if !seen[k] {
				t.Errorf("%s: $%d is not referenced", name, k)
			}
		}
		if seen[c.n+1] {
			t.Errorf("%s: $%d referenced, %d arguments passed", name, c.n+1, c.n)
		}
	}
	// Row per collection drops Instance and Status Reason (DBA Dash's CollectionHealth_Get.sql:516), keeps Instances
	last := sqlCHCollection[strings.LastIndex(sqlCHCollection, "SELECT r.collection"):]
	for _, no := range []string{"r.instance,", "status_reason"} {
		if strings.Contains(last, no) {
			t.Errorf("Row per collection selects %s", no)
		}
	}
	for _, yes := range []string{"r.instances", "r.failing_instances", "errors_from", "errors_to"} {
		if !strings.Contains(last, yes) {
			t.Errorf("Row per collection has no %s", yes)
		}
	}
}

func TestCollectionHealthStatuses(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
		err  bool
	}{
		{"", nil, false}, {"critical,na", []string{"critical", "n/a"}, false}, {"ok", []string{"ok"}, false},
		{"critical,warning,na,ok", nil, false}, {"bad", nil, true}, {"n/a", nil, true},
		// a repeated word is one status (the review of B6.2, part a #8): four words are 'all four' only when they differ
		{"ok,ok,ok,ok", []string{"ok"}, false}, {"critical,critical,warning,ok", []string{"critical", "warning", "ok"}, false},
	} {
		got, err := chStatuses(c.in)
		if (err != nil) != c.err || !reflect.DeepEqual(got, c.want) {
			t.Errorf("chStatuses(%q) = %v, %v; want %v, error %v", c.in, got, err, c.want, c.err)
		}
	}
}

// TestCollectionHealthBucket: an hour at least, about 48 buckets over a long range
func TestCollectionHealthBucket(t *testing.T) {
	at := time.Date(2026, 11, 14, 0, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		d    time.Duration
		want int
	}{{time.Hour, 3600}, {24 * time.Hour, 3600}, {7 * 24 * time.Hour, 4 * 3600}, {30 * 24 * time.Hour, 16 * 3600}} {
		if got := chBucket(at, at.Add(c.d)); got != c.want {
			t.Errorf("chBucket(%v) = %d, want %d", c.d, got, c.want)
		}
	}
}

// TestCollectionHealthPG13: the page's statements run on PostgreSQL 13 (README's floor): no date_bin, which 13 does not
// have (0054, 0076 and q_mssql_plancache.go floor the epoch instead) - the review of B6.2, part a #1
func TestCollectionHealthPG13(t *testing.T) {
	for name, q := range map[string]string{"sqlCHRuns": sqlCHRuns, "sqlCHCost": sqlCHCost, "sqlCHInstance": sqlCHInstance, "sqlCHCollection": sqlCHCollection, "sqlCHErrors": sqlCHErrors, "sqlCHThresholds": sqlCHThresholds} {
		if strings.Contains(q, "date_bin") {
			t.Errorf("%s calls date_bin: PostgreSQL 13 has none", name)
		}
	}
}

// TestCollectionHealthErrorsOnAsk: the page's main read (no part=) never runs the error list, which it does not draw;
// part=errors (the Errors link's list) does - the review of B6.2, part a #5
func TestCollectionHealthErrorsOnAsk(t *testing.T) {
	for _, c := range []struct {
		part string
		want []string
	}{{"", []string{"collections", "runs", "cost"}}, {"errors", []string{"collections", "runs", "cost", "errors"}}, {"runs", []string{"collections", "runs", "cost"}},
		{"thresholds", []string{"collections", "runs", "cost", "thresholds"}}} { // B6g-2: the dialog's read, on ask only
		if got := chPartNames(c.part); !reflect.DeepEqual(got, c.want) {
			t.Errorf("part=%q: parts %v, want %v", c.part, got, c.want)
		}
	}
}

// TestCollectionHealthRangeShape (the review of B6.2, part a #6 and #9a, the lead's 00:5x calls): the page reads its hourly
// rows from the hour that holds the range's start (DBA Dash's @FromHour, rounded down) and passes collection_health its
// scope; the rows are ordered as DBA Dash's: Status (critical, warning, N/A, OK), the range's Failed % down, the name
func TestCollectionHealthRangeShape(t *testing.T) {
	if strings.Contains(chHourFrom, "+ interval '1 hour'") {
		t.Errorf("chHourFrom rounds up: %s", chHourFrom)
	}
	if !strings.Contains(sqlCHRows, "CASE WHEN $3::int > 0 THEN ARRAY[$3::int] ELSE $4::int[] END, nullif($5::text, '')) c") {
		t.Errorf("sqlCHRows does not pass collection_health its scope (the instances and the collection)")
	}
	for name, q := range map[string]string{"sqlCHInstance": sqlCHInstance, "sqlCHCollection": sqlCHCollection} {
		if !strings.Contains(q, "WHEN 'n/a' THEN 3 WHEN 'ok' THEN 4") || !strings.Contains(q, "failed_pct DESC NULLS LAST") {
			t.Errorf("%s is not in DBA Dash's order (Status, Failed %% down, name)", name)
		}
	}
}

// Review B6.2 part b #1: Failed counts the hourly rows from the hour holding from to the end of the hour holding to
// (0166: the hours that begin before p_rate_to), so the list the Failed link opens reads that same window - the API
// gives it on every row (rate_from, rate_to; capped at now) and the page's link carries it; Errors keeps [from, to).
func TestCollectionHealthFailedWindowShape(t *testing.T) {
	for name, q := range map[string]string{"sqlCHInstance": sqlCHInstance, "sqlCHCollection": sqlCHCollection} {
		if !strings.Contains(q, chHourFrom+` AS rate_from`) {
			t.Errorf("%s: no rate_from = the hour holding from", name)
		}
		if !strings.Contains(q, `least(`+chHourTo+`, now()) AS rate_to`) {
			t.Errorf("%s: no rate_to = the end of the hour holding to, capped at now", name)
		}
	}
	b, err := os.ReadFile("../../web/src/collection_health.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `errorsLink(r, v, 'failed', { from: String(r.rate_from), to: String(r.rate_to) })`) {
		t.Errorf("collection_health.ts: the Failed link does not open the counted window")
	}
}

// TestCHFoldB6f3Shapes (the review B6f3 #2, #8): the error lists read the active instances only, as 0166's j counts
// Failed (an instance set inactive keeps its errors in collection_log); the per-instance grid breaks a tie by the
// collection, DBA Dash's Name (CollectionHealth_Get.sql L521: Status, FailedPct DESC, Name), then the instance
func TestCHFoldB6f3Shapes(t *testing.T) {
	if !regexp.MustCompile(`JOIN pgvigil\.instances i ON i\.instance_id = l\.instance_id AND i\.is_active`).MatchString(sqlCHErrors) {
		t.Errorf("sqlCHErrors reads inactive instances' errors (no i.is_active on its join)")
	}
	if !regexp.MustCompile(`failed_pct DESC NULLS LAST, r\.collection, r\.instance\s`).MatchString(sqlCHInstance) {
		t.Errorf("sqlCHInstance's tie-break is not the collection, then the instance")
	}
}
