package mssql

import (
	"fmt"
	"os"
	"testing"
)

func TestParseResource(t *testing.T) {
	cases := []struct {
		desc string
		want waitResource
	}{
		{"keylock hobtid=72057594047365120 dbid=5 id=lock2a8e3a07e80 mode=X associatedObjectId=72057594047365120",
			waitResource{kind: "key", dbid: 5, hobt: 72057594047365120}},
		{"pagelock fileid=1 pageid=264 dbid=7 id=lock1 mode=IX associatedObjectId=72057594043760640",
			waitResource{kind: "page", dbid: 7, file: 1, page: 264, hobt: 72057594043760640}},
		{"ridlock fileid=1 pageid=312 dbid=6 id=lock2 mode=X associatedObjectId=72057594044350464",
			waitResource{kind: "rid", dbid: 6, file: 1, page: 312, hobt: 72057594044350464}},
		{"objectlock lockPartition=0 objid=901578250 subresource=FULL dbid=5 id=lock3 mode=IX associatedObjectId=901578250",
			waitResource{kind: "object", dbid: 5, object: 901578250}},
		{"2:1:3", waitResource{kind: "page latch", dbid: 2, file: 1, page: 3}},
		{" 10:4:118207 ", waitResource{kind: "page latch", dbid: 10, file: 4, page: 118207}},
		{"exchangeEvent id=Pipe1f2c WaitType=e_waitPipeGetRow nodeId=2", waitResource{kind: "exchange"}},
		{"ACCESS_METHODS_DATASET_PARENT", waitResource{kind: "other"}},
		{"", waitResource{kind: ""}},
	}
	for _, c := range cases {
		if got := parseResource(c.desc); got != c.want {
			t.Errorf("parseResource(%q) = %+v, want %+v", c.desc, got, c.want)
		}
	}
}

func TestBracket(t *testing.T) {
	if got := bracket("a]b"); got != "[a]]b]" {
		t.Errorf("bracket = %s", got)
	}
}

// TestPrintBenign prints the benign wait list when PGVIGIL_PRINT_BENIGN is set (proof-darling-waiting.sh applies the
// same list to PerformanceMonitor's read before it compares).
func TestPrintBenign(t *testing.T) {
	if os.Getenv("PGVIGIL_PRINT_BENIGN") == "" {
		t.Skip("PGVIGIL_PRINT_BENIGN not set")
	}
	for w := range benignWaits {
		fmt.Println("benign", w)
	}
}
