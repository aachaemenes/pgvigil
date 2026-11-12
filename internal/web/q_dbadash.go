package web

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/dbadash"
)

// The DBADash door's API (task 55): DBADash's own instances and Summary statuses, read from the DBADash repositories the
// configuration names (internal/dbadash) and kept by 0052. The join wires the route in Handler:
//   GET /api/dbadash                          -> s.DBADash: every configured repository and every present instance
//                                                (the tree's Imported folders and the fleet grid), and part
//                                                'imported': each instance's pgvigil instance (sqlDBADashImported).
//   GET /api/dbadash?repo=<name>              -> the same, narrowed to one repository.
//   GET /api/dbadash?repo=<name>&id=<n>[&from=..&to=..] -> one DBADash instance: its facts, its Summary statuses with
//                                                DBADash's words, the status changes of the window, and the imported
//                                                server's newest database sizes (part 'sizes', task 168).
//   GET /api/dbadash?repo=<name>&id=<n>&page=<key>[&from=..&to=..][&snapshot=..] -> one DBADash page (task 75): ONE
//                                                call of the page's DBADash procedure for the instance, made now through
//                                                the repository's read login (internal/dbadash pages.go); the reply is
//                                                the procedure's result sets as grids, DBADash's version and whether it
//                                                is the proven one. A procedure that fails answers 502 with SQL Server's
//                                                own message. ?page=list returns the page list.
// Every part of the folders and the instance page reads a 0052 read function, never a table, but one: 'pgvigil', the
// SQL Server instance pgvigil itself monitors under the same @@SERVERNAME (pgvigil.mssql_instance.server_name equal,
// case-insensitive, to DBADash's Instance), whose actions door (actions_dsn and its actions: list, task 99) the
// DBADash page's Kill, Start and Stop buttons use through /api/mssql/actions/*: no such instance = no button, and the
// reason. ?part= narrows the reply to one part (the tree asks for part=fleet).

// dbadashRepo reads repo=<name>: 1..100 characters, the configuration's rule (no '/' or control character).
func dbadashRepo(r *http.Request) (*string, error) {
	v := r.URL.Query().Get("repo")
	if v == "" {
		return nil, nil
	}
	if len(v) > 100 || strings.ContainsAny(v, "/\t\r\n") {
		return nil, errors.New("repo must be a configured source repository name (the dbadash: list)")
	}
	return &v, nil
}

// DBADash is the DBADash folders, the fleet grid and one DBADash instance's page.
func (s *Server) DBADash(w http.ResponseWriter, r *http.Request) {
	repo, err := dbadashRepo(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	idv := r.URL.Query().Get("id")
	if pg := r.URL.Query().Get("page"); pg != "" {
		s.dbadashPage(w, r, repo, idv, pg)
		return
	}
	if idv == "" {
		s.multiPart(w, r, []part{
			{"repositories", `SELECT * FROM pgvigil.dbadash_repositories() WHERE $1::text IS NULL OR repository = $1`, []any{repo}},
			{"fleet", `SELECT * FROM pgvigil.dbadash_fleet($1)`, []any{repo}},
			{"checks", `SELECT * FROM pgvigil.dbadash_checks()`, nil},
			{"imported", sqlDBADashImported, []any{repo}},
		})
		return
	}
	if repo == nil {
		writeErr(w, http.StatusBadRequest, errors.New("id needs repo"))
		return
	}
	id, err := strconv.Atoi(idv)
	if err != nil || id <= 0 || id > dbadash.MaxInstanceID {
		writeErr(w, http.StatusBadRequest, errors.New("id must be the source repository's InstanceID (1 to 2147483647)"))
		return
	}
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"instance", `SELECT * FROM pgvigil.dbadash_instance($1, $2)`, []any{*repo, id}},
		{"statuses", `SELECT * FROM pgvigil.dbadash_statuses($1, $2)`, []any{*repo, id}},
		{"changes", `SELECT * FROM pgvigil.dbadash_changes($1, $2, $3, $4)`, []any{*repo, id, from, to}},
		{"pgvigil", sqlDBADashPgvigil, []any{*repo, id}},
		{"sizes", sqlDBADashSizes, []any{*repo, id}},
	})
}

// sqlDBADashImported is the pgvigil SQL Server instance of each instance read through a repository the configuration
// still names (task 168): one pgvigil collects itself (its own pages: it holds a mssql_instance read under the same
// @@SERVERNAME, or it has a collection attempt of its own in collection_dates, which the import never writes), or the one
// the import made under the instance's display name (pgvigil import dbadash's default name) with neither (an imported
// server: its tabs come from the import's tables and the repository's live screens, web/src/dbadash.ts). The order is
// the preference: collected first, then a repository instance still present, then the newest collection; candidates
// counts the repository instances that match one pgvigil instance (two repositories, or a server re-added under one
// display name: the page says so). An instance imported under another name (-name) is not matched (docs/dbadash.md).
const sqlDBADashImported = `
SELECT d.repository, d.instance_id AS source_id, i.instance_id, i.name, (m.instance_id IS NOT NULL OR c.attempted) AS collected,
       d.is_present, count(*) OVER (PARTITION BY i.instance_id) AS candidates
  FROM pgvigil.dbadash_instances d
  JOIN pgvigil.dbadash_repositories r ON r.repository = d.repository AND r.is_configured
  JOIN pgvigil.instances i ON i.engine = 'sqlserver' AND i.is_active
  LEFT JOIN pgvigil.mssql_instance m ON m.instance_id = i.instance_id
  -- an attempt that got past the connect (a page instance has its row from its add, and 0118 records its failed
  -- connects: those do not make it pgvigil's own until pgvigil reaches it - the join's review of fold 1, finding 1)
  CROSS JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM pgvigil.collection_dates cd WHERE cd.instance_id = i.instance_id
                                       AND NOT (cd.status = 'error' AND cd.note LIKE 'connect: %')) AS attempted) c
 WHERE ($1::text IS NULL OR d.repository = $1)
   AND (upper(m.server_name) = upper(d.instance)
        OR (m.instance_id IS NULL AND upper(i.name) = upper(d.display_name)))
 ORDER BY (m.instance_id IS NULL AND NOT c.attempted), NOT d.is_present, d.last_collection DESC NULLS LAST, d.repository, d.instance_id`

