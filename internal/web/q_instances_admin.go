// Admin > Instances (task 204; task 103 part 1): instances added, edited, disabled, removed and tested in the page,
// and the sync sources whose servers come in as proposals a click approves or ignores.
//
//	GET  /api/admin/instances            the file's instances (read-only), the page's, the sources, the proposals,
//	                                     the last 200 audit rows and the inventory generation
//	POST /api/admin/instances            op add | edit | disable | enable | remove | test
//	POST /api/admin/sources              op add | remove | enable | disable | sync
//	POST /api/admin/proposals            op approve | ignore | unignore
//
// Every write needs the UI login and the X-Pgvigil header and goes through an import_ function on the actions
// door's audit login (0122), which audits it, refused attempts included. A credential is written by this file to
// its own file under the config folder (config.WriteSecret) before the row that names it, and is never sent back:
// the API answers whether an instance has one, never what it holds. The collector takes a change within 15 s
// (config.WatchInventory) without a restart.
//
// RunInstanceSync (serve, every 30 s) reads each enabled source whose interval is up: a CMS
// (msdb.dbo.sysmanagement_shared_registered_servers and _groups, the groups as tags group:<name>), a DBA Dash
// repository's dbo.Instances, a server list, a pg_service.conf or a CSV, into the proposals (import_admin_proposals).
package web

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// InstancesAdmin is what serve hands the page: where the config lives (the credential files go beside it), the
// file's instances (shown read-only, their names refused on a write) and the DBA Dash repositories a source may name.
type InstancesAdmin struct {
	ConfigPath string
	File       []config.Instance
	// DBADash maps a dbadash: repository's name in pgvigil.yaml to its connection string's reference (env:/file:).
	DBADash map[string]string
}

var instancesAdmins sync.Map // *Server -> *InstancesAdmin

// SetInstancesAdmin gives the server the page's settings (serve calls it after Open).
func (s *Server) SetInstancesAdmin(a InstancesAdmin) { instancesAdmins.Store(s, &a) }

func (s *Server) instAdmin() *InstancesAdmin {
	if v, ok := instancesAdmins.Load(s); ok {
		return v.(*InstancesAdmin)
	}
	return &InstancesAdmin{}
}

func (a *InstancesAdmin) secretDir() string {
	if a.ConfigPath == "" {
		return ""
	}
	return config.SecretDir(a.ConfigPath)
}

func (a *InstancesAdmin) fileNames() []string {
	out := []string{}
	for _, in := range a.File {
		out = append(out, in.Name)
	}
	return out
}

// resolveRef reads a credential reference: file: and env: through config.Resolve, dpapi: through DPAPI.
func resolveRef(ref string) (string, error) {
	if p, ok := strings.CutPrefix(ref, "dpapi:"); ok {
		return config.ResolveDPAPI(p)
	}
	v := config.Resolve(ref)
	if strings.TrimSpace(v) == "" {
		return "", fmt.Errorf("the credential reference %s reads empty (a missing file or variable)", refShown(ref))
	}
	return v, nil
}

// refShown names a reference by its kind and file name only (no folder): enough to find it, nothing of its content.
func refShown(ref string) string {
	k, p, ok := strings.Cut(ref, ":")
	if !ok {
		return "(not a reference)"
	}
	if k == "env" {
		return ref
	}
	return k + ":" + filepath.Base(p)
}

