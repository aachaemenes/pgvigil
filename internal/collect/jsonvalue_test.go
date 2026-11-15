package collect

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// fakeRows is one row of fixed values, given as pgx's rows.Values() returns them.
type fakeRows struct {
	names []string
	vals  []any
	done  bool
}

func (f *fakeRows) Close()                        {}
func (f *fakeRows) Err() error                    { return nil }
func (f *fakeRows) CommandTag() pgconn.CommandTag { return pgconn.CommandTag{} }
func (f *fakeRows) FieldDescriptions() []pgconn.FieldDescription {
	out := make([]pgconn.FieldDescription, len(f.names))
	for i, n := range f.names {
		out[i] = pgconn.FieldDescription{Name: n}
	}
	return out
}
func (f *fakeRows) Next() bool {
	if f.done {
		return false
	}
	f.done = true
	return true
}
func (f *fakeRows) Scan(...any) error {
	return errors.New("fakeRows: rowsToMaps reads Values, never Scan")
}
func (f *fakeRows) Values() ([]any, error) { return f.vals, nil }
func (f *fakeRows) RawValues() [][]byte    { return nil }
func (f *fakeRows) Conn() *pgx.Conn        { return nil }
func (f *fakeRows) TypeMap() *pgtype.Map   { return nil }

// TestRowsToMapsJSONValues: pgx v5 decodes a timestamptz, timestamp or date of +/-infinity to a pgtype.InfinityModifier
// (an int8: 1 / -1), which JSON writes as a number - the repository's (r->>'x')::timestamptz then fails on '1' and the
// whole collection with it (the roles collection on RDS, 2026-11-15: rdsadmin's VALID UNTIL 'infinity'); a float NaN
// or +/-Inf has no JSON form at all (json.Marshal refuses the whole payload). rowsToMaps must hand the import
// PostgreSQL's own text for each, inside arrays too, and leave every other value as it was.
func TestRowsToMapsJSONValues(t *testing.T) {
	at := time.Date(2026, 11, 15, 23, 0, 0, 0, time.UTC)
	rows := &fakeRows{
		names: []string{"pinf", "ninf", "arr", "nan", "fpinf", "fninf", "f32nan", "fin", "n", "s", "tm", "nested"},
		vals: []any{pgtype.Infinity, pgtype.NegativeInfinity, []any{pgtype.Infinity, at, nil}, math.NaN(), math.Inf(1), math.Inf(-1),
			float32(math.NaN()), 1.5, int64(7), "x", at, map[string]any{"a": []any{pgtype.NegativeInfinity}}},
	}
	got, err := rowsToMaps(rows)
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("the rows do not marshal (the whole payload would be lost): %v", err)
	}
	want := `[{"arr":["infinity","2026-11-15T23:00:00Z",null],"f32nan":"NaN","fin":1.5,"fninf":"-Infinity","fpinf":"Infinity",` +
		`"n":7,"nan":"NaN","nested":{"a":["-infinity"]},"ninf":"-infinity","pinf":"infinity","s":"x","tm":"2026-11-15T23:00:00Z"}]`
	if string(b) != want {
		t.Errorf("rowsToMaps JSON\n got %s\nwant %s", b, want)
	}
}

// TestRowsToMapsInfinityLive: the same through a real server - each type's +/-infinity and the float specials read by
// pgx, through rowsToMaps and JSON, and back through the casts the imports use, equal to what was read.
// PGVIGIL_REPO_DSN names any PostgreSQL 14+ (numeric infinity); skipped without it.
func TestRowsToMapsInfinityLive(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	rs, err := conn.Query(ctx, `SELECT 'infinity'::timestamptz AS tz_p, '-infinity'::timestamptz AS tz_n,
	       'infinity'::timestamp AS ts_p, '-infinity'::timestamp AS ts_n, 'infinity'::date AS d_p, '-infinity'::date AS d_n,
	       ARRAY['infinity'::timestamptz, '2026-11-15 23:00+00'] AS tz_arr,
	       'NaN'::float8 AS f_nan, 'Infinity'::float8 AS f_p, '-Infinity'::float4 AS f_n, 'NaN'::numeric AS n_nan, 'Infinity'::numeric AS n_p`)
	if err != nil {
		t.Fatal(err)
	}
	got, err := rowsToMaps(rs)
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("the rows do not marshal (the whole payload would be lost): %v", err)
	}
	var back string
	err = conn.QueryRow(ctx, `SELECT concat_ws(' ',
	         (r->>'tz_p')::timestamptz = 'infinity', (r->>'tz_n')::timestamptz = '-infinity',
	         (r->>'ts_p')::timestamp = 'infinity', (r->>'ts_n')::timestamp = '-infinity',
	         (r->>'d_p')::date = 'infinity', (r->>'d_n')::date = '-infinity',
	         (r->'tz_arr'->>0)::timestamptz = 'infinity', (r->'tz_arr'->>1)::timestamptz = '2026-11-15 23:00+00',
	         (r->>'f_nan')::float8 = 'NaN', (r->>'f_p')::float8 = 'Infinity', (r->>'f_n')::float4 = '-Infinity',
	         (r->>'n_nan')::numeric = 'NaN', (r->>'n_p')::numeric = 'Infinity')
	    FROM jsonb_array_elements($1::jsonb) r`, string(b)).Scan(&back)
	if err != nil {
		t.Fatalf("the casts the imports use do not read the JSON back: %v (JSON %s)", err, b)
	}
	if want := "t t t t t t t t t t t t t"; back != want { // concat_ws writes a boolean through its output function (t)
		t.Errorf("read back %q, want %q (JSON %s)", back, want, b)
	}
}

