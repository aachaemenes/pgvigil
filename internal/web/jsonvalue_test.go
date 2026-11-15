package web

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestPgCellJSONValues: a custom report's cell (pgCell, q_customreports.go) has a JSON form for a float4 NaN or
// +/-Infinity (returned as it came, json.Marshal refused the whole reply) and inside an array or a composite (not
// walked: an infinity went out as 1, a NaN refused the reply); a finite float4 stays a number.
func TestPgCellJSONValues(t *testing.T) {
	cells := []any{
		pgCell(float32(math.NaN()), pgtype.Float4OID), pgCell(float32(math.Inf(-1)), pgtype.Float4OID), pgCell(float32(1.5), pgtype.Float4OID),
		pgCell([]any{pgtype.Infinity, math.NaN(), int64(3)}, 0), pgCell(map[string]any{"a": pgtype.NegativeInfinity}, 0),
	}
	b, err := json.Marshal(cells)
	if err != nil {
		t.Fatalf("the cells do not marshal (the whole reply would fail): %v", err)
	}
	if want := `["NaN","-Inf",1.5,["infinity","NaN",3],{"a":"-infinity"}]`; string(b) != want {
		t.Errorf("pgCell JSON\n got %s\nwant %s", b, want)
	}
}

// TestQueryJSONValues: a page's table read through Server.query hands the browser PostgreSQL's own text for a
// timestamptz, timestamp or date of +/-infinity (pgx v5 decodes it to a pgtype.InfinityModifier, JSON 1 / -1: the
// Roles page then read rdsadmin's 'password valid until' as 2001-01-01, expired) and for a float NaN or +/-Infinity
// (no JSON form: json.Marshal refused the whole reply), inside arrays too; queryTx (the perf summary's parts) the same.
// PGVIGIL_REPO_TEST_DSN names any PostgreSQL; skipped without it.
func TestQueryJSONValues(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	const q = `SELECT 'infinity'::timestamptz AS a, '-infinity'::timestamp AS b, 'infinity'::date AS c,
	                  ARRAY['-infinity'::timestamptz] AS d, 'NaN'::float8 AS e, '-Infinity'::float4 AS f, 2::int AS g`
	const want = `{"columns":["a","b","c","d","e","f","g"],"rows":[["infinity","-infinity","infinity",["-infinity"],"NaN","-Infinity",2]]}`
	s := &Server{pool: pool, log: discardLog()}
	tb, err := s.query(ctx, q)
	if err != nil {
		t.Fatal(err)
	}
	if b, err := json.Marshal(tb); err != nil {
		t.Errorf("query: the table does not marshal (the whole reply would fail): %v", err)
	} else if string(b) != want {
		t.Errorf("query JSON\n got %s\nwant %s", b, want)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	tb, err = queryTx(ctx, tx, q)
	if err != nil {
		t.Fatal(err)
	}
	if b, err := json.Marshal(tb); err != nil {
		t.Errorf("queryTx: the table does not marshal (the whole reply would fail): %v", err)
	} else if string(b) != want {
		t.Errorf("queryTx JSON\n got %s\nwant %s", b, want)
	}
}

// TestReportPwageNonFinite: the Password age report's PostgreSQL part (sqlRepPgLogins) on login roles VALID UNTIL
// '-infinity', 'infinity', a past and a future time. Since PGINF a non-finite value is stored; the part computed days
// for everything but NULL and 'infinity', and '-infinity' - now() raised (PostgreSQL 17+: 'cannot convert infinity to
// integer'; 16: 'cannot subtract infinite timestamps'), which failed the whole report. Now: no days for a non-finite
// value and is_expired said (true for '-infinity' and the past time, false for 'infinity' and the future one).
// PGVIGIL_REPO_TEST_DSN names a migrated repository; skipped without it.
func TestReportPwageNonFinite(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'onprem', '18.0', 180000, false, ARRAY['fixture']::text[], 'postgres')`,
		"pginf-pwage-"+time.Now().UTC().Format("150405.000000")).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.role_attributes (instance_id, rolname, snapshot_at, super, inherit, createrole, createdb,
	                                                                 canlogin, replication, bypassrls, connlimit, valid_until)
	    SELECT $1, v.n, now(), false, true, false, false, true, false, false, -1, v.u
	      FROM (VALUES ('a_minus', '-infinity'::timestamptz), ('b_plus', 'infinity'), ('c_past', now() - interval '3 days' + interval '1 hour'),
	                   ('d_future', now() + interval '10 days 1 hour')) v(n, u)`, id); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: discardLog()}
	tb, err := s.query(ctx, sqlRepPgLogins, []int{id})
	if err != nil {
		t.Fatalf("the Password age report's PostgreSQL part failed (the whole report with it): %v", err)
	}
	ci := map[string]int{}
	for i, c := range tb.Columns {
		ci[c] = i
	}
	if _, ok := ci["is_expired"]; !ok {
		t.Fatalf("no is_expired column (columns %v)", tb.Columns)
	}
	var got []string
	for _, row := range tb.Rows {
		got = append(got, fmt.Sprintf("%v days=%v expired=%v", row[ci["role_name"]], row[ci["days_until_expiration"]], row[ci["is_expired"]]))
	}
	want := []string{"a_minus days=<nil> expired=true", "b_plus days=<nil> expired=false", "c_past days=-3 expired=true", "d_future days=10 expired=false"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("the PostgreSQL logins part\n got %v\nwant %v", got, want)
	}
}
