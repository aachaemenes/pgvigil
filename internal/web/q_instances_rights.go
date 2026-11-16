// Admin > Instances' 'Rights' (the ServiceConfig takes, ST2; DBA Dash's Permissions Helper with its View Script):
// POST /api/admin/instances op 'rights' {name} connects to the instance as its own monitoring login - the page's by
// its stored credential, the file's by its dsn - and reads which of the rights pgvigil needs it holds
// (internal/mssql/rights.go, internal/collect/rights.go). The answer is the list (each right, what needs it, held /
// missing / why it does not apply) and the SCRIPT of the missing ones, the login quoted by the server itself.
//
// Nothing is granted and nothing on the monitored server is changed: the read is SELECTs, and the script is text for
// an administrator to copy. The click is audited (import_admin_rights_read, 0261). The call into this file is the
// WIRING patch's (scripts/st12-wiring.patch).

package web

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// rightsRow is one right as the page shows it; the two engines' reads are turned into it.
type rightsRow struct {
	name, state, kind, neededFor, key string
}

// rightsAnswer is what one Rights read found.
type rightsAnswer struct {
	login, server, platform string
	rows                    []rightsRow
	missing, missingCore    int
	script, noScript        string
}

// instanceLogin resolves an instance's engine, platform and connection string: the page's by its stored credential,
// the file's by its dsn. The string never leaves serve.
func (s *Server) instanceLogin(ctx context.Context, name string) (engine, plat, dsn string, err error) {
	have, err := s.pageInstance(ctx, name)
	if err != nil {
		return "", "", "", err
	}
	if have != nil {
		dsn, err = resolveRef(have.Ref)
		return have.Engine, have.Platform, dsn, err
	}
	fi, ok := s.instAdmin().fileInstance(name)
	if !ok {
		return "", "", "", fmt.Errorf("no instance %q among the page's and the file's", name)
	}
	dsn = fi.DSN()
	if why := fileDSNError(engineOf(fi), dsn); why != "" {
		return "", "", "", errors.New(why)
	}
	return engineOf(fi), fi.Platform, dsn, nil
}

// readRights opens one connection as the instance's login (10 s for the whole read) and asks the engine's catalogue.
func readRights(ctx context.Context, engine, plat, dsn string, at time.Time) (rightsAnswer, error) {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	stamp := at.UTC().Format("2006-01-02 15:04") + " UTC"
	kindOf := func(core bool) string {
		if core {
			return "needed"
		}
		return "optional"
	}
	switch engine {
	case config.EngineSQLServer:
		// every connection's socket ends at the read's deadline (a server that never answers the login holds nothing)
		db, err := openBoundedMSSQL(dsn, "pgvigil-admin-rights")
		if err != nil {
			return rightsAnswer{}, errors.New("the connection string does not parse (its text is not shown: it may hold a password)")
		}
		defer func() { _ = db.Close() }()
		conn, err := db.Conn(cctx)
		if err != nil {
			return rightsAnswer{}, err
		}
		defer func() { _ = conn.Close() }()
		r, err := mssql.ReadRights(cctx, conn, plat)
		if err != nil {
			return rightsAnswer{}, err
		}
		out := rightsAnswer{login: r.Login, server: r.Server, platform: "SQL Server, " + r.Platform, missing: r.Missing, missingCore: r.MissingCore, script: r.Script(stamp), noScript: r.NoScript}
		for _, x := range r.Rights {
			out.rows = append(out.rows, rightsRow{x.Name, x.State, kindOf(x.Core), x.For, x.Key})
		}
		return out, nil
	case config.EnginePostgres:
		conn, err := pgx.Connect(cctx, dsn)
		if err != nil {
			return rightsAnswer{}, err
		}
		defer func() { _ = conn.Close(context.Background()) }()
		r, err := collect.ReadRights(cctx, conn, plat)
		if err != nil {
			return rightsAnswer{}, err
		}
		out := rightsAnswer{login: r.Login, server: r.Server, platform: "PostgreSQL, " + r.Platform, missing: r.Missing, missingCore: r.MissingCore, script: r.Script(stamp), noScript: r.NoScript}
		for _, x := range r.Rights {
			out.rows = append(out.rows, rightsRow{x.Name, x.State, kindOf(x.Core), x.For, x.Key})
		}
		return out, nil
	}
	return rightsAnswer{}, fmt.Errorf("unknown engine %q", engine)
}

// instanceRights is op 'rights'. A read that cannot be made (no such instance, an unreachable server) answers ok
// false with the reason, as a test does; the click is audited either way.
func (s *Server) instanceRights(w http.ResponseWriter, r *http.Request, user string, in map[string]any) {
	ctx := r.Context()
	name := str(in, "name")
	if name == "" {
		writeErr(w, http.StatusBadRequest, errors.New("name is required"))
		return
	}
	audit := func(ok bool, detail string) {
		ans, _, err := s.callImport(ctx, "import_admin_rights_read", map[string]any{"ui_user": user, "client": clientIP(r), "name": name, "ok": ok, "detail": detail})
		if err != nil || ans.Outcome != "done" {
			s.log.Warn("admin instance: the rights read was not audited", "name", name, "err", err, "detail", ans.Detail)
		}
	}
	engine, plat, dsn, err := s.instanceLogin(ctx, name)
	if err == nil {
		var a rightsAnswer
		if a, err = readRights(ctx, engine, plat, dsn, time.Now()); err == nil {
			t := &table{Columns: []string{"right_name", "state", "kind", "needed_for", "key"}, Rows: [][]any{}}
			for _, x := range a.rows {
				t.Rows = append(t.Rows, []any{x.name, x.state, x.kind, x.neededFor, x.key})
			}
			audit(true, fmt.Sprintf("%d needed and %d optional missing, as %s", a.missingCore, a.missing-a.missingCore, a.login))
			s.reply(w, r, map[string]any{"ok": true, "login": a.login, "server": a.server, "platform": a.platform, "missing": a.missing,
				"missing_needed": a.missingCore, "rights": t, "script": a.script, "no_script": a.noScript}, nil)
			return
		}
	}
	audit(false, err.Error())
	s.reply(w, r, map[string]any{"ok": false, "detail": err.Error()}, nil)
}
