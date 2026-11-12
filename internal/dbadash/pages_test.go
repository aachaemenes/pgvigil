package dbadash

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

func TestProven(t *testing.T) {
	cases := []struct {
		version string
		want    bool
	}{
		{"4.24.1", true}, {"4.24.1.0", true}, {" 4.24.1.3 ", true}, // the padded one: Proven trims the version row
		{"4.24.10", false}, {"4.24.0", false}, {"4.25.0", false}, {"", false},
	}
	for _, c := range cases {
		if got := Proven(c.version); got != c.want {
			t.Errorf("Proven(%q) = %v, want %v", c.version, got, c.want)
		}
	}
}

func TestPagesNamed(t *testing.T) {
	seen := map[string]bool{}
	for _, p := range Pages {
		if seen[p.Key] {
			t.Errorf("page %s twice", p.Key)
		}
		seen[p.Key] = true
		if len(p.Procedure) < 9 || p.Procedure[:4] != "dbo." || p.Procedure[len(p.Procedure)-4:] != "_Get" {
			t.Errorf("page %s calls %s: every page calls a dbo.*_Get", p.Key, p.Procedure)
		}
		if p.Procedure == "dbo.Summary_Get" {
			t.Errorf("page %s calls dbo.Summary_Get, which may run dbo.Summary_Upd", p.Key)
		}
		if got, ok := PageByKey(p.Key); !ok || got.Procedure != p.Procedure {
			t.Errorf("PageByKey(%s)", p.Key)
		}
		if args := p.args(PageArgs{InstanceID: 7, From: time.Now().Add(-time.Hour), To: time.Now()}); len(args) == 0 {
			t.Errorf("page %s passes no argument", p.Key)
		}
	}
	if _, ok := PageByKey("summary_upd"); ok {
		t.Error("an unknown page was found")
	}
	if len(Procedures()) != len(Pages) {
		t.Error("Procedures")
	}
}

func TestPageRefusals(t *testing.T) {
	ctx := context.Background()
	if _, err := PageDSN(ctx, "sqlserver://x@127.0.0.1:1", "nope", PageArgs{InstanceID: 1}); err == nil {
		t.Error("an unknown page was called")
	}
	if _, err := PageDSN(ctx, "sqlserver://x@127.0.0.1:1", "backups", PageArgs{}); err == nil {
		t.Error("a page without an instance was called")
	}
	if _, err := PageDSN(ctx, "sqlserver://x@127.0.0.1:1", "performance", PageArgs{InstanceID: 1}); err == nil {
		t.Error("a windowed page without a window was called")
	}
	if _, err := PageDSN(ctx, " ", "backups", PageArgs{InstanceID: 1}); err == nil {
		t.Error("an empty dsn was used")
	}
	SetRepositories([]config.DBADashRepo{{Name: "Corp", DSNRaw: "env:PGVIGIL_TEST_NOT_SET"}})
	defer SetRepositories(nil)
	if _, err := Page(ctx, "other", "backups", PageArgs{InstanceID: 1}); !errors.Is(err, ErrNoRepository) {
		t.Errorf("an unconfigured repository: %v", err)
	}
	if _, err := Page(ctx, "corp", "backups", PageArgs{InstanceID: 1}); err == nil || errors.Is(err, ErrNoRepository) {
		t.Errorf("a configured repository (case-insensitive) whose dsn resolves to nothing: %v", err)
	}
}

func TestCellValue(t *testing.T) {
	at := time.Date(2026, 11, 11, 22, 1, 2, 340000000, time.UTC)
	cases := []struct {
		typ  string
		in   any
		want any
	}{
		{"DATETIME2", at, "2026-11-11 22:01:02.34"},
		{"DATE", at, "2026-11-11"},
		{"DECIMAL", []byte("12.345000"), "12.345000"},
		{"VARBINARY", []byte{0x01, 0xab}, "0x01AB"},
		{"UNIQUEIDENTIFIER", []byte{0x67, 0x45, 0x23, 0x01, 0xab, 0x89, 0xef, 0xcd, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef}, "01234567-89AB-CDEF-0123-456789ABCDEF"},
		{"INT", int64(5), int64(5)},
		{"NVARCHAR", nil, nil},
	}
	for _, c := range cases {
		if got := cellValue(c.typ, c.in); got != c.want {
			t.Errorf("cellValue(%s, %v) = %v, want %v", c.typ, c.in, got, c.want)
		}
	}
}

func TestVersionNum(t *testing.T) {
	for v, want := range map[string]any{"16.0.4295.3": 160000, "13.0.7037.1": 130000, "17.1.1000.2": 170001, "": nil, "x": nil} {
		if got := versionNum(v); got != want {
			t.Errorf("versionNum(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestImportMappings(t *testing.T) {
	if len(ImportMappings()) != 4 {
		t.Fatalf("mappings: %v", ImportMappings())
	}
	for _, m := range importMappings {
		for _, s := range []string{m.Count, m.Rows} {
			if !contains(s, "@id") || !contains(s, "@from") || !contains(s, "@to") {
				t.Errorf("%s: a T-SQL statement without @id, @from and @to", m.Key)
			}
		}
		if !contains(m.Rows, " AS at") || !contains(m.Rows, "ORDER BY") {
			t.Errorf("%s: the rows must alias their time 'at' and come in time order", m.Key)
		}
		if !contains(m.Insert, "NOT EXISTS") || !contains(m.Insert, "pgvigil."+m.Table) || !contains(m.Stored, "pgvigil."+m.Table) {
			t.Errorf("%s: the insert must skip a stored row and write its own table", m.Key)
		}
		// insertBatch passes $3 only to an insert that says it takes the facts: the driver refuses a count that differs
		if contains(m.Insert, "$3") != m.Facts {
			t.Errorf("%s: the insert uses $3 = %v but Facts = %v", m.Key, contains(m.Insert, "$3"), m.Facts)
		}
	}
	if _, err := Import(context.Background(), nil, " ", "x", ImportOptions{}); err == nil {
		t.Error("an empty source dsn was used")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestImportFlags(t *testing.T) {
	opt, err := importFlags("3, 7", "2026-11-01T00:00:00Z", "2026-11-02T00:00:00Z", "3=sql-a, 7 = sql-b", true)
	if err != nil || len(opt.Instances) != 2 || opt.Instances[1] != 7 || opt.Names[7] != "sql-b" || !opt.DryRun || opt.From.Day() != 1 {
		t.Fatalf("importFlags: %+v %v", opt, err)
	}
	for _, bad := range [][4]string{{"x", "", "", ""}, {"0", "", "", ""}, {"", "yesterday", "", ""}, {"", "2026-11-02T00:00:00Z", "2026-11-01T00:00:00Z", ""}, {"", "", "", "3"}, {"", "", "", "x=a"}, {"", "", "", "3="}} {
		if _, err := importFlags(bad[0], bad[1], bad[2], bad[3], false); err == nil {
			t.Errorf("importFlags(%q) passed", bad)
		}
	}
	if err := ImportCommand(context.Background(), nil, nil, []string{"other"}); err == nil {
		t.Error("import without 'dbadash' passed")
	}
	if err := ImportCommand(context.Background(), nil, nil, []string{"dbadash", "-config", "/nonexistent.yaml"}); err == nil {
		t.Error("import without -repo passed")
	}
}
