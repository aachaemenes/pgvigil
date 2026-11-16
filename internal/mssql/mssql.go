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
	"encoding/json"
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
	"github.com/aachaemenes/pgvigil/internal/secrets"
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

// InstanceRunner is a collection that reads the instance's configuration too (a cloud door: task 390a's azure:
// block); RunOnce calls RunInstance in place of Run.
type InstanceRunner interface {
	RunInstance(ctx context.Context, conn *sql.Conn, info Info, in config.Instance) ([]collect.Row, error)
}

// Configurer is a collection that runs only where the configuration names its door; a run without it is skipped
// with the reason before any connection (as a collection that does not apply).
type Configurer interface {
	Configured(in config.Instance) (bool, string)
}

// Timeouter is what a collector adds when one run needs more (or must take less) than RunTimeout on the SQL
// Server side: a reader of an Extended Events file, a pass over every database.
type Timeouter interface {
	Timeout() time.Duration
}

// InstanceCollector is a collection whose work depends on the CONFIGURED instance (its name and tags: the custom:
// checks that reach it, ST6 mssql_custom), not only on the server it detects. Wants is asked before the connect (false
// = skipped, nothing connected or stored); RunInstance takes the place of Run.
type InstanceCollector interface {
	Wants(in config.Instance) (ok bool, why string)
	RunInstance(ctx context.Context, conn *sql.Conn, info Info, in config.Instance) ([]collect.Row, error)
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
	lastAddr  string // the address of the TCP connection it opened last, whatever its deadline (B24h-1's probe target)
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
	// every TCP connection's address, with or without the dialer's deadline (the review of B24h-1 part a #2: a DSN with
	// its own 'connection timeout' kept none, so it was never probed); the Browser's UDP dial is not one
	if strings.HasPrefix(network, "tcp") && c.RemoteAddr() != nil {
		d.lastAddr = c.RemoteAddr().String()
	}
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

// again readies the dialer for a second connect (the secret's retry, B24e review 1): its own deadline when it keeps
// one (the dsn sets no 'connection timeout'), the first connect's conns, network note and holds dropped
func (d *deadlineDialer) again() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.conns, d.netErr, d.heldSum = nil, nil, 0
	if !d.until.IsZero() {
		d.until = time.Now().Add(collect.DefaultConnectTimeout)
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
	connects.Add(1)
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
	// a password from AWS Secrets Manager (B24e) is read before anything opens: its failure is not the server's
	sec, err := readSecret(ctx, in)
	if err != nil {
		return nil, nil, fmt.Errorf("connect %s: %w", in.Name, err)
	}
	db, err := sec.open(withAppName(dsn), dl)
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
	// a refused login with a secret (18456): one Refresh, and another version's own connect (review 1: its own error,
	// its own login and deadline; the first db closed, the second one nil when it failed - never a nil db closed)
	if db2, conn2, retried, rerr := sec.retry(ctx, err, dsn, withAppName(dsn), dl, &t0); retried {
		_ = db.Close()
		db, conn, err = db2, conn2, rerr
	}
	var se *secrets.ReadError
	if errors.As(err, &se) {
		// the retry's secret side (another version's login refused by the rule): not the server's failure
		if db != nil {
			_ = db.Close()
		}
		return nil, nil, fmt.Errorf("connect %s: %w", in.Name, err)
	}
	took := connectTook(time.Since(t0), dl.heldTotal()) // the slow-connect tier: the connect, its token fetch left out
	err = collect.InstanceConnectTimed(in.Name, dl.withNetwork(ctx, err), took)
	if err != nil {
		if db != nil {
			_ = db.Close()
		}
		return nil, nil, fmt.Errorf("connect %s: %w", in.Name, err)
	}
	sec.accepted(ctx)
	if _, err := conn.ExecContext(ctx, sessionSetup); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, fmt.Errorf("session setup %s: %w", in.Name, err)
	}
	collect.NoteRemote(in.Name, dl.lastRemote()) // B24h-1b: the probe's target is the address this connection used
	dl.done()
	return db, conn, nil
}

