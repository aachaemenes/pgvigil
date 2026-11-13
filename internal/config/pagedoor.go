package config

// The read door of an instance added in Admin > Instances: Community tools and custom reports on serve, with the
// monitoring login the page stored. It is off unless pgvigil.yaml turns it on (Doors.PageInstanceReads), and it never
// opens for a sign-in that uses serve's own identity or for a driver option outside the lists below: a page instance
// can be added by any signed-in user, so its door may reach only the server and the login that user typed. An
// instance of pgvigil.yaml is not judged here.

import (
	"net/url"
	"sort"
	"strings"

	"github.com/microsoft/go-mssqldb/msdsn"
)

// Doors holds the switches of serve's doors that only pgvigil.yaml turns on, never the page. The site profile (task
// 330) will list each on Site settings: one switch per door in one named place, the file's off over the profile and
// the profile over the page.
type Doors struct {
	// PageInstanceReads turns on Community tools and custom reports for the instances added in Admin > Instances.
	// Off by default.
	PageInstanceReads bool `yaml:"page_instance_reads"`
}

// PageReadsOff is the refusal while the switch is off.
const PageReadsOff = "off on this install: doors.page_instance_reads in pgvigil.yaml turns on Community tools and custom reports for instances added in Admin > Instances"

// pageMSOptions: the SQL Server driver options (go-mssqldb's names, without case) a page door opens with - none names
// a file, a second server, a log or a sign-in.
var pageMSOptions = map[string]string{
	"database":               "the database the login opens",
	"encrypt":                "TLS on the wire",
	"trustservercertificate": "whether the server's certificate is checked",
	"hostnameincertificate":  "the name the server's certificate must carry",
	"tlsmin":                 "the lowest TLS version",
	"connection timeout":     "seconds",
	"dial timeout":           "seconds",
	"keepalive":              "seconds",
	"applicationintent":      "an availability group's read routing",
	"multisubnetfailover":    "every address of the same listener",
	"packet size":            "the TDS packet size",
}

// pagePGOptions: the PostgreSQL driver options (pgx's keywords) a page door opens with. sslrootcert only as 'system'
// (the operating system's CA store): a path is a file on serve's host.
var pagePGOptions = map[string]string{
	"sslmode":              "TLS on the wire",
	"sslrootcert":          "system only",
	"sslsni":               "the server name in TLS",
	"sslnegotiation":       "postgres or direct",
	"channel_binding":      "SCRAM channel binding",
	"connect_timeout":      "seconds",
	"target_session_attrs": "which server of a list",
}

// the options that name serve's own identity or a file on its host: the identity words, not the plain refusal
var pageIdentityOptions = map[string]bool{
	"authenticator": true, "fedauth": true, "serverspn": true, "failoverpartnerspn": true, "krbsrvname": true, "krbspn": true,
	"gssencmode": true, "passfile": true, "service": true, "servicefile": true, "sslkey": true, "sslcert": true, "sslpassword": true,
	"certificate": true, "servercertificate": true,
}

// PageMSOptions and PagePGOptions list the allowed options with their reasons (docs and the page's note).
func PageMSOptions() []string { return sortedKeys(pageMSOptions) }
func PagePGOptions() []string { return sortedKeys(pagePGOptions) }

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func ownIdentity(name, what string) string {
	return "instance " + name + " signs in with this server's own identity (" + what + "): Community tools and custom reports run on it only from pgvigil.yaml"
}

func notOpened(name, key string) string {
	return "instance " + name + ": its driver option " + key + " is not one a page door opens: Community tools and custom reports run on it only from pgvigil.yaml"
}

func optionRefusal(name, key, value string, allowed map[string]string) string {
	k := strings.ToLower(strings.TrimSpace(key))
	switch {
	case pageIdentityOptions[k] || strings.HasPrefix(k, "krb5-") || (k == "sslrootcert" && value != "system"):
		return ownIdentity(name, k)
	case allowed[k] == "":
		return notOpened(name, k)
	}
	return ""
}

// PageDoorRefusal says why a page instance's door does not open for the auth and options its row holds, "" when it
// may. It picks the words; PageDSNRefusal, on the credential's own connection string, is the check that holds.
func PageDoorRefusal(name, engine, auth, options string) string {
	x := strings.TrimSpace(options)
	switch engine {
	case EngineSQLServer:
		switch auth {
		case "sql", "entra":
		case "windows", "entra-identity":
			return ownIdentity(name, auth)
		default:
			return "instance " + name + ": its authentication " + auth + " is not one a page door opens: Community tools and custom reports run on it only from pgvigil.yaml"
		}
		if x == "" {
			return ""
		}
		q, err := url.ParseQuery(strings.TrimPrefix(x, "?"))
		if err != nil {
			return "instance " + name + ": its driver options do not read as name=value pairs: Community tools and custom reports run on it only from pgvigil.yaml"
		}
		for _, k := range sortedQueryKeys(q) {
			if lk := strings.ToLower(strings.TrimSpace(k)); lk == "server" || lk == "host" {
				continue // BuildDSN leaves them out: the host is the form's
			}
			if why := optionRefusal(name, k, q.Get(k), pageMSOptions); why != "" {
				return why
			}
		}
	case EnginePostgres:
		switch auth {
		case "password":
		case "pgpass":
			return ownIdentity(name, auth)
		default:
			return "instance " + name + ": its authentication " + auth + " is not one a page door opens: Community tools and custom reports run on it only from pgvigil.yaml"
		}
		for _, f := range strings.Fields(x) {
			k, v, _ := strings.Cut(f, "=")
			if k == "host" || k == "hostaddr" || k == "port" || k == "dbname" {
				continue // BuildDSN leaves them out: the form's fields
			}
			if why := optionRefusal(name, k, v, pagePGOptions); why != "" {
				return why
			}
		}
	default:
		return "instance " + name + ": engine " + engine + " has no page door"
	}
	return ""
}

