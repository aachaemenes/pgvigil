package web

import (
	"context"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/engines"
	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// CheckResult is one instance's connection test for 'pgvigil check' (L181): the page's own test
// (testConnectionList), exported - who answered, and the collections that will not run there and why (N59).
type CheckResult struct {
	OK          bool
	Detail      string
	NotRun      []engines.NotRun
	Collections int
	ListNote    string // why the not-run list is missing or partial ("" = read)
}

// CheckConnection is the one connection test 'pgvigil check' runs per instance: the same 10-second connect, detect
// and not-run list the Admin > Instances page uses, so the command and the page never disagree.
func CheckConnection(ctx context.Context, engine, dsn string, sec *secrets.Ref, in config.Instance, cfg *config.Config) CheckResult {
	t := testConnectionList(ctx, engine, dsn, sec, in, cfg)
	return CheckResult{OK: t.ok, Detail: t.detail, NotRun: t.notRun, Collections: t.collections, ListNote: t.listNote}
}
