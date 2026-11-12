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
	"runtime"
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

func (a *InstancesAdmin) sourceDir() string {
	if a.ConfigPath == "" {
		return ""
	}
	return config.SourceSecretDir(a.ConfigPath)
}

// listPathOK refuses a list source's path inside a credential folder, the config file itself, or a network path (a
// UNC path would be opened over SMB as serve's machine account): a list is read into proposals, which the page shows.
func (a *InstancesAdmin) listPathOK(p string) error {
	if strings.HasPrefix(p, `\\`) || strings.HasPrefix(p, "//") {
		return errors.New("the list file is a network path (UNC): give a path on this server's own disk")
	}
	// Windows reads any two leading separators (/\, \/) and \??\ as a network or device path: only a drive letter
	if runtime.GOOS == "windows" {
		if v := filepath.VolumeName(filepath.Clean(p)); len(v) != 2 || v[1] != ':' {
			return errors.New(`the list file is not on a drive of this server (a network or device path): give a path like C:\lists\servers.txt`)
		}
	}
	clean := filepath.Clean(p)
	for _, d := range []string{a.secretDir(), a.sourceDir()} {
		if d == "" {
			continue
		}
		if rel, err := filepath.Rel(d, clean); err == nil && !strings.HasPrefix(rel, "..") {
			return errors.New("the list file lies in a credential folder: not a server list")
		}
	}
	if a.ConfigPath != "" {
		if abs, err := filepath.Abs(a.ConfigPath); err == nil && abs == clean {
			return errors.New("the list file is pgvigil.yaml itself: not a server list")
		}
	}
	return nil
}

// listFileOK checks a list source's file before it is added and before each read: a regular file and, off Windows,
// readable by more than its owner unless it is a pg_service.conf (whose parser keeps no password) - a file only
// its owner may read is a credential by convention (.pgpass), and a list is shown on the page.
func listFileOK(kind, p string) error {
	fi, err := os.Stat(p)
	if err != nil {
		return fmt.Errorf("the list file: %w", err)
	}
	if !fi.Mode().IsRegular() {
		return errors.New("the list file is not a regular file")
	}
	if runtime.GOOS != "windows" && kind != "pg_service" && fi.Mode().Perm()&0o044 == 0 {
		return fmt.Errorf("the list file can be read by its owner only (mode %04o): a file kept that private is a credential by convention (.pgpass); a server list is readable (0644)", fi.Mode().Perm())
	}
	return nil
}

// credentialGrace: an instance's previous credential file stays this long after an edit or a remove, so the
// collector, which reads the page's list every 15 s, never opens a ref already gone.
const credentialGrace = 30 * time.Second

func (s *Server) removeSecretLater(dir, ref, name string) {
	time.AfterFunc(credentialGrace, func() {
		if err := config.RemoveSecret(dir, ref); err != nil {
			s.log.Warn("admin instance: the previous credential file stays", "name", name, "err", err)
		}
	})
}

