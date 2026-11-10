package web

import (
	"errors"
	"net/http"
	"strings"
)

// searchLimit is how many databases and how many tables one search shows; one more row is read to say "more".
const searchLimit = 50

// sqlSearch finds databases and tables by a part of their name across every active instance: the databases and
// tables collections' current rows (a dropped one is not listed). $1 is the LIKE pattern, $2 the text as typed (an
// exact name sorts first), $3 the row cap per kind. A table matches by its name or by schema.name.
const sqlSearch = `
SELECT * FROM (
  SELECT 'database' AS kind, d.instance_id, i.name AS instance, d.dbid, NULL::bigint AS relid, d.datname,
         NULL::text AS schema_name, NULL::text AS table_name, d.size_bytes AS bytes
    FROM pgvigil.databases d JOIN pgvigil.instances i USING (instance_id)
   WHERE i.is_active AND d.is_present AND d.datname ILIKE $1
   ORDER BY (lower(d.datname) = lower($2)) DESC, d.datname, i.name
   LIMIT $3) a
UNION ALL
SELECT * FROM (
  SELECT 'table', t.instance_id, i.name, t.dbid, t.relid, t.datname, t.schema_name, t.table_name, t.total_bytes
    FROM pgvigil.tables t JOIN pgvigil.instances i USING (instance_id)
   WHERE i.is_active AND t.is_present AND (t.table_name ILIKE $1 OR t.schema_name || '.' || t.table_name ILIKE $1)
   ORDER BY (lower(t.table_name) = lower($2)) DESC, t.table_name, i.name, t.datname, t.schema_name
   LIMIT $3) b`

// likePattern turns typed text into a contains-pattern for ILIKE: the wildcards and the escape character a name
// may hold (my_table, 100%) match themselves.
func likePattern(q string) string {
	return "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q) + "%"
}

// search serves /api/search?q=<text>: the databases and tables whose name holds the text, fleet-wide.
func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if len(q) < 2 || len(q) > 128 {
		writeErr(w, http.StatusBadRequest, errors.New("q: 2 to 128 characters"))
		return
	}
	t, err := s.query(r.Context(), sqlSearch, likePattern(q), q, searchLimit+1)
	s.reply(w, r, t, err)
}
