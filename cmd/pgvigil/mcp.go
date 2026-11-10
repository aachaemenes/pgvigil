package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mcp"
	"github.com/aachaemenes/pgvigil/internal/web"
)

// the dispatch line in main.go comes at the join; until then this keeps the branch lint-clean on its own

// runMCP serves the Model Context Protocol on stdin and stdout for an AI client on this machine:
//
//	pgvigil mcp [-dsn env:PGVIGIL_MCP_DSN] [-config pgvigil.yaml]
//
// -dsn is the repository login, IN ROLE pgvigil_reader alone (checked before the first message:
// a superuser, the owner, a writer, the collector or pgvigil_auth is refused). -config is optional:
// it gives the stale check each instance's collection intervals, as serve has them. Every tool is
// read-only and answered by the JSON API's own handler in process; no port is opened and nothing
// is sent anywhere but the client's pipe. Logs go to stderr (stdout is the protocol).
func runMCP(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	dsnFlag := fs.String("dsn", "env:PGVIGIL_MCP_DSN", "the reader login's connection string (or env:NAME / file:path)")
	path := fs.String("config", "", "configuration file for the instances' collection intervals (optional)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return &configError{fmt.Errorf("mcp takes no arguments (got %q)", fs.Args())}
	}
	dsn := strings.TrimSpace(config.Resolve(*dsnFlag))
	if dsn == "" {
		return &configError{fmt.Errorf("-dsn %s resolves to nothing: set it to the reader login's connection string", *dsnFlag)}
	}
	var secret string
	if pc, err := pgx.ParseConfig(dsn); err == nil {
		secret = pc.Password
	} else {
		return &configError{errors.New("-dsn does not parse as a PostgreSQL connection string")}
	}
	exp := expectedIntervals(&config.Config{}) // every collection's default interval
	if *path != "" {
		cfg, err := config.Load(*path)
		if err != nil {
			return &configError{err}
		}
		exp = expectedIntervals(cfg)
	}
	user, err := mcp.CheckReader(ctx, dsn)
	if err != nil {
		return &configError{err}
	}
	// no Hosts (no listener), no login (the client's own child process), no actions: read only
	srv, err := web.Open(ctx, log, dsn, web.Options{Expected: exp})
	if err != nil {
		return err
	}
	defer srv.Close()
	log.Info("pgvigil mcp ready on stdio", "login", user, "version", version)
	return mcp.New(srv.Handler(), version, secret).Serve(ctx, os.Stdin, os.Stdout)
}
