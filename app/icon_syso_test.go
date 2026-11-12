package main

// The exe's own icon (task 191): rsrc_windows_amd64.syso holds mark E as icon group 1 at 16, 32, 48 and 256 px, drawn
// by iconPixel, so Explorer, a pinned taskbar button and Programs and Features show the mark. The Go linker takes a
// .syso in the package directory when it builds for windows/amd64; the file is committed, so the build needs no tool.
// After a change to icon.go: `go generate` here (this test with -syso writes the file); without -syso the test fails
// when the committed file is not what iconPixel draws now. The images are PNG-encoded by image/png, so a Go release
// that changes that encoder's output also fails it: `go generate` again (the drawing is the same).

//go:generate go test -run TestIconSyso -count=1 . -args -syso

import (
	"bytes"
	"flag"
	"image"
	"image/color"
	"os"
	"testing"

	"github.com/tc-hib/winres"
)

var writeSyso = flag.Bool("syso", false, "write "+sysoFile+" from iconPixel")

const sysoFile = "rsrc_windows_amd64.syso"

var sysoSizes = []int{16, 32, 48, 256}

// iconImage is iconPixel's drawing at n x n with straight alpha (iconPixel is premultiplied).
func iconImage(n int) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, n, n))
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			p := iconPixel(x, y, n)
			a := p >> 24
			r, g, b := p>>16&0xff, p>>8&0xff, p&0xff
			if a > 0 {
				r, g, b = min(r*255/a, 255), min(g*255/a, 255), min(b*255/a, 255)
			}
			img.SetNRGBA(x, y, color.NRGBA{R: uint8(r), G: uint8(g), B: uint8(b), A: uint8(a)})
		}
	}
	return img
}

// iconSyso is the object file: one icon group (ID 1, the exe's icon) with an image per size.
func iconSyso() ([]byte, error) {
	imgs := make([]image.Image, 0, len(sysoSizes))
	for _, n := range sysoSizes {
		imgs = append(imgs, iconImage(n))
	}
	icon, err := winres.NewIconFromImages(imgs)
	if err != nil {
		return nil, err
	}
	rs := &winres.ResourceSet{}
	if err := rs.SetIcon(winres.ID(1), icon); err != nil {
		return nil, err
	}
	var b bytes.Buffer
	if err := rs.WriteObject(&b, winres.ArchAMD64); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func TestIconSyso(t *testing.T) {
	want, err := iconSyso()
	if err != nil {
		t.Fatal(err)
	}
	if *writeSyso {
		if err := os.WriteFile(sysoFile, want, 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("%s written: %d bytes, icon group 1 at %v px", sysoFile, len(want), sysoSizes)
		return
	}
	got, err := os.ReadFile(sysoFile)
	if err != nil {
		t.Fatalf("%v (go generate in app/ writes it)", err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("%s (%d bytes) is not what iconPixel draws now (%d bytes): go generate in app/", sysoFile, len(got), len(want))
	}
}
