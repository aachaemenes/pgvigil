package web

import "net/http"

// The PostgreSQL Configuration grid (task 132; Darling's Configuration tab: setting, value, unit, default, source,
// what a change needs, pending restart). Route, wired in Handler:
//
//	GET /api/pgconfig?instance=<id> -> s.PGConfig
//
// settings: pgvigil.pg_config_settings, one row per setting the newest instance read stored (the server-level
// non-default ones and every setting waiting for a restart), the pending ones first. A read by a collector from
// before the detail list answers with detail_read false and the detail columns NULL.

// PGConfig serves one PostgreSQL instance's settings with their detail.
func (s *Server) PGConfig(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"settings", `SELECT * FROM pgvigil.pg_config_settings($1)`, []any{id}},
	})
}
