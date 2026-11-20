// Package alerts sends the repository's findings to the channels the configuration names (task 60): an SMTP
// relay, a webhook (a Teams or Slack card, or a generic JSON body) and a file drop (one JSON file per alert, the
// channel of an air-gapped site). Nothing is sent unless the configuration's alerts: list names a channel, and a
// channel sends only to its configured destination: a webhook's redirect is refused, never followed; SMTP talks to
// the configured host and port only, over Go's crypto/tls.
//
// The alerts: block sits in pgvigil.yaml beside the rest; config.Load ignores it and this package reads it
// (LoadFile), so a file without the block runs as before with every channel off. The sender connects to the repository
// as alerts_dsn (a login IN ROLE pgvigil_alerter, migration 0059; default the repository's dsn): the collector's own
// login may not read the findings.
//
//	alerts_dsn: env:PGVIGIL_ALERTS_DSN
//	alerts:
//	  - name: dba-mail               # [a-z0-9][a-z0-9_.-]*, unique
//	    kind: smtp                   # smtp | webhook | file | pagerduty | opsgenie | pushover | zabbix | azuremonitor
//	    min_severity: warning        # info | warning (default) | critical
//	    instances: [erp01]           # optional; instances: and tags: empty = every instance
//	    tags: [env:prod]             # optional; a tag in its written form (prod, env:prod)
//	    quiet_hours: "22:00-07:00"   # optional: nothing is sent inside it; what is owed goes out when it ends
//	    timezone: America/Chicago    # the quiet hours' zone (default UTC)
//	    repeat: 24h                  # a standing finding is sent again after this (default 24h; disabled = once)
//	    recovery: true               # a message when the finding clears (default true)
//	    clear_after: 10m             # a finding gone this long is resolved (default 10m; 0 = at the first pass)
//	    smtp: {host: relay.example.org, port: 587, tls: starttls, username: env:U, password: file:/p, from: a@b, to: [c@d]}
//	    webhook: {url: env:TEAMS_URL, format: teams}   # teams | slack | discord | googlechat | json; the URL through env: or file: only
//	    file: {dir: /var/spool/pgvigil/alerts}
//	    pagerduty: {routing_key: env:PD_KEY}            # Events API v2; one incident per finding, resolved when it clears
//	    pushover: {token: env:PO_TOKEN, user: env:PO_USER}   # task B24k: one phone notification per alert (pushover.go)
//	    zabbix: {server: zbx.example.org, host: pgvigil, tls_ca: /ca.pem, tls_cert: /c.crt, tls_key: /c.key}   # B24k (zabbix.go)
//	    azuremonitor: {endpoint: https://..., dcr_id: dcr-..., stream: Custom-..., tenant: ..., client_id: ..., client_secret: env:S}   # B24k
//
// Each pass (every minute inside `pgvigil run`, once for `pgvigil alerts`) records the channels, stamps the open alerts
// whose finding is gone (pgvigil.alert_mark), asks the repository what is owed (pgvigil.alert_due: firing, escalated,
// repeat, resolved, cleared), sends it per channel and records every attempt (pgvigil.alert_record). A failed send
// moves nothing: the next pass owes the same alerts, and the loop waits longer before trying a failing channel again
// (1, 2, 4 ... 30 minutes). Delivery is at least once: a send whose record then fails is sent again.
//
// The alert rules (migration 0085: a charted metric above or below a value for n minutes, per instance, tag or the
// fleet) ride the same pass: before it asks what is owed, the pass has the repository judge every rule in force
// (pgvigil.alert_rules_run) and a firing rule is then a finding of source 'alert rule' like any other, so the channels,
// repeats, recoveries, quiet hours, mutes and acknowledgements above apply to it unchanged. With no channel the pass
// judges nothing (nothing would be sent); a rule evaluation that fails, or runs past rulesTimeout on the server, is
// reported in the pass's summary line and the findings still go out.
//
// Task 151 (K07): the Opsgenie kind (opsgenie.go: one alert per finding under its alias, closed when it clears, also
// when it is cleared without a fix, as PagerDuty's); the webhook formats discord and googlechat (a message cut to the
// destination's text limit by packing fewer alerts in it, never by cutting one); per-channel templates (templates.go:
// a subject and a line for firing, escalated, repeat and resolved, with {placeholders} checked at load); max_per_hour
// (a send cap: what is over it is held, logged as outcome 'capped', and owed again by the next pass); a Send test asked
// from the Alerts page (tests.go: the request is a row through an import_* door, the next pass sends it); and
// alerts_base_url, the UI's address, so every alert line carries the address of its own page (#/alert?k=<finding key>).
//
//	alerts_base_url: https://pgvigil.example.org     # optional; no address = no link in the messages
//	  - name: ops
//	    kind: opsgenie
//	    opsgenie: {api_key: env:PGVIGIL_OG_KEY}         # url defaults to https://api.opsgenie.com (EU: https://api.eu.opsgenie.com)
//	    max_per_hour: 30                                # optional; 0 = no cap
//	    templates: {subject: {firing: "{severity}: {setting} on {instance}"}, line: {resolved: "OK again: {instance} {setting}"}}
package alerts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"gopkg.in/yaml.v3"

	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/textnow"
)

// Channel is one entry of the alerts: list.
type Channel struct {
	Name        string           `yaml:"name"`
	Kind        string           `yaml:"kind"`
	MinSeverity string           `yaml:"min_severity"`
	Instances   []string         `yaml:"instances"`
	Tags        []string         `yaml:"tags"`
	QuietHours  string           `yaml:"quiet_hours"`
	Timezone    string           `yaml:"timezone"`
	Repeat      *config.Duration `yaml:"repeat"`
	Recovery    *bool            `yaml:"recovery"`
	ClearAfter  *config.Duration `yaml:"clear_after"`
	SMTP        *SMTP            `yaml:"smtp"`
	Webhook     *Webhook         `yaml:"webhook"`
	File        *FileDrop        `yaml:"file"`
	PagerDuty   *PagerDuty       `yaml:"pagerduty"`
	Opsgenie    *Opsgenie        `yaml:"opsgenie"`
	Pushover    *Pushover        `yaml:"pushover"` // task B24k (pushover.go)
	Zabbix      *Zabbix          `yaml:"zabbix"`   // task B24k (zabbix.go)
	// AzureMonitor is task B24k's Logs Ingestion API channel (azuremonitor.go).
	AzureMonitor *AzureMonitor `yaml:"azuremonitor"`
	// task 403b K2 (slack.go): the Slack bot, a thread per alert
	Slack *SlackBot `yaml:"slack"`
	// MaxPerHour caps the alerts the channel sends in any hour (0 = no cap): what is over it is held, logged as
	// outcome 'capped', and sent by a later pass once the hour allows.
	MaxPerHour int        `yaml:"max_per_hour"`
	Templates  *Templates `yaml:"templates"`
	// DigestHour, when set (0-23 in the channel's timezone), sends the channel one message a day at that hour with the
	// alerts a digest window held on it (0154; digest.go); a route channel takes its base's (routes.go's copy).
	DigestHour *int `yaml:"digest_hour"`
	// Checks, when set, limits the channel to the findings of these checks: a finding's source or setting, compared
	// case-insensitively (SQLMonitor A31: backups to one team, blocking to another; the mutes' check match, 0073).
	Checks []string `yaml:"checks"`

	quiet  *quiet
	loc    *time.Location
	sender sender
	tpl    *compiled // Templates, checked
	base   string    // alerts_base_url, "" = no link
}

// maxChecks bounds a channel's checks: list.
const maxChecks = 50

// maxPerHourLimit bounds max_per_hour (a typing slip of 300000 is refused, not taken as no cap).
const maxPerHourLimit = 100000

// incidentKind says whether a channel keeps an incident per finding at the destination (PagerDuty, Opsgenie): such a
// channel is sent a finding cleared without a fix, or its incident would stay open for good.
func incidentKind(kind string) bool { return kind == "pagerduty" || kind == "opsgenie" }

// DefaultRepeat is how long a standing finding waits before it is sent again.
const DefaultRepeat = 24 * time.Hour

// RepeatEvery returns the repeat interval; 0 = never again.
func (c *Channel) RepeatEvery() time.Duration {
	if c.Repeat == nil {
		return DefaultRepeat
	}
	return c.Repeat.Duration
}

// DefaultClearAfter is how long a finding must stay gone before its alert is resolved: a collection gap or a finding
// that flickers at a time window's edge does not send a recovery and a new alert a minute later.
const DefaultClearAfter = 10 * time.Minute

// ClearAfterEvery returns the clear delay.
func (c *Channel) ClearAfterEvery() time.Duration {
	if c.ClearAfter == nil {
		return DefaultClearAfter
	}
	return c.ClearAfter.Duration
}

