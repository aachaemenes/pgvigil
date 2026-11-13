// Admin > Instances (task 204; task 103 part 1): instances added, edited, disabled, removed and tested in the page,
// and the sync sources whose servers come in as proposals a click approves or ignores.
//
//	GET  /api/admin/instances            the file's instances (read-only), the page's, the sources, the proposals,
//	                                     the last 200 audit rows and the inventory generation
//	POST /api/admin/instances            op add | edit | disable | enable | remove | test
//	POST /api/admin/sources              op add | remove | enable | disable | sync | sweep | edit
//	POST /api/admin/proposals            op approve | test | ignore | unignore
//
// Every write needs the UI login and the X-Pgvigil header and goes through an import_ function on the actions
// door's audit login (0122), which audits it, refused attempts included. A credential is written by this file to
// its own file under the config folder (config.WriteSecret) before the row that names it, and is never sent back:
// the API answers whether an instance has one, never what it holds. The collector takes a change within 15 s
// (config.WatchInventory) without a restart.
//
// RunInstanceSync (serve, every 30 s) reads each enabled source whose interval is up: a CMS
// (msdb.dbo.sysmanagement_shared_registered_servers and _groups, the groups as tags group:<name>), a DBA Dash
// repository's dbo.Instances, a server list, a pg_service.conf or a CSV, and aws / azure / gcp (internal/discover; the
// weekly sweep), into the proposals (import_admin_proposals).

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
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/discover"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
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
		        (SELECT max(c.snapshot_at) FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id AND c.status = 'ok') AS last_collected,
		        -- task 205's design pass: an approved server its source no longer lists
		        g.source AS gone_source, g.gone_at AS gone_since
		   FROM pgvigil.admin_instances a LEFT JOIN pgvigil.instances i ON i.name = a.name
		   LEFT JOIN LATERAL (SELECT p.source, p.gone_at FROM pgvigil.admin_proposals p
		                       WHERE p.instance_name = a.name AND p.state = 'approved' AND p.gone ORDER BY p.gone_at DESC LIMIT 1) g ON true
		  ORDER BY a.name`},
		{"sources", `SELECT name, kind, CASE WHEN kind = 'cms' THEN 'the CMS login''s credential file' WHEN kind IN ('aws', 'azure', 'gcp') THEN 'its settings file (the read-only credential)' ELSE ref END AS ref,
		        credential_ref IS NOT NULL AS has_credential, auth, every_s, enabled, last_run, last_ok, last_error, last_notes, last_count, created_at, created_by,
		        array_to_string(cloud_regions, ' ') AS regions, regions_read_at, array_to_string(tag_keys, ' ') AS tag_keys,
		        array_to_string(seen_tag_keys, ' ') AS seen_tag_keys, claim_until > now() AS reading FROM pgvigil.admin_sources ORDER BY name`},
		{"proposals", `SELECT proposal_id, source, server, engine, host, port, dbname, display_name, array_to_string(tags, ' ') AS tags, state, gone,
		        first_seen, last_seen, gone_at, decided_at, decided_by, instance_name,
		        alt_host, master_user, note, entra_only, serverless, auto_pause, resource_id
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
	case s.demo != nil:
		return "adding and changing instances writes connection secrets and connects to servers: it needs pgvigil serve with a signed-in user (this is pgvigil demo -serve)"
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
		db, err := mssqlopen.Open(mssqlApp(dsn, "pgvigil-admin-test"))
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
	if op == "sync" || op == "sweep" {
		res, err := s.syncSource(ctx, name, inRequestRead, "", user, false, op == "sweep")
		if err != nil {
			writeErr(w, http.StatusConflict, err)
			return
		}
		s.reply(w, r, res, nil)
		return
	}
	if op == "edit" {
		// the regions an AWS source reads and the resource tag keys a source takes in (the next read applies them)
		pay["regions"], pay["tag_keys"] = nil, nil
		if v, ok := in["regions"]; ok {
			pay["regions"] = splitList(fmt.Sprint(v))
		}
		if v, ok := in["tag_keys"]; ok {
			keys := []string{}
			for _, k := range splitList(fmt.Sprint(v)) {
				keys = append(keys, discover.TagKey(k))
			}
			pay["tag_keys"] = keys
		}
		if pay["regions"] == nil {
			delete(pay, "regions")
		}
		if pay["tag_keys"] == nil {
			delete(pay, "tag_keys")
		}
		ans, raw, err := s.callImport(ctx, "import_admin_source", pay)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
			return
		}
		s.log.Info("admin source", "op", op, "name", name, "user", user, "outcome", ans.Outcome, "detail", ans.Detail)
		s.answer(w, ans, raw, nil)
		return
	}
	var written []string
	var addToken string // an access token reads once, at the add: never written to the settings file
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
		case "aws", "azure", "gcp":
			cs := cloudSettings{Kind: kind, Profile: str(in, "aws_profile"), Regions: splitList(str(in, "aws_regions")),
				Subscriptions: splitList(str(in, "azure_subscriptions")), Cloud: str(in, "azure_cloud"), Auth: str(in, "cloud_auth"), TenantID: str(in, "azure_tenant"),
				ClientID: str(in, "azure_client_id"), ClientSecret: rawStr(in, "azure_client_secret"), Projects: splitList(str(in, "gcp_projects")),
				KeyJSON: rawStr(in, "gcp_key"), Token: rawStr(in, "cloud_token")}
			if err := cs.check(); err != nil {
				writeErr(w, http.StatusBadRequest, err)
				return
			}
			if cs.Auth == "token" {
				addToken = cs.Token
			}
			if kind == "aws" && len(cs.Regions) > 0 {
				pay["regions"] = cs.Regions // kept in the source's row; none = swept at its first read
			}
			if !srcExists {
				b, _ := json.Marshal(cs.stored())
				ref, err := config.WriteSecret(dir, "src-"+name+"-cloud", string(b))
				if err != nil {
					writeErr(w, http.StatusConflict, fmt.Errorf("the source's settings file: %w", err))
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
		_ = s.pool.QueryRow(ctx, `SELECT array_remove(ARRAY[CASE WHEN kind IN ('cms', 'aws', 'azure', 'gcp') THEN ref END, credential_ref], NULL) FROM pgvigil.admin_sources WHERE name = $1`, name).Scan(&refs)
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
		res, err := s.syncSource(ctx, name, inRequestRead, addToken, user, false, false)
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
	// task 205's design pass: the regions an AWS sweep found readable (nil = none kept yet), the resource tag keys
	// taken in, the Azure subscriptions of the last complete read
	Regions, TagKeys, Scopes []string
	// Silent: the kept AWS regions whose note says they did not answer within the last 7 days (task 205 D5: left out
	// until the next sweep; the review's part b: a note older than a week is asked again by the hourly read, so a
	// source never swept does not leave a region out for good)
	Silent []string
}

func (s *Server) sourceByName(ctx context.Context, name string) (*sourceRow, error) {
	var x sourceRow
	err := s.pool.QueryRow(ctx, `SELECT name, kind, ref, credential_ref, auth, enabled, cloud_regions, tag_keys, seen_scopes,
		        ARRAY(SELECT x->>'key' FROM jsonb_array_elements(note_items) x WHERE x->>'key' <> 'source' AND x->>'text' LIKE (x->>'key') || ': not reachable%'
		                 AND (x->>'last')::timestamptz > now() - $2 * interval '1 second' ORDER BY 1)
		   FROM pgvigil.admin_sources WHERE name = $1`, name, weeklySweep.Seconds()).
		Scan(&x.Name, &x.Kind, &x.Ref, &x.Cred, &x.Auth, &x.Enabled, &x.Regions, &x.TagKeys, &x.Scopes, &x.Silent)
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

// inRequestRead bounds a source read done while its request waits ("Add the source", "Read now"): inside serve's
// 75 s WriteTimeout with the import after it; loopRead bounds the sync loop's own reads.
const (
	inRequestRead = 50 * time.Second
	loopRead      = 3 * time.Minute
)

// errTokenOnce: a cloud source added with an access token has no credential after its add.
var errTokenOnce = errors.New("an access token reads once, at the add (it is not kept): remove the source and add it again with a fresh token, or give it a credential that lasts (a service principal, the managed identity, a key, the server's account)")

// readSource reads a source's servers now within limit; a cloud read's notes say what it could not see and its
// Unseen the key prefixes whose proposals are kept as they are. token is the access token of the add's own read.
// An AWS source reads the regions its row keeps (named at the add, swept, or edited); with none it sweeps (sweep
// forces one: "Read the regions again"), starting from the configuration's region, else the first region it kept.
func (s *Server) readSource(ctx context.Context, src *sourceRow, limit time.Duration, token string, sweep bool) (discover.Read, error) {
	switch src.Kind {
	case "aws", "azure", "gcp":
		v, err := resolveRef(src.Ref)
		if err != nil {
			return discover.Read{}, err
		}
		var cs cloudSettings
		if err := json.Unmarshal([]byte(v), &cs); err != nil {
			return discover.Read{}, errors.New("the source's settings file is not the page's own (JSON)")
		}
		if cs.Auth == "token" {
			if token == "" {
				return discover.Read{}, errTokenOnce
			}
			cs.Token = token
		}
		cctx, cancel := context.WithTimeout(ctx, limit)
		defer cancel()
		switch src.Kind {
		case "aws":
			o := discover.AWSOptions{Profile: cs.Profile, Regions: src.Regions, Skip: src.Silent}
			if sweep {
				// the kept regions are read too: a sweep that cannot list the partition loses none of them
				o.Regions, o.Keep, o.Skip = nil, src.Regions, nil
				o.Start = sweepStart(src.Regions, src.Silent) // a host with no configured region still has one to sweep from
			}
			return discover.AWS(cctx, o)
		case "azure":
			o := discover.AzureOptions{Subscriptions: cs.Subscriptions, Cloud: cs.Cloud, PrevScopes: src.Scopes}
			switch cs.Auth {
			case "identity":
				o.ManagedIdentity, o.ClientID = true, cs.ClientID
			case "token":
				o.Token = cs.Token
			default:
				o.TenantID, o.ClientID, o.ClientSecret = cs.TenantID, cs.ClientID, cs.ClientSecret
			}
			return discover.Azure(cctx, o)
		default:
			o := discover.GCPOptions{Projects: cs.Projects}
			switch cs.Auth {
			case "metadata":
				o.Metadata = true
			case "token":
				o.Token = cs.Token
			default:
				o.KeyJSON = cs.KeyJSON
			}
			return discover.GCP(cctx, o)
		}
	}
	list, err := s.readList(ctx, src)
	return discover.Read{Proposals: list}, err
}

// tokenOnly: a cloud source added with an access token read once, at its add; the sync loop passes it by.
func (s *Server) tokenOnly(ctx context.Context, name string) bool {
	src, err := s.sourceByName(ctx, name)
	if err != nil || (src.Kind != "aws" && src.Kind != "azure" && src.Kind != "gcp") {
		return false
	}
	v, err := resolveRef(src.Ref)
	if err != nil {
		return false
	}
	var cs cloudSettings
	return json.Unmarshal([]byte(v), &cs) == nil && cs.Auth == "token"
}

// splitList splits a list the page sends on spaces, commas or semicolons.
func splitList(v string) []string {
	return strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ';' || unicode.IsSpace(r) })
}

