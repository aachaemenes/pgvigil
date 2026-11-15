package web

// Indexes and statistics on demand (task 414, B23): what the Indexes tab of a SQL Server instance reads past the six-
// hourly inventory.
//
//	GET  /api/mssql/indexes/depth?instance=N[&db=<database id>][&object=O&index=I][&from=&to=][&part=...]
//	  state            the mssql_constraints collection's last run
//	  usage_series     per read in the window, what the database's (or one index's) seeks, scans, lookups and updates
//	                   added (mssql_index_usage_read's deltas; a baseline read adds nothing, a reset its whole count)
//	  missing_series   the ten requests with the most benefit in the window, each read's seeks and scans added
//	  missing_top      the newest read's requests (the most benefit first): the top 10 and the scatter
//	  untrusted        the untrusted foreign keys and check constraints with the text to review
//	  constraint_dbs   each database's constraint read
//	  fragmentation    the instance's last 20 fragmentation reads
//	  switches         why a histogram or a fragmentation read is off here, or ''
//	                                                                                     -> Server.MSSQLIndexDepth
//	POST /api/mssql/stats/histogram {instance_id, database, schema, table, stats}: one statistic's histogram, read
//	     when asked and never stored, through the instance's statistics-only login (stats_dsn) or else its read login;
//	     off unless the instance's histogram switch is on (pgvigil.yaml) and its query_text policy is full; audited
//	     (custom_report_log op histogram) before the answer, sent no-store; never an MCP tool, an export or a mail
//	                                                                                     -> Server.MSSQLHistogram
//	POST /api/mssql/indexes/fragmentation/cost {instance_id, database}: the database's heap size, beside the button
//	                                                                                     -> Server.MSSQLFragCost
//	POST /api/mssql/indexes/fragmentation {instance_id, database, mode}: starts a fragmentation read (a job of this
//	     serve's: the answer is its id at once; the page polls); off unless the instance's index_fragmentation switch
//	     is on; one at a time per instance                                               -> Server.MSSQLFragStart
//	GET  /api/mssql/indexes/fragmentation?instance=N[&id=R]: one read (the newest without id) and its rows
//	                                                                                     -> Server.MSSQLFragRead
//	POST /api/mssql/indexes/fragmentation/cancel {instance_id, read_id}                  -> Server.MSSQLFragCancel
//
// The switches are pgvigil.yaml's, per instance (histogram, stats_dsn, index_fragmentation; all off by default: an
// admin's opt-in in the one place, Q15). A page instance has neither (EXPLAIN and the index advisor stay on the
// file's instances the same way). Every POST needs the UI login and the X-Pgvigil header. Nothing here writes on the
// monitored server.

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// IndexDepthGate is one instance's switches (pgvigil.yaml: histogram, stats_dsn, index_fragmentation).
type IndexDepthGate struct {
	Histogram bool
	// StatsDSN is the statistics-only login's resolved dsn; "" with StatsConfigured false = the read login
	StatsDSN        string
	StatsConfigured bool
	Fragmentation   bool
}

// IndexDepthConfig is what serve hands the server from pgvigil.yaml, by instance name.
type IndexDepthConfig struct {
	Gates map[string]IndexDepthGate
}

var indexDepthConfigs sync.Map // *Server -> IndexDepthConfig

// SetIndexDepth gives the server the instances' switches (serve calls it after Open).
func (s *Server) SetIndexDepth(c IndexDepthConfig) { indexDepthConfigs.Store(s.self(), c) }

func (s *Server) indexDepthGate(name string) IndexDepthGate {
	if v, ok := indexDepthConfigs.Load(s.self()); ok {
		return v.(IndexDepthConfig).Gates[name]
	}
	return IndexDepthGate{}
}

const (
	// histogramBudget bounds one histogram read: the connection and three small statements
	histogramBudget = 30 * time.Second
	// fragBudget bounds one fragmentation read (a job: not tied to a request, so past serve's 75 s write timeout)
	fragBudget = 10 * time.Minute
	fragBeat   = 10 * time.Second
)

