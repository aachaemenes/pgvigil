package collect

import "testing"

func TestNormalizeSQL(t *testing.T) {
	cases := []struct{ in, want string }{
		{"SELECT * FROM t1 WHERE id = 42 AND name = 'bob'", "SELECT * FROM t1 WHERE id = ? AND name = ?"},
		{"select col2, 3.5e10 from s.t2 where x in (1, 2,3) and y = $1", "select col2, ? from s.t2 where x in (?) and y = $1"},
		{"insert into a values (E'it''s', 'o''k', -7)", "insert into a values (?, ?, ?)"},
		{"do $body$ begin perform 1; end $body$; select $$raw 'x'$$", "do ?; select ?"},
		{"ALTER ROLE app PASSWORD '<masked>' VALID UNTIL '2030-01-01'", "ALTER ROLE app PASSWORD ? VALID UNTIL ?"},
		{"select   *\n  from  t\twhere a = 1  ", "select * from t where a = ?"},
		{"select ts - interval '1 day', 0.5 * price, ip = '10.0.0.1'::inet from o", "select ts - interval ?, ? * price, ip = ?::inet from o"},
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
			{"kind": "event", "statement": "update t set a = 2", "detail": "Process 10: delete from t where id = 3", "pid": 10},
			{"kind": "summary", "total": 3},
			{"kind": "session", "query": nil},
		}
	}
	rows := mk()
	applyTextPolicy(rows, "full")
	if rows[0]["query"] != "select 1 from t where k = 'v'" {
		t.Errorf("full changed the text: %v", rows[0]["query"])
	}
	rows = mk()
	applyTextPolicy(rows, "")
	if rows[1]["statement"] != "update t set a = 2" {
		t.Errorf("an empty mode is full: %v", rows[1]["statement"])
	}
	rows = mk()
	applyTextPolicy(rows, "normalized")
	if rows[0]["query"] != "select ? from t where k = ?" || rows[1]["statement"] != "update t set a = ?" || rows[1]["detail"] != "Process ?: delete from t where id = ?" {
		t.Errorf("normalized: %v | %v | %v", rows[0]["query"], rows[1]["statement"], rows[1]["detail"])
	}
	if rows[0]["query_hash"] != int64(7) || rows[1]["pid"] != 10 || rows[2]["total"] != 3 {
		t.Error("a non-text column changed")
	}
	rows = mk()
	applyTextPolicy(rows, "none")
	if rows[0]["query"] != nil || rows[1]["statement"] != nil || rows[1]["detail"] != nil {
		t.Errorf("none kept text: %v | %v | %v", rows[0]["query"], rows[1]["statement"], rows[1]["detail"])
	}
	if _, ok := rows[0]["query"]; !ok {
		t.Error("none should keep the column with a nil value, not drop it")
	}
}
