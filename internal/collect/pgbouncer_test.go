package collect

import (
	"math/big"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// The collector sends SHOW commands only: every field of pgBouncerCommands, and no other literal command in the file.
func TestPgBouncerCommandsAreShowOnly(t *testing.T) {
	v := reflect.ValueOf(pgBouncerCommands)
	for i := 0; i < v.NumField(); i++ {
		if c := v.Field(i).String(); !strings.HasPrefix(c, "SHOW ") {
			t.Errorf("pgBouncerCommands.%s = %q: not a SHOW", v.Type().Field(i).Name, c)
		}
	}
	src, err := os.ReadFile("pgbouncer.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range regexp.MustCompile(`"(?i:(PAUSE|RESUME|RELOAD|KILL|SUSPEND|SHUTDOWN|DISABLE|ENABLE|RECONNECT|WAIT_CLOSE|SET)\b)[^"]*"`).FindAllString(string(src), -1) {
		t.Errorf("pgbouncer.go carries a console command that is not a SHOW: %s", m)
	}
}

func TestPgBouncerConfigured(t *testing.T) {
	c := pgBouncerCollector{}
	if ok, why := c.Configured(config.Instance{Name: "a", DSNRaw: "x"}); ok || why == "" {
		t.Errorf("no DSN: configured=%v why=%q, want false with a reason", ok, why)
	}
	if ok, _ := c.Configured(config.Instance{Name: "a", DSNRaw: "x", PgBouncerDSNRaw: "env:PGB"}); !ok {
		t.Error("a pgbouncer DSN: want configured")
	}
	if skip, _ := Gated(c, config.Instance{Name: "a", DSNRaw: "x", PgBouncerDSNRaw: "  "}); !skip {
		t.Error("a blank pgbouncer DSN: want gated off")
	}
}

func TestPgBouncerRows(t *testing.T) {
	num := func(n int64) pgtype.Numeric { return pgtype.Numeric{Int: big.NewInt(n), Valid: true} }
	pools := []map[string]any{
		{"database": "pgbouncer", "user": "pgbouncer", "cl_active": int64(1), "cl_waiting": int64(0)},
		{"database": "app", "user": "web", "cl_active": int64(5), "cl_waiting": int64(3), "sv_active": int64(2),
			"sv_idle": int64(0), "sv_used": int64(0), "sv_tested": int64(0), "sv_login": int64(0),
			"maxwait": int64(6), "maxwait_us": int64(250000), "pool_mode": "transaction"},
		{"database": "rep", "user": "r", "cl_active": "1", "cl_waiting": "0", "sv_active": "1", "maxwait": "0", "pool_mode": "session"}, // 1.18 as text
	}
	stats := []map[string]any{
		{"database": "app", "avg_xact_count": num(12), "avg_query_count": num(40), "avg_wait_time": num(1500),
			"avg_query_time": num(800), "total_xact_count": num(1000), "total_query_count": num(4000), "total_wait_time": num(90000)},
	}
	dbs := []map[string]any{
		{"name": "pgbouncer", "pool_size": int64(2)},
		{"name": "app", "host": "10.0.0.5", "port": int64(5432), "database": "appdb", "pool_size": int64(2),
			"min_pool_size": int64(0), "reserve_pool": int64(1), "pool_mode": "transaction", "max_connections": int64(0),
			"current_connections": int64(2), "paused": int64(0), "disabled": int64(0)},
		{"name": "rep", "pool_size": "20", "reserve_pool_size": "5", "paused": "1"},
	}
	conf := []map[string]any{{"key": "max_client_conn", "value": "100", "changeable": "yes"}, {"key": "listen_port", "value": "6432", "changeable": "no"}}
	// SHOW USERS as PgBouncer 1.24.1 prints it: web sets pool_size 4; r sets none and repeats the row above
	users := []map[string]any{{"name": "admin", "pool_size": nil}, {"name": "web", "pool_size": "        4"}, {"name": "r", "pool_size": "        4"}}
	rows := pgBouncerRows("PgBouncer 1.24.1", pools, stats, dbs, users, conf)

	by := map[string][]Row{}
	for _, r := range rows {
		k := r["kind"].(string)
		by[k] = append(by[k], r)
	}
	if len(by["state"]) != 1 || by["state"][0]["status"] != "ok" || by["state"][0]["version"] != "PgBouncer 1.24.1" {
		t.Errorf("state: %v", by["state"])
	}
	if len(by["pool"]) != 2 || len(by["database"]) != 2 || len(by["stats"]) != 1 || len(by["config"]) != 2 {
		t.Fatalf("counts: pool %d database %d stats %d config %d; want 2 2 1 2 (the console's own database left out)",
			len(by["pool"]), len(by["database"]), len(by["stats"]), len(by["config"]))
	}
	app := by["pool"][0]
	if app["database"] != "app" || app["cl_waiting"] != int64(3) || app["maxwait_ms"] != float64(6250) || app["pool_size"] != int64(4) || app["pool_size_from"] != "user" {
		t.Errorf("app pool: %v (want cl_waiting 3, maxwait_ms 6250, pool_size 4 from the user web's own size)", app)
	}
	rep := by["pool"][1]
	if rep["cl_active"] != int64(1) || rep["maxwait_ms"] != float64(0) || rep["pool_size"] != int64(20) || rep["pool_size_from"] != "database" {
		t.Errorf("rep pool (text columns; user r's repeated 4 is not its own, the database's 20 stands): %v", rep)
	}
	for _, r := range pgBouncerRows(nil, pools, nil, dbs, nil, nil) {
		if r["kind"] == "pool" && r["database"] == "app" && (r["pool_size"] != int64(2) || r["pool_size_from"] != "database") {
			t.Errorf("no SHOW USERS: want the database's size 2, got %v", r)
		}
	}
	if d := by["database"][1]; d["reserve_pool"] != int64(5) || d["paused"] != true || d["pool_size"] != int64(20) {
		t.Errorf("rep database (reserve_pool_size, paused 1): %v", d)
	}
	if s := by["stats"][0]; s["query_rate"] != int64(40) || s["avg_wait_us"] != int64(1500) || s["total_wait_us"] != int64(90000) {
		t.Errorf("stats from numeric: %v", s)
	}
	if c := by["config"]; c[0]["changeable"] != true || c[1]["changeable"] != false {
		t.Errorf("config changeable yes/no: %v", c)
	}
}

func TestBNum(t *testing.T) {
	cases := []struct {
		in   any
		want float64
		ok   bool
	}{
		{int64(7), 7, true}, {int32(7), 7, true}, {"12", 12, true}, {"x", 0, false}, {nil, 0, false},
		{pgtype.Numeric{Int: big.NewInt(15), Exp: -1, Valid: true}, 1.5, true},
		{pgtype.Numeric{Int: big.NewInt(3), Exp: 2, Valid: true}, 300, true},
		{pgtype.Numeric{}, 0, false},
	}
	for _, c := range cases {
		got, ok := bNum(c.in)
		if ok != c.ok || got != c.want {
			t.Errorf("bNum(%#v) = %v, %v; want %v, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

// SHOW CLIENTS and SHOW SERVERS (task 128): the console's own clients are left out, idle clients are counted and not
// kept, the longest wait comes first and is wait + wait_us, a server keeps its remote_pid, the timestamps come out as
// RFC 3339 whether the console sent text or a time, and the conns row counts what was read and kept.
func TestPgBouncerConnRows(t *testing.T) {
	clients := []map[string]any{
		{"database": "pgbouncer", "user": "mon", "state": "active"},
		{"database": "app", "user": "web", "state": "active", "application_name": "api", "addr": "10.0.0.5", "port": int64(53410),
			"connect_time": "2026-11-10 23:12:40 UTC", "request_time": "2026-11-10 23:12:40 UTC", "wait": int64(0), "wait_us": int64(0),
			"ptr": "0x1", "link": "0xs1"},
		{"database": "app", "user": "web", "state": "waiting", "application_name": "batch", "wait": "1", "wait_us": "250000", "ptr": "0x2", "link": ""},
		{"database": "app", "user": "web", "state": "waiting", "application_name": "api", "wait": int64(0), "wait_us": int64(15991), "ptr": "0x3"},
		{"database": "app", "user": "web", "state": "idle", "ptr": "0x4"},
	}
	servers := []map[string]any{
		{"database": "pgbouncer", "user": "pgbouncer", "state": "active", "remote_pid": int64(0)},
		{"database": "app", "user": "web", "state": "active", "application_name": "api", "remote_pid": int64(2017329), "ptr": "0xs1", "link": "0x1",
			"connect_time": time.Date(2026, 11, 10, 23, 12, 40, 0, time.UTC)},
	}
	rows := pgBouncerConnRows(clients, servers)
	if len(rows) != 5 {
		t.Fatalf("rows: %d, want 5 (conns, 3 clients, 1 server): %v", len(rows), rows)
	}
	if c := rows[0]; c["kind"] != "conns" || c["clients_read"] != 4 || c["clients_kept"] != 3 || c["servers_read"] != 1 {
		t.Errorf("conns row: %v", c)
	}
	if r := rows[1]; r["application_name"] != "batch" || r["wait_us"] != int64(1250000) || r["state"] != "waiting" {
		t.Errorf("first client (the longest wait): %v", r)
	}
	if r := rows[2]; r["wait_us"] != int64(15991) {
		t.Errorf("second client: %v", r)
	}
	if r := rows[3]; r["link"] != "0xs1" || r["connect_time"] != "2026-11-10T23:12:40Z" || r["port"] != int64(53410) {
		t.Errorf("the active client: %v", r)
	}
	if r := rows[4]; r["kind"] != "server" || r["remote_pid"] != int64(2017329) || r["connect_time"] != "2026-11-10T23:12:40Z" || r["link"] != "0x1" {
		t.Errorf("the server: %v", r)
	}
	if _, ok := rows[1]["remote_pid"]; ok {
		t.Error("a client row carries remote_pid (only a server's is the backend pid)")
	}
	if bTime("") != nil || bTime(nil) != nil {
		t.Error("a blank timestamp is not nil")
	}
}