// lastRemote: the address (ip:port) of the TCP connection the dialer opened last ("" when none)
func (d *deadlineDialer) lastRemote() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.lastAddr
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
func RunOnce(ctx context.Context, log *slog.Logger, r *repo.Repo, in config.Instance, name string) (res collect.Result) {
	c, ok := Get(name)
	if !ok {
		return collect.Result{Err: fmt.Errorf("unknown collection %q; known: %v", name, Names())}
	}
	start := time.Now()
	// every return carries the run's start, the time its collection_log row is written under (B6f3 #1)
	defer func() {
		if res.Start.IsZero() {
			res.Start = start
		}
	}()
	if ic, ok := c.(InstanceCollector); ok {
		if want, why := ic.Wants(in); !want {
			return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
		}
	}
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
	// a collection that does not apply to the instance as its last detect saw it is skipped without a connection
	// (detectcache.go): recorded on the instance the connecting run named, its row (last_seen, version) left as that
	// run wrote it - nothing was read; an instance row gone meanwhile (removed and added again) is made again first
	if info, instanceID, ok := cachedDetect(in, start); ok {
		applies, why := c.Applies(info)
		if cc, isCfg := c.(Configurer); applies && isCfg {
			applies, why = cc.Configured(in)
		}
		if !applies {
			lctx, lcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			err := r.LogCollection(lctx, instanceID, name, start, time.Since(start), "skipped", why)
			lcancel()
			if err != nil {
				ectx, ecancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
				instanceID, err = r.EnsureInstanceEngine(ectx, config.EngineSQLServer, in.Name, string(info.Kind), info.Version, info.VersionNum, false, in.Tags)
				ecancel()
				if err != nil {
					return collect.Result{Err: err, Duration: time.Since(start)}
				}
				logRun(instanceID, "skipped", why)
			}
			return collect.Result{Duration: time.Since(start), Note: " (skipped: " + why + ")"}
		}
	}
	db, conn, err := Connect(sctx, in)
	if err != nil {
		// the server did not answer: recorded, so the 'server unreachable' finding sees it (0118); a connect cut by
		// pgvigil's own shutdown (the parent ctx cancelled) is not recorded - the run's own timeout (sctx) still is
		cerr := timeoutNote(sctx, limit, err)
		var se *secrets.ReadError
		if errors.As(err, &se) && ctx.Err() == nil {
			// the password could not be read from AWS Secrets Manager (B24e): the collection's error, not the server's
			rctx, rcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			if lerr := r.LogSecretFailure(rctx, in.Name, config.EngineSQLServer, in.Platform, in.Tags, name, start, time.Since(start), err); lerr != nil {
				log.Warn("the secret's failure was not recorded", "instance", in.Name, "collection", name, "err", lerr)
			}
			rcancel()
			return collect.Result{Err: err, Duration: time.Since(start)}
		}
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
	// B6g-1 (N25 / N26): the run's own cost, read at its end on the run's one connection. Registered after the close
	// above, so it runs before it; every return below carries it - a failed read, a skip, a failed import - but a run
	// cut by its OWN timeout: the driver drops a connection whose statement hit its deadline (go-mssqldb takes
	// context.DeadlineExceeded for a broken connection), so there is nothing left to read (proven on SQL Server 2022:
	// TestSessionCostLive); such a run is not a cpu run and the hour's averages are over the runs that were read
	defer func() { endRead(ctx, conn, &res) }()
	// the minute's query round trip on this connection (B24h-1a): one batch with no parameters - one TDS round trip
	// (go-mssqldb sends sp_executesql only for a statement with arguments)
	collect.TimeRoundTrip(in.Name, func() error { _, err := conn.ExecContext(sctx, "SELECT 1"); return err })

	info, err := Detect(sctx, conn, in.Platform)
	if err != nil {
		// connected, then failed: recorded as the collection's failed run ('detect: ', B6.1's fold); the run's own
		// timeout (sctx) is recorded, a read cut by pgvigil's own shutdown (the parent ctx) is not
		derr := timeoutNote(sctx, limit, err)
		if ctx.Err() == nil {
			rctx, rcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			if lerr := r.LogRunFailure(rctx, in.Name, config.EngineSQLServer, name, start, time.Since(start), derr); lerr != nil {
				log.Warn("the failed run was not recorded", "instance", in.Name, "collection", name, "err", lerr)
			}
			rcancel()
		}
		return collect.Result{Err: fmt.Errorf("%s: %w", in.Name, derr), Duration: time.Since(start)}
	}
	if tag := poolTag(in); tag != "" {
		info.PoolTag = tag
	}
	info.LinkedServerTest = linkedServerTest(in) // task 409
	info.ReadAutoCloseDatabases = in.Reads != nil && in.Reads.AutoCloseDatabases
	info.CheckBackupFiles = in.Reads != nil && in.Reads.BackupFiles
	if info.CheckBackupFiles && name == Prefix+"backup_checks" {
		// the file check's own pool (run 301bp4: the collection's is capped at its one connection); a pool that does
		// not open leaves it nil, and the read says 'not judged: no connection for the file check'
		if fp, ferr := openBackupFilePool(ctx, in); ferr == nil {
			info.BackupFilePool = fp
			defer func() { _ = fp.Close() }()
		}
	}
	// the identity rule's lines from the instance's mssql_thresholds (the file was checked when it was read: an error
	// here leaves the defaults)
	info.IdentityWarnPct, info.IdentityCritPct, _ = IdentityLimits(in.MSSQLThresholds)
	ectx, ecancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	instanceID, err := r.EnsureInstanceEngine(ectx, config.EngineSQLServer, in.Name, string(info.Kind), info.Version, info.VersionNum, false, in.Tags)
	ecancel()
	if err != nil {
		// the repository's own failure: nothing to record it in (the hourly counts still count it)
		return collect.Result{Err: err, Duration: time.Since(start)}
	}
	rememberDetect(in, info, instanceID, start)
	ok, why := c.Applies(info)
	if cc, isCfg := c.(Configurer); ok && isCfg {
		ok, why = cc.Configured(in)
	}
	if !ok {
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
		// the HADR thresholds are configuration, not collected rows: a plain error in the hour (its log row's stage is
		// 'import', the repository's side)
		return collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
	}
	// a collection that reads on from one sequence number (the Agent job history) asks the repository where it stopped
	var rows []collect.Row
	cursorFailed := false // the read of the collector's own cursor failed: the repository's side, stage 'import' (0198)
	if ic, ok := c.(InstanceCollector); ok {
		rows, err = ic.RunInstance(sctx, conn, info, in)
	} else if cc, ok := c.(CursorCollector); ok {
		rows, err = cc.RunFrom(sctx, conn, info, func(_ context.Context, source string) (int64, bool, error) {
			cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
			defer ccancel()
			seq, found, cerr := r.MSSQLSeqCursor(cctx, instanceID, source)
			if cerr != nil {
				cursorFailed = true
			}
			return seq, found, cerr
		})
	} else if sc, ok := c.(SettingsCollector); ok {
		// a collection whose reads depend on the repository's settings (task 408): the settings first; a failed read of
		// them reads every part the login has the right for (nil settings), never nothing
		lctx, lcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
		raw, lerr := r.MSSQLSettings(lctx, instanceID, sc.SettingsFunc())
		lcancel()
		if lerr != nil {
			raw = nil
		}
		rows, err = sc.RunWithSettings(sctx, conn, info, raw)
	} else if lc, ok := c.(ListCollector); ok {
		// a collection whose list is the repository's (task 401): the defaults, pgvigil.yaml's lines and Admin's rows
		var list []CounterSpec
		lctx, lcancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
		raw, lerr := r.MSSQLCounterList(lctx, instanceID, counterEditsJSON(in))
		lcancel()
		if lerr == nil {
			list, lerr = ParseCounterList(raw)
		}
		if lerr != nil {
			logRun(instanceID, "error", lerr.Error())
			return collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, lerr), Duration: time.Since(start)}
		}
		rows, err = lc.RunList(sctx, conn, info, list)
	} else if ir, isInst := c.(InstanceRunner); isInst {
		rows, err = ir.RunInstance(sctx, conn, info, in)
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
		out := collect.Result{Err: fmt.Errorf("%s on %s: %w", name, in.Name, err), Duration: time.Since(start)}
		if cursorFailed {
			// the read of the collector's own cursor failed: the repository's side (stage 'import' on its log row), but
			// no collected row was written - a plain error in the hour (Import Failed = a write of collected rows failed)
			logStage(instanceID, "error", err.Error(), "import")
		} else {
			logRun(instanceID, "error", err.Error())
		}
		return out
	}
	collect.ApplyTextPolicy(rows, in.QueryText)
	var imp collect.Result // the run's import time (B6g-1, N27: the Import call alone, apart from the read)
	ictx, icancel := context.WithTimeout(context.WithoutCancel(ctx), repoTimeout)
	err = imp.TimedImport(func() error { return r.Import(ictx, instanceID, name, start, rows) })
	icancel()
	if err != nil {
		logStage(instanceID, "error", err.Error(), "import")
		return collect.Result{Err: fmt.Errorf("import %s from %s: %w", name, in.Name, err), Duration: time.Since(start),
			Outcome: imp.Outcome, Import: imp.Import, Imported: true}
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
	return collect.Result{Rows: len(rows), Duration: d, Note: partialNote(status, note), Outcome: collect.PartialOutcome(status),
		Import: imp.Import, Imported: imp.Imported}
}

