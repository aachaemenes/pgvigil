package mssql

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The helpers of the widened index read (D404) that the proof's one server does not reach: a LEFT range, a NULL
// boundary, a name with a bracket, a part's row that cannot be read, an index the ixextra part did not list, and the
// columnstore list left NULL where the segments part was not read.

func TestPfRange(t *testing.T) {
	got, err := pfRange(int64(1), `[{"v":"100"},{"v":"200"}]`)
	if err != nil || got != "RANGE RIGHT FOR VALUES (100, 200)" {
		t.Fatalf("right: %v %v", got, err)
	}
	got, err = pfRange(int64(0), `[{"v":"2026-01-01 00:00:00.000"},{}]`)
	if err != nil || got != "RANGE LEFT FOR VALUES (2026-01-01 00:00:00.000, NULL)" {
		t.Fatalf("left with a NULL boundary: %v %v", got, err)
	}
	if got, err := pfRange(int64(1), nil); got != nil || err != nil {
		t.Fatalf("no function: %v %v", got, err)
	}
	if _, err := pfRange(int64(1), "not json"); err == nil {
		t.Fatal("bad json: no error")
	}
}

func TestMergeExtra(t *testing.T) {
	idx := []collect.Row{
		{"object_id": int64(1), "index_id": int64(1), "index_type": "CLUSTERED"},
		{"object_id": int64(1), "index_id": int64(2), "index_type": "NONCLUSTERED"},
		{"object_id": int64(2), "index_id": int64(1), "index_type": "CLUSTERED"},
	}
	extra := []collect.Row{
		{"object_id": int64(1), "index_id": int64(1), "object_type": "U", "data_space_name": "ps_a", "data_space_type": "PARTITION_SCHEME",
			"partition_function": "pf_a", "pf_type": "int", "pf_partitions": int64(3), "pf_on_right": int64(1), "pf_values_json": `[{"v":"100"},{"v":"200"}]`,
			"partition_column": "we]ird", "any_uncompressed": int64(1), "row_lock_wait_count": int64(4)},
		{"object_id": int64(1), "index_id": int64(2), "object_type": "U", "data_space_name": "PRIMARY", "data_space_type": "ROWS_FILEGROUP",
			"filter_json": `[{"n":"b"},{"n":"c"}]`},
	}
	if bad := mergeExtra(idx, extra); bad != 0 {
		t.Fatalf("bad %d", bad)
	}
	if idx[0]["pf_range"] != "RANGE RIGHT FOR VALUES (100, 200)" || idx[0]["partition_column"] != "[we]]ird]" || idx[0]["row_lock_wait_count"] != int64(4) {
		t.Fatalf("index 1: %v", idx[0])
	}
	if _, ok := idx[0]["pf_values_json"]; ok {
		t.Fatal("pf_values_json left on the row")
	}
	if idx[0]["filter_columns"] != nil {
		t.Fatalf("an unfiltered index has filter columns: %v", idx[0]["filter_columns"])
	}
	if !reflect.DeepEqual(idx[1]["filter_columns"], []string{"[b]", "[c]"}) || idx[1]["partition_column"] != nil || idx[1]["pf_range"] != nil {
		t.Fatalf("index 2: %v", idx[1])
	}
	if _, ok := idx[2]["object_type"]; ok {
		t.Fatal("an index the part did not list took its columns")
	}
	half := []collect.Row{{"object_id": int64(1), "index_id": int64(2)}}
	if bad := mergeExtra(half, []collect.Row{{"object_id": int64(1), "index_id": int64(2), "object_type": "U", "filter_json": "x"}}); bad != 1 {
		t.Fatalf("a bad filter list: bad %d", bad)
	}
	if _, ok := half[0]["object_type"]; ok {
		t.Fatal("a row that could not be read was half stored")
	}
}

