package web

// Move from DBA Dash (task 206, Admin > Instances): servers a DBA Dash repository collects, moved to pgvigil one by one.
// The join wires the routes in Handler:
//   GET  /api/admin/dbadash_moves                -> the configured repositories (name, import switch) and the Windows
//                                                   sign-in's state
//   GET  /api/admin/dbadash_moves?repo=<name>    -> that repository's servers (0134's dbadash_move_list: one row per
//                                                   @@SERVERNAME, its state and move), each moved server's DBA Dash XE
//                                                   sessions as pgvigil's collector last listed them with the DROP lines
//                                                   for its DBA, the exact 'pgvigil import dbadash' command of its
//                                                   history, a history import running in this serve; and DBA Dash's
//                                                   services (read now through the door's read login: a failed read is
//                                                   a note, never a guess) with 'stop' once all their servers are ready
//   POST /api/admin/dbadash_moves  {op: add | count | import | tick, repo, ...}
//     add    servers: [{server, dbadash_ids, host, port, name}] (at most 50), one sign-in for all (auth sql | entra |
//            entra-identity | windows; login, password): each a credential file as 204 writes one and 0134's
//            import_dbadash_move add (the instance, the move, the audit row) on the actions door's audit login;
//            Windows only with the configuration's gmsa: on a Windows serve (Allen's (a): never DOMAIN\HOST$)
//     count  name: the dry run of the moved server's history (its InstanceIDs, up to pgvigil's first read of it), the
//            counts kept on the move (audited)
//     import name: the history import in the background on serve's own pool (the audit login, one connection), only
//            with the repository's import: true; off = 409 with the command to run by hand
//     tick   name, step, done: the checklist (the DBA's record, audited)
// Nothing here writes to DBA Dash's repository or to a monitored server.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/dbadash"
)

// maxMoveAdd is the most servers one add takes (the 16 KB body holds about 50 with their InstanceIDs).
const maxMoveAdd = 50

// moveSteps are the checklist's ticks (W8): DBA Dash stopped collecting the server (the DBA's hand in DBA Dash's service
// configuration), its XE sessions dropped by the server's DBA, the DBA Dash service stopped once all its servers moved.
var moveSteps = []string{"dbadash_stopped", "xe_dropped", "service_stopped"}

// moveJob is one history import this serve runs.
type moveJob struct {
	Name     string           `json:"name"`
	By       string           `json:"by"`
	Started  time.Time        `json:"started"`
	Ended    *time.Time       `json:"ended,omitempty"`
	Inserted map[string]int64 `json:"inserted"`
	Outcome  string           `json:"outcome,omitempty"` // ok | partial | failed: <why>
}

// moveJobs is a serve's import jobs and the pool they share.
type moveJobs struct {
	mu   sync.Mutex
	pool *pgxpool.Pool
	jobs map[string]*moveJob // by instance name, the newest
}

var moveJobsOf sync.Map // *Server -> *moveJobs

func (s *Server) moveJobs() *moveJobs {
	v, _ := moveJobsOf.LoadOrStore(s, &moveJobs{jobs: map[string]*moveJob{}})
	return v.(*moveJobs)
}

// importPool is the import's own pool: the actions door's audit login (a pgvigil_collector member, which the import's
// functions need), one connection, a statement timeout per batch.
func (s *Server) importPool(ctx context.Context) (*pgxpool.Pool, error) {
	mj := s.moveJobs()
	mj.mu.Lock()
	defer mj.mu.Unlock()
	if mj.pool != nil {
		return mj.pool, nil
	}
	if s.actions == nil || s.actions.audit == nil {
		return nil, errors.New(s.instancesOff())
	}
	pc := s.actions.audit.Config()
	pc.MaxConns, pc.MinConns = 1, 0
	rp := pc.ConnConfig.RuntimeParams
	rp["application_name"] = "pgvigil-serve-dbadash-import"
	rp["statement_timeout"] = "300000"
	rp["lock_timeout"] = "60000"
	p, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, err
	}
	mj.pool = p
	return p, nil
}

