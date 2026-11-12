package reportmail

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

// The sender's side, inside `pgvigil run` beside the alert sender and on its login (alerts_dsn, pgvigil_alerter):
// every minute the mails owed (pgvigil.report_mail_due) are each taken (report_mail_take: a taken row is never owed
// again, so a mail is never sent twice when its record fails), read (report_mail_payload, one mail at a time), built
// (Build) and mailed through the smtp channel it names (alerts.Channel.Mail: the channel's relay, TLS, login and from),
// and the answer recorded (pgvigil.report_mail_record: sent or failed with the relay's error, the message's size; the
// payload is cleared). A mail of a channel this configuration does not name is left to the sender that does; a
// scheduled page that could not be drawn needs no relay and is answered by any sender. Then report_mail_expire answers
// as failed what no sender took within the window and what was taken and never answered.
// Every failure is alerted: a 'report mail failed' warning sent at once on every channel of the configuration
// (alerts.Channel.Notify; an incident channel's notice is resolved at once, as a Send test is), the failed one too
// (its relay may take the notice to its own addresses when only a recipient was refused).

// Every is the pass interval.
const Every = time.Minute

// lockKey is the advisory lock a pass holds: two senders never mail one row twice.
const lockKey int64 = 0x7067766961_726d // "pgvia" "rm"

// sendTimeout bounds one mail (a large workbook over a slow relay).
const sendTimeout = 2 * time.Minute

// Result counts one pass.
type Result struct {
	Sent, Failed, Notices, NoticeFailed int
}

func (r Result) String() string {
	return fmt.Sprintf("%d sent, %d failed, %d failure notices (%d of them not delivered)", r.Sent, r.Failed, r.Notices, r.NoticeFailed)
}

// conn is what Pass calls: a pooled connection, a fake in the tests.
type conn interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

type owed struct {
	id                  int64
	kind, name, channel string
	to                  []string
	subject, xname      string
	html                string
	xlsx                []byte
	renderErr, by       string
	at                  time.Time
	route               string
}

// mailer is the part of an alerts.Channel a pass uses (a fake in the tests).
type mailer interface {
	MailFrom() string
	Mail(ctx context.Context, to []string, msg []byte) error
	Notify(ctx context.Context, items []alerts.Alert, now time.Time) error
}

// Pass mails what is owed at now through chs. nil error and an empty Result when the repository predates 0107.
func Pass(ctx context.Context, c conn, chs []alerts.Channel, now time.Time) (Result, error) {
	ms := make([]namedMailer, 0, len(chs))
	for i := range chs {
		ms = append(ms, namedMailer{name: chs[i].Name, kind: chs[i].Kind, m: &chs[i]})
	}
	return pass(ctx, c, ms, now)
}

type namedMailer struct {
	name, kind string
	m          mailer
}

func pass(ctx context.Context, c conn, chs []namedMailer, now time.Time) (Result, error) {
	var res Result
	var have bool
	if err := c.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.report_mail_take(timestamp with time zone, bigint)') IS NOT NULL`).Scan(&have); err != nil {
		return res, err
	}
	if !have {
		return res, nil
	}
	rows, err := c.Query(ctx, `SELECT send_id, kind, name, channel, recipients, subject, coalesce(xlsx_name, ''), coalesce(render_error, ''),
	                                  requested_by, requested_at, route
	                             FROM pgvigil.report_mail_due($1)`, now)
	if err != nil {
		return res, err
	}
	var due []owed
	for rows.Next() {
		var o owed
		if err := rows.Scan(&o.id, &o.kind, &o.name, &o.channel, &o.to, &o.subject, &o.xname, &o.renderErr, &o.by, &o.at, &o.route); err != nil {
			rows.Close()
			return res, err
		}
		due = append(due, o)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return res, err
	}
	byName := map[string]namedMailer{}
	for _, m := range chs {
		byName[m.name] = m
	}
	for _, o := range due {
		ch, ok := byName[o.channel]
		if !ok && o.renderErr == "" {
			continue // another sender's channel: it answers
		}
		var taken bool
		if err := c.QueryRow(ctx, `SELECT pgvigil.report_mail_take($1, $2)`, time.Now(), o.id).Scan(&taken); err != nil {
			return res, err
		}
		if !taken {
			continue // another sender took it
		}
		var size int
		var serr error
		if o.renderErr != "" {
			serr = fmt.Errorf("the page could not be rendered: %s", o.renderErr)
		} else if err := c.QueryRow(ctx, `SELECT coalesce(html, ''), xlsx FROM pgvigil.report_mail_payload($1)`, o.id).Scan(&o.html, &o.xlsx); err != nil {
			serr = fmt.Errorf("the mail's body could not be read: %w", err)
		} else {
			size, serr = mailOne(ctx, ch, o, now)
		}
		out, msg := "sent", ""
		if serr != nil {
			out, msg = "failed", serr.Error()
			res.Failed++
		} else {
			res.Sent++
		}
		if _, err := c.Exec(context.WithoutCancel(ctx), `SELECT pgvigil.report_mail_record($1, $2, $3, $4, $5)`, time.Now(), o.id, out, msg, size); err != nil {
			return res, err // the row stays taken: never mailed again; report_mail_expire answers it
		}
		if serr != nil {
			notify(ctx, chs, failureAlert(o, msg, now), now, &res)
		}
	}
	// what no sender took in the window, or took and never answered
	xr, err := c.Query(ctx, `SELECT send_id, kind, name, channel, recipients, requested_by, requested_at, route, error FROM pgvigil.report_mail_expire($1)`, now)
	if err != nil {
		return res, err
	}
	var gone []owed
	var why []string
	for xr.Next() {
		var o owed
		var e string
		if err := xr.Scan(&o.id, &o.kind, &o.name, &o.channel, &o.to, &o.by, &o.at, &o.route, &e); err != nil {
			xr.Close()
			return res, err
		}
		gone, why = append(gone, o), append(why, e)
	}
	xr.Close()
	if err := xr.Err(); err != nil {
		return res, err
	}
	for i, o := range gone {
		res.Failed++
		notify(ctx, chs, failureAlert(o, why[i], now), now, &res)
	}
	return res, nil
}

