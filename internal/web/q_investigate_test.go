package web

import (
	"strings"
	"testing"
)

// TestInvestigationOffWords: why the investigation door is off, in words a reader takes at once. In queue mode the
// words say that investigations are not offered there (not the audit login the door would need); the demo and
// -no-login keep their words first; in direct mode the audit login's words stay.
func TestInvestigationOffWords(t *testing.T) {
	queued := func(s *Server) *Server { queues.Store(s, &queueState{}); return s }
	cases := []struct {
		name string
		s    *Server
		want string
	}{
		{"queue mode", queued(&Server{auth: &authState{}, actions: &Actions{off: queueNotYet}}),
			"investigations are not offered in queue mode (actions.via queue in pgvigil.yaml)"},
		{"queue mode, -no-login", queued(&Server{actions: &Actions{off: queueNotYet}}),
			"investigations need the UI login: this server runs with -no-login"},
		{"queue mode, a demo", queued(&Server{auth: &authState{}, demo: &demoDoor{}, actions: &Actions{off: queueNotYet}}),
			"investigations are not written on a demo server"},
		{"direct, the audit login off", &Server{auth: &authState{}, actions: &Actions{off: "the audit login could not connect"}},
			"investigations are written through the actions door's audit login, and it is off: the audit login could not connect"},
		{"direct, no actions door", &Server{auth: &authState{}},
			"investigations are written through the actions door's audit login, and it is not connected"},
	}
	for _, c := range cases {
		got := c.s.investigationOff()
		queues.Delete(c.s)
		if !strings.HasPrefix(got, c.want) {
			t.Errorf("%s: %q, want it to start %q", c.name, got, c.want)
		}
		if strings.Contains(got, "off: off") {
			t.Errorf("%s: %q says 'off' twice", c.name, got)
		}
	}
}