// windowsOff is why the Windows sign-in is not offered ("" = it is, as the gMSA).
func windowsOff(gmsa, goos string) string {
	switch {
	case goos != "windows":
		return "Windows authentication needs pgvigil on Windows, running as the gMSA the configuration names (gmsa:); this server runs on " + goos
	case gmsa == "":
		return "Windows authentication needs the gMSA the service runs as named in the configuration (gmsa: DOMAIN\\name$); never the machine account"
	}
	return ""
}

// moveCommand is the exact CLI line of a moved server's history (W7: what the page shows when the import is off).
func moveCommand(cfgPath, repo string, ids []int, collectFrom *time.Time) string {
	if cfgPath == "" {
		cfgPath = "pgvigil.yaml"
	}
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = strconv.Itoa(id)
	}
	c := "pgvigil import dbadash -config " + shellWord(cfgPath) + " -repo " + shellWord(repo) + " -instance " + strings.Join(parts, ",")
	if collectFrom != nil {
		c += " -to " + collectFrom.UTC().Format(time.RFC3339Nano)
	}
	return c
}

// shellWord quotes a word for a POSIX shell or PowerShell when it holds anything but a plain path's characters.
func shellWord(v string) string {
	if v != "" && strings.Trim(v, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:\\-") == "" {
		return v
	}
	return "'" + strings.ReplaceAll(v, "'", "''") + "'"
}

// dropLine is the T-SQL a server's DBA runs to drop one of DBA Dash's sessions (pgvigil never runs it).
func dropLine(name string) string {
	return "DROP EVENT SESSION [" + strings.ReplaceAll(name, "]", "]]") + "] ON SERVER;"
}

// xeReadLine is the read a DBA runs on the server when pgvigil's collector has not listed its sessions yet.
const xeReadLine = `SELECT name FROM sys.server_event_sessions WHERE name LIKE N'DBADash[_]%';`

// localHost says whether DBA Dash's connection names the server on DBA Dash's own host, which pgvigil cannot reach so.
func localHost(h string) bool {
	switch strings.ToLower(strings.TrimSpace(h)) {
	case "", ".", "(local)", "localhost", "127.0.0.1", "::1", "(localdb)":
		return true
	}
	return strings.HasPrefix(strings.ToLower(h), ".\\") || strings.HasPrefix(strings.ToLower(h), "(local)\\") ||
		strings.HasPrefix(strings.ToLower(h), "localhost\\") || strings.HasPrefix(strings.ToLower(h), "(localdb)\\")
}

// moveRow is one server of dbadash_move_list as the page reads it, plus what serve adds.
type moveRow map[string]any

