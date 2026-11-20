package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it): op 'settings' (ST5a) - a page instance's settings
// stored through import_admin_instance_settings (0263), serve's verdicts (the check, a bad shape) refused and audited
// by the import, an instance of the file refused, the view's parts.
func TestInstanceSettingsOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tag := time.Now().UnixNano() % 1000000000
	name := fmt.Sprintf("sset-pg-%d", tag)
	user := fmt.Sprintf("sset-user-%d", tag)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`, user)
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_instances (name, engine, dsn_ref, auth, host, created_by, updated_by)
	                             VALUES ($1, 'postgres', 'file:/nonexistent/sset', 'password', '192.0.2.8', $2, $2)`, name, user); err != nil {
		t.Fatal(err)
	}
	cfg := &PageSettingsConfig{FloorS: 60, Catalogue: map[string][]PageCollectionView{config.EnginePostgres: {{Name: "statements", DefaultS: 300, BuiltinS: 300}}},
		Check: func(engine string, ps config.PageSettings) error {
			if _, ok := ps.Schedules["statements2"]; ok {
				return errors.New(`unknown collection "statements2"`)
			}
			if engine != config.EnginePostgres {
				return errors.New("not the stored engine")
			}
			return nil
		}}
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: pool}}
	s.SetPageSettings(cfg)
	t.Cleanup(func() { pageSettingsOf.Delete(s) })
	write := func(target string, settings any) map[string]any {
		t.Helper()
		in := map[string]any{"op": "settings", "name": target}
		if settings != nil {
			in["settings"] = settings
		}
		pay := map[string]any{"op": "settings", "ui_user": user, "client": "192.0.2.7", "name": target, "file_names": []string{"sset-file"}}
		rec := httptest.NewRecorder()
		s.instanceSettings(rec, httptest.NewRequest(http.MethodPost, "/api/admin/instances", nil), user, in, pay)
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s: %s (%v)", target, rec.Body.String(), err)
		}
		return out
	}
	words := func(out map[string]any) string { return fmt.Sprint(out["outcome"]) + "|" + fmt.Sprint(out["detail"]) }
	// the panel sends numbers as JSON does (float64 once decoded): stored as whole seconds
	if got := write(name, map[string]any{"schedules": map[string]any{"statements": float64(60), "activity": float64(0)}, "query_text": "none"}); words(got) != "done|settings of "+name+" saved: activity off, statements every 60 s; query_text none" || got["takes_effect"] == nil {
		t.Errorf("a change: %v", got)
	}
	for _, c := range []struct {
		target   string
		settings any
		want     string
	}{
		{name, map[string]any{"schedules": map[string]any{"statements2": float64(60)}}, `refused|unknown collection "statements2"`},
		{name, map[string]any{"schedules": map[string]any{"statements": float64(1.5)}}, "refused|the settings do not parse: its settings in Admin > Instances give statements 1.5: not whole seconds from 0 (off) to 30 days"},
		{name, "every minute", "refused|settings must be an object"},
		{name, nil, "refused|settings must be an object"},
		{"sset-file", map[string]any{}, "refused|sset-file is an instance of pgvigil.yaml: its schedules:, disabled: and query_text: in the file are its settings"},
	} {
		if got := words(write(c.target, c.settings)); got != c.want {
			t.Errorf("%v: %s, want %s", c.settings, got, c.want)
		}
	}
	var refused int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_audit WHERE ui_user = $1 AND op = 'instance settings' AND outcome = 'refused'`, user).Scan(&refused); err != nil || refused != 5 {
		t.Errorf("refused audit rows: %d (%v), want 5 - serve's verdicts are audited too", refused, err)
	}
	// the view's parts
	out := map[string]any{}
	s.instanceSettingsView(ctx, out)
	b, _ := json.Marshal(out)
	if !strings.Contains(string(b), `"settings_floor_s":60`) || !strings.Contains(string(b), `"default_s":300`) || !strings.Contains(string(b), `"schedules\": {\"activity\": 0, \"statements\": 60}`) {
		t.Errorf("the view's parts: %s", b)
	}
	// a server that sets none (demo, mcp)
	pageSettingsOf.Delete(s)
	if got := words(write(name, map[string]any{})); got != "refused|this server does not set an instance's settings (pgvigil serve does)" {
		t.Errorf("no PageSettings: %s", got)
	}
}

