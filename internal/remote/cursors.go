package remote

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// cursorMoves is what an import of one batch into view would do to the instance's cursors, as the repository's
// import functions do it - the remote collector has no repository, so the next read must start where the hub's
// cursor would stand. cur returns the value before the batch (the open bundle's newest, else the committed state).
//
// The rules (each with the SQL it follows; cursors_test.go holds each to its rule, and the rows that hold each to
// its SQL function on a store are task 3's next part):
//   - an explicit {kind:'cursor', source, read_to} row: a log cursor, the later of the two times (0079 L87-90,
//     0053 L113-116, 0100 L284-287);
//   - an explicit SQL Server row (mssql.Cursor.Row: file_name, file_offset, last_event_at, last_seq): the batch's
//     last row of the source (0065, 0158, 0160, 0161, 0162: DISTINCT ON (source) ... ORDER BY n DESC);
//   - the one-number families as mssql_hadr_cursor answers them (0300 L1682-1705), each by its view's own rule
//     (cursors_mssql.go) behind mssql_hadr_read's guard: mssql_jobs (0094), mssql_backup_files (0140) and
//     mssql_backup_history (0191);
//   - amcheck: the batch's time when it holds a 'run' row, never back (0023 L51-56);
//   - schema_ddl:<database>: the newest ddl logged_at or ddl_cursor read_to per database, forward only (0300
//     L2316-2322).
func cursorMoves(view string, at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool)) []format.Cursor {
	out := map[string]format.Cursor{}
	switch view {
	case "mssql_jobs":
		jobsMoves(at, rows, cur, out)
		return sorted(out)
	case "mssql_backup_files":
		backupFilesMoves(at, rows, cur, out)
		return sorted(out)
	case "mssql_backup_history":
		backupHistoryMoves(at, rows, cur, out)
		return sorted(out)
	}
	logMove := func(source string, t time.Time) {
		if prev, ok := out[source]; ok && prev.At != nil && prev.At.After(t) {
			return
		}
		if prev, ok := cur(source); ok && prev.At != nil && prev.At.After(t) {
			t = *prev.At
		}
		tt := t.UTC()
		out[source] = format.Cursor{Source: source, Kind: "log", At: &tt}
	}
	hasRun := false
	ddl := map[string]time.Time{}
	for _, r := range rows {
		kind, _ := r["kind"].(string)
		source, _ := r["source"].(string)
		switch kind {
		case "cursor":
			switch {
			case source != "" && r["read_to"] != nil:
				if t, ok := toTime(r["read_to"]); ok {
					logMove(source, t)
				}
			case source != "" && (hasKey(r, "last_seq") || hasKey(r, "file_name") || hasKey(r, "last_event_at")):
				c := format.Cursor{Source: source, Kind: "mssql"}
				c.FileName, _ = r["file_name"].(string)
				c.FileOffset, _ = toInt64(r["file_offset"])
				if t, ok := toTime(r["last_event_at"]); ok {
					tt := t.UTC()
					c.LastEventAt = &tt
				}
				c.LastSeq, _ = toInt64(r["last_seq"])
				out[source] = c
			}
		case "run":
			hasRun = true
		case "ddl", "ddl_cursor":
			db, _ := r["datname"].(string)
			key := "logged_at"
			if kind == "ddl_cursor" {
				key = "read_to"
			}
			if t, ok := toTime(r[key]); ok && db != "" {
				if prev, seen := ddl[db]; !seen || t.After(prev) {
					ddl[db] = t
				}
			}
		}
	}
	if view == "amcheck" && hasRun {
		logMove("amcheck", at)
	}
	if view == "schema" {
		for db, t := range ddl {
			logMove("schema_ddl:"+db, t)
		}
	}
	return sorted(out)
}

// sorted lists the moved cursors by source.
func sorted(out map[string]format.Cursor) []format.Cursor {
	moved := make([]format.Cursor, 0, len(out))
	for _, c := range out {
		moved = append(moved, c)
	}
	sort.Slice(moved, func(i, j int) bool { return moved[i].Source < moved[j].Source })
	return moved
}

func hasKey(r map[string]any, k string) bool { _, ok := r[k]; return ok }

// toTime reads a time a collector put in a row: a time.Time, or its RFC 3339 text.
func toTime(v any) (time.Time, bool) {
	switch t := v.(type) {
	case time.Time:
		return t, !t.IsZero()
	case *time.Time:
		if t != nil {
			return *t, !t.IsZero()
		}
	case string:
		if p, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(t)); err == nil {
			return p, true
		}
	}
	return time.Time{}, false
}

// toInt64 reads a whole number a collector put in a row (any integer type, a float holding one, or its text).
func toInt64(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int32:
		return int64(n), true
	case int64:
		return n, true
	case uint32:
		return int64(n), true
	case float64:
		if n == float64(int64(n)) {
			return int64(n), true
		}
	case string:
		if p, err := strconv.ParseInt(strings.TrimSpace(n), 10, 64); err == nil {
			return p, true
		}
	}
	return 0, false
}
