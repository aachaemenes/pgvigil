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
	// SlackActions turns on the Slack door (task 403b K5): Acknowledge and Mute 1 h on a Slack bot's posts, POST
	// /api/slack/actions outside the UI login, for the apps listed under slack_apps:. Off by default.
	SlackActions bool `yaml:"slack_actions"`
	// PageCloudBlocks lets an instance of Admin > Instances (added on the page or approved from discovery) carry an
	// aws: or azure: block (task B24p): its cloud reads run under THIS collector host's own cloud identity, so they
	// are an admin's opt-in here (the locked-down default). Off by default: every page block is dropped
	// (its reason logged and on the page) and the instance keeps collecting.
	PageCloudBlocks bool `yaml:"page_cloud_blocks"`
	// PageAWSProfiles are the AWS profiles a page block may name (a discovered instance's source
	// profile); empty (the default) = none, the host's default chain only.
	PageAWSProfiles []string `yaml:"page_aws_profiles"`
	// PrometheusMetrics turns on GET /metrics on serve (B24d): every active instance's newest figures in the Prometheus
	// text format, read with a signed-in session or metrics.token. Off by default; off, /metrics answers 404 with
	// web.MetricsOff. What it opens: server names, engines, platforms, versions, every figure (tags and database names
	// when metrics.tags / metrics.databases are on), to everyone who reads that Prometheus and its remote_write targets.
	PrometheusMetrics bool `yaml:"prometheus_metrics"`
	// DiscoveryAutoAdd lets a cloud discovery source of Admin > Instances add the servers it finds by itself (RELNOTES
	// L237): each source then has its own switch, off until an admin ticks it. Off by default (the
	// locked-down default): every found server is a proposal a person approves.
	DiscoveryAutoAdd bool `yaml:"discovery_auto_add"`
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

// PageMSOptions lists the SQL Server options a page door opens with (docs and the page's note).
func PageMSOptions() []string { return sortedKeys(pageMSOptions) }

// PagePGOptions lists the PostgreSQL options a page door opens with (docs and the page's note).
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

func fileOnHost(name, key string) string {
	return "instance " + name + ": its driver option names a file on this server's host (" + key + "): Community tools and custom reports run on it only from pgvigil.yaml"
}

func ownSocket(name, host string) string {
	return "instance " + name + " signs in through this server's own socket (host '" + host + "'): Community tools and custom reports run on it only from pgvigil.yaml"
}

// optionRefusal: a key outside the lists refuses. fold: the driver reads its keys without case (go-mssqldb); pgx
// reads them as written, so an upper-case PostgreSQL key is a startup setting, never the allowed option
func optionRefusal(name, key, value string, allowed map[string]string, fold bool) string {
	k := strings.TrimSpace(key)
	if fold {
		k = strings.ToLower(k)
	}
	lk := strings.ToLower(k)
	switch {
	case lk == "sslrootcert" && value != "system":
		return fileOnHost(name, k)
	case pageIdentityOptions[lk] || strings.HasPrefix(lk, "krb5-"):
		return ownIdentity(name, k)
	case allowed[k] == "":
		return notOpened(name, k)
	}
	return ""
}

// pgHostRefusal: a host list pgx would read as this server's own socket - none at all (pgx's default is the local
// socket), an empty element, a path or an abstract socket ('@')
func pgHostRefusal(name, host string) string {
	if strings.TrimSpace(host) == "" {
		return ownSocket(name, host)
	}
	for _, h := range strings.Split(host, ",") {
		if h = strings.TrimSpace(h); h == "" || strings.HasPrefix(h, "/") || strings.HasPrefix(h, "@") {
			return ownSocket(name, host)
		}
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
			if why := optionRefusal(name, k, q.Get(k), pageMSOptions, true); why != "" {
				return why
			}
		}
	case EnginePostgres:
		switch auth {
		case "password":
		case "pgpass", "kerberos":
			return ownIdentity(name, auth)
		default:
			return "instance " + name + ": its authentication " + auth + " is not one a page door opens: Community tools and custom reports run on it only from pgvigil.yaml"
		}
		for _, f := range strings.Fields(x) {
			k, v, _ := strings.Cut(f, "=")
			if k == "host" || k == "hostaddr" || k == "port" || k == "dbname" {
				continue // BuildDSN leaves them out: the form's fields
			}
			if why := optionRefusal(name, k, v, pagePGOptions, false); why != "" {
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
				if strings.EqualFold(v, "ActiveDirectoryServicePrincipal") || strings.EqualFold(v, "ActiveDirectoryApplication") {
					continue
				}
				return ownIdentity(name, "fedauth="+v)
			}
			if why := optionRefusal(name, k, v, pageMSOptions, true); why != "" {
				return why
			}
		}
		if cfg.User == "" || cfg.Password == "" {
			return ownIdentity(name, "no login and password in its credential")
		}
	case EnginePostgres:
		if t := strings.TrimSpace(dsn); strings.HasPrefix(t, "postgres://") || strings.HasPrefix(t, "postgresql://") {
			// pgvigil writes the keyword form; a URL is a hand edit, and net/url and pgx part on ';' and '#'
			return "instance " + name + ": its credential is a URL, not the keyword form pgvigil writes: Community tools and custom reports run on it only from pgvigil.yaml"
		}
		kv, err := pgSettings(dsn)
		if err != nil {
			return "instance " + name + ": its credential does not read as a PostgreSQL connection string"
		}
		if why := pgHostRefusal(name, kv["host"]); why != "" {
			return why
		}
		for _, k := range sortedKeys(kv) {
			switch k {
			case "host", "port", "dbname", "user", "password":
				continue
			}
			if why := optionRefusal(name, k, kv[k], pagePGOptions, false); why != "" {
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
		if strings.ContainsAny(key, pgSpace+"'\\") {
			return nil, errSyntax
		}
		s = strings.TrimLeft(s[eq+1:], pgSpace)
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
			for ; i < len(s) && strings.IndexByte(pgSpace, s[i]) < 0; i++ {
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
		s = strings.TrimLeft(s, pgSpace)
	}
	return out, nil
}

// pgSpace is what pgx splits a keyword string at (pgconn config.go: unicode.IsSpace on the ASCII bytes)
const pgSpace = " \t\n\r\v\f"

// PGSettings is a keyword connection string as the page door's check reads it (serve compares pgx's own reading)
func PGSettings(dsn string) (map[string]string, error) { return pgSettings(dsn) }

type parseError string

func (e parseError) Error() string { return string(e) }

const (
	errDup    = parseError("a key is given twice")
	errSyntax = parseError("not keyword = value pairs")
)