// the words the page shows beside the button (task 414's FOLD F4, F6)
const (
	fragCostWords = "reads every index and heap of the database; a heap's data pages are read in full even in LIMITED. " +
		"LIMITED reads the pages above an index's leaf, SAMPLED 1 % of an index or heap of 10,000 pages or more and all of a smaller one. " +
		"Index maintenance (an offline rebuild, an ALTER) holds a table up to 30 s and can end the read. Read a busy server off-hours."
	histogramOffWords = "off: a histogram shows the column's real values; an admin turns it on (histogram: true on the instance in pgvigil.yaml)"
	fragOffWords      = "off: a fragmentation read reads every index and heap of the database; an admin turns it on (index_fragmentation: true on the instance in pgvigil.yaml)"
)

// histogramOff is why a histogram cannot be read for the instance here, or "".
func (s *Server) histogramOff(ctx context.Context, ds *doorSet, name string) string {
	g := s.indexDepthGate(name)
	switch {
	case ds.isPage("sqlserver", name):
		return "off: a histogram is read only on an instance of pgvigil.yaml (histogram: true there)"
	case !g.Histogram:
		return histogramOffWords
	}
	if qt := ds.planPolicy(name); qt != "full" {
		return fmt.Sprintf("off: this instance's query_text policy is %q, and a histogram's keys are the column's real values, so it is read under \"full\" only", qt)
	}
	if g.StatsConfigured && strings.TrimSpace(g.StatsDSN) == "" {
		return "off: the statistics login's dsn (stats_dsn) resolved to an empty string on this server"
	}
	if !g.StatsConfigured {
		if _, _, no := ds.readLogin("sqlserver", name); no.Why != "" {
			return "off: " + no.Why
		}
	}
	if why := s.serverOff(); why != "" {
		return "Reading a histogram needs " + why + "."
	}
	actx, cancel := context.WithTimeout(context.WithoutCancel(ctx), auditBudget)
	defer cancel()
	if err := s.mayAudit(actx); err != nil {
		return strings.Replace(err.Error(), "nothing was run", "no histogram is read", 1)
	}
	return ""
}

// fragOff is why a fragmentation read cannot start for the instance here, or "".
func (s *Server) fragOff(ds *doorSet, name string) string {
	switch {
	case ds.isPage("sqlserver", name):
		return "off: a fragmentation read runs only on an instance of pgvigil.yaml (index_fragmentation: true there)"
	case !s.indexDepthGate(name).Fragmentation:
		return fragOffWords
	}
	if _, _, no := ds.readLogin("sqlserver", name); no.Why != "" {
		return "off: " + no.Why
	}
	if why := s.serverOff(); why != "" {
		return "A fragmentation read needs " + why + "."
	}
	return ""
}

// ---- GET /api/mssql/indexes/depth -------------------------------------------------------------------------------

// the database filter: a database id of the index read, as the Indexes tab's selector names it
const ixDepthDB = `($4::int IS NULL OR x.database_name = (SELECT b.database_name FROM pgvigil.mssql_index_db b WHERE b.instance_id = $1 AND b.database_id = $4))`

var sqlIxDepthUsage = `
SELECT x.snapshot_at AS at, sum(x.seeks_delta) AS seeks, sum(x.scans_delta) AS scans, sum(x.lookups_delta) AS lookups, sum(x.updates_delta) AS updates,
       count(*) AS indexes_moved, count(*) FILTER (WHERE x.reset) AS reset_rows
  FROM pgvigil.mssql_index_usage_read x
 WHERE x.instance_id = $1 AND x.snapshot_at >= $2 AND x.snapshot_at <= $3 AND x.prev_at IS NOT NULL AND ` + ixDepthDB + `
   AND ($5::bigint IS NULL OR (x.object_id = $5 AND x.index_id = $6))
 GROUP BY x.snapshot_at
 ORDER BY x.snapshot_at`

