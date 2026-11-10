package collect

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// The amcheck collection (task 34): an opt-in check that READS DATA. In each connectable database where the amcheck
// extension is installed and the monitoring login was granted EXECUTE on its functions, it runs bt_index_check on
// every valid B-tree index and, on PostgreSQL 14+ with amcheck 1.3+, verify_heapam on every table, materialized view
// and TOAST table, smallest first, until the run's budget. Both read every page of the relation they check (an
// AccessShareLock, no write): on a large database that is real I/O, which is why the collection is off until the
// instance's own schedules name it, and why a grant is the client DBA's choice:
//
//	CREATE EXTENSION amcheck;  -- in each database to check
//	GRANT EXECUTE ON FUNCTION bt_index_check(regclass, boolean) TO <login>;
//	GRANT EXECUTE ON FUNCTION verify_heapam(regclass, boolean, boolean, text, bigint, bigint) TO <login>;
//
// A database without the extension or the grant is a 'skipped' row with the reason; a relation the check reports
// damage in (SQLSTATE XX001 / XX002, or verify_heapam rows) counts as corrupt with its first messages; a relation it
// could not finish (a timeout, a lock, a dropped relation) counts as an error.
func init() { Register(amcheckCollector{}) }

type amcheckCollector struct{}

const (
	amcheckRelTimeout = 5 * time.Minute  // one relation's check
	amcheckBudget     = 30 * time.Minute // one run, every database
	amcheckProblems   = 50               // messages kept per database and check
	amcheckHeapRows   = 20               // verify_heapam rows read per relation
)

func (amcheckCollector) Name() string                   { return "amcheck" }
func (amcheckCollector) DefaultInterval() time.Duration { return 0 }
func (amcheckCollector) Applies(info platform.Info) (bool, string) {
	if info.ServerVersionNum > 0 && info.ServerVersionNum < 100000 {
		return false, "amcheck's bt_index_check needs PostgreSQL 10 or later"
	}
	return true, ""
}

// Configured: the instance's own schedules must name amcheck. A file-level schedule alone does not turn it on:
// the check reads every page it checks, so it is chosen per server.
func (amcheckCollector) Configured(in config.Instance) (bool, string) {
	if d, ok := in.Schedules["amcheck"]; ok && d.Duration > 0 {
		return true, ""
	}
	return false, "amcheck is opt-in per instance: name it under the instance's schedules (it reads every page of the indexes and tables it checks)"
}

func (amcheckCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, errors.New("amcheck runs per instance")
}

