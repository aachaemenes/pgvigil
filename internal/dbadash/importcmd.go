package dbadash

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// ImportUsage is the command's usage line.
const ImportUsage = `pgvigil import dbadash -config <file> -repo <name> [-instance <id>,...] [-from <time>] [-to <time>] [-name <id>=<pgvigil name>,...] [-dry-run]`

// ImportCommand is `pgvigil import dbadash ...` (args are the words after "import"): it reads the DBA Dash
// repository the configuration's dbadash: list names with -repo, through its dsn (the door's read login), and loads
// its history into the configuration's pgvigil repository, whose dsn must be the repository owner's (the one
// 'pgvigil migrate' uses). It prints a line per instance and mapping, and a total.
func ImportCommand(ctx context.Context, log *slog.Logger, out io.Writer, args []string) error {
	if len(args) == 0 || args[0] != "dbadash" {
		return fmt.Errorf("usage: %s", ImportUsage)
	}
	fs := flag.NewFlagSet("import dbadash", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	cfgPath := fs.String("config", "pgvigil.yaml", "configuration file")
	repo := fs.String("repo", "", "the DBA Dash repository's name in the configuration's dbadash: list")
	insts := fs.String("instance", "", "DBA Dash InstanceIDs, comma-separated (default: every active SQL Server instance)")
	from := fs.String("from", "", "the oldest history to take, RFC 3339 (default: everything DBA Dash keeps)")
	to := fs.String("to", "", "the newest history to take, RFC 3339 (default: now)")
	names := fs.String("name", "", "<DBA Dash InstanceID>=<pgvigil instance name>, comma-separated (default: DBA Dash's display name)")
	dry := fs.Bool("dry-run", false, "count only; write nothing")
	if err := fs.Parse(args[1:]); err != nil {
		return fmt.Errorf("%w\nusage: %s", err, ImportUsage)
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("unexpected %q\nusage: %s", fs.Arg(0), ImportUsage)
	}
	opt, err := importFlags(*insts, *from, *to, *names, *dry)
	if err != nil {
		return fmt.Errorf("%w\nusage: %s", err, ImportUsage)
	}
	if strings.TrimSpace(*repo) == "" {
		return fmt.Errorf("-repo is required\nusage: %s", ImportUsage)
	}
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		return err
	}
	var src *config.DBADashRepo
	for i := range cfg.DBADash {
		if strings.EqualFold(cfg.DBADash[i].Name, *repo) {
			src = &cfg.DBADash[i]
		}
	}
	if src == nil {
		return fmt.Errorf("no DBA Dash repository named %q in the configuration's dbadash: list", *repo)
	}
	got, err := Import(ctx, log, src.DSN(), cfg.Repository.DSN(), opt)
	var source, inserted int64
	for _, c := range got {
		source += c.Source
		inserted += c.Inserted
		line := fmt.Sprintf("%-30s dbadash %-5d pgvigil %-5d %-8s source %-8d inserted %-8d stored %d", c.Instance, c.DBADashID, c.PgvigilID, c.Mapping, c.Source, c.Inserted, c.Stored)
		if c.Skipped != "" {
			line += "  skipped: " + c.Skipped
		}
		_, _ = fmt.Fprintln(out, line)
	}
	mode := "imported"
	if opt.DryRun {
		mode = "dry run, nothing written"
	}
	_, _ = fmt.Fprintf(out, "total: %d DBA Dash row(s), %d inserted (%s)\n", source, inserted, mode)
	return err
}

// importFlags turns the command's flag values into ImportOptions.
func importFlags(insts, from, to, names string, dry bool) (ImportOptions, error) {
	opt := ImportOptions{DryRun: dry, Names: map[int]string{}}
	for _, s := range splitList(insts) {
		id, err := strconv.Atoi(s)
		if err != nil || id <= 0 {
			return opt, fmt.Errorf("-instance: %q is not a DBA Dash InstanceID", s)
		}
		opt.Instances = append(opt.Instances, id)
	}
	var err error
	if from != "" {
		if opt.From, err = time.Parse(time.RFC3339, from); err != nil {
			return opt, fmt.Errorf("-from: %w", err)
		}
	}
	if to != "" {
		if opt.To, err = time.Parse(time.RFC3339, to); err != nil {
			return opt, fmt.Errorf("-to: %w", err)
		}
	}
	if !opt.From.IsZero() && !opt.To.IsZero() && !opt.From.Before(opt.To) {
		return opt, errors.New("-from must be before -to")
	}
	for _, s := range splitList(names) {
		k, v, ok := strings.Cut(s, "=")
		id, err := strconv.Atoi(strings.TrimSpace(k))
		if !ok || err != nil || id <= 0 || strings.TrimSpace(v) == "" {
			return opt, fmt.Errorf("-name: %q is not <InstanceID>=<name>", s)
		}
		opt.Names[id] = strings.TrimSpace(v)
	}
	return opt, nil
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
