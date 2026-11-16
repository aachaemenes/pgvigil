// Package mssql is the SQL Server engine's collector frame: the connection with its safety settings, the detection
// of what the server is and what the login may read, the Collector interface with its registry, and RunOnce, which
// connects, detects, runs one collection and hands the rows to the repository's import function. A SQL Server
// collection is named mssql_<what>; its rows go to pgvigil.import_mssql_<what>. Nothing here writes to, or installs
// anything on, the monitored server.
package mssql

import (
	"context"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb" // the sqlserver driver (BSD-3)
	"github.com/microsoft/go-mssqldb/msdsn"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// Prefix starts the name of every SQL Server collection.
const Prefix = "mssql_"

// RunTimeout bounds the SQL Server side of one collection run on one instance: the connection, the detection and
// the collection's statements; a collector that is a Timeouter names its own. The repository writes of the run are not under it (repoTimeout).
const RunTimeout = 60 * time.Second

// repoTimeout bounds each repository write of a run. It starts when the write starts, so a run that used up
// RunTimeout on the SQL Server side still stores its error row.
const repoTimeout = 30 * time.Second

// Collector is one SQL Server collection type.
type Collector interface {
	// Name is the collection's name as the config, the CLI and the repository know it; it starts with Prefix.
	Name() string
	// DefaultInterval is the cadence when nothing overrides it; zero = off by default.
	DefaultInterval() time.Duration
	// Applies says whether the collection runs on this kind, version and set of rights.
	Applies(Info) (ok bool, why string)
	// Run executes the collection on an open connection.
	Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error)
}

// Timeouter is what a collector adds when one run needs more (or must take less) than RunTimeout on the SQL
// Server side: a reader of an Extended Events file, a pass over every database.
type Timeouter interface {
	Timeout() time.Duration
}

// runTimeout is the SQL Server side's deadline for one run of a collector.
func runTimeout(c Collector) time.Duration {
	if t, ok := c.(Timeouter); ok && t.Timeout() > 0 {
		return t.Timeout()
	}
	return RunTimeout
}

var registry = map[string]Collector{}

// Register adds a collector; called from each collector's init.
func Register(c Collector) {
	if !strings.HasPrefix(c.Name(), Prefix) {
		panic("a SQL Server collection is named " + Prefix + "<what>: " + c.Name())
	}
	if _, dup := registry[c.Name()]; dup {
		panic("duplicate collector " + c.Name())
	}
	registry[c.Name()] = c
}

