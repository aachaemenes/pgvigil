package collect

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// The read login's password from AWS Secrets Manager (task B24e): every PostgreSQL connect of an instance with a
// password_secret goes through dialWithSecret - collect.Connect and the per-database connects (connectCounted). The
// secret is read BEFORE the dial target is recorded, and its failure is a *secrets.ReadError, never counted as the
// server not answering or refusing the login (the server was not asked). A refused sign-in (28P01) asks the reader's
// Refresh once and retries only on another version of the secret; a sign-in that works tells the reader (Accepted),
// which ends the hold on a version a server refused.

// secretSource is the reader of the process (a test stands its own in)
type secretSource interface {
	Get(ctx context.Context, ref secrets.Ref) (secrets.Value, error)
	Refresh(ctx context.Context, ref secrets.Ref, failed string) (secrets.Value, bool, error)
	Accepted(ctx context.Context, ref secrets.Ref, version string)
}

var secretReader secretSource = secrets.Default

// dialWithSecret fills cfg's login and password from the instance's secret (secrets.Login's rule on the dsn as
// written), calls dial, and after a 28P01 retries once with a newer version; target is called right before each dial
// (it records the dial target and starts the connect's clock, so a retry's time is its own dial's).
func dialWithSecret(ctx context.Context, in config.Instance, cfg *pgx.ConnConfig, target func(), dial func(*pgx.ConnConfig) (*pgx.Conn, error)) (*pgx.Conn, error) {
	ref := in.SecretRef()
	if ref == nil {
		target()
		return dial(cfg)
	}
	dsn := in.DSN()
	v, err := secretReader.Get(ctx, *ref)
	if err != nil {
		return nil, err
	}
	if err := secrets.SetPG(cfg, dsn, *ref, v); err != nil {
		return nil, err
	}
	target()
	conn, err := dial(cfg)
	var pe *pgconn.PgError
	if err == nil {
		secretReader.Accepted(ctx, *ref, v.Version)
		return conn, nil
	}
	if !errors.As(err, &pe) || pe.Code != "28P01" {
		return conn, err
	}
	nv, retry, rerr := secretReader.Refresh(ctx, *ref, v.Version)
	if rerr != nil || !retry {
		return nil, err
	}
	if err := secrets.SetPG(cfg, dsn, *ref, nv); err != nil {
		return nil, err
	}
	target()
	conn, err = dial(cfg)
	if err == nil {
		secretReader.Accepted(ctx, *ref, nv.Version)
	}
	return conn, err
}
