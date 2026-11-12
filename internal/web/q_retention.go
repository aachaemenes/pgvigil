package web

// The Data Retention page and the tree's Instance Actions read (task 172; DBA Dash's Options > Data Retention and
// its instance menu's Pause/Resume Collections and Configure Schedule):
//
//   GET /api/retention[?days=N]               every table of the repository's schema: its size with its partitions,
//                                             what the retention does to it (read from pgvigil.purge()'s own text and
//                                             the text of the *_purge functions it calls, so the page follows the
//                                             functions as installed), its oldest partition or oldest row, the days that
//                                             oldest row is from now, whether that age can be judged against the purge
//                                             age, and what a purge with -days N would drop (N 1-3650, default 30: the
//                                             deploy timer's)
//   GET /api/instance/collections?instance=N  the instance's collections that stored a read: the interval the server
//                                             was given for each (0 = not run: disabled, or a schedule of 0), the
//                                             collector's default (0 = an opt-in collection), its last read, status,
//                                             duration and note, its errors and skips in the last 24 hours
//
// Both read only. The purge age itself is not known to the server: it is the -days of 'pgvigil purge', which the
// operator schedules (deploy/pgvigil-purge.timer); the page says so and takes the age to preview as a parameter.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// sqlRetentionSource is the text of purge(int) and of the *_purge functions it calls (pg_proc is readable by every
// login); $1 the names of the called ones.
const sqlRetentionSource = `
SELECT p.proname, p.prosrc
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'pgvigil' AND (p.proname = 'purge' OR p.proname = ANY($1::text[]))
 ORDER BY p.proname, p.oid DESC`

// sqlRetentionTables is every table of schema pgvigil that is not a partition: its size with its partitions (each
// with its indexes and TOAST), its partitions by month (a name ending _YYYYMM) or by day (_YYYYMMDD), the oldest of
// them, and the ones a purge with $1 days would drop under each rule: a month once the month after it lies before now -
// $1 (purge()'s rule), a day once the day after it does (mssql_running_purge()'s).
const sqlRetentionTables = `
WITH t AS (
  SELECT c.oid, c.relname, c.relkind, c.reltuples
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
), p AS (
  SELECT i.inhparent AS parent, k.relname, pg_total_relation_size(k.oid) AS bytes, k.reltuples,
         CASE WHEN k.relname ~ '_[0-9]{6}$' THEN to_date(right(k.relname, 6) || '01', 'YYYYMMDD') END AS month,
         CASE WHEN k.relname ~ '_[0-9]{8}$' THEN to_date(right(k.relname, 8), 'YYYYMMDD') END AS day
    FROM pg_inherits i
    JOIN pg_class k ON k.oid = i.inhrelid
   WHERE i.inhparent IN (SELECT oid FROM t)
)
SELECT t.relname AS table_name, t.relkind = 'p' AS partitioned,
       pg_total_relation_size(t.oid) + coalesce((SELECT sum(p.bytes) FROM p WHERE p.parent = t.oid), 0)::bigint AS size_bytes,
       CASE WHEN t.relkind = 'p' THEN coalesce((SELECT sum(greatest(p.reltuples, 0)) FROM p WHERE p.parent = t.oid), 0)
            ELSE greatest(t.reltuples, 0) END::bigint AS rows_estimate,
       (SELECT count(*) FROM p WHERE p.parent = t.oid AND (p.month IS NOT NULL OR p.day IS NOT NULL))::int AS partitions,
       (SELECT min(coalesce(p.day, p.month)) FROM p WHERE p.parent = t.oid) AS oldest_partition,
       (SELECT count(*) FROM p WHERE p.parent = t.oid AND p.month IS NOT NULL
           AND (p.month + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => $1))::int AS drop_months,
       coalesce((SELECT sum(p.bytes) FROM p WHERE p.parent = t.oid AND p.month IS NOT NULL
           AND (p.month + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => $1)), 0)::bigint AS drop_months_bytes,
       (SELECT count(*) FROM p WHERE p.parent = t.oid AND p.day IS NOT NULL
           AND (p.day + interval '1 day') AT TIME ZONE 'UTC' < now() - make_interval(days => $1))::int AS drop_days,
       coalesce((SELECT sum(p.bytes) FROM p WHERE p.parent = t.oid AND p.day IS NOT NULL
           AND (p.day + interval '1 day') AT TIME ZONE 'UTC' < now() - make_interval(days => $1)), 0)::bigint AS drop_days_bytes
  FROM t
 ORDER BY size_bytes DESC, t.relname`

