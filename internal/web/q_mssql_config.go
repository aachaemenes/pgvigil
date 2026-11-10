package web

import "net/http"

// The Configuration tab of a SQL Server instance: every value of sys.configurations as the base collection
// (mssql_instance, hourly) last read it, the values whose value in use changed between two reads (the previous
// value and the time of the read that saw the change: one change per value is kept), and the services the server
// lists (mssql_services).
const sqlMSSQLConfigValues = `
SELECT name, value, value_in_use, minimum, maximum, is_dynamic, is_advanced, previous_in_use, changed_at, is_present, snapshot_at,
       value IS DISTINCT FROM value_in_use
       -- the engine resolves a 0 in 'min server memory (MB)' to its own floor (16 in use on a default 2022 server): not
       -- pending; a 0 set over a larger value in use (1024, say) still waits for RECONFIGURE and stays pending
       AND NOT (name = 'min server memory (MB)' AND value = 0 AND value_in_use <= 16) AS pending
  FROM pgvigil.mssql_config
 WHERE instance_id = $1
 ORDER BY name`

const sqlMSSQLConfigServices = `
SELECT service_name, status, startup_type, service_account, process_id, last_startup_at, is_clustered, ifi_enabled, is_present, snapshot_at
  FROM pgvigil.mssql_service
 WHERE instance_id = $1
 ORDER BY is_present DESC, service_name`

// MSSQLConfig is GET /api/mssql/config?instance=N[&part=...].
func (s *Server) MSSQLConfig(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"values", sqlMSSQLConfigValues, []any{id}},
		{"services", sqlMSSQLConfigServices, []any{id}},
	})
}
