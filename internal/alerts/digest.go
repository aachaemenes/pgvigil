package alerts

// The daily digest (migration 0154; PerformanceMonitor 3.13 Added 7, Changed 18, Release 7): a channel with a
// digest_hour gets one message a day at that hour in its timezone, listing the alerts a digest window held on it
// since its last digest, grouped by instance and check (how many, first and last held, the highest severity, the
// newest detail), at most maxDigestGroups groups then '+N more'. Nothing is sent on a day with none (the store records
// 'empty'). The digest is an event the pass owes (pgvigil.digest_due): a failed one is owed again on the next pass, a
// missed hour once, and it goes out only when the channel is not in its quiet hours, not backing off and under its
// max_per_hour. The findings history (pgvigil.findings_history_run) is written by the same pass, whatever the
// channels.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// maxDigestGroups bounds the groups one digest lists; the rest are counted in its last line.
const maxDigestGroups = 40

// digestGroup is one row of pgvigil.digest_items.
type digestGroup struct {
	Instance, Check, Severity, Detail string
	Alerts                            int64
	First, Last                       time.Time
}

// undefinedFunction says a repository before the migration that makes the function: the feature is not there yet.
func undefinedFunction(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "42883"
}

// historyRun writes this pass's findings-history rows; 0 and no error on a repository before 0154.
func historyRun(ctx context.Context, conn *pgxpool.Conn, now time.Time) (int, error) {
	var n int
	err := conn.QueryRow(ctx, `SELECT pgvigil.findings_history_run($1)`, now).Scan(&n)
	if err != nil && undefinedFunction(err) {
		return 0, nil
	}
	return n, err
}

