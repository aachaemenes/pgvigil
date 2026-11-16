package cq

import (
	"testing"
	"time"
)

// CQ-LIVEMASK's own row: a state without words leaves its key out of the end, so 0200 stores NULL, never an empty
// string - a reader's coalesce(outcome, refusal) then shows a refusal's words.
func TestEndBodyLeavesEmptyWordsOut(t *testing.T) {
	b := endBody(End{State: "done", Rows: 3}, 1500*time.Millisecond, "read")
	for _, k := range []string{"outcome", "refusal", "result"} {
		if v, ok := b[k]; ok {
			t.Fatalf("a done end without %s carries the key (%q): 0200 would store ''", k, v)
		}
	}
	if b["state"] != "done" || b["rows"] != 3 || b["duration_ms"] != int64(1500) || b["keep"] != "read" {
		t.Fatalf("the end's other fields: %v", b)
	}
	b = endBody(End{State: "refused", Refusal: "no right"}, 0, "read")
	if b["refusal"] != "no right" {
		t.Fatalf("a refusal's words: %v", b)
	}
	if _, ok := b["outcome"]; ok {
		t.Fatalf("a refused end without an outcome carries the key: %v", b)
	}
	b = endBody(End{State: "failed", Outcome: "boom", Result: map[string]any{"a": 1}}, 0, "7d")
	if b["outcome"] != "boom" || b["result"] == nil || b["keep"] != "7d" {
		t.Fatalf("a failed end's words and result: %v", b)
	}
	if _, ok := b["refusal"]; ok {
		t.Fatalf("a failed end carries an empty refusal: %v", b)
	}
}
