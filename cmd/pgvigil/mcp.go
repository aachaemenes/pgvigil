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
// -config gives the stale check each instance's collection intervals and each instance's query_text policy, as serve
// has them; without it no policy is known and every instance is read as 'none' (no statement text, plan or deadlock
// graph is returned: the locked-down default, which an admin relaxes by giving -config). The read tools are answered
// by the JSON API's own handler in process; the agent door's tools by the repository's agent functions on one
// read-write connection of the same login, and run_select on a read-only connection of its own per call. No port is
// opened and nothing is sent anywhere but the client's pipe. Logs go to stderr (stdout is the protocol).
func runMCP(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
	dsnFlag := fs.String("dsn", "env:PGVIGIL_MCP_DSN", "the reader login's connection string (or env:NAME / file:path)")
	path := fs.String("config", "", "configuration file for the instances' collection intervals and query_text policies (without it every instance is read as 'none': no statement text, plan or deadlock graph is returned)")
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
	cfg := &config.Config{}
	exp := expectedIntervals(cfg) // every collection's default interval
	if *path != "" {
		var err error
		if cfg, err = config.Load(*path); err != nil {
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
	// a page instance's own intervals for the stale check, as serve's (ST5a's review F1); mcp's doors stay the file's
	go srv.WatchPageIntervals(ctx, log, cfg, web.DoorEvery, func(in config.Instance) map[string]int { return instanceIntervals(cfg, in) })
	// TEXT-NOW: the statement text a tool returns follows each instance's query_text policy as the file states it now
	// (internal/web/textread.go), as serve's pages do. With no file no policy is known and the door fails closed:
	// every instance is read as 'none' (an instance the file does not name takes the file's default, as in serve;
	// with no file the default is 'none'), said in its log
	pc := web.PlansConfig{QueryText: map[string]string{}, DefaultQueryText: "none"}
	// a file was given (cfg is never nil here: the page intervals' watcher reads the empty default without one)
	if *path != "" {
		pc.DefaultQueryText = cfg.QueryText
		for _, in := range cfg.Instances {
			pc.QueryText[in.Name] = in.QueryText
		}
	} else {
		log.Warn("pgvigil mcp without -config: no instance's query_text policy is known, so every instance is read as 'none' (no statement text, plan or deadlock graph is returned); give -config with the file serve reads to return what each instance's policy allows")
	}
	srv.SetPlans(pc)
	log.Info("pgvigil mcp ready on stdio", "login", user, "agent", login.Agent, "version", version)
	m := mcp.New(srv.Handler(), version, secret)
	if door != nil {
		m.WithAgent(door)
	}
	return m.Serve(ctx, os.Stdin, os.Stdout)
}