// del is one DELETE of the purge functions: the time column it compares with the age, whether it takes only the rows
// no longer present, the table whose rows keep these (its first NOT EXISTS), and whether it is a pure age rule (the
// age comparison and nothing else, so a row older than the age means the purge did not run with that age).
type del struct {
	column string
	absent bool
	sameAs string
	pure   bool
}

// rule is what the purge functions do to one table.
type rule struct {
	kind string // monthly | daily | rows
	dels []del
}

var (
	reIdent       = regexp.MustCompile(`^[a-z_][a-z0-9_]*$`)
	reParentList  = regexp.MustCompile(`(?s)p\.relname\s+IN\s*\(([^)]*)\)`)
	reDailyParent = regexp.MustCompile(`p\.relname\s*=\s*'([a-z_][a-z0-9_]*)'\s+AND\s+c\.relname\s*~\s*'[^']*\[0-9\]\{8\}`)
	reQuoted      = regexp.MustCompile(`'([a-z_][a-z0-9_]*)'`)
	reCalled      = regexp.MustCompile(`pgvigil\.([a-z_][a-z0-9_]*_purge)\s*\(`)
	reDelete      = regexp.MustCompile(`(?is)DELETE\s+FROM\s+pgvigil\.([a-z_][a-z0-9_]*)(?:\s+[a-z_][a-z0-9_]*)?\s+WHERE\s+(.*?);`)
	reAge         = `(?:now\(\)\s*-\s*make_interval\(days\s*=>\s*p_days\)|v_old|date_trunc\(.*\)|\(SELECT\s+max)`
	reTimeCompare = regexp.MustCompile(`(?is)(?:^|[\s(])(?:[a-z_][a-z0-9_]*\.)?([a-z_][a-z0-9_]*)\s*<\s*` + reAge)
	rePure        = regexp.MustCompile(`(?is)^\s*(?:NOT\s+(?:[a-z_][a-z0-9_]*\.)?is_present\s+AND\s+)?(?:[a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*\s*<\s*(?:now\(\)\s*-\s*make_interval\(days\s*=>\s*p_days\)\s*$|v_old\s*$|date_trunc\(.*$)`)
	reAbsent      = regexp.MustCompile(`(?i)NOT\s+(?:[a-z_][a-z0-9_]*\.)?is_present`)
	reNotExists   = regexp.MustCompile(`(?i)NOT\s+EXISTS\s*\(\s*SELECT\s+1\s+FROM\s+pgvigil\.([a-z_][a-z0-9_]*)`)
)

// purgeRules reads the purge functions' texts: the parents whose monthly partitions purge() drops, the parents whose
// daily partitions a called function drops, and every DELETE of a table.
func purgeRules(srcs []string) map[string]*rule {
	out := map[string]*rule{}
	for _, src := range srcs {
		if m := reParentList.FindStringSubmatch(src); m != nil {
			for _, q := range reQuoted.FindAllStringSubmatch(m[1], -1) {
				out[q[1]] = &rule{kind: "monthly"}
			}
		}
		for _, m := range reDailyParent.FindAllStringSubmatch(src, -1) {
			out[m[1]] = &rule{kind: "daily"}
		}
	}
	for _, src := range srcs {
		for _, m := range reDelete.FindAllStringSubmatch(src, -1) {
			table, where := m[1], m[2]
			r := out[table]
			if r == nil {
				r = &rule{kind: "rows"}
				out[table] = r
			}
			if r.kind != "rows" {
				continue
			}
			d := del{absent: reAbsent.MatchString(where), pure: rePure.MatchString(where)}
			if t := reTimeCompare.FindStringSubmatch(where); t != nil {
				d.column = t[1]
			}
			if x := reNotExists.FindStringSubmatch(where); x != nil {
				d.sameAs = x[1]
			}
			r.dels = append(r.dels, d)
		}
	}
	return out
}

