// Inventory (task 204): the instances the collector runs are the file's (pgvigil.yaml, read-only in the page)
// and the page's (Admin > Instances, kept in the repository: 0122). The collector reads the page's list through
// pgvigil.admin_inventory() at start and again whenever pgvigil.admin_inventory_generation() moves (polled every
// 15 s), merges it with the file's (Merge) and starts or stops each instance's loops by Diff, so a change in the
// page reaches the running collector without a restart.
//
// A credential never enters the repository: serve writes it to a file of its own under the config folder
// (WriteSecret: mode 0600 on Linux, a DPAPI machine-scope blob on Windows) and the row keeps the reference
// (file:<path> or dpapi:<path>), which Resolve reads on every run.
//
// The list sources of a sync (a server list, a pg_service.conf, a CSV) are parsed here into proposals; the
// SQL Server sources (a CMS, a DBA Dash repository) are read by serve.

package config

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/csv"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

// PageInstance is one row of pgvigil.admin_inventory().
type PageInstance struct {
	Name     string
	Engine   string
	Platform string
	DSNRef   string
	Tags     []string
	Disabled bool
}

// InventoryReader is the repository's side: the generation alone (cheap, polled) and the list with its generation.
type InventoryReader interface {
	InventoryGeneration(ctx context.Context) (int64, error)
	Inventory(ctx context.Context) ([]PageInstance, int64, error)
}

