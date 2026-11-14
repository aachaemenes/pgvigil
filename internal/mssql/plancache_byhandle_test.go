package mssql

import (
	"bytes"
	"encoding/xml"
	"strings"
	"testing"
)

// A cached plan read on demand by its handle (task 406): the handle's form and what each answer of the server is
// called. The reads themselves are proven against SQL Server by scripts/proof-mssql-qs-plans.sh.

func TestParsePlanHandle(t *testing.T) {
	b, err := ParsePlanHandle("0x0600050012ab")
	if err != nil || !bytes.Equal(b, []byte{0x06, 0x00, 0x05, 0x00, 0x12, 0xab}) {
		t.Fatalf("ParsePlanHandle = %x, %v", b, err)
	}
	if b, err := ParsePlanHandle(" 0XAbCd "); err != nil || !bytes.Equal(b, []byte{0xab, 0xcd}) {
		t.Errorf("upper 0X and spaces: %x, %v", b, err)
	}
	for _, bad := range []string{"", "0x", "0x1", "0x123", "abcd", "0xzz", "0x" + strings.Repeat("00", 65), "0x00;DROP", "0x00 00"} {
		if _, err := ParsePlanHandle(bad); err == nil {
			t.Errorf("ParsePlanHandle(%q) took it", bad)
		}
	}
	if _, err := ParsePlanHandle("0x" + strings.Repeat("ff", 64)); err != nil {
		t.Errorf("a 64-byte handle refused: %v", err)
	}
}

func TestPlanState(t *testing.T) {
	plan := `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements>` +
		`<StmtSimple StatementText="SELECT 1" QueryHash="0x1111" QueryPlanHash="0xab12CD"><QueryPlan CachedPlanSize="16"/></StmtSimple>` +
		`</Statements></Batch></BatchSequence></ShowPlanXML>`
	shell := `<ShowPlanXML><BatchSequence><Batch><Statements><StmtSimple StatementText="select * from t where a = 1" ParameterizedPlanHandle="0x06" ParameterizedText="(@1 tinyint)select * from t where a = @1"/></Statements></Batch></BatchSequence></ShowPlanXML>`
	for _, c := range []struct {
		name      string
		enc       bool
		size      int64
		has       bool
		xml, want string
		state     string
		hash      string
		withXML   bool
	}{
		{"ok", false, 400, true, plan, "", "ok", "0xAB12CD", true},
		{"ok, the hash compared in any case", false, 400, true, plan, "0xAB12cd", "ok", "0xAB12CD", true},
		{"changed", false, 400, true, plan, "0x99", "changed", "0xAB12CD", true},
		{"encrypted", true, 0, false, "", "", "encrypted", "", false},
		{"too large", false, PlanByHandleMaxBytes + 1, false, "", "", "too_large", "", false},
		{"NULL", false, 0, false, "", "", "no_plan", "", false},
		{"parameterized shell", false, 300, true, shell, "", "parameterized", "", false},
		{"no QueryPlan, no shell", false, 100, true, `<ShowPlanXML><BatchSequence/></ShowPlanXML>`, "", "no_plan", "", false},
	} {
		state, words, hash, out := planState(c.enc, c.size, c.has, c.xml, c.want)
		if state != c.state || hash != c.hash || (out != "") != c.withXML || words == "" {
			t.Errorf("%s: state %q hash %q xml %v words %q; want %q %q %v", c.name, state, hash, out != "", words, c.state, c.hash, c.withXML)
		}
	}
	if _, w, _, _ := planState(false, 400, true, plan, "0x99"); !strings.Contains(w, "0xAB12CD") || !strings.Contains(w, "0X99") {
		t.Errorf("the changed words name both hashes: %q", w)
	}
}

// The running plans' threshold (DBA Dash 4.25.0's defaults, each alone), the live plan's picks and its build gate.
func TestGroupRunning(t *testing.T) {
	req := func(h, ph string, start, cpu, grant, running int64) runningReq {
		return runningReq{session: 60 + start, request: 0, handle: h, qhash: "0x01", phash: ph, start: start, end: -1, cpu: cpu, grant: grant, running: running}
	}
	cases := []struct {
		name string
		reqs []runningReq
		want string // the first group's reasons, "" = not kept
	}{
		{"CPU alone", []runningReq{req("0xAA", "0x10", 0, 1000, 0, 2000)}, "cpu"},
		{"CPU just under", []runningReq{req("0xAA", "0x10", 0, 999, 0, 2000)}, ""},
		{"grant alone", []runningReq{req("0xAA", "0x10", 0, 10, 6400, 2000)}, "grant"},
		{"grant just under", []runningReq{req("0xAA", "0x10", 0, 10, 6399, 2000)}, ""},
		{"two requests on one plan", []runningReq{req("0xAA", "0x10", 0, 10, 0, 100), req("0xAA", "0x10", 0, 10, 0, 100)}, "count"},
		{"duration alone", []runningReq{req("0xAA", "0x10", 0, 10, 0, 10000)}, "duration"},
		{"duration just under", []runningReq{req("0xAA", "0x10", 0, 10, 0, 9999)}, ""},
		{"CPU summed over the group", []runningReq{req("0xAA", "0x10", 0, 600, 0, 100), req("0xAA", "0x10", 0, 600, 0, 100)}, "cpu,count"},
	}
	for _, c := range cases {
		g := groupRunning(c.reqs)
		got := ""
		if len(g) > 0 && g[0].meets {
			got = strings.Join(g[0].reasons, ",")
		}
		if got != c.want {
			t.Errorf("%s: reasons %q, want %q", c.name, got, c.want)
		}
	}
	// other offsets or another plan hash are another group; a zero plan hash is no group
	g := groupRunning([]runningReq{req("0xAA", "0x10", 0, 10, 0, 100), req("0xAA", "0x10", 50, 10, 0, 100), req("0xAA", "0x11", 0, 10, 0, 100), req("0xAA", "0x0000000000000000", 0, 5000, 0, 100)})
	if len(g) != 3 {
		t.Errorf("groups %d, want 3 (offsets and plan hash apart, the zero hash left out)", len(g))
	}
}