// sqlDBADashSizes is the newest database size per database that pgvigil import dbadash stored for the imported server of
// one repository instance (sqlDBADashImported's imported match: the display name, not collected by pgvigil), largest
// first: the Storage tab of an imported server (pgvigil's own Storage page lists the databases of its own file read,
// which an imported server has not). No imported server = no row.
const sqlDBADashSizes = `
SELECT * FROM (
  SELECT DISTINCT ON (s.database_name) s.database_name, s.snapshot_at, s.data_bytes, s.log_bytes, s.data_bytes + s.log_bytes AS size_bytes,
         s.data_used_bytes, s.files
    FROM pgvigil.dbadash_instances d
    JOIN pgvigil.dbadash_repositories r ON r.repository = d.repository AND r.is_configured
    JOIN pgvigil.instances i ON i.engine = 'sqlserver' AND i.is_active AND upper(i.name) = upper(d.display_name)
    JOIN pgvigil.mssql_database_size s ON s.instance_id = i.instance_id
   WHERE d.repository = $1 AND d.instance_id = $2
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_instance m WHERE m.instance_id = i.instance_id)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.collection_dates cd WHERE cd.instance_id = i.instance_id
                       AND NOT (cd.status = 'error' AND cd.note LIKE 'connect: %'))
   ORDER BY s.database_name, s.snapshot_at DESC) x
 ORDER BY x.size_bytes DESC, x.database_name`

// sqlDBADashPgvigil is the active SQL Server instance pgvigil monitors itself under the DBADash instance's server name
// (the actions buttons' door); more than one = the lowest instance_id, said by the count. Its machine name goes to the
// page, which acts only when DBADash's own MachineName for the instance (on the sessions and jobs pages) is the same.
const sqlDBADashPgvigil = `
SELECT i.instance_id, i.name, m.server_name, m.machine_name, count(*) OVER () AS matches
  FROM pgvigil.dbadash_instances d
  JOIN pgvigil.mssql_instance m ON upper(m.server_name) = upper(d.instance)
  JOIN pgvigil.instances i ON i.instance_id = m.instance_id AND i.engine = 'sqlserver' AND i.is_active
 WHERE d.repository = $1 AND d.instance_id = $2
 ORDER BY i.instance_id
 LIMIT 1`

// pageTimeout bounds a page's whole reply (the procedure's own bound is dbadash.PageTimeout).
const pageTimeout = 70 * time.Second

// dbadashPage is GET /api/dbadash?repo=&id=&page=: one DBADash procedure called now for one instance.
func (s *Server) dbadashPage(w http.ResponseWriter, r *http.Request, repo *string, idv, page string) {
	if page == "list" {
		s.reply(w, r, struct {
			Pages  []dbadash.PageDef `json:"pages"`
			Proven string            `json:"proven"`
		}{dbadash.Pages, dbadash.ProvenVersion}, nil)
		return
	}
	def, ok := dbadash.PageByKey(page)
	if !ok {
		writeErr(w, http.StatusBadRequest, errors.New("page must be one of the source repository's screens (page=list names them)"))
		return
	}
	if repo == nil {
		writeErr(w, http.StatusBadRequest, errors.New("page needs repo"))
		return
	}
	id, err := strconv.Atoi(idv)
	if err != nil || id <= 0 || id > dbadash.MaxInstanceID {
		writeErr(w, http.StatusBadRequest, errors.New("id must be the source repository's InstanceID (1 to 2147483647)"))
		return
	}
	a := dbadash.PageArgs{InstanceID: id}
	if def.Window {
		if _, a.From, a.To, err = params(r, false); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
	}
	if v := r.URL.Query().Get("snapshot"); v != "" && def.Snapshot {
		if a.Snapshot, err = time.Parse(time.RFC3339Nano, v); err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("snapshot must be an RFC 3339 time"))
			return
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), pageTimeout)
	defer cancel()
	out, err := dbadash.Page(ctx, *repo, page, a)
	switch {
	case errors.Is(err, dbadash.ErrNoRepository):
		writeErr(w, http.StatusNotFound, err)
		return
	case err != nil && out.Procedure == "":
		// before the procedure: the connection, the login or the version read
		s.log.Warn("dbadash page: repository not read", "repository", *repo, "page", page, "err", err)
		writeErr(w, http.StatusBadGateway, err)
		return
	case err != nil:
		s.log.Warn("dbadash page: procedure failed", "repository", *repo, "page", page, "procedure", out.Procedure, "err", err)
		writeErr(w, http.StatusBadGateway, err)
		return
	}
	s.reply(w, r, out, nil)
}
