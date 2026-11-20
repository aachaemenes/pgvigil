package mssql

import (
	"strings"
	"testing"
)

// TestBuildDocs (task 412, decision B1 (a)): a build's own page only when the catalogue lists that very build;
// an RTM row with no page and a 2025 product page link Microsoft's build list in words; an unlisted or newer build says
// so; a major the catalogue lacks gets nothing.
func TestBuildDocs(t *testing.T) {
	cases := []struct {
		major, build int
		url, words   string
	}{
		{15, 4470, "https://support.microsoft.com/kb/5090407", "Microsoft: Cumulative Update 32 GDR (15.0.4470)"},
		{16, 1000, buildListURL, "no page of RTM's own"},
		{17, 1000, buildListURL, "no page of RTM's own"},
		{15, 4466, buildListURL, "a build the catalogue does not list"}, // between 4465 and 4470, 2019's newest
		{15, 4471, buildListURL, "a build newer than the catalogue"},
		{17, 99999, buildListURL, "a build newer than the catalogue"},
	}
	for _, c := range cases {
		d := BuildDocs(c.major, c.build)
		if d == nil {
			t.Fatalf("BuildDocs(%d, %d): nil", c.major, c.build)
		}
		if d["build_url"] != c.url || !strings.Contains(d["build_url_words"].(string), c.words) {
			t.Errorf("BuildDocs(%d, %d): %q %q (want %q, words with %q)", c.major, c.build, d["build_url"], d["build_url_words"], c.url, c.words)
		}
	}
	if d := BuildDocs(17, 4055); d["newest_build"] != "17.0.4055" || d["newest_url"] == "" {
		t.Errorf("the newest 2025 build: %v", d)
	}
	if d := BuildDocs(12, 6024); d != nil {
		t.Errorf("a major the catalogue lacks: %v", d)
	}
	if d := BuildDocsOf(""); len(d) != 0 {
		t.Errorf("BuildDocsOf(\"\"): %v", d)
	}
	if d := BuildDocsOf("15.0.4470.1"); d["build_url"] != "https://support.microsoft.com/kb/5090407" {
		t.Errorf("BuildDocsOf(15.0.4470.1): %v", d)
	}
	// what the instance row holds is the first line of @@VERSION, not the bare product version (a lab run: no
	// link on any real instance): the dotted build inside it is the one read
	if d := BuildDocsOf("Microsoft SQL Server 2019 (RTM-CU32-GDR) (KB5090407) - 15.0.4470.1 (X64) "); d["build_url"] != "https://support.microsoft.com/kb/5090407" {
		t.Errorf("BuildDocsOf(the first line of @@VERSION, 15.0.4470.1): %v", d)
	}
	if d := BuildDocsOf("Microsoft SQL Server 2022 (RTM-CU28) (KB5125472) - 16.0.4325.4 (X64)"); d["build_url"] != buildListURL ||
		!strings.Contains(d["build_url_words"].(string), "a build newer than the catalogue") || d["newest_build"] != "16.0.4255" {
		t.Errorf("BuildDocsOf(the first line of @@VERSION, 16.0.4325.4): %v", d)
	}
	if d := BuildDocsOf("Microsoft SQL Azure (RTM) - 12.0.2000.8"); len(d) != 0 {
		t.Errorf("BuildDocsOf(Azure SQL Database, a major the catalogue lacks): %v", d)
	}
	// a preview's name holds a dotted number of its own ('CTP2.1'): the build read is the three-part one after it, a
	// row the catalogue lists with a product page only (a read of '2.1' would be major 2: no row, an empty map)
	if d := BuildDocsOf("Microsoft SQL Server 2025 (CTP2.1) - 17.0.800.3 (X64)"); d["build_url"] != buildListURL ||
		!strings.Contains(d["build_url_words"].(string), "no page of Preview CTP 2.1's own") || d["newest_build"] != "17.0.4055" {
		t.Errorf("BuildDocsOf(the first line of @@VERSION, 17.0.800.3): %v", d)
	}
	// every page of the catalogue is empty or Microsoft's, with no blank around it
	for major, rows := range builds {
		for _, r := range rows {
			if r.URL != strings.TrimSpace(r.URL) || (r.URL != "" && !strings.HasPrefix(r.URL, "https://support.microsoft.com/") &&
				!strings.HasPrefix(r.URL, "https://learn.microsoft.com/") && !strings.HasPrefix(r.URL, "https://info.microsoft.com/")) {
				t.Errorf("%d.0.%d: page %q", major, r.Build, r.URL)
			}
		}
	}
}
