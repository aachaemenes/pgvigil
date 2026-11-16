package mssql

import (
	"strings"
	"testing"
	"time"
)

func TestSchemaInScope(t *testing.T) {
	for _, c := range []struct {
		list []string
		in   []string
		out  []string
	}{
		{[]string{"*"}, []string{"Sales", "hr"}, nil},
		{[]string{"Sales"}, []string{"sales", "SALES"}, []string{"hr"}},
		{[]string{"*", "-hr"}, []string{"Sales"}, []string{"HR", "hr"}},
		{[]string{"-hr"}, []string{"Sales", "erp"}, []string{"hr"}},
		{nil, nil, []string{"Sales"}},
		{[]string{" "}, nil, []string{"Sales"}},
	} {
		f := schemaInScope(c.list)
		for _, n := range c.in {
			if !f(n) {
				t.Errorf("%q: %q is out of scope, want in", c.list, n)
			}
		}
		for _, n := range c.out {
			if f(n) {
				t.Errorf("%q: %q is in scope, want out", c.list, n)
			}
		}
	}
}

// S14: a part with a dot, a space or a double quote is quoted, so two different objects never share an identity.
func TestSchemaIdentities(t *testing.T) {
	a := schemaObj{kind: "column", pschema: "dbo", pname: "a.b", name: "c"}
	b := schemaObj{kind: "column", pschema: "dbo", pname: "a", name: "b.c"}
	if a.identity() == b.identity() {
		t.Fatalf("[a.b].[c] and [a].[b.c] share the identity %q", a.identity())
	}
	for _, c := range []struct {
		o    schemaObj
		want string
	}{
		{schemaObj{kind: "table", schema: "dbo", name: "Orders"}, "dbo.Orders"},
		{schemaObj{kind: "table", schema: "dbo", name: `say "hi"`}, `dbo."say ""hi"""`},
		{schemaObj{kind: "column", pschema: "dbo", pname: "Orders", name: "id"}, "dbo.Orders.id"},
		{schemaObj{kind: "index", pschema: "dbo", pname: "Orders", name: "ix_date"}, "ix_date on dbo.Orders"},
		{schemaObj{kind: "trigger", pschema: "s", pname: "t", name: "trg x"}, `"trg x" on s.t`},
		{schemaObj{kind: "schema", schema: "audit"}, "audit"},
	} {
		if got := c.o.identity(); got != c.want {
			t.Errorf("%s %q: identity %q, want %q", c.o.kind, c.o.name, got, c.want)
		}
	}
	if p := (schemaObj{kind: "index", pschema: "dbo", pname: "Orders", name: "ix"}).parent(); p != "dbo.Orders" {
		t.Errorf("an index's parent is %v, want dbo.Orders", p)
	}
	if p := (schemaObj{kind: "table", schema: "dbo", name: "Orders"}).parent(); p != nil {
		t.Errorf("a table's parent is %v, want none", p)
	}
}

