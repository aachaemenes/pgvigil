package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/jobmask"
)

// goSteps are the migrations' Go steps: each runs in its file's transaction, after the file's own statements and
// before the file is recorded, so a failed step rolls its file back with it and the next migrate runs both again.
var goSteps = map[string]func(context.Context, pgx.Tx) error{
	"0272_job_text_masked_again.sql": remaskJobText,
}

// remaskTable is a table whose job texts remaskJobText masks again in place.
type remaskTable struct {
	table  string
	text   []string // text columns
	json   []string // jsonb columns: every string inside them
	hash   string   // the jsonb column whose md5 is the row's def_hash ("" = none)
	script string   // the text column holding a job's script (jobmask.StoredScript decodes its commands), "" = none
}

// in 0272's lock order: pg_cron's and pgAgent's jobs and runs (masked by the collector as a step's text is), SQL
// Server's runs and jobs (the description masked by the collector), then the versions of both
var remaskTables = []remaskTable{
	{table: "jobs", text: []string{"command"}},
	{table: "job_runs", text: []string{"command", "return_message"}},
	{table: "mssql_job_runs", text: []string{"message", "failed_message"}},
	{table: "mssql_jobs", text: []string{"description", "last_message"}, json: []string{"steps"}},
	{table: "job_versions", text: []string{"script"}, json: []string{"definition", "changes"}, hash: "definition", script: "script"},
}

// remaskBatch is how many rows one fetch of the cursor reads.
const remaskBatch = 500

// remaskJobText (migration 0272's step): every job text an older build stored, masked again by today's rules
// (jobmask.StoredValue: a text still holding a key after that is replaced whole; a job's script by
// jobmask.StoredScript, which decodes each command and description as agentScript encodes them): no key the older
// rules missed is left in the store. Only the rows matching jobmask.Prefilter are read. A version whose definition changes gets its
// def_hash again as 0094 makes it (md5 of the definition's text), so the step writes no version; a job's next read
// may write one where the older mark keeps another shape than today's (docs/jobs.md, Known limits).
func remaskJobText(ctx context.Context, tx pgx.Tx) error {
	for _, t := range remaskTables {
		if err := t.remask(ctx, tx); err != nil {
			return fmt.Errorf("remask %s: %w", t.table, err)
		}
	}
	return nil
}

// remaskRow is one row whose texts changed: where it is (its table's oid and ctid: mssql_job_runs is partitioned
// and has no key) and every column's value after the mask, in the table's column order.
type remaskRow struct {
	oid  uint32
	ctid string
	vals []*string
}

// remask reads the table through a cursor (in batches, the step's transaction holding its snapshot) and updates
// each row whose texts the mask changed.
func (t remaskTable) remask(ctx context.Context, tx pgx.Tx) error {
	cols := append(append([]string{}, t.text...), t.json...)
	sel := make([]string, len(cols))
	for i, c := range cols {
		sel[i] = c + "::text"
	}
	// a cursor of its own name per table: pgx keeps a statement's description by its text, so one FETCH text for
	// cursors of other shapes would bind the first table's columns to the next
	cursor := "pgvigil_remask_" + t.table
	// only the rows a rule could change (the pattern is a constant of jobmask's, a dollar-quoted literal here)
	where := make([]string, len(cols))
	for i := range cols {
		where[i] = sel[i] + " ~* $re$" + jobmask.Prefilter + "$re$"
	}
	if _, err := tx.Exec(ctx, "DECLARE "+cursor+" NO SCROLL CURSOR FOR SELECT tableoid::oid, ctid::text, "+
		strings.Join(sel, ", ")+" FROM pgvigil."+t.table+" WHERE "+strings.Join(where, " OR ")); err != nil {
		return err
	}
	set := make([]string, len(cols))
	for i, c := range cols {
		if i < len(t.text) {
			set[i] = fmt.Sprintf("%s = $%d", c, i+3)
		} else {
			set[i] = fmt.Sprintf("%s = $%d::jsonb", c, i+3)
		}
		if c == t.hash {
			set = append(set, fmt.Sprintf("def_hash = md5(($%d::jsonb)::text)", i+3))
		}
	}
	update := "UPDATE pgvigil." + t.table + " SET " + strings.Join(set, ", ") + " WHERE tableoid = $1 AND ctid = $2::tid"
	for {
		changed, n, err := t.fetch(ctx, tx, cursor, len(cols))
		if err != nil {
			return err
		}
		for _, r := range changed {
			args := []any{r.oid, r.ctid}
			for _, v := range r.vals {
				args = append(args, v)
			}
			if _, err := tx.Exec(ctx, update, args...); err != nil {
				return err
			}
		}
		if n < remaskBatch {
			break
		}
	}
	_, err := tx.Exec(ctx, "CLOSE "+cursor)
	return err
}

// fetch reads the cursor's next batch and returns the rows the mask changed and how many it read.
func (t remaskTable) fetch(ctx context.Context, tx pgx.Tx, cursor string, ncols int) ([]remaskRow, int, error) {
	rows, err := tx.Query(ctx, fmt.Sprintf("FETCH %d FROM %s", remaskBatch, cursor))
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	var changed []remaskRow
	n := 0
	for rows.Next() {
		n++
		r := remaskRow{vals: make([]*string, ncols)}
		dest := []any{&r.oid, &r.ctid}
		for i := range r.vals {
			dest = append(dest, &r.vals[i])
		}
		if err := rows.Scan(dest...); err != nil {
			return nil, 0, err
		}
		dirty := false
		for i, v := range r.vals {
			if v == nil {
				continue
			}
			m, ch, err := remaskValue(*v, i >= len(t.text), i < len(t.text) && t.text[i] == t.script)
			if err != nil {
				return nil, 0, fmt.Errorf("%s (row %s): %w", t.table, r.ctid, err)
			}
			if ch {
				r.vals[i], dirty = &m, true
			}
		}
		if dirty {
			changed = append(changed, r)
		}
	}
	return changed, n, rows.Err()
}

// remaskValue is a column's value masked again (jobmask.StoredValue), a jsonb value's every string, a job's script by
// jobmask.StoredScript (its commands and description decoded, masked, guarded); changed says whether anything
// changed (a jsonb value unchanged is returned as read).
func remaskValue(v string, isJSON, isScript bool) (string, bool, error) {
	if isScript {
		m := jobmask.StoredScript(v)
		return m, m != v, nil
	}
	if !isJSON {
		m := jobmask.StoredValue(v)
		return m, m != v, nil
	}
	d := json.NewDecoder(strings.NewReader(v))
	d.UseNumber() // a number goes back as it was written
	var doc any
	if err := d.Decode(&doc); err != nil {
		return "", false, err
	}
	changed := false
	doc = remaskStrings(doc, &changed)
	if !changed {
		return v, false, nil
	}
	b, err := json.Marshal(doc) // < and > written as < / >: jsonb reads them back as the characters
	if err != nil {
		return "", false, err
	}
	return string(b), true, nil
}

// remaskStrings masks every string of a decoded jsonb value in place (an object's keys are names, left as they are).
func remaskStrings(v any, changed *bool) any {
	switch x := v.(type) {
	case string:
		if m := jobmask.StoredValue(x); m != x {
			*changed = true
			return m
		}
	case map[string]any:
		for k, e := range x {
			x[k] = remaskStrings(e, changed)
		}
	case []any:
		for i, e := range x {
			x[i] = remaskStrings(e, changed)
		}
	}
	return v
}
