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
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/logparse"
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
	// auth is the UI login; nil = off (a loopback listen that asked for it).
	auth *authState
	// tls says the listener is TLS: HSTS is sent and the session cookie is Secure.
	tls bool
	// actions is the cancel / terminate door (actions.go); never nil after Open.
	actions *Actions
	// tags is the config's ui: block for GET /api/tags (q_tags.go).
	tags TagsUI
	// version is this binary's version line for the About page (GET /api/health); "" = not said.
	version string
}

// Options shape a Server beyond its repository connection.
type Options struct {
	Expected Expected
	// Hosts lists the Host header values to accept (DNS-rebinding guard); nil accepts any.
	Hosts []string
	// Login requires the UI login (pgvigil.ui_users) on every /api endpoint but login, logout and session.
	Login bool
	// TLS says the listener is TLS.
	TLS bool
	// SessionTTL is a session's life from its login; 0 = 12 h.
	SessionTTL time.Duration
	// Actions turns the cancel / terminate door on (nil = off, the routes say why).
	Actions *ActionsConfig
	// Tags is the config's ui: block (the tree's grouping and value order).
	Tags TagsUI
	// AppName is the pool's application_name in pg_stat_activity; "" = pgvigil-serve (pgvigil mcp names itself pgvigil-mcp).
	AppName string
	// Version is this binary's version line (`pgvigil version`): the About page shows it and puts it into a problem report's mail.
	Version string
}

// Expected is the interval map of the stale check.
type Expected struct {
	Defaults  map[string]int            `json:"defaults"`
	Instances map[string]map[string]int `json:"instances"`
}

// DefaultStaleSecs is the age after which a collection with no known interval is stale.
const DefaultStaleSecs = 3 * 3600

