package web

// The PostgreSQL twins of DBA Dash's backup, role-change and state cells (task 162; migration 0103). The join wires the
// routes in Handler:
//	GET  /api/pg/backups            s.PgBackups           one instance: the base backups by tool, the file-fed replay, the thresholds
//	GET  /api/pg/backups/fleet      s.PgBackupsFleet      every instance's base-backup status and standby replay
//	GET  /api/pg/state              s.PgState             one instance: role changes, crashes, the statement store, uptime, amcheck age
//	GET  /api/pg/replication        s.PgReplicationFleet  the fleet's clusters, links, Patroni members and role changes
//	GET  /api/pg/thresholds         s.PgThresholds        the keys, the live rows, the tags and instances to set them on
//	POST /api/pg/thresholds         s.PgThresholdWrite    one attempt through pgvigil.import_pg_threshold (the UI login,
//	                                                      the X-Pgvigil header, the actions door's audit pool, as q_ack.go)
// The overview checks below feed the Summary: 'base backups' and 'log shipping' (the Backups column), 'crashes' (the
// Memory dumps column, its PostgreSQL twin), 'statement store' (the QS column), 'uptime' and 'amcheck age' (the
// Corruption column); each is pgvigil.pg_backups_checks for its check_group.

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

// PgBackupsCheckGroups are the check_group names of pg_backups_checks, each an overview check of its own.
var PgBackupsCheckGroups = []string{"base backups", "log shipping", "crashes", "statement store", "uptime", "amcheck age"}

func init() {
	for _, g := range PgBackupsCheckGroups {
		overviewChecks = append(overviewChecks, struct{ name, sql string }{g, `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.pg_backups_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND c.check_group = '` + g + `'`})
	}
}

// sqlPgThresholdsFor is the value in force for each key an instance takes (a database level is the amcheck part's).
const sqlPgThresholdsFor = `
SELECT k.key, k.label, k.unit, k.direction, t.warn, t.crit, t.level, t.tag, t.threshold_id, k.warn_default, k.crit_default, k.levels
  FROM pgvigil.pg_threshold_keys k CROSS JOIN LATERAL pgvigil.pg_threshold($1, k.key) t
 WHERE k.key = ANY ($2::text[])
 ORDER BY k.key`

const sqlPgBackupTools = `
SELECT tool, name, state, message, status_code, status_message, named_by, backup_count, archive_min, archive_max, system_id, db_version, read_at,
       last_label, last_type, last_started_at, last_stopped_at, last_db_size_bytes, last_backup_bytes, last_repo_bytes, wal_since_segments, wal_since_bytes,
       last_age_h, full_label, full_stopped_at, full_age_h, failed_listed, full_warn_h, full_crit_h, full_level, any_warn_h, any_crit_h, any_level
  FROM pgvigil.pg_base_backup_status WHERE instance_id = $1 ORDER BY tool, name`

const sqlPgBaseBackups = `
SELECT tool, name, label, backup_type, status, tool_status, retention_status, started_at, stopped_at,
       round(extract(epoch FROM stopped_at - started_at)::numeric, 0) AS duration_s, db_size_bytes, backup_bytes, repo_bytes, repo_delta_bytes,
       wal_start, wal_stop, wal_since_segments, wal_since_bytes, prior, first_seen, snapshot_at
  FROM pgvigil.pg_base_backups WHERE instance_id = $1 AND is_present
 ORDER BY stopped_at DESC NULLS FIRST, label DESC LIMIT 200`

const sqlPgReplay = `
SELECT has_receiver, restore_command_set, last_replay_at, server_now, replay_delay_secs, replay_lsn::text, receive_lsn::text, replay_paused,
       primary_instance, primary_last_archived, caught_up, warn_min, crit_min, threshold_level, read_at
  FROM pgvigil.pg_wal_replay_status WHERE instance_id = $1`

const sqlPgDetect = `
SELECT snapshot_at, is_replica, archive_mode, archive_command_set, restore_command_set, has_receiver, wal_segment_bytes, tools
  FROM pgvigil.pg_backup_detect WHERE instance_id = $1`

const sqlPgChecksFor = `
SELECT severity, check_name, object, at, detail, check_group
  FROM pgvigil.pg_backups_checks WHERE instance_id = $1 AND check_group = ANY ($2::text[])
 ORDER BY CASE severity WHEN 'critical' THEN 0 ELSE 1 END, check_group, check_name`

// PgBackups is one instance's base backups (the Base backups tab).
func (s *Server) PgBackups(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"detect", sqlPgDetect, []any{id}},
		{"tools", sqlPgBackupTools, []any{id}},
		{"backups", sqlPgBaseBackups, []any{id}},
		{"replay", sqlPgReplay, []any{id}},
		{"checks", sqlPgChecksFor, []any{id, []string{"base backups", "log shipping"}}},
		{"thresholds", sqlPgThresholdsFor, []any{id, []string{"full_backup_age", "backup_age", "archive_age", "replay_delay", "retention"}}},
	})
}