var pageName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}$`)

// RefOK says whether v is a credential reference the page may store: file:<absolute path> or dpapi:<absolute path>.
func RefOK(v string) bool {
	for _, p := range []string{"file:", "dpapi:"} {
		if s, ok := strings.CutPrefix(v, p); ok {
			return filepath.IsAbs(s) || (len(s) > 2 && s[1] == ':' && (s[2] == '\\' || s[2] == '/'))
		}
	}
	return false
}

// Merge gives the file's instances, then the page's enabled ones the file does not name, each made an Instance the
// way Validate makes a file instance (platform auto when empty, the file-level query_text). A page instance that
// breaks a rule is left out with its reason in skipped (the page refuses those on write; this guards a hand edit).
func Merge(file []Instance, page []PageInstance, queryText string) (all []Instance, skipped []string) {
	all = append(all, file...)
	inFile := map[string]bool{}
	for _, in := range file {
		inFile[in.Name] = true
	}
	if queryText == "" {
		queryText = "full"
	}
	for _, p := range page {
		why := ""
		switch {
		case p.Disabled:
			continue
		case inFile[p.Name]:
			why = "pgvigil.yaml holds an instance of that name"
		case !pageName.MatchString(p.Name):
			why = "not a valid name"
		case p.Engine != EnginePostgres && p.Engine != EngineSQLServer:
			why = "unknown engine " + p.Engine
		case !RefOK(p.DSNRef):
			why = "its dsn reference is not file:/path or dpapi:/path"
		}
		for _, t := range p.Tags {
			if _, err := ParseTag(t); err != nil && why == "" {
				why = err.Error()
			}
		}
		if why != "" {
			skipped = append(skipped, p.Name+": "+why)
			continue
		}
		plat := p.Platform
		if plat == "" {
			plat = "auto"
		}
		all = append(all, Instance{Name: p.Name, Engine: p.Engine, Platform: plat, DSNRaw: p.DSNRef, Tags: slices.Clone(p.Tags), QueryText: queryText})
	}
	return all, skipped
}

// Fingerprint names what makes an instance's loops differ: a change in any of these restarts its loops.
func Fingerprint(in Instance) string {
	sch := make([]string, 0, len(in.Schedules))
	for k, v := range in.Schedules {
		sch = append(sch, k+"="+v.String())
	}
	sort.Strings(sch)
	dis := slices.Clone(in.Disabled)
	sort.Strings(dis)
	tags := slices.Clone(in.Tags)
	sort.Strings(tags)
	return strings.Join([]string{in.Engine, in.Platform, in.DSNRaw, in.QueryText, strings.Join(tags, ","), strings.Join(sch, ","), strings.Join(dis, ",")}, "\x1f")
}

// Diff names the instances to stop (gone or changed) and to start (new or changed), by name, each sorted.
func Diff(old, cur []Instance) (stop, start []string) {
	o := map[string]string{}
	for _, in := range old {
		o[in.Name] = Fingerprint(in)
	}
	n := map[string]string{}
	for _, in := range cur {
		n[in.Name] = Fingerprint(in)
	}
	for name, f := range o {
		if g, ok := n[name]; !ok || g != f {
			stop = append(stop, name)
		}
	}
	for name, f := range n {
		if g, ok := o[name]; !ok || g != f {
			start = append(start, name)
		}
	}
	sort.Strings(stop)
	sort.Strings(start)
	return stop, start
}

// WatchInventory reads the page's list at once and hands the merged list to apply, then polls the generation every
// `every` and hands a new merged list whenever it moved. A failed read keeps the last list (logged once per
// failure streak); apply is called from this goroutine only. It returns when ctx ends.
//
// hold (nil = always) says whether this collector holds the page's instances (one collector of a repository does:
// sched's page_inventory lock). One that does not collects the file's instances only, says so once, and asks again
// each tick: when the holder ends, the next to take the lock reads the page's list at once.
func WatchInventory(ctx context.Context, log *slog.Logger, src InventoryReader, hold func(context.Context) (bool, error), file []Instance, queryText string, every time.Duration, apply func([]Instance)) {
	if every <= 0 {
		every = 15 * time.Second
	}
	var have int64 = -1
	failing := false
	held, toldOther := true, false
	read := func() {
		var err error
		if hold != nil {
			var ok bool
			ok, err = hold(ctx)
			if err == nil && !ok {
				if !toldOther && ctx.Err() == nil {
					log.Warn("instances: the page's instances are not this collector's now (another collector holds them, or its lease could not be renewed); it collects the file's only (asked again every tick)")
					toldOther = true
				}
				if held || have == -1 { // lost the lock, or never had it: the file's list alone
					all, _ := Merge(file, nil, queryText)
					apply(all)
				}
				held, have, failing = false, -3, false
				return
			}
			if err == nil && !held {
				log.Info("instances: this collector holds the page's instances now")
				held, toldOther, have = true, false, -3
			}
		}
		var gen int64
		if err == nil {
			gen, err = src.InventoryGeneration(ctx)
		}
		if err == nil && gen == have {
			return
		}
		var page []PageInstance
		if err == nil {
			page, gen, err = src.Inventory(ctx)
		}
		if err != nil {
			if ctx.Err() == nil && !failing {
				log.Warn("instances: the page's list could not be read; the last list stays", "err", err)
			}
			failing = true
			if have == -1 { // the first read failed: run the file's instances meanwhile (once, not each tick)
				have = -2
				all, _ := Merge(file, nil, queryText)
				apply(all)
			}
			return
		}
		failing = false
		all, skipped := Merge(file, page, queryText)
		for _, s := range skipped {
			log.Warn("instances: a page instance is left out", "why", s)
		}
		log.Info("instances: list read", "generation", gen, "from_file", len(file), "from_page", len(all)-len(file))
		have = gen
		apply(all)
	}
	read()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			read()
		}
	}
}

// SecretDir is the folder the page's instance credential files live in: instances/ beside the config file.
func SecretDir(configPath string) string { return besideConfig(configPath, "instances") }

// SourceSecretDir is the folder of the sync sources' credential files: sources/ beside the config file (apart
// from the instances', so no source's file and no instance's file can share a name).
func SourceSecretDir(configPath string) string { return besideConfig(configPath, "sources") }

func besideConfig(configPath, sub string) string {
	abs, err := filepath.Abs(configPath)
	if err != nil {
		abs = configPath
	}
	return filepath.Join(filepath.Dir(abs), sub)
}

// WriteSecret stores value for the named instance (or source) in dir and returns its reference. Each write is a
// file of its own (<name>-<random>.dsn): a refused attempt removes its own file only, never one a concurrent write
// of the same name owns; the caller removes the previous file once the row names the new one. The file is written
// beside its final name and renamed over it, so a reader never sees half of it.
func WriteSecret(dir, name, value string) (string, error) {
	if !pageName.MatchString(name) {
		return "", fmt.Errorf("not a valid name for a credential file: %q", name)
	}
	if strings.TrimSpace(value) == "" {
		return "", errors.New("nothing to store")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	if err := prepareDir(dir); err != nil {
		return "", fmt.Errorf("the credential folder's access: %w", err)
	}
	var rnd [6]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return "", err
	}
	return writeSecret(dir, name+"-"+hex.EncodeToString(rnd[:]), value)
}

// RemoveSecret deletes the file a reference names when it lies in dir; a reference elsewhere is left alone.
func RemoveSecret(dir, ref string) error {
	_, p, ok := strings.Cut(ref, ":")
	if !ok || !strings.HasPrefix(ref, "file:") && !strings.HasPrefix(ref, "dpapi:") {
		return nil
	}
	rel, err := filepath.Rel(dir, p)
	if err != nil || strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		return nil
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// Conn is what the page or a source gives for one server; BuildDSN makes its connection string.
type Conn struct {
	Engine, Auth, Host string
	Port               int
	DBName, Login      string
	Password           string // never stored anywhere but the credential file
	Extra              string // a source's credential template's own keys (see BuildDSN)
}

// BuildDSN makes the connection string the collector opens.
//   - sqlserver, auth sql: sqlserver://login:password@host:port?database=db&encrypt=true&TrustServerCertificate=<extra's>
//   - sqlserver, auth windows: no login (go-mssqldb uses the service account: SSPI on Windows, Kerberos on Linux)
//   - sqlserver, auth entra: fedauth=ActiveDirectoryServicePrincipal (login = the application id, password = its secret)
//   - postgres, auth password: host=... port=... dbname=... user=... password='...'
//   - postgres, auth pgpass: no password (the service account's .pgpass or PGPASSFILE)
//
// Extra (a sqlserver query string or postgres keywords, from a source's credential file) is appended; it may set
// TrustServerCertificate or sslmode, never the host.
func BuildDSN(c Conn) (string, error) {
	if optionHoldsPassword(c.Extra) {
		return "", errors.New("the driver options hold no password: it goes in the password field, to its own file")
	}
	host := strings.TrimSpace(c.Host)
	if host == "" || strings.ContainsAny(host, " /?#@'\"") {
		return "", fmt.Errorf("not a host: %q", c.Host)
	}
	if c.Port < 0 || c.Port > 65535 {
		return "", fmt.Errorf("not a port: %d", c.Port)
	}
	switch c.Engine {
	case EngineSQLServer:
		// a named instance (host\name) is go-mssqldb's sqlserver://host/name
		h, inst, _ := strings.Cut(host, `\`)
		if c.Port > 0 {
			h += ":" + strconv.Itoa(c.Port)
		}
		u := url.URL{Scheme: "sqlserver", Host: h}
		if inst != "" {
			u.Path = "/" + inst
		}
		q := url.Values{}
		if c.DBName != "" {
			q.Set("database", c.DBName)
		}
		switch c.Auth {
		case "sql":
			if c.Login == "" || c.Password == "" {
				return "", errors.New("a SQL login needs its name and password")
			}
			u.User = url.UserPassword(c.Login, c.Password)
		case "windows":
			if c.Password != "" {
				return "", errors.New("a Windows account connects as the service's own account: no password is stored")
			}
		case "entra":
			if c.Login == "" || c.Password == "" {
				return "", errors.New("an Entra service principal needs its application id and secret")
			}
			u.User = url.UserPassword(c.Login, c.Password)
			q.Set("fedauth", "ActiveDirectoryServicePrincipal")
		default:
			return "", fmt.Errorf("auth %q is not a SQL Server one (sql, windows, entra)", c.Auth)
		}
		if x := strings.TrimSpace(c.Extra); x != "" {
			ex, err := url.ParseQuery(strings.TrimPrefix(x, "?"))
			if err != nil {
				return "", fmt.Errorf("the source's options: %w", err)
			}
			for k, vs := range ex {
				if strings.EqualFold(k, "server") || strings.EqualFold(k, "host") {
					continue
				}
				for _, v := range vs {
					q.Set(k, v)
				}
			}
		}
		if q.Get("encrypt") == "" {
			q.Set("encrypt", "true")
		}
		u.RawQuery = q.Encode()
		return u.String(), nil
	case EnginePostgres:
		kv := []string{"host=" + pq(host)}
		if c.Port > 0 {
			kv = append(kv, "port="+strconv.Itoa(c.Port))
		}
		db := c.DBName
		if db == "" {
			db = "postgres"
		}
		kv = append(kv, "dbname="+pq(db))
		switch c.Auth {
		case "password":
			if c.Login == "" || c.Password == "" {
				return "", errors.New("a PostgreSQL login needs its name and password")
			}
			kv = append(kv, "user="+pq(c.Login), "password="+pq(c.Password))
		case "pgpass":
			if c.Password != "" {
				return "", errors.New("auth pgpass reads the service account's .pgpass: no password is stored")
			}
			if c.Login != "" {
				kv = append(kv, "user="+pq(c.Login))
			}
		default:
			return "", fmt.Errorf("auth %q is not a PostgreSQL one (password, pgpass)", c.Auth)
		}
		if x := strings.TrimSpace(c.Extra); x != "" {
			for _, f := range strings.Fields(x) {
				k, _, _ := strings.Cut(f, "=")
				if k == "host" || k == "hostaddr" || k == "port" || k == "dbname" {
					continue
				}
				kv = append(kv, f)
			}
		}
		return strings.Join(kv, " "), nil
	}
	return "", fmt.Errorf("unknown engine %q", c.Engine)
}

// optionHoldsPassword says whether driver options name a password (they are stored in the repository as written).
func optionHoldsPassword(x string) bool {
	l := strings.ToLower(x)
	return strings.Contains(l, "password") || strings.Contains(l, "pwd")
}

// QuoteValue quotes a libpq keyword value (a path or a login with a space, a quote or a backslash).
func QuoteValue(v string) string { return pq(v) }

// pq quotes a libpq keyword value.
func pq(v string) string {
	if v != "" && !strings.ContainsAny(v, " '\\") {
		return v
	}
	return "'" + strings.ReplaceAll(strings.ReplaceAll(v, `\`, `\\`), `'`, `\'`) + "'"
}