// RunInstance checks conn's database and every other connectable one (its own short connection), up to
// tablesMaxDatabases, within amcheckBudget.
func (amcheckCollector) RunInstance(ctx context.Context, conn *pgx.Conn, info platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	dbs, err := tablesDatabases(ctx, conn)
	if err != nil {
		return nil, err
	}
	var cur string
	if err := conn.QueryRow(ctx, `SELECT current_database()::text`).Scan(&cur); err != nil {
		return nil, err
	}
	out := []Row{}
	if len(dbs) > tablesMaxDatabases {
		out = append(out, Row{"kind": "collector_error", "source": "amcheck",
			"message": fmt.Sprintf("%d databases: the first %d by name are checked (tablesMaxDatabases)", len(dbs), tablesMaxDatabases)})
		dbs = dbs[:tablesMaxDatabases]
	}
	deadline := time.Now().Add(amcheckBudget)
	for _, db := range dbs {
		var rows []Row
		if db == cur {
			rows, err = amcheckDB(ctx, conn, info, db, deadline)
		} else {
			rows, err = amcheckOther(ctx, in, info, db, deadline)
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			out = append(out, Row{"kind": "collector_error", "source": "amcheck:" + db, "message": err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}

func amcheckOther(ctx context.Context, in config.Instance, info platform.Info, db string, deadline time.Time) ([]Row, error) {
	dsn := in.DSN()
	if dsn == "" {
		return nil, fmt.Errorf("dsn %q resolved to an empty string", in.DSNRaw)
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.Database = db
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if _, err := conn.Exec(ctx, sessionSetup); err != nil {
		return nil, fmt.Errorf("session setup: %w", err)
	}
	return amcheckDB(ctx, conn, info, db, deadline)
}

// amcheckExtSQL: the extension's schema (quote_ident: quoted only where it must be, so the GRANT line of a skip
// reads as written by hand) and version, and the login's EXECUTE on the two functions (NULL where the function does
// not exist in that version).
const amcheckExtSQL = `
SELECT quote_ident(n.nspname)::text, e.extversion::text,
       has_function_privilege(to_regprocedure(quote_ident(n.nspname) || '.bt_index_check(regclass, boolean)'), 'EXECUTE'),
       CASE WHEN to_regprocedure(quote_ident(n.nspname) || '.verify_heapam(regclass, boolean, boolean, text, bigint, bigint)') IS NOT NULL
            THEN has_function_privilege(to_regprocedure(quote_ident(n.nspname) || '.verify_heapam(regclass, boolean, boolean, text, bigint, bigint)'), 'EXECUTE') END
  FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'amcheck'`

// amcheckIndexesSQL: every valid, ready B-tree index of a permanent or unlogged relation, smallest first.
const amcheckIndexesSQL = `
SELECT c.oid::bigint, quote_ident(n.nspname) || '.' || quote_ident(c.relname)
  FROM pg_index i
  JOIN pg_class c ON c.oid = i.indexrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_am a ON a.oid = c.relam
 WHERE a.amname = 'btree' AND i.indisvalid AND i.indisready AND c.relpersistence <> 't'
 ORDER BY pg_relation_size(c.oid), c.oid`

// amcheckTablesSQL: every table, materialized view and TOAST table of a permanent or unlogged relation, smallest first.
const amcheckTablesSQL = `
SELECT c.oid::bigint, quote_ident(n.nspname) || '.' || quote_ident(c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'm', 't') AND c.relpersistence <> 't'
 ORDER BY pg_relation_size(c.oid), c.oid`

type amRel struct {
	oid  int64
	name string
}

// amcheckDB checks one database on conn.
func amcheckDB(ctx context.Context, conn *pgx.Conn, info platform.Info, db string, deadline time.Time) ([]Row, error) {
	skip := func(check, note string) Row {
		return Row{"kind": "run", "datname": db, "check_name": check, "status": "skipped", "note": note}
	}
	var nsp, ver string
	var btOK *bool
	var heapOK *bool
	err := conn.QueryRow(ctx, amcheckExtSQL).Scan(&nsp, &ver, &btOK, &heapOK)
	if errors.Is(err, pgx.ErrNoRows) {
		note := "the amcheck extension is not installed in this database (CREATE EXTENSION amcheck)"
		return []Row{skip("bt_index_check", note), skip("verify_heapam", note)}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("amcheck extension: %w", err)
	}
	if _, err := conn.Exec(ctx, fmt.Sprintf("SET statement_timeout = %d", amcheckRelTimeout.Milliseconds())); err != nil {
		return nil, fmt.Errorf("statement_timeout: %w", err)
	}
	q := nsp
	var out []Row
	if btOK == nil || !*btOK {
		out = append(out, skip("bt_index_check", fmt.Sprintf("the login lacks EXECUTE on %s.bt_index_check(regclass, boolean): GRANT EXECUTE ON FUNCTION %s.bt_index_check(regclass, boolean) TO the monitoring login", q, q)))
	} else {
		rels, err := amcheckRels(ctx, conn, amcheckIndexesSQL)
		if err != nil {
			return nil, fmt.Errorf("indexes: %w", err)
		}
		out = append(out, amcheckRun(ctx, db, "bt_index_check", rels, deadline, func(r amRel) ([]string, error) {
			_, err := conn.Exec(ctx, fmt.Sprintf("SELECT %s.bt_index_check($1::regclass, false)", q), r.oid)
			return nil, err
		}))
	}
	switch {
	case info.ServerVersionNum > 0 && info.ServerVersionNum < 140000:
		out = append(out, skip("verify_heapam", "verify_heapam needs PostgreSQL 14 or later"))
	case heapOK == nil:
		out = append(out, skip("verify_heapam", "amcheck "+ver+" has no verify_heapam (1.3 or later: ALTER EXTENSION amcheck UPDATE)"))
	case !*heapOK:
		out = append(out, skip("verify_heapam", fmt.Sprintf("the login lacks EXECUTE on %s.verify_heapam(regclass, boolean, boolean, text, bigint, bigint): GRANT EXECUTE ON FUNCTION %s.verify_heapam(regclass, boolean, boolean, text, bigint, bigint) TO the monitoring login", q, q)))
	default:
		rels, err := amcheckRels(ctx, conn, amcheckTablesSQL)
		if err != nil {
			return nil, fmt.Errorf("tables: %w", err)
		}
		out = append(out, amcheckRun(ctx, db, "verify_heapam", rels, deadline, func(r amRel) ([]string, error) {
			rows, err := conn.Query(ctx, fmt.Sprintf(`SELECT coalesce('block ' || blkno || coalesce(' offset ' || offnum, '') || coalesce(' attribute ' || attnum, '') || ': ', '') || msg
  FROM %s.verify_heapam($1::regclass, false, false, 'none') LIMIT %d`, q, amcheckHeapRows), r.oid)
			if err != nil {
				return nil, err
			}
			msgs, err := pgx.CollectRows(rows, pgx.RowTo[string])
			return msgs, err
		}))
	}
	return out, nil
}

func amcheckRels(ctx context.Context, conn *pgx.Conn, sql string) ([]amRel, error) {
	rows, err := conn.Query(ctx, sql)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (amRel, error) {
		var a amRel
		err := r.Scan(&a.oid, &a.name)
		return a, err
	})
}

// amcheckRun runs check over rels until deadline and returns the run row. check returns the messages of damage
// (verify_heapam's rows) or an error: SQLSTATE XX001 (data corrupted) and XX002 (index corrupted) are damage, a
// relation dropped since the list (42P01) is passed over, anything else is an error of that relation.
func amcheckRun(ctx context.Context, db, name string, rels []amRel, deadline time.Time, check func(amRel) ([]string, error)) Row {
	start := time.Now()
	var checked, corrupt, errs int
	problems := []map[string]string{}
	add := func(rel, msg string) {
		if len(problems) < amcheckProblems {
			problems = append(problems, map[string]string{"relation": rel, "message": msg})
		}
	}
	note := ""
	for i, r := range rels {
		if ctx.Err() != nil || time.Now().After(deadline) {
			note = fmt.Sprintf("the run's budget (%s) was reached: %d of %d relations not checked this run", amcheckBudget, len(rels)-i, len(rels))
			break
		}
		msgs, err := check(r)
		var pe *pgconn.PgError
		switch {
		case err == nil && len(msgs) == 0:
			checked++
		case err == nil:
			checked++
			corrupt++
			for _, m := range msgs {
				add(r.name, m)
			}
		case errors.As(err, &pe) && (pe.Code == "XX001" || pe.Code == "XX002"):
			checked++
			corrupt++
			add(r.name, pe.Message+detailOf(pe))
		case errors.As(err, &pe) && pe.Code == "42P01":
			// dropped between the list and its check
		default:
			errs++
			add(r.name, "not checked: "+err.Error())
		}
	}
	status := "ok"
	switch {
	case corrupt > 0:
		status = "corrupt"
	case errs > 0 && checked == 0:
		status = "error"
	case errs > 0 || note != "":
		status = "partial"
	}
	return Row{"kind": "run", "datname": db, "check_name": name, "status": status, "checked": checked, "total": len(rels),
		"corrupt": corrupt, "errors": errs, "problems": problems, "note": nilIfEmpty(note),
		"duration_ms": time.Since(start).Milliseconds()}
}

func detailOf(pe *pgconn.PgError) string {
	if pe.Detail == "" {
		return ""
	}
	return " (" + pe.Detail + ")"
}
