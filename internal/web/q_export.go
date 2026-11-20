package web

import "net/http"

// The Parquet export's own record (migration 0256): what `pgvigil export` wrote through its door, for the Collector
// page. An export that was never configured, or was turned off with -off and has no run in 90 days, has no row.
const (
	sqlExportRuns = `
SELECT r.name, r.window_from, r.window_to, r.pass, r.started_at, r.finished_at,
       round(extract(epoch FROM r.finished_at - r.started_at) * 1000)::bigint AS duration_ms,
       r.outcome, r.tables, r.files, r.rows, r.bytes, r.error
  FROM pgvigil.export_runs r ORDER BY r.started_at DESC, r.run_id DESC LIMIT 96`
	sqlExportState = `
SELECT s.name, s.destination, s.last_run_at, s.last_outcome, s.last_error, s.newest_window_to,
       CASE WHEN s.newest_window_to IS NULL THEN NULL
            ELSE floor(extract(epoch FROM now() - s.newest_window_to) / 3600)::int END AS hours_behind
  FROM pgvigil.export_state s ORDER BY s.name`
	sqlExportService = `SELECT name, detail FROM pgvigil.export_service ORDER BY name`
)

// Export answers GET /api/export: the export's last windows, its state and the service's lines about it.
func (s *Server) Export(w http.ResponseWriter, r *http.Request) {
	// a repository not migrated to 0256 yet has no record of an export: nothing to show, and no error on the page
	if hv, err := s.query(r.Context(), `SELECT to_regclass('pgvigil.export_runs') IS NOT NULL`); err != nil || len(hv.Rows) != 1 || hv.Rows[0][0] != true {
		s.reply(w, r, map[string]*table{}, err)
		return
	}
	s.multiPart(w, r, []part{{"runs", sqlExportRuns, nil}, {"state", sqlExportState, nil}, {"service", sqlExportService, nil}})
}
