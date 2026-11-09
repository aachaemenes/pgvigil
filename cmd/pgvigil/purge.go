package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// runPurge is the repository's retention: pgvigil.purge(days) drops a monthly partition once its
// whole month is older than days (so a daily purge keeps between days and about days + 31 on
// disk) and deletes the row-level series (job runs, activity summaries, statement info, texts no
// sample names any more, the collection log) past the same age. It runs as the repository owner
// (the config's repository DSN, as migrate does: purge() is the owner's alone, the collector and
// the UI logins cannot call it). pgvigil does not schedule it; the operator does
// (deploy/pgvigil-purge.timer, pg_cron on the repository, a Windows scheduled task). -dry-run
// lists the partitions a run would drop and changes nothing.
func runPurge(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("pgvigil purge", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	days := fs.Int("days", 30, "keep this many days; a monthly partition goes once its whole month is older")
	dry := fs.Bool("dry-run", false, "list the partitions that would be dropped and change nothing")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	if err := checkPurgeDays(*days); err != nil {
		return err
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return &configError{err}
	}
	r, err := repo.Open(ctx, cfg.Repository.DSN())
	if err != nil {
		return err
	}
	defer r.Close()
	if *dry {
		parts, err := r.PurgeCandidates(ctx, *days)
		if err != nil {
			return err
		}
		if len(parts) == 0 {
			fmt.Printf("purge -days %d would drop no partition (the row-level deletes are not listed)\n", *days)
			return nil
		}
		fmt.Printf("purge -days %d would drop %d partition(s): %s\n", *days, len(parts), strings.Join(parts, ", "))
		return nil
	}
	start := time.Now()
	n, err := r.Purge(ctx, *days)
	if err != nil {
		return err
	}
	d := time.Since(start)
	log.Info("purge done", "days", *days, "removed", n, "ms", d.Milliseconds())
	fmt.Printf("purge -days %d: %d partitions and rows removed in %.1f s\n", *days, n, d.Seconds())
	return nil
}

// checkPurgeDays refuses a retention under one day: purge(0) would delete every row of the
// row-level series up to this moment.
func checkPurgeDays(days int) error {
	if days < 1 {
		return &usageError{fmt.Errorf("-days %d: the retention is at least 1 day", days)}
	}
	return nil
}

// usageError is a bad command line: exit 2, as an unknown command exits.
type usageError struct{ err error }

func (e *usageError) Error() string { return e.err.Error() }
func (e *usageError) Unwrap() error { return e.err }
func (e *usageError) ExitCode() int { return 2 }
