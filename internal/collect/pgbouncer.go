package collect

import (
	"context"
	"fmt"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// pgBouncerCollector is the per-minute read of a PgBouncer pooler in front of an instance (task 62), through its
// admin console: a separate `pgbouncer:` DSN in the instance's config (dbname=pgbouncer) as a stats_users login. The
// console of such a login answers SHOW only (PAUSE, RELOAD, KILL and the rest are refused by PgBouncer itself), and
// this collector sends nothing but the fixed SHOW list below (pgBouncerCommands; a test holds it to SHOW). An
// instance without the DSN is skipped before any connection (ConfigGate): no pooler rows, no Pooler tab, no finding.
//
// SHOW USERS is read for the per-user pool sizes; a console that refuses it leaves the database's sizes.
//
// The console speaks the simple query protocol only, and takes no SET: the connection is opened with the simple
// protocol and without the collector's session setup (a pooler has no read-only transaction to set).
//
// Rows by kind:
//
//	state     status (ok | error), reason, version   (once)
//	pool      database, user, cl_active, cl_waiting, sv_active, sv_idle, sv_used, sv_tested, sv_login, maxwait_ms,
//	          pool_mode, pool_size, pool_size_from (the user's own size from SHOW USERS where set, else SHOW DATABASES')
//	stats     database, xact_rate, query_rate (per second, PgBouncer's own averages over its stats_period),
//	          avg_wait_us, avg_query_us, total_xact_count, total_query_count, total_wait_us
//	database  name, host, port, database, pool_size, min_pool_size, reserve_pool, pool_mode, max_connections,
//	          current_connections, paused, disabled
//	config    key, value, changeable
//	client    database, user, state, application_name, addr, port, connect_time, request_time, wait_us, ptr, link
//	          (SHOW CLIENTS, task 128: who waits in the pooler, how long, from which application; link is the ptr of
//	          the server it is paired with)
//	server    the same columns from SHOW SERVERS, and remote_pid: the backend's pid in PostgreSQL, the bridge from a
//	          pooled client to pg_stat_activity, Running queries and the blocking chain
//	conns     clients_read, clients_kept, servers_read (once, where SHOW CLIENTS was read)
//
// The console's own database 'pgbouncer' is left out of the pool, stats, database, client and server rows (it has no
// server pool, and its clients are the console's own logins, this collector's among them).
//
// SHOW CLIENTS can list thousands of idle clients on a busy pooler: the clients kept are those not idle (active,
// waiting, a cancel request), the longest waits first, at most pgBouncerClientCap; the conns row says how many were
// read and kept. SHOW SERVERS is bounded by the pool sizes and kept whole up to the same cap. A console that refuses
// SHOW CLIENTS or SHOW SERVERS (an older PgBouncer, a narrowed login) leaves the pool rows as before and no conns row.
// A pooler that cannot be reached stores the state 'error' with the reason and a collector_error row (the collection
// log says partial), so the tab shows why it is stale.
type pgBouncerCollector struct{}

func init() { Register(pgBouncerCollector{}) }

func (pgBouncerCollector) Name() string                   { return "pgbouncer" }
func (pgBouncerCollector) DefaultInterval() time.Duration { return time.Minute }
func (pgBouncerCollector) Applies(platform.Info) (bool, string) {
	return true, ""
}

// Configured: the collection runs only where the instance names its pooler.
func (pgBouncerCollector) Configured(in config.Instance) (bool, string) {
	if strings.TrimSpace(in.PgBouncerDSNRaw) == "" {
		return false, "no pgbouncer: DSN for this instance"
	}
	return true, ""
}

func (pgBouncerCollector) Run(context.Context, *pgx.Conn, platform.Info) ([]Row, error) {
	return nil, fmt.Errorf("pgbouncer needs the instance config: %w", ErrSkip)
}

// pgBouncerCommands is every command the collector sends to the console: SHOW only.
var pgBouncerCommands = struct{ Version, Pools, Stats, Databases, Users, Config, Clients, Servers string }{
	Version: "SHOW VERSION", Pools: "SHOW POOLS", Stats: "SHOW STATS", Databases: "SHOW DATABASES", Users: "SHOW USERS", Config: "SHOW CONFIG",
	Clients: "SHOW CLIENTS", Servers: "SHOW SERVERS",
}

// pgBouncerClientCap bounds the client (and server) rows of one read.
const pgBouncerClientCap = 1000

// pgBouncerTimeout bounds one read (connect and the eight SHOWs).
const pgBouncerTimeout = 15 * time.Second

func (pgBouncerCollector) RunInstance(ctx context.Context, _ *pgx.Conn, _ platform.Info, in config.Instance, _ CursorFunc) ([]Row, error) {
	fail := func(err error) ([]Row, error) {
		msg := err.Error()
		return []Row{
			{"kind": "state", "status": "error", "reason": msg, "version": nil},
			{"kind": "collector_error", "source": "pgbouncer", "message": msg},
		}, nil
	}
	dsn := in.PgBouncerDSN()
	if dsn == "" {
		return fail(fmt.Errorf("pgbouncer DSN %q resolved to an empty string (unset variable or unreadable file)", in.PgBouncerDSNRaw))
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return fail(fmt.Errorf("pgbouncer DSN: %w", err))
	}
	cfg.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	if cfg.ConnectTimeout == 0 || cfg.ConnectTimeout > pgBouncerTimeout {
		cfg.ConnectTimeout = pgBouncerTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, pgBouncerTimeout)
	defer cancel()
	conn, err := connectCounted(ctx, in.Name, cfg)
	if err != nil {
		return fail(fmt.Errorf("connect to the pooler: %w", err))
	}
	defer func() { _ = conn.Close(context.Background()) }()

	show := func(cmd string) ([]map[string]any, error) {
		rows, err := conn.Query(ctx, cmd)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", cmd, err)
		}
		defer rows.Close()
		names := []string{}
		for _, f := range rows.FieldDescriptions() {
			names = append(names, f.Name)
		}
		var out []map[string]any
		for rows.Next() {
			vals, err := rows.Values()
			if err != nil {
				return nil, fmt.Errorf("%s: %w", cmd, err)
			}
			m := make(map[string]any, len(names))
			for i, n := range names {
				if i < len(vals) {
					m[n] = vals[i]
				}
			}
			out = append(out, m)
		}
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("%s: %w", cmd, err)
		}
		return out, nil
	}

	var version any
	if v, err := show(pgBouncerCommands.Version); err == nil && len(v) > 0 {
		version = bText(v[0]["version"])
	}
	pools, err := show(pgBouncerCommands.Pools)
	if err != nil {
		return fail(err)
	}
	stats, err := show(pgBouncerCommands.Stats)
	if err != nil {
		return fail(err)
	}
	dbs, err := show(pgBouncerCommands.Databases)
	if err != nil {
		return fail(err)
	}
	users, err := show(pgBouncerCommands.Users)
	if err != nil {
		users = nil // the per-user size is a refinement: without it the database's size stands
	}
	conf, err := show(pgBouncerCommands.Config)
	if err != nil {
		return fail(err)
	}
	out := pgBouncerRows(version, pools, stats, dbs, users, conf)
	clients, cerr := show(pgBouncerCommands.Clients)
	servers, serr := show(pgBouncerCommands.Servers)
	if cerr == nil && serr == nil {
		out = append(out, pgBouncerConnRows(clients, servers, time.Now())...)
	}
	return out, nil
}

