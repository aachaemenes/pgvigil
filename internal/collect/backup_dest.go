package collect

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

// backup_dest (task 302): where a self-managed PostgreSQL server's WAL and base backups go, read from the server's own
// archive_command, archive_library and restore_command (every role that logs in reads them with SHOW: they carry no
// GUC_SUPERUSER_ONLY flag), and - behind the per-instance opt-in `backups: read_tools: true` - from the backup tool's
// configuration on the collector's host. A destination is BUILT from pieces that each pass a plain pattern (a scheme,
// a host, a port, a path, a bucket, a stanza or server name); the command's text is never stored, a credential never
// read into a value.
//
// THE LEXER (written before the first test row; 302's design pass finding 4). A command is cut into segments and
// words as a POSIX shell would cut a plain line, and refused where a shell would do more than cut it:
//
//   - The input is capped at 8 KB: a longer value is 'not known: too long' (Go's regexp is linear, so the cap bounds
//     the time too).
//   - Words are split on blanks (space, tab) outside quotes. A newline anywhere is 'not known: a newline in the
//     command' for the whole command (a second line is a second command no pattern here reads).
//   - Single and double quotes are accepted around a literal only: the quotes go, the text between them is the
//     word's. A '$' or a backtick inside a word, quoted or not (a variable, $( ), a command substitution), TAINTS the
//     word: a tainted word is never kept - a destination built from it is 'not known' - but it is still read for its
//     name (an option's name before '=' or a variable's name) so a secret-shaped name sets secret_seen. A command
//     substitution ('$(' or a backtick, quoted or not) makes its whole SEGMENT 'not known: a command substitution'
//     (what it prints can be any word, even one the lexer cut apart). An unclosed quote is 'not known: an unclosed
//     quote' for the whole command.
//   - A backslash is a literal character (Windows paths: `copy "%p" "C:\server\archivedir\%f"` - the documented
//     example as the server holds it); it escapes nothing.
//   - Outside quotes, '&&', '||', ';', '|' and a lone '&' end a segment; each segment is read alone and is a row of
//     its own (seq 1, 2, ...). '<', '>', '>>' and '>&' outside quotes are words of their own: a redirect's target is
//     the word after it (`2>&1` is the words '2', '>&', '1').
//   - A segment's leading wrappers are peeled, in any order, before its program is named: `timeout [-s SIG] [-k D] N`,
//     `nice [-n N]`, `ionice [-c N] [-n N]`, `sudo [-u USER] [-E]`, `flock [-w N] [-x|-s|-n] FILE`, `exec`,
//     `env [-i] [NAME=VALUE ...]`, and leading NAME=VALUE assignments (a shell's own). An assignment is kept only when
//     its name is one the shapes read (WALG_*_PREFIX, WALE_*_PREFIX, PGBACKREST_REPOn_* where-options); a
//     secret-shaped name sets secret_seen and its value is dropped unread.
//   - The program is the basename of the segment's first word after the wrappers.
//
// lexCommand returns the segments, or the reason the whole command is 'not known'.

const backupDestMaxInput = 8 << 10

// lexWord is one word of a segment: its text with the quotes gone, and whether a '$' or a backtick made it unusable.
type lexWord struct {
	text    string
	tainted bool
	subst   bool // a '$(' or a backtick: the segment is not known
}

// lexCommand cuts cmd into segments of words by the rules above; why is non-empty when the whole command is 'not known'.
func lexCommand(cmd string) (segs [][]lexWord, why string) {
	if len(cmd) > backupDestMaxInput {
		return nil, "not known: too long"
	}
	if strings.ContainsAny(cmd, "\n\r") {
		return nil, "not known: a newline in the command"
	}
	var cur []lexWord
	var w strings.Builder
	inWord, tainted, subst := false, false, false
	endWord := func() {
		if inWord {
			cur = append(cur, lexWord{text: w.String(), tainted: tainted, subst: subst})
		}
		w.Reset()
		inWord, tainted, subst = false, false, false
	}
	endSeg := func() {
		endWord()
		if len(cur) > 0 {
			segs = append(segs, cur)
		}
		cur = nil
	}
	for i := 0; i < len(cmd); i++ {
		c := cmd[i]
		switch c {
		case '\'', '"':
			j := strings.IndexByte(cmd[i+1:], c)
			if j < 0 {
				return nil, "not known: an unclosed quote"
			}
			lit := cmd[i+1 : i+1+j]
			if strings.ContainsAny(lit, "$`") {
				tainted = true
			}
			if c == '"' && (strings.Contains(lit, "$(") || strings.Contains(lit, "`")) {
				subst = true
			}
			w.WriteString(lit)
			inWord = true
			i += j + 1
		case ' ', '\t':
			endWord()
		case ';':
			endSeg()
		case '&', '|':
			if i+1 < len(cmd) && cmd[i+1] == c {
				i++
			}
			endSeg()
		case '<', '>':
			endWord()
			op := string(c)
			if c == '>' && i+1 < len(cmd) && (cmd[i+1] == '>' || cmd[i+1] == '&') {
				op += string(cmd[i+1])
				i++
			}
			cur = append(cur, lexWord{text: op})
		default:
			if c == '$' || c == '`' {
				tainted = true
			}
			if c == '`' || c == '$' && i+1 < len(cmd) && cmd[i+1] == '(' {
				subst = true
			}
			w.WriteByte(c)
			inWord = true
		}
	}
	endSeg()
	return segs, ""
}

// backupDest is one destination a command, a library or a tool's configuration names. Every kept field passed a plain
// pattern; detail carries pgvigil's own words (the stanza, the server, why a destination is 'not known').
type backupDest struct {
	role       string // wal | restore | base
	seq        int    // the segment's place in its command (1 for a library or a tool's configuration)
	source     string // archive_command | archive_library | restore_command | pgbackrest configuration | barman
	tool       string // pgbackrest | barman | barman-cloud | wal-g | wal-e | aws | gsutil | gcloud | az | azcopy | s3cmd | rclone | mc | rsync | scp | copy | basic_archive | library | script
	kind       string // posix | s3 | gcs | azure | https | host | rsync-module | rclone-remote | mc-alias | discard
	host       string
	container  string // a bucket, a blob container, an rsync module, an rclone remote, an mc alias
	path       string
	repoKey    string // repo1 ... (pgBackRest)
	detail     string
	secretSeen bool
}