var sqlIxDepthMissing = `
WITH top AS (
  SELECT x.ident FROM pgvigil.mssql_missing_index_read x
   WHERE x.instance_id = $1 AND x.snapshot_at >= $2 AND x.snapshot_at <= $3 AND ` + ixDepthDB + `
   GROUP BY x.ident ORDER BY max(x.benefit) DESC NULLS LAST, x.ident LIMIT 10)
SELECT x.ident, x.snapshot_at AS at, x.database_name AS database, x.table_ref, x.equality_columns, x.inequality_columns, x.included_columns,
       x.user_seeks, x.user_scans, x.seeks_delta, x.scans_delta, round(x.avg_impact::numeric, 1) AS avg_impact, round(x.benefit::numeric) AS benefit, x.reset
  FROM pgvigil.mssql_missing_index_read x JOIN top t ON t.ident = x.ident
 WHERE x.instance_id = $1 AND x.snapshot_at >= $2 AND x.snapshot_at <= $3
 ORDER BY x.ident, x.snapshot_at`

const sqlIxDepthMissingTop = `
SELECT m.ord, pgvigil.mssql_missing_ident(m.database_name, m.table_ref, m.equality_columns, m.inequality_columns, m.included_columns) AS ident,
       coalesce(m.database_name, 'database ' || m.database_id) AS database, m.table_ref, m.equality_columns, m.inequality_columns, m.included_columns,
       coalesce(m.user_seeks, 0) + coalesce(m.user_scans, 0) AS requests, round(m.avg_impact::numeric, 1) AS avg_impact, round(m.benefit::numeric) AS benefit,
       m.snapshot_at
  FROM pgvigil.mssql_missing_index m
 WHERE m.instance_id = $1 AND ($2::int IS NULL OR m.database_id = $2)
 ORDER BY m.ord`

var sqlIxDepthUntrusted = `
SELECT x.database_name AS database, x.kind, x.schema_name, x.table_name, x.constraint_name, x.is_disabled, x.ref_schema, x.ref_table, x.snapshot_at AS read_at,
       format('ALTER TABLE %s.%s WITH CHECK CHECK CONSTRAINT %s;', pgvigil.mssql_qname(coalesce(x.schema_name, 'dbo')), pgvigil.mssql_qname(x.table_name),
              pgvigil.mssql_qname(x.constraint_name)) AS script
  FROM pgvigil.mssql_untrusted_constraint x
 WHERE x.instance_id = $1 AND ($2::int IS NULL OR x.database_name = (SELECT b.database_name FROM pgvigil.mssql_constraint_db b WHERE b.instance_id = $1 AND b.database_id = $2))
 ORDER BY x.database_name, x.kind, x.table_name, x.constraint_name
 LIMIT 5000`

const sqlIxDepthConstraintDBs = `
SELECT b.database_id, b.database_name AS database, b.read_at, b.note, b.untrusted_fk, b.untrusted_check, b.disabled_check
  FROM pgvigil.mssql_constraint_db b
 WHERE b.instance_id = $1 AND ($2::int IS NULL OR b.database_id = $2)
 ORDER BY b.database_name`

// a running read with no beat for 60 s reads 'stopped' (serve restarted): the reader only reads; the next start or a
// Cancel marks the row
const sqlFragState = `CASE WHEN f.state = 'running' AND f.beat_at < now() - interval '60 seconds' THEN 'stopped' ELSE f.state END`

var sqlIxDepthFrag = `
SELECT f.read_id, f.database_name AS database, f.mode, f.ui_user, f.started_at, f.ended_at, ` + sqlFragState + ` AS state, f.note, f.objects_read,
       f.rows_kept, f.heap_pages, f.duration_ms, f.beat_at
  FROM pgvigil.mssql_fragmentation_read f
 WHERE f.instance_id = $1
 ORDER BY f.started_at DESC
 LIMIT 20`