const sqlPgBackupsFleet = `
SELECT b.instance_id, b.instance, b.tool, b.name, b.state, coalesce(b.status_message, b.message) AS message, b.last_label, b.last_type, b.last_stopped_at,
       b.last_age_h, b.last_db_size_bytes, b.last_repo_bytes, b.wal_since_bytes, b.full_stopped_at, b.full_age_h, b.full_warn_h, b.full_crit_h, b.backup_count,
       (SELECT CASE WHEN bool_or(c.severity = 'critical') THEN 'critical' WHEN count(*) > 0 THEN 'warning' END
          FROM pgvigil.pg_backups_checks c WHERE c.instance_id = b.instance_id AND c.check_group = 'base backups' AND c.object = b.name) AS worst,
       b.read_at
  FROM pgvigil.pg_base_backup_status b
 ORDER BY (b.state <> 'ok') DESC, b.full_age_h DESC NULLS FIRST, b.instance`

const sqlPgReplayFleet = `
SELECT w.instance_id, w.instance, w.has_receiver, w.last_replay_at, w.replay_delay_secs, w.replay_paused, w.primary_instance, w.caught_up,
       w.warn_min, w.crit_min, w.read_at
  FROM pgvigil.pg_wal_replay_status w ORDER BY w.has_receiver, w.replay_delay_secs DESC NULLS LAST, w.instance`

// PgBackupsFleet is every instance's base-backup status and every standby's replay (the fleet Backups root's sections).
func (s *Server) PgBackupsFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{{"tools", sqlPgBackupsFleet, nil}, {"replay", sqlPgReplayFleet, nil}})
}

const sqlPgRole = `
SELECT read_at, server_now, is_replica, timeline_id, timeline_source, system_identifier, postmaster_start, cluster_name, history_file, history_at,
       since, since_source, first_read_at
  FROM pgvigil.pg_role_state WHERE instance_id = $1`

const sqlPgRoleChanges = `
SELECT c.change_id, c.instance_id, i.name AS instance, c.changed_at, c.changed_at_source, c.detected_at, c.prev_read_at, c.change, c.from_role, c.to_role,
       c.from_timeline, c.to_timeline, c.postmaster_restarted, c.held_secs, c.to_system_identifier AS system_identifier
  FROM pgvigil.pg_role_changes c JOIN pgvigil.instances i USING (instance_id)
 WHERE ($1::int IS NULL OR c.instance_id = $1)
 ORDER BY c.changed_at DESC, c.change_id DESC LIMIT 500`

const sqlPgCrashes = `
SELECT at, pid, signal, detail, source, lines, ack_id, acked_by, acked_at
  FROM pgvigil.pg_crashes WHERE instance_id = $1 ORDER BY at DESC LIMIT 200`

const sqlPgCrashState = `
SELECT crashes_30d, open_30d, last_crash_at, open_crash_at, open_detail, open_age_h, warn_h, crit_h, threshold_level, status
  FROM pgvigil.pg_crash_state WHERE instance_id = $1`

const sqlPgStmtStore = `
SELECT available, preloaded, created, track, max_entries, track_utility, entries, dealloc, dealloc_24h, stats_reset, info_at, ext_at
  FROM pgvigil.pg_stmt_store_state WHERE instance_id = $1`

const sqlPgUptime = `
SELECT postmaster_start, uptime_h, warn_h, crit_h, threshold_level, status FROM pgvigil.pg_uptime_state WHERE instance_id = $1`

const sqlPgAmcheckAge = `
SELECT datname, last_ok_at, age_days, last_run_at, last_status, amcheck_runs_any, warn_days, crit_days, threshold_level
  FROM pgvigil.pg_amcheck_age WHERE instance_id = $1 ORDER BY age_days DESC NULLS FIRST, datname`

const sqlPgPatroniOf = `
SELECT m.member, m.scope, m.role, m.state, m.host, m.port, m.timeline, m.lag_bytes, m.lag_text, m.api_url, m.snapshot_at, p.url, p.ok, p.message
  FROM pgvigil.pg_patroni_read p LEFT JOIN pgvigil.pg_patroni_members m ON m.instance_id = p.instance_id AND m.is_present
 WHERE p.instance_id = $1 ORDER BY m.member`

// PgState is one instance's server state (the Server state tab).
func (s *Server) PgState(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"role", sqlPgRole, []any{id}},
		{"changes", sqlPgRoleChanges, []any{id}},
		{"crashes", sqlPgCrashes, []any{id}},
		{"crash_state", sqlPgCrashState, []any{id}},
		{"stmt", sqlPgStmtStore, []any{id}},
		{"uptime", sqlPgUptime, []any{id}},
		{"amcheck", sqlPgAmcheckAge, []any{id}},
		{"patroni", sqlPgPatroniOf, []any{id}},
		{"checks", sqlPgChecksFor, []any{id, []string{"crashes", "statement store", "uptime", "amcheck age"}}},
		{"thresholds", sqlPgThresholdsFor, []any{id, []string{"uptime", "crash", "amcheck_age"}}},
	})
}