// A1 and B2: a body is text under full (masked), a sha line otherwise; the hash and def_hash are
// the same under every policy, so a change of query_text is never a schema change; a view's text is kept always. The
// B+C review's B2: a body that names a password or a secret (the DDL log's own test) is never kept as text, under any
// policy - its sha line and the words (red on d3ea6294: its masked text was stored).
func TestSchemaFormsAndHashes(t *testing.T) {
	const withheld = "(body text not kept: it names a password or a secret)"
	db := userDB{id: 7, name: "shop"}
	plain := schemaObj{kind: "procedure", schema: "dbo", name: "p", def: "procedure P parameters []", hasBody: true, owner: "dbo",
		body: "CREATE PROCEDURE dbo.p AS SELECT name FROM sys.objects; SELECT 1"}
	full, none, norm := schemaRow(db, plain, "full"), schemaRow(db, plain, "none"), schemaRow(db, plain, "normalized")
	if full["hash"] != none["hash"] || full["hash"] != norm["hash"] || full["def_hash"] != none["def_hash"] {
		t.Fatalf("the hashes differ by policy: full %v / %v, none %v / %v", full["hash"], full["def_hash"], none["hash"], none["def_hash"])
	}
	fd, nd := full["definition"].(string), none["definition"].(string)
	if !strings.Contains(fd, "CREATE PROCEDURE dbo.p") {
		t.Errorf("under full the body is not its text: %q", fd)
	}
	if strings.Contains(nd, "CREATE PROCEDURE") || !strings.Contains(nd, "body sha256:") {
		t.Errorf("under none the body is not its sha line: %q", nd)
	}
	if def := schemaRow(db, plain, "")["definition"].(string); def != fd {
		t.Errorf("no policy set (the configuration's default, full) stores %q, want the text", def)
	}
	// a body change always changes the hash
	changed := plain
	changed.body = strings.Replace(plain.body, "SELECT 1", "SELECT 2", 1)
	if schemaRow(db, changed, "none")["hash"] == none["hash"] {
		t.Error("a body change left the hash unchanged")
	}
	// a body naming a password: its sha line and the words under every policy, never its text; the hash as ever
	secret := plain
	secret.body = "CREATE PROCEDURE dbo.p AS OPEN SYMMETRIC KEY k DECRYPTION BY PASSWORD = 'S3cret'; EXEC (N'ALTER LOGIN a WITH PASSWORD = ''Tw0''')"
	for _, mode := range []string{"full", ""} {
		d := schemaRow(db, secret, mode)["definition"].(string)
		if strings.Contains(d, "S3cret") || strings.Contains(d, "Tw0") || strings.Contains(d, "OPEN SYMMETRIC") ||
			!strings.Contains(d, "body sha256:") || !strings.HasSuffix(d, "\n"+withheld) {
			t.Errorf("a body naming a password under %q stores %q, want its sha line and %q", mode, d, withheld)
		}
	}
	if schemaRow(db, secret, "full")["hash"] != schemaRow(db, secret, "none")["hash"] {
		t.Error("a withheld body's hash differs by policy")
	}
	rotated := secret
	rotated.body = strings.Replace(secret.body, "S3cret", "N3wPass", 1)
	if r := schemaRow(db, rotated, "full"); r["hash"] == schemaRow(db, secret, "full")["hash"] || strings.Contains(r["definition"].(string), "N3wPass") {
		t.Errorf("a rotated password: the hash must change and the text never hold it: %v", r["definition"])
	}
	view := schemaObj{kind: "view", schema: "dbo", name: "v", def: "view", hasBody: true, body: "CREATE VIEW dbo.v AS SELECT 1 AS x"}
	if d := schemaRow(db, view, "none")["definition"].(string); !strings.Contains(d, "CREATE VIEW dbo.v") {
		t.Errorf("a view's text is not kept under none: %q", d)
	}
	secretView := schemaObj{kind: "view", schema: "dbo", name: "v2", def: "view", hasBody: true, body: "CREATE VIEW dbo.v2 AS SELECT secret_value FROM dbo.k"}
	if d := schemaRow(db, secretView, "none")["definition"].(string); strings.Contains(d, "secret_value") || !strings.HasSuffix(d, withheld) {
		t.Errorf("a view naming a secret under none stores %q, want its sha line and the words", d)
	}
	// the stored text is cut at 20,000 characters; the hash is taken before the cut
	long := plain
	long.body = strings.Repeat("x", 50000)
	r := schemaRow(db, long, "full")
	if n := len([]rune(r["definition"].(string))); n > schemaMaxDef {
		t.Errorf("a long body is stored at %d characters, over %d", n, schemaMaxDef)
	}
	longer := long
	longer.body += "y"
	if schemaRow(db, longer, "full")["hash"] == r["hash"] {
		t.Error("a change past the cut left the hash unchanged")
	}
}

func TestSchemaFingerprintSame(t *testing.T) {
	a := schemaFingerprint{objects: 10, indexes: 4, tablesViews: 3, newest: "2026-11-15T10:00:00.000"}
	if !a.same(a) {
		t.Fatal("a fingerprint differs from itself")
	}
	for _, b := range []schemaFingerprint{
		{objects: 11, indexes: 4, tablesViews: 3, newest: a.newest},
		{objects: 10, indexes: 5, tablesViews: 3, newest: a.newest},
		{objects: 10, indexes: 4, tablesViews: 3, newest: "2026-11-15T10:00:01.000"},
	} {
		if a.same(b) {
			t.Errorf("%+v and %+v read as the same (a torn read would be stored)", a, b)
		}
	}
}

// B-3 and S-2 of the build review: the 'mssql_db' row carries the server-clock create date (the identity) and the
// clock of a read that ended 'partial'.
func TestSchemaDBRowIdentity(t *testing.T) {
	db := userDB{id: 7, name: "shop", row: map[string]any{"created_at": "2026-03-08T10:00:00Z"}}
	at := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	r := mssqlDBRow(db, schemaLocal{createLocal: "2026-03-08T02:00:00.000"}, "partial", "too large", nil, &at)
	if pa, ok := r["partial_at"].(time.Time); r["create_local"] != "2026-03-08T02:00:00.000" || !ok || !pa.Equal(at) || r["read_at"] != nil {
		t.Errorf("the row is %v, want create_local, partial_at and no read_at", r)
	}
	if r := mssqlDBRow(db, schemaLocal{}, "seen", "", nil, nil); r["create_local"] != nil || r["partial_at"] != nil {
		t.Errorf("a row without a local create date or an attempt: %v", r)
	}
}
