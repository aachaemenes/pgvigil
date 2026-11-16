package collect

import (
	"encoding/xml"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
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
// (ScalarString, ConstValue, Expression) masked in the stored plan; a statement whose parameter is listed keeps its
// constants (the ParameterList value is masked as before); a plan with no credential keeps every byte; the document
// stays XML and a second pass changes nothing.
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

	// a showplan an instruction wraps (sp_WhoIsActive's <?query_plan ... ?>) is masked the same way
	if got := MaskXML("<?query_plan " + p5r + " ?>"); strings.Contains(got, secret) {
		t.Errorf("p5r inside <?query_plan ... ?>: the value is still there")
	}
}