// DBADashMoves is GET /api/admin/dbadash_moves.
func (s *Server) DBADashMoves(w http.ResponseWriter, r *http.Request) {
	a := s.instAdmin()
	repo, err := dbadashRepo(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	off := s.instancesOff()
	win := windowsOff(a.GMSA, runtime.GOOS)
	if repo == nil {
		type repoRow struct {
			Name   string `json:"name"`
			Import bool   `json:"import"`
		}
		list := []repoRow{}
		names := keys(a.DBADash)
		slices.Sort(names)
		for _, n := range names {
			on, _ := dbadash.ImportOn(n)
			list = append(list, repoRow{n, on})
		}
		s.reply(w, r, map[string]any{"repositories": list, "off": off, "windows_off": win, "gmsa": a.GMSA, "max_add": maxMoveAdd, "steps": moveSteps}, nil)
		return
	}
	on, ok := dbadash.ImportOn(*repo)
	if !ok {
		writeErr(w, http.StatusNotFound, dbadash.ErrNoRepository)
		return
	}
	ctx := r.Context()
	rows, err := s.pool.Query(ctx, `SELECT * FROM pgvigil.dbadash_move_list($1)`, *repo)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	list, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	xe, err := s.moveXE(ctx, *repo)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	mj := s.moveJobs()
	servers := make([]moveRow, 0, len(list))
	ready := map[int]bool{} // DBA Dash InstanceIDs of servers ready to switch
	for _, m := range list {
		row := moveRow(m)
		ids := intsOf(m["dbadash_ids"])
		if m["state"] == "ready to switch" {
			for _, id := range ids {
				ready[id] = true
			}
		}
		if name, _ := m["instance_name"].(string); name != "" {
			var cf *time.Time
			if t, ok := m["collect_from"].(time.Time); ok {
				cf = &t
			}
			row["command"] = moveCommand(a.ConfigPath, *repo, ids, cf)
			row["xe"] = xe[name]
			mj.mu.Lock()
			if j := mj.jobs[name]; j != nil {
				c := *j
				c.Inserted = make(map[string]int64, len(j.Inserted))
				for k, v := range j.Inserted {
					c.Inserted[k] = v
				}
				row["job"] = c
			}
			mj.mu.Unlock()
		}
		servers = append(servers, row)
	}
	out := map[string]any{"repository": *repo, "import": on, "off": off, "windows_off": win, "gmsa": a.GMSA,
		"max_add": maxMoveAdd, "steps": moveSteps, "servers": servers}
	if !on {
		out["import_off"] = "the history import inside pgvigil serve is off for " + *repo + " (dbadash: - name: " + *repo + " import: true turns it on): run each server's command on this host instead"
	}
	actx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	agents, aerr := dbadash.Agents(actx, *repo)
	if aerr != nil {
		out["agents_note"] = "DBA Dash's services were not read now (" + aerr.Error() + "): which service collects which server is not known here"
	} else {
		type agentOut struct {
			dbadash.Agent
			Waiting []string `json:"waiting"`
			Stop    string   `json:"stop,omitempty"`
		}
		ag := make([]agentOut, 0, len(agents))
		for _, a := range agents {
			o := agentOut{Agent: a, Waiting: []string{}}
			for _, in := range a.Instances {
				if !ready[in.ID] {
					sv := in.Server
					if sv == "" {
						sv = "InstanceID " + strconv.Itoa(in.ID)
					}
					if !slices.ContainsFunc(o.Waiting, func(x string) bool { return strings.EqualFold(x, sv) }) {
						o.Waiting = append(o.Waiting, sv)
					}
				}
			}
			if len(o.Waiting) == 0 {
				o.Stop = "stop the DBA Dash service " + a.Service + " on " + a.Host
			}
			ag = append(ag, o)
		}
		out["agents"] = ag
	}
	s.reply(w, r, out, nil)
}

// moveXE is each moved server's DBA Dash XE sessions as the collector last listed them (0134), by instance name: the
// sessions with their DROP lines, the read time, or the read line when no list was read since pgvigil began collecting.
func (s *Server) moveXE(ctx context.Context, repo string) (map[string]map[string]any, error) {
	rows, err := s.pool.Query(ctx, `
SELECT i.name, m.collect_from, r.read_at, f.name AS session, f.running, f.targets
  FROM pgvigil.dbadash_moves m
  JOIN pgvigil.instances i ON i.instance_id = m.instance_id
  LEFT JOIN pgvigil.mssql_xe_foreign_read r ON r.instance_id = m.instance_id
  LEFT JOIN pgvigil.mssql_xe_foreign f ON f.instance_id = m.instance_id
 WHERE m.repository = $1
 ORDER BY i.name, f.name`, repo)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]map[string]any{}
	for rows.Next() {
		var name string
		var cf, readAt *time.Time
		var sess *string
		var running *bool
		var targets []string
		if err := rows.Scan(&name, &cf, &readAt, &sess, &running, &targets); err != nil {
			return nil, err
		}
		x := out[name]
		if x == nil {
			x = map[string]any{"read_at": readAt, "sessions": []map[string]any{}, "drop": []string{}}
			if readAt == nil || cf == nil || readAt.Before(*cf) {
				x["note"] = "pgvigil has not listed this server's Extended Events sessions since it began collecting it: run this read on the server, and drop each DBADash_ session it lists"
				x["read"] = xeReadLine
			}
			out[name] = x
		}
		if sess != nil {
			sl := map[string]any{"name": *sess, "running": running != nil && *running, "targets": targets}
			if strings.EqualFold(*sess, "DBADash_SlowQueries") {
				sl["note"] = "its event files stay on the server's disk after the drop: remove them by hand when no longer wanted"
			}
			x["sessions"] = append(x["sessions"].([]map[string]any), sl)
			x["drop"] = append(x["drop"].([]string), dropLine(*sess))
		}
	}
	return out, rows.Err()
}

