package web

// Where a PostgreSQL server's base backups and WAL go (task 302; migration 0148). Its routes are
// added in Handler (no demodoor.go hunk: the demo door refuses the write, and the GET says so):
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

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// doorPgBackupDest is the entry's write route; the demo door does not carry it (its allow list's default: refused), and
// the GET's 'door' part says so to the page.
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
		// the write's off words where the route refuses it whatever the seat says: a demo serve carries no entry (its
		// door names the routes it takes, and this is not one), so the page never offers a live Edit the route answers 403
		{"door", `SELECT $1::text AS off`, []any{s.backupDestDoorOff()}},
	})
}

// backupDestDoorOff is why an entry cannot be written on this server whatever the seat says ("" = the seat decides).
func (s *Server) backupDestDoorOff() string {
	if s.demo != nil {
		return "a destination is not entered through the demo: it needs pgvigil serve with a signed-in user"
	}
	return ""
}

// sqlPgBackupDestFleet: EVERY active PostgreSQL instance (an rsync, cp, wal-g or basic_archive server and one with
// archive_mode off are exactly the ones no tool row names: F9), its read 'base backups to' and 'WAL to' (or the
// platform's line, or 'not known'), a person's entries apart from them (never as if read: F10), and base_not_read -
// 162's tool row kept off by the read_tools opt-in, so the Summary's Backup FULL cell is grey, never green (F1).
const sqlPgBackupDestFleet = `
SELECT i.instance_id, i.name AS instance,
       max(coalesce(d.read_text, d.platform_line, d.not_known)) FILTER (WHERE d.role = 'base') AS base_to,
       max(coalesce(d.read_text, d.platform_line, d.not_known)) FILTER (WHERE d.role = 'wal') AS wal_to,
       max(d.entered_text) FILTER (WHERE d.role = 'base') AS base_entered, max(d.entered_text) FILTER (WHERE d.role = 'wal') AS wal_entered,
       coalesce(bool_or(d.secret_seen), false) AS secret_seen,
       EXISTS (SELECT 1 FROM pgvigil.pg_backup_tools t WHERE t.instance_id = i.instance_id AND t.is_present AND t.state = 'not_read') AS base_not_read
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.pg_backup_destinations d ON d.instance_id = i.instance_id
 WHERE i.is_active AND i.engine = 'postgres'
 GROUP BY i.instance_id, i.name ORDER BY i.name`

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
	// F19: the first gate is the collector's own secret rule over every word (an option or a NAME=VALUE whose name is a
	// credential's, a URL's user:password@ or signature, user:password@host, sshpass -p, curl -u user:password, a
	// secret-shaped word with a value after it); 0148's function is the second
	if collect.EntryHoldsSecret(in.Text + " " + in.Note) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "refused", "detail": "an entry never holds a credential: name where the backups go, not how to reach it"})
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
		// the function's own words (RAISE EXCEPTION, SQLSTATE P0001) are a refusal (409): never the text that was
		// refused; any other failure (the pool, a timeout) is the server's (500), in words that hold no entry text
		var pe *pgconn.PgError
		if !errors.As(err, &pe) || pe.Code != "P0001" {
			s.log.Warn("pg backup destination: the write failed", "instance", in.InstanceID, "role", in.Role, "user", seat.user, "err", err)
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "failed", "detail": "the entry could not be written (the server's log has the error)"})
			return
		}
		msg := pe.Message
		s.log.Info("pg backup destination: refused", "instance", in.InstanceID, "role", in.Role, "user", seat.user, "why", msg)
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "refused", "detail": msg})
		return
	}
	s.log.Info("pg backup destination: entered", "instance", in.InstanceID, "role", in.Role, "user", seat.user, "ended_only", entry == nil)
	_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "done", "entry_id": entry})
}
