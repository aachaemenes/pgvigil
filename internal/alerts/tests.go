package alerts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Send test (task 151, K07.06): the Alerts page asks for a test message on one channel through the actions door
// (pgvigil.import_alert_test, migration 0093: the UI login and the audit login, as an acknowledgement); the sender's
// next pass reads the requests owed (pgvigil.alert_tests_due: asked in the last hour, not yet answered), sends each to
// its channel when this configuration names the channel, and records the answer (pgvigil.alert_test_record) beside an
// alert_log row of outcome 'test' (or 'failed' / 'refused' with the destination's error). The serve process never
// holds a channel's secret: the sender, which already holds it, does the send. A test goes out inside quiet hours,
// a back-off or a max_per_hour cap (a person is waiting for the answer); PagerDuty and Opsgenie get the test and its
// resolve at once, so no incident stays open.

// testQuerier is what runTests calls: a pool connection in a pass, a fake in the tests.
type testQuerier interface {
	rowQuerier
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

type testRequest struct {
	id          int64
	channel, by string
	at          time.Time
}

// testAlerts is the message a test sends: one 'test' alert, and on an incident kind its resolve.
func testAlerts(c *Channel, t testRequest) []Alert {
	key := fmt.Sprintf("test-%d", t.id)
	a := Alert{Event: "test", FindingKey: key, Instance: "pgvigil", Severity: "info", Source: "pgvigil", Setting: "test message",
		Value: fmt.Sprintf("a test message on channel %s, asked by %s at %s UTC; nothing is wrong", c.Name, t.by, t.at.UTC().Format("2006-01-02 15:04:05"))}
	if c.base != "" {
		a.URL = c.base + "/#/alerts"
	}
	out := []Alert{a}
	if incidentKind(c.Kind) {
		r := a
		r.Event = "resolved"
		out = append(out, r)
	}
	return out
}

// runTests answers the Send test requests owed to the channels of chs; nil when there is none or the repository
// predates 0093 (no such function).
func runTests(ctx context.Context, conn testQuerier, chs []Channel, now time.Time, res *Result) error {
	var have bool
	if err := conn.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.alert_tests_due(timestamp with time zone)') IS NOT NULL`).Scan(&have); err != nil {
		return err
	}
	if !have {
		return nil
	}
	rows, err := conn.Query(ctx, `SELECT test_id, channel, requested_by, requested_at FROM pgvigil.alert_tests_due($1)`, now)
	if err != nil {
		return err
	}
	var due []testRequest
	for rows.Next() {
		var t testRequest
		if err := rows.Scan(&t.id, &t.channel, &t.by, &t.at); err != nil {
			rows.Close()
			return err
		}
		due = append(due, t)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	byName := map[string]*Channel{}
	for i := range chs {
		byName[chs[i].Name] = &chs[i]
	}
	for _, t := range due {
		c := byName[t.channel]
		if c == nil {
			continue // another collector's channel: it answers
		}
		alerts := testAlerts(c, t)
		var serr error
		for _, batch := range batches(alerts, c.sender.perAlert()) {
			sctx, cancel := context.WithTimeout(ctx, sendTimeout)
			serr = c.sender.send(sctx, Message{Channel: c.Name, SentAt: now.UTC(), Alerts: batch})
			cancel()
			if serr != nil {
				break
			}
		}
		out, msg := "sent", ""
		if serr != nil {
			out, msg = "failed", serr.Error()
			var re *refusedError
			if errors.As(serr, &re) {
				out = "refused"
			}
			res.TestsFailed++
		}
		res.Tests++
		logOut := "test"
		if out != "sent" {
			logOut = out
		}
		if err := record(context.WithoutCancel(ctx), conn.Exec, time.Now(), attempt{Channel: c.Name, Kind: c.Kind,
			Destination: c.Destination(), Outcome: logOut, Error: msg, Items: alerts[:1]}); err != nil {
			return err
		}
		if _, err := conn.Exec(context.WithoutCancel(ctx), `SELECT pgvigil.alert_test_record($1, $2, $3, $4)`, time.Now(), t.id, out, msg); err != nil {
			return err
		}
	}
	return nil
}
