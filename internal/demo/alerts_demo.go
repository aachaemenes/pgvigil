package demo

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const demoAlertChannel = "demo-spool"

type demoAlertItem struct {
	Event      string `json:"event"`
	FindingKey string `json:"finding_key"`
	InstanceID int    `json:"instance_id"`
	Instance   string `json:"instance"`
	Severity   string `json:"severity"`
	Source     string `json:"source"`
	Setting    string `json:"setting"`
	Value      string `json:"value"`
}

type demoAlertSend struct {
	at      time.Time
	outcome string
	err     string
	item    demoAlertItem
}

// SeedAlerts records the demo channel and its sends from start to end.
func SeedAlerts(ctx context.Context, pool *pgxpool.Pool, start, end time.Time) error {
	for _, sql := range []string{
		`DELETE FROM pgvigil.alert_state WHERE channel = '` + demoAlertChannel + `'`,
		`DELETE FROM pgvigil.alert_log WHERE channel = '` + demoAlertChannel + `'`,
	} {
		if _, err := pool.Exec(ctx, sql); err != nil {
			return err
		}
	}
	ch, _ := json.Marshal([]map[string]any{{"name": demoAlertChannel, "kind": "file", "destination": "file:/var/spool/pgvigil/alerts",
		"min_severity": "warning", "instances": []string{}, "tags": []string{}, "quiet_hours": "", "timezone": "",
		"repeat_secs": 86400, "clear_after_secs": 600, "recovery": true}})
	if _, err := pool.Exec(ctx, `SELECT pgvigil.alert_channels_sync($1, $2::jsonb)`, start, string(ch)); err != nil {
		return err
	}
	rows, err := pool.Query(ctx, `SELECT finding_key, instance_id, instance, severity, source, setting, coalesce(value, '')
	                                FROM pgvigil.alert_findings
	                               WHERE severity IN ('warning', 'critical') AND instance LIKE 'demo-%'
	                               ORDER BY instance, source, setting, finding_key`)
	if err != nil {
		return err
	}
	var items []demoAlertItem
	for rows.Next() {
		var it demoAlertItem
		if err := rows.Scan(&it.FindingKey, &it.InstanceID, &it.Instance, &it.Severity, &it.Source, &it.Setting, &it.Value); err != nil {
			rows.Close()
			return err
		}
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	var sends []demoAlertSend
	for _, it := range items {
		// first sent 1-6 hours into the history (stable per finding), then every 24 hours while it stands
		first := start.Add(time.Hour + time.Duration(hash64(it.FindingKey)%(5*60))*time.Minute)
		ev := "firing"
		for t := first; t.Before(end); t = t.Add(24 * time.Hour) {
			x := it
			x.Event = ev
			sends = append(sends, demoAlertSend{at: t, outcome: "sent", item: x})
			ev = "repeat"
		}
	}
	// a finding that came and went: erp01's swap, fired 30 h before the end, resolved 4 h later
	var swap demoAlertItem
	if err := pool.QueryRow(ctx, `SELECT pgvigil.alert_finding_key(instance_id, 'pgvigil host', 'swap used', name || ': 2048 MB of swap in use'),
	                                     instance_id, name FROM pgvigil.instances WHERE name LIKE 'demo-%erp01' ORDER BY name LIMIT 1`).
		Scan(&swap.FindingKey, &swap.InstanceID, &swap.Instance); err == nil && end.Sub(start) > 31*time.Hour {
		swap.Severity, swap.Source, swap.Setting, swap.Value = "warning", "pgvigil host", "swap used", swap.Instance+": 2048 MB of swap in use"
		f, r := swap, swap
		f.Event, r.Event = "firing", "resolved"
		sends = append(sends, demoAlertSend{at: end.Add(-30 * time.Hour), outcome: "sent", item: f},
			demoAlertSend{at: end.Add(-26 * time.Hour), outcome: "sent", item: r})
	}
	// one failed attempt 50 h before the end (when the history is that long), then the send a minute later
	if len(items) > 0 && end.Sub(start) > 51*time.Hour {
		it := items[0]
		it.Event = "repeat"
		at := end.Add(-50 * time.Hour)
		sends = append(sends, demoAlertSend{at: at, outcome: "failed", err: "open /var/spool/pgvigil/alerts/.pgvigil-alert-1.tmp: permission denied", item: it},
			demoAlertSend{at: at.Add(time.Minute), outcome: "sent", item: it})
	}
	sort.SliceStable(sends, func(i, j int) bool { return sends[i].at.Before(sends[j].at) })
	// the history's month partitions, made as the owner (alert_record's own door makes only the current month's)
	for m := start; !m.After(end.AddDate(0, 1, 0)); m = m.AddDate(0, 1, 0) {
		if _, err := pool.Exec(ctx, `SELECT pgvigil.ensure_month_partition('alert_log', $1)`, m); err != nil {
			return err
		}
	}
	for _, s := range sends {
		pay, _ := json.Marshal(map[string]any{"channel": demoAlertChannel, "kind": "file", "destination": "file:/var/spool/pgvigil/alerts",
			"outcome": s.outcome, "error": s.err, "items": []demoAlertItem{s.item}})
		if _, err := pool.Exec(ctx, `SELECT pgvigil.alert_record($1, $2::jsonb)`, s.at, string(pay)); err != nil {
			return fmt.Errorf("%s %s at %s: %w", s.item.Event, s.item.Setting, s.at.Format(time.RFC3339), err)
		}
	}
	return nil
}
