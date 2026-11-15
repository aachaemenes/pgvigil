package web

// q_requests.go: serve's side of the request queue (task CQ, 487; migration 0200). With actions.via queue serve
// connects to no monitored server (the repository alone, and a DBA Dash repository named under dbadash:): a community
// run is an ask (import_action_request) a collector with cq.enabled claims and runs with its own logins, and the page
// waits on GET /api/requests/<id>?wait=25, answered the moment serve's LISTEN pgvigil_result hears the id (the row is
// read every 5 s while LISTEN holds, every 1 s while it is lost). The result is the asker's alone as serve names them
// (ui_action_result). Every other door is off in queue mode (queueNotYet).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// queueNotYet is the words of every door that is off in queue mode: the actions and plans this release does not send
// through the queue, and serve's own repository writes (acknowledgements, alert rules, applications, Admin > Instances,
// custom reports, report mail), which ride the audit login a queue-mode serve does not hold.
const queueNotYet = "off in queue mode (actions.via queue in pgvigil.yaml): this serve holds no login to the monitored servers and no write login to the repository, and in this release only the community tools go through the queue to a collector"

// queueWaitStep: a wait reads the request's row at least this often even while LISTEN holds (behind a
// transaction-mode pooler LISTEN seems to hold and no notify ever arrives).
const queueWaitStep = 5 * time.Second

// queueState is serve's queue: the requester login's pool, why asks are refused here (or ""), and the open waits.
type queueState struct {
	pool      *pgxpool.Pool
	off       string
	log       *slog.Logger
	mu        sync.Mutex
	waits     map[int64][]chan struct{}
	listening atomic.Bool
}

// queues holds each Server's queue beside it (web.go's Server is a WIRING file; nil = direct mode).
var queues sync.Map

func (s *Server) queue() *queueState {
	if v, ok := queues.Load(s); ok {
		return v.(*queueState)
	}
	return nil
}

// SetQueue turns serve's queue mode on (serve calls it after Open with actions.via queue): a pool on the repository
// dsn, which must hold pgvigil_requester and must NOT be the collector's (an error serve exits on, naming the role);
// every family's door that does not go through the queue gets queueNotYet.
func (s *Server) SetQueue(ctx context.Context, dsn string) error {
	pc, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return fmt.Errorf("actions.via queue: the repository dsn: %w", err)
	}
	pc.MaxConns = 4
	pc.ConnConfig.RuntimeParams["application_name"] = "pgvigil-serve-queue"
	pc.ConnConfig.RuntimeParams["statement_timeout"] = "5000"
	pc.ConnConfig.RuntimeParams["lock_timeout"] = "2000"
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return fmt.Errorf("actions.via queue: %w", err)
	}
	var who string
	var coll, req bool
	if err := pool.QueryRow(ctx, `SELECT current_user, pg_has_role(current_user, 'pgvigil_collector', 'MEMBER'),
		to_regrole('pgvigil_requester') IS NOT NULL AND pg_has_role(current_user, 'pgvigil_requester', 'MEMBER')`).Scan(&who, &coll, &req); err != nil {
		pool.Close()
		return fmt.Errorf("actions.via queue: the repository login could not be read: %w", err)
	}
	if coll {
		pool.Close()
		return fmt.Errorf("actions.via queue: the repository login %s is IN ROLE pgvigil_collector; serve in queue mode runs as a login IN ROLE pgvigil_reader, pgvigil_auth, pgvigil_requester and never as the collector's ('pgvigil roles' prints it)", who)
	}
	q := &queueState{pool: pool, log: s.log, waits: map[int64][]chan struct{}{}}
	if !req {
		q.off = fmt.Sprintf("the repository login %s IN ROLE pgvigil_requester (run 'pgvigil migrate' for 0200, then GRANT pgvigil_requester TO %s)", who, who)
	}
	queues.Store(s, q)
	if s.actions != nil {
		s.actions.off = queueNotYet
	}
	go q.listen(ctx, dsn)
	return nil
}

