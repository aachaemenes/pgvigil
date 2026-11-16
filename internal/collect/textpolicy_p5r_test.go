package collect

import (
	"encoding/xml"
	"errors"
	"io"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"
	"unsafe"
)

// The plans under testdata/mssqlplans are copies of the Query Store plans captured for the parameter extractor
// (internal/plans/testdata/mssqlparams on the extractor's branch, made by scripts/capture-mssql-param-plans.sh from a
// scratch SQL Server 2022 16.0.4325.4 container; the same bytes): the capture script's own statements, its own fake
// password 'hunter2' - no client text.
//   - p5r: SELECT ... WHERE name = @password OPTION (RECOMPILE) - the value is compiled into the plan as a constant
//     (ScalarString and ConstValue); the plan has no ParameterList to name it;
//   - p5:  the same statement without RECOMPILE - the value sits in the ParameterList's ParameterCompiledValue;
//   - p2:  SELECT ... WHERE id = @i OPTION (RECOMPILE) - no credential, the constant (42).

func readPlanFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile("testdata/mssqlplans/" + name + ".sqlplan")
	if err != nil {
		t.Fatalf("the captured plan %s: %v", name, err)
	}
	return string(b)
}

// wellFormed: every token of the document reads as XML.
func wellFormed(t *testing.T, what, doc string) {
	t.Helper()
	d := xml.NewDecoder(strings.NewReader(doc))
	for {
		_, err := d.Token()
		if errors.Is(err, io.EOF) {
			return
		}
		if err != nil {
			t.Errorf("%s: the masked document is no longer XML: %v", what, err)
			return
		}
	}
}

// TestMaskXMLRecompileCredential: a statement whose text names a credential-named @parameter that its plan lists in no
// ParameterList (OPTION (RECOMPILE) compiles the value into the plan) has every literal of its expression attributes
// (ScalarString, ConstValue, Expression) masked in the stored plan; p5, whose parameter is listed, changes only in its
// ParameterList value (masked as before: its expressions read [@password] and hold no literal); a plan with no
// credential keeps every byte; the document stays XML and a second pass changes nothing.
func TestMaskXMLRecompileCredential(t *testing.T) {
	const secret, value, maskedLit = "hunter2", "N&apos;hunter2&apos;", "&apos;&lt;masked&gt;&apos;"

	p5r := readPlanFixture(t, "p5r")
	if strings.Count(p5r, secret) != 2 || strings.Contains(p5r, "<ParameterList") {
		t.Fatalf("p5r is not the capture this row reads (the value twice, no ParameterList): the row tests nothing")
	}
	got := MaskXML(p5r)
	if strings.Contains(got, secret) {
		t.Errorf("p5r: the stored (masked) plan still holds the value compiled under RECOMPILE")
	}
	if want := strings.ReplaceAll(p5r, value, maskedLit); got != want {
		t.Errorf("p5r: the mask changed more or less than the two constants' values:\n got %q\nwant %q", got, want)
	}
	wellFormed(t, "p5r", got)
	if again := MaskXML(got); again != got {
		t.Errorf("p5r: a second pass changed the text")
	}

	p5 := readPlanFixture(t, "p5")
	if want := strings.ReplaceAll(p5, `ParameterCompiledValue="`+value+`"`, `ParameterCompiledValue="`+maskedLit+`"`); MaskXML(p5) != want {
		t.Errorf("p5 (the parameter listed): only its ParameterCompiledValue is masked, every other byte kept:\n got %q", MaskXML(p5))
	}

	p2 := readPlanFixture(t, "p2")
	if got := MaskXML(p2); got != p2 {
		t.Errorf("p2 (no credential): the mask changed it:\n got %q", got)
	}

	// built rows: a batch of two statements, a numeric secret, a hex value, a conversion warning, a name in another case
	stmt := func(text, body string) string {
		return `<StmtSimple StatementText="` + text + `" StatementId="1" StatementType="SELECT"><QueryPlan>` + body + `</QueryPlan></StmtSimple>`
	}
	op := func(scalar, cnst string) string {
		return `<ScalarOperator ScalarString="` + scalar + `"><Const ConstValue="` + cnst + `" /></ScalarOperator>`
	}
	doc := `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements>` +
		stmt("SELECT a FROM t WHERE pin = @User_PWD OPTION (RECOMPILE)",
			`<Warnings><PlanAffectingConvert ConvertIssue="Seek Plan" Expression="CONVERT_IMPLICIT(int,[t].[pin],0)=(98765)" /></Warnings>`+
				`<RelOp NodeId="0" EstimateRows="1"><IndexScan><Object Table="[t2]" Index="[ix_1]" /><Predicate>`+
				op("[db].[t2].[pin]=(98765) AND [t2].[k]=0x2A00 AND [Expr1003]=N&apos;tok&apos;&apos;s&apos;", "(98765)")+
				`</Predicate></IndexScan></RelOp>`) +
		stmt("SELECT b FROM t WHERE id = @i OPTION (RECOMPILE)", op("[t].[id]=(42) AND [t].[s]=N&apos;keep1&apos;", "(42)")) +
		`</Statements></Batch></BatchSequence></ShowPlanXML>`
	got = MaskXML(doc)
	for _, s := range []string{"98765", "0x2A00", "tok"} {
		if strings.Contains(got, s) {
			t.Errorf("built: %q is still in the credential statement: %q", s, got)
		}
	}
	for _, s := range []string{`ScalarString="[t].[id]=(42) AND [t].[s]=N&apos;keep1&apos;"`, `ConstValue="(42)"`, `[Expr1003]`, `Table="[t2]"`,
		`Index="[ix_1]"`, `EstimateRows="1"`, `StatementText="SELECT a FROM t WHERE pin = @User_PWD OPTION (RECOMPILE)"`} {
		if !strings.Contains(got, s) {
			t.Errorf("built: %s was not kept: %q", s, got)
		}
	}
	if !strings.Contains(got, `ConstValue="(&lt;masked&gt;)"`) || !strings.Contains(got, `[Expr1003]=`+maskedLit) {
		t.Errorf("built: the credential statement's constants not written as masked: %q", got)
	}
	wellFormed(t, "built", got)
	if again := MaskXML(got); again != got {
		t.Errorf("built: a second pass changed the text")
	}

	// a showplan an instruction wraps (sp_WhoIsActive's <?query_plan ... ?>) is masked the same way, byte for byte (the
	// statement pass skips the instruction's raw text: only the plan's own mask inside the wrapper takes the value)
	if got, want := MaskXML("<?query_plan "+p5r+" ?>"), "<?query_plan "+MaskXML(p5r)+" ?>"; got != want {
		t.Errorf("p5r inside <?query_plan ... ?>: not the plan's own mask inside the wrapper:\n got %q\nwant %q", got, want)
	}
}

