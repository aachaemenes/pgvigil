package web

// Reports by e-mail (task 171; DBA Dash's report subscriptions). Any page of the UI is mailed now or on a schedule
// to a list of addresses through an smtp channel of the alerts: block, the mail body the page's own grids as HTML in
// the screen's colours and the page's workbook attached (web/src/reportmail.ts builds both with the grid tools' and
// the export's own code from the grids on the screen: one renderer, so the mail equals the window).
//
//   GET  /api/reportmail?[part=schedules|sends|send|channels|log][&id=][&from=&to=]  the schedules (each with its last
//        send), the window's sends, one send's state (id), the smtp channels, the attempts; the door's state.
//   POST /api/reportmail                {op: add|edit|end|enable|disable, ...}  a schedule; the cron line and its next
//        send are computed here (internal/reportmail), the row written by pgvigil.import_report_mail.
//   POST /api/reportmail/send           the page as the window shows it (Send now): queued for the sender.
//   POST /api/reportmail/test           {schedule_id}: the schedule's page rendered now and queued (kind test).
//   POST /api/reportmail/rendered       a headless render's page posts its mail back here (its key, its session).
//
// Writes ride the UI login and the actions door's audit login, the way of q_alert_rules.go: the session's user is
// the row's user; the X-Pgvigil header. The mail itself is sent by the alert sender (pgvigil run,
// internal/reportmail Run): this process never holds a channel's secret.
//
// A schedule's turn (RunReportMail, a loop of this process): every minute the due schedules are claimed one at a
// time, just before each render (pgvigil.import_report_mail_claim: a lease and a claim token), and each page is opened
// in a headless Chromium-family browser (reportmail.FindBrowser, StartBrowser) as the schedule's owner, in the
// schedule's time zone (TZ), on a listener of this process on 127.0.0.1 that lives for the render. The browser starts
// on a launch page in its own 0700 profile folder (the render key is never on a command line); the key is opened once
// (reportmail.Renders): a session issued for the owner alone, revoked when the render ends (an owner who can no longer
// sign in renders nothing), the owner's grid choices written into the render's storage, then the page, whose own code
// builds the mail and posts it back from that session. The turn is queued (kind scheduled) with the claim's token and
// the next turn, or, when the page could not be rendered, queued as a failed render that the sender records and
// alerts; a turn whose claim was lost meanwhile is refused and mails nothing.

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/reportmail"
)

// the requests' size caps: a schedule's fields; a mail (the HTML, the workbook in base64 and the fields)
const (
	reportMailFormMax = 64 << 10
	reportMailBodyMax = 16 << 20
	// renderWait bounds one headless render, the browser's start and the page's reads included
	renderWait = 90 * time.Second
	// renderLease is the claim on a due schedule: past it another server may render the turn
	renderLease = 10 * time.Minute
)

const sqlReportMailSchedules = `
SELECT s.schedule_id, s.name, s.page, s.route, array_to_string(s.recipients, ', ') AS recipients, s.recipients AS recipient_list,
       s.channel, s.cadence, s.cron, s.timezone, s.attach_xlsx, s.enabled, s.next_at, s.created_by, s.created_at,
       s.changed_by, s.changed_at, l.send_id AS last_send_id, l.requested_at AS last_at, l.kind AS last_kind,
       coalesce(l.outcome, CASE WHEN l.send_id IS NULL THEN NULL WHEN l.requested_at <= now() - pgvigil.report_mail_window() THEN 'unanswered' ELSE 'queued' END) AS last_outcome,
       coalesce(l.error, l.render_error) AS last_error
  FROM pgvigil.report_mail_schedules s
  LEFT JOIN LATERAL (SELECT x.send_id, x.requested_at, x.kind, x.outcome, x.error, x.render_error
                       FROM pgvigil.report_mail_sends x WHERE x.schedule_id = s.schedule_id
                      ORDER BY x.requested_at DESC, x.send_id DESC LIMIT 1) l ON true
 WHERE s.ended_at IS NULL
 ORDER BY lower(s.name), s.schedule_id`

