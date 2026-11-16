package remote

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

var (
	t0   = time.Date(2026, 11, 16, 17, 50, 0, 0, time.UTC)
	t1   = t0.Add(5 * time.Minute)
	inst = format.Instance{Engine: "sqlserver", Name: `HOST\INST`, Platform: "onprem", ServerVersion: "16.0.4295.3", VersionNum: 16, Tags: []string{"env:prod"}}
)

func opts(outbox string) BundleOptions {
	return BundleOptions{Outbox: outbox, Site: "site1", Collector: "coll1", Stream: "3f9c0a7e5b1d2c48", Seq: 7, From: t0, To: t1,
		Instance: inst, QueryText: "hash", PgvigilVersion: "v0.4.0-test", SchemaLevel: "0329_remote"}
}

// A bundle written by the writer is one the format's reader takes whole: its folder, its manifest, its lines in
// the order the batches came, every row as the collector gave it.
func TestBundleWriteRead(t *testing.T) {
	out := t.TempDir()
	b, err := OpenBundle(opts(out))
	if err != nil {
		t.Fatal(err)
	}
	big := int64(9223372036854775807)
	add := func(view string, at time.Time, rows []map[string]any) {
		t.Helper()
		if err := b.AddBatch(view, at, rows); err != nil {
			t.Fatal(err)
		}
	}
	add("mssql_activity", t0.Add(time.Minute), []map[string]any{{"session_id": 52, "queryid": big, "query": "5d41"}, {"session_id": 61, "query": nil}})
	add("mssql_ag", t0.Add(90*time.Second), []map[string]any{{"group_name": "ag1", "role": "PRIMARY"}})
	add("mssql_activity", t0.Add(2*time.Minute), []map[string]any{{"session_id": 52, "wait_type": "LCK_M_X"}})
	add("mssql_ag", t0.Add(3*time.Minute), nil) // a batch of no rows is kept: the import is called with it
	b.AddRun(format.Run{Collection: "mssql_activity", At: t0.Add(time.Minute), Ms: 120, Status: "ok"})
	b.AddFailure(format.Failure{Kind: "connect", Collection: "mssql_jobs", At: t0.Add(4 * time.Minute), Ms: 3000, Cause: "timeout"})
	reads := []format.Read{{Collection: "mssql_activity", Status: format.ReadRan, Runs: 2}, {Collection: "mssql_jobs", Status: format.ReadSkipped, Reason: "not_due"}}
	at := t1
	cursors := []format.Cursor{{Source: "errorlog", Kind: "mssql", FileName: "ERRORLOG", FileOffset: 4096, LastEventAt: &at}}
	ref, err := b.Close(t1, reads, cursors, format.Heartbeat{Host: "jump01", Started: t0, At: t1, Instances: 1})
	if err != nil {
		t.Fatal(err)
	}
	want := format.Ref{Site: "site1", Collector: "coll1", InstanceKey: "HOST%5CINST", Seq: 7, End: t1}
	if ref != want {
		t.Fatalf("ref %+v, want %+v", ref, want)
	}
	dir := filepath.Join(out, filepath.FromSlash(ref.Dir()))
	m, err := format.DecodeManifest(read(t, filepath.Join(dir, format.ManifestFile)))
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Matches(ref); err != nil {
		t.Fatal(err)
	}
	if err := format.Verify(os.DirFS(dir), m, 1<<20); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if len(m.Files) != 2 || m.Files[0].View != "mssql_activity" || m.Files[0].Batches != 2 || m.Files[0].Rows != 3 || m.Files[1].Batches != 2 || m.Files[1].Rows != 1 {
		t.Errorf("files: %+v", m.Files)
	}
	if len(m.Runs) != 1 || len(m.Failures) != 1 || len(m.Reads) != 2 || len(m.Cursors) != 1 || m.Heartbeat.Host != "jump01" || m.Seq != 7 || m.QueryText != "hash" {
		t.Errorf("manifest: %+v", m)
	}
	acts, err := format.ReadLines(os.DirFS(dir), m.Files[0], 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	ags, err := format.ReadLines(os.DirFS(dir), m.Files[1], 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if acts[0].N != 1 || ags[0].N != 2 || acts[1].N != 3 || ags[1].N != 4 || !acts[1].At.Equal(t0.Add(2*time.Minute)) {
		t.Errorf("the order: %d %d %d %d", acts[0].N, ags[0].N, acts[1].N, ags[1].N)
	}
	if !bytes.Contains(acts[0].Rows, []byte("9223372036854775807")) || string(ags[1].Rows) != "[]" {
		t.Errorf("rows: %s / %s", acts[0].Rows, ags[1].Rows)
	}
	var rows []map[string]json.RawMessage
	if err := json.Unmarshal(acts[0].Rows, &rows); err != nil || string(rows[1]["query"]) != "null" {
		t.Errorf("a null stays null: %v %s", err, rows)
	}
	// nothing else is left in the outbox: no .part folder
	if parts := findParts(t, out); len(parts) != 0 {
		t.Errorf(".part left: %v", parts)
	}
}

// An interval with nothing in it is still a bundle: silence on the hub then means the collector or the transfer.
func TestEmptyBundle(t *testing.T) {
	out := t.TempDir()
	b, err := OpenBundle(opts(out))
	if err != nil {
		t.Fatal(err)
	}
	ref, err := b.Close(t1, []format.Read{{Collection: "mssql_activity", Status: format.ReadSkipped, Reason: "off"}}, nil, format.Heartbeat{Host: "h", Started: t0, At: t1})
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(out, filepath.FromSlash(ref.Dir()))
	m, err := format.DecodeManifest(read(t, filepath.Join(dir, format.ManifestFile)))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Files) != 0 || format.Verify(os.DirFS(dir), m, 1<<20) != nil {
		t.Errorf("an empty bundle: %+v", m.Files)
	}
}

// While a bundle is open only its .part folder exists, and no manifest is in it; a bundle abandoned (a crash before
// the rename) leaves its .part folder, which CleanParts removes and nothing else.
func TestPartUntilClose(t *testing.T) {
	out := t.TempDir()
	b, err := OpenBundle(opts(out))
	if err != nil {
		t.Fatal(err)
	}
	if err := b.AddBatch("mssql_ag", t0, []map[string]any{{"x": 1}}); err != nil {
		t.Fatal(err)
	}
	parts := findParts(t, out)
	if len(parts) != 1 || !strings.HasSuffix(parts[0], format.PartExt) {
		t.Fatalf("while open: %v", parts)
	}
	if _, err := os.Stat(filepath.Join(parts[0], format.ManifestFile)); !os.IsNotExist(err) {
		t.Errorf("a manifest in an open bundle: %v", err)
	}
	b.Abandon()
	// a finished bundle beside it is kept
	b2, err := OpenBundle(func() BundleOptions { o := opts(out); o.Seq = 8; o.From, o.To = t1, t1.Add(5*time.Minute); return o }())
	if err != nil {
		t.Fatal(err)
	}
	ref2, err := b2.Close(t1.Add(5*time.Minute), nil, nil, format.Heartbeat{Host: "h", Started: t0, At: t1})
	if err != nil {
		t.Fatal(err)
	}
	n, err := CleanParts(out)
	if err != nil || n != 1 {
		t.Fatalf("CleanParts: %d, %v", n, err)
	}
	if left := findParts(t, out); len(left) != 0 {
		t.Errorf("after CleanParts: %v", left)
	}
	if _, err := os.Stat(filepath.Join(out, filepath.FromSlash(ref2.Dir()), format.ManifestFile)); err != nil {
		t.Errorf("the finished bundle: %v", err)
	}
}

// A clean stop closes the bundle early: its folder carries the real end, not the planned one.
func TestEarlyClose(t *testing.T) {
	out := t.TempDir()
	b, err := OpenBundle(opts(out))
	if err != nil {
		t.Fatal(err)
	}
	early := t0.Add(2*time.Minute + 500*time.Millisecond)
	ref, err := b.Close(early, nil, nil, format.Heartbeat{Host: "h", Started: t0, At: early})
	if err != nil {
		t.Fatal(err)
	}
	if !ref.End.Equal(early.Truncate(time.Second)) {
		t.Errorf("end %v", ref.End)
	}
	m, err := format.DecodeManifest(read(t, filepath.Join(out, filepath.FromSlash(ref.Dir()), format.ManifestFile)))
	if err != nil || m.Matches(ref) != nil {
		t.Errorf("manifest of an early close: %v", err)
	}
}

// A signing collector's manifest.sig verifies with its public key, and a changed manifest does not.
func TestSignedBundle(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	out := t.TempDir()
	o := opts(out)
	o.Key = priv
	b, err := OpenBundle(o)
	if err != nil {
		t.Fatal(err)
	}
	if err := b.AddBatch("mssql_ag", t0, []map[string]any{{"x": 1}}); err != nil {
		t.Fatal(err)
	}
	ref, err := b.Close(t1, nil, nil, format.Heartbeat{Host: "h", Started: t0, At: t1})
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(out, filepath.FromSlash(ref.Dir()))
	man, sig := read(t, filepath.Join(dir, format.ManifestFile)), read(t, filepath.Join(dir, format.SigFile))
	if err := format.VerifySignature([][]byte{pub}, man, sig); err != nil {
		t.Fatalf("VerifySignature: %v", err)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if format.VerifySignature([][]byte{other}, man, sig) == nil {
		t.Errorf("another key verified it")
	}
	if format.VerifySignature([][]byte{other, pub}, man, sig) != nil {
		t.Errorf("the second of two listed keys did not")
	}
	changed := bytes.Replace(man, []byte(`"seq": 7`), []byte(`"seq": 8`), 1)
	if format.VerifySignature([][]byte{pub}, changed, sig) == nil {
		t.Errorf("a changed manifest verified")
	}
	m, _ := format.DecodeManifest(man)
	if err := format.Verify(os.DirFS(dir), m, 1<<20); err != nil {
		t.Errorf("a signed bundle's folder (manifest.sig is a known file): %v", err)
	}
}

// A view name that is no view name is refused at the write, never a file outside the bundle's folder.
func TestAddBatchRefusesABadView(t *testing.T) {
	b, err := OpenBundle(opts(t.TempDir()))
	if err != nil {
		t.Fatal(err)
	}
	defer b.Abandon()
	for _, v := range []string{"../x", "", "A", "a/b"} {
		if err := b.AddBatch(v, t0, nil); err == nil {
			t.Errorf("view %q taken", v)
		}
	}
}

func read(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func findParts(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && strings.HasSuffix(p, format.PartExt) {
			out = append(out, p)
			return filepath.SkipDir
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}