// Names lists the registered collections, sorted.
func Names() []string {
	out := make([]string, 0, len(registry))
	for n := range registry {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Get returns a collector by name.
func Get(name string) (Collector, bool) {
	c, ok := registry[name]
	return c, ok
}

// All returns every registered collector, sorted by name.
func All() []Collector {
	names := Names()
	out := make([]Collector, 0, len(names))
	for _, n := range names {
		out = append(out, registry[n])
	}
	return out
}

// sessionSetup keeps a collector from joining a convoy on a busy server: it gives up on a lock after two seconds,
// loses any deadlock it is part of, and reads without taking shared locks (the DMVs do not care; the msdb and catalog
// reads then never wait behind a writer). go-mssqldb resets a pooled session when it is taken from the pool, so the
// settings are applied on the one connection a run holds, after it is taken.
const sessionSetup = `SET NOCOUNT ON;
SET LOCK_TIMEOUT 2000;
SET DEADLOCK_PRIORITY LOW;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;`

// withAppName names the session "pgvigil" on the SQL Server side unless the dsn names one.
func withAppName(dsn string) string {
	l := strings.ToLower(dsn)
	if strings.Contains(l, "app name") || strings.Contains(l, "app+name") || strings.Contains(l, "app%20name") || strings.Contains(l, "application name") {
		return dsn
	}
	if strings.HasPrefix(l, "sqlserver://") {
		if strings.Contains(dsn, "?") {
			return dsn + "&app+name=pgvigil"
		}
		return dsn + "?app+name=pgvigil"
	}
	if strings.HasPrefix(l, "odbc:") {
		return dsn
	}
	return strings.TrimRight(dsn, "; ") + ";app name=pgvigil"
}

// deadlineDialer is the SQL Server connector's dialer (task 201 DONE-2 N10 and N8; review part E). While the connect is
// under way:
//   - the deadline, when the DSN sets no 'connection timeout' (the connect's start + collect.DefaultConnectTimeout),
//     bounds every dial and every connection it makes, and a later deadline the driver sets is held to it: go-mssqldb
//     dials for 15 s, the SQL Server Browser read sets its own 15 s, and the login reply is read with no deadline and
//     without the context, so a server that accepts and never answers would hold the collection for good;
//   - each connection records the first network error of its dial, read or write: go-mssqldb only logs a failed
//     Browser read (a named instance with no port then fails as "no instance matching ...") and wraps a TLS
//     handshake's error with %v - withNetwork joins the recorded error, so NoAnswer sees that no one answered.
//
// done() ends both: the deadline is lifted from the connections made, later dials go without one, nothing more is
// recorded. The keep-alive is the driver's own (the DSN's keepAlive, else 30 s). Hold() pauses the deadline while an
// Entra token is fetched (mssqlopen.Holder); a Kerberos exchange with the KDC is not paused and counts toward it.
type deadlineDialer struct {
	mu        sync.Mutex
	until     time.Time
	keepAlive time.Duration
	conns     []*watchedConn
	netErr    error
	over      bool
	held      bool // Hold: the deadline lifted while the sign-in waits on a third party
	// the slow-connect tier (the pass's #7): when the hold began and how long the holds of this connect lasted - the
	// connect's own time is db.Conn's elapsed minus that, whether or not the dialer keeps a deadline
	heldAt  time.Time
	heldSum time.Duration
}

// watchedConn is a connection the dialer made: its read and write errors are noted, its deadlines held to the
// connect's while that stands.
type watchedConn struct {
	net.Conn
	d *deadlineDialer
}

func (c *watchedConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.d.note(err)
	return n, err
}

func (c *watchedConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	c.d.note(err)
	return n, err
}

func (c *watchedConn) SetDeadline(t time.Time) error     { return c.Conn.SetDeadline(c.d.clamp(t)) }
func (c *watchedConn) SetReadDeadline(t time.Time) error { return c.Conn.SetReadDeadline(c.d.clamp(t)) }
func (c *watchedConn) SetWriteDeadline(t time.Time) error {
	return c.Conn.SetWriteDeadline(c.d.clamp(t))
}

func (d *deadlineDialer) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	d.mu.Lock()
	until := d.until
	d.mu.Unlock()
	c, err := (&net.Dialer{KeepAlive: d.keepAlive, Deadline: until}).DialContext(ctx, network, addr)
	if err != nil {
		d.note(err)
		return nil, err
	}
	w := &watchedConn{Conn: c, d: d}
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.until.IsZero() {
		_ = c.SetDeadline(d.until)
		d.conns = append(d.conns, w)
	} else if d.held {
		d.conns = append(d.conns, w) // a dial under a hold gets the deadline back at its release
	}
	return w, nil
}

// clamp holds a deadline the driver sets to the connect's while that stands (none: the connect's).
func (d *deadlineDialer) clamp(t time.Time) time.Time {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.until.IsZero() && (t.IsZero() || t.After(d.until)) {
		return d.until
	}
	return t
}

// note keeps the first network error (a net.Error, an end of stream) of the connect.
func (d *deadlineDialer) note(err error) {
	if err == nil {
		return
	}
	var ne net.Error
	if !errors.As(err, &ne) && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.over && d.netErr == nil {
		d.netErr = err
	}
}

func (d *deadlineDialer) done() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, c := range d.conns {
		_ = c.Conn.SetDeadline(time.Time{})
	}
	d.conns, d.until, d.netErr, d.over = nil, time.Time{}, nil, true
}

// Hold lifts the connect's deadline while the sign-in waits on a third party - an Entra token fetched in the middle of
// the login (mssqlopen's provider; azidentity's own retries on a managed identity alone wait 2 + 4 + 8 s) - and its
// release puts back the time that was left when the hold began, from the release on: a slow identity provider is
// not read as a server that never answered (join review 2). The run's context still bounds the fetch. The deadline is
// left alone while the DSN sets its own 'connection timeout' (no deadline of the dialer's) or after done(); the hold's
// time is recorded in every case (heldTotal: the slow-connect tier leaves it out of the connect's time).
func (d *deadlineDialer) Hold() (release func()) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.held {
		return func() {}
	}
	// the hold is timed in every case (a DSN's own 'connection timeout' too: the slow-connect tier leaves it out of
	// the connect's time); the deadline is lifted only where the dialer keeps one
	d.held, d.heldAt = true, time.Now()
	lift := !d.over && !d.until.IsZero()
	var left time.Duration
	if lift {
		left = max(time.Until(d.until), 0)
		d.until = time.Time{}
		for _, c := range d.conns {
			_ = c.Conn.SetDeadline(time.Time{})
		}
	}
	return func() {
		d.mu.Lock()
		defer d.mu.Unlock()
		d.held = false
		d.heldSum += time.Since(d.heldAt)
		if !lift || d.over {
			return
		}
		d.until = time.Now().Add(left)
		for _, c := range d.conns {
			_ = c.Conn.SetDeadline(d.until)
		}
	}
}

