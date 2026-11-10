package collect

import (
	"fmt"
	"testing"
)

// TestDropCovers: an unused index that covers a redundant or duplicate one is left out; one that covers nothing, and the
// covered index's own unused row, stay (constructed rows in the read's shape).
func TestDropCovers(t *testing.T) {
	rows := []Row{
		{"kind": "db", "dbid": int64(5)},
		{"kind": "index", "problem": "redundant", "indexrelid": int64(10), "covered_by_ids": "11"},
		{"kind": "index", "problem": "duplicate", "indexrelid": int64(20), "covered_by_ids": "21,22"},
		{"kind": "index", "problem": "unused", "indexrelid": int64(11)}, // covers 10: out
		{"kind": "index", "problem": "unused", "indexrelid": int64(22)}, // covers 20: out
		{"kind": "index", "problem": "unused", "indexrelid": int64(20)}, // the duplicate itself: stays
		{"kind": "index", "problem": "unused", "indexrelid": int64(30)}, // covers nothing: stays
		{"kind": "index", "problem": "invalid", "indexrelid": int64(11)},
	}
	got := dropCovers(rows)
	var ids []string
	for _, r := range got {
		if r["problem"] == "unused" {
			ids = append(ids, fmt.Sprint("u", r["indexrelid"]))
		}
	}
	if len(got) != 6 || len(ids) != 2 || ids[0] != "u20" || ids[1] != "u30" {
		t.Fatalf("got %d rows, unused %v; want 6 rows, unused [u20 u30]", len(got), ids)
	}
}
