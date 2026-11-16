// Package ingest is the hub's side of the remote collector (docs/remote-collector.md): one loop per site reads the
// site's drop (internal/export's Get and List only: the hub never writes, moves or deletes there), checks every bundle
// (internal/remote/format, in the order docs/remote-bundle-format.md gives) and loads each one once through migration
// 0329, in sequence per collector, instance and stream.
package ingest

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// Drop is what ingest reads of a site's drop: an internal/export Destination's Get and List.
type Drop interface {
	Get(ctx context.Context, key string) ([]byte, error)
	List(ctx context.Context, prefix string) ([]string, error)
}

// Site is one remote_sites entry as ingest uses it.
type Site struct {
	Name string
	Drop Drop
	Tags []string
	// ExpectedEvery: how often a bundle arrives; GapWait: how long a missing seq is waited for, and how long a bundle
	// whose files are missing or short is taken for a copy still running (the settle time)
	ExpectedEvery, GapWait time.Duration
	// Collectors: the site's collectors, each with the Ed25519 public keys its manifests are signed with (none =
	// unsigned); a bundle of a collector not listed is set aside
	Collectors map[string][][]byte
}

// The reasons a bundle is not loaded (beside format.Problem's kinds: missing, short, checksum, extra, malformed,
// too_big, count).
const (
	KindLate        = "late"                 // an older seq after a newer one of the same stream was loaded
	KindConflict    = "conflict"             // a seq already loaded, with another manifest
	KindGap         = "gap"                  // seqs missing past gap_wait: ingest went on (recorded on the bundle after them)
	KindNewerFormat = "newer format"         // read again once the hub's format reaches it
	KindSignature   = "signature"            // the collector signs and the signature does not hold
	KindMismatch    = "mismatch"             // the manifest names another site, collector, instance, seq or window than its folder
	KindUnknownView = "unknown view"         // a view outside pgvigil's own list (R9)
	KindOwned       = "name owned elsewhere" // the instance's name is another site's or the hub's own configuration's
)

// Batch is one line of one view file.
type Batch struct {
	View string
	N    int64
	At   time.Time
	Rows json.RawMessage
}

// Bundle is one checked bundle, ready to load.
type Bundle struct {
	Ref      format.Ref
	Manifest *format.Manifest
	Digest   string  // the sha256 of manifest.json's bytes: two bundles of one seq with other digests are a conflict
	Batches  []Batch // every line of every view file, in n order
	// AfterGap: the bundle comes after seqs ingest went past (a gap or a bundle set aside): its audit batches move the
	// audit cursor to their start (0329's import_remote_batch), recorded as an 'audit gap'
	AfterGap bool
}

// Mark is a bundle the hub did not load (or a gap before one), with its reason.
type Mark struct {
	Site, Collector, Key, Stream string
	Seq                          uint64
	End                          time.Time
	Kind, Reason, Digest         string
}

// Newest is the newest loaded bundle of a collector's instance in one stream.
type Newest struct {
	Stream string
	Seq    uint64
	End    time.Time
}

// Hub is the repository's side (0329); load.go is its implementation on serve's or run's pool.
type Hub interface {
	// Newest: the newest loaded bundle of (site, collector, key) in stream ("" = in any stream)
	Newest(ctx context.Context, site, collector, key, stream string) (Newest, bool, error)
	// Recorded: a bundle of this seq already loaded or marked: its digest and its kind ("loaded" or a Kind)
	Recorded(ctx context.Context, site, collector, key, stream string, seq uint64) (digest, kind string, found bool, err error)
	// Load loads a checked bundle: the instance, every batch once (its own transaction with its ledger row), each
	// read's status, the runs and failures, the heartbeat, then the bundle's ledger row, the stream's high-water and
	// the instance's as_of in one transaction
	Load(ctx context.Context, site Site, b *Bundle) error
	// Mark records a bundle not loaded, or a gap
	Mark(ctx context.Context, m Mark) error
}