// SendsRecovery says whether a cleared finding gets a message.
func (c *Channel) SendsRecovery() bool { return c.Recovery == nil || *c.Recovery }

// Destination is the channel's destination as stored and shown (a webhook's scheme and host only: its path holds the
// token).
func (c *Channel) Destination() string {
	if c.sender == nil {
		return ""
	}
	return c.sender.destination()
}

// Settings is what the configuration file says about alerts: the channels, the sender's login and the UI's address.
type Settings struct {
	DSNRaw     string    `yaml:"alerts_dsn"`
	Channels   []Channel `yaml:"alerts"`
	BaseURLRaw string    `yaml:"alerts_base_url"`
	// task 403b K5 (slackdoor.go): the Slack door's switch and its apps
	Doors     slackDoorSwitch `yaml:"doors"`
	SlackApps []SlackApp      `yaml:"slack_apps"`
	baseURL   string
}

// BaseURL is alerts_base_url as checked ("" = not set: the messages carry no link).
func (s *Settings) BaseURL() string { return s.baseURL }

// parseBaseURL checks alerts_base_url: an absolute http or https address with a host, no user, query or fragment (the
// UI's root, a sub-path allowed); it may come through env: or file:. The trailing slash is dropped.
func parseBaseURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if strings.HasPrefix(raw, "env:") || strings.HasPrefix(raw, "file:") {
		v := strings.TrimSpace(config.Resolve(raw))
		if v == "" {
			return "", fmt.Errorf("alerts_base_url %s is empty or unreadable", raw)
		}
		raw = v
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return "", fmt.Errorf("alerts_base_url %q must be an absolute http or https address (the UI's, as a reader opens it)", raw)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("alerts_base_url %q must not carry a user, a query or a fragment", raw)
	}
	base := strings.TrimRight(u.Scheme+"://"+u.Host+u.EscapedPath(), "/")
	if len(base) > maxBaseURL {
		return "", fmt.Errorf("alerts_base_url is over %d bytes (every alert line carries it)", maxBaseURL)
	}
	return base, nil
}

// maxBaseURL bounds alerts_base_url: the address rides after every line, inside the chat formats' text budgets.
const maxBaseURL = 200

// DSN resolves alerts_dsn; "" = not set (the caller uses the repository's dsn).
func (s *Settings) DSN() string {
	if strings.TrimSpace(s.DSNRaw) == "" {
		return ""
	}
	return config.Resolve(strings.TrimSpace(s.DSNRaw))
}

// LoadFile reads the alerts: block and alerts_dsn of the configuration file; no block = no channel (nothing is ever
// sent).
func LoadFile(path string) (*Settings, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("alerts: %w", err)
	}
	return Parse(b)
}

// Parse reads and validates the alerts: block and alerts_dsn of a configuration file's text.
func Parse(b []byte) (*Settings, error) {
	var s Settings
	if err := yaml.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("alerts: %w", err)
	}
	if err := Validate(s.Channels); err != nil {
		return nil, err
	}
	if err := checkSlackDoor(&s); err != nil {
		return nil, err
	}
	if v := strings.TrimSpace(s.DSNRaw); v != "" && (strings.HasPrefix(v, "env:") || strings.HasPrefix(v, "file:")) && s.DSN() == "" {
		return nil, fmt.Errorf("alerts_dsn %s is empty or unreadable", v)
	}
	base, err := parseBaseURL(s.BaseURLRaw)
	if err != nil {
		return nil, err
	}
	s.baseURL = base
	for i := range s.Channels {
		s.Channels[i].base = base
	}
	return &s, nil
}

var nameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,62}$`)

// Validate checks every channel and builds its sender; a secret through env: or file: is read here, once.
func Validate(chs []Channel) error {
	seen := map[string]bool{}
	for i := range chs {
		c := &chs[i]
		if !nameRE.MatchString(c.Name) {
			return fmt.Errorf("alerts[%d]: name %q must be lower-case letters, digits, '_', '.' or '-' (1..63, starting with a letter or digit)", i, c.Name)
		}
		if strings.HasPrefix(c.Name, routePrefix) {
			return fmt.Errorf("alerts[%d]: name %q starts with %q, the names of application contacts' routes (Admin > Applications): choose another name", i, c.Name, routePrefix)
		}
		if seen[c.Name] {
			return fmt.Errorf("alerts %q is listed twice", c.Name)
		}
		seen[c.Name] = true
		if err := c.validate(); err != nil {
			return fmt.Errorf("alerts %q: %w", c.Name, err)
		}
	}
	return nil
}

func (c *Channel) validate() error {
	if c.MinSeverity == "" {
		c.MinSeverity = "warning"
	}
	if rank(c.MinSeverity) == 0 {
		return fmt.Errorf("min_severity must be info, warning or critical (got %q)", c.MinSeverity)
	}
	for _, n := range c.Instances {
		if strings.TrimSpace(n) == "" {
			return errors.New("instances holds an empty name")
		}
	}
	for j, s := range c.Tags {
		t, err := config.ParseTag(s)
		if err != nil {
			return err
		}
		c.Tags[j] = t.String() // the written form the repository's instance_tags_merged holds
	}
	c.loc = time.UTC
	if c.Timezone != "" {
		loc, err := time.LoadLocation(c.Timezone)
		if err != nil {
			return fmt.Errorf("timezone: %w", err)
		}
		c.loc = loc
	}
	if c.QuietHours != "" {
		q, err := parseQuiet(c.QuietHours)
		if err != nil {
			return err
		}
		c.quiet = q
	}
	if c.ClearAfter != nil && c.ClearAfter.Duration < 0 {
		return errors.New("clear_after must be 0 or more")
	}
	if c.Repeat != nil && c.Repeat.Duration != 0 && c.Repeat.Duration < 5*time.Minute {
		return fmt.Errorf("repeat must be at least 5m, or disabled (got %s)", c.Repeat.Duration)
	}
	if c.MaxPerHour < 0 || c.MaxPerHour > maxPerHourLimit {
		return fmt.Errorf("max_per_hour must be 0 (no cap) to %d (got %d)", maxPerHourLimit, c.MaxPerHour)
	}
	if c.DigestHour != nil {
		if *c.DigestHour < 0 || *c.DigestHour > 23 {
			return fmt.Errorf("digest_hour must be 0 to 23, an hour in the channel's timezone (got %d)", *c.DigestHour)
		}
		if incidentKind(c.Kind) {
			return fmt.Errorf("digest_hour: a %s channel opens an incident per alert, never a daily message: set it on a mail, chat or file channel", c.Kind)
		}
		if c.Timezone == "Local" {
			return errors.New("digest_hour: timezone must be an IANA name (the repository reads the digest hour in it; Local is this machine's only)")
		}
	}
	if len(c.Checks) > maxChecks {
		return fmt.Errorf("checks: at most %d (got %d)", maxChecks, len(c.Checks))
	}
	for j, k := range c.Checks {
		k = strings.ToLower(strings.TrimSpace(k))
		if k == "" || len(k) > 200 {
			return errors.New("checks: each entry is a check's name (a finding's source or setting), 1 to 200 characters")
		}
		c.Checks[j] = k
	}
	tpl, err := c.Templates.compile()
	if err != nil {
		return err
	}
	if tpl != nil && c.Kind == "file" {
		return errors.New("templates: a file drop writes the alert's fields, never a subject or a line: leave them out")
	}
	if tpl != nil && len(tpl.line) > 0 && c.Kind == "webhook" && c.Webhook != nil && (c.Webhook.Format == "" || c.Webhook.Format == "json") {
		return errors.New("templates.line: a json webhook carries the alert's fields, not its line (its subject is the body's summary)")
	}
	c.tpl = tpl
	blocks := 0
	for _, set := range []bool{c.SMTP != nil, c.Webhook != nil, c.File != nil, c.PagerDuty != nil, c.Opsgenie != nil, c.Pushover != nil, c.Zabbix != nil, c.AzureMonitor != nil, c.Slack != nil} {
		if set {
			blocks++
		}
	}
	if blocks != 1 {
		return errors.New("exactly one of smtp:, webhook:, file:, pagerduty:, opsgenie:, pushover:, zabbix:, azuremonitor: or slack: is required")
	}
	switch c.Kind {
	case "smtp":
		if c.SMTP == nil {
			return errors.New("kind smtp needs an smtp: block")
		}
		c.sender, err = c.SMTP.build()
	case "webhook":
		if c.Webhook == nil {
			return errors.New("kind webhook needs a webhook: block")
		}
		c.sender, err = c.Webhook.build()
	case "file":
		if c.File == nil {
			return errors.New("kind file needs a file: block")
		}
		c.sender, err = c.File.build()
	case "pagerduty":
		if c.PagerDuty == nil {
			return errors.New("kind pagerduty needs a pagerduty: block")
		}
		if !c.SendsRecovery() {
			return errors.New("kind pagerduty sends every recovery (recovery: false would leave its incidents open)")
		}
		c.sender, err = c.PagerDuty.build()
	case "opsgenie":
		if c.Opsgenie == nil {
			return errors.New("kind opsgenie needs an opsgenie: block")
		}
		if !c.SendsRecovery() {
			return errors.New("kind opsgenie sends every recovery (recovery: false would leave its alerts open)")
		}
		c.sender, err = c.Opsgenie.build()
	case "pushover":
		if c.Pushover == nil {
			return errors.New("kind pushover needs a pushover: block")
		}
		c.sender, err = c.Pushover.build()
	case "zabbix":
		if c.Zabbix == nil {
			return errors.New("kind zabbix needs a zabbix: block")
		}
		c.sender, err = c.Zabbix.build()
	case "azuremonitor":
		if c.AzureMonitor == nil {
			return errors.New("kind azuremonitor needs an azuremonitor: block")
		}
		c.sender, err = c.AzureMonitor.build()
	case "slack":
		if c.Slack == nil {
			return errors.New("kind slack needs a slack: block")
		}
		c.sender, err = c.Slack.build()
	default:
		return fmt.Errorf("kind must be smtp, webhook, file, pagerduty, opsgenie, pushover, zabbix, azuremonitor or slack (got %q)", c.Kind)
	}
	return err
}

// secret resolves a value that must come through env:NAME or file:/path; what names it is the error's subject.
func secret(what, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "env:") && !strings.HasPrefix(raw, "file:") {
		return "", fmt.Errorf("%s must be env:NAME or file:/path, never inline", what)
	}
	v := config.Resolve(raw)
	if v == "" {
		return "", fmt.Errorf("%s %s is empty or unreadable", what, raw)
	}
	return v, nil
}

// loopback says whether a host name or address is this machine (plain SMTP and plain HTTP are allowed only there).
func loopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && ip.IsLoopback()
}

func rank(sev string) int {
	switch sev {
	case "critical":
		return 3
	case "warning":
		return 2
	case "info":
		return 1
	}
	return 0
}

// ---- quiet hours ----------------------------------------------------------------------------------------------

type quiet struct{ from, to int } // minutes after midnight; from > to crosses midnight

func parseQuiet(s string) (*quiet, error) {
	a, b, ok := strings.Cut(strings.TrimSpace(s), "-")
	if !ok {
		return nil, fmt.Errorf("quiet_hours %q must be HH:MM-HH:MM", s)
	}
	f, err1 := hhmm(a)
	t, err2 := hhmm(b)
	if err1 != nil || err2 != nil || f == t {
		return nil, fmt.Errorf("quiet_hours %q must be HH:MM-HH:MM with two different times", s)
	}
	return &quiet{f, t}, nil
}

func hhmm(s string) (int, error) {
	h, m, ok := strings.Cut(strings.TrimSpace(s), ":")
	if !ok || len(m) != 2 {
		return 0, errors.New("not HH:MM")
	}
	hv, err := strconv.Atoi(h)
	if err != nil || hv < 0 || hv > 23 {
		return 0, errors.New("hour")
	}
	mv, err := strconv.Atoi(m)
	if err != nil || mv < 0 || mv > 59 {
		return 0, errors.New("minute")
	}
	return hv*60 + mv, nil
}

// Quiet says whether t falls inside the channel's quiet hours (in its timezone).
func (c *Channel) Quiet(t time.Time) bool {
	if c.quiet == nil {
		return false
	}
	loc := c.loc
	if loc == nil {
		loc = time.UTC
	}
	lt := t.In(loc)
	m := lt.Hour()*60 + lt.Minute()
	if c.quiet.from < c.quiet.to {
		return m >= c.quiet.from && m < c.quiet.to
	}
	return m >= c.quiet.from || m < c.quiet.to
}

// ---- the pass -------------------------------------------------------------------------------------------------

// Alert is one finding owed to a channel.
type Alert struct {
	Event       string     `json:"event"` // firing | escalated | repeat | resolved | cleared
	FindingKey  string     `json:"finding_key"`
	InstanceID  *int       `json:"instance_id,omitempty"`
	Instance    string     `json:"instance"`
	Severity    string     `json:"severity"`
	Source      string     `json:"source"`
	Setting     string     `json:"setting"`
	Value       string     `json:"value"`
	Detail      string     `json:"detail,omitempty"`
	Suggested   string     `json:"suggested,omitempty"`
	FindingAt   *time.Time `json:"finding_at,omitempty"`
	FirstSentAt *time.Time `json:"first_sent_at,omitempty"`
	SentBefore  int        `json:"sent_before"` // this channel's earlier sends of the finding
	// URL is the address of the alert's own page (alerts_base_url + #/alert?k=<finding key>&t=<unix time>); "" when
	// no base address is configured.
	URL string `json:"url,omitempty"`

	text string // the line as the channel's template made it ("" = the built-in line)
}

// Message is what one send carries.
type Message struct {
	Channel string    `json:"channel"`
	SentAt  time.Time `json:"sent_at"`
	Alerts  []Alert   `json:"alerts"`
	// Subject is the channel's subject template filled for this message ("" = the built-in summary).
	Subject string `json:"subject,omitempty"`
}

// Summary is the one-line headline of a message: the channel's subject template when it has one.
func (m Message) Summary() string {
	if m.Subject != "" {
		return m.Subject
	}
	var firing, repeat, resolved, crit, tests int
	for _, a := range m.Alerts {
		switch a.Event {
		case "firing", "escalated":
			firing++
		case "repeat":
			repeat++
		case "test":
			tests++
		default:
			resolved++
		}
		if a.Severity == "critical" && a.Event != "resolved" {
			crit++
		}
	}
	parts := []string{}
	if tests > 0 && firing+repeat == 0 {
		return "pgvigil: test message"
	}
	if firing > 0 {
		parts = append(parts, fmt.Sprintf("%d new", firing))
	}
	if repeat > 0 {
		parts = append(parts, fmt.Sprintf("%d still open", repeat))
	}
	if resolved > 0 {
		parts = append(parts, fmt.Sprintf("%d resolved", resolved))
	}
	s := "pgvigil: " + strings.Join(parts, ", ")
	if crit > 0 {
		s += fmt.Sprintf(" (%d critical)", crit)
	}
	return s
}

// maxLine caps one alert's line (a finding's value or detail can be long): an SMTP line stays under RFC 5322's 998
// octets and a message of maxPerMessage alerts stays well under a Teams or Slack webhook's payload limit.
const maxLine = 600

// Line is one alert as a line of text: the channel's line template, or the built-in line, cut at maxLine bytes, then
// the address of the alert's page (never cut: a reader must be able to open it) unless the template placed it.
func (a Alert) Line() string {
	s := a.text
	if s == "" {
		s = a.line()
	}
	if a.URL == "" {
		return capLine(s)
	}
	// a template that placed {url} keeps it where it stands while the line fits; a line over maxLine loses the
	// placed copy and is cut, then the whole address follows (a cut never breaks the address)
	if strings.Contains(s, a.URL) {
		if len(s) <= maxLine+1+len(a.URL) {
			return s
		}
		s = strings.TrimSpace(strings.Replace(s, a.URL, "", 1))
	}
	return capLine(s) + " " + a.URL
}

// capLine cuts a line at maxLine bytes on a rune boundary.
func capLine(s string) string {
	if len(s) <= maxLine {
		return s
	}
	cut := maxLine - len(" ...")
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + " ..."
}

func (a Alert) line() string {
	if a.Event == "test" {
		return fmt.Sprintf("[TEST] %s: %s", a.Instance, a.Value)
	}
	ev := strings.ToUpper(a.Event)
	if a.Event == "resolved" {
		return fmt.Sprintf("[RESOLVED] %s: %s %s (%s) %s", a.Instance, a.Source, a.Setting, a.Severity, a.Value)
	}
	s := fmt.Sprintf("[%s %s] %s: %s %s = %s", ev, strings.ToUpper(a.Severity), a.Instance, a.Source, a.Setting, a.Value)
	if a.Detail != "" {
		s += " - " + a.Detail
	}
	if a.Suggested != "" {
		s += " (suggested: " + a.Suggested + ")"
	}
	return s
}

// channelFailing is the setting of the repository's own finding that a channel's last three sends failed (0154's
// alert_channel_failing, task 403b: PerformanceMonitor Fixed 21 / 27); its value is the channel's name.
const channelFailing = "alert channel failing"

// failingChannel names the channel an 'alert channel failing' alert is about, "" for any other alert. The pass sends it
// on every channel but that one.
func (a Alert) failingChannel() string {
	if a.Source == "pgvigil repository" && a.Setting == channelFailing {
		return a.Value
	}
	return ""
}

// sender delivers one message to one channel's destination.
type sender interface {
	send(ctx context.Context, m Message) error
	destination() string
	perAlert() bool // true: one message per alert (the file drop, PagerDuty's and Opsgenie's events)
}

// budgeted is a sender whose destination limits a message's text (Discord 2000 characters, Google Chat 4096): a
// message carries only as many alerts as their lines fit, the rest go in the next message of the pass.
type budgeted interface {
	budget() int // bytes of alert lines one message may carry; 0 = no limit beyond maxPerMessage
}

// costed is a budgeted sender whose message grows by more than an alert's line: a Teams card carries each line
// JSON-escaped (json.Marshal writes &, < and > as six bytes each) and its 'Open in pgvigil' button; lineCost is
// what one alert adds to the message, in the budget's bytes.
type costed interface {
	lineCost(a Alert) int
}

// holding is a sender whose destination's answer can hold the channel across passes (Pushover's 429 until its reset,
// another 4xx until the configuration changes): held reads the channel's newest attempt's error text, as the sender
// wrote it, and says whether it holds at now and why. A Send test is never held, and one that goes through ends the hold.
type holding interface {
	held(lastErr string, now time.Time) (bool, string)
}

// quotaed is a sender whose answers carry the destination's monthly quota (Pushover's X-Limit-App-* headers): the pass
// records the newest after each send (0154's alert_channel_quota).
type quotaed interface {
	lastQuota() *channelQuota
}

// threader is a sender that keeps a thread per alert (the Slack bot, task 403b K2): the pass posts what has no thread
// and replies in the threads it knows, each its own send and attempt (sendThreaded), and keeps each post's thread
// with its attempt (0154's alert_record_threads).
type threader interface {
	slackChannel() string
	post(ctx context.Context, m Message) (string, error)
	reply(ctx context.Context, m Message, threadTS string, broadcast bool) error
}

// refusedError marks a send refused for its destination (a redirect, a plain connection off loopback).
type refusedError struct{ msg string }

func (e *refusedError) Error() string { return e.msg }

func refused(format string, a ...any) error { return &refusedError{fmt.Sprintf(format, a...)} }

// maxPerMessage caps the alerts of one SMTP or webhook message; more go in the next message of the same pass.
const maxPerMessage = 25

// sendTimeout bounds one send.
const sendTimeout = 30 * time.Second

// lockKey is the advisory lock a pass holds: two senders (the daemon and a one-off `pgvigil alerts`) never send the
// same alert twice.
const lockKey int64 = 0x7067766961_6c72 // "pgvia" "lr"

// Result counts what one pass did.
type Result struct {
	Channels int
	Sent     int // alerts in sent messages
	Failed   int // alerts in failed or refused messages
	Cleared  int
	Held     []string // channels in their quiet hours
	// HeldBy is each channel its destination's last answer holds (task B24k: 'name: why'): nothing is owed it this pass.
	HeldBy  []string
	Skipped bool     // another sender held the lock
	Errors  []string // channel: error
	// RulesFiring is how many alert rule rows (a rule on one instance and series) fire after this pass's evaluation.
	RulesFiring int
	// RulesErr is why the alert rules were not judged in this pass (the summary line says it; Errors stays the
	// channels'); nil = judged, or a repository before 0085.
	RulesErr error
	// Capped is how many alerts the channels' max_per_hour held in this pass (owed again by a later pass).
	Capped int
	// Tests is how many Send test requests the pass answered; TestsFailed of them did not reach the destination.
	Tests, TestsFailed int
	// TestsErr is why the Send test requests were not read (a repository before 0093 has none: nil).
	TestsErr error
	// Routes is how many application contacts' routes sent through a derived channel this pass (routes.go);
	// RoutesErr is why the routes were not read (their door failed: no route sent, none closed).
	Routes    int
	RoutesErr error
	// HistoryRows is how many findings-history rows the pass wrote (0154: changes and hourly samples); HistoryErr is
	// why it wrote none (a repository before 0154: nil).
	HistoryRows int
	HistoryErr  error
	// Digests is how many daily digests the pass sent (digest.go), DigestsFailed how many failed; DigestErr is why
	// the digests owed were not read.
	Digests, DigestsFailed int
	DigestErr              error
}

func (r Result) String() string {
	if r.Skipped {
		return "another alert sender is running: nothing done"
	}
	s := fmt.Sprintf("%d channel(s): %d alert(s) sent, %d failed, %d cleared", r.Channels, r.Sent, r.Failed, r.Cleared)
	if len(r.Held) > 0 {
		s += "; quiet hours: " + strings.Join(r.Held, ", ")
	}
	if len(r.HeldBy) > 0 {
		s += "; held by the destination: " + strings.Join(r.HeldBy, "; ")
	}
	if r.RulesFiring > 0 {
		s += fmt.Sprintf("; %d alert rule row(s) firing", r.RulesFiring)
	}
	if r.RulesErr != nil {
		s += "; alert rules not judged: " + strings.Join(strings.Fields(r.RulesErr.Error()), " ")
	}
	if r.Capped > 0 {
		s += fmt.Sprintf("; %d held by max_per_hour", r.Capped)
	}
	if r.Tests > 0 {
		s += fmt.Sprintf("; %d test message(s), %d failed", r.Tests, r.TestsFailed)
	}
	if r.TestsErr != nil {
		s += "; test requests not read: " + strings.Join(strings.Fields(r.TestsErr.Error()), " ")
	}
	if r.Routes > 0 {
		s += fmt.Sprintf("; %d contact route(s)", r.Routes)
	}
	if r.RoutesErr != nil {
		s += "; contact routes not read: " + strings.Join(strings.Fields(r.RoutesErr.Error()), " ")
	}
	if r.HistoryErr != nil {
		s += "; findings history not written: " + strings.Join(strings.Fields(r.HistoryErr.Error()), " ")
	}
	if r.Digests > 0 || r.DigestsFailed > 0 {
		s += fmt.Sprintf("; %d digest(s) sent, %d failed", r.Digests, r.DigestsFailed)
	}
	if r.DigestErr != nil {
		s += "; digests not read: " + strings.Join(strings.Fields(r.DigestErr.Error()), " ")
	}
	return s
}

// rowQuerier is the one call evalRules makes: a pool connection in a pass, a fake in the tests.
type rowQuerier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// rulesTimeout bounds the rule evaluation on the server: a slow one must not hold the pass, and the lock it runs
// under, from the channels. The server ends the statement; the connection and the pass go on.
const rulesTimeout = 30 * time.Second

// evalRules has the repository judge every alert rule in force at now and store the result
// (pgvigil.alert_rules_run, 0085); it returns how many rows fire. The firing rows are findings of source
// 'alert rule' in pgvigil.alert_findings, so alert_due owes them like any other finding. A repository before 0085
// has no such function: that is asked first (no rules there, no error here, and no error in the server's log for a
// function it lacks). The call runs under the session's statement_timeout set to rulesTimeout and put back after.
func evalRules(ctx context.Context, q rowQuerier, now time.Time) (n int, err error) {
	var have bool
	if err := q.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.alert_rules_run(timestamp with time zone)') IS NOT NULL`).Scan(&have); err != nil {
		return 0, err
	}
	if !have {
		return 0, nil
	}
	var before, set string
	if err := q.QueryRow(ctx, `SELECT current_setting('statement_timeout')`).Scan(&before); err != nil {
		return 0, err
	}
	if err := q.QueryRow(ctx, `SELECT set_config('statement_timeout', $1, false)`, strconv.FormatInt(rulesTimeout.Milliseconds(), 10)).Scan(&set); err != nil {
		return 0, err
	}
	defer func() {
		// the session's own limit comes back whatever the evaluation did; a failure to put it back is the pass's to know
		if rerr := q.QueryRow(context.WithoutCancel(ctx), `SELECT set_config('statement_timeout', $1, false)`, before).Scan(&set); rerr != nil && err == nil {
			n, err = 0, fmt.Errorf("statement_timeout not put back: %w", rerr)
		}
	}()
	if err := q.QueryRow(ctx, `SELECT pgvigil.alert_rules_run($1)`, now).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

