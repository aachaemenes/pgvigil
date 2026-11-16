package ingest

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/export"
	"github.com/aachaemenes/pgvigil/internal/remote"
	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// memHub is the repository's side in memory: what ingest loaded and marked, in order.
type memHub struct {
	loaded map[string]string // site/coll/key/stream/seq -> digest
	kinds  map[string]string // the same key -> "loaded" or a mark's kind
	newest map[string]Newest // site/coll/key/stream -> newest loaded; site/coll/key/ -> newest of any stream
	order  []string          // "<stream>/<seq>" of each load, in order
	marks  []Mark
	loads  []*Bundle
}

func newMemHub() *memHub {
	return &memHub{loaded: map[string]string{}, kinds: map[string]string{}, newest: map[string]Newest{}}
}

func hk(site, coll, key, stream string, seq uint64) string {
	return fmt.Sprintf("%s/%s/%s/%s/%d", site, coll, key, stream, seq)
}

func (h *memHub) Newest(_ context.Context, site, coll, key, stream string) (Newest, bool, error) {
	n, ok := h.newest[site+"/"+coll+"/"+key+"/"+stream]
	return n, ok, nil
}

func (h *memHub) Recorded(_ context.Context, site, coll, key, stream string, seq uint64) (string, string, bool, error) {
	k := hk(site, coll, key, stream, seq)
	kind, ok := h.kinds[k]
	return h.loaded[k], kind, ok, nil
}

func (h *memHub) Load(_ context.Context, s Site, b *Bundle) error {
	m := b.Manifest
	k := hk(s.Name, m.Collector, b.Ref.InstanceKey, m.Stream, m.Seq)
	h.loaded[k], h.kinds[k] = b.Digest, "loaded"
	n := Newest{Stream: m.Stream, Seq: m.Seq, End: m.WindowTo}
	for _, nk := range []string{s.Name + "/" + m.Collector + "/" + b.Ref.InstanceKey + "/" + m.Stream, s.Name + "/" + m.Collector + "/" + b.Ref.InstanceKey + "/"} {
		if old, ok := h.newest[nk]; !ok || nk[len(nk)-1] != '/' && n.Seq > old.Seq || nk[len(nk)-1] == '/' && n.End.After(old.End) {
			h.newest[nk] = n
		}
	}
	h.order = append(h.order, fmt.Sprintf("%s/%d", m.Stream, m.Seq))
	h.loads = append(h.loads, b)
	return nil
}

func (h *memHub) Mark(_ context.Context, m Mark) error {
	h.marks = append(h.marks, m)
	if m.Kind != KindGap {
		k := hk(m.Site, m.Collector, m.Key, m.Stream, m.Seq)
		if _, ok := h.kinds[k]; !ok {
			h.loaded[k], h.kinds[k] = m.Digest, m.Kind
		}
	}
	return nil
}

func (h *memHub) markKinds() []string {
	var out []string
	for _, m := range h.marks {
		out = append(out, fmt.Sprintf("%s/%d:%s", m.Stream, m.Seq, m.Kind))
	}
	return out
}

// drop: a site's drop as a folder, written by the remote collector's own bundle writer
type drop struct {
	t    *testing.T
	root string
	base time.Time
}

func newDrop(t *testing.T) *drop {
	return &drop{t: t, root: t.TempDir(), base: time.Date(2026, 11, 16, 17, 0, 0, 0, time.UTC)}
}

// write puts bundle seq of stream into the drop (window ending base + seq x 5 min) with an activity view whose rows
// carry a 64-bit id no float64 holds; key signs it when set; view names the view.
func (d *drop) write(stream string, seq uint64, view string, key ed25519.PrivateKey) format.Ref {
	d.t.Helper()
	to := d.base.Add(time.Duration(seq) * 5 * time.Minute)
	b, err := remote.OpenBundle(remote.BundleOptions{Outbox: d.root, Site: "site1", Collector: "c1", Stream: stream, Seq: seq,
		From: to.Add(-5 * time.Minute), To: to, QueryText: "hash", PgvigilVersion: "v0.4.0", SchemaLevel: "0329_remote", Key: key,
		Instance: format.Instance{Engine: "sqlserver", Name: `HOST\INST`, Platform: "onprem", ServerVersion: "16.0", VersionNum: 16}})
	if err != nil {
		d.t.Fatal(err)
	}
	if err := b.AddBatch(view, to.Add(-4*time.Minute), []map[string]any{{"session_id": 52, "queryid": int64(9223372036854775807)}}); err != nil {
		d.t.Fatal(err)
	}
	if err := b.AddBatch(view, to.Add(-2*time.Minute), []map[string]any{{"session_id": 53}}); err != nil {
		d.t.Fatal(err)
	}
	b.AddRun(format.Run{Collection: view, At: to.Add(-4 * time.Minute), Ms: 100, Status: "ok"})
	ref, err := b.Close(to, []format.Read{{Collection: view, Status: "ran", Runs: 2, IntervalSecs: 60}}, nil, format.Heartbeat{Host: "jump01", Started: d.base, At: to, Instances: 1})
	if err != nil {
		d.t.Fatal(err)
	}
	return ref
}

