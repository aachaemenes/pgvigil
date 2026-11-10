package web

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestLikePattern(t *testing.T) {
	for in, want := range map[string]string{
		"orders":   `%orders%`,
		"my_table": `%my\_table%`,
		"100%":     `%100\%%`,
		`a\b`:      `%a\\b%`,
	} {
		if got := likePattern(in); got != want {
			t.Errorf("likePattern(%q) = %q; want %q", in, got, want)
		}
	}
}

// the length rule counts characters, not bytes, and needs no repository
func TestSearchLength(t *testing.T) {
	s := &Server{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	for q, want := range map[string]int{"": 400, "a": 400, "\u00e9": 400, strings.Repeat("x", 129): 400} {
		rec := httptest.NewRecorder()
		s.search(rec, httptest.NewRequest(http.MethodGet, "/api/search?q="+url.QueryEscape(q), nil))
		if rec.Code != want {
			t.Errorf("q of %d bytes: %d; want %d", len(q), rec.Code, want)
		}
	}
}

// TestSearchLive runs the search as the API serves it against a repository that holds collected rows (a demo
// repository: PGVIGIL_SEARCH_REPO_DSN); skipped without it. It takes a database name and a table name the
// repository holds and expects: the exact name first in its part, the databases before the tables, a schema.name
// text finding its table first, 128 two-byte characters accepted, the wildcards matching nothing by themselves.
func TestSearchLive(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_SEARCH_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_SEARCH_REPO_DSN not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(q string) []map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		s.search(rec, httptest.NewRequest(http.MethodGet, "/api/search?q="+url.QueryEscape(q), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("q=%q: %d %s", q, rec.Code, rec.Body.String())
		}
		var tb struct {
			Columns []string `json:"columns"`
			Rows    [][]any  `json:"rows"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &tb); err != nil {
			t.Fatal(err)
		}
		out := make([]map[string]any, len(tb.Rows))
		for i, r := range tb.Rows {
			out[i] = map[string]any{}
			for j, c := range tb.Columns {
				out[i][c] = r[j]
			}
		}
		return out
	}
	var db, schema, table string
	if err := pool.QueryRow(ctx, `SELECT d.datname FROM pgvigil.databases d JOIN pgvigil.instances i USING (instance_id)
	                               WHERE i.is_active AND d.is_present AND length(d.datname) > 3 ORDER BY d.datname LIMIT 1`).Scan(&db); err != nil {
		t.Skipf("the repository holds no database row: %v", err)
	}
	if err := pool.QueryRow(ctx, `SELECT t.schema_name, t.table_name FROM pgvigil.tables t JOIN pgvigil.instances i USING (instance_id)
	                               WHERE i.is_active AND t.is_present AND length(t.table_name) > 3 ORDER BY t.table_name LIMIT 1`).Scan(&schema, &table); err != nil {
		t.Skipf("the repository holds no table row: %v", err)
	}
	rows := call(db[1:])
	seenTable := false
	for _, r := range rows {
		if r["kind"] == "table" {
			seenTable = true
		} else if seenTable {
			t.Fatalf("a database row after a table row for %q", db[1:])
		}
	}
	rows = call(db)
	if len(rows) == 0 || rows[0]["kind"] != "database" || rows[0]["datname"] != db {
		t.Errorf("q=%q: the exact database name is not first: %v", db, rows)
	}
	firstTable := func(rows []map[string]any) map[string]any {
		for _, r := range rows {
			if r["kind"] == "table" {
				return r
			}
		}
		return nil
	}
	if r := firstTable(call(table)); r == nil || r["table_name"] != table {
		t.Errorf("q=%q: the exact table name is not the first table: %v", table, r)
	}
	if r := firstTable(call(schema + "." + table)); r == nil || r["table_name"] != table || r["schema_name"] != schema {
		t.Errorf("q=%q: schema.name does not find its table first: %v", schema+"."+table, r)
	}
	if rows := call("%_"); len(rows) != 0 {
		t.Errorf("the wildcards matched %d rows by themselves", len(rows))
	}
	call(strings.Repeat("\u00e9", 128))
}