// InstancesAdminView is GET /api/admin/instances.
func (s *Server) InstancesAdminView(w http.ResponseWriter, r *http.Request) {
	a := s.instAdmin()
	ctx := r.Context()
	file := &table{Columns: []string{"name", "engine", "platform", "tags", "source"}, Rows: [][]any{}}
	for _, in := range a.File {
		plat := in.Platform
		if plat == "" {
			plat = "auto"
		}
		file.Rows = append(file.Rows, []any{in.Name, in.Engine, plat, strings.Join(in.Tags, " "), "from the file"})
	}
	out := map[string]any{"file": file, "secret_dir": a.secretDir(), "dbadash": keys(a.DBADash), "writable": s.ackOff() == "", "why_not": s.ackOff()}
	parts := []struct{ k, q string }{
		{"page", `SELECT a.name, a.engine, a.platform, a.auth, a.host, a.port, a.dbname, a.login, array_to_string(a.tags, ' ') AS tags,
		        a.disabled, a.source, a.dsn_ref IS NOT NULL AS has_credential, a.created_at, a.created_by, a.updated_at, a.updated_by,
		        a.tested_at, a.tested_ok, a.tested_detail, i.instance_id, i.last_seen,
		        (SELECT max(c.snapshot_at) FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id AND c.status = 'ok') AS last_collected
		   FROM pgvigil.admin_instances a LEFT JOIN pgvigil.instances i ON i.name = a.name ORDER BY a.name`},
		{"sources", `SELECT name, kind, CASE WHEN kind = 'cms' THEN 'the CMS login''s credential file' ELSE ref END AS ref, credential_ref IS NOT NULL AS has_credential,
		        auth, every_s, enabled, last_run, last_ok, last_error, last_count, created_at, created_by FROM pgvigil.admin_sources ORDER BY name`},
		{"proposals", `SELECT proposal_id, source, server, engine, host, port, dbname, display_name, array_to_string(tags, ' ') AS tags, state, gone,
		        first_seen, last_seen, gone_at, decided_at, decided_by, instance_name
		   FROM pgvigil.admin_proposals ORDER BY gone, CASE state WHEN 'proposed' THEN 0 WHEN 'approved' THEN 1 ELSE 2 END, source, server`},
		{"audit", `SELECT at, ui_user, client, op, target, outcome, detail FROM pgvigil.admin_audit ORDER BY audit_id DESC LIMIT 200`},
	}
	for _, p := range parts {
		t, err := s.query(ctx, p.q)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("%s: %w", p.k, err))
			return
		}
		out[p.k] = t
	}
	var gen int64
	if err := s.pool.QueryRow(ctx, `SELECT pgvigil.admin_inventory_generation()`).Scan(&gen); err != nil {
		s.reply(w, r, nil, err)
		return
	}
	out["generation"] = gen
	s.reply(w, r, out, nil)
}

func keys(m map[string]string) []string {
	out := []string{}
	for k := range m {
		out = append(out, k)
	}
	return out
}

// adminBody is the writes' common door: the header, the actions door, the login, a body of 16 KB at most.
func (s *Server) adminBody(w http.ResponseWriter, r *http.Request) (string, map[string]any, bool) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return "", nil, false
	}
	if why := s.ackOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(strings.Replace(why, "acknowledgements", "instance changes", 1)))
		return "", nil, false
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return "", nil, false
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 16385))
	if err != nil || len(raw) > 16384 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 16 KB"))
		return "", nil, false
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return "", nil, false
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return "", nil, false
	}
	return user, in, true
}

func str(in map[string]any, k string) string {
	switch v := in[k].(type) {
	case string:
		return strings.TrimSpace(v)
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(v)
	}
	return ""
}

// rawStr is a value as sent (a password keeps its spaces).
func rawStr(in map[string]any, k string) string {
	if v, ok := in[k].(string); ok {
		return v
	}
	return ""
}

func tagsOf(in map[string]any) []string {
	out := []string{}
	switch v := in["tags"].(type) {
	case string:
		out = append(out, strings.Fields(v)...)
	case []any:
		for _, x := range v {
			if t, ok := x.(string); ok && strings.TrimSpace(t) != "" {
				out = append(out, strings.TrimSpace(t))
			}
		}
	}
	return out
}

type importAnswer struct {
	Outcome string `json:"outcome"`
	Detail  string `json:"detail"`
}

