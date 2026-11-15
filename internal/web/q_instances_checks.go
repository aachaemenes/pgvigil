// Admin > Instances' 'Check all' (the ServiceConfig takes, ST1): the page tests every instance - the ones of
// pgvigil.yaml too - by its own fan-out of POST /api/admin/instances op 'test', and shows for each its last test, how
// long ago it was last collected and the collection that fails now.
//
//   - op 'test' with the name of an instance of the file (fileInstanceTest): one connection as the file's own dsn,
//     which serve resolves and never sends anywhere; the result is kept by its name (import_admin_file_test, 0261)
//     and audited as the page's own tests are.
//   - GET /api/admin/instances gains the part 'checks' (instanceChecks): one row per instance of the page and of the
//     file - its last test, its newest collection that ended ok with its age by the repository's clock, and, where a
//     collection's last run ended in an error, how many do and the newest one's name and note.
//
// The two calls into this file are the WIRING patch's (scripts/st12-wiring.patch: q_instances_admin.go is shared).

package web

import (
	"context"
	"net/http"
	"strings"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// fileInstance finds an instance of pgvigil.yaml by its name.
func (a *InstancesAdmin) fileInstance(name string) (config.Instance, bool) {
	for _, in := range a.File {
		if in.Name == name {
			return in, true
		}
	}
	return config.Instance{}, false
}

// engineOf is an instance's engine as the file means it (none named = PostgreSQL).
func engineOf(in config.Instance) string {
	if in.Engine == "" {
		return config.EnginePostgres
	}
	return in.Engine
}

// emptyFileDSN is what a test of a file instance says when its dsn resolves to nothing.
const emptyFileDSN = "the instance's dsn in pgvigil.yaml resolved to an empty string (an unset variable or an unreadable file)"

// fileInstanceTest is op 'test' for an instance of the file: true = the request was answered here. A request that
// types its own host or password, a name the file does not list and a name the page owns are instanceTest's.
func (s *Server) fileInstanceTest(w http.ResponseWriter, r *http.Request, user string, in map[string]any) bool {
	name := str(in, "name")
	a := s.instAdmin()
	fi, ok := a.fileInstance(name)
	if !ok || rawStr(in, "password") != "" || str(in, "host") != "" {
		return false
	}
	ctx := r.Context()
	if have, err := s.pageInstance(ctx, name); err != nil || have != nil {
		return false
	}
	okc, detail := false, emptyFileDSN
	if dsn := fi.DSN(); strings.TrimSpace(dsn) != "" {
		okc, detail = testConnection(ctx, engineOf(fi), dsn)
	}
	ans, _, err := s.callImport(ctx, "import_admin_file_test", map[string]any{"ui_user": user, "client": clientIP(r), "name": name,
		"ok": okc, "detail": detail, "file_names": a.fileNames()})
	kept := err == nil && ans.Outcome == "done"
	if !kept {
		s.log.Warn("admin instance: the file instance's test result was not kept", "name", name, "err", err, "detail", ans.Detail)
	}
	s.reply(w, r, map[string]any{"ok": okc, "detail": detail, "kept": kept}, nil)
	return true
}

// sqlInstanceChecks: $1 the file's instance names. One row per instance of the file and of the page: its last test
// (the file's from admin_file_tests, the page's from its own row), the newest collection that ended ok and its age in
// seconds by the repository's clock, and the collections whose last run ended in an error - how many, and the newest
// one's name, note and time. A skipped collection (a missing right) is not an error: the Rights read names it.
const sqlInstanceChecks = `
WITH n AS (
  SELECT f.name, 'file'::text AS source, t.tested_at, t.tested_ok, t.tested_detail
    FROM unnest($1::text[]) f(name)
    LEFT JOIN pgvigil.admin_file_tests t ON t.name = f.name
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.admin_instances a WHERE a.name = f.name)
  UNION ALL
  SELECT a.name, 'page', a.tested_at, a.tested_ok, a.tested_detail FROM pgvigil.admin_instances a
)
SELECT n.name, n.source, n.tested_at, n.tested_ok, n.tested_detail, i.instance_id, i.last_seen, ok.last_collected,
       extract(epoch FROM now() - ok.last_collected)::bigint AS collected_age_s,
       coalesce(f.failing_n, 0)::int AS failing_n, f.collection AS failing_collection, f.note AS failing_note, f.snapshot_at AS failing_at
  FROM n
  LEFT JOIN pgvigil.instances i ON i.name = n.name
  LEFT JOIN LATERAL (SELECT max(c.snapshot_at) AS last_collected FROM pgvigil.collection_dates c
                      WHERE c.instance_id = i.instance_id AND c.status = 'ok') ok ON true
  LEFT JOIN LATERAL (SELECT count(*) OVER () AS failing_n, c.collection, c.note, c.snapshot_at
                       FROM pgvigil.collection_dates c
                      WHERE c.instance_id = i.instance_id AND c.status = 'error'
                      ORDER BY c.snapshot_at DESC, c.collection LIMIT 1) f ON true
 ORDER BY n.source, n.name`

// instanceChecks adds the part 'checks' to the page's answer.
func (s *Server) instanceChecks(ctx context.Context, a *InstancesAdmin, out map[string]any) error {
	t, err := s.query(ctx, sqlInstanceChecks, a.fileNames())
	if err != nil {
		return err
	}
	out["checks"] = t
	return nil
}