func TestMergeSegments(t *testing.T) {
	idx := []collect.Row{
		{"object_id": int64(1), "index_id": int64(1), "index_type": "CLUSTERED COLUMNSTORE"},
		{"object_id": int64(2), "index_id": int64(3), "index_type": "NONCLUSTERED COLUMNSTORE"},
		{"object_id": int64(3), "index_id": int64(1), "index_type": "CLUSTERED"},
	}
	mergeSegments(idx, []collect.Row{{"object_id": int64(1), "index_id": int64(1), "column_name": "s"}, {"object_id": int64(1), "index_id": int64(1), "column_name": "a"}})
	if !reflect.DeepEqual(idx[0]["cs_rebuild_columns"], []string{"[a]", "[s]"}) {
		t.Fatalf("columnstore with two: %v", idx[0]["cs_rebuild_columns"])
	}
	if !reflect.DeepEqual(idx[1]["cs_rebuild_columns"], []string{}) {
		t.Fatalf("columnstore with none: %#v", idx[1]["cs_rebuild_columns"])
	}
	if _, ok := idx[2]["cs_rebuild_columns"]; ok {
		t.Fatal("a rowstore index took a columnstore list")
	}
}

func TestPartRows(t *testing.T) {
	db := userDB{id: 7, name: "app"}
	fks, bad := partRows(db, "fks", []collect.Row{{"kind": "fk", "object_id": int64(9), "cols_json": `[{"n":"y"},{"n":"x"}]`}, {"kind": "fk", "cols_json": "x"}})
	if bad != 1 || len(fks) != 1 || !reflect.DeepEqual(fks[0]["columns"], []string{"[y]", "[x]"}) || fks[0]["database_name"] != "app" || fks[0]["database_id"] != int64(7) {
		t.Fatalf("fks: %v bad %d", fks, bad)
	}
	if _, ok := fks[0]["cols_json"]; ok {
		t.Fatal("cols_json left on the row")
	}
	heaps, bad := partRows(db, "heaps", []collect.Row{{"kind": "heap", "pf_on_right": int64(0), "pf_values_json": `[{"v":"5"}]`, "partition_column": "k"}})
	if bad != 0 || heaps[0]["pf_range"] != "RANGE LEFT FOR VALUES (5)" || heaps[0]["partition_column"] != "[k]" {
		t.Fatalf("heaps: %v", heaps)
	}
}

func TestPartFailures(t *testing.T) {
	f := partFailures{}
	f.add("a", map[string]error{"fks": errors.New("denied")})
	f.add("b", map[string]error{"fks": errors.New("other"), "heaps": errors.New("lock")})
	f.add("c", map[string]error{})
	rows := f.rows()
	if len(rows) != 2 || rows[0]["source"] != "sys.dm_db_partition_stats" || rows[1]["source"] != "sys.foreign_key_columns" {
		t.Fatalf("rows: %v", rows)
	}
	if m, _ := rows[1]["message"].(string); !strings.Contains(m, "the foreign keys of 2 database(s) were not read (a, b): denied") {
		t.Fatalf("fks message: %q", m)
	}
}

func TestIndexPartsSQL(t *testing.T) {
	// every part keeps the index read's set (no memory-optimized table) and runs on SQL Server 2016 SP1: no STRING_AGG,
	// CONCAT_WS or TRIM (2017); min_deep_data only in the segments part, which runs only where the column exists
	for name, q := range map[string]string{"ixextra": ixExtraSQL, "segments": ixSegmentsSQL, "heaps": ixHeapsSQL, "shape": ixShapeSQL, "fks": ixFKSQL} {
		for _, f := range []string{"STRING_AGG", "CONCAT_WS", "TRIM("} {
			if strings.Contains(strings.ReplaceAll(q, "RTRIM(", ""), f) {
				t.Errorf("%s uses %s", name, f)
			}
		}
		if name != "segments" && strings.Contains(q, "min_deep_data") {
			t.Errorf("%s reads min_deep_data", name)
		}
		if name != "segments" && !strings.Contains(q, "is_memory_optimized") {
			t.Errorf("%s does not leave memory-optimized tables out", name)
		}
	}
}