const sqlReportMailSends = `
SELECT x.send_id, x.requested_at, x.kind, x.name, x.requested_by, array_to_string(x.recipients, ', ') AS recipients, x.channel,
       x.subject, x.grids, x.rows, x.html_bytes, x.xlsx_bytes, x.mail_bytes, x.done_at,
       coalesce(x.outcome, CASE WHEN x.requested_at <= now() - pgvigil.report_mail_window() THEN 'unanswered' ELSE 'queued' END) AS outcome,
       coalesce(x.error, x.render_error) AS error, x.schedule_id, x.route
  FROM pgvigil.report_mail_sends x
 WHERE x.requested_at >= $1 AND x.requested_at < $2
 ORDER BY x.requested_at DESC, x.send_id DESC
 LIMIT 1000`

const sqlReportMailSend = `
SELECT x.send_id, x.requested_at, x.kind, x.name, array_to_string(x.recipients, ', ') AS recipients, x.channel, x.subject,
       x.grids, x.rows, x.html_bytes, x.xlsx_bytes, x.mail_bytes, x.done_at,
       coalesce(x.outcome, CASE WHEN x.requested_at <= now() - pgvigil.report_mail_window() THEN 'unanswered' ELSE 'queued' END) AS outcome,
       coalesce(x.error, x.render_error) AS error
  FROM pgvigil.report_mail_sends x WHERE x.send_id = $1`

const sqlReportMailChannels = `
SELECT c.name, c.destination FROM pgvigil.alert_channels c WHERE c.kind = 'smtp' AND c.is_configured ORDER BY c.name`

const sqlReportMailLog = `
SELECT l.at, l.ui_user, l.client, l.op, l.schedule_id, l.send_id, l.outcome, l.detail
  FROM pgvigil.report_mail_log l
 WHERE l.at >= $1 AND l.at < $2
 ORDER BY l.at DESC, l.log_id DESC
 LIMIT 1000`

// reportMailOff says why report mail cannot be written on this server, "" when it can: like alert rules it rides
// the UI login and the actions door's audit login.
func (s *Server) reportMailOff() string {
	if w := s.serverOff(); w != "" {
		return "Sending or scheduling a mail needs " + w + "."
	}
	return ""
}

// ReportMail is GET /api/reportmail.
func (s *Server) ReportMail(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	part := q.Get("part")
	out := map[string]any{}
	why := s.reportMailOff()
	browser, noBrowser := reportmail.FindBrowser(), ""
	if browser == "" {
		noBrowser = "no Chromium-family browser on this server (PGVIGIL_BROWSER names one): a schedule's turn cannot be rendered; Send now works from any browser"
	}
	out["door"] = map[string]any{"writable": why == "", "reason": why, "user": s.reportMailUser(r), "browser": browser != "", "browser_reason": noBrowser,
		"max_html": reportmail.MaxHTML, "max_xlsx": reportmail.MaxXLSX, "max_recipients": reportmail.MaxRecipients, "min_gap_secs": int(reportmail.MinGap.Seconds())}
	ctx := r.Context()
	if part == "send" {
		id := q.Get("id")
		if id == "" || strings.Trim(id, "0123456789") != "" || len(id) > 18 {
			writeErr(w, http.StatusBadRequest, errors.New("id must be a send_id"))
			return
		}
		t, err := s.query(ctx, sqlReportMailSend, id)
		out["send"] = t
		s.reply(w, r, out, err)
		return
	}
	parts := []struct {
		name, sql string
		args      []any
	}{
		{"schedules", sqlReportMailSchedules, nil},
		{"sends", sqlReportMailSends, []any{from, to}},
		{"channels", sqlReportMailChannels, nil},
		{"log", sqlReportMailLog, []any{from, to}},
	}
	for _, p := range parts {
		if part != "" && part != p.name {
			continue
		}
		t, err := s.query(ctx, p.sql, p.args...)
		if err != nil {
			s.reply(w, r, nil, fmt.Errorf("%s: %w", p.name, err))
			return
		}
		out[p.name] = t
	}
	s.reply(w, r, out, nil)
}

func (s *Server) reportMailUser(r *http.Request) string {
	if s.auth == nil {
		return ""
	}
	return s.sessionUser(r)
}

// reportMailGate is every write's door: the header, the login and the audit login. "" user = refused (written).
func (s *Server) reportMailGate(w http.ResponseWriter, r *http.Request, limit int64) (string, []byte) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return "", nil
	}
	if why := s.reportMailOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(why))
		return "", nil
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return "", nil
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil || int64(len(raw)) > limit {
		writeErr(w, http.StatusRequestEntityTooLarge, fmt.Errorf("body: unreadable or over %d KB", limit>>10))
		return "", nil
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return "", nil
	}
	return user, raw
}