// pgBouncerConnRows shapes SHOW CLIENTS and SHOW SERVERS (task 128). The columns by version: wait and wait_us (the
// seconds and the microsecond part of the current wait) since 1.8, application_name since 1.12, remote_pid on a
// server row the backend's pid. A client's state on 1.21+ is active, waiting, idle, active_cancel_req or
// waiting_cancel_req; older ones say active for an idle client, so on those every client is kept up to the cap.
//
// The cap keeps first the clients paired with a server (link set: at most as many as the servers; they name the
// application each server serves), then the longest waits, then the oldest requests.
//
// connect_time and request_time are text in the POOLER HOST's local time with its zone abbreviation
// ('2026-11-10 15:12:40 PST'; PgBouncer's admin.c formats them through localtime, and writes now for a time never
// set), which time.Parse cannot place (an abbreviation it does not know reads as offset zero). The offset comes from
// the pooler's own clock instead: the console's newest request is this collector's own SHOW CLIENTS, made at now, so
// now minus its wall-clock time, rounded to 15 minutes, is the pooler's offset from UTC. Without that row (or a
// reading more than 5 minutes off a 15-minute step) the times are stored only where the zone says UTC or GMT, else nil.
func pgBouncerConnRows(clients, servers []map[string]any, now time.Time) []Row {
	offset, known := time.Duration(0), false
	var newest time.Time
	for _, c := range clients {
		if bText(c["database"]) != "pgbouncer" {
			continue
		}
		if w, _, ok := bWall(c["request_time"]); ok && w.After(newest) {
			newest = w
		}
	}
	if !newest.IsZero() {
		d := now.UTC().Sub(newest)
		r := d.Round(15 * time.Minute)
		if diff := d - r; diff < 5*time.Minute && diff > -5*time.Minute {
			offset, known = r, true
		}
	}
	at := func(v any) any {
		w, zone, ok := bWall(v)
		if !ok {
			return nil
		}
		switch {
		case known:
			return w.Add(offset).Format(time.RFC3339)
		case zone == "UTC" || zone == "GMT" || zone == "Z":
			return w.Format(time.RFC3339)
		}
		return nil
	}
	conn := func(kind string, c map[string]any) Row {
		var wait any
		if s, ok := bNum(c["wait"]); ok {
			us, _ := bNum(c["wait_us"])
			wait = int64(s*1e6 + us)
		}
		r := Row{"kind": kind, "database": bText(c["database"]), "user": bText(c["user"]), "state": bText(c["state"]),
			"application_name": bText(c["application_name"]), "addr": bText(c["addr"]), "port": bInt(c["port"]),
			"connect_time": at(c["connect_time"]), "request_time": at(c["request_time"]), "wait_us": wait,
			"ptr": bText(c["ptr"]), "link": bText(c["link"])}
		if kind == "server" {
			r["remote_pid"] = bInt(c["remote_pid"])
		}
		return r
	}
	var kept []Row
	read := 0
	for _, c := range clients {
		if bText(c["database"]) == "pgbouncer" {
			continue
		}
		read++
		if bText(c["state"]) == "idle" {
			continue
		}
		kept = append(kept, conn("client", c))
	}
	linked := func(r Row) bool { l, _ := r["link"].(string); return strings.TrimSpace(l) != "" }
	wt := func(r Row) int64 { v, _ := r["wait_us"].(int64); return v }
	req := func(r Row) string { v, _ := r["request_time"].(string); return v }
	sort.SliceStable(kept, func(i, j int) bool {
		if a, b := linked(kept[i]), linked(kept[j]); a != b {
			return a
		}
		if a, b := wt(kept[i]), wt(kept[j]); a != b {
			return a > b
		}
		return req(kept[i]) < req(kept[j])
	})
	if len(kept) > pgBouncerClientCap {
		kept = kept[:pgBouncerClientCap]
	}
	var srv []Row
	sread := 0
	for _, c := range servers {
		if bText(c["database"]) == "pgbouncer" {
			continue
		}
		sread++
		if len(srv) < pgBouncerClientCap {
			srv = append(srv, conn("server", c))
		}
	}
	out := []Row{{"kind": "conns", "clients_read": read, "clients_kept": len(kept), "servers_read": sread}}
	out = append(out, kept...)
	return append(out, srv...)
}

