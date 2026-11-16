package collect

import "testing"

// TestMaskTree masks the strings of a decoded definition and nothing else.
func TestMaskTree(t *testing.T) {
	d := map[string]any{"name": "j", "steps": map[string]any{"s #1": map[string]any{"connection": "host=h password=pw1", "n": int64(3)}}}
	maskTree(d)
	got := d["steps"].(map[string]any)["s #1"].(map[string]any)
	if got["connection"] != "host=h password=<masked>" || got["n"] != int64(3) || d["name"] != "j" {
		t.Errorf("maskTree: %v", d)
	}
}
