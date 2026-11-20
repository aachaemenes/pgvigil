package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestFileReferencesL241 (RELNOTES L241): every env: / file: / dpapi: value of the file, wherever it sits, with where
// it sits (an instance by its name, another list item by its index), in the file's order; a value that only carries
// such a word inside it is no reference; a file that is not YAML is an error.
func TestFileReferencesL241(t *testing.T) {
	p := filepath.Join(t.TempDir(), "pgvigil.yaml")
	body := `repository:
  dsn: env:REPO
reports_dsn: " file:/etc/pgvigil/reports.dsn "
instances:
  - name: pg1
    dsn: "host=x password=env:NOT_A_REF"
    actions_dsn: file:/a
  - dsn: dpapi:C:\x\y.bin
alerts:
  channels:
    - webhook: env:HOOK
query_text: full
`
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	refs, err := FileReferences(p)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, r := range refs {
		got = append(got, r.Where+"="+r.Raw)
	}
	want := []string{
		"repository.dsn=env:REPO",
		"reports_dsn=file:/etc/pgvigil/reports.dsn",
		"instances[pg1].actions_dsn=file:/a",
		`instances[1].dsn=dpapi:C:\x\y.bin`,
		"alerts.channels[0].webhook=env:HOOK",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("references:\n%s\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	bad := filepath.Join(t.TempDir(), "bad.yaml")
	if err := os.WriteFile(bad, []byte("repository: [not, a, map\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := FileReferences(bad); err == nil {
		t.Error("a file that is not YAML is an error")
	}
	for _, c := range []struct {
		v    string
		want bool
	}{{"env:X", true}, {"file:/x", true}, {"dpapi:x", true}, {" env:X ", true}, {"host=x password=env:Y", false}, {"ENV:X", false}, {"", false}} {
		if IsReference(c.v) != c.want {
			t.Errorf("IsReference(%q) != %v", c.v, c.want)
		}
	}
}
