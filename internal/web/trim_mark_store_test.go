package web

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// TRIMMARK (decision (a); BJf8L): the beats' trims of the minute-led tables - collector_load and
// collector_runs in 0121's import_collector_beat, collector_probe in 0254's import_collector_probe - go by a mark
// (pgvigil.collector_trim_mark): from the mark to 10 minutes past the first row at or after it, never past 8 days
// back, the mark moved in the trim's own transaction. BJf8L D measured the old 'minute < now() - 8 days' on statistics 10
// hours old: a Seq Scan of collector_load's 6.2 GB, 3.2 s a beat at 2,124 instances. Store rows (box rows:
// PGVIGIL_REPO_TEST_DSN), each in one transaction rolled back; now() is the transaction's, so every beat of a row sees
// one clock.

var tmTables = []string{"collector_load", "collector_runs", "collector_probe"}

// tmStore: f9Store's transaction and collector, the three tables' rows older than 7 days deleted (in the transaction),
// so the trims start at this row's own rows, and an instance; it reports whether the store has the mark table.
func tmStore(t *testing.T) (context.Context, pgx.Tx, string, int64, int, bool) {
	t.Helper()
	ctx, tx, col, sfx := f9Store(t)
	for _, tbl := range tmTables {
		if _, err := tx.Exec(ctx, `DELETE FROM pgvigil.`+tbl+` WHERE minute < now() - interval '7 days'`); err != nil {
			t.Fatal(err)
		}
	}
	var marked bool
	if err := tx.QueryRow(ctx, `SELECT to_regclass('pgvigil.collector_trim_mark') IS NOT NULL`).Scan(&marked); err != nil {
		t.Fatal(err)
	}
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
		fmt.Sprintf("tm-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return ctx, tx, col, sfx, id, marked
}

// tmSetMarks sets the three tables' marks to at (an SQL expression of now(), or '-infinity'), or with at "" removes
// their rows (the first trim of a table: no row yet); nothing on a store without the mark table.
func tmSetMarks(ctx context.Context, t *testing.T, tx pgx.Tx, marked bool, at string) {
	t.Helper()
	if !marked {
		return
	}
	q := `DELETE FROM pgvigil.collector_trim_mark WHERE tbl = ANY ($1::text[])`
	if at != "" {
		q = `INSERT INTO pgvigil.collector_trim_mark (tbl, trimmed_to) SELECT tbl, ` + at + ` FROM unnest($1::text[]) tbl
		     ON CONFLICT (tbl) DO UPDATE SET trimmed_to = EXCLUDED.trimmed_to`
	}
	if _, err := tx.Exec(ctx, q, tmTables); err != nil {
		t.Fatal(err)
	}
}

// tmPlant writes one row in each of the three tables at the minute 'at' (an SQL expression of now()).
func tmPlant(ctx context.Context, t *testing.T, tx pgx.Tx, col string, id int, at string) {
	t.Helper()
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures)
		  VALUES (` + at + `, $2, $1, 1, 1, 1, 0, 0)`, []any{col, id}},
		{`INSERT INTO pgvigil.collector_runs (minute, collector_id, engine, collection, runs, failures, rows_written, dur_ms_sum, dur_ms_max, dur_hist)
		  VALUES (` + at + `, $1, 'postgres', 'tm', 1, 0, 0, 0, 0, '{}')`, []any{col}},
		{`INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max)
		  VALUES (` + at + `, $1, 'tm-host', '10.9.8.1:5432', 'tcp', 1, 1, 5, 5)`, []any{col}},
	} {
		if _, err := tx.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatalf("plant at %s: %v", at, err)
		}
	}
}

// tmBeat: one beat of the collector at the transaction's minute - import_collector_beat, then import_collector_probe
// (heartbeat.go's order), each with an empty body.
func tmBeat(ctx context.Context, t *testing.T, tx pgx.Tx, col string) {
	t.Helper()
	var known bool
	if err := tx.QueryRow(ctx, `SELECT pgvigil.import_collector_beat($1, date_trunc('minute', now()), '{}'::jsonb)`, col).Scan(&known); err != nil || !known {
		t.Fatalf("import_collector_beat: %v (known %v)", err, known)
	}
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_probe($1, date_trunc('minute', now()), '{}'::jsonb)`, col); err != nil {
		t.Fatalf("import_collector_probe: %v", err)
	}
}

