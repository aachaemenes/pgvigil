package remote

import (
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// The per-database snapshot sources (task 3 part 2 (f)): st:<db>, ct:<db>, qs_since:<db> and azdb_since, each by its
// import's current definition. cursors_test.go holds each case to its rule, cursors_sql_test.go each rule to its
// function on a store. One difference is named, not followed: the purges (mssql_plancache_purge 0092 L1125,
// mssql_index_depth_purge 0164 L626) drop guard rows older than the retention; a kept guard row refuses only a batch
// older than its database's last read by that much, which a collector reading forward never sends.

// dbTimes is a kept per-database time list: the names are each entry's JSON [database, time].
func decodeDBTimes(c format.Cursor) map[string]time.Time {
	out := map[string]time.Time{}
	for _, n := range c.Names {
		var f [2]string
		if json.Unmarshal([]byte(n), &f) != nil {
			continue
		}
		if t, err := time.Parse(time.RFC3339Nano, f[1]); err == nil {
			out[f[0]] = t
		}
	}
	return out
}

func encodeDBTimes(source string, m map[string]time.Time) format.Cursor {
	names := make([]string, 0, len(m))
	for db, t := range m {
		b, _ := json.Marshal([2]string{db, t.UTC().Format(time.RFC3339Nano)})
		names = append(names, string(b))
	}
	sort.Strings(names)
	return format.Cursor{Source: source, Kind: "list", Names: names}
}

func plainList(source string, set map[string]bool) format.Cursor {
	names := make([]string, 0, len(set))
	for n := range set {
		names = append(names, n)
	}
	sort.Strings(names)
	return format.Cursor{Source: source, Kind: "list", Names: names}
}

func sameNames(a, b format.Cursor) bool {
	return strings.Join(a.Names, "\n") == strings.Join(b.Names, "\n")
}

// toBool reads a value as PostgreSQL's text-to-boolean cast does (t / true / y / yes / on / 1 and their opposites,
// any case); anything else is false here (the cast would refuse the batch).
func toBool(v any) bool {
	switch b := v.(type) {
	case bool:
		return b
	case float64:
		return b == 1
	case int, int32, int64:
		n, _ := toInt64(b)
		return n == 1
	case string:
		switch strings.ToLower(strings.TrimSpace(b)) {
		case "t", "tr", "tru", "true", "y", "ye", "yes", "on", "1":
			return true
		}
	}
	return false
}

// namedDatabases is the batch's first 'databases' row whose names is a list (jsonb_typeof = 'array' ... LIMIT 1), as
// the set of its string elements (jsonb's ? operator); ok false when there is none.
func namedDatabases(rows []map[string]any) (map[string]bool, bool) {
	for _, r := range rows {
		if k, _ := r["kind"].(string); k != "databases" {
			continue
		}
		set := map[string]bool{}
		switch l := r["names"].(type) {
		case []any:
			for _, e := range l {
				if s, ok := e.(string); ok {
					set[s] = true
				}
			}
		case []string:
			for _, s := range l {
				set[s] = true
			}
		default:
			continue
		}
		return set, true
	}
	return nil, false
}

// perfChecked is mssql_perf_check's test (0074 L204-217): the batch's first state row carries server_utc.
func perfChecked(rows []map[string]any) bool {
	st := firstRow(rows, kindIs("state"))
	return st != nil && st["server_utc"] != nil
}

// statsMoves is import_mssql_stats (0092 L970-1035): mssql_perf_check (L973) refuses a batch without a state row
// carrying server_utc (nothing moves); per 'db' row with a name, a newer read of that database stands
// (mssql_stats_db's time, kept as 'stats_dbs'); otherwise its time becomes this read's and, when the row says read,
// 'st:<db>' takes the read's time (written over, never greatest). The first 'databases' row with a names list then
// drops the guard rows older than this read of the databases it does not name; 'st:' cursors stay.
func statsMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	if !perfChecked(rows) {
		return
	}
	at = at.UTC().Truncate(time.Microsecond)
	was, _ := cur("stats_dbs")
	m := decodeDBTimes(was)
	for _, r := range rows {
		k, _ := r["kind"].(string)
		db, named := r["database_name"].(string)
		if k != "db" || !named {
			continue
		}
		if t, ok := m[db]; ok && t.After(at) {
			continue
		}
		m[db] = at
		if toBool(r["read"]) {
			out["st:"+db] = format.Cursor{Source: "st:" + db, Kind: "mssql", LastEventAt: &at}
		}
	}
	if names, ok := namedDatabases(rows); ok {
		for db, t := range m {
			if t.Before(at) && !names[db] {
				delete(m, db)
			}
		}
	}
	if now := encodeDBTimes("stats_dbs", m); !sameNames(now, was) {
		out["stats_dbs"] = now
	}
}