var azureSub = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

// awsRegion is a region's shape only (a host name's labels): its partition is the credentials' answer at the read
var awsRegion = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)+$`)

// cloudSettings is a cloud source's settings file (written by serve under sources/, 0600; never in the repository).
type cloudSettings struct {
	Kind          string   `json:"kind"`
	Profile       string   `json:"profile,omitempty"`
	Regions       []string `json:"regions,omitempty"`
	Subscriptions []string `json:"subscriptions,omitempty"`
	Cloud         string   `json:"cloud,omitempty"` // azure: public | usgov | china (NOT PROVEN outside public: no lab)
	Auth          string   `json:"auth,omitempty"`  // azure: secret | identity | token; gcp: key | metadata | token; aws: the default chain or the profile
	TenantID      string   `json:"tenant_id,omitempty"`
	ClientID      string   `json:"client_id,omitempty"`
	ClientSecret  string   `json:"client_secret,omitempty"`
	Projects      []string `json:"projects,omitempty"`
	KeyJSON       string   `json:"key_json,omitempty"`
	Token         string   `json:"token,omitempty"`
}

// stored is what the settings file keeps: the fields the kind and its credential use (a hidden field the page sent
// is dropped), never an access token.
func (c cloudSettings) stored() cloudSettings {
	k := cloudSettings{Kind: c.Kind, Auth: c.Auth}
	switch c.Kind {
	case "aws":
		k.Profile = c.Profile // the regions are the source's row (cloud_regions: shown, edited, swept)
	case "azure":
		k.Subscriptions, k.Cloud = c.Subscriptions, c.Cloud
		switch c.Auth {
		case "secret", "":
			k.TenantID, k.ClientID, k.ClientSecret = c.TenantID, c.ClientID, c.ClientSecret
		case "identity":
			k.ClientID = c.ClientID
		}
	case "gcp":
		k.Projects = c.Projects
		if c.Auth == "key" || c.Auth == "" {
			k.KeyJSON = c.KeyJSON
		}
	}
	return k
}

func (c cloudSettings) check() error {
	switch c.Kind {
	case "aws":
		// the shape only (no region or partition named in pgvigil: the credentials' read says which it reads)
		for _, r := range c.Regions {
			if !awsRegion.MatchString(r) || len(r) > 40 {
				return fmt.Errorf("not an AWS region: %q", r)
			}
		}
	case "azure":
		for _, sub := range c.Subscriptions {
			if !azureSub.MatchString(sub) {
				return fmt.Errorf("not a subscription id (a GUID): %q", sub)
			}
		}
		switch c.Cloud {
		case "", "public", "usgov", "china":
		default:
			return errors.New("the Azure cloud is public, usgov or china")
		}
		switch c.Auth {
		case "secret", "":
			if c.TenantID == "" || c.ClientID == "" || c.ClientSecret == "" {
				return errors.New("a service principal needs its tenant, client id and secret")
			}
		case "identity":
		case "token":
			if c.Token == "" {
				return errors.New("the token is empty")
			}
		default:
			return errors.New("the Azure credential is secret, identity or token")
		}
	case "gcp":
		if len(c.Projects) == 0 {
			return errors.New("name the GCP project(s) to read")
		}
		switch c.Auth {
		case "key", "":
			if !strings.Contains(c.KeyJSON, "private_key") {
				return errors.New("paste the service account key file's JSON")
			}
		case "metadata":
		case "token":
			if c.Token == "" {
				return errors.New("the token is empty")
			}
		default:
			return errors.New("the GCP credential is key, metadata or token")
		}
	}
	return nil
}

// readList reads the non-cloud sources.
func (s *Server) readList(ctx context.Context, src *sourceRow) ([]config.Proposal, error) {
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
		db, err := mssqlopen.Open(mssqlApp(dsn, "pgvigil-sync"))
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

// errReadRunning: another read of the source holds its claim (a request's or the hourly loop's).
var errReadRunning = errors.New("a read of this source is running: try again when it ends")

// syncSource reads one source within limit and hands the list to import_admin_proposals (a failed read is recorded,
// nothing marked gone; a proposal under an unseen prefix is kept as it is). token: the add's access token. by: who
// asked (a UI login, or 'the hourly read'): one audit row per read. due: the loop's (a source not due is passed by).
// sweep: an AWS source reads the partition again and keeps the regions that answered (also at its first read).
// Task 205's design pass: one read of a source at a time (a claim; the loser answers errReadRunning) and the read's
// start on the repository's clock, so an older read is never applied over a newer one.
func (s *Server) syncSource(ctx context.Context, name string, limit time.Duration, token, by string, due, sweep bool) (map[string]any, error) {
	if why := s.instancesOff(); why != "" {
		return nil, errors.New(why)
	}
	if _, err := s.sourceByName(ctx, name); err != nil {
		return nil, err // a source removed meanwhile: said as such, not as a read running
	}
	holder := fmt.Sprintf("%s:%d:%d", s.hostName(), os.Getpid(), time.Now().UnixNano())
	var started *time.Time
	cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	err := s.actions.audit.QueryRow(cctx, `SELECT pgvigil.import_admin_source_claim($1, $2, $3, $4)`, name, holder, int((limit + 30*time.Second).Seconds()), due).Scan(&started)
	ccancel()
	if err != nil {
		return nil, err
	}
	if started == nil {
		if due {
			return nil, nil
		}
		return nil, errReadRunning
	}
	release := func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		_, _ = s.actions.audit.Exec(rctx, `SELECT pgvigil.import_admin_source_release($1, $2)`, name, holder)
	}
	// the source as it is under the claim (a read applied between the first look and the claim may have kept other
	// regions: the review's part b)
	src, err := s.sourceByName(ctx, name)
	if err != nil {
		release()
		return nil, err
	}
	sweep = sweep || (src.Kind == "aws" && len(src.Regions) == 0)
	rd, rerr := s.readSource(ctx, src, limit, token, sweep)
	var rows any
	var errText any
	if rerr != nil {
		errText = rerr.Error()
	} else {
		list := make([]config.Proposal, 0, len(rd.Proposals))
		for _, p := range rd.Proposals {
			p.Tags = discover.TagsWith(p, src.TagKeys)
			list = append(list, p)
		}
		rows = list
	}
	unseen := rd.Unseen
	if unseen == nil {
		unseen = []string{}
	}
	var keys any
	if rerr == nil {
		keys = append([]string{}, rd.TagKeys...)
	}
	b, _ := json.Marshal(rows)
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
	defer cancel()
	var out []byte
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_admin_proposals($1, $2, $3::jsonb, $4, $5::text[], $6, $7, $8, $9::text[], $10::text[])::text`,
		name, time.Now(), string(b), errText, unseen, *started, by, holder, rd.Scopes, keys).Scan(&out); err != nil {
		release()
		return nil, err
	}
	res := map[string]any{}
	_ = json.Unmarshal(out, &res)
	if res["outcome"] == "refused" {
		return res, fmt.Errorf("%v", res["detail"])
	}
	nb, _ := json.Marshal(noteItems(rd.Notes, rd.Asked))
	asked := rd.Asked
	if asked == nil {
		asked = []string{}
	}
	if _, err := s.actions.audit.Exec(wctx, `SELECT pgvigil.import_admin_source_notes($1, $2, $3::jsonb, $4::text[], $5, $6)`,
		name, time.Now(), string(nb), asked, *started, sweep && src.Kind == "aws"); err != nil {
		s.log.Warn("instance sync: the notes were not kept", "source", name, "err", err)
	}
	if rerr == nil && sweep && src.Kind == "aws" && rd.Swept {
		// the regions that answered are the source's from now on (shown and editable; "Read the regions again")
		pay := map[string]any{"op": "edit", "ui_user": by, "name": name, "regions": rd.Regions, "swept": true}
		if ans, _, err := s.callImport(wctx, "import_admin_source", pay); err != nil || ans.Outcome != "done" {
			s.log.Warn("instance sync: the swept regions were not kept", "source", name, "err", err, "detail", ans.Detail)
		} else {
			res["regions"] = rd.Regions
		}
	}
	if len(rd.Notes) > 0 {
		res["notes"] = rd.Notes
	}
	if len(rd.TagKeys) > 0 {
		res["tag_keys_seen"] = rd.TagKeys
	}
	if rerr != nil {
		return res, fmt.Errorf("the source %s could not be read: %w", name, rerr)
	}
	return res, nil
}

