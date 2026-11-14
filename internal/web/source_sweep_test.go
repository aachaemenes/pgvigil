package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestSweepStart (task 205's review, part b, finding 1): a host with no configured region sweeps from the first kept
// region that is not silent (STS is asked there too), else the first kept.
func TestSweepStart(t *testing.T) {
	for _, c := range []struct {
		regions, silent []string
		want            string
	}{
		{[]string{"ap-northeast-1", "us-east-2"}, []string{"ap-northeast-1"}, "us-east-2"},
		{[]string{"ap-northeast-1", "us-east-2"}, nil, "ap-northeast-1"},
		{[]string{"ap-northeast-1"}, []string{"ap-northeast-1"}, "ap-northeast-1"},
		{nil, nil, ""},
	} {
		if got := sweepStart(c.regions, c.silent); got != c.want {
			t.Errorf("sweepStart(%v, %v) = %q, want %q", c.regions, c.silent, got, c.want)
		}
	}
}

// TestSourceSweepNotesOnAStore (task 205's review, part b): on a migrated repository (PGVIGIL_REPO_TEST_DSN, its
// owner; skipped without it) -
// (1) a weekly sweep tried, whatever its outcome, is not tried again by the loop for 7 days (sweep_tried_at);
// (2) a region is silent (left out of the hourly read) only while its 'not reachable' note is under 7 days old;
// (3) a read's notes never land over a newer read's;
// (4) last_notes stops before 4000 characters at an item and says how many it left out;
// (5) an admin's edit that removes a kept region drops that region's notes; a region never kept keeps its note, and a
// sweep's own edit drops none.
func TestSourceSweepNotesOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	name := fmt.Sprintf("sweep-%d", time.Now().UnixNano()%1000000000)
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_sources WHERE name = $1`, name); err != nil {
			t.Error(err)
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	source := func(payload string) string {
		t.Helper()
		var out string
		if err := pool.QueryRow(ctx, `SELECT pgvigil.import_admin_source(now(), $1::jsonb)->>'outcome'`, payload).Scan(&out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	notes := func(items string, asked []string, started time.Time, sweep bool) {
		t.Helper()
		exec(`SELECT pgvigil.import_admin_source_notes($1, now(), $2::jsonb, $3::text[], $4, $5)`, name, items, asked, started, sweep)
	}
	text := func(q string) string {
		t.Helper()
		var out string
		if err := pool.QueryRow(ctx, q, name).Scan(&out); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
		return out
	}
	if got := source(fmt.Sprintf(`{"op":"add","ui_user":"test","name":%q,"kind":"aws","ref":"file:/x/%s.json","regions":["eu-west-1","us-east-2"]}`, name, name)); got != "done" {
		t.Fatalf("add: %s", got)
	}
	// (1) regions 8 days old: the loop's query says sweep; once a sweep was tried (its notes say so), it does not
	resweep := func() bool {
		t.Helper()
		rows, err := pool.Query(ctx, dueSourcesSQL, weeklySweep.Seconds())
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		for rows.Next() {
			var n string
			var r bool
			if err := rows.Scan(&n, &r); err != nil {
				t.Fatal(err)
			}
			if n == name {
				return r
			}
		}
		t.Fatalf("%s is not due", name)
		return false
	}
	exec(`UPDATE pgvigil.admin_sources SET regions_read_at = now() - interval '8 days', last_run = NULL WHERE name = $1`, name)
	if !resweep() {
		t.Fatal("(1) regions 8 days old, no sweep tried: not swept")
	}
	notes(`[{"key":"source","text":"sts:GetCallerIdentity did not answer within 20s"}]`, nil, time.Now(), true)
	if resweep() {
		t.Fatal("(1) a sweep tried now (it failed): swept again at the next tick")
	}
	exec(`UPDATE pgvigil.admin_sources SET sweep_tried_at = now() - interval '8 days' WHERE name = $1`, name)
	if !resweep() {
		t.Fatal("(1) a sweep tried 8 days ago: not swept")
	}
	exec(`UPDATE pgvigil.admin_sources SET regions_read_at = now() - interval '6 days', sweep_tried_at = NULL WHERE name = $1`, name)
	if resweep() {
		t.Fatal("(1) regions 6 days old: swept")
	}
	exec(`UPDATE pgvigil.admin_sources SET regions_read_at = now() - interval '8 days', sweep_tried_at = now() - interval '6 days' WHERE name = $1`, name)
	if resweep() {
		t.Fatal("(1) regions 8 days old, a sweep tried 6 days ago: swept")
	}
	// (2) a 'not reachable' note a day old: silent; 8 days old: asked again by the hourly read
	s := &Server{pool: pool}
	setNote := func(age string) {
		t.Helper()
		exec(`UPDATE pgvigil.admin_sources SET note_items = jsonb_build_array(jsonb_build_object('key', 'eu-west-1', 'text', 'eu-west-1: not reachable (no answer within 20s)',
		        'first', now() - $2::text::interval, 'last', now() - $2::text::interval)) WHERE name = $1`, name, age)
	}
	setNote("1 day")
	if src, err := s.sourceByName(ctx, name); err != nil || strings.Join(src.Silent, " ") != "eu-west-1" {
		t.Fatalf("(2) a day-old silent note: %v silent %v", err, src)
	}
	setNote("8 days")
	if src, err := s.sourceByName(ctx, name); err != nil || len(src.Silent) != 0 {
		t.Fatalf("(2) an 8-day-old silent note: %v silent %v", err, src.Silent)
	}
	// (3) a read's notes after a newer read was applied: not written
	exec(`UPDATE pgvigil.admin_sources SET last_read_start = now(), note_items = '[]' WHERE name = $1`, name)
	notes(`[{"key":"source","text":"an older read"}]`, nil, time.Now().Add(-time.Minute), false)
	if got := text(`SELECT note_items::text FROM pgvigil.admin_sources WHERE name = $1`); got != "[]" {
		t.Fatalf("(3) an older read's notes landed: %s", got)
	}
	// (4) 200 notes of about 100 characters: cut at an item before 4000, the rest counted
	var many []string
	for i := 0; i < 200; i++ {
		many = append(many, fmt.Sprintf(`{"key":"source","text":"note %03d %s"}`, i, strings.Repeat("x", 90)))
	}
	notes("["+strings.Join(many, ",")+"]", nil, time.Now().Add(time.Minute), false)
	ln := text(`SELECT last_notes FROM pgvigil.admin_sources WHERE name = $1`)
	if len(ln) > 4000 || !strings.HasSuffix(ln, " more") || !strings.Contains(ln, "; and ") || !strings.Contains(ln, "x; and") {
		t.Fatalf("(4) last_notes %d characters, ends %q", len(ln), ln[max(0, len(ln)-60):])
	}
	// (5) the kept eu-west-1 removed by an admin's edit: its note goes; a region never kept (refused at a sweep) keeps
	// its note; a sweep's own edit drops none
	items := `[{"key":"source","text":"rds:DescribeSourceRegions in us-east-2: 3 regions"},
	           {"key":"eu-west-1","text":"eu-west-1: not reachable (no answer within 20s)"},
	           {"key":"af-south-1","text":"af-south-1: not enabled for this account"}]`
	notes(items, []string{"eu-west-1", "af-south-1"}, time.Now().Add(2*time.Minute), false)
	if got := source(fmt.Sprintf(`{"op":"edit","ui_user":"test","name":%q,"regions":["us-east-2"],"swept":true}`, name)); got != "done" {
		t.Fatalf("(5) the sweep's edit: %s", got)
	}
	if got := text(`SELECT string_agg(x->>'key', ' ' ORDER BY x->>'key') FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = $1`); got != "af-south-1 eu-west-1 source" {
		t.Fatalf("(5) a sweep's edit dropped a note: %s", got)
	}
	if got := source(fmt.Sprintf(`{"op":"edit","ui_user":"test","name":%q,"regions":["eu-west-1","us-east-2"]}`, name)); got != "done" {
		t.Fatalf("(5) an edit back to two regions: %s", got)
	}
	if got := source(fmt.Sprintf(`{"op":"edit","ui_user":"test","name":%q,"regions":["us-east-2"]}`, name)); got != "done" {
		t.Fatalf("(5) the admin's edit: %s", got)
	}
	if got := text(`SELECT string_agg(x->>'key', ' ' ORDER BY x->>'key') FROM pgvigil.admin_sources, jsonb_array_elements(note_items) x WHERE name = $1`); got != "af-south-1 source" {
		t.Fatalf("(5) after the admin's edit removed eu-west-1: %s", got)
	}
	if ln := text(`SELECT last_notes FROM pgvigil.admin_sources WHERE name = $1`); strings.Contains(ln, "eu-west-1") || !strings.Contains(ln, "af-south-1: not enabled for this account (since ") {
		t.Fatalf("(5) last_notes after the edit: %s", ln)
	}
}