// listen holds LISTEN pgvigil_result and wakes the waits of each id it hears.
func (q *queueState) listen(ctx context.Context, dsn string) {
	for ctx.Err() == nil {
		conn, err := pgx.Connect(ctx, dsn)
		if err == nil {
			_, err = conn.Exec(ctx, `LISTEN pgvigil_result`)
		}
		for err == nil {
			q.listening.Store(true)
			var n *pgconn.Notification
			n, err = conn.WaitForNotification(ctx)
			if err == nil {
				if id, perr := strconv.ParseInt(n.Payload, 10, 64); perr == nil {
					q.wake(id)
				}
			}
		}
		q.listening.Store(false)
		if conn != nil {
			cctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_ = conn.Close(cctx)
			cancel()
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func (q *queueState) wake(id int64) {
	q.mu.Lock()
	ws := q.waits[id]
	delete(q.waits, id)
	q.mu.Unlock()
	for _, c := range ws {
		close(c)
	}
}

func (q *queueState) waitOn(id int64) chan struct{} {
	c := make(chan struct{})
	q.mu.Lock()
	q.waits[id] = append(q.waits[id], c)
	q.mu.Unlock()
	return c
}

func (q *queueState) drop(id int64, c chan struct{}) {
	q.mu.Lock()
	defer q.mu.Unlock()
	ws := q.waits[id]
	for i, x := range ws {
		if x == c {
			q.waits[id] = append(ws[:i], ws[i+1:]...)
			break
		}
	}
	if len(q.waits[id]) == 0 {
		delete(q.waits, id)
	}
}

// ask writes one request; the reply is import_action_request's {outcome, detail, request_id, expires_at}.
func (q *queueState) ask(ctx context.Context, kind, instance, user, client string, args any) (map[string]any, error) {
	b, err := json.Marshal(map[string]any{"kind": kind, "instance": instance, "ui_user": user, "client": client, "args": args})
	if err != nil {
		return nil, err
	}
	var raw []byte
	if err := q.pool.QueryRow(ctx, `SELECT pgvigil.import_action_request($1::jsonb)::text`, string(b)).Scan(&raw); err != nil {
		return nil, err
	}
	m := map[string]any{}
	return m, json.Unmarshal(raw, &m)
}

// replyAsk answers a POST that became an ask: 202 with the request's id, or 400 with the refusal's words.
func (s *Server) replyAsk(w http.ResponseWriter, r *http.Request, m map[string]any, err error) {
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the request could not be written to the repository: %v", err))
		return
	}
	if m["outcome"] != "waiting" {
		writeErr(w, http.StatusBadRequest, errors.New(fmt.Sprint(m["detail"])))
		return
	}
	m["via"] = "queue"
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(m)
}

// RequestGet is GET /api/requests/{id}?wait=N (0 to 25 s): the request's state and, for its asker alone, its result,
// answered at once when it has ended or when wait is 0, else when it ends (the notify) or wait runs out.
func (s *Server) RequestGet(w http.ResponseWriter, r *http.Request) {
	q := s.queue()
	if q == nil {
		writeErr(w, http.StatusNotFound, errors.New("the request queue is off on this server (actions.via direct)"))
		return
	}
	if s.auth == nil { // -no-login: no session to read (sessionUser needs the UI login)
		writeErr(w, http.StatusForbidden, errors.New("a request's result is its asker's: this server runs without the UI login"))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("a request's result is its asker's: sign in"))
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("the request id is a whole number"))
		return
	}
	wait := 0
	if v := r.URL.Query().Get("wait"); v != "" {
		if wait, err = strconv.Atoi(v); err != nil || wait < 0 || wait > 25 {
			writeErr(w, http.StatusBadRequest, errors.New("wait is 0 to 25 seconds"))
			return
		}
	}
	deadline := time.Now().Add(time.Duration(wait) * time.Second)
	for {
		c := q.waitOn(id) // before the read: a notify between the read and the wait is not lost
		m, err := q.result(r.Context(), id, user)
		if err != nil {
			q.drop(id, c)
			writeErr(w, http.StatusServiceUnavailable, err)
			return
		}
		if why, ok := m["refused"].(string); ok {
			q.drop(id, c)
			status := http.StatusForbidden
			if strings.HasPrefix(why, "no request") {
				status = http.StatusNotFound
			}
			writeErr(w, status, errors.New(why))
			return
		}
		st, _ := m["state"].(string)
		left := time.Until(deadline)
		if (st != "waiting" && st != "running") || left <= 0 {
			q.drop(id, c)
			m["listening"] = q.listening.Load()
			s.reply(w, r, m, nil)
			return
		}
		step := min(left, queueWaitStep)
		if !q.listening.Load() && step > time.Second {
			step = time.Second // LISTEN lost: read the row every second
		}
		select {
		case <-c:
		case <-time.After(step):
			q.drop(id, c)
		case <-r.Context().Done():
			q.drop(id, c)
			return
		}
	}
}

