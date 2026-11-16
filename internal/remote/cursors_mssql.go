package remote

import (
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// The rules of the three SQL Server imports whose cursors depend on more than the batch's cursor row. Each follows
// its function's current definition line by line; cursors_test.go holds each case to its rule and
// cursors_sql_test.go holds the rule to the function on a store.

// hadrGuard is mssql_hadr_read (0066 L134-153), the first statement of each of these imports: a batch older than
// the collection's last read is refused (nothing of it moves); the same time or later is the newest and becomes the
// last read. The last read is kept as the local source 'hadr_read:<view>', at the store's precision (microseconds).
func hadrGuard(view string, at time.Time, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) bool {
	key := "hadr_read:" + view
	at = at.UTC().Truncate(time.Microsecond)
	if prev, ok := cur(key); ok && prev.At != nil && prev.At.After(at) {
		return false
	}
	out[key] = format.Cursor{Source: key, Kind: "log", At: &at}
	return true
}

// seqOrNull is a one-number source as the import stores it: the number, or NULL when the row carries none.
func seqOrNull(source string, v any) format.Cursor {
	if n, ok := toInt64(v); ok {
		return format.Cursor{Source: source, Kind: "seq", Seq: n}
	}
	return format.Cursor{Source: source, Kind: "null"}
}

// firstRow is the batch's first row of a kind that pred accepts (the functions' 'WHERE ... LIMIT 1').
func firstRow(rows []map[string]any, pred func(map[string]any) bool) map[string]any {
	for _, r := range rows {
		if pred(r) {
			return r
		}
	}
	return nil
}

func kindIs(k string) func(map[string]any) bool {
	return func(r map[string]any) bool { s, _ := r["kind"].(string); return s == k }
}

// jobsMoves is import_mssql_jobs (0094 L151-222): the first cursor row's last_history_id and mark, stored only when
// the batch is the newest read; a first cursor row without last_history_id stores nothing.
func jobsMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	if !hadrGuard("mssql_jobs", at, cur, out) {
		return
	}
	r := firstRow(rows, kindIs("cursor"))
	if r == nil {
		return
	}
	if n, ok := toInt64(r["last_history_id"]); ok {
		out["jobs"] = format.Cursor{Source: "jobs", Kind: "seq", Seq: n}
		out["jobs_mark"] = seqOrNull("jobs_mark", r["mark"])
	}
}

// backupHistoryMoves is import_mssql_backup_history (0191 L154-276). Its cursor row is made by the collection's first
// accepted batch (every accepted batch upserts it, so the row exists exactly when 'hadr_read:mssql_backup_history'
// did before this batch): made, it takes the batch's values as they are; there, a value the batch does not carry is
// kept (coalesce) and restores move only when restore_read is 'read'. v_again: a cursor read (from_set_id > 0)
// listing a database the last listing did not hold sends last_set_id to 0, its mark as the batch has it. A batch
// listing databases (a 'database' row with a name) replaces the list.
func backupHistoryMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	_, existed := cur("hadr_read:mssql_backup_history")
	if !hadrGuard("mssql_backup_history", at, cur, out) {
		return
	}
	from, restoreRead := int64(0), "read"
	if r := firstRow(rows, kindIs("read")); r != nil {
		if n, ok := toInt64(r["from_set_id"]); ok {
			from = n
		}
		if s, ok := r["restore_read"].(string); ok {
			restoreRead = s
		}
	}
	listed := map[string]bool{}
	for _, r := range rows {
		if k, _ := r["kind"].(string); k == "database" {
			if n, _ := r["database_name"].(string); n != "" {
				listed[n] = true
			}
		}
	}
	held := map[string]bool{}
	if c, ok := cur("backup_history_dbs"); ok {
		for _, n := range c.Names {
			held[n] = true
		}
	}
	again := false
	if from > 0 {
		for n := range listed {
			if !held[n] {
				again = true
			}
		}
	}
	source := func(s string) map[string]any {
		return firstRow(rows, func(r map[string]any) bool {
			k, _ := r["kind"].(string)
			src, _ := r["source"].(string)
			return k == "cursor" && src == s
		})
	}
	bh, rh := source("backup_history"), source("restore_history")
	set := func(name string, v any, ok bool) {
		if n, isNum := toInt64(v); ok && isNum {
			out[name] = format.Cursor{Source: name, Kind: "seq", Seq: n}
		}
	}
	var lastSet any
	if bh != nil {
		lastSet = bh["last_id"]
	}
	if again {
		lastSet = int64(0)
	}
	set("backup_history", lastSet, true)
	if bh != nil {
		set("backup_history_mark", bh["mark"], true)
	}
	if rh != nil {
		restores := !existed || restoreRead == "read"
		set("restore_history", rh["last_id"], restores)
		set("restore_history_mark", rh["mark"], restores)
	}
	if len(listed) > 0 {
		names := make([]string, 0, len(listed))
		for n := range listed {
			names = append(names, n)
		}
		sort.Strings(names)
		out["backup_history_dbs"] = format.Cursor{Source: "backup_history_dbs", Kind: "list", Names: names}
	}
}

// heldSet is one row of pgvigil.mssql_backup_sets as backup_files' rule needs it: its key and the database's creation
// time the set was stored with (nil: NULL).
type heldSet struct {
	db, typ string
	copy    bool
	created *time.Time
}

// The held sets travel as a list whose names are each set's JSON [database, type, copy-only "0"/"1", created or ""].
func decodeHeld(c format.Cursor) map[[3]string]heldSet {
	out := map[[3]string]heldSet{}
	for _, n := range c.Names {
		var f [4]string
		if json.Unmarshal([]byte(n), &f) != nil {
			continue
		}
		h := heldSet{db: f[0], typ: f[1], copy: f[2] == "1"}
		if t, err := time.Parse(time.RFC3339Nano, f[3]); err == nil {
			h.created = &t
		}
		out[[3]string{f[0], f[1], f[2]}] = h
	}
	return out
}