func TestLivePicks(t *testing.T) {
	var reqs []runningReq
	for i := int64(0); i < 12; i++ { // twelve over the CPU line on one plan: the ten with the most CPU
		reqs = append(reqs, runningReq{session: 100 + i, handle: "0xAA", qhash: "0x01", phash: "0x10", end: -1, cpu: 60000 + i, running: 1000})
	}
	reqs = append(reqs,
		runningReq{session: 200, handle: "0xBB", qhash: "0x02", phash: "0x20", end: -1, cpu: 5, running: 300000, blocked: true},  // running long but blocked
		runningReq{session: 201, handle: "0xBC", qhash: "0x03", phash: "0x30", end: -1, cpu: 5, running: 300000, blocked: false}, // running long, not blocked
		runningReq{session: 202, handle: "0xBD", qhash: "0x04", phash: "0x40", end: -1, cpu: 59999, running: 9000})               // under both lines
	p := livePicks(reqs)
	if len(p) != livePlanMax || p[0].session != 111 || p[9].session != 102 {
		t.Fatalf("picks %d, first %d, last %d; want %d, 111, 102", len(p), p[0].session, p[len(p)-1].session, livePlanMax)
	}
	short := livePicks(reqs[12:])
	if len(short) != 1 || short[0].session != 201 {
		t.Errorf("of the three others only the unblocked long runner: %+v", short)
	}
}

func TestLivePlanBuildOK(t *testing.T) {
	for _, c := range []struct {
		info Info
		ok   bool
	}{
		{Info{Kind: KindServer, Major: 13, Build: 4000, ProductVersion: "13.0.4000.0"}, false}, // 2016 before SP1
		{Info{Kind: KindServer, Major: 13, Build: 4001, ProductVersion: "13.0.4001.0"}, true},  // 2016 SP1
		{Info{Kind: KindServer, Major: 14, Build: 3410, ProductVersion: "14.0.3410.1"}, false}, // 2017 before CU26
		{Info{Kind: KindServer, Major: 14, Build: 3411, ProductVersion: "14.0.3411.3"}, true},  // 2017 CU26
		{Info{Kind: KindServer, Major: 15, Build: 4152, ProductVersion: "15.0.4152.1"}, false}, // 2019 before CU12
		{Info{Kind: KindServer, Major: 15, Build: 4153, ProductVersion: "15.0.4153.1"}, true},  // 2019 CU12
		{Info{Kind: KindServer, Major: 16, Build: 1000, ProductVersion: "16.0.1000.6"}, true},  // 2022 RTM
		{Info{Kind: KindRDS, Major: 15, Build: 4100}, false},
		{Info{Kind: KindAzureMI, Major: 12}, true},
		{Info{Kind: KindAzureDB, Major: 12}, true},
		{Info{Kind: KindServer, Major: 12, Build: 6000}, false}, // 2014
	} {
		ok, why := LivePlanBuildOK(c.info)
		if ok != c.ok || (!ok && why == "") {
			t.Errorf("%+v: %v %q, want %v", c.info, ok, why, c.ok)
		}
	}
}

// TestMaskPlanXML: a showplan writes a literal's quotes as &apos; (SQL Server's XML), so the T-SQL password forms are
// masked on the decoded quotes, and the mask's angle brackets go back as entities: the file stays XML.
func TestMaskPlanXML(t *testing.T) {
	in := `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements>` +
		`<StmtSimple StatementText="SELECT /* PASSWORD = &apos;s3cretA&apos; */ COUNT(*) FROM t WHERE @pwd = N&apos;s3cretB&apos; AND a = &apos;it&apos;&apos;s&apos;" QueryPlanHash="0x01">` +
		`<QueryPlan><ParameterList><ColumnReference Column="@pwd" ParameterCompiledValue="N's3cretC'"/></ParameterList></QueryPlan></StmtSimple>` +
		`</Statements></Batch></BatchSequence></ShowPlanXML>`
	out := MaskPlanXML(in)
	for _, s := range []string{"s3cretA", "s3cretB"} {
		if strings.Contains(out, s) {
			t.Errorf("%s kept: %s", s, out)
		}
	}
	if !strings.Contains(out, "&lt;masked&gt;") || strings.Contains(out, "<masked>") {
		t.Errorf("the mask is not written as entities: %s", out)
	}
	if !strings.Contains(out, "it&apos;&apos;s") {
		t.Errorf("a literal that is no password changed: %s", out)
	}
	if err := xml.Unmarshal([]byte(out), new(struct{})); err != nil {
		t.Errorf("the masked plan is not XML: %v\n%s", err, out)
	}
	if got := MaskPlanXML(""); got != "" {
		t.Errorf("empty: %q", got)
	}
}
