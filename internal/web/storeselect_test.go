package web

import (
	"strings"
	"testing"
)

// WrapSelect: the text as the FROM of one SELECT, its trailing semicolons dropped, a trailing line comment kept off the
// wrap by the newline, the limit one past the cap; an empty or over-long text refused.
func TestWrapSelect(t *testing.T) {
	got, err := WrapSelect(" SELECT 1 AS n ; ; ", 1000)
	if err != nil || got != "SELECT * FROM (\nSELECT 1 AS n\n) AS q LIMIT 1001" {
		t.Fatalf("got %q, %v", got, err)
	}
	if got, _ := WrapSelect("SELECT 1 -- a note", 5); !strings.HasSuffix(got, "-- a note\n) AS q LIMIT 6") {
		t.Fatalf("a trailing comment: %q", got)
	}
	if _, err := WrapSelect(" ;; ", 5); err == nil {
		t.Fatal("an empty statement was taken")
	}
	if _, err := WrapSelect(strings.Repeat("x", MaxSelectText+1), 5); err == nil {
		t.Fatal("an over-long statement was taken")
	}
	// the cap counts characters, as the report function's length() does: 20,000 two-byte characters pass
	if _, err := WrapSelect("SELECT '"+strings.Repeat("é", MaxSelectText-9)+"'", 5); err != nil {
		t.Fatalf("20,000 characters of two bytes each: %v", err)
	}
	if _, err := WrapSelect("SELECT '"+strings.Repeat("é", MaxSelectText-8)+"'", 5); err == nil {
		t.Fatal("20,001 characters were taken")
	}
}
