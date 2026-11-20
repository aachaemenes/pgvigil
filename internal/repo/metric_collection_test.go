package repo

import (
	"fmt"
	"strings"
	"testing"
)

// armFile: one embedded migration's name and text
type armFile struct{ name, body string }

// collectionArmKept: the newest file defining pgvigil.metric_points carries the Collection arm, and the newest file
// writing the metric_catalog view keeps the 'collection' rows (0166 extends both of 0085's; a later file copying 0085's
// body would drop the family without an error)
func collectionArmKept(files []armFile) error {
	var points, catalog armFile
	for _, f := range files {
		if strings.Contains(f.body, "FUNCTION pgvigil.metric_points(") {
			points = f
		}
		if strings.Contains(f.body, "VIEW pgvigil.metric_catalog AS") {
			catalog = f
		}
	}
	if points.name == "" || catalog.name == "" {
		return fmt.Errorf("no embedded migration defines pgvigil.metric_points (%q) or the metric_catalog view (%q)", points.name, catalog.name)
	}
	if !strings.Contains(points.body, "p_family = 'collection'") {
		return fmt.Errorf("%s defines pgvigil.metric_points last and has no Collection arm (p_family = 'collection'): 0166's family is dropped", points.name)
	}
	if !strings.Contains(catalog.body, "'collection'") {
		return fmt.Errorf("%s writes the metric_catalog view last and has no 'collection' rows: 0166's family is dropped", catalog.name)
	}
	return nil
}

// TestMetricCollectionArmKept: the embedded migrations keep the Collection family's
// catalog rows and metric_points arm; the check's own rows show a later file copying 0085's body fails it
func TestMetricCollectionArmKept(t *testing.T) {
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	var files []armFile
	for _, n := range names {
		b, err := migrations.ReadFile("sql/" + n)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, armFile{n, string(b)})
	}
	if err := collectionArmKept(files); err != nil {
		t.Error(err)
	}
	later := func(body string) []armFile {
		return append(append([]armFile{}, files...), armFile{"9999_later.sql", body})
	}
	for name, body := range map[string]string{
		"a later metric_points from 0085's body":  "CREATE OR REPLACE FUNCTION pgvigil.metric_points(p_instance_id int, p_family text) ... IF p_family = 'sessions' THEN ...",
		"a later metric_catalog from 0085's list": "CREATE OR REPLACE VIEW pgvigil.metric_catalog AS SELECT ... ('any', 'host', 'Host', 90, 'load1', ...)",
	} {
		if collectionArmKept(later(body)) == nil {
			t.Errorf("%s: not flagged", name)
		}
	}
	if err := collectionArmKept(later("CREATE OR REPLACE FUNCTION pgvigil.metric_points(...) ... IF p_family = 'collection' THEN ...")); err != nil {
		t.Errorf("a later metric_points that keeps the arm: flagged (%v)", err)
	}
}
