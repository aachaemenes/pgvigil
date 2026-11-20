package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// pgSigninCollector is pg_signin (PGAUTH M1; a warning, never a refusal): how the server signed the read
// login in, hourly - PostgreSQL 16's SYSTEM_USER ('auth_method:identity', NULL under trust; the method word is
// pg_hba's) and the session's own pg_stat_ssl row - with the sslmode of the instance's dsn, which only the collector
// knows. The store judges it: a password-shaped method (ldap, radius, pam, bsd, password: the password crosses in
// clear inside the session) without sslmode=verify-full is a warning on the instance. The identity is never kept
// (under ldap it is the bind DN). Under 16 the method is not readable from the client.
type pgSigninCollector struct{}

func init() { Register(pgSigninCollector{}) }

func (pgSigninCollector) Name() string                   { return "pg_signin" }
func (pgSigninCollector) DefaultInterval() time.Duration { return time.Hour }
func (pgSigninCollector) Applies(info platform.Info) (bool, string) {
	if info.ServerVersionNum < 160000 {
		return false, "SYSTEM_USER needs PostgreSQL 16 or later: the sign-in method is not readable from the client"
	}
	return true, ""
}

func (pgSigninCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("pg_signin needs the instance config: %w", ErrSkip)
}

// pgSigninSQL: the session's own sign-in (SYSTEM_USER, any login may read it) and whether it runs inside TLS (the
// session's own row of pg_stat_ssl is visible to its login)
const pgSigninSQL = `SELECT coalesce(system_user, '') AS system_user,
       coalesce((SELECT s.ssl FROM pg_stat_ssl s WHERE s.pid = pg_backend_pid()), false) AS ssl`

func (pgSigninCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	var su string
	var ssl bool
	if err := conn.QueryRow(ctx, pgSigninSQL).Scan(&su, &ssl); err != nil {
		return nil, err
	}
	return []Row{pgSigninRow(su, ssl, in.DSN())}, nil
}

// pgSigninRow is the run's one row: the method word, whether it sends the password in clear, the session's TLS and
// the dsn's sslmode (config.SSLModeOf; the empty string when the dsn does not parse)
func pgSigninRow(systemUser string, ssl bool, dsn string) Row {
	method, sends := config.PasswordShaped(systemUser)
	return Row{"kind": "signin", "method": method, "clear": sends, "ssl": ssl, "sslmode": config.SSLModeOf(dsn)}
}