// heldTotal: how long this connect's sign-in was held for a third party (Hold), its releases so far.
func (d *deadlineDialer) heldTotal() time.Duration {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.heldSum
}

// connectTook: a SQL Server connect's own time for the slow-connect tier - db.Conn's elapsed minus the holds (an Entra
// token fetch not counted; Kerberos, DNS, the Browser, the redirect and the collector's CPU counted); never under a
// nanosecond, so an opened connect is always timed.
func connectTook(elapsed, held time.Duration) time.Duration {
	if t := elapsed - held; t > 0 {
		return t
	}
	return time.Nanosecond
}

// withNetwork joins the network error a connection recorded during the connect to the driver's error when the driver
// dropped it - an error with no SQL Server error number that NoAnswer does not read as unanswered (the Browser's "no
// instance matching ...", a TLS handshake's '%v'). Never on a cancel.
func (d *deadlineDialer) withNetwork(ctx context.Context, err error) error {
	var num interface{ SQLErrorNumber() int32 }
	if err == nil || ctx.Err() != nil || errors.Is(err, context.Canceled) || errors.As(err, &num) || collect.NoAnswer(err) {
		return err
	}
	d.mu.Lock()
	ne := d.netErr
	d.mu.Unlock()
	if ne == nil {
		return err
	}
	return fmt.Errorf("%w (the network: %w)", err, ne)
}

// recordTarget records an instance's dial target on the beat (collect.InstanceTarget; a test replaces it).
var recordTarget = collect.InstanceTarget

// msTarget is a SQL Server DSN's dial target (task 201 DONE-2 N8): 'mssql:<host>[\<instance>]:<port>', lower-cased -
// the port the driver dials: a port given (the instance name is then moot), else 1433 with no instance name, else 0
// with the instance name (the SQL Server Browser resolves it). One server, one target (review part E's nit 5).
func msTarget(p msdsn.Config) string {
	t := "mssql:" + strings.ToLower(p.Host)
	switch {
	case p.Port != 0:
		return t + ":" + fmt.Sprint(p.Port)
	case p.Instance == "":
		return t + ":1433"
	}
	return t + "\\" + strings.ToLower(p.Instance) + ":0"
}

// Connect opens one connection to a SQL Server instance with the safety settings applied. The caller closes both.
// A DSN that sets no 'connection timeout' (or sets 0) has the connect and the session setup end after
// collect.DefaultConnectTimeout (10 s), as a PostgreSQL instance's; one that sets it keeps its own.
func Connect(ctx context.Context, in config.Instance) (*sql.DB, *sql.Conn, error) {
	dsn := in.DSN()
	if strings.TrimSpace(dsn) == "" {
		return nil, nil, collect.InstanceConnect(in.Name, fmt.Errorf("connect %s: the dsn resolved to an empty string (unset variable or unreadable file)", in.Name))
	}
	dl := &deadlineDialer{keepAlive: 30 * time.Second}
	var target string
	if p, perr := msdsn.Parse(withAppName(dsn)); perr == nil {
		target = msTarget(p)
		if p.KeepAlive != 0 {
			dl.keepAlive = p.KeepAlive
		}
		if p.ConnTimeout <= 0 {
			dl.until = time.Now().Add(collect.DefaultConnectTimeout)
		}
	}
	// through mssqlopen as every SQL Server reader (CLOUDSQL C1: fedauth, Kerberos off Windows), with the dialer on
	// the connector it chooses (the join of 201 DONE-2)
	db, err := mssqlopen.OpenDialer(withAppName(dsn), dl)
	if err != nil {
		// a string mssqlopen refuses after it parses (a fedauth it does not open, fedauth with an authenticator, an
		// identity with a password, a principal without its secret) is a configuration error, not a dial: no target is
		// recorded, so the attempt it counts never stands for its server in collector_server_down_at (join review 1)
		return nil, nil, collect.InstanceConnect(in.Name, fmt.Errorf("connect %s: dsn: %w", in.Name, err))
	}
	recordTarget(in.Name, target) // task 201 DONE-2 N8: the dial target on the beat, once the string opens
	db.SetMaxOpenConns(1)
	t0 := time.Now()
	conn, err := db.Conn(ctx)
	took := connectTook(time.Since(t0), dl.heldTotal()) // the slow-connect tier: the connect, its token fetch left out
	err = collect.InstanceConnectTimed(in.Name, dl.withNetwork(ctx, err), took)
	if err != nil {
		_ = db.Close()
		return nil, nil, fmt.Errorf("connect %s: %w", in.Name, err)
	}
	if _, err := conn.ExecContext(ctx, sessionSetup); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, fmt.Errorf("session setup %s: %w", in.Name, err)
	}
	dl.done()
	return db, conn, nil
}