// bWall reads a console timestamp's wall clock (as if UTC) and its zone text: '2026-11-10 15:12:40 PST' gives
// 15:12:40 and 'PST'. A time.Time (a console that sends a typed value) is taken as it is, its zone 'Z'.
func bWall(v any) (time.Time, string, bool) {
	if t, ok := v.(time.Time); ok {
		if t.IsZero() {
			return time.Time{}, "", false
		}
		return t.UTC(), "Z", true
	}
	s, _ := bText(v).(string)
	s = strings.TrimSpace(s)
	if len(s) < 19 {
		return time.Time{}, "", false
	}
	t, err := time.Parse("2006-01-02 15:04:05", s[:19])
	if err != nil {
		return time.Time{}, "", false
	}
	return t, strings.TrimSpace(s[19:]), true
}

// pgBouncerRows shapes the SHOW results into the collection's rows (a pure function: the test feeds it the columns
// of PgBouncer 1.18 to 1.24, whose names moved: reserve_pool / reserve_pool_size, maxwait_us since 1.8).
//
// A pool's size: the user's own pool_size where the [users] section sets one (PgBouncer 1.17+; measured on 1.24.1, a
// user's pool_size wins over both default_pool_size and the database's pool_size), else the database's (SHOW
// DATABASES, which shows default_pool_size where the database sets none). SHOW USERS on 1.24.1 repeats the previous
// row's pool_size on a user that sets none (measured: users aaa unset, bbb = 3, ccc unset read blank, 3, 3), so a
// user's value counts only where it differs from the row above it; two users in a row with the same size read as
// the database's. pool_size_from says which ('user' | 'database').
func pgBouncerRows(version any, pools, stats, dbs, users, conf []map[string]any) []Row {
	out := []Row{{"kind": "state", "status": "ok", "reason": nil, "version": version}}
	userSize := map[string]any{}
	var prev any
	for _, u := range users {
		name, _ := bText(u["name"]).(string)
		v := bInt(u["pool_size"])
		if v != nil && v != prev && name != "" {
			userSize[name] = v
		}
		prev = v
	}
	poolSize := map[string]any{}
	for _, d := range dbs {
		name, _ := bText(d["name"]).(string)
		if name == "pgbouncer" {
			continue
		}
		reserve := d["reserve_pool"]
		if reserve == nil {
			reserve = d["reserve_pool_size"]
		}
		ps := bInt(d["pool_size"])
		poolSize[name] = ps
		out = append(out, Row{"kind": "database", "name": name, "host": bText(d["host"]), "port": bInt(d["port"]),
			"database": bText(d["database"]), "pool_size": ps, "min_pool_size": bInt(d["min_pool_size"]),
			"reserve_pool": bInt(reserve), "pool_mode": bText(d["pool_mode"]), "max_connections": bInt(d["max_connections"]),
			"current_connections": bInt(d["current_connections"]), "paused": bBool(d["paused"]), "disabled": bBool(d["disabled"])})
	}
	for _, p := range pools {
		db, _ := bText(p["database"]).(string)
		if db == "pgbouncer" {
			continue
		}
		size, from := poolSize[db], "database"
		if us, ok := userSize[fmt.Sprint(bText(p["user"]))]; ok {
			size, from = us, "user"
		}
		var maxwaitMS any
		if s, ok := bNum(p["maxwait"]); ok {
			us, _ := bNum(p["maxwait_us"])
			maxwaitMS = s*1000 + us/1000
		}
		out = append(out, Row{"kind": "pool", "database": db, "user": bText(p["user"]),
			"cl_active": bInt(p["cl_active"]), "cl_waiting": bInt(p["cl_waiting"]), "sv_active": bInt(p["sv_active"]),
			"sv_idle": bInt(p["sv_idle"]), "sv_used": bInt(p["sv_used"]), "sv_tested": bInt(p["sv_tested"]),
			"sv_login": bInt(p["sv_login"]), "maxwait_ms": maxwaitMS, "pool_mode": bText(p["pool_mode"]), "pool_size": size, "pool_size_from": from})
	}
	for _, s := range stats {
		db := bText(s["database"])
		if db == "pgbouncer" {
			continue
		}
		out = append(out, Row{"kind": "stats", "database": db, "xact_rate": bInt(s["avg_xact_count"]),
			"query_rate": bInt(s["avg_query_count"]), "avg_wait_us": bInt(s["avg_wait_time"]), "avg_query_us": bInt(s["avg_query_time"]),
			"total_xact_count": bInt(s["total_xact_count"]), "total_query_count": bInt(s["total_query_count"]),
			"total_wait_us": bInt(s["total_wait_time"])})
	}
	for _, c := range conf {
		key := bText(c["key"])
		if key == nil {
			continue
		}
		out = append(out, Row{"kind": "config", "key": key, "value": bText(c["value"]), "changeable": bBool(c["changeable"])})
	}
	return out
}

