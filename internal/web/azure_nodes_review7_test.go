package web

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// TestAzureNodesReview7Requests (review t11-7's fold, P25 (i) the node tabs; no store needed - each answer comes before
// any read):
//   - 6: /api/azuredb/summary binds ids= (sqlAzureScope's $5, the node's own cut): a malformed list is refused;
//   - 11: /api/mssql/procs with instances= - over the 500-database cap, or without part=objects - is refused.
func TestAzureNodesReview7Requests(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	// a handler that reaches the store (there is none here) panics: read as code 0, so a missing check fails cleanly
	code := func(h func(http.ResponseWriter, *http.Request), path string) (c int, body string) {
		defer func() {
			if recover() != nil {
				c, body = 0, "reached the store"
			}
		}()
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path, nil))
		return rec.Code, rec.Body.String()
	}
	if c, body := code(s.AzureDBSummary, "/api/azuredb/summary?ids=1,x"); c != http.StatusBadRequest || !strings.Contains(body, "ids") {
		t.Errorf("summary ids=1,x: %d %s, want 400 naming ids", c, body)
	}
	many := make([]string, 501)
	for i := range many {
		many[i] = "1"
	}
	if c, _ := code(s.MSSQLProcs, "/api/mssql/procs?part=objects&instances="+strings.Join(many, ",")); c != http.StatusBadRequest {
		t.Errorf("procs instances= of 501 ids: %d, want 400 (the 500-database cap)", c)
	}
	if c, _ := code(s.MSSQLProcs, "/api/mssql/procs?instances=1,2"); c != http.StatusBadRequest {
		t.Errorf("procs instances= without part=objects: %d, want 400", c)
	}
}

// TestAzureNodesReview7Page (review t11-7's fold): the node page -
//   - 3: a failed Azure Summary tab is an error box under the strip, never the whole page;
//   - 9: the node is azuredb.ts' AzureNode (no local Node shadowing the DOM's);
//   - 7: under a tag folder the empty words name the folder;
//   - 4: Slow Queries says it is the fleet's top 500 statement groups cut to the node;
//   - 5: Alerts says what is in view (the node's databases and the repository's own, its channels and mutes the whole
//     repository's);
//   - 2: Object Execution says the 500-database cap when the node holds more.
func TestAzureNodesReview7Page(t *testing.T) {
	b, err := os.ReadFile("../../web/src/azure_nodes.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, want := range []string{"import { AzureNode, azureSummaryView }", "catch (e) { return el('section', {}, el('h2', {}, name), strip, errorBox(e)); }",
		"folderWords(ctx.tag)", "the fleet's top 500", "In view:", "ids.length > 500"} {
		if !strings.Contains(src, want) {
			t.Errorf("azure_nodes.ts lacks %q", want)
		}
	}
	if strings.Contains(src, "interface Node ") {
		t.Error("azure_nodes.ts still declares its own Node (it shadows the DOM's)")
	}
}
