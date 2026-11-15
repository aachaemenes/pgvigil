package web

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The agent door's SELECTs (docs/agents.md): pgvigil mcp's run_select runs an agent's statement on the agent's own
// login, and serve's Run runs an answered ask's SELECT on the reports login (reports_dsn). Both go through the custom
// reports' runner (runPG): a connection opened and closed per run (an advisory lock or a set_config never outlives it),
// pgx's describe-exec protocol pinned (a dsn's default_query_exec_mode=simple_protocol cannot send several statements),
// BEGIN READ ONLY with the statement and lock timeouts set inside, the login's rule asked inside the transaction before
// the statement. The statement is wrapped as the FROM of one SELECT, so a second statement, an INSERT, an UPDATE, a
// DELETE or a data-modifying WITH is the server's syntax error, never a run.

// SelectResult is one wrapped SELECT's answer.
type SelectResult struct {
	Columns []string `json:"columns"`
	Types   []string `json:"types"`
	Rows    [][]any  `json:"rows"`
	Cut     bool     `json:"cut"` // more rows (or bytes) than the cap: the first ones kept
}

// MaxSelectText is the longest statement either door takes.
const MaxSelectText = 20000

// WrapSelect is the statement the doors run: the text, its trailing semicolons and blanks dropped, as the FROM of one
// SELECT with a row limit one past the cap (the extra row says the answer was cut). The newlines keep a trailing line
// comment from swallowing the wrap.
func WrapSelect(sql string, maxRows int) (string, error) {
	t := strings.TrimSpace(sql)
	for strings.HasSuffix(t, ";") {
		t = strings.TrimSpace(strings.TrimSuffix(t, ";"))
	}
	if t == "" {
		return "", errors.New("the statement is empty")
	}
	if len(t) > MaxSelectText {
		return "", errors.New("the statement is over 20,000 characters")
	}
	return "SELECT * FROM (\n" + t + "\n) AS q LIMIT " + strconv.Itoa(maxRows+1), nil
}

// StoreSelect runs one wrapped SELECT read-only as cfg's login under refusal (AgentStoreRefusal for the agent's login;
// the reports door's rule for serve's Run): refused is the rule's words (nothing ran), err the server's.
func StoreSelect(ctx context.Context, cfg *pgx.ConnConfig, sql string, timeout time.Duration, maxRows, maxBytes int,
	refusal func(context.Context, pgx.Tx) (string, error)) (res SelectResult, refused string, err error) {
	stmt, err := WrapSelect(sql, maxRows)
	if err != nil {
		return res, "", err
	}
	if refusal == nil {
		return res, "", errors.New("no login rule: nothing was run")
	}
	sets, why, err := runPGSized(ctx, cfg, stmt, nil, timeout, maxRows, maxBytes, refusal)
	if err != nil || why != "" {
		return res, why, err
	}
	res = SelectResult{Columns: []string{}, Types: []string{}, Rows: [][]any{}}
	if len(sets) > 0 {
		res.Columns, res.Types, res.Rows, res.Cut = sets[0].Columns, sets[0].Types, sets[0].Rows, sets[0].Truncated
	}
	return res, "", nil
}
