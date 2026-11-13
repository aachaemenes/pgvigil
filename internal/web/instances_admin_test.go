package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"
	"time"
)

// A list source's path: a network (UNC) or device path is refused on every system (serve would open it over SMB as
// its machine account), on Windows anything but a drive letter; a path on this server's disk is taken.
func TestListPathOK(t *testing.T) {
	a := &InstancesAdmin{}
	refuse := []string{`\\host\share\list.txt`, `//host/share/list.txt`}
	take := []string{"/srv/lists/servers.txt"}
	if runtime.GOOS == "windows" {
		refuse = append(refuse, `/\host\share\list.txt`, `\/host\share\list.txt`, `\??\UNC\host\share\list.txt`, `\\?\UNC\host\share\list.txt`)
		take = []string{`C:\lists\servers.txt`, `D:/lists/servers.txt`}
	}
	for _, p := range refuse {
		if err := a.listPathOK(p); err == nil {
			t.Errorf("%s was taken as a list path", p)
		}
	}
	for _, p := range take {
		if err := a.listPathOK(p); err != nil {
			t.Errorf("%s was refused: %v", p, err)
		}
	}
}

// The page's five read-only reasons in its own words (the join's w9c; the lead's 12:59: each reason a proof row):
// a demo serve (the join's demo door: proof-demodoor), -no-login (proof-instances L), the audit login off (L2), the
// audit login not connected, and no actions door at all, which serve never has (it always builds the door) - so this
// test is that reason's row. Each answers every write 403 with the words before any login is asked: an instance add,
// a source's sweep and edit, a proposal's test (205's merge review, finding 2).
func TestInstancesOffReasons(t *testing.T) {
	login := newAuth(func(context.Context, string) (string, error) { return "h", nil }, false, time.Hour)
	for _, c := range []struct {
		name string
		s    *Server
		want string
	}{
		// as pgvigil demo -serve runs it: no UI login (cmd/pgvigil/demo.go sets no Login), so a reorder that put the
		// -no-login case first would answer this row with the wrong words
		{"demo serve", &Server{log: discardLog(), demo: &demoDoor{}},
			"adding and changing instances writes connection secrets and connects to servers: it needs pgvigil serve with a signed-in user (this is pgvigil demo -serve)"},
		{"-no-login", &Server{log: discardLog()}, "adding and changing instances needs the UI login: this server runs with -no-login"},
		{"no actions door", &Server{log: discardLog(), auth: login}, "adding and changing instances is off on this server: it has no actions door (every change is written through its audit login)"},
		{"the audit login off", &Server{log: discardLog(), auth: login, actions: &Actions{off: "the audit login could not connect"}},
			"adding and changing instances goes through the actions door's audit login, and it is off: the audit login could not connect"},
		{"the audit login not connected", &Server{log: discardLog(), auth: login, actions: &Actions{}},
			"adding and changing instances goes through the actions door's audit login, and it is not connected"},
	} {
		if got := c.s.instancesOff(); got != c.want {
			t.Errorf("%s: instancesOff() = %q, want %q", c.name, got, c.want)
		}
		for _, p := range []struct {
			what, path, body string
			h                func(http.ResponseWriter, *http.Request)
		}{
			{"an instance add", "/api/admin/instances", `{"op":"add","name":"x"}`, c.s.InstancesAdminWrite},
			{"a source sweep", "/api/admin/sources", `{"op":"sweep","name":"x"}`, c.s.SourcesAdminWrite},
			{"a source edit", "/api/admin/sources", `{"op":"edit","name":"x"}`, c.s.SourcesAdminWrite},
			{"a proposal test", "/api/admin/proposals", `{"op":"test","proposal_id":"1"}`, c.s.ProposalsAdminWrite},
		} {
			r := httptest.NewRequest(http.MethodPost, p.path, strings.NewReader(p.body))
			r.Header.Set(loginHeader, "1")
			w := httptest.NewRecorder()
			p.h(w, r)
			if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), c.want) {
				t.Errorf("%s: %s answered %d %q, want 403 with %q", c.name, p.what, w.Code, w.Body.String(), c.want)
			}
		}
	}
}

// TestNoteItems (task 205 D4): a note is keyed by the region it starts with when the read asked that region, else
// 'source'.
func TestNoteItems(t *testing.T) {
	got := noteItems([]string{"af-south-1: not enabled for this account", "us-east-2 cluster c1: no instance (nothing to propose)",
		"ec2:DescribeRegions not granted (UnauthorizedOperation): x", "me-south-1: not reachable (no answer within 20s)"}, []string{"af-south-1", "us-east-2"})
	want := []string{"af-south-1", "us-east-2", "source", "source"}
	for i, w := range want {
		if got[i]["key"] != w {
			t.Fatalf("note %d keyed %q, want %q (%v)", i, got[i]["key"], w, got)
		}
	}
}
