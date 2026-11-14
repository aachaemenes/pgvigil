package plans

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// ExplainTimeout bounds the planning of an on-demand EXPLAIN.
const ExplainTimeout = 15 * time.Second

// MaxStatement is the longest statement text taken for EXPLAIN.
const MaxStatement = 100000

// GenericNote marks a row planned in the generic form.
const GenericNote = "the generic plan (PREPARE + plan_cache_mode = force_generic_plan): the parameters stay $n, as an application's prepared statement is planned after its fifth execution"

// Connect opens a short-lived connection for a plan: dsn with its database replaced by datname when given, a read-only
// default, a statement timeout and a short lock timeout, the application name app. An empty dsn is refused: pgx would
// fill it from serve's own environment and sign in as serve (as openMS refuses one for SQL Server).
func Connect(ctx context.Context, dsn, datname, app string, timeout time.Duration) (*pgx.Conn, error) {
	if strings.TrimSpace(dsn) == "" {
		return nil, errors.New("no login for this instance on this server: its dsn is empty")
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, errors.New("the dsn does not parse")
	}
	if datname != "" {
		cfg.Database = datname
	}
	if cfg.ConnectTimeout == 0 || cfg.ConnectTimeout > 10*time.Second {
		cfg.ConnectTimeout = 10 * time.Second
	}
	rp := cfg.RuntimeParams
	rp["application_name"] = app
	rp["statement_timeout"] = strconv.FormatInt(timeout.Milliseconds(), 10)
	rp["lock_timeout"] = "1000"
	rp["default_transaction_read_only"] = "on"
	rp["idle_in_transaction_session_timeout"] = strconv.FormatInt(timeout.Milliseconds()+5000, 10)
	return pgx.ConnectConfig(ctx, cfg)
}

// RepoSecretsCols are three columns on the SESSION user for a run in a database that is a pgvigil repository (one
// with a pgvigil schema; elsewhere all three are false, so a monitored database keeps pg_read_all_data): a member of
// the schema's owner (MEMBER, so a NOINHERIT member too: SET ROLE / set_config('role', ...) reaches the owner and every
// table), a member of pg_read_all_data (it reads ui_users; the planner folds table_to_xml), and a direct read of the
// UI's hashes (SELECT on ui_users, EXECUTE on a ui_* function). Every pgvigil object through the catalogs: a login
// without USAGE on the schema answers, never errors. serve's pgRefusal and EXPLAIN ANALYZE's check select them.
const RepoSecretsCols = `coalesce((SELECT pg_has_role(session_user, n.nspowner, 'MEMBER') FROM pg_namespace n WHERE n.nspname = 'pgvigil'), false),
       (EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgvigil') AND coalesce(pg_has_role(session_user, to_regrole('pg_read_all_data')::oid, 'MEMBER'), false)),
       coalesce((SELECT has_table_privilege(session_user, c.oid, 'SELECT') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'pgvigil' AND c.relname = 'ui_users'), false)
         OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                     WHERE n.nspname = 'pgvigil' AND p.proname LIKE 'ui\_%' AND has_function_privilege(session_user, p.oid, 'EXECUTE'))`

// SuperMemberCol is one column on the SESSION user: a member of a superuser role other than itself (MEMBER, so a
// NOINHERIT member too): SET ROLE / set_config('role', ..., true) inside the DBA's one statement reaches that role, and
// as a superuser a read-only transaction does not stop COPY ... TO PROGRAM or pg_read_file. MEMBER and never SET: a
// server before PostgreSQL 16 knows no SET mode, so a membership granted WITH SET FALSE is refused too. serve's
// pgRefusal and EXPLAIN ANALYZE's check select it (the code review of REPORT ROLE, part B).
const SuperMemberCol = `EXISTS (SELECT 1 FROM pg_roles s WHERE s.rolsuper AND s.rolname <> session_user AND pg_has_role(session_user, s.oid, 'MEMBER'))`

