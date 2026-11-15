package web

import (
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
	for name, q := range map[string]string{"sqlCHRuns": sqlCHRuns, "sqlCHCost": sqlCHCost, "sqlCHInstance": sqlCHInstance, "sqlCHCollection": sqlCHCollection, "sqlCHErrors": sqlCHErrors} {
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
	}{{"", []string{"collections", "runs", "cost"}}, {"errors", []string{"collections", "runs", "cost", "errors"}}, {"runs", []string{"collections", "runs", "cost"}}} {
		if got := chPartNames(c.part); !reflect.DeepEqual(got, c.want) {
			t.Errorf("part=%q: parts %v, want %v", c.part, got, c.want)
		}
	}
}
