package main

import (
	"archive/zip"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"regexp"
	"runtime"
	"runtime/debug"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"gopkg.in/yaml.v3"

	"github.com/aachaemenes/pgvigil/internal/alerts"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// supportAddress is where a problem report goes; pgvigil never sends anything there itself.
const supportAddress = "support@pgvigil.com"

// maskedText stands in the report for every value that is not written.
const maskedText = "<masked>"

// runReport writes a problem report: a local zip of diagnostics with the secrets and the site's names taken out.
//
//	pgvigil report [-config pgvigil.yaml] [-out file.zip] [-dsn env:NAME] [-names] [-errors 200]
//
// The zip holds README.txt (what the files are), version.txt (this binary and its platform), config.yaml (the
// configuration file with every value masked except the settings of keepKeys), repository.txt (the repository's
// server version and migration level), instances.txt (engine, platform and version per instance) and
// collection-errors.txt (the collections whose last run failed and the newest rows of the collection log).
// Nothing is sent anywhere: the file stays where it is written until the operator mails it. A configuration that
// does not load or a repository that does not answer is written into the report as that fact; the zip is still made,
// since that is when a report is needed.
func runReport(ctx context.Context, args []string) error { return runReportTo(ctx, args, os.Stdout) }

func runReportTo(ctx context.Context, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("pgvigil report", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	path := fs.String("config", "pgvigil.yaml", "path to the configuration file")
	out := fs.String("out", "", "the zip to write (default pgvigil-report-<UTC time>.zip in this folder); an existing file is never replaced")
	dsn := fs.String("dsn", "", "repository connection string for the reads (or env:NAME / file:path); default the config's repository dsn")
	names := fs.Bool("names", false, "keep the instance names (default: instance-1, instance-2, ..., and the list is printed here only)")
	maxErr := fs.Int("errors", 200, "how many of the newest collection errors to include (1..5000)")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return &usageError{err}
	}
	if fs.NArg() > 0 {
		return &usageError{fmt.Errorf("report takes no argument (got %q)", fs.Arg(0))}
	}
	if *maxErr < 1 || *maxErr > 5000 {
		return &usageError{fmt.Errorf("-errors %d: 1..5000", *maxErr)}
	}
	now := time.Now().UTC()
	target := *out
	if target == "" {
		target = "pgvigil-report-" + now.Format("20060102-150405") + ".zip"
	}

	m := newMasker(*names)
	raw, readErr := os.ReadFile(*path)
	cfgText := m.config(raw, readErr)
	if strings.TrimSpace(*dsn) != "" {
		m.learn("dsn", config.Resolve(strings.TrimSpace(*dsn)))
	}
	check := "not checked: the file was not read"
	if readErr == nil {
		check = "ok"
		if err := checkConfig(*path, raw); err != nil {
			// the YAML reader quotes the start of a value that has the wrong type (`postgre...`): a cut value is no
			// value the masker knows, so whatever stands between backquotes goes
			check = reBackquoted.ReplaceAllString(err.Error(), "`"+maskedText+"`")
		}
	}
	repoDSN := m.repoDSN
	if strings.TrimSpace(*dsn) != "" {
		repoDSN = config.Resolve(strings.TrimSpace(*dsn))
	}
	r := m.readRepository(ctx, repoDSN, *maxErr)

	files := []reportFile{
		{"README.txt", readmeText(now, *names)},
		{"version.txt", versionText(now)},
		{"config.yaml", "# pgvigil report: the configuration file, masked. A value is shown only where it is a setting (an engine, an\n" +
			"# interval, a switch); every other value reads " + maskedText + ". Comments of the file are not copied.\n" +
			"# configuration check: " + oneLine(m.text(check), 600) + "\n" + cfgText},
		{"repository.txt", r.repository},
		{"instances.txt", r.instances},
		{"collection-errors.txt", r.errors},
	}
	// the last net under the files that carry text pgvigil did not write: no secret of the configuration is in them,
	// whichever line put it there. (README.txt and version.txt hold no such text, and config.yaml is written value by
	// value from the rules of scalar; a pass over those would only take apart a word that happens to equal a password.)
	for i := range files {
		switch files[i].name {
		case "repository.txt", "instances.txt", "collection-errors.txt":
			files[i].body = m.strict(files[i].body)
		}
	}
	size, err := writeZip(target, files, now)
	if err != nil {
		return err
	}
	list := make([]string, len(files))
	for i, f := range files {
		list[i] = f.name
	}
	fmt.Fprintf(stdout, "pgvigil report: wrote %s (%d files, %d bytes)\n  %s\n", target, len(files), size, strings.Join(list, ", "))
	if legend := m.legend(); len(legend) > 0 {
		fmt.Fprintln(stdout, "Instance names are written as the names on the left; this list is printed here only, it is not in the zip:")
		for _, l := range legend {
			fmt.Fprintln(stdout, "  "+l)
		}
	}
	fmt.Fprintf(stdout, "Nothing was sent. Read the files, then attach the zip to a mail to %s.\n", supportAddress)
	return nil
}

// checkConfig is what the commands check before they use the file: its shape, the collection names, the custom: list
// and the alerts: block. The first error is the answer.
func checkConfig(path string, raw []byte) error {
	cfg, err := config.Load(path)
	if err != nil {
		return err
	}
	if err := checkCollectionNames(cfg); err != nil {
		return err
	}
	if _, _, err := collect.ParseCustomChecks(raw, cfg.Instances); err != nil {
		return err
	}
	_, err = alerts.LoadFile(path)
	return err
}

// reportFile is one entry of the zip.
type reportFile struct{ name, body string }

// writeZip writes the files into a new zip readable by its owner alone and returns its size. An existing file is
// never replaced, and a zip that could not be finished is removed.
func writeZip(path string, files []reportFile, at time.Time) (int64, error) {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return 0, fmt.Errorf("report: %s exists already and is not replaced: name another file with -out", path)
		}
		return 0, fmt.Errorf("report: %w", err)
	}
	fail := func(err error) (int64, error) {
		_ = f.Close()
		_ = os.Remove(path)
		return 0, fmt.Errorf("report: %s: %w", path, err)
	}
	zw := zip.NewWriter(f)
	for _, rf := range files {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: rf.name, Method: zip.Deflate, Modified: at})
		if err != nil {
			return fail(err)
		}
		if _, err := io.WriteString(w, rf.body); err != nil {
			return fail(err)
		}
	}
	if err := zw.Close(); err != nil {
		return fail(err)
	}
	st, err := f.Stat()
	if err != nil {
		return fail(err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(path)
		return 0, fmt.Errorf("report: %s: %w", path, err)
	}
	return st.Size(), nil
}