// callImport runs one import_admin_* function on the audit login and answers its outcome.
func (s *Server) callImport(ctx context.Context, fn string, pay map[string]any) (importAnswer, json.RawMessage, error) {
	b, _ := json.Marshal(pay)
	var out []byte
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer cancel()
	if err := s.actions.audit.QueryRow(wctx, fmt.Sprintf(`SELECT pgvigil.%s($1, $2::jsonb)::text`, fn), time.Now(), string(b)).Scan(&out); err != nil {
		return importAnswer{}, nil, err
	}
	var a importAnswer
	if err := json.Unmarshal(out, &a); err != nil {
		return importAnswer{}, nil, fmt.Errorf("%s answered %q", fn, out)
	}
	return a, out, nil
}

func (s *Server) answer(w http.ResponseWriter, a importAnswer, raw json.RawMessage, extra map[string]any) {
	code := http.StatusOK
	if a.Outcome != "done" {
		code = http.StatusConflict
	}
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	for k, v := range extra {
		out[k] = v
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(out)
}

// pageRow is what the writes read back of a page instance.
type pageRow struct {
	Engine, Platform, Ref, Auth, Host string
	Port                              *int
	DBName, Login                     *string
	Tags                              []string
}

func (s *Server) pageInstance(ctx context.Context, name string) (*pageRow, error) {
	var p pageRow
	err := s.pool.QueryRow(ctx, `SELECT engine, platform, dsn_ref, auth, host, port, dbname, login, tags FROM pgvigil.admin_instances WHERE name = $1`, name).
		Scan(&p.Engine, &p.Platform, &p.Ref, &p.Auth, &p.Host, &p.Port, &p.DBName, &p.Login, &p.Tags)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &p, err
}

func orZero[T any](p *T) (v T) {
	if p != nil {
		v = *p
	}
	return v
}

// InstancesAdminWrite is POST /api/admin/instances.
func (s *Server) InstancesAdminWrite(w http.ResponseWriter, r *http.Request) {
	user, in, ok := s.adminBody(w, r)
	if !ok {
		return
	}
	a := s.instAdmin()
	ctx := r.Context()
	op, name := str(in, "op"), str(in, "name")
	pay := map[string]any{"op": op, "ui_user": user, "client": clientIP(r), "name": name, "file_names": a.fileNames()}
	if op == "test" {
		s.instanceTest(w, r, user, in)
		return
	}
	dir := a.secretDir()
	if dir == "" && (op == "add" || op == "edit") {
		writeErr(w, http.StatusConflict, errors.New("this server was started without a config file path: credentials cannot be written"))
		return
	}
	have, err := s.pageInstance(ctx, name)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	var restore func() // puts the credential file back as it was when the row is refused
	switch op {
	case "add", "edit":
		port := 0
		if p := str(in, "port"); p != "" {
			if port, err = strconv.Atoi(p); err != nil {
				writeErr(w, http.StatusBadRequest, fmt.Errorf("port %q is not a number", p))
				return
			}
		}
		c := config.Conn{Engine: str(in, "engine"), Auth: str(in, "auth"), Host: str(in, "host"), Port: port, DBName: str(in, "dbname"),
			Login: str(in, "login"), Password: rawStr(in, "password"), Extra: str(in, "options")}
		if op == "edit" && have != nil {
			c.Engine = have.Engine
		}
		pay["engine"], pay["platform"], pay["auth"], pay["host"], pay["port"], pay["dbname"], pay["login"], pay["tags"] =
			c.Engine, str(in, "platform"), c.Auth, c.Host, str(in, "port"), c.DBName, c.Login, tagsOf(in)
		needsPw := c.Auth == "sql" || c.Auth == "entra" || c.Auth == "password"
		if op == "edit" && have != nil && c.Password == "" && needsPw {
			// a tags or platform edit keeps the credential file; a change of the connection asks for the password again
			if c.Host != have.Host || port != orZero(have.Port) || c.DBName != orZero(have.DBName) || c.Login != orZero(have.Login) || c.Auth != have.Auth || c.Extra != "" {
				writeErr(w, http.StatusConflict, errors.New("the connection changed: give the password again (it is never read back from its file)"))
				return
			}
			pay["dsn_ref"] = have.Ref
			break
		}
		if op == "add" && have != nil {
			pay["dsn_ref"] = "file:/refused" // the function refuses the name; nothing is written
			break
		}
		if op == "add" && slicesContains(a.fileNames(), name) {
			pay["dsn_ref"] = "file:/refused"
			break
		}
		dsn, err := config.BuildDSN(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		var old []byte
		var oldRef string
		if have != nil {
			oldRef = have.Ref
			if p, ok := strings.CutPrefix(have.Ref, "file:"); ok {
				old, _ = os.ReadFile(p)
			} else if p, ok := strings.CutPrefix(have.Ref, "dpapi:"); ok {
				old, _ = os.ReadFile(p)
			}
		}
		ref, err := config.WriteSecret(dir, name, dsn)
		if err != nil {
			writeErr(w, http.StatusConflict, fmt.Errorf("the credential file: %w", err))
			return
		}
		pay["dsn_ref"] = ref
		restore = func() {
			if old != nil && oldRef == ref {
				_, p, _ := strings.Cut(ref, ":")
				_ = os.WriteFile(p, old, 0o600)
				return
			}
			_ = config.RemoveSecret(dir, ref)
		}
	case "disable", "enable", "remove":
	default:
		writeErr(w, http.StatusBadRequest, errors.New("op is add, edit, disable, enable, remove or test"))
		return
	}
	ans, raw, err := s.callImport(ctx, "import_admin_instance", pay)
	if err != nil {
		if restore != nil {
			restore()
		}
		s.log.Error("admin instance: not written", "user", user, "op", op, "name", name, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if ans.Outcome != "done" && restore != nil {
		restore()
	}
	if ans.Outcome == "done" && op == "remove" && have != nil {
		if err := config.RemoveSecret(a.secretDir(), have.Ref); err != nil {
			s.log.Warn("admin instance: the credential file stays", "name", name, "err", err)
		}
	}
	s.log.Info("admin instance", "op", op, "name", name, "user", user, "outcome", ans.Outcome, "detail", ans.Detail)
	s.answer(w, ans, raw, nil)
}

func slicesContains(l []string, v string) bool {
	for _, x := range l {
		if x == v {
			return true
		}
	}
	return false
}

// instanceTest connects with a page instance's own file (name) or with the form's values (nothing written) and
// says what answered; a page instance's result is kept on its row (audited).
func (s *Server) instanceTest(w http.ResponseWriter, r *http.Request, user string, in map[string]any) {
	ctx := r.Context()
	name := str(in, "name")
	var engine, dsn string
	have, err := s.pageInstance(ctx, name)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	stored := have != nil && rawStr(in, "password") == "" && str(in, "host") == ""
	if stored {
		engine = have.Engine
		if dsn, err = resolveRef(have.Ref); err != nil {
			writeErr(w, http.StatusConflict, err)
			return
		}
	} else {
		port, _ := strconv.Atoi(str(in, "port"))
		c := config.Conn{Engine: str(in, "engine"), Auth: str(in, "auth"), Host: str(in, "host"), Port: port, DBName: str(in, "dbname"),
			Login: str(in, "login"), Password: rawStr(in, "password"), Extra: str(in, "options")}
		engine = c.Engine
		if dsn, err = config.BuildDSN(c); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
	}
	okc, detail := testConnection(ctx, engine, dsn)
	out := map[string]any{"ok": okc, "detail": detail}
	if stored {
		ans, _, err := s.callImport(ctx, "import_admin_instance", map[string]any{"op": "tested", "ui_user": user, "client": clientIP(r), "name": name, "ok": okc, "detail": detail})
		if err != nil || ans.Outcome != "done" {
			s.log.Warn("admin instance: the test result was not kept", "name", name, "err", err, "detail", ans.Detail)
		}
	}
	s.reply(w, r, out, nil)
}

// testConnection opens one connection (10 s) and reads who answered.
func testConnection(ctx context.Context, engine, dsn string) (bool, string) {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	switch engine {
	case config.EngineSQLServer:
		db, err := sql.Open("sqlserver", mssqlApp(dsn, "pgvigil-admin-test"))
		if err != nil {
			return false, "the connection string: " + err.Error()
		}
		defer db.Close()
		var srv, ver, login string
		if err := db.QueryRowContext(cctx, `SELECT CAST(@@SERVERNAME AS nvarchar(256)), CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)), SUSER_SNAME()`).Scan(&srv, &ver, &login); err != nil {
			return false, err.Error()
		}
		return true, fmt.Sprintf("connected: %s, SQL Server %s, as %s", srv, ver, login)
	case config.EnginePostgres:
		conn, err := pgx.Connect(cctx, dsn)
		if err != nil {
			return false, err.Error()
		}
		defer conn.Close(context.Background())
		var ver, login string
		if err := conn.QueryRow(cctx, `SELECT current_setting('server_version'), current_user`).Scan(&ver, &login); err != nil {
			return false, err.Error()
		}
		return true, fmt.Sprintf("connected: PostgreSQL %s, as %s", ver, login)
	}
	return false, "unknown engine " + engine
}

// sourceCred is a source's credential file's content: what an approved server connects with.
type sourceCred struct {
	Login    string `json:"login"`
	Password string `json:"password"`
	Extra    string `json:"extra"`
}

var srcName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,50}$`)

// SourcesAdminWrite is POST /api/admin/sources.
func (s *Server) SourcesAdminWrite(w http.ResponseWriter, r *http.Request) {
	user, in, ok := s.adminBody(w, r)
	if !ok {
		return
	}
	a := s.instAdmin()
	ctx := r.Context()
	op, name, kind := str(in, "op"), str(in, "name"), str(in, "kind")
	pay := map[string]any{"op": op, "ui_user": user, "client": clientIP(r), "name": name}
	if op == "sync" {
		res, err := s.syncSource(ctx, name)
		if err != nil {
			writeErr(w, http.StatusConflict, err)
			return
		}
		s.reply(w, r, res, nil)
		return
	}
	var written []string
	undo := func() {
		for _, ref := range written {
			_ = config.RemoveSecret(a.secretDir(), ref)
		}
	}
	if op == "add" {
		if !srcName.MatchString(name) {
			writeErr(w, http.StatusBadRequest, errors.New("a source name is 1 to 51 letters, digits, _ . or -"))
			return
		}
		dir := a.secretDir()
		if dir == "" {
			writeErr(w, http.StatusConflict, errors.New("this server was started without a config file path: credentials cannot be written"))
			return
		}
		var srcExists bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pgvigil.admin_sources WHERE name = $1)`, name).Scan(&srcExists); err != nil {
			s.reply(w, r, nil, err)
			return
		}
		pay["kind"], pay["auth"], pay["every_s"] = kind, str(in, "auth"), str(in, "every_s")
		switch kind {
		case "cms":
			port, _ := strconv.Atoi(str(in, "cms_port"))
			dsn, err := config.BuildDSN(config.Conn{Engine: config.EngineSQLServer, Auth: str(in, "cms_auth"), Host: str(in, "cms_host"), Port: port,
				DBName: "msdb", Login: str(in, "cms_login"), Password: rawStr(in, "cms_password"), Extra: str(in, "cms_options")})
			if err != nil {
				writeErr(w, http.StatusBadRequest, fmt.Errorf("the CMS login: %w", err))
				return
			}
			if !srcExists {
				ref, err := config.WriteSecret(dir, "src-"+name+"-cms", dsn)
				if err != nil {
					writeErr(w, http.StatusConflict, fmt.Errorf("the CMS login's file: %w", err))
					return
				}
				written = append(written, ref)
				pay["ref"] = ref
			}
		case "dbadash":
			if _, ok := a.DBADash[str(in, "ref")]; !ok {
				writeErr(w, http.StatusBadRequest, fmt.Errorf("no dbadash: repository %q in pgvigil.yaml (known: %s)", str(in, "ref"), strings.Join(keys(a.DBADash), ", ")))
				return
			}
			pay["ref"] = str(in, "ref")
		case "sqlserver_list", "pg_service", "pg_csv":
			p := str(in, "ref")
			if !filepath.IsAbs(p) {
				writeErr(w, http.StatusBadRequest, errors.New("the list file's path is absolute (a path on this server)"))
				return
			}
			if _, err := os.Stat(p); err != nil {
				writeErr(w, http.StatusBadRequest, fmt.Errorf("the list file: %w", err))
				return
			}
			pay["ref"] = p
		}
		if l, pw := str(in, "cred_login"), rawStr(in, "cred_password"); (l != "" || pw != "") && !srcExists {
			b, _ := json.Marshal(sourceCred{Login: l, Password: pw, Extra: str(in, "cred_options")})
			ref, err := config.WriteSecret(dir, "src-"+name, string(b))
			if err != nil {
				undo()
				writeErr(w, http.StatusConflict, fmt.Errorf("the source's credential file: %w", err))
				return
			}
			written = append(written, ref)
			pay["credential_ref"] = ref
		}
	}
	var refs []string
	if op == "remove" {
		_ = s.pool.QueryRow(ctx, `SELECT array_remove(ARRAY[CASE WHEN kind = 'cms' THEN ref END, credential_ref], NULL) FROM pgvigil.admin_sources WHERE name = $1`, name).Scan(&refs)
	}
	ans, raw, err := s.callImport(ctx, "import_admin_source", pay)
	if err != nil {
		undo()
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if ans.Outcome != "done" {
		undo()
	}
	if ans.Outcome == "done" && op == "remove" {
		for _, ref := range refs {
			_ = config.RemoveSecret(a.secretDir(), ref)
		}
	}
	extra := map[string]any{}
	if ans.Outcome == "done" && op == "add" {
		res, err := s.syncSource(ctx, name)
		if err != nil {
			extra["sync_error"] = err.Error()
		} else {
			extra["sync"] = res
		}
	}
	s.log.Info("admin source", "op", op, "name", name, "user", user, "outcome", ans.Outcome, "detail", ans.Detail)
	s.answer(w, ans, raw, extra)
}

type sourceRow struct {
	Name, Kind, Ref string
	Cred            *string
	Auth            string
	Enabled         bool
}

func (s *Server) sourceByName(ctx context.Context, name string) (*sourceRow, error) {
	var x sourceRow
	err := s.pool.QueryRow(ctx, `SELECT name, kind, ref, credential_ref, auth, enabled FROM pgvigil.admin_sources WHERE name = $1`, name).
		Scan(&x.Name, &x.Kind, &x.Ref, &x.Cred, &x.Auth, &x.Enabled)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("no source %s", name)
	}
	return &x, err
}