// MSSQLIndexDepth is GET /api/mssql/indexes/depth.
func (s *Server) MSSQLIndexDepth(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	database, err := dbFilter(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	var object, index any
	if v := q.Get("object"); v != "" {
		o, err1 := strconv.ParseInt(v, 10, 64)
		i, err2 := strconv.Atoi(q.Get("index"))
		if err1 != nil || err2 != nil {
			writeErr(w, http.StatusBadRequest, errors.New("object and index must be an index's object_id and index_id"))
			return
		}
		object, index = o, i
	}
	name, ok := s.mssqlInstanceName(w, r, id)
	if !ok {
		return
	}
	ds := s.doorsNow()
	hOff, fOff := s.histogramOff(r.Context(), ds, name), s.fragOff(ds, name)
	login := "read"
	if s.indexDepthGate(name).StatsConfigured {
		login = "statistics"
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_constraints", "mssql_indexes"}}},
		{"usage_series", sqlIxDepthUsage, []any{id, from, to, database, object, index}},
		{"missing_series", sqlIxDepthMissing, []any{id, from, to, database}},
		{"missing_top", sqlIxDepthMissingTop, []any{id, database}},
		{"untrusted", sqlIxDepthUntrusted, []any{id, database}},
		{"constraint_dbs", sqlIxDepthConstraintDBs, []any{id, database}},
		{"fragmentation", sqlIxDepthFrag, []any{id}},
		{"switches", `SELECT $1::text AS histogram_off, $2::text AS fragmentation_off, $3::text AS histogram_login, $4::text AS cost_words`,
			[]any{hOff, fOff, login, fragCostWords}},
	})
}

// ---- the bodies -------------------------------------------------------------------------------------------------

// objectNameOK: a database, schema, table or statistic name of a request (a sysname: 1-128 characters, no NUL)
func objectNameOK(v string) bool {
	return v != "" && len([]rune(v)) <= 128 && !strings.ContainsRune(v, 0)
}

// depthBody reads a POST body of these routes: the X-Pgvigil header, a JSON object of at most 4 KB.
func depthBody(w http.ResponseWriter, r *http.Request, into any) bool {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return false
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(into); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return false
	}
	return true
}

// mssqlInstanceByID is the SQL Server instance's name for a body's instance_id, or a 400 / 404 already written.
func (s *Server) mssqlInstanceByID(w http.ResponseWriter, r *http.Request, id int) (string, bool) {
	if id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
		return "", false
	}
	name, engine, err := s.communityInstance(r.Context(), id)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return "", false
	}
	if err != nil {
		s.reply(w, r, nil, err)
		return "", false
	}
	if engine != "sqlserver" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %d is not a SQL Server instance", id))
		return "", false
	}
	return name, true
}

// ---- POST /api/mssql/stats/histogram ----------------------------------------------------------------------------

