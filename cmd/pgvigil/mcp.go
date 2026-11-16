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

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mcp"
	"github.com/aachaemenes/pgvigil/internal/web"
)

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
	path := fs.String("config", "", "configuration file for the instances' collection intervals and query_text policies (optional; without it statement text is returned as stored)")
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
	var cfg *config.Config
	if *path != "" {
		var err error
		cfg, err = config.Load(*path)
		if err != nil {
			return &configError{err}
		}
		// the custom: list (task 61): the stale check counts the custom collection where a check applies
		if err := collect.LoadCustomChecks(*path, cfg.Instances); err != nil {
			return &configError{err}
		}
		exp = expectedIntervals(cfg)
	}
	user, err := mcp.CheckReader(ctx, dsn)
	if err != nil {
		return &configError{err}
	}
	// no Hosts (no listener), no login (the client's own child process), no actions: read only
	srv, err := web.Open(ctx, log, dsn, web.Options{Expected: exp, AppName: "pgvigil-mcp"})
	if err != nil {
		return err
	}
	defer srv.Close()
	// TEXT-NOW: the statement text a tool returns follows each instance's query_text policy as the file states it now
	// (internal/web/textread.go), as serve's pages do; with no file the door cannot know a policy and returns the text
	// as it was stored, said in its log
	if cfg != nil {
		pc := web.PlansConfig{QueryText: map[string]string{}, DefaultQueryText: cfg.QueryText}
		for _, in := range cfg.Instances {
			pc.QueryText[in.Name] = in.QueryText
		}
		srv.SetPlans(pc)
	} else {
		log.Warn("pgvigil mcp without -config: statement text is returned as it was stored, not under each instance's query_text policy now; give -config so a policy changed since applies")
	}
	log.Info("pgvigil mcp ready on stdio", "login", user, "version", version)
	return mcp.New(srv.Handler(), version, secret).Serve(ctx, os.Stdin, os.Stdout)
}
