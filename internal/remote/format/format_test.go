package format

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fixtureDir = "testdata/ok/site1/coll1/HOST%5CINST/2026-11-16/0000000001-20261116T175500Z"

// A name that is not a path part stays one path part, and comes back whole.
func TestInstanceKeyRoundTrip(t *testing.T) {
	for name, want := range map[string]string{
		`HOST\INST`:         "HOST%5CINST",
		"pg-01.example.com": "pg-01.example.com",
		"a/b c":             "a%2Fb%20c",
		"100%":              "100%25",
		"..":                "%2E.",
		".hidden":           "%2Ehidden",
		"ü":                 "%C3%BC",
	} {
		got := InstanceKey(name)
		if got != want {
			t.Errorf("InstanceKey(%q) = %q, want %q", name, got, want)
		}
		back, err := InstanceName(got)
		if err != nil || back != name {
			t.Errorf("InstanceName(%q) = %q, %v; want %q", got, back, err, name)
		}
	}
	// one name, one key: a byte written encoded that need not be (%41), lower-case hex or a leading dot left bare is refused
	for _, bad := range []string{"", "a%zz", "a%2", "a b", "a/b", "%2e.", "%41", "..", ".hidden", "%5c"} {
		if _, err := InstanceName(bad); err == nil {
			t.Errorf("InstanceName(%q): no error", bad)
		}
	}
}

// Site and collector names: lower-case letters, digits, '_', '.', '-', a letter or a digit first, at most 63.
func TestValidName(t *testing.T) {
	for _, ok := range []string{"site1", "acme-east", "a", "z.9_x", strings.Repeat("a", 63)} {
		if !ValidName(ok) {
			t.Errorf("ValidName(%q) = false", ok)
		}
	}
	for _, bad := range []string{"", "Site", "-a", ".a", "a/b", "a b", strings.Repeat("a", 64), "a\\b"} {
		if ValidName(bad) {
			t.Errorf("ValidName(%q) = true", bad)
		}
	}
}

// The bundle's folder is <site>/<collector>/<instance-key>/<day>/<seq>-<window end>, and parses back.
func TestBundleDirRoundTrip(t *testing.T) {
	ref := Ref{Site: "site1", Collector: "coll1", InstanceKey: "HOST%5CINST", Seq: 1, End: time.Date(2026, 11, 16, 17, 55, 0, 0, time.UTC)}
	const want = "site1/coll1/HOST%5CINST/2026-11-16/0000000001-20261116T175500Z"
	if got := ref.Dir(); got != want {
		t.Fatalf("Dir() = %q, want %q", got, want)
	}
	back, err := ParseDir(want)
	if err != nil || back != ref {
		t.Fatalf("ParseDir(%q) = %+v, %v; want %+v", want, back, err, ref)
	}
	// a window end off UTC is written in UTC
	cet := time.FixedZone("CET", 3600)
	if got := (Ref{Site: "s", Collector: "c", InstanceKey: "i", Seq: 7, End: time.Date(2026, 11, 17, 0, 30, 0, 0, cet)}).Dir(); got != "s/c/i/2026-11-16/0000000007-20261116T233000Z" {
		t.Errorf("a CET end: %q", got)
	}
	for _, bad := range []string{
		"site1/coll1/HOST%5CINST/2026-11-16/0000000001-20261116T175500Z/extra",
		"site1/coll1/HOST%5CINST/2026-11-16/1-20261116T175500Z",          // seq not 10 digits
		"site1/coll1/HOST%5CINST/2026-11-15/0000000001-20261116T175500Z", // day not the end's
		"Site1/coll1/HOST%5CINST/2026-11-16/0000000001-20261116T175500Z", // site not a name
		"site1/coll1/HOST INST/2026-11-16/0000000001-20261116T175500Z",   // key not encoded
		"site1/coll1/HOST%5CINST/2026-11-16/0000000000-20261116T175500Z", // seq 0
		"site1/coll1/HOST%5CINST/2026-11-16/0000000001-20261116T175500Z.part",
	} {
		if _, err := ParseDir(bad); err == nil {
			t.Errorf("ParseDir(%q): no error", bad)
		}
	}
}