// Proposal is one server a sync source holds.
type Proposal struct {
	Server      string   `json:"server"`
	Engine      string   `json:"engine"`
	Host        string   `json:"host"`
	Port        int      `json:"port,omitempty"`
	DBName      string   `json:"dbname,omitempty"`
	Login       string   `json:"login,omitempty"`
	DisplayName string   `json:"display_name,omitempty"`
	Tags        []string `json:"tags"`
}

// SplitHostPort reads "host", "host,port" (SQL Server's form), "host:port" and "[v6]:port"; a named instance
// (host\name) is kept whole.
func SplitHostPort(s string) (string, int) {
	s = strings.TrimSpace(s)
	// SQL Server's protocol prefix: tcp: is the default anyway (np: and lpc: are refused by NotTCP)
	if len(s) > 4 && strings.EqualFold(s[:4], "tcp:") {
		s = s[4:]
	}
	if h, p, ok := strings.Cut(s, ","); ok {
		if n, err := strconv.Atoi(strings.TrimSpace(p)); err == nil {
			return strings.TrimSpace(h), n
		}
	}
	if strings.HasPrefix(s, "[") {
		if i := strings.Index(s, "]:"); i > 0 {
			if n, err := strconv.Atoi(s[i+2:]); err == nil {
				return s[1:i], n
			}
		}
		return strings.Trim(s, "[]"), 0
	}
	if strings.Count(s, ":") == 1 {
		h, p, _ := strings.Cut(s, ":")
		if n, err := strconv.Atoi(p); err == nil {
			return h, n
		}
	}
	return s, 0
}