func intsOf(v any) []int {
	switch x := v.(type) {
	case []int32:
		out := make([]int, len(x))
		for i, n := range x {
			out[i] = int(n)
		}
		return out
	case []any:
		out := []int{}
		for _, e := range x {
			switch n := e.(type) {
			case int32:
				out = append(out, int(n))
			case int64:
				out = append(out, int(n))
			case float64:
				out = append(out, int(n))
			}
		}
		return out
	}
	return nil
}

// moveServer is one server of an add.
type moveServer struct {
	Server     string `json:"server"`
	DBADashIDs []int  `json:"dbadash_ids"`
	Host       string `json:"host"`
	Port       string `json:"port"`
	Name       string `json:"name"`
}

// moveAddCheck is the add's refusals before anything is written: the sign-in, the count, each server's host and name.
func moveAddCheck(auth, gmsa, goos string, servers []moveServer) error {
	switch auth {
	case "sql", "entra", "entra-identity":
	case "windows":
		if why := windowsOff(gmsa, goos); why != "" {
			return errors.New(why)
		}
	default:
		return errors.New("auth is sql, entra, entra-identity or windows")
	}
	if len(servers) == 0 || len(servers) > maxMoveAdd {
		return fmt.Errorf("an add moves 1 to %d servers (got %d)", maxMoveAdd, len(servers))
	}
	for _, sv := range servers {
		if config.NotTCP(sv.Host) {
			return fmt.Errorf("%s: %q is a named pipe or shared memory; pgvigil connects over TCP: type the server's network name", sv.Server, sv.Host)
		}
		h, _ := config.SplitHostPort(sv.Host)
		if localHost(h) {
			return fmt.Errorf("%s: DBA Dash connects to it as %q, on DBA Dash's own host: type the server's network name", sv.Server, sv.Host)
		}
		if n := strings.TrimSpace(sv.Name); n == "" || len(n) > 63 || nameFor(n) != n {
			return fmt.Errorf("%s: the name %q must be 1 to 63 characters of letters, digits, '_', '.', '@' and '-' (suggested: %s)", sv.Server, sv.Name, nameFor(sv.Server))
		}
		if sv.Port != "" {
			if p, err := strconv.Atoi(sv.Port); err != nil || p < 1 || p > 65535 {
				return fmt.Errorf("%s: port %q is not 1 to 65535", sv.Server, sv.Port)
			}
		}
	}
	return nil
}

// DBADashMovesWrite is POST /api/admin/dbadash_moves.
func (s *Server) DBADashMovesWrite(w http.ResponseWriter, r *http.Request) {
	user, in, ok := s.adminBody(w, r)
	if !ok {
		return
	}
	repo := str(in, "repo")
	if _, ok := dbadash.ImportOn(repo); !ok {
		writeErr(w, http.StatusNotFound, dbadash.ErrNoRepository)
		return
	}
	switch op := str(in, "op"); op {
	case "add":
		s.moveAdd(w, r, user, repo, in)
	case "count", "import":
		s.moveHistory(w, r, user, repo, op, str(in, "name"))
	case "tick":
		s.moveTick(w, r, user, in)
	default:
		writeErr(w, http.StatusBadRequest, errors.New("op is add, count, import or tick"))
	}
}

// moveTick is one checklist tick (a step of moveSteps, done or not), audited by 0134.
func (s *Server) moveTick(w http.ResponseWriter, r *http.Request, user string, in map[string]any) {
	step := str(in, "step")
	if !slices.Contains(moveSteps, step) {
		writeErr(w, http.StatusBadRequest, errors.New("step is "+strings.Join(moveSteps, ", ")))
		return
	}
	done := true
	if v, ok := in["done"].(bool); ok {
		done = v
	}
	ans, raw, err := s.callMove(r.Context(), map[string]any{"op": "tick", "ui_user": user, "client": clientIP(r), "name": str(in, "name"), "step": step, "done": done})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	s.answer(w, ans, raw, nil)
}

// callMove runs 0134's import_dbadash_move on the audit login.
func (s *Server) callMove(ctx context.Context, pay map[string]any) (importAnswer, json.RawMessage, error) {
	return s.callImport(ctx, "import_dbadash_move", pay)
}

