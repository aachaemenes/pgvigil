package savetable

// review-31 part B's unit rows (written 11-17 07:2x, before savetable-g3): the CREATE's quoting asserted as text on both
// engines (B1; the writes' own statements are recorded in internal/mssql and internal/actions), the decimal cells'
// exact values (S10) and the hostile names on both engines (N14).

import (
	"encoding/json"
	"math/big"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgtype"
)

// B1: every identifier of the CREATE goes through the one quoting, on both engines; the types come from the closed
// list; no part of the text comes from a cell (CreateSQL takes none: the values travel as the bulk copy's data)
func TestCreateSQLQuotesEveryName(t *testing.T) {
	cols := []Col{{Name: `a"b`, Type: "int"}, {Name: "a]b", Type: "text"}, {Name: "x y", Type: "dec"}, {Name: "a;--", Type: "bool"}}
	tgt := Target{Database: "db", Schema: "pgvigil_saved", Table: `t"]'x`}
	for _, c := range []struct{ engine, want string }{
		{SQLServer, `CREATE TABLE [db].[pgvigil_saved].[t"]]'x] ([a"b] BIGINT NULL, [a]]b] NVARCHAR(MAX) NULL, [x y] DECIMAL(38,10) NULL, [a;--] BIT NULL)`},
		{Postgres, `CREATE TABLE "pgvigil_saved"."t""]'x" ("a""b" bigint NULL, "a]b" text NULL, "x y" numeric NULL, "a;--" boolean NULL)`},
	} {
		got, err := CreateSQL(c.engine, tgt, cols)
		if err != nil || got != c.want {
			t.Errorf("%s: %q %v, want %q", c.engine, got, err, c.want)
		}
	}
	// a kind outside the closed list never reaches the text
	if got, err := CreateSQL(Postgres, tgt, []Col{{Name: "a", Type: "text); DROP TABLE x;--"}}); err == nil || strings.Contains(got, "DROP") {
		t.Errorf("an unknown kind: %q %v, want refused", got, err)
	}
}

// S10: a dec cell is the value it says, exactly - SQL Server gets the decimal's own text (an exponent written out, more
// than 10 places refused, never rounded), PostgreSQL a numeric of the same value
func TestConvertDecExactValue(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"12.3456789012", "12.3456789012"},
		{"-1e-10", "-0.0000000001"},
		{"1.5", "1.5"},
		{"1E+3", "1000"},
		{"-0.25", "-0.25"},
	} {
		v, err := Convert(SQLServer, "dec", 1, "amt", json.Number(c.in))
		if s, ok := v.(string); err != nil || !ok || s != c.want {
			t.Errorf("SQL Server %s: %#v %v, want the text %q", c.in, v, err, c.want)
		}
		v, err = Convert(Postgres, "dec", 1, "amt", json.Number(c.in))
		n, ok := v.(pgtype.Numeric)
		want, _ := new(big.Rat).SetString(c.want)
		if err != nil || !ok || !n.Valid || n.NaN || n.Int == nil || numRat(n).Cmp(want) != 0 {
			t.Errorf("PostgreSQL %s: %#v %v, want the numeric %s", c.in, v, err, c.want)
		}
	}
	if v, err := Convert(SQLServer, "dec", 1, "amt", json.Number("1e-11")); err == nil || !strings.Contains(err.Error(), "10 decimal places") {
		t.Errorf("SQL Server 1e-11: %#v %v, want refused for its 11 places", v, err)
	}
}

// numRat is a pgtype.Numeric's exact value
func numRat(n pgtype.Numeric) *big.Rat {
	r := new(big.Rat).SetInt(n.Int)
	e := int64(n.Exp)
	if e < 0 {
		e = -e
	}
	p := new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(e), nil))
	if n.Exp < 0 {
		return r.Quo(r, p)
	}
	return r.Mul(r, p)
}

// N14: the names TestCheckNameRefusals tries on one engine only, on the other one too - each quoted, none refused
func TestCheckNameMirrors(t *testing.T) {
	for _, c := range []struct{ engine, name string }{
		{SQLServer, `a"b`}, {Postgres, `a]b`}, {Postgres, "[x]"},
		{SQLServer, "a.b"}, {Postgres, "dbo.Customers"},
	} {
		if err := CheckName(c.engine, "table", c.name); err != nil {
			t.Errorf("%s %q: %v, want quoted and taken", c.engine, c.name, err)
		}
	}
}
