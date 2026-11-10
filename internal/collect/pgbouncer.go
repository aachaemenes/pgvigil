package collect

import (
	"context"
	"fmt"
	"math/big"
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
// The console speaks the simple query protocol only, and takes no SET: the connection is opened with the simple
// protocol and without the collector's session setup (a pooler has no read-only transaction to set).
//
// Rows by kind:
//
//	state     status (ok | error), reason, version   (once)
//	pool      database, user, cl_active, cl_waiting, sv_active, sv_idle, sv_used, sv_tested, sv_login, maxwait_ms,
//	          pool_mode, pool_size (SHOW DATABASES' pool_size for the pool's database)
//	stats     database, xact_rate, query_rate (per second, PgBouncer's own averages over its stats_period),
//	          avg_wait_us, avg_query_us, total_xact_count, total_query_count, total_wait_us
//	database  name, host, port, database, pool_size, min_pool_size, reserve_pool, pool_mode, max_connections,
//	          current_connections, paused, disabled
//	config    key, value, changeable
//
// The console's own database 'pgbouncer' is left out of the pool, stats and database rows (it has no server pool).
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
var pgBouncerCommands = struct{ Version, Pools, Stats, Databases, Config string }{
	Version: "SHOW VERSION", Pools: "SHOW POOLS", Stats: "SHOW STATS", Databases: "SHOW DATABASES", Config: "SHOW CONFIG",
}

// pgBouncerTimeout bounds one read (connect and the five SHOWs).
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
	conn, err := pgx.ConnectConfig(ctx, cfg)
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
	conf, err := show(pgBouncerCommands.Config)
	if err != nil {
		return fail(err)
	}
	return pgBouncerRows(version, pools, stats, dbs, conf), nil
}

// pgBouncerRows shapes the four SHOW results into the collection's rows (a pure function: the test feeds it the
// columns of PgBouncer 1.18 to 1.24, whose names moved: reserve_pool / reserve_pool_size, maxwait_us since 1.8).
func pgBouncerRows(version any, pools, stats, dbs, conf []map[string]any) []Row {
	out := []Row{{"kind": "state", "status": "ok", "reason": nil, "version": version}}
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
		var maxwaitMS any
		if s, ok := bNum(p["maxwait"]); ok {
			us, _ := bNum(p["maxwait_us"])
			maxwaitMS = s*1000 + us/1000
		}
		out = append(out, Row{"kind": "pool", "database": db, "user": bText(p["user"]),
			"cl_active": bInt(p["cl_active"]), "cl_waiting": bInt(p["cl_waiting"]), "sv_active": bInt(p["sv_active"]),
			"sv_idle": bInt(p["sv_idle"]), "sv_used": bInt(p["sv_used"]), "sv_tested": bInt(p["sv_tested"]),
			"sv_login": bInt(p["sv_login"]), "maxwait_ms": maxwaitMS, "pool_mode": bText(p["pool_mode"]), "pool_size": poolSize[db]})
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
