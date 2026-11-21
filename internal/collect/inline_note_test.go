package collect

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestNoteInlinePasswordsOnAStore (L9, 0455): at the collector's start the heartbeat hands the repository the names of
// the file's instances whose dsn carries an inline password (import_collector_inline_passwords under its own run id),
// replacing its host's list; without a heartbeat the call does nothing.
func TestNoteInlinePasswordsOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	if err := NoteInlinePasswords(context.Background(), []string{"x"}); err != nil {
		t.Fatalf("without a heartbeat the call does nothing: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	wait, err := StartHeartbeat(ctx, log, dsn, HeartbeatInfo{Probe: "off"})
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	defer func() { cancel(); wait() }()
	sfx := time.Now().UnixNano() % 1000000000
	names := []string{fmt.Sprintf("l9n-a-%d", sfx), fmt.Sprintf("l9n-b-%d", sfx)}
	if err := NoteInlinePasswords(ctx, names); err != nil {
		t.Fatal(err)
	}
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close(context.Background()) }()
	host, _ := os.Hostname()
	rows, err := c.Query(ctx, `SELECT instance FROM pgvigil.collector_inline_password WHERE host = $1 AND instance LIKE $2`, host, fmt.Sprintf("l9n-%%-%d", sfx))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			t.Fatal(err)
		}
		got = append(got, n)
	}
	rows.Close()
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(names, ",") {
		t.Errorf("the host's rows %v, want %v", got, names)
	}
	if err := NoteInlinePasswords(ctx, nil); err != nil {
		t.Fatal(err)
	}
}
