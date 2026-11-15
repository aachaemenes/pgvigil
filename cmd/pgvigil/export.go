package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/export"
)

// runExport is the repository's read-only export to Parquet (docs/parquet-export.md): one set of files and one
// manifest per clock hour, to a folder, an S3 bucket or an Azure Blob container, for a consumer outside pgvigil.
// It is off until the configuration has an export: section, and nothing in `pgvigil run` or `serve` starts it:
// the operator's scheduler does (deploy/pgvigil-export.timer), as it starts purge. A run exports every due
// window, oldest first; the destination's manifests are its only memory of what is done. It reads the repository
// as its own login, which must be unable to write, in read-only transactions.
//
// Exit: 0 every window this run took has its manifest; 1 a window is left without one, a table was given up, or an
// hour aged out; 2 usage; 3 the configuration or the login is refused.
func runExport(ctx context.Context, _ *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("pgvigil export", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	list := fs.Bool("tables-list", false, "print every table of the repository: its class, its time column, its key, or why it is left out")
	plan := fs.Bool("plan", false, "print the due windows and every table's kind; write nothing")
	status := fs.Bool("status", false, "read the destination's manifests: the newest window, the hours missing, the hours aged out")
	check := fs.Bool("check", false, "prove the configuration: the login, the map of tables, the destination (one tiny object written and removed)")
	off := fs.Bool("off", false, "take this export's row out of the repository (export_state): it is turned off and must raise no 'behind' line")
	gap := fs.Bool("gap", false, "-gap <from> <to>: accept a hole - write a gap manifest for every hour of it that has none")
	asJSON := fs.Bool("json", false, "with -tables-list, -plan or -status: JSON")
	from := fs.String("from", "", "with -to: export these hours whatever the manifests say (UTC, on the hour: 2026-01-31T14:00:00Z)")
	to := fs.String("to", "", "the end of -from's hours")
	tables := fs.String("tables", "", "with -from / -to: only these tables, comma separated; the manifest and the files carry a mark of their own")
	out := fs.String("out", "", "with -from / -to: a local folder instead of the configured destination")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	modes := 0
	for _, m := range []bool{*list, *plan, *status, *check, *gap, *off, *from != "" || *to != ""} {
		if m {
			modes++
		}
	}
	explicit := *from != "" || *to != ""
	switch {
	case modes > 1:
		return &usageError{errors.New("export: one of -tables-list, -plan, -status, -check, -gap, -off, -from / -to at a time")}
	case (*tables != "" || *out != "") && !explicit:
		return &usageError{errors.New("export: -tables and -out go with -from and -to")}
	case *asJSON && !(*list || *plan || *status):
		return &usageError{errors.New("export: -json goes with -tables-list, -plan or -status")}
	case !*gap && fs.NArg() > 0:
		return &usageError{fmt.Errorf("export: unexpected argument %q", fs.Arg(0))}
	}
	cfg, err := config.Load(*path)
	if err != nil {
		return &configError{err}
	}
	e := cfg.Export
	if e == nil {
		return &configError{fmt.Errorf("export: is not configured in %s: add an export: section to turn the Parquet export on (docs/parquet-export.md); nothing was read or written", *path)}
	}
	var dest export.Destination
	if *out != "" {
		dest = export.NewFolder(filepath.Join(*out, e.Name))
	} else if dest, err = exportDestination(ctx, e); err != nil {
		return &configError{err}
	}
	c := export.Config{Name: e.Name, DSN: e.DSN(), StateDir: e.StateDir, Dest: dest, Settle: e.Settle(), MaxAge: e.MaxAge(),
		FinalAfter: e.FinalAfter(), PerRun: e.PerRun(), MaxBytes: e.MaxBytes(), Timeout: e.Timeout(), Carry: e.Carry,
		Exclude: e.Tables.Exclude, ConfigPath: *path, NoRecord: *out != "", Version: version, Out: os.Stdout, Err: os.Stderr}
	switch {
	case *list:
		return export.List(ctx, c, *asJSON)
	case *plan:
		return export.Plan(ctx, c, *asJSON)
	case *status:
		return export.Status(ctx, c, *asJSON)
	case *check:
		return export.Check(ctx, c)
	case *off:
		return export.Off(ctx, c)
	case *gap:
		if fs.NArg() != 2 {
			return &usageError{errors.New("export: -gap <from> <to>, UTC and on the hour (2026-01-31T14:00:00Z 2026-01-31T16:00:00Z)")}
		}
		a, b, err := exportHours(fs.Arg(0), fs.Arg(1))
		if err != nil {
			return &usageError{err}
		}
		return export.Gap(ctx, c, a, b)
	case explicit:
		a, b, err := exportHours(*from, *to)
		if err != nil {
			return &usageError{err}
		}
		var only []string
		for _, t := range strings.Split(*tables, ",") {
			if t = strings.TrimSpace(t); t != "" {
				only = append(only, t)
			}
		}
		return export.RunWindows(ctx, c, a, b, only)
	}
	return export.Run(ctx, c)
}

// exportHours parses a span of whole hours.
func exportHours(from, to string) (time.Time, time.Time, error) {
	parse := func(s string) (time.Time, error) {
		t, err := time.Parse(time.RFC3339, strings.TrimSpace(s))
		if err != nil {
			return t, fmt.Errorf("export: %q is not a time like 2026-01-31T14:00:00Z", s)
		}
		t = t.UTC()
		if !t.Equal(t.Truncate(time.Hour)) {
			return t, fmt.Errorf("export: %q is not on the hour: a window is one clock hour", s)
		}
		return t, nil
	}
	a, err := parse(from)
	if err != nil {
		return a, a, err
	}
	b, err := parse(to)
	if err != nil {
		return a, b, err
	}
	if !b.After(a) {
		return a, b, errors.New("export: -to must be after -from")
	}
	return a, b, nil
}

// exportDestination opens the configured destination.
func exportDestination(ctx context.Context, e *config.Export) (export.Destination, error) {
	d := e.Destination
	switch d.Type {
	case "s3":
		return export.NewS3(ctx, export.S3Options{Bucket: d.Bucket, Prefix: d.Prefix, Region: d.Region, Endpoint: d.Endpoint, Profile: d.Profile, Name: e.Name})
	case "azure_blob":
		return export.NewAzureBlob(export.BlobOptions{AccountURL: d.AccountURL, Container: d.Container, Prefix: d.Prefix,
			ConnectionString: d.ConnectionString(), SASURL: d.SASURL(), Name: e.Name})
	}
	return export.NewFolder(filepath.Join(d.Path, e.Name)), nil
}