// The bundle made by gzip and sha256sum alone (testdata/make-fixture.sh) decodes and verifies.
func TestFixtureVerifies(t *testing.T) {
	m := fixtureManifest(t)
	if m.Format != Version || m.Site != "site1" || m.Collector != "coll1" || m.Seq != 1 || m.Instance.Name != `HOST\INST` || m.Instance.Engine != "sqlserver" {
		t.Fatalf("manifest: %+v", m)
	}
	if len(m.Files) != 2 || len(m.Reads) != 3 || len(m.Runs) != 4 || len(m.Cursors) != 2 {
		t.Fatalf("manifest lists: %d files, %d reads, %d runs, %d cursors", len(m.Files), len(m.Reads), len(m.Runs), len(m.Cursors))
	}
	status := map[string]string{}
	for _, r := range m.Reads {
		status[r.Collection] = r.Status
	}
	if status["mssql_activity"] != ReadRan || status["mssql_ag"] != ReadFailed || status["mssql_jobs"] != ReadSkipped {
		t.Errorf("reads: %v", status)
	}
	ref, err := ParseDir(strings.TrimPrefix(fixtureDir, "testdata/ok/"))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Matches(ref); err != nil {
		t.Errorf("the manifest against its own folder: %v", err)
	}
	if err := Verify(os.DirFS(fixtureDir), m, 1<<20); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	// a line's rows come through as the bytes written: an integer above 2^53 is not rounded
	lines, err := ReadLines(os.DirFS(fixtureDir), m.Files[0], 1<<20)
	if err != nil || len(lines) != 2 || lines[0].N != 1 || lines[1].N != 3 {
		t.Fatalf("ReadLines: %v, %+v", err, lines)
	}
	if !bytes.Contains(lines[0].Rows, []byte("9223372036854775807")) {
		t.Errorf("the rows lost the big integer: %s", lines[0].Rows)
	}
}

// Each fault is refused with its kind, so ingest tells 'incomplete, retry' (missing, short) from a set-aside.
func TestVerifyRefuses(t *testing.T) {
	for _, c := range []struct {
		name string
		kind string
		edit func(t *testing.T, dir string, m *Manifest)
		max  int64
	}{
		{"a changed byte", KindChecksum, func(t *testing.T, dir string, m *Manifest) { flipByte(t, filepath.Join(dir, "mssql_ag.ndjson.gz"), 20) }, 0},
		{"a cut file", KindShort, func(t *testing.T, dir string, m *Manifest) { cut(t, filepath.Join(dir, "mssql_ag.ndjson.gz"), 10) }, 0},
		{"a missing file", KindMissing, func(t *testing.T, dir string, m *Manifest) { rm(t, filepath.Join(dir, "mssql_ag.ndjson.gz")) }, 0},
		{"a missing sums file", KindMissing, func(t *testing.T, dir string, m *Manifest) { rm(t, filepath.Join(dir, SumsFile)) }, 0},
		{"a file the manifest does not list", KindExtra, func(t *testing.T, dir string, m *Manifest) { write(t, filepath.Join(dir, "x.ndjson.gz"), []byte("x")) }, 0},
		{"a row count off by one", KindCount, func(t *testing.T, dir string, m *Manifest) { m.Files[0].Rows++ }, 0},
		{"a batch count off by one", KindCount, func(t *testing.T, dir string, m *Manifest) { m.Files[1].Batches = 2 }, 0},
		{"a changed sums file", KindChecksum, func(t *testing.T, dir string, m *Manifest) {
			b := readFile(t, filepath.Join(dir, SumsFile))
			write(t, filepath.Join(dir, SumsFile), append(b, '\n'))
		}, 0},
		{"a sums file that names another file", KindChecksum, func(t *testing.T, dir string, m *Manifest) {
			b := bytes.Replace(readFile(t, filepath.Join(dir, SumsFile)), []byte("mssql_ag.ndjson.gz"), []byte("mssql_xx.ndjson.gz"), 1)
			write(t, filepath.Join(dir, SumsFile), b)
			m.SumsSHA256 = sha(b)
		}, 0},
		{"a batch number twice", KindMalformed, func(t *testing.T, dir string, m *Manifest) {
			regz(t, dir, m, "mssql_ag", `{"n":1,"at":"2026-11-16T17:51:30Z","rows":[{"group_name":"ag1","role":"PRIMARY"},{"group_name":"ag1","role":"SECONDARY"}]}`+"\n")
		}, 0},
		{"rows that are not a list", KindMalformed, func(t *testing.T, dir string, m *Manifest) {
			regz(t, dir, m, "mssql_ag", `{"n":2,"at":"2026-11-16T17:51:30Z","rows":{"group_name":"ag1"}}`+"\n")
		}, 0},
		{"more bytes than the cap", KindTooBig, func(t *testing.T, dir string, m *Manifest) {}, 100},
		{"a view name that is no name", KindMalformed, func(t *testing.T, dir string, m *Manifest) { m.Files[1].View = "../x" }, 0},
		{"a file name that is not its view's", KindMalformed, func(t *testing.T, dir string, m *Manifest) { m.Files[1].Name = "other.ndjson.gz" }, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			dir := copyFixture(t)
			m := fixtureManifest(t)
			c.edit(t, dir, m)
			max := c.max
			if max == 0 {
				max = 1 << 20
			}
			err := Verify(os.DirFS(dir), m, max)
			var p *Problem
			if !errors.As(err, &p) || p.Kind != c.kind {
				t.Fatalf("Verify: %v (want kind %q)", err, c.kind)
			}
		})
	}
}

