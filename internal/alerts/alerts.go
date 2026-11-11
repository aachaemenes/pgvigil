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
//	    kind: smtp                   # smtp | webhook | file | pagerduty
//	    min_severity: warning        # info | warning (default) | critical
//	    instances: [erp01]           # optional; instances: and tags: empty = every instance
//	    tags: [env:prod]             # optional; a tag in its written form (prod, env:prod)
//	    quiet_hours: "22:00-07:00"   # optional: nothing is sent inside it; what is owed goes out when it ends
//	    timezone: America/Chicago    # the quiet hours' zone (default UTC)
//	    repeat: 24h                  # a standing finding is sent again after this (default 24h; disabled = once)
//	    recovery: true               # a message when the finding clears (default true)
//	    clear_after: 10m             # a finding gone this long is resolved (default 10m; 0 = at the first pass)
//	    smtp: {host: relay.example.org, port: 587, tls: starttls, username: env:U, password: file:/p, from: a@b, to: [c@d]}
//	    webhook: {url: env:TEAMS_URL, format: teams}   # teams | slack | json; the URL through env: or file: only
//	    file: {dir: /var/spool/pgvigil/alerts}
//	    pagerduty: {routing_key: env:PD_KEY}            # Events API v2; one incident per finding, resolved when it clears
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
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"gopkg.in/yaml.v3"

	"github.com/aachaemenes/pgvigil/internal/config"
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

	quiet  *quiet
	loc    *time.Location
	sender sender
}

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

// Settings is what the configuration file says about alerts: the channels and the sender's login.
type Settings struct {
	DSNRaw   string    `yaml:"alerts_dsn"`
	Channels []Channel `yaml:"alerts"`
}

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
	if v := strings.TrimSpace(s.DSNRaw); v != "" && (strings.HasPrefix(v, "env:") || strings.HasPrefix(v, "file:")) && s.DSN() == "" {
		return nil, fmt.Errorf("alerts_dsn %s is empty or unreadable", v)
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
	blocks := 0
	for _, set := range []bool{c.SMTP != nil, c.Webhook != nil, c.File != nil, c.PagerDuty != nil} {
		if set {
			blocks++
		}
	}
	if blocks != 1 {
		return errors.New("exactly one of smtp:, webhook:, file: or pagerduty: is required")
	}
	var err error
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
	default:
		return fmt.Errorf("kind must be smtp, webhook, file or pagerduty (got %q)", c.Kind)
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
}

// Message is what one send carries.
type Message struct {
	Channel string    `json:"channel"`
	SentAt  time.Time `json:"sent_at"`
	Alerts  []Alert   `json:"alerts"`
}

