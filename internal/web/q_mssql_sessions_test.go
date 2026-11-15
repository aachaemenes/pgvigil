package web

import (
	"testing"
	"time"
)

// TestTopWindow: the top's reach is the newest historyMaxWindow of the window, counted back from its end or now,
// whichever is earlier; a window inside the reach is kept whole.
func TestTopWindow(t *testing.T) {
	now := time.Now()
	day := 24 * time.Hour
	for _, c := range []struct {
		name          string
		from, to      time.Time
		wantFrom      time.Time
		wantCut       bool
		endIsNowClose bool
	}{
		{"an hour: kept", now.Add(-2 * time.Hour), now.Add(-time.Hour), now.Add(-2 * time.Hour), false, false},
		{"seven days exactly: kept", now.Add(-8 * day), now.Add(-day), now.Add(-8 * day), false, false},
		{"thirty days: the newest seven", now.Add(-31 * day), now.Add(-day), now.Add(-8 * day), true, false},
		{"an end past now: counted back from now", now.Add(-30 * day), now.Add(10 * day), time.Time{}, true, true},
	} {
		gotFrom, gotEnd, cut := topWindow(c.from, c.to)
		if cut != c.wantCut {
			t.Errorf("%s: cut %v, want %v", c.name, cut, c.wantCut)
		}
		if c.endIsNowClose {
			if d := time.Since(gotEnd); d < 0 || d > time.Minute {
				t.Errorf("%s: end %v is not now", c.name, gotEnd)
			}
			if gotEnd.Sub(gotFrom) != historyMaxWindow {
				t.Errorf("%s: reach %v, want %v", c.name, gotEnd.Sub(gotFrom), historyMaxWindow)
			}
			continue
		}
		if !gotFrom.Equal(c.wantFrom) || !gotEnd.Equal(c.to) {
			t.Errorf("%s: %v .. %v, want %v .. %v", c.name, gotFrom, gotEnd, c.wantFrom, c.to)
		}
	}
}
