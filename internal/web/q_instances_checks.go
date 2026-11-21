// Admin > Instances' 'Check all' (the ServiceConfig takes, ST1): the page tests every instance - the ones of
// pgvigil.yaml too - by its own fan-out of POST /api/admin/instances op 'test', and shows for each its last test, how
// long ago it was last collected and the collection that fails now.
//
//   - op 'test' with the name of an instance of the file (fileInstanceTest): one connection as the file's own dsn,
//     which serve resolves and never sends anywhere; the result is kept by its name (import_admin_file_test, 0261)
//     and audited as the page's own tests are.
//   - GET /api/admin/instances gains the part 'checks' (instanceChecks): one row per instance of the page and of the
//     file - its last test, its newest collection that ended ok with its age by the repository's clock, and, where a
//     collection's last run ended in an error, how many do and the newest one's name and note.
//
// The two calls into this file are the WIRING patch's (scripts/admin-instances-wiring.patch: q_instances_admin.go is shared).

package web

import (
	"context"
	"database/sql"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/microsoft/go-mssqldb/msdsn"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// fileInstance finds an instance of pgvigil.yaml by its name.
func (a *InstancesAdmin) fileInstance(name string) (config.Instance, bool) {
	for _, in := range a.File {
		if in.Name == name {
			return in, true
		}
	}
	return config.Instance{}, false
}

// engineOf is an instance's engine as the file means it (none named = PostgreSQL).
func engineOf(in config.Instance) string {
	if in.Engine == "" {
		return config.EnginePostgres
	}
	return in.Engine
}

// emptyFileDSN is what a test of a file instance says when its dsn resolves to nothing; unparsedFileDSN when it does
// not parse.
const (
	emptyFileDSN    = "the instance's dsn in pgvigil.yaml resolved to an empty string (an unset variable or an unreadable file)"
	unparsedFileDSN = "the instance's dsn in pgvigil.yaml does not parse (its text is not shown: it may hold a password)"
)

// fileDSNError says why a file instance's dsn cannot be used, in fixed words, or "". A parse error is never passed on:
// pgconn's ParseConfigError carries the whole string and masks a password only in its usual spellings - a PostgreSQL
// dsn refused because a file it names could not be read adds that file error's own words (collect.UnreadFileWords), as
// the collector's connect and the page's connection test do.
func fileDSNError(engine, dsn string) string {
	if strings.TrimSpace(dsn) == "" {
		return emptyFileDSN
	}
	var err error
	switch engine {
	case config.EngineSQLServer:
		_, err = msdsn.Parse(dsn)
	default:
		_, err = pgx.ParseConfig(dsn)
		if err != nil {
			return unparsedFileDSN + collect.UnreadFileWords(err)
		}
	}
	if err != nil {
		return unparsedFileDSN
	}
	return ""
}

// boundedDialer is the SQL Server reads' dialer: each connection's socket ends at the deadline of the context its read
// runs under, whatever the driver sets later (go-mssqldb bounds the dial alone by the context: a server that accepts
// and never answers the login would hold the request).
type boundedDialer struct{}

func (boundedDialer) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	c, err := (&net.Dialer{KeepAlive: 30 * time.Second}).DialContext(ctx, network, addr)
	if err != nil {
		return nil, err
	}
	until, ok := ctx.Deadline()
	if !ok {
		return c, nil
	}
	if err := c.SetDeadline(until); err != nil {
		_ = c.Close()
		return nil, err
	}
	return &boundedConn{Conn: c, until: until}, nil
}

// boundedConn is a connection whose deadlines never go past until.
type boundedConn struct {
	net.Conn
	until time.Time
}

func (c *boundedConn) held(t time.Time) time.Time {
	if t.IsZero() || t.After(c.until) {
		return c.until
	}
	return t
}
func (c *boundedConn) SetDeadline(t time.Time) error      { return c.Conn.SetDeadline(c.held(t)) }
func (c *boundedConn) SetReadDeadline(t time.Time) error  { return c.Conn.SetReadDeadline(c.held(t)) }
func (c *boundedConn) SetWriteDeadline(t time.Time) error { return c.Conn.SetWriteDeadline(c.held(t)) }

// openBoundedMSSQL opens a SQL Server read whose every connection ends at its context's deadline.
func openBoundedMSSQL(dsn, app string) (*sql.DB, error) {
	return mssqlopen.OpenDialer(mssqlApp(dsn, app), boundedDialer{})
}

