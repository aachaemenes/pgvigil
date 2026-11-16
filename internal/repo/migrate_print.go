package repo

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

// migratePrintMeta is what the printed script's header names: the binary's version line and the repository as read.
type migratePrintMeta struct {
	Build    string // the binary's version line
	Database string // current_database()
	Server   string // current_setting('server_version')
	HasTable bool   // pgvigil.schema_version exists (false: a fresh repository)
}

// MigrateScript writes to w the statements 'pgvigil migrate' would run on this repository, in its order, and applies
// nothing: the repository is only read (one READ ONLY transaction: the database, the server version, and the versions
// pgvigil.schema_version holds), so any login that can read pgvigil.schema_version may print it. Nothing reaches w
// unless the whole script was made.
func (r *Repo) MigrateScript(ctx context.Context, w io.Writer, build string) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return fmt.Errorf("migrate -print: %w", err)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	meta := migratePrintMeta{Build: build}
	if err := tx.QueryRow(ctx, `SELECT current_database(), current_setting('server_version'),
       to_regclass('pgvigil.schema_version') IS NOT NULL`).Scan(&meta.Database, &meta.Server, &meta.HasTable); err != nil {
		return fmt.Errorf("migrate -print: read the repository: %w", err)
	}
	var applied []string
	if meta.HasTable {
		rows, err := tx.Query(ctx, `SELECT version FROM pgvigil.schema_version ORDER BY version`)
		if err != nil {
			return fmt.Errorf("migrate -print: read pgvigil.schema_version: %w", err)
		}
		applied, err = pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return fmt.Errorf("migrate -print: read pgvigil.schema_version: %w", err)
		}
	}
	names, err := migrationNames()
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := migrateScript(&buf, meta, names, applied, func(n string) ([]byte, error) { return migrations.ReadFile("sql/" + n) }); err != nil {
		return err
	}
	_, err = buf.WriteTo(w)
	return err
}

// rolesBlock follows each printed file inside its transaction: migrate's own rule, decided when it runs - apply_roles()
// re-applied when it exists by then (CREATE OR REPLACE resets SECURITY DEFINER), so on a fresh repository from the
// file that creates it onwards.
const rolesBlock = "DO $pgvigil_roles$ BEGIN IF to_regprocedure('pgvigil.apply_roles()') IS NOT NULL THEN PERFORM pgvigil.apply_roles(); END IF; END $pgvigil_roles$;\n"

