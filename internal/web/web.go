// Package web serves the pgvigil UI and its JSON API over the repository.
//
// Every query runs on a read-only connection with a statement timeout; the
// server never writes. The JSON shapes are {columns:[...], rows:[[...]]} so the
// same endpoints serve the embedded frontend, Grafana's JSON source and tools.
package web

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed dist
var dist embed.FS

// Server is the UI and API server.
type Server struct {
	pool *pgxpool.Pool
	log  *slog.Logger
	// expected holds the collection intervals in seconds used to call a collection stale:
	// Defaults per collection (the collector's own), Instances per configured instance
	// (0 = disabled there). A collection named by neither is stale after DefaultStaleSecs.
	expected Expected
	// hosts are the Host header values accepted; empty = any (a non-loopback listen).
	hosts map[string]bool
}

// Expected is the interval map of the stale check.
type Expected struct {
	Defaults  map[string]int            `json:"defaults"`
	Instances map[string]map[string]int `json:"instances"`
}

// DefaultStaleSecs is the age after which a collection with no known interval is stale.
const DefaultStaleSecs = 3 * 3600

// Open connects to the repository read-only.
// hosts lists the Host header values to accept (DNS-rebinding guard); nil accepts any.
func Open(ctx context.Context, log *slog.Logger, dsn string, expected Expected, hosts []string) (*Server, error) {
	if strings.TrimSpace(dsn) == "" {
		return nil, errors.New("repository dsn is empty")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("repository dsn: %w", err)
	}
	rp := cfg.ConnConfig.RuntimeParams
	rp["application_name"] = "pgvigil-serve"
	rp["default_transaction_read_only"] = "on"
	rp["statement_timeout"] = "15000"
	rp["lock_timeout"] = "2000"
	rp["search_path"] = "pgvigil, pg_catalog"
	if cfg.MaxConns > 8 {
		cfg.MaxConns = 8
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("repository: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("repository ping: %w", err)
	}
	return &Server{pool: pool, log: log, expected: expected, hosts: hostSet(hosts)}, nil
}

// Close releases the pool.
func (s *Server) Close() { s.pool.Close() }

// Handler returns the routes: /api/... and the embedded frontend.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", s.health)
	mux.HandleFunc("GET /api/instances", s.instances)
	mux.HandleFunc("GET /api/overview", s.overview)
	mux.HandleFunc("GET /api/activity", s.activity)
	mux.HandleFunc("GET /api/statements", s.statements)
	mux.HandleFunc("GET /api/counters", s.counters)
	mux.HandleFunc("GET /api/dms", s.dms)
	mux.HandleFunc("GET /api/", func(w http.ResponseWriter, _ *http.Request) {
		writeErr(w, http.StatusNotFound, errors.New("no such endpoint"))
	})
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		panic(err) // the embed path is fixed at build time
	}
	files := http.FileServerFS(sub)
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		// a client-side route (#/...) never reaches here; unknown paths get the shell
		if r.URL.Path != "/" {
			if _, err := fs.Stat(sub, strings.TrimPrefix(r.URL.Path, "/")); err != nil {
				r.URL.Path = "/"
			}
		}
		files.ServeHTTP(w, r)
	})
	return s.secure(mux)
}

func hostSet(hosts []string) map[string]bool {
	if len(hosts) == 0 {
		return nil
	}
	m := map[string]bool{}
	for _, h := range hosts {
		m[strings.ToLower(h)] = true
	}
	return m
}

// LoopbackHosts are the Host values a loopback listen on port accepts.
func LoopbackHosts(port string) []string {
	return []string{"localhost:" + port, "127.0.0.1:" + port, "[::1]:" + port, "localhost", "127.0.0.1", "[::1]"}
}

