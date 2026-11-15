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