// DecodeManifest is strict: a newer format is ErrNewerFormat (set aside, read after the hub's upgrade), an unknown
// key or a missing one is an error.
func TestDecodeManifest(t *testing.T) {
	b := readFile(t, filepath.Join(fixtureDir, ManifestFile))
	newer := bytes.Replace(b, []byte(`"format": 1`), []byte(`"format": 2`), 1)
	if _, err := DecodeManifest(newer); !errors.Is(err, ErrNewerFormat) {
		t.Errorf("format 2: %v", err)
	}
	unknown := bytes.Replace(b, []byte(`"seq": 1,`), []byte(`"seq": 1, "surprise": true,`), 1)
	if _, err := DecodeManifest(unknown); err == nil {
		t.Errorf("an unknown key: no error")
	}
	for _, key := range []string{`"site": "site1",`, `"stream": "3f9c0a7e5b1d2c48",`, `"seq": 1,`} {
		if _, err := DecodeManifest(bytes.Replace(b, []byte(key), nil, 1)); err == nil {
			t.Errorf("without %s: no error", key)
		}
	}
	// each read carries its collection's interval on the collector (the hub's staleness judges by it)
	m0, err := DecodeManifest(b)
	if err != nil || m0.Reads[0].IntervalSecs != 60 || m0.Reads[1].IntervalSecs != 120 || m0.Reads[2].IntervalSecs != 0 {
		t.Errorf("interval_secs: %v %+v", err, m0)
	}
	if _, err := DecodeManifest(bytes.Replace(b, []byte(`"interval_secs": 60`), []byte(`"interval_secs": -1`), 1)); err == nil {
		t.Errorf("a negative interval: no error")
	}
	// a bundle holds hash or none: the hub refuses any other text mode (the lead's 11:3x named check; H's ingest decodes
	// through DecodeManifest)
	for _, mode := range []string{"full", "normalized", ""} {
		if _, err := DecodeManifest(bytes.Replace(b, []byte(`"query_text": "hash"`), []byte(`"query_text": "`+mode+`"`), 1)); err == nil {
			t.Errorf("query_text %q: no error", mode)
		}
	}
	bad := bytes.Replace(b, []byte(`"status": "ran"`), []byte(`"status": "maybe"`), 1)
	if _, err := DecodeManifest(bad); err == nil {
		t.Errorf("a read status that is not ran / failed / skipped: no error")
	}
	m := fixtureManifest(t)
	for _, other := range []Ref{{Site: "site2", Collector: "coll1", InstanceKey: "HOST%5CINST", Seq: 1, End: m.WindowTo}, {Site: "site1", Collector: "coll1", InstanceKey: "HOST%5CINST", Seq: 2, End: m.WindowTo}, {Site: "site1", Collector: "coll1", InstanceKey: "OTHER", Seq: 1, End: m.WindowTo}} {
		if err := m.Matches(other); err == nil {
			t.Errorf("Matches(%+v): no error", other)
		}
	}
}

