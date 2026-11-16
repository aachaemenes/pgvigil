// Package remote is the remote collector's side: the bundle it writes for each instance's interval (bundle.go),
// its local state (state.go) and the store the collectors write through (store.go). The format both sides read is
// internal/remote/format.
package remote

import (
	"compress/gzip"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// BundleOptions opens one instance's interval.
type BundleOptions struct {
	Outbox                      string // the collector's outbox folder
	Site, Collector, Stream     string
	Seq                         uint64 // reserved in the state before the bundle opens
	From, To                    time.Time
	Instance                    format.Instance
	QueryText                   string // hash or none
	PgvigilVersion, SchemaLevel string
	Key                         ed25519.PrivateKey // nil: the bundle is not signed
}

// Bundle is one open interval of one instance. Its files are written into <its folder>.part as the batches come;
// Close writes SHA256SUMS, manifest.sig and manifest.json (last), syncs them and renames the folder whole, so a
// reader of the outbox sees a whole bundle or none. Safe for the collections' goroutines at once.
type Bundle struct {
	mu       sync.Mutex
	o        BundleOptions
	part     string
	views    map[string]*viewFile
	n        int64
	runs     []format.Run
	failures []format.Failure
	err      error // the first write that failed: the bundle cannot be closed whole
	closed   bool
}

type viewFile struct {
	f       *os.File
	gz      *gzip.Writer
	sum     hash.Hash
	bytes   counter // compressed, as written
	raw     counter // uncompressed
	batches int
	rows    int64
}

type counter struct{ n int64 }

func (c *counter) Write(p []byte) (int, error) { c.n += int64(len(p)); return len(p), nil }

// OpenBundle makes the interval's .part folder (a leftover of the same seq from a crash is removed first: its
// interval is being read again).
func OpenBundle(o BundleOptions) (*Bundle, error) {
	switch {
	case !format.ValidName(o.Site) || !format.ValidName(o.Collector):
		return nil, fmt.Errorf("bundle: site %q or collector %q is not a name", o.Site, o.Collector)
	case o.Seq == 0:
		return nil, errors.New("bundle: the seq starts at 1")
	case strings.TrimSpace(o.Instance.Name) == "":
		return nil, errors.New("bundle: no instance name")
	case o.QueryText != "hash" && o.QueryText != "none":
		return nil, fmt.Errorf("bundle: query_text %q (hash or none)", o.QueryText)
	case o.To.Before(o.From):
		return nil, errors.New("bundle: the window ends before it starts")
	}
	ref := o.ref(o.To)
	part := filepath.Join(o.Outbox, filepath.FromSlash(ref.Dir())) + format.PartExt
	if err := os.RemoveAll(part); err != nil {
		return nil, fmt.Errorf("bundle: %w", err)
	}
	if err := os.MkdirAll(part, 0o750); err != nil {
		return nil, fmt.Errorf("bundle: %w", err)
	}
	return &Bundle{o: o, part: part, views: map[string]*viewFile{}}, nil
}

func (o BundleOptions) ref(end time.Time) format.Ref {
	return format.Ref{Site: o.Site, Collector: o.Collector, InstanceKey: format.InstanceKey(o.Instance.Name), Seq: o.Seq, End: end.UTC().Truncate(time.Second)}
}

// line is a view file's line as written.
type line struct {
	N    int64           `json:"n"`
	At   time.Time       `json:"at"`
	Rows json.RawMessage `json:"rows"`
}

// AddBatch appends one batch of a view's rows: one line, numbered across the bundle.
func (b *Bundle) AddBatch(view string, at time.Time, rows []map[string]any) error {
	if !format.ValidView(view) {
		return fmt.Errorf("bundle: %q is not a view name", view)
	}
	raw := []byte("[]")
	if len(rows) > 0 {
		var err error
		if raw, err = json.Marshal(rows); err != nil {
			return fmt.Errorf("bundle: %s's rows: %w", view, err)
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return errors.New("bundle: closed")
	}
	if b.err != nil {
		return b.err
	}
	text, err := json.Marshal(line{N: b.n + 1, At: at.UTC(), Rows: raw})
	if err != nil {
		return fmt.Errorf("bundle: %w", err)
	}
	text = append(text, '\n')
	vf, err := b.view(view)
	if err == nil {
		_, err = vf.gz.Write(text)
	}
	if err != nil {
		b.err = fmt.Errorf("bundle: %s: %w", view, err)
		return b.err
	}
	vf.raw.n += int64(len(text))
	b.n++
	vf.batches++
	vf.rows += int64(len(rows))
	return nil
}

// view opens a view's file on its first batch.
func (b *Bundle) view(name string) (*viewFile, error) {
	if vf, ok := b.views[name]; ok {
		return vf, nil
	}
	f, err := os.OpenFile(filepath.Join(b.part, name+format.ViewExt), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o640)
	if err != nil {
		return nil, err
	}
	vf := &viewFile{f: f, sum: sha256.New()}
	gz, err := gzip.NewWriterLevel(io.MultiWriter(f, vf.sum, &vf.bytes), gzip.BestCompression)
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	vf.gz = gz
	b.views[name] = vf
	return vf, nil
}

// AddRun records one run of a collection (log_collection's arguments).
func (b *Bundle) AddRun(r format.Run) {
	b.mu.Lock()
	defer b.mu.Unlock()
	r.At = r.At.UTC()
	b.runs = append(b.runs, r)
}

// AddFailure records a run that never reached its rows.
func (b *Bundle) AddFailure(f format.Failure) {
	b.mu.Lock()
	defer b.mu.Unlock()
	f.At = f.At.UTC()
	b.failures = append(b.failures, f)
}

// Close ends the interval at end: the view files closed and synced, SHA256SUMS, manifest.sig (when signing),
// manifest.json last, the folder synced and renamed to its name with end. A failure leaves nothing in the outbox
// but is returned; the caller keeps its cursors where they were, so the interval is read again.
func (b *Bundle) Close(end time.Time, reads []format.Read, cursors []format.Cursor, hb format.Heartbeat) (format.Ref, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return format.Ref{}, errors.New("bundle: closed")
	}
	ref, err := b.close(end, reads, cursors, hb)
	b.closed = true
	if err != nil {
		b.closeFiles()
		_ = os.RemoveAll(b.part)
		return format.Ref{}, err
	}
	return ref, nil
}

func (b *Bundle) close(end time.Time, reads []format.Read, cursors []format.Cursor, hb format.Heartbeat) (format.Ref, error) {
	if b.err != nil {
		return format.Ref{}, b.err
	}
	ref := b.o.ref(end)
	if ref.End.Before(b.o.From.UTC().Truncate(time.Second)) {
		return format.Ref{}, errors.New("bundle: the window ends before it starts")
	}
	names := make([]string, 0, len(b.views))
	for v := range b.views {
		names = append(names, v)
	}
	sort.Strings(names)
	files := []format.File{}
	var sums strings.Builder
	for _, v := range names {
		vf := b.views[v]
		if err := vf.gz.Close(); err != nil {
			return format.Ref{}, fmt.Errorf("bundle: %s: %w", v, err)
		}
		if err := vf.f.Sync(); err != nil {
			return format.Ref{}, fmt.Errorf("bundle: %s: %w", v, err)
		}
		if err := vf.f.Close(); err != nil {
			return format.Ref{}, fmt.Errorf("bundle: %s: %w", v, err)
		}
		vf.f = nil
		f := format.File{View: v, Name: v + format.ViewExt, Batches: vf.batches, Rows: vf.rows, Bytes: vf.bytes.n, RawBytes: vf.raw.n, SHA256: hex.EncodeToString(vf.sum.Sum(nil))}
		files = append(files, f)
		fmt.Fprintf(&sums, "%s  %s\n", f.SHA256, f.Name)
	}
	if err := writeSynced(filepath.Join(b.part, format.SumsFile), []byte(sums.String())); err != nil {
		return format.Ref{}, err
	}
	s := sha256.Sum256([]byte(sums.String()))
	m := format.Manifest{
		Format: format.Version, PgvigilVersion: b.o.PgvigilVersion, SchemaLevel: b.o.SchemaLevel,
		Site: b.o.Site, Collector: b.o.Collector, Stream: b.o.Stream, Seq: b.o.Seq,
		WindowFrom: b.o.From.UTC(), WindowTo: ref.End, QueryText: b.o.QueryText, Instance: b.o.Instance,
		Files: files, SumsSHA256: hex.EncodeToString(s[:]),
		Reads: orEmpty(reads), Runs: orEmpty(b.runs), Failures: orEmpty(b.failures), Cursors: orEmpty(cursors), Heartbeat: hb,
	}
	man, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return format.Ref{}, fmt.Errorf("bundle: manifest: %w", err)
	}
	man = append(man, '\n')
	// the writer never leaves a manifest its readers refuse
	if _, err := format.DecodeManifest(man); err != nil {
		return format.Ref{}, fmt.Errorf("bundle: %w", err)
	}
	if b.o.Key != nil {
		if err := writeSynced(filepath.Join(b.part, format.SigFile), format.SignManifest(b.o.Key, man)); err != nil {
			return format.Ref{}, err
		}
	}
	if err := writeSynced(filepath.Join(b.part, format.ManifestFile), man); err != nil {
		return format.Ref{}, err
	}
	if err := syncDir(b.part); err != nil {
		return format.Ref{}, err
	}
	final := filepath.Join(b.o.Outbox, filepath.FromSlash(ref.Dir()))
	if _, err := os.Stat(final); err == nil {
		return format.Ref{}, fmt.Errorf("bundle: %s is already there: a seq is never written twice", ref.Dir())
	}
	if err := os.MkdirAll(filepath.Dir(final), 0o750); err != nil {
		return format.Ref{}, fmt.Errorf("bundle: %w", err)
	}
	if err := os.Rename(b.part, final); err != nil {
		return format.Ref{}, fmt.Errorf("bundle: %w", err)
	}
	for _, d := range []string{filepath.Dir(final), filepath.Dir(b.part)} {
		if err := syncDir(d); err != nil {
			return format.Ref{}, err
		}
	}
	return ref, nil
}

