package web

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestViewPayload: a page view keeps its page's own parameters (the instance, the tag, the view and the range dropped;
// keep_range keeps the range apart in state.range); only the store's fields pass; a delete takes view_id and version.
func TestViewPayload(t *testing.T) {
	for _, c := range []struct {
		name, op, in, want string
	}{
		{"page view: i, ti, tag, view, at and the range dropped", "save",
			`{"kind":"page","page":"instance:slowqueries","name":"x","ui_user":"mallory","shared_ok":true,"state":{"params":{"i":"7","ti":"8","tag":"env:x","view":"3","at":"2026-11-15T10:00:00Z","w":"24h","ms":"5000"},"layouts":[]}}`,
			`{"kind":"page","name":"x","page":"instance:slowqueries","state":{"layouts":[],"params":{"ms":"5000"}}}`},
		{"keep_range keeps the range apart", "save",
			`{"kind":"page","page":"root:fleet","name":"x","keep_range":true,"state":{"params":{"from":"a","to":"b","i":"1"}}}`,
			`{"kind":"page","name":"x","page":"root:fleet","state":{"params":{},"range":{"from":"a","to":"b"}}}`},
		{"a client's own range key is not kept without keep_range", "save",
			`{"kind":"page","page":"root:fleet","name":"x","state":{"params":{},"range":{"w":"1h"}}}`,
			`{"kind":"page","name":"x","page":"root:fleet","state":{"params":{}}}`},
		{"a dashboard's state is the store's to check", "save",
			`{"kind":"dashboard","name":"d","version":3,"view_id":9,"state":{"panels":[{"i":1}]}}`,
			`{"kind":"dashboard","name":"d","state":{"panels":[{"i":1}]},"version":3,"view_id":9}`},
		{"a delete takes view_id and version only", "delete",
			`{"view_id":9,"version":2,"name":"x","shared_ok":true}`,
			`{"version":2,"view_id":9}`},
		{"a state that is not an object passes to the store, which refuses it", "save",
			`{"kind":"page","page":"root:fleet","name":"x","state":[1]}`,
			`{"kind":"page","name":"x","page":"root:fleet","state":[1]}`},
	} {
		got, err := viewPayload(c.op, []byte(c.in))
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		b, _ := json.Marshal(got)
		if string(b) != c.want {
			t.Errorf("%s:\n got %s\nwant %s", c.name, b, c.want)
		}
	}
	if _, err := viewPayload("save", []byte(`[1]`)); err == nil {
		t.Error("a body that is not an object was taken")
	}
}

// TestViewsOff: saving is off, each with its reason, on demo serve, under -no-login and without the actions door's
// audit login.
func TestViewsOff(t *testing.T) {
	for _, c := range []struct {
		s    *Server
		want string
	}{
		{&Server{demo: &demoDoor{}}, "demo -serve"},
		{&Server{}, "-no-login"},
		{&Server{auth: &authState{}}, "no actions door"},
		{&Server{auth: &authState{}, actions: &Actions{off: "the log login may not write"}}, "it is off: the log login may not write"},
		{&Server{auth: &authState{}, actions: &Actions{}}, "not connected"},
	} {
		if got := c.s.viewsOff(); !strings.Contains(got, c.want) {
			t.Errorf("viewsOff() = %q, want it to say %q", got, c.want)
		}
	}
}

// TestViewEditors: the names are matched case-blind; none named = nobody.
func TestViewEditors(t *testing.T) {
	s := &Server{}
	s.SetViewEditors(nil)
	if viewEditor("ann") {
		t.Error("nobody named, yet ann may write shared views")
	}
	s.SetViewEditors([]string{" Ann ", ""})
	if !viewEditor("ann") || !viewEditor("ANN") || viewEditor("bob") {
		t.Error("the shared editors are not matched case-blind by name")
	}
	s.SetViewEditors(nil)
}
