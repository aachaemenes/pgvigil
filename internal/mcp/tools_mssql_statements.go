package mcp

// The two SQL Server statement tools of task 406 (PerformanceMonitor 3.13 Added 14 and 15): they read the web API's
// /api/mssql/everywhere and /api/mssql/search as every tool reads its page's API.

import (
	"context"
	"errors"
	"net/url"
	"regexp"
)

var queryHashForm = regexp.MustCompile(`^0x[0-9A-Fa-f]{1,16}$`)

func statementEverywhere(ctx context.Context, s *Server, a map[string]any) (any, error) {
	h, err := str(a, "query_hash")
	if err != nil {
		return nil, err
	}
	if !queryHashForm.MatchString(h) {
		return nil, errors.New("query_hash must be 0x and up to 16 hex digits")
	}
	q, err := window(a, 24)
	if err != nil {
		return nil, err
	}
	q.Set("hash", h)
	v, err := s.get(ctx, "/api/mssql/everywhere", q)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"query_hash": h, "from": q.Get("from"), "to": q.Get("to"), "rows": records(field(v, "rows"))}
	if n := field(v, "note"); n != nil {
		out["note"] = n
	}
	return readNote(out, v), nil
}

func findStatements(ctx context.Context, s *Server, a map[string]any) (any, error) {
	t, err := str(a, "text")
	if err != nil {
		return nil, err
	}
	q := url.Values{"q": {t}}
	if _, ok := a["instance"]; ok {
		in, err := s.resolve(ctx, a, "instance")
		if err != nil {
			return nil, err
		}
		q.Set("instance", in.ID)
	}
	v, err := s.get(ctx, "/api/mssql/search", q)
	if err != nil {
		return nil, err
	}
	return v, nil
}
