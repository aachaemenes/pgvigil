package reportmail

// The Daily checks mail: the one report mail schedule a setting keeps (migration 0258). pgvigil.yaml's block is
//
//	reports:
//	  daily_checks:
//	    enabled: true
//	    at: "07:00"
//	    tz: America/Los_Angeles
//	    to: [dba@example.org]
//	    as: alice          # the UI user the page is drawn as (a scheduled page is drawn in that user's session)
//	    channel: mail      # an smtp channel of the alerts: block
//
// The block is absent or whole: `enabled` is required when it is there, every other key is required when enabled is
// true, and a key the block does not know stops the command that read it - a typo ('daily_check:', 'enable:') must
// never read as "absent" or "off", which are two different states of the mail (absent: the Daily checks page's own
// control decides; off: the mail is off and the page says the file turned it off).

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// The kept schedule's fixed fields (0258's report_mail_kept_route and report_mail_kept_name say the same).
const (
	KeptDailyChecks  = "daily_checks"
	DailyChecksRoute = "#/checks?w=24h"
	DailyChecksName  = "Daily checks"
	// DailyChecksFileUser is who a write made for pgvigil.yaml's block is logged as
	DailyChecksFileUser = "pgvigil.yaml"
	// DailyChecksKey is the block's place in the file, as the refusals name it
	DailyChecksKey = "reports.daily_checks"
)

// DailyChecks is pgvigil.yaml's reports.daily_checks block.
type DailyChecks struct {
	Enabled *bool    `yaml:"enabled"`
	At      string   `yaml:"at"`
	TZ      string   `yaml:"tz"`
	To      []string `yaml:"to"`
	As      string   `yaml:"as"`
	Channel string   `yaml:"channel"`
	// Post: the webhook channels of the same file's alerts: block the mail's counts are posted to (B20-4); none = no post
	Post []string `yaml:"post"`
}

// dailyKeys are the block's keys in the order the docs list them, each with what its value is (the words of a refusal)
var dailyKeys = []struct{ key, is string }{
	{"enabled", "true or false"},
	{"at", "the hour of the daily mail, HH:MM (one value)"},
	{"tz", "the time zone of at, an IANA name or UTC (one value)"},
	{"to", "a list of mail addresses, as [dba@example.org]"},
	{"as", "the name of a UI user (one value)"},
	{"channel", "the name of an smtp channel of the alerts: block (one value)"},
	{"post", "a list of webhook channel names of the alerts: block, as [team-chat]"},
}

// On says whether the block turns the mail on.
func (d *DailyChecks) On() bool { return d != nil && d.Enabled != nil && *d.Enabled }

// LoadDailyChecks reads pgvigil.yaml's reports.daily_checks: nil when the file has no such block, the checked block
// otherwise. An unknown or repeated key under reports: or under the block, a value of the wrong kind, a block without
// `enabled`, or an enabled block with a key missing or wrong is an error that names the key.
func LoadDailyChecks(path string) (*DailyChecks, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	d, err := ParseDailyChecks(b)
	if err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	return d, nil
}

