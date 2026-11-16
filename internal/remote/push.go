package remote

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/export"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// pushedExt marks a pushed bundle: the file <bundle folder>.pushed beside it holds the push's time (keep_days counts
// from it). The write credential cannot list the container, so the outbox keeps what was pushed.
const pushedExt = ".pushed"

// Pusher writes the outbox's finished bundles into the push destination (R7 a: an Azure Blob container through
// internal/export's destination, a SAS limited to create + write on that container or a managed identity with only
// that right). It never lists, reads or deletes there (no export.CheckDestination): every file of a bundle is uploaded
// at the bundle's own layout under the container's prefix, manifest.json last - a blob is visible only once committed,
// so a poller that finds the manifest finds every file whole; a retry uploads the same bytes again. The outbox is the
// queue: bundles go in seq order per instance, a failure stops the round and the next round starts from it.
type Pusher struct {
	dest     export.Destination
	outbox   string
	keepDays int
	tries    int
	backoff  time.Duration
}

// NewPusher opens the push destination (remote.push: azure_blob, the one push of this release) with no request made.
func NewPusher(d config.ExportDestination, outbox string, keepDays int) (*Pusher, error) {
	if d.Type != "azure_blob" {
		return nil, fmt.Errorf("remote.push: azure_blob is the one push (got %q)", d.Type)
	}
	dest, err := export.NewAzureBlob(export.BlobOptions{AccountURL: d.AccountURL, Container: d.Container, Prefix: d.Prefix,
		ConnectionString: d.ConnectionString(), SASURL: d.SASURL()}) // no Name: the keys sit at the prefix itself
	if err != nil {
		return nil, err
	}
	p := newPusher(dest, outbox, keepDays)
	p.backoff = 2 * time.Second
	return p, nil
}

func newPusher(dest export.Destination, outbox string, keepDays int) *Pusher {
	return &Pusher{dest: dest, outbox: outbox, keepDays: keepDays, tries: 3}
}

// String names the destination for a log line (no secret).
func (p *Pusher) String() string { return p.dest.String() }

type outboxBundle struct {
	ref format.Ref
	dir string
}

// finished lists the outbox's finished bundles (a folder at a bundle's layout holding its manifest; never a .part
// folder), by instance and seq.
func (p *Pusher) finished() ([]outboxBundle, error) {
	dirs, err := filepath.Glob(filepath.Join(p.outbox, "*", "*", "*", "*", "*"))
	if err != nil {
		return nil, err
	}
	var out []outboxBundle
	for _, d := range dirs {
		fi, err := os.Stat(d)
		if err != nil || !fi.IsDir() || strings.HasSuffix(d, format.PartExt) {
			continue
		}
		rel, err := filepath.Rel(p.outbox, d)
		if err != nil {
			continue
		}
		ref, err := format.ParseDir(filepath.ToSlash(rel))
		if err != nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(d, format.ManifestFile)); err != nil {
			continue
		}
		out = append(out, outboxBundle{ref: ref, dir: d})
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i].ref, out[j].ref
		if a.Site+"/"+a.Collector+"/"+a.InstanceKey != b.Site+"/"+b.Collector+"/"+b.InstanceKey {
			return a.Site+"/"+a.Collector+"/"+a.InstanceKey < b.Site+"/"+b.Collector+"/"+b.InstanceKey
		}
		return a.Seq < b.Seq
	})
	return out, nil
}

func (p *Pusher) upload(ctx context.Context, key, local string) error {
	var err error
	for try := 0; try < p.tries; try++ {
		if try > 0 && p.backoff > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(p.backoff * time.Duration(try)):
			}
		}
		if err = p.dest.Upload(ctx, key, local); err == nil {
			return nil
		}
	}
	return err
}

// Round pushes every finished bundle not pushed yet; it returns how many it pushed and the first failure (the round
// stops there).
func (p *Pusher) Round(ctx context.Context, now time.Time) (int, error) {
	bundles, err := p.finished()
	if err != nil {
		return 0, err
	}
	pushed := 0
	for _, b := range bundles {
		if _, err := os.Stat(b.dir + pushedExt); err == nil {
			continue
		}
		entries, err := os.ReadDir(b.dir)
		if err != nil {
			return pushed, fmt.Errorf("remote push: %s: %w", b.ref.Dir(), err)
		}
		var names []string
		for _, e := range entries {
			if !e.IsDir() && e.Name() != format.ManifestFile {
				names = append(names, e.Name())
			}
		}
		sort.Strings(names)
		names = append(names, format.ManifestFile)
		for _, n := range names {
			if err := p.upload(ctx, b.ref.Dir()+"/"+n, filepath.Join(b.dir, n)); err != nil {
				return pushed, fmt.Errorf("remote push: %s/%s to %s: %w", b.ref.Dir(), n, p.dest, err)
			}
		}
		if err := writeSynced(b.dir+pushedExt, []byte(now.UTC().Format(time.RFC3339Nano)+"\n")); err != nil {
			return pushed, fmt.Errorf("remote push: %s pushed, its marker not written (the next round uploads it again): %w", b.ref.Dir(), err)
		}
		pushed++
	}
	return pushed, nil
}

// Prune removes the pushed bundles whose push is older than keep_days, each folder before its marker; it returns how
// many went. A bundle never pushed stays (remote.max_mb bounds the outbox: task 6).
func (p *Pusher) Prune(now time.Time) int {
	bundles, err := p.finished()
	if err != nil {
		return 0
	}
	n := 0
	for _, b := range bundles {
		raw, err := os.ReadFile(b.dir + pushedExt)
		if err != nil {
			continue
		}
		at, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(string(raw)))
		if err != nil || now.Sub(at) <= time.Duration(p.keepDays)*24*time.Hour {
			continue
		}
		if os.RemoveAll(b.dir) != nil {
			continue
		}
		if err := os.Remove(b.dir + pushedExt); err != nil && !errors.Is(err, os.ErrNotExist) {
			continue
		}
		n++
	}
	return n
}