// MSSQLHistogram is POST /api/mssql/stats/histogram.
func (s *Server) MSSQLHistogram(w http.ResponseWriter, r *http.Request) {
	var in struct {
		InstanceID int    `json:"instance_id"`
		Database   string `json:"database"`
		Schema     string `json:"schema"`
		Table      string `json:"table"`
		Stats      string `json:"stats"`
	}
	if !depthBody(w, r, &in) {
		return
	}
	if !objectNameOK(in.Database) || !objectNameOK(in.Schema) || !objectNameOK(in.Table) || !objectNameOK(in.Stats) {
		writeErr(w, http.StatusBadRequest, errors.New("database, schema, table and stats are required (each a name of 1 to 128 characters)"))
		return
	}
	name, ok := s.mssqlInstanceByID(w, r, in.InstanceID)
	if !ok {
		return
	}
	ds := s.doorsNow() // the request's one door set: the policy, the logins and the generation the audit names
	if why := s.histogramOff(r.Context(), ds, name); why != "" {
		s.reply(w, r, map[string]any{"state": "off", "words": why}, nil)
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	g := s.indexDepthGate(name)
	dsn, kind, _ := ds.readLogin("sqlserver", name)
	login := "read"
	if g.StatsConfigured {
		dsn, login = g.StatsDSN, "statistics"
	}
	statName := mssqlQ(in.Schema) + "." + mssqlQ(in.Table) + "." + mssqlQ(in.Stats)
	row := (&instanceRun{Door: kind, DoorGen: ds.Gen}).audit(map[string]any{"op": "histogram", "ui_user": user, "client": clientIP(r),
		"instance_id": in.InstanceID, "instance": name,
		"params": map[string]any{"database": in.Database, "schema": in.Schema, "table": in.Table, "stats": in.Stats, "login": login}})
	auditRow := func(row map[string]any) error {
		actx, acancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
		defer acancel()
		return s.auditRun(actx, row)
	}
	// end: the audit row first, then the answer; the answer is withheld when the row cannot be written
	end := func(outcome, detail string, out map[string]any, t0 time.Time) {
		row["outcome"], row["detail"], row["duration_ms"] = outcome, detail, time.Since(t0).Milliseconds()
		if aerr := auditRow(row); aerr != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the read's audit row could not be written (%v): its answer is withheld", aerr))
			return
		}
		s.reply(w, r, out, nil)
	}
	ctx, cancel := context.WithTimeout(r.Context(), histogramBudget)
	defer cancel()
	t0 := time.Now()
	db, conn, refused, err := openMS(ctx, dsn, "pgvigil-histogram")
	switch {
	case err != nil:
		end("failed", "the "+login+" login could not connect: "+err.Error(), map[string]any{"state": "error", "words": "the " + login + " login could not connect: " + err.Error()}, t0)
		return
	case refused != "":
		why := strings.Replace(refused, "custom reports and community tools run", "a histogram is read", 1)
		end("refused", why, map[string]any{"state": "off", "words": why}, t0)
		return
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	major, build, edition, product, err := mssql.ServerBuild(ctx, conn)
	if err != nil {
		end("failed", "the server's version was not read: "+err.Error(), map[string]any{"state": "error", "words": "the server's version was not read: " + err.Error()}, t0)
		return
	}
	if okBuild, why := mssql.HistogramBuild(major, build, edition); !okBuild {
		end("refused", why+" ("+product+")", map[string]any{"state": "off", "words": "off: " + why}, t0)
		return
	}
	quoted, err := mssql.OnDemandDatabase(ctx, conn, in.Database, false)
	if err != nil {
		end("refused", err.Error(), map[string]any{"state": "off", "words": err.Error()}, t0)
		return
	}
	h, err := mssql.ReadHistogram(ctx, conn, quoted, in.Schema, in.Table, in.Stats)
	if err != nil {
		end("failed", statName+" in "+in.Database+": "+err.Error(), map[string]any{"state": "error", "words": err.Error()}, t0)
		return
	}
	state := "ok"
	if h.Off != "" {
		state = "none"
	}
	// the row and the log line name the statistic and the step count, never a key value
	row["rows"] = len(h.Steps)
	s.log.Info("histogram read", "instance", name, "user", user, "database", in.Database, "statistic", statName, "steps", len(h.Steps), "login", login)
	end("done", fmt.Sprintf("%s in %s: %d step(s)%s", statName, in.Database, len(h.Steps), map[bool]string{true: "; " + h.Off, false: ""}[h.Off != ""]),
		map[string]any{"state": state, "words": h.Off, "header": h.Header, "steps": h.Steps, "login": login}, t0)
}

// mssqlQ is QUOTENAME for the words of a row (never sent to a server)
func mssqlQ(v string) string { return "[" + strings.ReplaceAll(v, "]", "]]") + "]" }

// ---- fragmentation: the cost, the job, the poll, the Cancel -----------------------------------------------------

// serveID names this serve's jobs in their rows (a random value per process)
var serveID = func() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}()

// fragJob is a running read of this serve
type fragJob struct {
	cancel    context.CancelFunc
	cancelled atomic.Bool
	instance  int
}

var fragJobs sync.Map // read_id -> *fragJob