// result reads ui_action_result on the queue's pool (it writes read_at: never the read-only UI pool).
func (q *queueState) result(ctx context.Context, id int64, user string) (map[string]any, error) {
	var raw []byte
	if err := q.pool.QueryRow(ctx, `SELECT pgvigil.ui_action_result($1, $2)::text`, id, user).Scan(&raw); err != nil {
		return nil, err
	}
	m := map[string]any{}
	return m, json.Unmarshal(raw, &m)
}

// RequestCancel is POST /api/requests/{id}/cancel: the asker's cancel (import_action_cancel's words).
func (s *Server) RequestCancel(w http.ResponseWriter, r *http.Request) {
	q := s.queue()
	if q == nil {
		writeErr(w, http.StatusNotFound, errors.New("the request queue is off on this server (actions.via direct)"))
		return
	}
	user, _, ok := s.gate(w, r, 1024, func() string { return q.off })
	if !ok {
		return
	}
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("the request id is a whole number"))
		return
	}
	var raw []byte
	if err := q.pool.QueryRow(r.Context(), `SELECT pgvigil.import_action_cancel($1, $2)::text`, id, user).Scan(&raw); err != nil {
		writeErr(w, http.StatusServiceUnavailable, err)
		return
	}
	m := map[string]any{}
	_ = json.Unmarshal(raw, &m)
	if m["outcome"] == "refused" {
		writeErr(w, http.StatusBadRequest, errors.New(fmt.Sprint(m["detail"])))
		return
	}
	s.reply(w, r, m, nil)
}

// ---- the community tools in queue mode -------------------------------------------------------------------------

// queuedCommunityRun: CommunityRun's queue path - the gate's checks done, the run asked of the collector.
func (s *Server) queuedCommunityRun(w http.ResponseWriter, r *http.Request, q *queueState, in communityBody, user, name string, t *communityTool) {
	args := map[string]any{"tool": t.ID}
	if in.Database != "" {
		args["database"] = in.Database
	}
	if len(in.Params) > 0 {
		args["params"] = in.Params
	}
	if in.TimeoutSecs != 0 {
		args["timeout_secs"] = in.TimeoutSecs
	}
	if in.Text != "" {
		args["text"] = in.Text
	}
	if in.QueryName != "" {
		args["query_name"] = in.QueryName
	}
	m, err := q.ask(r.Context(), "community_run", name, user, clientIP(r), args)
	s.replyAsk(w, r, m, err)
}

// queuedCommunityHelp: the form's @help in queue mode is its own ask (community_help).
func (s *Server) queuedCommunityHelp(w http.ResponseWriter, r *http.Request, q *queueState, in communityBody, user, name string, t *communityTool) {
	args := map[string]any{"tool": t.ID}
	if in.Database != "" {
		args["database"] = in.Database
	}
	m, err := q.ask(r.Context(), "community_help", name, user, clientIP(r), args)
	s.replyAsk(w, r, m, err)
}

