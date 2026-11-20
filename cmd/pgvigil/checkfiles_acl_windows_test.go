//go:build windows

package main

import (
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// TestSecretFileWalk (the Windows turn runs it from the test binary): the access-list walk over lists made from SDDL -
// a Users grant, an inherited one, a folder's inherit-only rule for its files, a deny that cancels an allow, a generic
// read, a single account's full control on the page's folder, and no list at all.
func TestSecretFileWalk(t *testing.T) {
	allowed := map[string]bool{"S-1-5-18": true, "S-1-5-32-544": true}
	for _, c := range []struct {
		name, sddl string
		dir, page  bool
		level      string
		says       string
	}{
		{"the installer's list", "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", true, false, "OK", ""},
		{"Users read", "D:P(A;;FA;;;SY)(A;;FR;;;BU)", false, false, "FAIL", "/remove:g *S-1-5-32-545"},
		{"Users inherited", "D:(A;ID;FR;;;BU)(A;;FA;;;SY)", false, false, "FAIL", "inherited from above"},
		{"a folder's rule for its files", "D:P(A;OICI;FA;;;SY)(A;OIIO;FR;;;BU)", true, false, "FAIL", "S-1-5-32-545"},
		{"a deny that cancels", "D:P(D;;FR;;;BU)(A;;FR;;;BU)(A;;FA;;;SY)", false, false, "OK", ""},
		{"generic read", "D:P(A;;GR;;;WD)", false, false, "FAIL", "/remove:g *S-1-1-0"},
		{"one account on the page's folder", "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;S-1-5-21-1-2-3-1104)", true, true, "WARN", "S-1-5-21-1-2-3-1104"},
	} {
		sd, err := windows.SecurityDescriptorFromString(c.sddl)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		dacl, _, err := sd.DACL()
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		level, words := judgeDACL(secretPath{Path: `C:\ProgramData\pgvigil\x`, Dir: c.dir, Page: c.page}, dacl, allowed)
		if level != c.level || !strings.Contains(words, c.says) {
			t.Errorf("%s: %s %q, want %s saying %q", c.name, level, words, c.level, c.says)
		}
	}
	if level, words := judgeDACL(secretPath{Path: `C:\ProgramData\pgvigil\x`}, nil, allowed); level != "FAIL" || !strings.Contains(words, "no access list") || strings.Contains(words, "/grant:r *S-1-5-18:F *S-1-5-32-544:F") {
		t.Errorf("no list: %s %q, want the FAIL whose fix is the installer's", level, words)
	}
}
