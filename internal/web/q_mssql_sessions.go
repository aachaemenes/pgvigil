package web

import (
	"net/http"
	"strconv"
	"time"
)

// ---- sessions and connections (task 413, B22) -----------------------------------------------------------------------
//   GET /api/mssql/sessions?instance=N[&from=&to=][&at=<a group read's time>][&n=5|10|25][&part=...]
//        the Connections page's 'Sessions and requests' part (web/src/mssql_sessions.ts):
//          counts      the per-minute counts over the window (mssql_sessions: sessions and requests by user / system x
//                      status, the waiting tasks of user sessions)                       <- 0163 mssql_session_counts_between
//          reads       the 5-minute group reads of the window, newest first (the 'at' picker) <- mssql_session_by_reads
//          login, status, interface, address, isolation
//                      each dimension at the read 'at' (else the newest of the window), the 'other' row last
//          activity    every session's summed CPU / reads / writes at each group read (OVW#34; A2: summed in 413's own read)
//          policy      the instance's query_text policy now
//   GET /api/mssql/sessions?instance=N[&from=&to=][&n=5|10|25]&part=top   its own request (the page asks it apart, so a
//        slow top over a long window loses only the top list: multi answers a whole reply with one part's error):
//          top         the top requests per measure (CPU, logical reads, tempdb, memory grant, duration) from
//                      mssql_requests over the newest historyMaxWindow (7 days) of the window, n each (5 by default; 10
//                      or 25), the statement only under the instance's query_text policy 'full' or 'normalized', by
//                      that policy now (TEXT-NOW's stmt rule at read), none under 'none'
//          top_window  the window the top read and whether a longer one was cut to its newest 7 days
//          policy      as above
//        One user / system rule on every part: sys.dm_exec_sessions.is_user_process over all sessions (the lead 11-15).
//                                                                                          -> Server.MSSQLSessions

const sqlMSSQLSessionsTop = `
SELECT t.measure, t.rank, t.value, t.session_id, t.request_id, t.start_time, t.first_seen, t.last_seen, t.login_name,
       t.program_name, t.host_name, t.database_name,
       CASE WHEN $5 THEN left(st.statement, 4000) END AS "statement@stmt", CASE WHEN $5 THEN st.full_chars END AS full_chars
  FROM pgvigil.mssql_requests_top($1, $2, $3, $4) t
  LEFT JOIN pgvigil.mssql_statement_text st ON st.text_id = t.text_id
 ORDER BY t.measure, t.rank`

// MSSQLSessions is GET /api/mssql/sessions.
func (s *Server) MSSQLSessions(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	var at any // NULL: the newest group read of the window
	if v := q.Get("at"); v != "" {
		t, err := time.Parse(time.RFC3339Nano, v)
		if err != nil {
			writeErr(w, http.StatusBadRequest, errBadAt)
			return
		}
		at = t
	}
	n := 5
	if v := q.Get("n"); v != "" {
		k, err := strconv.Atoi(v)
		if err != nil || (k != 5 && k != 10 && k != 25) {
			writeErr(w, http.StatusBadRequest, errBadTopN)
			return
		}
		n = k
	}
	name, ok := s.mssqlInstanceName(w, r, id)
	if !ok {
		return
	}
	// the statement text follows the instance's query_text policy as this serve reads it now: under 'none' no text is
	// returned, whatever an earlier policy stored
	policy := s.doorsNow().planPolicy(name)
	showText := policy != "none"
	pol := part{"policy", `SELECT $1::text AS query_text`, []any{policy}}
	if q.Get("part") == "top" {
		tfrom, tend, cut := topWindow(from, to)
		s.multi(w, r, []part{
			{"top", sqlMSSQLSessionsTop, []any{id, tfrom, to, n, showText}},
			{"top_window", `SELECT $1::timestamptz AS from_at, $2::timestamptz AS to_at, $3::boolean AS cut`, []any{tfrom, tend, cut}},
			pol,
		})
		return
	}
	dim := func(d string) part {
		return part{d, `SELECT * FROM pgvigil.mssql_session_by_at($1, $2, $3, $4, $5)`, []any{id, from, to, d, at}}
	}
	s.multiPart(w, r, []part{
		{"counts", `SELECT * FROM pgvigil.mssql_session_counts_between($1, $2, $3)`, []any{id, from, to}},
		{"reads", `SELECT * FROM pgvigil.mssql_session_by_reads($1, $2, $3)`, []any{id, from, to}},
		dim("login"), dim("status"), dim("interface"), dim("address"), dim("isolation"),
		// OVW#34 (A2): the session CPU / reads / writes of EVERY session at each group read, the status rows summed
		// (413's own read; activity's program groups count only user sessions with a program name)
		{"activity", `SELECT snapshot_at, sum(cpu_ms) AS cpu_ms, sum(reads) AS reads, sum(writes) AS writes
  FROM pgvigil.mssql_session_by WHERE instance_id = $1 AND dimension = 'status' AND snapshot_at > $2 AND snapshot_at <= $3
 GROUP BY snapshot_at ORDER BY snapshot_at`, []any{id, from, to}},
		pol,
	})
}

// topWindow is the top's reach: the newest historyMaxWindow of the window, counted back from its end or now, whichever is
// earlier (paramsReach's rule); cut says a longer window was cut.
func topWindow(from, to time.Time) (time.Time, time.Time, bool) {
	end := to
	if now := time.Now(); end.After(now) {
		end = now
	}
	if end.Sub(from) > historyMaxWindow {
		return end.Add(-historyMaxWindow), end, true
	}
	return from, end, false
}

var (
	errBadAt   = badParam("at must be a group read's time (RFC 3339)")
	errBadTopN = badParam("n must be 5, 10 or 25")
)

type badParam string

func (e badParam) Error() string { return string(e) }