// retentionWords is a rule in the page's words, the time column and the table that keeps the rows (the first DELETE
// that names one), and whether the oldest row can be judged against the age.
func retentionWords(r *rule) (words, column, sameAs string, judged bool) {
	switch {
	case r == nil:
		return "kept whole", "", "", false
	case r.kind == "monthly":
		return "monthly partitions", "", "", true
	case r.kind == "daily":
		return "daily partitions", "", "", true
	}
	parts := make([]string, 0, len(r.dels))
	for _, d := range r.dels {
		if column == "" {
			column = d.column
		}
		if sameAs == "" {
			sameAs = d.sameAs
		}
		switch {
		case d.pure && d.absent:
			parts = append(parts, "rows absent longer than the age")
		case d.pure:
			parts = append(parts, "rows older than the age")
		case d.sameAs != "" && d.column != "":
			parts = append(parts, "rows older than the age that "+d.sameAs+" no longer names")
		case d.sameAs != "":
			parts = append(parts, "rows "+d.sameAs+" no longer names")
		default:
			parts = append(parts, "rows older than the age, under conditions (see purge())")
		}
	}
	judged = len(r.dels) == 1 && r.dels[0].pure
	if len(parts) > 1 {
		return fmt.Sprintf("%d rules: %s", len(parts), strings.Join(parts, "; ")), column, sameAs, false
	}
	return strings.Join(parts, ""), column, sameAs, judged
}

// retentionDays reads ?days= (the purge age to preview): 1-3650, default 30.
func retentionDays(r *http.Request) (int, error) {
	v := r.URL.Query().Get("days")
	if v == "" {
		return 30, nil
	}
	d, err := strconv.Atoi(v)
	if err != nil || d < 1 || d > 3650 {
		return 0, errors.New("days must be a whole number from 1 to 3650")
	}
	return d, nil
}

// oldestTimeout caps each table's oldest-row read, oldestBudget all of them on one page: a large table without an
// index on its time column is not scanned for longer (its cell then says it was not read), and the page answers well
// inside the server's write timeout.
const (
	oldestTimeout = 2 * time.Second
	oldestBudget  = 20 * time.Second
)

// oldestRow is min(column) of a table (only its absent rows when absent), read in a read-only transaction under
// oldestTimeout. The names come from the catalogue and the function text and are checked as plain identifiers before
// they are quoted into the statement.
func (s *Server) oldestRow(ctx context.Context, table, column string, absent bool) (*time.Time, string) {
	if column == "" || !reIdent.MatchString(table) || !reIdent.MatchString(column) {
		return nil, ""
	}
	if ctx.Err() != nil {
		return nil, fmt.Sprintf("not read: the page's %s budget for the oldest rows was spent", oldestBudget)
	}
	q := fmt.Sprintf(`SELECT min(%s)::timestamptz FROM pgvigil.%s`, pgx.Identifier{column}.Sanitize(), pgx.Identifier{table}.Sanitize())
	if absent {
		q += ` WHERE NOT is_present`
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, "not read: " + err.Error()
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()
	if _, err := tx.Exec(ctx, fmt.Sprintf(`SET LOCAL statement_timeout = %d`, oldestTimeout.Milliseconds())); err != nil {
		return nil, "not read: " + err.Error()
	}
	var at *time.Time
	if err := tx.QueryRow(ctx, q).Scan(&at); err != nil {
		switch {
		case strings.Contains(err.Error(), "statement timeout"):
			return nil, fmt.Sprintf("not read: over %s", oldestTimeout)
		case ctx.Err() != nil:
			return nil, fmt.Sprintf("not read: the page's %s budget for the oldest rows was spent", oldestBudget)
		}
		return nil, "not read: " + err.Error()
	}
	return at, ""
}

// Retention is GET /api/retention.
func (s *Server) Retention(w http.ResponseWriter, r *http.Request) {
	days, err := retentionDays(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx := r.Context()
	// purge() first, then the functions its text calls
	srcs, found := []string{}, false
	var main string
	if err := s.pool.QueryRow(ctx, `SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	   WHERE n.nspname = 'pgvigil' AND p.proname = 'purge' ORDER BY p.oid DESC LIMIT 1`).Scan(&main); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		s.reply(w, r, nil, fmt.Errorf("purge(): %w", err))
		return
	}
	if main != "" {
		found = true
		var called []string
		for _, m := range reCalled.FindAllStringSubmatch(main, -1) {
			called = append(called, m[1])
		}
		t, err := s.query(ctx, sqlRetentionSource, called)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("purge functions: %w", err))
			return
		}
		for _, row := range t.Rows {
			if v, ok := row[1].(string); ok {
				srcs = append(srcs, v)
			}
		}
	}
	rules := purgeRules(srcs)
	t, err := s.query(ctx, sqlRetentionTables, days)
	if err != nil {
		s.reply(w, r, nil, fmt.Errorf("tables: %w", err))
		return
	}
	col := map[string]int{}
	for i, c := range t.Columns {
		col[c] = i
	}
	now := time.Now()
	budget, cancel := context.WithTimeout(ctx, oldestBudget)
	defer cancel()
	out := &table{Columns: []string{"schema_name", "table_name", "size_bytes", "rows_estimate", "retention", "column_name", "same_as",
		"partitions", "oldest_partition", "oldest_row", "actual_days", "judged", "would_drop", "would_drop_bytes", "note"}, Rows: [][]any{}}
	for _, row := range t.Rows {
		name, _ := row[col["table_name"]].(string)
		partitioned, _ := row[col["partitioned"]].(bool)
		ru := rules[name]
		words, column, sameAs, judged := retentionWords(ru)
		note := ""
		if ru == nil && partitioned {
			note = "partitioned, but the purge drops none of its partitions: it grows until a release names it"
		}
		var drop, dropBytes any = 0, 0
		if ru != nil && ru.kind == "monthly" {
			drop, dropBytes = row[col["drop_months"]], row[col["drop_months_bytes"]]
		} else if ru != nil && ru.kind == "daily" {
			drop, dropBytes = row[col["drop_days"]], row[col["drop_days_bytes"]]
		}
		var actual, oldest any
		if p, ok := row[col["oldest_partition"]].(time.Time); ok {
			actual = int(now.Sub(p).Hours() / 24)
		}
		if ru != nil && ru.kind == "rows" && column != "" {
			absent := len(ru.dels) == 1 && ru.dels[0].absent
			at, why := s.oldestRow(budget, name, column, absent)
			if at != nil {
				oldest, actual = *at, int(now.Sub(*at).Hours()/24)
			}
			if why != "" {
				note = why
			}
		}
		out.Rows = append(out.Rows, []any{"pgvigil", name, row[col["size_bytes"]], row[col["rows_estimate"]], words, nullStr(column), nullStr(sameAs),
			row[col["partitions"]], row[col["oldest_partition"]], oldest, actual, judged, drop, dropBytes, nullStr(note)})
	}
	s.reply(w, r, map[string]any{"days": days, "purge_found": found, "tables": out}, nil)
}

