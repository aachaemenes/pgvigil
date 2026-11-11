package demo

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// SeedPooler puts a PgBouncer in front of one demo instance (task 128) so the Pooler tab, its clients and servers and
// the trace to a blocking head are seen on a served demo at all. The instance is the demo fleet's (tagged demo, its name
// starting with prefix, engine postgres) whose activity history holds the most idle-in-transaction blockers, then the
// most lock waits: the one whose chains a pooled application would queue behind.
//
// The pooler reads are derived from that instance's own activity snapshots in (from, to], one read five seconds before
// each snapshot, so every number agrees with Running queries. A pool per (database, user) of the sampled client
// backends, its size the most sessions it held in one snapshot of the history, at most demoPoolSize. In each snapshot up
// to that size of the pool's sessions are pooler servers (remote_pid = the session's pid, one active client paired with
// it: the session's application and address), the lock waiters first, then the sessions others wait on, then by pid;
// the rest connected directly (a batch job, a migration tool: not every session goes through the pooler). A pool not
// full has idle servers (pids no snapshot holds). A full pool with a server blocked on a lock queues 3 + 2 x (its
// blocked servers) clients, the longest waiting as long as its oldest blocked server, at most 110 s (the demo's
// query_wait_timeout is 120 s: PgBouncer drops a client that waits longer). Re-run for a range it already
// holds, a read is replaced, not doubled (import_pgbouncer replaces its clients and servers; the pool rows are kept
// once per read). The live tick calls it for the minute it imports.
func SeedPooler(ctx context.Context, pool *pgxpool.Pool, prefix string, from, to time.Time) error {
	var id int
	err := pool.QueryRow(ctx, `
SELECT i.instance_id FROM pgvigil.instances i
  LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE s.state = 'idle in transaction' AND s.is_blocker) AS idle_heads,
                            count(*) FILTER (WHERE s.wait_event_type = 'Lock') AS waits
                       FROM pgvigil.activity_sample s WHERE s.instance_id = i.instance_id) a ON true
 WHERE 'demo' = ANY (i.tags) AND starts_with(i.name, $1) AND coalesce(i.engine, 'postgres') = 'postgres'
 ORDER BY a.idle_heads DESC, a.waits DESC, i.name LIMIT 1`, prefix).Scan(&id)
	if err != nil {
		return fmt.Errorf("pick the pooler's instance: %w", err)
	}
	// the pool sizes: the most sessions a pool held in one snapshot of the history
	size := map[[2]string]int{}
	rows, err := pool.Query(ctx, `
SELECT datname, usename, max(n) FROM (
  SELECT snapshot_at, coalesce(datname, '') AS datname, coalesce(usename, '') AS usename, count(*) AS n
    FROM pgvigil.activity_sample WHERE instance_id = $1 AND coalesce(backend_type, 'client backend') = 'client backend'
   GROUP BY 1, 2, 3) x GROUP BY 1, 2`, id)
	if err != nil {
		return err
	}
	for rows.Next() {
		var db, usr string
		var n int
		if err := rows.Scan(&db, &usr, &n); err != nil {
			rows.Close()
			return err
		}
		size[[2]string{db, usr}] = min(n, demoPoolSize)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	type sess struct {
		pid                 int
		db, usr, app, cl, s string
		lock, blocker       bool
		since               time.Time
	}
	snaps := map[time.Time][]sess{}
	var times []time.Time
	rows, err = pool.Query(ctx, `
SELECT a.snapshot_at, s.pid, coalesce(s.datname, ''), coalesce(s.usename, ''), coalesce(s.application_name, ''), coalesce(s.client, ''),
       coalesce(s.state, ''), coalesce(s.wait_event_type = 'Lock', false), coalesce(s.is_blocker, false), coalesce(s.query_start, a.snapshot_at)
  FROM pgvigil.activity_summary a
  LEFT JOIN pgvigil.activity_sample s ON s.instance_id = a.instance_id AND s.snapshot_at = a.snapshot_at
                                      AND coalesce(s.backend_type, 'client backend') = 'client backend'
 WHERE a.instance_id = $1 AND a.snapshot_at > $2 AND a.snapshot_at <= $3
 ORDER BY a.snapshot_at, s.pid`, id, from, to)
	if err != nil {
		return err
	}
	for rows.Next() {
		var at, since time.Time
		var pid *int
		var x sess
		if err := rows.Scan(&at, &pid, &x.db, &x.usr, &x.app, &x.cl, &x.s, &x.lock, &x.blocker, &since); err != nil {
			rows.Close()
			return err
		}
		if _, ok := snaps[at]; !ok {
			snaps[at] = nil
			times = append(times, at)
		}
		if pid != nil {
			x.pid, x.since = *pid, since
			snaps[at] = append(snaps[at], x)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	dbs := map[string]int{}
	for k, n := range size {
		dbs[k[0]] = max(dbs[k[0]], n)
	}
	for _, at := range times {
		read := at.Add(-5 * time.Second)
		ss := snaps[at]
		payload := []Row{{"kind": "state", "status": "ok", "reason": nil, "version": "PgBouncer 1.26.1"}}
		for _, db := range sortedKeys(dbs) {
			payload = append(payload, Row{"kind": "database", "name": db, "host": "10.60.1.10", "port": 5432, "database": db,
				"pool_size": dbs[db], "min_pool_size": 0, "reserve_pool": 0, "pool_mode": "transaction", "max_connections": 0,
				"current_connections": dbs[db], "paused": false, "disabled": false})
		}
		for _, kv := range [][2]string{{"pool_mode", "transaction"}, {"max_client_conn", "2000"}, {"default_pool_size", "20"},
			{"query_wait_timeout", "120"}, {"server_idle_timeout", "600"}, {"stats_period", "60"}} {
			payload = append(payload, Row{"kind": "config", "key": kv[0], "value": kv[1], "changeable": true})
		}
		var clients, servers []Row
		read0 := 0
		for _, k := range sortedPools(size) {
			var in []sess
			for _, x := range ss {
				if x.db == k[0] && x.usr == k[1] {
					in = append(in, x)
				}
			}
			rank := func(x sess) int {
				switch {
				case x.lock:
					return 0
				case x.blocker:
					return 1
				}
				return 2
			}
			sort.SliceStable(in, func(i, j int) bool { return rank(in[i]) < rank(in[j]) })
			if len(in) > size[k] {
				in = in[:size[k]] // the rest connected directly
			}
			blocked := 0
			var oldest time.Time
			for _, x := range in {
				if x.lock {
					blocked++
					if oldest.IsZero() || x.since.Before(oldest) {
						oldest = x.since
					}
				}
			}
			waiting, maxwait := 0, 0.0
			if blocked > 0 && len(in) >= size[k] {
				waiting = 3 + 2*blocked
				// below the demo's query_wait_timeout (120 s): PgBouncer drops a client that waits longer
				maxwait = min(at.Sub(oldest).Seconds(), 110)
			}
			idle := max(size[k]-len(in), 0)
			app := "web"
			for i, x := range in {
				sp, cp := fmt.Sprintf("0x7f20%08x", x.pid), fmt.Sprintf("0x7f10%08x", x.pid)
				addr := x.cl
				if addr == "" {
					addr = fmt.Sprintf("10.60.%d.%d", 20+i%5, 10+x.pid%200)
				}
				if x.app != "" {
					app = x.app
				}
				servers = append(servers, Row{"kind": "server", "database": k[0], "user": k[1], "state": "active", "application_name": x.app,
					"addr": "10.60.1.10", "port": 5432, "connect_time": read.Add(-3 * time.Hour).Format(time.RFC3339),
					"request_time": x.since.Format(time.RFC3339), "wait_us": int64(0), "ptr": sp, "link": cp, "remote_pid": x.pid})
				clients = append(clients, Row{"kind": "client", "database": k[0], "user": k[1], "state": "active", "application_name": x.app,
					"addr": addr, "port": 40000 + x.pid%20000, "connect_time": read.Add(-2 * time.Hour).Format(time.RFC3339),
					"request_time": x.since.Format(time.RFC3339), "wait_us": int64(0), "ptr": cp, "link": sp})
			}
			for i := 0; i < idle; i++ {
				// an idle server's backend is idle between transactions: no snapshot holds its pid
				servers = append(servers, Row{"kind": "server", "database": k[0], "user": k[1], "state": "idle",
					"addr": "10.60.1.10", "port": 5432, "connect_time": read.Add(-3 * time.Hour).Format(time.RFC3339),
					"request_time": read.Add(-time.Duration(3+i) * time.Second).Format(time.RFC3339), "wait_us": int64(0),
					"ptr": fmt.Sprintf("0x7f30%04x%04x", len(k[0])+len(k[1]), i), "remote_pid": 64000 + (len(k[0])*31+len(k[1])*7+i)%1000})
			}
			for i := 0; i < waiting; i++ {
				w := maxwait * float64(waiting-i) / float64(waiting)
				clients = append(clients, Row{"kind": "client", "database": k[0], "user": k[1], "state": "waiting", "application_name": app,
					"addr": fmt.Sprintf("10.60.%d.%d", 30+i%4, 50+i), "port": 41000 + i, "connect_time": read.Add(-time.Hour).Format(time.RFC3339),
					"request_time": read.Add(-time.Duration(w * float64(time.Second))).Format(time.RFC3339), "wait_us": int64(w * 1e6),
					"ptr": fmt.Sprintf("0x7f40%04x%04x", len(k[0]), i)})
			}
			read0 += len(in) + waiting + 12 // twelve idle clients counted, not kept
			payload = append(payload, Row{"kind": "pool", "database": k[0], "user": k[1], "cl_active": len(in), "cl_waiting": waiting,
				"sv_active": len(in), "sv_idle": idle, "sv_used": 0, "sv_tested": 0, "sv_login": 0, "maxwait_ms": maxwait * 1000,
				"pool_mode": "transaction", "pool_size": size[k], "pool_size_from": "database"})
		}
		for _, db := range sortedKeys(dbs) {
			payload = append(payload, Row{"kind": "stats", "database": db, "xact_rate": 40 + len(ss)*15, "query_rate": 120 + len(ss)*45,
				"avg_wait_us": 300, "avg_query_us": 2400, "total_xact_count": read.Unix() / 3, "total_query_count": read.Unix(),
				"total_wait_us": read.Unix() * 9})
		}
		sort.SliceStable(clients, func(i, j int) bool { return clients[i]["wait_us"].(int64) > clients[j]["wait_us"].(int64) })
		payload = append(payload, Row{"kind": "conns", "clients_read": read0, "clients_kept": len(clients), "servers_read": len(servers)})
		payload = append(payload, clients...)
		payload = append(payload, servers...)
		b, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_pgbouncer($1, $2, $3::jsonb)`, id, read, string(b)); err != nil {
			return fmt.Errorf("import_pgbouncer at %s: %w", read.Format(time.RFC3339), err)
		}
	}
	return nil
}

// demoPoolSize is the demo pooler's largest pool: small enough that a chain fills it.
const demoPoolSize = 4

func sortedKeys(m map[string]int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedPools(m map[[2]string]int) [][2]string {
	out := make([][2]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i][0]+"\x00"+out[i][1] < out[j][0]+"\x00"+out[j][1] })
	return out
}
