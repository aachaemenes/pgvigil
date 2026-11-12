package collect

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// backupToolsCollector reads the base backups of a self-managed server, every 15 minutes, from the tool that takes
// them (task 162; the WAL archiver and the RDS / Aurora side are the backups collection's).
//
// Which tool: the server's own archive_command and restore_command (pg_monitor reads them; only the tool's name and the
// stanza or server name are kept, never the command, which can carry a credential). pgbackrest ... --stanza=<s> names
// pgBackRest; barman-wal-archive / barman-wal-restore <host> <server>, an rsync into .../<server>/incoming, or
// barman-cloud-wal-archive <url> <server> names barman.
//
// The read: the tool's own JSON, run on the collector's host (no shell; the binary from PATH; 60 s):
//
//	pgbackrest --output=json --stanza=<s> info       every backup of the stanza, the archive's range, the status
//	barman -f json list-backups <server>             the barman server's catalog (the collector runs on the barman host)
//	barman-cloud-backup-list -f json <url> <server>  a cloud catalog (the host's own cloud credentials)
//
// A tool named by the server but missing on the collector's host is a 'no binary' state row, never an error: the
// collector's host needs the tool and read access to the repository (docs/backups-postgres.md).
//
// On a standby: the replay state (pg_last_xact_replay_timestamp, the replay and receive positions, paused) and whether
// a WAL receiver runs, so a standby fed by restore_command alone (file-based log shipping) has its replay delay.
//
// Rows: {kind:'detect'}, {kind:'tool'} per tool read, {kind:'backup'} per backup (the newest backupToolsKept),
// {kind:'replay'} on a standby. Read only.
type backupToolsCollector struct{}

func init() { Register(backupToolsCollector{}) }

const (
	backupToolsKept    = 50 // backups per stanza or server, the newest first
	backupToolsTimeout = 60 * time.Second
)

func (backupToolsCollector) Name() string                   { return "backup_tools" }
func (backupToolsCollector) DefaultInterval() time.Duration { return 15 * time.Minute }
func (backupToolsCollector) Applies(info platform.Info) (bool, string) {
	switch info.Kind {
	case platform.RDS, platform.Aurora, platform.Azure, platform.CloudSQL, platform.AlloyDB:
		return false, "a managed platform takes its own backups (the backups collection reads RDS and Aurora's)"
	}
	return true, ""
}

func (b backupToolsCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	return b.RunInstance(ctx, conn, info, config.Instance{}, nil)
}

// backupToolsSettingsSQL reads the commands (pg_read_all_settings: pg_monitor has it) and the standby's state.
const backupToolsSettingsSQL = `
SELECT pg_is_in_recovery() AS is_replica, current_setting('archive_mode') AS archive_mode,
       current_setting('archive_command') AS archive_command, coalesce(current_setting('restore_command', true), '') AS restore_command,
       pg_size_bytes(current_setting('wal_segment_size')) AS wal_segment_bytes,
       EXISTS (SELECT 1 FROM pg_stat_wal_receiver w WHERE w.pid IS NOT NULL) AS has_receiver`

// backupToolsReplaySQL: a standby's replay. The delay is the server's now less the last replayed commit's time.
const backupToolsReplaySQL = `
SELECT pg_last_xact_replay_timestamp() AS last_replay_at, now() AS server_now,
       extract(epoch FROM now() - pg_last_xact_replay_timestamp())::float8 AS replay_delay_secs,
       pg_last_wal_replay_lsn()::text AS replay_lsn, pg_last_wal_receive_lsn()::text AS receive_lsn`

// lookTool finds a tool's binary; a test or a proof sets it to a stand-in.
var lookTool = exec.LookPath