// migrateScript writes the script for a repository whose pgvigil.schema_version holds applied: the files of names
// (in name order) that applied lacks, each read through read.
func migrateScript(w io.Writer, meta migratePrintMeta, names, applied []string, read func(string) ([]byte, error)) error {
	have := make(map[string]bool, len(applied))
	for _, v := range applied {
		have[v] = true
	}
	known := make(map[string]bool, len(names))
	var pending []string
	newest := ""
	for _, n := range names {
		known[n] = true
		if have[n] {
			if n > newest {
				newest = n
			}
			continue
		}
		pending = append(pending, n)
	}
	var foreign []string // applied versions this build does not carry: migrate leaves them alone
	for _, v := range applied {
		if !known[v] {
			foreign = append(foreign, v)
		}
	}
	sort.Strings(foreign)
	bodies := make([][]byte, len(pending))
	for i, n := range pending {
		b, err := read(n)
		if err != nil {
			return fmt.Errorf("migrate -print: %s: %w", n, err)
		}
		if !endsWithSemicolon(b) {
			return fmt.Errorf("migrate -print: %s: its last statement has no semicolon, so the version row would run into it (migrate's one Exec does not care; a printed script does)", n)
		}
		bodies[i] = b
	}

	var s bytes.Buffer
	s.WriteString("-- pgvigil migrate -print: the statements 'pgvigil migrate' would run on this repository, in its order; nothing was applied.\n")
	fmt.Fprintf(&s, "-- build: %s\n", oneLine(meta.Build))
	fmt.Fprintf(&s, "-- repository: database %s on PostgreSQL %s\n", oneLine(meta.Database), oneLine(meta.Server))
	if !meta.HasTable {
		s.WriteString("-- applied: none (no pgvigil.schema_version: a fresh repository)\n")
	} else {
		fmt.Fprintf(&s, "-- applied: %d of this build's %d files", len(names)-len(pending), len(names))
		if newest != "" {
			fmt.Fprintf(&s, " (newest %s)", newest)
		}
		s.WriteString("\n")
	}
	if len(foreign) > 0 {
		fmt.Fprintf(&s, "-- not in this build: %d applied version(s) (newest %s): a newer pgvigil migrated this repository; migrate leaves them alone\n",
			len(foreign), oneLine(foreign[len(foreign)-1]))
	}
	if len(pending) == 0 {
		s.WriteString("-- pending: none - the repository holds every file of this build; nothing to run\n")
		_, err := s.WriteTo(w)
		return err
	}
	fmt.Fprintf(&s, "-- pending: %d file(s): %s .. %s\n", len(pending), pending[0], pending[len(pending)-1])
	s.WriteString("-- printed for the repository as read now: a migrate run in between makes the guard below stop the script before any file.\n")
	s.WriteString("-- run it as the repository owner: psql -X -v ON_ERROR_STOP=1 -d <the repository database> -f <this file>\n")
	s.WriteString("-- (each file commits on its own, as migrate commits them: a failure stops at that file, the ones before it stay applied)\n\n")

	fmt.Fprintf(&s, "SELECT pg_advisory_lock(%d);\n\n", migrateLockKey)
	s.WriteString(schemaVersionDDL + "\n\n")
	s.WriteString(jitBlock + "\n")
	s.WriteString("DO $pgvigil_guard$\nDECLARE done text;\nBEGIN\n")
	s.WriteString("  SELECT string_agg(version, ', ' ORDER BY version) INTO done FROM pgvigil.schema_version\n   WHERE version = ANY (ARRAY[")
	for i, n := range pending {
		if i > 0 {
			s.WriteString(", ")
		}
		s.WriteString(sqlLiteral(n))
	}
	s.WriteString("]);\n  IF done IS NOT NULL THEN\n")
	s.WriteString("    RAISE EXCEPTION 'pgvigil migrate -print: % applied since this script was printed: print it again', done;\n")
	s.WriteString("  END IF;\nEND\n$pgvigil_guard$;\n")
	for i, n := range pending {
		fmt.Fprintf(&s, "\n-- file %s (%d of %d)\nBEGIN;\n", n, i+1, len(pending))
		s.Write(bodies[i])
		if b := bodies[i]; len(b) == 0 || b[len(b)-1] != '\n' {
			s.WriteString("\n")
		}
		fmt.Fprintf(&s, "INSERT INTO pgvigil.schema_version (version) VALUES (%s);\n", sqlLiteral(n))
		s.WriteString(rolesBlock)
		s.WriteString("COMMIT;\n")
	}
	fmt.Fprintf(&s, "\nSELECT pg_advisory_unlock(%d);\n", migrateLockKey)
	_, err := s.WriteTo(w)
	return err
}

// jitBlock is repositoryJITOff's rule decided when the script runs: PostgreSQL 11 or later, no jit entry of the
// database's own -> ALTER DATABASE <db> SET jit = off; a refusal (the login does not own the database) is a WARNING
// naming the statement for the owner, never a stop - as migrate warns and goes on.
const jitBlock = `DO $pgvigil_jit$
DECLARE
  entry text;
  stmt text := format('ALTER DATABASE %I SET jit = off', current_database());
BEGIN
  IF current_setting('server_version_num')::int < 110000 THEN
    RETURN;
  END IF;
  SELECT substr(x, 5) INTO entry
    FROM pg_database d, pg_db_role_setting s, unnest(s.setconfig) x
   WHERE d.datname = current_database() AND s.setdatabase = d.oid AND s.setrole = 0 AND x LIKE 'jit=%'
   LIMIT 1;
  IF entry IS NOT NULL THEN
    RETURN; -- the database's own jit setting is left alone
  END IF;
  EXECUTE stmt;
  RAISE NOTICE 'the repository database %: jit set off for its new sessions (%)', current_database(), stmt;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE WARNING 'the repository database %: % was refused (%); the database''s owner runs it once', current_database(), stmt, SQLERRM;
END
$pgvigil_jit$;
`

// endsWithSemicolon: the file's last statement ends with ';' once trailing blank lines and whole-line '--' comments are
// set aside (a block comment or a comment after the semicolon on the last line is not looked into: such a file fails
// closed).
func endsWithSemicolon(b []byte) bool {
	lines := strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(lines[i])
		if l == "" || strings.HasPrefix(l, "--") {
			continue
		}
		return strings.HasSuffix(l, ";")
	}
	return false
}

// sqlLiteral quotes s as a standard SQL string literal.
func sqlLiteral(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// oneLine keeps a header value on its comment line.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }
