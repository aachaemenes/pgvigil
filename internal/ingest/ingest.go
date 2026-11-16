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

	"github.com/aachaemenes/pgvigil/internal/export"
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
	KindLoad        = "load"                 // the repository refused the load past the settle time (its error kept)
	KindDropError   = "drop error"           // the drop refused a file past the settle time (its error kept)
	KindUnlisted    = "unlisted"             // a collector folder the site does not list, or an instance key not in its form
	KindRetry       = "retry"                // 'pgvigil ingest -retry' asked: read again, past the stream's newest
)

// DefaultMaxBundle: a bundle whose views' uncompressed sizes sum past this is set aside 'too_big' before any view file is
// fetched (docs/remote-collector.md)
const DefaultMaxBundle = 2 << 30

// osLitter: files an operating system or a desktop leaves in a folder - ignored from the listing, never fetched
func osLitter(name string) bool {
	switch strings.ToLower(name) {
	case ".ds_store", "thumbs.db", "desktop.ini":
		return true
	}
	return strings.HasPrefix(name, "._")
}

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
	// AfterGap: the bundle comes after seqs ingest went past (a gap, a bundle set aside, a retry past the newest): its
	// audit batches move the audit cursor to their start (0329's remote_batch), recorded as an 'audit gap'
	AfterGap bool
	// Gap: the seqs ingest went past to load this one, in words - recorded in the load's own transaction, so a load that
	// fails records no gap
	Gap string
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

// Hub is the repository's side (0329's ingest door); load.go is its implementation on ingest's own pool.
type Hub interface {
	// Newest: the newest loaded bundle of (site, collector, key) in stream ("" = in any stream)
	Newest(ctx context.Context, site, collector, key, stream string) (Newest, bool, error)
	// Recorded: what the ledger holds for this seq: its digest and its kind ("loaded", "loading" - begun and stopped
	// part-way - or an open mark's Kind)
	Recorded(ctx context.Context, site, collector, key, stream string, seq uint64) (digest, kind string, found bool, err error)
	// Load loads a checked bundle: the instance, every batch once (its own transaction with its ledger row), then in one
	// transaction the runs and failures, the gap it went past, the heartbeat, each read's interval, the bundle's ledger
	// row, the stream's high-water and the instance's as_of
	Load(ctx context.Context, site Site, b *Bundle) error
	// Mark records a bundle not loaded; true = a new mark (an open one of that kind was not there)
	Mark(ctx context.Context, m Mark) (bool, error)
	// Seen: the hub's first sight of a bundle folder (recorded at now when new) - the settle clock
	Seen(ctx context.Context, site, collector, key, dir string, now time.Time) (time.Time, error)
	// Retries: the window ends of a key's bundles with an open retry ('pgvigil ingest -retry'), whose days are listed
	Retries(ctx context.Context, site, collector, key string) ([]time.Time, error)
}

// Ingester is one site's loop.
type Ingester struct {
	Site   Site
	Hub    Hub
	Allow  map[string]bool // the views a bundle may carry (AllowList)
	Now    func() time.Time
	MaxRaw int64 // a view file's uncompressed cap
	// MaxBundle: a bundle's views' uncompressed cap, all together (0 = DefaultMaxBundle)
	MaxBundle int64
	Work      string // a folder a bundle is copied into to be checked
	Log       *slog.Logger
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
	tooBig string          // manifest.json past format.MaxManifestBytes: why (never read further, never decoded)
	digest string
	stream string    // the manifest's, read loosely so a newer format still has one
	seen   time.Time // the hub's first sight of the folder: the settle runs from here
}

// Round reads the site's drop once and loads what is due: per collector the site lists, per instance key found under
// it, the bundles from the day of the newest loaded one (and the days of its open retries) to today, in order. One
// key's trouble - a drop error, a load the repository refuses - holds that key alone: the round goes on with the
// others and returns the errors it met, joined. A collector folder the site does not list is marked, by name.
func (in *Ingester) Round(ctx context.Context) (Result, error) {
	var res Result
	colls := make([]string, 0, len(in.Site.Collectors))
	for c := range in.Site.Collectors {
		colls = append(colls, c)
	}
	sort.Strings(colls)
	all, err := in.Site.Drop.List(ctx, in.Site.Name+"/")
	if err != nil {
		return res, fmt.Errorf("ingest %s: the drop's listing: %w", in.Site.Name, err)
	}
	in.markUnlisted(ctx, all)
	var errs []error
	for _, c := range colls {
		for _, k := range in.instanceKeys(ctx, c, all) {
			if err := in.group(ctx, c, k, &res); err != nil {
				errs = append(errs, fmt.Errorf("ingest %s/%s/%s: %w", in.Site.Name, c, k, err))
				in.Log.Error("remote ingest: one instance key held this round", "site", in.Site.Name, "collector", c, "instance", k, "err", err)
			}
		}
	}
	return res, errors.Join(errs...)
}