// liveTools reads a live worker's published tools of an instance (the newest worker that holds it, its open
// community door first), by that worker's collector id; a tool its community_allow shuts (a shut named door) comes
// back with the collector's words in Shut.
func (s *Server) liveTools(ctx context.Context, name string) (host string, rows map[string]cqToolRow, door string, err error) {
	rows = map[string]cqToolRow{}
	var open *bool
	var why *string
	var cid string
	err = s.pool.QueryRow(ctx, `SELECT w.collector_id, w.host, d.open, d.why
		  FROM pgvigil.cq_workers w
		  LEFT JOIN pgvigil.action_doors d ON d.collector_id = w.collector_id AND d.instance = $1 AND d.kind = 'community_run' AND d.name = ''
		 WHERE $1 = ANY (w.instances) AND w.beat_at > now() - interval '45 seconds'
		 ORDER BY d.open DESC NULLS LAST, w.beat_at DESC LIMIT 1`, name).Scan(&cid, &host, &open, &why)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", rows, fmt.Sprintf("no collector takes requests for %s now (cq.enabled in the pgvigil.yaml of the collector that holds it)", name), nil
	}
	if err != nil {
		return "", rows, "", err
	}
	switch {
	case open == nil:
		door = fmt.Sprintf("run a community tool is not through the queue yet on %s (the collector on %s)", name, host)
	case !*open:
		door = fmt.Sprintf("%s (the collector on %s)", strings.TrimSpace(deref(why)), host)
	}
	tr, err := s.pool.Query(ctx, `SELECT t.tool, t.present, coalesce(t.why, ''), t.params, coalesce(t.database, ''),
		       (SELECT n.why FROM pgvigil.action_doors n WHERE n.collector_id = t.collector_id AND n.instance = t.instance
		           AND n.kind = 'community_run' AND lower(n.name) = lower(t.tool) AND NOT n.open)
		  FROM pgvigil.cq_tools t WHERE t.collector_id = $1 AND t.instance = $2`, cid, name)
	if err != nil {
		return host, rows, door, err
	}
	defer tr.Close()
	for tr.Next() {
		var row cqToolRow
		var params []byte
		var shut *string
		if err := tr.Scan(&row.Tool, &row.Present, &row.Why, &params, &row.Database, &shut); err != nil {
			return host, rows, door, err
		}
		if len(params) > 0 {
			row.Params = json.RawMessage(params)
		}
		if shut != nil {
			row.Shut = fmt.Sprintf("%s (the collector on %s)", strings.TrimSpace(*shut), host)
		}
		rows[row.Tool] = row
	}
	return host, rows, door, tr.Err()
}