// tmCounts: per table, the collector's rows past 8 days and its rows inside them ('<old>/<recent>').
func tmCounts(ctx context.Context, t *testing.T, tx pgx.Tx, col string) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, tbl := range tmTables {
		var old, recent int
		if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE minute < now() - interval '8 days'), count(*) FILTER (WHERE minute >= now() - interval '8 days')
		                              FROM pgvigil.`+tbl+` WHERE collector_id = $1`, col).Scan(&old, &recent); err != nil {
			t.Fatal(err)
		}
		out[tbl] = fmt.Sprintf("%d/%d", old, recent)
	}
	return out
}

// tmMarks: per table, its mark as whole minutes before date_trunc('minute', now()) - 8 days, rounded up - a mark at
// now() - 8 days itself (a trim that reached the cut) reads 0 - ('none': no row, 'no mark table').
func tmMarks(ctx context.Context, t *testing.T, tx pgx.Tx, marked bool) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, tbl := range tmTables {
		if !marked {
			out[tbl] = "no mark table"
			continue
		}
		var m string
		if err := tx.QueryRow(ctx, `SELECT coalesce((SELECT CASE WHEN trimmed_to = '-infinity' THEN '-infinity'
		                                  ELSE ceil(extract(epoch FROM (date_trunc('minute', now()) - interval '8 days') - trimmed_to) / 60)::int::text END
		                                  FROM pgvigil.collector_trim_mark WHERE tbl = $1), 'none')`, tbl).Scan(&m); err != nil {
			t.Fatal(err)
		}
		out[tbl] = m
	}
	return out
}

// TestTrimMarkBacklogOnAStore (TRIMMARK row 1, case (1): the first beats with no mark yet - a store
// upgraded, or one whose collectors stopped - with the mark at '-infinity' and with no mark row at all): 7 rows a table
// past 8 days, every 5 minutes from 35 to 5 minutes before date_trunc('minute', now()) - 8 days, and 2 recent rows.
// Each beat trims 10 minutes from the oldest row only - 2 rows, 2, 2, then the last 1 (the fourth step ends at now() -
// 8 days) - the fifth trims nothing, the recent rows kept; the mark after each beat 25, 15, 5, 0, 0 minutes before
// date_trunc('minute', now()) - 8 days. RED on 0121 / 0254 as they were: the first beat trims all 7.
func TestTrimMarkBacklogOnAStore(t *testing.T) {
	for _, start := range []string{"'-infinity'", ""} {
		name := "a mark at -infinity"
		if start == "" {
			name = "no mark row"
		}
		t.Run(name, func(t *testing.T) {
			ctx, tx, col, _, id, marked := tmStore(t)
			tmSetMarks(ctx, t, tx, marked, start)
			for m := 5; m <= 35; m += 5 {
				tmPlant(ctx, t, tx, col, id, fmt.Sprintf("date_trunc('minute', now()) - interval '8 days' - interval '%d minutes'", m))
			}
			tmPlant(ctx, t, tx, col, id, "date_trunc('minute', now()) - interval '1 minute'")
			tmPlant(ctx, t, tx, col, id, "date_trunc('minute', now()) - interval '1 hour'")
			for beat, want := range []struct{ rows, mark string }{{"5/2", "25"}, {"3/2", "15"}, {"1/2", "5"}, {"0/2", "0"}, {"0/2", "0"}} {
				tmBeat(ctx, t, tx, col)
				counts, marks := tmCounts(ctx, t, tx, col), tmMarks(ctx, t, tx, marked)
				for _, tbl := range tmTables {
					if counts[tbl] != want.rows {
						t.Errorf("beat %d, %s: rows past 8 days / recent = %s, want %s (10 minutes a beat from the oldest row)", beat+1, tbl, counts[tbl], want.rows)
					}
					if marks[tbl] != want.mark {
						t.Errorf("beat %d, %s: the mark = %s, want %s minutes before 8 days back", beat+1, tbl, marks[tbl], want.mark)
					}
				}
			}
		})
	}
}

// TestTrimMarkReadsFromTheMarkOnAStore (TRIMMARK row 4): the trim reads from the mark, never
// below it - with the marks 45 minutes before date_trunc('minute', now()) - 8 days, a row 90 minutes before (below the
// mark: no import writes one there, the beats' parity lines see to it) stays and the row 30 minutes before goes; the
// mark then 20 (the step's end). A trim that read the whole key would take the row at 90 and leave the one at 30.
// RED on the old trims (no mark: both go).
func TestTrimMarkReadsFromTheMarkOnAStore(t *testing.T) {
	ctx, tx, col, _, id, marked := tmStore(t)
	tmSetMarks(ctx, t, tx, marked, "date_trunc('minute', now()) - interval '8 days' - interval '45 minutes'")
	tmPlant(ctx, t, tx, col, id, "date_trunc('minute', now()) - interval '8 days' - interval '90 minutes'")
	tmPlant(ctx, t, tx, col, id, "date_trunc('minute', now()) - interval '8 days' - interval '30 minutes'")
	tmBeat(ctx, t, tx, col)
	marks := tmMarks(ctx, t, tx, marked)
	for _, tbl := range tmTables {
		var at90, at30 int
		if err := tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE minute = date_trunc('minute', now()) - interval '8 days' - interval '90 minutes'),
		                                   count(*) FILTER (WHERE minute = date_trunc('minute', now()) - interval '8 days' - interval '30 minutes')
		                              FROM pgvigil.`+tbl+` WHERE collector_id = $1`, col).Scan(&at90, &at30); err != nil {
			t.Fatal(err)
		}
		if at90 != 1 || at30 != 0 || marks[tbl] != "20" {
			t.Errorf("%s: the row below the mark %d (want 1, not read), the row above it %d (want 0, trimmed), the mark %s (want 20)", tbl, at90, at30, marks[tbl])
		}
	}
}