// bNum reads a console value as a number: the console's columns are int8, int4, numeric or text by version.
func bNum(v any) (float64, bool) {
	switch x := v.(type) {
	case int64:
		return float64(x), true
	case int32:
		return float64(x), true
	case int16:
		return float64(x), true
	case int:
		return float64(x), true
	case float64:
		return x, true
	case float32:
		return float64(x), true
	case pgtype.Numeric:
		if !x.Valid || x.Int == nil {
			return 0, false
		}
		f, _ := new(big.Float).SetInt(x.Int).Float64()
		for e := x.Exp; e > 0; e-- {
			f *= 10
		}
		for e := x.Exp; e < 0; e++ {
			f /= 10
		}
		return f, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		return f, err == nil
	case []byte:
		return bNum(string(x))
	}
	return 0, false
}

// bInt: a whole number, or nil when the column is absent or not a number.
func bInt(v any) any {
	f, ok := bNum(v)
	if !ok {
		return nil
	}
	return int64(f)
}

// bText: a text value, or nil.
func bText(v any) any {
	switch x := v.(type) {
	case nil:
		return nil
	case string:
		return x
	case []byte:
		return string(x)
	}
	return fmt.Sprint(v)
}

// bBool: the console writes booleans as 0/1 (paused, disabled) or yes/no (changeable).
func bBool(v any) any {
	switch x := v.(type) {
	case nil:
		return nil
	case bool:
		return x
	}
	if f, ok := bNum(v); ok {
		return f != 0
	}
	switch strings.ToLower(strings.TrimSpace(fmt.Sprint(bText(v)))) {
	case "yes", "true", "on", "t":
		return true
	case "no", "false", "off", "f":
		return false
	}
	return nil
}
