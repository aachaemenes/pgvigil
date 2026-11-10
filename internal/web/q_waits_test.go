package web

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestWaitsSQLLive runs the Waits tab's own statements against a repository (scripts/proof-waits.sh sets
// PGVIGIL_WAITS_REPO_DSN and WAITS_INSTANCE) and checks every event line "<source> <type>:<event> <samples>" the
// proof expects (WAITS_EXPECT, one regexp per line, each must match a line) and, with WAITS_TREE, the lock tree lines
// "<level> <pid> <blocked> <state> <wait>" of the pids it names.
func TestWaitsSQLLive(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_WAITS_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_WAITS_REPO_DSN not set")
	}
	id, err := strconv.Atoi(os.Getenv("WAITS_INSTANCE"))
	if err != nil {
		t.Fatal("WAITS_INSTANCE")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	to := time.Now().Add(time.Minute)
	from := to.Add(-time.Hour)
	lines := func(sql string, args ...any) []string {
		rows, err := conn.Query(ctx, sql, args...)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			v, err := rows.Values()
			if err != nil {
				t.Fatal(err)
			}
			f := make([]string, len(v))
			for i, x := range v {
				f[i] = fmt.Sprint(x)
			}
			out = append(out, strings.Join(f, "|"))
		}
		if rows.Err() != nil {
			t.Fatal(rows.Err())
		}
		return out
	}
	// source|event_type|event|samples|wait_secs|pct
	var ev []string
	for _, l := range lines(sqlWaitsEvents, id, from, to) {
		f := strings.Split(l, "|")
		ev = append(ev, fmt.Sprintf("%s %s:%s %s", f[0], f[1], f[2], f[3]))
	}
	t.Logf("events:\n%s", strings.Join(ev, "\n"))
	if s := lines(sqlWaitsSeries, id, from, to); len(s) == 0 {
		t.Error("no series rows")
	}
	t.Logf("queries: %d rows", len(lines(sqlWaitsQueries, id, from, to)))
	for _, want := range strings.Split(strings.TrimSpace(os.Getenv("WAITS_EXPECT")), "\n") {
		if want == "" {
			continue
		}
		re := regexp.MustCompile(want)
		ok := false
		for _, e := range ev {
			ok = ok || re.MatchString(e)
		}
		if !ok {
			t.Errorf("no event matches %q", want)
		}
	}
	if pids := os.Getenv("WAITS_TREE_PIDS"); pids != "" {
		var tree []string
		for _, l := range lines(sqlWaitsLockTree, id, time.Now()) {
			// snapshot_at|top_blocker|level|pid|blocked_by|blocked|state|wait|...
			f := strings.Split(l, "|")
			for _, p := range strings.Fields(pids) {
				if f[3] == p {
					tree = append(tree, strings.Join([]string{f[2], f[3], f[5], f[6], f[7]}, " "))
				}
			}
		}
		got := strings.Join(tree, "\n")
		t.Logf("lock tree:\n%s", got)
		if want := os.Getenv("WAITS_TREE"); got != want {
			t.Errorf("lock tree:\n%s\nwant:\n%s", got, want)
		}
	}
}
