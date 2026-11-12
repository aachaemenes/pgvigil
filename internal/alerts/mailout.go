package alerts

import (
	"context"
	"errors"
	"time"
)

// The report mail's doors (task 171, internal/reportmail), on the sender's side: a whole message the caller built,
// mailed through an smtp channel's relay with the channel's TLS, login and from; and a notice (a report mail that
// failed) sent at once on any channel as an alert line, outside a pass (no state, no repeat).

// MailFrom is an smtp channel's from address; "" for another kind.
func (c *Channel) MailFrom() string {
	if s, ok := c.sender.(*smtpSender); ok {
		return s.from
	}
	return ""
}

// Mail sends msg (its headers and body, CRLF lines) to the addresses through the channel's relay.
func (c *Channel) Mail(ctx context.Context, to []string, msg []byte) error {
	s, ok := c.sender.(*smtpSender)
	if !ok {
		return errors.New("channel " + c.Name + " is not an smtp channel")
	}
	if len(to) == 0 {
		return errors.New("no address to mail")
	}
	cp := *s
	cp.to = to
	return cp.sendRaw(ctx, msg)
}

// Notify sends alerts on the channel now: one message, or one per alert on a per-alert kind. On an incident kind
// (PagerDuty, Opsgenie) each is resolved at once, as a Send test is: a notice opens no incident that nothing closes.
func (c *Channel) Notify(ctx context.Context, items []Alert, now time.Time) error {
	if c.sender == nil {
		return errors.New("channel " + c.Name + " is not built")
	}
	if incidentKind(c.Kind) {
		var both []Alert
		for _, a := range items {
			r := a
			r.Event = "resolved"
			both = append(both, a, r)
		}
		items = both
	}
	for _, batch := range batches(items, c.sender.perAlert()) {
		sctx, cancel := context.WithTimeout(ctx, sendTimeout)
		err := c.sender.send(sctx, Message{Channel: c.Name, SentAt: now.UTC(), Alerts: batch})
		cancel()
		if err != nil {
			return err
		}
	}
	return nil
}
