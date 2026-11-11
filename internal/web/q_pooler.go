package web

import (
	"fmt"
	"net/http"
	"time"
)

// The pooler traced (task 128): PgBouncer's clients and servers as read (SHOW CLIENTS, SHOW SERVERS, migration 0081)
// with each server's backend joined to the activity snapshot and its blocking chains.
//
// GET /api/pooler/conns?instance=<id>&[at=|to=] (Server.PoolerConns): the read pgvigil.pooler_read_at gives for at (else
// to, else now): the nearest read within two minutes, else the newest before it.
//
//	read     one row: the read's time, the paired activity snapshot's time, the clients read and kept, the servers read
//	clients  the clients kept (not idle; the longest waits first), each with its paired server's backend pid
//	servers  the servers, each with its backend's state, wait, ages, role in a chain (head | blocked | in a cycle) and
//	         its chain's head, and the application of the client it serves
//	trace    one row per pool (database, user) with a client waiting or a server whose backend is in a chain: the
//	         waiting clients and the longest wait, the servers, how many are busy and blocked, the heads its blocked
//	         servers wait behind (head_pids), its own servers that head a chain (heading_pids), and the servers whose
//	         pid is a session of another login or database here (servers_elsewhere: not this instance's backend)
//	heads    one row per head that a blocked pooler server's backend waits behind: its pid, state, application, last
//	         statement, whether the head is itself a pooler server and whose, the servers behind it and the clients
//	         waiting in the pools those servers belong to
//
// ?part= reads one part. No read for the instance: every part is empty.

const sqlPoolerConnRead = `
SELECT c.snapshot_at AS read_at,
       (SELECT a.snapshot_at FROM pgvigil.activity_summary a
         WHERE a.instance_id = $1 AND a.snapshot_at BETWEEN c.snapshot_at - interval '2 minutes' AND c.snapshot_at + interval '2 minutes'
         ORDER BY abs(extract(epoch FROM a.snapshot_at - c.snapshot_at)), a.snapshot_at DESC LIMIT 1) AS activity_at,
       c.clients_read, c.clients_kept, c.servers_read
  FROM pgvigil.pooler_conn_sample c
 WHERE c.instance_id = $1 AND c.kind = 'conns' AND c.snapshot_at = pgvigil.pooler_read_at($1, $2)`

const sqlPoolerConnClients = `
SELECT database, usr AS "user", state, application_name, addr, port, connect_time, request_time, wait_us, backend_pid,
       backend_match, paired_addr, backend_state, backend_wait_type, backend_wait, backend_query_secs, blocking_pids, role, head_pid, head_state
  FROM pgvigil.pooler_conns($1, $2) WHERE kind = 'client'`

const sqlPoolerConnServers = `
SELECT database, usr AS "user", state, application_name, addr, port, connect_time, request_time, backend_pid,
       backend_match, paired_application, paired_addr, backend_state, backend_wait_type, backend_wait, backend_query_secs, backend_xact_secs,
       blocking_pids, role, head_pid, head_state, head_application, head_query, head_via_pooler, head_client_application,
       backend_query
  FROM pgvigil.pooler_conns($1, $2) WHERE kind = 'server'`

const sqlPoolerConnTrace = `
WITH c AS (SELECT * FROM pgvigil.pooler_conns($1, $2))
SELECT c.database, c.usr AS "user",
       count(*) FILTER (WHERE c.kind = 'client' AND c.state LIKE 'waiting%') AS clients_waiting,
       max(c.wait_us) FILTER (WHERE c.kind = 'client' AND c.state LIKE 'waiting%') AS longest_wait_us,
       count(*) FILTER (WHERE c.kind = 'client' AND c.state LIKE 'active%') AS clients_active,
       count(*) FILTER (WHERE c.kind = 'server') AS servers,
       count(*) FILTER (WHERE c.kind = 'server' AND c.state LIKE 'active%') AS servers_active,
       count(*) FILTER (WHERE c.kind = 'server' AND c.role IN ('blocked', 'in a cycle')) AS servers_blocked,
       count(*) FILTER (WHERE c.kind = 'server' AND c.role = 'head') AS servers_heading,
       array_agg(DISTINCT c.head_pid) FILTER (WHERE c.kind = 'server' AND c.role IN ('blocked', 'in a cycle') AND c.head_pid IS NOT NULL) AS head_pids,
       array_agg(DISTINCT c.backend_pid) FILTER (WHERE c.kind = 'server' AND c.role = 'head') AS heading_pids,
       count(*) FILTER (WHERE c.kind = 'server' AND c.backend_match = 'another backend') AS servers_elsewhere
  FROM c
 GROUP BY c.database, c.usr
HAVING count(*) FILTER (WHERE c.kind = 'client' AND c.state LIKE 'waiting%') > 0
    OR count(*) FILTER (WHERE c.kind = 'server' AND c.role IS NOT NULL) > 0
 ORDER BY 3 DESC, 4 DESC NULLS LAST, 1, 2`

const sqlPoolerConnHeads = `
WITH c AS (SELECT * FROM pgvigil.pooler_conns($1, $2)),
w AS (SELECT database, usr, count(*) AS waiting, max(wait_us) AS longest_wait_us
        FROM c WHERE kind = 'client' AND state LIKE 'waiting%' GROUP BY database, usr),
s AS (SELECT * FROM c WHERE kind = 'server' AND role IN ('blocked', 'in a cycle') AND head_pid IS NOT NULL)
SELECT s.head_pid, max(s.head_state) AS head_state, max(s.head_application) AS head_application, max(s.head_query) AS head_query,
       bool_or(s.head_via_pooler) AS head_via_pooler, max(s.head_client_application) AS head_client_application,
       count(*) AS servers_behind,
       array_agg(DISTINCT s.database || '/' || s.usr) AS pools,
       (SELECT coalesce(sum(w.waiting), 0) FROM w WHERE (w.database, w.usr) IN (SELECT x.database, x.usr FROM s x WHERE x.head_pid = s.head_pid)) AS clients_waiting,
       (SELECT max(w.longest_wait_us) FROM w WHERE (w.database, w.usr) IN (SELECT x.database, x.usr FROM s x WHERE x.head_pid = s.head_pid)) AS longest_wait_us
  FROM s
 GROUP BY s.head_pid
 ORDER BY 7 DESC, 9 DESC, 1`

// PoolerConns serves the clients, servers and trace of one pooler read.
func (s *Server) PoolerConns(w http.ResponseWriter, r *http.Request) {
	id, _, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	at := to
	if v := r.URL.Query().Get("at"); v != "" {
		if at, err = time.Parse(time.RFC3339, v); err != nil {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("at: %w", err))
			return
		}
	}
	s.multiPart(w, r, []part{
		{"read", sqlPoolerConnRead, []any{id, at}},
		{"clients", sqlPoolerConnClients, []any{id, at}},
		{"servers", sqlPoolerConnServers, []any{id, at}},
		{"trace", sqlPoolerConnTrace, []any{id, at}},
		{"heads", sqlPoolerConnHeads, []any{id, at}},
	})
}