func readmeText(at time.Time, names bool) string {
	inst := "Instance names are written as instance-1, instance-2, ... (the order of the configuration file); the command\nprinted which is which on the terminal, and that list is not in this zip."
	if names {
		inst = "Instance names are written as they are (the report was made with -names)."
	}
	return "pgvigil problem report, written " + at.Format(time.RFC3339) + " by 'pgvigil report'.\n\n" +
		"This zip was written to a local file. pgvigil sent it nowhere. To ask for help, read the files and attach the\n" +
		"zip to a mail to " + supportAddress + ". A security problem does not go by mail: report it privately through\n" +
		"the Security tab of the project's GitHub repository (Report a vulnerability).\n\n" +
		"The files:\n" +
		"  version.txt            this pgvigil binary, its Go toolchain, the operating system and the module versions\n" +
		"  config.yaml            the configuration file with every value masked except plain settings\n" +
		"  repository.txt         the repository's server version and its migration level\n" +
		"  instances.txt          engine, platform and server version of each instance the repository knows\n" +
		"  collection-errors.txt  the collections whose last run failed, and the newest errors of the collection log\n\n" +
		"What is never in it: a password, a connection string, a webhook address, a routing key, a host, user or\n" +
		"database name of the configuration, a tag, a statement's text, a row of monitored data.\n" +
		inst + "\n\n" +
		"Error text is kept as the server or the driver wrote it, with the configuration's values, addresses and\n" +
		"credentials taken out. A name the configuration does not hold (an object in a server's message, a host of an\n" +
		"instance another collector reads, a value shorter than four characters) can remain there: read\n" +
		"collection-errors.txt before you send it.\n"
}

// versionText is this binary and where it runs: the line of `pgvigil version`, the operating system's own name where
// it has a file for it, and the versions of the modules in the build. The host's name is not written.
func versionText(at time.Time) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\nwritten: %s\nos: %s %s, %d CPUs\n", versionLine(), at.Format(time.RFC3339), runtime.GOOS, runtime.GOARCH, runtime.NumCPU())
	if rel := osRelease(); rel != "" {
		fmt.Fprintf(&b, "os release: %s\n", rel)
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			switch s.Key {
			case "vcs.revision", "vcs.time", "vcs.modified", "GOFIPS140", "CGO_ENABLED":
				fmt.Fprintf(&b, "build %s: %s\n", s.Key, s.Value)
			}
		}
		for _, d := range bi.Deps {
			switch d.Path {
			case "github.com/jackc/pgx/v5", "github.com/microsoft/go-mssqldb", "gopkg.in/yaml.v3", "github.com/aws/aws-sdk-go-v2":
				fmt.Fprintf(&b, "module %s %s\n", d.Path, d.Version)
			}
		}
	}
	return b.String()
}

// osRelease is PRETTY_NAME of /etc/os-release (Linux); "" where there is none.
func osRelease() string {
	raw, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(raw), "\n") {
		if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
			return oneLine(strings.Trim(strings.TrimSpace(v), `"'`), 120)
		}
	}
	return ""
}

// ---- the masker

