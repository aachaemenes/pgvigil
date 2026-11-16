package cq

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"strings"
	"testing"
)

// The result store's credential mask (task 488, CQ-16): a sqlcmd -P switch in a cell and a showplan's literal.
const (
	wkCmd     = "EXEC xp_cmdshell 'sqlcmd -S . -U app -P Wk1secret -Q x'"
	wkCmdWant = "EXEC xp_cmdshell 'sqlcmd -S . -U app -P <masked> -Q x'"
	wkPlan    = `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements>` +
		`<StmtSimple StatementText="ALTER LOGIN a WITH PASSWORD = &apos;Wk2secret&apos;" StatementId="1" /></Statements></Batch></BatchSequence></ShowPlanXML>`
)

// wellFormed reports an XML document's first syntax error, or nil.
func wellFormed(s string) error {
	d := xml.NewDecoder(strings.NewReader(s))
	for {
		if _, err := d.Token(); errors.Is(err, io.EOF) {
			return nil
		} else if err != nil {
			return err
		}
	}
}

// checkMasked reads ui_action_result's answer for the worker test's stand-in result: the -P switch masked, the plan's
// literal masked and the plan still XML, the boolean and the number as written.
func checkMasked(t *testing.T, res []byte) {
	t.Helper()
	var a struct {
		Result struct {
			Sets []struct {
				Columns []string `json:"columns"`
				Rows    [][]any  `json:"rows"`
			} `json:"sets"`
		} `json:"result"`
	}
	d := json.NewDecoder(bytes.NewReader(res))
	d.UseNumber()
	if err := d.Decode(&a); err != nil || len(a.Result.Sets) != 1 || len(a.Result.Sets[0].Rows) != 1 || len(a.Result.Sets[0].Rows[0]) != 4 {
		t.Fatalf("the stored result's shape: %s (%v)", res, err)
	}
	row := a.Result.Sets[0].Rows[0]
	if row[0] != true {
		t.Errorf("the boolean cell: %v", row[0])
	}
	if row[1] != wkCmdWant {
		t.Errorf("the sqlcmd cell:\n got %q\nwant %q", row[1], wkCmdWant)
	}
	plan, _ := row[2].(string)
	if strings.Contains(plan, "Wk2secret") || !strings.Contains(plan, "PASSWORD = &apos;&lt;masked&gt;&apos;") {
		t.Errorf("the plan cell: %q", plan)
	}
	if err := wellFormed(plan); err != nil {
		t.Errorf("the masked plan is not XML: %v\n%s", err, plan)
	}
	if row[3] != json.Number("12345678901234567") {
		t.Errorf("the number cell: %#v", row[3])
	}
}

// TestMaskResult: every string at any depth masked (a typed set's cells and column names, a nested message), the
// object keys, booleans, nulls and numbers kept as written, a second pass changing nothing; MaskRows and MaskStrings
// in place, a cell of another type untouched; nil stays nil; a value with no JSON form is an error.
func TestMaskResult(t *testing.T) {
	type set struct {
		Columns []string `json:"columns"`
		Rows    [][]any  `json:"rows"`
	}
	in := map[string]any{
		"sets": []set{{Columns: []string{"ok", "cmd", "plan", "n", "f", "none"}, Rows: [][]any{{true, wkCmd, wkPlan, int64(12345678901234567), 1.5, nil}}}},
		"words": map[string]any{"messages": []any{"CREATE LOGIN app WITH PASSWORD = N'Tq1secret', CHECK_POLICY = ON", "<IDLE>"},
			"password=Kp1secret": "a key is the result's own field name"},
	}
	out, err := MaskResult(in)
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	got := string(b)
	for _, secret := range []string{"Wk1secret", "Wk2secret", "Tq1secret"} {
		if strings.Contains(got, secret) {
			t.Errorf("the secret %q is still there: %s", secret, got)
		}
	}
	res := map[string]any{"result": out}
	rb, _ := json.Marshal(res)
	// checkMasked wants four cells: the first four of the row
	var four map[string]any
	d := json.NewDecoder(bytes.NewReader(rb))
	d.UseNumber()
	_ = d.Decode(&four)
	r0 := four["result"].(map[string]any)["sets"].([]any)[0].(map[string]any)
	row := r0["rows"].([]any)[0].([]any)
	if row[4] != json.Number("1.5") || row[5] != nil {
		t.Errorf("the float and the null: %#v %#v", row[4], row[5])
	}
	r0["rows"] = []any{row[:4]}
	rb, _ = json.Marshal(four)
	checkMasked(t, rb)
	w := out.(map[string]any)["words"].(map[string]any)
	if m := w["messages"].([]any); m[0] != "CREATE LOGIN app WITH PASSWORD = '<masked>', CHECK_POLICY = ON" || m[1] != "<IDLE>" {
		t.Errorf("the messages: %#v", m)
	}
	if _, ok := w["password=Kp1secret"]; !ok {
		t.Errorf("an object key was changed: %#v", w)
	}
	again, err := MaskResult(out)
	if err != nil {
		t.Fatal(err)
	}
	if b2, _ := json.Marshal(again); string(b2) != got {
		t.Errorf("a second pass changed the result:\n%s\n%s", got, b2)
	}

	rows := [][]any{{wkCmd, 7, "<IDLE>", nil}}
	cols := []string{"cmd", "PWD=Cs1secret;"}
	MaskRows(rows)
	MaskStrings(cols)
	if rows[0][0] != wkCmdWant || rows[0][1] != 7 || rows[0][2] != "<IDLE>" || rows[0][3] != nil {
		t.Errorf("MaskRows: %#v", rows)
	}
	if cols[0] != "cmd" || strings.Contains(cols[1], "Cs1secret") {
		t.Errorf("MaskStrings: %#v", cols)
	}

	if v, err := MaskResult(nil); v != nil || err != nil {
		t.Errorf("nil: %v %v", v, err)
	}
	if _, err := MaskResult(map[string]any{"c": make(chan int)}); err == nil {
		t.Error("a value with no JSON form was taken")
	}
}
