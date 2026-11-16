package export

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The folder destination: what is absent, what is listed, and a manifest written only where none is.
func TestFolderDestination(t *testing.T) {
	ctx := context.Background()
	d := NewFolder(filepath.Join(t.TempDir(), "repo"))
	if _, err := d.Get(ctx, "_manifests/a.json"); !errors.Is(err, errAbsent) {
		t.Fatalf("Get of nothing: %v", err)
	}
	if keys, err := d.List(ctx, "_manifests/"); err != nil || len(keys) != 0 {
		t.Fatalf("List of nothing: %v, %v", keys, err)
	}
	if err := d.Delete(ctx, "_manifests/a.json"); err != nil {
		t.Fatalf("Delete of nothing: %v", err)
	}
	if err := d.Put(ctx, "_manifests/a.json", []byte("one"), true); err != nil {
		t.Fatal(err)
	}
	if err := d.Put(ctx, "_manifests/a.json", []byte("two"), true); !errors.Is(err, errExists) {
		t.Fatalf("a second write of a manifest must be refused: %v", err)
	}
	if b, err := d.Get(ctx, "_manifests/a.json"); err != nil || string(b) != "one" {
		t.Fatalf("the first manifest stands: %q, %v", b, err)
	}
	if err := d.Put(ctx, "_manifests/_final/a", []byte("x"), false); err != nil {
		t.Fatal(err)
	}
	if err := d.Put(ctx, "_manifests/_final/a", []byte("y"), false); err != nil {
		t.Fatalf("a marker may be written again: %v", err)
	}
	local := filepath.Join(t.TempDir(), "f.parquet")
	if err := os.WriteFile(local, []byte("PAR1"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := d.Upload(ctx, "t/f.parquet", local); err != nil {
		t.Fatal(err)
	}
	keys, err := d.List(ctx, "_manifests/")
	if err != nil || len(keys) != 2 || keys[0] != "_manifests/_final/a" || keys[1] != "_manifests/a.json" {
		t.Fatalf("List: %v, %v (no .tmp, no .new, sorted)", keys, err)
	}
	if all, _ := d.List(ctx, ""); len(all) != 3 {
		t.Fatalf("everything: %v", all)
	}
	if err := CheckDestination(ctx, d); err != nil {
		t.Fatal(err)
	}
	if all, _ := d.List(ctx, ""); len(all) != 3 {
		t.Fatalf("the check leaves nothing: %v", all)
	}
	if err := d.Delete(ctx, "t/f.parquet"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Get(ctx, "t/f.parquet"); !errors.Is(err, errAbsent) {
		t.Fatalf("deleted: %v", err)
	}
}

func TestWindowNames(t *testing.T) {
	w, ok := windowOfKey("_manifests/prod__20260131T1400Z__20260131T1500Z.json", "prod")
	if !ok || w.From.Hour() != 14 || !w.To.Equal(w.From.Add(3600e9)) {
		t.Fatalf("a manifest's key: %v %v", w, ok)
	}
	for _, k := range []string{
		"_manifests/prod__20260131T1400Z__20260131T1500Z__t0a1b2c3d.json", // a subset run's
		"_manifests/other__20260131T1400Z__20260131T1500Z.json",           // another repository's
		"_manifests/prod__20260131T1400Z__20260131T1600Z.json",            // not one hour
		"_manifests/_check_abc",
	} {
		if _, ok := windowOfKey(k, "prod"); ok {
			t.Errorf("%s is not a window's manifest", k)
		}
	}
	if w2, ok := windowOfKey(finalKey("prod", w), "prod"); !ok || !w2.From.Equal(w.From) {
		t.Errorf("a marker's key reads back: %v %v", w2, ok)
	}
	if manifestKey("prod", w, "") != "_manifests/prod__20260131T1400Z__20260131T1500Z.json" {
		t.Errorf("manifestKey: %s", manifestKey("prod", w, ""))
	}
	if a, b := subsetMark([]string{"b", "a"}), subsetMark([]string{"a", "b"}); a != b || len(a) != 11 || a[:3] != "__t" {
		t.Errorf("a subset's mark is of its tables, in any order: %s %s", a, b)
	}
	// the name is the key's own prefix: one that ends in an underscore (the configuration refuses it) still reads back
	if w3, ok := windowOfKey(manifestKey("prod_", w, ""), "prod_"); !ok || !w3.From.Equal(w.From) {
		t.Errorf("a manifest of the name prod_ reads back: %v %v", w3, ok)
	}
	if _, ok := windowOfKey(manifestKey("prod_", w, ""), "prod"); ok {
		t.Error("a manifest of prod_ is not one of prod")
	}
	if !(Hour{From: w.From.Add(-14 * 3600e9)}).firstOfDay() || w.firstOfDay() {
		t.Error("the day's first window starts at 00:00 UTC")
	}
}

// A destination that takes a second manifest over the first, or cannot be listed, fails the check: a run needs both.
type lax struct {
	Destination
	noList bool
}

func (d lax) Put(ctx context.Context, key string, body []byte, _ bool) error {
	return d.Destination.Put(ctx, key, body, false)
}

func (d lax) List(ctx context.Context, prefix string) ([]string, error) {
	if d.noList {
		return nil, errors.New("no right to list")
	}
	return d.Destination.List(ctx, prefix)
}

func TestCheckDestinationTriesWhatARunNeeds(t *testing.T) {
	ctx := context.Background()
	good := NewFolder(filepath.Join(t.TempDir(), "repo"))
	if err := CheckDestination(ctx, good); err != nil {
		t.Fatal(err)
	}
	if err := CheckDestination(ctx, lax{Destination: NewFolder(filepath.Join(t.TempDir(), "a"))}); err == nil {
		t.Error("a destination that lets a second manifest replace the first passes the check")
	}
	if err := CheckDestination(ctx, lax{Destination: good, noList: true}); err == nil {
		t.Error("a destination that cannot be listed passes the check")
	}
	if all, _ := good.List(ctx, ""); len(all) != 0 {
		t.Errorf("the check leaves nothing: %v", all)
	}
}

// What a run takes and in what order: a window whose manifest an unfinished pass removed first, then the hours in
// reach with no manifest (oldest first: they are the ones a deadline can lose), then the final passes owed.
func TestDueOrder(t *testing.T) {
	h := func(n int) time.Time {
		return time.Date(2026, 3, 10, 0, 0, 0, 0, time.UTC).Add(time.Duration(n) * time.Hour)
	}
	now := h(100).Add(10 * time.Minute)
	st := &destState{done: map[time.Time]bool{}, final: map[time.Time]bool{}, pending: map[time.Time]bool{}}
	for n := 40; n < 60; n++ { // first passes written before an outage: hours 40 .. 59, none final
		st.done[h(n)] = true
	}
	st.oldest, st.newest = h(40), h(59)
	delete(st.done, h(45)) // a final pass removed this window's manifest and did not finish
	st.pending[h(45)] = true
	todo, aged := dueJobs(now, 20*time.Minute, 30*time.Hour, 24*time.Hour, st)
	// the reach holds the hours that ended after 70:10, from hour 70 on; with no manifest and settled: 70 .. 98
	if len(todo) < 31 || !todo[0].w.From.Equal(h(45)) || !todo[0].final {
		t.Fatalf("the unfinished window comes first, as a final pass: %v", todo[:1])
	}
	for i := 0; i < 29; i++ {
		if j := todo[1+i]; !j.w.From.Equal(h(70 + i)) {
			t.Fatalf("job %d is %v, want the hour %d in reach", 1+i, j.w.From, 70+i)
		}
	}
	if j := todo[30]; !j.w.From.Equal(h(40)) || !j.final {
		t.Errorf("the final passes owed come after the hours in reach, oldest first: %v", j)
	}
	if n := len(todo); n != 1+29+19 {
		t.Errorf("%d jobs, want 49 (1 unfinished, 29 in reach, 19 final passes)", n)
	}
	// aged out: no manifest, ended before the reach, between the export's first window and the reach: 60 .. 69
	if len(aged) != 10 || !aged[0].From.Equal(h(60)) || !aged[9].From.Equal(h(69)) {
		t.Errorf("aged out: %v", aged)
	}
	// a window that is final already, and one too young for its final pass, are no work
	st.final[h(40)] = true
	todo, _ = dueJobs(now, 20*time.Minute, 30*time.Hour, 24*time.Hour, st)
	for _, j := range todo {
		if j.w.From.Equal(h(40)) {
			t.Error("a window with its final marker is done")
		}
	}
	young := &destState{done: map[time.Time]bool{h(98): true}, final: map[time.Time]bool{}, pending: map[time.Time]bool{}, oldest: h(98), newest: h(98)}
	// a young export owes the hours of its reach it has not written (70 .. 97), nothing is aged; an hour already
	// final_after_hours old when it is first exported is exported as final at once (70 .. 75), the rest as pass 1
	todo, aged = dueJobs(now, 20*time.Minute, 30*time.Hour, 24*time.Hour, young)
	if len(todo) != 28 || len(aged) != 0 || !todo[0].w.From.Equal(h(70)) || !todo[0].final || !todo[5].final || todo[6].final || !todo[6].w.From.Equal(h(76)) {
		t.Errorf("a young export: %d jobs (want 28), %v aged, the first %v final %v, the seventh %v final %v", len(todo), aged, todo[0].w.From, todo[0].final, todo[6].w.From, todo[6].final)
	}
}

// The S3 destination's signing region: the destination's own region, else the AWS configuration's (AWS_REGION, the
// profile's region); only then, for a store named by its endpoint that is not AWS's, the S3-compatible signing
// default. An AWS destination with no region anywhere is refused with the setting to fill - pgvigil never picks an
// AWS region, so a government endpoint never signs as a commercial region.
func TestS3Region(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	cfgFile := filepath.Join(dir, "config")
	if err := os.WriteFile(cfgFile, []byte("[profile p]\nregion = eu-north-1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AWS_CONFIG_FILE", cfgFile)
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", filepath.Join(dir, "none"))
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_DEFAULT_PROFILE", "")
	t.Setenv("AWS_DEFAULT_REGION", "")
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")
	const store = "http://127.0.0.1:9000"
	for _, c := range []struct {
		name, env string
		o         S3Options
		want      string // the client's region; "" = refused
	}{
		{"the environment's region with an endpoint", "eu-west-3", S3Options{Endpoint: store}, "eu-west-3"},
		{"the profile's region with an endpoint", "", S3Options{Endpoint: store, Profile: "p"}, "eu-north-1"},
		{"the destination's region over the environment's", "eu-west-3", S3Options{Endpoint: store, Region: "ap-south-1"}, "ap-south-1"},
		{"no region anywhere, an S3-compatible store", "", S3Options{Endpoint: store}, "us-east-1"},
		{"no region anywhere, an AWS endpoint", "", S3Options{Endpoint: "https://s3.eu-west-3.amazonaws.com"}, ""},
		{"no region anywhere, AWS by default", "", S3Options{}, ""},
	} {
		t.Setenv("AWS_REGION", c.env)
		c.o.Bucket, c.o.Name = "b", "r"
		d, err := NewS3(ctx, c.o)
		if c.want == "" {
			if err == nil || !strings.Contains(err.Error(), "export.destination.region") {
				t.Errorf("%s: %v; want a refusal naming export.destination.region", c.name, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		if got := d.(*s3Dest).c.Options().Region; got != c.want {
			t.Errorf("%s: signs as %q, want %q", c.name, got, c.want)
		}
	}
}

// A bucket's or a container's keys are rooted at '<prefix>/<name>/', and at the prefix alone when the name is empty (a
// remote collector's push and the hub's drops read the prefix itself): never '<prefix>//' or '/'.
func TestDestinationRoots(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	t.Setenv("AWS_CONFIG_FILE", filepath.Join(dir, "none"))
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", filepath.Join(dir, "none"))
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_EC2_METADATA_DISABLED", "true")
	t.Setenv("AWS_REGION", "eu-west-3")
	for _, c := range []struct{ prefix, name, want string }{
		{"exports", "r", "exports/r/"},
		{"/exports/", "", "exports/"},
		{"", "r", "r/"},
		{"", "", ""},
	} {
		d, err := NewS3(ctx, S3Options{Endpoint: "http://127.0.0.1:9000", Bucket: "b", Prefix: c.prefix, Name: c.name})
		if err != nil {
			t.Fatalf("s3 %q %q: %v", c.prefix, c.name, err)
		}
		if got := d.(*s3Dest).root; got != c.want {
			t.Errorf("s3 prefix %q name %q: root %q, want %q", c.prefix, c.name, got, c.want)
		}
		b, err := NewAzureBlob(BlobOptions{SASURL: "https://acct.blob.core.windows.net/c?sv=2024-01-01&sig=x", Container: "c", Prefix: c.prefix, Name: c.name})
		if err != nil {
			t.Fatalf("blob %q %q: %v", c.prefix, c.name, err)
		}
		if got := b.(*blobDest).root; got != c.want {
			t.Errorf("blob prefix %q name %q: root %q, want %q", c.prefix, c.name, got, c.want)
		}
	}
}
