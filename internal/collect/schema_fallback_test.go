package collect

import (
	"strings"
	"testing"
)

// The B+C review's S3: the payload cap's three outcomes for one database's read - as it is; over it with bodies as
// text, so the bodies go back to their hashes with a 'schema text:' row; over it even with the hashes, not
// snapshotted. (A new function: the branch was inline in RunBatches and untested, so there is no red on rel-a26b
// beyond its absence.)
func TestSchemaFitFallback(t *testing.T) {
	mk := func() []Row {
		return []Row{{"kind": "obj", "object_kind": "function", "identity": "public.f(integer)", "owner": "app", "acl": "",
			"definition": "function returns integer language plpgsql", "body": strings.Repeat("select 1; ", 2000)}}
	}
	text, hashed := mk(), mk()
	schemaFinishMode(text, "full")
	schemaFinish(hashed)
	nText, nHashed := schemaPayloadSize(text), schemaPayloadSize(hashed)
	if nText <= nHashed {
		t.Fatalf("the text form (%d) is not larger than the hashed form (%d)", nText, nHashed)
	}
	if fit, note := schemaFit(text, "db1", nText); fit != schemaFitAsIs || note != nil {
		t.Errorf("at the cap: %v %v, want as it is", fit, note)
	}
	if fit, note := schemaFit(text, "db1", (nText+nHashed)/2); fit != schemaFitHashes || note["source"] != "schema text:db1" ||
		!strings.Contains(note["message"].(string), "bodies kept as hashes in db1") || text[0]["definition"] != hashed[0]["definition"] {
		t.Errorf("between the two sizes: %v %v, definition %q, want the hashes back and the 'schema text:' row", fit, note, text[0]["definition"])
	}
	over := mk()
	schemaFinishMode(over, "full")
	if fit, note := schemaFit(over, "db1", nHashed-1); fit != schemaFitOver || !strings.Contains(note["message"].(string), "not snapshotted") {
		t.Errorf("under the hashed size: %v %v, want not snapshotted", fit, note)
	}
}
