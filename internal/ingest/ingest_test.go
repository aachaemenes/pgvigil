package ingest

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
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

// streamIDs: the rows' streams by short name; a manifest's stream is 16 to 64 lower-case hex digits
var streamIDs = map[string]string{"st1": "aaaaaaaaaaaaaaaa", "st2": "bbbbbbbbbbbbbbbb"}

// streamName: a stream id back to the rows' short name
func streamName(id string) string {
	for k, v := range streamIDs {
		if v == id {
			return k
		}
	}
	return id
}

// memHub is the repository's side in memory: what ingest loaded and marked, in order.
type memHub struct {
	loaded map[string]string // site/coll/key/stream/seq -> digest
	kinds  map[string]string // the same key -> "loaded" or a mark's kind
	newest map[string]Newest // site/coll/key/stream -> newest loaded; site/coll/key/ -> newest of any stream
	order  []string          // "<stream>/<seq>" of each load, in order
	marks  []Mark
	loads  []*Bundle
	retry  map[string]time.Time // a key's open -retry (FOLD 1 B4): its window end
	fail   map[string]error     // an instance key whose Load fails (FOLD 1 S5)
}

func newMemHub() *memHub {
	return &memHub{loaded: map[string]string{}, kinds: map[string]string{}, newest: map[string]Newest{}, retry: map[string]time.Time{}, fail: map[string]error{}}
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
	if err := h.fail[b.Ref.InstanceKey]; err != nil {
		return err
	}
	m := b.Manifest
	k := hk(s.Name, m.Collector, b.Ref.InstanceKey, m.Stream, m.Seq)
	delete(h.retry, k)
	h.loaded[k], h.kinds[k] = b.Digest, "loaded"
	n := Newest{Stream: m.Stream, Seq: m.Seq, End: m.WindowTo}
	for _, nk := range []string{s.Name + "/" + m.Collector + "/" + b.Ref.InstanceKey + "/" + m.Stream, s.Name + "/" + m.Collector + "/" + b.Ref.InstanceKey + "/"} {
		if old, ok := h.newest[nk]; !ok || nk[len(nk)-1] != '/' && n.Seq > old.Seq || nk[len(nk)-1] == '/' && n.End.After(old.End) {
			h.newest[nk] = n
		}
	}
	h.order = append(h.order, fmt.Sprintf("%s/%d", streamName(m.Stream), m.Seq))
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

// retryBundle is pgvigil ingest -retry on the hub's side: the bundle's mark cleared and a retry recorded (stream st1)
func (h *memHub) retryBundle(site, coll string, ref format.Ref) {
	k := hk(site, coll, ref.InstanceKey, streamIDs["st1"], ref.Seq)
	h.kinds[k], h.retry[k] = "retry", ref.End
}

// Retries: the window ends of a key's bundles with an open -retry
func (h *memHub) Retries(_ context.Context, site, coll, key string) ([]time.Time, error) {
	var out []time.Time
	pfx := site + "/" + coll + "/" + key + "/"
	for k, end := range h.retry {
		if strings.HasPrefix(k, pfx) {
			out = append(out, end)
		}
	}
	return out, nil
}

func (h *memHub) markKinds() []string {
	var out []string
	for _, m := range h.marks {
		out = append(out, fmt.Sprintf("%s/%d:%s", streamName(m.Stream), m.Seq, m.Kind))
	}
	return out
}

// drop: a site's drop as a folder, written by the remote collector's own bundle writer
type drop struct {
	t    *testing.T
	root string
	base time.Time
	inst string // the instance's name ('HOST\INST' when empty)
}

func newDrop(t *testing.T) *drop {
	return &drop{t: t, root: t.TempDir(), base: time.Date(2026, 11, 16, 17, 0, 0, 0, time.UTC)}
}

// write puts bundle seq of stream into the drop (window ending base + seq x 5 min) with an activity view whose rows
// carry a 64-bit id no float64 holds; key signs it when set; view names the view.
func (d *drop) write(stream string, seq uint64, view string, key ed25519.PrivateKey) format.Ref {
	d.t.Helper()
	to := d.base.Add(time.Duration(seq) * 5 * time.Minute)
	b, err := remote.OpenBundle(remote.BundleOptions{Outbox: d.root, Site: "site1", Collector: "c1", Stream: streamIDs[stream], Seq: seq,
		From: to.Add(-5 * time.Minute), To: to, QueryText: "hash", PgvigilVersion: "v0.4.0", SchemaLevel: "0329_remote", Key: key,
		Instance: format.Instance{Engine: "sqlserver", Name: d.instName(), Platform: "onprem", ServerVersion: "16.0", VersionNum: 16}})
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

func (d *drop) instName() string {
	if d.inst == "" {
		return `HOST\INST`
	}
	return d.inst
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
	out := f(append([]byte(nil), b...))
	if string(out) == string(b) {
		d.t.Fatalf("the edit of %s changed nothing: the row would test nothing", file)
	}
	if err := os.WriteFile(p, out, 0o600); err != nil {
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

// FOLD 1 B4: -retry loads a bundle the instance went past - set aside (a checksum), the next one loaded after the gap
// on the next day; its file put right and retried, the next round lists its own day and loads it, not late
func TestRoundRetryPastTheNewest(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	d.base = time.Date(2026, 11, 16, 23, 45, 0, 0, time.UTC) // seq 2 ends 23:55 on the 16th, seq 3 00:00 on the 17th
	d.write("st1", 1, "mssql_activity", nil)
	r2 := d.write("st1", 2, "mssql_activity", nil)
	r3 := d.write("st1", 3, "mssql_activity", nil)
	var good []byte
	d.edit(r2, "mssql_activity.ndjson.gz", func(b []byte) []byte { good = append([]byte(nil), b...); b[len(b)-9] ^= 0xff; return b })
	now := r3.End.Add(time.Hour)
	round(t, d.ingester(h, now, nil))
	eq(t, "1 and 3 loaded", h.order, []string{"st1/1", "st1/3"})
	if err := os.WriteFile(d.path(r2, "mssql_activity.ndjson.gz"), good, 0o600); err != nil {
		t.Fatal(err)
	}
	h.retryBundle("site1", "c1", r2)
	r := round(t, d.ingester(h, now.Add(time.Minute), nil))
	eq(t, "-retry loads the bundle the instance went past", h.order, []string{"st1/1", "st1/3", "st1/2"})
	eq(t, "loaded", r.Loaded, 1)
	eq(t, "late", r.Late, 0)
}

// FOLD 1 S5: a Load error other than 'owned elsewhere' holds its own instance key while the bundle settles - the other
// keys load in the same round - and past the settle time marks the bundle 'load' with the error, the round going on
func TestRoundLoadErrorHoldsItsKeyOnly(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	ra := d.write("st1", 1, "mssql_activity", nil)
	d.inst = "OTHER"
	rb := d.write("st1", 1, "mssql_activity", nil)
	h.fail[ra.InstanceKey] = errors.New("ensure_instance: instance site1/HOST\\INST is already stored as engine postgres, not sqlserver")
	res, err := d.ingester(h, ra.End.Add(time.Minute), nil).Round(context.Background())
	if err != nil {
		t.Fatalf("one key's load error stopped the round: %v", err)
	}
	if len(h.loads) != 1 || h.loads[0].Ref.InstanceKey != rb.InstanceKey {
		t.Errorf("the other key's bundle in the same round: %d loads", len(h.loads))
	}
	eq(t, "the failing key waits inside the settle time", res.Waiting, 1)
	eq(t, "nothing marked yet", h.markKinds(), []string(nil))
	res = round(t, d.ingester(h, ra.End.Add(16*time.Minute), nil))
	eq(t, "past the settle time: marked 'load'", h.markKinds(), []string{"st1/1:load"})
	if len(h.marks) == 1 && !strings.Contains(h.marks[0].Reason, "already stored") {
		t.Errorf("the mark's reason carries the error: %q", h.marks[0].Reason)
	}
	eq(t, "set aside", res.SetAside, 1)
}