// keepKeys are the configuration keys whose value says how pgvigil is set up and names nothing of the site: an
// engine, a platform, an interval, a switch, a threshold. A value under any other key is written as <masked>, so a
// key this list does not know (a new one, a misspelt one) is masked, never shown.
var keepKeys = map[string]bool{
	"engine": true, "platform": true, "query_text": true, "interval": true, "explain_analyze": true, "hypo_index": true,
	"explain_timeout": true, "archive_warn_minutes": true, "latency_warn_secs": true, "region": true,
	// alerts:
	"kind": true, "min_severity": true, "quiet_hours": true, "timezone": true, "repeat": true, "recovery": true,
	"clear_after": true, "port": true, "tls": true, "format": true,
	// custom:
	"every": true, "rule": true, "compare": true, "warning": true, "critical": true,
}

// keepTrees are the keys under which every value is a setting: collection names with their intervals, threshold
// names with their numbers, action names, the tag keys the tree groups by.
var keepTrees = map[string]bool{"schedules": true, "mssql_thresholds": true, "disabled": true, "actions": true, "group_by": true}

// safeValue is the shape of a setting: a word, a number, a duration, a clock range, a time zone. A value of another
// shape under a kept key (an address, a connection string put there by mistake) is masked like the rest.
var safeValue = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 _.,:+/-]{0,63}$`)

var (
	identLike    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.-]{0,63}$`)
	envNameLike  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)
	reNumber     = regexp.MustCompile(`^[0-9.,:+-]+$`)
	reBackquoted = regexp.MustCompile("`[^`]*`")
)

// secretKey says whether a key's value is a credential or carries one: a connection string, a password, a webhook
// address (its path is the token), a routing key.
func secretKey(k string) bool {
	k = strings.ToLower(k)
	for _, w := range []string{"dsn", "pass", "pwd", "secret", "token", "key", "url", "credential", "auth", "sig", "pgbouncer"} {
		if strings.Contains(k, w) {
			return true
		}
	}
	return false
}

// plainWords are values that name nothing of a site; the text scrub leaves them (a database called postgres would
// otherwise take the word out of every message).
var plainWords = map[string]bool{"postgres": true, "localhost": true, "127.0.0.1": true, "master": true, "pgvigil": true,
	"pgbouncer": true, "true": true, "false": true, "none": true, "null": true, "disable": true, "require": true, "prefer": true}

// masker masks the configuration and remembers what it masked, so the same values are taken out of every other text
// of the report. secrets (passwords, connection strings, webhook addresses, the contents behind env: and file:) are
// taken out of every file; idents (hosts, users, database names, every other masked value) out of error text.
type masker struct {
	keepNames bool
	secrets   map[string]bool
	idents    map[string]bool
	alias     map[string]string // instance name -> instance-N (config order)
	order     []string          // the instance names in config order
	repoOnly  map[string]string // instance name the repository holds and the config does not -> its alias
	repoDSN   string            // the resolved repository.dsn ("" = not set or not resolved)
}

func newMasker(keepNames bool) *masker {
	return &masker{keepNames: keepNames, secrets: map[string]bool{}, idents: map[string]bool{}, alias: map[string]string{}, repoOnly: map[string]string{}}
}

// config returns the masked configuration file as YAML text, or a line saying why there is none.
func (m *masker) config(raw []byte, readErr error) string {
	if readErr != nil {
		var pe *os.PathError
		if errors.As(readErr, &pe) {
			return "# the configuration file was not read: " + pe.Err.Error() + "\n"
		}
		return "# the configuration file was not read\n"
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		// a file that is not YAML is not copied in any form: its lines may be anything
		return "# the configuration file is not valid YAML and is not copied: " + oneLine(m.text(err.Error()), 300) + "\n"
	}
	if doc.Kind == 0 {
		return "# the configuration file is empty\n"
	}
	m.walk(&doc, "", false)
	var b strings.Builder
	enc := yaml.NewEncoder(&b)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		return "# the masked configuration could not be written: " + oneLine(m.text(err.Error()), 300) + "\n"
	}
	_ = enc.Close()
	return b.String()
}

