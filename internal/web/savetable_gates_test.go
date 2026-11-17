package web

// review-31 part B S8, the route's own gates that come before any read of the store (written 11-17 07:4x, after
// savetable-g3 was queued: it rides savetable-g4): the switch off, queue mode, a save already running in this serve and
// no signed-in user - each answered with its own words and nothing read or written (the Server has no pool: a gate
// that reached the store would panic). The gates past the instance's read (a page instance, the body's instance, the
// upload's 408, the audit door) need a store: their row is a store test of their own.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSaveTableGatesBeforeTheStore(t *testing.T) {
	post := func(s *Server, user string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/api/actions/save_table?instance_id=1", strings.NewReader(`{}`))
		if user != "" {
			r = withWho(r, who{user: user, role: "admin"})
		}
		w := httptest.NewRecorder()
		s.SaveTable(w, r)
		return w
	}
	check := func(what string, w *httptest.ResponseRecorder, code int, words string) {
		t.Helper()
		if w.Code != code || !strings.Contains(w.Body.String(), words) {
			t.Errorf("%s: %d %s, want %d holding %q", what, w.Code, w.Body.String(), code, words)
		}
	}

	// the switch off (never enabled)
	check("the switch off", post(&Server{}, "admin1"), http.StatusForbidden, "doors: save_table")

	// queue mode: this serve holds no login to the monitored server
	q := &Server{actions: &Actions{}}
	q.EnableSaveTable(true)
	queues.Store(q.self(), &queueState{})
	t.Cleanup(func() { queues.Delete(q.self()); saveTables.Delete(q.self()) })
	check("queue mode", post(q, "admin1"), http.StatusForbidden, "queue mode")

	// a save already running in this serve: the second is refused at once (TryLock, never a waiting Lock)
	h := &Server{actions: &Actions{}}
	h.EnableSaveTable(true)
	t.Cleanup(func() { saveTables.Delete(h.self()) })
	h.saveTable().mu.Lock()
	w := post(h, "admin1")
	h.saveTable().mu.Unlock()
	check("a second save while one runs", w, http.StatusConflict, "another Save Table is running")

	// no signed-in user: 401 before the lock is even tried
	check("no signed-in user", post(h, ""), http.StatusUnauthorized, "login required")
}