// cmsQuery lists a CMS's registered Database Engine servers with the path of their groups (the root group,
// DatabaseEngineServerGroup, left out).
const cmsQuery = `
WITH g AS (
  SELECT server_group_id, parent_id, CAST(name AS nvarchar(max)) AS path, is_system_object
    FROM msdb.dbo.sysmanagement_shared_server_groups WHERE parent_id IS NULL AND server_type = 0
  UNION ALL
  SELECT c.server_group_id, c.parent_id, CAST(CASE WHEN g.is_system_object = 1 THEN c.name ELSE g.path + N'/' + c.name END AS nvarchar(max)), c.is_system_object
    FROM msdb.dbo.sysmanagement_shared_server_groups c JOIN g ON c.parent_id = g.server_group_id
)
SELECT s.server_name, s.name, CASE WHEN g.is_system_object = 1 THEN N'' ELSE g.path END
  FROM msdb.dbo.sysmanagement_shared_registered_servers s JOIN g ON g.server_group_id = s.server_group_id
 WHERE s.server_type = 0
 ORDER BY s.server_name`

// readSource reads a source's servers now.
func (s *Server) readSource(ctx context.Context, src *sourceRow) ([]config.Proposal, error) {
	a := s.instAdmin()
	switch src.Kind {
	case "cms", "dbadash":
		var dsn string
		var err error
		if src.Kind == "cms" {
			dsn, err = resolveRef(src.Ref)
		} else {
			ref, ok := a.DBADash[src.Ref]
			if !ok {
				return nil, fmt.Errorf("no dbadash: repository %q in pgvigil.yaml now", src.Ref)
			}
			dsn, err = resolveRef(ref)
		}
		if err != nil {
			return nil, err
		}
		db, err := sql.Open("sqlserver", mssqlApp(dsn, "pgvigil-sync"))
		if err != nil {
			return nil, fmt.Errorf("the connection string: %w", err)
		}
		defer db.Close()
		cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		q := cmsQuery
		if src.Kind == "dbadash" {
			q = `SELECT ConnectionID, Instance, N'' FROM dbo.Instances WHERE IsActive = 1 ORDER BY ConnectionID`
		}
		rows, err := db.QueryContext(cctx, q)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []config.Proposal
		for rows.Next() {
			var server, disp, path sql.NullString
			if err := rows.Scan(&server, &disp, &path); err != nil {
				return nil, err
			}
			if !server.Valid || strings.TrimSpace(server.String) == "" {
				continue
			}
			h, p := config.SplitHostPort(server.String)
			tags := []string{}
			if path.String != "" {
				for _, part := range strings.Split(path.String, "/") {
					if t := strings.TrimSpace(strings.NewReplacer(",", " ", "\t", " ").Replace(part)); t != "" {
						tags = append(tags, "group:"+t)
					}
				}
			}
			out = append(out, config.Proposal{Server: server.String, Engine: config.EngineSQLServer, Host: h, Port: p, DisplayName: disp.String, Tags: tags})
		}
		return out, rows.Err()
	case "sqlserver_list", "pg_csv", "pg_service":
		f, err := os.Open(src.Ref)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		switch src.Kind {
		case "pg_service":
			return config.ParsePgService(f)
		case "pg_csv":
			return config.ParseServerList(f, config.EnginePostgres)
		default:
			return config.ParseServerList(f, config.EngineSQLServer)
		}
	}
	return nil, fmt.Errorf("unknown source kind %s", src.Kind)
}

