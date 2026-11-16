package web

// The Daily checks mail (migration 0258, internal/reportmail/kept.go): the one report mail schedule a setting keeps.
//
// Who keeps it is read from pgvigil.yaml's reports.daily_checks block, which serve hands over once at its start
// (SetDailyChecks; serve reads the file once):
//   - the block PRESENT: the file owns the schedule. enabled: true keeps it (made, or updated in place; a schedule the
//     page made is taken over), enabled: false ends it. The Daily checks page's control is read only, with the reason.
//   - the block ABSENT: the page owns it. An admin's Mail daily... keeps one drawn as that admin; Turn off ends it. A
//     schedule a file kept and left behind is ended once at start.
// The file's setting is applied at start and then each minute only until the repository has answered it (a channel the
// sender has not recorded yet, or a repository not migrated yet, is tried again; nothing is written while it waits):
// the last serve started wins, and two serves never rewrite each other.
//
// Every write goes through import_report_mail_kept and the actions door's audit login, as report mail's own writes.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/reportmail"
)

// dailyChecks keeps each server's block and what applying it last found (serve calls SetDailyChecks after Open), keyed
// by s.self(): a render's copy of the server reads its origin's.
var dailyChecks sync.Map // *Server -> *dailyChecksState

type dailyChecksState struct {
	mu      sync.Mutex
	block   *reportmail.DailyChecks // nil: the file has no block
	settled bool                    // the repository has answered the file's setting: nothing more to apply
	why     string                  // why the file's setting is not applied yet, "" when it is
	logged  string                  // the reason last logged (each reason once)
}

// SetDailyChecks gives the server pgvigil.yaml's reports.daily_checks block (nil: the file has none).
func (s *Server) SetDailyChecks(d *reportmail.DailyChecks) {
	dailyChecks.Store(s.self(), &dailyChecksState{block: d})
}

func (s *Server) dailyChecksOf() *dailyChecksState {
	if v, ok := dailyChecks.Load(s.self()); ok {
		return v.(*dailyChecksState)
	}
	v, _ := dailyChecks.LoadOrStore(s.self(), &dailyChecksState{})
	return v.(*dailyChecksState)
}

const (
	sqlKeptMigrated = `SELECT to_regprocedure('pgvigil.import_report_mail_kept(timestamp with time zone, jsonb)') IS NOT NULL`
	// the live kept row; to_jsonb reads the 0258 columns, so the statement runs on a repository not migrated yet (no row)
	sqlKeptLive = `
SELECT s.schedule_id, to_jsonb(s)->>'kept_by' AS kept_by, s.cron, s.timezone, s.recipients, s.channel, s.created_by, s.next_at, s.attach_xlsx
  FROM pgvigil.report_mail_schedules s
 WHERE to_jsonb(s)->>'kept_as' = $1 AND s.ended_at IS NULL
 ORDER BY s.schedule_id DESC LIMIT 1`
	sqlKeptChannel = `SELECT EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.name = $1 AND c.kind = 'smtp' AND c.is_configured AND c.name NOT LIKE 'contact-%')`
)

const dailyNotMigrated = "this repository is not migrated for the Daily checks mail yet (pgvigil migrate)"

// keptRow is the live kept schedule, id 0 when there is none
type keptRow struct {
	id      int64
	by      string
	cron    string
	tz      string
	to      []string
	channel string
	owner   string
	next    *time.Time
	xlsx    bool
}

func (s *Server) keptLive(ctx context.Context) (keptRow, error) {
	var k keptRow
	var by *string
	err := s.pool.QueryRow(ctx, sqlKeptLive, reportmail.KeptDailyChecks).Scan(&k.id, &by, &k.cron, &k.tz, &k.to, &k.channel, &k.owner, &k.next, &k.xlsx)
	if errors.Is(err, pgx.ErrNoRows) {
		return keptRow{}, nil
	}
	if by != nil {
		k.by = *by
	}
	return k, err
}

// keptWrite is one keep or drop through the door: by is file or page, who the name the log keeps.
func (s *Server) keptWrite(ctx context.Context, op, by, who, client string, pay map[string]any) (map[string]any, error) {
	if pay == nil {
		pay = map[string]any{}
	}
	pay["op"], pay["by"], pay["ui_user"], pay["client"], pay["kept_as"] = op, by, who, client, reportmail.KeptDailyChecks
	return s.importJSON(ctx, "import_report_mail_kept", pay)
}

// dailyApplyTimeout bounds one try of the file's setting (its reads and its one write), under the minute between tries
const dailyApplyTimeout = 45 * time.Second