// Open connects to the repository read-only and, with o.Login, checks that the login can work:
// the serve login must hold pgvigil_auth and the schema must carry 0015.
func Open(ctx context.Context, log *slog.Logger, dsn string, o Options) (*Server, error) {
	if strings.TrimSpace(dsn) == "" {
		return nil, errors.New("repository dsn is empty")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("repository dsn: %w", err)
	}
	rp := cfg.ConnConfig.RuntimeParams
	rp["application_name"] = "pgvigil-serve"
	if o.AppName != "" {
		rp["application_name"] = o.AppName
	}
	rp["default_transaction_read_only"] = "on"
	rp["statement_timeout"] = "15000"
	rp["jit"] = "off" // the findings view (sixteen UNION arms of CASE-heavy rules) crosses jit_above_cost: LLVM compiled 1,289 functions per read, 147 s against 3 s without (2026-11-09)
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
	s := &Server{pool: pool, log: log, expected: o.Expected, hosts: hostSet(o.Hosts), tls: o.TLS, tags: o.Tags, version: o.Version}
	if o.Login {
		var n int64
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ui_user_count()`).Scan(&n); err != nil {
			pool.Close()
			var pg *pgconn.PgError
			switch {
			case errors.As(err, &pg) && pg.Code == "42501":
				return nil, fmt.Errorf("the serve login may not check passwords: as the repository owner run GRANT pgvigil_auth TO %s", cfg.ConnConfig.User)
			case errors.As(err, &pg) && pg.Code == "42883":
				return nil, errors.New("the repository has no UI login yet: run 'pgvigil migrate' as the repository owner")
			}
			return nil, fmt.Errorf("ui login check: %w", err)
		}
		if n == 0 {
			log.Warn("no UI user can log in yet: run 'pgvigil user add <name>' as the repository owner")
		}
		s.auth = newAuth(func(ctx context.Context, user string) (string, error) {
			var h *string
			if err := pool.QueryRow(ctx, `SELECT pgvigil.ui_password_hash($1)`, user).Scan(&h); err != nil {
				return "", err
			}
			if h == nil {
				return "", nil
			}
			return *h, nil
		}, o.TLS, o.SessionTTL)
	}
	if s.actions, err = s.NewActions(ctx, o.Actions); err != nil {
		log.Warn("actions are off", "reason", err)
	} else if o.Actions != nil && s.actions.off != "" {
		log.Warn("actions are off", "reason", s.actions.off)
	}
	return s, nil
}

// Close releases the audit pool and the pool.
func (s *Server) Close() { s.actions.Close(); s.pool.Close() }

// Handler returns the routes: /api/... (behind the login when it is on) and the embedded frontend.
// The shell and its assets are public: they hold no data.
func (s *Server) Handler() http.Handler {
	api := http.NewServeMux()
	api.HandleFunc("GET /api/health", s.health)
	api.HandleFunc("GET /api/instances", s.instances)
	api.HandleFunc("GET /api/overview", s.overview)
	api.HandleFunc("GET /api/activity", s.activity)
	api.HandleFunc("GET /api/statements", s.statements)
	api.HandleFunc("GET /api/counters", s.counters)
	api.HandleFunc("GET /api/dms", s.dms)
	api.HandleFunc("GET /api/replication", s.replication)
	api.HandleFunc("GET /api/jobs", s.jobs)
	api.HandleFunc("GET /api/logs", s.logs)
	api.HandleFunc("GET /api/config", s.config)
	api.HandleFunc("GET /api/databases", s.databases)
	api.HandleFunc("GET /api/search", s.search)
	api.HandleFunc("GET /api/tables", s.tables)
	api.HandleFunc("GET /api/tables/top", s.TablesTop)
	api.HandleFunc("GET /api/connections", s.Connections)
	api.HandleFunc("GET /api/diff", s.Diff)
	api.HandleFunc("GET /api/tablesize", s.TableSize)
	api.HandleFunc("GET /api/pgconfig", s.PGConfig)
	api.HandleFunc("GET /api/pg/dboptions", s.PGDBOptions)
	api.HandleFunc("GET /api/pg/dboptions/fleet", s.PGDBOptionsFleet)
	api.HandleFunc("GET /api/tiles", s.Tiles)
	api.HandleFunc("GET /api/dbchanges", s.DBChanges)
	api.HandleFunc("GET /api/findings", s.findings)
	api.HandleFunc("GET /api/alerts", s.Alerts)
	api.HandleFunc("GET /api/alertrules", s.AlertRules)
	api.HandleFunc("POST /api/alertrules", s.AlertRuleWrite)
	api.HandleFunc("POST /api/alertrules/end", s.AlertRuleEnd)
	api.HandleFunc("POST /api/alerts/test", s.AlertTest)
	api.HandleFunc("POST /api/alerts/dismiss", s.AlertDismiss)
	api.HandleFunc("POST /api/alerts/mute", s.AlertMute)
	api.HandleFunc("GET /api/metrics", s.Metrics)
	api.HandleFunc("GET /api/metrics/series", s.MetricSeries)
	api.HandleFunc("GET /api/ack", s.Ack)
	api.HandleFunc("POST /api/ack", s.AckAdd)
	api.HandleFunc("POST /api/ack/end", s.AckEnd)
	api.HandleFunc("GET /api/slow", s.slow)
	api.HandleFunc("GET /api/slowqueries", s.SlowQueries)
	api.HandleFunc("GET /api/compare", s.Compare)
	api.HandleFunc("GET /api/sessionsets", s.SessionSets)
	api.HandleFunc("GET /api/memory", s.Memory)
	api.HandleFunc("GET /api/mssql/audit", s.MSSQLAudit)
	api.HandleFunc("GET /api/mssql/xe", s.MSSQLXE)
	api.HandleFunc("GET /api/mssql/xe/deadlock", s.MSSQLXEDeadlock)
	api.HandleFunc("GET /api/mssql/xe/deadlock.xdl", s.MSSQLXEDeadlockXDL)
	api.HandleFunc("GET /api/blocking/history", s.BlockingHistory)
	api.HandleFunc("GET /api/mssql/xe/blocked", s.MSSQLXEBlocked)
	api.HandleFunc("GET /api/mssql/xe/slow", s.MSSQLXESlow)
	api.HandleFunc("GET /api/pgaudit", s.PgAudit)
	api.HandleFunc("GET /api/pooler", s.Pooler)
	api.HandleFunc("GET /api/pooler/conns", s.PoolerConns)
	api.HandleFunc("GET /api/schema", s.Schema)
	api.HandleFunc("GET /api/host", s.Host)
	api.HandleFunc("GET /api/disks", s.Disks)
	api.HandleFunc("GET /api/storage", s.Storage)
	api.HandleFunc("GET /api/storage/fleet", s.StorageFleet)
	api.HandleFunc("GET /api/dbinfo", s.DBInfo)
	api.HandleFunc("GET /api/dbinfo/fleet", s.DBInfoFleet)
	api.HandleFunc("GET /api/drill/db", s.DrillDB)
	api.HandleFunc("GET /api/drill/table", s.DrillTable)
	api.HandleFunc("GET /api/drill/job", s.DrillJob)
	api.HandleFunc("GET /api/drill/index", s.DrillIndex)
	api.HandleFunc("GET /api/backups", s.Backups)
	api.HandleFunc("GET /api/backups/fleet", s.BackupsFleet)
	api.HandleFunc("GET /api/corruption", s.Corruption)
	api.HandleFunc("GET /api/vacuum", s.Vacuum)
	api.HandleFunc("GET /api/dbadash", s.DBADash)
	api.HandleFunc("GET /api/jobsreport", s.JobsReport)
	api.HandleFunc("GET /api/custom", s.Custom)
	api.HandleFunc("GET /api/extensions", s.Extensions)
	api.HandleFunc("GET /api/roles", s.Roles)
	api.HandleFunc("GET /api/versions", s.Versions)
	api.HandleFunc("GET /api/io", s.IO)
	api.HandleFunc("GET /api/pgdepth", s.PgDepth)
	api.HandleFunc("GET /api/pi", s.PILoad)
	api.HandleFunc("GET /api/capacity", s.Capacity)
	api.HandleFunc("GET /api/waits", s.Waits)
	api.HandleFunc("GET /api/perfsummary", s.PerfSummary)
	api.HandleFunc("GET /api/performance", s.Performance)
	api.HandleFunc("GET /api/indexes", s.Indexes)
	api.HandleFunc("POST /api/indexes/advise", s.IndexAdvisor)
	api.HandleFunc("GET /api/dmsio", s.DMSIO)
	api.HandleFunc("GET /api/tags", s.Tags(s.tags))
	api.HandleFunc("POST /api/actions/cancel", s.actions.Cancel)
	api.HandleFunc("POST /api/actions/terminate", s.actions.Terminate)
	api.HandleFunc("GET /api/actions/log", s.actions.Log)
	api.HandleFunc("GET /api/mssql/storage", s.MSSQLStorage)
	api.HandleFunc("GET /api/mssql/cpu", s.MSSQLCPU)
	api.HandleFunc("GET /api/mssql/memory", s.MSSQLMemory)
	api.HandleFunc("GET /api/mssql/fileio", s.MSSQLFileIO)
	api.HandleFunc("GET /api/mssql/tempdb", s.MSSQLTempdb)
	api.HandleFunc("GET /api/mssql/querystore", s.MSSQLQueryStore)
	api.HandleFunc("GET /api/mssql/querystore/query", s.MSSQLQueryStoreQuery)
	api.HandleFunc("GET /api/mssql/querystore/plan.sqlplan", s.MSSQLQueryStorePlan)
	api.HandleFunc("GET /api/mssql/rowversions", s.MSSQLRowVersions)
	api.HandleFunc("GET /api/mssql/config", s.MSSQLConfig)
	api.HandleFunc("GET /api/mssql/properties", s.MSSQLProperties)
	api.HandleFunc("GET /api/mssql/checks", s.MSSQLChecks)
	api.HandleFunc("GET /api/mssql/checks/fleet", s.MSSQLChecksFleet)
	api.HandleFunc("GET /api/mssql/waitinfo", s.MSSQLWaitInfo)
	api.HandleFunc("GET /api/mssql/procs", s.MSSQLProcs)
	api.HandleFunc("GET /api/mssql/indexlocks", s.MSSQLIndexLocks)
	api.HandleFunc("GET /api/mssql/plancache", s.MSSQLPlanCache)
	api.HandleFunc("GET /api/mssql/indexes", s.MSSQLIndexes)
	api.HandleFunc("GET /api/mssql/errorlog", s.MSSQLErrorLog)
	api.HandleFunc("GET /api/mssql/defaulttrace", s.MSSQLDefaultTrace)
	api.HandleFunc("GET /api/mssql/syshealth", s.MSSQLSysHealth)
	api.HandleFunc("GET /api/mssql/actions/state", s.MSSQLActionState)
	api.HandleFunc("POST /api/mssql/actions/preview", s.MSSQLActionPreview)
	api.HandleFunc("POST /api/mssql/actions/run", s.MSSQLActionRun)
	api.HandleFunc("GET /api/plans", s.Plans)
	api.HandleFunc("GET /api/plan", s.Plan)
	api.HandleFunc("GET /api/mssql/summary", s.MSSQLSummary)
	api.HandleFunc("GET /api/mssql/running", s.MssqlRunning)
	api.HandleFunc("GET /api/running/fleet", s.RunningFleet)
	api.HandleFunc("GET /api/running/snapshots", s.RunningSnapshots)
	api.HandleFunc("GET /api/mssql/waits", s.MssqlWaits)
	api.HandleFunc("GET /api/mssql/availability", s.MSSQLAvailability)
	api.HandleFunc("GET /api/mssql/jobs", s.MSSQLJobs)
	api.HandleFunc("GET /api/jobs/history", s.JobsHistory)
	api.HandleFunc("GET /api/config/changes", s.ConfigChanges)
	api.HandleFunc("GET /api/mssql/config/fleet", s.MSSQLConfigFleet)
	api.HandleFunc("GET /api/mssql/traceflags", s.MSSQLTraceFlags)
	api.HandleFunc("GET /api/jobs/thresholds", s.JobThresholds)
	api.HandleFunc("POST /api/jobs/thresholds", s.JobThresholdWrite)
	api.HandleFunc("GET /api/slow/groups", s.SlowGroups)
	api.HandleFunc("GET /api/slow/events", s.SlowEvents)
	api.HandleFunc("GET /api/slow/percentiles", s.SlowPercentiles)
	api.HandleFunc("GET /api/logs/groups", s.LogGroups)
	api.HandleFunc("GET /api/logs/groups/rows", s.LogGroupRows)
	api.HandleFunc("GET /api/stmttrend", s.StmtTrend)
	api.HandleFunc("GET /api/stmtgroups", s.StmtGroups)
	api.HandleFunc("GET /api/stmtlag", s.StmtLag)
	api.HandleFunc("GET /api/plans/suggest", s.PlanSuggest)
	api.HandleFunc("GET /api/jobs/timeline", s.JobsTimeline)
	api.HandleFunc("GET /api/mssql/backups", s.MSSQLBackups)
	api.HandleFunc("POST /api/plans/explain", s.actions.Explain)
	api.HandleFunc("POST /api/plans/analyze", s.actions.ExplainAnalyze)
	api.HandleFunc("POST /api/plans/hypo", s.actions.HypoIndex)
	api.HandleFunc("GET /api/", func(w http.ResponseWriter, _ *http.Request) {
		writeErr(w, http.StatusNotFound, errors.New("no such endpoint"))
	})
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/login", s.login)
	mux.HandleFunc("POST /api/logout", s.logout)
	mux.HandleFunc("GET /api/session", s.sessionInfo)
	mux.Handle("/api/", s.requireLogin(api))
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		panic(err) // the embed path is fixed at build time
	}
	files := http.FileServerFS(sub)
	// no method in the pattern: "GET /" and the method-less "/api/" gate would be two patterns
	// neither of which is more specific, which the mux refuses
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			writeErr(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
			return
		}
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
// own name) and adds the headers an admin UI wants: no framing, no sniffing, same origin, HSTS under TLS.
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
		hd.Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; form-action 'self'")
		if s.tls {
			hd.Set("Strict-Transport-Security", "max-age=31536000")
		}
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

// maxWindow is the longest window a page reads; maxSeriesWindow the longest of a size series (hourly rows, bucketed
// to about 300 points whatever the span).
const (
	maxWindow       = 31 * 24 * time.Hour
	maxSeriesWindow = 366 * 24 * time.Hour
)

// params reads instance (required), from and to (RFC 3339, default the last hour); the window at most 31 days.
func params(r *http.Request, needInstance bool) (id int, from, to time.Time, err error) {
	return paramsMax(r, needInstance, maxWindow)
}

// paramsMax is params with the longest window the caller allows.
func paramsMax(r *http.Request, needInstance bool, longest time.Duration) (id int, from, to time.Time, err error) {
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
	if to.Sub(from) > longest {
		return 0, from, to, fmt.Errorf("window longer than %d days", int(longest.Hours()/24))
	}
	return id, from, to, nil
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	// version and repository_version are the About page's (web/src/about.ts): this binary's version line and the repository's server version
	t, err := s.query(r.Context(), `SELECT (SELECT max(version) FROM pgvigil.schema_version) AS schema_version, now() AS server_now,
       $1::text AS version, current_setting('server_version') AS repository_version`, s.version)
	s.reply(w, r, t, err)
}

func (s *Server) instances(w http.ResponseWriter, r *http.Request) {
	exp, err := json.Marshal(s.expected)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	t, err := s.query(r.Context(), sqlInstances, string(exp))
	s.reply(w, r, t, err)
}

func (s *Server) overview(w http.ResponseWriter, r *http.Request) {
	exp, err := json.Marshal(s.expected)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	// each check runs alone: one that fails or times out becomes its own row, the rest still show
	// check_group names the check that produced the row: the fleet Summary grid colours one cell per group
	out := &table{Columns: []string{"severity", "instance", "instance_id", "check_name", "object", "at", "detail", "check_group"}, Rows: [][]any{}}
	names := map[int32]string{}
	if t, err := s.query(r.Context(), `SELECT instance_id, name FROM pgvigil.instances`); err == nil {
		for _, row := range t.Rows {
			if id, ok := row[0].(int32); ok {
				names[id], _ = row[1].(string)
			}
		}
	}
	for _, c := range overviewChecks {
		// a check names the parameters it takes: $1 the expectations, $2 the default stale age
		var args []any
		switch {
		case strings.Contains(c.sql, "$2"):
			args = []any{string(exp), DefaultStaleSecs}
		case strings.Contains(c.sql, "$1"):
			args = []any{string(exp)}
		}
		t, err := s.query(r.Context(), c.sql, args...)
		if err != nil {
			s.log.Warn("overview check failed", "check", c.name, "err", err)
			out.Rows = append(out.Rows, []any{"critical", "", nil, "check could not run", c.name, time.Now(), err.Error(), c.name})
			continue
		}
		for _, row := range t.Rows {
			id, _ := row[0].(int32)
			out.Rows = append(out.Rows, []any{row[1], names[id], row[0], row[2], row[3], row[4], row[5], c.name})
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
	// the tables of one task row: task_instance names the instance the task rides on (two instance
	// blocks naming one task are two rows), else the page's instance filter, else any
	task := q.Get("task")
	tid := id
	if task != "" {
		if len(task) > 512 {
			writeErr(w, http.StatusBadRequest, errors.New("task must be a task ARN"))
			return
		}
		if v := q.Get("task_instance"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n <= 0 {
				writeErr(w, http.StatusBadRequest, errors.New("task_instance must be a positive instance_id"))
				return
			}
			tid = &n
		}
	}
	ctx := r.Context()
	out := struct {
		Tasks     *table `json:"tasks"`
		Instances *table `json:"instances"`
		Tables    *table `json:"tables"`
		Drain     *table `json:"drain"`
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
	if out.Drain, err = s.query(ctx, sqlDMSDrain, id); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if task != "" {
		out.Tables, err = s.query(ctx, sqlDMSTables, tid, task)
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
	order := r.URL.Query().Get("order")
	if order == "" {
		order = "time"
	}
	if !statementOrders[order] {
		writeErr(w, http.StatusBadRequest, errors.New("order must be time, calls, io, mean, rows, temp or wal"))
		return
	}
	t, err := s.query(r.Context(), `SELECT * FROM pgvigil.top_statements_by($1, $2, $3, $4, $5)`, id, from, to, order, limit)
	s.reply(w, r, t, err)
}

// statementOrders are the sorts top_statements_by knows.
var statementOrders = map[string]bool{"time": true, "calls": true, "io": true, "mean": true, "rows": true, "temp": true, "wal": true}

// tables is one instance's table health read: the per-database summary and the tables.
func (s *Server) tables(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := struct {
		Databases *table `json:"databases"`
		Tables    *table `json:"tables"`
	}{}
	if out.Databases, err = s.query(r.Context(), sqlTableDatabases, id); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	out.Tables, err = s.query(r.Context(), sqlTables, id)
	s.reply(w, r, out, err)
}

// findings lists the parameter findings of every instance, or one with ?instance=.
func (s *Server) findings(w http.ResponseWriter, r *http.Request) {
	var id *int
	if v := r.URL.Query().Get("instance"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
			return
		}
		id = &n
	}
	t, err := s.query(r.Context(), sqlFindings, id)
	s.reply(w, r, t, err)
}

// slow lists the executions seen running, or sitting idle in a transaction, at least ?min= seconds (default 5)
// between from and to (pgvigil.long_runs_in_window, 0048: an idle session by its idle time, its transaction age
// beside it); ?state=active|idle, ?user=, ?db= and ?app= narrow the rows (exact matches, 64 characters at most).
func (s *Server) slow(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	minSecs := 5
	if v := q.Get("min"); v != "" {
		if minSecs, err = strconv.Atoi(v); err != nil || minSecs < 0 || minSecs > 86400 {
			writeErr(w, http.StatusBadRequest, errors.New("min must be 0..86400 seconds"))
			return
		}
	}
	var state, user, db, app *string
	if v := q.Get("state"); v != "" {
		if v != "active" && v != "idle" {
			writeErr(w, http.StatusBadRequest, errors.New("state must be active or idle"))
			return
		}
		state = &v
	}
	for _, f := range []struct {
		name string
		dst  **string
	}{{"user", &user}, {"db", &db}, {"app", &app}} {
		if v := q.Get(f.name); v != "" {
			if len(v) > 64 || strings.ContainsFunc(v, func(c rune) bool { return c < ' ' || c == 0x7f }) {
				writeErr(w, http.StatusBadRequest, fmt.Errorf("%s must be 1..64 printable characters", f.name))
				return
			}
			val := v
			*f.dst = &val
		}
	}
	t, err := s.query(r.Context(), `SELECT * FROM pgvigil.long_runs_in_window($1, $2, $3, $4, $5, $6, $7, $8, 200)`,
		id, from, to, minSecs, state, user, db, app)
	s.reply(w, r, t, err)
}

func (s *Server) counters(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	kind := r.URL.Query().Get("kind")
	sql, ok := sqlCounters[kind]
	if !ok {
		writeErr(w, http.StatusBadRequest, errors.New("kind must be db, server, io or sessions"))
		return
	}
	if kind == "sessions" {
		t, err := s.query(r.Context(), sql, id, from, to)
		s.reply(w, r, t, err)
		return
	}
	collection := "dbstats"
	if kind == "io" {
		collection = "iostats"
	}
	t, err := s.query(r.Context(), sql, id, from, to, s.rateLookback(r.Context(), id, collection))
	s.reply(w, r, t, err)
}

// rateLookback is how far before the window a *_rate() read may reach for the first point's
// baseline: three intervals of the collection that fills the table, never under the functions'
// own 15-minute default, taken from the stale check's interval map (the instance's own schedule,
// else the collection default). So a cadence set above 15 minutes (schedules: iostats: 30m) keeps
// its first point in every preset instead of an empty 15-minute chart (review 20a).
func (s *Server) rateLookback(ctx context.Context, id int, collection string) int {
	secs := s.expected.Defaults[collection]
	var name string
	if err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name); err == nil {
		if m, ok := s.expected.Instances[name]; ok {
			if v, ok := m[collection]; ok && v > 0 {
				secs = v
			}
		}
	}
	lb := 3 * secs
	if lb < 900 {
		lb = 900
	}
	return lb
}

// multi runs named queries in order into one JSON object; the first error ends the reply.
func (s *Server) multi(w http.ResponseWriter, r *http.Request, parts []part) {
	out := map[string]*table{}
	for _, p := range parts {
		t, err := s.query(r.Context(), p.sql, p.args...)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("%s: %w", p.name, err))
			return
		}
		out[p.name] = t
	}
	s.reply(w, r, out, nil)
}

type part struct {
	name string
	sql  string
	args []any
}

// onlyPart narrows a page's parts to the one ?part= names (the side tree's folders read one list, task 65); no part
// = every part; a name the page does not have is refused.
func onlyPart(r *http.Request, parts []part) ([]part, error) {
	want := r.URL.Query().Get("part")
	if want == "" {
		return parts, nil
	}
	names := make([]string, 0, len(parts))
	for _, p := range parts {
		if p.name == want {
			return []part{p}, nil
		}
		names = append(names, p.name)
	}
	return nil, errors.New("part must be one of " + strings.Join(names, ", "))
}

// multiPart is multi over the part ?part= names (onlyPart), 400 for an unknown one.
func (s *Server) multiPart(w http.ResponseWriter, r *http.Request, parts []part) {
	ps, err := onlyPart(r, parts)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, ps)
}

// replication: the newest snapshot's objects, the instance's replication checks, and the lag of
// senders, receivers, slots and Aurora replicas over the window.
func (s *Server) replication(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// about 600 points per object over any window, never finer than the one-minute collection
	step := int(math.Ceil(to.Sub(from).Seconds() / 600))
	if step < 60 {
		step = 60
	}
	s.multi(w, r, []part{
		{"latest", sqlReplLatest, []any{id}},
		{"checks", sqlReplChecks, []any{id}},
		{"series", sqlReplSeries, []any{id, from, to, step}},
		{"series_meta", `SELECT $1::int AS step_secs, $2::int AS cap`, []any{step, replSeriesCap}},
	})
}

// jobs: the instance's scheduled jobs and their runs that started in the window.
func (s *Server) jobs(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"jobs", sqlJobs, []any{id}},
		{"runs", sqlJobRuns, []any{id, from, to}},
	})
}

// logs: the log events of the window (?kind= one kind), newest first, and the count per kind.
func (s *Server) logs(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var kind *string
	if v := r.URL.Query().Get("kind"); v != "" {
		if !logparse.KnownKind(v) {
			names := make([]string, 0, len(logparse.AllKinds()))
			for _, k := range logparse.AllKinds() {
				names = append(names, string(k))
			}
			writeErr(w, http.StatusBadRequest, errors.New("kind must be one of "+strings.Join(names, ", ")))
			return
		}
		kind = &v
	}
	s.multi(w, r, []part{
		{"counts", sqlLogCounts, []any{id, from, to}},
		{"events", sqlLogEvents, []any{id, from, to, kind}},
	})
}

// config: the instance_state row, its non-default settings and extensions, and the setting changes
// recorded in the window (with the count over all time, so an empty window is not read as "never changed").
func (s *Server) config(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"state", sqlConfigState, []any{id}},
		{"settings", sqlConfigSettings, []any{id}},
		{"extensions", sqlConfigExtensions, []any{id}},
		{"history", sqlConfigHistory, []any{id, from, to}},
		{"history_total", sqlConfigHistoryTotal, []any{id}},
	})
}

// databases: the instance's database inventory, largest first.
func (s *Server) databases(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	t, err := s.query(r.Context(), sqlDatabases, id)
	s.reply(w, r, t, err)
}