// importJSON calls one of 0107's import functions through the audit login and answers with its {outcome, detail, id}
func (s *Server) importJSON(ctx context.Context, fn string, pay map[string]any) (map[string]any, error) {
	b, err := json.Marshal(pay)
	if err != nil {
		return nil, err
	}
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	var out string
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.`+fn+`($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		return nil, fmt.Errorf("not written: %w", err)
	}
	var res map[string]any
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		return nil, fmt.Errorf("%s answered %q", fn, out)
	}
	return res, nil
}

func (s *Server) importReply(w http.ResponseWriter, r *http.Request, res map[string]any, err error) {
	if err != nil {
		s.log.Warn("report mail write failed", "path", r.URL.Path, "err", err)
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	code := http.StatusOK
	if res["outcome"] != "done" {
		code = http.StatusConflict
		res["error"] = fmt.Sprint(res["detail"]) // api.ts post() throws with the error's words
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(res)
}

// scheduleRequest is POST /api/reportmail's body
type scheduleRequest struct {
	Op         string   `json:"op"`
	ScheduleID int64    `json:"schedule_id"`
	Name       string   `json:"name"`
	Route      string   `json:"route"`
	Page       string   `json:"page"`
	Recipients []string `json:"recipients"`
	Channel    string   `json:"channel"`
	Cadence    string   `json:"cadence"`
	At         string   `json:"at"`
	Days       []int    `json:"days"`
	Cron       string   `json:"cron"`
	Timezone   string   `json:"timezone"`
	AttachXLSX *bool    `json:"attach_xlsx"`
	Enabled    *bool    `json:"enabled"`
	// GridPrefs: the grid tools' choices of the page in the asking browser (localStorage pgvigil.grid.* entries), so
	// the scheduled render hides, freezes and bars what the owner's window does; absent on an edit = kept
	GridPrefs map[string]string `json:"grid_prefs"`
}

// ReportMailWrite is POST /api/reportmail: a schedule added, changed, ended, switched on or off.
func (s *Server) ReportMailWrite(w http.ResponseWriter, r *http.Request) {
	user, raw := s.reportMailGate(w, r, reportMailFormMax)
	if user == "" {
		return
	}
	var in scheduleRequest
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	pay := map[string]any{"op": in.Op, "ui_user": user, "client": clientIP(r)}
	if in.ScheduleID > 0 {
		pay["schedule_id"] = in.ScheduleID
	}
	now := time.Now()
	switch in.Op {
	case "add", "edit":
		line, err := reportmail.CronFor(in.Cadence, in.At, in.Days, in.Cron)
		if err == nil {
			err = reportmail.CheckCron(line, in.Timezone, now)
		}
		if err == nil {
			err = reportmail.CheckRoute(in.Route)
		}
		var rcpt []string
		if err == nil {
			rcpt, err = reportmail.Recipients(in.Recipients)
		}
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		next, err := reportmail.NextSend(line, in.Timezone, now)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		pay["name"], pay["route"], pay["page"], pay["recipients"], pay["channel"] = in.Name, in.Route, in.Page, rcpt, in.Channel
		pay["cadence"], pay["cron"], pay["timezone"], pay["next_at"] = in.Cadence, line, strings.TrimSpace(in.Timezone), next.Format(time.RFC3339)
		pay["attach_xlsx"], pay["enabled"] = in.AttachXLSX == nil || *in.AttachXLSX, in.Enabled == nil || *in.Enabled
		if in.GridPrefs != nil {
			size := 2
			for k, v := range in.GridPrefs {
				size += len(k) + len(v) + 6
				if !strings.HasPrefix(k, "pgvigil.grid.") || len(k) > 200 {
					writeErr(w, http.StatusBadRequest, fmt.Errorf("grid choice %q is not one of the grid tools' (pgvigil.grid.*)", k))
					return
				}
			}
			if size > 16<<10 {
				writeErr(w, http.StatusBadRequest, errors.New("the page's grid choices are over 16 KB"))
				return
			}
			pay["grid_prefs"] = in.GridPrefs
		}
	case "enable":
		// the next send from the schedule's own line and zone, read here (the read-only pool)
		var line, tz string
		if err := s.pool.QueryRow(r.Context(), `SELECT cron, timezone FROM pgvigil.report_mail_schedules WHERE schedule_id = $1`, in.ScheduleID).Scan(&line, &tz); err == nil {
			if next, err := reportmail.NextSend(line, tz, now); err == nil {
				pay["next_at"] = next.Format(time.RFC3339)
			}
		}
	case "end", "disable":
	default:
		writeErr(w, http.StatusBadRequest, fmt.Errorf("op %q is not add, edit, end, enable or disable", in.Op))
		return
	}
	res, err := s.importJSON(r.Context(), "import_report_mail", pay)
	s.importReply(w, r, res, err)
}

// mailRequest is the body of POST /api/reportmail/send and of a render's post-back
type mailRequest struct {
	Key        string   `json:"key"` // a render's post-back: the render it answers
	Name       string   `json:"name"`
	Route      string   `json:"route"`
	Recipients []string `json:"recipients"`
	Channel    string   `json:"channel"`
	Subject    string   `json:"subject"`
	Window     string   `json:"window"` // the page's range as the page says it (a render: the subject is the schedule's name and this)
	HTML       string   `json:"html"`
	XLSX       string   `json:"xlsx"` // base64
	XLSXName   string   `json:"xlsx_name"`
	Grids      int      `json:"grids"`
	Rows       int      `json:"rows"`
	Error      string   `json:"error"` // a render's page that could not build its mail says why
}

// check is a mail's own checks before it is queued (the repository checks them again)
func (m *mailRequest) check() ([]byte, error) {
	if err := reportmail.CheckBody(m.HTML); err != nil {
		return nil, err
	}
	if m.XLSX == "" {
		return nil, nil
	}
	b, err := base64.StdEncoding.DecodeString(m.XLSX)
	if err != nil {
		return nil, errors.New("the workbook is not base64")
	}
	return b, reportmail.CheckWorkbook(b)
}

// ReportMailSend is POST /api/reportmail/send: the page as the window shows it, queued for the sender (Send now).
func (s *Server) ReportMailSend(w http.ResponseWriter, r *http.Request) {
	user, raw := s.reportMailGate(w, r, reportMailBodyMax)
	if user == "" {
		return
	}
	var in mailRequest
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	rcpt, err := reportmail.Recipients(in.Recipients)
	if err == nil {
		err = reportmail.CheckRoute(in.Route)
	}
	if err == nil {
		_, err = in.check()
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	pay := map[string]any{"ui_user": user, "client": clientIP(r), "kind": "now", "name": in.Name, "route": in.Route, "channel": in.Channel,
		"recipients": rcpt, "subject": in.Subject, "html": in.HTML, "xlsx_name": in.XLSXName, "grids": in.Grids, "rows": in.Rows}
	if in.XLSX != "" {
		pay["xlsx"] = in.XLSX
	}
	res, err := s.importJSON(r.Context(), "import_report_mail_send", pay)
	s.importReply(w, r, res, err)
}

// ReportMailTest is POST /api/reportmail/test {schedule_id}: the schedule's page rendered now as the asking user and
// queued to the schedule's addresses (kind test). One test per user at a time, under the hourly cap checked before the
// render, on a browser slot of its own (a test never holds up a schedule's turn). The reply says it started.
func (s *Server) ReportMailTest(w http.ResponseWriter, r *http.Request) {
	user, raw := s.reportMailGate(w, r, reportMailFormMax)
	if user == "" {
		return
	}
	var in struct {
		ScheduleID int64 `json:"schedule_id"`
	}
	if err := json.Unmarshal(raw, &in); err != nil || in.ScheduleID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("body: {schedule_id}"))
		return
	}
	var sc dueSchedule
	err := s.pool.QueryRow(r.Context(), `SELECT schedule_id, name, route, recipients, channel, cron, timezone, attach_xlsx, created_by, coalesce(next_at, now()), coalesce(grid_prefs::text, '')
	                                       FROM pgvigil.report_mail_schedules WHERE schedule_id = $1 AND ended_at IS NULL`, in.ScheduleID).
		Scan(&sc.id, &sc.name, &sc.route, &sc.to, &sc.channel, &sc.cron, &sc.tz, &sc.xlsx, &sc.owner, &sc.next, &sc.prefs)
	if err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no live schedule %d", in.ScheduleID))
		return
	}
	if reportmail.FindBrowser() == "" {
		writeErr(w, http.StatusConflict, errors.New("no Chromium-family browser on this server (PGVIGIL_BROWSER names one): a schedule's page cannot be rendered here"))
		return
	}
	var n, limit int
	if err := s.pool.QueryRow(r.Context(), `SELECT count(*), pgvigil.report_mail_hourly_cap() FROM pgvigil.report_mail_sends
	                                         WHERE requested_by = $1 AND kind IN ('now', 'test') AND outcome IS DISTINCT FROM 'refused'
	                                           AND requested_at > now() - interval '1 hour'`, user).Scan(&n, &limit); err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	if n >= limit {
		writeErr(w, http.StatusConflict, fmt.Errorf("%s asked %d mails in the last hour: at most %d an hour", user, n, limit))
		return
	}
	testMu.Lock()
	busy := testsInFlight[user]
	if !busy {
		testsInFlight[user] = true
	}
	testMu.Unlock()
	if busy {
		writeErr(w, http.StatusConflict, errors.New("a test of yours is being drawn: one at a time"))
		return
	}
	client := clientIP(r)
	go func() {
		defer func() { testMu.Lock(); delete(testsInFlight, user); testMu.Unlock() }()
		ctx, cancel := context.WithTimeout(serveContext(), renderWait+30*time.Second)
		defer cancel()
		s.renderAndQueue(ctx, sc, "test", user, client, time.Time{}, "", testSlot)
	}()
	s.reply(w, r, map[string]any{"outcome": "rendering", "detail": fmt.Sprintf("schedule %d's page is being drawn as %s: the test mail is queued when it is drawn (a minute or two), then the sender's next pass mails it", sc.id, user)}, nil)
}