// TestRolesValidUntilInfinityImport: a role VALID UNTIL 'infinity' (rdsadmin on RDS; any role so set on-prem) through
// the roles collection into the repository: the import succeeds (before the fix the whole collection failed with 22007
// 'invalid input syntax for type timestamp with time zone: "1"') and role_attributes keeps 'infinity'.
// PGVIGIL_REPO_DSN names a throwaway repository on a server where the test may create a role; skipped without it.
func TestRolesValidUntilInfinityImport(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	sfx := strconv.FormatInt(time.Now().UnixNano()%1_000_000_000_000, 10)
	role, roleNeg := "pginf_inf_"+sfx, "pginf_ninf_"+sfx
	// the drop is deferred before the first CREATE (and after the connection's close: it runs first), so a CREATE that
	// fails part way leaves no role behind
	defer func() {
		for _, n := range []string{role, roleNeg} {
			if _, err := conn.Exec(context.Background(), `DROP ROLE IF EXISTS `+n); err != nil {
				t.Error(err)
			}
		}
	}()
	for _, q := range []string{
		`CREATE ROLE ` + role + ` NOLOGIN VALID UNTIL 'infinity'`,
		`CREATE ROLE ` + roleNeg + ` NOLOGIN VALID UNTIL '-infinity'`,
	} {
		if _, err := conn.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	name := "pginf-roles-" + sfx
	id, err := r.EnsureInstance(ctx, name, "onprem", "fixture", 180000, false, []string{"fixture"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := conn.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	rows, err := rolesCollector{}.RunInstance(ctx, conn, platformInfoNone, config.Instance{Name: name, DSNRaw: dsn}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Import(ctx, id, "roles", time.Now().UTC(), rows); err != nil {
		t.Fatalf("the roles collection with a role VALID UNTIL 'infinity' did not import: %v", err)
	}
	var got string
	if err := conn.QueryRow(ctx, `SELECT string_agg(rolname || '=' || coalesce(valid_until::text, 'NULL'), ' ' ORDER BY rolname)
	                                FROM pgvigil.role_attributes WHERE instance_id = $1 AND rolname IN ($2, $3)`, id, role, roleNeg).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if want := role + "=infinity " + roleNeg + "=-infinity"; got != want { // by name: pginf_inf_ sorts before pginf_ninf_
		t.Errorf("role_attributes %q, want %q", got, want)
	}
}

// TestRolesMinusInfinityText: since PGINF a role VALID UNTIL '-infinity' (or 'infinity') reaches the repository, and
// the two texts built from it took to_char of a non-finite timestamp, which is NULL: role_flags dropped 'valid until'
// (an always-expired password read like none) and the 'login without a way in' finding's detail was NULL. Migration
// 0270 writes the value itself for a non-finite one. The flags read directly; the finding through the live roles
// collection with every hba rule it read made password-only (scram-sha-256), so the '-infinity' login role has no
// other way in. PGVIGIL_REPO_DSN as TestRolesValidUntilInfinityImport; skipped without it.
func TestRolesMinusInfinityText(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	var flags string
	if err := conn.QueryRow(ctx, `SELECT concat_ws(' | ',
	         pgvigil.role_flags(false, true, false, false, true, false, false, -1, '-infinity'),
	         pgvigil.role_flags(false, true, false, false, true, false, false, -1, 'infinity'),
	         pgvigil.role_flags(false, true, false, false, true, false, false, -1, '2026-01-02 03:04+00'),
	         pgvigil.role_flags(false, true, false, false, true, false, false, -1, NULL))`).Scan(&flags); err != nil {
		t.Fatal(err)
	}
	if want := "login,valid until -infinity | login,valid until infinity | login,valid until 2026-01-02 03:04 UTC | login"; flags != want {
		t.Errorf("role_flags\n got %q\nwant %q", flags, want)
	}
	sfx := strconv.FormatInt(time.Now().UnixNano()%1_000_000_000_000, 10)
	role := "pginf_exp_" + sfx
	defer func() {
		if _, err := conn.Exec(context.Background(), `DROP ROLE IF EXISTS `+role); err != nil {
			t.Error(err)
		}
	}()
	if _, err := conn.Exec(ctx, `CREATE ROLE `+role+` LOGIN VALID UNTIL '-infinity'`); err != nil {
		t.Fatal(err)
	}
	name := "pginf-exp-" + sfx
	id, err := r.EnsureInstance(ctx, name, "onprem", "fixture", 180000, false, []string{"fixture"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := conn.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	rows, err := rolesCollector{}.RunInstance(ctx, conn, platformInfoNone, config.Instance{Name: name, DSNRaw: dsn}, nil)
	if err != nil {
		t.Fatal(err)
	}
	nh := 0
	for _, row := range rows {
		if row["kind"] == "hba" {
			row["auth_method"] = "scram-sha-256" // every rule password-only: the role's one way in has expired
			nh++
		}
	}
	if nh == 0 {
		t.Fatal("the roles collection read no hba rule (the finding needs them: a superuser login reads pg_hba_file_rules)")
	}
	if err := r.Import(ctx, id, "roles", time.Now().UTC(), rows); err != nil {
		t.Fatal(err)
	}
	var detail *string
	if err := conn.QueryRow(ctx, `SELECT detail FROM pgvigil.role_findings WHERE instance_id = $1 AND setting = 'login without a way in' AND value = $2`,
		id, role).Scan(&detail); err != nil {
		t.Fatalf("no 'login without a way in' finding for %s: %v", role, err)
	}
	want := role + " is admitted only by password (scram-sha-256) and its password expired -infinity: no other method lets it in"
	if detail == nil || *detail != want {
		got := "NULL"
		if detail != nil {
			got = *detail
		}
		t.Errorf("the finding's detail\n got %q\nwant %q", got, want)
	}
}