// noteItems keys each note of a read: the AWS region it is about when it starts with one the read asked ("<region>: "
// or "<region> "), else "source" (task 205 D4: a region's note outlives a read that did not ask it).
func noteItems(notes, asked []string) []map[string]string {
	out := make([]map[string]string, 0, len(notes))
	for _, n := range notes {
		key := "source"
		for _, r := range asked {
			if strings.HasPrefix(n, r+": ") || strings.HasPrefix(n, r+" ") {
				key = r
				break
			}
		}
		out = append(out, map[string]string{"key": key, "text": n})
	}
	return out
}

// weeklySweep: an AWS source swept once is swept again by the loop when its regions are older than this (task 205
// D4: a region enabled since, or one RDS lists now, is found without a click).
const weeklySweep = 7 * 24 * time.Hour

// dueSourcesSQL lists the sources the loop reads now, each with whether the read is the weekly sweep: an AWS source
// swept once whose regions and last sweep tried are both older than $1 seconds (the review's part b: a sweep that
// failed is not tried again at every tick; sweep_tried_at is set by every sweep, whatever its outcome).
const dueSourcesSQL = `SELECT name, kind = 'aws' AND regions_read_at IS NOT NULL AND greatest(regions_read_at, sweep_tried_at) <= now() - $1 * interval '1 second'
   FROM pgvigil.admin_sources WHERE enabled AND (last_run IS NULL OR last_run + every_s * interval '1 second' <= now()) ORDER BY name`