// NotTCP says whether a server name asks for a named pipe or shared memory (np:, lpc:), which the collector does not open.
func NotTCP(s string) bool {
	l := strings.ToLower(strings.TrimSpace(s))
	return strings.HasPrefix(l, "np:") || strings.HasPrefix(l, "lpc:")
}

// secretShaped says whether a line looks like a connection string or a credential rather than a server: an error
// about it names its line number only, and nothing of it reaches a proposal.
func secretShaped(l string) bool {
	return strings.ContainsAny(l, "=@") || strings.Contains(l, "://") || pgpassShaped(l)
}

// pgpassFields splits a line on ':' the way libpq reads .pgpass: a backslash makes the next character literal
// (\: is a colon inside a field, as in an IPv6 host).
func pgpassFields(l string) []string {
	var f []string
	var b strings.Builder
	esc := false
	for _, r := range l {
		switch {
		case esc:
			b.WriteRune(r)
			esc = false
		case r == '\\':
			esc = true
		case r == ':':
			f = append(f, b.String())
			b.Reset()
		default:
			b.WriteRune(r)
		}
	}
	return append(f, b.String())
}

// pgpassShaped: host:port:database:user:password, the port a number or '*' (a .pgpass line holds no '=' or '@');
// an IPv6 address is not one.
func pgpassShaped(l string) bool {
	if strings.HasPrefix(l, "[") || net.ParseIP(l) != nil { // a bracketed IPv6 host (with or without a port), a bare IPv6
		return false
	}
	f := pgpassFields(l)
	if len(f) < 5 || f[0] == "" || f[2] == "" || f[3] == "" {
		return false
	}
	if f[1] == "*" {
		return true
	}
	_, err := strconv.Atoi(f[1])
	return err == nil
}

