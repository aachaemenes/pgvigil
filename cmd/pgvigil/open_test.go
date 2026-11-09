package main

import (
	"net"
	"strings"
	"testing"
)

func TestBrowseURL(t *testing.T) {
	cases := []struct{ scheme, listen, want string }{
		{"http", "127.0.0.1:8080", "http://127.0.0.1:8080/"},
		{"https", "0.0.0.0:8443", "https://127.0.0.1:8443/"},
		{"http", "[::]:8080", "http://[::1]:8080/"},
		{"http", "[::1]:9", "http://[::1]:9/"},
	}
	for _, c := range cases {
		addr, err := net.ResolveTCPAddr("tcp", c.listen)
		if err != nil {
			t.Fatal(err)
		}
		if got := browseURL(c.scheme, addr); got != c.want {
			t.Errorf("browseURL(%s, %s) = %s, want %s", c.scheme, c.listen, got, c.want)
		}
	}
}

func TestAppWindowCandidates(t *testing.T) {
	env := func(k string) string {
		return map[string]string{"ProgramFiles(x86)": `C:\Program Files (x86)`, "ProgramFiles": `C:\Program Files`, "LocalAppData": `C:\Users\u\AppData\Local`}[k]
	}
	win := appWindowCandidates("windows", "http://127.0.0.1:1/", env)
	if len(win) != 8 || !strings.HasSuffix(win[0][0], `msedge.exe`) || !strings.Contains(win[0][0], "(x86)") || win[0][1] != "--app=http://127.0.0.1:1/" {
		t.Fatalf("windows candidates: %v", win)
	}
	if !strings.Contains(win[2][0], `AppData\Local`) {
		t.Errorf("the user's own Edge install is not a candidate: %v", win[2])
	}
	lin := appWindowCandidates("linux", "http://127.0.0.1:1/", env)
	if lin[0][0] != "chromium" || lin[0][1] != "--app=http://127.0.0.1:1/" {
		t.Errorf("linux candidates: %v", lin)
	}
	mac := appWindowCandidates("darwin", "http://127.0.0.1:1/", env)
	if !strings.HasPrefix(mac[0][0], "/Applications/") {
		t.Errorf("darwin candidates: %v", mac)
	}
	if d := defaultBrowserCommand("windows", "u"); d[0] != "rundll32" {
		t.Errorf("windows default: %v", d)
	}
	if d := defaultBrowserCommand("linux", "u"); d[0] != "xdg-open" || d[1] != "u" {
		t.Errorf("linux default: %v", d)
	}
}