// secure refuses a Host the server does not answer to (a DNS-rebinding page would send its
// own name) and adds the headers a local admin UI wants: no framing, no sniffing, same origin.
func (s *Server) secure(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.hosts != nil && !s.hosts[strings.ToLower(r.Host)] {
			writeErr(w, http.StatusMisdirectedRequest, errors.New("unknown host"))
			return
		}
		hd := w.Header()
		hd.Set("X-Content-Type-Options", "nosniff")
		hd.Set("X-Frame-Options", "DENY")
		hd.Set("Referrer-Policy", "no-referrer")
		hd.Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:")
		h.ServeHTTP(w, r)
	})
}

// table is the JSON shape of every API result.
type table struct {
	Columns []string `json:"columns"`
	Rows    [][]any  `json:"rows"`
}

func (s *Server) query(ctx context.Context, sql string, args ...any) (*table, error) {
	rows, err := s.pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	t := &table{Rows: [][]any{}}
	for _, f := range rows.FieldDescriptions() {
		t.Columns = append(t.Columns, f.Name)
	}
	for rows.Next() {
		v, err := rows.Values()
		if err != nil {
			return nil, err
		}
		for i, x := range v {
			// a bigint past 2^53 (a queryid) would lose digits as a JSON number in a browser
			if n, ok := x.(int64); ok && (n > 1<<53 || n < -(1<<53)) {
				v[i] = strconv.FormatInt(n, 10)
			}
		}
		t.Rows = append(t.Rows, v)
	}
	return t, rows.Err()
}

func (s *Server) reply(w http.ResponseWriter, r *http.Request, v any, err error) {
	if err != nil {
		s.log.Warn("api query failed", "path", r.URL.Path, "err", err)
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		s.log.Warn("api write failed", "path", r.URL.Path, "err", err)
	}
}

func writeErr(w http.ResponseWriter, code int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

// params reads instance (required), from and to (RFC 3339, default the last hour).
func params(r *http.Request, needInstance bool) (id int, from, to time.Time, err error) {
	q := r.URL.Query()
	if needInstance {
		id, err = strconv.Atoi(q.Get("instance"))
		if err != nil || id <= 0 {
			return 0, from, to, errors.New("instance must be a positive instance_id")
		}
	}
	to = time.Now()
	if v := q.Get("to"); v != "" {
		if to, err = time.Parse(time.RFC3339, v); err != nil {
			return 0, from, to, fmt.Errorf("to: %w", err)
		}
	}
	from = to.Add(-time.Hour)
	if v := q.Get("from"); v != "" {
		if from, err = time.Parse(time.RFC3339, v); err != nil {
			return 0, from, to, fmt.Errorf("from: %w", err)
		}
	}
	if !from.Before(to) {
		return 0, from, to, errors.New("from must be before to")
	}
	if to.Sub(from) > 31*24*time.Hour {
		return 0, from, to, errors.New("window longer than 31 days")
	}
	return id, from, to, nil
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	t, err := s.query(r.Context(), `SELECT (SELECT max(version) FROM pgvigil.schema_version) AS schema_version, now() AS server_now`)
	s.reply(w, r, t, err)
}

func (s *Server) instances(w http.ResponseWriter, r *http.Request) {
	t, err := s.query(r.Context(), sqlInstances)
	s.reply(w, r, t, err)
}

func (s *Server) overview(w http.ResponseWriter, r *http.Request) {
	exp, err := json.Marshal(s.expected)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	// each check runs alone: one that fails or times out becomes its own row, the rest still show
	out := &table{Columns: []string{"severity", "instance", "instance_id", "check_name", "object", "at", "detail"}, Rows: [][]any{}}
	names := map[int32]string{}
	if t, err := s.query(r.Context(), `SELECT instance_id, name FROM pgvigil.instances`); err == nil {
		for _, row := range t.Rows {
			if id, ok := row[0].(int32); ok {
				names[id], _ = row[1].(string)
			}
		}
	}
	for _, c := range overviewChecks {
		var args []any
		if strings.Contains(c.sql, "$1") {
			args = []any{string(exp), DefaultStaleSecs}
		}
		t, err := s.query(r.Context(), c.sql, args...)
		if err != nil {
			s.log.Warn("overview check failed", "check", c.name, "err", err)
			out.Rows = append(out.Rows, []any{"critical", "", nil, "check could not run", c.name, time.Now(), err.Error()})
			continue
		}
		for _, row := range t.Rows {
			id, _ := row[0].(int32)
			out.Rows = append(out.Rows, []any{row[1], names[id], row[0], row[2], row[3], row[4], row[5]})
		}
	}
	sort.SliceStable(out.Rows, func(i, j int) bool {
		a, b := out.Rows[i], out.Rows[j]
		if (a[0] == "critical") != (b[0] == "critical") {
			return a[0] == "critical"
		}
		for _, k := range []int{1, 3, 4} {
			x, y := fmt.Sprint(a[k]), fmt.Sprint(b[k])
			if x != y {
				return x < y
			}
		}
		return false
	})
	s.reply(w, r, out, nil)
}

func (s *Server) activity(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// at = the snapshot at or before this time (history); default the latest
	var at *time.Time
	if v := r.URL.Query().Get("at"); v != "" {
		x, err := time.Parse(time.RFC3339, v)
		if err != nil {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("at: %w", err))
			return
		}
		at = &x
	}
	ctx := r.Context()
	var snap *time.Time
	if err := s.pool.QueryRow(ctx, `SELECT max(snapshot_at) FROM pgvigil.activity_summary
	                                 WHERE instance_id = $1 AND ($2::timestamptz IS NULL OR snapshot_at <= $2)`, id, at).Scan(&snap); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	out := struct {
		SnapshotAt *time.Time `json:"snapshot_at"`
		Summary    *table     `json:"summary"`
		Sessions   *table     `json:"sessions"`
		Chains     *table     `json:"chains"`
	}{SnapshotAt: snap}
	if snap == nil {
		s.reply(w, r, out, nil)
		return
	}
	if out.Summary, err = s.query(ctx, `SELECT * FROM pgvigil.activity_summary WHERE instance_id = $1 AND snapshot_at = $2`, id, *snap); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if out.Sessions, err = s.query(ctx, sqlSessions, id, *snap); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	out.Chains, err = s.query(ctx, `SELECT * FROM pgvigil.blocking_chains($1, $2) ORDER BY head_pid, depth, pid`, id, *snap)
	s.reply(w, r, out, err)
}

