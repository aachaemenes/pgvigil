package collect

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestNormalizeSQL(t *testing.T) {
	cases := []struct{ in, want string }{
		{"SELECT * FROM t1 WHERE id = 42 AND name = 'bob'", "SELECT * FROM t1 WHERE id = ? AND name = ?"},
		{"select col2, 3.5e10 from s.t2 where x in (1, 2,3) and y = $1", "select col2, ? from s.t2 where x in (?) and y = $1"},
		{"insert into a values (E'it''s', 'o''k', -7)", "insert into a values (?, ?, -?)"},
		{"do $body$ begin perform 1; end $body$; select $$raw 'x'$$", "do ?; select ?"},
		{"ALTER ROLE app PASSWORD '<masked>' VALID UNTIL '2030-01-01'", "ALTER ROLE app PASSWORD ? VALID UNTIL ?"},
		{"select   *\n  from  t\twhere a = 1  ", "select * from t where a = ?"},
		{"select ts - interval '1 day', 0.5 * price, ip = '10.0.0.1'::inet from o", "select ts - interval ?, ? * price, ip = ?::inet from o"},
		// review 14: shapes that desynchronised the regex chain
		{`select E'it\'s' , 'secret-1' from t`, "select ? , ? from t"},
		{"/* app: user's dashboard */ select 'secret-6' from t where a = 7", "select ? from t where a = ?"},
		{"-- don't log this\nselect 'secret-7' from t", "select ? from t"},
		{`select "it's" from t where k = 'secret-8'`, `select "it's" from t where k = ?`},
		{"select $a$ x $b$ secret-10 $a$", "select ?"},
		{"select .5, a-1, t.col3, 2.", "select ?, a-?, t.col3, ?"},
		{"/* outer /* nested 'x' */ still comment */ select 1", "select ?"},
		{"select U&'d\\0061t\\+000061' , B'1010', x'FF', n'txt' , nope'", "select ? , ?, ?, ? , nope?"},
		{"select 'unterminated and the rest is literal; select secret", "select ?"},
		{"select e from t where $2 = e", "select e from t where $2 = e"},
		{"select \"a\"\"b\" from \"we're\"", "select \"a\"\"b\" from \"we're\""},
	}
	for _, c := range cases {
		if got := normalizeSQL(c.in); got != c.want {
			t.Errorf("normalizeSQL(%q)\n got %q\nwant %q", c.in, got, c.want)
		}
	}
}

func TestApplyTextPolicy(t *testing.T) {
	mk := func() []Row {
		return []Row{
			{"kind": "session", "query": "select 1 from t where k = 'v'", "query_hash": int64(7)},
			{"kind": "session", "query": "select 1 from t where k = 'w'", "query_hash": int64(8)},
			{"kind": "event", "statement": "update t set a = 2", "detail": "Process 10: delete from t where id = 3", "pid": 10},
			{"kind": "summary", "total": 3},
			{"kind": "session", "query": nil, "query_hash": int64(9)},
		}
	}
	rows := mk()
	applyTextPolicy(rows, "full")
	if rows[0]["query"] != "select 1 from t where k = 'v'" || rows[0]["query_hash"] != int64(7) {
		t.Errorf("full changed the row: %v", rows[0])
	}
	rows = mk()
	applyTextPolicy(rows, "")
	if rows[2]["statement"] != "update t set a = 2" {
		t.Errorf("an empty mode is full: %v", rows[2]["statement"])
	}
	rows = mk()
	applyTextPolicy(rows, "normalized")
	if rows[0]["query"] != "select ? from t where k = ?" || rows[2]["statement"] != "update t set a = ?" || rows[2]["detail"] != "Process ?: delete from t where id = ?" {
		t.Errorf("normalized: %v | %v | %v", rows[0]["query"], rows[2]["statement"], rows[2]["detail"])
	}
	// the same shape with different literals shares one hash, and it is not the raw text's hash
	if rows[0]["query_hash"] != rows[1]["query_hash"] || rows[0]["query_hash"] == int64(7) {
		t.Errorf("normalized hashes: %v %v (raw 7 and 8)", rows[0]["query_hash"], rows[1]["query_hash"])
	}
	if rows[4]["query_hash"] != nil {
		t.Errorf("a session without text keeps a raw hash under normalized: %v", rows[4]["query_hash"])
	}
	if rows[2]["pid"] != 10 || rows[3]["total"] != 3 {
		t.Error("a non-text column changed")
	}
	rows = mk()
	applyTextPolicy(rows, "none")
	if rows[0]["query"] != nil || rows[2]["statement"] != nil || rows[2]["detail"] != nil || rows[0]["query_hash"] != nil {
		t.Errorf("none kept text or a hash: %v | %v", rows[0], rows[2])
	}
	if _, ok := rows[0]["query"]; !ok {
		t.Error("none should keep the column with a nil value, not drop it")
	}
}

// The log reader's rows under the policy, on the real lab batch: normalized leaves no quoted literal
// and no standalone number in any statement or detail; none leaves no text at all.
func TestTextPolicyOnLogRows(t *testing.T) {
	raw, err := os.ReadFile("testdata/aurora-lab-events.json")
	if err != nil {
		t.Fatal(err)
	}
	var rec []struct {
		S string `json:"s"`
		T int64  `json:"t"`
		M string `json:"m"`
	}
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatal(err)
	}
	var evs []cwEvent
	for _, r := range rec {
		evs = append(evs, cwEvent{Stream: r.S, Time: time.UnixMilli(r.T), Message: r.M})
	}
	rows := logRows(evs, "cloudwatch:/g", evs[0].Time, time.UTC, false)
	applyTextPolicy(rows, "normalized")
	literal := regexp.MustCompile(`'|(^|[^A-Za-z0-9_$.])\d`)
	texts := 0
	for _, r := range rows {
		for _, k := range []string{"statement", "detail"} {
			if s, ok := r[k].(string); ok {
				texts++
				if literal.MatchString(s) {
					t.Errorf("%s still carries a literal: %q", k, s)
				}
			}
		}
	}
	if texts == 0 {
		t.Fatal("no text rows in the fixture")
	}
	rows = logRows(evs, "cloudwatch:/g", evs[0].Time, time.UTC, false)
	applyTextPolicy(rows, "none")
	for _, r := range rows {
		if r["statement"] != nil || r["detail"] != nil {
			t.Errorf("none kept text: %v", r)
		}
	}
	if !strings.Contains(normalizeSQL("Process 1092: begin; update pgvigil_proof_7090 set v = 1"), "pgvigil_proof_7090") {
		t.Error("an identifier with digits must stay whole")
	}
}
