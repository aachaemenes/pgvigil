package remote

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

type sqlBatch struct {
	view string
	at   time.Time
	rows []map[string]any
}

// Each cursor rule against its SQL function: the same batches imported into a repository and passed through
// cursorMoves; the repository's own readers (LogCursor, MSSQLCursor, MSSQLSeqCursor) must answer what the rule
// answers. A rule that drifts from its function (a new migration) turns its row red. Needs PGVIGIL_REPO_TEST_DSN.
func TestCursorRulesAgainstSQL(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	a, b := t0.Add(-time.Hour), t0
	for _, c := range []struct {
		name, engine string
		batches      []sqlBatch
		sources      map[string]string // source -> its reader: log, mssql, seq
	}{
		{"logs", "postgres", []sqlBatch{
			{"logs", t0, []map[string]any{{"kind": "cursor", "source": "csvlog:/var/log/pg", "read_to": b}}},
			{"logs", t1, []map[string]any{{"kind": "cursor", "source": "csvlog:/var/log/pg", "read_to": a}}},
		}, map[string]string{"csvlog:/var/log/pg": "log"}},
		{"pgaudit", "postgres", []sqlBatch{
			{"pgaudit", t0, []map[string]any{{"kind": "state", "loaded": true, "keep_text": false, "log_where": "file"}, {"kind": "cursor", "source": "pgaudit:/var/log/pg", "read_to": b}}},
		}, map[string]string{"pgaudit:/var/log/pg": "log"}},
		{"pi", "postgres", []sqlBatch{
			{"pi", t0, []map[string]any{{"kind": "cursor", "source": "pi", "read_to": b}}},
		}, map[string]string{"pi": "log"}},
		{"schema ddl", "postgres", []sqlBatch{
			{"schema", t0, []map[string]any{
				{"kind": "ddl", "datname": "app", "dbid": 16384, "log_id": 1, "logged_at": a, "event": "ddl_command_end", "command_tag": "CREATE TABLE"},
				{"kind": "ddl_cursor", "datname": "crm", "read_to": b},
			}},
		}, map[string]string{"schema_ddl:app": "log", "schema_ddl:crm": "log"}},
		{"mssql xe", "sqlserver", []sqlBatch{
			{"mssql_xe", t0, []map[string]any{
				{"kind": "cursor", "source": "xe:blocked", "file_name": "blocked_0_1.xel", "file_offset": int64(4096), "last_event_at": a.Format(time.RFC3339Nano), "last_seq": int64(0)},
				{"kind": "cursor", "source": "xe:blocked", "file_name": "blocked_0_2.xel", "file_offset": int64(512), "last_event_at": b.Format(time.RFC3339Nano), "last_seq": int64(0)},
			}},
		}, map[string]string{"xe:blocked": "mssql"}},
		{"mssql jobs", "sqlserver", []sqlBatch{
			{"mssql_jobs", t0, []map[string]any{{"kind": "read", "cursor": true}, {"kind": "cursor", "last_history_id": int64(900), "mark": int64(7)}}},
		}, map[string]string{"jobs": "seq", "jobs_mark": "seq"}},
		{"mssql backup files", "sqlserver", []sqlBatch{
			{"mssql_backup_files", t0, []map[string]any{{"kind": "cursor", "last_set_id": int64(55), "mark": int64(2)}}},
		}, map[string]string{"backup_sets": "seq", "backup_sets_mark": "seq"}},
		{"mssql backup history", "sqlserver", []sqlBatch{
			{"mssql_backup_history", t0, []map[string]any{
				{"kind": "cursor", "source": "backup_history", "last_id": int64(10), "mark": int64(1)},
				{"kind": "cursor", "source": "restore_history", "last_id": int64(4), "mark": int64(9)},
			}},
		}, map[string]string{"backup_history": "seq", "backup_history_mark": "seq", "restore_history": "seq", "restore_history_mark": "seq"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			var tag [4]byte
			_, _ = rand.Read(tag[:])
			id, err := r.EnsureInstanceEngine(ctx, c.engine, "cursor-rule-"+hex.EncodeToString(tag[:]), "onprem", "16.0", 16, false, nil)
			if err != nil {
				t.Fatal(err)
			}
			cur := map[string]format.Cursor{}
			for _, bt := range c.batches {
				if err := r.Import(ctx, id, bt.view, bt.at, bt.rows); err != nil {
					t.Fatalf("import %s (the fixture, not the rule): %v", bt.view, err)
				}
				for _, m := range cursorMoves(bt.view, bt.at, bt.rows, func(s string) (format.Cursor, bool) { x, ok := cur[s]; return x, ok }) {
					cur[m.Source] = m
				}
			}
			for src, reader := range c.sources {
				g, ok := cur[src]
				switch reader {
				case "log":
					at, found, err := r.LogCursor(ctx, id, src)
					if err != nil || found != ok || (ok && !at.Equal(g.At.Truncate(time.Microsecond))) {
						t.Errorf("%s: the store %v %v (%v), the rule %v %+v", src, at, found, err, ok, g)
					}
				case "mssql":
					f, off, last, seq, found, err := r.MSSQLCursor(ctx, id, src)
					same := found == ok && (!ok || (f == g.FileName && off == g.FileOffset && seq == g.LastSeq && g.LastEventAt != nil && last.Equal(g.LastEventAt.Truncate(time.Microsecond))))
					if err != nil || !same {
						t.Errorf("%s: the store %q %d %v %d %v (%v), the rule %+v", src, f, off, last, seq, found, err, g)
					}
				case "seq":
					n, found, err := r.MSSQLSeqCursor(ctx, id, src)
					if err != nil || found != ok || (ok && n != g.Seq) {
						t.Errorf("%s: the store %d %v (%v), the rule %v %+v", src, n, found, err, ok, g)
					}
				}
			}
		})
	}
}
