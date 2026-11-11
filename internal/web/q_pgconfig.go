package web

import (
	"errors"
	"fmt"
	"net/http"

	"github.com/jackc/pgx/v5/pgconn"
)

// The PostgreSQL Configuration grid (task 132; Darling's Configuration tab: setting, value, unit, default, source,
// what a change needs, pending restart). Route, wired in Handler:
//
//	GET /api/pgconfig?instance=<id> -> s.PGConfig
//
// settings: pgvigil.pg_config_settings, one row per setting the newest instance read stored (the server-level
// non-default ones and every setting waiting for a restart), the pending ones first. A read by a collector from
// before the detail list answers with detail_read false and the detail columns NULL.
// rules: pgvigil.pg_setting_rules (0099), one row per setting a best-practice rule covers, with the value in use and
// its status: ok (every rule that applies here is met), warn or crit (the worst broken rule), none (no rule of the
// setting is meant for this platform). The page colours the value by it.

// PGConfig serves one PostgreSQL instance's settings with their detail.
func (s *Server) PGConfig(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]*table{}
	settings, err := s.query(r.Context(), `SELECT * FROM pgvigil.pg_config_settings($1)`, id)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("settings: %w", err))
		return
	}
	out["settings"] = settings
	// The rules read arrived with migration 0099. A store this binary has not migrated yet answers 'function does
	// not exist' (42883): the reply then carries the settings alone and the page draws its Settings grid as before.
	rules, err := s.query(r.Context(), `SELECT * FROM pgvigil.pg_setting_rules($1)`, id)
	var pg *pgconn.PgError
	switch {
	case err == nil:
		out["rules"] = rules
	case errors.As(err, &pg) && pg.Code == "42883":
	default:
		s.reply(w, r, nil, fmt.Errorf("rules: %w", err))
		return
	}
	s.reply(w, r, out, nil)
}
