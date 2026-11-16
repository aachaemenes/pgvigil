package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtureBundle = "../../internal/remote/format/testdata/ok/site1/coll1/HOST%5CINST/2026-11-16/0000000001-20261116T175500Z"

// inspect prints a bundle as a site's security team reads it before it leaves: the checks' result, the signature's,
// the manifest and every line, as JSON.
func TestBundleInspect(t *testing.T) {
	var out bytes.Buffer
	if err := inspectBundle(&out, fixtureBundle, nil, 1<<20); err != nil {
		t.Fatalf("inspect: %v\n%s", err, out.String())
	}
	s := out.String()
	for _, want := range []string{`"checks": "ok"`, `"signature": "not signed"`, `"name": "HOST\\INST"`, `"view": "mssql_ag"`, `"role":"SECONDARY"`, `9223372036854775807`} {
		if !strings.Contains(s, want) {
			t.Errorf("no %s in:\n%s", want, s)
		}
	}
	// a changed byte: the checks say so and the command fails
	dir := t.TempDir()
	for _, n := range []string{"manifest.json", "SHA256SUMS", "mssql_activity.ndjson.gz", "mssql_ag.ndjson.gz"} {
		b, err := os.ReadFile(filepath.Join(fixtureBundle, n))
		if err != nil {
			t.Fatal(err)
		}
		if n == "mssql_ag.ndjson.gz" {
			b[20] ^= 0xff
		}
		if err := os.WriteFile(filepath.Join(dir, n), b, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	out.Reset()
	if err := inspectBundle(&out, dir, nil, 1<<20); err == nil || !strings.Contains(out.String(), "checksum") {
		t.Errorf("a changed byte: %v\n%s", err, out.String())
	}
	// a key asked for and no signature: refused
	out.Reset()
	if err := inspectBundle(&out, fixtureBundle, []string{"ed25519:11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="}, 1<<20); err == nil || !strings.Contains(out.String(), "no manifest.sig") {
		t.Errorf("a key and no signature: %v\n%s", err, out.String())
	}
}