// ParseDailyChecks is LoadDailyChecks on the file's bytes. The block is read key by key from the file's own nodes, so a
// refusal names the key in plain words with the line it stands on in the file, never the value (the support report
// prints the refusal), and an alias (`to: *dba_list`, its anchor anywhere in the file) or a merge key reads as what it
// stands for.
func ParseDailyChecks(raw []byte) (*DailyChecks, error) {
	var top struct {
		Reports yaml.Node `yaml:"reports"`
	}
	if err := yaml.Unmarshal(raw, &top); err != nil {
		return nil, err
	}
	reports := aliased(&top.Reports)
	if reports.Kind == 0 || isNull(reports) {
		return nil, nil
	}
	if reports.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("reports: is a block of keys (daily_checks) (line %d of the file)", top.Reports.Line)
	}
	pairs, err := blockPairs(reports, "reports", []string{KeptDailyChecks})
	if err != nil {
		return nil, err
	}
	at, there := pairs[KeptDailyChecks]
	if !there || isNull(aliased(at)) {
		return nil, nil
	}
	block := aliased(at)
	keys := make([]string, len(dailyKeys))
	for i, k := range dailyKeys {
		keys[i] = k.key
	}
	if block.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("%s: is a block of keys (%s) (line %d of the file)", DailyChecksKey, strings.Join(keys, ", "), at.Line)
	}
	if pairs, err = blockPairs(block, DailyChecksKey, keys); err != nil {
		return nil, err
	}
	d := &DailyChecks{}
	for _, k := range dailyKeys {
		v, there := pairs[k.key]
		if !there || isNull(aliased(v)) {
			continue // not written, or a key with nothing after it: Check names it as required
		}
		good := true
		switch k.key {
		case "enabled":
			var on bool
			if good = v.Decode(&on) == nil; good {
				d.Enabled = &on
			}
		case "at":
			d.At, good = oneValue(v)
		case "tz":
			d.TZ, good = oneValue(v)
		case "to":
			d.To, good = valueList(v)
		case "as":
			d.As, good = oneValue(v)
		case "channel":
			d.Channel, good = oneValue(v)
		case "post":
			d.Post, good = valueList(v)
		}
		if !good {
			return nil, fmt.Errorf("%s: %s is %s (line %d of the file)", DailyChecksKey, k.key, k.is, v.Line)
		}
	}
	if err := d.Check(); err != nil {
		return nil, err
	}
	if err := d.checkPost(raw); err != nil {
		return nil, err
	}
	return d, nil
}