// walk masks the node in place. path is the dotted path of keys to it ("instances.[].dsn"); keep = it sits under a
// keepTrees key. Every comment is dropped: a commented-out line can hold anything.
func (m *masker) walk(n *yaml.Node, path string, keep bool) {
	n.HeadComment, n.LineComment, n.FootComment = "", "", ""
	switch n.Kind {
	case yaml.DocumentNode:
		for _, c := range n.Content {
			m.walk(c, path, keep)
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(n.Content); i += 2 {
			k, v := n.Content[i], n.Content[i+1]
			k.HeadComment, k.LineComment, k.FootComment = "", "", ""
			key := k.Value
			if k.Kind != yaml.ScalarNode || !identLike.MatchString(key) {
				// a key that is not a plain name (a line of something else read as a key) is not shown
				m.learn("", key)
				*k = yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "<masked-key>"}
				key = ""
			}
			sub := key
			if path != "" {
				sub = path + "." + key
			}
			if v.Kind == yaml.ScalarNode {
				m.scalar(v, sub, key, keep || keepTrees[key])
				continue
			}
			m.walk(v, sub, keep || keepTrees[key])
		}
	case yaml.SequenceNode:
		key := path[strings.LastIndexByte(path, '.')+1:]
		for _, c := range n.Content {
			if c.Kind == yaml.ScalarNode {
				m.scalar(c, path+".[]", key, keep)
				continue
			}
			m.walk(c, path+".[]", keep)
		}
	case yaml.ScalarNode:
		m.scalar(n, path, "", keep) // a file that is one bare value
	case yaml.AliasNode:
		// *name repeats a node that is masked where it is defined
	}
}

// scalar masks one value. key is the mapping key it sits under (a list's values: the list's key).
func (m *masker) scalar(v *yaml.Node, path, key string, keep bool) {
	v.HeadComment, v.LineComment, v.FootComment = "", "", ""
	val := v.Value
	// env:NAME and file:/path are an indirection only under the keys pgvigil resolves (a connection string, a webhook
	// address, a key, a mail login); anywhere else the same letters are data: a tag is written env:prod
	indirect := secretKey(key) || key == "username"
	set := func(text, note string) {
		*v = yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: text, LineComment: note, Anchor: v.Anchor}
	}
	switch {
	case path == "instances.[].name":
		name := strings.TrimSpace(val)
		if _, seen := m.alias[name]; !seen && name != "" {
			m.order = append(m.order, name)
			m.alias[name] = fmt.Sprintf("instance-%d", len(m.order))
		}
		if !m.keepNames {
			set(m.alias[name], "")
			if name == "" {
				set(maskedText, "")
			}
		}
	case val == "" || v.Tag == "!!null":
		// nothing to mask
	case (keep || keepKeys[key]) && safeValue.MatchString(val) && !strings.HasPrefix(val, "env:") && !strings.HasPrefix(val, "file:"):
		// a setting: shown as written
	case indirect && strings.HasPrefix(val, "env:"):
		name := strings.TrimPrefix(val, "env:")
		got := os.Getenv(name)
		if path == "repository.dsn" {
			m.repoDSN = got
		}
		m.learnSecret(got)
		if !envNameLike.MatchString(name) {
			m.learn("", name)
			set("env:"+maskedText, "")
			return
		}
		note := "set in the environment of this command"
		if got == "" {
			note = "NOT set in the environment of this command"
		}
		set(val, note)
	case indirect && strings.HasPrefix(val, "file:"):
		p := strings.TrimPrefix(val, "file:")
		got := config.Resolve(val)
		if path == "repository.dsn" {
			m.repoDSN = got
		}
		m.learnSecret(got)
		m.learn("", p)
		note := "the file was read"
		if got == "" {
			note = "the file was NOT read (missing, unreadable or empty)"
		}
		set("file:"+maskedText, note)
	default:
		if path == "repository.dsn" {
			m.repoDSN = val
		}
		m.learn(key, val)
		note := ""
		if strings.Contains(strings.ToLower(key), "dsn") || key == "pgbouncer" {
			note = "an inline connection string, keyword form"
			if strings.Contains(val, "://") {
				note = "an inline connection string, URL form"
			}
		}
		set(maskedText, note)
	}
}

// learn remembers a masked value: under a secret key the whole value is a secret and its parts are read as a
// connection string's; any other value is an identifier.
func (m *masker) learn(key, val string) {
	val = strings.TrimSpace(val)
	if val == "" {
		return
	}
	if secretKey(key) {
		m.learnSecret(val)
		return
	}
	if strings.Contains(val, "://") || strings.Contains(val, "=") {
		m.learnSecret(val) // an address or a connection string under a key that is not one's: read like one
		return
	}
	if !reNumber.MatchString(val) { // a bare number would take the same digits out of a port or a count in a message
		m.idents[val] = true
	}
}

// learnSecret remembers a credential-bearing value (a connection string, a webhook address, a key): the whole of it,
// each line of it, its password as a secret, its host, user and database names as identifiers.
func (m *masker) learnSecret(val string) {
	val = strings.TrimSpace(val)
	if val == "" {
		return
	}
	m.secrets[val] = true
	for _, line := range strings.Split(val, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			m.secrets[line] = true
		}
	}
	sec, ids := dsnParts(val)
	for _, s := range sec {
		if s != "" {
			m.secrets[s] = true
		}
	}
	for _, s := range ids {
		if s != "" && !reNumber.MatchString(s) { // a port (server=host,1433) is no name
			m.idents[s] = true
		}
	}
}

