package repo

import (
	"bytes"
	"context"
	"fmt"
	"io"

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
	return nil // ST7 red: not built yet
}