// dms lists the replication tasks (every instance, or one with ?instance=), the replication instances
// they run on, and with ?task=<arn> that task's table statistics.
func (s *Server) dms(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var id *int
	if v := q.Get("instance"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
			return
		}
		id = &n
	}
	ctx := r.Context()
	out := struct {
		Tasks     *table `json:"tasks"`
		Instances *table `json:"instances"`
		Tables    *table `json:"tables"`
	}{}
	var err error
	if out.Tasks, err = s.query(ctx, sqlDMSTasks, id); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if out.Instances, err = s.query(ctx, sqlDMSInstances, id); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if task := q.Get("task"); task != "" {
		if len(task) > 512 {
			writeErr(w, http.StatusBadRequest, errors.New("task must be a task ARN"))
			return
		}
		out.Tables, err = s.query(ctx, sqlDMSTables, id, task)
	}
	s.reply(w, r, out, err)
}

func (s *Server) statements(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > 500 {
			writeErr(w, http.StatusBadRequest, errors.New("limit must be 1..500"))
			return
		}
	}
	t, err := s.query(r.Context(), `SELECT * FROM pgvigil.top_statements($1, $2, $3, $4)`, id, from, to, limit)
	s.reply(w, r, t, err)
}

func (s *Server) counters(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	sql, ok := sqlCounters[r.URL.Query().Get("kind")]
	if !ok {
		writeErr(w, http.StatusBadRequest, errors.New("kind must be db, server, io or sessions"))
		return
	}
	t, err := s.query(r.Context(), sql, id, from, to)
	s.reply(w, r, t, err)
}