// applyDailyChecks applies the file's setting: called by RunReportMail at its start and each minute; it does nothing
// once the repository has answered. It never runs where report mail is off (RunReportMail returns before it).
// RunReportMail's loop is its one caller, so no two tries run at once: the reads and the write run outside the lock
// and under a deadline, and a repository that stalls never holds the Daily checks page (its part takes the same lock).
func (s *Server) applyDailyChecks(ctx context.Context) {
	st := s.dailyChecksOf()
	st.mu.Lock()
	block, settled := st.block, st.settled
	st.mu.Unlock()
	if settled {
		return
	}
	actx, cancel := context.WithTimeout(ctx, dailyApplyTimeout)
	why, done := s.applyDailyChecksOnce(actx, block)
	cancel()
	if ctx.Err() != nil {
		return // the server is stopping: what the try found is no state of the setting
	}
	st.mu.Lock()
	st.why, st.settled = why, done
	said := why == st.logged
	st.logged = why
	st.mu.Unlock()
	if !said && why != "" {
		s.log.Warn("daily checks mail: the setting is not applied", "setting", reportmail.DailyChecksKey, "reason", why)
	}
}

// applyDailyChecksOnce is one try: why the setting is not applied ("" when it is), and whether to stop trying.
func (s *Server) applyDailyChecksOnce(ctx context.Context, block *reportmail.DailyChecks) (string, bool) {
	var migrated bool
	if err := s.pool.QueryRow(ctx, sqlKeptMigrated).Scan(&migrated); err != nil {
		return "the repository could not be read: " + err.Error(), false
	}
	if !migrated {
		return dailyNotMigrated, false
	}
	live, err := s.keptLive(ctx)
	if err != nil {
		return "the kept schedule could not be read: " + err.Error(), false
	}
	answer := func(res map[string]any, err error, what string) (string, bool) {
		if err != nil {
			return err.Error(), false
		}
		switch res["outcome"] {
		case "done":
			s.log.Info("daily checks mail: "+what, "detail", res["detail"])
			return "", true
		case "unchanged":
			// said once, at the settle: the try ran and found the repository as the file says
			s.log.Info("daily checks mail: the setting is as kept: nothing written", "detail", res["detail"])
			return "", true
		}
		// a refusal of the setting's own values: trying again each minute would only fill the log
		return fmt.Sprint(res["detail"]), true
	}
	switch {
	case block == nil:
		// the page owns the mail; a schedule the file kept, and no longer names, is ended
		if live.id == 0 || live.by != "file" {
			return "", true
		}
		res, err := s.keptWrite(ctx, "drop", "file", reportmail.DailyChecksFileUser, "serve", nil)
		return answer(res, err, "the file no longer has the block: ended")
	case !block.On():
		if live.id == 0 {
			return "", true
		}
		res, err := s.keptWrite(ctx, "drop", "file", reportmail.DailyChecksFileUser, "serve", nil)
		return answer(res, err, "turned off in the file: ended")
	}
	req := block.Request()
	pay, _, err := req.Payload(time.Now())
	if err != nil {
		return err.Error(), true // the block was checked at start: this is a value the clock changed (none known)
	}
	// reads first, so a setting that cannot be kept yet writes nothing: the user, then the channel as the sender knows it
	if s.auth == nil {
		return "report mail is behind the UI login", true
	}
	hash, _, err := s.auth.lookup(ctx, req.As)
	if err != nil {
		return fmt.Sprintf("the user %s could not be read: %v", req.As, err), false
	}
	if hash == "" {
		return fmt.Sprintf("as: %s is not a UI user who can sign in (unknown or disabled): the page cannot be drawn as that user", req.As), false
	}
	var known bool
	if err := s.pool.QueryRow(ctx, sqlKeptChannel, req.Channel).Scan(&known); err != nil {
		return "the channels could not be read: " + err.Error(), false
	}
	if !known {
		return fmt.Sprintf("channel: %s is not an smtp channel the sender has recorded (is pgvigil run up, and does its alerts: block name it?)", req.Channel), false
	}
	res, err := s.keptWrite(ctx, "keep", "file", reportmail.DailyChecksFileUser, "serve", pay)
	return answer(res, err, "kept as the file says")
}

