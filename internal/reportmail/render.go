package reportmail

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// The headless render of a scheduled page (the serve process's side, internal/web/q_reportmail.go): a render key
// names one render in flight. The browser is started on a launch page in its own profile folder (0700: the key never
// appears on a command line, where another user of the host could read it), which sends it to the render's loopback
// listener with the key; that first request is answered once only, with the session issued for the render's user, and
// the page's post-back is taken only from that session. Ending the render forgets the key and hands back the session
// to revoke.

// Renders are the renders in flight, by key.
type Renders struct {
	mu sync.Mutex
	m  map[string]*pending
}

type pending struct {
	user, route, prefs string
	tok                string // the render's session, "" until the browser opens the key
	used               bool
	done               chan any
}

// NewRenders is an empty set.
func NewRenders() *Renders { return &Renders{m: map[string]*pending{}} }

// Start registers a render for user of route (prefs: the grid choices to load first, a JSON object or ""): its key
// and the channel its page's answer arrives on.
func (r *Renders) Start(user, route, prefs string) (string, <-chan any) {
	var b [24]byte
	_, _ = rand.Read(b[:])
	key := hex.EncodeToString(b[:])
	p := &pending{user: user, route: route, prefs: prefs, done: make(chan any, 1)}
	r.mu.Lock()
	r.m[key] = p
	r.mu.Unlock()
	return key, p.done
}

// ErrNoRender is a key that is not a live, unopened render.
var ErrNoRender = errors.New("no such render")

// Open is the browser's first request for key: once only, the render's session from issue (called under the lock,
// so a render that ends meanwhile always sees the session it must revoke), the route and the grid choices.
func (r *Renders) Open(key string, issue func(user string) (string, error)) (user, route, prefs, tok string, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.m[key]
	if p == nil || p.used {
		return "", "", "", "", ErrNoRender
	}
	p.used = true
	if p.tok, err = issue(p.user); err != nil {
		return "", "", "", "", err
	}
	return p.user, p.route, p.prefs, p.tok, nil
}

// Answer hands the page's answer to the render of key; only that render's own session (user and token) may answer,
// and only once. false = no such render for this session.
func (r *Renders) Answer(key, user, tok string, v any) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.m[key]
	if p == nil || !p.used || p.tok == "" || p.user != user || p.tok != tok {
		return false
	}
	select {
	case p.done <- v:
	default: // answered already
	}
	return true
}

// End forgets key: its session, if one was issued, is returned to be revoked.
func (r *Renders) End(key string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.m[key]
	delete(r.m, key)
	if p == nil {
		return ""
	}
	return p.tok
}

// Browser is one headless browser of a render.
type Browser struct {
	cmd     *exec.Cmd
	stderr  *tail
	done    chan struct{}
	waitErr error
}

// StartBrowser starts the browser at path headless in the profile folder dir (made by the caller, 0700), in time
// zone tz, on a launch page written into dir that opens target (the render's loopback address with its key).
func StartBrowser(ctx context.Context, path, dir, target, tz string) (*Browser, error) {
	t, err := json.Marshal(target) // escapes < > & as \u00xx: no way out of the script
	if err != nil {
		return nil, err
	}
	start := filepath.Join(dir, "start.html")
	if err := os.WriteFile(start, []byte(`<!DOCTYPE html><title>pgvigil</title><script>location.replace(`+string(t)+`)</script>`), 0o600); err != nil {
		return nil, err
	}
	u := url.URL{Scheme: "file", Path: filepath.ToSlash(start)}
	if !strings.HasPrefix(u.Path, "/") {
		u.Path = "/" + u.Path // C:/... on Windows
	}
	args := []string{"--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions",
		"--disable-background-networking", "--disable-sync", "--disable-default-apps", "--mute-audio", "--lang=en-US",
		"--window-size=1600,1200", "--user-data-dir=" + dir}
	if runtime.GOOS == "linux" && os.Geteuid() == 0 {
		args = append(args, "--no-sandbox") // Chromium refuses to start as root with its sandbox
	}
	args = append(args, u.String())
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = append(os.Environ(), "TZ="+tz)
	b := &Browser{cmd: cmd, stderr: &tail{n: 4096}, done: make(chan struct{})}
	cmd.Stderr = b.stderr
	cmd.WaitDelay = 5 * time.Second // a child left holding the stderr pipe never holds the wait
	cmd.Cancel = func() error { killGroup(cmd); return nil }
	group(cmd)
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("the browser %s did not start: %w", path, err)
	}
	go func() { b.waitErr = cmd.Wait(); close(b.done) }()
	return b, nil
}

// Done is closed when the browser has ended.
func (b *Browser) Done() <-chan struct{} { return b.done }

// Why is the ended browser's exit and its last line on stderr.
func (b *Browser) Why() string {
	<-b.done
	return fmt.Sprintf("%v: %s", b.waitErr, b.stderr.last())
}

// Stop kills the browser and its process group and waits for it (WaitDelay bounds the wait).
func (b *Browser) Stop() {
	killGroup(b.cmd)
	<-b.done
}

// tail keeps the first n bytes written (a browser's stderr, for the error line)
type tail struct {
	mu  sync.Mutex
	b   strings.Builder
	n   int
	end bool
}

func (t *tail) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	keep := p
	if room := t.n - t.b.Len(); room > 0 && !t.end {
		if len(keep) > room {
			keep = keep[:room]
			t.end = true
		}
		t.b.Write(keep)
	}
	return len(p), nil
}

func (t *tail) last() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	s := strings.TrimSpace(t.b.String())
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return s[i+1:]
	}
	return s
}
