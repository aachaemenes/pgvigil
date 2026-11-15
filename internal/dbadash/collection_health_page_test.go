package dbadash

import (
	"database/sql"
	"testing"
	"time"

	mssql "github.com/microsoft/go-mssqldb"
)

// TestCollectionHealthPage (B6.3): the tenth screen calls dbo.CollectionHealth_Get as DBA Dash's GUI does by default
// (CollectionHealthView.cs: a row per collection per instance, steps shown, every status) - the instance as dbo.IDs,
// the range as utc2 text - and is gated: a repository without the procedure (4.24.1 and older) or a login without
// EXECUTE on it reads nothing and says why
func TestCollectionHealthPage(t *testing.T) {
	p, ok := PageByKey("collectionhealth")
	if !ok {
		t.Fatal("no collectionhealth page")
	}
	if p.Title != "Collection Health" || p.Procedure != "dbo.CollectionHealth_Get" || !p.Window || p.Since != "4.25.0" {
		t.Fatalf("page %+v", p)
	}
	from, to := time.Date(2026, 11, 14, 6, 0, 0, 0, time.UTC), time.Date(2026, 11, 14, 7, 30, 0, 0, time.UTC)
	got := map[string]any{}
	var order []string
	for _, a := range p.args(PageArgs{InstanceID: 7, From: from, To: to}) {
		n := a.(sql.NamedArg)
		got[n.Name] = n.Value
		order = append(order, n.Name)
	}
	want := []string{"InstanceIDs", "FromDate", "ToDate", "DetailMaxHours", "GroupByInstance", "IncludeSteps", "IncludeCritical", "IncludeWarning", "IncludeNA", "IncludeOK"}
	if len(order) != len(want) {
		t.Fatalf("arguments %v, want %v", order, want)
	}
	for i, w := range want {
		if order[i] != w {
			t.Fatalf("arguments %v, want %v", order, want)
		}
	}
	if tvp, ok := got["InstanceIDs"].(mssql.TVP); !ok || tvp.TypeName != "dbo.IDs" {
		t.Errorf("InstanceIDs %#v, want a dbo.IDs table", got["InstanceIDs"])
	}
	if got["FromDate"] != "2026-11-14T06:00:00" || got["ToDate"] != "2026-11-14T07:30:00" || got["DetailMaxHours"] != 48 {
		t.Errorf("from %v to %v detail %v", got["FromDate"], got["ToDate"], got["DetailMaxHours"])
	}
	for _, k := range want[4:] {
		if got[k] != true {
			t.Errorf("%s = %v, want true (DBA Dash's default)", k, got[k])
		}
	}
	for _, c := range []struct {
		exists, exec bool
		want         string
	}{
		{false, false, "not read: dbo.CollectionHealth_Get is not in this DBA Dash repository (it came with DBA Dash 4.25.0)"},
		{true, false, "not read: this login has no EXECUTE on dbo.CollectionHealth_Get (docs/dbadash.md's GRANT, on DBA Dash 4.25.0 and later)"},
		{true, true, ""},
	} {
		if g := gateNote(p, c.exists, c.exec); g != c.want {
			t.Errorf("gateNote(exists %v, exec %v) = %q, want %q", c.exists, c.exec, g, c.want)
		}
	}
	// a page with no Since is never gated
	if b, _ := PageByKey("backups"); b.Since != "" || gateNote(b, false, false) != "" {
		t.Errorf("backups gated: %+v", b)
	}
}
