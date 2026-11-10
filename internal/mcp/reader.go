package mcp

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// sqlReaderCheck reads what the login may do in the repository. Every column but the first must be
// false for a reader; the first (USAGE on the schema) must be true.
const sqlReaderCheck = `
SELECT has_schema_privilege('pgvigil', 'USAGE') AS reads,
       r.rolsuper OR r.rolbypassrls AS superuser,
       has_schema_privilege('pgvigil', 'CREATE') AS creates,
       EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
                  AND has_table_privilege(c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')) AS writes,
       coalesce((SELECT pg_has_role('pgvigil_collector', 'MEMBER') FROM pg_roles WHERE rolname = 'pgvigil_collector'), false) AS collector,
       coalesce((SELECT pg_has_role('pgvigil_auth', 'MEMBER') FROM pg_roles WHERE rolname = 'pgvigil_auth'), false) AS auth
  FROM pg_roles r WHERE r.rolname = current_user`

// CheckReader connects as dsn and refuses a login that can do more than read the repository: a
// superuser, the schema's owner or anyone with CREATE on it, a login that may change any table or view of the schema, the
// collector (its import functions write), or the UI's pgvigil_auth (it reads the password hashes).
// The door's login is IN ROLE pgvigil_reader and nothing else.
func CheckReader(ctx context.Context, dsn string) (user string, err error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return "", errors.New("the dsn does not parse") // the parser's message can carry the dsn
	}
	cfg.ConnectTimeout = 15 * time.Second
	cfg.RuntimeParams["application_name"] = "pgvigil-mcp"
	cfg.RuntimeParams["default_transaction_read_only"] = "on"
	cfg.RuntimeParams["statement_timeout"] = "15000"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return "", fmt.Errorf("repository: %w", err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	user = cfg.User
	var reads, super, creates, writes, collector, auth bool
	if err := conn.QueryRow(ctx, sqlReaderCheck).Scan(&reads, &super, &creates, &writes, &collector, &auth); err != nil {
		if strings.Contains(err.Error(), "does not exist") {
			return user, errors.New("the repository has no pgvigil schema: run 'pgvigil migrate' as its owner first")
		}
		return user, fmt.Errorf("reader check: %w", err)
	}
	var why []string
	if super {
		why = append(why, "is a superuser (or bypasses row security)")
	}
	if creates {
		why = append(why, "may CREATE in the pgvigil schema (its owner?)")
	}
	if writes {
		why = append(why, "may change the repository's tables")
	}
	if collector {
		why = append(why, "holds pgvigil_collector (the collector's import functions write)")
	}
	if auth {
		why = append(why, "holds pgvigil_auth (it reads the UI's password hashes)")
	}
	if len(why) > 0 {
		return user, fmt.Errorf("refused: the login %s %s; pgvigil mcp runs as a login IN ROLE pgvigil_reader alone ('pgvigil roles' prints it)", user, strings.Join(why, ", "))
	}
	if !reads {
		return user, fmt.Errorf("the login %s may not read the repository: as its owner run GRANT pgvigil_reader TO %s", user, user)
	}
	return user, nil
}
