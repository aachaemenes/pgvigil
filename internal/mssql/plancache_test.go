package mssql

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The helpers of the plan cache, index and statistics collections that no SQL Server at hand exercises on demand:
// the optional columns of an older server, the query key, the text picker's memory, the column lists, the rotation
// of the per-database pass and the joining of the two health reads.

func TestPlanCacheQuery(t *testing.T) {
	old := planCacheQuery(map[string]bool{})
	if strings.Contains(old, "qs.total_spills") || strings.Contains(old, "qs.max_grant_kb") {
		t.Error("a column the server does not have is still read")
	}
	if strings.Contains(old, "{{") {
		t.Error("a token was left unfilled")
	}
	all := planCacheQuery(map[string]bool{"max_grant_kb": true, "max_used_grant_kb": true, "total_spills": true, "max_dop": true})
	for _, want := range []string{"ISNULL(qs.max_grant_kb, 0)", "ISNULL(qs.total_spills, 0)", "ISNULL(qs.max_dop, 0)", "<> 32767"} {
		if !strings.Contains(all, want) {
			t.Errorf("the statement lacks %q", want)
		}
	}
}

func TestPlanCacheKey(t *testing.T) {
	if k := planCacheKey(collect.Row{"query_hash_hex": "0xABCDEF0123456789"}); k != "0xABCDEF0123456789" {
		t.Errorf("a hash: %s", k)
	}
	k := planCacheKey(collect.Row{"query_hash_hex": "0x0000000000000000", "sql_handle": "0x0200AB", "stmt_start": int64(44)})
	if k != "0x0200AB:44" {
		t.Errorf("no hash: %s, want handle:offset", k)
	}
}

func TestPlanCacheTexts(t *testing.T) {
	p := &planCacheTexts{sent: map[string]time.Time{}}
	rows := []collect.Row{
		{"query_key": "0x01", "sql_handle": "0x0200AA", "stmt_start": int64(0), "stmt_end": int64(-1)},
		{"query_key": "0x01", "sql_handle": "0x0200BB", "stmt_start": int64(0), "stmt_end": int64(-1)}, // the same key again
		{"query_key": "0x02", "sql_handle": "not hex; DROP", "stmt_start": int64(0), "stmt_end": int64(-1)},
		{"query_key": "0x03", "sql_handle": "0x0200CC", "stmt_start": int64(10), "stmt_end": int64(90)},
	}
	now := time.Now()
	got := p.pick("s1", rows, now, 10)
	if len(got) != 2 || got[0]["query_key"] != "0x01" || got[1]["query_key"] != "0x03" {
		t.Fatalf("first pick: %v", got)
	}
	if v := planCacheTextValues(got); v != "(0x0200AA, 0, -1), (0x0200CC, 10, 90)" {
		t.Errorf("values: %s", v)
	}
	if again := p.pick("s1", rows, now.Add(time.Minute), 10); len(again) != 0 {
		t.Errorf("a text sent a minute ago is sent again: %v", again)
	}
	if other := p.pick("s2", rows, now, 10); len(other) != 2 {
		t.Errorf("another server shares the memory: %v", other)
	}
	p.unpick("s1", got[:1])
	if back := p.pick("s1", rows, now.Add(time.Minute), 10); len(back) != 1 || back[0]["query_key"] != "0x01" {
		t.Errorf("an unpicked text is not asked for again: %v", back)
	}
	if late := p.pick("s1", rows, now.Add(planCacheTextEvery+time.Minute), 1); len(late) != 1 {
		t.Errorf("after %s the text is due again, one at most: %v", planCacheTextEvery, late)
	}
	texts := planCacheTextRows(got, []collect.Row{{"sql_handle": "0x0200CC", "stmt_start": int64(10), "stmt_end": int64(90), "query": "SELECT 1", "object_name": nil}})
	if len(texts) != 1 || texts[0]["query_key"] != "0x03" || texts[0]["kind"] != "text" {
		t.Errorf("text rows: %v", texts)
	}
}

func TestIndexColumns(t *testing.T) {
	got, err := indexColumns(`[{"n":"a"},{"n":"we]ird","d":1}]`)
	if err != nil || strings.Join(got, ",") != "[a],[we]]ird] DESC" {
		t.Errorf("columns: %v %v", got, err)
	}
	if got, err := indexColumns(nil); err != nil || len(got) != 0 {
		t.Errorf("no array: %v %v", got, err)
	}
	if _, err := indexColumns("not json"); err == nil {
		t.Error("bad JSON read as columns")
	}
	rows, bad := indexRows(userDB{id: 5, name: "app"}, []collect.Row{{"keys_json": `[{"n":"id"}]`, "includes_json": nil}, {"keys_json": "x"}})
	if bad != 1 || len(rows) != 1 || rows[0]["database_name"] != "app" || rows[0]["keys_json"] != nil {
		t.Errorf("index rows: %v bad %d", rows, bad)
	}
}

