package web

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCollectorBackoffWordsL214 (L214, B2): the Collector page names an instance backing off - the handler computes
// 'backing off: <n> connects failed in a row since <t>; next try about <t>' from the stored (connect) streak with the
// same Go rule the loop uses (collect.BackoffWindow), and collector.ts shows the line.
func TestCollectorBackoffWordsL214(t *testing.T) {
	q, err := os.ReadFile("q_collector.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"collect.BackoffWindow", "backing_off", "backing off: "} {
		if !strings.Contains(string(q), want) {
			t.Errorf("q_collector.go lacks %q: the streak rows carry no backing-off line", want)
		}
	}
	ts, err := os.ReadFile(filepath.Join("..", "..", "web", "src", "collector.ts"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"backing_off"} {
		if !strings.Contains(string(ts), want) {
			t.Errorf("collector.ts lacks %q: the page never shows the backing-off line", want)
		}
	}
}
