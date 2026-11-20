package secrets

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"
)

// PGSettings reads a libpq connection string's settings as written, both forms: the keyword form (key = value,
// spaces around '=' allowed, a value single-quoted with \' and \\ escapes or bare with \ escapes - libpq's own
// rules) and the URL form (the userinfo's user and password, then the query's parameters). Keys are lower case.
// Nothing is filled from the environment (pgx's parsed config would give PGUSER or the OS account).
func PGSettings(dsn string) (map[string]string, error) {
	s := strings.TrimSpace(dsn)
	if strings.HasPrefix(s, "postgres://") || strings.HasPrefix(s, "postgresql://") {
		u, err := url.Parse(s)
		if err != nil {
			return nil, errors.New("the connection string's URL does not parse")
		}
		m := map[string]string{}
		if u.User != nil {
			if n := u.User.Username(); n != "" {
				m["user"] = n
			}
			if p, ok := u.User.Password(); ok {
				m["password"] = p
			}
		}
		for k, v := range u.Query() {
			if len(v) > 0 {
				m[strings.ToLower(k)] = v[len(v)-1]
			}
		}
		return m, nil
	}
	m := map[string]string{}
	rs := []rune(s)
	i := 0
	skip := func() {
		for i < len(rs) && unicode.IsSpace(rs[i]) {
			i++
		}
	}
	for {
		skip()
		if i >= len(rs) {
			return m, nil
		}
		start := i
		for i < len(rs) && rs[i] != '=' && !unicode.IsSpace(rs[i]) {
			i++
		}
		key := strings.ToLower(string(rs[start:i]))
		skip()
		if i >= len(rs) || rs[i] != '=' || key == "" {
			return nil, fmt.Errorf("the connection string: %q is not followed by '='", key)
		}
		i++
		skip()
		var val strings.Builder
		if i < len(rs) && rs[i] == '\'' {
			i++
			closed := false
			for i < len(rs) {
				switch c := rs[i]; {
				case c == '\\' && i+1 < len(rs):
					val.WriteRune(rs[i+1])
					i += 2
				case c == '\'':
					closed = true
					i++
				default:
					val.WriteRune(c)
					i++
				}
				if closed {
					break
				}
			}
			if !closed {
				return nil, fmt.Errorf("the connection string: %q's quoted value is not closed", key)
			}
		} else {
			for i < len(rs) && !unicode.IsSpace(rs[i]) {
				if rs[i] == '\\' && i+1 < len(rs) {
					i++
				}
				val.WriteRune(rs[i])
				i++
			}
		}
		m[key] = val.String()
	}
}

// PGUser is the user a libpq string names as written ("" = none, or a string that does not parse).
func PGUser(dsn string) string {
	m, err := PGSettings(dsn)
	if err != nil {
		return ""
	}
	return m["user"]
}

// FillPG puts the instance's secret (sec nil = none: nothing done) on a parsed libpq config: the login by Login's
// rule from the string as written (dsn) and the password, read through the reader. The password never enters a
// string (task B24e: every PostgreSQL connect of a password_secret instance - the collector's, the actions doors',
// EXPLAIN's, the index advisor's, the Connection Test's - fills its parsed config here).
func (r *Reader) FillPG(ctx context.Context, cfg *pgx.ConnConfig, dsn string, sec *Ref) error {
	if sec == nil {
		return nil
	}
	v, err := r.Get(ctx, *sec)
	if err != nil {
		return err
	}
	return SetPG(cfg, dsn, *sec, v)
}

// FillPG is the process reader's FillPG.
func FillPG(ctx context.Context, cfg *pgx.ConnConfig, dsn string, sec *Ref) error {
	return Default.FillPG(ctx, cfg, dsn, sec)
}

// SetPG puts a value already read on the config (the collector's retry after a refused sign-in)
func SetPG(cfg *pgx.ConnConfig, dsn string, ref Ref, v Value) error {
	user, err := Login(PGUser(dsn), v, false)
	if err != nil {
		return Named(err, ref)
	}
	cfg.User, cfg.Password = user, v.Password
	return nil
}

// Named puts the secret's name on a *ReadError that has none (Login's refusals)
func Named(err error, ref Ref) error {
	var re *ReadError
	if errors.As(err, &re) && re.Secret == "" {
		re.Secret = ref.ID
	}
	return err
}
