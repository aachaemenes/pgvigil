package actions

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestValidateExplain(t *testing.T) {
	ok := ExplainRequest{Instance: "i1", Statement: "select * from t where id = 5;", Reason: "slow report", User: "dba"}
	if err := ValidateExplain(ok); err != nil {
		t.Fatalf("a plain select refused: %v", err)
	}
	cases := map[string]func(r *ExplainRequest){
		"no statement":         func(r *ExplainRequest) { r.Statement = "  " },
		"is not executed":      func(r *ExplainRequest) { r.Statement = "delete from t" },
		"more than one":        func(r *ExplainRequest) { r.Statement = "select 1; delete from t" },
		"$n parameters":        func(r *ExplainRequest) { r.Statement = "select * from t where id = $1" },
		"a reason of at least": func(r *ExplainRequest) { r.Reason = "x" },
		"no UI user":           func(r *ExplainRequest) { r.User = "" },
		"NUL":                  func(r *ExplainRequest) { r.Statement = "select 1\x00" },
		"cannot be explained":  func(r *ExplainRequest) { r.Statement = "vacuum t" },
	}
	for want, f := range cases {
		r := ok
		f(&r)
		if err := ValidateExplain(r); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v", want, err)
		}
	}
}

// The gate and the door refuse before any connection is made (the dsns here point nowhere).
func TestExplainAnalyzeRefusals(t *testing.T) {
	r := ExplainRequest{Instance: "i1", Statement: "select 1", Reason: "check the plan", User: "dba"}
	d := Door{Monitor: "host=192.0.2.1 connect_timeout=1", Actions: "host=192.0.2.1 connect_timeout=1", Configured: true}
	res, row := ExplainAnalyze(context.Background(), d, ExplainGate{}, r)
	if res.Outcome != Refused || !strings.Contains(res.Detail, "off on instance i1") || row != nil {
		t.Errorf("gate off: %+v", res)
	}
	res, _ = ExplainAnalyze(context.Background(), Door{Monitor: "x"}, ExplainGate{Enabled: true}, r)
	if res.Outcome != Refused || !strings.Contains(res.Detail, "no explain_dsn") {
		t.Errorf("no explain login: %+v", res)
	}
	res, _ = ExplainAnalyze(context.Background(), Door{Monitor: "x"}, ExplainGate{Enabled: true, Configured: true}, r)
	if res.Outcome != Refused || !strings.Contains(res.Detail, "resolved to an empty string") {
		t.Errorf("explain_dsn unresolved: %+v", res)
	}
	r.Statement = "update t set v = 1"
	res, _ = ExplainAnalyze(context.Background(), d, ExplainGate{Enabled: true, DSN: "host=192.0.2.1 connect_timeout=1"}, r)
	if res.Outcome != Refused || !strings.Contains(res.Detail, "SELECT statements only") {
		t.Errorf("update: %+v", res)
	}
}

func TestExplainGateTimeout(t *testing.T) {
	if (ExplainGate{}).TimeoutOrDefault() != DefaultExplainTimeout || (ExplainGate{Timeout: time.Hour}).TimeoutOrDefault() != MaxExplainTimeout ||
		(ExplainGate{Timeout: 5 * time.Second}).TimeoutOrDefault() != 5*time.Second {
		t.Error("timeout bounds")
	}
}

func TestExplainRow(t *testing.T) {
	at := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	row := ExplainRow(at, ExplainRequest{Instance: "i1", Datname: "app", Statement: " select 1 ", Reason: "  why not  ", User: "dba", Client: "10.0.0.1"},
		Result{Outcome: Refused, Detail: "off"})
	j, _ := json.Marshal([]ExplainLogRow{row})
	var got []map[string]any
	_ = json.Unmarshal(j, &got)
	g := got[0]
	if g["action"] != "explain_analyze" || g["pid"] != float64(0) || g["backend_start"] != nil || g["datname"] != "app" || g["statement"] != "select 1" ||
		g["reason"] != "why not" || g["outcome"] != "refused" || g["instance_name"] != "i1" {
		t.Errorf("row %v", g)
	}
}
