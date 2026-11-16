package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"strconv"
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
// lists the partitions a run would drop and changes nothing. After purge() it builds the job statistics' hours
// (0139) and the replication hours (0150) of every instance still waiting, one instance per transaction; a purge
// scheduled as SQL alone (SELECT pgvigil.purge(N) from pg_cron) does not: schedule beside it
// SELECT pgvigil.job_stats_heal_one(i) FROM pgvigil.job_stats_pending() i LIMIT 1 (one instance a run), and for the
// replication hours TWO jobs of their own, so that an instance's month partitions are committed before its build
// starts: SELECT pgvigil.replication_hourly_months(i) FROM pgvigil.replication_hourly_pending() i LIMIT 1, and
// SELECT pgvigil.replication_hourly_heal_one(i) FROM pgvigil.replication_hourly_pending() i LIMIT 1.
func runPurge(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("pgvigil purge", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	days := fs.Int("days", 30, "keep this many days; a monthly partition goes once its whole month is older")
	dry := fs.Bool("dry-run", false, "list the partitions that would be dropped and change nothing")
	hours := fs.String("hours", "", "set an hours table's own retention first: <table>=<days> (job_stats_hourly=730), several separated by commas; the months the new age no longer keeps are dropped in this run")
	confirm := fs.Bool("confirm", false, "with -hours: allow a value lower than the stored one that drops hours months (they cannot be rebuilt once their runs are purged)")
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
	// -hours: every pair checked against the store's hours tables before any is set (one bad name sets none); a value
	// lower than the stored one that drops months needs -confirm; -dry-run lists by the new values and sets nothing
	var over map[string]int
	if *hours != "" {
		sets, err := parseHoursFlag(*hours)
		if err != nil {
			return &usageError{err}
		}
		known, err := r.HoursRetention(ctx)
		if err != nil {
			return err
		}
		over = map[string]int{}
		for _, h := range sets {
			if _, ok := known[h.table]; !ok {
				names := make([]string, 0, len(known))
				for n := range known {
					names = append(names, n)
				}
				sort.Strings(names)
				list := "none"
				if len(names) > 0 {
					list = strings.Join(names, ", ")
				}
				return &usageError{fmt.Errorf("-hours: no hours table %q (the store has: %s)", h.table, list)}
			}
			over[h.table] = h.days
		}
		with, err := r.PurgeCandidates(ctx, *days, over)
		if err != nil {
			return err
		}
		stored, err := r.PurgeCandidates(ctx, *days, nil)
		if err != nil {
			return err
		}
		extra := hoursExtraDrops(with, stored, over)
		if len(extra) > 0 && !*dry && !*confirm {
			return fmt.Errorf("-hours %s would drop %d hours month(s) the stored age keeps: %s - they cannot be rebuilt once their runs are purged; "+
				"run again with -confirm to drop them (-dry-run lists what a run drops)", *hours, len(extra), strings.Join(extra, ", "))
		}
		for _, h := range sets {
			if *dry {
				fmt.Printf("purge -hours: %s would keep %d days, now %d (not set: -dry-run)\n", h.table, h.days, known[h.table])
				continue
			}
			if err := r.SetHoursRetention(ctx, h.table, h.days); err != nil {
				return err
			}
			fmt.Printf("purge -hours: %s keeps %d days (was %d)\n", h.table, h.days, known[h.table])
		}
		if len(extra) > 0 {
			verb := "are dropped by this run"
			if *dry {
				verb = "would be dropped"
			}
			fmt.Printf("purge -hours: %d hours month(s) the stored age kept %s: %s\n", len(extra), verb, strings.Join(extra, ", "))
		}
	}
	if *dry {
		parts, err := r.PurgeCandidates(ctx, *days, over)
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
	// 0139: the job statistics' hours of every instance still waiting (a failed rollup, a lapsed history import, the
	// first build after the upgrade), each instance in its own transaction
	start = time.Now()
	inst, rows, failed, err := r.JobStatsHeal(ctx)
	if err != nil {
		return err
	}
	if inst > 0 || failed > 0 {
		log.Info("job statistics healed", "instances", inst, "hour_rows", rows, "failed", failed, "ms", time.Since(start).Milliseconds())
		fmt.Printf("purge: the job statistics' hours of %d instance(s) built (%d hour rows) in %.1f s", inst, rows, time.Since(start).Seconds())
		if failed > 0 {
			fmt.Printf("; %d instance(s) failed and stay for the next run (collection log 'job_stats_hourly')", failed)
		}
		fmt.Println()
	}
	// 0150: the replication hours the same way - an instance's month partitions in a transaction of their own, then
	// its build or heal
	start = time.Now()
	inst, rows, failed, err = r.ReplicationHourlyHeal(ctx)
	if err != nil {
		return err
	}
	if inst > 0 || failed > 0 {
		log.Info("replication hours healed", "instances", inst, "hour_rows", rows, "failed", failed, "ms", time.Since(start).Milliseconds())
		fmt.Printf("purge: the replication hours of %d instance(s) built (%d hour rows) in %.1f s", inst, rows, time.Since(start).Seconds())
		if failed > 0 {
			fmt.Printf("; %d instance(s) failed and stay for the next run (collection log 'replication_hourly')", failed)
		}
		fmt.Println()
	}
	// 0167: this month's and the next month's partition of the Azure SQL Database hours (never an import's trigger's
	// ACCESS EXCLUSIVE), then the hours still waiting (the first build, a failed rollup), each instance in its own
	// transaction
	if err := r.AzureDBHourMonths(ctx); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		log.Warn("azure hours: this month's or the next month's partition not made now (a later purge run makes it)", "err", err)
	}
	start = time.Now()
	ainst, arows, afailed, err := r.AzureDBHoursHeal(ctx)
	if err != nil {
		return err
	}
	if ainst > 0 || afailed > 0 {
		log.Info("azure hours healed", "instances", ainst, "hour_rows", arows, "failed", afailed, "ms", time.Since(start).Milliseconds())
		fmt.Printf("purge: the Azure SQL Database hours of %d instance(s) built (%d hour rows) in %.1f s", ainst, arows, time.Since(start).Seconds())
		if afailed > 0 {
			fmt.Printf("; %d instance(s) failed and stay for the next run (collection log 'mssql_azuredb_hour')", afailed)
		}
		fmt.Println()
	}
	return nil
}

// hoursExtraDrops is the hours months the -hours values drop that the stored ages keep: in with (the candidates by the
// new values) and not in stored, of a table -hours names.
func hoursExtraDrops(with, stored []string, over map[string]int) []string {
	was := map[string]bool{}
	for _, s := range stored {
		was[s] = true
	}
	var out []string
	for _, w := range with {
		if was[w] || len(w) < 8 {
			continue
		}
		if _, ok := over[w[:len(w)-7]]; ok {
			out = append(out, w)
		}
	}
	return out
}

// hoursSet is one '<table>=<days>' of -hours.
type hoursSet struct {
	table string
	days  int
}

// parseHoursFlag reads -hours: '<table>=<days>' pairs separated by commas, each table a plain lower-case name named
// once and its days 1 to 3650.
func parseHoursFlag(v string) ([]hoursSet, error) {
	var out []hoursSet
	seen := map[string]bool{}
	for _, part := range strings.Split(v, ",") {
		t, d, ok := strings.Cut(strings.TrimSpace(part), "=")
		n, err := strconv.Atoi(strings.TrimSpace(d))
		t = strings.TrimSpace(t)
		if !ok || err != nil || n < 1 || n > 3650 || t == "" || seen[t] || strings.Trim(t, "abcdefghijklmnopqrstuvwxyz0123456789_") != "" {
			return nil, fmt.Errorf("-hours wants <table>=<days>, each table once, with days 1 to 3650 (job_stats_hourly=730), not %q", part)
		}
		seen[t] = true
		out = append(out, hoursSet{t, n})
	}
	return out, nil
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