// endRead is a run's deferred last step on its connection: the session's cost into the result. A run cut by pgvigil's
// own stop (its error set, the parent context over) is not read - its result is dropped (the scheduler counts no run a
// stop cut short), and the read would stand between the stop and the loop's end
func endRead(ctx context.Context, conn *sql.Conn, res *collect.Result) {
	if res.Err != nil && ctx.Err() != nil {
		return
	}
	res.CPUMs, res.Reads = sessionCost(ctx, conn)
}

// sessionCostSQL: the session's own running totals. A session always sees its own row of sys.dm_exec_sessions: the
// read needs nothing beyond the login.
const sessionCostSQL = `SELECT cpu_time, logical_reads FROM sys.dm_exec_sessions WHERE session_id = @@SPID`

// sessionCostTimeout bounds the end read (DBA Dash's own timeout for its usage read)
const sessionCostTimeout = 10 * time.Second

// sessionCost reads the run's own cost at its end: cpu_time in ms and logical_reads of the run's session. A run holds
// ONE connection from its connect to its close (Connect: one *sql.Conn of a pool of one), so the session's totals are
// the run's. The read is made on a context of its own within sessionCostTimeout (a run's context may be over by then).
// A run cut by its own timeout is NOT read: the driver dropped the connection with its statement (said,
// not worked around in v0.4.0). nil, nil = not read (the connection is gone, a NULL, no row): never a
// zero that would read as 'no CPU'.
func sessionCost(ctx context.Context, conn *sql.Conn) (cpuMs, reads *int64) {
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), sessionCostTimeout)
	defer cancel()
	var c, l sql.NullInt64
	if err := conn.QueryRowContext(cctx, sessionCostSQL).Scan(&c, &l); err != nil || !c.Valid || !l.Valid {
		return nil, nil
	}
	return &c.Int64, &l.Int64
}

