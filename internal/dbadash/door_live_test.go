package dbadash

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestLivePages calls every DBADash page once for one instance (scripts/proof-dbadash-door.sh drives it; skipped
// without PGVIGIL_DBADASH_PAGE_DSN). PGVIGIL_DBADASH_PAGE_ID is the DBADash InstanceID, PGVIGIL_DBADASH_PAGE_FROM and
// _TO the window (RFC 3339), PGVIGIL_DBADASH_PAGE_SNAPSHOT (RFC 3339, optional) the sessions page's snapshot,
// PGVIGIL_DBADASH_PAGE_DIR the folder each page's reply is written to as <page>.json. It prints one line per page:
//
//	page <key> ok|error version=<v> proven=<bool> sets=<n> rows=<n,n,...> err=<message>
func TestLivePages(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_DBADASH_PAGE_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_DBADASH_PAGE_DSN not set (scripts/proof-dbadash-door.sh sets it)")
	}
	id, err := strconv.Atoi(os.Getenv("PGVIGIL_DBADASH_PAGE_ID"))
	if err != nil {
		t.Fatal("PGVIGIL_DBADASH_PAGE_ID: ", err)
	}
	from, err1 := time.Parse(time.RFC3339, os.Getenv("PGVIGIL_DBADASH_PAGE_FROM"))
	to, err2 := time.Parse(time.RFC3339, os.Getenv("PGVIGIL_DBADASH_PAGE_TO"))
	if err1 != nil || err2 != nil {
		t.Fatal("PGVIGIL_DBADASH_PAGE_FROM / _TO must be RFC 3339 times")
	}
	var snap time.Time
	if v := os.Getenv("PGVIGIL_DBADASH_PAGE_SNAPSHOT"); v != "" {
		if snap, err = time.Parse(time.RFC3339Nano, v); err != nil {
			t.Fatal("PGVIGIL_DBADASH_PAGE_SNAPSHOT: ", err)
		}
	}
	dir := os.Getenv("PGVIGIL_DBADASH_PAGE_DIR")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	for _, p := range Pages {
		out, err := PageDSN(ctx, dsn, p.Key, PageArgs{InstanceID: id, From: from, To: to, Snapshot: snap})
		state, msg := "ok", ""
		if err != nil {
			state, msg = "error", strings.ReplaceAll(err.Error(), "\n", " ")
		}
		var counts []string
		for _, rs := range out.Results {
			counts = append(counts, strconv.Itoa(len(rs.Rows)))
		}
		fmt.Printf("page %s %s version=%s proven=%t sets=%d rows=%s err=%s\n", p.Key, state, out.Version, out.Proven, len(out.Results), strings.Join(counts, ","), msg)
		if dir != "" && err == nil {
			b, err := json.Marshal(out)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, p.Key+".json"), b, 0o600); err != nil {
				t.Fatal(err)
			}
		}
	}
}