// MSSQLFragCost is POST /api/mssql/indexes/fragmentation/cost: the database's heap size through the read login (one
// read of sys.dm_db_partition_stats).
func (s *Server) MSSQLFragCost(w http.ResponseWriter, r *http.Request) {
	var in struct {
		InstanceID int    `json:"instance_id"`
		Database   string `json:"database"`
	}
	if !depthBody(w, r, &in) {
		return
	}
	if !objectNameOK(in.Database) {
		writeErr(w, http.StatusBadRequest, errors.New("database is required"))
		return
	}
	name, ok := s.mssqlInstanceByID(w, r, in.InstanceID)
	if !ok {
		return
	}
	ds := s.doorsNow()
	if s.sessionUser(r) == "" && s.auth != nil {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	dsn, _, no := ds.readLogin("sqlserver", name)
	if no.Why != "" {
		s.reply(w, r, map[string]any{"state": "off", "words": "off: " + no.Why, "cost_words": fragCostWords}, nil)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), histogramBudget)
	defer cancel()
	db, conn, refused, err := openMS(ctx, dsn, "pgvigil-fragcost")
	if err != nil || refused != "" {
		why := refused
		if err != nil {
			why = "the read login could not connect: " + err.Error()
		}
		s.reply(w, r, map[string]any{"state": "error", "words": why, "cost_words": fragCostWords}, nil)
		return
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	quoted, err := mssql.OnDemandDatabase(ctx, conn, in.Database, false)
	if err != nil {
		s.reply(w, r, map[string]any{"state": "error", "words": err.Error(), "cost_words": fragCostWords}, nil)
		return
	}
	heap, heaps, all, err := mssql.HeapSize(ctx, conn, quoted)
	if err != nil {
		s.reply(w, r, map[string]any{"state": "error", "words": "the database's sizes were not read: " + err.Error(), "cost_words": fragCostWords}, nil)
		return
	}
	s.reply(w, r, map[string]any{"state": "ok", "heap_pages": heap, "heaps": heaps, "all_pages": all, "heap_mb": heap * 8 / 1024, "all_mb": all * 8 / 1024,
		"cost_words": fragCostWords}, nil)
}

// fragCall runs one of 0164's fragmentation functions through the audit login.
func (s *Server) fragCall(fn string, payload map[string]any, into any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), auditBudget)
	defer cancel()
	return s.actions.audit.QueryRow(ctx, `SELECT pgvigil.`+fn+`($1, $2::jsonb)`, time.Now(), string(b)).Scan(into)
}

// MSSQLFragStart is POST /api/mssql/indexes/fragmentation.
func (s *Server) MSSQLFragStart(w http.ResponseWriter, r *http.Request) {
	var in struct {
		InstanceID int    `json:"instance_id"`
		Database   string `json:"database"`
		Mode       string `json:"mode"`
	}
	if !depthBody(w, r, &in) {
		return
	}
	mode := strings.ToUpper(strings.TrimSpace(in.Mode))
	if mode == "" {
		mode = "LIMITED"
	}
	if mode != "LIMITED" && mode != "SAMPLED" {
		writeErr(w, http.StatusBadRequest, errors.New("mode must be LIMITED or SAMPLED"))
		return
	}
	if !objectNameOK(in.Database) {
		writeErr(w, http.StatusBadRequest, errors.New("database is required"))
		return
	}
	name, ok := s.mssqlInstanceByID(w, r, in.InstanceID)
	if !ok {
		return
	}
	ds := s.doorsNow()
	if why := s.fragOff(ds, name); why != "" {
		s.reply(w, r, map[string]any{"state": "off", "words": why}, nil)
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	dsn, _, _ := ds.readLogin("sqlserver", name)
	// the connection is opened here (its refusals answer this request) and handed to the job, which closes it
	octx, ocancel := context.WithTimeout(r.Context(), histogramBudget)
	defer ocancel()
	db, conn, refused, err := openMS(octx, dsn, "pgvigil-fragmentation")
	if err != nil || refused != "" {
		why := refused
		if err != nil {
			why = "the read login could not connect: " + err.Error()
		}
		s.reply(w, r, map[string]any{"state": "refused", "words": why}, nil)
		return
	}
	handed := false
	defer func() {
		if !handed {
			_ = conn.Close()
			_ = db.Close()
		}
	}()
	quoted, err := mssql.OnDemandDatabase(octx, conn, in.Database, true)
	if err != nil {
		s.reply(w, r, map[string]any{"state": "refused", "words": err.Error()}, nil)
		return
	}
	heap, _, _, err := mssql.HeapSize(octx, conn, quoted)
	if err != nil {
		s.reply(w, r, map[string]any{"state": "refused", "words": "the database's sizes were not read: " + err.Error()}, nil)
		return
	}
	var started []byte
	if err := s.fragCall("import_mssql_fragmentation_start", map[string]any{"ui_user": user, "client": clientIP(r), "instance_id": in.InstanceID,
		"instance": name, "database": in.Database, "mode": mode, "serve_id": serveID, "heap_pages": heap}, &started); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the read's row could not be written (%v): nothing was read", err))
		return
	}
	var st struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
		ReadID  int64  `json:"read_id"`
	}
	if err := json.Unmarshal(started, &st); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	if st.Outcome != "done" {
		s.reply(w, r, map[string]any{"state": "refused", "words": st.Detail, "read_id": st.ReadID}, nil)
		return
	}
	jctx, jcancel := context.WithTimeout(context.Background(), fragBudget)
	job := &fragJob{cancel: jcancel, instance: in.InstanceID}
	fragJobs.Store(st.ReadID, job)
	handed = true
	go s.runFrag(jctx, job, st.ReadID, db, conn, name, user, in.Database, quoted, mode)
	s.reply(w, r, map[string]any{"state": "running", "read_id": st.ReadID, "heap_pages": heap, "words": fragCostWords}, nil)
}

