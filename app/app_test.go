package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func u32(v uint32) *uint32 { return &v }

func TestMerge(t *testing.T) {
	s := Merge(Choices{})
	if !s.UpdateCheck || s.UpdateFeed != DefaultFeed || s.AttachURL != DefaultAttachURL || s.Width != 1280 || s.Height != 800 || s.NoLogin {
		t.Errorf("defaults: %+v", s)
	}
	// the policy turns the check off whatever the user says; the user can turn it off alone
	if s := Merge(Choices{PolicyUpdateCheck: u32(0), UserUpdateCheck: u32(1)}); s.UpdateCheck || !strings.Contains(s.UpdateWhy, "administrator") {
		t.Errorf("policy off: %+v", s)
	}
	if s := Merge(Choices{PolicyUpdateCheck: u32(1), UserUpdateCheck: u32(0)}); s.UpdateCheck || !strings.Contains(s.UpdateWhy, "user") {
		t.Errorf("user off: %+v", s)
	}
	// the policy's attach URL and feed win; a URL gets its slash
	s = Merge(Choices{UserAttachURL: "http://127.0.0.1:9000", PolicyAttachURL: "http://127.0.0.1:9100", PolicyUpdateFeed: "https://mirror.example/latest.json"})
	if s.AttachURL != "http://127.0.0.1:9100/" || s.UpdateFeed != "https://mirror.example/latest.json" {
		t.Errorf("policy values: %+v", s)
	}
	// -no-login: the user's choice unless the policy requires the login
	if !Merge(Choices{UserNoLogin: u32(1)}).NoLogin || Merge(Choices{UserNoLogin: u32(1), PolicyRequireLogin: u32(1)}).NoLogin {
		t.Error("no-login precedence")
	}
	// the saved size, within reason
	if s := Merge(Choices{Width: u32(1500), Height: u32(900), Maximized: u32(1)}); s.Width != 1500 || s.Height != 900 || !s.Maximized {
		t.Errorf("size: %+v", s)
	}
	if s := Merge(Choices{Width: u32(10), Height: u32(900)}); s.Width != 1280 {
		t.Errorf("a size too small is ignored: %+v", s)
	}
}

func TestResolveConfig(t *testing.T) {
	have := map[string]bool{}
	ex := func(p string) bool { return have[p] }
	user := filepath.Join("L", "pgvigil", UIConfigName)
	machine := filepath.Join("P", "pgvigil", "app", UIConfigName)
	if _, _, err := ResolveConfig("", "L", "P", ex); err == nil || !strings.Contains(err.Error(), user) || !strings.Contains(err.Error(), machine) {
		t.Errorf("none: %v", err)
	}
	have[machine] = true
	if p, from, _ := ResolveConfig("", "L", "P", ex); p != machine || from != "machine" {
		t.Errorf("machine: %s %s", p, from)
	}
	have[user] = true
	if p, from, _ := ResolveConfig("", "L", "P", ex); p != user || from != "user" {
		t.Errorf("the user's own first: %s %s", p, from)
	}
	if _, _, err := ResolveConfig("x.yaml", "L", "P", ex); err == nil {
		t.Error("a missing -config file")
	}
	have["x.yaml"] = true
	if p, from, _ := ResolveConfig("x.yaml", "L", "P", ex); p != "x.yaml" || from != "flag" {
		t.Errorf("flag: %s %s", p, from)
	}
}

func TestProbe(t *testing.T) {
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/health" {
			_, _ = w.Write([]byte(`{"columns":["schema_version","server_now"],"rows":[["0045","x"]]}`))
		}
	}))
	defer ok.Close()
	login := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"login required"}`))
	}))
	defer login.Close()
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"status":"ok"}`)) }))
	defer other.Close()
	ctx := context.Background()
	c := ok.Client()
	if !Probe(ctx, c, ok.URL+"/") || !Probe(ctx, c, login.URL+"/") {
		t.Error("a pgvigil serve (open, or behind its login) is found")
	}
	if Probe(ctx, c, other.URL+"/") || Probe(ctx, c, "http://127.0.0.1:1/") {
		t.Error("another server, or none, is not a pgvigil serve")
	}
	if Probe(ctx, c, strings.Replace(ok.URL, "127.0.0.1", "example.com", 1)+"/") {
		t.Error("only loopback is attached to")
	}
}

// TestHelperServe is not a test: StartServe runs the test binary as a stand-in serve.
func TestHelperServe(_ *testing.T) {
	mode := os.Getenv("PGVIGIL_APP_HELPER")
	if mode == "" {
		return
	}
	switch mode {
	case "ok":
		fmt.Fprintln(os.Stderr, `time=x level=WARN msg="something first"`)
		fmt.Fprintln(os.Stderr, `time=x level=INFO msg="pgvigil serve started" url=http://127.0.0.1:43210/ login=true`)
		time.Sleep(time.Minute)
	case "fail":
		fmt.Fprintln(os.Stderr, `time=x level=ERROR msg="pgvigil failed" err="repository ping: connection refused"`)
		os.Exit(1)
	}
	os.Exit(0)
}