// Ingester is one site's loop.
type Ingester struct {
	Site   Site
	Hub    Hub
	Allow  map[string]bool // the views a bundle may carry (AllowList)
	Now    func() time.Time
	MaxRaw int64  // a view file's uncompressed cap
	Work   string // a folder a bundle is copied into to be checked
	Log    *slog.Logger
}

// Result counts one round: Skipped = loaded before, Kept = set aside before and still so (`pgvigil ingest -retry` reads
// one again), SetAside = set aside in this round.
type Result struct{ Loaded, Skipped, Kept, SetAside, Late, Conflicts, Gaps, Waiting int }

// ErrOwned is what a Hub's Load returns for an instance whose name another site or the hub's own file holds.
var ErrOwned = errors.New(KindOwned)

// candidate is one bundle folder found in the drop.
type candidate struct {
	ref    format.Ref
	files  map[string]bool // the file names the listing holds
	man    []byte          // manifest.json's bytes (nil: not there yet)
	digest string
	stream string // the manifest's, read loosely so a newer format still has one
}

// Round reads the site's drop once and loads what is due: per collector the site lists, per instance key found under
// it, the bundles from the day of the newest loaded one to today, in window order.
func (in *Ingester) Round(ctx context.Context) (Result, error) {
	var res Result
	colls := make([]string, 0, len(in.Site.Collectors))
	for c := range in.Site.Collectors {
		colls = append(colls, c)
	}
	sort.Strings(colls)
	for _, c := range colls {
		keys, err := in.instanceKeys(ctx, c)
		if err != nil {
			return res, err
		}
		for _, k := range keys {
			if err := in.group(ctx, c, k, &res); err != nil {
				return res, fmt.Errorf("ingest %s/%s/%s: %w", in.Site.Name, c, k, err)
			}
		}
	}
	return res, nil
}

// instanceKeys: the instance keys under <site>/<collector>/ (a drop's lifecycle rule keeps this listing short)
func (in *Ingester) instanceKeys(ctx context.Context, coll string) ([]string, error) {
	pfx := in.Site.Name + "/" + coll + "/"
	all, err := in.Site.Drop.List(ctx, pfx)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []string
	for _, k := range all {
		parts := strings.SplitN(strings.TrimPrefix(k, pfx), "/", 2)
		if len(parts) == 2 && !seen[parts[0]] {
			if _, err := format.InstanceName(parts[0]); err == nil {
				seen[parts[0]] = true
				out = append(out, parts[0])
			}
		}
	}
	sort.Strings(out)
	return out, nil
}

// candidates: the bundle folders of one instance key from day 'from' (zero: every day) to today, in window order
func (in *Ingester) candidates(ctx context.Context, coll, key string, from time.Time) ([]*candidate, error) {
	base := in.Site.Name + "/" + coll + "/" + key + "/"
	var prefixes []string
	if from.IsZero() {
		prefixes = []string{base}
	} else {
		today := in.Now().UTC().Truncate(24 * time.Hour)
		for d := from.UTC().Truncate(24 * time.Hour); !d.After(today); d = d.Add(24 * time.Hour) {
			prefixes = append(prefixes, base+d.Format("2006-01-02")+"/")
		}
	}
	byDir := map[string]*candidate{}
	for _, p := range prefixes {
		keys, err := in.Site.Drop.List(ctx, p)
		if err != nil {
			return nil, err
		}
		for _, k := range keys {
			i := strings.LastIndex(k, "/")
			if i < 0 {
				continue
			}
			dir, file := k[:i], k[i+1:]
			ref, err := format.ParseDir(dir)
			if err != nil {
				continue // a .part folder, a stray file: nobody reads it
			}
			c := byDir[dir]
			if c == nil {
				c = &candidate{ref: ref, files: map[string]bool{}}
				byDir[dir] = c
			}
			c.files[file] = true
		}
	}
	out := make([]*candidate, 0, len(byDir))
	for dir, c := range byDir {
		if c.files[format.ManifestFile] {
			b, err := in.Site.Drop.Get(ctx, dir+"/"+format.ManifestFile)
			if err != nil {
				return nil, err // listed but not read: the drop's, retried next round
			}
			sum := sha256.Sum256(b)
			c.man, c.digest = b, hex.EncodeToString(sum[:])
			var loose struct {
				Stream string `json:"stream"`
			}
			_ = json.Unmarshal(b, &loose)
			c.stream = loose.Stream
		}
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].ref.End.Equal(out[j].ref.End) {
			return out[i].ref.End.Before(out[j].ref.End)
		}
		return out[i].ref.Seq < out[j].ref.Seq
	})
	return out, nil
}

