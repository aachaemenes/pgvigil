package mssql

import (
	"encoding/xml"
	"errors"
	"io"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// TestStoredXMLStaysXML: an XML document a SQL Server collection stores - a showplan (Query Store, the running and the
// live plans: MaskPlanXML, then the query_text policy in RunOnce), an Extended Events deadlock graph and a blocked
// process report (the policy alone) - is still XML after the credential mask, under the policy 'full', and holds no
// secret. The mask writes '<masked>' escaped inside a document ('&lt;masked&gt;'), as MaskPlanXML does; a document
// with no credential keeps its bytes.
func TestStoredXMLStaysXML(t *testing.T) {
	const ns = `<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564" Build="16.0.4325.4"><BatchSequence><Batch><Statements>`
	const end = `</Statements></Batch></BatchSequence></ShowPlanXML>`
	cases := []struct {
		name, key, kindOf, in, secret string
		masked                        bool
	}{
		{"plan, a password-named parameter", "statement", "plan", ns +
			`<StmtSimple StatementText="SELECT name FROM dbo.users WHERE pwd_hash = HASHBYTES(&apos;SHA2_256&apos;, @password)" StatementType="SELECT"><QueryPlan><ParameterList>` +
			`<ColumnReference Column="@password" ParameterDataType="nvarchar(50)" ParameterCompiledValue="N&apos;Px1secret&apos;" ParameterRuntimeValue="N&apos;Px2secret&apos;" />` +
			`</ParameterList></QueryPlan></StmtSimple>` + end, "secret", true},
		{"plan, a password pair in the statement", "statement", "plan", ns +
			`<StmtSimple StatementText="UPDATE dbo.users SET PasswordHash = @h WHERE id = @id; ALTER LOGIN app WITH PASSWORD = &apos;Px3secret&apos;" StatementType="UPDATE"><QueryPlan /></StmtSimple>` + end, "secret", true},
		{"plan, no credential", "statement", "plan", ns +
			`<StmtSimple StatementText="SELECT id FROM dbo.t WHERE v = N&apos;x&apos;" StatementType="SELECT"><QueryPlan><ParameterList>` +
			`<ColumnReference Column="@v" ParameterDataType="int" ParameterCompiledValue="(5)" /></ParameterList></QueryPlan></StmtSimple>` + end, "", false},
		{"deadlock graph, an input buffer", "graph", "", `<deadlock><victim-list><victimProcess id="process1" /></victim-list><process-list>` +
			`<process id="process1" spid="55"><executionStack><frame procname="adhoc" line="1">UPDATE dbo.t SET v = 1</frame></executionStack>` +
			"<inputbuf>\nEXEC xp_cmdshell &apos;sqlcmd -S . -U sa -P Dg1secret -Q &quot;select 1&quot;&apos;;\nSELECT * FROM OPENROWSET(&apos;MSOLEDBSQL&apos;, &apos;Server=x;UID=sa;PWD=Dg2secret;&apos;, &apos;SELECT 1&apos;)   </inputbuf>" +
			`</process></process-list><resource-list /></deadlock>`, "secret", true},
		{"blocked process report", "report", "", `<blocked-process-report monitorLoop="12"><blocked-process><process id="p1" spid="57" waitresource="KEY: 5:1 (8194443284a0)">` +
			"<inputbuf>\nEXEC xp_cmdshell &apos;sqlcmd -S . -U sa -P Bp1secret -Q x&apos;   </inputbuf></process></blocked-process>" +
			`<blocking-process><process spid="56"><inputbuf>UPDATE dbo.t SET v = v + 1</inputbuf></process></blocking-process></blocked-process-report>`, "secret", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			v := c.in
			if c.key == "statement" {
				v = MaskPlanXML(v) // what querystore.go and plancache.go store
			}
			row := collect.Row{c.key: v}
			if c.kindOf != "" {
				row["kind_of"] = c.kindOf
			}
			collect.ApplyTextPolicy([]collect.Row{row}, "full")
			got, _ := row[c.key].(string)
			if err := wellFormed(got); err != nil {
				t.Fatalf("not XML after the mask: %v\n%s", err, got)
			}
			if c.secret != "" && strings.Contains(got, c.secret) {
				t.Fatalf("a secret is stored:\n%s", got)
			}
			if c.masked != strings.Contains(got, "&lt;masked&gt;") {
				t.Fatalf("masked %v, want %v:\n%s", !c.masked, c.masked, got)
			}
			if !c.masked && got != c.in {
				t.Fatalf("a document with no credential changed:\n%s\nwant\n%s", got, c.in)
			}
		})
	}
}

// wellFormed reads s to its end as XML (every token; no DTD).
func wellFormed(s string) error {
	d := xml.NewDecoder(strings.NewReader(s))
	for {
		_, err := d.Token()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}
