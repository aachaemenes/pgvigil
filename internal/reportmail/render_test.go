package reportmail

import (
	"errors"
	"sync"
	"testing"
)

// TestRendersDoor: a key opens once, for its own user; only the render's session answers it, once; an unknown, a
// reused, a foreign or an ended key is refused; End hands back the issued session to revoke, and a key opened after
// End issues nothing.
func TestRendersDoor(t *testing.T) {
	r := NewRenders()
	issued := map[string]string{}
	n := 0
	issue := func(u string) (string, error) {
		n++
		tok := u + "-tok-" + string(rune('a'+n))
		issued[tok] = u
		return tok, nil
	}

	key, done := r.Start("alice", "#/summary", `{"pgvigil.grid.summary.x":"{}"}`)
	if len(key) != 48 {
		t.Fatalf("key %q", key)
	}
	if _, _, _, _, err := r.Open("zz"+key[2:], issue); !errors.Is(err, ErrNoRender) {
		t.Fatalf("an unknown key opened: %v", err)
	}
	user, route, prefs, tok, err := r.Open(key, issue)
	if err != nil || user != "alice" || route != "#/summary" || prefs == "" || tok == "" {
		t.Fatalf("Open = %q %q %q %q %v", user, route, prefs, tok, err)
	}
	if _, _, _, _, err := r.Open(key, issue); !errors.Is(err, ErrNoRender) || n != 1 {
		t.Fatalf("a key opened twice (issued %d): %v", n, err)
	}
	if r.Answer(key, "bob", tok, 1) || r.Answer(key, "alice", "other", 1) || r.Answer("nokey", "alice", tok, 1) {
		t.Fatal("a foreign session, a wrong token or an unknown key answered")
	}
	if !r.Answer(key, "alice", tok, 7) || !r.Answer(key, "alice", tok, 8) {
		t.Fatal("the render's own session could not answer")
	}
	if v := <-done; v != 7 {
		t.Fatalf("the first answer is the one taken: %v", v)
	}
	select {
	case v := <-done:
		t.Fatalf("a second answer arrived: %v", v)
	default:
	}
	if got := r.End(key); got != tok {
		t.Fatalf("End = %q, want the issued session %q", got, tok)
	}
	if r.Answer(key, "alice", tok, 9) || r.End(key) != "" {
		t.Fatal("an ended render answered or ended twice")
	}

	// a render that ends before the browser opens it: nothing to revoke, and the late open issues nothing
	k2, _ := r.Start("alice", "#/jobs", "")
	if r.End(k2) != "" {
		t.Fatal("an unopened render handed back a session")
	}
	before := n
	if _, _, _, _, err := r.Open(k2, issue); !errors.Is(err, ErrNoRender) || n != before {
		t.Fatal("a key opened after its render ended")
	}

	// an issue that fails leaves no session behind
	k3, _ := r.Start("carol", "#/summary", "")
	if _, _, _, _, err := r.Open(k3, func(string) (string, error) { return "", errors.New("no") }); err == nil {
		t.Fatal("a failed issue opened the key")
	}
	if r.End(k3) != "" {
		t.Fatal("a failed issue left a session")
	}
}

// TestRendersRace: Open and End at once, many times: either the open sees the render (and End hands back its session)
// or it does not (and issues nothing); a session is never issued and lost.
func TestRendersRace(t *testing.T) {
	r := NewRenders()
	for range 500 {
		key, _ := r.Start("alice", "#/summary", "")
		var issued, ended string
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			_, _, _, tok, err := r.Open(key, func(string) (string, error) { return "tok", nil })
			if err == nil {
				issued = tok
			}
		}()
		go func() { defer wg.Done(); ended = r.End(key) }()
		wg.Wait()
		if issued != "" && ended != issued && r.End(key) == "" {
			t.Fatal("a session was issued after its render ended and never handed back")
		}
	}
}