// Explain plans a statement without running it, through the monitoring login (dsn) in the database datname: EXPLAIN
// (FORMAT JSON) in a read-only transaction that is rolled back. A statement with $n parameters (pg_stat_statements'
// text) is planned in the generic form: PREPARE, plan_cache_mode = force_generic_plan, EXPLAIN EXECUTE with NULLs
// (the generic plan does not look at the values). The login needs the privileges the statement needs (EXPLAIN
// checks them): pg_monitor alone cannot plan an application's statement, and the error says so.
//
// check, when set, is asked inside the read-only transaction before anything is planned (serve passes its pgRefusal:
// a login whose session user reaches past a read - a superuser, the server-file roles, pgvigil_auth, pgvigil_collector,
// CREATE on a pgvigil schema - is refused; the planner folds STABLE functions, so a planned statement can call them).
func Explain(ctx context.Context, dsn, datname, query string, check func(context.Context, pgx.Tx) (string, error)) (Row, error) {
	query = strings.TrimSpace(query)
	query = strings.TrimSpace(strings.TrimSuffix(query, ";"))
	if len(query) > MaxStatement {
		return Row{}, fmt.Errorf("the statement is longer than %d characters", MaxStatement)
	}
	sc := ScanSQL(query)
	if ok, why := sc.Explainable(); !ok {
		return Row{}, errors.New(why)
	}
	ctx, cancel := context.WithTimeout(ctx, ExplainTimeout+10*time.Second)
	defer cancel()
	conn, err := Connect(ctx, dsn, datname, "pgvigil-explain", ExplainTimeout)
	if err != nil {
		return Row{}, fmt.Errorf("the monitoring login could not connect to %s: %w", orDefault(datname), err)
	}
	defer func() { _ = conn.Close(context.WithoutCancel(ctx)) }()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return Row{}, err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if check != nil {
		why, err := check(ctx, tx)
		if err != nil {
			return Row{}, err
		}
		if why != "" {
			return Row{}, errors.New(why)
		}
	}

	var plan string
	note := ""
	// QueryExecModeExec: the extended protocol without a named statement, so the server takes one statement only
	mode := pgx.QueryExecModeExec
	if sc.MaxParam > 0 {
		if _, err := tx.Exec(ctx, `SET LOCAL plan_cache_mode = force_generic_plan`, mode); err != nil {
			return Row{}, fmt.Errorf("plan_cache_mode: %w", err)
		}
		if err := prepareOne(ctx, tx, "pgvigil_explain", query); err != nil {
			return Row{}, explainErr(err, datname, sc.Keyword)
		}
		args := strings.TrimSuffix(strings.Repeat("NULL, ", sc.MaxParam), ", ")
		err = tx.QueryRow(ctx, `EXPLAIN (FORMAT JSON) EXECUTE pgvigil_explain(`+args+`)`, mode).Scan(&plan)
		note = GenericNote
	} else {
		err = tx.QueryRow(ctx, `EXPLAIN (FORMAT JSON) `+query, mode).Scan(&plan)
	}
	if err != nil {
		return Row{}, explainErr(err, datname, sc.Keyword)
	}
	r := Build(Explained, time.Now(), "", datname, query, plan)
	if note != "" && r.PlanNote == "" {
		r.PlanNote = note
	}
	return r, nil
}

func orDefault(datname string) string {
	if datname == "" {
		return "the dsn's database"
	}
	return "database " + datname
}

// explainErr turns the server's refusals into what the user can do about them.
func explainErr(err error, datname, keyword string) error {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch {
		case pg.Code == "42501" && (keyword == "INSERT" || keyword == "UPDATE" || keyword == "DELETE" || keyword == "MERGE"):
			return fmt.Errorf("%s: EXPLAIN of an %s checks that statement's own privilege on its table, even without running it, and a "+
				"monitoring login should not hold a write privilege; plan its SELECT part here, or EXPLAIN it by hand as the application's role", pg.Message, keyword)
		case pg.Code == "42501":
			return fmt.Errorf("%s: EXPLAIN checks the statement's privileges and the monitoring login lacks one; pg_monitor alone cannot plan an "+
				"application's statement: GRANT pg_read_all_data (PostgreSQL 14+) or SELECT on the tables to it, the client DBA's opt-in", pg.Message)
		case pg.Code == "42P01" || pg.Code == "42883" || pg.Code == "42703":
			return fmt.Errorf("%s (in %s, as the monitoring login: a search_path or a database other than the application's?)", pg.Message, orDefault(datname))
		case pg.Code == "42P18":
			return fmt.Errorf("%s: a parameter's type cannot be inferred from the statement, so the generic plan cannot be made", pg.Message)
		case pg.Code == "57014":
			return fmt.Errorf("planning took longer than %s: cancelled", ExplainTimeout)
		}
		return fmt.Errorf("%s (SQLSTATE %s)", pg.Message, pg.Code)
	}
	return err
}

// prepareOne prepares a stored statement's text as name over the extended protocol, which takes ONE statement: the
// server refuses a text of several ("cannot insert multiple commands into a prepared statement"), whatever ScanSQL
// made of it. pgx sends an Exec without arguments over the simple protocol, which runs every statement of the text (a
// crafted text could COMMIT the read-only transaction and write), so tx.Exec is never used for it.
func prepareOne(ctx context.Context, tx pgx.Tx, name, query string) error {
	_, err := tx.Conn().PgConn().ExecParams(ctx, `PREPARE `+name+` AS `+query, nil, nil, nil, nil).Close()
	return err
}
