// Package format is the remote collector's bundle, as both sides read it: the folder a bundle lives in, its
// manifest, its view files' lines and the checks a reader makes before it trusts one. The writer (internal/remote),
// the hub's ingest (internal/ingest) and `pgvigil bundle inspect` use this package and nothing else for the format;
// docs/remote-bundle-format.md is its prose.
//
// A bundle is one instance's interval:
//
//	<site>/<collector>/<instance-key>/<yyyy-mm-dd>/<seq:010d>-<yyyymmddThhmmssZ>/
//	    <view>.ndjson.gz   one per view that has rows: a line per batch, {"n", "at", "rows"}
//	    SHA256SUMS         sha256sum's form, over every view file
//	    manifest.sig       only when the collector signs (Ed25519 over manifest.json's bytes)
//	    manifest.json      written last: a reader that finds it finds every other file written
package format

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Version is the format this binary writes and the newest it reads. A reader refuses a newer one with
// ErrNewerFormat (the hub sets such a bundle aside and reads it after its own upgrade) and reads every older one.
const Version = 1

// The names inside a bundle's folder.
const (
	ManifestFile = "manifest.json"
	SumsFile     = "SHA256SUMS"
	SigFile      = "manifest.sig"
	ViewExt      = ".ndjson.gz"
	// PartExt marks a bundle folder still being written on the collector's host; a reader never opens one.
	PartExt = ".part"
)

// Read statuses: how each collection of the instance's schedule ended in the interval.
const (
	ReadRan     = "ran"     // every run of the interval ended well
	ReadFailed  = "failed"  // at least one run failed (Runs and Failed count them)
	ReadSkipped = "skipped" // no run: Reason says why
)

// Skip reasons of a skipped read.
var skipReasons = map[string]bool{"off": true, "not_due": true, "not_applicable": true, "running": true}

// ErrNewerFormat is a manifest written by a newer format than Version.
var ErrNewerFormat = errors.New("the bundle's format is newer than this pgvigil reads")

