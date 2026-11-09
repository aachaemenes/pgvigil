package demo

// Actions log rows for the demo fleet (task 39): the shape import_actions_log takes. Every instance whose
// demo carries a lock chain or an idle-in-transaction head has a short history of attempts: a cancel done,
// a terminate done on the idle head, a refused attempt on a reused pid and one on a superuser's session.
// The rows are dated against the anchor and written once, at the anchor's snapshot.
//
// Step line (in Step, after add("storage", ...)):
//	if t.Equal(g.end) {
//		add("actions_log", g.actionsLogRows())
//	}
// Collections: no line (actions_log is the serve process's audit, not a collection: it never lands in
// collection_dates and the stale check never names it).

import "time"

func (g *Gen) actionsLogRows() []Row {
	s := g.Spec
	if !s.ChainActive && !s.ChainDDL && !s.IdleHead {
		return nil
	}
	row := func(ago time.Duration, user, action string, pid int, outcome, reason, detail string) Row {
		at := g.end.Add(-ago)
		return Row{"instance_name": s.Name, "at": at, "ui_user": user, "client": "10.9.0.21", "action": action, "pid": pid,
			"backend_start": at.Add(-time.Duration(1+pid%9) * time.Hour), "target_user": "app_" + s.App,
			"target_app": s.App + "-api", "reason": reason, "outcome": outcome, "detail": detail}
	}
	fn := map[string]string{"cancel": "pg_cancel_backend", "terminate": "pg_terminate_backend"}
	return []Row{
		row(26*time.Hour, "dba.oncall", "cancel", 41207, "done", "month-end report holding the convoy, agreed with the app owner",
			fn["cancel"]+"(41207) sent"),
		row(9*time.Hour+12*time.Minute, "dba.oncall", "terminate", 41388, "refused", "idle in transaction for 40 min, blocking updates",
			"pid 41388 now belongs to another backend (started later than the row shown): the session shown has ended and the pid was reused"),
		row(9*time.Hour+10*time.Minute, "dba.oncall", "terminate", 41391, "done", "idle in transaction for 40 min, blocking updates",
			fn["terminate"]+"(41391) sent"),
		{"instance_name": s.Name, "at": g.end.Add(-3 * time.Hour), "ui_user": "a.lead", "client": "10.9.0.33", "action": "terminate",
			"pid": 40012, "backend_start": g.end.Add(-30 * 24 * time.Hour), "target_user": "postgres", "target_app": "psql",
			"reason": "stray psql left open", "outcome": "refused",
			"detail": "pid 40012 belongs to the superuser postgres: the actions login holds pg_signal_backend only and a superuser's backend stays out of its reach"},
	}
}