var (
	dsnPassKeys  = map[string]bool{"password": true, "pwd": true, "passwd": true, "sslpassword": true, "access token": true, "accesstoken": true}
	dsnIdentKeys = map[string]bool{"host": true, "hostaddr": true, "server": true, "data source": true, "addr": true, "address": true,
		"network address": true, "user": true, "user id": true, "uid": true, "username": true, "dbname": true, "database": true,
		"initial catalog": true, "passfile": true, "sslcert": true, "sslkey": true, "sslrootcert": true, "service": true}
	reKeyword = regexp.MustCompile(`([A-Za-z_]+)\s*=\s*('(?:[^'\\]|\\.)*'|[^\s]*)`)
)

// dsnParts reads a connection string in the forms the drivers take (a URL, PostgreSQL's keyword=value list, the
// key=value; list of ADO and ODBC) and returns its passwords and its host, user and database names. A value that is
// no connection string (a webhook address, a key) gives its URL parts or nothing.
func dsnParts(v string) (secrets, idents []string) {
	hosts := func(h string) {
		for _, p := range strings.FieldsFunc(h, func(r rune) bool { return r == ',' || r == '\\' }) {
			p = strings.TrimPrefix(strings.TrimSpace(p), "tcp:")
			idents = append(idents, p)
			if hp, _, ok := strings.Cut(p, ":"); ok {
				idents = append(idents, hp)
			}
		}
	}
	pair := func(k, val string) {
		k = strings.ToLower(strings.TrimSpace(k))
		switch {
		case val == "":
		case dsnPassKeys[k] || (secretKey(k) && !dsnIdentKeys[k]):
			secrets = append(secrets, val)
		case k == "host" || k == "hostaddr" || k == "server" || k == "data source" || k == "addr" || k == "address" || k == "network address":
			hosts(val)
		case dsnIdentKeys[k]:
			idents = append(idents, val)
		}
	}
	if i := strings.Index(v, "://"); i > 0 {
		rest := v[i+3:]
		// the raw userinfo first: a password with a character url.Parse refuses is still found
		auth := rest
		if e := strings.IndexAny(rest, "/?"); e >= 0 {
			auth = rest[:e]
		}
		at := strings.LastIndexByte(auth, '@')
		if at < 0 {
			if a := strings.IndexByte(rest, '@'); a >= 0 && strings.Contains(rest[:a], ":") {
				auth, at = rest[:a+1], a // a raw password holding '/' or '?' cut the authority short
			}
		}
		if at >= 0 {
			user, pass, has := strings.Cut(auth[:at], ":")
			idents = append(idents, user)
			if has {
				secrets = append(secrets, pass)
				if dec, err := url.PathUnescape(pass); err == nil {
					secrets = append(secrets, dec)
				}
			}
		}
		if u, err := url.Parse(v); err == nil {
			hosts(u.Host)
			idents = append(idents, u.Hostname(), strings.Trim(u.Path, "/"))
			if u.User != nil {
				idents = append(idents, u.User.Username())
				if p, ok := u.User.Password(); ok {
					secrets = append(secrets, p)
				}
			}
			for k, vals := range u.Query() {
				for _, val := range vals {
					pair(k, val)
				}
			}
			if strings.HasPrefix(u.Scheme, "http") && len(u.Path) > 1 {
				secrets = append(secrets, strings.TrimPrefix(u.RequestURI(), "/")) // a webhook's path and query are its token
			}
		}
	} else if strings.Contains(v, ";") {
		for _, seg := range strings.Split(strings.TrimPrefix(v, "odbc:"), ";") {
			if k, val, ok := strings.Cut(seg, "="); ok {
				val = strings.TrimSpace(val)
				if len(val) > 1 && val[0] == '{' && val[len(val)-1] == '}' {
					val = val[1 : len(val)-1]
				}
				pair(k, val)
			}
		}
	} else if strings.Contains(v, "=") {
		for _, g := range reKeyword.FindAllStringSubmatch(v, -1) {
			val := g[2]
			if len(val) > 1 && val[0] == '\'' {
				val = strings.NewReplacer(`\'`, `'`, `\\`, `\`).Replace(val[1 : len(val)-1])
			}
			pair(g[1], val)
		}
	}
	// what the PostgreSQL driver itself reads from the string (and from PGPASSWORD or a password file beside it)
	pgURL := strings.HasPrefix(v, "postgres://") || strings.HasPrefix(v, "postgresql://")
	pgKeyword := !strings.Contains(v, "://") && !strings.Contains(v, ";") && strings.Contains(v, "=")
	if pgURL || pgKeyword {
		if c, err := pgconn.ParseConfig(v); err == nil {
			secrets = append(secrets, c.Password)
			idents = append(idents, c.Host, c.User, c.Database)
			for _, f := range c.Fallbacks {
				idents = append(idents, f.Host)
			}
		}
	}
	return secrets, idents
}

// minMask is the shortest value the scrubs look for: a shorter one (a two-letter user) would take ordinary words apart.
const minMask = 4

// strict takes every secret out of a text, whatever word it is (a password "postgres" takes that word out too: the
// safe side).
func (m *masker) strict(s string) string {
	for _, v := range longestFirst(m.secrets) {
		if len(v) >= minMask {
			s = strings.ReplaceAll(s, v, maskedText)
		}
	}
	return s
}

var (
	reURLUser = regexp.MustCompile("([A-Za-z][A-Za-z0-9+.-]*://)[^/\\s@\"'`]*@")
	reURLPath = regexp.MustCompile("(https?://[^/\\s\"'`?#]+)[/?#][^\\s\"'`]*")
	reCred    = regexp.MustCompile(`(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|routing[_-]?key|signature|sig)(["']?\s*[=:]\s*)("[^"]*"|'[^']*'|\{[^}]*\}|[^\s;&,]+)`)
	reConnKey = regexp.MustCompile(`(?i)\b(host|hostaddr|server|data source|user|user id|uid|username|dbname|database|initial catalog)(\s*=\s*)('[^']*'|[^\s;,)` + "`" + `]+)`)
	reIPv4    = regexp.MustCompile(`\b(?:\d{1,3}\.){3}\d{1,3}\b`)
	reLookup  = regexp.MustCompile(`\blookup [^\s:]+`)
	reDialed  = regexp.MustCompile(`(:\d{1,5}) \([^)\s]+\)`)
)

// text scrubs a text pgvigil did not write itself (a server's or a driver's error): the configuration's secrets and
// identifiers, the instance names (as their aliases), then what looks like a credential or an address whatever its
// source: the userinfo and the path of a URL, a password= or token= value, a host= or user= value, an IPv4 address,
// the host of a failed lookup or dial.
func (m *masker) text(s string) string {
	s = m.strict(s)
	var kept []string // -names: the instance names, set aside while the identifiers go (a database "orders" inside "orders-db01")
	if m.keepNames {
		names := map[string]bool{}
		for n := range m.alias {
			names[n] = true
		}
		for _, n := range longestFirst(names) {
			if len(n) >= minMask && strings.Contains(s, n) {
				s = replaceWord(s, n, fmt.Sprintf("\x00%d\x00", len(kept)))
				kept = append(kept, n)
			}
		}
	}
	if !m.keepNames {
		names := map[string]bool{}
		for n := range m.alias {
			names[n] = true
		}
		for n := range m.repoOnly {
			names[n] = true
		}
		for _, n := range longestFirst(names) {
			if len(n) < minMask || plainWords[strings.ToLower(n)] {
				continue
			}
			a := m.alias[n]
			if a == "" {
				a = m.repoOnly[n]
			}
			s = replaceWord(s, n, a)
		}
	}
	for _, v := range longestFirst(m.idents) {
		if len(v) >= minMask && !plainWords[strings.ToLower(v)] && !(m.keepNames && m.alias[v] != "") {
			s = replaceWord(s, v, maskedText)
		}
	}
	s = reURLUser.ReplaceAllString(s, "${1}"+maskedText+"@")
	s = reURLPath.ReplaceAllString(s, "${1}/"+maskedText)
	s = reCred.ReplaceAllStringFunc(s, func(hit string) string {
		g := reCred.FindStringSubmatch(hit)
		if strings.HasPrefix(g[3], maskedText) {
			return hit // masked already; what follows it (a bracket, a quote) stays
		}
		return g[1] + g[2] + maskedText
	})
	s = reConnKey.ReplaceAllString(s, "${1}${2}"+maskedText)
	s = reIPv4.ReplaceAllStringFunc(s, func(ip string) string {
		if ip == "127.0.0.1" || ip == "0.0.0.0" {
			return ip
		}
		return "<ip>"
	})
	s = reLookup.ReplaceAllString(s, "lookup "+maskedText)
	s = reDialed.ReplaceAllString(s, "${1} ("+maskedText+")")
	for i, n := range kept {
		s = strings.ReplaceAll(s, fmt.Sprintf("\x00%d\x00", i), n)
	}
	return s
}

// replaceWord replaces old where it stands as a word of its own: not inside a longer run of letters, digits or '_'.
func replaceWord(s, old, repl string) string {
	if old == "" || !strings.Contains(s, old) {
		return s
	}
	wordChar := func(r rune) bool {
		return r == '_' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r > utf8.RuneSelf
	}
	var b strings.Builder
	for {
		i := strings.Index(s, old)
		if i < 0 {
			break
		}
		before, _ := utf8.DecodeLastRuneInString(s[:i])
		after, _ := utf8.DecodeRuneInString(s[i+len(old):])
		first, _ := utf8.DecodeRuneInString(old)
		last, _ := utf8.DecodeLastRuneInString(old)
		inside := (i > 0 && wordChar(before) && wordChar(first)) || (i+len(old) < len(s) && wordChar(after) && wordChar(last))
		if inside {
			b.WriteString(s[:i+len(old)])
		} else {
			b.WriteString(s[:i])
			b.WriteString(repl)
		}
		s = s[i+len(old):]
	}
	b.WriteString(s)
	return b.String()
}

func longestFirst(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for v := range set {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool {
		if len(out[i]) != len(out[j]) {
			return len(out[i]) > len(out[j])
		}
		return out[i] < out[j]
	})
	return out
}

// instanceName is how an instance is written in the report: its own name with -names, else its alias; an instance
// the repository holds and the configuration does not is instance-id<N>.
func (m *masker) instanceName(name string, id int32) string {
	if m.keepNames {
		return name
	}
	if a := m.alias[name]; a != "" {
		return a
	}
	if m.repoOnly[name] == "" {
		m.repoOnly[name] = fmt.Sprintf("instance-id%d", id)
	}
	return m.repoOnly[name]
}

// legend is the list of which alias is which instance, for the terminal only.
func (m *masker) legend() []string {
	if m.keepNames {
		return nil
	}
	out := make([]string, 0, len(m.order)+len(m.repoOnly))
	for _, n := range m.order {
		out = append(out, m.alias[n]+" = "+n)
	}
	rest := make([]string, 0, len(m.repoOnly))
	for n, a := range m.repoOnly {
		rest = append(rest, a+" = "+n+" (in the repository, not in this configuration file)")
	}
	sort.Strings(rest)
	return append(out, rest...)
}

// oneLine puts a text on one line, cut to max characters.
func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) > max {
		r := []rune(s)
		s = string(r[:max]) + " ... (cut)"
	}
	return s
}

// ---- the repository's part

type repoReport struct{ repository, instances, errors string }

// readRepository reads what the report says about the repository, each part by itself: a login that may not read a
// table (the collector's) still gives the server version and the migration level. Every read is read only and
// bounded (10 s to connect, 10 s a statement).
func (m *masker) readRepository(ctx context.Context, dsn string, maxErr int) repoReport {
	none := func(why string) repoReport {
		line := "not read: " + why + "\n"
		return repoReport{"repository: " + line, "instances: " + line, "collection errors: " + line}
	}
	if strings.TrimSpace(dsn) == "" {
		return none("no repository connection string (repository.dsn is not set, or its env: or file: gave nothing in the environment of this command)")
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return none("the connection string does not parse")
	}
	if cfg.ConnectTimeout <= 0 || cfg.ConnectTimeout > 10*time.Second {
		cfg.ConnectTimeout = 10 * time.Second
	}
	cfg.RuntimeParams["application_name"] = "pgvigil-report"
	cfg.RuntimeParams["default_transaction_read_only"] = "on"
	cfg.RuntimeParams["statement_timeout"] = "10000"
	cfg.RuntimeParams["lock_timeout"] = "2000"
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	conn, err := pgx.ConnectConfig(cctx, cfg)
	cancel()
	if err != nil {
		return none("no connection: " + oneLine(m.text(err.Error()), 600))
	}
	defer conn.Close(context.Background())
	why := func(err error) string {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "42501" {
			return "this login may not read it (the collector's login writes only): run the report with -dsn and the repository owner's or a reader's connection string"
		}
		return oneLine(m.text(err.Error()), 600)
	}

	var out repoReport
	var b strings.Builder
	var ver string
	var standby bool
	if err := conn.QueryRow(ctx, `SELECT current_setting('server_version'), pg_is_in_recovery()`).Scan(&ver, &standby); err != nil {
		fmt.Fprintf(&b, "repository server: not read: %s\n", why(err))
	} else {
		fmt.Fprintf(&b, "repository server: PostgreSQL %s%s\n", oneLine(ver, 80), map[bool]string{true: " (a standby)", false: ""}[standby])
	}
	// the migration level: through the collector's function, else from the table (a reader's login reads the table
	// and may not call the function)
	var have *string
	levelErr := conn.QueryRow(ctx, `SELECT pgvigil.schema_latest()`).Scan(&have)
	if levelErr != nil {
		if err := conn.QueryRow(ctx, `SELECT max(version) FROM pgvigil.schema_version`).Scan(&have); err == nil {
			levelErr = nil
		}
	}
	switch {
	case levelErr != nil:
		fmt.Fprintf(&b, "migration level: not read: %s\n", why(levelErr))
	case have == nil:
		fmt.Fprintf(&b, "migration level: none applied\n")
	default:
		fmt.Fprintf(&b, "migration level: %s\n", oneLine(*have, 120))
	}
	// this binary's own level (the newest migration it carries), and which of the two is ahead
	rctx, rcancel := context.WithTimeout(ctx, 15*time.Second)
	if r, err := repo.Open(rctx, dsn); err == nil {
		if _, latest, _ := r.SchemaCurrent(rctx); latest != "" {
			state := "the repository's level was not read"
			switch {
			case levelErr != nil:
			case have != nil && *have >= latest:
				state = "the repository is current"
			default:
				state = "the repository is behind this binary: run 'pgvigil migrate' as the repository owner"
			}
			fmt.Fprintf(&b, "this binary's newest migration: %s (%s)\n", latest, state)
		}
		r.Close()
	}
	rcancel()
	rows, err := conn.Query(ctx, `SELECT status, count(*) FROM pgvigil.collection_dates GROUP BY status ORDER BY status`)
	if err != nil {
		fmt.Fprintf(&b, "last runs by status: not read: %s\n", why(err))
	} else {
		var parts []string
		for rows.Next() {
			var st string
			var n int64
			if rows.Scan(&st, &n) == nil {
				parts = append(parts, fmt.Sprintf("%d %s", n, oneLine(m.text(st), 20)))
			}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			fmt.Fprintf(&b, "last runs by status: not read: %s\n", why(err))
		} else {
			if len(parts) == 0 {
				parts = []string{"none yet"}
			}
			fmt.Fprintf(&b, "last runs by status (one per instance and collection): %s\n", strings.Join(parts, ", "))
		}
	}
	out.repository = b.String()

	// instances first: their names become aliases before any error text is scrubbed
	b.Reset()
	rows, err = conn.Query(ctx, `SELECT instance_id, name, coalesce(engine, 'postgres'), platform, coalesce(server_version, ''), is_active, last_seen
  FROM pgvigil.instances ORDER BY instance_id`)
	if err != nil {
		fmt.Fprintf(&b, "instances: not read: %s\n", why(err))
	} else {
		b.WriteString("instance\tengine\tplatform\tserver_version\tactive\tlast_seen_utc\n")
		n := 0
		for rows.Next() {
			var id int32
			var name, engine, platform, sv string
			var active bool
			var seen time.Time
			if err := rows.Scan(&id, &name, &engine, &platform, &sv, &active, &seen); err != nil {
				continue
			}
			n++
			fmt.Fprintf(&b, "%s\t%s\t%s\t%s\t%t\t%s\n", m.instanceName(name, id), field(engine), field(platform), oneLine(sv, 120), active, seen.UTC().Format("2006-01-02 15:04"))
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			fmt.Fprintf(&b, "instances: not read to the end: %s\n", why(err))
		}
		fmt.Fprintf(&b, "%d instance(s)\n", n)
	}
	out.instances = b.String()

	b.Reset()
	for _, part := range []struct{ title, sql string }{
		{"The collections whose last run failed", `SELECT i.instance_id, i.name, c.collection, c.snapshot_at, coalesce(c.duration_ms, 0), coalesce(c.note, '')
  FROM pgvigil.collection_dates c JOIN pgvigil.instances i USING (instance_id)
 WHERE c.status = 'error' ORDER BY c.snapshot_at DESC, i.instance_id, c.collection LIMIT $1`},
		{"The newest errors of the collection log", `SELECT i.instance_id, i.name, l.collection, l.snapshot_at, coalesce(l.duration_ms, 0), coalesce(l.note, '')
  FROM pgvigil.collection_log l JOIN pgvigil.instances i USING (instance_id)
 WHERE l.status = 'error' ORDER BY l.snapshot_at DESC, l.log_id DESC LIMIT $1`},
	} {
		fmt.Fprintf(&b, "%s (at most %d, the newest first)\n", part.title, maxErr)
		rows, err := conn.Query(ctx, part.sql, maxErr)
		if err != nil {
			fmt.Fprintf(&b, "not read: %s\n\n", why(err))
			continue
		}
		b.WriteString("instance\tcollection\tat_utc\tduration_ms\tnote\n")
		type errRow struct {
			id               int32
			name, coll, note string
			at               time.Time
			ms               int32
		}
		var list []errRow
		for rows.Next() {
			var e errRow
			if rows.Scan(&e.id, &e.name, &e.coll, &e.at, &e.ms, &e.note) == nil {
				list = append(list, e)
			}
		}
		rows.Close()
		// every name is known as its alias before the first note is scrubbed
		for _, e := range list {
			m.instanceName(e.name, e.id)
		}
		for _, e := range list {
			fmt.Fprintf(&b, "%s\t%s\t%s\t%d\t%s\n", m.instanceName(e.name, e.id), field(e.coll), e.at.UTC().Format("2006-01-02 15:04:05"), e.ms, oneLine(m.text(e.note), 2000))
		}
		if err := rows.Err(); err != nil {
			fmt.Fprintf(&b, "not read to the end: %s\n", why(err))
		}
		fmt.Fprintf(&b, "%d row(s)\n\n", len(list))
	}
	out.errors = b.String()
	return out
}

// field is a repository value that should be a plain word (an engine, a platform, a collection's name); one that is
// not is masked.
func field(s string) string {
	if s == "" || safeValue.MatchString(s) {
		return s
	}
	return maskedText
}