// constraintsMoves is import_mssql_constraints (0164 L244-290): mssql_perf_check refuses a batch without a state row
// carrying server_utc (nothing moves); per 'db' row the same guard ('constraint_dbs'), a database not read takes the
// read's time and no cursor, a read one also 'ct:<db>' (kept as 'ct_dbs'). The first 'databases' row drops every ct:
// cursor of a database it does not name (one this batch read too) and the guard rows older than this read of those.
func constraintsMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	if !perfChecked(rows) {
		return
	}
	at = at.UTC().Truncate(time.Microsecond)
	was, _ := cur("constraint_dbs")
	m := decodeDBTimes(was)
	ctWas, _ := cur("ct_dbs")
	ct := map[string]bool{}
	for _, n := range ctWas.Names {
		ct[n] = true
	}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		db, named := r["database_name"].(string)
		if k != "db" || !named {
			continue
		}
		if t, ok := m[db]; ok && t.After(at) {
			continue
		}
		m[db] = at
		if toBool(r["read"]) {
			out["ct:"+db] = format.Cursor{Source: "ct:" + db, Kind: "mssql", LastEventAt: &at}
			ct[db] = true
		}
	}
	if names, ok := namedDatabases(rows); ok {
		for db := range ct {
			if !names[db] {
				out["ct:"+db] = format.Cursor{Source: "ct:" + db, Kind: "null"}
				delete(ct, db)
			}
		}
		for db, t := range m {
			if t.Before(at) && !names[db] {
				delete(m, db)
			}
		}
	}
	if now := encodeDBTimes("constraint_dbs", m); !sameNames(now, was) {
		out["constraint_dbs"] = now
	}
	if now := plainList("ct_dbs", ct); !sameNames(now, ctWas) {
		out["ct_dbs"] = now
	}
}

// queryStoreMoves is import_mssql_querystore (0083 L271-470, called unchanged by 0126 and 0157) behind
// mssql_hadr_read: each store row with a name is upserted at this read's time (kept as 'qs_stores'; its
// newest_interval stays); a batch with any store row drops the store rows older than this read, their cursor with
// them; 'qs_since:<db>' is the greatest of its own and the batch's newest interval_start among the ended intervals of
// a database with a forced_read marker, where its store row is, as epoch seconds (floor, mssql_hadr_cursor).
func queryStoreMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	if !hadrGuard("mssql_querystore", at, cur, out) {
		return
	}
	at = at.UTC().Truncate(time.Microsecond)
	was, _ := cur("qs_stores")
	stores := decodeDBTimes(was)
	anyStore := false
	whole := map[string]bool{}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		db, named := r["database_name"].(string)
		switch {
		case k == "store":
			anyStore = true
			if named {
				stores[db] = at
			}
		case k == "forced_read" && named:
			whole[db] = true
		}
	}
	if anyStore {
		for db, t := range stores {
			if t.Before(at) {
				delete(stores, db)
				out["qs_since:"+db] = format.Cursor{Source: "qs_since:" + db, Kind: "null"}
			}
		}
	}
	newest := map[string]time.Time{}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		db, _ := r["database_name"].(string)
		start, okStart := toTime(r["interval_start"])
		_, okEnd := toTime(r["interval_end"])
		if k != "interval" || !whole[db] || !okStart || !okEnd {
			continue
		}
		if n, seen := newest[db]; !seen || start.After(n) {
			newest[db] = start
		}
	}
	for db, n := range newest {
		if _, there := stores[db]; !there {
			continue
		}
		src := "qs_since:" + db
		v := n.Unix()
		if prev, ok := cur(src); ok && prev.Kind == "seq" && prev.Seq >= v {
			continue
		}
		out[src] = format.Cursor{Source: src, Kind: "seq", Seq: v}
	}
	if now := encodeDBTimes("qs_stores", stores); !sameNames(now, was) {
		out["qs_stores"] = now
	}
	qsPlanMoves(at, rows, cur, out)
}

// azureDBMoves is import_mssql_azuredb_resources (0145 L135-185): 'azdb_since' is the greatest stored minute
// (GREATEST ignores a batch without minute rows) as epoch seconds; no guard.
func azureDBMoves(rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	var newest *time.Time
	for _, r := range rows {
		if k, _ := r["kind"].(string); k != "minute" {
			continue
		}
		if t, ok := toTime(r["minute"]); ok && (newest == nil || t.After(*newest)) {
			tt := t
			newest = &tt
		}
	}
	if newest == nil {
		return
	}
	v := newest.Unix()
	if prev, ok := cur("azdb_since"); ok && prev.Kind == "seq" && prev.Seq >= v {
		return
	}
	out["azdb_since"] = format.Cursor{Source: "azdb_since", Kind: "seq", Seq: v}
}

// qsPlanState is a plan's row of pgvigil.mssql_qs_plan as qs_plan:<id>:<db> needs it, kept as the one name of the list
// 'qs_plan_state:<id>:<db>' (JSON). Listed is the read time of its last plan row (the row's snapshot_at).
type qsPlanState struct {
	Hash    *int64     `json:"hash"`
	QueryID *int64     `json:"query_id"`
	QHash   *string    `json:"query_hash"`
	XML     string     `json:"xml_state,omitempty"` // "" = NULL; stored | policy | too large
	Checked *time.Time `json:"checked_at,omitempty"`
	HasXML  bool       `json:"has_xml,omitempty"`
	Listed  time.Time  `json:"listed"`
}