// testFileConnection is testConnection for an instance of the file, bounded the same on both engines (10 s).
func testFileConnection(ctx context.Context, engine, dsn string) (bool, string) {
	if engine != config.EngineSQLServer {
		return testConnection(ctx, engine, dsn)
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	db, err := openBoundedMSSQL(dsn, "pgvigil-admin-test")
	if err != nil {
		return false, unparsedFileDSN
	}
	defer func() { _ = db.Close() }()
	var srv, ver, login string
	if err := db.QueryRowContext(cctx, `SELECT CAST(@@SERVERNAME AS nvarchar(256)), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)), SUSER_SNAME()`).Scan(&srv, &ver, &login); err != nil {
		if cctx.Err() != nil {
			return false, "no answer within 10 seconds"
		}
		return false, err.Error()
	}
	return true, fmt.Sprintf("connected: %s, SQL Server %s, as %s", srv, ver, login)
}

// fileInstanceTest is op 'test' for an instance of the file: true = the request was answered here. A request that
// types its own host or password, a name the file does not list and a name the page owns are instanceTest's.
func (s *Server) fileInstanceTest(w http.ResponseWriter, r *http.Request, user string, in map[string]any) bool {
	name := str(in, "name")
	a := s.instAdmin()
	fi, ok := a.fileInstance(name)
	if !ok || rawStr(in, "password") != "" || str(in, "host") != "" {
		return false
	}
	ctx := r.Context()
	if have, err := s.pageInstance(ctx, name); err != nil || have != nil {
		return false
	}
	okc, detail := false, ""
	dsn := fi.DSN()
	if detail = fileDSNError(engineOf(fi), dsn); detail == "" {
		okc, detail = testFileConnection(ctx, engineOf(fi), dsn)
	}
	ans, _, err := s.callImport(ctx, "import_admin_file_test", map[string]any{"ui_user": user, "client": clientIP(r), "name": name,
		"ok": okc, "detail": detail, "file_names": a.fileNames()})
	// kept: this result is the one stored (a test older than the stored one is audited, not stored)
	kept := err == nil && ans.Outcome == "done" && ans.Detail == "tested "+name
	if !kept {
		s.log.Warn("admin instance: the file instance's test result was not kept", "name", name, "err", err, "detail", ans.Detail)
	}
	s.reply(w, r, map[string]any{"ok": okc, "detail": detail, "kept": kept}, nil)
	return true
}

// sqlInstanceChecks: $1 the file's instance names. One row per instance of the file and of the page: its last test
// (the file's from admin_file_tests, the page's from its own row), the newest collection that ended ok and its age in
// seconds by the repository's clock, and the collections whose last run ended in an error - how many, and the newest
// one's name, note and time. A skipped collection (a missing right) is not an error: the Rights read names it.
const sqlInstanceChecks = `
WITH n AS (
  SELECT f.name, 'file'::text AS source, t.tested_at, t.tested_ok, t.tested_detail
    FROM unnest($1::text[]) f(name)
    LEFT JOIN pgvigil.admin_file_tests t ON t.name = f.name
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.admin_instances a WHERE a.name = f.name)
  UNION ALL
  SELECT a.name, 'page', a.tested_at, a.tested_ok, a.tested_detail FROM pgvigil.admin_instances a
)
SELECT n.name, n.source, n.tested_at, n.tested_ok, n.tested_detail, i.instance_id, i.last_seen, ok.last_collected,
       extract(epoch FROM now() - ok.last_collected)::bigint AS collected_age_s,
       coalesce(f.failing_n, 0)::int AS failing_n, f.collection AS failing_collection, f.note AS failing_note, f.snapshot_at AS failing_at
  FROM n
  LEFT JOIN pgvigil.instances i ON i.name = n.name
  LEFT JOIN LATERAL (SELECT max(c.snapshot_at) AS last_collected FROM pgvigil.collection_dates c
                      WHERE c.instance_id = i.instance_id AND c.status = 'ok') ok ON true
  LEFT JOIN LATERAL (SELECT count(*) OVER () AS failing_n, c.collection, c.note, c.snapshot_at
                       FROM pgvigil.collection_dates c
                      WHERE c.instance_id = i.instance_id AND c.status = 'error'
                      ORDER BY c.snapshot_at DESC, c.collection LIMIT 1) f ON true
 ORDER BY n.source, n.name`

// instanceChecks adds the part 'checks' to the page's answer. Its read never fails the page: a repository without
// migration 0261 (or any error) leaves the part empty and says why in checks_error, and the rest of the page draws.
func (s *Server) instanceChecks(ctx context.Context, a *InstancesAdmin, out map[string]any) error {
	t, err := s.query(ctx, sqlInstanceChecks, a.fileNames())
	if err != nil {
		s.log.Warn("admin instances: the checks part was not read", "err", err)
		out["checks"], out["checks_error"] = nil, "the last tests and collections were not read: "+err.Error()
		return nil
	}
	out["checks"] = t
	return nil
}