func encodeHeld(held map[[3]string]heldSet) format.Cursor {
	names := make([]string, 0, len(held))
	for k, h := range held {
		created := ""
		if h.created != nil {
			created = h.created.UTC().Format(time.RFC3339Nano)
		}
		b, _ := json.Marshal([4]string{k[0], k[1], k[2], created})
		names = append(names, string(b))
	}
	sort.Strings(names)
	return format.Cursor{Source: "backup_sets_held", Kind: "list", Names: names}
}

// recreated is mssql_recreated (0066 L653-656): one creation time known and the other not, or more than 3900 s apart.
func recreated(was, now *time.Time) bool {
	if (was == nil) != (now == nil) {
		return true
	}
	if was == nil {
		return false
	}
	d := now.Sub(*was)
	return d > 3900*time.Second || d < -3900*time.Second
}

// backupFilesMoves is import_mssql_backup_files (0140 L328-510). A batch holding 'database' rows (v_dbs > 0): v_back
// when a cursor read ('from' > 0) lists a database of the kept 'unlisted' list; the new list is the old one and every
// database holding stored sets, less the databases listed now; the sets of a database not listed, or listed as
// created anew, go. Sets are stored for listed databases (full / diff / log, finished, no earlier than an hour before
// the database's creation). The first cursor row with last_set_id stores it and its mark. Then, with databases
// listed: a cursor row there takes the new list (and 0 with a NULL mark on v_back); none and a non-empty list makes
// it at 0 with a NULL mark. The stored sets are kept as the local list 'backup_sets_held' (only their keys and
// creation times: what 'unlisted' and mssql_recreated need).
func backupFilesMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	if !hadrGuard("mssql_backup_files", at, cur, out) {
		return
	}
	dbs := 0
	listed := map[string]*time.Time{}
	for _, r := range rows {
		if k, _ := r["kind"].(string); k != "database" {
			continue
		}
		dbs++
		n, ok := r["database_name"].(string)
		if _, seen := listed[n]; !ok || seen {
			continue
		}
		listed[n] = nil
		if t, ok := toTime(r["created_utc"]); ok {
			tt := t.UTC()
			listed[n] = &tt
		}
	}
	var unlisted []string
	if c, ok := cur("backup_sets_unlisted"); ok {
		unlisted = c.Names
	}
	heldCur, _ := cur("backup_sets_held")
	held := decodeHeld(heldCur)
	before := encodeHeld(held)
	_, rowThere := cur("backup_sets")

	back := false
	var newUnlisted []string
	if dbs > 0 {
		var from int64
		if r := firstRow(rows, kindIs("read")); r != nil {
			from, _ = toInt64(r["from"])
		}
		for _, u := range unlisted {
			if _, ok := listed[u]; ok && from > 0 {
				back = true
			}
		}
		next := map[string]bool{}
		for _, u := range unlisted {
			next[u] = true
		}
		for _, h := range held {
			next[h.db] = true
		}
		for n := range next {
			if _, ok := listed[n]; !ok {
				newUnlisted = append(newUnlisted, n)
			}
		}
		sort.Strings(newUnlisted)
		for k, h := range held {
			if created, ok := listed[h.db]; !ok || recreated(h.created, created) {
				delete(held, k)
			}
		}
	}
	for _, r := range rows {
		if k, _ := r["kind"].(string); k != "set" {
			continue
		}
		db, _ := r["database_name"].(string)
		created, ok := listed[db]
		typ, _ := r["backup_type"].(string)
		finish, finished := toTime(r["finish_utc"])
		if !ok || (typ != "full" && typ != "diff" && typ != "log") || !finished || (created != nil && finish.Before(created.Add(-time.Hour))) {
			continue
		}
		cp := "0"
		if n, _ := toInt64(r["is_copy_only"]); n == 1 {
			cp = "1"
		}
		held[[3]string{db, typ, cp}] = heldSet{db: db, typ: typ, copy: cp == "1", created: created}
	}
	if after := encodeHeld(held); strings.Join(after.Names, "\n") != strings.Join(before.Names, "\n") {
		out["backup_sets_held"] = after
	}

	if r := firstRow(rows, func(r map[string]any) bool {
		k, _ := r["kind"].(string)
		_, ok := toInt64(r["last_set_id"])
		return k == "cursor" && ok
	}); r != nil {
		n, _ := toInt64(r["last_set_id"])
		out["backup_sets"] = format.Cursor{Source: "backup_sets", Kind: "seq", Seq: n}
		out["backup_sets_mark"] = seqOrNull("backup_sets_mark", r["mark"])
		rowThere = true
	}
	if dbs > 0 {
		switch {
		case rowThere:
			out["backup_sets_unlisted"] = format.Cursor{Source: "backup_sets_unlisted", Kind: "list", Names: newUnlisted}
			if back {
				out["backup_sets"] = format.Cursor{Source: "backup_sets", Kind: "seq", Seq: 0}
				out["backup_sets_mark"] = format.Cursor{Source: "backup_sets_mark", Kind: "null"}
			}
		case len(newUnlisted) > 0:
			out["backup_sets"] = format.Cursor{Source: "backup_sets", Kind: "seq", Seq: 0}
			out["backup_sets_mark"] = format.Cursor{Source: "backup_sets_mark", Kind: "null"}
			out["backup_sets_unlisted"] = format.Cursor{Source: "backup_sets_unlisted", Kind: "list", Names: newUnlisted}
		}
	}
}