// queuedCommunity is Community's queue path: the same reply, each tool's state from the live worker's published rows.
func (s *Server) queuedCommunity(w http.ResponseWriter, r *http.Request, q *queueState, id int, name, engine, db string) {
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	out := struct {
		Enabled   bool        `json:"enabled"`
		Reason    string      `json:"reason,omitempty"`
		Instance  string      `json:"instance"`
		Engine    string      `json:"engine"`
		Database  string      `json:"database,omitempty"`
		Demo      bool        `json:"demo"`
		Tools     []toolState `json:"tools"`
		Log       *table      `json:"log"`
		Needs     []toolNeed  `json:"needs"`
		CheckedAt *time.Time  `json:"checked_at,omitempty"`
		Via       string      `json:"via"`
		Collector string      `json:"collector,omitempty"`
	}{Instance: name, Engine: engine, Tools: []toolState{}, Needs: []toolNeed{}, Via: "queue"}
	if engine == "sqlserver" {
		out.Database = msDB(db)
	}
	host, rows, door, err := s.liveTools(ctx, name)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	out.Collector = host
	// the sign-in and the requester role first (communityOffWords' queue part: a click would be 403 or refused), then
	// the collector's own door
	if w := s.communityOffWords(); w != "" {
		out.Needs = append(out.Needs, hardNeed(w, "", "configuration"))
	} else if door != "" {
		out.Needs = append(out.Needs, hardNeed(door, "", "configuration"))
	}
	for _, t := range communityTools {
		if t.Engine != engine {
			continue
		}
		ts := toolState{communityTool: t, Needs: []toolNeed{}}
		if row, ok := rows[t.ID]; ok {
			if t.Kind == "proc" {
				yes := row.Present
				ts.Installed = &yes
				// the collector checks one database (the login's default): its name, not the one picked here
				checked := row.Database
				if checked == "" {
					checked = out.Database
				}
				if yes {
					ts.Where = checked + ".dbo"
				}
				if engine == "sqlserver" && !strings.EqualFold(checked, out.Database) {
					ts.Needs = append(ts.Needs, noteNeed(fmt.Sprintf("the collector on %s checked %s in %s; a run in %s looks for it there and says so if it is not installed", host, t.Name, checked, out.Database), "", "repository"))
				}
			}
			if row.Shut != "" {
				ts.Needs = append(ts.Needs, hardNeed(row.Shut, "", "configuration"))
			} else if !row.Present && row.Why != "" {
				ts.Needs = append(ts.Needs, hardNeed(row.Why, "", "server"))
			}
		} else if door == "" && q.off == "" {
			ts.Needs = append(ts.Needs, notChecked("the collector on "+host+" has not published this tool yet"))
		}
		ts.State = "ready"
		for _, n := range append(append([]toolNeed{}, out.Needs...), ts.Needs...) {
			if n.Hard {
				ts.State = n.State
				break
			}
			if n.State == "note" {
				ts.State = "note"
			}
		}
		ts.On = ts.State == "ready" || ts.State == "note"
		out.Tools = append(out.Tools, ts)
	}
	for _, n := range out.Needs {
		if n.Hard {
			out.Reason = n.What
			break
		}
	}
	out.Enabled = out.Reason == ""
	out.Log, err = s.query(ctx, sqlCommunityLog, id)
	s.reply(w, r, out, err)
}

// queuedCommunityParams is CommunityParams' queue path: the form from the live worker's published parameter list;
// the help is its own ask (help_via: queue).
func (s *Server) queuedCommunityParams(w http.ResponseWriter, r *http.Request, t *communityTool, name string) {
	out := struct {
		Tool      string          `json:"tool"`
		Installed bool            `json:"installed"`
		Params    json.RawMessage `json:"params"`
		Left      []string        `json:"left_out"`
		HelpSets  []resultSet     `json:"help_sets"`
		Static    []reportParam   `json:"static_params,omitempty"`
		HelpVia   string          `json:"help_via"`
		Collector string          `json:"collector,omitempty"`
	}{Tool: t.ID, Params: json.RawMessage("[]"), Left: []string{}, HelpSets: []resultSet{}, HelpVia: "queue"}
	if t.Kind != "proc" {
		out.Installed, out.Static = true, t.Params
		s.reply(w, r, out, nil)
		return
	}
	host, rows, door, err := s.liveTools(r.Context(), name)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	if door != "" {
		writeErr(w, http.StatusConflict, errors.New(door))
		return
	}
	out.Collector = host
	row, ok := rows[t.ID]
	if row.Shut != "" {
		writeErr(w, http.StatusForbidden, errors.New(row.Shut))
		return
	}
	if !ok || !row.Present {
		why := row.Why
		if why == "" {
			why = fmt.Sprintf("the collector on %s has not published %s for %s yet", host, t.Name, name)
		}
		writeErr(w, http.StatusNotFound, errors.New(why))
		return
	}
	out.Installed = true
	if raw, ok := row.Params.(json.RawMessage); ok && len(raw) > 0 {
		out.Params = raw
	}
	s.reply(w, r, out, nil)
}