// sweepStart is the region a sweep starts from on a host with no configured region (STS is asked there too): the
// first kept region not silent, else the first kept (the review's part b).
func sweepStart(regions, silent []string) string {
	for _, r := range regions {
		if !slices.Contains(silent, r) {
			return r
		}
	}
	if len(regions) > 0 {
		return regions[0]
	}
	return ""
}

// hostName names this serve in a claim (the read's holder).
func (s *Server) hostName() string {
	h, _ := os.Hostname()
	return h
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
		type due struct {
			Name    string
			Resweep bool
		}
		rows, err := s.pool.Query(ctx, dueSourcesSQL, weeklySweep.Seconds())
		if err != nil {
			continue
		}
		names, err := pgx.CollectRows(rows, pgx.RowToStructByPos[due])
		if err != nil {
			continue
		}
		for _, d := range names {
			n := d.Name
			if s.tokenOnly(ctx, n) {
				continue
			}
			by := "the hourly read"
			if d.Resweep {
				by = "the weekly sweep"
			}
			if _, err := s.syncSource(ctx, n, loopRead, "", by, true, d.Resweep); err != nil && ctx.Err() == nil {
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

// approveLogin: the authentication, login and password an approved (or tested) proposal's server is read with, or
// the words of why not. A login typed at the approve is used with its password; else the source's, else the
// proposal's own. The source's authentication unless one is picked (the panel sends a pick, a login typed or not:
// never a silent drop, the join's review 3c), mapped to the engine's: SQL Server never takes password / pgpass, and a
// cloud source's one SQL login is a password login on its PostgreSQL servers.
//   - PostgreSQL: pgvigil signs in with a password login only (no Entra token sign-in), so a source that signs in to
//     Azure as an Entra application or identity holds no PostgreSQL login - its secret never becomes one (the join's
//     review 3a): such a proposal is approved only with a PostgreSQL login typed.
//   - entra-identity (this host's managed identity, CLOUDSQL C1): no secret, and the login is a user-assigned
//     identity's client id - typed, or the source's own when the source signs in that way; never a SQL login of the
//     source or the proposal (a typed password reaches BuildDSN, which refuses it in its own words).
//   - a picked authentication with no login typed takes the source's own login only when it is that kind; else the
//     words name what is missing.
func approveLogin(engine, srcAuth, typedAuth, typedLogin, typedPassword string, cred sourceCred, proposalLogin, server string) (auth, login, password string, err error) {
	typed := typedLogin != ""
	if typed {
		login, password = typedLogin, typedPassword
	} else {
		login, password = cred.Login, cred.Password
		if login == "" {
			login = proposalLogin
		}
	}
	auth = srcAuth
	if typedAuth != "" {
		auth = typedAuth
	}
	picked := typedAuth != "" && !typed && typedAuth != srcAuth
	entra := func(a string) bool { return a == "entra" || a == "entra-identity" }
	switch engine {
	case config.EnginePostgres:
		if entra(auth) || (!typed && entra(srcAuth)) {
			if !typed {
				return "", "", "", fmt.Errorf("this source signs in to Azure as an Entra application or identity; pgvigil signs in to PostgreSQL with a password login only: type a PostgreSQL login for %s", server)
			}
			auth = "password"
		}
		if auth == "sql" {
			auth = "password" // a cloud source's one login is a password login on its PostgreSQL servers
		}
		if picked && auth == "password" && password == "" {
			return "", "", "", fmt.Errorf("a PostgreSQL login needs its password: the source holds none (it signs in as %s) - type the login and password for %s, or pick .pgpass", srcAuth, server)
		}
		if auth == "password" && password == "" {
			auth = "pgpass"
		}
	case config.EngineSQLServer:
		if auth == "password" || auth == "pgpass" {
			auth = "sql"
		}
		switch {
		case auth == "entra-identity":
			if !typed {
				login, password = "", ""
				if srcAuth == "entra-identity" {
					login = cred.Login
				}
			}
		case picked && auth == "sql":
			return "", "", "", fmt.Errorf("a SQL login needs its name and password: the source signs in as %s, not with a SQL login - type the login and password for %s", srcAuth, server)
		case picked && auth == "entra":
			return "", "", "", fmt.Errorf("an Entra service principal needs its application (client) id and secret: the source signs in as %s - type them for %s", srcAuth, server)
		case picked && auth == "windows":
			login, password = "", "" // the service's own account or a credential cache: no secret of the source's
		}
	}
	return auth, login, password, nil
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
	if op == "approve" || op == "test" {
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
		// a login typed at the approve (or its Test) stands for the source's: a cloud proposal carries none (its
		// master user is information only, task 205's design pass)
		if l := str(in, "login"); l != "" {
			cred.Login, cred.Password = l, rawStr(in, "password")
		}
		cloud := sr.Kind == "aws" || sr.Kind == "azure" || sr.Kind == "gcp"
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
			auth, l, pw, aerr := approveLogin(engine, sr.Auth, str(in, "auth"), str(in, "login"), rawStr(in, "password"), cred, orZero(login), server)
			if aerr != nil {
				writeErr(w, http.StatusConflict, aerr)
				return
			}
			cred.Password = pw
			pay["auth"] = auth
			pay["login_used"] = l
			extra := cred.Extra
			if cloud && engine == config.EnginePostgres && !strings.Contains(extra, "sslmode=") {
				// a cloud server is reached over TLS unless the source's options say otherwise (SQL Server's
				// encrypt=true is BuildDSN's own default)
				extra = strings.TrimSpace(extra + " sslmode=require")
			}
			dsn, err = config.BuildDSN(config.Conn{Engine: engine, Auth: auth, Host: host, Port: orZero(port), DBName: orZero(db), Login: l, Password: cred.Password, Extra: extra})
			if err != nil {
				writeErr(w, http.StatusConflict, err)
				return
			}
		}
		if op == "test" {
			// 204's connection test before the instance is made: nothing written but the audit row
			okc, detail := testConnection(ctx, engine, dsn)
			ans, _, err := s.callImport(ctx, "import_admin_proposal_test", map[string]any{"ui_user": user, "client": clientIP(r), "proposal_id": id, "ok": okc, "detail": detail})
			if err != nil || ans.Outcome != "done" {
				s.log.Warn("admin proposal: the test was not audited", "proposal", id, "err", err, "detail", ans.Detail)
			}
			s.reply(w, r, map[string]any{"ok": okc, "detail": detail}, nil)
			return
		}
		for _, k := range []string{"confirm_master", "confirm_autopause", "confirm_duplicate"} {
			if v, ok := in[k].(bool); ok && v {
				pay[k] = true
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