// notify sends one failure notice on every channel
func notify(ctx context.Context, chs []namedMailer, a alerts.Alert, now time.Time, res *Result) {
	for _, n := range chs {
		res.Notices++
		nctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		if err := n.m.Notify(nctx, []alerts.Alert{a}, now); err != nil {
			res.NoticeFailed++
		}
		cancel()
	}
}

// mailOne builds and mails one owed row; the size is the message's bytes (0 when none was built)
func mailOne(ctx context.Context, ch namedMailer, o owed, now time.Time) (int, error) {
	if ch.kind != "smtp" {
		return 0, fmt.Errorf("channel %s is a %s channel, not smtp", ch.name, ch.kind)
	}
	from := ch.m.MailFrom()
	if from == "" {
		return 0, fmt.Errorf("channel %s has no smtp from address", ch.name)
	}
	text := o.subject + "\n\nThis report is in the HTML part of this mail"
	if o.xlsx != nil {
		text += "; the workbook " + attachName(o.xname) + " is attached"
	}
	text += ".\nAsked by " + o.by + " (" + o.kind + ") at " + o.at.UTC().Format("2006-01-02 15:04:05") + " UTC; the page: " + o.route + "\n"
	msg, err := Build(Mail{From: from, To: o.to, Subject: o.subject, HTML: o.html, Text: text, XLSX: o.xlsx, XLSXName: o.xname, At: now, ID: o.id})
	if err != nil {
		return 0, err
	}
	sctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	return len(msg), ch.m.Mail(sctx, o.to, msg)
}

// failureAlert is the notice of a failed report mail: a warning in the alert line every channel already writes
func failureAlert(o owed, why string, now time.Time) alerts.Alert {
	at := now.UTC()
	return alerts.Alert{Event: "firing", FindingKey: fmt.Sprintf("report-mail-%d", o.id), Instance: "pgvigil", Severity: "warning",
		Source: "report mail", Setting: "report mail failed",
		Value:  fmt.Sprintf("%s (%s mail %d to %s): %s", o.name, o.kind, o.id, strings.Join(o.to, ", "), why),
		Detail: "the mail was not sent; the Report mail page lists the send with its error", FindingAt: &at}
}

// Run is the loop inside `pgvigil run`: a pass every minute until ctx ends. Without an smtp channel it logs
// "report mail off" and returns without touching the repository.
func Run(ctx context.Context, log *slog.Logger, dsn string, chs []alerts.Channel) error {
	smtp := 0
	for i := range chs {
		if chs[i].Kind == "smtp" {
			smtp++
		}
	}
	if smtp == 0 {
		log.Info("report mail off: no smtp channel in the alerts: block, nothing is mailed")
		return nil
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return fmt.Errorf("report mail dsn: %w", err)
	}
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-reportmail"
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "30000"
	cfg.MaxConns = 2
	var pool *pgxpool.Pool
	for pool == nil {
		p, err := pgxpool.NewWithConfig(ctx, cfg)
		if err == nil && p.Ping(ctx) == nil {
			pool = p
			break
		}
		if p != nil {
			p.Close()
		}
		log.Warn("report mail: repository not reachable, retrying in 1m", "err", err)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(time.Minute):
		}
	}
	defer pool.Close()
	log.Info("report mail started", "smtp_channels", smtp)
	t := time.NewTicker(Every)
	defer t.Stop()
	for {
		if res, err := Once(ctx, pool, chs, time.Now()); err != nil {
			log.Warn("report mail pass failed", "err", err)
		} else if res.Sent+res.Failed > 0 {
			log.Info("report mail pass", "result", res.String())
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

// OnceDSN is one pass on its own small pool (`pgvigil alerts`, the sender's one-off pass); no smtp channel = nothing.
func OnceDSN(ctx context.Context, dsn string, chs []alerts.Channel) (Result, error) {
	smtp := false
	for i := range chs {
		smtp = smtp || chs[i].Kind == "smtp"
	}
	if !smtp {
		return Result{}, nil
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return Result{}, fmt.Errorf("report mail dsn: %w", err)
	}
	cfg.ConnConfig.RuntimeParams["application_name"] = "pgvigil-reportmail"
	cfg.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return Result{}, err
	}
	defer pool.Close()
	return Once(ctx, pool, chs, time.Now())
}

// Once is one pass under the advisory lock (a pass of another sender in progress = this one is skipped).
func Once(ctx context.Context, pool *pgxpool.Pool, chs []alerts.Channel, now time.Time) (Result, error) {
	c, err := pool.Acquire(ctx)
	if err != nil {
		return Result{}, err
	}
	defer c.Release()
	var got bool
	if err := c.QueryRow(ctx, `SELECT pg_try_advisory_lock($1)`, lockKey).Scan(&got); err != nil {
		return Result{}, err
	}
	if !got {
		return Result{}, nil
	}
	defer func() { _, _ = c.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock($1)`, lockKey) }()
	return Pass(ctx, c, chs, now)
}