var (
	reDestHost   = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)
	reDestPort   = regexp.MustCompile(`^[0-9]{1,5}$`)
	reDestPath   = regexp.MustCompile(`^/[A-Za-z0-9._~/@+,=-]*$`)
	reDestWin    = regexp.MustCompile(`^[A-Za-z]:\\[A-Za-z0-9._~\\ $-]*$|^\\\\[A-Za-z0-9._-]+\\[A-Za-z0-9._~\\ $-]*$`)
	reDestBucket = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$`)
	reDestPrefix = regexp.MustCompile(`^(?:WALG|WALE)_(S3|GS|AZ|OSS|SWIFT|FILE|SSH)_PREFIX$`)
	// a secret-shaped name, after the case is folded, '_' made '-', the leading dashes and a pgBackRest repoN- dropped
	reSecretWord = regexp.MustCompile(`(?:^|-)(?:password|passwd|pwd|pass|passphrase|secret|token|sas|credentials?)(?:$|-)`)
	secretNames  = map[string]bool{"account-key": true, "s3-key": true, "azure-key": true, "gcs-key": true, "access-key": true,
		"libsodium-key": true, "pgp-key": true, "connection-string": true, "storage-key": true, "walg-libsodium-key": true, "walg-pgp-key": true,
		"azure-storage-key": true, "azure-storage-access-key": true}
	reRepoN      = regexp.MustCompile(`^(?:pgbackrest-)?repo[0-9]+-`)
	reDestScheme = regexp.MustCompile(`^[a-z][a-z0-9+.-]{0,15}$`)
	reEnvName    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)
	// a barman retention policy as its docs write one ('RECOVERY WINDOW OF 4 WEEKS', 'REDUNDANCY 2')
	reBarmanPolicy = regexp.MustCompile(`^[A-Za-z0-9 ]{1,64}$`)
)

// secretName says whether an option's or a variable's name is one whose value is a credential. Exact words only: the
// never-flag list (a key's id, type, name or file, StrictHostKeyChecking, PubkeyAuthentication) never is.
func secretName(name string) bool {
	n := strings.ToLower(strings.TrimLeft(name, "-"))
	n = strings.ReplaceAll(n, "_", "-")
	n = reRepoN.ReplaceAllString(n, "")
	for _, never := range []string{"-key-id", "-key-type", "-key-name", "-key-file", "-token-file", "-password-file", "-pass-file"} {
		if strings.HasSuffix(n, never) {
			return false
		}
	}
	if strings.Contains(n, "keychecking") || strings.HasPrefix(n, "pubkey") || n == "sse-customer-key" {
		return false
	}
	// password, passwd and secret are never benign inside a name (PGPASSWORD, dbpassword); token, pass, key only as words
	return secretNames[n] || reSecretWord.MatchString(n) || strings.Contains(n, "password") || strings.Contains(n, "passwd") || strings.Contains(n, "secret")
}

// destPathOf is the directory of a word that holds %f (the file the archiver writes), or the word itself when it names a
// directory (a trailing '/'): a POSIX or a Windows path that passes its pattern, else "".
func destPathOf(w string) string {
	sep := "/"
	if strings.Contains(w, `\`) && !strings.Contains(w, "/") {
		sep = `\`
	}
	if i := strings.LastIndex(w, sep); i >= 0 && strings.Contains(w[i+1:], "%f") {
		w = w[:i]
		if w == "" {
			w = sep
		}
	} else if strings.Contains(w, "%") {
		return ""
	}
	if w != "/" && sep == "/" {
		w = strings.TrimRight(w, "/")
	}
	if reDestPath.MatchString(w) || w == "/" || reDestWin.MatchString(w) {
		return w
	}
	return ""
}

// destURL splits scheme://[userinfo@]host[:port]/path[?query] into what may be kept: userinfo and the query go (a
// password or a signature in either sets secret), the %f component goes from the path. ok is false when a piece fails.
func destURL(u string) (scheme, host, path string, secret, ok bool) {
	scheme, rest, found := strings.Cut(u, "://")
	if !found || !reDestScheme.MatchString(scheme) {
		return "", "", "", false, false
	}
	if q := strings.IndexByte(rest, '?'); q >= 0 {
		ql := strings.ToLower(rest[q:])
		secret = strings.Contains(ql, "sig=") || strings.Contains(ql, "signature") || strings.Contains(ql, "credential") || strings.Contains(ql, "token")
		rest = rest[:q]
	}
	hostPart, p, _ := strings.Cut(rest, "/")
	if at := strings.LastIndexByte(hostPart, '@'); at >= 0 {
		secret = secret || strings.Contains(hostPart[:at], ":")
		hostPart = hostPart[at+1:]
	}
	h, port, hasPort := strings.Cut(hostPart, ":")
	if !reDestHost.MatchString(h) || (hasPort && !reDestPort.MatchString(port)) {
		return "", "", "", secret, false
	}
	host = hostPart
	if p != "" {
		if path = destPathOf("/" + p); path == "" {
			return "", "", "", secret, false
		}
	}
	return scheme, host, path, secret, true
}

// destSeg is one segment after its wrappers: the program's words, the assignments a shape may read (their words, a
// tainted one included), the envdir a daemontools wrapper names, and whether a secret was seen on the way.
type destSeg struct {
	words   []lexWord
	assigns map[string]lexWord
	envdir  lexWord
	secret  bool
}

// wrapperValueOpts are the wrappers' options that take the next word as their value.
var wrapperValueOpts = map[string]map[string]bool{
	"timeout": {"-s": true, "--signal": true, "-k": true, "--kill-after": true},
	"nice":    {"-n": true, "--adjustment": true},
	"ionice":  {"-c": true, "--class": true, "-n": true, "--classdata": true, "-p": true},
	"sudo":    {"-u": true, "--user": true, "-g": true, "--group": true, "-C": true, "-D": true, "-h": true, "-p": true},
	"flock":   {"-w": true, "--timeout": true, "-E": true, "--conflict-exit-code": true},
	"exec":    {"-a": true},
	"env":     {"-u": true, "--unset": true, "-C": true, "--chdir": true},
	"sshpass": {"-p": true, "-f": true, "-d": true},
}

// peelSegment removes a segment's leading wrappers and NAME=VALUE assignments (the header's list).
func peelSegment(ws []lexWord) destSeg {
	d := destSeg{assigns: map[string]lexWord{}}
	for len(ws) > 0 {
		w := ws[0].text
		if name, val, ok := strings.Cut(w, "="); ok && reEnvName.MatchString(name) && !strings.HasPrefix(w, "-") {
			if secretName(name) {
				d.secret = true
			} else {
				d.assigns[name] = lexWord{text: val, tainted: ws[0].tainted}
			}
			ws = ws[1:]
			continue
		}
		prog := path.Base(w)
		opts, isWrapper := wrapperValueOpts[prog]
		if !isWrapper && prog != "envdir" {
			break
		}
		ws = ws[1:]
		if prog == "envdir" {
			if len(ws) > 0 {
				d.envdir, ws = ws[0], ws[1:]
			}
			continue
		}
		for len(ws) > 0 && strings.HasPrefix(ws[0].text, "-") && ws[0].text != "-" {
			o := ws[0].text
			if prog == "sshpass" && (o == "-p" || strings.HasPrefix(o, "-p") && len(o) > 2) {
				d.secret = true
			}
			ws = ws[1:]
			if opts[o] && len(ws) > 0 {
				ws = ws[1:]
			}
		}
		switch prog {
		case "timeout":
			if len(ws) > 0 { // the duration
				ws = ws[1:]
			}
		case "flock":
			if len(ws) > 0 { // the lock file
				ws = ws[1:]
			}
		}
	}
	d.words = ws
	return d
}

// optSplit reads an option word: its name and, when it carries one with '=', its value.
func optSplit(w string) (name, val string, hasVal bool) {
	if !strings.HasPrefix(w, "-") {
		return "", "", false
	}
	return strings.Cut(w, "=")
}

// destFromURLWord turns a URL word into a destination: s3://bucket/path and gs://bucket/path keep the bucket as the
// container; any other scheme keeps its host. ok is false when the word is tainted or a piece fails its pattern.
func destFromURLWord(d *backupDest, w lexWord) bool {
	if w.tainted {
		return false
	}
	scheme, host, p, secret, ok := destURL(w.text)
	d.secretSeen = d.secretSeen || secret
	if !ok {
		return false
	}
	switch scheme {
	case "s3", "gs":
		d.kind = map[string]string{"s3": "s3", "gs": "gcs"}[scheme]
		d.container, d.path = host, p
	case "azure":
		d.kind, d.host, d.path = "azure", host, p
	case "https", "http":
		d.kind, d.host, d.path = scheme, host, p
		if strings.HasSuffix(strings.ToLower(strings.Split(host, ":")[0]), ".blob.core.windows.net") {
			d.kind = "azure"
		}
	case "ssh", "sftp":
		d.kind, d.host, d.path = scheme, host, p
	default:
		d.kind, d.host, d.path = scheme, host, p
	}
	return true
}

// noRowProgs are a command's helpers that name no destination (a guard, a directory made first): no row.
var noRowProgs = map[string]bool{"test": true, "[": true, "[[": true, "mkdir": true, "chmod": true, "chown": true, "sync": true, "echo": true, "printf": true, "logger": true, "sleep": true}

// barmanWALValueOpts are barman-wal-archive / -restore 3.20.1's options that take a value (its synopsis); the flags
// beside them take none. An option in neither list makes the line 'not known' (reBarmanWAL's old swallow case).
var (
	barmanWALValueOpts = map[string]bool{"-U": true, "--user": true, "--port": true, "--compression-level": true, "-c": true, "--config": true,
		"-p": true, "--parallel": true, "--prefetch-cache-dir": true, "-s": true, "--sleep": true, "--spool-dir": true}
	barmanWALFlags = map[string]bool{"-z": true, "--gzip": true, "-j": true, "--bzip2": true, "--xz": true, "--snappy": true, "--zstd": true, "--lz4": true,
		"-t": true, "--test": true, "--md5": true, "-P": true, "--partial": true, "--keep-compression": true, "-q": true, "--quiet": true, "-h": true, "-V": true}
	rsyncValueOpts = map[string]bool{"-e": true, "--rsh": true, "--rsync-path": true, "--port": true, "--password-file": true, "--timeout": true, "--contimeout": true,
		"--bwlimit": true, "--chmod": true, "--chown": true, "--log-file": true, "--exclude": true, "--include": true, "--filter": true, "-f": true, "--temp-dir": true,
		"-T": true, "--partial-dir": true, "--backup-dir": true, "--suffix": true, "--compress-level": true, "--skip-compress": true, "--max-size": true,
		"--min-size": true, "--out-format": true, "--iconv": true, "-B": true, "--block-size": true}
	scpValueOpts = map[string]bool{"-i": true, "-P": true, "-o": true, "-F": true, "-c": true, "-l": true, "-S": true, "-J": true}
)

// positional is the words of a program that are not options or an option's value (valueOpts: the options that take the
// next word); every option's name passes the secret rule.
func positional(ws []lexWord, valueOpts map[string]bool, d *backupDest) []lexWord {
	var out []lexWord
	for i := 0; i < len(ws); i++ {
		w := ws[i]
		if name, val, hasVal := optSplit(w.text); name != "" {
			if secretName(name) {
				d.secretSeen = true
			}
			if name == "-o" || name == "--option" { // an ssh option: its own name
				if !hasVal && i+1 < len(ws) {
					val = ws[i+1].text
				}
				if on, _, ok := strings.Cut(val, "="); ok && secretName(on) {
					d.secretSeen = true
				}
			}
			if !hasVal && valueOpts[name] {
				i++
			}
			continue
		}
		if w.text == "<" || w.text == ">" || w.text == ">>" || w.text == ">&" {
			i++
			continue
		}
		out = append(out, w)
	}
	return out
}

// holdsFile is a word that names the archived file (%f) or the server's file (%p).
func holdsFile(w lexWord, ph string) bool { return strings.Contains(w.text, ph) }

// parseDestCommand reads archive_command (role wal) or restore_command (role restore) into its destinations, a row per
// segment that names one ('not known' rows included: what a segment does that no shape reads is said, never guessed).
func parseDestCommand(cmd, source, role string) []backupDest {
	base := backupDest{role: role, source: source}
	if strings.TrimSpace(cmd) == "" || cmd == "(disabled)" {
		return nil
	}
	segs, why := lexCommand(cmd)
	if why != "" {
		d := base
		d.seq, d.detail = 1, why
		return []backupDest{d}
	}
	ph := map[string]string{"wal": "%f", "restore": "%f"}[role]
	var out []backupDest
	for _, raw := range segs {
		d := base
		substituted := false
		for _, w := range raw {
			substituted = substituted || w.subst
		}
		if substituted {
			d.detail = "not known: a command substitution"
			out = append(out, d)
			continue
		}
		s := peelSegment(raw)
		d.secretSeen = s.secret
		if len(s.words) == 0 {
			if s.secret {
				d.detail = "not known: only settings and a credential"
				out = append(out, d)
			}
			continue
		}
		prog := s.words[0]
		name := path.Base(prog.text)
		args := s.words[1:]
		if prog.tainted {
			d.detail = "not known: the program is a variable or a substitution"
			out = append(out, d)
			continue
		}
		if noRowProgs[name] {
			continue
		}
		switch {
		case name == "true" || name == ":" || name == "exit" || name == "/bin/true":
			d.tool, d.kind, d.detail = "none", "discard", "WAL is discarded: the command archives nothing ("+name+")"
		case name == "pgbackrest":
			destPgBackRest(&d, args, s)
		case name == "barman-wal-archive" || name == "barman-wal-restore":
			destBarmanWAL(&d, args)
		case name == "barman-cloud-wal-archive" || name == "barman-cloud-wal-restore":
			destBarmanCloud(&d, args)
		case name == "wal-g" || name == "wal-e":
			destWalG(&d, name, args, s)
		case name == "aws" || name == "gsutil" || name == "gcloud" || name == "s3cmd" || name == "mc" || name == "rclone" || name == "azcopy" || name == "az" || name == "curl":
			destObjectCLI(&d, name, args)
		case name == "rsync" || name == "scp":
			destRemoteCopy(&d, name, args)
		case name == "cp" || name == "copy" || name == "install" || name == "mv" || name == "dd" || name == "cat" ||
			name == "gzip" || name == "pigz" || name == "xz" || name == "zstd" || name == "lz4" || name == "bzip2" || name == "7z":
			destLocalCopy(&d, name, raw, args, ph)
		case strings.Contains(prog.text, "/") || strings.HasSuffix(name, ".sh") || strings.HasSuffix(name, ".py") || strings.HasSuffix(name, ".pl") ||
			strings.HasSuffix(name, ".bat") || strings.HasSuffix(name, ".cmd") || strings.HasSuffix(name, ".ps1"):
			d.tool = "script"
			if reToolName.MatchString(name) {
				d.detail = "a script (" + name + "): the destination is inside it - not known"
			} else {
				d.detail = "a script: the destination is inside it - not known"
			}
		default:
			if reToolName.MatchString(name) {
				d.detail = "not known: " + name + " is no command pgvigil reads"
			} else {
				d.detail = "not known: a program pgvigil does not read"
			}
		}
		out = append(out, d)
	}
	for i := range out {
		out[i].seq = i + 1
	}
	return out
}

// destPgBackRest: pgbackrest [options] --stanza=S archive-push | archive-get; the inline where-options of each repoN, a
// --config named as the server's file; F2: a repoN-host set = that host's configuration holds the storage.
func destPgBackRest(d *backupDest, args []lexWord, s destSeg) {
	d.tool = "pgbackrest"
	opts := map[string]lexWord{}
	for i := 0; i < len(args); i++ {
		name, val, hasVal := optSplit(args[i].text)
		if name == "" {
			continue
		}
		if secretName(name) {
			d.secretSeen = true
			if !hasVal && i+1 < len(args) && !strings.HasPrefix(args[i+1].text, "-") {
				i++
			}
			continue
		}
		if !hasVal && i+1 < len(args) && !strings.HasPrefix(args[i+1].text, "-") && args[i+1].text != "archive-push" && args[i+1].text != "archive-get" {
			val = args[i+1].text
			i++
		}
		opts[strings.TrimLeft(name, "-")] = lexWord{text: val, tainted: args[i].tainted}
	}
	for k, v := range s.assigns {
		if strings.HasPrefix(k, "PGBACKREST_") {
			opts[strings.ToLower(strings.ReplaceAll(strings.TrimPrefix(k, "PGBACKREST_"), "_", "-"))] = v
		}
	}
	st, ok := opts["stanza"]
	if !ok || st.tainted || !reToolName.MatchString(st.text) {
		d.detail = "not known: pgbackrest without a stanza pgvigil can read"
		return
	}
	d.detail = "stanza " + st.text
	if c, ok := opts["config"]; ok {
		if p := destPathOf(c.text); p != "" && !c.tainted {
			d.detail += "; its configuration file on the server: " + p
		}
	}
	// the first repo named inline (repo1 when none is): its where-options
	repo := ""
	for k := range opts {
		if m := reRepoN.FindString(k); m != "" && (repo == "" || m < repo) {
			repo = m
		}
	}
	if repo == "" {
		d.detail += ": the repository is in pgBackRest's configuration (read with read_tools on)"
		return
	}
	d.repoKey = strings.TrimSuffix(repo, "-")
	get := func(k string) (string, bool) {
		v, ok := opts[repo+k]
		if !ok || v.tainted {
			return "", false
		}
		return v.text, true
	}
	if h, ok := get("host"); ok {
		if reDestHost.MatchString(h) {
			d.kind, d.host = "host", h
			d.detail += "; repository host " + h + ": its storage is in that host's configuration, not read"
		} else {
			d.detail += ": not known (a repository host pgvigil cannot read)"
		}
		return
	}
	typ, _ := get("type")
	switch typ {
	case "", "posix", "cifs", "s3", "gcs", "azure", "sftp":
	default:
		d.detail += ": not known (repository type)"
		return
	}
	if typ == "" {
		typ = "posix"
	}
	d.kind = typ
	if p, ok := get("path"); ok {
		if p = destPathOf(p + "/"); p != "" {
			d.path = p
		}
	}
	for _, k := range []string{"s3-bucket", "gcs-bucket", "azure-container"} {
		if v, ok := get(k); ok && reDestBucket.MatchString(v) {
			d.container = v
		}
	}
	for _, k := range []string{"s3-endpoint", "gcs-endpoint", "azure-endpoint", "sftp-host", "storage-host", "azure-account"} {
		if v, ok := get(k); ok && reDestHost.MatchString(v) {
			d.host = v
			break
		}
	}
}

// destBarmanWAL: barman-wal-archive | -restore [options] BARMAN_HOST SERVER_NAME ...
func destBarmanWAL(d *backupDest, args []lexWord) {
	d.tool = "barman"
	var pos []lexWord
	for i := 0; i < len(args); i++ {
		name, _, hasVal := optSplit(args[i].text)
		switch {
		case name == "":
			pos = append(pos, args[i])
		case barmanWALValueOpts[name]:
			if !hasVal {
				i++
			}
		case barmanWALFlags[name]:
		default:
			d.detail = "not known: an option barman-wal-archive does not take"
			return
		}
	}
	if len(pos) < 2 || pos[0].tainted || pos[1].tainted || !reDestHost.MatchString(pos[0].text) || !reToolName.MatchString(pos[1].text) {
		d.detail = "not known: barman's host and server"
		return
	}
	d.kind, d.host, d.detail = "host", pos[0].text, "barman server "+pos[1].text
}

// destBarmanCloud: barman-cloud-wal-archive | -restore [options] DESTINATION_URL SERVER_NAME ...; --endpoint-url kept as
// the host; --sse-customer-key is a file:// URI at 3.20.1 (any other value is taken for a secret).
func destBarmanCloud(d *backupDest, args []lexWord) {
	d.tool = "barman-cloud"
	endpoint := ""
	var pos []lexWord
	for i := 0; i < len(args); i++ {
		name, val, hasVal := optSplit(args[i].text)
		if name == "" {
			pos = append(pos, args[i])
			continue
		}
		takes := map[string]bool{"--cloud-provider": true, "--endpoint-url": true, "--aws-profile": true, "--profile": true, "--read-timeout": true,
			"--sse": true, "--sse-kms-key-id": true, "--sse-customer-key": true, "--tags": true, "--history-tags": true, "--azure-credential": true,
			"--credential": true, "--snappy": false, "--max-archive-size": true, "--min-chunk-size": true, "--max-bandwidth": true, "--encryption-scope": true,
			"--kms-key-name": true, "--parallel": true, "-P": true}[name]
		if !hasVal && takes && i+1 < len(args) {
			val = args[i+1].text
			i++
		}
		switch {
		case name == "--sse-customer-key":
			if !strings.HasPrefix(val, "file://") {
				d.secretSeen = true
			}
		case secretName(name):
			d.secretSeen = true
		case name == "--endpoint-url":
			if _, h, _, _, ok := destURL(val); ok {
				endpoint = h
			}
		}
	}
	if len(pos) < 2 || pos[1].tainted || !reToolName.MatchString(pos[1].text) || !destFromURLWord(d, pos[0]) {
		d.kind, d.host, d.container, d.path = "", "", "", ""
		d.detail = "not known: barman-cloud's destination"
		return
	}
	d.detail = "barman server " + pos[1].text
	if endpoint != "" {
		d.detail += "; endpoint " + endpoint
	}
}

// destWalG: wal-g | wal-e wal-push | wal-fetch: the destination is a setting (WALG_<store>_PREFIX), read only from an
// inline assignment or wal-e's --<store>-prefix; an envdir or a --config file is named as where it lives.
func destWalG(d *backupDest, name string, args []lexWord, s destSeg) {
	d.tool = name
	var prefix lexWord
	found := false
	for k, v := range s.assigns {
		if reDestPrefix.MatchString(k) {
			prefix, found = v, true
		}
	}
	conf := ""
	for i := 0; i < len(args); i++ {
		o, val, hasVal := optSplit(args[i].text)
		if o == "" {
			continue
		}
		if !hasVal && i+1 < len(args) && (o == "--config" || strings.HasSuffix(o, "-prefix")) {
			val = args[i+1].text
			i++
		}
		switch {
		case secretName(o):
			d.secretSeen = true
		case o == "--config":
			if p := destPathOf(val); p != "" {
				conf = p
			}
		case strings.HasSuffix(o, "-prefix"):
			prefix, found = lexWord{text: val, tainted: args[i].tainted}, true
		}
	}
	switch {
	case found && strings.HasPrefix(prefix.text, "/") && !prefix.tainted:
		if p := destPathOf(prefix.text + "/"); p != "" {
			d.kind, d.path = "posix", p
			return
		}
		d.detail = "not known: the prefix"
	case found:
		if !destFromURLWord(d, prefix) {
			d.kind, d.host, d.container, d.path = "", "", "", ""
			d.detail = "not known: the prefix"
		}
	case s.envdir.text != "" && !s.envdir.tainted && destPathOf(s.envdir.text+"/") != "":
		d.detail = "the destination is in the envdir " + destPathOf(s.envdir.text+"/") + " on the server - not known"
	case conf != "":
		d.detail = "the destination is in its configuration file " + conf + " on the server - not known"
	default:
		d.detail = "the destination is in the server's environment - not known"
	}
}

// destObjectCLI: an object store's command line; the destination is the last positional word that is a URL (a
// remote:path for rclone, alias/bucket/path for mc); az names its account and container by options.
func destObjectCLI(d *backupDest, name string, args []lexWord) {
	d.tool = name
	if name == "az" {
		var acct, cont lexWord
		for i := 0; i < len(args); i++ {
			o, val, hasVal := optSplit(args[i].text)
			if o == "" {
				continue
			}
			if !hasVal && i+1 < len(args) {
				val = args[i+1].text
				i++
			}
			switch {
			case secretName(o):
				d.secretSeen = true
			case o == "--account-name":
				acct = lexWord{text: val, tainted: args[i].tainted}
			case o == "--container-name" || o == "-c":
				cont = lexWord{text: val, tainted: args[i].tainted}
			}
		}
		if acct.tainted || cont.tainted || !reDestBucket.MatchString(acct.text) || !reDestBucket.MatchString(cont.text) {
			d.detail = "not known: az's account and container"
			return
		}
		d.kind, d.host, d.container = "azure", acct.text+".blob.core.windows.net", cont.text
		return
	}
	valueOpts := map[string]bool{"--endpoint-url": true, "--profile": true, "--region": true, "-u": true, "--user": true, "-T": true, "--upload-file": true,
		"--config": true, "--storage-class": true, "--sse": true, "--acl": true}
	endpoint := ""
	for i := 0; i < len(args); i++ {
		o, val, hasVal := optSplit(args[i].text)
		if (o == "-u" || o == "--user") && i+1 < len(args) && strings.Contains(args[i+1].text, ":") {
			d.secretSeen = true // curl -u user:password
		}
		if o == "--endpoint-url" {
			if !hasVal && i+1 < len(args) {
				val = args[i+1].text
			}
			if _, h, _, _, ok := destURL(val); ok {
				endpoint = h
			}
		}
	}
	pos := positional(args, valueOpts, d)
	if len(pos) == 0 {
		d.detail = "not known: " + name + "'s destination"
		return
	}
	last := pos[len(pos)-1]
	switch name {
	case "rclone":
		remote, p, ok := strings.Cut(last.text, ":")
		if strings.Contains(remote, ",") || strings.HasPrefix(last.text, ":") {
			low := strings.ToLower(last.text)
			for _, k := range []string{"secret", "key", "pass", "token"} {
				if strings.Contains(low, k) {
					d.secretSeen = true
				}
			}
			d.detail = "not known: an inline rclone remote"
			return
		}
		if !ok || last.tainted || !reToolName.MatchString(remote) {
			d.detail = "not known: rclone's destination"
			return
		}
		d.kind, d.container = "rclone-remote", remote
		if pp := destPathOf("/" + strings.TrimPrefix(p, "/")); pp != "" {
			d.path = pp
		}
		d.detail = "the remote " + remote + " is defined in the server's rclone configuration"
	case "mc":
		alias, p, ok := strings.Cut(last.text, "/")
		if !ok || last.tainted || !reToolName.MatchString(alias) {
			d.detail = "not known: mc's destination"
			return
		}
		d.kind, d.container = "mc-alias", alias
		if pp := destPathOf("/" + p); pp != "" {
			d.path = pp
		}
		d.detail = "the alias " + alias + " is defined in the server's mc configuration"
	default:
		if !destFromURLWord(d, last) {
			d.kind, d.host, d.container, d.path = "", "", "", ""
			d.detail = "not known: " + name + "'s destination"
			return
		}
		if endpoint != "" {
			d.host = endpoint
			d.detail = "endpoint " + endpoint
		}
	}
}

// destRemoteCopy: rsync or scp to [user@]host:/path, host::module/path or rsync://host[:port]/module/path; an rsync into
// .../<server>/incoming is barman's (its rsync archiving); a local target is a local copy.
func destRemoteCopy(d *backupDest, name string, args []lexWord) {
	d.tool = name
	vo := rsyncValueOpts
	if name == "scp" {
		vo = scpValueOpts
	}
	pos := positional(args, vo, d)
	if len(pos) == 0 || pos[len(pos)-1].tainted {
		d.detail = "not known: " + name + "'s destination"
		return
	}
	t := pos[len(pos)-1].text
	switch {
	case strings.HasPrefix(t, "rsync://"):
		if !destFromURLWord(d, pos[len(pos)-1]) {
			d.detail = "not known: " + name + "'s destination"
			return
		}
		d.kind = "rsync-module"
		return
	case strings.Contains(t, "::"):
		h, rest, _ := strings.Cut(t, "::")
		if at := strings.LastIndexByte(h, '@'); at >= 0 {
			h = h[at+1:]
		}
		mod, p, _ := strings.Cut(rest, "/")
		if !reDestHost.MatchString(h) || !reToolName.MatchString(mod) {
			d.detail = "not known: " + name + "'s destination"
			return
		}
		d.kind, d.host, d.container = "rsync-module", h, mod
		if p != "" {
			d.path = destPathOf("/" + p)
		}
		return
	case strings.Contains(t, ":") && !reDestWin.MatchString(t):
		h, p, _ := strings.Cut(t, ":")
		if at := strings.LastIndexByte(h, '@'); at >= 0 {
			h = h[at+1:]
		}
		dir := destPathOf(p)
		if !reDestHost.MatchString(h) || dir == "" {
			d.detail = "not known: " + name + "'s destination"
			return
		}
		if i := strings.Index(dir, "/incoming"); i > 0 && strings.HasSuffix(dir, "/incoming") {
			srv := path.Base(dir[:i])
			if reToolName.MatchString(srv) {
				d.tool, d.kind, d.host, d.path, d.detail = "barman", "host", h, dir, "barman server "+srv+" (rsync into its incoming directory)"
				return
			}
		}
		d.kind, d.host, d.path = "host", h, dir
	default:
		if p := destPathOf(t); p != "" {
			d.tool, d.kind, d.path = "copy", "posix", p
			if p == "/dev/null" || t == "/dev/null" {
				d.kind, d.path, d.detail = "discard", "", "WAL is discarded: the command copies to /dev/null"
			}
			return
		}
		d.detail = "not known: " + name + "'s destination"
	}
}

// destLocalCopy: cp, copy, install, mv, dd of=, cat or a compressor with a redirect: the directory of the word that
// holds the file (%f), the redirect's target first.
func destLocalCopy(d *backupDest, name string, raw []lexWord, args []lexWord, ph string) {
	d.tool, d.kind = "copy", "posix"
	if name != "cp" && name != "copy" && name != "install" && name != "mv" {
		d.detail = "compressed with " + name
		if name == "dd" || name == "cat" {
			d.detail = ""
		}
	}
	var target lexWord
	for i, w := range raw {
		if (w.text == ">" || w.text == ">>") && i+1 < len(raw) {
			target = raw[i+1]
		}
		if name == "dd" && strings.HasPrefix(w.text, "of=") {
			target = lexWord{text: strings.TrimPrefix(w.text, "of="), tainted: w.tainted}
		}
	}
	if target.text == "" {
		pos := positional(args, nil, d)
		for i := len(pos) - 1; i >= 0 && target.text == ""; i-- {
			if holdsFile(pos[i], ph) {
				target = pos[i]
			}
		}
		if target.text == "" && len(pos) > 1 && !holdsFile(pos[len(pos)-1], "%p") {
			target = pos[len(pos)-1]
		}
	}
	if target.text == "/dev/null" || target.text == "NUL" || strings.EqualFold(target.text, "nul") {
		d.kind, d.detail = "discard", "WAL is discarded: the command copies to "+target.text
		return
	}
	if target.text == "" || target.tainted {
		d.kind, d.detail = "", "not known: "+name+"'s target"
		return
	}
	w := target.text
	if !holdsFile(target, ph) && !strings.HasSuffix(w, "/") && !strings.HasSuffix(w, `\`) {
		w += "/"
	}
	p := destPathOf(w)
	if p == "" {
		d.kind, d.detail = "", "not known: "+name+"'s target"
		return
	}
	d.path = p
}

// parseDestLibrary reads archive_library (F7: a non-empty archive_library is the archiver on every version, whatever
// archive_command says): basic_archive's directory, or the module's name.
func parseDestLibrary(lib, basicDir string) []backupDest {
	lib = strings.TrimSpace(lib)
	if lib == "" {
		return nil
	}
	d := backupDest{role: "wal", seq: 1, source: "archive_library"}
	switch {
	case lib == "basic_archive":
		d.tool = "basic_archive"
		if p := destPathOf(strings.TrimRight(basicDir, "/") + "/"); p != "" && basicDir != "" {
			d.kind, d.path = "posix", p
		} else {
			d.detail = "not known: basic_archive.archive_directory"
		}
	case reToolName.MatchString(lib):
		d.tool, d.detail = "library", "the archive library "+lib+": the destination is the module's own setting - not known"
	default:
		d.tool, d.detail = "library", "an archive library: the destination is the module's own setting - not known"
	}
	return []backupDest{d}
}

// ---- the collection backup_dest -------------------------------------------------------------------------------------

// backupDestCollector is the collection backup_dest: every 15 minutes (backup_tools' interval, F11), the server's
// settings into destinations, and with read_tools on the backup tool's own configuration on the collector's host.
// Rows: one {kind:'settings'}, {kind:'dest'} per destination, {kind:'read'} per tool read (state off | ok | no_binary |
// error, the fixed words). Read only; nothing is run unless the instance opted in.
type backupDestCollector struct{}

func init() { Register(backupDestCollector{}) }

func (backupDestCollector) Name() string                   { return "backup_dest" }
func (backupDestCollector) DefaultInterval() time.Duration { return 15 * time.Minute }
func (backupDestCollector) Applies(info platform.Info) (bool, string) {
	return backupToolsCollector{}.Applies(info)
}

func (b backupDestCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	return b.RunInstance(ctx, conn, info, config.Instance{}, nil)
}

// backupDestSettingsSQL: the archiver's settings (archive_library from PostgreSQL 15, basic_archive's directory where
// the module is loaded: missing_ok) and whether the server is a standby.
const backupDestSettingsSQL = `
SELECT pg_is_in_recovery() AS is_replica, current_setting('archive_mode') AS archive_mode,
       current_setting('archive_command') AS archive_command,
       coalesce(current_setting('archive_library', true), '') AS archive_library,
       coalesce(current_setting('restore_command', true), '') AS restore_command,
       coalesce(current_setting('basic_archive.archive_directory', true), '') AS basic_archive_dir`

func (backupDestCollector) RunInstance(ctx context.Context, conn *pgx.Conn, _ platform.Info, inst config.Instance, _ CursorFunc) ([]Row, error) {
	rows, err := conn.Query(ctx, backupDestSettingsSQL)
	if err != nil {
		return nil, fmt.Errorf("backup_dest: the settings: %w", err)
	}
	set, err := rowsToMaps(rows)
	if err != nil || len(set) != 1 {
		return nil, fmt.Errorf("backup_dest: the settings: %v", err)
	}
	str := func(k string) string { v, _ := set[0][k].(string); return v }
	isReplica, _ := set[0]["is_replica"].(bool)
	st := destSettings{archiveMode: str("archive_mode"), archiveCmd: str("archive_command"), archiveLib: str("archive_library"),
		restoreCmd: str("restore_command"), basicDir: str("basic_archive_dir"), isReplica: isReplica}
	out := destRows(st)
	readOn := backupReadTools(inst)
	for _, t := range destTools(st) {
		out = append(out, readDestTool(t, readOn)...)
	}
	return out, nil
}

// destSettings is what the settings read gave.
type destSettings struct {
	archiveMode, archiveCmd, archiveLib, restoreCmd, basicDir string
	isReplica                                                 bool
}

// destOf parses the settings into destinations: F7 - a non-empty archive_library is the archiver on every version;
// archive_mode off = 'WAL is not archived'; base backups go where pgBackRest's, wal-g's, barman's or barman-cloud's WAL
// goes (a row of role base, its detail saying so), and are 'not known' for a plain copy (the view says it).
func destOf(st destSettings) []backupDest {
	var out []backupDest
	switch {
	case st.archiveMode == "off":
		out = append(out, backupDest{role: "wal", seq: 1, source: "archive_mode", tool: "none", detail: "WAL is not archived (archive_mode off)"})
	case strings.TrimSpace(st.archiveLib) != "":
		out = append(out, parseDestLibrary(st.archiveLib, st.basicDir)...)
	default:
		wal := parseDestCommand(st.archiveCmd, "archive_command", "wal")
		if len(wal) == 0 {
			wal = []backupDest{{role: "wal", seq: 1, source: "archive_command", tool: "none", detail: "WAL is not archived (archive_command is empty)"}}
		}
		out = append(out, wal...)
	}
	for _, d := range out {
		switch d.tool {
		case "pgbackrest", "wal-g", "wal-e", "barman", "barman-cloud":
			b := d
			b.role, b.detail = "base", strings.TrimSpace(d.detail+" (base backups go where its WAL goes)")
			if d.detail == "" {
				b.detail = "base backups go where its WAL goes"
			}
			out = append(out, b)
		}
	}
	out = append(out, parseDestCommand(st.restoreCmd, "restore_command", "restore")...)
	return out
}

// destRows: the settings row and a dest row per destination. F12: a standby with archive_mode on (not always) does not
// archive; a restore_command on a primary is set, not in use.
func destRows(st destSettings) []Row {
	out := []Row{{"kind": "settings", "is_replica": st.isReplica, "archive_mode": st.archiveMode,
		"archive_command_set": st.archiveCmd != "" && st.archiveCmd != "(disabled)", "archive_library_set": strings.TrimSpace(st.archiveLib) != "",
		"restore_command_set": st.restoreCmd != "",
		"standby_archives":    !st.isReplica || st.archiveMode == "always"}}
	for _, d := range destOf(st) {
		r := destRow(d)
		switch {
		case d.role == "wal" && st.isReplica && st.archiveMode == "on":
			r["detail"] = strings.TrimSpace(d.detail + " (this standby does not archive: archive_mode on archives on a primary only, always in recovery too)")
		case d.role == "restore" && !st.isReplica:
			r["detail"] = strings.TrimSpace(d.detail + " (set, not in use: this server is a primary)")
		}
		out = append(out, r)
	}
	return out
}

// destTool is a tool whose own configuration names its storage: a pgBackRest stanza (with the options inline in the
// server's command, which win for that server) or a barman server.
type destTool struct {
	tool, name string
	inline     map[string]string // pgBackRest's inline where-options, by their name without dashes
	config     string            // a --config the server's command names
}

// destTools: the tools the server's commands name whose configuration read_tools may read.
func destTools(st destSettings) []destTool {
	var out []destTool
	seen := map[string]bool{}
	for _, c := range []string{st.archiveCmd, st.restoreCmd} {
		segs, why := lexCommand(c)
		if why != "" {
			continue
		}
		for _, raw := range segs {
			s := peelSegment(raw)
			if len(s.words) == 0 {
				continue
			}
			switch path.Base(s.words[0].text) {
			case "pgbackrest":
				t := destTool{tool: "pgbackrest", inline: map[string]string{}}
				for i := 1; i < len(s.words); i++ {
					w := s.words[i]
					name, val, has := optSplit(w.text)
					if name == "" || w.tainted || secretName(name) {
						continue
					}
					if !has && i+1 < len(s.words) && !strings.HasPrefix(s.words[i+1].text, "-") {
						val = s.words[i+1].text
						i++
					}
					n := strings.TrimLeft(name, "-")
					switch {
					case n == "stanza" && reToolName.MatchString(val):
						t.name = val
					case n == "config":
						t.config = destPathOf(val)
					case pgbrWhere[reRepoN.ReplaceAllString(n, "")] && reRepoN.MatchString(n):
						t.inline[n] = val
					}
				}
				if t.name != "" && !seen["pgbackrest|"+t.name] {
					seen["pgbackrest|"+t.name] = true
					out = append(out, t)
				}
			case "barman-wal-archive", "barman-wal-restore":
				var d backupDest
				destBarmanWAL(&d, s.words[1:])
				if srv := strings.TrimPrefix(d.detail, "barman server "); srv != d.detail && !seen["barman|"+srv] {
					seen["barman|"+srv] = true
					out = append(out, destTool{tool: "barman", name: srv})
				}
			}
		}
	}
	return out
}

// pgbrWhere: the pgBackRest repository options read (where the repository is, its encryption's type, its retention) -
// a whitelist: any other option's value, a key or a passphrase above all, is never taken into a variable.
var pgbrWhere = map[string]bool{"type": true, "path": true, "host": true, "s3-bucket": true, "s3-endpoint": true, "s3-region": true, "s3-uri-style": true,
	"azure-account": true, "azure-container": true, "azure-endpoint": true, "gcs-bucket": true, "gcs-endpoint": true, "sftp-host": true,
	"storage-host": true, "cipher-type": true, "retention-full": true, "retention-full-type": true, "retention-diff": true, "retention-archive": true,
	"retention-archive-type": true}

// pgbrFiles is where pgBackRest reads its configuration when nothing names another: the file (the old default when the
// new one is missing) and the include directory's *.conf.
var pgbrFiles = struct{ file, oldFile, include string }{"/etc/pgbackrest/pgbackrest.conf", "/etc/pgbackrest.conf", "/etc/pgbackrest/conf.d"}

// pgbrGetenv and pgbrEnviron read the collector's environment; a test sets them.
var (
	pgbrGetenv  = os.Getenv
	pgbrEnviron = os.Environ
)

// pgbrConfig reads the where-options of a stanza's repositories as the collector host's pgBackRest would for the command
// cmd (archive-push for the WAL, backup for the base backups), F8: [stanza:cmd] over [stanza] over [global:cmd] over
// [global]; --config (or PGBACKREST_CONFIG) loads that file alone (no include directory), else the default file and
// the include directory; PGBACKREST_REPOn_* in the environment win over the files; the server's inline options win over
// all. Returns the options by name (repo1-path ...), where each came from, and the fixed words of a failure.
func pgbrConfig(stanza, cmd, serverConfig string, inline map[string]string) (opts map[string]string, from map[string]string, why string) {
	opts, from = map[string]string{}, map[string]string{}
	rank := map[string]int{}
	files := []string{}
	switch {
	case serverConfig != "":
		files = []string{serverConfig}
	case pgbrGetenv("PGBACKREST_CONFIG") != "":
		files = []string{pgbrGetenv("PGBACKREST_CONFIG")}
	default:
		f := pgbrFiles.file
		if p := pgbrGetenv("PGBACKREST_CONFIG_PATH"); p != "" {
			f = filepath.Join(p, "pgbackrest.conf")
		} else if _, err := os.Stat(f); err != nil {
			f = pgbrFiles.oldFile
		}
		files = []string{f}
		inc := pgbrFiles.include
		if p := pgbrGetenv("PGBACKREST_CONFIG_INCLUDE_PATH"); p != "" {
			inc = p
		} else if p := pgbrGetenv("PGBACKREST_CONFIG_PATH"); p != "" {
			inc = filepath.Join(p, "conf.d")
		}
		if m, err := filepath.Glob(filepath.Join(inc, "*.conf")); err == nil {
			sort.Strings(m)
			files = append(files, m...)
		}
	}
	sections := map[string]int{"global": 1, "global:" + cmd: 2, stanza: 3, stanza + ":" + cmd: 4}
	readAny := false
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		readAny = true
		sec := ""
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
				sec = strings.TrimSpace(line[1 : len(line)-1])
				continue
			}
			eq := strings.IndexByte(line, '=')
			if eq < 0 {
				continue
			}
			key := strings.TrimSpace(line[:eq])
			r, ok := sections[sec]
			if !ok || !reRepoN.MatchString(key) || !pgbrWhere[reRepoN.ReplaceAllString(key, "")] {
				continue // the value of an option not on the list is never read
			}
			if r >= rank[key] {
				rank[key], opts[key], from[key] = r, strings.TrimSpace(line[eq+1:]), f
			}
		}
	}
	for _, kv := range pgbrEnviron() {
		k, v, _ := strings.Cut(kv, "=")
		if !strings.HasPrefix(k, "PGBACKREST_REPO") {
			continue
		}
		key := strings.ToLower(strings.ReplaceAll(strings.TrimPrefix(k, "PGBACKREST_"), "_", "-"))
		if reRepoN.MatchString(key) && pgbrWhere[reRepoN.ReplaceAllString(key, "")] {
			opts[key], from[key] = v, "environment"
		}
	}
	for k, v := range inline {
		opts[k], from[k] = v, "the server's command"
	}
	if !readAny && len(opts) == 0 {
		return opts, from, "file not readable"
	}
	return opts, from, ""
}

// readDestTool reads one tool's configuration on the collector's host (read_tools on): a {kind:'read'} row with its
// state and fixed words, and the destinations it names (source 'pgbackrest configuration' or 'barman').
func readDestTool(t destTool, readOn bool) []Row {
	rd := Row{"kind": "read", "tool": t.tool, "name": t.name}
	if !readOn {
		rd["state"], rd["message"] = "off", backupNotRead
		return []Row{rd}
	}
	switch t.tool {
	case "pgbackrest":
		var out []Row
		for _, c := range []struct{ cmd, role string }{{"archive-push", "wal"}, {"backup", "base"}} {
			opts, from, why := pgbrConfig(t.name, c.cmd, t.config, t.inline)
			if why != "" {
				rd["state"], rd["message"] = "error", why
				return []Row{rd}
			}
			for _, d := range pgbrDests(t.name, c.role, opts, from) {
				out = append(out, destRow(d))
			}
		}
		rd["state"] = "ok"
		return append([]Row{rd}, out...)
	case "barman":
		bin, err := lookTool("barman")
		if err != nil {
			rd["state"], rd["message"] = "no_binary", "barman is not on the collector host's PATH"
			return []Row{rd}
		}
		raw, err := runTool(context.Background(), bin, "-f", "json", "show-servers", "--", t.name)
		if err != nil {
			rd["state"], rd["message"] = "error", "barman show-servers: "+err.Error()
			return []Row{rd}
		}
		ds, why := barmanDests(raw, t.name)
		if why != "" {
			rd["state"], rd["message"] = "error", why
			return []Row{rd}
		}
		rd["state"] = "ok"
		out := []Row{rd}
		for _, d := range ds {
			out = append(out, destRow(d))
		}
		return out
	}
	return nil
}

func destRow(d backupDest) Row {
	return Row{"kind": "dest", "role": d.role, "seq": d.seq, "source": d.source, "tool": nilIfEmpty(d.tool), "dest_kind": nilIfEmpty(d.kind),
		"host": nilIfEmpty(d.host), "container": nilIfEmpty(d.container), "path": nilIfEmpty(d.path), "repo_key": nilIfEmpty(d.repoKey),
		"detail": nilIfEmpty(d.detail), "secret_seen": d.secretSeen}
}

// pgbrDests turns a stanza's options into a destination per repository: its type (posix by default, said), its path
// (pgBackRest's default /var/lib/pgbackrest, said), bucket or container, host or endpoint, encryption and retention -
// where each value came from in the detail. F2: a repoN-host = that host's configuration holds the storage, not read.
func pgbrDests(stanza, role string, opts, from map[string]string) []backupDest {
	repos := map[string]bool{}
	for k := range opts {
		repos[strings.TrimSuffix(reRepoN.FindString(k), "-")] = true
	}
	if len(repos) == 0 {
		repos["repo1"] = true // pgBackRest's default repository: posix at /var/lib/pgbackrest
	}
	keys := make([]string, 0, len(repos))
	for k := range repos {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var out []backupDest
	for i, r := range keys {
		get := func(k string) (string, string) { return opts[r+"-"+k], from[r+"-"+k] }
		d := backupDest{role: role, seq: i + 1, source: "pgbackrest configuration", tool: "pgbackrest", repoKey: r}
		var said []string
		if h, f := get("host"); h != "" {
			if reDestHost.MatchString(h) {
				d.kind, d.host = "host", h
				d.detail = "stanza " + stanza + "; repository host " + h + " (" + f + "): its storage is in that host's configuration, not read"
			} else {
				d.detail = "stanza " + stanza + ": not known (a repository host pgvigil cannot read)"
			}
			out = append(out, d)
			continue
		}
		typ, tf := get("type")
		if typ == "" {
			typ, tf = "posix", "pgBackRest's default"
		}
		switch typ {
		case "posix", "cifs", "s3", "gcs", "azure", "sftp":
			d.kind = typ
			said = append(said, "type "+typ+" ("+tf+")")
		default:
			d.detail = "stanza " + stanza + ": not known (repository type)"
			out = append(out, d)
			continue
		}
		p, pf := get("path")
		if p == "" {
			p, pf = "/var/lib/pgbackrest", "pgBackRest's default"
		}
		if pp := destPathOf(strings.TrimRight(p, "/") + "/"); pp != "" {
			d.path = pp
			said = append(said, "path ("+pf+")")
		}
		for _, k := range []string{"s3-bucket", "gcs-bucket", "azure-container"} {
			if v, f := get(k); v != "" && reDestBucket.MatchString(v) {
				d.container = v
				said = append(said, k+" ("+f+")")
			}
		}
		for _, k := range []string{"s3-endpoint", "gcs-endpoint", "azure-endpoint", "sftp-host", "storage-host", "azure-account"} {
			if v, f := get(k); v != "" && reDestHost.MatchString(v) {
				d.host = v
				said = append(said, k+" ("+f+")")
				break
			}
		}
		if c, _ := get("cipher-type"); c != "" && c != "none" {
			said = append(said, "encrypted")
		} else {
			said = append(said, "not encrypted")
		}
		if n, _ := get("retention-full"); reDestPort.MatchString(n) {
			t, _ := get("retention-full-type")
			if t == "" {
				t = "count"
			}
			said = append(said, "retention "+n+" full ("+map[string]string{"count": "backups", "time": "days"}[t]+")")
		}
		d.detail = "stanza " + stanza + "; " + strings.Join(said, ", ")
		out = append(out, d)
	}
	return out
}

// barmanShow is barman show-servers' answer for one server, the whitelisted keys only (F3: conninfo,
// streaming_conninfo, ssh_command and every *_script are never decoded).
type barmanShow struct {
	BarmanHome           string          `json:"barman_home"`
	BackupDirectory      string          `json:"backup_directory"`
	BasebackupsDirectory string          `json:"basebackups_directory"`
	WalsDirectory        string          `json:"wals_directory"`
	BackupMethod         string          `json:"backup_method"`
	Archiver             json.RawMessage `json:"archiver"`
	StreamingArchiver    json.RawMessage `json:"streaming_archiver"`
	RetentionPolicy      string          `json:"retention_policy"`
	WalRetentionPolicy   string          `json:"wal_retention_policy"`
}

// barmanDests: the base backups' and the WAL's directories (a local path, or a cloud URL through the URL rule) of a
// barman server, with its method and retention.
func barmanDests(raw []byte, server string) ([]backupDest, string) {
	var all map[string]barmanShow
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, "barman show-servers: not the JSON expected"
	}
	b, ok := all[server]
	if !ok {
		return nil, "barman show-servers: server " + server + " is not in the answer"
	}
	var said []string
	if reToolName.MatchString(b.BackupMethod) {
		said = append(said, "backup method "+b.BackupMethod)
	}
	if rp := strings.TrimSpace(b.RetentionPolicy); reBarmanPolicy.MatchString(rp) {
		said = append(said, "retention "+rp)
	}
	var out []backupDest
	for i, c := range []struct{ role, dir string }{{"base", b.BasebackupsDirectory}, {"wal", b.WalsDirectory}} {
		dir := c.dir
		if dir == "" && b.BackupDirectory != "" {
			dir = strings.TrimRight(b.BackupDirectory, "/") + map[string]string{"base": "/base", "wal": "/wals"}[c.role]
		}
		d := backupDest{role: c.role, seq: i + 1, source: "barman", tool: "barman", detail: strings.TrimSpace("barman server " + server + "; " + strings.Join(said, ", "))}
		switch {
		case strings.Contains(dir, "://"):
			if !destFromURLWord(&d, lexWord{text: dir}) {
				d.kind, d.host, d.container, d.path, d.detail = "", "", "", "", "barman server "+server+": not known (the directory)"
			}
		case destPathOf(strings.TrimRight(dir, "/")+"/") != "":
			d.kind, d.path = "posix", destPathOf(strings.TrimRight(dir, "/")+"/")
		default:
			d.detail = "barman server " + server + ": not known (the directory)"
		}
		out = append(out, d)
	}
	return out, ""
}
