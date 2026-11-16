package collect

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/logparse"
)

func hexOf(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

// query_text hash (R5): every text key replaced by the hex SHA-256 of its normalized form (a log event's message by its
// shape), query_hash the textHash of the same normalized form - a shape groups across intervals as under normalized;
// a plan's statement is dropped as under every mode but full.
func TestHashModeRewrite(t *testing.T) {
	q := "SELECT * FROM accounts WHERE owner = 'alice' AND id IN (1, 2, 3)"
	rows := []Row{
		{"kind": "session", "query": q, "query_hash": int64(42)},
		{"kind": "event", "message": "connection authorized: user=alice database=app", "statement": "UPDATE t SET v = 7 WHERE id = 9"},
		{"kind": "error", "detail": "Key (email)=(alice@example.com) already exists.", "statement": "INSERT INTO u VALUES ('alice@example.com')"},
		{"kind": "plan_xml", "kind_of": "plan", "statement": "<ShowPlanXML/>"},
	}
	applyTextPolicy(rows, "hash")
	n := normalizeSQL(q)
	if rows[0]["query"] != hexOf(n) || rows[0]["query_hash"] != textHash(n) {
		t.Errorf("query: %v / %v, want %s / %d", rows[0]["query"], rows[0]["query_hash"], hexOf(n), textHash(n))
	}
	if rows[1]["message"] != hexOf(logparse.MessageShape("connection authorized: user=alice database=app")) {
		t.Errorf("an event's message: %v", rows[1]["message"])
	}
	for i, k := range []string{"statement", "detail"} {
		for _, r := range rows[1:3] {
			if v, ok := r[k]; ok && !hex64.MatchString(v.(string)) {
				t.Errorf("%d %s: %v", i, k, v)
			}
		}
	}
	if rows[3]["statement"] != nil {
		t.Errorf("a plan's statement: %v", rows[3]["statement"])
	}
	for _, r := range rows {
		for k, v := range r {
			if s, ok := v.(string); ok && (strings.Contains(s, "alice") || strings.Contains(s, "accounts")) {
				t.Errorf("text left in %s: %q", k, s)
			}
		}
	}
}

// RemoteDeny (R5, deny by default): a view's listed string fields pass as they are; every other string - nested in a
// list or an object too - is the hex SHA-256 of its normalized form under hash (a value already in that form stays) and
// NULL under none; numbers, booleans and times pass; a view with no list is refused in words.
func TestRemoteDeny(t *testing.T) {
	rows := []map[string]any{{
		"kind": "job", "name": "nightly", "job_id": "0x1F", "enabled": int64(1),
		"steps":       []any{map[string]any{"command": "EXEC dbo.purge @before = '2026-01-01'"}},
		"description": "keeps 30 days",
		"unknown":     "DELETE FROM secrets WHERE k = 'x'",
		"hashed":      hexOf("already"),
	}}
	if err := RemoteDeny("mssql_jobs", rows, "hash"); err != nil {
		t.Fatal(err)
	}
	r := rows[0]
	if r["kind"] != "job" || r["name"] != "nightly" || r["job_id"] != "0x1F" || r["enabled"] != int64(1) {
		t.Errorf("listed fields changed: %v", r)
	}
	if r["unknown"] != hexOf(normalizeSQL("DELETE FROM secrets WHERE k = 'x'")) || r["hashed"] != hexOf("already") {
		t.Errorf("an unlisted field: %v / %v", r["unknown"], r["hashed"])
	}
	if s, ok := r["steps"].(string); !ok || !hex64.MatchString(s) {
		t.Errorf("an unlisted list: %v", r["steps"])
	}
	none := []map[string]any{{"kind": "job", "name": "nightly", "unknown": "DELETE FROM secrets", "n": 3}}
	if err := RemoteDeny("mssql_jobs", none, "none"); err != nil {
		t.Fatal(err)
	}
	if none[0]["unknown"] != nil || none[0]["name"] != "nightly" || none[0]["n"] != 3 {
		t.Errorf("none: %v", none[0])
	}
	if err := RemoteDeny("no_such_view", rows, "hash"); err == nil || !strings.Contains(err.Error(), "no remote text list") {
		t.Errorf("a view with no list: %v", err)
	}
	if err := RemoteDeny("mssql_jobs", rows, "full"); err == nil {
		t.Errorf("mode full on a remote collector: no error")
	}
	for _, k := range []string{"query", "statement", "message", "detail", "definition", "script", "command"} {
		if RemotePasses("mssql_jobs", k) && k != "command" {
			t.Errorf("mssql_jobs passes the text key %s", k)
		}
	}
	if RemotePasses("mssql_jobs", "command") || !RemotePasses("mssql_requests", "command") {
		t.Errorf("command: a job step's text is hashed, a request's command tag passes")
	}
}