// ParseServerList reads a server list for engine: a CSV whose first line names its columns (host is required;
// port, name, dbname, login, tags (space-separated) are read when present) or one server per line ("host",
// "host,port", "host:port"); '#' starts a comment. The server key is the line's host and port as written.
func ParseServerList(r io.Reader, engine string) ([]Proposal, error) {
	if engine != EnginePostgres && engine != EngineSQLServer {
		return nil, fmt.Errorf("unknown engine %q", engine)
	}
	b, err := io.ReadAll(io.LimitReader(r, 4<<20))
	if err != nil {
		return nil, err
	}
	var lines []string
	var lineNo []int // each kept line's number in the file
	for i, l := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		if t := strings.TrimSpace(l); t != "" && !strings.HasPrefix(t, "#") {
			lines = append(lines, t)
			lineNo = append(lineNo, i+1)
		}
	}
	if len(lines) == 0 {
		return nil, nil
	}
	var out []Proposal
	head := strings.ToLower(lines[0])
	if strings.Contains(head, ",") && slices.Contains(splitTrim(head), "host") {
		cr := csv.NewReader(strings.NewReader(strings.Join(lines, "\n")))
		cr.FieldsPerRecord = -1
		recs, err := cr.ReadAll()
		if err != nil {
			// csv's error quotes no field text, its line numbers count the kept lines
			return nil, errors.New("the CSV could not be read (a quote not closed?)")
		}
		col := map[string]int{}
		for i, h := range recs[0] {
			col[strings.ToLower(strings.TrimSpace(h))] = i
		}
		get := func(rec []string, k string) string {
			if i, ok := col[k]; ok && i < len(rec) {
				return strings.TrimSpace(rec[i])
			}
			return ""
		}
		for n, rec := range recs[1:] {
			for _, f := range rec {
				if secretShaped(f) {
					return nil, fmt.Errorf("the CSV line %d holds a connection string or a credential ('=', '@', '://' or a .pgpass line): not a server list", lineNo[n+1])
				}
			}
			h, p := SplitHostPort(get(rec, "host"))
			if h == "" {
				return nil, fmt.Errorf("the CSV line %d has no host", lineNo[n+1])
			}
			if NotTCP(get(rec, "host")) {
				return nil, fmt.Errorf("the CSV line %d names a named pipe or shared memory: TCP only", lineNo[n+1])
			}
			if ps := get(rec, "port"); ps != "" {
				v, err := strconv.Atoi(ps)
				if err != nil || v < 1 || v > 65535 {
					return nil, fmt.Errorf("the CSV line %d: the port is not a number from 1 to 65535", lineNo[n+1])
				}
				p = v
			}
			key := h
			if p > 0 {
				key += "," + strconv.Itoa(p)
			}
			out = append(out, Proposal{Server: key, Engine: engine, Host: h, Port: p, DBName: get(rec, "dbname"), Login: get(rec, "login"),
				DisplayName: get(rec, "name"), Tags: strings.Fields(get(rec, "tags"))})
		}
		return dedupe(out), nil
	}
	for n, l := range lines {
		if secretShaped(l) {
			return nil, fmt.Errorf("line %d holds a connection string or a credential ('=', '@', '://' or a .pgpass line host:port:database:user:password): not a server list", lineNo[n])
		}
		if NotTCP(l) {
			return nil, fmt.Errorf("line %d names a named pipe or shared memory: TCP only", lineNo[n])
		}
		h, p := SplitHostPort(l)
		if h == "" || strings.ContainsAny(h, " \t") {
			return nil, fmt.Errorf("line %d is not a server (one host, host,port or host:port)", lineNo[n])
		}
		out = append(out, Proposal{Server: l, Engine: engine, Host: h, Port: p, Tags: []string{}})
	}
	return dedupe(out), nil
}