// counterEditsJSON: pgvigil.yaml's mssql_counters lines of an instance (the root's, then its own) as the repository's
// list function takes them.
func counterEditsJSON(in config.Instance) []byte {
	out := []map[string]string{}
	for _, l := range []struct {
		layer string
		e     config.CounterEdits
	}{{"root", in.MSSQLCountersRoot}, {"instance", in.MSSQLCounters}} {
		for _, set := range []struct {
			action string
			refs   []config.CounterRef
		}{{"add", l.e.Add}, {"remove", l.e.Remove}} {
			for _, r := range set.refs {
				out = append(out, map[string]string{"layer": l.layer, "action": set.action, "object": r.Object, "counter": r.Counter,
					"inst": r.Instance, "kind": r.Kind})
			}
		}
	}
	b, _ := json.Marshal(out)
	return b
}

func init() { config.CounterInUse = CounterInUse }

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

// instanceSecret is an instance's password from AWS Secrets Manager for one connect (task B24e); the zero value = none.
type instanceSecret struct {
	ref  *secrets.Ref
	val  secrets.Value
	user string // the SQL login, by secrets.Login's rule on the dsn as written (msLogin)
}

// secretSource is the reader of the process (a test stands its own in)
type secretSource interface {
	Get(ctx context.Context, ref secrets.Ref) (secrets.Value, error)
	Refresh(ctx context.Context, ref secrets.Ref, failed string) (secrets.Value, bool, error)
	Accepted(ctx context.Context, ref secrets.Ref, version string)
}

var secretReader secretSource = secrets.Default

