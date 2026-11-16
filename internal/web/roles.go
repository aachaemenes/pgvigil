package web

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"
)

// The web UI's roles (task B24f). viewer reads; operator acts on a monitored server (cancel, terminate, KILL, job
// start / stop, plan evict, EXPLAIN) and acknowledges; admin changes configuration others live with (instances,
// sources, applications, thresholds, exclusions, alert rules, custom reports, report mail schedules). Every POST is
// registered through s.post with its need (roles_test.go's AST check refuses any other write pattern), and
// docs/roles.md's table is the same list (TestRolesDocMatches). The role is read with the hash at every request
// (ui_login_of), so a demoted user loses the right at the next one. Roles apply with the login on: a -no-login serve
// (loopback only) and a demo serve (its own door and user) keep their own words.

type need int

const (
	needAnyone need = iota
	needViewer
	needOperator
	needAdmin
)

var needWord = [...]string{"anyone", "viewer", "operator", "admin"}

// roleRank is a role's place among the needs; an unknown or empty role ranks below viewer
func roleRank(role string) need {
	switch role {
	case "viewer":
		return needViewer
	case "operator":
		return needOperator
	case "admin":
		return needAdmin
	}
	return -1
}

// who is a request's signed-in user and role; err is set when the role could not be read (the lookup failed: the
// session is kept for reads, a write is refused 503)
type who struct {
	user, role string
	err        error
}

type whoKey struct{}

func withWho(r *http.Request, w who) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), whoKey{}, w))
}

// whoOf is the request's who, read once by requireLogin
func whoOf(r *http.Request) (who, bool) {
	w, ok := r.Context().Value(whoKey{}).(who)
	return w, ok
}

// article is 'an' before admin and operator, 'a' before viewer
func article(role string) string {
	if role == "viewer" {
		return "a"
	}
	return "an"
}

// routeWhat names what a route does, for its refusal ("<what> needs the <need> role: ...")
var routeWhat = map[string]string{
	"POST /api/indexes/advise":              "running the index advisor",
	"POST /api/mssql/actions/preview":       "previewing an action",
	"POST /api/community/glenn/parse":       "reading a diagnostic file",
	"POST /api/community/params":            "reading a tool's parameters",
	"POST /api/customreports/run":           "running a custom report",
	"POST /api/reportmail/rendered":         "drawing a mailed report",
	"POST /api/actions/cancel":              "cancelling a query",
	"POST /api/actions/terminate":           "ending a session",
	"POST /api/mssql/actions/run":           "running an action on a SQL Server instance",
	"POST /api/jobs/actions/stop":           "stopping a job",
	"POST /api/jobs/actions/start":          "starting a job",
	"POST /api/jobs/actions/enable":         "enabling a job",
	"POST /api/jobs/actions/disable":        "disabling a job",
	"POST /api/ack":                         "acknowledging",
	"POST /api/ack/end":                     "ending an acknowledgement",
	"POST /api/alerts/dismiss":              "dismissing an alert",
	"POST /api/alerts/mute":                 "changing a mute rule",
	"POST /api/alerts/test":                 "sending a test alert",
	"POST /api/plans/explain":               "running EXPLAIN",
	"POST /api/plans/analyze":               "running EXPLAIN ANALYZE",
	"POST /api/plans/hypo":                  "trying a hypothetical index",
	"POST /api/community/run":               "running a community tool",
	"POST /api/reportmail/send":             "sending a report by mail",
	"POST /api/reportmail/test":             "sending a test report mail",
	"POST /api/admin/instances":             "changing an instance",
	"POST /api/admin/sources":               "changing a discovery source",
	"POST /api/admin/proposals":             "approving or ignoring a proposed instance",
	"POST /api/admin/dbadash_moves":         "moving a DBA Dash instance",
	"POST /api/admin/applications":          "changing an application",
	"POST /api/admin/applications/contacts": "changing an application's contacts",
	"POST /api/admin/applications/assign":   "assigning instances to an application",
	"POST /api/admin/applications/routes":   "changing an application's routes",
	"POST /api/admin/applications/import":   "importing the applications inventory file",
	"POST /api/alertrules":                  "changing an alert rule",
	"POST /api/alertrules/end":              "ending an alert rule",
	"POST /api/drives/thresholds":           "changing a drive threshold",
	"POST /api/pg/thresholds":               "changing a PostgreSQL threshold",
	"POST /api/jobs/thresholds":             "changing a job threshold",
	"POST /api/mssql/config_expect":         "changing an expected value",
	"POST /api/jobs/exclusions":             "changing a job exclusion",
	"POST /api/customreports":               "changing a custom report",
	"POST /api/reportmail":                  "changing a report mail schedule",
}