// Pass runs one round over the channels; skip names the channels the loop is backing off (nil = none). The map it
// returns holds each channel that was tried: nil when every message went, else the error that stopped it.
func Pass(ctx context.Context, pool *pgxpool.Pool, chs []Channel, now time.Time, skip map[string]bool) (Result, map[string]error, error) {
	res := Result{Channels: len(chs)}
	outcome := map[string]error{}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return res, nil, err
	}
	defer conn.Release()
	var got bool
	if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, lockKey).Scan(&got); err != nil {
		return res, nil, err
	}
	if !got {
		res.Skipped = true
		return res, outcome, nil
	}
	defer func() { _, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, lockKey) }()

	if len(chs) == 0 {
		// no sync: a collector without an alerts: list leaves the channels another one records as they are
		err := record(ctx, conn.Exec, now, attempt{Outcome: "none", Error: "no channel configured: nothing sent"})
		return res, outcome, err
	}
	// the application contacts' routes (routes.go), read before the sync: ONE sync records the configuration's channels
	// and the derived ones together (a second would mark the other set not configured). A door that failed sends no
	// route and closes none; the configuration's channels go on.
	rs, haveRoutes, rerr := readRoutes(ctx, conn)
	if rerr != nil {
		res.RoutesErr = rerr
	}
	ds := derive(chs, rs)
	all := make([]Channel, 0, len(chs)+len(ds)) // a new slice: the caller's chs is never appended to
	all = append(all, chs...)
	routed := map[string]bool{}
	for _, d := range ds {
		if d.note == "" {
			all = append(all, d.ch)
			routed[d.ch.Name] = true
		}
	}
	res.Routes = len(routed)
	// a channel of a kind this repository's check does not take yet (before 0154: pushover, zabbix, azuremonitor,
	// slack) is left out of the pass and named, so the other channels still go (one such channel would make the
	// sync, and so every send, fail)
	if known, err := storeKinds(ctx, conn); err != nil {
		return res, nil, err
	} else if known != nil {
		kept := make([]Channel, 0, len(all))
		for _, c := range all {
			if !known[c.Kind] {
				res.Errors = append(res.Errors, c.Name+": the repository does not take kind "+c.Kind+" yet (pgvigil migrate)")
				continue
			}
			kept = append(kept, c)
		}
		all = kept
	}
	if err := syncChannels(ctx, conn.Exec, all, now); err != nil {
		return res, nil, err
	}
	if haveRoutes && rerr == nil {
		if err := routeNotes(ctx, conn, now, ds); err != nil {
			return res, nil, err
		}
		n, err := closeGone(ctx, conn, now, routed)
		if err != nil {
			return res, nil, err
		}
		res.Cleared += n
	}
	// the rules are judged before the quiet-hours cut: a channel in its quiet hours is owed what fired meanwhile when
	// they end. A failure here (or the server's cut at rulesTimeout) costs this pass's fresh rule states only: the
	// findings, and the rule alerts as last judged, still go out.
	if n, err := evalRules(ctx, conn, now); err != nil {
		res.RulesErr = err
	} else {
		res.RulesFiring = n
	}
	// the findings history (0154) is written whatever the channels: every finding's open, close and severity change,
	// and an hourly sample of each standing one. A failure costs this pass's rows only.
	if n, err := historyRun(ctx, conn, now); err != nil {
		res.HistoryErr = err
	} else {
		res.HistoryRows = n
	}
	// a Send test asked on the Alerts page goes out whatever the channel's quiet hours, back-off or cap: a person is
	// waiting for its answer (tests.go)
	if err := runTests(ctx, conn, chs, now, &res); err != nil {
		res.TestsErr = err
	}
	// a channel its destination's last answer holds (holding: Pushover's 429 or another 4xx) is skipped like a channel
	// backing off: nothing is owed it, its digest waits
	skipped := map[string]bool{}
	for n, v := range skip {
		skipped[n] = v
	}
	for i := range all {
		c := &all[i]
		h, ok := c.sender.(holding)
		if !ok || skipped[c.Name] || c.Quiet(now) {
			continue
		}
		// the newest of the channel's sends, Send tests that went and held attempts: only a send or a test that went
		// through ends a hold (a test that timed out carries no marker and leaves it), or a changed configuration
		// (held compares the marker's hash); 0154's alert_channel_failing reads the same row
		var last string
		if err := conn.QueryRow(ctx, `SELECT coalesce((SELECT coalesce(l.error, '') FROM pgvigil.alert_log l
		     WHERE l.channel = $1 AND (l.outcome IN ('sent', 'test') OR (l.outcome = 'failed' AND l.error LIKE 'held until %'))
		     ORDER BY l.snapshot_at DESC LIMIT 1), '')`,
			c.Name).Scan(&last); err != nil {
			return res, nil, err
		}
		if yes, why := h.held(last, now); yes {
			skipped[c.Name] = true
			res.HeldBy = append(res.HeldBy, c.Name+": "+why)
		}
	}
	var due []map[string]any
	byName := map[string]*Channel{}
	for i := range all {
		c := &all[i]
		byName[c.Name] = c
		if c.Quiet(now) {
			res.Held = append(res.Held, c.Name)
			continue
		}
		if skipped[c.Name] {
			continue
		}
		due = append(due, map[string]any{"name": c.Name, "min_severity": c.MinSeverity, "instances": nonNil(c.Instances),
			"tags": nonNil(c.Tags), "repeat_secs": int(c.RepeatEvery().Seconds()),
			"clear_after_secs": int(c.ClearAfterEvery().Seconds()), "recovery": c.SendsRecovery(),
			"repo_wide": !routed[c.Name],      // a route never takes the repository-wide findings (0190 alert_due)
			"checks":    nonNil(c.Checks),     // A31: the checks the channel takes ([] = all; alert_due's wiring line)
			"digest":    c.DigestHour != nil}) // digest holds apply only on a channel with a daily digest (0154 alert_hold)
	}
	if len(due) == 0 {
		return res, outcome, nil
	}
	pay, _ := json.Marshal(due)
	if _, err := conn.Exec(ctx, `SELECT pgvigil.alert_mark($1, $2::jsonb)`, now, string(pay)); err != nil {
		return res, nil, err
	}
	rows, err := conn.Query(ctx, `SELECT channel, event, finding_key, instance_id, instance, severity, source, setting, value,
	       detail, suggested, finding_at, first_sent_at, send_count FROM pgvigil.alert_due($1, $2::jsonb)`, now, string(pay))
	if err != nil {
		return res, nil, err
	}
	owed := map[string][]Alert{}
	var order []string
	for rows.Next() {
		var ch string
		var a Alert
		var inst, src, set, val, det, sug *string
		if err := rows.Scan(&ch, &a.Event, &a.FindingKey, &a.InstanceID, &inst, &a.Severity, &src, &set, &val, &det, &sug,
			&a.FindingAt, &a.FirstSentAt, &a.SentBefore); err != nil {
			rows.Close()
			return res, nil, err
		}
		a.Instance, a.Source, a.Setting, a.Value, a.Detail, a.Suggested = str(inst), str(src), str(set), str(val), str(det), str(sug)
		// TEXT-NOW: a finding that quotes a statement is sent under its instance's query_text policy now, not as the text
		// was stored (internal/textnow); the record keeps what was sent
		a.Value, a.Detail = textnow.Finding(a.Setting, a.Value, a.Detail, policyOf(a.Instance))
		a.FindingAt, a.FirstSentAt = utc(a.FindingAt), utc(a.FirstSentAt)
		if _, ok := owed[ch]; !ok {
			order = append(order, ch)
		}
		owed[ch] = append(owed[ch], a)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return res, nil, err
	}
	var anchors bool // task 403b K4 (0154): attachment is on this repository
	if err := conn.QueryRow(ctx, `SELECT to_regclass('pgvigil.alert_anchor_checks') IS NOT NULL`).Scan(&anchors); err != nil {
		return res, nil, err
	}
	// the Slack bot channels last: their calls are paced (at least 1 s apart), so a page owed to any other channel
	// never waits behind their posts and replies
	threaded := func(name string) bool { _, ok := byName[name].sender.(threader); return ok }
	sort.SliceStable(order, func(i, j int) bool { return !threaded(order[i]) && threaded(order[j]) })
	for _, name := range order {
		c := byName[name]
		if anchors {
			if err := attachedLines(ctx, conn, c.Name, owed[name], now); err != nil {
				return res, outcome, err
			}
		}
		var send, cleared []Alert
		for _, a := range owed[name] {
			if a.failingChannel() == c.Name {
				continue // its own 'alert channel failing' (0154): it would fail there, or arrive after the channel recovered
			}
			// a cleared finding (its instance retired, or the channel no longer covers it) is recorded without a
			// message - nothing was fixed - except on PagerDuty and Opsgenie, where the open incident must be resolved
			// or it stays open for good
			if a.Event == "cleared" && !incidentKind(c.Kind) {
				cleared = append(cleared, a)
			} else {
				send = append(send, c.decorate(a, now))
			}
		}
		if len(cleared) > 0 {
			if err := record(ctx, conn.Exec, now, attempt{Channel: c.Name, Kind: c.Kind, Destination: c.Destination(),
				Outcome: "cleared", Items: cleared}); err != nil {
				return res, outcome, err
			}
			res.Cleared += len(cleared)
		}
		if c.MaxPerHour > 0 && len(send) > 0 {
			held, err := c.capHold(ctx, conn, now, &send)
			if err != nil {
				return res, outcome, err
			}
			if len(held) > 0 {
				if err := record(ctx, conn.Exec, now, attempt{Channel: c.Name, Kind: c.Kind, Destination: c.Destination(),
					Outcome: "capped", Items: held, Error: fmt.Sprintf("%d alert(s) held: max_per_hour %d reached; a later pass sends them", len(held), c.MaxPerHour)}); err != nil {
					return res, outcome, err
				}
				res.Capped += len(held)
			}
		}
		if th, ok := c.sender.(threader); ok {
			chErr, err := c.sendThreaded(ctx, conn, th, send, now, &res)
			if err != nil {
				return res, outcome, err
			}
			outcome[c.Name] = chErr
			continue
		}
		budget := 0
		if b, ok := c.sender.(budgeted); ok {
			budget = b.budget()
		}
		var cost func(Alert) int
		if cs, ok := c.sender.(costed); ok {
			cost = cs.lineCost
		}
		var chErr error
		for _, batch := range batchesCost(send, c.sender.perAlert(), budget, cost) {
			sctx, cancel := context.WithTimeout(ctx, sendTimeout)
			err := c.sender.send(sctx, Message{Channel: c.Name, SentAt: now.UTC(), Alerts: batch, Subject: c.subject(batch)})
			cancel()
			at := attempt{Channel: c.Name, Kind: c.Kind, Destination: c.Destination(), Outcome: "sent", Items: batch}
			if err != nil {
				at.Outcome, at.Error = "failed", err.Error()
				var re *refusedError
				if errors.As(err, &re) {
					at.Outcome = "refused"
				}
				res.Failed += len(batch)
				res.Errors = append(res.Errors, c.Name+": "+err.Error())
				chErr = err
			} else {
				res.Sent += len(batch)
			}
			if rerr := record(context.WithoutCancel(ctx), conn.Exec, time.Now(), at); rerr != nil {
				return res, outcome, rerr
			}
			if qs, ok := c.sender.(quotaed); ok {
				if q := qs.lastQuota(); q != nil {
					if qerr := recordQuota(context.WithoutCancel(ctx), conn, now, c.Name, q); qerr != nil {
						res.Errors = append(res.Errors, c.Name+": its quota not recorded: "+qerr.Error())
					}
				}
			}
			if err != nil {
				break // the destination failed: the rest waits for the next pass
			}
		}
		outcome[c.Name] = chErr
	}
	// the attached alerts' notices (task 403b K4) on every Slack bot channel that is not quiet, not held or backing
	// off and did not just fail - whether or not it owed anything else this pass: an attached alert is held, so a pass
	// whose only news on the channel is that alert owes it nothing. A notice that fails is told in the result only:
	// it never backs off the channel (its pages would wait) and is tried again next pass.
	if anchors {
		for i := range all {
			c := &all[i]
			th, ok := c.sender.(threader)
			if !ok || c.Quiet(now) || skipped[c.Name] || outcome[c.Name] != nil {
				continue
			}
			if err := c.attachedNotices(ctx, conn, th, now, &res); err != nil {
				return res, outcome, err
			}
		}
	}
	// the daily digests (digest.go): after the alerts, to every channel owed one that is not quiet, not backing off and
	// did not just fail
	if err := runDigests(ctx, conn, all, now, skipped, outcome, &res); err != nil {
		res.DigestErr = err
	}
	for _, c := range all {
		if _, ok := outcome[c.Name]; !ok && !c.Quiet(now) && !skip[c.Name] {
			outcome[c.Name] = nil
		}
	}
	return res, outcome, nil
}