// markUnlisted marks once a round each collector folder the site does not list (its bundles are never read)
func (in *Ingester) markUnlisted(ctx context.Context, all []string) {
	seen := map[string]bool{}
	for _, k := range all {
		parts := strings.SplitN(strings.TrimPrefix(k, in.Site.Name+"/"), "/", 2)
		if len(parts) < 2 || parts[0] == "" || seen[parts[0]] {
			continue
		}
		seen[parts[0]] = true
		if _, ok := in.Site.Collectors[parts[0]]; ok {
			continue
		}
		why := fmt.Sprintf("collector %s is not one site %s lists in remote_sites: - its bundles are not read", parts[0], in.Site.Name)
		if isNew, err := in.Hub.Mark(ctx, Mark{Site: in.Site.Name, Collector: parts[0], Kind: KindUnlisted, Reason: why}); err == nil && isNew {
			in.Log.Warn("remote ingest: an unlisted collector", "site", in.Site.Name, "collector", parts[0])
		}
	}
}

// instanceKeys: the instance keys under <site>/<collector>/ in the site's listing; a key not in its form is marked
func (in *Ingester) instanceKeys(ctx context.Context, coll string, all []string) []string {
	pfx := in.Site.Name + "/" + coll + "/"
	seen := map[string]bool{}
	var out []string
	for _, k := range all {
		if !strings.HasPrefix(k, pfx) {
			continue
		}
		parts := strings.SplitN(strings.TrimPrefix(k, pfx), "/", 2)
		if len(parts) != 2 || seen[parts[0]] {
			continue
		}
		seen[parts[0]] = true
		if _, err := format.InstanceName(parts[0]); err != nil {
			why := fmt.Sprintf("instance key %s under %s is not in its form (%v): not read", parts[0], pfx, err)
			if isNew, merr := in.Hub.Mark(ctx, Mark{Site: in.Site.Name, Collector: coll, Key: parts[0], Kind: KindUnlisted, Reason: why}); merr == nil && isNew {
				in.Log.Warn("remote ingest: an instance key not in its form", "site", in.Site.Name, "collector", coll, "key", parts[0])
			}
			continue
		}
		out = append(out, parts[0])
	}
	sort.Strings(out)
	return out
}

// candidates: the bundle folders of one instance key from day 'from' (zero: every day) to today and on the days given,
// in order - within one stream by seq, across streams by window end. A key ending in '/', '.' or '..' (a folder
// marker some drops make) and an operating system's litter are skipped.
func (in *Ingester) candidates(ctx context.Context, coll, key string, from time.Time, days []time.Time) ([]*candidate, error) {
	base := in.Site.Name + "/" + coll + "/" + key + "/"
	var prefixes []string
	if from.IsZero() {
		prefixes = []string{base}
	} else {
		have := map[string]bool{}
		add := func(d time.Time) {
			p := base + d.UTC().Format("2006-01-02") + "/"
			if !have[p] {
				have[p] = true
				prefixes = append(prefixes, p)
			}
		}
		today := in.Now().UTC().Truncate(24 * time.Hour)
		for d := from.UTC().Truncate(24 * time.Hour); !d.After(today); d = d.Add(24 * time.Hour) {
			add(d)
		}
		for _, d := range days {
			add(d)
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
			if file == "" || file == "." || file == ".." {
				continue // a folder marker: nothing to read
			}
			ref, err := format.ParseDir(dir)
			if err != nil {
				continue // a .part folder, a stray file: nobody reads it
			}
			c := byDir[dir]
			if c == nil {
				c = &candidate{ref: ref, files: map[string]bool{}}
				byDir[dir] = c
			}
			if osLitter(file) {
				continue
			}
			c.files[file] = true
		}
	}
	out := make([]*candidate, 0, len(byDir))
	for dir, c := range byDir {
		if c.files[format.ManifestFile] {
			b, err := export.GetMax(ctx, in.Site.Drop, dir+"/"+format.ManifestFile, format.MaxManifestBytes)
			if errors.Is(err, export.ErrTooBig) {
				c.tooBig = err.Error()
				out = append(out, c)
				continue
			}
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
		a, b := out[i], out[j]
		if a.stream != "" && a.stream == b.stream && a.ref.Seq != b.ref.Seq {
			return a.ref.Seq < b.ref.Seq
		}
		if !a.ref.End.Equal(b.ref.End) {
			return a.ref.End.Before(b.ref.End)
		}
		return a.ref.Seq < b.ref.Seq
	})
	return out, nil
}