// dailyChecksPart is GET /api/reportmail?part=daily: the mail's state in the page's words, and whether this page may
// change it (and why not).
func (s *Server) dailyChecksPart(ctx context.Context, r *http.Request) (map[string]any, error) {
	st := s.dailyChecksOf()
	st.mu.Lock()
	block, fileWhy := st.block, st.why
	st.mu.Unlock()
	out := map[string]any{"route": reportmail.DailyChecksRoute, "name": reportmail.DailyChecksName, "kept": false, "user": s.reportMailUser(r)}
	owner := "page"
	switch {
	case block != nil && block.On():
		owner = "file"
	case block != nil:
		owner = "file-off"
	}
	out["owner"] = owner
	reason := s.reportMailOff()
	var migrated bool
	if err := s.pool.QueryRow(ctx, sqlKeptMigrated).Scan(&migrated); err != nil {
		return nil, err
	}
	var live keptRow // none on a repository that is not migrated yet: the part says so in words, with nothing read
	if migrated {
		var err error
		if live, err = s.keptLive(ctx); err != nil {
			return nil, err
		}
	}
	if live.id != 0 {
		out["kept"], out["schedule_id"], out["kept_by"], out["cron"] = true, live.id, live.by, live.cron
		out["at"], out["timezone"], out["recipients"], out["channel"], out["as"], out["attach_xlsx"] = reportmail.AtOfCron(live.cron), live.tz, live.to, live.channel, live.owner, live.xlsx
		if live.next != nil {
			out["next_at"] = live.next.UTC().Format(time.RFC3339)
		}
		// the user the page is drawn as: one who can no longer sign in fails every turn (alerted), and the page says so
		if s.auth != nil {
			if hash, _, err := s.auth.lookup(ctx, live.owner); err == nil && hash == "" {
				out["as_off"] = fmt.Sprintf("the user %s can no longer sign in (disabled or removed): each day's mail fails, and is alerted, until that user is enabled or the mail is kept as another", live.owner)
			}
		}
	}
	var channels int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.alert_channels c WHERE c.kind = 'smtp' AND c.is_configured AND c.name NOT LIKE 'contact-%'`).Scan(&channels); err != nil {
		return nil, err
	}
	switch {
	case reason != "":
	case !migrated:
		reason = "Mailing the Daily checks needs a migrated repository: " + dailyNotMigrated + "."
	case owner == "file":
		reason = "The Daily checks mail is kept by pgvigil.yaml (" + reportmail.DailyChecksKey + "): change it there."
		switch {
		case fileWhy != "" && live.id != 0:
			// the line above says "on, next send ...": that is the schedule kept before, not what the file now says
			reason += " " + dailyNotApplied(fileWhy)
		case fileWhy != "":
			reason += " It is not kept yet: " + fileWhy + "."
		}
	case owner == "file-off":
		reason = "The Daily checks mail is turned off in pgvigil.yaml (" + reportmail.DailyChecksKey + ".enabled: false)."
		switch {
		case fileWhy != "" && live.id != 0:
			reason += " " + dailyNotApplied(fileWhy)
		case fileWhy != "":
			reason += " " + fileWhy + "."
		}
	case channels == 0 && live.id == 0:
		reason = "Mailing the Daily checks needs an smtp channel: the sender has recorded none (the alerts: block of pgvigil.yaml, and pgvigil run)."
	}
	out["writable"], out["reason"] = reason == "", reason
	if reportmail.FindBrowser() == "" {
		out["browser_note"] = "no Chromium-family browser on this server (PGVIGIL_BROWSER names one): the daily mail cannot be drawn here, and each turn is a failed mail"
	}
	return out, nil
}

// dailyNotApplied is the page's sentence for a setting of the file that could not be applied while a schedule kept
// before is live: that schedule goes on mailing as it was (its hour, its addresses), and the page must not read as if
// the file's change were in force.
func dailyNotApplied(why string) string {
	return "The file's change is not applied: the schedule still runs as before (" + why + ")."
}

// dailyRequest is POST /api/reportmail's body for the ops daily_keep and daily_drop
type dailyRequest struct {
	Op         string   `json:"op"`
	At         string   `json:"at"`
	Timezone   string   `json:"timezone"`
	Recipients []string `json:"recipients"`
	Channel    string   `json:"channel"`
	AttachXLSX *bool    `json:"attach_xlsx"`
}

// reportMailDaily is POST /api/reportmail with op daily_keep / daily_drop: the Daily checks page's control. user is
// the signed-in user the gate found; the mail is drawn as that user.
func (s *Server) reportMailDaily(w http.ResponseWriter, r *http.Request, user string, raw []byte) {
	var in dailyRequest
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	st := s.dailyChecksOf()
	st.mu.Lock()
	block := st.block
	st.mu.Unlock()
	if block != nil {
		// the file owns the mail, also while it has kept none yet: the page writes nothing
		why := "the Daily checks mail is kept by pgvigil.yaml (" + reportmail.DailyChecksKey + "): change it there"
		if !block.On() {
			why = "the Daily checks mail is turned off in pgvigil.yaml (" + reportmail.DailyChecksKey + ".enabled: false)"
		}
		writeErr(w, http.StatusConflict, errors.New(why))
		return
	}
	var migrated bool
	if err := s.pool.QueryRow(r.Context(), sqlKeptMigrated).Scan(&migrated); err != nil || !migrated {
		writeErr(w, http.StatusConflict, errors.New(dailyNotMigrated))
		return
	}
	var res map[string]any
	var err error
	switch in.Op {
	case "daily_keep":
		req := reportmail.KeptRequest{At: in.At, TZ: strings.TrimSpace(in.Timezone), As: user, Channel: strings.TrimSpace(in.Channel), To: in.Recipients,
			AttachXLSX: in.AttachXLSX == nil || *in.AttachXLSX}
		pay, _, perr := req.Payload(time.Now())
		if perr != nil {
			writeErr(w, http.StatusBadRequest, perr)
			return
		}
		res, err = s.keptWrite(r.Context(), "keep", "page", user, clientIP(r), pay)
	case "daily_drop":
		res, err = s.keptWrite(r.Context(), "drop", "page", user, clientIP(r), nil)
	default:
		writeErr(w, http.StatusBadRequest, fmt.Errorf("op %q is not daily_keep or daily_drop", in.Op))
		return
	}
	if err == nil && res["outcome"] == "unchanged" {
		res["outcome"] = "done" // already as asked: the page's answer is the same
	}
	s.importReply(w, r, res, err)
}