// runTool runs a tool and returns its standard output; stderr's first line rides on the error.
var runTool = func(ctx context.Context, bin string, args ...string) ([]byte, error) {
	cctx, cancel := context.WithTimeout(ctx, backupToolsTimeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, bin, args...)
	cmd.WaitDelay = 5 * time.Second // a child that keeps the pipes open does not stretch the run past its timeout
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if i := strings.IndexByte(msg, '\n'); i >= 0 {
			msg = msg[:i]
		}
		if len(msg) > 300 {
			msg = msg[:300]
		}
		if errors.Is(cctx.Err(), context.DeadlineExceeded) {
			return nil, fmt.Errorf("no answer in %s", backupToolsTimeout)
		}
		if msg == "" {
			return nil, err
		}
		return nil, fmt.Errorf("%v: %s", err, msg)
	}
	return out.Bytes(), nil
}

func (backupToolsCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, _ config.Instance, _ CursorFunc) ([]Row, error) {
	rows, err := conn.Query(ctx, backupToolsSettingsSQL)
	if err != nil {
		return nil, fmt.Errorf("backup_tools: the settings: %w", err)
	}
	set, err := rowsToMaps(rows)
	if err != nil || len(set) != 1 {
		return nil, fmt.Errorf("backup_tools: the settings: %v", err)
	}
	s := set[0]
	archiveCmd, _ := s["archive_command"].(string)
	restoreCmd, _ := s["restore_command"].(string)
	isReplica, _ := s["is_replica"].(bool)
	seg, _ := s["wal_segment_bytes"].(int64)
	tools := detectBackupTools(archiveCmd, restoreCmd)
	det := Row{"kind": "detect", "is_replica": isReplica, "archive_mode": s["archive_mode"], "has_receiver": s["has_receiver"],
		"archive_command_set": archiveCmd != "" && archiveCmd != "(disabled)", "restore_command_set": restoreCmd != "",
		"wal_segment_bytes": seg, "tools": len(tools)}
	out := []Row{det}
	for _, t := range tools {
		out = append(out, readBackupTool(ctx, t, seg)...)
	}
	if isReplica {
		rr, err := conn.Query(ctx, backupToolsReplaySQL)
		if err == nil {
			rep, err := rowsToMaps(rr)
			if err == nil && len(rep) == 1 {
				rep[0]["kind"], rep[0]["has_receiver"] = "replay", s["has_receiver"]
				var paused *bool
				if err := conn.QueryRow(ctx, `SELECT pg_is_wal_replay_paused()`).Scan(&paused); err == nil {
					rep[0]["replay_paused"] = paused
				}
				out = append(out, rep[0])
			}
		} else {
			out = append(out, Row{"kind": "collector_error", "source": "backup_tools:replay", "message": err.Error()})
		}
	}
	return out, nil
}

// backupTool is a tool the server's commands name: pgbackrest (name = the stanza), barman (the server), barman-cloud
// (the server; url = the destination; opts = its --cloud-provider and --endpoint-url, checked, passed on to the read).
type backupTool struct {
	tool, name, url, from string
	opts                  []string
}

var (
	reStanza      = regexp.MustCompile(`(?:^|[\s/])pgbackrest\b[^|;&]*?--stanza[= ]([A-Za-z0-9_.-]+)`)
	reBarmanWAL   = regexp.MustCompile(`(?:^|[\s/])barman-wal-(?:archive|restore)\b((?:\s+-[-\w]+(?:[= ](?:'[^']*'|"[^"]*"|[^\s-][^\s]*))?)*)\s+([^\s-][^\s]*)\s+([A-Za-z0-9_.-]+)`)
	reBarmanRsync = regexp.MustCompile(`(?:^|\s)rsync\b.*?:[^\s]*/([A-Za-z0-9_.-]+)/incoming/`)
	// a name starts with a letter, a digit or '_': never an option
	reToolName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$`)
	// a destination or an endpoint: a scheme, a host, an optional port and path, nothing a shell or an option could read
	reCloudURL     = regexp.MustCompile(`^(?:s3|gs|azure|https?)://[A-Za-z0-9][A-Za-z0-9._-]*(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~/-]*)?$`)
	reEndpointURL  = regexp.MustCompile(`^https?://[A-Za-z0-9][A-Za-z0-9._-]*(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~/-]*)?$`)
	cloudProviders = map[string]bool{"aws-s3": true, "azure-blob-storage": true, "google-cloud-storage": true}
)