// ---- the headless render ---------------------------------------------------------------------------------------

type dueSchedule struct {
	id                             int64
	name, route, channel, cron, tz string
	to                             []string
	xlsx                           bool
	owner                          string
	next                           time.Time
	claim, prefs                   string
}

type rendered struct {
	mail mailRequest
	err  error
}

// renders: the renders in flight (internal/reportmail: the key checks); the browser slots: one for the schedules'
// turns, one for the Send tests; the tests drawing now, by user; the serve process's context (RunReportMail's)
var (
	renders       = reportmail.NewRenders()
	schedSlot     = make(chan struct{}, 1)
	testSlot      = make(chan struct{}, 1)
	testMu        sync.Mutex
	testsInFlight = map[string]bool{}
	serveMu       sync.Mutex
	serveCtx      context.Context
)

func serveContext() context.Context {
	serveMu.Lock()
	defer serveMu.Unlock()
	if serveCtx != nil {
		return serveCtx
	}
	return context.Background()
}

// renderPage opens route in a headless browser as user, in time zone tz, with the grid choices prefs (a JSON object of
// the grid tools' localStorage entries, or ""), and waits for the page's mail. slot: the browser slot it takes.
func (s *Server) renderPage(ctx context.Context, user, route, tz, prefs string, slot chan struct{}) (mailRequest, error) {
	if s.auth == nil {
		return mailRequest{}, errors.New("report mail is behind the UI login: this server runs with -no-login")
	}
	if err := reportmail.CheckRoute(route); err != nil {
		return mailRequest{}, err
	}
	if _, err := reportmail.Zone(tz); err != nil {
		return mailRequest{}, err
	}
	browser := reportmail.FindBrowser()
	if browser == "" {
		return mailRequest{}, errors.New("no Chromium-family browser on this server (PGVIGIL_BROWSER names one)")
	}
	hash, err := s.auth.lookup(ctx, user)
	if err != nil {
		return mailRequest{}, fmt.Errorf("the user %s could not be read: %w", user, err)
	}
	if hash == "" {
		return mailRequest{}, fmt.Errorf("the user %s can no longer sign in (disabled or removed): the page is not rendered", user)
	}
	select {
	case slot <- struct{}{}:
	case <-ctx.Done():
		return mailRequest{}, ctx.Err()
	}
	defer func() { <-slot }()

	key, done := renders.Start(user, route, prefs)
	defer func() {
		if tok := renders.End(key); tok != "" {
			s.auth.revoke(tok)
		}
	}()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return mailRequest{}, err
	}
	// the same routes on loopback for the render's life: no Host list (the port is new), no TLS
	inner := *s
	inner.hosts, inner.tls = nil, false
	app := inner.Handler()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /mailrender/{key}", func(w http.ResponseWriter, rq *http.Request) { s.renderOpen(w, rq, user, hash) })
	mux.Handle("/", app)
	hs := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = hs.Serve(ln) }()
	defer func() { _ = hs.Close() }()

	dir, err := os.MkdirTemp("", "pgvigil-render-")
	if err != nil {
		return mailRequest{}, err
	}
	defer func() { _ = os.RemoveAll(dir) }()
	rctx, cancel := context.WithTimeout(ctx, renderWait)
	defer cancel()
	b, err := reportmail.StartBrowser(rctx, browser, dir, fmt.Sprintf("http://%s/mailrender/%s", ln.Addr(), key), tz)
	if err != nil {
		return mailRequest{}, err
	}
	defer b.Stop()
	select {
	case v := <-done:
		got, _ := v.(rendered)
		if got.err != nil {
			return mailRequest{}, got.err
		}
		return got.mail, nil
	case <-b.Done():
		return mailRequest{}, fmt.Errorf("the browser ended before the page was drawn (%s)", b.Why())
	case <-rctx.Done():
		return mailRequest{}, fmt.Errorf("the page was not drawn in %s", renderWait)
	}
}

