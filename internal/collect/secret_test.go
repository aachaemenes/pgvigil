package collect

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/secrets"
)

// a stand-in reader: Get hands out cur, Refresh answers next (retry when its version differs), Accepted is counted
type fakeSecrets struct {
	cur, next secrets.Value
	accepted  []string
}

func (f *fakeSecrets) Get(context.Context, secrets.Ref) (secrets.Value, error) { return f.cur, nil }
func (f *fakeSecrets) Refresh(_ context.Context, _ secrets.Ref, failed string) (secrets.Value, bool, error) {
	return f.next, f.next.Version != failed, nil
}
func (f *fakeSecrets) Accepted(_ context.Context, _ secrets.Ref, v string) {
	f.accepted = append(f.accepted, v)
}

// Review 18 and 2: after a 28P01 the retry's dial records its target and starts its clock again (target called before
// each dial), carries the new version's password, and a sign-in that works is told to the reader (Accepted); review
// 7: the dsn's user is kept and must be the secret's username.
func TestDialWithSecretRetry(t *testing.T) {
	f := &fakeSecrets{cur: secrets.Value{User: "pgv", Password: "old", Version: "v1"}, next: secrets.Value{User: "pgv", Password: "new", Version: "v2"}}
	secretReader = f
	defer func() { secretReader = secrets.Default }()
	in := config.Instance{Name: "s1", DSNRaw: "host=h dbname=d", PasswordSecret: &config.PasswordSecret{Ref: "aws-secretsmanager:s", Region: "us-east-2"}}
	cfg, err := pgx.ParseConfig(in.DSN())
	if err != nil {
		t.Fatal(err)
	}
	targets, dials := 0, []string{}
	conn, err := dialWithSecret(context.Background(), in, cfg, func() { targets++ }, func(c *pgx.ConnConfig) (*pgx.Conn, error) {
		dials = append(dials, c.User+":"+c.Password)
		if c.Password == "old" {
			return nil, &pgconn.PgError{Code: "28P01"}
		}
		return nil, nil // a stand-in for a connection: nil conn, nil error
	})
	if err != nil || conn != nil {
		t.Fatalf("the retry: %v", err)
	}
	if targets != 2 || fmt.Sprint(dials) != "[pgv:old pgv:new]" || fmt.Sprint(f.accepted) != "[v2]" {
		t.Errorf("targets %d (want 2: one a dial), dials %v (want old then new as pgv), accepted %v (want [v2])", targets, dials, f.accepted)
	}
	in.DSNRaw = "host=h user=other dbname=d"
	cfg, _ = pgx.ParseConfig(in.DSN())
	_, err = dialWithSecret(context.Background(), in, cfg, func() {}, func(*pgx.ConnConfig) (*pgx.Conn, error) {
		t.Error("dialled with a dsn user other than the secret's username")
		return nil, nil
	})
	var re *secrets.ReadError
	if !errors.As(err, &re) || re.Code != "LoginMismatch" {
		t.Errorf("a dsn user other than the secret's: %v, want a *secrets.ReadError LoginMismatch (not the server's failure)", err)
	}
}

// Review 4: a run that could not read its password builds no 'collection failing' streak per collection (0192's one
// finding speaks for the instance), as the instance's own connect failure builds none.
func TestSecretFailureNoStreak(t *testing.T) {
	h := &Heartbeat{runs: map[[2]string]*runAgg{}, load: map[string]*loadAgg{}, streaks: map[[2]string]*streak{}}
	now := time.Now()
	se := fmt.Errorf("connect s1: %w", &secrets.ReadError{Secret: "pgvigil/read", Code: "AccessDeniedException", Refused: true})
	for i := 0; i < 4; i++ {
		for _, c := range []string{"activity", "statements", "tables"} {
			h.record("s1", "postgres", c, Result{Err: se, Duration: time.Millisecond}, now, 0)
		}
	}
	for k, s := range h.streaks {
		if k[0] == "s1" && s.fails > 0 {
			t.Errorf("%s: a streak of %d failures from the secret's refusal", k[1], s.fails)
		}
	}
}