// barmanCloudTool reads barman-cloud-wal-archive / -restore [options] <url> <server> ...: the first argument that is a
// destination URL and the next one; of the options only --cloud-provider (one of its three values) and --endpoint-url (a
// checked URL) are kept. A destination or an option that fails its check names no tool.
func barmanCloudTool(cmd, from string) (backupTool, bool) {
	f := strings.Fields(cmd)
	for i, w := range f {
		if !strings.HasSuffix(w, "barman-cloud-wal-archive") && !strings.HasSuffix(w, "barman-cloud-wal-restore") {
			continue
		}
		t := backupTool{tool: "barman-cloud", from: from}
		for j := i + 1; j < len(f); j++ {
			a := f[j]
			key, val, hasVal := strings.Cut(a, "=")
			switch key {
			case "--cloud-provider", "--endpoint-url":
				if !hasVal {
					if j+1 >= len(f) {
						return backupTool{}, false
					}
					j++
					val = f[j]
				}
				if (key == "--cloud-provider" && !cloudProviders[val]) || (key == "--endpoint-url" && !reEndpointURL.MatchString(val)) {
					return backupTool{}, false
				}
				t.opts = append(t.opts, key+"="+val)
				continue
			}
			if strings.HasPrefix(a, "-") {
				continue
			}
			if !reCloudURL.MatchString(a) || j+1 >= len(f) {
				continue
			}
			t.url, t.name = a, f[j+1]
			return t, true
		}
	}
	return backupTool{}, false
}

// detectBackupTools names the tools the two commands call, archive_command's first; a name that fails the
// pattern (a variable, a quote) is not used.
func detectBackupTools(archiveCmd, restoreCmd string) []backupTool {
	var out []backupTool
	seen := map[string]bool{}
	add := func(t backupTool) {
		if !reToolName.MatchString(t.name) || seen[t.tool+"|"+t.name] {
			return
		}
		seen[t.tool+"|"+t.name] = true
		out = append(out, t)
	}
	for _, c := range []struct{ cmd, from string }{{archiveCmd, "archive_command"}, {restoreCmd, "restore_command"}} {
		if c.cmd == "" || c.cmd == "(disabled)" {
			continue
		}
		if m := reStanza.FindStringSubmatch(c.cmd); m != nil {
			add(backupTool{tool: "pgbackrest", name: m[1], from: c.from})
		}
		if t, ok := barmanCloudTool(c.cmd, c.from); ok {
			add(t)
		} else if m := reBarmanWAL.FindStringSubmatch(c.cmd); m != nil {
			add(backupTool{tool: "barman", name: m[3], from: c.from})
		} else if m := reBarmanRsync.FindStringSubmatch(c.cmd); m != nil {
			add(backupTool{tool: "barman", name: m[1], from: c.from})
		}
	}
	return out
}

// readBackupTool runs one tool and turns its JSON into rows: a 'tool' row always, 'backup' rows when it answered.
func readBackupTool(ctx context.Context, t backupTool, seg int64) []Row {
	bin := map[string]string{"pgbackrest": "pgbackrest", "barman": "barman", "barman-cloud": "barman-cloud-backup-list"}[t.tool]
	st := Row{"kind": "tool", "tool": t.tool, "name": t.name, "named_by": t.from, "binary": bin}
	path, err := lookTool(bin)
	if err != nil {
		st["state"], st["message"] = "no_binary", fmt.Sprintf("the server's %s names %s, but %s is not on the collector host's PATH", t.from, t.tool, bin)
		return []Row{st}
	}
	var args []string
	switch t.tool {
	case "pgbackrest":
		args = []string{"--output=json", "--stanza=" + t.name, "info"}
	case "barman":
		args = []string{"-f", "json", "list-backups", "--", t.name}
	default:
		args = append(append([]string{"-f", "json"}, t.opts...), "--", t.url, t.name)
	}
	start := time.Now()
	raw, err := runTool(ctx, path, args...)
	st["read_ms"] = time.Since(start).Milliseconds()
	if err != nil {
		st["state"], st["message"] = "error", err.Error()
		return []Row{st}
	}
	var backups []Row
	switch t.tool {
	case "pgbackrest":
		backups, err = parsePgBackRest(raw, t.name, seg, st)
	case "barman":
		backups, err = parseBarman(raw, t.name)
	default:
		backups, err = parseBarmanCloud(raw, t.name)
	}
	if err != nil {
		st["state"], st["message"] = "error", err.Error()
		return []Row{st}
	}
	if st["state"] == nil {
		st["state"] = "ok"
	}
	st["backup_count"] = len(backups)
	// every label rides on the tool row, so a backup past the newest backupToolsKept is not taken for expired
	labels := make([]string, 0, len(backups))
	for _, b := range backups {
		labels = append(labels, fmt.Sprint(b["label"]))
	}
	st["labels"] = labels
	return append([]Row{st}, keepBackups(backups, backupToolsKept)...)
}

