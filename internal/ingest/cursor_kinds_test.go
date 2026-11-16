package ingest

import (
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// H review part 2 N6, at the merge: a bundle whose end cursors carry the kinds W's writer writes for a set and for a
// source with nothing yet ('list', 'null') loads like any other - never set aside 'malformed' by an older copy of the
// format's cursor check. No names on the list: the same row compiles on H's own tip (its Cursor has none), its red there.
func TestRoundTakesListAndNullCursors(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	to := d.base.Add(5 * time.Minute)
	b, err := remote.OpenBundle(remote.BundleOptions{Outbox: d.root, Site: "site1", Collector: "c1", Stream: streamIDs["st1"], Seq: 1,
		From: to.Add(-5 * time.Minute), To: to, QueryText: "hash", PgvigilVersion: "v0.4.0", SchemaLevel: "0329_remote",
		Instance: format.Instance{Engine: "sqlserver", Name: d.instName(), Platform: "onprem", ServerVersion: "16.0", VersionNum: 16}})
	if err != nil {
		t.Fatal(err)
	}
	if err := b.AddBatch("mssql_activity", to.Add(-4*time.Minute), []map[string]any{{"session_id": 52}}); err != nil {
		t.Fatal(err)
	}
	cursors := []format.Cursor{{Source: "backup_files", Kind: "list"}, {Source: "jobs", Kind: "null"}}
	if _, err := b.Close(to, []format.Read{{Collection: "mssql_activity", Status: "ran", Runs: 1, IntervalSecs: 60}}, cursors,
		format.Heartbeat{Host: "jump01", Started: d.base, At: to, Instances: 1}); err != nil {
		t.Fatalf("the writer refused a list and a null cursor: %v", err)
	}
	r := round(t, d.ingester(h, d.base.Add(time.Hour), nil))
	eq(t, "loaded", r.Loaded, 1)
	eq(t, "set aside", r.SetAside, 0)
	eq(t, "marks", h.markKinds(), []string{})
}