// syncSource reads one source and hands the list to import_admin_proposals (a failed read is recorded, nothing
// marked gone).
func (s *Server) syncSource(ctx context.Context, name string) (map[string]any, error) {
	if s.ackOff() != "" {
		return nil, errors.New(s.ackOff())
	}
	src, err := s.sourceByName(ctx, name)
	if err != nil {
		return nil, err
	}
	list, rerr := s.readSource(ctx, src)
	var rows any
	var errText any
	if rerr != nil {
		errText = rerr.Error()
	} else {
		if list == nil {
			list = []config.Proposal{}
		}
		rows = list
	}
	b, _ := json.Marshal(rows)
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	var out []byte
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_admin_proposals($1, $2, $3::jsonb, $4)::text`, name, time.Now(), string(b), errText).Scan(&out); err != nil {
		return nil, err
	}
	res := map[string]any{}
	_ = json.Unmarshal(out, &res)
	if rerr != nil {
		return res, fmt.Errorf("the source %s could not be read: %w", name, rerr)
	}
	return res, nil
}

// RunInstanceSync reads each enabled source whose interval is up, every 30 s, until ctx ends (serve runs it).
func (s *Server) RunInstanceSync(ctx context.Context) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if s.ackOff() != "" {
			continue
		}
		rows, err := s.pool.Query(ctx, `SELECT name FROM pgvigil.admin_sources WHERE enabled AND (last_run IS NULL OR last_run + every_s * interval '1 second' <= now()) ORDER BY name`)
		if err != nil {
			continue
		}
		names, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			continue
		}
		for _, n := range names {
			if _, err := s.syncSource(ctx, n); err != nil && ctx.Err() == nil {
				s.log.Warn("instance sync", "source", n, "err", err)
			}
		}
	}
}

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9_.@-]+`)

