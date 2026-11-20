package alerts

import (
	"context"
	"errors"
	"fmt"
	"net/mail"
	"net/textproto"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Owner-routed alerts (task 310, migration 0136): an application's contact receives the
// alerts of its application's instances through a route, chosen on Admin > Applications - a configured smtp channel
// (its relay and secrets stay in the configuration file) and a minimum severity. Each pass reads the live routes
// through the store's one door (pgvigil.alert_contact_routes, the sender's or the owner's session only) and makes one
// DERIVED channel per route, named 'contact-<route_id>': a copy of the base's built channel with to: the contact's
// address, its scope the application's tag alone (the base's instances: and tags: dropped), its repeat,
// clear_after, quiet hours and max_per_hour the base's, counted as its own channel. A derived channel never takes
// the repository-wide findings (collector or network, purge): those stay the configured channels'. No address leaves
// the derived channel: its destination text names the contact's id, and every error has the address replaced by
// 'contact <id>' before it is logged or stored.

// routePrefix starts every derived channel's name; Validate refuses a configured channel named so.
const routePrefix = "contact-"

// route is one live route as the door answers it.
type route struct {
	ID, ContactID                      int
	Role, App, Channel, Severity, Mail string
}

// derived is a route's channel, or why the route sends nothing this pass (note != "").
type derived struct {
	ch   Channel
	note string
}

// readRoutes asks the door for the live routes. have is false on a repository before 0136 (no door: no route, no
// error); a door that fails returns its error, and the pass then closes nothing (a route gone is only known from a
// door that answered).
func readRoutes(ctx context.Context, q *pgxpool.Conn) (rs []route, have bool, err error) {
	if err := q.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.alert_contact_routes()') IS NOT NULL`).Scan(&have); err != nil || !have {
		return nil, false, err
	}
	rows, err := q.Query(ctx, `SELECT route_id, contact_id, role, application, channel_name, coalesce(min_severity, ''), email
	  FROM pgvigil.alert_contact_routes()`)
	if err != nil {
		return nil, true, err
	}
	defer rows.Close()
	for rows.Next() {
		var r route
		if err := rows.Scan(&r.ID, &r.ContactID, &r.Role, &r.App, &r.Channel, &r.Severity, &r.Mail); err != nil {
			return nil, true, err
		}
		rs = append(rs, r)
	}
	return rs, true, rows.Err()
}

// derive makes each route's channel from its base among chs (the configuration's, built): a route whose base is not
// configured, is not an smtp channel, or whose address Go's mail parser refuses sends nothing and says why.
func derive(chs []Channel, rs []route) []derived {
	base := map[string]*Channel{}
	for i := range chs {
		base[chs[i].Name] = &chs[i]
	}
	out := make([]derived, 0, len(rs))
	for _, r := range rs {
		name := routePrefix + strconv.Itoa(r.ID)
		who := fmt.Sprintf("contact %d (%s of %s)", r.ContactID, r.Role, r.App)
		b, ok := base[r.Channel]
		switch {
		case !ok:
			out = append(out, derived{ch: Channel{Name: name, Kind: "smtp"}, note: fmt.Sprintf("route of %s: channel %s is not configured: nothing sent", who, r.Channel)})
			continue
		case b.Kind != "smtp":
			out = append(out, derived{ch: Channel{Name: name, Kind: b.Kind}, note: fmt.Sprintf("route of %s: channel %s is not an smtp channel: nothing sent", who, r.Channel)})
			continue
		}
		s, ok := b.sender.(*smtpSender)
		if !ok {
			out = append(out, derived{ch: Channel{Name: name, Kind: "smtp"}, note: fmt.Sprintf("route of %s: channel %s is not built: nothing sent", who, r.Channel)})
			continue
		}
		a, err := mail.ParseAddress(r.Mail)
		if err != nil {
			out = append(out, derived{ch: Channel{Name: name, Kind: "smtp"}, note: fmt.Sprintf("route of %s: its e-mail address is refused by the mail parser: nothing sent", who)})
			continue
		}
		c := *b // the base as built: its quiet hours, zone, templates and link base; its secrets never read again
		c.Name = name
		c.Instances = nil
		c.Tags = []string{"application:" + r.App}
		if r.Severity != "" {
			c.MinSeverity = r.Severity
		}
		cp := *s
		cp.to = []string{a.Address}
		c.sender = &routeSender{smtp: &cp, contact: r.ContactID, addr: a.Address, raw: r.Mail,
			dest: fmt.Sprintf("smtp://%s to contact %d (%s of %s) through %s", s.addr, r.ContactID, r.Role, r.App, b.Name)}
		out = append(out, derived{ch: c})
	}
	return out
}