// sweepSecrets removes the instance credential files no instance names (those a serve stopped within the grace of an
// edit or a remove left behind), once, at the sync loop's first tick: past the grace, so a collector still holding
// an old ref has moved on. A file younger than twice the grace stays (an add may be writing it). true = done.
func (s *Server) sweepSecrets(ctx context.Context) bool {
	dir := s.instAdmin().secretDir()
	if dir == "" {
		return true
	}
	rows, err := s.pool.Query(ctx, `SELECT dsn_ref FROM pgvigil.admin_instances`)
	if err != nil {
		return false
	}
	refs, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return false
	}
	named := map[string]bool{}
	for _, r := range refs {
		if _, p, ok := strings.Cut(r, ":"); ok {
			named[filepath.Clean(p)] = true
		}
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return true
	}
	for _, e := range ents {
		p := filepath.Join(dir, e.Name())
		fi, err := e.Info()
		if err != nil || !fi.Mode().IsRegular() || named[p] || time.Since(fi.ModTime()) < 2*credentialGrace {
			continue
		}
		ref := "file:" + p
		if strings.HasSuffix(e.Name(), ".dpapi") {
			ref = "dpapi:" + p
		}
		if err := config.RemoveSecret(dir, ref); err == nil {
			s.log.Info("admin instance: a credential file no instance names was removed", "file", e.Name())
		}
	}
	return true
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
	out := map[string]any{"file": file, "secret_dir": a.secretDir(), "dbadash": keys(a.DBADash), "writable": s.instancesOff() == "", "why_not": s.instancesOff()}
	parts := []struct{ k, q string }{
		{"page", `SELECT a.name, a.engine, a.platform, a.auth, a.host, a.port, a.dbname, a.login, a.options, array_to_string(a.tags, ' ') AS tags,
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

// instancesOff says why the page cannot add or change instances (or read its sources) on this server, "" when it
// can, in the page's own words: its writes ride the actions door's audit login and the UI login, as acknowledgements
// do (ackOff), but an acknowledgement's wording would be wrong here (the join's w9c: proof-upgrade, proof-darling-alerts C).
func (s *Server) instancesOff() string {
	switch {
	case s.auth == nil:
		return "adding and changing instances needs the UI login: this server runs with -no-login"
	case s.actions == nil:
		return "adding and changing instances is off on this server: it has no actions door (every change is written through its audit login)"
	case s.actions.audit == nil:
		if s.actions.off != "" {
			return "adding and changing instances goes through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "adding and changing instances goes through the actions door's audit login, and it is not connected"
	}
	return ""
}

// adminBody is the writes' common door: the header, the actions door, the login, a body of 16 KB at most.
func (s *Server) adminBody(w http.ResponseWriter, r *http.Request) (string, map[string]any, bool) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return "", nil, false
	}
	if why := s.instancesOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
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
	DBName, Login, Options            *string
	Tags                              []string
}

func (s *Server) pageInstance(ctx context.Context, name string) (*pageRow, error) {
	var p pageRow
	err := s.pool.QueryRow(ctx, `SELECT engine, platform, dsn_ref, auth, host, port, dbname, login, options, tags FROM pgvigil.admin_instances WHERE name = $1`, name).
		Scan(&p.Engine, &p.Platform, &p.Ref, &p.Auth, &p.Host, &p.Port, &p.DBName, &p.Login, &p.Options, &p.Tags)
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
	var written, previous string // this attempt's credential file; the one the row named before (removed once replaced)
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
		pay["engine"], pay["platform"], pay["auth"], pay["host"], pay["port"], pay["dbname"], pay["login"], pay["options"], pay["tags"] =
			c.Engine, str(in, "platform"), c.Auth, c.Host, str(in, "port"), c.DBName, c.Login, c.Extra, tagsOf(in)
		if op == "edit" && have != nil && c.Password == "" {
			changed := c.Host != have.Host || port != orZero(have.Port) || c.DBName != orZero(have.DBName) || c.Login != orZero(have.Login) ||
				c.Auth != have.Auth || c.Extra != orZero(have.Options)
			if !changed {
				// a tags or platform edit keeps the credential file as it is
				pay["dsn_ref"] = have.Ref
				break
			}
			if c.Auth == "sql" || c.Auth == "entra" || c.Auth == "password" {
				writeErr(w, http.StatusConflict, errors.New("the connection changed: give the password again (it is never read back from its file)"))
				return
			}
		}
		if (op == "add" && have != nil) || (op == "edit" && have == nil) || slicesContains(a.fileNames(), name) {
			pay["dsn_ref"] = "file:/refused" // the function refuses the name; nothing is written
			break
		}
		dsn, err := config.BuildDSN(c)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		ref, err := config.WriteSecret(dir, name, dsn)
		if err != nil {
			writeErr(w, http.StatusConflict, fmt.Errorf("the credential file: %w", err))
			return
		}
		pay["dsn_ref"], written = ref, ref
		if have != nil {
			previous = have.Ref
		}
	case "disable", "enable", "remove":
		if op == "remove" && have != nil {
			previous = have.Ref
		}
	default:
		writeErr(w, http.StatusBadRequest, errors.New("op is add, edit, disable, enable, remove or test"))
		return
	}
	ans, raw, err := s.callImport(ctx, "import_admin_instance", pay)
	switch {
	case err != nil || ans.Outcome != "done":
		// this attempt's own file only: a concurrent write of the same name owns another
		if written != "" {
			_ = config.RemoveSecret(a.secretDir(), written)
		}
		if err != nil {
			s.log.Error("admin instance: not written", "user", user, "op", op, "name", name, "err", err)
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
			return
		}
	case previous != "" && (op == "remove" || written != ""):
		// the row names the new file now (or no file: a remove); the old one goes after the collector's next read
		s.removeSecretLater(a.secretDir(), previous, name)
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
		defer func() { _ = db.Close() }()
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
		defer func() { _ = conn.Close(context.Background()) }()
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
			_ = config.RemoveSecret(a.sourceDir(), ref)
		}
	}
	if op == "add" {
		if !srcName.MatchString(name) {
			writeErr(w, http.StatusBadRequest, errors.New("a source name is 1 to 51 letters, digits, _ . or -"))
			return
		}
		dir := a.sourceDir()
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
			if err := a.listPathOK(p); err != nil {
				writeErr(w, http.StatusBadRequest, err)
				return
			}
			if err := listFileOK(kind, p); err != nil {
				writeErr(w, http.StatusBadRequest, err)
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
			_ = config.RemoveSecret(a.sourceDir(), ref)
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
		defer func() { _ = db.Close() }()
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
		defer func() { _ = rows.Close() }()
		var out []config.Proposal
		for rows.Next() {
			var server, disp, path sql.NullString
			if err := rows.Scan(&server, &disp, &path); err != nil {
				return nil, err
			}
			if !server.Valid || strings.TrimSpace(server.String) == "" || config.NotTCP(server.String) {
				continue // a named pipe or shared memory registration: the collector opens TCP only
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
		if err := s.instAdmin().listPathOK(src.Ref); err != nil {
			return nil, err
		}
		if err := listFileOK(src.Kind, src.Ref); err != nil {
			return nil, err
		}
		f, err := os.Open(src.Ref)
		if err != nil {
			return nil, err
		}
		defer func() { _ = f.Close() }()
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
	if why := s.instancesOff(); why != "" {
		return nil, errors.New(why)
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
	swept := false
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if !swept {
			swept = s.sweepSecrets(ctx)
		}
		if s.instancesOff() != "" {
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
			dsn = "service=" + config.QuoteValue(server) + " servicefile=" + config.QuoteValue(sr.Ref)
			if cred.Login != "" {
				dsn += " user=" + config.QuoteValue(cred.Login)
			}
			if cred.Password != "" {
				dsn += " password=" + config.QuoteValue(cred.Password)
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
			restore = func() { _ = config.RemoveSecret(a.secretDir(), ref) } // this attempt's own file only
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