func helper(t *testing.T, mode string) func(*exec.Cmd) error {
	t.Helper()
	return func(c *exec.Cmd) error {
		c.Env = append(os.Environ(), "PGVIGIL_APP_HELPER="+mode)
		return nil
	}
}

func TestStartServe(t *testing.T) {
	exe, _ := os.Executable()
	args := []string{"-test.run=^TestHelperServe$"}
	s, err := StartServe(context.Background(), exe, args, nil, helper(t, "ok"), nil)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if s.URL != "http://127.0.0.1:43210/" || !s.Started || s.Pid() == 0 {
		t.Errorf("serve: %+v", s)
	}
	if err := s.Stop(); err != nil {
		t.Errorf("stop: %v", err)
	}
	select {
	case <-s.Done():
	default:
		t.Error("the process still runs after Stop")
	}
	_, err = StartServe(context.Background(), exe, args, nil, helper(t, "fail"), nil)
	if err == nil || !strings.Contains(err.Error(), "connection refused") {
		t.Errorf("a serve that exits says why: %v", err)
	}
	if got := ServeArgs(`C:\x\pgvigil.yaml`, true); strings.Join(got, " ") != `serve -config C:\x\pgvigil.yaml -listen 127.0.0.1:0 -no-login` {
		t.Errorf("args: %v", got)
	}
	if got := ServeArgs("c", false); len(got) != 5 {
		t.Errorf("the login stays on by default: %v", got)
	}
	var a *Serve
	if a.Stop() != nil || (&Serve{URL: "x"}).Stop() != nil {
		t.Error("an attached serve is never stopped")
	}
}

func TestUpdate(t *testing.T) {
	var hits int
	feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if ua := r.Header.Get("User-Agent"); !strings.HasPrefix(ua, "pgvigil-app/") {
			t.Errorf("user agent %q", ua)
		}
		_, _ = w.Write([]byte(`{"tag_name":"v0.3.0","html_url":"https://github.com/aachaemenes/pgvigil/releases/tag/v0.3.0","assets":[]}`))
	}))
	defer feed.Close()
	ctx := context.Background()
	rel, newer, err := CheckUpdate(ctx, feed.Client(), feed.URL, "v0.2.0")
	if err != nil || !newer || rel.Tag != "v0.3.0" || rel.URL == "" {
		t.Errorf("newer: %v %v %+v", err, newer, rel)
	}
	if _, newer, _ := CheckUpdate(ctx, feed.Client(), feed.URL, "v0.3.0"); newer {
		t.Error("the same version is not newer")
	}
	if _, _, err := CheckUpdate(ctx, feed.Client(), "http://example.com/feed", "v0.1.0"); err == nil {
		t.Error("plain http beyond loopback is refused")
	}
	if hits != 2 {
		t.Errorf("feed hits %d, want 2", hits)
	}
	for _, c := range []struct {
		tag, cur string
		want     bool
	}{{"v1.0.0", "v0.9.9", true}, {"v0.10.0", "v0.9.0", true}, {"v0.2.0", "v0.10.0", false}, {"v1.0.0", "dev", false}, {"v1.0.0-rc1", "v0.1.0", false}} {
		if Newer(c.tag, c.cur) != c.want {
			t.Errorf("Newer(%s, %s) != %v", c.tag, c.cur, c.want)
		}
	}
	now := time.Now()
	if !DueForCheck(0, now) || DueForCheck(now.Add(-time.Hour).Unix(), now) || !DueForCheck(now.Add(-25*time.Hour).Unix(), now) || !DueForCheck(now.Add(48*time.Hour).Unix(), now) {
		t.Error("due rules")
	}
}

func TestIcon(t *testing.T) {
	n := 32
	if a := iconPixel(0, 0, n) >> 24; a != 0 {
		t.Errorf("the corner is transparent, alpha %d", a)
	}
	if p := iconPixel(n/2, n/2, n); p != 0xFFFFFFFF {
		t.Errorf("the pupil is white: %08x", p)
	}
	if p := iconPixel(n/2, 3, n); p>>24 != 0xFF || p&0xFFFFFF == 0xFFFFFF {
		t.Errorf("the disc is teal and opaque: %08x", p)
	}
}

func TestTemplate(t *testing.T) {
	c := ConfigTemplate()
	if !strings.Contains(c, "repository:") || !strings.Contains(c, "instances: []") || strings.Contains(strings.ToLower(c), "password=") {
		t.Errorf("template: %s", c)
	}
}