// group takes one instance key's bundles in order; a bundle that must wait (a missing seq, a copy still running) holds
// the ones after it until the next round.
func (in *Ingester) group(ctx context.Context, coll, key string, res *Result) error {
	var from time.Time
	if n, ok, err := in.Hub.Newest(ctx, in.Site.Name, coll, key, ""); err != nil {
		return err
	} else if ok {
		from = n.End
	}
	cands, err := in.candidates(ctx, coll, key, from)
	if err != nil {
		return err
	}
	for _, c := range cands {
		wait, err := in.take(ctx, coll, key, c, res)
		if err != nil {
			return err
		}
		if wait {
			res.Waiting++
			return nil
		}
	}
	return nil
}

// settling: the bundle is younger than the settle time (gap_wait from its window's end)
func (in *Ingester) settling(c *candidate) bool { return in.Now().Sub(c.ref.End) < in.Site.GapWait }

// retryKinds: a bundle marked so is read again when it appears with the same manifest (a copy that finished, a hub
// that was upgraded)
var retryKinds = map[string]bool{format.KindMissing: true, format.KindShort: true, KindNewerFormat: true}

// take checks one bundle and loads or marks it; wait = it, and the bundles after it, wait for the next round.
func (in *Ingester) take(ctx context.Context, coll, key string, c *candidate, res *Result) (bool, error) {
	site := in.Site.Name
	mark := func(kind, reason string) error {
		switch kind {
		case KindLate:
			res.Late++
		case KindConflict:
			res.Conflicts++
		case KindGap:
			res.Gaps++
		default:
			res.SetAside++
		}
		in.Log.Warn("remote bundle not loaded", "site", site, "bundle", c.ref.Dir(), "kind", kind, "reason", reason)
		return in.Hub.Mark(ctx, Mark{Site: site, Collector: coll, Key: key, Stream: c.stream, Seq: c.ref.Seq, End: c.ref.End, Kind: kind, Reason: reason, Digest: c.digest})
	}
	if c.man == nil { // no manifest yet: a copy still running, or one that never finished
		if in.settling(c) {
			return true, nil
		}
		return false, mark(format.KindMissing, "manifest.json is not in the drop")
	}
	if digest, kind, found, err := in.Hub.Recorded(ctx, site, coll, key, c.stream, c.ref.Seq); err != nil {
		return false, err
	} else if found {
		switch {
		case kind == "loaded" && digest == c.digest:
			res.Skipped++
			return false, nil
		case kind == "loaded":
			return false, mark(KindConflict, fmt.Sprintf("seq %d is loaded with manifest %s; this one is %s", c.ref.Seq, short(digest), short(c.digest)))
		case digest == c.digest && !retryKinds[kind]:
			res.Kept++
			return false, nil
		}
	}
	// 1. the signature, before any other file is read
	if keys := in.Site.Collectors[coll]; len(keys) > 0 {
		if !c.files[format.SigFile] {
			return false, mark(KindSignature, "the collector signs and the bundle has no manifest.sig")
		}
		sig, err := in.Site.Drop.Get(ctx, c.ref.Dir()+"/"+format.SigFile)
		if err != nil {
			return false, err
		}
		if err := format.VerifySignature(keys, c.man, sig); err != nil {
			return false, mark(KindSignature, err.Error())
		}
	}
	// 2. the manifest: its format, then its names against the configuration and its folder
	m, err := format.DecodeManifest(c.man)
	switch {
	case errors.Is(err, format.ErrNewerFormat):
		return false, mark(KindNewerFormat, err.Error())
	case err != nil:
		return false, mark(format.KindMalformed, err.Error())
	}
	if err := m.Matches(c.ref); err != nil {
		return false, mark(KindMismatch, err.Error())
	}
	if m.Site != site || m.Collector != coll {
		return false, mark(KindMismatch, fmt.Sprintf("the manifest names site %s, collector %s; the drop's is %s / %s", m.Site, m.Collector, site, coll))
	}
	// 3. every view on pgvigil's own list
	for _, f := range m.Files {
		if !in.Allow[f.View] {
			return false, mark(KindUnknownView, fmt.Sprintf("view %s is not one a bundle may carry", f.View))
		}
	}
	// 4. its place in the stream: an older seq than the newest loaded is late; a missing seq waits gap_wait
	afterGap, gapReason := false, ""
	n, ok, err := in.Hub.Newest(ctx, site, coll, key, m.Stream)
	if err != nil {
		return false, err
	}
	next := uint64(1)
	if ok {
		if m.Seq <= n.Seq {
			return false, mark(KindLate, fmt.Sprintf("seq %d after seq %d was loaded", m.Seq, n.Seq))
		}
		next = n.Seq + 1
	} else if in.Log != nil {
		if p, had, _ := in.Hub.Newest(ctx, site, coll, key, ""); had && p.Stream != m.Stream {
			in.Log.Info("remote collector started a new stream", "site", site, "collector", coll, "instance", key, "stream", m.Stream, "previous", p.Stream)
		}
	}
	if m.Seq > next {
		if in.settling(c) {
			return true, nil
		}
		afterGap = true
		if m.Seq == next+1 {
			gapReason = fmt.Sprintf("seq %d missing past gap_wait (%s)", next, in.Site.GapWait)
		} else {
			gapReason = fmt.Sprintf("seqs %d to %d missing past gap_wait (%s)", next, m.Seq-1, in.Site.GapWait)
		}
	}
	// 5. the files, copied here and checked against the manifest
	dir, err := os.MkdirTemp(in.Work, "bundle-")
	if err != nil {
		return false, err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	for name := range c.files {
		if name == format.ManifestFile {
			continue
		}
		b, err := in.Site.Drop.Get(ctx, c.ref.Dir()+"/"+name)
		if err != nil {
			return false, err
		}
		if err := os.WriteFile(filepath.Join(dir, name), b, 0o600); err != nil {
			return false, err
		}
	}
	if err := os.WriteFile(filepath.Join(dir, format.ManifestFile), c.man, 0o600); err != nil {
		return false, err
	}
	fsys := os.DirFS(dir)
	if err := format.Verify(fsys, m, in.MaxRaw); err != nil {
		var p *format.Problem
		if errors.As(err, &p) {
			if (p.Kind == format.KindMissing || p.Kind == format.KindShort) && in.settling(c) {
				return true, nil
			}
			return false, mark(p.Kind, p.Error())
		}
		return false, err
	}
	b := &Bundle{Ref: c.ref, Manifest: m, Digest: c.digest, AfterGap: afterGap}
	for _, f := range m.Files {
		lines, err := format.ReadLines(fsys, f, in.MaxRaw)
		if err != nil {
			return false, mark(format.KindMalformed, err.Error())
		}
		for _, l := range lines {
			b.Batches = append(b.Batches, Batch{View: f.View, N: l.N, At: l.At, Rows: l.Rows})
		}
	}
	sort.Slice(b.Batches, func(i, j int) bool { return b.Batches[i].N < b.Batches[j].N })
	if afterGap {
		if err := mark(KindGap, gapReason); err != nil {
			return false, err
		}
	}
	if err := in.Hub.Load(ctx, in.Site, b); err != nil {
		if errors.Is(err, ErrOwned) {
			return false, mark(KindOwned, err.Error())
		}
		return false, err
	}
	res.Loaded++
	return false, nil
}

func short(d string) string {
	if len(d) > 12 {
		return d[:12]
	}
	return d
}