func (s *Server) moveAdd(w http.ResponseWriter, r *http.Request, user, repo string, in map[string]any) {
	a := s.instAdmin()
	var servers []moveServer
	if b, err := json.Marshal(in["servers"]); err == nil {
		_ = json.Unmarshal(b, &servers)
	}
	for i := range servers {
		servers[i].Host, servers[i].Port, servers[i].Name = strings.TrimSpace(servers[i].Host), strings.TrimSpace(servers[i].Port), strings.TrimSpace(servers[i].Name)
		if servers[i].Port == "" {
			if h, p := config.SplitHostPort(servers[i].Host); p > 0 {
				servers[i].Host, servers[i].Port = h, strconv.Itoa(p)
			}
		}
	}
	auth, login, password := str(in, "auth"), str(in, "login"), rawStr(in, "password")
	if err := moveAddCheck(auth, a.GMSA, runtime.GOOS, servers); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if auth == "windows" {
		login, password = "", "" // the service's own account (the gMSA): no secret
	}
	dir := a.secretDir()
	if dir == "" {
		writeErr(w, http.StatusConflict, errors.New("this server was started without a config file path: credentials cannot be written"))
		return
	}
	type result struct {
		Server  string `json:"server"`
		Name    string `json:"name"`
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
	}
	out := []result{}
	for _, sv := range servers {
		res := result{Server: sv.Server, Name: sv.Name}
		port := 0
		if sv.Port != "" {
			port, _ = strconv.Atoi(sv.Port)
		}
		pay := map[string]any{"op": "add", "ui_user": user, "client": clientIP(r), "repository": repo, "server": sv.Server,
			"dbadash_ids": sv.DBADashIDs, "name": sv.Name, "host": sv.Host, "port": sv.Port, "auth": auth, "login": login,
			"platform": "auto", "tags": []string{}, "file_names": a.fileNames()}
		var written string
		if slicesContains(a.fileNames(), sv.Name) {
			pay["dsn_ref"] = "file:/refused" // the function refuses the name; nothing is written
		} else {
			dsn, err := config.BuildDSN(config.Conn{Engine: config.EngineSQLServer, Auth: auth, Host: sv.Host, Port: port, Login: login, Password: password})
			if err != nil {
				res.Outcome, res.Detail = "refused", err.Error()
				out = append(out, res)
				continue
			}
			ref, err := config.WriteSecret(dir, sv.Name, dsn)
			if err != nil {
				res.Outcome, res.Detail = "refused", "the credential file: "+err.Error()
				out = append(out, res)
				continue
			}
			pay["dsn_ref"], written = ref, ref
		}
		ans, _, err := s.callMove(r.Context(), pay)
		if err != nil || ans.Outcome != "done" {
			if written != "" {
				_ = config.RemoveSecret(dir, written)
			}
			if err != nil {
				s.log.Error("dbadash move add: not written", "user", user, "server", sv.Server, "name", sv.Name, "err", err)
				ans = importAnswer{Outcome: "error", Detail: "not written: " + err.Error()}
			}
		}
		res.Outcome, res.Detail = ans.Outcome, ans.Detail
		s.log.Info("dbadash move add", "repository", repo, "server", sv.Server, "name", sv.Name, "user", user, "outcome", ans.Outcome, "detail", ans.Detail)
		out = append(out, res)
	}
	s.reply(w, r, map[string]any{"results": out}, nil)
}

// moveOf reads one moved server's InstanceIDs and first read by pgvigil (nil row = not a move of the repository).
func (s *Server) moveOf(ctx context.Context, repo, name string) (ids []int, collectFrom *time.Time, found bool, err error) {
	err = s.pool.QueryRow(ctx, `
SELECT array_agg(mi.dbadash_id ORDER BY mi.dbadash_id), m.collect_from
  FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id
  JOIN pgvigil.dbadash_move_ids mi ON mi.instance_id = m.instance_id
 WHERE m.repository = $1 AND i.name = $2
 GROUP BY m.collect_from`, repo, name).Scan(&ids, &collectFrom)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, false, nil
	}
	return ids, collectFrom, err == nil, err
}