// roleWords is a refusal's text: what, the need, who holds which role, and how an admin changes it
func roleWords(what string, n need, w who) string {
	return fmt.Sprintf("%s needs the %s role: %s is %s %s (an admin changes it with 'pgvigil user role %s %s' on the server)",
		what, needWord[n], w.user, article(w.role), w.role, w.user, needWord[n])
}

// roleOK says whether the request's user holds need n, writing the refusal when not (403 with the role's words, a
// 'role refused' log line and no audit row - review-16 S3: a refusal row would let a loop fill admin_audit; 503 when
// the role could not be read). With the login off or on a demo serve roles do not apply.
func (s *Server) roleOK(w http.ResponseWriter, r *http.Request, n need, what string) bool {
	if n == needAnyone || s.auth == nil || s.demo != nil {
		return true
	}
	wh, ok := whoOf(r)
	if !ok {
		wh = s.sessionWho(r)
	}
	switch {
	case wh.user == "":
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return false
	case wh.err != nil:
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the role could not be read: %v", wh.err))
		return false
	case roleRank(wh.role) < n:
		s.log.Info("role refused", "user", wh.user, "role", wh.role, "need", needWord[n], "what", what, "route", r.Method+" "+r.URL.Path)
		writeErr(w, http.StatusForbidden, errors.New(roleWords(what, n, wh)))
		return false
	}
	return true
}

// muteCeiling is the longest end an operator may give a mute, a silence or a blackout (the lead 11-15 13:3x): an end
// more than 7 days after now, or after its start when that is later, is open-ended and needs admin with the same words
// as no end at all (review-18 b24f1 S2: the store takes any end in the future, 9999-12-31 included).
const muteCeiling = 7 * 24 * time.Hour

// openEnded says whether a mute, silence or blackout's end makes it open-ended: none, or past muteCeiling
func openEnded(starts, until *time.Time, now time.Time) bool {
	if until == nil {
		return true
	}
	from := now
	if starts != nil && starts.After(from) {
		from = *starts
	}
	return until.Sub(from) > muteCeiling
}

// roleErr is a role refusal a handler raises from its own body read, where its caller writes the reply (alertDoor's
// build): 403 with the role's words, as roleOK writes it
type roleErr struct{ words string }

func (e roleErr) Error() string { return e.words }

// needErr is roleOK for such a handler: nil when the request's user holds need n, else the refusal - the same
// 'role refused' log line, no audit row. With the login off or on a demo serve roles do not apply.
func (s *Server) needErr(r *http.Request, n need, what string) error {
	if n == needAnyone || s.auth == nil || s.demo != nil {
		return nil
	}
	wh, ok := whoOf(r)
	if !ok {
		wh = s.sessionWho(r)
	}
	if wh.err != nil || roleRank(wh.role) < n {
		s.log.Info("role refused", "user", wh.user, "role", wh.role, "need", needWord[n], "what", what, "route", r.Method+" "+r.URL.Path)
		return roleErr{roleWords(what, n, wh)}
	}
	return nil
}

// post registers a write with its need: the X-Pgvigil header first (every POST, login and logout too: a POST
// without it writes nothing), then the role, then the route's own gates (no login, no door, the demo) in its
// handler. Every POST of web.go goes through here (roles_test.go).
func (s *Server) post(mux *http.ServeMux, pattern string, n need, h http.HandlerFunc) {
	what := routeWhat[pattern]
	if what == "" {
		what = "this change"
	}
	mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(loginHeader) == "" {
			writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
			return
		}
		if !s.roleOK(w, r, n, what) {
			return
		}
		h(w, r)
	})
}

// roleCan is a page's answer of what the session's role may do (review-16 S6: {operator, admin} beside a route's
// own writable / reason); with the login off or on a demo every role check is open, the route's own reason stands
func (s *Server) roleCan(r *http.Request) map[string]bool {
	if s.auth == nil || s.demo != nil {
		return map[string]bool{"operator": true, "admin": true}
	}
	wh, ok := whoOf(r)
	if !ok {
		wh = s.sessionWho(r)
	}
	rk := roleRank(wh.role)
	if wh.err != nil {
		rk = -1
	}
	return map[string]bool{"operator": rk >= needOperator, "admin": rk >= needAdmin}
}