// runFrag is the job: the read on its own context, a beat every fragBeat, the end and its rows written once.
func (s *Server) runFrag(ctx context.Context, job *fragJob, id int64, db *sql.DB, conn *sql.Conn, name, user, database, quoted, mode string) {
	defer func() {
		job.cancel()
		fragJobs.Delete(id)
		_ = conn.Close()
		_ = db.Close()
	}()
	t0 := time.Now()
	var read atomic.Int64
	done := make(chan struct{})
	go func() {
		t := time.NewTicker(fragBeat)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				var state string
				if err := s.fragCall("import_mssql_fragmentation_beat", map[string]any{"read_id": id, "objects_read": read.Load()}, &state); err != nil {
					s.log.Warn("fragmentation read: the beat was not written", "read_id", id, "err", err)
				}
			}
		}
	}()
	res, err := mssql.FragmentationRead(ctx, conn, quoted, mode, func(n int) { read.Store(int64(n)) })
	close(done)
	state, note := "done", ""
	switch {
	case err == nil:
		if res.Read > len(res.Rows) {
			note = fmt.Sprintf("%d of %d index and heap rows are under %d pages and are counted, not kept", res.Read-len(res.Rows), res.Read, mssql.FragMinPages)
		}
	case job.cancelled.Load():
		state, note = "cancelled", "cancelled by a user; the rows read before it are kept, "+res.Stopped
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		state, note = "failed", fmt.Sprintf("the read's %s budget ran out %s; the rows read before it are kept", fragBudget, res.Stopped)
	default:
		state = "failed"
		note = "the read stopped " + res.Stopped + ": " + err.Error()
		if strings.Contains(err.Error(), "1222") || strings.Contains(strings.ToLower(err.Error()), "lock request time out") {
			note += fmt.Sprintf(" (a table was held by another session for %d s: index maintenance, an offline rebuild or an ALTER, ends the read)", mssql.FragLockTimeoutMS/1000)
		}
		if len(res.Rows) > 0 {
			note += "; the rows read before it are kept"
		}
	}
	rows := make([]collect.Row, 0, len(res.Rows))
	rows = append(rows, res.Rows...)
	var final string
	if err := s.fragCall("import_mssql_fragmentation_finish", map[string]any{"read_id": id, "state": state, "note": note, "objects_read": res.Read,
		"duration_ms": time.Since(t0).Milliseconds(), "rows": rows}, &final); err != nil {
		s.log.Warn("fragmentation read: its end was not written", "read_id", id, "err", err)
	}
	s.log.Info("fragmentation read", "instance", name, "user", user, "database", database, "mode", mode, "state", state, "rows", res.Read,
		"kept", len(res.Rows), "ms", time.Since(t0).Milliseconds())
}

