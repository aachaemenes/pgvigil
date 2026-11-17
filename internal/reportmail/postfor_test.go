package reportmail

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/aachaemenes/pgvigil/internal/alerts"
)

// B20-4 (review-26 go1 S1 / S2): postFor over a fake repository and fake channels - a post channel this sender lacks
// and one that refuses are both in the answer and alerted; no post taken = nothing sent, nothing recorded; a page that
// sent no counts is alerted once; a record or a take that fails still alerts (the notice needs no repository).

type postConn struct {
	take    []any // the take's row (post, channels, day, route); nil = no row
	takeErr error
	why     string // the post_error read of a send with no post; "" = no row
	execErr error
	execs   []string
	args    [][]any
}

type fakeRow struct {
	vals []any
	err  error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	for i, d := range dest {
		switch p := d.(type) {
		case *[]byte:
			*p = r.vals[i].([]byte)
		case *[]string:
			*p = r.vals[i].([]string)
		case *time.Time:
			*p = r.vals[i].(time.Time)
		case *string:
			*p = r.vals[i].(string)
		}
	}
	return nil
}

func (c *postConn) QueryRow(_ context.Context, sql string, _ ...any) pgx.Row {
	switch {
	case strings.Contains(sql, "report_mail_post_take"):
		if c.takeErr != nil {
			return fakeRow{err: c.takeErr}
		}
		if c.take == nil {
			return fakeRow{err: pgx.ErrNoRows}
		}
		return fakeRow{vals: c.take}
	case strings.Contains(sql, "post_error FROM pgvigil.report_mail_sends"):
		if c.why == "" {
			return fakeRow{err: pgx.ErrNoRows}
		}
		return fakeRow{vals: []any{c.why}}
	}
	return fakeRow{err: errors.New("unexpected query: " + sql)}
}

func (c *postConn) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, errors.New("unexpected Query")
}

func (c *postConn) Exec(_ context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	c.execs, c.args = append(c.execs, sql), append(c.args, args)
	return pgconn.CommandTag{}, c.execErr
}

type postMailer struct {
	postErr error
	posts   []alerts.Post
	notices []alerts.Alert
}

func (m *postMailer) MailFrom() string                             { return "a@b.org" }
func (m *postMailer) Mail(context.Context, []string, []byte) error { return nil }
func (m *postMailer) Post(_ context.Context, p alerts.Post) error {
	m.posts = append(m.posts, p)
	return m.postErr
}
func (m *postMailer) Notify(_ context.Context, a []alerts.Alert, _ time.Time) error {
	m.notices = append(m.notices, a...)
	return nil
}

func TestPostFor(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 11, 16, 15, 0, 0, 0, time.UTC)
	o := owed{id: 42, kind: "scheduled", name: "Daily checks"}
	num := []byte(`{"instances": 3, "critical": 1, "warnings": 0, "worst": [{"name": "a", "critical": 1, "warnings": 0}]}`)
	take := []any{num, []string{"hook", "gone"}, time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC), "#/checks?w=24h"}
	setting := func(m *postMailer) []string {
		var out []string
		for _, a := range m.notices {
			out = append(out, a.Setting)
		}
		return out
	}

	// (a) one channel refuses, one is not this sender's: both in the answer, one notice per channel, nothing else
	hook, mail := &postMailer{postErr: errors.New("post 127.0.0.1:9: connection refused")}, &postMailer{}
	chs := []namedMailer{{name: "hook", kind: "webhook", m: hook}, {name: "mail", kind: "smtp", m: mail}}
	c := &postConn{take: take}
	var res Result
	if err := postFor(ctx, c, chs, o, now, &res); err != nil {
		t.Fatal(err)
	}
	if len(c.execs) != 1 || !strings.Contains(c.execs[0], "report_mail_post_record") {
		t.Fatalf("execs %q", c.execs)
	}
	msg, _ := c.args[0][2].(string)
	if !strings.Contains(msg, "gone: not a channel of this sender's configuration") || !strings.Contains(msg, "hook: post 127.0.0.1:9") {
		t.Errorf("the recorded answer %q", msg)
	}
	if res.PostFailed != 1 || res.Posted != 0 || len(hook.posts) != 1 || len(mail.posts) != 0 {
		t.Errorf("res %+v, hook posts %d, mail posts %d", res, len(hook.posts), len(mail.posts))
	}
	if strings.Join(setting(hook), ",") != "daily checks post failed" || strings.Join(setting(mail), ",") != "daily checks post failed" || !strings.Contains(hook.notices[0].Value, "mail 42,") {
		t.Errorf("notices hook %v mail %v", hook.notices, mail.notices)
	}
	if got := hook.posts[0]; got.Title != "Daily checks 2026-11-16: 1 critical, 0 warnings on 3 instances" || got.Route != "#/checks?w=24h" {
		t.Errorf("the post %+v", got)
	}

	// (b) nothing to take, no reason on the row: nothing sent, nothing recorded, no notice
	hook, mail = &postMailer{}, &postMailer{}
	chs = []namedMailer{{name: "hook", kind: "webhook", m: hook}, {name: "mail", kind: "smtp", m: mail}}
	c, res = &postConn{}, Result{}
	if err := postFor(ctx, c, chs, o, now, &res); err != nil || len(c.execs) != 0 || len(hook.posts)+len(hook.notices)+len(mail.notices) != 0 || res != (Result{}) {
		t.Errorf("no post: err %v execs %q posts %d notices %d/%d res %+v", err, c.execs, len(hook.posts), len(hook.notices), len(mail.notices), res)
	}

	// (c) a page that sent no counts: alerted once with the row's reason, nothing recorded
	c, res = &postConn{why: "the drawn page sent no counts: nothing posted"}, Result{}
	if err := postFor(ctx, c, chs, o, now, &res); err != nil || len(c.execs) != 0 || res.PostFailed != 1 || len(mail.notices) != 1 || !strings.Contains(mail.notices[0].Value, "sent no counts") {
		t.Errorf("no counts: err %v execs %q res %+v notices %v", err, c.execs, res, mail.notices)
	}

	// (d) the record fails: the notice still goes (it needs no repository), the error comes back
	hook, mail = &postMailer{postErr: errors.New("refused")}, &postMailer{}
	chs = []namedMailer{{name: "hook", kind: "webhook", m: hook}, {name: "mail", kind: "smtp", m: mail}}
	c, res = &postConn{take: take, execErr: errors.New("the repository went away")}, Result{}
	if err := postFor(ctx, c, chs, o, now, &res); err == nil || len(mail.notices) != 1 || mail.notices[0].Setting != "daily checks post failed" {
		t.Errorf("a failed record: err %v, notices %v", err, mail.notices)
	}

	// (e) the take fails: the post is lost to this pass (the mail is recorded sent), so it is alerted before the error
	mail = &postMailer{}
	chs = []namedMailer{{name: "mail", kind: "smtp", m: mail}}
	c, res = &postConn{takeErr: errors.New("conn closed")}, Result{}
	if err := postFor(ctx, c, chs, o, now, &res); err == nil || len(mail.notices) != 1 || !strings.Contains(mail.notices[0].Value, "the post could not be taken: conn closed") {
		t.Errorf("a failed take: err %v, notices %v", err, mail.notices)
	}
}
