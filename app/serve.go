package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Serve is the pgvigil serve the window shows: attached (another process runs it) or started here.
type Serve struct {
	URL     string
	Started bool // started by this app: stopped when the app quits

	cmd  *exec.Cmd
	done chan struct{} // closed when the started process has exited
	err  error         // its exit error, read after done

	mu   sync.Mutex
	tail []string // the serve's last log lines
}

// Probe says whether a pgvigil serve answers at base (http://host:port/): GET api/health gives 200
// with the health table, or 401 with an error (the UI login is on). Anything else is not one.
func Probe(ctx context.Context, client *http.Client, base string) bool {
	u, err := url.Parse(base)
	if err != nil || u.Scheme != "http" || !loopbackHost(u.Hostname()) {
		return false // the app attaches to loopback only: the window never shows another machine's serve
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(base, "/")+"/api/health", nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer func() { _ = resp.Body.Close() }()
	var body map[string]any
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&body); err != nil {
		return false
	}
	switch resp.StatusCode {
	case http.StatusOK:
		cols, _ := body["columns"].([]any)
		return len(cols) > 0 && cols[0] == "schema_version"
	case http.StatusUnauthorized:
		_, ok := body["error"].(string)
		return ok
	}
	return false
}

func loopbackHost(h string) bool { return h == "127.0.0.1" || h == "localhost" || h == "::1" }

// servedURL finds the URL in serve's start line: msg="pgvigil serve started" url=http://127.0.0.1:N/
var servedURL = regexp.MustCompile(`msg="pgvigil serve started" url=(http://127\.0\.0\.1:[0-9]+/)`)

// ServeArgs are the arguments of the serve this app starts: loopback, a free port, the UI login on
// unless the user chose -no-login (which serve allows on loopback only).
func ServeArgs(config string, noLogin bool) []string {
	a := []string{"serve", "-config", config, "-listen", "127.0.0.1:0"}
	if noLogin {
		a = append(a, "-no-login")
	}
	return a
}

// StartServe runs exe with args, reads its log (stderr) until the start line names the URL, and
// returns. prepare sets the platform's process attributes (no console window, the job object).
// The serve's log keeps being read into Tail, and into logw when it is not nil.
func StartServe(ctx context.Context, exe string, args []string, logw io.Writer, prepare func(*exec.Cmd) error, after func(*exec.Cmd) error) (*Serve, error) {
	cmd := exec.Command(exe, args...)
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if prepare != nil {
		if err := prepare(cmd); err != nil {
			return nil, err
		}
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start %s: %w", exe, err)
	}
	s := &Serve{Started: true, cmd: cmd, done: make(chan struct{})}
	if after != nil {
		if err := after(cmd); err != nil { // the job object: a failure leaves the serve to Stop alone
			s.addTail("app: " + err.Error())
		}
	}
	found := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stderr)
		sc.Buffer(make([]byte, 64*1024), 1<<20)
		sent := false
		for sc.Scan() {
			line := sc.Text()
			s.addTail(line)
			if logw != nil {
				_, _ = fmt.Fprintln(logw, line)
			}
			if m := servedURL.FindStringSubmatch(line); m != nil && !sent {
				found <- m[1]
				sent = true
			}
		}
	}()
	go func() { s.err = cmd.Wait(); close(s.done) }()
	t := time.NewTimer(45 * time.Second)
	defer t.Stop()
	select {
	case u := <-found:
		s.URL = u
		return s, nil
	case <-s.done:
		time.Sleep(100 * time.Millisecond) // the reader's last lines
		return nil, fmt.Errorf("pgvigil serve exited before it listened (%v):\n%s", s.err, s.Tail())
	case <-t.C:
		_ = s.Stop()
		return nil, fmt.Errorf("pgvigil serve did not listen within 45 s:\n%s", s.Tail())
	case <-ctx.Done():
		_ = s.Stop()
		return nil, ctx.Err()
	}
}

func (s *Serve) addTail(line string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.tail = append(s.tail, line)
	if len(s.tail) > 30 {
		s.tail = s.tail[len(s.tail)-30:]
	}
}

// Tail is the serve's last log lines.
func (s *Serve) Tail() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.tail, "\n")
}

// Done is closed when a started serve has exited (nil for an attached one).
func (s *Serve) Done() <-chan struct{} { return s.done }

// Pid is the started serve's process id (0 when attached).
func (s *Serve) Pid() int {
	if s == nil || s.cmd == nil || s.cmd.Process == nil {
		return 0
	}
	return s.cmd.Process.Pid
}

// Stop ends a serve this app started and waits for it; an attached serve is left running.
func (s *Serve) Stop() error {
	if s == nil || !s.Started || s.cmd == nil {
		return nil
	}
	select {
	case <-s.done:
		return nil
	default:
	}
	if err := s.cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	select {
	case <-s.done:
		return nil
	case <-time.After(10 * time.Second):
		return errors.New("pgvigil serve did not exit within 10 s of the kill")
	}
}
