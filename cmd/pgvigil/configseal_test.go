package main

import (
	"bytes"
	"strings"
	"testing"
)

// TestConfigSealL155: one versioned file, scrypt over the password, AES-256-GCM
// with the header as additional data; open refuses a wrong password, a changed byte anywhere and another version
// before returning anything.
func TestConfigSealL155(t *testing.T) {
	plain := []byte("repository:\n  dsn: host=h user=u password=s3cret-L155\n")
	a, err := sealExport(plain, "correct horse")
	if err != nil {
		t.Fatal(err)
	}
	b, err := sealExport(plain, "correct horse")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(a, b) {
		t.Errorf("two seals of one payload are the same bytes: the salt and the nonce must be new each time")
	}
	if bytes.Contains(a, []byte("s3cret-L155")) || bytes.Contains(a, []byte("repository")) {
		t.Errorf("the sealed file holds the payload in clear")
	}
	if !bytes.HasPrefix(a, []byte(exportMagic)) {
		t.Errorf("the file does not start with its header %q", exportMagic)
	}
	got, err := openExport(a, "correct horse")
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("open: %v, payload back %v", err, bytes.Equal(got, plain))
	}
	refuse := func(what string, data []byte, pw, says string) {
		t.Helper()
		got, err := openExport(data, pw)
		if err == nil || got != nil || !strings.Contains(err.Error(), says) {
			t.Errorf("%s: %v (payload returned %v), want a refusal saying %q", what, err, got != nil, says)
		}
	}
	refuse("a wrong password", a, "battery staple", "does not open")
	for _, at := range []int{len(exportMagic) + 2, len(exportMagic) + 20, len(a) - 1} {
		c := append([]byte(nil), a...)
		c[at] ^= 0x01
		refuse("a byte changed", c, "correct horse", "does not open")
	}
	v := append([]byte(nil), a...)
	v[len(exportMagic)] = 2
	refuse("version 2", v, "correct horse", "version 2")
	refuse("not an export", []byte("hello, world: not sealed"), "correct horse", "not a pgvigil configuration export")
	refuse("a cut file", a[:len(exportMagic)+10], "correct horse", "not a pgvigil configuration export")
	if _, err := sealExport(plain, ""); err == nil {
		t.Errorf("an empty password sealed")
	}
}