func splitTrim(s string) []string {
	f := strings.Split(s, ",")
	for i := range f {
		f[i] = strings.TrimSpace(f[i])
	}
	return f
}

func dedupe(in []Proposal) []Proposal {
	seen := map[string]bool{}
	out := in[:0]
	for _, p := range in {
		if p.Tags == nil {
			p.Tags = []string{}
		}
		if !seen[p.Server] {
			seen[p.Server] = true
			out = append(out, p)
		}
	}
	return out
}

// ParsePgService reads a pg_service.conf: each [service] section with host (required), port, dbname and user;
// a password in the file is never read into a proposal (the approved instance connects with service=<name> and
// the file itself, so the password stays where it is). The server key is the service name.
func ParsePgService(r io.Reader) ([]Proposal, error) {
	sc := bufio.NewScanner(io.LimitReader(r, 4<<20))
	var out []Proposal
	var cur *Proposal
	flush := func() error {
		if cur == nil {
			return nil
		}
		if cur.Host == "" {
			return fmt.Errorf("service %s has no host", cur.Server)
		}
		out = append(out, *cur)
		cur = nil
		return nil
	}
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if l == "" || strings.HasPrefix(l, "#") || strings.HasPrefix(l, ";") {
			continue
		}
		if strings.HasPrefix(l, "[") && strings.HasSuffix(l, "]") {
			if err := flush(); err != nil {
				return nil, err
			}
			name := strings.TrimSpace(l[1 : len(l)-1])
			if name == "" {
				return nil, errors.New("an empty [service] name")
			}
			cur = &Proposal{Server: name, Engine: EnginePostgres, DisplayName: name, Tags: []string{}}
			continue
		}
		if cur == nil {
			continue
		}
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			continue
		}
		k, v = strings.ToLower(strings.TrimSpace(k)), strings.TrimSpace(v)
		switch k {
		case "host":
			cur.Host = v
		case "port":
			if n, err := strconv.Atoi(v); err == nil {
				cur.Port = n
			}
		case "dbname":
			cur.DBName = v
		case "user":
			cur.Login = v
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if err := flush(); err != nil {
		return nil, err
	}
	return dedupe(out), nil
}
