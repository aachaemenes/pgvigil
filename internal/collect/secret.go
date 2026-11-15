package collect

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// The read login's password from AWS Secrets Manager (task B24e): every PostgreSQL connect of an instance with a
// password_secret goes through dialWithSecret - collect.Connect and the per-database connects (connectCounted). The
// secret is read BEFORE the dial target is recorded, and its failure is a *secrets.ReadError, never counted as the
// server not answering or refusing the login (the server was not asked). A refused sign-in (28P01) asks the reader's
// Refresh once and retries only on another version of the secret.

// dialWithSecret fills cfg's password (and its user when the dsn names none) from the instance's secret, calls dial,
// and after a 28P01 retries once with a newer version; target is called right before each dial.
func dialWithSecret(ctx context.Context, in config.Instance, cfg *pgx.ConnConfig, target func(), dial func(*pgx.ConnConfig) (*pgx.Conn, error)) (*pgx.Conn, error) {
	ps := in.PasswordSecret
	if ps == nil {
		target()
		return dial(cfg)
	}
	ref, err := secrets.ParseRef(ps.Ref, ps.Region, ps.Profile)
	if err != nil {
		return nil, err
	}
	v, err := secrets.Default.Get(ctx, ref)
	if err != nil {
		return nil, err
	}
	if err := applyPG(cfg, in, v); err != nil {
		return nil, err
	}
	target()
	conn, err := dial(cfg)
	var pe *pgconn.PgError
	if err == nil || !errors.As(err, &pe) || pe.Code != "28P01" {
		return conn, err
	}
	nv, retry, rerr := secrets.Default.Refresh(ctx, ref, v.Version)
	if rerr != nil || !retry {
		return nil, err
	}
	if err := applyPG(cfg, in, nv); err != nil {
		return nil, err
	}
	return dial(cfg)
}

// applyPG puts the secret's password on the config, and its username when the dsn names no user; a dsn user other
// than the secret's username is refused (pgx's parsed default is PGUSER or the OS account, so the dsn as written is read)
func applyPG(cfg *pgx.ConnConfig, in config.Instance, v secrets.Value) error {
	u := dsnUser(in.DSN())
	switch {
	case u == "" && v.User != "":
		cfg.User = v.User
	case u != "" && v.User != "" && u != v.User:
		return fmt.Errorf("instance %s: the dsn's user %q is not the secret's username %q", in.Name, u, v.User)
	}
	cfg.Password = v.Password
	return nil
}

// dsnUser is the user a libpq string names as written: user= in the keyword form, the userinfo in the URL form
func dsnUser(dsn string) string {
	if strings.Contains(dsn, "://") {
		if u, err := url.Parse(dsn); err == nil && u.User != nil {
			return u.User.Username()
		}
		return ""
	}
	for _, f := range strings.Fields(dsn) {
		if k, v, ok := strings.Cut(f, "="); ok && strings.EqualFold(k, "user") {
			return strings.Trim(v, "'")
		}
	}
	return ""
}