func sortedQueryKeys(q url.Values) []string {
	out := make([]string, 0, len(q))
	for k := range q {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// PageDSNRefusal says why a page instance's resolved connection string does not open a door, "" when it may: its
// own keys (go-mssqldb's parser; a PostgreSQL keyword or URL string read as pgconn reads it) against the lists, a
// login and a password present in the string itself. A key it does not know refuses. The caller adds what only the
// driver's effective configuration shows (pgx's environment defaults).
func PageDSNRefusal(name, engine, dsn string) string {
	if strings.TrimSpace(dsn) == "" {
		return "instance " + name + ": its credential is not readable on this host"
	}
	switch engine {
	case EngineSQLServer:
		cfg, err := msdsn.Parse(dsn)
		if err != nil {
			return "instance " + name + ": its credential does not read as a SQL Server connection string"
		}
		for _, k := range sortedKeys(cfg.Parameters) {
			v := cfg.Parameters[k]
			switch k {
			case "user id", "password", "server", "port":
				continue
			case "fedauth":
				if strings.EqualFold(v, "ActiveDirectoryServicePrincipal") {
					continue
				}
				return ownIdentity(name, "fedauth="+v)
			}
			if why := optionRefusal(name, k, v, pageMSOptions); why != "" {
				return why
			}
		}
		if cfg.User == "" || cfg.Password == "" {
			return ownIdentity(name, "no login and password in its credential")
		}
	case EnginePostgres:
		kv, err := pgSettings(dsn)
		if err != nil {
			return "instance " + name + ": its credential does not read as a PostgreSQL connection string"
		}
		for _, k := range sortedKeys(kv) {
			switch k {
			case "host", "port", "dbname", "user", "password":
				continue
			}
			if why := optionRefusal(name, k, kv[k], pagePGOptions); why != "" {
				return why
			}
		}
		if kv["user"] == "" || kv["password"] == "" {
			return ownIdentity(name, "no login and password in its credential")
		}
	default:
		return "instance " + name + ": engine " + engine + " has no page door"
	}
	return ""
}

// pgSettings reads a PostgreSQL connection string as pgconn does: a URL (postgres:// or postgresql://, its query's
// keys) or keyword = value pairs, a value bare or in single quotes with backslash escapes. A key twice is an error.
func pgSettings(dsn string) (map[string]string, error) {
	out := map[string]string{}
	put := func(k, v string) error {
		if _, ok := out[k]; ok {
			return errDup
		}
		out[k] = v
		return nil
	}
	if strings.HasPrefix(dsn, "postgres://") || strings.HasPrefix(dsn, "postgresql://") {
		u, err := url.Parse(dsn)
		if err != nil {
			return nil, err
		}
		if u.User != nil {
			out["user"] = u.User.Username()
			if p, ok := u.User.Password(); ok {
				out["password"] = p
			}
		}
		out["host"] = u.Hostname()
		if p := u.Port(); p != "" {
			out["port"] = p
		}
		if db := strings.TrimPrefix(u.Path, "/"); db != "" {
			out["dbname"] = db
		}
		for k, vs := range u.Query() {
			if len(vs) != 1 {
				return nil, errDup
			}
			if err := put(k, vs[0]); err != nil {
				return nil, err
			}
		}
		return out, nil
	}
	s := strings.TrimSpace(dsn)
	for len(s) > 0 {
		eq := strings.IndexRune(s, '=')
		if eq < 1 {
			return nil, errSyntax
		}
		key := strings.TrimSpace(s[:eq])
		if strings.ContainsAny(key, " \t\n'\\") {
			return nil, errSyntax
		}
		s = strings.TrimLeft(s[eq+1:], " \t\n")
		var val strings.Builder
		if strings.HasPrefix(s, "'") {
			s = s[1:]
			closed := false
			for i := 0; i < len(s); i++ {
				switch c := s[i]; {
				case c == '\\' && i+1 < len(s):
					i++
					val.WriteByte(s[i])
				case c == '\'':
					s = s[i+1:]
					closed = true
				default:
					val.WriteByte(c)
				}
				if closed {
					break
				}
			}
			if !closed {
				return nil, errSyntax
			}
		} else {
			i := 0
			for ; i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\n'; i++ {
				if s[i] == '\\' && i+1 < len(s) {
					i++
				}
				val.WriteByte(s[i])
			}
			s = s[i:]
		}
		if err := put(key, val.String()); err != nil {
			return nil, err
		}
		s = strings.TrimLeft(s, " \t\n")
	}
	return out, nil
}

type parseError string

func (e parseError) Error() string { return string(e) }

const (
	errDup    = parseError("a key is given twice")
	errSyntax = parseError("not keyword = value pairs")
)
