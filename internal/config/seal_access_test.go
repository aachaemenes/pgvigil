//go:build !windows

package config

import "testing"

// TestAccountReachesASealL9 (rn-l9 S6): the service's account reaches a sealed path as its owner, or through the group
// when the group may read - never through the bits for others, which a seal never sets: a configuration the service
// reads through its others bits (root:root 0644) leaves the seal refused, not silently unreadable.
func TestAccountReachesASealL9(t *testing.T) {
	for _, c := range []struct {
		uid        string
		gids       []string
		fu, fg     uint32
		groupReads bool
		want       bool
	}{
		{"990", []string{"990"}, 990, 990, false, true},       // the service owns it
		{"990", []string{"990", "991"}, 0, 991, true, true},   // root:<the service's group> 0640: the installer's form
		{"990", []string{"990", "991"}, 0, 991, false, false}, // the group may not read
		{"990", []string{"990"}, 0, 0, true, false},           // root:root 0640: the service is no member
		{"990", nil, 0, 0, false, false},                      // root:root 0600
	} {
		if got := accountReaches(c.uid, c.gids, c.fu, c.fg, c.groupReads); got != c.want {
			t.Errorf("accountReaches(%s, %v, %d:%d, group reads %v) = %v, want %v", c.uid, c.gids, c.fu, c.fg, c.groupReads, got, c.want)
		}
	}
}
