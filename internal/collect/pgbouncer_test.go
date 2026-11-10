package collect

import (
	"math/big"
	"os"
	"reflect"
	"regexp"
	"strings"
	"testing"

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
	rows := pgBouncerRows("PgBouncer 1.24.1", pools, stats, dbs, conf)

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
	if app["database"] != "app" || app["cl_waiting"] != int64(3) || app["maxwait_ms"] != float64(6250) || app["pool_size"] != int64(2) {
		t.Errorf("app pool: %v (want cl_waiting 3, maxwait_ms 6250, pool_size 2 from SHOW DATABASES)", app)
	}
	rep := by["pool"][1]
	if rep["cl_active"] != int64(1) || rep["maxwait_ms"] != float64(0) || rep["pool_size"] != int64(20) {
		t.Errorf("rep pool (text columns): %v", rep)
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