// Abandon closes the bundle's files and leaves its .part folder, as a crash would (the next start's CleanParts
// removes it).
func (b *Bundle) Abandon() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.closed {
		b.closeFiles()
		b.closed = true
	}
}

func (b *Bundle) closeFiles() {
	for _, vf := range b.views {
		if vf.f != nil {
			_ = vf.gz.Close()
			_ = vf.f.Close()
			vf.f = nil
		}
	}
}

// CleanParts removes every .part folder under the outbox: bundles a crash left open. Their intervals are read
// again (the cursors moved only with a finished bundle).
func CleanParts(outbox string) (int, error) {
	var parts []string
	err := filepath.WalkDir(outbox, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && strings.HasSuffix(d.Name(), format.PartExt) {
			parts = append(parts, p)
			return filepath.SkipDir
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	for _, p := range parts {
		if err := os.RemoveAll(p); err != nil {
			return 0, err
		}
	}
	return len(parts), nil
}

func orEmpty[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// writeSynced writes a whole file and syncs it.
func writeSynced(p string, b []byte) error {
	f, err := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o640)
	if err != nil {
		return fmt.Errorf("bundle: %w", err)
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return fmt.Errorf("bundle: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("bundle: %w", err)
	}
	return f.Close()
}

// syncDir makes a folder's entries (a new file, a rename) durable. Windows has no handle to sync a folder by; its
// file system writes the entry with the file.
func syncDir(p string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	d, err := os.Open(p)
	if err != nil {
		return fmt.Errorf("bundle: %w", err)
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("bundle: sync %s: %w", p, err)
	}
	return nil
}
