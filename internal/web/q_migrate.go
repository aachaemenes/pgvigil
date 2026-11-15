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
//            Windows only with the configuration's gmsa: on a Windows serve (the design's rule: never DOMAIN\HOST$)
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
	"net"
	"net/http"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

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
	Inserted map[string]int64 `json:"inserted"`          // per mapping, summed over the server's InstanceIDs at each read
	Outcome  string           `json:"outcome,omitempty"` // ok | partial: <why> | failed: <why>
	Notes    []string         `json:"notes,omitempty"`   // an InstanceID DBA Dash no longer holds, and the like
	byID     map[int]map[string]int64
}

// moveJobs is a serve's import jobs, the pool they share and their lifetime: serve's Close stops them (their runs end
// 'failed: serve stopped'), waits for them and then closes the pool.
type moveJobs struct {
	mu     sync.Mutex
	pool   *pgxpool.Pool
	jobs   map[string]*moveJob // by instance name, the newest
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

var moveJobsOf sync.Map // *Server -> *moveJobs

func (s *Server) moveJobs() *moveJobs {
	if v, ok := moveJobsOf.Load(s.self()); ok {
		return v.(*moveJobs)
	}
	ctx, cancel := context.WithCancel(context.Background())
	v, loaded := moveJobsOf.LoadOrStore(s.self(), &moveJobs{jobs: map[string]*moveJob{}, ctx: ctx, cancel: cancel})
	if loaded {
		cancel()
	}
	return v.(*moveJobs)
}

// closeMoveJobs is serve's Close for the import jobs: each job's context ends, its run's end mark is written by the
// import itself, and the pool closes once every job returned (at most 30 s).
func (s *Server) closeMoveJobs() {
	v, ok := moveJobsOf.LoadAndDelete(s.self())
	if !ok {
		return
	}
	mj := v.(*moveJobs)
	mj.cancel()
	done := make(chan struct{})
	go func() { mj.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		s.log.Warn("dbadash move import: a job did not end within 30 s of serve's stop")
	}
	mj.mu.Lock()
	if mj.pool != nil {
		mj.pool.Close()
		mj.pool = nil
	}
	mj.mu.Unlock()
}

// copyJob is a job as the page reads it: its inserts per mapping summed over the server's InstanceIDs.
func copyJob(j *moveJob) moveJob {
	c := *j
	c.byID = nil
	c.Inserted = map[string]int64{}
	for _, m := range j.byID {
		for k, v := range m {
			c.Inserted[k] += v
		}
	}
	c.Notes = slices.Clone(j.Notes)
	return c
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

// winSide is what the Windows sign-in is offered on: the configuration's gmsa:, the OS, the account this serve runs
// as and the host's NetBIOS name.
type winSide struct{ GMSA, GOOS, RunAs, Host string }

// thisWin is serve's own winSide (the account and the host read once).
func thisWin(gmsa string) winSide {
	runAs, host := winSelf()
	return winSide{GMSA: gmsa, GOOS: runtime.GOOS, RunAs: runAs, Host: host}
}

var winSelf = sync.OnceValues(func() (string, string) {
	runAs := ""
	if u, err := user.Current(); err == nil {
		runAs = u.Username
	}
	h, _ := os.Hostname()
	h, _, _ = strings.Cut(h, ".")
	h = strings.ToUpper(h)
	if len(h) > 15 {
		h = h[:15] // the NetBIOS name: the first 15 characters
	}
	return runAs, h
})

// windowsOff is why the Windows sign-in is not offered ("" = it is, as the gMSA): never the machine account
// DOMAIN\HOST$, named in gmsa: or reached through a serve that runs as another account (mssqlopen refuses the same at
// each connect of run, serve and the import).
func windowsOff(w winSide) string {
	switch {
	case w.GOOS != "windows":
		return "Windows authentication needs pgvigil on Windows, running as the gMSA the configuration names (gmsa:); this server runs on " + w.GOOS
	case w.GMSA == "":
		return "Windows authentication needs the gMSA the service runs as named in the configuration (gmsa: DOMAIN\\name$); never the machine account"
	}
	_, acct, _ := strings.Cut(w.GMSA, `\`)
	if w.Host != "" && strings.EqualFold(strings.TrimSuffix(acct, "$"), w.Host) {
		return "gmsa: " + w.GMSA + " is this host's machine account (" + w.Host + "$), never offered: name the group Managed Service Account the service runs as"
	}
	if !strings.EqualFold(w.RunAs, w.GMSA) {
		return fmt.Sprintf("pgvigil serve runs as %q, not as the gMSA %s the configuration names (gmsa:): a Windows sign-in would reach the servers as another account (a virtual or system account signs in as the machine account); run pgvigil serve and the service as the gMSA", w.RunAs, w.GMSA)
	}
	return ""
}

// moveCommand is the exact CLI line of a moved server's history (W7: what the page shows when the import is off), in
// the shell of serve's own OS (PowerShell on Windows, a POSIX shell elsewhere), the configuration's path absolute.
func moveCommand(cfgPath, repo string, ids []int, collectFrom *time.Time, goos string) string {
	if cfgPath == "" {
		cfgPath = "pgvigil.yaml"
	}
	parts := make([]string, len(ids))
	for i, id := range ids {
		parts[i] = strconv.Itoa(id)
	}
	c := "pgvigil import dbadash -config " + shellWord(cfgPath, goos) + " -repo " + shellWord(repo, goos) + " -instance " + strings.Join(parts, ",")
	if collectFrom != nil {
		c += " -to " + collectFrom.UTC().Format(time.RFC3339Nano)
	}
	return c
}

// absConfig is serve's configuration path made absolute (serve's own working folder), so the command runs from any.
func absConfig(p string) string {
	if p == "" {
		p = "pgvigil.yaml"
	}
	if a, err := filepath.Abs(p); err == nil {
		return a
	}
	return p
}

// shellWord quotes a word when it holds anything but a plain path's characters: PowerShell doubles a "'" inside single
// quotes, a POSIX shell closes, escapes and reopens them.
func shellWord(v, goos string) string {
	if v != "" && strings.Trim(v, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:\\-") == "" {
		return v
	}
	if goos == "windows" {
		return "'" + strings.ReplaceAll(v, "'", "''") + "'"
	}
	return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'"
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

// addressWhy says why a server as DBA Dash connects to it (or as typed in the add's row) is not a network name or
// address pgvigil can connect to; "" when it is. A DBA Dash ConnectionID is often a free-text label (a host and a
// comment, an alias in brackets, two names in one): the driver would take such a label for a host name and fail at
// the first collection, or reach another server. Accepted, after an optional 'tcp:': a DNS or NetBIOS name (letters,
// digits, '-', '_', '.') or an IPv4 address, either with an optional '\instance' (letters, digits, '_', '$', '#'; at
// most 16), then an optional ',port' or ':port'; an IPv6 address alone, or in brackets with an optional ':port'.
// web/src/move_address.ts' addrWhy is the same rule (the page's prefill); this one decides. Spaces around the ','
// before a port are dropped first ('sql01, 1433' is sql01 on 1433).
func addressWhy(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 4 && strings.EqualFold(s[:4], "tcp:") {
		s = s[4:]
	}
	if h, p, ok := strings.Cut(s, ","); ok {
		s = strings.TrimSpace(h) + "," + strings.TrimSpace(p)
	}
	switch {
	case s == "":
		return "empty"
	case strings.ContainsAny(s, " \t"):
		return "a space in it: a label, not a network name"
	}
	if strings.HasPrefix(s, "[") {
		in, rest, closed := strings.Cut(s[1:], "]")
		if !closed {
			return "a '[' with no ']': not a network address"
		}
		if ip := net.ParseIP(in); ip == nil || ip.To4() != nil || strings.Contains(in, ".") {
			return "brackets around a name: an alias, not a network address"
		}
		if rest == "" {
			return ""
		}
		if !strings.HasPrefix(rest, ":") {
			return "text after the bracketed address"
		}
		return portWhy(rest[1:])
	}
	host := s
	switch {
	case strings.Contains(s, ","):
		h, p, _ := strings.Cut(s, ",")
		if why := portWhy(p); why != "" {
			return why
		}
		host = h
	case strings.Count(s, ":") == 1:
		h, p, _ := strings.Cut(s, ":")
		if why := portWhy(p); why != "" {
			return why
		}
		host = h
	case strings.Contains(s, ":"):
		if net.ParseIP(s) != nil {
			return ""
		}
		return "colons that are neither an IPv6 address nor a port"
	}
	name, inst, named := strings.Cut(host, `\`)
	if strings.ContainsAny(name, "[](){}") {
		return "brackets in it: a label, not a network name"
	}
	if net.ParseIP(name) == nil {
		if name == "" || len(name) > 253 || strings.Contains(name, "..") || strings.Trim(name, ".-") != name {
			return "not a host name"
		}
		for _, r := range name {
			if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '-' && r != '_' && r != '.' {
				return fmt.Sprintf("%q is not a character of a network name", r)
			}
		}
	}
	if named {
		if inst == "" || len([]rune(inst)) > 16 {
			return "the instance name after '\\' is not 1 to 16 characters"
		}
		for _, r := range inst {
			if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_' && r != '$' && r != '#' {
				return fmt.Sprintf("%q is not a character of an instance name", r)
			}
		}
	}
	return ""
}

// portWhy is addressWhy's port after ',' or ':': "" for 1 to 65535.
func portWhy(p string) string {
	n, err := strconv.Atoi(strings.TrimSpace(p))
	switch {
	case err != nil:
		return fmt.Sprintf("%q after the name is not a port", p)
	case n < 1 || n > 65535:
		return fmt.Sprintf("port %d is not 1 to 65535", n)
	}
	return ""
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
	win := windowsOff(thisWin(a.GMSA))
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
			row["command"] = moveCommand(absConfig(a.ConfigPath), *repo, intsOf(m["move_ids"]), cf, runtime.GOOS)
			row["xe"] = xe[name]
			mj.mu.Lock()
			if j := mj.jobs[name]; j != nil {
				row["job"] = copyJob(j)
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
		ag := agentLines(agents, ready)
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
func moveAddCheck(auth string, win winSide, servers []moveServer) error {
	switch auth {
	case "sql", "entra", "entra-identity":
	case "windows":
		if why := windowsOff(win); why != "" {
			return errors.New(why)
		}
	default:
		return errors.New("auth is sql, entra, entra-identity or windows")
	}
	if len(servers) == 0 || len(servers) > maxMoveAdd {
		return fmt.Errorf("an add moves 1 to %d servers (got %d)", maxMoveAdd, len(servers))
	}
	for _, sv := range servers {
		if strings.TrimSpace(sv.Host) == "" {
			return fmt.Errorf("%s: no host: type the server's host and port in its row", sv.Server)
		}
		if config.NotTCP(sv.Host) {
			return fmt.Errorf("%s: %q is a named pipe or shared memory; pgvigil connects over TCP: type the server's network name", sv.Server, sv.Host)
		}
		h, _ := config.SplitHostPort(sv.Host)
		if localHost(h) {
			return fmt.Errorf("%s: DBA Dash connects to it as %q, on DBA Dash's own host: type the server's network name", sv.Server, sv.Host)
		}
		if why := addressWhy(sv.Host); why != "" {
			return fmt.Errorf("%s: %q is not a network name or address pgvigil can connect to (%s): type the server's host and port in its row", sv.Server, sv.Host, why)
		}
		if n := strings.TrimSpace(sv.Name); n == "" || len(n) > 63 || nameFor(n) != n {
			return fmt.Errorf("%s: the name %q must be 1 to 63 characters of letters, digits, '_', '.', '@' and '-' (suggested: %s)", sv.Server, sv.Name, nameFor(sv.Server))
		}
		if sv.Port != "" {
			p, err := strconv.Atoi(sv.Port)
			if err != nil || p < 1 || p > 65535 {
				return fmt.Errorf("%s: port %q is not 1 to 65535", sv.Server, sv.Port)
			}
			// a port typed in the host and another in the port field: never pick one silently
			if _, hp := config.SplitHostPort(sv.Host); hp > 0 && hp != p {
				return fmt.Errorf("%s: the host %q carries port %d and the port field says %d: keep one", sv.Server, sv.Host, hp, p)
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
		s.moveTick(w, r, user, repo, in)
	default:
		writeErr(w, http.StatusBadRequest, errors.New("op is add, count, import or tick"))
	}
}

// moveTick is one checklist tick (a step of moveSteps, done or not), audited by 0134.
func (s *Server) moveTick(w http.ResponseWriter, r *http.Request, user, repo string, in map[string]any) {
	step := str(in, "step")
	if !slices.Contains(moveSteps, step) {
		writeErr(w, http.StatusBadRequest, errors.New("step is "+strings.Join(moveSteps, ", ")))
		return
	}
	done := true
	if v, ok := in["done"].(bool); ok {
		done = v
	}
	// a tick is a server moved from THIS repository (0134's tick reads the name alone)
	if _, _, found, err := s.moveOf(r.Context(), repo, str(in, "name")); err != nil {
		s.reply(w, r, nil, err)
		return
	} else if !found {
		writeErr(w, http.StatusNotFound, fmt.Errorf("%s is not a server moved from DBA Dash repository %s", str(in, "name"), repo))
		return
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
	b, _ := json.Marshal(in["servers"])
	if err := json.Unmarshal(b, &servers); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("servers: each is {server, dbadash_ids, host, port, name} with text fields (%v)", err))
		return
	}
	for i := range servers {
		sv := &servers[i]
		sv.Host, sv.Port, sv.Name = strings.TrimSpace(sv.Host), strings.TrimSpace(sv.Port), strings.TrimSpace(sv.Name)
	}
	auth, login, password := str(in, "auth"), str(in, "login"), rawStr(in, "password")
	// the checks read each host as typed (an alias in brackets is refused before the split would cut it to a name)
	if err := moveAddCheck(auth, thisWin(a.GMSA), servers); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	for i := range servers {
		// DBA Dash's connection as typed: 'tcp:' and a ',port' or ':port' come off the host (a port typed apart wins)
		sv := &servers[i]
		h, p := config.SplitHostPort(sv.Host)
		sv.Host = h
		if sv.Port == "" && p > 0 {
			sv.Port = strconv.Itoa(p)
		}
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
	if op == "count" {
		// one deadline for the whole count, inside serve's 75 s write deadline
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 55*time.Second)
		defer cancel()
	}
	ids, cf, found, err := s.moveOf(ctx, repo, name)
	switch {
	case err != nil:
		s.reply(w, r, nil, err)
		return
	case !found:
		writeErr(w, http.StatusNotFound, fmt.Errorf("%s is not a server moved from DBA Dash repository %s", name, repo))
		return
	}
	cmd := moveCommand(absConfig(s.instAdmin().ConfigPath), repo, ids, cf, runtime.GOOS)
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
		got, err := dbadash.ImportFrom(ctx, s.log, repo, opt)
		if err != nil {
			writeErr(w, http.StatusBadGateway, fmt.Errorf("the dry run: %v", err))
			return
		}
		counts := moveCounts(got)
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
	prev := mj.jobs[name] // an ended job stays shown when this click is refused
	job := &moveJob{Name: name, By: user, Started: time.Now(), Inserted: map[string]int64{}, byID: map[int]map[string]int64{}}
	mj.jobs[name] = job
	mj.mu.Unlock()
	// the run mark before the answer: another run of this move (a CLI run, another serve) is the click's 409, in its words
	_, raw, err := s.callMove(ctx, map[string]any{"op": "run", "ui_user": user, "client": clientIP(r), "name": name})
	var mark struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
		RunID   int64  `json:"run_id"`
	}
	if err == nil {
		err = json.Unmarshal(raw, &mark)
	}
	if err != nil || mark.Outcome != "done" || mark.RunID == 0 {
		mj.mu.Lock()
		if prev != nil {
			mj.jobs[name] = prev
		} else {
			delete(mj.jobs, name)
		}
		mj.mu.Unlock()
		if err != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the run mark was not written: %v", err))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "refused", "detail": mark.Detail})
		return
	}
	opt.Run = &dbadash.MoveRun{Name: name, ID: mark.RunID}
	opt.Progress = func(c dbadash.ImportCount, _ bool) {
		mj.mu.Lock()
		defer mj.mu.Unlock()
		if job.byID[c.DBADashID] == nil {
			job.byID[c.DBADashID] = map[string]int64{}
		}
		job.byID[c.DBADashID][c.Mapping] = c.Inserted
	}
	mj.wg.Add(1)
	go func() {
		defer mj.wg.Done()
		outcome, notes := "", []string(nil)
		defer func() {
			if p := recover(); p != nil { // never takes the server down
				outcome = fmt.Sprintf("failed: panic: %v", p)
			}
			now := time.Now()
			mj.mu.Lock()
			job.Ended, job.Outcome, job.Notes = &now, outcome, notes
			mj.mu.Unlock()
			s.log.Info("dbadash move import", "repository", repo, "name", name, "user", user, "outcome", outcome)
		}()
		// serve's own lifetime (Close ends it), at most a day
		jctx, cancel := context.WithTimeout(mj.ctx, 24*time.Hour)
		defer cancel()
		got, err := dbadash.ImportFrom(jctx, s.log, repo, opt)
		outcome, notes = jobOutcome(got, err)
	}()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]any{"outcome": "started", "detail": "the history import of " + name + " runs in the background: the list shows its rows and its end"})
}

// agentOut is one DBA Dash service as the page shows it: the servers it still collects that are not ready to switch,
// and the stop line once there are none.
type agentOut struct {
	dbadash.Agent
	Waiting []string `json:"waiting"`
	Stop    string   `json:"stop,omitempty"`
}

// agentLines is the agents' rule (W8 c): a service may be stopped only when every active server it collects is ready to
// switch (by DBA Dash InstanceID); each server waiting is named once (its @@SERVERNAME, else its InstanceID). A service
// that collects no active server now (each removed in DBA Dash after its move) may be stopped too.
func agentLines(agents []dbadash.Agent, ready map[int]bool) []agentOut {
	ag := make([]agentOut, 0, len(agents))
	for _, a := range agents {
		o := agentOut{Agent: a, Waiting: []string{}}
		for _, in := range a.Instances {
			if ready[in.ID] {
				continue
			}
			sv := in.Server
			if sv == "" {
				sv = "InstanceID " + strconv.Itoa(in.ID)
			}
			if !slices.ContainsFunc(o.Waiting, func(x string) bool { return strings.EqualFold(x, sv) }) {
				o.Waiting = append(o.Waiting, sv)
			}
		}
		switch {
		case len(a.Instances) == 0:
			o.Stop = "stop the DBA Dash service " + a.Service + " on " + a.Host + " if it still runs: it collects no active server now"
		case len(o.Waiting) == 0:
			o.Stop = "stop the DBA Dash service " + a.Service + " on " + a.Host
		}
		ag = append(ag, o)
	}
	return ag
}

// moveCounts is a dry run's counts per mapping: a server DBA Dash lists under several InstanceIDs has its sources
// summed and its stored rows once (stored is pgvigil's figure for the one moved instance, the same on every line); an
// InstanceID DBA Dash no longer holds (mapping '-') counts nothing.
func moveCounts(got []dbadash.ImportCount) map[string]any {
	counts := map[string]any{}
	for _, c := range got {
		if c.Mapping == "-" {
			continue
		}
		e := map[string]any{"source": c.Source, "stored": c.Stored}
		if prev, ok := counts[c.Mapping].(map[string]any); ok {
			e["source"] = prev["source"].(int64) + c.Source
			if sk, ok := prev["skipped"]; ok {
				e["skipped"] = sk
			}
		}
		if c.Skipped != "" {
			e["skipped"] = c.Skipped
		}
		counts[c.Mapping] = e
	}
	return counts
}

// jobOutcome is a background import's outcome: failed with the error, partial with the first mapping held back, else
// ok; an InstanceID DBA Dash no longer holds is a note, not a partial (nothing of it was there to import).
func jobOutcome(got []dbadash.ImportCount, err error) (string, []string) {
	var notes []string
	outcome := "ok"
	for _, c := range got {
		switch {
		case c.Mapping == "-":
			notes = append(notes, "DBA Dash InstanceID "+strconv.Itoa(c.DBADashID)+": "+c.Skipped)
		case c.Skipped != "" && outcome == "ok":
			outcome = "partial: " + c.Mapping + ": " + c.Skipped
		}
	}
	if err != nil {
		outcome = "failed: " + err.Error()
	}
	return outcome, notes
}
