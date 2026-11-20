package web

// REPORT ROLE: a custom report on the store (the repository) runs the DBA's own SQL, so it runs only on its own login,
// reports_dsn in pgvigil.yaml: IN ROLE pgvigil_reader alone, on serve's own repository. Serve's own repository login
// holds pgvigil_auth (it checks the UI's passwords through pgvigil.ui_password_hash), so a store report on it would
// read every UI user's password hash; a role set inside the run is no boundary (the run can set it back:
// set_config('role', 'none', true) - PostgreSQL checks a role change against the session user), so the boundary is the
// login, checked on SESSION_USER inside the run's own read-only transaction (storeRefusal). Without the key, or with a
// login that fails the check, a store run is refused with words and audited refused - never run as serve's login.
// pgvigil mcp keeps its own reader check (internal/mcp/reader.go): it runs fixed tools, no user SQL.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// ReportsConfig is the config's reports_dsn: Raw as the file writes it ("" = not in the file), DSN resolved.
type ReportsConfig struct {
	Raw string
	DSN string
}

// reportsDoor is serve's store-report login: its connection settings (built as the UI pool's, uiPoolConfig: search_path,
// jit off, the custom plans, read only) or why there is none, serve's own repository to compare with (its pool: read
// at every check, so a restart or a failover of the repository is followed, and a failed read refuses) and the latest
// check's answer for the page (a minute old at most).
type reportsDoor struct {
	cfg   *pgx.ConnConfig
	off   string // why store reports are off before any check ("" when cfg is set)
	serve rowQuerier

	mu      sync.Mutex
	checked time.Time
	why     string
}

// The words of each refusal (docs/customreports.md quotes them).
const (
	storeRule     = "a report on the store runs only as a login IN ROLE pgvigil_reader alone ('pgvigil roles' prints it)"
	storeNoKey    = "a report on the store runs only as a login IN ROLE pgvigil_reader alone: reports_dsn in pgvigil.yaml names one ('pgvigil roles' prints it); this server's repository login holds pgvigil_auth, which reads the UI's password hashes"
	storeCheckTTL = time.Minute
)

// rowQuerier is serve's pool as the door reads it (one row).
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// storeIDSQL is serve's own repository: the server's start (another server, a replica among them, started at another
// time) and the database's oid (another database of the same server).
const storeIDSQL = `SELECT pg_postmaster_start_time(), d.oid FROM pg_database d WHERE d.datname = current_database()`

// storeCheckSQL reads the SESSION user's rights (a role set at connect or in the run is undone by the run): a superuser
// or a login that bypasses row security; every role it is a MEMBER of (one it may switch to, not only one it inherits)
// but itself and pgvigil_reader - the owner (pg_database_owner), pgvigil_auth, pgvigil_collector, pg_read_all_data,
// the server-file roles, pg_monitor; USAGE on the schema; and, as a second line, the hashes themselves (SELECT on
// ui_users, EXECUTE on any ui_* function). Then serve's repository's two facts, compared with storeIDSQL's. Every
// object is found through the catalogs, never by a qualified name: a name in pgvigil (to_regclass('pgvigil.x'))
// raises 'permission denied for schema pgvigil' for a login without USAGE - the logins this check exists to refuse
// with words (reportrole-g1: noinh, none). $1 is the roles the login may be a member of beside itself: pgvigil_reader
// for the reports login; pgvigil_reader and pgvigil_investigator for the agent door's (AgentStoreRefusal).
const storeCheckSQL = `SELECT session_user::text, r.rolsuper OR r.rolbypassrls,
       coalesce((SELECT string_agg(m.rolname::text, ', ' ORDER BY m.rolname) FROM pg_roles m
                  WHERE m.rolname <> session_user AND NOT (m.rolname = ANY ($1::text[]))
                    AND pg_has_role(session_user, m.oid, 'MEMBER')), ''),
       coalesce(has_schema_privilege(session_user, to_regnamespace('pgvigil')::oid, 'USAGE'), false),
       coalesce(has_table_privilege(session_user, (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                                                    WHERE n.nspname = 'pgvigil' AND c.relname = 'ui_users'), 'SELECT'), false)
         OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                     WHERE n.nspname = 'pgvigil' AND p.proname LIKE 'ui\_%'
                       AND has_function_privilege(session_user, p.oid, 'EXECUTE')),
       pg_postmaster_start_time(),
       (SELECT d.oid FROM pg_database d WHERE d.datname = current_database())
  FROM pg_roles r WHERE r.rolname = session_user`

// newReportsDoor builds the store-report login from the config (nil or an empty key = off, with the words); serve's
// own repository is read through serve's pool at each check.
func (s *Server) newReportsDoor(_ context.Context, rc *ReportsConfig) *reportsDoor {
	d := &reportsDoor{}
	if s.pool != nil {
		d.serve = s.pool
	}
	switch {
	case rc == nil || strings.TrimSpace(rc.Raw) == "":
		d.off = storeNoKey
	case strings.TrimSpace(rc.DSN) == "":
		d.off = fmt.Sprintf("reports_dsn (%s) resolves to nothing: fill in the env file or the file it names; %s", rc.Raw, storeRule)
	default:
		pc, err := uiPoolConfig(rc.DSN, Options{AppName: "pgvigil-report"})
		if err != nil {
			d.off = "reports_dsn does not parse; " + storeRule // the parser's message can carry the dsn
		} else {
			d.cfg = pc.ConnConfig
		}
	}
	return d
}