// qsPlanDay is how long a plan's state counts after its last plan row: the hub's purge keeps a plan at least a day
// (pgvigil purge -days is at least 1), so a state younger than this is one the hub still holds (or holds with a newer
// row); an older one counts as absent - the remote then reads the plan's XML once more where the hub might not need
// it, never the other way round. With a transfer delay and a hub purging at -days 1, the hub can drop a plan the remote
// still holds; the remote then skips one policy look within the day (a remote sends no plan XML: TestRemotePlanXMLNeverKept).
const qsPlanDay = 24 * time.Hour

func decodeQSPlan(c format.Cursor, ok bool) (qsPlanState, bool) {
	var st qsPlanState
	if !ok || c.Kind != "list" || len(c.Names) != 1 || json.Unmarshal([]byte(c.Names[0]), &st) != nil {
		return qsPlanState{}, false
	}
	return st, true
}

func encodeQSPlan(source string, st qsPlanState) format.Cursor {
	b, _ := json.Marshal(st)
	return format.Cursor{Source: source, Kind: "list", Names: []string{string(b)}}
}

// qsPlanAnswer is mssql_hadr_cursor's qs_plan arm (0300 L1688-1693) over a kept plan state at now: the hash when the
// XML is stored, or was looked at under the text policy within 24 h; nothing for a state over qsPlanDay old.
func qsPlanAnswer(c format.Cursor, now time.Time) (int64, bool) {
	st, ok := decodeQSPlan(c, true)
	if !ok || st.Hash == nil || now.Sub(st.Listed) > qsPlanDay {
		return 0, false
	}
	if st.XML == "stored" || (st.XML == "policy" && st.Checked != nil && st.Checked.After(now.Add(-24*time.Hour))) {
		return *st.Hash, true
	}
	return 0, false
}

func sameInt(a, b *int64) bool  { return (a == nil) == (b == nil) && (a == nil || *a == *b) }
func sameStr(a, b *string) bool { return (a == nil) == (b == nil) && (a == nil || *a == *b) }
func intPtr(v any) *int64 {
	n, ok := toInt64(v)
	if !ok {
		return nil
	}
	return &n
}

// qsPlanMoves is 0083 L369-424's plan writes, after the store part of the same import: each plan row (a name, a plan
// id and a query id; the first per plan) upserts its plan - a changed hash, query id or query hash clears the XML, its
// state and its check time; an xml_note marks it 'too large' (the next plain row clears that); then each plan_xml row
// (the first per plan) of a plan that has a row stores its XML ('stored') or none ('policy', an empty statement is
// none) at the read's time. The forced_read policy update (L410-413) clears XML a plan holds: no remote plan holds any.
func qsPlanMoves(at time.Time, rows []map[string]any, cur func(string) (format.Cursor, bool), out map[string]format.Cursor) {
	batch := map[string]qsPlanState{}
	load := func(src string) (qsPlanState, bool) {
		if st, ok := batch[src]; ok {
			return st, true
		}
		c, ok := cur(src)
		st, ok := decodeQSPlan(c, ok)
		if !ok || at.Sub(st.Listed) > qsPlanDay {
			return qsPlanState{}, false
		}
		return st, true
	}
	key := func(r map[string]any) (string, bool) {
		db, named := r["database_name"].(string)
		id, isNum := toInt64(r["plan_id"])
		if !named || !isNum {
			return "", false
		}
		return "qs_plan_state:" + strconv.FormatInt(id, 10) + ":" + db, true
	}
	seen := map[string]bool{}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		src, ok := key(r)
		if k != "plan" || !ok || r["query_id"] == nil || seen[src] {
			continue
		}
		seen[src] = true
		next := qsPlanState{Hash: intPtr(r["plan_hash_n"]), QueryID: intPtr(r["query_id"]), Listed: at}
		if qh, isStr := r["query_hash_hex"].(string); isStr {
			next.QHash = &qh
		}
		tooLarge := r["xml_note"] != nil
		if tooLarge {
			next.XML = "too large"
		}
		if prev, there := load(src); there {
			changed := !sameInt(prev.Hash, next.Hash) || !sameInt(prev.QueryID, next.QueryID) || !sameStr(prev.QHash, next.QHash)
			if !changed && !tooLarge {
				next.HasXML = prev.HasXML
			}
			if !tooLarge && !changed && prev.XML != "too large" {
				next.XML = prev.XML
			}
			if !changed {
				next.Checked = prev.Checked
			}
		}
		batch[src] = next
	}
	seen = map[string]bool{}
	for _, r := range rows {
		k, _ := r["kind"].(string)
		src, ok := key(r)
		if k != "plan_xml" || !ok || seen[src] {
			continue
		}
		seen[src] = true
		st, there := load(src)
		if !there {
			continue
		}
		stmt, _ := r["statement"].(string)
		st.HasXML = stmt != ""
		st.XML = "policy"
		if st.HasXML {
			st.XML = "stored"
		}
		checked := at
		st.Checked = &checked
		batch[src] = st
	}
	for src, st := range batch {
		out[src] = encodeQSPlan(src, st)
	}
}