func TestOldestFirst(t *testing.T) {
	dbs := []userDB{{id: 5, name: "a"}, {id: 6, name: "b"}, {id: 7, name: "c"}, {id: 8, name: "d"}}
	now := time.Now()
	read := map[string]time.Time{"ix:a": now, "ix:c": now.Add(-time.Hour)} // b and d never read
	asked := 0
	got, err := oldestFirst(context.Background(), dbs, "ix:", func(_ context.Context, src string) (Cursor, error) {
		asked++
		at, ok := read[src]
		return Cursor{Found: ok, LastEventAt: at}, nil
	})
	if err != nil || asked != 4 {
		t.Fatalf("err %v, %d cursors read", err, asked)
	}
	var ids []int64
	for _, d := range got {
		ids = append(ids, d.id)
	}
	if fmt.Sprint(ids) != "[6 8 7 5]" {
		t.Errorf("order %v, want never read (by id), then the oldest read: [6 8 7 5]", ids)
	}
	if same, _ := oldestFirst(context.Background(), dbs, "ix:", nil); len(same) != 4 || same[0].id != 5 {
		t.Errorf("no cursor: the server's order is kept: %v", same)
	}
	if _, err := oldestFirst(context.Background(), dbs, "ix:", func(context.Context, string) (Cursor, error) { return Cursor{}, errors.New("down") }); err == nil {
		t.Error("a repository that does not answer is not an error")
	}
}

func TestPlanCacheHealthRows(t *testing.T) {
	plans := []collect.Row{{"database_id": int64(6), "database_name": "b", "plans": int64(10), "single_use": int64(4)}}
	stmts := []collect.Row{{"database_id": int64(5), "database_name": "a", "statements": int64(3)}, {"database_id": int64(6), "statements": int64(12)}}
	got := planCacheHealthRows(plans, stmts)
	if len(got) != 2 || got[0]["database_id"] != int64(5) || got[0]["plans"] != int64(0) || got[1]["single_use"] != int64(4) || got[1]["statements"] != int64(12) {
		t.Errorf("health rows: %v", got)
	}
}

func TestStatsQuery(t *testing.T) {
	if q := statsQuery(statsRowsSQL, map[string]bool{}); !strings.Contains(q, "CAST(NULL AS float) AS persisted_pct") || strings.Contains(q, "{{") {
		t.Error("an older server's statement reads persisted_sample_percent")
	}
	if q := statsQuery(statsRowsSQL, map[string]bool{"persisted_sample_percent": true}); !strings.Contains(q, "sp.persisted_sample_percent AS persisted_pct") {
		t.Error("a current server's statement leaves out persisted_sample_percent")
	}
}

// TestNoReservedAlias: an alias that is a T-SQL reserved word breaks the whole batch on the server (run 3 of the
// proof: 'AS statistics' in the statistics summary, error 156). Every statement of the three collections is
// scanned for 'AS <word>' with a word of SQL Server's reserved list that a column name could take.
func TestNoReservedAlias(t *testing.T) {
	reserved := []string{"statistics", "index", "key", "file", "plan", "percent", "rowcount", "user", "current", "table", "schema",
		"open", "procedure", "function", "trigger", "view", "database", "default", "identity", "rule", "close", "check", "primary", "foreign",
		"public", "references", "restore", "backup", "column", "order", "group", "values", "top", "with", "option", "read", "write"}
	stmts := map[string]string{
		"planCache":     planCacheQuery(map[string]bool{"max_grant_kb": true, "max_used_grant_kb": true, "total_spills": true, "max_dop": true}),
		"planCacheText": planCacheTextQuery("(0x01, 0, -1)", true), "planCacheDatabases": planCacheDatabasesSQL,
		"plans": planCachePlansSQL, "statements": planCacheStatementsSQL, "singleUse": planCacheSingleUseSQL, "duplicates": planCacheDuplicatesSQL,
		"userDatabases": userDatabasesQuery(true, true), "indexes": indexesSQL, "missing": missingIndexSQL,
		"statsSummary": statsQuery(statsSummarySQL, map[string]bool{"persisted_sample_percent": true}),
		"statsRows":    statsQuery(statsRowsSQL, map[string]bool{"persisted_sample_percent": true}),
	}
	for name, q := range stmts {
		low := strings.ToLower(q)
		for _, w := range reserved {
			for _, sep := range []string{",", "\n", " ", ")"} {
				if strings.Contains(low, " as "+w+sep) {
					t.Errorf("%s: alias %q is a reserved word (bracket it)", name, w)
				}
			}
		}
	}
}
