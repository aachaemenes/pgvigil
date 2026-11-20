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
	Role          string // viewer, operator or admin (B24f)
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

// Roles are the web UI's roles, lowest first (B24f): viewer reads, operator acts on a monitored server and
// acknowledges, admin changes configuration others live with.
var Roles = []string{"viewer", "operator", "admin"}

// RoleName checks a role name before the round trip (the table's CHECK says the same).
func RoleName(s string) (string, error) {
	r := strings.ToLower(strings.TrimSpace(s))
	for _, x := range Roles {
		if r == x {
			return r, nil
		}
	}
	return "", fmt.Errorf("role %q: one of %s", s, strings.Join(Roles, ", "))
}

func uiErr(verb string, err error) error {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "42P01", "42501":
			return fmt.Errorf("%s: the repository has no UI login yet, or this is not its owner: run 'pgvigil migrate' as the owner (%s)", verb, pg.Message)
		case "42703", "42883":
			return fmt.Errorf("%s: the repository has no UI roles yet: run 'pgvigil migrate' as the owner (%s)", verb, pg.Message)
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
	rows, err := r.pool.Query(ctx, `SELECT username, role, is_disabled, created_at, password_set_at FROM pgvigil.ui_users ORDER BY username`)
	if err != nil {
		return nil, uiErr("list", err)
	}
	defer rows.Close()
	var out []UIUser
	for rows.Next() {
		var u UIUser
		if err := rows.Scan(&u.Name, &u.Role, &u.Disabled, &u.CreatedAt, &u.PasswordSetAt); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// UIUserAdd creates a user with the given argon2id hash and role (checked by RoleName). An empty role makes an admin
// when the repository has no enabled admin (its first: a fresh install's first user can change what an admin may),
// else a viewer (the locked-down default). Demoting, disabling or removing the last admin is allowed: the repository
// owner's 'pgvigil user role <name> admin' (or an add without -role) is the way back. Two adds at once take one
// advisory lock, so only one of them can be that first admin. It returns the role written and whether it was that
// first admin.
func (r *Repo) UIUserAdd(ctx context.Context, name, hash, role string) (string, bool, error) {
	var got string
	var first bool
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return "", false, uiErr("add", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('pgvigil.ui_users: the first admin'))`); err != nil {
		return "", false, uiErr("add", err)
	}
	err = tx.QueryRow(ctx, `
INSERT INTO pgvigil.ui_users (username, password_hash, role)
SELECT $1, $2, coalesce(nullif($3, ''), CASE WHEN f.first THEN 'admin' ELSE 'viewer' END)
  FROM (SELECT NOT EXISTS (SELECT 1 FROM pgvigil.ui_users WHERE role = 'admin' AND NOT is_disabled) AS first) f
RETURNING role, $3 = '' AND role = 'admin'`, name, hash, role).Scan(&got, &first)
	if err != nil {
		return "", false, uiErr("add", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return "", false, uiErr("add", err)
	}
	return got, first, nil
}

// UIUserSetRole changes a user's role; an open session follows it at its next request (ui_login_of).
func (r *Repo) UIUserSetRole(ctx context.Context, name, role string) error {
	t, err := r.pool.Exec(ctx, `UPDATE pgvigil.ui_users SET role = $2 WHERE username = $1`, name, role)
	if err != nil {
		return uiErr("role", err)
	}
	if t.RowsAffected() == 0 {
		return fmt.Errorf("role: no user %q", name)
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

// UIUserEnable turns a user on or off; a disabled user cannot log in and ui_login_of returns NULLs.
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

// UIUserRemove deletes a user, in one transaction with the user's personal views (0259's ui_views: a personal view is
// its owner's alone); a shared view the user made stays, its owner NULL (the foreign key's ON DELETE SET NULL).
func (r *Repo) UIUserRemove(ctx context.Context, name string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return uiErr("remove", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	// the user row first, locked: a view saved by the user while the remove runs waits for it (then finds no user)
	if _, err := tx.Exec(ctx, `SELECT 1 FROM pgvigil.ui_users WHERE username = $1 FOR UPDATE`, name); err != nil {
		return uiErr("remove", err)
	}
	var hasViews bool
	if err := tx.QueryRow(ctx, `SELECT to_regclass('pgvigil.ui_views') IS NOT NULL`).Scan(&hasViews); err != nil {
		return uiErr("remove", err)
	}
	if hasViews {
		if _, err := tx.Exec(ctx, `DELETE FROM pgvigil.ui_views v USING pgvigil.ui_users u
 WHERE u.username = $1 AND v.owner_user_id = u.user_id AND NOT v.shared`, name); err != nil {
			return uiErr("remove", err)
		}
	}
	t, err := tx.Exec(ctx, `DELETE FROM pgvigil.ui_users WHERE username = $1`, name)
	if err != nil {
		return uiErr("remove", err)
	}
	if t.RowsAffected() == 0 {
		return fmt.Errorf("remove: no user %q", name)
	}
	if err := tx.Commit(ctx); err != nil {
		return uiErr("remove", err)
	}
	return nil
}
