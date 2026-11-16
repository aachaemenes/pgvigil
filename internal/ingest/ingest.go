// Package ingest is the hub's side of the remote collector (docs/remote-collector.md): one loop per site reads the
// site's drop (internal/export's Get and List only: the hub never writes, moves or deletes there), checks every bundle
// (internal/remote/format, in the order docs/remote-bundle-format.md gives) and loads each one once through migration
// 0329, in sequence per collector, instance and stream.
package ingest

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
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
	KindLate        = "late"         // an older seq after a newer one of the same stream was loaded
	KindConflict    = "conflict"     // a seq already loaded, with another manifest
	KindGap         = "gap"          // seqs missing past gap_wait: ingest went on (recorded on the bundle after them)
	KindNewerFormat = "newer format" // read again once the hub's format reaches it
	KindSignature   = "signature"    // the collector signs and the signature does not hold
	KindMismatch    = "mismatch"     // the manifest names another site, collector, instance, seq or window than its folder
	KindUnknownView = "unknown view" // a view outside pgvigil's own list (R9)
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

// Result counts one round.
type Result struct{ Loaded, Skipped, SetAside, Late, Conflicts, Gaps, Waiting int }

// Round reads the site's drop once and loads what is due.
func (in *Ingester) Round(ctx context.Context) (Result, error) {
	return Result{}, nil // OUTBOX H task 1: the red rows' stub
}

// AllowList is the views a bundle may carry.
func AllowList() map[string]bool {
	return map[string]bool{} // OUTBOX H task 1: the red rows' stub
}

// Sites opens remote_sites: for the loop, one Site each (open builds a drop's reader).
func Sites(ctx context.Context, cfg []config.RemoteSite, open func(context.Context, config.ExportDestination) (Drop, error)) ([]Site, error) {
	return nil, nil // OUTBOX H task 1: the red rows' stub
}