// postNameRE is a channel's name as the alerts: block takes it (internal/alerts nameRE)
var postNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,62}$`)

// checkPost: each name of an enabled block's post: list is a webhook channel of the same file's alerts: block (the
// channel's own keys are the alerts package's to check; here only its name and kind are read). An entry that cannot
// be a channel's name is refused by its place, never printed: a webhook's URL pasted for its channel would otherwise
// reach serve's log and the support report with its secret (review-26 go2 S2).
func (d *DailyChecks) checkPost(raw []byte) error {
	if !d.On() || len(d.Post) == 0 {
		return nil
	}
	var file struct {
		Alerts []struct {
			Name string `yaml:"name"`
			Kind string `yaml:"kind"`
		} `yaml:"alerts"`
	}
	if err := yaml.Unmarshal(raw, &file); err != nil {
		return fmt.Errorf("%s: post: the alerts: block cannot be read: %w", DailyChecksKey, err)
	}
	kinds := map[string]string{}
	for _, c := range file.Alerts {
		kinds[strings.TrimSpace(c.Name)] = c.Kind
	}
	for i, name := range d.Post {
		n := strings.TrimSpace(name)
		if !postNameRE.MatchString(n) {
			return fmt.Errorf("%s: post: entry %d of the list is not a webhook channel of the alerts: block", DailyChecksKey, i+1)
		}
		if kinds[n] != "webhook" {
			return fmt.Errorf("%s: post: %s is not a webhook channel of the alerts: block", DailyChecksKey, n)
		}
	}
	return nil
}

// aliased is the node an alias stands for (the node itself when it is none)
func aliased(n *yaml.Node) *yaml.Node {
	for i := 0; n != nil && n.Kind == yaml.AliasNode && n.Alias != nil && i < 16; i++ {
		n = n.Alias
	}
	return n
}

func isNull(n *yaml.Node) bool { return n.Kind == yaml.ScalarNode && n.Tag == "!!null" }

// blockPairs is a block's keys with their values: its own pairs, and behind them what a merge key (<<) brings in (a
// key of the block's own goes first, then the merged blocks in their order). A key the block does not know, or one
// written twice, is refused by its name with the line it stands on in the file.
func blockPairs(n *yaml.Node, where string, known []string) (map[string]*yaml.Node, error) {
	out := map[string]*yaml.Node{}
	var merges []*yaml.Node
	for i := 0; i+1 < len(n.Content); i += 2 {
		k, v := n.Content[i], n.Content[i+1]
		if k.Kind == yaml.ScalarNode && k.Value == "<<" && (k.Tag == "" || k.Tag == "!" || k.Tag == "!!merge") {
			merges = append(merges, v)
			continue
		}
		is := false
		for _, name := range known {
			is = is || k.Kind == yaml.ScalarNode && k.Value == name
		}
		if !is {
			name := "a key that is no plain word"
			if k.Kind == yaml.ScalarNode {
				name = k.Value
			}
			return nil, fmt.Errorf("%s: %s is not a key of the block (line %d of the file); its keys: %s", where, name, k.Line, strings.Join(known, ", "))
		}
		if _, twice := out[k.Value]; twice {
			return nil, fmt.Errorf("%s: %s is written twice (line %d of the file)", where, k.Value, k.Line)
		}
		out[k.Value] = v
	}
	for _, m := range merges {
		blocks := []*yaml.Node{m}
		if aliased(m).Kind == yaml.SequenceNode {
			blocks = aliased(m).Content
		}
		for _, b := range blocks {
			if aliased(b).Kind != yaml.MappingNode {
				return nil, fmt.Errorf("%s: << merges a block of keys (line %d of the file)", where, b.Line)
			}
			more, err := blockPairs(aliased(b), where, known)
			if err != nil {
				return nil, err
			}
			for key, v := range more {
				if _, own := out[key]; !own {
					out[key] = v
				}
			}
		}
	}
	return out, nil
}

// oneValue is a key's one value as the file writes it (07:00 and "07:00" are the same text), false for a list or a block
func oneValue(v *yaml.Node) (string, bool) {
	v = aliased(v)
	if v.Kind != yaml.ScalarNode {
		return "", false
	}
	return v.Value, true
}

// valueList is a key's list of values, false for anything but a list of single values
func valueList(v *yaml.Node) ([]string, bool) {
	v = aliased(v)
	if v.Kind != yaml.SequenceNode {
		return nil, false
	}
	var out []string
	for _, c := range v.Content {
		c = aliased(c)
		if c.Kind != yaml.ScalarNode {
			return nil, false
		}
		if !isNull(c) {
			out = append(out, c.Value)
		}
	}
	return out, true
}

// Check says why the block cannot be used, nil when it can. An off block is checked for `enabled` alone: its other
// keys may stay in the file for the day it is turned on again.
func (d *DailyChecks) Check() error {
	if d.Enabled == nil {
		return fmt.Errorf("%s: enabled is required (true or false): a block without it would be neither on nor off", DailyChecksKey)
	}
	if !*d.Enabled {
		return nil
	}
	if strings.TrimSpace(d.At) == "" {
		return fmt.Errorf("%s: at is required (the hour of the daily mail, HH:MM)", DailyChecksKey)
	}
	if _, err := d.Cron(); err != nil {
		return fmt.Errorf("%s: at: %w", DailyChecksKey, err)
	}
	if strings.TrimSpace(d.TZ) == "" {
		return fmt.Errorf("%s: tz is required (the time zone of at: an IANA name such as America/Los_Angeles, or UTC)", DailyChecksKey)
	}
	if _, err := Zone(d.TZ); err != nil {
		return fmt.Errorf("%s: tz: %w", DailyChecksKey, err)
	}
	if len(d.To) == 0 {
		return fmt.Errorf("%s: to is required (one to %d mail addresses)", DailyChecksKey, MaxRecipients)
	}
	// the refusals name the entry by its place, never its value: the support report prints them (pgvigil report)
	for i, a := range d.To {
		if strings.TrimSpace(a) == "" {
			continue
		}
		if _, err := Recipients([]string{a}); err != nil {
			return fmt.Errorf("%s: to: address %d of the list is not one mail address with a domain", DailyChecksKey, i+1)
		}
	}
	if _, err := Recipients(d.To); err != nil {
		return fmt.Errorf("%s: to: %w", DailyChecksKey, err) // the count only: at least one, at most MaxRecipients
	}
	if strings.TrimSpace(d.As) == "" {
		return fmt.Errorf("%s: as is required (the UI user the page is drawn as: a scheduled page is drawn in that user's session)", DailyChecksKey)
	}
	ch := strings.TrimSpace(d.Channel)
	if ch == "" {
		return fmt.Errorf("%s: channel is required (an smtp channel of the alerts: block)", DailyChecksKey)
	}
	if strings.HasPrefix(ch, "contact-") {
		return fmt.Errorf("%s: channel names an application contact's route (contact-...): the mail goes through an smtp channel of the alerts: block", DailyChecksKey)
	}
	return nil
}

// Cron is the block's daily line ('M H * * *').
func (d *DailyChecks) Cron() (string, error) { return CronFor("daily", d.At, nil, "") }

// KeptRequest is one keep of the kept schedule: the block's fields, or the Daily checks page's dialog.
type KeptRequest struct {
	At, TZ, As, Channel string
	To                  []string
	AttachXLSX          bool
	// Post: the webhook channels the counts are posted to (B20-4); the repository checks each is one it records
	Post []string
}

// Request is the block as a keep.
func (d *DailyChecks) Request() KeptRequest {
	return KeptRequest{At: d.At, TZ: strings.TrimSpace(d.TZ), As: strings.ToLower(strings.TrimSpace(d.As)), Channel: strings.TrimSpace(d.Channel), To: d.To, AttachXLSX: true, Post: d.Post}
}

// Payload is the keep's payload for import_report_mail_kept (without op, by, ui_user and client, the caller's) and
// its key: the payload without the next send, so two keeps of the same setting compare equal whenever they are made.
func (k KeptRequest) Payload(now time.Time) (map[string]any, string, error) {
	line, err := CronFor("daily", k.At, nil, "")
	if err != nil {
		return nil, "", err
	}
	if err := CheckCron(line, k.TZ, now); err != nil {
		return nil, "", err
	}
	rcpt, err := Recipients(k.To)
	if err != nil {
		return nil, "", err
	}
	if strings.TrimSpace(k.As) == "" {
		return nil, "", errors.New("the Daily checks mail needs the UI user its page is drawn as")
	}
	if strings.TrimSpace(k.Channel) == "" {
		return nil, "", errors.New("the Daily checks mail needs its smtp channel")
	}
	next, err := NextSend(line, k.TZ, now)
	if err != nil {
		return nil, "", err
	}
	as := strings.ToLower(strings.TrimSpace(k.As))
	post := []string{}
	for _, p := range k.Post {
		if p = strings.TrimSpace(p); p != "" {
			post = append(post, p)
		}
	}
	key := strings.Join([]string{line, k.TZ, as, strings.TrimSpace(k.Channel), strings.Join(rcpt, ","), fmt.Sprint(k.AttachXLSX), strings.Join(post, ",")}, "|")
	return map[string]any{"kept_as": KeptDailyChecks, "as": as, "recipients": rcpt, "channel": strings.TrimSpace(k.Channel), "cron": line,
		"timezone": k.TZ, "attach_xlsx": k.AttachXLSX, "next_at": next.Format(time.RFC3339), "post_channels": post}, key, nil
}

// AtOfCron is the HH:MM of a daily line ('5 7 * * *' is 07:05), "" for any other line.
func AtOfCron(line string) string {
	f := strings.Fields(line)
	if len(f) != 5 || f[2] != "*" || f[3] != "*" || f[4] != "*" {
		return ""
	}
	var h, m int
	if _, err := fmt.Sscanf(f[1]+" "+f[0], "%d %d", &h, &m); err != nil || h < 0 || h > 23 || m < 0 || m > 59 {
		return ""
	}
	return fmt.Sprintf("%02d:%02d", h, m)
}
