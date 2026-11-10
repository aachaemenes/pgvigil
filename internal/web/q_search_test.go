package web

import "testing"

func TestLikePattern(t *testing.T) {
	for in, want := range map[string]string{
		"orders":   `%orders%`,
		"my_table": `%my\_table%`,
		"100%":     `%100\%%`,
		`a\b`:      `%a\\b%`,
	} {
		if got := likePattern(in); got != want {
			t.Errorf("likePattern(%q) = %q; want %q", in, got, want)
		}
	}
}
