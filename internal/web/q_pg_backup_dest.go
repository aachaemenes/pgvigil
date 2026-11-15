package web

// Where a PostgreSQL server's base backups and WAL go (task 302; migration 0148). The lead's WIRING (scripts/inv-302-
// wiring.patch) adds the routes in Handler and the write door's route to demodoor.go's lists:
//	GET  /api/pg/backup_dest         s.PgBackupDest       one instance: base backups to, WAL to, restore from (read beside
//	                                                      entered), every destination with its source, the tool reads, the findings
//	GET  /api/pg/backup_dest/fleet   s.PgBackupDestFleet  every instance's 'base backups to' and 'WAL to'
//	POST /api/pg/backup_dest         s.PgBackupDestWrite  a person's destination through pgvigil.import_backup_dest_entry (the
//	                                                      UI login, the X-Pgvigil header, the write door's audit pool, as q_pg_backups.go)
// Nothing here holds a command's text: the destinations were built from checked pieces at the read.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// doorPgBackupDest is the entry's write route (demodoor.go's scope lists take it in the WIRING patch).
const doorPgBackupDest doorRoute = "pg/backup_dest"

const sqlPgBackupDestinations = `
SELECT role, label, platform_line, read_text, read_at, secret_seen, confirmed, not_known, entered_text, entered_note, entered_by, entered_at,
       entered_beside_read
  FROM pgvigil.pg_backup_destinations WHERE instance_id = $1 ORDER BY ord`

const sqlPgBackupDestRows = `
SELECT role, source, seq, tool, dest_kind, host, container, path, repo_key, detail, secret_seen, snapshot_at
  FROM pgvigil.pg_backup_dest WHERE instance_id = $1
 ORDER BY CASE role WHEN 'base' THEN 1 WHEN 'wal' THEN 2 ELSE 3 END, source, seq`

const sqlPgBackupDestReads = `
SELECT tool, name, state, message, snapshot_at FROM pgvigil.pg_backup_dest_reads WHERE instance_id = $1 ORDER BY tool, name`

const sqlPgBackupDestSettings = `
SELECT snapshot_at, is_replica, archive_mode, archive_command_set, archive_library_set, restore_command_set, standby_archives
  FROM pgvigil.pg_backup_dest_settings WHERE instance_id = $1`

const sqlPgBackupDestFindings = `
SELECT severity, check_name, object, detail, at FROM pgvigil.pg_backup_dest_findings WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, check_name`

const sqlPgBackupDestHistory = `
SELECT role, dest_text, note, entered_by, entered_at, ended_at, ended_by FROM pgvigil.pg_backup_dest_entered WHERE instance_id = $1
 ORDER BY entered_at DESC LIMIT 20`

// PgBackupDest is one instance's destinations (the Base backups tab's 'Where the backups go').
func (s *Server) PgBackupDest(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"destinations", sqlPgBackupDestinations, []any{id}},
		{"dests", sqlPgBackupDestRows, []any{id}},
		{"reads", sqlPgBackupDestReads, []any{id}},
		{"settings", sqlPgBackupDestSettings, []any{id}},
		{"findings", sqlPgBackupDestFindings, []any{id}},
		{"history", sqlPgBackupDestHistory, []any{id}},
	})
}

const sqlPgBackupDestFleet = `
SELECT d.instance_id, i.name AS instance, max(coalesce(d.read_text, d.platform_line, d.entered_text, d.not_known)) FILTER (WHERE d.role = 'base') AS base_to,
       max(coalesce(d.read_text, d.platform_line, d.entered_text, d.not_known)) FILTER (WHERE d.role = 'wal') AS wal_to,
       bool_or(d.entered_text IS NOT NULL AND d.read_text IS NULL) AS entered_only, bool_or(d.secret_seen) AS secret_seen
  FROM pgvigil.pg_backup_destinations d JOIN pgvigil.instances i ON i.instance_id = d.instance_id
 GROUP BY d.instance_id, i.name ORDER BY i.name`

// PgBackupDestFleet is every PostgreSQL instance's 'base backups to' and 'WAL to' (the fleet Backups section).
func (s *Server) PgBackupDestFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{{"fleet", sqlPgBackupDestFleet, nil}})
}

// PgBackupDestWrite is POST /api/pg/backup_dest: one person's destination for one role of one instance (an empty text
// ends the entry in force). The function refuses a credential, a control character, an over-long text; a refusal is
// 409 with its reason. Who may write is the write door's (admin once the roles join).
func (s *Server) PgBackupDestWrite(w http.ResponseWriter, r *http.Request) {
	seat, ok := s.seat(w, r, strings.Replace(s.ackOff(), "acknowledgements", "backup destinations", 1))
	if !ok {
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	if err != nil || len(raw) > 4096 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 4 KB"))
		return
	}
	var in struct {
		InstanceID int    `json:"instance_id"`
		Role       string `json:"role"`
		Text       string `json:"text"`
		Note       string `json:"note"`
	}
	if err := json.Unmarshal(raw, &in); err != nil || in.InstanceID <= 0 {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: an instance_id, a role and a text: %v", err))
		return
	}
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	pool, ok := seat.poolFor(wctx, w, writeScope{Route: doorPgBackupDest, InstanceID: in.InstanceID, OneInstance: true})
	if !ok {
		return
	}
	var entry *int64
	err = pool.QueryRow(wctx, `SELECT pgvigil.import_backup_dest_entry($1, $2, $3, $4, $5)`, in.InstanceID, in.Role, in.Text, in.Note, seat.user).Scan(&entry)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		// the function's own words (RAISE EXCEPTION): never the text that was refused
		msg := err.Error()
		if i := strings.Index(msg, "ERROR: "); i >= 0 {
			msg = msg[i+len("ERROR: "):]
		}
		if i := strings.Index(msg, " (SQLSTATE"); i >= 0 {
			msg = msg[:i]
		}
		s.log.Info("pg backup destination: refused", "instance", in.InstanceID, "role", in.Role, "user", seat.user, "why", msg)
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "refused", "detail": msg})
		return
	}
	s.log.Info("pg backup destination: entered", "instance", in.InstanceID, "role", in.Role, "user", seat.user, "ended_only", entry == nil)
	_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "done", "entry_id": entry})
}