// moveHistory is count (the dry run, kept on the move) and import (the background run).
func (s *Server) moveHistory(w http.ResponseWriter, r *http.Request, user, repo, op, name string) {
	ctx := r.Context()
	ids, cf, found, err := s.moveOf(ctx, repo, name)
	switch {
	case err != nil:
		s.reply(w, r, nil, err)
		return
	case !found:
		writeErr(w, http.StatusNotFound, fmt.Errorf("%s is not a server moved from DBA Dash repository %s", name, repo))
		return
	}
	cmd := moveCommand(s.instAdmin().ConfigPath, repo, ids, cf)
	if on, _ := dbadash.ImportOn(repo); op == "import" && !on {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "refused", "command": cmd,
			"detail": "the history import inside pgvigil serve is off for " + repo + " (dbadash: import: true turns it on): run this on the pgvigil host instead: " + cmd})
		return
	}
	if op == "import" && cf == nil {
		writeErr(w, http.StatusConflict, fmt.Errorf("pgvigil has not read %s yet: its history is imported up to pgvigil's first read of it, after that read", name))
		return
	}
	pool, err := s.importPool(ctx)
	if err != nil {
		writeErr(w, http.StatusConflict, err)
		return
	}
	opt := dbadash.ImportOptions{Instances: ids, Store: pool, By: user}
	if cf != nil {
		opt.To = *cf
	}
	if op == "count" {
		opt.DryRun = true
		cctx, cancel := context.WithTimeout(ctx, 60*time.Second) // inside serve's 75 s write deadline
		defer cancel()
		got, err := dbadash.ImportFrom(cctx, s.log, repo, opt)
		if err != nil {
			writeErr(w, http.StatusBadGateway, fmt.Errorf("the dry run: %v", err))
			return
		}
		counts := map[string]any{}
		for _, c := range got {
			if c.Mapping == "-" {
				continue
			}
			e := map[string]any{"source": c.Source, "stored": c.Stored}
			if c.Skipped != "" {
				e["skipped"] = c.Skipped
			}
			if prev, ok := counts[c.Mapping].(map[string]any); ok { // a server DBA Dash lists twice: its InstanceIDs summed
				e["source"] = prev["source"].(int64) + c.Source
				e["stored"] = prev["stored"].(int64) + c.Stored
			}
			counts[c.Mapping] = e
		}
		ans, raw, err := s.callMove(ctx, map[string]any{"op": "count", "ui_user": user, "client": clientIP(r), "name": name, "counts": counts})
		if err != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
			return
		}
		s.answer(w, ans, raw, map[string]any{"counts": counts, "lines": got})
		return
	}
	mj := s.moveJobs()
	mj.mu.Lock()
	if j := mj.jobs[name]; j != nil && j.Ended == nil {
		mj.mu.Unlock()
		writeErr(w, http.StatusConflict, fmt.Errorf("an import of %s runs in this server already: started by %s at %s", name, j.By, j.Started.UTC().Format(time.RFC3339)))
		return
	}
	job := &moveJob{Name: name, By: user, Started: time.Now(), Inserted: map[string]int64{}}
	mj.jobs[name] = job
	mj.mu.Unlock()
	opt.Progress = func(c dbadash.ImportCount, final bool) {
		mj.mu.Lock()
		defer mj.mu.Unlock()
		job.Inserted[c.Mapping] = c.Inserted
	}
	go func() {
		jctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 24*time.Hour)
		defer cancel()
		got, err := dbadash.ImportFrom(jctx, s.log, repo, opt)
		outcome := "ok"
		for _, c := range got {
			if c.Skipped != "" {
				outcome = "partial: " + c.Mapping + ": " + c.Skipped
				break
			}
		}
		if err != nil {
			outcome = "failed: " + err.Error()
		}
		now := time.Now()
		mj.mu.Lock()
		job.Ended, job.Outcome = &now, outcome
		mj.mu.Unlock()
		s.log.Info("dbadash move import", "repository", repo, "name", name, "user", user, "outcome", outcome)
	}()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "started", "detail": "the history import of " + name + " runs in the background: the list shows its rows and its end"})
}