// renderOpen: the browser's first request on the render's listener. A key is opened once only: the render's session
// is issued for its user, set as the cookie (on loopback, never Secure: the listener is plain), the grid choices are
// written into this origin's storage and the browser is sent to the page.
func (s *Server) renderOpen(w http.ResponseWriter, r *http.Request, user, hash string) {
	key := r.PathValue("key")
	_, route, prefs, tok, err := renders.Open(key, func(u string) (string, error) {
		if u != user {
			return "", reportmail.ErrNoRender // another render's key on this render's listener
		}
		return s.auth.issue(u, hash)
	})
	if err != nil {
		writeErr(w, http.StatusNotFound, errors.New("no such render"))
		return
	}
	sep := "?"
	if strings.Contains(route, "?") {
		sep = "&"
	}
	target, _ := json.Marshal("/" + route + sep + "mailrender=" + key)
	kept := map[string]string{}
	if prefs != "" {
		_ = json.Unmarshal([]byte(prefs), &kept) // the repository's checked object; written again by json (< > & escaped)
	}
	pj, _ := json.Marshal(kept)
	script := "try{const p=" + string(pj) + ";for(const k of Object.keys(p))localStorage.setItem(k,p[k]);}catch(e){}location.replace(" + string(target) + ");"
	sum := sha256.Sum256([]byte(script))
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Content-Security-Policy", "default-src 'none'; script-src 'sha256-"+base64.StdEncoding.EncodeToString(sum[:])+"'")
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: tok, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode, MaxAge: int(renderWait.Seconds()) + 60})
	_, _ = io.WriteString(w, "<!DOCTYPE html><title>pgvigil</title><script>"+script+"</script>")
}