func nullStr(v string) any {
	if v == "" {
		return nil
	}
	return v
}

// sqlInstanceCollections is one instance's collections as the repository saw them: the last read of each
// (collection_dates) and its errors and skips over the last 24 hours (collection_log).
const sqlInstanceCollections = `
SELECT d.collection, d.snapshot_at, d.duration_ms, d.status, d.note,
       (SELECT count(*) FROM pgvigil.collection_log l
         WHERE l.instance_id = d.instance_id AND l.collection = d.collection AND l.status = 'error'
           AND l.snapshot_at > now() - interval '24 hours')::int AS errors_24h,
       (SELECT count(*) FROM pgvigil.collection_log l
         WHERE l.instance_id = d.instance_id AND l.collection = d.collection AND l.status = 'skipped'
           AND l.snapshot_at > now() - interval '24 hours')::int AS skips_24h
  FROM pgvigil.collection_dates d
 WHERE d.instance_id = $1
 ORDER BY d.collection`

// InstanceCollections is GET /api/instance/collections: each collection that stored a read on the instance, with the
// interval the server was given for it (the instance's own, else the collector's default; 0 = not run now: in the
// instance's disabled: list, or a schedule of 0; null = not known to this server). Only collections that stored a read
// are listed: the server's interval map also holds the other engine's collections and the ones off for want of a door
// (no aws: block), all at 0, which a disabled: line must never name.
func (s *Server) InstanceCollections(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx := r.Context()
	var name, engine string
	if err := s.pool.QueryRow(ctx, `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name, &engine); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
			return
		}
		s.reply(w, r, nil, err)
		return
	}
	t, err := s.query(ctx, sqlInstanceCollections, id)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	own := s.expected.Instances[name]
	interval := func(c string) any {
		if v, ok := own[c]; ok {
			return v
		}
		if v, ok := s.expected.Defaults[c]; ok {
			return v
		}
		return nil
	}
	// default_s: the collector's own interval; 0 = an opt-in collection (off until a schedule gives it one), which a
	// disabled: line has nothing to do with
	def := func(c string) any {
		if v, ok := s.expected.Defaults[c]; ok {
			return v
		}
		return nil
	}
	out := &table{Columns: append([]string{"interval_s", "default_s"}, t.Columns...), Rows: [][]any{}}
	for _, row := range t.Rows {
		c, _ := row[0].(string)
		out.Rows = append(out.Rows, append([]any{interval(c), def(c)}, row...))
	}
	s.reply(w, r, map[string]any{"instance": name, "engine": engine, "collections": out}, nil)
}