// group takes one instance key's bundles in order; a bundle that must wait (a missing seq, a copy still running, any
// problem inside the settle time) holds the ones after it until the next round.
func (in *Ingester) group(ctx context.Context, coll, key string, res *Result) error {
	var from time.Time
	if n, ok, err := in.Hub.Newest(ctx, in.Site.Name, coll, key, ""); err != nil {
		return err
	} else if ok {
		from = n.End
	}
	days, err := in.Hub.Retries(ctx, in.Site.Name, coll, key)
	if err != nil {
		return err
	}
	cands, err := in.candidates(ctx, coll, key, from, days)
	if err != nil {
		return err
	}
	for _, c := range cands {
		if c.seen, err = in.Hub.Seen(ctx, in.Site.Name, coll, key, c.ref.Dir(), in.Now()); err != nil {
			return err
		}
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

// settling: the hub first saw the bundle's folder less than the settle time (gap_wait) ago - a copy may still be running
func (in *Ingester) settling(c *candidate) bool { return in.Now().Sub(c.seen) < in.Site.GapWait }

// retryKinds: a bundle marked so is read again when it appears with the same manifest - a copy that finished, a hub
// that was upgraded, a key or a name the hub's configuration has since put right
var retryKinds = map[string]bool{format.KindMissing: true, format.KindShort: true, KindNewerFormat: true,
	KindSignature: true, KindUnknownView: true, KindOwned: true}

// take checks one bundle and loads or marks it; wait = it, and the bundles after it, wait for the next round. Inside the
// settle time any problem with the bundle itself waits; it is marked only past it.
func (in *Ingester) take(ctx context.Context, coll, key string, c *candidate, res *Result) (bool, error) {
	site := in.Site.Name
	mark := func(kind, reason string) error {
		isNew, err := in.Hub.Mark(ctx, Mark{Site: site, Collector: coll, Key: key, Stream: c.stream, Seq: c.ref.Seq, End: c.ref.End, Kind: kind, Reason: reason, Digest: c.digest})
		if err != nil || !isNew {
			return err
		}
		switch kind {
		case KindLate:
			res.Late++
		case KindConflict:
			res.Conflicts++
		default:
			res.SetAside++
		}
		in.Log.Warn("remote bundle not loaded", "site", site, "bundle", c.ref.Dir(), "kind", kind, "reason", reason)
		return nil
	}
	// aside: a problem with the bundle - waited for inside the settle time, marked past it
	aside := func(kind, reason string) (bool, error) {
		if in.settling(c) {
			in.Log.Info("remote bundle waits (inside the settle time)", "site", site, "bundle", c.ref.Dir(), "kind", kind, "reason", reason)
			return true, nil
		}
		return false, mark(kind, reason)
	}
	if c.tooBig != "" { // final: a copy still running is shorter, never longer
		return false, mark(format.KindTooBig, c.tooBig)
	}
	if c.man == nil { // no manifest yet: a copy still running, or one that never finished
		return aside(format.KindMissing, "manifest.json is not in the drop")
	}
	retried := false
	if digest, kind, found, err := in.Hub.Recorded(ctx, site, coll, key, c.stream, c.ref.Seq); err != nil {
		return false, err
	} else if found {
		switch {
		case kind == "loaded" && digest == c.digest:
			res.Skipped++
			return false, nil
		case kind == "loaded", kind == "loading" && digest != c.digest:
			return false, mark(KindConflict, fmt.Sprintf("seq %d is %s with manifest %s; this one is %s", c.ref.Seq, kind, short(digest), short(c.digest)))
		case kind == "loading":
			// begun and stopped part-way with this manifest: it resumes at its first batch not loaded
		case kind == KindRetry:
			retried = true
		case digest == c.digest && !retryKinds[kind]:
			res.Kept++
			return false, nil
		}
	}
	// 1. the signature, before any other file is read
	if keys := in.Site.Collectors[coll]; len(keys) > 0 {
		if !c.files[format.SigFile] {
			return aside(KindSignature, "the collector signs and the bundle has no manifest.sig")
		}
		sig, err := export.GetMax(ctx, in.Site.Drop, c.ref.Dir()+"/"+format.SigFile, format.MaxSigBytes)
		if errors.Is(err, export.ErrTooBig) {
			return false, mark(format.KindTooBig, err.Error())
		}
		if err != nil {
			return aside(KindDropError, err.Error())
		}
		if err := format.VerifySignature(keys, c.man, sig); err != nil {
			return aside(KindSignature, err.Error())
		}
	}
	// 2. the manifest: its format, then its names against the configuration and its folder
	m, err := format.DecodeManifest(c.man)
	switch {
	case errors.Is(err, format.ErrNewerFormat):
		return aside(KindNewerFormat, err.Error())
	case err != nil:
		return aside(format.KindMalformed, err.Error())
	}
	if err := m.Matches(c.ref); err != nil {
		return aside(KindMismatch, err.Error())
	}
	if m.Site != site || m.Collector != coll {
		return aside(KindMismatch, fmt.Sprintf("the manifest names site %s, collector %s; the drop's is %s / %s", m.Site, m.Collector, site, coll))
	}
	// 3. every view on pgvigil's own list, and the bundle's size within the cap
	var raw int64
	known := map[string]bool{format.ManifestFile: true, format.SigFile: true, format.SumsFile: true}
	// each file's read cap: a view file its manifest bytes, the sums the manifest's cap, the signature its own
	caps := map[string]int64{format.SigFile: format.MaxSigBytes, format.SumsFile: format.MaxManifestBytes}
	for _, f := range m.Files {
		if !in.Allow[f.View] {
			return aside(KindUnknownView, fmt.Sprintf("view %s is not one a bundle may carry", f.View))
		}
		raw += f.RawBytes
		known[f.Name] = true
		caps[f.Name] = f.Bytes
	}
	max := in.MaxBundle
	if max <= 0 {
		max = DefaultMaxBundle
	}
	if raw > max {
		return false, mark(format.KindTooBig, fmt.Sprintf("its views uncompress to %d bytes, past the hub's cap of %d for one bundle", raw, max))
	}
	for name := range c.files {
		if !known[name] {
			return aside(format.KindExtra, fmt.Sprintf("%s is not a file the manifest lists", name))
		}
	}
	// 4. its place in the stream: an older seq than the newest loaded is late (unless retried); a missing seq waits
	// gap_wait from the hub's first sight of this bundle
	afterGap, gapReason := retried, ""
	n, ok, err := in.Hub.Newest(ctx, site, coll, key, m.Stream)
	if err != nil {
		return false, err
	}
	next := uint64(1)
	if ok && !retried {
		if m.Seq <= n.Seq {
			return false, mark(KindLate, fmt.Sprintf("seq %d after seq %d was loaded", m.Seq, n.Seq))
		}
		next = n.Seq + 1
	} else if !ok && in.Log != nil {
		if p, had, _ := in.Hub.Newest(ctx, site, coll, key, ""); had && p.Stream != m.Stream {
			in.Log.Info("remote collector started a new stream", "site", site, "collector", coll, "instance", key, "stream", m.Stream, "previous", p.Stream)
		}
	}
	if !retried && m.Seq > next {
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
	// 5. the files the manifest lists, copied here and checked against it
	dir, err := os.MkdirTemp(in.Work, "bundle-")
	if err != nil {
		return false, err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	for name := range c.files {
		if name == format.ManifestFile || !known[name] {
			continue
		}
		b, err := export.GetMax(ctx, in.Site.Drop, c.ref.Dir()+"/"+name, caps[name])
		if errors.Is(err, export.ErrTooBig) { // longer than the manifest says: final, read no further
			return false, mark(format.KindTooBig, err.Error())
		}
		if err != nil {
			return aside(KindDropError, err.Error())
		}
		if err := os.WriteFile(filepath.Join(dir, filepath.Base(name)), b, 0o600); err != nil {
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
			return aside(p.Kind, p.Error())
		}
		return false, err
	}
	b := &Bundle{Ref: c.ref, Manifest: m, Digest: c.digest, AfterGap: afterGap, Gap: gapReason}
	for _, f := range m.Files {
		lines, err := format.ReadLines(fsys, f, in.MaxRaw)
		if err != nil {
			return aside(format.KindMalformed, err.Error())
		}
		for _, l := range lines {
			b.Batches = append(b.Batches, Batch{View: f.View, N: l.N, At: l.At, Rows: l.Rows})
		}
	}
	sort.Slice(b.Batches, func(i, j int) bool { return b.Batches[i].N < b.Batches[j].N })
	if err := in.Hub.Load(ctx, in.Site, b); err != nil {
		if errors.Is(err, ErrOwned) {
			return aside(KindOwned, err.Error())
		}
		return aside(KindLoad, err.Error())
	}
	res.Loaded++
	if gapReason != "" {
		res.Gaps++
		in.Log.Warn("remote ingest went past a gap", "site", site, "bundle", c.ref.Dir(), "reason", gapReason)
	}
	return false, nil
}

func short(d string) string {
	if len(d) > 12 {
		return d[:12]
	}
	return d
}
