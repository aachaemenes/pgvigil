package demo

import (
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/logparse"
)

// TestDemoErrorsParse: each demo error, written as a server log would write it, is read by logparse into the kind,
// level, message shape, detail and statement the demo stores for it, so the demo's groups are a real log's groups.
func TestDemoErrorsParse(t *testing.T) {
	for _, e := range demoErrors {
		raw, detailLine, stmt := e.render(123456)
		head := "2026-11-10 10:03:00 UTC:10.0.0.5(40001):app_erp@erp:[1001]:"
		lines := head + e.level + ":  " + raw + "\n"
		if detailLine != "" {
			lines += head + "DETAIL:  " + detailLine + "\n"
		}
		lines += head + "STATEMENT:  " + stmt + "\n"
		evs, err := logparse.ParseIn(strings.NewReader(lines), time.UTC)
		if err != nil || len(evs) != 1 {
			t.Fatalf("%q: %d events, err %v", raw, len(evs), err)
		}
		ev := evs[0]
		wantDetail := raw
		if detailLine != "" && e.kind == "error" {
			wantDetail = raw + "\nDETAIL: " + detailLine
		}
		if string(ev.Kind) != e.kind || ev.Level != e.level || ev.Message != logparse.MessageShape(raw) || ev.Detail != wantDetail || ev.Statement != stmt {
			t.Errorf("%q: parsed %s/%s/%q detail %q stmt %q; the demo stores %s/%s/%q detail %q stmt %q",
				raw, ev.Kind, ev.Level, ev.Message, ev.Detail, ev.Statement, e.kind, e.level, logparse.MessageShape(raw), wantDetail, stmt)
		}
	}
}