// Summary is the one-line headline of a message.
func (m Message) Summary() string {
	var firing, repeat, resolved, crit int
	for _, a := range m.Alerts {
		switch a.Event {
		case "firing", "escalated":
			firing++
		case "repeat":
			repeat++
		default:
			resolved++
		}
		if a.Severity == "critical" && a.Event != "resolved" {
			crit++
		}
	}
	parts := []string{}
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

// Line is one alert as a line of text, at most maxLine bytes.
func (a Alert) Line() string {
	s := a.line()
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

// sender delivers one message to one channel's destination.
type sender interface {
	send(ctx context.Context, m Message) error
	destination() string
	perAlert() bool // true: one message per alert (the file drop)
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
	Skipped  bool     // another sender held the lock
	Errors   []string // channel: error
	// RulesFiring is how many alert rule rows (a rule on one instance and series) fire after this pass's evaluation.
	RulesFiring int
	// RulesErr is why the alert rules were not judged in this pass (the summary line says it; Errors stays the
	// channels'); nil = judged, or a repository before 0085.
	RulesErr error
}

func (r Result) String() string {
	if r.Skipped {
		return "another alert sender is running: nothing done"
	}
	s := fmt.Sprintf("%d channel(s): %d alert(s) sent, %d failed, %d cleared", r.Channels, r.Sent, r.Failed, r.Cleared)
	if len(r.Held) > 0 {
		s += "; quiet hours: " + strings.Join(r.Held, ", ")
	}
	if r.RulesFiring > 0 {
		s += fmt.Sprintf("; %d alert rule row(s) firing", r.RulesFiring)
	}
	if r.RulesErr != nil {
		s += "; alert rules not judged: " + strings.Join(strings.Fields(r.RulesErr.Error()), " ")
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
	if err := syncChannels(ctx, conn.Exec, chs, now); err != nil {
		return res, nil, err
	}
	// the rules are judged before the quiet-hours cut: a channel in its quiet hours is owed what fired meanwhile when
	// they end. A failure here (or the server's cut at rulesTimeout) costs this pass's fresh rule states only: the
	// findings, and the rule alerts as last judged, still go out.
	if n, err := evalRules(ctx, conn, now); err != nil {
		res.RulesErr = err
	} else {
		res.RulesFiring = n
	}
	var due []map[string]any
	byName := map[string]*Channel{}
	for i := range chs {
		c := &chs[i]
		byName[c.Name] = c
		if c.Quiet(now) {
			res.Held = append(res.Held, c.Name)
			continue
		}
		if skip[c.Name] {
			continue
		}
		due = append(due, map[string]any{"name": c.Name, "min_severity": c.MinSeverity, "instances": nonNil(c.Instances),
			"tags": nonNil(c.Tags), "repeat_secs": int(c.RepeatEvery().Seconds()),
			"clear_after_secs": int(c.ClearAfterEvery().Seconds()), "recovery": c.SendsRecovery()})
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
	for _, name := range order {
		c := byName[name]
		var send, cleared []Alert
		for _, a := range owed[name] {
			if a.Event == "cleared" {
				cleared = append(cleared, a)
			} else {
				send = append(send, a)
			}
		}
		if len(cleared) > 0 {
			if err := record(ctx, conn.Exec, now, attempt{Channel: c.Name, Kind: c.Kind, Destination: c.Destination(),
				Outcome: "cleared", Items: cleared}); err != nil {
				return res, outcome, err
			}
			res.Cleared += len(cleared)
		}
		var chErr error
		for _, batch := range batches(send, c.sender.perAlert()) {
			sctx, cancel := context.WithTimeout(ctx, sendTimeout)
			err := c.sender.send(sctx, Message{Channel: c.Name, SentAt: now.UTC(), Alerts: batch})
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
			if err != nil {
				break // the destination failed: the rest waits for the next pass
			}
		}
		outcome[c.Name] = chErr
	}
	for _, c := range chs {
		if _, ok := outcome[c.Name]; !ok && !c.Quiet(now) && !skip[c.Name] {
			outcome[c.Name] = nil
		}
	}
	return res, outcome, nil
}

func batches(a []Alert, perAlert bool) [][]Alert {
	n := maxPerMessage
	if perAlert {
		n = 1
	}
	var out [][]Alert
	for len(a) > 0 {
		k := min(n, len(a))
		out = append(out, a[:k])
		a = a[k:]
	}
	return out
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

func syncChannels[T any](ctx context.Context, exec func(context.Context, string, ...any) (T, error), chs []Channel, now time.Time) error {
	rows := make([]map[string]any, 0, len(chs))
	for i := range chs {
		c := &chs[i]
		rows = append(rows, map[string]any{"name": c.Name, "kind": c.Kind, "destination": c.Destination(),
			"min_severity": c.MinSeverity, "instances": nonNil(c.Instances), "tags": nonNil(c.Tags),
			"quiet_hours": c.QuietHours, "timezone": c.Timezone, "repeat_secs": int(c.RepeatEvery().Seconds()),
			"clear_after_secs": int(c.ClearAfterEvery().Seconds()), "recovery": c.SendsRecovery()})
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
		switch {
		case err != nil:
			log.Warn("alerts pass failed", "err", err)
		case res.Sent+res.Failed+res.Cleared > 0:
			log.Info("alerts pass", "result", res.String())
		}
		if res.RulesErr != nil {
			log.Warn("alerts: the alert rules were not judged in this pass", "err", res.RulesErr)
		}
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
