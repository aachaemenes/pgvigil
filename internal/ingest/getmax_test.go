package ingest

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/remote/format"
)

// OUTBOX H GETMAX (relw2c-s2 13:3x): ingest reads every drop file under a cap - the manifest and SHA256SUMS under the
// format's manifest cap, manifest.sig under its own, each view file under its manifest bytes + 1 - so one oversized or
// corrupt file in a site's drop never takes the hub's memory. The caps as the format names them (1 MiB, 4 KiB):
const (
	rowManifestCap = 1 << 20
	rowSigCap      = 4 << 10
)

// capDrop records each read of the drop in order - its key and its cap (-1 = a Get with no cap) - and answers a capped
// read through the folder's own GetMax when it has one, else a Get and a length check (the helper's fallback)
type capDrop struct {
	Drop
	reads []capRead
}

type capRead struct {
	key string
	max int64
}

func (c *capDrop) Get(ctx context.Context, key string) ([]byte, error) {
	c.reads = append(c.reads, capRead{key, -1})
	return c.Drop.Get(ctx, key)
}

func (c *capDrop) GetMax(ctx context.Context, key string, max int64) ([]byte, error) {
	c.reads = append(c.reads, capRead{key, max})
	if g, ok := c.Drop.(interface {
		GetMax(context.Context, string, int64) ([]byte, error)
	}); ok {
		return g.GetMax(ctx, key, max)
	}
	b, err := c.Drop.Get(ctx, key)
	if err == nil && int64(len(b)) > max {
		return nil, fmt.Errorf("%s: past the cap of %d bytes", key, max)
	}
	return b, err
}

// readsOf: the reads of one bundle's folder, in order
func (c *capDrop) readsOf(ref format.Ref) []capRead {
	var out []capRead
	for _, r := range c.reads {
		if strings.HasPrefix(r.key, ref.Dir()+"/") {
			out = append(out, r)
		}
	}
	return out
}

func viewFileOf(t *testing.T, d *drop, ref format.Ref) (string, int64) {
	t.Helper()
	b, err := os.ReadFile(d.path(ref, format.ManifestFile))
	if err != nil {
		t.Fatal(err)
	}
	m, err := format.DecodeManifest(b)
	if err != nil || len(m.Files) == 0 {
		t.Fatalf("the bundle's manifest: %v (%d files)", err, len(m.Files))
	}
	return m.Files[0].Name, m.Files[0].Bytes
}

// every read of a whole bundle is capped: the manifest and the sums at the manifest cap, a view file at its manifest
// bytes (the destination reads max + 1 to see past it), the signature at its own cap - no read without one
func TestRoundReadsEveryFileUnderACap(t *testing.T) {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	d, h := newDrop(t), newMemHub()
	r := d.write("st1", 1, "mssql_activity", key)
	view, vbytes := viewFileOf(t, d, r)
	in := d.ingester(h, r.End.Add(time.Minute), map[string][][]byte{"c1": {key.Public().(ed25519.PublicKey)}})
	cd := &capDrop{Drop: in.Site.Drop}
	in.Site.Drop = cd
	round(t, in)
	eq(t, "loaded", h.order, []string{"st1/1"})
	want := map[string]int64{format.ManifestFile: rowManifestCap, format.SumsFile: rowManifestCap, format.SigFile: rowSigCap, view: vbytes}
	got := map[string]int64{}
	for _, rd := range cd.readsOf(r) {
		name := strings.TrimPrefix(rd.key, r.Dir()+"/")
		if prev, seen := got[name]; seen && prev != rd.max {
			t.Errorf("%s read twice with two caps: %d then %d", name, prev, rd.max)
		}
		got[name] = rd.max
	}
	for name, max := range want {
		if g, ok := got[name]; !ok {
			t.Errorf("%s: never read", name)
		} else if g != max {
			t.Errorf("%s read with cap %d (-1 = none), want %d", name, g, max)
		}
	}
}

// a view file one byte past its manifest bytes: set aside 'too_big' at once with the file named, read under its cap,
// and no file of that bundle read after it
func TestRoundViewFilePastItsBytesIsTooBig(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	r := d.write("st1", 1, "mssql_activity", nil)
	view, vbytes := viewFileOf(t, d, r)
	d.edit(r, view, func(b []byte) []byte { return append(b, 0) })
	in := d.ingester(h, r.End.Add(time.Minute), nil) // inside the settle: a longer file is final, never a copy running
	cd := &capDrop{Drop: in.Site.Drop}
	in.Site.Drop = cd
	round(t, in)
	eq(t, "not loaded", h.order, []string(nil))
	eq(t, "set aside", h.markKinds(), []string{"st1/1:" + format.KindTooBig})
	if len(h.marks) == 1 && !strings.Contains(h.marks[0].Reason, view) {
		t.Errorf("the mark names the file: %q", h.marks[0].Reason)
	}
	reads := cd.readsOf(r)
	last := -1
	for i, rd := range reads {
		if strings.HasSuffix(rd.key, "/"+view) {
			last = i
			if rd.max != vbytes {
				t.Errorf("%s read with cap %d (-1 = none), want its manifest bytes %d", view, rd.max, vbytes)
			}
		}
	}
	if last < 0 {
		t.Fatalf("%s never read", view)
	}
	if last != len(reads)-1 {
		t.Errorf("read after the oversized file: %v", reads[last+1:])
	}
}

// a manifest past the format's cap: set aside 'too_big' naming manifest.json, never decoded, never loaded; the round
// goes on with the next stream's bundle (before, a manifest read error ended the whole round)
func TestRoundManifestPastItsCapIsTooBig(t *testing.T) {
	d, h := newDrop(t), newMemHub()
	r1 := d.write("st1", 1, "mssql_activity", nil)
	r2 := d.write("st2", 1, "mssql_activity", nil)
	d.edit(r1, format.ManifestFile, func(b []byte) []byte { // still valid JSON: whitespace after the object
		return append(b, bytes.Repeat([]byte(" "), rowManifestCap+1-len(b))...)
	})
	in := d.ingester(h, r2.End.Add(time.Minute), nil)
	cd := &capDrop{Drop: in.Site.Drop}
	in.Site.Drop = cd
	round(t, in)
	eq(t, "the next stream's bundle loaded, the big one not", h.order, []string{"st2/1"})
	var found bool
	for _, m := range h.marks {
		if m.Seq == 1 && m.Kind == format.KindTooBig && strings.Contains(m.Reason, format.ManifestFile) {
			found = true
		}
	}
	if !found {
		t.Errorf("no 'too_big' mark naming %s for seq 1: %v", format.ManifestFile, h.markKinds())
	}
	for _, rd := range cd.readsOf(r1) {
		if rd.max < 0 {
			t.Errorf("%s read with no cap", rd.key)
		}
	}
}

// manifest.sig past its own cap (a valid signature followed by newlines): set aside 'too_big', not loaded
func TestRoundSignaturePastItsCapIsTooBig(t *testing.T) {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	d, h := newDrop(t), newMemHub()
	r := d.write("st1", 1, "mssql_activity", key)
	d.edit(r, format.SigFile, func(b []byte) []byte { return append(b, bytes.Repeat([]byte("\n"), rowSigCap)...) })
	in := d.ingester(h, r.End.Add(time.Minute), map[string][][]byte{"c1": {key.Public().(ed25519.PublicKey)}})
	round(t, in)
	eq(t, "not loaded", h.order, []string(nil))
	eq(t, "set aside", h.markKinds(), []string{"st1/1:" + format.KindTooBig})
}
