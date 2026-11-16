package web

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	mssqldb "github.com/microsoft/go-mssqldb"
)

// community_exec.go: one community tool run, shared by serve's direct path and the request queue (task CQ, 486).

// communityRefusal is a run refused before anything was sent: the audit row it is written as, and why.
type communityRefusal struct {
	row map[string]any
	err error
}

// communityExec runs one community tool on one instance's read login: the run (its sets, outcome and statement), or
// a refusal before anything was sent with the audit row the refusal is written as. Serve's direct run (CommunityRun)
// and the request queue's worker (cq_community.go) both run it, so a run and its refusal words are one code path.
func communityExec(ctx context.Context, t *communityTool, in *communityBody, name, dsn string, no noDoor, run instanceRun, user, client string) (instanceRun, string, *communityRefusal) {
	timeout := time.Duration(in.TimeoutSecs) * time.Second
	t0 := time.Now()
	var stmt string
	// no read login on this door set: each kind refuses where it did before (a script's text is checked first),
	// before anything is sent, the set's words as the run's
	switch t.Kind {
	case "query":
		if no.Why != "" {
			run.finish(t0, nil, no.Why, nil)
			break
		}
		cfg, err := pgx.ParseConfig(dsn)
		if err != nil {
			run.finish(t0, nil, "", errors.New("the monitoring dsn does not parse"))
			break
		}
		// a database other than the login's own: the same login on that database
		if in.Database != "" {
			cfg.Database = in.Database
		}
		args := pgx.NamedArgs{}
		for _, p := range t.Params {
			v := in.Params[p.Name]
			x, err := paramValue(p, &v)
			if err != nil {
				return run, stmt, &communityRefusal{run.audit(map[string]any{"op": "community_run", "ui_user": user, "client": client, "tool": t.ID,
					"instance_id": in.InstanceID, "instance": name, "params": map[string]any{"values": in.Params, "database": in.Database}}), fmt.Errorf("parameter %s %w", p.Name, err)}
			}
			args[p.Name] = x
		}
		stmt = t.SQL
		if t.ID == "pg_top_statements" {
			// the view in the schema the extension was created in, whatever the login's search path
			schema, err := pgExtSchema(ctx, cfg, "pg_stat_statements")
			if err != nil {
				run.finish(t0, nil, "", err)
				break
			}
			if schema == "" {
				run.finish(t0, nil, "pg_stat_statements is not created in this database: a superuser-class role runs CREATE EXTENSION pg_stat_statements there", nil)
				break
			}
			stmt = strings.Replace(stmt, "FROM pg_stat_statements s", "FROM "+pgx.Identifier{schema, "pg_stat_statements"}.Sanitize()+" s", 1)
		}
		sets, why, err := runPG(ctx, cfg, stmt, args, timeout, 5000, nil)
		run.finish(t0, sets, why, err)
	case "script":
		text := strings.TrimSpace(in.Text)
		if text == "" || len(text) > 128<<10 {
			return run, stmt, &communityRefusal{run.audit(map[string]any{"op": "community_run", "ui_user": user, "client": client, "tool": t.ID,
				"instance_id": in.InstanceID, "instance": name, "report_name": in.QueryName}), errors.New("text is the query to run, 1 to 128 KB (pick a query of the script)")}
		}
		stmt = text
		if in.Database != "" {
			stmt = "USE " + msQuote(in.Database) + ";\n" + text
		}
		if no.Why != "" {
			run.finish(t0, nil, no.Why, nil)
			break
		}
		sets, why, err := runMS(ctx, dsn, stmt, nil, timeout, 5000, true)
		run.finish(t0, sets, why, err)
	default:
		if no.Why != "" {
			run.finish(t0, nil, no.Why, nil)
			break
		}
		db, conn, why, err := openMS(ctx, dsn, "pgvigil-community")
		if err != nil || why != "" {
			run.finish(t0, nil, why, err)
			break
		}
		in.Database = msDB(in.Database)
		params, _, found, err := readProcParams(ctx, conn, in.Database, t.Name, t.Help)
		switch {
		case err != nil:
			run.finish(t0, nil, "", fmt.Errorf("the parameters of %s could not be read: %v", t.Name, err))
		case !found:
			run.finish(t0, nil, fmt.Sprintf("%s is not installed in %s on %s: pgvigil never installs it; get it from %s", t.Name, in.Database, name, t.URL), nil)
		}
		if run.Outcome != "" {
			_ = conn.Close()
			_ = db.Close()
			break
		}
		byName := map[string]procParam{}
		for _, p := range params {
			byName[strings.ToLower(strings.TrimPrefix(p.Name, "@"))] = p
		}
		keys := make([]string, 0, len(in.Params))
		for k := range in.Params {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var b strings.Builder
		b.WriteString("EXEC " + msQuote(in.Database) + ".[dbo]." + msQuote(t.Name))
		var args []any
		var bad error
		for _, k := range keys {
			v := in.Params[k]
			if strings.TrimSpace(v) == "" {
				continue
			}
			key := strings.ToLower(strings.TrimPrefix(k, "@"))
			p, ok := byName[key]
			if !ok {
				bad = fmt.Errorf("%s has no parameter @%s pgvigil passes (a parameter that writes a table, an OUTPUT one and @help are left out)", t.Name, key)
				break
			}
			x, err := msArg(p, v)
			if err != nil {
				bad = err
				break
			}
			pn := "p" + strconv.Itoa(len(args)+1)
			if len(args) > 0 {
				b.WriteString(",")
			}
			b.WriteString(" " + p.Name + " = @" + pn)
			args = append(args, sql.Named(pn, x))
		}
		if bad != nil {
			_ = conn.Close()
			_ = db.Close()
			return run, stmt, &communityRefusal{run.audit(map[string]any{"op": "community_run", "ui_user": user, "client": client, "tool": t.ID,
				"instance_id": in.InstanceID, "instance": name, "statement": b.String(), "params": map[string]any{"values": in.Params, "database": in.Database}}), bad}
		}
		stmt = b.String()
		rctx, rcancel := context.WithTimeout(ctx, timeout)
		rows, err := conn.QueryContext(rctx, stmt, args...)
		var sets []resultSet
		if err == nil {
			sets, run.AtSetCap, err = readMSWith(rows, 5000, &sizer{}, rcancel, in.ExactTypes)
		}
		rcancel()
		_ = conn.Close()
		_ = db.Close()
		run.finish(t0, sets, "", err)
		// the procedure looked at this server and said no in one of its own listed messages, before any result set:
		// still a failed run in the audit (the statement reached the server), drawn as a note
		var me mssqldb.Error
		if errors.As(err, &me) && len(sets) == 0 && declinedBy(t.Name, me) {
			run.Declined = true
			run.Error = fmt.Sprintf("%s declined: %s (msg %d, severity %d)", t.Name, strings.TrimSpace(me.Message), me.Number, me.Class)
		}
	}
	return run, stmt, nil
}