// attachedLines (task 403b K4) writes attachment into the owed alerts' details before their lines are made: a firing
// alert that was attached under an anchor until now says what it was attached to and why it fires now; an anchor's
// recovery lists what was attached under that occurrence while it stood.
func attachedLines(ctx context.Context, conn *pgxpool.Conn, channel string, owed []Alert, now time.Time) error {
	var firing, resolved []string
	critical := map[string]bool{} // a firing alert that is critical now: never held, whatever its anchor does
	for _, a := range owed {
		switch a.Event {
		case "firing":
			firing = append(firing, a.FindingKey)
			if a.Severity == "critical" {
				critical[a.FindingKey] = true
			}
		case "resolved":
			resolved = append(resolved, a.FindingKey)
		}
	}
	if len(firing) == 0 && len(resolved) == 0 {
		return nil
	}
	rows, err := conn.Query(ctx, `SELECT d.finding_key, d.anchor_key, d.anchor_first_sent_at, coalesce(d.instance_name, ''),
	       coalesce(d.setting, ''), d.last_at, coalesce(st.instance_name, ''), coalesce(st.setting, ''), st.cleared_at
	  FROM pgvigil.alert_held d
	  LEFT JOIN pgvigil.alert_state st
	    ON st.channel = d.channel AND st.finding_key = d.anchor_key AND st.first_sent_at = d.anchor_first_sent_at
	 WHERE d.hold_kind = 'attached' AND d.channel = $1 AND (d.finding_key = ANY ($2) OR d.anchor_key = ANY ($3))
	 ORDER BY d.last_at DESC`, channel, firing, resolved)
	if err != nil {
		return err
	}
	defer rows.Close()
	released := map[string]string{} // a firing key: why it fires now
	under := map[string][]string{}  // an anchor occurrence: what stood under it
	for rows.Next() {
		var key, anchor, inst, set, aInst, aSet string
		var anchorFirst, last time.Time
		var cleared *time.Time
		if err := rows.Scan(&key, &anchor, &anchorFirst, &inst, &set, &last, &aInst, &aSet, &cleared); err != nil {
			return err
		}
		if _, seen := released[key]; !seen && last.After(now.Add(-15*time.Minute)) {
			why := "which no longer anchors it"
			switch {
			case critical[key]:
				why = "and is critical now (a critical alert is never held)"
			case cleared != nil:
				why = "which resolved " + cleared.UTC().Format("15:04") + " UTC"
			}
			released[key] = fmt.Sprintf("was attached to %s on %s, %s", aSet, aInst, why)
		}
		k := threadKey(anchor, anchorFirst)
		under[k] = append(under[k], set+" on "+inst)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for i := range owed {
		a := &owed[i]
		switch {
		case a.Event == "firing" && released[a.FindingKey] != "":
			a.Detail = strings.TrimPrefix(a.Detail+"; "+released[a.FindingKey], "; ")
		case a.Event == "resolved" && a.FirstSentAt != nil && len(under[threadKey(a.FindingKey, *a.FirstSentAt)]) > 0:
			list := under[threadKey(a.FindingKey, *a.FirstSentAt)]
			more := ""
			if len(list) > 5 {
				list, more = list[:5], fmt.Sprintf(" and %d more", len(list)-5)
			}
			a.Detail = strings.TrimPrefix(a.Detail+"; attached while it stood: "+strings.Join(list, ", ")+more, "; ")
		}
	}
	return nil
}

// attachedNotices (task 403b K4) posts, on a Slack bot channel, one reply in the anchor's thread per alert held
// attached under it this pass that was not shown yet (at most slackReplies a pass), and marks each shown (0154's
// alert_attached_noticed). An anchor whose thread is not known shows nothing here: its recovery lists them. A reply
// Slack refuses as a reply (the thread is locked or takes none) is marked shown too: the recovery still lists it. Any
// other failure goes in the result's errors and ends the notices for this pass; it never counts as the channel's
// failure. It returns an error only when the repository failed.
func (c *Channel) attachedNotices(ctx context.Context, conn *pgxpool.Conn, th threader, now time.Time, res *Result) error {
	rows, err := conn.Query(ctx, `SELECT d.finding_key, d.instance_id, coalesce(d.instance_name, ''), coalesce(d.severity, 'warning'),
	       coalesce(d.source, ''), coalesce(d.setting, ''), coalesce(d.value, ''), coalesce(d.detail, ''), t.ts
	  FROM pgvigil.alert_held d
	  JOIN pgvigil.alert_threads t
	    ON t.channel = d.channel AND t.finding_key = d.anchor_key AND t.first_sent_at = d.anchor_first_sent_at AND t.slack_channel = $2
	 WHERE d.hold_kind = 'attached' AND d.channel = $1 AND d.noticed_at IS NULL AND d.last_at >= $3
	 ORDER BY d.first_at LIMIT $4`, c.Name, th.slackChannel(), now, slackReplies)
	if err != nil {
		return err
	}
	type notice struct {
		a  Alert
		ts string
	}
	var ns []notice
	for rows.Next() {
		var n notice
		if err := rows.Scan(&n.a.FindingKey, &n.a.InstanceID, &n.a.Instance, &n.a.Severity, &n.a.Source, &n.a.Setting, &n.a.Value, &n.a.Detail, &n.ts); err != nil {
			rows.Close()
			return err
		}
		n.a.Event = "attached"
		ns = append(ns, n)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	var done []string
	for _, n := range ns {
		m := Message{Channel: c.Name, SentAt: now.UTC(), Alerts: []Alert{n.a}, Subject: "pgvigil: attached under this alert (no page while it stands)"}
		sctx, cancel := context.WithTimeout(ctx, sendTimeout)
		err := th.reply(sctx, m, n.ts, false)
		cancel()
		if err != nil {
			res.Errors = append(res.Errors, c.Name+": an attached alert's reply: "+err.Error())
			if threadRefused(err) {
				done = append(done, n.a.FindingKey) // the thread takes no reply: shown by the anchor's recovery instead
				continue
			}
			break
		}
		done = append(done, n.a.FindingKey)
	}
	if len(done) > 0 {
		if _, err := conn.Exec(context.WithoutCancel(ctx), `SELECT pgvigil.alert_attached_noticed($1, $2, $3)`, now, c.Name, done); err != nil {
			return err
		}
	}
	return nil
}

// threadKey names one occurrence's thread: its finding key and its first send.
func threadKey(key string, first time.Time) string {
	return key + "\x00" + first.UTC().Format(time.RFC3339Nano)
}

// sendThreaded sends a Slack bot channel's owed alerts (task 403b K2): the threads its open alerts have are read for
// the channel's Slack channel; an alert without one (a new firing, or a state that predates the channel) goes in a
// top-level post of at most slackPerPost alerts, the others as one reply each in their thread (an escalation broadcast
// to the channel, a repeat and the recovery in the thread only). Urgent ones go first (escalated and critical), the
// posts before the replies, at most slackReplies replies a pass (the rest stay owed: nothing is recorded for them).
// A reply Slack refuses as a reply goes as a new post. Each send is its own attempt; a post's threads are written with
// it. A failed send ends the channel's pass, as for every channel. It returns the channel's outcome and an error only
// when the repository failed.
func (c *Channel) sendThreaded(ctx context.Context, conn *pgxpool.Conn, th threader, send []Alert, now time.Time, res *Result) (error, error) {
	known := map[string]string{}
	var keys []string
	for _, a := range send {
		if a.FirstSentAt != nil && a.Event != "firing" {
			keys = append(keys, a.FindingKey)
		}
	}
	withThreads := true
	if err := conn.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.alert_record_threads(timestamp with time zone, jsonb, jsonb)') IS NOT NULL`).Scan(&withThreads); err != nil {
		return nil, err
	}
	if withThreads && len(keys) > 0 {
		rows, err := conn.Query(ctx, `SELECT finding_key, first_sent_at, ts FROM pgvigil.alert_threads
		     WHERE channel = $1 AND slack_channel = $2 AND finding_key = ANY($3)`, c.Name, th.slackChannel(), keys)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var k, ts string
			var first time.Time
			if err := rows.Scan(&k, &first, &ts); err != nil {
				rows.Close()
				return nil, err
			}
			known[threadKey(k, first)] = ts
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	type reply struct {
		a  Alert
		ts string
	}
	var posts []Alert
	var replies []reply
	for _, a := range send {
		if a.FirstSentAt != nil && a.Event != "firing" {
			if ts, ok := known[threadKey(a.FindingKey, *a.FirstSentAt)]; ok {
				replies = append(replies, reply{a, ts})
				continue
			}
		}
		posts = append(posts, a)
	}
	urgent := func(a Alert) bool {
		return a.Event == "escalated" || (a.Severity == "critical" && a.Event != "resolved")
	}
	sort.SliceStable(posts, func(i, j int) bool { return urgent(posts[i]) && !urgent(posts[j]) })
	sort.SliceStable(replies, func(i, j int) bool { return urgent(replies[i].a) && !urgent(replies[j].a) })
	// note records one send's attempt (with the threads a post opened) and counts it
	note := func(items []Alert, sendErr error, ts string) error {
		at := attempt{Channel: c.Name, Kind: c.Kind, Destination: c.Destination(), Outcome: "sent", Items: items}
		if sendErr != nil {
			at.Outcome, at.Error = "failed", sendErr.Error()
			var re *refusedError
			if errors.As(sendErr, &re) {
				at.Outcome = "refused"
			}
			res.Failed += len(items)
			res.Errors = append(res.Errors, c.Name+": "+sendErr.Error())
		} else {
			res.Sent += len(items)
		}
		var threads []map[string]string
		if sendErr == nil && ts != "" && withThreads {
			for _, a := range items {
				if a.Event != "resolved" {
					threads = append(threads, map[string]string{"finding_key": a.FindingKey, "slack_channel": th.slackChannel(), "ts": ts})
				}
			}
		}
		if len(threads) == 0 {
			return record(context.WithoutCancel(ctx), conn.Exec, time.Now(), at)
		}
		pay, _ := json.Marshal(at)
		tj, _ := json.Marshal(threads)
		_, err := conn.Exec(context.WithoutCancel(ctx), `SELECT pgvigil.alert_record_threads($1, $2::jsonb, $3::jsonb)`, time.Now(), string(pay), string(tj))
		return err
	}
	for i := 0; i < len(posts); i += slackPerPost {
		batch := posts[i:min(i+slackPerPost, len(posts))]
		sctx, cancel := context.WithTimeout(ctx, sendTimeout)
		ts, err := th.post(sctx, Message{Channel: c.Name, SentAt: now.UTC(), Alerts: batch, Subject: c.subject(batch)})
		cancel()
		if rerr := note(batch, err, ts); rerr != nil {
			return nil, rerr
		}
		if err != nil {
			return err, nil // the destination failed: the rest waits for the next pass
		}
	}
	for n, r := range replies {
		if n >= slackReplies {
			break // owed: the next pass sends them
		}
		m := Message{Channel: c.Name, SentAt: now.UTC(), Alerts: []Alert{r.a}, Subject: c.subject([]Alert{r.a})}
		sctx, cancel := context.WithTimeout(ctx, sendTimeout)
		err := th.reply(sctx, m, r.ts, r.a.Event == "escalated")
		cancel()
		ts := ""
		if err != nil && threadRefused(err) {
			// the thread takes no reply: the alert opens a new one, on its own time (the reply may have spent its
			// own on Retry-After waits)
			pctx, pcancel := context.WithTimeout(ctx, sendTimeout)
			ts, err = th.post(pctx, m)
			pcancel()
		}
		if rerr := note(m.Alerts, err, ts); rerr != nil {
			return nil, rerr
		}
		if err != nil {
			return err, nil
		}
	}
	return nil, nil
}

// recordQuota stores a destination's quota as its last answer gave it (0154's alert_channel_quota_put); a repository
// before 0154 has no such function, and the quota goes unrecorded without an error.
func recordQuota(ctx context.Context, conn rowQuerier, now time.Time, channel string, q *channelQuota) error {
	var have bool
	if err := conn.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.alert_channel_quota_put(timestamp with time zone, text, integer, integer, timestamp with time zone)') IS NOT NULL`).Scan(&have); err != nil || !have {
		return err
	}
	var done bool
	return conn.QueryRow(ctx, `SELECT true FROM (SELECT pgvigil.alert_channel_quota_put($1, $2, $3, $4, $5)) x`,
		now, channel, q.Remaining, q.Limit, q.Reset).Scan(&done)
}

func batches(a []Alert, perAlert bool) [][]Alert { return batchesWithin(a, perAlert, 0) }

// batchesWithin cuts the alerts into messages of at most maxPerMessage (1 for a per-alert sender) whose lines, one
// newline each, stay within budget bytes (0 = no budget); a message always carries at least one alert.
func batchesWithin(a []Alert, perAlert bool, budget int) [][]Alert {
	return batchesCost(a, perAlert, budget, nil)
}

// batchesCost is batchesWithin with each alert costing cost(a) bytes of the budget (nil = its line and a newline).
func batchesCost(a []Alert, perAlert bool, budget int, cost func(Alert) int) [][]Alert {
	if cost == nil {
		cost = func(x Alert) int { return len(x.Line()) + 1 }
	}
	n := maxPerMessage
	if perAlert {
		n = 1
	}
	var out [][]Alert
	for len(a) > 0 {
		k, used := 0, 0
		for k < len(a) && k < n {
			l := cost(a[k])
			if budget > 0 && k > 0 && used+l > budget {
				break
			}
			used += l
			k++
		}
		out = append(out, a[:k])
		a = a[k:]
	}
	return out
}

// capHold keeps in *send what the channel's max_per_hour still allows in the hour before now (its sent alerts as the
// log records them) and returns the rest, held: firing and escalated first, the critical ones first among them, then
// the recoveries, then the repeats.
func (c *Channel) capHold(ctx context.Context, q rowQuerier, now time.Time, send *[]Alert) ([]Alert, error) {
	var used int
	if err := q.QueryRow(ctx, `SELECT coalesce(sum(n_firing + n_repeat + n_resolved), 0)::int FROM pgvigil.alert_log
	   WHERE channel = $1 AND outcome = 'sent' AND snapshot_at > $2::timestamptz - interval '1 hour'`,
		c.Name, now).Scan(&used); err != nil {
		return nil, fmt.Errorf("max_per_hour: %w", err)
	}
	left := max(c.MaxPerHour-used, 0)
	if len(*send) <= left {
		return nil, nil
	}
	s := append([]Alert(nil), *send...)
	order := func(a Alert) int {
		switch a.Event {
		case "firing", "escalated":
			return 3 - rank(a.Severity) // 0 critical, 1 warning, 2 info
		case "resolved", "cleared":
			return 3
		}
		return 4
	}
	sort.SliceStable(s, func(i, j int) bool { return order(s[i]) < order(s[j]) })
	*send = s[:left]
	return s[left:], nil
}

func utc(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	u := t.UTC()
	return &u
}

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// storeKindRE reads a kind out of alert_channels_kind_check's definition (CHECK ((kind = ANY (ARRAY['smtp'::text, ...]))).
var storeKindRE = regexp.MustCompile(`'([a-z0-9_]+)'::text`)

// storeKinds is the channel kinds the repository's alert_channels takes (nil: no kind check found, nothing filtered).
func storeKinds(ctx context.Context, conn rowQuerier) (map[string]bool, error) {
	var def string
	err := conn.QueryRow(ctx, `SELECT coalesce((SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
	     WHERE c.conrelid = 'pgvigil.alert_channels'::regclass AND c.conname = 'alert_channels_kind_check'), '')`).Scan(&def)
	if err != nil || def == "" {
		return nil, err
	}
	out := map[string]bool{}
	for _, m := range storeKindRE.FindAllStringSubmatch(def, -1) {
		out[m[1]] = true
	}
	if len(out) == 0 {
		return nil, nil
	}
	return out, nil
}

func syncChannels[T any](ctx context.Context, exec func(context.Context, string, ...any) (T, error), chs []Channel, now time.Time) error {
	rows := make([]map[string]any, 0, len(chs))
	for i := range chs {
		c := &chs[i]
		rows = append(rows, map[string]any{"name": c.Name, "kind": c.Kind, "destination": c.Destination(),
			"min_severity": c.MinSeverity, "instances": nonNil(c.Instances), "tags": nonNil(c.Tags),
			"quiet_hours": c.QuietHours, "timezone": c.Timezone, "repeat_secs": int(c.RepeatEvery().Seconds()),
			"clear_after_secs": int(c.ClearAfterEvery().Seconds()), "recovery": c.SendsRecovery(),
			"max_per_hour": c.MaxPerHour, "templates": c.tpl.words(), "link_base": c.base})
	}
	pay, _ := json.Marshal(rows)
	_, err := exec(ctx, `SELECT pgvigil.alert_channels_sync($1, $2::jsonb)`, now, string(pay))
	return err
}

type attempt struct {
	Channel     string  `json:"channel,omitempty"`
	Kind        string  `json:"kind,omitempty"`
	Destination string  `json:"destination,omitempty"`
	Outcome     string  `json:"outcome"`
	Error       string  `json:"error,omitempty"`
	Items       []Alert `json:"items"`
}

func record[T any](ctx context.Context, exec func(context.Context, string, ...any) (T, error), at time.Time, a attempt) error {
	if a.Items == nil {
		a.Items = []Alert{}
	}
	pay, _ := json.Marshal(a)
	_, err := exec(ctx, `SELECT pgvigil.alert_record($1, $2::jsonb)`, at, string(pay))
	return err
}

// textPolicy is each instance's query_text policy now, by its name (TEXT-NOW): the process that sends sets it - serve
// from its doors, `pgvigil run` and `pgvigil alerts` from the configuration file; unset = the text as stored.
var textPolicy atomic.Pointer[func(string) string]

// SetTextPolicy sets the policy the sends follow.
func SetTextPolicy(f func(instance string) string) { textPolicy.Store(&f) }

// PolicyOfConfig is a configuration file's policies: an instance's own query_text, else the file's (an instance the
// file does not name - one added in Admin > Instances - takes the file's), else full.
func PolicyOfConfig(def string, byName map[string]string) func(string) string {
	return func(name string) string {
		if p := byName[name]; p != "" {
			return p
		}
		if def != "" {
			return def
		}
		return "full"
	}
}

func policyOf(name string) string {
	if p := textPolicy.Load(); p != nil {
		return (*p)(name)
	}
	return "full"
}

// ---- the commands ---------------------------------------------------------------------------------------------

// Once runs one pass against the repository (`pgvigil alerts`); dsn is the sender's login (Settings.DSN, else the
// repository's).
//
// With no channel there is nothing to send: the pass only records the 'none' row, and a login that may not write it
// (the collector's, on an install without alerts_dsn) is no error: nothing was sent either way.
func Once(ctx context.Context, dsn string, chs []Channel) (Result, error) {
	pool, err := pxpool(ctx, dsn)
	if err != nil {
		return Result{}, err
	}
	defer pool.Close()
	res, _, err := Pass(ctx, pool, chs, time.Now(), nil)
	var pe *pgconn.PgError
	if err != nil && len(chs) == 0 && errors.As(err, &pe) && pe.Code == "42501" {
		return res, nil
	}
	return res, err
}

// Every is the loop's cadence inside `pgvigil run`.
const Every = time.Minute

// maxBackoff caps how long a failing channel waits before the next try.
const maxBackoff = 30 * time.Minute

// logPass logs one pass of Run: its result when something moved, and each part it could not read - on a quiet pass
// too, where nothing else would say it.
func logPass(log *slog.Logger, res Result, err error) {
	switch {
	case err != nil:
		log.Warn("alerts pass failed", "err", err)
	case res.Sent+res.Failed+res.Cleared+res.Capped+res.Tests > 0:
		log.Info("alerts pass", "result", res.String())
	}
	if res.RulesErr != nil {
		log.Warn("alerts: the alert rules were not judged in this pass", "err", res.RulesErr)
	}
	if res.TestsErr != nil {
		log.Warn("alerts: the Send test requests were not read in this pass", "err", res.TestsErr)
	}
	if res.RoutesErr != nil {
		log.Warn("alerts: the contact routes were not read in this pass", "err", res.RoutesErr)
	}
}

// Run is the loop inside `pgvigil run`: a pass every minute until ctx ends. With no channel it logs "alerts off" and
// returns without touching the repository: nothing is ever sent, and the collector's login needs no alert right.
func Run(ctx context.Context, log *slog.Logger, dsn string, chs []Channel) error {
	if len(chs) == 0 {
		log.Info("alerts off: no channel configured, nothing is sent")
		return nil
	}
	var pool *pgxpool.Pool
	for pool == nil {
		p, err := pxpool(ctx, dsn)
		if err == nil {
			pool = p
			break
		}
		log.Warn("alerts: repository not reachable, retrying in 1m", "err", err)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(time.Minute):
		}
	}
	defer pool.Close()
	log.Info("alerts started", "channels", len(chs))
	for i := range chs {
		if chs[i].PlainByOptIn() {
			log.Warn("alerts: a channel sends plain text off loopback by allow_plain (an admin's opt-in)", "channel", chs[i].Name, "destination", chs[i].Destination())
		}
	}
	type back struct {
		fails int
		until time.Time
	}
	backoff := map[string]*back{}
	t := time.NewTicker(Every)
	defer t.Stop()
	for {
		now := time.Now()
		skip := map[string]bool{}
		for n, b := range backoff {
			if now.Before(b.until) {
				skip[n] = true
			}
		}
		res, outcome, err := Pass(ctx, pool, chs, now, skip)
		logPass(log, res, err)
		for n, e := range outcome {
			if e == nil {
				delete(backoff, n)
				continue
			}
			b := backoff[n]
			if b == nil {
				b = &back{}
				backoff[n] = b
			}
			b.fails++
			wait := min(time.Minute<<min(b.fails-1, 5), maxBackoff)
			b.until = now.Add(wait)
			log.Warn("alerts: channel failed", "channel", n, "err", e, "next_try", wait)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

func pxpool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("alerts: repository dsn: %w", err)
	}
	cfg.MaxConns = 2
	if cfg.ConnConfig.RuntimeParams == nil {
		cfg.ConnConfig.RuntimeParams = map[string]string{}
	}
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil alerts"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

// hostOf returns the host of a URL for the destination shown in the UI.
func hostOf(u *url.URL) string { return u.Scheme + "://" + u.Host }
