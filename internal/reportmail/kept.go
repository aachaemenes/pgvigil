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
	"bytes"
	"errors"
	"fmt"
	"os"
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
}

// reportsBlock is pgvigil.yaml's reports: block: the keys it knows, read strictly
type reportsBlock struct {
	DailyChecks *DailyChecks `yaml:"daily_checks"`
}

// On says whether the block turns the mail on.
func (d *DailyChecks) On() bool { return d != nil && d.Enabled != nil && *d.Enabled }

// LoadDailyChecks reads pgvigil.yaml's reports.daily_checks: nil when the file has no such block, the checked block
// otherwise. An unknown key under reports: or under the block, a block without `enabled`, or an enabled block with a
// key missing or wrong is an error that names the key.
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

// ParseDailyChecks is LoadDailyChecks on the file's bytes.
func ParseDailyChecks(raw []byte) (*DailyChecks, error) {
	var top struct {
		Reports yaml.Node `yaml:"reports"`
	}
	if err := yaml.Unmarshal(raw, &top); err != nil {
		return nil, err
	}
	if top.Reports.Kind == 0 || top.Reports.Tag == "!!null" {
		return nil, nil
	}
	if top.Reports.Kind != yaml.MappingNode {
		return nil, errors.New("reports: is a block of keys (daily_checks)")
	}
	// the block again through a strict decoder: yaml.Node.Decode takes any key, a Decoder with KnownFields does not
	sub, err := yaml.Marshal(&top.Reports)
	if err != nil {
		return nil, fmt.Errorf("reports: %w", err)
	}
	var rb reportsBlock
	dec := yaml.NewDecoder(bytes.NewReader(sub))
	dec.KnownFields(true)
	if err := dec.Decode(&rb); err != nil {
		return nil, fmt.Errorf("reports: %s (the keys are reports.daily_checks: enabled, at, tz, to, as, channel)", strings.TrimPrefix(err.Error(), "yaml: "))
	}
	if rb.DailyChecks == nil {
		return nil, nil
	}
	if err := rb.DailyChecks.Check(); err != nil {
		return nil, err
	}
	return rb.DailyChecks, nil
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
	if _, err := Recipients(d.To); err != nil {
		return fmt.Errorf("%s: to: %w", DailyChecksKey, err)
	}
	if strings.TrimSpace(d.As) == "" {
		return fmt.Errorf("%s: as is required (the UI user the page is drawn as: a scheduled page is drawn in that user's session)", DailyChecksKey)
	}
	ch := strings.TrimSpace(d.Channel)
	if ch == "" {
		return fmt.Errorf("%s: channel is required (an smtp channel of the alerts: block)", DailyChecksKey)
	}
	if strings.HasPrefix(ch, "contact-") {
		return fmt.Errorf("%s: channel %s is an application contact's route: the mail goes through an smtp channel of the alerts: block", DailyChecksKey, ch)
	}
	return nil
}

// Cron is the block's daily line ('MM HH * * *').
func (d *DailyChecks) Cron() (string, error) { return CronFor("daily", d.At, nil, "") }

// KeptRequest is one keep of the kept schedule: the block's fields, or the Daily checks page's dialog.
type KeptRequest struct {
	At, TZ, As, Channel string
	To                  []string
	AttachXLSX          bool
}

// Request is the block as a keep.
func (d *DailyChecks) Request() KeptRequest {
	return KeptRequest{At: d.At, TZ: strings.TrimSpace(d.TZ), As: strings.ToLower(strings.TrimSpace(d.As)), Channel: strings.TrimSpace(d.Channel), To: d.To, AttachXLSX: true}
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
	key := strings.Join([]string{line, k.TZ, as, strings.TrimSpace(k.Channel), strings.Join(rcpt, ","), fmt.Sprint(k.AttachXLSX)}, "|")
	return map[string]any{"kept_as": KeptDailyChecks, "as": as, "recipients": rcpt, "channel": strings.TrimSpace(k.Channel), "cron": line,
		"timezone": k.TZ, "attach_xlsx": k.AttachXLSX, "next_at": next.Format(time.RFC3339)}, key, nil
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
