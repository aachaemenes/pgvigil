package mssql

import (
	"strings"
	"testing"
)

// B9c (B9-13): what the read login saw of a job decides whether an enable or a disable is sent at all - a multiserver
// job (its master server owns it; SQLAgentOperatorRole may not change one) and a job already in the state asked are
// refused with words and nothing is sent; Start and Stop are not judged here.
func TestJobToggleRefusal(t *testing.T) {
	on, off := true, false
	cases := []struct {
		name string
		k    ActionKind
		t    Target
		want string // "" = may be sent
	}{
		{"enable a disabled job", ActionJobEnable, Target{JobName: "n", JobEnabled: &off}, ""},
		{"disable an enabled job", ActionJobDisable, Target{JobName: "n", JobEnabled: &on}, ""},
		{"enable an enabled job", ActionJobEnable, Target{JobName: "n", JobEnabled: &on}, "already enabled"},
		{"disable a disabled job", ActionJobDisable, Target{JobName: "n", JobEnabled: &off}, "already disabled"},
		{"a multiserver job", ActionJobDisable, Target{JobName: "n", JobEnabled: &on, JobMultiserver: true}, "multiserver job"},
		{"the state not read", ActionJobEnable, Target{JobName: "n"}, "not read"},
		{"start is not judged here", ActionJobStart, Target{JobName: "n", JobEnabled: &off, JobMultiserver: true}, ""},
	}
	for _, c := range cases {
		got := toggleRefusal(c.k, c.t)
		if (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%s: toggleRefusal = %q, want %q", c.name, got, c.want)
		}
	}
}