// readSecret reads the instance's secret (none: the zero value) and its login
func readSecret(ctx context.Context, in config.Instance) (instanceSecret, error) {
	ref := in.SecretRef()
	if ref == nil {
		return instanceSecret{}, nil
	}
	v, err := secretReader.Get(ctx, *ref)
	if err != nil {
		return instanceSecret{}, err
	}
	s := instanceSecret{ref: ref}
	if err := s.use(in.DSN(), v); err != nil {
		return instanceSecret{}, err
	}
	return s, nil
}

// use takes v for the next open, with its login (a rotation may change the username: review 1)
func (s *instanceSecret) use(dsn string, v secrets.Value) error {
	user, err := msLogin(dsn, v)
	if err != nil {
		return secrets.Named(err, *s.ref)
	}
	s.val, s.user = v, user
	return nil
}

// msLogin is the SQL login of a connect with the secret, one rule for the collector, the actions door and the
// Connection Test (review 7): secrets.Login on the dsn's own login (SQL Server's names compare without case), and
// never a DOMAIN\user login (go-mssqldb signs that in through Windows, and an empty one as the service account). A
// string that does not parse is left to the open, which refuses it in its own words.
func msLogin(dsn string, v secrets.Value) (string, error) {
	dsnUser := ""
	if p, err := msdsn.Parse(dsn); err == nil {
		dsnUser = p.User
	}
	user, err := secrets.Login(dsnUser, v, true)
	if err != nil {
		return "", err
	}
	if strings.Contains(user, `\`) {
		return "", &secrets.ReadError{Code: "WindowsLogin", Message: "a DOMAIN\\user login signs in through Windows: a password from AWS Secrets Manager is a SQL login's", Refused: true}
	}
	return user, nil
}

// OpenRead opens a read login's string for a one-off connect (the actions door's check, the Connection Test): with
// sec, the secret's login (msLogin's rule) and password set on the parsed string (task B24e), never in a string;
// nil = mssqlopen.Open's.
func OpenRead(ctx context.Context, dsn string, sec *secrets.Ref) (*sql.DB, error) {
	if sec == nil {
		return mssqlopen.Open(dsn)
	}
	v, err := secretReader.Get(ctx, *sec)
	if err != nil {
		return nil, err
	}
	user, err := msLogin(dsn, v)
	if err != nil {
		return nil, secrets.Named(err, *sec)
	}
	return mssqlopen.OpenDialerCredentials(dsn, user, v.Password, nil)
}

// open opens the string as mssqlopen would, with the secret's login and password set on its parsed config
func (s instanceSecret) open(dsn string, dl *deadlineDialer) (*sql.DB, error) {
	if s.ref == nil {
		return mssqlopen.OpenDialer(dsn, dl)
	}
	return mssqlopen.OpenDialerCredentials(dsn, s.user, s.val.Password, dl)
}

// accepted tells the reader the version signed in (a held version is released)
func (s instanceSecret) accepted(ctx context.Context) {
	if s.ref != nil {
		secretReader.Accepted(ctx, *s.ref, s.val.Version)
	}
}

// retry: after a refused login (18456) with a secret, one Refresh; another version opens and connects once more with
// its own login and, when the dsn sets no timeout, its own 10 s (t0 restarted: the retry's time is its own dial's).
// retried false = the first connect's answer stands; true = the second connect's db and conn, or its own error with
// db nil.
func (s *instanceSecret) retry(ctx context.Context, err error, dsn, appDSN string, dl *deadlineDialer, t0 *time.Time) (*sql.DB, *sql.Conn, bool, error) {
	var me mssqldb.Error
	if s.ref == nil || err == nil || !errors.As(err, &me) || me.Number != 18456 {
		return nil, nil, false, nil
	}
	nv, retry, rerr := secretReader.Refresh(ctx, *s.ref, s.val.Version)
	if rerr != nil || !retry {
		return nil, nil, false, nil
	}
	if uerr := s.use(dsn, nv); uerr != nil {
		return nil, nil, true, uerr
	}
	dl.again()
	db, oerr := s.open(appDSN, dl)
	if oerr != nil {
		return nil, nil, true, oerr
	}
	db.SetMaxOpenConns(1)
	*t0 = time.Now()
	conn, cerr := db.Conn(ctx)
	if cerr != nil {
		_ = db.Close()
		return nil, nil, true, cerr
	}
	return db, conn, true, nil
}
