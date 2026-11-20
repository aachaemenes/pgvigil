package collect

// Task A26-PG's tests that use only what the code before it already had (schemaFinish, schemaFinishMode, Row,
// SchemaBodyWithheld), so the red-first step runs this file on the code before it: TestSchemaHashPinned must PASS there
// (its constant IS that code's hash), TestSchemaHashPrev must FAIL there (no hash_prev).

import (
	"strings"
	"testing"
)

// schemaPinnedHash is the hash the schemaFinish that read no SQL-standard body gives schemaPinnedRow(""): an
// SQL-standard function as that code read it (prosrc is empty). Computed from that code's recipe (kind, the definition + ' body sha256:' +
// the first 16 hex of sha256(body), owner, ACL, each followed by a zero byte).
const (
	schemaPinnedHash    = "a1079d81733eeebff468f7476dc5d5b989105426fc91840242a825030489596b"
	schemaPinnedDefHash = "1ec39bc563f92f03bbd8fe26c01d6c8750d39ff2d7450bd4fd22c0635701ad08"
	schemaPinnedDef     = "function (a integer) returns integer language sql volatile cost 100"
)

func schemaPinnedRow(body string) Row {
	return Row{"kind": "obj", "object_kind": "function", "identity": "public.f(integer)", "owner": "app", "acl": "",
		"definition": schemaPinnedDef, "body": body}
}

// TestSchemaHashPinned: the old recipe's bytes for an empty body, kept by every later change of the hash code.
func TestSchemaHashPinned(t *testing.T) {
	r := schemaPinnedRow("")
	schemaFinish([]Row{r})
	if r["hash"] != schemaPinnedHash {
		t.Errorf("hash %v, want the pinned %s", r["hash"], schemaPinnedHash)
	}
	if r["def_hash"] != schemaPinnedDefHash {
		t.Errorf("def_hash %v, want the pinned %s", r["def_hash"], schemaPinnedDefHash)
	}
	if want := schemaPinnedDef + " body sha256:e3b0c44298fc1c14"; r["definition"] != want {
		t.Errorf("definition %q, want %q", r["definition"], want)
	}
}

// TestSchemaHashPrev: beside an SQL-standard body (body_prev present), hash_prev is the old code's hash of the same row
// under every policy, the new hash differs, body_prev leaves the row; a string body carries no hash_prev;
// under full the stored text is the deparsed body. Before the fix there was no hash_prev.
func TestSchemaHashPrev(t *testing.T) {
	const deparsed = "BEGIN ATOMIC\n SELECT (a + 1);\nEND"
	for _, mode := range []string{"none", "full", ""} {
		r := schemaPinnedRow(deparsed)
		r["body_prev"] = ""
		schemaFinishMode([]Row{r}, mode)
		if r["hash_prev"] != schemaPinnedHash {
			t.Errorf("mode %q: hash_prev %v, want the old code's %s", mode, r["hash_prev"], schemaPinnedHash)
		}
		if r["hash"] == schemaPinnedHash {
			t.Errorf("mode %q: the read body left the hash as the old code's", mode)
		}
		if _, ok := r["body_prev"]; ok {
			t.Errorf("mode %q: body_prev stayed in the row (it would ride in the payload)", mode)
		}
		if mode != "none" && !strings.HasSuffix(r["definition"].(string), "\n"+deparsed) {
			t.Errorf("mode %q: the stored definition %q does not end with the deparsed body", mode, r["definition"])
		}
	}
	s := schemaPinnedRow("select a + 1")
	schemaFinish([]Row{s})
	if _, ok := s["hash_prev"]; ok {
		t.Error("a string body (no body_prev) carries a hash_prev")
	}
	// body_prev read as it is (the pg_proc page: prosrc is 'typically' empty), not assumed empty
	p := schemaPinnedRow(deparsed)
	p["body_prev"] = "x"
	schemaFinish([]Row{p})
	if p["hash_prev"] == schemaPinnedHash || p["hash_prev"] == nil {
		t.Errorf("hash_prev %v is not over body_prev's own text", p["hash_prev"])
	}
}

// TestSchemaDeparsedSecret: a deparsed body (the server's raw text, literals as '...'::text - not the quoted form of a
// psql quote_literal) naming a password is withheld under full; one the withhold test does not match still goes
// through maskBody.
func TestSchemaDeparsedSecret(t *testing.T) {
	r := schemaPinnedRow("BEGIN ATOMIC\n SELECT 'host=h password=Hunter2abc dbname=x'::text;\nEND")
	r["body_prev"] = ""
	schemaFinishMode([]Row{r}, "full")
	if d := r["definition"].(string); strings.Contains(d, "Hunter2abc") || strings.Contains(d, "BEGIN ATOMIC") || !strings.HasSuffix(d, "\n"+SchemaBodyWithheld) {
		t.Errorf("a deparsed body naming a password stores %q", d)
	}
	m := schemaPinnedRow("BEGIN ATOMIC\n SELECT 'host=h sslkey=/k/c.key'::text;\nEND")
	m["body_prev"] = ""
	schemaFinishMode([]Row{m}, "full")
	if d := m["definition"].(string); strings.Contains(d, "/k/c.key") || !strings.Contains(d, "BEGIN ATOMIC") {
		t.Errorf("maskBody on a deparsed literal stores %q", d)
	}
}