// QueryRows runs one statement and returns its rows keyed by the result's column names as written. The contract
// every collector builds on, by the column's SQL Server type:
//
//   - char, varchar, nchar, nvarchar, text, ntext, xml: a string.
//   - decimal, numeric, money, smallmoney: a string of the number as the server wrote it ("12.345").
//   - bit, tinyint, smallint, int, bigint, real, float: the Go value the driver gives (bool, int64, float64).
//   - uniqueidentifier: the canonical text, upper case (6F9619FF-8B86-D011-B42D-00C04FC964FF).
//   - binary, varbinary, image, timestamp / rowversion and any other value the driver hands over as bytes
//     (a handle, a hash, context_info): "0x" and upper-case hex, the form SSMS prints and a 0x literal takes.
//   - datetimeoffset: a time.Time in UTC; it is the only time type that says which instant it means.
//   - datetime, datetime2, smalldatetime: ZONE-LESS text, 2026-11-10T07:00:00.1234567 (the fraction without its
//     trailing zeros); date: 2026-11-10; time: 07:00:00.1234567. They are whatever clock the column was written
//     in, which for almost every DMV and msdb column is the SERVER'S LOCAL time; the driver cannot know, so
//     nothing here pretends they are UTC. A collector that stores an instant converts on the SQL Server side, in
//     its SELECT (a UTC column where the DMV has one, the server's offset or AT TIME ZONE ... AT TIME ZONE 'UTC'
//     where it does not), and returns a datetimeoffset or text ending in Z.
//   - NULL: nil.
func QueryRows(ctx context.Context, conn *sql.Conn, query string, args ...any) ([]collect.Row, error) {
	rs, err := conn.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rs.Close() }()
	cols, err := rs.Columns()
	if err != nil {
		return nil, err
	}
	types, err := rs.ColumnTypes()
	if err != nil {
		return nil, err
	}
	kinds := make([]string, len(cols))
	for i := range kinds {
		if i < len(types) {
			kinds[i] = strings.ToUpper(types[i].DatabaseTypeName())
		}
	}
	var out []collect.Row
	for rs.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rs.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make(collect.Row, len(cols))
		for i, c := range cols {
			row[c] = rowValue(kinds[i], vals[i])
		}
		out = append(out, row)
	}
	return out, rs.Err()
}

// rowValue turns one scanned value into what QueryRows promises for the column's type (the driver's
// DatabaseTypeName, upper case).
func rowValue(dbType string, v any) any {
	switch x := v.(type) {
	case []byte:
		switch dbType {
		case "DECIMAL", "NUMERIC", "MONEY", "SMALLMONEY":
			return string(x)
		case "UNIQUEIDENTIFIER":
			var u mssqldb.UniqueIdentifier
			if err := u.Scan(x); err == nil {
				return u.String()
			}
		}
		return "0x" + strings.ToUpper(hex.EncodeToString(x))
	case time.Time:
		switch dbType {
		case "DATETIMEOFFSET":
			return x.UTC()
		case "DATE":
			return x.Format("2006-01-02")
		case "TIME":
			return x.Format("15:04:05.9999999")
		}
		return x.Format("2006-01-02T15:04:05.9999999")
	}
	return v
}