// TestMaskXMLCredentialRegions: the statement rule's cases one by one (P5R-MASK's review): the credential names come
// from the statement's text BEFORE the tag pass masks it (a column named as its parameter, 'PasswordHash =
// @PasswordHash', leaves no name after it); a statement whose text names a credential parameter has its expression
// literals masked whether or not the parameter is listed (a live plan may carry both); a linked server's RemoteQuery is
// an expression; each statement of a batch, of an IF's branches, is its own region; names keep their digits, every
// number form goes; a comment's, a CDATA section's or an instruction's raw text is not read as tags. Each row: the
// exact output, the secrets gone, still XML, a second pass changes nothing, and inside <?query_plan ... ?> the same.
func TestMaskXMLCredentialRegions(t *testing.T) {
	const (
		head = `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements>`
		tail = `</Statements></Batch></BatchSequence></ShowPlanXML>`
		val  = `N&apos;hunter2&apos;`
		mlit = `&apos;&lt;masked&gt;&apos;`
		mnum = `&lt;masked&gt;`
	)
	// mt is a StatementText as the tag pass writes it (MaskCredentials, escaped where it changed): no row depends on how
	// that older rule writes a pair
	mt := func(text string) string { return xmlAttrEscape(MaskCredentials(text)) }
	stmt := func(text, body string) string {
		return `<StmtSimple StatementText="` + text + `" StatementId="1" StatementType="SELECT"><QueryPlan>` + body + `</QueryPlan></StmtSimple>`
	}
	seek := func(v string) string {
		return `<RelOp NodeId="0" EstimateRows="1"><IndexSeek><SeekPredicates><ScalarOperator ScalarString="` + v + `"><Const ConstValue="` + v +
			`" /></ScalarOperator></SeekPredicates></IndexSeek></RelOp>`
	}
	params := func(v string) string {
		return `<ParameterList><ColumnReference Column="@password" ParameterDataType="nvarchar(50)" ParameterCompiledValue="` + v +
			`" ParameterRuntimeValue="` + v + `" /></ParameterList>`
	}
	update := func(v string) string {
		return `<RelOp NodeId="0" PhysicalOp="Clustered Index Update"><Update><SetPredicate><ScalarOperator ScalarString="[db].[dbo].[u].[PwdHash] = ` + v +
			`" /></SetPredicate></Update></RelOp>`
	}
	pred := func(v string) string {
		return `<RelOp NodeId="1"><Filter><Predicate><ScalarOperator ScalarString="` + v + `" /></Predicate></Filter></RelOp>`
	}
	remote := func(v string) string {
		return `<RelOp NodeId="0" PhysicalOp="Remote Query"><RemoteQuery RemoteQuery="SELECT &quot;Tbl1001&quot;.&quot;id&quot; &quot;Col1003&quot; FROM &quot;db&quot;.&quot;dbo&quot;.&quot;T&quot; &quot;Tbl1001&quot; WHERE &quot;Tbl1001&quot;.&quot;name&quot;=` +
			v + `" RemoteSource="LOOP10" /></RelOp>`
	}
	cond := func(text, c, then, els string) string {
		return `<StmtCond StatementText="` + text + `" StatementId="1" StatementType="COND"><Condition><QueryPlan>` + pred(c) +
			`</QueryPlan></Condition><Then><Statements>` + then + `</Statements></Then><Else><Statements>` + els + `</Statements></Else></StmtCond>`
	}
	const (
		tB1a  = "SELECT id FROM dbo.Users WHERE PasswordHash = @PasswordHash OPTION (RECOMPILE)"
		tB1b  = "UPDATE u SET PwdHash = @PwdHash WHERE id = 7 OPTION (RECOMPILE)"
		tPw   = "SELECT id FROM dbo.T WHERE name = @password OPTION (RECOMPILE)"
		tTwo  = "SELECT id FROM dbo.T WHERE name = @password AND pin = @user_pwd OPTION (RECOMPILE)"
		tI    = "SELECT b FROM t WHERE id = @i OPTION (RECOMPILE)"
		tIf   = "IF @flag = 1"
		tThen = "SELECT a FROM t WHERE code = @pwd OPTION (RECOMPILE)"
		tDig  = "SELECT a FROM #t2 WHERE k = @secret_k OPTION (RECOMPILE)"
		tNum  = "SELECT a FROM t WHERE s = @ApiSecret OPTION (RECOMPILE)"
		tRem  = "SELECT id FROM LOOP10.db.dbo.T WHERE name = @password OPTION (RECOMPILE)"
		raw   = `<!-- <StmtSimple StatementText="SELECT 1 WHERE a = @password"><ScalarOperator ScalarString="N'c0mment'" /> -->` +
			`<![CDATA[<StmtSimple StatementText="x @pwd"><Const ConstValue="(31337)" />]]>` +
			`<?note <StmtSimple StatementText="y @secret"><Const ConstValue="(42424)" /> ?>`
	)
	for _, c := range []struct {
		name, in, want string
		gone           []string
	}{
		{"B1 a column named as its parameter", head + stmt(tB1a, seek(val)) + tail, head + stmt(mt(tB1a), seek(mlit)) + tail, []string{"hunter2"}},
		{"B1 an UPDATE's SetPredicate", head + stmt(tB1b, update(val)) + tail, head + stmt(mt(tB1b), update(mlit)) + tail, []string{"hunter2"}},
		{"H1 listed and compiled in", head + stmt(tPw, seek(val)+params(val)) + tail, head + stmt(mt(tPw), seek(mlit)+params(mlit)) + tail, []string{"hunter2"}},
		{"two credential parameters, one listed", head + stmt(tTwo, seek(val)+pred("[dbo].[T].[pin]=(98765)")+params(val)) + tail,
			head + stmt(mt(tTwo), seek(mlit)+pred("[dbo].[T].[pin]=("+mnum+")")+params(mlit)) + tail, []string{"hunter2", "98765"}},
		{"a statement with no credential first", head + stmt(tI, seek("(42)")) + stmt(tPw, seek(val)) + tail,
			head + stmt(mt(tI), seek("(42)")) + stmt(mt(tPw), seek(mlit)) + tail, []string{"hunter2"}},
		{"an IF's branches", head + cond(tIf, "[@flag]=(1)", stmt(tThen, seek("N&apos;s3cret&apos;")), stmt(tI, seek("(77)"))) + tail,
			head + cond(mt(tIf), "[@flag]=(1)", stmt(mt(tThen), seek(mlit)), stmt(mt(tI), seek("(77)"))) + tail, []string{"s3cret"}},
		{"names keep their digits", head + stmt(tDig, pred("Expr1003=(5) AND [#t2].[a]=@p1 AND Expr1004&gt;=(12.5)")) + tail,
			head + stmt(mt(tDig), pred("Expr1003=("+mnum+") AND [#t2].[a]=@p1 AND Expr1004&gt;=("+mnum+")")) + tail, []string{"12.5"}},
		{"a negative, an exponent, money, a GUID", head + stmt(tNum, pred("[t].[a]=(-5) AND [t].[f]=(1.000000000000000e+003) AND [t].[m]=($5.0000) AND [t].[g]={guid&apos;0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0&apos;}")) + tail,
			head + stmt(mt(tNum), pred("[t].[a]=(-"+mnum+") AND [t].[f]=("+mnum+") AND [t].[m]=($"+mnum+") AND [t].[g]={guid"+mlit+"}")) + tail,
			[]string{"e+003", "5.0000", "0F1E2D3C"}},
		{"M1 a linked server's RemoteQuery", head + stmt(tRem, remote(val)) + tail, head + stmt(mt(tRem), remote(mlit)) + tail, []string{"hunter2"}},
		{"raw text is not read as tags", head + raw + stmt(tI, seek("(42)")) + tail, head + raw + stmt(mt(tI), seek("(42)")) + tail, nil},
	} {
		got := MaskXML(c.in)
		if got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
		for _, s := range c.gone {
			if strings.Contains(got, s) {
				t.Errorf("%s: %q is still there", c.name, s)
			}
		}
		wellFormed(t, c.name, got)
		if again := MaskXML(got); again != got {
			t.Errorf("%s: a second pass changed the text:\n got %q", c.name, again)
		}
		if w, want := MaskXML("<?query_plan "+c.in+" ?>"), "<?query_plan "+got+" ?>"; w != want {
			t.Errorf("%s inside <?query_plan ... ?>:\n got %q\nwant %q", c.name, w, want)
		}
	}
}