// refusal is runPG's check for a store run, asked inside the run's own transaction.
// storeRights reads the SESSION user's rights through storeCheckSQL, allow being the roles it may be a member of beside
// itself, and says why they reach past a read (none = may go on) and whether it may read the schema at all.
func storeRights(ctx context.Context, tx pgx.Tx, allow []string) (user string, why []string, usage bool, start time.Time, oid uint32, err error) {
	var member string
	var super, hashes bool
	if err = tx.QueryRow(ctx, storeCheckSQL, allow).Scan(&user, &super, &member, &usage, &hashes, &start, &oid); err != nil {
		return
	}
	switch {
	case super: // a superuser counts as a member of every role: the one reason, not the server's every role
		why = append(why, "is a superuser (or bypasses row security)")
	case member != "":
		why = append(why, "is a member of "+member)
	}
	if hashes && member == "" && !super {
		why = append(why, "may read the UI's password hashes")
	}
	return
}

// agentRule is the agent door's rule (pgvigil mcp on a login holding pgvigil_investigator; docs/agents.md quotes it).
const agentRule = "the agent door runs as a login IN ROLE pgvigil_reader, pgvigil_investigator and nothing else ('pgvigil roles' prints it)"

// AgentStoreRefusal is the store rule for the agent door's login, asked on its SESSION user at pgvigil mcp's start and
// again inside the transaction of every run_select (a role set at connect - options=-c role= - or in the run is undone
// by the run, so the check reads the session user): a superuser, a member of any role but pgvigil_reader and
// pgvigil_investigator (pg_read_all_data, pg_read_server_files, pgvigil_alerter, the owner among them), or a login that may read
// the UI's password hashes is refused with words; "" = it may run.
func AgentStoreRefusal(ctx context.Context, tx pgx.Tx) (string, error) {
	user, why, usage, _, _, err := storeRights(ctx, tx, []string{"pgvigil_reader", "pgvigil_investigator"})
	if err != nil {
		return "", fmt.Errorf("reading the agent login's rights: %w", err)
	}
	if len(why) > 0 {
		return fmt.Sprintf("the login %s %s: %s", user, strings.Join(why, ", "), agentRule), nil
	}
	if !usage {
		return fmt.Sprintf("the login %s may not read the repository: as its owner run GRANT pgvigil_reader TO %s", user, user), nil
	}
	return "", nil
}

func (d *reportsDoor) refusal(ctx context.Context, tx pgx.Tx) (string, error) {
	user, why, usage, start, oid, err := storeRights(ctx, tx, []string{"pgvigil_reader"})
	if err != nil {
		return "", fmt.Errorf("reading the reports login's rights: %w", err)
	}
	if len(why) > 0 {
		return fmt.Sprintf("reports_dsn's login %s %s: %s", user, strings.Join(why, ", "), storeRule), nil
	}
	if !usage {
		return fmt.Sprintf("reports_dsn's login %s may not read the repository: as its owner run GRANT pgvigil_reader TO %s", user, user), nil
	}
	// serve's own repository, read now beside the login's (a restart or a failover moves the start time of both; a read
	// that fails refuses: the comparison is never skipped)
	var sStart time.Time
	var sOID uint32
	if d.serve == nil {
		return "this server's own repository could not be read to compare with reports_dsn's: nothing was run", nil
	}
	if err := d.serve.QueryRow(ctx, storeIDSQL).Scan(&sStart, &sOID); err != nil {
		return "this server's own repository could not be read to compare with reports_dsn's (" + connWords(err) + "): nothing was run", nil
	}
	if !start.Equal(sStart) || oid != sOID {
		return "reports_dsn reaches another server or database than this server's repository (a replica, a copy or another database): it names the repository the repository dsn names", nil
	}
	return "", nil
}

// state is why a store report cannot run here ("" = it can), for the page's Run and the GET: the words before any
// check, else the latest check's (at most a minute old: a check connects as the reports login and reads its rights).
// The check runs outside the lock and apart from the request's context: a GET that ends early cancels nothing, and an
// unreachable host holds no other GET behind the lock; a cancelled check is never kept.
func (d *reportsDoor) state(ctx context.Context) string {
	if d.off != "" {
		return d.off
	}
	d.mu.Lock()
	if !d.checked.IsZero() && time.Since(d.checked) < storeCheckTTL {
		why := d.why
		d.mu.Unlock()
		return why
	}
	d.mu.Unlock()
	why, keep := d.check(context.WithoutCancel(ctx))
	if keep {
		d.mu.Lock()
		d.why, d.checked = why, time.Now()
		d.mu.Unlock()
	}
	return why
}

// check connects as the reports login and asks refusal, as a run does (a failed connection is a reason too); keep is
// false for a cancelled check (its words say nothing of the login).
func (d *reportsDoor) check(ctx context.Context) (why string, keep bool) {
	cfg := d.cfg.Copy()
	cfg.ConnectTimeout = 10 * time.Second
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	conn, err := pgx.ConnectConfig(cctx, cfg)
	if err != nil {
		return "reports_dsn does not connect: " + connWords(err) + "; " + storeRule, !errors.Is(err, context.Canceled)
	}
	defer func() { _ = conn.Close(context.WithoutCancel(ctx)) }()
	tx, err := conn.BeginTx(cctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return "reports_dsn: " + err.Error(), !errors.Is(err, context.Canceled)
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	why, err = d.refusal(cctx, tx)
	if err != nil {
		return err.Error(), !errors.Is(err, context.Canceled)
	}
	return why, true
}

// connWords is a connection error without its connection string (pgx's message names the host, the user and the
// database, never the password).
func connWords(err error) string {
	s := err.Error()
	if i := strings.Index(s, "password="); i >= 0 {
		return s[:i] + "..."
	}
	return s
}

// StoreReportsOff is why a custom report on the store cannot run on this serve ("" = it can): serve's start says it
// once in a WARN.
func (s *Server) StoreReportsOff(ctx context.Context) string {
	if s.reports == nil {
		return storeNoKey
	}
	return s.reports.state(ctx)
}