// TestMaskCells hands scripts/proof-dbadash-door.sh the pages' text columns and their mask (skipped without
// PGVIGIL_DBADASH_MASK_OUT). The proof compares each page with a second client's call of the same procedure; that
// client's cells of the text columns must pass the mask the page's cells passed - this package's, never a copy of it,
// and the columns by this package's list. It writes PGVIGIL_DBADASH_MASK_OUT as
//
//	{"columns": {"<page>": ["<column>", ...]}, "masked": ["<text>", ...]}
//
// columns being pageText's and masked the texts of the JSON list in PGVIGIL_DBADASH_MASK_IN (none without it) through
// maskPage, in the list's order. It prints no text.
func TestMaskCells(t *testing.T) {
	out := os.Getenv("PGVIGIL_DBADASH_MASK_OUT")
	if out == "" {
		t.Skip("PGVIGIL_DBADASH_MASK_OUT not set (scripts/proof-dbadash-door.sh sets it)")
	}
	cells := []string{}
	if in := os.Getenv("PGVIGIL_DBADASH_MASK_IN"); in != "" {
		b, err := os.ReadFile(in)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(b, &cells); err != nil {
			t.Fatal("PGVIGIL_DBADASH_MASK_IN is not a JSON list of texts")
		}
	}
	reply := struct {
		Columns map[string][]string `json:"columns"`
		Masked  []string            `json:"masked"`
	}{Columns: map[string][]string{}, Masked: []string{}}
	var page, column string
	for p, cols := range pageText {
		for c := range cols {
			reply.Columns[p] = append(reply.Columns[p], c)
			page, column = p, c
		}
		sort.Strings(reply.Columns[p])
	}
	if page == "" {
		t.Fatal("no page lists a text column")
	}
	// every text column passes the one mask: a reply of one such column carries the texts through maskPage
	r := PageReply{Page: page, Results: []ResultSet{{Columns: []Column{{Name: column, Type: "NVARCHAR"}}}}}
	for _, c := range cells {
		r.Results[0].Rows = append(r.Results[0].Rows, []any{c})
	}
	maskPage(&r)
	for _, row := range r.Results[0].Rows {
		s, _ := row[0].(string)
		reply.Masked = append(reply.Masked, s)
	}
	b, err := json.Marshal(reply)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(out, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

// TestLiveImport runs the import once (scripts/proof-dbadash-door.sh drives it; skipped without
// PGVIGIL_DBADASH_IMPORT_DSN): from that DBADash repository into the pgvigil repository PGVIGIL_DBADASH_IMPORT_REPO
// (its owner, or a login in role pgvigil_collector), the dry run first when PGVIGIL_DBADASH_IMPORT_DRY=1; with
// PGVIGIL_DBADASH_IMPORT_STORE=1 through a pool of that repository handed to it (ImportOptions.Store, serve's way: task
// 206), which it must leave open. It prints one line per instance and mapping, one per Progress call, and with a Store
// whether the pool still answers after the import:
//
//	import <dbadash id> <pgvigil id> <mapping> source=<n> inserted=<n> stored=<n> skipped=<reason>
//	progress <dbadash id> <mapping> inserted=<n> final=<0|1>
//	store open after: <ok | the error>
func TestLiveImport(t *testing.T) {
	src := os.Getenv("PGVIGIL_DBADASH_IMPORT_DSN")
	if src == "" {
		t.Skip("PGVIGIL_DBADASH_IMPORT_DSN not set (scripts/proof-dbadash-door.sh sets it)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	opt := ImportOptions{DryRun: os.Getenv("PGVIGIL_DBADASH_IMPORT_DRY") == "1"}
	if b := os.Getenv("PGVIGIL_DBADASH_IMPORT_BATCH"); b != "" {
		opt.Batch, _ = strconv.Atoi(b)
	}
	opt.Progress = func(c ImportCount, final bool) {
		f := 0
		if final {
			f = 1
		}
		fmt.Printf("progress %d %s inserted=%d final=%d\n", c.DBADashID, c.Mapping, c.Inserted, f)
	}
	repoDSN := os.Getenv("PGVIGIL_DBADASH_IMPORT_REPO")
	if os.Getenv("PGVIGIL_DBADASH_IMPORT_STORE") == "1" {
		// the pool handed to Import is the only way to the store: Import is given no dsn of its own (review 206e 2: an
		// Import that opened the dsn itself would pass every E2 row otherwise)
		pool, err := pgxpool.New(ctx, repoDSN)
		repoDSN = "host=/nonexistent-pgvigil-e2 dbname=none"
		if err != nil {
			t.Fatal(err)
		}
		defer pool.Close()
		opt.Store = pool
		defer func() {
			res := "ok"
			if err := pool.Ping(ctx); err != nil {
				res = err.Error()
			}
			fmt.Printf("store open after: %s\n", res)
		}()
	}
	got, err := Import(ctx, log, src, repoDSN, opt)
	for _, c := range got {
		fmt.Printf("import %d %d %s source=%d inserted=%d stored=%d skipped=%s\n", c.DBADashID, c.PgvigilID, c.Mapping, c.Source, c.Inserted, c.Stored, c.Skipped)
	}
	if err != nil {
		fmt.Printf("import error %s\n", strings.ReplaceAll(err.Error(), "\n", " "))
		t.Fatal(err)
	}
}
