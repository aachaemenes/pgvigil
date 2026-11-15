package web

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// TestInstanceCloudWriteOnAStore (B24p task 5): the Cloud fieldset through serve's handler - an add with its block in
// one call (done: the row and the block; the view's page row carries it, no 'not used' note); a block whose target
// is not the instance's own host, a typed profile, an empty fieldset and the switch off are refused BEFORE anything is
// written (no row, no credential file); the explicit clear removes the block. Needs a migrated repository and its
// owner: PGVIGIL_REPO_TEST_DSN (skipped without it).
func TestInstanceCloudWriteOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	ok, bad, off := fmt.Sprintf("b24p-ok-%d", sfx), fmt.Sprintf("b24p-bad-%d", sfx), fmt.Sprintf("b24p-off-%d", sfx)
	defer func() {
		for _, n := range []string{ok, bad, off} {
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.admin_instances WHERE name = $1`, n)
			_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE name = $1`, n)
		}
	}()
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "pgvigil.yaml")
	s := &Server{pool: pool, log: discardLog(), actions: &Actions{audit: pool}}
	s.SetInstancesAdmin(InstancesAdmin{ConfigPath: cfgPath})
	defer instancesAdmins.Delete(s)
	config.SetPageCloud(config.Doors{PageCloudBlocks: true})
	defer config.SetPageCloud(config.Doors{})
	write := func(body map[string]any) *httptest.ResponseRecorder {
		b, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		var in map[string]any
		_ = json.Unmarshal(b, &in)
		s.instancesWrite(w, httptest.NewRequest(http.MethodPost, "/api/admin/instances", bytes.NewReader(b)), "b24p", in)
		return w
	}
	host := "db1.c9akciq32.us-east-2.rds.amazonaws.com"
	add := func(name, h string, cloud any) map[string]any {
		return map[string]any{"op": "add", "name": name, "engine": "postgres", "platform": "rds", "host": h, "port": "5432", "dbname": "postgres",
			"auth": "password", "login": "pgv", "password": "pw b24p", "cloud": cloud}
	}
	rows := func(name string) (int, int) {
		var a, c int
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instances WHERE name = $1`, name).Scan(&a)
		_ = pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.admin_instance_cloud WHERE name = $1`, name).Scan(&c)
		return a, c
	}
	files := func() int {
		es, _ := os.ReadDir(config.SecretDir(cfgPath))
		return len(es)
	}
	if w := write(add(ok, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}, "azure": nil})); w.Code != http.StatusOK {
		t.Fatalf("an add with its block: %d %s", w.Code, w.Body.String())
	}
	if a, c := rows(ok); a != 1 || c != 1 {
		t.Fatalf("after the add: %d row(s), %d block(s); want 1 and 1", a, c)
	}
	before := files()
	for _, c := range []struct {
		what  string
		body  map[string]any
		code  int
		words string
	}{
		{"another instance's host", add(bad, "db2.c9akciq32.us-east-2.rds.amazonaws.com", map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}}), http.StatusConflict, "db2.c9akciq32"},
		{"a CNAME", add(bad, "billing.corp.example", map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}}), http.StatusConflict, "not an RDS endpoint"},
		{"a typed profile", add(bad, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1", "profile": "prod"}}), http.StatusBadRequest, "no AWS profile"},
		{"a page key it does not take", add(bad, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1", "log_group": "/x"}}), http.StatusBadRequest, "log_group"},
		{"an empty fieldset", add(bad, host, map[string]any{"aws": nil, "azure": nil}), http.StatusBadRequest, "Clear"},
	} {
		w := write(c.body)
		if w.Code != c.code || !strings.Contains(w.Body.String(), c.words) {
			t.Errorf("%s: %d %s, want %d naming %q", c.what, w.Code, w.Body.String(), c.code, c.words)
		}
		if a, _ := rows(bad); a != 0 || files() != before {
			t.Errorf("%s: the refused add wrote %d row(s) and %d credential file(s)", c.what, a, files()-before)
		}
	}
	// the switch off: refused in its words, nothing written
	config.SetPageCloud(config.Doors{})
	if w := write(add(off, host, map[string]any{"aws": map[string]any{"region": "us-east-2", "db_instance": "db1"}})); w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "page_cloud_blocks") {
		t.Errorf("the switch off: %d %s", w.Code, w.Body.String())
	}
	if a, _ := rows(off); a != 0 {
		t.Error("the switch off: the add was written")
	}
	// the view: the block on its row, and the note while the switch is off (the collector will not use it)
	vw := httptest.NewRecorder()
	s.InstancesAdminView(vw, httptest.NewRequest(http.MethodGet, "/api/admin/instances", nil))
	var view struct {
		CloudBlocks struct {
			On    bool              `json:"on"`
			Notes map[string]string `json:"notes"`
		} `json:"cloud_blocks"`
	}
	if err := json.Unmarshal(vw.Body.Bytes(), &view); err != nil {
		t.Fatalf("the view: %d %s", vw.Code, vw.Body.String())
	}
	if view.CloudBlocks.On || !strings.Contains(view.CloudBlocks.Notes[ok], "page_cloud_blocks") || !strings.Contains(vw.Body.String(), `"db_instance"`) {
		t.Errorf("the view with the switch off: on %v, note %q (want the off words), the block on the row: %v", view.CloudBlocks.On, view.CloudBlocks.Notes[ok], strings.Contains(vw.Body.String(), `"db_instance"`))
	}
	// the explicit clear (allowed with the switch off)
	if w := write(map[string]any{"op": "cloud_clear", "name": ok}); w.Code != http.StatusOK {
		t.Fatalf("the clear: %d %s", w.Code, w.Body.String())
	}
	if _, c := rows(ok); c != 0 {
		t.Error("the clear left the block")
	}
}
