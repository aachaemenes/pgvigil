package web

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/cq"
)

// CQ-LIVEMASK: serve's direct community run shows the text the request queue stores - every text cell, a JSON cell's
// strings, a processing instruction's text, every column name and the run's error words masked; the audit row's
// detail and statement masked before the write on both paths.

const lmPW = "Lm1secret"

// lmJSON is v as JSON with '<' and '>' as written (json.Marshal writes them \u003c / \u003e)
func lmJSON(t *testing.T, v any) string {
	t.Helper()
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

var lmCmd = "sqlcmd -S . -U app -P " + lmPW + " -Q x"

// lmDecode is a JSON text as a value, its numbers as written (json.Number), so 7 and 7 compare equal whatever type
// carried them
func lmDecode(t *testing.T, s string) any {
	t.Helper()
	d := json.NewDecoder(strings.NewReader(s))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

// lmRun is a direct run's reply as communityExec builds it, before the mask: a fresh copy per call (the mask works in
// place)
func lmRun() instanceRun {
	return instanceRun{Instance: "i1", Engine: "sqlserver", Outcome: "failed", Error: "mssql: " + lmCmd,
		Sets: []resultSet{{Columns: []string{"n", "cmd", "query", "PASSWORD = '" + lmPW + "'"}, Types: []string{"number", "text", "text", "text"},
			Rows: [][]any{
				{int64(7), lmCmd, "<?query --\r\n" + lmCmd + "\r\n--?>", "plain"},
				{nil, map[string]any{"text": lmCmd, "n": 3.5}, []any{lmCmd, true}, ""},
			}}}}
}

func TestMaskRunMasksTheDirectRun(t *testing.T) {
	run := lmRun()
	maskRun(&run)
	b := lmJSON(t, run)
	if strings.Contains(b, lmPW) {
		t.Fatalf("the direct run still holds the password: %s", b)
	}
	// the text cell, the processing instruction, the JSON object's and the JSON array's strings, the error words
	if n := strings.Count(b, "-P <masked>"); n < 5 {
		t.Fatalf("want the -P switch masked in 5 places at least, got %d: %s", n, b)
	}
	if run.Sets[0].Rows[0][0] != int64(7) || run.Sets[0].Rows[0][3] != "plain" || run.Sets[0].Rows[1][0] != nil {
		t.Fatalf("a value without a credential changed: %#v", run.Sets[0].Rows)
	}
	if !strings.HasPrefix(run.Sets[0].Rows[0][2].(string), "<?query --") {
		t.Fatalf("the processing instruction lost its shape: %q", run.Sets[0].Rows[0][2])
	}
	// a second pass changes nothing (the queue's later passes run over an already masked result)
	again := run
	again.Sets = []resultSet{{Columns: append([]string(nil), run.Sets[0].Columns...), Types: run.Sets[0].Types,
		Rows: [][]any{append([]any(nil), run.Sets[0].Rows[0]...), append([]any(nil), run.Sets[0].Rows[1]...)}}}
	maskRun(&again)
	if b2 := lmJSON(t, again); b2 != b {
		t.Fatalf("a second mask changed the run:\n%s\n%s", b, b2)
	}
}

// the same text on either path: the direct reply's sets equal what the queue stores for the same run (cqSets, then
// the worker's MaskResult)
func TestMaskRunEqualsTheQueuesStore(t *testing.T) {
	direct := lmRun()
	maskRun(&direct)
	queued, err := cq.MaskResult(cqSets(lmRun())["sets"])
	if err != nil {
		t.Fatal(err)
	}
	// compared as values (review B1): the direct sets are structs (fields in their declared order), the queue's are
	// maps (keys sorted), so their JSON texts differ in order alone
	d, q := lmJSON(t, direct.Sets), lmJSON(t, queued)
	if !reflect.DeepEqual(lmDecode(t, d), lmDecode(t, q)) {
		t.Fatalf("the direct run's sets differ from the queue's stored sets:\ndirect %s\nqueued %s", d, q)
	}
	if direct.Error != cq.MaskText("mssql: "+lmCmd) {
		t.Fatalf("the direct run's error words: %q, want the queue's %q", direct.Error, cq.MaskText("mssql: "+lmCmd))
	}
}

func TestMaskAuditRow(t *testing.T) {
	stmt := "RAISERROR('" + lmCmd + "', 16, 1)"
	row := map[string]any{"op": "community_run", "tool": "glenn_berry", "report_name": "1 x", "detail": "mssql: " + lmCmd,
		"statement": stmt, "rows": 0, "outcome": "failed"}
	maskAudit(row)
	for _, k := range []string{"detail", "statement"} {
		s, _ := row[k].(string)
		if strings.Contains(s, lmPW) || !strings.Contains(s, "-P <masked>") {
			t.Fatalf("the audit row's %s: %q, want the -P switch masked", k, s)
		}
	}
	if row["op"] != "community_run" || row["tool"] != "glenn_berry" || row["report_name"] != "1 x" || row["rows"] != 0 || row["outcome"] != "failed" {
		t.Fatalf("an audit field without a credential changed: %v", row)
	}
	// the queue's writer masks the row it is given when it is built (the write itself is the worker's transaction)
	qrow := map[string]any{"op": "community_run", "detail": "mssql: " + lmCmd, "statement": stmt}
	_ = cqAuditRow(qrow)
	if strings.Contains(qrow["detail"].(string), lmPW) || strings.Contains(qrow["statement"].(string), lmPW) {
		t.Fatalf("cqAuditRow writes the password: %v", qrow)
	}
	// a row without detail or statement gets none
	bare := map[string]any{"op": "community_run"}
	maskAudit(bare)
	if _, ok := bare["detail"]; ok {
		t.Fatalf("a detail was added: %v", bare)
	}
}