// runDigests sends every digest owed at now. A channel takes part when it has a digest_hour, is not in its quiet
// hours, is not backing off (skip) and did not fail in this pass (outcome); a failed send is recorded and owed again.
func runDigests(ctx context.Context, conn *pgxpool.Conn, all []Channel, now time.Time, skip map[string]bool,
	outcome map[string]error, res *Result) error {
	var ask []map[string]any
	byName := map[string]*Channel{}
	for i := range all {
		c := &all[i]
		if c.DigestHour == nil || c.Quiet(now) || skip[c.Name] || outcome[c.Name] != nil {
			continue
		}
		byName[c.Name] = c
		ask = append(ask, map[string]any{"name": c.Name, "digest_hour": *c.DigestHour, "timezone": c.Timezone})
	}
	if len(ask) == 0 {
		return nil
	}
	pay, _ := json.Marshal(ask)
	type owedDigest struct {
		channel      string
		dueAt, since time.Time
	}
	var owed []owedDigest
	rows, err := conn.Query(ctx, `SELECT channel, due_at, since FROM pgvigil.digest_due($1, $2::jsonb)`, now, string(pay))
	if err != nil {
		if undefinedFunction(err) {
			return nil
		}
		return err
	}
	for rows.Next() {
		var o owedDigest
		if err := rows.Scan(&o.channel, &o.dueAt, &o.since); err != nil {
			rows.Close()
			return err
		}
		owed = append(owed, o)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, o := range owed {
		c := byName[o.channel]
		if c == nil {
			continue
		}
		groups, err := digestItems(ctx, conn, o.channel, o.since, now)
		if err != nil {
			return err
		}
		rec := map[string]any{"channel": o.channel, "due_at": o.dueAt, "since": o.since, "groups": len(groups)}
		var alerts int64
		for _, g := range groups {
			alerts += g.Alerts
		}
		rec["alerts"] = alerts
		if len(groups) == 0 {
			rec["outcome"] = "empty"
			if err := digestRecord(ctx, conn, now, rec); err != nil {
				return err
			}
			continue
		}
		if c.MaxPerHour > 0 {
			used, err := digestCapUsed(ctx, conn, c.Name, now)
			if err != nil {
				return err
			}
			if used >= c.MaxPerHour {
				continue // owed again: a later pass sends it once the hour allows (nothing recorded)
			}
		}
		msg := digestMessage(c, groups, o.since, now)
		sctx, cancel := context.WithTimeout(ctx, sendTimeout)
		err = c.sender.send(sctx, msg)
		cancel()
		rec["outcome"] = "sent"
		if err != nil {
			rec["outcome"], rec["error"] = "failed", err.Error()
			var re *refusedError
			if errors.As(err, &re) {
				rec["outcome"] = "refused"
			}
			res.DigestsFailed++
			res.Errors = append(res.Errors, c.Name+": digest: "+err.Error())
			outcome[c.Name] = err
		} else {
			res.Digests++
		}
		if err := digestRecord(context.WithoutCancel(ctx), conn, time.Now(), rec); err != nil {
			return err
		}
	}
	return nil
}

// digestItems reads one channel's digest groups held after since.
func digestItems(ctx context.Context, conn *pgxpool.Conn, channel string, since, now time.Time) ([]digestGroup, error) {
	rows, err := conn.Query(ctx, `SELECT instance, check_name, alerts, first_at, last_at, coalesce(severity, ''),
	       coalesce(detail, '') FROM pgvigil.digest_items($1, $2, $3)`, channel, since, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []digestGroup
	for rows.Next() {
		var g digestGroup
		if err := rows.Scan(&g.Instance, &g.Check, &g.Alerts, &g.First, &g.Last, &g.Severity, &g.Detail); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// digestCapUsed is what the channel sent in the hour before now: its alerts (alert_log, as capHold counts them) and
// its digests (digest_log), one each.
func digestCapUsed(ctx context.Context, conn *pgxpool.Conn, channel string, now time.Time) (int, error) {
	var used int
	err := conn.QueryRow(ctx, `SELECT (SELECT coalesce(sum(n_firing + n_repeat + n_resolved), 0) FROM pgvigil.alert_log
	   WHERE channel = $1 AND outcome = 'sent' AND snapshot_at > $2::timestamptz - interval '1 hour')
	 + (SELECT count(*) FROM pgvigil.digest_log WHERE channel = $1 AND outcome = 'sent' AND at > $2::timestamptz - interval '1 hour')`,
		channel, now).Scan(&used)
	if err != nil {
		return 0, fmt.Errorf("max_per_hour: %w", err)
	}
	return used, nil
}

// digestRecord writes one digest attempt.
func digestRecord(ctx context.Context, conn *pgxpool.Conn, at time.Time, rec map[string]any) error {
	pay, _ := json.Marshal(rec)
	_, err := conn.Exec(ctx, `SELECT pgvigil.digest_record($1, $2::jsonb)`, at, string(pay))
	return err
}

// digestMessage builds one channel's digest: a line per group (event 'digest'), the most severe first as the store
// orders them, then '+N more' past maxDigestGroups. The detail is the one the alert's own message would carry.
func digestMessage(c *Channel, groups []digestGroup, since, now time.Time) Message {
	loc := c.loc
	if loc == nil {
		loc = time.UTC
	}
	var total int64
	for _, g := range groups {
		total += g.Alerts
	}
	shown := groups
	if len(shown) > maxDigestGroups {
		shown = shown[:maxDigestGroups]
	}
	out := make([]Alert, 0, len(shown)+1)
	for _, g := range shown {
		when := g.First.In(loc).Format("Mon 15:04")
		if !g.Last.Equal(g.First) {
			when += " to " + g.Last.In(loc).Format("Mon 15:04")
		}
		a := Alert{Event: "digest", Instance: g.Instance, Severity: g.Severity, Setting: g.Check,
			Value: fmt.Sprintf("%d alert(s) held, %s", g.Alerts, when), Detail: g.Detail}
		a.text = fmt.Sprintf("[%s] %s - %s: %s", strings.ToUpper(g.Severity), g.Instance, g.Check, a.Value)
		if g.Detail != "" {
			a.text += " - newest: " + g.Detail
		}
		out = append(out, a)
	}
	if more := len(groups) - len(shown); more > 0 {
		a := Alert{Event: "digest", Instance: "pgvigil", Setting: "digest", Value: fmt.Sprintf("+%d more group(s)", more)}
		a.text = fmt.Sprintf("+%d more group(s): the Alerts page lists every held alert", more)
		out = append(out, a)
	}
	subject := fmt.Sprintf("pgvigil: daily digest - %d alert(s) held on %s since %s", total, c.Name,
		since.In(loc).Format("Mon 2006-01-02 15:04 MST"))
	return Message{Channel: c.Name, SentAt: now.UTC(), Alerts: out, Subject: subject}
}