// nameFor makes an instance name of a proposal's server: "sql01\PROD,1433" -> "sql01-PROD-1433".
func nameFor(server string) string {
	n := strings.Trim(unsafeName.ReplaceAllString(server, "-"), "-._@")
	if len(n) > 63 {
		n = n[:63]
	}
	return n
}

// ProposalsAdminWrite is POST /api/admin/proposals.
func (s *Server) ProposalsAdminWrite(w http.ResponseWriter, r *http.Request) {
	user, in, ok := s.adminBody(w, r)
	if !ok {
		return
	}
	a := s.instAdmin()
	ctx := r.Context()
	op, id := str(in, "op"), str(in, "proposal_id")
	pay := map[string]any{"op": op, "ui_user": user, "client": clientIP(r), "proposal_id": id, "file_names": a.fileNames()}
	var restore func()
	if op == "approve" {
		var src, server, engine, host string
		var port *int
		var db, login *string
		err := s.pool.QueryRow(ctx, `SELECT source, server, engine, host, port, dbname, login FROM pgvigil.admin_proposals WHERE proposal_id::text = $1`, id).
			Scan(&src, &server, &engine, &host, &port, &db, &login)
		if errors.Is(err, pgx.ErrNoRows) {
			writeErr(w, http.StatusConflict, fmt.Errorf("no proposal %s", id))
			return
		} else if err != nil {
			s.reply(w, r, nil, err)
			return
		}
		sr, err := s.sourceByName(ctx, src)
		if err != nil {
			s.reply(w, r, nil, err)
			return
		}
		name := str(in, "name")
		if name == "" {
			name = nameFor(server)
		}
		pay["name"] = name
		var cred sourceCred
		if sr.Cred != nil {
			v, err := resolveRef(*sr.Cred)
			if err != nil {
				writeErr(w, http.StatusConflict, fmt.Errorf("the source's credential: %w", err))
				return
			}
			if err := json.Unmarshal([]byte(v), &cred); err != nil {
				writeErr(w, http.StatusConflict, errors.New("the source's credential file is not the page's own (JSON)"))
				return
			}
		}
		var dsn string
		if sr.Kind == "pg_service" {
			// the service file itself: its password (or the service account's .pgpass) stays where it is
			dsn = "service=" + strings.ReplaceAll(server, " ", "") + " servicefile=" + sr.Ref
			if cred.Login != "" {
				dsn += " user=" + cred.Login
			}
			if cred.Password != "" {
				dsn += " password='" + strings.ReplaceAll(strings.ReplaceAll(cred.Password, `\`, `\\`), `'`, `\'`) + "'"
			}
		} else {
			l := cred.Login
			if l == "" {
				l = orZero(login)
			}
			auth := sr.Auth
			if auth == "password" && cred.Password == "" {
				auth = "pgpass"
			}
			dsn, err = config.BuildDSN(config.Conn{Engine: engine, Auth: auth, Host: host, Port: orZero(port), DBName: orZero(db), Login: l, Password: cred.Password, Extra: cred.Extra})
			if err != nil {
				writeErr(w, http.StatusConflict, err)
				return
			}
		}
		if have, _ := s.pageInstance(ctx, name); have != nil || slicesContains(a.fileNames(), name) {
			pay["dsn_ref"] = "file:/refused" // the function refuses the name; nothing is written
		} else {
			ref, err := config.WriteSecret(a.secretDir(), name, dsn)
			if err != nil {
				writeErr(w, http.StatusConflict, fmt.Errorf("the credential file: %w", err))
				return
			}
			pay["dsn_ref"] = ref
			restore = func() { _ = config.RemoveSecret(a.secretDir(), ref) }
		}
	}
	ans, raw, err := s.callImport(ctx, "import_admin_decision", pay)
	if err != nil {
		if restore != nil {
			restore()
		}
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if ans.Outcome != "done" && restore != nil {
		restore()
	}
	s.log.Info("admin proposal", "op", op, "proposal", id, "user", user, "outcome", ans.Outcome, "detail", ans.Detail)
	s.answer(w, ans, raw, nil)
}
