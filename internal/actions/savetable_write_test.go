package actions

// review-31 part B, B1 (written 11-17 07:2x, before savetable-g3): Save Table's PostgreSQL write inside its transaction,
// recorded statement by statement through a pgx.Tx of the test's own - SET LOCAL search_path, the CREATE (CreateSQL's
// text, every name quoted), the COPY of the one quoted target with its quoted columns, the commit; a cell's value is
// never in any statement's text: it travels as the COPY's data.

import (
	"context"
	"strings"
	"testing"

	"github.com/aachaemenes/pgvigil/internal/savetable"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// recTx records what writeTx asks of its transaction; the rest of pgx.Tx is never called (a nil interface)
type recTx struct {
	pgx.Tx
	texts []string
	vals  []any
}

func (r *recTx) Exec(_ context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	r.texts = append(r.texts, "EXEC "+sql)
	r.vals = append(r.vals, args...)
	return pgconn.CommandTag{}, nil
}

func (r *recTx) CopyFrom(_ context.Context, table pgx.Identifier, cols []string, src pgx.CopyFromSource) (int64, error) {
	r.texts = append(r.texts, "COPY "+table.Sanitize()+" ("+strings.Join(cols, "|")+")")
	var n int64
	for src.Next() {
		v, err := src.Values()
		if err != nil {
			return n, err
		}
		r.vals = append(r.vals, v...)
		n++
	}
	return n, src.Err()
}

func (r *recTx) Commit(context.Context) error   { r.texts = append(r.texts, "COMMIT"); return nil }
func (r *recTx) Rollback(context.Context) error { return nil }

func TestSaveTableWriteSendsNoValueText(t *testing.T) {
	tgt := savetable.Target{Database: "db", Schema: savetable.Schema, Table: `t"]'x`}
	cols := []savetable.Col{{Name: `a"b`, Type: "text"}, {Name: "a]b", Type: "int"}}
	const sentinel = "SENTINEL-7b'); DROP TABLE pgvigil_saved.decoy;--"
	rows := [][]any{{sentinel, int64(424242)}, {"two", int64(2)}, {nil, nil}}
	create, err := savetable.CreateSQL(savetable.Postgres, tgt, cols)
	if err != nil {
		t.Fatal(err)
	}
	tx := &recTx{}
	n, err := writeTx(context.Background(), tx, create, tgt, cols, rows)
	if err != nil || n != 3 {
		t.Fatalf("writeTx: %d rows, %v; want 3 and no error", n, err)
	}
	want := []string{
		"EXEC SET LOCAL search_path = pg_catalog",
		"EXEC " + create,
		`COPY "pgvigil_saved"."t""]'x" (a"b|a]b)`,
		"COMMIT",
	}
	if strings.Join(tx.texts, "\n") != strings.Join(want, "\n") {
		t.Errorf("the statements:\n%s\nwant:\n%s", strings.Join(tx.texts, "\n"), strings.Join(want, "\n"))
	}
	for _, s := range tx.texts {
		if strings.Contains(s, "SENTINEL") || strings.Contains(s, "424242") {
			t.Errorf("a cell's value in a statement's text: %q", s)
		}
	}
	if len(tx.vals) != 6 || tx.vals[0] != sentinel {
		t.Errorf("the values handed as data: %#v, want the 6 cells, the sentinel first", tx.vals)
	}
}
