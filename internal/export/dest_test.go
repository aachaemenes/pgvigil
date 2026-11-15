package export

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
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
	if !(Hour{From: w.From.Add(-14 * 3600e9)}).firstOfDay() || w.firstOfDay() {
		t.Error("the day's first window starts at 00:00 UTC")
	}
}
