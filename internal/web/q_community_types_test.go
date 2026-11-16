package web

import (
	"encoding/json"
	"strings"
	"testing"
)

// fakeCol is a result column as go-mssqldb describes it (*sql.ColumnType's three reads)
type fakeCol struct {
	name, typ    string
	null, nullOK bool
}

func (f fakeCol) Name() string                  { return f.name }
func (f fakeCol) DatabaseTypeName() string      { return f.typ }
func (f fakeCol) Nullable() (nullable, ok bool) { return f.null, f.nullOK }

// KITWATCH K4.1 (F7: opt-in): the Run answer carries each column's SQL type and nullability only when the request asks
// "exact_types": true - kitwatch reads a retype inside one coarse type (int -> bigint) from it; without it the answer
// is today's (the demo samples and every exact-JSON test unchanged).
func TestMSSetExactTypes(t *testing.T) {
	cts := []colType{fakeCol{"cpu", "BIGINT", true, true}, fakeCol{"status", "NVARCHAR", false, true}, fakeCol{"x", "INT", false, false}}
	plain := msSet(cts, false)
	if strings.Join(plain.Columns, ",") != "cpu,status,x" || strings.Join(plain.Types, ",") != "number,text,number" || plain.SQLTypes != nil || plain.Nullable != nil {
		t.Errorf("without exact_types: %+v", plain)
	}
	b, _ := json.Marshal(plain)
	if strings.Contains(string(b), "sql_types") || strings.Contains(string(b), "nullable") {
		t.Errorf("without exact_types the answer gained keys: %s", b)
	}
	exact := msSet(cts, true)
	if strings.Join(exact.SQLTypes, ",") != "BIGINT,NVARCHAR,INT" {
		t.Errorf("exact types: %v", exact.SQLTypes)
	}
	if len(exact.Nullable) != 3 || exact.Nullable[0] == nil || !*exact.Nullable[0] || exact.Nullable[1] == nil || *exact.Nullable[1] || exact.Nullable[2] != nil {
		t.Errorf("nullability (true, false, unknown): %v", exact.Nullable)
	}
	var body communityBody
	if err := json.Unmarshal([]byte(`{"tool":"sp_Blitz","instance_id":1,"exact_types":true}`), &body); err != nil || !body.ExactTypes {
		t.Errorf("the request's exact_types: %+v %v", body, err)
	}
}