func fixtureManifest(t *testing.T) *Manifest {
	t.Helper()
	m, err := DecodeManifest(readFile(t, filepath.Join(fixtureDir, ManifestFile)))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func copyFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	err := fs.WalkDir(os.DirFS(fixtureDir), ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		write(t, filepath.Join(dir, p), readFile(t, filepath.Join(fixtureDir, p)))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

// regz rewrites a view's file with body and puts its new size and sums into the manifest and the sums file, so only
// the fault the case names is left.
func regz(t *testing.T, dir string, m *Manifest, view, body string) {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	for i := range m.Files {
		if m.Files[i].View != view {
			continue
		}
		f := &m.Files[i]
		write(t, filepath.Join(dir, f.Name), buf.Bytes())
		f.Bytes, f.RawBytes, f.SHA256 = int64(buf.Len()), int64(len(body)), sha(buf.Bytes())
	}
	var sums bytes.Buffer
	for _, f := range m.Files {
		sums.WriteString(f.SHA256 + "  " + f.Name + "\n")
	}
	write(t, filepath.Join(dir, SumsFile), sums.Bytes())
	m.SumsSHA256 = sha(sums.Bytes())
}

func readFile(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func write(t *testing.T, p string, b []byte) {
	t.Helper()
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func rm(t *testing.T, p string) {
	t.Helper()
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
}

func flipByte(t *testing.T, p string, at int) {
	t.Helper()
	b := readFile(t, p)
	b[at] ^= 0xff
	write(t, p, b)
}

func cut(t *testing.T, p string, n int) {
	t.Helper()
	b := readFile(t, p)
	write(t, p, b[:len(b)-n])
}

// The cursor kinds: log, mssql and seq carry a read position; list carries the names a SQL function keeps beside its
// cursor (backup_history's database list, backup_files' unlisted databases); null is a source the store holds as
// NULL (its reader answers not found). Any other kind is refused; a list's names round-trip in order.
func TestCursorKinds(t *testing.T) {
	m := fixtureManifest(t)
	for _, c := range []Cursor{{Source: "backup_history_dbs", Kind: "list", Names: []string{"app", "crm"}}, {Source: "backup_sets_mark", Kind: "null"}, {Source: "backup_sets_unlisted", Kind: "list"}} {
		m.Cursors = []Cursor{c}
		if err := m.check(); err != nil {
			t.Errorf("%+v: %v", c, err)
		}
	}
	for _, c := range []Cursor{{Source: "x", Kind: "set"}, {Source: "", Kind: "list"}, {Source: "y", Kind: "null", Seq: 3}, {Source: "z", Kind: "seq", Names: []string{"a"}}} {
		m.Cursors = []Cursor{c}
		if err := m.check(); err == nil {
			t.Errorf("%+v: no error", c)
		}
	}
	b, err := json.Marshal(Cursor{Source: "backup_history_dbs", Kind: "list", Names: []string{"crm", "app"}})
	if err != nil {
		t.Fatal(err)
	}
	var back Cursor
	if err := json.Unmarshal(b, &back); err != nil || len(back.Names) != 2 || back.Names[0] != "crm" || back.Names[1] != "app" {
		t.Errorf("round trip %s: %v %+v", b, err, back)
	}
}