// routeSender is the base's smtp sender mailing one contact: its destination text and its errors never name the address.
type routeSender struct {
	smtp      *smtpSender
	contact   int
	addr, raw string
	dest      string
}

func (r *routeSender) destination() string { return r.dest }
func (r *routeSender) perAlert() bool      { return false }
func (r *routeSender) send(ctx context.Context, m Message) error {
	err := r.smtp.send(ctx, m)
	if err == nil {
		return nil
	}
	// a relay's reply is its own words, which may name the recipient in any form (rewritten, the local part alone):
	// only its code and its enhanced status code are kept
	var tpe *textproto.Error
	if errors.As(err, &tpe) {
		code := strconv.Itoa(tpe.Code)
		if f := strings.Fields(tpe.Msg); len(f) > 0 && enhancedStatus.MatchString(f[0]) {
			code += " " + f[0]
		}
		return fmt.Errorf("the relay answered %s for contact %d (its words left out: they may name the address)", code, r.contact)
	}
	msg := scrub(err.Error(), fmt.Sprintf("contact %d", r.contact), r.addr, r.raw)
	var re *refusedError
	if errors.As(err, &re) {
		return &refusedError{msg}
	}
	return errors.New(msg)
}

// enhancedStatus is an SMTP enhanced status code (RFC 3463: class.subject.detail): digits and dots, no address.
var enhancedStatus = regexp.MustCompile(`^[245]\.[0-9]{1,3}\.[0-9]{1,3}$`)

// scrub replaces each address in s (any case) by its stand-in.
func scrub(s, with string, addrs ...string) string {
	for _, a := range addrs {
		if a == "" {
			continue
		}
		s = regexp.MustCompile(`(?i)`+regexp.QuoteMeta(a)).ReplaceAllLiteralString(s, with)
	}
	return s
}

// routeNotes records each route's note in the log once - when it differs from that channel's last row there (a
// note standing pass after pass is logged once, not every minute).
func routeNotes(ctx context.Context, conn *pgxpool.Conn, now time.Time, ds []derived) error {
	for _, d := range ds {
		if d.note == "" {
			continue
		}
		var last string
		// the last row that is not a close: closeGone's 'cleared' row of the same pass ties on snapshot_at
		err := conn.QueryRow(ctx, `SELECT coalesce((SELECT l.error FROM pgvigil.alert_log l WHERE l.channel = $1
		  AND l.outcome <> 'cleared' ORDER BY l.snapshot_at DESC LIMIT 1), '')`, d.ch.Name).Scan(&last)
		if err != nil {
			return err
		}
		if last == d.note {
			continue
		}
		if err := record(ctx, conn.Exec, now, attempt{Channel: d.ch.Name, Kind: d.ch.Kind, Outcome: "none", Error: d.note}); err != nil {
			return err
		}
	}
	return nil
}

// closeGone closes, with no message, the open alert rows of every derived channel that is no longer a live route
// (turned off, removed, its contact or its base gone): called only when the door answered.
func closeGone(ctx context.Context, conn *pgxpool.Conn, now time.Time, live map[string]bool) (int, error) {
	rows, err := conn.Query(ctx, `SELECT channel, finding_key, instance_id, instance_name, severity, coalesce(source, ''),
	       coalesce(setting, ''), coalesce(value, '') FROM pgvigil.alert_state
	 WHERE cleared_at IS NULL AND channel LIKE 'contact-%' ORDER BY channel, finding_key`)
	if err != nil {
		return 0, err
	}
	gone := map[string][]Alert{}
	var order []string
	for rows.Next() {
		var ch string
		var a Alert
		if err := rows.Scan(&ch, &a.FindingKey, &a.InstanceID, &a.Instance, &a.Severity, &a.Source, &a.Setting, &a.Value); err != nil {
			rows.Close()
			return 0, err
		}
		if live[ch] {
			continue
		}
		a.Event = "cleared"
		if _, ok := gone[ch]; !ok {
			order = append(order, ch)
		}
		gone[ch] = append(gone[ch], a)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	n := 0
	for _, ch := range order {
		if err := record(ctx, conn.Exec, now, attempt{Channel: ch, Kind: "smtp", Outcome: "cleared", Items: gone[ch],
			Error: "the route is gone (turned off or removed, or its contact): closed with no message"}); err != nil {
			return n, err
		}
		n += len(gone[ch])
	}
	return n, nil
}