// TestMaskPlanCredStatementsNoCopy: a plan the statement pass masks nothing in comes back as the same string, not a
// copy of it (a stored plan is up to 4 MB): p2 names no credential; p5 names one, but its expressions hold no literal.
func TestMaskPlanCredStatementsNoCopy(t *testing.T) {
	for _, name := range []string{"p2", "p5"} {
		in := readPlanFixture(t, name)
		if out := maskPlanCredStatements(in); out != in || unsafe.StringData(out) != unsafe.StringData(in) {
			t.Errorf("%s: masked nothing, yet came back as a copy (%d bytes)", name, len(out))
		}
	}
}

// TestMaskPlanCredStatementsCost: the statement pass over a plan of the largest stored size (qsPlanXMLMaxBytes, 4 MB)
// stays under TestMaskXMLInstructionCost's bars (2 s, 64 MB) when every statement names a credential parameter (every
// region masked) and when none does; the whole MaskXML over the first is measured and logged (the tag pass is
// 415-PI's: its number is read, not judged here).
func TestMaskPlanCredStatementsCost(t *testing.T) {
	const head, tail = `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements>`, `</Statements></Batch></BatchSequence></ShowPlanXML>`
	unit := func(text, v string) string {
		return `<StmtSimple StatementText="` + text + `" StatementId="1" StatementType="SELECT"><QueryPlan><RelOp NodeId="0" EstimateRows="1"><IndexSeek>` +
			`<SeekPredicates><ScalarOperator ScalarString="` + v + `"><Const ConstValue="` + v + `" /></ScalarOperator></SeekPredicates></IndexSeek></RelOp></QueryPlan></StmtSimple>`
	}
	build := func(u string) (string, int) {
		n := (4<<20 - len(head) - len(tail)) / len(u)
		return head + strings.Repeat(u, n) + tail, n
	}
	measure := func(f func() string) (string, time.Duration, uint64) {
		var before, after runtime.MemStats
		runtime.GC()
		runtime.ReadMemStats(&before)
		start := time.Now()
		out := f()
		d := time.Since(start)
		runtime.ReadMemStats(&after)
		return out, d, (after.TotalAlloc - before.TotalAlloc) >> 20
	}
	cred, n := build(unit("SELECT a FROM t WHERE k = @password OPTION (RECOMPILE)", "N&apos;hunter2&apos;"))
	plain, _ := build(unit("SELECT a FROM t WHERE k = @i OPTION (RECOMPILE)", "N&apos;keep1&apos;"))
	for _, c := range []struct {
		name, in string
		masks    int
	}{{"every statement a credential one", cred, 2 * n}, {"no credential statement", plain, 0}} {
		out, d, mb := measure(func() string { return maskPlanCredStatements(c.in) })
		t.Logf("%s: %d bytes, %d statements: %v, %d MB", c.name, len(c.in), n, d, mb)
		if d > 2*time.Second {
			t.Errorf("%s: 4 MB took %v", c.name, d)
		}
		if mb > 64 {
			t.Errorf("%s: %d MB allocated for 4 MB", c.name, mb)
		}
		if got := strings.Count(out, `&apos;&lt;masked&gt;&apos;`); got != c.masks || strings.Contains(out, "hunter2") {
			t.Errorf("%s: %d values masked, want %d (and no value left)", c.name, got, c.masks)
		}
	}
	out, d, mb := measure(func() string { return MaskXML(cred) })
	t.Logf("MaskXML whole over every statement a credential one: %v, %d MB", d, mb)
	if strings.Contains(out, "hunter2") {
		t.Errorf("MaskXML whole: a value is still there")
	}
}
