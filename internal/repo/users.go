package repo

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// UIUser is a row of pgvigil.ui_users without its hash.
type UIUser struct {
	Name          string
	Disabled      bool
	CreatedAt     time.Time
	PasswordSetAt time.Time
}

var userNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9._@-]{0,63}$`)

// UserName lower-cases and checks a UI user name (the table's own rule, said before the round trip).
func UserName(s string) (string, error) {
	n := strings.ToLower(strings.TrimSpace(s))
	if !userNameRE.MatchString(n) {
		return "", fmt.Errorf("user name %q: 1-64 characters of a-z, 0-9, . _ @ -, starting with a letter or digit", s)
	}
	return n, nil
}

func uiErr(verb string, err error) error {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "42P01", "42501":
			return fmt.Errorf("%s: the repository has no UI login yet, or this is not its owner: run 'pgvigil migrate' as the owner (%s)", verb, pg.Message)
		case "23505":
			return fmt.Errorf("%s: the user exists; 'pgvigil user passwd <name>' changes the password", verb)
		case "23514":
			return fmt.Errorf("%s: %s", verb, pg.Message)
		}
	}
	return fmt.Errorf("%s: %w", verb, err)
}

// UIUsers lists the UI users.
func (r *Repo) UIUsers(ctx context.Context) ([]UIUser, error) {
	rows, err := r.pool.Query(ctx, `SELECT username, is_disabled, created_at, password_set_at FROM pgvigil.ui_users ORDER BY username`)
	if err != nil {
		return nil, uiErr("list", err)
	}
	defer rows.Close()
	var out []UIUser
	for rows.Next() {
		var u UIUser
		if err := rows.Scan(&u.Name, &u.Disabled, &u.CreatedAt, &u.PasswordSetAt); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// UIUserAdd creates a user with the given argon2id hash.
func (r *Repo) UIUserAdd(ctx context.Context, name, hash string) error {
	if _, err := r.pool.Exec(ctx, `INSERT INTO pgvigil.ui_users (username, password_hash) VALUES ($1, $2)`, name, hash); err != nil {
		return uiErr("add", err)
	}
	return nil
}

// UIUserSetPassword replaces the hash; a disabled user stays disabled (enable is its own verb).
func (r *Repo) UIUserSetPassword(ctx context.Context, name, hash string) error {
	t, err := r.pool.Exec(ctx, `UPDATE pgvigil.ui_users SET password_hash = $2, password_set_at = now() WHERE username = $1`, name, hash)
	if err != nil {
		return uiErr("passwd", err)
	}
	if t.RowsAffected() == 0 {
		return fmt.Errorf("passwd: no user %q", name)
	}
	return nil
}

// UIUserEnable turns a user on or off; a disabled user cannot log in and ui_password_hash returns NULL.
func (r *Repo) UIUserEnable(ctx context.Context, name string, enabled bool) error {
	t, err := r.pool.Exec(ctx, `UPDATE pgvigil.ui_users SET is_disabled = NOT $2 WHERE username = $1`, name, enabled)
	if err != nil {
		return uiErr("enable", err)
	}
	if t.RowsAffected() == 0 {
		return fmt.Errorf("no user %q", name)
	}
	return nil
}

// UIUserRemove deletes a user.
func (r *Repo) UIUserRemove(ctx context.Context, name string) error {
	t, err := r.pool.Exec(ctx, `DELETE FROM pgvigil.ui_users WHERE username = $1`, name)
	if err != nil {
		return uiErr("remove", err)
	}
	if t.RowsAffected() == 0 {
		return fmt.Errorf("remove: no user %q", name)
	}
	return nil
}