const sqlPgLinks = `
SELECT system_identifier, cluster, instance_id, instance, role, timeline_id, role_since, read_at, has_receiver, replay_delay_secs, last_replay_at,
       receiver_status, sender_host, slot_name, receiver_delay_secs, sender_key, sender_state, sync_state, replay_lag_bytes, replay_lag_secs,
       slot_retained_bytes, slot_active, patroni_role, patroni_state, patroni_lag_bytes, changes_30d
  FROM pgvigil.pg_replication_links
 ORDER BY system_identifier NULLS LAST, role, instance`

const sqlPgPatroniFleet = `
SELECT p.instance_id, i.name AS instance, p.url, p.ok, p.message, p.scope, p.members, p.snapshot_at,
       (SELECT json_agg(json_build_object('member', m.member, 'role', m.role, 'state', m.state, 'host', m.host, 'port', m.port, 'timeline', m.timeline,
                                          'lag_bytes', m.lag_bytes, 'lag_text', m.lag_text) ORDER BY m.member)
          FROM pgvigil.pg_patroni_members m WHERE m.instance_id = p.instance_id AND m.is_present) AS member_list
  FROM pgvigil.pg_patroni_read p JOIN pgvigil.instances i ON i.instance_id = p.instance_id AND i.is_active
 ORDER BY p.scope NULLS LAST, i.name`

// PgReplicationFleet is the fleet Replication page.
func (s *Server) PgReplicationFleet(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{
		{"links", sqlPgLinks, nil},
		{"patroni", sqlPgPatroniFleet, nil},
		{"changes", sqlPgRoleChanges, []any{nil}},
	})
}

const sqlPgThresholdKeys = `SELECT key, label, unit, direction, warn_default, crit_default, levels, max_value FROM pgvigil.pg_threshold_keys ORDER BY key`
const sqlPgThresholdRows = `
SELECT threshold_id, key, label, unit, level, instance_id, instance, tag, datname, warn, crit, created_by, created_at, replaces
  FROM pgvigil.pg_threshold_rows ORDER BY key, CASE level WHEN 'root' THEN 1 WHEN 'tag' THEN 2 WHEN 'instance' THEN 3 ELSE 4 END, tag, instance, datname`
const sqlPgThresholdTags = `
SELECT DISTINCT t.tag FROM pgvigil.instance_tags_merged m JOIN pgvigil.instances i USING (instance_id) CROSS JOIN unnest(m.tags) t(tag)
 WHERE i.is_active AND i.engine = 'postgres' ORDER BY 1`
const sqlPgThresholdInstances = `SELECT instance_id, name FROM pgvigil.instances WHERE is_active AND engine = 'postgres' ORDER BY name`

// PgThresholds is the Thresholds page's read: the keys with their defaults, the live rows, the tags and instances.
func (s *Server) PgThresholds(w http.ResponseWriter, r *http.Request) {
	s.multiPart(w, r, []part{
		{"keys", sqlPgThresholdKeys, nil},
		{"rows", sqlPgThresholdRows, nil},
		{"tags", sqlPgThresholdTags, nil},
		{"instances", sqlPgThresholdInstances, nil},
	})
}

// PgThresholdWrite is POST /api/pg/thresholds: one attempt to set a level's threshold for a key or to make it inherit.
// The function checks every value and answers done or refused; a refused attempt is 409 with its reason.
func (s *Server) PgThresholdWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.ackOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(strings.Replace(why, "acknowledgements", "thresholds", 1)))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	if err != nil || len(raw) > 4096 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 4 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	// only the named keys travel on; who and from where are the server's to say
	pay := map[string]any{"ui_user": user, "client": clientIP(r)}
	for _, k := range []string{"op", "key", "level", "instance_id", "tag", "datname", "warn", "crit"} {
		if v, ok := in[k]; ok && v != nil {
			// a number is passed on as its text: the function checks the shape before it casts
			if f, isNum := v.(float64); isNum {
				v = strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.2f", f), "0"), ".")
			}
			pay[k] = v
		}
	}
	b, _ := json.Marshal(pay)
	var out []byte
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_pg_threshold($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("pg threshold: not written", "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res struct {
		Outcome     string `json:"outcome"`
		Detail      string `json:"detail"`
		ThresholdID *int64 `json:"threshold_id"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_pg_threshold answered %q", out))
		return
	}
	s.log.Info("pg threshold: attempt", "op", pay["op"], "key", pay["key"], "level", pay["level"], "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "threshold_id": res.ThresholdID}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(o)
}