var (
	nameRE   = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,62}$`)
	viewRE   = regexp.MustCompile(`^[a-z][a-z0-9_]{0,62}$`)
	hex64RE  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	streamRE = regexp.MustCompile(`^[0-9a-f]{16,64}$`)
	leafRE   = regexp.MustCompile(`^([0-9]{10})-([0-9]{8}T[0-9]{6}Z)$`)
)

// ValidName says whether s may name a site or a collector: lower-case letters, digits, '_', '.', '-', a letter or a
// digit first, 1 to 63 characters (one path part on every drop, and a tag value on the hub).
func ValidName(s string) bool { return nameRE.MatchString(s) }

// ValidView says whether s may name a view (a collection): the repository's identifier shape. Whether the hub
// knows the view is the hub's allow-list, not this.
func ValidView(s string) bool { return viewRE.MatchString(s) }

// keyByte says whether b stands for itself in an instance key; a '.' does except as the first byte, so no key is
// "." or ".." or a hidden file.
func keyByte(b byte, first bool) bool {
	switch {
	case b >= 'A' && b <= 'Z', b >= 'a' && b <= 'z', b >= '0' && b <= '9', b == '_', b == '-':
		return true
	case b == '.':
		return !first
	}
	return false
}

// InstanceKey is an instance name as one path part: every byte that does not stand for itself becomes %XX
// (upper-case hex), so a SQL Server name HOST\INST is HOST%5CINST. Each name has exactly one key.
func InstanceKey(name string) string {
	var b strings.Builder
	for i := 0; i < len(name); i++ {
		c := name[i]
		if keyByte(c, i == 0) {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// InstanceName reads a key back. A key that is not the one key of its name (a bare byte that should be encoded,
// one encoded that need not be, lower-case hex) is refused, so two keys never name one instance.
func InstanceName(key string) (string, error) {
	if key == "" {
		return "", errors.New("an empty instance key")
	}
	var b []byte
	for i := 0; i < len(key); i++ {
		c := key[i]
		if c != '%' {
			b = append(b, c)
			continue
		}
		if i+2 >= len(key) || !upperHex(key[i+1]) || !upperHex(key[i+2]) {
			return "", fmt.Errorf("instance key %q: a %% not followed by two upper-case hex digits", key)
		}
		v, _ := strconv.ParseUint(key[i+1:i+3], 16, 8)
		b = append(b, byte(v))
		i += 2
	}
	name := string(b)
	if !utf8.ValidString(name) || InstanceKey(name) != key {
		return "", fmt.Errorf("instance key %q is not the key of the name it spells", key)
	}
	return name, nil
}

func upperHex(c byte) bool { return c >= '0' && c <= '9' || c >= 'A' && c <= 'F' }

// Ref names one bundle by its folder.
type Ref struct {
	Site, Collector, InstanceKey string
	Seq                          uint64
	End                          time.Time // the window's end, to the second, UTC
}

// Dir is the bundle's folder, relative to the drop's root (or prefix).
func (r Ref) Dir() string {
	end := r.End.UTC()
	return fmt.Sprintf("%s/%s/%s/%s/%010d-%s", r.Site, r.Collector, r.InstanceKey, end.Format("2006-01-02"), r.Seq, end.Format("20060102T150405Z"))
}

// ParseDir reads a bundle's folder back into its Ref; anything else (a .part folder, a deeper or shallower path, a
// day that is not the end's) is refused.
func ParseDir(p string) (Ref, error) {
	parts := strings.Split(p, "/")
	if len(parts) != 5 {
		return Ref{}, fmt.Errorf("%q is not <site>/<collector>/<instance-key>/<day>/<seq>-<end>", p)
	}
	site, coll, key, day, leaf := parts[0], parts[1], parts[2], parts[3], parts[4]
	if !ValidName(site) || !ValidName(coll) {
		return Ref{}, fmt.Errorf("%q: the site or the collector is not a name", p)
	}
	if _, err := InstanceName(key); err != nil {
		return Ref{}, fmt.Errorf("%q: %w", p, err)
	}
	m := leafRE.FindStringSubmatch(leaf)
	if m == nil {
		return Ref{}, fmt.Errorf("%q: the last part is not <seq:10 digits>-<yyyymmddThhmmssZ>", p)
	}
	seq, err := strconv.ParseUint(m[1], 10, 64)
	if err != nil || seq == 0 {
		return Ref{}, fmt.Errorf("%q: the seq starts at 1", p)
	}
	end, err := time.Parse("20060102T150405Z", m[2])
	if err != nil {
		return Ref{}, fmt.Errorf("%q: %w", p, err)
	}
	if end.Format("2006-01-02") != day {
		return Ref{}, fmt.Errorf("%q: the day is not the window end's", p)
	}
	return Ref{Site: site, Collector: coll, InstanceKey: key, Seq: seq, End: end}, nil
}

// Manifest is manifest.json.
type Manifest struct {
	Format         int       `json:"format"`
	PgvigilVersion string    `json:"pgvigil_version"`
	SchemaLevel    string    `json:"schema_level"` // the newest migration the writing binary carries
	Site           string    `json:"site"`
	Collector      string    `json:"collector"`
	Stream         string    `json:"stream"` // random, new with a new state folder: a new stream starts a new seq
	Seq            uint64    `json:"seq"`
	WindowFrom     time.Time `json:"window_from"`
	WindowTo       time.Time `json:"window_to"`
	QueryText      string    `json:"query_text"` // hash or none
	Instance       Instance  `json:"instance"`
	Files          []File    `json:"files"`
	SumsSHA256     string    `json:"sums_sha256"`
	Reads          []Read    `json:"reads"`
	Runs           []Run     `json:"runs"`
	Failures       []Failure `json:"failures"`
	Cursors        []Cursor  `json:"cursors"`
	Heartbeat      Heartbeat `json:"heartbeat"`
}

// Instance is ensure_instance's arguments, as the collector saw the instance.
type Instance struct {
	Engine        string   `json:"engine"`
	Name          string   `json:"name"`
	Platform      string   `json:"platform"`
	ServerVersion string   `json:"server_version"`
	VersionNum    int      `json:"version_num"`
	IsReplica     bool     `json:"is_replica"`
	Tags          []string `json:"tags"`
}

// File is one view file.
type File struct {
	View     string `json:"view"`
	Name     string `json:"name"`
	Batches  int    `json:"batches"`
	Rows     int64  `json:"rows"`
	Bytes    int64  `json:"bytes"`     // the file as written (gzip)
	RawBytes int64  `json:"raw_bytes"` // uncompressed
	SHA256   string `json:"sha256"`    // of the file as written
}

// Read is how one collection of the schedule ended in the interval.
type Read struct {
	Collection string `json:"collection"`
	Status     string `json:"status"`
	Runs       int    `json:"runs,omitempty"`
	Failed     int    `json:"failed,omitempty"`
	Reason     string `json:"reason,omitempty"`
	// IntervalSecs is the collection's interval on the collector (its yaml's schedules): the hub judges a remote
	// collection's staleness by it, not by its own defaults. 0 = not scheduled (a skipped read 'off').
	IntervalSecs int `json:"interval_secs,omitempty"`
}

// Run is one run of a collection: log_collection's arguments.
type Run struct {
	Collection string    `json:"collection"`
	At         time.Time `json:"at"`
	Ms         int64     `json:"ms"`
	Status     string    `json:"status"`
	Note       string    `json:"note,omitempty"`
	Stage      string    `json:"stage,omitempty"`
}

// Failure is a run that never reached its rows: a connect, a secret or a run failure.
type Failure struct {
	Kind       string    `json:"kind"`
	Collection string    `json:"collection"`
	At         time.Time `json:"at"`
	Ms         int64     `json:"ms"`
	Cause      string    `json:"cause"`
}

// Cursor is how far a source was read when the bundle closed: a log cursor (At), a SQL Server file cursor
// (FileName, FileOffset, LastEventAt, LastSeq), a one-number cursor (Seq), a list a SQL function keeps beside its
// cursor (Names: backup_history's database list, backup_files' unlisted databases and the sets it holds) or a source
// the store holds as NULL (null: its reader answers not found).
type Cursor struct {
	Source      string     `json:"source"`
	Kind        string     `json:"kind"` // log | mssql | seq | list | null
	At          *time.Time `json:"at,omitempty"`
	FileName    string     `json:"file_name,omitempty"`
	FileOffset  int64      `json:"file_offset,omitempty"`
	LastEventAt *time.Time `json:"last_event_at,omitempty"`
	LastSeq     int64      `json:"last_seq,omitempty"`
	Seq         int64      `json:"seq,omitempty"`
	Names       []string   `json:"names,omitempty"`
}

// check holds a cursor to its kind: a known kind with a source, no names but on a list, no value on a null.
func (c Cursor) check() error {
	switch {
	case c.Source == "":
		return fmt.Errorf("a cursor of kind %q without its source", c.Kind)
	case c.Kind != "log" && c.Kind != "mssql" && c.Kind != "seq" && c.Kind != "list" && c.Kind != "null":
		return fmt.Errorf("cursor %q of kind %q (log, mssql, seq, list or null)", c.Source, c.Kind)
	case c.Kind != "list" && c.Names != nil:
		return fmt.Errorf("cursor %q of kind %s carries names", c.Source, c.Kind)
	case c.Kind == "null" && (c.At != nil || c.FileName != "" || c.FileOffset != 0 || c.LastEventAt != nil || c.LastSeq != 0 || c.Seq != 0):
		return fmt.Errorf("cursor %q of kind null carries a value", c.Source)
	}
	return nil
}

// Heartbeat is the collector's own state when the bundle closed.
type Heartbeat struct {
	Host       string    `json:"host"`
	Started    time.Time `json:"started"`
	At         time.Time `json:"at"`
	Instances  int       `json:"instances"`
	FailStreak int       `json:"fail_streak"`
}

// DecodeManifest reads manifest.json strictly: a newer format is ErrNewerFormat, an unknown key, a missing
// required value or a value out of its set is an error.
func DecodeManifest(b []byte) (*Manifest, error) {
	var head struct {
		Format *int `json:"format"`
	}
	if err := json.Unmarshal(b, &head); err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	switch {
	case head.Format == nil || *head.Format < 1:
		return nil, errors.New("manifest: no format version")
	case *head.Format > Version:
		return nil, fmt.Errorf("manifest: format %d, this pgvigil reads up to %d: %w", *head.Format, Version, ErrNewerFormat)
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	var m Manifest
	if err := d.Decode(&m); err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	if d.More() {
		return nil, errors.New("manifest: more than one JSON value")
	}
	if err := m.check(); err != nil {
		return nil, fmt.Errorf("manifest: %w", err)
	}
	return &m, nil
}

func (m *Manifest) check() error {
	switch {
	case !ValidName(m.Site) || !ValidName(m.Collector):
		return fmt.Errorf("site %q or collector %q is not a name", m.Site, m.Collector)
	case !streamRE.MatchString(m.Stream):
		return fmt.Errorf("stream %q is not 16 to 64 lower-case hex digits", m.Stream)
	case m.Seq == 0:
		return errors.New("no seq (it starts at 1)")
	case m.WindowFrom.IsZero() || m.WindowTo.IsZero() || m.WindowTo.Before(m.WindowFrom):
		return errors.New("no window, or one that ends before it starts")
	case m.QueryText != "hash" && m.QueryText != "none":
		return fmt.Errorf("query_text %q: a bundle holds hash or none", m.QueryText)
	case m.Instance.Engine != "postgres" && m.Instance.Engine != "sqlserver":
		return fmt.Errorf("engine %q is neither postgres nor sqlserver", m.Instance.Engine)
	case strings.TrimSpace(m.Instance.Name) == "":
		return errors.New("no instance name")
	case !hex64RE.MatchString(m.SumsSHA256):
		return errors.New("sums_sha256 is not a sha256")
	}
	if err := m.checkFiles(); err != nil {
		return err
	}
	for _, r := range m.Reads {
		switch {
		case r.Collection == "":
			return errors.New("a read without its collection")
		case r.Status == ReadSkipped && !skipReasons[r.Reason]:
			return fmt.Errorf("read %s: skipped needs a reason (off, not_due, not_applicable, running), got %q", r.Collection, r.Reason)
		case r.Status != ReadRan && r.Status != ReadFailed && r.Status != ReadSkipped:
			return fmt.Errorf("read %s: status %q is not ran, failed or skipped", r.Collection, r.Status)
		case r.IntervalSecs < 0:
			return fmt.Errorf("read %s: a negative interval", r.Collection)
		}
	}
	for _, r := range m.Runs {
		if r.Collection == "" || r.Status == "" || r.At.IsZero() {
			return errors.New("a run without its collection, status or time")
		}
	}
	for _, f := range m.Failures {
		if f.Kind != "connect" && f.Kind != "secret" && f.Kind != "run" {
			return fmt.Errorf("a failure of kind %q (connect, secret or run)", f.Kind)
		}
	}
	for _, c := range m.Cursors {
		if err := c.check(); err != nil {
			return err
		}
	}
	return nil
}

// checkFiles holds each view file's entry to its shape: a view name, its file name, a batch at least, a sha256.
func (m *Manifest) checkFiles() error {
	seen := map[string]bool{}
	for _, f := range m.Files {
		switch {
		case !ValidView(f.View):
			return fmt.Errorf("view %q is not a view name", f.View)
		case f.Name != f.View+ViewExt:
			return fmt.Errorf("view %s's file is %q, not %s", f.View, f.Name, f.View+ViewExt)
		case seen[f.View]:
			return fmt.Errorf("view %s is listed twice", f.View)
		case f.Batches < 1 || f.Rows < 0 || f.Bytes < 1 || f.RawBytes < 1:
			return fmt.Errorf("view %s: a file holds a batch at least, and its sizes", f.View)
		case !hex64RE.MatchString(f.SHA256):
			return fmt.Errorf("view %s: its sha256 is not one", f.View)
		}
		seen[f.View] = true
	}
	return nil
}

// Matches holds the manifest to the folder it was found in (and that to the hub's configuration): a manifest
// that names another site, collector, instance, seq or window end is not this bundle's.
func (m *Manifest) Matches(r Ref) error {
	switch {
	case m.Site != r.Site || m.Collector != r.Collector:
		return fmt.Errorf("the manifest names %s/%s, the folder %s/%s", m.Site, m.Collector, r.Site, r.Collector)
	case InstanceKey(m.Instance.Name) != r.InstanceKey:
		return fmt.Errorf("the manifest names instance %q, the folder %s", m.Instance.Name, r.InstanceKey)
	case m.Seq != r.Seq:
		return fmt.Errorf("the manifest's seq %d, the folder's %d", m.Seq, r.Seq)
	case !m.WindowTo.Truncate(time.Second).Equal(r.End):
		return fmt.Errorf("the manifest's window ends %s, the folder's %s", m.WindowTo.UTC().Format(time.RFC3339), r.End.Format(time.RFC3339))
	}
	return nil
}

// Line is one batch in a view file.
type Line struct {
	N    int64           `json:"n"`    // the batch's number across the whole bundle, from 1: the order the store received them in
	At   time.Time       `json:"at"`   // the batch's snapshot time
	Rows json.RawMessage `json:"rows"` // a JSON list of row objects, the bytes as written (no number rounded)
}
