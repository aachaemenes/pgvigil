package demo

// Backup rows for the demo fleet (the backups collection, task 33): the shapes import_backups takes.
//
// Step:        if first || t.Minute()%5 == 0 { add("backups", g.backupRows(t)) }
// Collections: "backups" on every platform (the archiver is read everywhere; the cloud side on RDS and Aurora).
// seed.go:     no skip line: every platform has the archiver read.

import (
	"fmt"
	"strings"
	"time"
)

const demoSeg = int64(16 << 20)

// backupRows is the 5-minute backups read. The archiver: a segment archived about every 4 minutes on a primary
// (archive_timeout 300), the last a minute or two before the read; onprem-hr01's archive_command has failed for
// the last 3 hours (every attempt a failure, the WAL piling up); the standby onprem-erp02 has archive_mode on and
// archives nothing; Aurora reports archive_mode off. The cloud side: RDS and Aurora with a daily automated snapshot
// at 03:05 UTC kept for the retention, a manual snapshot two weeks old; rds-orders01's retention is 3 days,
// aurora-dms01 keeps Aurora's default of 1 day, aurora-reporting01's last two automated snapshots were missed.
func (g *Gen) backupRows(t time.Time) []Row {
	s := g.Spec
	has := func(part string) bool { return strings.Contains(s.Name, part) }
	mins := int64(t.Sub(g.start).Minutes())
	arch := Row{"kind": "archiver", "name": "pg_stat_archiver", "archive_mode": "on", "archive_timeout": "5min", "archive_set": true,
		"is_replica": s.Replica, "wal_segment_bytes": demoSeg, "archive_warn_minutes": 60, "stats_reset": g.start.Add(-30 * 24 * time.Hour)}
	switch {
	case s.Platform == "aurora":
		arch["archive_mode"], arch["archive_set"] = "off", false
		arch["archived_count"], arch["failed_count"] = 0, 0
		arch["current_lsn"], arch["archive_lag_bytes"] = "0/0", 0
	case s.Replica:
		arch["archived_count"], arch["failed_count"] = 0, 0
	default:
		n := mins/4 + int64(g.idx)*1000
		last := t.Add(-time.Duration(1+int(noise(s.Name+"arch", t)*3)) * time.Minute)
		arch["archived_count"], arch["failed_count"] = n, int64(2)
		arch["last_archived_wal"] = fmt.Sprintf("00000001%08X%08X", n/256, n%256)
		arch["last_archived_time"] = last
		arch["last_failed_wal"] = fmt.Sprintf("00000001%08X%08X", (n-500)/256, (n-500)%256)
		arch["last_failed_time"] = g.start.Add(36 * time.Hour)
		arch["archive_lag_bytes"] = int64(noise(s.Name+"lag", t) * float64(demoSeg))
		if has("hr01") {
			broke := g.end.Add(-3 * time.Hour)
			if t.After(broke) {
				stuck := (int64(broke.Sub(g.start).Minutes()))/4 + int64(g.idx)*1000
				waiting := int64(t.Sub(broke).Minutes() / 4)
				arch["archived_count"] = stuck
				arch["last_archived_wal"] = fmt.Sprintf("00000001%08X%08X", stuck/256, stuck%256)
				arch["last_archived_time"] = broke
				arch["failed_count"] = int64(2) + int64(t.Sub(broke).Minutes())*3
				arch["last_failed_wal"] = fmt.Sprintf("00000001%08X%08X", (stuck+1)/256, (stuck+1)%256)
				arch["last_failed_time"] = t.Add(-20 * time.Second)
				arch["archive_lag_bytes"] = waiting*demoSeg + demoSeg/2
			}
		}
		arch["current_lsn"] = fmt.Sprintf("%X/%X", n/256, (n%256)*demoSeg)
	}
	out := []Row{arch}
	if s.Platform != "rds" && s.Platform != "aurora" {
		return out
	}
	retention, kind, prefix := 7, "instance", "rds:"+s.Name
	if s.Platform == "aurora" {
		kind = "cluster"
	}
	switch {
	case has("orders01"):
		retention = 3
	case has("dms01"):
		retention = 1
	case has("crm01"):
		retention = 14
	}
	out = append(out, Row{"kind": "cloud", "name": s.Name, "resource_kind": kind, "retention_days": retention,
		"latest_restorable_time":   t.Add(-time.Duration(2+int(noise(s.Name+"lrt", t)*4)) * time.Minute),
		"earliest_restorable_time": map[bool]any{true: t.Add(-time.Duration(retention) * 24 * time.Hour).Truncate(time.Hour), false: nil}[kind == "cluster"],
		"backup_window":            "03:00-03:30"})
	day := time.Date(t.Year(), t.Month(), t.Day(), 3, 5, 0, 0, time.UTC)
	if day.After(t) {
		day = day.Add(-24 * time.Hour)
	}
	n := 0
	for i := 0; i < retention; i++ {
		at := day.Add(-time.Duration(i) * 24 * time.Hour)
		if has("reporting01") && g.end.Sub(at) < 48*time.Hour {
			continue // the last two automated snapshots were missed
		}
		out = append(out, Row{"kind": "snapshot", "name": fmt.Sprintf("%s-%s", prefix, at.Format("2006-01-02-15-04")), "snapshot_type": "automated",
			"status": "available", "created_at": at, "allocated_gib": map[bool]any{true: 0, false: 500}[kind == "cluster"], "encrypted": true})
		n++
	}
	manual := g.end.Add(-14 * 24 * time.Hour).Truncate(time.Hour)
	out = append(out, Row{"kind": "snapshot", "name": s.Name + "-before-upgrade", "snapshot_type": "manual", "status": "available",
		"created_at": manual, "allocated_gib": map[bool]any{true: 0, false: 500}[kind == "cluster"], "encrypted": !has("billing01")},
		Row{"kind": "snapshots_read", "name": "snapshots", "count": n + 1})
	return out
}