const sqlFragOne = `
SELECT f.read_id, f.instance_id, f.database_name AS database, f.mode, f.ui_user, f.started_at, f.ended_at, ` + sqlFragState + ` AS state, f.note,
       f.objects_read, f.rows_kept, f.heap_pages, f.duration_ms, f.beat_at, extract(epoch FROM coalesce(f.ended_at, now()) - f.started_at)::int AS secs
  FROM pgvigil.mssql_fragmentation_read f
 WHERE f.instance_id = $1 AND ($2::bigint IS NULL OR f.read_id = $2)
 ORDER BY f.started_at DESC
 LIMIT 1`

const sqlFragRows = `
SELECT x.ord, x.schema_name, x.table_name, x.index_name, x.index_type, x.partition_number, x.alloc_unit, x.page_count,
       round(x.fragment_pct::numeric, 2) AS fragment_pct, x.fragment_count, round(x.page_density::numeric, 2) AS page_density, x.record_count,
       x.forwarded, x.marked
  FROM pgvigil.mssql_fragmentation_row x
 WHERE x.read_id = (SELECT f.read_id FROM pgvigil.mssql_fragmentation_read f WHERE f.instance_id = $1 AND ($2::bigint IS NULL OR f.read_id = $2)
                     ORDER BY f.started_at DESC LIMIT 1)
 ORDER BY x.marked DESC, x.fragment_pct DESC NULLS LAST, x.page_count DESC
 LIMIT 5000`

// MSSQLFragRead is GET /api/mssql/indexes/fragmentation.
func (s *Server) MSSQLFragRead(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var rid any
	if v := r.URL.Query().Get("id"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("id must be a fragmentation read's id"))
			return
		}
		rid = n
	}
	s.multiPart(w, r, []part{
		{"read", sqlFragOne, []any{id, rid}},
		{"rows", sqlFragRows, []any{id, rid}},
	})
}

// MSSQLFragCancel is POST /api/mssql/indexes/fragmentation/cancel: this serve's job is cancelled (its context: the
// driver sends the server an attention); a read this serve does not hold is stopped when it has no beat.
func (s *Server) MSSQLFragCancel(w http.ResponseWriter, r *http.Request) {
	var in struct {
		InstanceID int   `json:"instance_id"`
		ReadID     int64 `json:"read_id"`
	}
	if !depthBody(w, r, &in) {
		return
	}
	if in.ReadID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("read_id is required"))
		return
	}
	if why := s.serverOff(); why != "" {
		s.reply(w, r, map[string]any{"state": "off", "words": "Cancelling a fragmentation read needs " + why + "."}, nil)
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	var inst int
	if err := s.pool.QueryRow(r.Context(), `SELECT instance_id FROM pgvigil.mssql_fragmentation_read WHERE read_id = $1`, in.ReadID).Scan(&inst); err != nil || inst != in.InstanceID {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no fragmentation read %d on instance %d", in.ReadID, in.InstanceID))
		return
	}
	if v, ok := fragJobs.Load(in.ReadID); ok {
		job := v.(*fragJob)
		job.cancelled.Store(true)
		job.cancel()
		s.log.Info("fragmentation read cancelled", "read_id", in.ReadID, "user", user)
		s.reply(w, r, map[string]any{"state": "cancelling", "words": "cancelled: the server ends the read; its rows so far are kept"}, nil)
		return
	}
	var out []byte
	if err := s.fragCall("import_mssql_fragmentation_stop", map[string]any{"read_id": in.ReadID, "ui_user": user}, &out); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	var st struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
	}
	_ = json.Unmarshal(out, &st)
	s.reply(w, r, map[string]any{"state": st.Outcome, "words": st.Detail}, nil)
}