// TestTrimMarkFailedBeatOnAStore (TRIMMARK row 2, case (2)): a beat that fails AFTER its trims - a stale
// heartbeat row (beat_at 9 days back) whose delete, the beat's last statement, raises - leaves the rows and the mark
// where they were: the mark and the DELETE are in the beat's one transaction (any order of the two inside the function
// passes; the row proves the transaction, not the order). The control: the same beat without the failure trims the
// old row and moves the mark to the step's end. RED on 0121 as it was: no mark table.
func TestTrimMarkFailedBeatOnAStore(t *testing.T) {
	ctx, tx, col, sfx, id, marked := tmStore(t)
	tmPlant(ctx, t, tx, col, id, "date_trunc('minute', now()) - interval '8 days' - interval '30 minutes'")
	tmSetMarks(ctx, t, tx, marked, "date_trunc('minute', now()) - interval '8 days' - interval '45 minutes'")
	if _, err := tx.Exec(ctx, `SAVEPOINT tm_fail`); err != nil {
		t.Fatal(err)
	}
	fn := fmt.Sprintf("pgvigil.tm_fail_%d", sfx)
	for _, q := range []string{
		`INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		 VALUES ('tm-stale-` + fmt.Sprint(sfx) + `', 'tm-stale', 'linux', 'console', 'x', 1, now() - interval '10 days', now() - interval '9 days')`,
		`CREATE FUNCTION ` + fn + `() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RAISE EXCEPTION 'tm: the failure planted after the trims'; END $f$`,
		`CREATE TRIGGER tm_fail BEFORE DELETE ON pgvigil.collector_heartbeat FOR EACH ROW EXECUTE FUNCTION ` + fn + `()`,
	} {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	_, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_beat($1, date_trunc('minute', now()), '{}'::jsonb)`, col)
	if err == nil || !strings.Contains(err.Error(), "the failure planted after the trims") {
		t.Fatalf("the beat with the planted failure: err %v, want the planted failure", err)
	}
	if _, err := tx.Exec(ctx, `ROLLBACK TO SAVEPOINT tm_fail`); err != nil {
		t.Fatal(err)
	}
	counts, marks := tmCounts(ctx, t, tx, col), tmMarks(ctx, t, tx, marked)
	for _, tbl := range []string{"collector_load", "collector_runs"} {
		if counts[tbl] != "1/0" {
			t.Errorf("after the failed beat, %s: rows past 8 days / recent = %s, want 1/0 (the trim rolled back)", tbl, counts[tbl])
		}
		if marks[tbl] != "45" {
			t.Errorf("after the failed beat, %s: the mark = %s, want 45 (where it was)", tbl, marks[tbl])
		}
	}
	tmBeat(ctx, t, tx, col)
	counts, marks = tmCounts(ctx, t, tx, col), tmMarks(ctx, t, tx, marked)
	for _, tbl := range tmTables {
		if counts[tbl] != "0/0" || marks[tbl] != "20" {
			t.Errorf("the control beat, %s: rows %s, the mark %s; want 0/0 and 20 (10 minutes past the row at 30)", tbl, counts[tbl], marks[tbl])
		}
	}
}

// TestTrimMarkLateBeatOnAStore (TRIMMARK row 3, parity - PASS on the old trims as well): a store whose marks stand at 8
// days back (as beats leave them) takes a beat written 9 days back (a collector whose clock is 9 days behind): its
// load and runs rows, and a probe row it carries from 9 days back, are not kept past the beat - the old trim removed
// them in the same beat; rows below the mark are never reached by the trim again.
func TestTrimMarkLateBeatOnAStore(t *testing.T) {
	ctx, tx, col, sfx, _, marked := tmStore(t)
	name := fmt.Sprintf("tm-%d", sfx)
	tmSetMarks(ctx, t, tx, marked, "date_trunc('minute', now()) - interval '8 days'")
	var known bool
	if err := tx.QueryRow(ctx, `SELECT pgvigil.import_collector_beat($1, date_trunc('minute', now()) - interval '9 days', jsonb_build_object(
	    'load', jsonb_build_array(jsonb_build_object('instance', $2::text, 'attempts', 1, 'opened', 1, 'runs', 1, 'failures', 0, 'auth', 0)),
	    'runs', jsonb_build_array(jsonb_build_object('engine', 'postgres', 'collection', 'tm', 'runs', 1, 'failures', 0, 'rows', 0, 'dur_sum', 0, 'dur_max', 0, 'hist', '[]'::jsonb))))`,
		col, name).Scan(&known); err != nil || !known {
		t.Fatalf("the late beat: %v (known %v)", err, known)
	}
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_probe($1, date_trunc('minute', now()), jsonb_build_object('probes', jsonb_build_array(
	    jsonb_build_object('host', 'tm-host', 'address', '10.9.7.1:5432', 'method', 'tcp', 'at', now() - interval '9 days', 'sent', 1, 'answered', 1, 'ms_sum', 5, 'ms_max', 5))))`, col); err != nil {
		t.Fatalf("the late probe: %v", err)
	}
	counts := tmCounts(ctx, t, tx, col)
	for _, tbl := range tmTables {
		if counts[tbl] != "0/0" {
			t.Errorf("a late beat, %s: rows past 8 days / recent = %s, want 0/0 (none kept past 8 days)", tbl, counts[tbl])
		}
	}
}