func (d *drop) path(ref format.Ref, file string) string {
	return filepath.Join(d.root, filepath.FromSlash(ref.Dir()), file)
}

func (d *drop) edit(ref format.Ref, file string, f func([]byte) []byte) {
	d.t.Helper()
	p := d.path(ref, file)
	b, err := os.ReadFile(p)
	if err != nil {
		d.t.Fatal(err)
	}
	if err := os.WriteFile(p, f(b), 0o600); err != nil {
		d.t.Fatal(err)
	}
}

func (d *drop) ingester(h *memHub, now time.Time, keys map[string][][]byte) *Ingester {
	if keys == nil {
		keys = map[string][][]byte{"c1": nil}
	}
	return &Ingester{
		Site: Site{Name: "site1", Drop: export.NewFolder(d.root), ExpectedEvery: 5 * time.Minute, GapWait: 15 * time.Minute, Collectors: keys},
		Hub:  h, Allow: map[string]bool{"mssql_activity": true, "mssql_ag": true}, Now: func() time.Time { return now },
		MaxRaw: 1 << 20, Work: d.t.TempDir(), Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

func round(t *testing.T, in *Ingester) Result {
	t.Helper()
	r, err := in.Round(context.Background())
	if err != nil {
		t.Fatalf("Round: %v", err)
	}
	return r
}

func eq(t *testing.T, what string, got, want any) {
	t.Helper()
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("%s: %v, want %v", what, got, want)
	}
}

// in seq order, each once; the batches in n order with their rows as written (a 64-bit id not rounded)
func TestRoundLoadsInOrderOnce(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	for _, s := range []uint64{3, 1, 2} {
		d.write("st1", s, "mssql_activity", nil)
	}
	now := d.base.Add(time.Hour)
	r := round(t, d.ingester(h, now, nil))
	eq(t, "loaded", r.Loaded, 3)
	eq(t, "the order", h.order, []string{"st1/1", "st1/2", "st1/3"})
	if len(h.loads) > 0 {
		b := h.loads[0]
		eq(t, "the first bundle's batches", len(b.Batches), 2)
		if len(b.Batches) == 2 {
			eq(t, "n order", fmt.Sprint(b.Batches[0].N, b.Batches[1].N), "1 2")
			if !strings.Contains(string(b.Batches[0].Rows), "9223372036854775807") {
				t.Errorf("the rows as written: %s", b.Batches[0].Rows)
			}
			eq(t, "the view", b.Batches[0].View, "mssql_activity")
		}
		eq(t, "the instance key", b.Ref.InstanceKey, "HOST%5CINST")
	}
	r = round(t, d.ingester(h, now, nil))
	eq(t, "a second round loads nothing", r.Loaded, 0)
	eq(t, "and skips the three", r.Skipped, 3)
}

// a missing seq is waited for gap_wait, then recorded, and ingest goes on; the missing one arriving later is late
func TestRoundGapThenLate(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	d.write("st1", 1, "mssql_activity", nil)
	r3 := d.write("st1", 3, "mssql_activity", nil)
	r := round(t, d.ingester(h, r3.End.Add(time.Minute), nil))
	eq(t, "inside gap_wait: seq 1 loaded", h.order, []string{"st1/1"})
	eq(t, "and 3 waits", r.Waiting, 1)
	r = round(t, d.ingester(h, r3.End.Add(16*time.Minute), nil))
	eq(t, "past gap_wait: 3 loaded", h.order, []string{"st1/1", "st1/3"})
	eq(t, "the gap recorded", h.markKinds(), []string{"st1/3:gap"})
	if len(h.marks) == 1 && !strings.Contains(h.marks[0].Reason, "2") {
		t.Errorf("the gap's reason names seq 2: %q", h.marks[0].Reason)
	}
	eq(t, "gaps", r.Gaps, 1)
	d.write("st1", 2, "mssql_activity", nil)
	r = round(t, d.ingester(h, r3.End.Add(20*time.Minute), nil))
	eq(t, "seq 2 after 3: late, not loaded", h.markKinds(), []string{"st1/3:gap", "st1/2:late"})
	eq(t, "late", r.Late, 1)
	eq(t, "the loads", h.order, []string{"st1/1", "st1/3"})
}

// a seq loaded, then another bundle of the same seq: a conflict; a new stream starts its own sequence
func TestRoundConflictAndNewStream(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	r1 := d.write("st1", 1, "mssql_activity", nil)
	now := d.base.Add(time.Hour)
	round(t, d.ingester(h, now, nil))
	if err := os.RemoveAll(filepath.Join(d.root, filepath.FromSlash(r1.Dir()))); err != nil {
		t.Fatal(err)
	}
	d.write("st1", 1, "mssql_ag", nil) // the same folder, other files: another digest
	r := round(t, d.ingester(h, now, nil))
	eq(t, "the conflict", h.markKinds(), []string{"st1/1:conflict"})
	eq(t, "conflicts", r.Conflicts, 1)
	d.base = d.base.Add(30 * time.Minute) // a reinstalled collector: a new stream from seq 1, later windows
	d.write("st2", 1, "mssql_activity", nil)
	d.write("st2", 2, "mssql_activity", nil)
	round(t, d.ingester(h, now.Add(time.Hour), nil))
	eq(t, "the new stream's loads", h.order, []string{"st1/1", "st2/1", "st2/2"})
}

// the checks, in order: the signature first, the manifest against its folder, the format, the views, the files
func TestRoundChecks(t *testing.T) {
	_, good, _ := ed25519.GenerateKey(rand.Reader)
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	pub := good.Public().(ed25519.PublicKey)
	cases := []struct {
		name  string
		make  func(d *drop) format.Ref
		keys  map[string][][]byte
		after time.Duration // now = the bundle's end + after
		kind  string        // the mark's kind; "" = loaded; "wait" = waiting, nothing marked
	}{
		{"loads", func(d *drop) format.Ref { return d.write("st1", 1, "mssql_activity", nil) }, nil, time.Hour, ""},
		{"signed right", func(d *drop) format.Ref { return d.write("st1", 1, "mssql_activity", good) }, map[string][][]byte{"c1": {pub}}, time.Hour, ""},
		{"signed by another key", func(d *drop) format.Ref { return d.write("st1", 1, "mssql_activity", other) }, map[string][][]byte{"c1": {pub}}, time.Hour, KindSignature},
		{"unsigned where keys are listed", func(d *drop) format.Ref { return d.write("st1", 1, "mssql_activity", nil) }, map[string][][]byte{"c1": {pub}}, time.Hour, KindSignature},
		{"a re-summed file under a signature", func(d *drop) format.Ref {
			r := d.write("st1", 1, "mssql_activity", good)
			d.edit(r, "manifest.json", func(b []byte) []byte {
				return []byte(strings.Replace(string(b), `"pgvigil_version": "v0.4.0"`, `"pgvigil_version": "v0.4.1"`, 1))
			})
			return r
		}, map[string][][]byte{"c1": {pub}}, time.Hour, KindSignature},
		{"another site's manifest", func(d *drop) format.Ref {
			r := d.write("st1", 1, "mssql_activity", nil)
			d.edit(r, "manifest.json", func(b []byte) []byte {
				return []byte(strings.Replace(string(b), `"site": "site1"`, `"site": "site2"`, 1))
			})
			return r
		}, nil, time.Hour, KindMismatch},
		{"a newer format", func(d *drop) format.Ref {
			r := d.write("st1", 1, "mssql_activity", nil)
			d.edit(r, "manifest.json", func(b []byte) []byte { return []byte(strings.Replace(string(b), `"format": 1`, `"format": 2`, 1)) })
			return r
		}, nil, time.Hour, KindNewerFormat},
		{"an unknown view", func(d *drop) format.Ref { return d.write("st1", 1, "mssql_cursor", nil) }, nil, time.Hour, KindUnknownView},
		{"a changed byte", func(d *drop) format.Ref {
			r := d.write("st1", 1, "mssql_activity", nil)
			d.edit(r, "mssql_activity.ndjson.gz", func(b []byte) []byte { b[len(b)-9] ^= 0xff; return b })
			return r
		}, nil, time.Hour, format.KindChecksum},
		{"a file cut inside the settle time", func(d *drop) format.Ref {
			r := d.write("st1", 1, "mssql_activity", nil)
			d.edit(r, "mssql_activity.ndjson.gz", func(b []byte) []byte { return b[:len(b)/2] })
			return r
		}, nil, time.Minute, "wait"},
		{"a file cut past the settle time", func(d *drop) format.Ref {
			r := d.write("st1", 1, "mssql_activity", nil)
			d.edit(r, "mssql_activity.ndjson.gz", func(b []byte) []byte { return b[:len(b)/2] })
			return r
		}, nil, time.Hour, format.KindShort},
		{"a collector the site does not list", func(d *drop) format.Ref { return d.write("st1", 1, "mssql_activity", nil) }, map[string][][]byte{"c9": nil}, time.Hour, "none"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d, h := newDrop(t), newMemHub()
			ref := c.make(d)
			r := round(t, d.ingester(h, ref.End.Add(c.after), c.keys))
			switch c.kind {
			case "":
				eq(t, "loaded", h.order, []string{"st1/1"})
				eq(t, "marks", h.markKinds(), []string(nil))
			case "wait":
				eq(t, "loaded", h.order, []string(nil))
				eq(t, "marks", h.markKinds(), []string(nil))
				eq(t, "waiting", r.Waiting, 1)
			case "none":
				eq(t, "loaded", h.order, []string(nil))
				eq(t, "marks", h.markKinds(), []string(nil))
			default:
				eq(t, "loaded", h.order, []string(nil))
				eq(t, "the mark", h.markKinds(), []string{"st1/1:" + c.kind})
				eq(t, "set aside", r.SetAside, 1)
			}
		})
	}
}