// keepBackups is the newest n backups (sorted newest first), plus the newest full and the newest that ended well when
// they are older: the status rows read both.
func keepBackups(rows []Row, n int) []Row {
	if len(rows) <= n {
		return rows
	}
	out := append([]Row{}, rows[:n]...)
	var full, good bool
	for _, r := range out {
		full = full || (r["status"] == "ok" && isFullBackup(r["backup_type"]))
		good = good || r["status"] == "ok"
	}
	for _, r := range rows[n:] {
		if full && good {
			break
		}
		f := r["status"] == "ok" && isFullBackup(r["backup_type"])
		if (f && !full) || (r["status"] == "ok" && !good) {
			out = append(out, r)
			full, good = full || f, good || r["status"] == "ok"
		}
	}
	return out
}

// isFullBackup: the kinds that hold the whole cluster (0103's pg_base_backup_status counts the same).
func isFullBackup(t any) bool {
	switch t {
	case "full", "rsync", "snapshot":
		return true
	}
	return false
}

// ---- pgBackRest ----------------------------------------------------------------------------------------

type pgbrInfo struct {
	Name   string `json:"name"`
	Status struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"status"`
	Archive []struct {
		ID       string  `json:"id"`
		Max      *string `json:"max"`
		Min      *string `json:"min"`
		Database struct {
			ID int `json:"id"`
		} `json:"database"`
	} `json:"archive"`
	DB []struct {
		ID       int         `json:"id"`
		SystemID json.Number `json:"system-id"`
		Version  string      `json:"version"`
	} `json:"db"`
	Backup []struct {
		Label     string  `json:"label"`
		Type      string  `json:"type"`
		Prior     *string `json:"prior"`
		Error     *bool   `json:"error"`
		Timestamp struct {
			Start int64 `json:"start"`
			Stop  int64 `json:"stop"`
		} `json:"timestamp"`
		Archive struct {
			Start *string `json:"start"`
			Stop  *string `json:"stop"`
		} `json:"archive"`
		Info struct {
			Size       *int64 `json:"size"`
			Delta      *int64 `json:"delta"`
			Repository struct {
				Size  *int64 `json:"size"`
				Delta *int64 `json:"delta"`
			} `json:"repository"`
		} `json:"info"`
		Database struct {
			ID      int `json:"id"`
			RepoKey int `json:"repo-key"`
		} `json:"database"`
	} `json:"backup"`
}

// parsePgBackRest reads 'pgbackrest --output=json info': the stanza's status and archive range into the tool row,
// one row per backup, the newest first, the newest with the WAL archived since it (the archive's newest segment
// less the backup's last, at the server's segment size).
func parsePgBackRest(raw []byte, stanza string, seg int64, st Row) ([]Row, error) {
	var all []pgbrInfo
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, fmt.Errorf("pgbackrest info: not the JSON expected: %v", err)
	}
	var s *pgbrInfo
	for i := range all {
		if all[i].Name == stanza {
			s = &all[i]
		}
	}
	if s == nil {
		return nil, fmt.Errorf("pgbackrest info: stanza %s is not in the answer", stanza)
	}
	st["status_code"], st["status_message"] = s.Status.Code, s.Status.Message
	if s.Status.Code != 0 {
		st["state"] = "error"
	}
	archMax := map[int]string{}
	for _, a := range s.Archive {
		if a.Max != nil {
			archMax[a.Database.ID] = *a.Max
			st["archive_max"] = *a.Max
		}
		if a.Min != nil && st["archive_min"] == nil {
			st["archive_min"] = *a.Min
		}
	}
	if n := len(s.DB); n > 0 {
		st["system_id"], st["db_version"] = s.DB[n-1].SystemID.String(), s.DB[n-1].Version
	}
	out := make([]Row, 0, len(s.Backup))
	for _, b := range s.Backup {
		r := Row{"kind": "backup", "tool": "pgbackrest", "name": stanza, "label": b.Label, "backup_type": b.Type, "status": "ok",
			"started_at": unixUTC(b.Timestamp.Start), "stopped_at": unixUTC(b.Timestamp.Stop),
			"db_size_bytes": b.Info.Size, "backup_bytes": b.Info.Delta, "repo_bytes": b.Info.Repository.Size, "repo_delta_bytes": b.Info.Repository.Delta,
			"wal_start": b.Archive.Start, "wal_stop": b.Archive.Stop, "prior": b.Prior, "error": b.Error}
		if b.Error != nil && *b.Error {
			r["status"] = "error"
		}
		if b.Archive.Stop != nil {
			if mx, ok := archMax[b.Database.ID]; ok {
				if n, ok := walSegmentsBetween(*b.Archive.Stop, mx, seg); ok {
					r["wal_since_segments"] = n
					if seg > 0 {
						r["wal_since_bytes"] = n * seg
					}
				}
			}
		}
		out = append(out, r)
	}
	sortBackups(out)
	return out, nil
}

// walSegmentsBetween counts the segments after a and up to b (WAL file names, the timeline ignored).
func walSegmentsBetween(a, b string, seg int64) (int64, bool) {
	num := func(w string) (int64, bool) {
		if len(w) < 24 || seg <= 0 {
			return 0, false
		}
		hi, e1 := strconv.ParseInt(w[8:16], 16, 64)
		lo, e2 := strconv.ParseInt(w[16:24], 16, 64)
		if e1 != nil || e2 != nil {
			return 0, false
		}
		return hi*(0x100000000/seg) + lo, true
	}
	x, ok1 := num(a)
	y, ok2 := num(b)
	if !ok1 || !ok2 {
		return 0, false
	}
	if y < x {
		return 0, true
	}
	return y - x, true
}

// ---- barman --------------------------------------------------------------------------------------------

// parseBarman reads 'barman -f json list-backups <server>': {<server>: [{backup_id, backup_type, status,
// end_time_timestamp, size_bytes, wal_size_bytes, retention_status}]} (barman 3: output.py JsonOutputWriter).
// A backup still running carries only its id and status.
func parseBarman(raw []byte, server string) ([]Row, error) {
	var all map[string][]struct {
		BackupID        string      `json:"backup_id"`
		BackupName      string      `json:"backup_name"`
		BackupType      string      `json:"backup_type"`
		Status          string      `json:"status"`
		EndTimestamp    json.Number `json:"end_time_timestamp"`
		SizeBytes       *int64      `json:"size_bytes"`
		WalSizeBytes    *int64      `json:"wal_size_bytes"`
		RetentionStatus string      `json:"retention_status"`
	}
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, fmt.Errorf("barman list-backups: not the JSON expected: %v", err)
	}
	list, ok := all[server]
	if !ok {
		return nil, fmt.Errorf("barman list-backups: server %s is not in the answer", server)
	}
	out := make([]Row, 0, len(list))
	for _, b := range list {
		typ := b.BackupType
		if typ == "" {
			typ = "full" // before barman 3.11 every backup was a full one and the key did not exist
		}
		r := Row{"kind": "backup", "tool": "barman", "name": server, "label": b.BackupID, "backup_type": typ,
			"status": barmanStatus(b.Status), "tool_status": nilIfEmpty(b.Status), "retention_status": nilIfEmpty(b.RetentionStatus),
			"db_size_bytes": b.SizeBytes, "wal_since_bytes": b.WalSizeBytes}
		if n, err := b.EndTimestamp.Int64(); err == nil && n > 0 {
			r["stopped_at"] = unixUTC(n)
		} else if t, err := time.Parse("20060102T150405", b.BackupID); err == nil {
			// a backup still running or failed carries no end: its default id is its start on the barman server's
			// clock, read as UTC, which places it among the others
			r["started_at"] = t.UTC()
		}
		out = append(out, r)
	}
	sortBackups(out)
	return out, nil
}

// parseBarmanCloud reads 'barman-cloud-backup-list -f json': {backups_list: [BackupInfo.to_json()]} with
// begin_time_iso / end_time_iso, size, status, mode, begin_wal, end_wal.
func parseBarmanCloud(raw []byte, server string) ([]Row, error) {
	var all struct {
		List []struct {
			BackupID string `json:"backup_id"`
			Status   string `json:"status"`
			Begin    string `json:"begin_time_iso"`
			End      string `json:"end_time_iso"`
			BeginC   string `json:"begin_time"`
			EndC     string `json:"end_time"`
			Size     *int64 `json:"size"`
			BeginWAL string `json:"begin_wal"`
			EndWAL   string `json:"end_wal"`
		} `json:"backups_list"`
	}
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, fmt.Errorf("barman-cloud-backup-list: not the JSON expected: %v", err)
	}
	out := make([]Row, 0, len(all.List))
	for _, b := range all.List {
		// barman-cloud takes full base backups only (mode is how it copied: concurrent, exclusive)
		r := Row{"kind": "backup", "tool": "barman-cloud", "name": server, "label": b.BackupID, "backup_type": "full",
			"status": barmanStatus(b.Status), "tool_status": nilIfEmpty(b.Status), "db_size_bytes": b.Size,
			"wal_start": nilIfEmpty(b.BeginWAL), "wal_stop": nilIfEmpty(b.EndWAL)}
		if t, ok := barmanTime(b.Begin, b.BeginC); ok {
			r["started_at"] = t
		}
		if t, ok := barmanTime(b.End, b.EndC); ok {
			r["stopped_at"] = t
		}
		out = append(out, r)
	}
	sortBackups(out)
	return out, nil
}

// barmanTime: the ISO field (barman 3.13 and later), else the older ctime one ('Wed Nov 11 10:00:00 2026', no zone:
// read as UTC).
func barmanTime(iso, ctime string) (time.Time, bool) {
	if t, err := time.Parse(time.RFC3339Nano, iso); err == nil {
		return t.UTC(), true
	}
	if t, err := time.Parse(time.ANSIC, ctime); err == nil {
		return t.UTC(), true
	}
	return time.Time{}, false
}

// barmanStatus maps barman's status to ok (DONE), running (a backup in flight) or error (FAILED and the rest).
func barmanStatus(s string) string {
	switch strings.ToUpper(s) {
	case "DONE":
		return "ok"
	case "STARTED", "EMPTY", "WAITING_FOR_WALS", "SYNCING":
		return "running"
	}
	return "error"
}

// sortBackups puts the newest stop first (a backup without one, still running, at the top).
func sortBackups(rows []Row) {
	at := func(r Row) (time.Time, bool) { t, ok := r["stopped_at"].(time.Time); return t, ok }
	sort.SliceStable(rows, func(i, j int) bool {
		a, okA := at(rows[i])
		b, okB := at(rows[j])
		if okA != okB {
			return !okA
		}
		return a.After(b)
	})
}

func unixUTC(s int64) any {
	if s <= 0 {
		return nil
	}
	return time.Unix(s, 0).UTC()
}