// RunOnce runs one SQL Server collection against one instance and stores the rows. The SQL Server side runs
// under RunTimeout; every repository write gets its own repoTimeout on a context the run's deadline (and a
// shutdown's cancel) does not cut, so a run that timed out is recorded as an error instead of leaving the
// previous ok row in place.
func RunOnce(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string) collect.Result {
	c, ok := Get(name)
	if !ok {
		return collect.Result{Err: fmt.Errorf("unknown collection %q; known: %v", name, Names())}
	}
	start := time.Now()
	limit := runTimeout(c)
	sctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	// logStage records the run with where it failed (0198: 'import' for a write into the repository); logRun names none
	logStage := func(instanceID int, status, note, stage string) {
		rctx, rcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
		defer rcancel()
		if err := r.LogCollectionStage(rctx, instanceID, name, start, time.Since(start), status, note, stage); err != nil {
			log.Warn("the collection's result was not recorded", "instance", in.Name, "collection", name, "status", status, "err", err)
		}
	}
	logRun := func(instanceID int, status, note string) { logStage(instanceID, status, note, "") }
	db, conn, err := Connect(sctx, in)
	if err != nil {
		// the server did not answer: recorded, so the 'server unreachable' finding sees it (0118); a connect cut by
		// pgvigil's own shutdown (the parent ctx cancelled) is not recorded - the run's own timeout (sctx) still is
		cerr := timeoutNote(sctx, limit, err)
		if ctx.Err() == nil {
			rctx, rcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			if lerr := r.LogConnectFailure(rctx, in.Name, config.EngineSQLServer, in.Platform, in.Tags, name, start, time.Since(start), cerr); lerr != nil {
				log.Warn("the failed connect was not recorded", "instance", in.Name, "collection", name, "err", lerr)
			}
			rcancel()
		}
		return collect.Result{Err: cerr, Duration: time.Since(start)}
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()

	info, err := Detect(sctx, conn, in.Platform)
	if err != nil {
		return collect.Result{Err: fmt.Errorf("%s: %w", in.Name, timeoutNote(sctx, limit, err)), Duration: time.Since(start)}
	}
	for _, t := range in.TagPairs() {
		if t.Key == "pool" {
			info.PoolTag = t.Value
		}
	}
	ectx, ecancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	instanceID, err := r.EnsureInstanceEngine(ectx, config.EngineSQLServer, in.Name, string(info.Kind), info.Version, info.VersionNum, false, in.Tags)
	ecancel()
	if err != nil {
		return collect.Result{Err: err, Duration: time.Since(start)}
	}
	if ok, why := c.Applies(info); !ok {
		logRun(instanceID, "skipped", why)
		return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	// a collection that reads its source from a cursor imports batch by batch, each batch with its cursor (batch.go)
	if bc, ok := c.(BatchCollector); ok {
		return runBatched(ctx, sctx, log, r, in, name, bc, conn, info, instanceID, start, limit)
	}
	tctx, tcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	err = StoreHADRThresholds(tctx, r, instanceID, name, start, in.MSSQLThresholds)
	tcancel()
	if err != nil {
		logStage(instanceID, "error", err.Error(), "import")
		return collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	// a collection that reads on from one sequence number (the Agent job history) asks the repository where it stopped
	var rows []collect.Row
	cursorFailed := false // the read of the collector's own cursor failed: the repository's side, stage 'import' (0198)
	if cc, ok := c.(CursorCollector); ok {
		rows, err = cc.RunFrom(sctx, conn, info, func(_ context.Context, source string) (int64, bool, error) {
			cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			defer ccancel()
			seq, found, cerr := r.MSSQLSeqCursor(cctx, instanceID, source)
			if cerr != nil {
				cursorFailed = true
			}
			return seq, found, cerr
		})
	} else {
		rows, err = c.Run(sctx, conn, info)
	}
	if errors.Is(err, collect.ErrSkip) {
		why := strings.TrimSuffix(err.Error(), ": "+collect.ErrSkip.Error())
		logRun(instanceID, "skipped", why)
		return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
	}
	if err != nil {
		err = timeoutNote(sctx, limit, err)
		if cursorFailed {
			logStage(instanceID, "error", err.Error(), "import")
		} else {
			logRun(instanceID, "error", err.Error())
		}
		return collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	collect.ApplyTextPolicy(rows, in.QueryText)
	ictx, icancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	err = r.Import(ictx, instanceID, name, start, rows)
	icancel()
	if err != nil {
		logStage(instanceID, "error", err.Error(), "import")
		return collect.Result{Err: fmt.Errorf("import %s from %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	// task 406: a collector that must learn its rows were stored (mssql_running_plans marks the plans it sent)
	if as, ok := c.(AfterStorer); ok {
		as.AfterStore(info, rows)
	}
	d := time.Since(start)
	status, note := "ok", ""
	for _, row := range rows {
		if row["kind"] == "collector_error" {
			status, note = "partial", fmt.Sprintf("%v: %v", row["source"], row["message"])
			break
		}
	}
	logRun(instanceID, status, note)
	log.Debug("collected", "instance", in.Name, "collection", name, "rows", len(rows), "ms", d.Milliseconds())
	return collect.Result{Rows: len(rows), Duration: d, Note: partialNote(status, note)}
}

// timeoutNote says so when an error is the run's own deadline: the driver's text for it names no cause.
func timeoutNote(sctx context.Context, limit time.Duration, err error) error {
	if errors.Is(sctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("the run hit its %d s timeout on the SQL Server side: %w", int(limit.Seconds()), err)
	}
	return err
}

func partialNote(status, note string) string {
	if status != "partial" {
		return ""
	}
	return " (partial: " + note + ")"
}