// ReportMailRendered is POST /api/reportmail/rendered: a headless render's page posts its mail (or why it has none).
// Only the render's own session may answer its key.
func (s *Server) ReportMailRendered(w http.ResponseWriter, r *http.Request) {
	user, raw := s.reportMailGate(w, r, reportMailBodyMax)
	if user == "" {
		return
	}
	var in mailRequest
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	var got rendered
	if in.Error != "" {
		got.err = errors.New("the page could not build its mail: " + in.Error)
	} else if _, err := in.check(); err != nil {
		got.err = err
	} else {
		got.mail = in
	}
	c, err := r.Cookie(sessionCookie)
	if err != nil || !renders.Answer(in.Key, user, c.Value, got) {
		writeErr(w, http.StatusNotFound, errors.New("no such render"))
		return
	}
	s.reply(w, r, map[string]any{"outcome": "done"}, nil)
}

// renderAndQueue renders one schedule's page and queues its mail: kind scheduled (by the owner, with the claim's token
// and the next turn) or test (by the asking user). A render that fails is queued as a failed render: the sender
// records and alerts it.
func (s *Server) renderAndQueue(ctx context.Context, sc dueSchedule, kind, user, client string, next time.Time, claim string, slot chan struct{}) {
	m, rerr := s.renderPage(ctx, user, sc.route, sc.tz, sc.prefs, slot)
	pay := map[string]any{"ui_user": user, "client": client, "kind": kind, "schedule_id": sc.id, "name": sc.name, "route": sc.route,
		"channel": sc.channel, "recipients": sc.to}
	if claim != "" {
		pay["claim"] = claim
	}
	if !next.IsZero() {
		// the turn after this one, never in the past: the render took its time
		if now := time.Now(); !next.After(now) {
			if n, err := reportmail.NextSend(sc.cron, sc.tz, now); err == nil {
				next = n
			} else {
				next = now.Add(24 * time.Hour)
			}
		}
		pay["next_at"] = next.Format(time.RFC3339)
	}
	if rerr != nil {
		pay["render_error"] = rerr.Error()
		pay["subject"] = sc.name
	} else {
		subj := sc.name
		if strings.TrimSpace(m.Window) != "" {
			subj += " - " + strings.TrimSpace(m.Window)
		}
		if kind == "test" {
			subj = "[test] " + subj
		}
		if len(subj) > 200 {
			subj = subj[:200]
		}
		pay["subject"], pay["html"], pay["grids"], pay["rows"], pay["xlsx_name"] = subj, m.HTML, m.Grids, m.Rows, m.XLSXName
		if sc.xlsx && m.XLSX != "" {
			pay["xlsx"] = m.XLSX
		}
	}
	res, err := s.importJSON(ctx, "import_report_mail_send", pay)
	switch {
	case err != nil:
		// the repository refused the write (it is down or read only): the lease runs out and the turn is drawn again
		s.log.Warn("report mail: the turn was not queued", "schedule", sc.id, "kind", kind, "err", err)
	case res["outcome"] != "done":
		s.log.Warn("report mail: the turn was refused", "schedule", sc.id, "kind", kind, "detail", res["detail"])
	case rerr != nil:
		s.log.Warn("report mail: the page could not be rendered (queued as failed: the sender alerts it)", "schedule", sc.id, "err", rerr)
	default:
		s.log.Info("report mail: queued", "schedule", sc.id, "kind", kind, "send", res["send_id"])
	}
}

