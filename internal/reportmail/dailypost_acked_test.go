package reportmail

import (
	"encoding/json"
	"testing"
)

// DAILY-SQL (review-28 code S2, the lead 11-16 20:01): a day whose every failing row is acknowledged posts 'no open
// check ... acknowledged', never 'all checks pass'; the count rides in the post's fields.
func TestDailyPostAcknowledged(t *testing.T) {
	if z := (DailyPost{Instances: 5, Acknowledged: 2}).Post("2026-11-16"); z.Title != "Daily checks 2026-11-16: no open check on 5 instances; 2 acknowledged" ||
		len(z.Lines) != 0 || z.Fields["acknowledged"] != 2 {
		t.Errorf("every row acknowledged: %+v", z)
	}
	if one := (DailyPost{Instances: 1, Acknowledged: 1}).Post("2026-11-16"); one.Title != "Daily checks 2026-11-16: no open check on 1 instance; 1 acknowledged" {
		t.Errorf("one instance: %q", one.Title)
	}
	if z := (DailyPost{Instances: 5}).Post("2026-11-16"); z.Title != "Daily checks 2026-11-16: all checks pass on 5 instances" || z.Fields["acknowledged"] != 0 {
		t.Errorf("a green day: %+v", z)
	}
	if c := (DailyPost{Instances: 5, Critical: 1, Acknowledged: 3, Worst: []DailyWorst{{"a", 1, 0}}}).Post("2026-11-16"); c.Title != "Daily checks 2026-11-16: 1 critical, 0 warnings on 5 instances" {
		t.Errorf("open rows and acknowledged ones: the counts title stays: %q", c.Title)
	}
	var p DailyPost
	if err := json.Unmarshal([]byte(`{"instances": 2, "acknowledged": -1}`), &p); err != nil || p.Check() == nil || p.Check().Error() != "the post's counts are not counts" {
		t.Errorf("a negative acknowledged count: %v %v", err, p.Check())
	}
}
