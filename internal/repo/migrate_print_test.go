package repo

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

// ST7: 'pgvigil migrate -print' writes the statements migrate would run and applies nothing. These rows check the
// writer alone (no server); the box row applies a printed script with psql and compares it with migrate's schema.

func printFor(t *testing.T, meta migratePrintMeta, names, applied []string, bodies map[string]string) (string, error) {
	t.Helper()
	read := func(n string) ([]byte, error) {
		if bodies == nil {
			return migrations.ReadFile("sql/" + n)
		}
		b, ok := bodies[n]
		if !ok {
			return nil, fmt.Errorf("no body for %s", n)
		}
		return []byte(b), nil
	}
	var buf bytes.Buffer
	err := migrateScript(&buf, meta, names, applied, read)
	return buf.String(), err
}

// inOrder fails unless each of parts is in s after the one before it.
func inOrder(t *testing.T, s string, parts ...string) {
	t.Helper()
	at := 0
	for _, p := range parts {
		i := strings.Index(s[at:], p)
		if i < 0 {
			t.Fatalf("missing (or out of order) after offset %d: %q", at, p)
		}
		at += i + len(p)
	}
}

// T1 a fresh repository: the lock, the bootstrap, the jit block, the guard, then every embedded file in name order,
// each in its own transaction with its version row and the apply_roles block, then the unlock.
func TestMigratePrintFresh(t *testing.T) {
	names, err := migrationNames()
	if err != nil {
		t.Fatal(err)
	}
	out, err := printFor(t, migratePrintMeta{Build: "pgvigil test", Database: "pgv", Server: "18.1"}, names, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	inOrder(t, out,
		"-- pgvigil migrate -print", "-- build: pgvigil test", "-- repository: database pgv on PostgreSQL 18.1",
		"-- applied: none (no pgvigil.schema_version: a fresh repository)",
		fmt.Sprintf("-- pending: %d file(s): %s .. %s", len(names), names[0], names[len(names)-1]),
		"-- run it with psql as the repository owner", "--   psql -X -v ON_ERROR_STOP=1",
		"\n\\set ON_ERROR_STOP on\nSET client_encoding = 'UTF8';\n",
		fmt.Sprintf("SELECT pg_advisory_lock(%d);", migrateLockKey),
		ownerBlock,
		schemaVersionDDL,
		"DO $pgvigil_jit$", "ALTER DATABASE %I SET jit = off", "WHEN insufficient_privilege", "$pgvigil_jit$;",
		"DO $pgvigil_guard$", "unnest(ARRAY['"+names[0]+"'", "'"+names[len(names)-1]+"']::text[])",
		"unnest(ARRAY[]::text[])", "gone since then", "$pgvigil_guard$;")
	if strings.Index(out, "\\set ON_ERROR_STOP on") > strings.Index(out, "SELECT pg_advisory_lock") {
		t.Fatal("ON_ERROR_STOP is not set before the first statement")
	}
	var parts []string
	for i, n := range names {
		body, err := migrations.ReadFile("sql/" + n)
		if err != nil {
			t.Fatal(err)
		}
		parts = append(parts, fmt.Sprintf("-- file %s (%d of %d)\nBEGIN;\n", n, i+1, len(names)), string(body),
			"INSERT INTO pgvigil.schema_version (version) VALUES ('"+n+"');\n", rolesBlock, "COMMIT;\n")
	}
	parts = append(parts, fmt.Sprintf("SELECT pg_advisory_unlock(%d);", migrateLockKey))
	inOrder(t, out, parts...)
	if got := strings.Count(out, "\nCOMMIT;\n"); got != len(names) {
		t.Fatalf("COMMIT lines: %d, want one per file (%d)", got, len(names))
	}
}

// T2 a repository at version N with a gap: only the files its schema_version lacks, in name order (migrate applies a
// gap too); the guard names exactly those; the applied files' bodies are not printed.
func TestMigratePrintAtN(t *testing.T) {
	names := []string{"0001_a.sql", "0002_b.sql", "0003_c.sql", "0004_d.sql"}
	bodies := map[string]string{"0001_a.sql": "SELECT 'a1';\n", "0002_b.sql": "SELECT 'b2';\n", "0003_c.sql": "SELECT 'c3';\n", "0004_d.sql": "SELECT 'd4';\n"}
	out, err := printFor(t, migratePrintMeta{Build: "b", Database: "d", Server: "17.2", HasTable: true}, names,
		[]string{"0001_a.sql", "0003_c.sql"}, bodies)
	if err != nil {
		t.Fatal(err)
	}
	inOrder(t, out, "-- applied: 2 of this build's 4 files (newest 0003_c.sql)", "-- pending: 2 file(s): 0002_b.sql .. 0004_d.sql",
		"unnest(ARRAY['0002_b.sql', '0004_d.sql']::text[])", "unnest(ARRAY['0001_a.sql', '0003_c.sql']::text[])",
		"-- file 0002_b.sql (1 of 2)\nBEGIN;\nSELECT 'b2';\nINSERT INTO pgvigil.schema_version (version) VALUES ('0002_b.sql');\n",
		"-- file 0004_d.sql (2 of 2)\nBEGIN;\nSELECT 'd4';\n")
	for _, gone := range []string{"'a1'", "'c3'", "-- file 0001_a.sql", "-- file 0003_c.sql"} {
		if strings.Contains(out, gone) {
			t.Fatalf("an applied file printed: %q", gone)
		}
	}
}

// T3 nothing pending: the header alone (every line a comment), saying so; no statement at all.
func TestMigratePrintNothingPending(t *testing.T) {
	names := []string{"0001_a.sql", "0002_b.sql"}
	out, err := printFor(t, migratePrintMeta{Build: "b", Database: "d", Server: "16.4", HasTable: true}, names, names,
		map[string]string{"0001_a.sql": "SELECT 1;\n", "0002_b.sql": "SELECT 2;\n"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "-- pending: none - the repository holds every file of this build; nothing to run") {
		t.Fatalf("no 'pending: none' line in:\n%s", out)
	}
	for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if !strings.HasPrefix(l, "--") {
			t.Fatalf("a statement printed with nothing pending: %q", l)
		}
	}
}

// T4 versions this build does not carry (a newer pgvigil migrated the repository): named in the header, as migrate
// leaves them alone; they do not count as applied files of this build.
func TestMigratePrintNewerVersions(t *testing.T) {
	names := []string{"0001_a.sql", "0002_b.sql"}
	out, err := printFor(t, migratePrintMeta{Build: "b", Database: "d", Server: "16.4", HasTable: true}, names,
		[]string{"0001_a.sql", "0998_x.sql", "0999_future.sql"}, map[string]string{"0002_b.sql": "SELECT 2;\n"})
	if err != nil {
		t.Fatal(err)
	}
	inOrder(t, out, "-- applied: 1 of this build's 2 files (newest 0001_a.sql)",
		"-- not in this build: 2 applied version(s) (newest 0999_future.sql): a newer pgvigil migrated this repository; migrate leaves them alone",
		"-- pending: 1 file(s): 0002_b.sql .. 0002_b.sql", "-- file 0002_b.sql (1 of 1)")
}

// T5 a file's bytes go out unchanged (a dollar-quoted body, a doubled quote, a CRLF, a last line without a newline);
// a body without a final newline gets one before its version row.
func TestMigratePrintBodyVerbatim(t *testing.T) {
	body := "CREATE FUNCTION pgvigil.f() RETURNS text LANGUAGE sql AS $$ SELECT 'it''s' $$;\r\n-- a comment\r\nSELECT 1;"
	out, err := printFor(t, migratePrintMeta{Build: "b", Database: "d", Server: "16.4"}, []string{"0001_a.sql"}, nil,
		map[string]string{"0001_a.sql": body})
	if err != nil {
		t.Fatal(err)
	}
	inOrder(t, out, "BEGIN;\n"+body+"\nINSERT INTO pgvigil.schema_version (version) VALUES ('0001_a.sql');\n")
}

// T6 fails closed: a file whose last statement has no semicolon would run into the version row, so the writer refuses
// it by name (every embedded file passes: T1); an unreadable file is an error too; nothing is written either way.
func TestMigratePrintRefuses(t *testing.T) {
	out, err := printFor(t, migratePrintMeta{Build: "b", Database: "d", Server: "16.4"}, []string{"0001_a.sql", "0002_b.sql"}, nil,
		map[string]string{"0001_a.sql": "SELECT 1;\n", "0002_b.sql": "SELECT 2\n-- trailing comment\n"})
	if err == nil || !strings.Contains(err.Error(), "0002_b.sql") {
		t.Fatalf("no refusal naming 0002_b.sql: %v", err)
	}
	if out != "" {
		t.Fatalf("output after a refusal: %q", out)
	}
	// the read's own error names no file, so the name must come from the writer (review-st7 NIT 7)
	var buf bytes.Buffer
	err = migrateScript(&buf, migratePrintMeta{}, []string{"0001_a.sql"}, nil, func(string) ([]byte, error) { return nil, fmt.Errorf("unreadable") })
	if err == nil || !strings.Contains(err.Error(), "0001_a.sql") {
		t.Fatalf("an unreadable file not named: %v", err)
	}
	if buf.Len() != 0 {
		t.Fatalf("output after an unreadable file: %q", buf.String())
	}
}