// RunReportMail is the schedules' loop of the serve process: every minute the due turns are claimed one at a time,
// rendered and queued. Off (logged once) without the UI login or the audit login.
func (s *Server) RunReportMail(ctx context.Context) {
	serveMu.Lock()
	serveCtx = ctx
	serveMu.Unlock()
	if why := s.reportMailOff(); why != "" {
		s.log.Info("report mail schedules off", "reason", why)
		return
	}
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		s.reportMailTurns(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// reportMailTurns claims and runs the turns due now, one claim just before each render, at most 20 a minute
func (s *Server) reportMailTurns(ctx context.Context) {
	var have bool
	if err := s.pool.QueryRow(ctx, `SELECT to_regprocedure('pgvigil.import_report_mail_claim(timestamp with time zone, integer, integer)') IS NOT NULL`).Scan(&have); err != nil || !have {
		return
	}
	for range 20 {
		if ctx.Err() != nil {
			return
		}
		now := time.Now()
		var d dueSchedule
		var prefs *string
		err := s.actions.audit.QueryRow(ctx, `SELECT schedule_id, name, route, recipients, channel, cron, timezone, attach_xlsx, created_by, next_at, claim_token, grid_prefs::text
		                                        FROM pgvigil.import_report_mail_claim($1, $2, 1)`, now, int(renderLease.Seconds())).
			Scan(&d.id, &d.name, &d.route, &d.to, &d.channel, &d.cron, &d.tz, &d.xlsx, &d.owner, &d.next, &d.claim, &prefs)
		if errors.Is(err, pgx.ErrNoRows) {
			return
		}
		if err != nil {
			s.log.Warn("report mail: the due schedules could not be claimed", "err", err)
			return
		}
		if prefs != nil {
			d.prefs = *prefs
		}
		// the turn after this one, from now: a server down for a day sends one late turn, not every one missed
		after := now
		if d.next.After(after) {
			after = d.next
		}
		next, err := reportmail.NextSend(d.cron, d.tz, after)
		if err != nil {
			next = now.Add(24 * time.Hour) // a line that no longer parses: the turn fails once a day, alerted
		}
		rctx, cancel := context.WithTimeout(ctx, renderWait+30*time.Second)
		s.renderAndQueue(rctx, d, "scheduled", d.owner, "scheduler", next, d.claim, schedSlot)
		cancel()
	}
}
