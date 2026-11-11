package dbadash

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
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

// TestLiveImport runs the import once (scripts/proof-dbadash-door.sh drives it; skipped without
// PGVIGIL_DBADASH_IMPORT_DSN): from that DBADash repository into the pgvigil repository PGVIGIL_DBADASH_IMPORT_REPO
// (its owner), the dry run first when PGVIGIL_DBADASH_IMPORT_DRY=1. It prints one line per instance and mapping:
//
//	import <dbadash id> <pgvigil id> <mapping> source=<n> inserted=<n> stored=<n> skipped=<reason>
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
	got, err := Import(ctx, log, src, os.Getenv("PGVIGIL_DBADASH_IMPORT_REPO"), opt)
	for _, c := range got {
		fmt.Printf("import %d %d %s source=%d inserted=%d stored=%d skipped=%s\n", c.DBADashID, c.PgvigilID, c.Mapping, c.Source, c.Inserted, c.Stored, c.Skipped)
	}
	if err != nil {
		fmt.Printf("import error %s\n", strings.ReplaceAll(err.Error(), "\n", " "))
		t.Fatal(err)
	}
}
