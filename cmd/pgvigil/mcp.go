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
// a superuser, the owner, a writer, the collector or pgvigil_auth is refused) - or, for the agent door
// (docs/agents.md), IN ROLE pgvigil_reader, pgvigil_agent and nothing else, checked on its session user.
// -config is optional: it gives the stale check each instance's collection intervals, as serve has them.
// The read tools are answered by the JSON API's own handler in process; the agent door's tools by the
// repository's agent functions on one read-write connection of the same login, and run_select on a
// read-only connection of its own per call. No port is opened and nothing is sent anywhere but the
// client's pipe. Logs go to stderr (stdout is the protocol).
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
		// the custom: list (task 61): the stale check counts the custom collection where a check applies
		if err := collect.LoadCustomChecks(*path, cfg.Instances); err != nil {
			return &configError{err}
		}
		exp = expectedIntervals(cfg)
	}
	login, err := mcp.CheckLogin(ctx, dsn, web.AgentStoreRefusal)
	if err != nil {
		return &configError{err}
	}
	user := login.User
	var door *mcp.AgentDoor
	if login.Agent {
		if door, err = mcp.NewAgentDoor(ctx, dsn); err != nil {
			return err
		}
		defer door.Close()
		selCfg, err := pgx.ParseConfig(dsn)
		if err != nil {
			return &configError{errors.New("-dsn does not parse as a PostgreSQL connection string")}
		}
		door.Wrap = web.WrapSelect
		door.Select = func(ctx context.Context, sql string) ([]string, []string, [][]any, bool, string, error) {
			r, why, err := web.StoreSelect(ctx, selCfg, "pgvigil-mcp-select", sql, 15*time.Second, 1000, 1<<20, web.AgentStoreRefusal)
			return r.Columns, r.Types, r.Rows, r.Cut, why, err
		}
	}
	// no Hosts (no listener), no login (the client's own child process), no actions: read only
	srv, err := web.Open(ctx, log, dsn, web.Options{Expected: exp, AppName: "pgvigil-mcp"})
	if err != nil {
		return err
	}
	defer srv.Close()
	log.Info("pgvigil mcp ready on stdio", "login", user, "agent", login.Agent, "version", version)
	m := mcp.New(srv.Handler(), version, secret)
	if door != nil {
		m.WithAgent(door)
	}
	return m.Serve(ctx, os.Stdin, os.Stdout)
}