// TestInstanceSettingsThresholdsOnAStore (ST5b): op 'settings' carries a SQL Server page instance's thresholds and
// paused intervals to 0266 and says when the thresholds take effect; 'expect' reaches the import, which refuses a write
// over a change made since; the dialogs' answer (collectionsSettingsParts) holds the page instance's source, stored
// settings, catalogue, floor, ceiling and why it cannot be written here, and says 'file' for a name not added here.
func TestInstanceSettingsThresholdsOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tag := time.Now().UnixNano() % 1000000000
	name := fmt.Sprintf("sthr-ms-%d", tag)
	user := fmt.Sprintf("sthr-user-%d", tag)
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, name)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_audit WHERE ui_user = $1`, user)
	}()
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.admin_instances (name, engine, dsn_ref, auth, host, created_by, updated_by)
	                             VALUES ($1, 'sqlserver', 'file:/nonexistent/sthr', 'sql', '192.0.2.8', $2, $2)`, name, user); err != nil {
		t.Fatal(err)
	}
	cfg := &PageSettingsConfig{FloorS: 60, Catalogue: map[string][]PageCollectionView{config.EngineSQLServer: {{Name: "mssql_jobs", DefaultS: 300, BuiltinS: 300},
		{Name: "mssql_running_plans", Box: true}}}, Thresholds: []PageThresholdView{{Name: "redo_queue_kb", Default: 512000}},
		Check: func(string, config.PageSettings) error { return nil }}
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: pool}}
	s.SetPageSettings(cfg)
	t.Cleanup(func() { pageSettingsOf.Delete(s) })
	write := func(settings, expect any) map[string]any {
		t.Helper()
		in := map[string]any{"op": "settings", "name": name, "settings": settings}
		if expect != nil {
			in["expect"] = expect
		}
		pay := map[string]any{"op": "settings", "ui_user": user, "client": "192.0.2.7", "name": name, "file_names": []string{"sthr-file"}}
		rec := httptest.NewRecorder()
		s.instanceSettings(rec, httptest.NewRequest(http.MethodPost, "/api/admin/instances", nil), user, in, pay)
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s (%v)", rec.Body.String(), err)
		}
		return out
	}
	set := map[string]any{"schedules": map[string]any{"mssql_jobs": float64(0)}, "paused": map[string]any{"mssql_jobs": float64(600)},
		"thresholds": map[string]any{"redo_queue_kb": float64(1024), "backup_exclude": []any{"tmp%"}}}
	got := write(set, map[string]any{})
	if fmt.Sprint(got["outcome"]) != "done" || !strings.Contains(fmt.Sprint(got["detail"]), "thresholds redo_queue_kb 1024; backup_exclude tmp%; paused mssql_jobs (its own 600 s kept)") ||
		!strings.HasSuffix(fmt.Sprint(got["takes_effect"]), "; its thresholds are stored at the instance's next HA/DR, jobs or backups read") {
		t.Errorf("thresholds and paused: %v", got)
	}
	if got := write(map[string]any{}, map[string]any{}); fmt.Sprint(got["outcome"])+"|"+fmt.Sprint(got["detail"]) != "refused|the settings of "+name+" changed since they were read: read them again" {
		t.Errorf("a stale expect: %v", got)
	}
	parts := s.collectionsSettingsParts(ctx, name, config.EngineSQLServer)
	b, _ := json.Marshal(parts)
	var p map[string]any
	_ = json.Unmarshal(b, &p)
	cat, _ := p["catalogue"].(map[string]any)
	box, _ := cat["mssql_running_plans"].(map[string]any)
	if p["source"] != "page" || !strings.Contains(string(b), `"redo_queue_kb":1024`) || box["box"] != true || p["settings_floor_s"] != float64(60) ||
		p["settings_ceiling_s"] != float64(2592000) || p["writable"] != false || !strings.HasPrefix(fmt.Sprint(p["why_not"]), "adding and changing instances needs the UI login") {
		t.Errorf("the dialogs' parts of a page instance: %s", b)
	}
	if p := s.collectionsSettingsParts(ctx, "sthr-none", config.EngineSQLServer); len(p) != 1 || p["source"] != "file" {
		t.Errorf("a name not added here: %v", p)
	}
	// the thresholds' words only where the save changed them - a schedule-only save keeping them has
	// none; a save that takes every threshold away waits for the same read and says so
	words := "its thresholds are stored at the instance's next HA/DR, jobs or backups read"
	keep := map[string]any{"schedules": map[string]any{"mssql_jobs": float64(600)}, "thresholds": set["thresholds"]}
	if got := write(keep, set); fmt.Sprint(got["outcome"]) != "done" || strings.Contains(fmt.Sprint(got["takes_effect"]), words) {
		t.Errorf("a schedule-only save: %v (want done, no thresholds words)", got)
	}
	gone := map[string]any{"schedules": map[string]any{"mssql_jobs": float64(600)}}
	if got := write(gone, keep); fmt.Sprint(got["outcome"]) != "done" || !strings.Contains(fmt.Sprint(got["takes_effect"]), words) {
		t.Errorf("a save that takes every threshold away: %v (want done, the thresholds words)", got)
	}
}
