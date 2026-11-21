package collect

import (
	"context"
	"fmt"
	"time"
)

// NoteInlinePasswords hands the repository the names of the file instances whose dsn carries an inline PostgreSQL
// password (L9, 0455's import_collector_inline_passwords under this run's id): the whole list of this host, so a name
// left out is fixed. 'pgvigil run' calls it once its heartbeat has started; without a heartbeat it does nothing. Only
// names travel - never a connection string. A repository without 0455 (an older store) answers an error the caller
// logs; the collection goes on.
func NoteInlinePasswords(ctx context.Context, names []string) error {
	h := current.Load()
	if h == nil || h.pool == nil {
		return nil
	}
	if names == nil {
		names = []string{}
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if _, err := h.pool.Exec(cctx, `SELECT pgvigil.import_collector_inline_passwords($1, $2)`, h.id, names); err != nil {
		return fmt.Errorf("the inline-password list: %w", err)
	}
	return nil
}
