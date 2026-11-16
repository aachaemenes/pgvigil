package reportmail

import (
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

// The Daily checks mail's post (B20-4): with each mail of the kept schedule that is sent, its counts, the worst three
// instances and the page's link go to the webhook channels its setting names (once a day; a failed mail posts nothing).
// The numbers are the drawn page's (web/src/checksorder.ts dailyPost, carried by the render), never read again.

// DailyPost is what the drawn Daily checks page counted.
type DailyPost struct {
	Instances int          `json:"instances"`
	Critical  int          `json:"critical"`
	Warnings  int          `json:"warnings"`
	Worst     []DailyWorst `json:"worst"`
}

// DailyWorst is one of the worst three instances, in the page's order.
type DailyWorst struct {
	Name     string `json:"name"`
	Critical int    `json:"critical"`
	Warnings int    `json:"warnings"`
}

// PostKind is the json format's kind of the post.
const PostKind = "daily checks"

// maxPostName bounds an instance's name in a post (instances.name is far shorter in practice).
const maxPostName = 200

// Check says why numbers a page sent back cannot be posted (they come from a browser: bounded before they are queued).
func (p DailyPost) Check() error {
	if p.Instances < 0 || p.Critical < 0 || p.Warnings < 0 {
		return errors.New("the post's counts are not counts")
	}
	if len(p.Worst) > 3 {
		return fmt.Errorf("the post names %d instances: at most 3", len(p.Worst))
	}
	for i, w := range p.Worst {
		switch {
		case strings.TrimSpace(w.Name) == "":
			return fmt.Errorf("the post's instance %d has no name", i+1)
		case utf8.RuneCountInString(w.Name) > maxPostName:
			return fmt.Errorf("the post's instance %d has a name over %d characters", i+1, maxPostName)
		case w.Critical < 0 || w.Warnings < 0:
			return errors.New("the post's counts are not counts")
		}
	}
	return nil
}

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}

// Post is the post of day (the turn's date in the schedule's zone): the counts in the title, one line per worst
// instance, the page's route for the link.
func (p DailyPost) Post(day string) alerts.Post {
	title := fmt.Sprintf("%s %s: %s, %s on %s", DailyChecksName, day, plural(p.Critical, "critical", "critical"),
		plural(p.Warnings, "warning", "warnings"), plural(p.Instances, "instance", "instances"))
	if p.Critical == 0 && p.Warnings == 0 {
		title = fmt.Sprintf("%s %s: all checks pass on %s", DailyChecksName, day, plural(p.Instances, "instance", "instances"))
	}
	var lines []string
	for i, w := range p.Worst {
		var parts []string
		if w.Critical > 0 {
			parts = append(parts, plural(w.Critical, "critical", "critical"))
		}
		if w.Warnings > 0 {
			parts = append(parts, plural(w.Warnings, "warning", "warnings"))
		}
		lines = append(lines, fmt.Sprintf("%d. %s: %s", i+1, w.Name, strings.Join(parts, ", ")))
	}
	worst := p.Worst
	if worst == nil {
		worst = []DailyWorst{}
	}
	return alerts.Post{Kind: PostKind, Title: title, Lines: lines, Route: DailyChecksRoute,
		Fields: map[string]any{"instances": p.Instances, "critical": p.Critical, "warnings": p.Warnings, "worst": worst, "day": day}}
}
